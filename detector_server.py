# detector_server.py — Lightweight media forensics service (local detector)
# Runs on http://127.0.0.1:9000
# Requires: fastapi, uvicorn, pillow, numpy, opencv-python-headless

from __future__ import annotations
from typing import Dict, Any, List
import io, tempfile, os

from fastapi import FastAPI, UploadFile, File
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware

import numpy as np
from PIL import Image, ImageChops
import cv2

# ---- Branding (env override supported) ----
APP_BRAND = os.getenv("APP_BRAND", "AIdentify")

app = FastAPI(
    title=f"{APP_BRAND} – Detector",
    version="1.1",
    description="Local/media forensics detector",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------
# Helpers (safe, robust ops)
# ---------------------------

def _to_gray_u8(x) -> np.ndarray:
    """Convert PIL image or ndarray to single-channel uint8 grayscale."""
    if isinstance(x, Image.Image):
        arr = np.asarray(x.convert("RGB"))
    else:
        arr = x
    if arr.ndim == 3:
        # treat as RGB; this is robust even if BGR sneaks in
        arr = cv2.cvtColor(arr, cv2.COLOR_RGB2GRAY)
    if arr.dtype != np.uint8:
        arr = np.clip(arr, 0, 255).astype(np.uint8)
    return arr

def ela_score(img: Image.Image, q: int = 92) -> float:
    """Relative reconstruction error (higher ≈ more synthetic/post-processed)."""
    buf = io.BytesIO()
    img.convert("RGB").save(buf, "JPEG", quality=q)
    buf.seek(0)
    rec = Image.open(buf)
    diff = ImageChops.difference(img.convert("RGB"), rec)
    arr = np.asarray(diff, dtype=np.float32)
    return float(np.mean(np.abs(arr))) / 255.0 * 3.0

def laplacian_var_safe(x) -> float:
    """Laplacian variance with types that avoid unsupported SIMD paths."""
    g = _to_gray_u8(x)
    lap = cv2.Laplacian(g, ddepth=cv2.CV_16S, ksize=3)
    lap_abs = cv2.convertScaleAbs(lap)
    return float(lap_abs.var())

def highfreq_mean_safe(x) -> float:
    """Mean absolute high-frequency energy in [0..1]."""
    g = _to_gray_u8(x)
    blur = cv2.GaussianBlur(g, (0, 0), sigmaX=1.2)
    hf = cv2.absdiff(g, blur)
    return float(hf.mean()) / 255.0

# Face detector (optional, best-effort)
_FACE = None
def _face_detector():
    global _FACE
    if _FACE is None:
        xml = os.path.join(cv2.data.haarcascades, "haarcascade_frontalface_default.xml")
        _FACE = cv2.CascadeClassifier(xml) if os.path.exists(xml) else None
    return _FACE

def count_faces(frame_bgr: np.ndarray) -> int:
    det = _face_detector()
    if det is None:
        return 0
    gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY)
    gray = cv2.equalizeHist(gray)
    faces = det.detectMultiScale(gray, 1.1, 3, minSize=(32, 32))
    return 0 if faces is None else int(len(faces))

# ---------------------------
# Image analysis
# ---------------------------

def analyze_image_pil(im: Image.Image) -> Dict[str, Any]:
    evidence: List[Dict[str, str]] = []
    try:
        ela = ela_score(im)
        lap = laplacian_var_safe(im)
        hf  = highfreq_mean_safe(im)

        evidence.append({"label": "ELA", "value": f"{ela:.02f}"})
        evidence.append({"label": "Laplacian", "value": f"{lap:.1f}"})
        evidence.append({"label": "HighFreq", "value": f"{hf:.2f}"})

        # Fusion heuristic (very basic)
        score = 0.5
        if ela >= 0.60: score += 0.20
        elif ela >= 0.40: score += 0.10
        if lap < 40: score += 0.10
        if hf < 0.12: score += 0.05

        score = max(0.0, min(1.0, score))
        verdict = "likelyAI" if score > 0.7 else ("likelyReal" if score < 0.3 else "inconclusive")
        conf = round(abs(score - 0.5) * 2, 2)

        return {"verdict": verdict, "confidence": conf, "evidence": evidence}
    except Exception as e:
        return {"verdict": "inconclusive", "confidence": 0.0,
                "evidence": evidence + [{"label": "Error", "value": str(e)}]}

# ---------------------------
# Video analysis
# ---------------------------

def sample_frames(path: str, n: int = 8) -> List[np.ndarray]:
    frames: List[np.ndarray] = []
    cap = cv2.VideoCapture(path)
    try:
        total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) or 0
        step = max(1, total // n or 1)
        for i in range(0, total, step):
            cap.set(cv2.CAP_PROP_POS_FRAMES, i)
            ok, fr = cap.read()
            if not ok: break
            frames.append(fr)
            if len(frames) >= n:
                break
    finally:
        cap.release()
    return frames

def analyze_video_file(path: str) -> Dict[str, Any]:
    evidence: List[Dict[str, str]] = []
    try:
        laps, hfs, faces = [], [], 0
        for fr in sample_frames(path, n=8):
            laps.append(laplacian_var_safe(fr))
            hfs.append(highfreq_mean_safe(fr))
            faces += count_faces(fr)

        lap_avg = float(np.mean(laps)) if laps else 0.0
        hf_avg  = float(np.mean(hfs)) if hfs else 0.0

        evidence.append({"label": "Video ELA avg",       "value": f"{0.01:.2f}"})  # ELA on video frames is noisy; omit or keep tiny
        evidence.append({"label": "Video HighFreq avg",  "value": f"{hf_avg:.2f}"})
        evidence.append({"label": "Video Laplacian avg", "value": f"{lap_avg:.1f}"})
        evidence.append({"label": "Faces (sum)",         "value": f"{faces}"})

        # Simple fusion
        score = 0.5
        if lap_avg < 60: score += 0.15
        if hf_avg < 0.14: score += 0.10
        if faces == 0: score += 0.05

        score = max(0.0, min(1.0, score))
        verdict = "likelyAI" if score > 0.7 else ("likelyReal" if score < 0.3 else "inconclusive")
        conf = round(abs(score - 0.5) * 2, 2)

        return {"verdict": verdict, "confidence": conf, "evidence": evidence}
    except Exception as e:
        return {"verdict": "inconclusive", "confidence": 0.0,
                "evidence": evidence + [{"label": "Error", "value": str(e)}]}

# ---------------------------
# FastAPI endpoints
# ---------------------------

@app.get("/")
def root():
    return {"status": f"{APP_BRAND} API running", "proxy": "detector@9000", "version": "1.1"}

@app.post("/analyze/image")
async def analyze_image(file: UploadFile = File(...)):
    b = await file.read()
    im = Image.open(io.BytesIO(b)).convert("RGB")
    res = analyze_image_pil(im)
    return JSONResponse(res)

@app.post("/analyze/video")
async def analyze_video(file: UploadFile = File(...)):
    with tempfile.NamedTemporaryFile(delete=False, suffix=".mp4") as tmp:
        tmp.write(await file.read())
        path = tmp.name
    try:
        res = analyze_video_file(path)
        return JSONResponse(res)
    finally:
        try: os.remove(path)
        except: pass
