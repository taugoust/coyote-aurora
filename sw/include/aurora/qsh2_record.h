#pragma once

#include <cstdint>
#include <vector>

#include <qshell/qshell_abi_generated.hpp>

namespace aurora::qsh2 {

struct RecordHeader {
    std::uint32_t context_id = 0;
    std::uint32_t round_id = 0;
    std::uint32_t schema_id = ::qshell::abi::schema_helios_phenom_syndrome;
    std::uint16_t flags = ::qshell::abi::flag_end_of_round;
    std::uint32_t source_endpoint_id = 0;
    std::uint32_t destination_endpoint_id = 0;
    std::uint32_t route_capability_id = 0;
    std::uint32_t route_version = 0;
    std::uint32_t record_sequence = 0;
    std::uint8_t abi_version = ::qshell::abi::version;
    std::uint8_t record_class =
        static_cast<std::uint8_t>(::qshell::abi::record_class::syndrome);
    std::uint32_t payload_bytes = 0;
};

struct Record {
    RecordHeader header;
    std::vector<std::uint8_t> payload;
};

std::vector<std::uint8_t> encode_record(
    const RecordHeader& header,
    const std::vector<std::uint8_t>& payload);

Record decode_record(const std::vector<std::uint8_t>& bytes);

void validate_opaque_loopback_response(
    const Record& response,
    const RecordHeader& request,
    const std::vector<std::uint8_t>& request_payload,
    std::uint32_t expected_service_endpoint_id,
    std::uint32_t expected_peer_endpoint_id,
    std::uint32_t expected_route_version);

} // namespace aurora::qsh2
