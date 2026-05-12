#!/usr/bin/env bash

set -euo pipefail

ROOT="${WHISPER_CPP_ROOT:-$HOME/MyProjects/whisper.cpp}"
FFMPEG="${FFMPEG:-$(command -v ffmpeg || true)}"
WHISPER_CLI="${WHISPER_CLI_BINARY:-$ROOT/build/bin/whisper-cli}"
WHISPER_SERVER="${WHISPER_SERVER_BINARY:-$ROOT/build/bin/whisper-server}"
MODEL="${WHISPER_MODEL_PATH:-$ROOT/models/ggml-small.en.bin}"
PORT="${PORT:-8177}"
OUT_DIR="${1:-$(pwd)/benchmark-output}"

[[ -x "$FFMPEG" ]] || { echo "ffmpeg not found. Set FFMPEG=/absolute/path/to/ffmpeg." >&2; exit 1; }
[[ -x "$WHISPER_CLI" ]] || { echo "whisper-cli not found. Set WHISPER_CPP_ROOT or WHISPER_CLI_BINARY." >&2; exit 1; }
[[ -x "$WHISPER_SERVER" ]] || { echo "whisper-server not found. Set WHISPER_CPP_ROOT or WHISPER_SERVER_BINARY." >&2; exit 1; }
[[ -f "$MODEL" ]] || { echo "model not found. Set WHISPER_MODEL_PATH." >&2; exit 1; }

mkdir -p "$OUT_DIR"

echo "Using output directory: $OUT_DIR"

echo
echo "== Device enumeration =="
for i in 1 2 3; do
  echo "Run $i"
  /usr/bin/time -lp "$FFMPEG" -f avfoundation -list_devices true -i '' \
    >"$OUT_DIR/ffmpeg-devices-$i.log" 2>&1 || true
  tail -n 20 "$OUT_DIR/ffmpeg-devices-$i.log"
done

echo
echo "== Generate test WAV =="
"$FFMPEG" -f lavfi -i anullsrc=r=16000:cl=mono -t 2 -ac 1 -ar 16000 -c:a pcm_s16le -y \
  "$OUT_DIR/whisper-silence.wav" >"$OUT_DIR/generate-test-wav.log" 2>&1
ls -lh "$OUT_DIR/whisper-silence.wav"

echo
echo "== Fresh whisper-cli timings =="
for i in 1 2 3; do
  echo "Run $i"
  /usr/bin/time -lp "$WHISPER_CLI" \
    -m "$MODEL" \
    -f "$OUT_DIR/whisper-silence.wav" \
    --output-txt \
    --output-file "$OUT_DIR/whisper-cli-$i" \
    >"$OUT_DIR/whisper-cli-$i.log" 2>&1
  tail -n 30 "$OUT_DIR/whisper-cli-$i.log"
done

echo
echo "== Resident whisper-server timings =="
"$WHISPER_SERVER" -m "$MODEL" --host 127.0.0.1 --port "$PORT" \
  >"$OUT_DIR/whisper-server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

python3 - <<PY
import time
import urllib.request

port = int("${PORT}")
start = time.time()
ready = None

for _ in range(3000):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/", timeout=0.2) as r:
            if r.status == 200:
                ready = time.time()
                break
    except Exception:
        pass
    time.sleep(0.01)

if ready is None:
    raise SystemExit("server did not become ready")

print(f"server_ready_ms={(ready - start) * 1000:.1f}")
PY

for i in 1 2 3; do
  echo "Request $i"
  /usr/bin/time -lp curl -sS "http://127.0.0.1:${PORT}/inference" \
    -H "Content-Type: multipart/form-data" \
    -F "file=@$OUT_DIR/whisper-silence.wav" \
    -F "response_format=json" \
    >"$OUT_DIR/whisper-server-$i.json" 2>"$OUT_DIR/whisper-server-$i.time"
  cat "$OUT_DIR/whisper-server-$i.time"
  cat "$OUT_DIR/whisper-server-$i.json"
  echo
done
