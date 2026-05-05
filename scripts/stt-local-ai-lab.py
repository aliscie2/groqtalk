#!/usr/bin/env python3
"""Local STT lab for GroqTalk voice fixtures.

This is intentionally local-only:
  - talks to a local whisper-server
  - reads fixture WAVs from tests/fixtures/stt
  - writes reports/videos under artifacts/stt-lab

It lets us reproduce a bad dictation, compare baseline recognition against
context-guided recognition, and render a quick visual MP4 for review.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = REPO_ROOT / "tests/fixtures/stt/manifest.json"
ARTIFACT_ROOT = REPO_ROOT / "artifacts/stt-lab"
WHISPER_SERVER = Path("/opt/homebrew/bin/whisper-server")
DEFAULT_MODEL = Path.home() / ".config/groqtalk/models/ggml-large-v3-turbo-q5_0.bin"
DEFAULT_PORT = 8725

BUILT_IN_TERMS = [
    "mesh LLM",
    "LLM",
    "Petra Cursor",
    "Cursor",
    "Tauri app",
    "GroqTalk",
    "Qwen",
    "AI",
    "PDF",
    "VPN",
    "KYC",
    "DHL",
    "Shopify",
    "Hyderabad",
    "Coimbatore",
]


def run(args: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess:
    proc = subprocess.run(
        args,
        cwd=REPO_ROOT,
        text=True,
        check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and proc.returncode != 0:
        details = ""
        if capture:
            details = f"\nstdout:\n{proc.stdout or ''}\nstderr:\n{proc.stderr or ''}"
        raise RuntimeError(f"Command failed ({proc.returncode}): {' '.join(args)}{details}")
    return proc


def port_is_listening(port: int) -> bool:
    return run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"], check=False, capture=True).returncode == 0


def wait_for_port(port: int, timeout: float = 20.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if port_is_listening(port):
            return True
        time.sleep(0.5)
    return False


def start_whisper_server(port: int, model: Path) -> subprocess.Popen | None:
    if port_is_listening(port):
        return None
    if not WHISPER_SERVER.exists():
        raise RuntimeError(f"Missing whisper-server at {WHISPER_SERVER}")
    if not model.exists():
        raise RuntimeError(f"Missing Whisper model at {model}")

    ARTIFACT_ROOT.mkdir(parents=True, exist_ok=True)
    log_path = ARTIFACT_ROOT / "whisper-large.log"
    log = open(log_path, "a", encoding="utf-8")
    proc = subprocess.Popen(
        [
            str(WHISPER_SERVER),
            "--model",
            str(model),
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--language",
            "en",
            "--flash-attn",
            "-bs",
            "1",
        ],
        cwd=REPO_ROOT,
        stdout=log,
        stderr=log,
        text=True,
    )
    if not wait_for_port(port):
        proc.terminate()
        raise RuntimeError(f"whisper-server did not open port {port}; see {log_path}")
    return proc


def load_manifest() -> dict:
    with open(MANIFEST_PATH, "r", encoding="utf-8") as file:
        return json.load(file)


def fixture_by_name(name: str) -> dict:
    manifest = load_manifest()
    for fixture in manifest.get("fixtures", []):
        if fixture.get("name") == name:
            return fixture
    names = ", ".join(f.get("name", "?") for f in manifest.get("fixtures", []))
    raise RuntimeError(f"Unknown fixture `{name}`. Available fixtures: {names}")


def list_fixtures() -> None:
    manifest = load_manifest()
    for fixture in manifest.get("fixtures", []):
        print(f"{fixture['name']}: {fixture['wavPath']}")


def unique_terms(terms: list[str]) -> list[str]:
    seen: set[str] = set()
    output: list[str] = []
    for term in terms:
        trimmed = term.strip()
        if not trimmed:
            continue
        key = trimmed.lower()
        if key in seen:
            continue
        seen.add(key)
        output.append(trimmed)
    return output


def context_prompt(fixture: dict) -> str:
    required = fixture.get("requiredPhrases") or []
    expected_terms = re.findall(r"\b[A-Z][A-Za-z0-9]*(?:\s+[A-Z][A-Za-z0-9]*)*\b", fixture.get("expectedText", ""))
    terms = unique_terms(BUILT_IN_TERMS + required + expected_terms)
    return (
        "The speaker discusses software development. Correct terms include "
        + ", ".join(terms)
        + ". Preserve acronyms and app names."
    )


def multipart_form(fields: dict[str, str], file_field: str, file_path: Path) -> tuple[bytes, str]:
    boundary = "----GroqTalkSTTLab" + uuid.uuid4().hex
    chunks: list[bytes] = []

    def add(text: str) -> None:
        chunks.append(text.encode("utf-8"))

    add(f"--{boundary}\r\n")
    add(f'Content-Disposition: form-data; name="{file_field}"; filename="{file_path.name}"\r\n')
    add("Content-Type: audio/wav\r\n\r\n")
    chunks.append(file_path.read_bytes())
    add("\r\n")

    for key, value in fields.items():
        add(f"--{boundary}\r\n")
        add(f'Content-Disposition: form-data; name="{key}"\r\n\r\n')
        add(f"{value}\r\n")

    add(f"--{boundary}--\r\n")
    return b"".join(chunks), boundary


def transcribe(wav_path: Path, port: int, prompt: str | None = None) -> str:
    fields = {
        "language": "en",
        "response_format": "json",
        "temperature": "0.0",
    }
    if prompt:
        fields["prompt"] = prompt

    body, boundary = multipart_form(fields, "file", wav_path)
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/inference",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            payload = response.read().decode("utf-8", errors="replace")
    except urllib.error.URLError as error:
        raise RuntimeError(f"transcription request failed: {error}") from error

    try:
        decoded = json.loads(payload)
        return (decoded.get("text") or payload).strip()
    except json.JSONDecodeError:
        return payload.strip()


def normalize(text: str) -> str:
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"(?i)\bta\s+uri\b", "Tauri", text)
    return text.strip()


def comparable(text: str) -> str:
    text = normalize(text).lower()
    text = re.sub(r"[^a-z0-9']+", " ", text)
    return re.sub(r"\s+", " ", text).strip()


def levenshtein(left: str, right: str) -> int:
    if not left:
        return len(right)
    if not right:
        return len(left)
    previous = list(range(len(right) + 1))
    for i, lc in enumerate(left, 1):
        current = [i] + [0] * len(right)
        for j, rc in enumerate(right, 1):
            current[j] = min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + (0 if lc == rc else 1),
            )
        previous = current
    return previous[-1]


def edit_ratio(actual: str, expected: str) -> float:
    expected_cmp = comparable(expected)
    actual_cmp = comparable(actual)
    return levenshtein(actual_cmp, expected_cmp) / max(len(expected_cmp), 1)


def ffprobe_duration(wav_path: Path) -> float:
    proc = run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            str(wav_path),
        ],
        capture=True,
    )
    return max(float(proc.stdout.strip()), 0.5)


def render_panel(out_dir: Path, fixture: dict, baseline: str, guided: str, expected: str) -> Path:
    png_path = out_dir / f"{fixture['name']}.png"
    run(
        [
            "swift",
            "scripts/render-stt-panel.swift",
            str(png_path),
            fixture["name"],
            expected,
            baseline,
            guided,
        ],
        capture=True,
    )
    return png_path


def render_video(out_dir: Path, fixture: dict, baseline: str, guided: str, expected: str) -> Path:
    wav_path = REPO_ROOT / fixture["wavPath"]
    duration = ffprobe_duration(wav_path)
    video_path = out_dir / f"{fixture['name']}.mp4"
    panel_path = render_panel(out_dir, fixture, baseline, guided, expected)

    filter_complex = (
        "[1:a]showwaves=s=1088x88:mode=line:colors=0x5EE8B6@0.95,format=rgba[w];"
        "[0:v][w]overlay=x=96:y=322[v]"
    )
    run(
        [
            "ffmpeg",
            "-y",
            "-loop",
            "1",
            "-framerate",
            "30",
            "-t",
            f"{duration:.3f}",
            "-i",
            str(panel_path),
            "-i",
            str(wav_path),
            "-filter_complex",
            filter_complex,
            "-map",
            "[v]",
            "-map",
            "1:a",
            "-c:v",
            "libx264",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-shortest",
            str(video_path),
        ],
        capture=True,
    )
    return video_path


def write_report(out_dir: Path, fixture: dict, baseline: str, guided: str, expected: str, prompt: str, video: Path | None) -> Path:
    baseline_ratio = edit_ratio(baseline, expected)
    guided_ratio = edit_ratio(guided, expected)
    report = {
        "fixture": fixture["name"],
        "wavPath": fixture["wavPath"],
        "expectedText": expected,
        "baselineText": baseline,
        "guidedText": guided,
        "baselineEditRatio": baseline_ratio,
        "guidedEditRatio": guided_ratio,
        "requiredPhrases": fixture.get("requiredPhrases") or [],
        "prompt": prompt,
        "videoPath": str(video) if video else None,
    }
    json_path = out_dir / f"{fixture['name']}.json"
    json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    md_path = out_dir / f"{fixture['name']}.md"
    md_path.write_text(
        "\n".join(
            [
                f"# STT Lab: {fixture['name']}",
                "",
                f"- WAV: `{fixture['wavPath']}`",
                f"- Baseline edit ratio: `{baseline_ratio:.3f}`",
                f"- Local AI edit ratio: `{guided_ratio:.3f}`",
                f"- Video: `{video}`" if video else "- Video: not rendered",
                "",
                "## Baseline",
                "",
                baseline,
                "",
                "## Local AI",
                "",
                guided,
                "",
                "## Expected",
                "",
                expected,
                "",
                "## Prompt",
                "",
                prompt,
                "",
            ]
        ),
        encoding="utf-8",
    )
    return md_path


def run_fixture(fixture: dict, *, port: int, make_video: bool) -> None:
    wav_path = REPO_ROOT / fixture["wavPath"]
    if not wav_path.exists():
        raise RuntimeError(f"Fixture WAV missing: {wav_path}")

    prompt = context_prompt(fixture)
    expected = fixture["expectedText"]
    out_dir = ARTIFACT_ROOT / fixture["name"]
    out_dir.mkdir(parents=True, exist_ok=True)

    baseline = normalize(transcribe(wav_path, port))
    guided = normalize(transcribe(wav_path, port, prompt=prompt))
    video = render_video(out_dir, fixture, baseline, guided, expected) if make_video else None
    report = write_report(out_dir, fixture, baseline, guided, expected, prompt, video)

    print(f"Fixture: {fixture['name']}")
    print(f"Baseline: {baseline}")
    print(f"Local AI: {guided}")
    print(f"Expected: {expected}")
    print(f"Report: {report}")
    if video:
        print(f"Video: {video}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run local STT fixture research and render review videos.")
    parser.add_argument("--fixture", default="mesh_llm_tauri_app", help="Fixture name from tests/fixtures/stt/manifest.json")
    parser.add_argument("--all", action="store_true", help="Run every fixture in the manifest")
    parser.add_argument("--list", action="store_true", help="List fixture names")
    parser.add_argument("--video", action="store_true", help="Render an MP4 review video")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Whisper Large server port")
    parser.add_argument("--model", default=str(DEFAULT_MODEL), help="Whisper Large ggml model path")
    args = parser.parse_args()

    if args.list:
        list_fixtures()
        return 0

    server = None
    try:
        server = start_whisper_server(args.port, Path(args.model))
        manifest = load_manifest()
        fixtures = manifest.get("fixtures", []) if args.all else [fixture_by_name(args.fixture)]
        for fixture in fixtures:
            run_fixture(fixture, port=args.port, make_video=args.video)
        return 0
    finally:
        if server is not None:
            server.send_signal(signal.SIGTERM)
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                server.kill()


if __name__ == "__main__":
    raise SystemExit(main())
