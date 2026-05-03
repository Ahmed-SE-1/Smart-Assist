import 'package:torch_light/torch_light.dart';
import 'package:flutter/services.dart';

class HardwareAlertService {
  static bool _isAlerting = false;

  static Future<void> trigger() async {
    if (_isAlerting) return;
    _isAlerting = true;

    try {
      bool hasTorch = false;
      try {
        hasTorch = await TorchLight.isTorchAvailable();
      } catch (_) {}

      // 3 dafa alert cycle chalega
      for (int i = 0; i < 3; i++) {
        HapticFeedback.heavyImpact(); // Sath vibrate karega

        if (hasTorch) {
          await TorchLight.enableTorch();
          await Future.delayed(const Duration(milliseconds: 300));
          await TorchLight.disableTorch();
        } else {
          // Agar torch nahi hai toh sirf vibration ke darmyan gap ke liye delay
          await Future.delayed(const Duration(milliseconds: 300));
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }
    } catch (e) {
      print("Alert Hardware Error: $e");
    } finally {
      _isAlerting = false;
    }
  }
}