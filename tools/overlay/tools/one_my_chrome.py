"""One: copy the person's own Chrome sign-ins into the hidden browser One keeps for helpers.

Run by One itself, OUTSIDE the folder lock (the lock closes Chrome's own folder):
    hermes --run-module tools.one_my_chrome <browser> <copy dir> [--src <user data dir>] [--profile <dir name>]
It reuses Hermes's real-profile snapshot (hermes_cli.browser_connect.snapshot_real_profile):
Local State rewritten for one Default profile, the active profile minus caches and extensions,
and the cookie/login databases copied with SQLite's online backup, so it works while their Chrome
is open. Only the destination differs: One's own folder instead of $HERMES_HOME/browser-profile
(Hermes deletes that one whenever browser.use_real_profile is off). Their Chrome is never touched,
never quit, never written to. Prints one JSON line: {"ok", "copy", "source", "profile",
"profile_name", "profiles", "cookies", "signs", "error"}.

`cookies` and `signs` describe the COPY (rows in its cookie database, still encrypted), so One can
later tell "the Mac didn't let Chrome unlock them" apart from "you weren't signed in": `signs`
lists the well-known sites whose sign-in cookie is in the copy (site, domain, cookie name only).
Never a cookie value.
"""

import json
import os
import re
import sqlite3
import sys
import time

# Well-known sites and the cookie that means "signed in". Names only; values are never read.
SIGNS = (
    ("Google", ".google.com", "SID"),
    ("GitHub", "github.com", "user_session"),
    ("Amazon", ".amazon.com", "at-main"),
    ("Facebook", ".facebook.com", "c_user"),
    ("Instagram", ".instagram.com", "sessionid"),
    ("X", ".x.com", "auth_token"),
    ("LinkedIn", ".linkedin.com", "li_at"),
    ("Claude", ".claude.ai", "sessionKey"),
    ("ChatGPT", "chatgpt.com", "__Secure-next-auth.session-token"),
    ("Microsoft", "login.microsoftonline.com", "ESTSAUTHPERSISTENT"),
    ("Outlook.com", "login.live.com", "__Host-MSAAUTHP"),
    ("Netflix", ".netflix.com", "NetflixId"),
    ("Slack", ".slack.com", "d"),
    ("Notion", ".notion.so", "token_v2"),
    ("Etsy", ".etsy.com", "session-key-www"),
)


def copy_report(dst: str) -> tuple[int, list[dict]]:
    """Rows in the copy's cookie DB and the known sign-ins present (unexpired). No values."""
    for rel in ("Default/Network/Cookies", "Default/Cookies"):
        f = os.path.join(dst, rel)
        if not os.path.isfile(f):
            continue
        try:
            c = sqlite3.connect("file:" + f + "?mode=ro", uri=True, timeout=1)
            n = c.execute("select count(*) from cookies").fetchone()[0]
            # Chrome time = microseconds since 1601; 0 = a session cookie.
            now = int((time.time() + 11644473600) * 1_000_000)
            signs = []
            for site, domain, name in SIGNS:
                hit = c.execute(
                    "select 1 from cookies where host_key in (?, ?) and name=? and (expires_utc=0 or expires_utc>?) limit 1",
                    (domain, "." + domain.lstrip("."), name, now),
                ).fetchone()
                if hit:
                    signs.append({"site": site, "domain": domain, "name": name})
            c.close()
            return n, signs
        except sqlite3.Error:
            return -1, []
    return 0, []


# The hidden browser's own sign-ins (a site signed in through One's window, never in their Chrome) live
# only in the copy's cookie file, and the snapshot replaces that file whole. Nov 17-18 2026 it signed X
# out of the hidden browser on every copy. So: keep the copy's cookie file before each copy, put it back
# if the copy fails, and after a copy that works, add back every cookie their Chrome doesn't have (the
# newer one wins where both do). `restore` puts the kept file back (One runs it when the Mac's keychain
# box got no answer). Cookie values stay encrypted and are never read.
COOKIE_FILES = ("Default/Network/Cookies", "Default/Cookies")


def kept_dir(dst: str) -> str:
    return dst.rstrip("/") + "-before"


def _backup(a: str, b: str) -> None:
    os.makedirs(os.path.dirname(b), exist_ok=True)
    if os.path.exists(b):
        os.unlink(b)
    s = sqlite3.connect("file:" + a + "?mode=ro", uri=True, timeout=5)
    d = sqlite3.connect(b, timeout=5)
    try:
        s.backup(d)
    finally:
        s.close()
        d.close()


def keep(dst: str) -> list[str]:
    """Save the copy's cookie files (before a copy). Returns the ones kept."""
    k = kept_dir(dst)
    if os.path.isdir(k):
        import shutil

        shutil.rmtree(k, ignore_errors=True)
    done = []
    for rel in COOKIE_FILES:
        f = os.path.join(dst, rel)
        if os.path.isfile(f) and os.path.getsize(f) > 0:
            try:
                _backup(f, os.path.join(k, rel))
                done.append(rel)
            except sqlite3.Error:
                pass
    return done


