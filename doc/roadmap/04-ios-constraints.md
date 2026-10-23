# iOS constraints and open experiments

Status: no iOS implementation exists. The design paper commits to **one
package** (`instant_barcode_scanner`) with a platform-neutral API and
capability negotiation, not a separate `mobile_scanner`-clone package. This
document maps the parity surface onto AVFoundation, names what cannot match
Android, and lists the experiments that must happen before the iOS API is
promised.

Nothing here is implemented; it exists so Android API decisions do not paint
iOS into a corner.

## Mapping

| Capability | iOS mechanism | Confidence | Notes |
| --- | --- | --- | --- |
| Facing / lens selection | `AVCaptureDevice.DiscoverySession`, `builtInWideAngleCamera` / `builtInUltraWideCamera` / `builtInTelephotoCamera`, `external` | high | Same heuristic as Android: rank by focal length per facing; `any` = default. Device types can be unavailable on iPads without tele |
| Torch | `device.hasTorch`, `device.torchMode` | high | Torch is tied to a running session; must be re-applied after restart; `TorchState.auto` has no direct Android equivalent (capability-gate both) |
| Zoom | `device.videoZoomFactor`, `minAvailableVideoZoomFactor`, `maxAvailableVideoZoomFactor` | high | Normalized 0..1 maps to device range; smooth ramp (`ramp(toVideoZoomFactor:withRate:)`) is nicer than Android |
| Formats | `AVCaptureMetadataOutput.metadataObjectTypes` | medium | Covers QR, EAN-8/13, UPC-E, Code39/93/128, PDF417, Aztec, DataMatrix, ITF-14, Codabar (verify Codabar + DataMatrix on target iOS). **Not** an exact ML Kit format set |
| `rawBytes` | `AVMetadataMachineReadableCodeObject` exposes `stringValue`, not raw payload bytes | **low** | Likely lossy on iOS (e.g. Aztec). Vision `VNDetectBarcodesRequest` also gives decoded strings. Decide: return UTF-8 bytes of the string, mark capability `supportsRawBytes=false`, or depend on ML Kit iOS. This must be resolved before claiming parity |
| `text` / `displayValue` | `stringValue` | high | `displayValue` is a mobile_scanner/ML Kit concept; on iOS return `stringValue` and document differences |
| Corners / size | Vision barcode observation or metadata object bounds (converted) | medium | Coordinate spaces differ from Android; scan-window math needs its own validation |
| Detection speed / dedupe | Throttle in the Swift delegate | high | Same semantics implemented natively; Dart-side dedupe is an alternative (keeps behavior identical across platforms) |
| Scan window | `metadataOutput.rectOfInterest` (normalized coords) | medium | Known orientation quirks; validate per orientation before promising. Alternative: filter by observation bounds in Swift |
| `returnImage` | `AVCapturePhotoOutput` or pixel-buffer capture on detection | medium | Adds capture-path complexity; capability-gate |
| `invertImage` | not planned | n/a | Android-only in mobile_scanner too |
| `analyzeImage` (file) | `VNImageRequestHandler` + `VNDetectBarcodesRequest` | high | Works in simulator (unlike the camera); map formats to Vision symbologies |
| Camera permission | `AVCaptureDevice.requestAccess(for: .video)` + `NSCameraUsageDescription` | high | Denial is permanent-ish per app settings; map to `permission_denied`; document Info.plist requirement |
| Preview | Flutter texture fed by `CVPixelBuffer` (FlutterTexture protocol) or platform view | medium | Big decision. Our Android preview is a shared `Texture`; on iOS the equivalent requires implementing `FlutterTexture` and copying/retaining buffers. Mobile_scanner uses a platform view. Decide before tranche C |
| Lifecycle / background | `AVCaptureSession` interruption / route-change notifications; app background → `stopRunning` | high | No auto-reopen, matching Android: app calls `warmUp()` on return |
| Close | `session.stopRunning()` on a serial queue | high | Completion can truthfully mean the camera is released. iOS has no camera2-style HAL availability callback; "ready for NFC" means stopRunning returned |

## The park question

Android `parked` = device open + session configured + repeating stopped.
iOS has no equivalent without keeping a session running (which keeps the
camera indicator lit and costs power), because `stopRunning()` is the only
way to release capture. Options:

1. **`supportsPark = false` on iOS.** `warmUp()` drives to `open`: session
   configured and running (preview visible, analysis gated by the controller
   state). `scan()` is then a state flip, not a session start. `park()` closes.
   Truthful, simple, and still much faster than configuring per read.
2. **Reuse `parked` for "configured but stopped".** Only honest if
   `stopRunning()`/`startRunning()` keeps the configuration and measures
   cheaply enough to be called "warm". Indicator behavior must be measured
   (expected: indicator off while stopped).

Decision needs the measurements below. Whichever wins, `ScannerCapabilities`
must say so and the README must not overclaim iOS battery behavior.

## Experiments to run before promising the iOS arm

Hardware needed: one iPhone with wide+ultra-wide (ideally tele), one iPad
optional. No simulator for camera timing.

1. **Session start/stop latency**: time `startRunning()` and `stopRunning()`
   on an already-configured session, cold vs after a previous run. Compare to
   Android parked→live (~0.19 s documented) and closed→live.
2. **Camera indicator**: does the green indicator go dark after
   `stopRunning()`? Immediately or with a delay? (This defines truthful
   close on iOS.)
3. **Torch with stopped session**: does torch stay on after `stopRunning()`
   (it must not); what is the restore sequence on restart?
4. **Format matrix**: which `AVMetadataObject.ObjectType` values are
   supported and which decode the test symbols (Aztec, DataMatrix, Codabar,
   ITF-14, PDF417, Code128, EAN-13, UPC-E corner cases).
5. **Raw payload fidelity**: compare `stringValue` and any Vision payload
   bytes against known binary Aztec/DataMatrix payloads. Decide
   `supportsRawBytes` truthfully.
6. **Scan window**: `rectOfInterest` behavior in portrait/landscape, front
   camera mirroring, and whether filtering by observation bounds is more
   reliable.
7. **Preview path**: `FlutterTexture` vs `UiKitView` performance (60 fps
   preview, first-frame latency, memory/retain cycles). This drives the
   shared view API.
8. **Return-image capture**: cost of one photo/pixel-buffer capture on
   detection; check for shutter sound/UX issues.
9. **Interruptions**: phone call, Control Center camera, backgrounding —
   which notifications fire and what state should the controller report.

## iOS implementation order (after experiments)

1. Swift plugin skeleton + Pigeon host API mirroring the Android one.
2. Session lifecycle, true close, capability negotiation
   (`supportsPark`/`supportsTrueClose` decided by data).
3. Metadata output + format mapping + batch/scan API + detection throttle.
4. Facing/lens/torch/zoom.
5. Preview texture + view parity.
6. `analyzeImage`, optionally `returnImage`.
7. Run the same Dart contract tests against a fake iOS platform plus
   on-device tests; extend `test/hardening_test.dart` only where the platform
   differs.

## Rules to protect the shared API

- No Dart API may assume `supportsPark == true` (already enforced by the
  controller's degraded path and tests).
- Android-only knobs (`invertImage`, `cameraResolution`, `autoZoom`) stay
  explicitly documented and capability-gated on both platforms.
- `rawBytes` must not be promised as byte-exact on iOS until experiment 5
  says otherwise; if it cannot be exact, expose it as nullable with a
  capability flag rather than pretending.
- Keep park/close semantics in the controller, not per platform: iOS reports
  capabilities, the controller adapts exactly as it already does for
  `supportsPark == false`.
