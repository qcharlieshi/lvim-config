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
    cockpit_inbox.py wait ID [--timeout S]   block until the human replies (exit codes below)
    cockpit_inbox.py read ID [--new]         whole thread, or only unread replies (and ack them)
    cockpit_inbox.py list
    cockpit_inbox.py card add TITLE [--lane L] [--thread ID] [--note N] [--owe TEXT]
    cockpit_inbox.py card move CARD LANE [--note N] [--owe TEXT]
    cockpit_inbox.py hook stop               Claude Code Stop hook (stdin: hook JSON), see hook_stop()
    cockpit_inbox.py hook prompt             UserPromptSubmit hook: snapshot repos at turn start (turns/)
    cockpit_inbox.py backfill-sessions [--dry-run]   tag legacy threads with the Claude session that posted them

Exit codes (post --wait, wait, read --new): a verdict and an error never share a code.
    0  approved, approved with notes, or a plain reply    10 changes requested    11 rejected    12 wait timed out
    64 usage error    65 nothing to post (empty diff)    66 no such thread or card    70 internal error (traceback)

--diff without REV, inside a Claude session: one diff per repo this turn changed, measured from the
turn-start snapshot (so the human's own uncommitted work is left out), else the edited files vs HEAD.

Storage ($COCKPIT_INBOX_DIR, default ~/.cockpit/inbox):
    threads/<id>.jsonl   events: message · reply · annotation · annotation_deleted · state · ack · delivery
    blobs/<sha256>       attachment bytes as sent, so annotations pin to what was reviewed
    turns/<session>.json repo states at the session's latest prompt (head, stash-create snap, untracked)
    waiting/<id>         heartbeat while an agent blocks in `wait` (nvim skips prompt delivery)
    cards.jsonl          board card snapshots, latest line per card wins
    feedback.jsonl       why-tagged steer ledger, written by nvim on send
"""

import argparse
import hashlib
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import time
import traceback
from datetime import datetime
from pathlib import Path

ROOT = Path(os.environ.get("COCKPIT_INBOX_DIR", "~/.cockpit/inbox")).expanduser()
THREADS = ROOT / "threads"
BLOBS = ROOT / "blobs"
WAITING = ROOT / "waiting"
CARDS = ROOT / "cards.jsonl"
LANES = ["backlog", "todo", "in_progress", "in_review", "done", "cancelled"]
# Verdicts 10-12, errors 64+ (sysexits.h): Python's own failures (1) and argparse's (2) can't pass for a verdict
VERDICT_EXIT = {"changes_requested": 10, "reject": 11}
EXIT_TIMEOUT = 12
EX_USAGE, EX_DATAERR, EX_NOINPUT, EX_SOFTWARE = 64, 65, 66, 70
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


def die(msg, code):
    print(f"cockpit-inbox: {msg}", file=sys.stderr)
    sys.exit(code)


def append(path, event):
    path.parent.mkdir(parents=True, exist_ok=True)
    event = {
        "v": 1,
        "at": datetime.now().astimezone().isoformat(timespec="seconds"),
        "ts": int(time.time()),
        "id": secrets.token_hex(6),
        **{k: v for k, v in event.items() if v is not None},
    }
    data = (json.dumps(event) + "\n").encode()
    # One write() on an O_APPEND fd: concurrent writers can't interleave inside a line, readers see all or nothing
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        if os.write(fd, data) != len(data):
            raise OSError(f"short write to {path}")
    finally:
        os.close(fd)
    return event


def read_jsonl(path):
    """Complete events only: a last line without its newline is a write still in flight, a bad line is skipped,
    and an event from a schema version this reader doesn't know is ignored (same rules as store.lua)."""
    try:
        lines = path.read_bytes().split(b"\n")[:-1]
    except FileNotFoundError:
        return []
    out = []
    for line in lines:
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if isinstance(e, dict) and e.get("v", 1) == 1:
            out.append(e)
    return out


VALID_ID = re.compile(r"[A-Za-z0-9_-]+")


def valid_id(s):
    """Thread and session ids become file names: nothing that can leave its directory."""
    return isinstance(s, str) and VALID_ID.fullmatch(s) is not None


def check_id(s, what="thread id"):
    if not valid_id(s):
        die(f"invalid {what} {s!r} (allowed: letters, digits, _ and -)", EX_USAGE)
    return s


def thread_path(tid, must_exist=True):
    path = THREADS / f"{check_id(tid)}.jsonl"
    if must_exist and not path.exists():
        die(f"no thread {tid}", EX_NOINPUT)
    return path


def git(*args, cwd=None, ok_codes=(0,)):
    res = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if res.returncode not in ok_codes:
        raise RuntimeError(res.stderr.strip())
    return res.stdout


PROJECTS = Path(os.environ.get("COCKPIT_PROJECTS_DIR", "~/.cockpit/projects")).expanduser()


def project_containing(cwd):
    """The defined project whose dir is cwd or contains it; the longest (most specific) dir wins."""
    here = os.path.realpath(cwd)
    best, length = None, -1
    for f in PROJECTS.glob("*/project.json"):
        try:
            p = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        for r in p.get("repos") or []:
            r = os.path.realpath(os.path.expanduser(r))
            if (here == r or here.startswith(r + "/")) and len(r) > length:
                best, length = p.get("name") or f.parent.name, len(r)
    return best


def project_of(cwd):
    # Agents spawned by cockpit carry their project in the pane env (herdr workspace.create/tab.create env)
    if os.environ.get("COCKPIT_PROJECT"):
        return os.environ["COCKPIT_PROJECT"]
    found = project_containing(cwd)
    if found:
        return found
    # No defined project: the repo's common dir, so every worktree of a repo groups together
    try:
        common = git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=cwd).strip()
        return Path(common).parent.name
    except (RuntimeError, FileNotFoundError):
        return Path(cwd).name


