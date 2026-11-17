#pragma once
#include "IWebAdapter.hpp"

namespace airmuse {

class QQMusicAdapter : public IWebAdapter {
public:
    WebPlatform GetPlatform() const override { return WebPlatform::QQMusic; }
    const wchar_t* GetName() const override { return L"QQ 音乐"; }
    const wchar_t* GetHomeUrl() const override { return L"https://y.qq.com"; }
    const wchar_t* GetInjectScript() const override { return kQQMusicScript; }

    const wchar_t* GetPlayPauseJs() const override {
        return L"(function(){const a=document.querySelector('audio');if(a){a.paused?a.play():a.pause();}})();";
    }

    const wchar_t* GetNextJs() const override {
        return L"document.querySelector('.btn_big_next, [title*=\"下一首\"]')?.click();";
    }

    const wchar_t* GetPrevJs() const override {
        return L"document.querySelector('.btn_big_prev, [title*=\"上一首\"]')?.click();";
    }

    const wchar_t* GetSeekJsTemplate() const override {
        return L"(function(){const a=document.querySelector('audio');if(a)a.currentTime=%.3f;})();";
    }

private:
    static inline constexpr const wchar_t* kQQMusicScript = LR"JS(
(function() {
    if (window.__airmuseQQHooked) return;
    window.__airmuseQQHooked = true;
    const style = document.createElement('style');
    style.textContent = `
        .mod_header, .mod_footer, .popup_download, .bottom_player { display: none !important; }
        body { min-width: 0 !important; overflow-x: hidden !important; background: #1c1d20 !important; zoom: 0.80; }
        ::-webkit-scrollbar { width: 4px; } ::-webkit-scrollbar-thumb { background: rgba(49,194,124,0.35); border-radius: 2px; }
    `;
    (document.head || document.documentElement).appendChild(style);

    setInterval(() => {
        try {
            const audio = document.querySelector('audio');
            const meta = navigator.mediaSession && navigator.mediaSession.metadata;
            const titleEl = document.querySelector('.song_name__link, .player_music__info a');
            const artistEl = document.querySelector('.singer_name__link, .player_music__info .singer_name');
            const title = (meta && meta.title) || (titleEl && titleEl.textContent.trim()) || '';
            const artist = (meta && meta.artist) || (artistEl && artistEl.textContent.trim()) || '';
            if (!title) return;

            window.chrome.webview.postMessage(JSON.stringify({
                type: 'nowPlaying',
                source: 'QQ 音乐 Web',
                title: title,
                artist: artist,
                album: (meta && meta.album) || '',
                isPlaying: audio ? !audio.paused : false,
                positionMs: audio ? Math.round((audio.currentTime || 0) * 1000) : 0,
                durationMs: (audio && isFinite(audio.duration)) ? Math.round(audio.duration * 1000) : 0
            }));
        } catch (_) {}
    }, 350);
})();
)JS";
};

} // namespace airmuse
