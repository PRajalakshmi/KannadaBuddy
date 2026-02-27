/// App-wide configuration. Avoid hardcoding URLs and secrets in source.
///
/// For release/Play Store builds, set the OCR server URL via dart-define:
///   flutter build apk --dart-define=OCR_BASE_URL=https://your-api.example.com
///   flutter build appbundle --dart-define=OCR_BASE_URL=https://your-api.example.com
///
/// If not set, defaults to a local dev URL (app will only work on same network).
const String ocrBaseUrl = String.fromEnvironment(
  'OCR_BASE_URL',
  defaultValue: 'http://192.168.1.11:5001',
);
