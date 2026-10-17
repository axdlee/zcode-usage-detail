"""Shared fixtures for usage-detail test suites: synthetic DB + process helpers."""

import json
import os
from pathlib import Path
import sqlite3
import subprocess

PLUGIN = Path(__file__).resolve().parents[1] / "usage-detail"
SCHEMA = """
    CREATE TABLE session (
        id TEXT PRIMARY KEY, title TEXT, directory TEXT,
        time_created INTEGER, time_updated INTEGER
    );
    CREATE TABLE model_usage (
        id TEXT PRIMARY KEY, session_id TEXT, started_at INTEGER,
        model_id TEXT, provider_id TEXT, query_source TEXT,
        input_tokens INTEGER, output_tokens INTEGER,
        reasoning_tokens INTEGER, cache_read_input_tokens INTEGER,
        cache_creation_input_tokens INTEGER, computed_total_tokens INTEGER,
        duration_ms INTEGER, time_to_first_token_ms INTEGER,
        status TEXT, error_code TEXT, error_message TEXT,
        retry_count INTEGER DEFAULT 0, cancelled_by_user INTEGER DEFAULT 0,
        turn_id TEXT
    );
    CREATE TABLE tool_usage (
        session_id TEXT, tool_name TEXT, status TEXT, duration_ms INTEGER
    );
    CREATE TABLE todo (
        session_id TEXT, content TEXT, status TEXT, priority TEXT,
        position INTEGER, time_created INTEGER, time_updated INTEGER
    );
    CREATE TABLE part (
        id TEXT PRIMARY KEY, session_id TEXT, data TEXT,
        time_created INTEGER, time_updated INTEGER
    );
"""


class SynthDb:
    """合成 model_usage 库：schema 与 ~/.zcode/cli/db/db.sqlite 保持一致。"""

    def __init__(self, path: Path):
        self.path = path
        self.conn = sqlite3.connect(path)
        # 每次写入立即提交：子进程（CLI/node）只读文件，看不到未提交事务
        self.conn.isolation_level = None
        self.conn.executescript(SCHEMA)

    def close(self):
        self.conn.commit()
        self.conn.close()

    def session(self, sid, title, directory="/p"):
        self.conn.execute("INSERT INTO session VALUES (?, ?, ?, 1000, 1000)", (sid, title, directory))

    def usage(self, rid, sid, started, status="completed", model="Model-A", provider="account:plan",
              inn=100, out=10, reasoning=5, cache=80, dur=30000, ttft=800, retry=0, source="main_turn",
              turn=None):
        self.conn.execute(
            "INSERT INTO model_usage (id, session_id, started_at, model_id, provider_id, query_source,"
            " input_tokens, output_tokens, reasoning_tokens, cache_read_input_tokens,"
            " cache_creation_input_tokens, computed_total_tokens, duration_ms, time_to_first_token_ms,"
            " status, error_code, error_message, retry_count, turn_id)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, 'E_TEST', 'synthetic error', ?, ?)",
            (rid, sid, started, model, provider, source, inn, out, reasoning, cache,
             inn + out + reasoning, dur, ttft, status, retry, turn))

    def tool(self, sid, name, status="completed", dur=20):
        self.conn.execute("INSERT INTO tool_usage VALUES (?, ?, ?, ?)", (sid, name, status, dur))

    def todo(self, sid, content, status="completed"):
        n = self.conn.execute("SELECT count(*) FROM todo").fetchone()[0]
        self.conn.execute("INSERT INTO todo VALUES (?, ?, ?, 'medium', ?, 1000, 1000)",
                          (sid, content, status, n + 1))


class IsoHome:
    """把 HOME 指向临时目录：usage.sh / node 脚本对 ~/.zcode 的读写全部落在夹具里。"""

    def __init__(self, root: Path):
        self.root = root
        (root / ".zcode").mkdir(parents=True, exist_ok=True)

    def env(self, **extra):
        # NO_AUTOSYNC：测试内禁用真实网络价格同步，保持离线确定
        return {**os.environ, "HOME": str(self.root), "TZ": "UTC", "ZCODE_USAGE_NO_AUTOSYNC": "1", **extra}

    def zcode_path(self, name):
        return self.root / ".zcode" / name

    def read_json(self, name):
        return json.loads(self.zcode_path(name).read_text())

    def write_json(self, name, data):
        self.zcode_path(name).write_text(json.dumps(data))


def run(args, env, **kw):
    return subprocess.run(args, text=True, capture_output=True, env=env, **kw)


def run_cli(script, args, env, timeout=120):
    return run(["bash", str(script), *args],
               {**env, "ZCODE_USAGE_PRICES": str(Path(env["HOME"]) / "missing.json")}, timeout=timeout)


def run_node(script, args, env, timeout=60, stdin_text=None):
    return run(["node", str(script), *args], env, timeout=timeout, input=stdin_text)
