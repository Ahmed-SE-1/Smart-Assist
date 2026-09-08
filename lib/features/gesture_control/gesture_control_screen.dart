import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/theme.dart';
import '../../models/device.dart';
import '../../providers/smart_home_provider.dart';
import 'models/gesture_types.dart';
import 'services/gesture_recognition_service.dart';
import 'services/gesture_tts_helper.dart';
import 'state/gesture_navigation_state_machine.dart';
import 'widgets/gesture_control_widgets.dart';

/// Full-screen Gesture Control mode with live camera + MediaPipe recognition.
class GestureControlScreen extends ConsumerStatefulWidget {
  const GestureControlScreen({super.key});

  @override
  ConsumerState<GestureControlScreen> createState() => _GestureControlScreenState();
}

class _GestureControlScreenState extends ConsumerState<GestureControlScreen> {
  // ─── Services ───────────────────────────────────────────────────────────
  final GestureRecognitionService _recognitionService = GestureRecognitionService();
  final GestureTtsHelper _tts = GestureTtsHelper();
  late GestureNavigationStateMachine _stateMachine;

  // ─── Camera ─────────────────────────────────────────────────────────────
  CameraController? _cameraController;
  List<CameraDescription> _cameras = [];
  int _cameraIndex = 0;
  bool _cameraReady = false;
  bool _cameraPermissionDenied = false;

  // ─── Gesture pipeline ─────────────────────────────────────────────────────
  static const double _confidenceThreshold = 0.75;
  static const Duration _actionCooldown = Duration(milliseconds: 1800);

  String _detectedLabel = '';
  double _detectedConfidence = 0;
  RecognizedGesture _detectedGesture = RecognizedGesture.none;
  bool _inCooldown = false;
  Timer? _cooldownTimer;
  DateTime _lastFrameProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _frameInterval = Duration(milliseconds: 120);

  // ─── UI state ───────────────────────────────────────────────────────────
  GestureNavigationSnapshot _snapshot = const GestureNavigationSnapshot(
    navState: GestureNavState.roomsList,
    selectedRoomIndex: 0,
    selectedDeviceIndex: 0,
  );
  bool _nativeReady = false;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _stateMachine = GestureNavigationStateMachine(confidenceThreshold: _confidenceThreshold);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _syncDataFromProvider();
    _stateMachine.reset();
    setState(() => _snapshot = _stateMachine.snapshot());

    await _initCamera();
    if (_recognitionService.isSupported) {
      _nativeReady = await _recognitionService.initialize();
      if (!_nativeReady) {
        _initError = 'MediaPipe model failed to load. Place gesture_recognizer.task in assets/models/.';
      }
    } else {
      _initError = 'Live gesture recognition is supported on Android only.';
    }