def herdr_socket():
    if os.environ.get("HERDR_SOCKET_PATH"):
        return os.environ["HERDR_SOCKET_PATH"]
    base = Path("~/.config/herdr").expanduser()
    name = os.environ.get("COCKPIT_HERDR_SESSION")
    return str(base / "sessions" / name / "herdr.sock" if name else base / "herdr.sock")


def herdr_call(method, params):
    """One request over herdr's NDJSON socket API; the result dict, or None on any failure."""
    try:
        with socket.socket(socket.AF_UNIX) as s:
            s.settimeout(2)
            s.connect(herdr_socket())
            s.sendall((json.dumps({"id": "ck", "method": method, "params": params}) + "\n").encode())
            buf = b""
            while b"\n" not in buf:
                chunk = s.recv(65536)
                if not chunk:
                    return None
                buf += chunk
        return json.loads(buf.split(b"\n", 1)[0]).get("result")
    except (OSError, ValueError):
        return None


def herdr_identity():
    """This process's herdr pane, resolved by explicit pane id (never --current: herdr #2900)."""
    pane_id = os.environ.get("HERDR_PANE_ID")
    if os.environ.get("HERDR_ENV") != "1" or not pane_id:
        return None
    pane = (herdr_call("pane.get", {"pane_id": pane_id}) or {}).get("pane")
    if not pane:
        return None
    ident = {k: pane.get(k) for k in ("pane_id", "workspace_id", "terminal_id")}
    agents = (herdr_call("agent.list", {}) or {}).get("agents") or []
    mine = next((a for a in agents if a.get("pane_id") == pane_id), {})
    sid = (mine.get("agent_session") or {}).get("value")
    return ident | ({"name": mine["name"]} if mine.get("name") else {}) | ({"session_id": sid} if sid else {})


CLAUDE_DIR = Path(os.environ.get("COCKPIT_CLAUDE_DIR", "~/.claude")).expanduser()


def claude_session_id():
    """The session of the nearest Claude ancestor. The parent is often a Bash-tool shell, not Claude, so walk up
    to the first pid with a ~/.claude/sessions/<pid>.json."""
    pid = os.getppid()
    for _ in range(8):
        try:
            return json.loads((CLAUDE_DIR / "sessions" / f"{pid}.json").read_text())["sessionId"]
        except (OSError, ValueError, KeyError):
            pass
        try:
            pid = int(subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)], capture_output=True, text=True).stdout)
        except ValueError:
            return None
        if pid <= 1:
            return None
    return None


