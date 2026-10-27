"""One's voice for phone chats: the same Kokoro model and voice as on the Mac, written to a file.
Usage: speak_file.py <voice dir> <voice id> <text file> <output file (.ogg = voice message)>"""
import os, sys
import soundfile as sf
from kokoro_onnx import Kokoro

here, voice, src, dst = sys.argv[1:5]
text = open(src, encoding="utf-8").read().strip()
k = Kokoro(os.path.join(here, "kokoro-v1.0.onnx"), os.path.join(here, "voices-v1.0.bin"))
a, sr = k.create(text, voice=voice or "af_heart", speed=1.0, lang="en-us")
if dst.endswith(".ogg"):
    sf.write(dst, a, sr, format="OGG", subtype="OPUS")
else:
    sf.write(dst, a, sr)
