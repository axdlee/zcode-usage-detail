#!/usr/bin/env node
// Stop hook（async: true，fire-and-forget）：每轮回复结束时本地计算统计并发系统通知。
// 官方语义：async hook 的后台 stdout 不会注入上下文、不影响回合——正好：我们要的就是
// 「零模型开销」的统计出口。统计行不进对话（进对话必经模型，见 README），改走系统通知。
// 开关：~/.zcode/usage-turnstats.json {"enabled":true,"mode":"notify"}；任何异常静默退出。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const STATS_SCRIPT = path.join(HERE, '..', 'scripts', 'turn-stats.mjs');

function readSwitch() {
  try {
    const v = JSON.parse(fs.readFileSync(path.join(os.homedir(), '.zcode', 'usage-turnstats.json'), 'utf8'));
    if (!v || v.enabled !== true) return null;
    return v.mode === 'notify' ? 'notify' : (v.mode === 'inject' ? 'inject' : 'inject'); // 兼容旧 {"enabled":true}（无 mode）= inject
  } catch (e) { return null; }
}

try {
  if (readSwitch() !== 'notify') process.exit(0);
  if (process.platform !== 'darwin') process.exit(0); // osascript 通知仅 macOS；其他平台静默
  const line = execFileSync(process.execPath, [STATS_SCRIPT, '--turn', '--current'], { encoding: 'utf8', timeout: 15000 }).trim();
  const msg = line.split('\n').filter((l) => l.includes('本轮用量'))[0] || line.split('\n')[0] || '';
  if (!msg) process.exit(0);
  const esc = (t) => t.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
  execFileSync('osascript', ['-e', `display notification "${esc(msg)}" with title "ZCode 用量" subtitle "本轮统计（零上下文开销）"`], { timeout: 8000, stdio: 'ignore' });
} catch (e) {}
process.exit(0);
