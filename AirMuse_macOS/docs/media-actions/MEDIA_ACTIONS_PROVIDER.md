# Provider 能力与真实接口验证
资料库添加/移除、收藏/取消收藏是正式交付目标，不是可选装饰。当前 Apple Music Web 会话、AMP 适配路径实际权限未在本次文档制作中验证。不得将官方 API 或网页 UI 存在等同现有客户端可调用；不得猜测端点、请求体、token 或绕过授权。只使用合法可用会话和已验证接口，不记录凭证、Cookie、私有账户数据；真实写测试使用明确授权的测试账户与可恢复资源，不删除真实用户资产。

## 建议契约
```swift
func addToLibrary(_ resource: MediaResourceReference) async throws
func removeFromLibrary(_ resource: MediaResourceReference) async throws
func setFavorite(_ resource: MediaResourceReference, enabled: Bool) async throws
func fetchResourceState(_ resource: MediaResourceReference) async throws -> MediaResourceState
```
实际可返回 mutation receipt 与权威状态；使用既有依赖注入。能力按资源种类、归属、账户权限和当前会话动态区分 readMembership/add/remove/readFavorite/favorite/unfavorite、station、navigation。能力未知不等于支持；查询失败不等于未收藏。自建、协作、归属不明歌单容器强制只读，即使底层接口有写权限也禁止。

## 逐项证据表（执行时填）
| 资源 | 读取成员 | 添加 | 移除 | 读取收藏 | 收藏 | 取消收藏 |
|---|---|---|---|---|---|---|
| 歌曲 | 待验证 | 待验证 | 待验证 | 待验证 | 待验证 | 待验证 |
| 专辑 | 待验证 | 待验证 | 待验证 | 待验证 | 待验证 | 待验证 |
| 平台歌单 | 待验证 | 待验证 | 待验证 | 待验证 | 待验证 | 待验证 |
| 艺人 | 不适用 | 不适用 | 不适用 | 已有详情状态，待实测 | 已有 setArtistRating，待实测 | 已有 setArtistRating，待实测 |
| 自建/归属不明歌单 | 可读 | 禁止 | 禁止 | 不展示 | 禁止 | 禁止 |
证据包含接口来源、权限条件、资源 ID 类型、脱敏状态码及响应结构、服务端读回结果、错误/重试语义、联动影响。验证添加/移除同资源时目录 ID 与 library ID 是否不同；订阅歌单的移除必须证明不会删除自建歌单。收藏可能自动添加资料库，移除可能影响收藏或个人歌单成员；读取确认联动，无法保证安全的路径禁用并记录。403/401 与网络错误分开处理，401 走既有会话恢复；禁止无界自动重试。未验证写能力隐藏或明确不可用，进度标 BLOCKED/PENDING_INTEGRATION，不得假成功。

## 已有接口优先
`AppleMusicProvider.setArtistRating(artistID:value:)` 封装 `AppleMusicAmpClient.setArtistRating(artistID:value:generation:)`，现有实现使用 PUT/DELETE；收藏传 1，取消传 nil。只确认源码存在，不代表实测授权通过。复用现有传输、会话 generation 和错误处理；不得直接推断其他资源适用相同 URL、payload 或 ID。艺人详情现有 isFavorited / isSuggestLess 不得用失败默认值覆盖真实状态；不增加减少推荐入口。歌曲、专辑、平台歌单的成员与收藏状态需要独立证据。现有 fetchFavoriteSongs、fetchFavoritePlaylists、fetchLibrary*、resolveCatalogSongID 等可作为读取/映射基础；不将分页列表中缺席当作未收藏或未加入资料库。
