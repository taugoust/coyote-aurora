######################################################################################
# Coyote peer-stream loopback test [Hardware]
#
# Exercises Coyote's optional peer ULI over the Aurora QSFP1 backend. The user
# RTL sees only axis_peer_recv/axis_peer_send and peer status; Aurora-specific
# wiring remains hidden in Coyote's PEER_BACKEND=aurora_qsfp1 implementation.
######################################################################################

cmake_minimum_required(VERSION 3.5)
if(DEFINED ENV{COYOTE_ROOT} AND EXISTS "$ENV{COYOTE_ROOT}/cmake")
    set(CYT_DIR $ENV{COYOTE_ROOT})
else()
    set(CYT_DIR ${CMAKE_SOURCE_DIR}/../../../)
endif()
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)
find_package(CoyoteHW REQUIRED)

project(peer_stream_loopback)
message("*** Coyote peer-stream loopback [Hardware] ***")

set(N_REGIONS 1)

# Keep the network stack off. The peer abstraction is intentionally distinct
# from Coyote's Ethernet/RDMA/TCP network service.
set(EN_NET_0  0)
set(EN_NET_1  0)
set(EN_RDMA   0)
set(EN_TCP    0)

# Keep one normal host stream for control/testing. The peer interface is backed
# by real Aurora on U280 QSFP1; it no longer consumes a host stream.
set(EN_STRM 1)
set(N_STRM_AXI 1)
set(EN_PEER 1)
set(PEER_BACKEND "aurora_qsfp1")
set(N_PEER_LINKS 1)
set(N_PEER_AXI 1)

# Build with optimization (high-speed serial timing closure)
set(BUILD_OPT 1)

validation_checks_hw()

load_apps (
    VFPGA_C0_0 "src"
)

create_hw()
