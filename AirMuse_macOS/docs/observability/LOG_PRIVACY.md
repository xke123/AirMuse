# LOG — 安全、脱敏、分享规则
源码基线：`791ae679d8e1c7fc03252f57dc4cef09c13a7005`（main，2026-11-28 06:24:47 北京时间）。实施前复核 HEAD。本文为实施规范，不是已完成的生产功能或实测结果。

威胁模型：日志会被复制给 AI/开发者；HTTP、JS、错误、资源、路径可能包含凭证或个人数据。任何档位都先脱敏再进入 buffer、文件、控制台、OSLog、UI、导出。类型化 allowlist 为第一道；LogSanitizer 防御兜底，拒绝未知字段或过大数据。绝不以 privacy .private 代替预脱敏。

| 字段 | 规则 |
|---|---|
| providerID、随机业务UUID、版本、状态、数量、耗时 | 安全字段可直接记录；非随机外来 ID 按引用处理 |
| accountID、私人资源、storefront scope、cursor、搜索词 | 运行/导出内稳定 HMAC 引用（随机密钥仅本地、不同 run 可用独立映射；导出不含密钥/明文映射）；公开ID也默认可分享引用 |
| 曲名、艺人、歌单名 | 默认分享日志不含；本地可选安全展示必须明确选择，单独受控字段，分享前移除；不可解锁密钥类信息 |
| URL/path | endpoint template + 安全 host class；不含 query/fragment/userinfo/私人 path；未知端点用类型 |
| Header/body | 安全 allowlist 的 Content-Type/长度/状态/重试等；不记录整头、整包、网页/JS/歌词正文 |
| 凭证 | Authorization、Cookie、Set-Cookie、JWT、developer/user token、OAuth code/state/verifier、API key、密码、Keychain、认证页面原文永远禁止 |
| 错误 | 统一 domain/code/stage/safeSummary；递归过滤 underlying，禁止直接 String(describing: error)/NSError.userInfo/JS stack 原文 |
| 本地文件 | 文件类型/大小/相对受控标签，禁止用户名、绝对路径、文件内容 |

导出默认不含真实私人歌单及歌曲名；可选择包含已审查的显示名称（独立明示确认），仍不得输出凭证或原始请求。预览摘要、记录范围与风险。无自动上传。旧文本段不能保证安全时应重新白名单解析或明确排除，manifest 写出排除原因。清理临时导出、禁止在 ZIP 包中附带原始数据库/Keychain/缓存/浏览器存储。测试覆盖大小写、JSON 嵌套、转义、URL percent encoding、base64/未知字段、错误链、日志注入换行；用人工 canary，不用真实 token。每个 sink 分别测试；发现泄漏立即停止该输出、报告范围及清理建议，不把秘密写进错误日志。
