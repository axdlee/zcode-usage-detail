"""大数据量 + 特殊字符的性能回归：防 bash 3.2 ${var//} 平方级退化复发。

背景：META JSON 的 < 转义曾在 bash 层做（${META//</\\u003c}），bash 3.2 在
长串 + replacement 含反斜杠 + 串中存在匹配时是平方级——3MB 全量 META 叠加
会话标题里的一个 < 就能把侧栏面板拖到分钟级超时。现转义在 SQL replace() 完成。
"""

import json
import time
import unittest

from support import PLUGIN, IsoHome, SynthDb, run_cli


class PerfEscapeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import tempfile
        from pathlib import Path
        cls.tmp = tempfile.TemporaryDirectory()
        cls.home = IsoHome(Path(cls.tmp.name))
        cls.db = Path(cls.tmp.name) / "usage.sqlite"
        d = SynthDb(cls.db)
        import random
        random.seed(3)
        # 3 万行请求 + 大量含 < 与 </script> 的会话标题（复现原缺陷的数据形态）
        titles = ["<2GB 低配模式调优", "对比 a<b 与 b<c 的排序", "正常标题没有特殊字符",
                  "</script>alert(1)</script>", "TS 泛型 <T extends object> 实战"]
        for i in range(40):
            d.session(f"s{i:03d}", titles[i % len(titles)], f"/proj/<{i}>")
        for i in range(30000):
            sid = f"s{i % 40:03d}"
            d.usage(f"r{i}", sid, 1700000000000 + i * 60_000,
                    model=["glm-5.3", "glm-5.3-flash"][i % 2],
                    inn=500 + (i * 7) % 9000, out=100 + i % 800, cache=1000 + i % 5000,
                    status="error" if i % 97 == 0 else "completed")
        cls.env = cls.home.env(ZCODE_USAGE_DB=str(cls.db))
        cls.out = Path(cls.tmp.name) / "dash.html"

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_01_dashboard_fast_with_lt_titles(self):
        # 根治前：3MB META + 标题含 < 会触发 bash 3.2 平方级替换（分钟级超时）
        t0 = time.time()
        r = run_cli(PLUGIN / "scripts/usage.sh", ["dashboard", str(self.out)], self.env, timeout=120)
        elapsed = time.time() - t0
        self.assertEqual(r.returncode, 0, r.stderr[-500:] if r.stderr else "")
        self.assertLess(elapsed, 20, f"dashboard 生成过慢：{elapsed:.1f}s（疑似平方级路径复发）")
        html = self.out.read_text()
        # 转义生效：< 已变 \u003c，且恶意闭合序列不会原样出现
        self.assertNotIn("</script>alert", html)
        self.assertIn("\\u003c2GB", html)

    def test_02_meta_json_still_parses(self):
        # \u003c 是合法 JSON 转义：抽出的 DATA 必须能被 JSON.parse 无损还原
        html = self.out.read_text()
        start = html.index("const DATA =") + len("const DATA =")
        end = html.index(";\nfunction __usageBoot")
        data = json.loads(html[start:end].strip())
        # 含 < 的会话标题语义无损（JSON 解析后还原为 <）
        self.assertTrue(any("<2GB" in t for t in data["sessions"]))
        self.assertEqual(len(data["rows"]), 30000)


if __name__ == "__main__":
    unittest.main()
