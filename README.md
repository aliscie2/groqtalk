# GroqTalk

Voice-to-text and text-to-speech menubar app for macOS. Local-only. Lives in your menu bar — press Fn to dictate, Ctrl+Option to speak selected text aloud.

## Features

- **Speech-to-text** via Parakeet-TDT v2 (`mlx-community/parakeet-tdt-0.6b-v2`). 60–120× real-time on Apple Silicon; beats Whisper-large on the English OpenASR benchmark.
- **Text-to-speech** via Kokoro (`mlx-community/Kokoro-82M-bf16`) with 9 preset voices.
- **Smart chunking** — Apple `NLTagger` sentence segmentation with an atomic-span mask so URLs, numbers, versions, quoted strings, parentheticals, code, and markdown emphasis never get cut mid-word.
- **Hotkeys** — Fn to dictate + auto-paste, Ctrl+Option to read selected text aloud, Cmd+Shift+Space for live dictation.
- **Custom dictionary** for domain-specific terms.
- **100% local** — no cloud, no API keys, no network.

## Requirements

- macOS 14+ (Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`)
- Homebrew Python 3.11 (`brew install python@3.11`)
- `pip install -U mlx-audio` (serves both Kokoro and Parakeet on port 8723)

## Installation

```bash
# 1. Clone
git clone https://github.com/aliscie2/groqtalk.git
cd groqtalk

# 2. One-time: create a stable self-signed identity so macOS Accessibility
#    grants survive every rebuild. See "Accessibility gotcha" below.
bash scripts/create-signing-cert.sh

# 3. One-time: patch the installed mlx-audio package with the PR #594
#    serialization lock. Without this, concurrent TTS+STT inference
#    corrupts the Metal command buffer and the server crashes every
#    ~3 requests. Idempotent — safe to re-run after a pip upgrade.
bash scripts/patch-mlx-audio.sh

# 4. Build + install
chmod +x build.sh
./build.sh
cp -R build/GroqTalk.app /Applications/
open /Applications/GroqTalk.app
```

On first launch:
1. **Grant Accessibility** (System Settings → Privacy & Security → Accessibility).
2. **Grant Input Monitoring** (same pane) — this is a separate TCC service on macOS 10.15+; without it `tapCreate` succeeds but delivers zero events.
3. **Grant Microphone** when prompted.

First use will pull the Parakeet and Kokoro models from Hugging Face (~2.3 GB + ~160 MB). Subsequent runs load instantly.

### Hotkey troubleshooting

If global hotkeys stop working, check `~/.config/groqtalk/groqtalk.log` and follow this list in order:

1. **Secure Input is active.** Any NSSecureTextField with keyboard focus (1Password auto-type, Terminal "Secure Keyboard Entry", sudo prompt, password dialog) silently gags every CGEventTap on the machine. The menu-bar icon gets a 🔒 prefix and the log shows `[SECURE-INPUT] transitioned to true`. Close the password field; hotkeys return instantly.
2. **Missing permissions.** Log shows `Accessibility trusted: true | Input Monitoring: true` when correct. Input Monitoring is a separate grant — both are needed.
3. **Rebuild without stable signing.** Verify with `codesign -dvv /Applications/GroqTalk.app | grep Authority` — should be `GroqTalk Local`, not `(ad-hoc)`. If ad-hoc, run `scripts/create-signing-cert.sh` once and rebuild.
4. **Stale cache after system event.** Quit + relaunch. The tap self-heals on wake-from-sleep and space changes, but a full relaunch always fixes it.

### TTS/STT server crashes

If the mlx_audio server crashes with SIGSEGV after a few requests, the serialization patch wasn't applied. Run:

```bash
bash scripts/patch-mlx-audio.sh
pkill -9 -f mlx_audio.server   # app will auto-respawn
```

## Custom Dictionary

Add domain-specific words/phrases (one per line) to `~/.config/groqtalk/dictionary.txt` to bias the STT.

## Hotkeys

| Shortcut | Action |
|----------|--------|
| `Fn` (tap) | Toggle recording → transcribe + paste |
| `Ctrl+Option` (tap) | Read selected text aloud (TTS) |
| `Cmd+Shift+Space` | Live dictation |

## License

MIT
