# Android audit, 2026-10-22

Scope: the shipped v0.1 Android path — Dart controller, fake platform tests,
Kotlin plugin/mechanism/selection/pipeline. Goal: find lifecycle, concurrency
and transport bugs before parity work builds on top of them.

Method: a Dart audit subagent produced the A-series with file/line evidence;
every finding was re-checked against the source before fixing. The Kotlin
audit subagent returned an empty report twice, so the Kotlin mechanism was
audited directly (files below) rather than retried again.

Files read in full:

- `lib/src/controller.dart`
- `lib/src/view.dart`
- `lib/src/platform/{platform,policy,types}.dart`
- `android/src/main/kotlin/dev/instantbarcode/instant_barcode_scanner/`
  `{InstantBarcodeScannerPlugin,CameraMechanism,CameraSelection,BarcodeAnalysisPipeline}.kt`
- `test/{controller,fake_platform,platform,policy,spam}_test.dart`

## Dart findings (A-series)

Status: **fixed** in `lib/src/controller.dart` unless noted. Each fixed item
has a regression test in `test/hardening_test.dart` (H) or an extended
`test/spam_test.dart` (S).

| ID | Severity | Finding | Status / evidence |
| --- | --- | --- | --- |
| A1 | critical | `endNfcHandoff()` after `dispose()` re-opened the camera (no disposed guard) | fixed; H “endNfcHandoff after dispose never reopens” |
| A2 | critical | In-flight `warmUp()`/`park()` continued after `dispose()` (post-await writes, drives) | fixed via post-await `_ensureUsable()` inside serialized actions; H “warmUp suspended on the texture does not drive after dispose” |
| A3 | high | A second `beginNfcHandoff()` replaced the waiter/handoff state, orphaning a queued scan | fixed: reentrant begin joins the active handoff; H “a second beginNfcHandoff does not drop the resume target” |
| A4 | high | `warmUp()`/`park()` reopened the camera during an active NFC handoff | fixed: both no-op while `_handoff`; H “warmUp during a handoff does not reopen” |
| A5 | high | `close()`/`park()` during a scan left the scan pending; next `scan()` deduped onto the stale future; late barcodes could complete a non-live scan | fixed: close/park fail the pending scan with `StateError`, clear the scan slot, identity-guarded completion, barcode delivery gated on `live`/no handoff; H “close cancels…next scan is fresh”, H “park cancels…” |
| A6 | high | Concurrent `warmUp()` + `scan()` parked the camera underneath the scan | fixed: drives are serialized; a warmUp whose scan was already active at call time never parks; H “a late warmUp does not park under an active scan” |
| A7 | high | Platform failure/closed events never settled a pending scan (caller waited out the timeout) | fixed: status events fail the pending scan (`ScannerException` with the platform code, or `StateError` on background close); H “background close…”, H “failure event…” |
| A8 | medium | Failed `beginNfcHandoff()` cleared the handoff but never re-armed the idle timer | fixed: failure path clears handoff and calls `_touchIdle` |
| A9 | medium | `beginNfcHandoff()` left `_activeScan` pointing at the interrupted scan; a scan requested during the handoff inherited its `StateError` | fixed: interrupted scan slot cleared; scans requested during a handoff wait for it; H “a scan requested during a handoff waits and then reads” |
| A10 | medium | `dispose()` was not idempotent/shared; it awaited `_scanController.close()` while listeners paused | fixed: shared `_disposeFuture`, stream close is fire-and-forget, all late callbacks gated by `_disposed`; H “dispose is idempotent…” |
| A11 | medium | `PlatformException` from a command escaped untyped | fixed: drives map to `ScannerStatus(failed, 'platform_error')` → `ScannerException`; capabilities/texture wrap too; H “a throwing drive surfaces as ScannerException(failed)” |
| A12 | medium | Capabilities were cached even when the lookup failed | fixed: failed lookups clear the cache; H “a failed capabilities lookup is not cached” |
| A13 | medium | `supportsPark == false` path was incomplete (warmUp/open, step-down, handoff resume) | fixed: warmUp opens, park closes, idle step-down degrades live→closed, handoff resume maps parked→open; H two degraded-capabilities tests |
| A14–A17 | low | Reported as documentation-level gaps (single-instance constraint, README/test-count drift, stream replay semantics) | addressed as doc comments in `controller.dart` (single instance, broadcast no-replay) and roadmap notes; no behavior change |

## Kotlin findings (K-series)

Audited directly. Status as of this pass:

