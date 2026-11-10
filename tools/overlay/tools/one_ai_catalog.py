"""One's window into the engine's own AI lists (copied into the engine's tools/ by One, run with
`hermes --run-module tools.one_ai_catalog <command>`). Every answer comes from the engine's code, never a
list kept in One. Prints one JSON object. Never prints a key: only variable NAMES and "is there one".

  providers                 every AI the engine offers, with what One needs to add a key and check it
  models <provider>         the engine's model list for one AI (its live list when it has one, else its own)
  efforts <provider> <model>...  the thinking levels the engine really sends for each model (probed per level)
  save-key <provider>       reads ONE key on stdin and saves it the way the engine's own screens do
  resolved <model> [job]    (tests) the level the engine resolves for a new chat / helper and for a routine
"""
import json
import sys

LADDER = ("none", "low", "medium", "high", "xhigh", "max")
EFFORT_KEYS = ("effort", "reasoning_effort", "verbosity", "thinking_level", "thinkingLevel")


def out(obj):
    json.dump(obj, sys.stdout)
    sys.stdout.write("\n")


def _profiles():
    try:
        from providers import list_providers
        return {p.name: p for p in list_providers()}
    except Exception:
        return {}


def _health_checks():
    """The engine's own `hermes doctor` key checks: first key variable -> (models url, has a /models)."""
    try:
        from hermes_cli.doctor_connectivity import _build_apikey_providers_list
        rows = _build_apikey_providers_list()
    except Exception:
        return {}
    return {r[1][0]: (r[2], bool(r[4])) for r in rows if r[1]}


def providers():
    from hermes_cli import auth_plugin_providers as app
    from hermes_cli.auth import PROVIDER_REGISTRY, get_auth_status
    from hermes_cli.models import get_default_model_for_provider
    from hermes_cli.provider_catalog import provider_catalog
    app.sync_plugin_provider_registry()
    profiles = _profiles()
    checks = _health_checks()
    rows = []
    for d in provider_catalog():  # the list `hermes model` and the engine's own app show
        cfg = PROVIDER_REGISTRY.get(d.slug)
        prof = profiles.get(d.slug)
        base = (cfg.inference_base_url if cfg else "") or (getattr(prof, "base_url", "") if prof else "") or ""
        api_mode = (getattr(prof, "api_mode", "") if prof else "") or ""
        keys = [v for v in d.api_key_env_vars if not v.endswith("_URL")]
        try:
            model = get_default_model_for_provider(d.slug) or ""
        except Exception:
            model = ""
        if not model and prof:
            model = (list(getattr(prof, "fallback_models", ()) or []) or [""])[0]
        url, has_models = checks.get(keys[0], (None, True)) if keys else (None, False)
        if not has_models:
            url = ""
        elif url is None and base:
            url = (getattr(prof, "models_url", "") if prof else "") or base.rstrip("/") + "/models"
        auth = "x-api-key" if api_mode == "anthropic_messages" else ("query" if d.slug == "gemini" else "bearer")
        try:
            st = get_auth_status(d.slug) or {}
        except Exception:
            st = {}
        host = base.split("//")[-1].split("/")[0].split(":")[0]
        rows.append({
            "id": d.slug, "name": d.label, "about": d.description or "", "auth_type": d.auth_type,
            "key_vars": keys, "base_url": base, "api_mode": api_mode, "model": model,
            "key_page": d.signup_url or "", "check_url": url or "", "check_auth": auth,
            "needs_base_url": not base, "local": host in ("127.0.0.1", "localhost", "0.0.0.0"),
            "builtin_registry": cfg is not None, "has_key": bool(st.get("logged_in") or st.get("configured")),
        })
    out({"schema": 1, "providers": rows})


def models(pid):
    from hermes_cli.models import curated_models_for_provider
    try:
        ids = [m for m, _ in curated_models_for_provider(pid)]
    except Exception:
        ids = []
    out({"provider": pid, "models": ids})


def _cfg(level):
    from hermes_constants import parse_reasoning_effort
    return parse_reasoning_effort(level)


def _found(obj):
    """Every effort word anywhere in a request, plus whether thinking was switched off."""
    words, off = set(), False
    stack = [obj]
    while stack:
        o = stack.pop()
        if isinstance(o, dict):
            for k, v in o.items():
                if k in EFFORT_KEYS and isinstance(v, str):
                    words.add(v.strip().lower())
                if k == "type" and v in ("disabled", "between_tools"):
                    off = True
                if k == "enabled" and v is False:
                    off = True
                if k == "think" and v is False:
                    off = True
                stack.append(v)
        elif isinstance(o, (list, tuple)):
            stack.extend(o)
    return words, off


