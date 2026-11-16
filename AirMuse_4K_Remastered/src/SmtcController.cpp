#include "SmtcController.hpp"
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Storage.Streams.h>
#include <algorithm>
#include <cwctype>

using namespace winrt;
using namespace Windows::Media::Control;
using namespace Windows::Storage::Streams;

namespace {
bool ContainsIgnoreCase(std::wstring const& haystack, std::wstring const& needle) {
    auto it = std::search(
        haystack.begin(), haystack.end(),
        needle.begin(), needle.end(),
        [](wchar_t a, wchar_t b) { return std::towlower(a) == std::towlower(b); }
    );
    return it != haystack.end();
}

bool IsAllowedAppleMusicSession(std::wstring const& appId) {
    return ContainsIgnoreCase(appId, L"AppleMusic") ||
           ContainsIgnoreCase(appId, L"AppleInc.AppleMusic") ||
           ContainsIgnoreCase(appId, L"AirMuse");
}
} // namespace

SmtcController::~SmtcController() {
    Shutdown();
}

bool SmtcController::Initialize(HWND notifyHwnd, UINT notifyMsg) {
    m_hwnd = notifyHwnd;
    m_notifyMsg = notifyMsg;

    try {
        m_manager = GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get();
        if (!m_manager) return false;

        m_sessionsChangedToken = m_manager.SessionsChanged([this](auto&&, auto&&) {
            RefreshSession();
        });
        m_currentChangedToken = m_manager.CurrentSessionChanged([this](auto&&, auto&&) {
            RefreshSession();
        });

        RefreshSession();
        return true;
    } catch (...) {
        return false;
    }
}

void SmtcController::Shutdown() {
    DetachSessionEvents();
    if (m_manager) {
        if (m_sessionsChangedToken.value) m_manager.SessionsChanged(m_sessionsChangedToken);
        if (m_currentChangedToken.value) m_manager.CurrentSessionChanged(m_currentChangedToken);
        m_manager = nullptr;
    }
}

NowPlayingInfo SmtcController::GetSnapshot() const {
    std::lock_guard lock(m_mutex);
    return m_info;
}

void SmtcController::RefreshSession() {
    if (!m_manager) return;

    GlobalSystemMediaTransportControlsSession target{ nullptr };
    try {
        auto sessions = m_manager.GetSessions();
        GlobalSystemMediaTransportControlsSession fallbackAllowed{ nullptr };

        for (uint32_t i = 0; i < sessions.Size(); ++i) {
            auto s = sessions.GetAt(i);
            std::wstring appId(s.SourceAppUserModelId().c_str());
            if (!IsAllowedAppleMusicSession(appId)) {
                continue;
            }

            bool isPlaying = false;
            try {
                isPlaying = (s.GetPlaybackInfo().PlaybackStatus() ==
                             GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing);
            } catch (...) {}

            if (isPlaying) {
                target = s;
                break;
            }
            if (!fallbackAllowed) {
                fallbackAllowed = s;
            }
        }

        if (!target) {
            target = fallbackAllowed;
        }
    } catch (...) {
        target = nullptr;
    }

    DetachSessionEvents();
    m_session = target;

    if (m_session) {
        {
            std::lock_guard lock(m_mutex);
            std::wstring appId(m_session.SourceAppUserModelId().c_str());
            m_info.sourceAppId = appId;
            m_info.isAppleMusic = IsAllowedAppleMusicSession(appId);
        }
        AttachSessionEvents(m_session);
        UpdateMediaProperties();
        UpdatePlaybackInfo();
        UpdateTimeline();
    } else {
        std::lock_guard lock(m_mutex);
        m_info = NowPlayingInfo{};
    }
    NotifyUI();
}

void SmtcController::AttachSessionEvents(GlobalSystemMediaTransportControlsSession const& session) {
    m_mediaPropsToken = session.MediaPropertiesChanged([this](auto&&, auto&&) {
        UpdateMediaProperties();
        NotifyUI();
    });
    m_playbackInfoToken = session.PlaybackInfoChanged([this](auto&&, auto&&) {
        UpdatePlaybackInfo();
        NotifyUI();
    });
    m_timelineToken = session.TimelinePropertiesChanged([this](auto&&, auto&&) {
        UpdateTimeline();
        NotifyUI();
    });
}

void SmtcController::DetachSessionEvents() {
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

void SmtcController::UpdateMediaProperties() {
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
        m_info.title = props.Title().empty() ? L"未知曲目" : std::wstring(props.Title().c_str());
        m_info.artist = props.Artist().empty() ? L"未知艺术家" : std::wstring(props.Artist().c_str());
        m_info.album = std::wstring(props.AlbumTitle().c_str());
        if (!thumbData.empty()) {
            m_info.thumbnailBytes = std::move(thumbData);
        }
    } catch (...) {}
}

void SmtcController::UpdatePlaybackInfo() {
    if (!m_session) return;
    try {
        auto pb = m_session.GetPlaybackInfo();
        std::lock_guard lock(m_mutex);
        m_info.isPlaying = (pb.PlaybackStatus() == GlobalSystemMediaTransportControlsSessionPlaybackStatus::Playing);
    } catch (...) {}
}

void SmtcController::UpdateTimeline() {
    if (!m_session) return;
    try {
        auto tl = m_session.GetTimelineProperties();
        std::lock_guard lock(m_mutex);
        m_info.positionMs = tl.Position().count() / 10000;
        m_info.durationMs = tl.EndTime().count() / 10000;
    } catch (...) {}
}

void SmtcController::NotifyUI() {
    if (m_hwnd && IsWindow(m_hwnd)) {
        PostMessageW(m_hwnd, m_notifyMsg, 0, 0);
    }
}

void SmtcController::PlayPause() {
    if (m_session) {
        try { m_session.TryTogglePlayPauseAsync(); } catch (...) {}
    }
}

void SmtcController::Stop() {
    if (m_session) {
        try { m_session.TryStopAsync(); } catch (...) {}
    }
}

void SmtcController::Next() {
    if (m_session) {
        try { m_session.TrySkipNextAsync(); } catch (...) {}
    }
}

void SmtcController::Previous() {
    if (m_session) {
        try { m_session.TrySkipPreviousAsync(); } catch (...) {}
    }
}

void SmtcController::SeekRelativeSeconds(int deltaSec) {
    if (!m_session) return;
    try {
        auto tl = m_session.GetTimelineProperties();
        int64_t nextTicks = tl.Position().count() + static_cast<int64_t>(deltaSec) * 10000000LL;
        nextTicks = std::clamp<int64_t>(nextTicks, 0, tl.EndTime().count());
        m_session.TryChangePlaybackPositionAsync(nextTicks);
    } catch (...) {}
}

void SmtcController::VolumeStep(bool up) {
    WORD vk = up ? VK_VOLUME_UP : VK_VOLUME_DOWN;
    INPUT in[2]{};
    in[0].type = INPUT_KEYBOARD; in[0].ki.wVk = vk;
    in[1].type = INPUT_KEYBOARD; in[1].ki.wVk = vk; in[1].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(2, in, sizeof(INPUT));
}

bool SmtcController::SeekToPositionMs(int64_t targetMs) {
    if (!m_session) return false;
    try {
        auto pb = m_session.GetPlaybackInfo();
        if (!pb.Controls().IsPlaybackPositionEnabled()) return false;
        auto tl = m_session.GetTimelineProperties();
        int64_t ticks = std::clamp<int64_t>(targetMs * 10000LL, 0, tl.EndTime().count());
        return m_session.TryChangePlaybackPositionAsync(ticks).get();
    } catch (...) {
        return false;
    }
}
