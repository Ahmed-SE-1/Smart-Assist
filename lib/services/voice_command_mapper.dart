import 'package:flutter/foundation.dart';

import '../models/device.dart';
import '../models/intent_result.dart';
import '../models/room.dart';
import '../providers/smart_home_provider.dart';

// ═══════════════════════════════════════════
// TUNING CONSTANTS
// ═══════════════════════════════════════════

/// Fan speed range accepted by [DevicesNotifier.setFanSpeed].
const int _minFanSpeed = 0;
const int _maxFanSpeed = 5;

/// AC temperature range accepted by [DevicesNotifier.setACTemperature].
const int _minAcTemp = 16;
const int _maxAcTemp = 32;

/// How much one `increase_value` / `decrease_value` command moves the value.
const int _fanSpeedStep = 1;
const int _acTempStep = 1;

// ═══════════════════════════════════════════
// BILINGUAL KEYWORD TABLES
// ═══════════════════════════════════════════

/// Urdu script + Roman Urdu + English words that all point at the same
/// [DeviceType].
///
/// This is what makes Urdu commands usable even though the user's devices are
/// saved with English names. The backend tells us *what to do* (`device_on`),
/// this table tells us *what to do it to* ("پنکھا" → every fan).
const Map<DeviceType, List<String>> _deviceTypeAliases = {
  DeviceType.light: [
    // English
    'light', 'lights', 'lamp', 'bulb', 'lightbulb',
    // Urdu script
    'بتی', 'بتیاں', 'بلب', 'لائٹ', 'لائیٹ', 'روشنی', 'چراغ',
    // Roman Urdu
    'batti', 'battian', 'bathi', 'roshni', 'lait', 'chiragh',
  ],
  DeviceType.fan: [
    // English
    'fan', 'fans', 'ceiling fan', 'speed',
    // Urdu script
    'پنکھا', 'پنکھے', 'پنکھوں', 'فین', 'رفتار',
    // Roman Urdu
    'pankha', 'pankhay', 'pankhe', 'penkha', 'raftar',
  ],
  DeviceType.ac: [
    // English — 'temperature' lives here too, because "increase the temperature"
    // means the AC, not the read-only sensor.
    'ac', 'a c', 'air conditioner', 'air conditioning', 'aircon', 'cooler',
    'temperature',
    // Urdu script
    'اے سی', 'اےسی', 'ایئر کنڈیشنر', 'ائیر کنڈیشنر', 'کولر', 'ٹمپریچر',
    // Roman Urdu
    'kooler', 'temperature',
  ],
  DeviceType.sensor: [
    // English
    'sensor', 'temperature', 'temp', 'humidity', 'motion', 'reading',
    // Urdu script
    'سینسر', 'درجہ حرارت', 'حرارت', 'ٹمپریچر', 'نمی', 'حرکت',
    // Roman Urdu
    'darja hararat', 'hararat', 'nami', 'harkat',
  ],
};

/// Common room words in Urdu / Roman Urdu / English.
///
/// Rooms are created by the user with arbitrary names, so we can't alias them
/// directly. Instead, if the command mentions any word in a group, we look for a
/// room whose *own name* matches any other word in that same group. So "کچن"
/// finds a room the user called "Kitchen".
const Map<String, List<String>> _roomAliases = {
  'bedroom': [
    'bedroom', 'bed room', 'sleeping room',
    'بیڈروم', 'بیڈ روم', 'سونے کا کمرہ', 'کمرہ', 'خواب گاہ',
    'kamra', 'kamrah', 'sone ka kamra', 'khwabgah',
  ],
  'kitchen': [
    'kitchen',
    'کچن', 'باورچی خانہ', 'باورچی', 'رسوئی',
    'bawarchi khana', 'bawarchi', 'rasoi',
  ],
  'lounge': [
    'lounge', 'living room', 'drawing room', 'hall',
    'لاؤنج', 'لاونج', 'ڈرائنگ روم', 'بیٹھک', 'ہال',
    'baithak', 'lounge',
  ],
  'bathroom': [
    'bathroom', 'washroom', 'toilet',
    'باتھ روم', 'واش روم', 'غسل خانہ', 'بیت الخلا',
    'ghusal khana', 'washroom',
  ],
  'garage': ['garage', 'گیراج', 'garaj'],
  'garden': ['garden', 'lawn', 'باغ', 'لان', 'bagh', 'lawn'],
  'store': ['store', 'store room', 'اسٹور', 'سٹور', 'گودام', 'godam'],
  'dining': ['dining', 'dining room', 'ڈائننگ', 'کھانے کا کمرہ', 'khane ka kamra'],
};

