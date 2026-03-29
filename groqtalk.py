"""GroqTalk — voice-to-text and text-to-speech menubar app."""
from __future__ import annotations

import ctypes
import ctypes.util
import json
import logging
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timedelta

import io

import httpx
import numpy as np
import rumps
import sounddevice as sd
import soundfile as sf
from dotenv import load_dotenv
from groq import Groq

from AppKit import NSPasteboard, NSPasteboardTypeString
from AVFoundation import AVAudioPlayer
from Foundation import NSURL, NSData
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

load_dotenv()
_config_env = os.path.join(os.path.expanduser("~"), ".config", "groqtalk", ".env")
if os.path.exists(_config_env):
    load_dotenv(_config_env, override=True)

# --- Logging ---
_log_file = os.path.join(os.path.expanduser("~"), ".config", "groqtalk", "groqtalk.log")
os.makedirs(os.path.dirname(_log_file), exist_ok=True)
logging.basicConfig(
    level=logging.WARNING,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(_log_file, mode="w"),
    ],
)
log = logging.getLogger("groqtalk")
log.setLevel(logging.DEBUG)

# --- Constants ---
GROQ_API_KEY = os.getenv("GROQ_API_KEY")
SAMPLE_RATE = 16000
CHANNELS = 1
WHISPER_MODEL = "whisper-large-v3-turbo"
LLM_MODEL = "llama-3.3-70b-versatile"
LLM_SYSTEM_PROMPT = (
    "Fix the grammar, punctuation, and formatting of the following transcribed speech. "
    "Keep the original meaning. Return ONLY the cleaned text, nothing else. "
    "Do NOT add any new content, explanations, or elaboration. "
    "When the speaker lists points, steps, or items, format them as a structured list "
    "using markdown (e.g. **Point 1:** ...). Use line breaks between items for readability."
)
TTS_MODEL = "canopylabs/orpheus-v1-english"
TTS_VOICE = "hannah"
TTS_CHUNK_SIZE = 150  # chars per TTS chunk — smaller = faster first audio
SILENCE_THRESHOLD = 0.01  # amplitude below this is silence
LLM_SKIP_WORD_LIMIT = 100  # skip LLM cleanup for short transcripts
ICON_IDLE = "🎙"
ICON_RECORDING = "🔴"
ICON_PROCESSING = "⏳"
ICON_SPEAKING = "🔊"

# macOS virtual key codes
kVK_ANSI_A = 0x00
kVK_ANSI_D = 0x02
# Carbon modifier masks
cmdKey = 0x0100
shiftKey = 0x0200

# --- Groq client (HTTP/2 for connection multiplexing) ---
log.info("GROQ_API_KEY loaded: %s", "YES" if GROQ_API_KEY else "NO")
_ax_trusted = AXIsProcessTrusted()
log.info("Accessibility trusted: %s", _ax_trusted)
if not _ax_trusted:
    # Prompt macOS to show the Accessibility permission dialog
    from ApplicationServices import AXIsProcessTrustedWithOptions
    from Foundation import NSDictionary
    options = NSDictionary.dictionaryWithObject_forKey_(True, "AXTrustedCheckOptionPrompt")
    AXIsProcessTrustedWithOptions(options)
    log.info("Prompted user for Accessibility permission")
try:
    _http_client = httpx.Client(http2=True, timeout=30.0)
    groq_client = Groq(api_key=GROQ_API_KEY, http_client=_http_client)
    log.info("Groq client created with HTTP/2")
except Exception:
    groq_client = Groq(api_key=GROQ_API_KEY)
    log.info("Groq client created (HTTP/2 not available, using HTTP/1.1)")


# ---------------------------------------------------------------------------
# Carbon global hotkeys — NO Accessibility permission required
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
    ctypes.POINTER(_EventTypeSpec), ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p),
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
def _carbon_hotkey_callback(next_handler, event, user_data):
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


