######################################################################################
# Coyote Example 14: Aurora 64B/66B FPGA-to-FPGA Loopback [Hardware]
#
# Direct serial transport on U280's QSFP1 via Xilinx Aurora 64B/66B IP, bypassing
# Ethernet/IP entirely. Two cards (rose <-> clara) cabled QSFP1<->QSFP1.
#
# Aurora is instantiated in the shell, parallel to CMAC on QSFP0. Its user-side
# AXI4-Stream is brought into the vFPGA boundary as axis_aurora_rx / axis_aurora_tx,
# mirroring the bypass_rx/tx pattern used by the raw-Ethernet bypass example.
######################################################################################

cmake_minimum_required(VERSION 3.5)
set(CYT_DIR ${CMAKE_SOURCE_DIR}/../../../)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)
find_package(CoyoteHW REQUIRED)

project(example_14_aurora_loopback)
message("*** Coyote Example 14: Aurora 64B/66B Loopback [Hardware] ***")

set(N_REGIONS 1)

# Aurora 64B/66B on QSFP1 (this example's whole reason). 4 lanes @ 25.78125 Gbps.
# Reference clock 161.1328125 MHz from QSFP1 cage.
set(EN_AURORA_1 1)

# Keep CMAC stack off; this example is Aurora-only for first integration.
set(EN_NET_0  0)
set(EN_NET_1  0)
set(EN_RDMA   0)
set(EN_TCP    0)

# Host streams enabled so the vFPGA can DMA payload from/to host memory
set(EN_STRM   1)
set(N_STRM_AXI 1)

# Build with optimization (high-speed serial timing closure)
set(BUILD_OPT 1)

validation_checks_hw()

load_apps (
    VFPGA_C0_0 "src"
)

create_hw()
