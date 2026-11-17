// airmuse_apple_engine.js
// Modern Web Engine for AirMuse (Amp-API Direct Fetch + IndexedDB + Responsive Dual-Column Layout)

(function () {
    if (window.__airmuseEngineInited) return;

    // ── 0. IndexedDB 异步本地缓存引擎 (替代 localStorage) ───────────────────
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

    function init() {
        if (!document.body) {
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', init, { once: true });
            } else {
                setTimeout(init, 50);
            }
            return;
        }

        if (window.__airmuseEngineInited) return;
        window.__airmuseEngineInited = true;

        // ── 1. 样式表：深色居中导航、封面角标、右侧专区详情 ───────────────────
        const CSS = `
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
                gap: 2px;
                width: 48px;
                justify-content: flex-end;
            }

            .am-icon-btn {
                border: none;
                background: transparent;
                color: #8e8e93;
                font-size: 12px;
                cursor: pointer;
                padding: 3px 5px;
                border-radius: 4px;
                transition: color 0.15s, background 0.15s;
                display: flex;
                align-items: center;
                justify-content: center;
                line-height: 1;
            }
            .am-icon-btn:hover {
                color: #f4f4f5;
                background: rgba(255, 255, 255, 0.08);
            }
            .am-icon-btn.active {
                color: #fa2d48;
                background: rgba(250, 45, 72, 0.15);
            }

            .am-tab-group {
                display: flex;
                background: #242428;
                border-radius: 5px;
                padding: 2px;
                gap: 2px;
            }
            .am-tab-btn {
                border: none;
                background: transparent;
                color: #a1a1aa;
                font-size: 11px;
                font-weight: 500;
                padding: 2px 7px;
                border-radius: 4px;
                cursor: pointer;
                transition: all 0.15s ease;
            }
            .am-tab-btn:hover { color: #f4f4f5; }
            .am-tab-btn.active {
                background: #fa2d48;
                color: #ffffff;
                font-weight: 600;
                box-shadow: 0 1px 4px rgba(250, 45, 72, 0.4);
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
                border-color: rgba(250, 45, 72, 0.6);
                background: #27272b;
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
                background: #fa2d48;
                color: #ffffff;
                font-weight: 600;
                box-shadow: 0 1px 3px rgba(250, 45, 72, 0.4);
            }

            /* 主体双栏布局 */
            .am-main-layout {
                display: flex;
                flex: 1;
                min-height: 0;
                position: relative;
            }

            /* 左侧分类侧边栏 (无任何数字计数) */
            .am-sidebar {
                width: 94px;
                background: #141416;
                border-right: 1px solid rgba(255, 255, 255, 0.06);
                overflow-y: auto;
                overflow-x: hidden;
                padding: 4px;
                flex-shrink: 0;
            }
            .am-sidebar::-webkit-scrollbar { width: 3px; }
            .am-sidebar::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.15); border-radius: 2px; }

            .am-cat-item {
                font-size: 10.5px;
                color: #a1a1aa;
                padding: 6px 7px;
                border-radius: 4px;
                margin-bottom: 2px;
                cursor: pointer;
                white-space: nowrap;
                overflow: hidden;
                text-overflow: ellipsis;
                transition: all 0.12s ease;
            }
            .am-cat-item:hover {
                background: rgba(255, 255, 255, 0.05);
                color: #ffffff;
            }
            .am-cat-item.active {
                background: rgba(250, 45, 72, 0.15);
                color: #fa2d48;
                font-weight: 600;
            }

            /* 右侧内容面板 */
            .am-content-panel {
                flex: 1;
                background: #18181b;
                display: flex;
                flex-direction: column;
                min-width: 0;
                position: relative; /* 限制详情页仅在右边栏展开 */
            }

            /* 滚动卡片容器 */
            .am-cards-scroll {
                flex: 1;
                overflow-y: auto;
                padding: 6px;
                display: flex;
                flex-direction: column;
                gap: 5px;
            }
            .am-cards-scroll::-webkit-scrollbar { width: 3px; }
            .am-cards-scroll::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.18); border-radius: 2px; }

            /* 卡片条目规范 (单栏模式) */
            .am-item-card {
                display: flex;
                gap: 7px;
                padding: 5px 6px;
                background: #202024;
                border: 1px solid rgba(255, 255, 255, 0.04);
                border-radius: 5px;
                cursor: pointer;
                align-items: center;
                text-decoration: none;
                color: inherit;
                transition: background 0.12s, transform 0.1s;
                min-width: 0;
            }
            .am-item-card:hover {
                background: #27272a;
                transform: translateY(-1px);
                border-color: rgba(255, 255, 255, 0.09);
            }

            /* 封面包装层与右上角角标 */
            .am-thumb-wrap {
                position: relative;
                flex-shrink: 0;
                line-height: 0;
                display: inline-block;
                border-radius: 4px;
                overflow: hidden;
            }
            .am-item-thumb {
                width: 38px;
                height: 38px;
                border-radius: 4px;
                object-fit: cover;
                background: #27272a;
                display: block;
            }
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

            /* 角标色彩系统 */
            .type-song { background: rgba(37, 99, 235, 0.9); color: #ffffff; }
            .type-fav-song { background: rgba(225, 29, 72, 0.95); color: #ffffff; }
            .type-album { background: rgba(147, 51, 234, 0.9); color: #ffffff; }
            .type-playlist { background: rgba(219, 39, 119, 0.9); color: #ffffff; }
            .type-user-playlist { background: rgba(14, 165, 233, 0.95); color: #ffffff; } /* 自建：鲜明亮蓝 */
            .type-fav-playlist { background: rgba(219, 39, 119, 0.95); color: #ffffff; }  /* 收藏：玫瑰粉 */
            .type-station { background: rgba(217, 119, 6, 0.95); color: #ffffff; }
            .type-editorial { background: rgba(22, 163, 74, 0.9); color: #ffffff; }
            .type-artist { background: rgba(13, 148, 136, 0.9); color: #ffffff; }
            .type-default { background: rgba(82, 82, 91, 0.9); color: #ffffff; }

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
            }
            .am-cards-scroll.grid-2col .am-thumb-wrap {
                width: 100% !important;
            }
            .am-cards-scroll.grid-2col .am-item-thumb {
                width: 100% !important;
                height: auto !important;
                aspect-ratio: 1 / 1 !important;
                border-radius: 4px !important;
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
                gap: 2px !important;
            }
            .am-cards-scroll.grid-2col .am-item-title {
                font-size: 10px !important;
                line-height: 1.25 !important;
            }
            .am-cards-scroll.grid-2col .am-item-sub {
                font-size: 8.5px !important;
                line-height: 1.2 !important;
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
            .am-detail-btn.play-all { background: #fa2d48; color: #fff; font-weight: 600; }
            .am-detail-btn.play-all:hover { background: #e0263f; }
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
        `;

        const styleEl = document.createElement('style');
        styleEl.id = 'airmuse-modern-css';
        styleEl.textContent = CSS;
        (document.head || document.documentElement).appendChild(styleEl);

        // ── 2. 创建核心 DOM 结构 ──────────────────────────────────────────────
        let appRoot = document.getElementById('airmuse-app');
        if (!appRoot) {
            appRoot = document.createElement('div');
            appRoot.id = 'airmuse-app';
            appRoot.innerHTML = `
                <div class="am-top-bar" id="amTopBar">
                    <div class="am-top-left">
                        <button class="am-icon-btn" id="amRefreshBtn" title="刷新数据">⟳</button>
                    </div>
                    <div class="am-top-center">
                        <div class="am-tab-group">
                            <button class="am-tab-btn active" data-tab="home">主页</button>
                            <button class="am-tab-btn" data-tab="browse">新发现</button>
                            <button class="am-tab-btn" data-tab="radio">广播</button>
                            <button class="am-tab-btn" data-tab="library">资料库</button>
                            <button class="am-tab-btn" data-tab="playlists">歌单</button>
                        </div>
                    </div>
                    <div class="am-top-right">
                        <button class="am-icon-btn" id="amLayoutBtn" title="切换单栏/双栏">⚏</button>
                        <button class="am-icon-btn" id="amSearchBtn" title="搜索 (替换顶部栏)">🔍</button>
                    </div>
                </div>
                <div class="am-search-bar" id="amSearchBar" style="display: none;">
                    <button class="am-icon-btn am-search-back-btn" id="amSearchBackBtn" title="返回标签栏 (Esc)">‹</button>
                    <div class="am-search-input-wrap">
                        <span class="am-search-icon">🔍</span>
                        <input type="text" class="am-search-input" id="amSearchInput" placeholder="在 Apple Music 中搜索..." autocomplete="off" />
                        <button class="am-search-clear" id="amSearchClear" style="display: none;" title="清空">✕</button>
                    </div>
                    <div class="am-search-right">
                        <button class="am-icon-btn" id="amSearchLayoutBtn" title="切换单栏/双栏">⚏</button>
                        <div class="am-search-scope" id="amSearchScope">
                            <button class="am-scope-btn active" id="amScopeCatalog" data-scope="catalog" title="搜索 Apple Music 全球曲库">Apple Music</button>
                            <button class="am-scope-btn" id="amScopeLibrary" data-scope="library" title="搜索你的个人资料库">资料库</button>
                        </div>
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
            document.body.appendChild(appRoot);
        }

        const TYPE_NAMES = {
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

        let currentTab = 'home';
        let activeCategoryIdx = 0;
        let is2Col = false;
        let isSearching = false;
        let currentSearchScope = 'catalog'; // 'catalog' | 'library'
        let currentSearchCategories = [];
        let activeSearchCategoryIdx = 0;
        let isLoadingMore = false;

        let datasets = {
            home: { categories: [] },
            browse: { categories: [] },
            radio: { categories: [] },
            library: { categories: [] },
            playlists: { categories: [] }
        };

        const topBar = document.getElementById('amTopBar');
        const sidebar = document.getElementById('amSidebar');
        const cardsScroll = document.getElementById('amCardsScroll');
        const detailView = document.getElementById('amDetailView');
        const detailBack = document.getElementById('amDetailBack');
        const detailPlayAll = document.getElementById('amDetailPlayAll');
        const detailTitle = document.getElementById('amDetailTitle');
        const detailScroll = document.getElementById('amDetailScroll');
        const layoutBtn = document.getElementById('amLayoutBtn');
        const searchBtn = document.getElementById('amSearchBtn');
        const searchBar = document.getElementById('amSearchBar');
        const searchBackBtn = document.getElementById('amSearchBackBtn');
        const searchInput = document.getElementById('amSearchInput');
        const searchClear = document.getElementById('amSearchClear');
        const searchLayoutBtn = document.getElementById('amSearchLayoutBtn');
        const scopeBtns = searchBar.querySelectorAll('.am-scope-btn');
        let currentDetailItem = null;

        // 绑定 Tab 点击
        const tabBtns = appRoot.querySelectorAll('.am-tab-btn');
        tabBtns.forEach(btn => {
            btn.onclick = () => {
                const tabKey = btn.getAttribute('data-tab');
                if (currentTab === tabKey && detailView.style.display !== 'flex' && !isSearching) return;
                currentTab = tabKey;
                activeCategoryIdx = 0;
                exitSearchMode();
                tabBtns.forEach(b => b.classList.toggle('active', b === btn));
                render();
            };
        });

        // 绑定刷新按钮
        const refreshBtn = document.getElementById('amRefreshBtn');
        if (refreshBtn) {
            refreshBtn.onclick = () => {
                fetchAllAmpData(true);
            };
        }

        // 绑定单栏/双栏切换
        function applyLayout() {
            cardsScroll.classList.toggle('grid-2col', is2Col);
            const icon = is2Col ? '☰' : '⚏';
            const tip = is2Col ? '切换至单栏列表' : '切换至双栏网格';
            layoutBtn.innerText = icon;
            layoutBtn.title = tip;
            layoutBtn.classList.toggle('active', is2Col);
            if (searchLayoutBtn) {
                searchLayoutBtn.innerText = icon;
                searchLayoutBtn.title = tip;
                searchLayoutBtn.classList.toggle('active', is2Col);
            }
        }

        function toggleLayout() {
            is2Col = !is2Col;
            applyLayout();
            idbSet('airmuse_layout_2col', is2Col);
        }

        layoutBtn.onclick = toggleLayout;
        if (searchLayoutBtn) searchLayoutBtn.onclick = toggleLayout;

        idbGet('airmuse_layout_2col').then(val => {
            if (val !== null && val !== undefined) {
                is2Col = !!val;
                applyLayout();
            }
        });

        // ── 搜索控制逻辑 (完全替换顶部标签栏 + 范围开关 + 双栏呈现) ───────────────────
        function enterSearchMode() {
            isSearching = true;
            topBar.style.display = 'none';
            searchBar.style.display = 'flex';
            detailView.style.display = 'none';
            searchInput.focus();

            const query = searchInput.value.trim();
            if (query) {
                performSearch(query, currentSearchScope);
            } else {
                renderSearchPrompt();
            }
        }

        function exitSearchMode() {
            isSearching = false;
            currentSearchCategories = [];
            activeSearchCategoryIdx = 0;
            searchBar.style.display = 'none';
            topBar.style.display = 'flex';
            detailView.style.display = 'none';
            searchInput.value = '';
            searchClear.style.display = 'none';
            render();
        }

        searchBtn.onclick = enterSearchMode;
        searchBackBtn.onclick = exitSearchMode;

        searchClear.onclick = () => {
            searchInput.value = '';
            searchClear.style.display = 'none';
            searchInput.focus();
            renderSearchPrompt();
        };

        scopeBtns.forEach(btn => {
            btn.onclick = () => {
                const scope = btn.dataset.scope;
                if (scope === currentSearchScope) return;
                currentSearchScope = scope;
                scopeBtns.forEach(b => b.classList.toggle('active', b === btn));
                searchInput.placeholder = scope === 'catalog' ? '在 Apple Music 中搜索...' : '在资料库中搜索...';
                const query = searchInput.value.trim();
                if (query) {
                    performSearch(query, currentSearchScope);
                } else {
                    renderSearchPrompt();
                }
            };
        });

        let searchDebounceTimer = null;
        searchInput.oninput = () => {
            clearTimeout(searchDebounceTimer);
            const query = searchInput.value.trim();
            searchClear.style.display = searchInput.value ? 'block' : 'none';
            if (!query) {
                renderSearchPrompt();
                return;
            }
            searchDebounceTimer = setTimeout(() => {
                performSearch(query, currentSearchScope);
            }, 280);
        };

        searchInput.onkeydown = (e) => {
            if (e.key === 'Escape') {
                exitSearchMode();
            } else if (e.key === 'Enter') {
                clearTimeout(searchDebounceTimer);
                const q = searchInput.value.trim();
                if (q) performSearch(q, currentSearchScope);
            }
        };

        function renderSearchPrompt() {
            sidebar.innerHTML = '<div class="am-empty-tip" style="padding: 10px 4px; font-size: 10px;">输入搜索</div>';
            const scopeLabel = currentSearchScope === 'catalog' ? 'Apple Music 全球曲库' : '个人资料库';
            cardsScroll.innerHTML = `
                <div class="am-empty-tip" style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100%; gap: 6px;">
                    <div style="font-size: 24px; opacity: 0.8;">🔍</div>
                    <div style="font-size: 11px; color: #d4d4d8; font-weight: 500;">搜索 ${scopeLabel}</div>
                    <div style="font-size: 9.5px; color: #71717a;">在上方搜索框输入关键词</div>
                </div>
            `;
        }

        async function performSearch(query, scope = currentSearchScope) {
            if (!query) {
                renderSearchPrompt();
                return;
            }
            isSearching = true;
            detailView.style.display = 'none';
            sidebar.innerHTML = '<div class="am-empty-tip" style="padding: 10px 4px; font-size: 10px;">搜索中...</div>';
            cardsScroll.innerHTML = '<div class="am-empty-tip">正在搜索...</div>';

            try {
                const sf = 'cn';
                if (scope === 'catalog') {
                    const url = `/v1/catalog/${sf}/search?term=${encodeURIComponent(query)}&types=songs,albums,artists,playlists&limit=25&relate[songs]=artists&include[songs]=artists&include[albums]=artists&art[url]=f&l=zh-Hans-CN&platform=web`;
                    const res = await fetchAmp(url, false);
                    const results = res?.results || {};

                    const songs = (results.songs?.data || []).map(t => mapSongItem(t)).filter(Boolean);
                    const artists = (results.artists?.data || []).map(a => mapCatalogArtist(a)).filter(Boolean);
                    const albums = (results.albums?.data || []).map(a => mapCatalogAlbum(a)).filter(Boolean);
                    const playlists = (results.playlists?.data || []).map(p => mapPlaylistItem(p)).filter(Boolean);

                    const searchCategories = [];

                    // 1. 最佳结果 (组合高相关度条目：首位艺人 + 4首歌曲 + 2张专辑 + 2个歌单)
                    const topItems = [];
                    if (artists.length) topItems.push(artists[0]);
                    if (songs.length) topItems.push(...songs.slice(0, 4));
                    if (albums.length) topItems.push(...albums.slice(0, 2));
                    if (playlists.length) topItems.push(...playlists.slice(0, 2));

                    if (topItems.length) {
                        searchCategories.push({
                            id: 'cat-top',
                            title: '最佳结果',
                            items: topItems
                        });
                    }
                    if (songs.length) {
                        searchCategories.push({
                            id: 'cat-songs',
                            title: '歌曲',
                            items: songs,
                            nextUrl: results.songs?.next || null
                        });
                    }
                    if (artists.length) {
                        searchCategories.push({
                            id: 'cat-artists',
                            title: '艺人',
                            items: artists,
                            nextUrl: results.artists?.next || null
                        });
                    }
                    if (albums.length) {
                        searchCategories.push({
                            id: 'cat-albums',
                            title: '专辑',
                            items: albums,
                            nextUrl: results.albums?.next || null
                        });
                    }
                    if (playlists.length) {
                        searchCategories.push({
                            id: 'cat-playlists',
                            title: '歌单',
                            items: playlists,
                            nextUrl: results.playlists?.next || null
                        });
                    }

                    renderSearchResults(searchCategories, query, scope);
                } else {
                    // scope === 'library'
                    const url = `/v1/me/library/search?term=${encodeURIComponent(query)}&types=library-songs,library-albums,library-artists,library-playlists&limit=25&art[url]=f&include=catalog&l=zh-Hans-CN&platform=web`;
                    const res = await fetchAmp(url, true);
                    const results = res?.results || {};

                    const libSongs = (results['library-songs']?.data || []).map(t => mapSongItem(t)).filter(Boolean);
                    const libArtists = (results['library-artists']?.data || []).map(a => mapLibraryItem(a, 'artist')).filter(Boolean);
                    const libAlbums = (results['library-albums']?.data || []).map(a => mapLibraryItem(a, 'album')).filter(Boolean);
                    const libPlaylists = (results['library-playlists']?.data || []).map(p => mapPlaylistItem(p)).filter(Boolean);

                    const searchCategories = [];

                    // 1. 最佳结果 (组合资料库命中项)
                    const topItems = [];
                    if (libArtists.length) topItems.push(libArtists[0]);
                    if (libSongs.length) topItems.push(...libSongs.slice(0, 4));
                    if (libAlbums.length) topItems.push(...libAlbums.slice(0, 2));
                    if (libPlaylists.length) topItems.push(...libPlaylists.slice(0, 2));

                    if (topItems.length) {
                        searchCategories.push({
                            id: 'lib-top',
                            title: '最佳结果',
                            items: topItems
                        });
                    }
                    if (libSongs.length) {
                        searchCategories.push({
                            id: 'lib-songs',
                            title: '歌曲',
                            items: libSongs,
                            nextUrl: results['library-songs']?.next || null
                        });
                    }
                    if (libArtists.length) {
                        searchCategories.push({
                            id: 'lib-artists',
                            title: '艺人',
                            items: libArtists,
                            nextUrl: results['library-artists']?.next || null
                        });
                    }
                    if (libAlbums.length) {
                        searchCategories.push({
                            id: 'lib-albums',
                            title: '专辑',
                            items: libAlbums,
                            nextUrl: results['library-albums']?.next || null
                        });
                    }
                    if (libPlaylists.length) {
                        searchCategories.push({
                            id: 'lib-playlists',
                            title: '歌单',
                            items: libPlaylists,
                            nextUrl: results['library-playlists']?.next || null
                        });
                    }

                    renderSearchResults(searchCategories, query, scope);
                }
            } catch (_) {
                sidebar.innerHTML = '<div class="am-empty-tip" style="padding: 10px 4px; font-size: 10px;">错误</div>';
                cardsScroll.innerHTML = '<div class="am-empty-tip">搜索遇到网络问题，请重试</div>';
            }
        }

        function renderSearchResults(categories, query, scope) {
            currentSearchCategories = categories;
            activeSearchCategoryIdx = 0;

            if (!categories.length) {
                sidebar.innerHTML = '<div class="am-empty-tip" style="padding: 10px 4px; font-size: 10px;">无结果</div>';
                const scopeName = scope === 'catalog' ? 'Apple Music' : '资料库';
                cardsScroll.innerHTML = `
                    <div class="am-empty-tip" style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100%; gap: 6px;">
                        <div style="font-size: 24px; opacity: 0.8;">∅</div>
                        <div style="font-size: 11px; color: #d4d4d8; font-weight: 500;">未找到相关内容</div>
                        <div style="font-size: 9.5px; color: #71717a;">在 ${scopeName} 中未找到与 "${escapeHtml(query)}" 匹配的结果</div>
                    </div>
                `;
                return;
            }

            renderSearchSidebarAndCards();
        }

        function renderSearchSidebarAndCards() {
            sidebar.innerHTML = '';
            if (!currentSearchCategories || !currentSearchCategories.length) {
                sidebar.innerHTML = '<div class="am-empty-tip" style="padding: 10px 4px; font-size: 10px;">无结果</div>';
                return;
            }

            if (activeSearchCategoryIdx >= currentSearchCategories.length) {
                activeSearchCategoryIdx = 0;
            }

            currentSearchCategories.forEach((cat, idx) => {
                const item = document.createElement('div');
                item.className = 'am-cat-item' + (idx === activeSearchCategoryIdx ? ' active' : '');
                item.innerText = cat.title;
                item.title = cat.title;
                item.onclick = () => {
                    activeSearchCategoryIdx = idx;
                    sidebar.querySelectorAll('.am-cat-item').forEach((b, i) => b.classList.toggle('active', i === idx));
                    detailView.style.display = 'none';
                    renderCardsForCategory(cat);
                };
                sidebar.appendChild(item);
            });

            const cat = currentSearchCategories[activeSearchCategoryIdx];
            if (cat) {
                renderCardsForCategory(cat);
            }
        }

        // 绑定详情页返回与整张播放 (仅在右侧面板内操作)
        detailBack.onclick = () => {
            detailView.style.display = 'none';
        };

        detailPlayAll.onclick = async () => {
            if (!currentDetailItem) return;
            const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
            if (mk) {
                try {
                    if (currentDetailItem.type.includes('playlist')) {
                        await mk.setQueue({ playlist: currentDetailItem.id });
                    } else if (currentDetailItem.type === 'album') {
                        await mk.setQueue({ album: currentDetailItem.id });
                    }
                    await mk.play();
                    setTimeout(pushNowPlaying, 400);
                } catch (_) {}
            }
        };

        // ── 3. 渲染视图 ───────────────────────────────────────────────────────
        function render() {
            if (isSearching) {
                if (!currentSearchCategories || !currentSearchCategories.length) {
                    renderSearchPrompt();
                    return;
                }
                renderSearchSidebarAndCards();
                return;
            }

            const curData = datasets[currentTab] || { categories: [] };
            sidebar.innerHTML = '';

            if (!curData.categories || !curData.categories.length) {
                cardsScroll.innerHTML = '<div class="am-empty-tip">正在载入 Apple Music 数据...</div>';
                return;
            }

            if (activeCategoryIdx >= curData.categories.length) {
                activeCategoryIdx = 0;
            }

            curData.categories.forEach((cat, idx) => {
                const el = document.createElement('div');
                el.className = 'am-cat-item' + (idx === activeCategoryIdx ? ' active' : '');
                el.title = cat.title;

                const span = document.createElement('span');
                span.innerText = cat.title;
                span.style.overflow = 'hidden';
                span.style.textOverflow = 'ellipsis';
                el.appendChild(span);

                el.onclick = () => {
                    activeCategoryIdx = idx;
                    isSearching = false;
                    detailView.style.display = 'none'; // 点击左侧分类即切回右侧卡片浏览
                    Array.from(sidebar.children).forEach((child, i) => {
                        child.className = 'am-cat-item' + (i === activeCategoryIdx ? ' active' : '');
                    });
                    renderContent();
                };
                sidebar.appendChild(el);
            });

            renderContent();
        }

        function renderContent() {
            const curData = datasets[currentTab] || { categories: [] };
            const cat = curData.categories[activeCategoryIdx];
            if (!cat) return;

            renderCardsForCategory(cat);
        }

        // 创建条目卡片 (右上角封面角标，彻底去除红色眉标)
        function createCardElement(item, cat, itemIdx) {
            const typeKey = (item.type || 'default').toLowerCase();
            const typeLabel = TYPE_NAMES[typeKey] || item.type || '条目';
            const tagClass = 'type-' + (TYPE_NAMES[typeKey] ? typeKey : 'default');

            const fallbackImg = (typeKey === 'artist')
                ? "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='38' height='38' viewBox='0 0 38 38'%3E%3Crect width='38' height='38' fill='%2327272a'/%3E%3Ctext x='50%25' y='50%25' dominant-baseline='middle' text-anchor='middle' font-family='sans-serif' font-size='16' fill='%2371717a'%3E👤%3C/text%3E%3C/svg%3E"
                : "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='38' height='38' viewBox='0 0 38 38'%3E%3Crect width='38' height='38' fill='%2327272a'/%3E%3Ctext x='50%25' y='50%25' dominant-baseline='middle' text-anchor='middle' font-family='sans-serif' font-size='16' fill='%2371717a'%3E🎵%3C/text%3E%3C/svg%3E";

            const card = document.createElement('div');
            card.className = 'am-item-card';

            // 封面容器：图片 + 右上角角标
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

            // 卡片内容 (彻底去除任何红色眉标显示)
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
                handleItemClick(item, cat, itemIdx);
            };

            return card;
        }

        function renderCardsForCategory(cat) {
            cardsScroll.innerHTML = '';

            if (!cat.items || !cat.items.length) {
                cardsScroll.innerHTML = '<div class="am-empty-tip">该分类暂无条目</div>';
                return;
            }

            cat.items.forEach((item, itemIdx) => {
                const card = createCardElement(item, cat, itemIdx);
                cardsScroll.appendChild(card);
            });

            cardsScroll.scrollTop = 0;
        }

        // ── 4. 触底滚动加载引擎 (Infinite Scroll on Bottom) ────────────────────
        cardsScroll.onscroll = async () => {
            if (isLoadingMore) return;
            const curData = datasets[currentTab] || { categories: [] };
            const cat = isSearching 
                ? (currentSearchCategories ? currentSearchCategories[activeSearchCategoryIdx] : null) 
                : curData.categories[activeCategoryIdx];
            if (!cat || !cat.nextUrl) return;

            const threshold = 50;
            if (cardsScroll.scrollTop + cardsScroll.clientHeight >= cardsScroll.scrollHeight - threshold) {
                isLoadingMore = true;

                let spinner = document.createElement('div');
                spinner.className = 'am-loading-more';
                spinner.id = 'amLoadingMoreIndicator';
                spinner.innerText = '正在加载更多...';
                cardsScroll.appendChild(spinner);

                try {
                    const isLib = isSearching ? (currentSearchScope === 'library') : (currentTab === 'library' || currentTab === 'playlists');
                    const res = await fetchAmp(cat.nextUrl, isLib);
                    if (res && res.data && res.data.length) {
                        const startIdx = cat.items.length;
                        const newItems = res.data.map(d => {
                            if (d.type === 'library-songs' || d.type === 'songs') return mapSongItem(d);
                            if (d.type === 'library-albums' || d.type === 'albums') return isLib ? mapLibraryItem(d, 'album') : mapCatalogAlbum(d);
                            if (d.type === 'library-artists' || d.type === 'artists') return isLib ? mapLibraryItem(d, 'artist') : mapCatalogArtist(d);
                            if (d.type === 'library-playlists' || d.type === 'playlists') return mapPlaylistItem(d);
                            return resolveResourceItem(d, res.resources);
                        }).filter(Boolean);

                        cat.items.push(...newItems);
                        cat.nextUrl = res.next || null;

                        newItems.forEach((item, idx) => {
                            const card = createCardElement(item, cat, startIdx + idx);
                            cardsScroll.insertBefore(card, spinner);
                        });

                        if (!isSearching) {
                            idbSet(CACHE_KEY, datasets);
                        }
                    } else {
                        cat.nextUrl = null;
                    }
                } catch (_) {
                    cat.nextUrl = null;
                } finally {
                    const el = document.getElementById('amLoadingMoreIndicator');
                    if (el) el.remove();
                    isLoadingMore = false;
                }
            }
        };

        // ── 5. 详情页与播放控制 (仅在右侧栏内展现) ───────────────────────────
        async function handleItemClick(item, cat, itemIdx) {
            const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;

            if (item.type === 'station') {
                if (mk) {
                    try {
                        await mk.setQueue({ station: item.id });
                        await mk.play();
                        setTimeout(pushNowPlaying, 400);
                    } catch (_) {}
                }
                return;
            }

            if (item.type === 'song' || item.type === 'fav-song') {
                if (mk) {
                    try {
                        await mk.setQueue({ song: item.id });
                        await mk.play();
                        setTimeout(pushNowPlaying, 400);
                    } catch (_) {}
                }
                return;
            }

            openDetailView(item);
        }

        async function openDetailView(item) {
            currentDetailItem = item;
            detailTitle.innerText = item.title;
            detailScroll.innerHTML = '<div class="am-empty-tip">正在载入曲目列表...</div>';
            detailView.style.display = 'flex'; // 仅覆盖右侧 am-content-panel，左侧栏不受影响

            const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
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

            if (!endpoint) return;

            try {
                const res = await fetchAmp(endpoint + '?limit=100', isLib);
                const rawTracks = res?.data || [];
                detailScroll.innerHTML = '';
                if (!rawTracks.length) {
                    detailScroll.innerHTML = '<div class="am-empty-tip">暂无可播放曲目</div>';
                    return;
                }

                rawTracks.forEach((t, idx) => {
                    const attr = t.attributes || {};
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
                    nameEl.innerText = attr.name || '未知单曲';
                    body.appendChild(nameEl);

                    const artistEl = document.createElement('div');
                    artistEl.className = 'am-track-artist';
                    artistEl.innerText = attr.artistName || attr.albumName || '';
                    body.appendChild(artistEl);

                    row.appendChild(body);

                    if (attr.durationInMillis) {
                        const durEl = document.createElement('div');
                        durEl.className = 'am-track-dur';
                        durEl.innerText = formatDuration(attr.durationInMillis);
                        row.appendChild(durEl);
                    }

                    row.onclick = async () => {
                        if (mk) {
                            try {
                                if (item.type.includes('playlist')) {
                                    await mk.setQueue({ playlist: item.id, startWith: idx });
                                } else if (item.type === 'album') {
                                    await mk.setQueue({ album: item.id, startWith: idx });
                                } else {
                                    await mk.setQueue({ song: t.id });
                                }
                                await mk.play();
                                setTimeout(pushNowPlaying, 400);
                            } catch (_) {}
                        }
                    };

                    detailScroll.appendChild(row);
                });
            } catch (e) {
                detailScroll.innerHTML = '<div class="am-empty-tip">曲目拉取失败</div>';
            }
        }

        // ── 6. Amp-API 并发抓取与解析引擎 ─────────────────────────────────────
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

        function formatDuration(ms) {
            if (!ms || isNaN(ms)) return '';
            const sec = Math.floor(ms / 1000);
            const m = Math.floor(sec / 60);
            const s = sec % 60;
            return `${m}:${s < 10 ? '0' : ''}${s}`;
        }

        function makeCategory(id, title, items, nextUrl = null) {
            return { id, title, items, nextUrl };
        }

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

        // 映射单曲条目 (彻底去除红色文字眉标)
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

        // 映射资料库条目 (解决艺人封面缺失问题：提取 catalog 官方艺人头像)
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

            // 核心修复：艺人官方高清头像位于 relationships.catalog.data[0].attributes.artwork
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

        // 映射歌单条目 (角标区分自建/收藏，去除封面下方自建和已收藏文字)
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
                type,          // 角标显示：自建 或 收藏
                artworkUrl: formatArtworkUrl(rawArtwork, 160),
                linkUrl: attr.url || `https://music.apple.com/cn/playlist/${pl.id}`,
                canEdit,
                isLibrary: isLib
            };
        }

        function getDeveloperToken() {
            try {
                const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk && mk.developerToken) return mk.developerToken;
                const m = document.documentElement.innerHTML.match(/eyJ0eXAiOiJKV1Qi[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+/);
                if (m && m[0]) return m[0];
            } catch (_) {}
            return FALLBACK_DEV_TOKEN;
        }

        function getUserToken() {
            try {
                const mk = window.MusicKit && window.MusicKit.getInstance ? window.MusicKit.getInstance() : null;
                if (mk && mk.musicUserToken) return mk.musicUserToken;
                const m = document.cookie.match(/(?:^|;\s*)media-user-token=([^;]+)/);
                if (m && m[1]) return decodeURIComponent(m[1]);
            } catch (_) {}
            return FALLBACK_USER_TOKEN;
        }

        try {
            const uToken = getUserToken();
            if (uToken && !document.cookie.includes('media-user-token')) {
                document.cookie = `media-user-token=${uToken}; domain=.music.apple.com; path=/; max-age=31536000; SameSite=Lax`;
            }
        } catch (_) {}

        async function fetchAmp(url, needAuth = false) {
            const devToken = getDeveloperToken();
            const userToken = getUserToken();
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

        async function fetchAllAmpData(forceRefresh = false) {
            const devToken = getDeveloperToken();
            const userToken = getUserToken();
            if (!devToken) return;

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
                // 重点：加入 include=catalog&art[url]=f 关联官方 Catalog 艺人高清写真封面
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

                // 1. 解析主页
                const homeCats = (resMap.home.data || []).reduce((acc, d, idx) => {
                    const rec = resMap.home.resources?.['personal-recommendation']?.[d.id];
                    if (!rec) return acc;
                    const title = rec.attributes?.title?.stringForDisplay || rec.attributes?.title?.text || rec.attributes?.name || `推荐板块 ${idx + 1}`;
                    const items = (rec.relationships?.contents?.data || []).map(ref => resolveResourceItem(ref, resMap.home.resources)).filter(Boolean);
                    if (items.length) acc.push(makeCategory(`section-${idx + 1}`, title, items));
                    return acc;
                }, []);

                // 2. 解析新发现 & 广播
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

                // 3. 解析资料库 (排列：最近添加，喜爱歌曲，专辑，艺人，已存单曲)
                const libCats = [];
                // ① 最近添加
                const recentItems = (resMap.libRecent.data || []).map(item => mapLibraryItem(item, 'item'));
                if (recentItems.length) libCats.push(makeCategory('lib-recent', '最近添加', recentItems, resMap.libRecent.next || null));

                // ② 喜爱歌曲
                const favTracks = resMap.libFav.data?.[0]?.relationships?.tracks?.data || [];
                if (favTracks.length) libCats.push(makeCategory('lib-fav', '喜爱歌曲', favTracks.map(t => mapSongItem(t, true))));

                // ③ 专辑
                const albumItems = (resMap.libAlbums.data || []).map(item => mapLibraryItem(item, 'album'));
                if (albumItems.length) libCats.push(makeCategory('lib-albums', '专辑', albumItems, resMap.libAlbums.next || null));

                // ④ 艺人 (带 catalog 官方高清头像)
                const artistItems = (resMap.libArtists.data || []).map(item => mapLibraryItem(item, 'artist'));
                if (artistItems.length) libCats.push(makeCategory('lib-artists', '艺人', artistItems, resMap.libArtists.next || null));

                // ⑤ 已存单曲
                const songItems = (resMap.libSongs.data || []).map(t => mapSongItem(t, false));
                if (songItems.length) libCats.push(makeCategory('lib-songs', '已存单曲', songItems, resMap.libSongs.next || null));

                // 4. 解析歌单 (排列：所有歌单，收藏歌单，为你推荐，自建歌单)
                const plCats = [];
                const rawPlaylists = resMap.playlists.data || [];
                const userPlaylists = [];
                const favPlaylists = [];

                rawPlaylists.forEach(p => {
                    const item = mapPlaylistItem(p);
                    if (p.attributes?.canEdit) {
                        userPlaylists.push(item);
                    } else {
                        favPlaylists.push(item);
                    }
                });

                // ① 所有歌单
                const plAll = rawPlaylists.map(p => mapPlaylistItem(p));
                if (plAll.length) {
                    plCats.push(makeCategory('pl-all', '所有歌单', plAll, resMap.playlists.next || null));
                }

                // ② 收藏歌单
                if (favPlaylists.length) {
                    plCats.push(makeCategory('pl-fav', '收藏歌单', favPlaylists));
                }

                // ③ 为你推荐
                const madeForYouItems = (resMap.madeForYou.data || []).map(p => mapPlaylistItem(p));
                if (madeForYouItems.length) {
                    plCats.push(makeCategory('pl-mfy', '为你推荐', madeForYouItems));
                }

                // ④ 自建歌单
                if (userPlaylists.length) {
                    plCats.push(makeCategory('pl-user', '自建歌单', userPlaylists));
                }

                datasets = {
                    home: { categories: homeCats },
                    browse: { categories: browseCats },
                    radio: { categories: radioCats },
                    library: { categories: libCats },
                    playlists: { categories: plCats },
                };

                idbSet(CACHE_KEY, datasets);
                render();
            } catch (_) {}
        }

        // ── 7. 读取 IndexedDB 缓存极速直出 ─────────────────────────────────────
        idbGet(CACHE_KEY).then(cachedData => {
            if (cachedData && cachedData.home && cachedData.home.categories && cachedData.home.categories.length) {
                datasets = cachedData;
                render();
            }
        });

        setTimeout(() => {
            fetchAllAmpData();
        }, 80);

        // ── 8. 实时同步与用户检测 ───────────────────────────────────────────────
        function pushNowPlaying() {
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

                if (window.chrome && window.chrome.webview) {
                    window.chrome.webview.postMessage(JSON.stringify({
                        type: 'nowPlaying',
                        source: 'Apple Music',
                        title: title,
                        artist: artist,
                        album: album,
                        isPlaying: isPlaying,
                        positionMs: posMs,
                        durationMs: durMs
                    }));
                }
            } catch (_) {}
        }

        function detectUser() {
            try {
                let uname = '';
                const subEls = document.querySelectorAll('.product-lockup__subtitle, [data-testid="product-lockup-subtitle"], [aria-label*="账号"], [aria-label*="Account"]');
                for (const el of subEls) {
                    const txt = (el.textContent || el.getAttribute('aria-label') || '').trim();
                    const m = txt.match(/^(.+?)的\s*Apple\s*Music$/i);
                    if (m && m[1] && m[1] !== '你') { uname = m[1].trim(); break; }
                }
                if (!uname) uname = '小可';
                if (window.chrome && window.chrome.webview) {
                    window.chrome.webview.postMessage(JSON.stringify({ type: 'userStatus', userName: uname }));
                }
            } catch (_) {}
        }

        setInterval(() => {
            pushNowPlaying();
            detectUser();
        }, 350);

        window.__airmuseJumpToPlaying = function () {};
    }

    init();
})();