def _install_carbon_hotkey_handler():
    event_type = _EventTypeSpec(eventClass=_kEventClassKeyboard, eventKind=_kEventHotKeyPressed)
    status = _carbon.InstallEventHandler(
        _carbon.GetApplicationEventTarget(), _carbon_hotkey_callback,
        1, ctypes.byref(event_type), None, ctypes.byref(_carbon_handler_ref),
    )
    if status != 0:
        log.error("InstallEventHandler failed: %d", status)
    else:
        log.debug("Carbon event handler installed")


def register_hotkey(key_code: int, modifiers: int, hotkey_id: int, callback: callable):
    _hotkey_callbacks[hotkey_id] = callback
    hk_id = _EventHotKeyID(signature=0x4754, id=hotkey_id)
    ref = ctypes.c_void_p()
    status = _carbon.RegisterEventHotKey(
        key_code, modifiers, hk_id,
        _carbon.GetApplicationEventTarget(), 0, ctypes.byref(ref),
    )
    if status != 0:
        log.error("RegisterEventHotKey failed: %d (key=%d mod=%d)", status, key_code, modifiers)
    else:
        _hotkey_refs.append(ref)
        log.debug("Registered hotkey id=%d key=%d mod=%d", hotkey_id, key_code, modifiers)


def unregister_all_hotkeys():
    for ref in _hotkey_refs:
        _carbon.UnregisterEventHotKey(ref)
    _hotkey_refs.clear()
    _hotkey_callbacks.clear()


# ---------------------------------------------------------------------------
# Audio helpers — silence trimming, OGG encoding
# ---------------------------------------------------------------------------
def _trim_silence(audio: np.ndarray, threshold: float = SILENCE_THRESHOLD) -> np.ndarray:
    """Trim leading and trailing silence from audio."""
    abs_audio = np.abs(audio).flatten()
    above = np.where(abs_audio > threshold)[0]
    if len(above) == 0:
        return audio
    start, end = above[0], above[-1] + 1
    trimmed = audio[start:end]
    log.debug("[trim] %d → %d samples (removed %.1fs silence)",
              len(audio), len(trimmed), (len(audio) - len(trimmed)) / SAMPLE_RATE)
    return trimmed


def _encode_ogg(audio: np.ndarray, sample_rate: int = SAMPLE_RATE) -> bytes:
    """Encode audio to OGG/Vorbis in memory — much smaller than WAV."""
    buf = io.BytesIO()
    sf.write(buf, audio, sample_rate, format='OGG', subtype='VORBIS')
    ogg_bytes = buf.getvalue()
    return ogg_bytes


def _prepare_audio_for_whisper(audio_frames: list[np.ndarray]) -> tuple[bytes, str, float]:
    """Concatenate frames, trim silence, encode to OGG. Returns (bytes, mime, duration)."""
    t0 = time.time()
    audio = np.concatenate(audio_frames, axis=0)
    raw_duration = len(audio) / SAMPLE_RATE

    # Trim silence
    audio = _trim_silence(audio)
    trimmed_duration = len(audio) / SAMPLE_RATE

    # Convert float32 to int16 for encoding
    audio_int16 = (audio * 32767).astype(np.int16)

    # Encode to OGG (much smaller upload)
    ogg_bytes = _encode_ogg(audio_int16)

    prep_time = time.time() - t0
    log.info("[prep] %.1fs audio (trimmed from %.1fs) → %d bytes OGG in %.3fs",
             trimmed_duration, raw_duration, len(ogg_bytes), prep_time)
    return ogg_bytes, "audio/ogg", trimmed_duration


# ---------------------------------------------------------------------------
# Helpers — native macOS APIs (no keystroke simulation for reading text)
# ---------------------------------------------------------------------------
def _clipboard_read() -> str:
    """Read clipboard via NSPasteboard."""
    pb = NSPasteboard.generalPasteboard()
    text = pb.stringForType_(NSPasteboardTypeString)
    return str(text) if text else ""


def _clipboard_write(text: str) -> None:
    """Write to clipboard via NSPasteboard."""
    pb = NSPasteboard.generalPasteboard()
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)


