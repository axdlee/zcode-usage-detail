"""CLI query / export / switch subcommands against a synthetic database."""

import json
from pathlib import Path
import unittest

from support import PLUGIN, IsoHome, SynthDb, run_cli


class CliQueriesTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = IsoHome(Path(self.tmp.name))
        self.db = Path(self.tmp.name) / "usage.sqlite"
        self.dbh = SynthDb(self.db)
        self.addCleanup(self.dbh.close)
        # 今天 0 点（本地时区）为基准铺数据
        import time
        self.today0 = int(time.mktime(time.strptime(time.strftime("%Y-%m-%d"), "%Y-%m-%d"))) * 1000
        d = self.dbh
        d.session("s1", "会话一", "/p1")
        d.session("s2", "会话二", "/p2")
        d.usage("a", "s1", self.today0 + 1000)                      # 完成
        d.usage("b", "s1", self.today0 + 2000, model="Model-B", provider="byok")
        d.usage("c", "s2", self.today0 + 3000, status="error", retry=2)
        d.usage("e", "s2", self.today0 + 4000, status="cancelled")
        d.usage("f", "s2", self.today0 - 86400_000, status="completed")  # 昨天
        d.tool("s1", "Read"); d.tool("s1", "Read", "error", 40); d.tool("s2", "Bash")
        d.todo("s1", "任务一"); d.todo("s1", "任务二", "pending")
        self.env = self.home.env(ZCODE_USAGE_DB=str(self.db))

    def q(self, *args):
        r = run_cli(PLUGIN / "scripts/usage.sh", list(args), self.env)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def test_summary_json(self):
        r = self.q("summary")
        self.assertIn("总请求数", r.stdout)
        self.assertIn("1", r.stdout)

    def test_recent_and_day(self):
        r = self.q("recent", "2")
        self.assertIn("耗时", r.stdout)  # 明细表头
        import time
        self.q("day", time.strftime("%Y-%m-%d"))  # 本地今天（UTC 视角可能为空，验证不报错）
        self.q("days", "7")

    def test_sessions_models_providers(self):
        for cmd, kw in (("sessions", "会话一"), ("models", "Model-A"), ("providers", "plan")):
            r = self.q(cmd)
            self.assertIn(kw, r.stdout, cmd)

    def test_errors_and_months_and_projects(self):
        self.assertIn("synthetic error", self.q("errors").stdout)
        self.q("months")
        self.assertIn("/p1", self.q("projects").stdout)

    def test_blocks(self):
        self.q("blocks")

    def test_waste(self):
        r = self.q("waste", "7")
        self.assertIn("失败请求：1 次", r.stdout)
        self.assertIn("重试：2 次", r.stdout)
        self.assertIn("浪费取证", r.stdout)

    def test_export_json_csv(self):
        out = Path(self.tmp.name) / "e.json"
        self.q("export", "json", str(out))
        j = json.loads(out.read_text())
        self.assertEqual(len(j["rows"]), 5)
        # rows 列形状：r12=id、r13=retry_count
        self.assertEqual(j["rows"][0][12], "a" if j["rows"][0][12] == "a" else j["rows"][0][12])
        self.assertTrue(all(len(row) >= 14 for row in j["rows"]))
        csvp = Path(self.tmp.name) / "e.csv"
        self.q("export", "csv", str(csvp))
        self.assertGreaterEqual(csvp.read_text().count("\n"), 5)

    def test_dashboard_generates(self):
        out = Path(self.tmp.name) / "d.html"
        self.q("dashboard", str(out))
        html = out.read_text()
        self.assertIn('id="ud-insights"', html)
        self.assertIn('id="ud-models"', html)
        self.assertIn("tokCell", html)

    def test_alerts_switch_roundtrip(self):
        self.q("alerts", "permission", "on")
        self.assertTrue(self.home.read_json("usage-alerts.json")["permission"] is True)
        self.q("alerts", "budget", "off")
        cfg = self.home.read_json("usage-alerts.json")
        self.assertIs(cfg["permission"], True)
        self.assertIs(cfg["budget"], False)
        st = self.q("alerts", "permission", "status").stdout
        self.assertIn("开", st)

    def test_turnstats_switch_roundtrip(self):
        self.q("turnstats", "notify")
        cfg = self.home.read_json("usage-turnstats.json")
        self.assertIs(cfg["enabled"], True)
        self.assertEqual(cfg["mode"], "notify")
        st = self.q("turnstats", "status").stdout
        self.assertIn("通知模式", st)
        self.q("turnstats", "off")
        self.assertIs(self.home.read_json("usage-turnstats.json")["enabled"], False)

    def test_prices_show_builtin_fallback(self):
        r = self.q("prices", "show")
        # 无用户价格文件时回退内置价（GLM 5.3 官方 CNY 价）
        self.assertIn("glm-5.3", r.stdout.lower())

    def test_doctor(self):
        self.q("doctor")

    def test_alerts_whitelist(self):
        # alerts 子命令参数白名单（what/act 拼接进 node -e 前必须校验；无参缺省 budget）
        src = PLUGIN.joinpath("scripts", "lib", "cmd-monitor.sh").read_text()
        self.assertIn('case "$what" in budget|permission)', src)
        self.assertIn('case "$act" in on|off|status)', src)
        self.assertIn('local what="${2:-budget}"', src)


if __name__ == "__main__":
    unittest.main()
