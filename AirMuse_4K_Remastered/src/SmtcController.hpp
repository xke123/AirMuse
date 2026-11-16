#pragma once
#include <windows.h>
#include <string>
#include <vector>
#include <functional>
#include <mutex>
#include <cstdint>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>

struct NowPlayingInfo {
    std::wstring title = L"Apple Music 未播放";
    std::wstring artist = L"等待媒体会话...";
    std::wstring album;
    std::wstring sourceAppId;
    bool isPlaying = false;
    bool isAppleMusic = false;
    int64_t positionMs = 0;
    int64_t durationMs = 0;
    std::vector<uint8_t> thumbnailBytes;
};

class SmtcController {
public:
    using UpdateCallback = std::function<void()>;

    SmtcController() = default;
    ~SmtcController();

    bool Initialize(HWND notifyHwnd, UINT notifyMsg);
    void Shutdown();

    NowPlayingInfo GetSnapshot() const;

    void PlayPause();
    void Stop();
    void Next();
    void Previous();
    void SeekRelativeSeconds(int deltaSec);
    bool SeekToPositionMs(int64_t targetMs);
    void VolumeStep(bool up);

private:
    void RefreshSession();
    void AttachSessionEvents(winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSession const& session);
    void DetachSessionEvents();
    void UpdateMediaProperties();
    void UpdatePlaybackInfo();
    void UpdateTimeline();
    void NotifyUI();

    HWND m_hwnd = nullptr;
    UINT m_notifyMsg = 0;

    mutable std::mutex m_mutex;
    NowPlayingInfo m_info;

    winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionManager m_manager{ nullptr };
    winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSession m_session{ nullptr };

    winrt::event_token m_sessionsChangedToken{};
    winrt::event_token m_currentChangedToken{};
    winrt::event_token m_mediaPropsToken{};
    winrt::event_token m_playbackInfoToken{};
    winrt::event_token m_timelineToken{};
};
