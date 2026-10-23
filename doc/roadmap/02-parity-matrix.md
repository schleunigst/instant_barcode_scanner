# Parity specification vs `mobile_scanner` 7.4.2 (Android)

Baseline: `~/.pub-cache/hosted/pub.dev/mobile_scanner-7.4.2/` (CameraX 1.6.1,
ML Kit barcode bundled by default; we use ML Kit + Camera2 directly).

This document started as a proposal and is now the **decision record + working
spec** for the parity program. The human is unavailable during implementation;
the decisions below were taken autonomously (see "Decisions" at the end) and
can be revisited when the human returns. Tranche A is implemented in the
working tree and verified by `flutter analyze`, the Dart suite, a debug APK
build, 4/4 instrumented tests, and the integration flows on the `pixel_bench`
emulator. Tranche B's
decoding work is implemented on the same gates (77 Dart tests); geometry
validation on two orientations/facings and the battery spot-check still need
a physical device (the emulator has one emulated back camera).

## Design stance

Parity means *the capabilities an app needs to replace mobile_scanner*, not
API mimicry. We keep:

- our lifecycle (`warmUp` / `scan` / `park` / `close` / NFC handoff / idle
  policy), because that is the product;
- truthful close and the HAL-availability completion guarantee;
- a platform-neutral API that AVFoundation can implement.

We add configuration and controls. We do **not** add `autoStart`, a second
`start/stop/pause` lifecycle, or a widget-owned controller lifecycle.

Mapping of mobile_scanner lifecycle calls for migration purposes:

| mobile_scanner | `instant_barcode_scanner` |
| --- | --- |
| `start()` (controller) | `warmUp()` then `scan()` from the screen; `scan()` alone works cold |
| `stop()` | `park()` (scripts staying on the screen) or `close()` (leaving) |
| `pause()` (app backgrounded) | platform closes on activity stop; app calls `warmUp()` on resume. No `pause()` needed |
| `dispose()` | `dispose()` (reset semantics; safe to recreate) |
| `autoStart` | not applicable — the screen/route calls `warmUp()` |

## Gap matrix

Legend: **have** = exists today; **gap** = parity work; **n/a** = deliberate
non-goal. Tranche letters refer to the plan below.

### A. Camera selection and configuration

| Feature | mobile_scanner API | Ours today | Plan |
| --- | --- | --- | --- |
| Facing direction | constructor `facing: CameraFacing.{back,front,external}`, `switchCamera(ToggleDirection())` | back camera hardcoded (`backCameraId` in `CameraSelection.kt`) | **A**: `facing` in `ScannerConfig`; `switchCamera()` toggles back/front when ≥2 cameras; `external` only if enum reserved |
| Lens type | `lensType: CameraLensType.{any,normal,wide,zoom}`; `switchCamera(ToggleLensType())`; `getSupportedLenses()`, `getBestCloseRangeScanningLens()` | none | **A**: config `lensType`; capabilities expose available lenses; selection heuristic from `CameraCharacteristics` (see Android notes); `getSupportedLenses()` equivalent |
| Resolution | `cameraResolution: Size?` (Android-only; default 640x480 in mobile_scanner) | pick largest ≤1280x720 YUV for analysis; preview size device-chosen | **A**: optional `cameraResolution` in config (Android-only); default stays our 1280x720 analysis budget |
| Torch | `torchEnabled`, `toggleTorch()`, `TorchState` in state | none | **A**: `setTorch(bool)`, `toggleTorch()`, `ValueListenable<TorchState> torchState`, capability `supportsTorch` |
| Zoom | `initialZoom`, `setZoomScale(0..1)`, `getZoomScale()`, `resetZoomScale()`, autoZoom (Android-only) | none | **A**: normalized zoom 0..1, `setZoom`, `resetZoom`, `ValueListenable<double> zoomScale`, capability `zoomRange`; `autoZoom` candidate in **B** |
| Focus point | `setFocusPoint(Offset)` (tap-to-focus) | none | **C** (view) / defer if device testing shows risk |
| Camera hardware enumeration | `availableCameras` in state; `MobileScannerState.cameraLensType` | none exposed | **A**: capabilities expose cameras/lenses; state exposes current `facing`/`lensType` |

### B. Decoding behavior

