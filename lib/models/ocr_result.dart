/// Result of OCR with optional transliteration and translation.
class OcrResult {
  final String text;
  final String transliteration;
  final String translation;

  const OcrResult({
    required this.text,
    this.transliteration = '',
    this.translation = '',
  });
}
