#!/usr/bin/env bash
#
# One-time setup of the GPU transcription stack on the Windows PC.
#
#   ./scripts/install-whisper.sh
#
# Creates %USERPROFILE%\.notables-venv on the PC (deliberately OUTSIDE the vault) with
# faster-whisper + the CUDA runtime wheels, then verifies CUDA actually engages and
# pre-downloads large-v3 (~3 GB) so the first real lecture doesn't wait for it.
#
# The `python` on the PC's PATH is a broken uv shim - the real interpreter is used
# explicitly below. Override it with NOTABLES_PC_PYTHON.
#
# Paths default to the PC's own %USERPROFILE%. Set NOTABLES_PC_HOME in the
# gitignored notables.local (or the environment) to use a different directory.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO/notables.local" ] && . "$REPO/notables.local"
HOST="${NOTABLES_PC:-pc}"
PC_HOME="${NOTABLES_PC_HOME:-$(ssh "$HOST" 'echo %USERPROFILE%' | tr -d '\r')}"
case "$PC_HOME" in ''|*%*) echo "could not read %USERPROFILE% from $HOST; set NOTABLES_PC_HOME" >&2; exit 1 ;; esac
PY="${NOTABLES_PC_PYTHON:-$PC_HOME\AppData\Local\Programs\Python\Python312\python.exe}"
VENV="$PC_HOME\.notables-venv"
VENVPY="$VENV\Scripts\python.exe"
MODELS="$PC_HOME\.notables-models"

echo "==> GPU"
ssh "$HOST" 'C:\Windows\System32\nvidia-smi.exe --query-gpu=name,memory.total,driver_version --format=csv,noheader'

echo "==> creating the venv"
ssh "$HOST" "$PY -m venv $VENV & $VENVPY -m pip install --disable-pip-version-check -q --upgrade pip"

echo "==> installing faster-whisper + CUDA runtime wheels"
ssh "$HOST" "$VENVPY -m pip install --disable-pip-version-check \"faster-whisper>=1.1\" \"ctranslate2>=4.5\" nvidia-cublas-cu12 \"nvidia-cudnn-cu12>=9,<10\"" | tail -3

# pypdf is the ONLY third-party dependency of the Canvas material extractor. Office
# formats are zip+XML and need nothing; PDFs need this. Without it, PDFs report
# "extraction failed" in the UI rather than silently yielding no text.
echo "==> installing pypdf (Canvas PDF extraction)"
ssh "$HOST" "$VENVPY -m pip install --disable-pip-version-check -q pypdf" | tail -2
ssh "$HOST" "$VENVPY -c \"import pypdf; print('pypdf', pypdf.__version__)\""

# OCR fallback for scanned PDFs: pypdfium2 renders pages (a wheel bundling PDFium,
# no external binary), rapidocr-onnxruntime reads them on the CPU. Only ever used
# when a PDF has no text layer.
echo "==> installing pypdfium2 + rapidocr-onnxruntime (scanned-PDF OCR)"
ssh "$HOST" "$VENVPY -m pip install --disable-pip-version-check -q pypdfium2 rapidocr-onnxruntime" | tail -2
ssh "$HOST" "$VENVPY -c \"import pypdfium2, numpy, rapidocr_onnxruntime; print('ocr stack ok')\""

echo "==> verifying CUDA (a silent CPU fallback would turn 4 minutes into 40)"
ssh "$HOST" "$VENVPY -c \"import os,sys;base=os.path.join(sys.prefix,'Lib','site-packages','nvidia');[os.add_dll_directory(os.path.join(base,s,'bin')) for s in ('cublas','cudnn','cuda_nvrtc') if os.path.isdir(os.path.join(base,s,'bin'))];import ctranslate2;print('ctranslate2',ctranslate2.__version__);print('cuda devices',ctranslate2.get_cuda_device_count());print('float16' in ctranslate2.get_supported_compute_types('cuda') and 'float16 OK' or 'NO float16')\""

echo "==> pre-downloading whisper large-v3 into $MODELS (~3 GB, one time)"
ssh "$HOST" "$VENVPY -c \"import os,sys;base=os.path.join(sys.prefix,'Lib','site-packages','nvidia');[os.add_dll_directory(os.path.join(base,s,'bin')) for s in ('cublas','cudnn','cuda_nvrtc') if os.path.isdir(os.path.join(base,s,'bin'))];from faster_whisper import WhisperModel;m=WhisperModel('large-v3',device='cuda',compute_type='float16',download_root=r'$MODELS');print('large-v3 loaded on cuda/float16')\""

echo "==> done"
