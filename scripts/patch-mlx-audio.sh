#!/bin/bash
# Patch the locally-installed mlx_audio runtime so every MLX inference path
# is serialized on Apple Silicon. This prevents shared Parakeet/Kokoro usage
# from corrupting Metal command buffers when requests overlap.
#
# The script is idempotent and can also patch a test copy by setting:
#   FILE_OVERRIDE=/path/to/server.py ./scripts/patch-mlx-audio.sh
set -euo pipefail

PY=${PYTHON:-/opt/homebrew/bin/python3.11}
FILE=${FILE_OVERRIDE:-$("$PY" -c 'import mlx_audio, os; print(os.path.join(mlx_audio.__path__[0], "server.py"))')}

if [ ! -f "$FILE" ]; then
  echo "server.py not found at $FILE"
  exit 1
fi

if grep -q '_MLX_INFERENCE_LOCK = threading.RLock()' "$FILE"; then
  echo "Already patched: $FILE"
  exit 0
fi

cp "$FILE" "$FILE.bak"
"$PY" - "$FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
src = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global src
    if old not in src:
        raise SystemExit(f"Could not find {label} block to patch")
    src = src.replace(old, new, 1)


replace_once(
    "import asyncio\n",
    "import asyncio\nimport threading\n",
    "asyncio import",
)

replace_once(
    'MLX_AUDIO_NUM_WORKERS = os.getenv("MLX_AUDIO_NUM_WORKERS", "2")\n',
    '''MLX_AUDIO_NUM_WORKERS = os.getenv("MLX_AUDIO_NUM_WORKERS", "2")

# LOCAL PATCH (GroqTalk):
# MLX Metal is not thread-safe when multiple model.generate() calls overlap
# inside the shared server process. Serialize every model load / inference path
# so Parakeet STT and Kokoro TTS cannot corrupt the command buffer when
# requests race.
_MLX_INFERENCE_LOCK = threading.RLock()
''',
    "module lock",
)

replace_once(
    '''    def load_model(self, model_name: str):
        if model_name not in self.models:
            self.models[model_name] = load_model(model_name)

        return self.models[model_name]
''',
    '''    def load_model(self, model_name: str):
        with _MLX_INFERENCE_LOCK:
            if model_name not in self.models:
                self.models[model_name] = load_model(model_name)

            return self.models[model_name]
''',
    "ModelProvider.load_model",
)

replace_once(
    '''    for result in model.generate(
        payload.input,
        voice=payload.voice,
        speed=payload.speed,
        gender=payload.gender,
        pitch=payload.pitch,
        instruct=payload.instruct,
        lang_code=payload.lang_code,
        ref_audio=ref_audio,
        ref_text=payload.ref_text,
        temperature=payload.temperature,
        top_p=payload.top_p,
        top_k=payload.top_k,
        repetition_penalty=payload.repetition_penalty,
        stream=payload.stream,
        streaming_interval=payload.streaming_interval,
        max_tokens=payload.max_tokens,
        verbose=payload.verbose,
    ):

        if payload.stream:
            buffer = io.BytesIO()
            audio_write(
                buffer, result.audio, result.sample_rate, format=payload.response_format
            )
            yield buffer.getvalue()
        else:
            audio_chunks.append(result.audio)
            if sample_rate is None:
                sample_rate = result.sample_rate

    if payload.stream:
        return

    if not audio_chunks:
        raise HTTPException(status_code=400, detail="No audio generated")

    concatenated_audio = np.concatenate(audio_chunks)
    buffer = io.BytesIO()
    audio_write(buffer, concatenated_audio, sample_rate, format=payload.response_format)
    yield buffer.getvalue()
''',
    '''    response_chunks = []
    with _MLX_INFERENCE_LOCK:
        for result in model.generate(
            payload.input,
            voice=payload.voice,
            speed=payload.speed,
            gender=payload.gender,
            pitch=payload.pitch,
            instruct=payload.instruct,
            lang_code=payload.lang_code,
            ref_audio=ref_audio,
            ref_text=payload.ref_text,
            temperature=payload.temperature,
            top_p=payload.top_p,
            top_k=payload.top_k,
            repetition_penalty=payload.repetition_penalty,
            stream=payload.stream,
            streaming_interval=payload.streaming_interval,
            max_tokens=payload.max_tokens,
            verbose=payload.verbose,
        ):

            if payload.stream:
                buffer = io.BytesIO()
                audio_write(
                    buffer, result.audio, result.sample_rate, format=payload.response_format
                )
                response_chunks.append(buffer.getvalue())
            else:
                audio_chunks.append(result.audio)
                if sample_rate is None:
                    sample_rate = result.sample_rate

        if not payload.stream:
            if not audio_chunks:
                raise HTTPException(status_code=400, detail="No audio generated")

            concatenated_audio = np.concatenate(audio_chunks)
            buffer = io.BytesIO()
            audio_write(
                buffer, concatenated_audio, sample_rate, format=payload.response_format
            )
            response_chunks.append(buffer.getvalue())

    for chunk in response_chunks:
        yield chunk
''',
    "generate_audio",
)

