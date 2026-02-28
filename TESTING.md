# Testing KannadaBuddy

## 0. Automated test suite

### Flutter (unit and widget tests)

From the project root:

```bash
flutter pub get
flutter test
```

This runs:

- **`test/ocr_result_test.dart`** – `OcrResult` model (fields, defaults).
- **`test/app_config_test.dart`** – App config (e.g. `ocrBaseUrl` non-empty, valid URL).
- **`test/ocr_service_test.dart`** – `OCRService.submitKannadaText` (parsing JSON, error handling) with mocked HTTP.
- **`test/iap_service_test.dart`** – Subscription product ID constant.
- **`test/widget_test.dart`** – App launches, home shows “KannadaBuddy” and “Get transliteration & translation”.

### Server (Python API tests)

From the `server/` directory:

```bash
cd server
pip install -r requirements.txt
pip install pytest   # if not already installed
python -m pytest tests/ -v
```

This runs:

- **`tests/test_app.py`** – `/text` (missing/empty body → 400, valid JSON → 200 and keys), `/ocr` and `/document` (no file → 400), and helper functions (`normalize_line_endings`, `preserve_format_line_by_line`).

Note: `test_text_valid_returns_200_and_keys` calls the real transliteration/translation; it may hit the network and require dependencies (e.g. `indic_transliteration`, `deep_translator`).

---

## 1. Testing the upgrade flow (no real payment)

You can test the **entire upgrade flow** (free limit, upgrade screen, Copy/Share gating) **without** setting up real in-app products.

### How it works

- Run the app in **debug** mode (e.g. `flutter run` or Run in IDE).
- When the **store is unavailable** (emulator, or no product configured), tapping **Subscribe** still **grants Pro** and closes the upgrade screen so you can verify the rest of the app.
- So you can:
  - Use gallery/document until you hit the free limit → upgrade screen appears.
  - Tap **Subscribe** → Pro is granted, upgrade screen closes, free-attempts label disappears, Copy/Share work.
  - Or tap **Maybe later** → upgrade screen closes without granting Pro.

### Reset and repeat

- **Android:** Settings → Apps → KannadaBuddy → Storage → **Clear data** (or uninstall and reinstall).
- **iOS:** Delete the app and reinstall, or clear app data if available.
- This resets the free-use count and the “has upgraded” flag so you can test again.

---

## 2. Testing real in-app purchase (Android)

1. **Create the product in Play Console**
   - [Google Play Console](https://play.google.com/console) → Your app → **Monetize** → **Subscriptions**.
   - Create a subscription with product ID: **`kannadabuddy_pro_monthly`**.
   - Set price (e.g. ₹99/month) and save.

2. **Upload a build**
   - Build an app bundle:  
     `flutter build appbundle`
   - Upload it to the **Internal testing** track (or Closed testing).

3. **Add license testers**
   - Play Console → **Setup** → **License testing**.
   - Add the **Gmail** accounts that will test. These accounts can “purchase” without being charged.

4. **Install and test**
   - Install the app from the Internal testing track (link from Play Console) on a **real device** (same Google account as a license tester).
   - Open the upgrade screen and tap **Subscribe**. Complete the test purchase (you won’t be charged).
   - Tap **Restore purchases** to verify restore works (e.g. after reinstalling).

---

## 3. Testing real in-app purchase (iOS)

1. **Create the product in App Store Connect**
   - [App Store Connect](https://appstoreconnect.apple.com) → Your app → **Subscriptions**.
   - Create a subscription group and a subscription with product ID: **`kannadabuddy_pro_monthly`**.

2. **Add Sandbox testers**
   - App Store Connect → **Users and Access** → **Sandbox** → **Testers**.
   - Create a Sandbox Apple ID (or use an existing one).

3. **Run on device**
   - Build and run on a **real device** (IAP does not complete in Simulator):  
     `flutter run` or archive and install via Xcode.
   - On the device: **Settings → App Store → Sandbox Account** and sign in with the Sandbox tester.
   - Open the app, go to the upgrade screen, tap **Subscribe**. Use the Sandbox account when prompted; you won’t be charged.

4. **Restore**
   - Tap **Restore purchases** and confirm that Pro is restored.

---

## 4. Quick checklist

| What to test              | How |
|---------------------------|-----|
| Free limit (e.g. 5 uses)  | Use gallery/document 5 times; 6th time should show upgrade screen. |
| Subscribe (debug, no IAP) | Run debug build, tap Subscribe with store unavailable → Pro granted. |
| Maybe later               | Tap Maybe later → upgrade screen closes, no Pro. |
| Copy/Share without Pro    | On Results, tap Copy or Share → upgrade screen. |
| Copy/Share with Pro       | After subscribing (or clearing data and using debug Subscribe), Copy/Share work. |
| Restore purchases         | After a real (sandbox/license) purchase, reinstall and tap Restore → Pro restored. |
| Reset for next test       | Clear app data or uninstall/reinstall. |
