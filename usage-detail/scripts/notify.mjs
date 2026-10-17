#!/usr/bin/env node
// 跨平台系统通知（零依赖）：darwin=osascript / win32=PowerShell WinRT toast / linux=notify-send。
// 用法：node notify.mjs <title> <subtitle> <message>；任何失败静默退出 0，不影响调用方。
import { spawn } from 'node:child_process';

const [title, subtitle = '', msg = ''] = process.argv.slice(2);
if (!msg) process.exit(0);

try {
  if (process.platform === 'darwin') {
    const esc = (t) => String(t).replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    // 通知归因 ZCode.app：display notification 默认归属「脚本编辑器」（卷轴图标，观感差）；
    // 经 ZCode 转发后显示 ZCode 图标。is running 判断不会拉起未运行的 app——
    // 从 CLI/tmux 发通知时 ZCode 没开就回退系统默认归属。
    const n = `display notification "${esc(msg)}" with title "${esc(title)}" subtitle "${esc(subtitle)}"`;
    const script = 'if application id "dev.zcode.app" is running then\n' +
      `  tell application id "dev.zcode.app" to ${n}\n` +
      'else\n' + `  ${n}\n` + 'end if';
    spawn('osascript', ['-e', script], { detached: true, stdio: 'ignore' }).unref();
  } else if (process.platform === 'win32') {
    // WinRT toast：PowerShell 5.1 起自带，无需任何模块；toast 归因到系统 PowerShell 应用
    const sq = (t) => String(t).replace(/'/g, "''");
    const ps = `
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
$x = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$t = $x.GetElementsByTagName('text')
$t.Item(0).AppendChild($x.CreateTextNode('${sq(title)}')) | Out-Null
$t.Item(1).AppendChild($x.CreateTextNode('${sq(subtitle ? subtitle + ' — ' : '')}${sq(msg)}')) | Out-Null
$toast = [Windows.UI.Notifications.ToastNotification]::new($x)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('Microsoft.Windows.PowerShell').Show($toast)`;
    spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', ps],
      { detached: true, stdio: 'ignore' }).unref();
  } else if (process.platform === 'linux') {
    spawn('notify-send', [`--app-name=${title}`, subtitle ? `${subtitle}\n${msg}` : msg],
      { detached: true, stdio: 'ignore' }).unref();
  }
} catch (e) { /* 通知失败静默 */ }
process.exit(0);
