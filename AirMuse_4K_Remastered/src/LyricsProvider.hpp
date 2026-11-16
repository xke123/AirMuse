#pragma once
#include <windows.h>
#include <string>
#include <vector>
#include <mutex>
#include <unordered_map>
#include <cstdint>

struct LyricLine {
    int64_t timeMs = 0;
    std::wstring text;
    std::wstring trans;
};

struct LyricsSnapshot {
    std::wstring trackKey;
    std::vector<LyricLine> lines;
    bool loading = false;
    std::wstring statusText;
};

class LyricsProvider {
public:
    void Initialize(HWND notifyHwnd, UINT notifyMsg);
    void RequestLyrics(std::wstring const& title, std::wstring const& artist, int64_t durationMs);
    LyricsSnapshot GetSnapshot() const;

private:
    void FetchWorker(std::wstring key, std::wstring title, std::wstring artist, int64_t durationMs);
    void NotifyUI();

    HWND m_hwnd = nullptr;
    UINT m_notifyMsg = 0;

    mutable std::mutex m_mutex;
    LyricsSnapshot m_current;
    std::unordered_map<std::wstring, std::vector<LyricLine>> m_cache;
};
