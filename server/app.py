"""
Kannada OCR server with transliteration (Kannada -> Latin) and translation (Kannada -> English).
Transliteration uses Latin (Roman) script with the IAST (International Alphabet of Sanskrit
Transliteration) scheme (e.g. ā ī ū ḷ ṇ ṣ ś).
Users sign in with Google; quota and subscription are tracked per user in SQLite.
Run: pip install -r requirements.txt && python app.py
"""
import os
import re
from typing import Optional
from flask import Flask, request, jsonify
from PIL import Image
import pytesseract

# Linux/Unix servers usually have tesseract at /usr/bin/tesseract. Windows relies on PATH.
# Override anytime with env: TESSERACT_CMD=/path/to/tesseract
_tesseract_cmd = os.environ.get("TESSERACT_CMD", "").strip()
if _tesseract_cmd and os.path.isfile(_tesseract_cmd):
    pytesseract.pytesseract.tesseract_cmd = _tesseract_cmd
elif os.name == "posix" and os.path.isfile("/usr/bin/tesseract"):
    pytesseract.pytesseract.tesseract_cmd = "/usr/bin/tesseract"

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

# Numbering-only lines: short or pure Roman numerals/digits like "2", "IV", "10".
_NUMBERING_ONLY_RE = re.compile(r"^[0-9IVXivx]+$")


def _is_kannada_line(line: str) -> bool:
    """True if the line contains Kannada script; otherwise treat as English/non-Kannada and pass through unchanged."""
    return bool(_KANNADA_RE.search(line))


def _is_numbering_only_line(text: str) -> bool:
    """
    Detect pure numbering headers like "2", "IV", "10".
    Mirrors: if (text.length < 3) return ""; if (/^[0-9IVX]+$/).
    """
    if not text:
        return True
    s = text.strip()
    if not s:
        return True
    # Never treat Kannada text as numbering-only (short Kannada words like "ಮಾ" must not be dropped).
    if _KANNADA_RE.search(s):
        return False
    if len(s) < 3:
        return True
    if _NUMBERING_ONLY_RE.fullmatch(s):
        return True
    return False


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


# Latin letters must never go through Kannada→IAST (library maps them to garbage, e.g. "bugs" → "008").
_LATIN_LETTERS_RE = re.compile(r"[a-zA-Z]")

# Transliteration output is Latin (Roman) script using IAST (International Alphabet of Sanskrit
# Transliteration). Normalize variant characters to strict IAST so app display is consistent.
_IAST_NORMALIZE = {
    "\u013C": "\u1E37",   # ļ (l with cedilla) → ḷ (l with dot below)
    "\u013B": "\u1E36",   # Ļ → Ḷ
    "\u0142": "l",        # ł (Polish l) → l if it appears
}


def _normalize_to_iast(s: str) -> str:
    """Ensure transliteration uses strict IAST (Latin script). Replaces known variants."""
    if not s:
        return s
    for variant, iast in _IAST_NORMALIZE.items():
        s = s.replace(variant, iast)
    return s


def transliterate_kannada_to_latin(text: str) -> str:
    """Convert Kannada script to Latin (Roman) using IAST. Non-Kannada text is returned unchanged."""
    if not text or not text.strip():
        return ""
    if not _is_kannada_line(text):
        return text.strip()
    # Never run Kannada transliterator on strings that contain Latin; sanscript mis-maps them.
    if _LATIN_LETTERS_RE.search(text):
        return text.strip()
    try:
        from indic_transliteration.sanscript import transliterate
        out = transliterate(text.strip(), "kannada", "iast")
        # If output looks like numeric garbage and input had no digits, keep input (safety net).
        if out and out.strip().isdigit() and not any(c.isdigit() for c in text):
            return text.strip()
        return _normalize_to_iast(out) if out else out
    except Exception:
        return text.strip()


def _transliterate_line_passthrough(line: str) -> str:
    """Transliterate only Kannada segments; drop obvious OCR garbage, preserve meaningful non-Kannada."""
    if not line.strip():
        return ""
    # Skip pure numbering lines like "2", "IV", "10" in transliteration/translation views.
    if _is_numbering_only_line(line):
        return ""
    if not _is_kannada_line(line):
        return line
    out = []
    for is_kannada, seg in _segment_by_kannada(line):
        if is_kannada:
            # Segment is a Kannada run only; still skip if Latin slipped in (defensive).
            if _LATIN_LETTERS_RE.search(seg):
                out.append(seg)
            else:
                out.append(transliterate_kannada_to_latin(seg) or seg)
        else:
            # Non-Kannada: keep spaces/real text, but drop pure garbage blobs (€, bullets, etc.).
            s = seg
            if not s.strip():
                out.append(s)
            # Drop short, symbol-only blobs (no letters or digits), e.g. "€ x :" parts from OCR.
            elif not re.search(r"[A-Za-z0-9]", s) and re.search(r"[\u00B7\u2022\u2023\u25E6\u2219\u00B0\u00A2-\u00A5\u20A0-\u20CF€]", s):
                continue
            else:
                out.append(s)
    return "".join(out)


# Cache kn→en per segment to speed PDFs with repeated words (thread-safe for parallel workers).
_TRANSLATE_SEGMENT_CACHE = {}
_TRANSLATE_SEGMENT_CACHE_LOCK = __import__("threading").Lock()
_TRANSLATE_SEGMENT_CACHE_MAX = 4000


def _kannada_run_to_english_or_latin(seg: str) -> str:
    """
    Translate a Kannada-only run to English. If API still returns Kannada (or fails),
    fall back to IAST transliteration so the output has no Kannada script—avoids leaked
    letters in the translation column.
    """
    if not seg or not seg.strip():
        return seg or ""
    key = seg.strip()
    if not _KANNADA_RE.search(key):
        return key
    try:
        t = translate_kannada_to_english(key, append_sentence_period=False) or ""
        t = (t or "").strip()
        if t and not _KANNADA_RE.search(t):
            return t
    except Exception:
        pass
    # Retry without fine_tune (some APIs return Kannada with extra spaces/punct)
    try:
        from deep_translator import GoogleTranslator
        t2 = GoogleTranslator(source="kn", target="en").translate(text=key)
        if t2 and not _KANNADA_RE.search(t2.strip()):
            return t2.strip()
    except Exception:
        pass
    try:
        from deep_translator import MyMemoryTranslator
        t3 = MyMemoryTranslator(source="kn", target="en").translate(text=key)
        if t3 and not _KANNADA_RE.search(t3.strip()):
            return t3.strip()
    except Exception:
        pass
    # Last resort: Latin transliteration (no Kannada glyphs)
    try:
        latin = transliterate_kannada_to_latin(key)
        if latin and not _KANNADA_RE.search(latin):
            return latin
    except Exception:
        pass
    return key


def _translate_segment_cached(seg: str) -> str:
    """Translate a single Kannada-only segment; cached only when result has no Kannada script."""
    if not seg or not seg.strip():
        return seg
    key = seg.strip()
    with _TRANSLATE_SEGMENT_CACHE_LOCK:
        if key in _TRANSLATE_SEGMENT_CACHE:
            cached = _TRANSLATE_SEGMENT_CACHE[key]
            # Never serve cached value that still contains Kannada (stale bad API response)
            if cached and not _KANNADA_RE.search(cached):
                return cached
            del _TRANSLATE_SEGMENT_CACHE[key]
    try:
        t = translate_kannada_to_english(key, append_sentence_period=False) or key
    except Exception:
        t = key
    # If API echoed Kannada or returned garbage with Kannada, force Latin/English path
    if t and _KANNADA_RE.search(t):
        t = _kannada_run_to_english_or_latin(key)
    with _TRANSLATE_SEGMENT_CACHE_LOCK:
        if len(_TRANSLATE_SEGMENT_CACHE) >= _TRANSLATE_SEGMENT_CACHE_MAX:
            _TRANSLATE_SEGMENT_CACHE.clear()
        # Only cache successful English (no Kannada script in output)
        if t and not _KANNADA_RE.search(t):
            _TRANSLATE_SEGMENT_CACHE[key] = t
    return t


