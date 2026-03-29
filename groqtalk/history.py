"""History load/save/prune/add, TTS cache, relative_time, usage tracking + cost."""
from __future__ import annotations

import json
import os
from datetime import datetime, timedelta

from .config import log, HISTORY_DIR, HISTORY_MAX

# ---------------------------------------------------------------------------
# Usage tracking -- local cost estimator
# ---------------------------------------------------------------------------
_USAGE_FILE = os.path.join(os.path.expanduser("~"), ".config", "groqtalk", "usage.json")

# Groq pricing (from groq.com/pricing, March 2025)
_PRICE_WHISPER_PER_SEC = 0.04 / 3600
_PRICE_LLM_INPUT_PER_TOKEN = 0.59 / 1e6
_PRICE_LLM_OUTPUT_PER_TOKEN = 0.79 / 1e6
_PRICE_TTS_PER_CHAR = 22.00 / 1e6


def _load_usage() -> list[dict]:
    try:
        with open(_USAGE_FILE, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []


def _save_usage(entries: list[dict]) -> None:
    with open(_USAGE_FILE, "w") as f:
        json.dump(entries, f)


def log_usage(kind: str, **kwargs: float | int) -> None:
    """Log a usage event with timestamp."""
    entries = _load_usage()
    entry = {"ts": datetime.now().isoformat(), "kind": kind, **kwargs}
    entries.append(entry)
    _save_usage(entries)


def get_cost_last_n_days(days: int = 3) -> tuple[float, dict]:
    """Calculate estimated cost for last N days."""
    entries = _load_usage()
    cutoff = datetime.now() - timedelta(days=days)
    totals = {
        "whisper_sec": 0.0, "llm_in_tok": 0,
        "llm_out_tok": 0, "tts_chars": 0, "calls": 0,
    }
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
# History -- disk-cached ring buffer of last N recordings + TTS
# ---------------------------------------------------------------------------
_HISTORY_INDEX = os.path.join(HISTORY_DIR, "index.json")


def load_history() -> list[dict]:
    """Load history index."""
    try:
        with open(_HISTORY_INDEX, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return []


def _save_history(entries: list[dict]) -> None:
    with open(_HISTORY_INDEX, "w") as f:
        json.dump(entries, f, indent=2)


def _prune_history(entries: list[dict]) -> list[dict]:
    """Keep only the newest HISTORY_MAX entries, delete old files."""
    if len(entries) <= HISTORY_MAX:
        return entries
    old = entries[:-HISTORY_MAX]
    for e in old:
        for key in ("wav", "tts_wav"):
            path = e.get(key, "")
            if path and os.path.exists(path):
                os.unlink(path)
                log.debug("[HISTORY] deleted %s", path)
    return entries[-HISTORY_MAX:]


def add_history_entry(wav_bytes: bytes, transcript: str, cleaned: str) -> dict:
    """Save a recording to history and return the entry."""
    entries = load_history()
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    wav_path = os.path.join(HISTORY_DIR, f"rec_{ts}.wav")
    with open(wav_path, "wb") as f:
        f.write(wav_bytes)
    entry = {
        "ts": ts, "wav": wav_path,
        "transcript": transcript, "cleaned": cleaned,
    }
    entries.append(entry)
    entries = _prune_history(entries)
    _save_history(entries)
    log.info("[HISTORY] saved entry %s (%d bytes WAV)", ts, len(wav_bytes))
    return entry


def save_tts_to_history(text: str, tts_wav_bytes: bytes) -> None:
    """Attach TTS audio to matching history entry, or save standalone."""
    entries = load_history()
    for e in reversed(entries):
        if e.get("cleaned", "").strip() == text.strip():
            ts = e["ts"]
            tts_path = os.path.join(HISTORY_DIR, f"tts_{ts}.wav")
            with open(tts_path, "wb") as f:
                f.write(tts_wav_bytes)
            e["tts_wav"] = tts_path
            _save_history(entries)
            log.info("[HISTORY] saved TTS for entry %s (%d bytes)", ts, len(tts_wav_bytes))
            return
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    tts_path = os.path.join(HISTORY_DIR, f"tts_{ts}.wav")
    with open(tts_path, "wb") as f:
        f.write(tts_wav_bytes)
    entry = {"ts": ts, "tts_wav": tts_path, "cleaned": text[:200]}
    entries.append(entry)
    entries = _prune_history(entries)
    _save_history(entries)
    log.info("[HISTORY] saved standalone TTS entry %s (%d bytes)", ts, len(tts_wav_bytes))


def find_cached_tts(text: str) -> bytes | None:
    """Check if we already have TTS audio for this text."""
    entries = load_history()
    for e in reversed(entries):
        if e.get("cleaned", "").strip() == text.strip() and e.get("tts_wav"):
            path = e["tts_wav"]
            if os.path.exists(path):
                with open(path, "rb") as f:
                    data = f.read()
                log.info("[HISTORY] TTS cache hit for %s (%d bytes)", e["ts"], len(data))
                return data
    return None


def relative_time(ts_str: str) -> str:
    """Convert timestamp string like '20260329_174547' to '5m ago'."""
    try:
        ts = datetime.strptime(ts_str, "%Y%m%d_%H%M%S")
        delta = datetime.now() - ts
        seconds = int(delta.total_seconds())
        if seconds < 60:
            return "just now"
        if seconds < 3600:
            return f"{seconds // 60}m ago"
        if seconds < 86400:
            return f"{seconds // 3600}h ago"
        return f"{seconds // 86400}d ago"
    except (ValueError, TypeError):
        return ts_str
