"""Standing goals (/goal) through One's own connection to the REAL engine, with a stand-in model.

Run by tools/goal-engine-check.sh (CI: the fresh-install workflow, against the engine it just installed and patched).
  python3 tools/goal-engine-check.py <hermes binary> <work folder>      prints "goal engine ok" when every case passes
The engine runs its own goal loop (judge after every turn, turn budget, pause/resume) in a throwaway home. The model
and the judge are a stand-in served here (an OpenAI-style endpoint), so the check costs nothing and needs no sign-in:
the agent counts one number per turn, says DONE-MARK when it reaches the goal's number, and asks for a yes (ASK-MARK
with a [choices: ...] line) when the goal says to send something; the judge says done on DONE-MARK, blocked on
ASK-MARK, else continue. What is checked is One's side: the prompt stays open for all of a goal's turns and returns
once it ends, the budget, Stop, pause/resume, a helper's goal, a send that waits for a yes, the notes and the yes rule.
"""

import http.server
import json
import os
import re
import shutil
import socketserver
import subprocess
import sys
import threading
import time

HERMES, WORK = sys.argv[1], os.path.abspath(sys.argv[2])
HOME = os.path.join(WORK, "home")
LAUNCH = os.environ.get("ONE_GOAL_LAUNCH", "acp").split()  # dev: "--run-module one_goaltest_acp"
shutil.rmtree(WORK, ignore_errors=True)
os.makedirs(HOME)
fails = 0


def check(name, ok, detail=""):
    global fails
    print(("  ✓ " if ok else "  ✗ ") + name + ("" if ok or not detail else f"  ({detail})"), flush=True)
    fails += 0 if ok else 1


# ---- the stand-in model ---------------------------------------------------------------------------------------
REQUESTS = []  # (time, kind, last user text, whole request text)
LOCK = threading.Lock()


def answer(body):
    msgs = body.get("messages") or []
    text = lambda m: m.get("content") if isinstance(m.get("content"), str) else json.dumps(m.get("content"))
    system = " ".join(text(m) for m in msgs if m.get("role") == "system")
    whole = "\n".join(text(m) or "" for m in msgs)
    users = [text(m) or "" for m in msgs if m.get("role") == "user"]
    last = users[-1] if users else ""
    if "strict judge" in system.lower():
        verdict = "done" if "DONE-MARK" in last else "blocked" if "ASK-MARK" in last else "continue"
        with LOCK:
            REQUESTS.append((time.time(), "judge", last, whole))
        return json.dumps({"verdict": verdict, "reason": f"stand-in judge: {verdict}"})
    goals = re.findall(r"Count to (\d+)", whole)
    if not body.get("tools") or (not goals and "Email the note" not in whole):
        return "OK"  # titles and other side requests (a turn of the agent always carries its tools)
    with LOCK:
        REQUESTS.append((time.time(), "turn", last, whole))
    if "slowly" in whole:
        time.sleep(1.5)
    if "Email the note" in whole and not goals:
        return "The note is ready. Sending it needs your yes. ASK-MARK\n\n[choices: Yes, send it | Not now]"
    said = [m for m in msgs if m.get("role") == "assistant" and re.fullmatch(r"\s*\d+( DONE-MARK)?\s*", text(m) or "")]
    n, target = len(said) + 1, int(goals[-1])
    return f"{n} DONE-MARK" if n >= target else str(n)


