import multiprocessing
import subprocess
import time
import os

def start_detector():
    """Start the detector_server on port 9000"""
    subprocess.run([
        "python", "-m", "uvicorn", "detector_server:app",
        "--host", "0.0.0.0", "--port", "9000"
    ])

def start_backend():
    """Start the FastAPI backend_api on port 8000"""
    subprocess.run([
        "python", "-m", "uvicorn", "backend_api:app",
        "--host", "0.0.0.0", "--port", os.environ.get("PORT", "8000")
    ])

if __name__ == "__main__":
    # Start both in parallel for Render or local dev
    proc1 = multiprocessing.Process(target=start_detector)
    proc1.start()

    # Give the detector a few seconds to start up before the backend calls it
    time.sleep(5)

    start_backend()
