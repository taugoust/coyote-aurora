#include <chrono>
#include <cctype>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <vector>

#include <boost/program_options.hpp>

#include <helios/helios_protocol.h>
#include <helios/helios_qshell_protocol.h>
#include <helios/helios_transport_coyote.h>

namespace {

void require_hex_bytes(const std::string& value, const char* name) {
    std::string compact;
    for (const char c : value) {
        if (!std::isspace(static_cast<unsigned char>(c))) {
            compact.push_back(c);
        }
    }
    if (compact.rfind("0x", 0) == 0 || compact.rfind("0X", 0) == 0) {
        compact.erase(0, 2);
    }
    if (compact.empty() || (compact.size() % 2) != 0) {
        throw std::runtime_error(std::string(name) + " must contain complete bytes");
    }
    for (const char c : compact) {
        if (!std::isxdigit(static_cast<unsigned char>(c))) {
            throw std::runtime_error(std::string(name) + " contains a non-hexadecimal character");
        }
    }
}

std::size_t round_up(std::size_t value, std::size_t multiple) {
    return ((value + multiple - 1) / multiple) * multiple;
}

std::size_t helios_response_bytes_for_distance(int distance, const std::string& noise_model) {
    if (distance < 3 || (distance % 2) == 0) {
        throw std::runtime_error("distance must be an odd integer >= 3");
    }
    if (noise_model != "phenom" && noise_model != "circuit") {
        throw std::runtime_error("noise-model must be either 'phenom' or 'circuit'");
    }

    const int grid_width_x = distance + 1;
    const int grid_width_z = (distance - 1) / 2;
    const int grid_width_u = distance;

    const int ns_error_count_per_round = (grid_width_x - 1) * grid_width_z;
    const int ew_error_count_per_round = (grid_width_x - 1) * grid_width_z + 1;
    const int ud_error_count_per_round = grid_width_x * grid_width_z;

    int correction_bits_per_round =
        ns_error_count_per_round + ew_error_count_per_round + ud_error_count_per_round;

    if (noise_model == "circuit") {
        const int diag_ns_error_count_per_round = ((grid_width_x - 1) * grid_width_z) - grid_width_z;
        const int diag_ew_error_count_per_round = ((grid_width_x - 1) * grid_width_z) - (grid_width_z + 1);
        const int diag_hook_error_count_per_round = (grid_width_u > 3) ? grid_width_u - 1 : 0;
        correction_bits_per_round +=
            diag_ns_error_count_per_round + diag_ew_error_count_per_round + diag_hook_error_count_per_round;
    }

    const int correction_bytes_per_round = (correction_bits_per_round + 7) / 8;

    return 3 + static_cast<std::size_t>(grid_width_u) * correction_bytes_per_round;
}

} // namespace

