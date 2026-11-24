"""format_reply / stage_step: the text an agent reads back, which carries its next instructions."""


def test_format_reply_changes_requested(ck, fixture_inbox):
    reply = {
        "id": "r9",
        "verdict": "changes_requested",
        "text": "Tighten it.",
        "answers": [{"question": "Which?", "answer": "A"}],
        "annotations": [{"label": "missed-context", "blocking": True, "loc": "plan.md:3", "quote": "foo", "text": "why"}],
        "edits": [{"attachment": "plan.md", "path": "/tmp/repo/plan.md", "patch": "--- a/plan.md\n+++ b/plan.md\n"}],
    }
    out = ck.format_reply("basic", reply)
    assert out.startswith("Inbox reply on thread basic — changes requested")
    assert "- Which?: A" in out
    assert "1. [missed-context, blocking] plan.md:3" in out and "   > foo" in out
    assert "Edited by the human: /tmp/repo/plan.md" in out and "```diff" in out
    assert ck.NEXT_STEP["edits"] in out
    assert f"{ck.CLI} post --thread basic" in out
    assert "say which belong in CLAUDE.md" in out


def test_format_reply_plain(ck, fixture_inbox):
    out = ck.format_reply("basic", {"id": "r1", "text": "thanks"})
    assert out.startswith("Inbox reply on thread basic — reply")
    assert "Reply: act on it." in out


def test_stage_step(ck, fixture_inbox):
    assert "Do the `build` stage next" in ck.stage_step("pipeline", "plan", "approve")
    assert "--stage build" in ck.stage_step("pipeline", "plan", "approve_with_notes")
    assert "was the last stage" in ck.stage_step("pipeline", "build", "approve")
    assert "halted" in ck.stage_step("pipeline", "plan", "reject")
    assert "repost the revision as the same stage" in ck.stage_step("pipeline", "plan", "changes_requested")


def test_format_reply_appends_stage_step(ck, fixture_inbox):
    out = ck.format_reply("pipeline", {"id": "r2", "verdict": "approve", "stage": "plan"})
    assert "Approved: proceed." in out and "Do the `build` stage next" in out
