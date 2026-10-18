# usage-detail

[简体中文](README_CN.md) | English

A [ZCode](https://zcode.z.ai) plugin for inspecting **every single model request** your client makes — row-by-row records, official plan vs. custom BYOK providers, multi-dimensional filters and an interactive dashboard.

Purely local read-only queries. **No network calls, no data leaves your machine.**

![Dashboard overview](screenshots/dashboard-overview-dark.png)

The sessions tab expands in place: context compactions, model mix, tool usage and a context-watermark curve at a glance:

![Sessions & drill-down](screenshots/dashboard-sessions-dark.png)

Daily trend stacks by provider, with a per-day table (requests / tokens / cache hits / generation speed) below — click a day to jump straight to that day's request log:

![Daily trend](screenshots/dashboard-trend-light.png)

## Features

> **Platform support**: full experience on macOS; Windows & Linux cover all core capabilities (side panel / MCP / hooks / dashboard / CLI) — the CLI needs bash (Git Bash on Windows; falls back to a node:sqlite shim when sqlite3 is unavailable) and Node ≥ 22.13 (bundled with ZCode). Notifications use per-platform native channels (osascript / WinRT toast / notify-send) and degrade silently.

- **Per-request detail**: one row per model request — time, session, model, provider, main-turn vs. subagent, input / cache-read / cache-write / output tokens, duration, TTFT, **output tok/s** (color-coded in six tiers), status, and per-row converted cost (list price, toggleable); paginated, sortable by column headers
- **Session side panel** (ZCode Desktop 3.15+): **the exact same UI as `/usage-ui`**, not a stripped-down view — six tabs, heatmap, trends, per-day table, session drill-down, model efficiency, request pagination/sorting/drill-down, dark/light following the host theme, generated on demand by a zero-dependency built-in MCP service (**full history embedded by default**; database path and row limit configurable in Settings). Hover any chart for the full breakdown (tokens + cache rate); the hourly-distribution tab switches between requests / tokens; request pagination supports direct page jumps
- **Per-turn usage card**: stats computed locally at each turn's end (zero model overhead, never enters context), pushed in real time to the panel's top banner via MCP resource subscription; optional system notification (macOS / Windows / Linux) or an in-conversation stats line (`usage.sh turnstats`, side-panel card only by default)
- **Budget / burn alerts** (zero model overhead): while the local panel is running, checked locally every minute — a system notification fires when today's converted cost reaches 80%/100% of your daily budget (once per tier per day), and also when today's tokens exceed 50% over the 7-day daily average; disable with `usage.sh alerts budget off`
- **Permission-wait reminder** (off by default): get notified when the agent waits for a permission approval — long unattended runs never miss a confirmation; enable with `usage.sh alerts permission on`
- **Waste forensics**: see the tokens burned by failed/cancelled requests at a glance — an insight card plus `usage.sh waste [days]` for a full report (fail/cancel/retry breakdown + worst-offender sessions + most-retried models)
- **Model efficiency tab**: compare models by avg tok/s, avg TTFT, fail rate, cache rate and cost per 1k tokens; session rankings carry a **0–100 health score** (weighted fail/cancel/retry, explainable formula)
- **Two-level drill-down**: click a session row (or a "most active sessions" row) to expand it — project directory, main/subagent split, compaction events, model mix **donut**, provider mix, **tool-usage donut**, event timeline (compactions / model switches) and a **context-watermark curve** with per-point hover; click a request row for its full record — token breakdown, timing, output speed, and (local panel mode) the provider-reported **raw usage JSON**
- **Current session** (thanks to [@Garfielk](https://github.com/Garfielk)): `/usage-this` summarizes the current session with per-model/per-provider grouping and recent failures; `/usage-this-ui` renders a compact panel
- **Provider separation**: automatically distinguishes `account:*` official plans (e.g. GLM Coding Plan) from custom/BYOK providers, with trends stacked by provider
- **Interactive dashboard** (`/usage-ui`): six tabs — overview / daily trend (with per-day table) / sessions / model efficiency / requests / failures. Provider, model, session and time-range filters apply globally; **clicking a session or model name in the detail table jumps to that session's/model's log**; requests paginate at 50 per page with direct page jumps; dark/light follows ZCode. **Full history embedded by default**; `/usage-ui <rows>` limits to 1–20000
- **Cache-rate end to end**: hit rate and cache volume (read+write) in the insights; provider mix, model mix, session ranking and request rows all carry cache rates
- **Hover details**: heatmap, trend and hourly charts show the full usage breakdown on hover
- **Insight metrics**: active days, current/longest streak, peak day, cache hit rate, cache volume, todo completion, retries/cancellations, avg duration, main/subagent split, top-tools **donut**, peak hours (requests/tokens switchable), data volume checkup
- **Activity heatmap**: GitHub-contribution style, tokens per day in quartiles; daily / weekly / month-calendar granularity
- **Health card**: avg TTFT, generation speed, error rate, peak context watermark, tool calls and total time — one row of checkup metrics
- **Daily table + monthly summary**: below the trend chart; click a day to load that day's request log
- **Multi-vendor quota aggregation (optional)**: the overview quota card and the `usage_quota` MCP tool aggregate vendor usage — GLM keyless (parses client-log observations); DeepSeek (balance), Kimi (5-hour/weekly windows), OpenRouter (credits), MiniMax (Token Plan) activate once you store their API keys in Settings. Keys are sent only to the corresponding vendor's official domain for read-only queries, stored in `~/.zcode/usage-vendors.json` (mode 0600), never logged or exported
- **Converted cost (list price, CNY)**: GLM 5.3 models ship with z.ai's official list price built in; everything else syncs from [models.dev](https://models.dev) with a USD→CNY rate (`ZCODE_USAGE_USD_CNY` overridable). Custom entries and official anchors are never overwritten by sync. Subscription-plan requests are not actually billed per token — the amount expresses the list-price value of equivalent API usage. The dashboard has a "converted cost" toggle and a "sync prices" button
- **Time-of-use pricing**: price each request by its local time tier — add a `tariff` field to the price table:

  ```json
  { "currency": "CNY",
    "models": { "deepseek-flash": { "in": 2, "out": 8, "cache": 0.04,
      "tariff": { "tz": 8, "weekend": 0.5,
        "tiers": [
          { "hours": [[9, 12], [14, 18]], "mult": 1.0, "name": "高峰" },
          { "hours": [[0, 24]], "mult": 0.5, "name": "空闲" } ] } } } }
  ```

  `weekend` is an optional flat weekend multiplier; `holidays` / `workdays` accept holiday and make-up-workday lists (`"YYYY-MM-DD"`, in `tz`). **The official DeepSeek peak/off-peak list price is built in** (deepseek-flash / deepseek-v4-flash / deepseek-v4-pro; verified against the official pricing page 2026-10: weekdays 9:00–12:00 & 14:00–18:00 peak, weekends and holidays off-peak) together with the **2026 State Council holiday schedule** — rerun `prices sync` to refresh. The GLM Coding Plan credit off-peak (14:00–18:00 at 1×, otherwise 0.5×) shows live on the GLM quota card. Without `tariff`, base prices apply unchanged.
- **Plan quota query** (`quota`, optional CLI): GLM remaining quota varies by account/plan type — the command prefers keyless parsing of client-log observations; for the monitoring API write `~/.zcode/usage-quota-token.json` (`{"token":"YOUR_KEY","base":"https://open.bigmodel.cn"}`)
- **Local resident panel** (`serve`): one command starts a read-only web service on this machine — data loads once, burn rate polls every 5 seconds, full drill-downs, never touches your session context
- **Export**: `export csv` / `export json` for all records (CSV follows RFC 4180)
- **Zero dependencies**: only `bash` + `sqlite3` (+ Node, bundled with ZCode)

Data comes from ZCode's local client database `~/.zcode/cli/db/db.sqlite` (read-only).

## Installation

### Option 1: add the GitHub marketplace source (recommended)

1. Open ZCode's **Plugin Marketplace**
2. Click **Add → Add marketplace** and paste this repository:

   ```
   https://github.com/axdlee/zcode-usage-detail
   ```

3. Switch to the **Personal** tab, find **Usage Detail (用量明细)** and click **Install**

### Option 2: local directory

```bash
git clone https://github.com/axdlee/zcode-usage-detail.git
```

Then **Plugin Marketplace → Add → Add marketplace** with the cloned folder (the level containing `marketplace.json`), and install as above.

### Option 3: one-shot AI install

Paste this to ZCode (or any coding agent) and it will handle the rest:

```text
Please install the zcode-usage-detail plugin from GitHub:

1. Run git clone https://github.com/axdlee/zcode-usage-detail.git ~/.zcode/plugins/zcode-usage-detail (git -C pull if it exists)
2. Validate the plugin manifest: node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs plugins validate ~/.zcode/plugins/zcode-usage-detail/usage-detail (skip if the CLI is missing)
3. After reading the plugin README's install section, tell me the manual steps: paste ~/.zcode/plugins/zcode-usage-detail into "Plugin Marketplace → Add → Add marketplace", then install "Usage Detail" under the Personal tab
4. Give me an acceptance check: after installing, start a new task and run /usage-ui — the embedded usage dashboard should appear
```

## Usage

After installing, **start a new task**:

| Input | Effect |
|---|---|
| `/usage-ui` | Generate the interactive dashboard, rendered inline in the session |
| `/usage-ui 8000` | Same, limited to the latest 8000 rows |
| `/usage-this` | Infer the current session: identity, usage summary, per-model/provider, recent failures |
| `/usage-this-ui` | Compact current-session panel: four usage stats, collapsible model mix and request detail |
| `/usage-this --session sess_xxx` | Explicit session (UI commands accept it too) |
| `/usage-this --directory /absolute/project/path` | Pick the latest session inside a project directory (UI commands accept it too) |
| `/usage` | Text overview (all-time + today) |
| `/usage blocks` | 5-hour window usage (CLI approximation; the UI module was removed — official quota lives in Usage Stats → Coding Plan) |
| `/usage recent 50` | Latest 50 request rows |
| `/usage providers` | Aggregate by provider (official plan / custom BYOK) |
| `/usage months` | Monthly summary |
| `/usage projects 10` | Top 10 projects by directory |
| `/usage tools` | Tool-call statistics |
| `/usage cost` | Converted cost per model (official list price CNY, customizable) |
| `/usage-today` | Today: request detail + converted amount + failures |
| `/usage prices sync` | Sync latest official prices from models.dev |
| `/usage quota` | Plan quota remaining (keyless client-log parsing; optional API key) |
| `/usage doctor` | Environment checkup: database/tables/prices/quota source/dependencies ("stats disappeared?" run this first) |
| `/usage export csv` | Export all records as CSV |
| `/usage day 2026-10-14` | One day's request detail |
| `/usage sessions 10` | Top 10 sessions by usage |
| `/usage errors` | Recent failed/cancelled requests |
| "which session burns the most tokens?" | Natural language works too — it routes to the right query |

### Current-session detection

ZCode's command environment does not yet expose a reliable session ID, so the plugin uses the **`session_id` of the latest model request** in the local database, fixed for the duration of one run. Parallel windows may land on another session — verify the session title, ID and latest-request time in the output; when ambiguous pass `--session ID`, or narrow candidates with `--directory "absolute project path"` (mutually exclusive). Directory matching is exact; use a project directory from the report.

Only the selected `session_id` is counted; sub-sessions under other IDs are not merged. The text report counts all statuses; generation = output + thinking; failures and cancellations are counted separately and in-flight requests fall into "other". In-flight requests may not have full tokens yet — rerun to refresh.

The session UI shows title, latest request and four usage stats on first paint; session ID, project directory and creation time expand on demand. Model mix and request detail start collapsed; failures/cancellations get a direct filter link. Session ranking, heatmap and daily trends live in the full `/usage-ui`.

The session-filtered UI embeds all of that session's requests by default; `ZCODE_USAGE_LIMIT` clamps to 1–20000 (-1 = all). Coverage is annotated when limited — cards and detail reflect loaded rows only. Results are a local snapshot at generation time and do not represent server-side plan quota.

Run the scripts directly:

```bash
bash usage-detail/scripts/usage.sh this
bash usage-detail/scripts/usage.sh this --session sess_xxx
bash usage-detail/scripts/usage.sh dashboard-this /tmp/usage-this.html --directory "/path/to/project"
```

### Opening the session side panel

1. After installing or updating, **restart ZCode** (the host loads plugin manifests at launch)
2. Open any task and click **"+"** in the right-hand panel area
3. Choose **"Usage (用量)"** — the panel docks as a side tab and refreshes with the session
4. **"Full panel ↗"** at its top starts the local resident service and opens the complete dashboard (paginated detail, heatmap, 5-hour windows, session drill-down — everything)

If "Usage" is missing: make sure the plugin is enabled, ZCode is 3.15+ and has been restarted; otherwise run `/usage doctor`.

### Per-turn usage stats (live card + optional notification/stats line)

At each turn's end an async Stop hook computes the stats locally (pure node + SQLite, **zero model overhead, never enters context**) and pushes them to any open side panel via the host's MCP resource subscription (`resources/subscribe` → `notifications/resources/updated`) — the "⏱ This turn" banner refreshes speed/TTFT/cache/requests/duration live. Numbers for humans, never through the model.

`usage.sh turnstats <mode>` controls the extra outlets beyond the panel:

- **notify (recommended, zero overhead)**: see it even with the panel closed — a system notification after each turn (macOS osascript / Windows WinRT toast / Linux notify-send; all local, silent when unavailable)
- **inject (in-conversation line)**: appends `> 本轮用量：⚡ 82 tok/s · …` to each tool-using reply. The stats script does zero model inference, but **text entering the conversation must go through the model** (ZCode hooks cannot append to replies, and injecting context from the Stop hook forces an extra full model call — measurably more expensive). Cost: ~0.15k tokens/turn for the injected instruction (stays in context) + ~0.1k tool call + ~0.05k output — under 0.1% of a million-token context, ~1% on short sessions
- **off (default)**: side-panel live card and browser-panel polling only (local panel pulls `/api/turn` every 15s)

notify/inject need a reopened session to take effect (hook config snapshots per session); the side-panel card works as soon as the panel opens.

### Converted cost (official list price CNY, customizable)

Price resolution order: `ZCODE_USAGE_PRICES` env → `~/.zcode/usage-prices.json` (your file) → built-in prices. GLM 5.3 models ship with z.ai's official list price (CNY per million tokens, matching the official pricing page); the rest bundle from models.dev converted at USD→CNY (7.2, `ZCODE_USAGE_USD_CNY` overridable). Works out of the box.

- **Daily auto-sync**: when generating a dashboard or starting the panel, prices older than one day sync from models.dev automatically (`ZCODE_USAGE_NO_AUTOSYNC=1` to disable)
- `usage.sh prices show` prints the effective table; `usage.sh prices sync` forces a full sync (keeps custom entries; needs node + curl)
- The dashboard's "Sync Prices" button: in-session it asks the agent to sync and re-render; in the local panel it syncs and refreshes directly
- **"Prices / Budget" panel** (local panel): search and edit any model's input/output/cache price — saving reconverts the full history immediately; add or remove entries
- **Local converted budget**: set daily/monthly budgets in the price panel; the overview shows a "today / daily budget" progress bar that turns red past 100%
- **Unpriced hint**: converted costs show "unpriced N%" — tokens of unpriced models are excluded from totals, stated explicitly instead of silently zeroed
- Custom: edit `~/.zcode/usage-prices.json` to add models or change currency:

  ```json
  { "currency": "USD",
    "models": { "glm-5.3": {"in": 1.4, "out": 4.4, "cache": 0.26},
                 "my-private-model": {"in": 1, "out": 3, "cache": 0.1} } }
  ```

With prices configured, `/usage cost` breaks cost down per model and the dashboard grows a "converted cost" toggle adding cost columns to session ranking and provider mix. Note: requests inside a subscription plan (e.g. GLM Coding Plan) are not actually billed per token — treat estimates as BYOK metering or a mental reference.

### Live burn-rate monitoring

- Dashboard "5-hour window" tab: remaining % + reset time + burn rate (tokens/hour) + comparison against the last 3 complete windows + full-window projection + **remaining-requests estimate** (from the average of the last 3 complete windows)
- **Local resident panel**: `usage.sh serve` (default port 7741; `serve 8080` to change), opens the browser automatically. Data loads once; burn rate and today's usage poll lightly every 5 seconds (queries only the last 5h, indexed, negligible overhead). Listens on 127.0.0.1 only, read-only, writes nothing
- Terminal monitor (claude-monitor style): `usage.sh live [seconds]`, 3s refresh by default, Ctrl-C to exit

### Dashboard preview

Daily trends stack by provider, with a per-day table below — click a day to load that day's log:

![Daily trend](screenshots/dashboard-trend-light.png)

Request detail supports status filtering and header sorting:

![Request detail](screenshots/dashboard-detail-light.png)

## Data & privacy

- The data source is the local SQLite written by the ZCode client (`model_usage` in `~/.zcode/cli/db/db.sqlite`); the plugin only ever queries it **read-only**
- No network, no uploads, no database writes; dashboard data is embedded at generation time and exists only in an HTML file on your own machine
- The dashboard embeds the latest 3000 requests by default; `/usage-ui <rows>` adjusts (1–20000; beyond ~8000 rows may exceed inline rendering limits — use `export json` for full history)
- Token semantics: the input column includes cache hits (cache reads listed separately); generation = output + thinking; cost = uncached-input × in + cache-hit × cache + generation × out (cache never billed twice; time-of-use models price each request at its own moment)
- **Plan quota remaining** (5-hour pool / weekly allowance) is metered server-side and not in the local database: `/usage quota` prefers keyless parsing of client-log observations; depending on account/plan some observations may be empty — defer to ZCode's **Usage Stats → Coding Plan**, or configure API credentials for the monitoring endpoint
- **Multi-vendor quotas (all optional, off by default)**: only after you store a vendor's API key in plugin settings does the plugin query that vendor's **official domain** read-only — DeepSeek `api.deepseek.com`, Kimi `api.kimi.com`, OpenRouter `openrouter.ai`, MiniMax `api.minimaxi.com`; keys live in `~/.zcode/usage-vendors.json` (mode 0600) and never appear in logs or exports. GLM quota queries send no credentials at all (local client-log parsing). No keys, no outbound requests

## Known limitations

- Counts only **this machine, this account's** requests inside ZCode
- The local schema may evolve with ZCode versions (verified through 0.16.x)
- The UI renders via ZCode Desktop's Gen UI — desktop app required
- 5-hour windows and costs are **local approximations**; server-side plan quota is authoritative at Usage Stats → Coding Plan

## Development & testing

Run session-filter, aggregation, empty-data, parameter-escaping and dashboard regression tests (Python 3 for development only; the plugin itself still needs just bash + sqlite3):

```bash
python3 -m unittest discover -s tests -v
bash -n usage-detail/scripts/usage.sh
```

## Acknowledgments

Design draws on these excellent peers: [ccusage](https://github.com/ccusage/ccusage) (5-hour windows / cost reports), [Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor) (burn rate & depletion projection) and the DeepSeek Harness community usage-plugin family (activity heatmap, cache hit rate, streaks, exports).

## License

[MIT](LICENSE)
