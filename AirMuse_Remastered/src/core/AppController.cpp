#include "AppController.hpp"
#include <algorithm>
#include <thread>

namespace airmuse {

AppController::AppController() = default;
AppController::~AppController() { Shutdown(); }

bool AppController::Initialize(HWND mainHwnd, HWND webHostHwnd) {
    m_mainHwnd = mainHwnd;

    m_smtcProvider = std::make_shared<SmtcProvider>();
    m_webProvider  = std::make_shared<WebSourceProvider>();

    m_arbitrator.RegisterProvider(m_smtcProvider);
    m_arbitrator.RegisterProvider(m_webProvider);

    m_lyricsEngine.Initialize(mainHwnd, WM_APP_LYRICS_UPDATED);

    std::thread([this, mainHwnd]() {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        m_smtcProvider->Initialize(mainHwnd, WM_APP_STATE_CHANGED);
    }).detach();

    m_webProvider->Initialize(webHostHwnd, mainHwnd, WM_APP_STATE_CHANGED);
    return true;
}

void AppController::Shutdown() {
    if (m_webProvider) m_webProvider->Shutdown();
    if (m_smtcProvider) m_smtcProvider->Shutdown();
}

void AppController::PlayPause() { if (auto p = m_arbitrator.GetActiveProvider()) p->PlayPause(); }
void AppController::Stop()      { if (auto p = m_arbitrator.GetActiveProvider()) p->Stop(); }
void AppController::Next()      { if (auto p = m_arbitrator.GetActiveProvider()) p->Next(); }
void AppController::Previous()  { if (auto p = m_arbitrator.GetActiveProvider()) p->Previous(); }

void AppController::SeekTo(int64_t positionMs) {
    if (auto p = m_arbitrator.GetActiveProvider()) {
        p->SeekTo(positionMs);
        auto cur = m_store.GetPlayback();
        cur.positionMs = positionMs;
        cur.timestampTick = GetTickCount64();
        m_store.UpdatePlayback(cur);
    }
}

void AppController::AdjustVolume(float delta) {
    if (auto p = m_arbitrator.GetActiveProvider()) {
        auto cur = m_store.GetPlayback();
        float nextVol = std::clamp(cur.volume + delta, 0.0f, 1.0f);
        p->SetVolume(nextVol);
        cur.volume = nextVol;
        m_store.UpdatePlayback(cur);
    }
}

void AppController::SwitchWebPlatform(WebPlatform platform) {
    if (m_webProvider) m_webProvider->SwitchPlatform(platform);
}

WebPlatform AppController::CurrentWebPlatform() const {
    return m_webProvider ? m_webProvider->CurrentPlatform() : WebPlatform::AppleMusic;
}

std::wstring AppController::CurrentWebUserName() const {
    return m_webProvider ? m_webProvider->GetLoggedInUser() : L"";
}

void AppController::SetWebVisible(bool visible) {
    if (m_webProvider) m_webProvider->SetVisible(visible);
}

void AppController::ResizeWebHost(int widthPx, int heightPx) {
    if (m_webProvider) m_webProvider->Resize(widthPx, heightPx);
}

void AppController::JumpToPlayingContext() {
    if (m_webProvider) m_webProvider->NavigateToPlayingContext();
}

void AppController::PlayAppleMusicTrack(const std::wstring& kind, const std::wstring& collectionId, int trackIdx, const std::wstring& trackId) {
    if (m_webProvider) m_webProvider->PlayAppleMusicTrack(kind, collectionId, trackIdx, trackId);
}

void AppController::PlayAppleMusicStation(const std::wstring& stationId) {
    if (m_webProvider) m_webProvider->PlayAppleMusicStation(stationId);
}

void AppController::AdjustLyricsOffset(int64_t deltaMs) {
    auto cur = m_store.GetPlayback();
    m_lyricsEngine.AdjustOffset(cur.TrackKey(), deltaMs);
    m_store.UpdateLyrics(m_lyricsEngine.GetSnapshot());
}

void AppController::OnMediaSourceUpdated() {
    NowPlayingState best = m_arbitrator.ResolveBestState();
    m_store.UpdatePlayback(best);

    std::wstring key = best.TrackKey();
    if (!best.title.empty() && best.title != L"AirMuse Ready" && key != m_lastQueriedTrackKey) {
        m_lastQueriedTrackKey = key;
        m_lyricsEngine.RequestLyrics(best.title, best.artist, best.durationMs);
        m_store.UpdateLyrics(m_lyricsEngine.GetSnapshot());
    }
}

void AppController::OnLyricsUpdated() {
    m_store.UpdateLyrics(m_lyricsEngine.GetSnapshot());
}

} // namespace airmuse
