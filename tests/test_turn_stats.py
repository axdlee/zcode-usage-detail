"""turn-stats.mjs guard rails: --current only trusts prompt-submit state of the same session."""

import json
from pathlib import Path
import time
import unittest

from support import PLUGIN, IsoHome, SynthDb, run_node


class TurnStatsTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = IsoHome(Path(self.tmp.name))
        self.db = Path(self.tmp.name) / "usage.sqlite"
        self.dbh = SynthDb(self.db)
        self.addCleanup(self.dbh.close)
        now = int(time.time() * 1000)
        self.dbh.usage("a", "s1", now - 5000, dur=20000, ttft=1000)
        self.dbh.usage("b", "s1", now - 2000, dur=30000, ttft=2000)
        self.state = self.home.zcode_path("usage-detail-turn.json")
        self.env = self.home.env(
            ZCODE_USAGE_DB=str(self.db),
            ZCODE_SESSION_ID="s1",
        )

    def write_state(self, source="prompt-submit", sid="s1", prompt_ts=None):
        self.state.write_text(json.dumps({
            "source": source, "promptTs": prompt_ts or (int(time.time() * 1000) - 10000),
            "sessionId": sid,
        }))

    def test_no_state_empty(self):
        r = run_node(PLUGIN / "scripts/turn-stats.mjs", ["--turn", "--current"], self.env)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "")

    def test_wrong_source_guarded(self):
        self.write_state(source="other")
        r = run_node(PLUGIN / "scripts/turn-stats.mjs", ["--turn", "--current"], self.env)
        self.assertEqual(r.stdout.strip(), "")

    def test_session_mismatch_guarded(self):
        self.write_state(sid="other-session")
        r = run_node(PLUGIN / "scripts/turn-stats.mjs", ["--turn", "--current"], self.env)
        self.assertEqual(r.stdout.strip(), "")

    def test_match_outputs_line(self):
        self.write_state()
        r = run_node(PLUGIN / "scripts/turn-stats.mjs", ["--turn", "--current"], self.env)
        self.assertTrue(r.stdout.strip().startswith("本轮用量："), r.stdout)
        self.assertIn("2 次请求", r.stdout)

    def test_no_current_uses_any_source(self):
        self.write_state(source="whatever")
        r = run_node(PLUGIN / "scripts/turn-stats.mjs", ["--turn"], self.env)
        self.assertTrue(r.stdout.strip().startswith("本轮用量："))


if __name__ == "__main__":
    unittest.main()
