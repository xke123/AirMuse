#pragma once
#include "Models.hpp"
#include <mutex>

namespace airmuse {

class PlaybackStore {
public:
    void UpdatePlayback(NowPlayingState const& state) {
        std::lock_guard lock(m_mutex);
        if (state.artworkBytes.empty() && state.TrackKey() == m_state.TrackKey()) {
            auto savedArt = std::move(m_state.artworkBytes);
            m_state = state;
            m_state.artworkBytes = std::move(savedArt);
        } else {
            m_state = state;
        }
    }

    NowPlayingState GetPlayback() const {
        std::lock_guard lock(m_mutex);
        return m_state;
    }

    void UpdateLyrics(LyricsSnapshot const& snap) {
        std::lock_guard lock(m_mutex);
        m_lyrics = snap;
    }

    LyricsSnapshot GetLyrics() const {
        std::lock_guard lock(m_mutex);
        return m_lyrics;
    }

private:
    mutable std::mutex m_mutex;
    NowPlayingState m_state;
    LyricsSnapshot m_lyrics;
};

} // namespace airmuse