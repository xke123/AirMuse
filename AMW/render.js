/**
 * Apple Music Web — 数据渲染模块 (render.js)
 * =====================================================================================
 * 职责：
 * 1. 接收全量结构化数据集 (Home / Browse / Radio / Library / Playlists)
 * 2. 生成 400x400 双栏自适应独立 HTML 文件 (index.html)
 * 3. 支持 CLI 独立执行：node render.js (直接基于本地已有 JSON 重新渲染界面)
 * 4. 支持模块化导出：renderHtml(datasets, outputPath)
 */

import { writeFileSync, readFileSync, existsSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const DEFAULT_OUT_HTML = resolve(__dirname, 'index.html');

/**
 * 从本地已有 JSON 读取数据集
 */
export function loadDatasetsFromFiles(baseDir = __dirname) {
  const readJson = (file) => {
    const fullPath = resolve(baseDir, file);
    if (!existsSync(fullPath)) return { categories: [] };
    try {
      const text = readFileSync(fullPath, 'utf-8').replace(/^\uFEFF/, '');
      return JSON.parse(text);
    } catch {
      return { categories: [] };
    }
  };

  return {
    home: readJson('apple_music_homepage.json'),
    browse: readJson('apple_music_browse.json'),
    radio: readJson('apple_music_radio.json'),
    library: readJson('apple_music_library.json'),
    playlists: readJson('apple_music_playlists.json'),
  };
}

/**
 * 渲染全功能 400x400 双栏交互式网页
 * @param {Object} datasets 包含 home, browse, radio, library, playlists
 * @param {string} outputPath 输出目标 HTML 文件绝对路径
 */
export function renderHtml(datasets, outputPath = DEFAULT_OUT_HTML) {
  const jsonStr = JSON.stringify(datasets);

  const html = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Apple Music - 400x400 全功能五模块</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: #09090b;
    color: #f5f5f7;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    display: flex;
    justify-content: center;
    align-items: center;
    min-height: 100vh;
    padding: 12px;
  }
  .window-container {
    width: 400px;
    height: 400px;
    background: #18181b;
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: 12px;
    box-shadow: 0 16px 36px rgba(0, 0, 0, 0.65), 0 0 0 1px rgba(255, 255, 255, 0.05);
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }
  .top-bar {
    height: 38px;
    background: #121214;
    border-bottom: 1px solid rgba(255, 255, 255, 0.08);
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 8px;
    user-select: none;
    flex-shrink: 0;
  }
  .window-controls {
    display: flex;
    gap: 6px;
    align-items: center;
  }
  .btn-circle {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    display: inline-block;
  }
  .btn-close { background: #ff5f57; }
  .btn-min { background: #febc2e; }
  .btn-max { background: #28c840; }

  .tab-group {
    display: flex;
    background: #27272a;
    border-radius: 6px;
    padding: 2px;
    gap: 2px;
  }
  .tab-btn {
    border: none;
    background: transparent;
    color: #a1a1aa;
    font-size: 11px;
    font-weight: 500;
    padding: 3px 6px;
    border-radius: 4px;
    cursor: pointer;
    transition: all 0.15s ease;
  }
  .tab-btn:hover { color: #f4f4f5; }
  .tab-btn.active {
    background: #fa2d48;
    color: #ffffff;
    box-shadow: 0 1px 4px rgba(250, 45, 72, 0.35);
  }

  .main-layout {
    display: flex;
    flex: 1;
    min-height: 0;
  }
  .sidebar {
    width: 130px;
    background: #141416;
    border-right: 1px solid rgba(255, 255, 255, 0.06);
    overflow-y: auto;
    overflow-x: hidden;
    padding: 6px;
    flex-shrink: 0;
  }
  .sidebar::-webkit-scrollbar { width: 3px; }
  .sidebar::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.15); border-radius: 2px; }

  .cat-item {
    font-size: 11px;
    color: #a1a1aa;
    padding: 6px 8px;
    border-radius: 5px;
    margin-bottom: 2px;
    cursor: pointer;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    display: flex;
    justify-content: space-between;
    align-items: center;
    transition: all 0.12s ease;
  }
  .cat-item:hover {
    background: rgba(255, 255, 255, 0.05);
    color: #ffffff;
  }
  .cat-item.active {
    background: rgba(250, 45, 72, 0.15);
    color: #fa2d48;
    font-weight: 600;
  }
  .cat-badge {
    font-size: 9px;
    color: #71717a;
    background: rgba(255, 255, 255, 0.06);
    padding: 1px 4px;
    border-radius: 3px;
    margin-left: 4px;
  }

  .content-panel {
    flex: 1;
    background: #18181b;
    display: flex;
    flex-direction: column;
    min-width: 0;
  }
  .cat-header {
    height: 32px;
    padding: 0 10px;
    background: rgba(24, 24, 27, 0.95);
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    display: flex;
    align-items: center;
    justify-content: space-between;
    font-size: 12px;
    font-weight: 600;
    color: #e4e4e7;
    flex-shrink: 0;
  }
  .badge-api {
    font-size: 9px;
    font-weight: normal;
    color: #34d399;
    background: rgba(52, 211, 153, 0.12);
    border: 1px solid rgba(52, 211, 153, 0.3);
    padding: 1px 5px;
    border-radius: 4px;
  }

  .cards-scroll {
    flex: 1;
    overflow-y: auto;
    padding: 8px 10px;
    display: flex;
    flex-direction: column;
    gap: 7px;
  }
  .cards-scroll::-webkit-scrollbar { width: 4px; }
  .cards-scroll::-webkit-scrollbar-thumb { background: rgba(255,255,255,0.18); border-radius: 2px; }

  .item-card {
    display: flex;
    gap: 8px;
    padding: 6px;
    background: #202024;
    border: 1px solid rgba(255, 255, 255, 0.04);
    border-radius: 6px;
    text-decoration: none;
    color: inherit;
    align-items: center;
    transition: background 0.12s, transform 0.1s;
  }
  .item-card:hover {
    background: #27272a;
    transform: translateY(-1px);
    border-color: rgba(255, 255, 255, 0.09);
  }
  .item-thumb {
    width: 44px;
    height: 44px;
    border-radius: 5px;
    object-fit: cover;
    background: #27272a;
    flex-shrink: 0;
  }
  .item-body {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
    justify-content: center;
    gap: 1px;
  }
  .item-eyebrow {
    font-size: 9px;
    color: #fa2d48;
    font-weight: 500;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .item-title {
    font-size: 11px;
    font-weight: 600;
    color: #f4f4f5;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .item-sub {
    font-size: 10px;
    color: #a1a1aa;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .type-pill {
    font-size: 9px;
    padding: 2px 5px;
    border-radius: 3px;
    flex-shrink: 0;
  }
  .type-song { background: rgba(59, 130, 246, 0.2); color: #60a5fa; }
  .type-fav-song { background: rgba(244, 63, 94, 0.2); color: #fb7185; font-weight: 600; }
  .type-album { background: rgba(168, 85, 247, 0.2); color: #c084fc; }
  .type-playlist { background: rgba(236, 72, 153, 0.2); color: #f472b6; }
  .type-station { background: rgba(234, 179, 8, 0.2); color: #facc15; }
  .type-editorial { background: rgba(34, 197, 94, 0.2); color: #4ade80; }
  .type-artist { background: rgba(20, 184, 166, 0.2); color: #2dd4bf; }
  .type-default { background: rgba(113, 113, 122, 0.2); color: #a1a1aa; }

  .empty-tip {
    font-size: 11px;
    color: #71717a;
    text-align: center;
    margin-top: 40px;
  }
</style>
</head>
<body>

<div class="window-container">
  <div class="top-bar">
    <div class="window-controls">
      <span class="btn-circle btn-close"></span>
      <span class="btn-circle btn-min"></span>
      <span class="btn-circle btn-max"></span>
    </div>
    <div class="tab-group">
      <button class="tab-btn active" id="tabHome" data-tab="home">主页</button>
      <button class="tab-btn" id="tabBrowse" data-tab="browse">新发现</button>
      <button class="tab-btn" id="tabRadio" data-tab="radio">广播</button>
      <button class="tab-btn" id="tabLibrary" data-tab="library">资料库</button>
      <button class="tab-btn" id="tabPlaylists" data-tab="playlists">歌单</button>
    </div>
  </div>

  <div class="main-layout">
    <div class="sidebar" id="sidebar"></div>
    <div class="content-panel">
      <div class="cat-header">
        <span id="curCatName">板块明细</span>
        <span class="badge-api">Amp-API 160px</span>
      </div>
      <div class="cards-scroll" id="cardsScroll"></div>
    </div>
  </div>
</div>

<script>
  const DATASETS = ${jsonStr};

  const TYPE_NAMES = {
    song: '单曲',
    'fav-song': '喜爱',
    album: '专辑',
    playlist: '歌单',
    station: '电台',
    editorial: '精选',
    artist: '艺人',
    item: '推荐',
    default: '条目'
  };

  let currentTab = 'home';
  let activeIndex = 0;

  const sidebar = document.getElementById('sidebar');
  const curCatName = document.getElementById('curCatName');
  const cardsScroll = document.getElementById('cardsScroll');

  const tabs = {
    home: document.getElementById('tabHome'),
    browse: document.getElementById('tabBrowse'),
    radio: document.getElementById('tabRadio'),
    library: document.getElementById('tabLibrary'),
    playlists: document.getElementById('tabPlaylists')
  };

  Object.entries(tabs).forEach(([key, btn]) => {
    btn.onclick = () => {
      if (currentTab === key) return;
      currentTab = key;
      activeIndex = 0;
      Object.values(tabs).forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      render();
    };
  });

  function getCurrentDataset() {
    return DATASETS[currentTab] || { categories: [] };
  }

  function render() {
    const dataset = getCurrentDataset();
    sidebar.innerHTML = '';

    dataset.categories.forEach((cat, idx) => {
      const el = document.createElement('div');
      el.className = 'cat-item' + (idx === activeIndex ? ' active' : '');
      el.title = cat.title;

      const titleSpan = document.createElement('span');
      titleSpan.innerText = cat.title;
      titleSpan.style.overflow = 'hidden';
      titleSpan.style.textOverflow = 'ellipsis';
      el.appendChild(titleSpan);

      const badge = document.createElement('span');
      badge.className = 'cat-badge';
      badge.innerText = cat.itemCount;
      el.appendChild(badge);

      el.onclick = () => {
        activeIndex = idx;
        renderSidebarActive();
        renderContent();
      };
      sidebar.appendChild(el);
    });

    renderContent();
  }

  function renderSidebarActive() {
    Array.from(sidebar.children).forEach((child, i) => {
      child.className = 'cat-item' + (i === activeIndex ? ' active' : '');
    });
  }

  function renderContent() {
    const dataset = getCurrentDataset();
    const cat = dataset.categories[activeIndex];
    if (!cat) return;

    curCatName.innerText = cat.title;
    cardsScroll.innerHTML = '';
    if (!cat.items || !cat.items.length) {
      cardsScroll.innerHTML = '<div class="empty-tip">该分类暂无明细条目</div>';
      return;
    }

    const fallbackImg = "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='40' height='40' viewBox='0 0 40 40'%3E%3Crect width='40' height='40' fill='%232c2c2e'/%3E%3Ctext x='50%25' y='50%25' dominant-baseline='middle' text-anchor='middle' font-family='sans-serif' font-size='16' fill='%23636366'%3E🎵%3C/text%3E%3C/svg%3E";

    cat.items.forEach(item => {
      const a = document.createElement('a');
      a.className = 'item-card';
      a.href = item.linkUrl || '#';
      a.target = item.linkUrl ? '_blank' : '_self';

      const typeKey = (item.type || 'default').toLowerCase();
      const typeLabel = TYPE_NAMES[typeKey] || item.type || '条目';
      const tagClass = 'type-' + (TYPE_NAMES[typeKey] ? typeKey : 'default');

      const img = document.createElement('img');
      img.className = 'item-thumb';
      img.src = item.artworkUrl || fallbackImg;
      img.onerror = function() { this.src = fallbackImg; };
      a.appendChild(img);

      const body = document.createElement('div');
      body.className = 'item-body';

      if (item.eyebrow) {
        const eye = document.createElement('div');
        eye.className = 'item-eyebrow';
        eye.innerText = item.eyebrow;
        body.appendChild(eye);
      }

      const title = document.createElement('div');
      title.className = 'item-title';
      title.innerText = item.title || '未知名称';
      body.appendChild(title);

      const sub = document.createElement('div');
      sub.className = 'item-sub';
      sub.innerText = item.subtitle || 'Apple Music';
      body.appendChild(sub);

      a.appendChild(body);

      const pill = document.createElement('span');
      pill.className = 'type-pill ' + tagClass;
      pill.innerText = typeLabel;
      a.appendChild(pill);

      cardsScroll.appendChild(a);
    });

    cardsScroll.scrollTop = 0;
  }

  render();
</script>
</body>
</html>`;

  writeFileSync(outputPath, '\uFEFF' + html, 'utf-8');
  return outputPath;
}

// ── CLI 直接执行支持 ────────────────────────────────────────────────────────
const isDirectCli = process.argv[1] && (
  process.argv[1].endsWith('render.js') || 
  process.argv[1].endsWith('render')
);

if (isDirectCli) {
  console.log('🎨 正在从本地已提取的 JSON 数据渲染 400x400 网页 (index.html) ...');
  const datasets = loadDatasetsFromFiles(__dirname);
  const outPath = renderHtml(datasets, DEFAULT_OUT_HTML);
  console.log(`✅ 渲染完成！网页已生成: ${outPath}`);
}
