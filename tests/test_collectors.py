#!/usr/bin/python3 -I
"""Tests for bin/collect-grok, bin/collect-hermes and bin/collect-grok-bot.

Everything runs in a throwaway HOME. No test touches the network: the HTTP
calls are replaced, and the paths that would reach them are fed expired or
missing sign-ins.

    python3 -I tests/test_collectors.py
"""

import contextlib
import email.message
import importlib.util
import io
import json
import os
import pathlib
import sqlite3
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
from importlib.machinery import SourceFileLoader

BIN = pathlib.Path(__file__).resolve().parents[1] / "bin"


def load(name):
    loader = SourceFileLoader(name.replace("-", "_"), str(BIN / name))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


grok = load("collect-grok")
hermes = load("collect-hermes")
grokbot = load("collect-grok-bot")


def iso(seconds_from_now):
    import datetime as dt
    return (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=seconds_from_now)).isoformat()


def http_error(code, retry_after=None):
    headers = email.message.Message()
    if retry_after is not None:
        headers["Retry-After"] = str(retry_after)
    return urllib.error.HTTPError("https://example.invalid", code, "x", headers, io.BytesIO(b""))


class FakeHome(unittest.TestCase):
    def setUp(self):
        self.home = pathlib.Path(tempfile.mkdtemp(prefix="agents-home-"))
        self.saved = {k: os.environ.get(k) for k in ("HOME", "XDG_CACHE_HOME", "GROK_HOME", "HERMES_HOME")}
        os.environ["HOME"] = str(self.home)
        os.environ.pop("XDG_CACHE_HOME", None)
        os.environ.pop("GROK_HOME", None)
        os.environ.pop("HERMES_HOME", None)
        self.cache = self.home / ".cache" / "omarchy" / "agent-usage"

    def tearDown(self):
        for key, value in self.saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def write(self, rel, data, mode=0o600):
        path = self.home / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(data if isinstance(data, str) else json.dumps(data))
        path.chmod(mode)
        return path


# --- shared hardening -------------------------------------------------------


class CacheHardening(FakeHome):
    def test_cache_dir_is_made_private(self):
        self.cache.mkdir(parents=True, mode=0o755)
        self.cache.chmod(0o755)
        for module in (grok, hermes, grokbot):
            self.assertEqual(module.cache_root(), self.cache)
            self.assertEqual(self.cache.stat().st_mode & 0o777, 0o700)
            self.cache.chmod(0o755)

    def test_a_planted_cache_link_is_refused(self):
        elsewhere = self.home / "elsewhere"
        elsewhere.mkdir()
        self.cache.parent.mkdir(parents=True)
        self.cache.symlink_to(elsewhere)
        for module in (grok, hermes, grokbot):
            with self.assertRaises(PermissionError):
                module.cache_root()

    def test_writes_replace_a_planted_link_instead_of_following_it(self):
        victim = self.write("victim.txt", "must survive")
        self.cache.mkdir(parents=True)
        target = self.cache / "grok-limits.json"
        target.symlink_to(victim)
        for module in (grok, hermes, grokbot):
            module.write_json(target, {"a": 1})
            self.assertEqual(victim.read_text(), "must survive")
            self.assertFalse(target.is_symlink())
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            target.unlink()
            target.symlink_to(victim)
        self.assertEqual([p.name for p in self.cache.iterdir()], ["grok-limits.json"])

    def test_bounded_reads_refuse_links_fifos_and_oversize(self):
        real = self.write("real.json", {"ok": 1})
        link = self.home / "link.json"
        link.symlink_to(real)
        fifo = self.home / "fifo.json"
        os.mkfifo(fifo)
        big = self.write("big.json", {"pad": "x" * 5000})
        for module in (grok, hermes, grokbot):
            self.assertEqual(module.read_bounded_json(real, 1000), {"ok": 1})
            self.assertIsNone(module.read_bounded_json(link, 1000))
            self.assertIsNone(module.read_bounded_json(fifo, 1000))  # returns, does not block
            self.assertIsNone(module.read_bounded_json(big, 1000))


# --- Grok --------------------------------------------------------------------


