# Configuration

The installer writes the runtime config to:

- `~/Library/Application Support/WhisperDictation/config.json`

Example shape:

```json
{
  "controlHost": "127.0.0.1",
  "controlPort": 44123,
  "preferredInputDevice": null,
  "enforcePreferredInputDevice": false,
  "prebufferMilliseconds": 1000,
  "audioBufferSizeFrames": 128,
  "pollIntervalMilliseconds": 150,
  "whisperServerBinary": "/absolute/path/to/whisper.cpp/build/bin/whisper-server",
  "whisperCliBinary": "/absolute/path/to/whisper.cpp/build/bin/whisper-cli",
  "whisperModelPath": "/absolute/path/to/whisper.cpp/models/ggml-small.en.bin",
  "whisperServerHost": "127.0.0.1",
  "whisperServerPort": 8177,
  "tempDirectory": "/Users/example/Library/Caches/WhisperDictation",
  "salvageDirectory": "/Users/example/Documents/WhisperSalvage",
  "daemonLogPath": "/Users/example/Library/Logs/WhisperDictation/daemon.log",
  "whisperServerLogPath": "/Users/example/Library/Logs/WhisperDictation/whisper-server.log",
  "controlBinaryPath": "/absolute/path/to/repo/bin/whisper-dictation-ctl",
  "daemonBinaryPath": "/absolute/path/to/repo/bin/whisper-dictation-daemon",
  "warmServerOnLaunch": true,
  "whisperThreads": 4
}
```

Most people should not edit this file directly. Re-run the installer with environment variables instead.
