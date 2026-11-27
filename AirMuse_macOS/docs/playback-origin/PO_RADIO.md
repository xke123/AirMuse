# PO — 电台独立会话与自适应播放列表

## 三个身份必须分离
`PlaybackTarget(kind:.station, providerResourceID: stationID)` 是真实远端播放/重试/恢复目标。`PlaybackOrigin(kind:.station, sourceID: stationID, sourceTitle, stationContext)` 是稳定来源。`confirmedCurrent.track` 是远端实际节目/歌曲；可选 seedResource 只说明创建电台的歌曲/艺人，绝不用于替代 stationID 或当前歌手。普通歌曲播放即使从电台相关页面选择，也应是明确 song target，不以来源 kind 或 ID 前缀替代真实类型判断。

## 创建及事件
- 点击广播卡片只传入一个 station，拒绝多条/混入普通歌；艺人/歌曲电台使用已验证 provider 返回 station ID，保留 seed；种子获取慢请求不得覆盖新播放。普通卡片列表过滤不可播放资源和 radio，按真实 occurrence 定位点击歌曲。
- 电台开始前不要将 station 占位对象当真实歌曲展示；区分 station connecting、transport playing、实际 item available。直播只提供真实节目元数据；无歌曲关系不假造专辑。
- 远端每次实际 item 变化更新 itemSequence 或等价代数，保留 station origin 与 target；QueueEntry UUID 可以复用，不能作为曲目身份唯一检查。真实同一首重放也要有事件身份。缺字段清空旧曲目字段，未知不是上一首值。仅同一已确认 item 的增量元数据可以合并。旧 engine/session/operation/item 事件丢弃。
- remote itemChanged 不强制 phase playing、不凭元数据事件确认音频播放；pause/failure/stop 与连接状态以真实 transport 为准。结束事件不得 local advance/重复/切换另一电台；按引擎真实电台行为处理，停止或错误给明确提示，不自动重连或跨会话恢复。

## 能力矩阵
| 能力 | local | algorithmic station | live station | unknown |
|---|---|---|---|---|
| 播放/暂停 | 现有 | 真实支持 | 真实支持（不推测可暂停） | 仅已验证支持 |
| 下一首/上一首/seek | 现有 | 单项实测才开放 | 默认禁用，实测例外 | 默认禁用 |
| 读取后续 | 本地真实队列 | 默认未知；真实可读才只读展示 | 不适用 | 未知 |
| 排序/删除/清空/随机/循环/插入/追加 | 现有 | 禁止 | 禁止 | 禁止 |

沿用 QueueCapabilities，必要时补 transport capabilities（pause/seek/live 等），区分未知与不支持，Provider/engine 为真实来源。不能仅因 MusicStation.isLive==false 就认定算法电台或可跳过；未确认分类为 unknown。默认 remoteStationDefault.canSkipNext 的现状须审查。所有入口（主播放器、Mini、菜单、键盘、系统控制、面板）共享并在协调器最终检查，不能只禁用按钮。

## 模式切换表
| 当前 | 动作 | 结果 |
|---|---|---|
| local A + B C D | 收听 R | 明确替换，只创建 R 会话；不保留 B C D 隐藏栈 |
| remote R | 收听 S | 替换 R，只有 S |
| remote R | 播放/随机普通集合 X Y | 直接替换，X 或全量随机首曲，剩余本地待播 |
| remote R | 立即插播 X Y | 确认结束 R 后播放 X、待播 Y；不承诺返回 R |
| remote R | 队首/队尾 X Y | 确认结束 R，local staged [X,Y]，无 current、无自动 play |
| remote R | 取消确认 | 完全保持 R、当前项、transport、代数及队列 |
| remote R | 来源导航 | 只浏览，R 继续原状态 |

所有单曲、整集合、艺人、右键及页面菜单走同一流程。确认框说明“结束电台并立即播放”或“结束电台并建立队列（不自动播放）”；取消“继续收听电台”。确认中若会话已变化，撤销旧动作并提示，不针对新电台执行。完整集合准备失败/空集合/账户切换不能结束原电台；在确认及提交前后检查目标。暂存完成后 Play 才消费队首。切换失败显示实际状态与可重试操作；不使用 try? 吞错。跨模式历史不可在本地 previous/repeat 触发旧 station 或把动态电台歌曲当可重复的本地历史条目。

## 电台面板与来源跳转
右侧入口保持可见，电台图标、无数字。展示电台名、实际状态、已知当前歌曲/节目、可用控制；不展示灰掉的整套普通队列 toolbar。连接失败优先展示失败与真正的 station retry；暂停不显示自动续播中。没有后续曲目数据时“后续内容由电台决定，待播列表不可读取”，非“待播为空”。若未来有真实可读队列，按能力只读展示；本期不开发未验证远端列表接口。直播使用实际状态，未知类型保守。

来源菜单的 station detail、广播栏目、seed artist/song 与当前歌曲 album/artist 明确标注；例如周杰伦电台播放林俊杰：来源艺人周杰伦、当前歌手林俊杰。仅有真实 route 才展示。无 station detail 不用播放卡片冒充导航，不自动重新启动电台。种子单曲无内部单曲页时可用已验证关联专辑并明确标签。

## 真实环境验证门槛
检查现有 MusicKit WebEngine setQueue station、itemChanged/stateChanged/ended 真实语义及能力反馈，使用有权限账号及真实 SDK。禁止猜测新接口、伪造远端曲目、绕过权限。记录算法/直播/未知案例、事件顺序、真实响应及日志（脱敏），实测不了保守关闭并标 PENDING_INTEGRATION。
