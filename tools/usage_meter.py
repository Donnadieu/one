"""One: the AI plan's own meter (the 5-hour window and the week), read through the engine's own code.

Run by One (outside the folder lock) with the engine's python, cwd = the engine folder:
    <engine venv python> -I usage_meter.py <provider> [<engine dir>]
Prints one JSON line: {"provider", "windows": [{"label", "used", "reset", "scope"}], "error"}.
Reads only (a GET to the provider's usage endpoint with the login the engine already has); never prints a token.
"""

import json
import os
import sys


def main() -> int:
    provider = sys.argv[1] if len(sys.argv) > 1 else "anthropic"
    engine = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
    sys.path.insert(0, engine)
    out = {"provider": provider, "windows": [], "error": None}
    try:
        from agent.account_usage import fetch_account_usage

        s = fetch_account_usage(provider)
        if s is None:
            out["error"] = "no meter for this AI"
        else:
            out["error"] = s.unavailable_reason
            for w in s.windows:
                out["windows"].append({
                    "label": w.label,
                    "used": w.used_percent,
                    "reset": w.reset_at.timestamp() if w.reset_at else None,
                    "scope": w.scope,
                })
    except Exception as e:  # a meter that can't be read is just unknown
        out["error"] = type(e).__name__
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
