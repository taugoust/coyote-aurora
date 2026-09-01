#include <helios/helios_protocol.h>

#include <algorithm>
#include <cctype>
#include <iomanip>
#include <sstream>
#include <string>

namespace helios {

std::vector<uint8_t> encode_request(const HeliosDecodeRequest& req) {
    std::vector<uint8_t> tx;
    tx.reserve(req.measurement_bytes.size() + 2);

    if (req.include_start_decoding) {
        tx.push_back(START_DECODING_MSG);
    }
    tx.push_back(MEASUREMENT_DATA_HEADER);
    tx.insert(tx.end(), req.measurement_bytes.begin(), req.measurement_bytes.end());
    return tx;
}

HeliosDecodeResponse decode_response(const std::vector<uint8_t>& rx_bytes) {
    if (rx_bytes.size() < 3) {
        throw std::runtime_error("Helios response too short: need at least 3 bytes");
    }

    HeliosDecodeResponse out;
    out.iteration_count = rx_bytes[0];
    out.cycle_count = static_cast<uint16_t>(rx_bytes[1] << 8) | static_cast<uint16_t>(rx_bytes[2]);
    out.correction_bytes.assign(rx_bytes.begin() + 3, rx_bytes.end());
    return out;
}

std::vector<uint8_t> parse_hex_bytes(const std::string& hex) {
    std::string s;
    s.reserve(hex.size());
    for (char c : hex) {
        if (!std::isspace(static_cast<unsigned char>(c))) {
            s.push_back(c);
        }
    }

    if (s.rfind("0x", 0) == 0 || s.rfind("0X", 0) == 0) {
        s = s.substr(2);
    }

    if (s.empty() || (s.size() % 2) != 0) {
        throw std::runtime_error("Hex input must contain an even number of digits");
    }

    std::vector<uint8_t> out;
    out.reserve(s.size() / 2);
    for (std::size_t i = 0; i < s.size(); i += 2) {
        const auto byte = static_cast<uint8_t>(std::stoul(s.substr(i, 2), nullptr, 16));
        out.push_back(byte);
    }
    return out;
}

std::string to_hex_string(const std::vector<uint8_t>& bytes, std::size_t max_bytes) {
    const std::size_t n = (max_bytes == 0) ? bytes.size() : std::min(bytes.size(), max_bytes);
    std::ostringstream oss;
    for (std::size_t i = 0; i < n; ++i) {
        if (i) oss << ' ';
        oss << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(bytes[i]);
    }
    if (n < bytes.size()) {
        oss << " ...";
    }
    return oss.str();
}

} // namespace helios
