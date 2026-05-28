cmake_minimum_required(VERSION 3.5)
project(example_14_aurora_loopback)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

option(EN_SIM "Enable simulation mode for Coyote" OFF)

if(EN_SIM)
    add_subdirectory(../../../sim/sw ${CMAKE_BINARY_DIR}/coyote)
else()
    add_subdirectory(../../../sw ${CMAKE_BINARY_DIR}/coyote)
endif()

message("*** Coyote Example 14: Aurora 64B/66B Loopback [Software] ***")

set(TARGET_DIR "${CMAKE_SOURCE_DIR}/src/")

set(EXEC test)
add_executable(${EXEC} ${TARGET_DIR}/main.cpp)
target_link_libraries(${EXEC} PUBLIC Coyote)

find_package(Boost REQUIRED COMPONENTS program_options)
target_link_libraries(${EXEC} PUBLIC Boost::program_options)
