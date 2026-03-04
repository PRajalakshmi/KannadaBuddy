# Fix Google Sign-In: ApiException 10 (DEVELOPER_ERROR)

**Error:** `PlatformException(Signin failed, com.google.android.gms.common.api.ApiException: 10:, null, null)`

**Cause:** ApiException **10** means **DEVELOPER_ERROR** — your app’s **SHA-1 fingerprint** is not registered in Google Cloud (or Firebase), or the Android OAuth client is missing/misconfigured.

---

## 1. Get your app’s SHA-1

### Option A – Gradle (recommended)

From the project root:

```bash
cd android && ./gradlew signingReport
```

In the output, find **Variant: debug** and **Variant: release** and copy the **SHA1** value(s). You need at least the **debug** SHA-1 for development.

### Option B – Android Studio

1. Open **Android Studio** → open the **android** folder of this project.
2. **Gradle** panel (right) → **android** → **Tasks** → **android** → double‑click **signingReport**.
3. In the **Run** window, find **SHA1** under the **debug** (and **release** if needed) configuration.

### Option C – keytool (debug keystore)

Debug keystore is usually at `~/.android/debug.keystore`:

```bash
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
```

Copy the **SHA1** line.

---

## 2. Create / use a Google Cloud project

1. Go to [Google Cloud Console](https://console.cloud.google.com/).
2. Create a project or select the one you use for this app.
3. **APIs & Services** → **Credentials**.

---

## 3. Add Android OAuth client with SHA-1

1. **Credentials** → **+ CREATE CREDENTIALS** → **OAuth client ID**.
2. If asked, configure the **OAuth consent screen** (e.g. External, add your email as test user).
3. Application type: **Android**.
4. **Name:** e.g. `KannadaBuddy Android`.
5. **Package name:** must match your app exactly:
   ```text
   com.example.kanndabuddy
   ```
   (Same as in `android/app/build.gradle.kts` → `applicationId`.)
6. **SHA-1 certificate fingerprint:** paste the **SHA1** you got in step 1 (debug for local runs, add release when you build release/Play Store).
7. Click **Create**.

Keep this client for Android; you can also create a **Web application** client later if your backend verifies ID tokens (then use that Web client ID in `server` env `GOOGLE_CLIENT_ID`).

---

## 4. (Optional) Use Firebase instead

If you prefer Firebase:

1. [Firebase Console](https://console.firebase.google.com/) → Add/select project → Add **Android** app.
2. **Package name:** `com.example.kanndabuddy`.
3. **Debug signing certificate SHA-1:** paste the same SHA-1 from step 1.
4. Download **google-services.json** and put it in:
   ```text
   android/app/google-services.json
   ```
5. In the project root `android/build.gradle.kts` (or `android/build.gradle`), add the Google services plugin if not already there; in `android/app/build.gradle.kts` apply it and sync.

Firebase will create an Android OAuth client with that SHA-1; Google Sign-In will then work as long as the package name matches.

---

## 5. Double-check

- **Package name** in Google Cloud (or Firebase) = `com.example.kanndabuddy`.
- **SHA-1** in the Android OAuth client = the one from your **debug** keystore (for `flutter run` / debug builds).
- If you already created an Android client before adding SHA-1, edit it and add the SHA-1, or create a new Android client with the correct SHA-1 and package name.
- Uninstall the app from the device/emulator and run again:
  ```bash
  flutter clean && flutter pub get && flutter run
  ```

---

## 6. Release / Play Store builds

For **release** or **Google Play** builds:

- Add the **release** keystore SHA-1 (from `signingReport` for release or from your release keystore) to the same Android OAuth client (or a second Android client with the same package name).
- If the app is signed by **Google Play App Signing**, add the **App signing key certificate** SHA-1 from **Play Console → Your app → Setup → App signing** to your Google Cloud Android OAuth client (or Firebase).

After the correct SHA-1 and package name are set, ApiException 10 should go away and Sign in with Google should succeed.
