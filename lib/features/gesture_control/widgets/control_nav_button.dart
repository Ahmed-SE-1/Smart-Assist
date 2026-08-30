import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Center mic button in the bottom nav: tap → Voice, long-press → Gesture Control.
class ControlNavButton extends StatefulWidget {
  const ControlNavButton({
    super.key,
    required this.isActive,
    required this.primaryColor,
  });

  final bool isActive;
  final Color primaryColor;

  @override
  State<ControlNavButton> createState() => _ControlNavButtonState();
}

class _ControlNavButtonState extends State<ControlNavButton> {
  bool _longPressHandled = false;

  void _onTap() {
    if (_longPressHandled) {
      _longPressHandled = false;
      return;
    }
    context.go('/home/voice');
  }

  void _onLongPress() {
    _longPressHandled = true;
    context.push('/home/gesture');
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _onTap,
      onLongPress: _onLongPress,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: widget.isActive
              ? widget.primaryColor
              : widget.primaryColor.withValues(alpha: 0.1),
          shape: BoxShape.circle,
        ),
        child: Icon(
          widget.isActive ? Icons.mic : Icons.mic_none,
          color: widget.isActive ? Colors.white : widget.primaryColor,
        ),
      ),
    );
  }
}