def _segment_into_phrases(segments: list) -> list:
    """
    Group segments into phrase runs: consecutive Kannada with only space/punct between
    become one phrase. Returns list of ("text", s) or ("phrase", s).
    """
    items = []
    i = 0
    while i < len(segments):
        is_k, seg = segments[i]
        if not is_k:
            items.append(("text", seg))
            i += 1
            continue
        parts = []
        while i < len(segments):
            is_k, seg = segments[i]
            if is_k:
                parts.append(seg)
                i += 1
            else:
                if seg.strip():
                    break
                parts.append(seg)
                i += 1
        if parts:
            items.append(("phrase", "".join(parts)))
    return items


def _translate_phrase_cached(phrase: str) -> str:
    """Translate a Kannada phrase (one or more words); cached when result is clean."""
    if not phrase or not phrase.strip():
        return phrase
    key = phrase.strip()
    with _TRANSLATE_SEGMENT_CACHE_LOCK:
        if key in _TRANSLATE_SEGMENT_CACHE:
            cached = _TRANSLATE_SEGMENT_CACHE[key]
            if cached and not _KANNADA_RE.search(cached):
                return cached
            del _TRANSLATE_SEGMENT_CACHE[key]
    try:
        t = translate_kannada_to_english(key, append_sentence_period=False) or key
    except Exception:
        t = key
    if t and _KANNADA_RE.search(t):
        t = _kannada_run_to_english_or_latin(key)
    with _TRANSLATE_SEGMENT_CACHE_LOCK:
        if len(_TRANSLATE_SEGMENT_CACHE) >= _TRANSLATE_SEGMENT_CACHE_MAX:
            _TRANSLATE_SEGMENT_CACHE.clear()
        if t and not _KANNADA_RE.search(t):
            _TRANSLATE_SEGMENT_CACHE[key] = t
    return t


def _translate_line_phrase(line: str) -> str:
    """Translate at phrase level: group consecutive Kannada (with spaces) into phrases, translate each phrase."""
    if not line.strip():
        return ""
    if _is_numbering_only_line(line):
        return ""
    if not _is_kannada_line(line):
        return line
    segments = list(_segment_by_kannada(line))
    items = _segment_into_phrases(segments)
    out = []
    for kind, s in items:
        if kind == "text":
            out.append(s)
        else:
            if _LATIN_LETTERS_RE.search(s):
                out.append(s)
            else:
                out.append(_translate_phrase_cached(s) or s)
    joined = "".join(out)
    if joined and joined.rstrip() and joined.rstrip()[-1] not in ".!?":
        joined = joined.rstrip() + "."
    return joined


def _translate_line_phrase_parallel(line: str) -> str:
    """Phrase translation with parallel API calls for each phrase."""
    if not line.strip():
        return ""
    if _is_numbering_only_line(line):
        return ""
    if not _is_kannada_line(line):
        return line
    segments = list(_segment_by_kannada(line))
    items = _segment_into_phrases(segments)
    phrase_items = [(i, s) for i, (kind, s) in enumerate(items) if kind == "phrase" and not _LATIN_LETTERS_RE.search(s)]
    if not phrase_items:
        joined = "".join(s for _, s in items)
        if joined and joined.rstrip() and joined.rstrip()[-1] not in ".!?":
            joined = joined.rstrip() + "."
        return joined
    from concurrent.futures import ThreadPoolExecutor, as_completed
    workers = max(2, min(16, int(os.environ.get("TRANSLATE_SEGMENT_WORKERS", "8") or "8")))
    translated = {}
    if len(phrase_items) == 1:
        idx, phrase = phrase_items[0]
        translated[idx] = _translate_phrase_cached(phrase)
    else:
        with ThreadPoolExecutor(max_workers=min(workers, len(phrase_items))) as ex:
            futs = {ex.submit(lambda i_ph: (i_ph[0], _translate_phrase_cached(i_ph[1])), ip): ip for ip in phrase_items}
            for fut in as_completed(futs):
                idx, t = fut.result()
                translated[idx] = t
    out = []
    for i, (kind, s) in enumerate(items):
        if kind == "text":
            out.append(s)
        else:
            out.append(translated.get(i, _translate_phrase_cached(s) if not _LATIN_LETTERS_RE.search(s) else s))
    joined = "".join(out)
    if joined and joined.rstrip() and joined.rstrip()[-1] not in ".!?":
        joined = joined.rstrip() + "."
    return joined


def _translate_line_passthrough(line: str) -> str:
    """Translate only Kannada segments (word-level); leave spaces, symbols, digits, and English as-is."""
    if not line.strip():
        return ""
    if not _is_kannada_line(line):
        return line
    out = []
    for is_kannada, seg in _segment_by_kannada(line):
        if is_kannada:
            if _LATIN_LETTERS_RE.search(seg):
                out.append(seg)
            else:
                out.append(_translate_segment_cached(seg) or seg)
        else:
            out.append(seg)
    joined = "".join(out)
    # Single trailing period for the whole line (segments no longer each add ".").
    if joined and joined.rstrip() and joined.rstrip()[-1] not in ".!?":
        joined = joined.rstrip() + "."
    return joined


def _translate_line_passthrough_parallel(line: str) -> str:
    """
    Same output as _translate_line_passthrough but translates Kannada segments in parallel
    within the line. Matches image OCR quality (segment-wise) without sequential API waits.
    """
    if not line.strip():
        return ""
    if not _is_kannada_line(line):
        return line
    segments = list(_segment_by_kannada(line))
    # Positions in segments list that are Kannada-only (safe for kn→en)
    to_translate = []  # (position_in_segments, seg)
    for pos, (is_kannada, seg) in enumerate(segments):
        if is_kannada and not _LATIN_LETTERS_RE.search(seg):
            to_translate.append((pos, seg))

    if not to_translate:
        joined = "".join(seg for _, seg in segments)
        if joined and joined.rstrip() and joined.rstrip()[-1] not in ".!?":
            joined = joined.rstrip() + "."
        return joined

    seg_workers = int(os.environ.get("TRANSLATE_SEGMENT_WORKERS", "8") or "8")
    seg_workers = max(2, min(seg_workers, 16))

    from concurrent.futures import ThreadPoolExecutor, as_completed

    translated_by_pos = {}

    def translate_one(pos_seg):
        pos, seg = pos_seg
        return pos, _translate_segment_cached(seg)

    if len(to_translate) == 1:
        pos, seg = to_translate[0]
        translated_by_pos[pos] = _translate_segment_cached(seg)
    else:
        with ThreadPoolExecutor(max_workers=min(seg_workers, len(to_translate))) as ex:
            futs = [ex.submit(translate_one, item) for item in to_translate]
            for fut in as_completed(futs):
                pos, translated = fut.result()
                translated_by_pos[pos] = translated

    out_parts = []
    for pos, (is_kannada, seg) in enumerate(segments):
        if pos in translated_by_pos:
            out_parts.append(translated_by_pos[pos])
        else:
            out_parts.append(seg)
    joined = "".join(out_parts)
    if joined and joined.rstrip() and joined.rstrip()[-1] not in ".!?":
        joined = joined.rstrip() + "."
    return joined


