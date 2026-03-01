"""
SQLite DB for users and subscriptions.
"""
import sqlite3
import os
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
                free_use_count INTEGER NOT NULL DEFAULT 0,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE TABLE IF NOT EXISTS subscriptions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL REFERENCES users(id),
                purchase_token TEXT NOT NULL,
                platform TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            );
            CREATE INDEX IF NOT EXISTS idx_subscriptions_user ON subscriptions(user_id);
        """)
        conn.commit()
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


def get_or_create_user(google_id: str, email: str):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id, free_use_count FROM users WHERE google_id = ?", (google_id,)
        ).fetchone()
        if row:
            return {"user_id": row["id"], "email": email, "free_use_count": row["free_use_count"], "is_new": False}
        conn.execute(
            "INSERT INTO users (google_id, email) VALUES (?, ?)", (google_id, email)
        )
        user_id = conn.execute("SELECT last_insert_rowid()").fetchone()[0]
        return {"user_id": user_id, "email": email, "free_use_count": 0, "is_new": True}


def get_user(user_id: int):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id, google_id, email, free_use_count FROM users WHERE id = ?", (user_id,)
        ).fetchone()
        return dict(row) if row else None


def has_pro(user_id: int) -> bool:
    with get_conn() as conn:
        row = conn.execute(
            "SELECT 1 FROM subscriptions WHERE user_id = ? LIMIT 1", (user_id,)
        ).fetchone()
        return row is not None


def get_user_status(user_id: int):
    user = get_user(user_id)
    if not user:
        return None
    return {
        "user_id": user["id"],
        "email": user["email"],
        "free_use_count": user["free_use_count"],
        "free_use_limit": FREE_USE_LIMIT,
        "has_pro": has_pro(user_id),
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


def link_subscription(user_id: int, purchase_token: str, platform: str):
    with get_conn() as conn:
        conn.execute(
            "INSERT INTO subscriptions (user_id, purchase_token, platform) VALUES (?, ?, ?)",
            (user_id, purchase_token, platform),
        )
