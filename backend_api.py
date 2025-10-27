# backend_api.py — AIdentify API (detector proxy + robust URL fetch)
# Requires: fastapi, uvicorn, requests, yt-dlp, pillow, numpy, opencv-python-headless, python-multipart

from fastapi import FastAPI, UploadFile, File, Form
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import tempfile, os, shutil, mimetypes, io
from typing import Dict, Any, Optional
import requests
from PIL import Image, ImageChops
import numpy as np
import cv2
import yt_dlp

# --- Config ---
DETECTOR_URL = "http://127.0.0.1:9000"   # your local detector
TIMEOUT = 60

app = FastAPI(title="AI Identifier API", version="1.1")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], allow_credentials=True,
    allow_methods=["*"], allow_headers=["*"],
)

# -------------------------
# Simple image/video signals
# -------------------------
def ela_score(img: Image.Image, q: int = 90) -> float:
    buf = io.BytesIO()
    img.convert("RGB").save(buf, "JPEG", quality=q)
    buf.seek(0)
    rec = Image.open(buf)
    diff = ImageChops.difference(img.convert("RGB"), rec)
    arr = np.asarray(diff, dtype=np.float32)
    return float(np.mean(np.abs(arr))) / 255.0 * 3.0

def sniff_media_type(path: str) -> str:
    mt, _ = mimetypes.guess_type(path)
    if mt and mt.startswith("image/"): return "image"
    if mt and mt.startswith("video/"): return "video"
    try:
        with Image.open(path): return "image"
    except: pass
    try:
        cap = cv2.VideoCapture(path)
        if cap.isOpened() and int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) > 0:
            cap.release(); return "video"
        cap.release()
    except: pass
    return "unknown"

# -------------------------
# Proxy to local detector
# -------------------------
def post_to_detector(endpoint: str, file_path: str) -> Dict[str, Any]:
    with open(file_path, "rb") as f:
        files = {"file": (os.path.basename(file_path), f, "application/octet-stream")}
        r = requests.post(f"{DETECTOR_URL}{endpoint}", files=files, timeout=TIMEOUT)
        r.raise_for_status()
        return r.json()

# -------------------------
# Robust URL fetching
# -------------------------
def try_direct_get(url: str, tmp_path: str) -> Optional[str]:
    """If the URL points to a direct media file, fetch it via HTTP GET."""
    try:
        r = requests.get(url, stream=True, timeout=TIMEOUT)
        ct = r.headers.get("Content-Type", "")
        if r.status_code == 200 and ("video" in ct or "image" in ct or url.lower().endswith((".mp4",".mov",".mkv",".jpg",".jpeg",".png",".webp",".bmp",".gif"))):
            with open(tmp_path, "wb") as out:
                for chunk in r.iter_content(chunk_size=1024*128):
                    if chunk: out.write(chunk)
            return tmp_path
    except Exception:
        pass
    return None

def ytdlp_download(url: str, out_dir: str) -> Optional[str]:
    """
    Download using yt-dlp with Chrome cookies and multiple client profiles.
    Returns downloaded file path or None.
    """
    outtmpl = os.path.join(out_dir, "%(id)s.%(ext)s")

    # Prefer MP4 <=720p (good enough for analysis) with safe fallbacks
    fmt = "bv*[ext=mp4][height<=720]+ba[ext=m4a]/b[ext=mp4][height<=720]/best[ext=mp4]/best"

    # Multiple YouTube player clients to dodge SABR gating
    extractor_args = {"youtube": {"player_client": ["web","ios","android","tv"]}}

    ydl_opts = {
        "outtmpl": outtmpl,
        "format": fmt,
        "merge_output_format": "mp4",
        "noplaylist": True,
        "quiet": True,
        "nocheckcertificate": True,
        "geo_bypass": True,
        "http_headers": {
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/118.0.0.0 Safari/537.36"
            )
        },
        # IMPORTANT: use Chrome cookies (open Chrome and be signed into YouTube)
        "cookiesfrombrowser": ("chrome",),
        "extractor_args": extractor_args,
    }

    last_err = None
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=True)  # may raise
            path = ydl.prepare_filename(info)
            # Normalize common alt extensions
            for candidate in (path, path.replace(".webm", ".mp4"), path.replace(".mkv",".mp4")):
                if os.path.exists(candidate):
                    return candidate
    except Exception as e:
        last_err = e

    # If we get here, try again with a simpler 'best' in case MP4 wasn’t offered
    try:
        ydl_opts2 = {**ydl_opts, "format": "best"}
        with yt_dlp.YoutubeDL(ydl_opts2) as ydl:
            info = ydl.extract_info(url, download=True)
            path = ydl.prepare_filename(info)
            for candidate in (path, path.replace(".webm", ".mp4"), path.replace(".mkv",".mp4")):
                if os.path.exists(candidate):
                    return candidate
    except Exception:
        pass

    # Nothing worked
    if last_err:
        raise last_err
    return None

