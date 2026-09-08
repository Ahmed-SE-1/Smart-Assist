# Sign / Gesture Detection — Integration & Working

How the MediaPipe Gesture Recognizer is wired into Smart-Assist, from the camera
sensor to a device turning on.

---

## 1. Overview

Smart-Assist recognizes hand signs so a user can navigate rooms and control
devices without touching the screen. The pipeline is:

```
Camera sensor
  → camera plugin (Dart)          image stream of YUV420 frames
  → GestureRecognitionService     throttle + MethodChannel marshalling
  → MainActivity (Kotlin)         channel handler
  → GestureRecognizerHelper       YUV420 → Bitmap → MediaPipe inference
  → back over the channel         { gesture: "Thumb_Up", confidence: 0.91 }
  → RecognizedGesture.fromLabel   string → enum
  → GestureNavigationStateMachine enum + state → action
  → devicesProvider               actual device command
  → GestureTtsHelper              spoken confirmation
```

Recognition is **Android-only**. On any other platform
`GestureRecognitionService.isSupported` is `false`, the screen still shows the
camera and lists, and an inline notice explains that live recognition is
unavailable. Nothing crashes.

---

## 2. The model

| Property | Value |
|---|---|
| Model | MediaPipe Gesture Recognizer bundle |
| File | `gesture_recognizer.task` (~8 MB) |
| Load path | `android/app/src/main/assets/gesture_recognizer.task` |
| Native dependency | `com.google.mediapipe:tasks-vision:0.10.14` |
| Running mode | `RunningMode.IMAGE` (one-shot per frame) |

The `.task` bundle is self-contained — it holds the palm detector, the hand
landmark model, and the gesture classifier head. There is no separate label file;
category names come back from the bundle's own metadata.

### Where the file must live

The model is loaded natively via `BaseOptions.setModelAssetPath("gesture_recognizer.task")`,
which resolves against the **Android** asset manager — not Flutter's asset bundle.
So the copy that matters is:

```
android/app/src/main/assets/gesture_recognizer.task
```

`pubspec.yaml` also declares `assets/models/` as a Flutter asset directory. That
directory currently holds only a `README.txt`; it exists so the model can be
shipped through Flutter assets later (e.g. for an iOS bridge). If you drop a
model there, remember it does **not** feed the Android path. Keeping both copies
in sync is a manual step, documented in `assets/models/README.txt`.

### Recognized labels

Seven trained gestures plus two sentinels, modelled by `RecognizedGesture` in
[gesture_types.dart](../lib/features/gesture_control/models/gesture_types.dart):

| Enum | MediaPipe label | Emoji |
|---|---|---|
| `closedFist` | `Closed_Fist` | ✊ |
| `openPalm` | `Open_Palm` | ✋ |
| `pointingUp` | `Pointing_Up` | ☝️ |
| `thumbDown` | `Thumb_Down` | 👎 |
| `thumbUp` | `Thumb_Up` | 👍 |
| `victory` | `Victory` | ✌️ |
| `iLoveYou` | `ILoveYou` | 🤟 |
| `unknown` | `Unknown` / unmapped | ❔ |
| `none` | no hand in frame | ❔ |

`RecognizedGesture.fromLabel()` matches case-insensitively and falls back to
`unknown` for anything it does not recognize, so a retrained model with extra
categories degrades gracefully instead of throwing. `isActionable` is false for
`unknown` and `none` — those two can never trigger an action.

---

## 3. Layer-by-layer

### 3.1 Screen and camera setup

[`gesture_control_screen.dart`](../lib/features/gesture_control/gesture_control_screen.dart)
owns the session. `_bootstrap()` runs on `initState`:

1. `_syncDataFromProvider()` — pull rooms and devices from Riverpod into the
   state machine.
2. `_stateMachine.reset()` — start at the rooms list.
3. `_initCamera()` — request camera permission, enumerate cameras, prefer the
   **front** lens (a user signing at their own phone), start the stream.
4. `_recognitionService.initialize()` — load the model natively.
5. Speak an opening announcement through TTS.

Camera config in `_startCamera()`:

```dart
CameraController(
  camera,
  ResolutionPreset.medium,        // keeps per-frame conversion cheap
  enableAudio: false,
  imageFormatGroup: ImageFormatGroup.yuv420,
)
```

`ResolutionPreset.medium` is deliberate — the YUV→JPEG→Bitmap conversion cost
scales with pixel count, and the classifier does not need more resolution.
`yuv420` is required because the Kotlin side reconstructs NV21 from exactly three
planes.

