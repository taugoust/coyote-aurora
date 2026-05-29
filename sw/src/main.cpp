/**
 * Coyote peer-stream host-backed loopback test.
 *
 * This drives the optional Coyote peer abstraction when PEER_BACKEND=host_stream.
 * Host stream destination 0 remains the normal host-facing stream; destination 1
 * is hidden behind axis_peer_recv[0] / axis_peer_send[0]. This app sends a
 * counter-pattern burst through destination 1 and verifies that the vFPGA sees
 * and returns it through the peer interface.
 *
 * Register map (CSR index = byte_offset / 8):
 *   0: CTRL           (bit0=TX start, bit1=RX arm)
 *   1: STATUS         (bit0=tx_done, bit1=rx_done, bit2=peer_link_up, bits[6:3]=peer_lane_up)
 *   2: TX_BURST_BEATS (AXI_DATA_BITS-wide beats to send)
 *   3: RX_BEAT_CNT    (read-only)
 *   4: RX_MISMATCHES  (read-only)
 */

#include <algorithm>
#include <bitset>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <unistd.h>
#include <vector>

#include <boost/program_options.hpp>

#include <coyote/cDefs.hpp>
#include <coyote/cOps.hpp>
#include <coyote/cThread.hpp>

namespace po = boost::program_options;

constexpr uint32_t DEFAULT_VFPGA_ID = 0;
constexpr uint32_t PEER_HOST_DEST = 1;
constexpr uint32_t AXI_DATA_BYTES = 64; // Coyote AXI_DATA_BITS is 512 in this flow.

constexpr uint32_t REG_CTRL        = 0;
constexpr uint32_t REG_STATUS      = 1;
constexpr uint32_t REG_TX_BURST    = 2;
constexpr uint32_t REG_RX_BEATS    = 3;
constexpr uint32_t REG_RX_MISMATCH = 4;

constexpr uint64_t CTRL_TX_START = 1ULL << 0;
constexpr uint64_t CTRL_RX_ARM   = 1ULL << 1;

static void print_status(uint64_t s) {
    bool tx_done      = (s >> 0) & 0x1;
    bool rx_done      = (s >> 1) & 0x1;
    bool peer_link_up = (s >> 2) & 0x1;
    uint8_t lane_up   = (s >> 3) & 0xF;
    std::cout << "  peer_link_up=" << peer_link_up
              << " peer_lane_up=" << std::bitset<4>(lane_up)
              << " tx_done=" << tx_done
              << " rx_done=" << rx_done
              << "\n";
}

