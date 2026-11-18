// airmuse_apple_engine.js
// Auto-generated bundle: AirMuse UI Core + AppleMusicProvider
// DO NOT EDIT DIRECTLY: Modify src/media/airmuse_ui_core.js or src/media/provider/apple_music_provider.js instead.

(function () {
    function ensureAppMounted() {
        try {
            if (window.AirMuseUI && window.AirMuseUI.dom && window.AirMuseUI.dom.appRoot) {
                if (document.body && !document.body.contains(window.AirMuseUI.dom.appRoot)) {
                    document.body.appendChild(window.AirMuseUI.dom.appRoot);
                }
            }
        } catch (_) {}
    }

    if (window.__airmuseEngineInited) {
        ensureAppMounted();
        return;
    }

    function bootstrap() {
        if (!document.body) {
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', bootstrap, { once: true });
            } else {
                setTimeout(bootstrap, 50);
            }
            return;
        }

        if (window.__airmuseEngineInited) {
            ensureAppMounted();
            return;
        }
        window.__airmuseEngineInited = true;

        try {
            // ── 1. 通用 UI 核心组件框架 (Universal UI Core) ──
            /**
 * airmuse_ui_core.js
 * AirMuse 通用前端页面渲染与组件化核心框架 (Universal UI Core & Component Library)
 *
 * 职责：
 * 1. 负责窗口内全部 DOM 结构构建、深色玻璃拟物与响应式 CSS 主题管理
 * 2. 提供顶部微型导航条 (MicroNav)、替换式搜索栏 (SearchBar)、左侧专区栏 (Sidebar)、
 *    右侧卡片网格 (CardGrid)、专区曲目详情抽屉 (DetailView) 等全套组件
 * 3. 彻底与特定音源 (Apple Music / QQ 音乐 / Spotify) 解耦，通过标准 IDataProvider 接口进行数据驱动与交互
 */

(function (global) {
    if (global.AirMuseUI) return;

    // ── 0. 工具函数 ────────────────────────────────────────────────────────
    function escapeHtml(str) {
        if (!str) return '';
        return String(str)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;');
    }

    function formatDuration(ms) {
        if (!ms || isNaN(ms)) return '';
        const sec = Math.floor(ms / 1000);
        const m = Math.floor(sec / 60);
        const s = sec % 60;
        return `${m}:${s < 10 ? '0' : ''}${s}`;
    }

    // 角标文字映射
    const DEFAULT_TYPE_NAMES = {
        song: '单曲',
        'fav-song': '喜爱',
        album: '专辑',
        playlist: '歌单',
        'user-playlist': '自建',
        'fav-playlist': '收藏',
        station: '电台',
        editorial: '精选',
        artist: '艺人',
        item: '推荐',
        default: '条目'
    };

    // ── 1. 标准音源数据提供者接口 (IDataProvider Contract) ──────────────────
    class IDataProvider {
        get id() { return 'abstract-provider'; }
        get name() { return '未知音源'; }
        get tabs() { return [{ id: 'home', label: '主页' }]; }
        get searchScopes() { return [{ id: 'default', label: '全部', placeholder: '搜索音乐...' }]; }

        async loadInitialData() { return {}; }
        async fetchTabData(tabId, forceRefresh = false) { return []; }
        async loadMore(category, tabId, isSearching, scopeId) { return []; }
        async search(query, scopeId) { return []; }
        async loadDetail(item) { return []; }
        async playItem(item, category, index) {}
        async playCollection(item, tracks, startIndex = 0) {}
        onNowPlayingChange(callback) {}
        onUserChange(callback) {}
    }

    // ── 2. 主题与样式管理 (AirMuseUI.Theme) ─────────────────────────────────
    const Theme = {
        STYLE_ID: 'airmuse-modern-css',
        CSS: `
            body > *:not(#airmuse-app) { display: none !important; }
            amp-chrome-player, amp-lcd, .web-chrome, .chrome-player,
            .web-chrome-playback-controls, .playback-controls,
            .web-navigation__header, .web-navigation__sidebar,
            .web-navigation__native-upsell, .upsell-banner { display: none !important; }

            html, body {
                background: #18181b !important;
                margin: 0 !important;
                padding: 0 !important;
                overflow: hidden !important;
                width: 100vw !important;
                height: 100vh !important;
                user-select: none !important;
            }

            #airmuse-app {
                position: fixed !important;
                top: 0 !important;
                left: 0 !important;
                right: 0 !important;
                bottom: 0 !important;
                width: 100% !important;
                height: 100% !important;
                background: #18181b !important;
                display: flex !important;
                flex-direction: column !important;
                z-index: 2147483647 !important;
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, "Microsoft YaHei", sans-serif !important;
                color: #f5f5f7 !important;
                box-sizing: border-box !important;
                overflow: hidden !important;
            }

            /* 顶部微型导航条 MicroNav (居中标签组，左刷新，右切换+搜索) */
            .am-top-bar {
                height: 30px;
                background: #141416;
                border-bottom: 1px solid rgba(255, 255, 255, 0.07);
                display: flex;
                align-items: center;
                justify-content: space-between;
                padding: 0 5px;
                flex-shrink: 0;
                position: relative;
            }
            .am-top-left {
                display: flex;
                align-items: center;
                width: 32px;
                justify-content: flex-start;
            }
            .am-top-center {
                display: flex;
                align-items: center;
                justify-content: center;
                flex: 1;
            }
            .am-top-right {
                display: flex;
                align-items: center;
                width: 48px;
                justify-content: flex-end;
                gap: 2px;
            }

            /* 图标小按钮 */
            .am-icon-btn {
                background: transparent;
                border: none;
                color: #a1a1aa;
                cursor: pointer;
                padding: 3px 5px;
                font-size: 11px;
                border-radius: 4px;
                transition: all 0.15s ease;
                display: inline-flex;
                align-items: center;
                justify-content: center;
                line-height: 1;
            }
            .am-icon-btn:hover {
                background: rgba(255, 255, 255, 0.09);
                color: #ffffff;
            }
            .am-icon-btn.active {
                color: #ffffff;
                background: rgba(255, 255, 255, 0.16);
            }

            /* 居中标签组 */
            .am-tab-group {
                display: inline-flex;
                align-items: center;
                background: #1e1e22;
                border-radius: 6px;
                padding: 2px;
                gap: 1px;
                border: 1px solid rgba(255, 255, 255, 0.05);
            }
            .am-tab-btn {
                border: none;
                background: transparent;
                color: #a1a1aa;
                font-size: 10px;
                font-weight: 500;
                padding: 2px 7px;
                border-radius: 4px;
                cursor: pointer;
                transition: all 0.15s ease;
                white-space: nowrap;
                line-height: 1.2;
            }
            .am-tab-btn:hover { color: #f4f4f5; }
            .am-tab-btn.active {
                background: linear-gradient(180deg, #ececf0 0%, #c4c4cc 100%);
                color: #121214;
                font-weight: 600;
                box-shadow: 0 1px 4px rgba(0, 0, 0, 0.45), inset 0 1px 0 rgba(255, 255, 255, 0.8);
                border: 1px solid rgba(255, 255, 255, 0.4);
            }

            /* 快速搜索栏 (完全替换顶部标签栏，共享 32px 高度) */
            .am-search-bar {
                height: 32px;
                background: #18181b;
                border-bottom: 1px solid rgba(255, 255, 255, 0.08);
                display: flex;
                align-items: center;
                padding: 0 6px;
                gap: 5px;
                flex-shrink: 0;
            }
            .am-search-back-btn {
                font-size: 18px !important;
                font-weight: 700 !important;
                width: 22px !important;
                height: 22px !important;
                padding: 0 !important;
                color: #a1a1aa !important;
                border-radius: 4px !important;
                line-height: 1 !important;
            }
            .am-search-back-btn:hover {
                color: #ffffff !important;
                background: rgba(255, 255, 255, 0.08) !important;
            }
            .am-search-input-wrap {
                flex: 1;
                display: flex;
                align-items: center;
                background: #242428;
                border: 1px solid rgba(255, 255, 255, 0.08);
                border-radius: 6px;
                padding: 0 6px;
                height: 22px;
                position: relative;
                min-width: 0;
                transition: border-color 0.15s, background 0.15s;
            }
            .am-search-input-wrap:focus-within {
                border-color: rgba(228, 228, 231, 0.55);
                background: #27272b;
                box-shadow: 0 0 6px rgba(228, 228, 231, 0.15);
            }
            .am-search-icon {
                font-size: 10px;
                color: #71717a;
                margin-right: 4px;
                flex-shrink: 0;
                line-height: 1;
            }
            .am-search-input {
                flex: 1;
                border: none;
                background: transparent;
                color: #f4f4f5;
                font-size: 10px;
                outline: none;
                padding: 0;
                min-width: 0;
                line-height: 1.2;
            }
            .am-search-input::placeholder { color: #71717a; }
            .am-search-clear {
                border: none;
                background: transparent;
                color: #71717a;
                font-size: 10px;
                cursor: pointer;
                padding: 0 2px;
                border-radius: 2px;
                line-height: 1;
                flex-shrink: 0;
            }
            .am-search-clear:hover { color: #f4f4f5; }
            .am-search-right {
                display: flex;
                align-items: center;
                gap: 4px;
                flex-shrink: 0;
            }
            .am-search-scope {
                display: flex;
                background: #242428;
                border-radius: 12px;
                padding: 2px;
                gap: 2px;
                border: 1px solid rgba(255, 255, 255, 0.08);
                flex-shrink: 0;
            }
            .am-scope-btn {
                border: none;
                background: transparent;
                color: #a1a1aa;
                font-size: 9px;
                font-weight: 500;
                padding: 1.5px 6px;
                border-radius: 9px;
                cursor: pointer;
                transition: all 0.15s ease;
                white-space: nowrap;
                line-height: 1.2;
            }
            .am-scope-btn:hover { color: #ffffff; }
            .am-scope-btn.active {
                background: linear-gradient(180deg, #ececf0 0%, #c4c4cc 100%);
                color: #121214;
                font-weight: 600;
                box-shadow: 0 1px 3px rgba(0, 0, 0, 0.4);
                border: 1px solid rgba(255, 255, 255, 0.35);
            }

            /* 主内容区域：左侧分类列表 + 右侧卡片瀑布流 */
            .am-main-layout {
                flex: 1;
                display: flex;
                min-height: 0;
                overflow: hidden;
            }

            /* 左侧分类专区 (Sidebar) */
            .am-sidebar {
                width: 72px;
                background: #121214;
                border-right: 1px solid rgba(255, 255, 255, 0.05);
                display: flex;
                flex-direction: column;
                overflow-y: auto;
                overflow-x: hidden;
                flex-shrink: 0;
                padding: 4px 0 8px 0;
                scroll-behavior: smooth;
            }
            .am-sidebar::-webkit-scrollbar { width: 3.5px; }
            .am-sidebar::-webkit-scrollbar-track { background: rgba(255, 255, 255, 0.03); }
            .am-sidebar::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.35); border-radius: 2px; }
            .am-sidebar::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.6); }

            .am-cat-item {
                flex-shrink: 0;
                min-height: 24px;
                height: 24px;
                display: flex;
                align-items: center;
                justify-content: center;
                padding: 0 4px;
                box-sizing: border-box;
                font-size: 9.5px;
                color: #8e8e93;
                text-align: center;
                cursor: pointer;
                transition: all 0.12s ease;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
                border-left: 2px solid transparent;
                line-height: 1.25;
            }
            .am-cat-item span {
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
                max-width: 100%;
                display: block;
            }
            .am-cat-item:hover {
                color: #e4e4e7;
                background: rgba(255, 255, 255, 0.03);
            }
            .am-cat-item.active {
                color: #ffffff;
                font-weight: 600;
                border-left-color: #e4e4e7;
                background: rgba(255, 255, 255, 0.09);
                box-shadow: inset 1px 0 0 rgba(255, 255, 255, 0.25);
            }

            /* 右侧内容面板 (Content Panel) */
            .am-content-panel {
                flex: 1;
                min-width: 0;
                display: flex;
                flex-direction: column;
                position: relative;
                overflow: hidden;
                background: #18181b;
            }

            /* 卡片滚动区域 (Cards Scroll) */
            .am-cards-scroll {
                flex: 1;
                min-height: 0;
                overflow-y: auto;
                overflow-x: hidden;
                padding: 6px;
                display: flex;
                flex-direction: column;
                gap: 5px;
            }
            .am-cards-scroll::-webkit-scrollbar { width: 3px; }
            .am-cards-scroll::-webkit-scrollbar-track { background: rgba(255, 255, 255, 0.03); }
            .am-cards-scroll::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.28); border-radius: 2px; }
            .am-cards-scroll::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.48); }

            /* 单栏卡片 (默认模式) */
            .am-item-card {
                display: flex;
                align-items: center;
                background: #202024;
                border-radius: 5px;
                padding: 4px 6px;
                gap: 7px;
                cursor: pointer;
                transition: background 0.12s ease, transform 0.08s ease;
                position: relative;
                overflow: hidden;
                border: 1px solid rgba(255, 255, 255, 0.03);
                min-height: 44px;
                flex-shrink: 0;
            }
            .am-item-card:hover {
                background: #2a2a2e;
                transform: translateX(1px);
            }
            .am-item-card:active {
                transform: scale(0.99);
            }

            /* 封面容器与封面图片 */
            .am-thumb-wrap {
                position: relative;
                width: 38px;
                height: 38px;
                flex-shrink: 0;
                border-radius: 4px;
                overflow: hidden;
                background: #27272a;
            }
            .am-item-thumb {
                width: 100%;
                height: 100%;
                object-fit: cover;
                display: block;
            }

            /* 封面角标 */
            .am-cover-badge {
                position: absolute;
                top: 2px;
                right: 2px;
                font-size: 7px;
                line-height: 1;
                padding: 1.5px 3px;
                border-radius: 2px;
                font-weight: 600;
                box-shadow: 0 1px 3px rgba(0, 0, 0, 0.65);
                pointer-events: none;
                letter-spacing: 0.2px;
            }

            /* 角标色彩系统 (银灰玻璃微光规范) */
            .type-song { background: rgba(71, 85, 105, 0.88); color: #f8fafc; border: 1px solid rgba(255, 255, 255, 0.15); }
            .type-fav-song { background: rgba(100, 116, 139, 0.88); color: #f8fafc; border: 1px solid rgba(255, 255, 255, 0.15); }
            .type-album { background: rgba(82, 82, 91, 0.88); color: #f8fafc; border: 1px solid rgba(255, 255, 255, 0.15); }
            .type-playlist { background: rgba(63, 63, 70, 0.88); color: #f8fafc; border: 1px solid rgba(255, 255, 255, 0.15); }
            .type-user-playlist { background: rgba(75, 85, 99, 0.88); color: #f8fafc; border: 1px solid rgba(255, 255, 255, 0.15); }
            .type-fav-playlist { background: rgba(63, 63, 70, 0.88); color: #f8fafc; border: 1px solid rgba(255, 255, 255, 0.15); }
            .type-station { background: rgba(87, 83, 78, 0.88); color: #f8fafc; border: 1px solid rgba(255, 255, 255, 0.15); }
            .type-editorial { background: rgba(68, 64, 60, 0.88); color: #f8fafc; border: 1px solid rgba(255, 255, 255, 0.15); }
            .type-artist { background: rgba(71, 85, 105, 0.88); color: #f8fafc; border: 1px solid rgba(255, 255, 255, 0.15); }
            .type-default { background: rgba(82, 82, 91, 0.88); color: #f8fafc; border: 1px solid rgba(255, 255, 255, 0.15); }

            .am-item-body {
                flex: 1;
                min-width: 0;
                display: flex;
                flex-direction: column;
                justify-content: center;
                gap: 2px;
            }
            .am-item-title {
                font-size: 10.5px;
                font-weight: 600;
                color: #f4f4f5;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
                line-height: 1.3;
            }
            .am-item-sub {
                font-size: 9.5px;
                color: #a1a1aa;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
                line-height: 1.2;
            }

            /* 双栏网格模式 (2-Column Grid) */
            .am-cards-scroll.grid-2col {
                display: grid !important;
                grid-template-columns: repeat(2, minmax(0, 1fr)) !important;
                grid-auto-rows: max-content !important;
                gap: 6px !important;
                align-content: start !important;
                padding: 6px !important;
            }
            .am-cards-scroll.grid-2col .am-item-card {
                display: flex !important;
                flex-direction: column !important;
                align-items: stretch !important;
                padding: 5px !important;
                gap: 4px !important;
                min-width: 0 !important;
                height: auto !important;
                min-height: max-content !important;
                flex-shrink: 0 !important;
                overflow: hidden !important;
            }
            .am-cards-scroll.grid-2col .am-thumb-wrap {
                width: 100% !important;
                height: auto !important;
                aspect-ratio: 1 / 1 !important;
                position: relative !important;
                flex-shrink: 0 !important;
                border-radius: 4px !important;
                overflow: hidden !important;
            }
            .am-cards-scroll.grid-2col .am-item-thumb {
                width: 100% !important;
                height: 100% !important;
                aspect-ratio: 1 / 1 !important;
                border-radius: 4px !important;
                display: block !important;
                object-fit: cover !important;
            }
            .am-cards-scroll.grid-2col .am-cover-badge {
                top: 3px !important;
                right: 3px !important;
                font-size: 7.5px !important;
                padding: 2px 4px !important;
            }
            .am-cards-scroll.grid-2col .am-item-body {
                width: 100% !important;
                min-width: 0 !important;
                display: flex !important;
                flex-direction: column !important;
                gap: 2px !important;
                flex-shrink: 0 !important;
                margin-top: 2px !important;
            }
            .am-cards-scroll.grid-2col .am-item-title {
                font-size: 10px !important;
                line-height: 1.25 !important;
                white-space: nowrap !important;
                overflow: hidden !important;
                text-overflow: ellipsis !important;
            }
            .am-cards-scroll.grid-2col .am-item-sub {
                font-size: 8.5px !important;
                line-height: 1.2 !important;
                white-space: nowrap !important;
                overflow: hidden !important;
                text-overflow: ellipsis !important;
            }

            /* 触底加载提示 */
            .am-loading-more {
                text-align: center;
                font-size: 9.5px;
                color: #71717a;
                padding: 8px 0;
                grid-column: 1 / -1;
            }

            /* 详情页模式 (仅在右侧面板内展开) */
            .am-detail-view {
                display: none;
                flex-direction: column;
                min-height: 0;
                background: #18181b;
                position: absolute;
                inset: 0;
                z-index: 5;
            }
            .am-detail-header {
                height: 28px;
                padding: 0 8px;
                background: #141416;
                border-bottom: 1px solid rgba(255, 255, 255, 0.06);
                display: flex;
                align-items: center;
                gap: 6px;
                flex-shrink: 0;
            }
            .am-detail-btn {
                border: none;
                background: #27272a;
                color: #f4f4f5;
                font-size: 10px;
                padding: 2px 7px;
                border-radius: 4px;
                cursor: pointer;
            }
            .am-detail-btn:hover { background: #3f3f46; }
            .am-detail-btn.play-all {
                background: linear-gradient(180deg, #ececf0 0%, #c4c4cc 100%);
                color: #121214;
                font-weight: 600;
                border: 1px solid rgba(255, 255, 255, 0.45);
                box-shadow: 0 1px 3px rgba(0, 0, 0, 0.4), inset 0 1px 0 rgba(255, 255, 255, 0.7);
            }
            .am-detail-btn.play-all:hover {
                background: linear-gradient(180deg, #ffffff 0%, #d4d4d8 100%);
                color: #000000;
                box-shadow: 0 1px 4px rgba(0, 0, 0, 0.5), inset 0 1px 0 #ffffff;
            }
            .am-detail-title {
                font-size: 11px;
                font-weight: 600;
                color: #f4f4f5;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
                flex: 1;
            }
            .am-track-row {
                display: flex;
                align-items: center;
                gap: 8px;
                padding: 5px 8px;
                border-radius: 4px;
                cursor: pointer;
                transition: background 0.12s;
            }
            .am-track-row:hover { background: #222226; }
            .am-track-row.active {
                background: rgba(255, 255, 255, 0.10);
                border-left: 2px solid #e4e4e7;
            }
            .am-track-row.active .am-track-idx {
                color: #ffffff;
                font-weight: 700;
                text-shadow: 0 0 6px rgba(255, 255, 255, 0.4);
            }
            .am-track-row.active .am-track-name {
                color: #ffffff;
                font-weight: 600;
                text-shadow: 0 0 6px rgba(255, 255, 255, 0.3);
            }
            .am-track-row.active .am-track-artist {
                color: #c4c4cc;
            }
            .am-track-idx { font-size: 9.5px; color: #71717a; width: 16px; text-align: center; }
            .am-track-body { flex: 1; min-width: 0; display: flex; flex-direction: column; }
            .am-track-name { font-size: 10.5px; color: #f4f4f5; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            .am-track-artist { font-size: 9px; color: #a1a1aa; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
            .am-track-dur { font-size: 9px; color: #71717a; margin-left: 4px; }

            .am-empty-tip {
                font-size: 11px;
                color: #71717a;
                text-align: center;
                margin-top: 40px;
            }
        `,
        apply() {
            let el = document.getElementById(this.STYLE_ID);
            if (!el) {
                el = document.createElement('style');
                el.id = this.STYLE_ID;
                (document.head || document.documentElement).appendChild(el);
            }
            el.textContent = this.CSS;
        }
    };

    // ── 3. 核心应用骨架与组件 (AirMuseUI) ──────────────────────────────────
    const AirMuseUI = {
        IDataProvider,
        Theme,
        provider: null,

        // 状态
        currentTab: '',
        activeCategoryIdx: 0,
        is2Col: false,
        isSearching: false,
        currentSearchScope: '',
        currentSearchCategories: [],
        activeSearchCategoryIdx: 0,
        isLoadingMore: false,
        currentDetailItem: null,
        datasets: {},

        // DOM 元素引用
        dom: {
            appRoot: null,
            topBar: null,
            tabGroup: null,
            refreshBtn: null,
            layoutBtn: null,
            searchBtn: null,
            searchBar: null,
            searchBackBtn: null,
            searchInput: null,
            searchClear: null,
            searchLayoutBtn: null,
            searchScope: null,
            sidebar: null,
            cardsScroll: null,
            detailView: null,
            detailBack: null,
            detailPlayAll: null,
            detailTitle: null,
            detailScroll: null
        },

        // 初始化
        init(provider) {
            this.provider = provider;
            try {
                this.Theme.apply();
                this.mountScaffold();
                this.bindBridge();
                this.startSPAKeeper();
                this.loadInitialData();
            } catch (err) {
                console.error('[AirMuseUI] init error:', err);
            }
        },

        // 构建脚手架
        mountScaffold() {
            let app = document.getElementById('airmuse-app');
            if (app) app.remove();

            app = document.createElement('div');
            app.id = 'airmuse-app';
            app.innerHTML = `
                <div class="am-top-bar" id="amTopBar">
                    <div class="am-top-left">
                        <button class="am-icon-btn" id="amRefreshBtn" title="刷新数据">⟳</button>
                    </div>
                    <div class="am-top-center">
                        <div class="am-tab-group" id="amTabGroup"></div>
                    </div>
                    <div class="am-top-right">
                        <button class="am-icon-btn" id="amLayoutBtn" title="切换单栏/双栏">⚏</button>
                        <button class="am-icon-btn" id="amSearchBtn" title="搜索 (替换顶部栏)"><svg width="11" height="11" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="display:inline-block; vertical-align:middle;"><circle cx="6.5" cy="6.5" r="4.5"/><line x1="10" y1="10" x2="14.5" y2="14.5"/></svg></button>
                    </div>
                </div>
                <div class="am-search-bar" id="amSearchBar" style="display: none;">
                    <button class="am-icon-btn am-search-back-btn" id="amSearchBackBtn" title="返回标签栏 (Esc)">‹</button>
                    <div class="am-search-input-wrap">
                        <span class="am-search-icon"><svg width="11" height="11" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="display:inline-block; vertical-align:middle;"><circle cx="6.5" cy="6.5" r="4.5"/><line x1="10" y1="10" x2="14.5" y2="14.5"/></svg></span>
                        <input type="text" class="am-search-input" id="amSearchInput" placeholder="搜索..." autocomplete="off" />
                        <button class="am-search-clear" id="amSearchClear" style="display: none;" title="清空">✕</button>
                    </div>
                    <div class="am-search-right">
                        <button class="am-icon-btn" id="amSearchLayoutBtn" title="切换单栏/双栏">⚏</button>
                        <div class="am-search-scope" id="amSearchScope"></div>
                    </div>
                </div>
                <div class="am-main-layout">
                    <div class="am-sidebar" id="amSidebar"></div>
                    <div class="am-content-panel">
                        <div class="am-cards-scroll" id="amCardsScroll"></div>
                        <div class="am-detail-view" id="amDetailView">
                            <div class="am-detail-header">
                                <button class="am-detail-btn" id="amDetailBack">← 返回</button>
                                <button class="am-detail-btn play-all" id="amDetailPlayAll">▶ 播放</button>
                                <div class="am-detail-title" id="amDetailTitle"></div>
                            </div>
                            <div class="am-cards-scroll" id="amDetailScroll"></div>
                        </div>
                    </div>
                </div>
            `;
            document.body.appendChild(app);

            // 绑定 DOM 引用
            this.dom.appRoot = app;
            this.dom.topBar = app.querySelector('#amTopBar');
            this.dom.tabGroup = app.querySelector('#amTabGroup');
            this.dom.refreshBtn = app.querySelector('#amRefreshBtn');
            this.dom.layoutBtn = app.querySelector('#amLayoutBtn');
            this.dom.searchBtn = app.querySelector('#amSearchBtn');
            this.dom.searchBar = app.querySelector('#amSearchBar');
            this.dom.searchBackBtn = app.querySelector('#amSearchBackBtn');
            this.dom.searchInput = app.querySelector('#amSearchInput');
            this.dom.searchClear = app.querySelector('#amSearchClear');
            this.dom.searchLayoutBtn = app.querySelector('#amSearchLayoutBtn');
            this.dom.searchScope = app.querySelector('#amSearchScope');
            this.dom.sidebar = app.querySelector('#amSidebar');
            this.dom.cardsScroll = app.querySelector('#amCardsScroll');
            this.dom.detailView = app.querySelector('#amDetailView');
            this.dom.detailBack = app.querySelector('#amDetailBack');
            this.dom.detailPlayAll = app.querySelector('#amDetailPlayAll');
            this.dom.detailTitle = app.querySelector('#amDetailTitle');
            this.dom.detailScroll = app.querySelector('#amDetailScroll');

            this.renderTabs();
            this.renderSearchScopes();
            this.bindEvents();
        },

        // 切换标签页
        switchTab(tabId) {
            if (this.currentTab === tabId && this.dom.detailView.style.display !== 'flex' && !this.isSearching) return;
            this.currentTab = tabId;
            this.activeCategoryIdx = 0;
            this.exitSearchMode();
            if (this.dom.tabGroup) {
                this.dom.tabGroup.querySelectorAll('.am-tab-btn').forEach(b => {
                    b.classList.toggle('active', b.dataset.tab === tabId);
                });
            }
            this.render();
            // 若无数据，自动从音源请求
            const curData = this.datasets[this.currentTab];
            if (!curData || !curData.categories || !curData.categories.length) {
                this.fetchTabData(this.currentTab, false);
            }
        },

        // 渲染顶部标签
        renderTabs() {
            const tabs = (this.provider && this.provider.tabs) || [{ id: 'home', label: '主页' }];
            this.dom.tabGroup.innerHTML = '';
            if (!this.currentTab && tabs.length > 0) {
                this.currentTab = tabs[0].id;
            }

            tabs.forEach(tab => {
                const btn = document.createElement('button');
                btn.className = 'am-tab-btn' + (tab.id === this.currentTab ? ' active' : '');
                btn.dataset.tab = tab.id;
                btn.innerText = tab.label;
                btn.onclick = () => {
                    this.switchTab(tab.id);
                };
                this.dom.tabGroup.appendChild(btn);
            });
        },

        // 渲染搜索范围胶囊按钮
        renderSearchScopes() {
            const scopes = (this.provider && this.provider.searchScopes) || [{ id: 'catalog', label: '全部', placeholder: '搜索音乐...' }];
            this.dom.searchScope.innerHTML = '';
            if (!this.currentSearchScope && scopes.length > 0) {
                this.currentSearchScope = scopes[0].id;
                this.dom.searchInput.placeholder = scopes[0].placeholder || '搜索音乐...';
            }

            scopes.forEach(scope => {
                const btn = document.createElement('button');
                btn.className = 'am-scope-btn' + (scope.id === this.currentSearchScope ? ' active' : '');
                btn.dataset.scope = scope.id;
                btn.innerText = scope.label;
                btn.title = `搜索 ${scope.label}`;
                btn.onclick = () => {
                    if (this.currentSearchScope === scope.id) return;
                    this.currentSearchScope = scope.id;
                    this.dom.searchScope.querySelectorAll('.am-scope-btn').forEach(b => {
                        b.classList.toggle('active', b.dataset.scope === scope.id);
                    });
                    this.dom.searchInput.placeholder = scope.placeholder || `搜索 ${scope.label}...`;
                    const q = this.dom.searchInput.value.trim();
                    if (q) {
                        this.performSearch(q, this.currentSearchScope);
                    } else {
                        this.renderSearchPrompt();
                    }
                };
                this.dom.searchScope.appendChild(btn);
            });
        },

        // 绑定交互事件
        bindEvents() {
            // 刷新按钮
            if (this.dom.refreshBtn) {
                this.dom.refreshBtn.onclick = () => {
                    this.fetchTabData(this.currentTab, true);
                };
            }

            // 单双栏布局切换
            const toggleLayout = () => {
                this.is2Col = !this.is2Col;
                this.applyLayout();
                try {
                    localStorage.setItem('airmuse_layout_2col', this.is2Col ? '1' : '0');
                } catch (_) {}
            };
            if (this.dom.layoutBtn) this.dom.layoutBtn.onclick = toggleLayout;
            if (this.dom.searchLayoutBtn) this.dom.searchLayoutBtn.onclick = toggleLayout;

            // 还原历史布局设定
            try {
                const saved = localStorage.getItem('airmuse_layout_2col');
                if (saved !== null) {
                    this.is2Col = (saved === '1');
                    this.applyLayout();
                }
            } catch (_) {}

            // 搜索交互
            if (this.dom.searchBtn) this.dom.searchBtn.onclick = () => this.enterSearchMode();
            if (this.dom.searchBackBtn) this.dom.searchBackBtn.onclick = () => this.exitSearchMode();

            if (this.dom.searchClear) {
                this.dom.searchClear.onclick = () => {
                    this.dom.searchInput.value = '';
                    this.dom.searchClear.style.display = 'none';
                    this.dom.searchInput.focus();
                    this.renderSearchPrompt();
                };
            }

            let searchTimer = null;
            if (this.dom.searchInput) {
                this.dom.searchInput.oninput = () => {
                    clearTimeout(searchTimer);
                    const q = this.dom.searchInput.value.trim();
                    this.dom.searchClear.style.display = this.dom.searchInput.value ? 'block' : 'none';
                    if (!q) {
                        this.renderSearchPrompt();
                        return;
                    }
                    searchTimer = setTimeout(() => {
                        this.performSearch(q, this.currentSearchScope);
                    }, 280);
                };

                this.dom.searchInput.onkeydown = (e) => {
                    if (e.key === 'Escape') {
                        this.exitSearchMode();
                    } else if (e.key === 'Enter') {
                        clearTimeout(searchTimer);
                        const q = this.dom.searchInput.value.trim();
                        if (q) this.performSearch(q, this.currentSearchScope);
                    }
                };
            }

            // 详情页返回与整张播放
            if (this.dom.detailBack) {
                this.dom.detailBack.onclick = () => {
                    this.dom.detailView.style.display = 'none';
                };
            }

            if (this.dom.detailPlayAll) {
                this.dom.detailPlayAll.onclick = async () => {
                    if (!this.currentDetailItem || !this.provider) return;
                    await this.provider.playCollection(this.currentDetailItem);
                };
            }

            // 触底无限滚动加载
            if (this.dom.cardsScroll) {
                this.dom.cardsScroll.onscroll = () => this.handleScroll();
            }
        },

        // 应用单双栏样式
        applyLayout() {
            this.dom.cardsScroll.classList.toggle('grid-2col', this.is2Col);
            const icon = this.is2Col ? '☰' : '⚏';
            const tip = this.is2Col ? '切换至单栏列表' : '切换至双栏网格';
            if (this.dom.layoutBtn) {
                this.dom.layoutBtn.innerText = icon;
                this.dom.layoutBtn.title = tip;
                this.dom.layoutBtn.classList.toggle('active', this.is2Col);
            }
            if (this.dom.searchLayoutBtn) {
                this.dom.searchLayoutBtn.innerText = icon;
                this.dom.searchLayoutBtn.title = tip;
                this.dom.searchLayoutBtn.classList.toggle('active', this.is2Col);
            }
        },

        // 进入搜索模式
        enterSearchMode() {
            this.isSearching = true;
            this.dom.topBar.style.display = 'none';
            this.dom.searchBar.style.display = 'flex';
            this.dom.detailView.style.display = 'none';
            this.dom.searchInput.focus();

            const query = this.dom.searchInput.value.trim();
            if (query) {
                this.performSearch(query, this.currentSearchScope);
            } else {
                this.renderSearchPrompt();
            }
        },

        // 退出搜索模式
        exitSearchMode() {
            this.isSearching = false;
            this.currentSearchCategories = [];
            this.activeSearchCategoryIdx = 0;
            this.dom.searchBar.style.display = 'none';
            this.dom.topBar.style.display = 'flex';
            this.dom.detailView.style.display = 'none';
            this.dom.searchInput.value = '';
            this.dom.searchClear.style.display = 'none';
            this.render();
        },

        // 搜索初始空提示
        renderSearchPrompt() {
            this.dom.sidebar.innerHTML = '<div class="am-empty-tip" style="padding: 10px 4px; font-size: 10px;">输入搜索</div>';
            const scopeObj = this.provider?.searchScopes?.find(s => s.id === this.currentSearchScope);
            const scopeLabel = scopeObj ? scopeObj.label : '曲库';
            this.dom.cardsScroll.innerHTML = `
                <div class="am-empty-tip" style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100%; gap: 6px;">
                    <div style="font-size: 24px; opacity: 0.8;">🔍</div>
                    <div style="font-size: 11px; color: #d4d4d8; font-weight: 500;">搜索 ${escapeHtml(scopeLabel)}</div>
                    <div style="font-size: 9.5px; color: #71717a;">在上方搜索框输入关键词</div>
                </div>
            `;
        },

        // 执行搜索
        async performSearch(query, scope) {
            if (!query) {
                this.renderSearchPrompt();
                return;
            }
            this.isSearching = true;
            this.dom.detailView.style.display = 'none';
            this.dom.sidebar.innerHTML = '<div class="am-empty-tip" style="padding: 10px 4px; font-size: 10px;">搜索中...</div>';
            this.dom.cardsScroll.innerHTML = '<div class="am-empty-tip">正在搜索...</div>';

            try {
                const categories = await this.provider.search(query, scope);
                this.renderSearchResults(categories || [], query, scope);
            } catch (_) {
                this.dom.sidebar.innerHTML = '<div class="am-empty-tip" style="padding: 10px 4px; font-size: 10px;">错误</div>';
                this.dom.cardsScroll.innerHTML = '<div class="am-empty-tip">搜索遇到网络问题，请重试</div>';
            }
        },

        // 渲染搜索结果
        renderSearchResults(categories, query, scope) {
            this.currentSearchCategories = categories;
            this.activeSearchCategoryIdx = 0;

            if (!categories.length) {
                this.dom.sidebar.innerHTML = '<div class="am-empty-tip" style="padding: 10px 4px; font-size: 10px;">无结果</div>';
                const scopeObj = this.provider?.searchScopes?.find(s => s.id === scope);
                const scopeName = scopeObj ? scopeObj.label : '曲库';
                this.dom.cardsScroll.innerHTML = `
                    <div class="am-empty-tip" style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100%; gap: 6px;">
                        <div style="font-size: 24px; opacity: 0.8;">∅</div>
                        <div style="font-size: 11px; color: #d4d4d8; font-weight: 500;">未找到相关内容</div>
                        <div style="font-size: 9.5px; color: #71717a;">在 ${escapeHtml(scopeName)} 中未找到与 "${escapeHtml(query)}" 匹配的结果</div>
                    </div>
                `;
                return;
            }

            this.renderSearchSidebarAndCards();
        },

        renderSearchSidebarAndCards() {
            this.dom.sidebar.innerHTML = '';
            if (!this.currentSearchCategories || !this.currentSearchCategories.length) {
                this.dom.sidebar.innerHTML = '<div class="am-empty-tip" style="padding: 10px 4px; font-size: 10px;">无结果</div>';
                return;
            }

            if (this.activeSearchCategoryIdx >= this.currentSearchCategories.length) {
                this.activeSearchCategoryIdx = 0;
            }

            this.currentSearchCategories.forEach((cat, idx) => {
                const item = document.createElement('div');
                item.className = 'am-cat-item' + (idx === this.activeSearchCategoryIdx ? ' active' : '');
                item.innerText = cat.title;
                item.title = cat.title;
                item.onclick = () => {
                    this.activeSearchCategoryIdx = idx;
                    this.dom.sidebar.querySelectorAll('.am-cat-item').forEach((b, i) => b.classList.toggle('active', i === idx));
                    this.dom.detailView.style.display = 'none';
                    this.renderCardsForCategory(cat);
                };
                this.dom.sidebar.appendChild(item);
            });

            const cat = this.currentSearchCategories[this.activeSearchCategoryIdx];
            if (cat) {
                this.renderCardsForCategory(cat);
            }
        },

        // 加载初始缓存数据
        async loadInitialData() {
            if (!this.provider) return;
            try {
                const cached = await this.provider.loadInitialData();
                if (cached && typeof cached === 'object') {
                    this.datasets = cached;
                    this.render();
                }
            } catch (_) {}

            // 无论是否有缓存，后台发起一次保鲜抓取
            if (this.currentTab) {
                this.fetchTabData(this.currentTab, false);
            }
        },

        // 请求 Tab 数据
        async fetchTabData(tabId, forceRefresh = false) {
            if (!this.provider) return;
            try {
                const categories = await this.provider.fetchTabData(tabId, forceRefresh);
                if (categories && Array.isArray(categories)) {
                    this.datasets[tabId] = { categories };
                    if (this.currentTab === tabId && !this.isSearching) {
                        this.render();
                    }
                }
            } catch (err) {
                console.warn('[AirMuseUI] fetchTabData error:', err);
            }
        },

        // 全局主视图渲染
        render() {
            if (this.isSearching) {
                if (!this.currentSearchCategories || !this.currentSearchCategories.length) {
                    this.renderSearchPrompt();
                    return;
                }
                this.renderSearchSidebarAndCards();
                return;
            }

            const curData = this.datasets[this.currentTab] || { categories: [] };
            this.dom.sidebar.innerHTML = '';

            if (!curData.categories || !curData.categories.length) {
                this.dom.cardsScroll.innerHTML = `<div class="am-empty-tip">正在载入 ${escapeHtml(this.provider?.name || '音乐')} 数据...</div>`;
                return;
            }

            if (this.activeCategoryIdx >= curData.categories.length) {
                this.activeCategoryIdx = 0;
            }

            curData.categories.forEach((cat, idx) => {
                const el = document.createElement('div');
                el.className = 'am-cat-item' + (idx === this.activeCategoryIdx ? ' active' : '');
                el.title = cat.title;

                const span = document.createElement('span');
                span.innerText = cat.title;
                span.style.overflow = 'hidden';
                span.style.textOverflow = 'ellipsis';
                el.appendChild(span);

                el.onclick = () => {
                    this.activeCategoryIdx = idx;
                    this.isSearching = false;
                    this.dom.detailView.style.display = 'none';
                    Array.from(this.dom.sidebar.children).forEach((child, i) => {
                        child.className = 'am-cat-item' + (i === this.activeCategoryIdx ? ' active' : '');
                    });
                    this.renderContent();
                };
                this.dom.sidebar.appendChild(el);
            });

            this.renderContent();
        },

        renderContent() {
            const curData = this.datasets[this.currentTab] || { categories: [] };
            const cat = curData.categories[this.activeCategoryIdx];
            if (!cat) return;
            this.renderCardsForCategory(cat);
        },

        // 创建单条目卡片
        createCardElement(item, cat, itemIdx) {
            const typeKey = (item.type || 'default').toLowerCase();
            const typeLabel = DEFAULT_TYPE_NAMES[typeKey] || item.type || '条目';
            const tagClass = 'type-' + (DEFAULT_TYPE_NAMES[typeKey] ? typeKey : 'default');

            const fallbackImg = (typeKey === 'artist')
                ? "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='38' height='38' viewBox='0 0 38 38'%3E%3Crect width='38' height='38' fill='%2327272a'/%3E%3Ctext x='50%25' y='50%25' dominant-baseline='middle' text-anchor='middle' font-family='sans-serif' font-size='16' fill='%2371717a'%3E👤%3C/text%3E%3C/svg%3E"
                : "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='38' height='38' viewBox='0 0 38 38'%3E%3Crect width='38' height='38' fill='%2327272a'/%3E%3Ctext x='50%25' y='50%25' dominant-baseline='middle' text-anchor='middle' font-family='sans-serif' font-size='16' fill='%2371717a'%3E🎵%3C/text%3E%3C/svg%3E";

            const card = document.createElement('div');
            card.className = 'am-item-card';

            const thumbWrap = document.createElement('div');
            thumbWrap.className = 'am-thumb-wrap';

            const img = document.createElement('img');
            img.className = 'am-item-thumb';
            img.src = item.artworkUrl || fallbackImg;
            img.loading = 'lazy';
            img.onerror = function () { this.src = fallbackImg; };
            thumbWrap.appendChild(img);

            const badge = document.createElement('span');
            badge.className = 'am-cover-badge ' + tagClass;
            badge.innerText = typeLabel;
            thumbWrap.appendChild(badge);

            card.appendChild(thumbWrap);

            const body = document.createElement('div');
            body.className = 'am-item-body';

            const title = document.createElement('div');
            title.className = 'am-item-title';
            title.innerText = item.title || '未知名称';
            title.title = item.title || '';
            body.appendChild(title);

            const sub = document.createElement('div');
            sub.className = 'am-item-sub';
            sub.innerText = item.subtitle || '';
            sub.title = item.subtitle || '';
            body.appendChild(sub);

            card.appendChild(body);

            card.onclick = () => {
                this.handleItemClick(item, cat, itemIdx);
            };

            return card;
        },

        renderCardsForCategory(cat) {
            this.dom.cardsScroll.innerHTML = '';
            if (!cat.items || !cat.items.length) {
                this.dom.cardsScroll.innerHTML = '<div class="am-empty-tip">该分类暂无条目</div>';
                return;
            }

            cat.items.forEach((item, itemIdx) => {
                const card = this.createCardElement(item, cat, itemIdx);
                this.dom.cardsScroll.appendChild(card);
            });

            this.dom.cardsScroll.scrollTop = 0;
        },

        // 点击条目处理：单曲/电台直接播放，歌单/专辑/艺人展开详情抽屉
        async handleItemClick(item, cat, itemIdx) {
            if (!this.provider) return;

            if (item.type === 'station' || item.type === 'song' || item.type === 'fav-song') {
                await this.provider.playItem(item, cat, itemIdx);
                return;
            }

            this.openDetailView(item);
        },

        // 展开详情页
        async openDetailView(item) {
            this.currentDetailItem = item;
            this.dom.detailTitle.innerText = item.title;
            this.dom.detailScroll.innerHTML = '<div class="am-empty-tip">正在载入曲目列表...</div>';
            this.dom.detailView.style.display = 'flex';

            if (!this.provider) return;
            try {
                const tracks = await this.provider.loadDetail(item);
                this.dom.detailScroll.innerHTML = '';
                if (!tracks || !tracks.length) {
                    this.dom.detailScroll.innerHTML = '<div class="am-empty-tip">暂无可播放曲目</div>';
                    return;
                }

                tracks.forEach((t, idx) => {
                    const row = document.createElement('div');
                    row.className = 'am-track-row';

                    const idxEl = document.createElement('div');
                    idxEl.className = 'am-track-idx';
                    idxEl.innerText = idx + 1;
                    row.appendChild(idxEl);

                    const body = document.createElement('div');
                    body.className = 'am-track-body';

                    const nameEl = document.createElement('div');
                    nameEl.className = 'am-track-name';
                    nameEl.innerText = t.name || t.title || '未知单曲';
                    body.appendChild(nameEl);

                    const artistEl = document.createElement('div');
                    artistEl.className = 'am-track-artist';
                    artistEl.innerText = t.artistName || t.subtitle || '';
                    body.appendChild(artistEl);

                    row.appendChild(body);

                    if (t.durationMs) {
                        const durEl = document.createElement('div');
                        durEl.className = 'am-track-dur';
                        durEl.innerText = formatDuration(t.durationMs);
                        row.appendChild(durEl);
                    }

                    row.onclick = async () => {
                        this.dom.detailScroll.querySelectorAll('.am-track-row.active').forEach(r => r.classList.remove('active'));
                        row.classList.add('active');
                        await this.provider.playItem(t, item, idx);
                    };

                    this.dom.detailScroll.appendChild(row);
                });
            } catch (_) {
                this.dom.detailScroll.innerHTML = '<div class="am-empty-tip">曲目拉取失败</div>';
            }
        },

        // 触底无限滚动
        async handleScroll() {
            if (this.isLoadingMore || !this.provider) return;
            const curData = this.datasets[this.currentTab] || { categories: [] };
            const cat = this.isSearching
                ? (this.currentSearchCategories ? this.currentSearchCategories[this.activeSearchCategoryIdx] : null)
                : curData.categories[this.activeCategoryIdx];

            if (!cat || !cat.nextUrl) return;

            const threshold = 50;
            if (this.dom.cardsScroll.scrollTop + this.dom.cardsScroll.clientHeight >= this.dom.cardsScroll.scrollHeight - threshold) {
                this.isLoadingMore = true;

                const spinner = document.createElement('div');
                spinner.className = 'am-loading-more';
                spinner.id = 'amLoadingMoreIndicator';
                spinner.innerText = '正在加载更多...';
                this.dom.cardsScroll.appendChild(spinner);

                try {
                    const newItems = await this.provider.loadMore(cat, this.currentTab, this.isSearching, this.currentSearchScope);
                    if (newItems && newItems.length) {
                        const startIdx = cat.items.length;
                        cat.items.push(...newItems);
                        newItems.forEach((item, idx) => {
                            const card = this.createCardElement(item, cat, startIdx + idx);
                            this.dom.cardsScroll.insertBefore(card, spinner);
                        });
                    }
                } catch (_) {
                } finally {
                    spinner.remove();
                    this.isLoadingMore = false;
                }
            }
        },

        // 桥接原生与音源事件
        bindBridge() {
            if (this.provider) {
                this.provider.onNowPlayingChange((np) => {
                    if (window.chrome && window.chrome.webview && np) {
                        window.chrome.webview.postMessage(JSON.stringify({
                            type: 'nowPlaying',
                            ...np
                        }));
                    }
                    if (this.dom.detailScroll && np && np.title) {
                        const rows = this.dom.detailScroll.querySelectorAll('.am-track-row');
                        rows.forEach(r => {
                            const nameEl = r.querySelector('.am-track-name');
                            if (nameEl && nameEl.innerText === np.title) {
                                r.classList.add('active');
                            } else {
                                r.classList.remove('active');
                            }
                        });
                    }
                });

                this.provider.onUserChange((u) => {
                    if (window.chrome && window.chrome.webview && u) {
                        window.chrome.webview.postMessage(JSON.stringify({
                            type: 'userStatus',
                            userName: u
                        }));
                    }
                });
            }

            // 原生宿主反射接口
            window.__airmusePlayTrack = (kind, collectionId, trackIdx, trackId) => {
                if (this.provider && typeof this.provider.playByNative === 'function') {
                    this.provider.playByNative(kind, collectionId, trackIdx, trackId);
                }
            };

            window.__airmusePlayStation = (stationId) => {
                if (this.provider && typeof this.provider.playStationByNative === 'function') {
                    this.provider.playStationByNative(stationId);
                }
            };

            window.__airmuseJumpToPlaying = () => {
                if (this.provider && typeof this.provider.jumpToPlaying === 'function') {
                    this.provider.jumpToPlaying();
                }
            };
        },

        // SPA 保活：监听宿主页面 DOM 变动与路由替换，确保 `#airmuse-app` 瞬间恢复，绝不黑屏
        startSPAKeeper() {
            if (this._spaObserver) {
                try { this._spaObserver.disconnect(); } catch (_) {}
            }

            const ensureMounted = () => {
                if (!document.body) return;
                const existing = document.getElementById('airmuse-app');
                if (!existing) {
                    if (this.dom.appRoot) {
                        // 节点仍然保存在内存中，直接重新挂载到 body，保留所有事件和渲染状态
                        document.body.appendChild(this.dom.appRoot);
                    } else {
                        // 全新初始化脚手架
                        this.mountScaffold();
                        this.render();
                    }
                }
            };

            try {
                this._spaObserver = new MutationObserver(() => {
                    ensureMounted();
                });
                if (document.body) {
                    this._spaObserver.observe(document.body, { childList: true });
                }
                if (document.documentElement) {
                    this._spaObserver.observe(document.documentElement, { childList: true });
                }
            } catch (_) {}

            // 双重保障：低频心跳检测 (250ms) 确保在任何极端 SPA 清理或导航下万无一失
            if (this._spaKeeperTimer) clearInterval(this._spaKeeperTimer);
            this._spaKeeperTimer = setInterval(ensureMounted, 250);
        }
    };

    global.AirMuseUI = AirMuseUI;

})(typeof window !== 'undefined' ? window : this);


            // ── 2. Apple Music 音源适配器 (AppleMusicProvider) ──
            /**
 * apple_music_provider.js
 * AirMuse Apple Music 专属数据适配器 (AppleMusicProvider)
 *
 * 职责：
 * 1. 实现 IDataProvider 规范，提供 Apple Music 的 Tab 配置、搜索范围配置
 * 2. 直连 Apple Music Amp-API (Amp-API Direct Fetch)，支持官方 Token 嗅探与降级
 * 3. 实现双域检索 (Catalog 全球曲库 + Library 个人资料库)、高清封面写真解析、触底分页
 * 4. 驱动 MusicKit.getInstance() 实现单曲、电台、整张歌单/专辑播放
 * 5. 封装 IndexedDB 极速缓存引擎 (替代 localStorage)
 */

(function (global) {
    const BaseClass = (global.AirMuseUI && global.AirMuseUI.IDataProvider) ? global.AirMuseUI.IDataProvider : class {};

    // ── 0. IndexedDB 异步本地缓存 ──────────────────────────────────────────
    const DB_NAME = 'airmuse_music_db';
    const DB_VERSION = 2;
    const STORE_NAME = 'catalog_cache';
    const CACHE_KEY = 'airmuse_catalog_v3';

    function getDB() {
        return new Promise((resolve, reject) => {
            const req = indexedDB.open(DB_NAME, DB_VERSION);
            req.onupgradeneeded = (e) => {
                const db = e.target.result;
                if (!db.objectStoreNames.contains(STORE_NAME)) {
                    db.createObjectStore(STORE_NAME);
                }
            };
            req.onsuccess = () => resolve(req.result);
            req.onerror = () => reject(req.error);
        });
    }

    async function idbGet(key) {
        try {
            const db = await getDB();
            return new Promise((resolve) => {
                const tx = db.transaction(STORE_NAME, 'readonly');
                const req = tx.objectStore(STORE_NAME).get(key);
                req.onsuccess = () => resolve(req.result);
                req.onerror = () => resolve(null);
            });
        } catch (_) {
            return null;
        }
    }

    async function idbSet(key, val) {
        try {
            const db = await getDB();
            return new Promise((resolve) => {
                const tx = db.transaction(STORE_NAME, 'readwrite');
                const req = tx.objectStore(STORE_NAME).put(val, key);
                req.onsuccess = () => resolve(true);
                req.onerror = () => resolve(false);
            });
        } catch (_) {
            return false;
        }
    }

    // ── 1. 令牌与 API 基础配置 ─────────────────────────────────────────────
    const FALLBACK_DEV_TOKEN = 'eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6IldlYlBsYXlLaWQifQ.eyJpc3MiOiJBTVBXZWJQbGF5IiwiaWF0IjoxNzkzOTAwNzA4LCJleHAiOjE3OTk5NDg3MDgsInJvb3RfaHR0cHNfb3JpZ2luIjpbImFwcGxlLmNvbSJdfQ.7L-PYJHjO8PpFdhKS-OSkf_snyFvg5cq-JDERUs_N_UcUX9Vk0kf1WLatgDeEvhB_Arg1b5Tl-99G1v6hUwH0A';
    const FALLBACK_USER_TOKEN = '0.AhLguOql2yDcoV5g/aTy/eSDkhhH62HGfnutGQVywp2Sl7wUjfwH+robO39OcpfAC+MmQfsjqUytTfT9WoY8ueQYrYCU1bscJNMOHwErJDvbhYd1RlZQH8xHF/ArXIG5Gq3hX48An4eyLx01IwI+RLsbCG7QTR7dnAmPoEJYQSuYfzW057zsIvwXlt/XrviGeunNQ4BDXL0Fy5YRmb/ufLjQOHxu96gA/SjjMbNhw67Eri3B2g==';

    function formatArtworkUrl(artworkObj, size = 160) {
        if (!artworkObj?.url) return null;
        return artworkObj.url
            .replace('{w}x{h}', `${size}x${size}`)
            .replace('{c}', 'bb')
            .replace('cc.{f}', 'bb.webp')
            .replace('{f}', 'webp');
    }

    function makeCategory(id, title, items, nextUrl = null) {
        return { id, title, items, nextUrl };
    }

    // ── 2. 数据模型映射器 (Mappers) ────────────────────────────────────────
    function resolveResourceItem(ref, resources) {
        const item = resources?.[ref.type]?.[ref.id];
        if (!item) return null;
        let target = item;
        if (item.relationships?.contents?.data?.[0]) {
            const tRef = item.relationships.contents.data[0];
            target = resources?.[tRef.type]?.[tRef.id] || item;
        }
        const attr = target.attributes || item.attributes || {};
        const typeMap = {
            songs: 'song',
            playlists: 'playlist',
            'library-playlists': 'playlist',
            stations: 'station',
            albums: 'album',
            'library-albums': 'album'
        };
        const type = typeMap[target.type || ref.type] || (ref.type?.includes('editorial') ? 'editorial' : 'item');
        return {
            id: target.id || item.id,
            title: attr.name || attr.title || item.attributes?.designBadge || '推荐精选',
            subtitle: attr.artistName || attr.curatorName || (attr.description?.standard ? attr.description.standard.slice(0, 36) : 'Apple Music'),
            eyebrow: null,
            type,
            artworkUrl: formatArtworkUrl(attr.artwork || attr.editorialArtwork, 160),
            linkUrl: attr.url || `https://music.apple.com/cn/${type}/${target.id || item.id}`,
            durationMs: attr.durationInMillis || null,
        };
    }

    function mapCatalogArtist(a) {
        const attr = a.attributes || {};
        return {
            id: a.id,
            title: attr.name || '未知艺人',
            subtitle: attr.genreNames?.[0] || '艺人',
            eyebrow: null,
            type: 'artist',
            artworkUrl: formatArtworkUrl(attr.artwork, 160),
            linkUrl: attr.url || `https://music.apple.com/cn/artist/${a.id}`,
            isLibrary: false
        };
    }

    function mapCatalogAlbum(a) {
        const attr = a.attributes || {};
        return {
            id: a.id,
            title: attr.name || '未知专辑',
            subtitle: attr.artistName || 'Apple Music',
            eyebrow: null,
            type: 'album',
            artworkUrl: formatArtworkUrl(attr.artwork, 160),
            linkUrl: attr.url || `https://music.apple.com/cn/album/${a.id}`,
            isLibrary: false
        };
    }

    function mapSongItem(track, isFav = false) {
        const attr = track.attributes || {};
        const catAttr = track.relationships?.catalog?.data?.[0]?.attributes;
        const sub = [attr.artistName, attr.albumName].filter(Boolean).join(' · ');
        const rawArtwork = attr.artwork || catAttr?.artwork;
        const isLib = track.type?.includes('library') || (typeof track.id === 'string' && track.id.startsWith('i.'));
        return {
            id: track.id,
            title: attr.name || '未知单曲',
            subtitle: sub || 'Apple Music',
            eyebrow: null,
            type: isFav ? 'fav-song' : 'song',
            artworkUrl: formatArtworkUrl(rawArtwork, 160),
            linkUrl: attr.url || `https://music.apple.com/cn/song/${attr.playParams?.catalogId || track.id}`,
            durationMs: attr.durationInMillis || null,
            isLibrary: isLib
        };
    }

    function mapLibraryItem(item, defaultType = 'item') {
        const attr = item.attributes || {};
        const catItem = item.relationships?.catalog?.data?.[0];
        const catAttr = catItem?.attributes;
        const type = item.type === 'library-albums' ? 'album' : (item.type === 'library-playlists' ? 'playlist' : (item.type === 'library-artists' ? 'artist' : defaultType));

        let sub = '';
        if (attr.artistName) {
            sub = attr.trackCount ? `${attr.artistName} (${attr.trackCount} 首)` : attr.artistName;
        } else if (type === 'artist') {
            sub = catAttr?.genreNames?.[0] || '艺人';
        } else {
            sub = '资料库';
        }

        const rawArtwork = attr.artwork || catAttr?.artwork;

        return {
            id: item.id,
            title: attr.name || catAttr?.name || '未知名称',
            subtitle: sub,
            eyebrow: null,
            type,
            artworkUrl: formatArtworkUrl(rawArtwork, 160),
            linkUrl: `https://music.apple.com/cn/${type}/${item.id}`,
            isLibrary: true
        };
    }

    function mapPlaylistItem(pl) {
        const attr = pl.attributes || {};
        const catAttr = pl.relationships?.catalog?.data?.[0]?.attributes;
        const canEdit = !!attr.canEdit;
        const type = canEdit ? 'user-playlist' : 'fav-playlist';

        let sub = '';
        if (attr.curatorName && attr.curatorName !== 'Apple Music') {
            sub = attr.curatorName;
        } else if (attr.description?.standard) {
            sub = attr.description.standard.slice(0, 36);
        } else if (attr.trackCount) {
            sub = `${attr.trackCount} 首单曲`;
        } else {
            sub = 'Apple Music';
        }

        const rawArtwork = attr.artwork || catAttr?.artwork;
        const isLib = pl.type?.includes('library') || (typeof pl.id === 'string' && pl.id.startsWith('p.'));

        return {
            id: pl.id,
            title: attr.name || '未命名歌单',
            subtitle: sub,
            eyebrow: null,
            type,
            artworkUrl: formatArtworkUrl(rawArtwork, 160),
            linkUrl: attr.url || `https://music.apple.com/cn/playlist/${pl.id}`,
            canEdit,
            isLibrary: isLib
        };
    }

    // ── 3. AppleMusicProvider 类实现 ──────────────────────────────────────
    class AppleMusicProvider extends BaseClass {
        constructor() {
            super();
            this._cachedDatasets = null;
            this._nowPlayingCallback = null;
            this._userCallback = null;
            this._initCookie();
            this._startMonitor();
        }

        get id() { return 'apple-music'; }
        get name() { return 'Apple Music'; }

        get tabs() {
            return [
                { id: 'home', label: '主页' },
                { id: 'browse', label: '新发现' },
                { id: 'radio', label: '广播' },
                { id: 'library', label: '资料库' },
                { id: 'playlists', label: '歌单' }
            ];
        }

        get searchScopes() {
            return [
                { id: 'catalog', label: 'Apple Music', placeholder: '在 Apple Music 中搜索...' },
                { id: 'library', label: '资料库', placeholder: '在资料库中搜索...' }
            ];
        }

        _initCookie() {
            try {
                const uToken = this.getUserToken();
                if (uToken && !document.cookie.includes('media-user-token')) {
                    document.cookie = `media-user-token=${uToken}; domain=.music.apple.com; path=/; max-age=31536000; SameSite=Lax`;
                }
            } catch (_) {}
        }

        getDeveloperToken() {
            try {
                const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk && mk.developerToken) return mk.developerToken;
                const m = document.documentElement.innerHTML.match(/eyJ0eXAiOiJKV1Qi[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+/);
                if (m && m[0]) return m[0];
            } catch (_) {}
            return FALLBACK_DEV_TOKEN;
        }

        getUserToken() {
            try {
                const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk && mk.musicUserToken) return mk.musicUserToken;
                const m = document.cookie.match(/(?:^|;\s*)media-user-token=([^;]+)/);
                if (m && m[1]) return decodeURIComponent(m[1]);
            } catch (_) {}
            return FALLBACK_USER_TOKEN;
        }

        async fetchAmp(url, needAuth = false) {
            const devToken = this.getDeveloperToken();
            const userToken = this.getUserToken();
            const fullUrl = url.indexOf('http') === 0 ? url : ('https://amp-api.music.apple.com' + url);

            const headers = {
                'authorization': `Bearer ${devToken}`,
                'origin': 'https://music.apple.com',
                'referer': 'https://music.apple.com/'
            };
            if (needAuth && userToken) {
                headers['music-user-token'] = userToken;
            }

            try {
                const res = await fetch(fullUrl, { headers });
                if (res.ok) return await res.json();
            } catch (_) {}
            return null;
        }

        async loadInitialData() {
            const cached = await idbGet(CACHE_KEY);
            if (cached && cached.home && cached.home.categories && cached.home.categories.length) {
                this._cachedDatasets = cached;
                return cached;
            }
            return null;
        }

        async fetchTabData(tabId, forceRefresh = false) {
            const devToken = this.getDeveloperToken();
            const userToken = this.getUserToken();
            if (!devToken) return [];

            const defaultHeaders = {
                'authorization': `Bearer ${devToken}`,
                'origin': 'https://music.apple.com',
                'referer': 'https://music.apple.com/'
            };
            const userHeaders = userToken ? { ...defaultHeaders, 'music-user-token': userToken } : defaultHeaders;

            const ENDPOINTS = [
                { key: 'home', url: 'https://amp-api.music.apple.com/v1/me/recommendations?art%5Burl%5D=f&displayFilter%5Bkind%5D=MusicCircleCoverShelf%2CMusicConcertsEmptyShelf%2CMusicCoverGrid%2CMusicCoverShelf%2CMusicNotesHeroShelf%2CMusicSocialCardShelf%2CMusicSuperHeroShelf&extend=editorialArtwork%2CeditorialVideo%2CplainEditorialCard%2CplainEditorialNotes&extend%5Bplaylists%5D=artistNames&extend%5Bstations%5D=airTime%2CsupportsAirTimeUpdates&fields%5Bartists%5D=name%2Cartwork%2Curl&format%5Bresources%5D=map&include%5Balbums%5D=artists&include%5Blibrary-playlists%5D=catalog&include%5Bpersonal-recommendation%5D=primary-content&include%5Bstations%5D=radio-show&l=zh-Hans-CN&meta%5Bstations%5D=inflectionPoints&name=listen-now&omit%5Bresource%5D=autos&platform=web&timezone=%2B08%3A00&types=activities%2Calbums%2Capple-curators%2Cartists%2Cconcerts%2Ccurators%2Ceditorial-items%2Clibrary-albums%2Clibrary-playlists%2Cmusic-movies%2Cmusic-videos%2Cplaylists%2Csocial-profiles%2Csocial-upsells%2Csongs%2Cstations%2Ctv-episodes%2Ctv-shows%2Cuploaded-audios%2Cuploaded-videos&with=friendsMix%2Clibrary%2Csocial', headers: userHeaders },
                { key: 'browse', url: 'https://amp-api-edge.music.apple.com/v1/editorial/cn/groupings?art[url]=c,f&format[resources]=map&include[albums]=artists&include[music-videos]=artists&include[songs]=artists&include[stations]=events,radio-show&l=zh-Hans-CN&name=music&platform=web&tabs=subscriber', headers: defaultHeaders },
                { key: 'radio', url: 'https://amp-api-edge.music.apple.com/v1/editorial/cn/groupings?art[url]=c,f&format[resources]=map&include[albums]=artists&include[music-videos]=artists&include[songs]=artists&include[stations]=events,radio-show&l=zh-Hans-CN&name=radio&platform=web&tabs=subscriber', headers: defaultHeaders },
                { key: 'libRecent', url: 'https://amp-api.music.apple.com/v1/me/library/recently-added?art[url]=f&limit=25&l=zh-Hans-CN&platform=web', headers: userHeaders },
                { key: 'libAlbums', url: 'https://amp-api.music.apple.com/v1/me/library/albums?art[url]=f&limit=50&l=zh-Hans-CN&platform=web', headers: userHeaders },
                { key: 'libArtists', url: 'https://amp-api.music.apple.com/v1/me/library/artists?include=catalog&art[url]=f&limit=50&l=zh-Hans-CN&platform=web', headers: userHeaders },
                { key: 'libFav', url: 'https://amp-api.music.apple.com/v1/me/library/playlists/p.MLUk3bdrQ?art[url]=f&include=tracks&l=zh-Hans-CN&platform=web', headers: userHeaders },
                { key: 'libSongs', url: 'https://amp-api.music.apple.com/v1/me/library/songs?art[url]=f&limit=100&l=zh-Hans-CN&platform=web', headers: userHeaders },
                { key: 'playlists', url: 'https://amp-api.music.apple.com/v1/me/library/playlists?art[url]=f&include=catalog&limit=100&l=zh-Hans-CN&platform=web', headers: userHeaders },
                { key: 'madeForYou', url: 'https://amp-api.music.apple.com/v1/me/library/playlists?sort=type&filter[featured]=made-for-you&include[library-playlists]=catalog&fields[library-playlists]=artwork,dateAdded,name,playParams&l=zh-Hans-CN&platform=web', headers: userHeaders },
            ];

            try {
                const responses = await Promise.all(
                    ENDPOINTS.map(ep => fetch(ep.url, { headers: ep.headers }).then(r => r.ok ? r.json() : {}).catch(() => ({})))
                );
                const resMap = Object.fromEntries(ENDPOINTS.map((ep, idx) => [ep.key, responses[idx]]));

                // 1. 主页
                const homeCats = (resMap.home.data || []).reduce((acc, d, idx) => {
                    const rec = resMap.home.resources?.['personal-recommendation']?.[d.id];
                    if (!rec) return acc;
                    const title = rec.attributes?.title?.stringForDisplay || rec.attributes?.title?.text || rec.attributes?.name || `推荐板块 ${idx + 1}`;
                    const items = (rec.relationships?.contents?.data || []).map(ref => resolveResourceItem(ref, resMap.home.resources)).filter(Boolean);
                    if (items.length) acc.push(makeCategory(`section-${idx + 1}`, title, items));
                    return acc;
                }, []);

                // 2. 新发现 & 广播
                function parseEditorial(json) {
                    const grp = json.resources?.groupings?.[json.data?.[0]?.id];
                    const tab = json.resources?.['editorial-elements']?.[grp?.relationships?.tabs?.data?.[0]?.id];
                    return (tab?.relationships?.children?.data || []).reduce((acc, childRef, idx) => {
                        const child = json.resources?.[childRef.type]?.[childRef.id];
                        if (!child) return acc;
                        const title = child.attributes?.title?.stringForDisplay || child.attributes?.title?.text || child.attributes?.name || (idx === 0 ? '精品推荐' : null);
                        if (!title) return acc;
                        const sourceList = child.relationships?.children?.data || child.relationships?.contents?.data || [];
                        const items = sourceList.map(ref => resolveResourceItem(ref, json.resources)).filter(Boolean);
                        if (items.length) acc.push(makeCategory(`section-${idx + 1}`, title, items));
                        return acc;
                    }, []);
                }
                const browseCats = parseEditorial(resMap.browse);
                const radioCats = parseEditorial(resMap.radio);

                // 3. 资料库
                const libCats = [];
                const recentItems = (resMap.libRecent.data || []).map(item => mapLibraryItem(item, 'item'));
                if (recentItems.length) libCats.push(makeCategory('lib-recent', '最近添加', recentItems, resMap.libRecent.next || null));

                const favTracks = resMap.libFav.data?.[0]?.relationships?.tracks?.data || [];
                if (favTracks.length) libCats.push(makeCategory('lib-fav', '喜爱歌曲', favTracks.map(t => mapSongItem(t, true))));

                const albumItems = (resMap.libAlbums.data || []).map(item => mapLibraryItem(item, 'album'));
                if (albumItems.length) libCats.push(makeCategory('lib-albums', '专辑', albumItems, resMap.libAlbums.next || null));

                const artistItems = (resMap.libArtists.data || []).map(item => mapLibraryItem(item, 'artist'));
                if (artistItems.length) libCats.push(makeCategory('lib-artists', '艺人', artistItems, resMap.libArtists.next || null));

                const songItems = (resMap.libSongs.data || []).map(t => mapSongItem(t, false));
                if (songItems.length) libCats.push(makeCategory('lib-songs', '已存单曲', songItems, resMap.libSongs.next || null));

                // 4. 歌单
                const plCats = [];
                const rawPlaylists = resMap.playlists.data || [];
                const userPlaylists = [];
                const favPlaylists = [];

                rawPlaylists.forEach(p => {
                    const item = mapPlaylistItem(p);
                    if (p.attributes?.canEdit) userPlaylists.push(item);
                    else favPlaylists.push(item);
                });

                const plAll = rawPlaylists.map(p => mapPlaylistItem(p));
                if (plAll.length) plCats.push(makeCategory('pl-all', '所有歌单', plAll, resMap.playlists.next || null));
                if (favPlaylists.length) plCats.push(makeCategory('pl-fav', '收藏歌单', favPlaylists));
                const madeForYouItems = (resMap.madeForYou.data || []).map(p => mapPlaylistItem(p));
                if (madeForYouItems.length) plCats.push(makeCategory('pl-mfy', '为你推荐', madeForYouItems));
                if (userPlaylists.length) plCats.push(makeCategory('pl-user', '自建歌单', userPlaylists));

                const allDatasets = {
                    home: { categories: homeCats },
                    browse: { categories: browseCats },
                    radio: { categories: radioCats },
                    library: { categories: libCats },
                    playlists: { categories: plCats },
                };

                this._cachedDatasets = allDatasets;
                idbSet(CACHE_KEY, allDatasets);

                return allDatasets[tabId]?.categories || [];
            } catch (_) {
                return [];
            }
        }

        async loadMore(cat, tabId, isSearching, scopeId) {
            if (!cat || !cat.nextUrl) return [];
            try {
                const isLib = isSearching ? (scopeId === 'library') : (tabId === 'library' || tabId === 'playlists');
                const res = await this.fetchAmp(cat.nextUrl, isLib);
                if (res && res.data && res.data.length) {
                    const newItems = res.data.map(d => {
                        if (d.type === 'library-songs' || d.type === 'songs') return mapSongItem(d);
                        if (d.type === 'library-albums' || d.type === 'albums') return isLib ? mapLibraryItem(d, 'album') : mapCatalogAlbum(d);
                        if (d.type === 'library-artists' || d.type === 'artists') return isLib ? mapLibraryItem(d, 'artist') : mapCatalogArtist(d);
                        if (d.type === 'library-playlists' || d.type === 'playlists') return mapPlaylistItem(d);
                        return resolveResourceItem(d, res.resources);
                    }).filter(Boolean);

                    cat.nextUrl = res.next || null;
                    if (!isSearching && this._cachedDatasets) {
                        idbSet(CACHE_KEY, this._cachedDatasets);
                    }
                    return newItems;
                }
            } catch (_) {
                cat.nextUrl = null;
            }
            return [];
        }

        async search(query, scope = 'catalog') {
            const sf = 'cn';
            if (scope === 'catalog') {
                const url = `/v1/catalog/${sf}/search?term=${encodeURIComponent(query)}&types=songs,albums,artists,playlists&limit=25&relate[songs]=artists&include[songs]=artists&include[albums]=artists&art[url]=f&l=zh-Hans-CN&platform=web`;
                const res = await this.fetchAmp(url, false);
                const results = res?.results || {};

                const songs = (results.songs?.data || []).map(t => mapSongItem(t)).filter(Boolean);
                const artists = (results.artists?.data || []).map(a => mapCatalogArtist(a)).filter(Boolean);
                const albums = (results.albums?.data || []).map(a => mapCatalogAlbum(a)).filter(Boolean);
                const playlists = (results.playlists?.data || []).map(p => mapPlaylistItem(p)).filter(Boolean);

                const searchCategories = [];
                const topItems = [];
                if (artists.length) topItems.push(artists[0]);
                if (songs.length) topItems.push(...songs.slice(0, 4));
                if (albums.length) topItems.push(...albums.slice(0, 2));
                if (playlists.length) topItems.push(...playlists.slice(0, 2));

                if (topItems.length) searchCategories.push(makeCategory('cat-top', '最佳结果', topItems));
                if (songs.length) searchCategories.push(makeCategory('cat-songs', '歌曲', songs, results.songs?.next || null));
                if (artists.length) searchCategories.push(makeCategory('cat-artists', '艺人', artists, results.artists?.next || null));
                if (albums.length) searchCategories.push(makeCategory('cat-albums', '专辑', albums, results.albums?.next || null));
                if (playlists.length) searchCategories.push(makeCategory('cat-playlists', '歌单', playlists, results.playlists?.next || null));

                return searchCategories;
            } else {
                const url = `/v1/me/library/search?term=${encodeURIComponent(query)}&types=library-songs,library-albums,library-artists,library-playlists&limit=25&include=catalog&art[url]=f&l=zh-Hans-CN&platform=web`;
                const res = await this.fetchAmp(url, true);
                const results = res?.results || {};

                const libSongs = (results['library-songs']?.data || []).map(t => mapSongItem(t)).filter(Boolean);
                const libArtists = (results['library-artists']?.data || []).map(a => mapLibraryItem(a, 'artist')).filter(Boolean);
                const libAlbums = (results['library-albums']?.data || []).map(a => mapLibraryItem(a, 'album')).filter(Boolean);
                const libPlaylists = (results['library-playlists']?.data || []).map(p => mapPlaylistItem(p)).filter(Boolean);

                const searchCategories = [];
                if (libSongs.length) searchCategories.push(makeCategory('lib-songs', '歌曲', libSongs, results['library-songs']?.next || null));
                if (libArtists.length) searchCategories.push(makeCategory('lib-artists', '艺人', libArtists, results['library-artists']?.next || null));
                if (libAlbums.length) searchCategories.push(makeCategory('lib-albums', '专辑', libAlbums, results['library-albums']?.next || null));
                if (libPlaylists.length) searchCategories.push(makeCategory('lib-playlists', '歌单', libPlaylists, results['library-playlists']?.next || null));

                return searchCategories;
            }
        }

        async loadDetail(item) {
            const sf = 'cn';
            const isLib = (item.id.indexOf('p.') === 0 || item.id.indexOf('l.') === 0 || item.isLibrary);

            let endpoint = '';
            if (item.type.includes('playlist')) {
                endpoint = isLib ? `/v1/me/library/playlists/${item.id}/tracks` : `/v1/catalog/${sf}/playlists/${item.id}/tracks`;
            } else if (item.type === 'album') {
                endpoint = isLib ? `/v1/me/library/albums/${item.id}/tracks` : `/v1/catalog/${sf}/albums/${item.id}/tracks`;
            } else if (item.type === 'artist') {
                endpoint = isLib ? `/v1/me/library/artists/${item.id}/tracks` : `/v1/catalog/${sf}/artists/${item.id}/view/top-songs`;
            }

            if (!endpoint) return [];

            const res = await this.fetchAmp(endpoint + '?limit=100', isLib);
            const rawTracks = res?.data || [];
            return rawTracks.map(t => {
                const attr = t.attributes || {};
                return {
                    id: t.id,
                    name: attr.name || '未知单曲',
                    artistName: attr.artistName || attr.albumName || '',
                    durationMs: attr.durationInMillis || null,
                    raw: t
                };
            });
        }

        async playItem(item, category, index = 0) {
            const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk) return;

            // 1. [0ms 极速响应] 立即向 UI 和 C++ 发送乐观播放状态，完全跳过网络握手延迟，曲名/歌手/进度瞬间更新
            const title = item.name || item.title || '';
            const artist = item.artistName || item.subtitle || '';
            const durationMs = item.durationMs || 0;
            const albumName = (category && (category.title || category.name)) || item.albumName || '';
            this._notifyOptimisticNowPlaying({
                title,
                artist,
                album: albumName,
                contextTitle: albumName,
                durationMs,
                isPlaying: true
            });

            try {
                // 2. [队列复用极速优化] 若当前点击的曲目属于同一个歌单/专辑，直接切索引，避免重新向苹果云端全量拉取歌单
                const colId = category ? (category.id || null) : null;
                const isSameCollection = colId && (this._currentCollectionId === colId);
                const hasValidQueue = mk.queue && mk.queue.items && mk.queue.items.length > 0;

                if (isSameCollection && hasValidQueue && typeof index === 'number' && index >= 0 && index < mk.queue.items.length) {
                    if (typeof mk.changeToMediaAtIndex === 'function') {
                        await mk.changeToMediaAtIndex(index);
                        mk.play();
                        return;
                    }
                }

                // 3. 记录当前歌单/专辑 ID，供下次同歌单切歌时零延迟复用
                if (colId) {
                    this._currentCollectionId = colId;
                }

                // 4. 并行非阻塞发起队列与播放请求
                if (item.type === 'station') {
                    await mk.setQueue({ station: item.id });
                } else if (item.type === 'song' || item.type === 'fav-song') {
                    await mk.setQueue({ song: item.id });
                } else if (category && category.type && category.type.includes('playlist')) {
                    await mk.setQueue({ playlist: category.id, startWith: index });
                } else if (category && category.type === 'album') {
                    await mk.setQueue({ album: category.id, startWith: index });
                } else {
                    await mk.setQueue({ song: item.id });
                }
                mk.play();
            } catch (_) {}
            this._notifyNowPlaying();
        }

        async playCollection(item, tracks = null, startIndex = 0) {
            const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk) return;

            if (item && item.id) {
                this._currentCollectionId = item.id;
            }

            try {
                if (item.type.includes('playlist')) {
                    await mk.setQueue({ playlist: item.id, startWith: startIndex });
                } else if (item.type === 'album') {
                    await mk.setQueue({ album: item.id, startWith: startIndex });
                }
                await mk.play();
            } catch (_) {}
            this._notifyNowPlaying();
        }

        playByNative(kind, collectionId, trackIdx, trackId) {
            const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk) return;

            // 队列复用优化
            if (collectionId && this._currentCollectionId === collectionId && mk.queue && mk.queue.items && trackIdx >= 0) {
                if (typeof mk.changeToMediaAtIndex === 'function') {
                    mk.changeToMediaAtIndex(trackIdx).then(() => mk.play());
                    return;
                }
            }

            if (collectionId) this._currentCollectionId = collectionId;

            try {
                if (kind === 'playlist' && collectionId) {
                    mk.setQueue({ playlist: collectionId, startWith: trackIdx }).then(() => mk.play());
                } else if (kind === 'album' && collectionId) {
                    mk.setQueue({ album: collectionId, startWith: trackIdx }).then(() => mk.play());
                } else if (trackId) {
                    mk.setQueue({ song: trackId }).then(() => mk.play());
                }
            } catch (_) {}
            this._notifyNowPlaying();
        }

        playStationByNative(stationId) {
            const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (!mk || !stationId) return;
            try {
                mk.setQueue({ station: stationId }).then(() => mk.play());
            } catch (_) {}
            this._notifyNowPlaying();
        }

        jumpToPlaying() {
            // 保留未来扩展：若用户在底部栏双击，可跳转到正在播放上下文
        }

        onNowPlayingChange(callback) {
            this._nowPlayingCallback = callback;
        }

        onUserChange(callback) {
            this._userCallback = callback;
        }

        _notifyOptimisticNowPlaying(meta) {
            if (!this._nowPlayingCallback) return;
            try {
                this._nowPlayingCallback({
                    source: 'Apple Music',
                    title: meta.title || '',
                    artist: meta.artist || '',
                    album: meta.album || '',
                    contextTitle: meta.contextTitle || meta.album || '',
                    isPlaying: true,
                    positionMs: 0,
                    durationMs: meta.durationMs || 0
                });
            } catch (_) {}
        }

        _notifyNowPlaying() {
            if (!this._nowPlayingCallback) return;
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

                this._nowPlayingCallback({
                    source: 'Apple Music',
                    title,
                    artist,
                    album,
                    isPlaying,
                    positionMs: posMs,
                    durationMs: durMs
                });
            } catch (_) {}
        }

        _detectUser() {
            if (!this._userCallback) return;
            try {
                let uname = '';
                const subEls = document.querySelectorAll('.product-lockup__subtitle, [data-testid="product-lockup-subtitle"], [aria-label*="账号"], [aria-label*="Account"]');
                for (const el of subEls) {
                    const txt = (el.textContent || el.getAttribute('aria-label') || '').trim();
                    const m = txt.match(/^(.+?)的\s*Apple\s*Music$/i);
                    if (m && m[1] && m[1] !== '你') { uname = m[1].trim(); break; }
                }
                if (!uname) uname = '小可';
                this._userCallback(uname);
            } catch (_) {}
        }

        _attachNativeEvents() {
            // 接入 MusicKit 原生状态变更事件与 audio 元素直通事件，彻底消除 350ms 轮询等待
            try {
                const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk && typeof mk.addEventListener === 'function') {
                    mk.addEventListener('playbackStateDidChange', () => this._notifyNowPlaying());
                    mk.addEventListener('nowPlayingItemDidChange', () => this._notifyNowPlaying());
                    mk.addEventListener('playbackTimeDidChange', () => this._notifyNowPlaying());
                }
            } catch (_) {}

            const hookAudio = () => {
                const audios = document.querySelectorAll('audio, video');
                audios.forEach(a => {
                    if (a.__airmuseHooked) return;
                    a.__airmuseHooked = true;
                    a.preload = 'auto';
                    a.addEventListener('play', () => this._notifyNowPlaying());
                    a.addEventListener('playing', () => this._notifyNowPlaying());
                    a.addEventListener('pause', () => this._notifyNowPlaying());
                    a.addEventListener('seeked', () => this._notifyNowPlaying());
                });
            };
            hookAudio();
            setInterval(hookAudio, 2500);
        }

        _startMonitor() {
            this._attachNativeEvents();
            setInterval(() => {
                this._notifyNowPlaying();
                this._detectUser();
            }, 500);
        }
    }

    global.AppleMusicProvider = AppleMusicProvider;

})(typeof window !== 'undefined' ? window : this);


            // ── 3. 实例化并启动应用 ──
            const provider = new window.AppleMusicProvider();
            window.AirMuseUI.init(provider);
        } catch (err) {
            console.error('[AirMuse] Engine bootstrap error:', err);
        }
    }

    bootstrap();
})();
