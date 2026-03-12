import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../config/app_config.dart';
import '../models/ocr_result.dart';

class OCRService {
  static String get _baseUrl => ocrBaseUrl;

  /// Server/nginx sometimes returns HTML (502, 413, wrong path). jsonDecode then throws FormatException.
  static void _ensureJsonBody(String body, {String context = 'Server'}) {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('<') ||
        trimmed.startsWith('<!') ||
        trimmed.toLowerCase().contains('<html')) {
      final hint = trimmed.contains('413') || trimmed.toLowerCase().contains('large')
          ? 'File too large for server (nginx client_max_body_size).'
          : trimmed.contains('502') || trimmed.contains('Bad Gateway')
              ? 'Backend unreachable (502).'
              : 'Proxy returned a web page instead of JSON—check API URL and nginx config.';
      throw Exception('$context: $hint');
    }
  }

  /// Headers to send with each request when user is signed in (X-User-Id).
  Map<String, String> _headers(int? userId) {
    final h = <String, String>{};
    if (userId != null) h['X-User-Id'] = userId.toString();
    return h;
  }

  Future<OcrResult> extractKannadaText(String imagePath, {int? userId}) async {
    final uri = Uri.parse('$_baseUrl/ocr');
    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(_headers(userId))
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
  Future<OcrResult> submitKannadaText(String text, {int? userId}) async {
    final uri = Uri.parse('$_baseUrl/text');
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        ..._headers(userId),
      },
      body: jsonEncode({'text': text}),
    );
    final body = response.body;
    if (response.statusCode == 403) {
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        throw Exception(json['error'] as String? ?? 'Free quota exceeded');
      } catch (e) {
        if (e is Exception) rethrow;
        throw Exception('Free quota exceeded');
      }
    }
    if (response.statusCode != 200) {
      _ensureJsonBody(body, context: 'Document/text');
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        throw Exception(json['error'] as String? ?? body);
      } catch (e) {
        if (e is Exception) rethrow;
        throw Exception('Server error (${response.statusCode})');
      }
    }
    _ensureJsonBody(body, context: 'Document/text');
    final json = jsonDecode(body) as Map<String, dynamic>;
    if (json.containsKey('error')) {
      throw Exception(json['error'] as String);
    }
    return OcrResult(
      text: (json['text'] ?? '') as String,
      transliteration: (json['transliteration'] ?? '') as String,
      translation: (json['translation'] ?? '') as String,
      userStatus: json['user_status'] as Map<String, dynamic>?,
    );
  }

  Future<OcrResult> extractFromDocument(String filePath, {int? userId}) async {
    final uri = Uri.parse('$_baseUrl/document');
    final fileName = filePath.split(RegExp(r'[/\\]')).last;
    final ext = fileName.split('.').last.toLowerCase();

    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(_headers(userId))
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

    if (streamedResponse.statusCode == 403) {
      _ensureJsonBody(body, context: 'Upload');
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        throw Exception(json['error'] as String? ?? 'Free quota exceeded');
      } catch (e) {
        if (e is Exception) rethrow;
        throw Exception('Free quota exceeded');
      }
    }
    if (streamedResponse.statusCode != 200) {
      _ensureJsonBody(body, context: 'Upload');
      // Propagate server JSON error so UI can show "use DOCX" etc. instead of generic failed.
      try {
        final json = jsonDecode(body) as Map<String, dynamic>;
        final err = json['error'] as String?;
        if (err != null && err.isNotEmpty) throw Exception(err);
      } catch (e) {
        if (e is Exception) rethrow;
      }
      throw Exception(
        'Server error (${streamedResponse.statusCode}). '
        'If uploading a large PDF, increase nginx client_max_body_size.',
      );
    }

    _ensureJsonBody(body, context: 'Upload');
    final json = jsonDecode(body) as Map<String, dynamic>;
    if (json.containsKey('error')) {
      throw Exception(json['error'] as String);
    }
    return OcrResult(
      text: (json['text'] ?? '') as String,
      transliteration: (json['transliteration'] ?? '') as String,
      translation: (json['translation'] ?? '') as String,
      userStatus: json['user_status'] as Map<String, dynamic>?,
    );
  }

  /// Link purchase token to the signed-in user on the backend. Backend verifies with Google Play,
  /// stores expiry in DB, and returns user_status. Returns the response map or null on error.
  Future<Map<String, dynamic>?> linkSubscription(int userId, String purchaseToken, {String platform = 'android'}) async {
    final uri = Uri.parse('$_baseUrl/user/subscription');
    final response = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'X-User-Id': userId.toString(),
      },
      body: jsonEncode({'purchase_token': purchaseToken, 'platform': platform}),
    );
    if (response.statusCode != 200) {
      throw Exception(response.body);
    }
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      return body;
    } catch (_) {
      return null;
    }
  }

  /// Fetch user status (free_use_count, has_pro) from backend.
  Future<Map<String, dynamic>?> getUserStatus(int userId) async {
    final uri = Uri.parse('$_baseUrl/user/status');
    final response = await http.get(
      uri,
      headers: {'X-User-Id': userId.toString()},
    );
    if (response.statusCode != 200) return null;
    try {
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }
}