def session():
    herdr = herdr_identity()
    return {
        "agent": os.environ.get("COCKPIT_AGENT") or "claude",
        "tmux_pane": os.environ.get("TMUX_PANE"),
        "herdr": herdr,
        "session_id": (herdr or {}).get("session_id") or claude_session_id(),
        "cwd": os.getcwd(),
        "pid": os.getppid(),
    }


def snapshot(data, name, **extra):
    sha = hashlib.sha256(data).hexdigest()
    blob = BLOBS / sha
    if not blob.exists():
        BLOBS.mkdir(parents=True, exist_ok=True)
        tmp = BLOBS / f".{sha}.{secrets.token_hex(4)}"  # renamed into place: a blob is never seen half-written
        tmp.write_bytes(data)
        tmp.replace(blob)
    return {"name": name, "sha256": sha, **{k: v for k, v in extra.items() if v is not None}}


def edit_patch(ed):
    """A reply edit's patch: inline (older replies) or in blobs/ by sha (store.lua keeps reply lines small)."""
    if ed.get("patch") is not None:
        return ed["patch"]
    sha = ed.get("patch_sha256")
    try:
        return (BLOBS / check_id(sha, "blob sha")).read_text()
    except OSError:
        return f"(patch blob missing: {sha})"


def git_diff(rev, cwd, paths=None, skip_untracked=(), exclude=()):
    """Worktree vs REV, plus untracked files (which `git diff REV` skips — most of what an agent creates).
    paths: limit to these repo-relative paths; skip_untracked: untracked files that predate the turn;
    exclude: repo-relative paths left out (markdown sent as editable documents instead)."""
    spec = list(paths) if paths is not None else ["."]
    if paths is not None and not spec:
        return ""
    spec += [f":(exclude){p}" for p in exclude]
    patch = git("diff", rev, "--", *spec, cwd=cwd)
    skip = set(skip_untracked) | set(exclude)
    for path in git("ls-files", "--others", "--exclude-standard", "--", *spec, cwd=cwd).splitlines():
        if path not in skip:
            patch += git("diff", "--no-index", "--", "/dev/null", path, cwd=cwd, ok_codes=(0, 1))
    return patch


# ---------------------------------------------------------------------------
# Turn snapshots: what a turn changed, per repo, without the human's own uncommitted work
# ---------------------------------------------------------------------------
TURNS = ROOT / "turns"
TURN_STALE = 7 * 86400


def toplevel(path):
    p = Path(path)
    d = p if p.is_dir() else p.parent
    while not d.exists() and d != d.parent:  # a deleted file's dir may be gone too
        d = d.parent
    try:
        return git("rev-parse", "--show-toplevel", cwd=d).strip() or None
    except (RuntimeError, OSError):
        return None


def repos_under(cwd):
    """The repo containing cwd; outside git (an org root like ~/dev/lilt), the repos directly under it."""
    top = toplevel(cwd)
    if top:
        return [top]
    try:
        return sorted(str(d) for d in Path(cwd).iterdir() if d.is_dir() and (d / ".git").exists())
    except OSError:
        return []


def repo_state(repo):
    head = git("rev-parse", "HEAD", cwd=repo).strip()
    # A commit of the dirty worktree + index, made without touching either; empty output = clean
    snap = git("stash", "create", cwd=repo).strip() or head
    untracked = git("ls-files", "--others", "--exclude-standard", cwd=repo).splitlines()
    return {"head": head, "snap": snap, "untracked": untracked}


def cmd_snapshot(a):
    """Detached child of the UserPromptSubmit hook: record every repo's state at turn start."""
    check_id(a.session, "session id")
    repos = {}
    for r in repos_under(a.cwd):
        try:
            repos[r] = repo_state(r)
        except (RuntimeError, OSError):
            pass  # empty repo (no HEAD), permissions: no snapshot, fall back to edited paths
    TURNS.mkdir(parents=True, exist_ok=True)
    out = TURNS / f"{a.session}.json"
    tmp = out.with_suffix(".tmp")
    tmp.write_text(json.dumps({"ts": a.ts, "cwd": a.cwd, "transcript": a.transcript, "repos": repos}))
    tmp.replace(out)
    now = time.time()
    for f in TURNS.glob("*.json"):
        if now - f.stat().st_mtime > TURN_STALE:
            f.unlink(missing_ok=True)


