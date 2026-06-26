from __future__ import annotations

import argparse
import ctypes
import json
import math
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time
import tkinter as tk
import urllib.error
import urllib.request
import wave
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import pyperclip
import sounddevice as sd
from pynput import keyboard


if sys.platform == "win32":
    from ctypes import wintypes


APP_NAME = "WhisperDictation"
DEFAULT_SAMPLE_RATE = 16_000
DEFAULT_CHANNELS = 1
DEFAULT_CONFIG_PATH = Path(os.environ.get("APPDATA", Path.home())) / APP_NAME / "config.json"
DEFAULT_INPUT_DEVICE_PROBE_SECONDS = 0.35

PREFERRED_INPUT_HOST_APIS = ("Windows WASAPI", "Windows WDM-KS", "MME", "Windows DirectSound")
IGNORED_AUTO_INPUT_NAME_PARTS = (
    "mapper",
    "primary sound capture",
    "stereo mix",
    "speaker",
    "output",
)


MOD_ALT = 0x0001
MOD_CONTROL = 0x0002
MOD_SHIFT = 0x0004
MOD_WIN = 0x0008
WM_HOTKEY = 0x0312

VK_CODES = {
    "backspace": 0x08,
    "tab": 0x09,
    "enter": 0x0D,
    "return": 0x0D,
    "esc": 0x1B,
    "escape": 0x1B,
    "space": 0x20,
    "page_up": 0x21,
    "pageup": 0x21,
    "page_down": 0x22,
    "pagedown": 0x22,
    "end": 0x23,
    "home": 0x24,
    "left": 0x25,
    "up": 0x26,
    "right": 0x27,
    "down": 0x28,
    "insert": 0x2D,
    "delete": 0x2E,
}

for index in range(1, 13):
    VK_CODES[f"f{index}"] = 0x6F + index

for letter in "abcdefghijklmnopqrstuvwxyz":
    VK_CODES[letter] = ord(letter.upper())

for digit in "0123456789":
    VK_CODES[digit] = ord(digit)


@dataclass(frozen=True)
class DictationConfig:
    whisper_cli_path: Path
    whisper_model_path: Path
    whisper_server_path: Path | None = None
    use_whisper_server: bool = True
    whisper_server_host: str = "127.0.0.1"
    whisper_server_port: int = 8177
    server_request_timeout_seconds: float = 30.0
    sample_rate: int = DEFAULT_SAMPLE_RATE
    channels: int = DEFAULT_CHANNELS
    input_device: str | int | None = None
    input_device_auto_probe_seconds: float = DEFAULT_INPUT_DEVICE_PROBE_SECONDS
    prebuffer_milliseconds: int = 1000
    block_milliseconds: int = 40
    whisper_threads: int = 4
    language: str = "en"
    cli_timeout_seconds: float = 90.0
    start_stop_hotkey: str = "<ctrl>+<alt>+d"
    backup_start_stop_hotkey: str = ""
    copy_buffer_hotkey: str = "<ctrl>+<alt>+<end>"
    paste_and_clear_hotkey: str = "<ctrl>+<alt>+s"
    cancel_hotkey: str = "<ctrl>+<alt>+<backspace>"
    clear_buffer_hotkey: str = "<ctrl>+<alt>+<page_down>"
    auto_paste: bool = False
    transcript_joiner: str = " "
    paste_delay_seconds: float = 0.4
    clear_clipboard_after_paste_seconds: float = 2.0
    keep_recent_captures: bool = False
    recent_capture_limit: int = 12
    temp_directory: Path = Path(tempfile.gettempdir()) / APP_NAME
    salvage_directory: Path = Path.home() / "Documents" / "WhisperSalvage"

    @classmethod
    def load(cls, path: Path) -> "DictationConfig":
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        return cls(
            whisper_cli_path=Path(data["whisperCliPath"]),
            whisper_model_path=Path(data["whisperModelPath"]),
            whisper_server_path=Path(data["whisperServerPath"]) if data.get("whisperServerPath") else None,
            use_whisper_server=bool(data.get("useWhisperServer", True)),
            whisper_server_host=str(data.get("whisperServerHost", "127.0.0.1")),
            whisper_server_port=int(data.get("whisperServerPort", 8177)),
            server_request_timeout_seconds=float(data.get("serverRequestTimeoutSeconds", 30.0)),
            sample_rate=int(data.get("sampleRate", DEFAULT_SAMPLE_RATE)),
            channels=int(data.get("channels", DEFAULT_CHANNELS)),
            input_device=data.get("inputDevice"),
            input_device_auto_probe_seconds=float(data.get("inputDeviceAutoProbeSeconds", DEFAULT_INPUT_DEVICE_PROBE_SECONDS)),
            prebuffer_milliseconds=int(data.get("prebufferMilliseconds", 1000)),
            block_milliseconds=int(data.get("blockMilliseconds", 40)),
            whisper_threads=int(data.get("whisperThreads", 4)),
            language=str(data.get("language", "en")),
            cli_timeout_seconds=float(data.get("cliTimeoutSeconds", 90.0)),
            start_stop_hotkey=str(data.get("startStopHotkey", "<ctrl>+<alt>+d")),
            backup_start_stop_hotkey=str(data.get("backupStartStopHotkey", "")),
            copy_buffer_hotkey=str(data.get("copyBufferHotkey", "<ctrl>+<alt>+<end>")),
            paste_and_clear_hotkey=str(data.get("pasteAndClearHotkey", "<ctrl>+<alt>+s")),
            cancel_hotkey=str(data.get("cancelHotkey", "<ctrl>+<alt>+<backspace>")),
            clear_buffer_hotkey=str(data.get("clearBufferHotkey", "<ctrl>+<alt>+<page_down>")),
            auto_paste=bool(data.get("autoPaste", False)),
            transcript_joiner=str(data.get("transcriptJoiner", " ")),
            paste_delay_seconds=float(data.get("pasteDelaySeconds", 0.4)),
            clear_clipboard_after_paste_seconds=float(data.get("clearClipboardAfterPasteSeconds", 2.0)),
            keep_recent_captures=bool(data.get("keepRecentCaptures", False)),
            recent_capture_limit=int(data.get("recentCaptureLimit", 12)),
            temp_directory=Path(data.get("tempDirectory", Path(tempfile.gettempdir()) / APP_NAME)),
            salvage_directory=Path(data.get("salvageDirectory", Path.home() / "Documents" / "WhisperSalvage")),
        )

    def validate(self) -> None:
        if not self.whisper_cli_path.exists():
            raise RuntimeError(f"whisper-cli.exe not found: {self.whisper_cli_path}")
        if not self.whisper_model_path.exists():
            raise RuntimeError(f"Whisper model not found: {self.whisper_model_path}")
        if self.use_whisper_server and self.whisper_server_path is not None and not self.whisper_server_path.exists():
            raise RuntimeError(f"whisper-server.exe not found: {self.whisper_server_path}")
        if self.sample_rate <= 0:
            raise RuntimeError("sampleRate must be positive")
        if self.channels != 1:
            raise RuntimeError("Only mono capture is currently supported")
        if self.input_device_auto_probe_seconds < 0:
            raise RuntimeError("inputDeviceAutoProbeSeconds cannot be negative")
        if self.prebuffer_milliseconds < 0:
            raise RuntimeError("prebufferMilliseconds cannot be negative")
        if self.block_milliseconds <= 0:
            raise RuntimeError("blockMilliseconds must be positive")
        if self.whisper_threads <= 0:
            raise RuntimeError("whisperThreads must be positive")
        if self.cli_timeout_seconds <= 0:
            raise RuntimeError("cliTimeoutSeconds must be positive")
        if self.server_request_timeout_seconds <= 0:
            raise RuntimeError("serverRequestTimeoutSeconds must be positive")


