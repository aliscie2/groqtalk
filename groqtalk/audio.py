"""Audio helpers: silence detection (RMS), trim, OGG encode, text chunking."""
from __future__ import annotations

import io
import re
import time

import numpy as np
import soundfile as sf

from .config import log, SAMPLE_RATE, SILENCE_THRESHOLD, RMS_THRESHOLD, TTS_CHUNK_SIZE


def is_audio_silent(audio: np.ndarray, rms_threshold: float = RMS_THRESHOLD) -> bool:
    """Detect if audio is below noise floor to prevent Whisper hallucination."""
    if len(audio) == 0:
        return True
    rms = float(np.sqrt(np.mean(audio ** 2)))
    above = float(np.mean(np.abs(audio) > rms_threshold))
    is_silent = rms < rms_threshold or above < 0.1
    log.debug("[ENERGY] RMS=%.4f above=%.1f%% silent=%s", rms, above * 100, is_silent)
    return is_silent


def trim_silence(audio: np.ndarray, threshold: float = SILENCE_THRESHOLD) -> np.ndarray:
    """Trim leading and trailing silence from audio."""
    abs_audio = np.abs(audio).flatten()
    above = np.where(abs_audio > threshold)[0]
    if len(above) == 0:
        return audio
    start, end = above[0], above[-1] + 1
    trimmed = audio[start:end]
    log.debug(
        "[trim] %d -> %d samples (removed %.1fs)",
        len(audio), len(trimmed), (len(audio) - len(trimmed)) / SAMPLE_RATE,
    )
    return trimmed


def encode_ogg(audio: np.ndarray, sample_rate: int = SAMPLE_RATE) -> bytes:
    """Encode audio to OGG/Vorbis in memory."""
    buf = io.BytesIO()
    sf.write(buf, audio, sample_rate, format="OGG", subtype="VORBIS")
    return buf.getvalue()


def prepare_audio_for_whisper(
    audio_frames: list[np.ndarray],
) -> tuple[bytes, str, float]:
    """Concat frames, trim silence, encode to OGG. Returns (bytes, mime, duration)."""
    t0 = time.time()
    audio = np.concatenate(audio_frames, axis=0)
    raw_dur = len(audio) / SAMPLE_RATE
    audio = trim_silence(audio)
    trim_dur = len(audio) / SAMPLE_RATE
    audio_i16 = (audio * 32767).astype(np.int16)
    ogg = encode_ogg(audio_i16)
    log.info(
        "[prep] %.1fs (trimmed from %.1fs) -> %d bytes OGG in %.3fs",
        trim_dur, raw_dur, len(ogg), time.time() - t0,
    )
    return ogg, "audio/ogg", trim_dur


def clean_text_for_speech(text: str) -> str:
    """Transform technical text into natural speech-friendly text."""
    t = text

    # URLs first (before other transforms): https://api.groq.com/... → "groq dot com"
    t = re.sub(r"https?://(?:www\.)?([a-zA-Z0-9.-]+)\S*",
               lambda m: _speak_domain(m.group(1)), t)

    # Version patterns: HTTP/2, Python/3.12 → "H-T-T-P 2", "Python 3.12"
    t = re.sub(r"\b(\w+)/(\d[\d.]*)\b", r"\1 \2", t)

    # File paths: /path/to/file.py → "file dot py"
    t = re.sub(r"[~/][\w./-]+/(\w[\w.-]*)", lambda m: _speak_filename(m.group(1)), t)

    # Standalone filenames: any word.ext where ext is 1-5 lowercase letters
    t = re.sub(r"\b([\w-]+)\.([a-z]{1,5})\b",
               lambda m: f"{m.group(1).replace('_', ' ')} dot {m.group(2)}", t)

    # Pronounceable overrides (words that happen to be all-caps but should be said as-is)
    _say_as_word = {"JSON": "jason", "YAML": "yaml", "SQL": "sequel",
                    "RAM": "ram", "OGG": "ogg", "WAV": "wave", "PIP": "pip",
                    "NASA": "NASA", "FEMA": "FEMA", "NATO": "NATO", "SCSI": "scuzzy"}

    def _spell_abbrev(m: re.Match) -> str:
        word = m.group(0)
        if word in _say_as_word:
            return _say_as_word[word]
        return "-".join(word)  # "HTTP" → "H-T-T-P", any length

    # Any ALL-CAPS word 2-7 chars: spell it out (generic pattern, not finite list)
    t = re.sub(r"\b[A-Z]{2,7}\b", _spell_abbrev, t)

    # snake_case and kebab-case → spaces
    t = re.sub(r"\b(\w+)[_-](\w+)(?:[_-](\w+))?(?:[_-](\w+))?\b",
               lambda m: " ".join(g for g in m.groups() if g), t)

    # CamelCase → separate words: ThreadingHTTPServer → Threading Server
    t = re.sub(r"([a-z])([A-Z])", r"\1 \2", t)
    t = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1 \2", t)

    # Code blocks and backticks → remove
    t = re.sub(r"```[\s\S]*?```", " code block omitted ", t)
    t = re.sub(r"`([^`]+)`", r"\1", t)

    # Markdown headers
    t = re.sub(r"^#{1,6}\s*", "", t, flags=re.MULTILINE)

    # Markdown bold/italic
    t = re.sub(r"\*{1,3}([^*]+)\*{1,3}", r"\1", t)

    # Arrows and special chars
    t = t.replace("→", "to").replace("←", "from").replace("=>", "to")
    t = t.replace(">=", "or higher").replace("<=", "or lower")
    t = t.replace("!=", "not equal to").replace("==", "equals")
    t = t.replace("&&", "and").replace("||", "or")

    # Repeated whitespace
    t = re.sub(r"\s+", " ", t).strip()

    return t


def _speak_filename(name: str) -> str:
    """Convert filename to speech: server.py → server dot py."""
    parts = name.rsplit(".", 1)
    if len(parts) == 2:
        return f"{parts[0]} dot {parts[1]}"
    return name


def _speak_domain(domain: str) -> str:
    """Convert domain to speech: api.groq.com → groq dot com."""
    parts = domain.split(".")
    # Remove common prefixes
    parts = [p for p in parts if p not in ("www", "api", "docs", "console")]
    return " dot ".join(parts) if parts else domain


def split_text_chunks(text: str, max_chars: int = TTS_CHUNK_SIZE) -> list[str]:
    """Split text into chunks at sentence boundaries for streaming TTS."""
    if len(text) <= max_chars:
        return [text]
    chunks: list[str] = []
    remaining = text
    while remaining:
        if len(remaining) <= max_chars:
            chunks.append(remaining)
            break
        segment = remaining[:max_chars]
        split_at = -1
        for pat in [r"[.!?]\s", r"\n", r",\s"]:
            matches = list(re.finditer(pat, segment))
            if matches:
                split_at = matches[-1].end()
                break
        if split_at == -1:
            last_space = segment.rfind(" ")
            split_at = last_space if last_space > 0 else max_chars
        chunks.append(remaining[:split_at].strip())
        remaining = remaining[split_at:].strip()
    return [c for c in chunks if c]