def hook_prompt(payload):
    if not (os.environ.get("TMUX_PANE") or os.environ.get("HERDR_PANE_ID")):
        return
    if os.environ.get("COCKPIT_INBOX_HOOK") == "0" or not payload.get("session_id"):
        return
    # git stash create over a dozen repos takes a while: never hold up the prompt
    subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "snapshot", payload["session_id"],
         payload.get("cwd") or os.getcwd(), str(time.time()), payload.get("transcript_path") or ""],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
    )


def find_transcript(sid):
    hits = list(Path("~/.claude/projects").expanduser().glob(f"*/{sid}.jsonl"))
    return str(hits[0]) if hits else None


def turn_diffs(sid, transcript=None, exclude=()):
    """[(repo, base_sha, base_label, patch)] for every repo this turn changed.
    Repos snapshotted at turn start: worktree vs that snapshot (catches Bash edits and commits, leaves out
    work that predates the turn). Other repos holding a file the agent edited: those files vs HEAD."""
    turn = {}
    sid = sid if valid_id(sid) else None
    if sid and (TURNS / f"{sid}.json").exists():
        try:
            turn = json.loads((TURNS / f"{sid}.json").read_text())
        except ValueError:
            turn = {}
    transcript = transcript or turn.get("transcript") or (sid and find_transcript(sid))
    _, edited, _ = turn_activity(transcript)
    excl = {str(Path(p).resolve()) for p in exclude}
    by_repo = {}
    for f in edited:
        r = toplevel(f)
        if r:
            by_repo.setdefault(r, []).append(f)
    out = []
    snaps = turn.get("repos") or {}
    for repo in sorted(set(snaps) | set(by_repo)):
        def rel(paths):
            return [os.path.relpath(str(Path(p).resolve()), str(Path(repo).resolve())) for p in paths]

        ex = rel([p for p in excl if p.startswith(str(Path(repo).resolve()) + os.sep)])
        try:
            st = snaps.get(repo)
            if st:
                base, label = st["snap"], "turn start"
                patch = git_diff(base, repo, skip_untracked=st.get("untracked", []), exclude=ex)
            else:
                base, label = git("rev-parse", "HEAD", cwd=repo).strip(), "HEAD (edited files only)"
                patch = git_diff(base, repo, paths=rel(by_repo[repo]), exclude=ex)
        except (RuntimeError, OSError):
            continue
        if patch.strip():
            out.append((repo, base, label, patch))
    return out


def parse_question(n, spec):
    text, _, opts = spec.partition("::")
    return {"id": f"q{n}", "text": text.strip(), "options": [o.strip() for o in opts.split("|") if o.strip()]}


def slug(title):
    return re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:40] or "thread"


def cmd_post(a):
    cwd = os.getcwd()
    if not a.thread and not a.title:
        die("--title is required for a new thread", EX_USAGE)
    tid = a.thread or f"{datetime.now():%Y%m%d-%H%M%S}-{slug(a.title)}"
    path = thread_path(tid, must_exist=bool(a.thread))

    attachments = []
    for p in a.attach:
        fp = Path(p).expanduser().resolve()
        attachments.append(snapshot(fp.read_bytes(), fp.name, type="file", path=str(fp)))
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if a.diff == "" and sid:
        # This turn's changes, one diff per repo it touched (see turn_diffs); markdown sent with --attach
        # is reviewed as an editable document, so it stays out of the diffs
        diffs = turn_diffs(sid, exclude=a.attach)
        if not diffs and not attachments:
            die("this turn changed nothing to diff", EX_DATAERR)
        for repo, base, label, patch in diffs:
            head = git("rev-parse", "--short", "HEAD", cwd=repo).strip()
            attachments.append(
                snapshot(patch.encode(), f"{Path(repo).name}-{head}.diff", type="diff",
                         base=label, base_sha=base, head=head, cwd=repo)
            )
    elif a.diff is not None:
        rev = a.diff or "HEAD"
        patch = git_diff(rev, cwd)
        if not patch.strip():
            die(f"empty diff against {rev}", EX_DATAERR)
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
    acked = {e.get("reply") for e in events if e.get("kind") == "ack"}
    return [e for e in events if e.get("kind") == "reply" and e.get("id") not in acked]


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
        out += ["", f"Edited by the human: {ed.get('path') or ed['attachment']}", "```diff", edit_patch(ed).rstrip(), "```"]
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
                return EXIT_TIMEOUT
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
        if e.get("kind") == "message":
            print(f"## agent · {e['at']}\n{e.get('text', '')}")
            for att in e.get("attachments", []):
                print(f"  attached: {att['name']}")
            for q in e.get("questions", []):
                print(f"  ? {q['text']} {q['options'] or ''}")
        elif e.get("kind") == "reply":
            print(f"## human · {e['at']}\n{format_reply(a.thread, e)}")
        print()


