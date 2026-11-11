# Cockpit Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the cockpit spine — inner tmux engine, git-tracked workspace, `cockpit` CLI (tracks, agents, status), the operator agent definition, the Documents/Records artifact model, and the steer loop — so a goal can be run end-to-end from the shell before the nvim hood exists.

**Architecture:** A Python CLI (`scripts/cockpit.py` + `scripts/cockpitlib/`) is the only writer of `~/.cockpit/` (one git repo, sessions as subdirs). Agents run as panes in an inner tmux server (`tmux -L cockpit`) tagged with per-pane user options; Claude Code hooks write per-pane JSON markers that the CLI reads for status. Documents/Records are markdown with YAML frontmatter; revisions are commits; steers are Records delivered by `send-keys`.

**Tech Stack:** Python 3.13 via `uv run` (inline deps: `pyyaml`, `pynvim`), tmux 3.6a, git, jq (hooks), Claude Code 2.1.250 (`--agent`, hooks), pytest (happy path only — Prototype tier).

**Spec:** `docs/superpowers/specs/2026-08-28-cockpit-design.md` (sections §3–§7, §9, §11, §12 steps 1–5). Plan 2 covers §8 (nvim hood).

## Global Constraints

- Quality tier: **Prototype** — happy-path tests only, error handling on critical paths only, no gold-plating.
- Inner tmux server socket name: `cockpit` (`tmux -L cockpit`); inner session name: `cockpit-<session>`; inner window per track named `<track>`; window `main` for the operator.
- Workspace root: `~/.cockpit/` (override with `$COCKPIT_ROOT` for tests). Session dir: `~/.cockpit/<session>/`.
- Worktrees: `~/dev/worktrees/<repo>/<branch>/` (override `$COCKPIT_WORKTREES`).
- Only the CLI commits; commits serialized by `fcntl.flock` on `~/.cockpit/.git/cockpit.lock`.
- Tracked: `STATE.md documents/ records/ annotations/ feedback.jsonl tracks/`; ignored: `*/logs/ */agents/ */events.jsonl */metrics.jsonl`.
- Document kinds: `research prd spec design adr plan codediff review digest`; Record kinds: `state tasks handoff context steer`.
- Ids: `<track>/<seq>` with two-digit zero-padded seq shared by documents and records of a track; filenames `<seq>-<kind>-<slug>.md`.
- Hook scripts always exit 0 (except `doc lint --hook`, which exits 2 to show a warning), write markers via tmp+rename, print nothing on `SessionStart`.
- Lua/Python style: 2-space Lua, PEP 8 Python, 120 cols; minimal comments (why, not what).
- Run all Python via `uv run scripts/cockpit.py …`; run tests via `uv run --with pytest --with pyyaml --with pynvim -m pytest tests -q` from the repo root (`~/.config/nvim`).
- Commit after each task in `~/.config/nvim` (branch `main`); messages `feat(cockpit): …`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `scripts/cockpit.py` | uv inline-metadata entry point; adds `scripts/` to `sys.path`, calls `cockpitlib.cli.main()` |
| `scripts/cockpitlib/__init__.py` | empty |
| `scripts/cockpitlib/paths.py` | root/session/worktree paths, session-name resolution, dir scaffolding |
| `scripts/cockpitlib/repo.py` | git init, `.gitignore`, locked commit |
| `scripts/cockpitlib/tmuxctl.py` | inner-server wrapper: ensure server/session/window, new pane with env + tags, list panes, send, pipe-pane, kill |
| `scripts/cockpitlib/state.py` | `STATE.md` render/parse, `snapshot` |
| `scripts/cockpitlib/tracks.py` | worktrees, `tracks/<name>/track.json`, symlinks, inner windows |
| `scripts/cockpitlib/agents.py` | spawn (pane mode), marker reading, status table |
| `scripts/cockpitlib/docs.py` | kinds table, templates, frontmatter, `new/save/lint/list/lineage` |
| `scripts/cockpitlib/steer.py` | annotations, `review send`, `feedback.jsonl` |
| `scripts/cockpitlib/cli.py` | argparse dispatch |
| `scripts/cockpitlib/templates/<kind>.md` | body templates (headings + one-line guidance) |
| `scripts/hooks/cockpit-marker.sh` | worker hook: event → `agents/<pane>.json`, `events.jsonl` |
| `scripts/hooks/cockpit-operator.sh` | operator hook: `PreCompact` → snapshot; `SessionStart(compact\|resume)` → print state |
| `scripts/hooks/install-cockpit-hooks.py` | merges hook entries into `~/.claude/settings.json` (backup first) |
| `scripts/cockpit-smoke.sh` | throwaway end-to-end run |
| `scripts/nvim_bridge.py` | add `--socket` / `--pane` global flags and `socket_for_pane()` |
| `~/.config/nix-darwin/dotfiles/.zshrc` | `vim` becomes a function with a per-pane socket |
| `~/.claude/agents/cockpit.md` | operator agent definition (system prompt + Stop hook) |
| `tests/conftest.py`, `tests/test_*.py` | happy-path tests with `COCKPIT_ROOT` pointed at a tmp dir |

---

### Task 1: Entry point, paths, and repo layer

**Files:**
- Create: `scripts/cockpit.py`, `scripts/cockpitlib/__init__.py`, `scripts/cockpitlib/paths.py`, `scripts/cockpitlib/repo.py`, `scripts/cockpitlib/cli.py`
- Test: `tests/conftest.py`, `tests/test_paths.py`, `tests/test_repo.py`

**Interfaces:**
- Produces: `paths.root() -> Path`, `paths.session_name() -> str`, `paths.session_dir(name=None) -> Path`, `paths.ensure_session_dirs(sdir: Path) -> None`, `paths.inner_session(name) -> str`, `paths.worktrees_root() -> Path`; `repo.ensure_repo() -> Path`, `repo.commit(paths: list[Path], message: str) -> bool`, `repo.head_short(path: Path) -> str`; `cli.main(argv=None)`.

- [ ] **Step 1: Write the failing tests**

`tests/conftest.py`:
```python
import os
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))


@pytest.fixture
def root(tmp_path, monkeypatch):
    monkeypatch.setenv("COCKPIT_ROOT", str(tmp_path / "cockpit"))
    monkeypatch.setenv("COCKPIT_SESSION", "demo")
    monkeypatch.setenv("COCKPIT_WORKTREES", str(tmp_path / "worktrees"))
    monkeypatch.delenv("TMUX", raising=False)
    monkeypatch.delenv("TMUX_PANE", raising=False)
    monkeypatch.setenv("GIT_AUTHOR_NAME", "t")
    monkeypatch.setenv("GIT_AUTHOR_EMAIL", "t@t")
    monkeypatch.setenv("GIT_COMMITTER_NAME", "t")
    monkeypatch.setenv("GIT_COMMITTER_EMAIL", "t@t")
    return tmp_path / "cockpit"
```

`tests/test_paths.py`:
```python
from cockpitlib import paths


def test_session_name_strips_inner_prefix(monkeypatch, root):
    monkeypatch.setenv("COCKPIT_SESSION", "cockpit-feat")
    assert paths.session_name() == "feat"


def test_session_dir_and_scaffold(root):
    sdir = paths.session_dir()
    paths.ensure_session_dirs(sdir)
    for sub in ("documents", "records", "annotations", "tracks", "agents", "logs"):
        assert (sdir / sub).is_dir()
    assert sdir == root / "demo"
    assert paths.inner_session("demo") == "cockpit-demo"
```

`tests/test_repo.py`:
```python
import subprocess

from cockpitlib import paths, repo


def test_init_and_commit(root):
    repo.ensure_repo()
    assert (root / ".git").is_dir()
    assert "*/logs/" in (root / ".gitignore").read_text()
    sdir = paths.session_dir()
    paths.ensure_session_dirs(sdir)
    f = sdir / "STATE.md"
    f.write_text("# x\n")
    assert repo.commit([f], "state: init") is True
    log = subprocess.check_output(["git", "-C", str(root), "log", "--oneline"], text=True)
    assert "state: init" in log
    assert repo.commit([f], "state: nothing") is False
    assert len(repo.head_short(f)) >= 7
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/.config/nvim && uv run --with pytest --with pyyaml --with pynvim -m pytest tests -q`
Expected: FAIL with `ModuleNotFoundError: No module named 'cockpitlib'`

- [ ] **Step 3: Write the entry point and paths**

`scripts/cockpit.py`:
```python
#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6", "pynvim>=0.5"]
# ///
"""cockpit — meta-harness CLI. See docs/superpowers/specs/2026-08-28-cockpit-design.md."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from cockpitlib.cli import main  # noqa: E402

if __name__ == "__main__":
    main()
```

`scripts/cockpitlib/__init__.py`: empty file.

`scripts/cockpitlib/paths.py`:
```python
import os
import subprocess
from pathlib import Path

INNER_SOCKET = "cockpit"
SESSION_SUBDIRS = ("documents", "records", "annotations", "tracks", "agents", "logs")


def root() -> Path:
    return Path(os.environ.get("COCKPIT_ROOT", Path.home() / ".cockpit")).expanduser()


def worktrees_root() -> Path:
    return Path(os.environ.get("COCKPIT_WORKTREES", Path.home() / "dev" / "worktrees")).expanduser()


def _outer_tmux_session() -> str | None:
    try:
        out = subprocess.run(
            ["tmux", "display-message", "-p", "#S"], capture_output=True, text=True, timeout=2
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    name = out.stdout.strip()
    return name or None


def session_name() -> str:
    """COCKPIT_SESSION wins; else the tmux session, with the inner `cockpit-` prefix stripped."""
    name = os.environ.get("COCKPIT_SESSION") or _outer_tmux_session() or "default"
    return name[len("cockpit-"):] if name.startswith("cockpit-") else name


def inner_session(name: str) -> str:
    return f"cockpit-{name}"


def session_dir(name: str | None = None) -> Path:
    return root() / (name or session_name())


def ensure_session_dirs(sdir: Path) -> None:
    for sub in SESSION_SUBDIRS:
        (sdir / sub).mkdir(parents=True, exist_ok=True)
```

- [ ] **Step 4: Write the repo layer**

`scripts/cockpitlib/repo.py`:
```python
import fcntl
import subprocess
from contextlib import contextmanager
from pathlib import Path

from . import paths

GITIGNORE = "*/logs/\n*/agents/\n*/events.jsonl\n*/metrics.jsonl\n"


def _git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(paths.root()), *args], capture_output=True, text=True, check=check)


@contextmanager
def _lock():
    lock_path = paths.root() / ".git" / "cockpit.lock"
    with open(lock_path, "w") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def ensure_repo() -> Path:
    r = paths.root()
    r.mkdir(parents=True, exist_ok=True)
    if not (r / ".git").is_dir():
        _git("init", "-q", "-b", "main")
    gi = r / ".gitignore"
    if not gi.exists():
        gi.write_text(GITIGNORE)
        with _lock():
            _git("add", ".gitignore")
            _git("commit", "-q", "-m", "cockpit: init")
    return r


def commit(files: list[Path], message: str) -> bool:
    """Stage the given paths and commit; False when nothing changed."""
    ensure_repo()
    rel = [str(Path(f).resolve().relative_to(paths.root().resolve())) for f in files]
    with _lock():
        _git("add", "-A", "--", *rel)
        staged = _git("diff", "--cached", "--quiet", check=False)
        if staged.returncode == 0:
            return False
        _git("commit", "-q", "-m", message)
    return True


def head_short(path: Path) -> str:
    """Short sha of the last commit touching path (or HEAD when untracked)."""
    rel = str(Path(path).resolve().relative_to(paths.root().resolve()))
    out = _git("log", "-1", "--format=%h", "--", rel, check=False).stdout.strip()
    return out or _git("rev-parse", "--short", "HEAD").stdout.strip()
```

- [ ] **Step 5: Write a minimal CLI skeleton**

