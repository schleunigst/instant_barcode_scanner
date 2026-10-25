import 'package:flutter_test/flutter_test.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

void main() {
  test('the example sits on the public API', () {
    const result = ScanResult(format: BarcodeFormat.qrCode, text: 'hello');
    expect(result.rawBytes, isNull);
    expect(result.text, 'hello');

    const metrics = ScannerMetrics();
    expect(metrics.scanRequests, 0);
    expect(metrics.analyzedFrames, 0);

    const policy = ScannerPolicy();
    expect(policy.idleTarget(ScannerState.live), ScannerState.parked);
    expect(policy.idleTarget(ScannerState.parked), ScannerState.closed);
  });
}
