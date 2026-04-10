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

# 2. Build
chmod +x build.sh
./build.sh

# 3. Run
open build/GroqTalk.app
```

On first launch you'll need to:
1. **Grant Accessibility** permission (System Settings → Privacy & Security → Accessibility → enable GroqTalk)
2. **Grant Microphone** permission when prompted
3. **Set your Groq API key** from the menubar icon → Settings

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
