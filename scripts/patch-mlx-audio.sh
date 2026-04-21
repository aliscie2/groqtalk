#!/bin/bash
# Backport of mlx-audio PR #594 (https://github.com/Blaizzy/mlx-audio/pull/594)
# into the locally-installed mlx_audio package. Idempotent — re-running after
# a pip upgrade re-applies the patch if mlx_audio has been reinstalled.
#
# Why: MLX Metal is not thread-safe. Uvicorn's threadpool runs request
# handlers in parallel, so two concurrent model.generate() calls corrupt
# the Metal command buffer and the process aborts with SIGSEGV / SIGABRT
# after ~3 requests. PR #594 adds an asyncio lock; this script adds a
# threading.RLock which works across both TTS (async) and STT (sync)
# paths of mlx_audio.server.
#
# Run once after `pip install mlx-audio` or after upgrading mlx-audio.
# The local patched server file lives at:
#   $(python -c 'import mlx_audio; print(mlx_audio.__path__[0])')/server.py
set -e

PY=${PYTHON:-/opt/homebrew/bin/python3.11}
FILE=$("$PY" -c 'import mlx_audio, os; print(os.path.join(mlx_audio.__path__[0], "server.py"))')
if [ ! -f "$FILE" ]; then
  echo "server.py not found at $FILE — is mlx-audio installed?"
  exit 1
fi

if grep -q '_MLX_INFERENCE_LOCK' "$FILE"; then
  echo "Already patched: $FILE"
  exit 0
fi

cp "$FILE" "$FILE.bak"
"$PY" - "$FILE" <<'PY'
import re, sys
path = sys.argv[1]
src = open(path).read()

# 1) Insert the module-level lock after `import asyncio`.
lock_block = '''import asyncio
import threading
# LOCAL PATCH (backport of https://github.com/Blaizzy/mlx-audio/pull/594):
# MLX Metal is not thread-safe. Serialize every model.generate() call with
# a reentrant lock to prevent concurrent Metal command buffer corruption.
_MLX_INFERENCE_LOCK = threading.RLock()
'''
src = re.sub(r'^import asyncio\s*\n', lock_block, src, count=1, flags=re.M)

# 2) Wrap the STT generator body with the lock.
src = re.sub(
    r'def generate_transcription_stream\(stt_model, tmp_path: str, gen_kwargs: dict\):\s*\n\s*"""[^"]+"""\s*\n(\s*)try:\s*\n(?:\s*#[^\n]*\n)*\s*result = stt_model\.generate\(tmp_path, \*\*gen_kwargs\)',
    '''def generate_transcription_stream(stt_model, tmp_path: str, gen_kwargs: dict):
    """Generator that yields transcription chunks and cleans up temp file."""
\\1try:
\\1    with _MLX_INFERENCE_LOCK:
\\1        result = stt_model.generate(tmp_path, **gen_kwargs)''',
    src,
)

# 3) Wrap the TTS for-loop in generate_audio with the lock.
src = re.sub(
    r'(\n    for result in model\.generate\(\n[\s\S]+?yield buffer\.getvalue\(\)\n)',
    '''
    _MLX_INFERENCE_LOCK.acquire()
    try:
\\1    finally:
      _MLX_INFERENCE_LOCK.release()
''',
    src, count=1,
)

open(path, 'w').write(src)
print(f'Patched: {path}')
PY

echo "Done. Backup at $FILE.bak"