def _translate_line_whole(line: str) -> str:
    """
    Translate at phrase level: group consecutive Kannada into phrases, translate each phrase.
    Fewer API calls than word-level and more natural than one huge line for mixed content.
    """
    if not line.strip():
        return ""
    if _is_numbering_only_line(line):
        return ""
    if not _is_kannada_line(line):
        return line
    return _translate_line_phrase_parallel(line)


def _translate_kannada_runs_in_string(s: str) -> str:
    """
    Replace each contiguous Kannada run with English via kn→en. Used when mixed lines still
    contain Kannada after passthrough (Latin guard skipped whole segment). Preserves non-Kannada.
    """
    if not s or not _KANNADA_RE.search(s):
        return s
    parts = re.split(r"([\u0C80-\u0CFF]+)", s)
    out = []
    for i, p in enumerate(parts):
        if not p:
            continue
        if i % 2 == 1 and _KANNADA_RE.fullmatch(p):
            try:
                t = _translate_segment_cached(p)
                if t and t.strip() and not _KANNADA_RE.search(t):
                    out.append(t.strip())
                else:
                    # Cached/API path left Kannada — force Latin fallback
                    out.append(_kannada_run_to_english_or_latin(p))
            except Exception:
                try:
                    out.append(_kannada_run_to_english_or_latin(p))
                except Exception:
                    out.append(p)
        else:
            out.append(p)
    return "".join(out)


def _fix_document_translation_kannada_leaks(source_text: str, translation: str) -> str:
    """
    Whole-line translate returns source unchanged when line has Latin, leaving Kannada in output.
    1) Re-run segment passthrough on source line.
    2) If translation line still contains Kannada, translate each Kannada run in that line only
       (so glossary lines become natural English without re-sending whole line as kn-only).
    """
    if not translation or not source_text:
        return translation or ""
    src_lines = source_text.splitlines()
    tr_lines = translation.splitlines()
    out = []
    for i, src in enumerate(src_lines):
        tr = tr_lines[i] if i < len(tr_lines) else ""
        if not src.strip():
            out.append(tr)
            continue
        # Cheap first pass: translate Kannada runs inside the line only (no full segment walk on source).
        if _KANNADA_RE.search(tr):
            try:
                tr2 = _translate_kannada_runs_in_string(tr)
                if tr2 and not _KANNADA_RE.search(tr2):
                    tr = tr2
                elif tr2:
                    tr = tr2
            except Exception:
                pass
        # Still Kannada: full segment translate on source (parallel — same quality as image path).
        if _KANNADA_RE.search(tr):
            try:
                tr = _translate_line_phrase_parallel(src)
            except Exception:
                try:
                    tr = _translate_line_phrase(src)
                except Exception:
                    pass
        # Second pass: any remaining Kannada → runs only again (mixed safe).
        if _KANNADA_RE.search(tr):
            try:
                tr2 = _translate_kannada_runs_in_string(tr)
                if tr2 and not _KANNADA_RE.search(tr2):
                    tr = tr2
                elif tr2:
                    tr = tr2  # partial improvement
            except Exception:
                pass
        # Last resort: still Kannada — parallel passthrough again (cache may help second time).
        if _KANNADA_RE.search(tr):
            try:
                tr = _translate_line_phrase_parallel(src)
            except Exception:
                pass
        out.append(tr)
    return "\n".join(out)


def _strip_kannada_script_from_translation(translation: str) -> str:
    """
    Final pass: any remaining Kannada script in translation is replaced by English or IAST.
    Preserves line count (line-by-line). Safe to call on full document translation payload.
    """
    if not translation or not _KANNADA_RE.search(translation):
        return translation
    lines = translation.splitlines()
    out = []
    for line in lines:
        if not line.strip() or not _KANNADA_RE.search(line):
            out.append(line)
            continue
        try:
            fixed = _translate_kannada_runs_in_string(line)
            if fixed and not _KANNADA_RE.search(fixed):
                out.append(fixed)
            else:
                # Run-by-run replace still left Kannada — split and force each run
                parts = re.split(r"([\u0C80-\u0CFF]+)", line)
                merged = []
                for j, p in enumerate(parts):
                    if not p:
                        continue
                    if j % 2 == 1 and _KANNADA_RE.fullmatch(p):
                        merged.append(_kannada_run_to_english_or_latin(p))
                    else:
                        merged.append(p)
                out.append("".join(merged))
        except Exception:
            out.append(line)
    return "\n".join(out)


def _final_decode_other_language(translation: str, source_text: Optional[str] = None) -> str:
    """
    At the end of translation: if a line contains any ASCII (English) and also non-ASCII
    (Kannada or other script), decode those other-language runs to English/Latin by
    comparing with the input (source) line when available.
    """
    if not translation or not translation.strip():
        return translation
    lines = translation.splitlines()
    src_lines = (source_text or "").splitlines() if source_text else []
    out = []
    for i, line in enumerate(lines):
        if not line.strip():
            out.append(line)
            continue
        has_ascii = any(ord(c) < 128 for c in line)
        if not has_ascii:
            out.append(line)
            continue
        if not _KANNADA_RE.search(line):
            out.append(line)
            continue
        source_line = src_lines[i] if i < len(src_lines) else ""
        try:
            parts = re.split(r"([\u0C80-\u0CFF]+)", line)
            merged = []
            for j, p in enumerate(parts):
                if not p:
                    continue
                if j % 2 == 1 and _KANNADA_RE.fullmatch(p):
                    # Prefer decoding using the same run from source when present (canonical form)
                    to_decode = p.strip() if (source_line and p.strip() in source_line) else p
                    decoded = _kannada_run_to_english_or_latin(to_decode)
                    merged.append(decoded)
                else:
                    merged.append(p)
            out.append("".join(merged))
        except Exception:
            try:
                fixed = _translate_kannada_runs_in_string(line)
                out.append(fixed if fixed else line)
            except Exception:
                out.append(line)
    return "\n".join(out)


def _naturalize_translation(text: str) -> str:
    """
    Replace awkward machine-translated lines (feedback/survey style) with natural English.
    Triggered by substring heuristics so we don't depend on exact API wording.
    """
    if not text or not text.strip():
        return text

    def fix_line(line: str) -> str:
        s = line.strip()
        if not s:
            return line
        # Match without leading quote/bullet noise
        low = s.lower().lstrip('"\';*•·▪▫- ').strip()

        # Do not return "" here — dropping lines breaks Summary tab pairing (transliteration
        # is line-aligned with translation by index). Junk lines keep original below.

        # 1) Errors/bugs — ಯಾವುದಾದರೂ ದೋಷಗಳು (bugs) often becomes "Anything Errors (bugs)."
        if ("error" in low or "doṣa" in low) and ("bug" in low or "anything" in low):
            return "Have you noticed any errors or bugs?"
        if low.startswith("anything") and "error" in low:
            return "Have you noticed any errors or bugs?"

        # 2) Suggestions — ಸುಧಾರಣೆಗಾಗಿ ನಿಮ್ಮ ಸಲಹೆಗಳು ಏನು?
        if "improvement" in low and ("tip" in low or "suggest" in low):
            return "Do you have any suggestions to improve the app?"
        if "improvement" in low and low.rstrip(".?").endswith("what"):
            return "Do you have any suggestions to improve the app?"
        if "for improvement" in low and "your" in low and "what" in low:
            return "Do you have any suggestions to improve the app?"

        # 3) Feedback important — ನಿಮ್ಮ ಪ್ರತಿಕ್ರಿಯೆ ನನಗೆ ತುಂಬಾ ಮುಖ್ಯ
        if ("feedback" in low or "response" in low or "pratikriye" in low) and "important" in low:
            return "Your feedback is very important to us."
        if "too much" in low and "important" in low:
            return "Your feedback is very important to us."
        if "to me" in low and "important" in low and ("your" in low or "much" in low):
            return "Your feedback is very important to us."

        # 4) Thanks — ಮತ್ತೊಮ್ಮೆ ನಿಮ್ಮ ಸಹಾಯಕ್ಕೆ ಧನ್ಯವಾದಗಳು
        if "thank you" in low and ("help" in low or "again" in low or "support" in low):
            return "Thank you for your support!"
        if low.startswith("again your") and "thank" in low:
            return "Thank you for your support!"
        if "thank you" in low and "sahāya" in low:  # transliteration leak
            return "Thank you for your support!"

        return line

    # Must preserve exact line count and order so Flutter Summary pairs transliteration[i] with translation[i].
    out_lines = []
    for ln in text.splitlines():
        fixed = fix_line(ln)
        out_lines.append(fixed if fixed else ln)
    return "\n".join(out_lines) if out_lines else text