def restore(dst: str) -> int:
    """Put the kept cookie files back. Returns how many files were restored."""
    n = 0
    for rel in COOKIE_FILES:
        b = os.path.join(kept_dir(dst), rel)
        if not os.path.isfile(b):
            continue
        f = os.path.join(dst, rel)
        for side in ("-journal", "-wal", "-shm"):  # a stale sidecar would replay over the restored file
            if os.path.exists(f + side):
                os.unlink(f + side)
        _backup(b, f)
        n += 1
    return n


def _unique_cols(c: sqlite3.Connection, schema: str) -> list[str]:
    for idx in c.execute(f"pragma {schema}.index_list(cookies)").fetchall():
        if idx[2] and idx[3] == "c":  # unique, from CREATE INDEX (Chrome's cookies_unique_index)
            return [r[2] for r in c.execute(f"pragma {schema}.index_info('{idx[1]}')")]
    return []


# Nov 20 2026: per cookie "newer wins" still signed X out. Their Chrome visits x.com as a guest every day, so
# its guest ct0 was newer and landed next to the hidden browser's auth_token, and X ended the session. And
# their Chrome's rows are sealed with another key (v10) than the hidden browser's own (v11): the hidden
# browser can't read them and drops them when it starts, so any site that took Chrome's rows lost them all.
# So each site comes whole from ONE side: the hidden browser's when it's signed in there and Chrome isn't,
# when its sign-in is newer, or when Chrome's rows are sealed with a key the hidden browser doesn't use.
_SEAL = re.compile(rb"v\d\d")
_AUTH = re.compile(r"sess|auth|token|login|sid|user|uid|twid|li_at|jwt|remember", re.I)
_SIGN_NAMES = {(d.lstrip(".").lower(), n) for _s, d, n in SIGNS}


def _site(host: str) -> str:
    """Cookies of one site together: accounts.google.com and .google.com are both google.com."""
    p = host.lstrip(".").lower().split(".")
    return ".".join(p[-2:]) if len(p) > 2 else ".".join(p)


def _site_rows(c: sqlite3.Connection, schema: str, key: list[str], stamp: str) -> dict:
    """site -> [(rowid, unique key, name, expires, stamp, seal)]. Reads the seal (first 3 bytes), never a value."""
    out: dict = {}
    ks = ", ".join(key)
    q = f"select rowid, {ks}, name, expires_utc, {stamp}, substr(encrypted_value, 1, 3), host_key from {schema}.cookies"
    for r in c.execute(q):
        k = tuple(r[1 : 1 + len(key)])
        name, exp, at, seal, host = r[1 + len(key) :]
        seal = bytes(seal) if isinstance(seal, (bytes, memoryview)) else str(seal or "").encode()
        out.setdefault(_site(host), []).append((r[0], k, name, exp, at, seal))
    return out


def _signed(site: str, rows: list) -> list:
    """The rows that look like a live sign-in on this site."""
    now = int((time.time() + 11644473600) * 1_000_000)
    return [r for r in rows if (r[3] == 0 or r[3] > now) and ((site, r[2]) in _SIGN_NAMES or _AUTH.search(r[2]))]


def _side(site: str, hidden: list, chrome: list, seals: set):
    """Which side a site present in both comes from: "hidden", "chrome", or None (nobody signed in: per cookie)."""
    if seals and any(_SEAL.fullmatch(r[5]) and r[5] not in seals for r in chrome):
        return "hidden"  # the hidden browser couldn't read Chrome's rows and would drop the site
    hs, cs = _signed(site, hidden), _signed(site, chrome)
    if hs and not cs:
        return "hidden"
    if cs and not hs:
        return "chrome"
    if hs and cs:
        return "hidden" if max(r[4] for r in hs) > max(r[4] for r in cs) else "chrome"
    return None


