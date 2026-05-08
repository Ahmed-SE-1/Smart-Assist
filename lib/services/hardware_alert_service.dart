import 'package:flutter/foundation.dart';
import 'package:torch_light/torch_light.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart'; // Naya package

class HardwareAlertService {
  static bool _isAlerting = false;

  // AudioPlayer ka instance banaya
  static final AudioPlayer _audioPlayer = AudioPlayer();

  static Future<void> trigger() async {
    if (_isAlerting) return;
    _isAlerting = true;

    try {
      // 1. Sab se pehle sound play karein
      // (Dhyan rahay k file ka naam wahi ho jo aapne assets mein rakha hai)
      await _audioPlayer.play(AssetSource('audio/alert.mp3'));

      // 2. Torch check karein
      bool hasTorch = false;
      try {
        hasTorch = await TorchLight.isTorchAvailable();
      } catch (_) {}

      // 3. 3 dafa flash aur vibration ka cycle chalega jab tak sound baj rahi hogi
      for (int i = 0; i < 3; i++) {
        HapticFeedback.heavyImpact(); // Vibrate

        if (hasTorch) {
          await TorchLight.enableTorch();
          await Future.delayed(const Duration(milliseconds: 300));
          await TorchLight.disableTorch();
        } else {
          await Future.delayed(const Duration(milliseconds: 300));
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      debugPrint("Alert Hardware Error: $e");
    } finally {
      _isAlerting = false;
    }
  }
}
