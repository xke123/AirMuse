#pragma once
#include "IMediaSourceProvider.hpp"
#include <mutex>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.Control.h>

namespace airmuse {

class SmtcProvider : public IMediaSourceProvider {
public:
    SmtcProvider() = default;
    ~SmtcProvider() override;

    bool Initialize(HWND notifyHwnd, UINT notifyMsg);
    void Shutdown();

    std::wstring Id() const override { return L"system_smtc"; }
    int BasePriority() const override { return 10; }
    bool IsAvailable() const override;
    NowPlayingState GetState() const override;

    void PlayPause() override;
    void Stop() override;
    void Next() override;
    void Previous() override;
    void SeekTo(int64_t positionMs) override;
    void SetVolume(float volume0to1) override;

private:
    void RefreshSession();
    void AttachSessionEvents(winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSession const& session);
    void DetachSessionEvents();
    void UpdateMediaProperties();
    void UpdatePlaybackInfo();
    void UpdateTimeline();
    void NotifyUI();

    static bool SetAppProcessVolume(std::wstring const& appIdHint, float volume0to1, float* outCurrentVol = nullptr);

    HWND m_hwnd = nullptr;
    UINT m_notifyMsg = 0;
    mutable std::mutex m_mutex;
    NowPlayingState m_state;

    winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSessionManager m_manager{ nullptr };
    winrt::Windows::Media::Control::GlobalSystemMediaTransportControlsSession m_session{ nullptr };
    winrt::event_token m_sessionsChangedToken{};
    winrt::event_token m_currentChangedToken{};
    winrt::event_token m_mediaPropsToken{};
    winrt::event_token m_playbackInfoToken{};
    winrt::event_token m_timelineToken{};
};

} // namespace airmuse