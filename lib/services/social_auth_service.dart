import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

class SocialAuthService {
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      'email',
      'https://www.googleapis.com/auth/userinfo.profile',
    ],
  );

  Future<Map<String, String?>?> signInWithGoogle() async {
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) return null; // User cancelled the selection

      return {
        'name': googleUser.displayName,
        'email': googleUser.email,
        'photoUrl': googleUser.photoUrl,
        'id': googleUser.id,
      };
    } catch (e) {
      print('Error Google Sign-In: $e');
      rethrow;
    }
  }

  Future<Map<String, String?>?> signInWithApple() async {
    try {
      // Apple Sign-In only works on iOS/macOS natively, or via JS on Web.
      // On Android it requires a different setup (serviceId/redirectUri).
      if (!kIsWeb && !Platform.isIOS && !Platform.isMacOS) {
        throw Exception('Apple Sign-In is only supported on iOS/macOS for this implementation.');
      }

      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

      return {
        'name': '${credential.givenName ?? ''} ${credential.familyName ?? ''}'.trim(),
        'email': credential.email,
        'id': credential.userIdentifier,
      };
    } catch (e) {
      print('Error Apple Sign-In: $e');
      rethrow;
    }
  }
}
