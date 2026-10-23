#include "wirex/audio_input_cleanup.hpp"

#include <iostream>

int main()
{
    wirex::audio_input_cleanup::State state;
    bool input_open = true;
    int close_calls = 0;
    const bool closed = state.close_if_open(input_open, [&]() {
        ++close_calls;
        return false;
    });
    if (closed || input_open || !state.close_failed() || state.reopen_allowed() || close_calls != 1) {
        std::cerr << "WaveIn close failure did not remain sticky\n";
        return 1;
    }
    if (state.close_if_open(input_open, [&]() {
            ++close_calls;
            return true;
        }) || close_calls != 1 || state.reopen_allowed()) {
        std::cerr << "WaveIn close failure allowed a retry/reopen\n";
        return 1;
    }
    std::cout << "audio input cleanup tests passed\n";
    return 0;
}
