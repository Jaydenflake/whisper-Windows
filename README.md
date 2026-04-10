# whisper-maxxing

`whisper-maxxing` is a low-latency local dictation harness for macOS.

Low-latency local dictation for macOS using:

- a resident native audio-capture daemon
- `whisper.cpp` kept hot in memory through `whisper-server`
- Hammerspoon hotkeys for start, stop, cancel, and paste

This repo exists to solve the common `whisper.cpp` cold-start problem: if you launch recording and transcription from scratch on every hotkey press, you lose the first words. This harness keeps the audio path ready, keeps a rolling prebuffer, and offloads transcription to a resident service.

## What It Does

- starts capture through a native Swift daemon instead of spawning `ffmpeg` on every hotkey press
- keeps a 1-second rolling prebuffer so the first spoken words are preserved
- keeps `whisper-server` resident instead of loading the model for every transcription
- uses `launchd` so the daemon is restarted automatically and available at login
- pastes finished transcripts directly into the frontmost app through Hammerspoon

## Hotkeys

- `cmd + .`: start or stop dictation
- `cmd + ,`: cancel the active recording

## Requirements

- macOS 14 or later
- Xcode command line tools with Swift 6 support
- [Hammerspoon](https://www.hammerspoon.org/)
- a built `whisper.cpp` checkout with:
  - `build/bin/whisper-server`
  - `build/bin/whisper-cli`
  - at least one model file such as `models/ggml-small.en.bin`

This repo does not vendor `whisper.cpp`. It assumes you already have a local checkout.

## Quick Start

1. Clone this repo.
2. Build `whisper.cpp`.
3. Install Hammerspoon.
4. Run the installer:

```bash
./scripts/install-local.sh
```

If your `whisper.cpp` checkout is not in one of the default locations, point the installer at it:

```bash
WHISPER_CPP_ROOT=/absolute/path/to/whisper.cpp ./scripts/install-local.sh
```

If you want to pin a microphone explicitly:

```bash
PREFERRED_INPUT_DEVICE="MacBook Pro Microphone" \
ENFORCE_PREFERRED_INPUT_DEVICE=true \
./scripts/install-local.sh
```

The installer will:

- build the Swift binaries
- write `~/Library/Application Support/WhisperDictation/config.json`
- install the Hammerspoon config to `~/.hammerspoon/init.lua`
- install a `launchd` agent at `~/Library/LaunchAgents/com.hansenhomeai.whisper-dictation.plist`
- warm the daemon and reload Hammerspoon

## Repo Layout

- [`Sources/WhisperDictationCore`](Sources/WhisperDictationCore): shared config, transport, buffering, and audio helpers
- [`Sources/whisper-dictation-daemon`](Sources/whisper-dictation-daemon): native capture daemon and transcription queue
- [`Sources/whisper-dictation-ctl`](Sources/whisper-dictation-ctl): control CLI used by Hammerspoon and scripts
- [`hammerspoon/init.lua`](hammerspoon/init.lua): hotkey integration and result polling
- [`launchd/com.hansenhomeai.whisper-dictation.plist.template`](launchd/com.hansenhomeai.whisper-dictation.plist.template): LaunchAgent template
- [`scripts/install-local.sh`](scripts/install-local.sh): installer
- [`scripts/benchmark-startup.sh`](scripts/benchmark-startup.sh): warm/cold startup benchmarks
- [`scripts/benchmark-pipeline.sh`](scripts/benchmark-pipeline.sh): end-to-end queue and transcription checks

## Documentation

- [Setup Guide](docs/setup.md)
- [Configuration](docs/configuration.md)
- [Architecture](docs/architecture.md)
- [Operations](docs/operations.md)
- [Performance Notes](docs/latency-analysis.md)

## Notes

- The steady-state design assumes the daemon is already resident through `launchd`.
- Cold daemon recovery exists, but the intended fast path is the warm resident path.
- The current default installer prefers `ggml-small.en.bin` if it exists, then falls back to a smaller English model if needed.

## License

MIT. See [LICENSE](LICENSE).
