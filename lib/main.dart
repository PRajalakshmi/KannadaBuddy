import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'content/legal_content.dart';
import 'models/ocr_result.dart';
import 'services/auth_service.dart';
import 'services/iap_service.dart';
import 'services/ocr_service.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:package_info_plus/package_info_plus.dart';
// Monetization: 2 free file/image uses, then upgrade. Copy & Share require upgrade.
const int _kFreeUseLimit = 5;
/// Max characters for typed Kannada text (translation APIs have limits; keep under ~5k).
const int _kMaxTypedTextLength = 2000;
const String _kKeyFreeUseCount = 'kannada_buddy_free_use_count';
const String _kKeyHasUpgraded = 'kannada_buddy_has_upgraded';
const String _kKeyPurchaseToken = 'kannada_buddy_purchase_token';
// Subscription price (single place for Play Store / future IAP).
const String kSubscriptionPrice = '₹99';
const String kSubscriptionPeriod = 'month';
// Minimum English word count we require for image/document translations
// to avoid obviously incomplete outputs. For very short text, prefer the
// typed Kannada input instead of image/document upload.
const int _kMinEnglishWordsForImageDoc = 8;

/// Full-screen ad when a free user taps **Maybe later** on upgrade from Copy/Share or from image/doc limit.
const String _kRewardInterstitialAdUnitId = 'ca-app-pub-8200804857823335/4450763976';

/// Outcome of the upgrade sheet ([_UpgradePage]).
enum UpgradeFlowResult {
  subscribed,
  copyShareUnlockedViaAd,
  mediaUnlockedViaAd,
  dismissed,
}

/// Which feature **Maybe later** + interstitial unlocks (non-subscribers only).
enum _UpgradeInterstitialKind { copyShare, freeMediaLimit }

/// Loads and shows an interstitial; completes after dismiss, failed show/load, or timeout.
Future<void> _runRewardInterstitial() async {
  final completer = Completer<void>();
  var finished = false;
  void complete() {
    if (finished) return;
    finished = true;
    if (!completer.isCompleted) completer.complete();
  }

  await InterstitialAd.load(
    adUnitId: _kRewardInterstitialAdUnitId,
    request: const AdRequest(),
    adLoadCallback: InterstitialAdLoadCallback(
      onAdLoaded: (InterstitialAd ad) {
        ad.fullScreenContentCallback = FullScreenContentCallback(
          onAdDismissedFullScreenContent: (InterstitialAd ad) {
            ad.dispose();
            complete();
          },
          onAdFailedToShowFullScreenContent: (InterstitialAd ad, AdError error) {
            ad.dispose();
            complete();
          },
        );
        ad.show();
      },
      onAdFailedToLoad: (LoadAdError error) {
        complete();
      },
    ),
  );

  await completer.future.timeout(
    const Duration(seconds: 25),
    onTimeout: () {
      complete();
    },
  );
}

/// Message when image/document could not be read or translation is not meaningful.
const String _kUnreadableMessage =
    'We could not reliably read or translate this input. Please upload a clearer image or document and try again. '
    'Avoid blur, poor lighting, shadows, fingers or objects covering the text, cluttered backgrounds, and skewed or angled pages. '
    'Use a sharp, well-lit image cropped to the text only, with nothing obscuring the words.';

/// Shown when backend says quota exceeded but app thinks user is Pro (subscription not linked).
const String _kSubscriberQuotaMessage =
    'Your Pro subscription wasn\'t recognized. We tried to link it — please try again. '
    'If it still fails, open the Upgrade screen (from the menu) and tap Restore.';

/// Typed-text input specific messages (shown in the text-box / translate flow).
const String _kErrorEmptyTypedInput =
    'Please enter or paste some Kannada text to translate.';
const String _kErrorTypedTranslationNotMeaningful =
    'We couldn\'t get a clear translation for this text. Try shorter text or split into smaller parts.';
const String _kErrorTypedTranslationFailed =
    'Translation failed. Check your internet connection and try again.';

/// Image (gallery) specific messages.
const String _kErrorImageUnreadable =
    'We couldn\'t read or translate text from this image. Use a clear, well-lit photo with readable Kannada text; avoid blur, shadows, or objects covering the text.';
const String _kErrorImageFailed =
    'Image processing failed. Check your internet connection and try again.';

/// Document specific messages.
const String _kErrorDocumentNoPath =
    'Could not open the selected file. Try another file.';
const String _kErrorDocumentUnreadable =
    'We couldn\'t read or translate this document. Try a different PDF, DOC, DOCX or TXT file with clear Kannada text.';
const String _kErrorDocumentFailed =
    'Document processing failed. Check your internet connection and try again.';

/// Counts space-separated tokens (words) in text (language-agnostic).
int _wordCount(String text) {
  return text.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty).length;
}

/// Extracts \"meaningful\" English-like words (filters romanized gibberish like \"sa\", \"ka\"):
/// - at least 3 alphabetic characters
/// - majority of characters are A–Z/a–z
List<String> _englishWords(String text) {
  final tokens = text.trim().split(RegExp(r'\s+'));
  final words = <String>[];
  for (final raw in tokens) {
    final token = raw.trim();
    if (token.isEmpty) continue;
    final runes = token.runes.toList();
    int letterCount = 0;
    int nonLetterCount = 0;
    for (final r in runes) {
      final isAsciiLetter =
          (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A);
      if (isAsciiLetter) {
        letterCount++;
      } else if (r != 0x27 /* apostrophe */) {
        nonLetterCount++;
      }
    }
    if (letterCount >= 3 && letterCount > nonLetterCount) {
      words.add(token.toLowerCase());
    }
  }
  return words;
}

int _englishWordCount(String text) => _englishWords(text).length;

/// True if the English translation looks meaningful: non-empty, not same as source,
/// not mostly Kannada, and translation word/character count is in a reasonable ratio to Kannada.
/// [transliteration] optional: for image/doc, if provided and source is long, we require
/// transliteration word count to be in line with source (catches bad OCR returning one run-on).
/// [forDocument] when true, skips strict transliteration overlap checks—PDF notes often mix
/// Kannada with short English glosses so translation tokens overlap romanized text and would
/// otherwise be rejected despite a valid server response.
bool _isTranslationMeaningful(
  String sourceText,
  String translation, {
  String? transliteration,
  bool forDocument = false,
}) {
  final t = translation.trim();
  if (t.isEmpty) return false;
  final src = sourceText.trim();
  if (t == src) return false;
  final chars = t.replaceAll(RegExp(r'\s'), '').runes.toList();
  if (chars.isEmpty) return false;
  int kannadaCount = 0;
  for (final r in chars) {
    if (r >= 0x0C80 && r <= 0x0CFF) kannadaCount++;
  }
  if (kannadaCount > chars.length ~/ 2) return false;

  final srcWords = _wordCount(src);
  final transWords = _englishWords(t);
  final dstWords = transWords.length;
  final srcLen = src.length;
  final dstLen = t.length;

  // Short input (one word/line): accept if we got some translation.
  if (srcWords <= 4) {
    if (dstWords < 1) return false;
    return true;
  }

  // Longer input: translation word count must be a reasonable fraction of Kannada word count.
  // Documents (PDF notes) often have sparse English glosses—don't require as many English tokens.
  final minWords = forDocument
      ? 1
      : (srcWords / 3).ceil().clamp(1, 999);
  if (dstWords < minWords) return false;

  // Long source (e.g. full page): translation must not be disproportionately short by character length.
  if (!forDocument && srcLen > 300 && dstLen < srcLen / 5) return false;

  // For image/doc: if transliteration is provided, run strict translation-vs-transliteration checks.
  // Documents extracted from PDF often have glossary-style lines (Kannada + English); overlap is high.
  if (!forDocument && transliteration != null && srcWords > 10) {
    final transLitWords = _wordCount(transliteration);
    if (transLitWords < (srcWords / 5).ceil()) return false;

    final translitWords = _englishWords(transliteration);
    final transSet = transWords.toSet();
    final translitSet = translitWords.toSet();
    final overlapCount = transSet.intersection(translitSet).length;
    final uniqueInTranslation = transSet.length - overlapCount;
    final overlapRatio =
        transSet.isEmpty ? 0.0 : overlapCount / transSet.length;

    // Reject if too many translation \"words\" are just transliteration (romanized gibberish).
    if (overlapRatio > 0.35) return false;
    // Require at least 8 words in translation that are NOT in transliteration (real English).
    if (uniqueInTranslation < _kMinEnglishWordsForImageDoc) return false;
  }

  return true;
}

/// Log OCR/document/translate errors for debugging. User never sees this.
void _logOcrError(String context, Object error, [StackTrace? stackTrace]) {
  debugPrint('[KannadaBuddy OCR error] context=$context error=$error');
  if (stackTrace != null) {
    debugPrint('[KannadaBuddy OCR error] stackTrace:\n$stackTrace');
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Strict family/kids ad policy: no mature content, no personalized/interest-based ads,
  // no remarketing or behavioural tracking, child-directed treatment, G-rated only.
  await MobileAds.instance.updateRequestConfiguration(
    RequestConfiguration(
      maxAdContentRating: MaxAdContentRating.g,
      tagForChildDirectedTreatment: TagForChildDirectedTreatment.yes,
      tagForUnderAgeOfConsent: TagForUnderAgeOfConsent.yes,
    ),
  );
  await MobileAds.instance.initialize();
  runApp(MyApp());
}

// Professional, parent & kid-friendly theme
final _theme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xFF0D7377),
    brightness: Brightness.light,
    primary: const Color(0xFF0D7377),
    secondary: const Color(0xFF14A3B8),
  ),
  scaffoldBackgroundColor: const Color(0xFFF5F8FA),
  appBarTheme: const AppBarTheme(
    centerTitle: true,
    elevation: 0,
    backgroundColor: Color(0xFF0D7377),
    foregroundColor: Colors.white,
    titleTextStyle: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w600,
      color: Colors.white,
      letterSpacing: -0.5,
    ),
  ),
  cardTheme: CardThemeData(
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    color: Colors.white,
    margin: EdgeInsets.zero,
  ),
  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      elevation: 0,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
  ),
  textButtonTheme: TextButtonThemeData(
    style: TextButton.styleFrom(
      foregroundColor: const Color(0xFF0D7377),
      textStyle: const TextStyle(fontWeight: FontWeight.w600),
    ),
  ),
  snackBarTheme: SnackBarThemeData(
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    backgroundColor: const Color(0xFF2D3436),
  ),
);

