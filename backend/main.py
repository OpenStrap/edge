"""WHOOP Connect Backend — production FastAPI service."""
import asyncio
import json
import math
import statistics
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone, timedelta
from typing import Optional

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from database import init_db, get_db_conn


# ── Lifespan ──────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


app = FastAPI(title="WHOOP Connect API", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── WebSocket hub ─────────────────────────────────────────────────────────────

class ConnectionHub:
    def __init__(self):
        self._clients: set[WebSocket] = set()

    async def connect(self, ws: WebSocket):
        await ws.accept()
        self._clients.add(ws)

    def disconnect(self, ws: WebSocket):
        self._clients.discard(ws)

    async def broadcast(self, data: dict):
        dead = set()
        for ws in self._clients:
            try:
                await ws.send_json(data)
            except Exception:
                dead.add(ws)
        self._clients -= dead


hub = ConnectionHub()


# ── Pydantic schemas ──────────────────────────────────────────────────────────

class HRSample(BaseModel):
    hr: int = Field(..., ge=20, le=250)
    ts: Optional[int] = None          # Unix epoch seconds; defaults to now

class HRVSample(BaseModel):
    hrv_rmssd: float = Field(..., ge=0)
    ts: Optional[int] = None

class SpO2Sample(BaseModel):
    spo2: float = Field(..., ge=70, le=100)
    ts: Optional[int] = None

class TempSample(BaseModel):
    temp_c: float
    ts: Optional[int] = None

class IMUSample(BaseModel):
    accel_mag: Optional[float] = None
    accel_x: Optional[float] = None
    accel_y: Optional[float] = None
    accel_z: Optional[float] = None
    gyro_x: Optional[float] = None
    gyro_y: Optional[float] = None
    gyro_z: Optional[float] = None
    ts: Optional[int] = None

class BatterySample(BaseModel):
    battery_pct: float = Field(..., ge=0, le=100)
    charging: bool = False
    ts: Optional[int] = None

class BulkPayload(BaseModel):
    """Single-call bulk ingest from Flutter app."""
    hr: Optional[int] = None
    hrv: Optional[float] = None
    spo2: Optional[float] = None
    temp_c: Optional[float] = None
    battery_pct: Optional[float] = None
    charging: Optional[bool] = None
    accel_mag: Optional[float] = None
    wrist_on: Optional[bool] = None
    ts: Optional[int] = None          # defaults to server time


# ── Helpers ───────────────────────────────────────────────────────────────────

def _now() -> int:
    return int(time.time())

def _ts(ts: Optional[int]) -> int:
    return ts if ts is not None else _now()

def _window_start(hours: int) -> int:
    return _now() - hours * 3600


# ── Health check ─────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "time": datetime.now(timezone.utc).isoformat()}


# ── Ingest endpoints ──────────────────────────────────────────────────────────

@app.post("/api/ingest", status_code=204)
async def ingest_bulk(payload: BulkPayload):
    """Primary ingest endpoint — Flutter calls this every second."""
    ts = _ts(payload.ts)
    async with get_db_conn() as conn:
        if payload.hr is not None:
            await conn.execute(
                "INSERT INTO hr (ts, value) VALUES (?, ?)", (ts, payload.hr))
        if payload.hrv is not None:
            await conn.execute(
                "INSERT INTO hrv (ts, value) VALUES (?, ?)", (ts, payload.hrv))
        if payload.spo2 is not None:
            await conn.execute(
                "INSERT INTO spo2 (ts, value) VALUES (?, ?)", (ts, payload.spo2))
        if payload.temp_c is not None:
            await conn.execute(
                "INSERT INTO temperature (ts, value) VALUES (?, ?)", (ts, payload.temp_c))
        if payload.battery_pct is not None:
            await conn.execute(
                "INSERT INTO battery (ts, value, charging) VALUES (?, ?, ?)",
                (ts, payload.battery_pct, 1 if payload.charging else 0))
        if payload.accel_mag is not None:
            await conn.execute(
                "INSERT INTO imu (ts, accel_mag) VALUES (?, ?)", (ts, payload.accel_mag))
        await conn.commit()

    # Broadcast to WebSocket clients
    await hub.broadcast({
        "type": "live",
        "ts": ts,
        "hr": payload.hr,
        "hrv": payload.hrv,
        "spo2": payload.spo2,
        "temp_c": payload.temp_c,
        "battery_pct": payload.battery_pct,
        "charging": payload.charging,
        "accel_mag": payload.accel_mag,
        "wrist_on": payload.wrist_on,
    })


@app.post("/api/metrics/hr", status_code=204)
async def post_hr(s: HRSample):
    ts = _ts(s.ts)
    async with get_db_conn() as conn:
        await conn.execute("INSERT INTO hr (ts, value) VALUES (?, ?)", (ts, s.hr))
        await conn.commit()
    await hub.broadcast({"type": "hr", "ts": ts, "value": s.hr})


@app.post("/api/metrics/hrv", status_code=204)
async def post_hrv(s: HRVSample):
    ts = _ts(s.ts)
    async with get_db_conn() as conn:
        await conn.execute("INSERT INTO hrv (ts, value) VALUES (?, ?)", (ts, s.hrv_rmssd))
        await conn.commit()


@app.post("/api/metrics/spo2", status_code=204)
async def post_spo2(s: SpO2Sample):
    ts = _ts(s.ts)
    async with get_db_conn() as conn:
        await conn.execute("INSERT INTO spo2 (ts, value) VALUES (?, ?)", (ts, s.spo2))
        await conn.commit()


# ── Query endpoints ───────────────────────────────────────────────────────────

@app.get("/api/metrics/hr")
async def get_hr(hours: int = Query(24, ge=1, le=168)):
    since = _window_start(hours)
    async with get_db_conn() as conn:
        rows = await conn.execute_fetchall(
            "SELECT ts, value FROM hr WHERE ts >= ? ORDER BY ts ASC", (since,))
    return {"data": [{"ts": r[0], "hr": r[1]} for r in rows]}


@app.get("/api/metrics/hrv")
async def get_hrv(hours: int = Query(24, ge=1, le=168)):
    since = _window_start(hours)
    async with get_db_conn() as conn:
        rows = await conn.execute_fetchall(
            "SELECT ts, value FROM hrv WHERE ts >= ? ORDER BY ts ASC", (since,))
    return {"data": [{"ts": r[0], "hrv": r[1]} for r in rows]}


@app.get("/api/metrics/spo2")
async def get_spo2(hours: int = Query(24, ge=1, le=168)):
    since = _window_start(hours)
    async with get_db_conn() as conn:
        rows = await conn.execute_fetchall(
            "SELECT ts, value FROM spo2 WHERE ts >= ? ORDER BY ts ASC", (since,))
    return {"data": [{"ts": r[0], "spo2": r[1]} for r in rows]}


# ── Insights ──────────────────────────────────────────────────────────────────

@app.get("/api/insights/today")
async def insights_today():
    since = _window_start(24)
    async with get_db_conn() as conn:
        hr_rows = await conn.execute_fetchall(
            "SELECT value FROM hr WHERE ts >= ?", (since,))
        hrv_rows = await conn.execute_fetchall(
            "SELECT value FROM hrv WHERE ts >= ?", (since,))
        spo2_rows = await conn.execute_fetchall(
            "SELECT value FROM spo2 WHERE ts >= ?", (since,))
        temp_rows = await conn.execute_fetchall(
            "SELECT value FROM temperature WHERE ts >= ?", (since,))
        batt_rows = await conn.execute_fetchall(
            "SELECT value FROM battery WHERE ts >= ? ORDER BY ts DESC LIMIT 1", (since,))

    hr_vals = [r[0] for r in hr_rows]
    hrv_vals = [r[0] for r in hrv_rows]
    spo2_vals = [r[0] for r in spo2_rows]
    temp_vals = [r[0] for r in temp_rows]

    def safe_avg(vals): return round(sum(vals) / len(vals), 1) if vals else None
    def safe_min(vals): return min(vals) if vals else None
    def safe_max(vals): return max(vals) if vals else None

    # Recovery score: weighted HRV + resting HR
    recovery = _compute_recovery(hr_vals, hrv_vals)
    strain = _compute_strain(hr_vals)
    hrv_trend = _hrv_trend(hrv_vals)

    return {
        "summary": {
            "hr_avg": safe_avg(hr_vals),
            "hr_min": safe_min(hr_vals),
            "hr_max": safe_max(hr_vals),
            "hrv_avg": safe_avg(hrv_vals),
            "hrv_latest": hrv_vals[-1] if hrv_vals else None,
            "spo2_avg": safe_avg(spo2_vals),
            "spo2_min": safe_min(spo2_vals),
            "temp_avg": safe_avg(temp_vals),
            "battery_pct": batt_rows[0][0] if batt_rows else None,
        },
        "scores": {
            "recovery": recovery,
            "strain": strain,
            "hrv_trend": hrv_trend,   # "improving" | "declining" | "stable"
        },
        "data_points": len(hr_vals),
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/api/insights/recovery")
async def insights_recovery():
    # Use last 7 days HRV baseline vs last 24h
    week_since = _window_start(168)
    day_since = _window_start(24)
    async with get_db_conn() as conn:
        week_hrv = await conn.execute_fetchall(
            "SELECT value FROM hrv WHERE ts >= ?", (week_since,))
        day_hrv = await conn.execute_fetchall(
            "SELECT value FROM hrv WHERE ts >= ?", (day_since,))
        day_hr = await conn.execute_fetchall(
            "SELECT value FROM hr WHERE ts >= ?", (day_since,))

    week_vals = [r[0] for r in week_hrv]
    day_vals = [r[0] for r in day_hrv]
    hr_vals = [r[0] for r in day_hr]

    baseline_hrv = statistics.median(week_vals) if week_vals else 40.0
    current_hrv = day_vals[-1] if day_vals else None
    resting_hr = min(hr_vals) if hr_vals else None

    recovery = _compute_recovery(hr_vals, day_vals)
    score_label = "green" if recovery and recovery >= 67 else "yellow" if recovery and recovery >= 34 else "red"

    return {
        "recovery_score": recovery,
        "score_label": score_label,
        "hrv_baseline_7d": round(baseline_hrv, 1),
        "hrv_current": round(current_hrv, 1) if current_hrv else None,
        "resting_hr": resting_hr,
        "recommendation": _recovery_recommendation(recovery),
    }


@app.get("/api/insights/history")
async def insights_history(days: int = Query(7, ge=1, le=30)):
    result = []
    for d in range(days - 1, -1, -1):
        day_start = _now() - (d + 1) * 86400
        day_end = _now() - d * 86400
        async with get_db_conn() as conn:
            hr_rows = await conn.execute_fetchall(
                "SELECT value FROM hr WHERE ts >= ? AND ts < ?", (day_start, day_end))
            hrv_rows = await conn.execute_fetchall(
                "SELECT value FROM hrv WHERE ts >= ? AND ts < ?", (day_start, day_end))

        hr_vals = [r[0] for r in hr_rows]
        hrv_vals = [r[0] for r in hrv_rows]

        date_str = (datetime.now(timezone.utc) - timedelta(days=d)).strftime("%Y-%m-%d")
        result.append({
            "date": date_str,
            "hr_avg": round(sum(hr_vals) / len(hr_vals), 1) if hr_vals else None,
            "hrv_avg": round(sum(hrv_vals) / len(hrv_vals), 1) if hrv_vals else None,
            "recovery": _compute_recovery(hr_vals, hrv_vals),
            "data_points": len(hr_vals),
        })
    return {"history": result}


# ── WebSocket ─────────────────────────────────────────────────────────────────

@app.websocket("/ws/stream")
async def ws_stream(websocket: WebSocket):
    await hub.connect(websocket)
    try:
        while True:
            # Keep connection alive; client can also send pings
            await websocket.receive_text()
    except WebSocketDisconnect:
        hub.disconnect(websocket)


# ── Analytics helpers ─────────────────────────────────────────────────────────

def _compute_recovery(hr_vals: list, hrv_vals: list) -> Optional[float]:
    if not hrv_vals:
        return None
    hrv = hrv_vals[-1]
    # Simple model: HRV 20ms = 0%, 80ms = 100%
    hrv_score = min(100, max(0, (hrv - 20) / 60 * 100))
    if hr_vals:
        resting = min(hr_vals)
        # Resting HR 40bpm = 100%, 80bpm = 0%
        hr_score = min(100, max(0, (80 - resting) / 40 * 100))
        return round(hrv_score * 0.7 + hr_score * 0.3, 1)
    return round(hrv_score, 1)


def _compute_strain(hr_vals: list) -> Optional[float]:
    if not hr_vals:
        return None
    # Strain: time in each HR zone weighted by zone factor
    # Zones based on 185bpm max HR (adjustable)
    max_hr = 185
    zone_weights = {1: 1, 2: 2, 3: 3, 4: 5, 5: 8}
    zone_minutes = {1: 0, 2: 0, 3: 0, 4: 0, 5: 0}
    for hr in hr_vals:
        pct = hr / max_hr
        if pct < 0.5:      zone_minutes[1] += 1
        elif pct < 0.6:    zone_minutes[2] += 1
        elif pct < 0.7:    zone_minutes[3] += 1
        elif pct < 0.85:   zone_minutes[4] += 1
        else:              zone_minutes[5] += 1
    raw = sum(zone_minutes[z] * zone_weights[z] for z in range(1, 6))
    # Normalize to 0-21 (WHOOP-style)
    strain = min(21, raw / len(hr_vals) * 21) if hr_vals else 0
    return round(strain, 1)


def _hrv_trend(hrv_vals: list) -> str:
    if len(hrv_vals) < 6:
        return "stable"
    first_half = hrv_vals[: len(hrv_vals) // 2]
    second_half = hrv_vals[len(hrv_vals) // 2:]
    avg1 = sum(first_half) / len(first_half)
    avg2 = sum(second_half) / len(second_half)
    diff_pct = (avg2 - avg1) / avg1 * 100
    if diff_pct > 5:
        return "improving"
    if diff_pct < -5:
        return "declining"
    return "stable"


def _recovery_recommendation(score: Optional[float]) -> str:
    if score is None:
        return "Gathering data — wear WHOOP for 24h to see insights."
    if score >= 67:
        return "Recovery is green. Push hard today — your body is ready."
    if score >= 34:
        return "Recovery is yellow. Moderate intensity. Avoid max effort."
    return "Recovery is red. Prioritize rest and sleep tonight."


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=5677, reload=True)
