# whisper-maxxing

Low-latency local dictation for macOS. `whisper-maxxing` keeps audio capture and `whisper.cpp` warm so hotkey dictation starts immediately, preserves the first words with a rolling prebuffer, and pastes completed transcripts through Hammerspoon.

This repo also includes a Windows port under `windows/`. The Windows version is a Python hotkey dictation script that records from the microphone, transcribes with local `whisper.cpp` `whisper-cli.exe`, then copies and pastes the transcript into the active app. See [docs/windows.md](docs/windows.md).

## What You Get

- native Swift capture daemon managed by `launchd`
- resident `whisper-server` with bounded request timeouts and CLI fallback
- 1-second rolling prebuffer
- Hammerspoon hotkeys:
  - `cmd + .` starts or stops dictation
  - `cmd + ,` cancels the active recording
- loopback-only local control socket
- successful dictation audio/transcript persistence off by default

## Requirements

For the original macOS daemon:

- macOS 14 or later
- Xcode command line tools with Swift 6 support
- [Hammerspoon](https://www.hammerspoon.org/)
- `whisper.cpp` built locally with:
  - `build/bin/whisper-server`
  - `build/bin/whisper-cli`
  - a model such as `models/ggml-small.en.bin`

This repo does not vendor `whisper.cpp` or model files.

For Windows:

- Windows 10 or later
- Python 3.10 or later
- `whisper.cpp` with `whisper-cli.exe`
- a model such as `ggml-small.en.bin`

Install with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 `
  -WhisperCppRoot C:\src\whisper.cpp `
  -WhisperModelPath C:\src\whisper.cpp\models\ggml-small.en.bin
```

Run with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows-dictation.ps1
```

## Build `whisper.cpp`

One standard setup path:

```bash
git clone https://github.com/ggml-org/whisper.cpp.git ~/src/whisper.cpp
cd ~/src/whisper.cpp
cmake -B build
cmake --build build --config Release
./models/download-ggml-model.sh small.en
```

Any local checkout is fine if it contains the binaries and model. Pass its path during install if it is not in a default location.

## macOS Permissions

Before first real use, grant:

- Microphone access to the dictation daemon/Terminal path that starts it.
- Accessibility access to Hammerspoon so it can paste into the frontmost app.

Open System Settings > Privacy & Security, then check Microphone and Accessibility. If dictation starts but produces no text, permissions are one of the first things to verify.

## Install

From this repo:

```bash
WHISPER_CPP_ROOT=~/src/whisper.cpp ./scripts/install-local.sh
```

The installer builds release binaries, writes config, installs a LaunchAgent, installs `~/.hammerspoon/whisper-dictation.lua`, and adds a small guarded loader to `~/.hammerspoon/init.lua` if needed. Existing `init.lua` is backed up before modification.

Common overrides:

```bash
WHISPER_CPP_ROOT=~/src/whisper.cpp \
WHISPER_MODEL_PATH=~/src/whisper.cpp/models/ggml-small.en.bin \
PREFERRED_INPUT_DEVICE="MacBook Pro Microphone" \
ENFORCE_PREFERRED_INPUT_DEVICE=true \
WHISPER_THREADS=6 \
./scripts/install-local.sh
```

Useful optional settings:

- `WHISPER_VAD_MODEL_PATH`: enables VAD for longer recordings when readable.
- `SERVER_REQUEST_TIMEOUT_SECONDS`: default `30`.
- `CLI_TIMEOUT_SECONDS`: default `90`.
- `PERSIST_RECENT_CAPTURES=true`: stores successful recent audio/transcript proof under `~/Documents/WhisperSalvage/recent`.
- `HAMMERSPOON_INSTALL_MODE=overwrite`: replaces `~/.hammerspoon/init.lua` with this repo's config instead of using the safe include mode.

`CONTROL_HOST` is intentionally loopback-only. Use `127.0.0.1`, `localhost`, or `::1`; do not expose the control socket to a network.

## Verify

```bash
./bin/whisper-dictation-ctl status
```

Expected healthy fields include:

- `"ok": true`
- `"engineReady": true`
- `"serverState": "ready"`
- `"prebufferAvailableMilliseconds": 1000`

Run a real control loop:

```bash
./bin/whisper-dictation-ctl start
sleep 1
./bin/whisper-dictation-ctl stop
./bin/whisper-dictation-ctl next-result
```

Run code checks:

```bash
swift build
swift run transcript-quality-tests
COUNT=2 ./scripts/benchmark-pipeline.sh
```

## Privacy

Dictation is local. Audio is recorded to temporary WAV data for transcription.

By default, successful dictations are not saved after completion. Failed or low-confidence sessions may save diagnostic salvage files under `~/Documents/WhisperSalvage` so you can debug what happened. Set `PERSIST_RECENT_CAPTURES=true` only if you explicitly want successful recent audio and transcript JSON saved for inspection.

## Troubleshooting

- No text appears: run `./bin/whisper-dictation-ctl status`, check Microphone permissions, then check `~/Library/Logs/WhisperDictation/launch-agent.stderr.log`.
- Hotkey does nothing: confirm Hammerspoon is running, Accessibility is granted, and `~/.hammerspoon/init.lua` loads `~/.hammerspoon/whisper-dictation.lua`.
- Wrong microphone: rerun install with `PREFERRED_INPUT_DEVICE` and `ENFORCE_PREFERRED_INPUT_DEVICE=true`.
- Duplicate server or stale daemon: rerun `./scripts/install-local.sh`; matching stale `whisper-server` processes on the configured port are cleaned before launch.

## Repo Layout

- `Sources/WhisperDictationCore`: shared config, socket protocol, buffering, and transcript quality helpers
- `Sources/whisper-dictation-daemon`: capture daemon and transcription queue
- `Sources/whisper-dictation-ctl`: control CLI used by Hammerspoon and scripts
- `hammerspoon/init.lua`: repo-managed Hammerspoon dictation module
- `windows/whisper_dictation.py`: Windows hotkey dictation script
- `scripts/install-local.sh`: local installer
- `scripts/install-windows.ps1`: Windows installer
- `docs/architecture.md`, `docs/operations.md`, `docs/latency-analysis.md`: focused reference notes
- `docs/windows.md`: Windows setup and troubleshooting

## License

MIT. See [LICENSE](LICENSE).
