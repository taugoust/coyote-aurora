#include <iostream>
#include <stdexcept>
#include <vector>

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

  std::cout << "helios_protocol_selftest: OK\n";
  return 0;
}
