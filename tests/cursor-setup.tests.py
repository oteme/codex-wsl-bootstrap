import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "scripts/install-cursor.py"
MARKER = ".codex-workstation-bootstrap-managed"
MANAGED = "hooks/codex-workstation-bootstrap"
# Managed file name -> fixture file in the hook source directory. The real hooks are not used.
SOURCES = {
    "rtk-codex-safe-hook.py": "rtk-codex-safe-hook.py",
    "rtk-cursor-safe-hook.py": "rtk-cursor-safe-hook.py",
    "cursor-session-guidance.py": "cursor-session-guidance.py",
    "test.sh": "test-rtk-cursor-safe-hook.sh",
}
VALID_HOOKS = {"version": 1, "hooks": {"stop": [{"command": "echo stop"}]}}
VALID_MCP = {"mcpServers": {"github": {"command": "gh-mcp"}}}


def chrome(port):
    return {"command": "npx", "args": ["-y", "chrome-devtools-mcp@latest", f"--browser-url=http://127.0.0.1:{port}"]}


def managed_handlers(managed):
    def command(name):
        return "/usr/bin/python3 -B " + shlex.quote(str(managed / name))
    return {
        "preToolUse": {"command": command("rtk-cursor-safe-hook.py"), "matcher": "Shell", "timeout": 10, "failClosed": True},
        "sessionStart": {"command": command("cursor-session-guidance.py"), "timeout": 10},
    }


def mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def write(path, content, file_mode=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not isinstance(content, str):
        content = json.dumps(content, indent=2) + "\n"
    path.write_text(content, encoding="utf-8")
    if file_mode is not None:
        path.chmod(file_mode)


def replace_with_symlink(path, target):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.symlink_to(target)


def snapshot(root):
    # Type, mode and content of every path, without following symlinks.
    state = {}
    for directory, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            path = Path(directory, name)
            info = path.lstat()
            key = str(path.relative_to(root))
            if stat.S_ISLNK(info.st_mode):
                state[key] = ("symlink", os.readlink(path))
            elif stat.S_ISDIR(info.st_mode):
                state[key] = ("dir", stat.S_IMODE(info.st_mode))
            else:
                state[key] = ("file", stat.S_IMODE(info.st_mode), path.read_bytes())
    return state


class CursorInstallTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.source = self.root / "hook source"
        for name in SOURCES.values():
            write(self.source / name, f"print('fixture {name}')\n")
        self.guidance = self.root / "composed guidance.md"
        write(self.guidance, "## gstack\n\nfixture guidance\n")
        self.cursor = self.root / "home dir" / ".cursor"

    def run_installer(self, cursor, *extra, cwd=None):
        # Options in extra come last, so they override the defaults.
        return subprocess.run(
            [sys.executable, str(INSTALLER), "--cursor-dir", str(cursor), "--hook-source-dir", str(self.source),
             "--guidance-file", str(self.guidance), "--rtk-version", "0.46.0", *extra],
            capture_output=True, text=True, cwd=cwd)

    def install(self, cursor, *extra):
        result = self.run_installer(cursor, *extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return result

    def assertRefused(self, cursor, message, *extra, cwd=None):
        before = snapshot(self.root)
        result = self.run_installer(cursor, *extra, cwd=cwd)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(message, result.stderr)
        self.assertEqual(snapshot(self.root), before)

    def test_fresh_install_writes_managed_dir_hooks_and_servers(self):
        self.install(self.cursor)
        managed = self.cursor / MANAGED
        self.assertEqual(sorted(path.name for path in managed.iterdir()),
                         sorted([*SOURCES, "guidance.md", "rtk-version", MARKER]))
        for name, source in SOURCES.items():
            self.assertEqual((managed / name).read_bytes(), (self.source / source).read_bytes())
            self.assertEqual(mode(managed / name), 0o755)
        self.assertEqual((managed / "guidance.md").read_bytes(), self.guidance.read_bytes())
        self.assertEqual((managed / "rtk-version").read_text(), "0.46.0\n")
        for name in ["guidance.md", "rtk-version", MARKER]:
            self.assertEqual(mode(managed / name), 0o644)
        handlers = managed_handlers(managed)
        hooks = {"version": 1, "hooks": {event: [handler] for event, handler in handlers.items()}}
        self.assertEqual((self.cursor / "hooks.json").read_text(), json.dumps(hooks, indent=2) + "\n")
        mcp = {"mcpServers": {"chrome-devtools": chrome(9222), "chrome-devtools-9223": chrome(9223)}}
        self.assertEqual((self.cursor / "mcp.json").read_text(), json.dumps(mcp, indent=2) + "\n")
        self.assertEqual([mode(self.cursor / "hooks.json"), mode(self.cursor / "mcp.json")], [0o644, 0o644])

    def test_rerun_is_byte_identical_and_keeps_user_settings(self):
        user_hooks = {
            "version": 1,
            "note": {"owner": "user"},
            "hooks": {
                "stop": [{"command": "echo stop"}],
                "preToolUse": [{"command": "user-shell-guard", "matcher": "Shell", "timeout": 5}],
                "afterFileEdit": [],
            },
        }
        github = {"command": "gh-mcp", "env": {"TOKEN": "keep"}}
        extra = [1, 2.5, None, "日本語"]
        write(self.cursor / "hooks.json", user_hooks, 0o600)
        write(self.cursor / "mcp.json", {"mcpServers": {"github": github}, "extra": extra}, 0o640)
        self.install(self.cursor)
        first = snapshot(self.root)
        self.install(self.cursor)
        self.assertEqual(snapshot(self.root), first)

        handlers = managed_handlers(self.cursor / MANAGED)
        hooks = json.loads((self.cursor / "hooks.json").read_text())
        self.assertEqual(list(hooks), ["version", "note", "hooks"])
        self.assertEqual(hooks["note"], {"owner": "user"})
        self.assertEqual(hooks["hooks"], {
            "stop": [{"command": "echo stop"}],
            "preToolUse": [user_hooks["hooks"]["preToolUse"][0], handlers["preToolUse"]],
            "afterFileEdit": [],
            "sessionStart": [handlers["sessionStart"]],
        })
        self.assertEqual(list(hooks["hooks"]), ["stop", "preToolUse", "afterFileEdit", "sessionStart"])
        mcp = json.loads((self.cursor / "mcp.json").read_text())
        self.assertEqual(mcp, {"mcpServers": {"github": github, "chrome-devtools": chrome(9222),
                                              "chrome-devtools-9223": chrome(9223)}, "extra": extra})
        self.assertEqual(list(mcp["mcpServers"]), ["github", "chrome-devtools", "chrome-devtools-9223"])
        self.assertEqual([mode(self.cursor / "hooks.json"), mode(self.cursor / "mcp.json")], [0o600, 0o640])

    def test_rerun_replaces_managed_files_and_handlers(self):
        self.install(self.cursor)
        managed = self.cursor / MANAGED
        handlers = managed_handlers(managed)
        # A directory whose name only starts with the managed path is not managed.
        sibling = "/usr/bin/python3 " + shlex.quote(str(managed) + "-extra/hook.py")
        write(self.cursor / "hooks.json", {
            "version": 1,
            "hooks": {
                "preToolUse": [{"command": handlers["preToolUse"]["command"], "matcher": "*", "timeout": 99},
                               {"command": "user-shell-guard"}],
                "beforeShellExecution": [{"command": "/usr/bin/python3 " + shlex.quote(str(managed / "old-hook.py"))}],
                "sessionStart": [handlers["sessionStart"], handlers["sessionStart"]],
                "stop": [{"command": sibling}],
            },
        })
        write(managed / "rtk-cursor-safe-hook.py", "tampered\n")
        (managed / "test.sh").chmod(0o600)
        write(self.source / "rtk-codex-safe-hook.py", "print('updated codex hook')\n")
        write(self.guidance, "## gstack\n\nupdated guidance\n")
        self.install(self.cursor, "--rtk-version", "0.47.0")

        for name, source in SOURCES.items():
            self.assertEqual((managed / name).read_bytes(), (self.source / source).read_bytes())
            self.assertEqual(mode(managed / name), 0o755)
        self.assertEqual((managed / "guidance.md").read_text(), "## gstack\n\nupdated guidance\n")
        self.assertEqual((managed / "rtk-version").read_text(), "0.47.0\n")
        self.assertEqual(json.loads((self.cursor / "hooks.json").read_text())["hooks"], {
            "preToolUse": [{"command": "user-shell-guard"}, handlers["preToolUse"]],
            "beforeShellExecution": [],
            "sessionStart": [handlers["sessionStart"]],
            "stop": [{"command": sibling}],
        })

    def test_identical_server_is_kept_as_written(self):
        write(self.cursor / "mcp.json", {"mcpServers": {"chrome-devtools-9223": {"args": chrome(9223)["args"], "command": "npx"}}})
        self.install(self.cursor)
        servers = json.loads((self.cursor / "mcp.json").read_text())["mcpServers"]
        self.assertEqual(servers, {"chrome-devtools-9223": chrome(9223), "chrome-devtools": chrome(9222)})
        self.assertEqual(list(servers), ["chrome-devtools-9223", "chrome-devtools"])
        self.assertEqual(list(servers["chrome-devtools-9223"]), ["args", "command"])

    def test_check_only_writes_nothing(self):
        before = snapshot(self.root)
        self.install(self.cursor, "--check-only")
        self.assertEqual(snapshot(self.root), before)
        self.assertFalse(self.cursor.exists())

        write(self.cursor / "hooks.json", VALID_HOOKS)
        write(self.cursor / "mcp.json", VALID_MCP)
        before = snapshot(self.root)
        self.install(self.cursor, "--check-only")
        self.assertEqual(snapshot(self.root), before)
        write(self.cursor / "mcp.json", "{")
        self.assertRefused(self.cursor, "refusing to replace invalid Cursor MCP config", "--check-only")

    def test_refusals_change_nothing(self):
        def symlinked(name, content):
            def setup(cursor):
                target = cursor.parent / f"real {name}"
                write(target, content)
                replace_with_symlink(cursor / name, target)
            return setup

        def symlinked_dir(name, marked):
            def setup(cursor):
                target = cursor.parent / "real dir"
                target.mkdir()
                if marked:
                    write(target / MARKER, "")
                replace_with_symlink(cursor / name, target)
            return setup

        def text(name, content):
            return lambda cursor: write(cursor / name, content)

        def managed_with(name, directory=False):
            def setup(cursor):
                write(cursor / MANAGED / MARKER, "managed by codex-workstation-bootstrap\n")
                if directory:
                    (cursor / MANAGED / name).mkdir()
                else:
                    write(cursor / MANAGED / name, "user file\n")
            return setup

        def unmarked_managed_dir(cursor):
            write(cursor / MANAGED / "user.txt", "mine\n")

        def symlinked_marker(cursor):
            write(cursor.parent / "real marker", "")
            replace_with_symlink(cursor / MANAGED / MARKER, cursor.parent / "real marker")

        def hooks_json_dir(cursor):
            (cursor / "hooks.json").unlink()
            (cursor / "hooks.json").mkdir()

        cases = [
            ("symlinked hooks file", symlinked("hooks.json", VALID_HOOKS), "refusing to replace symlinked Cursor hooks file"),
            ("symlinked MCP config", symlinked("mcp.json", VALID_MCP), "refusing to replace symlinked Cursor MCP config"),
            ("symlinked hooks directory", symlinked_dir("hooks", False), "refusing to use symlinked hooks directory"),
            ("symlinked managed directory", symlinked_dir(MANAGED, True), "refusing to overwrite unmanaged hook directory"),
            ("managed directory without marker", unmarked_managed_dir, "refusing to overwrite unmanaged hook directory"),
            ("symlinked marker", symlinked_marker, "refusing to overwrite unmanaged hook directory"),
            ("managed file is a directory", managed_with("test.sh", directory=True), "refusing to replace non-regular managed file"),
            ("hooks path is a file", text("hooks", "not a directory\n"), "refusing to use non-directory hooks directory"),
            ("hooks file is a directory", hooks_json_dir, "refusing to replace non-regular Cursor hooks file"),
            ("invalid hooks JSON", text("hooks.json", "{"), "refusing to replace invalid Cursor hooks file"),
            ("empty hooks JSON", text("hooks.json", ""), "refusing to replace invalid Cursor hooks file"),
            ("hooks JSON with comment", text("hooks.json", '{"version": 1, // note\n"hooks": {}}'), "remove // comments and trailing commas"),
            ("hooks JSON with duplicate key", text("hooks.json", '{"version": 1, "hooks": {}, "hooks": {}}'), "duplicate key 'hooks'"),
            ("hooks JSON with NaN", text("hooks.json", '{"version": 1, "hooks": {}, "x": NaN}'), "non-standard JSON constant NaN"),
            ("hooks not an object", text("hooks.json", "[]"), "refusing to replace Cursor hooks file that is not a JSON object"),
            ("version 2", text("hooks.json", {"version": 2, "hooks": {}}), 'refusing to replace Cursor hooks file without "version": 1'),
            ("version missing", text("hooks.json", {"hooks": {}}), 'refusing to replace Cursor hooks file without "version": 1'),
            ("version true", text("hooks.json", {"version": True, "hooks": {}}), 'refusing to replace Cursor hooks file without "version": 1'),
            ("hooks array", text("hooks.json", {"version": 1, "hooks": []}), '"hooks" must be an object'),
            ("event object", text("hooks.json", {"version": 1, "hooks": {"stop": {"command": "x"}}}), "hooks.stop must be an array"),
            ("handler string", text("hooks.json", {"version": 1, "hooks": {"stop": ["echo"]}}), "hooks.stop entries must be objects"),
            ("invalid MCP JSON", text("mcp.json", '{"mcpServers": {},}'), "refusing to replace invalid Cursor MCP config"),
            ("MCP not an object", text("mcp.json", "[]"), "refusing to replace Cursor MCP config that is not a JSON object"),
            ("mcpServers array", text("mcp.json", {"mcpServers": []}), '"mcpServers" must be an object'),
            ("different second server", text("mcp.json", {"mcpServers": {"chrome-devtools-9223": {**chrome(9223), "env": {"DEBUG": "1"}}}}),
             "refusing to overwrite MCP server chrome-devtools-9223 with different existing settings"),
            ("different first server", text("mcp.json", {"mcpServers": {"chrome-devtools": chrome(9223)}}),
             "refusing to overwrite MCP server chrome-devtools with different existing settings"),
        ]
        for index, (name, setup, message) in enumerate(cases):
            with self.subTest(name):
                cursor = self.root / f"case {index}" / ".cursor"
                write(cursor / "hooks.json", VALID_HOOKS)
                write(cursor / "mcp.json", VALID_MCP)
                setup(cursor)
                self.assertRefused(cursor, message)
                self.assertRefused(cursor, message, "--check-only")

    def test_invalid_arguments_create_nothing(self):
        write(self.root / "empty guidance.md", "\n \n")
        write(self.root / "cursor file", "not a directory\n")
        cases = [
            ("relative Cursor directory", ["--cursor-dir", "relative/.cursor"], "--cursor-dir must be an absolute path"),
            ("missing hook source", ["--hook-source-dir", str(self.root / "missing")], "Cursor hook source is missing"),
            ("missing guidance", ["--guidance-file", str(self.root / "missing.md")], "Cursor guidance file is missing"),
            ("empty guidance", ["--guidance-file", str(self.root / "empty guidance.md")], "Cursor guidance file is empty"),
            ("empty RTK version", ["--rtk-version", ""], "invalid RTK version"),
            ("RTK version with space", ["--rtk-version", "0.46 0"], "invalid RTK version"),
            ("Cursor directory is a file", ["--cursor-dir", str(self.root / "cursor file")], "refusing to use non-directory Cursor directory"),
        ]
        for name, extra, message in cases:
            with self.subTest(name):
                self.assertRefused(self.cursor, message, *extra, cwd=self.root)
                self.assertFalse(self.cursor.exists())
                self.assertFalse((self.root / "relative").exists())

    def test_hook_commands_run_from_paths_with_spaces_and_quotes(self):
        for cursor in [self.cursor, self.root / "it's a home" / ".cursor"]:
            with self.subTest(str(cursor)):
                self.install(cursor)
                first = snapshot(self.root)
                self.install(cursor)
                self.assertEqual(snapshot(self.root), first)
                hooks = json.loads((cursor / "hooks.json").read_text())["hooks"]
                self.assertEqual({event: len(handlers) for event, handlers in hooks.items()},
                                 {"preToolUse": 1, "sessionStart": 1})
                for event, name in [("preToolUse", "rtk-cursor-safe-hook.py"), ("sessionStart", "cursor-session-guidance.py")]:
                    result = subprocess.run(hooks[event][0]["command"], shell=True, capture_output=True, text=True)
                    self.assertEqual((result.returncode, result.stdout), (0, f"fixture {name}\n"), result.stderr)


if __name__ == "__main__":
    unittest.main()
