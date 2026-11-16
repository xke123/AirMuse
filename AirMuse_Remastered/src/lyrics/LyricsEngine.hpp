#pragma once
#include "../core/Models.hpp"
#include <mutex>
#include <unordered_map>

namespace airmuse {

class LyricsEngine {
public:
    void Initialize(HWND notifyHwnd, UINT notifyMsg);
    void RequestLyrics(std::wstring const& title, std::wstring const& artist, int64_t durationMs);
    void AdjustOffset(std::wstring const& trackKey, int64_t deltaMs);
    LyricsSnapshot GetSnapshot() const;

private:
    void FetchWorker(std::wstring key, std::wstring title, std::wstring artist, int64_t durationMs);
    void NotifyUI();

    HWND m_hwnd = nullptr;
    UINT m_notifyMsg = 0;
    mutable std::mutex m_mutex;
    LyricsSnapshot m_current;
    std::unordered_map<std::wstring, std::vector<LyricLine>> m_cache;
    std::unordered_map<std::wstring, int64_t> m_offsets;
};

} // namespace airmuse