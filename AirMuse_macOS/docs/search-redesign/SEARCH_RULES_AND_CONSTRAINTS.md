# AirMuse 搜索栏重构 — 规则与工程约束

## 1. 架构与模块边界规则
- **数据层与 UI 层分离**：
  - 搜索结果模型（`MusicSearchResult`、`SearchSection`、`SearchCategory`、`next` 游标）定义在 `Domain`，不依赖 `AppKit`。
  - 网络请求与 JSON 解析（`with=topResults`、`meta.results.order`、`next` 分页）封装在 `AppleMusicAmpClient` 与 `AppleMusicProvider`，UI 层不直接拼装 URL 或解析原始字典。
- **不破坏既有业务与播放链路**：
  - 搜索态切换、分类切换、分页加载与浮层展开/收起不得中断当前播放，也不得触发非必要的 WebKit 重建。
  - 搜索历史持久化使用独立 `UserDefaults` Key，不污染播放状态、账号会话或舞台窗口锚点数据。
- **动态分类硬性约束**：
  - 严禁在前端硬编码固定顺序或固定集合的搜索结果分类；左侧边栏条目必须完全由当次搜索返回的非空结果及 `meta.results.order` 驱动。

---

## 2. 并发、状态与生命周期约束
- **Swift 6 严格并发**：所有 UI 控件与控制器保持 `@MainActor` 隔离；后台解析结果通过 `Sendable` 模型传回主线程，禁止滥用 `@unchecked Sendable`。
- **世代隔离（Latest-Intent-Wins）**：
  - 所有搜索请求、范围切换与分页加载均需绑定并校验 `searchGeneration`。
  - 切换关键词、切换 `Apple Music / 资料库` 范围或退出搜索模式时，立即取消在途 `Task`，丢弃过期回调，禁止旧结果覆盖新状态。
- **分页防重入**：同一分类同一 `next` 游标在同一时间只允许一个在途分页请求，加载中/已完成/失败状态需明确隔离，避免滚动到底部时重复并发拉取。

---

## 3. 视觉、Liquid Glass 与辅助功能约束
- **双模式与透明辅助适配**：
  - Enhanced 模式下，搜索栏与历史 Expand 浮层使用原生 `NSGlassEffectContainerView` + `NSGlassEffectView`。
  - Original 模式或系统开启 **Reduce Transparency** 时，自动切换为清晰的半透明深色回退背景与细边框，保证文字与删除按钮对比度。
  - 系统开启 **Reduce Motion** 时，搜索栏切换、浮层展开/收起及面板显隐跳过弹簧/淡入淡出过渡，直接落位。
- **命中隔离与可访问性**：
  - 搜索历史浮层隐藏或收起时，`isHidden = true` 且不拦截下方类别浏览卡片的点击与滚动。
  - 搜索框获得焦点时，保持 `PlayerWindow` 键盘输入畅通，不与播放器全局快捷键冲突。

---

## 4. 性能约束
- **分页预算**：每页严格按 `25` 条加载，禁止一次性拉取超大 `limit` 导致主线程排版卡顿。
- **零卡片级 `NSGlassEffectView`**：3 栏类别浏览卡片与搜索结果卡片/列表行继续遵循 `LibraryContentView` 既有规范，不得为每张卡片创建独立 `NSGlassEffectView`。
- **图片与缓存**：封面图沿用异步解码与缓存机制，不阻塞主线程滚动。
