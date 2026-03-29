"""Clipboard read/write, paste simulation, get selected text."""
from __future__ import annotations

import threading
import time

from AppKit import NSPasteboard, NSPasteboardTypeString
from ApplicationServices import (
    AXUIElementCreateSystemWide,
    AXUIElementCopyAttributeValue,
    AXIsProcessTrusted,
)
from Quartz import (
    CGEventSourceCreate, kCGEventSourceStateHIDSystemState,
    CGEventCreateKeyboardEvent, CGEventSetFlags, CGEventPost,
    kCGEventFlagMaskCommand, kCGHIDEventTap,
)

from .config import log

# Virtual key codes for C and V
_kVK_ANSI_C: int = 0x08
_kVK_ANSI_V: int = 0x09


def clipboard_read() -> str:
    """Read string from NSPasteboard."""
    pb = NSPasteboard.generalPasteboard()
    text = pb.stringForType_(NSPasteboardTypeString)
    return str(text) if text else ""


def clipboard_write(text: str) -> None:
    """Write string to NSPasteboard."""
    pb = NSPasteboard.generalPasteboard()
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)


def _cg_keystroke(key_code: int) -> bool:
    """Send Cmd+key via CGEvent. Returns True on success."""
    try:
        src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState)
        down = CGEventCreateKeyboardEvent(src, key_code, True)
        up = CGEventCreateKeyboardEvent(src, key_code, False)
        CGEventSetFlags(down, kCGEventFlagMaskCommand)
        CGEventSetFlags(up, kCGEventFlagMaskCommand)
        CGEventPost(kCGHIDEventTap, down)
        time.sleep(0.02)
        CGEventPost(kCGHIDEventTap, up)
        return True
    except Exception:
        return False


def simulate_paste() -> bool:
    """Simulate Cmd+V via CGEvent if Accessibility is trusted.

    If not trusted, skip silently -- text is already in clipboard.
    """
    if not AXIsProcessTrusted():
        log.info("[paste] Accessibility not trusted -- skipping (text in clipboard)")
        return False
    ok = _cg_keystroke(_kVK_ANSI_V)
    if ok:
        log.debug("[paste] Cmd+V via CGEvent OK")
    else:
        log.warning("[paste] CGEvent paste failed")
    return ok


def get_selected_text() -> str:
    """Get selected text via AX API, falling back to Cmd+C clipboard grab."""
    log.debug("[get_selected_text] thread=%s", threading.current_thread().name)
    if AXIsProcessTrusted():
        text = _get_via_ax()
        if text:
            return text
    return _get_via_clipboard_copy()


def _get_via_ax() -> str:
    """Read AXSelectedText from the focused element."""
    try:
        sys_wide = AXUIElementCreateSystemWide()
        err, focused = AXUIElementCopyAttributeValue(
            sys_wide, "AXFocusedUIElement", None,
        )
        if err or not focused:
            return ""
        err, selected = AXUIElementCopyAttributeValue(
            focused, "AXSelectedText", None,
        )
        if err or not selected:
            return ""
        text = str(selected).strip()
        if text:
            log.debug("[get_selected_text] AX got %d chars", len(text))
        return text
    except Exception:
        log.debug("[get_selected_text] AX failed")
        return ""


def _get_via_clipboard_copy() -> str:
    """Simulate Cmd+C, read clipboard, restore original clipboard."""
    if not AXIsProcessTrusted():
        log.info("[get_selected_text] no Accessibility -- cannot simulate Cmd+C")
        return ""
    old = clipboard_read()
    ok = _cg_keystroke(_kVK_ANSI_C)
    if not ok:
        return ""
    time.sleep(0.15)
    new_text = clipboard_read().strip()
    clipboard_write(old)
    log.debug("[get_selected_text] Cmd+C fallback got %d chars", len(new_text))
    return new_text
