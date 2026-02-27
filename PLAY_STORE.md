# Play Store readiness

## Hardcoding and config

| Item | Location | Status |
|------|----------|--------|
| **OCR server URL** | Was hardcoded in `lib/services/ocr_service.dart` | **Configurable** via `lib/config/app_config.dart`. Set for release: `flutter build appbundle --dart-define=OCR_BASE_URL=https://your-api.com` |
| **Subscription price** | `lib/main.dart` | Single constants `kSubscriptionPrice` and `kSubscriptionPeriod` (e.g. ₹99, month). Change there for updates. |
| **Free attempt limit** | `lib/main.dart` | `_kFreeUseLimit = 2`. Change there if you change the free tier. |

No API keys or secrets are stored in the repo. The app talks to your own backend; use HTTPS in production.

## Before submitting to Play Store

1. **Backend**  
   Deploy the Python server (`server/`) to a public HTTPS URL. Build the app with that URL:
   ```bash
   flutter build appbundle --dart-define=OCR_BASE_URL=https://your-production-api.com
   ```

2. **Signing**  
   In `android/app/build.gradle.kts`, replace the release `signingConfig` with your upload key (see [Android signing](https://docs.flutter.dev/deployment/android#signing-the-app)).

3. **Application ID**  
   Change `applicationId` in `android/app/build.gradle.kts` from `com.example.kanndabuddy` to your own (e.g. `com.yourcompany.kanndabuddy`).

4. **App name**  
   Update `android:label` in `android/app/src/main/AndroidManifest.xml` (e.g. "KannadaBuddy").

5. **Privacy policy**  
   Play Store requires a privacy policy URL if the app handles user data (e.g. images/documents sent to your server). Host a policy and add the URL in Play Console.

6. **In-app purchase**  
   The app uses the [in_app_purchase](https://pub.dev/packages/in_app_purchase) package. Subscribe and Restore are wired to the store. Create a **subscription** product with ID **`kannadabuddy_pro_monthly`** in [Google Play Console](https://play.google.com/console) (Subscriptions) and in [App Store Connect](https://appstoreconnect.apple.com) (Subscriptions). Price it at ₹99/month (or equivalent). In debug builds, if the store is unavailable, Subscribe still grants access for testing.

7. **Cleartext traffic**  
   `android:usesCleartextTraffic="true"` is set so HTTP works in dev. For production, use HTTPS and you can set this to `false` if you want to block HTTP.

## Summary

- **No hardcoded secrets.**  
- **Server URL** is configurable via `--dart-define=OCR_BASE_URL=...`.  
- **Price and free limit** are single constants in `main.dart`.  
- **Manifest** was fixed so `usesCleartextTraffic` is correctly inside `<application>`.  
- To be **fully Play Store ready**, deploy your backend, use release signing, set your app ID and name, add a privacy policy, and optionally wire real IAP.
