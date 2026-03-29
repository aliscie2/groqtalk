"""GroqTalkApp -- the rumps.App class with all menu setup, hotkey handlers, STT/TTS pipelines."""
from __future__ import annotations

import io
import os
import queue
import subprocess
import threading
import time

import numpy as np
import rumps
import sounddevice as sd
import soundfile as sf
from AVFoundation import AVAudioPlayer
from Foundation import NSData

from .config import (
    log, groq_client,
    SAMPLE_RATE, CHANNELS, WHISPER_MODEL, LLM_MODEL, LLM_SYSTEM_PROMPT,
    TTS_MODEL, TTS_VOICE, TTS_VOICES,
    LLM_SKIP_WORD_LIMIT,
    ICON_IDLE, ICON_RECORDING, ICON_PROCESSING, ICON_SPEAKING,
    kVK_ANSI_A, kVK_ANSI_D, kVK_ANSI_R, kVK_ANSI_S, cmdKey, shiftKey,
)
from .hotkeys import install_carbon_hotkey_handler, register_hotkey, unregister_all_hotkeys
from .audio import is_audio_silent, trim_silence, prepare_audio_for_whisper, split_text_chunks
from .clipboard import clipboard_write, simulate_paste, get_selected_text
from .history import (
    log_usage, get_cost_last_n_days,
    load_history, add_history_entry, save_tts_to_history, find_cached_tts, relative_time,
)


