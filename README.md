# GroqTalk

Voice-to-text and text-to-speech menubar app for macOS. Lives in your menu bar — hold a hotkey to record, release to transcribe and auto-paste.

## Features

- **Voice-to-text** via Groq Cloud or local Whisper (small/large, auto-selected by RAM)
- **Text-to-speech** with Kokoro TTS (multiple voices)
- **Grammar correction** via Llama 3.3 70B on Groq
- **Custom dictionary** for domain-specific terms
- **Hotkeys**: hold to record, release to transcribe + paste
- **Local-first**: supports fully offline STT with whisper.cpp / mlx-whisper

## Requirements

- macOS 13.0+ (Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`)
- A [Groq API key](https://console.groq.com/) (for cloud STT and grammar correction)

## Installation

```bash
# 1. Clone
git clone https://github.com/aliscie2/groqtalk.git
cd groqtalk

# 2. One-time: create a stable code-signing identity so macOS Accessibility
#    permission survives every rebuild (see "Accessibility gotcha" below).
bash scripts/create-signing-cert.sh

# 3. Build
chmod +x build.sh
./build.sh

# 4. Run
open build/GroqTalk.app
```

On first launch you'll need to:
1. **Grant Accessibility** permission (System Settings → Privacy & Security → Accessibility → enable GroqTalk)
2. **Grant Microphone** permission when prompted
3. **Set your Groq API key** from the menubar icon → Settings

### Hotkey troubleshooting (if Ctrl+Option / Fn do nothing)

If global hotkeys stop working, the problem is almost always one of these four, in decreasing order of likelihood. Check `~/.config/groqtalk/groqtalk.log`.

1. **Secure Input mode.** If a password-style text field has keyboard focus *anywhere on the system* (1Password auto-type, Terminal "Secure Keyboard Entry", sudo prompt, an open password dialog), macOS silently gags every CGEventTap — GroqTalk's included. The menu-bar icon shows a 🔒 prefix and the log shows `[SECURE-INPUT] transitioned to true`. Close the password field and hotkeys return instantly.
2. **Missing permissions.** Grant both **Accessibility** AND **Input Monitoring** in System Settings → Privacy & Security. Input Monitoring is a separate service from Accessibility; GroqTalk prompts for both but you have to accept both. Log at startup shows `Accessibility trusted: true | Input Monitoring: true` when correct.
3. **Rebuild without stable signing.** If you skipped `scripts/create-signing-cert.sh`, every rebuild is ad-hoc signed and macOS silently revokes your TCC grant. Run the script once, rebuild, re-grant once, done forever. Verify with `codesign -dvv /Applications/GroqTalk.app | grep Authority` — should be `GroqTalk Local`, not `(ad-hoc)`.
4. **Stale cache after system event.** `AXIsProcessTrusted()` is per-process cached. If you granted permissions to an already-running app, quit from the menu bar and relaunch. The app also self-heals the tap on wake-from-sleep and space changes, but if it ever stops responding: `pkill -9 -f GroqTalk.app && open /Applications/GroqTalk.app`.

## Local STT Setup (Optional)

For offline transcription, download Whisper models to `~/.config/groqtalk/models/`:

| Model | File | RAM needed |
|-------|------|------------|
| Small (fast) | `ggml-small.en.bin` | 8GB+ |
| Large (accurate) | `ggml-large-v3-turbo-q5_0.bin` | 24GB+ |

The app auto-selects the best model based on your Mac's RAM.

## Custom Dictionary

Add domain-specific words/phrases (one per line) to `~/.config/groqtalk/dictionary.txt` to improve transcription accuracy.

## Hotkeys

| Shortcut | Action |
|----------|--------|
| `Fn` (tap) | Toggle recording → transcribe + paste |
| `Ctrl+Option` (tap) | Read selected text aloud (TTS) |

## License

MIT
