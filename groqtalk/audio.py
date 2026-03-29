"""Audio helpers: trim_silence, encode_ogg, prepare_audio, is_audio_silent, persistent stream."""
from __future__ import annotations

import io
import re
import time

import numpy as np
import soundfile as sf

from .config import log, SAMPLE_RATE, SILENCE_THRESHOLD, RMS_THRESHOLD, TTS_CHUNK_SIZE


def is_audio_silent(audio: np.ndarray, rms_threshold: float = RMS_THRESHOLD) -> bool:
    """Detect if audio is below noise floor -- prevents Whisper hallucination."""
    if len(audio) == 0:
        return True
    rms = float(np.sqrt(np.mean(audio ** 2)))
    above = float(np.mean(np.abs(audio) > rms_threshold))
    is_silent = rms < rms_threshold or above < 0.1
    log.debug(
        "[ENERGY] RMS=%.4f, above_threshold=%.1f%%, silent=%s",
        rms, above * 100, is_silent,
    )
    return is_silent


def trim_silence(
    audio: np.ndarray, threshold: float = SILENCE_THRESHOLD,
) -> np.ndarray:
    """Trim leading and trailing silence from audio."""
    abs_audio = np.abs(audio).flatten()
    above = np.where(abs_audio > threshold)[0]
    if len(above) == 0:
        return audio
    start, end = above[0], above[-1] + 1
    trimmed = audio[start:end]
    log.debug(
        "[trim] %d -> %d samples (removed %.1fs silence)",
        len(audio), len(trimmed), (len(audio) - len(trimmed)) / SAMPLE_RATE,
    )
    return trimmed


def encode_ogg(audio: np.ndarray, sample_rate: int = SAMPLE_RATE) -> bytes:
    """Encode audio to OGG/Vorbis in memory -- much smaller than WAV."""
    buf = io.BytesIO()
    sf.write(buf, audio, sample_rate, format="OGG", subtype="VORBIS")
    return buf.getvalue()


def prepare_audio_for_whisper(
    audio_frames: list[np.ndarray],
) -> tuple[bytes, str, float]:
    """Concatenate frames, trim silence, encode to OGG.

    Returns (bytes, mime, duration).
    """
    t0 = time.time()
    audio = np.concatenate(audio_frames, axis=0)
    raw_duration = len(audio) / SAMPLE_RATE
    audio = trim_silence(audio)
    trimmed_duration = len(audio) / SAMPLE_RATE
    audio_int16 = (audio * 32767).astype(np.int16)
    ogg_bytes = encode_ogg(audio_int16)
    prep_time = time.time() - t0
    log.info(
        "[prep] %.1fs audio (trimmed from %.1fs) -> %d bytes OGG in %.3fs",
        trimmed_duration, raw_duration, len(ogg_bytes), prep_time,
    )
    return ogg_bytes, "audio/ogg", trimmed_duration


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
        for pattern in [r"[.!?]\s", r"\n", r",\s"]:
            matches = list(re.finditer(pattern, segment))
            if matches:
                split_at = matches[-1].end()
                break
        if split_at == -1:
            last_space = segment.rfind(" ")
            split_at = last_space if last_space > 0 else max_chars
        chunks.append(remaining[:split_at].strip())
        remaining = remaining[split_at:].strip()
    return [c for c in chunks if c]
