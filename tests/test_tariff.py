"""分时计价（峰谷）：内置 DeepSeek 官方牌价 + tariff 结构 + 端到端进 dashboard。"""

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from support import PLUGIN, SynthDb

USAGE_SH = PLUGIN / "scripts" / "usage.sh"
BUILTIN = PLUGIN / "scripts" / "default-prices.json"


class TariffTest(unittest.TestCase):
    def test_builtin_deepseek_tariff_entries(self):
        d = json.loads(BUILTIN.read_text())
        for m in ("deepseek-flash", "deepseek-v4-flash", "deepseek-v4-pro"):
            e = d["models"].get(m)
            self.assertIsNotNone(e, f"内置表缺 {m}")
            self.assertGreater(e["in"], 0)
            t = e.get("tariff") or {}
            self.assertEqual(t.get("tz"), 8)
            self.assertEqual(t.get("weekend"), 0.5)  # 周末全天空闲价（2026-08-23 官方规则）
            tiers = t.get("tiers") or []
            self.assertEqual([h for h in tiers[0]["hours"]], [[9, 12], [14, 18]])  # 工作日高峰
            self.assertEqual(tiers[0]["mult"], 1.0)  # 高峰为基准价
            self.assertEqual(tiers[1]["mult"], 0.5)  # 空闲半价
            # 2026 年国务院办公厅节假日安排（国办通知，2025-11-04 发布）
            self.assertIn("2026-02-18", t["holidays"])  # 春节（周三放假 → 空闲价）
            self.assertIn("2026-10-07", t["holidays"])  # 国庆末尾
            self.assertEqual(len(t["holidays"]), 33)
            self.assertIn("2026-02-14", t["workdays"])  # 春节调休上班的周六 → 按工作日分时
            self.assertNotIn("2026-10-17", t["holidays"])  # 普通周末不属于节假日

    def test_pinned_protects_official_entries_in_sync(self):
        src = (PLUGIN / "scripts" / "lib" / "cmd-cost.sh").read_text()
        for m in ("deepseek-flash", "deepseek-v4-flash", "deepseek-v4-pro"):
            self.assertIn(f"'{m}'", src, f"sync PINNED 未保护 {m}")
        self.assertIn("default-prices.json", src)  # 官方权威条目由内置表种子化

    def test_dashboard_embeds_tariff(self):
        with tempfile.TemporaryDirectory(prefix="ud-tariff-") as td:
            db = Path(td) / "db.sqlite"
            synth = SynthDb(db)
            synth.session("s1", "tariff 样例")
            synth.usage("r1", "s1", 1768364400000, model="deepseek-flash", turn=None)  # 2026-01-14 15:00 +08 高峰
            out = Path(td) / "dash.html"
            r = subprocess.run(["bash", str(USAGE_SH), "dashboard", str(out)], text=True, capture_output=True,
                               env={**os.environ, "ZCODE_USAGE_DB": str(db), "TZ": "Asia/Shanghai",
                                    "ZCODE_USAGE_NO_AUTOSYNC": "1"})
            self.assertEqual(r.returncode, 0, r.stderr)
            m = re.search(r"const DATA =\n(.*?)\n;", out.read_text(), re.S)
            self.assertIsNotNone(m)
            data = json.loads(m.group(1))
            e = data["prices"]["models"]["deepseek-flash"]
            self.assertEqual(e["tariff"]["weekend"], 0.5)
            self.assertEqual(e["in"], 2)  # 官方高峰牌价（CNY/百万 token）


if __name__ == "__main__":
    unittest.main()