def _wire(pid, model, level, row):
    """What the engine would put on the wire for this level (its own request builders, no network)."""
    mode = row.get("api_mode") or ""
    if pid == "anthropic" or mode == "anthropic_messages":
        from agent.anthropic_adapter import _thinking_kwargs
        return _thinking_kwargs(_cfg(level), model, 64000)
    if pid in ("openai-codex", "xai-oauth") or mode == "codex_responses":
        from agent.transports.codex import _resolve_reasoning
        from agent.model_metadata import grok_supports_reasoning_effort, openai_model_rejects_reasoning
        xai = pid.startswith("xai")
        if xai and not grok_supports_reasoning_effort(model):
            return {}
        if not xai and openai_model_rejects_reasoning(model):
            return {}
        params = {"reasoning_config": _cfg(level), "provider": pid, "base_url": row.get("base_url")}
        params["is_xai_responses" if xai else "is_codex_backend"] = True if xai else pid == "openai-codex"
        effort, enabled = _resolve_reasoning(model, params)
        if effort is None:
            return {}
        return {"reasoning": {"effort": effort}, "enabled": enabled}
    from agent.transports.chat_completions import ChatCompletionsTransport
    from providers import get_provider_profile
    supports = True
    try:
        from agent.models_dev import get_model_capabilities
        caps = get_model_capabilities(pid, model, allow_network=False)
        if caps is not None and caps.supports_reasoning is False:
            supports = False
    except Exception:
        pass
    kw = ChatCompletionsTransport().build_kwargs(
        model, [{"role": "user", "content": "hi"}], provider_profile=get_provider_profile(pid),
        reasoning_config=_cfg(level), supports_reasoning=supports, base_url=row.get("base_url"), provider_name=pid)
    return {k: v for k, v in kw.items() if k not in ("messages", "tools")}


def _levels(pid, model, row):
    levels, budgets = [], []
    for lv in LADDER:
        try:
            wire = _wire(pid, model, lv, row)
        except Exception:
            continue
        words, off = _found(wire)
        budget = ((wire or {}).get("thinking") or {}).get("budget_tokens") if isinstance(wire, dict) else None
        if lv == "none":
            if off or "none" in words:
                levels.append(lv)
        elif lv in words:
            levels.append(lv)
        elif budget and budget not in budgets:  # older thinking: a level counts when it buys its own budget
            levels.append(lv)
        if budget:
            budgets.append(budget)
    return levels


def efforts(pid, models):
    row = next((r for r in _rows_quiet() if r["id"] == pid), {"api_mode": "", "base_url": ""})
    out({"provider": pid, "levels": {m: _levels(pid, m, row) for m in models}})


def _rows_quiet():
    import io
    real = sys.stdout
    sys.stdout = io.StringIO()
    try:
        providers()
        return json.loads(sys.stdout.getvalue())["providers"]
    except Exception:
        return []
    finally:
        sys.stdout = real


def save_key(pid):
    from hermes_cli.auth import PROVIDER_REGISTRY
    from hermes_cli.credential_lifecycle import save_provider_env_credential
    key = sys.stdin.readline().strip()
    cfg = PROVIDER_REGISTRY.get(pid)
    names = [v for v in (cfg.api_key_env_vars if cfg else ()) if not v.endswith("_URL")]
    if not key or not names:
        out({"ok": False, "error": "no key" if not key else "this AI takes no key"})
        return
    try:
        save_provider_env_credential(names[0], key)
    except Exception as e:
        out({"ok": False, "error": type(e).__name__})
        return
    out({"ok": True, "var": names[0]})


def resolved(model, job=None):
    from hermes_cli.config import load_config_readonly as load_config
    from hermes_constants import resolve_reasoning_config
    cfg = load_config()
    chat = resolve_reasoning_config(cfg, model)
    res = {"model": model, "chat": (chat or {}).get("effort") if (chat or {}).get("enabled", True) else "none"}
    if job is not None:
        from cron.scheduler import _resolve_job_reasoning_config as _job_reasoning_config
        r = _job_reasoning_config(json.loads(job), cfg, model)
        res["routine"] = (r or {}).get("effort") if (r or {}).get("enabled", True) else "none"
    out(res)


def main(argv):
    cmd = argv[0] if argv else ""
    if cmd == "providers":
        providers()
    elif cmd == "models" and len(argv) > 1:
        models(argv[1])
    elif cmd == "efforts" and len(argv) > 2:
        efforts(argv[1], argv[2:])
    elif cmd == "save-key" and len(argv) > 1:
        save_key(argv[1])
    elif cmd == "resolved" and len(argv) > 1:
        resolved(argv[1], argv[2] if len(argv) > 2 else None)
    else:
        out({"error": "usage: providers | models <id> | efforts <id> <model>... | save-key <id> | resolved <model> [job]"})
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
