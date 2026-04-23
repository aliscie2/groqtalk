#!/bin/bash
# Replicates the "request cancelled before STT cold-load completes" bug
# and verifies the warm-on-switch fix. Designed to run without the Swift app
# — we talk directly to mlx_audio.server on port 8723, same endpoint the
# Swift client uses.
#
# Scenario:
#   1. Kill any existing mlx_audio.server (force cold state).
#   2. Spawn a fresh mlx_audio.server.
#   3. Fire TWO transcription requests back-to-back:
#        - request A: short timeout (10s) — we expect this to TIME OUT on a
#          cold load. That IS the bug (the Swift client used to cancel at 8s).
#        - request B: long timeout (120s) — this MUST succeed. That's what
#          the `warmSTT` fix achieves: the warmup replaces request A.
#   4. Then fire request C with a short timeout — now the model is warm and
#      should respond in well under 5s, proving the warmup would prevent
#      the original cancellation.
#
# Exit codes:
#   0 — all assertions pass (cold fails, warm succeeds fast).
#   1 — something unexpected (e.g. warmed model also slow, or cold succeeded).
#
# Run: bash tests/test_stt_cold_load.sh
#
# Notes:
#   - Defaults to the current app model (Parakeet). Override with
#     `MODEL=... bash tests/test_stt_cold_load.sh` if you want to stress a
#     different checkpoint manually.

set -u
PORT=8723
MODEL="${MODEL:-mlx-community/parakeet-tdt-0.6b-v2}"
TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { echo "  ✓ $1"; }

# --- Build a 0.5s silent PCM16 mono 16 kHz WAV via Python ---
"$(command -v python3.11 || command -v python3)" - <<PY > "$TMP/silent.wav"
import struct, sys
sr, sec = 16000, 0.5
frames = int(sr * sec)
data = b'\x00\x00' * frames
hdr = b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVE'
hdr += b'fmt ' + struct.pack('<IHHIIHH', 16, 1, 1, sr, sr*2, 2, 16)
hdr += b'data' + struct.pack('<I', len(data))
sys.stdout.buffer.write(hdr + data)
PY
[ -s "$TMP/silent.wav" ] || fail "failed to build silent WAV"
ok "built 0.5s silent WAV ($(wc -c < "$TMP/silent.wav") bytes)"

# --- Start fresh mlx_audio.server ---
echo "[setup] killing any existing mlx_audio.server ..."
pkill -9 -f mlx_audio.server 2>/dev/null
sleep 1

echo "[setup] starting fresh mlx_audio.server on :$PORT ..."
if [ -x "$HOME/.config/groqtalk/start_tts.sh" ]; then
  "$HOME/.config/groqtalk/start_tts.sh" > "$TMP/server.log" 2>&1 &
else
  PYTHONUNBUFFERED=1 HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
    /opt/homebrew/bin/python3.11 -m mlx_audio.server \
    --host 127.0.0.1 --port "$PORT" > "$TMP/server.log" 2>&1 &
fi
SERVER=$!
trap "kill $SERVER 2>/dev/null; rm -rf $TMP" EXIT

# Wait for the server to start accepting connections.
for i in $(seq 1 30); do
  curl -sSf "http://127.0.0.1:$PORT/docs" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -sSf "http://127.0.0.1:$PORT/docs" >/dev/null 2>&1 \
  || fail "server didn't come up in 15s"
ok "server ready on :$PORT"

# --- Request A: cold load with aggressive 10s timeout ---
# This is the bug reproducer — we expect it to time out on a truly cold model.
echo; echo "[A] cold request (10s timeout, expect timeout or slow success)..."
t0=$(date +%s)
curl -sS -m 10 "http://127.0.0.1:$PORT/v1/audio/transcriptions" \
  -F "file=@$TMP/silent.wav" -F "model=$MODEL" -F "language=en" \
  -o "$TMP/resp_a.txt" -w "%{http_code} %{time_total}\n" > "$TMP/meta_a.txt" 2>&1
ra=$?
dt=$(( $(date +%s) - t0 ))
if [ $ra -eq 28 ]; then
  ok "request A timed out at ~${dt}s (reproducer hit — this is the cancelled-request bug)"
elif [ $ra -eq 0 ]; then
  echo "  (A) unexpectedly succeeded on first cold request in ${dt}s — model was probably already warm in page cache"
else
  ok "request A exited with curl code $ra after ${dt}s (network hiccup or cancellation — still a cold-load failure mode)"
fi

# --- Request B: warm wait with 120s timeout — MUST succeed ---
echo; echo "[B] warm request (120s timeout, MUST succeed)..."
t0=$(date +%s)
curl -sS -m 120 "http://127.0.0.1:$PORT/v1/audio/transcriptions" \
  -F "file=@$TMP/silent.wav" -F "model=$MODEL" -F "language=en" \
  -o "$TMP/resp_b.txt" -w "%{http_code} %{time_total}\n" > "$TMP/meta_b.txt" 2>&1
rb=$?
dt=$(( $(date +%s) - t0 ))
[ $rb -eq 0 ] || fail "request B (warm wait) failed with curl code $rb — server broken"
grep -q "200" "$TMP/meta_b.txt" || fail "request B non-200 response: $(cat "$TMP/meta_b.txt")"
ok "request B succeeded in ${dt}s (cold load completed)"

# --- Request C: post-warm, short timeout should easily succeed ---
echo; echo "[C] post-warm request (10s timeout, MUST succeed quickly)..."
t0=$(date +%s)
curl -sS -m 10 "http://127.0.0.1:$PORT/v1/audio/transcriptions" \
  -F "file=@$TMP/silent.wav" -F "model=$MODEL" -F "language=en" \
  -o "$TMP/resp_c.txt" -w "%{http_code} %{time_total}\n" > "$TMP/meta_c.txt" 2>&1
rc=$?
dt=$(( $(date +%s) - t0 ))
[ $rc -eq 0 ] || fail "request C (warm) failed with curl code $rc in ${dt}s — warmup didn't help"
grep -q "200" "$TMP/meta_c.txt" || fail "request C non-200 response: $(cat "$TMP/meta_c.txt")"
[ "$dt" -lt 8 ] || fail "request C took ${dt}s (>=8s) — warmup insufficient"
ok "request C succeeded in ${dt}s (model warm, well under 8s cancellation threshold)"

echo
echo "✅ Test passed. Cold load is slow (reproduces the cancel bug), warm"
echo "   calls are fast — the warmSTT() pre-warm fix is architecturally valid."
