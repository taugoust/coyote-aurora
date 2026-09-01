#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include <helios/helios_protocol.h>

namespace helios::qshell {

constexpr std::size_t record_header_bytes = 48;
constexpr std::size_t record_payload_capacity = 16;
constexpr std::uint8_t record_abi_version = 2;
constexpr std::uint8_t record_class_syndrome = 1;
constexpr std::uint8_t record_class_correction = 2;
constexpr std::uint16_t flag_end_of_round = 0x0001;
constexpr std::uint32_t schema_helios_phenom_syndrome = 0x00010001;
constexpr std::uint32_t schema_helios_sparse_correction = 0x00010002;

struct RecordHeader {
  std::uint32_t context_id = 0;
  std::uint32_t round_id = 0;
  std::uint32_t schema_id = schema_helios_phenom_syndrome;
  std::uint16_t flags = flag_end_of_round;
  std::uint32_t source_endpoint_id = 0;
  std::uint32_t destination_endpoint_id = 0;
  std::uint32_t route_capability_id = 0;
  std::uint32_t route_version = 0;
  std::uint32_t record_sequence = 0;
  std::uint8_t abi_version = record_abi_version;
  std::uint8_t record_class = record_class_syndrome;
  std::uint32_t payload_bytes = 0;
};

struct DecodeResponse {
  RecordHeader header;
  HeliosDecodeResponse decoder;
};

std::vector<std::uint8_t> encode_request(const RecordHeader &header,
                                         const HeliosDecodeRequest &request);

DecodeResponse decode_response(const std::vector<std::uint8_t> &bytes,
                               const RecordHeader &expected_request,
                               std::uint32_t expected_decoder_endpoint_id,
                               std::uint32_t expected_route_version);

} // namespace helios::qshell