If permission is denied, `_buildPermissionDenied()` renders instead of the body,
with a button that re-requests and falls through to `openAppSettings()` on a
permanent denial.

### 3.2 Frame throttling

`_onCameraFrame()` is the hot path — the camera fires it continuously. Three
guards keep it cheap:

```dart
if (_inCooldown || !_nativeReady) return;                    // 1. skip during cooldown
if (now.difference(_lastFrameProcessed) < _frameInterval) return;  // 2. ~8 fps cap
```

- `_frameInterval` = **120 ms**, so at most ~8 frames/sec reach the model. The
  camera may deliver 30 fps; the rest are dropped.
- During an action cooldown, frames are dropped entirely — no point classifying
  while input is being ignored.
- A third guard lives in the service: `_isProcessing` drops any frame that
  arrives while a previous inference is still in flight, so the MethodChannel
  never queues a backlog.

Together these three keep at most one inference in flight and bound CPU use.

### 3.3 Dart → native bridge

[`gesture_recognition_service.dart`](../lib/features/gesture_control/services/gesture_recognition_service.dart)
talks over a `MethodChannel` named
`com.example.smart_home/gesture_recognizer` with three methods:

| Method | Args | Returns |
|---|---|---|
| `initialize` | — | `bool` — model loaded |
| `detect` | `width`, `height`, `format`, `planes`, `bytesPerRow` | `{ gesture: String, confidence: double }` |
| `dispose` | — | `null` |

`detect` passes the raw plane bytes as a `List<Uint8List>`, which Flutter's
standard codec transfers to Kotlin as `List<ByteArray>`. Every call is wrapped in
a `PlatformException` catch that returns `GestureDetectionResult.none` — a native
failure degrades to "no gesture" rather than propagating an error into the UI.

### 3.4 Native handler

[`MainActivity.kt`](../android/app/src/main/kotlin/com/example/smart_home/MainActivity.kt)
registers the handler in `configureFlutterEngine`. It holds a nullable
`GestureRecognizerHelper`, validates arguments (`width > 0`, `height > 0`,
non-null planes), and returns the `"None"` / `0.0` map on anything unexpected.
`onDestroy()` closes the helper so the native recognizer is released even if
Flutter never calls `dispose`.

### 3.5 Inference

[`GestureRecognizerHelper.kt`](../android/app/src/main/kotlin/com/example/smart_home/GestureRecognizerHelper.kt)
does the real work.

**Setup** — `initialize()` builds the recognizer with all three MediaPipe
confidence floors set to `0.75`:

```kotlin
GestureRecognizer.GestureRecognizerOptions.builder()
    .setBaseOptions(BaseOptions.builder().setModelAssetPath(MODEL_ASSET).build())
    .setRunningMode(RunningMode.IMAGE)
    .setMinHandDetectionConfidence(0.75f)
    .setMinHandPresenceConfidence(0.75f)
    .setMinTrackingConfidence(0.75f)
    .build()
```

These gate the *hand detection* stages. The *gesture classification* score is
gated separately in Dart (see §4). Returns `false` on any exception — typically a
missing or corrupt `.task` file — which the screen surfaces as a "model failed to
load" message.

**Frame conversion** — `yuv420ToBitmap()` rebuilds an NV21 buffer from the three
incoming planes, interleaving chroma as `V, U, V, U…` and using `bytesPerRow` to
step correctly over row padding. That buffer goes through `YuvImage` →
`compressToJpeg(quality 80)` → `BitmapFactory.decodeByteArray`.

> This JPEG round-trip is the most expensive step in the pipeline, and it is why
> `ResolutionPreset.medium` and the 120 ms throttle matter. Every index write is
> bounds-checked (`uvIndex < vBuffer.size && offset + 1 < nv21.size`), so a
> device reporting unusual strides produces a degraded image rather than an
> `ArrayIndexOutOfBoundsException`.

**Classification** — the bitmap is wrapped in a `BitmapImageBuilder` and passed
to `recognizer.recognize(mpImage)`. `parseResult()` takes `gestures()[0]` — the
first detected hand — and its top-scoring category, returning the label and
score. Empty results become `"None"` / `0.0`.

### 3.6 Decision and execution

Back in Dart, `_onGestureDetected()`:

1. Updates `_detectedLabel`, `_detectedConfidence`, `_detectedGesture` for the
   UI — this happens for *every* result, including `Unknown`, so the user always
   sees live feedback.
2. Returns early unless `gesture.isActionable && confidence >= 0.75`.
3. Re-syncs rooms/devices — they may have changed while gesture mode was open.
4. Calls `_stateMachine.handleGesture(...)`.
5. If the result has an effect: start the cooldown, update the snapshot, speak
   the TTS message, then run the side effect.

