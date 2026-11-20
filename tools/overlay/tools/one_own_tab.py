"""One: the hand-off shows the tab the asking helper was working in, never another helper's (Nov 19 2026).

Helpers share one hidden browser (the Chrome copy on 9224, One's own on 9223). ``hand_off`` used to show the open
tab that looked most like a human step, so a helper asking Omar to sign in to X showed him another helper's
Greenhouse job form (its captcha outscored X's plain log-in page), even after the X tab was put in front.

So every ``browser_exec`` call notes, by the helper's task id, the tab its browser session ends on (the harness
daemon's ``current_tab()``, written when the call's script exits). ``hand_off`` then shows that tab and only that
tab, brought to the front of its browser with Chrome's own activate: the same browser, nothing closed, reloaded or
reopened. A helper that opened its tab some other way passes ``target_id``. With no note at all, the old pick
still runs, but never on a tab another helper noted.

Copied next to ``one_human_step.py`` in the engine's ``tools/`` by One (``Installer.applyHumanStep``).
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import time
import urllib.request
from pathlib import Path
from typing import Optional

KEEP_SECONDS = 6 * 3600  # another helper's note older than this no longer hides its tab

# Prepended to every browser_exec script (the harness runs it with exec() in its own process, so the note is
# written at exit even when the script raised). `current_tab()` is the harness helper: the daemon's attached tab.
TAB_NOTE = """\
def _one_note_tab(_p={path!r}):  # One: the tab this helper ends on (hand_off shows exactly that tab)
    import json as _j, os as _o, time as _t
    try:
        _c = current_tab()
        with open(_p + ".tmp", "w") as _f:
            _j.dump({{"target_id": _c["targetId"], "url": _c.get("url", ""), "at": _t.time()}}, _f)
        _o.replace(_p + ".tmp", _p)
    except Exception:
        pass
__import__("atexit").register(_one_note_tab)
"""


def _dir() -> Path:
    override = os.environ.get("ONE_HANDOFF_DIR")
    if override:
        d = Path(override) / "tabs"
    else:
        from hermes_constants import get_hermes_home
        d = Path(get_hermes_home()).parent / "handoff" / "tabs"
    d.mkdir(parents=True, exist_ok=True)
    return d


def note_path(task_id: Optional[str]) -> Path:
    return _dir() / (re.sub(r"[^A-Za-z0-9._-]+", "_", task_id or "default")[:120] + ".json")


def _read(p: Path) -> dict:
    try:
        return json.loads(p.read_text())
    except Exception:
        return {}


def note(task_id: Optional[str], target_id: str, url: str = "") -> None:
    """This helper's tab is now `target_id` (e.g. the page came back in a new tab after the window)."""
    if not target_id:
        return
    p = note_path(task_id)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps({"target_id": target_id, "url": url, "at": time.time()}))
    os.replace(tmp, p)


def _pages(host: str, port: int) -> list[dict]:
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/json/list", timeout=3) as r:
            return [t for t in json.loads(r.read().decode()) if t.get("type") == "page"]
    except Exception:
        return []


def own_tab(host: str, port: int, task_id: Optional[str], target_id: str = "") -> Optional[dict]:
    """The helper's own open tab on this browser: the one it named, else the one its last browser_exec ended on."""
    tid = target_id or _read(note_path(task_id)).get("target_id", "")
    return next((t for t in _pages(host, port) if tid and t.get("id") == tid), None)


def others_tabs(task_id: Optional[str]) -> frozenset:
    """Tabs other helpers noted lately: never shown for this helper."""
    mine, out = note_path(task_id), set()
    for f in mine.parent.glob("*.json"):
        n = _read(f)
        if f != mine and n.get("target_id") and time.time() - float(n.get("at") or 0) < KEEP_SECONDS:
            out.add(n["target_id"])
    return frozenset(out)


def bring_forward(host: str, port: int, target_id: str) -> bool:
    """That tab in front of its browser (Chrome's own activate: nothing reloads, closes or reopens)."""
    try:
        with urllib.request.urlopen(f"http://{host}:{port}/json/activate/{target_id}", timeout=3) as r:
            return r.status == 200
    except Exception:
        return False


def wrap_browser_exec() -> bool:
    """Makes every browser_exec call note the tab it ends on. True once the engine's browser_exec is wrapped."""
    with contextlib.suppress(Exception):
        import tools.browser_use_cli as bu
        if getattr(bu.browser_exec, "_one_own_tab", False):
            return True
        run = bu.browser_exec

        def browser_exec(code: str = "", *a, **kw):
            if code and code.strip():
                code = TAB_NOTE.format(path=str(note_path(kw.get("task_id")))) + code
            return run(code, *a, **kw)

        browser_exec._one_own_tab = True  # type: ignore[attr-defined]
        bu.browser_exec = browser_exec  # the registry's handler looks it up here on every call
        return True
    return False
