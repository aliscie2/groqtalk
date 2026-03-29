"""Constants, logging setup, env loading, Groq client init."""
from __future__ import annotations

import logging
import os
import subprocess
import sys

import httpx
from dotenv import load_dotenv
from groq import Groq

# --- Environment ---
load_dotenv()
_config_env = os.path.join(os.path.expanduser("~"), ".config", "groqtalk", ".env")
if os.path.exists(_config_env):
    load_dotenv(_config_env, override=True)

# --- Logging ---
_log_file = os.path.join(os.path.expanduser("~"), ".config", "groqtalk", "groqtalk.log")
os.makedirs(os.path.dirname(_log_file), exist_ok=True)
_file_handler = logging.FileHandler(_log_file, mode="w")
_file_handler.setLevel(logging.DEBUG)
_file_handler.setFormatter(
    logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S")
)
_stream_handler = logging.StreamHandler(sys.stdout)
_stream_handler.setLevel(logging.DEBUG)
_stream_handler.setFormatter(
    logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S")
)
log = logging.getLogger("groqtalk")
log.setLevel(logging.DEBUG)
log.addHandler(_file_handler)
log.addHandler(_stream_handler)
log.propagate = False

# --- Constants ---
GROQ_API_KEY: str | None = os.getenv("GROQ_API_KEY")
SAMPLE_RATE: int = 16000
CHANNELS: int = 1
WHISPER_MODEL: str = "whisper-large-v3-turbo"
LLM_MODEL: str = "llama-3.3-70b-versatile"
LLM_SYSTEM_PROMPT: str = (
    "Fix the grammar, punctuation, and formatting of the following transcribed speech. "
    "Keep the original meaning. Return ONLY the cleaned text, nothing else. "
    "Do NOT add any new content, explanations, or elaboration. "
    "When the speaker lists points, steps, or items, format them as a structured list "
    "using markdown (e.g. **Point 1:** ...). Use line breaks between items for readability."
)
TTS_MODEL: str = "canopylabs/orpheus-v1-english"
TTS_VOICE: str = "hannah"
TTS_VOICES: list[str] = ["hannah", "diana", "autumn", "austin", "daniel", "troy"]
TTS_CHUNK_SIZE: int = 150
SILENCE_THRESHOLD: float = 0.01
RMS_THRESHOLD: float = 0.02
LLM_SKIP_WORD_LIMIT: int = 100
HISTORY_MAX: int = 10
HISTORY_DIR: str = os.path.join(os.path.expanduser("~"), ".config", "groqtalk", "history")
ICON_IDLE: str = "\U0001f399"
ICON_RECORDING: str = "\U0001f534"
ICON_PROCESSING: str = "\u231b"
ICON_SPEAKING: str = "\U0001f50a"

# macOS virtual key codes
kVK_ANSI_A: int = 0x00
kVK_ANSI_D: int = 0x02
kVK_ANSI_R: int = 0x0F
kVK_ANSI_S: int = 0x01
# Carbon modifier masks
cmdKey: int = 0x0100
shiftKey: int = 0x0200

# --- Accessibility check ---
log.info("GROQ_API_KEY loaded: %s", "YES" if GROQ_API_KEY else "NO")

from ApplicationServices import AXIsProcessTrusted  # noqa: E402

_ax_trusted = AXIsProcessTrusted()
log.info("Accessibility trusted: %s", _ax_trusted)
if not _ax_trusted:
    from ApplicationServices import AXIsProcessTrustedWithOptions  # noqa: E402
    from Foundation import NSDictionary  # noqa: E402
    options = NSDictionary.dictionaryWithObject_forKey_(True, "AXTrustedCheckOptionPrompt")
    AXIsProcessTrustedWithOptions(options)
    subprocess.Popen([
        "open",
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
    ])
    log.info("Opened Accessibility settings for user")

# --- Groq client (HTTP/2 for connection multiplexing) ---
try:
    _http_client = httpx.Client(http2=True, timeout=30.0)
    groq_client: Groq = Groq(api_key=GROQ_API_KEY, http_client=_http_client)
    log.info("Groq client created with HTTP/2")
except Exception:
    groq_client = Groq(api_key=GROQ_API_KEY)
    log.info("Groq client created (HTTP/2 not available, using HTTP/1.1)")

# Ensure history dir exists
os.makedirs(HISTORY_DIR, exist_ok=True)
