#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <vector>

#include <coyote/cThread.hpp>

namespace helios {

class HeliosCoyoteTransport {
public:
    explicit HeliosCoyoteTransport(
        int32_t vfpga_id = 0,
        std::uint32_t device = 0,
        bool use_hugepages = true);

    std::uint64_t wait_for_peer_up(std::chrono::milliseconds timeout);

    std::vector<uint8_t> roundtrip(
        const std::vector<uint8_t>& tx_bytes,
        std::size_t rx_window_bytes,
        std::chrono::milliseconds timeout,
        bool trim_trailing_zeros = true);

private:
    coyote::cThread thread_;
    uint8_t* src_mem_;
    uint8_t* dst_mem_;
    std::size_t capacity_;

    void ensure_capacity(std::size_t bytes);
};

} // namespace helios
