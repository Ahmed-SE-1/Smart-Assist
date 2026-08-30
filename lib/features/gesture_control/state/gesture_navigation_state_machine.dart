import '../models/gesture_types.dart';

/// Lightweight room/device descriptors passed into the state machine.
/// Keeps the machine decoupled from Riverpod models and easy to unit-test.
class GestureRoomItem {
  const GestureRoomItem({required this.id, required this.name});

  final String id;
  final String name;
}

class GestureDeviceItem {
  const GestureDeviceItem({
    required this.id,
    required this.name,
    required this.roomId,
    required this.isControllable,
  });

  final String id;
  final String name;
  final String roomId;

  /// Sensors cannot be toggled ON/OFF via gestures.
  final bool isControllable;
}

/// Core navigation logic for Gesture Control.
///
/// State flow:
///   [GestureNavState.roomsList] → (Open_Palm) → [GestureNavState.devicesList]
///   → (Open_Palm) → [GestureNavState.deviceAction]
///
/// Gestures are index-based — room/device names (including Urdu) never affect logic.
class GestureNavigationStateMachine {
  GestureNavigationStateMachine({
    List<GestureRoomItem> rooms = const [],
    List<GestureDeviceItem> devices = const [],
    this.confidenceThreshold = 0.75,
  })  : _rooms = List.unmodifiable(rooms),
        _allDevices = List.unmodifiable(devices);

  final double confidenceThreshold;

  List<GestureRoomItem> _rooms;
  List<GestureDeviceItem> _allDevices;

  GestureNavState _navState = GestureNavState.roomsList;
  int _roomIndex = 0;
  int _deviceIndex = 0;
  String? _selectedRoomId;
  String? _selectedDeviceId;

  GestureNavState get navState => _navState;
  int get selectedRoomIndex => _roomIndex;
  int get selectedDeviceIndex => _deviceIndex;
  String? get selectedRoomId => _selectedRoomId;
  String? get selectedDeviceId => _selectedDeviceId;

  List<GestureRoomItem> get rooms => _rooms;

  /// Devices filtered to the currently selected room (controllable only in action state).
  List<GestureDeviceItem> get devicesInSelectedRoom {
    if (_selectedRoomId == null) return const [];
    return _allDevices.where((d) => d.roomId == _selectedRoomId).toList();
  }

  /// Refresh lists when Riverpod data changes without resetting navigation depth.
  void updateData({
    required List<GestureRoomItem> rooms,
    required List<GestureDeviceItem> devices,
  }) {
    _rooms = List.unmodifiable(rooms);
    _allDevices = List.unmodifiable(devices);
    _clampIndices();
  }

  GestureNavigationSnapshot snapshot({String? announcement}) {
    return GestureNavigationSnapshot(
      navState: _navState,
      selectedRoomIndex: _roomIndex,
      selectedDeviceIndex: _deviceIndex,
      selectedRoomId: _selectedRoomId,
      selectedDeviceId: _selectedDeviceId,
      announcement: announcement,
    );
  }

  /// Resets to the initial rooms list (called when entering gesture mode).
  void reset() {
    _navState = GestureNavState.roomsList;
    _roomIndex = 0;
    _deviceIndex = 0;
    _selectedRoomId = null;
    _selectedDeviceId = null;
    _clampIndices();
  }

  /// Processes a recognized gesture with [confidence].
  /// Returns [GestureNavActionType.none] when confidence is too low or gesture is unknown.
  GestureNavActionResult handleGesture(
    RecognizedGesture gesture, {
    required double confidence,
  }) {
    if (!gesture.isActionable || confidence < confidenceThreshold) {
      return GestureNavActionResult(
        action: GestureNavActionType.none,
        snapshot: snapshot(),
      );
    }

    switch (gesture) {
      case RecognizedGesture.pointingUp:
        return _moveNext();
      case RecognizedGesture.thumbDown:
        return _movePrevious();
      case RecognizedGesture.openPalm:
        return _confirmSelection();
      case RecognizedGesture.closedFist:
        return _goBack();
      case RecognizedGesture.thumbUp:
        return _turnOn();
      case RecognizedGesture.victory:
        return _turnOff();
      case RecognizedGesture.iLoveYou:
        return _jumpToRooms();
      case RecognizedGesture.unknown:
      case RecognizedGesture.none:
        return GestureNavActionResult(
          action: GestureNavActionType.none,
          snapshot: snapshot(),
        );
    }
  }

