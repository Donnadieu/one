"""A real hidden Chrome keeps its own X and Google sign-ins through a copy of their Chrome.

Run: python3 tools/chrome-copy-live-check.py [--engine <engine dir>] [--code <one_my_chrome.py>]
Prints "chrome copy live ok" when every case passes; exit 0 ok, 1 a case failed, 3 no Chrome on this Mac.

Nov 18-20 2026 X (@OverviewEffect6) and Google were signed out of One's hidden browser four times, each
time right after "use my Chrome". tools/chrome-copy-check.py proves the merge on made-up files, but the
loss happened in Chrome itself: their Chrome's cookie rows are sealed with another key (v10) than the
hidden browser's own (v11), and when the hidden browser starts it drops rows it can't read, taking the
whole site with them. Only a real Chrome shows that. So here, per case:
  1. a real headless Chrome on a scratch profile (DevTools over a pipe: no port, never 9224) signs in
     to x.com and google.com (made-up cookie values set over DevTools) and quits cleanly;
  2. a made-up "their Chrome" holds v10-sealed rows: newer guest x.com rows, a newer Google sign-in;
  3. the real copy path runs (one_my_chrome.main; with --engine, the engine's own snapshot code);
  4. the same Chrome starts again on the copy and we read its cookies back over DevTools.
X's auth_token, ct0 and twid and Google's SID and __Secure-1PSID must all still be there, unchanged.
Made-up values only; never touches their Chrome, One's own hidden browsers or the Keychain.
"""

import importlib.util
import json
import os
import random
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
CHROME_APP = next(
    (p for p in ("/Applications/Google Chrome.app", os.path.expanduser("~/Applications/Google Chrome.app")) if os.path.isdir(p)), None
)
ARGS = sys.argv[1:]


def arg(name):
    return ARGS[ARGS.index(name) + 1] if name in ARGS and ARGS.index(name) + 1 < len(ARGS) else None


ENGINE, CODE = arg("--engine"), arg("--code") or str(HERE / "overlay/tools/one_my_chrome.py")
fails = 0


def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    if not ok:
        fails += 1


