# CLAUDE.md — notes for future Claude sessions

## "Global hotkey does nothing" — triage checklist

**When a user says Ctrl+Option / Fn / Cmd+Shift+Space doesn't work, check these four things in order.** They account for ~100% of hotkey failures we've seen, and each one looks like "the hotkey is broken" from the user's perspective.

1. **Secure Input is active.** `grep SECURE-INPUT ~/.config/groqtalk/groqtalk.log`. If `transitioned to true` appears and you don't see a matching `false`, a password field somewhere on the system is gagging every CGEventTap (ours, everyone's). Ask the user to close any open password/API-key prompt. `ps -E | grep _SECURE_INPUT` identifies the culprit process. **This repo used to trigger it on itself** — the API-key dialog was an NSSecureTextField. Now it's NSTextField (`GroqTalk/Menu/StatusBarController.swift`), but any other app (1Password auto-type, Terminal "Secure Keyboard Entry", sudo prompt) can still turn it on.
2. **Stable signing missing.** `codesign -dvv /Applications/GroqTalk.app | grep Authority` must show `Authority=GroqTalk Local`. If it shows `(ad-hoc)`, every rebuild invalidates the TCC grant — see "Accessibility / TCC" below.
3. **TCC permissions.** Log should show `Accessibility trusted: true | Input Monitoring: true` at startup. If either is false, grant in System Settings → Privacy & Security. **Input Monitoring is a SEPARATE permission from Accessibility** on macOS 10.15+; the app prompts for both via `AccessibilityChecker.checkAndPrompt()`. Tap creation succeeds even without Input Monitoring — it just delivers zero events, which looks identical to the hotkey being "broken".
4. **Tap silently died.** Log should show `[HOTKEY] Fn + Ctrl+Option tap installed!`. If it's there but no `ctrl+opt DOWN` ever follows a real keypress, the tap stopped delivering events without firing tapDisabled (known macOS bug after Stage Manager toggles / display sleep). The `HotkeyService.installHealthMonitor()` heartbeat + wake/space-change observers rebuild the tap; if they fail, `pkill -9 -f GroqTalk.app && open /Applications/GroqTalk.app` is the sledgehammer.

## Accessibility / TCC — the single most important gotcha

**Symptom:** User reports a global hotkey (Ctrl+Option, Fn, Cmd+Shift+Space) does nothing. The log shows `Accessibility trusted: false` and then `[HOTKEY] Waiting for Accessibility — retrying every 3s` with no further events.

**Root cause:** macOS TCC binds Accessibility grants to the app's **code-signing identity**, and ad-hoc signing (`codesign -s -`) produces a new identity every build. Rebuilds silently invalidate the grant. This has burned us for hours — do not underestimate it.

