#!/usr/bin/env python3
"""
cockpit_inbox.py — agent side of the cockpit inbox (reviewed in nvim with <leader>ka).

Agents post documents, diffs and questions; the human annotates, answers and replies
with a verdict from nvim. Modeled on the Plannotator Inbox, stored as cockpit's own
append-only JSONL (one file per thread) so it survives any vendor.

Usage:
    cockpit_inbox.py post --title T [--thread ID] [--text TEXT|-] [--attach PATH]...
                          [--diff [REV]] [--question 'Text::opt1|opt2']... [--gate]
                          [--stage S [--pipeline P --stages a,b,c]] [--wait [--timeout S]]

Pipelines: one thread per run. Every post carries the stage it delivers (--stage); the first
post names the pipeline and its ordered stages. A stage post always gates: the run never moves
on until the human approves. Each post to a stage is a new round of that stage.
    cockpit_inbox.py wait ID [--timeout S]   exit 0 approved/replied, 1 changes requested, 2 rejected, 3 timeout
    cockpit_inbox.py read ID [--new]         whole thread, or only unread replies (and ack them)
    cockpit_inbox.py list
    cockpit_inbox.py card add TITLE [--lane L] [--thread ID] [--note N] [--owe TEXT]
    cockpit_inbox.py card move CARD LANE [--note N] [--owe TEXT]
    cockpit_inbox.py hook stop               Claude Code Stop hook (stdin: hook JSON), see hook_stop()

Storage ($COCKPIT_INBOX_DIR, default ~/.cockpit/inbox):
    threads/<id>.jsonl   events: message · reply · annotation · annotation_deleted · state · ack
    blobs/<sha256>       attachment bytes as sent, so annotations pin to what was reviewed
    waiting/<id>         heartbeat while an agent blocks in `wait` (nvim skips tmux delivery)
    cards.jsonl          board card snapshots, latest line per card wins
    feedback.jsonl       why-tagged steer ledger, written by nvim on send
"""

import argparse
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(os.environ.get("COCKPIT_INBOX_DIR", "~/.cockpit/inbox")).expanduser()
THREADS = ROOT / "threads"
BLOBS = ROOT / "blobs"
WAITING = ROOT / "waiting"
CARDS = ROOT / "cards.jsonl"
LANES = ["backlog", "todo", "in_progress", "in_review", "done", "cancelled"]
VERDICT_EXIT = {"changes_requested": 1, "reject": 2}
CLI = f"python3 {Path(__file__).resolve()}"
EDIT_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}
# The reply explains itself to the agent, so no skill has to teach the workflow up front
NEXT_STEP = {
    "approve": "Approved: proceed.",
    "edits": "The human edited your deliverables directly (patches above, against exactly what you sent). "
    "Treat the edited version as the new baseline: apply the patches to your files first.",
    "approve_with_notes": "Approved with notes: proceed, and apply the non-blocking notes as you go.",
    "changes_requested": "Changes requested: address every blocking note, then repost the revised files to this "
    "thread with `{cli} post --thread {tid} --text '<what changed>' --attach <files> | --diff`.",
    "reject": "Rejected: stop this approach. Ask what to do instead unless the reply says.",
    None: "Reply: act on it. If you change files, repost them with `{cli} post --thread {tid} ...`.",
}


def append(path, event):
    path.parent.mkdir(parents=True, exist_ok=True)
    event = {
        "v": 1,
        "at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "ts": int(time.time()),
        "id": secrets.token_hex(6),
        **{k: v for k, v in event.items() if v is not None},
    }
    with open(path, "a") as f:
        f.write(json.dumps(event) + "\n")
    return event


def read_jsonl(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def thread_path(tid, must_exist=True):
    path = THREADS / f"{tid}.jsonl"
    if must_exist and not path.exists():
        sys.exit(f"cockpit-inbox: no thread {tid}")
    return path


def git(*args, cwd=None, ok_codes=(0,)):
    res = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if res.returncode not in ok_codes:
        raise RuntimeError(res.stderr.strip())
    return res.stdout


def project_of(cwd):
    # Common dir, not toplevel: every worktree of a repo lands in the same project
    try:
        common = git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=cwd).strip()
        return Path(common).parent.name
    except (RuntimeError, FileNotFoundError):
        return Path(cwd).name


