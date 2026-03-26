/// App-wide configuration. Avoid hardcoding URLs and secrets in source.
///
/// This URL must match where app.py is running (server listens on port 5001).
/// Timeout/refused? 1) Start server: cd server && source .venv/bin/activate && python app.py
/// 2) Use your Mac's LAN IP so emulator can reach it (10.0.2.2 can timeout on some setups).
/// - Android emulator / physical device: http://YOUR_MAC_IP:5001 (e.g. 192.168.1.9)
/// - Same machine (Chrome/desktop): http://localhost:5001
///
/// For release builds override via dart-define:
///   flutter build appbundle --dart-define=OCR_BASE_URL=https://your-domain.com
const String ocrBaseUrl = String.fromEnvironment(
  'OCR_BASE_URL',
  //defaultValue: 'http://192.168.1.9:5001',
  // defaultValue: 'http://192.168.1.11:5001',
  // defaultValue: 'http://10.0.2.2:5001',
  // defaultValue: 'http://localhost:5001',
   defaultValue: 'https://kannada.astrostarveda.com',
);
