# Setup Guide

## 1. Install Dependencies

- Install Hammerspoon from `https://www.hammerspoon.org/`
- Install Xcode command line tools
- Build `whisper.cpp`

Expected `whisper.cpp` artifacts:

- `build/bin/whisper-server`
- `build/bin/whisper-cli`
- `models/ggml-small.en.bin` or another supported model

## 2. Install This Repo

From the repo root:

```bash
./scripts/install-local.sh
```

If `whisper.cpp` is somewhere else:

```bash
WHISPER_CPP_ROOT=/absolute/path/to/whisper.cpp ./scripts/install-local.sh
```

## 3. Optional Install-Time Overrides

Common environment variables:

- `WHISPER_CPP_ROOT`: path to the local `whisper.cpp` checkout
- `WHISPER_MODEL_PATH`: explicit path to a model file
- `WHISPER_SERVER_BINARY`: override the server binary path
- `WHISPER_CLI_BINARY`: override the CLI binary path
- `PREFERRED_INPUT_DEVICE`: microphone name to pin
- `ENFORCE_PREFERRED_INPUT_DEVICE`: `true` or `false`
- `WHISPER_THREADS`: number of transcription threads
- `PREBUFFER_MILLISECONDS`: rolling prebuffer size, default `1000`
- `CONTROL_PORT`: local control port, default `44123`
- `WHISPER_SERVER_PORT`: local `whisper-server` port, default `8177`

Example:

```bash
WHISPER_CPP_ROOT=$HOME/src/whisper.cpp \
WHISPER_MODEL_PATH=$HOME/src/whisper.cpp/models/ggml-small.en.bin \
PREFERRED_INPUT_DEVICE="Built-in Microphone" \
ENFORCE_PREFERRED_INPUT_DEVICE=true \
WHISPER_THREADS=6 \
./scripts/install-local.sh
```

## 4. Verify

The installer writes:

- `~/Library/Application Support/WhisperDictation/config.json`
- `~/.hammerspoon/init.lua`
- `~/Library/LaunchAgents/com.hansenhomeai.whisper-dictation.plist`

Quick health check:

```bash
./bin/whisper-dictation-ctl status
```

Expected fields:

- `"ok": true`
- `"engineReady": true`
- `"serverState": "ready"` after warmup

## 5. Use

- `cmd + .`: start or stop dictation
- `cmd + ,`: cancel recording

Hammerspoon polls for completed results and pastes the transcript into the frontmost app automatically.
