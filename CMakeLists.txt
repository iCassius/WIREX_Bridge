cmake_minimum_required(VERSION 3.16)
project(wirex_dmrd LANGUAGES CXX)

add_library(wirex_dmrd src/dmrd.cpp)
target_include_directories(wirex_dmrd PUBLIC include)
target_compile_features(wirex_dmrd PUBLIC cxx_std_17)

if(MSVC)
    target_compile_options(wirex_dmrd PRIVATE /W4 /permissive-)
else()
    target_compile_options(wirex_dmrd PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_executable(dmrd_test tests/dmrd_test.cpp)
target_link_libraries(dmrd_test PRIVATE wirex_dmrd)

enable_testing()
add_test(NAME dmrd_test COMMAND dmrd_test)
