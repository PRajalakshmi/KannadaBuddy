"""
SQLite DB for users and subscriptions.
Subscription status is determined by backend from expiry_date; Flutter never caches premium permanently.
"""
import sqlite3
import os
from datetime import datetime, timezone
from contextlib import contextmanager

DB_PATH = os.environ.get("KANNADA_DB_PATH", os.path.join(os.path.dirname(__file__), "kannada_buddy.db"))
FREE_USE_LIMIT = 5


def init_db():
    conn = sqlite3.connect(DB_PATH)
    try:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                google_id TEXT NOT NULL UNIQUE,
                email TEXT NOT NULL,
                display_name TEXT,
                free_use_count INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS subscriptions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL REFERENCES users(id),
                purchase_token TEXT NOT NULL,
                platform TEXT NOT NULL,
                expiry_date TEXT,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_subscriptions_user ON subscriptions(user_id);
        """)
        conn.commit()
        # Migration: add expiry_date if table existed without it
        try:
            conn.execute("ALTER TABLE subscriptions ADD COLUMN expiry_date TEXT")
            conn.commit()
        except sqlite3.OperationalError:
            pass
        # Migration: add display_name if table existed without it
        try:
            conn.execute("ALTER TABLE users ADD COLUMN display_name TEXT")
            conn.commit()
        except sqlite3.OperationalError:
            pass
    finally:
        conn.close()


@contextmanager
def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def get_or_create_user(google_id: str, email: str, display_name: str | None = None):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id, free_use_count, display_name FROM users WHERE google_id = ?", (google_id,)
        ).fetchone()
        if row:
            if display_name is not None and display_name.strip():
                conn.execute("UPDATE users SET display_name = ? WHERE id = ?", (display_name.strip(), row["id"]))
            name = (display_name or row["display_name"] or "").strip() or None
            return {
                "user_id": row["id"],
                "email": email,
                "display_name": name,
                "free_use_count": row["free_use_count"],
                "is_new": False,
            }
        conn.execute(
            "INSERT INTO users (google_id, email, display_name) VALUES (?, ?, ?)",
            (google_id, email, (display_name or "").strip() or None),
        )
        user_id = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
        return {
            "user_id": user_id,
            "email": email,
            "display_name": (display_name or "").strip() or None,
            "free_use_count": 0,
            "is_new": True,
        }


def get_user(user_id: int):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id, google_id, email, display_name, free_use_count FROM users WHERE id = ?", (user_id,)
        ).fetchone()
        return dict(row) if row else None


def has_pro(user_id: int) -> bool:
    """True if user has an active subscription (expiry_date is null or in the future)."""
    now = datetime.now(timezone.utc).isoformat()
    with get_conn() as conn:
        row = conn.execute(
            """SELECT 1 FROM subscriptions WHERE user_id = ?
               AND (expiry_date IS NULL OR expiry_date > ?) LIMIT 1""",
            (user_id, now),
        ).fetchone()
        return row is not None


def get_user_status(user_id: int):
    user = get_user(user_id)
    if not user:
        return None
    premium = has_pro(user_id)
    free_count = user["free_use_count"]
    free_left = max(0, FREE_USE_LIMIT - free_count) if not premium else None
    return {
        "user_id": user["id"],
        "email": user["email"],
        "display_name": user.get("display_name"),
        "free_use_count": free_count,
        "free_use_limit": FREE_USE_LIMIT,
        "has_pro": premium,
        "is_premium": premium,
        "free_scans_left": free_left if free_left is not None else "unlimited",
        "show_ads": not premium,
    }


def can_use_free_quota(user_id: int) -> bool:
    if has_pro(user_id):
        return True
    user = get_user(user_id)
    if not user:
        return False
    return user["free_use_count"] < FREE_USE_LIMIT


def increment_free_use(user_id: int):
    with get_conn() as conn:
        conn.execute(
            "UPDATE users SET free_use_count = free_use_count + 1 WHERE id = ?", (user_id,)
        )


def link_subscription(user_id: int, purchase_token: str, platform: str, expires_at=None):
    """Link purchase to user. expires_at: ISO datetime or None (treated as active until verified)."""
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO subscriptions (user_id, purchase_token, platform, expiry_date) VALUES (?, ?, ?, ?)",
            (user_id, purchase_token, platform, expires_at),
        )
