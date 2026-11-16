#pragma once
#include "../core/Models.hpp"

namespace airmuse {

struct WebAdapterSpec {
    WebPlatform platform;
    const wchar_t* name;
    const wchar_t* homeUrl;
    const wchar_t* injectScript;
    const wchar_t* playPauseJs;
    const wchar_t* nextJs;
    const wchar_t* prevJs;
    const wchar_t* seekJsTemplate;
};

inline constexpr const wchar_t* kAppleMusicScript = LR"JS(
(function() {
    const CSS_ID = 'airmuse-compact-css';
    const NAV_ID = 'airmuse-micronav';
    const PANE_ID = 'airmuse-twopane';
    let selectedSectionIdx = 0;
    let lastPath = '';
    let pendingTabType = null;
    let pendingTimer = null;
    let lastRenderSig = '';
    let detailState = null;
    let playingCtx = null;   // { path, sectionName, itemTitle, kind, apiKind, id, isLib, href }
    let returnCtx = null;    // 跳转前的浏览位置快照：{ path, sectionIdx, detailSnapshot }
    let pendingTarget = null;// 待定位目标：{ sectionName, itemTitle, openDetailObj }

    window.__airmuseJumpToPlaying = function() {
        if (!playingCtx) return;
        // 1. 记录点击跳转前正在浏览的页面状态，供“← 返回”按钮原路返回
        returnCtx = {
            path: location.pathname,
            sectionIdx: selectedSectionIdx,
            detailSnapshot: detailState ? JSON.parse(JSON.stringify(detailState)) : null
        };

        // 2. 如果是歌单/播放列表/专辑，直接在右半边栏展开它的曲目列表
        if (playingCtx.kind && playingCtx.id) {
            openItemDetail({
                title: playingCtx.itemTitle,
                href: playingCtx.href,
                _forceRes: { kind: playingCtx.kind, apiKind: playingCtx.apiKind, id: playingCtx.id, isLib: playingCtx.isLib }
            }, true);
            return;
        }

        // 3. 如果是电台或主页推荐卡片（如“小可的电台”），跳回对应页面 -> 选中对应左侧分类 -> 滚动高亮该卡片
        pendingTarget = { sectionName: playingCtx.sectionName, itemTitle: playingCtx.itemTitle };
        const targetSub = playingCtx.path.replace(/^\/[a-z]{2}/i, '') || '/home';
        if (location.pathname !== playingCtx.path) {
            navigateSpa(targetSub, true);
        } else {
            detailState = null;
            lastRenderSig = '';
            renderTwoPane();
        }
    };

    let lastSentUser = '__init__';
    function detectAndPushUser() {
        try {
            let uname = '';
            // 1. 尝试从资料库歌单副标题（如“小可的 Apple Music”）或账号按钮读取用户名
            const subEls = document.querySelectorAll('.product-lockup__subtitle, [data-testid="product-lockup-subtitle"], [aria-label*="账号"], [aria-label*="Account"]');
            for (const el of subEls) {
                const txt = (el.textContent || el.getAttribute('aria-label') || '').trim();
                const m = txt.match(/^(.+?)的\s*Apple\s*Music$/i);
                if (m && m[1] && m[1] !== '你') { uname = m[1].trim(); break; }
            }
            const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!uname && mk && mk.isAuthorized) {
                uname = '已登录用户';
            }
            if (uname !== lastSentUser && window.chrome && window.chrome.webview) {
                lastSentUser = uname;
                window.chrome.webview.postMessage(JSON.stringify({ type: 'userStatus', userName: uname }));
            }
        } catch (_) {}
    }

    function pushNowPlaying() {
        detectAndPushUser();
        try {
            const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            const item = mk ? mk.nowPlayingItem : null;
            const meta = navigator.mediaSession ? navigator.mediaSession.metadata : null;
            const audio = document.querySelector('audio, video');

            let title = '', artist = '', album = '', isPlaying = false, posMs = 0, durMs = 0;

            if (item) {
                const attrs = item.attributes || {};
                title = item.title || attrs.name || '';
                artist = item.artistName || attrs.artistName || '';
                album = item.albumName || attrs.albumName || '';
                isPlaying = !!mk.isPlaying;
                durMs = Math.round((Number(mk.currentPlaybackDuration || 0)) * 1000) || Number(attrs.durationInMillis || 0);
                posMs = Math.round((Number(mk.currentPlaybackTime || 0)) * 1000);
            } else if (meta && meta.title) {
                title = meta.title || '';
                artist = meta.artist || '';
                album = meta.album || '';
                isPlaying = audio ? !audio.paused : (navigator.mediaSession.playbackState === 'playing');
                if (audio && isFinite(audio.duration)) {
                    durMs = Math.round(audio.duration * 1000);
                    posMs = Math.round((audio.currentTime || 0) * 1000);
                }
            }

            if (!title) return;

            if (window.chrome && window.chrome.webview) {
                window.chrome.webview.postMessage(JSON.stringify({
                    type: 'nowPlaying',
                    source: 'Apple Music',
                    title: title,
                    artist: artist,
                    album: album,
                    contextTitle: playingCtx ? playingCtx.itemTitle : '',
                    contextType: playingCtx ? (playingCtx.kind || '电台') : '',
                    isPlaying: isPlaying,
                    positionMs: posMs,
                    durationMs: durMs
                }));
            }
        } catch (_) {}
    }

    function injectCSS() {
        if (document.getElementById(CSS_ID)) return;
        const style = document.createElement('style');
        style.id = CSS_ID;
        style.textContent = `
            :root { color-scheme: dark !important; }
            html, body { background: #1c1d20 !important; color: #e8ecf4 !important; overflow-x: hidden !important; margin: 0 !important; padding: 0 !important; }
            amp-chrome-player, amp-lcd, .web-chrome, .chrome-player, .web-chrome-playback-controls,
            .playback-controls, .web-navigation__header, .web-navigation__sidebar, .web-navigation__native-upsell,
            .native-upsell, .upsell-banner, [data-testid="chrome-player"], [data-testid="player-bar"],
            [data-testid="sidebar"], [data-testid="upsell-banner"], [class*="chrome-player"],
            [class*="ChromePlayer"], [class*="playback-bar"], [class*="mini-player"],
            header.navigation, nav.navigation, footer, .web-footer, .footer {
                display: none !important; height: 0 !important; width: 0 !important; opacity: 0 !important; pointer-events: none !important;
            }
            main, #scrollable-page, .web-navigation__main, .dt-page-container {
                margin: 0 !important; padding: 34px 6px 12px 6px !important; width: 100% !important; max-width: 100% !important;
                box-sizing: border-box !important; background: #1c1d20 !important; overflow-x: hidden !important;
            }
            #scrollable-page { zoom: 0.84; }
            .shelf-grid__body ul, .shelf-grid ul, [data-testid="shelf-grid"] ul, .grid {
                display: grid !important; grid-template-columns: repeat(2, minmax(0, 1fr)) !important; gap: 6px !important;
            }
            .shelf-grid__nav-arrow, .paddle { display: none !important; }
            #${NAV_ID} {
                position: fixed !important; top: 0 !important; left: 0 !important; right: 0 !important; height: 30px !important;
                z-index: 2147483647 !important; display: flex !important; align-items: center !important; justify-content: center !important;
                padding: 0 24px 0 2px !important; background: rgba(24, 25, 29, 0.96) !important;
                border-bottom: 1px solid rgba(255, 255, 255, 0.08) !important; box-sizing: border-box !important;
                font-family: "Microsoft YaHei UI", sans-serif !important; user-select: none !important;
            }
            #${NAV_ID} .am-tabs { display: flex !important; align-items: center !important; gap: 1px !important; }
            #${NAV_ID} button.am-tab {
                appearance: none !important; border: none !important; background: transparent !important;
                color: rgba(232, 236, 244, 0.68) !important; font-size: 11px !important; padding: 3px 5px !important;
                border-radius: 4px !important; cursor: pointer !important; white-space: nowrap !important;
            }
            #${NAV_ID} button.am-tab:hover { background: rgba(255, 255, 255, 0.08) !important; color: #fff !important; }
            #${NAV_ID} button.am-tab.active { background: rgba(250, 36, 60, 0.24) !important; color: #ff5c70 !important; font-weight: 600 !important; }
            #${NAV_ID} button.am-search-toggle { position: absolute !important; right: 4px !important; top: 50% !important; transform: translateY(-50%) !important; }
            #${NAV_ID} .am-search-box { display: none !important; flex: 1 !important; align-items: center !important; gap: 4px !important; }
            #${NAV_ID}.searching .am-tabs, #${NAV_ID}.searching .am-search-toggle { display: none !important; }
            #${NAV_ID}.searching .am-search-box { display: flex !important; }
            #${NAV_ID} input.am-search-input {
                flex: 1 !important; height: 20px !important; background: rgba(255,255,255,0.08) !important;
                border: 1px solid rgba(255,255,255,0.16) !important; border-radius: 4px !important; color: #fff !important; font-size: 11px !important; padding: 0 6px !important; outline: none !important;
            }
            #${PANE_ID} {
                position: fixed !important; top: 30px !important; left: 0 !important; right: 0 !important; bottom: 0 !important;
                z-index: 2147483640 !important; display: flex !important; background: #1c1d20 !important; color: #e8ecf4 !important;
                font-family: "Microsoft YaHei UI", sans-serif !important; overflow: hidden !important;
            }
            #${PANE_ID} .am-left-rail {
                width: 82px !important; min-width: 82px !important; height: 100% !important; overflow-y: auto !important;
                background: rgba(20, 21, 24, 0.98) !important; border-right: 1px solid rgba(255, 255, 255, 0.08) !important; padding: 4px 0 !important;
            }
            #${PANE_ID} .am-sec-btn {
                display: block !important; width: 100% !important; text-align: left !important; border: none !important;
                border-left: 2px solid transparent !important; background: transparent !important; color: rgba(232, 236, 244, 0.62) !important;
                font-size: 11px !important; line-height: 1.3 !important; padding: 7px 6px !important; cursor: pointer !important;
            }
            #${PANE_ID} .am-sec-btn.active { background: rgba(250, 36, 60, 0.18) !important; border-left-color: #fa243c !important; color: #fff !important; font-weight: 600 !important; }
            #${PANE_ID} .am-right-wrap { flex: 1 !important; height: 100% !important; display: flex !important; flex-direction: column !important; overflow: hidden !important; }
            #${PANE_ID} .am-detail-header {
                display: flex !important; align-items: center !important; gap: 6px !important; height: 28px !important; min-height: 28px !important; padding: 0 6px !important;
                background: rgba(25, 26, 30, 0.98) !important; border-bottom: 1px solid rgba(255, 255, 255, 0.08) !important; box-sizing: border-box !important; overflow: hidden !important;
            }
            #${PANE_ID} .am-detail-back {
                flex: 0 0 auto !important; white-space: nowrap !important; border: none !important;
                background: rgba(255,255,255,0.12) !important; color: #fff !important; font-size: 11px !important;
                line-height: 1 !important; border-radius: 4px !important; padding: 4px 7px !important; cursor: pointer !important;
            }
            #${PANE_ID} .am-detail-back:hover { background: rgba(250, 36, 60, 0.45) !important; }
            #${PANE_ID} .am-detail-marquee {
                flex: 1 1 auto !important; min-width: 0 !important; overflow: hidden !important; position: relative !important;
                mask-image: linear-gradient(to right, transparent 0%, #000 4%, #000 94%, transparent 100%) !important;
                -webkit-mask-image: linear-gradient(to right, transparent 0%, #000 4%, #000 94%, transparent 100%) !important;
            }
            #${PANE_ID} .am-detail-title {
                display: inline-block !important; font-size: 11px !important; font-weight: 600 !important; color: #fff !important;
                white-space: nowrap !important; padding-left: 2px !important;
            }
            @keyframes airmuse-card-pulse { 0%,100% { box-shadow: 0 0 0 2px #fa243c; background: rgba(250,36,60,0.22); } 50% { box-shadow: 0 0 0 4px rgba(250,36,60,0.4); } }
            # .am-card.highlight { animation: airmuse-card-pulse 1.2s ease-in-out 3; }
            @keyframes airmuse-marquee {
                0%, 15% { transform: translateX(0); }
                85%, 100% { transform: translateX(var(--scroll-dist, 0px)); }
            }
            #${PANE_ID} .am-right-scroll { flex: 1 !important; overflow-y: auto !important; padding: 6px !important; }
            #${PANE_ID} .am-right-grid { display: grid !important; grid-template-columns: repeat(2, minmax(0, 1fr)) !important; gap: 8px 6px !important; }
            #${PANE_ID} .am-card { display: flex !important; flex-direction: column !important; cursor: pointer !important; border-radius: 5px !important; padding: 3px !important; }
            #${PANE_ID} .am-card:hover { background: rgba(255, 255, 255, 0.07) !important; }
            #${PANE_ID} .am-card-img { width: 100% !important; aspect-ratio: 1 / 1 !important; object-fit: cover !important; border-radius: 4px !important; background: #27292e !important; margin-bottom: 4px !important; }
            #${PANE_ID} .am-card-title { font-size: 11px !important; font-weight: 600 !important; color: #eef2f8 !important; line-height: 1.25 !important; display: -webkit-box !important; -webkit-line-clamp: 2 !important; -webkit-box-orient: vertical !important; overflow: hidden !important; }
            #${PANE_ID} .am-card-sub { font-size: 10px !important; color: rgba(232, 236, 244, 0.56) !important; white-space: nowrap !important; overflow: hidden !important; text-overflow: ellipsis !important; }
            #${PANE_ID} .am-track-row { display: flex !important; align-items: center !important; gap: 6px !important; padding: 5px 4px !important; border-radius: 4px !important; cursor: pointer !important; user-select: none !important; }
            #${PANE_ID} .am-track-row:hover { background: rgba(255, 255, 255, 0.10) !important; }
            #${PANE_ID} .am-track-name { font-size: 11px !important; color: #eef2f8 !important; white-space: nowrap !important; overflow: hidden !important; text-overflow: ellipsis !important; }
            #${PANE_ID} .am-track-artist { font-size: 10px !important; color: rgba(232, 236, 244, 0.52) !important; white-space: nowrap !important; overflow: hidden !important; text-overflow: ellipsis !important; }
            ::-webkit-scrollbar { width: 4px; height: 4px; }
            ::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.22); border-radius: 2px; }
        `;
        (document.head || document.documentElement).appendChild(style);
    }

    function hideBottomFloatingPlayers() {
        const vh = window.innerHeight || 276;
        document.querySelectorAll('body > *, #app > *, [role="region"], amp-chrome-player, .chrome-player, [class*="player"], [class*="Player"]').forEach(el => {
            if (!el || el.id === NAV_ID || el.id === PANE_ID || el.closest(`#${NAV_ID}, #${PANE_ID}`)) return;
            try {
                const cs = getComputedStyle(el);
                if (cs.position === 'fixed' || cs.position === 'sticky') {
                    const r = el.getBoundingClientRect();
                    if (r.height > 20 && r.height < 130 && r.bottom >= vh - 40 && r.top > vh * 0.4) {
                        el.style.setProperty('display', 'none', 'important');
                    }
                }
            } catch (_) {}
        });
    }

    function getStorefront() {
        const m = location.pathname.match(/^\/([a-z]{2})(\/|$)/i);
        return m ? m[1].toLowerCase() : 'cn';
    }

    // 4. 修复：让资料库 (/library) 和播放列表 (/playlists) 也进入双栏模式
    function getTwoPanePageType() {
        const p = location.pathname.toLowerCase();
        if (p === '/' || /^\/[a-z]{2}\/?$/.test(p) || p.includes('/home') || p.includes('/listen-now')) return 'home';
        if (p.includes('/new') || p.includes('/browse') || p.includes('/explore')) return 'new';
        if (p.includes('/radio')) return 'radio';
        if (p.includes('/library/playlists')) return 'playlists';
        if (p.includes('/library')) return 'library';
        return null;
    }

    function navigateSpa(subPath) {
        const sf = getStorefront();
        detailState = null;
        lastRenderSig = '';
        if (subPath === '/home') pendingTabType = 'home';
        else if (subPath === '/new') pendingTabType = 'new';
        else if (subPath === '/radio') pendingTabType = 'radio';
        else if (subPath.includes('/playlists')) pendingTabType = 'playlists';
        else if (subPath.includes('/library')) pendingTabType = 'library';
        else pendingTabType = null;

        if (pendingTimer) clearTimeout(pendingTimer);
        if (pendingTabType) pendingTimer = setTimeout(() => { pendingTabType = null; lastRenderSig = ''; renderTwoPane(); }, 3500);
        renderTwoPane();

        const link = document.querySelector(`a[href$="${subPath}"], a[href*="${subPath}"]`);
        if (link) link.click();
        else location.href = '/' + sf + subPath;
    }

    // 3. 修复广播页面大量显示“未知项目”：增强标题与副标题抓取逻辑
    function extractCardMetadata(el) {
        const titleSelectors = [
            '.songs-list-row__song-name',
            '.product-lockup__title',
            '.editorial-lockup__title',
            '[data-testid="product-lockup-title"]',
            '[data-testid="editorial-lockup-title"]',
            '[data-testid*="title"]',
            'a[data-testid="click-action"]',
            'h3', 'h4'
        ];
        let title = '';
        for (const sel of titleSelectors) {
            const node = el.querySelector(sel);
            if (node && node.textContent.trim()) {
                title = node.textContent.trim();
                break;
            }
        }
        if (!title) {
            const ariaEl = el.querySelector('a[aria-label], button[aria-label], [aria-label]');
            if (ariaEl) {
                const lbl = (ariaEl.getAttribute('aria-label') || '').replace(/^播放\s*/i, '').replace(/^Play\s*/i, '').trim();
                if (lbl && lbl.length > 1) title = lbl;
            }
        }
        if (!title) {
            const img = el.querySelector('img[alt]');
            if (img && img.alt && img.alt.trim()) title = img.alt.trim();
        }
        if (!title) {
            const lines = (el.textContent || '').split('\n').map(s => s.trim()).filter(s => s.length > 1 && s !== 'E');
            if (lines.length > 0) title = lines[0];
        }

        const subSelectors = [
            '.songs-list-row__by-line',
            '.product-lockup__subtitle',
            '.editorial-lockup__subtitle',
            '[data-testid="product-lockup-subtitle"]',
            '[data-testid*="subtitle"]'
        ];
        let sub = '';
        for (const sel of subSelectors) {
            const node = el.querySelector(sel);
            if (node && node.textContent.trim() && node.textContent.trim() !== title) {
                sub = node.textContent.trim();
                break;
            }
        }
        return { title, sub };
    }

    function extractSections(pageType) {
        const page = document.querySelector('#scrollable-page') || document.querySelector('main') || document.body;
        if (!page) return [];

        // 针对资料库与播放列表页面的专属结构化提取
        if (pageType === 'library' || pageType === 'playlists') {
            const rows = Array.from(page.querySelectorAll('.songs-list-row, .shelf-grid__list-item, [data-testid="library-playlist-item"], li'));
            const validItems = [];
            const seenHref = new Set();
            for (const el of rows) {
                const aEl = el.querySelector('a[href]');
                const href = aEl ? (aEl.getAttribute('href') || '') : '';
                if (!href || seenHref.has(href)) continue;
                if (!href.includes('/playlist/') && !href.includes('/album/') && !href.includes('/library/')) continue;
                seenHref.add(href);
                const { title, sub } = extractCardMetadata(el);
                const img = el.querySelector('img');
                const imgUrl = img ? (img.currentSrc || img.src || img.getAttribute('data-src') || '') : '';
                validItems.push({ title, sub, imgUrl, href, triggerEl: el });
            }
            if (validItems.length > 0) {
                const sections = [];
                if (pageType === 'library') {
                    sections.push({
                        name: '资料库分类',
                        rawEl: page,
                        items: [
                            { title: '最近添加', sub: '资料库', imgUrl: '', href: `/${getStorefront()}/library/recently-added`, isNav: true },
                            { title: '播放列表', sub: '所有歌单', imgUrl: '', href: `/${getStorefront()}/library/playlists`, isNav: true },
                            { title: '艺人', sub: '已收藏艺人', imgUrl: '', href: `/${getStorefront()}/library/artists`, isNav: true },
                            { title: '专辑', sub: '已收藏专辑', imgUrl: '', href: `/${getStorefront()}/library/albums`, isNav: true }
                        ]
                    });
                }
                sections.push({
                    name: pageType === 'playlists' ? '全部播放列表' : '最近项目',
                    rawEl: page,
                    items: validItems
                });
                return sections;
            }
        }

        const candidates = Array.from(page.querySelectorAll('section, .section, [data-testid="section-container"], .shelf-grid, [class*="shelf-grid"]'));
        const seen = new Set();
        const sections = [];
        for (const sec of candidates) {
            let items = Array.from(sec.querySelectorAll('.shelf-grid__list-item, ul > li, .songs-list-row'));
            items = items.filter(el => {
                const pLi = el.parentElement ? el.parentElement.closest('.shelf-grid__list-item, ul > li, .songs-list-row') : null;
                return !pLi || !sec.contains(pLi);
            });
            if (items.length === 0 || seen.has(items[0])) continue;
            seen.add(items[0]);

            let secName = '';
            const h = sec.querySelector('h2, h3, .section-title, [data-testid="section-title"]');
            if (h && !h.closest('ul, li')) secName = (h.textContent || '').replace(/[>\n]/g, ' ').trim();
            if (!secName) secName = sections.length === 0 ? '精选推荐' : ('频道 ' + (sections.length + 1));

            const parsed = [];
            for (const el of items) {
                const { title, sub } = extractCardMetadata(el);
                const img = el.querySelector('img');
                const aEl = el.querySelector('a[href]');
                const imgUrl = img ? (img.currentSrc || img.src || img.getAttribute('data-src') || '') : '';
                const href = aEl ? (aEl.getAttribute('href') || '') : '';
                if (title && (imgUrl || href)) parsed.push({ title, sub, imgUrl, href, triggerEl: el });
            }
            if (parsed.length > 0) sections.push({ name: secName, rawEl: sec, items: parsed });
        }
        return sections;
    }

    // 1. 修复：歌单/专辑内双击或单击任意曲目，强制从指定索引 idx 起播
    async function playTrackAtIndex(kind, collectionId, trackIdx, trackId) {
        if (detailState) { playingCtx = { path: location.pathname, sectionName: '', itemTitle: detailState.title, kind: detailState.kind, apiKind: detailState.apiKind, id: detailState.id, isLib: detailState.isLib, href: detailState.href }; }
        const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
        if (!mk) return;
        try {
            if (kind && collectionId) {
                await mk.setQueue({ [kind]: collectionId, startPosition: trackIdx });
                if (typeof mk.changeToMediaAtIndex === 'function') {
                    await mk.changeToMediaAtIndex(trackIdx);
                }
                await mk.play();
                setTimeout(pushNowPlaying, 300);
                return;
            }
            if (trackId) {
                await mk.setQueue({ song: String(trackId) });
                await mk.play();
                setTimeout(pushNowPlaying, 300);
            }
        } catch (_) {
            // 回退方案：先加载队列，稍等 120ms 再强制跳转索引
            try {
                await mk.setQueue({ [kind]: collectionId });
                if (typeof mk.changeToMediaAtIndex === 'function') {
                    await mk.changeToMediaAtIndex(trackIdx);
                }
                await mk.play();
            } catch (_) {}
        }
    }

    // 2. 修复：电台点击直接播放，绝不跳转进入电台内容页
    async function playRadioOrDirectCard(item) {
        playingCtx = { path: location.pathname, sectionName: item._secName || '', itemTitle: item.title, kind: '', id: '', href: item.href || '' };
        const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
        const mStation = (item.href || '').match(/\/station\/[^/]+\/(ra\.[a-zA-Z0-9._-]+|\d+)/);
        if (mk && mStation) {
            try {
                await mk.setQueue({ station: mStation[1] });
                await mk.play();
                setTimeout(pushNowPlaying, 400);
                return;
            } catch (_) {}
        }

        if (item.triggerEl) {
            // 先触发 hover 事件唤醒悬浮播放按钮
            item.triggerEl.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }));
            item.triggerEl.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
            const playBtn = item.triggerEl.querySelector(
                'button[data-testid="play-button"], button[aria-label*="播放"], button[aria-label*="Play"], .play-button, button'
            );
            if (playBtn) {
                playBtn.click();
                setTimeout(pushNowPlaying, 500);
                return;
            }
        }
    }

    async function openItemDetail(item, fromJump = false) {
        if (!fromJump) returnCtx = null;
        if (item.isNav && item.href) {
            navigateSpa(item.href.replace(/^\/[a-z]{2}/i, ''));
            return;
        }

        // 兼容官方歌单 (pl.xxx) 与用户自建播放列表 (p.xxx)
        const mPl = (item.href || '').match(/\/playlist\/[^/]+\/(p[l]?\.[a-zA-Z0-9._-]+)/);
        const mAl = (item.href || '').match(/\/album\/[^/]+\/(\d+)/);
        const isLibPl = (item.href || '').match(/\/library\/playlist\/(p\.[a-zA-Z0-9._-]+)/);

        const resInfo = mPl
            ? { kind: 'playlist', apiKind: mPl[1].startsWith('p.') ? 'library/playlists' : 'playlists', id: mPl[1], isLib: mPl[1].startsWith('p.') }
            : (isLibPl
                ? { kind: 'playlist', apiKind: 'library/playlists', id: isLibPl[1], isLib: true }
                : (mAl ? { kind: 'album', apiKind: 'albums', id: mAl[1], isLib: false } : null));

        if (!resInfo) {
            await playRadioOrDirectCard(item);
            return;
        }

        detailState = { title: item.title, kind: resInfo.kind, apiKind: resInfo.apiKind, id: resInfo.id, isLib: resInfo.isLib, href: item.href, tracks: [], loading: true };
        renderTwoPane();

        const sf = getStorefront();
        const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
        let tracks = [];
        if (mk && mk.api && typeof mk.api.music === 'function') {
            try {
                const endpoint = resInfo.isLib ? `/v1/me/library/playlists/${resInfo.id}/tracks` : `/v1/catalog/${sf}/${resInfo.apiKind}/${resInfo.id}`;
                const resp = await mk.api.music(endpoint, resInfo.isLib ? {} : { include: 'tracks' });
                const rawTracks = resInfo.isLib
                    ? resp?.data?.data
                    : resp?.data?.data?.[0]?.relationships?.tracks?.data;
                if (Array.isArray(rawTracks)) {
                    tracks = rawTracks.map(t => ({
                        id: t.id,
                        name: t.attributes?.name || '未知曲目',
                        artist: t.attributes?.artistName || ''
                    }));
                }
            } catch (_) {}
        }

        if (detailState && detailState.id === resInfo.id) {
            detailState.loading = false;
            detailState.tracks = tracks;
            renderTwoPane();
        }
    }

    function renderTwoPane() {
        const pageType = getTwoPanePageType();
        const activeType = pendingTabType || pageType;
        let pane = document.getElementById(PANE_ID);
        if (!activeType) { if (pane) pane.remove(); return; }
        if (!pane && document.body) {
            pane = document.createElement('div');
            pane.id = PANE_ID;
            pane.innerHTML = `<div class="am-left-rail"></div><div class="am-right-wrap"></div>`;
            document.body.appendChild(pane);
        }
        if (!pane) return;

        const sections = (pageType && (!pendingTabType || pendingTabType === pageType)) ? extractSections(pageType) : [];
        if (sections.length > 0 && pendingTabType === pageType) pendingTabType = null;

        const rail = pane.querySelector('.am-left-rail');
        const rightWrap = pane.querySelector('.am-right-wrap');
        if (sections.length === 0) {
            rail.innerHTML = '';
            rightWrap.innerHTML = `<div style="padding:40px;text-align:center;color:#9aa4b6;font-size:11px;">正在加载内容...</div>`;
            return;
        }
        if (selectedSectionIdx >= sections.length) selectedSectionIdx = 0;

        const sig = `${pageType}|${selectedSectionIdx}|${sections.length}|${detailState ? detailState.id + ':' + detailState.loading + ':' + detailState.tracks.length : 'g'}`;
        if (lastRenderSig === sig) return;
        lastRenderSig = sig;

        rail.innerHTML = '';
        sections.forEach((sec, idx) => {
            const btn = document.createElement('button');
            btn.className = 'am-sec-btn' + (idx === selectedSectionIdx ? ' active' : '');
            btn.textContent = sec.name;
            btn.onclick = () => {
                selectedSectionIdx = idx; detailState = null; lastRenderSig = '';
                try { sec.rawEl.scrollIntoView({ block: 'center' }); } catch (_) {}
                renderTwoPane();
            };
            rail.appendChild(btn);
        });

        if (detailState) {
            rightWrap.innerHTML = '';
            const hdr = document.createElement('div');
            hdr.className = 'am-detail-header';
            const back = document.createElement('button');
            back.className = 'am-detail-back';
            back.textContent = '← 返回';
            back.onclick = () => {
                if (returnCtx) {
                    const rc = returnCtx;
                    returnCtx = null;
                    detailState = rc.detailSnapshot;
                    selectedSectionIdx = rc.sectionIdx;
                    lastRenderSig = '';
                    if (rc.path && rc.path !== location.pathname) {
                        navigateSpa(rc.path.replace(/^\/[a-z]{2}/i, '') || '/home', true);
                    } else {
                        renderTwoPane();
                    }
                    return;
                }
                detailState = null; lastRenderSig = ''; renderTwoPane();
            };
            const marquee = document.createElement('div');
            marquee.className = 'am-detail-marquee';
            const ttl = document.createElement('div');
            ttl.className = 'am-detail-title';
            ttl.textContent = detailState.title;
            marquee.appendChild(ttl);
            hdr.append(back, marquee);
            requestAnimationFrame(() => {
                const overflow = ttl.scrollWidth - marquee.clientWidth;
                if (overflow > 4) {
                    ttl.style.setProperty('--scroll-dist', `-${overflow + 8}px`);
                    const sec = Math.max(4, Math.min(14, overflow / 18));
                    ttl.style.animation = `airmuse-marquee ${sec}s ease-in-out infinite alternate`;
                }
            });
            rightWrap.appendChild(hdr);

            const scroller = document.createElement('div');
            scroller.className = 'am-right-scroll';
            if (detailState.loading) {
                scroller.innerHTML = `<div style="padding:30px;text-align:center;font-size:11px;color:#9aa4b6;">加载曲目中...</div>`;
            } else if (detailState.tracks.length === 0) {
                scroller.innerHTML = `<div style="padding:30px;text-align:center;font-size:11px;color:#9aa4b6;">暂无可播放曲目</div>`;
            } else {
                detailState.tracks.forEach((tr, idx) => {
                    const row = document.createElement('div');
                    row.className = 'am-track-row';
                    row.title = '单击或双击播放此曲目';
                    row.innerHTML = `<div style="width:18px;font-size:10px;color:#8892a4;text-align:center;">${idx + 1}</div><div style="flex:1;min-width:0;"><div class="am-track-name">${tr.name}</div><div class="am-track-artist">${tr.artist}</div></div>`;
                    row.onclick = () => playTrackAtIndex(detailState.kind, detailState.id, idx, tr.id);
                    row.ondblclick = () => playTrackAtIndex(detailState.kind, detailState.id, idx, tr.id);
                    scroller.appendChild(row);
                });
            }
            rightWrap.appendChild(scroller);
            return;
        }

        rightWrap.innerHTML = `<div class="am-right-scroll"><div class="am-right-grid"></div></div>`;
        const grid = rightWrap.querySelector('.am-right-grid');
        if (pendingTarget) {
            const foundIdx = sections.findIndex(s => s.name === pendingTarget.sectionName || s.items.some(it => it.title === pendingTarget.itemTitle));
            if (foundIdx >= 0) selectedSectionIdx = foundIdx;
        }
        const targetHighlightTitle = pendingTarget ? pendingTarget.itemTitle : '';
        if (pendingTarget && sections[selectedSectionIdx]?.items.some(it => it.title === targetHighlightTitle)) {
            pendingTarget = null;
        }
        sections[selectedSectionIdx].items.forEach(item => {
            item._secName = sections[selectedSectionIdx].name;
            const card = document.createElement('div');
            card.className = 'am-card';
            if (item.imgUrl) {
                const img = document.createElement('img');
                img.className = 'am-card-img';
                img.src = item.imgUrl;
                card.appendChild(img);
            }
            const t = document.createElement('div');
            t.className = 'am-card-title';
            t.textContent = item.title;
            card.appendChild(t);
            if (item.sub) {
                const s = document.createElement('div');
                s.className = 'am-card-sub';
                s.textContent = item.sub;
                card.appendChild(s);
            }
            card.onclick = () => openItemDetail(item);
            if (targetHighlightTitle && item.title === targetHighlightTitle) {
                card.classList.add('highlight');
                setTimeout(() => card.scrollIntoView({ behavior: 'smooth', block: 'center' }), 80);
            }
            grid.appendChild(card);
        });
    }

    function injectMicroNav() {
        if (document.getElementById(NAV_ID) || !document.body) return;
        const nav = document.createElement('div');
        nav.id = NAV_ID;
        // 3. 修复：将“歌单”改为“播放列表”
        const tabs = [
            { label: '主页', path: '/home' },
            { label: '新发现', path: '/new' },
            { label: '广播', path: '/radio' },
            { label: '资料库', path: '/library/recently-added' },
            { label: '播放列表', path: '/library/playlists' }
        ];
        const wrap = document.createElement('div');
        wrap.className = 'am-tabs';
        tabs.forEach(t => {
            const btn = document.createElement('button');
            btn.className = 'am-tab';
            btn.textContent = t.label;
            btn.setAttribute('data-path', t.path);
            btn.onclick = () => { selectedSectionIdx = 0; navigateSpa(t.path); };
            wrap.appendChild(btn);
        });
        const sBox = document.createElement('div');
        sBox.className = 'am-search-box';
        const inp = document.createElement('input');
        inp.className = 'am-search-input';
        inp.placeholder = '搜索 Apple Music...';
        inp.onkeydown = (e) => {
            if (e.key === 'Enter' && inp.value.trim()) {
                pendingTabType = null; detailState = null;
                location.href = `/${getStorefront()}/search?term=${encodeURIComponent(inp.value.trim())}`;
                nav.classList.remove('searching');
            } else if (e.key === 'Escape') nav.classList.remove('searching');
        };
        const closeBtn = document.createElement('button');
        closeBtn.className = 'am-tab';
        closeBtn.textContent = '✕';
        closeBtn.onclick = () => nav.classList.remove('searching');
        sBox.append(inp, closeBtn);

        const sToggle = document.createElement('button');
        sToggle.className = 'am-tab am-search-toggle';
        sToggle.textContent = '🔍';
        sToggle.onclick = () => { nav.classList.toggle('searching'); if (nav.classList.contains('searching')) inp.focus(); };

        nav.append(wrap, sBox, sToggle);
        document.body.appendChild(nav);
    }

    function syncAll() {
        if (location.pathname !== lastPath) {
            lastPath = location.pathname;
            selectedSectionIdx = 0;
            detailState = null;
        }
        injectCSS();
        injectMicroNav();
        hideBottomFloatingPlayers();
        const nav = document.getElementById(NAV_ID);
        if (nav) {
            const cur = pendingTabType ? '/' + pendingTabType : location.pathname.toLowerCase();
            nav.querySelectorAll('button.am-tab[data-path]').forEach(b => {
                const dp = b.getAttribute('data-path');
                let isActive = false;
                if (dp === '/library/recently-added') isActive = cur.includes('/library') && !cur.includes('/playlists');
                else if (dp === '/library/playlists') isActive = cur.includes('/playlists');
                else isActive = cur.includes(dp) || (dp === '/home' && /^\/[a-z]{2}\/?$/.test(cur));
                b.classList.toggle('active', isActive);
            });
        }
        renderTwoPane();
        pushNowPlaying();
    }

    syncAll();
    if (!window.__airmuseAppleLoop) {
        window.__airmuseAppleLoop = true;
        setInterval(syncAll, 350);
    }
})();
)JS";

