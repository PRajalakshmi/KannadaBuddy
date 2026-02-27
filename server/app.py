"""
Kannada OCR server with transliteration (Kannada -> Latin) and translation (Kannada -> English).
Run: pip install -r requirements.txt && python app.py
"""
from flask import Flask, request, jsonify
from PIL import Image
import pytesseract

app = Flask(__name__)


def transliterate_kannada_to_latin(text: str) -> str:
    """Convert Kannada script to Latin (IAST)."""
    if not text or not text.strip():
        return ""
    try:
        from indic_transliteration.sanscript import transliterate
        return transliterate(text.strip(), "kannada", "iast")
    except Exception:
        return ""


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


@app.route("/ocr", methods=["POST"])
def ocr():
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
        text = normalize_line_endings(text or "")

        transliteration = preserve_format_line_by_line(text, transliterate_kannada_to_latin) if text else ""
        translation = preserve_format_line_by_line(text, translate_kannada_to_english) if text else ""

        return jsonify({
            "text": text,
            "transliteration": transliteration,
            "translation": translation,
        })
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

        transliteration = preserve_format_line_by_line(text, transliterate_kannada_to_latin)
        translation = preserve_format_line_by_line(text, translate_kannada_to_english)

        return jsonify({
            "text": text,
            "transliteration": transliteration,
            "translation": translation,
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/text", methods=["POST"])
def text():
    """Accept plain Kannada text (JSON body: {"text": "..."}) and return transliteration + translation."""
    data = request.get_json(silent=True) or {}
    text = (data.get("text") or "").strip()
    if not text:
        return jsonify({"error": "Missing or empty 'text' in request body"}), 400
    try:
        text = normalize_line_endings(text)
        transliteration = preserve_format_line_by_line(text, transliterate_kannada_to_latin)
        translation = preserve_format_line_by_line(text, translate_kannada_to_english)
        return jsonify({
            "text": text,
            "transliteration": transliteration,
            "translation": translation,
        })
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001, debug=True)
