import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/activity_log.dart';
import '../models/device.dart';
import '../models/pir_motion_event.dart';
import '../models/room.dart';
import '../models/user.dart';
import '../services/iot_simulation_service.dart';
import './user_provider.dart';
import 'automation_provider.dart';
import 'service_providers.dart';

const _uuid = Uuid();

final roomSyncErrorProvider = StateProvider<String?>((ref) => null);
final deviceSyncErrorProvider = StateProvider<String?>((ref) => null);

Map<String, dynamic> _sharedDeviceData(Device device) => {
  'id': device.id,
  'name': device.name,
  'type': device.type.name,
  'roomId': device.roomId,
  'sensorType': device.sensorType,
  'channel': device.channel,
};

String _firestoreWriteError(String recordType, FirebaseException error) {
  if (error.code == 'permission-denied') {
    return '$recordType was not saved: Firestore denied access. Check your House approval and Room permissions.';
  }
  final detail = error.message;
  return detail == null || detail.isEmpty
      ? '$recordType could not be saved (${error.code}). Please try again.'
      : '$recordType could not be saved: $detail';
}

// ═══════════════════════════════════════════
// ROOM STATE MANAGEMENT
// ═══════════════════════════════════════════

/// Manages the list of Rooms (e.g., Bedroom, Kitchen) created by the user.
class RoomsNotifier extends Notifier<List<Room>> {
  int _nodeCounter = 0;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;
  String? _activeHouseId;
  int _listenerGeneration = 0;
  final Map<String, Room> _confirmedRoomWrites = {};

  // --- UPGRADED: House-Specific Storage Key ---
  String getStorageKey({String? houseId}) {
    final user = ref.read(userProvider);
    // Agar user logged in hai, toh uske houseId ke hisaab se key banegi
    return 'shared_house_rooms_db_${houseId ?? user?.houseId ?? 'default'}';
  }

  @override
  List<Room> build() {
    // ref.watch lagane se jab bhi user login/logout hoga, ye provider reload hoga
    _subscription?.cancel();
    final user = ref.watch(userProvider);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final houseId =
        user?.isApproved == true && user?.id == uid
            ? user?.houseId?.trim()
            : null;
    final listenerGeneration = ++_listenerGeneration;
    if (_activeHouseId != houseId) _confirmedRoomWrites.clear();
    _activeHouseId = houseId;
    ref.read(roomSyncErrorProvider.notifier).state = null;
    if (houseId != null && houseId.isNotEmpty) {
      if (user?.role == UserRole.member && user!.assignedRoomIds.isEmpty) {
        state = [];
        return [];
      }
      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collection('houses')
          .doc(houseId)
          .collection('rooms');
      if (user?.role == UserRole.member) {
        query = query.where(FieldPath.documentId, whereIn: user!.assignedRoomIds);
      }
      _subscription = query
          .snapshots(includeMetadataChanges: true)
          .listen(
            (snapshot) {
              if (_activeHouseId != houseId ||
                  _listenerGeneration != listenerGeneration) {
                return;
              }
              ref.read(roomSyncErrorProvider.notifier).state = null;
              final roomsById = {
                for (final doc in snapshot.docs.where(
                  (doc) => !doc.metadata.hasPendingWrites,
                ))
                  doc.id: Room.fromMap({...doc.data(), 'id': doc.id}),
              };
              _confirmedRoomWrites.removeWhere(
                (roomId, _) => roomsById.containsKey(roomId),
              );
              for (final entry in _confirmedRoomWrites.entries) {
                roomsById.putIfAbsent(entry.key, () => entry.value);
              }
              state = roomsById.values.toList();
              _nodeCounter = Room.highestEsp32Counter(state);
              unawaited(_saveRooms(houseId: houseId).catchError((_) {}));
            },
            onError: (Object error, StackTrace stack) {
              if (_activeHouseId == houseId &&
                  _listenerGeneration == listenerGeneration) {
                ref.read(roomSyncErrorProvider.notifier).state =
                    'Rooms could not be synchronized. Check your connection and House access.';
              }
            },
          );
    } else {
      state = [];
    }
    ref.onDispose(() => _subscription?.cancel());
    return [];
  }

  String? _normalizedMqttNodeId(String? mqttNodeId) {
    final trimmed = mqttNodeId?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }

  String? _mqttNodeError(String? mqttNodeId, {String? exceptRoomId}) {
    final normalized = _normalizedMqttNodeId(mqttNodeId);
    if (normalized == null) return null;
    if (!Room.isSupportedMqttNodeId(normalized)) {
      return 'Choose ROOM1_NODE or ROOM2_NODE.';
    }
    final taken = state.any(
      (room) => room.id != exceptRoomId && room.mqttNodeId == normalized,
    );
    if (taken) {
      return '$normalized is already assigned to another room.';
    }
    return null;
  }

  Future<void> _saveRooms({String? houseId}) async {
    final encoded = jsonEncode(state.map((r) => r.toMap()).toList());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(getStorageKey(houseId: houseId), encoded);
  }

