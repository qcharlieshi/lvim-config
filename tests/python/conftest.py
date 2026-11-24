import importlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "cockpit_inbox.py"
FIXTURES = REPO / "tests" / "fixtures" / "threads"
sys.path.insert(0, str(SCRIPT.parent))

# Anything that would let the CLI reach a real pane, herdr server, Claude session or inbox
LEAKY = ("TMUX", "TMUX_PANE", "CLAUDE_CODE_SESSION_ID", "COCKPIT_PROJECT", "COCKPIT_AGENT", "COCKPIT_STAGE",
         "COCKPIT_PIPELINE", "COCKPIT_HERDR_SESSION", "COCKPIT_INBOX_HOOK")


@pytest.fixture
def env(tmp_path, monkeypatch):
    for k in list(os.environ):
        if k in LEAKY or k.startswith("HERDR_"):
            monkeypatch.delenv(k)
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("COCKPIT_INBOX_DIR", str(tmp_path / "inbox"))
    monkeypatch.setenv("COCKPIT_ATTACH_DIR", str(tmp_path / "attached"))
    (tmp_path / "home").mkdir()
    return tmp_path


@pytest.fixture
def ck(env):
    """cockpit_inbox imported against the temp inbox (it reads the env at import time)."""
    import cockpit_inbox

    return importlib.reload(cockpit_inbox)


@pytest.fixture
def cli(env):
    """Run the CLI as an agent would; returns CompletedProcess."""

    def run(*args, stdin=None, extra_env=None):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            input=stdin,
            capture_output=True,
            text=True,
            env=os.environ | (extra_env or {}),
            cwd=env,
            timeout=30,
        )

    return run


@pytest.fixture
def fixture_inbox(ck):
    """The golden thread fixtures copied into the temp inbox."""
    ck.THREADS.mkdir(parents=True, exist_ok=True)
    for f in FIXTURES.glob("*.jsonl"):
        shutil.copy(f, ck.THREADS / f.name)
    return json.loads((FIXTURES / "expected.json").read_text())