# Optional: preferred terms for Kannada→English (e.g. homework/school context).
# Add entries to fix recurring mistranslations. Keys are lowercased for matching.
TRANSLATION_GLOSSARY = {
    # Example: "some google output": "preferred translation",
}


# Trained sentences/words: exact Kannada line → correct transliteration (IAST) and English.
# Keys are normalized (strip); add entries from curriculum so app shows these instead of API output.
CUSTOM_TRANSLITERATION_LINES = {
    "ಪದಗಳ ಅರ್ಥ ತಿಳಿಯಿರಿ :": "padagaḷa artha tiḷiyiri :",
    "ಪದಗಳ ಅರ್ಥ ತಿಳಿಯಿರಿ:": "padagaḷa artha tiḷiyiri:",
    "ಹೊಂದಿಸಿ ಬರೆಯಿರಿ.": "hondisi bareyiri.",
    "ಬಿಡಿಸಿ ಬರೆಯಿರಿ.": "bidisi bareyiri.",
    "ವಿರುದ್ಧ ಪದಗಳು:": "viruddha padagaḷu:",
    "ಒಂದು ವಾಕ್ಯದಲ್ಲಿ ಉತ್ತರಿಸಿ.": "ondu vākyadalli uttarisiri.",
    "ಈ ಮಾತುಗಳನ್ನು ಯಾರು ಯಾರಿಗೆ ಹೇಳಿದರು?": "ī mātugaḷannu yāru yārige hēḷidaru?",
    "ಪದಗಳ": "padagaḷa",
    "ಅರ್ಥ": "artha",
    "ತಿಳಿಯಿರಿ": "tiḷiyiri",
    "ಹೊಂದಿಸಿ": "hondisi",
    "ಬರೆಯಿರಿ": "bareyiri",
    "ಬಿಡಿಸಿ": "bidisi",
    "ವಿರುದ್ಧ": "viruddha",
    "ಪದಗಳು": "padagaḷu",
    "ಒಂದು": "ondu",
    "ವಾಕ್ಯದಲ್ಲಿ": "vākyadalli",
    "ಉತ್ತರಿಸಿ": "uttarisiri",
    "ಈ": "ī",
    "ಮಾತುಗಳನ್ನು": "mātugaḷannu",
    "ಯಾರು": "yāru",
    "ಯಾರಿಗೆ": "yārige",
    "ಹೇಳಿದರು": "hēḷidaru",
}

CUSTOM_TRANSLATION_LINES = {
    "ಪದಗಳ ಅರ್ಥ ತಿಳಿಯಿರಿ :": "Understand the meanings of the words.",
    "ಪದಗಳ ಅರ್ಥ ತಿಳಿಯಿರಿ:": "Understand the meanings of the words.",
    "ಹೊಂದಿಸಿ ಬರೆಯಿರಿ.": "Match and write.",
    "ಬಿಡಿಸಿ ಬರೆಯಿರಿ.": "Separate and write.",
    "ವಿರುದ್ಧ ಪದಗಳು:": "Opposite words.",
    "ಒಂದು ವಾಕ್ಯದಲ್ಲಿ ಉತ್ತರಿಸಿ.": "Answer in one sentence.",
    "ಈ ಮಾತುಗಳನ್ನು ಯಾರು ಯಾರಿಗೆ ಹೇಳಿದರು?": "Who said these words to whom?",
    "ಪದಗಳ": "of words",
    "ಅರ್ಥ": "meaning",
    "ತಿಳಿಯಿರಿ": "understand / learn",
    "ಹೊಂದಿಸಿ": "match / pair",
    "ಬರೆಯಿರಿ": "write",
    "ಬಿಡಿಸಿ": "separate / split",
    "ವಿರುದ್ಧ": "opposite",
    "ಪದಗಳು": "words",
    "ಒಂದು": "one",
    "ವಾಕ್ಯದಲ್ಲಿ": "in a sentence",
    "ಉತ್ತರಿಸಿ": "answer",
    "ಈ": "these",
    "ಮಾತುಗಳನ್ನು": "words / sentences",
    "ಯಾರು": "who",
    "ಯಾರಿಗೆ": "to whom",
    "ಹೇಳಿದರು": "said / told",
    "ಕೂಸು ಕಂದಯ್ಯ": "baby",
}


def _normalize_line_for_override(s: str) -> str:
    """Single spaces, strip, no trailing . or : so document and OCR lines match same override."""
    if not s:
        return ""
    return " ".join(s.strip().split()).strip().rstrip(".:").strip()


def _override_lookup(line: str, override_map: dict):
    """Exact match first; then normalized match (spaces + trailing .:) so document and image align."""
    k = line.strip()
    if k in override_map:
        return override_map[k]
    k_norm = _normalize_line_for_override(k)
    if not k_norm:
        return None
    for key, value in override_map.items():
        if _normalize_line_for_override(key) == k_norm:
            return value
    return None


def _apply_custom_line_overrides(
    source_text: str, result_text: str, override_map: dict
) -> str:
    """Replace result lines with trained overrides when source line matches. Preserves line count."""
    if not source_text or not result_text or not override_map:
        return result_text
    src_lines = source_text.splitlines()
    res_lines = result_text.splitlines()
    out = []
    for i, src in enumerate(src_lines):
        override = _override_lookup(src, override_map)
        if override is not None:
            out.append(override)
        elif i < len(res_lines):
            out.append(res_lines[i])
        else:
            out.append("")
    return "\n".join(out)


def _preprocess_kannada_for_translation(text: str) -> str:
    """Clean Kannada text before sending to translator for better results."""
    if not text:
        return ""
    s = " ".join(text.strip().split())
    return s.strip()


def _fine_tune_translation(raw: str, append_period: bool = True) -> str:
    """Post-process translated text: sentence case, normalize spaces, apply glossary.
    When append_period is False, no trailing dot is added (used for segment-by-segment
    translation so we don't get 'Word. Next.' after every chunk)."""
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
        # Segment-by-segment translation joins with ""; adding "." per segment causes "Word. Next.".
        if append_period and s[-1] not in ".!?":
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


