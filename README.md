# instant_barcode_scanner

A session-scoped barcode scanner for Flutter. Android only for now.

The camera is the slow part. On the device this package was developed against
(a Galaxy S24 FE), the first preview frame arrives a median of 1.33 s after a
camera that was fully closed, but 0.27 s after one that was parked. Warm is
worth it — and warm is not one thing: each camera state steadies out at its
own battery draw. Measured on that device with the app in the foreground and
everything else pinned in every measurement (so the deltas are what the
camera itself costs):

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

This package works the ladder instead. You ask for a state and it resolves
only when that state is actually true; the idle policy steps it back down on
its own — `live` to `parked` a few seconds after your last read, `parked` to
`closed` after a longer idle — so the expensive states are spent only while
a scan can actually happen.

> Status: `0.1.0`, early development. APIs may change between 0.x releases.

## Install

```yaml
dependencies:
  instant_barcode_scanner: ^0.1.0
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

Runtime permission handling is the host app's job; the example app uses
`permission_handler`.

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

- Android only. iOS is planned as a separate `instant_barcode_scanner_ios`.
- The preview has no rotation or aspect-ratio correction yet; it fills the
  widget as-is.
- No torch control, no analyzer SPI yet (a custom decoder cannot be plugged
  in before the `setAnalyzer` API lands), no scan-region hints.
- One scanner instance per app is the supported shape today.

## Testing

The package is verified on three levels, and all of it is in this repository:

- `flutter test` runs the Dart suite (26 tests): the state machine, idle
  policy, handoff and failure paths against a fake with real async semantics,
  plus the pigeon mapping including the raw-bytes pass-through.
- `./gradlew :instant_barcode_scanner:connectedDebugAndroidTest` (from
  `example/android`) runs 4 device tests against the real camera: convergence
  to `parked`, retargeting a `close` through an in-flight open, truthful
  release confirmed through `CameraManager` availability, and dispose during
  an open.
- `flutter test integration_test` (from `example/`) runs the end-to-end
  flows, including a fresh session after `dispose()`.

## Contributing

See `CONTRIBUTING.md`. Issues and pull requests are welcome; for timing
claims, come with numbers.

## License

BSD-3-Clause. See `LICENSE`.
