/**
 * Coyote Example 14: Aurora 64B/66B FPGA-to-FPGA Loopback — Host App
 *
 * Drives the example_14 vFPGA on either rose (TX side) or clara (RX side).
 * Both sides must run this same binary; --role flag selects behavior.
 *
 * Register map (CSR index = byte_offset / 8):
 *   0: CTRL          (bit0=TX start, bit1=RX arm)
 *   1: STATUS        (bit0=tx_done, bit1=rx_done, bit2=channel_up, bits[6:3]=lane_up)
 *   2: TX_BURST_BEATS (256-bit beats to send)
 *   3: RX_BEAT_CNT   (read-only)
 *   4: RX_MISMATCHES (read-only)
 */

#include <chrono>
#include <thread>
#include <iostream>
#include <iomanip>
#include <bitset>
#include <unistd.h>
#include <boost/program_options.hpp>

#include <coyote/cThread.hpp>

namespace po = boost::program_options;

constexpr uint32_t DEFAULT_VFPGA_ID = 0;

constexpr uint32_t REG_CTRL          = 0;
constexpr uint32_t REG_STATUS        = 1;
constexpr uint32_t REG_TX_BURST      = 2;
constexpr uint32_t REG_RX_BEATS      = 3;
constexpr uint32_t REG_RX_MISMATCH   = 4;

constexpr uint64_t CTRL_TX_START = 1ULL << 0;
constexpr uint64_t CTRL_RX_ARM   = 1ULL << 1;

static void print_status(uint64_t s) {
    bool tx_done    = (s >> 0) & 0x1;
    bool rx_done    = (s >> 1) & 0x1;
    bool channel_up = (s >> 2) & 0x1;
    uint8_t lane_up = (s >> 3) & 0xF;
    std::cout << "  channel_up=" << channel_up
              << " lane_up=" << std::bitset<4>(lane_up)
              << " tx_done=" << tx_done
              << " rx_done=" << rx_done
              << "\n";
}

static bool wait_for_channel_up(coyote::cThread& t, int timeout_ms = 5000) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    while (std::chrono::steady_clock::now() < deadline) {
        uint64_t s = t.getCSR(REG_STATUS);
        if ((s >> 2) & 0x1) {        // bit 2 = channel_up
            std::cout << "[OK] channel_up asserted; ";
            print_status(s);
            return true;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    std::cout << "[FAIL] channel_up did not assert within " << timeout_ms << " ms\n";
    print_status(t.getCSR(REG_STATUS));
    return false;
}

int main(int argc, char* argv[]) {
    std::string role;
    uint64_t    n_beats;

    po::options_description desc("Coyote Aurora Loopback");
    desc.add_options()
        ("role,r", po::value<std::string>(&role)->default_value("rx"),
         "Role: 'tx' (sender) or 'rx' (receiver)")
        ("beats,n", po::value<uint64_t>(&n_beats)->default_value(1024),
         "Number of 256-bit beats to send / expect");
    po::variables_map vm;
    po::store(po::parse_command_line(argc, argv, desc), vm);
    po::notify(vm);

    std::cout << "=== Coyote Example 14: Aurora Loopback ===\n"
              << "Role:  " << role << "\n"
              << "Beats: " << n_beats << "\n";

    coyote::cThread t(DEFAULT_VFPGA_ID, getpid());

    // Step 1: wait for Aurora link to come up
    if (!wait_for_channel_up(t)) return 1;

    if (role == "rx") {
        // RX side: arm capture, then poll for incoming beats
        std::cout << "Arming RX...\n";
        t.setCSR(CTRL_RX_ARM, REG_CTRL);

        // Poll for n_beats arrivals
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        uint64_t prev = 0;
        while (std::chrono::steady_clock::now() < deadline) {
            uint64_t beats = t.getCSR(REG_RX_BEATS);
            if (beats != prev) {
                std::cout << "  beats received: " << beats << "/" << n_beats << "\n";
                prev = beats;
            }
            if (beats >= n_beats) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }

        uint64_t beats    = t.getCSR(REG_RX_BEATS);
        uint64_t mismatch = t.getCSR(REG_RX_MISMATCH);
        std::cout << "[RX result] beats=" << beats
                  << " mismatches=" << mismatch << "\n";
        if (beats == n_beats && mismatch == 0) {
            std::cout << "*** PASS: " << n_beats << " beats received with no mismatch ***\n";
            return 0;
        }
        std::cout << "*** FAIL ***\n";
        return 1;

    } else if (role == "tx") {
        // TX side: write burst length, then fire
        std::cout << "Programming burst length and firing TX...\n";
        t.setCSR(n_beats, REG_TX_BURST);
        t.setCSR(CTRL_TX_START, REG_CTRL);

        // Wait for tx_done
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (std::chrono::steady_clock::now() < deadline) {
            uint64_t s = t.getCSR(REG_STATUS);
            if ((s >> 0) & 0x1) {        // bit 0 = tx_done
                std::cout << "[OK] TX done.\n";
                t.setCSR(0, REG_CTRL);   // clear start
                return 0;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
        std::cout << "*** FAIL: TX did not complete ***\n";
        return 1;
    }

    std::cerr << "Unknown role '" << role << "'. Use 'tx' or 'rx'.\n";
    return 2;
}
