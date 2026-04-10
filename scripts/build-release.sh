#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
mkdir -p "$ROOT/bin"
cp "$BIN_PATH/whisper-dictation-daemon" "$ROOT/bin/whisper-dictation-daemon"
cp "$BIN_PATH/whisper-dictation-ctl" "$ROOT/bin/whisper-dictation-ctl"

echo "Release binaries copied to $ROOT/bin"