def cmd_list(_):
    for path in sorted(THREADS.glob("*.jsonl")):
        events = read_jsonl(path)
        last = next((e for e in reversed(events) if e.get("kind") in ("message", "reply")), {})
        state = "replied" if last.get("kind") == "reply" else "open"
        title = next((e["title"] for e in events if e.get("title")), "")
        print(f"{path.stem}\t{state}\t{title}")


def cards():
    latest = {}
    for e in read_jsonl(CARDS):
        if e.get("card"):
            latest[e["card"]] = e
    return latest


def cmd_card(a):
    if a.card_cmd == "add":
        if a.thread is not None:
            check_id(a.thread)
        card = {"card": f"c-{secrets.token_hex(4)}", "title": a.title, "lane": a.lane, "thread": a.thread}
    else:
        card = cards().get(a.card)
        if not card:
            die(f"no card {a.card}", EX_NOINPUT)
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
    # Only the exact trigger store.lua's deliver() sends, and only for a thread that exists: the prompt is
    # untrusted text, and a quoted path or regex must never become a file the hook appends to
    m = re.match(r"Inbox reply on thread ([A-Za-z0-9_-]+)\. Run:", prompt or "")
    reply_thread = m.group(1) if m and (THREADS / f"{m.group(1)}.jsonl").is_file() else None
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


ATTACHED = Path(os.environ.get("COCKPIT_ATTACH_DIR", "~/.cockpit/attached")).expanduser()


def attached_tmux_pane():
    """The tmux pane a `claude` launcher (scripts/cockpit-claude) has attached to this herdr agent, if any:
    the launcher writes ATTACHED/<terminal_id> containing its $TMUX_PANE for the duration of the attach."""
    ident = herdr_identity() or {}
    tid = ident.get("terminal_id")
    if not tid or not re.fullmatch(r"[A-Za-z0-9_-]+", tid):
        return None
    try:
        return (ATTACHED / tid).read_text().strip() or None
    except OSError:
        return None