def turn(prompt_id, model="grok-4", inp=100, out=50, ts="2026-10-19T10:00:00Z"):
    return json.dumps({"timestamp": ts, "params": {"update": {
        "sessionUpdate": "turn_completed", "prompt_id": prompt_id,
        "usage": {"modelUsage": {model: {"inputTokens": inp, "outputTokens": out}}}}}})


class GrokTests(FakeHome):
    def test_billing_payload(self):
        parsed = grok.parse_billing({
            "subscription_tier": "SuperGrokPlus",
            "config": {
                "creditUsagePercent": 42,
                "currentPeriod": {"type": "WEEKLY", "end": "2026-10-20T00:00:00Z"},
                "productUsage": [{"product": "GrokChat", "usagePercent": 10},
                                 {"product": "GrokBuild", "usagePercent": 30},
                                 {"product": "Mystery", "usagePercent": 99}],
                "prepaidBalance": {"val": 500}, "onDemandCap": 1000, "onDemandUsed": 250,
            },
        })
        self.assertEqual([l["title"] for l in parsed["limits"]], ["Weekly", "Grok Build", "Chat"])
        self.assertAlmostEqual(parsed["limits"][0]["percent"], 0.42)
        self.assertEqual(parsed["tierLabel"], "SuperGrok Plus")
        self.assertEqual(parsed["balance"], {"remaining": 12.5, "funded": 15.0, "spent": 2.5, "currency": "USD"})

    def test_session_scan(self):
        root = self.home / ".grok" / "sessions"
        self.write(".grok/sessions/a/updates.jsonl", "\n".join([
            turn("p1"), turn("p1"), "not json turn_completed", "x" * 10, turn("p2", inp=10, out=5)]) + "\n")
        self.write(".grok/sessions/sub/summary.json", {"session_kind": "subagent-task"})
        self.write(".grok/sessions/sub/updates.jsonl", turn("p9") + "\n")
        stats = grok.scan_sessions(root)
        self.assertEqual(stats["totalPrompts"], 2)
        self.assertEqual(stats["totalSessions"], 1)
        self.assertEqual(stats["modelUsage"]["grok-4"]["inputTokens"], 110)

    def test_an_oversized_line_is_skipped_without_losing_the_rest(self):
        old = grok.MAX_LINE_BYTES
        grok.MAX_LINE_BYTES = 4096
        try:
            self.write(".grok/sessions/a/updates.jsonl",
                       turn("p1") + "\n" + "turn_completed " + "y" * 200_000 + "\n" + turn("p2") + "\n")
            turns = grok.scan_updates(self.home / ".grok/sessions/a/updates.jsonl")
        finally:
            grok.MAX_LINE_BYTES = old
        self.assertEqual([t["id"] for t in turns], ["p1", "p2"])

    def test_bounded_lines(self):
        r, w = os.pipe()
        os.write(w, b"short\n" + b"z" * 6000 + b"\nlast\n" + b"q" * 100)
        os.close(w)
        try:
            lines = list(grok.bounded_lines(r, 4096))
        finally:
            os.close(r)
        # The 6000-byte line arrived inside one read and is still dropped;
        # an unterminated tail is kept.
        self.assertEqual(lines, [b"short", b"last", b"q" * 100])

    def test_links_and_fifos_in_the_session_tree_are_not_read(self):
        outside = self.write("outside.jsonl", turn("leak") + "\n")
        (self.home / ".grok/sessions/a").mkdir(parents=True)
        (self.home / ".grok/sessions/a/updates.jsonl").symlink_to(outside)
        (self.home / ".grok/sessions/b").mkdir(parents=True)
        os.mkfifo(self.home / ".grok/sessions/b/updates.jsonl")
        done = []
        t = threading.Thread(target=lambda: done.append(grok.scan_sessions(self.home / ".grok/sessions")), daemon=True)
        t.start()
        t.join(5)
        self.assertTrue(done, "a FIFO in the session tree hung the scan")
        self.assertEqual(done[0]["totalPrompts"], 0)

    def test_a_planted_lock_link_is_never_truncated(self):
        victim = self.write("victim.txt", "must survive")
        root = self.home / ".grok" / "sessions"
        root.mkdir(parents=True)
        cache_file, lock_file = grok.scan_cache_paths(root)
        lock_file.symlink_to(victim)
        stats = grok.cached_scan(root, 20)
        self.assertEqual(stats["totalPrompts"], 0)
        self.assertEqual(victim.read_text(), "must survive")

    def login(self, expires):
        self.write(".grok/auth.json", {"x": {"auth_mode": "oidc", "key": "tok", "expires_at": expires}})

    def test_expired_sign_in_serves_the_cache_without_a_retry_treadmill(self):
        self.login(iso(-60))
        fetched = round((time.time() - 7200) * 1000)
        self.write(".cache/omarchy/agent-usage/grok-limits.json",
                   {"fetchedAtMs": fetched, "limits": [{"label": "Weekly", "percent": 0.2}], "tierLabel": "SuperGrok"})
        result = grok.collect_limits(self.home / ".grok", False)
        self.assertEqual(result["usageStatusText"], "Sign-in expired")
        self.assertNotIn("retryAdvised", result)
        self.assertTrue(result["limitsAsOf"].startswith("20"))
        self.assertEqual(result["tierLabel"], "SuperGrok")

    def test_429_backs_off_even_a_forced_refresh(self):
        self.login(iso(3600))
        calls = []

        def limited(url, headers):
            calls.append(url)
            raise http_error(429, retry_after=1200)

        old = grok.fetch_proxy_json
        grok.fetch_proxy_json = limited
        try:
            first = grok.collect_limits(self.home / ".grok", True)
            second = grok.collect_limits(self.home / ".grok", True)
        finally:
            grok.fetch_proxy_json = old
        self.assertEqual(len(calls), 1)
        self.assertEqual(first["usageStatusText"], "Rate limited, next try in 20m")
        self.assertTrue(second["usageStatusText"].startswith("Rate limited"))
        self.assertNotIn("retryAdvised", first)

    def test_a_network_failure_advises_a_retry(self):
        self.login(iso(3600))
        old = grok.fetch_proxy_json
        grok.fetch_proxy_json = lambda url, headers: (_ for _ in ()).throw(OSError("down"))
        try:
            result = grok.collect_limits(self.home / ".grok", True)
        finally:
            grok.fetch_proxy_json = old
        self.assertEqual(result["usageStatusText"], "Grok limits unavailable")
        self.assertTrue(result["retryAdvised"])

    def test_retry_after_bounds(self):
        msg = email.message.Message()
        self.assertEqual(grok.retry_after_seconds(msg), 300)
        msg["Retry-After"] = "99999999"
        self.assertEqual(grok.retry_after_seconds(msg), 300)  # not a plain small number
        msg.replace_header("Retry-After", "7200")
        self.assertEqual(grok.retry_after_seconds(msg), 3600)
        msg.replace_header("Retry-After", "Wed, 21 Oct 2026 07:28:00 GMT")
        self.assertEqual(grok.retry_after_seconds(msg), 300)


