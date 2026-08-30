import 'package:flutter/material.dart';

import '../../../core/theme.dart';
import '../models/gesture_types.dart';

/// Linear list showing either rooms or devices with the selected item highlighted.
class GestureNavigationList extends StatelessWidget {
  const GestureNavigationList({
    super.key,
    required this.navState,
    required this.itemNames,
    required this.selectedIndex,
    this.header,
  });

  final GestureNavState navState;
  final List<String> itemNames;
  final int selectedIndex;
  final String? header;

  @override
  Widget build(BuildContext context) {
    if (itemNames.isEmpty) {
      return _emptyState(
        navState == GestureNavState.roomsList
            ? 'No rooms available. Add a room from Home.'
            : 'No devices in this room.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (header != null) ...[
          Text(
            header!,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
        ],
        ...List.generate(itemNames.length, (index) {
          final isSelected = index == selectedIndex;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.only(bottom: 8),
            padding: EdgeInsets.symmetric(
              horizontal: isSelected ? 18 : 14,
              vertical: isSelected ? 14 : 10,
            ),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppTheme.primaryColor.withValues(alpha: 0.25)
                  : AppTheme.cardColorDark,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected ? AppTheme.primaryColor : Colors.grey.shade800,
                width: isSelected ? 2.5 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _iconForState(navState),
                  color: isSelected ? AppTheme.primaryColor : Colors.white54,
                  size: isSelected ? 22 : 18,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    itemNames[index],
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: isSelected ? 17 : 14,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                ),
                if (isSelected)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Selected',
                      style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _emptyState(String message) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.cardColorDark,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade800),
      ),
      child: Text(
        message,
        style: const TextStyle(color: Colors.white70, fontSize: 14),
        textAlign: TextAlign.center,
      ),
    );
  }

  IconData _iconForState(GestureNavState state) {
    switch (state) {
      case GestureNavState.roomsList:
        return Icons.meeting_room_outlined;
      case GestureNavState.devicesList:
      case GestureNavState.deviceAction:
        return Icons.devices_outlined;
    }
  }
}

/// Compact overlay showing the live camera preview and detected gesture label.
class GestureCameraOverlay extends StatelessWidget {
  const GestureCameraOverlay({
    super.key,
    required this.cameraPreview,
    required this.detectedLabel,
    required this.confidence,
    required this.onSwitchCamera,
    this.isFrontCamera = true,
  });

  final Widget cameraPreview;
  final String detectedLabel;
  final double confidence;
  final VoidCallback onSwitchCamera;
  final bool isFrontCamera;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 180,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.5), width: 2),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        fit: StackFit.expand,
        children: [
          cameraPreview,
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              onPressed: onSwitchCamera,
              icon: Icon(
                isFrontCamera ? Icons.camera_rear : Icons.camera_front,
                color: Colors.white,
              ),
              style: IconButton.styleFrom(
                backgroundColor: Colors.black54,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: Colors.black54,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      detectedLabel.isEmpty ? 'No hand detected' : detectedLabel,
                      style: TextStyle(
                        color: detectedLabel == 'Unknown'
                            ? Colors.orangeAccent
                            : AppTheme.accentColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (confidence > 0)
                    Text(
                      '${(confidence * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Quick reference card for gesture → action mapping in the current state.
class GestureHintBar extends StatelessWidget {
  const GestureHintBar({super.key, required this.navState});

  final GestureNavState navState;

  @override
  Widget build(BuildContext context) {
    final hints = _hintsForState(navState);
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: hints
          .map(
            (h) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.cardColorDark,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade800),
              ),
              child: Text(
                h,
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
            ),
          )
          .toList(),
    );
  }

  List<String> _hintsForState(GestureNavState state) {
    switch (state) {
      case GestureNavState.roomsList:
      case GestureNavState.devicesList:
        return const [
          '↑ Next',
          '↓ Prev',
          '✋ Select',
          '✊ Back',
          '🤟 Rooms',
        ];
      case GestureNavState.deviceAction:
        return const [
          '👍 ON',
          '✌ OFF',
          '✊ Back',
          '🤟 Rooms',
        ];
    }
  }
}