# -------------------------
# API
# -------------------------
@app.get("/")
def root():
    return {"status": "AI Identifier API running", "proxy": "detector@9000", "version": "1.1"}

@app.post("/analyze/upload")
async def analyze_upload(file: UploadFile = File(...)):
    # Save incoming file
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        tmp.write(await file.read())
        p = tmp.name

    evidence = []
    try:
        media = sniff_media_type(p)
        if media == "image":
            evidence.append({"label":"Source","value":"Local detector"})
            res = post_to_detector("/analyze/image", p)
        elif media == "video":
            evidence.append({"label":"Source","value":"Local detector"})
            res = post_to_detector("/analyze/video", p)
        else:
            return JSONResponse({"verdict":"inconclusive","confidence":0.0,
                                 "evidence":[{"label":"File","value":"Unsupported"}]})
        # merge evidence
        if "evidence" in res:
            res["evidence"] = evidence + res["evidence"]
        else:
            res["evidence"] = evidence
        return JSONResponse(res)
    finally:
        try: os.remove(p)
        except: pass

@app.post("/analyze/url")
def analyze_url(url: str = Form(...)):
    """
    1) Try direct GET (works for direct .mp4 / image links and many CDNs)
    2) Try yt-dlp with Chrome cookies + multiple client profiles
    3) If still blocked (SABR / no formats), return clear evidence
    """
    res = {"verdict":"inconclusive","confidence":0.0,"evidence":[]}

    # temp workspace
    workdir = tempfile.mkdtemp(prefix="fetch_")
    tmp_path = os.path.join(workdir, "media.bin")

    try:
        # Path A: direct GET
        d = try_direct_get(url, tmp_path)
        if d and os.path.getsize(d) > 0:
            res["evidence"].append({"label":"Fetch","value":"Direct GET"})
            kind = sniff_media_type(d)
            if kind == "image":
                res["evidence"].append({"label":"Source","value":"Local detector"})
                res = post_to_detector("/analyze/image", d) | {"evidence": res["evidence"]}
                return JSONResponse(res)
            if kind == "video":
                res["evidence"].append({"label":"Source","value":"Local detector"})
                res = post_to_detector("/analyze/video", d) | {"evidence": res["evidence"]}
                return JSONResponse(res)

        # Path B: yt-dlp
        try:
            path = ytdlp_download(url, workdir)
            if path and os.path.exists(path) and os.path.getsize(path) > 0:
                res["evidence"].append({"label":"Fetch","value":"yt-dlp downloaded"})
                kind = sniff_media_type(path)
                if kind == "image":
                    res["evidence"].append({"label":"Source","value":"Local detector"})
                    r = post_to_detector("/analyze/image", path)
                    r["evidence"] = res["evidence"] + r.get("evidence", [])
                    return JSONResponse(r)
                if kind == "video":
                    res["evidence"].append({"label":"Source","value":"Local detector"})
                    r = post_to_detector("/analyze/video", path)
                    r["evidence"] = res["evidence"] + r.get("evidence", [])
                    return JSONResponse(r)
                res["evidence"].append({"label":"File","value":"Unsupported"})
            else:
                res["evidence"].append({"label":"Fetch","value":"No downloadable video stream"})
        except Exception as e:
            # Show trimmed yt-dlp error (without ANSI)
            msg = str(e).replace("\u001b[0;31m","").replace("\u001b[0m","")
            res["evidence"].append({"label":"Fetch","value":f"yt-dlp error: {msg}"})

        # If we got here, neither path produced a playable file
        if not any(ev["label"].startswith("Video") or ev["label"]=="ELA" for ev in res["evidence"]):
            res["evidence"].append({"label":"File","value":"Unsupported"})
        return JSONResponse(res)

    finally:
        # cleanup
        try:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)
            shutil.rmtree(workdir, ignore_errors=True)
        except:
            pass
