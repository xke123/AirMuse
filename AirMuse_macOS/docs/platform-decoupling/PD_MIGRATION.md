# PD — 迁移计划与兼容策略

## 原则
以小步可构建迁移为主，不搬空旧模块后再补功能。首先新增等价通用契约及测试，再逐条迁移实际生产调用链，最后移除旧路径和依赖。Apple Music 接口行为、缓存、登录、授权、订阅错误、音频、搜索、播放来源、队列与收藏保持。禁止在迁移时猜测新 API、绕过鉴权或修改未授权真实资源。

## 路径与顺序
1. 记录当前依赖图与源码引用、已有180项测试报告；实际运行并建立差异。列出所有平台专有字段、类型、字符串、URL、Token、错误、WebKit 宿主和旧播放接口调用点；标记测试/生产/迁移边界。
2. Domain 新增/扩展统一 identity、context、能力、错误、Page/route；让现有模型通过适配器显式构造，旧字段兼容读取。先增加同 ID 不同平台/账户、unknown、不支持等测试。迁移 MediaDetailIdentity 与 OriginNavigationTarget 所有分支；不遗留裸 ID 比较。
3. Apple Music Provider 实现通用 Catalog/Search/Collection/Station/Mutation/Auth 与 Engine factory，AMP DTO 在内部转换。专有 ID 前缀只能在 Apple Music mapper 或明确旧数据迁移中使用；移除通用默认值。现有 API Client 共享实例只可在 Apple Music 内部受控，不能由 App/UI 调 token。验证账号切换、注销后的 cookie 清理真正完成，避免 Task 火后不管的回调污染新会话。
4. 移出 Controller 的页面请求、关系查询、集合解析与操作；保留布局与动画。逐条删除旧调用、旧错误分支和重复业务代码。MediaResourceStateStore 移入 Application/通用边界，保留现有字段级状态与磁盘快照机制；按目标 scope 路由而非当前浏览 scope。可复用现有实例结构，但不能同时维护新旧缓存。歌词第三方逻辑移出具体 Adapter。
5. 拆 SPM Target：先隔离 AppleMusicAdapter 与专用授权 presenter；兼容聚合只在允许模块使用；最终 UI/Application/Playback/Domain 的依赖闭包无具体 Adapter。构建 no-Apple host。清理旧 MusicPlaybackProvider 的生产路径：确有调用则桥接到同一协调器，否则标记废弃/移除并验证测试，无第二引擎入口。
6. App CompositionRoot 注册 lazy factory，生命周期交给通用 Runtime；现有窗口宿主不变。完成 browse/play/resource operation 独立路由，按需激活及账户注销。用 Fixture 注入无平台启动、浏览与数据行为。
7. Router 先用确定性假引擎验证事件和音频权，再接现有 AppleMusicWebEngine。对比普通播放/电台/恢复/系统媒体行为；旧 stop、取消、失败及新命令并发须有阻塞点测试。
8. 来源、队列、自适应面板、能力、原生材质差量接入；全量回归及真实验收。

## 持久化
现有单活动快照可以保留单文件（本期没有多平台独立恢复栈），但是外层必须明确 provider/account/region；缺失或不匹配私人身份不能恢复。若切换后写入新快照，旧 debounce 写必须按 session/routing generation 失效。迁移需保留 QueueEntry UUID、顺序、confirmed/pending 区别、来源、历史、循环/随机及真实电台目标；不能用当前电台歌曲 ID 替代 station ID。未知来源无推测；旧快照有可信外层 provider 但目标不匹配时拒绝/降级，不能默默修复。若增加 schema 版本，提供 v1/v2 及本版本数据迁移、未知枚举安全降级、损坏数据恢复；原文件迁移失败不得覆盖。写入原子化，不保存 Token/Cookie/SDK 对象/临时游标。注销/删除仅影响对应作用域，保留其他独立账户数据。

缓存 key 至少覆盖 provider、资源 kind、ID、scope、必要 region/账户；临时任务再加 session/intent generation。目录与私人缓存隔离，图片按 URL 和授权范围，歌词按真实歌曲版本及来源。磁盘文件名需安全编码或哈希，不直接拼接用户可控 ID；现有缓存无法安全迁移则明确失效并重取，不跨账户复用。缓存有界并记录淘汰/命中，不因抽象层重复缓存和网络请求。

## 回滚
每阶段保持可构建和测试；记录迁移文件与旧入口删除证据。可在未提交本地工作区用独立变更审查，不擅自 reset/revert 用户修改。数据 schema 向前迁移需保留安全备份或只读兼容，不能要求用户删除全部资料库或重新登录作为常规升级步骤。