class Browser:
    """A real headless Chrome on `profile`, DevTools over --remote-debugging-pipe (fd 3 in, fd 4 out)."""

    def __init__(self, profile):
        exe = CHROME_APP + "/Contents/MacOS/Google Chrome"
        import fcntl

        def high(fd):  # above 4, so the dup2 below never lands on itself (that would keep close-on-exec set)
            h = fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 10)
            os.close(fd)
            return h

        a_r, a_w = (high(x) for x in os.pipe())  # we write commands -> Chrome reads fd 3
        b_r, b_w = (high(x) for x in os.pipe())  # Chrome writes fd 4 -> we read

        def fds():
            os.dup2(a_r, 3)
            os.dup2(b_w, 4)

        self.p = subprocess.Popen(
            # --no-sandbox: Chrome's own sandbox can't start inside One's folder lock (made-up pages only here).
            [exe, "--headless=new", "--no-sandbox", "--remote-debugging-pipe", f"--user-data-dir={profile}", "--no-first-run",
             "--no-default-browser-check", "--disable-sync", "about:blank"],
            close_fds=False, preexec_fn=fds,  # pass_fds would close 3 and 4 after the dup2
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        os.close(a_r)
        os.close(b_w)
        self.w, self.r, self.buf, self.n = os.fdopen(a_w, "wb", buffering=0), os.fdopen(b_r, "rb", buffering=0), b"", 0

    def call(self, method, **params):
        self.n += 1
        self.w.write(json.dumps({"id": self.n, "method": method, "params": params}).encode() + b"\0")
        deadline = time.time() + 30
        while time.time() < deadline:
            while b"\0" in self.buf:
                msg, self.buf = self.buf.split(b"\0", 1)
                j = json.loads(msg)
                if j.get("id") == self.n:
                    if "error" in j:
                        raise RuntimeError(f"{method}: {j['error']}")
                    return j.get("result", {})
            chunk = self.r.read(65536)
            if not chunk:
                raise RuntimeError(f"{method}: Chrome closed the pipe")
            self.buf += chunk
        raise RuntimeError(f"{method}: no answer")

    def cookies(self):
        return {(c["domain"], c["name"]): c["value"] for c in self.call("Storage.getCookies")["cookies"]}

    def close(self):
        try:
            self.call("Browser.close")  # a clean quit writes every cookie to disk
        except RuntimeError:
            pass
        try:
            self.p.wait(20)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait()
        time.sleep(0.5)


# The hidden browser's own sign-ins (made-up values), as Omar's window sign-in leaves them.
SIGN_IN = [
    (".x.com", "auth_token", "hidden-auth"), (".x.com", "ct0", "hidden-ct0"), (".x.com", "twid", "u%3D1"),
    (".x.com", "guest_id", "v1%3Ahidden"), (".google.com", "SID", "hidden-sid"), (".google.com", "__Secure-1PSID", "hidden-1psid"),
    (".google.com", "HSID", "hidden-hsid"), (".youtube.com", "LOGIN_INFO", "hidden-login"), (".linkedin.com", "li_at", "hidden-li"),
]
MUST = [(".x.com", "auth_token"), (".x.com", "ct0"), (".x.com", "twid"), (".google.com", "SID"), (".google.com", "__Secure-1PSID")]


def hidden_profile(root):
    prof = root / "browser/my-chrome"
    prof.mkdir(parents=True)
    b = Browser(prof)
    exp = time.time() + 3600 * 24 * 300
    b.call("Storage.setCookies", cookies=[
        {"name": n, "value": v, "domain": d, "path": "/", "secure": True, "httpOnly": n != "ct0", "expires": exp, "sameSite": "Lax"}
        for d, n, v in SIGN_IN])
    got = b.cookies()
    b.close()
    return prof, all(got.get((d, n)) == v for d, n, v in SIGN_IN)


def cookie_db(prof):
    for rel in ("Default/Network/Cookies", "Default/Cookies"):
        if (prof / rel).is_file():
            return prof / rel
    return None


def seals(db):
    c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    s = {bytes(r[0]) for r in c.execute("select substr(encrypted_value, 1, 3) from cookies")}
    c.close()
    return s


def their_chrome(root, hidden_db, rows, extra_column=False):
    """A made-up Chrome user data dir: the real cookie schema (from the hidden browser's own file), our rows."""
    src = root / "Chrome"
    (src / "Default").mkdir(parents=True)
    (src / "Local State").write_text('{"profile": {"last_used": "Default", "info_cache": {"Default": {"name": "Omar"}}}}')
    db = src / "Default" / hidden_db.name
    if hidden_db.parent.name == "Network":
        db = src / "Default/Network/Cookies"
        db.parent.mkdir(parents=True)
    shutil.copyfile(hidden_db, db)
    c = sqlite3.connect(str(db))
    cols = [r[1] for r in c.execute("pragma table_info(cookies)")]
    tmpl = dict(zip(cols, c.execute("select * from cookies limit 1").fetchone()))
    c.execute("delete from cookies")
    now = int((time.time() + 11644473600) * 1_000_000) + 60_000_000  # newer than the hidden browser's rows
    for host, name in rows:
        r = dict(tmpl, host_key=host, name=name, value="", encrypted_value=b"v10" + random.randbytes(48),
                 creation_utc=now, last_update_utc=now, last_access_utc=now, expires_utc=now + 3600 * 24 * 300 * 1_000_000)
        c.execute(f"insert into cookies ({','.join(cols)}) values ({','.join('?' * len(cols))})", [r[k] for k in cols])
    if extra_column:  # their Chrome is a version ahead: its cookie table has a column the hidden browser's lacks
        c.execute("alter table cookies add column one_test_newer integer not null default 0")
    c.commit()
    c.close()
    return src


def load_code():
    if ENGINE:
        sys.path.insert(0, ENGINE)
        os.environ.setdefault("HERMES_HOME", tempfile.mkdtemp(prefix="one-live-home-"))
    else:  # no engine here: a stand-in for its snapshot, which copies the cookie DB over the copy's (SQLite backup)
        bc = types.ModuleType("hermes_cli.browser_connect")
        bc._real_profile_pin = lambda: None
        bc.real_profile_data_dir = lambda _b: None
        bc._resolve_source_profile = lambda _src: ("Default", None)

        def snapshot(_browser, src=None):
            dst = bc.real_profile_copy_dir("chrome")
            for rel in ("Default/Network/Cookies", "Default/Cookies"):
                if os.path.isfile(os.path.join(src, rel)):
                    os.makedirs(os.path.dirname(os.path.join(dst, rel)), exist_ok=True)
                    s, d = sqlite3.connect(os.path.join(src, rel)), sqlite3.connect(os.path.join(dst, rel))
                    s.backup(d)
                    s.close()
                    d.close()
            return dst, None

        bc.snapshot_real_profile = snapshot
        pkg = types.ModuleType("hermes_cli")
        pkg.browser_connect = bc
        sys.modules["hermes_cli"], sys.modules["hermes_cli.browser_connect"] = pkg, bc
    spec = importlib.util.spec_from_file_location("one_my_chrome_under_test", CODE)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def copy(m, src, prof):
    import contextlib
    import io

    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = m.main(["chrome", str(prof), "--src", str(src)])
    return code, buf.getvalue().strip().splitlines()[-1:]


def case(title, chrome_rows, stray=False, extra_column=False):
    print(title)
    root = Path(tempfile.mkdtemp(prefix="one-live-copy-"))
    try:
        prof, ok = hidden_profile(root)
        check("a real hidden Chrome signed in to X and Google (made-up values)", ok)
        db = cookie_db(prof)
        if stray:  # a row the hidden browser can't read, left from a window on its profile (sealed like their Chrome's)
            c = sqlite3.connect(str(db))
            cols = [r[1] for r in c.execute("pragma table_info(cookies)")]
            r = dict(zip(cols, c.execute("select * from cookies limit 1").fetchone()), host_key=".stray.example", name="pref",
                     encrypted_value=b"v10" + random.randbytes(48))
            c.execute(f"insert into cookies ({','.join(cols)}) values ({','.join('?' * len(cols))})", [r[k] for k in cols])
            c.commit()
            c.close()
        print(f"    (hidden browser seals its rows {sorted(s.decode() for s in seals(db))})")
        src = their_chrome(root, db, chrome_rows, extra_column)
        code, out = copy(m, src, prof)
        check("the copy ran (exit 0)", code == 0)
        if code:
            print("    " + " ".join(out))
        b = Browser(prof)
        after = b.cookies()
        b.close()
        want = {(d, n): v for d, n, v in SIGN_IN}
        lost = [f"{d} {n}" for d, n in MUST if after.get((d, n)) != want[(d, n)]]
        check("after the restart X keeps auth_token, ct0, twid and Google keeps SID, __Secure-1PSID", not lost)
        if lost:
            print("    lost: " + ", ".join(lost))
        others = [f"{d} {n}" for d, n, v in SIGN_IN if (d, n) not in MUST and after.get((d, n)) != v]
        check("and every other sign-in it had is still there (YouTube, LinkedIn, X guest_id, Google HSID)", not others)
        if others:
            print("    lost: " + ", ".join(others))
    finally:
        shutil.rmtree(root, ignore_errors=True)


if not CHROME_APP:
    print("chrome copy live: Google Chrome isn't on this Mac; nothing checked")
    sys.exit(3)
m = load_code()
print(f"code under test: {CODE}" + (f" (engine {ENGINE})" if ENGINE else " (stand-in snapshot)"))
GUEST_X = [(".x.com", "guest_id"), (".x.com", "ct0"), (".x.com", "gt"), (".x.com", "personalization_id")]
GOOGLE = [(".google.com", "SID"), (".google.com", "__Secure-1PSID"), (".google.com", "HSID"), (".youtube.com", "LOGIN_INFO")]
case("Their Chrome: newer guest X rows and a newer Google sign-in, all sealed v10 (Nov 20 2026)", GUEST_X + GOOGLE + [(".amazon.com", "at-main")])
case("Same, and the hidden browser's file already holds one row it can't read", GUEST_X + GOOGLE, stray=True)
case("Same, and their Chrome's cookie table has a column the hidden browser's lacks", GUEST_X + GOOGLE, extra_column=True)
print("chrome copy live ok" if not fails else f"chrome copy live FAILED: {fails}")
sys.exit(1 if fails else 0)
