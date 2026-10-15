"""Exercise the shipped bash/SQLite queries against synthetic databases."""

import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "usage-detail/scripts/usage.sh"


class UsageThisTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.db = self.root / "usage.sqlite"
        self.conn = sqlite3.connect(self.db)
        self.addCleanup(self.conn.close)
        self.conn.executescript("""
            CREATE TABLE session (
                id TEXT PRIMARY KEY, title TEXT, directory TEXT,
                time_created INTEGER, time_updated INTEGER
            );
            CREATE TABLE model_usage (
                id TEXT PRIMARY KEY, session_id TEXT, started_at INTEGER,
                model_id TEXT, provider_id TEXT, query_source TEXT,
                input_tokens INTEGER, output_tokens INTEGER,
                reasoning_tokens INTEGER, cache_read_input_tokens INTEGER,
                cache_creation_input_tokens INTEGER, computed_total_tokens INTEGER,
                duration_ms INTEGER, time_to_first_token_ms INTEGER,
                status TEXT, error_code TEXT, error_message TEXT,
                retry_count INTEGER DEFAULT 0, cancelled_by_user INTEGER DEFAULT 0
            );
            CREATE TABLE tool_usage (
                session_id TEXT, tool_name TEXT, status TEXT, duration_ms INTEGER
            );
            CREATE TABLE todo (
                session_id TEXT, content TEXT, status TEXT, priority TEXT,
                position INTEGER, time_created INTEGER, time_updated INTEGER
            );
            CREATE TABLE part (
                id TEXT PRIMARY KEY, session_id TEXT, data TEXT,
                time_created INTEGER, time_updated INTEGER
            );
        """)
        self.add_session("old", "另一会话", "/other")
        self.add_session("current", "当前会话", "/project")
        self.add_session("empty", "空会话", "/empty")
        self.add_usage("a", "old", 1000, model="Other", provider="private-other")
        self.add_usage("b", "current", 2000)
        self.add_usage("c", "current", 3000, status="error", model="Model-B", provider="byok")
        self.add_usage("d", "current", 4000, status="cancelled")
        self.add_usage("e", "current", 5000, status="running")
        self.conn.executemany("INSERT INTO tool_usage VALUES (?, ?, ?, ?)", [
            ("old", "OtherTool", "completed", 10),
            ("current", "Read", "completed", 20),
            ("current", "Read", "error", 40),
        ])
        self.conn.executemany("INSERT INTO todo VALUES (?, ?, ?, ?, ?, ?, ?)", [
            ("current", "任务一", "completed", "medium", 1, 1000, 1000),
            ("current", "任务二", "pending", "medium", 2, 1000, 1000),
        ])
        self.conn.execute("INSERT INTO part VALUES ('p1', 'current', '{\"type\":\"compaction\",\"preCompactTokenCount\":90000}', 2500, 2500)")
        self.conn.commit()

    def add_session(self, sid, title, directory):
        self.conn.execute("INSERT INTO session VALUES (?, ?, ?, 1000, 1000)", (sid, title, directory))

    def add_usage(self, rid, sid, started, status="completed", model="Model-A", provider="account:plan"):
        self.conn.execute(
            "INSERT INTO model_usage (id, session_id, started_at, model_id, provider_id, query_source,"
            " input_tokens, output_tokens, reasoning_tokens, cache_read_input_tokens,"
            " cache_creation_input_tokens, computed_total_tokens, duration_ms, time_to_first_token_ms,"
            " status, error_code, error_message)"
            " VALUES (?, ?, ?, ?, ?, 'main_turn', 100, 10, 5, 80, 0, 115, 30, 25, ?, 'E_TEST', 'synthetic error')",
            (rid, sid, started, model, provider, status))

    def run_script(self, *args, success=True, **env):
        self.conn.commit()
        result = subprocess.run(["bash", str(SCRIPT), *args], text=True, capture_output=True,
                                env={**os.environ, "ZCODE_USAGE_DB": str(self.db),
                                     "ZCODE_USAGE_PRICES": str(self.root / "missing.json"), "TZ": "UTC", **env})
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def dashboard(self, *args, cmd="dashboard-this"):
        out = self.root / "nested" / "dashboard.html"
        self.run_script(cmd, str(out), *args)
        html = out.read_text()
        match = re.search(r"const DATA =\n(.*?)\n;", html, re.S)
        self.assertIsNotNone(match)
        return json.loads(match[1]), html

    def test_latest_session_and_all_status_totals(self):
        result = self.run_script("this").stdout
        self.assertIn("当前会话", result)
        self.assertIn("最近请求推断", result)
        self.assertNotIn("Other", result)
        summary = result.split("—— 会话汇总", 1)[1].split("—— 按模型", 1)[0]
        self.assertEqual([int(n) for n in re.findall(r"\d+", summary)], [4, 1, 1, 1, 1, 400, 60, 320])
        self.assertIn("Model-B", result)
        errors = result.split("—— 最近失败/取消请求", 1)[1]
        self.assertIn("error", errors)
        self.assertIn("cancelled", errors)
        self.assertNotIn("running", errors)

    def test_explicit_session_overrides_latest(self):
        result = self.run_script("this", "--session", "old").stdout
        self.assertIn("另一会话", result)
        self.assertIn("显式指定会话", result)
        self.assertNotIn("当前会话", result)

    def test_directory_selects_its_latest_session(self):
        data, _ = self.dashboard("--directory", "/other")
        self.assertEqual(data["session"]["id"], "old")
        self.assertEqual(data["models"], ["Other"])
        self.run_script("this", "--directory", "/absent", success=False)

    def test_dashboard_isolates_all_metadata_and_tools(self):
        data, html = self.dashboard()
        self.assertEqual(data["session"]["id"], "current")
        self.assertEqual(data["session"]["latest"], 5000)
        self.assertEqual((data["total"], data["covered"]), (4, 4))
        self.assertEqual(data["sessions"], ["当前会话"])
        self.assertEqual(data["models"], ["Model-A", "Model-B"])
        self.assertEqual(data["providers"], ["account:plan", "byok"])
        self.assertEqual(data["tools"], [["Read", 2, 1, 30]])
        self.assertEqual(sum(row[4] for row in data["rows"]), 400)
        self.assertEqual(sum(row[5] for row in data["rows"]), 60)
        self.assertEqual(sum(row[6] for row in data["rows"]), 320)
        self.assertEqual(sorted(row[8] for row in data["rows"]), [0, 1, 2, 3])
        self.assertNotIn("OtherTool", html)
        self.assertNotIn("private-other", html)

    def test_full_dashboard_remains_unfiltered(self):
        data, _ = self.dashboard(cmd="dashboard")
        self.assertIsNone(data["session"])
        self.assertEqual((data["total"], data["covered"]), (5, 5))
        self.assertIn("Other", data["models"])
        self.assertEqual(len(data["tools"]), 2)
        self.assertIn("总请求数", self.run_script("summary").stdout)
        self.assertIn("Other", self.run_script("models").stdout)

    def test_filter_precedes_row_limit(self):
        for n in range(3010):
            self.add_usage("bulk-%04d" % n, "old", 10000 + n)
        data, _ = self.dashboard("--session", "current")
        self.assertEqual((data["total"], data["covered"]), (4, 4))
        data, _ = self.dashboard("--session", "old")
        self.assertEqual((data["total"], data["covered"]), (3011, 3000))
        self.assertTrue(all(data["models"][row[2]] == "Model-A" for row in data["rows"]))

    def test_upstream_dashboard_limit_is_preserved(self):
        data, _ = self.dashboard("2", cmd="dashboard")
        self.assertEqual((data["total"], data["covered"]), (5, 2))
        out = self.root / "limited.html"
        self.run_script("dashboard-this", str(out), "--session", "current", ZCODE_USAGE_LIMIT="1")
        data = json.loads(re.search(r"const DATA =\n(.*?)\n;", out.read_text(), re.S)[1])
        self.assertEqual((data["total"], data["covered"]), (4, 1))
        self.assertEqual(data["session"]["id"], "current")

    def test_invalid_dashboard_limits(self):
        out = str(self.root / "invalid.html")
        for limit in ("0", "20001", "invalid"):
            with self.subTest(limit=limit):
                for cmd in ("dashboard", "dashboard-this"):
                    self.run_script(cmd, out, success=False, ZCODE_USAGE_LIMIT=limit)

    def test_empty_database_and_existing_empty_session(self):
        self.conn.execute("DELETE FROM model_usage")
        self.assertIn("未找到", self.run_script("this", success=False).stderr)
        self.assertIn("0", self.run_script("this", "--session", "empty").stdout)
        data, _ = self.dashboard("--session", "empty")
        self.assertEqual(data["session"]["title"], "空会话")
        self.assertIsNone(data["session"]["latest"])
        self.assertEqual((data["total"], data["covered"], data["rows"]), (0, 0, []))

    def test_missing_session_metadata_preserves_usage(self):
        self.conn.execute("DELETE FROM session WHERE id='current'")
        data, _ = self.dashboard()
        self.assertEqual(data["session"]["id"], "current")
        self.assertIn("无标题", data["session"]["title"])
        self.assertEqual(data["covered"], 4)

    def test_quoted_arguments_and_script_tag_are_safe(self):
        sid = "session' OR 1=1 --"
        directory = "/project/it's a test"
        title = '</script><script>throw "injected"</script>&中文'
        self.add_session(sid, title, directory)
        self.add_usage("quoted", sid, 6000)
        data, html = self.dashboard("--session", sid)
        self.assertEqual(data["session"]["id"], sid)
        self.assertEqual(data["session"]["title"], title)
        self.assertEqual(data["total"], 1)
        self.assertEqual(html.count("</script>"), 1)
        data, _ = self.dashboard("--directory", directory)
        self.assertEqual(data["session"]["id"], sid)
        self.assertIn(sid, self.run_script("this", "--session", sid).stdout)

    def test_price_file_path_with_quote(self):
        price = self.root / "it's prices.json"
        price.write_text('{"Model-A":{"in":1,"out":2,"cache":0.1}}')
        out = self.root / "prices.html"
        self.run_script("dashboard-this", str(out), ZCODE_USAGE_PRICES=str(price))
        self.assertIn('"in":1', out.read_text())

    def test_invalid_arguments_and_missing_database(self):
        for args in [("--session",), ("--session", ""), ("--directory",), ("--wat",),
                     ("--session", "absent"), ("--session", "current", "--directory", "/project"),
                     ("--session", "current", "--session", "old")]:
            with self.subTest(args=args):
                self.run_script("this", *args, success=False)
        self.run_script("dashboard-this", success=False)
        self.assertIn("未知会话参数：--wat", self.run_script("this", "--wat", success=False).stderr)
        self.run_script("this", success=False, ZCODE_USAGE_DB=str(self.root / "absent.sqlite"))
        self.assertFalse((self.root / "absent.sqlite").exists())

    def test_queries_do_not_modify_database(self):
        before = self.db.read_bytes()
        self.run_script("this")
        self.dashboard()
        self.assertEqual(before, self.db.read_bytes())


if __name__ == "__main__":
    unittest.main()
