import importlib.util
import json
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("chrome", ROOT / "scripts/chrome-devtools-mcp.py")
chrome = importlib.util.module_from_spec(spec)
spec.loader.exec_module(chrome)


def servers(app=False):
    command, env = chrome.runtime(app)
    return [{"name": name, "enabled": True, "transport": {
        "type": "stdio", "command": command, "args": chrome.server_args(port),
        "env": env, "env_vars": [], "cwd": None}} for name, port in chrome.SERVERS.items()]


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.servers = servers()

    def output(self, value):
        return subprocess.CompletedProcess([], 0, stdout=json.dumps(value))

    def test_existing_both_registrations_are_not_mutated(self):
        with patch.object(chrome.subprocess, "run", return_value=self.output(self.servers)) as run:
            chrome.registration("codex", self.home, True)
            self.assertEqual(run.call_count, 1)

    def test_missing_adds_both_exact_commands_then_verifies(self):
        with patch.object(chrome.subprocess, "run", side_effect=[self.output([]), self.output([]), self.output([]), self.output(self.servers)]) as run:
            chrome.registration("codex", self.home, True)
            for index, (name, port) in enumerate(chrome.SERVERS.items(), 1):
                self.assertEqual(run.call_args_list[index].args[0], ["codex", "mcp", "add", name, "--", "npx", "-y", "chrome-devtools-mcp@latest", f"--browser-url=http://127.0.0.1:{port}"])
                self.assertEqual(run.call_args_list[index].kwargs["env"]["CODEX_HOME"], str(self.home))

    def test_existing_9222_only_adds_9223(self):
        with patch.object(chrome.subprocess, "run", side_effect=[self.output(self.servers[:1]), self.output([]), self.output(self.servers)]) as run:
            chrome.registration("codex", self.home, True)
            self.assertEqual(run.call_args_list[1].args[0][3], "chrome-devtools-9223")
            self.assertEqual(run.call_count, 3)

    def test_conflict_in_second_port_prevents_first_add(self):
        for field, value in [("command", "custom-npx"), ("args", []), ("env", {"X": "1"}), ("cwd", "/tmp"), ("env_vars", ["SECRET"]), ("type", "streamable_http")]:
            server = json.loads(json.dumps(self.servers[1]))
            server["transport"][field] = value
            with self.subTest(field=field), patch.object(chrome.subprocess, "run", return_value=self.output([server])) as run:
                with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
                    chrome.registration("codex", self.home, True)
                self.assertEqual(run.call_count, 1)

    def test_disabled_duplicate_invalid_list_and_missing_fail(self):
        disabled = json.loads(json.dumps(self.servers))
        disabled[0]["enabled"] = False
        for value in [{}, [None], [], self.servers * 2, disabled]:
            with self.subTest(value=value), patch.object(chrome.subprocess, "run", return_value=self.output(value)):
                with self.assertRaises(ValueError):
                    chrome.registration("codex", self.home)

    def test_failed_add_propagates(self):
        with patch.object(chrome.subprocess, "run", side_effect=[self.output([]), subprocess.CalledProcessError(1, "codex")]):
            with self.assertRaises(subprocess.CalledProcessError):
                chrome.registration("codex", self.home, True)

    def test_preflight_accepts_missing_but_never_mutates(self):
        with patch.object(chrome.subprocess, "run", return_value=self.output([])) as run:
            chrome.registration("codex", self.home, preflight=True)
            self.assertEqual(run.call_count, 1)

    def test_app_records_absolute_npx_and_node_path(self):
        with patch.object(chrome.shutil, "which", side_effect=lambda name, **kw: "/fixture/runtime/bin/" + name):
            self.assertEqual(chrome.runtime(True), ("/fixture/runtime/bin/npx", {"PATH": "/fixture/runtime/bin:/usr/local/bin:/usr/bin:/bin"}))
            with patch.object(chrome.subprocess, "run", side_effect=[self.output([]), self.output([]), self.output([]), self.output(servers(True))]) as run:
                chrome.registration("codex", self.home, True, app=True)
                add = run.call_args_list[1].args[0]
                self.assertIn("PATH=/fixture/runtime/bin:/usr/local/bin:/usr/bin:/bin", add)
                self.assertIn("/fixture/runtime/bin/npx", add)

    def test_symlink_fails_before_codex(self):
        (self.home / "config.toml").symlink_to(self.home / "missing")
        with patch.object(chrome.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                chrome.registration("codex", self.home, True)
            run.assert_not_called()

    @unittest.skipUnless(shutil.which("codex"), "real Codex integration")
    def test_real_codex_two_homes_preserve_settings_and_rerun(self):
        for app in [False, True]:
            home = self.home / ("app" if app else "cli")
            home.mkdir()
            config = home / "config.toml"
            config.write_text('model = "gpt"\n[desktop]\nrunCodexInWindowsSubsystemForLinux = true\n[mcp_servers.unrelated]\ncommand = "echo"\nargs = ["keep"]\n')
            chrome.registration("codex", home, True, app=app)
            installed = config.read_bytes()
            for expected in [b'[mcp_servers.unrelated]', b'"keep"', b'runCodexInWindowsSubsystemForLinux = true', b'[mcp_servers.chrome-devtools-9223]']:
                self.assertIn(expected, installed)
            chrome.registration("codex", home, True, app=app)
            self.assertEqual(config.read_bytes(), installed)

    @unittest.skipUnless(shutil.which("codex"), "real Codex integration")
    def test_invalid_toml_preserved_with_diagnostic(self):
        config = self.home / "config.toml"
        config.write_text("[broken\n")
        result = subprocess.run(["python3", str(ROOT / "scripts/chrome-devtools-mcp.py"), "--codex-home", str(self.home), "--install"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config.toml", result.stderr)
        self.assertEqual(config.read_text(), "[broken\n")

    def test_connections_check_selected_port_and_reject_wrong_port(self):
        for port in [9222, 9223]:
            with patch.object(chrome.urllib.request, "build_opener") as factory:
                response = factory.return_value.open.return_value.__enter__.return_value
                response.read.return_value = json.dumps({"Browser": "Chrome/1", "webSocketDebuggerUrl": f"ws://127.0.0.1:{port}/devtools/browser/id"})
                chrome.connection(port)
                factory.return_value.open.assert_called_once_with(f"http://127.0.0.1:{port}/json/version", timeout=5)
                with self.assertRaises(ValueError):
                    chrome.connection(9223 if port == 9222 else 9222)
        with patch.object(chrome.urllib.request, "build_opener") as factory:
            factory.return_value.open.side_effect = OSError("refused")
            with self.assertRaises(OSError):
                chrome.connection(9223)


if __name__ == "__main__":
    unittest.main()
