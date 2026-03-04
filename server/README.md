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

On first run, a SQLite DB file `kannada_buddy.db` is created in the server folder. It stores **users** (Google ID, email, free-use count) and **subscriptions** (user ID, purchase token, platform). All OCR/document/text requests require the **X-User-Id** header (obtained after the app signs in with Google via `POST /auth/google`). Optional: set **GOOGLE_CLIENT_ID** (e.g. Android client ID from Firebase) to verify Google ID tokens; otherwise the server accepts `google_id` + `email` in the auth request body for development.

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

### Fix "Server error (404)" when app calls the backend

If the app shows **Server error (404)** when signing in or using OCR, the request is reaching your server but **not** your Flask app. That usually means:

- You use a **domain** like `https://kannada.astrostarveda.com` (no port). Traffic on 443 is handled by **nginx** (or Apache), which is returning 404 because it does not forward these paths to app.py.

**Option A – Use the port in the app URL (quick test)**  
Point the app at Flask directly with the port:

- In `lib/config/app_config.dart` set the URL to `https://kannada.astrostarveda.com:5001` (or `http://...` if you don’t have HTTPS on 5001).
- Ensure port 5001 is open and app.py (or gunicorn) is listening on `0.0.0.0:5001`.

**Option B – Proxy from nginx to Flask (recommended for production)**  
Keep the app URL as `https://kannada.astrostarveda.com` (no port). Configure nginx to forward API requests to Flask:

1. Run Flask (or gunicorn) on a local port, e.g. **5001**:  
   `gunicorn -w 1 -b 127.0.0.1:5001 app:app`
2. In your nginx server block for `kannada.astrostarveda.com`, add:

   ```nginx
   location /auth/ {
       proxy_pass http://127.0.0.1:5001;
       proxy_set_header Host $host;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_set_header X-Forwarded-Proto $scheme;
   }
   location /user/ {
       proxy_pass http://127.0.0.1:5001;
       proxy_set_header Host $host;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_set_header X-Forwarded-Proto $scheme;
   }
   location /ocr {
       proxy_pass http://127.0.0.1:5001;
       proxy_set_header Host $host;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_set_header X-Forwarded-Proto $scheme;
       client_max_body_size 10M;
   }
   location /document {
       proxy_pass http://127.0.0.1:5001;
       proxy_set_header Host $host;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_set_header X-Forwarded-Proto $scheme;
       client_max_body_size 20M;
   }
   location /text {
       proxy_pass http://127.0.0.1:5001;
       proxy_set_header Host $host;
       proxy_set_header X-Real-IP $remote_addr;
       proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       proxy_set_header X-Forwarded-Proto $scheme;
   }
   ```

3. Reload nginx: `sudo nginx -t && sudo systemctl reload nginx`

Then `https://kannada.astrostarveda.com/auth/google` will be served by Flask and the 404 will go away.

### After you've deployed: what to do next

1. **Point the Flutter app at your server**  
   Edit `lib/config/app_config.dart` and set the `defaultValue` to your server URL (e.g. `https://kannada.astrostarveda.com` with no trailing slash). Or build with:  
   `flutter build appbundle --dart-define=OCR_BASE_URL=https://your-domain.com`  
   Use **https** if your server is behind HTTPS. Rebuild the app after changing.

2. **Keep the server running**  
   Use a process manager (e.g. systemd, supervisor) or gunicorn + nginx so the app and DB stay up across reboots.

3. **Database**  
   `kannada_buddy.db` is created on first run. Ensure the process has write permission to the server directory (or set `KANNADA_DB_PATH`). Back it up if you need to keep user/subscription data.

4. **Google Sign-In (optional)**  
   To verify ID tokens on the server, set env `GOOGLE_CLIENT_ID` to your Android OAuth client ID (from Firebase/Google Cloud). Without it, the server still works using `google_id` + `email` from the app.

5. **Smoke test**  
   Install the app, sign in with Google, then use gallery/document or type Kannada and tap the translate button. If results load, the app is talking to your deployed server.

## Translation (Kannada → English)

The server uses **Google Translate** first, then **MyMemory** as fallback if the result is empty or clearly wrong. To fix recurring mistranslations, edit `app.py` and add entries to `TRANSLATION_GLOSSARY`, e.g.:

```python
TRANSLATION_GLOSSARY = {
    "skool": "school",
    "wrong phrase": "correct phrase",
}
```
