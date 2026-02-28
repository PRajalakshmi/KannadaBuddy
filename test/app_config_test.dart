import 'package:flutter_test/flutter_test.dart';
import 'package:kanndabuddy/config/app_config.dart';

void main() {
  group('App config', () {
    test('ocrBaseUrl is non-empty', () {
      expect(ocrBaseUrl, isNotEmpty);
    });

    test('ocrBaseUrl is a valid URL format', () {
      expect(
        ocrBaseUrl.startsWith('http://') || ocrBaseUrl.startsWith('https://'),
        isTrue,
      );
    });
  });
}