`_executeAction()` maps the action type onto real work:

| Action | Effect |
|---|---|
| `turnOnDevice` | `devicesNotifier.turnOn(id, method: 'gesture')` |
| `turnOffDevice` | `devicesNotifier.turnOff(id, method: 'gesture')` |
| `exitMode` | `context.pop()` out of gesture mode |
| navigation actions | none — the snapshot update *is* the effect |

The `method: 'gesture'` tag lets the provider layer attribute the command to
gesture input.

---

## 4. Confidence and cooldown

**Two independent thresholds, both 0.75:**

- Kotlin's `MIN_CONFIDENCE` gates MediaPipe's hand detection / presence /
  tracking stages.
- Dart's `_confidenceThreshold` gates the classifier score, checked twice: once
  in `_onGestureDetected` and again inside
  `GestureNavigationStateMachine.handleGesture`. The state machine's own check
  makes it safe to unit-test and impossible to bypass from a future caller.

**Cooldown** — `_actionCooldown` is **1800 ms**. After any accepted action,
`_startCooldown()` sets `_inCooldown = true`, which both drops incoming frames
and shows a spinner in the app bar. This is the key usability guard: a hand held
in one pose for two seconds would otherwise fire the same action ~16 times. The
cooldown converts a held pose into exactly one action.

---

## 5. Navigation state machine

[`gesture_navigation_state_machine.dart`](../lib/features/gesture_control/state/gesture_navigation_state_machine.dart)
holds all navigation logic with **no Flutter or Riverpod imports** — it takes
plain `GestureRoomItem` / `GestureDeviceItem` records. That is what makes it
unit-testable, and it is covered by
[gesture_navigation_state_machine_test.dart](../test/gesture_navigation_state_machine_test.dart).

### States

```
roomsList ──✋──► devicesList ──✋──► deviceAction
    ◄────✊────       ◄────✊────
    ◄──────────🤟──────────────────────┘
```

### Gesture → action per state

| Sign | `roomsList` | `devicesList` | `deviceAction` |
|---|---|---|---|
| ☝️ `Pointing_Up` | next room | next device | ignored |
| 👎 `Thumb_Down` | previous room | previous device | ignored |
| ✋ `Open_Palm` | open room | select device | ignored |
| ✊ `Closed_Fist` | **exit mode** | back to rooms | back to devices |
| 🤟 `ILoveYou` | jump to rooms | jump to rooms | jump to rooms |
| 👍 `Thumb_Up` | ignored | ignored | **turn ON** |
| ✌️ `Victory` | ignored | ignored | **turn OFF** |

Design notes worth knowing:

- **Index-based, never name-based.** Movement is `(index ± 1) % length`, so
  wrapping is automatic and Urdu or any other room name works identically.
- **`Closed_Fist` at the root exits the mode.** "Back" from the top level means
  leaving, which is why the same sign both navigates and exits depending on depth.
- **Navigation signs are inert in `deviceAction`.** Only ON/OFF and the two
  escape signs apply, so a stray pointing gesture cannot silently move the
  selection while the user is aiming to toggle.
- **Sensors are rejected.** `_confirmSelection` checks `isControllable`
  (`type != DeviceType.sensor`) and returns a `none` action with the spoken
  message "… cannot be controlled by gesture" — feedback without a state change.
- **`_clampIndices()`** runs on every data update. If the selected room or device
  disappears, it drops the selection and walks the state back to a valid depth,
  which prevents a stale ID from being toggled.

Every accepted transition carries a `ttsMessage`, so the mode is fully usable
without looking at the screen.

---

## 6. UI feedback

Built in [gesture_control_widgets.dart](../lib/features/gesture_control/widgets/gesture_control_widgets.dart):

- **`GestureCameraOverlay`** — the live preview. Takes an `aspectRatio` (default
  3:4 portrait) rather than a fixed height; the screen computes it from available
  width, clamped between 240 px and 62 % of screen height. The feed is wrapped in
  `FittedBox(fit: BoxFit.cover)` so it fills the frame instead of letterboxing.
  A bottom bar shows the detected label and confidence percentage, and a corner
  button switches lenses.
- **`GestureGuideCard`** — the collapsible "which sign does what" list. Rows come
  from `gestureActionHintsFor(navState)`, which mirrors the state machine's
  switch. Signs that do nothing in the current state are shown **dimmed with a
  short reason** ("Turn ON — select device first") rather than hidden, so users
  learn the full vocabulary. The row for the currently detected gesture
  highlights once confidence clears 0.75.