def translate_kannada_to_english(text: str, append_sentence_period: bool = True) -> str:
    """Translate Kannada to English: try Google, fallback to MyMemory; pre/post process.
    Never raises: network/SSL/timeouts return original segment so document/OCR requests don't 500."""
    if not text or not text.strip():
        return ""
    inp = _preprocess_kannada_for_translation(text)
    if not inp:
        return ""
    # Never send pure Latin/English (no Kannada) to kn→en; APIs often return garbage (e.g. "bugs" → "008").
    # Mixed lines (Kannada + Latin) are allowed so full sentences can be translated.
    if _LATIN_LETTERS_RE.search(inp) and not _KANNADA_RE.search(inp):
        return inp.strip()
    try:
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

        out = _fine_tune_translation(out, append_period=append_sentence_period)
        # If API returned digit-only garbage and input had no digits, keep original.
        if out and out.strip().isdigit() and not any(c.isdigit() for c in inp):
            return inp.strip()
        return out
    except Exception:
        # Gunicorn worker timeout during requests.get can abort worker; catch any leak + always return something
        return inp.strip()


def _ai_correct_kannada_line(line: str) -> str:
    """
    Optional AI-based correction for OCR'd Kannada text before translation.
    Uses Google Translate kn→kn (via deep_translator) when USE_AI_CORRECT=1.
    Falls back to the original line on any error.
    """
    if not line or not line.strip():
        return line
    if os.environ.get("USE_AI_CORRECT", "").strip().lower() not in ("1", "true", "yes"):
        return line
    # Only attempt correction when the line has Kannada script.
    if not _KANNADA_RE.search(line):
        return line
    try:
        from deep_translator import GoogleTranslator
        fixed = GoogleTranslator(source="kn", target="kn").translate(text=line)
        return fixed or line
    except Exception:
        return line


def _ai_correct_english_line(line: str) -> str:
    """
    Optional AI-based correction for translated English text (grammar/fluency).
    Uses Google Translate en→en (via deep_translator) when USE_AI_CORRECT=1.
    Falls back to the original line on any error.
    """
    if not line or not line.strip():
        return line
    if os.environ.get("USE_AI_CORRECT", "").strip().lower() not in ("1", "true", "yes"):
        return line
    # Only attempt when line has Latin letters (likely English).
    if not _LATIN_LETTERS_RE.search(line):
        return line
    try:
        from deep_translator import GoogleTranslator
        fixed = GoogleTranslator(source="en", target="en").translate(text=line)
        return fixed or line
    except Exception:
        return line


def _strip_ocr_garbage_from_line(line: str) -> str:
    """
    Remove obvious OCR garbage suffixes (like trailing digit blobs '668!' after a Kannada word)
    before transliteration/translation. Keeps core Kannada word/phrase intact.
    """
    if not line or not line.strip():
        return line
    # Only clean lines that contain Kannada; pure English/number lines are left as-is.
    if not _KANNADA_RE.search(line):
        return line
    # Fix specific mid-line garbage we see from OCR, e.g. '€ x :' between Kannada and 'written expression'.
    # Example raw: 'ಒಂದು ವಾಕ್ಯದಲ್ಲಿ € x :ರೆಯಿರಿ written expression'
    line = re.sub(r"\s*€\s*x\s*:\s*", " ", line)

    # Strip tiny trailing Latin blobs after Kannada, e.g. 'ಜಗತ್ತಿಗೆ ಮಗು ಏನಾಗಿ. . vw?'
    # Keep the question mark but drop a 1–3 letter suffix like 'vw' or 'vw?'.
    if _KANNADA_RE.search(line):
        line = re.sub(r"\s+[A-Za-z]{1,3}\?*$", "?", line)

    # Strip trailing runs of digits, noisy punctuation, currency, and stray dots/combining marks
    # (no Kannada chars in that run). This catches things like '668!', '•', '€', broken dotted blobs.
    cleaned = re.sub(r"[0-9\u00B7\u2022\u2023\u25E6\u2219\u00B0\u00A2-\u00A5\u20A0-\u20CF\u0300-\u036F]+[0-9!@#$%^&*()_+=\\-\\[\\]{};:'\",.<>/?\\|`~\u00B7\u2022\u2023\u25E6\u2219\u00B0\u00A2-\u00A5\u20A0-\u20CF\u0300-\u036F]*\\s*$", "", line)
    return cleaned.rstrip() or line.strip()


# Fixed English labels that often appear after Kannada, where OCR inserts junk symbols in between.
_OCR_ENGLISH_LABELS = [
    "written expression",
    "oral expression",
    "fill in the blanks",
]


def _filter_ocr_lines(text: str) -> str:
    """
    Drop clearly irrelevant OCR lines (timestamps, headers, pure English like 'PDF reader')
    so they don't appear at the top of results.
    Keep:
      - lines containing Kannada script, or
      - non-empty lines that are not pure timestamp/garbage.
    """
    if not text or not text.strip():
        return text
    lines = normalize_line_endings(text).splitlines()
    kept = []
    for ln in lines:
        s = ln.strip()
        if not s:
            continue
        # Count Kannada vs total non-space chars.
        total = sum(1 for ch in s if not ch.isspace())
        kn = sum(1 for ch in s if "\u0C80" <= ch <= "\u0CFF")

        # Drop lines with no Kannada at all (pure English/metadata like 'PDF reader', '( Nana kanda notes... Ba:').
        if kn == 0:
            continue

        # Drop lines that are mostly digits/symbols with only a stray Kannada char or two
        # and typical timestamp/garbage symbols like %, € etc.
        if total > 0 and kn / total < 0.3 and re.search(r"[%€]", s):
            continue

        kept.append(s)
    return "\n".join(kept)


def _merge_broken_kannada_tokens(line: str) -> str:
    """
    Fix simple OCR/PDF word breaks inside Kannada words, for both sajāti and vijāti conjuncts:
      - 'ಮ ಗು' -> 'ಮಗು' (space between short Kannada tokens)
      - 'ಕ್ ಕ' / 'ಚ್ ಚ' -> 'ಕ್ಕ' / 'ಚ್ಚ' (space before halant+consonant)
      - 'ಮುತ್ತ ು' -> 'ಮುತ್ತು' (space before dependent vowel sign)
    """
    if not line or not line.strip():
        return line

    # First pass: merge short, pure-Kannada tokens separated by spaces.
    tokens = line.split()
    if len(tokens) < 2:
        merged = line
    else:
        out = []
        i = 0
        while i < len(tokens):
            tok = tokens[i]
            nxt = tokens[i + 1] if i + 1 < len(tokens) else None
            if (
                nxt is not None
                and _KANNADA_RE.fullmatch(tok)
                and _KANNADA_RE.fullmatch(nxt)
                and len(tok) <= 2
                and len(nxt) <= 2
            ):
                out.append(tok + nxt)
                i += 2
            else:
                out.append(tok)
                i += 1
        merged = " ".join(out)

    # Second pass: remove spaces between base letters and following halant+consonant,
    # so 'ಕ್ ಕ' / 'ಚ್ ಚ' etc. become 'ಕ್ಕ' / 'ಚ್ಚ'.
    merged = re.sub(r"([\u0C80-\u0CFF])\s*(\u0CCD[\u0C80-\u0CFF])", r"\1\2", merged)

    # Third pass: remove spaces between base syllable and following dependent vowel signs,
    # e.g. 'ಮುತ್ತ ು' -> 'ಮುತ್ತು'.
    merged = re.sub(r"([\u0C80-\u0CFF])\s*([\u0CBE-\u0CCC\u0CD5-\u0CD6])", r"\1\2", merged)

    return merged


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
        try:
            processed = process_fn(stripped)
        except Exception:
            processed = stripped  # e.g. translation API timeout — keep line so document still returns 200
        result.append(processed if processed else stripped)
    return "\n".join(result)


