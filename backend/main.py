import asyncio
import httpx
import time
import os
import secrets
from collections import defaultdict, deque
from fastapi import FastAPI, Depends, HTTPException, Request, Security
from fastapi.responses import FileResponse
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security.api_key import APIKeyHeader
from contextlib import asynccontextmanager
from telegram_client import start_telegram_client, latest_messages, generate_morning_digest, night_summary
from dotenv import load_dotenv

load_dotenv()

API_KEY = os.getenv("API_SECRET_KEY", "default_secret_key_change_me")
API_KEY_NAME = "X-API-Key"
api_key_header = APIKeyHeader(name=API_KEY_NAME, auto_error=True)

# Розумний Rate Limiter (Sliding Window: до 15 запитів за 3 секунди з одного IP)
RATE_WINDOW = 3.0
MAX_REQUESTS_PER_WINDOW = 15
ip_requests: dict[str, deque] = defaultdict(deque)

# Кеш для API тривог (щоб не блокував ubilling та відповідь віддавалась за 1 мс)
alerts_cache = {"data": None, "timestamp": 0.0}
ALERTS_CACHE_TTL = 10.0
http_client: httpx.AsyncClient | None = None

def get_client_ip(request: Request) -> str:
    forwarded = request.headers.get("X-Forwarded-For")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"

def check_rate_limit(request: Request):
    client_ip = get_client_ip(request)
    now = time.monotonic()
    
    if len(ip_requests) > 5000:
        ip_requests.clear()
        
    q = ip_requests[client_ip]
    while q and now - q[0] > RATE_WINDOW:
        q.popleft()
        
    if len(q) >= MAX_REQUESTS_PER_WINDOW:
        raise HTTPException(status_code=429, detail="Too Many Requests. Rate limit exceeded.")
    q.append(now)

async def verify_api_key(api_key: str = Security(api_key_header), _ = Depends(check_rate_limit)):
    if not secrets.compare_digest(api_key, API_KEY):
        raise HTTPException(status_code=403, detail="Forbidden. Invalid API Key.")
    return api_key

async def resilient_telegram_loop():
    """Автоматичний перезапуск клієнта при збоях мережі"""
    while True:
        try:
            await start_telegram_client()
        except asyncio.CancelledError:
            break
        except Exception as e:
            print(f"⚠️ Помилка Telegram-клієнта: {e}. Перезапуск через 10 с...")
            await asyncio.sleep(10)

@asynccontextmanager
async def lifespan(app: FastAPI):
    global http_client
    http_client = httpx.AsyncClient(timeout=10.0)
    task = asyncio.create_task(resilient_telegram_loop())
    yield
    task.cancel()
    await http_client.aclose()

app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "OPTIONS"],
    allow_headers=["*"],
)

@app.get("/")
def read_root():
    return {"status": "secure", "app": "Kyiv Alert Backend"}

@app.get("/api/messages", dependencies=[Depends(verify_api_key)])
def get_messages():
    return {"messages": latest_messages}

@app.get("/api/alerts", dependencies=[Depends(verify_api_key)])
async def get_alerts():
    now = time.monotonic()
    if alerts_cache["data"] is not None and (now - alerts_cache["timestamp"]) < ALERTS_CACHE_TTL:
        return alerts_cache["data"]

    url = "https://ubilling.net.ua/aerialalerts/"
    try:
        assert http_client is not None
        response = await http_client.get(url)
        response.raise_for_status()
        data = response.json()
        alerts_cache["data"] = data
        alerts_cache["timestamp"] = now
        return data
    except Exception as e:
        if alerts_cache["data"] is not None:
            return alerts_cache["data"]  # Віддаємо останній кеш, якщо зовнішній API ліг
        return {"error": str(e)}

@app.get("/api/config", dependencies=[Depends(check_rate_limit)])
def get_remote_config():
    config_path = os.path.join(os.path.dirname(__file__), "remote_config.json")
    if os.path.exists(config_path):
        try:
            with open(config_path, "r", encoding="utf-8") as f:
                import json
                return json.load(f)
        except Exception as e:
            return {"error": f"Failed to read config: {e}"}
    return {
        "version_code": 39,
        "version_name": "1.2.36",
        "apk_url": "",
        "changelog": "Стабільна версія Kyiv Alert Monitor",
        "extra_locations": {},
        "extra_channels": [],
        "extra_danger_keywords": [],
        "extra_clear_keywords": []
    }

@app.get("/api/download-apk")
def download_apk():
    root_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    apk_path = os.path.join(root_dir, "KyivAlert_Phone.apk")
    if os.path.exists(apk_path):
        return FileResponse(apk_path, media_type="application/vnd.android.package-archive", filename="KyivAlert.apk")
    flutter_apk = os.path.join(root_dir, "frontend", "build", "app", "outputs", "flutter-apk", "app-release.apk")
    if os.path.exists(flutter_apk):
        return FileResponse(flutter_apk, media_type="application/vnd.android.package-archive", filename="KyivAlert.apk")
    raise HTTPException(status_code=404, detail="APK file not found on server")

# Кеш для ранкового дайджесту (15 хвилин = 900 с)
digest_cache = {"data": None, "timestamp": 0.0}
DIGEST_CACHE_TTL = 900.0

@app.get("/api/digest", dependencies=[Depends(check_rate_limit)])
async def get_digest():
    now = time.monotonic()
    if digest_cache["data"] is not None and (now - digest_cache["timestamp"]) < DIGEST_CACHE_TTL:
        return digest_cache["data"]

    try:
        data = await generate_morning_digest()
        digest_cache["data"] = data
        digest_cache["timestamp"] = now
        return data
    except Exception as e:
        if digest_cache["data"] is not None:
            return digest_cache["data"]
        return {"error": f"Failed to generate morning digest: {e}"}


