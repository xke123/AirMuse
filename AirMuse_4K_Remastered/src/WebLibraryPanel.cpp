#include "WebLibraryPanel.hpp"
#include <unknwn.h>
#include <objidl.h>
#include <ole2.h>
#include <WebView2.h>
#include <wrl.h>
#include <shlobj.h>
#include <winrt/Windows.Data.Json.h>
#include <mutex>
#include <string>

using namespace Microsoft::WRL;
using namespace winrt::Windows::Data::Json;

struct WebLibraryPanel::Impl {
    ComPtr<ICoreWebView2Environment> env;
    ComPtr<ICoreWebView2Controller> controller;
    ComPtr<ICoreWebView2> webview;
    bool visible = false;
    mutable std::mutex mutex;
    NowPlayingInfo nowPlaying;
};

namespace {
std::wstring GetWebViewUserDataFolder() {
    PWSTR localAppData = nullptr;
    std::wstring dir;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &localAppData)) && localAppData) {
        dir = std::wstring(localAppData) + L"\\AirMuse\\WebView2";
        CoTaskMemFree(localAppData);
    }
    return dir;
}

const wchar_t* kInjectCompactAppleMusicJs = LR"JS(
(function() {
    const CSS_ID = 'airmuse-compact-css';
    const NAV_ID = 'airmuse-micronav';
    const PANE_ID = 'airmuse-twopane';

    let selectedSectionIdx = 0;
    let lastPath = '';
    let scanTimer = null;
    let pendingTabType = null; // 'home' | 'new' | 'radio' | null
    let pendingTimer = null;
    let lastRenderSig = '';
    let detailState = null;

    let mkHooked = false;
    let lastSentJson = '';
    let lastSentPosTick = 0;

    function pushNowPlaying(force) {
        try {
            const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk) return;
            const item = mk.nowPlayingItem;
            if (!item) return;

            const attrs = item.attributes || {};
            const title = item.title || attrs.name || '';
            const artist = item.artistName || attrs.artistName || '';
            const album = item.albumName || attrs.albumName || '';
            const isPlaying = !!mk.isPlaying;
            const durSec = Number(mk.currentPlaybackDuration || 0);
            const posSec = Number(mk.currentPlaybackTime || 0);
            const durMs = durSec > 0 ? Math.round(durSec * 1000) : Number(attrs.durationInMillis || 0);
            const posMs = posSec > 0 ? Math.round(posSec * 1000) : 0;

            if (!title) return;

            const now = Date.now();
            const sig = `${title}|${artist}|${isPlaying}|${durMs}`;
            if (!force && sig === lastSentJson && (now - lastSentPosTick) < 400) {
                return;
            }
            lastSentJson = sig;
            lastSentPosTick = now;

            if (window.chrome && window.chrome.webview) {
                window.chrome.webview.postMessage(JSON.stringify({
                    type: 'nowPlaying',
                    title,
                    artist,
                    album,
                    isPlaying,
                    positionMs: posMs,
                    durationMs: durMs
                }));
            }
        } catch (_) {}
    }

    function ensureMusicKitBridge() {
        const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
        if (!mk) return;
        if (!mkHooked) {
            mkHooked = true;
            try {
                mk.addEventListener('playbackStateDidChange', () => pushNowPlaying(true));
                mk.addEventListener('nowPlayingItemDidChange', () => pushNowPlaying(true));
                mk.addEventListener('playbackTimeDidChange', () => pushNowPlaying(false));
            } catch (_) {}
        }
        pushNowPlaying(false);
    }

    function injectCSS() {
        if (document.getElementById(CSS_ID)) return;
        const style = document.createElement('style');
        style.id = CSS_ID;
        style.textContent = `
            :root { color-scheme: dark !important; }
            html, body {
                background: #1c1d20 !important;
                color: #e8ecf4 !important;
                overflow-x: hidden !important;
                margin: 0 !important;
                padding: 0 !important;
            }

            amp-chrome-player,
            amp-lcd,
            .web-chrome,
            .chrome-player,
            .web-chrome-playback-controls,
            .playback-controls,
            .web-navigation__header,
            .web-navigation__sidebar,
            .web-navigation__native-upsell,
            .native-upsell,
            .upsell-banner,
            [data-testid="chrome-player"],
            [data-testid="player-bar"],
            [data-testid="sidebar"],
            [data-testid="upsell-banner"],
            [class*="chrome-player"],
            [class*="ChromePlayer"],
            [class*="playback-bar"],
            [class*="mini-player"],
            header.navigation,
            nav.navigation,
            footer,
            .web-footer,
            .footer {
                display: none !important;
                height: 0 !important;
                width: 0 !important;
                opacity: 0 !important;
                pointer-events: none !important;
                overflow: hidden !important;
            }

            main,
            #scrollable-page,
            .web-navigation__main,
            .dt-page-container {
                margin-left: 0 !important;
                margin-right: 0 !important;
                padding-top: 36px !important;
                padding-left: 6px !important;
                padding-right: 6px !important;
                padding-bottom: 12px !important;
                width: 100% !important;
                max-width: 100% !important;
                box-sizing: border-box !important;
                background: #1c1d20 !important;
                overflow-x: hidden !important;
            }

            #scrollable-page { zoom: 0.84; }

            h1, h2, .section-title, [data-testid="section-title"] {
                font-size: 14px !important;
                line-height: 1.25 !important;
                margin: 8px 0 5px 0 !important;
                letter-spacing: 0.2px !important;
            }

            .shelf-grid__body ul,
            .shelf-grid ul,
            [data-testid="shelf-grid"] ul,
            .grid {
                display: grid !important;
                grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
                gap: 6px !important;
                overflow: visible !important;
                padding: 0 !important;
                margin: 0 !important;
            }

            .shelf-grid__list-item,
            .grid-item {
                width: 100% !important;
                min-width: 0 !important;
                max-width: 100% !important;
                margin: 0 !important;
            }

            .shelf-grid__nav-arrow,
            .paddle { display: none !important; }

            .songs-list-row { min-height: 36px !important; padding: 3px 4px !important; }
            .songs-list-row__artwork-wrapper { width: 28px !important; height: 28px !important; min-width: 28px !important; }
            .songs-list-row__col--secondary,
            .songs-list-row__col--time { display: none !important; }

            /* 顶部 32px 极简微导航条（标签居中 + 右侧搜索按钮） */
            #${NAV_ID} {
                position: fixed !important;
                top: 0 !important;
                left: 0 !important;
                right: 0 !important;
                height: 32px !important;
                z-index: 2147483647 !important;
                display: flex !important;
                align-items: center !important;
                justify-content: center !important;
                padding: 0 28px 0 6px !important;
                background: rgba(24, 25, 29, 0.96) !important;
                backdrop-filter: blur(12px) !important;
                border-bottom: 1px solid rgba(255, 255, 255, 0.08) !important;
                box-sizing: border-box !important;
                font-family: "Microsoft YaHei UI", "Segoe UI", sans-serif !important;
                user-select: none !important;
            }
            #${NAV_ID} .am-tabs {
                display: flex !important;
                align-items: center !important;
                justify-content: center !important;
                gap: 3px !important;
                flex: 1 !important;
                min-width: 0 !important;
            }
            #${NAV_ID} button.am-tab {
                appearance: none !important;
                border: none !important;
                background: transparent !important;
                color: rgba(232, 236, 244, 0.65) !important;
                font-size: 11px !important;
                font-weight: 500 !important;
                padding: 4px 6px !important;
                border-radius: 4px !important;
                cursor: pointer !important;
                white-space: nowrap !important;
                transition: background 0.15s, color 0.15s !important;
            }
            #${NAV_ID} button.am-tab:hover {
                background: rgba(255, 255, 255, 0.08) !important;
                color: #ffffff !important;
            }
            #${NAV_ID} button.am-tab.active {
                background: rgba(250, 36, 60, 0.22) !important;
                color: #ff5c70 !important;
                font-weight: 600 !important;
            }
            #${NAV_ID} button.am-search-toggle {
                position: absolute !important;
                right: 5px !important;
                top: 50% !important;
                transform: translateY(-50%) !important;
            }
            #${NAV_ID} .am-search-box {
                display: none !important;
                flex: 1 !important;
                align-items: center !important;
                gap: 4px !important;
            }
            #${NAV_ID}.searching { padding: 0 6px !important; }
            #${NAV_ID}.searching .am-tabs { display: none !important; }
            #${NAV_ID}.searching .am-search-toggle { display: none !important; }
            #${NAV_ID}.searching .am-search-box { display: flex !important; }
            #${NAV_ID} input.am-search-input {
                flex: 1 !important;
                height: 22px !important;
                background: rgba(255, 255, 255, 0.08) !important;
                border: 1px solid rgba(255, 255, 255, 0.16) !important;
                border-radius: 4px !important;
                color: #ffffff !important;
                font-size: 11px !important;
                padding: 0 7px !important;
                outline: none !important;
            }
            #${NAV_ID} input.am-search-input:focus { border-color: rgba(250, 36, 60, 0.7) !important; }

            /* 左右两栏 Master-Detail 视图 */
            #${PANE_ID} {
                position: fixed !important;
                top: 32px !important;
                left: 0 !important;
                right: 0 !important;
                bottom: 0 !important;
                z-index: 2147483640 !important;
                display: flex !important;
                background: #1c1d20 !important;
                color: #e8ecf4 !important;
                font-family: "Microsoft YaHei UI", "Segoe UI", sans-serif !important;
                overflow: hidden !important;
            }
            #${PANE_ID} .am-left-rail {
                width: 82px !important;
                min-width: 82px !important;
                height: 100% !important;
                overflow-y: auto !important;
                overflow-x: hidden !important;
                background: rgba(20, 21, 24, 0.96) !important;
                border-right: 1px solid rgba(255, 255, 255, 0.08) !important;
                padding: 4px 0 !important;
                box-sizing: border-box !important;
            }
            #${PANE_ID} .am-sec-btn {
                display: block !important;
                width: 100% !important;
                text-align: left !important;
                border: none !important;
                border-left: 2px solid transparent !important;
                background: transparent !important;
                color: rgba(232, 236, 244, 0.62) !important;
                font-size: 11px !important;
                line-height: 1.3 !important;
                padding: 7px 6px !important;
                cursor: pointer !important;
                word-break: break-word !important;
                transition: background 0.12s, color 0.12s !important;
            }
            #${PANE_ID} .am-sec-btn:hover {
                background: rgba(255, 255, 255, 0.05) !important;
                color: #ffffff !important;
            }
            #${PANE_ID} .am-sec-btn.active {
                background: rgba(250, 36, 60, 0.16) !important;
                border-left-color: #fa243c !important;
                color: #ffffff !important;
                font-weight: 600 !important;
            }
            #${PANE_ID} .am-right-wrap {
                flex: 1 !important;
                height: 100% !important;
                display: flex !important;
                flex-direction: column !important;
                overflow: hidden !important;
                min-width: 0 !important;
            }
            #${PANE_ID} .am-detail-header {
                display: flex !important;
                align-items: center !important;
                gap: 6px !important;
                height: 28px !important;
                min-height: 28px !important;
                padding: 0 6px !important;
                background: rgba(25, 26, 30, 0.96) !important;
                border-bottom: 1px solid rgba(255, 255, 255, 0.08) !important;
                box-sizing: border-box !important;
            }
            #${PANE_ID} .am-detail-back {
                appearance: none !important;
                border: none !important;
                background: rgba(255, 255, 255, 0.08) !important;
                color: #eef2f8 !important;
                font-size: 11px !important;
                border-radius: 4px !important;
                padding: 2px 6px !important;
                cursor: pointer !important;
                flex-shrink: 0 !important;
            }
            #${PANE_ID} .am-detail-back:hover { background: rgba(250, 36, 60, 0.35) !important; }
            #${PANE_ID} .am-detail-title {
                font-size: 11px !important;
                font-weight: 600 !important;
                color: #ffffff !important;
                white-space: nowrap !important;
                overflow: hidden !important;
                text-overflow: ellipsis !important;
            }
            #${PANE_ID} .am-right-scroll {
                flex: 1 !important;
                overflow-y: auto !important;
                overflow-x: hidden !important;
                padding: 6px !important;
                box-sizing: border-box !important;
            }
            #${PANE_ID} .am-right-grid {
                display: grid !important;
                grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
                gap: 8px 6px !important;
            }
            #${PANE_ID} .am-card {
                display: flex !important;
                flex-direction: column !important;
                cursor: pointer !important;
                border-radius: 5px !important;
                padding: 3px !important;
                transition: background 0.12s !important;
                min-width: 0 !important;
            }
            #${PANE_ID} .am-card:hover { background: rgba(255, 255, 255, 0.07) !important; }
            #${PANE_ID} .am-card-img {
                width: 100% !important;
                aspect-ratio: 1 / 1 !important;
                object-fit: cover !important;
                border-radius: 4px !important;
                background: #27292e !important;
                margin-bottom: 4px !important;
                display: block !important;
            }
            #${PANE_ID} .am-card-title {
                font-size: 11px !important;
                font-weight: 600 !important;
                color: #eef2f8 !important;
                line-height: 1.25 !important;
                display: -webkit-box !important;
                -webkit-line-clamp: 2 !important;
                -webkit-box-orient: vertical !important;
                overflow: hidden !important;
                word-break: break-word !important;
            }
            #${PANE_ID} .am-card-sub {
                font-size: 10px !important;
                color: rgba(232, 236, 244, 0.56) !important;
                line-height: 1.2 !important;
                margin-top: 2px !important;
                white-space: nowrap !important;
                overflow: hidden !important;
                text-overflow: ellipsis !important;
            }
            #${PANE_ID} .am-track-list {
                display: flex !important;
                flex-direction: column !important;
                gap: 2px !important;
            }
            #${PANE_ID} .am-track-row {
                display: flex !important;
                align-items: center !important;
                gap: 7px !important;
                padding: 4px 5px !important;
                border-radius: 4px !important;
                cursor: pointer !important;
                transition: background 0.12s !important;
            }
            #${PANE_ID} .am-track-row:hover { background: rgba(255, 255, 255, 0.08) !important; }
            #${PANE_ID} .am-track-idx {
                width: 16px !important;
                font-size: 10px !important;
                color: rgba(232, 236, 244, 0.45) !important;
                text-align: center !important;
                flex-shrink: 0 !important;
            }
            #${PANE_ID} .am-track-img {
                width: 26px !important;
                height: 26px !important;
                border-radius: 3px !important;
                object-fit: cover !important;
                background: #27292e !important;
                flex-shrink: 0 !important;
            }
            #${PANE_ID} .am-track-info { flex: 1 !important; min-width: 0 !important; }
            #${PANE_ID} .am-track-name {
                font-size: 11px !important;
                font-weight: 500 !important;
                color: #eef2f8 !important;
                white-space: nowrap !important;
                overflow: hidden !important;
                text-overflow: ellipsis !important;
            }
            #${PANE_ID} .am-track-artist {
                font-size: 10px !important;
                color: rgba(232, 236, 244, 0.52) !important;
                white-space: nowrap !important;
                overflow: hidden !important;
                text-overflow: ellipsis !important;
            }
            #${PANE_ID} .am-loading {
                display: flex !important;
                flex-direction: column !important;
                align-items: center !important;
                justify-content: center !important;
                gap: 8px !important;
                height: 160px !important;
                color: rgba(232, 236, 244, 0.65) !important;
                font-size: 11px !important;
            }
            #${PANE_ID} .am-spinner {
                width: 18px !important;
                height: 18px !important;
                border: 2px solid rgba(255, 255, 255, 0.14) !important;
                border-top-color: #fa243c !important;
                border-radius: 50% !important;
                animation: airmuse-spin 0.75s linear infinite !important;
            }
            @keyframes airmuse-spin { to { transform: rotate(360deg); } }

            ::-webkit-scrollbar { width: 4px; height: 4px; }
            ::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.22); border-radius: 2px; }
            ::-webkit-scrollbar-track { background: transparent; }
        `;
        (document.head || document.documentElement).appendChild(style);
    }

    function hideBottomFloatingPlayers() {
        const vh = window.innerHeight || 278;
        const els = document.querySelectorAll('body > *, #app > *, [role="region"], amp-chrome-player, .chrome-player');
        for (const el of els) {
            if (!el || el.id === NAV_ID || el.id === PANE_ID) continue;
            try {
                const cs = getComputedStyle(el);
                if (cs.position === 'fixed' || cs.position === 'sticky') {
                    const r = el.getBoundingClientRect();
                    if (r.height > 24 && r.height < 120 && r.bottom >= vh - 36 && r.top > vh * 0.45) {
                        el.style.setProperty('display', 'none', 'important');
                    }
                }
            } catch (_) {}
        }
    }

    function getStorefront() {
        const m = location.pathname.match(/^\/([a-z]{2})(\/|$)/i);
        return m ? m[1].toLowerCase() : 'cn';
    }

    function getTwoPanePageType() {
        const p = location.pathname.toLowerCase();
        if (p === '/' || /^\/[a-z]{2}\/?$/.test(p) || p.includes('/home') || p.includes('/listen-now')) return 'home';
        if (p.includes('/new') || p.includes('/browse') || p.includes('/explore') || p.includes('/discover')) return 'new';
        if (p.includes('/radio')) return 'radio';

        const h1 = document.querySelector('h1');
        if (h1) {
            const t = (h1.textContent || '').trim();
            if (t === '主页' || t === 'Home' || t === 'Listen Now' || t === '现在就听') return 'home';
            if (t === '新发现' || t === 'New' || t === 'Browse' || t === '浏览') return 'new';
            if (t === '广播' || t === 'Radio') return 'radio';
        }
        return null;
    }

    function findSidebarLink(subPath) {
        const navSelectors = [
            `.web-navigation__sidebar a[href$="${subPath}"]`,
            `[data-testid="sidebar"] a[href$="${subPath}"]`,
            `nav a[href$="${subPath}"]`,
            `.web-navigation__sidebar a[href*="${subPath}"]`,
            `[data-testid="sidebar"] a[href*="${subPath}"]`,
            `nav a[href*="${subPath}"]`
        ];
        for (const sel of navSelectors) {
            const el = document.querySelector(sel);
            if (el) return el;
        }
        return null;
    }

    function navigateSpa(subPath) {
        const sf = getStorefront();
        const target = '/' + sf + subPath;
        detailState = null;
        lastRenderSig = '';

        if (subPath === '/home') pendingTabType = 'home';
        else if (subPath === '/new') pendingTabType = 'new';
        else if (subPath === '/radio') pendingTabType = 'radio';
        else pendingTabType = null;

        if (pendingTimer) clearTimeout(pendingTimer);
        if (pendingTabType) {
            pendingTimer = setTimeout(() => {
                pendingTabType = null;
                lastRenderSig = '';
                renderTwoPane();
            }, 4000);
        }

        renderTwoPane();

        const link = findSidebarLink(subPath);
        if (link) {
            link.click();
            return;
        }
        if (location.pathname !== target) {
            location.href = target;
        }
    }

    function updateActiveTab() {
        const nav = document.getElementById(NAV_ID);
        if (!nav) return;
        const p = location.pathname.toLowerCase();
        const activeType = pendingTabType || getTwoPanePageType();
        nav.querySelectorAll('button.am-tab[data-path]').forEach(btn => {
            const key = btn.getAttribute('data-match');
            let active = false;
            if (key === '/home') active = (activeType === 'home');
            else if (key === '/new') active = (activeType === 'new');
            else if (key === '/radio') active = (activeType === 'radio');
            else active = (!pendingTabType && p.includes(key));
            btn.classList.toggle('active', active);
        });
    }

    function pickImageUrl(rootEl) {
        const img = rootEl.querySelector('img');
        if (img) {
            if (img.currentSrc && !img.currentSrc.startsWith('data:')) return img.currentSrc;
            if (img.src && !img.src.startsWith('data:')) return img.src;
            const ds = img.getAttribute('data-src');
            if (ds) return ds;
        }
        const sources = rootEl.querySelectorAll('picture source[srcset]');
        for (const s of sources) {
            const ss = s.getAttribute('srcset') || '';
            const first = ss.split(',')[0].trim().split(' ')[0];
            if (first) return first;
        }
        return '';
    }

    function extractTextPair(itemEl) {
        const titleEl = itemEl.querySelector(
            '.songs-list-row__song-name, .product-lockup__title, .editorial-lockup__title, [data-testid="product-lockup-title"], .line-clamp-wrapper, a[data-testid="click-action"]'
        );
        const subEl = itemEl.querySelector(
            '.songs-list-row__by-line, .product-lockup__subtitle, .editorial-lockup__subtitle, [data-testid="product-lockup-subtitle"], .secondary-label'
        );

        let title = titleEl ? titleEl.textContent.trim() : '';
        let sub = subEl ? subEl.textContent.trim() : '';

        if (!title) {
            const lines = (itemEl.innerText || '')
                .split('\n')
                .map(s => s.trim())
                .filter(s => s.length > 0 && s !== '···' && s !== 'E');
            if (lines.length >= 2 && (lines[0].includes('已更新') || lines[0].includes('经典') || lines[0].includes('专题'))) {
                title = lines[1] || lines[0];
                sub = lines[2] || lines[0];
            } else {
                title = lines[0] || '';
                sub = lines[1] || '';
            }
        }
        return { title, sub };
    }

    function extractSectionTitle(sec, secIdx, pageType) {
        if (pageType === 'new' && secIdx === 0) return '精选推荐';
        try {
            const candidates = sec.querySelectorAll(
                'h2, h3, .section-title, [data-testid="section-title"], .shelf-grid__header a, .shelf-grid__header button'
            );
            for (const h of candidates) {
                if (h.closest('ul, li, .shelf-grid__list-item, .songs-list-row')) continue;
                const t = (h.textContent || '').replace(/[>›\n]/g, ' ').trim();
                if (t) return t;
            }
        } catch (_) {}
        return secIdx === 0 ? '精选推荐' : ('推荐模块 ' + (secIdx + 1));
    }

    function extractSections(pageType) {
        const page = document.querySelector('#scrollable-page') || document.querySelector('main') || document.body;
        if (!page) return [];

        const candidates = Array.from(
            page.querySelectorAll('section, .section, [data-testid="section-container"], .shelf-grid, [class*="shelf-grid"]')
        );
        const seenLists = new Set();
        const sections = [];

        for (const sec of candidates) {
            let items = Array.from(sec.querySelectorAll('.shelf-grid__list-item, ul > li, .songs-list-row'));
            items = items.filter(el => {
                const parentLi = el.parentElement ? el.parentElement.closest('.shelf-grid__list-item, ul > li, .songs-list-row') : null;
                return !parentLi || !sec.contains(parentLi);
            });
            if (items.length === 0) continue;

            const sig = items[0];
            if (seenLists.has(sig)) continue;
            seenLists.add(sig);

            const secName = extractSectionTitle(sec, sections.length, pageType);
            const parsedItems = [];
            for (const itemEl of items) {
                const { title, sub } = extractTextPair(itemEl);
                const imgUrl = pickImageUrl(itemEl);
                const linkEl = itemEl.querySelector('a[href]');
                const href = linkEl ? (linkEl.getAttribute('href') || '') : '';
                if (!title && !imgUrl) continue;
                parsedItems.push({
                    title: title || '未命名',
                    sub: sub || '',
                    imgUrl,
                    href,
                    triggerEl: itemEl
                });
            }

            if (parsedItems.length > 0) {
                sections.push({
                    name: secName,
                    rawEl: sec,
                    items: parsedItems
                });
            }
        }
        return sections;
    }

    function parseResourceFromHref(href) {
        if (!href) return null;
        let m = href.match(/\/playlist\/[^/]+\/(pl\.[a-zA-Z0-9._-]+)/);
        if (m) return { kind: 'playlist', apiKind: 'playlists', id: m[1] };
        m = href.match(/\/album\/[^/]+\/(\d+)/);
        if (m) return { kind: 'album', apiKind: 'albums', id: m[1] };
        return null;
    }

    function formatArt(urlTemplate, size = 80) {
        if (!urlTemplate) return '';
        return urlTemplate.replace('{w}', String(size)).replace('{h}', String(size));
    }

    function extractTracksFromSerializedHtml(htmlText) {
        try {
            const doc = new DOMParser().parseFromString(htmlText, 'text/html');
            const scriptEl = doc.querySelector('script#serialized-server-data');
            if (!scriptEl) return [];
            const json = JSON.parse(scriptEl.textContent || '{}');
            const tracks = [];
            function walk(node) {
                if (!node || typeof node !== 'object') return;
                if (Array.isArray(node)) {
                    for (const item of node) walk(item);
                    return;
                }
                if (node.type === 'songs' && node.attributes && node.attributes.name) {
                    tracks.push({
                        id: node.id,
                        name: node.attributes.name,
                        artist: node.attributes.artistName || '',
                        art: formatArt(node.attributes.artwork && node.attributes.artwork.url)
                    });
                    return;
                }
                for (const k of Object.keys(node)) walk(node[k]);
            }
            walk(json);
            return tracks;
        } catch (_) {
            return [];
        }
    }

    async function playCollectionTrack(kind, collectionId, trackIdx, trackId) {
        const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
        if (mk) {
            try {
                if (kind && collectionId) {
                    await mk.setQueue({ [kind]: collectionId, startPosition: trackIdx });
                    if (typeof mk.changeToMediaAtIndex === 'function') {
                        try { await mk.changeToMediaAtIndex(trackIdx); } catch (_) {}
                    }
                    await mk.play();
                    pushNowPlaying(true);
                    return true;
                }
                if (trackId) {
                    await mk.setQueue({ song: String(trackId) });
                    await mk.play();
                    pushNowPlaying(true);
                    return true;
                }
            } catch (_) {}
        }
        return false;
    }

    async function openItemDetail(item) {
        const resInfo = parseResourceFromHref(item.href);
        if (!resInfo) {
            // 广播电台、单曲等直接触发原元素播放
            const target = item.triggerEl.querySelector('button[data-testid="play-button"], button, a') || item.triggerEl;
            try { target.click(); } catch (_) {}
            setTimeout(() => pushNowPlaying(true), 500);
            return;
        }

        detailState = {
            title: item.title,
            kind: resInfo.kind,
            id: resInfo.id,
            href: item.href,
            tracks: [],
            loading: true,
            error: ''
        };
        renderTwoPane();

        const sf = getStorefront();
        const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
        let tracks = [];

        if (mk && mk.api && typeof mk.api.music === 'function') {
            try {
                const resp = await mk.api.music(`/v1/catalog/${sf}/${resInfo.apiKind}/${resInfo.id}`, { include: 'tracks' });
                const col = resp && resp.data && resp.data.data && resp.data.data[0];
                const rawTracks = col && col.relationships && col.relationships.tracks && col.relationships.tracks.data;
                if (Array.isArray(rawTracks)) {
                    tracks = rawTracks.map(t => ({
                        id: t.id,
                        name: (t.attributes && t.attributes.name) || '未知曲目',
                        artist: (t.attributes && t.attributes.artistName) || '',
                        art: formatArt(t.attributes && t.attributes.artwork && t.attributes.artwork.url)
                    }));
                }
            } catch (_) {}
        }

        if (tracks.length === 0 && item.href) {
            try {
                const resp = await fetch(item.href, { credentials: 'include' });
                if (resp.ok) {
                    const html = await resp.text();
                    tracks = extractTracksFromSerializedHtml(html);
                }
            } catch (_) {}
        }

        if (!detailState || detailState.id !== resInfo.id) return;
        detailState.loading = false;
        detailState.tracks = tracks;
        if (tracks.length === 0) {
            detailState.error = '暂无可展示曲目，点击此处用原页面打开';
        }
        renderTwoPane();
    }

    function renderTwoPane() {
        const pageType = getTwoPanePageType();
        const activeType = pendingTabType || pageType;
        let pane = document.getElementById(PANE_ID);

        if (!activeType) {
            if (pane) pane.remove();
            return;
        }

        if (!pane && document.body) {
            pane = document.createElement('div');
            pane.id = PANE_ID;
            pane.innerHTML = `<div class="am-left-rail"></div><div class="am-right-wrap"></div>`;
            document.body.appendChild(pane);
        }
        if (!pane) return;

        // 只有在当前路由与目标类型一致（或非切换等待态）时才解析页面模块
        const readyToExtract = pageType && (!pendingTabType || pendingTabType === pageType);
        const sections = readyToExtract ? extractSections(pageType) : [];
        if (sections.length > 0 && pendingTabType === pageType) {
            pendingTabType = null;
        }

        const rail = pane.querySelector('.am-left-rail');
        const rightWrap = pane.querySelector('.am-right-wrap');

        if (sections.length === 0) {
            const sig = `loading:${activeType}`;
            if (lastRenderSig === sig) return;
            lastRenderSig = sig;
            const labelMap = { home: '主页', new: '新发现', radio: '广播' };
            const label = labelMap[activeType] || '内容';
            rail.innerHTML = '';
            rightWrap.innerHTML = `<div class="am-loading"><div class="am-spinner"></div><div>正在加载${label}内容...</div></div>`;
            return;
        }

        const dataSig = `${pageType}|${selectedSectionIdx}|${sections.map(x => x.name + ":" + x.items.length).join(",")}|${detailState ? detailState.id + ":" + detailState.loading + ":" + detailState.tracks.length : "grid"}`;
        if (lastRenderSig === dataSig) return;
        lastRenderSig = dataSig;

        if (selectedSectionIdx >= sections.length) selectedSectionIdx = 0;

        rail.innerHTML = '';
        sections.forEach((sec, idx) => {
            const btn = document.createElement('button');
            btn.className = 'am-sec-btn' + (idx === selectedSectionIdx ? ' active' : '');
            btn.textContent = sec.name;
            btn.onclick = () => {
                selectedSectionIdx = idx;
                detailState = null;
                lastRenderSig = '';
                try { sec.rawEl.scrollIntoView({ block: 'center' }); } catch (_) {}
                renderTwoPane();
                setTimeout(renderTwoPane, 180);
            };
            rail.appendChild(btn);
        });

        if (detailState) {
            rightWrap.innerHTML = '';
            const hdr = document.createElement('div');
            hdr.className = 'am-detail-header';

            const backBtn = document.createElement('button');
            backBtn.className = 'am-detail-back';
            backBtn.textContent = '← 返回';
            backBtn.onclick = () => {
                detailState = null;
                lastRenderSig = '';
                renderTwoPane();
            };

            const titleSpan = document.createElement('div');
            titleSpan.className = 'am-detail-title';
            titleSpan.textContent = detailState.title;

            hdr.appendChild(backBtn);
            hdr.appendChild(titleSpan);
            rightWrap.appendChild(hdr);

            const scroller = document.createElement('div');
            scroller.className = 'am-right-scroll';

            if (detailState.loading) {
                scroller.innerHTML = `<div class="am-loading"><div class="am-spinner"></div><div>正在加载曲目列表...</div></div>`;
            } else if (detailState.error) {
                const errDiv = document.createElement('div');
                errDiv.className = 'am-loading';
                errDiv.style.cursor = 'pointer';
                errDiv.textContent = detailState.error;
                errDiv.onclick = () => {
                    const href = detailState.href;
                    detailState = null;
                    pendingTabType = null;
                    if (href) location.href = href;
                };
                scroller.appendChild(errDiv);
            } else {
                const list = document.createElement('div');
                list.className = 'am-track-list';
                detailState.tracks.forEach((tr, idx) => {
                    const row = document.createElement('div');
                    row.className = 'am-track-row';

                    const idxEl = document.createElement('div');
                    idxEl.className = 'am-track-idx';
                    idxEl.textContent = String(idx + 1);

                    const img = document.createElement('img');
                    img.className = 'am-track-img';
                    if (tr.art) img.src = tr.art;
                    img.loading = 'lazy';

                    const info = document.createElement('div');
                    info.className = 'am-track-info';
                    const nm = document.createElement('div');
                    nm.className = 'am-track-name';
                    nm.textContent = tr.name;
                    const ar = document.createElement('div');
                    ar.className = 'am-track-artist';
                    ar.textContent = tr.artist;
                    info.appendChild(nm);
                    if (tr.artist) info.appendChild(ar);

                    row.appendChild(idxEl);
                    row.appendChild(img);
                    row.appendChild(info);

                    row.onclick = async () => {
                        const ok = await playCollectionTrack(detailState.kind, detailState.id, idx, tr.id);
                        if (!ok && detailState.href) {
                            location.href = detailState.href;
                        }
                    };
                    list.appendChild(row);
                });
                scroller.appendChild(list);
            }
            rightWrap.appendChild(scroller);
            return;
        }

        rightWrap.innerHTML = `<div class="am-right-scroll"><div class="am-right-grid"></div></div>`;
        const grid = rightWrap.querySelector('.am-right-grid');
        const activeSec = sections[selectedSectionIdx];

        activeSec.items.forEach(item => {
            const card = document.createElement('div');
            card.className = 'am-card';

            const img = document.createElement('img');
            img.className = 'am-card-img';
            if (item.imgUrl) img.src = item.imgUrl;
            img.loading = 'lazy';

            const title = document.createElement('div');
            title.className = 'am-card-title';
            title.textContent = item.title;

            const sub = document.createElement('div');
            sub.className = 'am-card-sub';
            sub.textContent = item.sub;

            card.appendChild(img);
            card.appendChild(title);
            if (item.sub) card.appendChild(sub);

            card.onclick = () => openItemDetail(item);
            grid.appendChild(card);
        });
    }

    function injectMicroNav() {
        if (document.getElementById(NAV_ID) || !document.body) return;
        const nav = document.createElement('div');
        nav.id = NAV_ID;

        const tabs = [
            { label: '主页', path: '/home', match: '/home' },
            { label: '新发现', path: '/new', match: '/new' },
            { label: '广播', path: '/radio', match: '/radio' },
            { label: '资料库', path: '/library/recently-added', match: '/library/recently-added' },
            { label: '歌单', path: '/library/playlists', match: '/library/playlists' }
        ];

        const tabsWrap = document.createElement('div');
        tabsWrap.className = 'am-tabs';
        tabs.forEach(t => {
            const btn = document.createElement('button');
            btn.className = 'am-tab';
            btn.textContent = t.label;
            btn.setAttribute('data-path', t.path);
            btn.setAttribute('data-match', t.match);
            btn.onclick = () => {
                selectedSectionIdx = 0;
                navigateSpa(t.path);
                setTimeout(() => { updateActiveTab(); renderTwoPane(); }, 120);
            };
            tabsWrap.appendChild(btn);
        });

        const searchWrap = document.createElement('div');
        searchWrap.className = 'am-search-box';
        const input = document.createElement('input');
        input.className = 'am-search-input';
        input.type = 'text';
        input.placeholder = '搜索歌曲 / 歌手 / 专辑...';
        input.onkeydown = (e) => {
            if (e.key === 'Enter' && input.value.trim()) {
                pendingTabType = null;
                detailState = null;
                const sf = getStorefront();
                location.href = `/${sf}/search?term=${encodeURIComponent(input.value.trim())}`;
                nav.classList.remove('searching');
            } else if (e.key === 'Escape') {
                nav.classList.remove('searching');
            }
        };
        const closeBtn = document.createElement('button');
        closeBtn.className = 'am-tab';
        closeBtn.textContent = '✕';
        closeBtn.onclick = () => nav.classList.remove('searching');
        searchWrap.appendChild(input);
        searchWrap.appendChild(closeBtn);

        const searchBtn = document.createElement('button');
        searchBtn.className = 'am-tab am-search-toggle';
        searchBtn.textContent = '🔍';
        searchBtn.title = '搜索';
        searchBtn.onclick = () => {
            nav.classList.toggle('searching');
            if (nav.classList.contains('searching')) {
                setTimeout(() => input.focus(), 30);
            }
        };

        nav.appendChild(tabsWrap);
        nav.appendChild(searchWrap);
        nav.appendChild(searchBtn);
        document.body.appendChild(nav);
        updateActiveTab();
    }

    function scheduleSync() {
        if (scanTimer) clearTimeout(scanTimer);
        scanTimer = setTimeout(() => {
            if (location.pathname !== lastPath) {
                lastPath = location.pathname;
                selectedSectionIdx = 0;
                detailState = null;
                const pt = getTwoPanePageType();
                if (pt === pendingTabType) pendingTabType = null;
            }
            injectCSS();
            injectMicroNav();
            hideBottomFloatingPlayers();
            updateActiveTab();
            renderTwoPane();
            ensureMusicKitBridge();
        }, 120);
    }

    scheduleSync();
    if (!window.__airmuseObserver) {
        const origPush = history.pushState;
        history.pushState = function() {
            const r = origPush.apply(this, arguments);
            scheduleSync();
            return r;
        };
        const origReplace = history.replaceState;
        history.replaceState = function() {
            const r = origReplace.apply(this, arguments);
            scheduleSync();
            return r;
        };
        window.__airmuseObserver = new MutationObserver((mutations) => {
            const relevant = mutations.some(m => {
                const t = m.target;
                return t && !(t.closest && t.closest('#airmuse-twopane, #airmuse-micronav'));
            });
            if (relevant) scheduleSync();
        });
        window.__airmuseObserver.observe(document.documentElement, { childList: true, subtree: true });
        window.addEventListener('popstate', () => scheduleSync());
        setInterval(() => {
            ensureMusicKitBridge();
            const pt = getTwoPanePageType();
            if (location.pathname !== lastPath || (pt && !document.getElementById(PANE_ID)) || !document.getElementById(NAV_ID)) {
                scheduleSync();
            }
        }, 400);
    }
})();
)JS";
} // namespace

