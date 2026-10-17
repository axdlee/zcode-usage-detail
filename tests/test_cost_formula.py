"""成本公式回归：input_tokens 含缓存命中，命中段按 cache 价、未命中段按 in 价，不得重复计费。

历史教训：0.12 在通知成本里写对了 inBillable = input - cache_read，但前端 rowCost 与
CLI cost 子命令一直是 input 全量 × in 价的旧公式，GLM 98% 命中率下成本虚高数倍，
直到 0.21.x 细读代码才暴露——本测试防止三处实现再次漂移。
"""

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
from support import PLUGIN

USAGE_SH = PLUGIN / "scripts" / "usage.sh"


class CostFormulaTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="ud-cost-"))
        self.db = self.tmp / "db.sqlite"
        self.prices = self.tmp / "prices.json"
        # 价格：in=1、out=2、cache=0.5（元/百万）
        self.prices.write_text(json.dumps({"currency": "CNY", "models": {"Model-A": {"in": 1, "out": 2, "cache": 0.5}}}))
        conn = sqlite3.connect(self.db)
        conn.executescript("""
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
                retry_count INTEGER DEFAULT 0, cancelled_by_user INTEGER DEFAULT 0,
                turn_id TEXT);
            CREATE TABLE tool_usage (session_id TEXT, tool_name TEXT, status TEXT, duration_ms INTEGER);
            CREATE TABLE todo (session_id TEXT, content TEXT, status TEXT, priority TEXT,
                position INTEGER, time_created INTEGER, time_updated INTEGER);
            CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT, data TEXT,
                time_created INTEGER, time_updated INTEGER);
            INSERT INTO session VALUES ('s1','成本口径样例','/p',1000,1000);
            -- input=2,000,000（含命中 1,600,000）→ 未命中 400,000
            INSERT INTO model_usage (id, session_id, started_at, model_id, provider_id, query_source,
                input_tokens, output_tokens, reasoning_tokens, cache_read_input_tokens, status) VALUES
                ('r1','s1',1758000000000,'Model-A','account:plan','main_turn',2000000,100000,0,1600000,'completed');
        """)
        conn.commit()
        conn.close()
        self.env = {**os.environ, "ZCODE_USAGE_DB": str(self.db), "ZCODE_USAGE_PRICES": str(self.prices),
                    "TZ": "UTC", "ZCODE_USAGE_NO_AUTOSYNC": "1"}

    def run_usage(self, *args):
        return subprocess.run(["bash", str(USAGE_SH), *args], text=True, capture_output=True, env=self.env)

    def test_cli_cost_no_double_billing(self):
        # 期望：输入成本 0.4（未命中 0.4M×1）、生成 0.2（0.1M×2）、缓存读 0.8（1.6M×0.5）、合计 1.4
        r = self.run_usage("cost")
        self.assertEqual(r.returncode, 0, r.stderr)
        for label, expect in [("输入成本", "0.4"), ("生成成本", "0.2"), ("缓存读成本", "0.8"), ("合计", "1.4")]:
            row = next((l for l in r.stdout.splitlines() if "Model-A" in l), "")
            self.assertIn(expect, row, f"{label} 期望含 {expect}，实际行：{row}")

    def test_front_end_formula_guards(self):
        # 文本护栏：三处实现都必须是「未命中 = input - cache_read」口径
        dash = (PLUGIN / "scripts" / "lib" / "dashboard.sh").read_text()
        self.assertIn("Math.max(0, N(r[4]) - N(r[6]))", dash, "前端 rowCost 缺少未命中扣减")
        serve = (PLUGIN / "scripts" / "serve.mjs").read_text()
        self.assertIn("nn(r[4]) - nn(r[6])", serve, "serve 预算告警成本未扣减缓存命中")
        monitor = (PLUGIN / "scripts" / "lib" / "cmd-monitor.sh").read_text()
        self.assertIn("inBillable", monitor, "通知成本口径漂移")
        cost_sql = (PLUGIN / "scripts" / "lib" / "cmd-cost.sh").read_text()
        self.assertIn("max(m.input_tokens - m.cache_read_input_tokens, 0)", cost_sql, "CLI cost SQL 未扣减缓存命中")


if __name__ == "__main__":
    unittest.main()
