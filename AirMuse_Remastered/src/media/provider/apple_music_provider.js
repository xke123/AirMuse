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
