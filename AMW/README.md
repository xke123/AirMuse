# Apple Music Web 极速结构化数据提取器 (AMW)

独立、完整且高效的 Apple Music Web 官方 Storefront Amp-API 直连采集引擎与 400x400 双栏展示界面。

---

## 🎯 核心架构与拆分设计

本项目采用**数据获取**与**数据渲染**完全解耦的架构，零第三方 npm 依赖（仅依赖 Node.js 18+ 原生能力）：

```
e:\Codes\Github\AirMuse\AMW\
├── fetch_data.js          # 【数据获取模块】：API 鉴权、10路异步全并发网络采集、数据清洗与归一化
├── render.js              # 【数据渲染模块】：独立/模块化 400x400 视窗与双栏交互网页渲染器
├── index.html             # 【终端产物】：400x400 独立单文件体验网页 (五大标签切换、无跨域、内嵌数据)
├── apple_music_homepage.json   # 主页数据 (18 分类, 176 项)
├── apple_music_browse.json     # 新发现数据 (17 分类, 287 项)
├── apple_music_radio.json      # 广播数据 (8 分类, 95 项)
├── apple_music_library.json    # 资料库数据 (喜爱歌曲 100 首明细, 已存歌曲, 最近添加, 专辑, 艺人)
├── apple_music_playlists.json  # 播放列表数据 (置顶喜爱歌曲, 特别为你推荐 16 个智能混音, 自建, 收藏)
├── timing_report.json          # 全链路毫秒级性能计时报表
├── auth.json                   # 登录凭据 (包含 media-user-token Cookie)
└── .apple_dev_token.cache      # 官方 Developer Bearer Token 缓存 (自动刷新)
```

---

## ⚡ 核心能力与五大模块矩阵

1. **【主页 (Home)】**：
   - 提取主页 **18 个分类板块**，共计 **176 项**；
   - 涵盖专属推荐、最近播放、最新发行、专属流派电台与精选歌单。

2. **【新发现 (Browse)】**：
   - 提取全球与华语新发现 **17 个分类板块**，共计 **287 项**；
   - 涵盖精品推荐、新歌精选、本周新发行、新近发布、歌单已更新等。

3. **【广播 (Radio)】**：
   - 提取广播 **8 个分类板块**，共计 **95 项**；
   - 涵盖精品电台推荐、风格电台、热门电台与艺人电台。

4. **【资料库 (Library)】**：
   - **喜爱歌曲 (智能歌单)**：提取系统官方智能歌单 `p.MLUk3bdrQ` 的 **100 首喜爱单曲明细**（歌名、歌手、所属专辑、格式化时长、160x160 官方封面、播放参数与专属粉色「喜爱」徽章）；
   - **已存歌曲**：提取资料库前 100 首单曲，并标注资料库总歌单数（**13,830** 首单曲）；
   - **最近添加** (25 项)、**已存专辑** (50 张)、**关注艺人** (50 位)。

5. **【播放列表 (Playlists)】**：
   - **置顶喜爱歌单**：在所有歌单列表第一位展示官方红星标志的「喜爱歌曲」智能歌单；
   - **特别为你推荐 (Made For You)**：提取 16 张官方定制/智能推荐歌单（《爱不释耳 (Favorites Mix)》、《放松歌单》、《能量充电》、《你的精选集》、《音乐新发现》及 2016-2025 历年音乐回忆）；
   - **自建歌单**与**收藏歌单**分类展示。

---

## 📋 数据结构契约规范 (Data Schema)

各模块生成的 JSON 文件（如 [apple_music_library.json](file:///e:/Codes/Github/AirMuse/AMW/apple_music_library.json)）遵循统一的数据结构，便于客户端（如 C++ `AppleMusicAdapter`）直接消费：

```json
{
  "pageName": "资料库",
  "url": "https://amp-api.music.apple.com/v1/me/library",
  "capturedAt": "2026-11-18T02:56:27.123Z",
  "totalCategories": 5,
  "categories": [
    {
      "id": "section-library-favorites",
      "title": "喜爱歌曲 (113 首)",
      "itemCount": 100,
      "items": [
        {
          "id": "i.MoxZoqlIk3bdrQ",
          "title": "If You Want Me",
          "subtitle": "陈霓 · 渐强",
          "eyebrow": "喜爱 · 3:31",
          "type": "fav-song",
          "artworkUrl": "https://is1-ssl.mzstatic.com/image/.../160x160bb.webp",
          "linkUrl": "https://music.apple.com/cn/song/1443086079",
          "durationMs": 211952,
          "durationFormatted": "3:31",
          "playParams": {
            "id": "i.MoxZoqlIk3bdrQ",
            "catalogId": "1443086079",
            "kind": "song",
            "isLibrary": true
          }
        }
      ]
    }
  ]
}
```

---

## 🌐 官方 Storefront Amp-API 端点映射

| 业务板块 | 请求方式 | 官方 Amp-API 端点 | 鉴权头 |
| :--- | :--- | :--- | :--- |
| **主页个性化推荐** | `GET` | `/v1/me/recommendations?name=listen-now` | DevToken + UserToken |
| **新发现全球/华语** | `GET` | `/v1/editorial/cn/groupings?name=music` | DevToken |
| **广播与电台** | `GET` | `/v1/editorial/cn/groupings?name=radio` | DevToken |
| **资料库 - 最近添加** | `GET` | `/v1/me/library/recently-added?limit=25` | DevToken + UserToken |
| **资料库 - 已存专辑** | `GET` | `/v1/me/library/albums?limit=50` | DevToken + UserToken |
| **资料库 - 关注艺人** | `GET` | `/v1/me/library/artists?limit=50` | DevToken + UserToken |
| **资料库 - 喜爱歌曲** | `GET` | `/v1/me/library/playlists/p.MLUk3bdrQ?include=tracks` | DevToken + UserToken |
| **资料库 - 已存单曲** | `GET` | `/v1/me/library/songs?limit=100` | DevToken + UserToken |
| **歌单 - 所有播放列表** | `GET` | `/v1/me/library/playlists?limit=100` | DevToken + UserToken |
| **歌单 - 为你推荐 (混音)**| `GET` | `/v1/me/library/playlists?filter[featured]=made-for-you` | DevToken + UserToken |

---

## 🚀 性能测算基准 (全并发直出)

- **总耗时**：约 **1.5 ~ 2.0 秒**（10 路 HTTP 并发流同时拉取）
- **纯内存数据解析耗时**：**0.1ms ~ 0.4ms / 模块**
- **覆盖规模**：**5 大模块** | **52 个分类板块** | **1,101 项条目**
- **整站平均效率**：**~1.5 ms / 数据项**
- **缩略图标准化**：统一为 `160x160` WebP 格式，单图约 5~7KB，兼顾清晰度与极致流畅度。

---

## 🛠️ 运行方式

```bash
# 1. 抓取全量数据并自动生成 index.html
npm start
# 或
node fetch_data.js

# 2. 仅基于本地已有 JSON 重新渲染 index.html（调样式或无网调试用）
npm run render
# 或
node render.js
```

---

## 🖥️ 400x400 体验网页

双击打开 [index.html](file:///e:/Codes/Github/AirMuse/AMW/index.html) 即可体验：
- 顶部 `[ 主页 ] [ 新发现 ] [ 广播 ] [ 资料库 ] [ 歌单 ]` 五标签秒级切换；
- 左侧分类导航条带实时条目数徽章；
- 右侧独立滚动卡片列表，支持直达 Apple Music 播放链接。
