/// App-wide configuration. Avoid hardcoding URLs and secrets in source.
///
/// This URL must match where app.py is running.
/// Local: Android emulator use http://10.0.2.2:5001 | Physical device use http://YOUR_MAC_IP:5001 (e.g. 192.168.1.11).
///
/// For release builds override via dart-define:
///   flutter build appbundle --dart-define=OCR_BASE_URL=https://your-domain.com
const String ocrBaseUrl = String.fromEnvironment(
  'OCR_BASE_URL',
  //defaultValue: 'http://192.168.1.11:5001',
   defaultValue: 'https://kannada.astrostarveda.com',
);