/// Generic "a room was mentioned" words. If one of these appears but we can't
/// resolve which room, we stop instead of guessing — the same safety check the
/// old keyword engine had.
const List<String> _genericRoomWords = [
  'room', 'کمرہ', 'کمرے', 'kamra', 'kamre',
];

// ═══════════════════════════════════════════
// OUTCOME TYPE
// ═══════════════════════════════════════════

/// The result of running one voice intent against the smart-home state.
class VoiceCommandOutcome {
  /// Did we actually change (or successfully report) something?
  final bool success;

  /// Text shown on the Voice screen.
  final String message;

  /// Text spoken through TTS. Usually the same as [message], but strips symbols
  /// like `°C` that a speech engine reads awkwardly.
  final String speech;

  const VoiceCommandOutcome({
    required this.success,
    required this.message,
    required this.speech,
  });

  factory VoiceCommandOutcome.ok(String message, {String? speech}) =>
      VoiceCommandOutcome(
        success: true,
        message: message,
        speech: speech ?? message,
      );

  factory VoiceCommandOutcome.fail(String message, {String? speech}) =>
      VoiceCommandOutcome(
        success: false,
        message: message,
        speech: speech ?? message,
      );
}

/// Internal helper: either a resolved device, or the failure to report.
class _DeviceResolution {
  final Device? device;
  final VoiceCommandOutcome? failure;

  _DeviceResolution.found(Device this.device) : failure = null;
  _DeviceResolution.failed(VoiceCommandOutcome this.failure) : device = null;
}

/// Internal helper: the room a command referred to, if any.
class _RoomResolution {
  final Room? room;

  /// True when the user clearly named a room we don't have.
  final bool mentionedButUnknown;

  const _RoomResolution(this.room, {this.mentionedButUnknown = false});
}

// ═══════════════════════════════════════════
// THE MAPPER
// ═══════════════════════════════════════════

/// Turns an [IntentResult] from the NLP backend into a real call on
/// [DevicesNotifier].
///
/// Intent → action mapping:
///
/// | Intent            | Action                                        |
/// |-------------------|-----------------------------------------------|
/// | `device_on`       | `turnOn(id)`                                  |
/// | `device_off`      | `turnOff(id)`                                 |
/// | `device_open`     | `turnOn(id)`  (alias — no curtain DeviceType) |
/// | `device_close`    | `turnOff(id)` (alias — no curtain DeviceType) |
/// | `increase_value`  | `setFanSpeed(+1)` / `setACTemperature(+1)`    |
/// | `decrease_value`  | `setFanSpeed(-1)` / `setACTemperature(-1)`    |
/// | `status_check`    | read-only — reports state, changes nothing    |
class VoiceCommandMapper {
  final List<Device> devices;
  final List<Room> rooms;
  final DevicesNotifier notifier;

  VoiceCommandMapper({
    required this.devices,
    required this.rooms,
    required this.notifier,
  });

  /// Runs [result] against the current smart-home state.
  ///
  /// Never throws — every failure path returns a [VoiceCommandOutcome] the UI
  /// can show and speak.
  Future<VoiceCommandOutcome> execute(IntentResult result) async {
    if (devices.isEmpty) {
      return VoiceCommandOutcome.fail(
        'You have not added any devices yet.\nCreate a room and add a device first.',
      );
    }

    final text = _normalize(result.rawText);
    debugPrint('VoiceCommandMapper: intent=${result.intent} text="$text"');

    // --- Which room? ---
    final roomResolution = _resolveRoom(text);
    if (roomResolution.mentionedButUnknown) {
      return VoiceCommandOutcome.fail(
        'I could not find that room.\nAvailable rooms: ${rooms.map((r) => r.name).join(', ')}.',
        speech: 'I could not find that room.',
      );
    }
    final room = roomResolution.room;

    // status_check is read-only and still useful without a named device, so it
    // gets its own path with a whole-house fallback.
    if (result.type == VoiceIntent.statusCheck) {
      return _statusCheck(text, room);
    }

    // --- Which device? ---
    // The preference list breaks ties: "temperature" matches both the AC and a
    // temperature sensor, and for an action intent the AC is what's meant.
    final resolution = _resolveDevice(
      text,
      room,
      preference: const [DeviceType.ac, DeviceType.fan, DeviceType.light],
    );
    if (resolution.failure != null) return resolution.failure!;
    final device = resolution.device!;

    // --- Do the thing ---
    switch (result.type) {
      case VoiceIntent.deviceOn:
      case VoiceIntent.deviceOpen:
        return _setPower(device, on: true);

      case VoiceIntent.deviceOff:
      case VoiceIntent.deviceClose:
        return _setPower(device, on: false);

      case VoiceIntent.increaseValue:
        return _step(device, increase: true);

      case VoiceIntent.decreaseValue:
        return _step(device, increase: false);

      case VoiceIntent.statusCheck: // handled above
      case VoiceIntent.unknown:
        return VoiceCommandOutcome.fail(
          'I understood the words but not the command. Please try again.',
        );
    }
  }

