"""GroqTalk — voice-to-text and text-to-speech menubar app."""
from __future__ import annotations

import ctypes
import ctypes.util
import logging
import os
import subprocess
import sys
import tempfile
import threading
import time

import numpy as np
import pyperclip
import rumps
import sounddevice as sd
from dotenv import load_dotenv
from groq import Groq
from scipy.io.wavfile import write as write_wav

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
LLM_MODEL = "llama-3.1-8b-instant"
LLM_SYSTEM_PROMPT = (
    "Fix the grammar, punctuation, and formatting of the following transcribed speech. "
    "Keep the original meaning. Return only the cleaned text, nothing else. "
    "When the speaker lists points, steps, or items, format them as a structured list "
    "using markdown (e.g. **Point 1:** ...). Use line breaks between items for readability."
)
TTS_MODEL = "canopylabs/orpheus-v1-english"
TTS_VOICE = "troy"
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

# --- Groq client ---
log.info("GROQ_API_KEY loaded: %s", "YES" if GROQ_API_KEY else "NO")
groq_client = Groq(api_key=GROQ_API_KEY)


# ---------------------------------------------------------------------------
# Carbon global hotkeys — NO Accessibility permission required
# PyObjC exposes RegisterEventHotKey but not InstallEventHandler/
# GetApplicationEventTarget, so we use ctypes for the missing pieces.
# ---------------------------------------------------------------------------
_carbon = ctypes.cdll.LoadLibrary(ctypes.util.find_library("Carbon"))


class _EventHotKeyID(ctypes.Structure):
    _fields_ = [("signature", ctypes.c_uint32), ("id", ctypes.c_uint32)]


class _EventTypeSpec(ctypes.Structure):
    _fields_ = [("eventClass", ctypes.c_uint32), ("eventKind", ctypes.c_uint32)]


# Carbon callback type: OSStatus (*handler)(EventHandlerCallRef, EventRef, void*)
_EventHandlerProcPtr = ctypes.CFUNCTYPE(
    ctypes.c_int32, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p
)

# Declare argtypes/restypes so ctypes marshals correctly
_carbon.GetApplicationEventTarget.argtypes = []
_carbon.GetApplicationEventTarget.restype = ctypes.c_void_p

_carbon.InstallEventHandler.argtypes = [
    ctypes.c_void_p,                    # EventTargetRef
    _EventHandlerProcPtr,               # EventHandlerUPP
    ctypes.c_uint32,                    # numTypes
    ctypes.POINTER(_EventTypeSpec),     # EventTypeSpec*
    ctypes.c_void_p,                    # userData
    ctypes.POINTER(ctypes.c_void_p),    # EventHandlerRef*
]
_carbon.InstallEventHandler.restype = ctypes.c_int32

_carbon.RegisterEventHotKey.argtypes = [
    ctypes.c_uint32,                    # keyCode
    ctypes.c_uint32,                    # modifiers
    _EventHotKeyID,                     # hotKeyID (by value)
    ctypes.c_void_p,                    # EventTargetRef
    ctypes.c_uint32,                    # options
    ctypes.POINTER(ctypes.c_void_p),    # EventHotKeyRef*
]
_carbon.RegisterEventHotKey.restype = ctypes.c_int32

_carbon.UnregisterEventHotKey.argtypes = [ctypes.c_void_p]
_carbon.UnregisterEventHotKey.restype = ctypes.c_int32

_carbon.GetEventParameter.argtypes = [
    ctypes.c_void_p,                    # EventRef
    ctypes.c_uint32,                    # EventParamName
    ctypes.c_uint32,                    # EventParamType
    ctypes.c_void_p,                    # actualType (NULL ok)
    ctypes.c_uint32,                    # bufferSize
    ctypes.c_void_p,                    # actualSize (NULL ok)
    ctypes.c_void_p,                    # outData
]
_carbon.GetEventParameter.restype = ctypes.c_int32

