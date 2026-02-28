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
import 'services/iap_service.dart';
import 'services/ocr_service.dart';

// Monetization: 2 free file/image uses, then upgrade. Copy & Share require upgrade.
const int _kFreeUseLimit = 5;
const String _kKeyFreeUseCount = 'kannada_buddy_free_use_count';
const String _kKeyHasUpgraded = 'kannada_buddy_has_upgraded';
// Subscription price (single place for Play Store / future IAP).
const String kSubscriptionPrice = '₹99';
const String kSubscriptionPeriod = 'month';
// Minimum English word count we require for image/document translations
// to avoid obviously incomplete outputs. For very short text, prefer the
// typed Kannada input instead of image/document upload.
const int _kMinEnglishWordsForImageDoc = 8;

/// Message when image/document could not be read or translation is not meaningful.
const String _kUnreadableMessage =
    'We could not reliably read or translate this input. Please upload a clearer image or document and try again. '
    'Avoid blur, poor lighting, shadows, fingers or objects covering the text, cluttered backgrounds, and skewed or angled pages. '
    'Use a sharp, well-lit image cropped to the text only, with nothing obscuring the words.';

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
bool _isTranslationMeaningful(
  String sourceText,
  String translation, {
  String? transliteration,
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
  final minWords = (srcWords / 3).ceil().clamp(1, 999);
  if (dstWords < minWords) return false;

  // Long source (e.g. full page): translation must not be disproportionately short by character length.
  if (srcLen > 300 && dstLen < srcLen / 5) return false;

  // For image/doc: if transliteration is provided, run strict translation-vs-transliteration checks.
  if (transliteration != null && srcWords > 10) {
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

/// User-friendly message when server is unreachable.
String _serverErrorMessage(Object e) {
  final s = e.toString().toLowerCase();
  if (s.contains('socket') || s.contains('no route to host') ||
      s.contains('connection refused') || s.contains('network is unreachable') ||
      s.contains('failed host lookup')) {
    return 'Cannot reach server. Check:\n'
        '• Server is running at the URL in lib/config/app_config.dart (default: kannada.astrostarveda.com)\n'
        '• Device has internet and can reach that host';
  }
  return e.toString();
}

void main() {
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
  final OCRService ocrService = OCRService();
  final TextEditingController _kannadaController = TextEditingController();
  final FocusNode _kannadaFocusNode = FocusNode();
  final PageController _keyboardPageController = PageController();
  static final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  void _onKannadaFocusChange() {
    setState(() => _showKannadaKeyboard = _kannadaFocusNode.hasFocus);
  }

  void _hideKannadaKeyboardAndClearResults() {
    _kannadaFocusNode.unfocus();
    _kannadaController.clear();
    setState(() {
      transliteration = '';
      translation = '';
      errorMessage = null;
    });
  }

  @override
  void initState() {
    super.initState();
    _kannadaFocusNode.addListener(_onKannadaFocusChange);
    _loadMonetizationState();
  }

  Future<void> _loadMonetizationState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _freeUseCount = prefs.getInt(_kKeyFreeUseCount) ?? 0;
        _hasUpgraded = prefs.getBool(_kKeyHasUpgraded) ?? false;
      });
    } catch (_) {}
  }

  Future<void> _incrementFreeUse() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kKeyFreeUseCount, (prefs.getInt(_kKeyFreeUseCount) ?? 0) + 1);
    if (mounted) await _loadMonetizationState();
  }

  @override
  void dispose() {
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

  void _navigateToResults(String kannada, String transliteration, String translation) {
    _navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (context) => _ResultsPage(
          kannada: kannada,
          transliteration: transliteration,
          translation: translation,
          hasUpgraded: _hasUpgraded,
        ),
      ),
    );
  }

  /// Returns true if the user can proceed (under free limit or upgraded).
  Future<bool> _showUpgradeIfNeeded() async {
    if (_hasUpgraded || _freeUseCount < _kFreeUseLimit) return true;
    final upgraded = await _navigatorKey.currentState?.push<bool>(
      MaterialPageRoute<bool>(builder: (context) => const _UpgradePage()),
    );
    if (upgraded == true && mounted) await _loadMonetizationState();
    return upgraded == true;
  }

  Future<void> _translateTypedText() async {
    final text = _kannadaController.text.trim();
    if (text.isEmpty) return;
    // Text box is unlimited; only gallery & document count toward free attempts.
    setState(() {
      transliteration = '';
      translation = '';
      errorMessage = null;
      _isLoading = true;
    });
    _startProgressAnimation();
    try {
      final result = await ocrService.submitKannadaText(text);
      if (!mounted) return;
      _completeProgress();
      if (!_isTranslationMeaningful(text, result.translation)) {
        setState(() => errorMessage = _kUnreadableMessage);
        return;
      }
      _kannadaController.clear();
      _navigateToResults(result.text, result.transliteration, result.translation);
    } catch (e) {
      if (mounted) {
        setState(() => errorMessage = _serverErrorMessage(e));
        _completeProgress();
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
    if (key == 'space') {
      _kannadaController.text += ' ';
      return;
    }
    // Dotted-circle + ottakshara keys: insert only the ottakshara part so it combines with preceding consonant
    if (key.startsWith(_kannadaDottedCircle)) {
      _kannadaController.text += key.substring(_kannadaDottedCircle.length);
      return;
    }
    _kannadaController.text += key;
  }

  Future<void> _processPickedFile(XFile pickedFile) async {
    setState(() { _isLoading = true; errorMessage = null; });
    _startProgressAnimation();
    try {
      final result = await ocrService.extractKannadaText(pickedFile.path);
      if (!mounted) return;
      _completeProgress();
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
        setState(() => errorMessage = _kUnreadableMessage);
        return;
      }
      if (!_hasUpgraded) await _incrementFreeUse();
      _navigateToResults(result.text, result.transliteration, result.translation);
    } catch (e) {
      if (mounted) {
        setState(() => errorMessage = _serverErrorMessage(e));
        _completeProgress();
      }
    }
  }

  Future<void> scanImageFromGallery() async {
    _hideKannadaKeyboardAndClearResults();
    if (!await _showUpgradeIfNeeded()) return;
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      await _processPickedFile(pickedFile);
    }
  }

  Future<void> readFromDocument() async {
    _hideKannadaKeyboardAndClearResults();
    if (!await _showUpgradeIfNeeded()) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'doc', 'docx', 'txt'],
      withData: false,
      withReadStream: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null || path.isEmpty) {
      setState(() {
        errorMessage = 'Could not get file path. Try saving the file to device first.';
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
    });
    _startProgressAnimation();
    try {
      final docResult = await ocrService.extractFromDocument(path);
      if (!mounted) return;
      _completeProgress();
      final text = docResult.text.trim();
      final hasText = text.isNotEmpty;
      final englishWords = _englishWordCount(docResult.translation);
      if (!hasText ||
          englishWords < _kMinEnglishWordsForImageDoc ||
          !_isTranslationMeaningful(
            text,
            docResult.translation,
            transliteration: docResult.transliteration,
          )) {
        setState(() => errorMessage = _kUnreadableMessage);
        return;
      }
      if (!_hasUpgraded) await _incrementFreeUse();
      _navigateToResults(docResult.text, docResult.transliteration, docResult.translation);
    } catch (e) {
      if (mounted) {
        setState(() => errorMessage = _serverErrorMessage(e));
        _completeProgress();
      }
    }
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
                final upgraded = await _navigatorKey.currentState?.push<bool>(
                  MaterialPageRoute<bool>(builder: (context) => const _UpgradePage()),
                );
                if (upgraded == true && mounted) await _loadMonetizationState();
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
          title: const Text('KannadaBuddy'),
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
                child: Text(
                  'Or type in Kannada',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: const Color(0xFF2D3436).withOpacity( 0.7),
                  ),
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
                    style: const TextStyle(fontSize: 18, height: 1.5),
                    decoration: InputDecoration(
                      hintText: 'Tap to use Kannada keyboard…',
                      hintStyle: TextStyle(
                        color: const Color(0xFF2D3436).withOpacity( 0.4),
                        fontSize: 16,
                      ),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.all(16),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.content_paste_rounded, color: Color(0xFF0D7377)),
                        tooltip: 'Paste from clipboard',
                        onPressed: () async {
                          final data = await Clipboard.getData(Clipboard.kTextPlain);
                          if (data != null && data.text != null && data.text!.isNotEmpty) {
                            _kannadaController.text += data.text!;
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
                      children: [
                        Icon(Icons.info_outline_rounded, size: 20, color: const Color(0xFFE74C3C)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            errorMessage!,
                            style: const TextStyle(color: Color(0xFFC0392B), fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
                const SizedBox(height: 20),
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

class _UpgradePage extends StatefulWidget {
  const _UpgradePage();

  @override
  State<_UpgradePage> createState() => _UpgradePageState();
}

class _UpgradePageState extends State<_UpgradePage> {
  IAPService? _iap;
  bool _storeReady = false;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _iap = IAPService(
      onPurchaseSuccess: () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kKeyHasUpgraded, true);
        if (!mounted) return;
        setState(() => _loading = false);
        Navigator.of(context).pop(true);
      },
      onPurchaseCancelOrError: () {
        if (mounted) setState(() => _loading = false);
      },
    );
    _iap!.initialize().then((_) {
      if (mounted) setState(() => _storeReady = _iap!.isAvailable);
    });
  }

  @override
  void dispose() {
    _iap?.dispose();
    super.dispose();
  }

  Future<void> _onSubscribe() async {
    setState(() { _loading = true; _error = null; });
    if (_iap!.isAvailable && _iap!.productDetails != null) {
      final ok = await _iap!.buy();
      if (!mounted) return;
      if (!ok) {
        setState(() { _loading = false; _error = 'Could not start purchase.'; });
      }
    } else {
      if (kDebugMode) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kKeyHasUpgraded, true);
        if (mounted) Navigator.of(context).pop(true);
      } else {
        setState(() {
          _loading = false;
          _error = 'Store not available. Try again later.';
        });
      }
    }
  }

  Future<void> _onRestore() async {
    setState(() { _loading = true; _error = null; });
    await _iap?.restore();
    if (!mounted) return;
    setState(() => _loading = false);
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
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [primary, primaryLight],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: primary.withOpacity(0.35),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: Column(
                        children: [
                          Icon(Icons.workspace_premium_rounded, size: 52, color: Colors.white.withOpacity(0.95)),
                          const SizedBox(height: 12),
                          const Text(
                            'Unlock full access',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Get transliteration & translation without limits',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 15,
                              color: Colors.white.withOpacity(0.9),
                              height: 1.35,
                            ),
                          ),
                        ],
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
                    onPressed: _loading ? null : () => Navigator.of(context).pop(false),
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

  const _ResultsPage({
    required this.kannada,
    required this.transliteration,
    required this.translation,
    required this.hasUpgraded,
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
    final upgraded = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (context) => const _UpgradePage()),
    );
    if (upgraded != true || !context.mounted) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kKeyHasUpgraded) ?? false) {
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
    final transliterationLines = widget.transliteration.split(RegExp(r'\r?\n'));
    final translationLines = widget.translation.split(RegExp(r'\r?\n'));
    final count = transliterationLines.length > translationLines.length
        ? transliterationLines.length
        : translationLines.length;
    final entries = <Widget>[];
    final summaryParts = <String>[];
    for (int i = 0; i < count; i++) {
      final transliterated = i < transliterationLines.length ? transliterationLines[i].trim() : '';
      final meaning = i < translationLines.length ? translationLines[i].trim() : '';
      if (transliterated.isEmpty && meaning.isEmpty) continue;
      summaryParts.add('Kannada  ${transliterated.isEmpty ? '—' : transliterated}\nMeaning  ${meaning.isEmpty ? '—' : meaning}');
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
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: SelectableText.rich(
                  TextSpan(
                    style: bodyStyle,
                    children: [
                      TextSpan(text: 'Kannada  ', style: labelStyle),
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
                      TextSpan(text: 'Meaning  ', style: labelStyle),
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
                    TextSpan(text: 'Kannada  ', style: labelStyle),
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
        ? 'Kannada  —\nMeaning  —'
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