bool WebLibraryPanel::Initialize(HWND hostHwnd, HWND notifyHwnd, UINT notifyMsg) {
    m_hostHwnd = hostHwnd;
    m_notifyHwnd = notifyHwnd;
    m_notifyMsg = notifyMsg;
    if (!m_impl) m_impl = new Impl();

    std::wstring userData = GetWebViewUserDataFolder();
    HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
        nullptr,
        userData.empty() ? nullptr : userData.c_str(),
        nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [this](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                if (FAILED(result) || !env || !m_impl) return result;
                m_impl->env = env;

                env->CreateCoreWebView2Controller(
                    m_hostHwnd,
                    Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                        [this](HRESULT ctrlRes, ICoreWebView2Controller* controller) -> HRESULT {
                            if (FAILED(ctrlRes) || !controller || !m_impl) return ctrlRes;
                            m_impl->controller = controller;
                            controller->get_CoreWebView2(&m_impl->webview);

                            ComPtr<ICoreWebView2Controller2> ctrl2;
                            if (SUCCEEDED(controller->QueryInterface(IID_PPV_ARGS(&ctrl2))) && ctrl2) {
                                COREWEBVIEW2_COLOR bg{ 255, 28, 29, 32 };
                                ctrl2->put_DefaultBackgroundColor(bg);
                            }

                            if (m_impl->webview) {
                                ComPtr<ICoreWebView2Settings> settings;
                                if (SUCCEEDED(m_impl->webview->get_Settings(&settings)) && settings) {
                                    settings->put_AreDefaultContextMenusEnabled(TRUE);
                                    settings->put_AreDevToolsEnabled(TRUE);
                                    settings->put_IsStatusBarEnabled(FALSE);
                                }
                                m_impl->webview->AddScriptToExecuteOnDocumentCreated(
                                    kInjectCompactAppleMusicJs, nullptr);

                                m_impl->webview->add_WebMessageReceived(
                                    Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                                        [this](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
                                            if (!args || !m_impl) return S_OK;
                                            LPWSTR raw = nullptr;
                                            if (SUCCEEDED(args->TryGetWebMessageAsString(&raw)) && raw) {
                                                JsonObject obj;
                                                if (JsonObject::TryParse(raw, obj)) {
                                                    auto type = obj.GetNamedString(L"type", L"");
                                                    if (type == L"nowPlaying") {
                                                        std::lock_guard lock(m_impl->mutex);
                                                        m_impl->nowPlaying.title = obj.GetNamedString(L"title", L"").c_str();
                                                        m_impl->nowPlaying.artist = obj.GetNamedString(L"artist", L"").c_str();
                                                        m_impl->nowPlaying.album = obj.GetNamedString(L"album", L"").c_str();
                                                        m_impl->nowPlaying.isPlaying = obj.GetNamedBoolean(L"isPlaying", false);
                                                        m_impl->nowPlaying.positionMs = static_cast<int64_t>(obj.GetNamedNumber(L"positionMs", 0.0));
                                                        m_impl->nowPlaying.durationMs = static_cast<int64_t>(obj.GetNamedNumber(L"durationMs", 0.0));
                                                        m_impl->nowPlaying.isAppleMusic = true;
                                                        m_impl->nowPlaying.sourceAppId = L"AirMuse.WebView2";
                                                        if (m_notifyHwnd && IsWindow(m_notifyHwnd) && m_notifyMsg) {
                                                            PostMessageW(m_notifyHwnd, m_notifyMsg, 0, 0);
                                                        }
                                                    }
                                                }
                                                CoTaskMemFree(raw);
                                            }
                                            return S_OK;
                                        }).Get(),
                                    nullptr
                                );

                                m_impl->webview->add_NavigationCompleted(
                                    Callback<ICoreWebView2NavigationCompletedEventHandler>(
                                        [this](ICoreWebView2* sender, ICoreWebView2NavigationCompletedEventArgs*) -> HRESULT {
                                            if (sender) sender->ExecuteScript(kInjectCompactAppleMusicJs, nullptr);
                                            return S_OK;
                                        }).Get(),
                                    nullptr
                                );
                                m_impl->webview->Navigate(L"https://music.apple.com");
                            }

                            RECT rc{};
                            GetClientRect(m_hostHwnd, &rc);
                            m_impl->controller->put_Bounds(rc);
                            m_impl->controller->put_IsVisible(m_impl->visible ? TRUE : FALSE);
                            return S_OK;
                        }).Get()
                );
                return S_OK;
            }).Get()
    );
    return SUCCEEDED(hr);
}

