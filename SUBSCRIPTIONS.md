# Subscription tracking and validation

## How the app marks the subscription

| Step | What happens |
|------|----------------|
| 1 | User taps **Subscribe** and completes payment in Google Play / App Store. |
| 2 | The store sends a **purchase** event to the app via the `in_app_purchase` plugin. |
| 3 | `IAPService._onPurchaseUpdate` receives it with `PurchaseStatus.purchased` (or `restored` on restore). |
| 4 | The app calls **`onPurchaseSuccess()`**, which runs: `SharedPreferences.setBool('kannada_buddy_has_upgraded', true)`. |
| 5 | That **local flag** is the “mark”: the app treats the user as **Pro** (Copy/Share, no free limit) as long as `kannada_buddy_has_upgraded == true`. |

So the subscription is **marked** only by a **boolean in device storage**. There is no expiry date stored in the app.

---

## How (and whether) the app checks the validity period

**Today the app does *not* check a validity period or expiry date.**

- The Flutter `in_app_purchase` plugin does **not** expose subscription **expiry date** on Android (or iOS) in a simple way.
- The app never reads “valid until” from the purchase; it only knows “the store said purchased/restored” at that moment.
- So **validity** is only implied:
  - When the user **purchases** or taps **Restore**, the store sends current/active purchases. If the subscription is **expired** or **cancelled**, the store may **not** return it (platform-dependent). In that case the app would not call `onPurchaseSuccess`, but the app also does **not** set Pro to `false` when restore returns nothing — so a user who had Pro and then expired might still appear Pro until they clear data or reinstall.

To **properly** check validity period you have two options:

1. **Restore on launch and treat “no subscription returned” as not Pro**  
   After calling `restorePurchases()`, wait for the stream; if you get no event for `kannadabuddy_pro_monthly`, set `kannada_buddy_has_upgraded = false`. That way, when the store stops returning the subscription (e.g. expired), the app will downgrade. (The app already does restore on launch but does not yet clear the flag when nothing is returned.)

2. **Server-side validation (recommended for real expiry)**  
   Your backend calls **Google Play Developer API** (Android) or **App Store Server API** (iOS) with the purchase token, gets the **actual subscription status and expiry date**, and tells the app whether the user is still Pro. The app then marks subscription (or clears it) based on the server response.

---

## How it works today (details)

### Tracking (in the app)

| What | Where | Key |
|------|--------|-----|
| **Pro status** | `SharedPreferences` (device only) | `kannada_buddy_has_upgraded` |
| **Free-use count** | `SharedPreferences` | `kannada_buddy_free_use_count` |

- When a **purchase** or **restore** succeeds, the app sets `kannada_buddy_has_upgraded = true` and treats the user as Pro (Copy/Share, no limit).
- On **launch**, the app reads this flag; it does **not** call the store to re-validate.
- **Restore** is only triggered when the user taps “Restore purchases” on the upgrade screen.

So today, “validation” is: **whatever the store reports** via the `in_app_purchase` plugin (`PurchaseStatus.purchased` or `PurchaseStatus.restored`). There is **no server-side** verification.

---

## 1. Validate on device (improve current flow)

### A. Restore on launch (recommended)

**This app does a restore on launch:** when the app starts, it calls the store’s `restorePurchases()`. If the store returns the Pro subscription (e.g. after reinstall or new device), the app sets `kannada_buddy_has_upgraded = true` and the user gets Pro without opening the upgrade screen.

Re-ask the store for existing purchases when the app starts. That way:

- After reinstall or new device, the app can recover Pro without the user opening the upgrade screen.
- If the user cancelled or refunded, the store won’t return the subscription and the app can treat them as free again (once you stop relying only on the local flag).

**Idea:** After `_loadMonetizationState()`, if the store is available, call `restorePurchases()` once at startup. In `IAPService._onPurchaseUpdate`, when you get `PurchaseStatus.restored` for the subscription, call `onPurchaseSuccess()` so the app updates Pro status (and can write `kannada_buddy_has_upgraded = true` again). If restore returns nothing (or no subscription), keep or set Pro to false.

### B. Don’t trust only the local flag for “forever”

Right now, once `kannada_buddy_has_upgraded` is true, the app never re-checks. So:

- **Expired subscriptions** (e.g. user stopped paying) are not detected.
- **Refunds / cancellations** are not reflected until the user taps Restore (and the store stops returning the subscription).

To “validate” properly on device you need to:

1. **Restore on launch** (and optionally periodically), and  
2. **Only set Pro = true when the store actually returns the subscription** in that restore; otherwise set Pro = false (and optionally clear `kannada_buddy_has_upgraded`).

Then “tracking” is still local, but “validation” is: *current store state*, not a one-time flag.

---

## 2. Server-side validation (strongest)

To **track and validate** subscriptions in a way you control (and that works across devices and reinstalls), add a **backend** that talks to Google and Apple.

### Android (Google Play)

1. **Get a purchase token**  
   From `PurchaseDetails.verificationData.serverVerificationData` (and related fields) you get a token after purchase/restore.

2. **Backend calls Google Play Developer API**  
   - Use **Google Play Developer API** → *Purchases.subscriptions* (e.g. `get`).  
   - Send: subscription ID, purchase token, and (for server) the **package name** and **service account** credentials.  
   - Response includes subscription state: active, expired, cancelled, etc.

3. **App calls your backend**  
   - After purchase or restore, app sends (e.g. over HTTPS) to your server: product id, purchase token, platform.  
   - Server calls Google, then returns “active” or “not active”.  
   - App sets Pro (and optionally `kannada_buddy_has_upgraded`) only when server says active.

### iOS (App Store)

1. **Get receipt / transaction info**  
   From the `in_app_purchase` plugin you get purchase/restore data; on iOS this can include receipt data or transaction identifiers.

2. **Backend calls App Store**  
   - **App Store Server API** (recommended): verify transaction and get subscription status.  
   - Or **verifyReceipt** (legacy): send receipt to Apple; response includes subscription status and expiry.

3. **App calls your backend**  
   - Same idea as Android: app sends receipt/transaction to your server; server talks to Apple and returns active/not active; app sets Pro only when server says active.

### What the backend can do

- **Validate** each purchase/restore with Google or Apple.
- **Track** subscriptions in your DB (user id, product, platform, expiry, status).
- **Single source of truth**: e.g. “is this user Pro?” is decided by your server, not only by the app’s SharedPreferences.

---

## 3. Practical checklist

| Goal | What to do |
|------|------------|
| **Track** (who is Pro on this device) | Keep using SharedPreferences + set/clear when purchase/restore succeeds or re-validation says not active. |
| **Validate on device** | Add restore-on-launch (and optionally periodic restore); only set Pro when the store returns the subscription. |
| **Validate on server** | Add backend that verifies with Google Play and App Store; app sends purchase/restore data to backend and sets Pro only if backend says “active”. |
| **Handle expiry/refund** | With restore-on-launch (and server if you have it), treat user as Pro only when store (and server) say active; otherwise set Pro = false and clear local flag. |

---

## 4. References

- **Google Play**: [Verify purchases on the backend](https://developer.android.com/google/play/billing/security#verify)
- **Apple**: [App Store Server API](https://developer.apple.com/documentation/appstoreserverapi), [Server Notifications](https://developer.apple.com/documentation/appstoreservernotifications)
- **Flutter**: `in_app_purchase` plugin exposes purchase/restore data you can send to your server for verification.
