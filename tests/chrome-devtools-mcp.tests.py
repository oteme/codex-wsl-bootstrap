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


class RegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.server = {"name": chrome.NAME, "enabled": True, "transport": {
            "type": "stdio", "command": "npx", "args": chrome.ARGS,
            "env": None, "env_vars": [], "cwd": None}}

    def output(self, servers):
        return subprocess.CompletedProcess([], 0, stdout=json.dumps(servers))

    def test_existing_registration_is_not_mutated(self):
        with patch.object(chrome.subprocess, "run", return_value=self.output([self.server])) as run:
            chrome.registration("codex", self.home, True)
            self.assertEqual(run.call_count, 1)

    def test_missing_adds_exact_command_and_verifies(self):
        with patch.object(chrome.subprocess, "run", side_effect=[self.output([]), self.output([]), self.output([self.server])]) as run:
            chrome.registration("codex", self.home, True)
            self.assertEqual(run.call_args_list[1].args[0], ["codex", "mcp", "add", chrome.NAME, "--", "npx", *chrome.ARGS])
            self.assertEqual(run.call_args_list[1].kwargs["env"]["CODEX_HOME"], str(self.home))

    def test_conflicting_and_disabled_settings_are_preserved(self):
        for field, value in [("command", "custom-npx"), ("args", []), ("env", {"X": "1"}), ("cwd", "/tmp"), ("env_vars", ["SECRET"]), ("type", "streamable_http")]:
            server = json.loads(json.dumps(self.server))
            server["transport"][field] = value
            with self.subTest(field=field), patch.object(chrome.subprocess, "run", return_value=self.output([server])) as run:
                with self.assertRaisesRegex(ValueError, "refusing to overwrite"):
                    chrome.registration("codex", self.home, True)
                self.assertEqual(run.call_count, 1)
        self.server["enabled"] = False
        with patch.object(chrome.subprocess, "run", return_value=self.output([self.server])):
            with self.assertRaises(ValueError):
                chrome.registration("codex", self.home, True)

    def test_invalid_list_missing_registration_and_failed_add(self):
        for servers in [{}, [None], [], [self.server, self.server]]:
            with self.subTest(servers=servers), patch.object(chrome.subprocess, "run", return_value=self.output(servers)):
                with self.assertRaises(ValueError):
                    chrome.registration("codex", self.home)
        with patch.object(chrome.subprocess, "run", side_effect=[self.output([]), subprocess.CalledProcessError(1, "codex")]):
            with self.assertRaises(subprocess.CalledProcessError):
                chrome.registration("codex", self.home, True)

    def test_symlink_fails_before_running_codex(self):
        (self.home / "config.toml").symlink_to(self.home / "missing")
        with patch.object(chrome.subprocess, "run") as run:
            with self.assertRaises(ValueError):
                chrome.registration("codex", self.home, True)
            run.assert_not_called()

    @unittest.skipUnless(shutil.which("codex"), "Codex CLI integration requires the real CLI")
    def test_real_codex_preserves_unrelated_config_and_is_idempotent(self):
        # Isolated fixture; never write to a workstation CODEX_HOME.
        config = self.home / "config.toml"
        config.write_text('model = "gpt"\n[mcp_servers.unrelated]\ncommand = "echo"\nargs = ["keep"]\n')
        chrome.registration("codex", self.home, True)
        installed = config.read_bytes()
        self.assertIn(b'[mcp_servers.unrelated]', installed)
        self.assertIn(b'"keep"', installed)
        chrome.registration("codex", self.home, True)
        self.assertEqual(config.read_bytes(), installed)

    @unittest.skipUnless(shutil.which("codex"), "Codex CLI integration requires the real CLI")
    def test_invalid_toml_preserved_with_diagnostic(self):
        config = self.home / "config.toml"
        config.write_text("[broken\n")
        before = config.read_bytes()
        result = subprocess.run(["python3", str(ROOT / "scripts/chrome-devtools-mcp.py"),
                                 "--codex-home", str(self.home), "--install"],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("config.toml", result.stderr)
        self.assertEqual(config.read_bytes(), before)

    def test_connection_fails_on_wrong_server_or_unreachable(self):
        for data in [{}, {"Browser": "Other/1"}, {"Browser": "Chrome/1", "webSocketDebuggerUrl": "ws://other:9222/devtools/browser/id"}]:
            with patch.object(chrome.urllib.request, "build_opener") as factory:
                factory.return_value.open.return_value.__enter__.return_value.read.return_value = json.dumps(data)
                with self.assertRaises(ValueError):
                    chrome.connection()
        with patch.object(chrome.urllib.request, "build_opener") as factory:
            factory.return_value.open.side_effect = OSError("refused")
            with self.assertRaises(OSError):
                chrome.connection()


if __name__ == "__main__":
    unittest.main()
