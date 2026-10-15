#!/usr/bin/env node
// ZCode 用量明细 · 会话侧栏面板的 MCP 服务（零依赖，手写最小 MCP stdio 协议）
//
// 与宿主的会话：
//   initialize → tools/list → tools/call / resources/read（newline-delimited JSON-RPC）
// 页面（ui/panel.html）通过 window.zcode 兼容层 callTool('usage_summary') 取数渲染。
// 只读：node:sqlite 只读连接 + 配额日志尾随，不写任何文件、不联网。
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const DB = process.env.ZCODE_USAGE_DB || path.join(os.homedir(), '.zcode/cli/db/db.sqlite');
const USER_PRICE = process.env.ZCODE_USAGE_PRICES || path.join(os.homedir(), '.zcode/usage-prices.json');
const HERE = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const PANEL_HTML = path.join(HERE, '..', 'ui', 'panel.html');
const DEFAULT_LIMIT = process.env.ZCODE_USAGE_LIMIT && Number(process.env.ZCODE_USAGE_LIMIT)
  ? Math.max(1, Math.min(20000, Number(process.env.ZCODE_USAGE_LIMIT)))
  : -1; // 默认全部

let db = null;
function openDb() {
  if (db) return db;
  db = new DatabaseSync(DB, { readOnly: true });
  return db;
}
// 单行单值查询（与 usage.sh 的 qr 语义一致）
function q1(sql) {
  const row = openDb().prepare(sql).get();
  if (!row) return '';
  return String(row[Object.keys(row)[0]]);
}

function priceText() {
  const p = USER_PRICE;
  try { return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null; } catch (e) { return null; }
}

