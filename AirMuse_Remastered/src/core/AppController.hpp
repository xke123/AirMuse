#pragma once
#include <windows.h>
#include <memory>
#include "PlaybackStore.hpp"
#include "../media/MediaArbitrator.hpp"
#include "../media/SmtcProvider.hpp"
#include "../media/WebSourceProvider.hpp"
#include "../lyrics/LyricsEngine.hpp"

namespace airmuse {

class AppController {
public:
    AppController();
    ~AppController();

    bool Initialize(HWND mainHwnd, HWND webHostHwnd);
    void Shutdown();

    PlaybackStore& Store() { return m_store; }
    PlaybackStore const& Store() const { return m_store; }

    void PlayPause();
    void Stop();
    void Next();
    void Previous();
    void SeekTo(int64_t positionMs);
    void AdjustVolume(float delta);

    void SwitchWebPlatform(WebPlatform platform);
    WebPlatform CurrentWebPlatform() const;
    std::wstring CurrentWebUserName() const;
    void SetWebVisible(bool visible);
    void ResizeWebHost(int widthPx, int heightPx);
    void JumpToPlayingContext();
    void PlayAppleMusicTrack(const std::wstring& kind, const std::wstring& collectionId, int trackIdx, const std::wstring& trackId);
    void PlayAppleMusicStation(const std::wstring& stationId);

    void AdjustLyricsOffset(int64_t deltaMs);

    void OnMediaSourceUpdated();
    void OnLyricsUpdated();

private:
    HWND m_mainHwnd = nullptr;
    PlaybackStore m_store;
    MediaArbitrator m_arbitrator;
    std::shared_ptr<SmtcProvider> m_smtcProvider;
    std::shared_ptr<WebSourceProvider> m_webProvider;
    LyricsEngine m_lyricsEngine;
    std::wstring m_lastQueriedTrackKey;
};

} // namespace airmuse
