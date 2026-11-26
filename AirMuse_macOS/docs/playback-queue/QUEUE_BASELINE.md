# 源码基线

审计提交：[f494b09](https://github.com/xke123/AirMuse/commit/f494b09c35583065f4a9a7fdf7ecb4ca5314a982)，北京时间 2026-11-27 02:32；最新提交说明为搜索体验与艺人页面。下列结论来自静态代码，非运行验证。路径相对于 AirMuse_macOS/Sources。

| 文件 | 已观察事实 | 任务 |
|---|---|---|
| Domain/Models/PlaybackQueue.swift | tracks + currentIndex；shuffle 按 track ID 寻回当前 | 独立条目及确定顺序 |
| Playback/PlaybackCoordinatorV2.swift:105–139 | 会话变化且 nil 才 stop；playTrack 替换队列 | 隔离清理、区分新队列与内部推进 |
| 同文件:171–180 | stop 不清空 queue | 定义普通停止与账户失效 |
| 同文件:205–245 | 模式设置仅写 flag；prev 使用索引；已有读取快照 | 统一编辑、历史及订阅 |
| 同文件:306–405 | 事件检查 engine/operation；电台 itemChanged 重建歌曲 | 补齐会话及条目关联，保持电台来源 |
| 同文件:411–443 | 自然结束去重；随机每次抽选非当前曲目 | 每轮随机顺序、结束与手动推进语义 |
| 同文件:452–479 | 仅发布 PlaybackState，currentTrack 为 desiredTrack | 原子结构快照与确认态 |
| Playback/PlaybackStore.swift | 有 queue 属性但无 queue stream | 单一只读结构流 |
| Playback/PlaybackSnapshotStore.swift | schemaVersion 1，queueTracks/index、模式、账户；原子 JSON 写入 | 迁移与真实生命周期接入 |
| App/CompositionRoot.swift:22,54 | 已实例化快照 store | 复用，不建第二套 |
| App/AppLifecycleCoordinator.swift:352–356 | 系统媒体键调用协调器 | 保持同一语义；复核持久化接入 |
| UI/Player/PlayerWindowController.swift:141–155,211–225 | 主/迷你控制调用协调器 | 保持统一入口 |
| UI/Library/LibraryWindowController.swift:541–561,1553–1556,1731–1733,1831–1832 | 多个 MusicTrack 队列构造点 | 统一加入来源、精确条目身份 |
| UI/Library/LibraryContentView.swift:632–633,824–825,925–930 | 选择与播放全部回调传歌曲 | 增加带来源操作意图 |
| Providers/AppleMusic/AppleMusicAmpClient.swift:739–780 | 专辑/歌单方法默认 limit 100 | 追踪实际分页，不假设完整 |
| Providers/AppleMusic/Playback/AppleMusicWebEngine.swift:293–301 | song/album/playlist/station setQueue | 本地/远端所有权明确 |
| Domain/CoreV2/PlaybackContracts.swift | QueueOwner、EngineCommand、PlaybackOperationContext | 复用现有契约 |

源码链接前缀：https://github.com/xke123/AirMuse/blob/f494b09c35583065f4a9a7fdf7ecb4ca5314a982/AirMuse_macOS/Sources/

未确认：自动保存恢复完整接入、远端电台队列读写能力、真实无缝播放、SDK 玻璃效果、全部入口是否有后续提交。实施前重新检查当前 HEAD、git status、Package.swift、真实调用点、测试目标及平台最低版本，记录基线构建和测试命令及结果。