    if (mounted) setState(() {});
    await _tts.speak('Gesture control mode. ${_headerLabel()}');
  }

  void _syncDataFromProvider() {
    final rooms = ref.read(visibleRoomsProvider);
    final devices = ref.read(devicesProvider);

    _stateMachine.updateData(
      rooms: rooms
          .map((r) => GestureRoomItem(id: r.id, name: r.name))
          .toList(),
      devices: devices
          .map(
            (d) => GestureDeviceItem(
              id: d.id,
              name: d.name,
              roomId: d.roomId,
              isControllable: d.type != DeviceType.sensor,
            ),
          )
          .toList(),
    );
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _cameraPermissionDenied = true);
      return;
    }

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        setState(() => _initError = 'No camera found on this device.');
        return;
      }

      // Prefer front camera for gesture control accessibility.
      _cameraIndex = _cameras.indexWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      if (_cameraIndex < 0) _cameraIndex = 0;

      await _startCamera(_cameraIndex);
    } catch (e) {
      setState(() => _initError = 'Camera error: $e');
    }
  }

  Future<void> _startCamera(int index) async {
    await _cameraController?.dispose();

    final camera = _cameras[index];
    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    await controller.initialize();

    if (!mounted) {
      await controller.dispose();
      return;
    }

    _cameraController = controller;
    _cameraReady = true;

    await controller.startImageStream(_onCameraFrame);

    setState(() {});
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    _cameraIndex = (_cameraIndex + 1) % _cameras.length;
    await _startCamera(_cameraIndex);
  }

  void _onCameraFrame(CameraImage image) {
    if (_inCooldown || !_nativeReady) return;

    final now = DateTime.now();
    if (now.difference(_lastFrameProcessed) < _frameInterval) return;
    _lastFrameProcessed = now;

    _recognitionService.detectFromCameraImage(image).then(_onGestureDetected);
  }

  Future<void> _onGestureDetected(GestureDetectionResult result) async {
    if (!mounted) return;

    setState(() {
      _detectedLabel = result.rawLabel.isEmpty
          ? (result.gesture == RecognizedGesture.none ? '' : result.gesture.label)
          : result.rawLabel;
      _detectedConfidence = result.confidence;
      _detectedGesture = result.gesture;
    });

    if (!result.gesture.isActionable || result.confidence < _confidenceThreshold) {
      return;
    }

    if (_inCooldown) return;

    // Keep lists fresh in case rooms/devices changed while in gesture mode.
    _syncDataFromProvider();

    final actionResult = _stateMachine.handleGesture(
      result.gesture,
      confidence: result.confidence,
    );

    if (!actionResult.hasEffect) return;

    _startCooldown();

    setState(() => _snapshot = actionResult.snapshot);

    if (actionResult.ttsMessage != null) {
      await _tts.speak(actionResult.ttsMessage!);
    }

    await _executeAction(actionResult);
  }

  void _startCooldown() {
    _inCooldown = true;
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer(_actionCooldown, () {
      if (mounted) setState(() => _inCooldown = false);
    });
  }

  Future<void> _executeAction(GestureNavActionResult result) async {
    final devicesNotifier = ref.read(devicesProvider.notifier);

    switch (result.action) {
      case GestureNavActionType.turnOnDevice:
        if (result.deviceId != null) {
          await devicesNotifier.turnOn(result.deviceId!, method: 'gesture');
        }
        break;
      case GestureNavActionType.turnOffDevice:
        if (result.deviceId != null) {
          await devicesNotifier.turnOff(result.deviceId!, method: 'gesture');
        }
        break;
      case GestureNavActionType.exitMode:
        if (mounted) _exitGestureMode();
        break;
      case GestureNavActionType.moveNext:
      case GestureNavActionType.movePrevious:
      case GestureNavActionType.confirmSelection:
      case GestureNavActionType.goBack:
      case GestureNavActionType.jumpToRooms:
      case GestureNavActionType.none:
        break;
    }
  }

  void _exitGestureMode() {
    _tts.speak('Gesture mode closed');
    context.pop();
  }

  String _headerLabel() {
    switch (_snapshot.navState) {
      case GestureNavState.roomsList:
        return 'Browsing rooms';
      case GestureNavState.devicesList:
        return 'Browsing devices';
      case GestureNavState.deviceAction:
        return 'Device control';
    }
  }

  List<String> _currentListItems() {
    switch (_snapshot.navState) {
      case GestureNavState.roomsList:
        return _stateMachine.rooms.map((r) => r.name).toList();
      case GestureNavState.devicesList:
      case GestureNavState.deviceAction:
        return _stateMachine.devicesInSelectedRoom.map((d) => d.name).toList();
    }
  }

  int _currentSelectedIndex() {
    switch (_snapshot.navState) {
      case GestureNavState.roomsList:
        return _snapshot.selectedRoomIndex;
      case GestureNavState.devicesList:
      case GestureNavState.deviceAction:
        return _snapshot.selectedDeviceIndex;
    }
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _recognitionService.dispose();
    _tts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-sync when provider data changes.
    ref.listen(visibleRoomsProvider, (_, __) {
      _syncDataFromProvider();
      if (mounted) setState(() => _snapshot = _stateMachine.snapshot());
    });
    ref.listen(devicesProvider, (_, __) {
      _syncDataFromProvider();
      if (mounted) setState(() => _snapshot = _stateMachine.snapshot());
    });

    return Scaffold(
      backgroundColor: AppTheme.backgroundColorDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: _exitGestureMode,
        ),
        title: const Text('Gesture Control', style: TextStyle(color: Colors.white)),
        actions: [
          if (_inCooldown)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primaryColor),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: _cameraPermissionDenied ? _buildPermissionDenied() : _buildBody(),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ElevatedButton.icon(
            onPressed: _exitGestureMode,
            icon: const Icon(Icons.exit_to_app),
            label: const Text('Exit Gesture Mode'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent.shade200,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionDenied() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.camera_alt_outlined, size: 72, color: Colors.grey.shade600),
          const SizedBox(height: 24),
          const Text(
            'Camera Permission Required',
            style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          const Text(
            'Gesture Control uses your camera to recognize hand gestures in real time. '
            'Please grant camera access to continue.',
            style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () async {
              final status = await Permission.camera.request();
              if (status.isGranted) {
                setState(() => _cameraPermissionDenied = false);
                await _initCamera();
              } else {
                await openAppSettings();
              }
            },
            child: const Text('Grant Camera Access'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - 40; // horizontal padding
        final screenHeight = MediaQuery.sizeOf(context).height;

        // Portrait 3:4 frame, capped so the guide below stays reachable.
        final previewHeight = (width * 4 / 3).clamp(240.0, screenHeight * 0.62);
        final previewAspect = width / previewHeight;

        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _headerLabel(),
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 12),

              if (_cameraReady && _cameraController != null)
                GestureCameraOverlay(
                  cameraPreview: _buildFilledPreview(_cameraController!),
                  detectedLabel: _detectedLabel,
                  confidence: _detectedConfidence,
                  onSwitchCamera: _switchCamera,
                  aspectRatio: previewAspect,
                  isFrontCamera:
                      _cameras.isNotEmpty &&
                      _cameras[_cameraIndex].lensDirection == CameraLensDirection.front,
                )
              else
                Container(
                  height: previewHeight,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.cardColorDark,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const CircularProgressIndicator(color: AppTheme.primaryColor),
                ),

              if (_initError != null) ...[
                const SizedBox(height: 8),
                Text(_initError!, style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
              ],

              const SizedBox(height: 16),
              GestureGuideCard(
                navState: _snapshot.navState,
                activeGesture: _detectedConfidence >= _confidenceThreshold
                    ? _detectedGesture
                    : null,
              ),
              const SizedBox(height: 16),

              GestureNavigationList(
                navState: _snapshot.navState,
                itemNames: _currentListItems(),
                selectedIndex: _currentSelectedIndex(),
                header: _snapshot.navState == GestureNavState.deviceAction
                    ? 'Selected device — use 👍 ON / ✌️ OFF'
                    : null,
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  /// Scales the camera feed to cover the whole preview frame instead of
  /// letterboxing inside it.
  Widget _buildFilledPreview(CameraController controller) {
    final previewSize = controller.value.previewSize;
    if (previewSize == null) return CameraPreview(controller);

    return ClipRect(
      child: OverflowBox(
        alignment: Alignment.center,
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            // previewSize is reported in sensor orientation (landscape).
            width: previewSize.height,
            height: previewSize.width,
            child: CameraPreview(controller),
          ),
        ),
      ),
    );
  }
}
