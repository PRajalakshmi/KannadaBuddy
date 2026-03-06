"""
Kannada OCR server with transliteration (Kannada -> Latin) and translation (Kannada -> English).
Users sign in with Google; quota and subscription are tracked per user in SQLite.
Run: pip install -r requirements.txt && python app.py
"""
import os
import re
from flask import Flask, request, jsonify
from PIL import Image
import pytesseract

from db import (
    init_db,
    get_or_create_user,
    get_user_status,
    can_use_free_quota,
    has_pro,
    increment_free_use,
    link_subscription,
)

app = Flask(__name__)

# Optional: set GOOGLE_CLIENT_ID to verify Google ID tokens (e.g. Android client ID from Firebase).
GOOGLE_CLIENT_ID = os.environ.get("GOOGLE_CLIENT_ID", "")

# Google Play: package and subscription ID for server-side verification. Service account JSON via GOOGLE_APPLICATION_CREDENTIALS.
GOOGLE_PLAY_PACKAGE = os.environ.get("GOOGLE_PLAY_PACKAGE_NAME", "com.kanndabuddy")
GOOGLE_PLAY_SUBSCRIPTION_ID = os.environ.get("GOOGLE_PLAY_SUBSCRIPTION_ID", "kannadabuddy_pro_monthly")


def _user_id_from_request():
    try:
        uid = request.headers.get("X-User-Id")
        return int(uid) if uid else None
    except (TypeError, ValueError):
        return None


def _require_user():
    """Returns (user_id, err_response, err_status). On success err_response and err_status are None."""
    user_id = _user_id_from_request()
    if user_id is None:
        return None, jsonify({"error": "Missing or invalid X-User-Id header"}), 401
    status = get_user_status(user_id)
    if status is None:
        return None, jsonify({"error": "User not found"}), 404
    return user_id, None, None


def _verify_android_subscription(package_name: str, subscription_id: str, purchase_token: str):
    """
    Verify subscription with Google Play Developer API. Returns expiry datetime in ISO (UTC) or None on failure.
    Requires GOOGLE_APPLICATION_CREDENTIALS pointing to a service account JSON with Android Publisher access.
    """
    creds_path = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", "").strip()
    if not creds_path or not os.path.isfile(creds_path):
        return None
    try:
        from google.oauth2 import service_account
        from googleapiclient.discovery import build
        import datetime

        creds = service_account.Credentials.from_service_account_file(
            creds_path,
            scopes=["https://www.googleapis.com/auth/androidpublisher"],
        )
        service = build("androidpublisher", "v3", credentials=creds)
        result = (
            service.purchases()
            .subscriptions()
            .get(
                packageName=package_name,
                subscriptionId=subscription_id,
                token=purchase_token,
            )
            .execute()
        )
        expiry_ms = result.get("expiryTimeMillis")
        if not expiry_ms:
            return None
        # expiryTimeMillis is string, milliseconds since epoch
        ts = int(expiry_ms) / 1000.0
        expiry_dt = datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc)
        return expiry_dt.isoformat()
    except Exception:
        return None


def _user_status_response():
    user_id = _user_id_from_request()
    if user_id is None:
        return {}
    status = get_user_status(user_id)
    return (status or {})


# Kannada script Unicode range (U+0C80–U+0CFF). Lines with no Kannada are left as-is (e.g. English, numbers, URLs).
_KANNADA_RE = re.compile(r"[\u0C80-\u0CFF]+")


def _is_kannada_line(line: str) -> bool:
    """True if the line contains Kannada script; otherwise treat as English/non-Kannada and pass through unchanged."""
    return bool(_KANNADA_RE.search(line))


def _segment_by_kannada(text: str):
    """Split text into segments of consecutive Kannada vs non-Kannada (spaces, symbols, digits, etc.). Returns list of (is_kannada, segment_str)."""
    if not text:
        return []
    # Split by Kannada runs; capturing group keeps the Kannada parts in the list (odd indices).
    parts = re.split(r"([\u0C80-\u0CFF]+)", text)
    result = []
    for i, seg in enumerate(parts):
        if not seg:
            continue
        result.append((i % 2 == 1, seg))
    return result


