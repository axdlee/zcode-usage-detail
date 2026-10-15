#!/usr/bin/env node
// ZCode 用量明细 · 本地常驻面板服务
// 只读查询本地 SQLite，仅监听 127.0.0.1。页面数据一次加载 /api/data，
// 燃烧率等实时指标轻量轮询 /api/live（默认 5s），不重复拉全量。
import http from 'node:http';
import { execFileSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const port = Number(process.argv[2]) || 7741;
const DB = process.env.ZCODE_USAGE_DB || path.join(os.homedir(), '.zcode/cli/db/db.sqlite');
const USER_PRICE = process.env.ZCODE_USAGE_PRICES || path.join(os.homedir(), '.zcode/usage-prices.json');
const HERE = path.dirname(fs.realpathSync(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')));
const USAGE_SH = path.join(HERE, 'usage.sh');

if (!fs.existsSync(DB)) {
  console.error('未找到 ZCode 本地数据库：' + DB);
  process.exit(1);
}

// node:sqlite 只读连接（Node ≥22.5）：常驻进程内直接查询，省去每次 spawn sqlite3 CLI 的进程开销
let db;
try {
  db = new DatabaseSync(DB, { readOnly: true });
} catch (e) {
  console.error('node:sqlite 打开数据库失败（需要 Node ≥ 22.5）：' + e.message);
  process.exit(1);
}
function q(sql) {
  const row = db.prepare(sql).get();
  if (!row) return '';
  return String(row[Object.keys(row)[0]]);
}

function pricePath() {
  if (process.env.ZCODE_USAGE_PRICES && fs.existsSync(process.env.ZCODE_USAGE_PRICES)) return process.env.ZCODE_USAGE_PRICES;
  if (fs.existsSync(USER_PRICE)) return USER_PRICE;
  const d = path.join(HERE, 'default-prices.json');
  return fs.existsSync(d) ? d : null;
}

const META_SQL = (pfText, limit, disk) => `
  WITH P AS (SELECT provider_id AS v, row_number() OVER (ORDER BY provider_id)-1 AS i FROM (SELECT DISTINCT provider_id FROM model_usage)),
       M AS (SELECT model_id AS v, row_number() OVER (ORDER BY model_id)-1 AS i FROM (SELECT DISTINCT model_id FROM model_usage)),
       S AS (SELECT session_id AS v, row_number() OVER (ORDER BY session_id)-1 AS i FROM (SELECT DISTINCT session_id FROM model_usage)),
       PJ AS (SELECT ${pfText != null ? `CAST('${pfText.replace(/'/g, "''")}' AS text)` : 'NULL'} AS pj),
       R AS (SELECT * FROM model_usage ORDER BY started_at DESC LIMIT ${limit})
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
              ELSE json_object('currency', COALESCE(json_extract(pj,'$.currency'),'CNY'),
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

// limit 归一：未指定/非正数 = 全部（LIMIT -1），正数钳到 1-20000
function clampLimit(v) {
  const n = Number(v);
  if (!Number.isFinite(n) || n <= 0) return -1;
  return Math.max(1, Math.min(20000, Math.round(n)));
}

function dataJSON(limit) {
  limit = clampLimit(limit);
  // node:sqlite 没有 CLI 的 readfile()：价格文件内容在 node 侧读好后内联（单引号转义）
  const pp = pricePath();
  const pfText = pp ? fs.readFileSync(pp, 'utf8') : null;
  return q(META_SQL(pfText, limit, diskJSON()));
}

function liveJSON() {
  const win = q(`WITH cur AS (SELECT count(*) AS req,
                       COALESCE(sum(input_tokens),0) AS inn,
                       COALESCE(sum(output_tokens+reasoning_tokens),0) AS gen,
                       min(started_at) AS st
                FROM model_usage WHERE started_at > (unixepoch()*1000 - 18000000))
         SELECT req, inn+gen AS tok,
                CAST(round((inn+gen) / max(0.1,(unixepoch()*1000 - COALESCE(st, unixepoch()*1000))/3600000.0)) AS int),
                COALESCE(st, 0)
         FROM cur;`).trim().split('|').map(Number);
  const today = q(`SELECT count(*), COALESCE(sum(input_tokens+output_tokens+reasoning_tokens),0),
                          sum(CASE WHEN status<>'completed' THEN 1 ELSE 0 END)
                   FROM model_usage WHERE date(started_at/1000,'unixepoch','localtime')=date('now','localtime');`).trim().split('|').map(Number);
  return {
    window: { req: win[0] || 0, tok: win[1] || 0, rateH: win[2] || 0, start: win[3] || 0 },
    today: { req: today[0] || 0, tok: today[1] || 0, fail: today[2] || 0 },
    gen: Date.now()
  };
}

let diskCache = { at: 0, v: {} };
function diskJSON() {
  if (Date.now() - diskCache.at < 600000) return diskCache.v;
  const dirs = {
    logs: path.join(os.homedir(), '.zcode/v2/logs'),
    rollout: path.join(os.homedir(), '.zcode/cli/rollout'),
    artifacts: path.join(os.homedir(), '.zcode/cli/artifacts'),
    db: DB
  };
  const out = {};
  for (const [k, dir] of Object.entries(dirs)) {
    try { out[k] = parseInt(execFileSync('du', ['-sm', dir], { encoding: 'utf8' }).split('\t')[0], 10) || 0; }
    catch (e) { out[k] = 0; }
  }
  diskCache = { at: Date.now(), v: out };
  return out;
}

let quotaCache = { at: 0, v: null };
function quotaJSON() {
  if (quotaCache.v && Date.now() - quotaCache.at < 60000) return quotaCache.v;
  try {
    const out = execFileSync(process.execPath, [path.join(HERE, 'quota.mjs')], { encoding: 'utf8', timeout: 25000 });
    quotaCache = { at: Date.now(), v: JSON.parse(out) };
  } catch (e) {
    let msg = e.message;
    try { msg = JSON.parse(e.stdout || '{}').error || msg; } catch (e2) {}
    quotaCache = { at: Date.now(), v: { ok: false, error: String(msg).slice(0, 160) } };
  }
  return quotaCache.v;
}

function requestJSON(id) {
  if (!/^[A-Za-z0-9_-]+$/.test(id)) return { error: '非法 id' };
  const row = q(`SELECT json_object(
    'raw_usage_json', raw_usage_json,
    'provider_metadata_json', provider_metadata_json,
    'finish_reason', finish_reason,
    'error_code', error_code,
    'error_message', error_message,
    'agent', agent,
    'variant', variant)
  FROM model_usage WHERE id = '${id}';`).trim();
  return row ? JSON.parse(row) : { error: '未找到该请求' };
}

function renderFragment(limit) {
  const out = path.join(os.tmpdir(), 'zcode-usage-serve-' + process.pid + '.html');
  const args = [USAGE_SH, 'dashboard', out];
  if (limit > 0) args.push(String(limit)); // -1（全部）走脚本默认，避免 num_arg 校验负数
  execFileSync('bash', args, { encoding: 'utf8', timeout: 120000 });
  let html = fs.readFileSync(out, 'utf8');
  try { fs.unlinkSync(out); } catch (e) {}
  // 切换为服务模式：数据走 /api/data，由 boot 函数异步加载
  html = html.replace(/^const DATA =\n.*$/m, "const DATA = null;\nwindow.__USAGE_DATA_URL__ = '/api/data';\nwindow.__USAGE_SERVE__ = true;");
  if (html.indexOf('__USAGE_DATA_URL__') < 0) throw new Error('dashboard 生成结果异常');
  // 服务态附加：刷新按钮 + 实时燃烧率角标（5s 轻轮询）
  html += `<script>
(function () {
  var t = setInterval(function () {
    var c = document.querySelector('.viz-controls');
    if (!c || !window.__usageBootDone) return;
    clearInterval(t);
    var b = document.createElement('button');
    b.type = 'button'; b.className = 'btn'; b.style.margin = '0'; b.style.fontSize = '12px';
    b.textContent = '刷新数据';
    b.addEventListener('click', function () { b.disabled = true; b.textContent = '刷新中…'; location.reload(); });
    c.appendChild(b);
    var badge = document.createElement('span');
    badge.id = 'ud-live-badge'; badge.className = 'text-small text-muted';
    c.appendChild(badge);
    function tick() {
      fetch('/api/live').then(function (r) { return r.json(); }).then(function (j) {
        badge.textContent = '● 实时 · 燃烧率 ' + Number(j.window.rateH || 0).toLocaleString('zh-CN') + ' token/h · 近 5h ' + Number(j.window.tok || 0).toLocaleString('zh-CN') + ' token · 今日 ' + Number(j.today.req || 0).toLocaleString('zh-CN') + ' 次';
      }).catch(function () {});
    }
    tick();
    setInterval(tick, 5000);
  }, 200);
})();
</script>`;
  return html;
}


// 独立页面样式壳：Gen UI 宿主不在浏览器里，工具类与主题变量由本壳提供（明暗随系统）
const { SHELL_CSS, TAB_JS } = await import('./shell.mjs');


let frag = { html: null, limit: 0, at: 0 };
function getFragment(limit) {
  limit = clampLimit(limit);
  if (!frag.html || frag.limit !== limit || Date.now() - frag.at > 30000) {
    frag = { html: renderFragment(limit), limit, at: Date.now() };
  }
  return frag.html;
}

// 启动时价格表每日自动同步一次（与 dashboard 口径一致，可 env 关闭）
try {
  if (process.env.ZCODE_USAGE_NO_AUTOSYNC !== '1') {
    let stale = !fs.existsSync(USER_PRICE);
    if (!stale) stale = Date.now() - fs.statSync(USER_PRICE).mtimeMs >= 86400e3;
    if (stale && fs.existsSync(process.env.ZCODE_USAGE_PRICES || '/dev/null') === false || stale) {
      spawn('bash', [USAGE_SH, 'prices', 'sync'], { detached: true, stdio: 'ignore' }).unref();
    }
  }
} catch (e) {}

const server = http.createServer(function (req, res) {
  const u = new URL(req.url, 'http://127.0.0.1');
  try {
    if (req.method === 'GET' && (u.pathname === '/' || u.pathname === '/index.html')) {
      const limit = u.searchParams.get('limit');
      const fragHtml = getFragment(limit);
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ZCode 用量面板</title><style>' + SHELL_CSS + '</style></head><body>' + fragHtml + '<script>' + TAB_JS + '</scr' + 'ipt></body></html>');
    } else if (req.method === 'GET' && u.pathname === '/api/data') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(dataJSON(u.searchParams.get('limit')));
    } else if (req.method === 'GET' && u.pathname === '/api/quota') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(quotaJSON()));
    } else if (req.method === 'GET' && u.pathname === '/api/request') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(requestJSON(u.searchParams.get('id') || '')));
    } else if (req.method === 'GET' && u.pathname === '/api/live') {
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
      res.end(JSON.stringify(liveJSON()));
    } else if (req.method === 'POST' && u.pathname === '/api/sync-prices') {
      const out = execFileSync('bash', [USAGE_SH, 'prices', 'sync'], { encoding: 'utf8', timeout: 90000 });
      frag.html = null;
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ ok: true, message: out.trim().split('\n').pop() }));
    } else {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Not Found');
    }
  } catch (e) {
    if (!res.headersSent) res.writeHead(500, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('错误：' + (e.message || e));
  }
});

server.listen(port, '127.0.0.1', function () {
  const url = 'http://127.0.0.1:' + port;
  console.log('ZCode 用量面板已启动：' + url + '  （Ctrl-C 退出，仅监听本机）');
  if (process.platform === 'darwin') spawn('open', [url], { detached: true, stdio: 'ignore' }).unref();
  else if (process.platform === 'linux') spawn('xdg-open', [url], { detached: true, stdio: 'ignore' }).unref();
});
