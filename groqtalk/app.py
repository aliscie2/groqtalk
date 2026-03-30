"""GroqTalkApp -- native PyObjC NSStatusBar app (no rumps dependency)."""
from __future__ import annotations

import io
import os
import queue
import subprocess
import threading
import time

import numpy as np
import sounddevice as sd
import soundfile as sf
from AVFoundation import AVAudioPlayer
from Foundation import (
    NSData, NSObject, NSUserNotification, NSUserNotificationCenter,
)
from AppKit import (
    NSApplication, NSStatusBar, NSMenu, NSMenuItem,
    NSVariableStatusItemLength,
)

from .config import (
    log, groq_client, is_ax_trusted,
    SAMPLE_RATE, CHANNELS, WHISPER_MODEL, LLM_MODEL, LLM_SYSTEM_PROMPT,
    TTS_MODEL, TTS_VOICE, TTS_VOICES, LLM_SKIP_WORD_LIMIT,
    ICON_IDLE, ICON_RECORDING, ICON_PROCESSING, ICON_SPEAKING,
    kVK_ANSI_A, kVK_ANSI_D, kVK_ANSI_R, kVK_ANSI_S, cmdKey, shiftKey,
)
from .hotkeys import (
    install_carbon_hotkey_handler, register_hotkey, unregister_all_hotkeys,
)
from .audio import (
    is_audio_silent, trim_silence, prepare_audio_for_whisper,
    split_text_chunks, clean_text_for_speech,
)
from .clipboard import clipboard_write, simulate_paste, get_selected_text
from .history import (
    log_usage, get_cost_last_n_days,
    load_history, add_history_entry, save_tts_to_history,
    find_cached_tts, relative_time,
)


# ======================================================================
# Main-thread dispatch via performSelectorOnMainThread
# ======================================================================

class _UIProxy(NSObject):
    """NSObject subclass that drains closures on the main thread."""

    _instance = None
    _pending_calls: list = []
    _pending_lock = threading.Lock()

    @classmethod
    def shared(cls) -> _UIProxy:
        if cls._instance is None:
            cls._instance = cls.alloc().init()
        return cls._instance

    def runPending_(self, _sender: object) -> None:
        with type(self)._pending_lock:
            calls = list(type(self)._pending_calls)
            type(self)._pending_calls.clear()
        for fn in calls:
            try:
                fn()
            except Exception:
                log.exception("[UIProxy] error in main-thread closure")


def _on_main(fn: object) -> None:
    """Dispatch *fn* to the main thread via performSelectorOnMainThread."""
    proxy = _UIProxy.shared()
    with type(proxy)._pending_lock:
        type(proxy)._pending_calls.append(fn)
    proxy.performSelectorOnMainThread_withObject_waitUntilDone_(
        "runPending:", None, False,
    )


def _notify(title: str, subtitle: str, message: str) -> None:
    """Post a macOS notification on the main thread."""
    def _do() -> None:
        n = NSUserNotification.alloc().init()
        n.setTitle_(title)
        n.setSubtitle_(subtitle)
        n.setInformativeText_(message)
        NSUserNotificationCenter.defaultUserNotificationCenter().deliverNotification_(n)
    _on_main(_do)


# ======================================================================
# Menu delegate -- routes NSMenuItem selectors back to GroqTalkApp
# ======================================================================

