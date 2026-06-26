# Windows Setup

This repo now includes a Windows-native dictation script in `windows/whisper_dictation.py`.

The Windows version is intentionally separate from the macOS Swift daemon. It uses:

- Python for the app runtime
- `sounddevice` for microphone capture
- native Windows global hotkeys
- `whisper.cpp` `whisper-cli.exe` for local transcription
- optional resident `whisper-server.exe` for faster repeated transcription
- the Windows clipboard so you can paste with normal `Ctrl+V`

## Hotkeys

Defaults:

- `Ctrl + Alt + D`: start or stop dictation
- `Ctrl + Alt + End`: manually copy the accumulated transcript to the clipboard
- `Ctrl + Alt + S`: paste the accumulated transcript, clear the transcript buffer, and clear the clipboard
- `Ctrl + Alt + Backspace`: cancel the active recording
- `Ctrl + Alt + Page Down`: clear the accumulated transcript

These are stored in `%APPDATA%\WhisperDictation\config.json` as:

```json
{
  "startStopHotkey": "<ctrl>+<alt>+d",
  "backupStartStopHotkey": "",
  "copyBufferHotkey": "<ctrl>+<alt>+<end>",
  "pasteAndClearHotkey": "<ctrl>+<alt>+s",
  "cancelHotkey": "<ctrl>+<alt>+<backspace>",
  "clearBufferHotkey": "<ctrl>+<alt>+<page_down>"
}
```

`Ctrl + Alt + Delete` is intentionally avoided because Windows reserves it. Plain `Delete + Enter` is also not recommended as a global shortcut because it is too easy to trigger while editing text and does not include a modifier key.

Use `pynput` hotkey syntax when changing them. Examples:

- `<ctrl>+<alt>+d`
- `<ctrl>+<alt>+s`
- `<ctrl>+<alt>+<left>`
- `<ctrl>+<alt>+<end>`
- `<ctrl>+<shift>+d`
- `<ctrl>+<alt>+d`
- `<cmd>+<alt>+<space>` for the Windows key plus Alt plus Space

## Requirements

- Windows 10 or later
- Python 3.10 or later
- A local `whisper.cpp` build or release containing `whisper-cli.exe`
- A local Whisper model, for example `ggml-small.en.bin`

The installer creates a virtual environment under:

```powershell
%LOCALAPPDATA%\WhisperDictation\venv
```

It writes config to:

```powershell
%APPDATA%\WhisperDictation\config.json
```

## Install

From this repo in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 `
  -WhisperCppRoot C:\src\whisper.cpp `
  -WhisperModelPath C:\src\whisper.cpp\models\ggml-small.en.bin
```

If you know the exact CLI path:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 `
  -WhisperCliPath C:\src\whisper.cpp\build\bin\Release\whisper-cli.exe `
  -WhisperModelPath C:\src\whisper.cpp\models\ggml-small.en.bin
```

To install a Startup shortcut:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 `
  -WhisperCppRoot C:\src\whisper.cpp `
  -CreateStartupShortcut
```

You can also use environment variables:

```powershell
$env:WHISPER_CPP_ROOT = "C:\src\whisper.cpp"
$env:WHISPER_MODEL_PATH = "C:\src\whisper.cpp\models\ggml-small.en.bin"
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1
```

## Run

Start the dictation script:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\start-windows-dictation.ps1
```

Keep that PowerShell window open while using dictation.

Press `Ctrl + Alt + D` to start recording. Press it again to stop. Each completed recording is transcribed, appended to an in-memory transcript buffer, and the full buffer is copied to the clipboard automatically. A small recording indicator appears near the bottom of the screen while capture is active.

Paste with normal `Ctrl + V` wherever you want it. `Ctrl + Alt + End` is still available as a manual copy command if you want to refresh the clipboard.