// 全量 META（与 serve.mjs 同一形状：行数组 + 索引映射，前端聚合）
function metaSQL(limit, disk) {
  const pt = priceText();
  const PJ = pt != null ? `CAST('${pt.replace(/'/g, "''")}' AS text)` : 'NULL';
  return `
  WITH P AS (SELECT provider_id AS v, row_number() OVER (ORDER BY provider_id)-1 AS i FROM (SELECT DISTINCT provider_id FROM model_usage)),
       M AS (SELECT model_id AS v, row_number() OVER (ORDER BY model_id)-1 AS i FROM (SELECT DISTINCT model_id FROM model_usage)),
       S AS (SELECT session_id AS v, row_number() OVER (ORDER BY session_id)-1 AS i FROM (SELECT DISTINCT session_id FROM model_usage)),
       PJ AS (SELECT ${PJ} AS pj),
       R AS (SELECT * FROM model_usage ORDER BY started_at DESC, id DESC LIMIT ${limit})
  SELECT json_object(
    'providers',(SELECT json_group_array(v) FROM (SELECT v,i FROM P ORDER BY i)),
    'models',(SELECT json_group_array(v) FROM (SELECT v,i FROM M ORDER BY i)),
    'sessions',(SELECT json_group_array(coalesce(se.title,'')) FROM (SELECT v,i FROM S ORDER BY i) SI LEFT JOIN session se ON se.id=SI.v),
    'sessionDirs',(SELECT json_group_array(coalesce(se.directory,'')) FROM (SELECT v,i FROM S ORDER BY i) SI LEFT JOIN session se ON se.id=SI.v),
    'tools',(SELECT COALESCE(json_group_array(json_array(tool_name, c, f, d)),'[]') FROM (SELECT tool_name, count(*) AS c, sum(status<>'completed') AS f, CAST(round(avg(duration_ms)) AS int) AS d FROM tool_usage GROUP BY tool_name ORDER BY c DESC LIMIT 8)),
    'todos',(SELECT json_array(sum(CASE WHEN status='completed' THEN 1 ELSE 0 END), count(*)) FROM todo),
    'stability',(SELECT json_array(COALESCE(sum(retry_count),0), COALESCE(sum(cancelled_by_user),0), COALESCE(sum(CASE WHEN status='error' THEN 1 ELSE 0 END),0)) FROM model_usage),
    'hours',(SELECT COALESCE(json_group_object(hr, c),'{}') FROM (SELECT strftime('%H', started_at/1000,'unixepoch','localtime') AS hr, count(*) AS c FROM model_usage GROUP BY hr)),
    'compactions',(SELECT COALESCE(json_group_array(json_array(SI.i, c.cnt, c.maxpre, json(c.ts))),'[]') FROM (SELECT p.session_id AS sid, count(*) AS cnt, max(COALESCE(json_extract(p.data,'$.preCompactTokenCount'),0)) AS maxpre, json_group_array(strftime('%m-%d %H:%M', p.time_created/1000,'unixepoch','localtime')) AS ts FROM part p WHERE json_extract(p.data,'$.type')='compaction' GROUP BY p.session_id) c LEFT JOIN S SI ON SI.v = c.sid WHERE SI.i IS NOT NULL),
    'sessionTools',(SELECT COALESCE(json_group_array(json_array(SI.i, t.tool, t.c, t.ms)),'[]') FROM (SELECT session_id AS sid, tool_name AS tool, count(*) AS c, CAST(sum(duration_ms) AS int) AS ms FROM tool_usage GROUP BY session_id, tool_name) t LEFT JOIN S SI ON SI.v = t.sid WHERE SI.i IS NOT NULL),
    'disk', json('${JSON.stringify(disk).replace(/'/g, "''")}'),
    'prices',(SELECT CASE
          WHEN pj IS NULL OR NOT json_valid(pj) THEN json('{}')
          ELSE json_object('currency', COALESCE(json_extract(pj,'$.currency'),'USD'),
               'models', COALESCE(CASE WHEN json_type(pj,'$.models')='object'
                 THEN (SELECT json_group_object(lower(je.key), json(je.value)) FROM json_each(pj,'$.models') je
                       WHERE lower(je.key) IN (SELECT lower(v) FROM M) AND json_type(je.value)='object')
                 ELSE (SELECT json_group_object(lower(je.key), json(je.value)) FROM json_each(pj) je
                       WHERE lower(je.key) IN (SELECT lower(v) FROM M) AND json_type(je.value)='object')
               END, json('{}')))
        END FROM PJ),
    'total',(SELECT count(*) FROM model_usage),
    'covered',(SELECT count(*) FROM R),
    'gen',(SELECT datetime('now','localtime')),
    'rows',(SELECT json_group_array(json_array(
              SI.i, R.started_at, MI.i, PI.i,
              R.input_tokens, R.output_tokens+R.reasoning_tokens, R.cache_read_input_tokens,
              R.duration_ms,
              CASE R.status WHEN 'completed' THEN 0 WHEN 'error' THEN 1 WHEN 'cancelled' THEN 2 ELSE 3 END,
              CASE R.query_source WHEN 'main_turn' THEN 0 WHEN 'subagent' THEN 1 ELSE 2 END,
              R.cache_creation_input_tokens, R.time_to_first_token_ms, R.id))
            FROM R
            LEFT JOIN S SI ON SI.v = R.session_id
            LEFT JOIN M MI ON MI.v = R.model_id
            LEFT JOIN P PI ON PI.v = R.provider_id));`;
}

let metaCache = { at: 0, v: null };
function dataJSON(limit) {
  // -1 = 全部（LIMIT -1），0/空 = 默认，其余钳到 1-20000
  if (limit == null || Number(limit) === 0) limit = DEFAULT_LIMIT;
  else if (Number(limit) > 0) limit = Math.max(1, Math.min(20000, Number(limit)));
  if (metaCache.v && metaCache.v.limit === limit && Date.now() - metaCache.at < 15000) return metaCache.v.data;
  const disk = { logs: duMB(path.join(os.homedir(), '.zcode/v2/logs')), rollout: duMB(path.join(os.homedir(), '.zcode/cli/rollout')), artifacts: duMB(path.join(os.homedir(), '.zcode/cli/artifacts')), db: duMB(DB) };
  const data = JSON.parse(q1(metaSQL(limit, disk)));
  metaCache = { at: Date.now(), v: { limit, data } };
  return data;
}