class MyApp extends StatefulWidget {
  @override
  State<MyApp> createState() => _MyAppState();
}

// Kannada keyboard: 4 columns x 8 rows per page (row 8 = space/backspace/done). Multipage.
// Dotted circle (U+25CC) + ottakshara keys: display as ◌್ಕ etc., insert only ್ಕ so it combines with preceding consonant.
const String _kannadaDottedCircle = '\u25CC'; // ◌
const List<String> _kannadaKeyboardChars = [
  'ಅ', 'ಆ', 'ಇ', 'ಈ', 'ಉ', 'ಊ', 'ಋ', 'ಎ', 'ಏ', 'ಐ', 'ಒ', 'ಓ', 'ಔ',
  'ಾ', 'ಿ', 'ೀ', 'ು', 'ೂ', 'ೃ', 'ೆ', 'ೇ', 'ೈ', 'ೊ', 'ೋ', 'ೌ', 'ಂ', 'ಃ', '್',
  'ಕ', 'ಖ', 'ಗ', 'ಘ', 'ಙ', 'ಚ', 'ಛ', 'ಜ', 'ಝ', 'ಞ', 'ಟ', 'ಠ', 'ಡ', 'ಢ',
  'ಣ', 'ತ', 'ಥ', 'ದ', 'ಧ', 'ನ', 'ಪ', 'ಫ', 'ಬ', 'ಭ', 'ಮ', 'ಯ', 'ರ', 'ಲ',
  'ವ', 'ಶ', 'ಷ', 'ಸ', 'ಹ', 'ಳ',
  // Dotted circle + ottakshara (display only); on tap we insert just the ottakshara part (್+consonant)
  '$_kannadaDottedCircle\u0CCD', // ◌್
  '$_kannadaDottedCircle\u0CCD\u0C95', '$_kannadaDottedCircle\u0CCD\u0C96', '$_kannadaDottedCircle\u0CCD\u0C97', '$_kannadaDottedCircle\u0CCD\u0C98', '$_kannadaDottedCircle\u0CCD\u0C99',
  '$_kannadaDottedCircle\u0CCD\u0C9A', '$_kannadaDottedCircle\u0CCD\u0C9B', '$_kannadaDottedCircle\u0CCD\u0C9C', '$_kannadaDottedCircle\u0CCD\u0C9D', '$_kannadaDottedCircle\u0CCD\u0C9E',
  '$_kannadaDottedCircle\u0CCD\u0C9F', '$_kannadaDottedCircle\u0CCD\u0CA0', '$_kannadaDottedCircle\u0CCD\u0CA1', '$_kannadaDottedCircle\u0CCD\u0CA2', '$_kannadaDottedCircle\u0CCD\u0CA3',
  '$_kannadaDottedCircle\u0CCD\u0CA4', '$_kannadaDottedCircle\u0CCD\u0CA5', '$_kannadaDottedCircle\u0CCD\u0CA6', '$_kannadaDottedCircle\u0CCD\u0CA7', '$_kannadaDottedCircle\u0CCD\u0CA8',
  '$_kannadaDottedCircle\u0CCD\u0CAA', '$_kannadaDottedCircle\u0CCD\u0CAB', '$_kannadaDottedCircle\u0CCD\u0CAC', '$_kannadaDottedCircle\u0CCD\u0CAD', '$_kannadaDottedCircle\u0CCD\u0CAE',
  '$_kannadaDottedCircle\u0CCD\u0CAF', '$_kannadaDottedCircle\u0CCD\u0CB0', '$_kannadaDottedCircle\u0CCD\u0CB2', '$_kannadaDottedCircle\u0CCD\u0CB5',
  '$_kannadaDottedCircle\u0CCD\u0CB6', '$_kannadaDottedCircle\u0CCD\u0CB7', '$_kannadaDottedCircle\u0CCD\u0CB8', '$_kannadaDottedCircle\u0CCD\u0CB9', '$_kannadaDottedCircle\u0CCD\u0CB3',
];
const int _keyboardCols = 4;
const int _keyboardCharRows = 7; // row 8 is space/backspace/done
const int _keyboardKeysPerPage = _keyboardCols * _keyboardCharRows; // 28

class _MyAppState extends State<MyApp> {
  String transliteration = "";
  String translation = "";
  String? errorMessage;
  bool _isLoading = false;
  double _progressValue = 0.0;
  Timer? _progressTimer;
  bool _showKannadaKeyboard = false;
  int _keyboardPageIndex = 0;
  int _freeUseCount = 0;
  bool _hasUpgraded = false;
  /// After free image/doc uses are exhausted, user can tap Maybe later + ad once per session to keep uploading.
  bool _mediaUnlockedViaAdSession = false;
  /// For main page: subscriber name when premium, else 'Guest'.
  String _mainDisplayName = 'Guest';
  /// Pro subscription expiry (ISO date string from backend); null when free or unknown.
  String? _subscriptionExpiry;
  /// Only set when an exception occurred; shown in debug mode for diagnosis.
  String? _lastOcrErrorDetail;
  final AuthService authService = AuthService();
  final OCRService ocrService = OCRService();
  final TextEditingController _kannadaController = TextEditingController();
  final FocusNode _kannadaFocusNode = FocusNode();
  final PageController _keyboardPageController = PageController();
  static final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  void _onKannadaFocusChange() {
    setState(() => _showKannadaKeyboard = _kannadaFocusNode.hasFocus);
  }

  /// Sets the Kannada text box content, never exceeding [_kMaxTypedTextLength].
  void _setKannadaText(String text) {
    if (text.length <= _kMaxTypedTextLength) {
      _kannadaController.text = text;
    } else {
      _kannadaController.text = text.substring(0, _kMaxTypedTextLength);
    }
  }

  void _hideKannadaKeyboardAndClearResults() {
    _kannadaFocusNode.unfocus();
    _kannadaController.clear();
    setState(() {
      transliteration = '';
      translation = '';
      errorMessage = null;
      _lastOcrErrorDetail = null;
    });
  }

  IAPService? _launchIAP;

  @override
  void initState() {
    super.initState();
    _kannadaFocusNode.addListener(_onKannadaFocusChange);
    // Restore sign-in first so subscribed users are remembered every launch, then load state and refresh.
    authService.restoreSignInIfNeeded().then((_) async {
      if (!mounted) return;
      await _loadMonetizationState();
      if (!mounted) return;
      if (await authService.isSignedIn()) {
        if (mounted) _refreshUserStatusFromBackend();
      }
      if (!mounted) return;
      _restorePurchasesOnLaunch();
    });
  }

  /// At launch: restore purchases from store, send token to backend (verify + store expiry), then apply user_status.
  /// Backend is source of truth: if active → unlock premium; if expired → show subscribe button.
  Future<void> _restorePurchasesOnLaunch() async {
    await _loadMonetizationState();
    if (!mounted) return;
    _launchIAP = IAPService(
      onPurchaseSuccess: (String? purchaseToken) async {
        if (purchaseToken == null || purchaseToken.isEmpty) return;
        await _savePurchaseToken(purchaseToken);
        final uid = await authService.currentUserId();
        if (uid == null) return;
        try {
          final body = await ocrService.linkSubscription(uid, purchaseToken, platform: 'android');
          if (mounted && body != null && body['user_status'] != null) {
            await _applyUserStatusFromMap(body['user_status'] as Map<String, dynamic>);
          } else if (mounted) {
            await _refreshUserStatusFromBackend();
          }
        } catch (_) {
          if (mounted) await _refreshUserStatusFromBackend();
        }
      },
    );
    final available = await _launchIAP!.initialize();
    if (!available || !mounted) return;
    await _launchIAP!.restore();
    Future.delayed(const Duration(seconds: 5), () {
      _launchIAP?.dispose();
      _launchIAP = null;
    });
  }

  /// Fetches user status from backend. Premium is always from backend (expiry-based); we never cache as source of truth.
  /// At launch we use this to decide: if active → unlock premium; if expired → show subscribe button.
  Future<void> _refreshUserStatusFromBackend() async {
    final uid = await authService.currentUserId();
    if (uid == null) return;
    try {
      final status = await ocrService.getUserStatus(uid);
      if (status == null || !mounted) return;
      await _applyUserStatusFromMap(status);
    } catch (_) {}
  }

