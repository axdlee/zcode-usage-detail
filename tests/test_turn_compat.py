"""turn 分段与老 schema 兼容：turn_id 列存在时进 META r14，缺失时降级不崩。"""

import json
import os
import re
import sqlite3
import subprocess
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from support import PLUGIN, SynthDb

USAGE_SH = PLUGIN / "scripts" / "usage.sh"


class TurnCompatTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="ud-turn-"))
        self.db = self.tmp / "db.sqlite"
        self.out = self.tmp / "dash.html"
        self.conn = None

    def tearDown(self):
        if self.conn is not None:
            self.conn.close()

    def run_usage(self, *args):
        return subprocess.run(["bash", str(USAGE_SH), *args], text=True, capture_output=True,
                              env={**os.environ, "ZCODE_USAGE_DB": str(self.db),
                                   "ZCODE_USAGE_PRICES": str(self.tmp / "missing.json"),
                                   "TZ": "UTC",
                                   "ZCODE_USAGE_NO_AUTOSYNC": "1"})

    def data_of(self, html):
        m = re.search(r"const DATA =\n(.*?)\n;", html, re.S)
        self.assertIsNotNone(m, "DATA JSON 缺失")
        return json.loads(m.group(1))

    def test_dashboard_carries_turn_ids(self):
        synth = SynthDb(self.db)
        self.conn = synth.conn
        t0 = 1758000000000
        synth.session("s1", "turn 分段样例")
        synth.usage("r1", "s1", t0, turn="turn_a")
        synth.usage("r2", "s1", t0 + 60_000, turn="turn_a")
        synth.usage("r3", "s1", t0 + 120_000, turn="turn_b")
        r = self.run_usage("dashboard", str(self.out))
        self.assertEqual(r.returncode, 0, r.stderr)
        turns = [row[14] for row in self.data_of(self.out.read_text())["rows"]]
        self.assertEqual(turns.count("turn_a"), 2)
        self.assertIn("turn_b", turns)

    def test_legacy_schema_without_turn_id_still_works(self):
        # 老版本 ZCode 的 model_usage 没有 turn_id 列：dashboard / export 不允许崩
        self.conn = sqlite3.connect(self.db)
        self.conn.executescript("""
            CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, directory TEXT,
                time_created INTEGER, time_updated INTEGER);
            CREATE TABLE model_usage (
                id TEXT PRIMARY KEY, session_id TEXT, started_at INTEGER,
                model_id TEXT, provider_id TEXT, query_source TEXT,
                input_tokens INTEGER, output_tokens INTEGER,
                reasoning_tokens INTEGER, cache_read_input_tokens INTEGER,
                cache_creation_input_tokens INTEGER, computed_total_tokens INTEGER,
                duration_ms INTEGER, time_to_first_token_ms INTEGER,
                status TEXT, error_code TEXT, error_message TEXT,
                retry_count INTEGER DEFAULT 0, cancelled_by_user INTEGER DEFAULT 0);
            CREATE TABLE tool_usage (session_id TEXT, tool_name TEXT, status TEXT, duration_ms INTEGER);
            CREATE TABLE todo (session_id TEXT, content TEXT, status TEXT, priority TEXT,
                position INTEGER, time_created INTEGER, time_updated INTEGER);
            CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT, data TEXT,
                time_created INTEGER, time_updated INTEGER);
            INSERT INTO session VALUES ('s1','legacy','/p',1000,1000);
            INSERT INTO model_usage (id, session_id, started_at, model_id, provider_id, query_source,
                input_tokens, output_tokens, cache_read_input_tokens, status) VALUES
                ('r1','s1',1758000000000,'Model-A','account:plan','main_turn',100,10,80,'completed');
        """)
        self.conn.commit()
        r = self.run_usage("dashboard", str(self.out))
        self.assertEqual(r.returncode, 0, r.stderr)
        data = self.data_of(self.out.read_text())
        self.assertTrue(all(row[14] is None for row in data["rows"]))
        export = self.tmp / "exp.json"
        r = self.run_usage("export", "json", str(export))
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(export.read_text())
        self.assertEqual(len(data["rows"]), 1)
        self.assertIsNone(data["rows"][0][14])


if __name__ == "__main__":
    unittest.main()