  // ─── Gesture handlers ─────────────────────────────────────────────────────

  GestureNavActionResult _moveNext() {
    switch (_navState) {
      case GestureNavState.roomsList:
        if (_rooms.isEmpty) return _noAction();
        _roomIndex = (_roomIndex + 1) % _rooms.length;
        final name = _rooms[_roomIndex].name;
        return GestureNavActionResult(
          action: GestureNavActionType.moveNext,
          snapshot: snapshot(announcement: name),
          ttsMessage: name,
        );
      case GestureNavState.devicesList:
        final devices = devicesInSelectedRoom;
        if (devices.isEmpty) return _noAction();
        _deviceIndex = (_deviceIndex + 1) % devices.length;
        final name = devices[_deviceIndex].name;
        return GestureNavActionResult(
          action: GestureNavActionType.moveNext,
          snapshot: snapshot(announcement: name),
          ttsMessage: name,
        );
      case GestureNavState.deviceAction:
        // Navigation gestures are ignored in device_action — only ON/OFF apply.
        return _noAction();
    }
  }

  GestureNavActionResult _movePrevious() {
    switch (_navState) {
      case GestureNavState.roomsList:
        if (_rooms.isEmpty) return _noAction();
        _roomIndex = (_roomIndex - 1 + _rooms.length) % _rooms.length;
        final name = _rooms[_roomIndex].name;
        return GestureNavActionResult(
          action: GestureNavActionType.movePrevious,
          snapshot: snapshot(announcement: name),
          ttsMessage: name,
        );
      case GestureNavState.devicesList:
        final devices = devicesInSelectedRoom;
        if (devices.isEmpty) return _noAction();
        _deviceIndex = (_deviceIndex - 1 + devices.length) % devices.length;
        final name = devices[_deviceIndex].name;
        return GestureNavActionResult(
          action: GestureNavActionType.movePrevious,
          snapshot: snapshot(announcement: name),
          ttsMessage: name,
        );
      case GestureNavState.deviceAction:
        return _noAction();
    }
  }

  GestureNavActionResult _confirmSelection() {
    switch (_navState) {
      case GestureNavState.roomsList:
        if (_rooms.isEmpty) return _noAction();
        final room = _rooms[_roomIndex];
        _selectedRoomId = room.id;
        _deviceIndex = 0;
        _navState = GestureNavState.devicesList;
        final devices = devicesInSelectedRoom;
        final deviceName = devices.isNotEmpty ? devices.first.name : 'No devices';
        return GestureNavActionResult(
          action: GestureNavActionType.confirmSelection,
          snapshot: snapshot(announcement: '$deviceName in ${room.name}'),
          ttsMessage: '${room.name} selected. $deviceName',
        );
      case GestureNavState.devicesList:
        final devices = devicesInSelectedRoom;
        if (devices.isEmpty) return _noAction();
        final device = devices[_deviceIndex];
        if (!device.isControllable) {
          return GestureNavActionResult(
            action: GestureNavActionType.none,
            snapshot: snapshot(),
            ttsMessage: '${device.name} cannot be controlled by gesture',
          );
        }
        _selectedDeviceId = device.id;
        _navState = GestureNavState.deviceAction;
        return GestureNavActionResult(
          action: GestureNavActionType.confirmSelection,
          snapshot: snapshot(announcement: device.name),
          ttsMessage: '${device.name} selected. Thumb up to turn on, victory to turn off.',
        );
      case GestureNavState.deviceAction:
        return _noAction();
    }
  }

