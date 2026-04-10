#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$ROOT/bin/whisper-dictation-ctl"
OUT_DIR="${1:-$ROOT/benchmark-output/pipeline-$(date +%Y%m%d-%H%M%S)}"
COUNT="${COUNT:-5}"
LOAD="${LOAD:-0}"
WORKERS="${WORKERS:-$(python3 - <<'PY'
import os
print(max(1, (os.cpu_count() or 2) - 1))
PY
)}"
mkdir -p "$OUT_DIR"

cleanup() {
  if [[ -n "${LOAD_PID:-}" ]]; then
    kill "$LOAD_PID" >/dev/null 2>&1 || true
    wait "$LOAD_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

"$CTL" warmup >/dev/null

if [[ "$LOAD" == "1" ]]; then
  python3 "$ROOT/scripts/cpu-stress.py" --seconds 240 --workers "$WORKERS" &
  LOAD_PID=$!
  sleep 0.3
fi

for i in $(seq 1 "$COUNT"); do
  "$CTL" start > "$OUT_DIR/start-$i.json"
  sleep 0.20
  "$CTL" stop > "$OUT_DIR/stop-$i.json"
  sleep 0.10
done

deadline=$((SECONDS + 90))
found=0
while [[ $SECONDS -lt $deadline && $found -lt $COUNT ]]; do
  result_json="$("$CTL" next-result)"
  echo "$result_json" >> "$OUT_DIR/results.ndjson"
  available="$(python3 -c 'import json, sys; payload=json.loads(sys.argv[1]); print("yes" if payload.get("resultAvailable") else "no")' "$result_json")"
  if [[ "$available" == "yes" ]]; then
    found=$((found + 1))
  fi
  sleep 0.25
done

python3 - "$OUT_DIR/results.ndjson" "$COUNT" <<'PY'
import json, statistics, sys
path, expected = sys.argv[1], int(sys.argv[2])
seen = []
transcription_ms = []
queue_wait_ms = []
modes = {}
failed = []
with open(path, "r", encoding="utf-8") as fh:
    for line in fh:
        payload = json.loads(line)
        if payload.get("resultAvailable") and payload.get("result"):
            result = payload["result"]
            seen.append(result["sessionId"])
            metrics = result.get("metrics", {})
            mode = metrics.get("transcriptionMode") or "unknown"
            modes[mode] = modes.get(mode, 0) + 1
            if metrics.get("transcriptionMilliseconds") is not None:
                transcription_ms.append(metrics["transcriptionMilliseconds"])
            if metrics.get("queueWaitMilliseconds") is not None:
                queue_wait_ms.append(metrics["queueWaitMilliseconds"])
            if mode == "failed":
                failed.append(result["sessionId"])
unique = sorted(set(seen))

def pct(values, p):
    if not values:
        return None
    ordered = sorted(values)
    idx = max(0, min(len(ordered) - 1, int((p / 100.0) * len(ordered) + 0.999999) - 1))
    return ordered[idx]

summary = {
    "expected": expected,
    "received": len(unique),
    "sessionIds": unique,
    "transcriptionModeCounts": modes,
    "transcriptionMilliseconds": {
        "min": min(transcription_ms) if transcription_ms else None,
        "median": statistics.median(transcription_ms) if transcription_ms else None,
        "p95": pct(transcription_ms, 95),
        "max": max(transcription_ms) if transcription_ms else None,
    },
    "queueWaitMilliseconds": {
        "min": min(queue_wait_ms) if queue_wait_ms else None,
        "median": statistics.median(queue_wait_ms) if queue_wait_ms else None,
        "p95": pct(queue_wait_ms, 95),
        "max": max(queue_wait_ms) if queue_wait_ms else None,
    },
    "failedSessions": failed,
}
print(json.dumps(summary, indent=2))
with open(path.replace("results.ndjson", "summary.json"), "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2)

if len(unique) != expected or failed:
    raise SystemExit(1)
PY

echo "Pipeline benchmark output written to $OUT_DIR"