- **`GestureNavigationList`** — rooms or devices, with the current index
  visually emphasised (larger text, accent border, "Selected" badge).
- **`GestureHintBar`** — compact chip row derived from the same hint source,
  filtered to available signs. Still available but not currently mounted; the
  guide card supersedes it.

`gestureActionHintsFor()` is the single source of truth for on-screen hints. When
you change a mapping in the state machine, update that function too — they are
intentionally parallel, but nothing enforces it automatically.

### TTS

[`GestureTtsHelper`](../lib/features/gesture_control/services/gesture_tts_helper.dart)
is separate from the app-wide `TtsService` on purpose: it **always** speaks during
a gesture session regardless of the global voice-feedback toggle, because gesture
mode is the accessibility path and silent operation would make it unusable. Rate
0.5, volume 1.0, `en-US`, and `stop()` before each `speak()` so stale
announcements never queue up behind current ones.

---

## 7. Lifecycle and teardown

`dispose()` on the screen releases everything in order:

```dart
_cooldownTimer?.cancel();
_cameraController?.stopImageStream();
_cameraController?.dispose();
_recognitionService.dispose();   // → native "dispose" → recognizer.close()
_tts.dispose();
```

Stopping the image stream before disposing the controller prevents a frame
callback firing against a disposed controller. `MainActivity.onDestroy()` is the
backstop that closes the native recognizer if the Dart side never gets there.

---

## 8. Failure modes

| Condition | Behaviour |
|---|---|
| Not Android | `isSupported == false`; camera and lists still work; notice shown |
| Model missing / corrupt | `initialize()` returns false; "MediaPipe model failed to load" |
| Camera permission denied | Dedicated screen with re-request → app settings |
| No camera on device | "No camera found on this device." |
| Native exception mid-frame | Logged, returns `None`/`0.0`, session continues |
| Unrecognized label | Mapped to `unknown`, not actionable, shown in orange |
| Selected device deleted | `_clampIndices()` unwinds state to a valid depth |
| Sensor selected | Spoken rejection, no state change |

The consistent pattern: every failure degrades to "no gesture detected" and the
session keeps running. Nothing in the recognition path can take down the screen.

---

## 9. Extending it

**Swap in a retrained model** — replace
`android/app/src/main/assets/gesture_recognizer.task` and rebuild. If your
categories keep the standard MediaPipe names, nothing else changes. New category
names need entries in `RecognizedGesture` (with `symbol` and `displayName`), a
branch in `handleGesture`, and a row in `gestureActionHintsFor`.

**Tune responsiveness** — `_frameInterval` (120 ms) trades CPU for latency;
`_actionCooldown` (1800 ms) trades accidental repeats for speed;
`_confidenceThreshold` (0.75) trades false positives for false negatives. Raising
the threshold means fewer wrong actions but more ignored signs.

**Reduce CPU further** — the JPEG round-trip in `yuv420ToBitmap` is the main
cost. A direct YUV→RGB conversion, or switching MediaPipe to
`RunningMode.LIVE_STREAM` with `ByteBuffer` input, would avoid it. That is the
first place to look if you see thermal throttling on low-end hardware.

**iOS support** — implement the same three-method channel contract against
MediaPipe's iOS Tasks SDK and widen
`GestureRecognitionService.isSupported`. No Dart logic above the service layer
would need to change.

---

## 10. File map

| File | Role |
|---|---|
| `lib/features/gesture_control/gesture_control_screen.dart` | Session owner: camera, throttling, orchestration |
| `lib/features/gesture_control/models/gesture_types.dart` | Enums, label parsing, snapshots, UI hint data |
| `lib/features/gesture_control/services/gesture_recognition_service.dart` | MethodChannel bridge |
| `lib/features/gesture_control/services/gesture_tts_helper.dart` | Always-on TTS for gesture mode |
| `lib/features/gesture_control/state/gesture_navigation_state_machine.dart` | Pure navigation logic |
| `lib/features/gesture_control/widgets/gesture_control_widgets.dart` | Camera overlay, guide card, lists |
| `lib/screens/features/gesture/gesture_screen.dart` | Router alias for `GestureControlScreen` |
| `android/.../MainActivity.kt` | Channel handler, native lifecycle |
| `android/.../GestureRecognizerHelper.kt` | MediaPipe setup, YUV conversion, inference |
| `android/app/src/main/assets/gesture_recognizer.task` | The model (~8 MB) |
| `android/app/build.gradle.kts` | `tasks-vision:0.10.14` dependency |
| `test/gesture_navigation_state_machine_test.dart` | State machine unit tests |

Route: `/home/gesture` — see [router.dart](../lib/core/router.dart).
