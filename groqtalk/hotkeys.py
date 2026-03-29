"""Carbon global hotkey registration (ctypes Carbon bindings)."""
from __future__ import annotations

import ctypes
import ctypes.util

from .config import log

# ---------------------------------------------------------------------------
# Carbon global hotkeys -- NO Accessibility permission required
# ---------------------------------------------------------------------------
_carbon = ctypes.cdll.LoadLibrary(ctypes.util.find_library("Carbon"))


class _EventHotKeyID(ctypes.Structure):
    _fields_ = [("signature", ctypes.c_uint32), ("id", ctypes.c_uint32)]


class _EventTypeSpec(ctypes.Structure):
    _fields_ = [("eventClass", ctypes.c_uint32), ("eventKind", ctypes.c_uint32)]


_EventHandlerProcPtr = ctypes.CFUNCTYPE(
    ctypes.c_int32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p
)

_carbon.GetApplicationEventTarget.argtypes = []
_carbon.GetApplicationEventTarget.restype = ctypes.c_void_p

_carbon.InstallEventHandler.argtypes = [
    ctypes.c_void_p, _EventHandlerProcPtr, ctypes.c_uint32,
    ctypes.POINTER(_EventTypeSpec), ctypes.c_void_p,
    ctypes.POINTER(ctypes.c_void_p),
]
_carbon.InstallEventHandler.restype = ctypes.c_int32

_carbon.RegisterEventHotKey.argtypes = [
    ctypes.c_uint32, ctypes.c_uint32, _EventHotKeyID, ctypes.c_void_p,
    ctypes.c_uint32, ctypes.POINTER(ctypes.c_void_p),
]
_carbon.RegisterEventHotKey.restype = ctypes.c_int32

_carbon.UnregisterEventHotKey.argtypes = [ctypes.c_void_p]
_carbon.UnregisterEventHotKey.restype = ctypes.c_int32

_carbon.GetEventParameter.argtypes = [
    ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
    ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p,
]
_carbon.GetEventParameter.restype = ctypes.c_int32

_kEventClassKeyboard = 0x6B657962
_kEventHotKeyPressed = 5
_kEventParamDirectObject = 0x2D2D2D2D
_typeEventHotKeyID = 0x686B6964

_hotkey_callbacks: dict[int, callable] = {}
_hotkey_refs: list[ctypes.c_void_p] = []
_carbon_handler_ref = ctypes.c_void_p()


@_EventHandlerProcPtr
def _carbon_hotkey_callback(
    next_handler: ctypes.c_void_p,
    event: ctypes.c_void_p,
    user_data: ctypes.c_void_p,
) -> int:
    try:
        hk_id = _EventHotKeyID()
        _carbon.GetEventParameter(
            event, _kEventParamDirectObject, _typeEventHotKeyID,
            None, ctypes.sizeof(hk_id), None, ctypes.byref(hk_id),
        )
        cb = _hotkey_callbacks.get(hk_id.id)
        if cb:
            cb()
    except Exception:
        log.exception("Error in hotkey callback")
    return 0


def install_carbon_hotkey_handler() -> None:
    """Install the Carbon event handler for hotkey events."""
    event_type = _EventTypeSpec(
        eventClass=_kEventClassKeyboard, eventKind=_kEventHotKeyPressed,
    )
    status = _carbon.InstallEventHandler(
        _carbon.GetApplicationEventTarget(), _carbon_hotkey_callback,
        1, ctypes.byref(event_type), None, ctypes.byref(_carbon_handler_ref),
    )
    if status != 0:
        log.error("InstallEventHandler failed: %d", status)
    else:
        log.debug("Carbon event handler installed")


def register_hotkey(
    key_code: int, modifiers: int, hotkey_id: int, callback: callable,
) -> None:
    """Register a single global hotkey with a callback."""
    _hotkey_callbacks[hotkey_id] = callback
    hk_id = _EventHotKeyID(signature=0x4754, id=hotkey_id)
    ref = ctypes.c_void_p()
    status = _carbon.RegisterEventHotKey(
        key_code, modifiers, hk_id,
        _carbon.GetApplicationEventTarget(), 0, ctypes.byref(ref),
    )
    if status != 0:
        log.error(
            "RegisterEventHotKey failed: %d (key=%d mod=%d)",
            status, key_code, modifiers,
        )
    else:
        _hotkey_refs.append(ref)
        log.debug("Registered hotkey id=%d key=%d mod=%d", hotkey_id, key_code, modifiers)


def unregister_all_hotkeys() -> None:
    """Unregister all previously registered hotkeys."""
    for ref in _hotkey_refs:
        _carbon.UnregisterEventHotKey(ref)
    _hotkey_refs.clear()
    _hotkey_callbacks.clear()
