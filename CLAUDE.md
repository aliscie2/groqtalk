# CLAUDE.md — notes for future Claude sessions

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

## Architecture quick reference

- Swift macOS menu-bar app, built with `swiftc` + `build.sh` (no Xcode project).
- Lives in `/Applications/GroqTalk.app` after install; config in `~/.config/groqtalk/`.
- Spawns two local Python servers: `mlx_audio.server` on 8723 (TTS) and `whisper-server` on 8724 (STT).
- Hotkeys implemented in `GroqTalk/Services/HotkeyService.swift` via `CGEvent.tapCreate` (modifier-only detection for Fn / Ctrl+Option) + Carbon `RegisterEventHotKey` for Cmd+Shift+Space.
- Logs: `~/.config/groqtalk/groqtalk.log` (Swift side) and `~/.config/groqtalk/tts_server.log` (Python side).

## Quit bug — fixed but worth knowing

`AppDelegate.quit()` used to just `Process.terminate()` subprocesses and call `NSApplication.terminate(nil)`. In practice `mlx_audio.server` sometimes ignores SIGTERM mid-model-load, and `terminate(nil)` can stall on any lingering window. The current implementation sends SIGTERM, escalates to SIGKILL after 300 ms, runs `pkill -9` as belt-and-braces, and `exit(0)`s after 1 s if `terminate(nil)` hasn't fired.
