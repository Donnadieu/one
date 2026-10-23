"""One's voice: Kokoro (open source, runs on this Mac). Reads JSON lines {"id","text"} on stdin,
writes a wav per line and answers {"id","path","dur"} on stdout."""
import json, os, sys
import soundfile as sf
from kokoro_onnx import Kokoro

here = sys.argv[1]
out = os.path.join(here, "out"); os.makedirs(out, exist_ok=True)
for f in os.listdir(out):
    try: os.remove(os.path.join(out, f))
    except OSError: pass
k = Kokoro(os.path.join(here, "kokoro-v1.0.onnx"), os.path.join(here, "voices-v1.0.bin"))
voice = sys.argv[2] if len(sys.argv) > 2 else "af_heart"
print(json.dumps({"id": "ready"}), flush=True)
for line in sys.stdin:
    try:
        m = json.loads(line)
        a, sr = k.create(m["text"], voice=voice, speed=1.0, lang="en-us")
        p = os.path.join(out, f"{m['id']}.wav"); sf.write(p, a, sr)
        print(json.dumps({"id": m["id"], "path": p, "dur": len(a) / sr}), flush=True)
    except Exception as e:
        print(json.dumps({"id": m.get("id", "?") if isinstance(m, dict) else "?", "error": str(e)[:200]}), flush=True)
