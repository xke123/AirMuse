#pragma once
#include "IMediaSourceProvider.hpp"
#include "WebAdapters.hpp"

namespace airmuse {

class WebSourceProvider : public IMediaSourceProvider {
public:
    WebSourceProvider() = default;
    ~WebSourceProvider() override;

    bool Initialize(HWND hostHwnd, HWND notifyHwnd, UINT notifyMsg);
    void Shutdown();

    void SwitchPlatform(WebPlatform platform);
    WebPlatform CurrentPlatform() const { return m_platform; }
    std::wstring GetLoggedInUser() const;
    void Resize(int widthPx, int heightPx);
    void SetVisible(bool visible);
    void NavigateToPlayingContext();

    void PlayAppleMusicTrack(const std::wstring& kind, const std::wstring& collectionId, int trackIdx, const std::wstring& trackId);
    void PlayAppleMusicStation(const std::wstring& stationId);

    std::wstring Id() const override { return L"embedded_web"; }
    int BasePriority() const override { return 20; }
    bool IsAvailable() const override;
    NowPlayingState GetState() const override;

    void PlayPause() override;
    void Stop() override;
    void Next() override;
    void Previous() override;
    void SeekTo(int64_t positionMs) override;
    void SetVolume(float volume0to1) override;

private:
    HWND m_hostHwnd = nullptr;
    HWND m_notifyHwnd = nullptr;
    UINT m_notifyMsg = 0;
    WebPlatform m_platform = WebPlatform::AppleMusic;
    struct Impl;
    Impl* m_impl = nullptr;
};

} // namespace airmuse
