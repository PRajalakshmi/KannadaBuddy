# Kannada OCR server (with transliteration & translation)

## First-time setup

1. **Install Tesseract OCR** (required; `pytesseract` is only a wrapper around the Tesseract binary).

   **Ubuntu / Debian:**
   ```bash
   sudo apt update
   sudo apt install -y tesseract-ocr tesseract-ocr-kan
   ```
   Verify: `tesseract --version` and `tesseract --list-langs` should include `kan`.

   **CentOS / RHEL / Amazon Linux:**
   ```bash
   sudo yum install -y tesseract tesseract-langpack-kan
   # or: sudo amazon-linux-extras install epel && sudo yum install -y tesseract tesseract-langpack-kan
   ```

   **macOS:** `brew install tesseract tesseract-lang`

   **Windows:** Download installer from [GitHub tesseract](https://github.com/UB-Mannheim/tesseract/wiki) and add Tesseract to your PATH. Download `kan.traineddata` and place it in `TESSDATA_PREFIX` (e.g. `C:\Program Files\Tesseract-OCR\tessdata`).

   If you get **"Tesseract is not installed or not in your path"**, the binary is missing or not on PATH; fix the install above and ensure `tesseract` runs in a terminal.

2. Create and activate the virtual environment:

   ```bash
   cd server
   python3 -m venv venv
   source venv/bin/activate   # on Windows: venv\Scripts\activate
   pip install -r requirements.txt
   ```

## Run the server

From the **server** folder, activate the venv then start the app:

```bash
cd /Users/Raji/Documents/GitHub/kanndabuddy/server
source venv/bin/activate
python app.py
```

Server will be at `http://0.0.0.0:5001`. Use your machine’s IP and this port in the Flutter app (see `lib/config/app_config.dart`).

## Running on an external server

When you run **app.py on an external server** (VPS, cloud VM, etc.) so the Flutter app can reach it over the internet:

1. **Start the server** on that machine (with venv activated):
   ```bash
   cd server
   source venv/bin/activate
   python app.py
   ```
   By default it listens on **port 5001**. To use another port (e.g. 8001), change the last line in `app.py` to:
   ```python
   app.run(host="0.0.0.0", port=8001, debug=True)
   ```

2. **Open the port** in the server’s firewall (e.g. allow 5001 or 8001). On Linux with ufw:
   ```bash
   sudo ufw allow 5001
   sudo ufw reload
   ```

3. **Set the same URL in the app**: in the Flutter project, `lib/config/app_config.dart` must use your server’s **public IP or domain** and the **same port** (e.g. `http://31.97.236.62:5001` or `http://your-server.com:8001`). Rebuild the app after changing.

4. **Optional (production):** Run with **gunicorn** instead of the built-in server, and put **nginx** in front with HTTPS:
   ```bash
   pip install gunicorn
   gunicorn -w 1 -b 0.0.0.0:5001 app:app
   ```
   Then in the app use `https://your-domain.com` if nginx serves HTTPS on 443.

## Translation (Kannada → English)

The server uses **Google Translate** first, then **MyMemory** as fallback if the result is empty or clearly wrong. To fix recurring mistranslations, edit `app.py` and add entries to `TRANSLATION_GLOSSARY`, e.g.:

```python
TRANSLATION_GLOSSARY = {
    "skool": "school",
    "wrong phrase": "correct phrase",
}
```