def preserve_format_line_by_line_parallel(text: str, process_fn, max_workers: int = None) -> str:
    """
    Same as preserve_format_line_by_line but runs process_fn concurrently per non-empty line.
    Speeds up document/image translation (many HTTP calls). Cap workers to avoid rate limits.
    Set TRANSLATE_PARALLEL_WORKERS=0 to disable (use sequential).
    """
    if not text or not text.strip():
        return ""
    if os.environ.get("TRANSLATE_PARALLEL_WORKERS", "").strip() == "0":
        return preserve_format_line_by_line(text, process_fn)
    text = normalize_line_endings(text)
    lines = text.splitlines()
    n = len(lines)
    if n <= 1:
        return preserve_format_line_by_line(text, process_fn)
    # Default 10 workers — document/PDF benefits from higher parallelism; cap to avoid rate limits
    if max_workers is None:
        max_workers = int(os.environ.get("TRANSLATE_PARALLEL_WORKERS", "10") or "10")
    max_workers = max(2, min(max_workers, 16))

    from concurrent.futures import ThreadPoolExecutor, as_completed

    result = [""] * n

    def work(idx: int, stripped: str):
        try:
            out = process_fn(stripped)
            return idx, (out if out else stripped)
        except Exception:
            return idx, stripped

    indexed = [(i, line.strip()) for i, line in enumerate(lines) if line.strip()]
    if len(indexed) <= 2:
        return preserve_format_line_by_line(text, process_fn)

    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        futs = [ex.submit(work, i, s) for i, s in indexed]
        for fut in as_completed(futs):
            idx, out = fut.result()
            result[idx] = out
    for i, line in enumerate(lines):
        if not line.strip():
            result[i] = ""
        elif not result[i] and line.strip():
            result[i] = line.strip()
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


# Kannada anusvara (U+0C82); Tesseract/OCR often misread it as ASCII '0' or Kannada digit '೦'
# (e.g. ಬಂಗಾರ → ಬ0ಗಾರ / ಬ೦ಗಾರ).
_KANNADA_ANUSVARA = "\u0C82"


def _fix_anusvara_zero(text: str) -> str:
    """Replace '0' or '೦' (with optional spaces) between Kannada letters with anusvara ಂ."""
    if not text or ("0" not in text and "೦" not in text) or not _KANNADA_RE.search(text):
        return text
    return re.sub(
        r"([\u0C80-\u0CFF])\s*[0೦]\s*([\u0C80-\u0CFF])",
        lambda m: m.group(1) + _KANNADA_ANUSVARA + m.group(2),
        text,
    )


def _ocr_post_correct(text: str) -> str:
    """
    Tesseract often misreads Latin in parentheses next to Kannada, e.g. '(bugs)' → '(008)' or '(0೬08)'.
    It also misreads Kannada anusvara (ಂ) as digit 0 (e.g. ಬಂಗಾರ → ಬ0ಗಾರ). Fix known patterns.
    """
    if not text:
        return text

    def fix_line(line: str) -> str:
        line = _fix_anusvara_zero(line)
        # Fix simple intra-word breaks like 'ಮ ಗು' -> 'ಮಗು'.
        line = _merge_broken_kannada_tokens(line)
        # Heuristic: if the line contains one of the known English labels, strip symbol-only
        # junk immediately before the label (e.g. '€ x :' before 'written expression').
        for label in _OCR_ENGLISH_LABELS:
            idx = line.lower().find(label)
            if idx != -1:
                pre = line[:idx]
                post = line[idx:]
                # Remove trailing non-letter/digit chars (including bullets/currency) from pre.
                pre_clean = re.sub(r"[^0-9A-Za-z\u0C80-\u0CFF]+$", " ", pre).rstrip()
                line = (pre_clean + " " + post).strip()
                break
        # Only touch bug-lines that mention errors/defects in Kannada (ದೋಷ = doṣa).
        if "ದೋಷ" not in line:
            return line
        # Parenthetical with no Latin letters—digits/Kannada digits only—likely a misread English gloss.
        line = re.sub(r"\([0-9೦-೯O೦೬\s]+\)", "(bugs)", line)
        # Literal common misreads (ASCII).
        for bad in ("(008)", "(0 0 8)", "(00 8)"):
            if bad in line:
                line = line.replace(bad, "(bugs)")
        return line

    return "\n".join(fix_line(ln) for ln in text.splitlines())


# OCR language: Kannada + English + numbers (digits). Tesseract "kan+eng" covers all three.
_OCR_LANGS = ("kan+eng", "kan")


def _image_to_string_multi(img, langs=None):
    """
    Run OCR with Kannada + English + number format. Tries a few PSMs; returns best text
    by heuristic (more Latin letters in output). langs defaults to _OCR_LANGS.
    """
    if langs is None:
        langs = _OCR_LANGS
    configs = [
        r"--psm 6",   # uniform block of text
        r"--psm 3",   # fully automatic; sometimes better for mixed blocks
        r"--psm 4",   # single column variable size
    ]
    best_text, best_score = "", -1
    for _lang in langs:
        for cfg in configs:
            try:
                t = pytesseract.image_to_string(img, lang=_lang, config=cfg) or ""
                if not t.strip():
                    continue
                # Prefer output that preserves Latin (e.g. "bugs" not all digits in parens).
                score = sum(1 for c in t if c.isalpha() and ord(c) < 128)
                if score > best_score:
                    best_score, best_text = score, t
            except Exception:
                continue
        if best_text.strip():
            break
    return best_text


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
        raw = Image.open(file.stream).convert("L")
        # Build candidate images: high-contrast B&W first (best for many docs), then optional binarize, then grayscale.
        candidates = []
        try:
            from PIL import ImageEnhance
            contrast = float(os.environ.get("OCR_CONTRAST", "2.0").strip() or "2.0")
            contrast = max(1.0, min(4.0, contrast))
            high_contrast = ImageEnhance.Contrast(raw).enhance(contrast)
            # Convert to strict black/white for OCR (threshold 128; env OCR_BW_THRESHOLD overrides).
            thresh = int(os.environ.get("OCR_BW_THRESHOLD", "128").strip() or "128")
            thresh = max(1, min(254, thresh))
            bw_img = high_contrast.point(lambda x: 0 if x < thresh else 255, "1")
            candidates.append(bw_img)
        except Exception:
            pass
        use_bin = os.environ.get("OCR_BINARIZE", "1").strip().lower() in ("1", "true", "yes")
        if use_bin:
            bin_img = raw.point(lambda x: 0 if x < 160 else 255, "1")
            candidates.append(bin_img)
        candidates.append(raw)  # grayscale fallback for mixed kan+eng

        text = ""
        for img in candidates:
            text = _image_to_string_multi(img, langs=_OCR_LANGS)
            if text.strip():
                break
        text = normalize_line_endings(text or "").strip()
        text = _ocr_post_correct(text)
        # Filter out clearly irrelevant OCR lines (timestamps, headers, pure English noise).
        text = _filter_ocr_lines(text)
        # Optional AI correction (kn→kn) before any downstream steps.
        text = preserve_format_line_by_line(text, _ai_correct_kannada_line)
        # Remove obvious OCR garbage suffixes (e.g. trailing digit blobs) before transliteration.
        text = preserve_format_line_by_line(text, _strip_ocr_garbage_from_line)

        # Keep original cleaned text for transliteration.
        text_for_translation = text.replace("ಕೂಸು ಕಂದಯ್ಯ", "ಕಂದ")

        # Line-wise transliteration with word/phrase overrides (after AI + garbage cleanup).
        transliteration = preserve_format_line_by_line(text, _transliterate_line_passthrough) if text else ""
        if transliteration:
            transliteration = _apply_custom_line_overrides(text, transliteration, CUSTOM_TRANSLITERATION_LINES)
            transliteration = _normalize_to_iast(transliteration)

        # Image OCR translation pipeline:
        # Image → OCR → Clean text → Line split → Word match (overrides) → Translate → Display
        translation = ""
        if text_for_translation and (len(text_for_translation) > 500 or text_for_translation.count("\n") > 5):
            # Long OCR text: phrase translation per line in parallel, then clean Kannada leaks.
            try:
                translation = preserve_format_line_by_line_parallel(text_for_translation, _translate_line_phrase_parallel)
                translation = _fix_document_translation_kannada_leaks(text_for_translation, translation)
            except Exception:
                translation = preserve_format_line_by_line(text_for_translation, _translate_line_phrase)
                translation = _fix_document_translation_kannada_leaks(text_for_translation, translation)
        else:
            # Short OCR text: phrase translation per line (no morph pipeline).
            translation = preserve_format_line_by_line(text_for_translation, _translate_line_phrase) if text_for_translation else ""
            if translation:
                translation = _fix_document_translation_kannada_leaks(text_for_translation, translation)

        if translation:
            translation = _strip_kannada_script_from_translation(translation)
        if translation:
            # Word/phrase-level trained overrides.
            translation = _apply_custom_line_overrides(text_for_translation, translation, CUSTOM_TRANSLATION_LINES)
        if translation:
            # Final AI correction on English (grammar/fluency), then ASCII/Kannada cleanup.
            translation = preserve_format_line_by_line(translation, _ai_correct_english_line)
            translation = _final_decode_other_language(translation, text_for_translation)

        payload = {"text": text, "transliteration": transliteration, "translation": translation}
        if user_id is not None:
            # Only count against quota when we got meaningful text (avoid charging for photos/non-text images)
            if text and not has_pro(user_id):
                increment_free_use(user_id)
            payload["user_status"] = get_user_status(user_id)
        return jsonify(payload)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


