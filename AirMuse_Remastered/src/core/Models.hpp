#pragma once
#include "WinCommon.hpp"
#include <string>
#include <vector>
#include <cstdint>

namespace airmuse {

constexpr UINT WM_APP_STATE_CHANGED  = WM_APP + 10;
constexpr UINT WM_APP_LYRICS_UPDATED = WM_APP + 11;
constexpr UINT WM_APP_TRAY_ICON      = WM_APP + 12;

enum class DockSide { None = 0, Bottom, Top, Left, Right };
enum class WebPlatform { AppleMusic = 0, Spotify = 1, QQMusic = 2 };

struct MediaCapabilities {
    bool canPlayPause = true;
    bool canNext      = true;
    bool canPrevious  = true;
    bool canSeek      = true;
    bool canSetVolume = true;
};

struct NowPlayingState {
    std::wstring providerId;
    std::wstring sourceName = L"Ready";
    std::wstring title      = L"AirMuse Ready";
    std::wstring artist     = L"Waiting for playback...";
    std::wstring album;
    std::wstring contextTitle;
    std::wstring contextType;
    std::wstring webUserName;
    bool isPlaying          = false;
    int64_t positionMs      = 0;
    int64_t durationMs      = 0;
    ULONGLONG timestampTick = 0;
    float volume            = 0.8f;
    std::vector<uint8_t> artworkBytes;
    MediaCapabilities caps{};

    std::wstring TrackKey() const { return title + L"|" + artist; }

    int64_t EstimatedPositionMs() const {
        if (!isPlaying || timestampTick == 0) return positionMs;
        ULONGLONG elapsed = GetTickCount64() - timestampTick;
        int64_t est = positionMs + static_cast<int64_t>(elapsed);
        if (durationMs > 0 && est > durationMs) est = durationMs;
        return est;
    }
};

struct LyricLine {
    int64_t timeMs = 0;
    std::wstring text;
    std::wstring trans;
};

struct LyricsSnapshot {
    std::wstring trackKey;
    std::vector<LyricLine> lines;
    bool loading = false;
    int64_t offsetMs = 0;
    std::wstring statusText = L"暂无歌词";
};

} // namespace airmuse
