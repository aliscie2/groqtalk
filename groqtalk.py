"""GroqTalk — voice-to-text and text-to-speech menubar app."""
from __future__ import annotations

import os
import subprocess
import tempfile
import threading

import numpy as np
import pyperclip
import rumps
import sounddevice as sd
from dotenv import load_dotenv
from groq import Groq
from pynput import keyboard
from scipy.io.wavfile import write as write_wav

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
ICON_IDLE = "🎙"
ICON_RECORDING = "🔴"
ICON_PROCESSING = "⏳"
ICON_SPEAKING = "🔊"

# --- Groq client ---
groq_client = Groq(api_key=GROQ_API_KEY)


def get_selected_text() -> str:
    """Get currently selected text from any app via AppleScript."""
    script = (
        'tell application "System Events" to keystroke "c" using command down\n'
        "delay 0.1\n"
        'return (the clipboard as text)'
    )
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            capture_output=True, text=True, timeout=5,
        )
        return result.stdout.strip()
    except (subprocess.TimeoutExpired, subprocess.SubprocessError):
        return ""


class GroqTalkApp(rumps.App):
    """Menubar app for voice-to-text and text-to-speech."""

    def __init__(self) -> None:
        super().__init__("GroqTalk", title=ICON_IDLE)
        self.recording = False
        self._audio_frames: list[np.ndarray] = []
        self._stream: sd.InputStream | None = None
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
            HOTKEY_TTS: self._speak_selected,
        })
        self._hotkey_listener.start()

    # --- Speech-to-Text ---

    def _toggle_recording(self) -> None:
        """Toggle speech-to-text recording."""
        if self.recording:
            self._stop_recording()
        else:
            self._start_recording()

    def _start_recording(self) -> None:
        """Start capturing audio from mic."""
        self.recording = True
        self.title = ICON_RECORDING
        self._audio_frames = []
        self._stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            dtype="float32",
            callback=self._audio_callback,
        )
        self._stream.start()

    def _audio_callback(
        self,
        indata: np.ndarray,
        frames: int,
        time_info: object,
        status: sd.CallbackFlags,
    ) -> None:
        """Buffer incoming audio frames."""
        self._audio_frames.append(indata.copy())

    def _stop_recording(self) -> None:
        """Stop recording and process audio in background thread."""
        self.recording = False
        if self._stream:
            self._stream.stop()
            self._stream.close()
        self.title = ICON_PROCESSING
        threading.Thread(target=self._process_audio, daemon=True).start()

    def _process_audio(self) -> None:
        """Transcribe audio via Groq Whisper, clean via LLM, copy to clipboard."""
        try:
            if not self._audio_frames:
                rumps.notification("GroqTalk", "", "No audio captured.")
                return

            audio_data = np.concatenate(self._audio_frames, axis=0)
            tmp = tempfile.NamedTemporaryFile(suffix=".wav", delete=False)
            write_wav(tmp.name, SAMPLE_RATE, (audio_data * 32767).astype(np.int16))
            tmp.close()

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
                return

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

            pyperclip.copy(cleaned_text)
            preview = cleaned_text[:100] + ("…" if len(cleaned_text) > 100 else "")
            rumps.notification("GroqTalk", "Copied to clipboard ✓", preview)

        except Exception as e:
            rumps.notification("GroqTalk", "Error", str(e)[:100])
        finally:
            self.title = ICON_IDLE

    # --- Text-to-Speech ---

    def _speak_selected(self) -> None:
        """Read selected text aloud using macOS say command."""
        threading.Thread(target=self._run_tts, daemon=True).start()

    def _run_tts(self) -> None:
        """Copy selection and speak it."""
        try:
            text = get_selected_text()
            if not text.strip():
                rumps.notification("GroqTalk", "", "No text selected.")
                return
            self.title = ICON_SPEAKING
            subprocess.run(["say", text], check=True)
        except Exception as e:
            rumps.notification("GroqTalk", "TTS Error", str(e)[:100])
        finally:
            self.title = ICON_IDLE

    # --- App lifecycle ---

    def _quit(self, _sender: rumps.MenuItem) -> None:
        """Clean up and quit."""
        self._hotkey_listener.stop()
        rumps.quit_app()


if __name__ == "__main__":
    GroqTalkApp().run()
