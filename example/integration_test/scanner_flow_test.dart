import 'dart:async';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';
import 'package:integration_test/integration_test.dart';

/// End-to-end flows against the real plugin. Run on a device or emulator
/// with a working camera and the CAMERA permission granted:
///
/// ```
/// coordinator$ adb shell pm grant \
///   dev.instantbarcode.instant_barcode_scanner.example android.permission.CAMERA
/// coordinator$ flutter test integration_test
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('warm, scan, park, close, dispose, then a fresh session', (
    tester,
  ) async {
    final scanner = InstantBarcodeScanner();
    await scanner.warmUp();
    expect(scanner.state, ScannerState.parked);

    // The preview transform arrives from the platform with the first
    // configured session; the view uses it for rotation and fit.
    final metricsDeadline = DateTime.now().add(const Duration(seconds: 2));
    while (scanner.previewMetrics.value == null &&
        DateTime.now().isBefore(metricsDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final preview = scanner.previewMetrics.value;
    expect(preview, isNotNull);
    expect(preview!.size.isEmpty, isFalse);
    expect(preview.rotationDegrees % 90, 0);

    // Decoding controls are live on the platform channel; the camera is
    // parked here, so this exercises the stored-window path.
    await scanner.updateScanWindow(const Rect.fromLTRB(0.1, 0.1, 0.9, 0.9));
    await scanner.updateScanWindow(null);

    await expectLater(
      scanner.analyzeImage('/nonexistent/missing.png'),
      throwsA(
        isA<ScannerException>().having(
          (error) => error.status.errorCode,
          'errorCode',
          'invalid_image',
        ),
      ),
    );
    expect(scanner.state, ScannerState.parked);

    // Nothing decodable in front of the camera: the scan times out, and the
    // scanner stays live (the burst window) rather than falling apart.
    await expectLater(
      scanner.scan(timeout: const Duration(milliseconds: 600)),
      throwsA(isA<TimeoutException>()),
    );
    expect(scanner.state, ScannerState.live);

    await scanner.park();
    expect(scanner.state, ScannerState.parked);

    await scanner.close();
    expect(scanner.state, ScannerState.closed);

    await scanner.dispose();

    // The plugin resets, it does not die: a controller created after a
    // dispose must be able to warm up and close again (R3).
    final again = InstantBarcodeScanner();
    await again.warmUp();
    expect(again.state, ScannerState.parked);
    await again.close();
    expect(again.state, ScannerState.closed);
    await again.dispose();
  });

  testWidgets('a scan in flight is interrupted by an NFC handoff', (
    tester,
  ) async {
    final scanner = InstantBarcodeScanner();
    await scanner.warmUp();

    final pending = scanner.scan(timeout: const Duration(seconds: 10));
    final pendingFailure = expectLater(pending, throwsA(isA<StateError>()));

    // Wait for the scan to actually reach `live` so the handoff interrupts a
    // scan that is waiting for a barcode, not one still driving.
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (scanner.state != ScannerState.live &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(scanner.state, ScannerState.live);

    await scanner.beginNfcHandoff();
    await pendingFailure;
    expect(scanner.state, ScannerState.closed);

    // The handoff restores the pre-handoff target.
    await scanner.endNfcHandoff();
    expect(scanner.state, ScannerState.live);

    await scanner.close();
    await scanner.dispose();
  });
}
