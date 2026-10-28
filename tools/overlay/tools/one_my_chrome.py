"""One: copy the person's own Chrome sign-ins into the hidden browser One keeps for helpers.

Run by One itself, OUTSIDE the folder lock (the lock closes Chrome's own folder):
    hermes --run-module tools.one_my_chrome <browser> <copy dir> [--src <user data dir>]
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
    src = None
    if "--src" in argv:
        i = argv.index("--src")
        src = argv[i + 1] if i + 1 < len(argv) else None
    from hermes_cli import browser_connect as bc

    bc.real_profile_copy_dir = lambda _b: dst  # One's folder, not Hermes's auto-cleaned one
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
    copy, err = bc.snapshot_real_profile(browser, src=src)
    n, signs = copy_report(dst) if copy else (0, [])
    out.update(ok=bool(copy) and not err, copy=copy, error=err, cookies=n, signs=signs)
    print(json.dumps(out))
    return 0 if copy and not err else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