inline constexpr const wchar_t* kSpotifyScript = LR"JS(
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

inline constexpr const wchar_t* kQQMusicScript = LR"JS(
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

inline WebAdapterSpec GetWebAdapterSpec(WebPlatform platform) {
    switch (platform) {
    case WebPlatform::Spotify:
        return {
            WebPlatform::Spotify, L"Spotify", L"https://open.spotify.com", kSpotifyScript,
            L"document.querySelector('[data-testid=\"control-button-playpause\"]')?.click();",
            L"document.querySelector('[data-testid=\"control-button-skip-forward\"]')?.click();",
            L"document.querySelector('[data-testid=\"control-button-skip-back\"]')?.click();",
            L""
        };
    case WebPlatform::QQMusic:
        return {
            WebPlatform::QQMusic, L"QQ 音乐", L"https://y.qq.com", kQQMusicScript,
            L"(function(){const a=document.querySelector('audio');if(a){a.paused?a.play():a.pause();}})();",
            L"document.querySelector('.btn_big_next, [title*=\"下一首\"]')?.click();",
            L"document.querySelector('.btn_big_prev, [title*=\"上一首\"]')?.click();",
            L"(function(){const a=document.querySelector('audio');if(a)a.currentTime=%.3f;})();"
        };
    case WebPlatform::AppleMusic:
    default:
        return {
            WebPlatform::AppleMusic, L"Apple Music", L"https://music.apple.com", kAppleMusicScript,
            L"(function(){const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(mk)mk.isPlaying?mk.pause():mk.play();})();",
            L"(function(){const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(mk)mk.skipToNextItem();})();",
            L"(function(){const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(mk)mk.skipToPreviousItem();})();",
            L"(function(){const mk=window.MusicKit&&MusicKit.getInstance&&MusicKit.getInstance();if(mk)mk.seekToTime(%.3f);})();"
        };
    }
}

} // namespace airmuse





