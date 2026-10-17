"""BYOK 供应商名 + 项目根归并 + 本轮兜底（0.22.0 三特性）。

安全红线：provider_config.json 含 apiKey 明文，project-meta 只允许输出
providerId → providerName 映射，任何路径都不得把 Key 带出去。
"""

import json
import unittest
from pathlib import Path
import sys

from support import PLUGIN, IsoHome, run_node

sys.path.insert(0, str(Path(__file__).resolve().parent))

PM = PLUGIN / "scripts" / "lib" / "project-meta.mjs"
DASH = PLUGIN / "scripts" / "lib" / "dashboard.sh"


class ProjectMetaTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.home = IsoHome(Path(self.tmp.name))
        self.home.zcode_path("v2").mkdir(parents=True, exist_ok=True) if hasattr(self.home, "zcode_path") else None

    def tearDown(self):
        self.tmp.cleanup()

    def write_cfg(self, cfg):
        p = self.home.root / ".zcode" / "v2" / "provider_config.json"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(cfg))
        return p

    def test_01_provider_names_extracted(self):
        # providerId → providerName 命中；无 name 的条目跳过
        self.write_cfg({"config": {"providerConfigRules": {"providerRules": [
            {"providerId": "new-provider", "providerName": "hub-linuxdo",
             "config": {"access": {"apiKey": "sk-TEST-SECRET-never-leak"}}},
            {"providerId": "account:plan", "config": {}},
        ]}}})
        env = self.home.env()
        out = run_node(PM, ["[]"], env)
        r = json.loads(out.stdout)
        self.assertEqual(r["providerNames"], {"new-provider": "hub-linuxdo"})
        # 安全红线：apiKey / baseUrl 等其余字段绝不出现
        self.assertNotIn("sk-TEST-SECRET-never-leak", out.stdout)

    def test_02_provider_names_missing_config(self):
        # 配置不存在 / 坏 JSON：空映射不崩
        env = self.home.env()
        r = json.loads(run_node(PM, ["[]"], env).stdout)
        self.assertEqual(r["providerNames"], {})
        self.home.zcode_path("v2/provider_config.json").write_text("{broken")
        r = json.loads(run_node(PM, ["[]"], env).stdout)
        self.assertEqual(r["providerNames"], {})

    def test_03_project_map_git_merge(self):
        # 本仓库自身的子目录会话应归并到 git 仓库根（根必须是原目录的祖先且含 .git）；
        # 不存在的目录退化为空串。不写死仓库路径，语义化断言。
        env = self.home.env()
        deep = PLUGIN / "scripts"  # 插件内深层目录（其 git 根在更上层）
        dirs = [str(deep), "/nonexistent-dir-xyz", ""]
        r = json.loads(run_node(PM, [json.dumps(dirs)], env).stdout)
        pm = r["projectMap"]
        root = pm[str(deep)]
        self.assertTrue(root, "深层目录应解析出 git 根")
        self.assertIn(Path(root), Path(deep).parents, "git 根应是原目录的祖先（归并语义）")
        self.assertTrue((Path(root) / ".git").exists(), "git 根应含 .git")
        self.assertEqual(pm["/nonexistent-dir-xyz"], "")
        self.assertEqual(pm[""], "")

    def test_04_bad_dirs_json_degrades(self):
        env = self.home.env()
        r = json.loads(run_node(PM, ["not-json"], env).stdout)
        self.assertEqual(r["projectMap"], {})

    def test_06_no_git_binary(self):
        # 用户环境没装 git：projectRoot 必须静默退化为空串（前端按原目录分组），不能崩、不能挂
        import os, tempfile
        fakebin = Path(self.tmp.name) / "bin"
        fakebin.mkdir(exist_ok=True)
        node = os.path.realpath(__import__("shutil").which("node"))
        (fakebin / "node").symlink_to(node)  # PATH 里只有 node，没有任何 git
        env = self.home.env(PATH=str(fakebin))
        deep = PLUGIN / "scripts"
        r = json.loads(run_node(PM, [json.dumps([str(deep), str(PLUGIN)])], env).stdout)
        self.assertEqual(r["projectMap"], {str(deep): "", str(PLUGIN): ""},
                         "无 git 时所有目录都应退化为空串")
        self.assertEqual(r["providerNames"], {})

    def test_04b_dirs_via_stdin(self):
        # bash 侧经 stdin 传 dirs（Git Bash/MSYS 会篡改 argv 里的 POSIX 路径），stdin 不经转换
        import subprocess
        env = self.home.env()
        deep = PLUGIN / "scripts"
        proc = subprocess.run(["node", str(PM)], input=json.dumps([str(deep)]),
                              capture_output=True, text=True, env=env)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        r = json.loads(proc.stdout)
        self.assertTrue(r["projectMap"][str(deep)], "stdin 方式应照常解析 git 根")

    def test_05_dashboard_text_guards(self):
        # 前端三特性的文本护栏：真名映射 / 项目归并 / 本轮兜底，缺一处即回归
        src = DASH.read_text()
        self.assertIn("(D.providerNames || {})[raw] || raw", src, "pvLabel 未接 BYOK 名映射")
        self.assertIn("var PMAP = D.projectMap || {};", src, "项目归并映射缺失")
        self.assertIn("projKey(SD[r[0]]", src, "项目聚合未按仓库根归并")
        self.assertIn("window.__udTurnFallback", src, "本轮兜底函数缺失")
        self.assertIn("window.__udTurnFallback() : ''", src, "横幅未接兜底回退")
        self.assertIn("'providerNames', json_extract(json('$PMETA')", src, "bash META 未注入 providerNames")
        self.assertIn("| node \"$SCRIPT_DIR/lib/project-meta.mjs\"", src, "dirs 未走 stdin（MSYS 会篡改 argv 路径）")
        mon = (PLUGIN / "scripts" / "lib" / "cmd-monitor.sh").read_text()
        self.assertIn("stripBom", mon, "statusline 未剥 BOM")
        shim = (PLUGIN / "scripts" / "sqlite.mjs").read_text()
        self.assertIn("readfile", shim, "sqlite 替身缺 readfile（Windows 无 CLI 时价格注入必炸）")
        self.assertIn("-csv", shim, "sqlite 替身缺 csv 模式（export csv 回落依赖）")


if __name__ == "__main__":
    unittest.main()
