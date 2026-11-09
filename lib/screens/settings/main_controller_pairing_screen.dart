import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/user.dart';
import '../../providers/auth_provider.dart';
import '../../providers/service_providers.dart';
import '../../providers/user_provider.dart';
import '../../services/main_controller_pairing_service.dart';

class MainControllerPairingScreen extends ConsumerStatefulWidget {
  const MainControllerPairingScreen({super.key});

  @override
  ConsumerState<MainControllerPairingScreen> createState() =>
      _MainControllerPairingScreenState();
}

class _MainControllerPairingScreenState
    extends ConsumerState<MainControllerPairingScreen> {
  static const _scanDuration = Duration(seconds: 12);

  StreamSubscription<MainControllerBleDevice>? _scanSubscription;
  Timer? _scanTimer;
  Timer? _unpairPollTimer;
  MainControllerPairingSession? _session;
  String? _pollingOperationId;
  bool _pollInFlight = false;
  final Map<String, MainControllerBleDevice> _devices = {};
  final Map<String, Stream<ControllerRegistryState>> _houseStatusStreams = {};
  bool _starting = false;
  bool _scanning = false;
  bool _pairing = false;
  bool _unpairing = false;
  String? _progress;
  String? _message;
  bool _messageIsError = false;
  String? _lastStatusErrorLog;

  @override
  void dispose() {
    _scanTimer?.cancel();
    _unpairPollTimer?.cancel();
    _scanSubscription?.cancel();
    // The token is only referenced in this State and is discarded on exit.
    _session = null;
    super.dispose();
  }

  bool _canManage(User? user) =>
      user != null &&
      user.role == UserRole.owner &&
      user.isApproved &&
      user.houseId != null &&
      user.houseId!.trim().isNotEmpty;

  Future<void> _startPairing(User user) async {
    if (!_canManage(user)) {
      _showMessage(
        'Only an approved House owner can pair a controller.',
        error: true,
      );
      return;
    }
    final service = ref.read(controllerPairingServiceProvider);
    setState(() {
      _starting = true;
      _message = null;
      _progress = 'Creating a secure pairing session…';
      _devices.clear();
    });
    try {
      final session = await service.createPairingSession(user);
      if (!mounted) return;
      _session = session;
      setState(() {
        _starting = false;
        _progress = null;
      });
      _startScan();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _starting = false;
        _progress = null;
      });
      _showMessage(_friendlyError(error), error: true);
    }
  }

  void _startScan() {
    final service = ref.read(controllerPairingServiceProvider);
    _scanTimer?.cancel();
    _scanSubscription?.cancel();
    setState(() {
      _scanning = true;
      _devices.clear();
      _message = null;
    });
    _scanSubscription = service.scanForControllers().listen(
      (device) {
        if (!mounted) return;
        setState(() => _devices[device.id] = device);
      },
      onError: (Object error) {
        if (!mounted) return;
        _finishScan();
        _showMessage(_friendlyError(error), error: true);
      },
    );
    _scanTimer = Timer(_scanDuration, _finishScan);
  }

  Future<void> _finishScan() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _pair(User user, MainControllerBleDevice device) async {
    final session = _session;
    if (session == null || !session.expiresAt.isAfter(DateTime.now())) {
      _session = null;
      _showMessage('The pairing session expired. Start again.', error: true);
      return;
    }
    setState(() {
      _pairing = true;
      _message = null;
      _progress = 'Connecting to ${device.name}…';
    });
    try {
      final result = await ref
          .read(controllerPairingServiceProvider)
          .pairWithController(
            user: user,
            session: session,
            device: device,
            onProgress: (value) {
              if (mounted) setState(() => _progress = value);
            },
          );
      if (!mounted) return;
      _session = null;
      setState(() {
        _pairing = false;
        _progress = null;
      });
      _showMessage('Main Controller ${result.controllerId} connected.');
    } catch (error) {
      if (!mounted) return;
      if (error is MainControllerPairingException &&
          error.code == 'expired-token') {
        _session = null;
      }
      setState(() {
        _pairing = false;
        _progress = null;
      });
      _showMessage(_friendlyError(error), error: true);
    }
  }

  Future<void> _cancelPairing() async {
    await ref.read(controllerPairingServiceProvider).cancelPairing();
  }

  Future<void> _confirmUnpair(User user, String controllerId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Disconnect Main Controller?'),
            content: Text(
              'This removes $controllerId from this House. The controller record and its history will remain.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Disconnect'),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _unpairing = true;
      _message = null;
    });
    try {
      final operation = await ref
          .read(controllerPairingServiceProvider)
          .requestUnpair(user, controllerId);
      if (!mounted) return;
      if (operation.status == 'completed') {
        _showMessage('Main Controller successfully disconnected.');
      } else {
        _showMessage('Unpair pending. Waiting for the controller.');
        _startUnpairPolling(user, operation.operationId);
      }
    } catch (error) {
      if (!mounted) return;
      _showMessage(_friendlyError(error), error: true);
    } finally {
      if (mounted) setState(() => _unpairing = false);
    }
  }

  void _ensureUnpairPolling(User user, ControllerRegistryState? state) {
    final operationId = state?.unpairOperationId;
    if (operationId == null ||
        (state?.unpairStatus != 'pending' &&
            state?.unpairStatus != 'prepared')) {
      return;
    }
    if (_pollingOperationId == operationId) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startUnpairPolling(user, operationId);
    });
  }

  void _startUnpairPolling(User user, String operationId) {
    if (!mounted || _pollingOperationId == operationId) return;
    _unpairPollTimer?.cancel();
    _pollingOperationId = operationId;
    _pollUnpairStatus(user, operationId);
    _unpairPollTimer = Timer.periodic(
      const Duration(seconds: 4),
      (_) => _pollUnpairStatus(user, operationId),
    );
  }

  Future<void> _pollUnpairStatus(User user, String operationId) async {
    if (_pollInFlight || !mounted || _pollingOperationId != operationId) return;
    _pollInFlight = true;
    try {
      final operation = await ref
          .read(controllerPairingServiceProvider)
          .getUnpairOperation(user, operationId);
      if (!mounted || _pollingOperationId != operationId) return;
      if (operation.status == 'completed') {
        _unpairPollTimer?.cancel();
        _unpairPollTimer = null;
        _pollingOperationId = null;
        _showMessage('Main Controller successfully disconnected.');
      } else if (operation.status == 'failed') {
        _unpairPollTimer?.cancel();
        _unpairPollTimer = null;
        _pollingOperationId = null;
        _showMessage(
          'Unpair failed. The controller remains assigned; you can retry.',
          error: true,
        );
      } else {
        _showMessage(
          operation.status == 'prepared'
              ? 'Unpair pending. Waiting for the controller to finish disconnecting.'
              : 'Unpair pending. Waiting for the controller.',
        );
      }
    } catch (_) {
      // The operation is durable. A transient status lookup failure is not a
      // successful disconnect and the next timer tick will reconcile again.
    } finally {
      _pollInFlight = false;
    }
  }

  String _friendlyError(Object error) {
    if (error is MainControllerPairingException) return error.message;
    if (error is TimeoutException) return 'The operation timed out. Try again.';
    if (error is FirebaseException) {
      if (error.code == 'permission-denied') {
        return 'Firebase denied this operation. Confirm you are the approved House owner.';
      }
      if (error.code == 'already-exists') {
        return 'This House or controller is already paired.';
      }
    }
    return 'Could not complete controller setup. Check Bluetooth and your connection, then try again.';
  }

  void _showMessage(String value, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = value;
      _messageIsError = error;
    });
  }

  String _safeFirebaseErrorMessage(String? message, User user) {
    var safeMessage = message?.trim() ?? '';
    if (safeMessage.isEmpty) safeMessage = 'No additional details.';
    for (final privateValue in [user.id, user.name, user.email, user.houseId]) {
      if (privateValue != null && privateValue.isNotEmpty) {
        safeMessage = safeMessage.replaceAll(privateValue, '[redacted]');
      }
    }
    return safeMessage
        .replaceAll(RegExp(r'https?://\S+'), '[redacted URL]')
        .replaceAll(RegExp(r'\b[A-Za-z0-9_-]{32,}\b'), '[redacted value]');
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userProvider);
    final isAuthenticated = ref.watch(firebaseAuthenticatedProvider);
    if (!isAuthenticated || !_canManage(user)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Main Controller')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Only an approved House owner can connect or disconnect a Main Controller.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final houseId = user!.houseId!.trim();
    final service = ref.read(controllerPairingServiceProvider);
    final statusStream = _houseStatusStreams.putIfAbsent(
      houseId,
      () => service.watchHouse(houseId),
    );
    return StreamBuilder<ControllerRegistryState>(
      stream: statusStream,
      builder: (context, registrySnapshot) {
        final registryState = registrySnapshot.data;
        final paired = registryState?.isPaired == true;
        final pendingUnpair =
            registryState?.unpairStatus == 'pending' ||
            registryState?.unpairStatus == 'prepared' ||
            registryState?.status == 'unpair_pending' ||
            registryState?.status == 'unpair_prepared';
        final confirmedMissingHouse =
            registryState != null && !registryState.houseExists;
        if (registrySnapshot.hasError) {
          final error = registrySnapshot.error;
          if (error is FirebaseException) {
            final safeMessage = _safeFirebaseErrorMessage(error.message, user);
            final signature = '${error.code}:$safeMessage';
            if (_lastStatusErrorLog != signature) {
              _lastStatusErrorLog = signature;
              debugPrint(
                'Main Controller status stream Firebase error '
                '(code: ${error.code}, message: $safeMessage)',
              );
            }
          }
        } else {
          _lastStatusErrorLog = null;
        }
        final pairingBlockedByRegistry =
            paired || pendingUnpair || confirmedMissingHouse;
        return Scaffold(
          appBar: AppBar(title: const Text('Main Controller')),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _connectionStatus(registrySnapshot, user),
              const SizedBox(height: 18),
              if (_progress != null) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 12),
                Text(_progress!, textAlign: TextAlign.center),
                const SizedBox(height: 12),
              ],
              if (_pairing)
                TextButton.icon(
                  onPressed: _cancelPairing,
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Cancel pairing'),
                ),
              if (_message != null)
                Card(
                  color:
                      _messageIsError
                          ? Colors.red.shade50
                          : _message?.contains('pending') == true
                          ? Colors.amber.shade50
                          : Colors.green.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(_message!),
                  ),
                ),
              if (_session != null && !_scanning && !_pairing)
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 12),
                  child: Text(
                    'Pairing session expires at ${TimeOfDay.fromDateTime(_session!.expiresAt).format(context)}. The token stays on this screen only.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              FilledButton.icon(
                onPressed:
                    (_starting ||
                            _scanning ||
                            _pairing ||
                            _unpairing ||
                            pairingBlockedByRegistry)
                        ? null
                        : () => _startPairing(user),
                icon:
                    _starting || _scanning
                        ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                        : const Icon(Icons.bluetooth_searching),
                label: Text(_session == null ? 'Start pairing' : 'Scan again'),
              ),
              if (_scanning)
                TextButton.icon(
                  onPressed: _finishScan,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop scanning'),
                ),
              if (_devices.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  'Nearby Main Controllers',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                for (final device in _devices.values)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.memory),
                      title: Text(device.name),
                      subtitle: Text('Signal ${device.rssi} dBm'),
                      trailing: FilledButton.tonal(
                        onPressed:
                            _pairing || _session == null
                                ? null
                                : () => _pair(user, device),
                        child: const Text('Connect & pair'),
                      ),
                    ),
                  ),
              ] else if (!_scanning && _session != null)
                const Padding(
                  padding: EdgeInsets.all(18),
                  child: Text(
                    'No compatible controller found. Put the Main ESP32 in pairing mode and scan again.',
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: 14),
              Text(
                'Keep your phone near the controller while setup is in progress.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _connectionStatus(
    AsyncSnapshot<ControllerRegistryState> snapshot,
    User user,
  ) {
    if (snapshot.connectionState == ConnectionState.waiting) {
      return const Card(
        child: ListTile(
          leading: CircularProgressIndicator(),
          title: Text('Checking controller status…'),
        ),
      );
    }
    if (snapshot.hasError) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.error_outline, color: Colors.red),
          title: Text('Controller status unavailable'),
        ),
      );
    }
    final state = snapshot.data;
    _ensureUnpairPolling(user, state);
    if (state == null || !state.houseExists) {
      return const Card(
        child: ListTile(
          leading: Icon(Icons.home_work_outlined),
          title: Text('House registry not found'),
          subtitle: Text('Contact support before pairing a controller.'),
        ),
      );
    }
    if (!state.isPaired) {
      if (state.unpairStatus == 'completed') {
        return const Card(
          child: ListTile(
            leading: Icon(Icons.bluetooth_disabled, color: Colors.green),
            title: Text('Main Controller successfully disconnected'),
          ),
        );
      }
      return const Card(
        child: ListTile(
          leading: Icon(Icons.bluetooth_disabled),
          title: Text('No Main Controller connected'),
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              state.status == 'unpair_pending' ||
                      state.status == 'unpair_prepared'
                  ? Icons.hourglass_top
                  : Icons.bluetooth_connected,
              color:
                  state.status == 'unpair_pending' ||
                          state.status == 'unpair_prepared'
                      ? Colors.orange
                      : Colors.green,
            ),
            title: Text(
              state.unpairStatus == 'pending' ||
                      state.unpairStatus == 'prepared'
                  ? 'Unpair pending'
                  : state.unpairStatus == 'failed'
                  ? 'Unpair failed; controller remains assigned'
                  : 'Main Controller connected',
            ),
            subtitle: Text(
              '${state.controllerId}\n${state.unpairStatus == 'prepared'
                  ? 'Waiting for controller to finish disconnecting'
                  : state.unpairStatus == 'pending'
                  ? 'Waiting for controller'
                  : 'Status: ${state.status ?? 'unknown'}'}',
            ),
            isThreeLine: true,
          ),
          if (state.pairedAt != null)
            ListTile(
              dense: true,
              title: const Text('Paired'),
              subtitle: Text(state.pairedAt!.toLocal().toString()),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: OutlinedButton.icon(
              onPressed:
                  _unpairing ||
                          _pairing ||
                          state.unpairStatus == 'pending' ||
                          state.unpairStatus == 'prepared'
                      ? null
                      : () => _confirmUnpair(user, state.controllerId!),
              icon:
                  _unpairing
                      ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Icon(Icons.link_off),
              label: Text(
                state.unpairStatus == 'failed'
                    ? 'Retry disconnect'
                    : 'Disconnect Controller',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
