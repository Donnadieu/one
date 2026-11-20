"""Checks that copying their Chrome again never loses the hidden browser's own sign-ins.

Run: python3 tools/chrome-copy-check.py   (prints "chrome copy ok" when every case passes)

Nov 17-18 2026: X (@OverviewEffect6) was signed in only in the hidden browser (Omar signed in through the
window; his own Chrome isn't signed in to X). Every copy of his Chrome replaced the hidden browser's whole
cookie file, so X went signed out each time, and a copy that failed (the Mac's keychain box with nobody
there) left the hidden browser signed in to nothing. Here: a made-up Chrome and a made-up hidden browser,
and a stand-in for the engine's snapshot code (it overwrites the cookie file, like the real one).
No browser, no Keychain, no network. Never reads a real cookie.
"""

import importlib.util
import os
import shutil
import sqlite3
import sys
import tempfile
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent
tmp = Path(tempfile.mkdtemp(prefix="one-chrome-copy-"))
fails = 0


def check(name, ok):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name)
    if not ok:
        fails += 1


# Chrome's cookie table (the columns and unique key Chrome 158 uses).
SCHEMA = """
CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
CREATE TABLE cookies(creation_utc INTEGER NOT NULL,host_key TEXT NOT NULL,top_frame_site_key TEXT NOT NULL,
 name TEXT NOT NULL,value TEXT NOT NULL,encrypted_value BLOB NOT NULL,path TEXT NOT NULL,expires_utc INTEGER NOT NULL,
 is_secure INTEGER NOT NULL,is_httponly INTEGER NOT NULL,last_access_utc INTEGER NOT NULL,has_expires INTEGER NOT NULL,
 is_persistent INTEGER NOT NULL,priority INTEGER NOT NULL,samesite INTEGER NOT NULL,source_scheme INTEGER NOT NULL,
 source_port INTEGER NOT NULL,last_update_utc INTEGER NOT NULL,source_type INTEGER NOT NULL,
 has_cross_site_ancestor INTEGER NOT NULL);
CREATE UNIQUE INDEX cookies_unique_index ON cookies(host_key, top_frame_site_key, has_cross_site_ancestor, name, path,
 source_scheme, source_port);
"""
FAR = 13_500_000_000_000_000  # Chrome time (µs since 1601), years ahead


