#!/usr/bin/env bash
# 查询 ZCode 本地用量明细（只读）。数据源：客户端本地 SQLite 的 model_usage 表。
set -euo pipefail

DB="${ZCODE_USAGE_DB:-$HOME/.zcode/cli/db/db.sqlite}"

if [[ ! -f "$DB" ]]; then
  echo "未找到 ZCode 本地数据库：$DB" >&2
  exit 1
fi

q() { sqlite3 -readonly -header -column "$DB" "$1"; }
# 输出原始单值（供 JSON 组装），不带表格格式化
qr() { sqlite3 -readonly "$DB" "$1"; }

is_num() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# num_arg 默认值 实际参数 —— 校验数字参数，非法则报错退出
num_arg() {
  if [[ -n "${2:-}" ]]; then
    is_num "$2" || { echo "参数应为数字：$2" >&2; exit 1; }
    echo "$2"
  else
    echo "$1"
  fi
}

# 供应商标签：官方账号 / 自定义接入
PV_LABEL="CASE WHEN provider_id LIKE 'account:%' THEN '官方·'||substr(provider_id,9) ELSE '自定义·'||provider_id END"

cmd="${1:-summary}"
case "$cmd" in
  summary)
    q "SELECT count(*) AS 总请求数,
              datetime(min(started_at)/1000,'unixepoch','localtime') AS 首次请求,
              datetime(max(started_at)/1000,'unixepoch','localtime') AS 最近请求,
              sum(input_tokens) AS 输入token,
              sum(output_tokens+reasoning_tokens) AS 生成token,
              sum(cache_read_input_tokens) AS 缓存读token
       FROM model_usage WHERE status='completed';"
    echo
    echo "—— 今日 ——"
    q "SELECT count(*) AS 请求数,
              sum(input_tokens) AS 输入token,
              sum(output_tokens+reasoning_tokens) AS 生成token,
              sum(CASE WHEN status<>'completed' THEN 1 ELSE 0 END) AS 失败数
       FROM model_usage
       WHERE date(started_at/1000,'unixepoch','localtime') = date('now','localtime');"
    ;;
  providers)
    q "SELECT $PV_LABEL AS 来源,
              count(*) AS 请求数,
              sum(input_tokens) AS 输入token,
              sum(output_tokens+reasoning_tokens) AS 生成token,
              sum(cache_read_input_tokens) AS 缓存读token,
              datetime(min(started_at)/1000,'unixepoch','localtime') AS 首次,
              datetime(max(started_at)/1000,'unixepoch','localtime') AS 最近
       FROM model_usage GROUP BY provider_id ORDER BY sum(computed_total_tokens) DESC;"
    ;;
  recent)
    n=$(num_arg 20 "${2:-}")
    q "SELECT datetime(m.started_at/1000,'unixepoch','localtime') AS 时间,
              substr(s.title,1,28) AS 会话,
              m.model_id AS 模型,
              $PV_LABEL AS 来源,
              m.input_tokens AS 输入,
              m.output_tokens+m.reasoning_tokens AS 生成,
              m.cache_read_input_tokens AS 缓存读,
              m.duration_ms AS 耗时ms,
              m.status AS 状态
       FROM model_usage m LEFT JOIN session s ON s.id = m.session_id
       ORDER BY m.started_at DESC LIMIT $n;"
    ;;
  day)
    d="${2:-$(date +%F)}"
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "日期格式应为 YYYY-MM-DD：$d" >&2; exit 1; }
    q "SELECT datetime(m.started_at/1000,'unixepoch','localtime') AS 时间,
              substr(s.title,1,28) AS 会话,
              m.model_id AS 模型,
              $PV_LABEL AS 来源,
              m.input_tokens AS 输入,
              m.output_tokens+m.reasoning_tokens AS 生成,
              m.cache_read_input_tokens AS 缓存读,
              m.duration_ms AS 耗时ms,
              m.status AS 状态
       FROM model_usage m LEFT JOIN session s ON s.id = m.session_id
       WHERE date(m.started_at/1000,'unixepoch','localtime')='$d'
       ORDER BY m.started_at;"
    ;;
  days)
    n=$(num_arg 14 "${2:-}")
    q "SELECT date(started_at/1000,'unixepoch','localtime') AS 日期,
              count(*) AS 请求数,
              sum(input_tokens) AS 输入token,
              sum(output_tokens+reasoning_tokens) AS 生成token,
              sum(cache_read_input_tokens) AS 缓存读token,
              CAST(round(avg(duration_ms)) AS int) AS 平均耗时ms
       FROM model_usage WHERE status='completed'
       GROUP BY 日期 ORDER BY 日期 DESC LIMIT $n;"
    ;;
  sessions)
    n=$(num_arg 15 "${2:-}")
    q "SELECT substr(s.title,1,32) AS 会话,
              count(*) AS 请求数,
              sum(m.input_tokens) AS 输入token,
              sum(m.output_tokens+m.reasoning_tokens) AS 生成token,
              datetime(max(m.started_at)/1000,'unixepoch','localtime') AS 最后活动
       FROM model_usage m JOIN session s ON s.id = m.session_id
       GROUP BY m.session_id
       ORDER BY sum(m.input_tokens+m.output_tokens+m.reasoning_tokens) DESC LIMIT $n;"
    ;;
  models)
    q "SELECT max(model_id) AS 模型,
              count(*) AS 请求数,
              sum(input_tokens) AS 输入token,
              sum(output_tokens+reasoning_tokens) AS 生成token,
              sum(cache_read_input_tokens) AS 缓存读token
       FROM model_usage WHERE status='completed'
       GROUP BY lower(model_id) ORDER BY sum(computed_total_tokens) DESC;"
    ;;
  errors)
    n=$(num_arg 10 "${2:-}")
    q "SELECT datetime(started_at/1000,'unixepoch','localtime') AS 时间,
              model_id AS 模型,
              status AS 状态,
              coalesce(error_code,'-') AS 错误码,
              substr(coalesce(error_message,'-'),1,60) AS 错误信息
       FROM model_usage WHERE status<>'completed'
       ORDER BY started_at DESC LIMIT $n;"
    ;;
  dashboard)
    # 生成交互式用量界面（HTML 片段），输出路径必须由调用方指定。
    # 数据以原始请求行（上限 3000 条）内嵌，筛选/聚合全部在前端完成。
    out="${2:-}"
    [[ -n "$out" ]] || { echo "用法：usage.sh dashboard <输出.html>" >&2; exit 1; }
    META=$(qr "
      WITH P AS (SELECT provider_id AS v, row_number() OVER (ORDER BY provider_id)-1 AS i FROM (SELECT DISTINCT provider_id FROM model_usage)),
           M AS (SELECT model_id AS v, row_number() OVER (ORDER BY model_id)-1 AS i FROM (SELECT DISTINCT model_id FROM model_usage)),
           S AS (SELECT session_id AS v, row_number() OVER (ORDER BY session_id)-1 AS i FROM (SELECT DISTINCT session_id FROM model_usage)),
           R AS (SELECT * FROM model_usage ORDER BY started_at DESC LIMIT 3000)
      SELECT json_object(
        'providers',(SELECT json_group_array(v) FROM (SELECT v,i FROM P ORDER BY i)),
        'models',(SELECT json_group_array(v) FROM (SELECT v,i FROM M ORDER BY i)),
        'sessions',(SELECT json_group_array(coalesce(se.title,'')) FROM (SELECT v,i FROM S ORDER BY i) SI LEFT JOIN session se ON se.id=SI.v),
        'total',(SELECT count(*) FROM model_usage),
        'covered',(SELECT count(*) FROM R),
        'gen',(SELECT datetime('now','localtime')),
        'rows',(SELECT json_group_array(json_array(
                  SI.i, R.started_at, MI.i, PI.i,
                  R.input_tokens, R.output_tokens+R.reasoning_tokens, R.cache_read_input_tokens,
                  R.duration_ms,
                  CASE R.status WHEN 'completed' THEN 0 WHEN 'error' THEN 1 WHEN 'cancelled' THEN 2 ELSE 3 END))
                FROM R
                LEFT JOIN S SI ON SI.v = R.session_id
                LEFT JOIN M MI ON MI.v = R.model_id
                LEFT JOIN P PI ON PI.v = R.provider_id));")
    mkdir -p "$(dirname "$out")"
    {
      cat <<'UD_HEAD'
<div id="usage-dashboard">
<style>
#usage-dashboard .ud-toggle{background:none;border:none;color:var(--muted-foreground);font-size:12px;padding:2px 6px;}
#usage-dashboard .ud-toggle[aria-pressed="true"]{color:var(--foreground);font-weight:500;}
#usage-dashboard .ud-toggle:hover{color:var(--foreground);}
#usage-dashboard .ud-swatch{display:inline-block;width:8px;height:8px;border-radius:2px;margin-right:4px;vertical-align:middle;}
#usage-dashboard .ud-sortable{cursor:pointer;user-select:none;}
#usage-dashboard .ud-sortable:hover{color:var(--foreground);}
#usage-dashboard select.form-select{max-width:220px;}
#usage-dashboard .ud-dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;vertical-align:middle;}
#usage-dashboard .ud-tag{font-size:11px;color:var(--muted-foreground);background:var(--muted);border-radius:4px;padding:1px 5px;margin-left:6px;vertical-align:middle;}
#usage-dashboard .ud-stack{display:flex;height:10px;border-radius:5px;overflow:hidden;background:var(--muted);margin:8px 0 4px;}
#usage-dashboard .ud-stack span{height:100%;}
</style>
<div class="viz-controls" role="group" aria-label="用量筛选">
  <label class="form-label text-small text-muted" for="ud-f-pv">来源</label>
  <select class="form-select" id="ud-f-pv"></select>
  <label class="form-label text-small text-muted" for="ud-f-model">模型</label>
  <select class="form-select" id="ud-f-model"></select>
  <div class="viz-row" role="group" aria-label="时间范围" id="ud-f-range">
    <button type="button" class="ud-toggle" data-r="7" aria-pressed="false">近 7 天</button>
    <button type="button" class="ud-toggle" data-r="30" aria-pressed="false">近 30 天</button>
    <button type="button" class="ud-toggle" data-r="all" aria-pressed="true">全部</button>
  </div>
  <span class="text-small text-muted" id="ud-meta"></span>
</div>
<div class="nav nav-pills" role="tablist" aria-label="用量视图">
  <button class="nav-link active" id="ud-tab-overview" role="tab" aria-controls="ud-overview" aria-selected="true" type="button">总览</button>
  <button class="nav-link" id="ud-tab-trend" role="tab" aria-controls="ud-trend" aria-selected="false" type="button">每日趋势</button>
  <button class="nav-link" id="ud-tab-sessions" role="tab" aria-controls="ud-sessions" aria-selected="false" type="button">会话排行</button>
  <button class="nav-link" id="ud-tab-detail" role="tab" aria-controls="ud-detail" aria-selected="false" type="button">请求明细</button>
  <button class="nav-link" id="ud-tab-errors" role="tab" aria-controls="ud-errors" aria-selected="false" type="button">失败请求</button>
</div>
<div id="ud-overview" role="tabpanel" aria-labelledby="ud-tab-overview">
  <div class="viz-grid">
    <div class="card viz-stat"><div class="text-muted text-small">请求次数</div><div class="viz-stat-value tabular-nums" id="ud-k1">–</div><div class="text-small text-muted" id="ud-k1c"></div></div>
    <div class="card viz-stat"><div class="text-muted text-small">输入 token</div><div class="viz-stat-value tabular-nums" id="ud-k2">–</div><div class="text-small text-muted" id="ud-k2c"></div></div>
    <div class="card viz-stat"><div class="text-muted text-small">生成 token</div><div class="viz-stat-value tabular-nums" id="ud-k3">–</div><div class="text-small text-muted" id="ud-k3c"></div></div>
    <div class="card viz-stat"><div class="text-muted text-small">活跃会话</div><div class="viz-stat-value tabular-nums" id="ud-k4">–</div><div class="text-small text-muted" id="ud-k4c"></div></div>
  </div>
  <h3>来源构成</h3>
  <div id="ud-pv-stack"></div>
  <div id="ud-pv-rows"></div>
  <h3>模型分布</h3>
  <div id="ud-model-bars"></div>
  <h3>最活跃会话（Top 5）</h3>
  <div id="ud-top-sessions"></div>
</div>
<div id="ud-trend" role="tabpanel" aria-labelledby="ud-tab-trend" hidden>
  <div class="viz-row" role="group" aria-label="指标切换" id="ud-series-toggle">
    <button type="button" class="ud-toggle" data-m="req" aria-pressed="true"><span class="ud-swatch" style="background:var(--viz-series-1)"></span>请求数</button>
    <button type="button" class="ud-toggle" data-m="inn" aria-pressed="false"><span class="ud-swatch" style="background:var(--viz-series-1)"></span>输入 token</button>
    <button type="button" class="ud-toggle" data-m="out" aria-pressed="false"><span class="ud-swatch" style="background:var(--viz-series-1)"></span>生成 token</button>
    <button type="button" class="ud-toggle" data-m="ca" aria-pressed="false"><span class="ud-swatch" style="background:var(--viz-series-1)"></span>缓存读 token</button>
    <span class="text-small text-muted" id="ud-trend-readout" aria-live="polite"></span>
  </div>
  <div id="ud-trend-chart"></div>
</div>
<div id="ud-sessions" role="tabpanel" aria-labelledby="ud-tab-sessions" hidden>
  <p class="text-small text-muted">点击表头排序，筛选条件在上方全局生效。</p>
  <div class="table-responsive"><table class="table table-sm">
    <thead id="ud-sessions-head"></thead>
    <tbody id="ud-sessions-body"></tbody>
  </table></div>
</div>
<div id="ud-detail" role="tabpanel" aria-labelledby="ud-tab-detail" hidden>
  <div class="viz-row">
    <label class="form-label text-small text-muted" for="ud-f-stat">状态</label>
    <select class="form-select" id="ud-f-stat">
      <option value="-1">全部状态</option>
      <option value="0">完成</option>
      <option value="1">失败</option>
      <option value="2">已取消</option>
      <option value="3">进行中</option>
    </select>
  </div>
  <div class="table-responsive"><table class="table table-sm">
    <thead id="ud-detail-head"></thead>
    <tbody id="ud-detail-body"></tbody>
  </table></div>
  <button type="button" class="btn" id="ud-more">加载更多</button>
</div>
<div id="ud-errors" role="tabpanel" aria-labelledby="ud-tab-errors" hidden>
  <div class="table-responsive"><table class="table table-sm">
    <thead><tr><th>时间</th><th>会话</th><th>模型</th><th>来源</th><th>状态</th></tr></thead>
    <tbody id="ud-errors-body"></tbody>
  </table></div>
</div>
<script>
const DATA =
UD_HEAD
      printf '%s\n' "$META"
      cat <<'UD_TAIL'
;
(function () {
  var D = DATA || {};
  var PV = D.providers || [], MD = D.models || [], TL = D.sessions || [], R = D.rows || [];
  var $ = function (id) { return document.getElementById(id); };
  var N = function (v) { return v == null ? 0 : v; };
  var esc = function (t) { return String(t == null ? '' : t).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  function fmt(n) { n = N(n); if (n >= 1e8) return (n / 1e8).toFixed(2) + '亿'; if (n >= 1e4) return (n / 1e4).toFixed(1) + '万'; return String(Math.round(n)); }
  function fmtI(n) { return N(n).toLocaleString('zh-CN'); }
  function pad(n) { return n < 10 ? '0' + n : '' + n; }
  function dayKey(ts) { var d = new Date(ts); return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); }
  function fullTs(ts) { var d = new Date(ts); return dayKey(ts) + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()); }

  var STAT = ['完成', '失败', '已取消', '进行中'];
  var SCOLOR = ['var(--green)', 'var(--red)', 'var(--yellow)', 'var(--blue)'];
  function stHtml(s) { return '<span style="white-space:nowrap"><span style="color:' + SCOLOR[s] + '">●</span> ' + STAT[s] + '</span>'; }

  // 供应商：官方账号(account:*) / 自定义接入，按总 token 降序分配固定系列色
  var pvTot = PV.map(function (p, i) { var t = 0; R.forEach(function (r) { if (r[3] === i) t += N(r[4]) + N(r[5]); }); return { i: i, t: t }; })
    .sort(function (a, b) { return b.t - a.t; });
  var pvOrder = pvTot.map(function (x) { return x.i; });
  function pvColor(p) { var k = pvOrder.indexOf(p); return 'var(--viz-series-' + ((k % 6) + 1) + ')'; }
  function pvLabel(p) { return esc(String(PV[p] || '?').replace(/^account:/, '')); }
  function pvTag(p) { return /^account:/.test(String(PV[p] || '')) ? '官方账号' : '自定义接入'; }

  var maxTs = 0;
  R.forEach(function (r) { if (r[1] > maxTs) maxTs = r[1]; });

  var st = { p: -1, m: -1, rng: 'all' };
  var sortS = { k: 4, d: -1 }, sortD = { k: 0, d: -1 };
  var shown = 50, detailStat = -1, curMetric = 'req';

  function cutOf() { if (st.rng === 'all') return 0; return maxTs - (st.rng === '7' ? 7 : 30) * 864e5; }
  function frows(ignorePv) {
    var cut = cutOf();
    return R.filter(function (r) {
      if (!ignorePv && st.p >= 0 && r[3] !== st.p) return false;
      if (st.m >= 0 && r[2] !== st.m) return false;
      if (cut && r[1] < cut) return false;
      return true;
    });
  }
  function agg(rows) {
    var a = { req: rows.length, inn: 0, out: 0, ca: 0, sids: {} };
    rows.forEach(function (r) { a.inn += N(r[4]); a.out += N(r[5]); a.ca += N(r[6]); a.sids[r[0]] = 1; });
    a.sess = 0; for (var k in a.sids) a.sess++;
    a.tok = a.inn + a.out;
    return a;
  }
  function daySpan(rows) {
    var keys = {};
    rows.forEach(function (r) { keys[dayKey(r[1])] = 1; });
    return Object.keys(keys).sort();
  }

  function renderKpis(rows) {
    var a = agg(rows);
    var dcount = daySpan(rows).length || 1;
    $('ud-k1').textContent = fmtI(a.req);
    $('ud-k1c').textContent = '日均 ' + fmt(a.req / dcount) + ' · 覆盖 ' + dcount + ' 天';
    $('ud-k2').textContent = fmt(a.inn);
    $('ud-k2c').textContent = '其中缓存读 ' + fmt(a.ca);
    $('ud-k3').textContent = fmt(a.out);
    $('ud-k3c').textContent = '输出 + 思考 token';
    $('ud-k4').textContent = fmtI(a.sess);
    $('ud-k4c').textContent = '合计 ' + fmt(a.tok) + ' token';
    $('ud-meta').textContent = '数据截至 ' + (D.gen || '') + ' · 已加载最近 ' + fmtI(D.covered) + ' / ' + fmtI(D.total) + ' 条 · 仅统计本机';
  }

  function renderProviders(rows) {
    var per = PV.map(function (p, i) { return { i: i, req: 0, tok: 0 }; });
    rows.forEach(function (r) { var o = per[r[3]]; o.req++; o.tok += N(r[4]) + N(r[5]); });
    var tot = per.reduce(function (a, x) { return a + x.tok; }, 0);
    var act = per.filter(function (x) { return x.req > 0; }).sort(function (a, b) { return b.tok - a.tok; });
    if (!act.length) { $('ud-pv-stack').innerHTML = '<p class="text-muted">当前筛选下暂无数据</p>'; $('ud-pv-rows').innerHTML = ''; return; }
    $('ud-pv-stack').innerHTML = '<div class="ud-stack" role="img" aria-label="来源构成">' + act.map(function (x) {
      return '<span style="width:' + (tot ? (x.tok / tot * 100).toFixed(2) : 0) + '%;background:' + pvColor(x.i) + '"></span>';
    }).join('') + '</div>';
    $('ud-pv-rows').innerHTML = act.map(function (x) {
      return '<div class="text-small" style="display:flex;justify-content:space-between;gap:8px;padding:3px 0">' +
        '<span><span class="ud-dot" style="background:' + pvColor(x.i) + '"></span>' + pvLabel(x.i) + '<span class="ud-tag">' + pvTag(x.i) + '</span></span>' +
        '<span class="tabular-nums text-muted">' + fmtI(x.req) + ' 次 · ' + fmt(x.tok) + ' token · ' + (tot ? (x.tok / tot * 100).toFixed(1) : 0) + '%</span></div>';
    }).join('');
  }

  function renderModels(rows) {
    var per = {};
    rows.forEach(function (r) {
      var o = per[r[2]] || (per[r[2]] = { req: 0, tok: 0 });
      o.req++; o.tok += N(r[4]) + N(r[5]);
    });
    var list = Object.keys(per).map(function (m) { return { m: m, req: per[m].req, tok: per[m].tok }; })
      .sort(function (a, b) { return b.tok - a.tok; }).slice(0, 8);
    var tot = list.reduce(function (a, x) { return a + x.tok; }, 0);
    $('ud-model-bars').innerHTML = list.length ? list.map(function (x) {
      var p = tot ? Math.round(x.tok / tot * 100) : 0;
      return '<div style="margin:8px 0"><div class="text-small" style="display:flex;justify-content:space-between;gap:8px"><span>' + esc(MD[x.m]) + '</span><span class="tabular-nums text-muted">' + fmtI(x.req) + ' 次 · ' + fmt(x.tok) + ' token · ' + p + '%</span></div><div class="progress" role="progressbar" aria-label="' + esc(MD[x.m]) + ' 占比" aria-valuenow="' + p + '" aria-valuemin="0" aria-valuemax="100"><div class="progress-bar" style="width:' + p + '%"></div></div></div>';
    }).join('') : '<p class="text-muted">当前筛选下暂无数据</p>';
  }

  function sessAgg(rows) {
    var per = {};
    rows.forEach(function (r) {
      var o = per[r[0]] || (per[r[0]] = { tl: TL[r[0]] || '', req: 0, inn: 0, out: 0, last: 0 });
      o.req++; o.inn += N(r[4]); o.out += N(r[5]); if (r[1] > o.last) o.last = r[1];
    });
    return Object.keys(per).map(function (g) {
      var o = per[g]; o.g = g; o.tot = o.inn + o.out;
      return o;
    });
  }
  function sessTitle(o) { return o.tl ? esc(o.tl) : '<span class="text-muted">（无标题）</span>'; }

  function renderTopSessions(rows) {
    var list = sessAgg(rows).sort(function (a, b) { return b.tot - a.tot; }).slice(0, 5);
    $('ud-top-sessions').innerHTML = list.length ? '<table class="table table-sm"><thead><tr><th>会话</th><th class="text-end">请求数</th><th class="text-end">token 合计</th><th class="text-end">最后活动</th></tr></thead><tbody>' +
      list.map(function (o) {
        return '<tr><td>' + sessTitle(o) + '</td><td class="text-end tabular-nums">' + fmtI(o.req) + '</td><td class="text-end tabular-nums">' + fmt(o.tot) + '</td><td class="text-end text-nowrap">' + fullTs(o.last) + '</td></tr>';
      }).join('') + '</tbody></table>' : '<p class="text-muted">当前筛选下暂无数据</p>';
  }

  function renderSessions(rows) {
    var keys = { 1: 'req', 2: 'inn', 3: 'out', 4: 'tot', 5: 'last' };
    var list = sessAgg(rows).sort(function (a, b) { return (a[keys[sortS.k]] - b[keys[sortS.k]]) * sortS.d; });
    var cols = [
      { h: '会话', k: null }, { h: '请求数', k: 1, end: 1 }, { h: '输入 token', k: 2, end: 1 },
      { h: '生成 token', k: 3, end: 1 }, { h: 'token 合计', k: 4, end: 1 }, { h: '最后活动', k: 5, end: 1 }
    ];
    $('ud-sessions-head').innerHTML = '<tr>' + cols.map(function (c) {
      var arrow = sortS.k === c.k ? (sortS.d < 0 ? ' ↓' : ' ↑') : '';
      return c.k == null ? '<th>' + c.h + '</th>' : '<th class="ud-sortable' + (c.end ? ' text-end' : '') + '" data-k="' + c.k + '"' + (sortS.k === c.k ? ' aria-sort="' + (sortS.d < 0 ? 'descending' : 'ascending') + '"' : '') + '>' + c.h + arrow + '</th>';
    }).join('') + '</tr>';
    $('ud-sessions-body').innerHTML = list.length ? list.slice(0, 30).map(function (o) {
      return '<tr><td>' + sessTitle(o) + '</td><td class="text-end tabular-nums">' + fmtI(o.req) + '</td><td class="text-end tabular-nums">' + fmtI(o.inn) + '</td><td class="text-end tabular-nums">' + fmtI(o.out) + '</td><td class="text-end tabular-nums">' + fmtI(o.tot) + '</td><td class="text-end text-nowrap">' + fullTs(o.last) + '</td></tr>';
    }).join('') : '<tr><td colspan="6" class="text-muted">当前筛选下暂无数据</td></tr>';
    Array.prototype.forEach.call($('ud-sessions-head').querySelectorAll('.ud-sortable'), function (th) {
      th.addEventListener('click', function () {
        var k = +th.getAttribute('data-k');
        if (sortS.k === k) sortS.d = -sortS.d; else { sortS.k = k; sortS.d = -1; }
        renderSessions(frows(false));
      });
    });
  }

  function renderDetail(rows) {
    var keys = { 0: 1, 4: 4, 5: 5, 6: 6, 7: 7 };
    var list = rows.filter(function (r) { return detailStat < 0 || r[8] === detailStat; }).sort(function (a, b) { return (a[keys[sortD.k]] - b[keys[sortD.k]]) * sortD.d; });
    var cols = [
      { h: '时间', k: 0 }, { h: '会话', k: null }, { h: '模型', k: null }, { h: '来源', k: null },
      { h: '输入', k: 4, end: 1 }, { h: '生成', k: 5, end: 1 }, { h: '缓存读', k: 6, end: 1 }, { h: '耗时 ms', k: 7, end: 1 }, { h: '状态', k: null }
    ];
    $('ud-detail-head').innerHTML = '<tr>' + cols.map(function (c) {
      var arrow = sortD.k === c.k ? (sortD.d < 0 ? ' ↓' : ' ↑') : '';
      return c.k == null ? '<th>' + c.h + '</th>' : '<th class="ud-sortable' + (c.end ? ' text-end' : '') + '" data-k="' + c.k + '">' + c.h + arrow + '</th>';
    }).join('') + '</tr>';
    var view = list.slice(0, shown);
    $('ud-detail-body').innerHTML = view.length ? view.map(function (r) {
      return '<tr><td class="text-nowrap">' + fullTs(r[1]) + '</td><td>' + (TL[r[0]] ? esc(TL[r[0]]) : '<span class="text-muted">（无标题）</span>') + '</td><td>' + esc(MD[r[2]]) + '</td><td>' + pvLabel(r[3]) + '</td><td class="text-end tabular-nums">' + fmtI(r[4]) + '</td><td class="text-end tabular-nums">' + fmtI(r[5]) + '</td><td class="text-end tabular-nums">' + fmtI(r[6]) + '</td><td class="text-end tabular-nums">' + fmtI(r[7]) + '</td><td>' + stHtml(r[8]) + '</td></tr>';
    }).join('') : '<tr><td colspan="9" class="text-muted">当前筛选下暂无数据</td></tr>';
    var more = $('ud-more');
    if (shown >= list.length) { more.hidden = true; }
    else { more.hidden = false; more.textContent = '加载更多（已显示 ' + shown + ' / ' + list.length + '）'; }
    Array.prototype.forEach.call($('ud-detail-head').querySelectorAll('.ud-sortable'), function (th) {
      th.addEventListener('click', function () {
        var k = +th.getAttribute('data-k');
        if (sortD.k === k) sortD.d = -sortD.d; else { sortD.k = k; sortD.d = -1; }
        renderDetail(frows(false));
      });
    });
  }

  function renderErrors(rows) {
    var list = rows.filter(function (r) { return r[8] !== 0; }).sort(function (a, b) { return b[1] - a[1]; }).slice(0, 30);
    $('ud-errors-body').innerHTML = list.length ? list.map(function (r) {
      return '<tr><td class="text-nowrap">' + fullTs(r[1]) + '</td><td>' + (TL[r[0]] ? esc(TL[r[0]]) : '<span class="text-muted">（无标题）</span>') + '</td><td>' + esc(MD[r[2]]) + '</td><td>' + pvLabel(r[3]) + '</td><td>' + stHtml(r[8]) + '</td></tr>';
    }).join('') : '<tr><td colspan="5" class="text-muted">当前筛选下没有失败或取消的请求</td></tr>';
  }

  function drawTrend() {
    var host = $('ud-trend-chart');
    if (!host) return;
    var w = host.clientWidth;
    if (!w) return;
    var rows = frows(false);
    if (!rows.length) { host.innerHTML = '<p class="text-muted">当前筛选下暂无数据</p>'; return; }
    var days = daySpan(rows);
    var perDay = {};
    rows.forEach(function (r) {
      var k = dayKey(r[1]);
      var o = perDay[k] || (perDay[k] = {});
      var m = o[r[3]] || (o[r[3]] = { req: 0, inn: 0, out: 0, ca: 0 });
      m.req++; m.inn += N(r[4]); m.out += N(r[5]); m.ca += N(r[6]);
    });
    var active = {};
    rows.forEach(function (r) { active[r[3]] = 1; });
    var pvs = pvOrder.filter(function (p) { return active[p]; });
    var H = 240, P = { t: 12, r: 12, b: 28, l: 64 };
    var iw = w - P.l - P.r, ih = H - P.t - P.b;
    var slot = iw / days.length, bw = Math.max(2, Math.min(slot - 2, 40));
    var ymax = 1;
    days.forEach(function (k) {
      var o = perDay[k] || {};
      var t = 0;
      pvs.forEach(function (p) { t += N((o[p] || {})[curMetric]); });
      if (t > ymax) ymax = t;
    });
    var out = '';
    for (var i = 0; i <= 4; i++) {
      var v = ymax * i / 4, y = P.t + ih - ih * i / 4;
      out += '<line x1="' + P.l + '" y1="' + y + '" x2="' + (w - P.r) + '" y2="' + y + '" stroke="var(--border)" stroke-width="1"/>';
      out += '<text x="' + (P.l - 6) + '" y="' + (y + 4) + '" text-anchor="end" font-size="11" fill="var(--muted-foreground)">' + fmt(v) + '</text>';
    }
    var kStep = Math.ceil(days.length / 8);
    days.forEach(function (k, di) {
      if (di % kStep === 0) {
        out += '<text x="' + (P.l + di * slot + slot / 2) + '" y="' + (H - 8) + '" text-anchor="middle" font-size="11" fill="var(--muted-foreground)">' + esc(k.slice(5)) + '</text>';
      }
      var o = perDay[k] || {}, yBase = P.t + ih;
      pvs.forEach(function (p) {
        var v = N((o[p] || {})[curMetric]);
        if (!v) return;
        var bh = Math.round(ih * v / ymax);
        var tip = k + '\n' + pvLabel(p) + '\n请求 ' + fmtI((o[p] || {}).req || 0) + ' · 输入 ' + fmt((o[p] || {}).inn) + '\n生成 ' + fmt((o[p] || {}).out) + ' · 缓存读 ' + fmt((o[p] || {}).ca);
        out += '<rect x="' + (P.l + di * slot + (slot - bw) / 2) + '" y="' + (yBase - bh) + '" width="' + bw + '" height="' + Math.max(bh, 1) + '" fill="' + pvColor(p) + '" rx="2"><title>' + esc(tip) + '</title></rect>';
        yBase -= bh;
      });
    });
    host.innerHTML = '<svg width="' + w + '" height="' + H + '" role="img" aria-label="每日用量堆叠柱状图（按来源）"><desc>按天按来源堆叠展示 ' + days.length + ' 天数据</desc>' + out + '</svg>';
    var total = agg(rows);
    $('ud-trend-readout').textContent = '当前指标合计：请求数 ' + fmtI(total.req) + ' · 输入 ' + fmt(total.inn) + ' · 生成 ' + fmt(total.out) + ' · 缓存读 ' + fmt(total.ca);
  }

  function fillSelect(el, allLabel, items) {
    el.innerHTML = '<option value="-1">' + allLabel + '</option>' + items.map(function (it) {
      return '<option value="' + it.v + '">' + esc(it.label) + '</option>';
    }).join('');
  }

  function apply() {
    var rows = frows(false);
    renderKpis(rows);
    renderProviders(frows(true));
    renderModels(rows);
    renderTopSessions(rows);
    renderSessions(rows);
    renderDetail(rows);
    renderErrors(rows);
    drawTrend();
  }

  // 筛选控件
  fillSelect($('ud-f-pv'), '全部来源', PV.map(function (p, i) { return { v: i, label: pvLabel(i) + '（' + pvTag(i) + '）' }; }));
  fillSelect($('ud-f-model'), '全部模型', MD.map(function (m, i) { return { v: i, label: String(m) }; }));
  $('ud-f-pv').addEventListener('change', function () { st.p = +this.value; shown = 50; apply(); });
  $('ud-f-model').addEventListener('change', function () { st.m = +this.value; shown = 50; apply(); });
  $('ud-f-stat').addEventListener('change', function () { detailStat = +this.value; shown = 50; renderDetail(frows(false)); });
  Array.prototype.forEach.call(document.querySelectorAll('#ud-f-range .ud-toggle'), function (b) {
    b.addEventListener('click', function () {
      st.rng = b.getAttribute('data-r');
      Array.prototype.forEach.call(document.querySelectorAll('#ud-f-range .ud-toggle'), function (x) {
        x.setAttribute('aria-pressed', String(x === b));
      });
      shown = 50; apply();
    });
  });
  Array.prototype.forEach.call(document.querySelectorAll('#ud-series-toggle .ud-toggle'), function (b) {
    b.addEventListener('click', function () {
      curMetric = b.getAttribute('data-m');
      Array.prototype.forEach.call(document.querySelectorAll('#ud-series-toggle .ud-toggle'), function (x) {
        x.setAttribute('aria-pressed', String(x === b));
      });
      drawTrend();
    });
  });
  $('ud-more').addEventListener('click', function () { shown += 50; renderDetail(frows(false)); });
  $('ud-tab-trend').addEventListener('click', function () { requestAnimationFrame(drawTrend); });
  if (typeof ResizeObserver === 'function') { new ResizeObserver(function () { drawTrend(); }).observe($('ud-trend-chart')); }

  apply();
})();
</script>
</div>
UD_TAIL
    } > "$out"
    echo "已生成用量界面：$out"
    ;;
  help|*)
    cat <<'EOF'
用法：usage.sh [子命令] [参数]
  summary                  总览：累计 + 今日（默认）
  providers                按来源（官方套餐 / 自定义接入）汇总
  recent [N]               最近 N 条逐条请求明细（默认 20）
  day [YYYY-MM-DD]         某天逐条明细（缺省今天）
  days [N]                 最近 N 天按天汇总（默认 14）
  sessions [N]             按会话用量 Top N（默认 15）
  models                   按模型汇总
  errors [N]               最近 N 条失败请求（默认 10）
  dashboard <输出.html>    生成交互式用量界面（HTML 片段，供 ZCode 内嵌渲染）
环境变量 ZCODE_USAGE_DB 可覆盖数据库路径。
EOF
    ;;
esac