  Future<void> _loadMonetizationState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final upgraded = prefs.getBool(_kKeyHasUpgraded) ?? false;
      final name = prefs.getString('kannada_buddy_user_display_name');
      if (!mounted) return;
      setState(() {
        _freeUseCount = prefs.getInt(_kKeyFreeUseCount) ?? 0;
        _hasUpgraded = upgraded;
        _mainDisplayName = (upgraded && name != null && name.isNotEmpty) ? name : 'Guest';
      });
    } catch (_) {}
  }

  Future<void> _applyUserStatusFromResult(OcrResult? result) async {
    await _applyUserStatusFromMap(result?.userStatus);
  }

  /// Applies backend user_status (e.g. from subscription link or /user/status) to local state and prefs.
  /// Premium is only applied when the user is signed in; guests never get premium from API responses.
  Future<void> _applyUserStatusFromMap(Map<String, dynamic>? status) async {
    if (status == null) return;
    final count = status['free_use_count'] as int?;
    final fromBackend = status['is_premium'] as bool? ?? status['has_pro'] as bool? ?? false;
    final signedIn = await authService.isSignedIn();
    final bool wasPremium = _hasUpgraded;
    final isPremium = signedIn ? fromBackend : false;
    final displayName = status['display_name'] as String?;
    final expiry = status['subscription_expiry'] as String?;
    if (count != null) setState(() => _freeUseCount = count);
    if (!mounted) return;
    setState(() {
      _hasUpgraded = isPremium;
      _mainDisplayName = (isPremium && displayName != null && displayName.isNotEmpty) ? displayName : 'Guest';
      _subscriptionExpiry = isPremium ? expiry : null;
    });
    if (wasPremium && !isPremium && mounted) {
      // Subscription expired or was cancelled.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Your KannadaBuddy Pro plan has expired. Tap Upgrade to renew.'),
            duration: Duration(seconds: 5),
          ),
        );
      });
    }
    final prefs = await SharedPreferences.getInstance();
    if (count != null) await prefs.setInt(_kKeyFreeUseCount, count);
    await prefs.setBool(_kKeyHasUpgraded, isPremium);
    if (displayName != null && displayName.isNotEmpty && isPremium) {
      await prefs.setString('kannada_buddy_user_display_name', displayName);
    }
  }

  Future<void> _incrementLocalFreeUse() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kKeyFreeUseCount, (prefs.getInt(_kKeyFreeUseCount) ?? 0) + 1);
    if (mounted) await _loadMonetizationState();
  }

  /// Opens upgrade screen first; sign-in is shown only when user taps Subscribe on that screen.
  /// [callerContext] when set (e.g. from Results page) uses its navigator so the route actually opens.
  Future<UpgradeFlowResult?> _openUpgradeFlow({
    BuildContext? callerContext,
    bool forCopyShare = false,
    bool forFreeMediaLimit = false,
  }) async {
    _UpgradeInterstitialKind? interstitialKind;
    if (!_hasUpgraded) {
      if (forCopyShare) interstitialKind = _UpgradeInterstitialKind.copyShare;
      if (forFreeMediaLimit) interstitialKind = _UpgradeInterstitialKind.freeMediaLimit;
    }
    final navigator = callerContext != null
        ? Navigator.of(callerContext)
        : _navigatorKey.currentState;
    final result = await navigator?.push<UpgradeFlowResult>(
      MaterialPageRoute<UpgradeFlowResult>(
        builder: (context) => _UpgradePage(
          authService: authService,
          onLinkSubscription: _linkSubscriptionToken,
          maybeLaterInterstitialKind: interstitialKind,
        ),
      ),
    );
    if (result == UpgradeFlowResult.subscribed && mounted) {
      await _refreshUserStatusFromBackend();
    }
    return result;
  }

  @override
  void dispose() {
    _launchIAP?.dispose();
    _launchIAP = null;
    _progressTimer?.cancel();
    _kannadaFocusNode.removeListener(_onKannadaFocusChange);
    _kannadaFocusNode.dispose();
    _kannadaController.dispose();
    _keyboardPageController.dispose();
    super.dispose();
  }

  void _startProgressAnimation() {
    _progressTimer?.cancel();
    _progressValue = 0.0;
    _progressTimer = Timer.periodic(const Duration(milliseconds: 120), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        if (_progressValue < 0.9) {
          _progressValue = (_progressValue + 0.04).clamp(0.0, 0.9);
        }
      });
    });
  }

  void _completeProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
    if (!mounted) return;
    setState(() => _progressValue = 1.0);
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) setState(() {
        _isLoading = false;
        _progressValue = 0.0;
      });
    });
  }

  /// Links purchase token to current user on backend. Backend verifies with Google Play, stores expiry, returns user_status.
  /// Applies user_status from response to mark user premium. Retries once on failure. Returns true if linked.
  Future<bool> _linkSubscriptionToken(String? purchaseToken) async {
    if (purchaseToken == null || purchaseToken.isEmpty) return false;
    await _savePurchaseToken(purchaseToken);
    final uid = await authService.currentUserId();
    if (uid == null) return false;
    Future<Map<String, dynamic>?> doLink() => ocrService.linkSubscription(uid!, purchaseToken, platform: 'android');
    Map<String, dynamic>? body;
    try {
      body = await doLink();
      if (body != null && body['user_status'] != null && mounted) {
        await _applyUserStatusFromMap(body['user_status'] as Map<String, dynamic>);
      }
      return true;
    } catch (_) {
      await Future<void>.delayed(const Duration(seconds: 2));
      try {
        body = await doLink();
        if (body != null && body['user_status'] != null && mounted) {
          await _applyUserStatusFromMap(body['user_status'] as Map<String, dynamic>);
        }
        return true;
      } catch (_) {
        return false;
      }
    }
  }

  /// Saves purchase token so we can re-link after app reopen without waiting for restore.
  Future<void> _savePurchaseToken(String? token) async {
    if (token == null || token.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kKeyPurchaseToken, token);
  }

  /// When backend returns 403: try to re-link subscription (stored token or restore), then refresh status from backend.
  Future<bool> _tryRelinkSubscription() async {
    final uid = await authService.currentUserId();
    if (uid == null) return false;
    final prefs = await SharedPreferences.getInstance();
    final storedToken = prefs.getString(_kKeyPurchaseToken);
    if (storedToken != null && storedToken.isNotEmpty) {
      final linked = await _linkSubscriptionToken(storedToken);
      if (linked) return true;
    }
    final completer = Completer<bool>();
    IAPService? iap;
    iap = IAPService(
      onPurchaseSuccess: (String? token) async {
        if (token == null || token.isEmpty) return;
        await _savePurchaseToken(token);
        try {
          final body = await ocrService.linkSubscription(uid!, token, platform: 'android');
          if (mounted && body != null && body['user_status'] != null) {
            await _applyUserStatusFromMap(body['user_status'] as Map<String, dynamic>);
          }
          if (!completer.isCompleted) completer.complete(true);
        } catch (_) {
          if (!completer.isCompleted) completer.complete(false);
        } finally {
          iap?.dispose();
        }
      },
    );
    final available = await iap.initialize();
    if (!available) {
      iap.dispose();
      return false;
    }
    await iap.restore();
    final linked = await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        iap?.dispose();
        return false;
      },
    );
    return linked;
  }

  void _navigateToResults(String kannada, String transliteration, String translation) {
    _navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (context) => _ResultsPage(
          kannada: kannada,
          transliteration: transliteration,
          translation: translation,
          hasUpgraded: _hasUpgraded,
          onLinkSubscription: _linkSubscriptionToken,
          onRequestUpgrade: (ctx) =>
              _openUpgradeFlow(callerContext: ctx, forCopyShare: true),
        ),
      ),
    );
  }

  /// Returns true if the user can proceed (under free limit, upgraded, or ad-unlocked session for media).
  Future<bool> _showUpgradeIfNeeded() async {
    if (_hasUpgraded || _freeUseCount < _kFreeUseLimit || _mediaUnlockedViaAdSession) {
      return true;
    }
    final r = await _openUpgradeFlow(forFreeMediaLimit: true);
    if (r == UpgradeFlowResult.subscribed) return true;
    if (r == UpgradeFlowResult.mediaUnlockedViaAd) {
      setState(() => _mediaUnlockedViaAdSession = true);
      return true;
    }
    return false;
  }

  Future<void> _translateTypedText() async {
    _kannadaFocusNode.unfocus();
    final text = _kannadaController.text.trim();
    if (text.isEmpty) {
      setState(() {
        errorMessage = _kErrorEmptyTypedInput;
        _lastOcrErrorDetail = null;
      });
      return;
    }
    if (text.length > _kMaxTypedTextLength) {
      setState(() {
        errorMessage = 'Text is too long (max $_kMaxTypedTextLength characters). Please shorten or paste in smaller parts.';
        _lastOcrErrorDetail = null;
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('Maximum $_kMaxTypedTextLength characters. Split your text and try again.'),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
    setState(() {
      transliteration = '';
      translation = '';
      errorMessage = null;
      _isLoading = true;
    });
    _startProgressAnimation();
    try {
      final userId = await authService.currentUserId();
      final result = await ocrService.submitKannadaText(text, userId: userId);
      if (!mounted) return;
      _completeProgress();
      await _applyUserStatusFromResult(result);
      // Long pasted text (e.g. 2000 chars): use relaxed check; if translation empty but transliteration ok, still open Results.
      final meaningful = _isTranslationMeaningful(
        text,
        result.translation,
        transliteration: result.transliteration,
        forDocument: text.length > 600,
      );
      if (!meaningful) {
        final hasTranslit = result.transliteration.trim().isNotEmpty;
        if (result.translation.trim().isEmpty && hasTranslit && text.length >= 100) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('Translation incomplete—showing transliteration. Try shorter text or try again.')),
          );
        } else {
          setState(() { errorMessage = _kErrorTypedTranslationNotMeaningful; _lastOcrErrorDetail = null; });
          return;
        }
      }
      _kannadaController.clear();
      _navigateToResults(result.text, result.transliteration, result.translation);
    } catch (e, stackTrace) {
      _logOcrError('typed_text', e, stackTrace);
      if (!mounted) return;
      _completeProgress();
      final isQuotaExceeded = e.toString().toLowerCase().contains('free quota exceeded');
      if (isQuotaExceeded) {
        if (_hasUpgraded) {
          setState(() => errorMessage = 'Linking your subscription…');
          final linked = await _tryRelinkSubscription();
          if (!mounted) return;
          if (linked) {
            await _refreshUserStatusFromBackend();
            if (!mounted) return;
            setState(() { errorMessage = null; _lastOcrErrorDetail = null; });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Subscription re-linked. Please try again.')),
            );
          } else {
            setState(() { errorMessage = _kSubscriberQuotaMessage; _lastOcrErrorDetail = null; });
          }
        } else {
          // Signed-in free user over backend quota: open upgrade.
          await _openUpgradeFlow();
        }
      } else {
        setState(() {
          errorMessage = _kErrorTypedTranslationFailed;
          _lastOcrErrorDetail = e.toString();
        });
      }
    }
  }

  void _onKannadaKey(String key) {
    if (key == 'arrow_left') {
      if (_keyboardPageIndex > 0) {
        _keyboardPageController.previousPage(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
        );
      }
      return;
    }
    if (key == 'arrow_right') {
      final totalPages = (_kannadaKeyboardChars.length / _keyboardKeysPerPage).ceil().clamp(1, 8);
      if (_keyboardPageIndex < totalPages - 1) {
        _keyboardPageController.nextPage(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
        );
      }
      return;
    }
    if (key == 'backspace') {
      final t = _kannadaController.text;
      if (t.isNotEmpty) {
        final runes = t.runes.toList();
        runes.removeLast();
        _kannadaController.text = String.fromCharCodes(runes);
      }
      return;
    }
    final t = _kannadaController.text;
    if (t.length >= _kMaxTypedTextLength) return;
    final remaining = _kMaxTypedTextLength - t.length;
    if (key == 'space') {
      _setKannadaText(t + ' ');
      return;
    }
    // Dotted-circle + ottakshara keys: insert only the ottakshara part so it combines with preceding consonant
    if (key.startsWith(_kannadaDottedCircle)) {
      final toAdd = key.substring(_kannadaDottedCircle.length);
      _setKannadaText(t + (toAdd.length <= remaining ? toAdd : toAdd.substring(0, remaining)));
      return;
    }
    final toAdd = key.length <= remaining ? key : key.substring(0, remaining);
    _setKannadaText(t + toAdd);
  }

  Future<void> _processPickedFile(XFile pickedFile) async {
    setState(() { _isLoading = true; errorMessage = null; _lastOcrErrorDetail = null; });
    _startProgressAnimation();
    try {
      final userId = await authService.currentUserId();
      final result = await ocrService.extractKannadaText(pickedFile.path, userId: userId);
      if (!mounted) return;
      _completeProgress();
      await _applyUserStatusFromResult(result);
      final text = result.text.trim();
      final hasText = text.isNotEmpty;
      final englishWords = _englishWordCount(result.translation);
      if (!hasText ||
          englishWords < _kMinEnglishWordsForImageDoc ||
          !_isTranslationMeaningful(
            text,
            result.translation,
            transliteration: result.transliteration,
          )) {
        setState(() { errorMessage = _kErrorImageUnreadable; _lastOcrErrorDetail = null; });
        return;
      }
      final uid = await authService.currentUserId();
      if (uid == null) await _incrementLocalFreeUse();
      _navigateToResults(result.text, result.transliteration, result.translation);
    } catch (e, stackTrace) {
      _logOcrError('image', e, stackTrace);
      if (!mounted) return;
      _completeProgress();
      final isQuotaExceeded = e.toString().toLowerCase().contains('free quota exceeded');
      if (isQuotaExceeded) {
        if (_hasUpgraded) {
          setState(() => errorMessage = 'Linking your subscription…');
          final linked = await _tryRelinkSubscription();
          if (!mounted) return;
          if (linked) {
            await _refreshUserStatusFromBackend();
            if (!mounted) return;
            setState(() { errorMessage = null; _lastOcrErrorDetail = null; });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Subscription re-linked. Please try again.')),
            );
          } else {
            setState(() { errorMessage = _kSubscriberQuotaMessage; _lastOcrErrorDetail = null; });
          }
        } else {
          await _openUpgradeFlow();
        }
      } else {
        setState(() {
          errorMessage = _kErrorImageFailed;
          _lastOcrErrorDetail = e.toString();
        });
      }
    }
  }

  Future<void> scanImageFromGallery() async {
    _hideKannadaKeyboardAndClearResults();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (!await _showUpgradeIfNeeded()) return;
      if (!mounted) return;
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(source: ImageSource.gallery);
      if (pickedFile != null && mounted) {
        await _processPickedFile(pickedFile);
      }
    });
  }

  Future<void> readFromDocument() async {
    _hideKannadaKeyboardAndClearResults();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      if (!await _showUpgradeIfNeeded()) return;
      if (!mounted) return;
      final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'doc', 'docx', 'txt'],
      withData: false,
      withReadStream: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null || path.isEmpty) {
      _logOcrError('document', 'Could not get file path for selected file');
      setState(() {
        errorMessage = _kErrorDocumentNoPath;
        _lastOcrErrorDetail = 'Could not get file path for selected file';
        transliteration = '';
        translation = '';
      });
      return;
    }
    setState(() {
      transliteration = '';
      translation = '';
      _isLoading = true;
      errorMessage = null;
      _lastOcrErrorDetail = null;
    });
    _startProgressAnimation();
    try {
      final userId = await authService.currentUserId();
      final docResult = await ocrService.extractFromDocument(path, userId: userId);
      if (!mounted) return;
      _completeProgress();
      await _applyUserStatusFromResult(docResult);
      final text = docResult.text.trim();
      final hasText = text.isNotEmpty;
      final hasTranslation = docResult.translation.trim().isNotEmpty;
      final hasTranslit = docResult.transliteration.trim().isNotEmpty;
      // PDF/doc: server may return translation="" if translate timed out—still show text + transliteration.
      final translationOk = hasTranslation &&
          _isTranslationMeaningful(
            text,
            docResult.translation,
            transliteration: docResult.transliteration,
            forDocument: true,
          );
      // Accept document if we have usable text and either meaningful translation or transliteration only.
      // Short docs: allow text-only if long enough (server may return translation later).
      final documentOk = hasText &&
          (translationOk ||
              (hasTranslit && text.length >= 50) ||
              (text.length >= 200 && text.contains(RegExp(r'[\u0C80-\u0CFF]'))));
      if (!documentOk) {
        setState(() { errorMessage = _kErrorDocumentUnreadable; _lastOcrErrorDetail = null; });
        return;
      }
      if (hasText && hasTranslit && !hasTranslation && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Translation timed out—showing text and transliteration. Try shorter document or try again.'),
          ),
        );
      }
      final uid = await authService.currentUserId();
      if (uid == null) await _incrementLocalFreeUse();
      _navigateToResults(docResult.text, docResult.transliteration, docResult.translation);
    } catch (e, stackTrace) {
      _logOcrError('document', e, stackTrace);
      if (!mounted) return;
      _completeProgress();
      final isQuotaExceeded = e.toString().toLowerCase().contains('free quota exceeded');
      if (isQuotaExceeded) {
        if (_hasUpgraded) {
          setState(() => errorMessage = 'Linking your subscription…');
          final linked = await _tryRelinkSubscription();
          if (!mounted) return;
          if (linked) {
            await _refreshUserStatusFromBackend();
            if (!mounted) return;
            setState(() { errorMessage = null; _lastOcrErrorDetail = null; });
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Subscription re-linked. Please try again.')),
            );
          } else {
            setState(() { errorMessage = _kSubscriberQuotaMessage; _lastOcrErrorDetail = null; });
          }
        } else {
          await _openUpgradeFlow();
        }
      } else {
        final msg = e.toString().toLowerCase();
        // Server returns clear errors for empty extract, .doc, scanned PDF, etc.
        final isExtractOrFormat = msg.contains('could not extract') ||
            msg.contains('not supported') ||
            msg.contains('docx') ||
            msg.contains('empty') ||
            msg.contains('scanned pdf');
        setState(() {
          errorMessage = isExtractOrFormat
              ? _kErrorDocumentUnreadable
              : _kErrorDocumentFailed;
          _lastOcrErrorDetail = e.toString();
        });
      }
    }
    });
  }

  Future<void> _shareText(String text, String title) async {
    await Share.share(text, subject: title);
  }

  Future<void> _copyText(String text, BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard')),
      );
    }
  }

  static const TextStyle _bodyTextStyle = TextStyle(
    fontSize: 16,
    height: 1.6,
    color: Color(0xFF2D3436),
  );

  Widget _buildKannadaKeyboard() {
    final screenWidth = MediaQuery.of(context).size.width;
    const horizontalMargin = 20.0;
    const padding = 8.0;
    const gap = 4.0;
    final availableWidth = screenWidth - horizontalMargin * 2 - padding * 2;
    final keyWidth = (availableWidth - (_keyboardCols - 1) * gap) / _keyboardCols;
    const int bottomRowKeys = 5;
    final bottomKeyWidth = (availableWidth - (bottomRowKeys - 1) * gap) / bottomRowKeys;
    const keyHeight = 36.0;
    const keyFontSize = 16.0;
    final totalPages = (_kannadaKeyboardChars.length / _keyboardKeysPerPage).ceil().clamp(1, 8);

    return Container(
      margin: const EdgeInsets.fromLTRB(horizontalMargin, 12, horizontalMargin, 0),
      height: keyHeight * 8 + gap * 7 + padding * 2 + 28,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0D7377).withOpacity( 0.08),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: PageView.builder(
              controller: _keyboardPageController,
              onPageChanged: (i) => setState(() => _keyboardPageIndex = i),
              itemCount: totalPages,
              itemBuilder: (context, pageIndex) {
                final start = pageIndex * _keyboardKeysPerPage;
                final pageChars = _kannadaKeyboardChars.skip(start).take(_keyboardKeysPerPage).toList();
                return Padding(
                  padding: const EdgeInsets.all(padding),
                  child: Column(
                    children: [
                      for (int r = 0; r < _keyboardCharRows; r++) ...[
                        Padding(
                          padding: EdgeInsets.only(bottom: r < _keyboardCharRows - 1 ? gap : 0),
                          child: Row(
                            children: List.generate(_keyboardCols, (c) {
                              final i = r * _keyboardCols + c;
                              final char = i < pageChars.length ? pageChars[i] : null;
                              return Padding(
                                padding: EdgeInsets.only(right: c < _keyboardCols - 1 ? gap : 0),
                                child: SizedBox(
                                  width: keyWidth,
                                  height: keyHeight,
                                  child: char != null
                                      ? Material(
                                          color: const Color(0xFF0D7377).withOpacity( 0.08),
                                          borderRadius: BorderRadius.circular(6),
                                          child: InkWell(
                                            onTap: () => _onKannadaKey(char),
                                            borderRadius: BorderRadius.circular(6),
                                            child: Center(
                                              child: Text(char, style: const TextStyle(fontSize: keyFontSize)),
                                            ),
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              );
                            }),
                          ),
                        ),
                      ],
                      Padding(
                        padding: const EdgeInsets.only(top: gap),
                        child: Row(
                          children: [
                            Padding(padding: const EdgeInsets.only(right: gap), child: SizedBox(width: bottomKeyWidth, height: keyHeight, child: _keyboardKey('arrow_left', width: bottomKeyWidth, height: keyHeight, icon: Icons.arrow_back_rounded))),
                            Padding(padding: const EdgeInsets.only(right: gap), child: SizedBox(width: bottomKeyWidth, height: keyHeight, child: _keyboardKey('arrow_right', width: bottomKeyWidth, height: keyHeight, icon: Icons.arrow_forward_rounded))),
                            Padding(padding: const EdgeInsets.only(right: gap), child: SizedBox(width: bottomKeyWidth, height: keyHeight, child: _keyboardKey(' ', width: bottomKeyWidth, height: keyHeight, label: 'space'))),
                            Padding(padding: const EdgeInsets.only(right: gap), child: SizedBox(width: bottomKeyWidth, height: keyHeight, child: _keyboardKey('backspace', width: bottomKeyWidth, height: keyHeight, icon: Icons.backspace_rounded))),
                            SizedBox(width: bottomKeyWidth, height: keyHeight, child: Material(color: const Color(0xFF0D7377).withOpacity( 0.15), borderRadius: BorderRadius.circular(6), child: InkWell(onTap: () => _kannadaFocusNode.unfocus(), borderRadius: BorderRadius.circular(6), child: const Center(child: Text('Done', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)))))),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (totalPages > 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(totalPages, (i) {
                  return GestureDetector(
                    onTap: () => _keyboardPageController.animateToPage(i, duration: const Duration(milliseconds: 200), curve: Curves.easeInOut),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: (_keyboardPageIndex == i) ? const Color(0xFF0D7377) : const Color(0xFF0D7377).withOpacity( 0.25),
                      ),
                    ),
                  );
                }),
              ),
            ),
        ],
      ),
    );
  }

  Widget _keyboardKey(String key, {required double width, required double height, String? label, IconData? icon}) {
    return Material(
      color: const Color(0xFF0D7377).withOpacity( 0.08),
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: () => _onKannadaKey(key),
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: width,
          height: height,
          child: Center(
            child: icon != null
                ? Icon(icon, size: 20)
                : Text(label ?? key, style: const TextStyle(fontSize: 14)),
          ),
        ),
      ),
    );
  }

  Widget _buildFreeAttemptsLabel() {
    const primary = Color(0xFF0D7377);
    final used = _freeUseCount.clamp(0, _kFreeUseLimit);
    final isOver = used >= _kFreeUseLimit;
    return Material(
      color: isOver
          ? primary.withOpacity(0.08)
          : Colors.grey.shade100,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: isOver
            ? () async {
                await _openUpgradeFlow();
              }
            : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              Icon(
                isOver ? Icons.info_outline_rounded : Icons.touch_app_rounded,
                size: 20,
                color: isOver ? primary : Colors.grey.shade700,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isOver
                      ? 'Free attempts used. Tap to upgrade for more.'
                      : '$used of $_kFreeUseLimit free attempts used (image/document)',
                  style: TextStyle(
                    fontSize: 13,
                    color: isOver ? primary : Colors.grey.shade700,
                    fontWeight: isOver ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInputCard({
    required IconData icon,
    required String label,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF0D7377).withOpacity( 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: const Color(0xFF0D7377), size: 28),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF2D3436),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: const Color(0xFF2D3436).withOpacity( 0.65),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: const Color(0xFF0D7377).withOpacity( 0.6)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultCard({
    required String title,
    required String content,
    required VoidCallback onCopy,
    required VoidCallback onShare,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0D7377).withOpacity( 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 4,
                  height: 22,
                  decoration: const BoxDecoration(
                    color: Color(0xFF0D7377),
                    borderRadius: BorderRadius.all(Radius.circular(2)),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    color: Color(0xFF0D7377),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SelectableText(content, style: _bodyTextStyle),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_rounded, size: 20),
                  label: const Text('Copy'),
                ),
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: onShare,
                  icon: const Icon(Icons.share_rounded, size: 20),
                  label: const Text('Share'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'KannadaBuddy',
      theme: _theme,
      home: Scaffold(
        appBar: AppBar(
          title: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text('KannadaBuddy'),
              Text(
                _mainDisplayName,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.normal,
                  color: Colors.white.withOpacity(0.9),
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.info_outline_rounded),
              onPressed: () {
                _navigatorKey.currentState?.push(
                  MaterialPageRoute<void>(
                    builder: (context) => _InfoMenuPage(
                      showUpgrade: !_hasUpgraded,
                      onUpgrade: (ctx) async {
                        final upgraded = await _openUpgradeFlow(callerContext: ctx);
                        if (upgraded == UpgradeFlowResult.subscribed && mounted) {
                          await _refreshUserStatusFromBackend();
                        }
                      },
                      authService: authService,
                      ocrService: ocrService,
                      hasUpgraded: _hasUpgraded,
                      displayName: _mainDisplayName,
                      subscriptionExpiry: _subscriptionExpiry,
                      onSignOut: () {
                        SharedPreferences.getInstance().then(
                          (prefs) {
                            prefs.setBool(_kKeyHasUpgraded, false);
                            prefs.remove(_kKeyFreeUseCount);
                          },
                        );
                        setState(() {
                          _mainDisplayName = 'Guest';
                          _hasUpgraded = false;
                          _freeUseCount = 0;
                          _mediaUnlockedViaAdSession = false;
                          _subscriptionExpiry = null;
                        });
                        _loadMonetizationState();
                      },
                    ),
                  ),
                );
              },
              tooltip: 'Privacy, Terms, About & more',
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
              if (!_hasUpgraded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: _buildFreeAttemptsLabel(),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Text(
                  'Add your Kannada text',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF2D3436).withOpacity( 0.7),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lightbulb_outline_rounded, size: 18, color: Colors.amber.shade700),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'For best accuracy: use a sharp, well-lit image; crop to the text only; '
                        'avoid blur, shadows, fingers or objects on the page; and hold the camera straight to avoid skew.',
                        style: TextStyle(
                          fontSize: 13,
                          color: const Color(0xFF2D3436).withOpacity(0.65),
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    _buildInputCard(
                      icon: Icons.photo_library_rounded,
                      label: 'Choose from gallery',
                      subtitle: 'Pick an image from your device',
                      onTap: scanImageFromGallery,
                    ),
                    const SizedBox(height: 10),
                    _buildInputCard(
                      icon: Icons.description_rounded,
                      label: 'Open a document',
                      subtitle: 'PDF, DOC, DOCX or TXT file',
                      onTap: readFromDocument,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      'Or type in Kannada',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: const Color(0xFF2D3436).withOpacity(0.7),
                      ),
                    ),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _kannadaController,
                      builder: (context, value, _) {
                        final len = value.text.length;
                        final atLimit = len >= _kMaxTypedTextLength;
                        return Text(
                          '$len / $_kMaxTypedTextLength',
                          style: TextStyle(
                            fontSize: 13,
                            color: atLimit
                                ? Colors.red.shade700
                                : const Color(0xFF2D3436).withOpacity(0.6),
                            fontWeight: atLimit ? FontWeight.w600 : FontWeight.w400,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF0D7377).withOpacity( 0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: TextField(
                    controller: _kannadaController,
                    focusNode: _kannadaFocusNode,
                    readOnly: true,
                    maxLines: 3,
                    maxLength: _kMaxTypedTextLength,
                    style: const TextStyle(fontSize: 18, height: 1.5),
                    decoration: InputDecoration(
                      hintText: 'Tap to use Kannada keyboard…',
                      hintStyle: TextStyle(
                        color: const Color(0xFF2D3436).withOpacity( 0.4),
                        fontSize: 16,
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(16),
                      counterText: '',
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.content_paste_rounded, color: Color(0xFF0D7377)),
                        tooltip: 'Paste from clipboard',
                        onPressed: () async {
                          final data = await Clipboard.getData(Clipboard.kTextPlain);
                          if (data != null && data.text != null && data.text!.isNotEmpty) {
                            final current = _kannadaController.text;
                            final remaining = _kMaxTypedTextLength - current.length;
                            if (remaining <= 0) return;
                            final toAdd = data.text!.length <= remaining
                                ? data.text!
                                : data.text!.substring(0, remaining);
                            _setKannadaText(current + toAdd);
                          }
                        },
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _translateTypedText,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0D7377),
                      foregroundColor: Colors.white,
                      elevation: 2,
                      shadowColor: const Color(0xFF0D7377).withOpacity( 0.4),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    icon: const Icon(Icons.translate_rounded, size: 22),
                    label: const Text('Get transliteration & translation'),
                  ),
                ),
              ),
              if (_isLoading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      LinearProgressIndicator(
                        value: _progressValue,
                        backgroundColor: const Color(0xFF0D7377).withOpacity( 0.2),
                        valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF14A3B8)),
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _progressValue >= 1.0
                              ? 'Done! Opening results…'
                              : 'Processing your request…',
                          style: TextStyle(
                            fontSize: 13,
                            color: const Color(0xFF2D3436).withOpacity(0.75),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (_progressValue > 0 && _progressValue < 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '${(_progressValue * 100).round()}%',
                            style: TextStyle(
                              fontSize: 12,
                              color: const Color(0xFF0D7377).withOpacity(0.8),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              if (_showKannadaKeyboard) _buildKannadaKeyboard(),
              if (errorMessage != null) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE74C3C).withOpacity( 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE74C3C).withOpacity( 0.3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded, size: 20, color: const Color(0xFFE74C3C)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                errorMessage!,
                                style: const TextStyle(color: Color(0xFFC0392B), fontSize: 14),
                              ),
                              if (kDebugMode && _lastOcrErrorDetail != null) ...[
                                const SizedBox(height: 8),
                                Text(
                                  _lastOcrErrorDetail!,
                                  style: TextStyle(
                                    color: const Color(0xFFC0392B).withOpacity(0.8),
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                  ),
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
                const SizedBox(height: 20),
              if (!_hasUpgraded)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 16),
                    child: const _HomeAdBanner(),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 24, bottom: 32),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.menu_book_rounded,
                          size: 48,
                          color: const Color(0xFF0D7377).withOpacity( 0.25),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Results open in a new page',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: const Color(0xFF2D3436).withOpacity( 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Banner ad for non-subscribers only. Parent must not build this when [_MyAppState._hasUpgraded] is true.
class _HomeAdBanner extends StatefulWidget {
  const _HomeAdBanner();

  @override
  State<_HomeAdBanner> createState() => _HomeAdBannerState();
}

class _HomeAdBannerState extends State<_HomeAdBanner> {
  BannerAd? _bannerAd;
  bool _isLoaded = false;

  static String get _bannerAdUnitId {
    return 'ca-app-pub-8200804857823335/8777750749';
  }

  @override
  void initState() {
    super.initState();
    _loadAd();
  }

  void _loadAd() {
    _bannerAd?.dispose();
    _bannerAd = BannerAd(
      adUnitId: _bannerAdUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (Ad ad) {
          if (mounted) setState(() => _isLoaded = true);
        },
        onAdFailedToLoad: (Ad ad, LoadAdError error) {},
      ),
    )..load();
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLoaded || _bannerAd == null) {
      return const SizedBox(height: 50);
    }
    return SizedBox(
      width: _bannerAd!.size.width.toDouble(),
      height: _bannerAd!.size.height.toDouble(),
      child: AdWidget(ad: _bannerAd!),
    );
  }
}

/// Sign-in with Google; on success backend registers user and returns quota/Pro status.
class _SignInPage extends StatelessWidget {
  const _SignInPage({required this.authService, required this.onSuccess, this.forSubscription = false});

  final AuthService authService;
  final VoidCallback onSuccess;
  final bool forSubscription;

  static Widget _benefitRow(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle_rounded, color: const Color(0xFF0D7377), size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 16, color: Color(0xFF2D3436), height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF0D7377);
    return Scaffold(
      appBar: AppBar(title: const Text('KannadaBuddy')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                Icons.menu_book_rounded,
                size: 56,
                color: primary.withOpacity(0.9),
              ),
              const SizedBox(height: 16),
              Text(
                forSubscription
                    ? 'Sign in with Google to subscribe to Pro and get full access.'
                    : 'Sign in with Google to use Kannada OCR, transliteration and translation. Your free quota is tracked per account.',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16, height: 1.4, color: Color(0xFF2D3436)),
              ),
              const SizedBox(height: 24),
              Text(
                'Full access benefits',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: primary,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 12),
              _benefitRow('Unlimited images & documents'),
              _benefitRow('Copy results to clipboard'),
              _benefitRow('Share as PDF'),
              _benefitRow('Unlimited Kannada text translation'),
              const SizedBox(height: 28),
              ElevatedButton.icon(
                onPressed: () async {
                  try {
                    await authService.signInWithGoogle();
                    if (context.mounted) onSuccess();
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(e.toString())),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.login_rounded, size: 22),
                label: const Text('Sign in with Google'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Menu listing Account, Upgrade (when not subscribed), Privacy Policy, Terms, About, Contact, Subscription info, Data safety.
class _InfoMenuPage extends StatelessWidget {
  const _InfoMenuPage({
    this.showUpgrade = true,
    this.onUpgrade,
    this.authService,
    this.ocrService,
    this.hasUpgraded = false,
    this.displayName,
    this.subscriptionExpiry,
    this.onSignOut,
  });

  final bool showUpgrade;
  final void Function(BuildContext)? onUpgrade;
  final AuthService? authService;
  final OCRService? ocrService;
  final bool hasUpgraded;
  final String? displayName;
  final String? subscriptionExpiry;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    const teal = Color(0xFF0D7377);
    final items = [
      (Icons.privacy_tip_outlined, 'Privacy Policy', kPrivacyPolicyTitle, kPrivacyPolicyBody),
      (Icons.description_outlined, 'Terms and Conditions', kTermsTitle, kTermsBody),
      (Icons.info_outline_rounded, 'About Us', kAboutTitle, kAboutBody),
      (Icons.email_outlined, 'Contact Us', kContactTitle, kContactBody),
      (Icons.card_membership_outlined, 'Subscription Info', kSubscriptionInfoTitle, kSubscriptionInfoBody),
      (Icons.security_outlined, 'Data Safety', kDataSafetyTitle, kDataSafetyBody),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Info & Legal'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: 1024 / 500,
                child: Image.asset(
                  'assets/feature-graphic.png',
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
          if (showUpgrade && onUpgrade != null)
            ListTile(
              leading: Icon(Icons.workspace_premium_rounded, color: teal, size: 24),
              title: const Text('Upgrade & Restore', style: TextStyle(fontWeight: FontWeight.w600)),
              subtitle: const Text('Subscribe to Pro or restore your purchase'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                onUpgrade!(context);
              },
            ),
          if (showUpgrade && onUpgrade != null) const Divider(height: 1),
          if (authService != null) ...[
            ListTile(
              leading: Icon(Icons.account_circle_outlined, color: teal, size: 24),
              title: const Text('Account', style: TextStyle(fontWeight: FontWeight.w600)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!context.mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => _ProfileAccountPage(
                        authService: authService!,
                        ocrService: ocrService,
                        isPremium: hasUpgraded,
                        initialDisplayName: displayName,
                        subscriptionExpiry: subscriptionExpiry,
                        onSignOut: onSignOut,
                      ),
                    ),
                  );
                });
              },
            ),
            const Divider(height: 1),
          ],
          ListTile(
            leading: Icon(Icons.ads_click_rounded, color: teal, size: 24),
            title: const Text('Privacy choices', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(
              'Change or withdraw ad consent (EEA, UK, CH)',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () async {
              await ConsentForm.showPrivacyOptionsForm((FormError? error) {
                if (!context.mounted) return;
                if (error != null) {
                  final msg = error.message.trim().isNotEmpty
                      ? error.message
                      : 'Privacy options are not available on this device or region.';
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(msg)),
                  );
                }
              });
            },
          ),
          const Divider(height: 1),
          ...List.generate(items.length, (index) {
            final (icon, label, title, body) = items[index];
            return ListTile(
              leading: Icon(icon, color: teal, size: 24),
              title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () {
                final isContact = title == kContactTitle;
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => _InfoContentPage(
                      title: title,
                      body: body,
                      contactEmail: isContact ? kContactEmail : null,
                    ),
                  ),
                );
              },
            );
          }),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
            child: FutureBuilder<PackageInfo>(
              future: PackageInfo.fromPlatform(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const SizedBox.shrink();
                final info = snapshot.data!;
                final versionText = info.buildNumber.isNotEmpty
                    ? '${info.version} (${info.buildNumber})'
                    : info.version;
                return Center(
                  child: Text(
                    'Version $versionText',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey.shade600,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Account: name, email, subscription status, validity/expiry, sign out.
class _ProfileAccountPage extends StatefulWidget {
  const _ProfileAccountPage({
    required this.authService,
    this.ocrService,
    required this.isPremium,
    this.initialDisplayName,
    this.subscriptionExpiry,
    this.onSignOut,
  });

  final AuthService authService;
  final OCRService? ocrService;
  final bool isPremium;
  final String? initialDisplayName;
  final String? subscriptionExpiry;
  final VoidCallback? onSignOut;

  @override
  State<_ProfileAccountPage> createState() => _ProfileAccountPageState();
}

class _ProfileAccountPageState extends State<_ProfileAccountPage> {
  String? _email;
  String? _displayName;
  String? _subscriptionExpiry;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _displayName = widget.initialDisplayName;
    _subscriptionExpiry = widget.subscriptionExpiry;
    _loadDetails();
  }

  Future<void> _loadDetails() async {
    final email = await widget.authService.currentEmail();
    final name = widget.initialDisplayName ?? await widget.authService.currentUserName();
    // Fetch fresh user status so we get subscription_expiry (valid until) from backend
    if (widget.isPremium && widget.ocrService != null) {
      final uid = await widget.authService.currentUserId();
      if (uid != null) {
        final status = await widget.ocrService!.getUserStatus(uid);
        if (mounted && status != null) {
          final expiry = status['subscription_expiry'] as String?;
          if (expiry != null && expiry.isNotEmpty) {
            setState(() => _subscriptionExpiry = expiry);
          }
        }
      }
    }
    if (mounted) {
      setState(() {
        _email = email;
        _displayName = name;
        _loading = false;
      });
    }
  }

  Future<void> _signOut() async {
    await widget.authService.signOut();
    if (!mounted) return;
    widget.onSignOut?.call();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  static const List<String> _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String _formatExpiry(String isoDate) {
    try {
      final dt = DateTime.parse(isoDate);
      return '${dt.day} ${_monthNames[dt.month - 1]} ${dt.year}';
    } catch (_) {
      return isoDate;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Account'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF0D7377)))
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _sectionTitle('Account'),
                  _detailCard(
                    icon: Icons.person_outline_rounded,
                    label: 'Name',
                    value: (_displayName != null && _displayName!.isNotEmpty) ? _displayName! : 'Guest',
                  ),
                  const SizedBox(height: 12),
                  _detailCard(
                    icon: Icons.email_outlined,
                    label: 'Email',
                    value: _email ?? 'Not signed in',
                  ),
                  const SizedBox(height: 12),
                  _detailCard(
                    icon: Icons.workspace_premium_rounded,
                    label: 'Subscription',
                    value: widget.isPremium ? 'Pro (active)' : 'Free',
                  ),
                  if (widget.isPremium && _subscriptionExpiry != null && _subscriptionExpiry!.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _detailCard(
                      icon: Icons.event_rounded,
                      label: 'Valid until',
                      value: _formatExpiry(_subscriptionExpiry!),
                    ),
                  ],
                  const SizedBox(height: 32),
                  if (_email != null && _email!.isNotEmpty)
                    TextButton.icon(
                      onPressed: _signOut,
                      icon: const Icon(Icons.logout_rounded, size: 20),
                      label: const Text('Sign out'),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red.shade700,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: Color(0xFF0D7377),
        ),
      ),
    );
  }

  Widget _detailCard({required IconData icon, required String label, required String value}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: const Color(0xFF0D7377)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF2D3436),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen scrollable content for one legal/info section.
class _InfoContentPage extends StatelessWidget {
  const _InfoContentPage({
    required this.title,
    required this.body,
    this.contactEmail,
  });

  final String title;
  final String body;
  final String? contactEmail;

  Future<void> _launchEmail(BuildContext context) async {
    final uri = Uri(scheme: 'mailto', path: contactEmail);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cannot open email app. Email: $contactEmail')),
        );
      }
    }
  }

  static const TextStyle _bodyStyle = TextStyle(
    fontSize: 15,
    height: 1.65,
    color: Color(0xFF2D3436),
  );

  static const TextStyle _subtitleStyle = TextStyle(
    fontSize: 16,
    height: 1.5,
    fontWeight: FontWeight.w700,
    color: Color(0xFF0D7377),
    letterSpacing: 0.2,
  );

  List<InlineSpan> _buildSpans(String text) {
    final spans = <InlineSpan>[];
    final lines = text.trim().split('\n');
    final subtitleRegex = RegExp(r'^\s*\*\*(.+?)\*\*\s*$');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        spans.add(const TextSpan(text: '\n'));
        continue;
      }
      final subtitleMatch = subtitleRegex.firstMatch(trimmed);
      if (subtitleMatch != null) {
        spans.add(TextSpan(text: '${subtitleMatch.group(1)!.trim()}\n', style: _subtitleStyle));
      } else {
        spans.addAll(_parseInlineBold(trimmed));
        spans.add(const TextSpan(text: '\n'));
      }
    }
    return spans;
  }

  List<InlineSpan> _parseInlineBold(String line) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'\*\*(.+?)\*\*');
    var start = 0;
    for (final match in pattern.allMatches(line)) {
      if (match.start > start) {
        spans.add(TextSpan(text: line.substring(start, match.start), style: _bodyStyle));
      }
      spans.add(TextSpan(text: match.group(1)!, style: _subtitleStyle));
      start = match.end;
    }
    if (start < line.length) {
      spans.add(TextSpan(text: line.substring(start), style: _bodyStyle));
    }
    return spans.isEmpty ? [TextSpan(text: line, style: _bodyStyle)] : spans;
  }

  @override
  Widget build(BuildContext context) {
    final spans = _buildSpans(body);
    final contentSpans = spans.isNotEmpty ? spans : [TextSpan(text: body, style: _bodyStyle)];

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: SelectableText.rich(
                TextSpan(style: _bodyStyle, children: contentSpans),
              ),
            ),
          ),
          if (contactEmail != null)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => _launchEmail(context),
                    icon: const Icon(Icons.email_rounded),
                    label: const Text('Send email'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _UpgradePage extends StatefulWidget {
  const _UpgradePage({
    required this.authService,
    this.onLinkSubscription,
    this.maybeLaterInterstitialKind,
  });
  final AuthService authService;
  final Future<void> Function(String? purchaseToken)? onLinkSubscription;
  /// When set (non-subscriber only), **Maybe later** shows an interstitial then pops the matching [UpgradeFlowResult].
  final _UpgradeInterstitialKind? maybeLaterInterstitialKind;

  @override
  State<_UpgradePage> createState() => _UpgradePageState();
}

class _UpgradePageState extends State<_UpgradePage> {
  IAPService? _iap;
  bool _storeReady = false;
  bool _loading = false;
  String? _error;
  String? _userName;
  Timer? _subscribeTimeout;

  @override
  void initState() {
    super.initState();
    widget.authService.currentUserName().then((name) {
      if (mounted && name != null && name.isNotEmpty) {
        setState(() => _userName = name);
      }
    });
    _iap = IAPService(
      onPurchaseSuccess: (String? purchaseToken) async {
        _subscribeTimeout?.cancel();
        _subscribeTimeout = null;
        await widget.onLinkSubscription?.call(purchaseToken);
        if (!mounted) return;
        setState(() => _loading = false);
        // Pop the upgrade screen on the next frame so we don't
        // navigate while the Navigator is locked by the billing flow.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Navigator.of(context).pop(UpgradeFlowResult.subscribed);
        });
      },
      onPurchaseCancelOrError: () {
        if (mounted) setState(() => _loading = false);
      },
    );
    _iap!.initialize().then((_) {
      if (!mounted) return;
      setState(() => _storeReady = _iap!.isAvailable);
      // We no longer auto-restore here; users can tap \"Restore purchases\"
      // or rely on the app's launch-time restore flow.
    });
  }

  @override
  void dispose() {
    _subscribeTimeout?.cancel();
    _iap?.dispose();
    super.dispose();
  }

  Future<void> _onSubscribe() async {
    if (!mounted) return;
    _subscribeTimeout?.cancel();
    setState(() { _loading = true; _error = null; });
    if (!await widget.authService.isSignedIn()) {
      final signedIn = await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (context) => _SignInPage(
            authService: widget.authService,
            forSubscription: true,
            onSuccess: () {
              Navigator.of(context).pop(true);
            },
          ),
        ),
      );
      if (!mounted) return;
      final name = await widget.authService.currentUserName();
      if (mounted) setState(() { _loading = false; if (name != null && name.isNotEmpty) _userName = name; });
      if (signedIn != true) return;
      if (mounted) setState(() => _loading = true);
    }
    if (!mounted) return;
    // Connect billing client and query subscription product when user taps Subscribe
    final connected = await _iap!.initialize();
    if (mounted) setState(() => _storeReady = _iap!.isAvailable);
    if (!connected || !_iap!.isAvailable) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'Billing is not available. Check your connection and try again.'; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Billing is not available. Check your connection.'), duration: Duration(seconds: 4)),
        );
      }
      return;
    }
    if (_iap!.productDetails == null) {
      await _iap!.loadProducts();
      if (mounted) setState(() {});
    }
    if (!mounted) return;
    if (_iap!.productDetails == null) {
      const productId = 'kannadabuddy_pro_monthly';
      setState(() {
        _loading = false;
        _error = 'Subscription not available yet. In Play Console add a subscription with ID “$productId” (Monetize → Subscriptions), activate it, and use a tester account.';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Add subscription “kannadabuddy_pro_monthly” in Play Console → Monetize → Subscriptions.'),
            duration: Duration(seconds: 5),
          ),
        );
      }
      return;
    }
    // Launch Google payment UI
    final ok = await _iap!.buy();
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _loading = false;
        _error = 'Billing uses the Play Store account on this device. If you see "Already subscribed", sign in to the app with that same Google account, or tap Restore.';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Subscription is tied to your Play Store account. Sign in to the app with that account to use Pro.'),
            duration: Duration(seconds: 5),
          ),
        );
      }
      return;
    }
    // If user already has subscription, Play may show "Already subscribed" and not send an event — stop loading after a timeout
    _subscribeTimeout?.cancel();
    _subscribeTimeout = Timer(const Duration(seconds: 25), () {
      if (!mounted) return;
      if (_loading) {
        setState(() {
          _loading = false;
          _error = 'The Play Store account on this device already has Pro. Sign in to the app with that same Google account to use Pro, or tap Restore to link it.';
        });
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Subscription is tied to your Play Store account. Sign in to the app with that same account.'),
            duration: Duration(seconds: 5),
          ),
        );
      }
    });
  }

  Future<void> _onRestore() async {
    if (_loading) return;
    _subscribeTimeout?.cancel();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _iap == null) return;
      setState(() { _loading = true; _error = null; });
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Restoring purchases…'), duration: Duration(seconds: 2)),
      );
      if (!_iap!.isAvailable) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = 'Billing is not available. Check your connection and try again.';
          });
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('Billing not available. Check connection.'), duration: Duration(seconds: 3)),
          );
        }
        return;
      }
      await _iap!.restore();
      if (!mounted) return;
      // Restore result comes via purchase stream; stop spinner shortly if no event
      _subscribeTimeout = Timer(const Duration(seconds: 5), () {
        if (!mounted) return;
        if (_loading) {
          setState(() {
            _loading = false;
            _error = 'No subscription found for the Play Store account on this device. Use the same Google account in the app and in Play Store, or Subscribe above.';
          });
        }
      });
    });
  }

  Future<void> _onMaybeLater() async {
    if (!mounted) return;
    final kind = widget.maybeLaterInterstitialKind;
    if (kind != null) {
      setState(() => _loading = true);
      await _runRewardInterstitial();
      if (!mounted) return;
      setState(() => _loading = false);
      final result = kind == _UpgradeInterstitialKind.copyShare
          ? UpgradeFlowResult.copyShareUnlockedViaAd
          : UpgradeFlowResult.mediaUnlockedViaAd;
      Navigator.of(context).pop(result);
      return;
    }
    Navigator.of(context).pop(UpgradeFlowResult.dismissed);
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(0xFF0D7377);
    const primaryLight = Color(0xFF14A3A8);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 16),
                    if (_userName != null && _userName!.isNotEmpty) ...[
                      Text(
                        'Welcome, $_userName',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: primary.withOpacity(0.9),
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                    ],
                    SizedBox(
                      height: 170,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Image.asset(
                          'assets/feature-graphic.png',
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    _benefitRow('Unlimited images & documents'),
                    _benefitRow('Copy results to clipboard'),
                    _benefitRow('Share as PDF'),
                    _benefitRow('Unlimited Kannada text translation'),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
                      decoration: BoxDecoration(
                        color: primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: primary.withOpacity(0.2), width: 1),
                      ),
                      child: Column(
                        children: [
                          Text(
                            _storeReady && _iap?.productDetails?.price != null
                                ? _iap!.productDetails!.price
                                : kSubscriptionPrice,
                            style: const TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.w800,
                              color: primary,
                              letterSpacing: -0.5,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'per $kSubscriptionPeriod',
                            style: TextStyle(
                              fontSize: 15,
                              color: primary.withOpacity(0.85),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Cancel anytime',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        style: TextStyle(color: Colors.red.shade700, fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Subscription uses the Google account in Play Store on this device. Sign in to the app with that same account to get Pro.',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.35),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _loading ? null : _onSubscribe,
                    style: FilledButton.styleFrom(
                      backgroundColor: primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      elevation: 0,
                    ),
                    child: _loading
                        ? const SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text('Subscribe — $kSubscriptionPrice/$kSubscriptionPeriod'),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _loading ? null : _onRestore,
                    child: Text('Restore purchases', style: TextStyle(color: Colors.grey.shade700)),
                  ),
                  const SizedBox(height: 4),
                  TextButton(
                    onPressed: _loading ? null : _onMaybeLater,
                    child: Text('Maybe later', style: TextStyle(color: Colors.grey.shade700)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _benefitRow(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle_rounded, color: const Color(0xFF0D7377), size: 24),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 16, color: Color(0xFF2D3436), height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultsPage extends StatefulWidget {
  final String kannada;
  final String transliteration;
  final String translation;
  final bool hasUpgraded;
  final void Function(String? purchaseToken)? onLinkSubscription;
  final Future<UpgradeFlowResult?> Function(BuildContext)? onRequestUpgrade;

  const _ResultsPage({
    required this.kannada,
    required this.transliteration,
    required this.translation,
    required this.hasUpgraded,
    this.onLinkSubscription,
    this.onRequestUpgrade,
  });

  @override
  State<_ResultsPage> createState() => _ResultsPageState();
}

class _ResultsPageState extends State<_ResultsPage> {
  late bool _isUpgraded;

  @override
  void initState() {
    super.initState();
    _isUpgraded = widget.hasUpgraded;
  }

  bool get _hasUpgraded => _isUpgraded;

  static const TextStyle _bodyTextStyle = TextStyle(
    fontSize: 16,
    height: 1.6,
    color: Color(0xFF2D3436),
  );

  Future<void> _refreshUpgradedAndRun(BuildContext context, Future<void> Function() action) async {
    final result = await widget.onRequestUpgrade?.call(context);
    if (!context.mounted) return;
    if (result == UpgradeFlowResult.subscribed) {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kKeyHasUpgraded) ?? false) {
        setState(() => _isUpgraded = true);
        await action();
      }
    } else if (result == UpgradeFlowResult.copyShareUnlockedViaAd) {
      setState(() => _isUpgraded = true);
      await action();
    }
  }

  Future<void> _saveAsPdf(BuildContext context, {required String title, required String content}) async {
    try {
      // Match app Results screen: clean sans-serif, 16pt body, clear diacritics (IAST/Latin)
      final baseFont = await PdfGoogleFonts.notoSansRegular();
      final boldFont = await PdfGoogleFonts.notoSansBold();
      final kannadaFallback = await PdfGoogleFonts.notoSansKannadaRegular();
      final theme = pw.ThemeData.withFont(
        base: baseFont,
        bold: boldFont,
        fontFallback: [kannadaFallback],
      );
      final pdf = pw.Document(theme: theme);
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(32),
          build: (pw.Context ctx) => [
            pw.Header(
              level: 0,
              child: pw.Text(title, style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
            ),
            pw.SizedBox(height: 16),
            pw.Paragraph(text: content, style: pw.TextStyle(fontSize: 16, font: baseFont)),
          ],
        ),
      );
      final bytes = await pdf.save();
      final fileName = 'KannadaBuddy_${title.replaceAll(' ', '_')}.pdf';
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(bytes);
      if (context.mounted) {
        await Share.shareXFiles([XFile(file.path)], subject: title, text: 'Save this PDF to your device');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Open the share menu to save or open the PDF')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not create PDF: $e')),
        );
      }
    }
  }

  Widget _buildTabContent(BuildContext context, {required String content, required String title, String? cardTitle}) {
    final theme = Theme.of(context);
    final displayTitle = cardTitle ?? title;
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: const Color(0xFF0D7377),
      letterSpacing: 0.2,
    ) ?? const TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w700,
      color: Color(0xFF0D7377),
      letterSpacing: 0.2,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF0D7377).withOpacity(0.12), width: 1),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF0D7377).withOpacity(0.06),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(displayTitle, style: titleStyle),
                      ),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          TextButton.icon(
                            onPressed: () async {
                              if (_hasUpgraded) {
                                await Clipboard.setData(ClipboardData(text: content));
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Copied to clipboard')),
                                  );
                                }
                              } else {
                                await _refreshUpgradedAndRun(context, () async {
                                  await Clipboard.setData(ClipboardData(text: content));
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Copied to clipboard')),
                                    );
                                  }
                                });
                              }
                            },
                            icon: const Icon(Icons.copy_rounded, size: 20),
                            label: const Text('Copy'),
                          ),
                          TextButton.icon(
                            onPressed: () async {
                              if (_hasUpgraded) {
                                await _saveAsPdf(context, title: title, content: content);
                              } else {
                                await _refreshUpgradedAndRun(context, () => _saveAsPdf(context, title: title, content: content));
                              }
                            },
                            icon: const Icon(Icons.share_rounded, size: 20),
                            label: const Text('Share'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SelectableText(content, style: _bodyTextStyle),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryTab(BuildContext context) {
    final theme = Theme.of(context);
    const labelStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.6,
      color: Color(0xFF0D7377),
    );
    const bodyStyle = TextStyle(
      fontSize: 16,
      height: 1.65,
      fontWeight: FontWeight.w400,
      color: Color(0xFF2D3436),
    );
    final kannadaLines = widget.kannada.split(RegExp(r'\r?\n'));
    final transliterationLines = widget.transliteration.split(RegExp(r'\r?\n'));
    final translationLines = widget.translation.split(RegExp(r'\r?\n'));
    final count = transliterationLines.length > translationLines.length
        ? transliterationLines.length
        : translationLines.length;
    final entries = <Widget>[];
    final summaryParts = <String>[];
    for (int i = 0; i < count; i++) {
      final inputKannada = i < kannadaLines.length ? kannadaLines[i].trim() : '';
      final transliterated = i < transliterationLines.length ? transliterationLines[i].trim() : '';
      final meaning = i < translationLines.length ? translationLines[i].trim() : '';
      if (transliterated.isEmpty && meaning.isEmpty) continue;
      summaryParts.add('Kannada: ${transliterated.isEmpty ? '—' : transliterated}\nMeaning: ${meaning.isEmpty ? '—' : meaning}');
      entries.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (entries.isNotEmpty)
                Divider(
                  height: 24,
                  thickness: 1,
                  color: const Color(0xFF0D7377).withOpacity(0.12),
                ),
              if (inputKannada.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 6),
                  child: SelectableText(inputKannada, style: bodyStyle),
                ),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: SelectableText.rich(
                  TextSpan(
                    style: bodyStyle,
                    children: [
                      TextSpan(text: 'Kannada: ', style: labelStyle),
                      TextSpan(text: transliterated.isEmpty ? '—' : transliterated),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: SelectableText.rich(
                  TextSpan(
                    style: bodyStyle,
                    children: [
                      TextSpan(text: 'Meaning: ', style: labelStyle),
                      TextSpan(text: meaning.isEmpty ? '—' : meaning),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (entries.isEmpty) {
      entries.add(
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText.rich(
                TextSpan(
                  style: bodyStyle,
                  children: [
                    TextSpan(text: 'Kannada: ', style: labelStyle),
                    const TextSpan(text: '—'),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              SelectableText.rich(
                TextSpan(
                  style: bodyStyle,
                  children: [
                    TextSpan(text: 'Meaning  ', style: labelStyle),
                    const TextSpan(text: '—'),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    final summaryText = summaryParts.isEmpty
        ? 'Kannada: —\nMeaning: —'
        : summaryParts.join('\n\n');
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 28),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF0D7377).withOpacity(0.12), width: 1),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF0D7377).withOpacity(0.06),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    'Summary',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF0D7377),
                      letterSpacing: 0.2,
                    ) ?? const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0D7377),
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: () async {
                        if (_hasUpgraded) {
                          await Clipboard.setData(ClipboardData(text: summaryText));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Copied to clipboard')),
                            );
                          }
                        } else {
                          await _refreshUpgradedAndRun(context, () async {
                            await Clipboard.setData(ClipboardData(text: summaryText));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Copied to clipboard')),
                              );
                            }
                          });
                        }
                      },
                      icon: const Icon(Icons.copy_rounded, size: 20),
                      label: const Text('Copy'),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        if (_hasUpgraded) {
                          await _saveAsPdf(context, title: 'Summary', content: summaryText);
                        } else {
                          await _refreshUpgradedAndRun(context, () => _saveAsPdf(context, title: 'Summary', content: summaryText));
                        }
                      },
                      icon: const Icon(Icons.share_rounded, size: 20),
                      label: const Text('Share'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            ...entries,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'Back to main menu',
          ),
          title: const Text('Results'),
          bottom: TabBar(
            indicator: BoxDecoration(
              color: Colors.white.withOpacity(0.28),
              borderRadius: BorderRadius.circular(10),
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
            tabs: [
              Tab(
                icon: SizedBox(
                  width: 24,
                  height: 24,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned(left: 0, top: 2, child: Icon(Icons.transcribe_rounded, size: 14)),
                      Positioned(right: 0, bottom: 2, child: Icon(Icons.translate_rounded, size: 14)),
                    ],
                  ),
                ),
                text: 'Summary',
              ),
              const Tab(icon: Icon(Icons.transcribe_rounded, size: 20), text: 'Transliteration'),
              const Tab(icon: Icon(Icons.translate_rounded, size: 20), text: 'Translation'),
            ],
          ),
        ),
        body: SafeArea(
          child: TabBarView(
            children: [
              _buildSummaryTab(context),
              _buildTabContent(context, content: widget.transliteration, title: 'Transliteration', cardTitle: 'Kannada'),
              _buildTabContent(context, content: widget.translation, title: 'Translation', cardTitle: 'Meaning'),
            ],
          ),
        ),
      ),
    );
  }
}