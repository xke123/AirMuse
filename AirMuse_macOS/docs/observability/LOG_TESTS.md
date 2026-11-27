# LOG — 验收与测试
源码基线：`791ae679d8e1c7fc03252f57dc4cef09c13a7005`（main，2026-11-28 06:24:47 北京时间）。实施前复核 HEAD。本文为实施规范，不是已完成的生产功能或实测结果。

自动化采用 Swift Testing/现有测试设施、注入 Clock/transport/engine/writer，使用可控 continuation/barrier 而不是随机 sleep；所有案例断言生产接线、事件字段、终态、隐私和业务状态不被 logger 改变。不要为了测试构造不经过真实调用链的假日志。现有 197 项为仓库自报基线，不是本次实测。

| ID | 场景 | 确定性断言 |
|---|---|---|
| T01 | schema v1 JSONL roundtrip 与未知版本处理 | 固定事件及缺失字段，断言稳定 schema 与兼容失败 |
| T02 | 真实 run/sequence 唯一且单调 | 并发发射并验证单 run 顺序与缺口 |
| T03 | 时间倒退不影响 duration | 注入 wall/monotonic clock 分离 |
| T04 | 禁用级别不计算昂贵载荷 | 计数 closure 未执行 |
| T05 | Trace UI→Application→Adapter→HTTP→Engine→Store | fixture 真实生产链共享 root 与 parent |
| T06 | 跨 Task/Actor/AsyncStream/bridge 传播 | 显式 context，旧 callback 保留原 trace |
| T07 | 合并请求多消费者 | 同 requestID 多 links 不重复计传输 |
| T08 | 重试/取消/过期终态 | 每 begin 有 outcome，不误报成功 |
| T09 | 缓存刷新与用户 trace 分离 | 后台独立 root/link |
| T10 | 错误脱敏嵌套与 unknown key | canary 不出现在任何 sink |
| T11 | Header/Cookie/JWT/OAuth/URL 编码 | 全变体 canary 被禁止 |
| T12 | 关联ID、错误、路径、换行注入 | 拒绝外部敏感字段并保持 JSONL 一行 |
| T13 | 本地名称 opt-in 与分享默认 | 分享无名称/搜索词/映射密钥 |
| T14 | 并发写入与顺序 | 短锁、单 writer，无死锁、重复或崩溃 |
| T15 | 缓冲溢出优先级 | 高优先保留、所有丢弃计数与范围 |
| T16 | 关键容量也耗尽 | 明确 critical loss，不宣称全量 |
| T17 | 磁盘满/权限/轮转失败 | sink failure 不递归、不阻塞播放 |
| T18 | 轮转按数量+字节+期限 | 跨 run 总预算及淘汰范围 |
| T19 | 崩溃截断恢复 | 截断最后一行标 gap，不伪造 EOF |
| T20 | 导出 H 与尾部 | 并发写入/轮转，完整范围去重 |
| T21 | 导出取消/磁盘满 | partial/failed、临时文件清理 |
| T22 | 清空视图与删除历史 | 删除 barrier 阻止旧批次复活 |
| T23 | 多订阅与隐藏恢复 | 有界 cursor、无漏重、隐藏不布局 |
| T24 | Registry 重复/未激活/激活失败 | 无额外初始化、真实 outcome |
| T25 | 会话 A→B→A | 旧 generation discard、引用隔离 |
| T26 | 登录恢复/刷新/退出 | 记录状态机及失败，不输出凭证 |
| T27 | 跨平台资源路由 | browse 与 playing 不同，按目标平台 |
| T28 | 浏览/搜索慢 A 快 B | 过期原因及空结果/失败区别 |
| T29 | 网络队列等待/429/超时/401/403 | requestID/attempt/分类准确 |
| T30 | AMP 直接路径及通用 HTTP | 两者有 trace，无双计 |
| T31 | 收藏快速 on/off | confirmed/desired/revision、superseded |
| T32 | 写超时核对失败/成功 | unknown 与 confirmed 分离 |
| T33 | 旧查询与新写 | 字段补丁保留另一个 pending |
| T34 | 状态缓存 scope/淘汰/磁盘失败 | 可追踪不伪造成功 |
| T35 | 队列 replace/shuffle/interrupt/prepend/append | 前后 revision、顺序、确认级别 |
| T36 | 队列移动/删除/撤销/历史 | checkpoint+diff 可重建 |
| T37 | 10000 条队列及分片 | 预算、顺序与 gap |
| T38 | 分页返回100但提交0 | received/accepted 区别 |
| T39 | 分页重复游标/重试/clear | 批次与拒绝原因 |
| T40 | 候选引擎准备失败 | 旧播放保持、真实 failure |
| T41 | 旧引擎停播失败 | 不启动新引擎、lease failure |
| T42 | 快速 A→B→C 切换 | routingGeneration、candidate discard、无旧事件污染 |
| T43 | 命令接受但引擎失败 | accepted 不标 audible/confirmed |
| T44 | 电台动态切歌 | station 固定、itemSequence 与元数据重置 |
| T45 | 直播/未知能力 | 禁止未证实 skip/seek、unknown queue |
| T46 | 电台转本地暂存/取消 | 不自动播放、正确 stop 证据 |
| T47 | 来源跨平台导航 | 只改变浏览，不误判自然切歌 |
| T48 | 来源关系旧结果 | itemSequence/资源身份 discard |
| T49 | 快照恢复/迁移/作用域拒绝 | 真实 schema、station target、无自动播放 |
| T50 | 歌词/封面/缓存失败 | 仅元数据，无正文/URL原文 |
| T51 | 动画快速反转/销毁 | 旧回调被拦截、无业务副作用 |
| T52 | 帧/进度聚合 | 不逐帧日志、缺失指标 unknown |
| T53 | 只读快照超时 | 组件 partial，不激活平台或发写请求 |
| T54 | 不变量误报防护 | 独立自然切歌、不同 owner 时点不误报 |
| T55 | 诊断窗口筛选/暂停/隐藏 | 后台持续有界、跟随可关 |
| T56 | FixtureHost 不链接 Apple Music | 通用 logger/快照/导出可用 |
| T57 | 日志自身故障 | 无递归、无业务状态改变 |
| T58 | 关闭/Normal/FullTrace 性能基准 | 相同 workload，记录样本量 p50/p95/资源预算 |

