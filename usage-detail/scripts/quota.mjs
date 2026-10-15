#!/usr/bin/env node
// 查询 GLM Coding Plan 官方配额：/api/monitor/usage/quota/limit
// 凭据解析顺序：ANTHROPIC_AUTH_TOKEN 环境变量 → ZCode 本地 provider_config.json 中的套餐 API Key（只发往官方域名）
import https from 'node:https';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

function resolveEndpoint() {
  if (process.env.ANTHROPIC_AUTH_TOKEN && process.env.ANTHROPIC_BASE_URL) {
    return { token: process.env.ANTHROPIC_AUTH_TOKEN, base: process.env.ANTHROPIC_BASE_URL };
  }
  // 1) Claude 兼容配置里的 API Key
  const ruleFiles = [
    path.join(os.homedir(), '.claude/settings.json'),
    path.join(os.homedir(), '.zcode/v2/provider_config.json')
  ];
  for (const f of ruleFiles) {
    try {
      const j = JSON.parse(fs.readFileSync(f, 'utf8'));
      const rules = (j.config && j.config.providerConfigRules && j.config.providerConfigRules.providerRules) || [];
      for (const r of rules) {
        const c = r.config || {};
        const key = c.access && c.access.apiKey;
        const base = (c.api && c.api.baseUrl) || '';
        if (key && /anthropic|z\.ai|bigmodel/i.test(base + ' ' + (r.providerId || ''))) {
          return { token: key, base: base.replace(/\/api\/anthropic.*$/, '') || 'https://open.bigmodel.cn' };
        }
      }
    } catch (e) {}
  }
  // 1.5) 用户手动放置的令牌文件
  try {
    const tf = JSON.parse(fs.readFileSync(path.join(os.homedir(), '.zcode/usage-quota-token.json'), 'utf8'));
    if (tf && tf.token) return { token: tf.token, base: tf.base || 'https://open.bigmodel.cn' };
  } catch (e) {}
  // 2) ZCode 桌面端 OAuth 凭据（编码套餐登录态）
  try {
    const creds = JSON.parse(fs.readFileSync(path.join(os.homedir(), '.zcode/v2/credentials.json'), 'utf8'));
    const raw = creds['oauth:bigmodel:access_token'];
    if (raw) {
      let token = raw;
      try { const j = JSON.parse(raw); token = j.access_token || j.accessToken || raw; } catch (e) {}
      return { token: token, base: 'https://open.bigmodel.cn' };
    }
  } catch (e) {}
  return null;
}

const ep = resolveEndpoint();
if (!ep) {
  console.error(JSON.stringify({ error: '未找到套餐凭据（ANTHROPIC_AUTH_TOKEN/ANTHROPIC_BASE_URL 或 ZCode provider_config 中的编码套餐 API Key）' }));
  process.exit(2);
}
const base = ep.base.replace(/\/+$/, '');
const url = base + '/api/monitor/usage/quota/limit';

https.get(url, { headers: { Authorization: 'Bearer ' + ep.token, Accept: 'application/json' }, timeout: 15000 }, function (res) {
  let body = '';
  res.on('data', function (c) { body += c; });
  res.on('end', function () {
    if (res.statusCode !== 200) {
      console.error(JSON.stringify({ error: 'HTTP ' + res.statusCode, body: body.slice(0, 300) }));
      process.exit(1);
    }
    try {
      const j = JSON.parse(body);
      const limits = (j.data && j.data.limits) || j.limits || [];
      const out = limits.map(function (l) {
        return { type: l.type, percentage: l.percentage, resetTime: l.resetTime || l.reset_time || null };
      });
      console.log(JSON.stringify({ ok: true, platform: base.includes('z.ai') ? 'ZAI' : 'ZHIPU', limits: out }));
    } catch (e) {
      console.error(JSON.stringify({ error: '响应解析失败', body: body.slice(0, 300) }));
      process.exit(1);
    }
  });
}).on('error', function (e) {
  console.error(JSON.stringify({ error: e.message }));
  process.exit(1);
});
