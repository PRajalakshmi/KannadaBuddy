# Is KannadaBuddy Play Store ready?

**Short answer:** Almost. The app and backend are in good shape; you need to finish **signing**, **AdMob production IDs**, and **Play Console setup** (listing, privacy URL, data safety, content rating, ads declaration, subscription).

---

## ✅ Already in place

| Item | Status |
|------|--------|
| App name | KannadaBuddy (manifest, iOS, web) |
| Default API URL | `https://kannada.astrostarveda.com` (production) |
| Privacy & terms text | In-app content in `lib/content/legal_content.dart` |
| Subscription product ID | `kannadabuddy_pro_monthly` in code and docs |
| Free tier | 5 free image/document uses, then upgrade |
| Ads (free users) | Banner shown for non-subscribers; hidden for Pro |
| User-facing errors | Friendly message only; real errors logged with `[KannadaBuddy OCR error]` |
| No secrets in repo | API URL overridable via `--dart-define=OCR_BASE_URL=...` |

---

## ❌ Must do before publishing

### 1. Release signing (required for upload)

Right now the release build uses **debug** signing. Play requires an **upload key**.

- Create a keystore and configure release signing in `android/app/build.gradle.kts`.
- See: [Flutter – Signing the app](https://docs.flutter.dev/deployment/android#signing-the-app).

Without this, you cannot upload an AAB to Play Console.

### 2. AdMob production IDs (required if you keep ads)

The app currently uses **Google test** AdMob IDs. For production:

- Create an app in [AdMob](https://admob.google.com) and get your **Android** and **iOS** App IDs.
- Create **banner** ad units and get the ad unit IDs.
- Replace in:
  - `android/app/src/main/AndroidManifest.xml` → `com.google.android.gms.ads.APPLICATION_ID`
  - `ios/Runner/Info.plist` → `GADApplicationIdentifier`
  - `lib/main.dart` → `_HomeAdBannerState._bannerAdUnitId` (Android and iOS IDs).

If you don’t replace these, you stay on test ads (policy risk if you publish as-is).

### 3. Application ID (recommended)

Package name is still `com.example.kanndabuddy`. For a real product, use your own (e.g. `com.astrostarveda.kannadabuddy`). Changing it later is difficult, so do it before the first upload.

- Update `applicationId` and `namespace` in `android/app/build.gradle.kts`.
- Update package and paths in `android/app/src/main/kotlin/...` to match.
- Use the same package name when creating the app in Play Console.

### 4. Play Console (required)

All of these are in the Play Console, not in code:

| Task | Where |
|------|--------|
| Create app (match application ID) | Dashboard |
| Store listing (short/full description, icon 512×512, screenshots, category, contact email) | Grow → Main store listing |
| Privacy policy **URL** (host the policy text and paste URL here) | Policy → App content → Privacy policy |
| Data safety form (data types, purpose, ephemeral/not stored) | Policy → App content → Data safety |
| Declare **ads** (Yes; app uses AdMob for free users) | Policy → App content |
| Content rating (e.g. IARC questionnaire) | Policy → App content |
| Target audience / age group | Policy → App content |
| Subscription `kannadabuddy_pro_monthly` (create, set price e.g. ₹99/month, activate) | Monetize → Subscriptions |
| Upload AAB (after signing + build) | Release → Internal testing, then Production |
| License testers (for IAP testing) | Setup → License testing |

Details: see **PLAY_CONSOLE.md**.

---

## Optional but recommended

- **Cleartext traffic:** Default API is HTTPS. You can set `android:usesCleartextTraffic="false"` in `AndroidManifest.xml` for release to block HTTP.
- **Internal test:** Upload to **Internal testing** first, install via the Play link, and test IAP + ads before going to Production.

---

## Build and upload (after signing is set)

```bash
flutter clean && flutter pub get
flutter build appbundle --dart-define=OCR_BASE_URL=https://kannada.astrostarveda.com
```

Upload `build/app/outputs/bundle/release/app-release.aab` in Play Console → Release → your track.

---

## Summary

| Blocking? | Item |
|-----------|------|
| **Yes** | Release signing (keystore + build.gradle.kts) |
| **Yes** | Play Console: store listing, privacy policy URL, data safety, content rating, ads declaration, subscription |
| **Yes** | AdMob production App ID + ad unit IDs (or remove ads) |
| **Recommended** | Own application ID (e.g. com.yourcompany.kannadabuddy) |

Once signing is configured, AdMob IDs are production, and the Play Console checklist is done, you’re ready to submit for review.