# Carbon event constants
_kEventClassKeyboard = 0x6B657962  # 'keyb'
_kEventHotKeyPressed = 5
_kEventParamDirectObject = 0x2D2D2D2D  # '----'
_typeEventHotKeyID = 0x686B6964       # 'hkid'

_hotkey_callbacks: dict[int, callable] = {}
_hotkey_refs: list[ctypes.c_void_p] = []

# Must be kept alive as a module-level reference so it isn't garbage collected
_carbon_handler_ref = ctypes.c_void_p()


@_EventHandlerProcPtr
def _carbon_hotkey_callback(next_handler, event, user_data):
    """Called by Carbon when a registered hotkey is pressed."""
    try:
        hk_id = _EventHotKeyID()
        _carbon.GetEventParameter(
            event,
            _kEventParamDirectObject,
            _typeEventHotKeyID,
            None,
            ctypes.sizeof(hk_id),
            None,
            ctypes.byref(hk_id),
        )
        cb = _hotkey_callbacks.get(hk_id.id)
        if cb:
            cb()
    except Exception:
        log.exception("Error in hotkey callback")
    return 0  # noErr


def _install_carbon_hotkey_handler():
    """Install one Carbon event handler for all hotkey events."""
    event_type = _EventTypeSpec(
        eventClass=_kEventClassKeyboard, eventKind=_kEventHotKeyPressed
    )
    status = _carbon.InstallEventHandler(
        _carbon.GetApplicationEventTarget(),
        _carbon_hotkey_callback,
        1,
        ctypes.byref(event_type),
        None,
        ctypes.byref(_carbon_handler_ref),
    )
    if status != 0:
        log.error("InstallEventHandler failed: %d", status)
    else:
        log.debug("Carbon event handler installed")


