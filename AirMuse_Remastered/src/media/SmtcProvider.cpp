#include "SmtcProvider.hpp"
#include <mmdeviceapi.h>
#include <audiopolicy.h>
#include <psapi.h>
#include <wrl/client.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Storage.Streams.h>
#include <algorithm>
#include <cwctype>

using namespace winrt;
using namespace winrt::Windows::Media::Control;
using namespace winrt::Windows::Storage::Streams;
using Microsoft::WRL::ComPtr;

namespace airmuse {

namespace {

bool ContainsIgnoreCase(std::wstring const& haystack, std::wstring const& needle) {
    auto it = std::search(
        haystack.begin(), haystack.end(),
        needle.begin(), needle.end(),
        [](wchar_t a, wchar_t b) { return std::towlower(a) == std::towlower(b); }
    );
    return it != haystack.end();
}

bool IsSupportedMusicSession(std::wstring const& appId) {
    if (ContainsIgnoreCase(appId, L"AirMuse")) return false;
    return ContainsIgnoreCase(appId, L"AppleMusic") ||
           ContainsIgnoreCase(appId, L"Spotify") ||
           ContainsIgnoreCase(appId, L"QQMusic") ||
           ContainsIgnoreCase(appId, L"CloudMusic") ||
           ContainsIgnoreCase(appId, L"foobar2000") ||
           ContainsIgnoreCase(appId, L"MusicBee");
}

std::wstring FriendlyAppName(std::wstring const& appId) {
    if (ContainsIgnoreCase(appId, L"AppleMusic")) return L"Apple Music";
    if (ContainsIgnoreCase(appId, L"Spotify"))    return L"Spotify";
    if (ContainsIgnoreCase(appId, L"QQMusic"))    return L"QQ 音乐";
    if (ContainsIgnoreCase(appId, L"CloudMusic")) return L"网易云音乐";
    return L"Desktop Media";
}

} // namespace

SmtcProvider::~SmtcProvider() { Shutdown(); }

bool SmtcProvider::Initialize(HWND notifyHwnd, UINT notifyMsg) {
    m_hwnd = notifyHwnd;
    m_notifyMsg = notifyMsg;
    try {
        m_manager = GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
        if (!m_manager) return false;
        m_sessionsChangedToken = m_manager.SessionsChanged([this](auto&&, auto&&) { RefreshSession(); });
        m_currentChangedToken  = m_manager.CurrentSessionChanged([this](auto&&, auto&&) { RefreshSession(); });
        RefreshSession();
        return true;
    } catch (...) {
        return false;
    }
}

void SmtcProvider::Shutdown() {
    DetachSessionEvents();
    if (m_manager) {
        if (m_sessionsChangedToken.value) m_manager.SessionsChanged(m_sessionsChangedToken);
        if (m_currentChangedToken.value) m_manager.CurrentSessionChanged(m_currentChangedToken);
        m_manager = nullptr;
    }
}

bool SmtcProvider::IsAvailable() const {
    std::lock_guard lock(m_mutex);
    return !m_state.providerId.empty();
}

NowPlayingState SmtcProvider::GetState() const {
    std::lock_guard lock(m_mutex);
    return m_state;
}

void SmtcProvider::RefreshSession() {
    if (!m_manager) return;
    GlobalSystemMediaTransportControlsSession target{ nullptr };
    try {
        auto sessions = m_manager.GetSessions();
        GlobalSystemMediaTransportControlsSession fallback{ nullptr };
        for (uint32_t i = 0; i < sessions.Size(); ++i) {
            auto s = sessions.GetAt(i);
            std::wstring appId(s.SourceAppUserModelId().c_str());
            if (!IsSupportedMusicSession(appId)) continue;

            bool playing = false;
            try {
                playing = (s.GetPlaybackInfo().PlaybackStatus() ==
                           GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing);
            } catch (...) {}

            if (playing) { target = s; break; }
            if (!fallback) fallback = s;
        }
        if (!target) target = fallback;
    } catch (...) {
        target = nullptr;
    }

    DetachSessionEvents();
    m_session = target;

    if (m_session) {
        std::wstring appId(m_session.SourceAppUserModelId().c_str());
        float curVol = 0.8f;
        SetAppProcessVolume(appId, -1.0f, &curVol);
        {
            std::lock_guard lock(m_mutex);
            m_state.providerId = appId;
            m_state.sourceName = FriendlyAppName(appId);
            m_state.volume = curVol;
        }
        AttachSessionEvents(m_session);
        UpdateMediaProperties();
        UpdatePlaybackInfo();
        UpdateTimeline();
    } else {
        std::lock_guard lock(m_mutex);
        m_state = NowPlayingState{};
    }
    NotifyUI();
}

void SmtcProvider::AttachSessionEvents(GlobalSystemMediaTransportControlsSession const& session) {
    m_mediaPropsToken = session.MediaPropertiesChanged([this](auto&&, auto&&) { UpdateMediaProperties(); NotifyUI(); });
    m_playbackInfoToken = session.PlaybackInfoChanged([this](auto&&, auto&&) { UpdatePlaybackInfo(); NotifyUI(); });
    m_timelineToken = session.TimelinePropertiesChanged([this](auto&&, auto&&) { UpdateTimeline(); NotifyUI(); });
}

void SmtcProvider::DetachSessionEvents() {
    if (m_session) {
        if (m_mediaPropsToken.value) m_session.MediaPropertiesChanged(m_mediaPropsToken);
        if (m_playbackInfoToken.value) m_session.PlaybackInfoChanged(m_playbackInfoToken);
        if (m_timelineToken.value) m_session.TimelinePropertiesChanged(m_timelineToken);
    }
    m_mediaPropsToken = {};
    m_playbackInfoToken = {};
    m_timelineToken = {};
    m_session = nullptr;
}

void SmtcProvider::UpdateMediaProperties() {
    if (!m_session) return;
    try {
        auto props = m_session.TryGetMediaPropertiesAsync().get();
        if (!props) return;
        std::vector<uint8_t> thumbData;
        if (auto thumbRef = props.Thumbnail()) {
            try {
                auto stream = thumbRef.OpenReadAsync().get();
                uint64_t size = stream.Size();
                if (size > 0 && size < 4 * 1024 * 1024) {
                    DataReader reader(stream);
                    reader.LoadAsync(static_cast<uint32_t>(size)).get();
                    thumbData.resize(static_cast<size_t>(size));
                    reader.ReadBytes(thumbData);
                }
            } catch (...) {}
        }
        std::lock_guard lock(m_mutex);
        m_state.title  = props.Title().empty() ? L"Unknown Track" : std::wstring(props.Title().c_str());
        m_state.artist = props.Artist().empty() ? L"Unknown Artist" : std::wstring(props.Artist().c_str());
        m_state.album  = std::wstring(props.AlbumTitle().c_str());
        if (!thumbData.empty()) m_state.artworkBytes = std::move(thumbData);
    } catch (...) {}
}

void SmtcProvider::UpdatePlaybackInfo() {
    if (!m_session) return;
    try {
        auto pb = m_session.GetPlaybackInfo();
        auto ctrls = pb.Controls();
        std::lock_guard lock(m_mutex);
        m_state.isPlaying         = (pb.PlaybackStatus() == GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing);
        m_state.caps.canPlayPause = ctrls.IsPlayPauseToggleEnabled();
        m_state.caps.canNext      = ctrls.IsNextEnabled();
        m_state.caps.canPrevious  = ctrls.IsPreviousEnabled();
        m_state.caps.canSeek      = ctrls.IsPlaybackPositionEnabled();
    } catch (...) {}
}

void SmtcProvider::UpdateTimeline() {
    if (!m_session) return;
    try {
        auto tl = m_session.GetTimelineProperties();
        std::lock_guard lock(m_mutex);
        m_state.positionMs    = tl.Position().count() / 10000;
        m_state.durationMs    = tl.EndTime().count() / 10000;
        m_state.timestampTick = GetTickCount64();
    } catch (...) {}
}

void SmtcProvider::NotifyUI() {
    if (m_hwnd && IsWindow(m_hwnd)) PostMessageW(m_hwnd, m_notifyMsg, 0, 0);
}

void SmtcProvider::PlayPause() { if (m_session) try { m_session.TryTogglePlayPauseAsync(); } catch (...) {} }
void SmtcProvider::Stop()      { if (m_session) try { m_session.TryStopAsync(); } catch (...) {} }
void SmtcProvider::Next()      { if (m_session) try { m_session.TrySkipNextAsync(); } catch (...) {} }
void SmtcProvider::Previous()  { if (m_session) try { m_session.TrySkipPreviousAsync(); } catch (...) {} }

void SmtcProvider::SeekTo(int64_t positionMs) {
    if (!m_session) return;
    try {
        auto tl = m_session.GetTimelineProperties();
        int64_t ticks = std::clamp<int64_t>(positionMs * 10000LL, 0, tl.EndTime().count());
        m_session.TryChangePlaybackPositionAsync(ticks);
    } catch (...) {}
}

void SmtcProvider::SetVolume(float volume0to1) {
    std::wstring appId;
    {
        std::lock_guard lock(m_mutex);
        appId = m_state.providerId;
        m_state.volume = volume0to1;
    }
    if (!appId.empty()) SetAppProcessVolume(appId, volume0to1, nullptr);
}

bool SmtcProvider::SetAppProcessVolume(std::wstring const& appIdHint, float volume0to1, float* outCurrentVol) {
    ComPtr<IMMDeviceEnumerator> enumerator;
    if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator)))) return false;
    ComPtr<IMMDevice> device;
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &device))) return false;
    ComPtr<IAudioSessionManager2> sessionMgr;
    if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr, &sessionMgr))) return false;
    ComPtr<IAudioSessionEnumerator> sessionEnum;
    if (FAILED(sessionMgr->GetSessionEnumerator(&sessionEnum))) return false;

    int count = 0;
    sessionEnum->GetCount(&count);
    bool matched = false;

    for (int i = 0; i < count; ++i) {
        ComPtr<IAudioSessionControl> ctrl;
        if (FAILED(sessionEnum->GetSession(i, &ctrl))) continue;
        ComPtr<IAudioSessionControl2> ctrl2;
        if (FAILED(ctrl.As(&ctrl2))) continue;

        DWORD pid = 0;
        ctrl2->GetProcessId(&pid);
        if (pid == 0) continue;

        HANDLE hProc = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!hProc) continue;

        wchar_t exePath[MAX_PATH]{};
        DWORD sz = MAX_PATH;
        QueryFullProcessImageNameW(hProc, 0, exePath, &sz);
        CloseHandle(hProc);

        std::wstring procName(exePath);
        bool isTarget =
            (ContainsIgnoreCase(appIdHint, L"Spotify") && ContainsIgnoreCase(procName, L"Spotify.exe")) ||
            (ContainsIgnoreCase(appIdHint, L"AppleMusic") && ContainsIgnoreCase(procName, L"AppleMusic.exe")) ||
            (ContainsIgnoreCase(appIdHint, L"QQMusic") && ContainsIgnoreCase(procName, L"QQMusic.exe")) ||
            (ContainsIgnoreCase(appIdHint, L"CloudMusic") && ContainsIgnoreCase(procName, L"cloudmusic.exe"));

        if (isTarget) {
            ComPtr<ISimpleAudioVolume> simpleVol;
            if (SUCCEEDED(ctrl.As(&simpleVol))) {
                if (outCurrentVol) simpleVol->GetMasterVolume(outCurrentVol);
                if (volume0to1 >= 0.0f) simpleVol->SetMasterVolume(std::clamp(volume0to1, 0.0f, 1.0f), nullptr);
                matched = true;
            }
        }
    }
    return matched;
}

} // namespace airmuse