int run_main(int argc, char* argv[]) {
    namespace po = boost::program_options;

    std::string input_hex;
    std::string input_file;
    std::string output_file;
    std::string expected_correction_hex;
    bool include_start = true;
    bool qshell_record = false;
    bool verbose = false;
    int timeout_ms = 1000;
    int distance = 3;
    std::string noise_model = "phenom";
    std::uint32_t context_id = 0;
    std::uint32_t round_id = 0;
    std::uint32_t schema_id = helios::qshell::schema_helios_phenom_syndrome;
    std::uint32_t source_endpoint_id = 0x12345678u;
    std::uint32_t peer_endpoint_id = 0x80000001u;
    std::uint32_t decoder_endpoint_id = 0;
    std::uint32_t route_capability_id = 1;
    std::uint32_t expected_route_version = 0;
    std::uint32_t record_sequence = 0;
    std::uint32_t flags = helios::qshell::flag_end_of_round;
    constexpr int COYOTE_HOST_STREAM_BEAT_BYTES = 64;
    int rx_window = 0;
    int device = 0;

    po::options_description opts("Aurora QShell peer runner options");
    opts.add_options()
        ("help,h", "Show help")
        ("input-hex", po::value<std::string>(&input_hex), "Measurement bytes as hex string")
        ("input-file", po::value<std::string>(&input_file), "Path to file containing raw measurement bytes")
        ("output-file", po::value<std::string>(&output_file), "Optional output file for raw RX bytes")
        ("expect-correction-hex", po::value<std::string>(&expected_correction_hex), "Require exact Helios correction payload bytes")
        ("no-start", po::bool_switch()->default_value(false), "Do not prepend START_DECODING_MSG")
        ("qshell", po::bool_switch(&qshell_record), "Wrap the native Helios request in a QSH2 record")
        ("context", po::value<std::uint32_t>(&context_id)->default_value(0), "QShell context id")
        ("round", po::value<std::uint32_t>(&round_id)->default_value(0), "QShell round id")
        ("schema", po::value<std::uint32_t>(&schema_id)->default_value(helios::qshell::schema_helios_phenom_syndrome), "QShell syndrome schema id")
        ("source-endpoint", po::value<std::uint32_t>(&source_endpoint_id)->default_value(0x12345678u), "Untrusted source id sent on the wire before Rose stamps it")
        ("peer-endpoint", po::value<std::uint32_t>(&peer_endpoint_id)->default_value(0x80000001u), "Authenticated Aurora endpoint expected in the correction destination")
        ("decoder-endpoint", po::value<std::uint32_t>(&decoder_endpoint_id)->default_value(0), "Expected correction producer endpoint id")
        ("route", po::value<std::uint32_t>(&route_capability_id)->default_value(1), "QShell route capability id")
        ("route-version", po::value<std::uint32_t>(&expected_route_version)->default_value(0), "Expected active route version")
        ("sequence", po::value<std::uint32_t>(&record_sequence)->default_value(0), "QShell request sequence")
        ("flags", po::value<std::uint32_t>(&flags)->default_value(helios::qshell::flag_end_of_round), "QShell flags")
        ("timeout-ms", po::value<int>(&timeout_ms)->default_value(1000), "Roundtrip timeout in milliseconds")
        ("distance,d", po::value<int>(&distance)->default_value(3), "Helios code distance; used to size the receive window")
        ("noise-model", po::value<std::string>(&noise_model)->default_value("phenom"), "Hardware noise model: phenom or circuit; used to size the receive window")
        ("rx-window", po::value<int>(&rx_window)->default_value(0), "Receive DMA window in bytes; 0 chooses a distance/noise-model-derived 64-byte-aligned window")
        ("device", po::value<int>(&device)->default_value(0), "Coyote device index used for /dev/coyote_fpga_<device>_v0")
        ("verbose,v", po::bool_switch(&verbose), "Enable verbose logging");

    po::variables_map vm;
    po::store(po::parse_command_line(argc, argv, opts), vm);
    po::notify(vm);

    if (vm.count("help")) {
        std::cout << opts << std::endl;
        return 0;
    }

    include_start = !vm["no-start"].as<bool>();

    if (!qshell_record) {
        throw std::runtime_error("the Aurora peer runner requires --qshell");
    }
    if (distance != 3 || noise_model != "phenom") {
        throw std::runtime_error("the deployed QShell migration package supports only d3 phenom");
    }
    if (device < 0) {
        throw std::runtime_error("Coyote device index must be non-negative");
    }
    if (source_endpoint_id == peer_endpoint_id) {
        throw std::runtime_error("source-endpoint must differ from peer-endpoint to prove Rose authentication stamping");
    }
    if (flags > 0xffffu) {
        throw std::runtime_error("QShell flags must fit in 16 bits");
    }

    const auto native_response_bytes = helios_response_bytes_for_distance(distance, noise_model);
    const auto expected_response_bytes = native_response_bytes +
        (qshell_record ? helios::qshell::record_header_bytes : 0);
    if (rx_window == 0) {
        rx_window = static_cast<int>(round_up(expected_response_bytes, COYOTE_HOST_STREAM_BEAT_BYTES));
    } else if (rx_window < 0) {
        throw std::runtime_error("rx-window must be non-negative");
    } else if (static_cast<std::size_t>(rx_window) < expected_response_bytes) {
        throw std::runtime_error("rx-window is smaller than the expected response for the selected distance");
    }

    std::vector<uint8_t> measurement_bytes;
    if (!input_file.empty()) {
        std::ifstream ifs(input_file, std::ios::binary);
        if (!ifs) throw std::runtime_error("Failed to open input file: " + input_file);
        measurement_bytes.assign(std::istreambuf_iterator<char>(ifs), std::istreambuf_iterator<char>());
    } else if (!input_hex.empty()) {
        require_hex_bytes(input_hex, "input-hex");
        measurement_bytes = helios::parse_hex_bytes(input_hex);
    } else {
        throw std::runtime_error("Provide either --input-hex or --input-file");
    }

    helios::HeliosDecodeRequest req;
    req.measurement_bytes = measurement_bytes;
    req.include_start_decoding = include_start;

    std::vector<std::uint8_t> tx;
    helios::qshell::RecordHeader qshell_header;
    if (qshell_record) {
        qshell_header.context_id = context_id;
        qshell_header.round_id = round_id;
        qshell_header.schema_id = schema_id;
        qshell_header.flags = static_cast<std::uint16_t>(flags);
        qshell_header.source_endpoint_id = source_endpoint_id;
        qshell_header.route_capability_id = route_capability_id;
        qshell_header.record_sequence = record_sequence;
        tx = helios::qshell::encode_request(qshell_header, req);
    } else {
        tx = helios::encode_request(req);
    }

    if (qshell_record && tx.size() > COYOTE_HOST_STREAM_BEAT_BYTES) {
        throw std::runtime_error("the initial QShell/Helios adapter accepts one 64-byte request beat");
    }

    if (verbose) {
        std::cout << "distance=" << distance
                  << " noise_model=" << noise_model
                  << " qshell=" << (qshell_record ? "yes" : "no")
                  << " expected_response_bytes=" << expected_response_bytes
                  << " rx_window=" << rx_window << "\n";
        std::cout << "TX bytes: " << tx.size() << "\n";
        std::cout << "TX[0:64]: " << helios::to_hex_string(tx, 64) << "\n";
    }

    helios::HeliosCoyoteTransport transport(
        0, static_cast<std::uint32_t>(device));
    const auto peer_status = transport.wait_for_peer_up(
        std::chrono::milliseconds(timeout_ms));
    if (verbose) {
        std::cout << "Aurora peer link is up; lanes=0x" << std::hex
                  << ((peer_status >> 3u) & 0xfu) << std::dec << "\n";
    }
    const auto rx = transport.roundtrip(
        tx,
        static_cast<std::size_t>(rx_window),
        std::chrono::milliseconds(timeout_ms),
        !qshell_record);

    if (verbose) {
        std::cout << "RX bytes: " << rx.size() << "\n";
        std::cout << "RX[0:64]: " << helios::to_hex_string(rx, 64) << "\n";
    }

    helios::HeliosDecodeResponse rsp;
    if (qshell_record) {
        auto expected_header = qshell_header;
        expected_header.source_endpoint_id = peer_endpoint_id;
        const auto qshell_rsp = helios::qshell::decode_response(
            rx, expected_header, decoder_endpoint_id, expected_route_version);
        if (qshell_rsp.header.payload_bytes != native_response_bytes) {
            throw std::runtime_error("QSH2 Helios response payload length does not match d3 phenom");
        }
        std::cout << "context=" << qshell_rsp.header.context_id
                  << " round=" << qshell_rsp.header.round_id
                  << " schema=" << qshell_rsp.header.schema_id
                  << " source=" << qshell_rsp.header.source_endpoint_id
                  << " destination=" << qshell_rsp.header.destination_endpoint_id
                  << " route=" << qshell_rsp.header.route_capability_id
                  << " route_version=" << qshell_rsp.header.route_version
                  << " sequence=" << qshell_rsp.header.record_sequence
                  << " abi=" << static_cast<unsigned>(qshell_rsp.header.abi_version)
                  << " flags=0x" << std::hex << qshell_rsp.header.flags
                  << std::dec << "\n";
        rsp = qshell_rsp.decoder;
        if (!expected_correction_hex.empty()) {
            require_hex_bytes(expected_correction_hex, "expect-correction-hex");
            const auto expected_correction =
                helios::parse_hex_bytes(expected_correction_hex);
            if (rsp.correction_bytes != expected_correction) {
                throw std::runtime_error("Helios correction payload does not match the expected oracle");
            }
        }
    } else {
        rsp = helios::decode_response(rx);
    }

    std::cout << "iteration_count=" << static_cast<unsigned>(rsp.iteration_count)
              << " cycle_count=" << rsp.cycle_count
              << " correction_bytes=" << rsp.correction_bytes.size() << "\n";

    if (!output_file.empty()) {
        std::ofstream ofs(output_file, std::ios::binary);
        if (!ofs) throw std::runtime_error("Failed to open output file: " + output_file);
        ofs.write(reinterpret_cast<const char*>(rx.data()), static_cast<std::streamsize>(rx.size()));
    }

    return 0;
}

int main(int argc, char* argv[]) {
    try {
        return run_main(argc, argv);
    } catch (const std::exception& error) {
        std::cerr << "aurora-qshell-peer: " << error.what() << "\n";
        return 1;
    }
}