  /// Owner-triggered, create-only migration for the legacy House-scoped cache.
  Future<String> migrateLocalHouseData() async {
    final user = ref.read(userProvider);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final houseId = user?.houseId?.trim();
    if (user == null ||
        user.role != UserRole.owner ||
        !user.isApproved ||
        uid == null ||
        user.id != uid ||
        houseId == null ||
        houseId.isEmpty) {
      return 'Only the signed-in, approved House owner can migrate local data.';
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final roomJson = prefs.getString('shared_house_rooms_db_$houseId');
      final deviceJson = prefs.getString('shared_house_devices_db_$houseId');
      final rooms =
          roomJson == null
              ? <Room>[]
              : (jsonDecode(roomJson) as List)
                  .map(
                    (row) =>
                        Room.fromMap(Map<String, dynamic>.from(row as Map)),
                  )
                  .toList();
      final devices =
          deviceJson == null
              ? <Device>[]
              : (jsonDecode(deviceJson) as List)
                  .map(
                    (row) =>
                        Device.fromMap(Map<String, dynamic>.from(row as Map)),
                  )
                  .toList();
      if (rooms.isEmpty && devices.isEmpty)
        return 'No local Rooms or Devices need migration.';
      if (rooms.any((room) => room.id.isEmpty || room.creatorId != uid) ||
          rooms.map((room) => room.id).toSet().length != rooms.length) {
        return 'Migration stopped: local Rooms are not uniquely attributable to this House owner.';
      }
      final roomIds = rooms.map((room) => room.id).toSet();
      if (devices.any((device) => device.id.isEmpty || device.roomId.isEmpty) ||
          devices.map((device) => device.id).toSet().length != devices.length) {
        return 'Migration stopped: a local Device has an invalid or ambiguous Room relationship.';
      }

      final houseRef = FirebaseFirestore.instance
          .collection('houses')
          .doc(houseId);
      final houseSnapshot = await houseRef.get();
      final houseData = houseSnapshot.data();
      if (!houseSnapshot.exists ||
          houseData?['houseId'] != houseId ||
          houseData?['ownerUid'] != uid) {
        return 'Migration stopped: the signed-in owner could not verify this House record.';
      }
      for (final device in devices.where(
        (item) => !roomIds.contains(item.roomId),
      )) {
        if (!(await houseRef.collection('rooms').doc(device.roomId).get())
            .exists) {
          return 'Migration stopped: Device ${device.id} refers to a Room that cannot be verified in this House.';
        }
      }

      final roomRefs = {
        for (final room in rooms)
          room.id: houseRef.collection('rooms').doc(room.id),
      };
      final deviceRefs = {
        for (final device in devices)
          device.id: houseRef.collection('devices').doc(device.id),
      };
      final existingRooms = <String, Map<String, dynamic>>{};
      final existingDevices = <String, Map<String, dynamic>>{};
      for (final room in rooms) {
        final snapshot = await roomRefs[room.id]!.get();
        if (snapshot.exists) existingRooms[room.id] = snapshot.data()!;
      }
      for (final device in devices) {
        final snapshot = await deviceRefs[device.id]!.get();
        if (snapshot.exists) existingDevices[device.id] = snapshot.data()!;
      }
      for (final room in rooms) {
        final existing = existingRooms[room.id];
        if (existing != null &&
            room.toMap().entries.any(
              (entry) => existing[entry.key] != entry.value,
            )) {
          return 'Migration stopped: cloud Room ${room.id} already exists with different data.';
        }
      }
      for (final device in devices) {
        final existing = existingDevices[device.id];
        final expected = _sharedDeviceData(device);
        if (existing != null &&
            expected.entries.any(
              (entry) => existing[entry.key] != entry.value,
            )) {
          return 'Migration stopped: cloud Device ${device.id} already exists with different data.';
        }
      }

      for (final room in rooms.where(
        (item) => !existingRooms.containsKey(item.id),
      )) {
        await FirebaseFirestore.instance.runTransaction((transaction) async {
          final snapshot = await transaction.get(roomRefs[room.id]!);
          if (snapshot.exists) {
            final data = snapshot.data()!;
            if (room.toMap().entries.any(
              (entry) => data[entry.key] != entry.value,
            )) {
              throw StateError('Room ${room.id} changed during migration.');
            }
          } else {
            transaction.set(roomRefs[room.id]!, room.toMap());
          }
        });
      }
      for (final device in devices.where(
        (item) => !existingDevices.containsKey(item.id),
      )) {
        await FirebaseFirestore.instance.runTransaction((transaction) async {
          final reference = deviceRefs[device.id]!;
          final snapshot = await transaction.get(reference);
          final expected = _sharedDeviceData(device);
          if (snapshot.exists) {
            final data = snapshot.data()!;
            if (expected.entries.any(
              (entry) => data[entry.key] != entry.value,
            )) {
              throw StateError('Device ${device.id} changed during migration.');
            }
          } else {
            transaction.set(reference, expected);
          }
        });
      }
      for (final reference in [...roomRefs.values, ...deviceRefs.values]) {
        if (!(await reference.get()).exists)
          return 'Migration could not verify every cloud record; local data was retained.';
      }
      return 'Migration complete: ${rooms.length} Rooms and ${devices.length} Devices verified. Local data was retained.';
    } catch (_) {
      return 'Migration failed before verification. Local data was retained; retry after resolving Firestore access.';
    }
  }

