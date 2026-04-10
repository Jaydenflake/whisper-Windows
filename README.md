# Whisper Dictation Hotkey

This repository snapshots the current local dictation setup that is running through Hammerspoon and `whisper.cpp`.

The live system has not been changed by this repo setup. The current live source of truth is still:

- `~/.hammerspoon/init.lua`

This repo contains:

- `hammerspoon/init.lua`: mirrored current Hammerspoon config
- `docs/latency-analysis.md`: measured startup and latency facts from April 10, 2026
- `scripts/benchmark-current.sh`: repeatable benchmark script for the current local stack

## Current Architecture

Current hotkey flow:

1. `cmd + .` enters Hammerspoon.
2. Hammerspoon resolves the microphone by calling `ffmpeg -f avfoundation -list_devices true -i ''`.
3. Hammerspoon launches a fresh `ffmpeg` recording process.
4. On stop, Hammerspoon launches a fresh `whisper-cli` process.
5. `whisper-cli` loads `ggml-small.en.bin`, transcribes, writes a text file, and the result is pasted.

## Hard Facts

- Current model: `ggml-small.en.bin`
- Current model size: `487,614,201` bytes
- Current build flags: `GGML_METAL=ON`, `GGML_BLAS=ON`, `WHISPER_COREML=OFF`
- Current recorder path: `/opt/homebrew/bin/ffmpeg`
- Current transcriber path: `/Users/gabrielhansen/MyProjects/whisper.cpp/build/bin/whisper-cli`

Measured on this machine:

- Device enumeration on every hotkey press costs about `0.21s` to `0.81s`
- Fresh `whisper-cli` execution costs about `1.09s` on first run and about `0.55s` on warm runs for a trivial 2-second WAV
- A resident `whisper-server` drops hot inference for the same 2-second WAV to about `0.19s` to `0.26s`
- A cold launch of `whisper-server` to HTTP-ready took about `8.15s`, which is acceptable if it happens once at login and not on every hotkey press

## Recommendation Summary

If the goal is immediate capture, the fix is architectural, not just a faster model:

1. Remove microphone discovery from the hot path.
2. Start capture immediately on keypress.
3. Keep transcription resident in memory.
4. Add a short pre-roll buffer so the first spoken word is never lost.

The clear target architecture is:

1. A resident recorder process or Hammerspoon-managed audio session that is already prepared before the hotkey fires.
2. A resident local transcription service that holds the model in memory.
3. A hotkey that only toggles capture state and sends buffered audio for transcription.

## Core ML Status

Core ML is not currently active in the working build.

I also verified that a separate Core ML-enabled build does not currently work end-to-end because it expects:

- `models/ggml-small.en-encoder.mlmodelc`

What is present on disk right now is:

- `models/coreml-encoder-small.en.mlpackage`

That means Core ML is not wired correctly yet in the current local setup and should not be treated as an active optimization until the expected compiled model artifact exists and loads successfully.
