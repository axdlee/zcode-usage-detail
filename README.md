# ZCode 用量明细 (usage-detail)

[English](#english) | 简体中文

一个 [ZCode](https://zcode.z.ai) 插件：查看**每一次模型请求**的本地用量明细——逐条记录、按来源（GLM 官方套餐 / 自定义 BYOK 接入）区分、多维筛选与交互式仪表盘。

纯本地只读查询，**不发起任何网络请求，不上传任何数据**。

![仪表盘总览](screenshots/dashboard-overview-dark.png)

每日趋势按来源堆叠，官方套餐与 BYOK 一目了然：

![每日趋势](screenshots/dashboard-trend-light.png)

5 小时窗口实时燃烧率（当前速率 vs 近期窗口均值）：

![5小时窗口](screenshots/dashboard-blocks-dark.png)

## 功能

- **逐条明细**：每次模型请求一行——时间、会话、模型、来源、主会话/子代理、输入/生成/缓存读 token、耗时、状态
- **当前会话**：`/usage-this` 查看会话汇总、按模型/来源分组和最近失败/取消请求；`/usage-this-ui` 使用精简面板，首屏展示请求/输入/生成/缓存读，模型分布和请求明细按需展开，支持直接查看失败/取消记录
- **来源区分**：自动区分 `account:*` 官方套餐（如 GLM Coding Plan）与自定义/BYOK 接入，仪表盘按来源堆叠展示每日趋势
- **交互式仪表盘**（`/usage-ui`）：总览 / 每日趋势 / 5 小时窗口 / 会话排行 / 请求明细 / 失败请求六个标签页；来源、模型、时间范围（近 7 天 / 30 天 / 全部）全局筛选即时生效；表格点击表头排序；界面自动适配 ZCode 明暗主题。默认内嵌最近 3000 条请求，`/usage-ui <条数>` 可调（1–20000）
- **5 小时窗口**：按相邻请求间隔 ≥5h 切分用量窗口（同 ccusage 口径），当前窗口显示进行中进度与剩余时间
- **洞察指标**：活跃天数、当前/最长连续活跃、峰值日、缓存命中率、平均耗时、主会话/子代理拆分、最常用工具
- **活跃热力图**：GitHub 提交风格，按天 token 四分位着色，悬停看当日明细
- **成本估算**（可选）：在 `~/.zcode/usage-prices.json` 配置价格表后，`cost` 命令与仪表盘"成本估算"开关即可按官方牌价估算花费
- **导出**：`export csv` / `export json` 全量记录（CSV 遵循 RFC 4180）
- **零依赖**：只用 macOS / Linux 自带的 `bash` + `sqlite3`，不需要 Node / Python

数据来自 ZCode 客户端本地数据库 `~/.zcode/cli/db/db.sqlite`（只读）。

## 安装

### 方式一：添加 GitHub 市场源（推荐）

1. 打开 ZCode 的 **插件市场**
2. 点击 **添加 → 添加插件市场**，粘贴本仓库地址：

   ```
   https://github.com/axdlee/zcode-usage-detail
   ```

3. 添加后进入 **个人** 标签页，找到 **用量明细 (Usage Detail)**，点击 **安装**

### 方式二：本地目录

```bash
git clone https://github.com/axdlee/zcode-usage-detail.git
```

然后在 **插件市场 → 添加 → 添加插件市场** 粘贴克隆出的目录路径（即包含 `marketplace.json` 的那一层），后续步骤同上。

### 方式三：AI 一键安装

把下面这段话直接发给 ZCode（或任何编码智能体），它会替你完成剩余步骤：

```text
请帮我安装 GitHub 上的 zcode-usage-detail 插件：

1. 执行 git clone https://github.com/axdlee/zcode-usage-detail.git ~/.zcode/plugins/zcode-usage-detail（目录已存在则 git -C 拉取更新）
2. 校验插件清单：node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs plugins validate ~/.zcode/plugins/zcode-usage-detail/usage-detail（没有这个 CLI 就跳过）
3. 读完插件 README 的安装章节后，告诉我手动步骤：在 ZCode 的「插件市场 → 添加 → 添加插件市场」里粘贴 ~/.zcode/plugins/zcode-usage-detail，然后在「个人」标签安装「用量明细」插件
4. 最后给我一条验收提示：安装后新建任务运行 /usage-ui，应看到内嵌的用量仪表盘
```

## 使用

安装后**新建任务**：

| 输入 | 效果 |
|---|---|
| `/usage-ui` | 生成交互式仪表盘，内嵌渲染在会话中 |
| `/usage-ui 8000` | 同上，内嵌最近 8000 条 |
| `/usage-this` | 推断当前会话，显示身份、用量汇总、模型/来源与最近失败/取消请求 |
| `/usage-this-ui` | 当前会话的精简面板：四项用量统计、折叠模型分布与请求明细 |
| `/usage-this --session sess_xxx` | 显式指定会话（UI 命令同样支持） |
| `/usage-this --directory /绝对/项目路径` | 选择指定项目目录内最近请求的会话（UI 命令同样支持） |
| `/usage` | 文本总览（累计 + 今日） |
| `/usage blocks` | 5 小时窗口用量（含进行中的窗口） |
| `/usage recent 50` | 最近 50 条逐条明细 |
| `/usage providers` | 按来源（官方套餐 / 自定义接入）汇总 |
| `/usage months` | 按月汇总 |
| `/usage projects 10` | 按项目目录汇总 Top 10 |
| `/usage tools` | 工具调用统计 |
| `/usage cost` | 成本估算（内置官方价，可自定义价格表） |
| `/usage prices sync` | 从 models.dev 同步最新官方价 |
| `/usage export csv` | 导出全部记录为 CSV |
| `/usage day 2026-10-14` | 某天的逐条明细 |
| `/usage sessions 10` | 会话用量排行 Top 10 |
| `/usage errors` | 最近的失败/取消请求 |
| “看看我哪个会话最烧 token” | 自然语言同样可以，会自动路由到对应查询 |

### 当前会话定位

ZCode 命令环境尚未提供可靠的当前会话 ID，因此默认使用本地数据库中**最近一次模型请求的 `session_id`**，一次执行中固定该 ID。多窗口并行请求时可能定位到另一会话，请核对输出中的会话标题、ID 和最近请求时间；有歧义时用 `--session ID` 指定，或用 `--directory "项目绝对路径"` 限制候选范围（两者互斥）。目录匹配为精确匹配，可使用报告中的项目目录。

只统计所选 `session_id` 的请求，不递归合并其他 ID 的子会话。文本版统计全部状态，生成 token = 输出 + 思考；失败和取消单独计数，进行中的请求归入其他状态。正在进行的请求可能尚未写入完整 token，重新运行可刷新。

会话 UI 首屏展示标题、最近请求和四项用量；会话 ID、项目目录与创建时间可展开查看。模型分布和请求明细默认折叠，有失败/取消请求时可直接跳到对应筛选。会话排行、热力图、每日趋势和 5 小时窗口仍在全量 `/usage-ui` 中查看。

UI 在会话过滤后默认加载最近 3000 条，可用 `ZCODE_USAGE_LIMIT` 调整为 1-20000；超过时标注覆盖范围，卡片和明细均只统计已加载记录。结果是生成时的本地快照，不表示服务端套餐余量。

直接运行脚本：

```bash
bash usage-detail/scripts/usage.sh this
bash usage-detail/scripts/usage.sh this --session sess_xxx
bash usage-detail/scripts/usage.sh dashboard-this /tmp/usage-this.html --directory "/path/to/project"
```

### 成本估算（默认官方价，可自定义）

价格表解析顺序：`ZCODE_USAGE_PRICES` 环境变量 → `~/.zcode/usage-prices.json`（你的自定义文件）→ 插件内置官方价（自动打包自 [models.dev](https://models.dev) 的 zai/zhipuai 官方牌价，美元/百万 token）。所以开箱即有官方价，无需任何配置。

- `usage.sh prices show` 查看当前生效的价格表
- `usage.sh prices sync` 从 models.dev 同步最新官方价（保留你的自定义条目；需要 node + curl）
- 自定义：编辑 `~/.zcode/usage-prices.json`，可加任意模型、改币种：

  ```json
  { "currency": "USD",
    "models": { "glm-5.3": {"in": 1.4, "out": 4.4, "cache": 0.26},
                 "my-private-model": {"in": 1, "out": 3, "cache": 0.1} } }
  ```

配置后 `/usage cost` 按模型拆分估算；仪表盘顶部出现"成本估算"开关，打开后会话排行与来源构成追加成本列。注意：订阅套餐（如 GLM Coding Plan）内的请求实际不按 token 计费，估算仅供 BYOK 按量计费或心理参考。

### 实时燃烧率监控

- 仪表盘"5 小时窗口"页：当前窗口的燃烧率（token/小时）、时间进度条、与近 3 个完整窗口均值的对比和满窗预测
- 终端实时监控（claude-monitor 风格）：`usage.sh live [秒]`，默认 3s 刷新、Ctrl-C 退出；只查最近 5h/48h 数据并走索引，开销极低，适合挂在一个终端角落

### 仪表盘预览

每日趋势按来源堆叠，官方套餐与 BYOK 一目了然：

![每日趋势](screenshots/dashboard-trend-light.png)

请求明细支持状态筛选与表头排序：

![请求明细](screenshots/dashboard-detail-light.png)

## 数据说明与隐私

- 数据源是 ZCode 客户端自动写入的本地 SQLite（`~/.zcode/cli/db/db.sqlite` 的 `model_usage` 表），本插件只做**只读**查询
- 不联网、不上传、不写库；仪表盘数据在生成时内嵌，仅存在于你自己机器上的一个 HTML 文件
- 仪表盘默认内嵌最近 3000 条请求，`/usage-ui <条数>` 可调整（1–20000；超过约 8000 条可能超出会话内嵌渲染的体积限制，全量历史请用 `export json`）
- token 口径：输入列含缓存命中（缓存读单独列出），生成 = 输出 + 思考
- GLM Coding Plan 的**套餐配额余量**（5 小时池 / 周额度）由服务端计量，不在本地库中，请在 ZCode 的 **Usage Stats → Coding Plan** 查看

## 已知限制

- 只统计**本机、本账号**在 ZCode 内的请求
- 本地库结构可能随 ZCode 版本演进变化（当前在 0.16.x 验证通过）
- 界面基于 ZCode Desktop 的 Gen UI 内嵌渲染，需在桌面端使用
- 5 小时窗口与成本均为**本地近似口径**，服务端套餐配额以 ZCode 的 Usage Stats → Coding Plan 为准

## 开发验证

运行会话过滤、聚合、空记录、参数转义及仪表盘回归测试（开发环境需要 Python 3；插件运行仍仅需 bash + sqlite3）：

```bash
python3 -m unittest discover -s tests -v
bash -n usage-detail/scripts/usage.sh
```

## 致谢

设计参考了这些优秀的同类项目：[ccusage](https://github.com/ccusage/ccusage)（5 小时窗口 / 成本报告）、[Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor)（燃烧率与耗尽预测）以及 DeepSeek Harness 社区的用量插件家族（活跃热力图、缓存命中率、连续活跃、导出等思路）。

## License

[MIT](LICENSE)
