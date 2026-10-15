#!/usr/bin/env bash
# 查询 ZCode 本地用量明细（只读）。数据源：客户端本地 SQLite 的 model_usage / tool_usage 表。
# 设计参考：ccusage（5小时窗口/成本）、DeepSeek Harness 社区用量插件（热力图/洞察/导出）。
set -euo pipefail

DB="${ZCODE_USAGE_DB:-$HOME/.zcode/cli/db/db.sqlite}"
PRICE_FILE="${ZCODE_USAGE_PRICES:-$HOME/.zcode/usage-prices.json}"

# 价格表解析顺序：ZCODE_USAGE_PRICES → 用户文件 ~/.zcode/usage-prices.json → 插件内置官方价（models.dev）
price_file() {
  if [[ -n "${ZCODE_USAGE_PRICES:-}" && -f "$ZCODE_USAGE_PRICES" ]]; then
    echo "$ZCODE_USAGE_PRICES"; return
  fi
  if [[ -f "$HOME/.zcode/usage-prices.json" ]]; then
    echo "$HOME/.zcode/usage-prices.json"; return
  fi
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/default-prices.json"
  if [[ -f "$d" ]]; then echo "$d"; fi
}

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
              round(sum(cache_read_input_tokens)*100.0/max(sum(input_tokens),1),1) AS 缓存率,
              datetime(min(started_at)/1000,'unixepoch','localtime') AS 首次,
              datetime(max(started_at)/1000,'unixepoch','localtime') AS 最近
       FROM model_usage GROUP BY provider_id ORDER BY sum(computed_total_tokens) DESC;"
    ;;
  blocks)
    # 5 小时窗口：相邻请求间隔 >= 5h 即开启新窗口（与 ccusage 口径一致）。末尾窗口若仍在 5h 内即为进行中。
    q "WITH s AS (SELECT started_at, input_tokens, output_tokens+reasoning_tokens AS gen,
                         LAG(started_at) OVER (ORDER BY started_at) AS prev FROM model_usage),
            b AS (SELECT started_at, input_tokens, gen,
                         SUM(CASE WHEN prev IS NULL OR started_at-prev>=18000000 THEN 1 ELSE 0 END) OVER (ORDER BY started_at) AS blk FROM s)
       SELECT blk AS 窗口,
              datetime(min(started_at)/1000,'unixepoch','localtime') AS 开始,
              datetime(max(started_at)/1000,'unixepoch','localtime') AS 最近活动,
              count(*) AS 请求数,
              sum(input_tokens) AS 输入token,
              sum(gen) AS 生成token,
              CASE WHEN unixepoch()*1000 - max(started_at) < 18000000 THEN '进行中' ELSE '已结束' END AS 状态
       FROM b GROUP BY blk ORDER BY min(started_at) DESC LIMIT 15;"
    ;;
  months)
    q "SELECT strftime('%Y-%m', started_at/1000,'unixepoch','localtime') AS 月份,
              count(*) AS 请求数,
              sum(input_tokens) AS 输入token,
              sum(output_tokens+reasoning_tokens) AS 生成token,
              sum(cache_read_input_tokens) AS 缓存读token,
              count(DISTINCT date(started_at/1000,'unixepoch','localtime')) AS 活跃天
       FROM model_usage GROUP BY 月份 ORDER BY 月份 DESC;"
    ;;
  projects)
    n=$(num_arg 15 "${2:-}")
    q "SELECT s.directory AS 项目目录,
              count(*) AS 请求数,
              sum(m.input_tokens) AS 输入token,
              sum(m.output_tokens+m.reasoning_tokens) AS 生成token,
              datetime(max(m.started_at)/1000,'unixepoch','localtime') AS 最后活动
       FROM model_usage m JOIN session s ON s.id = m.session_id
       GROUP BY s.directory ORDER BY sum(m.input_tokens+m.output_tokens+m.reasoning_tokens) DESC LIMIT $n;"
    ;;
  tools)
    n=$(num_arg 15 "${2:-}")
    q "SELECT tool_name AS 工具,
              count(*) AS 调用,
              sum(status<>'completed') AS 失败,
              CAST(round(avg(duration_ms)) AS int) AS 平均耗时ms,
              datetime(max(started_at)/1000,'unixepoch','localtime') AS 最近调用
       FROM tool_usage GROUP BY tool_name ORDER BY 调用 DESC LIMIT $n;"
    ;;
  cost)
    # 成本估算：默认用插件内置官方价（models.dev），用户文件 ~/.zcode/usage-prices.json 可覆盖/扩展
    pf=$(price_file)
    if [[ -z "$pf" ]]; then
      echo "未找到价格表（应随插件内置 scripts/default-prices.json）" >&2
      exit 1
    fi
    q "WITH src AS (SELECT CAST(readfile('$pf') AS text) AS j),
            n AS (SELECT CASE WHEN json_type(j,'\$.models')='object' THEN j ELSE json_object('models',json(j)) END AS j2,
                         COALESCE(json_extract(j,'\$.currency'),'USD') AS cur FROM src),
            p AS (SELECT je.key AS model,
                         CAST(json_extract(je.value,'\$.in') AS real) AS pin,
                         CAST(json_extract(je.value,'\$.out') AS real) AS pout,
                         CAST(json_extract(je.value,'\$.cache') AS real) AS pcache
                  FROM n, json_each(n.j2,'\$.models') je)
       SELECT m.model_id AS 模型,
              count(*) AS 请求数,
              round(sum(m.input_tokens)/1000000.0*p.pin, 2) AS 输入成本,
              round(sum(m.output_tokens+m.reasoning_tokens)/1000000.0*p.pout, 2) AS 生成成本,
              round(sum(m.cache_read_input_tokens)/1000000.0*p.pcache, 2) AS 缓存读成本,
              round(sum(m.input_tokens)/1000000.0*p.pin
                  + sum(m.output_tokens+m.reasoning_tokens)/1000000.0*p.pout
                  + sum(m.cache_read_input_tokens)/1000000.0*p.pcache, 2) AS 合计,
              (SELECT cur FROM n) AS 币种
       FROM model_usage m JOIN p ON lower(p.model) = lower(m.model_id)
       GROUP BY m.model_id ORDER BY 合计 DESC;"
    echo
    echo "（估算口径：官方牌价 × 本地记录 token；含分时费率的模型按标准价估算，精确分时请在面板查看；订阅套餐内请求实际不按 token 计费）"
    ;;
  prices)
    # 官方价格表：show 查看 / sync 从 models.dev 同步（保留自定义条目）
    sub="${2:-show}"
    case "$sub" in
      show)
        pf=$(price_file)
        [[ -n "$pf" ]] || { echo "未找到价格表" >&2; exit 1; }
        echo "生效价格表：$pf"
        echo
        q "WITH src AS (SELECT CAST(readfile('$pf') AS text) AS j),
                n AS (SELECT CASE WHEN json_type(j,'\$.models')='object' THEN j ELSE json_object('models',json(j)) END AS j2 FROM src)
           SELECT je.key AS 模型,
                  json_extract(je.value,'\$.in') AS 输入,
                  json_extract(je.value,'\$.out') AS 生成,
                  json_extract(je.value,'\$.cache') AS 缓存读,
                  COALESCE(json_extract(j2.j2,'\$.currency'),'USD') AS 币种
           FROM n j2, json_each(j2.j2,'\$.models') je
           ORDER BY 模型;"
        echo
        echo "（单位：每百万 token）自定义请编辑 ~/.zcode/usage-prices.json；同步官方价：usage.sh prices sync"
        ;;
      sync)
        command -v node >/dev/null 2>&1 || { echo "prices sync 需要 node（同步仅是可选操作，内置价格表已可用）" >&2; exit 1; }
        tmp=$(mktemp)
        curl -fsSL --max-time 30 https://models.dev/api.json -o "$tmp" || { echo "下载 models.dev 失败" >&2; rm -f "$tmp"; exit 1; }
        node - "$tmp" "${ZCODE_USAGE_PRICES:-$HOME/.zcode/usage-prices.json}" <<'NODE'
