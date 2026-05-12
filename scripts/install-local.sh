#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="${HOME}"
PREFERRED_INPUT_DEVICE_EXPLICIT="${PREFERRED_INPUT_DEVICE+x}"
ENFORCE_PREFERRED_INPUT_DEVICE_EXPLICIT="${ENFORCE_PREFERRED_INPUT_DEVICE+x}"
APP_SUPPORT_DIR="$HOME_DIR/Library/Application Support/WhisperDictation"
CACHE_DIR="${CACHE_DIR:-$HOME_DIR/Library/Caches/WhisperDictation}"
LOG_DIR="${LOG_DIR:-$HOME_DIR/Library/Logs/WhisperDictation}"
SALVAGE_DIR="${SALVAGE_DIR:-$HOME_DIR/Documents/WhisperSalvage}"
CONFIG_PATH="$APP_SUPPORT_DIR/config.json"
HSM_TARGET="$HOME_DIR/.hammerspoon/init.lua"
HSM_INCLUDE_TARGET="$HOME_DIR/.hammerspoon/whisper-dictation.lua"
HSM_BACKUP="$HOME_DIR/.hammerspoon/init.lua.backup-$(date +%Y%m%d-%H%M%S)"
HSM_INSTALL_MODE="${HAMMERSPOON_INSTALL_MODE:-include}"
LAUNCH_AGENTS_DIR="$HOME_DIR/Library/LaunchAgents"
LAUNCH_AGENT_LABEL="com.hansenhomeai.whisper-dictation"
LAUNCH_AGENT_PATH="$LAUNCH_AGENTS_DIR/$LAUNCH_AGENT_LABEL.plist"
LAUNCH_AGENT_OUT="$LOG_DIR/launch-agent.stdout.log"
LAUNCH_AGENT_ERR="$LOG_DIR/launch-agent.stderr.log"
USER_UID="$(id -u)"

CONTROL_HOST="${CONTROL_HOST:-127.0.0.1}"
CONTROL_PORT="${CONTROL_PORT:-44123}"
WHISPER_SERVER_HOST="${WHISPER_SERVER_HOST:-127.0.0.1}"
WHISPER_SERVER_PORT="${WHISPER_SERVER_PORT:-8177}"
PREBUFFER_MILLISECONDS="${PREBUFFER_MILLISECONDS:-1000}"
AUDIO_BUFFER_SIZE_FRAMES="${AUDIO_BUFFER_SIZE_FRAMES:-128}"
POLL_INTERVAL_MILLISECONDS="${POLL_INTERVAL_MILLISECONDS:-150}"
WARM_SERVER_ON_LAUNCH="${WARM_SERVER_ON_LAUNCH:-true}"
WHISPER_THREADS="${WHISPER_THREADS:-4}"
PREFERRED_INPUT_DEVICE="${PREFERRED_INPUT_DEVICE:-}"
ENFORCE_PREFERRED_INPUT_DEVICE="${ENFORCE_PREFERRED_INPUT_DEVICE:-false}"
PERSIST_RECENT_CAPTURES="${PERSIST_RECENT_CAPTURES:-false}"
SERVER_REQUEST_TIMEOUT_SECONDS="${SERVER_REQUEST_TIMEOUT_SECONDS:-30}"
CLI_TIMEOUT_SECONDS="${CLI_TIMEOUT_SECONDS:-90}"

fail() {
  echo "install-local.sh: $*" >&2
  exit 1
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

canonical_path() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

resolve_whisper_cpp_root() {
  if [[ -n "${WHISPER_CPP_ROOT:-}" ]]; then
    printf '%s\n' "$WHISPER_CPP_ROOT"
    return
  fi

  local candidates=(
    "$ROOT/../whisper.cpp"
    "$HOME_DIR/MyProjects/whisper.cpp"
    "$HOME_DIR/src/whisper.cpp"
    "$HOME_DIR/code/whisper.cpp"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate/build/bin/whisper-server" && -x "$candidate/build/bin/whisper-cli" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  fail "Unable to find whisper.cpp. Set WHISPER_CPP_ROOT=/absolute/path/to/whisper.cpp."
}

resolve_model_path() {
  if [[ -n "${WHISPER_MODEL_PATH:-}" ]]; then
    printf '%s\n' "$WHISPER_MODEL_PATH"
    return
  fi

  local model_dir="$1/models"
  local candidates=(
    "$model_dir/ggml-small.en.bin"
    "$model_dir/ggml-base.en.bin"
    "$model_dir/ggml-small.bin"
    "$model_dir/ggml-base.bin"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  fail "Unable to find a Whisper model in $model_dir. Set WHISPER_MODEL_PATH=/absolute/path/to/model.bin."
}

assert_bool() {
  local value
  value="$(lower "$1")"
  case "$value" in
    true|false) ;;
    *)
      fail "Expected true/false for boolean value, got '$1'"
      ;;
  esac
}

assert_positive_number() {
  local name="$1"
  local value="$2"
  python3 - "$name" "$value" <<'PY'
import sys

name, value = sys.argv[1:]
try:
    parsed = float(value)
except ValueError:
    raise SystemExit(f"install-local.sh: {name} must be a positive number, got {value!r}")
if parsed <= 0:
    raise SystemExit(f"install-local.sh: {name} must be a positive number, got {value!r}")
PY
}

assert_loopback_control_host() {
  case "$(lower "$CONTROL_HOST")" in
    127.0.0.1|localhost|::1) ;;
    *)
      fail "CONTROL_HOST must stay loopback-only. Use 127.0.0.1, localhost, or ::1."
      ;;
  esac
}