| Feature | mobile_scanner API | Ours today | Plan |
| --- | --- | --- | --- |
| Symbology filter | constructor `formats: List<BarcodeFormat>` (empty = all) | ML Kit defaults (all formats), no filter | **A**: `formats` in config; build `BarcodeScannerOptions`; recreate client when config differs |
| Detection throttle | `detectionSpeed: {noDuplicates, normal, unrestricted}` + `detectionTimeoutMs` (250 default) | single-flight (`busy` flag); no cooldown, no dedupe | **B**: implement semantics in pipeline (see Android notes); expose `detectionSpeed`, `detectionTimeout` in config |
| Multiple barcodes per frame | `BarcodeCapture.barcodes` (list) via `onDetect`/stream | platform already returns `List<PlatformBarcode>` per event; Dart `scan()` takes first; `scans` flattens | **B**: add `Stream<ScanEvent> scanEvents` carrying the batch (+ optional image); keep `scans` as flattened convenience |
| Result geometry | `Barcode.corners`, `Barcode.size` | none | **B**: add to `ScanResult` (`List<Offset>? corners`, `Size? size`); needed for scan window |
| Display value | `Barcode.displayValue` | none | **B**: add nullable `displayValue` (Android/iOS both provide it via ML Kit/AVFoundation metadata; iOS may differ — mark best-effort) |
| Barcode value type | `Barcode.type` (URL, WiFi, contact, …) | none | **B**: optional `BarcodeType` enum; Android-only mapping via ML Kit (`Barcode.valueType`), null elsewhere. Capability-gated |
| Scan window | widget `scanWindow`, `updateScanWindow(Rect?)`, `scanWindowUpdateThreshold` | none | **B**: `updateScanWindow(Rect? window)` + view integration; filter by mapped corners; Android-first, measure rotation math on device |
| Return frame image | `returnImage: bool` → `BarcodeCapture.image` (JPEG bytes) | none | **Deferred** (not in tranches A–C): YUV→JPEG per detection is the most expensive item and no target-app need is confirmed; revisit on request |
| Invert colors | `invertImage: bool` (Android-only) | none | **B** (Android-only, capability-gated): bitmap inversion for white-on-black symbols |
| Analyze a still image | `analyzeImage(String path, {formats})` | none | **B**: platform method using ML Kit `InputImage.fromFilePath`; no camera session; capability `supportsAnalyzeImage`; iOS simulator unsupported (same as mobile_scanner) — document |

### C. Widget / preview

| Feature | mobile_scanner API | Ours today | Plan |
| --- | --- | --- | --- |
| Preview fit | `fit: BoxFit` (default cover) | raw `Texture`, no aspect correction, no fit | **C**: aspect-ratio aware preview with `fit` (`BoxFit.cover/contain/fill`) |
| Overlay / placeholder / error builders | `overlayBuilder`, `placeholderBuilder`, `errorBuilder` | black until texture | **C**: `overlayBuilder` + `placeholderBuilder`; error handling stays via controller status (`errorBuilder` not needed but can be added) |
| Tap-to-focus | `tapToFocus: bool` | none | **C**/defer: needs focus metering plumbing; candidate |
| Lifecycle helper | `useAppLifecycleState` | app-driven; plugin closes on activity stop | **n/a** — keep app-driven |

### D. Permissions and errors

| Feature | mobile_scanner API | Ours today | Plan |
| --- | --- | --- | --- |
| Camera permission | requested on start; `MobileScannerErrorCode.permissionDenied` | no check; `SecurityException` → generic `open_failed` | **A**: request `CAMERA` via activity result on first open; map denial to `ScannerStatus(failed, errorCode: 'permission_denied')`; document retry path |
| Typed error codes | `MobileScannerException.errorCode` enum | `ScannerException` + platform `errorCode` strings | **A**: standardize codes: `permission_denied`, `camera_unavailable`, `configuration_failed`, `platform_error`, `unsupported`, `detached`; keep string codes (stable) |
| Unsupported feature behavior | throws / `UnsupportedError` | n/a | all Android-only knobs must throw or degrade per capability; never silently ignore |

### E. State model

| Feature | mobile_scanner | Ours today | Plan |
| --- | --- | --- | --- |
| Torch state | `TorchState` in `MobileScannerState` | none | **A**: `torchState` listenable |
| Zoom state | `zoomScale` in state | none | **A**: `zoomScale` listenable (normalized) |
| Camera direction / lens | state fields | add `facing`, `lensType` getters (from config/confirmed selection) | **A** |
| Device orientation | `deviceOrientation` in state | sensor rotation handled natively for analysis; preview has no orientation correction | **C** with preview work |
| Initialization/start flags | `isInitialized`, `isStarting`, `isRunning` | `state` (`opening`/`closing` not emitted in v0.1) | **n/a** — derive from `state`; do not add duplicate flags |

