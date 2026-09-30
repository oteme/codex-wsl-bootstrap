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
INSTALLER = ROOT / "scripts/install-antigravity.py"
MARKER = ".codex-workstation-bootstrap-managed"
MANAGED = "config/hooks/codex-workstation-bootstrap"
HOOK_NAME = "codex-workstation-bootstrap-rtk"
# Managed file name -> fixture file in the hook source directory. The real hooks are not used.
SOURCES = {
    "rtk-codex-safe-hook.py": "rtk-codex-safe-hook.py",
    "rtk-antigravity-safe-hook.py": "rtk-antigravity-safe-hook.py",
    "test.sh": "test-rtk-antigravity-safe-hook.sh",
}
# Orca registers its own named hook in the same file.
ORCA = {
    "orca-status": {
        "SessionStart": [{"hooks": [{"type": "command", "command": "'/opt/orca/bin/orca-hook' status --event start", "timeout": 5}]}],
        "PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "'/opt/orca/bin/orca-hook' status --event tool"}]}],
    }
}
TEAM_ENTRY = {"path": "/opt/team skills", "include_only": ["lint"]}


def chrome(port):
    return {"command": "npx", "args": ["-y", "chrome-devtools-mcp@latest", f"--browser-url=http://127.0.0.1:{port}"]}


SERVERS = {"chrome-devtools": chrome(9222), "chrome-devtools-9223": chrome(9223)}


def managed_hook(managed):
    command = "/usr/bin/python3 -B " + shlex.quote(str(managed / "rtk-antigravity-safe-hook.py"))
    return {"PreToolUse": [{"matcher": "run_command", "hooks": [{"type": "command", "command": command, "timeout": 10}]}]}


def skills_entry(skills):
    return {"path": str(skills), "exclude": ["ralph-run"]}


def mode(path):
    return stat.S_IMODE(path.stat().st_mode)


