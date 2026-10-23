#!/bin/bash
# Sets up One's voice (Kokoro) next to One's engine. Usage: install_voice.sh <support dir>
set -e
S="$1"; V="$S/voice"; T="$S/hermes/tools"
UV=$(ls -d "$T"/uv-*/uv 2>/dev/null | head -1); PY=$(ls -d "$T"/python-3*/bin/python3 2>/dev/null | head -1)
[ -x "$UV" ] && [ -x "$PY" ] || { echo "✗ engine tools missing"; exit 1; }
mkdir -p "$V"
echo "→ Getting my voice ready"
[ -x "$V/venv/bin/python" ] || "$UV" venv -q -p "$PY" "$V/venv"
VIRTUAL_ENV="$V/venv" "$UV" pip install -q kokoro-onnx soundfile
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  [ -s "$V/$f" ] || curl -fsSL -o "$V/$f.part" "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/$f" && mv -f "$V/$f.part" "$V/$f" 2>/dev/null || true
done
[ -s "$V/kokoro-v1.0.onnx" ] && [ -s "$V/voices-v1.0.bin" ] || { echo "✗ voice download failed"; exit 1; }
"$V/venv/bin/python" -I -c "import kokoro_onnx, soundfile" && touch "$V/.ready" && echo "✓ Voice ready"
