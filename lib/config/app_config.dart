/// App-wide configuration. Avoid hardcoding URLs and secrets in source.
///
/// This URL must match where app.py is running (e.g. your external server).
/// Default: https://kannada.astrostarveda.com
///
/// For release builds you can override via dart-define:
///   flutter build appbundle --dart-define=OCR_BASE_URL=https://your-domain.com
const String ocrBaseUrl = String.fromEnvironment(
  'OCR_BASE_URL',
  defaultValue: 'https://kannada.astrostarveda.com',
);
