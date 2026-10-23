"""Render the fixed onboarding lines (voice/lines.json) to voice/<key>.mp3 with Kokoro, voice af_heart:
the same free, on-device voice One uses live, so setup and replies sound like one person.

Usage: python3 tools/render_voice.py <dir with kokoro-v1.0.onnx and voices-v1.0.bin>   (needs kokoro-onnx, soundfile, ffmpeg)
"""
import json, os, subprocess, sys
import soundfile as sf
from kokoro_onnx import Kokoro
here = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'voice')
cfg = json.load(open(os.path.join(here, 'lines.json')))
m = sys.argv[1]
k = Kokoro(os.path.join(m, 'kokoro-v1.0.onnx'), os.path.join(m, 'voices-v1.0.bin'))
for name, text in cfg['lines'].items():
    a, sr = k.create(text, voice=cfg.get('voice', 'af_heart'), speed=1.0, lang='en-us')
    wav = os.path.join(here, f'{name}.wav'); sf.write(wav, a, sr)
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', wav, '-b:a', '96k', os.path.join(here, f'{name}.mp3')], check=True)
    os.remove(wav); print('rendered', name)