def transliterate_kannada_to_latin(text: str) -> str:
    """Convert Kannada script to Latin (IAST). Non-Kannada text is returned unchanged."""
    if not text or not text.strip():
        return ""
    if not _is_kannada_line(text):
        return text.strip()
    try:
        from indic_transliteration.sanscript import transliterate
        return transliterate(text.strip(), "kannada", "iast")
    except Exception:
        return ""


def _transliterate_line_passthrough(line: str) -> str:
    """Transliterate only Kannada segments; leave spaces, symbols, digits, and English as-is."""
    if not line.strip():
        return ""
    if not _is_kannada_line(line):
        return line
    out = []
    for is_kannada, seg in _segment_by_kannada(line):
        if is_kannada:
            out.append(transliterate_kannada_to_latin(seg) or seg)
        else:
            out.append(seg)
    return "".join(out)


def _translate_line_passthrough(line: str) -> str:
    """Translate only Kannada segments; leave spaces, symbols, digits, and English as-is."""
    if not line.strip():
        return ""
    if not _is_kannada_line(line):
        return line
    out = []
    for is_kannada, seg in _segment_by_kannada(line):
        if is_kannada:
            out.append(translate_kannada_to_english(seg) or seg)
        else:
            out.append(seg)
    return "".join(out)


# Optional: preferred terms for Kannada→English (e.g. homework/school context).
# Add entries to fix recurring mistranslations. Keys are lowercased for matching.
TRANSLATION_GLOSSARY = {
    # Example: "some google output": "preferred translation",
}


def _preprocess_kannada_for_translation(text: str) -> str:
    """Clean Kannada text before sending to translator for better results."""
    if not text:
        return ""
    s = " ".join(text.strip().split())
    return s.strip()


def _fine_tune_translation(raw: str) -> str:
    """Post-process translated text: sentence case, normalize spaces, apply glossary."""
    if not raw or not raw.strip():
        return ""
    s = " ".join(raw.strip().split())
    lower = s.lower()
    for key, preferred in TRANSLATION_GLOSSARY.items():
        if key in lower:
            s = s.replace(key, preferred)
            s = s.replace(key.capitalize(), preferred)
    if s:
        s = s[0].upper() + s[1:]
        if s[-1] not in ".!?":
            s = s + "."
    return s


def _is_bad_translation(kannada: str, english: str) -> bool:
    """True if we should try another engine (empty, unchanged, or clearly wrong)."""
    if not english or not english.strip():
        return True
    e = english.strip()
    if e == kannada.strip():
        return True
    if len(e) < 2:
        return True
    return False


def translate_kannada_to_english(text: str) -> str:
    """Translate Kannada to English: try Google, fallback to MyMemory; pre/post process."""
    if not text or not text.strip():
        return ""
    inp = _preprocess_kannada_for_translation(text)
    if not inp:
        return ""

    out = None
    # 1) Try Google Translate first (best for most languages)
    try:
        from deep_translator import GoogleTranslator
        out = GoogleTranslator(source="kn", target="en").translate(text=inp)
    except Exception:
        pass

    # 2) Fallback to MyMemory if Google failed or returned a bad result
    if _is_bad_translation(inp, out or ""):
        try:
            from deep_translator import MyMemoryTranslator
            out = MyMemoryTranslator(source="kn", target="en").translate(text=inp)
        except Exception:
            pass

    if _is_bad_translation(inp, out or ""):
        return inp  # Return original if both failed (so user sees something)

    return _fine_tune_translation(out)


def normalize_line_endings(text: str) -> str:
    """Ensure we use \\n only so line structure is preserved end-to-end."""
    if not text:
        return ""
    return text.replace("\r\n", "\n").replace("\r", "\n").strip()


