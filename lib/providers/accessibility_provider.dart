// providers/accessibility_provider.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'package:shared_preferences/shared_preferences.dart';

class VoiceFeedbackNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return false;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool('voiceFeedbackEnabled') ?? false;

    final uid = firebase.FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
        if (doc.exists && doc.data()?['voiceFeedbackEnabled'] is bool) {
          final cloudVal = doc.data()!['voiceFeedbackEnabled'] as bool;
          if (cloudVal != state) {
            state = cloudVal;
            await prefs.setBool('voiceFeedbackEnabled', cloudVal);
          }
        }
      } catch (_) {}
    }
  }

  Future<void> toggle(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('voiceFeedbackEnabled', value);

    final uid = firebase.FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({'voiceFeedbackEnabled': value})
          .catchError((_) {});
    }
  }

  Future<void> resetToDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('voiceFeedbackEnabled');
    state = false;
  }

  Future<void> syncFromUserDoc(Map<String, dynamic> data) async {
    if (data['voiceFeedbackEnabled'] is bool) {
      final val = data['voiceFeedbackEnabled'] as bool;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('voiceFeedbackEnabled', val);
      state = val;
    }
  }
}

class ShowTextFeedbackNotifier extends Notifier<bool> {
  @override
  bool build() {
    _load();
    return true; // Default to true
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool('visualAlertsEnabled') ?? true;

    final uid = firebase.FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
        if (doc.exists && doc.data()?['visualAlertsEnabled'] is bool) {
          final cloudVal = doc.data()!['visualAlertsEnabled'] as bool;
          if (cloudVal != state) {
            state = cloudVal;
            await prefs.setBool('visualAlertsEnabled', cloudVal);
          }
        }
      } catch (_) {}
    }
  }

  Future<void> resetToDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('visualAlertsEnabled');
    state = true;
  }

  Future<void> syncFromUserDoc(Map<String, dynamic> data) async {
    if (data['visualAlertsEnabled'] is bool) {
      final val = data['visualAlertsEnabled'] as bool;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('visualAlertsEnabled', val);
      state = val;
    }
  }

  Future<void> toggle(bool value) async {
    state = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('visualAlertsEnabled', value);

    final uid = firebase.FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update({'visualAlertsEnabled': value})
          .catchError((_) {});
    }
  }
}

final voiceFeedbackProvider = NotifierProvider<VoiceFeedbackNotifier, bool>(VoiceFeedbackNotifier.new);
final showTextFeedbackProvider = NotifierProvider<ShowTextFeedbackNotifier, bool>(ShowTextFeedbackNotifier.new);

// Ye service actual text ko aawaz mein convert karegi
final ttsServiceProvider = Provider<TtsService>((ref) {
  return TtsService(ref);
});

class TtsService {
  final Ref ref;
  final FlutterTts flutterTts = FlutterTts();

  TtsService(this.ref) {
    _initTts();
  }

  void _initTts() async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setSpeechRate(0.5);
    await flutterTts.setVolume(1.0);
  }

  Future<void> speak(String text) async {
    final isEnabled = ref.read(voiceFeedbackProvider);
    if (isEnabled) {
      await flutterTts.speak(text);
    }
  }
}