  Future<String?> addRoom(
    String name,
    String iconAsset,
    String creatorId,
    String creatorName, {
    String? mqttNodeId,
  }) async {
    if (name.trim().isEmpty) return 'Room name cannot be empty';
    if (state.length >= 5) return 'Maximum 5 rooms allowed';

    final isDuplicate = state.any(
      (r) => r.name.trim().toLowerCase() == name.trim().toLowerCase(),
    );
    if (isDuplicate) {
      return 'Room "$name" already exists. Please choose a different name.';
    }
    final nodeError = _mqttNodeError(mqttNodeId);
    if (nodeError != null) return nodeError;

    _nodeCounter = Room.highestEsp32Counter(state);
    _nodeCounter++;
    final nodeId = 'NODE_${_nodeCounter.toString().padLeft(3, '0')}';

    final room = Room(
      id: _uuid.v4(),
      name: name.trim(),
      iconAsset: iconAsset,
      esp32NodeId: nodeId,
      mqttNodeId: _normalizedMqttNodeId(mqttNodeId),
      creatorId: creatorId,
      creatorName: creatorName,
    );

    final houseId = ref.read(userProvider)?.houseId?.trim();
    if (houseId == null ||
        houseId.isEmpty ||
        ref.read(userProvider)?.isApproved != true ||
        ref.read(userProvider)?.id != FirebaseAuth.instance.currentUser?.uid)
      return 'An approved House member is required.';
    if (creatorId != FirebaseAuth.instance.currentUser?.uid) {
      return 'The Room creator must be the signed-in House member.';
    }
    try {
      await FirebaseFirestore.instance
          .collection('houses')
          .doc(houseId)
          .collection('rooms')
          .doc(room.id)
          .set(room.toMap());
    } on FirebaseException catch (error) {
      return _firestoreWriteError('Room', error);
    } catch (error) {
      return 'Room could not be saved to the House. $error';
    }
    if (_activeHouseId != houseId) return null;
    _confirmedRoomWrites[room.id] = room;
    if (!state.any((existing) => existing.id == room.id)) {
      state = [...state, room];
    }
    try {
      await _saveRooms(houseId: houseId);
    } catch (_) {
      // Firestore is authoritative; a local cache failure cannot undo the
      // completed cloud write or make the dialog report that it failed.
    }
    return null;
  }

  Future<String?> editRoom(
    String id,
    String name,
    String iconAsset, {
    String? mqttNodeId,
  }) async {
    if (name.trim().isEmpty) return 'Room name cannot be empty';

    if (state.any(
      (r) =>
          r.id != id &&
          r.name.trim().toLowerCase() == name.trim().toLowerCase(),
    )) {
      return 'Room "$name" already exists. Please choose a different name.';
    }
    final nodeError = _mqttNodeError(mqttNodeId, exceptRoomId: id);
    if (nodeError != null) return nodeError;

    final roomMatches = state.where((r) => r.id == id);
    final existing = roomMatches.isEmpty ? null : roomMatches.first;
    if (existing == null) return 'Room no longer exists.';
    final updated = existing.copyWith(
      name: name.trim(),
      iconAsset: iconAsset,
      mqttNodeId: _normalizedMqttNodeId(mqttNodeId),
    );
    final houseId = ref.read(userProvider)?.houseId?.trim();
    if (houseId == null ||
        houseId.isEmpty ||
        ref.read(userProvider)?.isApproved != true ||
        ref.read(userProvider)?.id != FirebaseAuth.instance.currentUser?.uid)
      return 'An approved House member is required.';
    try {
      await FirebaseFirestore.instance
          .collection('houses')
          .doc(houseId)
          .collection('rooms')
          .doc(id)
          .update(updated.toMap());
    } catch (_) {
      return 'Room could not be updated in the House. Please try again.';
    }
    if (_activeHouseId != houseId) return null;
    state =
        state.map((r) {
          if (r.id == id) {
            return r.copyWith(
              name: name.trim(),
              iconAsset: iconAsset,
              mqttNodeId: _normalizedMqttNodeId(mqttNodeId),
            );
          }
          return r;
        }).toList();
    _saveRooms(houseId: houseId);
    return null;
  }

  Future<String?> removeRoom(String roomId) async {
    final user = ref.read(userProvider);
    final houseId = user?.houseId?.trim();
    if (houseId == null ||
        houseId.isEmpty ||
        user?.isApproved != true ||
        user?.id != FirebaseAuth.instance.currentUser?.uid) {
      return 'An approved House member is required.';
    }
    final house = FirebaseFirestore.instance.collection('houses').doc(houseId);
    try {
      final roomRef = house.collection('rooms').doc(roomId);
      final roomSnapshot = await roomRef.get();
      if (!roomSnapshot.exists) return 'Room no longer exists.';
      final room = Room.fromMap({
        ...roomSnapshot.data()!,
        'id': roomSnapshot.id,
      });
      if (user!.role != UserRole.owner && room.creatorId != user.id) {
        return 'You can delete only rooms you created.';
      }
      if (roomSnapshot.data()?['deletionInProgress'] != true) {
        await roomRef.update({'deletionInProgress': true});
      }
      final devices =
          await house
              .collection('devices')
              .where('roomId', isEqualTo: roomId)
              .get();
      for (var offset = 0; offset < devices.docs.length; offset += 450) {
        final batch = FirebaseFirestore.instance.batch();
        for (final device in devices.docs.skip(offset).take(450)) {
          batch.delete(device.reference);
        }
        await batch.commit();
      }
      await roomRef.delete();
    } catch (_) {
      return 'Room could not be completely deleted. Please retry.';
    }
    if (_activeHouseId != houseId) return null;
    state = state.where((r) => r.id != roomId).toList();
    _saveRooms(houseId: houseId);
    ref.read(devicesProvider.notifier).removeDevicesInRoom(roomId);
    return null;
  }
}

