from __future__ import annotations

import ctypes
import sys
from ctypes import wintypes


MOD_ALT = 0x0001
MOD_CONTROL = 0x0002
MOD_SHIFT = 0x0004
MOD_WIN = 0x0008
WM_HOTKEY = 0x0312

HOTKEYS = {
    1: ("Ctrl+Alt+Left", MOD_CONTROL | MOD_ALT, 0x25),
    2: ("Ctrl+Alt+Home", MOD_CONTROL | MOD_ALT, 0x24),
    3: ("Ctrl+Alt+Space", MOD_CONTROL | MOD_ALT, 0x20),
    4: ("Ctrl+Alt+D", MOD_CONTROL | MOD_ALT, ord("D")),
}


def main() -> int:
    if sys.platform != "win32":
        print("hotkey_probe.py only runs on Windows.", file=sys.stderr)
        return 1

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    registered: list[int] = []

    for hotkey_id, (name, modifiers, key_code) in HOTKEYS.items():
        if user32.RegisterHotKey(None, hotkey_id, modifiers, key_code):
            registered.append(hotkey_id)
            print(f"registered: {name}", flush=True)
        else:
            print(f"failed: {name} Windows error {ctypes.get_last_error()}", flush=True)

    if not registered:
        print("No hotkeys registered.", flush=True)
        return 1

    print("Press one of the registered hotkeys. Press Ctrl+C in this window to stop.", flush=True)
    msg = wintypes.MSG()
    try:
        while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
            if msg.message == WM_HOTKEY:
                name = HOTKEYS.get(int(msg.wParam), ("unknown", 0, 0))[0]
                print(f"fired: {name}", flush=True)
    except KeyboardInterrupt:
        return 130
    finally:
        for hotkey_id in registered:
            user32.UnregisterHotKey(None, hotkey_id)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
