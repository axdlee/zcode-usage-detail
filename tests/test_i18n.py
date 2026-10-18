"""i18n 与交互优化（0.23.0）：双语字典、语言判定、昨天筛选、预算卡、明细搜索的文本护栏。"""

from pathlib import Path
import unittest, sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from support import PLUGIN

DASH = PLUGIN / "scripts" / "lib" / "dashboard.sh"


class I18nTest(unittest.TestCase):
    def test_core_guards(self):
        src = DASH.read_text()
        # i18n 基础设施
        self.assertIn("var I18N_EN = {", src)
        self.assertIn("function tr(s) { return I18N_LANG === 'en' && I18N_EN[s] ? I18N_EN[s] : s; }", src)
        self.assertIn("localStorage.getItem('ud-lang')", src)
        self.assertIn("createTreeWalker", src)  # 静态 DOM 翻译
        # 设置弹窗语言选择 + serve/侧栏两条生效路径
        self.assertIn("ud-mgr-lang", src)
        self.assertIn("Reopen the panel to apply", src)
        # 「昨天」筛选：按钮 / 下界 / 上界
        self.assertIn('data-r="yday"', src)
        self.assertIn("st.rng === 'yday') t0 -= 864e5", src)
        self.assertIn("function cutTo()", src)
        self.assertIn("if (cutUp && r[1] >= cutUp) return false;", src)
        # 明细文本搜索
        self.assertIn('id="ud-f-q"', src)
        self.assertIn("st.q = v;", src)
        # 预算进度卡（数据链三路）
        self.assertIn("D.budgetDaily", src)
        self.assertIn("'budgetDaily', $BUDGET_D", src)
        shim = (PLUGIN / "scripts" / "serve.mjs").read_text()
        self.assertIn("budgetDaily", shim)
        panel = (PLUGIN / "scripts" / "mcp" / "panel-server.mjs").read_text()
        self.assertIn("budgetDaily", panel)
        # 自动刷新（serve 壳）
        self.assertIn("ud-autorefresh", shim)
        self.assertIn("Auto ' + (on ? 'ON' : 'OFF')", shim)

    def test_dict_block_is_closed_exactly_once(self):
        # 回归护栏：词条曾被插到 '};' 之后导致字典提前闭合、整段 boot 语法报错页面白屏。
        # 要求 I18N_EN 字典块内不允许出现 '};'，且块以 '\n};' 恰好闭合一次，其后紧跟 var I18N_LANG。
        src = DASH.read_text()
        start = src.index("var I18N_EN = {")
        end = src.index("\n};", start)
        body = src[start:end]
        self.assertNotIn("\n};", body)
        tail = src[end:end + 40]
        self.assertTrue(tail.startswith("\n};\nvar I18N_LANG"), tail[:40])

    def test_turn_banner_en_rewrite(self):
        # 英文横幅：turn-stats.mjs 服务端中文文本在前端按固定格式重写（含 万/亿 → K/M/B）
        src = DASH.read_text()
        self.assertIn("function enTurn(t)", src)
        self.assertIn("text = enTurn(text);", src)
        self.assertIn("This turn: ", src)


if __name__ == "__main__":
    unittest.main()
