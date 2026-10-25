# instant_barcode_scanner

A session-scoped barcode scanner for Flutter. Android only for now.

Most of a cold scan's wait is the camera, not the scan: from a fully
closed state, the first preview frame takes a median of 1.33 s to appear
on the device this package was developed against (a Galaxy S24 FE), while
a barcode decode itself runs on the order of milliseconds once frames are
flowing. A parked camera — device and session held open, but streaming
nothing — cuts that same open to 0.27 s. A held camera also costs
battery, though, and its states draw very differently. Measured on that
device with the app in the foreground and everything else pinned in every
measurement (so the deltas are what the camera itself costs):

- **`closed`** — the app idles at about **3.5 %/h**. The camera contributes
  nothing; this is just the phone running your app.
- **`parked`** (session held, no frames streaming, OS camera indicator dark) —
  about **7.9 %/h**, roughly 4.4 %/h more than `closed`. This is the warm state:
  the next scan starts 0.27 s in instead of 1.33 s, and nothing about the phone
  looks or feels live.
- **`live`** (streaming and decoding) — about **12.8 %/h**: the exact same
  foreground app, streaming at full rate, costs close to four times what it
  does with the camera closed. Most scanner packages sit in this state for
  the entire time their scan screen is up, barcode already read or not, and
  pay the 1.33 s again on every re-entry.

