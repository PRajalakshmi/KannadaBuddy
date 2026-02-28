import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:kanndabuddy/models/ocr_result.dart';
import 'package:kanndabuddy/services/ocr_service.dart';
import 'package:mocktail/mocktail.dart';

class MockHttpClient extends Mock implements http.Client {}

void main() {
  late MockHttpClient mockClient;

  setUpAll(() {
    registerFallbackValue(Uri());
    registerFallbackValue(<String, String>{});
  });

  setUp(() {
    mockClient = MockHttpClient();
  });

  group('OCRService.submitKannadaText', () {
    test('parses successful JSON response into OcrResult', () async {
      // Use ASCII so response.body decoding is consistent across platforms
      const text = 'kannada';
      const transliteration = 'kannada';
      const translation = 'Kannada';
      final jsonBody = jsonEncode({
        'text': text,
        'transliteration': transliteration,
        'translation': translation,
      });
      when(() => mockClient.post(any(), headers: any(named: 'headers'), body: any(named: 'body'), encoding: any(named: 'encoding')))
          .thenAnswer((_) async => http.Response(jsonBody, 200));

      final result = await http.runWithClient(() async {
        return await OCRService().submitKannadaText(text);
      }, () => mockClient);

      expect(result, isA<OcrResult>());
      expect(result.text, text);
      expect(result.transliteration, transliteration);
      expect(result.translation, translation);
    });

    test('handles missing optional fields with empty string', () async {
      final json = jsonEncode({'text': 'x'});
      when(() => mockClient.post(any(), headers: any(named: 'headers'), body: any(named: 'body'), encoding: any(named: 'encoding')))
          .thenAnswer((_) async => http.Response(json, 200));

      final result = await http.runWithClient(() async {
        return await OCRService().submitKannadaText('x');
      }, () => mockClient);

      expect(result.text, 'x');
      expect(result.transliteration, '');
      expect(result.translation, '');
    });

    test('throws when response has error key', () async {
      final json = jsonEncode({'error': 'Invalid input'});
      when(() => mockClient.post(any(), headers: any(named: 'headers'), body: any(named: 'body'), encoding: any(named: 'encoding')))
          .thenAnswer((_) async => http.Response(json, 200));

      expect(
        () => http.runWithClient(() async {
          return await OCRService().submitKannadaText('bad');
        }, () => mockClient),
        throwsA(isA<Exception>().having((e) => e.toString(), 'message', contains('Invalid input'))),
      );
    });

    test('throws when status code is not 200', () async {
      when(() => mockClient.post(any(), headers: any(named: 'headers'), body: any(named: 'body'), encoding: any(named: 'encoding')))
          .thenAnswer((_) async => http.Response('Server error', 500));

      expect(
        () => http.runWithClient(() async {
          return await OCRService().submitKannadaText('x');
        }, () => mockClient),
        throwsA(isA<Exception>()),
      );
    });
  });
}