def merge(dst: str) -> int:
    """After a copy that worked: put back the hidden browser's sites, each whole (see _side). Returns rows put back."""
    total = 0
    for rel in COOKIE_FILES:
        b, f = os.path.join(kept_dir(dst), rel), os.path.join(dst, rel)
        if not (os.path.isfile(b) and os.path.isfile(f)):
            continue
        c = sqlite3.connect(f, timeout=5)
        try:
            c.execute("attach database ? as old", (b,))  # the kept copy; only read
            new_cols = [r[1] for r in c.execute("pragma main.table_info(cookies)")]
            old_cols = {r[1] for r in c.execute("pragma old.table_info(cookies)")}
            key = _unique_cols(c, "main")
            cols = [x for x in new_cols if x in old_cols]
            if not key or any(k not in old_cols for k in key) or len(cols) < len(new_cols):
                continue  # Chrome changed its table: keep their Chrome's copy as it is rather than guess
            stamp = "last_update_utc" if "last_update_utc" in cols else "creation_utc"
            old, new = _site_rows(c, "old", key, stamp), _site_rows(c, "main", key, stamp)
            seals = {r[5] for rs in old.values() for r in rs if _SEAL.fullmatch(r[5])}  # keys the hidden browser writes
            drop, add = [], []  # main rowids to delete, old rowids to insert
            for site, o in old.items():
                m = new.get(site, [])
                side = _side(site, o, m, seals) if m else "hidden"
                if side == "hidden":  # the hidden browser's whole site, nothing of Chrome's mixed in
                    drop += [r[0] for r in m]
                    add += [r[0] for r in o]
                elif side is None:  # nobody signed in there: the same cookie in both, the newer one wins
                    mine = {r[1]: r for r in m}
                    for r in o:
                        t = mine.get(r[1])
                        if t is None or r[4] > t[4]:
                            drop += [t[0]] if t else []
                            add.append(r[0])
            sel = ", ".join(cols)
            for i in range(0, len(drop), 500):
                part = drop[i : i + 500]
                c.execute(f"delete from main.cookies where rowid in ({','.join('?' * len(part))})", part)
            for i in range(0, len(add), 500):
                part = add[i : i + 500]
                q = f"insert or ignore into main.cookies ({sel}) select {sel} from old.cookies where rowid in ({','.join('?' * len(part))})"
                cur = c.execute(q, part)
                total += cur.rowcount if cur.rowcount > 0 else 0
            c.commit()
        except sqlite3.Error:
            c.rollback()
        finally:
            c.close()
    return total


def profiles(src: str) -> tuple[list[str], dict]:
    try:
        with open(os.path.join(src, "Local State"), encoding="utf-8-sig", errors="replace") as fh:
            cache = ((json.load(fh).get("profile") or {}).get("info_cache")) or {}
        return sorted(cache.keys()), cache
    except (OSError, ValueError, AttributeError):
        return [], {}


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(json.dumps({"ok": False, "error": "usage: one_my_chrome <browser> <copy dir> [--src <dir>]"}))
        return 2
    browser, dst = argv[0], os.path.abspath(os.path.expanduser(argv[1]))
    if browser == "restore":  # `restore <copy dir>`: the cookies from before the last copy, back in place
        try:
            n = restore(dst)
        except (OSError, sqlite3.Error) as e:
            print(json.dumps({"ok": False, "restored": 0, "error": str(e)}))
            return 1
        print(json.dumps({"ok": n > 0, "restored": n, "error": None if n else "nothing-kept"}))
        return 0 if n else 1
    src = None
    if "--src" in argv:
        i = argv.index("--src")
        src = argv[i + 1] if i + 1 < len(argv) else None
    pin = None
    if "--profile" in argv:
        i = argv.index("--profile")
        pin = argv[i + 1] if i + 1 < len(argv) else None
    from hermes_cli import browser_connect as bc

    bc.real_profile_copy_dir = lambda _b: dst  # One's folder, not Hermes's auto-cleaned one
    if pin:  # the profile they use, picked by One (never a silent switch to another identity)
        bc._real_profile_pin = lambda: pin
    src = src or bc.real_profile_data_dir(browser)
    out: dict = {"source": src}
    if not src or not os.path.isdir(src):
        # Inside the folder lock Chrome's folder looks missing too: say which it is.
        parent = os.path.dirname(src or "")
        why = "chrome-folder-unreadable" if parent and not os.access(parent, os.R_OK) else "no-chrome-folder"
        out.update(ok=False, error=why)
        print(json.dumps(out))
        return 1
    if not os.access(os.path.join(src, "Local State"), os.R_OK):
        out.update(ok=False, error="chrome-folder-unreadable")
        print(json.dumps(out))
        return 1
    profile, err = bc._resolve_source_profile(src)
    names, cache = profiles(src)
    out.update(profile=profile, profiles=names, profile_name=(cache.get(profile or "") or {}).get("name"))
    if err:
        out.update(ok=False, error=err)
        print(json.dumps(out))
        return 1
    try:
        keep(dst)
    except OSError:
        pass
    copy, err = bc.snapshot_real_profile(browser, src=src)
    kept = 0
    if copy and not err:
        kept = merge(dst)
    else:
        try:
            restore(dst)  # a failed copy leaves the hidden browser's cookies as they were
        except (OSError, sqlite3.Error):
            pass
    n, signs = copy_report(dst) if copy else (0, [])
    out.update(ok=bool(copy) and not err, copy=copy, error=err, cookies=n, signs=signs, kept=kept)
    print(json.dumps(out))
    return 0 if copy and not err else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
