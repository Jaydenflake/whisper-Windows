# Performance Notes

Date: `2026-04-10`

These measurements were taken on the original development machine for this repo. They are useful as a baseline, not as a universal guarantee.

## Legacy Baseline

Before this harness, the dictation path was:

1. Hammerspoon hotkey
2. microphone lookup via `ffmpeg -list_devices`
3. fresh `ffmpeg` recording process
4. fresh `whisper-cli` process
5. model load
6. inference

Measured costs from that older design:

- device enumeration on every hotkey press: about `0.21s` to `0.81s`
- fresh `whisper-cli` wall time on a trivial WAV: about `0.55s` warm and `1.09s` first run
- hot resident `whisper-server` inference on the same trivial WAV: about `0.19s` to `0.26s`

That is why the repo moved to a resident daemon plus resident server design.

## Current Resident Design

The steady-state design is:

- keep the capture daemon resident through `launchd`
- keep `whisper-server` resident
- keep a rolling prebuffer
- make the hotkey toggle only a logical recording session

## Startup Benchmark Summary

Verified startup results from the current harness:

### Warm Idle

- control round-trip p95: `8.24 ms`
- capture-ready p95: `151.54 ms`
- prebuffer available: `1000 ms`

### Warm Load

- control round-trip p95: `7.39 ms`
- capture-ready p95: `158.83 ms`
- prebuffer available p95: `1000 ms`

### Cold Idle

- daemon cold-boot p95: `354.47 ms`
- control round-trip p95: `360.57 ms`
- capture-ready p95: `162.36 ms`

## Interpretation

The important split is:

- `clientObservedMilliseconds` is end-to-end command latency
- `captureReadyMs` is when the native audio engine is actually live

For real usage, the warm resident path is the intended mode. That is the path users experience after login and after normal operation, and it stays in the single-digit millisecond range at the control layer with capture ready in about `0.15s`.

Cold daemon recovery exists, but it is a fallback path, not the intended steady-state mode.

## Reproducing

Build the repo, install it, then run:

```bash
ITERATIONS=12 ./scripts/benchmark-startup.sh
COUNT=5 ./scripts/benchmark-pipeline.sh
```

Synthetic CPU pressure can be added through:

```bash
LOAD=1 COUNT=5 ./scripts/benchmark-pipeline.sh
```
