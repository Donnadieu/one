"""Render the onboarding lines to voice/<key>.mp3 with ElevenLabs.

Usage: ELEVENLABS_API_KEY=... python3 tools/render_voice.py [--force]
Only lines whose text changed (or are missing) are rendered, to save credits.
"""
import hashlib, json, os, sys, urllib.request

here = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'voice')
cfg = json.load(open(os.path.join(here, 'lines.json')))
key = os.environ['ELEVENLABS_API_KEY']
stamp_path = os.path.join(here, '.rendered.json')
stamps = json.load(open(stamp_path)) if os.path.exists(stamp_path) else {}
force = '--force' in sys.argv
chars = 0
for name, text in cfg['lines'].items():
    sig = hashlib.sha1(f"{cfg['voice_id']}|{text}".encode()).hexdigest()
    out = os.path.join(here, f'{name}.mp3')
    if not force and stamps.get(name) == sig and os.path.exists(out):
        continue
    req = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{cfg['voice_id']}",
        data=json.dumps({'text': text, 'model_id': cfg['model_id'],
                         'voice_settings': {'stability': 0.55, 'similarity_boost': 0.75, 'style': 0.15}}).encode(),
        headers={'xi-api-key': key, 'Content-Type': 'application/json', 'Accept': 'audio/mpeg'})
    with urllib.request.urlopen(req, timeout=60) as r:
        open(out, 'wb').write(r.read())
    stamps[name] = sig
    chars += len(text)
    print('rendered', name)
json.dump(stamps, open(stamp_path, 'w'), indent=1)
print('characters used:', chars)
