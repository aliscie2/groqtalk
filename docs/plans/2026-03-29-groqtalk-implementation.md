# GroqTalk Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Minimal Python menubar app with speech-to-text (Groq Whisper + LLM cleanup) and text-to-speech (macOS `say`).

**Architecture:** `rumps` menubar app with `pynput` global hotkeys. Cmd+Shift+Space toggles voice recording → Groq Whisper transcription → Groq LLM grammar cleanup → clipboard. Cmd+Shift+S reads clipboard aloud via macOS `say`. Single file app.

**Tech Stack:** Python, rumps, sounddevice, scipy, groq, pynput, pyperclip, subprocess (for `say`)

---

## Execution Guide

**Batch order:** Tasks 1-2 (setup + core), Task 3 (STT feature), Task 4 (TTS feature), Task 5 (integration), Task 6 (review)

**Parallelism:** All tasks are sequential — single file app with each task building on the last.

**Review checkpoints:** After Task 4 (both features done), run `/staged-review no-fix`

**How to start:** `/superpowers:executing-plans docs/plans/2026-03-29-groqtalk-implementation.md`

---

### Task 1: Project Setup

**Files:**
- Create: `~/Desktop/groqtalk/requirements.txt`
- Create: `~/Desktop/groqtalk/.env`

**Step 1: Create requirements.txt**

```
rumps
sounddevice
scipy
groq
pynput
pyperclip
python-dotenv
```

**Step 2: Install dependencies**

Run: `cd ~/Desktop/groqtalk && pip install -r requirements.txt`

**Step 3: Create .env file with Groq API key**

Read the key from `~/Desktop/weekaly.com/.env` (the `VITE_GROQ_API_KEY` value) and write it to `~/Desktop/groqtalk/.env` as:

```
GROQ_API_KEY=<the key value>
```

**Step 4: Commit**

```bash
cd ~/Desktop/groqtalk && git init && git add requirements.txt .env
git commit -m "chore: project setup with dependencies"
```

Note: Consider adding `.env` to `.gitignore` — it contains an API key.

---

### Task 2: App Shell — Menubar + Hotkeys

**Files:**
- Create: `~/Desktop/groqtalk/groqtalk.py`

**Step 1: Write the menubar app skeleton with hotkey listeners**

```python
"""GroqTalk — voice-to-text and text-to-speech menubar app."""
from __future__ import annotations

import os
import threading

import rumps
from dotenv import load_dotenv
from pynput import keyboard

load_dotenv()

# --- Constants ---
GROQ_API_KEY = os.getenv("GROQ_API_KEY")
HOTKEY_STT = "<cmd>+<shift>+space"
HOTKEY_TTS = "<cmd>+<shift>+s"
SAMPLE_RATE = 16000
CHANNELS = 1
WHISPER_MODEL = "whisper-large-v3-turbo"
LLM_MODEL = "llama-3.3-70b-versatile"
LLM_SYSTEM_PROMPT = (
    "Fix the grammar, punctuation, and formatting of the following transcribed speech. "
    "Keep the original meaning. Return only the cleaned text, nothing else."
)


class GroqTalkApp(rumps.App):
    """Menubar app for voice-to-text and text-to-speech."""

    def __init__(self) -> None:
        super().__init__("GroqTalk", title="🎙")
        self.recording = False
        self.menu = [
            rumps.MenuItem("Speech → Text  (⌘⇧Space)"),
            rumps.MenuItem("Text → Speech  (⌘⇧S)"),
            None,
            rumps.MenuItem("Quit", callback=self._quit),
        ]
        self._setup_hotkeys()

    def _setup_hotkeys(self) -> None:
        """Register global hotkeys in a background thread."""
        self._hotkey_listener = keyboard.GlobalHotKeys({
            HOTKEY_STT: self._toggle_recording,
            HOTKEY_TTS: self._speak_clipboard,
        })
        self._hotkey_listener.start()

    def _toggle_recording(self) -> None:
        """Toggle speech-to-text recording."""
        if self.recording:
            self._stop_recording()
        else:
            self._start_recording()

    def _start_recording(self) -> None:
        """Start recording — placeholder."""
        self.recording = True
        self.title = "🔴"

    def _stop_recording(self) -> None:
        """Stop recording — placeholder."""
        self.recording = False
        self.title = "🎙"

    def _speak_clipboard(self) -> None:
        """Read clipboard aloud — placeholder."""
        pass

    def _quit(self, _sender: rumps.MenuItem) -> None:
        """Clean up and quit."""
        self._hotkey_listener.stop()
        rumps.quit_app()


if __name__ == "__main__":
    GroqTalkApp().run()
```

**Step 2: Run to verify menubar icon appears**

Run: `cd ~/Desktop/groqtalk && python groqtalk.py`
Expected: Mic emoji appears in menubar, app runs without errors. Quit via menu.

**Step 3: Commit**

```bash
git add groqtalk.py
git commit -m "feat: menubar app shell with hotkey registration"
```

---

### Task 3: Speech-to-Text Feature

**Files:**
- Modify: `~/Desktop/groqtalk/groqtalk.py`

