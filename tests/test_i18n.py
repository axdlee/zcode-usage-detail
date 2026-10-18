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
        self.assertIn("function t(s) { return I18N_LANG === 'en' && I18N_EN[s] ? I18N_EN[s] : s; }", src)
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


if __name__ == "__main__":
    unittest.main()
