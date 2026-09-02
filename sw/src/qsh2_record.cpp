#include <aurora/qsh2_record.h>

#include <algorithm>
#include <cstddef>
#include <limits>
#include <stdexcept>
#include <string>

namespace aurora::qsh2 {
namespace {

void write_u16_le(
    std::vector<std::uint8_t>& bytes,
    std::size_t offset,
    std::uint16_t value) {
    bytes.at(offset) = static_cast<std::uint8_t>(value & 0xffu);
    bytes.at(offset + 1) = static_cast<std::uint8_t>((value >> 8u) & 0xffu);
}

void write_u32_le(
    std::vector<std::uint8_t>& bytes,
    std::size_t offset,
    std::uint32_t value) {
    bytes.at(offset) = static_cast<std::uint8_t>(value & 0xffu);
    bytes.at(offset + 1) = static_cast<std::uint8_t>((value >> 8u) & 0xffu);
    bytes.at(offset + 2) = static_cast<std::uint8_t>((value >> 16u) & 0xffu);
    bytes.at(offset + 3) = static_cast<std::uint8_t>((value >> 24u) & 0xffu);
}

std::uint16_t read_u16_le(
    const std::vector<std::uint8_t>& bytes,
    std::size_t offset) {
    return static_cast<std::uint16_t>(bytes.at(offset)) |
        static_cast<std::uint16_t>(
            static_cast<std::uint16_t>(bytes.at(offset + 1)) << 8u);
}

std::uint32_t read_u32_le(
    const std::vector<std::uint8_t>& bytes,
    std::size_t offset) {
    return static_cast<std::uint32_t>(bytes.at(offset)) |
        (static_cast<std::uint32_t>(bytes.at(offset + 1)) << 8u) |
        (static_cast<std::uint32_t>(bytes.at(offset + 2)) << 16u) |
        (static_cast<std::uint32_t>(bytes.at(offset + 3)) << 24u);
}

bool known_record_class(std::uint8_t value) {
    using ::qshell::abi::record_class;
    return value == static_cast<std::uint8_t>(record_class::syndrome) ||
        value == static_cast<std::uint8_t>(record_class::correction) ||
        value == static_cast<std::uint8_t>(record_class::control) ||
        value == static_cast<std::uint8_t>(record_class::error);
}

void validate_flags(std::uint8_t record_class_value, std::uint16_t flags) {
    using namespace ::qshell::abi;

    if ((flags & static_cast<std::uint16_t>(~known_flags)) != 0) {
        throw std::runtime_error("QSH2 record contains unknown flags");
    }
    const auto type = static_cast<record_class>(record_class_value);
    const std::uint16_t allowed =
        type == record_class::control
            ? flag_control_response
            : (type == record_class::syndrome || type == record_class::correction)
                ? flag_end_of_round
                : 0;
    if ((flags & static_cast<std::uint16_t>(~allowed)) != 0) {
        throw std::runtime_error("QSH2 flags are invalid for the record class");
    }
}

void require_identity(bool condition, const char* field) {
    if (!condition) {
        throw std::runtime_error(
            std::string("QSH2 opaque-loopback identity mismatch: ") + field);
    }
}

} // namespace

std::vector<std::uint8_t> encode_record(
    const RecordHeader& header,
    const std::vector<std::uint8_t>& payload) {
    using namespace ::qshell::abi;

    if (header.abi_version != version) {
        throw std::runtime_error("unsupported QSH2 ABI version");
    }
    if (!known_record_class(header.record_class)) {
        throw std::runtime_error("unknown QSH2 record class");
    }
    validate_flags(header.record_class, header.flags);
    if (payload.size() > std::numeric_limits<std::uint32_t>::max()) {
        throw std::runtime_error("QSH2 payload exceeds its encoded length field");
    }

    std::vector<std::uint8_t> bytes(header_bytes + payload.size(), 0);
    write_u32_le(bytes, offset::magic, magic);
    bytes.at(offset::abi_version) = header.abi_version;
    bytes.at(offset::record_class) = header.record_class;
    write_u16_le(bytes, offset::flags, header.flags);
    write_u16_le(
        bytes,
        offset::header_bytes,
        static_cast<std::uint16_t>(header_bytes));
    write_u32_le(
        bytes,
        offset::payload_bytes,
        static_cast<std::uint32_t>(payload.size()));
    write_u32_le(bytes, offset::context_id, header.context_id);
    write_u32_le(bytes, offset::round_id, header.round_id);
    write_u32_le(bytes, offset::schema_id, header.schema_id);
    write_u32_le(bytes, offset::source_endpoint_id, header.source_endpoint_id);
    write_u32_le(
        bytes,
        offset::destination_endpoint_id,
        header.destination_endpoint_id);
    write_u32_le(
        bytes,
        offset::route_capability_id,
        header.route_capability_id);
    write_u32_le(bytes, offset::route_version, header.route_version);
    write_u32_le(bytes, offset::record_sequence, header.record_sequence);
    std::copy(payload.begin(), payload.end(), bytes.begin() + header_bytes);
    return bytes;
}

Record decode_record(const std::vector<std::uint8_t>& bytes) {
    using namespace ::qshell::abi;

    if (bytes.size() < header_bytes) {
        throw std::runtime_error("QSH2 record is shorter than its header");
    }
    if (read_u32_le(bytes, offset::magic) != magic) {
        throw std::runtime_error("QSH2 record has invalid magic");
    }
    if (bytes.at(offset::abi_version) != version) {
        throw std::runtime_error("unsupported QSH2 ABI version");
    }
    if (!known_record_class(bytes.at(offset::record_class))) {
        throw std::runtime_error("unknown QSH2 record class");
    }
    if (read_u16_le(bytes, offset::header_bytes) != header_bytes ||
        read_u16_le(bytes, offset::reserved) != 0) {
        throw std::runtime_error("QSH2 record has an invalid header layout");
    }

    Record record;
    record.header.abi_version = bytes.at(offset::abi_version);
    record.header.record_class = bytes.at(offset::record_class);
    record.header.flags = read_u16_le(bytes, offset::flags);
    record.header.payload_bytes = read_u32_le(bytes, offset::payload_bytes);
    record.header.context_id = read_u32_le(bytes, offset::context_id);
    record.header.round_id = read_u32_le(bytes, offset::round_id);
    record.header.schema_id = read_u32_le(bytes, offset::schema_id);
    record.header.source_endpoint_id =
        read_u32_le(bytes, offset::source_endpoint_id);
    record.header.destination_endpoint_id =
        read_u32_le(bytes, offset::destination_endpoint_id);
    record.header.route_capability_id =
        read_u32_le(bytes, offset::route_capability_id);
    record.header.route_version = read_u32_le(bytes, offset::route_version);
    record.header.record_sequence =
        read_u32_le(bytes, offset::record_sequence);

    validate_flags(record.header.record_class, record.header.flags);
    if (record.header.payload_bytes > bytes.size() - header_bytes) {
        throw std::runtime_error("QSH2 record payload length exceeds available bytes");
    }
    const auto payload_end = header_bytes + record.header.payload_bytes;
    record.payload.assign(bytes.begin() + header_bytes, bytes.begin() + payload_end);
    return record;
}

void validate_opaque_loopback_response(
    const Record& response,
    const RecordHeader& request,
    const std::vector<std::uint8_t>& request_payload,
    std::uint32_t expected_service_endpoint_id,
    std::uint32_t expected_peer_endpoint_id,
    std::uint32_t expected_route_version) {
    using namespace ::qshell::abi;

    require_identity(
        request.record_class == static_cast<std::uint8_t>(record_class::syndrome),
        "request.record_class");
    require_identity(request.schema_id == schema_opaque_loopback, "request.schema_id");
    require_identity(request.route_version == 0, "request.route_version");
    require_identity(
        response.header.record_class ==
            static_cast<std::uint8_t>(record_class::correction),
        "record_class");
    require_identity(response.header.schema_id == schema_opaque_loopback, "schema_id");
    require_identity(response.header.context_id == request.context_id, "context_id");
    require_identity(response.header.round_id == request.round_id, "round_id");
    require_identity(response.header.flags == request.flags, "flags");
    require_identity(
        response.header.source_endpoint_id == expected_service_endpoint_id,
        "source_endpoint_id");
    require_identity(
        response.header.destination_endpoint_id == expected_peer_endpoint_id,
        "destination_endpoint_id");
    require_identity(
        response.header.route_capability_id == request.route_capability_id,
        "route_capability_id");
    require_identity(
        response.header.route_version == expected_route_version,
        "route_version");
    require_identity(response.header.record_sequence == 0, "record_sequence");
    require_identity(response.payload == request_payload, "payload");
}

} // namespace aurora::qsh2