let duCache = {};
function duMB(dir) {
  if (duCache[dir] && Date.now() - duCache[dir].at < 600000) return duCache[dir].v;
  let v = 0;
  try { v = parseInt(execDu(dir), 10) || 0; } catch (e) {}
  duCache[dir] = { at: Date.now(), v };
  return v;
}
import { execFileSync } from 'node:child_process';
function execDu(dir) { return execFileSync('du', ['-sm', dir], { encoding: 'utf8' }).split('\t')[0]; }

// 时间范围 → [fromMs, toMs]（today/yesterday/7d/30d/month/last_month/all 或 from/to ISO 日期）
function rangeToSpan(a) {
  const now = new Date();
  const d0 = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const addDays = (d, n) => new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
  let from = null, to = null;
  const range = a && a.range || '7d';
  if (a && a.from) from = new Date(a.from + 'T00:00:00').getTime();
  if (a && a.to) to = new Date(a.to + 'T00:00:00').getTime() + 86400000;
  if (from || to) return [from || 0, to || Date.now() + 86400000];
  switch (range) {
    case 'today': return [d0.getTime(), Date.now()];
    case 'yesterday': return [addDays(d0, -1).getTime(), d0.getTime()];
    case '7d': return [addDays(d0, -6).getTime(), Date.now()];
    case '30d': return [addDays(d0, -29).getTime(), Date.now()];
    case 'month': return [new Date(now.getFullYear(), now.getMonth(), 1).getTime(), Date.now()];
    case 'last_month': return [new Date(now.getFullYear(), now.getMonth() - 1, 1).getTime(), new Date(now.getFullYear(), now.getMonth(), 1).getTime()];
    default: return [0, Date.now() + 86400000];
  }
}

// 按时间范围聚合：KPI/每日/时段/来源/模型（rows 内存聚合，行来自全量 META 缓存）
function buildTrend(a) {
  const [from, to] = rangeToSpan(a);
  const D = dataJSON(-1);
  const R = (D.rows || []).filter((r) => r[1] >= from && r[1] < to);
  const MD = D.models || [], PV = D.providers || [];
  let inn = 0, out = 0, ca = 0, genMs = 0, gen = 0;
  const dayMap = {}, hourMap = {}, pvMap = {}, mdMap = {};
  const states = { completed: 0, error: 0, cancelled: 0 };
  for (const r of R) {
    inn += r[4]; out += r[5]; ca += r[6];
    if (r[8] === 0) { states.completed++; gen += r[5]; genMs += Math.max(1, r[7] - (r[11] || 0)); }
    else if (r[8] === 1) states.error++; else if (r[8] === 2) states.cancelled++;
    const d = new Date(r[1]);
    const key = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
    dayMap[key] = (dayMap[key] || 0) + r[4] + r[5];
    hourMap[d.getHours()] = (hourMap[d.getHours()] || 0) + 1;
    pvMap[PV[r[3]] || '?'] = (pvMap[PV[r[3]] || '?'] || 0) + r[4] + r[5];
    mdMap[MD[r[2]] || '?'] = (mdMap[MD[r[2]] || '?'] || 0) + r[4] + r[5];
  }
  const pct = (m) => Object.keys(m).map((k) => ({ name: k, tokens: m[k], pct: Math.round(m[k] / (inn + out) * 1000) / 10 })).sort((x, y) => y.tokens - x.tokens);
  const dayKeys = Object.keys(dayMap).sort();
  return {
    range: (a && a.range) || (a && (a.from || a.to) ? 'custom' : '7d'),
    from: dayKeys[0] || null, to: dayKeys[dayKeys.length - 1] || null,
    kpi: { requests: R.length, inTokens: inn, outTokens: out, cacheRead: ca, cacheRate: inn ? Math.round(ca / inn * 100) : null, avgTps: genMs ? Math.round(gen / genMs * 1000) : null, ...states },
    daily: dayKeys.map((k) => ({ day: k.slice(5), tokens: dayMap[k] })),
    hours: Object.keys(hourMap).map((h) => ({ h: Number(h), req: hourMap[h] })).sort((x, y) => x.h - y.h),
    providers: pct(pvMap).slice(0, 6),
    models: pct(mdMap).slice(0, 8),
  };
}

