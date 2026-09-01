cmake_minimum_required(VERSION 3.10...4.1)
project(peer_stream_loopback_host)

if(POLICY CMP0167)
    cmake_policy(SET CMP0167 NEW)
endif()

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(EN_SIM "Enable simulation mode for Coyote" OFF)

if(DEFINED ENV{COYOTE_ROOT})
    set(CYT_DIR $ENV{COYOTE_ROOT})
else()
    set(CYT_DIR ${CMAKE_SOURCE_DIR}/../../../)
endif()

if(EN_SIM)
    add_subdirectory(${CYT_DIR}/sim/sw ${CMAKE_BINARY_DIR}/coyote)
else()
    add_subdirectory(${CYT_DIR}/sw ${CMAKE_BINARY_DIR}/coyote)
endif()

message("*** Aurora QShell peer bridge [Software] ***")

set(TARGET_DIR "${CMAKE_SOURCE_DIR}/src")
set(PROTOCOL_SOURCES
    ${TARGET_DIR}/helios_protocol.cpp
    ${TARGET_DIR}/helios_qshell_protocol.cpp
)

find_package(Boost CONFIG REQUIRED COMPONENTS program_options)

add_executable(aurora-qshell-peer
    ${TARGET_DIR}/qshell_peer_main.cpp
    ${TARGET_DIR}/helios_transport_coyote.cpp
    ${PROTOCOL_SOURCES}
)
target_include_directories(aurora-qshell-peer PRIVATE ${CMAKE_SOURCE_DIR}/include)
target_link_libraries(aurora-qshell-peer PUBLIC Coyote Boost::program_options)

include(CTest)
if(BUILD_TESTING)
    add_executable(aurora-qshell-protocol-test
        tests/helios_protocol_test.cpp
        ${PROTOCOL_SOURCES}
    )
    target_include_directories(aurora-qshell-protocol-test PRIVATE ${CMAKE_SOURCE_DIR}/include)
    add_test(NAME aurora-qshell-protocol COMMAND aurora-qshell-protocol-test)
endif()
