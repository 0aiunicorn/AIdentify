from fastapi import FastAPI, File, UploadFile, Form
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
def home():
    return {"status": "AI Identifier API running"}

@app.post("/analyze/upload")
async def analyze_upload(file: UploadFile = File(...)):
    return {
        "verdict": "likelyAI",
        "confidence": 0.82,
        "evidence": [
            {"label": "Metadata", "value": "No camera EXIF found"},
            {"label": "C2PA Credentials", "value": "Not present"}
        ]
    }

@app.post("/analyze/url")
async def analyze_url(url: str = Form(...)):
    return {
        "verdict": "likelyReal",
        "confidence": 0.94,
        "evidence": [
            {"label": "Source", "value": "Trusted CDN"},
            {"label": "Metadata", "value": "Contains camera EXIF data"}
        ]
    }
