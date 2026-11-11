"""One: the Claude plan's meter reads percent, never a fraction (copied into the engine's agent/ by One, hooked
into agent/account_usage.py by `Installer.applyUsageMeter`).

Anthropic's /api/oauth/usage sends `seven_day.utilization: 1.0` for 1% used (the same answer's `limits[]` says
`percent: 1`). The pinned Hermes reads it with `_usage_windows(..., fraction=True)`, which scales anything <= 1 up
by 100, so 1% became 100% (Nov 11 2026: every helper paused at a limit that wasn't there). Upstream issues:
NousResearch/hermes-agent#139008, #145660, #146280, #147006 (and #152095 for the `limits` list).

`install(module)` wraps the module's `_usage_windows` for the Anthropic call only (the one that reads
`utilization` with a `seven_day` window): it always reads percent, and when the answer carries `limits[]` it takes
`percent` from there (`session` = the 5-hour window, `weekly_all` = the week). Every other provider (Codex reads
`used_percent`, which really can be a fraction) goes through the engine's own code unchanged. Never raises.
"""

# The `limits[].kind` Anthropic sends, and the window key it stands for.
LIMIT_KINDS = {"session": "five_hour", "weekly_all": "seven_day"}


def is_anthropic(mapping, used_key):
    return used_key == "utilization" and any(key == "seven_day" for key, _ in mapping)


def _number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v == v


def from_limits(mod, source, mapping, windows):
    """Windows with `limits[].percent` put in for the session and the week (added when only `limits` has one)."""
    labels = dict(mapping)
    limits = source.get("limits") if isinstance(source, dict) else None
    if not isinstance(limits, list):
        return windows
    out = list(windows)
    for item in limits:
        if not isinstance(item, dict):
            continue
        key = LIMIT_KINDS.get(item.get("kind"))
        label = labels.get(key) if key else None
        if not label or not _number(item.get("percent")):
            continue
        old = next((w for w in out if w.label == label), None)
        reset = mod._parse_dt(item.get("resets_at")) or (old.reset_at if old else None)
        new = mod.AccountUsageWindow(label=label, used_percent=float(item["percent"]), reset_at=reset, scope="account")
        out = [new if w is old else w for w in out] if old else out + [new]
    return out


def install(mod):
    """Wraps `mod._usage_windows` once. False when the engine no longer has what it wraps (then nothing changes)."""
    try:
        if getattr(mod, "_one_usage_percent", False):
            return True
        original = getattr(mod, "_usage_windows", None)
        if not callable(original) or not hasattr(mod, "AccountUsageWindow") or not hasattr(mod, "_parse_dt"):
            return False

        def usage_windows(source, mapping, used_key, reset_key, *, fraction=False, **kw):
            if not is_anthropic(mapping, used_key):
                return original(source, mapping, used_key, reset_key, fraction=fraction, **kw)
            windows = original(source, mapping, used_key, reset_key, fraction=False, **kw)  # percent, as sent
            try:
                return from_limits(mod, source, mapping, windows)
            except Exception:  # an odd `limits` list: the percent windows still stand
                return windows

        usage_windows.__wrapped__ = original
        mod._usage_windows = usage_windows
        mod._one_usage_percent = True
        return True
    except Exception:
        return False