// 会话列表（真 session_id，按 token Top N，可按时间范围过滤）
function buildSessions(a) {
  const [from, to] = rangeToSpan(a);
  const rows = openDb().prepare(`
    SELECT m.session_id AS sid, MAX(s.title) AS title, MAX(s.directory) AS dir,
           COUNT(*) AS req, SUM(m.input_tokens) AS inn,
           SUM(m.output_tokens + m.reasoning_tokens) AS out,
           SUM(m.cache_read_input_tokens) AS ca,
           MAX(m.started_at) AS last
    FROM model_usage m LEFT JOIN session s ON s.id = m.session_id
    WHERE m.started_at >= ? AND m.started_at < ? AND m.session_id IS NOT NULL AND m.session_id <> ''
    GROUP BY m.session_id ORDER BY SUM(m.input_tokens + m.output_tokens + m.reasoning_tokens) DESC LIMIT 20
  `).all(from, to);
  return rows.map((r) => ({
    id: r.sid, title: r.title || '（无标题）', dir: r.dir || null,
    req: r.req, tokens: (r.inn || 0) + (r.out || 0),
    cacheRate: r.inn ? Math.round((r.ca || 0) / r.inn * 100) : null, last: r.last,
  }));
}

// 单会话详情：元信息 + 聚合 + 最近 15 条请求 + 压缩/模型切换事件
function buildSessionDetail(id) {
  if (!id) return { error: '缺少会话 id' };
  const db = openDb();
  const meta = db.prepare(`SELECT id, title, directory, time_created FROM session WHERE id = ?`).get(id) || { id, title: '（无标题）', directory: null, time_created: null };
  const agg = db.prepare(`
    SELECT COUNT(*) AS req,
           COALESCE(SUM(input_tokens),0) AS inn,
           COALESCE(SUM(output_tokens+reasoning_tokens),0) AS out,
           COALESCE(SUM(cache_read_input_tokens),0) AS ca,
           MIN(started_at) AS first, MAX(started_at) AS last,
           SUM(CASE WHEN status='error' THEN 1 ELSE 0 END) AS errors
    FROM model_usage WHERE session_id = ?`).get(id);
  const perf = db.prepare(`
    SELECT COALESCE(SUM(output_tokens+reasoning_tokens),0) AS gen,
           COALESCE(SUM(max(duration_ms - COALESCE(time_to_first_token_ms, 0), 1)), 0) AS ms
    FROM model_usage WHERE session_id = ? AND status='completed'`).get(id);
  const models = db.prepare(`SELECT model_id AS name, SUM(input_tokens+output_tokens+reasoning_tokens) AS tokens FROM model_usage WHERE session_id = ? GROUP BY model_id ORDER BY tokens DESC`).all(id);
  const providers = db.prepare(`SELECT provider_id AS name, COUNT(*) AS req FROM model_usage WHERE session_id = ? GROUP BY provider_id ORDER BY req DESC`).all(id);
  const tools = db.prepare(`SELECT tool_name AS name, COUNT(*) AS req FROM tool_usage WHERE session_id = ? GROUP BY tool_name ORDER BY req DESC LIMIT 6`).all(id);
  const compactions = db.prepare(`SELECT COUNT(*) AS cnt, MAX(COALESCE(json_extract(data,'$.preCompactTokenCount'),0)) AS pre FROM part WHERE session_id = ? AND json_extract(data,'$.type')='compaction'`).get(id);
  const recent = db.prepare(`
    SELECT datetime(started_at/1000,'unixepoch','localtime') AS t, model_id AS model,
           input_tokens AS inTok, output_tokens+reasoning_tokens AS outTok,
           duration_ms AS dur, time_to_first_token_ms AS ttft,
           CASE status WHEN 'completed' THEN 0 WHEN 'error' THEN 1 WHEN 'cancelled' THEN 2 ELSE 3 END AS status
    FROM model_usage WHERE session_id = ? ORDER BY started_at DESC LIMIT 15`).all(id);
  let avgTps = null;
  if (perf && perf.ms > 0) avgTps = Math.round(perf.gen / perf.ms * 1000);
  return {
    id, title: meta.title, dir: meta.directory,
    created: meta.time_created, requests: agg.req,
    inTokens: agg.inn, outTokens: agg.out,
    cacheRate: agg.inn ? Math.round(agg.ca / agg.inn * 100) : null,
    avgTps, first: agg.first, last: agg.last, errors: agg.errors || 0,
    models, providers, tools,
    compactions: compactions && compactions.cnt ? { cnt: compactions.cnt, pre: compactions.pre } : null,
    recent,
  };
}