NowPlayingInfo WebLibraryPanel::GetNowPlayingSnapshot() const {
    if (!m_impl) return NowPlayingInfo{};
    std::lock_guard lock(m_impl->mutex);
    return m_impl->nowPlaying;
}

void WebLibraryPanel::PlayPause() {
    if (!m_impl || !m_impl->webview) return;
    m_impl->webview->ExecuteScript(
        L"(function(){const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(!mk)return;if(mk.isPlaying)mk.pause();else mk.play();})();",
        nullptr);
}

void WebLibraryPanel::Stop() {
    if (!m_impl || !m_impl->webview) return;
    m_impl->webview->ExecuteScript(
        L"(function(){const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(mk)mk.stop();})();",
        nullptr);
}

void WebLibraryPanel::Next() {
    if (!m_impl || !m_impl->webview) return;
    m_impl->webview->ExecuteScript(
        L"(function(){const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(mk)mk.skipToNextItem();})();",
        nullptr);
}

void WebLibraryPanel::Previous() {
    if (!m_impl || !m_impl->webview) return;
    m_impl->webview->ExecuteScript(
        L"(function(){const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(mk)mk.skipToPreviousItem();})();",
        nullptr);
}

void WebLibraryPanel::SeekToPositionMs(int64_t targetMs) {
    if (!m_impl || !m_impl->webview) return;
    double sec = static_cast<double>(targetMs) / 1000.0;
    wchar_t js[256];
    swprintf_s(js, L"(function(){const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(mk)mk.seekToTime(%.3f);})();", sec);
    m_impl->webview->ExecuteScript(js, nullptr);
}

void WebLibraryPanel::Resize(int widthPx, int heightPx) {
    if (!m_impl || !m_impl->controller) return;
    RECT rc{ 0, 0, widthPx, heightPx };
    m_impl->controller->put_Bounds(rc);
}

void WebLibraryPanel::SetVisible(bool visible) {
    if (!m_impl) return;
    m_impl->visible = visible;
    if (m_impl->controller) {
        m_impl->controller->put_IsVisible(visible ? TRUE : FALSE);
    }
}

void WebLibraryPanel::Shutdown() {
    if (!m_impl) return;
    if (m_impl->controller) {
        m_impl->controller->Close();
        m_impl->controller.Reset();
    }
    m_impl->webview.Reset();
    m_impl->env.Reset();
    delete m_impl;
    m_impl = nullptr;
}
