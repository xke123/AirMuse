# 源码基线与缺陷台账

静态审查参考：[ccd3102](https://github.com/xke123/AirMuse/commit/ccd3102a5ddaa86785a645b1e000b9afce47a38c)，北京时间 2026-11-27 06:12:12。与 d794fc2 比较 30 个文件变更。本次文档不代表独立编译、实机或真实账号验证；仓库进度自报的测试结果不是本次实测。行号以参考提交为准，实际 HEAD 复核后记录差异。下列路径均相对 `AirMuse_macOS/`。

## 核心问题（BUG01–15）
| ID | 优先级 | 证据/风险 | 修复验收 |
|---|---|---|---|
| BUG01 | P0 | `Sources/Providers/AppleMusic/AppleMusicProvider.swift:432–512`：资料库写能力 false，add/remove 直接 unsupported；收藏仅 artist，歌曲电台 false。确定的交付缺口。 | 真实授权验证及逐类型能力；未验证不开放。 |
| BUG02 | P0 | `Sources/UI/Library/LibraryWindowController.swift:2517–2533` 另有硬编码能力，与 Provider 重复。 | Provider 能力快照唯一；UI 合并队列上下文。 |
| BUG03 | P0 | `Sources/Providers/MediaActions/MediaResourceStateStore.swift:175–188,249–264` 整体覆盖 receipt.state；部分响应会丢另一字段或 pending。 | 字段级补丁、版本守卫。 |
| BUG04 | P0 | 同文件 152–205,227–282：effectiveBool 可能是 pending target 而非 confirmed；过期操作正常返回状态。 | 真实确认值、明确 superseded、失败/超时正确反馈。 |
| BUG05 | P0 | 同文件 116–138,196–202,272–278,295–311：读请求无字段 revision；超时核对后未重验 op。 | 旧读/旧核对不能覆盖新写；相同请求共享合并结果。 |
| BUG06 | P0 | `LibraryWindowController.swift:608–639,2080–2128,2206–2308`：详情播放菜单仅传当前 tracks，卡片路径分页。 | 完整资源解析；350 首集合不同入口等价。 |
| BUG07 | P0 | 同文件 2000–2029,2326–2344,2594–2627：艺人歌曲/电台请求后才注册意图或未注册。 | 点击时注册，提交时原子验明最新意图。 |
| BUG08 | P0 | 同文件 2130–2160：等待前序任务后才读快照；可能捕获新队列。 | 冻结目标队列和作用域，清空/替换后拒绝旧编辑。 |
| BUG09 | P0 | 同文件 2169 等调用反馈；`Tests/PlaybackTests/MediaActionPlaybackTests.swift:160–175` 明确接受数不等于真实播放。 | 命令接受、引擎确认、失败各自反馈。 |
| BUG10 | P0（写前置） | `LibraryWindowController.swift:2441–2514` 无条件赋 catalogID/libraryID，身份混用风险。 | 真实映射、类型校验，缺失则不可写。 |
| BUG11 | P0（写前置） | 同文件 2435–2439 所有权靠前缀及默认 platform。 | 可信元数据；未知默认只读；删除目标强校验。 |
| BUG12 | P1 | 同文件 2629–2635 忽略 isLibrary；`Sources/Domain/Models/MediaActionResolver.swift:243–260` 来源/专辑可重复。 | 导航保留作用域，真实身份去重。 |
| BUG13 | P1 | `MediaResourceStateStore.swift:31–35,130,210–211,285–286,314–325` 辅助字典无完成清理；defer 无 task 身份校验；FIFO 可淘汰 pending。 | 在途身份登记与安全清理，缓存/任务有界。 |
| BUG14 | P1 | `LibraryWindowController.swift:134–149` observer 主要更新当前艺人；其他 UI 缺完整联动。 | 同资源跨界面一致、局部刷新。 |
| BUG15 | P2 | 同文件 2277–2308：整批等待，100 页上限/游标重复后仍提交部分集合。部分提交为确定风险；渐进优化为建议。 | 不伪称全量；非随机可渐进并保序，无法安全渐进则保留整批加载。 |

## UX/附加回归
| ID | 优先级 | 证据/风险 | 修复 |
|---|---|---|---|
| UX01 | P1 | `LibraryWindowController.swift:529,1883–1906` 艺人顶部仍独立 playEntries、try?。 | 五种动作统一，错误可见，严格热门歌曲。 |
| UX02 | P1 | 同文件 592–670,1792：菜单只读缓存，未见 refreshState 接线，初始收藏可能一直 unknown。 | 首次必要读、已有状态填充、失败可重试。 |
| UX03 | P1 | Provider 写能力未实现，专辑/平台歌单一级操作不完整。 | 已验证后统一快捷按钮与菜单状态。 |
| UX04 | P1 | 同文件 693–695 队列 onReportError 仅日志。 | 真实失败统一反馈，避免双 Toast。 |
| UX05 | P0 | `Sources/UI/Library/MediaActions/MediaPlayCapsuleMenu.swift:107–121` 空/nil 描述默认 replaceAndPlay。 | 不可用无副作用。 |
| UX06 | P1 | 同文件 168–292 独立 Panel、局部事件监听、渐显；实机失焦/边界/反转风险。 | 生命周期、目标冻结、焦点及屏幕验证；真实形变需实机。 |
| UX07 | P2 | `Sources/UI/Library/PlaybackQueue/LiquidFusionQueueDockView.swift:795–1018,1148+` 多类光环音符/Toast；潜在快速操作叠加。 | 反馈合并、有界图层/任务、Reduce Motion。 |
| UX08 | P1 | `Sources/App/AppDelegate.swift:56–60` 遍历非 Panel 窗口恢复；可能误开辅助窗口或跳过真实舞台。 | 窗口管理层明确恢复唯一舞台。 |

## 补充审查入口（待复核，不标为已证实缺陷）
- `AppleMusicProvider.setFavorite` 502–507：写后查询失败回退 enabled，可能以预期状态冒充真实状态；检查 `fetchArtistDetail` 缓存及读回权限/语义。`AppleMusicAmpClient.swift:865–915` 评级查询失败是否被默认 false 掩盖、library artist ID 是否解析成 catalog ID。
- `LibraryWindowController.swift:418–451,1942–1980`：同一账号重新登录、A→B→A 的 session generation，旧 artist header rollback/Toast 是否跨 scope；旧界面是否仍可操作。菜单 callback 在触发时引用 currentDetailOrigin，核查页面切换。
- 过期专辑请求在 generation 检查前先 cancel 分页（2242–2244）；shuffle 路径 await cancel 后也需再验证。批量任务取消、错误、空集合与重复点击的状态清理。
- 队列右键、拖拽、清空、分页重试、模式开关、快照恢复、历史及远端电台应复用已实现契约并回归；检查旧命令结果与新快照的关联、可用能力与实际队列状态是否一致。
- `MusicTrack.swift` 新增关系字段与旧快照 decode 兼容；检查曲目关系 API 是否真实返回；没有关系时按需查询，不编造。

## 已有实现（禁止重建）
`Domain/Models/MediaActions.swift`, `MediaActionResolver.swift`, `Domain/Protocols/MediaResourceMutationProvider.swift`, `Providers/MediaActions/MediaResourceStateStore.swift`, `PlaybackCoordinatorV2.submitIntent`, `QueueInsertionIntent` 五种意图、`QueueCommandResult`, `QueueManager`, `QueuePaginationLoader`, `MediaContextMenuBuilder`, `MediaPlayCapsuleMenu`, `LiquidFusionQueueDockView`。沿用现有测试套件。进度文档 MA06/07/09 自报 PENDING_INTEGRATION；不可将其改成 VERIFIED 而不补真实证据。
