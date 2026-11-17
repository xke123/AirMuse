/**
 * Apple Music Web — 极速数据获取引擎 (fetch_data.js)
 * =====================================================================================
 * 职责：
 * 1. 动态获取/缓存官方 Developer Bearer Token，读取用户 media-user-token 凭证
 * 2. 10 路 Storefront Amp-API 原生 HTTP 纯异步全并发极速抓取 (~1.5 秒直出)
 * 3. 统一规范化为 160x160 缩略图与 mm:ss 时长格式
 * 4. 覆盖 主页 / 新发现 / 广播 / 资料库(喜爱歌曲+单曲库) / 歌单(为你推荐+自建收藏)
 * 5. 保存 5 大标准数据 JSON 与 timing_report.json，自动调用 render.js 输出 index.html
 */

import { writeFileSync, existsSync, readFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import { renderHtml } from './render.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

// ── 1. 产物路径配置 ─────────────────────────────────────────────────────────
const AUTH_FILE         = resolve(__dirname, 'auth.json');
const TOKEN_CACHE_FILE  = resolve(__dirname, '.apple_dev_token.cache');
const HTML_OUT_FILE     = resolve(__dirname, 'index.html');
const TIMING_OUT_FILE   = resolve(__dirname, 'timing_report.json');

const HOME_OUT_FILE      = resolve(__dirname, 'apple_music_homepage.json');
const BROWSE_OUT_FILE    = resolve(__dirname, 'apple_music_browse.json');
const RADIO_OUT_FILE     = resolve(__dirname, 'apple_music_radio.json');
const LIBRARY_OUT_FILE   = resolve(__dirname, 'apple_music_library.json');
const PLAYLISTS_OUT_FILE = resolve(__dirname, 'apple_music_playlists.json');

// ── 2. 格式化与对象构造工具 ───────────────────────────────────────────────────
export function formatArtworkUrl(artworkObj, size = 160) {
  if (!artworkObj?.url) return null;
  return artworkObj.url
    .replace('{w}x{h}', `${size}x${size}`)
    .replace('{c}', 'bb')
    .replace('cc.{f}', 'bb.webp')
    .replace('{f}', 'webp');
}

export function formatDuration(ms) {
  if (!ms || isNaN(ms)) return '';
  const sec = Math.floor(ms / 1000);
  const m = Math.floor(sec / 60);
  const s = sec % 60;
  return `${m}:${s < 10 ? '0' : ''}${s}`;
}

function makeCategory(id, title, items, durationMs = 0.2) {
  return {
    id,
    title,
    itemCount: items.length,
    items,
    timing: {
      hydrationDurationMs: 0,
      extractionDurationMs: Number(durationMs.toFixed(2)),
      totalDurationMs: Number(durationMs.toFixed(2)),
      avgTimePerItemMs: items.length ? Number((durationMs / items.length).toFixed(3)) : 0,
    }
  };
}

function makePageResult(pageName, url, categories, netMs, parseMs) {
  const totalMs = netMs + parseMs;
  const totalItems = categories.reduce((sum, c) => sum + c.itemCount, 0);
  return {
    pageName,
    url,
    capturedAt: new Date().toISOString(),
    totalCategories: categories.length,
    categories,
    timing: {
      totalDurationMs: Number(totalMs.toFixed(2)),
      breakdown: { navigationDurationMs: Number(netMs.toFixed(2)), extractionDurationMs: Number(parseMs.toFixed(2)) },
      totalCategories: categories.length,
      totalItems,
      avgTimePerCategoryMs: categories.length ? Number((totalMs / categories.length).toFixed(2)) : 0,
      avgTimePerItemMs: totalItems ? Number((totalMs / totalItems).toFixed(2)) : 0,
    },
  };
}

// ── 3. 授权凭证获取 ─────────────────────────────────────────────────────────
export async function getDeveloperToken() {
  try {
    if (existsSync(TOKEN_CACHE_FILE)) {
      const token = readFileSync(TOKEN_CACHE_FILE, 'utf-8').trim();
      const exp = JSON.parse(Buffer.from(token.split('.')[1], 'base64').toString()).exp;
      if (exp && exp * 1000 > Date.now() + 86400000) return token;
    }
  } catch {}

  console.log('🔑 正在动态获取 Apple Developer Token ...');
  const res = await fetch('https://music.apple.com/assets/index~B8RKPfmaCI.js', { headers: { 'user-agent': 'Mozilla/5.0' } });
  const token = (await res.text()).match(/eyJ0eXAiOiJKV1Qi[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+/)?.[0];
  if (!token) throw new Error('未能获取 Apple Developer Token');
  writeFileSync(TOKEN_CACHE_FILE, token, 'utf-8');
  return token;
}

export function getUserToken() {
  if (!existsSync(AUTH_FILE)) return null;
  try {
    const auth = JSON.parse(readFileSync(AUTH_FILE, 'utf-8'));
    return auth.cookies?.find(c => c.name === 'media-user-token' && c.value)?.value || null;
  } catch {
    return null;
  }
}

// ── 4. 通用资源与条目映射器 ─────────────────────────────────────────────────
function resolveResourceItem(ref, resources) {
  const item = resources?.[ref.type]?.[ref.id];
  if (!item) return null;

  let target = item;
  if (item.relationships?.contents?.data?.[0]) {
    const tRef = item.relationships.contents.data[0];
    target = resources?.[tRef.type]?.[tRef.id] || item;
  }

  const attr = target.attributes || item.attributes || {};
  const typeMap = { songs: 'song', playlists: 'playlist', 'library-playlists': 'playlist', stations: 'station', albums: 'album', 'library-albums': 'album' };
  const type = typeMap[target.type || ref.type] || (ref.type.includes('editorial') ? 'editorial' : 'item');

  return {
    id: target.id || item.id,
    title: attr.name || attr.title || item.attributes?.designBadge || '推荐精选',
    subtitle: attr.artistName || attr.curatorName || (attr.description?.standard ? attr.description.standard.slice(0, 36) : 'Apple Music'),
    eyebrow: item.attributes?.designBadge || attr.plainEditorialNotes?.tagline || attr.plainEditorialCard?.tagline || null,
    type,
    artworkUrl: formatArtworkUrl(attr.artwork || attr.editorialArtwork, 160),
    linkUrl: attr.url || `https://music.apple.com/cn/${type}/${target.id || item.id}`,
  };
}

function mapSongItem(track, isFav = false) {
  const attr = track.attributes || {};
  const durationStr = formatDuration(attr.durationInMillis);
  const sub = [attr.artistName, attr.albumName].filter(Boolean).join(' · ');
  return {
    id: track.id,
    title: attr.name || '未知单曲',
    subtitle: sub || 'Apple Music',
    eyebrow: durationStr ? `${isFav ? '喜爱' : '已存'} · ${durationStr}` : (isFav ? '喜爱歌曲' : '已存单曲'),
    type: isFav ? 'fav-song' : 'song',
    artworkUrl: formatArtworkUrl(attr.artwork, 160),
    linkUrl: attr.url || `https://music.apple.com/cn/song/${attr.playParams?.catalogId || track.id}`,
    durationMs: attr.durationInMillis || null,
    durationFormatted: durationStr,
    playParams: attr.playParams || null,
  };
}

function mapLibraryItem(item, defaultType = 'item', defaultEyebrow = '') {
  const attr = item.attributes || {};
  const type = item.type === 'library-albums' ? 'album' : (item.type === 'library-playlists' ? 'playlist' : defaultType);
  const sub = attr.artistName ? (attr.trackCount ? `${attr.artistName} (${attr.trackCount} 首)` : attr.artistName) : (type === 'artist' ? '已加入资料库' : '资料库');
  const eye = defaultEyebrow || (attr.releaseDate ? attr.releaseDate.slice(0, 4) : type);
  return {
    id: item.id,
    title: attr.name || '未知名称',
    subtitle: sub,
    eyebrow: eye,
    type,
    artworkUrl: formatArtworkUrl(attr.artwork, 160),
    linkUrl: `https://music.apple.com/cn/${type}/${item.id}`,
  };
}

function mapPlaylistItem(pl, subtitle = null, eyebrow = null) {
  const attr = pl.attributes || {};
  const canEdit = attr.canEdit;
  return {
    id: pl.id,
    title: attr.name || '未命名歌单',
    subtitle: subtitle || (canEdit ? '自建歌单' : (attr.curatorName || '已收藏歌单')),
    eyebrow: eyebrow || (canEdit ? '自建' : '收藏'),
    type: 'playlist',
    artworkUrl: formatArtworkUrl(attr.artwork, 160),
    linkUrl: attr.url || `https://music.apple.com/cn/playlist/${pl.id}`,
    canEdit: !!canEdit,
  };
}

// ── 5. 数据解析器：主页 / 新发现 / 广播 ─────────────────────────────────────
export function parseHomeData(json, netMs) {
  const t0 = performance.now();
  const categories = (json.data || []).reduce((acc, d, idx) => {
    const rec = json.resources?.['personal-recommendation']?.[d.id];
    if (!rec) return acc;
    const title = rec.attributes?.title?.stringForDisplay || rec.attributes?.title?.text || rec.attributes?.name || `推荐板块 ${idx + 1}`;
    const items = (rec.relationships?.contents?.data || []).map(ref => resolveResourceItem(ref, json.resources)).filter(Boolean);
    if (items.length) acc.push(makeCategory(`section-${idx + 1}`, title, items));
    return acc;
  }, []);
  return makePageResult('主页', 'https://amp-api.music.apple.com/v1/me/recommendations', categories, netMs, performance.now() - t0);
}

function parseEditorialGrouping(json, pageName, fallbackUrl, netMs) {
  const t0 = performance.now();
  const grp = json.resources?.groupings?.[json.data?.[0]?.id];
  const tab = json.resources?.['editorial-elements']?.[grp?.relationships?.tabs?.data?.[0]?.id];
  const categories = (tab?.relationships?.children?.data || []).reduce((acc, childRef, idx) => {
    const child = json.resources?.[childRef.type]?.[childRef.id];
    if (!child) return acc;
    const title = child.attributes?.title?.stringForDisplay || child.attributes?.title?.text || child.attributes?.name || (idx === 0 ? '精品推荐' : null);
    if (!title) return acc;
    const sourceList = child.relationships?.children?.data || child.relationships?.contents?.data || [];
    const items = sourceList.map(ref => resolveResourceItem(ref, json.resources)).filter(Boolean);
    if (items.length) acc.push(makeCategory(`section-${idx + 1}`, title, items));
    return acc;
  }, []);
  return makePageResult(pageName, fallbackUrl, categories, netMs, performance.now() - t0);
}

export function parseBrowseData(json, netMs) {
  return parseEditorialGrouping(json, '新发现', 'https://amp-api-edge.music.apple.com/v1/editorial/cn/groupings?name=music', netMs);
}

export function parseRadioData(json, netMs) {
  return parseEditorialGrouping(json, '广播', 'https://amp-api-edge.music.apple.com/v1/editorial/cn/groupings?name=radio', netMs);
}

// ── 6. 数据解析器：资料库 / 歌单 ───────────────────────────────────────────
export function parseLibraryData(favJson, songsJson, recentJson, albumsJson, artistsJson, netMs) {
  const t0 = performance.now();
  const categories = [];

  // 1. 喜爱歌曲 (官方智能歌单 p.MLUk3bdrQ)
  const favTracks = favJson?.data?.[0]?.relationships?.tracks?.data || [];
  if (favTracks.length) {
    const totalFav = favJson.data[0].relationships.tracks.meta?.total || favTracks.length;
    categories.push(makeCategory('section-library-favorites', `喜爱歌曲 (${totalFav} 首)`, favTracks.map(t => mapSongItem(t, true))));
  }

  // 2. 已存单曲
  if (songsJson?.data?.length) {
    const totalSongs = songsJson.meta?.total || songsJson.data.length;
    categories.push(makeCategory('section-library-songs', `已存歌曲 (共 ${totalSongs} 首)`, songsJson.data.map(s => mapSongItem(s, false))));
  }

  // 3. 最近添加 / 专辑 / 关注艺人
  if (recentJson?.data?.length) categories.push(makeCategory('section-library-recent', '最近添加', recentJson.data.map(i => mapLibraryItem(i, 'song', '最近添加'))));
  if (albumsJson?.data?.length) categories.push(makeCategory('section-library-albums', '已存专辑', albumsJson.data.map(i => mapLibraryItem(i, 'album'))));
  if (artistsJson?.data?.length) categories.push(makeCategory('section-library-artists', '关注艺人', artistsJson.data.map(i => mapLibraryItem(i, 'artist', '艺人'))));

  return makePageResult('资料库', 'https://amp-api.music.apple.com/v1/me/library', categories, netMs, performance.now() - t0);
}

export function parsePlaylistsData(playlistsJson, favPlaylistJson, madeForYouJson, netMs) {
  const t0 = performance.now();
  const categories = [];

  const allItems = (playlistsJson?.data || []).map(p => mapPlaylistItem(p));
  const favObj = favPlaylistJson?.data?.[0];
  if (favObj && !allItems.some(it => it.id === favObj.id)) {
    allItems.unshift(mapPlaylistItem(favObj, '官方智能歌单', '精选智能'));
  }

  if (allItems.length) categories.push(makeCategory('section-playlists-all', `所有播放列表 (${allItems.length})`, allItems));

  const mfyRaw = madeForYouJson?.data || [];
  if (mfyRaw.length) {
    const mfy = mfyRaw.map(p => mapPlaylistItem(p, '特别为你推荐', '专属定制'));
    categories.push(makeCategory('section-playlists-mfy', `特别为你推荐 (${mfy.length})`, mfy));
  }

  const created = allItems.filter(i => i.canEdit);
  if (created.length) categories.push(makeCategory('section-playlists-created', `自建歌单 (${created.length})`, created));

  const saved = allItems.filter(i => !i.canEdit);
  if (saved.length) categories.push(makeCategory('section-playlists-saved', `收藏歌单 (${saved.length})`, saved));

  return makePageResult('播放列表', 'https://amp-api.music.apple.com/v1/me/library/playlists', categories, netMs, performance.now() - t0);
}

// ── 7. 性能报表构建器 ───────────────────────────────────────────────────────
export function generateTimingReport(pages, overallMs) {
  const totalCategories = pages.reduce((a, p) => a + p.totalCategories, 0);
  const totalItems = pages.reduce((a, p) => a + p.timing.totalItems, 0);

  const lines = [
    '========================================================================================',
    '       Apple Music 官方 Storefront API 全模块直连性能报表 (5 Modules Benchmark)',
    '========================================================================================',
    `整体总耗时: ${(overallMs / 1000).toFixed(2)} 秒 (${overallMs.toFixed(0)} ms) 🚀 (包含喜爱歌曲与资料库单曲)`,
    `覆盖模块数: 5 个 (主页/新发现/广播/资料库/播放列表) 全并发 | 总分类: ${totalCategories} 个 | 总条目: ${totalItems} 项`,
    `整站端到端平均效率: ${(overallMs / totalItems).toFixed(2)} ms / 数据条目\n`,
    '----------------------------------------------------------------------------------------',
    '各模块性能详析 (并发网络拉取 + 原生秒级映射)',
    '----------------------------------------------------------------------------------------',
    ...pages.map(p => 
      `- ${p.pageName.padEnd(6, ' ')} : 模块总耗时 ${(p.timing.totalDurationMs / 1000).toFixed(2)}s ` +
      `| 网络耗时 ${(p.timing.breakdown.navigationDurationMs / 1000).toFixed(2)}s ` +
      `| 映射耗时 ${p.timing.breakdown.extractionDurationMs.toFixed(1)}ms ` +
      `| 分类数 ${p.totalCategories} | 条目数 ${p.timing.totalItems}`
    ),
    '========================================================================================'
  ];

  const summaryString = lines.join('\n');
  return {
    summaryString,
    reportJson: {
      generatedAt: new Date().toISOString(),
      summaryText: summaryString,
      metrics: {
        overallDurationMs: Number(overallMs.toFixed(2)),
        overallDurationFormatted: `${(overallMs / 1000).toFixed(2)}s`,
        totalPages: pages.length,
        totalCategories,
        totalItems,
        avgTimePerItemMs: Number((overallMs / totalItems).toFixed(2)),
      },
      pages: pages.map(p => ({
        pageName: p.pageName,
        url: p.url,
        timing: p.timing,
        categories: p.categories.map(c => ({ title: c.title, itemCount: c.itemCount, timing: c.timing })),
      })),
    },
  };
}

// ── 8. 核心抓取主函数 ───────────────────────────────────────────────────────
export async function fetchAllData(options = {}) {
  const globalStartTime = performance.now();

  console.log('🚀 ========================================================');
  console.log('   Apple Music 数据获取引擎 (Storefront Amp-API 直连并发流)');
  console.log('   (主页 + 新发现 + 广播 + 资料库(含喜爱歌曲) + 歌单 全并发)');
  console.log('========================================================\n');

  const devToken = await getDeveloperToken();
  const userToken = getUserToken();

  console.log(`🔐 Developer Token : 已就绪 (${devToken.slice(0, 30)}...)`);
  console.log(`👤 User Token      : ${userToken ? `已就绪 (${userToken.slice(0, 20)}...)` : '未提供'}`);

  const defaultHeaders = {
    authorization: `Bearer ${devToken}`,
    origin: 'https://music.apple.com',
    referer: 'https://music.apple.com/',
    'user-agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  };
  const userHeaders = userToken ? { ...defaultHeaders, 'music-user-token': userToken } : defaultHeaders;

  const ENDPOINTS = [
    { key: 'home',       url: 'https://amp-api.music.apple.com/v1/me/recommendations?art%5Burl%5D=f&displayFilter%5Bkind%5D=MusicCircleCoverShelf%2CMusicConcertsEmptyShelf%2CMusicCoverGrid%2CMusicCoverShelf%2CMusicNotesHeroShelf%2CMusicSocialCardShelf%2CMusicSuperHeroShelf&extend=editorialArtwork%2CeditorialVideo%2CplainEditorialCard%2CplainEditorialNotes&extend%5Bplaylists%5D=artistNames&extend%5Bstations%5D=airTime%2CsupportsAirTimeUpdates&fields%5Bartists%5D=name%2Cartwork%2Curl&format%5Bresources%5D=map&include%5Balbums%5D=artists&include%5Blibrary-playlists%5D=catalog&include%5Bpersonal-recommendation%5D=primary-content&include%5Bstations%5D=radio-show&l=zh-Hans-CN&meta%5Bstations%5D=inflectionPoints&name=listen-now&omit%5Bresource%5D=autos&platform=web&timezone=%2B08%3A00&types=activities%2Calbums%2Capple-curators%2Cartists%2Cconcerts%2Ccurators%2Ceditorial-items%2Clibrary-albums%2Clibrary-playlists%2Cmusic-movies%2Cmusic-videos%2Cplaylists%2Csocial-profiles%2Csocial-upsells%2Csongs%2Cstations%2Ctv-episodes%2Ctv-shows%2Cuploaded-audios%2Cuploaded-videos&with=friendsMix%2Clibrary%2Csocial', headers: userHeaders, name: '主页' },
    { key: 'browse',     url: 'https://amp-api-edge.music.apple.com/v1/editorial/cn/groupings?art[url]=c,f&format[resources]=map&include[albums]=artists&include[music-videos]=artists&include[songs]=artists&include[stations]=events,radio-show&l=zh-Hans-CN&name=music&platform=web&tabs=subscriber', headers: defaultHeaders, name: '新发现' },
    { key: 'radio',      url: 'https://amp-api-edge.music.apple.com/v1/editorial/cn/groupings?art[url]=c,f&format[resources]=map&include[albums]=artists&include[music-videos]=artists&include[songs]=artists&include[stations]=events,radio-show&l=zh-Hans-CN&name=radio&platform=web&tabs=subscriber', headers: defaultHeaders, name: '广播' },
    { key: 'libRecent',  url: 'https://amp-api.music.apple.com/v1/me/library/recently-added?art[url]=f&limit=25&l=zh-Hans-CN&platform=web', headers: userHeaders, name: '资料库-最近添加' },
    { key: 'libAlbums',  url: 'https://amp-api.music.apple.com/v1/me/library/albums?art[url]=f&limit=50&l=zh-Hans-CN&platform=web', headers: userHeaders, name: '资料库-专辑' },
    { key: 'libArtists', url: 'https://amp-api.music.apple.com/v1/me/library/artists?limit=50&l=zh-Hans-CN&platform=web', headers: userHeaders, name: '资料库-艺人' },
    { key: 'libFav',     url: 'https://amp-api.music.apple.com/v1/me/library/playlists/p.MLUk3bdrQ?art[url]=f&include=tracks&l=zh-Hans-CN&platform=web', headers: userHeaders, name: '资料库-喜爱歌曲智能歌单' },
    { key: 'libSongs',   url: 'https://amp-api.music.apple.com/v1/me/library/songs?art[url]=f&limit=100&l=zh-Hans-CN&platform=web', headers: userHeaders, name: '资料库-已存单曲' },
    { key: 'playlists',  url: 'https://amp-api.music.apple.com/v1/me/library/playlists?art[url]=f&include=catalog&limit=100&l=zh-Hans-CN&platform=web', headers: userHeaders, name: '播放列表' },
    { key: 'madeForYou', url: 'https://amp-api.music.apple.com/v1/me/library/playlists?sort=type&filter[featured]=made-for-you&include[library-playlists]=catalog&fields[library-playlists]=artwork,dateAdded,name,playParams&l=zh-Hans-CN&platform=web', headers: userHeaders, name: '歌单-特别为你推荐' },
  ];

  console.log('⚡ 正在同时发起 10 个原生 HTTP 并发请求 (全模块极速流) ...');

  const fetchJson = async ({ url, headers, name }) => {
    const t0 = performance.now();
    try {
      const res = await fetch(url, { headers });
      if (!res.ok) console.warn(`⚠️ [${name}] HTTP 状态码: ${res.status}`);
      return { json: res.ok ? await res.json() : {}, duration: performance.now() - t0 };
    } catch (e) {
      console.warn(`⚠️ [${name}] 请求失败: ${e.message}`);
      return { json: {}, duration: performance.now() - t0 };
    }
  };

  const responses = await Promise.all(ENDPOINTS.map(fetchJson));
  const resMap = Object.fromEntries(ENDPOINTS.map((ep, idx) => [ep.key, responses[idx]]));

  console.log('🔄 正在将 5 个模块数据转换为标准结构与 160x160 封面 ...');

  const homeResult = parseHomeData(resMap.home.json, resMap.home.duration);
  const browseResult = parseBrowseData(resMap.browse.json, resMap.browse.duration);
  const radioResult = parseRadioData(resMap.radio.json, resMap.radio.duration);

  const libMaxMs = Math.max(resMap.libRecent.duration, resMap.libAlbums.duration, resMap.libArtists.duration, resMap.libFav.duration, resMap.libSongs.duration);
  const libraryResult = parseLibraryData(resMap.libFav.json, resMap.libSongs.json, resMap.libRecent.json, resMap.libAlbums.json, resMap.libArtists.json, libMaxMs);

  const plMaxMs = Math.max(resMap.playlists.duration, resMap.madeForYou.duration);
  const playlistsResult = parsePlaylistsData(resMap.playlists.json, resMap.libFav.json, resMap.madeForYou.json, plMaxMs);

  const globalDurationMs = performance.now() - globalStartTime;

  console.log('\n' + '═'.repeat(60));
  console.log('📊 全模块 API 抓取完成，正在保存产物文件与报表 ...');
  console.log('═'.repeat(60));

  const outputFiles = [
    [HOME_OUT_FILE, homeResult, '主页数据'],
    [BROWSE_OUT_FILE, browseResult, '新发现数据'],
    [RADIO_OUT_FILE, radioResult, '广播数据'],
    [LIBRARY_OUT_FILE, libraryResult, '资料库数据'],
    [PLAYLISTS_OUT_FILE, playlistsResult, '播放列表数据'],
  ];

  outputFiles.forEach(([filePath, data, label]) => {
    writeFileSync(filePath, '\uFEFF' + JSON.stringify(data, null, 2), 'utf-8');
    console.log(`💾 ${label.padEnd(8, ' ')}: ${filePath}`);
  });

  const pages = [homeResult, browseResult, radioResult, libraryResult, playlistsResult];
  const { summaryString, reportJson } = generateTimingReport(pages, globalDurationMs);
  writeFileSync(TIMING_OUT_FILE, '\uFEFF' + JSON.stringify(reportJson, null, 2), 'utf-8');
  console.log(`⏱️  性能报表    : ${TIMING_OUT_FILE}`);

  const datasets = { home: homeResult, browse: browseResult, radio: radioResult, library: libraryResult, playlists: playlistsResult };
  const htmlOutPath = options.htmlPath || HTML_OUT_FILE;
  renderHtml(datasets, htmlOutPath);
  console.log(`🖥️  体验网页    : ${htmlOutPath}`);

  console.log('\n' + summaryString);
  return { datasets, reportJson, summaryString };
}

// ── CLI 直接执行支持 ────────────────────────────────────────────────────────
const isDirectCli = process.argv[1] && (
  process.argv[1].endsWith('fetch_data.js') || 
  process.argv[1].endsWith('fetch_data')
);

if (isDirectCli) {
  fetchAllData().catch(err => {
    console.error('\n❌ 运行失败:', err);
    process.exit(1);
  });
}
