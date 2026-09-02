#include <helios/helios_qshell_protocol.h>

#include <stdexcept>
#include <string>

namespace helios::qshell {
namespace {

void require_identity(bool condition, const char* field) {
    if (!condition) {
        throw std::runtime_error(
            std::string("QSH2 Helios response identity mismatch: ") + field);
    }
}

} // namespace

std::vector<std::uint8_t> encode_request(
    const RecordHeader& header,
    const HeliosDecodeRequest& request) {
    if (header.abi_version != record_abi_version ||
        header.record_class != record_class_syndrome) {
        throw std::runtime_error("Unsupported QShell record type for Helios request");
    }
    if (header.schema_id != schema_helios_phenom_syndrome) {
        throw std::runtime_error("Helios QShell request uses the wrong syndrome schema");
    }
    if (header.flags != flag_end_of_round) {
        throw std::runtime_error("Helios QShell request must end the round");
    }
    if (header.destination_endpoint_id != 0) {
        throw std::runtime_error("QShell ingress destination endpoint must be zero");
    }
    if (header.route_version != 0) {
        throw std::runtime_error("QShell ingress route version must be zero");
    }

    const auto native_request = helios::encode_request(request);
    if (native_request.size() > record_payload_capacity) {
        throw std::runtime_error(
            "Helios d3 request exceeds the one-beat QSH2 payload capacity");
    }
    return aurora::qsh2::encode_record(header, native_request);
}

DecodeResponse decode_response(
    const std::vector<std::uint8_t>& bytes,
    const RecordHeader& expected_request,
    std::uint32_t expected_decoder_endpoint_id,
    std::uint32_t expected_route_version) {
    const auto record = aurora::qsh2::decode_record(bytes);
    DecodeResponse response;
    response.header = record.header;

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
    if (response.header.payload_bytes > record_payload_capacity) {
        throw std::runtime_error("QSH2 Helios response payload length is invalid");
    }

    require_identity(
        response.header.context_id == expected_request.context_id,
        "context_id");
    require_identity(
        response.header.round_id == expected_request.round_id,
        "round_id");
    require_identity(
        response.header.source_endpoint_id == expected_decoder_endpoint_id,
        "source_endpoint_id");
    require_identity(
        response.header.destination_endpoint_id ==
            expected_request.source_endpoint_id,
        "destination_endpoint_id");
    require_identity(
        response.header.route_capability_id ==
            expected_request.route_capability_id,
        "route_capability_id");
    require_identity(
        response.header.route_version == expected_route_version,
        "route_version");
    require_identity(response.header.flags == expected_request.flags, "flags");
    require_identity(response.header.record_sequence == 0, "record_sequence");

    response.decoder = helios::decode_response(record.payload);
    return response;
}

} // namespace helios::qshell