def session():
    return {
        "agent": os.environ.get("COCKPIT_AGENT") or "claude",
        "tmux_pane": os.environ.get("TMUX_PANE"),
        "cwd": os.getcwd(),
        "pid": os.getppid(),
    }


def snapshot(data, name, **extra):
    sha = hashlib.sha256(data).hexdigest()
    blob = BLOBS / sha
    if not blob.exists():
        BLOBS.mkdir(parents=True, exist_ok=True)
        blob.write_bytes(data)
    return {"name": name, "sha256": sha, **{k: v for k, v in extra.items() if v is not None}}


def git_diff(rev, cwd):
    patch = git("diff", rev, cwd=cwd)
    # `git diff REV` skips untracked files, which is most of what an agent creates
    for path in git("ls-files", "--others", "--exclude-standard", cwd=cwd).splitlines():
        patch += git("diff", "--no-index", "--", "/dev/null", path, cwd=cwd, ok_codes=(0, 1))
    return patch


def parse_question(n, spec):
    text, _, opts = spec.partition("::")
    return {"id": f"q{n}", "text": text.strip(), "options": [o.strip() for o in opts.split("|") if o.strip()]}


def slug(title):
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:40] or "thread"


def cmd_post(a):
    cwd = os.getcwd()
    if not a.thread and not a.title:
        sys.exit("cockpit-inbox: --title is required for a new thread")
    tid = a.thread or f"{datetime.now():%Y%m%d-%H%M%S}-{slug(a.title)}"
    path = thread_path(tid, must_exist=bool(a.thread))

    attachments = []
    for p in a.attach:
        fp = Path(p).expanduser().resolve()
        attachments.append(snapshot(fp.read_bytes(), fp.name, type="file", path=str(fp)))
    if a.diff is not None:
        rev = a.diff or "HEAD"
        patch = git_diff(rev, cwd)
        if not patch.strip():
            sys.exit(f"cockpit-inbox: empty diff against {rev}")
        head = git("rev-parse", "--short", "HEAD", cwd=cwd).strip()
        # Resolved now: the reviewer rebuilds both sides from it after HEAD has moved on
        base_sha = git("rev-parse", rev, cwd=cwd).strip()
        attachments.append(
            snapshot(
                patch.encode(),
                f"{project_of(cwd)}-{head}.diff",
                type="diff",
                base=rev,
                base_sha=base_sha,
                head=head,
                cwd=cwd,
            )
        )

    event = {
        "kind": "message",
        "from": "agent",
        "text": sys.stdin.read() if a.text == "-" else (a.text or ""),
        "attachments": attachments,
        "questions": [parse_question(i, q) for i, q in enumerate(a.question, 1)],
        "gate": (a.gate or bool(a.stage)) or None,
        "stage": a.stage,
        "pipeline": a.pipeline,
        "stages": [x.strip() for x in a.stages.split(",") if x.strip()] if a.stages else None,
        "session": {k: v for k, v in session().items() if v is not None},
    }
    if not path.exists():
        event |= {"title": a.title, "project": project_of(cwd)}
    append(path, {k: v for k, v in event.items() if v is not None})
    print(tid)
    if a.wait:
        sys.exit(wait(tid, a.timeout))


def pending_replies(events):
    acked = {e["reply"] for e in events if e["kind"] == "ack"}
    return [e for e in events if e["kind"] == "reply" and e["id"] not in acked]


