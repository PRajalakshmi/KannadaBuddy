import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../config/app_config.dart';
import '../models/ocr_result.dart';

class OCRService {
  static String get _baseUrl => ocrBaseUrl;

  Future<OcrResult> extractKannadaText(String imagePath) async {
    final uri = Uri.parse('$_baseUrl/ocr');
    final request = http.MultipartRequest('POST', uri)
      ..files.add(
        await http.MultipartFile.fromPath(
          'image',
          imagePath,
          contentType: MediaType('image', 'jpeg'),
        ),
      );
    return _sendMultipartAndParse(request);
  }

  /// Upload a document (PDF, DOC, DOCX, TXT, etc.) and get text + transliteration + translation.
  /// Submit plain Kannada text and get transliteration + translation.
  Future<OcrResult> submitKannadaText(String text) async {
    final uri = Uri.parse('$_baseUrl/text');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'text': text}),
    );
    final body = response.body;
    if (response.statusCode != 200) {
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        throw Exception(json['error'] as String? ?? body);
      } catch (_) {
        throw Exception('Server error: $body');
      }
    }
    final json = jsonDecode(body) as Map<String, dynamic>;
    if (json.containsKey('error')) {
      throw Exception(json['error'] as String);
    }
    return OcrResult(
      text: (json['text'] ?? '') as String,
      transliteration: (json['transliteration'] ?? '') as String,
      translation: (json['translation'] ?? '') as String,
    );
  }

  Future<OcrResult> extractFromDocument(String filePath) async {
    final uri = Uri.parse('$_baseUrl/document');
    final fileName = filePath.split(RegExp(r'[/\\]')).last;
    final ext = fileName.split('.').last.toLowerCase();

    final request = http.MultipartRequest('POST', uri)
      ..files.add(
        await http.MultipartFile.fromPath(
          'document',
          filePath,
          filename: fileName,
          contentType: MediaType(
            ext == 'txt' ? 'text' : 'application',
            ext == 'txt' ? 'plain' : (ext == 'pdf' ? 'pdf' : 'octet-stream'),
          ),
        ),
      );

    return _sendMultipartAndParse(request);
  }

  Future<OcrResult> _sendMultipartAndParse(http.MultipartRequest request) async {
    final streamedResponse = await request.send();
    final body = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode != 200) {
      throw Exception('Server error: $body');
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    if (json.containsKey('error')) {
      throw Exception(json['error'] as String);
    }
    return OcrResult(
      text: (json['text'] ?? '') as String,
      transliteration: (json['transliteration'] ?? '') as String,
      translation: (json['translation'] ?? '') as String,
    );
  }
}