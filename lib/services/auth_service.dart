import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

const String _keyUserId = 'kannada_buddy_user_id';
const String _keyUserEmail = 'kannada_buddy_user_email';
const String _keyUserDisplayName = 'kannada_buddy_user_display_name';

/// Handles Google Sign-In and backend auth. Stores user_id and email locally.
class AuthService {
  AuthService({GoogleSignIn? googleSignIn})
      : _googleSignIn = googleSignIn ?? GoogleSignIn(scopes: ['email']);

  final GoogleSignIn _googleSignIn;
  static String get _baseUrl => ocrBaseUrl;

  int? get userId {
    // Synchronous read not possible from SharedPreferences; caller should use currentUserId().
    return null;
  }

  /// Returns current user id from prefs, or null if not signed in.
  Future<int?> currentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getInt(_keyUserId);
    return id;
  }

  /// Returns stored email or null.
  Future<String?> currentEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyUserEmail);
  }

  /// Returns stored display name or null (for signed-in users / subscribers).
  Future<String?> currentUserName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyUserDisplayName);
  }

  /// Returns true if we have a stored user_id (signed in).
  Future<bool> isSignedIn() async {
    final id = await currentUserId();
    return id != null;
  }

  /// Restore Google account on app start so sign-in persists. If we have no stored
  /// user_id but silent sign-in succeeds, re-register with backend and store user_id.
  Future<void> restoreSignInIfNeeded() async {
    try {
      final account = await _googleSignIn.signInSilently();
      if (account == null) return;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt(_keyUserId) != null) return;
      final auth = await account.authentication;
      final idToken = auth.idToken;
      final email = account.email ?? '';
      final uri = Uri.parse('$_baseUrl/auth/google');
      final name = account.displayName ?? '';
      final body = idToken != null && idToken.isNotEmpty
          ? jsonEncode({'id_token': idToken, 'display_name': name})
          : jsonEncode({'google_id': account.id, 'email': email, 'display_name': name});
      final response = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: body,
      );
      if (response.statusCode != 200) return;
      final data = _tryParseJson(response.body);
      final userId = data?['user_id'] as int?;
      if (userId != null) {
        await prefs.setInt(_keyUserId, userId);
        await prefs.setString(_keyUserEmail, (data?['email'] as String?) ?? email);
        final name = data?['display_name'] as String?;
        if (name != null && name.isNotEmpty) {
          await prefs.setString(_keyUserDisplayName, name);
        }
      }
    } catch (_) {}
  }

  /// Sign in with Google, register/login on backend, store user_id and email.
  /// Returns map with user_id, email, free_use_count, has_pro; throws on failure.
  Future<Map<String, dynamic>> signInWithGoogle() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) throw Exception('Sign in cancelled');

      final auth = await account.authentication;
    final idToken = auth.idToken;
    final email = account.email ?? '';

    final displayName = account.displayName ?? '';
    final uri = Uri.parse('$_baseUrl/auth/google');
    final body = idToken != null && idToken.isNotEmpty
        ? jsonEncode({'id_token': idToken, 'display_name': displayName})
        : jsonEncode({
            'google_id': account.id,
            'email': email,
            'display_name': displayName,
          });

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    final respBody = response.body;
    if (response.statusCode != 200) {
      final msg = _tryParseError(respBody) ??
          'Server error (${response.statusCode}) at $uri — check app_config.dart base URL and that app.py is running (or nginx proxies to it).';
      throw Exception(msg);
    }

    final data = _tryParseJson(respBody);
    if (data == null) {
      throw Exception(
        'Server returned a page instead of JSON at $uri — check app_config.dart (ocrBaseUrl) and that /auth/google is served by app.py.',
      );
    }
    final userId = data['user_id'] as int?;
    if (userId == null) throw Exception('Server did not return user_id');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyUserId, userId);
    await prefs.setString(_keyUserEmail, data['email'] as String? ?? email);
    final name = data['display_name'] as String?;
    if (name != null && name.isNotEmpty) {
      await prefs.setString(_keyUserDisplayName, name);
    }

    return Map<String, dynamic>.from(data);
    } catch (e, st) {
      // Log full error for "sign in failed R1 d 10" / DEVELOPER_ERROR (SHA-1 or package name mismatch).
      debugPrint('Google Sign-In error: $e');
      debugPrint('Stack: $st');
      rethrow;
    }
  }

  static String? _tryParseError(String body) {
    final data = _tryParseJson(body);
    if (data != null && data['error'] != null) return data['error'] as String?;
    if (body.trimLeft().startsWith('<')) return null;
    return body.length > 200 ? '${body.substring(0, 200)}…' : body;
  }

  static Map<String, dynamic>? _tryParseJson(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty || trimmed.startsWith('<')) return null;
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Sign out: clear local user and Google account.
  Future<void> signOut() async {
    await _googleSignIn.signOut();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUserId);
    await prefs.remove(_keyUserEmail);
    await prefs.remove(_keyUserDisplayName);
  }
}
