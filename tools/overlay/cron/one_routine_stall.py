"""One: a routine never sits on a model reply that has gone quiet, and a reply cut short picks the same turn back up.

Hooked into the engine's ``cron/scheduler.py`` by One (Installer.applyRoutineStall); copied next to it.
Nov 25 and 27 2026: routines sat 11 minutes to over an hour on a reply that sent nothing (the Mac slept with the lid
shut, the connection died under it), then failed "Operation interrupted: waiting for model response" and every step
they had done was thrown away with the run. Two changes, routines only (platform ``cron`` and their own helpers):

1. A streamed reply with no data for ``ONE_ROUTINE_STALL_SECONDS`` (default 240 s) is cut off: the engine's own
   stall timer is capped at that (it allows 900 s for a model on this Mac, more for some thinking models). Only
   streamed replies: a non-streamed one sends nothing until it is done, so silence there is not a stall.
2. When the turn still ends on the model (the engine's retries ran out while the AI couldn't be reached, or the
   session lease lapsed while the Mac slept), the run waits until the AI's address answers again (polling every
   ``ONE_ROUTINE_REACH_POLL_SECONDS``, 15 s, for up to ``ONE_ROUTINE_REACH_WAIT_SECONDS``, 30 min) and runs the
   SAME turn again with everything it already did (tool calls and their results) as its history, so a finished
   step (an upload, a post) is not done twice. At most ``ONE_ROUTINE_TURN_RETRIES`` (3) times per run.
A person's Stop, a cancelled run, a rate limit, a billing or sign-in wall are never retried.
"""

import functools
import logging
import os
import socket
import time
from urllib.parse import urlsplit

logger = logging.getLogger("cron.scheduler")

_INSTALLED = "_one_routine_stall"
# The engine's turn exit reasons for a turn the system (not a person) cut short during a model call.
_RETRY_ISSUERS = ("session_turn_lease_lost", "turn_liveness_watchdog")
# Classified API failures that mean "the AI couldn't be reached or answered nothing", after the engine's own retries.
_RETRY_FAILURES = ("timeout", "server_error", "overloaded")
_RETRY_TEXT = (
    "can't reach the model provider", "has been unresponsive (no response received)", "connection error",
    "timed out", "no response received",
)
CONTINUE = (
    "[The connection to the AI dropped while this routine was working, and it has been picked back up.] "
    "Carry on from exactly where you stopped. Everything above already happened: don't redo a finished step "
    "(an upload, a post, a message sent, a file written); check its result above instead."
)


def _env_float(name, default):
    try:
        value = float(os.environ.get(name, "") or default)
    except ValueError:
        return default
    return value if value > 0 else default


def stall_seconds():
    return _env_float("ONE_ROUTINE_STALL_SECONDS", 240.0)


def is_routine(agent, depth=0):
    """A cron agent, or a helper one started (followed up its delegate parents)."""
    if agent is None or depth > 8:
        return False
    if getattr(agent, "platform", None) == "cron":
        return True
    ref = getattr(agent, "_delegate_parent_ref", None)
    parent = ref() if callable(ref) else None
    return is_routine(parent, depth + 1)


def capped(agent, value):
    """The engine's stall patience for a streamed reply, capped at the routine limit for routines."""
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not is_routine(agent):
        return value
    limit = stall_seconds()
    if value > limit:
        logger.info("Routine stream stall limit %.0fs (the engine's was %.0fs)", limit, value)
        return limit
    return value


def _patch_streams():
    """Cap the stall timer of the engine's streamed calls (Anthropic/OpenAI streams, and Bedrock's)."""
    from agent import chat_completion_helpers as h

    call = getattr(h, "_StreamingCall", None)
    orig = getattr(call, "_resolve_stale_timeout", None)
    if orig is None:
        return False
    if not getattr(orig, "_one_capped", False):

        @functools.wraps(orig)
        def _resolve_stale_timeout(self):
            orig(self)
            self._stream_stale_timeout = capped(self.agent, self._stream_stale_timeout)

        _resolve_stale_timeout._one_capped = True
        call._resolve_stale_timeout = _resolve_stale_timeout
    derive = getattr(h, "_derive_stream_stale_timeout", None)
    if derive is not None and not getattr(derive, "_one_capped", False):

        @functools.wraps(derive)
        def _derive_stream_stale_timeout(agent, api_kwargs):
            return capped(agent, derive(agent, api_kwargs))

        _derive_stream_stale_timeout._one_capped = True
        h._derive_stream_stale_timeout = _derive_stream_stale_timeout
    return True


def should_retry(result, cancel_event=None):
    """True for a turn that ended on the model with no person behind the stop."""
    if not isinstance(result, dict) or not (result.get("failed") is True or result.get("completed") is False):
        return False
    if cancel_event is not None and cancel_event.is_set():
        return False
    reason = str(result.get("turn_exit_reason") or "")
    if reason.startswith("interrupted_during_api_call("):
        return reason[len("interrupted_during_api_call("):].rstrip(")") in _RETRY_ISSUERS
    if reason.startswith(("interrupted", "max_iterations", "budget", "guardrail")):
        return False  # a person's Stop, a gateway restart, a limit: never picked back up
    if result.get("billing_block") or result.get("failure_reason") in ("rate_limit", "billing", "auth", "auth_permanent"):
        return False
    if result.get("failure_reason") in _RETRY_FAILURES or reason == "all_retries_exhausted_no_response":
        return True
    text = f"{result.get('error') or ''} {result.get('final_response') or ''}".lower()
    return any(t in text for t in _RETRY_TEXT)


