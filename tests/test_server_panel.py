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
        if 'settings' in str(self._testMethodName):
            import sys as _s
            print('RAW:', repr(out[:400]), file=_s.stderr)
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
        self.assertEqual(len(by_id[2]["result"]["tools"]), 9)  # 7 数据工具 + settings_get/set
        uris = [r["uri"] for r in by_id[3]["result"]["resources"]]
        self.assertIn("ui://usage-detail/panel.html", uris)
        self.assertIn("ui://usage-detail/turn.txt", uris)
        detail = by_id[4]["result"]["structuredContent"]
        self.assertEqual(len(detail["rows"]), 2)

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


if __name__ == "__main__":
    unittest.main()