def make_db(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    c = sqlite3.connect(str(path))
    c.executescript(SCHEMA)
    c.execute("insert into meta values ('version', '24')")
    for host, name, val, updated in rows:
        c.execute(
            "insert into cookies values (?,?,'',?,'',?,'/',?,1,1,?,1,1,1,0,2,443,?,0,0)",
            (updated, host, name, val.encode(), FAR, updated, updated),
        )
    c.commit()
    c.close()


def rows(path):
    c = sqlite3.connect("file:" + str(path) + "?mode=ro", uri=True)
    r = {(h, n): v for h, n, v in c.execute("select host_key, name, encrypted_value from cookies")}
    c.close()
    return r


# Their Chrome: Google signed in (newer than the hidden browser's), X only as a guest, a site only Chrome has.
src = tmp / "Chrome"
(src / "Default").mkdir(parents=True)
(src / "Local State").write_text('{"profile": {"last_used": "Default", "info_cache": {"Default": {"name": "Omar"}}}}')
CHROME = [
    (".google.com", "SID", "chrome-sid", 300),
    (".x.com", "guest_id", "chrome-guest", 100),
    (".x.com", "ct0", "chrome-guest-ct0", 50),
    (".amazon.com", "at-main", "chrome-amazon", 300),
]
make_db(src / "Default/Network/Cookies", CHROME)

# The hidden browser's copy: X signed in through the window (only here), an older Google sign-in.
dst = tmp / "browser/my-chrome"
HIDDEN = [
    (".x.com", "auth_token", "hidden-auth", 200),
    (".x.com", "ct0", "hidden-ct0", 200),
    (".x.com", "twid", "hidden-twid", 200),
    (".google.com", "SID", "hidden-sid", 10),
]


def reset_copy():
    if dst.exists():
        shutil.rmtree(dst)
    make_db(dst / "Default/Network/Cookies", HIDDEN)
    (dst / ".hermes-snapshot-complete").write_text("Default")


# A stand-in for the engine's snapshot code: overwrites the copy's cookie file with Chrome's, like the
# real one (SQLite backup), then fails (MODE "fail", the cookie file already replaced) or succeeds.
MODE = {"v": "ok"}
bc = types.ModuleType("hermes_cli.browser_connect")
bc.real_profile_copy_dir = lambda _b: str(dst)
bc._real_profile_pin = lambda: None
bc.real_profile_data_dir = lambda _b: str(src)
bc._resolve_source_profile = lambda _src: ("Default", None)


def snapshot(_browser, src=None):
    s = sqlite3.connect(str(Path(src) / "Default/Network/Cookies"))
    d = sqlite3.connect(bc.real_profile_copy_dir("chrome") + "/Default/Network/Cookies")
    s.backup(d)
    s.close()
    d.close()
    if MODE["v"] == "fail":
        return None, "could not read the 'chrome' profile's login data (Cookies: disk I/O error)"
    return bc.real_profile_copy_dir("chrome"), None


bc.snapshot_real_profile = snapshot
pkg = types.ModuleType("hermes_cli")
pkg.browser_connect = bc
sys.modules["hermes_cli"] = pkg
sys.modules["hermes_cli.browser_connect"] = bc

spec = importlib.util.spec_from_file_location("one_my_chrome", HERE / "overlay/tools/one_my_chrome.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def run(*argv):
    import contextlib
    import io

    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        code = m.main(list(argv))
    return code, buf.getvalue()


cookies = dst / "Default/Network/Cookies"

print("A copy that fails leaves the hidden browser's cookies untouched")
reset_copy()
before = rows(cookies)
MODE["v"] = "fail"
code, out = run("chrome", str(dst), "--src", str(src))
check("the failed copy says so (exit 1)", code == 1 and '"ok": false' in out)
check("every cookie the hidden browser had is back, unchanged", rows(cookies) == before)
check("X is still signed in there (auth_token, ct0, twid)", all((".x.com", n) in rows(cookies) for n in ("auth_token", "ct0", "twid")))

print("A copy that works keeps the sign-ins made only in the hidden browser")
reset_copy()
MODE["v"] = "ok"
code, out = run("chrome", str(dst), "--src", str(src))
after = rows(cookies)
check("the copy worked (exit 0)", code == 0 and '"ok": true' in out)
check("X stays signed in (it lives only in the hidden browser)", after.get((".x.com", "auth_token")) == b"hidden-auth")
check("the same cookie in both: the newer one wins (the hidden browser's X ct0)", after.get((".x.com", "ct0")) == b"hidden-ct0")
check("the same cookie in both: the newer one wins (Chrome's Google sign-in)", after.get((".google.com", "SID")) == b"chrome-sid")
check("sites only Chrome has come in", after.get((".amazon.com", "at-main")) == b"chrome-amazon")
check("the report counts the kept sign-ins", '"kept": 3' in out)

print("Putting the cookies from before the copy back (the Mac's keychain said no)")
code, out = run("restore", str(dst))
check("restore works (exit 0)", code == 0)
check("the cookies are exactly the ones from before the copy", rows(cookies) == {(h, n): v.encode() for h, n, v, _ in HIDDEN})

print("A first copy (no hidden browser yet) still works")
shutil.rmtree(dst)
dst.mkdir(parents=True)
(dst / "Default/Network").mkdir(parents=True)
code, out = run("chrome", str(dst), "--src", str(src))
check("first copy: Chrome's cookies, nothing else", code == 0 and rows(cookies) == {(h, n): v.encode() for h, n, v, _ in CHROME})
code, out = run("restore", str(dst))
check("restore with nothing kept changes nothing and says so", code == 1 and rows(cookies) == {(h, n): v.encode() for h, n, v, _ in CHROME})


# Nov 20 2026: a helper ran "use my Chrome" twice (9:07 and 9:11 AM) and X was signed out of the hidden
# browser both times, though the merge above was in. Their Chrome opens x.com as a guest every day, so its
# x.com cookies (ct0, guest_id...) were NEWER than the hidden browser's sign-in: per cookie "newer wins" put
# Chrome's guest ct0 next to the hidden browser's auth_token, and X ended the session. And their Chrome's
# rows are sealed with another key (v10) than the hidden browser's own (v11): the hidden browser can't read
# them and drops them on start, so a site whose rows came from Chrome loses them all (x.com, google.com,
# youtube.com: 55 rows each time). A site is kept whole, from one side, never mixed.
def scenario(chrome_rows, hidden_rows):
    make_db(src / "Default/Network/Cookies", chrome_rows)
    if dst.exists():
        shutil.rmtree(dst)
    make_db(dst / "Default/Network/Cookies", hidden_rows)
    (dst / ".hermes-snapshot-complete").write_text("Default")
    MODE["v"] = "ok"
    code, out = run("chrome", str(dst), "--src", str(src))
    return code, out, rows(cookies)


print("Their Chrome visited X as a guest AFTER the hidden browser signed in")
code, out, after = scenario(
    [(".x.com", "guest_id", "chrome-guest", 900), (".x.com", "ct0", "chrome-guest-ct0", 900), (".x.com", "gt", "chrome-gt", 900)],
    [(".x.com", "auth_token", "hidden-auth", 200), (".x.com", "ct0", "hidden-ct0", 200), (".x.com", "twid", "hidden-twid", 200),
     (".x.com", "guest_id", "hidden-guest", 100)],
)
check("the copy worked (exit 0)", code == 0)
check("X keeps the hidden browser's whole sign-in (auth_token, ct0, twid)",
      [after.get((".x.com", n)) for n in ("auth_token", "ct0", "twid")] == [b"hidden-auth", b"hidden-ct0", b"hidden-twid"])
check("no guest cookie from their Chrome mixed into the signed-in X", after.get((".x.com", "gt")) is None
      and after.get((".x.com", "guest_id")) == b"hidden-guest")

print("Any site signed in only in the hidden browser, with newer guest cookies in their Chrome")
code, out, after = scenario(
    [(".shop.example", "visitor", "chrome-visitor", 900), (".shop.example", "csrf", "chrome-csrf", 900)],
    [(".shop.example", "sessionid", "hidden-session", 200), (".shop.example", "csrf", "hidden-csrf", 200)],
)
check("its sign-in stays, with its own csrf", after.get((".shop.example", "sessionid")) == b"hidden-session"
      and after.get((".shop.example", "csrf")) == b"hidden-csrf" and (".shop.example", "visitor") not in after)

print("Both signed in to Google, their Chrome newer: Chrome's whole Google, not a mix")
code, out, after = scenario(
    [(".google.com", "SID", "chrome-sid", 300), (".google.com", "HSID", "chrome-hsid", 300)],
    [(".google.com", "SID", "hidden-sid", 10), (".google.com", "HSID", "hidden-hsid", 10), (".google.com", "__Secure-3PSIDTS", "hidden-ts", 10)],
)
check("Chrome's newer Google sign-in wins", after.get((".google.com", "SID")) == b"chrome-sid" and after.get((".google.com", "HSID")) == b"chrome-hsid")
check("none of the hidden browser's older Google cookies mixed in", (".google.com", "__Secure-3PSIDTS") not in after)

print("Their Chrome's cookies are sealed with a key the hidden browser doesn't use (v10 vs v11)")
code, out, after = scenario(
    [(".x.com", "auth_token", "v10chrome-auth", 900), (".x.com", "ct0", "v10chrome-ct0", 900), (".amazon.com", "at-main", "v10chrome-amazon", 900)],
    [(".x.com", "auth_token", "v11hidden-auth", 200), (".x.com", "ct0", "v11hidden-ct0", 200), (".x.com", "twid", "v11hidden-twid", 200)],
)
check("X keeps the rows the hidden browser can read", [after.get((".x.com", n)) for n in ("auth_token", "ct0", "twid")]
      == [b"v11hidden-auth", b"v11hidden-ct0", b"v11hidden-twid"])
check("a site only Chrome has still comes in", after.get((".amazon.com", "at-main")) == b"v10chrome-amazon")

shutil.rmtree(tmp, ignore_errors=True)
print("chrome copy ok" if not fails else f"chrome copy FAILED: {fails}")
sys.exit(1 if fails else 0)