replace_once(
    '''def generate_transcription_stream(stt_model, tmp_path: str, gen_kwargs: dict):
    """Generator that yields transcription chunks and cleans up temp file."""
    try:
        # Call generate with stream=True (models handle streaming internally)
        result = stt_model.generate(tmp_path, **gen_kwargs)

        # Check if result is a generator (streaming mode)
        if hasattr(result, "__iter__") and hasattr(result, "__next__"):
            accumulated_text = ""
            for chunk in result:
                # Handle different chunk types (string tokens vs structured chunks)
                if isinstance(chunk, str):
                    accumulated_text += chunk
                    chunk_data = {"text": chunk, "accumulated": accumulated_text}
                else:
                    # Structured chunk (e.g., Whisper streaming)
                    chunk_data = {
                        "text": chunk.text,
                        "start": getattr(chunk, "start_time", None),
                        "end": getattr(chunk, "end_time", None),
                        "is_final": getattr(chunk, "is_final", None),
                        "language": getattr(chunk, "language", None),
                    }
                yield json.dumps(sanitize_for_json(chunk_data)) + "\\n"
        else:
            # Not a generator, yield the full result
            yield json.dumps(sanitize_for_json(result)) + "\\n"
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
''',
    '''def generate_transcription_stream(stt_model, tmp_path: str, gen_kwargs: dict):
    """Generator that yields transcription chunks and cleans up temp file."""
    try:
        lines = []
        with _MLX_INFERENCE_LOCK:
            # Call generate with stream=True (models handle streaming internally)
            result = stt_model.generate(tmp_path, **gen_kwargs)

            # Check if result is a generator (streaming mode)
            if hasattr(result, "__iter__") and hasattr(result, "__next__"):
                accumulated_text = ""
                for chunk in result:
                    # Handle different chunk types (string tokens vs structured chunks)
                    if isinstance(chunk, str):
                        accumulated_text += chunk
                        chunk_data = {"text": chunk, "accumulated": accumulated_text}
                    else:
                        # Structured chunk (e.g., Whisper streaming)
                        chunk_data = {
                            "text": chunk.text,
                            "start": getattr(chunk, "start_time", None),
                            "end": getattr(chunk, "end_time", None),
                            "is_final": getattr(chunk, "is_final", None),
                            "language": getattr(chunk, "language", None),
                        }
                    lines.append(json.dumps(sanitize_for_json(chunk_data)) + "\\n")
            else:
                # Not a generator, yield the full result
                lines.append(json.dumps(sanitize_for_json(result)) + "\\n")

        for line in lines:
            yield line
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
''',
    "generate_transcription_stream",
)