**The fix is already in this repo:**
1. `scripts/create-signing-cert.sh` — run once to create a stable self-signed cert `GroqTalk Local` in the user's login keychain.
2. `build.sh` — auto-detects the cert and signs with it; falls back to ad-hoc with a big warning if the cert is missing.
3. `GroqTalk/Utilities/AccessibilityChecker.swift` — does **NOT** call `tccutil reset` (an earlier version did; it was catastrophic: wiped the user's grant on every launch).

**Debug checklist if it happens again:**
- `codesign -dvv /Applications/GroqTalk.app | grep Authority` — should show `Authority=GroqTalk Local`, not `Authority=(ad-hoc)`.
- `security find-certificate -c "GroqTalk Local" ~/Library/Keychains/login.keychain-db` — cert should be in login keychain.
- Log should show `Accessibility trusted: true` and `[HOTKEY] Fn + Ctrl+Option tap installed!` after a relaunch once granted.
- If needed: `tccutil reset Accessibility com.groqtalk.app` to wipe stale rows, then re-add via System Settings.
- `AXIsProcessTrusted()` is cached per-process at launch — always advise the user to **quit and relaunch** after granting, not just retry the hotkey.

**Do NOT:**
- Call `tccutil reset` from inside the app.
- Change the bundle ID (`com.groqtalk.app`) — TCC rows are keyed by it.
- Switch back to ad-hoc signing in `build.sh`.

## mlx-audio serialization patch — required for Parakeet stability

**Symptom:** `mlx_audio.server` crashes with SIGSEGV / SIGABRT after ~3 Parakeet requests. Log line: `[KOKORO] server exited (code=11)` or `(code=6)`, with `resource_tracker: leaked semaphore` warning in the tail of `tts_server.log`.

**Root cause:** MLX Metal is not thread-safe. Uvicorn's threadpool runs request handlers in parallel, two concurrent `model.generate()` calls corrupt the Metal command buffer, the process aborts. Upstream fix is [mlx-audio PR #594](https://github.com/Blaizzy/mlx-audio/pull/594) — still open as of April 2026.

**The fix lives in this repo:** `scripts/patch-mlx-audio.sh`. It's idempotent; re-runs are no-ops. Users must run it once after `pip install mlx-audio` AND again after any `pip install -U mlx-audio`. If PR #594 ever merges, the script becomes harmless.

**Do NOT:**
- Run Parakeet STT without the patch (three requests then crash).
- Assume that upgrading mlx-audio fixes this — PR is still open.
- Swap in `parakeet-mlx` CLI per-request (model cold-load kills latency).

## Architecture quick reference

- Swift macOS menu-bar app, built with `swiftc` + `build.sh` (no Xcode project).
- Lives in `/Applications/GroqTalk.app` after install; config in `~/.config/groqtalk/`.
- **One** local Python server: `mlx_audio.server` on 8723 hosts both Kokoro TTS and Parakeet STT. Patched with the PR #594 serialization lock so TTS + STT inference can't race.
- STT default: `mlx-community/parakeet-tdt-0.6b-v2`. TTS default: `mlx-community/Kokoro-82M-bf16`.
- Hotkeys: `CGEvent.tapCreate` (modifier-only Fn / Ctrl+Option) + Carbon `RegisterEventHotKey` for Cmd+Shift+Space. See `GroqTalk/Services/HotkeyService.swift`.
- Chunking: Apple `NLTagger` sentence segmentation + atomic-span mask (URLs via `NSDataDetector`, regex for versions/decimals/markdown-emphasis/inline-code, paired brackets/quotes). See `GroqTalk/Utilities/TextChunker.swift`.
- Logs: `~/.config/groqtalk/groqtalk.log` (Swift) and `~/.config/groqtalk/tts_server.log` (Python, append-only so crash tracebacks survive respawn).

## Intentional non-features (document pushback so future Claude doesn't re-add)

- **No per-word click-to-seek.** Kokoro doesn't emit native timestamps; faking them via whisper post-alignment or character-weighted proportional mapping was rejected by the user as "a trick." Chunk-level click-to-jump remains (chunk boundaries ARE real audio splits).
- **No karaoke per-word highlighting.** Same reason. Chunk-level active/done states are the hierarchy.
- **No cloud** — Groq, OpenAI, ElevenLabs, Azure all removed / rejected. Local-only.
- **No LLM text preprocessor** — user rejected the "AI polish display" idea in favor of deterministic NLTagger chunking.
- **No Whisper.** Parakeet-TDT beats Whisper-large on English and runs faster. Whisper Small/Large paths were stripped along with the `start_stt.sh` launcher and `WordAligner`.

## Quit bug — fixed but worth knowing

`AppDelegate.quit()` used to just `Process.terminate()` subprocesses and call `NSApplication.terminate(nil)`. In practice `mlx_audio.server` sometimes ignores SIGTERM mid-model-load, and `terminate(nil)` can stall on any lingering window. The current implementation sends SIGTERM, escalates to SIGKILL after 300 ms, runs `pkill -9` as belt-and-braces, and `exit(0)`s after 1 s if `terminate(nil)` hasn't fired.