`scripts/cockpitlib/cli.py`:
```python
import argparse
import subprocess
import sys

from . import paths, repo


def cmd_init(args):
    repo.ensure_repo()
    sdir = paths.session_dir()
    paths.ensure_session_dirs(sdir)
    print(sdir)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="cockpit", description="meta-harness CLI")
    sub = p.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("init", help="create the workspace for the current session")
    sp.add_argument("--goal", default=None)
    sp.set_defaults(fn=cmd_init)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        args.fn(args)
    except (subprocess.CalledProcessError, FileNotFoundError, ValueError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd ~/.config/nvim && uv run --with pytest --with pyyaml --with pynvim -m pytest tests -q`
Expected: `3 passed`

Also: `chmod +x scripts/cockpit.py && COCKPIT_ROOT=/tmp/cp-test COCKPIT_SESSION=demo scripts/cockpit.py init` prints `/tmp/cp-test/demo`; `git -C /tmp/cp-test log --oneline` shows `cockpit: init`. Then `rm -rf /tmp/cp-test`.

- [ ] **Step 7: Commit**

```bash
cd ~/.config/nvim && git add scripts/cockpit.py scripts/cockpitlib tests && git commit -m "feat(cockpit): entry point, paths, git tracking layer"
```

---

### Task 2: Inner tmux engine wrapper

**Files:**
- Create: `scripts/cockpitlib/tmuxctl.py`
- Test: manual (tmux is not exercised in pytest; the smoke script in Task 10 covers it)

**Interfaces:**
- Produces: `tmuxctl.tmx(*args) -> str`, `tmuxctl.ensure_server() -> None`, `tmuxctl.ensure_session(inner: str, cwd: Path) -> None`, `tmuxctl.has_window(inner, name) -> bool`, `tmuxctl.new_pane(inner, window, cwd, cmd, env: dict, tags: dict) -> str`, `tmuxctl.list_panes(inner) -> list[dict]`, `tmuxctl.send(pane, text)`, `tmuxctl.pipe_log(pane, path)`, `tmuxctl.kill(pane)`, `tmuxctl.kill_window(inner, name)`, `tmuxctl.attach_cmd(inner, window) -> str`.
- Pane dict keys: `pane_id window role track title pid dead`.

- [ ] **Step 1: Write the wrapper**

`scripts/cockpitlib/tmuxctl.py`:
```python
import shlex
import subprocess
from pathlib import Path

from .paths import INNER_SOCKET

PANE_FMT = "#{pane_id}\t#{window_name}\t#{@cockpit_role}\t#{@cockpit_track}\t#{pane_title}\t#{pane_pid}\t#{pane_dead}"


def tmx(*args: str, check: bool = True) -> str:
    out = subprocess.run(["tmux", "-L", INNER_SOCKET, *args], capture_output=True, text=True)
    if check and out.returncode != 0:
        raise subprocess.CalledProcessError(out.returncode, args, out.stdout, out.stderr)
    return out.stdout


def ensure_server() -> None:
    """Inner server: no prefix, no status bar — it is an engine, not a UI."""
    if subprocess.run(["tmux", "-L", INNER_SOCKET, "has-session"], capture_output=True).returncode != 0:
        tmx("new-session", "-d", "-s", "_cockpit", "-x", "200", "-y", "50")
    tmx("set", "-g", "prefix", "None")
    tmx("set", "-g", "status", "off")
    tmx("set", "-g", "history-limit", "5000")
    tmx("set", "-g", "escape-time", "10")
    tmx("set", "-g", "focus-events", "on")
    tmx("set", "-g", "allow-passthrough", "on")


def ensure_session(inner: str, cwd: Path) -> None:
    ensure_server()
    if subprocess.run(["tmux", "-L", INNER_SOCKET, "has-session", "-t", f"={inner}"], capture_output=True).returncode != 0:
        tmx("new-session", "-d", "-s", inner, "-n", "main", "-c", str(cwd))


def has_window(inner: str, name: str) -> bool:
    names = tmx("list-windows", "-t", f"={inner}", "-F", "#{window_name}").split()
    return name in names


def new_pane(inner: str, window: str, cwd: Path, cmd: str, env: dict, tags: dict) -> str:
    """Create the window if needed (running cmd), else split it; returns the new pane id."""
    env_flags = [x for k, v in env.items() for x in ("-e", f"{k}={v}")]
    if has_window(inner, window):
        pane = tmx("split-window", "-d", "-P", "-F", "#{pane_id}", "-t", f"={inner}:{window}", "-c", str(cwd),
                   *env_flags, cmd).strip()
        tmx("select-layout", "-t", f"={inner}:{window}", "tiled")
    else:
        pane = tmx("new-window", "-d", "-P", "-F", "#{pane_id}", "-t", f"={inner}:", "-n", window, "-c", str(cwd),
                   *env_flags, cmd).strip()
    for k, v in tags.items():
        tmx("set", "-p", "-t", pane, f"@cockpit_{k}", str(v))
    tmx("set", "-p", "-t", pane, "remain-on-exit", "on")
    return pane


def list_panes(inner: str) -> list[dict]:
    rows = []
    out = tmx("list-panes", "-s", "-t", f"={inner}", "-F", PANE_FMT, check=False)
    for line in out.splitlines():
        pane_id, window, role, track, title, pid, dead = line.split("\t")
        rows.append({"pane_id": pane_id, "window": window, "role": role, "track": track,
                     "title": title, "pid": int(pid or 0), "dead": dead == "1"})
    return rows


def send(pane: str, text: str, enter: bool = True) -> None:
    tmx("send-keys", "-t", pane, "-l", text)
    if enter:
        tmx("send-keys", "-t", pane, "Enter")


def pipe_log(pane: str, path: Path) -> None:
    tmx("pipe-pane", "-o", "-t", pane, f"cat >> {shlex.quote(str(path))}")


def kill(pane: str) -> None:
    tmx("kill-pane", "-t", pane)


def kill_window(inner: str, name: str) -> None:
    tmx("kill-window", "-t", f"={inner}:{name}", check=False)


def attach_cmd(inner: str, window: str) -> str:
    return f"tmux -L {INNER_SOCKET} attach -t ={inner}:{window}"
```

- [ ] **Step 2: Verify manually**

Run:
```bash
cd ~/.config/nvim && uv run --with pyyaml --with pynvim python -c "
import sys; sys.path.insert(0,'scripts')
from pathlib import Path
from cockpitlib import tmuxctl as t
t.ensure_session('cockpit-demo', Path.home())
p = t.new_pane('cockpit-demo', 'feat-x', Path.home(), 'sleep 30', {'COCKPIT_TRACK':'feat-x'}, {'role':'impl','track':'feat-x'})
print(p, t.list_panes('cockpit-demo'))
t.kill_window('cockpit-demo','feat-x'); t.tmx('kill-session','-t','=cockpit-demo')"
```
Expected: prints a pane id like `%3` and a list containing `{'pane_id': '%3', 'window': 'feat-x', 'role': 'impl', 'track': 'feat-x', ...}`. `tmux -L cockpit show -g prefix` prints `prefix None`.

- [ ] **Step 3: Commit**

```bash
cd ~/.config/nvim && git add scripts/cockpitlib/tmuxctl.py && git commit -m "feat(cockpit): inner tmux engine wrapper"
```

---

### Task 3: STATE.md render/parse and `state set` / `snapshot`

**Files:**
- Create: `scripts/cockpitlib/state.py`
- Modify: `scripts/cockpitlib/cli.py` (add `state`, `snapshot`, `log`, extend `init --goal`)
- Test: `tests/test_state.py`

**Interfaces:**
- Consumes: `paths`, `repo.commit`.
- Produces: `state.load(sdir) -> dict` with keys `goal: str, decisions: list[str], next: list[str]`; `state.render(sdir, tracks: list[dict], agents: list[dict]) -> str`; `state.write(sdir, tracks, agents, message) -> Path`; `state.set_field(sdir, field, value)`.
- Track dict (from Task 4): `{name, branch, repos: [{name, path, worktree}], window}`. Agent dict (from Task 5): `{pane_id, role, track, status, title, updated}`.

- [ ] **Step 1: Write the failing test**

`tests/test_state.py`:
```python
from cockpitlib import paths, repo, state


def test_roundtrip_and_set(root):
    repo.ensure_repo()
    sdir = paths.session_dir()
    paths.ensure_session_dirs(sdir)
    state.set_field(sdir, "goal", "Ship worktree tracks")
    state.set_field(sdir, "decision", "one window per track")
    state.set_field(sdir, "next", "spawn reviewer")
    data = state.load(sdir)
    assert data["goal"] == "Ship worktree tracks"
    assert data["decisions"] == ["one window per track"]
    assert data["next"] == ["spawn reviewer"]
    text = state.render(sdir, tracks=[{"name": "feat-x", "branch": "feat/x", "repos": [{"name": "r"}], "window": "feat-x"}],
                        agents=[{"pane_id": "%3", "role": "impl", "track": "feat-x", "status": "working",
                                 "title": "editing", "updated": "12:00"}])
    assert "| feat-x | r | feat/x |" in text
    assert "| %3 | impl | feat-x | working |" in text
    assert state.load(sdir)["goal"] == "Ship worktree tracks"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/.config/nvim && uv run --with pytest --with pyyaml --with pynvim -m pytest tests/test_state.py -q`
Expected: FAIL with `cannot import name 'state'`

- [ ] **Step 3: Implement state.py**

`scripts/cockpitlib/state.py`:
```python
import re
from datetime import datetime
from pathlib import Path

from . import repo

SECTIONS = ("Goal", "Tracks", "Agents", "Decisions", "Next")


def _sections(text: str) -> dict[str, str]:
    out, cur = {}, None
    for line in text.splitlines():
        m = re.match(r"^## (\w+)\s*$", line)
        if m:
            cur = m.group(1)
            out[cur] = ""
        elif cur:
            out[cur] += line + "\n"
    return out


def _bullets(block: str) -> list[str]:
    return [re.sub(r"^- (\[.\] )?", "", l).strip() for l in block.splitlines() if l.startswith("- ")]


def load(sdir: Path) -> dict:
    f = sdir / "STATE.md"
    if not f.exists():
        return {"goal": "", "decisions": [], "next": []}
    s = _sections(f.read_text())
    return {"goal": s.get("Goal", "").strip(), "decisions": _bullets(s.get("Decisions", "")),
            "next": _bullets(s.get("Next", ""))}


def render(sdir: Path, tracks: list[dict], agents: list[dict]) -> str:
    d = load(sdir)
    lines = [f"# Cockpit — {sdir.name}", "", f"_updated {datetime.now():%Y-%m-%d %H:%M}_", "",
             "## Goal", "", d["goal"] or "_unset_", "",
             "## Tracks", "", "| track | repos | branch | window |", "|---|---|---|---|"]
    for t in tracks:
        lines.append(f"| {t['name']} | {', '.join(r['name'] for r in t['repos'])} | {t['branch']} | {t['window']} |")
    lines += ["", "## Agents", "", "| pane | role | track | status | title | updated |", "|---|---|---|---|---|---|"]
    for a in agents:
        lines.append(f"| {a['pane_id']} | {a['role']} | {a['track']} | {a['status']} | {a['title']} | {a['updated']} |")
    lines += ["", "## Decisions", ""] + [f"- {x}" for x in d["decisions"]]
    lines += ["", "## Next", ""] + [f"- [ ] {x}" for x in d["next"]] + [""]
    return "\n".join(lines)


def write(sdir: Path, tracks: list[dict], agents: list[dict], message: str) -> Path:
    f = sdir / "STATE.md"
    f.write_text(render(sdir, tracks, agents))
    repo.commit([f], message)
    return f


def set_field(sdir: Path, field: str, value: str) -> None:
    """field: goal (replace) | decision | next (append). Re-renders with current tracks/agents."""
    d = load(sdir)
    if field == "goal":
        d["goal"] = value
    elif field == "decision":
        d["decisions"].append(value)
    elif field == "next":
        d["next"].append(value)
    else:
        raise ValueError(f"unknown field {field}")
    f = sdir / "STATE.md"
    text = render(sdir, tracks=_current_tracks(sdir), agents=_current_agents(sdir))
    # render() reads the old file; splice the new field values in
    s = _sections(text)
    s["Goal"] = f"\n{d['goal'] or '_unset_'}\n\n"
    s["Decisions"] = "\n" + "".join(f"- {x}\n" for x in d["decisions"]) + "\n"
    s["Next"] = "\n" + "".join(f"- [ ] {x}\n" for x in d["next"]) + "\n"
    head = text.split("## Goal")[0]
    f.write_text(head + "".join(f"## {k}\n{s.get(k, '')}" for k in SECTIONS))
    repo.commit([f], f"state: {field} — {value[:60]}")


def _current_tracks(sdir: Path) -> list[dict]:
    from . import tracks  # local import: tracks depends on state for snapshot
    return tracks.list_tracks(sdir)


def _current_agents(sdir: Path) -> list[dict]:
    from . import agents
    return agents.list_agents(sdir, live=False)
```

