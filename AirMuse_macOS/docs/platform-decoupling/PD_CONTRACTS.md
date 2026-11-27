# PD — 统一平台与资源契约

以下类型名为设计意图，优先扩展现有契约，实际 API 可按源码调整；不可改变可观察业务语义。

## 1. 身份与上下文
```swift
struct ResourceIdentity: Hashable, Codable, Sendable {
    let providerID: ProviderID
    let kind: ResourceKind
    let opaqueID: String
    let scope: ResourceScope
}
enum ResourceScope: Hashable, Codable, Sendable {
    case catalog(region: String?)
    case library(accountID: String, region: String?)
    case local(namespace: String)
    case unknown
}
```
`ProviderID` 为不透明稳定标识，不能以显示名作主键。账号身份为平台内稳定标识；sessionID/generation 是运行时防过期身份，不是永久资源身份。目录与资料库真实关系以 Adapter 解析的别名/映射为准；不能把 catalogID 和 libraryID 合并成一个可用于删除的 ID。资源同名/同 ISRC 也不等于同平台资源。未知 ID/作用域不能用于破坏性写入。QueueEntry UUID 与资源 ID 独立，来源不可变。`MusicTrack`、`MediaResourceReference`、`MediaArtistRef`、`MediaDetailIdentity`、`PlaybackTarget`、`StationSeedResource`、`PlaybackOrigin` 复用这一身份或等价的单一类型，避免多字段双写；旧字段仅兼容读取并明确优先级。

每种 `OriginNavigationTarget`（resource/librarySection/search/chart/browseSection/stationDetail）绑定同一持久作用域或包含作用域的 route envelope。运行时导航/读写/分页需携带当前 session generation 并重验。禁止在资源路由时用当前浏览平台覆盖原 provider。旧来源无平台时，只有已验证 Apple Music 快照外层等可信元数据可推导，否则 unknown。不要全局默认 Apple Music。

## 2. 平台能力与协议
保留细粒度协议，注册 Adapter descriptor + capability + optional service factories。平台描述包含稳定 ID、显示名、图标、入口描述；不含任意布局、HTML 或脚本。以协议组合表达 Catalog、Library、Search、Station、Mutation、Authentication、Playback Engine、可选 Lyrics。禁止庞大强制协议和大量空实现。优先升级现有 MusicCatalogProvider/MusicLibraryProvider/MusicSearchProvider/MusicAuthenticationProvider/MediaResourceMutationProvider/PlaybackEngineProtocol；明确废弃或桥接旧 MusicPlaybackProvider，桥接只能指向唯一协调器，不能绕过播放权。缺失能力显式 unsupported，不允许空写成功、unknown=false、权限失败=空列表。读接口区分真实空集合与不可用。能力快照从 Adapter/资源权限/账户与引擎证据合成，UI 只合并选择/页面上下文；协调器提交时再校验。区分 canPlay/canPause/canSeek/skip/volume/stop、队列可读与可编辑、随机/循环及远端列表；算法电台不是可 seek 的证据。无能力证明保持保守，停播能力不可缺失或必须支持隔离失败处理。

## 3. 通用分页与页面 DTO
```swift
struct Page<Element: Sendable>: Sendable {
    let items: [Element]
    let next: PageCursor?
    let totalCount: Int?
}
```
PageCursor 为 Adapter 自己生成解析的 opaque token + scope + route/request fingerprint（或等价不透明句柄），不暴露 AMP URL 给 UI；不能跨平台/账户/查询使用，不得把游标当任意 URL 访问。保留 QueuePaginationLoader 的批次锚点、循环检测、页数预算、精确失败游标重试、取消与 epoch；可逐步把 URL 改为 cursor，无需另建 loader。播放队列入队按真实集合，不以当前 UI 已加载数组代替全量，顺序首批启动、完整随机先全量、部分失败明确状态；集合操作沿现有策略，不无关重写。

BrowseRoute = 平台作用域 + 稳定栏目/资源类型化目标；BrowsePage/Section/MediaCard/TrackRow 仅包含通用数据、能力、加载态、分页，不含 AmpCategory/TrackPage/SDK 对象。Section 使用已有专辑、歌单、歌曲、艺人、电台、分类组件；不支持的 section 隐藏，未知 section 安全降级。使用稳定栏目 ID，不用 tabIndex、title 或语言文案确定业务；index 只用于呈现。

## 4. 错误与资源操作
归一化领域错误：unsupported、authorizationRequired、subscriptionRequired、resourceUnavailable、permissionDenied、network、rateLimited、invalidCursor、sessionExpired、superseded、outcomeUnknown、engineUnavailable、handoffFailed 等；保留可重试性及脱敏诊断，不泄露 token/cookie/用户数据。用户取消不显示成功或通用网络错误。资源写使用冻结的 ResourceIdentity + 当前有效会话，Provider 确认和权限为准；沿用现有字段级 patch、confirmed/desired/pending/revision、核对未知结果、批量查询、SWR 与有界缓存。自建、协作、未知所有权歌单容器严格只读。操作菜单按目标资源平台路由，即使浏览/播放平台不同。

## 5. 不可变性与并发
所有跨 actor DTO Sendable；UI MainActor。长操作点击时冻结 provider/account/session generation/resource/intent/queueID/epoch；跨 await 重新校验。最终提交在权威所有者隔离域中完成，校验至修改之间不悬挂。浏览、导航、读写、播放各有独立代数；不能互相取消无关请求。字符串拼接键需防分隔符冲突，优先 Hashable 类型化 key。
