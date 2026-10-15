---
description: 生成当前会话的交互式用量仪表盘，显示会话身份供核对。
argument-hint: "[--session 会话ID | --directory 项目绝对路径]"
skills: usage-detail
---

用户要以图形界面查看当前会话用量。按 `usage-detail` 技能的「当前会话」流程执行 `dashboard-this` 子命令，参数为 $ARGUMENTS；输出文件使用宿主会话可视化目录中的 `usage-this-dashboard.html`。

按技能的仪表盘交付方式在最终回复引用生成文件，并注明解析到的会话标题和定位方式。自动定位时提示用户核对标题，多窗口下可用 `--session ID` 指定会话。
