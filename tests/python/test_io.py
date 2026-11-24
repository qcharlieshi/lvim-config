"""Log I/O safety (review 0.3, 1.7): torn lines, single-write appends, ids that become paths."""

import json
import multiprocessing
import shutil

import pytest

from conftest import FIXTURES


def test_wait_survives_torn_last_line(cli, ck):
    # nvim is mid-write on a reply when `wait` polls: the half line must read as "no reply yet", not crash
    ck.THREADS.mkdir(parents=True)
    message = (FIXTURES / "basic.jsonl").read_text().splitlines()[0]
    (ck.THREADS / "t1.jsonl").write_text(message + '\n{"v": 1, "ts": 1, "id": "r2", "kind": "reply", "verdict": "chan')
    res = cli("wait", "t1", "--timeout", "1")
    assert res.returncode == 12, res.stderr  # timeout: nothing complete to read
    assert "Traceback" not in res.stderr


def test_read_jsonl_skips_torn_garbage_and_unknown_versions(ck):
    events = ck.read_jsonl(FIXTURES / "torn.jsonl")
    assert [e["id"] for e in events] == ["m1", "r1"]
    assert [e["id"] for e in ck.read_jsonl(FIXTURES / "unterminated.jsonl")] == ["m1"]


def _hammer(args):
    root, n, size = args
    import importlib
    import os

    os.environ["COCKPIT_INBOX_DIR"] = root
    import cockpit_inbox

    importlib.reload(cockpit_inbox)
    for i in range(n):
        cockpit_inbox.append(cockpit_inbox.THREADS / "t.jsonl", {"kind": "message", "text": "x" * size, "n": i})


def test_concurrent_large_appends_stay_whole(ck):
    # each event is one write() on an O_APPEND fd: concurrent writers can't interleave inside a line
    with multiprocessing.get_context("spawn").Pool(4) as pool:
        pool.map(_hammer, [(str(ck.ROOT), 20, 200_000 + k) for k in range(4)])
    lines = (ck.THREADS / "t.jsonl").read_bytes().split(b"\n")
    assert lines[-1] == b""
    assert len(lines) - 1 == 80
    for line in lines[:-1]:
        json.loads(line)


@pytest.mark.parametrize("tid", ["../evil", "a/b", "x y", "", "a.b"])
def test_thread_ids_that_escape_are_usage_errors(cli, ck, tid):
    ck.THREADS.mkdir(parents=True, exist_ok=True)
    (ck.ROOT / "evil.jsonl").write_text("")  # what threads/../evil.jsonl resolves to
    for args in (["post", "--thread", tid, "--text", "x"], ["wait", tid], ["read", tid],
                 ["card", "add", "c", "--thread", tid]):
        res = cli(*args)
        assert res.returncode == 64, (args, res.returncode, res.stderr)
    assert (ck.ROOT / "evil.jsonl").read_text() == ""


def test_snapshot_session_id_is_validated(cli, env):
    assert cli("snapshot", "../../x", str(env), "1").returncode == 64


def test_reply_edit_patch_from_blob(ck, fixture_inbox):
    # nvim keeps reply events small: edit patches live in blobs/ and the reply carries their sha
    patch = "--- a/plan.md\n+++ b/plan.md\n@@ -1 +1 @@\n-a\n+b\n"
    sha = ck.snapshot(patch.encode(), "patch")["sha256"]
    out = ck.format_reply("basic", {"id": "r", "edits": [{"attachment": "plan.md", "patch_sha256": sha}]})
    assert "+b" in out and "Edited by the human: plan.md" in out
    inline = ck.format_reply("basic", {"id": "r", "edits": [{"attachment": "plan.md", "patch": patch}]})
    assert "+b" in inline