def _simulate_paste() -> bool:
    """Simulate ⌘V via Quartz CGEvent to paste at cursor."""
    log.debug("[paste] simulating ⌘V via CGEvent...")
    try:
        src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState)
        down = CGEventCreateKeyboardEvent(src, 9, True)
        up = CGEventCreateKeyboardEvent(src, 9, False)
        CGEventSetFlags(down, kCGEventFlagMaskCommand)
        CGEventSetFlags(up, kCGEventFlagMaskCommand)
        CGEventPost(kCGHIDEventTap, down)
        CGEventPost(kCGHIDEventTap, up)
        log.debug("[paste] ⌘V posted OK")
        return True
    except Exception:
        log.exception("[paste] CGEvent ⌘V failed")
        return False


def get_selected_text() -> str:
    """Get selected text via macOS Accessibility API — no ⌘C needed."""
    log.debug("[get_selected_text] called from thread=%s", threading.current_thread().name)
    try:
        system_wide = AXUIElementCreateSystemWide()

        err, focused = AXUIElementCopyAttributeValue(system_wide, "AXFocusedUIElement", None)
        if err or not focused:
            log.warning("[get_selected_text] no focused element (AX err=%d)", err)
            return _get_selected_text_clipboard_fallback()

        err, selected = AXUIElementCopyAttributeValue(focused, "AXSelectedText", None)
        if err or not selected:
            log.debug("[get_selected_text] no AXSelectedText (AX err=%d), trying clipboard fallback", err)
            return _get_selected_text_clipboard_fallback()

        text = str(selected).strip()
        log.debug("[get_selected_text] AX got %d chars: %s", len(text), repr(text[:120]) if text else "(empty)")
        return text
    except Exception:
        log.exception("[get_selected_text] AX error, trying clipboard fallback")
        return _get_selected_text_clipboard_fallback()


def _get_selected_text_clipboard_fallback() -> str:
    """Fallback: simulate ⌘C when Accessibility API doesn't work for an app."""
    log.debug("[get_selected_text:fallback] using ⌘C clipboard method")
    try:
        old_clipboard = _clipboard_read()
        time.sleep(0.2)
        src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState)
        down = CGEventCreateKeyboardEvent(src, 8, True)
        up = CGEventCreateKeyboardEvent(src, 8, False)
        CGEventSetFlags(down, kCGEventFlagMaskCommand)
        CGEventSetFlags(up, kCGEventFlagMaskCommand)
        CGEventPost(kCGHIDEventTap, down)
        CGEventPost(kCGHIDEventTap, up)
        time.sleep(0.15)
        new_clipboard = _clipboard_read().strip()
        log.debug("[get_selected_text:fallback] got %d chars: %s", len(new_clipboard), repr(new_clipboard[:120]) if new_clipboard else "(empty)")
        _clipboard_write(old_clipboard)
        return new_clipboard
    except Exception:
        log.exception("[get_selected_text:fallback] failed")
        return ""


def _split_text_chunks(text: str, max_chars: int = TTS_CHUNK_SIZE) -> list[str]:
    """Split text into chunks at sentence boundaries for streaming TTS."""
    if len(text) <= max_chars:
        return [text]

    chunks = []
    remaining = text
    while remaining:
        if len(remaining) <= max_chars:
            chunks.append(remaining)
            break
        # Find last sentence end within max_chars
        segment = remaining[:max_chars]
        # Try splitting at sentence boundaries: . ! ? then newline, then comma
        split_at = -1
        for pattern in [r'[.!?]\s', r'\n', r',\s']:
            matches = list(re.finditer(pattern, segment))
            if matches:
                split_at = matches[-1].end()
                break
        if split_at == -1:
            # No good boundary — split at last space
            last_space = segment.rfind(' ')
            split_at = last_space if last_space > 0 else max_chars
        chunks.append(remaining[:split_at].strip())
        remaining = remaining[split_at:].strip()

    return [c for c in chunks if c]


# ---------------------------------------------------------------------------
# Usage tracking — local cost estimator
# ---------------------------------------------------------------------------
_USAGE_FILE = os.path.join(os.path.expanduser("~"), ".config", "groqtalk", "usage.json")

