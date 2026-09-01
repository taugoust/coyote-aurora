#include <helios/helios_qshell_protocol.h>

#include <algorithm>
#include <cstddef>
#include <iterator>
#include <stdexcept>
#include <string>

namespace helios::qshell {
namespace {

constexpr std::uint8_t magic[4] = {'Q', 'S', 'H', '2'};

void append_u16_le(std::vector<std::uint8_t> &out, std::uint16_t value) {
  out.push_back(static_cast<std::uint8_t>(value & 0xffu));
  out.push_back(static_cast<std::uint8_t>((value >> 8u) & 0xffu));
}

void append_u32_le(std::vector<std::uint8_t> &out, std::uint32_t value) {
  out.push_back(static_cast<std::uint8_t>(value & 0xffu));
  out.push_back(static_cast<std::uint8_t>((value >> 8u) & 0xffu));
  out.push_back(static_cast<std::uint8_t>((value >> 16u) & 0xffu));
  out.push_back(static_cast<std::uint8_t>((value >> 24u) & 0xffu));
}

std::uint16_t read_u16_le(const std::vector<std::uint8_t> &bytes,
                          std::size_t offset) {
  return static_cast<std::uint16_t>(bytes.at(offset)) |
         static_cast<std::uint16_t>(
             static_cast<std::uint16_t>(bytes.at(offset + 1)) << 8u);
}

std::uint32_t read_u32_le(const std::vector<std::uint8_t> &bytes,
                          std::size_t offset) {
  return static_cast<std::uint32_t>(bytes.at(offset)) |
         (static_cast<std::uint32_t>(bytes.at(offset + 1)) << 8u) |
         (static_cast<std::uint32_t>(bytes.at(offset + 2)) << 16u) |
         (static_cast<std::uint32_t>(bytes.at(offset + 3)) << 24u);
}

RecordHeader decode_header(const std::vector<std::uint8_t> &bytes) {
  if (bytes.size() < record_header_bytes) {
    throw std::runtime_error(
        "QSH2 Helios response is shorter than its record header");
  }
  if (!std::equal(std::begin(magic), std::end(magic), bytes.begin())) {
    throw std::runtime_error("QSH2 Helios response has invalid magic");
  }
  if (bytes.at(4) != record_abi_version) {
    throw std::runtime_error(
        "Unsupported QShell record ABI in Helios response");
  }
  if (read_u16_le(bytes, 8) != record_header_bytes ||
      read_u16_le(bytes, 10) != 0) {
    throw std::runtime_error(
        "QSH2 Helios response has an invalid header layout");
  }

  RecordHeader header;
  header.abi_version = bytes.at(4);
  header.record_class = bytes.at(5);
  header.flags = read_u16_le(bytes, 6);
  header.payload_bytes = read_u32_le(bytes, 12);
  header.context_id = read_u32_le(bytes, 16);
  header.round_id = read_u32_le(bytes, 20);
  header.schema_id = read_u32_le(bytes, 24);
  header.source_endpoint_id = read_u32_le(bytes, 28);
  header.destination_endpoint_id = read_u32_le(bytes, 32);
  header.route_capability_id = read_u32_le(bytes, 36);
  header.route_version = read_u32_le(bytes, 40);
  header.record_sequence = read_u32_le(bytes, 44);
  return header;
}

void require_identity(bool condition, const char *field) {
  if (!condition) {
    throw std::runtime_error(
        std::string("QSH2 Helios response identity mismatch: ") + field);
  }
}

} // namespace

std::vector<std::uint8_t> encode_request(const RecordHeader &header,
                                         const HeliosDecodeRequest &request) {
  if (header.abi_version != record_abi_version ||
      header.record_class != record_class_syndrome) {
    throw std::runtime_error(
        "Unsupported QShell record type for Helios request");
  }
  if (header.schema_id != schema_helios_phenom_syndrome) {
    throw std::runtime_error(
        "Helios QShell request uses the wrong syndrome schema");
  }
  if (header.flags != flag_end_of_round) {
    throw std::runtime_error("Helios QShell request must end the round");
  }
  if (header.destination_endpoint_id != 0) {
    throw std::runtime_error(
        "QShell ingress destination endpoint must be zero");
  }
  if (header.route_version != 0) {
    throw std::runtime_error("QShell ingress route version must be zero");
  }

  const auto native_request = helios::encode_request(request);
  if (native_request.size() > record_payload_capacity) {
    throw std::runtime_error(
        "Helios d3 request exceeds the one-beat QSH2 payload capacity");
  }

  std::vector<std::uint8_t> bytes;
  bytes.reserve(record_header_bytes + native_request.size());
  bytes.insert(bytes.end(), std::begin(magic), std::end(magic));
  bytes.push_back(record_abi_version);
  bytes.push_back(record_class_syndrome);
  append_u16_le(bytes, header.flags);
  append_u16_le(bytes, static_cast<std::uint16_t>(record_header_bytes));
  append_u16_le(bytes, 0);
  append_u32_le(bytes, static_cast<std::uint32_t>(native_request.size()));
  append_u32_le(bytes, header.context_id);
  append_u32_le(bytes, header.round_id);
  append_u32_le(bytes, header.schema_id);
  append_u32_le(bytes, header.source_endpoint_id);
  append_u32_le(bytes, header.destination_endpoint_id);
  append_u32_le(bytes, header.route_capability_id);
  append_u32_le(bytes, header.route_version);
  append_u32_le(bytes, header.record_sequence);
  bytes.insert(bytes.end(), native_request.begin(), native_request.end());
  return bytes;
}

DecodeResponse decode_response(const std::vector<std::uint8_t> &bytes,
                               const RecordHeader &expected_request,
                               std::uint32_t expected_decoder_endpoint_id,
                               std::uint32_t expected_route_version) {
  DecodeResponse response;
  response.header = decode_header(bytes);

  if (response.header.record_class != record_class_correction) {
    throw std::runtime_error("QSH2 Helios response is not a correction record");
  }
  if (response.header.schema_id != schema_helios_sparse_correction) {
    throw std::runtime_error(
        "QSH2 Helios response uses the wrong correction schema");
  }
  if ((response.header.flags & ~flag_end_of_round) != 0) {
    throw std::runtime_error("QSH2 Helios response contains unsupported flags");
  }
  if (response.header.payload_bytes > record_payload_capacity ||
      response.header.payload_bytes > bytes.size() - record_header_bytes) {
    throw std::runtime_error("QSH2 Helios response payload length is invalid");
  }

  require_identity(response.header.context_id == expected_request.context_id,
                   "context_id");
  require_identity(response.header.round_id == expected_request.round_id,
                   "round_id");
  require_identity(response.header.source_endpoint_id ==
                       expected_decoder_endpoint_id,
                   "source_endpoint_id");
  require_identity(response.header.destination_endpoint_id ==
                       expected_request.source_endpoint_id,
                   "destination_endpoint_id");
  require_identity(response.header.route_capability_id ==
                       expected_request.route_capability_id,
                   "route_capability_id");
  require_identity(response.header.route_version == expected_route_version,
                   "route_version");
  require_identity(response.header.flags == expected_request.flags, "flags");
  require_identity(response.header.record_sequence == 0, "record_sequence");

  const auto payload_end = record_header_bytes + response.header.payload_bytes;
  const std::vector<std::uint8_t> native_response(
      bytes.begin() + static_cast<std::ptrdiff_t>(record_header_bytes),
      bytes.begin() + static_cast<std::ptrdiff_t>(payload_end));
  response.decoder = helios::decode_response(native_response);
  return response;
}

} // namespace helios::qshell
