#!/usr/bin/python3
"""A stand-in for One's engine (`hermes acp`) used by `make helpers-check` (tools/helpers-check.sh).

It speaks the same ACP JSON-RPC over stdin/stdout as the real engine, costs nothing and answers in seconds.
Every helper job the check sends contains `STRESSJOB <id> secs=<n>`: the stand-in takes a step, says it is
working (partial words, like a real helper mid-job), waits n seconds and only then ends with `DONE <id>`.
`ask=1` after secs ends the job with a [choices: …] line (needs their yes). `STRESSCLOSE <title>` answers with
a [close-helper: <title>] line. A message to the assistant containing `STRESSSPAWN <n> secs=<a,b,...>` answers with n helper lines, the
first one written twice, and the whole reply delivered twice (how the real engine doubled a reply on
Oct 27, 2026). Everything it does is appended to $ONE_FAKE_ENGINE_LOG (one JSON object per line), so the
check can count how many times each job really ran and whether two copies ever overlapped.
Sessions are remembered in $ONE_FAKE_ENGINE_LOG.sessions, so a restarted stand-in can reopen them.
"""
import json
import os
import re
import sys
import threading
import time
import uuid

LOG = os.environ.get("ONE_FAKE_ENGINE_LOG", os.path.join(os.getcwd(), "fake-engine.jsonl"))
SESS = LOG + ".sessions"
out_lock = threading.Lock()
log_lock = threading.Lock()
cancelled = set()
c_lock = threading.Lock()


def log(**k):
    k["t"] = time.time()
    k["pid"] = os.getpid()
    with log_lock, open(LOG, "a") as f:
        f.write(json.dumps(k) + "\n")


def send(obj):
    data = json.dumps(obj) + "\n"
    with out_lock:
        try:
            sys.stdout.write(data)
            sys.stdout.flush()
        except BrokenPipeError:
            os._exit(0)


def known():
    try:
        with open(SESS) as f:
            return set(l.strip() for l in f if l.strip())
    except OSError:
        return set()


def chunk(sid, text):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {
        "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})


def tool(sid, title):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {
        "sessionUpdate": "tool_call", "toolCallId": uuid.uuid4().hex, "title": title}}})


def is_cancelled(sid):
    with c_lock:
        return sid in cancelled


def prompt(rid, sid, text):
    with c_lock:
        cancelled.discard(sid)
    if text.startswith("/steer "):
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    m = re.search(r"STRESSJOB (\S+) secs=(\d+(?:\.\d+)?)( ask=1)?", text)
    if m:
        job, secs, ask = m.group(1), float(m.group(2)), bool(m.group(3))
        resumed = "interrupted by a restart" in text or "were interrupted" in text
        log(ev="start", job=job, sid=sid, resumed=resumed)
        tool(sid, "terminal: sleep %g" % secs)
        chunk(sid, "Working on %s, halfway there.\n" % job)  # words before the job is done
        end = time.time() + secs
        while time.time() < end:
            if is_cancelled(sid):
                log(ev="cancelled", job=job, sid=sid)
                send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
                return
            time.sleep(0.1)
        chunk(sid, "DONE %s" % job + ("\nGo ahead?\n[choices: Yes, go ahead | Not now]" if ask else ""))  # ask=1: needs their yes
        log(ev="end", job=job, sid=sid)
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    m = re.search(r"STRESSSPAWN (\d+) prefix=(\S+) secs=([\d.,]+)", text)
    if m:
        n, prefix, secs = int(m.group(1)), m.group(2), [s for s in m.group(3).split(",") if s]
        lines = ["[helper: %s%02d | STRESSJOB %s%02d secs=%s]" % (prefix, i, prefix, i, secs[(i - 1) % len(secs)]) for i in range(1, n + 1)]
        lines.insert(1, lines[0])  # the same helper line twice in one reply
        reply = "Sending %d helpers now.\n" % n + "\n".join(lines) + "\n"
        log(ev="spawn-reply", n=n, sid=sid)
        chunk(sid, reply)
        chunk(sid, reply)  # and the whole reply delivered twice
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    m = re.search(r"STRESSCLOSE ([^\n]+)", text)
    if m:  # asked to close a helper: the line the assistant writes for it
        log(ev="close-reply", sid=sid)
        chunk(sid, "Closed %s.\n[close-helper: %s]\n" % (m.group(1).strip(), m.group(1).strip()))
        send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    log(ev="main", sid=sid, text=text[:80])
    chunk(sid, "OK.")
    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


def main():
    log(ev="engine-up")
    for line in sys.stdin:
        try:
            m = json.loads(line)
        except ValueError:
            continue
        method, rid, p = m.get("method"), m.get("id"), m.get("params") or {}
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": rid, "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}}})
        elif method == "session/new":
            sid = "fake-" + uuid.uuid4().hex[:12]
            with log_lock, open(SESS, "a") as f:
                f.write(sid + "\n")
            send({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": sid}})
        elif method == "session/load":
            ok = p.get("sessionId") in known()
            send({"jsonrpc": "2.0", "id": rid, "result": {}} if ok else {"jsonrpc": "2.0", "id": rid, "error": {"code": -32002, "message": "no such session"}})
        elif method == "session/prompt":
            text = "".join(b.get("text", "") for b in p.get("prompt", []) if b.get("type") == "text")
            threading.Thread(target=prompt, args=(rid, p.get("sessionId"), text), daemon=True).start()
        elif method == "session/cancel":
            with c_lock:
                cancelled.add(p.get("sessionId"))
        elif rid is not None and method:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "not in the stand-in"}})
    log(ev="engine-eof")
    os._exit(0)  # One went away: so does the engine (its turns end with it)


if __name__ == "__main__":
    main()