Press `Ctrl + Alt + S` when you want to paste the accumulated transcript and reset for a new dictation. If transcription is still running, the app waits and pastes as soon as the text is ready. It also waits briefly for the hotkey keys to be released, sends paste, waits again so the target app can consume the paste, clears the internal transcript buffer, and clears the clipboard.

Press `Ctrl + Alt + Page Down` to clear the accumulated transcript after you are done with it.

## Microphone Selection

List input devices:

```powershell
& "$env:LOCALAPPDATA\WhisperDictation\venv\Scripts\python.exe" .\windows\whisper_dictation.py list-devices
```

Probe input devices and show local audio levels:

```powershell
& "$env:LOCALAPPDATA\WhisperDictation\venv\Scripts\python.exe" .\windows\whisper_dictation.py probe-devices
```

Then reinstall with a device name or index:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1 `
  -WhisperCppRoot C:\src\whisper.cpp `
  -InputDevice "Microphone"
```

The match is case-insensitive and can be a substring of the device name.

When `inputDevice` is empty, the app probes likely microphone devices for a short local level check, selects the strongest working input, opens that device at its native sample rate, and resamples to 16 kHz for Whisper. The probe is not saved or transcribed. Set `inputDeviceAutoProbeSeconds` to `0` if you want to skip the level probe.

## Configuration

Edit `%APPDATA%\WhisperDictation\config.json` for:

- `inputDevice`: microphone name substring or device index
- `inputDeviceAutoProbeSeconds`: local startup level-probe duration, default `0.35`
- `useWhisperServer`: keep `true` to use resident `whisper-server.exe` when available
- `whisperServerPath`: path to `whisper-server.exe`
- `whisperServerPort`: local server port, default `8177`
- `startStopHotkey`: start/stop hotkey
- `backupStartStopHotkey`: optional backup start/stop hotkey
- `copyBufferHotkey`: copy accumulated transcript hotkey
- `pasteAndClearHotkey`: paste accumulated transcript and reset hotkey
- `cancelHotkey`: cancel hotkey
- `clearBufferHotkey`: clear accumulated transcript hotkey
- `autoPaste`: default `false`; set `true` if the copy hotkey should also paste
- `transcriptJoiner`: text between appended chunks, default one space
- `pasteDelaySeconds`: delay before sending paste after the paste/reset hotkey, default `0.4`
- `clearClipboardAfterPasteSeconds`: delay before clearing clipboard after paste/reset, default `2.0`
- `whisperThreads`: CPU threads passed to `whisper-cli.exe`
- `language`: language passed to Whisper, default `en`
- `keepRecentCaptures`: opt-in successful audio/transcript retention

Failed transcriptions save diagnostic audio under:

```powershell
%USERPROFILE%\Documents\WhisperSalvage
```

## Troubleshooting

If no text appears:

- Make sure the PowerShell runner window is still open.
- Confirm `whisper-cli.exe` and the model paths in config exist.
- Run `probe-devices`. If the selected/default device has near-zero peak/RMS but another microphone device has stronger levels, set `inputDevice` to that device index or rerun the installer with `-InputDevice`.
- Try a smaller model such as `ggml-base.en.bin` if transcription is very slow.
- Press the copy hotkey and confirm the transcript reaches the clipboard.

If hotkeys do not fire:

- Try running PowerShell as Administrator.
- Change the hotkeys in config if another app already uses them.
- Avoid shortcuts reserved by Windows or your laptop keyboard software.

If the first word is missing:

- Increase `prebufferMilliseconds` from `1000` to `1500`.

## Differences From The Mac Version

The macOS app uses a resident Swift daemon, Hammerspoon, and optionally a warm `whisper-server`.

The Windows version is a simpler single-process script. It still preserves the key behavior needed for laptop dictation:

- global hotkeys
- prebuffered microphone capture
- local Whisper transcription
- accumulated transcript copy/paste workflow

When `whisper-server.exe` is configured, the Windows version keeps the model resident for faster repeated dictation. If the server path fails, it falls back to `whisper-cli.exe`.
