cmake_minimum_required(VERSION 3.16)
project(luciaos LANGUAGES CXX)

if(POLICY CMP0156)
  cmake_policy(SET CMP0156 NEW)
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(LUCIA_SANITIZE "Enable runtime sanitizers" OFF)

function(lucia_target target)
  target_include_directories(${target} PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
  target_compile_options(${target} PRIVATE -Wall -Wextra -Wpedantic)
  if(LUCIA_SANITIZE)
    if(APPLE)
      set(sanitizers undefined)
    else()
      set(sanitizers address,undefined)
    endif()
    target_compile_options(${target} PRIVATE
      -fsanitize=${sanitizers}
      -fno-omit-frame-pointer
    )
    target_link_options(${target} PRIVATE -fsanitize=${sanitizers})
  endif()
endfunction()

if(APPLE)
  add_library(lucia_platform platform/macos/file.cpp)
else()
  message(FATAL_ERROR "This foundation currently supports macOS only")
endif()
lucia_target(lucia_platform)

add_library(lucia_storage
  storage/volume/file_volume.cpp
  storage/volume/memory_volume.cpp
)
target_link_libraries(lucia_storage PUBLIC lucia_platform)
lucia_target(lucia_storage)

add_library(lucia_fabric
  fabric/model/blob_ref.cpp
  fabric/model/fiber.cpp
  fabric/model/input_port.cpp
  fabric/model/output_port.cpp
  fabric/model/texel.cpp
  fabric/model/texel_id.cpp
  fabric/model/value.cpp
  fabric/model/value_outcome.cpp
  fabric/persistence/encode.cpp
  fabric/persistence/store.cpp
)
target_link_libraries(lucia_fabric PUBLIC lucia_storage)
lucia_target(lucia_fabric)

add_library(lucia_realm realm/authority/capability.cpp)
target_link_libraries(lucia_realm PUBLIC lucia_fabric)
lucia_target(lucia_realm)

add_library(lucia_loom
  loom/effects/effect.cpp
  loom/evaluation/spool.cpp
  loom/evaluation/state.cpp
  loom/organization/arrangement.cpp
)
target_link_libraries(lucia_loom PUBLIC lucia_fabric lucia_realm)
lucia_target(lucia_loom)

add_library(lucia_view
  view/runtime/evaluators.cpp
  view/runtime/shell.cpp
)
target_link_libraries(lucia_view PUBLIC lucia_loom)
lucia_target(lucia_view)

add_library(lucia_projection
  projection/file/file_projection.cpp
  projection/file/projection_manifest.cpp
)
target_link_libraries(lucia_projection PUBLIC lucia_loom)
lucia_target(lucia_projection)

add_executable(loom
  loom/cli/arguments.cpp
  loom/cli/commands.cpp
  loom/cli/main.cpp
)
target_link_libraries(loom PRIVATE lucia_loom lucia_view lucia_projection)
lucia_target(loom)

enable_testing()

function(lucia_test name source)
  add_executable(${name} ${source})
  target_link_libraries(${name} PRIVATE ${ARGN})
  lucia_target(${name})
  add_test(NAME ${name} COMMAND ${name})
endfunction()

lucia_test(volume_test tests/storage/volume_test.cpp lucia_storage)
lucia_test(fabric_test tests/fabric/fabric_test.cpp lucia_fabric)
lucia_test(store_test tests/fabric/store_test.cpp lucia_fabric)
lucia_test(spool_test tests/loom/spool_test.cpp lucia_loom)
lucia_test(effect_test tests/loom/effect_test.cpp lucia_loom)
lucia_test(state_test tests/loom/state_test.cpp lucia_loom)
lucia_test(arrangement_test tests/loom/arrangement_test.cpp lucia_loom)
lucia_test(view_test tests/view/view_test.cpp lucia_view)
lucia_test(projection_test tests/projection/projection_test.cpp
           lucia_projection)
lucia_test(first_lucia_test tests/acceptance/first_lucia_test.cpp
           lucia_view lucia_projection)

add_test(
  NAME loom_demo
  COMMAND loom demo --image ${CMAKE_BINARY_DIR}/loom-demo.img
)