def hook_stop(payload):
    """
    Route an unattended stop to the inbox:
      watched pane / already posted / second stop (stop_hook_active) -> allow
      edited files but posted nothing -> block, telling the agent how to post them for review
      answering an inbox reply -> allow, appending to that thread
      last line ends with '?' -> allow, posting it as a question
      anything else (status chatter) -> allow, posting nothing
    """
    # herdr agents only: a hand-started session has no cockpit agent to own its threads
    if not os.environ.get("HERDR_PANE_ID") or os.environ.get("COCKPIT_INBOX_HOOK") == "0" or payload.get("stop_hook_active"):
        return None
    # herdr panes are headless: watched only while a `claude` launcher has it attached in a tmux pane
    # (attach marker), and then exactly when that tmux pane is
    tmux_pane = attached_tmux_pane()
    if tmux_pane and watching(tmux_pane):
        return None
    posted, edited, reply_thread = turn_activity(payload.get("transcript_path"))
    if posted:
        return None
    thread_hint = f"--thread {reply_thread}" if reply_thread else "--title '<short title>'"
    docs = [f for f in edited if f.endswith((".md", ".mdx", ".txt"))]
    # changes made through Bash (sed, codegen, git commit) show up only in the turn diff
    code = turn_diffs(payload.get("session_id"), payload.get("transcript_path"), exclude=docs)
    if docs or code:
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
    last_line = text.splitlines()[-1].strip()
    # markdown wrapping hides the '?': **Which one?**, `x?`, (which?)
    asks = last_line.rstrip("*_`) \t").endswith("?")
    if not reply_thread and not asks:
        return None
    sid8 = (payload.get("session_id") or "")[:8]
    tid = reply_thread or f"session-{sid8 if valid_id(sid8) else 'unknown'}"
    path = THREADS / f"{tid}.jsonl"
    event = {
        "kind": "message",
        "from": "agent",
        "text": text,
        "attachments": [],
        "questions": [{"id": "q1", "text": last_line, "options": []}] if asks else [],
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
        payload = json.load(sys.stdin)
        if a.event == "prompt":
            return hook_prompt(payload)
        decision = hook_stop(payload)
    except Exception as e:  # a hook bug must never wedge the agent
        print(f"cockpit-inbox hook: {e}", file=sys.stderr)
        return
    if decision:
        print(json.dumps(decision))


def thread_session(events):
    """The Claude session id a thread already records (owner event or first message), else None."""
    owner = None
    for e in events:
        if e.get("kind") == "message" and owner is None:
            owner = e.get("session") or {}
        elif e.get("kind") == "owner":
            owner = {**(owner or {}), **(e.get("session") or {})}
    owner = owner or {}
    return owner.get("session_id") or (owner.get("herdr") or {}).get("session_id")


def first_mention(path, needle):
    """Timestamp of the first transcript line mentioning needle ('' if it has none)."""
    try:
        with open(path, errors="replace") as f:
            for line in f:
                if needle in line:
                    try:
                        return json.loads(line).get("timestamp") or ""
                    except ValueError:
                        return ""
    except OSError:
        pass
    return None


def posting_session(tid):
    """The session that posted thread tid: hook threads are named session-<first 8 of its id>; otherwise the
    transcript that mentions the id first (later sessions may mention it too, e.g. when reading it)."""
    projects = CLAUDE_DIR / "projects"
    m = re.fullmatch(r"session-([0-9a-f]{8})", tid)
    if m:
        hit = sorted(projects.glob(f"*/{m.group(1)}*.jsonl"))
        return hit[0].stem if hit else None
    try:
        out = subprocess.run(["rg", "-l", "-F", "--max-depth", "2", "-g", "*.jsonl", "-e", tid, str(projects)],
                             capture_output=True, text=True).stdout.split()
    except OSError:
        out = [str(f) for f in projects.glob("*/*.jsonl") if tid in f.read_text(errors="replace")]
    best = None
    for f in out:
        ts = first_mention(f, tid)
        if ts is not None and (best is None or ts < best[0]):
            best = (ts, Path(f).stem)
    return best and best[1]


def cmd_backfill_sessions(a):
    for path in sorted(THREADS.glob("*.jsonl")):
        events = read_jsonl(path)
        if not events or thread_session(events):
            continue
        sid = posting_session(path.stem)
        print(f"{path.stem} -> {sid or 'unmatched'}")
        if sid and not a.dry_run:
            append(path, {"kind": "owner", "session": {"session_id": sid}})


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        die(message, EX_USAGE)


def main():
    p = Parser(prog="cockpit_inbox.py", description="Agent side of the cockpit inbox")
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
    bf = sub.add_parser("backfill-sessions", help="tag legacy threads with the Claude session that posted them")
    bf.add_argument("--dry-run", action="store_true")
    bf.set_defaults(fn=cmd_backfill_sessions)

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
    h.add_argument("event", choices=["stop", "prompt"])
    h.set_defaults(fn=cmd_hook)

    s = sub.add_parser("snapshot", help="(internal) record repo states at turn start")
    s.add_argument("session")
    s.add_argument("cwd")
    s.add_argument("ts", type=float)
    s.add_argument("transcript", nargs="?", default="")
    s.set_defaults(fn=cmd_snapshot)

    a = p.parse_args()
    try:
        a.fn(a)
    except Exception:
        traceback.print_exc()
        sys.exit(EX_SOFTWARE)


if __name__ == "__main__":
    main()
