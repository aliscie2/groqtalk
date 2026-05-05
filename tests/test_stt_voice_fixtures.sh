#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

PORT="${STT_WHISPER_LARGE_PORT:-8725}"
MODEL="${STT_WHISPER_LARGE_MODEL:-$HOME/.config/groqtalk/models/ggml-large-v3-turbo-q5_0.bin}"
TMP="$(mktemp -d)"
STARTED_SERVER=""

cleanup() {
  if [ -n "$STARTED_SERVER" ]; then
    kill "$STARTED_SERVER" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

wait_for_port() {
  for _ in $(seq 1 30); do
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  return 1
}

if ! lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  [ -x /opt/homebrew/bin/whisper-server ] || fail "whisper-server is missing"
  [ -f "$MODEL" ] || fail "Whisper Large model is missing at $MODEL"

  echo "[setup] starting temporary whisper-server on :$PORT"
  /opt/homebrew/bin/whisper-server \
    --model "$MODEL" \
    --host 127.0.0.1 \
    --port "$PORT" \
    --language en \
    --flash-attn \
    -bs 1 > "$TMP/whisper-large.log" 2>&1 &
  STARTED_SERVER="$!"
  wait_for_port || {
    cat "$TMP/whisper-large.log" >&2
    fail "whisper-server did not open :$PORT"
  }
else
  echo "[setup] using existing whisper-server on :$PORT"
fi

swiftc \
  tests/test_stt_voice_fixtures.swift \
  GroqTalk/API/GroqAPIClient.swift \
  GroqTalk/Storage/ConfigManager.swift \
  GroqTalk/Utilities/StructuredTranscript.swift \
  GroqTalk/Utilities/TranscriptPostProcessor.swift \
  GroqTalk/Utilities/DictionaryCorrector.swift \
  GroqTalk/Utilities/KokoroVoiceResolver.swift \
  -o "$TMP/test_stt_voice_fixtures"

"$TMP/test_stt_voice_fixtures"
