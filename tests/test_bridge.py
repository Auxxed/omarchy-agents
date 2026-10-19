#!/usr/bin/python3 -I
"""Tests for bin/usage-bridge, the only way records reach the shell.

    python3 -I tests/test_bridge.py
"""

import importlib.util
import json
import math
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader

ROOT = pathlib.Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "bin" / "usage-bridge"

loader = SourceFileLoader("usage_bridge", str(BRIDGE))
spec = importlib.util.spec_from_loader(loader.name, loader)
bridge = importlib.util.module_from_spec(spec)
loader.exec_module(bridge)


def keys(value, prefix=""):
    """Every key path in a JSON value, lists looked into."""
    out = set()
    if isinstance(value, dict):
        for k, v in value.items():
            out.add(prefix + k)
            out |= keys(v, prefix + k + ".")
    elif isinstance(value, list):
        for v in value:
            out |= keys(v, prefix)
    return out


# Fields the collectors write that the panel never reads.
NOT_FOR_THE_PANEL = {"updatedAt"}


class Sanitize(unittest.TestCase):
    def test_junk_never_crashes_it(self):
        junk = [None, True, "x", "inf", float("inf"), float("nan"), -1, 10**400 if False else 1e308, [], {}, [1, {}], {"a": []}]
        fields = ["limits", "balance", "activeDates", "recentDays", "modelUsage", "todayTokensByModel",
                  "todayPrompts", "limitsAsOf", "hermes", "name", "ready"]
        for field in fields:
            for value in junk:
                record = {"id": "hermes", field: value}
                out = bridge.sanitize_record(record)
                self.assertIsNotNone(out, (field, value))
                json.dumps(out, allow_nan=False)
        nested = {"id": "hermes", "balance": {"remaining": "inf", "funded": float("inf"), "spent": "x"},
                  "limits": [{"percent": float("inf")}, {"percent": "0.5"}, {"percent": True}, {"percent": 0.4}],
                  "hermes": {"runningWorkers": float("inf"), "lastEnded": {"reason": ["x"], "at": 5},
                             "recentSessions": [{"id": "ok", "messages": float("inf"), "costUsd": "1"}]}}
        out = bridge.sanitize_record(nested)
        json.dumps(out, allow_nan=False)
        self.assertNotIn("balance", out)
        self.assertEqual([l["percent"] for l in out["limits"]], [0.4])
        self.assertEqual(out["hermes"]["runningWorkers"], 0)
        self.assertEqual(out["hermes"]["lastEnded"], {"reason": "", "at": ""})

    def test_bad_ids_are_rejected(self):
        for rid in ("", "../x", "-x", "a" * 70, None, 5):
            self.assertIsNone(bridge.sanitize_record({"id": rid}))

    def test_session_ids_that_reach_an_argv_are_checked(self):
        out = bridge.sanitize_record({"id": "hermes", "hermes": {"recentSessions": [
            {"id": "good_1"}, {"id": "x;rm -rf ~"}, {"id": "--resume"}, {"id": "ok", "source": "EVIL"}]}})
        sessions = out["hermes"]["recentSessions"]
        self.assertEqual([s["id"] for s in sessions], ["good_1", "ok"])
        self.assertEqual(sessions[1]["source"], "cli")

    def test_limits_as_of_must_be_a_timestamp(self):
        self.assertEqual(bridge.sanitize_record({"id": "g", "limitsAsOf": "2026-10-17T05:30:07.591000+00:00"})["limitsAsOf"],
                         "2026-10-17T05:30:07.591000+00:00")
        self.assertEqual(bridge.sanitize_record({"id": "g", "limitsAsOf": "<b>yesterday</b>"})["limitsAsOf"], "")

    def test_every_collector_field_reaches_the_panel(self):
        """The bridge rebuilds records from a whitelist. Twice a collector
        field (limitsAsOf, then runningWorkers and lastEnded) never reached
        the panel because the whitelist missed it. Full records from both
        collectors must come through with every key."""
        grok = {
            "schemaVersion": 1, "id": "grok", "name": "Grok", "updatedAt": "2026-10-19T00:00:00+00:00",
            "ready": True, "hasLocalStats": True, "hasPromptStats": True, "tierLabel": "SuperGrok",
            "usageStatusText": "Sign-in expired", "authHelpText": "Run grok login", "retryAdvised": True,
            "limits": [{"label": "Weekly (7-day)", "title": "Weekly", "percent": 0.2, "resetsAt": "2026-10-20T00:00:00+00:00"}],
            "limitsAsOf": "2026-10-17T05:30:07.591000+00:00",
            "balance": {"remaining": 1.5, "funded": 2.0, "spent": 0.5, "currency": "USD", "estimated": True},
            "todayPrompts": 1, "todaySessions": 1, "todayTotalTokens": 10, "todayTokensByModel": {"grok-4": 10},
            "recentDays": [{"date": "2026-10-19", "messageCount": 10}], "modelUsage": {"grok-4": {
                "inputTokens": 1, "outputTokens": 2, "cacheReadInputTokens": 3, "cacheCreationInputTokens": 4}},
            "totalPrompts": 1, "totalSessions": 1, "activeDays": 1, "activeDates": ["2026-10-19"], "scope": "device",
        }
        hermes = dict(grok, id="hermes", name="Hermes", hermes={
            "gateway": {"state": "running", "activeAgents": 1}, "paused": False,
            "cron": {"jobs": 1, "active": 1, "failing": 0, "nextRunAt": "2026-10-20T00:00:00+00:00"},
            "recentSessions": [{"id": "s1", "title": "T", "source": "cli", "model": "m", "messages": 2,
                                "lastActivityAt": "2026-10-19T00:00:00+00:00", "open": True, "pinned": False, "costUsd": 0.1}],
            "todayCostUsd": 0.1, "weekCostUsd": 0.2, "runningWorkers": 1,
            "lastEnded": {"reason": "tui_close", "at": "2026-10-19T00:00:00+00:00"},
        })
        for record in (grok, hermes):
            out = bridge.sanitize_record(record)
            lost = keys(record) - keys(out) - NOT_FOR_THE_PANEL
            self.assertEqual(lost, set(), record["id"])