@dataclass
class Capture:
    session_id: str
    started_at: float
    stopped_at: float
    prebuffer_milliseconds: float
    samples: np.ndarray


@dataclass(frozen=True)
class ResolvedInputDevice:
    device: int | str | None
    name: str
    sample_rate: int


@dataclass(frozen=True)
class InputDeviceProbe:
    index: int
    name: str
    host_api: str
    sample_rate: int
    peak: int
    rms: float
    error: str | None = None


def log(message: str) -> None:
    print(f"[whisper-dictation] {message}", flush=True)


def normalize_transcript(text: str) -> str:
    stripped = text.strip()
    if not stripped:
        return ""

    marker = stripped.upper().replace(" ", "").replace("_", "").replace("-", "")
    marker = marker.strip("[]()")
    if marker in {"BLANKAUDIO", "NOSPEECH", "SILENCE"}:
        return ""

    lines: list[str] = []
    for raw_line in stripped.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = " ".join(raw_line.split())
        for token in ("[BLANK_AUDIO]", "(BLANK_AUDIO)", "[NO_SPEECH]", "(NO_SPEECH)", "[NOSPEECH]", "(NOSPEECH)", "[SILENCE]", "(SILENCE)"):
            line = line.replace(token, " ")
        line = " ".join(line.split())
        if line:
            lines.append(line)

    cleaned = "\n".join(lines).strip()
    return cleaned if any(ch.isalnum() for ch in cleaned) else ""


def audio_metrics(samples: np.ndarray) -> tuple[float, float, bool]:
    if samples.size == 0:
        return -math.inf, -math.inf, True

    normalized = np.abs(samples.astype(np.float64)) / float(np.iinfo(np.int16).max)
    peak = float(np.max(normalized))
    rms = float(np.sqrt(np.mean(normalized * normalized)))
    peak_db = 20.0 * math.log10(peak) if peak > 0 else -math.inf
    rms_db = 20.0 * math.log10(rms) if rms > 0 else -math.inf
    return peak_db, rms_db, peak_db <= -50.0 and rms_db <= -55.0


