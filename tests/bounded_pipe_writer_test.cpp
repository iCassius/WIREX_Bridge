#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "wirex/bounded_pipe_writer.hpp"

#include <array>
#include <chrono>
#include <iostream>
#include <string>

int main()
{
    HANDLE read_handle = INVALID_HANDLE_VALUE;
    HANDLE write_handle = INVALID_HANDLE_VALUE;
    if (!CreatePipe(&read_handle, &write_handle, nullptr, 4096)) {
        std::cerr << "CreatePipe failed\n";
        return 1;
    }
    wirex::bounded_pipe_writer::Writer writer(write_handle);
    if (!writer.enable_nonblocking()) {
        CloseHandle(read_handle);
        CloseHandle(write_handle);
        std::cerr << "Could not enable nonblocking anonymous-pipe writes\n";
        return 1;
    }
    std::array<char, 1024> fill{};
    bool filled = false;
    for (int i = 0; i < 100; ++i) {
        DWORD written = 0;
        if (!WriteFile(write_handle, fill.data(), static_cast<DWORD>(fill.size()), &written, nullptr) || written == 0) {
            filled = true;
            break;
        }
    }
    if (!filled) {
        CloseHandle(read_handle);
        CloseHandle(write_handle);
        std::cerr << "Anonymous pipe did not reach its bounded full state\n";
        return 1;
    }
    const auto before = std::chrono::steady_clock::now();
    const bool full_pipe_write = writer.write_line("{\"type\":\"snapshot\"}", 60);
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - before).count();
    if (full_pipe_write || elapsed > 500) {
        CloseHandle(read_handle);
        CloseHandle(write_handle);
        std::cerr << "Full anonymous pipe did not fail within a finite deadline\n";
        return 1;
    }
    CloseHandle(read_handle);
    const bool disconnected_write = writer.write_line("{}", 60);
    CloseHandle(write_handle);
    if (disconnected_write) {
        std::cerr << "Disconnected anonymous pipe write was reported as successful\n";
        return 1;
    }
    std::cout << "bounded pipe writer tests passed\n";
    return 0;
}
