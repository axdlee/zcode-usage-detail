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

# SQL 字符串字面量；会话 ID、目录、价格表路径都可能含单引号。
sql_quote() {
  local value="$1"
  # Bash 3.2 的替换表达式置于双引号内会保留多余反斜杠。
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

# 定位一次后固定 ID，后续查询不会因其他窗口的新请求切换会话。
resolve_session() {
  local requested='' directory='' directory_sql=''
  SESSION_MODE='最近请求推断（多窗口时请核对）'
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --session|--directory)
        [[ $# -ge 2 && -n "$2" ]] || { echo "$1 需要非空参数" >&2; exit 1; }
        [[ -z "$requested$directory" ]] || { echo "--session 与 --directory 只能指定一个且不能重复" >&2; exit 1; }
        if [[ "$1" == --session ]]; then requested="$2"; else directory="$2"; fi
        shift 2
        ;;
      *) echo "未知会话参数：${1}（可用 --session ID 或 --directory DIR）" >&2; exit 1 ;;
    esac
  done
  if [[ -n "$requested" ]]; then
    SESSION_ID="$requested"
    SESSION_MODE='显式指定会话'
    SESSION_SQL=$(sql_quote "$SESSION_ID")
    [[ "$(qr "SELECT EXISTS(SELECT 1 FROM session WHERE id=$SESSION_SQL) OR EXISTS(SELECT 1 FROM model_usage WHERE session_id=$SESSION_SQL);")" == 1 ]] || {
      echo "未找到指定会话：$SESSION_ID" >&2; exit 1;
    }
  else
    if [[ -n "$directory" ]]; then
      directory_sql="AND session_id IN (SELECT id FROM session WHERE directory=$(sql_quote "$directory"))"
      SESSION_MODE='指定目录内最近请求推断（多窗口时请核对）'
    fi
    SESSION_ID=$(qr "SELECT session_id FROM model_usage WHERE session_id IS NOT NULL AND session_id<>'' $directory_sql ORDER BY started_at DESC, id DESC LIMIT 1;")
    [[ -n "$SESSION_ID" ]] || { echo "未找到可用于定位会话的模型请求${directory:+（目录：${directory}）}；可用 --session ID 指定会话" >&2; exit 1; }
    SESSION_SQL=$(sql_quote "$SESSION_ID")
  fi
}

session_info() {
  q "SELECT $SESSION_SQL AS 会话ID,
            coalesce(nullif(s.title,''),'（无标题或会话已删除）') AS 会话标题,
            coalesce(s.directory,'-') AS 项目目录,
            datetime(s.time_created/1000,'unixepoch','localtime') AS 创建时间,
            (SELECT datetime(max(started_at)/1000,'unixepoch','localtime') FROM model_usage WHERE session_id=$SESSION_SQL) AS 最近请求
     FROM (SELECT 1) LEFT JOIN session s ON s.id=$SESSION_SQL;"
  echo "定位方式：${SESSION_MODE}；仅统计该 session_id 的记录。"
}

cmd="${1:-summary}"
case "$cmd" in
  this)
    resolve_session "${@:2}"
    session_info
    echo
    echo "—— 会话汇总（全部状态；输入含缓存读，生成=输出+思考）——"
    q "SELECT count(*) AS 总请求数,
              coalesce(sum(status='completed'),0) AS 完成数,
              coalesce(sum(status='error'),0) AS 失败数,
              coalesce(sum(status='cancelled'),0) AS 取消数,
              coalesce(sum(status NOT IN ('completed','error','cancelled')),0) AS 其他状态数,
              coalesce(sum(input_tokens),0) AS 输入token,
              coalesce(sum(output_tokens+reasoning_tokens),0) AS 生成token,
              coalesce(sum(cache_read_input_tokens),0) AS 缓存读token
       FROM model_usage WHERE session_id=$SESSION_SQL;"
    echo
    echo "—— 按模型与来源（全部状态）——"
    q "SELECT model_id AS 模型, $PV_LABEL AS 来源,
              count(*) AS 请求数,
              sum(input_tokens) AS 输入token,
              sum(output_tokens+reasoning_tokens) AS 生成token,
              sum(cache_read_input_tokens) AS 缓存读token
       FROM model_usage WHERE session_id=$SESSION_SQL
       GROUP BY model_id, provider_id ORDER BY sum(input_tokens+output_tokens+reasoning_tokens) DESC;"
    echo
    echo "—— 最近失败/取消请求（最多 10 条）——"
    q "SELECT datetime(started_at/1000,'unixepoch','localtime') AS 时间,
              model_id AS 模型, $PV_LABEL AS 来源, status AS 状态,
              coalesce(error_code,'-') AS 错误码,
              substr(coalesce(error_message,'-'),1,60) AS 错误信息
       FROM model_usage WHERE session_id=$SESSION_SQL AND status IN ('error','cancelled')
       ORDER BY started_at DESC, id DESC LIMIT 10;"
    ;;
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
    echo "（估算口径：官方牌价 × 本地记录 token；订阅套餐内请求实际不按 token 计费）"
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
let n = 0;
for (const prov of ['zai', 'zhipuai']) {
  for (const [m, v] of Object.entries((md[prov] || {}).models || {})) {
    if (!/glm/i.test(m)) continue;
    const p = v.price || v.cost;
    if (!p) continue;
    out.models[m] = { in: p.input || 0, out: p.output || 0, cache: p.cache_read || 0 };
    n++;
  }
}
out.source = 'models.dev';
out.updated = new Date().toISOString().slice(0, 10);
fs.mkdirSync(require('path').dirname(user), { recursive: true });
fs.writeFileSync(user, JSON.stringify(out, null, 2) + '\n');
console.log('已同步 ' + n + ' 个官方模型价到 ' + user + '（自定义条目保留，官方价以 models.dev 为准）');
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
            'total',(SELECT count(*) FROM model_usage),
            'covered',(SELECT count(*) FROM R),
            'gen',(SELECT datetime('now','localtime')),
            'rows',(SELECT json_group_array(json_array(
                      SI.i, R.started_at, MI.i, PI.i,
                      R.input_tokens, R.output_tokens+R.reasoning_tokens, R.cache_read_input_tokens,
                      R.duration_ms,
                      CASE R.status WHEN 'completed' THEN 0 WHEN 'error' THEN 1 WHEN 'cancelled' THEN 2 ELSE 3 END,
                      CASE R.query_source WHEN 'main_turn' THEN 0 WHEN 'subagent' THEN 1 ELSE 2 END))
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
  dashboard|dashboard-this)
    # 生成交互式用量界面（HTML 片段），输出路径必须由调用方指定。
    # 默认最近 3000 条；全量 dashboard 可用第三参数调整，会话版用 ZCODE_USAGE_LIMIT 调整。
    out="${2:-}"
    [[ -n "$out" ]] || { echo "用法：usage.sh $cmd <输出.html>" >&2; exit 1; }
    scope=''
    session_meta='null'
    limit_arg="${3:-}"
    if [[ "$cmd" == dashboard-this ]]; then
      limit_arg=''
      resolve_session "${@:3}"
      scope="WHERE session_id=$SESSION_SQL"
      session_meta="(SELECT json_object('id',$SESSION_SQL,
        'title',coalesce(nullif(s.title,''),'（无标题或会话已删除）'),
        'directory',s.directory,'created',s.time_created,
        'latest',(SELECT max(started_at) FROM model_usage $scope),
        'selection',$(sql_quote "$SESSION_MODE"))
        FROM (SELECT 1) LEFT JOIN session s ON s.id=$SESSION_SQL)"
    fi
    limit=$(num_arg "${ZCODE_USAGE_LIMIT:-3000}" "$limit_arg")
    is_num "$limit" && [[ "$limit" -ge 1 && "$limit" -le 20000 ]] || { echo "条数应在 1-20000 之间：${limit}（更多历史请用 export json）" >&2; exit 1; }
    pf=$(price_file)
    if [[ -n "$pf" ]]; then
      PJ_SQL="(SELECT CAST(readfile($(sql_quote "$pf")) AS text) AS pj)"
    else
      PJ_SQL="(SELECT NULL AS pj)"
    fi
    META=$(qr "
      WITH U AS (SELECT * FROM model_usage $scope),
           P AS (SELECT provider_id AS v, row_number() OVER (ORDER BY provider_id)-1 AS i FROM (SELECT DISTINCT provider_id FROM U)),
           M AS (SELECT model_id AS v, row_number() OVER (ORDER BY model_id)-1 AS i FROM (SELECT DISTINCT model_id FROM U)),
           S AS (SELECT session_id AS v, row_number() OVER (ORDER BY session_id)-1 AS i FROM (SELECT DISTINCT session_id FROM U)),
           PJ AS $PJ_SQL,
           R AS (SELECT * FROM U ORDER BY started_at DESC, id DESC LIMIT $limit)
      SELECT json_object(
        'session',$session_meta,
        'providers',(SELECT json_group_array(v) FROM (SELECT v,i FROM P ORDER BY i)),
        'models',(SELECT json_group_array(v) FROM (SELECT v,i FROM M ORDER BY i)),
        'sessions',(SELECT json_group_array(coalesce(se.title,'')) FROM (SELECT v,i FROM S ORDER BY i) SI LEFT JOIN session se ON se.id=SI.v),
        'tools',(SELECT COALESCE(json_group_array(json_array(tool_name, c, f, d)),'[]') FROM (SELECT tool_name, count(*) AS c, sum(status<>'completed') AS f, CAST(round(avg(duration_ms)) AS int) AS d FROM tool_usage $scope GROUP BY tool_name ORDER BY c DESC LIMIT 8)),
        'prices',(SELECT CASE WHEN pj IS NOT NULL AND json_valid(pj) THEN json(pj) ELSE json('{}') END FROM PJ),
        'total',(SELECT count(*) FROM U),
        'covered',(SELECT count(*) FROM R),
        'gen',(SELECT datetime('now','localtime')),
        'rows',(SELECT json_group_array(json_array(
                  SI.i, R.started_at, MI.i, PI.i,
                  R.input_tokens, R.output_tokens+R.reasoning_tokens, R.cache_read_input_tokens,
                  R.duration_ms,
                  CASE R.status WHEN 'completed' THEN 0 WHEN 'error' THEN 1 WHEN 'cancelled' THEN 2 ELSE 3 END,
                  CASE R.query_source WHEN 'main_turn' THEN 0 WHEN 'subagent' THEN 1 ELSE 2 END))
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
#usage-dashboard .ud-insights{display:flex;flex-wrap:wrap;gap:4px 18px;padding:6px 0;}
#usage-dashboard .ud-insights .text-muted{margin-right:4px;}
</style>
<div id="ud-session" hidden>
  <h3 id="ud-session-title"></h3>
  <p class="text-small text-muted" id="ud-session-info" style="white-space:pre-wrap;overflow-wrap:anywhere"></p>
</div>
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
  <h3>活跃热力图</h3>
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
    <thead><tr><th>时间</th><th>会话</th><th>模型</th><th>来源</th><th>类型</th><th>状态</th></tr></thead>
    <tbody id="ud-errors-body"></tbody>
  </table></div>
</div>
<script>
const DATA =
UD_HEAD
      # JSON 位于 script 中：转义 < 防止会话标题中的 </script> 提前闭合标签。
      printf '%s\n' "${META//</\\u003c}"
      cat <<'UD_TAIL'
;
(function () {
  var D = DATA || {};
  var PV = D.providers || [], MD = D.models || [], TL = D.sessions || [], R = D.rows || [];
  var TOOLS = D.tools || [];
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

  if (D.session) {
    $('ud-session').hidden = false;
    $('ud-session-title').textContent = '会话用量 · ' + D.session.title;
    $('ud-session-info').textContent = '会话 ID：' + D.session.id + '\n项目目录：' + (D.session.directory || '–')
      + '\n创建：' + (D.session.created == null ? '–' : fullTs(D.session.created))
      + ' · 最近请求：' + (D.session.latest == null ? '暂无请求' : fullTs(D.session.latest))
      + '\n定位方式：' + D.session.selection + '；仅统计该 session_id 的记录。';
  }

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
  function rowCost(r) {
    var p = priceOf(r[2]);
    if (!p) return null;
    return N(r[4]) / 1e6 * N(p.in) + N(r[5]) / 1e6 * N(p.out) + N(r[6]) / 1e6 * N(p.cache);
  }
  function fmtCost(c) { return c == null ? '–' : CURSYM + (c >= 100 ? Math.round(c).toLocaleString('zh-CN') : c.toFixed(2)); }

  var maxTs = 0;
  R.forEach(function (r) { if (r[1] > maxTs) maxTs = r[1]; });

  var st = { p: -1, m: -1, rng: 'all' };
  var sortS = { k: 4, d: -1 }, sortD = { k: 0, d: -1 };
  var shown = 50, detailStat = -1, curMetric = 'req', costOn = false;

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
    var a = { req: rows.length, inn: 0, out: 0, ca: 0, dur: 0, sub: 0, sids: {} };
    rows.forEach(function (r) {
      a.inn += N(r[4]); a.out += N(r[5]); a.ca += N(r[6]); a.dur += N(r[7]);
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
    $('ud-k2c').textContent = '其中缓存读 ' + fmt(a.ca);
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
      ['平均耗时', a.req ? (a.dur / a.req / 1000).toFixed(1) + ' s' : '–'],
      ['主会话 / 子代理', fmtI(a.req - a.sub) + ' / ' + fmtI(a.sub)]
    ];
    if (TOOLS.length) {
      items.push(['最常用工具', esc(String(TOOLS[0][0])).replace(/^mcp__/, '') + ' ×' + fmtI(TOOLS[0][1])]);
    }
    var totalCost = 0, anyCost = false;
    rows.forEach(function (r) { var c = rowCost(r); if (c != null) { totalCost += c; anyCost = true; } });
    if (anyCost) items.push(['估算成本', fmtCost(totalCost)]);
    $('ud-insights').innerHTML = items.map(function (it) {
      return '<span><span class="text-muted">' + it[0] + '</span><span class="tabular-nums">' + it[1] + '</span></span>';
    }).join('');
  }

  function renderProviders(rows) {
    var per = PV.map(function (p, i) { return { i: i, req: 0, tok: 0, cost: 0, hasCost: false }; });
    rows.forEach(function (r) { var o = per[r[3]]; o.req++; o.tok += N(r[4]) + N(r[5]); var c = rowCost(r); if (c != null) { o.cost += c; o.hasCost = true; } });
    var tot = per.reduce(function (a, x) { return a + x.tok; }, 0);
    var act = per.filter(function (x) { return x.req > 0; }).sort(function (a, b) { return b.tok - a.tok; });
    if (!act.length) { $('ud-pv-stack').innerHTML = '<p class="text-muted">当前筛选下暂无数据</p>'; $('ud-pv-rows').innerHTML = ''; return; }
    $('ud-pv-stack').innerHTML = '<div class="ud-stack" role="img" aria-label="来源构成">' + act.map(function (x) {
      return '<span style="width:' + (tot ? (x.tok / tot * 100).toFixed(2) : 0) + '%;background:' + pvColor(x.i) + '"></span>';
    }).join('') + '</div>';
    $('ud-pv-rows').innerHTML = act.map(function (x) {
      return '<div class="text-small" style="display:flex;justify-content:space-between;gap:8px;padding:3px 0">' +
        '<span><span class="ud-dot" style="background:' + pvColor(x.i) + '"></span>' + pvLabel(x.i) + '<span class="ud-tag">' + pvTag(x.i) + '</span></span>' +
        '<span class="tabular-nums text-muted">' + fmtI(x.req) + ' 次 · ' + fmt(x.tok) + ' token · ' + (tot ? (x.tok / tot * 100).toFixed(1) : 0) + '%' + (costOn && x.hasCost ? ' · ' + fmtCost(x.cost) : '') + '</span></div>';
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
      var o = per[r[0]] || (per[r[0]] = { tl: TL[r[0]] || '', req: 0, inn: 0, out: 0, sub: 0, last: 0, cost: 0, hasCost: false });
      o.req++; o.inn += N(r[4]); o.out += N(r[5]); if (r[1] > o.last) o.last = r[1];
      if (r[9] === 1) o.sub++;
      var c = rowCost(r); if (c != null) { o.cost += c; o.hasCost = true; }
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

  function renderHeatmap(rows) {
    var host = $('ud-heatmap');
    var per = {};
    rows.forEach(function (r) { var k = dayKey(r[1]); var o = per[k] || (per[k] = { req: 0, tok: 0 }); o.req++; o.tok += N(r[4]) + N(r[5]); });
    var days = Object.keys(per).sort();
    if (!days.length) { host.innerHTML = '<p class="text-muted">当前筛选下暂无数据</p>'; return; }
    var start = new Date(days[0] + 'T00:00:00'), end = new Date(days[days.length - 1] + 'T00:00:00');
    var cells = [];
    for (var d = new Date(start); d <= end; d.setDate(d.getDate() + 1)) {
      var k = dayKey(d.getTime());
      cells.push({ k: k, v: per[k] ? per[k].tok : 0, req: per[k] ? per[k].req : 0 });
    }
    // 最多展示最近 26 周，避免超宽
    if (cells.length > 182) {
      cells = cells.slice(-182);
      start = new Date(cells[0].k + 'T00:00:00');
    }
    var lead = (start.getDay() + 6) % 7; // 周一为第一行
    var nz = cells.map(function (c) { return c.v; }).filter(function (v) { return v > 0; }).sort(function (a, b) { return a - b; });
    function q(p) { return nz.length ? nz[Math.min(nz.length - 1, Math.floor(nz.length * p))] : 1; }
    var q1 = q(0.25), q2 = q(0.5), q3 = q(0.75);
    var CS = 13, GAP = 3, RW = 7, L = 24, T = 16;
    var cols = Math.ceil((lead + cells.length) / RW);
    var W = L + cols * (CS + GAP) + 4, H = T + RW * (CS + GAP) + 20;
    var out = '';
    ['一', '三', '五'].forEach(function (w, i) {
      out += '<text x="' + (L - 6) + '" y="' + (T + (i * 2 + 1) * (CS + GAP) - 2) + '" text-anchor="end" font-size="10" fill="var(--muted-foreground)">' + w + '</text>';
    });
    var lastMonth = '';
    cells.forEach(function (c, i) {
      var pos = lead + i;
      var col = Math.floor(pos / RW), row = pos % RW;
      if (row === 0) {
        var mk = c.k.slice(0, 7);
        if (mk !== lastMonth) {
          lastMonth = mk;
          out += '<text x="' + (L + col * (CS + GAP)) + '" y="10" font-size="10" fill="var(--muted-foreground)">' + Number(c.k.slice(5, 7)) + '月</text>';
        }
      }
      var x = L + col * (CS + GAP), y = T + row * (CS + GAP);
      var fill = 'var(--muted)', op = '';
      if (c.v > 0) {
        fill = 'var(--viz-series-1)';
        op = c.v <= q1 ? ' fill-opacity="0.35"' : c.v <= q2 ? ' fill-opacity="0.6"' : c.v <= q3 ? ' fill-opacity="0.85"' : '';
      }
      out += '<rect x="' + x + '" y="' + y + '" width="' + CS + '" height="' + CS + '" rx="3" fill="' + fill + '"' + op + '><title>' + c.k + ' · ' + fmtI(c.req) + ' 次请求 · ' + fmt(c.v) + ' token</title></rect>';
    });
    var lg = ['少'];
    var lv = [0, q1, q2, q3, Infinity];
    for (var li = 0; li < 5; li++) {
      var lx = W - 118 + li * (CS + GAP);
      var lfill = li === 0 ? 'var(--muted)' : 'var(--viz-series-1)';
      var lop = li === 0 || li === 4 ? '' : ' fill-opacity="' + [0, 0.35, 0.6, 0.85][li] + '"';
      lg.push('<rect x="' + lx + '" y="' + (H - 14) + '" width="' + CS + '" height="' + CS + '" rx="3" fill="' + lfill + '"' + lop + '></rect>');
    }
    lg.push('<text x="' + (W - 128) + '" y="' + (H - 4) + '" text-anchor="end" font-size="10" fill="var(--muted-foreground)">少</text>');
    lg.push('<text x="' + (W - 4) + '" y="' + (H - 4) + '" text-anchor="end" font-size="10" fill="var(--muted-foreground)">多</text>');
    host.innerHTML = '<svg width="' + W + '" height="' + H + '" role="img" aria-label="活跃热力图（按天 token）"><desc>共 ' + cells.length + ' 天，' + nz.length + ' 天有用量' + (per[days[days.length - 1]] && cells.length >= 182 ? '，展示最近 26 周' : '') + '</desc>' + out + lg.join('') + '</svg>';
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
        cmp = '<div class="text-small text-muted" style="margin-top:4px">近 ' + recent.length + ' 个完整窗口均值 ' + fmt(avg) + ' token · 按当前速率本窗口预计 ' + fmt(projected) + ' token（' + (diff >= 0 ? '高于' : '低于') + '均值 ' + Math.abs(diff) + '%）</div>';
      }
      $('ud-block-now').innerHTML = '<div class="text-small text-muted">最近窗口（进行中）· 开始 ' + fullTs(active.start) + ' · 已进行 ' + (elapsedMs / 36e5).toFixed(1) + ' / 5 小时</div>' +
        '<div class="text-small" style="margin:4px 0">' + fmtI(active.req) + ' 次请求 · ' + fmt(tok) + ' token · 燃烧率 ' + fmt(rate) + ' token/小时 · 约 ' + minsLeft + ' 分钟后满 5 小时</div>' +
        '<div class="progress" role="progressbar" aria-label="窗口时间进度" aria-valuenow="' + elPct + '" aria-valuemin="0" aria-valuemax="100"><div class="progress-bar" style="width:' + elPct + '%"></div></div>' + cmp;
    } else {
      $('ud-block-now').innerHTML = '<div class="text-small text-muted">当前没有进行中的 5 小时窗口（最近一次活动 ' + (last ? fullTs(last.end) : '–') + '）。需要盯着燃烧率时，可在终端运行 <code>usage.sh live</code> 实时监控。</div>';
    }
    $('ud-blocks-body').innerHTML = blocks.slice(-12).reverse().map(function (b) {
      var hrs = ((b.end - b.start) / 36e5).toFixed(1);
      return '<tr><td class="text-nowrap">' + fullTs(b.start) + '</td><td class="text-nowrap">' + fullTs(b.end) + '</td><td class="text-end tabular-nums">' + hrs + ' h</td><td class="text-end tabular-nums">' + fmtI(b.req) + '</td><td class="text-end tabular-nums">' + fmt(b.inn) + '</td><td class="text-end tabular-nums">' + fmt(b.out) + '</td></tr>';
    }).join('');
  }

  function renderSessions(rows) {
    var keys = { 1: 'req', 2: 'inn', 3: 'out', 4: 'tot', 5: 'last', 6: 'cost' };
    var list = sessAgg(rows).sort(function (a, b) { return ((a[keys[sortS.k]] || 0) - (b[keys[sortS.k]] || 0)) * sortS.d; });
    var cols = [
      { h: '会话', k: null }, { h: '请求数', k: 1, end: 1 }, { h: '输入 token', k: 2, end: 1 },
      { h: '生成 token', k: 3, end: 1 }, { h: 'token 合计', k: 4, end: 1 },
      costOn ? { h: '估算成本', k: 6, end: 1 } : null,
      { h: '最后活动', k: 5, end: 1 }
    ].filter(Boolean);
    $('ud-sessions-head').innerHTML = '<tr>' + cols.map(function (c) {
      var arrow = sortS.k === c.k ? (sortS.d < 0 ? ' ↓' : ' ↑') : '';
      return c.k == null ? '<th>' + c.h + '</th>' : '<th class="ud-sortable' + (c.end ? ' text-end' : '') + '" data-k="' + c.k + '"' + (sortS.k === c.k ? ' aria-sort="' + (sortS.d < 0 ? 'descending' : 'ascending') + '"' : '') + '>' + c.h + arrow + '</th>';
    }).join('') + '</tr>';
    $('ud-sessions-body').innerHTML = list.length ? list.slice(0, 30).map(function (o) {
      return '<tr><td>' + sessTitle(o) + (o.sub ? '<span class="ud-tag">子代理 ×' + fmtI(o.sub) + '</span>' : '') + '</td><td class="text-end tabular-nums">' + fmtI(o.req) + '</td><td class="text-end tabular-nums">' + fmtI(o.inn) + '</td><td class="text-end tabular-nums">' + fmtI(o.out) + '</td><td class="text-end tabular-nums">' + fmtI(o.tot) + '</td>' + (costOn ? '<td class="text-end tabular-nums">' + (o.hasCost ? fmtCost(o.cost) : '–') + '</td>' : '') + '<td class="text-end text-nowrap">' + fullTs(o.last) + '</td></tr>';
    }).join('') : '<tr><td colspan="7" class="text-muted">当前筛选下暂无数据</td></tr>';
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
      { h: '时间', k: 0 }, { h: '会话', k: null }, { h: '模型', k: null }, { h: '来源', k: null }, { h: '类型', k: null },
      { h: '输入', k: 4, end: 1 }, { h: '生成', k: 5, end: 1 }, { h: '缓存读', k: 6, end: 1 }, { h: '耗时 ms', k: 7, end: 1 }, { h: '状态', k: null }
    ];
    $('ud-detail-head').innerHTML = '<tr>' + cols.map(function (c) {
      var arrow = sortD.k === c.k ? (sortD.d < 0 ? ' ↓' : ' ↑') : '';
      return c.k == null ? '<th>' + c.h + '</th>' : '<th class="ud-sortable' + (c.end ? ' text-end' : '') + '" data-k="' + c.k + '">' + c.h + arrow + '</th>';
    }).join('') + '</tr>';
    var view = list.slice(0, shown);
    $('ud-detail-body').innerHTML = view.length ? view.map(function (r) {
      return '<tr><td class="text-nowrap">' + fullTs(r[1]) + '</td><td>' + (TL[r[0]] ? esc(TL[r[0]]) : '<span class="text-muted">（无标题）</span>') + '</td><td>' + esc(MD[r[2]]) + '</td><td>' + pvLabel(r[3]) + '</td><td>' + QT[r[9]] + '</td><td class="text-end tabular-nums">' + fmtI(r[4]) + '</td><td class="text-end tabular-nums">' + fmtI(r[5]) + '</td><td class="text-end tabular-nums">' + fmtI(r[6]) + '</td><td class="text-end tabular-nums">' + fmtI(r[7]) + '</td><td>' + stHtml(r[8]) + '</td></tr>';
    }).join('') : '<tr><td colspan="10" class="text-muted">当前筛选下暂无数据</td></tr>';
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
    var list = rows.filter(function (r) { return r[8] === 1 || r[8] === 2; }).sort(function (a, b) { return b[1] - a[1]; }).slice(0, 30);
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
    renderInsights(rows);
    renderProviders(frows(true));
    renderModels(rows);
    renderTopSessions(rows);
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
  $('ud-f-pv').addEventListener('change', function () { st.p = +this.value; shown = 50; apply(); });
  $('ud-f-model').addEventListener('change', function () { st.m = +this.value; shown = 50; apply(); });
  $('ud-f-stat').addEventListener('change', function () { detailStat = +this.value; shown = 50; renderDetail(frows(false)); });
  $('ud-f-cost').addEventListener('change', function () { costOn = this.checked; renderProviders(frows(true)); renderSessions(frows(false)); renderInsights(frows(false)); });
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
  this [--session ID | --directory DIR]
                           当前会话汇总、模型/来源与最近失败/取消请求（默认按最近请求推断）
  dashboard-this <输出.html> [--session ID | --directory DIR]
                           当前会话仪表盘（会话过滤后再取最近 3000 条）
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
环境变量：ZCODE_USAGE_DB 覆盖数据库路径；ZCODE_USAGE_PRICES 覆盖价格表路径；ZCODE_USAGE_LIMIT 覆盖默认内嵌条数。
EOF
    ;;
esac
