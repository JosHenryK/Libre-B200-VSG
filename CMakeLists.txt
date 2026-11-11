cmake_minimum_required(VERSION 3.16)
project(athena_skydar LANGUAGES CXX)

if(POLICY CMP0167)
  cmake_policy(SET CMP0167 NEW)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(UHD REQUIRED)
find_package(Boost REQUIRED)

add_executable(tx_lfm_pulses tx_lfm_pulses.cpp)
target_include_directories(tx_lfm_pulses PRIVATE ${UHD_INCLUDE_DIRS} ${Boost_INCLUDE_DIRS})
target_link_libraries(tx_lfm_pulses PRIVATE ${UHD_LIBRARIES})