replace_once(
    '''    try:
        # Load model and processor
        if SAM_PROCESSOR is None:
            SAM_PROCESSOR = SAMAudioProcessor.from_pretrained(model)
        if SAM_MODEL is None:
            SAM_MODEL = SAMAudio.from_pretrained(model)

        # Process inputs
        batch = SAM_PROCESSOR(
            descriptions=[description],
            audios=[tmp_path],
        )

        # Calculate step_size from steps
        step_size = 2 / (steps * 2)  # e.g., 16 steps -> 2/32 = 0.0625
        ode_opt = {"method": method, "step_size": step_size}

        # Separate audio
        result = SAM_MODEL.separate_long(
            audios=batch.audios,
            descriptions=batch.descriptions,
            anchor_ids=batch.anchor_ids,
            anchor_alignment=batch.anchor_alignment,
            ode_opt=ode_opt,
            ode_decode_chunk_size=50,
        )

        mx.clear_cache()

        # Convert results to numpy
        target_audio = np.array(result.target[0])
        residual_audio = np.array(result.residual[0])
        sample_rate = SAM_MODEL.sample_rate

        # Encode as base64 WAV
        def audio_to_base64(audio_array, sr):
            buffer = io.BytesIO()
            sf.write(buffer, audio_array, sr, format="wav")
            buffer.seek(0)
            return base64.b64encode(buffer.read()).decode("utf-8")

        return SeparationResponse(
            target=audio_to_base64(target_audio, sample_rate),
            residual=audio_to_base64(residual_audio, sample_rate),
            sample_rate=sample_rate,
        )
''',
    '''    try:
        with _MLX_INFERENCE_LOCK:
            # Load model and processor
            if SAM_PROCESSOR is None:
                SAM_PROCESSOR = SAMAudioProcessor.from_pretrained(model)
            if SAM_MODEL is None:
                SAM_MODEL = SAMAudio.from_pretrained(model)

            # Process inputs
            batch = SAM_PROCESSOR(
                descriptions=[description],
                audios=[tmp_path],
            )

            # Calculate step_size from steps
            step_size = 2 / (steps * 2)  # e.g., 16 steps -> 2/32 = 0.0625
            ode_opt = {"method": method, "step_size": step_size}

            # Separate audio
            result = SAM_MODEL.separate_long(
                audios=batch.audios,
                descriptions=batch.descriptions,
                anchor_ids=batch.anchor_ids,
                anchor_alignment=batch.anchor_alignment,
                ode_opt=ode_opt,
                ode_decode_chunk_size=50,
            )

            mx.clear_cache()

            # Convert results to numpy
            target_audio = np.array(result.target[0])
            residual_audio = np.array(result.residual[0])
            sample_rate = SAM_MODEL.sample_rate

        # Encode as base64 WAV
        def audio_to_base64(audio_array, sr):
            buffer = io.BytesIO()
            sf.write(buffer, audio_array, sr, format="wav")
            buffer.seek(0)
            return base64.b64encode(buffer.read()).decode("utf-8")

        return SeparationResponse(
            target=audio_to_base64(target_audio, sample_rate),
            residual=audio_to_base64(residual_audio, sample_rate),
            sample_rate=sample_rate,
        )
''',
    "audio_separations",
)

replace_once(
    '''    if supports_stream and streaming:
        result_iter = stt_model.generate(
            mx.array(audio_array), stream=True, language=language, verbose=False
        )
        accumulated = ""
        detected_language = language
        for chunk in result_iter:
            delta = (
                chunk if isinstance(chunk, str) else getattr(chunk, "text", str(chunk))
            )
            accumulated += delta
            # Pick up detected language from streaming results
            chunk_lang = getattr(chunk, "language", None)
            if chunk_lang and detected_language is None:
                detected_language = chunk_lang
            await websocket.send_json({"type": "delta", "delta": delta})

        await websocket.send_json(
            {
                "type": "complete",
                "text": accumulated,
                "segments": None,
                "language": detected_language,
                "is_partial": is_partial,
            }
        )
    else:
        tmp_path = f"/tmp/realtime_{time.time()}.mp3"
        audio_write(tmp_path, audio_array, sample_rate)
        try:
            result = stt_model.generate(tmp_path, language=language, verbose=False)
            segments = (
                sanitize_for_json(result.segments)
                if hasattr(result, "segments") and result.segments
                else None
            )
            await websocket.send_json(
                {
                    "text": result.text,
                    "segments": segments,
                    "language": getattr(result, "language", language),
                    "is_partial": is_partial,
                }
            )
''',
    '''    if supports_stream and streaming:
        events = []
        with _MLX_INFERENCE_LOCK:
            result_iter = stt_model.generate(
                mx.array(audio_array), stream=True, language=language, verbose=False
            )
            accumulated = ""
            detected_language = language
            for chunk in result_iter:
                delta = (
                    chunk if isinstance(chunk, str) else getattr(chunk, "text", str(chunk))
                )
                accumulated += delta
                # Pick up detected language from streaming results
                chunk_lang = getattr(chunk, "language", None)
                if chunk_lang and detected_language is None:
                    detected_language = chunk_lang
                events.append({"type": "delta", "delta": delta})

            events.append(
                {
                    "type": "complete",
                    "text": accumulated,
                    "segments": None,
                    "language": detected_language,
                    "is_partial": is_partial,
                }
            )

        for event in events:
            await websocket.send_json(event)
    else:
        tmp_path = f"/tmp/realtime_{time.time()}.mp3"
        audio_write(tmp_path, audio_array, sample_rate)
        try:
            with _MLX_INFERENCE_LOCK:
                result = stt_model.generate(tmp_path, language=language, verbose=False)
                segments = (
                    sanitize_for_json(result.segments)
                    if hasattr(result, "segments") and result.segments
                    else None
                )
                message = {
                    "text": result.text,
                    "segments": segments,
                    "language": getattr(result, "language", language),
                    "is_partial": is_partial,
                }
            await websocket.send_json(message)
''',
    "_stream_transcription",
)

path.write_text(src)
print(f"Patched: {path}")
PY

echo "Done. Backup at $FILE.bak"
