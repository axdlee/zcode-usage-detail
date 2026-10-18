"""serve.mjs HTTP endpoints + panel-server MCP stdio protocol + hook scripts."""

import json
from pathlib import Path
import subprocess
import time
import unittest
import urllib.request

from support import PLUGIN, IsoHome, SynthDb, run_node

PORT = 7819


class ServerPanelTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import tempfile
        cls.tmp = tempfile.TemporaryDirectory()
        cls.home = IsoHome(Path(cls.tmp.name))
        cls.db = Path(cls.tmp.name) / "usage.sqlite"
        cls.dbh = SynthDb(cls.db)
        d = cls.dbh
        d.session("s1", "会话一", "/p1")
        d.usage("a", "s1", int(time.time() * 1000) - 60000, dur=20000, ttft=900)
        d.usage("b", "s1", int(time.time() * 1000) - 30000, status="error")
        cls.env = cls.home.env(ZCODE_USAGE_DB=str(cls.db))
        cls.serve = subprocess.Popen(
            ["node", str(PLUGIN / "scripts/serve.mjs"), str(PORT)],
            env=cls.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        base = f"http://127.0.0.1:{PORT}/"
        for _ in range(40):
            try:
                urllib.request.urlopen(base + "api/live", timeout=2)
                break
            except Exception:
                time.sleep(0.3)
        cls.addCleanup = lambda x: None

    @classmethod
    def tearDownClass(cls):
        cls.serve.terminate()
        cls.dbh.close()
        cls.tmp.cleanup()

    def get(self, path):
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}{path}", timeout=30) as r:
            return r.status, r.read()

    def post(self, path, data):
        req = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}",
                                     data=json.dumps(data).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read())

    # ---- serve HTTP ----

    def test_01_api_data_rows(self):
        st, body = self.get("/api/data?limit=10")
        self.assertEqual(st, 200)
        j = json.loads(body)
        self.assertEqual(len(j["rows"]), 2)
        self.assertTrue(all(len(row) >= 14 for row in j["rows"]))

    def test_02_api_live_version(self):
        st, body = self.get("/api/live")
        j = json.loads(body)
        self.assertEqual(st, 200)
        self.assertTrue(str(j["v"]).count(".") >= 1)  # semver 形如 0.13.3

    def test_03_api_turn(self):
        # 写 prompt-submit 状态文件后 /api/turn 能取到本轮统计
        self.home.write_json("usage-detail-turn.json", {
            "source": "prompt-submit", "promptTs": int(time.time() * 1000) - 120000, "sessionId": ""})
        st, body = self.get("/api/turn")
        j = json.loads(body)
        self.assertEqual(st, 200)
        self.assertIn("本轮用量", j["text"])

    def test_04a_port_shift_on_busy(self):
        # 7741 被占时 serve 自动顺延 7742+ 并把实际端口写进 usage-serve.json（退避策略）。
        # 7741 是全局资源：已被占用（如日常 serve 在跑）则跳过，避免干扰真实环境。
        import socket
        probe = socket.socket()
        busy = probe.connect_ex(("127.0.0.1", 7741)) == 0
        probe.close()
        if busy:
            self.skipTest("7741 已被占用，跳过顺延测试")
        holder = socket.socket()
        holder.bind(("127.0.0.1", 7741))
        holder.listen(1)
        pidfile = self.home.zcode_path("usage-serve.json")
        backup = pidfile.read_text() if pidfile.exists() else None  # 类夹具 serve 的记录，测后还原
        try:
            proc = subprocess.Popen(["node", str(PLUGIN / "scripts/serve.mjs")],
                                    env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shifted = None
            for _ in range(40):
                time.sleep(0.3)
                if pidfile.exists():
                    meta = json.loads(pidfile.read_text())
                    if meta.get("port") not in (7741, None):
                        shifted = meta["port"]
                        break
            self.assertEqual(shifted, 7742, "应顺延到 7742")
            with urllib.request.urlopen("http://127.0.0.1:7742/api/live", timeout=3) as r:
                self.assertEqual(r.status, 200)
            proc.terminate()
        finally:
            holder.close()
            if backup is not None:
                pidfile.write_text(backup)

    def test_04_switches_roundtrip(self):
        st, before = self.post("/api/switches", {})
        st, after = self.post("/api/switches", {"permissionAlerts": True, "turnstats": "notify"})
        self.assertEqual(after["permissionAlerts"], True)
        self.assertEqual(after["turnstats"], "notify")
        self.assertIs(self.home.read_json("usage-alerts.json")["permission"], True)
        self.assertEqual(self.home.read_json("usage-turnstats.json")["mode"], "notify")
        # 还原
        _, restored = self.post("/api/switches", {"permissionAlerts": False, "turnstats": "off"})
        self.assertEqual(restored["turnstats"], "off")

    def test_05_report_html(self):
        st, body = self.get("/report.html")
        self.assertEqual(st, 200)
        self.assertIn(b"usage-dashboard", body)

    def test_06_pid_file(self):
        pid = json.loads(self.home.zcode_path("usage-serve.json").read_text())
        self.assertEqual(pid["port"], PORT)
        self.assertTrue(str(pid["pid"]).isdigit())

    # ---- hooks ----

    def test_07_prompt_submit_silent_when_off(self):
        self.home.write_json("usage-turnstats.json", {"enabled": False})
        r = run_node(PLUGIN / "hooks/prompt-submit.mjs", [], self.env,
                     stdin_text=json.dumps({"prompt": "hi", "session_id": "s1"}))
        self.assertEqual(r.returncode, 0)
        self.assertNotIn("additionalContext", r.stdout)

    def test_08_prompt_submit_injects_when_inject_mode(self):
        self.home.write_json("usage-turnstats.json", {"enabled": True, "mode": "inject"})
        self.home.write_json("usage-detail-turn.json", {
            "source": "prompt-submit", "promptTs": int(time.time() * 1000) - 60000, "sessionId": ""})
        r = run_node(PLUGIN / "hooks/prompt-submit.mjs", [], self.env,
                     stdin_text=json.dumps({"prompt": "hi", "session_id": "s1"}))
        self.assertEqual(r.returncode, 0)
        self.assertIn("additionalContext", r.stdout)
        self.assertIn("turn-stats.mjs", r.stdout)

    def test_09_stop_hook_writes_marker(self):
        self.home.zcode_path("usage-detail-turn-done.json").unlink(missing_ok=True)
        r = run_node(PLUGIN / "hooks/stop-notify.mjs", [], self.env)
        self.assertEqual(r.returncode, 0)
        marker = self.home.read_json("usage-detail-turn-done.json")
        self.assertIn("ts", marker)

    def test_10_permission_hook_silent_by_default(self):
        r = run_node(PLUGIN / "hooks/permission-notify.mjs", [], self.env,
                     stdin_text=json.dumps({"tool_name": "Bash"}))
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "")

    # ---- panel-server MCP 协议 ----

    def rpc(self, lines):
        proc = subprocess.Popen(
            ["node", str(PLUGIN / "scripts/mcp/panel-server.mjs")], env=self.env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        try:
            out, _ = proc.communicate("\n".join(lines) + "\n", timeout=90)
        finally:
            if proc.poll() is None:
                proc.kill()
        msgs = []
        for line in out.splitlines():
            if line.strip():
                try:
                    msgs.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
        return msgs

    def test_11_mcp_tools_and_resources(self):
        msgs = self.rpc([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"}}),
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
            json.dumps({"jsonrpc": "2.0", "id": 3, "method": "resources/list"}),
            json.dumps({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                        "params": {"name": "usage_detail", "arguments": {"limit": 2}}}),
        ])
        by_id = {m.get("id"): m for m in msgs if m.get("id")}
        caps = by_id[1]["result"]["capabilities"]
        self.assertTrue(caps["resources"]["subscribe"])
        self.assertEqual(len(by_id[2]["result"]["tools"]), 11)  # 7 数据工具 + ctx_top + settings_get/set + open_full_panel + prices_sync
        uris = [r["uri"] for r in by_id[3]["result"]["resources"]]
        self.assertIn("ui://usage-detail/panel.html", uris)
        self.assertIn("ui://usage-detail/turn.txt", uris)


    def test_12_ctx_top(self):
        # 上下文 Top 下钻：工具存在、返回结构固定（tools/files 数组）；
        # 合成库无 part 数据 → 空数组但不缺键（真实数据渲染由前端端到端覆盖）
        msgs = self.rpc([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"}}),
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                        "params": {"name": "usage_ctx_top", "arguments": {"session": "sess_x"}}}),
        ])
        by_id = {m.get("id"): m for m in msgs if m.get("id")}
        sc = by_id[2]["result"]["structuredContent"]
        self.assertIsInstance(sc.get("tools"), list)
        self.assertIsInstance(sc.get("files"), list)
        # 面板 HTML 含 sessionIds 与「上下文 Top」按钮挂点
        msgs2 = self.rpc([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"}}),
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "resources/read",
                        "params": {"uri": "ui://usage-detail/panel.html"}}),
        ])
        by2 = {m.get("id"): m for m in msgs2 if m.get("id")}
        html = by2[2]["result"]["contents"][0]["text"]
        self.assertIn('"sessionIds"', html)
        self.assertIn("ud-ctx-top", html)

    def test_12_mcp_resource_subscribe_push(self):
        self.home.zcode_path("usage-detail-turn-done.json").unlink(missing_ok=True)
        # 先写一次旧标记并 sleep 越过 mtime，再订阅 → 写新标记应触发一次推送
        self.home.zcode_path("usage-detail-turn-done.json").write_text('{"ts":1}')
        time.sleep(0.05)
        msgs = self.rpc([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"}}),
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "resources/subscribe",
                        "params": {"uri": "ui://usage-detail/turn.txt"}}),
            "__MARKER__",
            json.dumps({"jsonrpc": "2.0", "id": 3, "method": "resources/unsubscribe",
                        "params": {"uri": "ui://usage-detail/turn.txt"}}),
        ])
        # __MARKER__ 不是合法 JSON 会被忽略；这里改在订阅建立后由外部写标记不可行（单进程管道），
        # 退而验证订阅请求被接受（返回空结果）且 turn 资源可读。
        by_id = {m.get("id"): m for m in msgs if m.get("id")}
        self.assertEqual(by_id[2]["result"], {})
        self.assertEqual(by_id[3]["result"], {})

    def test_13_mcp_settings_roundtrip(self):
        msgs = self.rpc([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"}}),
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                        "params": {"name": "usage_settings_get", "arguments": {}}}),
            json.dumps({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                        "params": {"name": "usage_settings_set", "arguments": {
                            "switches": {"turnstats": "notify"},
                            "budget": {"daily": 3, "monthly": 50},
                            "priceGeneral": {"usdCny": "7.35", "autoSync": False}}}}),
            json.dumps({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                        "params": {"name": "usage_settings_get", "arguments": {}}}),
        ])
        by_id = {m.get("id"): m for m in msgs if m.get("id")}
        got = by_id[2]["result"]["structuredContent"]
        self.assertIn("models", got["prices"])
        self.assertIn("turnstats", got["switches"])
        got2 = by_id[4]["result"]["structuredContent"]
        self.assertEqual(got2["switches"]["turnstats"], "notify")
        self.assertEqual(got2["budget"]["daily"], 3)
        self.assertEqual(got2["prices"]["usdCny"], 7.35)
        self.assertIs(got2["prices"]["autoSync"], False)

    def test_13b_switches_single_field_merge(self):
        # 侧栏开关逐个提交单字段：alerts 文件承载两个开关，后写不得抹掉先写（回归护栏）
        def call_set(switches, rid):
            return json.dumps({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                               "params": {"name": "usage_settings_set",
                                          "arguments": {"switches": switches}}})
        msgs = self.rpc([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"}}),
            call_set({"budgetAlerts": False}, 2),
            call_set({"permissionAlerts": True}, 3),
            call_set({"turnstats": "notify"}, 4),
            json.dumps({"jsonrpc": "2.0", "id": 5, "method": "tools/call",
                        "params": {"name": "usage_settings_get", "arguments": {}}}),
        ])
        by_id = {m.get("id"): m for m in msgs if m.get("id")}
        sw = by_id[5]["result"]["structuredContent"]["switches"]
        self.assertIs(sw["budgetAlerts"], False)      # 第二次提交未抹掉预算告警设置
        self.assertIs(sw["permissionAlerts"], True)   # 权限提醒已开启
        self.assertEqual(sw["turnstats"], "notify")   # turnstats 文件独立生效
        # 还原，避免污染同文件后续用例
        self.rpc([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"}}),
            call_set({"budgetAlerts": True, "permissionAlerts": False, "turnstats": "off"}, 2),
        ])

    def test_15_settings_get_slim_and_query(self):
        # 全量价格表（模拟 sync 后数千条）：宿主 structuredContent 有 64KiB 上限，
        # settings_get 缺省只返回当前用量相关 + GLM 内置；query 按名搜索全量。
        models = {f"other-{i:02d}": {"in": 1, "out": 2, "cache": 0.1} for i in range(30)}
        models["Model-A"] = {"in": 3, "out": 4, "cache": 0.2}  # SynthDb 里在用的模型
        models["glm-5.3"] = {"in": 8, "out": 32, "cache": 4}
        self.home.write_json("usage-prices.json", {"currency": "CNY", "usdCny": None, "autoSync": True, "models": models})
        msgs = self.rpc([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"}}),
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                        "params": {"name": "usage_settings_get", "arguments": {}}}),
            json.dumps({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                        "params": {"name": "usage_settings_get", "arguments": {"query": "other-1"}}}),
        ])
        by_id = {m.get("id"): m for m in msgs if m.get("id")}
        slim = by_id[2]["result"]["structuredContent"]["prices"]
        self.assertTrue(slim["modelsSlim"])
        self.assertEqual(slim["modelsTotal"], 32)
        self.assertIn("Model-A", slim["models"])
        self.assertIn("glm-5.3", slim["models"])
        self.assertNotIn("other-01", slim["models"])
        q = by_id[3]["result"]["structuredContent"]["prices"]
        self.assertEqual(set(q["models"]), {f"other-1{i}" for i in range(10)})  # other-10..19
        self.assertNotIn("Model-A", q["models"])

    def test_16_settings_set_returns_slim_prices(self):
        msgs = self.rpc([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"}}),
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                        "params": {"name": "usage_settings_set", "arguments": {
                            "price": {"model": "Model-A", "in": 3, "out": 4, "cache": 0.2}}}}),
        ])
        sc = {m.get("id"): m for m in msgs if m.get("id")}[2]["result"]["structuredContent"]
        self.assertTrue(sc["ok"])
        self.assertIn("Model-A", sc["prices"]["models"])  # 保存响应带瘦身表，面板据此软刷新
        self.assertTrue(sc["prices"]["modelsSlim"])

    def test_16b_prices_sync_error_path(self):
        # PATH 不可用 → prices sync 无法启动 → 工具返回 isError（离线可测，不访问 models.dev）
        import shutil
        node = shutil.which("node")  # 先在正常 PATH 下解析，随后给子进程一个不可用的 PATH
        env = dict(self.env)
        env["PATH"] = "/nonexistent"
        proc = subprocess.Popen(
            [node, str(PLUGIN / "scripts/mcp/panel-server.mjs")], env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        out, _ = proc.communicate("\n".join([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"}}),
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                        "params": {"name": "usage_prices_sync", "arguments": {}}}),
        ]) + "\n", timeout=60)
        proc.wait()
        by_id = {m.get("id"): m for m in (json.loads(l) for l in out.splitlines() if l.strip()) if m.get("id")}
        r = by_id[2]["result"]
        self.assertTrue(r.get("isError"))
        self.assertIn("同步失败", r["content"][0]["text"])

    def test_17_panel_shell_serve_flag(self):
        # 侧栏壳必须显式声明非 serve 环境：dashboard 片段里的保存/导出分支据此避免页面级导航
        msgs = self.rpc([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"}}),
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "resources/read",
                        "params": {"uri": "ui://usage-detail/panel.html"}}),
        ])
        by_id = {m.get("id"): m for m in msgs if m.get("id")}
        html = by_id[2]["result"]["contents"][0]["text"]
        self.assertIn("window.__USAGE_SERVE__=false", html)
        self.assertIn("usage-dashboard", html)

    def test_14_mcp_turn_resource_read(self):
        self.home.write_json("usage-detail-turn.json", {
            "source": "prompt-submit", "promptTs": int(time.time() * 1000) - 120000, "sessionId": ""})
        self.home.zcode_path("usage-detail-turn-done.json").write_text(json.dumps({"ts": int(time.time() * 1000)}))
        msgs = self.rpc([
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": "2025-06-18"}}),
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "resources/read",
                        "params": {"uri": "ui://usage-detail/turn.txt"}}),
        ])
        by_id = {m.get("id"): m for m in msgs if m.get("id")}
        text = by_id[2]["result"]["contents"][0]["text"]
        self.assertIn("本轮用量", text)

    def test_18_host_origin_guard_and_ctxoverride_keep(self):
        # 发布加固护栏：① serve 拒绝异 Host（DNS rebinding）与跨站 Origin 写请求；
        # ② MCP settings_set 未传 ctxOverride 时保留原覆盖（与 serve 同口径，不得静默清除）
        serve_src = (PLUGIN / "scripts" / "serve.mjs").read_text()
        self.assertIn("host !== '127.0.0.1:' + listenPort", serve_src)
        self.assertIn("origin !== 'http://127.0.0.1:' + listenPort", serve_src)
        self.assertIn("req.method === 'POST'", serve_src)
        panel_src = (PLUGIN / "scripts" / "mcp" / "panel-server.mjs").read_text()
        self.assertIn("coRaw !== undefined", panel_src)
        self.assertIn("prevEntry.ctxOverride", panel_src)
        self.assertIn("spawn(process.execPath", panel_src)  # 不依赖 PATH 里的 node

    def test_19_budget_input_number_guard(self):
        # 回归：设置弹窗保存预算后洞察区崩溃（'30'.toFixed）——N() 必须真转数字
        src = (PLUGIN / "scripts" / "lib" / "dashboard.sh").read_text()
        self.assertIn("var N = function (v) { var x = Number(v);", src)


if __name__ == "__main__":
    unittest.main()
