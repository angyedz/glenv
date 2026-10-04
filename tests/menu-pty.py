#!/usr/bin/env python3
"""Interactive-menu test for install.sh, driven through a pty.

Asserts the full non-install path: menu renders, arrow keys and checkboxes
work, presets switch, the plan screen appears before any sudo, and declining
leaves the system untouched (exit 0, 'cancelled').

    python3 tests/menu-pty.py

Environment:
    GLENV_INSTALLER  path to install.sh (default: <repo>/install.sh)
    GLENV_PREFIX     prefix for the test run (default: a fresh mkdtemp)
"""
import os
import pty
import re
import select
import shutil
import sys
import tempfile
import time

TREE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALLER = os.environ.get("GLENV_INSTALLER", os.path.join(TREE, "install.sh"))
PREFIX = os.environ.get("GLENV_PREFIX") or tempfile.mkdtemp(prefix="glenv-pty-")

FAILS = 0


def ok(msg):
    print(f"[pty] ok:   {msg}")


def no(msg):
    global FAILS
    FAILS += 1
    print(f"[pty] FAIL: {msg}")


def check(buf, marker, desc):
    plain = re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", buf)
    if marker.encode() in plain:
        ok(desc)
    else:
        no(f"{desc} (marker not found: {marker!r})")


def main():
    created_prefix = os.environ.get("GLENV_PREFIX") is None
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["GLENV_PREFIX"] = PREFIX
        os.environ.setdefault("TERM", "xterm-256color")
        os.environ.setdefault("LANG", "C.UTF-8")
        os.execvp("sh", ["sh", INSTALLER])

    buf = b""
    history = []

    def pump(seconds):
        nonlocal buf
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return False
                if not data:
                    return False
                buf += data
        return True

    def wait_for(text, timeout=90):
        end = time.time() + timeout
        while time.time() < end:
            if text.encode() in buf:
                return True
            if not pump(0.3):
                return False
        return False

    def send(keys, wait=0.6):
        os.write(fd, keys)
        pump(wait)
        history.append(buf)

    def shot():
        """plain-text view of everything printed so far"""
        return re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", buf).replace(b"\r", b"\n")

    try:
        if not wait_for("Select components"):
            no("menu never appeared (preflight stuck?)")
            return
        ok("menu appeared")

        # cursor on row 3, space toggles it off
        send(b"\x1b[B")
        send(b"\x1b[B")
        send(b" ")
        frame = re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", history[-1]).replace(b"\r", b"\n")
        if b"> [ ] x11" in frame:
            ok("arrow keys + space toggle checkbox (x11 off, cursor row 3)")
        else:
            no("arrow keys + space toggle checkbox (expected '> [ ] x11')")

        # preset 1 = minimal: only core checked
        send(b"1")
        frame = re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", history[-1]).replace(b"\r", b"\n")
        if b"1> minimal" in frame and b"[x] core" in frame and b"[ ] gl" in frame:
            ok("preset 1 (minimal) selects only core")
        else:
            no("preset 1 (minimal) selects only core")

        # preset 2 = standard
        send(b"2")
        frame = re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", history[-1]).replace(b"\r", b"\n")
        if b"2> standard" in frame and b"[x] sound" in frame and b"[ ] gui" in frame:
            ok("preset 2 (standard) = core gl x11 sound net fonts")
        else:
            no("preset 2 (standard) selected groups")

        # enter -> plan screen (must appear before any privilege stage)
        send(b"\r", wait=3.0)
        check(buf, "[3/9] Plan", "plan screen reached")
        check(buf, "System changes (need root):", "plan lists system changes")
        check(buf, "proceed with installation? [y/N]", "confirmation prompt shown")

        # decline -> clean cancel, nothing touched
        send(b"n", wait=2.0)
        pump(2.0)
        check(buf, "cancelled — nothing was changed", "decline cancels cleanly")

        _, status = os.waitpid(pid, 0)
        code = status >> 8
        if code == 0:
            ok("installer exit code 0")
        else:
            no(f"installer exit code {code}")
        if "[4/9] Privileges" in shot().decode("utf-8", "replace"):
            no("sudo stage was reached before confirmation (must not happen)")
        else:
            ok("no sudo stage before confirmation")
    finally:
        try:
            os.close(fd)
        except OSError:
            pass
        if created_prefix:
            shutil.rmtree(PREFIX, ignore_errors=True)

    print()
    if FAILS == 0:
        print("[pty] ALL PASSED")
        return 0
    print(f"[pty] {FAILS} FAILURE(S)")
    return 1


if __name__ == "__main__":
    sys.exit(main())
