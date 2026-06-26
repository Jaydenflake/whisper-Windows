param(
    [string]$WhisperCppRoot = $env:WHISPER_CPP_ROOT,
    [string]$WhisperCliPath = $env:WHISPER_CLI_PATH,
    [string]$WhisperServerPath = $env:WHISPER_SERVER_PATH,
    [string]$WhisperModelPath = $env:WHISPER_MODEL_PATH,
    [string]$InputDevice = $env:WHISPER_INPUT_DEVICE,
    [string]$StartStopHotkey = "<ctrl>+<alt>+d",
    [string]$BackupStartStopHotkey = "",
    [string]$CopyBufferHotkey = "<ctrl>+<alt>+<end>",
    [string]$PasteAndClearHotkey = "<ctrl>+<alt>+s",
    [string]$CancelHotkey = "<ctrl>+<alt>+<backspace>",
    [string]$ClearBufferHotkey = "<ctrl>+<alt>+<page_down>",
    [int]$WhisperThreads = 4,
    [string]$Language = "en",
    [switch]$CreateStartupShortcut
)

$ErrorActionPreference = "Stop"

function Resolve-FirstExistingPath {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return (Resolve-Path $candidate).Path
        }
    }
    return $null
}

function Get-PythonCommand {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        return @{
            Exe = $py.Source
            Args = @("-3")
        }
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return @{
            Exe = $python.Source
            Args = @()
        }
    }

    throw "Python 3 was not found. Install Python 3 from python.org or the Microsoft Store, then rerun this script."
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$appDataDir = Join-Path $env:APPDATA "WhisperDictation"
$localAppDataDir = Join-Path $env:LOCALAPPDATA "WhisperDictation"
$venvDir = Join-Path $localAppDataDir "venv"
$configPath = Join-Path $appDataDir "config.json"
$requirementsPath = Join-Path $repoRoot "windows\requirements.txt"
$runnerPath = Join-Path $repoRoot "windows\whisper_dictation.py"
$startScriptPath = Join-Path $repoRoot "scripts\start-windows-dictation.ps1"
$salvageDir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "WhisperSalvage"
$tempDir = Join-Path $env:TEMP "WhisperDictation"

New-Item -ItemType Directory -Force -Path $appDataDir, $localAppDataDir, $salvageDir, $tempDir | Out-Null

if (-not $WhisperCliPath) {
    $rootCandidates = @()
    if ($WhisperCppRoot) {
        $rootCandidates += $WhisperCppRoot
    }
    $rootCandidates += @(
        (Join-Path $repoRoot "..\whisper.cpp"),
        (Join-Path $HOME "src\whisper.cpp"),
        (Join-Path $HOME "code\whisper.cpp"),
        (Join-Path $HOME "Downloads\whisper.cpp")
    )

    foreach ($root in $rootCandidates) {
        if (-not $root) { continue }
        $WhisperCliPath = Resolve-FirstExistingPath @(
            (Join-Path $root "build\bin\Release\whisper-cli.exe"),
            (Join-Path $root "build\bin\whisper-cli.exe"),
            (Join-Path $root "build\Release\bin\whisper-cli.exe"),
            (Join-Path $root "build\Release\whisper-cli.exe"),
            (Join-Path $root "main.exe")
        )
        if ($WhisperCliPath) {
            if (-not $WhisperCppRoot) {
                $WhisperCppRoot = (Resolve-Path $root).Path
            }
            break
        }
    }
}

if (-not $WhisperCliPath -or -not (Test-Path $WhisperCliPath)) {
    throw "Unable to find whisper-cli.exe. Set WHISPER_CPP_ROOT or pass -WhisperCliPath C:\path\to\whisper-cli.exe."
}
$WhisperCliPath = (Resolve-Path $WhisperCliPath).Path

if (-not $WhisperServerPath) {
    $cliDir = Split-Path -Parent $WhisperCliPath
    $WhisperServerPath = Resolve-FirstExistingPath @(
        (Join-Path $cliDir "whisper-server.exe"),
        (Join-Path (Split-Path -Parent $cliDir) "bin\Release\whisper-server.exe"),
        (Join-Path (Split-Path -Parent $cliDir) "bin\whisper-server.exe")
    )
}

