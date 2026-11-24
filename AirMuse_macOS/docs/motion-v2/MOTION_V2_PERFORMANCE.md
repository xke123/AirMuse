# AirMuse Motion V2 — 性能、资源与验收方法

以下全部为目标预算而非实测。比较同一机器、同一OS/SDK、同一分辨率、刷新率、渲染模式、歌曲和网络条件；记录主进程与WebKit子进程，不能用包大小替代运行成本。

| 指标 | 建议目标 / 方法 |
|---|---|
| 首次输入视觉反馈 | 一帧内为目标；signpost从输入到呈现，无法直接测呈现时明确代理指标 |
| 60Hz/120Hz | 帧预算16.67/8.33ms；记录P50/P95/P99、超预算帧、hitch数量 |
| 冷启动 | 不新增强制等待；以500ms为建议目标，比较基线 |
| 模式切换 | 320ms设计时长，测完成与中断；不触发WebKit重建 |
| 空闲 | 装饰时钟0；必要播放/歌词时钟另计；测CPU、唤醒次数 |
| 内存 | 记录RSS、峰值、WebKit、图层/视图数量；100轮切换后无持续增长趋势 |
| CPU/GPU | 记录空闲、播放、拖动、扫光、列表滚动；相同场景与基线比较 |
| 请求/播放 | 模式/布局切换额外网络请求、seek、播放命令、引擎重建均为0 |

## 测量程序
- 记录硬件、系统、刷新率、显示器数量、Original/Enhanced、辅助功能、Git SHA、Release构建命令。
- OSSignposter记录 input、transition begin/retarget/cancel/end、layout、render、glass allocation、first interactive；用Instruments Time Profiler、Core Animation/Animation Hitches（以本机模板为准）、Allocations、Leaks、Energy Log或同等可用工具采样。使用 `xcrun xctrace list templates` 确认环境。日志禁止敏感账户数据。
- 每场景建议至少30次：启动、双击收缩/展开、音乐库/歌词开关、hover、seek、磁吸、切歌；统计分位数及异常。记录样本量、测量窗口和是否热缓存。若仅录像，注明帧率及时间精度，不冒充Instruments测量。
- 连续100次模式/模块切换、100次hover、快速10次反向切换，观察图层/定时器/监听器数量；至少4小时播放观察资源趋势。关闭窗口、睡眠唤醒、切换账户、进程恢复、屏幕拔插均检查。
- 对照现有业务自动化测试与实际播放：暂停/继续/seek/切歌/退出/离线/缓存不得退化。测试工程可注入mock clock、fake playback snapshot，但生产禁止假状态。

## 回归门禁
测量环境缺失则标记PENDING_INTEGRATION，附可复制命令与手动步骤；不能将缺失写成通过。若有显著回归（初始警戒线：同场景P95帧耗时或空闲CPU增加超过10%，结合测量噪声判断），定位原因并修复或明确记录经用户接受的取舍。优先禁用装饰，不牺牲实际播放与输入正确性。所有设计参数调整同步INTERACTION_SPEC及PROGRESS。
