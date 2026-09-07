#!/usr/bin/env python3
"""Register the requested CLI MCP configuration without replacing user settings."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request

NAME = "chrome-devtools"
ARGS = ["-y", "chrome-devtools-mcp@latest", "--browser-url=http://127.0.0.1:9222"]


def registration(codex, home, install=False):
    config = Path(home) / "config.toml"
    if config.is_symlink() or (config.exists() and not config.is_file()):
        raise ValueError("refusing non-regular Codex config.toml")
    env = dict(os.environ, CODEX_HOME=str(home))
    result = subprocess.run([codex, "mcp", "list", "--json"], env=env,
                            stdout=subprocess.PIPE, text=True, check=True)
    servers = json.loads(result.stdout)
    if not isinstance(servers, list) or any(not isinstance(s, dict) or not isinstance(s.get("name"), str) for s in servers):
        raise ValueError("invalid codex mcp list output")
    matches = [s for s in servers if s["name"] == NAME]
    if not matches:
        if not install:
            raise ValueError("chrome-devtools MCP is not registered")
        subprocess.run([codex, "mcp", "add", NAME, "--", "npx", *ARGS], env=env, check=True)
        return registration(codex, home)
    if len(matches) != 1:
        raise ValueError("duplicate chrome-devtools registration")
    server = matches[0]
    transport = server.get("transport", {})
    if (server.get("enabled") is not True or transport.get("type") != "stdio"
            or transport.get("command") != "npx" or transport.get("args") != ARGS
            or transport.get("env") not in (None, {})
            or transport.get("env_vars") not in (None, [])
            or transport.get("cwd") is not None):
        raise ValueError("chrome-devtools has different existing settings; refusing to overwrite")
    print("ok   chrome-devtools MCP registration (existing settings preserved)")


def connection():
    # Do not send local DevTools traffic to an HTTP proxy or follow redirects.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    with opener.open("http://127.0.0.1:9222/json/version", timeout=5) as response:
        data = json.load(response)
    if (not isinstance(data, dict) or not isinstance(data.get("Browser"), str)
            or not data["Browser"].startswith("Chrome/")
            or not isinstance(data.get("webSocketDebuggerUrl"), str)
            or not data["webSocketDebuggerUrl"].startswith("ws://127.0.0.1:9222/devtools/browser/")):
        raise ValueError("9222 did not return the expected Chrome DevTools endpoint")
    print("ok   Chrome DevTools connection: " + data["Browser"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--codex-home", default=os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--check-browser", action="store_true")
    args = parser.parse_args()
    registration(args.codex, args.codex_home, args.install)
    if args.check_browser:
        connection()


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