Note: `tracks.list_tracks` and `agents.list_agents` arrive in Tasks 4–5. Until then add these two temporary stubs at the bottom of `state.py` and **delete them in Task 5**:
```python
def _current_tracks(sdir: Path) -> list[dict]:  # TEMP until Task 4
    return []


def _current_agents(sdir: Path) -> list[dict]:  # TEMP until Task 5
    return []
```
(Keep only one definition of each function in the file — use the stubs now, replace with the real ones above in Task 5.)

- [ ] **Step 4: Wire CLI verbs**

In `scripts/cockpitlib/cli.py` add:
```python
from . import state


def cmd_init(args):
    repo.ensure_repo()
    sdir = paths.session_dir()
    paths.ensure_session_dirs(sdir)
    if args.goal:
        state.set_field(sdir, "goal", args.goal)
    elif not (sdir / "STATE.md").exists():
        state.write(sdir, [], [], "state: init")
    print(sdir)


def cmd_state(args):
    state.set_field(paths.session_dir(), args.field, " ".join(args.value))


def cmd_snapshot(args):
    from . import agents, tracks
    sdir = paths.session_dir()
    state.write(sdir, tracks.list_tracks(sdir), agents.list_agents(sdir), "snapshot: " + (args.reason or "manual"))
    print(sdir / "STATE.md")


def cmd_log(args):
    import subprocess
    rel = str(paths.session_dir().relative_to(paths.root()))
    subprocess.run(["git", "-C", str(paths.root()), "log", "--oneline", f"-{args.n}", "--", rel])
```
and in `build_parser()`:
```python
    sp = sub.add_parser("state"); sp.add_argument("op", choices=["set"]); sp.add_argument("field", choices=["goal", "decision", "next"])
    sp.add_argument("value", nargs="+"); sp.set_defaults(fn=cmd_state)
    sp = sub.add_parser("snapshot"); sp.add_argument("--reason", default=None); sp.set_defaults(fn=cmd_snapshot)
    sp = sub.add_parser("log"); sp.add_argument("-n", type=int, default=20); sp.set_defaults(fn=cmd_log)
```
(`cmd_snapshot` imports `tracks`/`agents`, which exist after Task 5; `init`, `state`, `log` work now.)

- [ ] **Step 5: Run tests**

Run: `cd ~/.config/nvim && uv run --with pytest --with pyyaml --with pynvim -m pytest tests -q`
Expected: `4 passed`

- [ ] **Step 6: Commit**

```bash
cd ~/.config/nvim && git add scripts/cockpitlib && git commit -m "feat(cockpit): STATE.md render/parse, state set, log"
```

---

### Task 4: Tracks — worktrees, track dirs, inner windows

**Files:**
- Create: `scripts/cockpitlib/tracks.py`
- Modify: `scripts/cockpitlib/cli.py`, `scripts/cockpitlib/state.py` (swap `_current_tracks` stub for the real import)
- Test: `tests/test_tracks.py`

**Interfaces:**
- Consumes: `paths`, `repo.commit`, `tmuxctl.ensure_session/has_window/kill_window`.
- Produces: `tracks.resolve_repo(spec: str) -> Path`, `tracks.add(sdir, name, repos: list[str], branch: str|None, base: str, tmux: bool=True) -> dict`, `tracks.list_tracks(sdir) -> list[dict]`, `tracks.get(sdir, name) -> dict`, `tracks.remove(sdir, name, remove_worktrees: bool)`, `tracks.primary_worktree(track: dict, primary: str|None) -> Path`.
- Track dict: `{name, branch, window, repos: [{name, path, worktree}]}` persisted at `tracks/<name>/track.json`; symlink `tracks/<name>/<repo>` → worktree.

- [ ] **Step 1: Write the failing test**

`tests/test_tracks.py`:
```python
import json
import subprocess

from cockpitlib import paths, repo, tracks


def _mkrepo(path):
    path.mkdir(parents=True)
    subprocess.run(["git", "-C", str(path), "init", "-q", "-b", "main"], check=True)
    (path / "README.md").write_text("hi\n")
    subprocess.run(["git", "-C", str(path), "add", "."], check=True)
    subprocess.run(["git", "-C", str(path), "commit", "-q", "-m", "init"], check=True)


def test_add_creates_worktrees_and_symlinks(root, tmp_path):
    repo.ensure_repo()
    sdir = paths.session_dir()
    paths.ensure_session_dirs(sdir)
    r1, r2 = tmp_path / "src" / "alpha", tmp_path / "src" / "beta"
    _mkrepo(r1)
    _mkrepo(r2)
    t = tracks.add(sdir, "feat-x", [str(r1), str(r2)], branch="feat/x", base="main", tmux=False)
    assert t["branch"] == "feat/x" and t["window"] == "feat-x"
    wt = paths.worktrees_root() / "alpha" / "feat_x"
    assert wt.is_dir() and (wt / "README.md").exists()
    assert (sdir / "tracks" / "feat-x" / "alpha").resolve() == wt.resolve()
    saved = json.loads((sdir / "tracks" / "feat-x" / "track.json").read_text())
    assert [r["name"] for r in saved["repos"]] == ["alpha", "beta"]
    assert tracks.list_tracks(sdir)[0]["name"] == "feat-x"
    assert tracks.primary_worktree(t, None) == wt
    tracks.remove(sdir, "feat-x", remove_worktrees=True, tmux=False)
    assert not (sdir / "tracks" / "feat-x").exists() and not wt.exists()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/.config/nvim && uv run --with pytest --with pyyaml --with pynvim -m pytest tests/test_tracks.py -q`
Expected: FAIL with `cannot import name 'tracks'`

- [ ] **Step 3: Implement tracks.py**

`scripts/cockpitlib/tracks.py`:
```python
import json
import shutil
import subprocess
from pathlib import Path

from . import paths, repo, tmuxctl

REPO_SEARCH = [Path.home() / "dev", Path.home() / "dev" / "lilt"]


def resolve_repo(spec: str) -> Path:
    p = Path(spec).expanduser()
    if p.is_dir() and (p / ".git").exists():
        return p.resolve()
    for base in REPO_SEARCH:
        cand = base / spec
        if (cand / ".git").exists():
            return cand.resolve()
    raise FileNotFoundError(f"repo not found: {spec}")


def _git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(cwd), *args], capture_output=True, text=True, check=True).stdout


def _worktree_for(repo_path: Path, branch: str, base: str) -> Path:
    wt = paths.worktrees_root() / repo_path.name / branch.replace("/", "_")
    if wt.exists():
        return wt
    wt.parent.mkdir(parents=True, exist_ok=True)
    branches = _git(repo_path, "branch", "--list", branch).strip()
    if branches:
        _git(repo_path, "worktree", "add", str(wt), branch)
    else:
        _git(repo_path, "worktree", "add", "-b", branch, str(wt), base)
    return wt


def _track_dir(sdir: Path, name: str) -> Path:
    return sdir / "tracks" / name


def add(sdir: Path, name: str, repos: list[str], branch: str | None, base: str = "main", tmux: bool = True) -> dict:
    branch = branch or f"cockpit/{name}"
    tdir = _track_dir(sdir, name)
    tdir.mkdir(parents=True, exist_ok=True)
    entries = []
    for spec in repos:
        rp = resolve_repo(spec)
        wt = _worktree_for(rp, branch, base)
        link = tdir / rp.name
        if not link.exists():
            link.symlink_to(wt)
        entries.append({"name": rp.name, "path": str(rp), "worktree": str(wt)})
    track = {"name": name, "branch": branch, "window": name, "repos": entries}
    (tdir / "track.json").write_text(json.dumps(track, indent=2) + "\n")
    if tmux:
        inner = paths.inner_session(sdir.name)
        tmuxctl.ensure_session(inner, sdir)
        if not tmuxctl.has_window(inner, name):
            tmuxctl.tmx("new-window", "-d", "-t", f"={inner}:", "-n", name, "-c", str(Path(entries[0]["worktree"])))
    repo.commit([tdir], f"track({name}): add {', '.join(e['name'] for e in entries)} @ {branch}")
    return track


def get(sdir: Path, name: str) -> dict:
    f = _track_dir(sdir, name) / "track.json"
    if not f.exists():
        raise FileNotFoundError(f"track not found: {name}")
    return json.loads(f.read_text())


def list_tracks(sdir: Path) -> list[dict]:
    tdir = sdir / "tracks"
    if not tdir.exists():
        return []
    return [json.loads(f.read_text()) for f in sorted(tdir.glob("*/track.json"))]


def primary_worktree(track: dict, primary: str | None) -> Path:
    for r in track["repos"]:
        if primary is None or r["name"] == primary:
            return Path(r["worktree"])
    raise ValueError(f"repo {primary} not in track {track['name']}")


def remove(sdir: Path, name: str, remove_worktrees: bool = False, tmux: bool = True) -> None:
    track = get(sdir, name)
    if tmux:
        tmuxctl.kill_window(paths.inner_session(sdir.name), name)
    if remove_worktrees:
        for r in track["repos"]:
            _git(Path(r["path"]), "worktree", "remove", "--force", r["worktree"])
    tdir = _track_dir(sdir, name)
    shutil.rmtree(tdir)
    repo.commit([sdir / "tracks"], f"track({name}): rm")
```

- [ ] **Step 4: Wire CLI verbs and state**

In `cli.py`:
```python
from . import tracks


def cmd_track(args):
    sdir = paths.session_dir()
    if args.op == "add":
        t = tracks.add(sdir, args.name, args.repo, args.branch, args.base)
        print(json.dumps(t, indent=2))
    elif args.op == "rm":
        tracks.remove(sdir, args.name, remove_worktrees=args.worktrees)
    elif args.op == "list":
        for t in tracks.list_tracks(sdir):
            print(f"{t['name']}\t{t['branch']}\t{','.join(r['name'] for r in t['repos'])}")
    elif args.op == "pick":
        import subprocess
        candidates = []
        for base in tracks.REPO_SEARCH:
            for g in base.glob("*/.git"):
                out = subprocess.run(["git", "-C", str(g.parent), "worktree", "list", "--porcelain"],
                                     capture_output=True, text=True).stdout
                wt = None
                for line in out.splitlines():
                    if line.startswith("worktree "):
                        wt = line[9:]
                    elif line.startswith("branch ") and wt and wt != str(g.parent):
                        candidates.append(f"{g.parent.name}\t{line[18:]}\t{wt}")
        pick = subprocess.run(["fzf"], input="\n".join(candidates), capture_output=True, text=True).stdout.strip()
        if pick:
            rname, branch, _ = pick.split("\t")
            print(json.dumps(tracks.add(sdir, args.name or branch.replace("/", "-"), [rname], branch, "main"), indent=2))
```
parser:
```python
    sp = sub.add_parser("track"); sp.add_argument("op", choices=["add", "rm", "list", "pick"]); sp.add_argument("name", nargs="?")
    sp.add_argument("--repo", action="append", default=[]); sp.add_argument("--branch"); sp.add_argument("--from", dest="base", default="main")
    sp.add_argument("--worktrees", action="store_true", help="rm: also remove git worktrees"); sp.set_defaults(fn=cmd_track)
```
Add `import json` at the top of `cli.py`. In `state.py`, replace the TEMP `_current_tracks` stub with:
```python
def _current_tracks(sdir: Path) -> list[dict]:
    from . import tracks
    return tracks.list_tracks(sdir)
```

- [ ] **Step 5: Run tests**

