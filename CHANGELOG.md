# Changelog

## Unreleased

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
- `analysisMetrics` and per-event `ScanEvent.analysisFrame` expose upright
  analysis-frame size/rotation for barcode coordinate mapping.
- `ScannerCapabilities` reports the resolved `cameraFacing`,
  `cameraLensType`, and `cameraId` after fallback.
- Preview fit, overlay and placeholder builders, upright rotation, and
  front-camera mirroring in `InstantBarcodeScannerView`.

### Fixed

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