  // ─────────────────────────────────────────
  // ACTIONS
  // ─────────────────────────────────────────

  /// `device_on` / `device_off` (and their `device_open` / `device_close` aliases).
  Future<VoiceCommandOutcome> _setPower(Device device, {required bool on}) async {
    final word = on ? 'ON' : 'OFF';

    if (device.type == DeviceType.sensor) {
      return VoiceCommandOutcome.fail(
        '${device.name} is a sensor — it cannot be switched $word.',
      );
    }

    if (device.isOn == on) {
      return VoiceCommandOutcome.ok('${device.name} is already $word.');
    }

    final ok = on
        ? await notifier.turnOn(device.id, method: 'voice')
        : await notifier.turnOff(device.id, method: 'voice');

    return ok
        ? VoiceCommandOutcome.ok('${device.name} turned $word')
        : VoiceCommandOutcome.fail(
            '${device.name} did not respond. Please check the device and try again.',
          );
  }

  /// `increase_value` / `decrease_value`.
  ///
  /// Fans step by [_fanSpeedStep] within 0–5, ACs by [_acTempStep] within
  /// 16–32°C. Lights have no brightness field in [Device], so they're rejected
  /// with a clear message instead of doing something surprising.
  Future<VoiceCommandOutcome> _step(Device device, {required bool increase}) async {
    final direction = increase ? 'increase' : 'decrease';

    switch (device.type) {
      case DeviceType.fan:
        final delta = increase ? _fanSpeedStep : -_fanSpeedStep;
        final next =
            (device.fanSpeed + delta).clamp(_minFanSpeed, _maxFanSpeed).toInt();

        if (next == device.fanSpeed) {
          return VoiceCommandOutcome.ok(
            '${device.name} is already at ${increase ? 'maximum' : 'minimum'} speed ($next).',
          );
        }

        final ok = await notifier.setFanSpeed(device, next, method: 'voice');
        if (!ok) {
          return VoiceCommandOutcome.fail(
            '${device.name} did not respond. Please try again.',
          );
        }
        // setFanSpeed also flips isOn, so speed 0 means the fan switched off.
        return VoiceCommandOutcome.ok(
          next == 0
              ? '${device.name} speed set to 0 (turned OFF)'
              : '${device.name} speed set to $next',
        );

      case DeviceType.ac:
        final delta = increase ? _acTempStep : -_acTempStep;
        final next =
            (device.acTemperature + delta).clamp(_minAcTemp, _maxAcTemp).toInt();

        if (next == device.acTemperature) {
          return VoiceCommandOutcome.ok(
            '${device.name} is already at its ${increase ? 'highest' : 'lowest'} '
            'temperature ($next°C).',
            speech: '${device.name} is already at its '
                '${increase ? 'highest' : 'lowest'} temperature, $next degrees.',
          );
        }

        final ok = await notifier.setACTemperature(device, next, method: 'voice');
        if (!ok) {
          return VoiceCommandOutcome.fail(
            '${device.name} did not respond. Please try again.',
          );
        }

        // Matches the app's existing behaviour: setting a temperature powers the
        // AC on, otherwise the change would be invisible.
        var note = '';
        if (!device.isOn) {
          await notifier.turnOn(device.id, method: 'voice');
          note = ' and turned ON';
        }

        return VoiceCommandOutcome.ok(
          '${device.name} set to $next°C$note',
          speech: '${device.name} set to $next degrees$note',
        );

      case DeviceType.light:
        return VoiceCommandOutcome.fail(
          '${device.name} has no brightness control.\n'
          'Try "turn on ${device.name}" instead.',
          speech: '${device.name} has no brightness control.',
        );

      case DeviceType.sensor:
        return VoiceCommandOutcome.fail(
          '${device.name} is a sensor — its reading cannot be ${direction}d.',
        );
    }
  }