def format_reply(tid, reply):
    verdict = reply.get("verdict") or "reply"
    out = [f"Inbox reply on thread {tid} — {verdict.replace('_', ' ')}"]
    if reply.get("text"):
        out += ["", reply["text"]]
    if reply.get("answers"):
        out += ["", "Answers:"] + [f"- {x['question']}: {x['answer']}" for x in reply["answers"]]
    if reply.get("annotations"):
        out += ["", "Annotations:"]
        for i, n in enumerate(reply["annotations"], 1):
            flag = ", blocking" if n.get("blocking") else ""
            out.append(f"{i}. [{n.get('label', 'comment')}{flag}] {n.get('loc', n.get('attachment', ''))}")
            out += [f"   > {line}" for line in (n.get("quote") or "").splitlines()]
            if n.get("text"):
                out.append(f"   {n['text']}")
    for ed in reply.get("edits") or []:
        out += ["", f"Edited by the human: {ed.get('path') or ed['attachment']}", "```diff", ed["patch"].rstrip(), "```"]
    if reply.get("edits"):
        out += ["", NEXT_STEP["edits"]]
    out += ["", NEXT_STEP[reply.get("verdict")].format(cli=CLI, tid=tid)]
    stage = reply.get("stage")
    if stage:
        out.append(stage_step(tid, stage, reply.get("verdict")))
    if any(n.get("label") in ("missing-convention", "missed-context") for n in reply.get("annotations") or []):
        out.append("Some notes are missing-convention/missed-context: say which belong in CLAUDE.md when you reply.")
    return "\n".join(out)


def stage_step(tid, stage, verdict):
    stages = next((e["stages"] for e in read_jsonl(thread_path(tid)) if e.get("stages")), [])
    i = stages.index(stage) if stage in stages else -1
    nxt = stages[i + 1] if 0 <= i < len(stages) - 1 else None
    post = f"{CLI} post --thread {tid} --stage {{s}} --text '<summary>' --attach <files> | --diff"
    if verdict in ("approve", "approve_with_notes"):
        if not nxt:
            return f"Pipeline: `{stage}` was the last stage; the run is done."
        return f"Pipeline: `{stage}` passed. Do the `{nxt}` stage next, then post its deliverables and stop:\n  " + post.format(s=nxt)
    if verdict == "reject":
        return f"Pipeline: `{stage}` rejected; the run is halted until the human says otherwise."
    return f"Pipeline: this is round feedback for `{stage}`; repost the revision as the same stage:\n  " + post.format(s=stage)


def emit(tid, replies):
    path = thread_path(tid)
    print("\n\n".join(format_reply(tid, r) for r in replies))
    for r in replies:
        append(path, {"kind": "ack", "reply": r["id"]})
    return VERDICT_EXIT.get(replies[-1].get("verdict"), 0)


def wait(tid, timeout):
    path = thread_path(tid)
    beat = WAITING / tid
    WAITING.mkdir(parents=True, exist_ok=True)
    deadline = time.time() + timeout if timeout else None
    try:
        while True:
            beat.touch()
            new = pending_replies(read_jsonl(path))
            if new:
                return emit(tid, new)
            if deadline and time.time() > deadline:
                print(f"cockpit-inbox: no reply on {tid} yet (timeout); run `wait {tid}` again")
                return 3
            time.sleep(2)
    finally:
        beat.unlink(missing_ok=True)


def cmd_wait(a):
    sys.exit(wait(a.thread, a.timeout))


def cmd_read(a):
    events = read_jsonl(thread_path(a.thread))
    if a.new:
        new = pending_replies(events)
        if not new:
            print(f"cockpit-inbox: no unread replies on {a.thread}")
            return
        sys.exit(emit(a.thread, new))
    for e in events:
        if e["kind"] == "message":
            print(f"## agent · {e['at']}\n{e.get('text', '')}")
            for att in e.get("attachments", []):
                print(f"  attached: {att['name']}")
            for q in e.get("questions", []):
                print(f"  ? {q['text']} {q['options'] or ''}")
        elif e["kind"] == "reply":
            print(f"## human · {e['at']}\n{format_reply(a.thread, e)}")
        print()


def cmd_list(_):
    for path in sorted(THREADS.glob("*.jsonl")):
        events = read_jsonl(path)
        last = next((e for e in reversed(events) if e["kind"] in ("message", "reply")), {})
        state = "replied" if last.get("kind") == "reply" else "open"
        print(f"{path.stem}\t{state}\t{events[0].get('title', '')}")


