"""A routine whose model reply stalls is cut off within its idle limit and picks the SAME turn back up once the AI
can be reached again, keeping the work it already did (tools/overlay/cron/one_routine_stall.py).

Run: <engine python> tools/routine-stall-check.py <engine folder> <work folder>     prints "routine stall ok"
     (CI: tools/routine-stall-check.sh in the fresh-install workflow, against the engine it installed and patched)
The engine is the REAL one: a real AIAgent (platform cron) runs through the scheduler's own
`_run_agent_with_watchdog`, speaking Anthropic's streaming API to a stand-in served here, in a throwaway home.
In both cases the stand-in model:
  call 1  asks for one step ("the upload": a terminal command that appends a line to uploads.log)
  call 2  sends the reply's headers, then nothing at all: a stream that stalls
  then    the connection goes away (the stand-in stops listening: the AI can't be reached) and comes back
  after   it answers "STALL-DONE" when the upload's result is in what it was sent
Case 1, a quiet reply: the stall must be cut off within the idle limit (ONE_ROUTINE_STALL_SECONDS, 3 s here), not
  the engine's own 900 s for a model on this machine (before the fix the routine is still waiting at the deadline).
Case 2, the Mac slept through it (Nov 25 and 27 2026): the session lease lapses during the stalled reply, the engine's
  own lease path stops the turn ("Operation interrupted: waiting for model response"), and the AI is out of reach for
  longer. The routine must wait for it, then run the same turn again (before the fix the routine failed there).
Both: retried only once the stand-in listens again, the retry carries the upload's result, the upload ran once, and
the routine ends ok with the stand-in's answer.
"""

import http.server
import json
import os
import shutil
import socket
import socketserver
import sys
import threading
import time

ENGINE, WORK = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
LIMIT = 3.0  # the routine idle limit under test (seconds)
shutil.rmtree(WORK, ignore_errors=True)
HOME = os.path.join(WORK, "home")
os.makedirs(HOME)
os.makedirs(os.path.join(WORK, "user"))
os.environ.update({
    "HERMES_HOME": HOME, "HOME": os.path.join(WORK, "user"), "ONE_ROUTINE_STALL_SECONDS": str(LIMIT),
    "ONE_ROUTINE_REACH_POLL_SECONDS": "0.5", "HERMES_CRON_TIMEOUT": "600",
})
sys.path.insert(0, ENGINE)
if os.environ.get("ONE_CHECK_SDK"):  # the engine's pinned Anthropic SDK on a fresh engine, after the engine's own packages
    sys.path.append(os.environ["ONE_CHECK_SDK"])
fails = 0


