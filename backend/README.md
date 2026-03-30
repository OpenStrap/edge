# Backend

A minimal FastAPI server that receives WHOOP metrics from the companion app, stores them in SQLite, and surfaces basic computed insights.

---

## What This Is (and Isn't)

This backend is a **proof of concept**. It ingests raw sensor data (HR, HRV, SpO2, temperature, IMU, battery) and computes rudimentary recovery and strain scores. It is not — in any meaningful sense — comparable to what WHOOP's actual platform does.

WHOOP's real value is in their algorithms: sleep staging, recovery modeling, strain quantification, coaching intelligence built on years of validated research. This backend does none of that. It applies simple weighted formulas to a handful of metrics and calls it "recovery." Consider it a skeleton you can build on.

---

## Stack

- **FastAPI** — async Python web framework
- **aiosqlite** — async SQLite for local storage
- **WebSocket** — real-time metric broadcast to connected clients

---

## Setup

```bash
cd backend
python -m venv venv
source venv/bin/activate      # Windows: venv\Scripts\activate
pip install fastapi aiosqlite uvicorn

uvicorn main:app --host 0.0.0.0 --port 5677
```

The server starts on port `5677` by default.

---

## Connecting the App

In `/app/lib/core/services/api_client.dart`, set `_base` to your server URL:

```dart
static const _base = 'http://192.168.x.x:5677';   // local network
// or
static const _base = 'https://your-tunnel-domain.com';  // if tunneled
```

If you want to expose the backend publicly (for remote access), use any reverse tunnel tool — ngrok, cloudflared, etc.

---

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Server health check |
| `POST` | `/api/ingest` | Ingest bulk metrics (HR, HRV, SpO2, temp, battery, IMU) |
| `GET` | `/api/metrics/hr?hours=N` | HR history for last N hours |
| `GET` | `/api/metrics/hrv?hours=N` | HRV history |
| `GET` | `/api/metrics/spo2?hours=N` | SpO2 history |
| `GET` | `/api/insights/today` | Today's computed insights (recovery, strain, HRV trend) |
| `GET` | `/api/insights/recovery` | Current recovery score |
| `GET` | `/api/insights/history?days=N` | Historical insights for last N days |
| `WS` | `/ws/stream` | WebSocket live metric stream |

---

## Computed Insights

**Recovery Score (0–100%)**
- 70% weight: HRV score (normalized against 7-day average)
- 30% weight: Resting HR score (lower resting HR = better recovery)

**Strain Score (0–21)**
- Time accumulated in each HR zone × zone weight, normalized to WHOOP's 0–21 scale
- Zone weights: Zone 1 (1×), Zone 2 (2×), Zone 3 (3×), Zone 4 (4×), Zone 5 (5×)

**HRV Trend**
- Compares first and second half of the session's HRV readings
- Returns: `"improving"` / `"stable"` / `"declining"`

These are approximations. Do not make health decisions based on them.

---

## Limitations

- No authentication — anyone on the network can push data to this server
- SQLite is not suitable for high-frequency production workloads
- Insight algorithms are not validated against clinical data
- No sleep staging, no historical trend modeling, no coaching

This is a starting point. The protocol is solved. The data pipeline works. What you do with the data is the hard part.