// ---- 侧栏面板摘要：服务端预聚合（侧栏窄、结构化输出须 ≤64KiB，不做全行下发）----
function buildSummary() {
  const D = dataJSON(DEFAULT_LIMIT);
  const R = D.rows || [], MD = D.models || [], PV = D.providers || [], TL = D.sessions || [];
  const today0 = new Date(); today0.setHours(0, 0, 0, 0);
  let inn = 0, out = 0, ca = 0, todayReq = 0;
  const pvAgg = {}, mdAgg = {};
  const sessAgg = {};
  for (const r of R) {
    inn += r[4]; out += r[5]; ca += r[6];
    if (r[1] >= today0.getTime()) todayReq++;
    const pv = PV[r[3]] || '?', md = MD[r[2]] || '?';
    pvAgg[pv] = (pvAgg[pv] || 0) + r[4] + r[5];
    mdAgg[md] = (mdAgg[md] || 0) + r[4] + r[5];
    const s = sessAgg[r[0]] || (sessAgg[r[0]] = { title: TL[r[0]] || '（无标题）', req: 0, tot: 0, last: 0 });
    s.req++; s.tot += r[4] + r[5]; if (r[1] > s.last) s.last = r[1];
  }
  const pct = (m) => Object.keys(m).map((k) => ({ name: k, tokens: m[k], pct: Math.round(m[k] / (inn + out) * 1000) / 10 }))
    .sort((a, b) => b.tokens - a.tokens);
  // 近 14 天每日 token（供面板 sparkline）
  const dayMap = {};
  for (const r of R) {
    const d = new Date(r[1]);
    const key = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0');
    dayMap[key] = (dayMap[key] || 0) + r[4] + r[5];
  }
  const daily = Object.keys(dayMap).sort().slice(-14).map((k) => ({ day: k.slice(5), tokens: dayMap[k] }));
  const hourMap = D.hours || {};
  const hours = Object.keys(hourMap).map((h) => ({ h: Number(h), req: hourMap[h] })).sort((a, b) => a.h - b.h);
  const failures = (D.stability || [0, 0, 0])[2] || 0;
  const tools = (D.tools || []).slice(0, 5).map((t) => ({ name: String(t[0]).replace(/^mcp__/, ''), req: t[1] }));
  const states = { completed: 0, error: 0, cancelled: 0 };
  for (const r of R) { if (r[8] === 0) states.completed++; else if (r[8] === 1) states.error++; else if (r[8] === 2) states.cancelled++; }
  const topSess = Object.values(sessAgg).sort((a, b) => b.tot - a.tot).slice(0, 5);
  // 当前 5h 窗口（与 usage.sh blocks 口径一致：R 按时间降序，从最新往旧，相邻间隔 ≥5h 即断窗）
  let win = { req: 0, tok: 0, start: 0 };
  for (let i = 0; i < R.length; i++) {
    if (i === 0) { win.start = R[0][1]; win.req = 1; win.tok = R[0][4] + R[0][5]; continue; }
    if (R[i - 1][1] - R[i][1] >= 18000000) break;
    win.req++; win.tok += R[i][4] + R[i][5]; win.start = R[i][1];
  }
  // ⑤ 剩余请求估算：按最近 3 个完整窗口的平均请求数，推算当前窗口还可发起多少次
  const wins = [];
  let cur = { req: 0 };
  for (let i = 0; i < R.length; i++) {
    cur.req++;
    if (i < R.length - 1 && R[i][1] - R[i + 1][1] >= 18000000) { wins.push(cur); cur = { req: 0 }; }
  }
  if (cur.req) wins.push(cur);
  // R 按时间降序：wins[0] 是最新（进行中），其后是完整窗口
  const full = wins.slice(1, 4);
  const avgReq = full.length ? Math.round(full.reduce((a, w) => a + w.req, 0) / full.length) : 0;
  const windowEstimate = avgReq > 0 && win.start
    ? { avgReq, basedOn: full.length, remainingReq: Math.max(0, avgReq - win.req) }
    : null;
  return {
    kpi: {
      covered: D.covered, total: D.total, gen: D.gen,
      requests: inn + out ? R.length : 0,
      inTokens: inn, outTokens: out, cacheRead: ca,
      cacheRate: inn ? Math.round(ca / inn * 100) : null,
      todayRequests: todayReq,
    },
    providers: pct(pvAgg).slice(0, 5),
    models: pct(mdAgg).slice(0, 6),
    topSessions: topSess.map((s) => ({ title: s.title.slice(0, 40), req: s.req, tokens: s.tot, last: s.last })),
    window: win,
    windowEstimate,
    daily, hours, tools, failures, states,
    disk: D.disk || {},
    serveUrl: 'http://127.0.0.1:7741',
  };
}

