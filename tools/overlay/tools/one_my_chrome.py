"""One: copy the person's own Chrome sign-ins into the hidden browser One keeps for helpers.

Run by One itself, OUTSIDE the folder lock (the lock closes Chrome's own folder):
    hermes --run-module tools.one_my_chrome <browser> <copy dir> [--src <user data dir>]
It reuses Hermes's real-profile snapshot (hermes_cli.browser_connect.snapshot_real_profile):
Local State rewritten for one Default profile, the active profile minus caches and extensions,
and the cookie/login databases copied with SQLite's online backup, so it works while their Chrome
is open. Only the destination differs: One's own folder instead of $HERMES_HOME/browser-profile
(Hermes deletes that one whenever browser.use_real_profile is off). Their Chrome is never touched,
never quit, never written to. Prints one JSON line: {"ok", "copy", "source", "profile", "error"}.
"""

import json
import os
import sys


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
    profile = None
    if src and os.path.isdir(src):
        profile, err = bc._resolve_source_profile(src)
        if err:
            print(json.dumps({"ok": False, "source": src, "error": err}))
            return 1
    copy, err = bc.snapshot_real_profile(browser, src=src)
    print(json.dumps({"ok": bool(copy) and not err, "copy": copy, "source": src, "profile": profile, "error": err}))
    return 0 if copy and not err else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
