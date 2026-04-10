# Operations

## Build

Debug build:

```bash
swift build -c debug
```

Release build and copy binaries to `bin/`:

```bash
./scripts/build-release.sh
```

## Health Checks

Daemon status:

```bash
./bin/whisper-dictation-ctl status
```

Warm the daemon and server:

```bash
./bin/whisper-dictation-ctl warmup
```

Pull the next completed transcript:

```bash
./bin/whisper-dictation-ctl next-result
```

## LaunchAgent

Installed plist:

- `~/Library/LaunchAgents/com.hansenhomeai.whisper-dictation.plist`

Useful commands:

```bash
launchctl print gui/$(id -u)/com.hansenhomeai.whisper-dictation
launchctl kickstart -k gui/$(id -u)/com.hansenhomeai.whisper-dictation
launchctl bootout gui/$(id -u)/com.hansenhomeai.whisper-dictation
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.hansenhomeai.whisper-dictation.plist
```

## Logs

Default log paths:

- `~/Library/Logs/WhisperDictation/daemon.log`
- `~/Library/Logs/WhisperDictation/whisper-server.log`
- `~/Library/Logs/WhisperDictation/launch-agent.stdout.log`
- `~/Library/Logs/WhisperDictation/launch-agent.stderr.log`

## Benchmarking

Startup benchmark:

```bash
ITERATIONS=12 ./scripts/benchmark-startup.sh
```

Pipeline benchmark:

```bash
COUNT=5 ./scripts/benchmark-pipeline.sh
```

Pipeline benchmark with synthetic CPU load:

```bash
LOAD=1 COUNT=5 ./scripts/benchmark-pipeline.sh
```

## Troubleshooting

### No transcript appears

- check `./bin/whisper-dictation-ctl status`
- check that `serverState` becomes `ready`
- check `whisper-server.log`

### Wrong microphone

- set `PREFERRED_INPUT_DEVICE`
- set `ENFORCE_PREFERRED_INPUT_DEVICE=true`
- rerun `./scripts/install-local.sh`

### Hammerspoon hotkey does nothing

- confirm `~/.hammerspoon/init.lua` was installed from this repo
- open Hammerspoon Console
- run `hs.reload()`

### Daemon or server duplicated

The installer already cleans up stray daemon and `whisper-server` processes before reinstalling.

If you need to clean them manually:

```bash
pkill -f '/whisper-dictation-daemon --config ' || true
pkill -f '/whisper-server -m ' || true
```