def _address(agent):
    """(host, port) a TCP connect must reach for the AI to be reachable: the proxy when one is set."""
    proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
    url = urlsplit(proxy if proxy else str(getattr(agent, "base_url", "") or "https://api.anthropic.com"))
    if not url.hostname:
        return None
    return url.hostname, url.port or (443 if url.scheme in ("https", "") else 80)


def reachable(address, timeout=5.0):
    if address is None:
        return True
    try:
        with socket.create_connection(address, timeout=timeout):
            return True
    except OSError:
        return False


def wait_until_reachable(agent, job, scheduler, cancel_event=None):
    """Poll the AI's address until it answers; keeps the run's claim fresh meanwhile. False = gave up."""
    address = _address(agent)
    poll = _env_float("ONE_ROUTINE_REACH_POLL_SECONDS", 15.0)
    deadline = time.monotonic() + _env_float("ONE_ROUTINE_REACH_WAIT_SECONDS", 1800.0)
    said = False
    while True:
        if cancel_event is not None and cancel_event.is_set():
            return False
        if reachable(address):
            return True
        if time.monotonic() >= deadline:
            return False
        if not said:
            logger.warning("Job '%s': the AI (%s) can't be reached; waiting for it before picking the turn back up",
                           job.get("name") or job.get("id"), address and address[0])
            said = True
        _keep_claim(job, scheduler)
        time.sleep(poll)


def _keep_claim(job, scheduler):
    """While it waits the run is alive: refresh its run claim (one-shot jobs) and its progress stamp."""
    claim = job.get("run_claim")
    owner = str(claim.get("by") or "") if isinstance(claim, dict) else ""
    try:
        if owner and hasattr(scheduler, "heartbeat_run_claim"):
            scheduler.heartbeat_run_claim(job["id"], expected_owner=owner)
        execution = str(job.get("execution_id") or "")
        if execution:
            from cron.executions import touch_execution_progress

            touch_execution_progress(execution)
    except Exception:
        logger.debug("Job '%s': claim refresh while waiting failed", job.get("id"), exc_info=True)


def continuation(result, prompt):
    """(history, message) for running the same turn again: what was done so far, and what to send.

    When the model was never answered for this turn (the last message is the turn's own request) that request
    is sent again as is; otherwise the work so far is the history and the model is told to carry on."""
    messages = [m for m in (result.get("messages") or []) if isinstance(m, dict)]
    while messages and messages[-1].get("role") == "assistant" and not messages[-1].get("tool_calls") \
            and "interrupted" in str(messages[-1].get("content") or "").lower():
        messages.pop()  # the engine's own "Operation interrupted" note is not work
    if not messages:
        return None, prompt
    if messages[-1].get("role") == "user":
        return messages[:-1] or None, messages[-1].get("content") or prompt
    return messages, CONTINUE


def _clear_interrupt(agent):
    clear = getattr(agent, "clear_interrupt", None)
    if callable(clear):
        try:
            clear(hard_cancel=True)
        except TypeError:
            clear()
        except Exception:
            logger.debug("clear_interrupt failed", exc_info=True)


def install(scheduler):
    """Wrap the scheduler's ``_run_agent_with_watchdog`` once. True when hooked."""
    if getattr(scheduler, _INSTALLED, False):
        return True
    orig = getattr(scheduler, "_run_agent_with_watchdog", None)
    if orig is None:
        return False

    @functools.wraps(orig)
    def _run_agent_with_watchdog(agent, prompt, job, job_id, job_name, task_id, cancel_event, worker_state=None):
        try:
            if not _patch_streams():
                logger.warning("one_routine_stall: the engine's stream stall timer moved; routine limit not set")
        except Exception as exc:  # never break a routine
            logger.warning("one_routine_stall: stream limit not set: %s", exc)
        result = orig(agent, prompt, job, job_id, job_name, task_id, cancel_event, worker_state=worker_state)
        tries = int(_env_float("ONE_ROUTINE_TURN_RETRIES", 3))
        for attempt in range(1, tries + 1):
            if not should_retry(result, cancel_event):
                break
            logger.warning(
                "Job '%s': the turn ended on the model (%s); picking the same turn back up once the AI answers "
                "(try %d/%d)", job_name, result.get("turn_exit_reason") or result.get("error"), attempt, tries)
            if not wait_until_reachable(agent, job, scheduler, cancel_event):
                logger.warning("Job '%s': the AI stayed out of reach; the run ends as it was", job_name)
                break
            history, message = continuation(result, prompt)
            _clear_interrupt(agent)
            agent.run_conversation = functools.partial(type(agent).run_conversation, agent,
                                                       conversation_history=history)
            try:
                result = orig(agent, message, job, job_id, job_name, task_id, cancel_event, worker_state=worker_state)
            finally:
                try:
                    del agent.run_conversation
                except AttributeError:
                    pass
        return result

    scheduler._run_agent_with_watchdog = _run_agent_with_watchdog
    setattr(scheduler, _INSTALLED, True)
    return True