def cards():
    latest = {}
    for e in read_jsonl(CARDS):
        latest[e["card"]] = e
    return latest


def cmd_card(a):
    if a.card_cmd == "add":
        card = {"card": f"c-{secrets.token_hex(4)}", "title": a.title, "lane": a.lane, "thread": a.thread}
    else:
        card = cards().get(a.card)
        if not card:
            sys.exit(f"cockpit-inbox: no card {a.card}")
        card = {k: card[k] for k in ("card", "title", "thread", "note", "owe") if k in card} | {"lane": a.lane}
    if a.note is not None:
        card["note"] = a.note
    if a.owe is not None:
        card["owe"] = a.owe
    append(CARDS, {"kind": "card", "by": session()["agent"], **card})
    print(card["card"])


def human_text(entry):
    """Text of a human prompt; None for tool results, which also arrive as type=user."""
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        blocks = [b for b in content if isinstance(b, dict)]
        if blocks and not any(b.get("type") == "tool_result" for b in blocks):
            return "\n".join(b.get("text", "") for b in blocks if b.get("type") == "text")
    return None


def turn_activity(transcript):
    """What the agent did since the last human prompt: (posted?, edited files, inbox thread it was answering)."""
    entries = []
    try:
        for line in Path(transcript).read_text().splitlines():
            try:
                entries.append(json.loads(line))
            except ValueError:
                pass
    except (OSError, TypeError):
        return False, [], None
    entries = [e for e in entries if not e.get("isSidechain")]
    start = next(
        (i for i in range(len(entries) - 1, -1, -1) if entries[i].get("type") == "user" and human_text(entries[i])),
        0,
    )
    prompt = human_text(entries[start]) if entries else ""
    reply_thread = (m := re.search(r"Inbox reply on thread (\S+?)\.", prompt or "")) and m.group(1)
    posted, edited = False, []
    for e in entries[start:]:
        if e.get("type") != "assistant":
            continue
        for b in (e.get("message") or {}).get("content") or []:
            if not isinstance(b, dict) or b.get("type") != "tool_use":
                continue
            inp = b.get("input") or {}
            if b.get("name") == "Bash" and "cockpit_inbox.py" in inp.get("command", "") and " post" in inp["command"]:
                posted = True
            elif b.get("name") in EDIT_TOOLS:
                edited.append(inp.get("file_path") or inp.get("notebook_path"))
    return posted, [f for f in dict.fromkeys(edited) if f], reply_thread


def watching(pane):
    # Pane focused in the focused window of an attached session: you're reading the terminal already
    try:
        out = subprocess.run(
            ["tmux", "display-message", "-p", "-t", pane, "#{pane_id} #{pane_active} #{window_active} #{session_attached}"],
            capture_output=True,
            text=True,
            timeout=2,
        ).stdout.split()
    except (OSError, subprocess.SubprocessError):
        return False
    # display -t falls back to the current pane for a missing target, so confirm it answered for ours
    return len(out) == 4 and out[0] == pane and out[1:3] == ["1", "1"] and out[3] != "0"


