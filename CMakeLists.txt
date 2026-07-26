cmake_minimum_required(VERSION 3.28)

project(lucia
  VERSION 0.1.0
  DESCRIPTION "Lucia storage substrate"
  LANGUAGES CXX
)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(LUCIA_BUILD_TESTS "Build Lucia unit tests" ON)

add_library(lucia_storage
  src/lucia/storage/memory_volume.cpp
  src/lucia/storage/faulty_volume.cpp
  src/platform/posix/file_volume.cpp
)

add_library(lucia::storage ALIAS lucia_storage)

target_include_directories(lucia_storage
  PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_compile_options(lucia_storage
  PRIVATE
    -Wall
    -Wextra
    -Wpedantic
    -Wconversion
    -Wshadow
)

if(LUCIA_BUILD_TESTS)
  enable_testing()
  add_executable(lucia_storage_tests
    tests/storage/volume_test.cpp
  )
  target_link_libraries(lucia_storage_tests
    PRIVATE
      lucia::storage
  )
  target_compile_options(lucia_storage_tests
    PRIVATE
      -Wall
      -Wextra
      -Wpedantic
  )
  add_test(NAME lucia_storage_tests COMMAND lucia_storage_tests)
endif()
