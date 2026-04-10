# Latency Analysis

Date: `2026-04-10`

Machine-level facts gathered from the current local setup.

## Files and Build State

- Live Hammerspoon config: `/Users/gabrielhansen/.hammerspoon/init.lua`
- `whisper.cpp` checkout: `/Users/gabrielhansen/MyProjects/whisper.cpp`
- Current model: `/Users/gabrielhansen/MyProjects/whisper.cpp/models/ggml-small.en.bin`
- Current binary: `/Users/gabrielhansen/MyProjects/whisper.cpp/build/bin/whisper-cli`
- Current server binary: `/Users/gabrielhansen/MyProjects/whisper.cpp/build/bin/whisper-server`

Build cache facts from `build/CMakeCache.txt`:

- `CMAKE_BUILD_TYPE=Release`
- `GGML_BLAS=ON`
- `GGML_METAL=1`
- `GGML_METAL_EMBED_LIBRARY=ON`
- `WHISPER_COREML=OFF`

## Current Hammerspoon Hot Path

Relevant current behavior from `init.lua`:

- `resolveAudioDevice()` shells out to `ffmpeg -f avfoundation -list_devices true -i ''`
- `startRecording()` runs that lookup on every hotkey press before starting capture
- `runWhisper()` launches a fresh `whisper-cli` process after recording stops

That means the current startup path is:

1. Hammerspoon hotkey dispatch
2. AVFoundation device enumeration
3. New `ffmpeg` process launch
4. New `whisper-cli` process launch
5. Model load
6. Inference

## Measured Device Enumeration Cost

Repeated timings for:

```bash
/usr/bin/time -lp /opt/homebrew/bin/ffmpeg -f avfoundation -list_devices true -i ''
```

Results:

- Run 1: `real 0.64`
- Run 2: `real 0.81`
- Run 3: `real 0.21`

Conclusion:

- Current microphone resolution alone adds a noticeable fixed delay before recording can even start.

## Measured Fresh `whisper-cli` Cost

Test input:

- 2-second mono 16 kHz silent WAV generated locally

Repeated timings for:

```bash
/usr/bin/time -lp whisper-cli -m ggml-small.en.bin -f /tmp/whisper-silence.wav --output-txt --output-file ...
```

Observed `whisper_print_timings`:

- Run 1 load time: `525.14 ms`
- Run 2 load time: `214.00 ms`
- Run 3 load time: `234.66 ms`

Observed wall times:

- Run 1: `real 1.09`
- Run 2: `real 0.55`
- Run 3: `real 0.55`

Observed runtime backend info:

- `WHISPER : COREML = 0`
- `Metal : EMBED_LIBRARY = 1`

Conclusion:

- The current fresh-process design pays both process startup and model initialization costs on every transcription.
- Even when warm, the CLI path still spends about half a second on a trivial request.

## Measured Resident `whisper-server` Cost

With a persistent local `whisper-server` process already running and the model already loaded:

```bash
curl -sS http://127.0.0.1:8177/inference \
  -H "Content-Type: multipart/form-data" \
  -F file=@/tmp/whisper-silence.wav \
  -F response_format=json
```

Observed wall times:

- Run 1: `real 0.26`
- Run 2: `real 0.19`
- Run 3: `real 0.20`

Conclusion:

- Keeping the model resident cuts the hot transcription path roughly in half versus the warm fresh-CLI path.
- The remaining user-visible miss at the start of dictation is therefore mostly a capture-start problem, not purely a transcription problem.

## Measured Resident Server Cold Start

A fresh server launch was probed until HTTP root became reachable.

Observed time to ready:

- `ready_ms=8152.9`

Conclusion:

- `whisper-server` is not suitable to cold-launch on each hotkey press.
- It is suitable to launch once at login and keep resident.

## Core ML Verification

A separate Core ML-enabled build was created in:

- `/Users/gabrielhansen/MyProjects/whisper.cpp/build-coreml`

Build result:

- Compile succeeded

Runtime result:

- The Core ML-enabled binary failed to initialize because it expected:
  - `/Users/gabrielhansen/MyProjects/whisper.cpp/models/ggml-small.en-encoder.mlmodelc`
- Actual artifact present on disk:
  - `/Users/gabrielhansen/MyProjects/whisper.cpp/models/coreml-encoder-small.en.mlpackage`

Observed failure:

- `whisper_init_state: failed to load Core ML model`

Conclusion:

- Core ML is not currently a functioning part of this setup.
- It may still be worth enabling later, but only after the correct compiled model artifact is generated and verified.

## Clear Recommendation

To stop losing the first words, the next implementation should do all of the following:

1. Cache or pre-resolve the microphone device outside the hotkey path.
2. Keep a resident recording component alive so capture begins immediately.
3. Maintain a short rolling pre-buffer so speech that begins slightly before the UI state flips is still preserved.
4. Keep Whisper resident with `whisper-server` or an equivalent local daemon launched at login.
5. Have the hotkey toggle recording state only, not process startup.