## 实机验收
| ID | 实机条件及证据 |
|---|---|
| E01 | Apple Music 真账户登录/恢复/退出，脱敏 Trace 与状态一致；无凭证输出 |
| E02 | 真实目录/搜索/收藏/资料库操作（明确授权可逆资源，非诊断自动写），失败/超时核对与实际结果 |
| E03 | 普通播放/暂停/seek/插播/队列/分页，音频与日志对齐，确认语义准确 |
| E04 | 直播及算法电台切换、动态歌曲、暂停/失败、真实能力、队列暂存；录音/设备证据仅在用户允许下采集，不默认录音 |
| E05 | 平台切换及音频权交接；若仅有一个真实音源则 fixture 自动测试，真实多平台仍待联调 |
| E06 | Original/Enhanced、Normal/Mini、双玻璃、窄窗、多屏、辅助功能、诊断窗口隐藏/销毁 |
| E07 | Instruments 实测三档启动/首播/CPU/GPU/内存/帧与大队列；按 PIPELINE 门槛记录 |
| E08 | 长时运行/磁盘轮转/故障导出，脱敏 ZIP 实际人工检查与离线 Trace/队列重建 |

执行 `swift build --product FixtureHost`、`swift run FixtureHost`、`swift build --product AirMuse`、`swift test`，加诊断专项 filter、依赖扫描、隐私 canary 扫描、压力基准。记录真实退出码/测试总数/SDK/设备/失败；无 macOS 或真实账户标待验。
