#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  cat <<'USAGE'
Usage:
  scripts/add-stt-fixture.sh <name> <expected_text> [wav_path] [required_phrases_csv]

If wav_path is omitted, the latest GroqTalk history recording is used.
Example:
  scripts/add-stt-fixture.sh mesh_llm "Test, test, mesh LLM." "" "mesh LLM,Tauri app"
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi
[ $# -ge 2 ] || { usage >&2; exit 1; }

NAME="$1"
EXPECTED="$2"
WAV_PATH="${3:-}"
REQUIRED_CSV="${4:-}"

if [ -z "$WAV_PATH" ]; then
  WAV_PATH="$(ls -t "$HOME"/.config/groqtalk/history/rec_*.wav 2>/dev/null | head -n 1 || true)"
fi

[ -n "$WAV_PATH" ] || { echo "No GroqTalk history recording found." >&2; exit 1; }
[ -f "$WAV_PATH" ] || { echo "WAV not found: $WAV_PATH" >&2; exit 1; }

SLUG="$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+|_+$//g')"
[ -n "$SLUG" ] || { echo "Fixture name produced an empty slug." >&2; exit 1; }

FIXTURE_DIR="tests/fixtures/stt"
MANIFEST="$FIXTURE_DIR/manifest.json"
DEST="$FIXTURE_DIR/$SLUG.wav"

mkdir -p "$FIXTURE_DIR"
cp "$WAV_PATH" "$DEST"

python3 - "$MANIFEST" "$SLUG" "$DEST" "$EXPECTED" "$REQUIRED_CSV" <<'PY'
import json
import os
import sys

manifest_path, name, wav_path, expected, required_csv = sys.argv[1:]
manifest = {"fixtures": []}
if os.path.exists(manifest_path):
    with open(manifest_path, "r", encoding="utf-8") as f:
        manifest = json.load(f)

required = [p.strip() for p in required_csv.split(",") if p.strip()]
fixture = {
    "name": name,
    "wavPath": wav_path,
    "mode": "whisperLarge",
    "expectedText": expected,
    "requiredPhrases": required,
    "maxEditDistanceRatio": 0.28,
}

fixtures = [f for f in manifest.get("fixtures", []) if f.get("name") != name]
fixtures.append(fixture)
manifest["fixtures"] = fixtures

with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

echo "Added STT fixture:"
echo "  $DEST"
echo "  $MANIFEST"
echo
echo "Run: bash tests/test_stt_voice_fixtures.sh"