class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        self.reply({"object": "list", "data": [{"id": "stand-in", "object": "model", "context_length": 200000}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        words = answer(body)
        usage = {"prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12}
        if not body.get("stream"):
            return self.reply({"id": "x", "object": "chat.completion", "created": int(time.time()), "model": "stand-in",
                               "choices": [{"index": 0, "message": {"role": "assistant", "content": words},
                                            "finish_reason": "stop"}], "usage": usage})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        base = {"id": "x", "object": "chat.completion.chunk", "created": int(time.time()), "model": "stand-in"}
        for piece in [{"role": "assistant", "content": words}, {}]:
            chunk = dict(base, choices=[{"index": 0, "delta": piece, "finish_reason": None if piece else "stop"}])
            if not piece:
                chunk["usage"] = usage
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")
        self.wfile.write(b"data: [DONE]\n\n")

    def reply(self, obj):
        data = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


server = Server(("127.0.0.1", 0), Model)
threading.Thread(target=server.serve_forever, daemon=True).start()
PORT = server.server_address[1]

with open(os.path.join(HOME, "config.yaml"), "w") as f:
    f.write(f"""model:
  default: stand-in
  provider: custom
  base_url: http://127.0.0.1:{PORT}/v1
  api_key: stand-in
  context_length: 200000
goals:
  max_turns: 4
auxiliary:
  goal_judge:
    provider: custom
    base_url: http://127.0.0.1:{PORT}/v1
    api_key: stand-in
    model: stand-in
""")

# ---- One's side of the connection (what Engine.swift does) -----------------------------------------------------
env = {k: v for k, v in os.environ.items() if not k.startswith("HERMES_")}
env.update(HERMES_HOME=HOME, HERMES_YOLO_MODE="1", PYTHONUNBUFFERED="1", NO_COLOR="1", TERM="dumb",
           HERMES_GATEWAY_LOCK_DIR=os.path.join(HOME, "gateway-locks"), ONE_GOAL_IDLE="25")
if os.environ.get("ONE_RUNTIME_DIR"):
    env["HERMES_RUNTIME_DIR"] = os.environ["ONE_RUNTIME_DIR"]
engine = subprocess.Popen([HERMES] + LAUNCH, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=open(os.path.join(WORK, "engine.log"), "w"), env=env, cwd=WORK)
waiting, texts, nid = {}, {}, [0]


def reader():
    for line in engine.stdout:
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if "id" in m and "method" not in m:
            ev = waiting.pop(m["id"], None)
            if ev:
                ev[1] = m
                ev[0].set()
        elif m.get("method") == "session/update":
            u = m["params"]["update"]
            if u.get("sessionUpdate") == "agent_message_chunk":
                sid = m["params"]["sessionId"]
                texts[sid] = texts.get(sid, "") + (u.get("content") or {}).get("text", "")
        elif "id" in m:  # a permission ask: One allows (its own guardrails are the folder lock and the asks)
            opts = (m.get("params") or {}).get("options") or []
            ok = next((o["optionId"] for o in opts if o["optionId"].startswith("allow")), None)
            send({"jsonrpc": "2.0", "id": m["id"], "result": {"outcome": {"outcome": "selected", "optionId": ok} if ok else {"outcome": "cancelled"}}})


threading.Thread(target=reader, daemon=True).start()


def send(o):
    engine.stdin.write((json.dumps(o) + "\n").encode())
    engine.stdin.flush()


def call(method, params, timeout=240):
    nid[0] += 1
    ev = [threading.Event(), None]
    waiting[nid[0]] = ev
    send({"jsonrpc": "2.0", "id": nid[0], "method": method, "params": params})
    ev[0].wait(timeout)
    return ev[1] or {"error": "timed out"}


def prompt(sid, text, timeout=240):
    r = call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}]}, timeout)
    return (r.get("result") or {}).get("stopReason") or f"error: {r.get('error')}"


def state(sid):
    import sqlite3
    try:
        c = sqlite3.connect(f"file:{HOME}/state.db?mode=ro", uri=True)
        row = c.execute("select value from state_meta where key=?", ("goal:" + sid,)).fetchone()
        c.close()
        return json.loads(row[0]) if row else {}
    except Exception:
        return {}


def turns_since(t0):
    with LOCK:
        return [r for r in REQUESTS if r[0] >= t0 and r[1] == "turn"]


def judged_since(t0):
    with LOCK:
        return [r for r in REQUESTS if r[0] >= t0 and r[1] == "judge"]


def new_session():
    for _ in range(30):
        r = call("session/new", {"cwd": WORK, "mcpServers": []}, 120)
        if "result" in r:
            return r["result"]["sessionId"]
        time.sleep(3)
    print("could not open a conversation:", r)
    sys.exit(1)


NOTE = "\n\n(One app note, not from the user: PROBE-NOTE. Rules for this chat.)"
call("initialize", {"protocolVersion": 1, "clientCapabilities": {}}, 120)

print("A goal is set, works turn after turn and the prompt ends with it", flush=True)
a = new_session()
t0 = time.time()
stop = prompt(a, "/goal Count to 3, one number per turn." + NOTE)
s = state(a)
turns = turns_since(t0)
check("the prompt returned only once the goal was done", stop == "end_turn" and s.get("status") == "done", f"{stop}, {s.get('status')}")
check("three turns, judged after each", len(turns) == 3 and s.get("turns_used") == 3, f"{len(turns)} turns, {s.get('turns_used')} judged")
check("every turn's words reached One, each on its own paragraph", re.search(r"1\s*\n\n2\s*\n\n3 DONE-MARK", texts.get(a, "")) is not None, repr(texts.get(a, "")[-120:]))
check("One's notes went with the first turn, not into the goal", "PROBE-NOTE" not in s.get("goal", "") and "PROBE-NOTE" in turns[0][2] if turns else False)
check("the yes rule went with the first turn", bool(turns) and "STANDING GOAL" in turns[0][2])
check("the yes rule is in the goal's contract the judge reads", "their yes" in json.dumps(s.get("contract") or {}) and any("their yes" in j[3] for j in judged_since(t0)))
time.sleep(3)
check("nothing ran after it was done", len(turns_since(t0)) == 3)

