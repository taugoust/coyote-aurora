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

if(NOT DEFINED QSHELL_ROOT AND DEFINED ENV{QSHELL_ROOT})
    set(QSHELL_ROOT $ENV{QSHELL_ROOT})
endif()
if(NOT DEFINED QSHELL_ROOT)
    message(FATAL_ERROR "QSHELL_ROOT must point to the authoritative QShell source")
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
    ${TARGET_DIR}/qsh2_record.cpp
)
set(HOST_INCLUDE_DIRS
    ${CMAKE_SOURCE_DIR}/include
    ${QSHELL_ROOT}/include
)

find_package(Boost CONFIG REQUIRED COMPONENTS program_options)

add_executable(aurora-qshell-peer
    ${TARGET_DIR}/qshell_peer_main.cpp
    ${TARGET_DIR}/helios_transport_coyote.cpp
    ${PROTOCOL_SOURCES}
)
target_include_directories(aurora-qshell-peer PRIVATE ${HOST_INCLUDE_DIRS})
target_link_libraries(aurora-qshell-peer PUBLIC Coyote Boost::program_options)

add_executable(aurora-qshell-loopback
    ${TARGET_DIR}/qshell_loopback_main.cpp
    ${TARGET_DIR}/helios_transport_coyote.cpp
    ${TARGET_DIR}/qsh2_record.cpp
)
target_include_directories(aurora-qshell-loopback PRIVATE ${HOST_INCLUDE_DIRS})
target_link_libraries(aurora-qshell-loopback PUBLIC Coyote Boost::program_options)

include(CTest)
if(BUILD_TESTING)
    add_executable(aurora-qshell-protocol-test
        tests/helios_protocol_test.cpp
        ${PROTOCOL_SOURCES}
    )
    target_include_directories(aurora-qshell-protocol-test PRIVATE ${HOST_INCLUDE_DIRS})
    add_test(NAME aurora-qshell-protocol COMMAND aurora-qshell-protocol-test)
endif()
