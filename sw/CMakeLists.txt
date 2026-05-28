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

message("*** Coyote peer-stream loopback [Software] ***")

set(TARGET_DIR "${CMAKE_SOURCE_DIR}/src")

set(EXEC test)
add_executable(${EXEC} ${TARGET_DIR}/main.cpp)
target_link_libraries(${EXEC} PUBLIC Coyote)

find_package(Boost CONFIG REQUIRED COMPONENTS program_options)
target_link_libraries(${EXEC} PUBLIC Boost::program_options)
