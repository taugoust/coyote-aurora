#include <chrono>
#include <cctype>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include <boost/program_options.hpp>

#include <aurora/qsh2_record.h>
#include <helios/helios_transport_coyote.h>

namespace {

std::vector<std::uint8_t> parse_hex_bytes(const std::string& value) {
    std::string compact;
    for (const char character : value) {
        if (!std::isspace(static_cast<unsigned char>(character))) {
            compact.push_back(character);
        }
    }
    if (compact.rfind("0x", 0) == 0 || compact.rfind("0X", 0) == 0) {
        compact.erase(0, 2);
    }
    if ((compact.size() % 2) != 0) {
        throw std::runtime_error("payload-hex must contain complete bytes");
    }

    std::vector<std::uint8_t> bytes;
    bytes.reserve(compact.size() / 2);
    for (std::size_t offset = 0; offset < compact.size(); offset += 2) {
        if (!std::isxdigit(static_cast<unsigned char>(compact.at(offset))) ||
            !std::isxdigit(static_cast<unsigned char>(compact.at(offset + 1)))) {
            throw std::runtime_error("payload-hex contains a non-hexadecimal character");
        }
        bytes.push_back(static_cast<std::uint8_t>(
            std::stoul(compact.substr(offset, 2), nullptr, 16)));
    }
    return bytes;
}

} // namespace

int run_main(int argc, char* argv[]) {
    namespace po = boost::program_options;

    std::string payload_hex = "a55a00ff11223344";
    std::uint32_t context_id = 4660;
    std::uint32_t round_id = 1;
    std::uint32_t wire_source_endpoint_id = 0x12345678u;
    std::uint32_t peer_endpoint_id = 0x80000001u;
    std::uint32_t service_endpoint_id = 20;
    std::uint32_t route_capability_id = 1;
    std::uint32_t expected_route_version = 1;
    std::uint32_t record_sequence = 0;
    int timeout_ms = 2000;
    int device = 0;
    bool verbose = false;

    po::options_description options("Aurora QShell opaque-loopback options");
    options.add_options()
        ("help,h", "Show help")
        ("payload-hex", po::value<std::string>(&payload_hex)->default_value(payload_hex),
            "Opaque payload bytes; at most 16 bytes")
        ("context", po::value<std::uint32_t>(&context_id)->default_value(context_id),
            "QShell context id")
        ("round", po::value<std::uint32_t>(&round_id)->default_value(round_id),
            "QShell round id")
        ("wire-source", po::value<std::uint32_t>(&wire_source_endpoint_id)->default_value(wire_source_endpoint_id),
            "Untrusted source id transmitted before Rose peer stamping")
        ("peer-endpoint", po::value<std::uint32_t>(&peer_endpoint_id)->default_value(peer_endpoint_id),
            "Authenticated Aurora peer endpoint")
        ("service-endpoint", po::value<std::uint32_t>(&service_endpoint_id)->default_value(service_endpoint_id),
            "Expected loopback service endpoint")
        ("route", po::value<std::uint32_t>(&route_capability_id)->default_value(route_capability_id),
            "QShell route capability id")
        ("route-version", po::value<std::uint32_t>(&expected_route_version)->default_value(expected_route_version),
            "Expected active route version in the correction")
        ("sequence", po::value<std::uint32_t>(&record_sequence)->default_value(record_sequence),
            "Ingress syndrome sequence")
        ("timeout-ms", po::value<int>(&timeout_ms)->default_value(timeout_ms),
            "Link and round-trip timeout")
        ("device", po::value<int>(&device)->default_value(device),
            "Coyote device index")
        ("verbose,v", po::bool_switch(&verbose), "Print transmitted and received identity");

    po::variables_map arguments;
    po::store(po::parse_command_line(argc, argv, options), arguments);
    po::notify(arguments);
    if (arguments.count("help")) {
        std::cout << options << '\n';
        return 0;
    }
    if (device < 0 || timeout_ms <= 0) {
        throw std::runtime_error("device must be non-negative and timeout-ms must be positive");
    }
    if (wire_source_endpoint_id == peer_endpoint_id) {
        throw std::runtime_error(
            "wire-source must differ from peer-endpoint to prove source stamping");
    }
    if (route_capability_id == 0 || expected_route_version == 0) {
        throw std::runtime_error(
            "route capability and expected route version must be nonzero");
    }
    if (record_sequence != 0) {
        throw std::runtime_error(
            "the one-record opaque-loopback oracle requires sequence zero");
    }

    const auto payload = parse_hex_bytes(payload_hex);
    const auto payload_capacity =
        ::qshell::abi::beat_bytes - ::qshell::abi::header_bytes;
    if (payload.size() > payload_capacity) {
        throw std::runtime_error("payload exceeds the one-beat QSH2 capacity");
    }

    aurora::qsh2::RecordHeader request;
    request.context_id = context_id;
    request.round_id = round_id;
    request.schema_id = ::qshell::abi::schema_opaque_loopback;
    request.flags = ::qshell::abi::flag_end_of_round;
    request.source_endpoint_id = wire_source_endpoint_id;
    request.destination_endpoint_id = 0;
    request.route_capability_id = route_capability_id;
    request.route_version = 0;
    request.record_sequence = record_sequence;
    request.record_class = static_cast<std::uint8_t>(
        ::qshell::abi::record_class::syndrome);

    const auto tx = aurora::qsh2::encode_record(request, payload);
    if (tx.size() > ::qshell::abi::beat_bytes) {
        throw std::runtime_error("opaque-loopback request is not one complete QSH2 beat");
    }

    helios::HeliosCoyoteTransport transport(
        0,
        static_cast<std::uint32_t>(device));
    const auto peer_status = transport.wait_for_peer_up(
        std::chrono::milliseconds(timeout_ms));
    const auto rx = transport.roundtrip(
        tx,
        ::qshell::abi::beat_bytes,
        std::chrono::milliseconds(timeout_ms),
        false);
    const auto response = aurora::qsh2::decode_record(rx);
    aurora::qsh2::validate_opaque_loopback_response(
        response,
        request,
        payload,
        service_endpoint_id,
        peer_endpoint_id,
        expected_route_version);

    if (verbose) {
        std::cout << "peer_status=0x" << std::hex << peer_status << std::dec
                  << " request_source=" << request.source_endpoint_id
                  << " response_source=" << response.header.source_endpoint_id
                  << " response_destination="
                  << response.header.destination_endpoint_id << '\n';
    }
    std::cout << "QSH2_OPAQUE_LOOPBACK_PASS"
              << " context=" << response.header.context_id
              << " round=" << response.header.round_id
              << " capability=" << response.header.route_capability_id
              << " route_version=" << response.header.route_version
              << " payload_bytes=" << response.payload.size() << '\n';
    return 0;
}

int main(int argc, char* argv[]) {
    try {
        return run_main(argc, argv);
    } catch (const std::exception& error) {
        std::cerr << "aurora-qshell-loopback: " << error.what() << '\n';
        return 1;
    }
}
