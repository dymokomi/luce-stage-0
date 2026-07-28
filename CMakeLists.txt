cmake_minimum_required(VERSION 3.16)
project(luciaos LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(LUCIA_SANITIZE "Enable address and undefined behavior sanitizers" OFF)

function(lucia_target target)
  target_include_directories(${target} PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
  target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic)
  if(LUCIA_SANITIZE)
    target_compile_options(${target} PRIVATE
      -fsanitize=address,undefined
      -fno-omit-frame-pointer
    )
    target_link_options(${target} PRIVATE -fsanitize=address,undefined)
  endif()
endfunction()

if(APPLE)
  add_library(lucia_platform platform/macos/file.cpp)
else()
  message(FATAL_ERROR "This foundation currently supports macOS only")
endif()
lucia_target(lucia_platform)

add_library(lucia_storage
  storage/memory_volume.cpp
  storage/file_volume.cpp
)
target_link_libraries(lucia_storage PUBLIC lucia_platform)
lucia_target(lucia_storage)

add_library(lucia_fabric
  fabric/texel_id.cpp
  fabric/blob_ref.cpp
  fabric/value.cpp
  fabric/value_outcome.cpp
  fabric/fiber.cpp
  fabric/input_port.cpp
  fabric/output_port.cpp
  fabric/texel.cpp
  fabric/encode.cpp
  fabric/store.cpp
)
target_link_libraries(lucia_fabric PUBLIC lucia_storage)
lucia_target(lucia_fabric)

add_library(lucia_realm realm/capability.cpp)
target_link_libraries(lucia_realm PUBLIC lucia_fabric)
lucia_target(lucia_realm)

add_library(lucia_loom
  loom/spool.cpp
  loom/effect.cpp
)
target_link_libraries(lucia_loom PUBLIC lucia_fabric lucia_realm)
lucia_target(lucia_loom)

add_executable(loom loom/main.cpp)
target_link_libraries(loom PRIVATE lucia_loom)
lucia_target(loom)

enable_testing()

function(lucia_test name)
  add_executable(${name} tests/${name}.cpp)
  target_link_libraries(${name} PRIVATE ${ARGN})
  lucia_target(${name})
  add_test(NAME ${name} COMMAND ${name})
endfunction()

lucia_test(volume_test lucia_storage)
lucia_test(fabric_test lucia_fabric)
lucia_test(store_test lucia_fabric)
lucia_test(spool_test lucia_loom)
lucia_test(effect_test lucia_loom)

add_test(
  NAME loom_demo
  COMMAND loom demo --image ${CMAKE_BINARY_DIR}/loom-demo.img
)
