import 'dart:convert';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';

const String _keyUserId = 'kannada_buddy_user_id';
const String _keyUserEmail = 'kannada_buddy_user_email';

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

  /// Returns true if we have a stored user_id (signed in).
  Future<bool> isSignedIn() async {
    final id = await currentUserId();
    return id != null;
  }

  /// Sign in with Google, register/login on backend, store user_id and email.
  /// Returns map with user_id, email, free_use_count, has_pro; throws on failure.
  Future<Map<String, dynamic>> signInWithGoogle() async {
    final account = await _googleSignIn.signIn();
    if (account == null) throw Exception('Sign in cancelled');

    final auth = await account.authentication;
    final idToken = auth.idToken;
    final email = account.email ?? '';

    final uri = Uri.parse('$_baseUrl/auth/google');
    final body = idToken != null && idToken.isNotEmpty
        ? jsonEncode({'id_token': idToken})
        : jsonEncode({
            'google_id': account.id,
            'email': email,
          });

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    final respBody = response.body;
    if (response.statusCode != 200) {
      try {
        final json = jsonDecode(respBody) as Map<String, dynamic>;
        throw Exception(json['error'] as String? ?? respBody);
      } catch (e) {
        if (e is Exception) rethrow;
        throw Exception('Auth failed: $respBody');
      }
    }

    final data = jsonDecode(respBody) as Map<String, dynamic>;
    final userId = data['user_id'] as int?;
    if (userId == null) throw Exception('Server did not return user_id');

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyUserId, userId);
    await prefs.setString(_keyUserEmail, data['email'] as String? ?? email);

    return Map<String, dynamic>.from(data);
  }

  /// Sign out: clear local user and Google account.
  Future<void> signOut() async {
    await _googleSignIn.signOut();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUserId);
    await prefs.remove(_keyUserEmail);
  }
}