final roomsProvider = NotifierProvider<RoomsNotifier, List<Room>>(
  RoomsNotifier.new,
);

// --- ACCESS CONTROL FILTER FOR ROOMS ---
final visibleRoomsProvider = Provider<List<Room>>((ref) {
  final user = ref.watch(userProvider);
  final allRooms = ref.watch(roomsProvider);

  if (user == null || !user.isApproved) return [];
  if (user.role == UserRole.owner) return allRooms;

  return allRooms.where((r) => user.assignedRoomIds.contains(r.id)).toList();
});

// ═══════════════════════════════════════════
// DEVICE STATE MANAGEMENT
// ═══════════════════════════════════════════

/// Outcome of the existing sequential, per-device OFF operation.
class AllDevicesOffResult {
  const AllDevicesOffResult({
    required this.controllableCount,
    required this.alreadyOffCount,
    required this.turnedOffCount,
    required this.failedCount,
  });

  final int controllableCount;
  final int alreadyOffCount;
  final int turnedOffCount;
  final int failedCount;

  String get message {
    if (controllableCount == 0) return 'No controllable devices found.';
    if (failedCount > 0) {
      return '$turnedOffCount devices turned OFF. '
          '$alreadyOffCount already OFF. '
          '$failedCount devices could not be turned OFF. Please try again.';
    }
    if (alreadyOffCount == controllableCount) {
      return 'All devices are already OFF.';
    }
    return 'All devices have been turned OFF.';
  }
}

class DevicesNotifier extends Notifier<List<Device>> {
  Timer? _sensorTimer;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;
  String? _activeHouseId;
  int _listenerGeneration = 0;
  final Map<String, Device> _confirmedDeviceWrites = {};

  // --- UPGRADED: House-Specific Storage Key ---
  String getStorageKey({String? houseId}) {
    final user = ref.read(userProvider);
    return 'shared_house_devices_db_${houseId ?? user?.houseId ?? 'default'}';
  }

  @override
  List<Device> build() {
    _subscription?.cancel();
    final user = ref.watch(userProvider);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final houseId =
        user?.isApproved == true && user?.id == uid
            ? user?.houseId?.trim()
            : null;
    final listenerGeneration = ++_listenerGeneration;
    if (_activeHouseId != houseId) _confirmedDeviceWrites.clear();
    _activeHouseId = houseId;
    ref.read(deviceSyncErrorProvider.notifier).state = null;
    if (houseId != null && houseId.isNotEmpty) {
      if (user?.role == UserRole.member && user!.assignedRoomIds.isEmpty) {
        state = [];
        return [];
      }
      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collection('houses')
          .doc(houseId)
          .collection('devices');
      if (user?.role == UserRole.member) {
        query = query.where('roomId', whereIn: user!.assignedRoomIds);
      }
      _subscription = query
          .snapshots(includeMetadataChanges: true)
          .listen(
            (snapshot) {
              if (_activeHouseId != houseId ||
                  _listenerGeneration != listenerGeneration) {
                return;
              }
              ref.read(deviceSyncErrorProvider.notifier).state = null;
              final live = {for (final d in state) d.id: d};
              final devicesById = <String, Device>{};
              for (final doc in snapshot.docs.where(
                (doc) => !doc.metadata.hasPendingWrites,
              )) {
                    final cloud = Device.fromMap({...doc.data(), 'id': doc.id});
                    final previous = live[cloud.id];
                    final cloudData = doc.data();
                    devicesById[cloud.id] = cloud.copyWith(
                      isOn: cloudData['isOn'] is bool ? cloudData['isOn'] as bool : (previous?.isOn ?? false),
                      fanSpeed: cloudData['fanSpeed'] is int ? cloudData['fanSpeed'] as int : (previous?.fanSpeed ?? 0),
                      acTemperature: cloudData['acTemperature'] is int ? cloudData['acTemperature'] as int : (previous?.acTemperature ?? 24),
                      sensorValue: cloudData['sensorValue'] is num ? (cloudData['sensorValue'] as num).toDouble() : (previous?.sensorValue ?? 0.0),
                    );
              }
              _confirmedDeviceWrites.removeWhere(
                (deviceId, _) => devicesById.containsKey(deviceId),
              );
              for (final entry in _confirmedDeviceWrites.entries) {
                devicesById.putIfAbsent(entry.key, () => entry.value);
              }
              state = devicesById.values.toList();
              unawaited(_saveDevices(houseId: houseId).catchError((_) {}));
            },
            onError: (Object error, StackTrace stack) {
              if (_activeHouseId == houseId &&
                  _listenerGeneration == listenerGeneration) {
                ref.read(deviceSyncErrorProvider.notifier).state =
                    'Devices could not be synchronized. Check your connection and House access.';
              }
            },
          );
    } else {
      state = [];
    }
    ref.onDispose(() => _subscription?.cancel());
    _startSensorSimulation();
    ref.onDispose(() {
      _sensorTimer?.cancel();
    });
    return [];
  }

