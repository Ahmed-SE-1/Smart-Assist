/// MediaPipe Gesture Recognizer labels (7 trained gestures + unknown).
enum RecognizedGesture {
  closedFist('Closed_Fist'),
  openPalm('Open_Palm'),
  pointingUp('Pointing_Up'),
  thumbDown('Thumb_Down'),
  thumbUp('Thumb_Up'),
  victory('Victory'),
  iLoveYou('ILoveYou'),
  unknown('Unknown'),
  none('None');

  const RecognizedGesture(this.label);

  final String label;

  /// Parses a raw label string from MediaPipe (case-insensitive).
  static RecognizedGesture fromLabel(String? raw) {
    final normalized = raw?.trim().toLowerCase() ?? '';
    if (normalized.isEmpty) return RecognizedGesture.none;
    for (final gesture in RecognizedGesture.values) {
      if (gesture.label.toLowerCase() == normalized) {
        return gesture;
      }
    }
    return RecognizedGesture.unknown;
  }

  bool get isActionable =>
      this != RecognizedGesture.unknown &&
      this != RecognizedGesture.none;

  /// Emoji shown in the on-screen gesture guide.
  String get symbol {
    switch (this) {
      case RecognizedGesture.closedFist:
        return '✊';
      case RecognizedGesture.openPalm:
        return '✋';
      case RecognizedGesture.pointingUp:
        return '☝️';
      case RecognizedGesture.thumbDown:
        return '👎';
      case RecognizedGesture.thumbUp:
        return '👍';
      case RecognizedGesture.victory:
        return '✌️';
      case RecognizedGesture.iLoveYou:
        return '🤟';
      case RecognizedGesture.unknown:
      case RecognizedGesture.none:
        return '❔';
    }
  }

  /// Human-readable gesture name (e.g. "Closed Fist").
  String get displayName {
    switch (this) {
      case RecognizedGesture.closedFist:
        return 'Closed Fist';
      case RecognizedGesture.openPalm:
        return 'Open Palm';
      case RecognizedGesture.pointingUp:
        return 'Pointing Up';
      case RecognizedGesture.thumbDown:
        return 'Thumb Down';
      case RecognizedGesture.thumbUp:
        return 'Thumb Up';
      case RecognizedGesture.victory:
        return 'Victory';
      case RecognizedGesture.iLoveYou:
        return 'I Love You';
      case RecognizedGesture.unknown:
        return 'Unknown';
      case RecognizedGesture.none:
        return 'No hand';
    }
  }
}

/// One row of the on-screen "which sign does what" guide.
class GestureActionHint {
  const GestureActionHint({
    required this.gesture,
    required this.action,
    required this.isAvailable,
  });

  final RecognizedGesture gesture;

  /// What this sign does in the current navigation state.
  final String action;

  /// False when the sign is ignored in the current state (shown dimmed).
  final bool isAvailable;

  String get symbol => gesture.symbol;
  String get name => gesture.displayName;
}