assert_hammerspoon_install_mode() {
  case "$HSM_INSTALL_MODE" in
    include|overwrite) ;;
    *)
      fail "HAMMERSPOON_INSTALL_MODE must be include or overwrite."
      ;;
  esac
}

cleanup_matching_whisper_servers() {
  local pids pid command server_name model_name
  server_name="$(basename "$WHISPER_SERVER_BINARY")"
  model_name="$(basename "$WHISPER_MODEL_PATH")"
  pids="$(/usr/sbin/lsof -nP -iTCP:"$WHISPER_SERVER_PORT" -sTCP:LISTEN -t 2>/dev/null || true)"
  [[ -n "$pids" ]] || return 0

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
    [[ -n "$command" ]] || continue
    if { [[ "$command" == *"$WHISPER_SERVER_BINARY"* ]] || [[ "$command" == *"/$server_name"* ]]; } \
      && { [[ "$command" == *"$WHISPER_MODEL_PATH"* ]] || [[ "$command" == *"/$model_name"* ]]; } \
      && [[ "$command" == *"--port $WHISPER_SERVER_PORT"* ]]; then
      echo "Stopping stale whisper-server pid $pid on port $WHISPER_SERVER_PORT"
      kill "$pid" >/dev/null 2>&1 || true
      for _ in {1..20}; do
        kill -0 "$pid" >/dev/null 2>&1 || break
        sleep 0.05
      done
      if kill -0 "$pid" >/dev/null 2>&1; then
        kill -9 "$pid" >/dev/null 2>&1 || true
      fi
    else
      fail "Port $WHISPER_SERVER_PORT is already used by another process: $command"
    fi
  done <<< "$pids"
}

install_hammerspoon_config() {
  local backed_up=false
  local loader
  loader='
-- whisper-maxxing dictation
local whisperDictationConfig = os.getenv("HOME") .. "/.hammerspoon/whisper-dictation.lua"
if hs.fs.attributes(whisperDictationConfig) then
  dofile(whisperDictationConfig)
end'
  case "$HSM_INSTALL_MODE" in
    overwrite)
      if [[ -f "$HSM_TARGET" ]]; then
        cp "$HSM_TARGET" "$HSM_BACKUP"
        backed_up=true
      fi
      cp "$ROOT/hammerspoon/init.lua" "$HSM_TARGET"
      echo "Updated Hammerspoon config at $HSM_TARGET"
      [[ "$backed_up" == "true" ]] && echo "Backup saved at $HSM_BACKUP"
      ;;
    include)
      cp "$ROOT/hammerspoon/init.lua" "$HSM_INCLUDE_TARGET"
      if [[ -f "$HSM_TARGET" ]]; then
        cp "$HSM_TARGET" "$HSM_BACKUP"
        backed_up=true
      else
        : > "$HSM_TARGET"
      fi

      if cmp -s "$ROOT/hammerspoon/init.lua" "$HSM_TARGET"; then
        printf '%s\n' "$loader" > "$HSM_TARGET"
      elif ! grep -q 'whisper-dictation.lua' "$HSM_TARGET"; then
        printf '%s\n' "$loader" >> "$HSM_TARGET"
      fi

      echo "Installed Hammerspoon include at $HSM_INCLUDE_TARGET"
      echo "Ensured guarded loader in $HSM_TARGET"
      [[ "$backed_up" == "true" ]] && echo "Backup saved at $HSM_BACKUP"
      ;;
  esac
}

