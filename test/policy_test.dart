import 'package:flutter_test/flutter_test.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

void main() {
  group('ScannerPolicy', () {
    const policy = ScannerPolicy(
      parkAfter: Duration(seconds: 5),
      closeAfter: Duration(seconds: 30),
    );

    test('live has an idle delay and steps down to parked', () {
      expect(policy.idleDelay(ScannerState.live), const Duration(seconds: 5));
      expect(policy.idleTarget(ScannerState.live), ScannerState.parked);
    });

    test('parked has an idle delay and steps down to closed', () {
      expect(
        policy.idleDelay(ScannerState.parked),
        const Duration(seconds: 30),
      );
      expect(policy.idleTarget(ScannerState.parked), ScannerState.closed);
    });

    test('stable non-streaming states have no idle step', () {
      for (final state in [
        ScannerState.closed,
        ScannerState.open,
        ScannerState.failed,
      ]) {
        expect(policy.idleDelay(state), isNull, reason: '$state delay');
        expect(policy.idleTarget(state), isNull, reason: '$state target');
      }
    });

    test('defaults: 5s to park, 5min to close', () {
      const defaults = ScannerPolicy();
      expect(defaults.parkAfter, const Duration(seconds: 5));
      expect(defaults.closeAfter, const Duration(minutes: 5));
    });
  });
}
