#!/usr/bin/env python3
"""Register two Chrome profiles for CLI or WSL-backed App without replacing user settings."""
import argparse
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import urllib.request

SERVERS = {"chrome-devtools": 9222, "chrome-devtools-9223": 9223}


def server_args(port):
    return ["-y", "chrome-devtools-mcp@latest", f"--browser-url=http://127.0.0.1:{port}"]


def runtime(app):
    if not app:
        return "npx", {}
    search_path = str(Path.home() / ".local/bin") + ":" + os.environ.get("PATH", "")
    npx, node = shutil.which("npx", path=search_path), shutil.which("node", path=search_path)
    if not npx or not node:
        raise ValueError("App MCP requires working WSL node and npx on setup PATH")
    # App's WSL app-server does not inherit the user's interactive shell PATH.
    runtime_path = ":".join(dict.fromkeys([str(Path(node).parent), str(Path(npx).parent), "/usr/local/bin", "/usr/bin", "/bin"]))
    return npx, {"PATH": runtime_path}


def registration(codex, home, install=False, app=False, preflight=False):
    config = Path(home) / "config.toml"
    if config.is_symlink() or (config.exists() and not config.is_file()):
        raise ValueError("refusing non-regular Codex config.toml")
    env = dict(os.environ, CODEX_HOME=str(home))
    command, runtime_env = runtime(app)
    result = subprocess.run([codex, "mcp", "list", "--json"], env=env,
                            stdout=subprocess.PIPE, text=True, check=True)
    servers = json.loads(result.stdout)
    if not isinstance(servers, list) or any(not isinstance(s, dict) or not isinstance(s.get("name"), str) for s in servers):
        raise ValueError("invalid codex mcp list output")
    missing = []
    # Validate BOTH names before adding anything, including when the first is absent.
    for name, port in SERVERS.items():
        matches = [s for s in servers if s["name"] == name]
        if not matches:
            missing.append(name)
            continue
        if len(matches) != 1:
            raise ValueError(f"duplicate {name} registration")
        server = matches[0]
        transport = server.get("transport")
        if (server.get("enabled") is not True or not isinstance(transport, dict)
                or transport.get("type") != "stdio" or transport.get("command") != command
                or transport.get("args") != server_args(port)
                or (transport.get("env") or {}) != runtime_env
                or transport.get("env_vars") not in (None, [])
                or transport.get("cwd") is not None):
            raise ValueError(f"{name} has different existing settings; refusing to overwrite")
    if preflight:
        return
    if missing:
        if not install:
            raise ValueError(f"MCP is not registered: {', '.join(missing)}")
        for name in missing:
            add = [codex, "mcp", "add", name]
            for key, value in runtime_env.items():
                add += ["--env", f"{key}={value}"]
            subprocess.run([*add, "--", command, *server_args(SERVERS[name])], env=env, check=True)
        return registration(codex, home, app=app)
    print(f"ok   Chrome MCP registrations: 9222 + 9223 ({home})")


def connection(port):
    # Do not send local DevTools traffic to an HTTP proxy or follow redirects.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open(f"http://127.0.0.1:{port}/json/version", timeout=5) as response:
        data = json.load(response)
    if (not isinstance(data, dict) or not isinstance(data.get("Browser"), str)
            or not data["Browser"].startswith("Chrome/")
            or not isinstance(data.get("webSocketDebuggerUrl"), str)
            or not data["webSocketDebuggerUrl"].startswith(f"ws://127.0.0.1:{port}/devtools/browser/")):
        raise ValueError(f"{port} did not return the expected Chrome DevTools endpoint")
    print(f"ok   Chrome DevTools connection ({port}): " + data["Browser"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--codex-home", default=os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--check-browser", type=int, choices=SERVERS.values())
    parser.add_argument("--app", action="store_true")
    parser.add_argument("--preflight", action="store_true")
    args = parser.parse_args()
    registration(args.codex, args.codex_home, args.install, args.app, args.preflight)
    if args.check_browser:
        connection(args.check_browser)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
