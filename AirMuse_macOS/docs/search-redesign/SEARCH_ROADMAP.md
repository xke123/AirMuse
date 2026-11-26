# AirMuse 搜索栏重构 — 实施路线图（Roadmap）

## 状态定义
- `TODO`：尚未开始
- `IN_PROGRESS`：正在编码或联调
- `IMPLEMENTED`：代码已合入，待补齐测试
- `TESTED`：单元测试通过
- `VERIFIED`：已通过实机/交互回归验证
- `BLOCKED`：受外部依赖或权限阻塞

---

## 任务拆解与依赖关系

| 任务 ID | 任务名称 | 依赖 | 当前状态 | 关键产出与验收标准 |
| :--- | :--- | :--- | :--- | :--- |
| **S01** | 搜索历史持久化模型（最近 5 条） | 无 | `TESTED` | 支持新增去重置顶（上限 5 条）、单条删除、全部清空；具备纯单元测试覆盖 |
| **S02** | `Domain` 与 `AMP API` 全量搜索升级（`topResults` + 动态顺序 + 25 条分页） | 无 | `TESTED` | 统一 `limit = 25`；支持 `with=topResults`、解析 `meta.results.order`、返回各分类 `next` 游标及 `fetchSearchPage(nextURL:)` |
| **S03** | `LibraryTopBarView` 聚焦与范围开关升级 | 无 | `TESTED` | 点搜索自动让宿主窗口成 key 并聚焦输入框；右侧开关改为 `[Apple Music \| 资料库]`（默认 Apple Music） |
| **S04** | Liquid Glass Expand 搜索历史浮层 | S01, S03 | `TESTED` | 基于 `NSGlassEffectContainerView` + `NSGlassEffectView` 展开最近 5 条历史，支持点击搜索、单条删除、全部清除及隐藏态命中隔离 |
| **S05** | `LibraryContentView` 3 栏类别浏览视图 | 无 | `TESTED` | 支持 3 栏网格模式，搜索空态展示固定类别浏览并支持点击钻取 |
| **S06** | 搜索结果页双栏布局与动态左边栏 | S02, S03 | `TESTED` | 有关键词时恢复双栏；左边栏按 API 返回顺序动态生成非空分类，默认选中「最佳结果」；右侧按选中分类展示结果 |
| **S07** | 右侧结果滚动分页加载（每页 25 条）与艺人路由预留 | S02, S06 | `TESTED` | 滚到底部自动加载 `next`（防重入、世代隔离）；艺人点击走统一预留路由接口 |
| **S08** | 单元测试、双模式/辅助功能回归与实机验收 | S01–S07 | `IN_PROGRESS` | 新增逻辑测试全部通过（42/42）；待实机验证在线 AMP 搜索、Original/Enhanced 与辅助功能表现 |

---

## 完成定义（DoD）
1. 点击搜索按钮光标稳定聚焦，空态显示 5 条 Liquid Glass Expand 历史浮层（可单删/全清）与 3 栏类别浏览。
2. 搜索栏右侧开关默认 Apple Music，可切换资料库并即时重搜。
3. 搜索结果页恢复双栏，左侧动态分类不写死、默认第一项为最佳结果，右侧每页 25 条并支持滚动分页。
4. 全量 `swift test` 通过，无新增并发警告或回归问题。