def hook_stop(payload):
    """
    Route an unattended stop to the inbox:
      watched pane / already posted / second stop (stop_hook_active) -> allow
      edited files but posted nothing -> block, telling the agent how to post them for review
      anything else -> allow, posting the last message as an FYI (a trailing '?' makes it a question)
    """
    pane = os.environ.get("TMUX_PANE")
    if not pane or os.environ.get("COCKPIT_INBOX_HOOK") == "0" or payload.get("stop_hook_active"):
        return None
    if watching(pane):
        return None
    posted, edited, reply_thread = turn_activity(payload.get("transcript_path"))
    if posted:
        return None
    thread_hint = f"--thread {reply_thread}" if reply_thread else "--title '<short title>'"
    if edited:
        docs = [f for f in edited if f.endswith((".md", ".mdx", ".txt"))]
        code = [f for f in edited if f not in docs]
        how = " ".join(
            filter(None, [f"--attach {' --attach '.join(docs)}" if docs else "", "--diff" if code else ""])
        )
        return {
            "decision": "block",
            "reason": "You changed files while the user is away; post them to their inbox for review before stopping:\n"
            f"  {CLI} post {thread_hint} --text '<one-paragraph summary: intent, risk, how to test>' {how}\n"
            "Add --question 'Text::A|B' if you need a decision, or --gate if you need an explicit approval. "
            "Then stop; the user's reply will arrive as a new prompt.",
        }

    text = (payload.get("last_assistant_message") or "").strip()
    if not text:
        return None
    tid = reply_thread or f"session-{(payload.get('session_id') or 'unknown')[:8]}"
    path = THREADS / f"{tid}.jsonl"
    last_line = text.splitlines()[-1].strip()
    event = {
        "kind": "message",
        "from": "agent",
        "text": text,
        "attachments": [],
        "questions": [{"id": "q1", "text": last_line, "options": []}] if last_line.endswith("?") else [],
        "session": {k: v for k, v in session().items() if v is not None},
    }
    if not path.exists():
        cwd = payload.get("cwd") or os.getcwd()
        title = re.sub(r"^[#*\s]+", "", text.splitlines()[0])[:60] or tid
        event |= {"title": title, "project": project_of(cwd)}
    append(path, event)
    return None


def cmd_hook(a):
    try:
        decision = hook_stop(json.load(sys.stdin))
    except Exception as e:  # a hook bug must never wedge the agent
        print(f"cockpit-inbox hook: {e}", file=sys.stderr)
        return
    if decision:
        print(json.dumps(decision))


def main():
    p = argparse.ArgumentParser(prog="cockpit_inbox.py", description="Agent side of the cockpit inbox")
    sub = p.add_subparsers(dest="cmd", required=True)

    post = sub.add_parser("post", help="post a message, documents, a diff or questions")
    post.add_argument("--title")
    post.add_argument("--thread", help="append to an existing thread")
    post.add_argument("--text", help="message body, or - for stdin")
    post.add_argument("--attach", action="append", default=[], metavar="PATH")
    post.add_argument("--diff", nargs="?", const="", metavar="REV", help="attach git diff vs REV (default HEAD)")
    post.add_argument("--question", action="append", default=[], metavar="'TEXT::A|B'")
    post.add_argument("--gate", action="store_true", help="ask for an explicit verdict")
    post.add_argument("--stage", default=os.environ.get("COCKPIT_STAGE"), help="pipeline stage this post delivers")
    post.add_argument("--pipeline", default=os.environ.get("COCKPIT_PIPELINE"), help="pipeline name (first post)")
    post.add_argument("--stages", help="ordered stages, comma-separated (first post)")
    post.add_argument("--wait", action="store_true", help="block until the human replies")
    post.add_argument("--timeout", type=int, default=0, metavar="S")
    post.set_defaults(fn=cmd_post)

    w = sub.add_parser("wait", help="block until a reply arrives")
    w.add_argument("thread")
    w.add_argument("--timeout", type=int, default=0, metavar="S")
    w.set_defaults(fn=cmd_wait)

    r = sub.add_parser("read", help="print a thread")
    r.add_argument("thread")
    r.add_argument("--new", action="store_true", help="only unread replies, then ack them")
    r.set_defaults(fn=cmd_read)

    sub.add_parser("list", help="list threads").set_defaults(fn=cmd_list)

    c = sub.add_parser("card", help="board cards").add_subparsers(dest="card_cmd", required=True)
    add = c.add_parser("add")
    add.add_argument("title")
    add.add_argument("--lane", choices=LANES, default="in_progress")
    add.add_argument("--thread")
    move = c.add_parser("move")
    move.add_argument("card")
    move.add_argument("lane", choices=LANES)
    for sp in (add, move):
        sp.add_argument("--note")
        sp.add_argument("--owe", help="what the human owes, e.g. 'approve the copy'")
        sp.set_defaults(fn=cmd_card)

    h = sub.add_parser("hook", help="Claude Code hook entry point")
    h.add_argument("event", choices=["stop"])
    h.set_defaults(fn=cmd_hook)

    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
