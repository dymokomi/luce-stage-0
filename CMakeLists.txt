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

add_library(lucia_crypto
  crypto/key.cpp
  crypto/seal.cpp
)
target_include_directories(lucia_crypto PUBLIC crypto storage)
target_link_libraries(lucia_crypto PUBLIC lucia_storage)
target_compile_options(lucia_crypto PRIVATE -Wall -Wextra)

add_library(lucia_realm
  realm/principal.cpp
)
target_include_directories(lucia_realm PUBLIC realm crypto storage)
target_link_libraries(lucia_realm PUBLIC lucia_crypto)
target_compile_options(lucia_realm PRIVATE -Wall -Wextra)

add_library(lucia_fabric
  fabric/value.cpp
  fabric/node_id.cpp
  fabric/port.cpp
  fabric/fiber.cpp
  fabric/node.cpp
  fabric/encode.cpp
  fabric/store.cpp
)
target_include_directories(lucia_fabric PUBLIC fabric realm crypto storage)
target_link_libraries(lucia_fabric PUBLIC lucia_storage lucia_crypto lucia_realm)
target_compile_options(lucia_fabric PRIVATE -Wall -Wextra)

add_executable(loom loom/main.cpp)
target_link_libraries(loom PRIVATE lucia_fabric lucia_realm lucia_crypto lucia_storage)
target_compile_options(loom PRIVATE -Wall -Wextra)

enable_testing()

add_executable(volume_test tests/volume_test.cpp)
target_link_libraries(volume_test PRIVATE lucia_storage)
add_test(NAME volume_test COMMAND volume_test)

add_executable(fabric_test tests/fabric_test.cpp)
target_link_libraries(fabric_test PRIVATE lucia_fabric lucia_crypto)
add_test(NAME fabric_test COMMAND fabric_test)

add_executable(store_test tests/store_test.cpp)
target_link_libraries(store_test PRIVATE lucia_fabric lucia_realm lucia_crypto)
add_test(NAME store_test COMMAND store_test)

add_test(NAME loom_demo COMMAND loom demo --image ${CMAKE_BINARY_DIR}/loom-demo.img --key ${CMAKE_BINARY_DIR}/loom-demo.key)