## API delta (proposal)

Additive; existing calls keep working. New symbols in parentheses are new
public types.

```dart
// New enums / types
enum CameraFacing { back, front, external }
enum CameraLensType { any, normal, wide, zoom }
enum DetectionSpeed { noDuplicates, normal, unrestricted }
enum TorchState { off, on, unavailable }
enum BarcodeType { url, wifi, text, contact, email, phone, sms, geo, calendar, driverLicense, unknown }

class ScannerConfig {
  const ScannerConfig({
    this.facing = CameraFacing.back,
    this.lensType = CameraLensType.any,
    this.formats = const <BarcodeFormat>[],
    this.torchEnabled = false,
    this.initialZoom,
    this.detectionSpeed = DetectionSpeed.normal,
    this.detectionTimeout = const Duration(milliseconds: 250),
    this.cameraResolution,      // Android-only, null = package default
    this.invertImage = false,   // Android-only
    this.returnImage = false,
  });
  // ...
}

class ScanEvent {
  final List<ScanResult> barcodes;
  final Uint8List? image;
}

// ScannerConfig is fixed for the controller's lifetime. Changing camera
// hardware or formats is a reconfiguration: dispose + new controller (cheap,
// dispose is a reset). Live-adjustable controls are methods below.

class InstantBarcodeScanner {
  InstantBarcodeScanner({
    ScannerConfig config = const ScannerConfig(),
    ScannerPolicy policy = const ScannerPolicy(),
    InstantBarcodeScannerPlatform? platform,
  });

  ValueListenable<TorchState> get torchState;
  ValueListenable<double> get zoomScale;      // normalized 0..1
  Stream<ScanEvent> get scanEvents;           // batches per frame

  Future<void> switchCamera();                // toggle back/front
  Future<void> setTorch(bool enabled);
  Future<void> toggleTorch();
  Future<void> setZoom(double scale);         // 0..1
  Future<void> resetZoom();
  Future<void> updateScanWindow(Rect? window);
  Future<Set<CameraLensType>> getSupportedLenses();
  Future<BarcodeCapture?> analyzeImage(String path, {List<BarcodeFormat> formats});
}
```

`ScanResult` gains nullable `displayValue`, `corners`, `size`, `type`.

Capabilities gain: `supportsTorch`, `supportsZoom`, `minZoom`, `maxZoom`,
`supportsReturnImage`, `supportsInvertImage`, `supportsAnalyzeImage`,
`supportsFocusPoint`, `lenses` (per facing), plus the existing
`supportsPark` / `supportsTrueClose`.

Pigeon delta (new channel calls + data): `configure` is not a call if config
is constructor-only; instead extend `getCapabilities`, add
`switchCamera(facing, lensType)`, `setTorch`, `setZoom`, `updateScanWindow`,
`analyzeImage`; barcode payload gains `displayValue`, `corners`, `size`,
`valueType`; barcode batch event optionally carries `image`.

## Android implementation notes

Architecture stays Camera2 + `ImageReader` + ML Kit. No CameraX migration in
this program (would rewrite the mechanism and the close contract).

- **Camera enumeration**: `CameraManager.cameraIdList`, filter
  `LENS_FACING`, read `LENS_INFO_AVAILABLE_FOCAL_LENGTHS`. Heuristic for
  `lensType`: sort focal lengths within a facing; `wide` = shortest, `zoom` =
  longest, `normal` = the default camera id (or middle value). Skip physical
  ids with no focal-length data. `any` = current default (first back).
  Validate on device: `pixel_bench` has wide/normal/tele; log chosen ids.
- **Reconfiguration**: camera + analysis pipeline are camera-scoped. Switching
  drives `closed` first, tears down `ImageReader`/session, rebuilds against the
  new id (fixes K3). `switchCamera()` is atomic from the caller's view (goes
  through the same mutex queue).
- **Torch**: `FLASH_INFO_AVAILABLE`; add `FLASH_MODE_TORCH` to the repeating
  request while `live`; torch off on `park`/`close`; report `unavailable`
  when absent. Re-apply after session reconfiguration.
