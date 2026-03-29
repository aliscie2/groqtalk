# GroqTalk Design

## Overview
Minimal Python menubar app for voice-to-text using Groq APIs. Hold Fn key to speak, release to get clean formatted text in clipboard.

## Architecture
- **App shell:** `rumps` menubar app (mic icon in macOS menu bar)
- **Hotkey:** `pynput` global listener — hold Fn to record, release to stop
- **Recording:** `sounddevice` captures mic → WAV temp file
- **Transcription:** Groq Whisper API (`whisper-large-v3-turbo`)
- **Cleanup:** Groq LLM (`llama-3.3-70b-versatile`) — fix grammar, punctuation, formatting
- **Output:** `pyperclip` copies to clipboard + macOS notification

## Flow
1. User holds Fn key
2. Menubar icon changes to recording state
3. Audio captured via sounddevice
4. User releases Fn key
5. Audio saved as temp WAV
6. WAV sent to Groq Whisper → raw transcript
7. Raw transcript sent to Groq LLM → cleaned text
8. Cleaned text copied to clipboard
9. macOS notification: "Text copied to clipboard"
10. Menubar icon returns to idle state

## Dependencies
- rumps, sounddevice, numpy, groq, pynput, pyperclip

## API Key
Reuse existing Groq key from `~/Desktop/weekaly.com/.env` (VITE_GROQ_API_KEY)

## Location
`~/Desktop/groqtalk/` — single `groqtalk.py` + requirements.txt
