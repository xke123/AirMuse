#pragma once
#include "IWebAdapter.hpp"

namespace airmuse {

class SpotifyAdapter : public IWebAdapter {
public:
    WebPlatform GetPlatform() const override { return WebPlatform::Spotify; }
    const wchar_t* GetName() const override { return L"Spotify"; }
    const wchar_t* GetHomeUrl() const override { return L"https://open.spotify.com"; }
    const wchar_t* GetInjectScript() const override { return kSpotifyScript; }

    const wchar_t* GetPlayPauseJs() const override {
        return L"document.querySelector('[data-testid=\"control-button-playpause\"]')?.click();";
    }

    const wchar_t* GetNextJs() const override {
        return L"document.querySelector('[data-testid=\"control-button-skip-forward\"]')?.click();";
    }

    const wchar_t* GetPrevJs() const override {
        return L"document.querySelector('[data-testid=\"control-button-skip-back\"]')?.click();";
    }

    const wchar_t* GetSeekJsTemplate() const override {
        return L"";
    }

private:
    static inline constexpr const wchar_t* kSpotifyScript = LR"JS(
(function() {
    if (window.__airmuseSpotifyHooked) return;
    window.__airmuseSpotifyHooked = true;
    const style = document.createElement('style');
    style.textContent = `
        [data-testid="now-playing-bar"], [data-testid="left-sidebar"], [data-testid="global-nav-bar"],
        footer, [data-testid="cookie-notice"] { display: none !important; }
        .Root__main-view { grid-column: 1 / -1 !important; margin: 0 !important; width: 100% !important; zoom: 0.82; }
        ::-webkit-scrollbar { width: 4px; } ::-webkit-scrollbar-thumb { background: rgba(30,215,96,0.35); border-radius: 2px; }
    `;
    (document.head || document.documentElement).appendChild(style);

    setInterval(() => {
        try {
            const meta = navigator.mediaSession && navigator.mediaSession.metadata;
            if (!meta || !meta.title) return;
            const playBtn = document.querySelector('[data-testid="control-button-playpause"]');
            const isPlaying = playBtn ? (playBtn.getAttribute('aria-label') || '').toLowerCase().includes('pause') : false;
            const progEl = document.querySelector('[data-testid="playback-progressbar"] input[type="range"]');
            const posMs = progEl ? Number(progEl.value || 0) : 0;
            const durMs = progEl ? Number(progEl.max || 0) : 0;

            window.chrome.webview.postMessage(JSON.stringify({
                type: 'nowPlaying',
                source: 'Spotify Web',
                title: meta.title || '',
                artist: meta.artist || '',
                album: meta.album || '',
                isPlaying: isPlaying,
                positionMs: posMs,
                durationMs: durMs
            }));
        } catch (_) {}
    }, 350);
})();
)JS";
};

} // namespace airmuse
