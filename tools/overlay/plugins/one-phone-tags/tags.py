"""One's phone-tags plugin: the tags in a finished reply, cut exactly like Sources/TagLines.swift.

Pure text, no engine: what the person's phone shows for a reply (``shown``), the plain line for a reply that was only
tags (``plain_line``) and One's receipts for the lines it acted on (``receipts``). Kept in step with TagLines.acted /
TagLines.hidden; tests/fixtures/phone-tags/shown.json is checked against both (tools/phone-tags-check.py and
`One --test-helpers`).
"""

from __future__ import annotations

from typing import Optional

ACTED = ["helper", "tell-helper", "stop-helper", "done-helper", "close-helper"]
HIDDEN = ACTED + ["job-kind", "learned"]
RECEIPT = "↳"

def _opens(c: str, i: int, open_: str) -> bool:
    return c[i:i + len(open_)].lower() == open_


def _closing(c: str, i: int) -> Optional[int]:
    """The "]" balancing the "[" at i."""
    depth = 0
    for j in range(i, len(c)):
        if c[j] == "[":
            depth += 1
        elif c[j] == "]":
            depth -= 1
            if depth == 0:
                return j
    return None


def _stray(c: str, k: int, opens: list[str]) -> int:
    """A "]" later on that closes nothing there still ends this tag; looks no further than the next tag."""
    end, depth, low = k + 1, 0, 0
    m = k + 1
    while m < len(c):
        if c[m] == "[":
            if any(_opens(c, m, o) for o in opens):
                break
            depth += 1
        elif c[m] == "]":
            depth -= 1
            if depth < low:
                low = depth
                end = m + 1
        m += 1
    return end


def _next_line_start(c: str, frm: int, open_: str) -> Optional[int]:
    m = frm
    while m < len(c):
        if c[m] == "\n":
            s = m + 1
            while s < len(c) and c[s] in " \t":
                s += 1
            if _opens(c, s, open_):
                return s
        m += 1
    return None


def hits(c: str, tags: list[str]) -> list[dict]:
    """Every outermost tag of these kinds, in reading order (a finished reply)."""
    opens = [(t.lower(), "[" + t.lower() + ":") for t in tags]
    out: list[dict] = []
    i = 0
    while i < len(c):
        o = next((x for x in opens if _opens(c, i, x[1])), None) if c[i] == "[" else None
        if o is None:
            i += 1
            continue
        frm = i + len(o[1])
        k = _closing(c, i)
        if k is not None:
            end = _stray(c, k, [x[1] for x in opens])
            out.append({"start": i, "end": end, "body": c[frm:end - 1], "tag": o[0], "open": False})
            i = end
        else:
            nxt = _next_line_start(c, frm, o[1])
            nxt = len(c) if nxt is None else nxt
            out.append({"start": i, "end": nxt, "body": c[frm:nxt].strip(), "tag": o[0], "open": True})
            i = nxt
    return out


def cut(c: str, hs: list[dict]) -> str:
    out = ""
    at = 0
    n = len(c)
    for h in hs:
        s = h["start"]
        while s > at and c[s - 1] in " \t":
            s -= 1
        if h["open"]:
            out += c[at:s]
            at = n
            break
        e = h["end"]
        while e < n and c[e] in " \t":
            e += 1
        if (s == 0 or c[s - 1] == "\n") and e < n and c[e] == "\n":
            e += 1  # a tag on lines of its own: no blank line left
        out += c[at:s]
        after = c[e] if e < n else "\n"
        if out and out[-1] != "\n" and after != "\n":
            out += "\n"
        at = e
    if at < n:
        out += c[at:]
    lines = out.split("\n")
    while lines and not lines[-1].strip(" \t"):
        lines.pop()
    while lines and not lines[0].strip(" \t"):
        lines.pop(0)
    t = "\n".join(lines)
    while "\n\n\n" in t:
        t = t.replace("\n\n\n", "\n\n")
    return t


def shown(text: str) -> str:
    """What the person sees: One's own chat shows Helpers.strip(Helpers.read(reply).said)."""
    hs = hits(text, ACTED)
    said = cut(text, hs) if hs else text
    hs = hits(said, HIDDEN)
    t = cut(said, hs) if hs else said
    k = t.rfind("[")
    if k >= 0:
        tail = t[k:].lower()
        if any(("[" + tag + ":").startswith(tail) for tag in HIDDEN):
            t = t[:k].strip(" \t")
    keep = [ln for ln in t.split("\n") if not any(ln.strip(" \t").lower().startswith("[" + tag) for tag in HIDDEN)]
    return "\n".join(keep)


def _title(body: str) -> str:
    return " ".join(body.split("|", 1)[0].split())[:60]


def plain_line(text: str) -> str:
    """One short line for a reply that was only tags."""
    hs = hits(text, ACTED)
    jobs = [_title(h["body"]) for h in hs if h["tag"] == "helper" and "|" in h["body"]]
    tells = [_title(h["body"]) for h in hs if h["tag"] == "tell-helper"]
    stops = [_title(h["body"]) for h in hs if h["tag"] == "stop-helper"]
    clears = [_title(h["body"]) for h in hs if h["tag"] in ("done-helper", "close-helper")]
    parts = []
    if jobs:
        parts.append("On it: I sent a helper for " + ", ".join(jobs) + ". I'll message you here when it's done.")
    if stops:
        parts.append("Stopped " + ", ".join(stops) + ".")
    if clears:
        parts.append("Cleared " + ", ".join(clears) + ".")
    if tells:
        parts.append("Passed that on to " + ", ".join(tells) + ".")
    return " ".join(parts) or "Done."


def receipts(text: str) -> list[str]:
    """One short line per acted tag, added at the end of the reply: the person sees what went to One, and the saved
    reply (replayed next turn) no longer reads as a promise that ends at a colon."""
    out = []
    for h in hits(text, ACTED):
        name = _title(h["body"])
        if not name:
            continue
        if h["tag"] == "helper":
            line = f"{RECEIPT} Helper sent: {name}" if "|" in h["body"] else ""
        elif h["tag"] == "tell-helper":
            line = f"{RECEIPT} Passed on to {name}"
        elif h["tag"] == "stop-helper":
            line = f"{RECEIPT} Stopping {name}"
        else:
            line = f"{RECEIPT} Clearing {name}"
        if line and line not in out:
            out.append(line)
    return out
