# Google Play Console – Next steps after registration

Use this checklist to publish **KannadaBuddy** on Google Play.

---

## 1. Create your app in Play Console

- In [Google Play Console](https://play.google.com/console), click **Create app** (if you haven’t already).
- Fill in **App name**, **Default language**, and accept declarations.
- **Application ID (package name):** Must match your Android app.  
  Current value in the project: **`com.example.kanndabuddy`** (in `android/app/build.gradle.kts`).  
  If you created the Play Console app with a different package name, either:
  - Create a new app in Play Console with `com.example.kanndabuddy`, or  
  - Change the app’s `applicationId` in `build.gradle.kts` to match the one you used in Play Console (and use that package name everywhere).

---

## 2. Store listing (main store listing)

**Dashboard → Your app → Grow → Main store listing**

- **Short description** (up to 80 characters): e.g. *Kannada to English: transliterate and translate text, images & documents.*
- **Full description** (up to 4000 characters): Explain features (gallery, document, typed Kannada, transliteration, translation, Summary tab, Copy/Share, Pro subscription).
- **App icon:** 512×512 PNG (you have `assets/icon/kannadabuddy_logo_redesign.png` – resize if needed).
- **Feature graphic:** 1024×500 PNG (optional but recommended).
- **Screenshots:** At least 2 (phone); add 7″ and 10″ if you target tablets.
- **Category:** e.g. Education or Books & Reference.
- **Contact email:** e.g. **kannadabuddya@gmail.com** (same as in-app).

---

## 3. Privacy and data safety

**Policy → App content → Privacy policy**

- **Privacy policy URL** is required. You must host your privacy policy on a public URL (e.g. GitHub Pages, your website, or a privacy policy generator).
- Use the same text as in the app (see `lib/content/legal_content.dart` – `kPrivacyPolicyBody`). Paste it into a simple HTML or Markdown page and publish it, then add that URL in Play Console.

**Policy → App content → Data safety**

- Complete the **Data safety** form:
  - Does your app collect or share user data? **Yes** (e.g. “App functionality” – data sent for transliteration/translation).
  - Data types: e.g. “Other in-app user-generated content” (Kannada text/images), “Device or other IDs” if you use any.
  - Purpose: e.g. **App functionality**.
  - Is data ephemeral (not stored)? **Yes** for the text/images you process and don’t store.
  - Optional: “Data is not shared with third parties” (or describe if you use e.g. translation APIs).
- This should match your in-app **Data safety** and **Privacy policy** text.

---

## 4. In-app subscription (monetization)

**Monetize → Subscriptions (or Products)**

- Create a **subscription** with product ID: **`kannadabuddy_pro_monthly`** (must match `lib/services/iap_service.dart`).
- Set price (e.g. ₹99/month), billing period, and free trial / grace period if you want.
- Activate the subscription.

**Monetize → Monetization setup**

- Complete any required setup (e.g. accept agreements, set up merchant account if not done).

---

## 5. Content rating and other declarations

**Policy → App content**

- **App content access:** Declare if the app accesses restricted APIs (e.g. SMS, call log). KannadaBuddy typically only needs **Photos/Media/Files** (and optionally **Camera**) – declare what you actually use.
- **Ads:** KannadaBuddy shows ads for free users (AdMob). Select **Yes, my app contains ads** and complete the ad declaration. Replace test AdMob IDs with production App ID and banner ad unit IDs in AndroidManifest.xml, Info.plist, and lib/main.dart before release.
- **Content rating:** Complete the questionnaire (e.g. IARC). For an education/translation app, you’ll usually get a low rating (e.g. Everyone).
- **Target audience:** Set age groups (e.g. 13+ or as per your policy).
- **News app:** No (unless you qualify).
- **COVID-19 contact tracing / status:** No (unless applicable).
- **Data safety:** Already covered in step 3.
- **Government apps:** No (unless applicable).

---

## 6. Build and upload an Android App Bundle

On your machine:

1. **Release build**
   ```bash
   cd /path/to/kanndabuddy
   flutter clean
   flutter pub get
   flutter build appbundle
   ```
   Output: `build/app/outputs/bundle/release/app-release.aab`

2. **Upload to Play Console**
   - **Release → Testing** (or **Production** when ready).
   - Create a new release (e.g. **Internal testing** first).
   - Upload `app-release.aab`.
   - Add **Release name** (e.g. 1.0.0 (1)) and **Release notes**.
   - Save and start rollout to the chosen track.

3. **Version:** Ensure `version` in `pubspec.yaml` (e.g. `1.0.0+1`) is what you want. The first number is `versionName`, the part after `+` is `versionCode` (must increase for each upload).

---

## 7. Testing before public release

- **Internal testing:** Add testers by email. They get a link to install. Good for a quick check (including IAP if you use a license tester account).
- **Closed testing:** Optional; broader testers.
- **Open testing:** Optional; public opt-in test.
- For **in-app purchase testing:** Add the tester Gmail accounts under **Setup → License testing** so they can “purchase” without being charged.

---

## 8. Production release

- When store listing, data safety, content rating, and subscription are done and you’ve tested on **Internal** (or Closed) track:
  - Go to **Release → Production**.
  - Create a new release and upload the same (or a newer) **.aab**.
  - Add release notes and submit for review.
- Google will review the app (and subscription if applicable). After approval, the app goes live.

---

## Quick checklist

| Step | Where in Play Console | Status |
|------|------------------------|--------|
| Create app / match package name | Dashboard | ☐ |
| Store listing (description, icon, screenshots) | Grow → Main store listing | ☐ |
| Privacy policy URL | Policy → App content → Privacy policy | ☐ |
| Data safety form | Policy → App content → Data safety | ☐ |
| Subscription `kannadabuddy_pro_monthly` | Monetize → Subscriptions | ☐ |
| Content rating | Policy → App content → Content rating | ☐ |
| Other declarations (ads, target audience, etc.) | Policy → App content | ☐ |
| Build and upload .aab | Release → Testing or Production | ☐ |
| License testers (for IAP) | Setup → License testing | ☐ |
| Submit for review | Release → Production | ☐ |

---

## Hosting a privacy policy URL

You need a **public URL** for the privacy policy. Options:

1. **GitHub Pages:** Create a repo (e.g. `kannadabuddy-legal`), add `index.html` or `privacy.md`, enable GitHub Pages. Use the generated URL (e.g. `https://yourusername.github.io/kannadabuddy-legal/`).
2. **Your own domain:** Add a page like `https://yourdomain.com/kannadabuddy-privacy`.
3. **Privacy policy generators:** Some offer a free hosted page; use the URL they give you.

Use the same policy text as in the app (`lib/content/legal_content.dart`) so store listing and in-app content match.

---

## Contact

For app support or Play listing questions: **kannadabuddya@gmail.com**