class Files(unittest.TestCase):
    def setUp(self):
        self.home = pathlib.Path(tempfile.mkdtemp(prefix="bridge-home-"))
        self.usage = self.home / ".local/state/omarchy/agents/usage"
        self.usage.mkdir(parents=True)
        self.env = {"HOME": str(self.home), "PATH": "/usr/bin", "LANG": "C.UTF-8"}

    def run_bridge(self, *args):
        return subprocess.run([sys.executable, "-I", "-S", str(BRIDGE), *args], env=self.env,
                              capture_output=True, text=True, timeout=20)

    def put(self, name, data, mode=0o600):
        path = self.usage / name
        path.write_text(data if isinstance(data, str) else json.dumps(data))
        path.chmod(mode)
        return path

    def test_list_only_names_regular_records(self):
        self.put("claude.json", {"id": "claude"})
        self.put("notes.txt", "x")
        self.put(".grok.json.0123456789abcdef.tmp", "x")
        (self.usage / "link.json").symlink_to(self.usage / "claude.json")
        os.mkfifo(self.usage / "fifo.json")
        self.assertEqual(self.run_bridge("list").stdout.split(), ["claude"])

    def test_read_refuses_links_fifos_hardlinks_and_oversize(self):
        target = self.home / "elsewhere.json"
        target.write_text(json.dumps({"id": "evil"}))
        (self.usage / "a.json").symlink_to(target)
        os.mkfifo(self.usage / "b.json")
        self.put("c.json", {"id": "c", "pad": "x" * (bridge.MAX_RECORD + 10)})
        self.put("d.json", {"id": "d"})
        os.link(self.usage / "d.json", self.home / "second-name.json")
        for agent in ("a", "b", "c", "d"):
            result = self.run_bridge("read", agent)
            self.assertNotEqual(result.returncode, 0, agent)
            self.assertEqual(result.stdout, "", agent)
            self.assertNotIn("Traceback", result.stderr, agent)

    def test_read_a_good_record(self):
        self.put("grok.json", {"id": "grok", "name": "Grok", "todayPrompts": 3})
        result = self.run_bridge("read", "grok")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["todayPrompts"], 3)

    def test_missing_records_and_bad_requests(self):
        self.assertEqual(self.run_bridge("read", "nope").stdout, "")
        self.assertEqual(self.run_bridge("read", "../../x").returncode, 2)
        self.assertEqual(self.run_bridge("frobnicate").returncode, 2)
        self.assertEqual(self.run_bridge().returncode, 2)
        self.put("bad.json", "{not json")
        result = self.run_bridge("read", "bad")
        self.assertEqual(result.returncode, 4)
        self.assertNotIn("Traceback", result.stderr)
        deep = "[" * 100000 + "]" * 100000
        self.put("deep.json", deep)
        result = self.run_bridge("read", "deep")
        self.assertEqual(result.returncode, 4)
        self.assertNotIn("Traceback", result.stderr)

    def test_no_usage_directory_yet(self):
        empty = pathlib.Path(tempfile.mkdtemp(prefix="bridge-empty-"))
        self.env["HOME"] = str(empty)
        self.assertEqual(self.run_bridge("list").returncode, 0)
        self.assertEqual(self.run_bridge("read", "claude").returncode, 0)


if __name__ == "__main__":
    unittest.main()
