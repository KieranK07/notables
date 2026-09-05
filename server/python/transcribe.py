#!/usr/bin/env python3
"""
faster-whisper worker for the Notables note server.

Node spawns this with a one-line JSON job on stdin and reads a one-line JSON
summary from stdout; the full transcript and the timestamped segments are written
to `out_json` so a megabyte of text never has to travel through a pipe.

Progress lines go to stderr as `PROGRESS <done_sec> <total_sec>` so the server can
push a percentage down the SSE channel while the GPU works.

Job (stdin):
  {"audio": "...m4a", "out_json": "...json",
   "model": "large-v3", "device": "cuda", "compute_type": "float16",
   "model_dir": "...", "initial_prompt": "...", "beam_size": 5,
   "vad_filter": true, "language": "en"}

Result (stdout):
  {"ok": true, "device": "cuda", "compute_type": "float16", "language": "en",
   "duration": 3312.4, "chars": 41233, "segments": 812,
   "modelLoadSec": 11.2, "transcribeSec": 184.7, "realtimeFactor": 17.9}
"""
import json
import os
import sys
import time


def load_cuda_dlls():
    """
    The CUDA runtime ships as pip wheels (nvidia-cublas-cu12 / nvidia-cudnn-cu12);
    their DLLs are not on PATH, and without them CTranslate2 cannot use the GPU.
    """
    base = os.path.join(sys.prefix, "Lib", "site-packages", "nvidia")
    added = []
    for sub in ("cublas", "cudnn", "cuda_nvrtc"):
        p = os.path.join(base, sub, "bin")
        if os.path.isdir(p):
            try:
                os.add_dll_directory(p)
            except (AttributeError, OSError):
                pass
            os.environ["PATH"] = p + os.pathsep + os.environ.get("PATH", "")
            added.append(p)
    return added


def fail(message, **extra):
    out = {"ok": False, "error": str(message)}
    out.update(extra)
    sys.stdout.write(json.dumps(out))
    sys.stdout.flush()
    sys.exit(1)


def main():
    raw = sys.stdin.read()
    try:
        job = json.loads(raw)
    except Exception as e:
        fail("could not parse job json: %s" % e)

    audio = job["audio"]
    out_json = job["out_json"]
    device = job.get("device", "cuda")
    compute_type = job.get("compute_type", "float16")
    model_name = job.get("model", "large-v3")
    model_dir = job.get("model_dir") or None
    beam_size = int(job.get("beam_size", 5))
    vad_filter = bool(job.get("vad_filter", True))
    language = job.get("language") or None
    initial_prompt = job.get("initial_prompt") or None

    if not os.path.isfile(audio):
        fail("audio file not found: %s" % audio)

    load_cuda_dlls()

    try:
        import ctranslate2
        from faster_whisper import WhisperModel
    except Exception as e:
        fail("faster-whisper import failed: %s" % e)

    cuda_count = ctranslate2.get_cuda_device_count()
    if device == "cuda" and cuda_count < 1:
        # Be loud. A silent CPU fallback turns 4 minutes into 40.
        fail("device=cuda requested but ctranslate2 sees no CUDA device", cudaDevices=cuda_count)

    t0 = time.time()
    try:
        model = WhisperModel(
            model_name, device=device, compute_type=compute_type, download_root=model_dir
        )
    except Exception as e:
        fail("could not load %s on %s/%s: %s" % (model_name, device, compute_type, e),
             cudaDevices=cuda_count)
    load_sec = time.time() - t0

    sys.stderr.write("MODEL_LOADED %.1f cuda_devices=%d\n" % (load_sec, cuda_count))
    sys.stderr.flush()

    t1 = time.time()
    try:
        segments, info = model.transcribe(
            audio,
            language=language,
            beam_size=beam_size,
            vad_filter=vad_filter,
            initial_prompt=initial_prompt,
            condition_on_previous_text=True,
            word_timestamps=False,
        )
    except Exception as e:
        fail("transcribe() failed: %s" % e)

    total = float(getattr(info, "duration", 0.0) or 0.0)
    sys.stderr.write("DURATION %.2f\n" % total)
    sys.stderr.flush()

    out_segments = []
    parts = []
    last_report = 0.0
    try:
        for seg in segments:            # generator: work happens here
            text = seg.text.strip()
            out_segments.append({
                "id": seg.id,
                "start": round(float(seg.start), 3),
                "end": round(float(seg.end), 3),
                "text": text,
            })
            parts.append(text)
            if seg.end - last_report >= 15.0:
                last_report = seg.end
                sys.stderr.write("PROGRESS %.1f %.1f\n" % (seg.end, total))
                sys.stderr.flush()
    except Exception as e:
        fail("decoding failed after %d segments: %s" % (len(out_segments), e))
    transcribe_sec = time.time() - t1

    # Whisper emits one sentence per segment; join with spaces and start a new
    # paragraph at a long pause so the transcript file is readable.
    text_parts = []
    prev_end = None
    for s in out_segments:
        if prev_end is not None and s["start"] - prev_end > 2.5:
            text_parts.append("\n\n")
        elif text_parts:
            text_parts.append(" ")
        text_parts.append(s["text"])
        prev_end = s["end"]
    full_text = "".join(text_parts).strip()

    result = {
        "ok": True,
        "audio": audio,
        "model": model_name,
        "device": device,
        "computeType": compute_type,
        "cudaDevices": cuda_count,
        "language": getattr(info, "language", language),
        "languageProbability": round(float(getattr(info, "language_probability", 0.0) or 0.0), 4),
        "duration": round(total, 2),
        "beamSize": beam_size,
        "vadFilter": vad_filter,
        "initialPrompt": initial_prompt,
        "modelLoadSec": round(load_sec, 2),
        "transcribeSec": round(transcribe_sec, 2),
        "realtimeFactor": round(total / transcribe_sec, 2) if transcribe_sec > 0 else None,
        "segments": out_segments,
        "text": full_text,
    }

    os.makedirs(os.path.dirname(out_json), exist_ok=True)
    tmp = out_json + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    os.replace(tmp, out_json)

    summary = {k: v for k, v in result.items() if k not in ("segments", "text", "initialPrompt")}
    summary["chars"] = len(full_text)
    summary["segmentCount"] = len(out_segments)
    summary["outJson"] = out_json
    sys.stdout.write(json.dumps(summary))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
