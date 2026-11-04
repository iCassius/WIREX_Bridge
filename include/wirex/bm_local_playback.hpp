#pragma once

#include <cstdint>

namespace wirex::bm_local_playback {

// A route is selected once per admitted BM call. A call that starts without an
// HRI radio can still be presented locally, or kept visible with audio dropped
// when the selected WaveOut endpoint is unavailable.
enum class Route : std::uint8_t {
    inactive,
    radio,
    local_output,
    silent,
};

enum class AudioState : std::uint8_t {
    inactive,
    ready,
    playing,
    unavailable,
    failed,
};

enum class OutputError : std::uint8_t {
    none,
    selection_unavailable,
    open_failed,
    submit_failed,
    device_lost,
    close_failed,
};

enum class BeginResult : std::uint8_t {
    radio,
    local_output,
    silent,
    busy,
    invalid_generation,
    shutting_down,
};

struct Snapshot {
    Route route{Route::inactive};
    AudioState audio_state{AudioState::inactive};
    OutputError output_error{OutputError::none};
    bool radio_ready{};
    bool output_open{};
    bool call_active{};
    bool accepting_calls{true};
    std::uint64_t generation{};
};

class Session final {
public:
    // Called by the engine thread when HRI or the selected WaveOut endpoint
    // changes. An active call keeps its chosen route; a lost local output moves
    // it to silent draining so the BM call can remain visible and finish.
    void set_environment(bool radio_ready, bool output_open) noexcept {
        state_.radio_ready = radio_ready;
        state_.output_open = output_open;
        if (!output_open && state_.call_active && state_.route == Route::local_output) {
            state_.route = Route::silent;
            if (state_.output_error == OutputError::none) {
                state_.output_error = OutputError::device_lost;
            }
        }
        update_audio_state();
    }

    void output_available() noexcept {
        state_.output_error = OutputError::none;
        state_.output_open = true;
        update_audio_state();
    }

    void output_unavailable(OutputError error) noexcept {
        if (error == OutputError::none) error = OutputError::selection_unavailable;
        state_.output_error = error;
        state_.output_open = false;
        if (state_.call_active && state_.route == Route::local_output) {
            state_.route = Route::silent;
        }
        update_audio_state();
    }

    [[nodiscard]] BeginResult begin_call(std::uint64_t generation) noexcept {
        if (!state_.accepting_calls) return BeginResult::shutting_down;
        if (state_.call_active) return BeginResult::busy;
        if (generation == 0U) return BeginResult::invalid_generation;

        state_.generation = generation;
        state_.call_active = true;
        if (state_.radio_ready) {
            state_.route = Route::radio;
            update_audio_state();
            return BeginResult::radio;
        }
        if (state_.output_open) {
            state_.route = Route::local_output;
            update_audio_state();
            return BeginResult::local_output;
        }
        state_.route = Route::silent;
        update_audio_state();
        return BeginResult::silent;
    }

    [[nodiscard]] bool output_failed(OutputError error) noexcept {
        if (error == OutputError::none) return false;
        state_.output_error = error;
        state_.output_open = false;
        if (state_.call_active && state_.route == Route::local_output) {
            state_.route = Route::silent;
        }
        update_audio_state();
        return true;
    }

    [[nodiscard]] bool end_call(std::uint64_t generation) noexcept {
        if (!state_.call_active || generation == 0U || generation != state_.generation) return false;
        state_.call_active = false;
        state_.generation = 0U;
        state_.route = Route::inactive;
        update_audio_state();
        return true;
    }

    // A BM header can reserve a call before its first voice burst. If HRI attach
    // temporarily owns the output and then fails during that wait, the engine
    // may reselect a route before it admits playback. Once playback starts, this
    // method is no longer called and the route stays fixed for that stream.
    [[nodiscard]] bool retarget_pending_call(std::uint64_t generation,
                                             bool radio_ready,
                                             bool output_open) noexcept {
        if (!state_.call_active || generation == 0U || generation != state_.generation) return false;
        state_.radio_ready = radio_ready;
        state_.output_open = output_open;
        if (radio_ready) {
            state_.route = Route::radio;
        } else if (output_open && state_.output_error == OutputError::none) {
            state_.route = Route::local_output;
        } else {
            state_.route = Route::silent;
        }
        update_audio_state();
        return true;
    }

    // Do not switch a selected output while the Router owns media, an admitted
    // call is active, or a previous output still has queued WaveOut frames.
    [[nodiscard]] bool can_change_output(bool media_idle, bool output_drained) const noexcept {
        return state_.accepting_calls && !state_.call_active && media_idle && output_drained;
    }

    void request_shutdown() noexcept { state_.accepting_calls = false; }

    [[nodiscard]] bool finish_shutdown(bool output_still_open) noexcept {
        if (state_.accepting_calls || state_.call_active) return false;
        if (output_still_open) {
            state_.output_error = OutputError::close_failed;
            state_.output_open = true;
            return false;
        }
        state_ = Snapshot{};
        state_.accepting_calls = false;
        return true;
    }

    [[nodiscard]] const Snapshot& snapshot() const noexcept { return state_; }

    [[nodiscard]] bool should_send_hri() const noexcept { return state_.route == Route::radio; }
    [[nodiscard]] bool should_submit_audio() const noexcept {
        return state_.route == Route::radio || state_.route == Route::local_output;
    }
    [[nodiscard]] bool should_discard_audio() const noexcept { return state_.route == Route::silent; }

private:
    void update_audio_state() noexcept {
        if (state_.route == Route::radio || (!state_.call_active && state_.radio_ready)) {
            state_.audio_state = AudioState::inactive;
        } else if (state_.call_active && state_.route == Route::local_output) {
            state_.audio_state = AudioState::playing;
        } else if (!state_.call_active && state_.output_open) {
            state_.audio_state = AudioState::ready;
        } else if (state_.output_error != OutputError::none) {
            state_.audio_state = AudioState::failed;
        } else if (state_.radio_ready) {
            state_.audio_state = AudioState::inactive;
        } else if (state_.output_open || state_.route == Route::silent) {
            state_.audio_state = AudioState::unavailable;
        } else {
            state_.audio_state = AudioState::inactive;
        }
    }

    Snapshot state_{};
};

} // namespace wirex::bm_local_playback
