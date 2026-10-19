#!/usr/bin/python3 -I
"""Tests for bin/refresh, which runs the collectors and writes their records.

The refresh is copied next to fake collectors in a throwaway directory, so
it runs the fakes instead of the real ones, against a throwaway HOME.

    python3 -I tests/test_refresh.py
"""

import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def fake(body):
    return "#!/usr/bin/python3 -I\nimport json, sys, time\n" + body + "\n"


class Refresh(unittest.TestCase):
    def setUp(self):
        self.home = pathlib.Path(tempfile.mkdtemp(prefix="refresh-home-"))
        self.bin = pathlib.Path(tempfile.mkdtemp(prefix="refresh-bin-"))
        # Omarchy's packaged updater is not part of what is under test.
        source = (ROOT / "bin" / "refresh").read_text()
        packaged = 'PACKAGED = "/usr/bin/omarchy-agent-usage-update"'
        self.assertIn(packaged, source)
        (self.bin / "refresh").write_text(source.replace(packaged, 'PACKAGED = "/nonexistent/updater"'))
        self.usage = self.home / ".local/state/omarchy/agents/usage"
        self.env = {"HOME": str(self.home), "PATH": "/usr/bin", "LANG": "C.UTF-8"}

    def collector(self, agent, body):
        path = self.bin / ("collect-" + agent)
        path.write_text(fake(body))
        path.chmod(0o755)

    def record(self, agent, **extra):
        return "print(json.dumps(" + repr({"id": agent, "ready": True, **extra}) + "))"

    def run_refresh(self, *args, timeout=60):
        return subprocess.run([sys.executable, "-I", "-S", str(self.bin / "refresh"), *args], env=self.env,
                              capture_output=True, text=True, timeout=timeout)

    def test_records_are_written_private_and_whole(self):
        self.collector("grok", self.record("grok", limits=[]))
        self.collector("hermes", self.record("hermes"))
        result = self.run_refresh()
        self.assertEqual(json.loads((self.usage / "grok.json").read_text())["id"], "grok")
        self.assertEqual((self.usage / "grok.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.usage.stat().st_mode & 0o777, 0o700)
        self.assertEqual(sorted(p.name for p in self.usage.iterdir()), ["grok.json", "hermes.json"])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_planted_link_is_replaced_not_followed(self):
        victim = self.home / "victim"
        victim.write_text("must survive")
        self.usage.mkdir(parents=True, mode=0o700)
        (self.usage / "grok.json").symlink_to(victim)
        self.collector("grok", self.record("grok"))
        self.run_refresh("grok")
        self.assertEqual(victim.read_text(), "must survive")
        self.assertFalse((self.usage / "grok.json").is_symlink())

    def test_bad_output_is_never_written(self):
        cases = {
            "grok": "print('not json')",
            "hermes": self.record("someone-else"),
            "grok-bot": "sys.stdout.write('x' * 300000)",
        }
        for agent, body in cases.items():
            self.collector(agent, body)
        result = self.run_refresh()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(any(self.usage.glob("*.json")))

    def test_a_signed_out_grok_bot_record_is_removed(self):
        self.usage.mkdir(parents=True, mode=0o700)
        (self.usage / "grok-bot.json").write_text("{}")
        self.collector("grok-bot", "print(json.dumps({'id': 'grok-bot', 'ready': False, 'limits': []}))")
        self.run_refresh("grok-bot")
        self.assertFalse((self.usage / "grok-bot.json").exists())

    def test_a_hung_collector_is_killed(self):
        source = (self.bin / "refresh").read_text().replace("TIMEOUT = 45", "TIMEOUT = 2")
        (self.bin / "refresh").write_text(source)
        self.collector("grok", "time.sleep(60)")
        started = time.monotonic()
        result = self.run_refresh("grok", timeout=30)
        self.assertLess(time.monotonic() - started, 15)
        self.assertEqual(result.returncode, 1)

    def test_except_and_only(self):
        for agent in ("grok", "hermes", "grok-bot"):
            self.collector(agent, self.record(agent, limits=[{"percent": 0.1}]))
        self.run_refresh("--except", "hermes")
        self.assertEqual(sorted(p.name for p in self.usage.iterdir()), ["grok-bot.json", "grok.json"])
        shutil.rmtree(self.usage)
        self.run_refresh("hermes")
        self.assertEqual([p.name for p in self.usage.iterdir()], ["hermes.json"])
        self.assertEqual(self.run_refresh("--bogus").returncode, 2)
        self.assertEqual(self.run_refresh("../etc").returncode, 2)

    def test_stale_temporaries_are_swept_and_fresh_ones_kept(self):
        self.usage.mkdir(parents=True, mode=0o700)
        old = self.usage / ".grok.json.0123456789abcdef.tmp"
        new = self.usage / ".hermes.json.fedcba9876543210.tmp"
        other = self.usage / "notes.tmp"
        for path in (old, new, other):
            path.write_text("x")
        os.utime(old, (time.time() - 3600, time.time() - 3600))
        self.collector("grok", self.record("grok"))
        self.run_refresh("grok")
        self.assertFalse(old.exists())
        self.assertTrue(new.exists())
        self.assertTrue(other.exists())

    def test_sigterm_mid_write_unwinds_and_removes_the_temporary(self):
        """The handler raises SystemExit, so write_atomic's cleanup runs. A
        handler that exited on the spot would leave the .tmp behind (and
        take this test process with it)."""
        import importlib.util
        from importlib.machinery import SourceFileLoader
        loader = SourceFileLoader("refresh_under_test", str(self.bin / "refresh"))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        refresh = importlib.util.module_from_spec(spec)
        loader.exec_module(refresh)
        self.usage.mkdir(parents=True, mode=0o700)
        dirfd = os.open(self.usage, os.O_RDONLY | os.O_DIRECTORY)
        real_fsync = os.fsync

        def interrupted(fd):
            refresh.on_terminate(signal.SIGTERM, None)

        os.fsync = interrupted
        try:
            with self.assertRaises(SystemExit) as caught:
                refresh.write_atomic(dirfd, "grok.json", b"{}")
        finally:
            os.fsync = real_fsync
            os.close(dirfd)
        self.assertEqual(caught.exception.code, 128 + signal.SIGTERM)
        self.assertEqual(list(self.usage.iterdir()), [])

    def test_sigterm_takes_the_collector_down_and_leaves_no_temporary(self):
        self.collector("grok", "time.sleep(60)")
        proc = subprocess.Popen([sys.executable, "-I", "-S", str(self.bin / "refresh"), "grok"], env=self.env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 10
        child = None
        while time.monotonic() < deadline and child is None:
            out = subprocess.run(["/usr/bin/pgrep", "-f", str(self.bin / "collect-grok")], capture_output=True, text=True).stdout
            child = int(out.split()[0]) if out.split() else None
            time.sleep(0.05)
        self.assertIsNotNone(child, "collector never started")
        proc.send_signal(signal.SIGTERM)
        proc.wait(10)
        proc.stderr.close()
        self.assertEqual(proc.returncode, 128 + signal.SIGTERM)
        time.sleep(0.3)
        self.assertNotEqual(subprocess.run(["/usr/bin/kill", "-0", str(child)], capture_output=True).returncode, 0)
        self.assertFalse(any(p.name.endswith(".tmp") for p in self.usage.iterdir()))


if __name__ == "__main__":
    unittest.main()
