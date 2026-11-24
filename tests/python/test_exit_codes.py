"""Exit-code contract (review 0.2): verdicts 0/10/11/12, errors >= 64. An agent running `post --wait` must never
mistake a failure for a verdict."""

import pytest

APPROVED, CHANGES, REJECT, TIMEOUT = 0, 10, 11, 12
USAGE, DATAERR, NOINPUT, SOFTWARE = 64, 65, 66, 70
VERDICTS = {CHANGES, REJECT, TIMEOUT}


@pytest.fixture
def thread(cli, ck):
    def make(verdict=None):
        tid = cli("post", "--title", "t", "--text", "hi").stdout.strip()
        if verdict is not False:
            ck.append(ck.THREADS / f"{tid}.jsonl", {"kind": "reply", "from": "human", "verdict": verdict, "text": "x"})
        return tid

    return make


@pytest.mark.parametrize(
    "args,code",
    [
        (["wait", "no-such-thread"], NOINPUT),
        (["read", "no-such-thread", "--new"], NOINPUT),
        (["post", "--thread", "no-such-thread", "--text", "x", "--wait"], NOINPUT),
        (["post", "--text", "x"], USAGE),  # new thread without --title
        (["wait"], USAGE),  # argparse: missing positional
        (["post", "--bogus"], USAGE),
        (["post", "--title", "t", "--attach", "/nonexistent/file", "--wait"], SOFTWARE),  # unhandled error
    ],
)
def test_errors_never_look_like_verdicts(cli, args, code):
    res = cli(*args)
    assert res.returncode == code, (res.returncode, res.stderr)
    assert res.returncode not in VERDICTS
    assert res.stderr.strip()


@pytest.mark.parametrize(
    "verdict,code",
    [("approve", APPROVED), ("approve_with_notes", APPROVED), (None, APPROVED), ("changes_requested", CHANGES),
     ("reject", REJECT)],
)
def test_wait_verdict_codes(cli, thread, verdict, code):
    tid = thread(verdict)
    res = cli("wait", tid)
    assert res.returncode == code, res.stderr
    assert f"Inbox reply on thread {tid}" in res.stdout


def test_read_new_verdict_code(cli, thread):
    assert cli("read", thread("reject"), "--new").returncode == REJECT


def test_wait_timeout_code(cli, thread):
    res = cli("wait", thread(False), "--timeout", "1")
    assert res.returncode == TIMEOUT
    assert "timeout" in res.stdout


def test_empty_diff_is_dataerr(cli, env):
    import subprocess

    subprocess.run(["git", "init", "-q", str(env)], check=True)
    subprocess.run(["git", "-C", str(env), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty",
                    "-m", "init"], check=True)
    res = cli("post", "--title", "t", "--diff", "HEAD")
    assert res.returncode == DATAERR, res.stderr