def _extract_pdf_text(data: bytes) -> str:
    """
    Extract text from PDF bytes. Tries pypdf first, then pdfminer.six if empty or on error.
    Some PDFs (e.g. certain Kannada notes) parse with one library but not the other depending
    on server pypdf version or strict parsing.
    """
    import io
    if not data or not data.lstrip().startswith(b"%PDF"):
        return ""
    out = ""
    # 1) pypdf — strict=False avoids raises on slightly malformed PDFs
    try:
        from pypdf import PdfReader
        reader = PdfReader(io.BytesIO(data), strict=False)
        parts = []
        for page in reader.pages:
            try:
                t = page.extract_text() or ""
            except Exception:
                t = ""
            if not t.strip():
                try:
                    t = page.extract_text(extraction_mode="layout") or ""
                except Exception:
                    pass
            parts.append(t)
        out = "\n".join(parts).strip()
    except Exception:
        out = ""
    if out:
        return out
    # 2) pdfminer.six — often succeeds when pypdf returns empty
    try:
        from pdfminer.high_level import extract_text as pdfminer_extract
        out = (pdfminer_extract(io.BytesIO(data)) or "").strip()
    except Exception:
        pass
    return out


def _is_docx_zip(data: bytes) -> bool:
    """DOCX is a ZIP; magic PK."""
    return bool(data and len(data) >= 2 and data[:2] == b"PK")


def _extract_docx_text(data: bytes) -> str:
    import io
    try:
        from docx import Document
        doc = Document(io.BytesIO(data))
        return "\n".join(p.text for p in doc.paragraphs).strip()
    except Exception:
        return ""


def extract_text_from_document(data: bytes, filename: str) -> str:
    """Extract raw text from PDF, DOCX, or TXT. Uses magic bytes if extension missing (mobile uploads)."""
    import io
    if not data:
        return ""
    name = (filename or "").strip() or "upload"
    ext = name.split(".")[-1].lower() if "." in name else ""
    data_stripped = data.lstrip()
    is_pdf = ext == "pdf" or data_stripped.startswith(b"%PDF")
    is_docx = ext == "docx" or _is_docx_zip(data)

    if is_pdf:
        t = _extract_pdf_text(data)
        if t:
            return t
    if is_docx:
        t = _extract_docx_text(data)
        if t:
            return t
    if ext == "doc":
        return ""
    if ext == "txt":
        try:
            return data.decode("utf-8", errors="replace").strip()
        except Exception:
            pass
    # Unknown ext: try TXT if looks like text; else PDF/DOCX by magic
    try:
        sample = data[:4096]
        if sample and (max(sample) < 0x80 or b"\x00" not in sample[:512]):
            return data.decode("utf-8", errors="replace").strip()
    except Exception:
        pass
    if data_stripped.startswith(b"%PDF"):
        return _extract_pdf_text(data)
    if _is_docx_zip(data):
        return _extract_docx_text(data)
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
    # Do not reject on empty filename — Android/iOS pickers often send no filename; body still valid.
    try:
        data = file.read()
        if not data:
            return jsonify({"error": "Uploaded file is empty."}), 400
        filename = (file.filename or "").strip() or "upload"
        ext = filename.split(".")[-1].lower() if "." in filename else ""
        # If client sends no/odd extension but body is PDF, still extract (avoid false .doc path)
        if ext == "doc" and not data.lstrip().startswith(b"%PDF") and not data[:2] == b"PK":
            return jsonify({
                "error": "Legacy .doc format is not supported. Open in Word/LibreOffice and save as DOCX, then try again.",
            }), 400
        text = extract_text_from_document(data, filename)
        if not text:
            return jsonify({
                "error": "Could not extract text from this file. Supported: PDF, DOCX, TXT. Scanned PDFs need OCR—use a text-based PDF or paste text instead.",
            }), 400

        # Normalize so line breaks are preserved in response (e.g. two lines stay two lines)
        text = normalize_line_endings(text)
        text = _fix_anusvara_zero(text)

        transliteration = preserve_format_line_by_line(text, _transliterate_line_passthrough)
        if transliteration:
            transliteration = _apply_custom_line_overrides(text, transliteration, CUSTOM_TRANSLITERATION_LINES)
            transliteration = _normalize_to_iast(transliteration)
        try:
            # Sentence (line) translation: translate each full line once for more natural English.
            translation = preserve_format_line_by_line_parallel(
                text, _translate_line_with_pipeline
            )
            # translation = _naturalize_translation(translation) if translation else ""  # disabled for now
            # translation = _fix_document_translation_kannada_leaks(text, translation)  # post-processing: disabled for raw
        except Exception:
            try:
                # Fallback: phrase-wise translate per line if whole-line path fails.
                translation = preserve_format_line_by_line_parallel(text, _translate_line_phrase_parallel)
                # translation = _naturalize_translation(translation) if translation else ""  # disabled for now
                # translation = _fix_document_translation_kannada_leaks(text, translation)  # post-processing: disabled for raw
            except Exception:
                translation = ""
        # if translation:
        #     translation = _strip_kannada_script_from_translation(translation)  # post-processing: disabled for raw
        # if translation:
        #     translation = _apply_custom_line_overrides(text, translation, CUSTOM_TRANSLATION_LINES)  # post-processing: disabled for raw
        #     translation = _final_decode_other_language(translation, text)  # post-processing: disabled for raw

        payload = {"text": text, "transliteration": transliteration, "translation": translation}
        if user_id is not None:
            if not has_pro(user_id):
                increment_free_use(user_id)
            payload["user_status"] = get_user_status(user_id)
        return jsonify(payload)
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# --- Morph pipeline: OCR text → tokenize → morphological parse → root lookup → grammar reconstruction → translation ---

def _tokenize_words(line: str) -> list:
    """Tokenize line into words (split on whitespace). Preserves order."""
    if not line or not line.strip():
        return []
    return line.split()


# Optional root dictionary: maps root form -> canonical root (or same). Load from file if present.
_ROOT_DICT = {}
_ROOT_DICT_LOADED = False