Run: `cd ~/.config/nvim && uv run --with pytest --with pyyaml --with pynvim -m pytest tests -q`
Expected: `5 passed`

- [ ] **Step 6: Commit**

```bash
cd ~/.config/nvim && git add scripts/cockpitlib && git commit -m "feat(cockpit): tracks with per-repo worktrees and inner windows"
```

---

### Task 5: Agents — spawn (pane mode), markers, status

**Files:**
- Create: `scripts/cockpitlib/agents.py`
- Modify: `scripts/cockpitlib/cli.py`, `scripts/cockpitlib/state.py` (replace `_current_agents` stub; delete TEMP stubs)
- Test: `tests/test_agents.py`

**Interfaces:**
- Consumes: `tracks.get/primary_worktree`, `tmuxctl.*`, `paths`.
- Produces: `agents.spawn(sdir, track: str, role: str, prompt: str|None, primary: str|None, resume: str|None, extra: list[str]) -> str` (pane id); `agents.read_markers(sdir) -> dict[pane_id, dict]`; `agents.list_agents(sdir, live=True) -> list[dict]` with keys `pane_id role track status title updated window`; `agents.status_json(sdir) -> str`; `agents.status_pretty(sdir) -> str`; `agents.resolve_target(sdir, target: str) -> str` (pane id).
- Marker file `agents/<pane>.json` (pane id without `%`): `{"pane": "%3", "state": "working|idle|needs_you|offline", "session_id": "...", "transcript_path": "...", "last_message": "...", "updated": "<iso>", "role": "...", "track": "..."}`.
- Target grammar: `%N` | `main-claude` | `<track>:agent` | `<track>:agent[N]`.

- [ ] **Step 1: Write the failing test**

`tests/test_agents.py`:
```python
import json

from cockpitlib import agents, paths


def test_markers_merge_without_tmux(root):
    sdir = paths.session_dir()
    paths.ensure_session_dirs(sdir)
    (sdir / "agents" / "3.json").write_text(json.dumps({
        "pane": "%3", "state": "needs_you", "role": "impl", "track": "feat-x",
        "last_message": "Need approval for rm", "updated": "2026-08-28T10:00:00"}))
    rows = agents.list_agents(sdir, live=False)
    assert rows == [{"pane_id": "%3", "role": "impl", "track": "feat-x", "status": "needs_you",
                     "title": "Need approval for rm", "updated": "2026-08-28T10:00:00", "window": "feat-x"}]
    assert json.loads(agents.status_json(sdir))[0]["status"] == "needs_you"
    assert "needs_you" in agents.status_pretty(sdir)
    assert agents.resolve_target(sdir, "feat-x:agent") == "%3"
    assert agents.resolve_target(sdir, "%3") == "%3"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/.config/nvim && uv run --with pytest --with pyyaml --with pynvim -m pytest tests/test_agents.py -q`
Expected: FAIL with `cannot import name 'agents'`

- [ ] **Step 3: Implement agents.py**

`scripts/cockpitlib/agents.py`:
```python
import json
import re
import shlex
from datetime import datetime
from pathlib import Path

from . import paths, tmuxctl, tracks

STATUS_ICON = {"working": "●", "idle": "○", "needs_you": "◐", "offline": "✕", "": "?"}


def read_markers(sdir: Path) -> dict[str, dict]:
    out = {}
    for f in (sdir / "agents").glob("*.json"):
        try:
            m = json.loads(f.read_text())
        except json.JSONDecodeError:
            continue
        out[m.get("pane", "%" + f.stem)] = m
    return out


def list_agents(sdir: Path, live: bool = True) -> list[dict]:
    """Merge inner-tmux panes (authoritative for existence) with hook markers (authoritative for state)."""
    markers = read_markers(sdir)
    rows = {}
    if live:
        inner = paths.inner_session(sdir.name)
        for p in tmuxctl.list_panes(inner):
            if not p["role"]:
                continue
            m = markers.get(p["pane_id"], {})
            rows[p["pane_id"]] = {
                "pane_id": p["pane_id"], "role": p["role"], "track": p["track"],
                "status": "offline" if p["dead"] else m.get("state", ""),
                "title": (m.get("last_message") or p["title"])[:60], "updated": m.get("updated", ""),
                "window": p["window"]}
    for pid, m in markers.items():
        if pid not in rows:
            rows[pid] = {"pane_id": pid, "role": m.get("role", ""), "track": m.get("track", ""),
                         "status": m.get("state", "") if not live else "offline",
                         "title": (m.get("last_message") or "")[:60], "updated": m.get("updated", ""),
                         "window": m.get("track", "")}
    return sorted(rows.values(), key=lambda r: (r["track"], r["pane_id"]))


def status_json(sdir: Path, live: bool = False) -> str:
    return json.dumps(list_agents(sdir, live=live), indent=2)


def status_pretty(sdir: Path, live: bool = False) -> str:
    lines = [f"{'pane':<6} {'st':<2} {'role':<10} {'track':<14} {'updated':<19} title"]
    for a in list_agents(sdir, live=live):
        lines.append(f"{a['pane_id']:<6} {STATUS_ICON.get(a['status'], '?'):<2} {a['role']:<10} {a['track']:<14} "
                     f"{a['updated'][:19]:<19} {a['status']} {a['title']}")
    return "\n".join(lines)


def resolve_target(sdir: Path, target: str, live: bool = False) -> str:
    if re.fullmatch(r"%\d+", target):
        return target
    rows = list_agents(sdir, live=live)
    if target == "main-claude":
        cands = [r for r in rows if r["role"] == "operator"]
    else:
        m = re.fullmatch(r"([\w-]+):agent(?:\[(\d+)\])?", target)
        if not m:
            raise ValueError(f"bad target: {target}")
        cands = [r for r in rows if r["track"] == m.group(1) and r["role"] != "operator"]
        if m.group(2):
            cands = cands[int(m.group(2)):int(m.group(2)) + 1]
    if len(cands) != 1:
        raise ValueError(f"target {target} matches {len(cands)} panes: {[c['pane_id'] for c in cands]}")
    return cands[0]["pane_id"]


def spawn(sdir: Path, track: str, role: str = "impl", prompt: str | None = None, primary: str | None = None,
          resume: str | None = None, extra: list[str] | None = None) -> str:
    t = tracks.get(sdir, track)
    cwd = tracks.primary_worktree(t, primary)
    add_dirs = [r["worktree"] for r in t["repos"] if Path(r["worktree"]) != cwd]
    cmd = ["claude"]
    for d in add_dirs:
        cmd += ["--add-dir", d]
    if resume:
        cmd += ["--resume", resume]
    cmd += extra or []
    if prompt:
        cmd.append(prompt)
    inner = paths.inner_session(sdir.name)
    tmuxctl.ensure_session(inner, sdir)
    env = {"COCKPIT_DIR": str(sdir), "COCKPIT_TRACK": track, "COCKPIT_ROLE": role, "COCKPIT_SESSION": sdir.name}
    pane = tmuxctl.new_pane(inner, t["window"], cwd, " ".join(shlex.quote(c) for c in cmd), env,
                            {"role": role, "track": track})
    tmuxctl.pipe_log(pane, sdir / "logs" / f"{pane.lstrip('%')}.log")
    marker = sdir / "agents" / f"{pane.lstrip('%')}.json"
    marker.write_text(json.dumps({"pane": pane, "state": "idle", "role": role, "track": track,
                                  "updated": datetime.now().isoformat(timespec="seconds")}))
    return pane
```

- [ ] **Step 4: Wire CLI verbs, finish state.py**

In `cli.py`:
```python
from . import agents


def cmd_spawn(args):
    sdir = paths.session_dir()
    extra = args.extra[1:] if args.extra[:1] == ["--"] else args.extra  # argparse.REMAINDER keeps the `--`
    if args.what == "agent":
        pane = agents.spawn(sdir, args.track, role=args.role, prompt=args.prompt, primary=args.primary,
                            resume=args.resume, extra=extra)
        print(pane)
        print(tmuxctl.attach_cmd(paths.inner_session(sdir.name), tracks.get(sdir, args.track)["window"]))


def cmd_status(args):
    sdir = paths.session_dir()
    live = not args.offline
    print(agents.status_json(sdir, live) if args.json else agents.status_pretty(sdir, live))


def cmd_send(args):
    sdir = paths.session_dir()
    tmuxctl.send(agents.resolve_target(sdir, args.target, live=True), " ".join(args.text))


def cmd_kill(args):
    tmuxctl.kill(agents.resolve_target(paths.session_dir(), args.target, live=True))
```
parser:
```python
    sp = sub.add_parser("spawn"); sp.add_argument("what", choices=["agent"]); sp.add_argument("track")
    sp.add_argument("--role", default="impl"); sp.add_argument("-p", "--prompt"); sp.add_argument("--primary")
    sp.add_argument("--resume"); sp.add_argument("extra", nargs=argparse.REMAINDER, help="extra claude flags after --")
    sp.set_defaults(fn=cmd_spawn)
    sp = sub.add_parser("status"); sp.add_argument("--json", action="store_true"); sp.add_argument("--offline", action="store_true")
    sp.set_defaults(fn=cmd_status)
    sp = sub.add_parser("send"); sp.add_argument("target"); sp.add_argument("text", nargs="+"); sp.set_defaults(fn=cmd_send)
    sp = sub.add_parser("kill"); sp.add_argument("target"); sp.set_defaults(fn=cmd_kill)
```
Add `from . import tmuxctl` to `cli.py`. In `state.py` delete both TEMP stubs and keep the real `_current_tracks` / `_current_agents` (the latter calls `agents.list_agents(sdir, live=False)`).

- [ ] **Step 5: Run tests**

Run: `cd ~/.config/nvim && uv run --with pytest --with pyyaml --with pynvim -m pytest tests -q`
Expected: `6 passed`

- [ ] **Step 6: Commit**

```bash
cd ~/.config/nvim && git add scripts/cockpitlib && git commit -m "feat(cockpit): spawn agents into inner panes, markers, status"
```

---

### Task 6: Worker marker hook and hook installer

**Files:**
- Create: `scripts/hooks/cockpit-marker.sh`, `scripts/hooks/install-cockpit-hooks.py`
- Test: `tests/test_marker_hook.sh` (bash, run manually + by smoke)

**Interfaces:**
- Consumes: hook stdin JSON (`hook_event_name`, `session_id`, `transcript_path`, `last_assistant_message`, `notification_type`), env `COCKPIT_DIR`, `COCKPIT_ROLE`, `COCKPIT_TRACK`, `TMUX_PANE`.
- Produces: `agents/<pane>.json` (schema from Task 5), `events.jsonl` lines `{"ts","pane","kind","payload"}`.

- [ ] **Step 1: Write the hook**

`scripts/hooks/cockpit-marker.sh`:
```bash
#!/usr/bin/env bash
# Worker-side Claude Code hook: turn lifecycle events into a per-pane marker + event line.
# Must never block or fail the agent: always exit 0, never print on SessionStart.
[[ -n "${COCKPIT_DIR:-}" && -n "${TMUX_PANE:-}" ]] || exit 0
command -v jq >/dev/null || exit 0

payload="$(cat)"
event="$(jq -r '.hook_event_name // empty' <<<"$payload")"
pane_num="${TMUX_PANE#%}"
marker="$COCKPIT_DIR/agents/$pane_num.json"
ts="$(date +%Y-%m-%dT%H:%M:%S)"

case "$event" in
  SessionStart)      state="idle" ;;
  UserPromptSubmit)  state="working" ;;
  Stop)              state="idle" ;;
  SubagentStart|SubagentStop|SessionEnd) state="" ;;
  Notification)
    ntype="$(jq -r '.notification_type // empty' <<<"$payload")"
    case "$ntype" in
      permission_prompt|idle_prompt|elicitation_dialog|agent_needs_input) state="needs_you" ;;
      *) state="" ;;
    esac ;;
  *) state="" ;;
esac

mkdir -p "$COCKPIT_DIR/agents"
existing="{}"; [[ -f "$marker" ]] && existing="$(cat "$marker")"
tmp="$(mktemp "$COCKPIT_DIR/agents/.tmp.XXXXXX")"
jq -n --argjson old "$existing" --argjson new "$payload" \
   --arg pane "$TMUX_PANE" --arg state "$state" --arg ts "$ts" \
   --arg role "${COCKPIT_ROLE:-}" --arg track "${COCKPIT_TRACK:-}" '
  $old + {
    pane: $pane, role: ($role // $old.role), track: ($track // $old.track), updated: $ts,
    session_id: ($new.session_id // $old.session_id),
    transcript_path: ($new.transcript_path // $old.transcript_path),
    last_message: (($new.last_assistant_message // $old.last_message // "") | .[0:200])
  } + (if $state != "" then {state: $state} else {} end)
  + (if $new.hook_event_name == "SessionEnd" then {state: "offline"} else {} end)' >"$tmp" && mv -f "$tmp" "$marker"

jq -nc --arg ts "$ts" --arg pane "$TMUX_PANE" --arg kind "$event" --argjson p "$payload" \
  '{ts:$ts, pane:$pane, kind:$kind, payload:{session_id:$p.session_id, notification_type:$p.notification_type, agent_type:$p.agent_type}}' \
  >>"$COCKPIT_DIR/events.jsonl"
exit 0
```
`chmod +x scripts/hooks/cockpit-marker.sh`.

