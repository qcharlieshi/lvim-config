"""Golden fixtures (tests/fixtures/threads): what the Python side derives must match expected.json,
which tests/lua/test_store.lua asserts against store.thread() too."""


def test_pending_replies_match_golden(ck, fixture_inbox):
    for name, want in fixture_inbox.items():
        events = ck.read_jsonl(ck.thread_path(name))
        got = [e["id"] for e in ck.pending_replies(events)]
        assert got == want["pending_replies"], name


def test_ack_clears_pending(ck, fixture_inbox):
    path = ck.thread_path("pipeline")
    ck.append(path, {"kind": "ack", "reply": "r2"})
    assert ck.pending_replies(ck.read_jsonl(path)) == []


def test_append_envelope(ck, env):
    path = ck.THREADS / "t1.jsonl"
    ev = ck.append(path, {"kind": "message", "text": "hi", "gate": None})
    assert {"v", "at", "ts", "id"} <= set(ev)
    assert "gate" not in ev
    assert ck.read_jsonl(path) == [ev]
