cmake_minimum_required(VERSION 3.16)
project(lucia LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(lucia_storage
  storage/memory_volume.cpp
  storage/file_volume.cpp
)
target_include_directories(lucia_storage PUBLIC storage)
target_compile_options(lucia_storage PRIVATE -Wall -Wextra)

enable_testing()
add_executable(volume_test tests/volume_test.cpp)
target_link_libraries(volume_test PRIVATE lucia_storage)
add_test(NAME volume_test COMMAND volume_test)
