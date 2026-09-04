#include <iostream>
#include <stdexcept>
#include <vector>

#include <aurora/qsh2_record.h>
#include <helios/helios_protocol.h>
#include <helios/helios_qshell_protocol.h>

int main() {
  helios::HeliosDecodeRequest req;
  req.include_start_decoding = true;
  req.measurement_bytes = {0xaa, 0x55, 0x12};

  const auto tx = helios::encode_request(req);
  const std::vector<uint8_t> expected_tx = {0x01, 0x02, 0xaa, 0x55, 0x12};
  if (tx != expected_tx) {
    std::cerr << "encode_request selftest failed\n";
    return 1;
  }

  const std::vector<uint8_t> rx = {0x09, 0x01, 0x23, 0xde, 0xad};
  const auto rsp = helios::decode_response(rx);
  if (rsp.iteration_count != 0x09 || rsp.cycle_count != 0x0123 ||
      rsp.correction_bytes != std::vector<uint8_t>({0xde, 0xad})) {
    std::cerr << "decode_response selftest failed\n";
    return 1;
  }

  helios::qshell::RecordHeader header;
  header.context_id = 0x12345678;
  header.round_id = 0x89abcdef;
  header.source_endpoint_id = 0x11223344;
  header.destination_endpoint_id = 0;
  header.route_capability_id = 0xaabbccdd;
  header.record_sequence = 0x01020304;

  const auto qshell_tx = helios::qshell::encode_request(header, req);
  const std::vector<uint8_t> expected_qshell_tx = {
      0x51, 0x53, 0x48, 0x32, 0x02, 0x01, 0x01, 0x00, 0x30, 0x00, 0x00,
      0x00, 0x05, 0x00, 0x00, 0x00, 0x78, 0x56, 0x34, 0x12, 0xef, 0xcd,
      0xab, 0x89, 0x01, 0x00, 0x01, 0x00, 0x44, 0x33, 0x22, 0x11, 0x00,
      0x00, 0x00, 0x00, 0xdd, 0xcc, 0xbb, 0xaa, 0x00, 0x00, 0x00, 0x00,
      0x04, 0x03, 0x02, 0x01, 0x01, 0x02, 0xaa, 0x55, 0x12,
  };
  if (qshell_tx != expected_qshell_tx) {
    std::cerr << "QSH2 encode_request selftest failed\n";
    return 1;
  }

  // The declared payload includes a valid zero-valued final correction byte.
  // Extra bytes model the zero-filled Coyote receive window and are ignored.
  const std::vector<uint8_t> qshell_rx = {
      0x51, 0x53, 0x48, 0x32, 0x02, 0x02, 0x01, 0x00, 0x30, 0x00, 0x00,
      0x00, 0x05, 0x00, 0x00, 0x00, 0x78, 0x56, 0x34, 0x12, 0xef, 0xcd,
      0xab, 0x89, 0x02, 0x00, 0x01, 0x00, 0x88, 0x77, 0x66, 0x55, 0x44,
      0x33, 0x22, 0x11, 0xdd, 0xcc, 0xbb, 0xaa, 0x09, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x09, 0x01, 0x23, 0xde, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  };
  const auto qshell_rsp =
      helios::qshell::decode_response(qshell_rx, header, 0x55667788, 9);
  if (qshell_rsp.header.context_id != header.context_id ||
      qshell_rsp.header.round_id != header.round_id ||
      qshell_rsp.header.schema_id !=
          helios::qshell::schema_helios_sparse_correction ||
      qshell_rsp.header.source_endpoint_id != 0x55667788 ||
      qshell_rsp.header.destination_endpoint_id != header.source_endpoint_id ||
      qshell_rsp.header.route_capability_id != header.route_capability_id ||
      qshell_rsp.header.route_version != 9 ||
      qshell_rsp.header.abi_version != helios::qshell::record_abi_version ||
      qshell_rsp.decoder.iteration_count != 0x09 ||
      qshell_rsp.decoder.cycle_count != 0x0123 ||
      qshell_rsp.decoder.correction_bytes !=
          std::vector<uint8_t>({0xde, 0x00})) {
    std::cerr << "QSH2 decode_response selftest failed\n";
    return 1;
  }

  auto wrong_header = header;
  wrong_header.context_id++;
  try {
    (void)helios::qshell::decode_response(qshell_rx, wrong_header, 0x55667788,
                                          9);
    std::cerr << "QSH2 identity mismatch was accepted\n";
    return 1;
  } catch (const std::runtime_error &) {
  }

  aurora::qsh2::RecordHeader opaque_request;
  opaque_request.context_id = 4660;
  opaque_request.round_id = 1;
  opaque_request.schema_id = ::qshell::abi::schema_opaque_loopback;
  opaque_request.source_endpoint_id = 0x12345678;
  opaque_request.route_capability_id = 1;
  const std::vector<std::uint8_t> opaque_payload = {
      0xa5, 0x5a, 0x00, 0xff, 0x11, 0x22, 0x33, 0x44};
  const std::vector<std::uint8_t> expected_opaque_tx = {
      0x51, 0x53, 0x48, 0x32, 0x02, 0x01, 0x01, 0x00, 0x30, 0x00, 0x00,
      0x00, 0x08, 0x00, 0x00, 0x00, 0x34, 0x12, 0x00, 0x00, 0x01, 0x00,
      0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x78, 0x56, 0x34, 0x12, 0x00,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0xa5, 0x5a, 0x00, 0xff, 0x11, 0x22, 0x33,
      0x44,
  };
  const auto opaque_tx =
      aurora::qsh2::encode_record(opaque_request, opaque_payload);
  if (opaque_tx != expected_opaque_tx ||
      opaque_tx.size() >= ::qshell::abi::beat_bytes ||
      ((std::uint64_t{1} << opaque_tx.size()) - 1) !=
          std::uint64_t{0x00ffffffffffffffULL}) {
    std::cerr << "QSH2 opaque request golden bytes or valid mask changed\n";
    return 1;
  }
  auto invalid_flag_header = opaque_request;
  invalid_flag_header.flags = ::qshell::abi::flag_control_response;
  try {
    (void)aurora::qsh2::encode_record(invalid_flag_header, opaque_payload);
    std::cerr << "QSH2 syndrome with a control-response flag was accepted\n";
    return 1;
  } catch (const std::runtime_error &) {
  }

  invalid_flag_header.record_class =
      static_cast<std::uint8_t>(::qshell::abi::record_class::control);
  invalid_flag_header.flags = ::qshell::abi::flag_end_of_round;
  try {
    (void)aurora::qsh2::encode_record(invalid_flag_header, opaque_payload);
    std::cerr << "QSH2 control record with an end-of-round flag was accepted\n";
    return 1;
  } catch (const std::runtime_error &) {
  }

  invalid_flag_header.record_class =
      static_cast<std::uint8_t>(::qshell::abi::record_class::error);
  invalid_flag_header.flags = ::qshell::abi::flag_control_response;
  try {
    (void)aurora::qsh2::encode_record(invalid_flag_header, opaque_payload);
    std::cerr << "QSH2 error record with a flag was accepted\n";
    return 1;
  } catch (const std::runtime_error &) {
  }

  auto invalid_flag_wire = opaque_tx;
  invalid_flag_wire.at(::qshell::abi::offset::flags) =
      static_cast<std::uint8_t>(::qshell::abi::flag_control_response);
  try {
    (void)aurora::qsh2::decode_record(invalid_flag_wire);
    std::cerr << "QSH2 wire syndrome with a control-response flag was accepted\n";
    return 1;
  } catch (const std::runtime_error &) {
  }

  aurora::qsh2::RecordHeader control_header;
  control_header.record_class =
      static_cast<std::uint8_t>(::qshell::abi::record_class::control);
  control_header.flags = ::qshell::abi::flag_control_response;
  const auto control_record =
      aurora::qsh2::decode_record(aurora::qsh2::encode_record(control_header, {}));
  if (control_record.header.flags != ::qshell::abi::flag_control_response) {
    std::cerr << "QSH2 valid control-response flag was rejected\n";
    return 1;
  }

  const auto decoded_request = aurora::qsh2::decode_record(opaque_tx);
  if (decoded_request.header.schema_id !=
          ::qshell::abi::schema_opaque_loopback ||
      decoded_request.payload != opaque_payload) {
    std::cerr << "QSH2 opaque request round-trip failed\n";
    return 1;
  }

  const auto patterned_payload = [](std::size_t bytes, std::uint8_t salt) {
    std::vector<std::uint8_t> payload(bytes);
    for (std::size_t index = 0; index < payload.size(); ++index) {
      payload[index] = static_cast<std::uint8_t>(
          (index * 37u) ^ (index >> 3u) ^ salt);
    }
    return payload;
  };
  const auto wire_beats = [](std::size_t bytes) {
    return (bytes + ::qshell::abi::beat_bytes - 1) /
           ::qshell::abi::beat_bytes;
  };
  const auto final_valid_bytes = [](std::size_t bytes) {
    const auto remainder = bytes % ::qshell::abi::beat_bytes;
    return remainder == 0 ? ::qshell::abi::beat_bytes : remainder;
  };

  // The small d3 request remains one beat. The actual circuit-d9 request and
  // result exercise the 13- and 56-beat boundaries, respectively; the result
  // is 3,566 total bytes (48-byte header plus 3,518-byte payload).
  const std::vector<std::uint8_t> d3_opaque_payload = {
      0x01, 0x02, 0x10, 0x20, 0x30, 0x40};
  const auto d3_opaque_wire =
      aurora::qsh2::encode_record(opaque_request, d3_opaque_payload);
  const auto d3_opaque_record = aurora::qsh2::decode_record(d3_opaque_wire);
  if (d3_opaque_wire.size() != 54 || wire_beats(d3_opaque_wire.size()) != 1 ||
      final_valid_bytes(d3_opaque_wire.size()) != 54 ||
      d3_opaque_record.payload != d3_opaque_payload) {
    std::cerr << "QSH2 d3 opaque framing changed\n";
    return 1;
  }

  const auto d9_request_payload = patterned_payload(760, 0xa5);
  const auto d9_request_wire =
      aurora::qsh2::encode_record(opaque_request, d9_request_payload);
  const auto d9_request_record =
      aurora::qsh2::decode_record(d9_request_wire);
  if (d9_request_wire.size() != 808 || wire_beats(d9_request_wire.size()) != 13 ||
      final_valid_bytes(d9_request_wire.size()) != 40 ||
      d9_request_record.payload != d9_request_payload ||
      d9_request_wire.at(63) != d9_request_payload.at(15) ||
      d9_request_wire.at(64) != d9_request_payload.at(16) ||
      d9_request_wire.back() != d9_request_payload.back()) {
    std::cerr << "QSH2 circuit-d9 request framing changed\n";
    return 1;
  }

  auto truncated_d9_request = d9_request_wire;
  truncated_d9_request.pop_back();
  try {
    (void)aurora::qsh2::decode_record(truncated_d9_request);
    std::cerr << "QSH2 truncated circuit-d9 request was accepted\n";
    return 1;
  } catch (const std::runtime_error &) {
  }

  auto d9_response_header = opaque_request;
  d9_response_header.record_class = static_cast<std::uint8_t>(
      ::qshell::abi::record_class::correction);
  d9_response_header.source_endpoint_id = 20;
  d9_response_header.destination_endpoint_id = 0x80000001;
  d9_response_header.route_version = 1;
  const auto d9_response_payload = patterned_payload(3518, 0x5a);
  const auto d9_response_wire =
      aurora::qsh2::encode_record(d9_response_header, d9_response_payload);
  const auto d9_response = aurora::qsh2::decode_record(d9_response_wire);
  if (d9_response_wire.size() != 3566 ||
      wire_beats(d9_response_wire.size()) != 56 ||
      final_valid_bytes(d9_response_wire.size()) != 46 ||
      d9_response.payload != d9_response_payload ||
      d9_response_wire.at(63) != d9_response_payload.at(15) ||
      d9_response_wire.at(64) != d9_response_payload.at(16) ||
      d9_response_wire.back() != d9_response_payload.back()) {
    std::cerr << "QSH2 circuit-d9 result framing changed\n";
    return 1;
  }
  aurora::qsh2::validate_opaque_loopback_response(
      d9_response, opaque_request, d9_response_payload, 20, 0x80000001, 1);

  const auto maximum_payload = patterned_payload(
      aurora::qsh2::bridge_max_payload_bytes, 0x3c);
  const auto maximum_wire =
      aurora::qsh2::encode_record(opaque_request, maximum_payload);
  const auto maximum_record = aurora::qsh2::decode_record(maximum_wire);
  if (aurora::qsh2::bridge_max_record_beats != 65 ||
      maximum_wire.size() != 4144 || wire_beats(maximum_wire.size()) != 65 ||
      final_valid_bytes(maximum_wire.size()) != 48 ||
      maximum_record.payload != maximum_payload) {
    std::cerr << "QSH2 maximum-size framing changed\n";
    return 1;
  }

  try {
    (void)aurora::qsh2::encode_record(
        opaque_request,
        std::vector<std::uint8_t>(
            aurora::qsh2::bridge_max_payload_bytes + 1, 0xa5));
    std::cerr << "QSH2 record beyond the bridge bound was accepted\n";
    return 1;
  } catch (const std::runtime_error &) {
  }

  const std::vector<std::uint8_t> expected_opaque_rx = {
      0x51, 0x53, 0x48, 0x32, 0x02, 0x02, 0x01, 0x00, 0x30, 0x00, 0x00,
      0x00, 0x08, 0x00, 0x00, 0x00, 0x34, 0x12, 0x00, 0x00, 0x01, 0x00,
      0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x01,
      0x00, 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
      0x00, 0x00, 0x00, 0x00, 0xa5, 0x5a, 0x00, 0xff, 0x11, 0x22, 0x33,
      0x44,
  };
  auto opaque_rx = expected_opaque_rx;
  opaque_rx.resize(::qshell::abi::beat_bytes, 0);
  const auto opaque_response = aurora::qsh2::decode_record(opaque_rx);
  aurora::qsh2::validate_opaque_loopback_response(
      opaque_response, opaque_request, opaque_payload, 20, 0x80000001, 1);

  const auto expect_opaque_rejection = [&](const auto &candidate,
                                           const char *field) {
    try {
      aurora::qsh2::validate_opaque_loopback_response(
          candidate, opaque_request, opaque_payload, 20, 0x80000001, 1);
      std::cerr << "QSH2 opaque " << field << " mismatch was accepted\n";
      return false;
    } catch (const std::runtime_error &) {
      return true;
    }
  };

  auto mutated_response = opaque_response;
  mutated_response.header.record_class = static_cast<std::uint8_t>(
      ::qshell::abi::record_class::syndrome);
  if (!expect_opaque_rejection(mutated_response, "class")) return 1;
  mutated_response = opaque_response;
  mutated_response.header.schema_id++;
  if (!expect_opaque_rejection(mutated_response, "schema")) return 1;
  mutated_response = opaque_response;
  mutated_response.header.source_endpoint_id++;
  if (!expect_opaque_rejection(mutated_response, "source")) return 1;
  mutated_response = opaque_response;
  mutated_response.header.destination_endpoint_id++;
  if (!expect_opaque_rejection(mutated_response, "destination")) return 1;
  mutated_response = opaque_response;
  mutated_response.header.route_version++;
  if (!expect_opaque_rejection(mutated_response, "route version")) return 1;
  mutated_response = opaque_response;
  mutated_response.header.record_sequence++;
  if (!expect_opaque_rejection(mutated_response, "sequence")) return 1;
  mutated_response = opaque_response;
  mutated_response.payload[0] ^= 0xff;
  if (!expect_opaque_rejection(mutated_response, "payload")) return 1;

  std::cout << "helios_protocol_selftest: OK\n";
  return 0;
}
