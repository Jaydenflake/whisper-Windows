$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$venvPython = Join-Path $env:LOCALAPPDATA "WhisperDictation\venv\Scripts\python.exe"
$configPath = Join-Path $env:APPDATA "WhisperDictation\config.json"
$scriptPath = Join-Path $repoRoot "windows\whisper_dictation.py"

if (-not (Test-Path $venvPython)) {
    throw "Virtual environment not found at $venvPython. Run scripts\install-windows.ps1 first."
}

& $venvPython $scriptPath --config $configPath run
