"""Checks One's usage-meter overlay (tools/overlay/agent/one_account_usage.py) on the engine's REAL account_usage.py
(the pinned Hermes's, hooked by `One --apply-overlay`), with the real Nov 11 2026 /api/oauth/usage answer.

Run: python3 tools/usage-meter-check.py <engine folder whose agent/account_usage.py One hooked> [<pristine copy>]
     (prints "usage meter ok" when every case passes; CI runs it in preflight)
Cases: the pristine engine reads 1% as 100% (the bug), hooked it reads 1% as 1% and 100 as 100, `limits[].percent`
wins when sent (and adds a window only `limits` has), the 5-hour window too, Codex fractions unchanged, an odd
`limits` list never breaks the meter.
"""

import datetime
import importlib.util
import os
import sys
import types

if not hasattr(datetime, "UTC"):  # the engine wants Python 3.11's datetime.UTC; the Mac's python3 is older
    datetime.UTC = datetime.timezone.utc
ENGINE = os.path.abspath(sys.argv[1])
PRISTINE = sys.argv[2] if len(sys.argv) > 2 else None
sys.path.insert(0, ENGINE)
fails = 0


def check(name, ok, detail=""):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name + ("" if ok or not detail else f"  ({detail})"), flush=True)
    fails += 0 if ok else 1


# ---- stand-ins for the engine modules account_usage.py imports -----------------------------------------------------
def module(name, **attrs):
    m = types.ModuleType(name)
    m.__dict__.update(attrs)
    sys.modules[name] = m
    return m


class AuthError(Exception):
    pass


module("httpx", Client=None)
import agent  # the engine's own package (agent/__init__.py)

module("agent.anthropic_credentials", _is_oauth_token=lambda t: True, resolve_anthropic_token=lambda **k: "oauth-test")
module("agent.usage_gauges", BP_FULL=10000)
module("agent.account_usage_cache", remember_account_usage=lambda *a, **k: None)
module("hermes_cli")
module("hermes_cli.auth", AuthError=AuthError, _read_codex_tokens=lambda *a, **k: None,
       resolve_codex_runtime_credentials=lambda *a, **k: None)
module("hermes_cli.auth_codex", _codex_pool_route_base_url=lambda *a, **k: "")
module("hermes_cli.runtime_provider", resolve_runtime_provider=lambda **k: {})
module("hermes_time", safe_strftime=lambda dt, fmt: dt.strftime(fmt))

# The real answer from Nov 11 2026 (no token, no account id): the week at 1%, the 5-hour window unset.
NOV11 = {
    "five_hour": None,
    "seven_day": {"utilization": 1.0, "resets_at": "2026-11-18T07:59:59.686995+00:00", "limit_dollars": None},
    "seven_day_opus": None,
    "seven_day_sonnet": None,
    "extra_usage": {"is_enabled": False, "monthly_limit": 4000, "used_credits": 0.0, "utilization": 0.0},
    "limits": [
        {"kind": "weekly_all", "group": "weekly", "percent": 1, "severity": "normal",
         "resets_at": "2026-11-18T07:59:59.686995+00:00", "scope": None, "is_active": True},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 0, "severity": "normal",
         "resets_at": "2026-11-18T08:00:00+00:00", "scope": {"model": {"id": None, "display_name": "Fable"}},
         "is_active": False},
    ],
}


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m


def windows(mod, payload):
    mod._get_json = lambda url, headers, *, timeout: payload
    s = mod._fetch_anthropic_account_usage()
    return {w.label: w for w in s.windows}


def week(mod, payload):
    w = windows(mod, payload).get("Current week")
    return w.used_percent if w else None


if PRISTINE:
    raw = load(PRISTINE, "agent.account_usage_pristine")
    check("the pinned engine on its own reads Nov 11's 1% as 100% (the bug this fixes)", week(raw, NOV11) == 100.0,
          str(week(raw, NOV11)))

au = load(os.path.join(ENGINE, "agent", "account_usage.py"), "agent.account_usage")
check("the hook is in and wrapped the engine's own reader", getattr(au, "_one_usage_percent", False)
      and hasattr(au._usage_windows, "__wrapped__"))
check("Nov 11's answer: the week reads 1%, not 100%", week(au, NOV11) == 1.0, str(week(au, NOV11)))
w = windows(au, NOV11)["Current week"]
check("with its reset time and account scope", w.reset_at is not None and w.reset_at.year == 2026 and w.scope == "account")
no_limits = {"seven_day": {"utilization": 1.0, "resets_at": "2026-11-18T07:59:59Z"}}
check("utilization 1.0 with no limits list: 1%", week(au, no_limits) == 1.0, str(week(au, no_limits)))
full = {"seven_day": {"utilization": 100.0, "resets_at": "2026-11-18T07:59:59Z"}}
check("utilization 100: 100% (a full week still reads full)", week(au, full) == 100.0, str(week(au, full)))
half = {"seven_day": {"utilization": 0.5, "resets_at": "2026-11-18T07:59:59Z"}}
check("utilization 0.5: half a percent, never 50%", week(au, half) == 0.5, str(week(au, half)))
both = {"seven_day": {"utilization": 0.9, "resets_at": "2026-11-18T07:59:59Z"},
        "limits": [{"kind": "weekly_all", "percent": 37, "resets_at": "2026-11-18T08:00:00Z"}]}
check("limits[].percent wins over utilization when sent", week(au, both) == 37.0, str(week(au, both)))
session = {"seven_day": {"utilization": 4.0, "resets_at": "2026-11-18T07:59:59Z"},
           "limits": [{"kind": "session", "percent": 62, "resets_at": "2026-11-11T19:00:00Z"}]}
ws = windows(au, session)
check("a 5-hour window only limits[] has is added, with its reset", "Current session" in ws
      and ws["Current session"].used_percent == 62.0 and ws["Current session"].reset_at is not None
      and ws["Current week"].used_percent == 4.0)
odd = dict(NOV11, limits=[None, "x", {"kind": "weekly_all"}, {"kind": "weekly_all", "percent": "lots"}])
check("an odd limits list never breaks the meter (utilization still read as percent)", week(au, odd) == 1.0, str(week(au, odd)))
model = windows(au, dict(NOV11, seven_day_opus={"utilization": 1.0, "resets_at": "2026-11-18T07:59:59Z"}))
check("the model-only weeks stay model-scoped and read percent too", model["Opus week"].scope == "model"
      and model["Opus week"].used_percent == 1.0)
codex = au._usage_windows({"primary_window": {"used_percent": 0.4, "reset_at": None}}, (("primary_window", "Session"),),
                          "used_percent", "reset_at", fraction=True)
check("other providers untouched: a Codex fraction 0.4 still reads 40%", codex[0].used_percent == 40.0, str(codex[0].used_percent))
check("installing twice changes nothing", importlib.import_module("agent.one_account_usage").install(au)
      and au._usage_windows.__wrapped__.__name__ == "_usage_windows")

print("usage meter ok" if fails == 0 else f"usage meter: {fails} failed")
sys.exit(0 if fails == 0 else 1)