# Groq pricing (from groq.com/pricing, March 2025)
_PRICE_WHISPER_PER_SEC = 0.04 / 3600      # $0.04/hour audio
_PRICE_LLM_INPUT_PER_TOKEN = 0.59 / 1e6   # $0.59/M input tokens (exact)
_PRICE_LLM_OUTPUT_PER_TOKEN = 0.79 / 1e6  # $0.79/M output tokens (exact)
_PRICE_TTS_PER_CHAR = 22.00 / 1e6         # $22/M characters


def _load_usage() -> list[dict]:
    try:
        with open(_USAGE_FILE, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []


def _save_usage(entries: list[dict]) -> None:
    with open(_USAGE_FILE, "w") as f:
        json.dump(entries, f)


def _log_usage(kind: str, **kwargs) -> None:
    """Log a usage event with timestamp."""
    entries = _load_usage()
    entry = {"ts": datetime.now().isoformat(), "kind": kind, **kwargs}
    entries.append(entry)
    _save_usage(entries)


def _get_cost_last_n_days(days: int = 3) -> tuple[float, dict]:
    """Calculate estimated cost for last N days."""
    entries = _load_usage()
    cutoff = datetime.now() - timedelta(days=days)
    totals = {"whisper_sec": 0.0, "llm_in_tok": 0, "llm_out_tok": 0, "tts_chars": 0, "calls": 0}

    for e in entries:
        try:
            ts = datetime.fromisoformat(e["ts"])
        except (KeyError, ValueError):
            continue
        if ts < cutoff:
            continue
        totals["calls"] += 1
        if e.get("kind") == "whisper":
            totals["whisper_sec"] += e.get("audio_sec", 0)
        elif e.get("kind") == "llm":
            totals["llm_in_tok"] += e.get("input_tokens", 0)
            totals["llm_out_tok"] += e.get("output_tokens", 0)
        elif e.get("kind") == "tts":
            totals["tts_chars"] += e.get("chars", 0)

    cost = (
        totals["whisper_sec"] * _PRICE_WHISPER_PER_SEC
        + totals["llm_in_tok"] * _PRICE_LLM_INPUT_PER_TOKEN
        + totals["llm_out_tok"] * _PRICE_LLM_OUTPUT_PER_TOKEN
        + totals["tts_chars"] * _PRICE_TTS_PER_CHAR
    )
    return cost, totals


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
class GroqTalkApp(rumps.App):
    """Menubar app for voice-to-text and text-to-speech."""

    def __init__(self) -> None:
        super().__init__("GroqTalk", title=ICON_IDLE)
        self.recording = False
        self._audio_frames: list[np.ndarray] = []
        self._stream: sd.InputStream | None = None
        self._tts_generation: int = 0
        self._enhance_text = True  # LLM cleanup toggle
        self._enhance_item = rumps.MenuItem("Enhance Text (LLM)", callback=self._toggle_enhance)
        self._enhance_item.state = 1  # checkmark on
        self._playback_rate = 1.0
        self._speed_menu = rumps.MenuItem("Playback Speed")
        for rate in ["0.75x", "1.0x", "1.25x", "1.5x", "1.75x", "2.0x"]:
            item = rumps.MenuItem(rate, callback=self._set_speed)
            if rate == "1.0x":
                item.state = 1
            self._speed_menu.add(item)
        self._cost_item = rumps.MenuItem("Usage: $0.00 (3 days)")
        self._cost_item.set_callback(self._refresh_cost)
        self.menu = [
            rumps.MenuItem("Speech → Text  (⌘⇧A)"),
            rumps.MenuItem("Speak Selection  (⌘⇧D)"),
            None,
            self._enhance_item,
            self._speed_menu,
            self._cost_item,
        ]
        self._refresh_cost(None)
        self._setup_hotkeys()
        # Pre-warm Groq connection in background
        threading.Thread(target=self._warm_connection, daemon=True).start()
        log.info("GroqTalk started — look for %s in menu bar", ICON_IDLE)
        log.info("Hotkeys: ⌘⇧A (Record/STT) | ⌘⇧D (Speak selection)")

    def _warm_connection(self) -> None:
        """Pre-warm HTTP connection to Groq so first real call is faster."""
        try:
            t0 = time.time()
            groq_client.models.list()
            log.info("[WARM] Groq connection pre-warmed in %.2fs", time.time() - t0)
        except Exception:
            log.debug("[WARM] pre-warm failed (non-critical)")

    def _setup_hotkeys(self) -> None:
        _install_carbon_hotkey_handler()
        register_hotkey(kVK_ANSI_A, cmdKey | shiftKey, 1, self._toggle_recording)
        register_hotkey(kVK_ANSI_D, cmdKey | shiftKey, 2, self._speak_selected)

    # --- Speech-to-Text (live partial every 5s) ----------------------------

    LIVE_INTERVAL = 5.0  # seconds between live Whisper calls

    def _toggle_recording(self) -> None:
        log.info("[REC] ⌘⇧A pressed — recording=%s, thread=%s", self.recording, threading.current_thread().name)
        if self.recording:
            self._stop_recording()
        else:
            self._start_recording()

    def _start_recording(self) -> None:
        log.info("[REC] 🔴 starting recording...")
        self.recording = True
        self.title = ICON_RECORDING
        self._audio_frames = []
        self._live_transcript = ""
        try:
            self._stream = sd.InputStream(
                samplerate=SAMPLE_RATE, channels=CHANNELS,
                dtype="float32", callback=self._audio_callback,
            )
            self._stream.start()
            log.info("[REC] stream started — device=%s, samplerate=%d", sd.query_devices(sd.default.device[0])['name'], SAMPLE_RATE)
            # Start live transcription thread
            self._live_thread = threading.Thread(target=self._live_transcribe, daemon=True)
            self._live_thread.start()
        except Exception:
            log.exception("[REC] failed to start audio stream")
            self.recording = False
            self.title = ICON_IDLE

    def _audio_callback(self, indata, frames, time_info, status):
        if status:
            log.warning("[REC] audio callback status: %s", status)
        self._audio_frames.append(indata.copy())

    def _live_transcribe(self) -> None:
        """Every 5s, send only NEW audio to Whisper (not cumulative) and append to transcript."""
        log.info("[LIVE] live transcription thread started")
        last_frame_idx = 0
        parts: list[str] = []
        while self.recording:
            time.sleep(self.LIVE_INTERVAL)
            if not self.recording:
                break
            current_len = len(self._audio_frames)
            if current_len <= last_frame_idx:
                continue
            # Only send new frames since last call
            new_frames = self._audio_frames[last_frame_idx:current_len]
            last_frame_idx = current_len
            try:
                ogg_bytes, mime, duration = _prepare_audio_for_whisper(new_frames)
                if duration < 0.5:
                    continue
                t0 = time.time()
                transcription = groq_client.audio.transcriptions.create(
                    model=WHISPER_MODEL,
                    file=("audio.ogg", ogg_bytes, mime),
                    language="en",
                    response_format="text",
                )
                elapsed = time.time() - t0
                text = transcription.text.strip() if hasattr(transcription, 'text') else str(transcription).strip()
                if text:
                    parts.append(text)
                    self._live_transcript = " ".join(parts)
                    _clipboard_write(self._live_transcript)
                    _log_usage("whisper", audio_sec=duration)
                    log.info("[LIVE] NEW %.1fs audio (%d bytes OGG) → Whisper in %.2fs: %s | total so far: %s",
                             duration, len(ogg_bytes), elapsed, text[:80], self._live_transcript[:100])
            except Exception:
                log.exception("[LIVE] partial transcription error")
        log.info("[LIVE] live transcription thread stopped — %d parts collected", len(parts))

    def _stop_recording(self) -> None:
        log.info("[REC] ⏹ stopping — %d frames captured", len(self._audio_frames))
        self.recording = False
        if self._stream:
            self._stream.stop()
            self._stream.close()
        self.title = ICON_PROCESSING
        threading.Thread(target=self._process_audio, daemon=True).start()

    def _process_audio(self) -> None:
        pipeline_start = time.time()
        log.info("[STT] final pipeline started on thread=%s", threading.current_thread().name)
        try:
            if not self._audio_frames:
                log.warning("[STT] no audio frames captured")
                rumps.notification("GroqTalk", "", "No audio captured.")
                return

            ogg_bytes, mime, duration = _prepare_audio_for_whisper(self._audio_frames)
            log.info("[STT] audio: %.1fs, %d bytes OGG", duration, len(ogg_bytes))

            log.info("[STT] sending to Groq Whisper (%s)...", WHISPER_MODEL)
            t0 = time.time()
            transcription = groq_client.audio.transcriptions.create(
                model=WHISPER_MODEL,
                file=("audio.ogg", ogg_bytes, mime),
                language="en",
                response_format="text",
            )
            whisper_time = time.time() - t0
            raw_text = transcription.text.strip() if hasattr(transcription, 'text') else str(transcription).strip()
            log.info("[STT] Whisper done in %.2fs — raw transcript (%d chars): %s", whisper_time, len(raw_text), raw_text[:200])
            _log_usage("whisper", audio_sec=duration)

            if not raw_text.strip():
                log.warning("[STT] empty transcript, aborting")
                rumps.notification("GroqTalk", "", "No speech detected.")
                return

            word_count = len(raw_text.split())
            llm_time = 0.0

            if not self._enhance_text:
                cleaned_text = raw_text.strip()
                log.info("[STT] enhance OFF — skipping LLM")
            elif word_count < LLM_SKIP_WORD_LIMIT:
                cleaned_text = raw_text.strip()
                log.info("[STT] short text (%d words) — skipping LLM cleanup", word_count)
            else:
                log.info("[STT] long text (%d words) — sending to LLM (%s) for cleanup...", word_count, LLM_MODEL)
                t0 = time.time()
                completion = groq_client.chat.completions.create(
                    messages=[
                        {"role": "system", "content": LLM_SYSTEM_PROMPT},
                        {"role": "user", "content": raw_text},
                    ],
                    model=LLM_MODEL,
                    temperature=0.3,
                    max_tokens=2048,
                )
                llm_time = time.time() - t0
                cleaned_text = completion.choices[0].message.content.strip()
                usage = completion.usage
                _log_usage("llm", input_tokens=usage.prompt_tokens, output_tokens=usage.completion_tokens)
                log.info("[STT] LLM done in %.2fs — cleaned text (%d chars): %s", llm_time, len(cleaned_text), cleaned_text[:200])

            _clipboard_write(cleaned_text)
            log.debug("[STT] copied to clipboard, now auto-pasting...")
            if not _simulate_paste():
                log.warning("[STT] auto-paste failed — text is still in clipboard")
            total_time = time.time() - pipeline_start
            log.info("[STT] ✅ done in %.2fs (whisper=%.2fs, llm=%.2fs)", total_time, whisper_time, llm_time)
            self._refresh_cost(None)

        except Exception as e:
            log.exception("[STT] pipeline error")
            rumps.notification("GroqTalk", "Error", str(e)[:100])
        finally:
            self.title = ICON_IDLE

    # --- Text-to-Speech (chunked pipeline) --------------------------------

    def _speak_selected(self) -> None:
        was_speaking = self.title == ICON_SPEAKING
        self._tts_generation += 1
        gen = self._tts_generation
        subprocess.run(["pkill", "-f", "afplay"], capture_output=True)
        if was_speaking:
            # Already speaking — just stop, don't restart
            log.info("[TTS] ⌘⇧D pressed while speaking — stopped (gen=%d)", gen)
            self.title = ICON_IDLE
            return
        log.info("[TTS] ⌘⇧D pressed — gen=%d, starting TTS", gen)
        threading.Thread(target=self._run_tts, args=(gen,), daemon=True).start()

    def _run_tts(self, gen: int) -> None:
        pipeline_start = time.time()
        log.info("[TTS] gen=%d pipeline started on thread=%s", gen, threading.current_thread().name)
        try:
            text = get_selected_text()
            if self._tts_generation != gen:
                log.info("[TTS] gen=%d cancelled (current=%d), aborting", gen, self._tts_generation)
                return
            if not text.strip():
                log.warning("[TTS] gen=%d no text selected, aborting", gen)
                rumps.notification("GroqTalk", "", "No text selected.")
                return
            self.title = ICON_SPEAKING

            chunks = _split_text_chunks(text)
            log.info("[TTS] gen=%d text=%d chars → %d chunks", gen, len(text), len(chunks))

            for i, chunk in enumerate(chunks):
                if self._tts_generation != gen:
                    log.info("[TTS] gen=%d cancelled at chunk %d", gen, i)
                    break
                log.debug("[TTS] gen=%d chunk %d/%d (%d chars): %s...",
                          gen, i + 1, len(chunks), len(chunk), chunk[:60])

                # Stream WAV into memory, then play with AVAudioPlayer (native speed control)
                t0 = time.time()
                wav_data = b""

                with groq_client.audio.speech.with_streaming_response.create(
                    model=TTS_MODEL, voice=TTS_VOICE,
                    input=chunk, response_format="wav",
                ) as response:
                    for data in response.iter_bytes(chunk_size=8192):
                        if self._tts_generation != gen:
                            break
                        wav_data += data

                fetch_time = time.time() - t0
                log.info("[TTS] gen=%d chunk %d/%d fetched in %.2fs (%d bytes)",
                         gen, i + 1, len(chunks), fetch_time, len(wav_data))

                if self._tts_generation != gen or not wav_data:
                    break

                # Play with AVAudioPlayer — native rate control preserves pitch
                ns_data = NSData.dataWithBytes_length_(wav_data, len(wav_data))
                player, err = AVAudioPlayer.alloc().initWithData_error_(ns_data, None)
                if err or not player:
                    log.error("[TTS] gen=%d AVAudioPlayer init failed: %s", gen, err)
                    break
                player.setEnableRate_(True)
                player.setRate_(self._playback_rate)
                player.prepareToPlay()
                player.play()
                log.debug("[TTS] gen=%d playing chunk %d/%d at %.2fx via AVAudioPlayer",
                          gen, i + 1, len(chunks), self._playback_rate)

                # Wait for playback to finish (poll so we can cancel)
                while player.isPlaying():
                    if self._tts_generation != gen:
                        player.stop()
                        log.info("[TTS] gen=%d stopped playback", gen)
                        break
                    time.sleep(0.05)

                elapsed = time.time() - t0
                _log_usage("tts", chars=len(chunk))
                log.info("[TTS] gen=%d chunk %d/%d done in %.2fs (%d bytes streamed)",
                         gen, i + 1, len(chunks), elapsed, len(wav_data))

            total_time = time.time() - pipeline_start
            log.info("[TTS] gen=%d ✅ done in %.2fs", gen, total_time)
            self._refresh_cost(None)
        except Exception as e:
            log.exception("[TTS] gen=%d pipeline error", gen)
            rumps.notification("GroqTalk", "TTS Error", str(e)[:100])
        finally:
            if self._tts_generation == gen:
                self.title = ICON_IDLE

    # --- Lifecycle / UI ------------------------------------------------

    def _toggle_enhance(self, sender) -> None:
        """Toggle LLM text enhancement on/off."""
        self._enhance_text = not self._enhance_text
        sender.state = 1 if self._enhance_text else 0
        log.info("[UI] Enhance Text toggled: %s", "ON" if self._enhance_text else "OFF")

    def _set_speed(self, sender) -> None:
        """Set TTS playback speed."""
        self._playback_rate = float(sender.title.replace("x", ""))
        # Update checkmarks
        for item in self._speed_menu.values():
            item.state = 1 if item.title == sender.title else 0
        log.info("[UI] Playback speed set to %sx", self._playback_rate)

    def _refresh_cost(self, _sender) -> None:
        """Update cost display in menu."""
        cost, totals = _get_cost_last_n_days(3)
        self._cost_item.title = f"Usage: ${cost:.4f} (3 days) | {totals['calls']} calls"
        log.debug("[COST] $%.4f — whisper=%.0fs, llm=%d+%d tok, tts=%d chars, calls=%d",
                  cost, totals['whisper_sec'], totals['llm_in_tok'], totals['llm_out_tok'],
                  totals['tts_chars'], totals['calls'])

    def _quit(self, _sender):
        unregister_all_hotkeys()
        rumps.quit_app()


if __name__ == "__main__":
    GroqTalkApp().run()
