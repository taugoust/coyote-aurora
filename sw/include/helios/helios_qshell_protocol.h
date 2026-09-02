#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include <aurora/qsh2_record.h>
#include <helios/helios_protocol.h>

namespace helios::qshell {

inline constexpr std::size_t record_header_bytes = ::qshell::abi::header_bytes;
inline constexpr std::size_t record_payload_capacity =
    ::qshell::abi::beat_bytes - ::qshell::abi::header_bytes;
inline constexpr std::uint8_t record_abi_version = ::qshell::abi::version;
inline constexpr std::uint8_t record_class_syndrome =
    static_cast<std::uint8_t>(::qshell::abi::record_class::syndrome);
inline constexpr std::uint8_t record_class_correction =
    static_cast<std::uint8_t>(::qshell::abi::record_class::correction);
inline constexpr std::uint16_t flag_end_of_round =
    ::qshell::abi::flag_end_of_round;
inline constexpr std::uint32_t schema_helios_phenom_syndrome =
    ::qshell::abi::schema_helios_phenom_syndrome;
inline constexpr std::uint32_t schema_helios_sparse_correction =
    ::qshell::abi::schema_helios_sparse_correction;

using RecordHeader = aurora::qsh2::RecordHeader;

struct DecodeResponse {
    RecordHeader header;
    HeliosDecodeResponse decoder;
};

std::vector<std::uint8_t> encode_request(
    const RecordHeader& header,
    const HeliosDecodeRequest& request);

DecodeResponse decode_response(
    const std::vector<std::uint8_t>& bytes,
    const RecordHeader& expected_request,
    std::uint32_t expected_decoder_endpoint_id,
    std::uint32_t expected_route_version);

} // namespace helios::qshell