# --- Hermes ------------------------------------------------------------------


def hermes_db(path):
    con = sqlite3.connect(path)
    now = time.time()
    con.executescript("""
        create table sessions (id text, title text, source text, model text, message_count int,
          started_at real, last_activity_at real, ended_at real, end_reason text, pinned int,
          parent_session_id text, archived int, hidden int, actual_cost_usd real, estimated_cost_usd real);
        create table messages (role text, timestamp real, active int);
        create table session_model_usage (model text, input_tokens int, output_tokens int,
          cache_read_tokens int, cache_write_tokens int, last_seen real);
        create table async_delegations (state text, owner_pid int, owner_started_at int);
    """)
    rows = [
        ("s1", "Fix <b>bug</b>", "desktop", "claude-opus-5", 4, now - 600, now - 60, None, None, 1, None, 0, 0, 0.5, None),
        ("s2", "Old", "cli", "grok-4", 2, now - 9000, now - 8000, now - 7000, "tui_close", 0, None, 0, 0, None, 0.25),
        ("bad id!", "Nope", "cli", "x", 1, now - 50, now - 40, None, None, 0, None, 0, 0, None, None),
        ("child", "Sub", "cli", "x", 1, now - 30, now - 20, now - 10, "done", 0, "s1", 0, 0, None, None),
        ("arch", "Archived", "cli", "x", 1, now - 30, now - 20, None, None, 0, None, 1, 0, None, None),
    ]
    con.executemany("insert into sessions values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    con.executemany("insert into messages values (?,?,?)", [("user", now - 100, 1), ("user", now - 90, 0), ("assistant", now - 80, 1)])
    con.execute("insert into session_model_usage values ('claude-opus-5', 100, 50, 10, 5, ?)", (now,))
    con.commit()
    con.close()


class HermesTests(FakeHome):
    def test_account_payload(self):
        parsed = hermes.parse_account({
            "subscription": {"plan": "Plus", "monthly_credits": 20, "current_period_end": "2026-11-01T00:00:00Z"},
            "paid_service_access": {"subscription_credits_remaining": 15, "purchased_credits_remaining": 0},
        })
        self.assertEqual(parsed["tierLabel"], "Plus")
        self.assertEqual(parsed["limits"][0]["title"], "Monthly")
        self.assertAlmostEqual(parsed["limits"][0]["percent"], 0.25)
        self.assertEqual(parsed["balance"]["remaining"], 15)

    def test_state_db(self):
        (self.home / ".hermes").mkdir()
        hermes_db(self.home / ".hermes" / "state.db")
        os.chmod(self.home / ".hermes" / "state.db", 0o600)
        stats = hermes.scan_state_db(self.home / ".hermes")
        self.assertEqual(stats["totalPrompts"], 1)
        ids = [s["id"] for s in stats["recentSessions"]]
        # Newest first; the bad id, the archived one and the sub-session are not shown.
        self.assertEqual(ids, ["s1", "s2"])
        first = next(s for s in stats["recentSessions"] if s["id"] == "s1")
        self.assertEqual(first["title"], "Fix bbug/b")
        self.assertEqual(first["source"], "desktop")
        self.assertTrue(first["open"])
        self.assertEqual(stats["lastEnded"]["reason"], "tui_close")
        self.assertEqual(stats["modelUsage"]["claude-opus-5"]["inputTokens"], 100)

    def test_gateway_is_running_only_for_the_same_process(self):
        me = os.getpid()
        ticks = hermes.process_start_ticks(me)
        self.write(".hermes/gateway_state.json", {"pid": me, "start_time": ticks, "gateway_state": "running", "active_agents": 2})
        self.assertEqual(hermes.gateway_status(self.home / ".hermes"), {"state": "running", "activeAgents": 2})
        self.write(".hermes/gateway_state.json", {"pid": me, "start_time": ticks + 1, "gateway_state": "running"})
        self.assertEqual(hermes.gateway_status(self.home / ".hermes")["state"], "stopped")

    def test_cron(self):
        self.write(".hermes/cron/jobs.json", {"jobs": [
            {"next_run_at": iso(3600)}, {"next_run_at": iso(600), "last_status": "error"},
            {"enabled": False}, {"state": "paused", "next_run_at": iso(60)}, "junk"]})
        cron = hermes.cron_status(self.home / ".hermes")
        self.assertEqual((cron["jobs"], cron["active"], cron["failing"]), (4, 2, 1))
        self.assertTrue(cron["nextRunAt"].startswith("20"))

    def test_never_signed_in_is_not_an_error(self):
        result = hermes.collect_limits(self.home / ".hermes", False)
        self.assertEqual(result["usageStatusText"], "Not signed in to Nous Portal")
        self.assertNotIn("retryAdvised", result)

    def test_expired_sign_in_never_advises_a_retry(self):
        self.write(".hermes/auth.json", {"providers": {"nous": {"access_token": "t", "expires_at": iso(-60)}}})
        result = hermes.collect_limits(self.home / ".hermes", False)
        self.assertEqual(result["usageStatusText"], "Sign-in expired")
        self.assertNotIn("retryAdvised", result)

    def test_429_backs_off(self):
        self.write(".hermes/auth.json", {"providers": {"nous": {"access_token": "t", "expires_at": iso(3600)}}})
        calls = []

        def limited(token):
            calls.append(token)
            raise http_error(429)

        old = hermes.fetch_account
        hermes.fetch_account = limited
        try:
            first = hermes.collect_limits(self.home / ".hermes", True)
            second = hermes.collect_limits(self.home / ".hermes", True)
        finally:
            hermes.fetch_account = old
        self.assertEqual(len(calls), 1)
        self.assertEqual(first["usageStatusText"], "Rate limited, next try in 5m")
        self.assertTrue(second["usageStatusText"].startswith("Rate limited"))


# --- Grok Bot ----------------------------------------------------------------


def jwt(exp):
    import base64
    body = base64.urlsafe_b64encode(json.dumps({"exp": exp}).encode()).decode().rstrip("=")
    return "eyJhbGciOiJub25lIn0." + body + ".sig"


class GrokBotTests(FakeHome):
    def setUp(self):
        super().setUp()
        self.calls = []
        self.old_http = grokbot.http_json
        grokbot.http_json = lambda url, **kw: self.calls.append(url) or self.answer

    def tearDown(self):
        grokbot.http_json = self.old_http
        super().tearDown()

    def test_an_expired_app_token_is_never_renewed(self):
        self.write(".cursor/auth.json", {"accessToken": jwt(time.time() - 60), "refreshToken": "r"})
        self.answer = (200, {})
        result = grokbot.collect_limits(False)
        self.assertEqual(result["usageStatusText"], "Sign-in expired")
        self.assertEqual(result["authHelpText"], grokbot.EXPIRED_HELP)
        self.assertNotIn("retryAdvised", result)
        self.assertEqual(self.calls, [])  # no token endpoint, no API call

    def test_a_valid_token_reads_the_weekly_pool(self):
        self.write(".cursor/auth.json", {"accessToken": jwt(time.time() + 3600)})
        self.answer = (200, {"usagePercent": 37, "nextResetTimestampUtc": 1_800_000_000_000, "grokPlanLabel": "SuperGrok"})
        result = grokbot.collect_limits(True)
        self.assertEqual(len(self.calls), 1)
        self.assertIn("GetSandUsageStatus", self.calls[0])
        self.assertAlmostEqual(result["limits"][0]["percent"], 0.37)
        self.assertEqual(result["tierLabel"], "SuperGrok")

    def test_429_backs_off(self):
        self.write(".cursor/auth.json", {"accessToken": jwt(time.time() + 3600)})
        self.answer = (429, {})
        first = grokbot.collect_limits(True)
        second = grokbot.collect_limits(True)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(first["usageStatusText"], "Rate limited, next try in 5m")
        self.assertTrue(second["usageStatusText"].startswith("Rate limited"))

    def test_no_credentials(self):
        self.answer = (200, {})
        self.assertEqual(grokbot.collect_limits(False)["usageStatusText"], "Waiting for auth")
        self.assertEqual(self.calls, [])

    def test_renewal_code_is_gone(self):
        source = (BIN / "collect-grok-bot").read_text()
        self.assertNotIn("refresh_token", source)
        self.assertNotIn("oauth/token", source)


# --- whole runs --------------------------------------------------------------


class CollectorRuns(FakeHome):
    """Each collector run as the refresh runs it, offline, prints one record
    with the id the refresh expects."""

    def run_collector(self, name):
        import subprocess
        env = {"HOME": str(self.home), "PATH": "/usr/bin", "LANG": "C.UTF-8"}
        out = subprocess.run([sys.executable, "-I", "-S", str(BIN / name), "--limits-only"],
                             env=env, capture_output=True, timeout=60, check=True).stdout
        return json.loads(out)

    def test_records(self):
        (self.home / ".hermes").mkdir()
        hermes_db(self.home / ".hermes" / "state.db")
        os.chmod(self.home / ".hermes" / "state.db", 0o600)
        self.write(".grok/sessions/a/updates.jsonl", turn("p1") + "\n")
        for name, rid in (("collect-grok", "grok"), ("collect-hermes", "hermes"), ("collect-grok-bot", "grok-bot")):
            record = self.run_collector(name)
            self.assertEqual(record["id"], rid)
        self.assertEqual(self.run_collector("collect-hermes")["hermes"]["lastEnded"]["reason"], "tui_close")


if __name__ == "__main__":
    unittest.main()
