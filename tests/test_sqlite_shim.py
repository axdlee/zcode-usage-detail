"""sqlite.mjs shim must reproduce sqlite3 CLI list output (same rows, same | format)."""

import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from support import IsoHome, SynthDb

QUERIES = [
    "SELECT id, session_id, started_at, model_id, provider_id, input_tokens, status FROM model_usage ORDER BY started_at",
    "SELECT count(*) AS n, COALESCE(sum(input_tokens+output_tokens),0) AS tok FROM model_usage WHERE status='error'",
    "SELECT NULL AS n, '中文|标题' AS t, 3.5 AS f FROM (SELECT 1)",
    "SELECT provider_id AS v, count(*) AS c FROM model_usage GROUP BY provider_id ORDER BY c DESC",
]


class SqliteShimTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = IsoHome(Path(self.tmp.name))
        self.db = Path(self.tmp.name) / "u.sqlite"
        d = SynthDb(self.db)
        now = int(time.time() * 1000)
        d.session("s1", "会话一", "/p1")
        d.usage("a", "s1", now - 60000)
        d.usage("b", "s1", now - 30000, status="error", provider="byok", model="Model-B")
        d.close()

    def out(self, cmd, extra_env=None):
        env = {**os.environ, "HOME": str(self.home.root), **(extra_env or {})}
        r = subprocess.run(cmd, text=True, capture_output=True, env=env, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def test_shim_matches_sqlite3_cli(self):
        import shutil
        if not shutil.which("sqlite3"):
            self.skipTest("sqlite3 CLI 未安装，无法对比")
        for sql in QUERIES:
            cli = self.out(["sqlite3", "-readonly", str(self.db), sql])
            shim = self.out(["node", str(Path(__file__).resolve().parents[1] / "usage-detail/scripts/sqlite.mjs"),
                             str(self.db), sql])
            self.assertEqual(cli, shim, sql)

    def test_shim_header_mode(self):
        out = self.out(["node", str(Path(__file__).resolve().parents[1] / "usage-detail/scripts/sqlite.mjs"),
                        "-header", str(self.db), "SELECT id, status FROM model_usage ORDER BY id"])
        lines = out.strip().splitlines()
        self.assertEqual(lines[0], "id|status")
        self.assertEqual(len(lines), 3)

    def test_cli_suite_via_shim(self):
        """强制 qr/q 走 node 替身时，CLI 关键子命令输出仍正确。"""
        script = Path(__file__).resolve().parents[1] / "usage-detail/scripts/usage.sh"
        env = {**os.environ, "HOME": str(self.home.root), "ZCODE_USAGE_DB": str(self.db), "ZCODE_USAGE_SQLITE": "node"}
        for args, expect in ((["summary"], "总请求数"), (["errors"], "synthetic error"), (["waste", "7"], "失败请求：1 次")):
            r = subprocess.run(["bash", str(script), *args], text=True, capture_output=True, env=env, timeout=120)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(expect, r.stdout, args)


if __name__ == "__main__":
    unittest.main()
