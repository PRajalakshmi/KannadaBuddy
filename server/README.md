# Kannada OCR server (with transliteration & translation)

## First-time setup

1. Create and activate the virtual environment (already done if you ran the install):

   ```bash
   cd server
   python3 -m venv venv
   source venv/bin/activate   # on Windows: venv\Scripts\activate
   pip install -r requirements.txt
   ```

2. Install Tesseract with Kannada and put `kan.traineddata` in Tesseract's `tessdata` folder.

## Run the server

From the **server** folder, activate the venv then start the app:

```bash
cd /Users/Raji/Documents/GitHub/kanndabuddy/server
source venv/bin/activate
python app.py
```

Server will be at `http://0.0.0.0:5001`. Use your Mac's LAN IP (e.g. `http://192.168.1.16:5001`) in the Flutter app.

## Translation (Kannada → English)

The server uses **Google Translate** first, then **MyMemory** as fallback if the result is empty or clearly wrong. To fix recurring mistranslations, edit `app.py` and add entries to `TRANSLATION_GLOSSARY`, e.g.:

```python
TRANSLATION_GLOSSARY = {
    "skool": "school",
    "wrong phrase": "correct phrase",
}
```