- [ ] **Step 2: Write a shell test**

`tests/test_marker_hook.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
d="$(mktemp -d)"; export COCKPIT_DIR="$d" TMUX_PANE=%7 COCKPIT_ROLE=impl COCKPIT_TRACK=feat-x
h="$(dirname "$0")/../scripts/hooks/cockpit-marker.sh"
echo '{"hook_event_name":"SessionStart","session_id":"s1","transcript_path":"/t.jsonl"}' | "$h"
echo '{"hook_event_name":"UserPromptSubmit","session_id":"s1"}' | "$h"
jq -e '.state=="working" and .pane=="%7" and .role=="impl" and .session_id=="s1"' "$d/agents/7.json" >/dev/null
echo '{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"s1"}' | "$h"
jq -e '.state=="needs_you"' "$d/agents/7.json" >/dev/null
echo '{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"done with the router"}' | "$h"
jq -e '.state=="idle" and .last_message=="done with the router"' "$d/agents/7.json" >/dev/null
[[ "$(wc -l <"$d/events.jsonl")" -eq 4 ]]
echo "marker hook OK"; rm -rf "$d"
```
Run: `bash tests/test_marker_hook.sh` → `marker hook OK`.

- [ ] **Step 3: Write the installer**

`scripts/hooks/install-cockpit-hooks.py`:
```python
#!/usr/bin/env python3
"""Merge cockpit hook entries into ~/.claude/settings.json (idempotent; backs up first)."""
import json
import shutil
import sys
from pathlib import Path

SETTINGS = Path.home() / ".claude" / "settings.json"
HOOKS_DIR = Path.home() / ".config" / "nvim" / "scripts" / "hooks"
MARKER = str(HOOKS_DIR / "cockpit-marker.sh")
OPERATOR = str(HOOKS_DIR / "cockpit-operator.sh")
LINT = "uv run --quiet ~/.config/nvim/scripts/cockpit.py doc lint --hook"

WANTED = {
    "SessionStart": [{"matcher": "startup|resume|clear|compact", "hooks": [
        {"type": "command", "command": MARKER, "async": True},
        {"type": "command", "command": OPERATOR, "timeout": 20}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": MARKER, "async": True}]}],
    "Stop": [{"hooks": [{"type": "command", "command": MARKER, "async": True}]}],
    "Notification": [{"hooks": [{"type": "command", "command": MARKER, "async": True}]}],
    "SubagentStart": [{"hooks": [{"type": "command", "command": MARKER, "async": True}]}],
    "SubagentStop": [{"hooks": [{"type": "command", "command": MARKER, "async": True}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": MARKER, "async": True}]}],
    "PreCompact": [{"hooks": [{"type": "command", "command": OPERATOR, "timeout": 30}]}],
    "PostToolUse": [{"matcher": "Write|Edit", "hooks": [{"type": "command", "command": LINT, "timeout": 20}]}],
}


def is_cockpit(entry: dict) -> bool:
    return any("cockpit" in h.get("command", "") for h in entry.get("hooks", []))


def main():
    data = json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}
    shutil.copy(SETTINGS, SETTINGS.with_suffix(".json.pre-cockpit.bak"))
    hooks = data.setdefault("hooks", {})
    for event, entries in WANTED.items():
        kept = [e for e in hooks.get(event, []) if not is_cockpit(e)]
        hooks[event] = kept + entries
    if "--uninstall" in sys.argv:
        for event in list(hooks):
            hooks[event] = [e for e in hooks[event] if not is_cockpit(e)]
            if not hooks[event]:
                del hooks[event]
    SETTINGS.write_text(json.dumps(data, indent=2) + "\n")
    print(f"updated {SETTINGS} (backup: {SETTINGS.with_suffix('.json.pre-cockpit.bak')})")


if __name__ == "__main__":
    main()
```
Do **not** run the installer yet — the operator hook and `doc lint --hook` arrive in Tasks 7 and 8; run it in Task 10.

- [ ] **Step 4: Commit**

```bash
cd ~/.config/nvim && chmod +x scripts/hooks/*.sh tests/test_marker_hook.sh && git add scripts/hooks tests/test_marker_hook.sh && git commit -m "feat(cockpit): worker marker hook and settings installer"
```

---

### Task 7: Operator agent definition, operator hook, `up`

**Files:**
- Create: `~/.claude/agents/cockpit.md`, `scripts/hooks/cockpit-operator.sh`
- Modify: `scripts/cockpitlib/cli.py` (add `up`)
- Test: manual

**Interfaces:**
- Consumes: `cockpit snapshot`, `cockpit log`, `state.load`.
- Produces: `cockpit up` → ensures repo/session/inner server, starts `claude --agent cockpit` in inner window `main` with `COCKPIT_ROLE=operator`, prints the attach command.

- [ ] **Step 1: Write the operator hook**

`scripts/hooks/cockpit-operator.sh`:
```bash
#!/usr/bin/env bash
# Operator-only hook. Gated on the cockpit agent so worker sessions ignore it.
# PreCompact: snapshot STATE.md.  SessionStart(compact|resume): print state as context (stdout is context here).
payload="$(cat)"
agent="$(jq -r '.agent_type // empty' <<<"$payload" 2>/dev/null)"
[[ "$agent" == "cockpit" || "${COCKPIT_ROLE:-}" == "operator" ]] || exit 0
[[ -n "${COCKPIT_DIR:-}" ]] || exit 0
event="$(jq -r '.hook_event_name // empty' <<<"$payload")"
source_="$(jq -r '.source // .matcher // empty' <<<"$payload")"
CP="uv run --quiet $HOME/.config/nvim/scripts/cockpit.py"

case "$event" in
  PreCompact)
    $CP snapshot --reason pre-compact >/dev/null 2>&1 || true ;;
  SessionStart)
    if [[ "$source_" == "compact" || "$source_" == "resume" || -z "$source_" ]]; then
      echo "# Cockpit state (re-injected after $source_)"
      cat "$COCKPIT_DIR/STATE.md" 2>/dev/null
      echo; echo "## Recent history"; $CP log -n 20 2>/dev/null
      echo; echo "## Latest handoffs"
      ls -t "$COCKPIT_DIR"/records/*/*-handoff-*.md 2>/dev/null | head -3 | while read -r f; do echo "### $f"; cat "$f"; done
    fi ;;
esac
exit 0
```

- [ ] **Step 2: Write the operator agent**

`~/.claude/agents/cockpit.md`:
```markdown
---
name: cockpit
description: Cockpit operator — orchestrates agents, tracks, documents and views for a goal. Run with `claude --agent cockpit`.
model: inherit
permissionMode: acceptEdits
hooks:
  Stop:
    - hooks:
        - type: command
          command: "bash -lc 'uv run --quiet ~/.config/nvim/scripts/cockpit.py snapshot --reason stop >/dev/null 2>&1 || true'"
          async: true
---

You are the **cockpit operator**: a meta-harness that runs other Claude Code agents to achieve a goal. You do not write product code yourself. You arrange work, watch it, route the user's steers back to agents, and keep the workspace record honest.

## Where things are
- Workspace: `$COCKPIT_DIR` (a git repo at `~/.cockpit/`, session subdir). `STATE.md` is the record of truth: goal, tracks, agents, decisions, next.
- Agents run as panes in an inner tmux server `tmux -L cockpit`, one window per **track** (a track = one branch across one or more repo worktrees under `~/dev/worktrees/`).
- The user's Neovim is reachable through `python3 ~/.config/nvim/scripts/nvim_bridge.py` (`open`, `open_many`, `cmd`, `exec`).
- The only way to change the workspace is the CLI: `cockpit` (alias for `uv run --quiet ~/.config/nvim/scripts/cockpit.py`).

## CLI you use
`cockpit status [--json]` · `cockpit log` · `cockpit state set goal|decision|next "…"` · `cockpit snapshot`
`cockpit track add <name> --repo <r> [--repo <r2>] [--branch b] [--from main]` · `cockpit track list|rm|pick`
`cockpit spawn agent <track> [--role impl|reviewer|research] [-p "prompt"] [--primary <repo>]` · `cockpit send <target> "text"` · `cockpit kill <target>`
`cockpit doc new <kind> --track <t> --title "…" [--from <id>…]` · `cockpit doc save|lint|list|lineage`
`cockpit annotate <id>:<line> "text" --why <tag>` · `cockpit review send <target>`
Targets: `%N` · `main-claude` · `<track>:agent` · `<track>:agent[N]`.

## Rules of engagement
1. Start every turn that changes anything by reading `STATE.md` and `cockpit log -n 20`; end it by updating state (`state set` or `snapshot`) **before** replying.
2. Never kill or resize a pane you did not create, and never `send` into an agent mid-interaction, without asking first.
3. Prefer changing what the user sees (open a document or diff in nvim) over describing it. Replies are short: what changed, what needs them.
4. One nvim per repo. Cross-repo agents get `cwd` = primary worktree and the rest via `--add-dir` (`spawn` does this).
5. Keep your own context small. Do layout, state, and routing yourself; delegate token-heavy reading (log summaries, PR digests) to `claude -p --model haiku "…"` or a `--role research` agent, and file the result as a `digest` Document.
6. Write Documents through `cockpit doc new` (templates, budgets, lineage). Never hand-write frontmatter `producer` fields.
7. When the user steers (annotations exist for a track), deliver with `cockpit review send <track>:agent`; if the target is a discoverable Claude session, prefer the SendMessage tool with the steer record's path.
8. When asked for a plan, produce a `plan` Document and stop for approval before spawning implementers.

## Startup
On start or after compaction you receive `STATE.md`, recent history, and handoffs as context. Summarize the situation in three lines and ask what to do — or, if `Next` has unchecked items and the user said to continue, continue.
```

- [ ] **Step 3: Add `up` to the CLI**

In `cli.py`:
```python
def cmd_up(args):
    repo.ensure_repo()
    sdir = paths.session_dir()
    paths.ensure_session_dirs(sdir)
    if not (sdir / "STATE.md").exists():
        state.write(sdir, [], [], "state: init")
    from . import docs
    docs.ensure_templates()
    inner = paths.inner_session(sdir.name)
    tmuxctl.ensure_session(inner, sdir)
    live = [p for p in tmuxctl.list_panes(inner) if p["role"] == "operator" and not p["dead"]]
    if live:
        print(live[0]["pane_id"])
    else:
        env = {"COCKPIT_DIR": str(sdir), "COCKPIT_ROLE": "operator", "COCKPIT_SESSION": sdir.name}
        first = tmuxctl.tmx("list-panes", "-t", f"={inner}:main", "-F", "#{pane_id} #{pane_current_command}").split()
        pane = tmuxctl.new_pane(inner, "main", sdir, "claude --agent cockpit", env, {"role": "operator", "track": "main"})
        if len(first) >= 2 and first[1] in ("zsh", "bash", "sh"):
            tmuxctl.kill(first[0])  # the placeholder shell from new-session
        tmuxctl.pipe_log(pane, sdir / "logs" / f"{pane.lstrip('%')}.log")
        print(pane)
    print(tmuxctl.attach_cmd(inner, "main"))
```
parser: `sp = sub.add_parser("up"); sp.set_defaults(fn=cmd_up)`. `docs.ensure_templates()` arrives in Task 8 — until then `up` fails at import; that's expected ordering (Task 8 follows immediately).

