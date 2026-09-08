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

/// Large live camera preview with the detected gesture label overlaid.
class GestureCameraOverlay extends StatelessWidget {
  const GestureCameraOverlay({
    super.key,
    required this.cameraPreview,
    required this.detectedLabel,
    required this.confidence,
    required this.onSwitchCamera,
    this.isFrontCamera = true,
    this.aspectRatio = 3 / 4,
  });

  final Widget cameraPreview;
  final String detectedLabel;
  final double confidence;
  final VoidCallback onSwitchCamera;
  final bool isFrontCamera;

  /// Width / height of the preview box. Defaults to a 3:4 portrait frame so the
  /// user's hand fills a much larger area than the old fixed 180px strip.
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: Container(
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
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                          fontSize: 16,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (confidence > 0)
                      Text(
                        '${(confidence * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Expandable card listing which hand sign performs which action in the
/// current navigation state. Signs that do nothing here are shown dimmed.
class GestureGuideCard extends StatefulWidget {
  const GestureGuideCard({
    super.key,
    required this.navState,
    this.activeGesture,
    this.initiallyExpanded = true,
  });

  final GestureNavState navState;

  /// Currently detected gesture, highlighted in the list when present.
  final RecognizedGesture? activeGesture;

  final bool initiallyExpanded;

  @override
  State<GestureGuideCard> createState() => _GestureGuideCardState();
}

class _GestureGuideCardState extends State<GestureGuideCard> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final hints = gestureActionHintsFor(widget.navState);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.cardColorDark,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.grey.shade800),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.sign_language, color: AppTheme.primaryColor, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Gesture guide',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Text(
                    _stateLabel(widget.navState),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.white54,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Column(
                children: [
                  for (final hint in hints) _hintRow(hint),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _hintRow(GestureActionHint hint) {
    final isActive = widget.activeGesture == hint.gesture && hint.isAvailable;
    final textColor = hint.isAvailable ? Colors.white : Colors.white38;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isActive
            ? AppTheme.primaryColor.withValues(alpha: 0.22)
            : Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isActive ? AppTheme.primaryColor : Colors.transparent,
          width: isActive ? 1.6 : 1,
        ),
      ),
      child: Row(
        children: [
          Opacity(
            opacity: hint.isAvailable ? 1 : 0.4,
            child: Text(hint.symbol, style: const TextStyle(fontSize: 22)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hint.action,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 14,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hint.name,
                  style: TextStyle(
                    color: hint.isAvailable ? Colors.white54 : Colors.white24,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          if (isActive)
            const Icon(Icons.check_circle, color: AppTheme.accentColor, size: 18),
        ],
      ),
    );
  }

  String _stateLabel(GestureNavState state) {
    switch (state) {
      case GestureNavState.roomsList:
        return 'Rooms';
      case GestureNavState.devicesList:
        return 'Devices';
      case GestureNavState.deviceAction:
        return 'Device control';
    }
  }
}

/// Single-line chip row of the gestures that are usable right now.
class GestureHintBar extends StatelessWidget {
  const GestureHintBar({super.key, required this.navState});

  final GestureNavState navState;

  @override
  Widget build(BuildContext context) {
    final hints =
        gestureActionHintsFor(navState).where((h) => h.isAvailable).toList();

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
                '${h.symbol} ${h.action}',
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
            ),
          )
          .toList(),
    );
  }
}
