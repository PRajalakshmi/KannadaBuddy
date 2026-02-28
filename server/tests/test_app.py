"""
Tests for the Kannada OCR server API.
Run from server/: python -m pytest tests/ -v
Requires: pip install pytest
"""
import json
import pytest
from app import app


@pytest.fixture
def client():
    app.config["TESTING"] = True
    with app.test_client() as c:
        yield c


# --- /text endpoint ---

def test_text_missing_body(client):
    """POST /text with no JSON returns 400."""
    r = client.post(
        "/text",
        data=None,
        content_type="application/json",
    )
    assert r.status_code == 400
    data = r.get_json()
    assert "error" in data


def test_text_empty_json(client):
    """POST /text with {} returns 400."""
    r = client.post(
        "/text",
        data=json.dumps({}),
        content_type="application/json",
    )
    assert r.status_code == 400
    data = r.get_json()
    assert "error" in data


def test_text_empty_string(client):
    """POST /text with {\"text\": \"\"} returns 400."""
    r = client.post(
        "/text",
        data=json.dumps({"text": ""}),
        content_type="application/json",
    )
    assert r.status_code == 400
    data = r.get_json()
    assert "error" in data


def test_text_valid_returns_200_and_keys(client):
    """POST /text with non-empty Kannada text returns 200 and text, transliteration, translation."""
    r = client.post(
        "/text",
        data=json.dumps({"text": "ನಮಸ್ಕಾರ"}),
        content_type="application/json",
    )
    assert r.status_code == 200, r.get_data(as_text=True)
    data = r.get_json()
    assert "text" in data
    assert "transliteration" in data
    assert "translation" in data
    assert isinstance(data["text"], str)
    assert isinstance(data["transliteration"], str)
    assert isinstance(data["translation"], str)


# --- /ocr endpoint ---

def test_ocr_no_file(client):
    """POST /ocr without 'image' file part returns 400."""
    r = client.post("/ocr", data={})
    assert r.status_code == 400
    data = r.get_json()
    assert "error" in data
    assert "image" in data["error"].lower() or "file" in data["error"].lower()


# --- /document endpoint ---

def test_document_no_file(client):
    """POST /document without 'document' file part returns 400."""
    r = client.post("/document", data={})
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