function buildDetail(args) {
  const limit = Math.max(1, Math.min(200, Number(args && args.limit) || 30));
  const offset = Math.max(0, Number(args && args.offset) || 0);
  const status = args && args.status != null ? Number(args.status) : null;
  const where = status != null && status >= 0
    ? `WHERE CASE status WHEN 'completed' THEN 0 WHEN 'error' THEN 1 WHEN 'cancelled' THEN 2 ELSE 3 END = ${status | 0} `
    : '';
  const rows = JSON.parse(q1(`SELECT json_group_array(json_array(
      datetime(R.started_at/1000,'unixepoch','localtime'),
      R.model_id, R.provider_id,
      R.input_tokens, R.output_tokens+R.reasoning_tokens, R.cache_read_input_tokens,
      R.cache_creation_input_tokens, R.duration_ms, R.time_to_first_token_ms,
      CASE R.status WHEN 'completed' THEN 0 WHEN 'error' THEN 1 WHEN 'cancelled' THEN 2 ELSE 3 END,
      COALESCE((SELECT title FROM session WHERE id = R.session_id),'')))
    FROM (SELECT * FROM model_usage ${where} ORDER BY started_at DESC, id DESC LIMIT ${limit} OFFSET ${offset}) R`));
  return { offset, limit, rows: rows || [] };
}

