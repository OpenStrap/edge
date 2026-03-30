"""Async SQLite database layer."""
import aiosqlite
from contextlib import asynccontextmanager

DB_PATH = "whoop.db"


async def init_db():
    async with aiosqlite.connect(DB_PATH) as conn:
        await conn.executescript("""
            CREATE TABLE IF NOT EXISTS hr (
                id      INTEGER PRIMARY KEY AUTOINCREMENT,
                ts      INTEGER NOT NULL,
                value   INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_hr_ts ON hr(ts);

            CREATE TABLE IF NOT EXISTS hrv (
                id      INTEGER PRIMARY KEY AUTOINCREMENT,
                ts      INTEGER NOT NULL,
                value   REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_hrv_ts ON hrv(ts);

            CREATE TABLE IF NOT EXISTS spo2 (
                id      INTEGER PRIMARY KEY AUTOINCREMENT,
                ts      INTEGER NOT NULL,
                value   REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_spo2_ts ON spo2(ts);

            CREATE TABLE IF NOT EXISTS temperature (
                id      INTEGER PRIMARY KEY AUTOINCREMENT,
                ts      INTEGER NOT NULL,
                value   REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_temp_ts ON temperature(ts);

            CREATE TABLE IF NOT EXISTS battery (
                id       INTEGER PRIMARY KEY AUTOINCREMENT,
                ts       INTEGER NOT NULL,
                value    REAL NOT NULL,
                charging INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_battery_ts ON battery(ts);

            CREATE TABLE IF NOT EXISTS imu (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                ts        INTEGER NOT NULL,
                accel_mag REAL
            );
            CREATE INDEX IF NOT EXISTS idx_imu_ts ON imu(ts);
        """)
        await conn.commit()


@asynccontextmanager
async def get_db_conn():
    async with aiosqlite.connect(DB_PATH) as conn:
        conn.row_factory = aiosqlite.Row
        yield conn
