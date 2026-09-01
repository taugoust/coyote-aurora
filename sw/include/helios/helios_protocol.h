#pragma once

#include <cstdint>
#include <stdexcept>
#include <vector>
#include <string>

namespace helios {

constexpr uint8_t START_DECODING_MSG = 0x01;
constexpr uint8_t MEASUREMENT_DATA_HEADER = 0x02;

struct HeliosDecodeRequest {
    std::vector<uint8_t> measurement_bytes;
    bool include_start_decoding = true;
};

struct HeliosDecodeResponse {
    uint8_t iteration_count = 0;
    uint16_t cycle_count = 0;
    std::vector<uint8_t> correction_bytes;
};

std::vector<uint8_t> encode_request(const HeliosDecodeRequest& req);
HeliosDecodeResponse decode_response(const std::vector<uint8_t>& rx_bytes);

std::vector<uint8_t> parse_hex_bytes(const std::string& hex);
std::string to_hex_string(const std::vector<uint8_t>& bytes, std::size_t max_bytes = 0);

} // namespace helios
