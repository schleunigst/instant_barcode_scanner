import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

import 'fake_platform.dart';

/// Post-dispose contracts: late async completions and platform events must not
/// reach a disposed controller, its notifiers are disposed, and a second
/// dispose is safe.
void main() {
  test('a late zoom completion after dispose does not notify', () {
    fakeAsync((async) {
      final platform = FakePlatform()
        ..capabilitiesResult = const ScannerCapabilities(
          supportsPark: true,
          supportsTrueClose: true,
          supportsZoom: true,
          minZoom: 1,
          maxZoom: 4,
        );
      final zoom = Completer<void>();
      platform.zoomHandler = (_) => zoom.future;
      final scanner = InstantBarcodeScanner(platform: platform);

      var notifications = 0;
      scanner.zoomScale.addListener(() => notifications++);

      unawaited(scanner.setZoom(0.5));
      async.flushMicrotasks();
      expect(platform.zoomRatio, closeTo(2.5, 0.001));

      unawaited(scanner.dispose());
      async.flushMicrotasks();
      zoom.complete();
      async.flushMicrotasks();

      expect(notifications, 0);
      expect(() => scanner.zoomScale.addListener(() {}), throwsFlutterError);
    });
  });

  test('a late capabilities completion after dispose does not notify', () {
    fakeAsync((async) {
      final capabilities = Completer<ScannerCapabilities>();
      final platform = FakePlatform()
        ..capabilitiesHandler = () => capabilities.future;
      final scanner = InstantBarcodeScanner(platform: platform);

      var notifications = 0;
      scanner.torchState.addListener(() => notifications++);

      unawaited(scanner.capabilities);
      async.flushMicrotasks();

      unawaited(scanner.dispose());
      async.flushMicrotasks();
      capabilities.complete(
        const ScannerCapabilities(
          supportsPark: true,
          supportsTrueClose: true,
          supportsTorch: false,
        ),
      );
      async.flushMicrotasks();

      expect(notifications, 0);
      expect(() => scanner.torchState.addListener(() {}), throwsFlutterError);
    });
  });

  test(
    'platform events after dispose are dropped and dispose is idempotent',
    () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);
        var statuses = 0;
        var barcodes = 0;
        scanner.status.addListener(() => statuses++);
        scanner.scans.listen((_) => barcodes++);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
        final afterDispose = statuses;

        platform.emitStatus(const ScannerStatus(state: ScannerState.live));
        platform.emit(const [
          ScanResult(format: BarcodeFormat.qrCode, text: 'x'),
        ]);
        async.flushMicrotasks();

        expect(statuses, afterDispose);
        expect(barcodes, 0);
        expect(scanner.dispose(), isA<Future<void>>());
      });
    },
  );
}
