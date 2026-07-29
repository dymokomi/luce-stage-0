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
    target_include_directories(${target} PUBLIC ${PROJECT_SOURCE_DIR}/reference/src)
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
    add_library(lucia_platform reference/src/platform/macos/file.cpp)
else()
    message(FATAL_ERROR "This foundation currently supports macOS only")
endif()
lucia_target(lucia_platform)

add_library(lucia_storage
    reference/src/storage/volume/file_volume.cpp
    reference/src/storage/volume/memory_volume.cpp
)
target_link_libraries(lucia_storage PUBLIC lucia_platform)
lucia_target(lucia_storage)

add_library(lucia_fabric
    reference/src/fabric/model/blob_ref.cpp
    reference/src/fabric/model/fiber.cpp
    reference/src/fabric/model/input_port.cpp
    reference/src/fabric/model/output_port.cpp
    reference/src/fabric/model/texel.cpp
    reference/src/fabric/model/texel_id.cpp
    reference/src/fabric/model/value.cpp
    reference/src/fabric/model/value_outcome.cpp
    reference/src/fabric/persistence/encode.cpp
    reference/src/fabric/persistence/store.cpp
)
target_link_libraries(lucia_fabric PUBLIC lucia_storage)
lucia_target(lucia_fabric)

add_library(lucia_realm reference/src/realm/authority/capability.cpp)
target_link_libraries(lucia_realm PUBLIC lucia_fabric)
lucia_target(lucia_realm)

add_library(lucia_loom
    reference/src/loom/effects/effect.cpp
    reference/src/loom/evaluation/fiber_index.cpp
    reference/src/loom/evaluation/spool.cpp
    reference/src/loom/evaluation/state.cpp
    reference/src/loom/organization/arrangement.cpp
)
target_link_libraries(lucia_loom PUBLIC lucia_fabric lucia_realm)
lucia_target(lucia_loom)

add_library(lucia_view
    reference/src/view/runtime/evaluators.cpp
    reference/src/view/runtime/shell.cpp
)
target_link_libraries(lucia_view PUBLIC lucia_loom)
lucia_target(lucia_view)

add_library(lucia_projection
    reference/src/projection/file/file_projection.cpp
    reference/src/projection/file/projection_manifest.cpp
)
target_link_libraries(lucia_projection PUBLIC lucia_loom)
lucia_target(lucia_projection)

# The loom terminal runs on the Zig engine through the C ABI in
# abi/loom.h; the C++ engine above stays as the reference tree.
find_program(ZIG_EXECUTABLE zig)
if(NOT ZIG_EXECUTABLE)
    message(FATAL_ERROR "zig not found; the loom terminal links the Zig engine (see docs/ZIG.md)")
endif()

set(LOOM_ENGINE_LIB ${PROJECT_SOURCE_DIR}/zig-out/lib/libloom.a)
add_custom_target(loom_engine
    COMMAND ${ZIG_EXECUTABLE} build
    WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}
    BYPRODUCTS ${LOOM_ENGINE_LIB}
    COMMENT "Building the Loom engine (zig build)"
    VERBATIM
)

add_executable(loom
    apps/loom/command_line.cpp
    apps/loom/command_set.cpp
    apps/loom/image.cpp
    apps/loom/main.cpp
    apps/loom/terminal.cpp
)
add_dependencies(loom loom_engine)
target_include_directories(loom PRIVATE
    ${PROJECT_SOURCE_DIR}/apps/loom
    ${PROJECT_SOURCE_DIR}/abi
)
target_link_libraries(loom PRIVATE ${LOOM_ENGINE_LIB})
lucia_target(loom)

enable_testing()

function(lucia_test name source)
    add_executable(${name} ${source})
    target_link_libraries(${name} PRIVATE ${ARGN})
    lucia_target(${name})
    add_test(NAME ${name} COMMAND ${name})
endfunction()

lucia_test(volume_test reference/tests/storage/volume_test.cpp lucia_storage)
lucia_test(fabric_test reference/tests/fabric/fabric_test.cpp lucia_fabric)
lucia_test(store_test reference/tests/fabric/store_test.cpp lucia_fabric)
lucia_test(spool_test reference/tests/loom/spool_test.cpp lucia_loom)
lucia_test(fiber_index_test reference/tests/loom/fiber_index_test.cpp lucia_loom)
lucia_test(effect_test reference/tests/loom/effect_test.cpp lucia_loom)
lucia_test(state_test reference/tests/loom/state_test.cpp lucia_loom)
lucia_test(arrangement_test reference/tests/loom/arrangement_test.cpp lucia_loom)
lucia_test(view_test reference/tests/view/view_test.cpp lucia_view)
lucia_test(projection_test reference/tests/projection/projection_test.cpp
                     lucia_projection)
lucia_test(first_lucia_test reference/tests/acceptance/first_lucia_test.cpp
                     lucia_view lucia_projection)

add_test(
    NAME loom_terminal
    COMMAND sh -c "\
$<TARGET_FILE:loom> create ${CMAKE_BINARY_DIR}/loom-terminal.img && \
printf 'new left\\noutput value text\\nset value hello\\n\
new right\\noutput value text\\nset value world\\n\
new join\\neval concat\\ninput left text\\ninput right text\\noutput value text\\n\
connect left left value\\nconnect right right value\\npull value\\n\
watch value\\nselect left\\nset value HELLO\\nexit\\n' | \
$<TARGET_FILE:loom> open ${CMAKE_BINARY_DIR}/loom-terminal.img | grep -q HELLOworld"
)