def preserve_format_line_by_line(text: str, process_fn) -> str:
    """Split text into lines, process each line, rejoin. Preserves line/paragraph structure."""
    if not text or not text.strip():
        return ""
    text = normalize_line_endings(text)
    # splitlines() handles \\n, \\r\\n, \\r so we get one entry per line
    lines = text.splitlines()
    result = []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            result.append("")
            continue
        processed = process_fn(stripped)
        result.append(processed if processed else stripped)
    return "\n".join(result)


def _verify_google_id_token(id_token: str):
    """Verify Google ID token and return {"sub": google_id, "email": email, "name": name} or None."""
    if not GOOGLE_CLIENT_ID or not id_token:
        return None
    try:
        from google.oauth2 import id_token
        from google.auth.transport import requests as google_requests
        idinfo = id_token.verify_oauth2_token(
            id_token, google_requests.Request(), GOOGLE_CLIENT_ID
        )
        return {
            "sub": idinfo.get("sub"),
            "email": idinfo.get("email") or "",
            "name": idinfo.get("name") or "",
        }
    except Exception:
        return None


@app.route("/auth/google", methods=["POST"])
def auth_google():
    """Register or sign in with Google. Body: {"id_token": "..."} or {"google_id": "...", "email": "...", "display_name": "..."}."""
    data = request.get_json(silent=True) or {}
    id_token_str = (data.get("id_token") or "").strip()
    google_id = (data.get("google_id") or "").strip()
    email = (data.get("email") or "").strip()
    display_name = (data.get("display_name") or "").strip() or None

    if id_token_str:
        payload = _verify_google_id_token(id_token_str)
        if payload:
            google_id = payload.get("sub") or ""
            email = payload.get("email") or email
            if not display_name and payload.get("name"):
                display_name = payload.get("name")
    if not google_id or not email:
        return jsonify({"error": "Provide id_token or both google_id and email"}), 400

    out = get_or_create_user(google_id, email, display_name=display_name)
    status = get_user_status(out["user_id"])
    return jsonify({
        "user_id": out["user_id"],
        "email": out["email"],
        "display_name": status.get("display_name"),
        "free_use_count": status["free_use_count"],
        "free_use_limit": status["free_use_limit"],
        "has_pro": status["has_pro"],
    })


@app.route("/user/status", methods=["GET"])
def user_status():
    """Return quota and Pro status. Header: X-User-Id."""
    user_id, err_resp, err_status = _require_user()
    if err_resp is not None:
        return err_resp, err_status
    status = get_user_status(user_id)
    return jsonify(status)


@app.route("/user/subscription", methods=["POST"])
def user_subscription():
    """
    Link purchase token to user: verify with Google Play (Android), store expiry in DB, return user status.
    Header: X-User-Id. Body: {"purchase_token": "...", "platform": "android"}.
    Response: { "ok": true, "user_status": {...} } so the app can mark user premium.
    """
    user_id, err_resp, err_status = _require_user()
    if err_resp is not None:
        return err_resp, err_status
    data = request.get_json(silent=True) or {}
    token = (data.get("purchase_token") or data.get("purchaseToken") or "").strip()
    platform = (data.get("platform") or "android").strip().lower()
    expires_at = (data.get("expires_at") or data.get("expiry_date") or "").strip() or None

    if not token:
        return jsonify({"error": "Missing purchase_token"}), 400

    if platform == "android":
        verified_expiry = _verify_android_subscription(
            GOOGLE_PLAY_PACKAGE, GOOGLE_PLAY_SUBSCRIPTION_ID, token
        )
        if verified_expiry is not None:
            expires_at = verified_expiry

    link_subscription(user_id, token, platform, expires_at=expires_at)
    status = get_user_status(user_id)
    return jsonify({"ok": True, "user_status": status})