class GroqTalkApp(rumps.App):
    """Menubar app for voice-to-text and text-to-speech."""

    LIVE_INTERVAL: float = 5.0  # seconds between live Whisper calls

    def __init__(self) -> None:
        super().__init__("GroqTalk", title=ICON_IDLE)
        self.recording: bool = False
        self._audio_frames: list[np.ndarray] = []
        self._tts_generation: int = 0
        self._shutdown_event = threading.Event()
        self._enhance_text: bool = True
        self._last_recording_wav: bytes | None = None
        self._replay_generation: int = 0
        self._replay_player: AVAudioPlayer | None = None
        self._current_voice: str = TTS_VOICE
        self._playback_rate: float = 1.0
        self._live_transcript: str = ""

        self._build_menu()
        self._refresh_cost(None)
        self._setup_hotkeys()
        self._start_persistent_stream()
        threading.Thread(target=self._keep_alive, daemon=False).start()
        threading.Thread(target=self._warm_connection, daemon=True).start()
        log.info("GroqTalk started -- look for %s in menu bar", ICON_IDLE)
        log.info("Hotkeys: Cmd+Shift+A (Record/STT) | Cmd+Shift+D (Speak) | Cmd+Shift+R (Replay) | Cmd+Shift+S (Stop)")

    # --- Menu construction --------------------------------------------------

    def _build_menu(self) -> None:
        """Build the full menubar menu."""
        self._enhance_item = rumps.MenuItem(
            "Enhance Text (LLM)", callback=self._toggle_enhance,
        )
        self._enhance_item.state = 1
        self._voice_menu = self._build_voice_menu()
        self._speed_menu = self._build_speed_menu()
        self._cost_item = rumps.MenuItem("Usage: $0.00 (3 days)")
        self._cost_item.set_callback(self._refresh_cost)
        self._audios_menu = rumps.MenuItem("Recent Audios")
        self._texts_menu = rumps.MenuItem("Recent Texts")
        self._build_history_items(self._audios_menu, self._texts_menu)
        self._stop_item = rumps.MenuItem("Stop  (Cmd+Shift+S)", callback=self._stop_all)
        self._set_stop_visible(False)
        self.menu = [
            rumps.MenuItem("Speech -> Text  (Cmd+Shift+A)"),
            rumps.MenuItem("Speak Selection  (Cmd+Shift+D)"),
            rumps.MenuItem("Replay Latest   (Cmd+Shift+R)"),
            self._stop_item,
            None,
            self._audios_menu,
            self._texts_menu,
            None,
            self._enhance_item,
            self._voice_menu,
            self._speed_menu,
            self._cost_item,
        ]

    def _build_voice_menu(self) -> rumps.MenuItem:
        """Build voice selection submenu."""
        menu = rumps.MenuItem("Voice")
        for voice in TTS_VOICES:
            icon = "\U0001f469" if voice in ("hannah", "diana", "autumn") else "\U0001f468"
            label = f"{icon} {voice}"
            item = rumps.MenuItem(label, callback=self._set_voice)
            item.representedObject = voice
            if voice == TTS_VOICE:
                item.state = 1
            menu.add(item)
        return menu

    def _build_speed_menu(self) -> rumps.MenuItem:
        """Build playback speed submenu."""
        menu = rumps.MenuItem("Playback Speed")
        for rate in ["0.75x", "1.0x", "1.25x", "1.5x", "1.75x", "2.0x"]:
            item = rumps.MenuItem(rate, callback=self._set_speed)
            if rate == "1.0x":
                item.state = 1
            menu.add(item)
        return menu

    # --- Persistent audio stream -------------------------------------------

    def _start_persistent_stream(self) -> None:
        """Start persistent audio input stream (never stopped)."""
        self._persistent_stream = sd.InputStream(
            samplerate=SAMPLE_RATE, channels=CHANNELS,
            dtype="float32", callback=self._audio_callback,
        )
        self._persistent_stream.start()
        log.info(
            "[AUDIO] persistent stream started -- device=%s",
            sd.query_devices(sd.default.device[0])["name"],
        )

    def _audio_callback(
        self, indata: np.ndarray, frames: int, time_info: object, status: object,
    ) -> None:
        if status:
            log.warning("[REC] audio callback status: %s", status)
        self._audio_frames.append(indata.copy())

    # --- Lifecycle helpers --------------------------------------------------

    def _keep_alive(self) -> None:
        """Non-daemon thread that keeps the app alive."""
        while not self._shutdown_event.is_set():
            time.sleep(1)
        log.info("[KEEPALIVE] shutdown")

    def _warm_connection(self) -> None:
        """Pre-warm HTTP connection to Groq."""
        try:
            t0 = time.time()
            groq_client.models.list()
            log.info("[WARM] Groq connection pre-warmed in %.2fs", time.time() - t0)
        except Exception:
            log.debug("[WARM] pre-warm failed (non-critical)")

    def _setup_hotkeys(self) -> None:
        install_carbon_hotkey_handler()
        register_hotkey(kVK_ANSI_A, cmdKey | shiftKey, 1, self._toggle_recording)
        register_hotkey(kVK_ANSI_D, cmdKey | shiftKey, 2, self._speak_selected)
        register_hotkey(kVK_ANSI_R, cmdKey | shiftKey, 3, self._replay_recording)
        register_hotkey(kVK_ANSI_S, cmdKey | shiftKey, 4, lambda: self._stop_all(None))

    # --- Speech-to-Text (live partial every 5s) ----------------------------

    def _toggle_recording(self) -> None:
        log.info("[REC] Cmd+Shift+A pressed -- recording=%s", self.recording)
        if self.recording:
            self._stop_recording()
        else:
            self._start_recording()

    def _start_recording(self) -> None:
        log.info("[REC] starting recording...")
        self.recording = True
        self.title = ICON_RECORDING
        self._audio_frames = []
        self._live_transcript = ""
        threading.Thread(target=self._live_transcribe, daemon=True).start()

    def _live_transcribe(self) -> None:
        """Every 5s, send only NEW audio to Whisper and append to transcript."""
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
            new_frames = self._audio_frames[last_frame_idx:current_len]
            last_frame_idx = current_len
            try:
                ogg_bytes, mime, duration = prepare_audio_for_whisper(new_frames)
                if duration < 0.5:
                    continue
                t0 = time.time()
                transcription = groq_client.audio.transcriptions.create(
                    model=WHISPER_MODEL,
                    file=("audio.ogg", ogg_bytes, mime),
                    language="en", response_format="text",
                )
                elapsed = time.time() - t0
                text = (
                    transcription.text.strip()
                    if hasattr(transcription, "text")
                    else str(transcription).strip()
                )
                if text:
                    parts.append(text)
                    self._live_transcript = " ".join(parts)
                    clipboard_write(self._live_transcript)
                    log_usage("whisper", audio_sec=duration)
                    log.info(
                        "[LIVE] %.1fs audio -> Whisper in %.2fs: %s",
                        duration, elapsed, text[:80],
                    )
            except Exception:
                log.exception("[LIVE] partial transcription error")
        log.info("[LIVE] thread stopped -- %d parts collected", len(parts))

    def _stop_recording(self) -> None:
        log.info("[REC] stopping -- %d frames captured", len(self._audio_frames))
        self.recording = False
        self.title = ICON_PROCESSING
        frames = list(self._audio_frames)

        def _safe_process() -> None:
            try:
                self._process_audio(frames)
            except Exception:
                log.exception("[STT] thread crashed")
                self.title = ICON_IDLE

        threading.Thread(target=_safe_process, daemon=True).start()

    def _process_audio(self, frames: list[np.ndarray]) -> None:
        """Full STT pipeline: audio -> Whisper -> optional LLM -> clipboard."""
        pipeline_start = time.time()
        log.info("[STT] final pipeline started, frames=%d", len(frames))
        try:
            if not frames:
                log.warning("[STT] no audio frames captured")
                rumps.notification("GroqTalk", "", "No audio captured.")
                return

            ogg_bytes, mime, duration = prepare_audio_for_whisper(frames)
            if duration < 0.5:
                log.warning("[STT] audio too short (%.2fs)", duration)
                rumps.notification("GroqTalk", "", "Recording too short.")
                return

            raw_audio = np.concatenate(frames, axis=0)
            if is_audio_silent(raw_audio):
                log.warning("[STT] audio is silent -- skipping")
                rumps.notification("GroqTalk", "", "No sound detected. Check microphone.")
                return

            self._save_recording_wav(raw_audio)
            raw_text = self._transcribe_whisper(ogg_bytes, mime, duration)
            if not raw_text:
                return

            cleaned_text = self._enhance_transcript(raw_text)
            add_history_entry(self._last_recording_wav, raw_text, cleaned_text)
            clipboard_write(cleaned_text)
            log.debug("[STT] copied to clipboard, now auto-pasting...")
            if not simulate_paste():
                log.warning("[STT] auto-paste failed -- text is still in clipboard")

            total_time = time.time() - pipeline_start
            log.info("[STT] done in %.2fs", total_time)
            self._refresh_history()
            self._refresh_cost(None)
        except Exception as e:
            log.exception("[STT] pipeline error")
            rumps.notification("GroqTalk", "Error", str(e)[:100])
        finally:
            self.title = ICON_IDLE

    def _save_recording_wav(self, raw_audio: np.ndarray) -> None:
        """Trim and save raw audio as WAV for replay + history."""
        audio = trim_silence(raw_audio)
        wav_buf = io.BytesIO()
        sf.write(wav_buf, (audio * 32767).astype(np.int16), SAMPLE_RATE, format="WAV")
        self._last_recording_wav = wav_buf.getvalue()
        log.info("[STT] saved %d bytes WAV for replay", len(self._last_recording_wav))

    def _transcribe_whisper(
        self, ogg_bytes: bytes, mime: str, duration: float,
    ) -> str:
        """Send audio to Groq Whisper and return raw transcript."""
        log.info("[STT] sending to Groq Whisper (%s)...", WHISPER_MODEL)
        t0 = time.time()
        transcription = groq_client.audio.transcriptions.create(
            model=WHISPER_MODEL,
            file=("audio.ogg", ogg_bytes, mime),
            language="en", response_format="text",
        )
        elapsed = time.time() - t0
        raw_text = (
            transcription.text.strip()
            if hasattr(transcription, "text")
            else str(transcription).strip()
        )
        log.info("[STT] Whisper done in %.2fs -- %d chars", elapsed, len(raw_text))
        log_usage("whisper", audio_sec=duration)
        if not raw_text.strip():
            log.warning("[STT] empty transcript")
            rumps.notification("GroqTalk", "", "No speech detected.")
            return ""
        return raw_text

    def _enhance_transcript(self, raw_text: str) -> str:
        """Optionally clean up transcript with LLM."""
        word_count = len(raw_text.split())
        if not self._enhance_text:
            log.info("[STT] enhance OFF -- skipping LLM")
            return raw_text.strip()
        if word_count < LLM_SKIP_WORD_LIMIT:
            log.info("[STT] short text (%d words) -- skipping LLM", word_count)
            return raw_text.strip()
        log.info("[STT] sending to LLM (%s) for cleanup...", LLM_MODEL)
        t0 = time.time()
        completion = groq_client.chat.completions.create(
            messages=[
                {"role": "system", "content": LLM_SYSTEM_PROMPT},
                {"role": "user", "content": raw_text},
            ],
            model=LLM_MODEL, temperature=0.3, max_tokens=2048,
        )
        elapsed = time.time() - t0
        cleaned = completion.choices[0].message.content.strip()
        usage = completion.usage
        log_usage("llm", input_tokens=usage.prompt_tokens, output_tokens=usage.completion_tokens)
        log.info("[STT] LLM done in %.2fs -- %d chars", elapsed, len(cleaned))
        return cleaned

    # --- Replay latest recording -------------------------------------------

    def _stop_replay(self) -> None:
        """Stop any currently playing replay."""
        self._replay_generation += 1
        if self._replay_player and self._replay_player.isPlaying():
            self._replay_player.stop()
            log.info("[REPLAY] stopped previous playback")

    def _replay_recording(self) -> None:
        """Play back the latest voice recording (Cmd+Shift+R)."""
        self._stop_replay()
        entries = load_history()
        for e in reversed(entries):
            wav_path = e.get("wav", "")
            if wav_path and os.path.exists(wav_path):
                log.info("[REPLAY] playing %s", wav_path)
                gen = self._replay_generation
                threading.Thread(
                    target=self._run_replay, args=(wav_path, gen), daemon=True,
                ).start()
                return
        log.info("[REPLAY] no recording to replay")
        rumps.notification("GroqTalk", "", "No recording to replay.")

    def _replay_entry(self, sender: rumps.MenuItem) -> None:
        """Replay a specific history entry from the menu."""
        self._stop_replay()
        wav_path = sender.representedObject
        if wav_path and os.path.exists(wav_path):
            gen = self._replay_generation
            threading.Thread(
                target=self._run_replay, args=(wav_path, gen), daemon=True,
            ).start()
        else:
            rumps.notification("GroqTalk", "", "Recording file not found.")

    def _reuse_entry_text(self, sender: rumps.MenuItem) -> None:
        """Copy a history entry's cleaned text back to clipboard and paste."""
        text = sender.representedObject
        if text:
            clipboard_write(text)
            simulate_paste()
            log.info("[HISTORY] reused text: %s...", text[:60])

    def _run_replay(self, wav_path: str, gen: int) -> None:
        """Play a WAV file via AVAudioPlayer."""
        try:
            self.title = ICON_SPEAKING
            self._set_stop_visible(True)
            with open(wav_path, "rb") as f:
                wav_data = f.read()
            ns_data = NSData.dataWithBytes_length_(wav_data, len(wav_data))
            player, err = AVAudioPlayer.alloc().initWithData_error_(ns_data, None)
            if err or not player:
                log.error("[REPLAY] AVAudioPlayer init failed: %s", err)
                rumps.notification("GroqTalk", "", "Replay failed.")
                return
            self._replay_player = player
            player.prepareToPlay()
            player.play()
            while player.isPlaying():
                if self._replay_generation != gen:
                    player.stop()
                    log.info("[REPLAY] gen=%d cancelled", gen)
                    return
                time.sleep(0.05)
            log.info("[REPLAY] done")
        except Exception:
            log.exception("[REPLAY] error")
        finally:
            if self._replay_generation == gen:
                self.title = ICON_IDLE
                self._set_stop_visible(False)

    # --- Text-to-Speech (chunked pipeline) ---------------------------------

    def _speak_selected(self) -> None:
        was_speaking = self.title == ICON_SPEAKING
        self._tts_generation += 1
        gen = self._tts_generation
        subprocess.run(["pkill", "-f", "afplay"], capture_output=True)
        if was_speaking:
            log.info("[TTS] Cmd+Shift+D pressed while speaking -- stopped (gen=%d)", gen)
            self.title = ICON_IDLE
            self._set_stop_visible(False)
            return
        log.info("[TTS] Cmd+Shift+D pressed -- gen=%d, starting TTS", gen)
        threading.Thread(target=self._run_tts, args=(gen,), daemon=True).start()

    def _run_tts(self, gen: int) -> None:
        """Full TTS pipeline: get text -> chunk -> fetch audio -> play."""
        pipeline_start = time.time()
        try:
            text = get_selected_text()
            if self._tts_generation != gen:
                return
            if not text.strip():
                log.warning("[TTS] gen=%d no text selected", gen)
                rumps.notification("GroqTalk", "", "No text selected.")
                return
            self.title = ICON_SPEAKING
            self._set_stop_visible(True)

            cached = find_cached_tts(text)
            if cached:
                log.info("[TTS] gen=%d using cached TTS (%d bytes)", gen, len(cached))
                self._play_wav_bytes(cached, gen)
                log.info("[TTS] gen=%d cached playback done in %.2fs", gen, time.time() - pipeline_start)
                return

            chunks = split_text_chunks(text)
            log.info("[TTS] gen=%d text=%d chars -> %d chunks", gen, len(text), len(chunks))
            all_wav_data = self._stream_tts_chunks(chunks, gen)

            if all_wav_data and self._tts_generation == gen:
                save_tts_to_history(text, all_wav_data)
            log.info("[TTS] gen=%d done in %.2fs", gen, time.time() - pipeline_start)
            self._refresh_history()
            self._refresh_cost(None)
        except Exception as e:
            log.exception("[TTS] gen=%d pipeline error", gen)
            rumps.notification("GroqTalk", "TTS Error", str(e)[:100])
        finally:
            if self._tts_generation == gen:
                self.title = ICON_IDLE
                self._set_stop_visible(False)

    def _stream_tts_chunks(self, chunks: list[str], gen: int) -> bytes:
        """Prefetch and play TTS chunks. Returns concatenated WAV bytes."""
        prefetch_q: queue.Queue[tuple[int, bytes]] = queue.Queue()
        all_wav_data = b""

        def _fetch_chunk(idx: int, chunk_text: str) -> None:
            t0 = time.time()
            wav = b""
            try:
                with groq_client.audio.speech.with_streaming_response.create(
                    model=TTS_MODEL, voice=self._current_voice,
                    input=chunk_text, response_format="wav",
                ) as response:
                    for data in response.iter_bytes(chunk_size=8192):
                        if self._tts_generation != gen:
                            break
                        wav += data
            except Exception:
                log.exception("[TTS] gen=%d fetch error chunk %d", gen, idx)
            log.info(
                "[TTS] gen=%d chunk %d/%d fetched in %.2fs (%d bytes)",
                gen, idx + 1, len(chunks), time.time() - t0, len(wav),
            )
            prefetch_q.put((idx, wav))

        if chunks:
            threading.Thread(target=_fetch_chunk, args=(0, chunks[0]), daemon=True).start()

        for i in range(len(chunks)):
            if self._tts_generation != gen:
                break
            idx, wav_data = prefetch_q.get()
            if not wav_data or self._tts_generation != gen:
                break
            if i + 1 < len(chunks):
                threading.Thread(
                    target=_fetch_chunk, args=(i + 1, chunks[i + 1]), daemon=True,
                ).start()
            all_wav_data += wav_data
            log_usage("tts", chars=len(chunks[i]))
            self._play_wav_bytes(wav_data, gen)

        return all_wav_data

    def _play_wav_bytes(self, wav_data: bytes, gen: int) -> None:
        """Play WAV bytes via AVAudioPlayer with current speed setting."""
        ns_data = NSData.dataWithBytes_length_(wav_data, len(wav_data))
        player, err = AVAudioPlayer.alloc().initWithData_error_(ns_data, None)
        if err or not player:
            log.error("[PLAY] AVAudioPlayer init failed: %s", err)
            return
        player.setEnableRate_(True)
        player.setRate_(self._playback_rate)
        player.prepareToPlay()
        player.play()
        while player.isPlaying():
            if self._tts_generation != gen:
                player.stop()
                break
            time.sleep(0.05)

    # --- UI helpers ---------------------------------------------------------

    def _set_stop_visible(self, visible: bool) -> None:
        """Show/hide the Stop menu item."""
        try:
            self._stop_item._menuitem.setHidden_(not visible)
        except Exception:
            pass

    def _stop_all(self, _sender: object) -> None:
        """Stop all playback -- TTS, replay, everything."""
        self._tts_generation += 1
        self._stop_replay()
        subprocess.run(["pkill", "-f", "afplay"], capture_output=True)
        self.title = ICON_IDLE
        self._set_stop_visible(False)
        log.info("[STOP] all playback stopped")

    def _toggle_enhance(self, sender: rumps.MenuItem) -> None:
        self._enhance_text = not self._enhance_text
        sender.state = 1 if self._enhance_text else 0
        log.info("[UI] Enhance Text toggled: %s", "ON" if self._enhance_text else "OFF")

    def _set_voice(self, sender: rumps.MenuItem) -> None:
        self._current_voice = sender.representedObject
        for item in self._voice_menu.values():
            item.state = 1 if item.title == sender.title else 0
        log.info("[UI] Voice set to %s", self._current_voice)

    def _set_speed(self, sender: rumps.MenuItem) -> None:
        self._playback_rate = float(sender.title.replace("x", ""))
        for item in self._speed_menu.values():
            item.state = 1 if item.title == sender.title else 0
        log.info("[UI] Playback speed set to %sx", self._playback_rate)

    def _build_history_items(
        self, audios_menu: rumps.MenuItem, texts_menu: rumps.MenuItem,
    ) -> None:
        """Populate submenus from history."""
        entries = load_history()
        audio_count = 0
        for e in reversed(entries):
            if not (e.get("tts_wav") and os.path.exists(e["tts_wav"])):
                continue
            ago = relative_time(e.get("ts", ""))
            preview = (e.get("cleaned") or "")[:40]
            item = rumps.MenuItem(f"{ago} -- {preview}", callback=self._replay_entry)
            item.representedObject = e["tts_wav"]
            audios_menu.add(item)
            audio_count += 1
        if audio_count == 0:
            audios_menu.add(rumps.MenuItem("(no audios yet)"))

        text_count = 0
        for e in reversed(entries):
            text = e.get("cleaned") or e.get("transcript")
            if not text or not e.get("wav"):
                continue
            ago = relative_time(e.get("ts", ""))
            item = rumps.MenuItem(f"{ago} -- {text[:40]}", callback=self._reuse_entry_text)
            item.representedObject = text
            texts_menu.add(item)
            text_count += 1
        if text_count == 0:
            texts_menu.add(rumps.MenuItem("(no texts yet)"))

    def _refresh_history(self) -> None:
        """Rebuild Recent Audios and Recent Texts submenus."""
        try:
            self._audios_menu.clear()
            self._texts_menu.clear()
        except AttributeError:
            return
        self._build_history_items(self._audios_menu, self._texts_menu)

    def _refresh_cost(self, _sender: object) -> None:
        """Update cost display in menu."""
        cost, totals = get_cost_last_n_days(3)
        self._cost_item.title = f"Usage: ${cost:.4f} (3 days) | {totals['calls']} calls"
        log.debug(
            "[COST] $%.4f -- whisper=%.0fs, llm=%d+%d tok, tts=%d chars, calls=%d",
            cost, totals["whisper_sec"], totals["llm_in_tok"],
            totals["llm_out_tok"], totals["tts_chars"], totals["calls"],
        )

    def _quit(self, _sender: object) -> None:
        self._shutdown_event.set()
        try:
            self._persistent_stream.stop()
            self._persistent_stream.close()
        except Exception:
            pass
        unregister_all_hotkeys()
        rumps.quit_app()