- [ ] **Step 4: Manual verification (after Task 8)**

`cockpit up` prints a pane id and `tmux -L cockpit attach -t =cockpit-<session>:main`; running the attach command shows Claude starting with `@cockpit` in the header. In that Claude, ask "what's the state?" — it should reference `STATE.md` (the SessionStart hook injected it). Detach with `tmux -L cockpit detach` (prefix is None, so detach from another shell: `tmux -L cockpit detach-client -s =cockpit-<session>`).

- [ ] **Step 5: Commit**

```bash
cd ~/.config/nvim && chmod +x scripts/hooks/cockpit-operator.sh && git add scripts/hooks/cockpit-operator.sh scripts/cockpitlib/cli.py && git commit -m "feat(cockpit): operator agent hook and up"
```
(`~/.claude/agents/cockpit.md` lives outside the repo; also copy it to `scripts/claude-agents/cockpit.md` and `git add` that copy so it is versioned: `mkdir -p scripts/claude-agents && cp ~/.claude/agents/cockpit.md scripts/claude-agents/`.)

---

### Task 8: Artifact model — kinds, templates, frontmatter, `doc new/save/lint/list/lineage`

**Files:**
- Create: `scripts/cockpitlib/docs.py`, `scripts/cockpitlib/templates/{research,prd,spec,design,adr,plan,codediff,review,digest,tasks,handoff,context,steer}.md`
- Modify: `scripts/cockpitlib/cli.py`
- Test: `tests/test_docs.py`

**Interfaces:**
- Produces: `docs.KINDS: dict[kind, {"branch": "documents"|"records", "sections": [...], "budget": int}]`; `docs.ensure_templates()`; `docs.next_seq(sdir, track) -> int`; `docs.new(sdir, kind, track, title, derives_from: list[str], role: str|None, pane: str|None) -> Path`; `docs.read(path) -> tuple[dict, str]` (frontmatter, body); `docs.write(path, fm, body)`; `docs.save(sdir, path, steered_by: str|None) -> Path`; `docs.lint(path) -> list[str]`; `docs.find(sdir, doc_id) -> Path`; `docs.list_docs(sdir, track=None, kind=None) -> list[dict]`; `docs.lineage_mermaid(sdir, doc_id) -> str`.
- Frontmatter schema exactly as spec §6.

- [ ] **Step 1: Write the failing test**

`tests/test_docs.py`:
```python
from cockpitlib import docs, paths, repo


def test_new_save_lint_lineage(root):
    repo.ensure_repo()
    sdir = paths.session_dir()
    paths.ensure_session_dirs(sdir)
    docs.ensure_templates()
    p1 = docs.new(sdir, "research", "feat-x", "Worktree options", derives_from=[], role="research", pane="%2")
    p2 = docs.new(sdir, "plan", "feat-x", "Worktree per repo", derives_from=["feat-x/01"], role="impl", pane="%3")
    assert p1.name == "01-research-worktree-options.md"
    assert p2.name == "02-plan-worktree-per-repo.md"
    fm, body = docs.read(p2)
    assert fm["id"] == "feat-x/02" and fm["kind"] == "plan" and fm["revision"] == 1
    assert fm["producer"]["role"] == "impl" and fm["lineage"]["derives_from"] == ["feat-x/01"]
    assert "## Goal" in body and "## Test plan" in body
    assert docs.lint(p2) == []
    docs.write(p2, fm, body + "\nmore\n")
    docs.save(sdir, p2, steered_by="feat-x/03")
    fm2, _ = docs.read(p2)
    assert fm2["revision"] == 2 and fm2["lineage"]["steered_by"] == ["feat-x/03"]
    assert docs.find(sdir, "feat-x/02") == p2
    assert [d["id"] for d in docs.list_docs(sdir, track="feat-x")] == ["feat-x/01", "feat-x/02"]
    g = docs.lineage_mermaid(sdir, "feat-x/02")
    assert "feat-x/01" in g and "-->" in g
    fm2["kind"] = "bogus"
    docs.write(p2, fm2, body)
    assert any("kind" in e for e in docs.lint(p2))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/.config/nvim && uv run --with pytest --with pyyaml --with pynvim -m pytest tests/test_docs.py -q`
Expected: FAIL with `cannot import name 'docs'`

- [ ] **Step 3: Write the templates**

Each file in `scripts/cockpitlib/templates/` holds only the body (headings + one guidance line). Create all thirteen:

`research.md`:
```markdown
## Question
_One sentence: what needed answering and why now._

## Sources
- _URL or path — one line on what it contributed_

## Findings
_Bullets. Facts, not opinions. Cite a source per bullet._

## Recommendation
_What to do, in ≤ 3 sentences._

## Open questions
- _What remains unknown_
```
`prd.md`:
```markdown
## Problem
## Users
## Must / Should
- **Must**
- **Should**
## Success metrics
## Out of scope
```
`spec.md`:
```markdown
## Requirements
## Acceptance criteria
- [ ] _observable, testable_
## Interfaces
## Constraints
```
`design.md`:
```markdown
## Overview
## Architecture
## Components
## Data flow
## Failure modes
## Open questions
```
`adr.md`:
```markdown
## Context
## Decision
## Alternatives
## Consequences
```
`plan.md`:
```markdown
## Goal
## Non-goals
## Approach
## Steps
- [ ] _small, verifiable_
## Risks
## Test plan
```
`codediff.md`:
```markdown
## Intent
## Files
## Risk
## How to test
```
`review.md`:
```markdown
## Verdict
_approve | request-changes | comment_
## Blocking
- `file:line` — _why_
## Non-blocking
## Questions
```
`digest.md`:
```markdown
## What happened
## Decisions
## Needs you
```
`tasks.md`:
```markdown
## Tasks
- [ ] _task_ · owner: `%N` · blocked-on: —
```
`handoff.md`:
```markdown
## Done
## Next
## Gotchas
## Files touched
```
`context.md`:
```markdown
## Files
- `path:line` — _why it matters_
## Decisions in force
## Do not
```
`steer.md`:
```markdown
## Items
_Filled by `cockpit review send` — one bullet per annotation: `ref` · **why** · text_
## Instructions
Address each item, then revise the referenced document with `cockpit doc save` (revision +1) or reply in your pane.
```

- [ ] **Step 4: Implement docs.py**