/// Gesture → action mapping for [state], mirroring
/// `GestureNavigationStateMachine.handleGesture`.
List<GestureActionHint> gestureActionHintsFor(
  GestureNavState state, {
  bool supportsAdjustment = false,
}) {
  switch (state) {
    case GestureNavState.roomsList:
      return const [
        GestureActionHint(
          gesture: RecognizedGesture.pointingUp,
          action: 'Next room',
          isAvailable: true,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.thumbDown,
          action: 'Adjust fan / AC — select device first',
          isAvailable: false,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.openPalm,
          action: 'Open selected room',
          isAvailable: true,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.closedFist,
          action: 'Exit gesture mode',
          isAvailable: true,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.iLoveYou,
          action: 'Turn ALL devices OFF',
          isAvailable: true,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.thumbUp,
          action: 'Turn ON — pick a device first',
          isAvailable: false,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.victory,
          action: 'Turn OFF — pick a device first',
          isAvailable: false,
        ),
      ];
    case GestureNavState.devicesList:
      return const [
        GestureActionHint(
          gesture: RecognizedGesture.pointingUp,
          action: 'Next device',
          isAvailable: true,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.thumbDown,
          action: 'Adjust fan / AC — select device first',
          isAvailable: false,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.openPalm,
          action: 'Select this device',
          isAvailable: true,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.closedFist,
          action: 'Back to rooms',
          isAvailable: true,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.iLoveYou,
          action: 'Turn ALL devices OFF',
          isAvailable: true,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.thumbUp,
          action: 'Turn ON — select device first',
          isAvailable: false,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.victory,
          action: 'Turn OFF — select device first',
          isAvailable: false,
        ),
      ];
    case GestureNavState.deviceAction:
      return [
        GestureActionHint(
          gesture: RecognizedGesture.thumbUp,
          action: 'Turn device ON',
          isAvailable: true,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.victory,
          action: 'Turn device OFF',
          isAvailable: true,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.closedFist,
          action: 'Back to devices',
          isAvailable: true,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.iLoveYou,
          action: 'Turn ALL devices OFF',
          isAvailable: true,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.pointingUp,
          action: 'Next — go back first',
          isAvailable: false,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.thumbDown,
          action: supportsAdjustment
              ? 'Cycle fan speed / AC temperature'
              : 'Adjustment unavailable for this device',
          isAvailable: supportsAdjustment,
        ),
        GestureActionHint(
          gesture: RecognizedGesture.openPalm,
          action: 'Select — already selected',
          isAvailable: false,
        ),
      ];
  }
}

/// Navigation depth inside Gesture Control mode.
enum GestureNavState {
  /// User is browsing the list of rooms.
  roomsList,

  /// User confirmed a room and is browsing devices in that room.
  devicesList,

  /// User confirmed a device and can turn it ON/OFF with gestures.
  deviceAction,
}

/// Side-effects produced when the state machine accepts a gesture.
enum GestureNavActionType {
  moveNext,
  adjustDevice,
  confirmSelection,
  goBack,
  turnOnDevice,
  turnOffDevice,
  allDevicesOff,
  exitMode,
  none,
}

/// Immutable snapshot of navigation UI state for the gesture screen.
class GestureNavigationSnapshot {
  const GestureNavigationSnapshot({
    required this.navState,
    required this.selectedRoomIndex,
    required this.selectedDeviceIndex,
    this.selectedRoomId,
    this.selectedDeviceId,
    this.announcement,
  });

  final GestureNavState navState;
  final int selectedRoomIndex;
  final int selectedDeviceIndex;
  final String? selectedRoomId;
  final String? selectedDeviceId;

  /// Optional TTS phrase generated by a state transition (e.g. "Ahmed Room selected").
  final String? announcement;

  GestureNavigationSnapshot copyWith({
    GestureNavState? navState,
    int? selectedRoomIndex,
    int? selectedDeviceIndex,
    String? selectedRoomId,
    String? selectedDeviceId,
    String? announcement,
    bool clearAnnouncement = false,
  }) {
    return GestureNavigationSnapshot(
      navState: navState ?? this.navState,
      selectedRoomIndex: selectedRoomIndex ?? this.selectedRoomIndex,
      selectedDeviceIndex: selectedDeviceIndex ?? this.selectedDeviceIndex,
      selectedRoomId: selectedRoomId ?? this.selectedRoomId,
      selectedDeviceId: selectedDeviceId ?? this.selectedDeviceId,
      announcement: clearAnnouncement ? null : (announcement ?? this.announcement),
    );
  }
}

/// Result returned after the state machine processes one gesture.
class GestureNavActionResult {
  const GestureNavActionResult({
    required this.action,
    required this.snapshot,
    this.deviceId,
    this.ttsMessage,
  });

  final GestureNavActionType action;
  final GestureNavigationSnapshot snapshot;
  final String? deviceId;
  final String? ttsMessage;

  bool get hasEffect => action != GestureNavActionType.none;
}