static bool wait_for_peer_up(coyote::cThread& t, int timeout_ms) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < deadline) {
        uint64_t s = t.getCSR(REG_STATUS);
        if ((s >> 2) & 0x1) {
            std::cout << "[OK] peer_link_up asserted; ";
            print_status(s);
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    std::cout << "[FAIL] peer_link_up did not assert within " << timeout_ms << " ms\n";
    print_status(t.getCSR(REG_STATUS));
    return false;
}

static std::vector<uint8_t> make_counter_pattern(uint64_t beats) {
    std::vector<uint8_t> data(beats * AXI_DATA_BYTES, 0);
    for (uint64_t beat = 0; beat < beats; ++beat) {
        for (uint32_t lane = 0; lane < AXI_DATA_BYTES / sizeof(uint64_t); ++lane) {
            std::memcpy(&data[beat * AXI_DATA_BYTES + lane * sizeof(uint64_t)], &beat, sizeof(beat));
        }
    }
    return data;
}

static bool wait_for_completion(coyote::cThread& t, std::chrono::milliseconds timeout) {
    auto deadline = std::chrono::steady_clock::now() + timeout;
    while (std::chrono::steady_clock::now() < deadline) {
        if (t.checkCompleted(coyote::CoyoteOper::LOCAL_TRANSFER) >= 1) {
            return true;
        }
        std::this_thread::sleep_for(std::chrono::microseconds(100));
    }
    return false;
}

static uint64_t wait_for_done_status(coyote::cThread& t, std::chrono::milliseconds timeout) {
    auto deadline = std::chrono::steady_clock::now() + timeout;
    uint64_t status = 0;
    while (std::chrono::steady_clock::now() < deadline) {
        status = t.getCSR(REG_STATUS);
        const bool tx_done = (status >> 0) & 0x1;
        const bool rx_done = (status >> 1) & 0x1;
        const bool peer_up = (status >> 2) & 0x1;
        if (tx_done && rx_done && peer_up) {
            return status;
        }
        std::this_thread::sleep_for(std::chrono::microseconds(100));
    }
    return status;
}

int main(int argc, char* argv[]) {
    uint64_t beats;
    int timeout_ms;

    po::options_description desc("Coyote peer-stream loopback");
    desc.add_options()
        ("help,h", "show help")
        ("beats,n", po::value<uint64_t>(&beats)->default_value(1024),
         "Number of AXI_DATA_BITS-wide beats to send / expect")
        ("timeout-ms", po::value<int>(&timeout_ms)->default_value(10000),
         "Timeout in milliseconds");

    po::variables_map vm;
    po::store(po::parse_command_line(argc, argv, desc), vm);
    po::notify(vm);

    if (vm.count("help")) {
        std::cout << desc << "\n";
        return 0;
    }

    if (beats == 0) {
        std::cerr << "beats must be greater than zero\n";
        return 2;
    }

    const auto timeout = std::chrono::milliseconds(timeout_ms);
    const auto payload = make_counter_pattern(beats);
    const auto n_bytes = static_cast<uint32_t>(payload.size());

    std::cout << "=== Coyote peer-stream loopback ===\n"
              << "Beats:       " << beats << "\n"
              << "Bytes:       " << n_bytes << "\n"
              << "Peer dest:   " << PEER_HOST_DEST << "\n";

    coyote::cThread t(DEFAULT_VFPGA_ID, getpid());

    if (!wait_for_peer_up(t, timeout_ms)) return 1;

    auto* src_mem = reinterpret_cast<uint8_t*>(t.getMem({coyote::CoyoteAllocType::HPF, n_bytes}));
    auto* dst_mem = reinterpret_cast<uint8_t*>(t.getMem({coyote::CoyoteAllocType::HPF, n_bytes}));
    if (!src_mem || !dst_mem) {
        std::cerr << "failed to allocate Coyote buffers\n";
        return 1;
    }

    std::memcpy(src_mem, payload.data(), payload.size());
    std::memset(dst_mem, 0, payload.size());

    coyote::localSg src_sg = {
        .addr = src_mem,
        .len = n_bytes,
        .stream = coyote::STRM_HOST,
        .dest = PEER_HOST_DEST,
    };
    coyote::localSg dst_sg = {
        .addr = dst_mem,
        .len = n_bytes,
        .stream = coyote::STRM_HOST,
        .dest = PEER_HOST_DEST,
    };

    t.clearCompleted();
    t.setCSR(beats, REG_TX_BURST);
    const uint64_t burst_readback = t.getCSR(REG_TX_BURST);
    if (burst_readback != beats) {
        std::cerr << "[FAIL] TX_BURST_BEATS CSR readback mismatch: wrote " << beats
                  << ", read " << burst_readback << "\n"
                  << "       This usually means the programmed bitstream does not contain the current peer-stream CSR logic.\n";
        return 1;
    }

    t.setCSR(CTRL_TX_START | CTRL_RX_ARM, REG_CTRL);
    const uint64_t ctrl_readback = t.getCSR(REG_CTRL);
    if ((ctrl_readback & (CTRL_TX_START | CTRL_RX_ARM)) != (CTRL_TX_START | CTRL_RX_ARM)) {
        std::cerr << "[FAIL] CTRL CSR readback mismatch: wrote 0x"
                  << std::hex << (CTRL_TX_START | CTRL_RX_ARM) << ", read 0x" << ctrl_readback
                  << std::dec << "\n";
        return 1;
    }

    t.invoke(coyote::CoyoteOper::LOCAL_TRANSFER, src_sg, dst_sg);

    if (!wait_for_completion(t, timeout)) {
        std::cerr << "[FAIL] timed out waiting for LOCAL_TRANSFER completion\n";
        print_status(t.getCSR(REG_STATUS));
        return 1;
    }

    const uint64_t status = wait_for_done_status(t, timeout);
    const uint64_t rx_beats = t.getCSR(REG_RX_BEATS);
    const uint64_t mismatches = t.getCSR(REG_RX_MISMATCH);

    std::cout << "[status]\n";
    print_status(status);
    std::cout << "[rx] beats=" << rx_beats << " mismatches=" << mismatches << "\n";

    bool ok = true;
    if (((status >> 0) & 1U) == 0 || ((status >> 1) & 1U) == 0 || ((status >> 2) & 1U) == 0) {
        std::cerr << "[FAIL] expected tx_done, rx_done, and peer_link_up\n";
        ok = false;
    }
    if (rx_beats != beats) {
        std::cerr << "[FAIL] expected " << beats << " RX beats, got " << rx_beats << "\n";
        ok = false;
    }
    if (mismatches != 0) {
        std::cerr << "[FAIL] hardware reported " << mismatches << " mismatches\n";
        ok = false;
    }
    if (!std::equal(payload.begin(), payload.end(), dst_mem)) {
        std::cerr << "[FAIL] destination buffer does not match expected counter pattern\n";
        ok = false;
    }

    t.setCSR(0, REG_CTRL);

    if (!ok) return 1;
    std::cout << "*** PASS: peer stream loopback completed with no mismatch ***\n";
    return 0;
}
