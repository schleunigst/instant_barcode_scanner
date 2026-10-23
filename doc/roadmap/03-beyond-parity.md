# Beyond parity — candidate improvements

Collected while parity is being specified; **do not start implementation**
before parity tranches A–C are complete (user's ordering). This is a parking
lot with criteria, not a commitment.

Selection criteria, in order:

1. Does it strengthen the core promise (fast repeat scans, truthful close,
   battery honesty) rather than widen the API?
2. Is it feasible on iOS without weakening the shared API?
3. Can it be tested deterministically (fake platform / instrumented)?
4. Maintenance cost — no new native dependency unless clearly worth it.

## Strong candidates (my ranking)

### 1. Session-level scanning API (`ScanSession`)

Repeated scanning currently means calling `scan()` in a loop. A small wrapper
that owns the warm camera for a checkout flow, dedupes repeats across calls
and exposes accepted/rejected reads would make the package's differentiator
visible in the API, not just in behavior. Pure Dart on top of the controller.

- iOS: no change. Risk: low. Value: high.
- Guardrail: do not turn it into a second lifecycle; it must be sugar over
  `warmUp`/`scan`/`park`.

### 2. Timing metrics surface (`ScannerMetrics`)

Expose the numbers we already care about: cold open → first frame, warm
resume → first frame, last detected barcode → parked/closed timestamps,
barcodes/decoded-frame. Apps can log them; we use them to defend the battery
claims in the blog and docs. Platform-neutral if measured in the mechanism.

- Risk: low (additive listenable/stream); Value: high for the story.

### 3. Low-light torch assist (Android)

Mirror the iOS `TorchState.auto` idea on Android: sample a frame's mean
luminance and enable torch above a threshold, with hysteresis, only while
live and only if flash exists. Explicit opt-in config flag; off by default.

- Risk: medium (false positives, battery); iOS: `TorchState.auto` exists but
  semantics differ — capability-gate. Value: high for warehouse/dim aisles.

### 4. Scan-window overlay presets

A `ScannerOverlay` widget: dimmed outside, corner brackets, optional animated
sweep, driven by the same `Rect` as `updateScanWindow`. Purely visual; makes
the scan window feature usable without every app rebuilding it.

- Risk: low; iOS: same widget. Value: medium-high.

### 5. Duplicate policy beyond `noDuplicates`

mobile_scanner's `noDuplicates` only suppresses until a *different* barcode
appears. Real flows want a time window ("same value within 2 s is one read")
or "ignore this value until it leaves the frame". Expose a `dedupe:` policy
on config/`ScanSession`. We already have the signature plumbing from parity.

- Risk: low; Value: medium. iOS: same Dart-side behavior if we filter in Dart
  (preferable for parity of semantics).

### 6. Screen/route lifecycle helper

A `ScannerScope` / mixin that calls `warmUp()` on foreground, `park()` on
pause and `dispose()` after the route leaves, with the idle policy intact.
Apps migrating from mobile_scanner's widget-managed lifecycle get the same
ergonomics without hiding state.

- Risk: low; Value: medium (adoption friction). Must not auto-start scanning.

### 7. Focus quality feedback

Use ML Kit's per-frame detections to report "steady vs blurry frame" hints
(or simply frame luma variance) so the app can show "hold still". No parity
equivalent. Pure analysis-side signal; optional stream. Medium value, needs
tuning.

### 8. JPEG-free preview snapshots for scan confirmation

When a read succeeds, expose the frame's barcode crop (not the full JPEG from
`returnImage`) so checkout UIs can show the scanned symbol. Cheaper than
returnImage and unique. Android: crop from ImageProxy only on detection.
iOS: pixel buffer crop. Capability-gated.

## Medium / later

- **Battery-aware policy presets** (`aggressive`, `balanced`, `saver`) on top
  of `ScannerPolicy`; also step down on screen-off via a lifecycle broadcast
  on Android and notification on iOS.
- **Auto-focus ROI on detected corners** (Android `CONTROL_AF_REGIONS`) as a
  lower-cost alternative to ML Kit autoZoom brain.
- **Per-camera latency cache** so the first `scan()` after app start picks the
  fastest lens/facing combination for close-range codes (mobile_scanner's
  `getBestCloseRangeScanningLens` is a static heuristic; we can measure).
- **Debug overlay** (dev-only) drawing corners/scan window/latency on screen.
- **Haptic/audio read feedback** helper (apps usually implement this; low
  value).

## Rejected / deliberately not doing

- OCR, document scanning, face detection — different product.
- A general crop/rotate/upload pipeline; `analyzeImage` is the boundary.
- CameraX rewrite of the Android mechanism merely to get conveniences; the
  Camera2 mechanism is what makes the close contract true and measurable.
- A second widget-managed lifecycle (`autoStart`, `MobileScanner`-style
  start/stop/pause). Adoption convenience must not reintroduce hidden state.

## Keeping the differentiators

These already exist and every parity/beyond change must preserve them:

1. `parked` state (configured session, repeating stopped) and its measured
   resume cost.
2. Truthful `closed`: device released; completion after NFC handoff also waits
   for HAL availability.
3. `rawBytes` fidelity for backend systems (ML Kit Android preserves them;
   iOS limitation documented separately).
4. Idle policy as a first-class, testable object (`ScannerPolicy`).
5. The spam suite — every new command must keep the interleaving invariant.
