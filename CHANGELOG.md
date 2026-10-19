# Changelog

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
