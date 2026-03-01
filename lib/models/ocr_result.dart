/// Result of OCR with optional transliteration and translation.
/// [userStatus] is set when the backend returns quota/Pro info after the request.
class OcrResult {
  final String text;
  final String transliteration;
  final String translation;
  /// From backend: { free_use_count, free_use_limit, has_pro }.
  final Map<String, dynamic>? userStatus;

  const OcrResult({
    required this.text,
    this.transliteration = '',
    this.translation = '',
    this.userStatus,
  });
}
