#!/usr/bin/env python3
"""cockpit-ctl — the cockpit coordinator's CLI. Run it via scripts/cockpit-ctl (uses nvim's Python host venv).

Most commands run inside the cockpit nvim (lua/cockpit/ctl.lua) over its socket: $NVIM_LISTEN_ADDRESS, else the
address the cockpit last wrote to ~/.cockpit/coordinator/nvim (whichever nvim asked the coordinator last).
`ask` runs a one-off `claude -p` here and prints only its answer; `open` / `bridge` go through nvim_bridge.py.
Exit codes: 0 ok · 1 refused / failed · 64 usage · 70 internal error.
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DIR = Path(os.environ.get("COCKPIT_COORDINATOR_DIR", "~/.cockpit/coordinator")).expanduser()
ASKS = Path(os.environ.get("COCKPIT_ASKS_DIR", "~/.cockpit/asks")).expanduser()
BRIDGE_OK = {"open", "open_many", "harpoon_add", "harpoon_list", "mark", "trail", "scoped_grep", "buffers", "cursor", "state"}
ANSWER_LINES = 60
ASK_TOOLS = "Read,Grep,Glob"
# digests need no skills or MCP servers: keep their starting context small
ASK_LEAN = ["--strict-mcp-config", "--disable-slash-commands"]
ASK_PREAMBLE = (
    "You are a one-off helper for the cockpit coordinator (another Claude session). Answer the question concisely, "
    "in at most 40 lines: your answer is relayed verbatim into its context.\n\n"
)


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def nvim_addr():
    a = os.environ.get("NVIM_LISTEN_ADDRESS")
    if a and os.path.exists(a):
        return a
    f = DIR / "nvim"
    if f.exists():
        a = f.read_text().strip()
        if a and os.path.exists(a):
            return a
    die("cockpit-ctl: no cockpit nvim reachable (ask the coordinator from nvim once, or set NVIM_LISTEN_ADDRESS)")


def nvim_call(argv):
    import pynvim

    nv = pynvim.attach("socket", path=nvim_addr())
    try:
        res = nv.exec_lua('return require("cockpit.ctl").run(...)', argv)
    finally:
        nv.close()
    return res["code"], res["out"]


def slug(s, n=40):
    s = re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")
    return s[:n].rstrip("-") or "ask"


def clean_env():
    """A one-off is nobody's herdr agent: no herdr / inbox hooks, no tmux."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("HERDR_") and k not in ("TMUX", "TMUX_PANE")}
    env["COCKPIT_INBOX_HOOK"] = "0"
    env["COCKPIT_ASK"] = "1"
    return env


def cmd_ask(argv):
    fork = None
    if argv[:1] == ["--fork"]:
        if len(argv) < 2:
            die("usage: ask [--fork <agent>] <question>", 64)
        fork, argv = argv[1], argv[2:]
    question = " ".join(argv).strip()
    if not question:
        die("usage: ask [--fork <agent>] <question>", 64)
    # a plain digest runs on the cheap `digest` profile; a fork keeps the agent's own launch profile (model), so it
    # can reuse that conversation's prompt cache instead of re-reading it all on another model
    profile, extra, cwd, target = "digest", [], None, "one-off"
    if fork:
        code, out = nvim_call(["session", fork])
        if code != 0:
            die(out, code)
        s = json.loads(out)
        profile, extra = s.get("profile") or "default", ["--resume", s["session"], "--fork-session"]
        cwd, target = s.get("cwd"), "fork " + s["name"]
    code, out = nvim_call(["profile_args", profile])
    cmd = ["claude", "-p", "--output-format", "json", *json.loads(out if code == 0 else "[]"), *extra, *ASK_LEAN]
    cmd += ["--allowedTools", ASK_TOOLS]
    started = time.time()
    r = subprocess.run(
        cmd, input=ASK_PREAMBLE + question, capture_output=True, text=True, cwd=cwd, env=clean_env(), timeout=900
    )
    try:
        j = json.loads(r.stdout)
    except ValueError:
        die("ask failed: " + (r.stderr.strip() or r.stdout.strip() or f"claude exited {r.returncode}")[:500])
    answer = (j.get("result") or "").strip()
    ASKS.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S")
    path = ASKS / f"{stamp}-{slug(question)}.md"
    cost = j.get("total_cost_usd")
    path.write_text(
        f"# {question.splitlines()[0][:80]}\n\n"
        f"- asked: {time.strftime('%Y-%m-%d %H:%M')} · via: coordinator · target: {target}\n\n"
        f"## Question\n\n{question}\n\n## Answer\n\n{answer}\n\n"
        f"<!-- session: {j.get('session_id', '')} · cost: ${cost or 0:.2f} · {int(time.time() - started)}s -->\n"
    )
    lines = answer.splitlines()
    if len(lines) > ANSWER_LINES:
        lines = lines[:ANSWER_LINES] + [f"… truncated; full answer in {path}"]
    print("\n".join(lines))
    if j.get("is_error"):
        sys.exit(1)


def cmd_bridge(argv):
    if not argv or argv[0] not in BRIDGE_OK:
        die("bridge commands: " + " ".join(sorted(BRIDGE_OK)), 64)
    env = dict(os.environ, NVIM_LISTEN_ADDRESS=nvim_addr())
    sys.exit(subprocess.run([sys.executable, str(HERE / "nvim_bridge.py"), *argv], env=env).returncode)


def main():
    argv = sys.argv[1:]
    cmd = argv[0] if argv else "help"
    if cmd == "ask":
        return cmd_ask(argv[1:])
    if cmd == "open":
        return cmd_bridge(argv)
    if cmd == "bridge":
        return cmd_bridge(argv[1:])
    code, out = nvim_call(argv or ["help"])
    print(out, file=sys.stdout if code == 0 else sys.stderr)
    sys.exit(code)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:  # noqa: BLE001 — one line for the agent, not a traceback
        die(f"cockpit-ctl: internal error: {e}", 70)
