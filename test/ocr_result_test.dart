import 'package:flutter_test/flutter_test.dart';
import 'package:kanndabuddy/models/ocr_result.dart';

void main() {
  group('OcrResult', () {
    test('creates with required text and optional transliteration and translation', () {
      const result = OcrResult(
        text: 'ಕನ್ನಡ',
        transliteration: 'kannada',
        translation: 'Kannada',
      );
      expect(result.text, 'ಕನ್ನಡ');
      expect(result.transliteration, 'kannada');
      expect(result.translation, 'Kannada');
    });

    test('defaults transliteration and translation to empty string', () {
      const result = OcrResult(text: 'hello');
      expect(result.text, 'hello');
      expect(result.transliteration, '');
      expect(result.translation, '');
    });

    test('holds empty strings for all fields', () {
      const result = OcrResult(text: '', transliteration: '', translation: '');
      expect(result.text, '');
      expect(result.transliteration, '');
      expect(result.translation, '');
    });
  });
}