def write(path, content, file_mode=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not isinstance(content, str):
        content = json.dumps(content, indent=2) + "\n"
    path.write_text(content, encoding="utf-8")
    if file_mode is not None:
        path.chmod(file_mode)


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


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


class AntigravityInstallTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.source = self.root / "hook source"
        for name in SOURCES.values():
            write(self.source / name, f"print('fixture {name}')\n")
        self.gemini = self.root / "home dir" / ".gemini"
        self.skills = self.root / "home dir" / ".codex" / "skills"

    def run_installer(self, gemini, *extra, cwd=None):
        # Options in extra come last, so they override the defaults.
        return subprocess.run(
            [sys.executable, str(INSTALLER), "--gemini-dir", str(gemini), "--codex-skills-dir", str(self.skills),
             "--hook-source-dir", str(self.source), *extra],
            capture_output=True, text=True, cwd=cwd)

    def install(self, gemini, *extra):
        result = self.run_installer(gemini, *extra)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return result

    def assertRefused(self, gemini, message, *extra, cwd=None):
        before = snapshot(self.root)
        result = self.run_installer(gemini, *extra, cwd=cwd)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(message, result.stderr)
        self.assertEqual(snapshot(self.root), before)

    def assertVerified(self, gemini):
        before = snapshot(self.root)
        self.install(gemini, "--verify")
        self.assertEqual(snapshot(self.root), before)

    def test_fresh_install_writes_managed_dir_hook_skills_and_servers(self):
        self.install(self.gemini)
        managed = self.gemini / MANAGED
        config = self.gemini / "config"
        self.assertEqual(sorted(path.name for path in managed.iterdir()),
                         sorted([*SOURCES, "skills-entry.json", MARKER]))
        for name, source in SOURCES.items():
            self.assertEqual((managed / name).read_bytes(), (self.source / source).read_bytes())
            self.assertEqual(mode(managed / name), 0o755)
        self.assertEqual((managed / "skills-entry.json").read_text(), json.dumps(skills_entry(self.skills), indent=2) + "\n")
        for name in ["skills-entry.json", MARKER]:
            self.assertEqual(mode(managed / name), 0o644)
        expected = {
            "hooks.json": {HOOK_NAME: managed_hook(managed)},
            "skills.json": {"entries": [skills_entry(self.skills)]},
            "mcp_config.json": {"mcpServers": SERVERS},
        }
        for name, data in expected.items():
            self.assertEqual((config / name).read_text(), json.dumps(data, indent=2) + "\n")
            self.assertEqual(mode(config / name), 0o644)

    def test_rerun_is_byte_identical_and_keeps_other_tools(self):
        config = self.gemini / "config"
        audit = {"PostToolUse": [{"matcher": "run_command", "hooks": [{"type": "command", "command": "echo audit"}]}]}
        other_entry = {"path": str(self.root / "other skills")}
        github = {"command": "gh-mcp", "env": {"TOKEN": "keep"}}
        write(config / "hooks.json", {**ORCA, "user-audit": audit}, 0o600)
        write(config / "skills.json", {"inherits": ["/opt/base"], "entries": [TEAM_ENTRY, other_entry], "extra": {"k": 1.5}}, 0o640)
        write(config / "mcp_config.json", {"mcpServers": {"github": github}, "extra": True}, 0o600)
        self.install(self.gemini)
        first = snapshot(self.root)
        self.install(self.gemini)
        self.assertEqual(snapshot(self.root), first)

        hooks = read(config / "hooks.json")
        self.assertEqual(list(hooks), ["orca-status", "user-audit", HOOK_NAME])
        self.assertEqual(hooks, {**ORCA, "user-audit": audit, HOOK_NAME: managed_hook(self.gemini / MANAGED)})
        skills = read(config / "skills.json")
        self.assertEqual(list(skills), ["inherits", "entries", "extra"])
        self.assertEqual(skills, {"inherits": ["/opt/base"], "entries": [TEAM_ENTRY, other_entry, skills_entry(self.skills)],
                                  "extra": {"k": 1.5}})
        mcp = read(config / "mcp_config.json")
        self.assertEqual(mcp, {"mcpServers": {"github": github, **SERVERS}, "extra": True})
        self.assertEqual(list(mcp["mcpServers"]), ["github", *SERVERS])
        self.assertEqual([mode(config / name) for name in ["hooks.json", "skills.json", "mcp_config.json"]], [0o600, 0o640, 0o600])

    def test_rerun_replaces_managed_hook_entry_and_files_in_place(self):
        self.install(self.gemini)
        config = self.gemini / "config"
        managed = self.gemini / MANAGED
        old_command = "/usr/bin/python3 " + shlex.quote(str(managed / "old-hook.py"))
        write(config / "hooks.json", {
            HOOK_NAME: {"PreToolUse": [{"matcher": "run_command", "hooks": [{"type": "command", "command": old_command, "timeout": 3}]}],
                        "PostToolUse": [{"hooks": [{"type": "command", "command": old_command}]}]},
            **ORCA,
        })
        recorded = {"path": str(self.skills), "exclude": ["ralph-run", "legacy"]}
        write(managed / "skills-entry.json", recorded)
        write(config / "skills.json", {"entries": [TEAM_ENTRY, recorded, {"path": "/opt/last"}]})
        write(managed / "rtk-antigravity-safe-hook.py", "tampered\n")
        (managed / "test.sh").chmod(0o600)
        write(self.source / "rtk-codex-safe-hook.py", "print('updated codex hook')\n")
        self.install(self.gemini)

        hooks = read(config / "hooks.json")
        self.assertEqual(list(hooks), [HOOK_NAME, "orca-status"])
        self.assertEqual(hooks, {HOOK_NAME: managed_hook(managed), **ORCA})
        self.assertEqual(read(config / "skills.json"), {"entries": [TEAM_ENTRY, skills_entry(self.skills), {"path": "/opt/last"}]})
        self.assertEqual(read(managed / "skills-entry.json"), skills_entry(self.skills))
        for name, source in SOURCES.items():
            self.assertEqual((managed / name).read_bytes(), (self.source / source).read_bytes())
            self.assertEqual(mode(managed / name), 0o755)

    def test_recorded_entry_follows_a_moved_codex_skills_dir(self):
        self.install(self.gemini)
        config = self.gemini / "config"
        write(config / "skills.json", {"entries": [skills_entry(self.skills), TEAM_ENTRY]})
        moved = self.root / "moved home" / ".codex" / "skills"
        self.install(self.gemini, "--codex-skills-dir", str(moved))
        self.assertEqual(read(config / "skills.json"), {"entries": [skills_entry(moved), TEAM_ENTRY]})
        self.assertEqual(read(self.gemini / MANAGED / "skills-entry.json"), skills_entry(moved))

    def test_empty_mcp_config_created_by_agy_means_no_servers(self):
        config = self.gemini / "config"
        write(config / "mcp_config.json", "", 0o600)
        self.install(self.gemini)
        self.assertEqual((config / "mcp_config.json").read_text(), json.dumps({"mcpServers": SERVERS}, indent=2) + "\n")
        self.assertEqual(mode(config / "mcp_config.json"), 0o600)

    def test_check_only_writes_nothing(self):
        before = snapshot(self.root)
        self.install(self.gemini, "--check-only")
        self.assertEqual(snapshot(self.root), before)
        self.assertFalse(self.gemini.exists())

        config = self.gemini / "config"
        write(config / "hooks.json", ORCA)
        write(config / "skills.json", {"entries": [TEAM_ENTRY]})
        write(config / "mcp_config.json", "")
        before = snapshot(self.root)
        self.install(self.gemini, "--check-only")
        self.assertEqual(snapshot(self.root), before)
        write(config / "skills.json", "")
        self.assertRefused(self.gemini, "refusing to replace invalid Antigravity skills file", "--check-only")

    def test_verify_accepts_only_the_hook_setup_writes(self):
        config = self.gemini / "config"
        write(config / "hooks.json", ORCA)
        self.install(self.gemini)
        self.assertVerified(self.gemini)
        # Orca's own entry does not matter.
        hook = managed_hook(self.gemini / MANAGED)
        write(config / "hooks.json", {HOOK_NAME: hook})
        self.assertVerified(self.gemini)

        entry = hook["PreToolUse"][0]
        handler = entry["hooks"][0]
        cases = [
            ("another timeout", {**ORCA, HOOK_NAME: {"PreToolUse": [{**entry, "hooks": [{**handler, "timeout": 30}]}]}}),
            ("another matcher", {**ORCA, HOOK_NAME: {"PreToolUse": [{**entry, "matcher": "*"}]}}),
            ("missing", ORCA),
            ("managed directory in another named hook", {**ORCA, HOOK_NAME: hook, "rtk-copy": hook}),
        ]
        for name, hooks in cases:
            with self.subTest(name):
                write(config / "hooks.json", hooks)
                self.assertRefused(self.gemini, "is not the one setup writes", "--verify")

    def test_refusals_change_nothing(self):
        def symlinked(name, content):
            def setup(gemini):
                target = gemini.parent / f"real {name}"
                write(target, content)
                replace_with_symlink(gemini / "config" / name, target)
            return setup

        def symlinked_dir(relative, marked):
            def setup(gemini):
                target = gemini.parent / "real dir"
                target.mkdir()
                if marked:
                    write(target / MARKER, "")
                replace_with_symlink(gemini / relative, target)
            return setup

        def text(name, content):
            return lambda gemini: write(gemini / "config" / name, content)

        def hook_key(value):
            return lambda gemini: write(gemini / "config/hooks.json", {**ORCA, HOOK_NAME: value})

        def ours_and(extra_command):
            def setup(gemini):
                ours = managed_hook(gemini / MANAGED)["PreToolUse"][0]
                other = {"matcher": "run_command", "hooks": [{"type": "command", "command": extra_command}]}
                write(gemini / "config/hooks.json", {HOOK_NAME: {"PreToolUse": [ours, other]}})
            return setup

        def unmarked_managed_dir(gemini):
            write(gemini / MANAGED / "user.txt", "mine\n")

        def invalid_record(gemini):
            write(gemini / MANAGED / MARKER, "managed by codex-workstation-bootstrap\n")
            write(gemini / MANAGED / "skills-entry.json", "{")

        def config_file(gemini):
            shutil.rmtree(gemini / "config")
            write(gemini / "config", "not a directory\n")

        foreign = {"PreToolUse": [{"matcher": "run_command", "hooks": [{"type": "command", "command": "/usr/bin/python3 /opt/other/hook.py"}]}]}
        cases = [
            ("symlinked hooks file", symlinked("hooks.json", ORCA), "refusing to replace symlinked Antigravity hooks file"),
            ("symlinked skills file", symlinked("skills.json", {"entries": []}), "refusing to replace symlinked Antigravity skills file"),
            ("symlinked MCP config", symlinked("mcp_config.json", ""), "refusing to replace symlinked Antigravity MCP config"),
            ("symlinked hooks directory", symlinked_dir("config/hooks", False), "refusing to use symlinked hooks directory"),
            ("symlinked managed directory", symlinked_dir(MANAGED, True), "refusing to overwrite unmanaged hook directory"),
            ("managed directory without marker", unmarked_managed_dir, "refusing to overwrite unmanaged hook directory"),
            ("config is a file", config_file, "refusing to use non-directory Antigravity config directory"),
            ("invalid recorded skills entry", invalid_record, "refusing to replace invalid recorded skills entry"),
            ("invalid hooks JSON", text("hooks.json", "{"), "refusing to replace invalid Antigravity hooks file"),
            ("empty hooks JSON", text("hooks.json", ""), "refusing to replace invalid Antigravity hooks file"),
            ("empty skills JSON", text("skills.json", ""), "refusing to replace invalid Antigravity skills file"),
            ("blank MCP config", text("mcp_config.json", "\n"), "refusing to replace invalid Antigravity MCP config"),
            ("MCP config with comment", text("mcp_config.json", '{\n  // added by agy\n  "mcpServers": {}\n}'),
             "remove // comments and trailing commas"),
            ("MCP config with trailing comma", text("mcp_config.json", '{"mcpServers": {"x": {"command": "x"},}}'),
             "remove // comments and trailing commas"),
            ("hooks not an object", text("hooks.json", "[]"), "refusing to replace Antigravity hooks file that is not a JSON object"),
            ("skills not an object", text("skills.json", '"entries"'), "refusing to replace Antigravity skills file that is not a JSON object"),
            ("MCP not an object", text("mcp_config.json", "[]"), "refusing to replace Antigravity MCP config that is not a JSON object"),
            ("entries object", text("skills.json", {"entries": {}}), '"entries" must be an array'),
            ("entry string", text("skills.json", {"entries": ["/opt/skills"]}), "entries must be objects"),
            ("mcpServers array", text("mcp_config.json", {"mcpServers": []}), '"mcpServers" must be an object'),
            ("different second server", text("mcp_config.json", {"mcpServers": {"chrome-devtools-9223": {**chrome(9223), "disabled": True}}}),
             "refusing to overwrite MCP server chrome-devtools-9223 with different existing settings"),
            ("different first server", text("mcp_config.json", {"mcpServers": {"chrome-devtools": {"command": "npx", "args": ["chrome-devtools-mcp@latest"]}}}),
             "refusing to overwrite MCP server chrome-devtools with different existing settings"),
            ("foreign hook with managed name", hook_key(foreign), f"refusing to replace hook {HOOK_NAME} that this bootstrap does not manage"),
            ("managed name without commands", hook_key({}), f"refusing to replace hook {HOOK_NAME} that this bootstrap does not manage"),
            ("managed name holding a string", hook_key("echo"), f"refusing to replace hook {HOOK_NAME} that this bootstrap does not manage"),
            ("managed name with an extra command", ours_and("echo audit"), f"refusing to replace hook {HOOK_NAME} that this bootstrap does not manage"),
            ("managed name in a sibling directory", lambda gemini: ours_and(
                "/usr/bin/python3 " + shlex.quote(str(gemini / MANAGED) + "-old/hook.py"))(gemini),
             f"refusing to replace hook {HOOK_NAME} that this bootstrap does not manage"),
            ("foreign entry with the same path", text("skills.json", {"entries": [{"path": str(self.skills)}]}),
             f"refusing to replace skills entry for {self.skills} that this bootstrap does not manage"),
            ("foreign entry with the same path and a trailing slash",
             text("skills.json", {"entries": [{"path": f"{self.skills}/", "exclude": ["ralph-run"]}]}),
             f"refusing to replace skills entry for {self.skills} that this bootstrap does not manage"),
        ]
        for index, (name, setup, message) in enumerate(cases):
            with self.subTest(name):
                gemini = self.root / f"case {index}" / ".gemini"
                write(gemini / "config/hooks.json", ORCA)
                write(gemini / "config/skills.json", {"entries": [TEAM_ENTRY]})
                write(gemini / "config/mcp_config.json", "")
                setup(gemini)
                self.assertRefused(gemini, message)
                self.assertRefused(gemini, message, "--check-only")

    def test_invalid_arguments_create_nothing(self):
        write(self.root / "gemini file", "not a directory\n")
        cases = [
            ("relative Codex skills directory", ["--codex-skills-dir", "relative/skills"], "--codex-skills-dir must be an absolute path"),
            ("relative Gemini directory", ["--gemini-dir", "relative/.gemini"], "--gemini-dir must be an absolute path"),
            ("missing hook source", ["--hook-source-dir", str(self.root / "missing")], "Antigravity hook source is missing"),
            ("Gemini directory is a file", ["--gemini-dir", str(self.root / "gemini file")], "refusing to use non-directory Gemini directory"),
        ]
        for name, extra, message in cases:
            with self.subTest(name):
                self.assertRefused(self.gemini, message, *extra, cwd=self.root)
                self.assertFalse(self.gemini.exists())
                self.assertFalse((self.root / "relative").exists())

    def test_hook_command_runs_from_paths_with_spaces_and_quotes(self):
        for gemini in [self.gemini, self.root / "it's a home" / ".gemini"]:
            with self.subTest(str(gemini)):
                self.install(gemini)
                first = snapshot(self.root)
                self.install(gemini)
                self.assertEqual(snapshot(self.root), first)
                hooks = read(gemini / "config/hooks.json")
                self.assertEqual(hooks, {HOOK_NAME: managed_hook(gemini / MANAGED)})
                command = hooks[HOOK_NAME]["PreToolUse"][0]["hooks"][0]["command"]
                result = subprocess.run(command, shell=True, capture_output=True, text=True)
                self.assertEqual((result.returncode, result.stdout), (0, "fixture rtk-antigravity-safe-hook.py\n"), result.stderr)


if __name__ == "__main__":
    unittest.main()