| ID | Severity | Finding | Status / evidence |
| --- | --- | --- | --- |
| K1 | high | `awaitCameraAvailable` registered the `AvailabilityCallback` *after* the close drive. Availability callbacks report transitions only, so the close→available transition could be missed and every truthful close could stall the full 1 s timeout. Also hardcoded the back camera. | fixed: `CameraAvailabilityWatch` is started before the drive and awaited after; skipped when the last confirmed state is already `closed`/`failed`; watch is parameterized by camera id. `InstantBarcodeScannerPlugin.driveTo`, `CameraSelection.kt`. |
| K2 | high | No CAMERA runtime-permission check; a missing grant surfaces as a generic `open_failed` (`SecurityException`) instead of a permission error | fixed in parity tranche A: `InstantBarcodeScannerPlugin.ensureCameraPermission()` requests `CAMERA` through the activity binding; denial returns `failed/permission_denied` from `driveTo`/`switchCamera`. Device verification pending. |
| K3 | medium | `BarcodeAnalysisPipeline.target()` caches the `ImageReader` and sensor rotation for the first camera; lens/camera switching later would keep feeding frames from the old configuration | fixed in parity tranche A: `target(sensorRotation, cameraId, maxWidth, maxHeight)` is camera-scoped and recreates the reader when the camera or resolution budget changes; `CameraMechanism.switchCamera` bumps a selection generation so a stale open cannot claim the new selection. |
| K4 | low | ML Kit client creation raced between the camera thread (`target`) and analysis thread (`onImageAvailable`); `@Volatile` check-then-set could create two clients and leak one | fixed: `scannerInstance()` and `target()` are `@Synchronized`; `shutdown()` clears/close under the same lock |
| K5 | medium | `img.close()` in `addOnCompleteListener` could throw when the reader was closed mid-decode; the exception escaped the ML Kit callback | fixed: guarded close in both completion and catch paths |
| K6 | note | `getCapabilities()` hardcodes `supportsPark = true` / `supportsTrueClose = true`; multi-engine use and several lifecycle callbacks are outside the v0.1 contract | capabilities stay truthful for the current mechanism; multi-engine remains unsupported and documented (single live instance per app) |

Reviewed and left unchanged (no defect found in the v0.1 contract): the
mechanism's mutex/serialization of drives, generation tagging of analysis
results, activity-stop close, texture lifetime (engine-scoped), and the
dispose-reset semantics.

## Behavioral changes that are intentional (not regressions)

- An in-flight scan is now **cancelled** by `close()`, `park()` and
  `beginNfcHandoff()` with a `StateError`. Previously some of these left the
  scan pending until timeout, and a scan could slip underneath a handoff.
- `warmUp()` called while a scan is already running no longer parks the
  camera (it only ensures the texture). Previously it could park out from
  under the scan.
- Commands are executed in call order. A call that is queued behind a
  long-running platform call completes later than before, but the final
  confirmed state matches the last command.
- `warmUp()` on a platform without park support drives to `open`; `park()`
  closes. `supportsPark` is now consulted for idle step-down and handoff
  resume too.
- A command that is still queued when `dispose()` wins completes with a
  `StateError` instead of running against a torn-down platform. Fire-and-forget
  callers must observe the future (the example's spam harness does).

## Verification

- `flutter analyze`: no issues (package and example).
- `flutter test`: 73 tests green at tranche A (77 after tranche B decoding; 84 after tranche C preview geometry).
- `connectedDebugAndroidTest`: 4/4 green on `pixel_bench` after the tranche B
  constructor/config changes.
- Integration: `scanner_flow_test` 2/2 (now also exercises `updateScanWindow`
  and `analyzeImage` failure mapping) and `scanner_spam_test` 2/2 green.
- Tranche B still needs a physical device for geometry on both facings/
  orientations, a successful still-image decode, and the battery spot-check.
- `flutter build apk --debug` (from `example/`): green after the tranche A
  Kotlin changes.
- Instrumented `CameraMechanismDeviceTest`: 4/4 green on the `pixel_bench`
  AVD (API 35, emulated back camera): convergence to parked/closed, truthful
  close confirmed through `CameraManager`, close during open, dispose during
  open.
- Flutter integration suites on the same AVD: `scanner_flow_test` (2 tests)
  and `scanner_spam_test` (2 models) pass. CAMERA must be pre-granted
  (`adb shell pm grant …`); without it the first drive correctly waits on the
  system permission prompt, which is the K2 path working end to end.
- Still open on hardware: close→available latency re-measure (was ~0.19 s;
  K1 removes the 1 s worst case but the number has not been re-timed), and the
  parked/live draw spot-check.

## Next steps out of this audit

1. Re-time close→available on `pixel_bench` and the parked/live draw
   spot-check; the correctness gates (instrumented + integration) are green.
2. Device-verify lens/facing switching on a device with more than one back
   camera (the emulator exposes a single back camera, so the lens heuristic
   and front-camera fallback still need a real multi-camera device).
3. Measure cold/warm scan latency after the camera-scoped pipeline change;
   confirm no regression against the v0.1 numbers.
4. Then execute `02-parity-matrix.md` tranche B.