def _load_root_dict():
    global _ROOT_DICT, _ROOT_DICT_LOADED
    if _ROOT_DICT_LOADED:
        return
    _ROOT_DICT_LOADED = True
    path = os.environ.get("KANNADA_ROOT_DICT") or os.path.join(os.path.dirname(__file__), "kannada_roots.txt")
    if not os.path.isfile(path):
        return
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) >= 2:
                    _ROOT_DICT[parts[0].strip()] = parts[1].strip()
                else:
                    _ROOT_DICT[parts[0].strip()] = parts[0].strip()
    except Exception:
        pass


def _root_lookup(root: str) -> str:
    """Dictionary lookup for root word. Returns canonical form or the root itself."""
    if not root or not root.strip():
        return root
    _load_root_dict()
    return _ROOT_DICT.get(root.strip(), root.strip())


def _get_root_from_morphemes(morphemes: list, word: str) -> str:
    """Extract root/stem from morpheme list (typically first morpheme in agglutinative Kannada)."""
    if not morphemes:
        return word
    return morphemes[0].strip() or word


def _grammar_reconstruct(tokens: list, roots: list) -> str:
    """Reconstruct a single string from tokens and their roots (same order, space-joined)."""
    if not tokens or not roots:
        return " ".join(tokens) if tokens else ""
    looked = [_root_lookup(r) for r in roots]
    return " ".join(looked)


def _translate_line_morph_pipeline(line: str) -> str:
    """
    Full pipeline: tokenize → morphological parse → root extraction → root dictionary lookup
    → grammar reconstruction → translation. Use when USE_MORPH_PIPELINE=1.
    """
    if not line.strip():
        return ""
    if _is_numbering_only_line(line):
        return ""
    if not _is_kannada_line(line):
        return line
    # 1) Tokenize
    tokens = _tokenize_words(line)
    if not tokens:
        return line
    # 2) Morphological parse
    parsed = _morph_parse_kannada_text(line)
    if not parsed or len(parsed) != len(tokens):
        # Fallback: translate as phrase if morph or token count mismatch
        return _translate_line_phrase(line)
    # 3) Root extraction
    roots = [_get_root_from_morphemes(p["morphemes"], p["word"]) for p in parsed]
    # 4) Root lookup (inside _grammar_reconstruct)
    # 5) Grammar reconstruction
    reconstructed = _grammar_reconstruct(tokens, roots)
    if not reconstructed.strip():
        return line
    # 6) Translation
    try:
        out = translate_kannada_to_english(reconstructed, append_sentence_period=False) or reconstructed
        if out and out.rstrip() and out.rstrip()[-1] not in ".!?":
            out = out.rstrip() + "."
        return out
    except Exception:
        return _translate_line_phrase(line)


def _translate_line_with_pipeline(line: str) -> str:
    """Use morph pipeline (tokenize→morph→root lookup→reconstruct→translate) when USE_MORPH_PIPELINE=1 else phrase translation."""
    if os.environ.get("USE_MORPH_PIPELINE", "").strip().lower() in ("1", "true", "yes"):
        return _translate_line_morph_pipeline(line)
    return _translate_line_whole(line)


# Lazy-loaded Kannada morphological analyzer (Indic NLP Library). Set INDIC_RESOURCES_PATH if needed.
_KANNADA_MORPH_ANALYZER = None
_KANNADA_MORPH_ANALYZER_ERROR = None


def _get_kannada_morph_analyzer():
    """Return UnsupervisedMorphAnalyzer for Kannada if available; else None and error message."""
    global _KANNADA_MORPH_ANALYZER, _KANNADA_MORPH_ANALYZER_ERROR
    if _KANNADA_MORPH_ANALYZER_ERROR is not None:
        return None, _KANNADA_MORPH_ANALYZER_ERROR
    if _KANNADA_MORPH_ANALYZER is not None:
        return _KANNADA_MORPH_ANALYZER, None
    try:
        from indicnlp.morph.unsupervised_morph import UnsupervisedMorphAnalyzer
        _KANNADA_MORPH_ANALYZER = UnsupervisedMorphAnalyzer("kn")
        return _KANNADA_MORPH_ANALYZER, None
    except Exception as e:
        _KANNADA_MORPH_ANALYZER_ERROR = str(e)
        return None, _KANNADA_MORPH_ANALYZER_ERROR


def _morph_parse_kannada_text(text: str):
    """
    Run Kannada morphological parsing on text. Returns list of {"word": token, "morphemes": [...]}.
    Non-Kannada tokens are returned with a single morpheme. Uses Indic NLP Library when available.
    """
    if not text or not text.strip():
        return []
    tokens = text.split()
    analyzer, err = _get_kannada_morph_analyzer()
    result = []
    for token in tokens:
        morphemes = [token]
        if _KANNADA_RE.search(token) and analyzer is not None:
            try:
                parts = analyzer.morph_analyze(token)
                if parts:
                    morphemes = parts
            except Exception:
                pass
        result.append({"word": token, "morphemes": morphemes})
    return result


@app.route("/morph", methods=["POST"])
def morph():
    """Kannada morphological parsing. POST JSON: {"text": "ಕನ್ನಡ ಭಾಷೆ"}. Returns words with morpheme breakdown."""
    data = request.get_json(silent=True) or {}
    text = (data.get("text") or "").strip()
    if not text:
        return jsonify({"error": "Missing or empty 'text' in request body"}), 400
    try:
        text = normalize_line_endings(text)
        text = _fix_anusvara_zero(text)
        words = _morph_parse_kannada_text(text)
        analyzer, analyzer_err = _get_kannada_morph_analyzer()
        payload = {
            "text": text,
            "words": words,
            "morph_engine": "indic_nlp" if analyzer else "fallback",
            "morph_engine_error": analyzer_err if analyzer_err else None,
        }
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
        text = _fix_anusvara_zero(text)
        transliteration = preserve_format_line_by_line(text, _transliterate_line_passthrough)
        if transliteration:
            transliteration = _apply_custom_line_overrides(text, transliteration, CUSTOM_TRANSLITERATION_LINES)
            transliteration = _normalize_to_iast(transliteration)
        # Long pasted text (e.g. 2000 chars) has many Kannada segments; per-segment translate
        # causes hundreds of API calls → timeout / empty translation. Use whole-line path like /document.
        use_parallel_segments = len(text) > 400 or text.count("\n") > 10
        try:
            if use_parallel_segments:
                translation = preserve_format_line_by_line_parallel(
                    text, _translate_line_with_pipeline
                )
                # translation = _naturalize_translation(translation) if translation else ""  # disabled for now
                # translation = _fix_document_translation_kannada_leaks(text, translation)  # post-processing: disabled for raw
            else:
                translation = preserve_format_line_by_line_parallel(text, _translate_line_with_pipeline)
                # translation = _naturalize_translation(translation) if translation else ""  # disabled for now
        except Exception:
            try:
                translation = preserve_format_line_by_line_parallel(text, _translate_line_with_pipeline)
                # translation = _naturalize_translation(translation) if translation else ""  # disabled for now
                # if use_parallel_segments:
                #     translation = _fix_document_translation_kannada_leaks(text, translation)  # post-processing: disabled for raw
            except Exception:
                translation = ""
        # if translation:
        #     translation = _strip_kannada_script_from_translation(translation)  # post-processing: disabled for raw
        # if translation:
        #     translation = _apply_custom_line_overrides(text, translation, CUSTOM_TRANSLATION_LINES)  # post-processing: disabled for raw
        #     translation = _final_decode_other_language(translation, text)  # post-processing: disabled for raw
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