class _Delegate(NSObject):
    """Routes NSMenuItem actions back to the GroqTalkApp instance."""

    _app_ref: GroqTalkApp | None = None

    def menuRecord_(self, sender: object) -> None:
        self._app_ref._toggle_recording()

    def menuSpeak_(self, sender: object) -> None:
        self._app_ref._speak_selected()

    def menuReplay_(self, sender: object) -> None:
        self._app_ref._replay_recording()

    def menuStop_(self, sender: object) -> None:
        self._app_ref._stop_all()

    def menuToggleEnhance_(self, sender: object) -> None:
        self._app_ref._menu_toggle_enhance()

    def menuSetVoice_(self, sender: object) -> None:
        self._app_ref._menu_set_voice(sender)

    def menuSetSpeed_(self, sender: object) -> None:
        self._app_ref._menu_set_speed(sender)

    def menuRefreshCost_(self, sender: object) -> None:
        self._app_ref._refresh_cost()

    def menuReplayEntry_(self, sender: object) -> None:
        self._app_ref._replay_entry(sender.representedObject())

    def menuReuseText_(self, sender: object) -> None:
        self._app_ref._reuse_entry_text(sender.representedObject())

    def menuQuit_(self, sender: object) -> None:
        self._app_ref._quit()


# ======================================================================
# GroqTalkApp
# ======================================================================