@app.route("/ocr", methods=["POST"])
def ocr():
    user_id = _user_id_from_request()
    if user_id is not None:
        status = get_user_status(user_id)
        if status is None:
            return jsonify({"error": "User not found"}), 404
        if not can_use_free_quota(user_id):
            return jsonify({
                "error": "Free quota exceeded. Please upgrade to Pro.",
                "user_status": get_user_status(user_id),
            }), 403

    if "image" not in request.files:
        return jsonify({"error": "No image file part named 'image'"}), 400

    file = request.files["image"]
    if file.filename == "":
        return jsonify({"error": "Empty filename"}), 400

    try:
        img = Image.open(file.stream).convert("L")
        img = img.point(lambda x: 0 if x < 160 else 255, "1")
        custom_config = r"--psm 6"
        text = pytesseract.image_to_string(img, lang="kan", config=custom_config)
        text = normalize_line_endings(text or "").strip()

        transliteration = preserve_format_line_by_line(text, _transliterate_line_passthrough) if text else ""
        translation = preserve_format_line_by_line(text, _translate_line_passthrough) if text else ""

        payload = {"text": text, "transliteration": transliteration, "translation": translation}
        if user_id is not None:
            # Only count against quota when we got meaningful text (avoid charging for photos/non-text images)
            if text and not has_pro(user_id):
                increment_free_use(user_id)
            payload["user_status"] = get_user_status(user_id)
        return jsonify(payload)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


def extract_text_from_document(data: bytes, filename: str) -> str:
    """Extract raw text from PDF, DOCX, or TXT. Returns empty string on failure."""
    import io
    ext = (filename or "").split(".")[-1].lower()
    try:
        if ext == "pdf":
            from pypdf import PdfReader
            reader = PdfReader(io.BytesIO(data))
            return "\n".join((page.extract_text() or "") for page in reader.pages).strip()
        if ext == "docx":
            from docx import Document
            doc = Document(io.BytesIO(data))
            return "\n".join(p.text for p in doc.paragraphs).strip()
        if ext == "doc":
            return ""  # Old .doc not supported; use .docx
        if ext == "txt":
            return data.decode("utf-8", errors="replace").strip()
    except Exception:
        pass
    return ""


@app.route("/document", methods=["POST"])
def document():
    user_id = _user_id_from_request()
    if user_id is not None:
        status = get_user_status(user_id)
        if status is None:
            return jsonify({"error": "User not found"}), 404
        if not can_use_free_quota(user_id):
            return jsonify({
                "error": "Free quota exceeded. Please upgrade to Pro.",
                "user_status": get_user_status(user_id),
            }), 403

    if "document" not in request.files:
        return jsonify({"error": "No document file part named 'document'"}), 400

    file = request.files["document"]
    if file.filename == "":
        return jsonify({"error": "Empty filename"}), 400

    try:
        data = file.read()
        text = extract_text_from_document(data, file.filename)
        if not text:
            return jsonify({
                "error": "Could not extract text from this file. Supported: PDF, DOCX, TXT.",
            }), 400

        # Normalize so line breaks are preserved in response (e.g. two lines stay two lines)
        text = normalize_line_endings(text)

        transliteration = preserve_format_line_by_line(text, _transliterate_line_passthrough)
        translation = preserve_format_line_by_line(text, _translate_line_passthrough)

        payload = {"text": text, "transliteration": transliteration, "translation": translation}
        if user_id is not None:
            if not has_pro(user_id):
                increment_free_use(user_id)
            payload["user_status"] = get_user_status(user_id)
        return jsonify(payload)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/text", methods=["POST"])
def text():
    """Accept plain Kannada text (JSON body: {"text": "..."}). Always free; quota/upgrade does not apply."""
    user_id = _user_id_from_request()
    if user_id is not None:
        status = get_user_status(user_id)
        if status is None:
            return jsonify({"error": "User not found"}), 404

    data = request.get_json(silent=True) or {}
    text = (data.get("text") or "").strip()
    if not text:
        return jsonify({"error": "Missing or empty 'text' in request body"}), 400
    try:
        text = normalize_line_endings(text)
        transliteration = preserve_format_line_by_line(text, _transliterate_line_passthrough)
        translation = preserve_format_line_by_line(text, _translate_line_passthrough)
        payload = {"text": text, "transliteration": transliteration, "translation": translation}
        if user_id is not None:
            payload["user_status"] = get_user_status(user_id)
        return jsonify(payload)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# Ensure DB exists and has tables when app is loaded (e.g. by gunicorn).
init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001, debug=True)