// ---------- 最小 MCP stdio 协议 ----------
const SERVER_INFO = { name: 'usage-detail-panel', version: '0.10.0' };
// 完整版仪表盘作为侧栏页面（与 /usage-ui、serve 本地面板同源同界面，单一维护点）：
// 调 usage.sh dashboard 生成自包含片段（默认全量历史），包上独立壳（主题变量+页签行为）。
import { execFile } from 'node:child_process';
const { SHELL_CSS, TAB_JS } = await import('../shell.mjs');
const USAGE_SH = path.join(HERE, '..', 'usage.sh');
let dashCache = { at: 0, html: null };
function getPanelHtml() {
  return new Promise((resolve, reject) => {
    if (dashCache.html && Date.now() - dashCache.at < 60000) return resolve(dashCache.html);
    const tmp = path.join(os.tmpdir(), 'usage-detail-panel-' + process.pid + '.html');
    execFile('bash', [USAGE_SH, 'dashboard', tmp], { timeout: 120000, env: { ...process.env, ZCODE_USAGE_LIMIT: process.env.ZCODE_USAGE_LIMIT || '-1' } }, (err) => {
      if (err) return reject(new Error('生成仪表盘失败：' + (err.message || err)));
      try {
        const frag = fs.readFileSync(tmp, 'utf8');
        fs.unlinkSync(tmp);
        const html = '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ZCode 用量面板</title><style>' + SHELL_CSS + '</style></head><body style="padding:10px 12px 40px;max-width:none">' + frag + '<script>' + TAB_JS + '</scr' + 'ipt></body></html>';
        dashCache = { at: Date.now(), html };
        resolve(html);
      } catch (e) { reject(e); }
    });
  });
}

const TOOLS = [
  {
    name: 'usage_summary',
    description: 'ZCode 本地用量摘要：请求/token KPI、来源与模型占比、Top 会话、当前 5h 窗口与套餐配额（零密钥读客户端日志）。只读本机 SQLite。',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
    _meta: { ui: { resourceUri: 'ui://usage-detail/panel.html', surface: 'usage', visibility: ['model', 'app'] } },
  },
  {
    name: 'usage_trend',
    description: '按时间范围的用量聚合：KPI、每日 token、时段分布、来源/模型构成。range: today|yesterday|7d|30d|month|last_month|all，或 from/to（YYYY-MM-DD）。',
    inputSchema: {
      type: 'object',
      properties: {
        range: { type: 'string' }, from: { type: 'string' }, to: { type: 'string' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'usage_sessions',
    description: '会话列表（按 token Top 20，含真会话 id）：标题、请求数、token、缓存率、最后活动。时间范围参数同 usage_trend。',
    inputSchema: {
      type: 'object',
      properties: { range: { type: 'string' }, from: { type: 'string' }, to: { type: 'string' } },
      additionalProperties: false,
    },
  },
  {
    name: 'usage_session',
    description: '单个会话详情：元信息、聚合（含平均 tok/s）、模型/来源/工具分布、压缩事件、最近 15 条请求。',
    inputSchema: {
      type: 'object',
      properties: { id: { type: 'string', description: '会话 id' } },
      required: ['id'],
      additionalProperties: false,
    },
  },
  {
    name: 'open_full_panel',
    description: '打开本地常驻完整面板（http://127.0.0.1:7741）。若服务未运行会自动以只读方式启动（仅监听本机）。返回 { url }。',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  },
  {
    name: 'usage_detail',
    description: 'ZCode 本地请求明细分页（每行：时间/模型/来源/输入/生成/缓存读/缓存写/耗时ms/首字ms/状态/会话）。status: 0 完成 1 失败 2 取消 3 进行中，缺省全部。',
    inputSchema: {
      type: 'object',
      properties: {
        limit: { type: 'number', description: '条数（1-200，默认 30）' },
        offset: { type: 'number', description: '偏移（默认 0）' },
        status: { type: 'number', description: '状态过滤，缺省全部' },
      },
      additionalProperties: false,
    },
  },
];

import http2 from 'node:http';
import { spawn } from 'node:child_process';
function serveRunning() {
  return new Promise((resolve) => {
    const req = http2.get('http://127.0.0.1:7741/api/live', { timeout: 1200 }, (res) => { res.resume(); resolve(res.statusCode === 200); });
    req.on('error', () => resolve(false));
    req.on('timeout', () => { req.destroy(); resolve(false); });
  });
}
async function ensureServe() {
  if (await serveRunning()) return { url: 'http://127.0.0.1:7741', started: false };
  const child = spawn('node', [path.join(HERE, '..', 'serve.mjs'), '7741'], { detached: true, stdio: 'ignore' });
  child.unref();
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 400));
    if (await serveRunning()) return { url: 'http://127.0.0.1:7741', started: true };
  }
  return { url: 'http://127.0.0.1:7741', started: false, error: '启动超时，可手动运行 usage.sh serve' };
}