**Step 1: Add recording + transcription + cleanup logic**

Add these imports at the top:

```python
import tempfile
import subprocess

import numpy as np
import sounddevice as sd
from scipy.io.wavfile import write as write_wav
import pyperclip
from groq import Groq
```

Add a module-level Groq client after the constants:

```python
groq_client = Groq(api_key=GROQ_API_KEY)
```

Replace `_start_recording` with:

```python
def _start_recording(self) -> None:
    """Start capturing audio from mic."""
    self.recording = True
    self.title = "🔴"
    self._audio_frames: list[np.ndarray] = []
    self._stream = sd.InputStream(
        samplerate=SAMPLE_RATE,
        channels=CHANNELS,
        dtype="float32",
        callback=self._audio_callback,
    )
    self._stream.start()
```

Add the audio callback:

```python
def _audio_callback(
    self,
    indata: np.ndarray,
    frames: int,
    time_info: object,
    status: sd.CallbackFlags,
) -> None:
    """Buffer incoming audio frames."""
    self._audio_frames.append(indata.copy())
```

Replace `_stop_recording` with:

```python
def _stop_recording(self) -> None:
    """Stop recording and process audio in background thread."""
    self.recording = False
    self._stream.stop()
    self._stream.close()
    self.title = "⏳"
    # Process in background to keep UI responsive
    threading.Thread(target=self._process_audio, daemon=True).start()
```

Add the processing pipeline:

```python
def _process_audio(self) -> None:
    """Transcribe audio via Groq Whisper, clean up via LLM, copy to clipboard."""
    try:
        # Save audio to temp WAV
        audio_data = np.concatenate(self._audio_frames, axis=0)
        tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
        write_wav(tmp.name, SAMPLE_RATE, (audio_data * 32767).astype(np.int16))
        tmp.close()

        # Transcribe with Groq Whisper
        with open(tmp.name, "rb") as f:
            transcription = groq_client.audio.transcriptions.create(
                model=WHISPER_MODEL,
                file=("audio.wav", f.read(), "audio/wav"),
                language="en",
                response_format="json",
            )
        os.unlink(tmp.name)
        raw_text = transcription.text

        if not raw_text.strip():
            rumps.notification("GroqTalk", "", "No speech detected.")
            self.title = "🎙"
            return

        # Clean up with Groq LLM
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

        # Copy to clipboard
        pyperclip.copy(cleaned_text)
        rumps.notification("GroqTalk", "Copied to clipboard ✓", cleaned_text[:100])

    except Exception as e:
        rumps.notification("GroqTalk", "Error", str(e)[:100])
    finally:
        self.title = "🎙"
```

**Step 2: Test manually**

Run: `cd ~/Desktop/groqtalk && python groqtalk.py`
Test: Press Cmd+Shift+Space, speak a sentence, press Cmd+Shift+Space again. Verify cleaned text appears in clipboard.

**Step 3: Commit**

```bash
git add groqtalk.py
git commit -m "feat: speech-to-text with Groq Whisper + LLM cleanup"
```

---

### Task 4: Text-to-Speech Feature

**Files:**
- Modify: `~/Desktop/groqtalk/groqtalk.py`

**Step 1: Implement TTS using macOS `say` command**

Replace `_speak_clipboard` with:

```python
def _speak_clipboard(self) -> None:
    """Read clipboard text aloud using macOS say command."""
    text = pyperclip.paste()
    if not text or not text.strip():
        rumps.notification("GroqTalk", "", "Clipboard is empty.")
        return
    self.title = "🔊"
    threading.Thread(target=self._run_say, args=(text,), daemon=True).start()

def _run_say(self, text: str) -> None:
    """Run macOS say command in background."""
    try:
        subprocess.run(["say", text], check=True)
    except Exception as e:
        rumps.notification("GroqTalk", "TTS Error", str(e)[:100])
    finally:
        self.title = "🎙"
```

**Step 2: Test manually**

Run: `cd ~/Desktop/groqtalk && python groqtalk.py`
Test: Copy some text to clipboard, press Cmd+Shift+S. Verify it reads aloud.

**Step 3: Commit**

```bash
git add groqtalk.py
git commit -m "feat: text-to-speech via macOS say command"
```

---

### Task 5: Polish — .gitignore + README

**Files:**
- Create: `~/Desktop/groqtalk/.gitignore`

**Step 1: Create .gitignore**

```
.env
__pycache__/
*.pyc
.DS_Store
```

**Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: add gitignore"
```

---

### Task 6: Review Gate

**Step 1: Stage all changes**

```bash
cd ~/Desktop/groqtalk && git diff HEAD
```

**Step 2: Read groqtalk.py in full and verify:**

- [ ] No hardcoded API keys
- [ ] All functions under 40 lines
- [ ] File under 200 lines
- [ ] Constants at module top
- [ ] Type hints on all function signatures
- [ ] No security issues (key loaded from .env)
- [ ] Error handling on API calls
- [ ] Background threads for blocking operations (recording, API calls, TTS)
- [ ] Clean resource cleanup (stream close, temp file delete)

**Step 3: Fix any issues found before marking complete.**
