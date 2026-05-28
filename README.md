# Coyote Example 14: Aurora 64B/66B FPGA-to-FPGA Loopback

Direct serial communication between two U280 Alveo cards (rose ↔ clara) via
Xilinx Aurora 64B/66B IP on QSFP1, bypassing Ethernet/IP entirely.

## Configuration

- **Aurora IP:** 4 lanes bonded @ 25.78125 Gbps = **103.125 Gbps gross** (~99.6 Gbps after 64B/66B encoding)
- **Reference clock:** 161.1328125 MHz from QSFP1 cage
- **User interface:** 256-bit AXI4-Stream (TX + RX), `aclk` domain
- **Topology:** rose:QSFP1 ⇄ QSFP28 DAC/AOC cable ⇄ clara:QSFP1

## Architecture

```
Host x86 (rose)                                          Host x86 (clara)
   |                                                          |
   | PCIe (Coyote control regs)                               | PCIe (Coyote control regs)
   v                                                          v
+--vFPGA region--+                                  +--vFPGA region--+
| counter gen    |                                  | beat checker   |
| TX FSM         |                                  | RX FSM         |
+----------------+                                  +----------------+
   | axis_aurora_tx (256-bit)                          ^ axis_aurora_rx (256-bit)
   v                                                  |
+--Coyote shell---+                                +--Coyote shell---+
| aurora_module   |                                | aurora_module   |
| (Aurora IP)     |                                | (Aurora IP)     |
+-----------------+                                +-----------------+
   |  4 × GTY @ 25.78 Gbps                            ^
   v  (qsfp1)                                         |
   +----- QSFP28 cable -------------------------------+
```

## Build

### Hardware

```bash
# From inside versal-shell on rose (or wherever Vivado 2025.1 with U280 part lives)
cd /scratch/anubhav/Coyote-upstream/examples/14_aurora_loopback/hw
mkdir -p build && cd build
cmake ../ -DFDEV_NAME=u280
make project   # ~30 min (Aurora IP generation + BD assembly)
make bitgen    # ~2–4 hours (synth + impl + bitstream)
```

Produces `build/bitstreams/cyt_top.bit`. Copy or build the same on clara.

### Software

```bash
cd /scratch/anubhav/Coyote-upstream/examples/14_aurora_loopback/sw
mkdir -p build && cd build
cmake ../
make
```

Produces `build/test`.

## Run

### Step 1: Program both cards

```bash
# On rose:
cd /scratch/anubhav/Coyote-upstream
./program_fpga.sh examples/14_aurora_loopback/hw/build/bitstreams/cyt_top

# On clara: same.
```

### Step 2: Connect physical cable

Plug a QSFP28 DAC or AOC cable between rose's QSFP1 cage and clara's QSFP1 cage.
Both cards must be programmed before the cable is plugged in (or unplug + replug
after both are programmed to re-trigger Aurora's init handshake).

### Step 3: Run host apps

On **clara** (RX, arm first to be ready when rose starts sending):

```bash
sudo ./test --role rx --beats 1024
```

On **rose** (TX, fires after RX is armed):

```bash
sudo ./test --role tx --beats 1024
```

Expected output on clara:

```
=== Coyote Example 14: Aurora Loopback ===
Role:  rx
Beats: 1024
[OK] channel_up asserted;   channel_up=1 lane_up=1111 tx_done=0 rx_done=0
Arming RX...
  beats received: 1024/1024
[RX result] beats=1024 mismatches=0
*** PASS: 1024 beats received with no mismatch ***
```

## What this validates

| Component | Validated by |
|---|---|
| Aurora IP synth on U280 GTY | `make bitgen` succeeds |
| QSFP1 MGT refclock @ 161.13 MHz pinning | `channel_up=1` asserts |
| 4-lane bond, no lane drops | `lane_up=4'b1111` |
| AXI4-Stream CDC (user_clk ↔ aclk) | RX beats arrive intact |
| Shell-to-vFPGA Aurora wiring | counter pattern matches on RX |

## Troubleshooting

- **`channel_up=0`, `lane_up=0000`**: cable not plugged, peer not programmed, or refclock pin mismatch.
  Check `report_clocks` and the actual MGT refclock frequency in Vivado.
- **`channel_up=1`, `lane_up=1111`, but `beats=0`**: TX side didn't fire — check rose's CTRL register.
- **`mismatches > 0`**: bit errors. Check cable quality; lower line rate to 10.3125 Gbps for sanity.
- **PMA_INIT loops forever**: GT reference clock not stable. Check QSFP1 module is inserted (some
  QSFP cages need a module present to enable the refclock).

## Files

- `hw/CMakeLists.txt` — example build config (`EN_AURORA_1=1`, no CMAC)
- `hw/src/vfpga_top.svh` — vFPGA logic (counter gen + beat checker + CSR slave)
- `sw/src/main.cpp` — host driver (rx/tx role split)

Shell-side support (one-time per Coyote tree, not per-example):
- `scripts/ip_inst/aurora_infrastructure.tcl` — generates `aurora_loopback_ip` + two `axis_data_fifo_aurora_*` at shell build time when `EN_AURORA_1=1`
- `hw/templates/common/shell_top_tmplt.txt` — Aurora module instantiation on QSFP1
- `hw/templates/common/dynamic_top_tmplt.txt` — Aurora AXIS through dynamic region
- `hw/templates/common/user_wrapper_tmplt.txt` — flatten/repack at vFPGA boundary
- `hw/templates/common/user_logic_tmplt.txt` — vFPGA port declaration
- `hw/hdl/aurora/aurora_module.sv` — Aurora IP wrapper + init FSM + CDC FIFOs
- `hw/constraints/u280/dynamic/impl/u280_shell_zaurora_1.xdc` — 161 MHz refclock pin override
