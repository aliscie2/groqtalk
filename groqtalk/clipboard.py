"""Clipboard read/write, simulate_paste, get_selected_text."""
from __future__ import annotations

import subprocess
import threading
import time

from AppKit import NSPasteboard, NSPasteboardTypeString
from ApplicationServices import AXUIElementCreateSystemWide, AXUIElementCopyAttributeValue
from Quartz import (
    CGEventSourceCreate, kCGEventSourceStateHIDSystemState,
    CGEventCreateKeyboardEvent, CGEventSetFlags, CGEventPost,
    kCGEventFlagMaskCommand, kCGHIDEventTap,
)

from .config import log


def clipboard_read() -> str:
    """Read clipboard via NSPasteboard."""
    pb = NSPasteboard.generalPasteboard()
    text = pb.stringForType_(NSPasteboardTypeString)
    return str(text) if text else ""


def clipboard_write(text: str) -> None:
    """Write to clipboard via NSPasteboard."""
    pb = NSPasteboard.generalPasteboard()
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)


def simulate_paste() -> bool:
    """Simulate Cmd+V -- try CGEvent first, fall back to AppleScript."""
    try:
        src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState)
        down = CGEventCreateKeyboardEvent(src, 9, True)
        up = CGEventCreateKeyboardEvent(src, 9, False)
        CGEventSetFlags(down, kCGEventFlagMaskCommand)
        CGEventSetFlags(up, kCGEventFlagMaskCommand)
        CGEventPost(kCGHIDEventTap, down)
        time.sleep(0.02)
        CGEventPost(kCGHIDEventTap, up)
        log.debug("[paste] Cmd+V via CGEvent posted")
        return True
    except Exception:
        log.debug("[paste] CGEvent failed, trying AppleScript fallback")
    try:
        script = 'tell application "System Events" to keystroke "v" using command down'
        subprocess.run(["osascript", "-e", script], capture_output=True, timeout=3)
        log.debug("[paste] Cmd+V via AppleScript OK")
        return True
    except Exception:
        log.exception("[paste] both paste methods failed")
        return False


def _clipboard_copy_fallback() -> str:
    """Fallback: simulate Cmd+C when Accessibility API doesn't work."""
    log.debug("[get_selected_text:fallback] using Cmd+C clipboard method")
    try:
        old_clipboard = clipboard_read()
        time.sleep(0.2)
        src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState)
        down = CGEventCreateKeyboardEvent(src, 8, True)
        up = CGEventCreateKeyboardEvent(src, 8, False)
        CGEventSetFlags(down, kCGEventFlagMaskCommand)
        CGEventSetFlags(up, kCGEventFlagMaskCommand)
        CGEventPost(kCGHIDEventTap, down)
        CGEventPost(kCGHIDEventTap, up)
        time.sleep(0.15)
        new_clipboard = clipboard_read().strip()
        log.debug(
            "[get_selected_text:fallback] got %d chars: %s",
            len(new_clipboard),
            repr(new_clipboard[:120]) if new_clipboard else "(empty)",
        )
        clipboard_write(old_clipboard)
        return new_clipboard
    except Exception:
        log.exception("[get_selected_text:fallback] failed")
        return ""


def get_selected_text() -> str:
    """Get selected text via macOS Accessibility API -- no Cmd+C needed."""
    log.debug(
        "[get_selected_text] called from thread=%s",
        threading.current_thread().name,
    )
    try:
        system_wide = AXUIElementCreateSystemWide()
        err, focused = AXUIElementCopyAttributeValue(
            system_wide, "AXFocusedUIElement", None,
        )
        if err or not focused:
            log.warning("[get_selected_text] no focused element (AX err=%d)", err)
            return _clipboard_copy_fallback()
        err, selected = AXUIElementCopyAttributeValue(
            focused, "AXSelectedText", None,
        )
        if err or not selected:
            log.debug(
                "[get_selected_text] no AXSelectedText (AX err=%d), trying fallback",
                err,
            )
            return _clipboard_copy_fallback()
        text = str(selected).strip()
        log.debug(
            "[get_selected_text] AX got %d chars: %s",
            len(text), repr(text[:120]) if text else "(empty)",
        )
        return text
    except Exception:
        log.exception("[get_selected_text] AX error, trying clipboard fallback")
        return _clipboard_copy_fallback()