print("The turn budget", flush=True)
b = new_session()
t0 = time.time()
stop = prompt(b, "/goal Count to 20, one number per turn." + NOTE)
s = state(b)
check("the prompt returned when the budget (4 turns here) was used", stop == "end_turn" and s.get("status") == "paused" and "budget" in (s.get("paused_reason") or ""), f"{stop}, {s.get('status')}, {s.get('paused_reason')}")
check("exactly 4 turns", len(turns_since(t0)) == 4, str(len(turns_since(t0))))
time.sleep(3)
check("nothing ran after the budget", len(turns_since(t0)) == 4)

print("Pause and resume", flush=True)
t1 = time.time()
stop = prompt(b, "/goal resume" + NOTE)
s = state(b)
check("resume works on it again and the prompt holds until it stops", stop == "end_turn" and len(turns_since(t1)) >= 2 and not s.get("status") == "active", f"{stop}, {len(turns_since(t1))} turns, {s.get('status')}")
t2 = time.time()
stop = prompt(b, "/goal pause")
check("/goal pause is answered at once, not held", stop == "end_turn" and time.time() - t2 < 10 and not turns_since(t2))

print("Stop (One's Stop button) ends a goal mid-way", flush=True)
c = new_session()
t0 = time.time()
threading.Timer(4.5, lambda: send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": c}})).start()
stop = prompt(c, "/goal Count to 9, slowly, one number per turn." + NOTE)
s = state(c)
check("the prompt ended as stopped", stop == "cancelled", stop)
check("the goal is paused, not active", s.get("status") == "paused", str(s.get("status")))
n = len(turns_since(t0))
time.sleep(6)
check("no turn started after Stop", len(turns_since(t0)) <= n, f"{n} then {len(turns_since(t0))}")
check("it stopped well before the end", n < 6, str(n))

print("Stop before the first turn ends", flush=True)
d = new_session()
threading.Timer(0.6, lambda: send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": d}})).start()
t0 = time.time()
stop = prompt(d, "/goal Count to 9, slowly, one number per turn." + NOTE)
time.sleep(5)
check("stopped, and the goal can't carry on by itself", stop == "cancelled" and state(d).get("status") == "paused" and len(turns_since(t0)) <= 1,
      f"{stop}, {state(d).get('status')}, {len(turns_since(t0))}")

print("A helper with a goal (its own conversation, One's brief as a note)", flush=True)
h = new_session()
brief = ("\n\n(One app note, not from the user: you are working on this as a STANDING GOAL. Your brief: You're one of Ava's "
         "helpers. The job: Count to 2.\n\n(One app note, not from the user: You are a helper working on one job.))")
t0 = time.time()
stop = prompt(h, "/goal Count to 2, one number per turn." + brief)
s = state(h)
check("the helper's goal ran to done in its own conversation", stop == "end_turn" and s.get("status") == "done" and len(turns_since(t0)) == 2, f"{stop}, {s.get('status')}")
check("its goal is just the job, its brief went with the first turn", s.get("goal") == "Count to 2, one number per turn." and "Ava's helpers" in turns_since(t0)[0][2])

print("A send still waits for a yes", flush=True)
e = new_session()
t0 = time.time()
stop = prompt(e, "/goal Email the note to bob@example.com." + NOTE)
s = state(e)
check("it stopped at the ask, after one turn", stop == "end_turn" and len(turns_since(t0)) == 1, f"{stop}, {len(turns_since(t0))}")
check("the goal is paused on them, not carried on", s.get("status") == "paused" and s.get("last_verdict") == "blocked", f"{s.get('status')}, {s.get('last_verdict')}")
check("the ask reached One with its choices", "[choices: Yes, send it | Not now]" in texts.get(e, ""))
time.sleep(4)
check("no next turn took the step", len(turns_since(t0)) == 1)

engine.terminate()
try:
    engine.wait(10)
except Exception:
    engine.kill()
server.shutdown()
print("goal engine ok" if fails == 0 else f"goal engine: {fails} failed")
sys.exit(1 if fails else 0)