read_existing_config_value() {
  local key="$1"
  python3 - "$CONFIG_PATH" "$key" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
if not config_path.exists():
    raise SystemExit(0)
try:
    payload = json.loads(config_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(0)
value = payload.get(key)
if value is None:
    raise SystemExit(0)
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

detect_default_input_device() {
  system_profiler SPAudioDataType 2>/dev/null | python3 - <<'PY'
import sys

lines = sys.stdin.read().splitlines()
current = None
for raw in lines:
    line = raw.rstrip()
    stripped = line.strip()
    if not stripped:
        continue
    if raw.startswith("        ") and stripped.endswith(":") and not stripped.startswith(("Input ", "Output ", "Current ", "Transport", "Manufacturer", "Default ", "Input Source", "Output Source")):
        current = stripped[:-1]
        continue
    if current and stripped == "Default Input Device: Yes":
        print(current)
        break
PY
}

WHISPER_CPP_ROOT="$(canonical_path "$(resolve_whisper_cpp_root)")"
WHISPER_SERVER_BINARY="${WHISPER_SERVER_BINARY:-$WHISPER_CPP_ROOT/build/bin/whisper-server}"
WHISPER_CLI_BINARY="${WHISPER_CLI_BINARY:-$WHISPER_CPP_ROOT/build/bin/whisper-cli}"
WHISPER_MODEL_PATH="$(resolve_model_path "$WHISPER_CPP_ROOT")"
WHISPER_VAD_MODEL_PATH="${WHISPER_VAD_MODEL_PATH:-}"

WHISPER_SERVER_BINARY="$(canonical_path "$WHISPER_SERVER_BINARY")"
WHISPER_CLI_BINARY="$(canonical_path "$WHISPER_CLI_BINARY")"
WHISPER_MODEL_PATH="$(canonical_path "$WHISPER_MODEL_PATH")"
if [[ -n "$WHISPER_VAD_MODEL_PATH" ]]; then
  WHISPER_VAD_MODEL_PATH="$(canonical_path "$WHISPER_VAD_MODEL_PATH")"
fi

if [[ -z "$PREFERRED_INPUT_DEVICE" ]]; then
  PREFERRED_INPUT_DEVICE="$(read_existing_config_value preferredInputDevice || true)"
fi
if [[ -z "$PREFERRED_INPUT_DEVICE" ]]; then
  PREFERRED_INPUT_DEVICE="$(detect_default_input_device || true)"
fi
if [[ -n "$PREFERRED_INPUT_DEVICE" && -z "${ENFORCE_PREFERRED_INPUT_DEVICE_EXPLICIT:-}" ]]; then
  ENFORCE_PREFERRED_INPUT_DEVICE=true
fi

[[ -x "$WHISPER_SERVER_BINARY" ]] || fail "whisper-server not found at $WHISPER_SERVER_BINARY"
[[ -x "$WHISPER_CLI_BINARY" ]] || fail "whisper-cli not found at $WHISPER_CLI_BINARY"
[[ -f "$WHISPER_MODEL_PATH" ]] || fail "Whisper model not found at $WHISPER_MODEL_PATH"

assert_bool "$WARM_SERVER_ON_LAUNCH"
assert_bool "$ENFORCE_PREFERRED_INPUT_DEVICE"
assert_bool "$PERSIST_RECENT_CAPTURES"
assert_positive_number "SERVER_REQUEST_TIMEOUT_SECONDS" "$SERVER_REQUEST_TIMEOUT_SECONDS"
assert_positive_number "CLI_TIMEOUT_SECONDS" "$CLI_TIMEOUT_SECONDS"
assert_loopback_control_host
assert_hammerspoon_install_mode

export ROOT CACHE_DIR LOG_DIR SALVAGE_DIR
export CONTROL_HOST CONTROL_PORT WHISPER_SERVER_HOST WHISPER_SERVER_PORT
export PREBUFFER_MILLISECONDS AUDIO_BUFFER_SIZE_FRAMES POLL_INTERVAL_MILLISECONDS
export WARM_SERVER_ON_LAUNCH WHISPER_THREADS PREFERRED_INPUT_DEVICE ENFORCE_PREFERRED_INPUT_DEVICE
export WHISPER_SERVER_BINARY WHISPER_CLI_BINARY WHISPER_MODEL_PATH
export WHISPER_VAD_MODEL_PATH
export PERSIST_RECENT_CAPTURES SERVER_REQUEST_TIMEOUT_SECONDS CLI_TIMEOUT_SECONDS

"$ROOT/scripts/build-release.sh"

mkdir -p "$APP_SUPPORT_DIR" "$CACHE_DIR" "$LOG_DIR" "$SALVAGE_DIR" "$HOME_DIR/.hammerspoon" "$LAUNCH_AGENTS_DIR"

python3 - "$CONFIG_PATH" <<'PY'
import json
import os
import sys

config_path = sys.argv[1]
preferred = os.environ.get("PREFERRED_INPUT_DEVICE", "").strip()
vad_model = os.environ.get("WHISPER_VAD_MODEL_PATH", "").strip()
config = {
    "controlHost": os.environ["CONTROL_HOST"],
    "controlPort": int(os.environ["CONTROL_PORT"]),
    "preferredInputDevice": preferred or None,
    "enforcePreferredInputDevice": os.environ["ENFORCE_PREFERRED_INPUT_DEVICE"].lower() == "true",
    "prebufferMilliseconds": int(os.environ["PREBUFFER_MILLISECONDS"]),
    "audioBufferSizeFrames": int(os.environ["AUDIO_BUFFER_SIZE_FRAMES"]),
    "pollIntervalMilliseconds": int(os.environ["POLL_INTERVAL_MILLISECONDS"]),
    "whisperServerBinary": os.environ["WHISPER_SERVER_BINARY"],
    "whisperCliBinary": os.environ["WHISPER_CLI_BINARY"],
    "whisperModelPath": os.environ["WHISPER_MODEL_PATH"],
    "whisperVADModelPath": vad_model or None,
    "whisperServerHost": os.environ["WHISPER_SERVER_HOST"],
    "whisperServerPort": int(os.environ["WHISPER_SERVER_PORT"]),
    "tempDirectory": os.environ["CACHE_DIR"],
    "salvageDirectory": os.environ["SALVAGE_DIR"],
    "daemonLogPath": os.path.join(os.environ["LOG_DIR"], "daemon.log"),
    "whisperServerLogPath": os.path.join(os.environ["LOG_DIR"], "whisper-server.log"),
    "controlBinaryPath": os.path.join(os.environ["ROOT"], "bin", "whisper-dictation-ctl"),
    "daemonBinaryPath": os.path.join(os.environ["ROOT"], "bin", "whisper-dictation-daemon"),
    "warmServerOnLaunch": os.environ["WARM_SERVER_ON_LAUNCH"].lower() == "true",
    "whisperThreads": int(os.environ["WHISPER_THREADS"]),
    "persistRecentCaptures": os.environ["PERSIST_RECENT_CAPTURES"].lower() == "true",
    "serverRequestTimeoutSeconds": float(os.environ["SERVER_REQUEST_TIMEOUT_SECONDS"]),
    "cliTimeoutSeconds": float(os.environ["CLI_TIMEOUT_SECONDS"]),
}
with open(config_path, "w", encoding="utf-8") as fh:
    json.dump(config, fh, indent=2)
    fh.write("\n")
PY

python3 - "$ROOT/launchd/com.hansenhomeai.whisper-dictation.plist.template" "$LAUNCH_AGENT_PATH" \
  "$ROOT" "$CONFIG_PATH" "$LAUNCH_AGENT_OUT" "$LAUNCH_AGENT_ERR" <<'PY'
import pathlib
import sys

template_path, output_path, root, config_path, stdout_path, stderr_path = sys.argv[1:]
content = pathlib.Path(template_path).read_text(encoding="utf-8")
content = content.replace("__ROOT__", root)
content = content.replace("__CONFIG_PATH__", config_path)
content = content.replace("__STDOUT_PATH__", stdout_path)
content = content.replace("__STDERR_PATH__", stderr_path)
pathlib.Path(output_path).write_text(content, encoding="utf-8")
PY

install_hammerspoon_config

pkill -f '/whisper-dictation-daemon --config ' >/dev/null 2>&1 || true
cleanup_matching_whisper_servers
launchctl bootout "gui/$USER_UID/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
launchctl bootout "gui/$USER_UID" "$LAUNCH_AGENT_PATH" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$USER_UID" "$LAUNCH_AGENT_PATH"
launchctl kickstart -k "gui/$USER_UID/$LAUNCH_AGENT_LABEL"
"$ROOT/bin/whisper-dictation-ctl" warmup >/dev/null

if command -v hs >/dev/null 2>&1; then
  hs -c "hs.reload()" || true
elif pgrep -x Hammerspoon >/dev/null 2>&1; then
  osascript -e 'tell application "Hammerspoon" to activate' || true
fi

echo "Installed config to $CONFIG_PATH"
echo "Using whisper.cpp at $WHISPER_CPP_ROOT"
echo "Using model $WHISPER_MODEL_PATH"
echo "Installed LaunchAgent at $LAUNCH_AGENT_PATH"
echo
echo "Verify with:"
echo "  ./bin/whisper-dictation-ctl status"
echo "  ./bin/whisper-dictation-ctl start && sleep 1 && ./bin/whisper-dictation-ctl stop && ./bin/whisper-dictation-ctl next-result"
echo
echo "macOS permissions needed:"
echo "  System Settings > Privacy & Security > Microphone: allow dictation capture"
echo "  System Settings > Privacy & Security > Accessibility: allow Hammerspoon to paste text"