def check(name, ok, detail=""):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name + ("" if ok or not detail else f"  ({detail})"), flush=True)
    fails += 0 if ok else 1


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def message(n, blocks, stop_reason):
    """One Anthropic Messages stream (server-sent events) for ``blocks``."""
    out = [("message_start", {"type": "message_start", "message": {
        "id": f"msg_{n}", "type": "message", "role": "assistant", "model": "claude-stand-in", "content": [],
        "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 1}}})]
    for i, b in enumerate(blocks):
        if b["type"] == "text":
            start, delta = {"type": "text", "text": ""}, {"type": "text_delta", "text": b["text"]}
        else:
            start = {"type": "tool_use", "id": b["id"], "name": b["name"], "input": {}}
            delta = {"type": "input_json_delta", "partial_json": json.dumps(b["input"])}
        out += [("content_block_start", {"type": "content_block_start", "index": i, "content_block": start}),
                ("content_block_delta", {"type": "content_block_delta", "index": i, "delta": delta}),
                ("content_block_stop", {"type": "content_block_stop", "index": i})]
    out += [("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop_reason, "stop_sequence": None},
                               "usage": {"output_tokens": 5}}),
            ("message_stop", {"type": "message_stop"})]
    return "".join(f"event: {k}\ndata: {json.dumps(d)}\n\n" for k, d in out).encode()


class StandIn:
    """The stand-in model for one case: upload step, a stalled reply, an outage of ``down`` seconds, then answers."""

    def __init__(self, uploads, down, on_stall=None):
        self.uploads, self.down, self.on_stall = uploads, down, on_stall
        self.calls, self.events, self.lock, self.stop = [], {}, threading.Lock(), threading.Event()
        self.port, self.server = free_port(), None
        self.up()

    def up(self):
        stand_in = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *a):
                pass

            def do_POST(self):
                stand_in.answer(self)

        class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True
            allow_reuse_address = True

        self.server = Server(("127.0.0.1", self.port), Handler)
        threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True).start()

    def go_down(self):
        """The AI can't be reached: stop listening for ``down`` seconds, then come back on the same port."""
        with self.lock:
            if "GONE" in self.events:
                return
            self.events["GONE"] = time.time()
            self.events.setdefault("DOWN", time.time())
        self.server.shutdown()
        self.server.server_close()
        time.sleep(self.down)
        self.up()
        self.events["UP"] = time.time()

    def answer(self, h):
        body = json.loads(h.rfile.read(int(h.headers.get("Content-Length") or 0)) or b"{}")
        if "DOWN" in self.events and "UP" not in self.events:  # slipped in while it goes down: no answer
            h.close_connection = True
            return
        kind = "turn" if body.get("tools") else "side"  # the routine's own calls carry its tools
        with self.lock:
            self.calls.append((time.time(), kind, body))
            turns = sum(1 for c in self.calls if c[1] == "turn")
        whole = json.dumps(body.get("messages") or [])
        if kind == "side":
            data = message(len(self.calls), [{"type": "text", "text": "Stand-in title"}], "end_turn")
        elif turns == 1:
            data = message(turns, [{"type": "tool_use", "id": "toolu_upload", "name": "terminal",
                                    "input": {"command": f"echo uploaded >> '{self.uploads}'"}}], "tool_use")
        elif "STALLED" not in self.events:
            self.stall(h)
            return
        elif "toolu_upload" in whole:
            data = message(turns, [{"type": "text", "text": "Finished the routine. STALL-DONE"}], "end_turn")
        else:
            data = message(turns, [{"type": "text", "text": "I lost track of the upload. NO-HISTORY"}], "end_turn")
        h.send_response(200)
        h.send_header("Content-Type", "text/event-stream")
        h.send_header("Content-Length", str(len(data)))
        h.end_headers()
        h.wfile.write(data)
        h.wfile.flush()

    def stall(self, h):
        """The reply's headers, then nothing, ever: hold the socket until the engine gives up on it."""
        self.events["STALLED"] = time.time()
        h.send_response(200)
        h.send_header("Content-Type", "text/event-stream")
        h.end_headers()
        h.wfile.flush()
        if self.on_stall:
            self.on_stall(self)
        try:
            while not self.stop.is_set():
                h.connection.settimeout(0.5)
                try:
                    if h.connection.recv(1, socket.MSG_PEEK) == b"":
                        break  # the engine cut it off
                except socket.timeout:
                    continue
                except OSError:
                    break
        finally:
            self.events.setdefault("CUT-OFF", time.time())
            self.events.setdefault("DOWN", time.time())
            threading.Thread(target=self.go_down, daemon=True).start()


# ---- the engine ------------------------------------------------------------------------------------------------------
import cron.scheduler as scheduler  # noqa: E402  (the engine's, with One's overlay hooked in when it is applied)
from agent import turn_facade_lease  # noqa: E402
from hermes_state import SessionDB  # noqa: E402
from run_agent import AIAgent  # noqa: E402

check("One's routine stall overlay is hooked into the engine's scheduler", getattr(scheduler, "_one_routine_stall", False) is True)

# Case 2's "the Mac slept": the lease's own renewal finds its deadline already behind it (what a long sleep does).
SLEPT = threading.Event()
_refresh = turn_facade_lease.DurableTurnLease.refresh_tick


def refresh_tick(self):
    if SLEPT.is_set():
        SLEPT.clear()
        self._authority_deadline = time.time() - 1.0
    return _refresh(self)


turn_facade_lease.DurableTurnLease.refresh_tick = refresh_tick


def routine(case, stand_in, session_db):
    agent = AIAgent(
        model="claude-stand-in", api_key="sk-ant-stand-in", base_url=f"http://127.0.0.1:{stand_in.port}",
        provider="anthropic", api_mode="anthropic_messages", max_iterations=8, enabled_toolsets=["terminal"],
        quiet_mode=True, skip_context_files=True, load_soul_identity=False, skip_memory=True,
        skip_background_review=True, platform="cron", session_id=f"cron_stallcheck_{case}", session_db=session_db,
    )
    agent._session_turn_lease_refresh_interval = 0.3
    job = {"id": f"stallcheck{case}", "name": f"Stall check {case}", "schedule": {"kind": "interval", "minutes": 60}}
    box = {}

    def run():
        try:
            box["result"] = scheduler._run_agent_with_watchdog(
                agent, "Upload the report, then say you're done.", job, job["id"], job["name"], f"task-{case}", None)
        except BaseException as exc:  # noqa: BLE001  (reported below)
            box["error"] = exc

    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    return agent, worker, box


def verify(title, stand_in, agent, worker, box, deadline, cut_within=None):
    print(title, flush=True)
    t0 = time.time()
    worker.join(deadline)
    ev = stand_in.events
    turns = [c for c in stand_in.calls if c[1] == "turn"]
    if worker.is_alive():
        check(f"the routine is done within {deadline:.0f}s", False,
              f"still waiting on the stalled reply after {time.time() - t0:.0f}s; cut off: {'CUT-OFF' in ev}; "
              f"model calls: {len(turns)}; upload ran: {os.path.exists(stand_in.uploads)}")
        stand_in.stop.set()
        try:
            agent.interrupt("routine stall check ran out of time")
        except Exception:
            pass
        return
    result = box.get("result") or {}
    check("the model's reply stalled", "STALLED" in ev)
    if cut_within is not None:
        took = (ev.get("CUT-OFF") or 0) - (ev.get("STALLED") or 0)
        check(f"the stall was cut off within the idle limit ({cut_within:.0f}s, plus 6s slack)",
              "CUT-OFF" in ev and took <= cut_within + 6, f"{took:.1f}s")
    after_up = [c for c in turns if ev.get("UP") and c[0] >= ev["UP"]]
    check("the turn was retried once the AI could be reached again", bool(after_up))
    check("the routine ended ok, not on the stalled reply", "error" not in box and not result.get("failed")
          and result.get("completed") is not False,
          repr(box.get("error"))[:300] if "error" in box else str(result.get("error") or result.get("final_response"))[:300])
    check("the retry carried the work done so far (the upload's result)",
          bool(after_up) and "toolu_upload" in json.dumps(after_up[-1][2].get("messages")))
    if os.environ.get("ONE_CHECK_DEBUG") and after_up:
        for m in after_up[-1][2].get("messages") or []:
            print("      ", m.get("role"), json.dumps(m.get("content"))[:160])
    lines = open(stand_in.uploads).read().splitlines() if os.path.exists(stand_in.uploads) else []
    check("the upload ran once, not again", lines == ["uploaded"], f"{len(lines)} upload(s)")
    check("the routine ended with the model's answer", "STALL-DONE" in str(result.get("final_response") or ""),
          str(result.get("final_response"))[:200])
    stand_in.stop.set()


# Case 1: a reply that goes quiet, and a short outage after it.
one = StandIn(os.path.join(WORK, "uploads-1.log"), down=4.0)
verify("A reply that goes quiet", one, *routine(1, one, None), deadline=60.0, cut_within=LIMIT)

# Case 2: the Mac sleeps through the stalled reply (the lease lapses) and the AI stays out of reach for a while.
def sleep_now(stand_in):
    """The Mac goes to sleep: the lease lapses and the network is gone, both at once."""
    SLEPT.set()
    stand_in.events.setdefault("DOWN", time.time())
    threading.Thread(target=stand_in.go_down, daemon=True).start()


two = StandIn(os.path.join(WORK, "uploads-2.log"), down=8.0, on_stall=sleep_now)
db = SessionDB()
verify("The Mac slept through a stalled reply", two, *routine(2, two, db), deadline=60.0)

print("routine stall ok" if not fails else f"routine stall FAILED ({fails} failed)", flush=True)
os._exit(1 if fails else 0)