  /// `status_check` — read-only. Reports one device if named, otherwise
  /// summarises the mentioned room, otherwise the whole house.
  Future<VoiceCommandOutcome> _statusCheck(String text, Room? room) async {
    // Sensors are allowed here: "what is the temperature" should reach them.
    final resolution = _resolveDevice(
      text,
      room,
      preference: const [DeviceType.sensor, DeviceType.ac, DeviceType.fan, DeviceType.light],
      allowSensors: true,
      reportFailures: false,
    );

    if (resolution.device != null) {
      return _describe(resolution.device!);
    }

    // No specific device named — give a summary instead of an error.
    final scope =
        room == null ? devices : devices.where((d) => d.roomId == room.id).toList();
    final controllable =
        scope.where((d) => d.type != DeviceType.sensor).toList();
    final where = room == null ? 'your home' : room.name;

    if (controllable.isEmpty) {
      return VoiceCommandOutcome.ok('There are no controllable devices in $where.');
    }

    final active = controllable.where((d) => d.isOn).toList();

    if (active.isEmpty) {
      return VoiceCommandOutcome.ok(
        'All ${controllable.length} devices in $where are OFF.',
      );
    }

    return VoiceCommandOutcome.ok(
      '${active.length} of ${controllable.length} devices in $where are ON:\n'
      '${active.map((d) => d.name).join(', ')}',
      speech: '${active.length} of ${controllable.length} devices in $where are on: '
          '${active.map((d) => d.name).join(', ')}',
    );
  }

  /// Human-readable state of a single device.
  VoiceCommandOutcome _describe(Device d) {
    switch (d.type) {
      case DeviceType.sensor:
        final unit = d.sensorType == 'temperature' ? '°C' : '';
        final spokenUnit = d.sensorType == 'temperature' ? ' degrees' : '';
        final value = d.sensorValue.toStringAsFixed(1);
        return VoiceCommandOutcome.ok(
          '${d.name} currently reads $value$unit',
          speech: '${d.name} currently reads $value$spokenUnit',
        );

      case DeviceType.fan:
        return VoiceCommandOutcome.ok(
          d.isOn ? '${d.name} is ON at speed ${d.fanSpeed}' : '${d.name} is OFF',
        );

      case DeviceType.ac:
        return VoiceCommandOutcome.ok(
          '${d.name} is ${d.isOn ? 'ON' : 'OFF'}, set to ${d.acTemperature}°C',
          speech: '${d.name} is ${d.isOn ? 'on' : 'off'}, '
              'set to ${d.acTemperature} degrees',
        );

      case DeviceType.light:
        return VoiceCommandOutcome.ok('${d.name} is ${d.isOn ? 'ON' : 'OFF'}');
    }
  }

  // ─────────────────────────────────────────
  // RESOLUTION
  // ─────────────────────────────────────────

  /// Works out which room the command referred to.
  ///
  /// Tries the user's own room names first, then falls back to the bilingual
  /// [_roomAliases] table so "کچن" can find a room named "Kitchen".
  _RoomResolution _resolveRoom(String text) {
    // 1. The user's actual room name appears in the command.
    for (final room in rooms) {
      if (_mentions(text, room.name)) return _RoomResolution(room);
    }

    // 2. An Urdu / Roman-Urdu alias appears — find the matching room.
    var aliasMatched = false;
    for (final group in _roomAliases.values) {
      if (!group.any((alias) => _mentions(text, alias))) continue;
      aliasMatched = true;

      for (final room in rooms) {
        final name = _normalize(room.name);
        if (group.any((alias) => name.contains(' ${_normalize(alias).trim()} '))) {
          return _RoomResolution(room);
        }
      }
    }

    // 3. A room was clearly mentioned but we have no such room — don't guess.
    final saidGenericRoom =
        _genericRoomWords.any((word) => _mentions(text, word));
    if (aliasMatched || saidGenericRoom) {
      return const _RoomResolution(null, mentionedButUnknown: true);
    }

    return const _RoomResolution(null);
  }

