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
    target_include_directories(${target} PUBLIC ${PROJECT_SOURCE_DIR}/src)
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
    add_library(lucia_platform src/platform/macos/file.cpp)
else()
    message(FATAL_ERROR "This foundation currently supports macOS only")
endif()
lucia_target(lucia_platform)

add_library(lucia_storage
    src/storage/volume/file_volume.cpp
    src/storage/volume/memory_volume.cpp
)
target_link_libraries(lucia_storage PUBLIC lucia_platform)
lucia_target(lucia_storage)

add_library(lucia_fabric
    src/fabric/model/blob_ref.cpp
    src/fabric/model/fiber.cpp
    src/fabric/model/input_port.cpp
    src/fabric/model/output_port.cpp
    src/fabric/model/texel.cpp
    src/fabric/model/texel_id.cpp
    src/fabric/model/value.cpp
    src/fabric/model/value_outcome.cpp
    src/fabric/persistence/encode.cpp
    src/fabric/persistence/store.cpp
)
target_link_libraries(lucia_fabric PUBLIC lucia_storage)
lucia_target(lucia_fabric)

add_library(lucia_realm src/realm/authority/capability.cpp)
target_link_libraries(lucia_realm PUBLIC lucia_fabric)
lucia_target(lucia_realm)

add_library(lucia_loom
    src/loom/effects/effect.cpp
    src/loom/evaluation/spool.cpp
    src/loom/evaluation/state.cpp
    src/loom/organization/arrangement.cpp
)
target_link_libraries(lucia_loom PUBLIC lucia_fabric lucia_realm)
lucia_target(lucia_loom)

add_library(lucia_view
    src/view/runtime/evaluators.cpp
    src/view/runtime/shell.cpp
)
target_link_libraries(lucia_view PUBLIC lucia_loom)
lucia_target(lucia_view)

add_library(lucia_projection
    src/projection/file/file_projection.cpp
    src/projection/file/projection_manifest.cpp
)
target_link_libraries(lucia_projection PUBLIC lucia_loom)
lucia_target(lucia_projection)

add_executable(loom
    apps/loom/command_line.cpp
    apps/loom/commands.cpp
    apps/loom/image.cpp
    apps/loom/main.cpp
    apps/loom/terminal.cpp
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
    NAME loom_terminal
    COMMAND sh -c "\
$<TARGET_FILE:loom> create ${CMAKE_BINARY_DIR}/loom-terminal.img && \
printf 'new hello\\nfind hel\\nexit\\n' | \
$<TARGET_FILE:loom> open ${CMAKE_BINARY_DIR}/loom-terminal.img | grep -q hello"
)
