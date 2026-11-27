# PO — 源码基线与缺陷证据

参考 `main` `99466ff7853e6c3cfe88bf41159a23768b12b558`，提交 `feat(media-actions): stabilize media actions, Liquid Glass detail header/menu, batch state queries & SWR cache`。静态核对时间为 2026-11-27；不是已实施本期的证明。以下路径相对 `AirMuse_macOS/Sources/`，行号以此 SHA 为准。链接根： https://github.com/xke123/AirMuse/tree/99466ff7853e6c3cfe88bf41159a23768b12b558/AirMuse_macOS/Sources 。

| ID | 证据 | 风险与本期要求 |
|---|---|---|
| B01 | Domain/Models/PlaybackOrigin.swift 7–84：11 kind、sourceID/title/isLibrary/providerID/artworkURL；canNavigate 只支持 album/playlist/artist | 缺分类/搜索/电台种子目标；兼容扩展，真实目标驱动导航 |
| B02 | UI/Library/LibraryWindowController.swift 2137–2153：搜索 nil ID，library/forYou/browse 泛称，tab 2 直接标 station | 来源不准确；按真实页面资源与分类捕获，不能把普通歌曲标电台 |
| B03 | 同文件 1735–1776：song/radio/chart 共分支遍历 displayedItems，radio 指定 kind station | 可能构造混合/虚假远端待播；拆分卡片入口，电台仅一个真实目标，普通仅可播放歌曲 |
| B04 | Playback/PlaybackCoordinatorV2.swift 311–375：根据前缀或 origin.kind 推断 station，remote 不检查单个目标 | 最终隔离域强制显式真实 kind、单一远端目标；来源与播放类型分离，禁止混入 |
| B05 | Playback/QueueManager.swift 315–420：owner/caps 先换，confirmedCurrent=nil；515–565 remote itemChanged 保留 UUID，设置 phase playing | 切换阶段投影要区分 pending 与 confirmed；元数据更新不得凭自身确认真实播放/暂停；实际曲目标识单独变化 |
| B06 | Playback/PlaybackCoordinatorV2.swift 1102–1148：远端更新缺字段沿用旧 artist/album/art/duration | 新曲目不继承旧关系；缺字段未知，按需补全，过期结果作废 |
| B07 | Domain/Models/QueueCapabilities.swift：remoteStationDefault.canRead=false、canSkipNext=true；Coordinator 545–610 remote next 未显示能力 guard，previous 有 guard | 直播/未知类型保守；统一 transport 能力，最终协调器与所有控制入口检查 |
| B08 | UI/Library/PlaybackQueue/LiquidFusionQueueDockView.swift 1035–1103：remote 分支固定“电台自动续播中”，优先于 pending failure，普通 toolbar 灰态 | 改模式化面板，连接/暂停/失败优先，未知数量不冒充空列表 |
| B09 | LibraryWindowController.swift 2496–2530：确认“建立队列”仍 submitIntent(.replaceAndPlay)；2480–2481 集合路径仅提示 | 全部入口统一确认及真正 stage-only 原子操作；失败可见，取消不改变会话 |
| B10 | LibraryWindowController.swift 709–724：仅 album/playlist/artist 跳转；MediaActionResolver.swift 227–290 已有去重 | 复用去重，纯导航与播放分离；电台详情能力和真实广播入口验证，不通过 radio 卡片点击 |
| B11 | Playback/PlaybackStore.swift 28–39、132–142：原子 commit、低频 queueStream；Coordinator pause 458–472 只发状态 | 复用状态源，transport 低频投影保持一致，不能只读可能过期的 queue phase |
| B12 | Playback/QueueManager.swift 1165–1218：export currentEntryID=activeTargetEntry；PlaybackSnapshotStore.swift 50–115：v2 电台目标迁移、v1 unknown | 验证 pending 不冒充 confirmed、恢复不以歌曲 ID 当 station ID；新字段兼容 |
| B13 | LiquidFusionQueueDockView.swift 172、203–205、445–487：单玻璃 view，24pt，10pt，当前高度 65% | 增加同容器独立来源胶囊，50%/70% 约束，电台面板内容自适应 |
| B14 | Domain/Models/MusicStation.swift 有 isLive；WebEngine.swift 293–313 station setQueue；未看到已证实的完整远端队列读取能力 | 复用 station 模型与真实目标，不凭假设开启能力；验证直播与算法电台差别 |

## 已有能力（勿重建）
QueueEntry 独立 identity；QueueSnapshot owner/activeTarget/confirmedCurrent/pendingTarget/capabilities/loading；QueueManager 与协调器；五种 submitIntent；分页与 epoch；现有资源菜单、目录/资料库身份与内部导航；原生玻璃容器；状态缓存与批量查询。实际目录、接口名称变化以工作区核验为准。

## 已有报告与限制
`docs/media-actions-stabilization/MAS_PROGRESS.md` 报告 161 tests passed、真实账户资料库/收藏和歌曲电台验证；这属于仓库自述，本次未独立运行。当前文档没有修改仓库、运行 macOS、验证实际电台或原生融合。PO00 要重新复核上述 B01–B14；若已解决用测试关闭，不重复改造。