  GestureNavActionResult _goBack() {
    switch (_navState) {
      case GestureNavState.deviceAction:
        _navState = GestureNavState.devicesList;
        _selectedDeviceId = null;
        final devices = devicesInSelectedRoom;
        final name = devices.isNotEmpty
            ? devices[_deviceIndex.clamp(0, devices.length - 1)].name
            : 'Devices';
        return GestureNavActionResult(
          action: GestureNavActionType.goBack,
          snapshot: snapshot(announcement: name),
          ttsMessage: 'Back to devices. $name',
        );
      case GestureNavState.devicesList:
        _navState = GestureNavState.roomsList;
        _selectedRoomId = null;
        _deviceIndex = 0;
        final name = _rooms.isNotEmpty ? _rooms[_roomIndex].name : 'Rooms';
        return GestureNavActionResult(
          action: GestureNavActionType.goBack,
          snapshot: snapshot(announcement: name),
          ttsMessage: 'Back to rooms. $name',
        );
      case GestureNavState.roomsList:
        return GestureNavActionResult(
          action: GestureNavActionType.exitMode,
          snapshot: snapshot(announcement: 'Exiting gesture mode'),
          ttsMessage: 'Exiting gesture mode',
        );
    }
  }

  GestureNavActionResult _turnOn() {
    if (_navState != GestureNavState.deviceAction || _selectedDeviceId == null) {
      return _noAction();
    }
    final device = _findDevice(_selectedDeviceId!);
    final name = device?.name ?? 'Device';
    return GestureNavActionResult(
      action: GestureNavActionType.turnOnDevice,
      snapshot: snapshot(announcement: '$name turned ON'),
      deviceId: _selectedDeviceId,
      ttsMessage: '$name turned ON',
    );
  }

  GestureNavActionResult _turnOff() {
    if (_navState != GestureNavState.deviceAction || _selectedDeviceId == null) {
      return _noAction();
    }
    final device = _findDevice(_selectedDeviceId!);
    final name = device?.name ?? 'Device';
    return GestureNavActionResult(
      action: GestureNavActionType.turnOffDevice,
      snapshot: snapshot(announcement: '$name turned OFF'),
      deviceId: _selectedDeviceId,
      ttsMessage: '$name turned OFF',
    );
  }

  GestureNavActionResult _jumpToRooms() {
    _navState = GestureNavState.roomsList;
    _selectedRoomId = null;
    _selectedDeviceId = null;
    _deviceIndex = 0;
    _clampIndices();
    final name = _rooms.isNotEmpty ? _rooms[_roomIndex].name : 'Rooms';
    return GestureNavActionResult(
      action: GestureNavActionType.jumpToRooms,
      snapshot: snapshot(announcement: name),
      ttsMessage: 'Rooms list. $name',
    );
  }

  GestureNavActionResult _noAction() {
    return GestureNavActionResult(
      action: GestureNavActionType.none,
      snapshot: snapshot(),
    );
  }

  GestureDeviceItem? _findDevice(String id) {
    for (final device in _allDevices) {
      if (device.id == id) return device;
    }
    return null;
  }

  void _clampIndices() {
    if (_rooms.isEmpty) {
      _roomIndex = 0;
    } else {
      _roomIndex = _roomIndex.clamp(0, _rooms.length - 1);
    }

    final devices = devicesInSelectedRoom;
    if (devices.isEmpty) {
      _deviceIndex = 0;
    } else {
      _deviceIndex = _deviceIndex.clamp(0, devices.length - 1);
    }

    if (_selectedRoomId != null &&
        !_rooms.any((room) => room.id == _selectedRoomId)) {
      _selectedRoomId = null;
      _navState = GestureNavState.roomsList;
      _deviceIndex = 0;
    }

    if (_selectedDeviceId != null &&
        !devices.any((device) => device.id == _selectedDeviceId)) {
      _selectedDeviceId = null;
      if (_navState == GestureNavState.deviceAction) {
        _navState = GestureNavState.devicesList;
      }
    }
  }
}
