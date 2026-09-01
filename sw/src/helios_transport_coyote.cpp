#include <helios/helios_transport_coyote.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <unistd.h>

namespace helios {

HeliosCoyoteTransport::HeliosCoyoteTransport(
    int32_t vfpga_id, std::uint32_t device, bool use_hugepages)
    : thread_(vfpga_id, getpid(), device), src_mem_(nullptr), dst_mem_(nullptr), capacity_(0) {
    (void)use_hugepages;
}

std::uint64_t HeliosCoyoteTransport::wait_for_peer_up(
    std::chrono::milliseconds timeout) {
    constexpr std::uint32_t status_register = 1;
    constexpr std::uint64_t peer_link_up = 1ULL << 2;
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    std::uint64_t status = 0;

    do {
        status = thread_.getCSR(status_register);
        if ((status & peer_link_up) != 0) {
            return status;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    } while (std::chrono::steady_clock::now() < deadline);

    throw std::runtime_error("Timed out waiting for the Aurora peer link");
}

void HeliosCoyoteTransport::ensure_capacity(std::size_t bytes) {
    if (bytes <= capacity_) {
        return;
    }

    if (bytes > std::numeric_limits<uint32_t>::max()) {
        throw std::runtime_error("Requested Coyote buffer exceeds allocation size limit");
    }

    const auto alloc_bytes = static_cast<uint32_t>(bytes);
    src_mem_ = reinterpret_cast<uint8_t*>(thread_.getMem({coyote::CoyoteAllocType::HPF, alloc_bytes}));
    dst_mem_ = reinterpret_cast<uint8_t*>(thread_.getMem({coyote::CoyoteAllocType::HPF, alloc_bytes}));

    if (!src_mem_ || !dst_mem_) {
        throw std::runtime_error("Failed to allocate Coyote buffers");
    }

    capacity_ = bytes;
}

std::vector<uint8_t> HeliosCoyoteTransport::roundtrip(
    const std::vector<uint8_t>& tx_bytes,
    std::size_t rx_window_bytes,
    std::chrono::milliseconds timeout,
    bool trim_trailing_zeros) {

    if (tx_bytes.empty()) {
        throw std::runtime_error("TX payload must not be empty");
    }

    if (rx_window_bytes == 0) {
        throw std::runtime_error("RX window must be greater than zero");
    }

    if (tx_bytes.size() > std::numeric_limits<uint32_t>::max()) {
        throw std::runtime_error("TX payload exceeds Coyote LOCAL_TRANSFER size limit");
    }

    if (rx_window_bytes > std::numeric_limits<uint32_t>::max()) {
        throw std::runtime_error("RX window exceeds Coyote LOCAL_TRANSFER size limit");
    }

    const std::size_t alloc_len = std::max(tx_bytes.size(), rx_window_bytes);
    ensure_capacity(alloc_len);

    std::memset(src_mem_, 0, tx_bytes.size());
    std::memset(dst_mem_, 0, rx_window_bytes);
    std::memcpy(src_mem_, tx_bytes.data(), tx_bytes.size());

    coyote::localSg src_sg = {.addr = src_mem_, .len = static_cast<uint32_t>(tx_bytes.size()), .stream = 1};
    coyote::localSg dst_sg = {.addr = dst_mem_, .len = static_cast<uint32_t>(rx_window_bytes), .stream = 1};

    thread_.clearCompleted();
    thread_.invoke(coyote::CoyoteOper::LOCAL_TRANSFER, src_sg, dst_sg);

    const auto t0 = std::chrono::steady_clock::now();
    while (thread_.checkCompleted(coyote::CoyoteOper::LOCAL_TRANSFER) != 1) {
        if (std::chrono::steady_clock::now() - t0 > timeout) {
            std::ostringstream message;
            message << "Timed out waiting for LOCAL_TRANSFER completion"
                    << " (status=0x" << std::hex << thread_.getCSR(1)
                    << std::dec << ", peer_tx_beats=" << thread_.getCSR(5)
                    << ", peer_rx_beats=" << thread_.getCSR(3) << ")";
            throw std::runtime_error(message.str());
        }
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }

    std::vector<uint8_t> rx(dst_mem_, dst_mem_ + rx_window_bytes);

    if (trim_trailing_zeros) {
        while (!rx.empty() && rx.back() == 0) {
            rx.pop_back();
        }
    }

    return rx;
}

} // namespace helios
