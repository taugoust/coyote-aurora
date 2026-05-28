######################################################################################
# Coyote peer-stream loopback test [Hardware]
#
# Exercises Coyote's optional peer ULI. For the first prototype the peer backend
# is host_stream: host stream 0 remains visible to the app as the regular host
# stream, while host stream 1 is hidden behind axis_peer_recv/axis_peer_send.
######################################################################################

cmake_minimum_required(VERSION 3.5)
set(CYT_DIR ${CMAKE_SOURCE_DIR}/../../../)
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

# Host stream 0 remains a normal host stream. Host stream 1 backs the optional
# peer interface through PEER_BACKEND=host_stream.
set(EN_STRM 1)
set(N_STRM_AXI 2)
set(EN_PEER 1)
set(PEER_BACKEND "host_stream")
set(N_PEER_LINKS 1)
set(N_PEER_AXI 1)

# Build with optimization (high-speed serial timing closure)
set(BUILD_OPT 1)

validation_checks_hw()

load_apps (
    VFPGA_C0_0 "src"
)

create_hw()