`scripts/cockpitlib/docs.py`:
```python
import os
import re
import shutil
from datetime import datetime
from pathlib import Path

import yaml

from . import paths, repo

TEMPLATE_SRC = Path(__file__).parent / "templates"
KINDS = {
    "research": {"branch": "documents", "budget": 600},
    "prd": {"branch": "documents", "budget": 800},
    "spec": {"branch": "documents", "budget": 800},
    "design": {"branch": "documents", "budget": 1500},
    "adr": {"branch": "documents", "budget": 300},
    "plan": {"branch": "documents", "budget": 1000},
    "codediff": {"branch": "documents", "budget": 150},
    "review": {"branch": "documents", "budget": 400},
    "digest": {"branch": "documents", "budget": 200},
    "tasks": {"branch": "records", "budget": 0},
    "handoff": {"branch": "records", "budget": 200},
    "context": {"branch": "records", "budget": 0},
    "steer": {"branch": "records", "budget": 0},
}
STATUSES = ("draft", "in-review", "approved", "superseded", "rejected")
REQUIRED = ("id", "kind", "title", "status", "revision", "created", "updated", "budget", "producer", "lineage", "consumers")


def templates_dir() -> Path:
    return paths.root() / "templates"


def ensure_templates() -> None:
    """Copy bundled templates into ~/.cockpit/templates once; the user may edit them there."""
    templates_dir().mkdir(parents=True, exist_ok=True)
    for src in TEMPLATE_SRC.glob("*.md"):
        dst = templates_dir() / src.name
        if not dst.exists():
            shutil.copy(src, dst)


def sections_of(kind: str) -> list[str]:
    body = (templates_dir() / f"{kind}.md").read_text()
    return re.findall(r"^## (.+)$", body, flags=re.M)


def slugify(title: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return s[:40].rstrip("-") or "untitled"


def _track_files(sdir: Path, track: str) -> list[Path]:
    files = []
    for branch in ("documents", "records"):
        files += list((sdir / branch / track).glob("[0-9][0-9]-*.md"))
    return sorted(files, key=lambda p: p.name)


def next_seq(sdir: Path, track: str) -> int:
    seqs = [int(f.name[:2]) for f in _track_files(sdir, track)]
    return max(seqs, default=0) + 1


def read(path: Path) -> tuple[dict, str]:
    text = path.read_text()
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, flags=re.S)
    if not m:
        return {}, text
    return yaml.safe_load(m.group(1)) or {}, m.group(2)


def write(path: Path, fm: dict, body: str) -> None:
    path.write_text("---\n" + yaml.safe_dump(fm, sort_keys=False, allow_unicode=True) + "---\n" + body)


def new(sdir: Path, kind: str, track: str, title: str, derives_from: list[str] | None = None,
        role: str | None = None, pane: str | None = None, consumers: list[str] | None = None) -> Path:
    if kind not in KINDS:
        raise ValueError(f"unknown kind {kind}; one of {', '.join(KINDS)}")
    ensure_templates()
    meta = KINDS[kind]
    seq = next_seq(sdir, track)
    slug = slugify(title)
    path = sdir / meta["branch"] / track / f"{seq:02d}-{kind}-{slug}.md"
    path.parent.mkdir(parents=True, exist_ok=True)
    now = datetime.now().isoformat(timespec="seconds")
    fm = {
        "id": f"{track}/{seq:02d}", "kind": kind, "title": title, "status": "draft", "revision": 1,
        "created": now, "updated": now, "budget": meta["budget"],
        "producer": {"role": role or os.environ.get("COCKPIT_ROLE") or "user",
                     "pane": pane or os.environ.get("TMUX_PANE"), "session_id": None, "transcript": None,
                     "model": os.environ.get("CLAUDE_MODEL")},
        "lineage": {"derives_from": list(derives_from or []), "steered_by": [], "supersedes": None, "code": []},
        "consumers": consumers or (["user"] if meta["branch"] == "documents" else ["agent"]),
        "tags": ["cockpit", track],
    }
    body = f"# {title}\n\n" + (templates_dir() / f"{kind}.md").read_text()
    write(path, fm, body)
    if kind == "codediff":
        path.with_suffix(".patch").write_text("")
    repo.commit([path.parent], f"doc({fm['id']} {kind} r1): {title}")
    return path


def save(sdir: Path, path: Path, steered_by: str | None = None, status: str | None = None) -> Path:
    fm, body = read(path)
    fm["revision"] = int(fm.get("revision", 1)) + 1
    fm["updated"] = datetime.now().isoformat(timespec="seconds")
    if steered_by:
        fm.setdefault("lineage", {}).setdefault("steered_by", []).append(steered_by)
    if status:
        fm["status"] = status
    write(path, fm, body)
    repo.commit([path], f"doc({fm['id']} {fm['kind']} r{fm['revision']}): {fm['title']}")
    return path


def lint(path: Path) -> list[str]:
    errors = []
    fm, body = read(path)
    if not fm:
        return ["missing frontmatter"]
    for k in REQUIRED:
        if k not in fm:
            errors.append(f"missing field: {k}")
    kind = fm.get("kind")
    if kind not in KINDS:
        return errors + [f"unknown kind: {kind}"]
    if fm.get("status") not in STATUSES:
        errors.append(f"bad status: {fm.get('status')}")
    if not re.fullmatch(r"[\w-]+/\d{2}", str(fm.get("id", ""))):
        errors.append(f"bad id: {fm.get('id')}")
    present = set(re.findall(r"^## (.+)$", body, flags=re.M))
    for s in sections_of(kind):
        if s not in present:
            errors.append(f"missing section: ## {s}")
    budget = KINDS[kind]["budget"]
    words = len(re.sub(r"`[^`]*`", "", body).split())
    if budget and words > budget:
        errors.append(f"over budget: {words} words > {budget}")
    return errors


def find(sdir: Path, doc_id: str) -> Path:
    track, seq = doc_id.split("/")
    for f in _track_files(sdir, track):
        if f.name.startswith(f"{int(seq):02d}-"):
            return f
    raise FileNotFoundError(f"document not found: {doc_id}")


def list_docs(sdir: Path, track: str | None = None, kind: str | None = None) -> list[dict]:
    tracks_ = [track] if track else sorted({p.name for b in ("documents", "records") for p in (sdir / b).glob("*") if p.is_dir()})
    rows = []
    for t in tracks_:
        for f in _track_files(sdir, t):
            fm, _ = read(f)
            if kind and fm.get("kind") != kind:
                continue
            rows.append({"id": fm.get("id"), "kind": fm.get("kind"), "title": fm.get("title"), "status": fm.get("status"),
                         "revision": fm.get("revision"), "path": str(f)})
    return rows


def lineage_mermaid(sdir: Path, doc_id: str) -> str:
    seen, edges = set(), []

    def walk(did):
        if did in seen:
            return
        seen.add(did)
        try:
            fm, _ = read(find(sdir, did))
        except FileNotFoundError:
            return
        lin = fm.get("lineage", {})
        for p in lin.get("derives_from", []):
            edges.append(f'  "{p}" -->|derives| "{did}"')
            walk(p)
        for s in lin.get("steered_by", []):
            edges.append(f'  "{s}" -.->|steer| "{did}"')
            walk(s)
        if lin.get("supersedes"):
            edges.append(f'  "{lin["supersedes"]}" ==>|superseded by| "{did}"')
            walk(lin["supersedes"])

    walk(doc_id)
    return "graph TD\n" + "\n".join(edges or [f'  "{doc_id}"'])
```

- [ ] **Step 5: Wire CLI verbs**

In `cli.py`:
```python
from . import docs


def cmd_doc(args):
    sdir = paths.session_dir()
    if args.op == "new":
        p = docs.new(sdir, args.kind, args.track, args.title or args.kind, derives_from=args.from_ids, role=args.role)
        print(p)
    elif args.op == "save":
        print(docs.save(sdir, Path(args.path), steered_by=args.steered_by, status=args.status))
    elif args.op == "lint":
        if args.hook:
            payload = json.load(sys.stdin)
            fp = (payload.get("tool_input") or {}).get("file_path", "")
            if "/documents/" not in fp and "/records/" not in fp:
                return
            errs = docs.lint(Path(fp))
            if errs:
                print("cockpit doc lint: " + "; ".join(errs), file=sys.stderr)
                sys.exit(2)
            return
        errs = docs.lint(Path(args.path))
        print("\n".join(errs) if errs else "ok")
        sys.exit(1 if errs else 0)
    elif args.op == "list":
        for d in docs.list_docs(sdir, args.track, args.kind):
            print(f"{d['id']}\t{d['kind']:<9}\t{d['status']:<10}\tr{d['revision']}\t{d['title']}")
    elif args.op == "lineage":
        print(docs.lineage_mermaid(sdir, args.doc_id))
```
parser:
```python
    sp = sub.add_parser("doc"); dsub = sp.add_subparsers(dest="op", required=True)
    d = dsub.add_parser("new"); d.add_argument("kind", choices=list(docs.KINDS)); d.add_argument("--track", required=True)
    d.add_argument("--title"); d.add_argument("--from", dest="from_ids", action="append", default=[]); d.add_argument("--role")
    d.set_defaults(fn=cmd_doc)
    d = dsub.add_parser("save"); d.add_argument("path"); d.add_argument("--steered-by"); d.add_argument("--status", choices=docs.STATUSES); d.set_defaults(fn=cmd_doc)
    d = dsub.add_parser("lint"); d.add_argument("path", nargs="?"); d.add_argument("--hook", action="store_true"); d.set_defaults(fn=cmd_doc)
    d = dsub.add_parser("list"); d.add_argument("--track"); d.add_argument("--kind"); d.set_defaults(fn=cmd_doc)
    d = dsub.add_parser("lineage"); d.add_argument("doc_id"); d.set_defaults(fn=cmd_doc)
```
Add `from pathlib import Path` to `cli.py`.

- [ ] **Step 6: Run tests**

Run: `cd ~/.config/nvim && uv run --with pytest --with pyyaml --with pynvim -m pytest tests -q`
Expected: `7 passed`

- [ ] **Step 7: Commit**

```bash
cd ~/.config/nvim && git add scripts/cockpitlib && git commit -m "feat(cockpit): documents/records model with templates, frontmatter, lint, lineage"
```

---

### Task 9: Steer loop — `annotate`, `review send`, `feedback.jsonl`

**Files:**
- Create: `scripts/cockpitlib/steer.py`
- Modify: `scripts/cockpitlib/cli.py`
- Test: `tests/test_steer.py`

**Interfaces:**
- Consumes: `docs.find/read/new/write/save`, `repo.head_short/commit`, `agents.resolve_target`, `tmuxctl.send`.
- Produces: `steer.annotate(sdir, ref: str, text: str, why: str) -> dict` (item with keys `ref why text ts`); `steer.pending(sdir, track) -> list[dict]`; `steer.send(sdir, track: str, target: str|None, deliver: bool) -> Path` (steer record path).
- Ref grammar: `<track>/<seq>:<line>` (sha resolved automatically to `id@sha:line`), or `<path>:<start>[-<end>]` for files. WHY tags: `missing-convention wrong-assumption missed-context style scope-creep bug question approve`.
- Pending annotations live at `annotations/<track>/current.md` (one bullet per item); on send they move into the steer record and are appended to `feedback.jsonl` as `{ts, track, steer_id, ref, why, text}`.

- [ ] **Step 1: Write the failing test**

`tests/test_steer.py`:
```python
import json

from cockpitlib import docs, paths, repo, steer


def test_annotate_and_send(root):
    repo.ensure_repo()
    sdir = paths.session_dir()
    paths.ensure_session_dirs(sdir)
    docs.ensure_templates()
    plan = docs.new(sdir, "plan", "feat-x", "Worktree per repo", role="impl", pane="%3")
    item = steer.annotate(sdir, "feat-x/01:12", "Use one branch name across repos", "missing-convention")
    assert item["why"] == "missing-convention" and "@" in item["ref"] and item["ref"].endswith(":12")
    steer.annotate(sdir, "src/router.py:40-52", "This duplicates auth middleware", "wrong-assumption")
    assert len(steer.pending(sdir, "feat-x")) == 2
    rec = steer.send(sdir, "feat-x", target=None, deliver=False)
    fm, body = docs.read(rec)
    assert fm["kind"] == "steer" and fm["id"] == "feat-x/02"
    assert "missing-convention" in body and "src/router.py:40-52" in body
    assert steer.pending(sdir, "feat-x") == []
    lines = [json.loads(l) for l in (sdir / "feedback.jsonl").read_text().splitlines()]
    assert [l["why"] for l in lines] == ["missing-convention", "wrong-assumption"]
    assert lines[0]["steer_id"] == "feat-x/02"
    pfm, _ = docs.read(plan)
    assert pfm["lineage"]["steered_by"] == ["feat-x/02"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/.config/nvim && uv run --with pytest --with pyyaml --with pynvim -m pytest tests/test_steer.py -q`
Expected: FAIL with `cannot import name 'steer'`

- [ ] **Step 3: Implement steer.py**

`scripts/cockpitlib/steer.py`:
```python
import json
import re
from datetime import datetime
from pathlib import Path

from . import docs, repo

WHY = ("missing-convention", "wrong-assumption", "missed-context", "style", "scope-creep", "bug", "question", "approve")


def _pending_file(sdir: Path, track: str) -> Path:
    return sdir / "annotations" / track / "current.md"


def _track_of_ref(sdir: Path, ref: str) -> str | None:
    m = re.fullmatch(r"([\w-]+)/(\d{2})(?:@\w+)?:\d+(?:-\d+)?", ref)
    return m.group(1) if m else None


def resolve_ref(sdir: Path, ref: str) -> str:
    """`track/seq:line` → `track/seq@sha:line`; file refs pass through."""
    m = re.fullmatch(r"([\w-]+/\d{2}):(\d+(?:-\d+)?)", ref)
    if not m:
        return ref
    path = docs.find(sdir, m.group(1))
    return f"{m.group(1)}@{repo.head_short(path)}:{m.group(2)}"


def annotate(sdir: Path, ref: str, text: str, why: str, track: str | None = None) -> dict:
    if why not in WHY:
        raise ValueError(f"--why must be one of {', '.join(WHY)}")
    ref = resolve_ref(sdir, ref)
    track = track or _track_of_ref(sdir, ref)
    if not track:
        raise ValueError("file refs need --track")
    item = {"ref": ref, "why": why, "text": text, "ts": datetime.now().isoformat(timespec="seconds")}
    f = _pending_file(sdir, track)
    f.parent.mkdir(parents=True, exist_ok=True)
    with f.open("a") as fh:
        fh.write(f"- `{item['ref']}` · **{why}** · {text}\n")
    repo.commit([f], f"annotate({track}): {why} on {ref}")
    return item


def pending(sdir: Path, track: str) -> list[dict]:
    f = _pending_file(sdir, track)
    if not f.exists():
        return []
    items = []
    for line in f.read_text().splitlines():
        m = re.fullmatch(r"- `([^`]+)` · \*\*([\w-]+)\*\* · (.*)", line)
        if m:
            items.append({"ref": m.group(1), "why": m.group(2), "text": m.group(3)})
    return items


def send(sdir: Path, track: str, target: str | None, deliver: bool = True) -> Path:
    items = pending(sdir, track)
    if not items:
        raise ValueError(f"no pending annotations for {track}")
    rec = docs.new(sdir, "steer", track, f"steer round {docs.next_seq(sdir, track):02d}", role="user")
    fm, body = docs.read(rec)
    bullets = "\n".join(f"- `{i['ref']}` · **{i['why']}** · {i['text']}" for i in items)
    body = body.replace("_Filled by `cockpit review send` — one bullet per annotation: `ref` · **why** · text_", bullets)
    targets = sorted({i["ref"].split("@")[0] for i in items if "@" in i["ref"]})
    fm["lineage"]["derives_from"] = targets
    docs.write(rec, fm, body)
    with (sdir / "feedback.jsonl").open("a") as fh:
        for i in items:
            fh.write(json.dumps({"ts": datetime.now().isoformat(timespec="seconds"), "track": track,
                                 "steer_id": fm["id"], "ref": i["ref"], "why": i["why"], "text": i["text"]}) + "\n")
    for did in targets:
        docs.save(sdir, docs.find(sdir, did), steered_by=fm["id"], status="in-review")
    _pending_file(sdir, track).unlink()
    repo.commit([rec, sdir / "feedback.jsonl", sdir / "annotations"], f"steer({fm['id']} → {target or track}): {len(items)} annotations")
    if deliver:
        from . import agents, tmuxctl
        pane = agents.resolve_target(sdir, target or f"{track}:agent", live=True)
        tmuxctl.send(pane, f"Steer {fm['id']}: read {rec} and address every item, then `cockpit doc save` the revised document.")
    return rec
```

- [ ] **Step 4: Wire CLI verbs**

In `cli.py`:
```python
from . import steer


def cmd_annotate(args):
    print(json.dumps(steer.annotate(paths.session_dir(), args.ref, " ".join(args.text), args.why, track=args.track)))


def cmd_review(args):
    sdir = paths.session_dir()
    if args.op == "send":
        track = args.track or args.target.split(":")[0]
        print(steer.send(sdir, track, args.target, deliver=not args.no_deliver))
    elif args.op == "pending":
        for i in steer.pending(sdir, args.track):
            print(f"{i['ref']}\t{i['why']}\t{i['text']}")
```
parser:
```python
    sp = sub.add_parser("annotate"); sp.add_argument("ref"); sp.add_argument("text", nargs="+")
    sp.add_argument("--why", required=True, choices=steer.WHY); sp.add_argument("--track"); sp.set_defaults(fn=cmd_annotate)
    sp = sub.add_parser("review"); sp.add_argument("op", choices=["send", "pending"]); sp.add_argument("target", nargs="?")
    sp.add_argument("--track"); sp.add_argument("--no-deliver", action="store_true"); sp.set_defaults(fn=cmd_review)
```

- [ ] **Step 5: Run tests**

Run: `cd ~/.config/nvim && uv run --with pytest --with pyyaml --with pynvim -m pytest tests -q`
Expected: `8 passed`

- [ ] **Step 6: Commit**

```bash
cd ~/.config/nvim && git add scripts/cockpitlib && git commit -m "feat(cockpit): annotate, review send, feedback stream"
```

---

### Task 10: Bridge targeting, `vim` alias, hook install, smoke test

**Files:**
- Modify: `scripts/nvim_bridge.py` (`connect()`, `main()`, new `socket_for_pane()`), `~/.config/nix-darwin/dotfiles/.zshrc:50`
- Create: `scripts/cockpit-smoke.sh`
- Modify: `scripts/cockpitlib/cli.py` (add `nvims`)

**Interfaces:**
- Produces: `nvim_bridge.py [--socket PATH | --pane %N] <command> …`; `socket_for_pane(pane_id) -> str|None`; `cockpit nvims` (pane, socket, cwd per nvim in the **outer** tmux server).

- [ ] **Step 1: Generalize the bridge's socket discovery**

In `scripts/nvim_bridge.py`, add after `find_sibling_nvim_socket`:
```python
def socket_for_pane(pane_id, server=None):
    """Socket of the nvim running in a given tmux pane (any window), parsed from its --listen arg."""
    base = ["tmux"] + (["-L", server] if server else [])
    try:
        pid = subprocess.check_output(base + ["display-message", "-p", "-t", pane_id, "#{pane_pid}"], text=True).strip()
        children = subprocess.check_output(["pgrep", "-P", pid], text=True).split()
    except subprocess.CalledProcessError:
        return None
    for cpid in [pid] + children:
        try:
            args = subprocess.check_output(["ps", "-o", "args=", "-p", cpid], text=True)
        except subprocess.CalledProcessError:
            continue
        if "nvim" in args and "--listen" in args:
            parts = args.split()
            return parts[parts.index("--listen") + 1]
    return None
```
Change `connect()` to accept explicit overrides:
```python
def connect(socket=None, pane=None):
    session = _tmux_session_name()
    candidates = [
        socket,
        socket_for_pane(pane) if pane else None,
        os.environ.get("NVIM_LISTEN_ADDRESS"),
        os.environ.get("NVIM"),
        find_sibling_nvim_socket(),
        f"/tmp/nvim-server-{session}.pipe",
        "/tmp/nvim-server.pipe",  # legacy fallback
    ]
```
(rest of the function unchanged). In `main()`, parse the two global flags before the command:
```python
def main():
    argv = sys.argv[1:]
    socket = pane = None
    while argv and argv[0] in ("--socket", "--pane"):
        flag, val, argv = argv[0], argv[1], argv[2:]
        if flag == "--socket":
            socket = val
        else:
            pane = val
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)
    command = argv[0]
    if command not in COMMANDS:
        print(f"Unknown command: {command}", file=sys.stderr)
        print(f"Available: {', '.join(COMMANDS)}", file=sys.stderr)
        sys.exit(1)
    nvim = connect(socket=socket, pane=pane)
    COMMANDS[command](nvim, argv[1:])
```
Update the module docstring's usage line to `python3 nvim_bridge.py [--socket PATH | --pane %N] <command> [args...]`.

- [ ] **Step 2: Per-pane socket in the `vim` alias**

In `~/.config/nix-darwin/dotfiles/.zshrc`, replace line 50 (`alias vim='nvim --listen /tmp/nvim-server-$(tmux display-message -p "#S" 2>/dev/null || echo default).pipe'`) with:
```zsh
# One socket per tmux pane so several nvims in a session are individually addressable by the nvim bridge.
vim() {
  local sock
  if [[ -n "$TMUX_PANE" ]]; then
    sock="/tmp/nvim-$(tmux display-message -p '#S')-${TMUX_PANE#%}.pipe"
  else
    sock="/tmp/nvim-server-default.pipe"
  fi
  nvim --listen "$sock" "$@"
}
```
Verify in a new shell inside tmux: `vim` then in another pane `python3 ~/.config/nvim/scripts/nvim_bridge.py --pane <that pane id> state` returns JSON. (No `darwin-rebuild` needed — `.zshrc` is an out-of-store symlink.)

- [ ] **Step 3: Add `cockpit nvims`**

In `cli.py`:
```python
def cmd_nvims(args):
    import subprocess
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from nvim_bridge import socket_for_pane
    out = subprocess.run(["tmux", "list-panes", "-a", "-F", "#{pane_id}\t#{session_name}:#{window_name}\t#{pane_current_command}\t#{pane_current_path}"],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        pane, where, cmd, cwd = line.split("\t")
        if cmd == "nvim":
            print(f"{pane}\t{where}\t{socket_for_pane(pane) or '-'}\t{cwd}")
```
parser: `sp = sub.add_parser("nvims"); sp.set_defaults(fn=cmd_nvims)`.

- [ ] **Step 4: Install hooks and write the smoke test**

Run the installer once: `python3 ~/.config/nvim/scripts/hooks/install-cockpit-hooks.py` → prints the backup path. Check `jq '.hooks | keys' ~/.claude/settings.json` lists `PreCompact`, `Notification`, etc., and that the pre-existing `PreToolUse`/`ConfigChange`/`PostToolUse(Write)` entries are still present.

`scripts/cockpit-smoke.sh`:
```bash
#!/usr/bin/env bash
# End-to-end happy path on throwaway state. Leaves no repos, worktrees, or inner sessions behind.
set -euo pipefail
export COCKPIT_ROOT="$(mktemp -d)" COCKPIT_SESSION=smoke COCKPIT_WORKTREES="$(mktemp -d)"
CP="uv run --quiet $HOME/.config/nvim/scripts/cockpit.py"
src="$(mktemp -d)"; git -C "$src" init -q -b main; echo hi >"$src/README.md"; git -C "$src" add .; git -C "$src" commit -qm init
cleanup() { tmux -L cockpit kill-session -t =cockpit-smoke 2>/dev/null || true; rm -rf "$COCKPIT_ROOT" "$COCKPIT_WORKTREES" "$src"; }
trap cleanup EXIT

$CP init --goal "smoke test" >/dev/null
$CP track add feat-s --repo "$src" --branch feat/s >/dev/null
tmux -L cockpit list-windows -t =cockpit-smoke -F '#{window_name}' | grep -qx feat-s
pane="$($CP spawn agent feat-s --role impl -- --version | head -1)"          # `claude --version` exits immediately: a cheap stand-in
[[ "$pane" == %* ]]
$CP status --json | jq -e --arg p "$pane" '.[] | select(.pane_id==$p) | .track=="feat-s"' >/dev/null
doc="$($CP doc new plan --track feat-s --title "Smoke plan")"
$CP doc lint "$doc" | grep -qx ok
$CP annotate feat-s/01:3 "tighten the goal" --why style >/dev/null
$CP review send feat-s:agent --no-deliver >/dev/null
$CP doc list --track feat-s | grep -q "feat-s/02	steer"
jq -e '.why=="style"' "$COCKPIT_ROOT/smoke/feedback.jsonl" >/dev/null
$CP snapshot >/dev/null
git -C "$COCKPIT_ROOT" log --oneline | grep -q "steer(feat-s/02"
grep -q "| feat-s |" "$COCKPIT_ROOT/smoke/STATE.md"
$CP track rm feat-s --worktrees >/dev/null
echo "cockpit smoke OK"
```
Run: `bash scripts/cockpit-smoke.sh` → `cockpit smoke OK`. Also run `bash tests/test_marker_hook.sh` and the pytest suite (`8 passed`).

- [ ] **Step 5: Add the `cockpit` alias**

Append to `~/.config/nix-darwin/dotfiles/.zshrc` after the `vim` function:
```zsh
alias cockpit='uv run --quiet ~/.config/nvim/scripts/cockpit.py'
```

- [ ] **Step 6: Commit**

```bash
cd ~/.config/nvim && chmod +x scripts/cockpit-smoke.sh && git add scripts/nvim_bridge.py scripts/cockpit-smoke.sh scripts/cockpitlib/cli.py && git commit -m "feat(cockpit): bridge --socket/--pane targeting, nvims, smoke test"
cd ~/.config/nix-darwin && git add dotfiles/.zshrc && git commit -m "feat(zsh): per-pane nvim socket, cockpit alias"
```

---

### Task 11: Docs and skill pointer

**Files:**
- Modify: `docs/implementation-details.md` (Neovim Bridge section), `CLAUDE.md` (Configuration Structure + one rule), `~/.claude/skills/nvim-bridge/SKILL.md` (Connection section)

- [ ] **Step 1: Update project docs**

In `docs/implementation-details.md`, replace the "Neovim Bridge" socket-discovery bullet with:
```markdown
- Socket discovery: `--socket PATH` / `--pane %N` flags → `$NVIM_LISTEN_ADDRESS` → `$NVIM` → sibling tmux pane → `/tmp/nvim-server-<session>.pipe` → `/tmp/nvim-server.pipe`
- The `vim` shell function listens on `/tmp/nvim-<tmux-session>-<pane>.pipe`, one socket per pane
```
and add a section:
```markdown
## Cockpit (`scripts/cockpit.py`, `scripts/cockpitlib/`)

- Meta-harness CLI: git-tracked workspace at `~/.cockpit/<session>/`, agents as panes in an inner tmux server (`tmux -L cockpit`), Documents/Records with YAML-frontmatter lineage, steer loop (`annotate` → `review send`)
- Operator: `claude --agent cockpit` (`~/.claude/agents/cockpit.md`, versioned copy in `scripts/claude-agents/`)
- Hooks: `scripts/hooks/cockpit-marker.sh` (worker state markers), `scripts/hooks/cockpit-operator.sh` (snapshot / re-inject state); install with `scripts/hooks/install-cockpit-hooks.py`
- Spec: `docs/superpowers/specs/2026-08-28-cockpit-design.md`; smoke: `scripts/cockpit-smoke.sh`; tests: `uv run --with pytest --with pyyaml --with pynvim -m pytest tests -q`
```
In `CLAUDE.md` → Configuration Structure add: `` - `scripts/cockpit.py` + `scripts/cockpitlib/`: cockpit meta-harness CLI (see docs/implementation-details.md) ``. In `~/.claude/skills/nvim-bridge/SKILL.md` → Connection, add priority 0: `` `--socket PATH` or `--pane %N` given explicitly (use `cockpit nvims` to list) ``.

- [ ] **Step 2: Commit**

```bash
cd ~/.config/nvim && git add docs/implementation-details.md CLAUDE.md && git commit -m "docs: cockpit core and bridge targeting"
```

---

## Self-review notes

- **Spec coverage (steps 1–5):** §3 process tree — Tasks 2, 5, 7 (`up`, spawn into inner panes; nvim window attach is plan 2). §4 storage + git rules — Tasks 1, 3. §5 agent layer — Tasks 5, 6 (pane mode, markers, status rules for `needs_you` only from `Notification`); `--mode background|batch|team` deferred to plan 2 (spec build step 3 lists it; recorded as a gap to pick up there). §6 artifact model — Task 8. §7 CLI — verbs across Tasks 3–10 except `view *`, `focus`, `mark`, `last` (nvim hood, plan 2). §9 operator — Task 7. §11 smoke — Task 10.
- **Type consistency:** `list_agents` rows carry `pane_id role track status title updated window` everywhere; `tracks.get` returns the persisted dict with `window`; `docs.read` returns `(fm, body)` and `docs.write(path, fm, body)` everywhere; `steer.send` returns the record `Path`.
- **Known deferrals:** WorktreeCreate/Remove auto-registration and `TaskCompleted` hooks (plan 2); `metrics.jsonl` (build step 7).
