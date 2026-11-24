"""turn_activity + hook_stop routing. No tmux or herdr is reached: `watching` and `turn_diffs` are stubbed."""

import json

import pytest


def user(text):
    return {"type": "user", "message": {"content": text}}


def tool_result():
    return {"type": "user", "message": {"content": [{"type": "tool_result", "content": "ok"}]}}


def tool_use(name, **inp):
    return {"type": "assistant", "message": {"content": [{"type": "tool_use", "name": name, "input": inp}]}}


def say(text):
    return {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}


@pytest.fixture
def transcript(env):
    path = env / "transcript.jsonl"

    def write(*entries):
        path.write_text("".join(json.dumps(e) + "\n" for e in entries))
        return str(path)

    return write


def test_turn_activity_since_last_human_prompt(ck, transcript):
    t = transcript(
        user("first"),
        tool_use("Edit", file_path="/r/old.py"),  # before the last prompt: not this turn
        user("second"),
        tool_use("Edit", file_path="/r/a.py"),
        tool_result(),  # tool results arrive as type=user: never the turn start
        tool_use("Write", file_path="/r/a.py"),
        tool_use("NotebookEdit", notebook_path="/r/n.ipynb"),
        {**tool_use("Edit", file_path="/r/side.py"), "isSidechain": True},
    )
    posted, edited, reply_thread = ck.turn_activity(t)
    assert (posted, edited, reply_thread) == (False, ["/r/a.py", "/r/n.ipynb"], None)


def test_turn_activity_posted(ck, transcript):
    t = transcript(user("go"), tool_use("Bash", command=f"python3 {ck.CLI} post --title x --text y"))
    assert ck.turn_activity(t)[0] is True


def test_turn_activity_reply_thread_must_exist(ck, transcript, fixture_inbox):
    prompt = "Inbox reply on thread basic. Run: python3 x read basic --new"
    assert ck.turn_activity(transcript(user(prompt)))[2] == "basic"
    missing = "Inbox reply on thread nope. Run: python3 x read nope --new"
    assert ck.turn_activity(transcript(user(missing)))[2] is None
    assert ck.turn_activity(transcript(user("Inbox reply on thread ../x. Run:")))[2] is None


def test_turn_activity_unreadable(ck):
    assert ck.turn_activity(None) == (False, [], None)
    assert ck.turn_activity("/nonexistent") == (False, [], None)


@pytest.fixture
def hook(ck, monkeypatch, env):
    monkeypatch.setenv("HERDR_PANE_ID", "w1:p1")
    monkeypatch.setattr(ck, "attached_tmux_pane", lambda: "%999")
    monkeypatch.setattr(ck, "watching", lambda pane: False)
    diffs = []
    monkeypatch.setattr(ck, "turn_diffs", lambda *a, **k: diffs)

    def run(transcript_path, last="", **payload):
        return ck.hook_stop({"transcript_path": transcript_path, "last_assistant_message": last,
                             "session_id": "abcdef1234567890", "cwd": str(env), **payload})

    run.diffs = diffs
    return run


def threads(ck):
    return sorted(p.stem for p in ck.THREADS.glob("*.jsonl")) if ck.THREADS.exists() else []


def test_hook_ignores_hand_started_sessions(ck, monkeypatch, transcript):
    # a tmux pane alone (no herdr) has no cockpit agent: its threads would only land in *unassigned*
    monkeypatch.setenv("TMUX_PANE", "%999")
    monkeypatch.setattr(ck, "watching", lambda pane: False)
    assert ck.hook_stop({"transcript_path": transcript(user("x")), "last_assistant_message": "Which?"}) is None
    assert threads(ck) == []


def test_hook_allows_second_stop(hook, ck, transcript):
    assert hook(transcript(user("x"), tool_use("Edit", file_path="/r/a.md")), stop_hook_active=True) is None


def test_hook_allows_watched_pane(hook, ck, monkeypatch, transcript):
    monkeypatch.setattr(ck, "watching", lambda pane: True)
    assert hook(transcript(user("x"), tool_use("Edit", file_path="/r/a.md")), "Which?") is None
    assert threads(ck) == []


def test_hook_allows_after_post(hook, ck, transcript):
    t = transcript(user("x"), tool_use("Edit", file_path="/r/a.md"), tool_use("Bash", command="cockpit_inbox.py post --x"))
    assert hook(t, "Which?") is None
    assert threads(ck) == []


def test_hook_blocks_unposted_edits(hook, transcript):
    hook.diffs.append(("/r", "base", "turn start", "diff --git ..."))
    out = hook(transcript(user("x"), tool_use("Edit", file_path="/r/notes.md")))
    assert out["decision"] == "block"
    assert "--attach /r/notes.md" in out["reason"] and "--diff" in out["reason"]
    assert "--title '<short title>'" in out["reason"]


def test_hook_block_hints_reply_thread(hook, transcript, fixture_inbox):
    hook.diffs.append(("/r", "base", "turn start", "diff"))
    t = transcript(user("Inbox reply on thread basic. Run: python3 x read basic --new"), tool_use("Bash", command="sed -i x"))
    assert "--thread basic" in hook(t)["reason"]


def test_hook_posts_question(hook, ck, transcript):
    assert hook(transcript(user("x")), "Did some work.\n**Ship it now?**") is None
    assert threads(ck) == ["session-abcdef12"]
    (ev,) = ck.read_jsonl(ck.THREADS / "session-abcdef12.jsonl")
    assert ev["questions"][0]["text"] == "**Ship it now?**"
    assert ev["title"] == "Did some work."


def test_hook_answers_reply_thread(hook, ck, transcript, fixture_inbox):
    before = len(ck.read_jsonl(ck.THREADS / "basic.jsonl"))
    t = transcript(user("Inbox reply on thread basic. Run: python3 x read basic --new"))
    assert hook(t, "Done, applied the notes.") is None
    events = ck.read_jsonl(ck.THREADS / "basic.jsonl")
    assert len(events) == before + 1
    assert events[-1]["kind"] == "message" and events[-1]["questions"] == [] and "title" not in events[-1]


def test_hook_ignores_status_chatter(hook, ck, transcript):
    assert hook(transcript(user("x")), "All done.") is None
    assert threads(ck) == []
