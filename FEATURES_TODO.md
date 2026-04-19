# GroqTalk Features — Local-Only TODO

All cloud-dependent features excluded. Everything below runs on-device.

## Summary

- **6 quick wake-ups** (~25 lines total) — code exists, needs UX exposure
- **1 already wired** — no work needed
- **5 new features** (~155 lines total) — small additions, all local
- **2 deferred** — need a local LLM install (~2GB model)

## All 16 features

| #  | Feature                              | Effort            | Type              | Notes                                           |
|----|--------------------------------------|-------------------|-------------------|-------------------------------------------------|
| 1  | Parakeet STT discoverable            | 5 lines           | wake-up           | Already installed, buried in menu               |
| 2  | Chatterbox TTS discoverable          | 5 lines           | wake-up           | Higher-quality voice, already a menu option     |
| 3  | Show current voice in status bar     | 2 lines           | wake-up           | Makes voice picker findable                     |
| 4  | Pre-fill dictionary with tech terms  | 1 file            | wake-up           | Improves STT accuracy on first run              |
| 5  | Playback speed remembered            | 3 lines           | wake-up           | Persist user's speed choice across launches     |
| 6  | Live streaming STT hotkey            | 3 lines           | wake-up           | `liveLoop` already exists, just bind a key      |
| 7  | Recent audio -> dialog               | done              | already wired     | Clicking Recent Audio reopens TTS dialog        |
| 8  | Audio separations endpoint           | 40 lines          | new               | Denoise recordings via `/v1/audio/separations`  |
| 9  | Whisper word timestamps              | 30 lines          | new               | Karaoke-style word sync in dialog               |
| 10 | Model hot-swap                       | 20 lines          | new               | Unload unused voices to free RAM                |
| 11 | Queue multiple texts                 | 50 lines          | new               | Speak multiple copied snippets back-to-back     |
| 12 | "Speak clipboard" hotkey             | 5 lines           | wake-up           | Separate from Ctrl+Option, reads clipboard now  |
| 13 | Adaptive voice by content            | 15 lines          | new               | Auto-pick voice/speed for short vs long text    |
| 14 | Summarize before TTS                 | 80 lines + 2GB    | deferred (LLM)    | Needs local mlx_lm + Qwen 1.5B installed first  |
| 15 | Translate before TTS                 | 80 lines + 2GB    | deferred (LLM)    | Same local LLM as #14                           |
| 16 | Export TTS to MP3                    | REMOVED           | --                | Not wanted                                      |

## Top 3 most powerful to do now

1. **Whisper word timestamps** (#9) — dialog becomes karaoke, word-by-word sync. Biggest visible impact.
2. **Live streaming STT hotkey** (#6) — unlocks real-time dictation in any app. Code exists, just needs binding.
3. **Audio separations** (#8) — cleaner mic input = more accurate STT on noisy recordings.

## Wake-ups batch (recommended first commit)

Do items 1, 2, 3, 4, 5, 6, 12 together — roughly 25 lines total, all local, no risk:

- Default discoverable voices + alt TTS engine
- Voice in status bar
- Dictionary pre-filled
- Speed persisted
- Live STT bound
- Clipboard hotkey
