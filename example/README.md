# instant_barcode_scanner example

A small Android demo of the scanner's app-session lifecycle and controls.

The screen warms the scanner when it opens, scans on demand, and shows the last
decoded barcode, the live scanner state, and the number of streamed results. It
also exercises camera switching, torch, normalized zoom, a simulated NFC
handoff, and the preview overlay/placeholder builders.

## Run

```sh
flutter pub get
flutter run
```

The demo declares the camera permission. The plugin owns the runtime prompt on
the first camera drive, so the demo does not ask separately.

## Tests

```sh
flutter analyze
flutter test
flutter test integration_test -d <device>
```

Integration tests need a camera. Grant the permission before running them on a
fresh emulator install:

```sh
adb shell pm grant dev.instantbarcode.instant_barcode_scanner_example android.permission.CAMERA
```