- **Zoom**: prefer `CONTROL_ZOOM_RATIO` (API 30+), fall back to
  `SCALER_CROP_REGION` mapped against sensor active array; capability range
  from `CONTROL_ZOOM_RATIO_RANGE` or `SCALER_AVAILABLE_MAX_DIGITAL_ZOOM`.
  Normalized 0..1 maps linearly to `[minZoom, maxZoom]`.
- **Formats**: map to `BarcodeScannerOptions`; the ML Kit client is created
  once per pipeline (camera-scoped), so formats are part of pipeline
  construction.
- **Detection speed** (approximation, document the differences):
  - `normal`: single-flight + drop frames until `detectionTimeout` after a
    delivered batch (mobile_scanner's 250 ms default);
  - `unrestricted`: single-flight only; process the next available frame
    immediately;
  - `noDuplicates`: suppress a barcode whose `(format, rawBytes ?? text)` signature
    matches the last delivered one; deliver again when a different signature
    appears. ML Kit still analyzes every frame; we filter results.
- **Batches**: already available natively. Dart side must not flatten away
  the batch; `scanEvents` exposes it, `scans` remains a convenience.
- **Scan window**: view passes a `Rect` in view coordinates; platform maps
  through preview transform/rotation and checks `barcode.boundingBox` corners.
  This is the highest-risk geometry item — instrumented tests + manual matrix
  before shipping. Android-first.
- **returnImage**: encode only when a batch is detected; YUV_420_888 →
  NV21 → JPEG. Measure cost; capability on. iOS later via
  `AVCapturePhotoOutput`/pixel buffer.
- **invertImage**: YUV → Bitmap → invert → ML Kit on bitmap (Android-only;
  matches mobile_scanner's cost note).
- **analyzeImage**: `InputImage.fromFilePath` on the analysis worker; no
  camera touched; returns one batch; reuses format mapping.
- **Permission**: request from the host activity before the first open; suspend
  the drive until the result arrives; deny → `permission_denied`; permanently
  denied → same code with `errorDetails` string. `ActivityAware` already in
  place for lifecycle; reuse its binding.
- **Capabilities**: `getCapabilities` reads the selected camera's
  characteristics (flash, zoom range, facing/lens inventory) instead of
  hardcoding. Must stay correct after camera switches.

## iOS implications (pre-implementation)

- Facing/lens: `AVCaptureDevice.DeviceType` wide/ultra-wide/tele; equivalent
  heuristic. Torch `hasTorch`/`torchMode`; zoom `videoZoomFactor`, min/max.
- Formats: `AVCaptureMetadataOutput.metadataObjectTypes` (subset of ML Kit
  formats; `rawBytes` availability differs; `displayValue` semantics differ).
  Capability negotiation, not silent parity claims.
- Scan window: `metadataOutput.rectOfInterest` exists but uses normalized
  coordinates and has known device quirks — test before promising.
- `returnImage`/`analyzeImage`: feasible (photo output / `VNImageRequestHandler`);
  `invertImage` not planned (Android-only, as in mobile_scanner).
- Park: likely `supportsPark == false`; see `04-ios-constraints.md`.

## Tranche plan and acceptance

### Tranche A — core controls (implemented 2026-10-22)

Scope: `ScannerConfig` (facing, lensType, formats, torchEnabled, initialZoom,
cameraResolution), permission path, camera enumeration/selection
(`switchCamera`), torch, zoom, standardized error codes, capability extension,
camera-scoped pipeline (K3), example controls, README section, tests.

Acceptance:
- `flutter analyze` clean; all Dart tests green; new tests cover config
  plumbing, permission denial mapping, torch/zoom state, selection heuristic
  (fake/platform mapping) and capability truthfulness.
- Instrumented run on `pixel_bench`: open/facing switch/lens switch/torch/zoom
  twice each; close latency unchanged; no `ImageReader` leaks (log/strict mode).
- Cold-scan and warm-scan latency measured before/after (must not regress
  warm path; `scan()` cold unchanged).
- README documents Android-only knobs and migration mapping.

### Tranche B — decoding behavior

Scope: detection speed/timeout/dedupe, `scanEvents` batches + corners/size/
displayValue/type, scan window, returnImage, invertImage, analyzeImage.

**Implemented 2026-10-23** except `returnImage` (deferred, see decisions).
Deliberate deviations from the proposal, recorded for review:

- `ScanResult` carries `boundingBox: Rect?` and `corners: List<Offset>?`; a
  separate `Size` would duplicate the bounding box. `displayValue` and
  `BarcodeType` are always populated on Android (ML Kit).
- `scanEvents` has no image field; when `returnImage` lands, the image can be
  added to `ScanEvent` without breaking the batch shape.
- `analyzeImage(path)` returns `List<ScanResult>` rather than a
  `BarcodeCapture?` (no image), uses the controller's configured formats
  (no per-call override), and ignores the scan window. No
  `supportsAnalyzeImage` capability: the method is present on Android and
  will be added to iOS with the platform.
- `invertImage` inverts Y/U/V in an NV21 copy rather than round-tripping
  through a Bitmap; this is equivalent to RGB inversion (luma flips, chroma
  mirrors around 128) and avoids a second bitmap allocation per frame.
- Detection policy: `normal` gates frame submission with
  `SystemClock.elapsedRealtime()`; `noDuplicates` compares the sorted raw
  values of the whole decoded batch and resets on every `newGeneration()`
  (streaming start, including after park/close and camera switches) — the
  reference resets on stop/pause; ours also resets when a new camera starts.
- Scan window requires all detected corners inside, matching the reference;
  it is applied after duplicate suppression (reference order) and uses the
  upright frame dimensions (swapped when sensor rotation is 90/270).

Acceptance: same test gates (analyze/test/APK green); geometry validated on at
least two orientations and both facings; battery spot-check (parked/live
drain unchanged within noise); docs updated. **Outstanding:** device geometry
validation, battery spot-check, integration exercise of the new surfaces.

### Tranche C — view parity

Scope: aspect/fit preview, overlay/placeholder builders, orientation
correction, optional tap-to-focus.

Acceptance: visual check in `example/` on device; widget tests for builder
wiring; docs.

## Deliberate non-goals

- Web, macOS, Windows, Linux.
- `autoStart`, controller `start/stop/pause` duplicates, and the
  `controllerAlreadyInitialized` / `controllerInitializing` /
  `controllerUninitialized` error family (state model prevents them).
- Their `MobileScannerState` shape and widget-owned controller lifecycle.
- Copying mobile_scanner's default resolution (640x480); we keep the
  1280x720 analysis budget unless `cameraResolution` overrides it.
- `errorBuilder`-driven widget errors; our errors stay on the controller.

## Decisions (autonomous, 2026-10-22)

The human is unavailable; these were decided to keep the program moving and
are recorded here for review.

1. **`analyzeImage` is in tranche B.** It is a documented mobile_scanner
   capability and ML Kit makes it cheap (`InputImage.fromFilePath`); it does
   not disturb the warm-session story because it never opens the camera.
2. **`returnImage` is deferred** (not in A–C). It is the most expensive parity
   item (YUV→JPEG per detection) and no target-app need is confirmed. Revisit
   when a consumer asks for it.
3. **`BarcodeType` is in tranche B.** URL/WiFi/contact parsing is inexpensive
   compared with the decoding changes already in B; keep it behind the same
   `ScanResult` shape. `displayValue`/corners land with it.
4. **`ScannerConfig` is constructor-only.** Recreate the controller to change
   formats, initial torch/zoom, or resolution; `switchCamera()` is the only
   live mutation (facing/lens) and it preserves the confirmed state. This
   avoids a live reconfiguration state machine in v0.2.
5. **Tap-to-focus moves to the beyond-parity backlog** (tranche C is already
   view/orientation work; focus-point control adds platform surface without a
   confirmed need). `autoZoom` stays a B candidate.
6. **Torch is live-only.** Enabling requires `live`; leaving live turns it
   off. Config `torchEnabled` applies when streaming first starts.
7. **Zoom is normalized 0..1** across the selected camera's reported range;
   `switchCamera` resets it to 0 (widest). The platform clamps to the new
   camera's range.
8. **Error codes are preserved** from the platform (`permission_denied`,
   `unsupported`, `not_running`, `configure_failed`, …) instead of
   re-numbering; Dart exposes them verbatim in `ScannerStatus.errorCode`.
9. **Permission handling lives in the plugin** for Android: it requests
   `CAMERA` on the first drive that needs hardware and returns
   `failed/permission_denied` when denied. Host apps still declare the
   permission; the example keeps `permission_handler` for an explicit prompt.