For an app whose scan is a one-off errand — a scan button, a result, done —
[mobile_scanner](https://pub.dev/packages/mobile_scanner) is the right
shape, and its widget-scoped lifecycle fits: camera on while the scan
screen is up, off after. The problem appears where scanning spans screens
and idle stretches — checkout lanes, inventory walks, access points:
either the camera goes cold between them and every scan re-pays the
1.33 s, or it keeps streaming and every idle second pays the 12.8 %/h.

This package is for those apps. It holds the camera lifecycle at the app
session level, and the states are the API: you ask for the state you want
and the future resolves only when that state is actually true; an idle
policy steps the scanner down on its own — `live` to `parked` a few
seconds after your last read (so back-to-back scans stay hot), `parked` to
`closed` after a longer idle. `live` is spent only while a read can
actually happen; the seconds in between are parked, not live.

> Status: early development. `0.1.0` is the current source baseline; the
> controls, decoding, and preview work in this branch is unreleased. APIs may
> change between 0.x releases.

## Install

The package is not on pub.dev yet. Until the first release, depend on the
repository:

```yaml
dependencies:
  instant_barcode_scanner:
    git:
      url: https://github.com/schleunigst/instant_barcode_scanner.git
      ref: main
```

Requires Android SDK 24 or newer. Your app declares the camera permission
(see [Android setup](#android-setup)); the package does not.

## Usage

```dart
import 'dart:async';

import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

final scanner = InstantBarcodeScanner();

// When the scanning screen appears, put
// InstantBarcodeScannerView(controller: scanner) in the tree and warm up.
await scanner.warmUp();                     // parked: session ready, no frames

try {
  final result = await scanner.scan();      // live; resolves on the first read
  print('${result.format}: ${result.rawBytes?.length} bytes, "${result.text}"');
} on TimeoutException {
  // Nothing read in time. The scanner stays live for a moment
  // (ScannerPolicy.parkAfter), then parks itself.
}

// Every barcode decoded while live is also delivered here, including ones
// that arrive after a scan() timed out.
scanner.scans.listen((result) { /* ... */ });

// Frame batches (every barcode ML Kit found in one analyzed frame):
scanner.scanEvents.listen((event) {
  print('${event.barcodes.length} barcode(s) in this frame');
});

// Before an NFC handoff: this completes only once the camera HAL reports
// the device available again, so it is safe to open the reader right after.
await scanner.beginNfcHandoff();
// ... NFC flow ...
await scanner.endNfcHandoff();              // returns to the previous state

await scanner.close();                      // camera physically closed
await scanner.dispose();                    // release everything
```

The idle policy steps the scanner down on its own: `live` goes to `parked`
after 5 s without a delivered read (so back-to-back scans stay hot), and
`parked` goes to `closed` after 5 minutes. Both are configurable:

```dart
final scanner = InstantBarcodeScanner(
  policy: const ScannerPolicy(
    parkAfter: Duration(seconds: 3),
    closeAfter: Duration(minutes: 1),
  ),
);
```

### Camera configuration and controls

Camera choice, formats, and initial torch/zoom are fixed when the controller
is created; changing them means creating a new controller. `switchCamera()`
is the exception: it changes facing/lens live and preserves the confirmed
state (live stays live, parked stays parked, closed stays closed).

```dart
import 'dart:ui' show Size;

final scanner = InstantBarcodeScanner(
  config: const ScannerConfig(
    facing: CameraFacing.back,
    lensType: CameraLensType.wide,          // any | normal | wide | zoom
    formats: [BarcodeFormat.qrCode, BarcodeFormat.aztec],
    torchEnabled: false,
    initialZoom: 0.0,                       // normalized 0..1
    cameraResolution: Size(1280, 720),      // analysis/preview budget
    detectionSpeed: DetectionSpeed.normal,  // noDuplicates | normal | unrestricted
    detectionTimeout: Duration(milliseconds: 250),
    invertImage: false,                     // white-on-black symbols
  ),
);

await scanner.warmUp();

await scanner.switchCamera();               // toggle back/front
await scanner.switchCamera(facing: CameraFacing.front,
                           lensType: CameraLensType.normal);

await scanner.setTorch(true);               // live only
await scanner.toggleTorch();
await scanner.setZoom(0.5);                 // normalized 0..1
await scanner.resetZoom();                  // widest

scanner.torchState.addListener(() {
  print(scanner.torchState.value);          // off | on | unavailable
});
scanner.zoomScale.addListener(() {
  print(scanner.zoomScale.value);           // 0..1
});
```

The torch is a live-only control and goes off whenever streaming stops
(park, close, background). If the selected camera has no flash,
`torchState` is `unavailable`. Symbology filters are applied by the decoder;
an empty `formats` list means every format ML Kit supports. Changing
formats is a reconfiguration: dispose the controller and create a new one.

### Decoding behavior

`detectionSpeed` trades CPU for latency:

- `normal` (default) analyzes at most one frame per `detectionTimeout`;
- `noDuplicates` analyzes every frame but reports a batch only when its set
  of raw values differs from the previous reported batch;
- `unrestricted` analyzes and reports every frame.

`updateScanWindow(Rect)` restricts decoding to a normalized rectangle in the
upright analysis frame (`Rect.fromLTRB(0.1, 0.1, 0.9, 0.9)`); a barcode is
reported only when all of its detected corners fall inside. Pass `null` to
clear it. `scanner.scanEvents` exposes the raw per-frame batches (with
`corners`/`boundingBox` geometry); `scans` and `scan()` remain the flattened
convenience views.

`analyzeImage(path)` decodes a still file through ML Kit without opening the
camera or asking for permission, using the configured formats:

```dart
final results = await scanner.analyzeImage('/path/to/photo.jpg');
```

`invertImage: true` inverts frame colors before decoding, for
white-on-black symbols. It is Android-only and ignored elsewhere. The scan
window does not apply to still images.

### States

| State    | Camera device | Session | Frames | Notes                                    |
| -------- | ------------- | ------- | ------ | ---------------------------------------- |
| `closed` | closed        | —       | —      | OS camera indicator off                  |
| `open`   | open          | no      | —      | device held, no session                  |
| `parked` | open          | yes     | no     | preview holds its last frame             |
| `live`   | open          | yes     | yes    | decoding; OS camera indicator on         |
| `failed` | closed        | —       | —      | carries `errorCode`; camera already released |

`opening` and `closing` exist in the enum as part of the platform contract
but are not emitted in 0.1; commands resolve to stable states. When the
mechanism fails mid-session (a disconnect, a configure failure), the state
becomes `failed`, the camera is released first, and `errorCode` /
`errorMessage` say what happened. `warmUp()` or `scan()` retries from there.

Steady draws for these states on the same reference device (phone total,
app foreground): `live` ~12.8 %/h, `parked` ~7.9 %/h, `closed` ~3.5 %/h.
That ordering is the whole trade: a re-entry from `parked` costs 0.27 s
instead of 1.33 s, at a draw about a third below `live` and with the OS
camera indicator dark.

A `closed` status is a promise, not a hint: the camera device is closed and,
for `beginNfcHandoff()`, the camera HAL has reported the device available
again before the future completes. That is the whole point of owning camera2
directly instead of wrapping CameraX.

When the host activity goes to the background, the plugin closes the camera
itself — Android revokes camera access for background apps anyway, and it is
better to close deliberately than to be disconnected. The scanner does not
reopen on its own when the app returns; call `warmUp()` again.

### Raw bytes

`ScanResult.rawBytes` is the payload exactly as encoded in the symbol,
passed through untouched. `text` is a best-effort, lossy interpretation and
may be null. If your backend must see the original bytes — Aztec payloads
are the usual example — read `rawBytes`.

## Android setup

Declare the camera permission in your app's manifest:

```xml
<uses-permission android:name="android.permission.CAMERA" />
```

Runtime permission handling is handled by the plugin on Android: it requests
`CAMERA` on the first drive that needs the camera and reports
`failed/permission_denied` when denied. The example app also asks up front
with `permission_handler` so the prompt appears at a friendlier moment.

Decoding uses ML Kit. The default is the bundled model
(`com.google.mlkit:barcode-scanning`): hermetic, no Play Services dependency,
no first-use model download, roughly 2–3 MB per ABI. To use the unbundled
thin client instead, add this to your app's `android/app/build.gradle.kts`:

```kotlin
configurations.configureEach {
    exclude(group = "com.google.mlkit", module = "barcode-scanning")
}
dependencies {
    implementation("com.google.android.gms:play-services-mlkit-barcode-scanning:18.3.1")
}
```

The unbundled client downloads its model through Play Services on first use
and requires Play Services on the device.

## Limitations

- Android only for now, exactly as the design paper says below. iOS is
  planned for this same package, not a sibling: the API, events, and
  `Capabilities` (`supportsPark`, `supportsTrueClose`, …) are
  platform-neutral from day one, so iOS code slots in behind the same Dart
  policy — whether AVFoundation can hold a parked state (rather than
  close/reopen) is the open question it waits on.
- The preview has no rotation or aspect-ratio correction yet; it fills the
  widget as-is.
- No analyzer SPI yet (a custom decoder cannot be plugged in before the
  `setAnalyzer` API lands), no tap-to-focus, and no per-detection frame
  image (`returnImage`).
- One scanner instance per app is the supported shape today.

## Testing

The package is verified on three levels, and all of it is in this repository:

- `flutter test` runs the Dart suite (77 tests): the state machine, idle
  policy, handoff and failure paths against a fake with real async semantics,
  command serialization/races, config plumbing, torch/zoom/switch controls,
  detection policy/window/still-image behavior,
  and the pigeon mapping including the raw-bytes pass-through.
- `./gradlew :instant_barcode_scanner:connectedDebugAndroidTest` (from
  `example/android`) runs 4 device tests against the real camera: convergence
  to `parked`, retargeting a `close` through an in-flight open, truthful
  release confirmed through `CameraManager` availability, and dispose during
  an open.
- `flutter test integration_test` (from `example/`) runs the end-to-end
  flows, including a fresh session after `dispose()`, the NFC handoff, the
  scan-window commands, and the still-image error path.

## Contributing

See `CONTRIBUTING.md`. Issues and pull requests are welcome; for timing
claims, come with numbers.

## License

BSD-3-Clause. See `LICENSE`.