  Future<void> _saveDevices({String? houseId}) async {
    final encoded = jsonEncode(state.map((d) => d.toMap()).toList());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(getStorageKey(houseId: houseId), encoded);
  }

  void _startSensorSimulation() {
    _sensorTimer?.cancel();
    final iot = IoTSimulationService();

    _sensorTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      final currentDevices = state;
      bool changed = false;

      final newDevices =
          currentDevices.map((d) {
            if (d.type == DeviceType.sensor) {
              final newValue = iot.generateSensorValue(
                d.sensorType,
                d.sensorValue,
              );
              if (newValue != d.sensorValue) {
                changed = true;
                return d.copyWith(
                  sensorValue: double.parse(newValue.toStringAsFixed(1)),
                );
              }
            }
            return d;
          }).toList();

      if (changed) {
        state = newDevices;
      }
    });
  }

  Future<String?> addDevice(String name, DeviceType type, String roomId) async {
    if (name.trim().isEmpty) return 'Device name cannot be empty';

    final sensorType =
        type == DeviceType.sensor ? 'temperature' : 'temperature';
    final device = Device(
      id: _uuid.v4(),
      name: name.trim(),
      type: type,
      roomId: roomId,
      sensorValue: type == DeviceType.sensor ? 25.0 : 0.0,
      sensorType: sensorType,
      channel: Device.channelForType(type),
    );

    final user = ref.read(userProvider);
    final houseId = user?.houseId?.trim();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (houseId == null ||
        houseId.isEmpty ||
        user?.isApproved != true ||
        user?.id != uid ||
        uid == null)
      return 'An approved House member is required.';
    final roomMatches = ref
        .read(roomsProvider)
        .where((room) => room.id == roomId);
    if (roomMatches.isEmpty)
      return 'Choose a Room in the selected House.';
    final room = roomMatches.first;
    if (user!.role != UserRole.owner && room.creatorId != uid) {
      return 'Members can add Devices only to Rooms they created.';
    }
    try {
      await FirebaseFirestore.instance
          .collection('houses')
          .doc(houseId)
          .collection('devices')
          .doc(device.id)
          .set(_sharedDeviceData(device));
    } on FirebaseException catch (error) {
      return _firestoreWriteError('Device', error);
    } catch (error) {
      return 'Device could not be saved to the House. $error';
    }
    if (_activeHouseId != houseId) return null;
    _confirmedDeviceWrites[device.id] = device;
    if (!state.any((existing) => existing.id == device.id)) {
      state = [...state, device];
    }
    try {
      await _saveDevices(houseId: houseId);
    } catch (_) {
      // Keep the cloud-confirmed Device visible if local caching fails.
    }
    return null;
  }

  Future<String?> editDevice(String id, String name, DeviceType type) async {
    if (name.trim().isEmpty) return 'Device name cannot be empty';

    final deviceMatches = state.where((d) => d.id == id);
    final old = deviceMatches.isEmpty ? null : deviceMatches.first;
    if (old == null) return 'Device no longer exists.';
    final updated = old.copyWith(
      name: name.trim(),
      type: type,
      applyChannel: true,
      channel: Device.channelForType(type),
    );
    final houseId = ref.read(userProvider)?.houseId?.trim();
    if (houseId == null ||
        houseId.isEmpty ||
        ref.read(userProvider)?.isApproved != true ||
        ref.read(userProvider)?.id != FirebaseAuth.instance.currentUser?.uid)
      return 'An approved House member is required.';
    try {
      await FirebaseFirestore.instance
          .collection('houses')
          .doc(houseId)
          .collection('devices')
          .doc(id)
          .update({
            ..._sharedDeviceData(updated),
            'isOn': FieldValue.delete(),
            'fanSpeed': FieldValue.delete(),
            'acTemperature': FieldValue.delete(),
            'sensorValue': FieldValue.delete(),
          });
    } catch (_) {
      return 'Device could not be updated in the House. Please try again.';
    }
    if (_activeHouseId != houseId) return null;
    state =
        state.map((d) {
          if (d.id == id) {
            return d.copyWith(
              name: name.trim(),
              type: type,
              applyChannel: true,
              channel: Device.channelForType(type),
            );
          }
          return d;
        }).toList();
    _saveDevices(houseId: houseId);
    return null;
  }

  Future<String?> removeDevice(String deviceId) async {
    final user = ref.read(userProvider);
    final houseId = user?.houseId?.trim();
    if (houseId == null ||
        houseId.isEmpty ||
        user?.isApproved != true ||
        user?.id != FirebaseAuth.instance.currentUser?.uid)
      return 'An approved House member is required.';
    final matching = state.where((device) => device.id == deviceId);
    if (matching.isEmpty) return 'Device no longer exists.';
    final device = matching.first;
    final roomMatches = ref
        .read(roomsProvider)
        .where((room) => room.id == device.roomId);
    if (user!.role != UserRole.owner &&
        (roomMatches.isEmpty || roomMatches.first.creatorId != user.id)) {
      return 'You can delete devices only in rooms you created.';
    }
    try {
      await FirebaseFirestore.instance
          .collection('houses')
          .doc(houseId)
          .collection('devices')
          .doc(deviceId)
          .delete();
    } catch (_) {
      return 'Device could not be deleted. Please try again.';
    }
    if (_activeHouseId != houseId) return null;
    state = state.where((d) => d.id != deviceId).toList();
    _saveDevices(houseId: houseId);
    ref.read(automationProvider.notifier).removeRulesForDevice(deviceId);
    return null;
  }

  void removeDevicesInRoom(String roomId) {
    final devicesToRemove = state.where((d) => d.roomId == roomId).toList();

    state = state.where((d) => d.roomId != roomId).toList();
    _saveDevices();

    for (var device in devicesToRemove) {
      ref.read(automationProvider.notifier).removeRulesForDevice(device.id);
    }
  }

  // --- HARDWARE INTERACTION METHODS --- //

  String? lastCommandMessage;

  Room? _roomFor(Device device) {
    for (final room in ref.read(roomsProvider)) {
      if (room.id == device.roomId) return room;
    }
    return null;
  }

  void _syncDeviceStateToFirestore(String deviceId, Map<String, dynamic> data) {
    final houseId = ref.read(userProvider)?.houseId?.trim();
    if (houseId != null && houseId.isNotEmpty) {
      FirebaseFirestore.instance
          .collection('houses')
          .doc(houseId)
          .collection('devices')
          .doc(deviceId)
          .update(data)
          .catchError((_) {});
    }
  }

  CommandResult _failed(
    Device device,
    String action,
    String method,
    String message,
  ) => CommandResult(
    success: false,
    deviceId: device.id,
    roomId: device.roomId,
    action: action,
    method: method,
    timestamp: DateTime.now(),
    message: message,
  );

  Future<CommandResult> _command(
    Device device, {
    required String action,
    required String method,
  }) async {
    final mqtt = ref.read(mqttServiceProvider);
    final config = ref.read(mqttConfigProvider);
    final user = ref.read(userProvider);
    if (user == null || !user.isApproved) {
      return _failed(
        device,
        action,
        method,
        'House owner approval is required before controlling devices.',
      );
    }
    if (user.role == UserRole.member && !user.assignedRoomIds.contains(device.roomId)) {
      return _failed(
        device,
        action,
        method,
        'Access denied: You are not assigned to this room.',
      );
    }
    final isOnOff = action == 'ON' || action == 'OFF';
    final isRelay = Device.isRelayType(device.type);

    if (config.enabled && isOnOff && isRelay) {
      final room = _roomFor(device);
      final nodeId = room?.mqttNodeId?.trim();
      final hasExplicitNode = nodeId != null && nodeId.isNotEmpty;
      if (hasExplicitNode || device.channel != null) {
        if (!hasExplicitNode) {
          return _failed(
            device,
            action,
            method,
            'This room is not mapped to an ESP32 node.',
          );
        }
        if (!Room.isSupportedMqttNodeId(nodeId)) {
          return _failed(
            device,
            action,
            method,
            'This room is not mapped to an ESP32 node.',
          );
        }
        if (!Device.isChannelCompatible(device.type, device.channel)) {
          return _failed(
            device,
            action,
            method,
            'This ${device.type.name} does not have a valid relay channel.',
          );
        }
        return mqtt.publishDeviceCommand(
          houseId: ref.read(userProvider)?.houseId?.trim() ?? '',
          mqttDeviceId: nodeId,
          channel: device.channel!,
          state: action,
        );
      }

      final legacyMatch =
          device.type == DeviceType.light &&
          device.id == config.testAppDeviceId &&
          config.mappingError == null &&
          config.testChannel == Device.channelForType(DeviceType.light) &&
          Room.isSupportedMqttNodeId(config.testMqttDeviceId);
      if (legacyMatch) {
        return mqtt.publishDeviceCommand(
          houseId: ref.read(userProvider)?.houseId?.trim() ?? '',
          mqttDeviceId: config.testMqttDeviceId.trim(),
          channel: config.testChannel,
          state: action,
        );
      }

      return _failed(
        device,
        action,
        method,
        'This room is not mapped to an ESP32 node.',
      );
    }

    return mqtt.publishCommand(device: device, action: action, method: method);
  }

  /// Applies a PIR event already parsed from MQTT. Does not publish a command.
  ///
  /// A repeated event that does not change the light is ignored so the UI does
  /// not raise the same automation SnackBar again. Manual controls do not call
  /// this method.
  bool applyPirMotionEvent(PirMotionEvent event) {
    Room? room;
    for (final candidate in ref.read(roomsProvider)) {
      if (candidate.mqttNodeId == event.mqttNodeId) {
        room = candidate;
        break;
      }
    }
    if (room == null) return false;

    final lights =
        state
            .where(
              (device) =>
                  device.roomId == room!.id &&
                  device.type == DeviceType.light &&
                  Device.isChannelCompatible(device.type, device.channel),
            )
            .toList();
    if (lights.isEmpty) return false;
    final changing =
        lights.where((device) => device.isOn != event.lightOn).toList();
    if (changing.isEmpty) return false;

    final ids = changing.map((device) => device.id).toSet();
    state =
        state.map((device) {
          if (ids.contains(device.id)) {
            return device.copyWith(isOn: event.lightOn);
          }
          return device;
        }).toList();
    _saveDevices();

    for (final light in changing) {
      ref
          .read(activityLogProvider.notifier)
          .addLog(
            deviceId: light.id,
            deviceName: light.name,
            roomId: light.roomId,
            action: event.lightOn ? 'ON' : 'OFF',
            method: 'pir',
          );
    }
    ref
        .read(pirNoticeProvider.notifier)
        .show(
          PirAutomationNotice.forRoom(
            roomId: room.id,
            roomName: room.name,
            deviceId: changing.first.id,
            lightOn: event.lightOn,
          ),
        );
    return true;
  }

  Future<bool> toggleDevice(Device device, {String method = 'app'}) async {
    final newState = !device.isOn;
    final result = await _command(
      device,
      action: newState ? 'ON' : 'OFF',
      method: method,
    );
    lastCommandMessage = result.message;

    if (result.success) {
      state =
          state.map((d) {
            if (d.id == device.id) return d.copyWith(isOn: newState);
            return d;
          }).toList();
      _saveDevices();
      _syncDeviceStateToFirestore(device.id, {'isOn': newState});

      ref
          .read(activityLogProvider.notifier)
          .addLog(
            deviceId: device.id,
            deviceName: device.name,
            roomId: device.roomId,
            action: newState ? 'ON' : 'OFF',
            method: method,
          );
    }
    return result.success;
  }

  Future<bool> setFanSpeed(
    Device device,
    int speed, {
    String method = 'app',
  }) async {
    final result = await _command(
      device,
      action: 'SPEED_$speed',
      method: method,
    );
    lastCommandMessage = result.message;

    if (result.success) {
      state =
          state.map((d) {
            if (d.id == device.id) {
              return d.copyWith(fanSpeed: speed, isOn: speed > 0);
            }
            return d;
          }).toList();
      _saveDevices();
      _syncDeviceStateToFirestore(device.id, {'fanSpeed': speed, 'isOn': speed > 0});

      ref
          .read(activityLogProvider.notifier)
          .addLog(
            deviceId: device.id,
            deviceName: device.name,
            roomId: device.roomId,
            action: 'SPEED_$speed',
            method: method,
          );
    }
    return result.success;
  }

  Future<bool> setACTemperature(
    Device device,
    int temperature, {
    String method = 'app',
  }) async {
    final result = await _command(
      device,
      action: 'TEMP_$temperature',
      method: method,
    );
    lastCommandMessage = result.message;

    if (result.success) {
      state =
          state.map((d) {
            if (d.id == device.id) {
              return d.copyWith(acTemperature: temperature);
            }
            return d;
          }).toList();
      _saveDevices();
      _syncDeviceStateToFirestore(device.id, {'acTemperature': temperature});

      ref
          .read(activityLogProvider.notifier)
          .addLog(
            deviceId: device.id,
            deviceName: device.name,
            roomId: device.roomId,
            action: 'TEMP_$temperature',
            method: method,
          );
    }
    return result.success;
  }

  /// Cycles the current device value using the same setters as manual controls.
  Future<String> cycleDeviceAdjustment(
    String deviceId, {
    String method = 'app',
  }) async {
    // Resolve by ID at execution time so provider/remote updates are respected.
    final device = getById(deviceId);
    if (device == null) return 'Selected device is no longer available.';

    switch (device.type) {
      case DeviceType.fan:
        final current = device.fanSpeed;
        final next =
            current < DeviceControlLimits.minRunningFanSpeed ||
                    current >= DeviceControlLimits.maxFanSpeed
                ? DeviceControlLimits.minRunningFanSpeed
                : current + DeviceControlLimits.fanSpeedStep;
        // The manual fan slider is active while OFF; its setter handles power.
        final success = await setFanSpeed(device, next, method: method);
        return success
            ? '${device.name} speed set to $next.'
            : 'Could not adjust ${device.name}. Device not responding.';
      case DeviceType.ac:
        // The manual temperature slider is available only while the AC is ON.
        if (!device.isOn) {
          return 'Turn ${device.name} ON before adjusting temperature.';
        }
        final current = device.acTemperature;
        final next =
            current < DeviceControlLimits.minAcTemperature ||
                    current >= DeviceControlLimits.maxAcTemperature
                ? DeviceControlLimits.minAcTemperature
                : current + DeviceControlLimits.acTemperatureStep;
        final success = await setACTemperature(device, next, method: method);
        return success
            ? '${device.name} temperature set to $next degrees.'
            : 'Could not adjust ${device.name}. Device not responding.';
      case DeviceType.light:
      case DeviceType.sensor:
        return 'This device does not support adjustment.';
    }
  }

  Future<bool> turnOn(String deviceId, {String method = 'app'}) async {
    final device = state.firstWhere(
      (d) => d.id == deviceId,
      orElse: () => throw Exception('Device not found'),
    );
    if (device.isOn) return true;
    return toggleDevice(device, method: method);
  }

  Future<bool> turnOff(String deviceId, {String method = 'app'}) async {
    final device = state.firstWhere(
      (d) => d.id == deviceId,
      orElse: () => throw Exception('Device not found'),
    );
    if (!device.isOn) return true;
    return toggleDevice(device, method: method);
  }

  Future<AllDevicesOffResult> turnOffAll({String method = 'app'}) async {
    final user = ref.read(userProvider);
    if (user == null || !user.isApproved) {
      return const AllDevicesOffResult(
        controllableCount: 0,
        alreadyOffCount: 0,
        turnedOffCount: 0,
        failedCount: 0,
      );
    }
    // For members, only turn off devices in assigned rooms
    final devices = state.where((d) {
      if (d.type == DeviceType.sensor) return false;
      if (user.role == UserRole.member) {
        return user.assignedRoomIds.contains(d.roomId);
      }
      return true;
    }).toList();
    var alreadyOff = 0;
    var turnedOff = 0;
    var failed = 0;
    for (final device in devices) {
      if (!device.isOn) {
        alreadyOff++;
        continue;
      }
      try {
        // Re-read current state through the same OFF path as other controls.
        // Keep commands sequential, as in the original implementation.
        if (await turnOff(device.id, method: method)) {
          turnedOff++;
        } else {
          failed++;
        }
      } catch (_) {
        // A failed/unavailable device must not prevent the others going OFF.
        failed++;
      }
    }
    return AllDevicesOffResult(
      controllableCount: devices.length,
      alreadyOffCount: alreadyOff,
      turnedOffCount: turnedOff,
      failedCount: failed,
    );
  }

  List<Device> findByName(String name) {
    final lower = name.toLowerCase();
    return state.where((d) => d.name.toLowerCase().contains(lower)).toList();
  }

  Device? getById(String id) {
    try {
      return state.firstWhere((d) => d.id == id);
    } catch (_) {
      return null;
    }
  }
}

