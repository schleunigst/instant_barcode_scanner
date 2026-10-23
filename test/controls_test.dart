import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

import 'fake_platform.dart';

const _qr = ScanResult(format: BarcodeFormat.qrCode, text: 'hello');

ScannerCapabilities _caps({bool torch = false, bool zoom = false}) {
  return ScannerCapabilities(
    supportsPark: true,
    supportsTrueClose: true,
    supportsTorch: torch,
    supportsZoom: zoom,
    minZoom: 1,
    maxZoom: 8,
  );
}

void main() {
  test('configuration is forwarded before the first hardware call', () {
    fakeAsync((async) {
      final platform = FakePlatform();
      final scanner = InstantBarcodeScanner(
        platform: platform,
        config: const ScannerConfig(
          facing: CameraFacing.front,
          lensType: CameraLensType.wide,
          formats: [BarcodeFormat.qrCode],
          torchEnabled: true,
          initialZoom: 0.25,
          detectionSpeed: DetectionSpeed.noDuplicates,
          detectionTimeout: Duration(milliseconds: 120),
          invertImage: true,
          cameraResolution: Size(640, 480),
        ),
      );

      expect(platform.configured, isNull);

      unawaited(scanner.warmUp());
      async.flushMicrotasks();
      async.elapse(Duration.zero);

      final configured = platform.configured;
      expect(configured, isNotNull);
      expect(configured!.facing, CameraFacing.front);
      expect(configured.lensType, CameraLensType.wide);
      expect(configured.formats, [BarcodeFormat.qrCode]);
      expect(configured.torchEnabled, isTrue);
      expect(configured.initialZoom, 0.25);
      expect(configured.detectionSpeed, DetectionSpeed.noDuplicates);
      expect(configured.detectionTimeout, const Duration(milliseconds: 120));
      expect(configured.invertImage, isTrue);
      expect(configured.cameraResolution, const Size(640, 480));
      expect(platform.drives, [ScannerState.parked]);

      unawaited(scanner.dispose());
      async.flushMicrotasks();
    });
  });

  test('torchEnabled turns the torch state on when streaming starts', () {
    fakeAsync((async) {
      final platform = FakePlatform()..capabilitiesResult = _caps(torch: true);
      final scanner = InstantBarcodeScanner(
        platform: platform,
        config: const ScannerConfig(torchEnabled: true),
      );

      unawaited(scanner.scan().then((_) {}, onError: (Object _) {}));
      async.flushMicrotasks();
      expect(scanner.state, ScannerState.live);
      expect(scanner.torchState.value, TorchState.on);

      platform.emit([_qr]);
      async.flushMicrotasks();

      unawaited(scanner.dispose());
      async.flushMicrotasks();
    });
  });

  test('torch is live-only and off when streaming stops', () {
    fakeAsync((async) {
      final platform = FakePlatform()..capabilitiesResult = _caps(torch: true);
      final scanner = InstantBarcodeScanner(platform: platform);

      Object? error;
      unawaited(
        scanner.setTorch(true).then((_) {}, onError: (Object e) => error = e),
      );
      async.flushMicrotasks();
      expect(error, isA<StateError>());
      expect(platform.torch, isFalse);

      ScanResult? read;
      unawaited(scanner.scan().then((value) => read = value));
      async.flushMicrotasks();
      platform.emit([_qr]);
      async.flushMicrotasks();
      expect(read, _qr);

      unawaited(scanner.setTorch(true));
      async.flushMicrotasks();
      expect(platform.torch, isTrue);
      expect(scanner.torchState.value, TorchState.on);

      unawaited(scanner.park());
      async.flushMicrotasks();
      expect(scanner.state, ScannerState.parked);
      expect(scanner.torchState.value, TorchState.off);

      unawaited(scanner.dispose());
      async.flushMicrotasks();
    });
  });

  test('control commands refuse unsupported hardware', () {
    fakeAsync((async) {
      final platform = FakePlatform();
      final scanner = InstantBarcodeScanner(platform: platform);

      unawaited(scanner.scan().then((_) {}, onError: (Object _) {}));
      async.flushMicrotasks();
      expect(scanner.state, ScannerState.live);

      Object? torchError;
      unawaited(
        scanner
            .setTorch(true)
            .then((_) {}, onError: (Object e) => torchError = e),
      );
      async.flushMicrotasks();
      expect(torchError, isA<ScannerException>());
      expect((torchError! as ScannerException).status.errorCode, 'unsupported');
      expect(platform.torch, isFalse);

      Object? zoomError;
      unawaited(
        scanner.setZoom(0.5).then((_) {}, onError: (Object e) => zoomError = e),
      );
      async.flushMicrotasks();
      expect(zoomError, isA<ScannerException>());
      expect((zoomError! as ScannerException).status.errorCode, 'unsupported');
      expect(platform.zoomRatio, 1.0);

      unawaited(scanner.dispose());
      async.flushMicrotasks();
    });
  });

  test('zoom maps the normalized scale onto the camera ratio', () {
    fakeAsync((async) {
      final platform = FakePlatform()..capabilitiesResult = _caps(zoom: true);
      final scanner = InstantBarcodeScanner(platform: platform);

      expect(scanner.zoomScale.value, 0);

      unawaited(scanner.setZoom(0.5));
      async.flushMicrotasks();
      expect(platform.zoomRatio, closeTo(4.5, 1e-9));
      expect(scanner.zoomScale.value, 0.5);

      unawaited(scanner.resetZoom());
      async.flushMicrotasks();
      expect(platform.zoomRatio, 1.0);
      expect(scanner.zoomScale.value, 0);

      expect(scanner.setZoom(1.5), throwsRangeError);
      expect(scanner.setZoom(-0.1), throwsRangeError);

      unawaited(scanner.dispose());
      async.flushMicrotasks();
    });
  });

  test('switchCamera preserves state and resets controls and capabilities', () {
    fakeAsync((async) {
      final platform = FakePlatform()
        ..capabilitiesResult = _caps(torch: true, zoom: true);
      final scanner = InstantBarcodeScanner(platform: platform);

      ScanResult? read;
      unawaited(scanner.scan().then((value) => read = value));
      async.flushMicrotasks();
      platform.emit([_qr]);
      async.flushMicrotasks();
      expect(read, _qr);

      unawaited(scanner.setTorch(true));
      unawaited(scanner.setZoom(0.5));
      async.flushMicrotasks();
      expect(platform.torch, isTrue);
      expect(platform.zoomRatio, closeTo(4.5, 1e-9));

      platform.capabilitiesResult = _caps();
      unawaited(scanner.switchCamera());
      async.flushMicrotasks();

      expect(platform.switches, [(CameraFacing.front, CameraLensType.any)]);
      expect(scanner.config.facing, CameraFacing.front);
      expect(scanner.config.lensType, CameraLensType.any);
      expect(scanner.state, ScannerState.live);
      expect(scanner.torchState.value, TorchState.off);
      expect(scanner.zoomScale.value, 0);
      // The fixed configuration is sent once; switching is its own call.
      expect(platform.configured!.facing, CameraFacing.back);

      ScannerCapabilities? refreshed;
      unawaited(scanner.capabilities.then((value) => refreshed = value));
      async.flushMicrotasks();
      expect(refreshed!.supportsTorch, isFalse);
      expect(scanner.torchState.value, TorchState.unavailable);

      unawaited(scanner.dispose());
      async.flushMicrotasks();
    });
  });

  test('scan window is forwarded before warmUp and can be cleared', () {
    fakeAsync((async) {
      final platform = FakePlatform();
      final scanner = InstantBarcodeScanner(platform: platform);
      const window = Rect.fromLTRB(0.1, 0.2, 0.9, 0.8);

      unawaited(scanner.updateScanWindow(window));
      async.flushMicrotasks();
      expect(platform.configured, isNotNull);
      expect(platform.scanWindow, window);

      unawaited(scanner.updateScanWindow(null));
      async.flushMicrotasks();
      expect(platform.scanWindow, isNull);

      Object? outOfBounds;
      unawaited(
        scanner
            .updateScanWindow(const Rect.fromLTRB(0, 0, 1.2, 1))
            .then((_) {}, onError: (Object e) => outOfBounds = e),
      );
      async.flushMicrotasks();
      expect(outOfBounds, isA<ArgumentError>());

      Object? inverted;
      unawaited(
        scanner
            .updateScanWindow(const Rect.fromLTRB(0.6, 0, 0.4, 1))
            .then((_) {}, onError: (Object e) => inverted = e),
      );
      async.flushMicrotasks();
      expect(inverted, isA<ArgumentError>());
      expect(platform.scanWindow, isNull);

      unawaited(scanner.dispose());
      async.flushMicrotasks();
    });
  });

  test(
    'analyzeImage decodes without a camera session and does not change state',
    () {
      fakeAsync((async) {
        final platform = FakePlatform()
          ..analyzeImageResult = const [
            ScanResult(
              format: BarcodeFormat.ean13,
              text: '4006381333931',
              type: BarcodeType.product,
            ),
          ];
        final scanner = InstantBarcodeScanner(platform: platform);

        List<ScanResult>? decoded;
        Object? error;
        unawaited(
          scanner
              .analyzeImage('/tmp/label.png')
              .then(
                (value) => decoded = value,
                onError: (Object e) => error = e,
              ),
        );
        async.flushMicrotasks();

        expect(error, isNull);
        expect(platform.analyzedPaths, ['/tmp/label.png']);
        expect(platform.configured, isNotNull);
        expect(decoded, hasLength(1));
        expect(decoded!.single.text, '4006381333931');
        expect(decoded!.single.type, BarcodeType.product);
        expect(scanner.state, ScannerState.closed);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    },
  );

  test(
    'analyzeImage failures map to ScannerException with the platform code',
    () {
      fakeAsync((async) {
        final platform = FakePlatform()
          ..analyzeImageHandler = (_) => Future.error(
            PlatformException(code: 'invalid_image', message: 'no such file'),
          );
        final scanner = InstantBarcodeScanner(platform: platform);

        Object? error;
        unawaited(
          scanner
              .analyzeImage('/tmp/missing.png')
              .then((_) {}, onError: (Object e) => error = e),
        );
        async.flushMicrotasks();

        expect(error, isA<ScannerException>());
        expect((error! as ScannerException).status.errorCode, 'invalid_image');
        expect(scanner.state, ScannerState.closed);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    },
  );

  test('scanEvents carries the frame batch and scans flattens it', () {
    fakeAsync((async) {
      final platform = FakePlatform();
      final scanner = InstantBarcodeScanner(platform: platform);
      final events = <ScanEvent>[];
      final flat = <ScanResult>[];
      scanner.scanEvents.listen(events.add);
      scanner.scans.listen(flat.add);

      unawaited(scanner.scan().then((_) {}, onError: (Object _) {}));
      async.flushMicrotasks();

      const second = ScanResult(format: BarcodeFormat.code128, text: 'B');
      platform.emit(const [_qr, second]);
      async.flushMicrotasks();

      expect(events, hasLength(1));
      expect(events.single.barcodes, const [_qr, second]);
      expect(flat, const [_qr, second]);
      expect(() => events.single.barcodes.add(_qr), throwsUnsupportedError);

      unawaited(scanner.dispose());
      async.flushMicrotasks();
    });
  });

  test('a denied camera surface maps to failed and switch recovers', () {
    fakeAsync((async) {
      final platform = FakePlatform()
        ..nextDriveResult = (_) => const ScannerStatus(
          state: ScannerState.closed,
          errorCode: 'permission_denied',
          errorMessage: 'camera permission was not granted',
        );
      final scanner = InstantBarcodeScanner(platform: platform);

      Object? error;
      unawaited(scanner.scan().then((_) {}, onError: (Object e) => error = e));
      async.flushMicrotasks();

      expect(error, isA<ScannerException>());
      expect(
        (error! as ScannerException).status.errorCode,
        'permission_denied',
      );
      expect(scanner.state, ScannerState.failed);
      expect(scanner.status.value.errorCode, 'permission_denied');

      unawaited(scanner.switchCamera(facing: CameraFacing.front));
      async.flushMicrotasks();
      expect(scanner.config.facing, CameraFacing.front);
      expect(scanner.state, ScannerState.closed);

      unawaited(scanner.dispose());
      async.flushMicrotasks();
    });
  });
}