  /// Works out which device the command referred to.
  ///
  /// [preference] breaks ties when a word maps to more than one device type.
  /// [reportFailures] is false for `status_check`, which prefers a summary over
  /// an error when nothing matches.
  _DeviceResolution _resolveDevice(
    String text,
    Room? room, {
    required List<DeviceType> preference,
    bool allowSensors = false,
    bool reportFailures = true,
  }) {
    final inRoom =
        room == null ? devices : devices.where((d) => d.roomId == room.id).toList();
    final pool = allowSensors
        ? inRoom
        : inRoom.where((d) => d.type != DeviceType.sensor).toList();

    if (pool.isEmpty) {
      return _DeviceResolution.failed(
        reportFailures
            ? VoiceCommandOutcome.fail(
                room == null
                    ? 'You have no controllable devices yet.'
                    : 'There are no controllable devices in ${room.name}.',
              )
            : VoiceCommandOutcome.fail(''),
      );
    }

    // 1. The device's own name appears in the command. Works for English names
    //    and for users who named their devices in Urdu.
    final byName = pool.where((d) => _mentions(text, d.name)).toList();
    if (byName.length == 1) return _DeviceResolution.found(byName.first);
    if (byName.length > 1) {
      return _DeviceResolution.failed(_ambiguous(byName, reportFailures));
    }

    // 2. Fall back to the bilingual keyword table → DeviceType.
    final matchedTypes = _matchedTypes(text);
    if (matchedTypes.isEmpty) {
      return _DeviceResolution.failed(
        reportFailures
            ? VoiceCommandOutcome.fail(
                'I could not tell which device you meant.\n'
                'Available: ${pool.map((d) => d.name).join(', ')}',
                speech: 'I could not tell which device you meant.',
              )
            : VoiceCommandOutcome.fail(''),
      );
    }

    var candidates = pool.where((d) => matchedTypes.contains(d.type)).toList();

    if (candidates.isEmpty) {
      return _DeviceResolution.failed(
        reportFailures
            ? VoiceCommandOutcome.fail(
                room == null
                    ? 'You do not have that kind of device set up.'
                    : 'There is no such device in ${room.name}.',
              )
            : VoiceCommandOutcome.fail(''),
      );
    }

    // Narrow by the caller's preferred type — this is what makes "temperature"
    // mean the AC when adjusting, and the sensor when asking.
    if (candidates.length > 1) {
      for (final type in preference) {
        final byType = candidates.where((d) => d.type == type).toList();
        if (byType.isNotEmpty) {
          candidates = byType;
          break;
        }
      }
    }

    if (candidates.length == 1) return _DeviceResolution.found(candidates.first);

    return _DeviceResolution.failed(_ambiguous(candidates, reportFailures));
  }

  /// The same "please name the room" guard the old keyword engine had, but it
  /// now lists the actual options so the user knows what to say.
  VoiceCommandOutcome _ambiguous(List<Device> matches, bool report) {
    if (!report) return VoiceCommandOutcome.fail('');

    final labels = matches.map((d) {
      final roomName = _roomNameFor(d.roomId);
      return roomName == null ? d.name : '${d.name} ($roomName)';
    }).join(', ');

    final example = _roomNameFor(matches.first.roomId) ?? 'the room';

    return VoiceCommandOutcome.fail(
      'I found more than one match: $labels.\n'
      'Please name the room too, e.g. "${matches.first.name} in $example".',
      speech: 'I found more than one matching device. Please also say the room name.',
    );
  }

  /// The name of the room with this id, or null if it no longer exists.
  String? _roomNameFor(String roomId) {
    for (final room in rooms) {
      if (room.id == roomId) return room.name;
    }
    return null;
  }

  /// Every [DeviceType] whose keyword table matches something in [text].
  Set<DeviceType> _matchedTypes(String text) {
    final matched = <DeviceType>{};
    for (final entry in _deviceTypeAliases.entries) {
      if (entry.value.any((alias) => _mentions(text, alias))) {
        matched.add(entry.key);
      }
    }
    return matched;
  }
}

// ═══════════════════════════════════════════
// TEXT MATCHING HELPERS
// ═══════════════════════════════════════════

/// Lower-cases [input], replaces every punctuation mark with a space, and pads
/// the result with spaces.
///
/// The padding lets us match whole words with `contains(' word ')` instead of a
/// plain `contains`, which would otherwise find "ac" inside "back".
/// `unicode: true` keeps Urdu letters and Urdu digits intact.
String _normalize(String input) {
  final cleaned = input
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();
  return ' $cleaned ';
}

/// Whether [normalizedText] (already run through [_normalize]) mentions [alias].
///
/// Exact whole-word match first, then a prefix match for inflected forms
/// (Urdu plurals like پنکھا → پنکھاوں, or temp → temperature). The prefix rule
/// only applies to aliases of 4+ characters so short ones like "ac" can't fire
/// on unrelated words.
bool _mentions(String normalizedText, String alias) {
  final key = _normalize(alias).trim();
  if (key.isEmpty) return false;

  if (normalizedText.contains(' $key ')) return true;

  if (key.length >= 4 && !key.contains(' ')) {
    for (final token in normalizedText.trim().split(' ')) {
      if (token.length > key.length && token.startsWith(key)) return true;
    }
  }

  return false;
}
