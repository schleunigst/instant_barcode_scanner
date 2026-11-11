# Changelog

## Unreleased

### Changed

- `dispose()` now disposes the controller's value notifiers. Remove listeners
  before calling dispose; adding one afterwards throws, as with any disposed
  `ChangeNotifier`. Reading `status`, `state` and the other values remains
  safe. This is a post-dispose observable-behaviour change.

### Fixed

- Late async completions after `dispose()` (zoom, torch, camera switch,
  capabilities) no longer mutate notifiers or fire listeners, and platform
  events delivered after teardown are dropped.
- The example no longer requests the camera permission itself; the plugin is
  the single owner of the prompt.

## 0.3.0 — 2026-11-10

A lifecycle fix, a memory fix, and corrected install/platform declarations.

### Changed

- The declared environment is now coherent and wider: Dart 3.8 and Flutter
  3.32 (previously Dart 3.13.5 together with Flutter 3.3, a combination no
  Flutter release satisfies). Consumers on Flutter 3.32–3.46 are no longer
  excluded for no reason.

### Fixed

- `dispose()` no longer hangs behind a drive that is waiting on an unanswered
  camera-permission prompt. Teardown cancels the prompt and completes instead
  of queueing behind it.
- `analyzeImage()` with `invertImage` no longer allocates a second
  full-resolution bitmap: large photos are downsampled to a 2048 px long edge
  before the inverted copy is made.
- Preview rotation now follows the activity's current display on Android 11+
  instead of the deprecated default display, and preview metrics are published
  on the main thread.
- On platforms without an implementation the first call reports
  `unsupported_platform` instead of a transport-level `channel-error`.
- README: the Android manifest snippet includes the camera `uses-feature`
  opt-out, and permission denial plus platform support are documented.

## 0.2.0

Camera controls, detection policies, still-image decoding, the session facade,
metrics, and corrected preview geometry.

### Added

- Camera configuration: facing, lens preference, barcode formats, initial
  torch, initial zoom, and analysis/preview resolution.
- Live camera controls: `switchCamera`, `setTorch`/`toggleTorch`, and
  normalized `setZoom`/`resetZoom`, with `torchState` and `zoomScale`
  listenables and capability reporting.
- Detection policies (`noDuplicates`, `normal`, `unrestricted`) with a
  configurable timeout.
- Per-frame barcode batches through `scanEvents`, plus `displayValue`,
  `BarcodeType`, `boundingBox`, and `corners` on results.
- Normalized, rotation-aware scan windows via `updateScanWindow`.
- Still-image decoding through `analyzeImage` without opening the camera.
- `invertImage` support for white-on-black symbols, including still images.
- `ScanSession` lifecycle facade with idempotent `start`, `pause`, `resume`,
  and `dispose`.
- `ScannerMetrics` and `readMetrics()` expose scan/decode/camera counters and
  the last scan, open, and resume timings.
- `analysisMetrics` and per-event `ScanEvent.analysisFrame` expose upright
  analysis-frame size/rotation for barcode coordinate mapping.
- `ScannerCapabilities` reports the resolved `cameraFacing`,
  `cameraLensType`, and `cameraId` after fallback.
- Preview fit, overlay and placeholder builders, upright rotation, and
  front-camera mirroring in `InstantBarcodeScannerView`.

### Fixed

- Preview rotation now compensates only for the display rotation, and preview
  size is reported upright. Flutter's texture already applies the camera
  sensor transform, so the previous sensor-based rotation over-rotated
  portrait previews, broke landscape orientation, and stretched the aspect
  ratio.
- Camera permission is requested at runtime and denial reports
  `permission_denied`.
- Lifecycle and concurrency hardening around dispose, scan cancellation, NFC
  handoffs, camera switches, and queued torch/zoom commands.
- Truthful-close availability watch ordering, camera-scoped analysis targets,
  ML Kit client initialization races, and image-reader teardown.
- Emit the transient `opening`/`closing` states instead of leaving them
  documented but unreachable.
- Bound camera open/session configuration with timeouts, release superseded
  opens, and cancel pending permission prompts when the host goes away.
- Accept zoom before the first drive and apply it when the device opens.
- Refuse NFC handoff when the platform cannot guarantee a true camera close.
- Drop decoded batches delivered after the scanner leaves `live`.
- Fall back to a barcode's bounding box for scan-window filtering when the
  decoder does not report corners.
- Snapshot `ScannerConfig.formats` so later caller mutation cannot alter a
  running controller.

## 0.1.0

Initial development version.

- Session-scoped scanner states: `closed`, `open`, `parked`, `live`, plus
  `failed` with `errorCode`/`errorMessage`. `opening`/`closing` exist in the
  contract but are not emitted; commands resolve to stable states.
- Single-flight native convergence: overlapping commands retarget instead of
  racing; a `close` issued during an open still ends closed; failures close
  the device before reporting.
- Truthful release: `driveTo(closed)` completes only after `CameraManager`
  reports the camera available again, so `beginNfcHandoff()` is safe to chain
  directly into NFC reader mode.
- Dart-side idle policy (`ScannerPolicy`): park 5 s after the last delivered
  read, close after 5 minutes; no auto-park.
- `scans` stream: every decoded barcode is delivered, including after a
  `scan()` timeout; the idle timer is re-armed only by delivered reads.
- NFC handoff: `beginNfcHandoff()` fails a pending scan and releases the
  camera; `endNfcHandoff()` returns to the captured pre-handoff target. A
  `scan()` requested while the handoff is active waits for it to end instead
  of failing, so host screens can switch tabs and scan immediately.
- `dispose()` is a reset, not a terminal teardown: controllers created after
  it work, and it completes only after the native side has released the
  device.
- App backgrounding closes the camera (ActivityAware); the scanner does not
  reopen automatically when the app returns.
- Pigeon-based platform contract (`ScannerHostApi` / `ScannerFlutterApi`).
- camera2 mechanism with ML Kit barcode decoding (bundled model), YUV
  analysis on the same capture session as the preview.
- Raw-bytes-first `ScanResult` (`rawBytes` + best-effort `text`).
- `InstantBarcodeScannerView` preview widget and an example app.