final devicesProvider = NotifierProvider<DevicesNotifier, List<Device>>(
  DevicesNotifier.new,
);

class PirNoticeNotifier extends Notifier<List<PirAutomationNotice>> {
  @override
  List<PirAutomationNotice> build() => [];

  void show(PirAutomationNotice notice) {
    state = [...state, notice];
  }
}

final pirNoticeProvider =
    NotifierProvider<PirNoticeNotifier, List<PirAutomationNotice>>(
      PirNoticeNotifier.new,
    );

/// Listens on the shared MQTT client while a house is signed in.
final mqttEventBridgeProvider = Provider<void>((ref) {
  final config = ref.watch(mqttConfigProvider);
  final user = ref.watch(userProvider);
  final houseId = user?.houseId?.trim() ?? '';
  final mqtt = ref.watch(mqttServiceProvider);
  if (!config.enabled || user?.isApproved != true || houseId.isEmpty) return;

  final subscription = mqtt.motionEvents.listen((event) {
    ref.read(devicesProvider.notifier).applyPirMotionEvent(event);
  });
  mqtt.subscribeToHouseEvents(houseId);
  ref.onDispose(() {
    subscription.cancel();
    mqtt.clearHouseEventSubscription();
  });
});

final visibleDevicesProvider = Provider<List<Device>>((ref) {
  final user = ref.watch(userProvider);
  final allDevices = ref.watch(devicesProvider);
  if (user == null || !user.isApproved) return [];
  if (user.role == UserRole.owner) return allDevices;
  return allDevices.where((d) => user.assignedRoomIds.contains(d.roomId)).toList();
});

