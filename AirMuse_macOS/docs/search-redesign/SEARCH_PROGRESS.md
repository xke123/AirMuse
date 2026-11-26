# AirMuse 搜索栏重构 — 进度追踪（Progress）

## 当前总览
- **当前阶段**：S01–S07 代码实现与单元测试完成，等待实机在线 AMP 接口与双模式视觉回归验收。
- **总体进度**：7 / 8 `TESTED`，1 / 8 `IN_PROGRESS`

| 任务 ID | 状态 | 负责人 / 会话 | 变更文件 | 验证证据 | 备注 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| S01 | `TESTED` | Agent | `SearchHistoryStore.swift` | `SearchRedesignTests.testSearchHistoryStore` | 上限 5 条、去重置顶、单删、全清 |
| S02 | `TESTED` | Agent | `MusicSearchResult.swift`, `AppleMusicAmpClient.swift`, `AppleMusicProvider.swift` | `SearchRedesignTests.testDynamicSearchSectionModels` | `with=topResults`、`meta.results.order`、`limit=25`、`fetchSearchPage` |
| S03 | `TESTED` | Agent | `LibraryTopBarView.swift` | `SearchRedesignTests.testTopBarDefaultScopeAndExpandPopover` | `makeKey` 自动聚焦、`[Apple Music \| 资料库]` 开关、`Esc`/`Enter` |
| S04 | `TESTED` | Agent | `SearchHistoryExpandView.swift`, `LibraryWindowController.swift` | `SearchRedesignTests.testTopBarDefaultScopeAndExpandPopover` | `NSGlassEffectContainerView` + `NSGlassEffectView` 历史浮层 |
| S05 | `TESTED` | Agent | `LibraryContentView.swift`, `LibraryWindowController.swift` | `SearchRedesignTests.testContentViewThreeColumnsAndAppend` | 3 栏类别浏览网格与点击钻取 |
| S06 | `TESTED` | Agent | `LibraryWindowController.swift` | `swift test --filter "SearchRedesignTests\|Motion"` | 搜索结果恢复双栏、动态左边栏、默认「最佳结果」 |
| S07 | `TESTED` | Agent | `LibraryContentView.swift`, `LibraryWindowController.swift` | `SearchRedesignTests.testContentViewThreeColumnsAndAppend` | 滚到底部 `next` 25 条分页 + `onArtistSelected` 预留 |
| S08 | `IN_PROGRESS` | Agent | `SearchRedesignTests.swift` | 42 tests in 6 suites passed | 待实机在线账号验证真实 AMP 响应与 UI 观感 |

---

## 里程碑日志
- **2026-11-26（下午）**：完成 S01–S07 代码实现与 `SearchRedesignTests`（`swift test --filter "SearchRedesignTests|Motion"` 6 个套件 42 项测试全部通过）。
- **2026-11-26**：完成与现有代码（`LibraryTopBarView`、`LibraryWindowController`、`LibraryContentView`、`AppleMusicAmpClient`）的对比分析与重构方案确认，建立 `docs/search-redesign/` 项目管理文档。
