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

add_library(wirex_direct_frame src/direct_frame.cpp)
target_include_directories(wirex_direct_frame PUBLIC include)
target_compile_features(wirex_direct_frame PUBLIC cxx_std_17)

if(MSVC)
    target_compile_options(wirex_direct_frame PRIVATE /W4 /permissive-)
else()
    target_compile_options(wirex_direct_frame PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_executable(direct_frame_test tests/direct_frame_test.cpp)
target_link_libraries(direct_frame_test PRIVATE wirex_direct_frame)

enable_testing()
add_test(NAME dmrd_test COMMAND dmrd_test)
add_test(NAME direct_frame_test COMMAND direct_frame_test)
