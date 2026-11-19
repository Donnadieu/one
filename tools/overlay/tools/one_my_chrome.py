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


def merge(dst: str) -> int:
    """After a copy that worked: add back the kept cookies their Chrome doesn't have, or has older. Returns how many."""
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
            on = " and ".join(f"m.{k} = o.{k}" for k in key)
            newer = "o.last_update_utc > m.last_update_utc" if "last_update_utc" in cols else "o.creation_utc > m.creation_utc"
            # The same cookie in both: the hidden browser's wins only when it's newer.
            c.execute(f"delete from main.cookies where rowid in (select m.rowid from main.cookies m join old.cookies o on {on} where {newer})")
            sel = ", ".join(cols)
            cur = c.execute(f"insert or ignore into main.cookies ({sel}) select {sel} from old.cookies")
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