def resample_int16_mono(samples: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    if samples.size == 0 or source_rate == target_rate:
        return samples

    output_size = int(round(samples.size * float(target_rate) / float(source_rate)))
    if output_size <= 0:
        return np.array([], dtype=np.int16)
    if samples.size == 1:
        return np.full(output_size, int(samples[0]), dtype=np.int16)

    source_positions = np.arange(samples.size, dtype=np.float64)
    target_positions = np.linspace(0, samples.size - 1, num=output_size, dtype=np.float64)
    resampled = np.interp(target_positions, source_positions, samples.astype(np.float64))
    return np.clip(np.rint(resampled), np.iinfo(np.int16).min, np.iinfo(np.int16).max).astype(np.int16)


def probe_input_device(index: int, seconds: float) -> InputDeviceProbe:
    devices = sd.query_devices()
    hostapis = sd.query_hostapis()
    device = devices[index]
    host_api = str(hostapis[int(device.get("hostapi", 0))].get("name", "unknown"))
    name = str(device.get("name", "input device"))
    sample_rate = int(round(float(device.get("default_samplerate") or DEFAULT_SAMPLE_RATE)))
    if sample_rate <= 0:
        sample_rate = DEFAULT_SAMPLE_RATE

    try:
        samples = sd.rec(
            max(1, int(seconds * sample_rate)),
            samplerate=sample_rate,
            channels=1,
            dtype="int16",
            device=index,
            blocking=True,
        )
        mono = np.asarray(samples[:, 0], dtype=np.int16)
        mono_for_metrics = mono.astype(np.int32)
        peak = int(np.max(np.abs(mono_for_metrics))) if mono.size else 0
        rms = float(np.sqrt(np.mean(mono.astype(np.float64) * mono.astype(np.float64)))) if mono.size else 0.0
        return InputDeviceProbe(index, name, host_api, sample_rate, peak, rms)
    except Exception as exc:
        return InputDeviceProbe(index, name, host_api, sample_rate, 0, 0.0, str(exc))


def parse_hotkey(hotkey: str) -> tuple[int, int]:
    modifiers = 0
    key_code: int | None = None

    for raw_part in hotkey.split("+"):
        part = raw_part.strip().lower()
        if part.startswith("<") and part.endswith(">"):
            part = part[1:-1]

        if part in {"ctrl", "control"}:
            modifiers |= MOD_CONTROL
        elif part == "alt":
            modifiers |= MOD_ALT
        elif part == "shift":
            modifiers |= MOD_SHIFT
        elif part in {"cmd", "win", "windows"}:
            modifiers |= MOD_WIN
        elif part in VK_CODES:
            if key_code is not None:
                raise RuntimeError(f"Hotkey has more than one non-modifier key: {hotkey}")
            key_code = VK_CODES[part]
        else:
            raise RuntimeError(f"Unsupported hotkey key: {raw_part}")

    if key_code is None:
        raise RuntimeError(f"Hotkey is missing a non-modifier key: {hotkey}")

    return modifiers, key_code


class NativeHotkeyLoop:
    def __init__(self) -> None:
        if sys.platform != "win32":
            raise RuntimeError("Native hotkeys are only available on Windows")
        self._user32 = ctypes.WinDLL("user32", use_last_error=True)
        self._callbacks: dict[int, tuple[str, Any]] = {}

    def register(self, hotkey_id: int, label: str, hotkey: str, callback: Any) -> None:
        modifiers, key_code = parse_hotkey(hotkey)
        if not self._user32.RegisterHotKey(None, hotkey_id, modifiers, key_code):
            error = ctypes.get_last_error()
            raise RuntimeError(f"Unable to register {label} hotkey {hotkey}; Windows error {error}")
        self._callbacks[hotkey_id] = (label, callback)

    def run(self) -> None:
        msg = wintypes.MSG()
        while self._user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
            if msg.message == WM_HOTKEY:
                callback_entry = self._callbacks.get(int(msg.wParam))
                if callback_entry is not None:
                    label, callback = callback_entry
                    try:
                        callback()
                    except Exception as exc:
                        log(f"{label} hotkey failed: {exc}")

    def unregister_all(self) -> None:
        for hotkey_id in list(self._callbacks):
            self._user32.UnregisterHotKey(None, hotkey_id)
        self._callbacks.clear()


class RecordingOverlay:
    def __init__(self) -> None:
        self._commands: queue.Queue[str] = queue.Queue()
        self._ready = threading.Event()
        self._thread = threading.Thread(target=self._run, name="recording-overlay", daemon=True)
        self._thread.start()
        self._ready.wait(timeout=5.0)

    def show(self) -> None:
        self._commands.put("show")

    def hide(self) -> None:
        self._commands.put("hide")

    def stop(self) -> None:
        self._commands.put("stop")

    def _run(self) -> None:
        root = tk.Tk()
        root.withdraw()
        root.title("Whisper Dictation")

        window = tk.Toplevel(root)
        window.withdraw()
        window.overrideredirect(True)
        window.attributes("-topmost", True)
        window.configure(bg="#171717")

        frame = tk.Frame(window, bg="#171717", padx=14, pady=9)
        frame.pack()

        dot = tk.Canvas(frame, width=16, height=16, bg="#171717", highlightthickness=0)
        dot.create_oval(3, 3, 13, 13, fill="#ff3333", outline="")
        dot.pack(side="left")

        label = tk.Label(
            frame,
            text="Recording",
            bg="#171717",
            fg="#ffffff",
            font=("Segoe UI", 12, "bold"),
        )
        label.pack(side="left", padx=(8, 0))

        def position_window() -> None:
            window.update_idletasks()
            width = window.winfo_reqwidth()
            height = window.winfo_reqheight()
            screen_width = window.winfo_screenwidth()
            screen_height = window.winfo_screenheight()
            x = int((screen_width - width) / 2)
            y = int(screen_height - height - 80)
            window.geometry(f"{width}x{height}+{x}+{y}")

        def pump() -> None:
            while True:
                try:
                    command = self._commands.get_nowait()
                except queue.Empty:
                    break

                if command == "show":
                    position_window()
                    window.deiconify()
                    window.lift()
                elif command == "hide":
                    window.withdraw()
                elif command == "stop":
                    root.destroy()
                    return

            root.after(50, pump)

        self._ready.set()
        root.after(50, pump)
        root.mainloop()


class WindowsDictationApp:
    def __init__(self, config: DictationConfig) -> None:
        self.config = config
        self.config.temp_directory.mkdir(parents=True, exist_ok=True)
        self.config.salvage_directory.mkdir(parents=True, exist_ok=True)

        ring_capacity = max(1, int(config.sample_rate * config.prebuffer_milliseconds / 1000))
        self._ring_buffer: deque[int] = deque(maxlen=ring_capacity)
        self._session_samples: list[np.ndarray] | None = None
        self._session_started_at: float | None = None
        self._session_prebuffer_ms = 0.0
        self._lock = threading.RLock()
        self._work_queue: queue.Queue[Capture | None] = queue.Queue()
        self._transcript_parts: list[str] = []
        self._pending_transcription_count = 0
        self._paste_and_clear_when_ready = False
        self._controller = keyboard.Controller()
        self._stream: sd.InputStream | None = None
        self._capture_sample_rate = config.sample_rate
        self._last_audio_warning_at = 0.0
        self._overlay = RecordingOverlay()
        self._server_process: subprocess.Popen[Any] | None = None
        self._worker = threading.Thread(target=self._worker_loop, name="transcription-worker", daemon=True)

    def run(self) -> None:
        self._worker.start()
        self._prewarm_server_if_needed()
        self._start_audio_stream()
        log(
            "Ready. "
            f"Toggle dictation: {self._toggle_hotkey_summary()}; "
            f"copy transcript: {self.config.copy_buffer_hotkey}; "
            f"paste and reset: {self.config.paste_and_clear_hotkey}; "
            f"cancel: {self.config.cancel_hotkey}; "
            f"clear transcript: {self.config.clear_buffer_hotkey}"
        )
        log("Keep this window open while using dictation.")

        hotkeys = NativeHotkeyLoop()
        try:
            hotkeys.register(1, "toggle recording", self.config.start_stop_hotkey, self.toggle_recording)
            if self.config.backup_start_stop_hotkey:
                hotkeys.register(2, "backup toggle recording", self.config.backup_start_stop_hotkey, self.toggle_recording)
            hotkeys.register(3, "copy transcript", self.config.copy_buffer_hotkey, self.copy_transcript_to_clipboard)
            hotkeys.register(4, "paste and reset transcript", self.config.paste_and_clear_hotkey, self.paste_transcript_and_clear)
            hotkeys.register(5, "cancel recording", self.config.cancel_hotkey, self.cancel_recording)
            hotkeys.register(6, "clear transcript", self.config.clear_buffer_hotkey, self.clear_transcript)
            log("Native Windows hotkeys registered.")
            hotkeys.run()
        finally:
            hotkeys.unregister_all()
            self.shutdown()

    def shutdown(self) -> None:
        self._work_queue.put(None)
        self._overlay.stop()
        self._stop_server()
        if self._stream is not None:
            self._stream.stop()
            self._stream.close()
            self._stream = None

    def _toggle_hotkey_summary(self) -> str:
        if self.config.backup_start_stop_hotkey:
            return f"{self.config.start_stop_hotkey} or {self.config.backup_start_stop_hotkey}"
        return self.config.start_stop_hotkey

    def toggle_recording(self) -> None:
        with self._lock:
            recording = self._session_samples is not None
        if recording:
            self.stop_recording(discard=False)
        else:
            self.start_recording()

    def cancel_recording(self) -> None:
        self.stop_recording(discard=True)

    def copy_transcript_to_clipboard(self) -> None:
        with self._lock:
            transcript = self._current_transcript_locked()

        if not transcript:
            log("Transcript buffer is empty.")
            return

        pyperclip.copy(transcript)
        log(f"Copied transcript buffer to clipboard ({len(transcript)} characters).")
        if self.config.auto_paste:
            self._paste_clipboard()
            log("Transcript pasted into the active app.")

    def paste_transcript_and_clear(self) -> None:
        with self._lock:
            transcript = self._current_transcript_locked()
            pending = self._has_pending_transcription_locked()

            if pending:
                self._paste_and_clear_when_ready = True
                log("Paste/reset requested. Waiting for transcription to finish.")
                return

        if transcript:
            self._schedule_paste_and_clear_transcript(transcript)
        else:
            log("Nothing to paste or clear.")

    def clear_transcript(self) -> None:
        with self._lock:
            self._transcript_parts.clear()
            self._paste_and_clear_when_ready = False
        pyperclip.copy("")
        log("Transcript buffer cleared.")

    def start_recording(self) -> None:
        with self._lock:
            if self._session_samples is not None:
                log("Already recording.")
                return

            prebuffer = np.array(self._ring_buffer, dtype=np.int16)
            self._session_samples = [prebuffer] if prebuffer.size else []
            self._session_started_at = time.time()
            self._session_prebuffer_ms = 1000.0 * prebuffer.size / self.config.sample_rate

        self._overlay.show()
        log(f"Recording started with {int(self._session_prebuffer_ms)} ms prebuffer.")

    def stop_recording(self, discard: bool) -> None:
        with self._lock:
            if self._session_samples is None or self._session_started_at is None:
                log("No active recording.")
                return

            samples = np.concatenate(self._session_samples) if self._session_samples else np.array([], dtype=np.int16)
            started_at = self._session_started_at
            prebuffer_ms = self._session_prebuffer_ms
            self._session_samples = None
            self._session_started_at = None
            self._session_prebuffer_ms = 0.0

        if discard:
            self._overlay.hide()
            log("Recording canceled.")
            return

        capture = Capture(
            session_id=str(int(time.time() * 1000)),
            started_at=started_at,
            stopped_at=time.time(),
            prebuffer_milliseconds=prebuffer_ms,
            samples=samples,
        )
        duration_ms = 1000.0 * capture.samples.size / self.config.sample_rate
        self._overlay.hide()
        log(f"Recording stopped. Captured {int(duration_ms)} ms; transcribing...")
        with self._lock:
            self._pending_transcription_count += 1
        self._work_queue.put(capture)

    def _start_audio_stream(self) -> None:
        resolved = self._resolve_input_device()
        self._capture_sample_rate = resolved.sample_rate
        blocksize = max(1, int(self._capture_sample_rate * self.config.block_milliseconds / 1000))
        self._stream = sd.InputStream(
            samplerate=self._capture_sample_rate,
            channels=self.config.channels,
            dtype="int16",
            blocksize=blocksize,
            device=resolved.device,
            callback=self._on_audio,
        )
        self._stream.start()
        rate_note = ""
        if self._capture_sample_rate != self.config.sample_rate:
            rate_note = f"; resampling to {self.config.sample_rate} Hz for Whisper"
        log(f"Audio input: {resolved.name} at {self._capture_sample_rate} Hz{rate_note}.")

    def _resolve_input_device(self) -> ResolvedInputDevice:
        configured = self.config.input_device
        if configured is None or configured == "":
            return self._auto_select_input_device()
        if isinstance(configured, int):
            return self._make_resolved_input_device(configured)
        if isinstance(configured, str) and configured.isdigit():
            return self._make_resolved_input_device(int(configured))

        devices = sd.query_devices()
        configured_lower = str(configured).lower()
        for index, device in enumerate(devices):
            if device.get("max_input_channels", 0) > 0 and configured_lower in str(device.get("name", "")).lower():
                return self._make_resolved_input_device(index)
        raise RuntimeError(f"Input device not found: {configured}")

    def _auto_select_input_device(self) -> ResolvedInputDevice:
        probe_seconds = self.config.input_device_auto_probe_seconds
        candidates = self._auto_input_candidates()
        if not candidates:
            return ResolvedInputDevice(None, "system default input", self.config.sample_rate)

        probes: list[InputDeviceProbe] = []
        if probe_seconds > 0:
            for index in candidates:
                probe = probe_input_device(index, probe_seconds)
                probes.append(probe)
                if probe.error is None and probe.peak > 256 and probe.rms > 10.0:
                    log(
                        "Auto-selected input device "
                        f"{probe.index}: {probe.name} via {probe.host_api} "
                        f"(peak {probe.peak}, rms {probe.rms:.1f})."
                    )
                    return ResolvedInputDevice(probe.index, f"{probe.index}: {probe.name}", probe.sample_rate)

            working = [probe for probe in probes if probe.error is None]
            audible = [probe for probe in working if probe.peak > 32 and probe.rms > 1.0]
            if audible:
                best = max(audible, key=lambda probe: (probe.rms, probe.peak))
                log(
                    "Auto-selected input device "
                    f"{best.index}: {best.name} via {best.host_api} "
                    f"(peak {best.peak}, rms {best.rms:.1f})."
                )
                return ResolvedInputDevice(best.index, f"{best.index}: {best.name}", best.sample_rate)

            if working:
                best = max(working, key=lambda probe: (probe.rms, probe.peak))
                log(
                    "No clearly active microphone was found during auto-probe; "
                    f"using {best.index}: {best.name} via {best.host_api} "
                    f"(peak {best.peak}, rms {best.rms:.1f})."
                )
                return ResolvedInputDevice(best.index, f"{best.index}: {best.name}", best.sample_rate)

        index = candidates[0]
        resolved = self._make_resolved_input_device(index)
        log(f"Using preferred input device without level probe: {resolved.name}.")
        return resolved

    def _auto_input_candidates(self) -> list[int]:
        devices = sd.query_devices()
        hostapis = sd.query_hostapis()
        candidates: list[int] = []
        wasapi_default_inputs = {
            int(api.get("default_input_device", -1))
            for api in hostapis
            if str(api.get("name", "")).lower() == "windows wasapi"
        }

        def add(index: int | None) -> None:
            if index is None or index < 0 or index in candidates:
                return
            device = devices[index]
            if device.get("max_input_channels", 0) <= 0:
                return
            name = str(device.get("name", "")).lower()
            if any(part in name for part in IGNORED_AUTO_INPUT_NAME_PARTS):
                return
            candidates.append(index)

        preferred_host_ranks = {name.lower(): rank for rank, name in enumerate(PREFERRED_INPUT_HOST_APIS)}

        def rank_device(item: tuple[int, dict[str, Any]]) -> tuple[int, int, int, str]:
            index, device = item
            host_name = str(hostapis[int(device.get("hostapi", 0))].get("name", "")).lower()
            wasapi_default_rank = 0 if index in wasapi_default_inputs else 1
            channels_rank = -int(device.get("max_input_channels", 0))
            return (
                preferred_host_ranks.get(host_name, len(preferred_host_ranks)),
                wasapi_default_rank,
                channels_rank,
                str(device.get("name", "")).lower(),
            )

        for index, device in sorted(enumerate(devices), key=rank_device):
            add(index)

        return candidates

    def _make_resolved_input_device(self, index: int) -> ResolvedInputDevice:
        device = sd.query_devices(index)
        sample_rate = int(round(float(device.get("default_samplerate") or self.config.sample_rate)))
        if sample_rate <= 0:
            sample_rate = self.config.sample_rate
        return ResolvedInputDevice(index, f"{index}: {device.get('name', 'input device')}", sample_rate)

    def _on_audio(self, indata: np.ndarray, _frames: int, _time_info: Any, status: sd.CallbackFlags) -> None:
        if status:
            now = time.time()
            if now - self._last_audio_warning_at >= 2.0:
                self._last_audio_warning_at = now
                log(f"Audio input warning: {status}")

        samples = np.asarray(indata[:, 0], dtype=np.int16).copy()
        samples = resample_int16_mono(samples, self._capture_sample_rate, self.config.sample_rate)
        if samples.size == 0:
            return
        with self._lock:
            self._ring_buffer.extend(int(sample) for sample in samples)
            if self._session_samples is not None:
                self._session_samples.append(samples)

    def _worker_loop(self) -> None:
        while True:
            capture = self._work_queue.get()
            if capture is None:
                return
            try:
                text = self._transcribe(capture)
                if text:
                    transcript = self._append_transcript(text)
                    pyperclip.copy(transcript)
                    log(f"Transcript chunk added and copied to clipboard ({len(transcript)} characters).")
                    if self.config.auto_paste:
                        self._paste_clipboard()
                        log("Transcript pasted into the active app.")
                else:
                    log("No speech detected.")
            except Exception as exc:
                salvage = self._save_salvage(capture, f"transcription-error: {exc}")
                log(f"Transcription failed: {exc}")
                log(f"Audio saved for review: {salvage}")
            finally:
                transcript_to_paste: str | None = None
                with self._lock:
                    self._pending_transcription_count = max(self._pending_transcription_count - 1, 0)
                    if self._paste_and_clear_when_ready and not self._has_pending_transcription_locked():
                        transcript_to_paste = self._current_transcript_locked()
                        self._paste_and_clear_when_ready = False

                if transcript_to_paste:
                    self._schedule_paste_and_clear_transcript(transcript_to_paste)
                elif transcript_to_paste == "":
                    log("Paste/reset was requested, but no transcript was available.")
                self._work_queue.task_done()

    def _transcribe(self, capture: Capture) -> str:
        peak_db, rms_db, probably_silent = audio_metrics(capture.samples)
        if probably_silent:
            log(f"Skipping likely silent capture (peak {peak_db:.1f} dBFS, rms {rms_db:.1f} dBFS).")
            return ""

        with tempfile.TemporaryDirectory(prefix="whisper-dictation-", dir=self.config.temp_directory) as temp_dir:
            temp_path = Path(temp_dir)
            wav_path = temp_path / f"{capture.session_id}.wav"
            output_base = temp_path / "transcript"
            self._write_wav(wav_path, capture.samples)

            if self.config.use_whisper_server and self.config.whisper_server_path:
                try:
                    return self._transcribe_via_server(wav_path)
                except Exception as exc:
                    log(f"Server transcription failed; falling back to CLI: {exc}")

            command = [
                str(self.config.whisper_cli_path),
                "-m",
                str(self.config.whisper_model_path),
                "-f",
                str(wav_path),
                "-t",
                str(self.config.whisper_threads),
                "-l",
                self.config.language,
                "-nt",
                "-np",
                "-otxt",
                "-of",
                str(output_base),
            ]
            result = subprocess.run(
                command,
                capture_output=True,
                text=True,
                timeout=self.config.cli_timeout_seconds,
                check=False,
            )
            if result.returncode != 0:
                details = (result.stderr or result.stdout or "whisper-cli failed").strip()
                raise RuntimeError(details)

            transcript_path = output_base.with_suffix(".txt")
            if transcript_path.exists():
                raw_text = transcript_path.read_text(encoding="utf-8", errors="replace")
            else:
                raw_text = result.stdout

            text = normalize_transcript(raw_text)
            if self.config.keep_recent_captures:
                self._save_recent_capture(capture, text)
            return text

    def _prewarm_server_if_needed(self) -> None:
        if not self.config.use_whisper_server or not self.config.whisper_server_path:
            return
        threading.Thread(target=self._ensure_server_ready, name="whisper-server-prewarm", daemon=True).start()

    def _ensure_server_ready(self) -> None:
        if self._server_healthy():
            return

        if self._server_process is None or self._server_process.poll() is not None:
            log("Starting resident whisper-server...")
            log_path = self.config.temp_directory / "whisper-server.log"
            log_handle = log_path.open("ab")
            self._server_process = subprocess.Popen(
                [
                    str(self.config.whisper_server_path),
                    "-m",
                    str(self.config.whisper_model_path),
                    "--host",
                    self.config.whisper_server_host,
                    "--port",
                    str(self.config.whisper_server_port),
                    "-t",
                    str(self.config.whisper_threads),
                    "-nt",
                ],
                stdout=log_handle,
                stderr=log_handle,
            )

        deadline = time.time() + 15.0
        while time.time() < deadline:
            if self._server_healthy():
                log("Resident whisper-server is ready.")
                return
            time.sleep(0.1)
        raise RuntimeError("whisper-server did not become ready")

    def _server_healthy(self) -> bool:
        url = f"http://{self.config.whisper_server_host}:{self.config.whisper_server_port}/"
        try:
            with urllib.request.urlopen(url, timeout=0.3) as response:
                return response.status == 200
        except Exception:
            return False

    def _transcribe_via_server(self, wav_path: Path) -> str:
        self._ensure_server_ready()
        boundary = f"Boundary-{int(time.time() * 1000)}"
        body = bytearray()
        body.extend(self._multipart_field(boundary, "response_format", "json"))
        body.extend(self._multipart_field(boundary, "no_timestamps", "true"))
        body.extend(self._multipart_field(boundary, "temperature", "0.0"))
        body.extend(self._multipart_file(boundary, "file", wav_path.name, "audio/wav", wav_path.read_bytes()))
        body.extend(f"--{boundary}--\r\n".encode("utf-8"))

        request = urllib.request.Request(
            f"http://{self.config.whisper_server_host}:{self.config.whisper_server_port}/inference",
            data=bytes(body),
            method="POST",
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        with urllib.request.urlopen(request, timeout=self.config.server_request_timeout_seconds) as response:
            payload = json.loads(response.read().decode("utf-8", errors="replace"))
        return normalize_transcript(str(payload.get("text", "")))

    def _multipart_field(self, boundary: str, name: str, value: str) -> bytes:
        return (
            f"--{boundary}\r\n"
            f"Content-Disposition: form-data; name=\"{name}\"\r\n\r\n"
            f"{value}\r\n"
        ).encode("utf-8")

    def _multipart_file(self, boundary: str, name: str, filename: str, mime_type: str, data: bytes) -> bytes:
        return (
            f"--{boundary}\r\n"
            f"Content-Disposition: form-data; name=\"{name}\"; filename=\"{filename}\"\r\n"
            f"Content-Type: {mime_type}\r\n\r\n"
        ).encode("utf-8") + data + b"\r\n"

    def _stop_server(self) -> None:
        if self._server_process is None:
            return
        if self._server_process.poll() is None:
            self._server_process.terminate()
            try:
                self._server_process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self._server_process.kill()
        self._server_process = None

    def _write_wav(self, path: Path, samples: np.ndarray) -> None:
        with wave.open(str(path), "wb") as wav_file:
            wav_file.setnchannels(self.config.channels)
            wav_file.setsampwidth(2)
            wav_file.setframerate(self.config.sample_rate)
            wav_file.writeframes(samples.astype(np.int16).tobytes())

    def _paste_clipboard(self) -> None:
        time.sleep(0.05)
        with self._controller.pressed(keyboard.Key.ctrl):
            self._controller.press("v")
            self._controller.release("v")

    def _schedule_paste_and_clear_transcript(self, transcript: str) -> None:
        threading.Thread(
            target=self._paste_and_clear_transcript,
            args=(transcript,),
            name="paste-and-clear",
            daemon=True,
        ).start()
        log("Paste/reset scheduled.")

    def _paste_and_clear_transcript(self, transcript: str) -> None:
        pyperclip.copy(transcript)
        time.sleep(max(self.config.paste_delay_seconds, 0.0))
        self._paste_clipboard()
        log("Paste command sent.")
        time.sleep(max(self.config.clear_clipboard_after_paste_seconds, 0.0))
        with self._lock:
            self._transcript_parts.clear()
            self._paste_and_clear_when_ready = False
        pyperclip.copy("")
        log("Pasted transcript, cleared transcript buffer, and cleared clipboard.")

    def _append_transcript(self, text: str) -> str:
        with self._lock:
            self._transcript_parts.append(text)
            return self._current_transcript_locked()

    def _current_transcript_locked(self) -> str:
        parts = [part.strip() for part in self._transcript_parts if part.strip()]
        return self.config.transcript_joiner.join(parts).strip()

    def _has_pending_transcription_locked(self) -> bool:
        return self._pending_transcription_count > 0

    def _save_salvage(self, capture: Capture, reason: str) -> Path:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        wav_path = self.config.salvage_directory / f"whisper-{stamp}-{capture.session_id}.wav"
        note_path = self.config.salvage_directory / f"whisper-{stamp}-{capture.session_id}.txt"
        self._write_wav(wav_path, capture.samples)
        note_path.write_text(reason + "\n", encoding="utf-8")
        return wav_path

    def _save_recent_capture(self, capture: Capture, transcript: str) -> None:
        recent_dir = self.config.salvage_directory / "recent"
        recent_dir.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S")
        wav_path = recent_dir / f"recent-{stamp}-{capture.session_id}.wav"
        json_path = recent_dir / f"recent-{stamp}-{capture.session_id}.json"
        self._write_wav(wav_path, capture.samples)
        payload = {
            "sessionId": capture.session_id,
            "text": transcript,
            "prebufferMilliseconds": capture.prebuffer_milliseconds,
            "audioDurationMilliseconds": 1000.0 * capture.samples.size / self.config.sample_rate,
        }
        json_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        self._trim_recent_captures(recent_dir)

    def _trim_recent_captures(self, recent_dir: Path) -> None:
        wavs = sorted(recent_dir.glob("recent-*.wav"), key=lambda path: path.stat().st_mtime, reverse=True)
        for stale in wavs[self.config.recent_capture_limit :]:
            stale.unlink(missing_ok=True)
            stale.with_suffix(".json").unlink(missing_ok=True)


def list_devices() -> None:
    devices = sd.query_devices()
    hostapis = sd.query_hostapis()
    for index, device in enumerate(devices):
        if device.get("max_input_channels", 0) > 0:
            host_api = hostapis[int(device.get("hostapi", 0))].get("name", "unknown")
            sample_rate = int(round(float(device.get("default_samplerate") or DEFAULT_SAMPLE_RATE)))
            print(
                f"{index}: {device['name']} "
                f"({device['max_input_channels']} input channels, {host_api}, default {sample_rate} Hz)"
            )


def probe_devices(seconds: float = DEFAULT_INPUT_DEVICE_PROBE_SECONDS) -> None:
    devices = sd.query_devices()
    for index, device in enumerate(devices):
        if device.get("max_input_channels", 0) <= 0:
            continue
        probe = probe_input_device(index, seconds)
        if probe.error:
            print(
                f"{probe.index}: ERROR {probe.error} "
                f"({probe.host_api}, default {probe.sample_rate} Hz) - {probe.name}"
            )
        else:
            print(
                f"{probe.index}: peak={probe.peak} rms={probe.rms:.1f} "
                f"({probe.host_api}, default {probe.sample_rate} Hz) - {probe.name}"
            )


def write_default_config(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise RuntimeError(f"Config already exists: {path}")
    payload = {
        "whisperCliPath": "C:/path/to/whisper-cli.exe",
        "whisperModelPath": "C:/path/to/ggml-small.en.bin",
        "whisperServerPath": "C:/path/to/whisper-server.exe",
        "useWhisperServer": True,
        "whisperServerHost": "127.0.0.1",
        "whisperServerPort": 8177,
        "serverRequestTimeoutSeconds": 30,
        "sampleRate": DEFAULT_SAMPLE_RATE,
        "channels": DEFAULT_CHANNELS,
        "inputDevice": None,
        "inputDeviceAutoProbeSeconds": DEFAULT_INPUT_DEVICE_PROBE_SECONDS,
        "prebufferMilliseconds": 1000,
        "blockMilliseconds": 40,
        "whisperThreads": 4,
        "language": "en",
        "cliTimeoutSeconds": 90,
        "startStopHotkey": "<ctrl>+<alt>+d",
        "backupStartStopHotkey": "",
        "copyBufferHotkey": "<ctrl>+<alt>+<end>",
        "pasteAndClearHotkey": "<ctrl>+<alt>+s",
        "cancelHotkey": "<ctrl>+<alt>+<backspace>",
        "clearBufferHotkey": "<ctrl>+<alt>+<page_down>",
        "autoPaste": False,
        "transcriptJoiner": " ",
        "pasteDelaySeconds": 0.4,
        "clearClipboardAfterPasteSeconds": 2.0,
        "keepRecentCaptures": False,
        "recentCaptureLimit": 12,
        "tempDirectory": str(Path(tempfile.gettempdir()) / APP_NAME).replace("\\", "/"),
        "salvageDirectory": str(Path.home() / "Documents" / "WhisperSalvage").replace("\\", "/"),
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def load_config_or_exit(path: Path) -> DictationConfig:
    if not path.exists():
        raise RuntimeError(f"Config not found: {path}. Run scripts/install-windows.ps1 first.")
    config = DictationConfig.load(path)
    config.validate()
    return config


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Windows hotkey dictation for whisper.cpp")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG_PATH, help="Path to config.json")
    subparsers = parser.add_subparsers(dest="command")
    subparsers.add_parser("run", help="Run the hotkey dictation app")
    subparsers.add_parser("list-devices", help="List usable input devices")
    probe_parser = subparsers.add_parser("probe-devices", help="Record a short local level probe for each input device")
    probe_parser.add_argument("--seconds", type=float, default=DEFAULT_INPUT_DEVICE_PROBE_SECONDS)
    subparsers.add_parser("write-default-config", help="Create a starter config file")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    command = args.command or "run"
    try:
        if command == "list-devices":
            list_devices()
            return 0
        if command == "probe-devices":
            probe_devices(args.seconds)
            return 0
        if command == "write-default-config":
            write_default_config(args.config)
            log(f"Wrote {args.config}")
            return 0
        if command == "run":
            config = load_config_or_exit(args.config)
            app = WindowsDictationApp(config)
            app.run()
            return 0
        raise RuntimeError(f"Unknown command: {command}")
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        print(f"whisper-dictation: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
