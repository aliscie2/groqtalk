"""Constants, logging, env loading, Groq client, accessibility check."""
from __future__ import annotations

import logging
import os
import sys

import httpx
from dotenv import load_dotenv
from groq import Groq

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
load_dotenv()
_config_env = os.path.join(os.path.expanduser("~"), ".config", "groqtalk", ".env")
if os.path.exists(_config_env):
    load_dotenv(_config_env, override=True)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log_dir = os.path.join(os.path.expanduser("~"), ".config", "groqtalk")
os.makedirs(_log_dir, exist_ok=True)
_log_file = os.path.join(_log_dir, "groqtalk.log")

_fmt = logging.Formatter(
    "%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S",
)
_fh = logging.FileHandler(_log_file, mode="w")
_fh.setLevel(logging.DEBUG)
_fh.setFormatter(_fmt)
_sh = logging.StreamHandler(sys.stdout)
_sh.setLevel(logging.DEBUG)
_sh.setFormatter(_fmt)

log = logging.getLogger("groqtalk")
log.setLevel(logging.DEBUG)
log.addHandler(_fh)
log.addHandler(_sh)
log.propagate = False

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
GROQ_API_KEY: str | None = os.getenv("GROQ_API_KEY")
SAMPLE_RATE: int = 16_000
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
RMS_THRESHOLD: float = 0.001
LLM_SKIP_WORD_LIMIT: int = 100
HISTORY_MAX: int = 10
HISTORY_DIR: str = os.path.join(
    os.path.expanduser("~"), ".config", "groqtalk", "history",
)

# Status icons
ICON_IDLE: str = "\U0001f399"       # microphone
ICON_RECORDING: str = "\U0001f534"  # red circle
ICON_PROCESSING: str = "\u231b"     # hourglass
ICON_SPEAKING: str = "\U0001f50a"   # speaker

# macOS virtual key codes
kVK_ANSI_A: int = 0x00
kVK_ANSI_D: int = 0x02
kVK_ANSI_R: int = 0x0F
kVK_ANSI_S: int = 0x01

# Carbon modifier masks
cmdKey: int = 0x0100
shiftKey: int = 0x0200

# ---------------------------------------------------------------------------
# Accessibility check
# ---------------------------------------------------------------------------
log.info("GROQ_API_KEY loaded: %s", "YES" if GROQ_API_KEY else "NO")

from ApplicationServices import AXIsProcessTrusted  # noqa: E402

_ax_notified: bool = False


def is_ax_trusted() -> bool:
    """Return True if Accessibility permission is granted."""
    return bool(AXIsProcessTrusted())


_ax_trusted = is_ax_trusted()
log.info("Accessibility trusted: %s", _ax_trusted)

if not _ax_trusted:
    from ApplicationServices import AXIsProcessTrustedWithOptions  # noqa: E402
    from Foundation import NSDictionary  # noqa: E402

    opts = NSDictionary.dictionaryWithObject_forKey_(
        True, "AXTrustedCheckOptionPrompt",
    )
    AXIsProcessTrustedWithOptions(opts)
    log.info("Prompted user for Accessibility permission")

# ---------------------------------------------------------------------------
# Groq client (HTTP/2 for connection multiplexing)
# ---------------------------------------------------------------------------
try:
    _http = httpx.Client(http2=True, timeout=30.0)
    groq_client: Groq = Groq(api_key=GROQ_API_KEY, http_client=_http)
    log.info("Groq client created with HTTP/2")
except Exception:
    groq_client = Groq(api_key=GROQ_API_KEY)
    log.info("Groq client created (HTTP/1.1 fallback)")

# Ensure history dir
os.makedirs(HISTORY_DIR, exist_ok=True)
