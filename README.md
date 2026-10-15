# ZCode 用量明细 (usage-detail)

[English](#english) | 简体中文

一个 [ZCode](https://zcode.z.ai) 插件：查看**每一次模型请求**的本地用量明细——逐条记录、按来源（GLM 官方套餐 / 自定义 BYOK 接入）区分、多维筛选与交互式仪表盘。

纯本地只读查询，**不发起任何网络请求，不上传任何数据**。

![仪表盘总览](screenshots/dashboard-overview-dark.png)

## 功能

- **逐条明细**：每次模型请求一行——时间、会话、模型、来源、输入/生成/缓存读 token、耗时、状态
- **来源区分**：自动区分 `account:*` 官方套餐（如 GLM Coding Plan）与自定义/BYOK 接入，仪表盘按来源堆叠展示每日趋势
- **交互式仪表盘**（`/usage-ui`）：总览 / 每日趋势 / 会话排行 / 请求明细 / 失败请求五个标签页；来源、模型、时间范围（近 7 天 / 30 天 / 全部）全局筛选即时生效；表格点击表头排序；界面自动适配 ZCode 明暗主题
- **文本查询**（`/usage`）：总览、某天明细、按天汇总、会话排行、模型分布、失败请求
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
| `/usage` | 文本总览（累计 + 今日） |
| `/usage recent 50` | 最近 50 条逐条明细 |
| `/usage providers` | 按来源（官方套餐 / 自定义接入）汇总 |
| `/usage day 2026-10-14` | 某天的逐条明细 |
| `/usage sessions 10` | 会话用量排行 Top 10 |
| `/usage errors` | 最近的失败/取消请求 |
| “看看我哪个会话最烧 token” | 自然语言同样可以，会自动路由到对应查询 |

### 仪表盘预览

每日趋势按来源堆叠，官方套餐与 BYOK 一目了然：

![每日趋势](screenshots/dashboard-trend-light.png)

请求明细支持状态筛选与表头排序：

![请求明细](screenshots/dashboard-detail-light.png)

## 数据说明与隐私

- 数据源是 ZCode 客户端自动写入的本地 SQLite（`~/.zcode/cli/db/db.sqlite` 的 `model_usage` 表），本插件只做**只读**查询
- 不联网、不上传、不写库；仪表盘数据在生成时内嵌，仅存在于你自己机器上的一个 HTML 文件
- 仪表盘默认内嵌最近 3000 条请求，超过时界面会标注覆盖范围
- token 口径：输入列含缓存命中（缓存读单独列出），生成 = 输出 + 思考
- GLM Coding Plan 的**套餐配额余量**（5 小时池 / 周额度）由服务端计量，不在本地库中，请在 ZCode 的 **Usage Stats → Coding Plan** 查看

## 已知限制

- 只统计**本机、本账号**在 ZCode 内的请求
- 本地库结构可能随 ZCode 版本演进变化（当前在 0.16.x 验证通过）
- 界面基于 ZCode Desktop 的 Gen UI 内嵌渲染，需在桌面端使用

## License

[MIT](LICENSE)