const fs = require('fs');
const md = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const user = process.argv[3];
let out = { currency: 'USD', models: {} };
try {
  const old = JSON.parse(fs.readFileSync(user, 'utf8'));
  if (old && typeof old.models === 'object') out = old;
  else if (old && typeof old === 'object') out.models = old;
} catch (e) {}
out.currency = out.currency || 'USD';
// BYOK：全量同步所有供应商的所有带价模型；同名模型先到先得，自定义条目不会被覆盖
let n = 0;
for (const prov of Object.keys(md)) {
  for (const [m, v] of Object.entries((md[prov] || {}).models || {})) {
    const p = v.price || v.cost;
    if (!p || (!p.input && !p.output)) continue; // 跳过订阅占位（全 0 价）
    if (out.models[m]) continue;
    out.models[m] = { in: p.input || 0, out: p.output || 0, cache: p.cache_read || 0 };
    n++;
  }
}
out.source = 'models.dev';
out.updated = new Date().toISOString().slice(0, 10);
fs.mkdirSync(require('path').dirname(user), { recursive: true });
fs.writeFileSync(user, JSON.stringify(out, null, 2) + '\n');
console.log('已同步 ' + n + ' 个官方模型价（全部供应商）到 ' + user + '（自定义条目保留）');
NODE
        rm -f "$tmp"
        ;;
      *)
        echo "用法：usage.sh prices [show|sync]" >&2
        exit 1
        ;;
    esac
    ;;
  live)
    # 实时燃烧率监控（终端）：每 N 秒刷新（默认 3），Ctrl-C 退出。
    # 只查询最近 5h 与近 48h 数据，走 started_at 索引，开销极低。
    interval=$(num_arg 3 "${2:-}")
    while true; do
      printf '\033[H\033[2J'
      echo "── ZCode 用量实时监控 · 每 ${interval}s 刷新 · Ctrl-C 退出 · $(date '+%H:%M:%S') ──"
      echo
      q "WITH cur AS (SELECT count(*) AS req,
                            COALESCE(sum(input_tokens),0) AS inn,
                            COALESCE(sum(output_tokens+reasoning_tokens),0) AS gen,
                            min(started_at) AS st
                     FROM model_usage WHERE started_at > (unixepoch()*1000 - 18000000)),
            s AS (SELECT started_at, input_tokens, output_tokens+reasoning_tokens AS gen,
                         LAG(started_at) OVER (ORDER BY started_at) AS prev
                  FROM model_usage WHERE started_at > (unixepoch()*1000 - 172800000)),
            b AS (SELECT started_at, input_tokens, gen,
                         SUM(CASE WHEN prev IS NULL OR started_at-prev>=18000000 THEN 1 ELSE 0 END) OVER (ORDER BY started_at) AS blk
                  FROM s),
            hist AS (SELECT blk, sum(input_tokens)+sum(gen) AS tok
                     FROM b GROUP BY blk
                     HAVING min(started_at) <= (unixepoch()*1000 - 18000000)
                     ORDER BY min(started_at) DESC LIMIT 3)
       SELECT c.req AS 本窗请求,
              c.inn+c.gen AS 本窗token,
              CAST(round((c.inn+c.gen) / max(0.1,(unixepoch()*1000 - COALESCE(c.st, unixepoch()*1000))/3600000.0)) AS int) AS 燃烧率token每小时,
              (SELECT CAST(round(avg(tok)) AS int) FROM hist) AS 近3窗口均值token,
              (SELECT count(*) FROM hist) AS 均值样本数
       FROM cur c;"
      echo
      q "SELECT $PV_LABEL AS 来源, count(*) AS 近24h请求, sum(input_tokens+output_tokens+reasoning_tokens) AS token
         FROM model_usage WHERE started_at > (unixepoch()*1000 - 86400000)
         GROUP BY provider_id ORDER BY 近24h请求 DESC;"
      sleep "$interval"
    done
    ;;
  export)
    kind="${2:-csv}"
    out="${3:-}"
    case "$kind" in
      csv)
        out="${out:-zcode-usage-export.csv}"
        sqlite3 -readonly -csv "$DB" "
          SELECT datetime(m.started_at/1000,'unixepoch','localtime') AS time,
                 substr(coalesce(s.title,''),1,80) AS session,
                 s.directory AS project,
                 m.model_id AS model, m.provider_id AS provider,
                 m.input_tokens AS input_tokens,
                 m.output_tokens+m.reasoning_tokens AS output_tokens,
                 m.cache_read_input_tokens AS cache_read_tokens,
                 m.duration_ms AS duration_ms, m.status AS status
          FROM model_usage m LEFT JOIN session s ON s.id = m.session_id
          ORDER BY m.started_at;" > "$out"
        echo "已导出 CSV：$out"
        ;;
      json)
        out="${out:-zcode-usage-export.json}"
        qr "
          WITH P AS (SELECT provider_id AS v, row_number() OVER (ORDER BY provider_id)-1 AS i FROM (SELECT DISTINCT provider_id FROM model_usage)),
               M AS (SELECT model_id AS v, row_number() OVER (ORDER BY model_id)-1 AS i FROM (SELECT DISTINCT model_id FROM model_usage)),
               S AS (SELECT session_id AS v, row_number() OVER (ORDER BY session_id)-1 AS i FROM (SELECT DISTINCT session_id FROM model_usage)),
               R AS (SELECT * FROM model_usage ORDER BY started_at DESC LIMIT 20000)
          SELECT json_object(
            'providers',(SELECT json_group_array(v) FROM (SELECT v,i FROM P ORDER BY i)),
            'models',(SELECT json_group_array(v) FROM (SELECT v,i FROM M ORDER BY i)),
            'sessions',(SELECT json_group_array(coalesce(se.title,'')) FROM (SELECT v,i FROM S ORDER BY i) SI LEFT JOIN session se ON se.id=SI.v),
        'sessionDirs',(SELECT json_group_array(COALESCE(se.directory,'')) FROM (SELECT v,i FROM S ORDER BY i) SI LEFT JOIN session se ON se.id=SI.v),
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
                    LEFT JOIN P PI ON PI.v = R.provider_id));" > "$out"
        echo "已导出 JSON：$out"
        ;;
      *)
        echo "用法：usage.sh export <csv|json> [输出路径]" >&2
        exit 1
        ;;
    esac
    ;;
  recent)
    n=$(num_arg 20 "${2:-}")
    q "SELECT datetime(m.started_at/1000,'unixepoch','localtime') AS 时间,
              substr(s.title,1,28) AS 会话,
              m.model_id AS 模型,
              $PV_LABEL AS 来源,
              CASE m.query_source WHEN 'subagent' THEN '子代理' WHEN 'main_turn' THEN '主会话' ELSE '系统' END AS 类型,
              m.input_tokens AS 输入,
              m.output_tokens+m.reasoning_tokens AS 生成,
              m.cache_read_input_tokens AS 缓存读,
              m.cache_creation_input_tokens AS 缓存写,
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
              CASE m.query_source WHEN 'subagent' THEN '子代理' WHEN 'main_turn' THEN '主会话' ELSE '系统' END AS 类型,
              m.input_tokens AS 输入,
              m.output_tokens+m.reasoning_tokens AS 生成,
              m.cache_read_input_tokens AS 缓存读,
              m.cache_creation_input_tokens AS 缓存写,
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
              sum(CASE WHEN m.query_source='subagent' THEN 1 ELSE 0 END) AS 子代理请求,
              round(sum(m.cache_read_input_tokens)*100.0/max(sum(m.input_tokens),1),1) AS 缓存率,
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
              sum(cache_read_input_tokens) AS 缓存读token,
              round(sum(cache_read_input_tokens)*100.0/max(sum(input_tokens),1),1) AS 缓存率
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
    # 数据以原始请求行内嵌（默认最近 3000 条，可用第三参数或 ZCODE_USAGE_LIMIT 调整），筛选/聚合全部在前端完成。
    out="${2:-}"
    [[ -n "$out" ]] || { echo "用法：usage.sh dashboard <输出.html> [条数]" >&2; exit 1; }
    limit=$(num_arg "${ZCODE_USAGE_LIMIT:-3000}" "${3:-}")
    [[ "$limit" -ge 1 && "$limit" -le 20000 ]] || { echo "条数应在 1-20000 之间：$limit（过大可能超出会话内嵌渲染的体积限制，更多历史请用 export json）" >&2; exit 1; }
    # 价格表每日自动同步一次（需要 node + curl；ZCODE_USAGE_NO_AUTOSYNC=1 关闭）
    if [[ -z "${ZCODE_USAGE_NO_AUTOSYNC:-}" ]] && command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
      upf="${ZCODE_USAGE_PRICES:-$HOME/.zcode/usage-prices.json}"
      upf_mtime=0
      if [[ -f "$upf" ]]; then
        upf_mtime=$(stat -f %m "$upf" 2>/dev/null || stat -c %Y "$upf" 2>/dev/null || echo 0)
      fi
      if [[ $(( $(date +%s) - upf_mtime )) -ge 86400 ]]; then
        bash "${BASH_SOURCE[0]}" prices sync >/dev/null 2>&1 || true
      fi
    fi
    pf=$(price_file)
    if [[ -n "$pf" ]]; then
      PJ_SQL="(SELECT CAST(readfile('$pf') AS text) AS pj)"
    else
      PJ_SQL="(SELECT NULL AS pj)"
    fi
    logs_mb=$(du -sm "$HOME/.zcode/v2/logs" 2>/dev/null | cut -f1); logs_mb=${logs_mb:-0}
    rollout_mb=$(du -sm "$HOME/.zcode/cli/rollout" 2>/dev/null | cut -f1); rollout_mb=${rollout_mb:-0}
    artifacts_mb=$(du -sm "$HOME/.zcode/cli/artifacts" 2>/dev/null | cut -f1); artifacts_mb=${artifacts_mb:-0}
    db_mb=$(du -m "$DB" 2>/dev/null | cut -f1); db_mb=${db_mb:-0}
    META=$(qr "
      WITH P AS (SELECT provider_id AS v, row_number() OVER (ORDER BY provider_id)-1 AS i FROM (SELECT DISTINCT provider_id FROM model_usage)),
           M AS (SELECT model_id AS v, row_number() OVER (ORDER BY model_id)-1 AS i FROM (SELECT DISTINCT model_id FROM model_usage)),
           S AS (SELECT session_id AS v, row_number() OVER (ORDER BY session_id)-1 AS i FROM (SELECT DISTINCT session_id FROM model_usage)),
           PJ AS $PJ_SQL,
           R AS (SELECT * FROM model_usage ORDER BY started_at DESC LIMIT $limit)
      SELECT json_object(
        'providers',(SELECT json_group_array(v) FROM (SELECT v,i FROM P ORDER BY i)),
        'models',(SELECT json_group_array(v) FROM (SELECT v,i FROM M ORDER BY i)),
        'sessions',(SELECT json_group_array(coalesce(se.title,'')) FROM (SELECT v,i FROM S ORDER BY i) SI LEFT JOIN session se ON se.id=SI.v),
        'tools',(SELECT COALESCE(json_group_array(json_array(tool_name, c, f, d)),'[]') FROM (SELECT tool_name, count(*) AS c, sum(status<>'completed') AS f, CAST(round(avg(duration_ms)) AS int) AS d FROM tool_usage GROUP BY tool_name ORDER BY c DESC LIMIT 8)),
        'todos',(SELECT json_array(sum(CASE WHEN status='completed' THEN 1 ELSE 0 END), count(*)) FROM todo),
        'stability',(SELECT json_array(COALESCE(sum(retry_count),0), COALESCE(sum(cancelled_by_user),0), COALESCE(sum(CASE WHEN status='error' THEN 1 ELSE 0 END),0)) FROM model_usage),
        'hours',(SELECT COALESCE(json_group_object(hr, c),'{}') FROM (SELECT strftime('%H', started_at/1000,'unixepoch','localtime') AS hr, count(*) AS c FROM model_usage GROUP BY hr)),
        'compactions',(SELECT COALESCE(json_group_array(json_array(SI.i, c.cnt, c.maxpre)),'[]') FROM (SELECT p.session_id AS sid, count(*) AS cnt, max(COALESCE(json_extract(p.data,'$.preCompactTokenCount'),0)) AS maxpre FROM part p WHERE json_extract(p.data,'$.type')='compaction' GROUP BY p.session_id) c LEFT JOIN S SI ON SI.v = c.sid WHERE SI.i IS NOT NULL),
        'sessionTools',(SELECT COALESCE(json_group_array(json_array(SI.i, t.tool, t.c, t.ms)),'[]') FROM (SELECT session_id AS sid, tool_name AS tool, count(*) AS c, CAST(sum(duration_ms) AS int) AS ms FROM tool_usage GROUP BY session_id, tool_name) t LEFT JOIN S SI ON SI.v = t.sid WHERE SI.i IS NOT NULL),
        'disk', json('{"logs":$logs_mb,"rollout":$rollout_mb,"artifacts":$artifacts_mb,"db":$db_mb}'),
        'prices',(SELECT CASE
              WHEN pj IS NULL OR NOT json_valid(pj) THEN json('{}')
              ELSE json_object('currency', COALESCE(json_extract(pj,'$.currency'),'USD'),
                   'models', COALESCE(CASE WHEN json_type(pj,'$.models')='object'
                     THEN (SELECT json_group_object(lower(je.key), json(je.value)) FROM json_each(pj,'$.models') je
                           WHERE je.key IN (SELECT lower(v) FROM M) AND json_type(je.value)='object')
                     ELSE (SELECT json_group_object(lower(je.key), json(je.value)) FROM json_each(pj) je
                           WHERE je.key IN (SELECT lower(v) FROM M) AND json_type(je.value)='object')
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
                  R.cache_creation_input_tokens, R.time_to_first_token_ms))
                FROM R
                LEFT JOIN S SI ON SI.v = R.session_id
                LEFT JOIN M MI ON MI.v = R.model_id
                LEFT JOIN P PI ON PI.v = R.provider_id));")
    mkdir -p "$(dirname "$out")"
    {
      cat <<'UD_HEAD'
<div id="usage-dashboard">
<div id="ud-quota" class="viz-grid" hidden style="margin-bottom:8px"></div>
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
#usage-dashboard .ud-insights{display:flex;flex-wrap:wrap;padding:4px 0;}
#usage-dashboard .ud-ins{padding:2px 18px 2px 0;margin:2px 18px 2px 0;border-right:1px solid var(--border);}
#usage-dashboard .ud-ins:last-child{border-right:none;margin-right:0;}
#usage-dashboard .ud-ins-v{font-size:14px;font-weight:500;}
#usage-dashboard .ud-ins-l{font-size:11px;color:var(--muted-foreground);}
#usage-dashboard .ud-pager{display:flex;align-items:center;gap:10px;margin-top:10px;}
#usage-dashboard .ud-pager .btn{margin-top:0;}
#usage-dashboard .ud-legend{display:flex;flex-wrap:wrap;gap:4px 14px;margin:6px 0;}
#usage-dashboard .ud-legend .form-check{display:inline-flex;align-items:center;gap:4px;margin:0;}
#usage-dashboard .ud-click{cursor:pointer;}
#usage-dashboard .ud-click:hover td{background:var(--muted);}
#usage-dashboard .ud-exp td{background:var(--muted);padding:12px 14px;}
#usage-dashboard .ud-kv{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:8px 16px;margin:4px 0;}
#usage-dashboard .ud-kv-l{font-size:11px;color:var(--muted-foreground);}
#usage-dashboard .ud-kv-v{font-size:13px;font-weight:500;}
#usage-dashboard .ud-sec{margin-top:12px;}
#usage-dashboard pre.ud-raw{font-size:11px;background:var(--muted);border-radius:8px;padding:8px 10px;overflow-x:auto;white-space:pre;}
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
  <label class="form-check form-switch" id="ud-cost-wrap" hidden><input type="checkbox" class="form-check-input" id="ud-f-cost"><span class="form-check-label text-small">成本估算</span></label>
  <button type="button" class="btn" id="ud-price-sync" style="margin:0;padding:2px 10px;font-size:12px">同步价格</button>
  <span class="text-small text-muted" id="ud-meta"></span>
</div>
<div class="nav nav-pills" role="tablist" aria-label="用量视图">
  <button class="nav-link active" id="ud-tab-overview" role="tab" aria-controls="ud-overview" aria-selected="true" type="button">总览</button>
  <button class="nav-link" id="ud-tab-trend" role="tab" aria-controls="ud-trend" aria-selected="false" type="button">每日趋势</button>
  <button class="nav-link" id="ud-tab-blocks" role="tab" aria-controls="ud-blocks" aria-selected="false" type="button">5 小时窗口</button>
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
  <div class="ud-insights text-small" id="ud-insights" aria-live="polite"></div>
  <h3>来源构成</h3>
  <div id="ud-pv-stack"></div>
  <div id="ud-pv-rows"></div>
  <h3>模型分布</h3>
  <div id="ud-model-bars"></div>
  <h3>最活跃会话（Top 5）</h3>
  <div id="ud-top-sessions"></div>
  <div style="display:flex;justify-content:space-between;align-items:center">
    <h3 style="margin-bottom:0">时段分布</h3>
    <span class="text-small text-muted" id="ud-hours-note"></span>
  </div>
  <div id="ud-hours"></div>
  <div style="display:flex;justify-content:space-between;align-items:center">
    <h3 style="margin-bottom:0">活跃热力图</h3>
    <div class="viz-row" role="group" aria-label="热力图粒度" id="ud-heat-toggle">
      <button type="button" class="ud-toggle" data-hm="day" aria-pressed="true">每日</button>
      <button type="button" class="ud-toggle" data-hm="week" aria-pressed="false">每周</button>
    </div>
  </div>
  <div id="ud-heatmap"></div>
</div>
<div id="ud-trend" role="tabpanel" aria-labelledby="ud-tab-trend" hidden>
  <div class="viz-row" role="group" aria-label="指标切换" id="ud-series-toggle">
    <button type="button" class="ud-toggle" data-m="req" aria-pressed="true"><span class="ud-swatch" style="background:var(--viz-series-1)"></span>请求数</button>
    <button type="button" class="ud-toggle" data-m="inn" aria-pressed="false"><span class="ud-swatch" style="background:var(--viz-series-1)"></span>输入 token</button>
    <button type="button" class="ud-toggle" data-m="out" aria-pressed="false"><span class="ud-swatch" style="background:var(--viz-series-1)"></span>生成 token</button>
    <button type="button" class="ud-toggle" data-m="ca" aria-pressed="false"><span class="ud-swatch" style="background:var(--viz-series-1)"></span>缓存读 token</button>
    <span class="text-small text-muted" id="ud-trend-readout" aria-live="polite"></span>
  </div>
  <div class="ud-legend" id="ud-pv-legend"></div>
  <div id="ud-trend-chart"></div>
</div>
<div id="ud-blocks" role="tabpanel" aria-labelledby="ud-tab-blocks" hidden>
  <p class="text-small text-muted">相邻请求间隔满 5 小时即开启新窗口（同 ccusage 口径）。此为本地记录的近似口径，服务端套餐配额以 Usage Stats → Coding Plan 为准。</p>
  <div class="card" id="ud-block-now" style="margin:8px 0"></div>
  <div class="table-responsive"><table class="table table-sm">
    <thead><tr><th>开始</th><th>最近活动</th><th class="text-end">时长</th><th class="text-end">请求数</th><th class="text-end">输入 token</th><th class="text-end">生成 token</th></tr></thead>
    <tbody id="ud-blocks-body"></tbody>
  </table></div>
</div>
<div id="ud-sessions" role="tabpanel" aria-labelledby="ud-tab-sessions" hidden>
  <p class="text-small text-muted">点击表头排序，筛选条件在上方全局生效；点击行可展开会话详情。</p>
  <div class="table-responsive"><table class="table table-sm">
    <thead id="ud-sessions-head"></thead>
    <tbody id="ud-sessions-body"></tbody>
  </table></div>
</div>
<div id="ud-detail" role="tabpanel" aria-labelledby="ud-tab-detail" hidden>
  <p class="text-small text-muted">点击表头排序；点击任意请求行可展开该请求的完整信息。</p>
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
  <div class="ud-pager" id="ud-pager" aria-live="polite"></div>
</div>
<div id="ud-errors" role="tabpanel" aria-labelledby="ud-tab-errors" hidden>
  <div class="table-responsive"><table class="table table-sm">
    <thead><tr><th>时间</th><th>会话</th><th>模型</th><th>来源</th><th>类型</th><th>状态</th></tr></thead>
    <tbody id="ud-errors-body"></tbody>
  </table></div>
</div>
<script>
const DATA =
UD_HEAD
      printf '%s\n' "$META"
      cat <<'UD_TAIL'
;
function __usageBoot(D) {
  var PV = D.providers || [], MD = D.models || [], TL = D.sessions || [], R = D.rows || [];
  var TOOLS = D.tools || [], SD = D.sessionDirs || [];
  var PRICE = (D.prices && typeof D.prices === 'object') ? D.prices : null;
  var PMODELS = PRICE && PRICE.models && typeof PRICE.models === 'object' ? PRICE.models : PRICE;
  var CURSYM = (function () {
    var c = PRICE && PRICE.currency;
    return { USD: '$', CNY: '¥', EUR: '€', GBP: '£', JPY: '¥' }[c] || (c ? c + ' ' : '$');
  })();
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
  var QT = ['主会话', '子代理', '系统'];
  function stHtml(s) { return '<span style="white-space:nowrap"><span style="color:' + SCOLOR[s] + '">●</span> ' + STAT[s] + '</span>'; }

  // 供应商：官方账号(account:*) / 自定义接入，按总 token 降序分配固定系列色
  var pvTot = PV.map(function (p, i) { var t = 0; R.forEach(function (r) { if (r[3] === i) t += N(r[4]) + N(r[5]); }); return { i: i, t: t }; })
    .sort(function (a, b) { return b.t - a.t; });
  var pvOrder = pvTot.map(function (x) { return x.i; });
  function pvColor(p) { var k = pvOrder.indexOf(p); return 'var(--viz-series-' + ((k % 6) + 1) + ')'; }
  function pvLabel(p) { return esc(String(PV[p] || '?').replace(/^account:/, '')); }
  function pvTag(p) { return /^account:/.test(String(PV[p] || '')) ? '官方账号' : '自定义接入'; }

  function priceOf(mi) {
    if (!PMODELS) return null;
    var name = String(MD[mi] || '');
    var p = PMODELS[name] || PMODELS[name.toLowerCase()];
    if (!p) { for (var k in PMODELS) { if (k.toLowerCase() === name.toLowerCase()) { p = PMODELS[k]; break; } } }
    return p || null;
  }
  function tierMult(ts, t) {
    if (!t || !t.tiers) return 1;
    var d = new Date(ts);
    var h = d.getHours();
    if (typeof t.tz === 'number') h = ((d.getUTCHours() + t.tz) % 24 + 24) % 24;
    for (var i = 0; i < t.tiers.length; i++) {
      var tier = t.tiers[i] || {};
      var ws = tier.hours || [];
      for (var j = 0; j < ws.length; j++) {
        var b = ws[j][0], e = ws[j][1];
        if (b <= e ? (h >= b && h < e) : (h >= b || h < e)) return tier.mult == null ? 1 : tier.mult;
      }
    }
    return 1;
  }
  function rowCost(r) {
    var p = priceOf(r[2]);
    if (!p) return null;
    var base = N(r[4]) / 1e6 * N(p.in) + N(r[5]) / 1e6 * N(p.out) + N(r[6]) / 1e6 * N(p.cache);
    return base * tierMult(r[1], p.tariff);
  }
  function fmtMB(mb) { return mb >= 1024 ? (mb / 1024).toFixed(1) + ' GB' : N(mb) + ' MB'; }
  function fmtCost(c) { return c == null ? '–' : CURSYM + (c >= 100 ? Math.round(c).toLocaleString('zh-CN') : c.toFixed(2)); }

  var maxTs = 0;
  R.forEach(function (r) { if (r[1] > maxTs) maxTs = r[1]; });
  var cmpMap = {}, toolsMap = {};
  (D.compactions || []).forEach(function (c) { cmpMap[c[0]] = { cnt: c[1], pre: c[2] }; });
  (D.sessionTools || []).forEach(function (t) { (toolsMap[t[0]] || (toolsMap[t[0]] = [])).push([t[1], t[2], t[3]]); });

  var st = { p: -1, m: -1, rng: 'all', hidePv: {} };
  var sortS = { k: 4, d: -1 }, sortD = { k: 0, d: -1 };
  var page = 1, pageSize = 50, detailStat = -1, curMetric = 'req', costOn = false;
  var heatMode = 'day', heatLastW = -1, sessExp = -1, detExp = -1;

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
    var a = { req: rows.length, inn: 0, out: 0, ca: 0, ccw: 0, dur: 0, sub: 0, sids: {} };
    rows.forEach(function (r) {
      a.inn += N(r[4]); a.out += N(r[5]); a.ca += N(r[6]); a.ccw += N(r[10]); a.dur += N(r[7]);
      if (r[9] === 1) a.sub++;
      a.sids[r[0]] = 1;
    });
    a.sess = 0; for (var k in a.sids) a.sess++;
    a.tok = a.inn + a.out;
    return a;
  }
  function dayList(rows) {
    var s = {};
    rows.forEach(function (r) { s[dayKey(r[1])] = 1; });
    return Object.keys(s).sort();
  }

  function renderKpis(rows) {
    var a = agg(rows);
    var dcount = dayList(rows).length || 1;
    $('ud-k1').textContent = fmtI(a.req);
    $('ud-k1c').textContent = '日均 ' + fmt(a.req / dcount) + ' · 覆盖 ' + dcount + ' 天';
    $('ud-k2').textContent = fmt(a.inn);
    $('ud-k2c').textContent = '缓存读 ' + fmt(a.ca) + ' · 缓存写 ' + fmt(a.ccw);
    $('ud-k3').textContent = fmt(a.out);
    $('ud-k3c').textContent = '输出 + 思考 token';
    $('ud-k4').textContent = fmtI(a.sess);
    $('ud-k4c').textContent = a.sub ? '含子代理请求 ' + fmtI(a.sub) + ' 次' : '合计 ' + fmt(a.tok) + ' token';
    $('ud-meta').textContent = '数据截至 ' + (D.gen || '') + ' · 已加载最近 ' + fmtI(D.covered) + ' / ' + fmtI(D.total) + ' 条 · 仅统计本机';
  }

  function renderInsights(rows) {
    var a = agg(rows);
    var days = dayList(rows);
    // 连续天数：当前连续（今天/昨天截止）与最长连续
    var cur = 0, longest = 0, run = 0;
    var dayMs = days.map(function (k) { return new Date(k + 'T00:00:00').getTime(); });
    var lastMs = dayMs.length ? dayMs[dayMs.length - 1] : 0;
    var todayMs = new Date(new Date().toDateString()).getTime();
    for (var i = 0; i < dayMs.length; i++) {
      run = (i > 0 && dayMs[i] - dayMs[i - 1] === 864e5) ? run + 1 : 1;
      if (run > longest) longest = run;
    }
    cur = lastMs && (todayMs - lastMs <= 864e5) ? run : 0;
    var peak = null, peakV = -1;
    var perDay = {};
    rows.forEach(function (r) { var k = dayKey(r[1]); perDay[k] = (perDay[k] || 0) + N(r[4]) + N(r[5]); });
    for (var k in perDay) { if (perDay[k] > peakV) { peakV = perDay[k]; peak = k; } }
    var hit = a.inn ? Math.round(a.ca / a.inn * 100) : 0;
    var items = [
      ['活跃天数', days.length + ' 天'],
      ['连续活跃', '当前 ' + cur + ' 天 · 最长 ' + longest + ' 天'],
      ['峰值日', peak ? peak.slice(5) + '（' + fmt(peakV) + ' token）' : '–'],
      ['缓存命中率', hit + '%'],
      ['缓存量（读+写）', fmt(a.ca + a.ccw) + ' token'],
      ['任务完成', D.todos && D.todos[1] > 0 ? N(D.todos[0]) + '/' + D.todos[1] + '（' + Math.round(N(D.todos[0]) / D.todos[1] * 100) + '%）' : '–'],
      ['重试 / 取消', D.stability ? fmtI(D.stability[0]) + ' / ' + fmtI(D.stability[1]) : '–'],
      ['平均耗时', a.req ? (a.dur / a.req / 1000).toFixed(1) + ' s' : '–'],
      ['主会话 / 子代理', fmtI(a.req - a.sub) + ' / ' + fmtI(a.sub)]
    ];
    if (TOOLS.length) {
      items.push(['最常用工具', esc(String(TOOLS[0][0])).replace(/^mcp__/, '') + ' ×' + fmtI(TOOLS[0][1])]);
    }
    if (D.hours) {
      var pk = -1, pv2 = -1;
      for (var hh = 0; hh < 24; hh++) { var kk2 = (hh < 10 ? '0' : '') + hh; var c2 = N(D.hours[kk2]); if (c2 > pv2) { pv2 = c2; pk = hh; } }
      if (pk >= 0) items.push(['峰值时段', pk + ' 点（' + fmtI(pv2) + ' 次请求）']);
    }
    if (D.disk && D.disk.logs) items.push(['数据体量', '日志 ' + fmtMB(D.disk.logs) + ' · 导出 ' + fmtMB(D.disk.rollout) + ' · 库 ' + fmtMB(D.disk.db)]);
    var totalCost = 0, anyCost = false;
    rows.forEach(function (r) { var c = rowCost(r); if (c != null) { totalCost += c; anyCost = true; } });
    if (anyCost) items.push(['估算成本', fmtCost(totalCost)]);
    $('ud-insights').innerHTML = items.map(function (it) {
      return '<span class="ud-ins"><div class="ud-ins-v tabular-nums">' + it[1] + '</div><div class="ud-ins-l">' + it[0] + '</div></span>';
    }).join('');
  }

  function renderProviders(rows) {
    var per = PV.map(function (p, i) { return { i: i, req: 0, tok: 0, inn: 0, ca: 0, cost: 0, hasCost: false }; });
    rows.forEach(function (r) { var o = per[r[3]]; o.req++; o.tok += N(r[4]) + N(r[5]); o.inn += N(r[4]); o.ca += N(r[6]); var c = rowCost(r); if (c != null) { o.cost += c; o.hasCost = true; } });
    var tot = per.reduce(function (a, x) { return a + x.tok; }, 0);
    var act = per.filter(function (x) { return x.req > 0; }).sort(function (a, b) { return b.tok - a.tok; });
    if (!act.length) { $('ud-pv-stack').innerHTML = '<p class="text-muted">当前筛选下暂无数据</p>'; $('ud-pv-rows').innerHTML = ''; return; }
    $('ud-pv-stack').innerHTML = '<div class="ud-stack" role="img" aria-label="来源构成">' + act.map(function (x) {
      return '<span style="width:' + (tot ? (x.tok / tot * 100).toFixed(2) : 0) + '%;background:' + pvColor(x.i) + '"></span>';
    }).join('') + '</div>';
    $('ud-pv-rows').innerHTML = act.map(function (x) {
      return '<div class="text-small" style="display:flex;justify-content:space-between;gap:8px;padding:3px 0">' +
        '<span><span class="ud-dot" style="background:' + pvColor(x.i) + '"></span>' + pvLabel(x.i) + '<span class="ud-tag">' + pvTag(x.i) + '</span></span>' +
        '<span class="tabular-nums text-muted">' + fmtI(x.req) + ' 次 · ' + fmt(x.tok) + ' token · ' + (tot ? (x.tok / tot * 100).toFixed(1) : 0) + '% · 缓存 ' + (x.inn ? Math.round(x.ca / x.inn * 100) : 0) + '%' + (costOn && x.hasCost ? ' · ' + fmtCost(x.cost) : '') + '</span></div>';
    }).join('');
  }

  function renderModels(rows) {
    var per = {};
    rows.forEach(function (r) {
      var o = per[r[2]] || (per[r[2]] = { req: 0, tok: 0, inn: 0, ca: 0 });
      o.req++; o.tok += N(r[4]) + N(r[5]); o.inn += N(r[4]); o.ca += N(r[6]);
    });
    var list = Object.keys(per).map(function (m) { return { m: m, req: per[m].req, tok: per[m].tok, hit: per[m].inn ? Math.round(per[m].ca / per[m].inn * 100) : 0 }; })
      .sort(function (a, b) { return b.tok - a.tok; }).slice(0, 8);
    var tot = list.reduce(function (a, x) { return a + x.tok; }, 0);
    $('ud-model-bars').innerHTML = list.length ? list.map(function (x) {
      var p = tot ? Math.round(x.tok / tot * 100) : 0;
      return '<div style="margin:8px 0"><div class="text-small" style="display:flex;justify-content:space-between;gap:8px"><span>' + esc(MD[x.m]) + '</span><span class="tabular-nums text-muted">' + fmtI(x.req) + ' 次 · ' + fmt(x.tok) + ' token · ' + p + '% · 缓存 ' + x.hit + '%</span></div><div class="progress" role="progressbar" aria-label="' + esc(MD[x.m]) + ' 占比" aria-valuenow="' + p + '" aria-valuemin="0" aria-valuemax="100"><div class="progress-bar" style="width:' + p + '%"></div></div></div>';
    }).join('') : '<p class="text-muted">当前筛选下暂无数据</p>';
  }

  function sessAgg(rows) {
    var per = {};
    rows.forEach(function (r) {
      var o = per[r[0]] || (per[r[0]] = { tl: TL[r[0]] || '', req: 0, inn: 0, out: 0, ca: 0, sub: 0, last: 0, cost: 0, hasCost: false });
      o.req++; o.inn += N(r[4]); o.out += N(r[5]); o.ca += N(r[6]); if (r[1] > o.last) o.last = r[1];
      if (r[9] === 1) o.sub++;
      var c = rowCost(r); if (c != null) { o.cost += c; o.hasCost = true; }
    });
    return Object.keys(per).map(function (g) {
      var o = per[g]; o.g = +g; o.tot = o.inn + o.out;
      o.rate = o.inn ? Math.round(o.ca / o.inn * 100) : 0;
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

  function renderHours(rows) {
    var host = $('ud-hours');
    if (!host) return;
    var w = host.clientWidth;
    if (!w) return;
    var H = D.hours || {};
    var arr = [];
    for (var i = 0; i < 24; i++) { var kk = (i < 10 ? '0' : '') + i; arr.push(N(H[kk])); }
    var peak = 0;
    for (var i2 = 1; i2 < 24; i2++) if (arr[i2] > arr[peak]) peak = i2;
    var max = Math.max.apply(null, arr) || 1;
    var cw = Math.floor((w - 4) / 24);
    var bw = Math.max(3, cw - 3);
    var Hh = 92;
    var out = '';
    for (var i3 = 0; i3 < 24; i3++) {
      var bh = Math.round((Hh - 20) * arr[i3] / max);
      var x = 2 + i3 * cw;
      out += '<rect x="' + x + '" y="' + (Hh - 18 - bh) + '" width="' + bw + '" height="' + bh + '" rx="2" fill="var(--viz-series-1)"' + (i3 === peak ? '' : ' fill-opacity="0.45"') + '><title>' + i3 + ':00–' + i3 + ':59 · ' + fmtI(arr[i3]) + ' 次请求</title></rect>';
      if (i3 % 3 === 0) out += '<text x="' + (x + bw / 2) + '" y="' + (Hh - 4) + '" text-anchor="middle" font-size="10" fill="var(--muted-foreground)">' + i3 + '</text>';
    }
    host.innerHTML = '<svg width="' + (cw * 24) + '" height="' + Hh + '" role="img" aria-label="24 小时请求分布"><desc>峰值 ' + peak + ' 点</desc>' + out + '</svg>';
    var note = $('ud-hours-note');
    if (note) note.textContent = '峰值 ' + peak + ' 点 · ' + fmtI(arr[peak]) + ' 次请求';
  }
  function renderHeatmap(rows) {
    var host = $('ud-heatmap');
    if (!host) return;
    var w = host.clientWidth;
    if (!w) return;
    var per = {};
    rows.forEach(function (r) { var k = dayKey(r[1]); var o = per[k] || (per[k] = { req: 0, tok: 0 }); o.req++; o.tok += N(r[4]) + N(r[5]); });
    var days = Object.keys(per).sort();
    if (!days.length) { host.innerHTML = '<p class="text-muted">当前筛选下暂无数据</p>'; heatLastW = w; return; }
    var start = new Date(days[0] + 'T00:00:00'), end = new Date(days[days.length - 1] + 'T00:00:00');
    var cells = [];
    for (var d = new Date(start); d <= end; d.setDate(d.getDate() + 1)) {
      var k = dayKey(d.getTime());
      cells.push({ k: k, v: per[k] ? per[k].tok : 0, req: per[k] ? per[k].req : 0 });
    }
    var gap = 3, L = 2, T = 2;
    var out = '';
    function shade(v, qs) {
      if (v <= 0) return { fill: 'var(--muted)', op: '' };
      var f = 'var(--viz-series-1)';
      if (v <= qs[0]) return { fill: f, op: ' fill-opacity="0.35"' };
      if (v <= qs[1]) return { fill: f, op: ' fill-opacity="0.6"' };
      if (v <= qs[2]) return { fill: f, op: ' fill-opacity="0.85"' };
      return { fill: f, op: '' };
    }
    function rect(x, y, cw, ch, st2, tip) {
      return '<rect x="' + x + '" y="' + y + '" width="' + cw + '" height="' + ch + '" rx="3" fill="' + st2.fill + '"' + st2.op + '><title>' + esc(tip) + '</title></rect>';
    }
    if (heatMode === 'week') {
      var lead0 = (new Date(cells[0].k + 'T00:00:00').getDay() + 6) % 7;
      var weeks = [], wk = null;
      cells.forEach(function (c, i) {
        var wi = Math.floor((lead0 + i) / 7);
        if (!wk || wk.i !== wi) { wk = { i: wi, k: c.k, v: 0, req: 0 }; weeks.push(wk); }
        wk.v += c.v; wk.req += c.req;
      });
      var wv = weeks.map(function (x) { return x.v; }).filter(function (v) { return v > 0; }).sort(function (a, b) { return a - b; });
      var wq = [0.25, 0.5, 0.75].map(function (pp) { return wv.length ? wv[Math.min(wv.length - 1, Math.floor(wv.length * pp))] : 1; });
      var cw = Math.min(40, Math.floor((w - L - (weeks.length - 1) * gap) / Math.max(1, weeks.length)));
      var ch = Math.min(28, Math.max(14, cw));
      var W2 = L + weeks.length * (cw + gap), H2 = T + ch + 24;
      var lastM = '';
      weeks.forEach(function (x, i) {
        var x0 = L + i * (cw + gap);
        var mk = x.k.slice(0, 7);
        if (mk !== lastM) { lastM = mk; out += '<text x="' + x0 + '" y="' + (T + ch + 16) + '" font-size="10" fill="var(--muted-foreground)">' + Number(x.k.slice(5, 7)) + '月</text>'; }
        out += rect(x0, T, cw, ch, shade(x.v, wq), x.k + ' 当周 · ' + fmtI(x.req) + ' 次请求 · ' + fmt(x.v) + ' token');
      });
      host.innerHTML = '<svg width="' + W2 + '" height="' + H2 + '" role="img" aria-label="活跃热力图（每周 token）"><desc>共 ' + weeks.length + ' 周</desc>' + out + '</svg>';
      heatLastW = w;
      return;
    }
    var minCw = 6;
    var maxCols = Math.max(1, Math.floor((w - L - minCw) / (minCw + gap)));
    var maxCells = maxCols * 7;
    if (cells.length > maxCells) { cells = cells.slice(-maxCells); }
    start = new Date(cells[0].k + 'T00:00:00');
    var lead = (start.getDay() + 6) % 7;
    var cols = Math.ceil((lead + cells.length) / 7);
    var cw = Math.min(16, Math.floor((w - L - (cols - 1) * gap) / cols));
    var ch = cw;
    var W2 = L + cols * (cw + gap), H2 = T + 7 * (ch + gap) + 24;
    var dv = cells.map(function (c) { return c.v; }).filter(function (v) { return v > 0; }).sort(function (a, b) { return a - b; });
    var dq = [0.25, 0.5, 0.75].map(function (pp) { return dv.length ? dv[Math.min(dv.length - 1, Math.floor(dv.length * pp))] : 1; });
    var lastM = '';
    cells.forEach(function (c, i) {
      var pos = lead + i;
      var col = Math.floor(pos / 7), row = pos % 7;
      var x = L + col * (cw + gap), y = T + row * (ch + gap);
      if (row === 0) {
        var mk = c.k.slice(0, 7);
        if (mk !== lastM) {
          lastM = mk;
          out += '<text x="' + x + '" y="' + (T + 7 * (ch + gap) + 16) + '" font-size="10" fill="var(--muted-foreground)">' + Number(c.k.slice(5, 7)) + '月</text>';
        }
      }
      out += rect(x, y, cw, ch, shade(c.v, dq), c.k + ' · ' + fmtI(c.req) + ' 次请求 · ' + fmt(c.v) + ' token');
    });
    host.innerHTML = '<svg width="' + W2 + '" height="' + H2 + '" role="img" aria-label="活跃热力图（每日 token）"><desc>共 ' + cells.length + ' 天，' + dv.length + ' 天有用量</desc>' + out + '</svg>';
    heatLastW = w;
  }

  function renderBlocks(rows) {
    if (!rows.length) { $('ud-block-now').innerHTML = '<p class="text-muted">当前筛选下暂无数据</p>'; $('ud-blocks-body').innerHTML = ''; return; }
    var srt = rows.slice().sort(function (a, b) { return a[1] - b[1]; });
    var blocks = [], cur = null;
    srt.forEach(function (r) {
      if (!cur || r[1] - cur.start >= 18e6) { cur = { start: r[1], end: r[1], req: 0, inn: 0, out: 0, ca: 0 }; blocks.push(cur); }
      cur.end = r[1]; cur.req++; cur.inn += N(r[4]); cur.out += N(r[5]); cur.ca += N(r[6]);
    });
    var now = Date.now();
    var last = blocks[blocks.length - 1];
    var active = last && (now - last.start) < 18e6 ? last : null;
    if (active) {
      var elapsedMs = now - active.start;
      var elPct = Math.min(100, Math.round(elapsedMs / 18e6 * 100));
      var remainPct = 100 - elPct;
      var minsLeft = Math.max(0, Math.round((active.start + 18e6 - now) / 60000));
      var tok = active.inn + active.out;
      var rate = tok / Math.max(0.05, elapsedMs / 36e5);
      var complete = blocks.filter(function (b) { return b !== active; });
      var recent = complete.slice(-3);
      var avg = recent.length ? recent.reduce(function (a, b) { return a + b.inn + b.out; }, 0) / recent.length : 0;
      var projected = rate * 5;
      var cmp = '';
      if (avg > 0) {
        var diff = Math.round((projected - avg) / avg * 100);
        cmp = '<div class="text-small text-muted" style="margin-top:6px">近 ' + recent.length + ' 个完整窗口均值 ' + fmt(avg) + ' token · 按当前速率本窗口预计 ' + fmt(projected) + ' token（' + (diff >= 0 ? '高于' : '低于') + '均值 ' + Math.abs(diff) + '%）</div>';
      }
      var resetClock = fullTs(active.start + 18e6).slice(11, 16);
      $('ud-block-now').innerHTML =
        '<div style="display:flex;justify-content:space-between;align-items:baseline"><span class="text-small text-muted">本窗口剩余</span><span class="text-small text-muted">约 ' + resetClock + ' 重置 · 开始 ' + fullTs(active.start).slice(11) + '</span></div>' +
        '<div class="viz-stat-value tabular-nums">' + remainPct + '%</div>' +
        '<div class="progress" role="progressbar" aria-label="窗口剩余时间" aria-valuenow="' + remainPct + '" aria-valuemin="0" aria-valuemax="100" style="margin-top:6px"><div class="progress-bar" style="width:' + remainPct + '%"></div></div>' +
        '<div class="text-small text-muted" style="margin-top:6px">' + fmtI(active.req) + ' 次请求 · ' + fmt(tok) + ' token · 燃烧率 ' + fmt(rate) + ' token/h · 约 ' + minsLeft + ' 分钟后满 5 小时</div>' + cmp;
    } else {
      $('ud-block-now').innerHTML = '<div class="text-small text-muted">当前没有进行中的 5 小时窗口（最近一次活动 ' + (last ? fullTs(last.end) : '–') + '）。需要盯着燃烧率时，可在终端运行 <code>usage.sh live</code> 实时监控。</div>';
    }
    $('ud-blocks-body').innerHTML = blocks.slice(-12).reverse().map(function (b) {
      var hrs = ((b.end - b.start) / 36e5).toFixed(1);
      return '<tr><td class="text-nowrap">' + fullTs(b.start) + '</td><td class="text-nowrap">' + fullTs(b.end) + '</td><td class="text-end tabular-nums">' + hrs + ' h</td><td class="text-end tabular-nums">' + fmtI(b.req) + '</td><td class="text-end tabular-nums">' + fmt(b.inn) + '</td><td class="text-end tabular-nums">' + fmt(b.out) + '</td></tr>';
    }).join('');
  }

  function sessionDetailHTML(o) {
    var rs = R.filter(function (r) { return r[0] === o.g; }).sort(function (a, b) { return a[1] - b[1]; });
    var dir = SD[o.g] ? esc(SD[o.g]) : '<span class="text-muted">–</span>';
    var mm = {}, pv2 = {};
    rs.forEach(function (r) {
      var nm = String(MD[r[2]] || '?').toLowerCase();
      mm[nm] = (mm[nm] || 0) + N(r[4]) + N(r[5]);
      pv2[r[3]] = (pv2[r[3]] || 0) + 1;
    });
    var mtot = 0; for (var k in mm) mtot += mm[k];
    var mix = Object.keys(mm).sort(function (a, b) { return mm[b] - mm[a]; }).map(function (k) { return '<span class="text-small text-muted">' + esc(k) + ' ' + Math.round(mm[k] / mtot * 100) + '%</span>'; }).join(' · ');
    var pvm = Object.keys(pv2).map(function (k) { return '<span class="text-small text-muted">' + pvLabel(k) + ' ×' + pv2[k] + '</span>'; }).join(' · ');
    var tl = (toolsMap[o.g] || []).slice().sort(function (a, b) { return b[1] - a[1]; }).slice(0, 6)
      .map(function (t) { return '<span class="text-small text-muted">' + esc(String(t[0]).replace(/^mcp__/, '')) + ' ×' + fmtI(t[1]) + '</span>'; }).join(' · ');
    var cm = cmpMap[o.g];
    var cmpHtml = cm ? '压缩 ' + cm.cnt + ' 次 · 压缩前水位最高 ' + fmt(cm.pre) + ' token' : '无压缩记录';
    var W = 600, H = 90, maxIn = 1;
    rs.forEach(function (r) { if (N(r[4]) > maxIn) maxIn = N(r[4]); });
    var pts = rs.map(function (r, i) {
      var x = rs.length > 1 ? i / (rs.length - 1) * (W - 8) + 4 : W / 2;
      var y = H - 8 - (H - 16) * N(r[4]) / maxIn;
      return x.toFixed(1) + ',' + y.toFixed(1);
    }).join(' ');
    var curve = '<svg viewBox="0 0 ' + W + ' ' + H + '" width="100%" height="' + H + '" preserveAspectRatio="none" role="img" aria-label="上下文水位曲线"><polyline points="' + pts + '" fill="none" stroke="var(--viz-series-1)" stroke-width="1.5"/></svg>';
    function kv(l, v) { return '<div><div class="ud-kv-l">' + l + '</div><div class="ud-kv-v">' + v + '</div></div>'; }
    return '<div class="ud-kv">' +
      kv('项目目录', dir) +
      kv('起止', fullTs(rs.length ? rs[0][1] : 0) + ' ~ ' + fullTs(o.last)) +
      kv('请求 / 缓存率', fmtI(o.req) + ' 次 · ' + o.rate + '%') +
      kv('上下文压缩', cmpHtml) +
      (costOn && o.hasCost ? kv('估算成本', fmtCost(o.cost)) : '') +
      '</div>' +
      '<div class="ud-sec"><div class="ud-kv-l">模型占比（按 token）</div>' + mix + '</div>' +
      '<div class="ud-sec"><div class="ud-kv-l">来源</div>' + pvm + '</div>' +
      (tl ? '<div class="ud-sec"><div class="ud-kv-l">使用工具 Top 6</div>' + tl + '</div>' : '') +
      '<div class="ud-sec"><div class="ud-kv-l">上下文水位（按请求输入 token 近似，峰值 ' + fmt(maxIn) + '）</div>' + curve + '</div>';
  }
  function renderSessions(rows) {
    var keys = { 1: 'req', 2: 'inn', 3: 'out', 4: 'tot', 5: 'last', 6: 'cost', 7: 'rate' };
    var list = sessAgg(rows).sort(function (a, b) { return ((a[keys[sortS.k]] || 0) - (b[keys[sortS.k]] || 0)) * sortS.d; });
    var hasCmp = (D.compactions || []).length > 0;
    var cols = [
      { h: '会话', k: null }, { h: '请求数', k: 1, end: 1 }, { h: '输入 token', k: 2, end: 1 },
      { h: '生成 token', k: 3, end: 1 }, { h: 'token 合计', k: 4, end: 1 },
      { h: '缓存率', k: 7, end: 1 },
      hasCmp ? { h: '压缩', k: null, end: 1 } : null,
      costOn ? { h: '估算成本', k: 6, end: 1 } : null,
      { h: '最后活动', k: 5, end: 1 }
    ].filter(Boolean);
    var span = cols.length;
    $('ud-sessions-head').innerHTML = '<tr>' + cols.map(function (c) {
      var arrow = sortS.k === c.k ? (sortS.d < 0 ? ' ↓' : ' ↑') : '';
      return c.k == null ? '<th>' + c.h + '</th>' : '<th class="ud-sortable' + (c.end ? ' text-end' : '') + '" data-k="' + c.k + '"' + (sortS.k === c.k ? ' aria-sort="' + (sortS.d < 0 ? 'descending' : 'ascending') + '"' : '') + '>' + c.h + arrow + '</th>';
    }).join('') + '</tr>';
    var shown = list.slice(0, 30);
    var body = '';
    shown.forEach(function (o) {
      body += '<tr class="ud-click" data-sg="' + o.g + '"><td>' + sessTitle(o) + (o.sub ? '<span class="ud-tag">子代理 ×' + fmtI(o.sub) + '</span>' : '') + '</td><td class="text-end tabular-nums">' + fmtI(o.req) + '</td><td class="text-end tabular-nums">' + fmtI(o.inn) + '</td><td class="text-end tabular-nums">' + fmtI(o.out) + '</td><td class="text-end tabular-nums">' + fmtI(o.tot) + '</td><td class="text-end tabular-nums">' + o.rate + '%</td>' + (hasCmp ? '<td class="text-end text-nowrap">' + (cmpMap[o.g] ? cmpMap[o.g].cnt + ' 次' : '–') + '</td>' : '') + (costOn ? '<td class="text-end tabular-nums">' + (o.hasCost ? fmtCost(o.cost) : '–') + '</td>' : '') + '<td class="text-end text-nowrap">' + fullTs(o.last) + '</td></tr>';
      if (o.g === sessExp) body += '<tr class="ud-exp"><td colspan="' + span + '">' + sessionDetailHTML(o) + '</td></tr>';
    });
    $('ud-sessions-body').innerHTML = body || '<tr><td colspan="' + span + '" class="text-muted">当前筛选下暂无数据</td></tr>';
    Array.prototype.forEach.call($('ud-sessions-body').querySelectorAll('tr.ud-click'), function (tr) {
      tr.addEventListener('click', function () {
        var g = +tr.getAttribute('data-sg');
        sessExp = (sessExp === g) ? -1 : g;
        renderSessions(frows(false));
      });
    });
    Array.prototype.forEach.call($('ud-sessions-head').querySelectorAll('.ud-sortable'), function (th) {
      th.addEventListener('click', function () {
        var k = +th.getAttribute('data-k');
        if (sortS.k === k) sortS.d = -sortS.d; else { sortS.k = k; sortS.d = -1; }
        sessExp = -1;
        renderSessions(frows(false));
      });
    });
  }

  function requestDetailHTML(r) {
    function kv(l, v) { return '<div><div class="ud-kv-l">' + l + '</div><div class="ud-kv-v">' + v + '</div></div>'; }
    var ttftpct = r[11] != null && r[7] ? Math.round(r[11] / r[7] * 100) + '%' : '–';
    var c = costOn ? rowCost(r) : null;
    return '<div class="ud-kv">' +
      kv('Token 构成', '输入 ' + fmtI(r[4]) + '（缓存读 ' + fmtI(r[6]) + ' · 缓存写 ' + fmtI(r[10]) + '）+ 生成 ' + fmtI(r[5]) + ' = 合计 ' + fmtI(N(r[4]) + N(r[5]))) +
      kv('时序', '总耗时 ' + fmtI(r[7]) + ' ms · 首字 ' + (r[11] == null ? '–' : fmtI(r[11]) + ' ms（' + ttftpct + '）')) +
      kv('模型 / 来源 / 类型', esc(MD[r[2]]) + ' · ' + pvLabel(r[3]) + ' · ' + QT[r[9]]) +
      kv('会话', TL[r[0]] ? esc(TL[r[0]]) : '–') +
      (costOn ? kv('估算成本', c == null ? '–' : fmtCost(c)) : '') +
      '</div>' +
      (window.__USAGE_SERVE__ ? '<div class="ud-sec" id="ud-reqraw"><div class="ud-kv-l">正在拉取 provider 上报的原始用量…</div></div>' : '');
  }
  function fillRawUsage(id) {
    var el = $('ud-reqraw');
    if (!el) return;
    fetch('/api/request?id=' + encodeURIComponent(id)).then(function (x) { return x.json(); }).then(function (j) {
      if (j.error) { el.innerHTML = '<div class="ud-kv-l">原始用量：' + esc(j.error) + '</div>'; return; }
      var usage = '(无)';
      try { usage = j.raw_usage_json ? JSON.stringify(JSON.parse(j.raw_usage_json), null, 1) : usage; } catch (e) { usage = j.raw_usage_json || usage; }
      var extra = [];
      if (j.finish_reason) extra.push('finish_reason: ' + j.finish_reason);
      if (j.error_code || j.error_message) extra.push('错误: ' + (j.error_code || '') + ' ' + (j.error_message || ''));
      if (j.agent) extra.push('agent: ' + j.agent);
      el.innerHTML = '<div class="ud-kv-l">provider 上报的原始用量</div><pre class="ud-raw">' + esc(usage) + '</pre>' + (extra.length ? '<div class="text-small text-muted">' + esc(extra.join(' · ')) + '</div>' : '');
    }).catch(function (e) { el.innerHTML = '<div class="ud-kv-l">拉取失败：' + esc(String(e)) + '</div>'; });
  }
  function renderDetail(rows) {
    var ACC = {
      0: function (r) { return r[1]; },
      4: function (r) { return N(r[4]); },
      5: function (r) { return N(r[5]); },
      6: function (r) { return N(r[6]); },
      7: function (r) { return N(r[7]); },
      10: function (r) { return N(r[10]); },
      11: function (r) { return N(r[11]); },
      12: function (r) { return N(r[4]) + N(r[5]); },
      13: function (r) { return rowCost(r) || 0; }
    };
    var list = rows.filter(function (r) { return detailStat < 0 || r[8] === detailStat; })
      .sort(function (a, b) { return (ACC[sortD.k](a) - ACC[sortD.k](b)) * sortD.d; });
    var cols = [
      { h: '时间', k: 0 }, { h: '会话', k: null }, { h: '模型', k: null }, { h: '来源', k: null }, { h: '类型', k: null },
      { h: '输入', k: 4, end: 1 }, { h: '缓存读', k: 6, end: 1 }, { h: '缓存写', k: 10, end: 1 },
      { h: '生成', k: 5, end: 1 }, { h: '合计', k: 12, end: 1 }, { h: '耗时 ms', k: 7, end: 1 }, { h: '首字 ms', k: 11, end: 1 },
      { h: '状态', k: null },
      costOn ? { h: '成本', k: 13, end: 1 } : null
    ].filter(Boolean);
    var span = cols.length;
    $('ud-detail-head').innerHTML = '<tr>' + cols.map(function (c) {
      var arrow = sortD.k === c.k ? (sortD.d < 0 ? ' ↓' : ' ↑') : '';
      return c.k == null ? '<th>' + c.h + '</th>' : '<th class="ud-sortable' + (c.end ? ' text-end' : '') + '" data-k="' + c.k + '"' + (sortD.k === c.k ? ' aria-sort="' + (sortD.d < 0 ? 'descending' : 'ascending') + '"' : '') + '>' + c.h + arrow + '</th>';
    }).join('') + '</tr>';
    var totalPages = Math.max(1, Math.ceil(list.length / pageSize));
    if (page > totalPages) page = totalPages;
    if (page < 1) page = 1;
    var view = list.slice((page - 1) * pageSize, page * pageSize);
    var body = '';
    view.forEach(function (r, i) {
      body += '<tr class="ud-click" data-di="' + i + '"><td class="text-nowrap">' + fullTs(r[1]) + '</td>' +
        '<td>' + (TL[r[0]] ? esc(TL[r[0]]) : '<span class="text-muted">（无标题）</span>') + '</td>' +
        '<td>' + esc(MD[r[2]]) + '</td><td>' + pvLabel(r[3]) + '</td><td>' + QT[r[9]] + '</td>' +
        '<td class="text-end tabular-nums">' + fmtI(r[4]) + '</td>' +
        '<td class="text-end tabular-nums">' + fmtI(r[6]) + '</td>' +
        '<td class="text-end tabular-nums">' + fmtI(r[10]) + '</td>' +
        '<td class="text-end tabular-nums">' + fmtI(r[5]) + '</td>' +
        '<td class="text-end tabular-nums">' + fmtI(N(r[4]) + N(r[5])) + '</td>' +
        '<td class="text-end tabular-nums">' + fmtI(r[7]) + '</td>' +
        '<td class="text-end tabular-nums">' + (r[11] == null ? '–' : fmtI(r[11])) + '</td>' +
        '<td>' + stHtml(r[8]) + '</td>' +
        (costOn ? '<td class="text-end tabular-nums">' + (rowCost(r) == null ? '–' : fmtCost(rowCost(r))) + '</td>' : '') +
        '</tr>';
      if (detExp === i) body += '<tr class="ud-exp"><td colspan="' + span + '">' + requestDetailHTML(r) + '</td></tr>';
    });
    $('ud-detail-body').innerHTML = body || '<tr><td colspan="' + span + '" class="text-muted">当前筛选下暂无数据</td></tr>';
    $('ud-pager').innerHTML = '<button type="button" class="btn" id="ud-prev"' + (page <= 1 ? ' disabled' : '') + '>上一页</button>' +
      '<span class="text-small text-muted tabular-nums">第 ' + page + ' / ' + totalPages + ' 页 · 共 ' + fmtI(list.length) + ' 条</span>' +
      '<button type="button" class="btn" id="ud-next"' + (page >= totalPages ? ' disabled' : '') + '>下一页</button>';
    var prevBtn = $('ud-prev'), nextBtn = $('ud-next');
    if (prevBtn) prevBtn.addEventListener('click', function () { page--; detExp = -1; renderDetail(frows(false)); });
    if (nextBtn) nextBtn.addEventListener('click', function () { page++; detExp = -1; renderDetail(frows(false)); });
    Array.prototype.forEach.call($('ud-detail-body').querySelectorAll('tr.ud-click'), function (tr) {
      tr.addEventListener('click', function () {
        var i = +tr.getAttribute('data-di');
        detExp = (detExp === i) ? -1 : i;
        renderDetail(frows(false));
        if (detExp >= 0 && window.__USAGE_SERVE__) fillRawUsage(view[detExp][12]);
      });
    });
    Array.prototype.forEach.call($('ud-detail-head').querySelectorAll('.ud-sortable'), function (th) {
      th.addEventListener('click', function () {
        var k = +th.getAttribute('data-k');
        if (sortD.k === k) sortD.d = -sortD.d; else { sortD.k = k; sortD.d = -1; }
        detExp = -1;
        renderDetail(frows(false));
      });
    });
  }

  function renderErrors(rows) {
    var list = rows.filter(function (r) { return r[8] !== 0; }).sort(function (a, b) { return b[1] - a[1]; }).slice(0, 30);
    $('ud-errors-body').innerHTML = list.length ? list.map(function (r) {
      return '<tr><td class="text-nowrap">' + fullTs(r[1]) + '</td><td>' + (TL[r[0]] ? esc(TL[r[0]]) : '<span class="text-muted">（无标题）</span>') + '</td><td>' + esc(MD[r[2]]) + '</td><td>' + pvLabel(r[3]) + '</td><td>' + QT[r[9]] + '</td><td>' + stHtml(r[8]) + '</td></tr>';
    }).join('') : '<tr><td colspan="6" class="text-muted">当前筛选下没有失败或取消的请求</td></tr>';
  }

  function drawTrend() {
    var host = $('ud-trend-chart');
    if (!host) return;
    var w = host.clientWidth;
    if (!w) return;
    var rows = frows(false);
    if (!rows.length) { host.innerHTML = '<p class="text-muted">当前筛选下暂无数据</p>'; return; }
    var days = dayList(rows);
    var perDay = {};
    rows.forEach(function (r) {
      var k = dayKey(r[1]);
      var o = perDay[k] || (perDay[k] = {});
      var m = o[r[3]] || (o[r[3]] = { req: 0, inn: 0, out: 0, ca: 0 });
      m.req++; m.inn += N(r[4]); m.out += N(r[5]); m.ca += N(r[6]);
    });
    var active = {};
    rows.forEach(function (r) { active[r[3]] = 1; });
    var pvs = pvOrder.filter(function (p) { return active[p] && !st.hidePv[p]; });
    var legendRows = frows(true).reduce(function (acc, r) {
      var o = acc[r[3]] || (acc[r[3]] = { req: 0, inn: 0, out: 0, ca: 0 });
      o.req++; o.inn += N(r[4]); o.out += N(r[5]); o.ca += N(r[6]);
      return acc;
    }, {});
    $('ud-pv-legend').innerHTML = pvOrder.filter(function (p) { return active[p]; }).map(function (p) {
      var o = legendRows[p] || { req: 0, inn: 0, out: 0, ca: 0 };
      var total = o[curMetric];
      return '<label class="form-check form-switch"><input type="checkbox" class="form-check-input" data-pv="' + p + '"' + (st.hidePv[p] ? '' : ' checked') + '><span class="ud-swatch" style="background:' + pvColor(p) + '"></span><span class="form-check-label text-small">' + pvLabel(p) + ' · ' + fmt(total) + '</span></label>';
    }).join('');
    Array.prototype.forEach.call(document.querySelectorAll('#ud-pv-legend input'), function (cb) {
      cb.addEventListener('change', function () {
        st.hidePv[+cb.getAttribute('data-pv')] = !cb.checked;
        drawTrend();
      });
    });
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
    renderInsights(rows);
    renderProviders(frows(true));
    renderModels(rows);
    renderTopSessions(rows);
    renderHours(rows);
    renderHeatmap(rows);
    renderBlocks(rows);
    renderSessions(rows);
    renderDetail(rows);
    renderErrors(rows);
    drawTrend();
  }

  // 筛选控件
  fillSelect($('ud-f-pv'), '全部来源', PV.map(function (p, i) { return { v: i, label: pvLabel(i) + '（' + pvTag(i) + '）' }; }));
  fillSelect($('ud-f-model'), '全部模型', MD.map(function (m, i) { return { v: i, label: String(m) }; }));
  if (PRICE && Object.keys(PRICE).length) { $('ud-cost-wrap').hidden = false; }
  $('ud-f-pv').addEventListener('change', function () { st.p = +this.value; page = 1; sessExp = -1; detExp = -1; apply(); });
  $('ud-f-model').addEventListener('change', function () { st.m = +this.value; page = 1; sessExp = -1; detExp = -1; apply(); });
  $('ud-f-stat').addEventListener('change', function () { detailStat = +this.value; page = 1; renderDetail(frows(false)); });
  $('ud-f-cost').addEventListener('change', function () { costOn = this.checked; renderProviders(frows(true)); renderSessions(frows(false)); renderInsights(frows(false)); });
  Array.prototype.forEach.call(document.querySelectorAll('#ud-f-range .ud-toggle'), function (b) {
    b.addEventListener('click', function () {
      st.rng = b.getAttribute('data-r');
      Array.prototype.forEach.call(document.querySelectorAll('#ud-f-range .ud-toggle'), function (x) {
        x.setAttribute('aria-pressed', String(x === b));
      });
      page = 1; sessExp = -1; detExp = -1; apply();
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
  Array.prototype.forEach.call(document.querySelectorAll('#ud-heat-toggle .ud-toggle'), function (b) {
    b.addEventListener('click', function () {
      heatMode = b.getAttribute('data-hm');
      Array.prototype.forEach.call(document.querySelectorAll('#ud-heat-toggle .ud-toggle'), function (x) {
        x.setAttribute('aria-pressed', String(x === b));
      });
      heatLastW = -1;
      renderHeatmap(frows(false));
    });
  });
  $('ud-price-sync').addEventListener('click', function () {
    var btn = this;
    btn.disabled = true;
    btn.textContent = '同步中…';
    if (window.__USAGE_SERVE__) {
      fetch('/api/sync-prices', { method: 'POST' }).then(function () { location.reload(); }).catch(function () {
        btn.textContent = '同步失败'; btn.disabled = false;
      });
    } else if (window.zcode && window.zcode.sendFollowUpMessage) {
      window.zcode.sendFollowUpMessage({ prompt: '请运行 /usage prices sync 从 models.dev 同步官方价格表，完成后用 /usage-ui 重新生成用量仪表盘', title: '同步官方价格表' });
      btn.textContent = '已请求同步';
      setTimeout(function () { btn.textContent = '同步价格'; btn.disabled = false; }, 3000);
    } else {
      btn.textContent = '当前环境不支持';
      setTimeout(function () { btn.textContent = '同步价格'; btn.disabled = false; }, 3000);
    }
  });
  $('ud-tab-trend').addEventListener('click', function () { requestAnimationFrame(drawTrend); });
  if (typeof ResizeObserver === 'function') {
    new ResizeObserver(function () { drawTrend(); }).observe($('ud-trend-chart'));
    new ResizeObserver(function () {
      var w = $('ud-heatmap').clientWidth;
      if (w && w !== heatLastW) renderHeatmap(frows(false));
    }).observe($('ud-heatmap'));
  }

  function renderQuota(j) {
    var el = $('ud-quota');
    if (!el) return;
    el.hidden = false;
    if (!j || !j.ok || !j.limits || !j.limits.length) {
      el.innerHTML = '<div class="card" style="grid-column:1/-1"><span class="text-small text-muted">实时配额条不可用：' + esc((j && j.error) || '监控接口未返回配额') + '。桌面 OAuth 登录态不适用于该接口；如用 API Key 接入，可在 ~/.zcode/usage-quota-token.json 写入 {"token":"你的KEY","base":"https://open.bigmodel.cn"}。</span></div>';
      return;
    }
    var names = { TOKENS_LIMIT: '5 小时池已用', TIME_LIMIT: 'MCP（月）已用', WEEKLY_LIMIT: '周配额已用', TOKENS_WEEKLY_LIMIT: '周配额已用' };
    el.innerHTML = j.limits.map(function (l) {
      var pct = Math.round(N(l.percentage));
      var name = names[l.type] || l.type;
      var reset = l.resetTime ? '<span class="text-small text-muted">' + esc(String(l.resetTime)) + ' 重置</span>' : '';
      return '<div class="card"><div style="display:flex;justify-content:space-between;align-items:baseline"><span class="text-small text-muted">' + esc(name) + '</span>' + reset + '</div><div class="viz-stat-value tabular-nums">' + pct + '%</div><div class="progress" style="margin-top:6px"><div class="progress-bar" style="width:' + pct + '%"></div></div></div>';
    }).join('');
  }
  window.__usageRenderQuota = renderQuota;

  apply();
  window.__usageBootDone = true;
}
if (window.__USAGE_DATA_URL__) {
  fetch(window.__USAGE_DATA_URL__).then(function (r) { return r.json(); }).then(function (j) { __usageBoot(j); });
} else {
  __usageBoot(DATA || {});
}
</script>
</div>
UD_TAIL
    } > "$out"
    echo "已生成用量界面：$out"
    ;;
  quota)
    # 官方配额：5 小时/周/MCP 池用量百分比（凭据解析见 quota.mjs）
    command -v node >/dev/null 2>&1 || { echo "quota 需要 node" >&2; exit 1; }
    exec node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/quota.mjs"
    ;;
  serve)
    # 本地常驻面板：浏览器打开，自动轮询燃烧率（只监听 127.0.0.1，只读）
    command -v node >/dev/null 2>&1 || { echo "serve 需要 node" >&2; exit 1; }
    port=$(num_arg 7741 "${2:-}")
    exec node "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/serve.mjs" "$port"
    ;;
  help|*)
    cat <<'EOF'
用法：usage.sh [子命令] [参数]
  summary                  总览：累计 + 今日（默认）
  providers                按来源（官方套餐 / 自定义接入）汇总
  blocks                   5 小时窗口用量（末尾窗口若在 5h 内即进行中）
  months                   按月汇总
  projects [N]             按项目目录汇总 Top N（默认 15）
  tools [N]                工具调用统计 Top N（默认 15）
  cost                     成本估算（默认用内置官方价，~/.zcode/usage-prices.json 可覆盖）
  prices [show|sync]       查看价格表 / 从 models.dev 同步官方价（保留自定义条目）
  live [秒]                终端实时燃烧率监控（默认 3s 刷新，Ctrl-C 退出；供用户在终端运行）
  export csv|json [路径]   导出全部记录（默认当前目录）
  recent [N]               最近 N 条逐条请求明细（默认 20）
  day [YYYY-MM-DD]         某天逐条明细（缺省今天）
  days [N]                 最近 N 天按天汇总（默认 14）
  sessions [N]             按会话用量 Top N（默认 15）
  models                   按模型汇总
  errors [N]               最近 N 条失败请求（默认 10）
  dashboard <输出.html> [条数]
                           生成交互式用量界面（HTML 片段，供 ZCode 内嵌渲染）；
                           条数默认 3000，可用 ZCODE_USAGE_LIMIT 覆盖，范围 1-20000
  serve [端口]             本地常驻面板（默认端口 7741），浏览器打开、5s 轮询实时燃烧率
  quota                    官方套餐配额（5小时/周/MCP 池用量百分比，凭据不可用时提示）
环境变量：ZCODE_USAGE_DB 覆盖数据库路径；ZCODE_USAGE_PRICES 覆盖价格表路径；ZCODE_USAGE_LIMIT 覆盖默认内嵌条数；ZCODE_USAGE_NO_AUTOSYNC=1 关闭价格表每日自动同步。
EOF
    ;;
esac
