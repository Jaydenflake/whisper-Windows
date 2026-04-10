#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$ROOT/bin/whisper-dictation-ctl"
OUT_DIR="${1:-$ROOT/benchmark-output/$(date +%Y%m%d-%H%M%S)}"
ITERATIONS="${ITERATIONS:-12}"
CONTROL_HOST="${CONTROL_HOST:-127.0.0.1}"
CONTROL_PORT="${CONTROL_PORT:-44123}"
LAUNCH_AGENT_LABEL="${LAUNCH_AGENT_LABEL:-com.hansenhomeai.whisper-dictation}"
LAUNCH_AGENT_PATH="${HOME}/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"
LAUNCH_AGENT_WAS_PRESENT=0
mkdir -p "$OUT_DIR"

cleanup() {
  if [[ -n "${LOAD_PID:-}" ]]; then
    kill "$LOAD_PID" >/dev/null 2>&1 || true
    wait "$LOAD_PID" 2>/dev/null || true
  fi
  if [[ "$LAUNCH_AGENT_WAS_PRESENT" == "1" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1 || true
    launchctl kickstart -k "gui/$(id -u)/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

wait_for_daemon_down() {
  python3 - "$CONTROL_HOST" "$CONTROL_PORT" <<'PY'
import socket, sys, time

host = sys.argv[1]
port = int(sys.argv[2])
deadline = time.time() + 5.0

while time.time() < deadline:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(0.05)
    try:
        sock.connect((host, port))
    except OSError:
        sys.exit(0)
    finally:
        sock.close()
    time.sleep(0.02)

raise SystemExit("daemon port never closed after shutdown")
PY
}

kill_stray_daemons() {
  pkill -f '/whisper-dictation-daemon --config ' >/dev/null 2>&1 || true
}

run_python_summary() {
  local mode="$1"
  local infile="$2"
  local outfile="$3"
  python3 - "$mode" "$infile" "$outfile" <<'PY'
import json, math, statistics, sys
mode, infile, outfile = sys.argv[1], sys.argv[2], sys.argv[3]
rows = []
with open(infile, "r", encoding="utf-8") as fh:
    for line in fh:
        rows.append(json.loads(line))

def pct(values, p):
    ordered = sorted(values)
    if not ordered:
        return None
    idx = math.ceil((p / 100.0) * len(ordered)) - 1
    idx = max(0, min(idx, len(ordered) - 1))
    return ordered[idx]

observed = [row["clientObservedMilliseconds"] for row in rows]
cold = [row.get("coldBootMilliseconds") for row in rows if row.get("coldBootMilliseconds") is not None]
engine = [
    row.get("status", {}).get("engineStartupMilliseconds")
    for row in rows
    if row.get("status", {}).get("engineStartupMilliseconds") is not None
]
prebuffer = [
    row.get("status", {}).get("prebufferAvailableMilliseconds")
    for row in rows
    if row.get("status", {}).get("prebufferAvailableMilliseconds") is not None
]
if mode.startswith("cold-") and len(cold) != len(rows):
    raise SystemExit(f"{mode} expected {len(rows)} true cold starts but saw {len(cold)}")
summary = {
    "mode": mode,
    "iterations": len(rows),
    "coldBootSamples": len(cold),
    "clientObservedMs": {
        "min": min(observed),
        "median": statistics.median(observed),
        "p95": pct(observed, 95),
        "max": max(observed),
    },
    "coldBootMs": {
        "min": min(cold) if cold else None,
        "median": statistics.median(cold) if cold else None,
        "p95": pct(cold, 95) if cold else None,
        "max": max(cold) if cold else None,
    },
    "engineStartupMs": {
        "min": min(engine) if engine else None,
        "median": statistics.median(engine) if engine else None,
        "p95": pct(engine, 95) if engine else None,
        "max": max(engine) if engine else None,
    },
    "captureReadyMs": {
        "min": min(engine) if engine else None,
        "median": statistics.median(engine) if engine else None,
        "p95": pct(engine, 95) if engine else None,
        "max": max(engine) if engine else None,
    },
    "prebufferAvailableMs": {
        "min": min(prebuffer) if prebuffer else None,
        "median": statistics.median(prebuffer) if prebuffer else None,
        "p95": pct(prebuffer, 95) if prebuffer else None,
        "max": max(prebuffer) if prebuffer else None,
    },
}
with open(outfile, "w", encoding="utf-8") as fh:
    json.dump(summary, fh, indent=2)
print(json.dumps(summary, indent=2))
PY
}

run_mode() {
  local mode="$1"
  local load="$2"
  local out_file="$OUT_DIR/${mode}.ndjson"
  : > "$out_file"

  if [[ "$mode" == cold-* && -f "$LAUNCH_AGENT_PATH" ]]; then
    LAUNCH_AGENT_WAS_PRESENT=1
    launchctl bootout "gui/$(id -u)/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
    launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1 || true
    kill_stray_daemons
    wait_for_daemon_down
  fi

  if [[ "$mode" == warm-* ]]; then
    "$CTL" warmup >/dev/null
    sleep 0.25
  fi

  if [[ "$load" == "load" ]]; then
    python3 "$ROOT/scripts/cpu-stress.py" --seconds 120 --workers "$(python3 - <<'PY'
import os
print(max(1, (os.cpu_count() or 2) - 1))
PY
)" &
    LOAD_PID=$!
    sleep 0.3
  else
    LOAD_PID=""
  fi

for _ in $(seq 1 "$ITERATIONS"); do
    if [[ "$mode" == cold-* ]]; then
      "$CTL" shutdown >/dev/null 2>&1 || true
      kill_stray_daemons
      wait_for_daemon_down
    fi

    start_json="$("$CTL" start)"
    echo "$start_json" >> "$out_file"
    "$CTL" cancel >/dev/null 2>&1 || true
    sleep 0.15
done

  if [[ -n "${LOAD_PID:-}" ]]; then
    kill "$LOAD_PID" >/dev/null 2>&1 || true
    wait "$LOAD_PID" 2>/dev/null || true
    LOAD_PID=""
  fi

  run_python_summary "$mode" "$out_file" "$OUT_DIR/${mode}-summary.json"
}

run_mode "warm-idle" "idle"
run_mode "cold-idle" "idle"
run_mode "warm-load" "load"
run_mode "cold-load" "load"

echo "Benchmark output written to $OUT_DIR"