class GroqTalkApp:
    """Menubar app for voice-to-text and text-to-speech using native PyObjC."""

    LIVE_INTERVAL: float = 5.0

    def __init__(self) -> None:
        self._app = NSApplication.sharedApplication()
        self._app.setActivationPolicy_(2)  # NSApplicationActivationPolicyProhibited

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
        self._stream = None
        self._title: str = ICON_IDLE
        self._ax_paste_warned: bool = False

        self._delegate = _Delegate.alloc().init()
        self._delegate._app_ref = self

        self._build_status_item()
        self._refresh_cost()
        self._setup_hotkeys()
        threading.Thread(target=self._keep_alive, daemon=False).start()
        threading.Thread(target=self._warm_connection, daemon=True).start()
        log.info("GroqTalk started -- look for %s in menu bar", ICON_IDLE)
        log.info(
            "Hotkeys: Cmd+Shift+A (Record/STT) | Cmd+Shift+D (Speak) "
            "| Cmd+Shift+R (Replay) | Cmd+Shift+S (Stop)",
        )

    # ------------------------------------------------------------------
    # Status bar + menu  (BUG FIX #1: setAutoenablesItems_ + setEnabled_)
    # ------------------------------------------------------------------

    def _build_status_item(self) -> None:
        """Create the NSStatusItem and its menu."""
        self._status_item = NSStatusBar.systemStatusBar().statusItemWithLength_(
            NSVariableStatusItemLength,
        )
        self._status_item.setTitle_(ICON_IDLE)
        self._status_item.setHighlightMode_(True)

        menu = NSMenu.alloc().init()
        menu.setAutoenablesItems_(False)

        self._menu = menu
        self._add_record_item(menu)
        self._add_speak_item(menu)
        self._add_replay_item(menu)
        self._add_stop_item(menu)
        menu.addItem_(NSMenuItem.separatorItem())
        self._add_history_submenus(menu)
        menu.addItem_(NSMenuItem.separatorItem())
        self._add_enhance_item(menu)
        self._add_voice_submenu(menu)
        self._add_speed_submenu(menu)
        self._add_cost_item(menu)
        menu.addItem_(NSMenuItem.separatorItem())
        self._add_quit_item(menu)

        self._status_item.setMenu_(menu)

    def _add_record_item(self, menu: NSMenu) -> None:
        item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Speech \u2192 Text  (\u2318\u21e7A)", "menuRecord:", "",
        )
        item.setTarget_(self._delegate)
        item.setEnabled_(True)
        menu.addItem_(item)

    def _add_speak_item(self, menu: NSMenu) -> None:
        item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Speak Selection  (\u2318\u21e7D)", "menuSpeak:", "",
        )
        item.setTarget_(self._delegate)
        item.setEnabled_(True)
        menu.addItem_(item)

    def _add_replay_item(self, menu: NSMenu) -> None:
        item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Replay Latest   (\u2318\u21e7R)", "menuReplay:", "",
        )
        item.setTarget_(self._delegate)
        item.setEnabled_(True)
        menu.addItem_(item)

    def _add_stop_item(self, menu: NSMenu) -> None:
        self._stop_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "\u23f9 Stop  (\u2318\u21e7S)", "menuStop:", "",
        )
        self._stop_item.setTarget_(self._delegate)
        self._stop_item.setEnabled_(True)
        self._stop_item.setHidden_(True)
        menu.addItem_(self._stop_item)

    def _add_history_submenus(self, menu: NSMenu) -> None:
        # Recent Audios
        self._audios_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Recent Audios", None, "",
        )
        self._audios_item.setEnabled_(True)
        self._audios_submenu = NSMenu.alloc().init()
        self._audios_submenu.setAutoenablesItems_(False)
        self._audios_item.setSubmenu_(self._audios_submenu)
        menu.addItem_(self._audios_item)

        # Recent Texts
        self._texts_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Recent Texts", None, "",
        )
        self._texts_item.setEnabled_(True)
        self._texts_submenu = NSMenu.alloc().init()
        self._texts_submenu.setAutoenablesItems_(False)
        self._texts_item.setSubmenu_(self._texts_submenu)
        menu.addItem_(self._texts_item)

        self._build_history_items()

    def _add_enhance_item(self, menu: NSMenu) -> None:
        self._enhance_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "\u2713 Enhance Text (LLM)", "menuToggleEnhance:", "",
        )
        self._enhance_item.setTarget_(self._delegate)
        self._enhance_item.setEnabled_(True)
        self._enhance_item.setState_(1)
        menu.addItem_(self._enhance_item)

    def _add_voice_submenu(self, menu: NSMenu) -> None:
        voice_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Voice", None, "",
        )
        voice_item.setEnabled_(True)
        self._voice_submenu = NSMenu.alloc().init()
        self._voice_submenu.setAutoenablesItems_(False)
        for voice in TTS_VOICES:
            icon = "\U0001f469" if voice in ("hannah", "diana", "autumn") else "\U0001f468"
            vi = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                f"{icon} {voice}", "menuSetVoice:", "",
            )
            vi.setTarget_(self._delegate)
            vi.setEnabled_(True)
            vi.setRepresentedObject_(voice)
            if voice == TTS_VOICE:
                vi.setState_(1)
            self._voice_submenu.addItem_(vi)
        voice_item.setSubmenu_(self._voice_submenu)
        menu.addItem_(voice_item)

    def _add_speed_submenu(self, menu: NSMenu) -> None:
        speed_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Playback Speed", None, "",
        )
        speed_item.setEnabled_(True)
        self._speed_submenu = NSMenu.alloc().init()
        self._speed_submenu.setAutoenablesItems_(False)
        for rate in ("0.75x", "1.0x", "1.25x", "1.5x", "1.75x", "2.0x"):
            si = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                rate, "menuSetSpeed:", "",
            )
            si.setTarget_(self._delegate)
            si.setEnabled_(True)
            if rate == "1.0x":
                si.setState_(1)
            self._speed_submenu.addItem_(si)
        speed_item.setSubmenu_(self._speed_submenu)
        menu.addItem_(speed_item)

    def _add_cost_item(self, menu: NSMenu) -> None:
        self._cost_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Usage: $0.00 (3 days)", "menuRefreshCost:", "",
        )
        self._cost_item.setTarget_(self._delegate)
        self._cost_item.setEnabled_(True)
        menu.addItem_(self._cost_item)

    def _add_quit_item(self, menu: NSMenu) -> None:
        item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Quit", "menuQuit:", "",
        )
        item.setTarget_(self._delegate)
        item.setEnabled_(True)
        menu.addItem_(item)

    # ------------------------------------------------------------------
    # Title property
    # ------------------------------------------------------------------

    @property
    def title(self) -> str:
        return self._title

    @title.setter
    def title(self, value: str) -> None:
        self._title = value
        self._status_item.setTitle_(value)

    # ------------------------------------------------------------------
    # History submenus
    # ------------------------------------------------------------------

    def _build_history_items(self) -> None:
        """Populate Recent Audios / Recent Texts submenus."""
        self._audios_submenu.removeAllItems()
        self._texts_submenu.removeAllItems()
        entries = load_history()
        self._populate_audio_history(entries)
        self._populate_text_history(entries)

    def _populate_audio_history(self, entries: list[dict]) -> None:
        count = 0
        for e in reversed(entries):
            if not (e.get("tts_wav") and os.path.exists(e["tts_wav"])):
                continue
            ago = relative_time(e.get("ts", ""))
            preview = (e.get("cleaned") or "")[:40]
            item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                f"{ago} -- {preview}", "menuReplayEntry:", "",
            )
            item.setTarget_(self._delegate)
            item.setEnabled_(True)
            item.setRepresentedObject_(e["tts_wav"])
            self._audios_submenu.addItem_(item)
            count += 1
        if count == 0:
            ph = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "(no audios yet)", None, "",
            )
            self._audios_submenu.addItem_(ph)

    def _populate_text_history(self, entries: list[dict]) -> None:
        count = 0
        for e in reversed(entries):
            text = e.get("cleaned") or e.get("transcript")
            if not text or not e.get("wav"):
                continue
            ago = relative_time(e.get("ts", ""))
            item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                f"{ago} -- {text[:40]}", "menuReuseText:", "",
            )
            item.setTarget_(self._delegate)
            item.setEnabled_(True)
            item.setRepresentedObject_(text)
            self._texts_submenu.addItem_(item)
            count += 1
        if count == 0:
            ph = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
                "(no texts yet)", None, "",
            )
            self._texts_submenu.addItem_(ph)

    def _refresh_history(self) -> None:
        self._build_history_items()

    def _refresh_cost(self) -> None:
        cost, totals = get_cost_last_n_days(3)
        self._cost_item.setTitle_(
            f"Usage: ${cost:.4f} (3 days) | {totals['calls']} calls",
        )

    # ------------------------------------------------------------------
    # Audio stream (on-demand)
    # ------------------------------------------------------------------

    def _audio_callback(
        self, indata: np.ndarray, frames: int,
        time_info: object, status: object,
    ) -> None:
        if status:
            log.warning("[REC] audio callback status: %s", status)
        if self.recording:
            self._audio_frames.append(indata.copy())

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def _keep_alive(self) -> None:
        while not self._shutdown_event.is_set():
            time.sleep(1)
        log.info("[KEEPALIVE] shutdown")

    def _warm_connection(self) -> None:
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
        register_hotkey(kVK_ANSI_S, cmdKey | shiftKey, 4, lambda: self._stop_all())

    def run(self) -> None:
        """Start the NSApplication run loop."""
        self._app.run()

    # ------------------------------------------------------------------
    # Speech-to-Text
    # ------------------------------------------------------------------

    def _toggle_recording(self) -> None:
        log.info("[REC] Cmd+Shift+A pressed -- recording=%s", self.recording)
        if self.recording:
            self._stop_recording()
        else:
            self._start_recording()

    def _start_recording(self) -> None:
        log.info("[REC] starting recording...")
        self._audio_frames = []
        self._live_transcript = ""
        try:
            self._stream = sd.InputStream(
                samplerate=SAMPLE_RATE, channels=CHANNELS,
                dtype="float32", callback=self._audio_callback,
            )
            self._stream.start()
            self.recording = True
            self._ui_set_title(ICON_RECORDING)
            log.info(
                "[REC] stream opened -- device=%s",
                sd.query_devices(sd.default.device[0])["name"],
            )
            threading.Thread(target=self._live_transcribe, daemon=True).start()
        except Exception:
            log.exception("[REC] failed to open mic -- check permission")
            self._ui_set_title(ICON_IDLE)

    def _live_transcribe(self) -> None:
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
            self._transcribe_live_chunk(new_frames, parts)
        log.info("[LIVE] thread stopped -- %d parts collected", len(parts))

    def _transcribe_live_chunk(
        self, frames: list[np.ndarray], parts: list[str],
    ) -> None:
        try:
            ogg_bytes, mime, duration = prepare_audio_for_whisper(frames)
            if duration < 0.5:
                return
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
                log.info("[LIVE] %.1fs -> Whisper in %.2fs: %s", duration, elapsed, text[:80])
        except Exception:
            log.exception("[LIVE] partial transcription error")

    def _stop_recording(self) -> None:
        log.info("[REC] stopping -- %d frames captured", len(self._audio_frames))
        self.recording = False
        self._ui_set_title(ICON_PROCESSING)
        frames = list(self._audio_frames)
        # Don't call stream.abort()/close() — causes PortAudio deadlock.
        # Just drop the reference; GC + PortAudio handle cleanup.
        self._stream = None
        log.info("[REC] stream released, processing %d frames", len(frames))

        def _process() -> None:
            try:
                self._process_audio(frames)
            except Exception:
                log.exception("[STT] thread crashed")
                self._ui_set_title(ICON_IDLE)

        threading.Thread(target=_process, daemon=True).start()
        log.info("[REC] stream closed")

    def _process_audio(self, frames: list[np.ndarray]) -> None:
        pipeline_start = time.time()
        log.info("[STT] final pipeline started, frames=%d", len(frames))
        try:
            if not frames:
                _notify("GroqTalk", "", "No audio captured.")
                return
            ogg_bytes, mime, duration = prepare_audio_for_whisper(frames)
            if duration < 0.5:
                _notify("GroqTalk", "", "Recording too short.")
                return
            raw_audio = np.concatenate(frames, axis=0)
            if is_audio_silent(raw_audio):
                _notify("GroqTalk", "", "No sound detected. Check microphone.")
                return
            self._save_recording_wav(raw_audio)
            raw_text = self._transcribe_whisper(ogg_bytes, mime, duration)
            if not raw_text:
                return
            cleaned_text = self._enhance_transcript(raw_text)
            add_history_entry(self._last_recording_wav, raw_text, cleaned_text)
            clipboard_write(cleaned_text)
            self._do_auto_paste()
            log.info("[STT] done in %.2fs", time.time() - pipeline_start)
            self._ui_refresh()
        except Exception as e:
            log.exception("[STT] pipeline error")
            _notify("GroqTalk", "Error", str(e)[:100])
        finally:
            self._ui_set_title(ICON_IDLE)

    def _do_auto_paste(self) -> None:
        """BUG FIX #2: check AXIsProcessTrusted before paste."""
        if not is_ax_trusted():
            if not self._ax_paste_warned:
                self._ax_paste_warned = True
                _notify(
                    "GroqTalk",
                    "Grant Accessibility for auto-paste",
                    "Text copied to clipboard. Enable Accessibility to auto-paste.",
                )
            log.info("[STT] skipping paste -- no Accessibility")
            return
        if not simulate_paste():
            log.warning("[STT] auto-paste failed -- text is still in clipboard")

    def _save_recording_wav(self, raw_audio: np.ndarray) -> None:
        audio = trim_silence(raw_audio)
        wav_buf = io.BytesIO()
        sf.write(
            wav_buf, (audio * 32767).astype(np.int16),
            SAMPLE_RATE, format="WAV",
        )
        self._last_recording_wav = wav_buf.getvalue()
        log.info("[STT] saved %d bytes WAV for replay", len(self._last_recording_wav))

    def _transcribe_whisper(
        self, ogg_bytes: bytes, mime: str, duration: float,
    ) -> str:
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
            _notify("GroqTalk", "", "No speech detected.")
            return ""
        return raw_text

    def _enhance_transcript(self, raw_text: str) -> str:
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
        log_usage(
            "llm",
            input_tokens=usage.prompt_tokens,
            output_tokens=usage.completion_tokens,
        )
        log.info("[STT] LLM done in %.2fs -- %d chars", elapsed, len(cleaned))
        return cleaned

    # ------------------------------------------------------------------
    # Replay
    # ------------------------------------------------------------------

    def _stop_replay(self) -> None:
        self._replay_generation += 1
        if self._replay_player and self._replay_player.isPlaying():
            self._replay_player.stop()
            log.info("[REPLAY] stopped previous playback")

    def _replay_recording(self) -> None:
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
        _notify("GroqTalk", "", "No recording to replay.")

    def _replay_entry(self, wav_path: str) -> None:
        self._stop_replay()
        if wav_path and os.path.exists(wav_path):
            gen = self._replay_generation
            threading.Thread(
                target=self._run_replay, args=(wav_path, gen), daemon=True,
            ).start()
        else:
            _notify("GroqTalk", "", "Recording file not found.")

    def _reuse_entry_text(self, text: str) -> None:
        if text:
            clipboard_write(text)
            simulate_paste()
            log.info("[HISTORY] reused text: %s...", text[:60])

    def _run_replay(self, wav_path: str, gen: int) -> None:
        try:
            self._ui_set_title(ICON_SPEAKING)
            self._ui_set_stop(True)
            with open(wav_path, "rb") as f:
                wav_data = f.read()
            ns_data = NSData.dataWithBytes_length_(wav_data, len(wav_data))
            player, err = AVAudioPlayer.alloc().initWithData_error_(ns_data, None)
            if err or not player:
                log.error("[REPLAY] AVAudioPlayer init failed: %s", err)
                _notify("GroqTalk", "", "Replay failed.")
                return
            self._replay_player = player
            player.prepareToPlay()
            player.play()
            while player.isPlaying():
                if self._replay_generation != gen:
                    player.stop()
                    return
                time.sleep(0.05)
        except Exception:
            log.exception("[REPLAY] error")
        finally:
            if self._replay_generation == gen:
                self._ui_set_title(ICON_IDLE)
                self._ui_set_stop(False)

    # ------------------------------------------------------------------
    # TTS
    # ------------------------------------------------------------------

    def _speak_selected(self) -> None:
        was_speaking = self._title == ICON_SPEAKING
        self._tts_generation += 1
        gen = self._tts_generation
        subprocess.run(["pkill", "-f", "afplay"], capture_output=True)
        if was_speaking:
            log.info("[TTS] stopped (gen=%d)", gen)
            self._ui_set_title(ICON_IDLE)
            self._ui_set_stop(False)
            return
        log.info("[TTS] starting TTS gen=%d", gen)
        threading.Thread(target=self._run_tts, args=(gen,), daemon=True).start()

    def _run_tts(self, gen: int) -> None:
        pipeline_start = time.time()
        try:
            text = get_selected_text()
            if self._tts_generation != gen:
                return
            if not text.strip():
                _notify("GroqTalk", "", "No text selected.")
                return
            self._ui_set_title(ICON_SPEAKING)
            self._ui_set_stop(True)
            cached = find_cached_tts(text)
            if cached:
                log.info("[TTS] gen=%d cache hit (%d bytes)", gen, len(cached))
                self._play_wav_bytes(cached, gen)
                return
            speech_text = clean_text_for_speech(text)
            log.debug("[TTS] cleaned for speech: %s", speech_text[:120])
            chunks = split_text_chunks(speech_text)
            log.info("[TTS] gen=%d %d chars -> %d chunks", gen, len(speech_text), len(chunks))
            all_wav = self._stream_tts_chunks(chunks, gen)
            if all_wav and self._tts_generation == gen:
                save_tts_to_history(text, all_wav)
            log.info("[TTS] gen=%d done in %.2fs", gen, time.time() - pipeline_start)
            self._ui_refresh()
        except Exception as e:
            log.exception("[TTS] gen=%d pipeline error", gen)
            _notify("GroqTalk", "TTS Error", str(e)[:100])
        finally:
            if self._tts_generation == gen:
                self._ui_set_title(ICON_IDLE)
                self._ui_set_stop(False)

    def _stream_tts_chunks(self, chunks: list[str], gen: int) -> bytes:
        prefetch_q: queue.Queue[tuple[int, bytes]] = queue.Queue()
        all_wav = b""

        if chunks:
            threading.Thread(
                target=self._fetch_tts_chunk,
                args=(0, chunks[0], gen, chunks, prefetch_q),
                daemon=True,
            ).start()

        for i in range(len(chunks)):
            if self._tts_generation != gen:
                break
            idx, wav_data = prefetch_q.get()
            if not wav_data or self._tts_generation != gen:
                break
            if i + 1 < len(chunks):
                threading.Thread(
                    target=self._fetch_tts_chunk,
                    args=(i + 1, chunks[i + 1], gen, chunks, prefetch_q),
                    daemon=True,
                ).start()
            all_wav += wav_data
            log_usage("tts", chars=len(chunks[i]))
            self._play_wav_bytes(wav_data, gen)

        return all_wav

    def _fetch_tts_chunk(
        self, idx: int, chunk_text: str, gen: int,
        chunks: list[str], q: queue.Queue,
    ) -> None:
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
        q.put((idx, wav))

    def _play_wav_bytes(self, wav_data: bytes, gen: int) -> None:
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

    # ------------------------------------------------------------------
    # UI helpers (BUG FIX #3: ALL dispatched to main thread)
    # ------------------------------------------------------------------

    def _ui_set_title(self, icon: str) -> None:
        _on_main(lambda: setattr(self, "title", icon))

    def _ui_set_stop(self, visible: bool) -> None:
        def _do() -> None:
            try:
                self._stop_item.setHidden_(not visible)
            except Exception:
                pass
        _on_main(_do)

    def _ui_refresh(self) -> None:
        _on_main(lambda: (self._refresh_history(), self._refresh_cost()))

    def _stop_all(self) -> None:
        """Nuclear stop — kills recording, TTS, replay, everything."""
        # Stop recording if active
        if self.recording:
            self.recording = False
            self._stream = None
            log.info("[STOP] recording stopped")
        # Stop TTS
        self._tts_generation += 1
        # Stop replay
        self._stop_replay()
        # Kill any external audio
        subprocess.run(["pkill", "-f", "afplay"], capture_output=True)
        # Reset UI
        self._ui_set_title(ICON_IDLE)
        self._ui_set_stop(False)
        log.info("[STOP] all stopped")

    # ------------------------------------------------------------------
    # Menu action handlers
    # ------------------------------------------------------------------

    def _menu_toggle_enhance(self) -> None:
        self._enhance_text = not self._enhance_text
        self._enhance_item.setState_(1 if self._enhance_text else 0)
        label = "\u2713 Enhance Text (LLM)" if self._enhance_text else "Enhance Text (LLM)"
        self._enhance_item.setTitle_(label)
        log.info("[UI] Enhance Text: %s", "ON" if self._enhance_text else "OFF")

    def _menu_set_voice(self, sender: object) -> None:
        self._current_voice = sender.representedObject()
        for i in range(self._voice_submenu.numberOfItems()):
            item = self._voice_submenu.itemAtIndex_(i)
            item.setState_(1 if item.title() == sender.title() else 0)
        log.info("[UI] Voice set to %s", self._current_voice)

    def _menu_set_speed(self, sender: object) -> None:
        self._playback_rate = float(sender.title().replace("x", ""))
        for i in range(self._speed_submenu.numberOfItems()):
            item = self._speed_submenu.itemAtIndex_(i)
            item.setState_(1 if item.title() == sender.title() else 0)
        log.info("[UI] Playback speed set to %sx", self._playback_rate)

    def _quit(self) -> None:
        self._shutdown_event.set()
        if self._stream:
            try:
                self._stream.abort()
                self._stream.close()
            except Exception:
                pass
        unregister_all_hotkeys()
        self._app.terminate_(None)