final devicesByRoomProvider = Provider.family<List<Device>, String>((
  ref,
  roomId,
) {
  final user = ref.watch(userProvider);
  if (user == null || !user.isApproved) return [];
  if (user.role != UserRole.owner && !user.assignedRoomIds.contains(roomId)) {
    return [];
  }
  final devices = ref.watch(devicesProvider);
  return devices.where((d) => d.roomId == roomId).toList();
});

// ═══════════════════════════════════════════
// ACTIVITY LOG STATE
// ═══════════════════════════════════════════

class ActivityLogNotifier extends Notifier<List<ActivityLog>> {
  @override
  List<ActivityLog> build() {
    ref.watch(userProvider); // Naya User login par purane logs clear ho jayenge
    return [];
  }

  void addLog({
    required String deviceId,
    required String deviceName,
    required String roomId,
    required String action,
    required String method,
  }) {
    final log = ActivityLog(
      id: _uuid.v4(),
      deviceId: deviceId,
      deviceName: deviceName,
      roomId: roomId,
      action: action,
      method: method,
      timestamp: DateTime.now(),
    );

    state = [log, ...state];
  }
}

final activityLogProvider =
    NotifierProvider<ActivityLogNotifier, List<ActivityLog>>(
      ActivityLogNotifier.new,
    );

// ═══════════════════════════════════════════
// DASHBOARD UI HELPERS
// ═══════════════════════════════════════════

final activeDeviceCountProvider = Provider<int>((ref) {
  final user = ref.watch(userProvider);
  final devices = ref.watch(devicesProvider);
  if (user == null || !user.isApproved) return 0;
  return devices
      .where((d) {
        if (!d.isOn || d.type == DeviceType.sensor) return false;
        if (user.role == UserRole.owner) return true;
        return user.assignedRoomIds.contains(d.roomId);
      })
      .length;
});

final temperatureProvider = Provider<double>((ref) {
  final user = ref.watch(userProvider);
  final devices = ref.watch(devicesProvider);
  if (user == null || !user.isApproved) return 0.0;
  try {
    final sensor = devices.firstWhere(
      (d) =>
          d.type == DeviceType.sensor &&
          d.sensorType == 'temperature' &&
          (user.role == UserRole.owner || user.assignedRoomIds.contains(d.roomId)),
    );
    return sensor.sensorValue;
  } catch (_) {
    return 0.0;
  }
});
