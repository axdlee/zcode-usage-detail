#!/usr/bin/env node
// UserPromptSubmit hook：每次用户发消息时
// 1) 记录会话与提问时间戳到状态文件（turn-stats.mjs --current 守卫的唯一依据）
// 2) 注入「本轮统计指令」：模型在写最终回复正文之前自测本问速率，
//    把输出的统计行原样放进 Markdown 引用块附在回复最末尾。
// 输出必须为严格 JSON；任何异常静默退出，不影响对话。
// 机制参考 zcode-tps-monitor（MIT）实测经验：
//   - promptTs 绝不在别处覆盖，否则 --current 守卫误判"本问无数据"
//   - 统计行必须与完整回复正文同一条消息——客户端会把带工具调用的消息
//     折叠进「模型轨迹」区，统计行单独成条时用户只能看到统计行本身
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const STATS_SCRIPT = path.join(HERE, '..', 'scripts', 'turn-stats.mjs');
const STATE_FILE = process.env.ZCODE_USAGE_TURN_STATE || path.join(os.homedir(), '.zcode', 'usage-detail-turn.json');

const sid = process.env.ZCODE_SESSION_ID || process.env.CLAUDE_SESSION_ID || '';
try {
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  const now = Date.now();
  fs.writeFileSync(STATE_FILE, JSON.stringify({ sessionId: sid, ts: now, promptTs: now, source: 'prompt-submit' }));
} catch (e) {}

const INSTRUCTION = [
  '',
  '【本轮统计指令】若你在本次回答中已经调用过工具，请严格按以下顺序收尾：',
  `1. 在开始写最终回复正文之前，运行一次：node "${STATS_SCRIPT}" --turn --current`,
  '2. 然后输出完整的最终回复正文（用户需要的全部内容），并把脚本输出的那一行原样放入 Markdown 引用块（新行行首加「> 」）附在这条回复的最末尾；不要改写数字、不要追加任何其他内容。',
  '关键约束：统计行必须与完整回复正文在同一条消息里。绝不能让统计行（或只含统计行的短消息）单独成为你最后一条消息，也绝不能在写完全部回复正文之后再调用任何工具——客户端会折叠之前带工具调用的消息，用户将只能看到一行统计。',
  '降级规则：若你已经写完回复正文才发现没运行统计脚本，就直接省略统计行结束回答，不要事后补调用工具。',
  '注意：若脚本没有输出任何统计行（如本次回答没有调用过任何工具），则不要显示统计行、也不要为此额外调用工具。',
].join('\n');

process.stdout.write(JSON.stringify({
  hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: INSTRUCTION },
}));