def register_hotkey(key_code: int, modifiers: int, hotkey_id: int, callback: callable):
    """Register a global hotkey. No Accessibility permission needed."""
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
# Helpers
# ---------------------------------------------------------------------------
def get_selected_text() -> str:
    """Copy selected text to clipboard via simulated ⌘C, then read it."""
    old_clipboard = pyperclip.paste()
    try:
        # Wait for user to release modifier keys from the hotkey
        time.sleep(0.2)
        subprocess.run(
            ["osascript", "-e",
             'tell application "System Events"\n'
             'keystroke "c" using command down\n'
             'end tell'],
            capture_output=True, timeout=3,
        )
        time.sleep(0.15)
        new_clipboard = pyperclip.paste().strip()
        if new_clipboard and new_clipboard != old_clipboard:
            return new_clipboard
        return new_clipboard
    except Exception:
        return ""


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
        self.menu = [
            rumps.MenuItem("Speech → Text  (⌘⇧A)"),
            rumps.MenuItem("Clipboard → Speech  (⌘⇧D)"),
            None,
            rumps.MenuItem("Quit", callback=self._quit),
        ]
        self._setup_hotkeys()
        log.info("GroqTalk started — look for %s in menu bar", ICON_IDLE)
        log.info("Hotkeys: ⌘⇧A (Record/STT) | ⌘⇧D (Talk/TTS)")

    def _setup_hotkeys(self) -> None:
        _install_carbon_hotkey_handler()
        register_hotkey(kVK_ANSI_A, cmdKey | shiftKey, 1, self._toggle_recording)
        register_hotkey(kVK_ANSI_D, cmdKey | shiftKey, 2, self._speak_selected)

    # --- Speech-to-Text ------------------------------------------------

    def _toggle_recording(self) -> None:
        log.info("⌘⇧A pressed — recording=%s", self.recording)
        if self.recording:
            self._stop_recording()
        else:
            self._start_recording()

    def _start_recording(self) -> None:
        log.info("🔴 Recording started")
        self.recording = True
        self.title = ICON_RECORDING
        self._audio_frames = []
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE, channels=CHANNELS,
            dtype="float32", callback=self._audio_callback,
        )
        self._stream.start()

    def _audio_callback(self, indata, frames, time_info, status):
        self._audio_frames.append(indata.copy())

    def _stop_recording(self) -> None:
        log.info("⏹ Recording stopped — %d frames captured", len(self._audio_frames))
        self.recording = False
        if self._stream:
            self._stream.stop()
            self._stream.close()
        self.title = ICON_PROCESSING
        threading.Thread(target=self._process_audio, daemon=True).start()

    def _process_audio(self) -> None:
        try:
            if not self._audio_frames:
                rumps.notification("GroqTalk", "", "No audio captured.")
                return

            audio_data = np.concatenate(self._audio_frames, axis=0)
            duration = len(audio_data) / SAMPLE_RATE
            log.info("Audio: %.1fs, %d samples", duration, len(audio_data))

            tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
            write_wav(tmp.name, SAMPLE_RATE, (audio_data * 32767).astype(np.int16))
            tmp.close()

            log.info("Sending to Groq Whisper (%s)...", WHISPER_MODEL)
            with open(tmp.name, "rb") as f:
                transcription = groq_client.audio.transcriptions.create(
                    model=WHISPER_MODEL,
                    file=("audio.wav", f.read(), "audio/wav"),
                    language="en",
                    response_format="json",
                )
            os.unlink(tmp.name)
            raw_text = transcription.text
            log.info("Raw transcript: %s", raw_text[:200])

            if not raw_text.strip():
                rumps.notification("GroqTalk", "", "No speech detected.")
                return

            log.info("Sending to Groq LLM (%s) for cleanup...", LLM_MODEL)
            completion = groq_client.chat.completions.create(
                messages=[
                    {"role": "system", "content": LLM_SYSTEM_PROMPT},
                    {"role": "user", "content": raw_text},
                ],
                model=LLM_MODEL,
                temperature=0.3,
                max_tokens=2048,
            )
            cleaned_text = completion.choices[0].message.content.strip()
            log.info("Cleaned text: %s", cleaned_text[:200])

            pyperclip.copy(cleaned_text)
            # Auto-paste at cursor
            subprocess.run(
                ["osascript", "-e",
                 'tell application "System Events" to keystroke "v" using command down'],
                capture_output=True, timeout=3,
            )
            log.info("✅ Copied and pasted")

        except Exception as e:
            log.exception("STT pipeline error")
            rumps.notification("GroqTalk", "Error", str(e)[:100])
        finally:
            self.title = ICON_IDLE

    # --- Text-to-Speech ------------------------------------------------

    def _speak_selected(self) -> None:
        # Kill any currently playing audio first
        subprocess.run(["pkill", "-f", "afplay"], capture_output=True)
        log.info("⌘⇧D pressed — reading selected text")
        threading.Thread(target=self._run_tts, daemon=True).start()

    def _run_tts(self) -> None:
        try:
            text = get_selected_text()
            log.debug("Selected text: %s", text[:100] if text else "(empty)")
            if not text.strip():
                rumps.notification("GroqTalk", "", "No text selected.")
                return
            self.title = ICON_SPEAKING
            log.info("🔊 Sending to Groq TTS: %s...", text[:50])

            tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
            tmp.close()

            with groq_client.audio.speech.with_streaming_response.create(
                model=TTS_MODEL, voice=TTS_VOICE,
                input=text, response_format="wav",
            ) as response:
                response.stream_to_file(tmp.name)

            subprocess.run(["afplay", "-r", "1.35", tmp.name])
            os.unlink(tmp.name)
            log.info("✅ Done speaking")
        except Exception as e:
            log.exception("TTS error")
            rumps.notification("GroqTalk", "TTS Error", str(e)[:100])
        finally:
            self.title = ICON_IDLE

    # --- Lifecycle -----------------------------------------------------

    def _quit(self, _sender):
        unregister_all_hotkeys()
        rumps.quit_app()


if __name__ == "__main__":
    GroqTalkApp().run()