function handleToolCall(name, args) {
  if (name === 'usage_summary') {
    return { structuredContent: buildSummary(), content: [{ type: 'text', text: '用量摘要已生成' }] };
  }
  if (name === 'usage_detail') {
    const out = buildDetail(args);
    return { structuredContent: out, content: [{ type: 'text', text: (out.rows || []).length + ' 条明细' }] };
  }
  if (name === 'usage_trend') {
    return { structuredContent: buildTrend(args), content: [{ type: 'text', text: '趋势聚合' }] };
  }
  if (name === 'usage_sessions') {
    return { structuredContent: { sessions: buildSessions(args) }, content: [{ type: 'text', text: '会话列表' }] };
  }
  if (name === 'usage_session') {
    return { structuredContent: buildSessionDetail(args && args.id), content: [{ type: 'text', text: '会话详情' }] };
  }
  if (name === 'open_full_panel') {
    return ensureServe().then((r) => ({ structuredContent: r, content: [{ type: 'text', text: r.url + (r.started ? '（已启动）' : '（已在运行）') }] }));
  }
  return { isError: true, content: [{ type: 'text', text: '未知工具：' + name }] };
}

function dispatch(msg) {
  const { id, method, params } = msg;
  function reply(result) {
    if (id == null) return;
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, result }) + '\n');
  }
  function replyErr(code, message) {
    if (id == null) return;
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }) + '\n');
  }
  try {
    switch (method) {
      case 'initialize':
        reply({
          protocolVersion: params && params.protocolVersion || '2025-06-18',
          capabilities: { tools: { listChanged: false }, resources: { subscribe: false, listChanged: false } },
          serverInfo: SERVER_INFO,
        });
        return;
      case 'ping': reply({}); return;
      case 'tools/list': reply({ tools: TOOLS }); return;
      case 'tools/call': {
        const r = handleToolCall(params && params.name, params && params.arguments);
        reply(r);
        return;
      }
      case 'resources/list':
        reply({ resources: [{ uri: 'ui://usage-detail/panel.html', mimeType: 'text/html;profile=mcp-app', name: '用量面板' }] });
        return;
      case 'resources/read': {
        const uri = params && params.uri;
        if (uri !== 'ui://usage-detail/panel.html') { replyErr(-32602, '未知资源：' + uri); return; }
        getPanelHtml().then((html) => {
          reply({ contents: [{ uri, mimeType: 'text/html;profile=mcp-app', text: html }] });
        }).catch((e) => replyErr(-32603, (e && e.message) || String(e)));
        return;
      }
      default:
        if (method && method.startsWith('notifications/')) return;
        replyErr(-32601, '方法不存在：' + method);
    }
  } catch (e) {
    replyErr(-32603, '内部错误：' + (e && e.message || e));
  }
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buf += chunk;
  let idx;
  while ((idx = buf.indexOf('\n')) !== -1) {
    const line = buf.slice(0, idx).trim();
    buf = buf.slice(idx + 1);
    if (!line) continue;
    try { dispatch(JSON.parse(line)); } catch (e) { /* 坏行忽略 */ }
  }
});
process.stdin.on('end', () => process.exit(0));
