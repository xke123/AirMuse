# LOG — 采集、存储、完整性与性能
源码基线：`791ae679d8e1c7fc03252f57dc4cef09c13a7005`（main，2026-11-28 06:24:47 北京时间）。实施前复核 HEAD。本文为实施规范，不是已完成的生产功能或实测结果。

## 单入口/单 writer
保留 AppLogger 兼容方法；旧文本走受限 legacy.event 并脱敏，迁移后业务使用类型化 emit。检查模式/级别后才构造 payload。入口同步短临界区分配 sequence、接纳脱敏事件（不可磁盘/网络/等待 UI/每事件创建 Task）；有界 ring + 预留 critical 容量，单异步消费者批量编码 JSONL 与落盘，通知批次。Swift 6 actor/锁保护全部可变状态；现有 unchecked Sendable 需审查并移除或证明隔离，不能新增逃逸。消费者错误通过独立有界 counter/emergency path 记录，不递归调用 logger。订阅 snapshot+cursor 原子注册，支持多窗口、取消、重连、去重及缺口。

## 初始预算（待测调优）
| 项 | Normal | Debug | FullTrace | Performance |
|---|---:|---:|---:|---:|
| 内存环事件 | 2000 | 5000 | 10000 | 2000 |
| 内存字节硬上限 | 8 MiB | 16 MiB | 32 MiB | 8 MiB |
| 持久化段预算 | 5×5 MiB | 5×10 MiB | 10×10 MiB | 5×5 MiB |
| 留存上限 | 7天 | 3天 | 3天 | 3天 |
| UI 批量间隔 | 250ms | 150ms | 100ms | 250ms |
| 进度聚合 | 5s | 2s | 1s | 5s |

字节与数量双限，writer 待写队列另设上限（建议 4 MiB/4096 events，关键保留25%）；单事件目标 ≤16KiB，超大队列分片/显式快照预算，禁止任意大 payload。文件总预算跨运行、跨模式计算，不累加。批次写入目标 64条或250ms，关键终态可请求早刷但不阻塞业务。故障时优先淘汰低优先级；若关键也丢失必须记录计数，不能承诺无限可靠。记录 retained/dropped/evicted/filtered/sampled/writerFailed 各自分母，sequence range、reason、类别/级别。过滤与采样不伪装丢失。磁盘段轮转按字节、时间；文件 permissions 0600、目录0700，应用私有路径。多进程独立 run/文件，不跨进程争抢同一 writer。

## 文件与导出一致性
每段 JSONL 有 schema/run/sequence 及范围索引，原子更新 manifest，崩溃后扫描尾部截断行并记录 gap，不伪造 EOF。导出捕获 high-watermark H；writer 完成 H 或显式超时/部分，固定仍保留的段与未刷盘尾部，用 eventID/run+sequence 去重；导出期间轮转 pin 受预算限制，超限返回 partial 而非无限缓存。导出不会暂停音频。历史清理区分“清空视图”“删除本地日志”（确认、同步到 writer/订阅、旧批次失效）；不删除用户播放快照/资料库。退出有界 flush，超时记录 incomplete（若无法落盘下一次启动检测）。日志文件不包含原始私有字段。

## 性能验收
使用相同设备、SDK、数据、日志策略及可复现脚本，预热后多次测量关闭/Normal/FullTrace；记录 p50/p95、样本量、CPU/内存峰值/磁盘写入/启动/首播/100、1k、10k 队列/动画。初始目标：Normal 日志入口 p95≤0.2ms、FullTrace ≤0.5ms（不含显式快照）；相对关闭档启动及队列操作 p95 增幅≤10%或≤2ms（绝对小样本另报）；空闲 CPU 增量≤1百分点；日志内存严格受预算；隐藏诊断窗无持续布局；帧预算60Hz 16.67ms/120Hz 8.33ms 整帧目标，不伪造真实帧率。目标非已测结果，未达需定位、修复或记录明确阻塞。OSSignposter begin/end 同一 interval；实际指标 unavailable 不填0；仅聚合，不逐帧打印。