if ($WhisperServerPath -and (Test-Path $WhisperServerPath)) {
    $WhisperServerPath = (Resolve-Path $WhisperServerPath).Path
}

if (-not $WhisperModelPath) {
    $modelRoot = if ($WhisperCppRoot) { $WhisperCppRoot } else { Split-Path -Parent (Split-Path -Parent $WhisperCliPath) }
    $WhisperModelPath = Resolve-FirstExistingPath @(
        (Join-Path $modelRoot "models\ggml-small.en.bin"),
        (Join-Path $modelRoot "models\ggml-base.en.bin"),
        (Join-Path $modelRoot "models\ggml-small.bin"),
        (Join-Path $modelRoot "models\ggml-base.bin")
    )
}

if (-not $WhisperModelPath -or -not (Test-Path $WhisperModelPath)) {
    throw "Unable to find a Whisper model. Set WHISPER_MODEL_PATH or pass -WhisperModelPath C:\path\to\ggml-small.en.bin."
}
$WhisperModelPath = (Resolve-Path $WhisperModelPath).Path

$pythonCommand = Get-PythonCommand
if (-not (Test-Path $venvDir)) {
    & $pythonCommand.Exe @($pythonCommand.Args) -m venv $venvDir
}

$venvPython = Join-Path $venvDir "Scripts\python.exe"
& $venvPython -m pip install --upgrade pip
& $venvPython -m pip install -r $requirementsPath

$config = [ordered]@{
    whisperCliPath = $WhisperCliPath
    whisperModelPath = $WhisperModelPath
    whisperServerPath = if ($WhisperServerPath) { $WhisperServerPath } else { $null }
    useWhisperServer = [bool]$WhisperServerPath
    whisperServerHost = "127.0.0.1"
    whisperServerPort = 8177
    serverRequestTimeoutSeconds = 30
    sampleRate = 16000
    channels = 1
    inputDevice = if ($InputDevice) { $InputDevice } else { $null }
    inputDeviceAutoProbeSeconds = 0.35
    prebufferMilliseconds = 1000
    blockMilliseconds = 40
    whisperThreads = $WhisperThreads
    language = $Language
    cliTimeoutSeconds = 90
    startStopHotkey = $StartStopHotkey
    backupStartStopHotkey = $BackupStartStopHotkey
    copyBufferHotkey = $CopyBufferHotkey
    pasteAndClearHotkey = $PasteAndClearHotkey
    cancelHotkey = $CancelHotkey
    clearBufferHotkey = $ClearBufferHotkey
    autoPaste = $false
    transcriptJoiner = " "
    pasteDelaySeconds = 0.4
    clearClipboardAfterPasteSeconds = 2.0
    keepRecentCaptures = $false
    recentCaptureLimit = 12
    tempDirectory = $tempDir
    salvageDirectory = $salvageDir
}

$config | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 $configPath

if ($CreateStartupShortcut) {
    $startupDir = [Environment]::GetFolderPath("Startup")
    $shortcutPath = Join-Path $startupDir "Whisper Dictation.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "powershell.exe"
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$startScriptPath`""
    $shortcut.WorkingDirectory = $repoRoot
    $shortcut.WindowStyle = 7
    $shortcut.Save()
    Write-Host "Created Startup shortcut at $shortcutPath"
}

Write-Host ""
Write-Host "Installed Windows dictation config to $configPath"
Write-Host "Using whisper CLI: $WhisperCliPath"
Write-Host "Using model: $WhisperModelPath"
Write-Host ""
Write-Host "Start dictation with:"
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$startScriptPath`""
Write-Host ""
Write-Host "Default hotkeys:"
Write-Host "  Start/stop recording: $StartStopHotkey"
Write-Host "  Backup start/stop:    $BackupStartStopHotkey"
Write-Host "  Copy transcript:      $CopyBufferHotkey"
Write-Host "  Paste and reset:      $PasteAndClearHotkey"
Write-Host "  Cancel recording:     $CancelHotkey"
Write-Host "  Clear transcript:     $ClearBufferHotkey"
Write-Host ""
Write-Host "To list microphone devices:"
Write-Host "  `"$venvPython`" `"$runnerPath`" --config `"$configPath`" list-devices"
Write-Host "To probe microphone levels:"
Write-Host "  `"$venvPython`" `"$runnerPath`" --config `"$configPath`" probe-devices"
