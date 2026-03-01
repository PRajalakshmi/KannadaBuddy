"""
Tests for the Kannada OCR server API.
Run from server/: python -m pytest tests/ -v
Requires: pip install pytest
"""
import json
import os
import tempfile
import pytest
import db
from app import app

# Use a temp DB for tests so we don't touch the real one.
db.DB_PATH = os.path.join(tempfile.gettempdir(), "kannada_buddy_test.db")


@pytest.fixture
def client():
    app.config["TESTING"] = True
    db.init_db()
    with app.test_client() as c:
        yield c


@pytest.fixture
def test_user(client):
    """Create a test user via /auth/google (google_id + email) and return user_id and headers."""
    r = client.post(
        "/auth/google",
        data=json.dumps({"google_id": "test-google-id-123", "email": "test@example.com"}),
        content_type="application/json",
    )
    assert r.status_code == 200, r.get_data(as_text=True)
    data = r.get_json()
    user_id = data["user_id"]
    return {"user_id": user_id, "headers": {"X-User-Id": str(user_id)}}


# --- /auth/google ---

def test_auth_google_creates_user(client):
    """POST /auth/google with google_id and email returns user_id and status."""
    r = client.post(
        "/auth/google",
        data=json.dumps({"google_id": "unique-id-456", "email": "user@test.com"}),
        content_type="application/json",
    )
    assert r.status_code == 200
    data = r.get_json()
    assert "user_id" in data
    assert data["email"] == "user@test.com"
    assert "free_use_count" in data
    assert "has_pro" in data


def test_auth_google_missing_credentials(client):
    """POST /auth/google without id_token or google_id returns 400."""
    r = client.post("/auth/google", data=json.dumps({}), content_type="application/json")
    assert r.status_code == 400


# --- /text endpoint (requires X-User-Id) ---

def test_text_without_user_id_allowed(client):
    """POST /text without X-User-Id is allowed (anonymous); returns 200 without user_status."""
    r = client.post(
        "/text",
        data=json.dumps({"text": "ನಮಸ್ಕಾರ"}),
        content_type="application/json",
    )
    assert r.status_code == 200
    data = r.get_json()
    assert "text" in data
    assert "user_status" not in data


def test_text_missing_body(client, test_user):
    """POST /text with no JSON returns 400."""
    r = client.post(
        "/text",
        data=None,
        content_type="application/json",
        headers=test_user["headers"],
    )
    assert r.status_code == 400
    data = r.get_json()
    assert "error" in data


def test_text_empty_json(client, test_user):
    """POST /text with {} returns 400."""
    r = client.post(
        "/text",
        data=json.dumps({}),
        content_type="application/json",
        headers=test_user["headers"],
    )
    assert r.status_code == 400
    data = r.get_json()
    assert "error" in data


def test_text_empty_string(client, test_user):
    """POST /text with {\"text\": \"\"} returns 400."""
    r = client.post(
        "/text",
        data=json.dumps({"text": ""}),
        content_type="application/json",
        headers=test_user["headers"],
    )
    assert r.status_code == 400
    data = r.get_json()
    assert "error" in data


def test_text_valid_returns_200_and_keys(client, test_user):
    """POST /text with non-empty Kannada text returns 200 and text, transliteration, translation, user_status."""
    r = client.post(
        "/text",
        data=json.dumps({"text": "ನಮಸ್ಕಾರ"}),
        content_type="application/json",
        headers=test_user["headers"],
    )
    assert r.status_code == 200, r.get_data(as_text=True)
    data = r.get_json()
    assert "text" in data
    assert "transliteration" in data
    assert "translation" in data
    assert "user_status" in data
    assert isinstance(data["text"], str)
    assert isinstance(data["transliteration"], str)
    assert isinstance(data["translation"], str)


# --- /ocr endpoint (requires X-User-Id) ---

def test_ocr_no_user_id_no_file(client):
    """POST /ocr without X-User-Id is allowed; returns 400 for missing image."""
    r = client.post("/ocr", data={})
    assert r.status_code == 400


def test_ocr_no_file(client, test_user):
    """POST /ocr without 'image' file part returns 400."""
    r = client.post("/ocr", data={}, headers=test_user["headers"])
    assert r.status_code == 400
    data = r.get_json()
    assert "error" in data
    assert "image" in data["error"].lower() or "file" in data["error"].lower()


# --- /document endpoint (requires X-User-Id) ---

def test_document_no_user_id_no_file(client):
    """POST /document without X-User-Id is allowed; returns 400 for missing document."""
    r = client.post("/document", data={})
    assert r.status_code == 400


def test_document_no_file(client, test_user):
    """POST /document without 'document' file part returns 400."""
    r = client.post("/document", data={}, headers=test_user["headers"])
    assert r.status_code == 400
    data = r.get_json()
    assert "error" in data
    assert "document" in data["error"].lower() or "file" in data["error"].lower()


# --- Helpers (from app) ---

def test_normalize_line_endings():
    """normalize_line_endings uses \\n only."""
    from app import normalize_line_endings
    assert normalize_line_endings("a\r\nb\r\nc") == "a\nb\nc"
    assert normalize_line_endings("") == ""
    assert normalize_line_endings("  x  ").strip() == "x"


def test_preserve_format_line_by_line():
    """preserve_format_line_by_line splits by lines and applies process_fn."""
    from app import preserve_format_line_by_line
    # identity
    out = preserve_format_line_by_line("a\nb\nc", lambda s: s.upper())
    assert out == "A\nB\nC"
    out = preserve_format_line_by_line("", lambda s: s)
    assert out == ""
