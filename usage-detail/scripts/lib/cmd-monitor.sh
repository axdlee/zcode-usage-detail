# 实时监控与本地服务子命令（由入口 usage.sh source）

# 终端实时燃烧率监控
cmd_live() {
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
}

# 官方套餐配额（quota.mjs）
cmd_quota() {
    # 官方配额：5 小时/周/MCP 池用量百分比（凭据解析见 quota.mjs）
    command -v node >/dev/null 2>&1 || { echo "quota 需要 node" >&2; exit 1; }
    exec node "$SCRIPT_DIR/quota.mjs"
}

# 本地常驻面板（serve.mjs）
cmd_serve() {
    # 本地常驻面板：浏览器打开，自动轮询燃烧率（只监听 127.0.0.1，只读）
    command -v node >/dev/null 2>&1 || { echo "serve 需要 node" >&2; exit 1; }
    port=$(num_arg 7741 "${2:-}")
    exec node "$SCRIPT_DIR/serve.mjs" "$port"
}


# 每轮统计行开关（写 ~/.zcode/usage-turnstats.json；hook 每次提交时读取）
cmd_turnstats() {
    local f="$HOME/.zcode/usage-turnstats.json"
    case "${2:-status}" in
      on)
        mkdir -p "$(dirname "$f")"
        echo '{"enabled":true}' > "$f"
        echo "已开启：每轮回复末尾附统计行。"
        echo "开销提示：统计行必须经由模型输出——每轮注入指令约 0.5k token（持续保留在上下文）+ 一次工具调用（结果约 0.1k）+ 统计行输出约 0.05k；"
        echo "相对百万级上下文占比 <0.1%，短会话约 1-2%。关闭：usage.sh turnstats off"
        ;;
      off)
        echo '{"enabled":false}' > "$f"
        echo "已关闭：不再注入统计指令（侧栏面板的请求明细仍可查看每轮速率/首字/缓存率）。"
        ;;
      status)
        if [[ -f "$f" ]] && grep -q '"enabled"[: ]*true' "$f" 2>/dev/null; then
          echo "当前：开启（每轮约增加 0.5-1k token 模型开销；usage.sh turnstats off 关闭）"
        else
          echo "当前：关闭（默认）。开启：usage.sh turnstats on"
        fi
        ;;
      *)
        echo "用法：usage.sh turnstats [on|off|status]" >&2
        exit 1
        ;;
    esac
}
