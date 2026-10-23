import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

import 'fake_platform.dart';

/// Regression tests for the lifecycle races found in the v0.1 audit:
/// disposal vs in-flight commands, handoff reentrancy, scan cancellation,
/// platform transport failures and capability degradation.
void main() {
  group('dispose races', () {
    test('dispose is idempotent and resets the platform once', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);

        final first = scanner.dispose();
        final second = scanner.dispose();
        async.flushMicrotasks();

        expect(identical(first, second), isTrue);
        expect(platform.disposeCalls, 1);
        expect(scanner.textureId.value, isNull);
      });
    });

    test('endNfcHandoff after dispose never reopens the camera', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);

        unawaited(scanner.warmUp());
        async.flushMicrotasks();
        unawaited(scanner.beginNfcHandoff());
        async.flushMicrotasks();
        expect(platform.drives, [ScannerState.parked, ScannerState.closed]);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
        final afterDispose = List.of(platform.drives);

        unawaited(scanner.endNfcHandoff());
        async.flushMicrotasks();

        expect(platform.drives, afterDispose);
        expect(scanner.state, ScannerState.closed);
      });
    });

    test('warmUp suspended on the texture does not drive after dispose', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final texture = Completer<int>();
        platform.textureHandler = () => texture.future;
        final scanner = InstantBarcodeScanner(platform: platform);

        unawaited(scanner.warmUp().catchError((Object _) {}));
        async.flushMicrotasks();

        unawaited(scanner.dispose());
        async.flushMicrotasks();
        texture.complete(42);
        async.flushMicrotasks();
        async.flushMicrotasks();

        expect(platform.drives, isEmpty);
        expect(platform.disposed, isTrue);
        expect(scanner.state, ScannerState.closed);
      });
    });
  });

  group('handoff races', () {
    test('warmUp during a handoff does not reopen the camera', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);

        unawaited(scanner.warmUp());
        async.flushMicrotasks();
        unawaited(scanner.beginNfcHandoff());
        async.flushMicrotasks();

        unawaited(scanner.warmUp());
        async.flushMicrotasks();
        expect(platform.drives, [ScannerState.parked, ScannerState.closed]);

        unawaited(scanner.endNfcHandoff());
        async.flushMicrotasks();
        expect(platform.drives, [
          ScannerState.parked,
          ScannerState.closed,
          ScannerState.parked,
        ]);
        expect(scanner.state, ScannerState.parked);
      });
    });

    test('a second beginNfcHandoff does not drop the resume target', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);

        unawaited(scanner.warmUp());
        async.flushMicrotasks();
        unawaited(scanner.beginNfcHandoff());
        async.flushMicrotasks();
        unawaited(scanner.beginNfcHandoff());
        async.flushMicrotasks();
        unawaited(scanner.endNfcHandoff());
        async.flushMicrotasks();

        expect(platform.drives, [
          ScannerState.parked,
          ScannerState.closed,
          ScannerState.parked,
        ]);
        expect(scanner.state, ScannerState.parked);
      });
    });

    test('a scan requested during a handoff waits and then reads', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);

        unawaited(scanner.beginNfcHandoff());
        async.flushMicrotasks();

        ScanResult? result;
        unawaited(
          scanner.scan().then(
            (value) => result = value,
            onError: (Object _) {},
          ),
        );
        async.flushMicrotasks();
        expect(scanner.state, ScannerState.closed);
        expect(result, isNull);

        unawaited(scanner.endNfcHandoff());
        async.flushMicrotasks();
        expect(scanner.state, ScannerState.live);

        platform.emit([
          const ScanResult(format: BarcodeFormat.qrCode, text: 'hello'),
        ]);
        async.flushMicrotasks();
        expect(result?.text, 'hello');
      });
    });
  });

  group('scan ordering', () {
    test('a late warmUp does not park under an active scan', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);

        unawaited(scanner.warmUp());
        async.flushMicrotasks();
        unawaited(scanner.scan().then((_) {}, onError: (Object _) {}));
        async.flushMicrotasks();
        final before = List.of(platform.drives);

        unawaited(scanner.warmUp());
        async.flushMicrotasks();

        expect(platform.drives, before);
        expect(scanner.state, ScannerState.live);
      });
    });

    test('close cancels an in-flight scan and the next scan is fresh', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);

        Object? cancelled;
        unawaited(
          scanner
              .scan(timeout: const Duration(seconds: 30))
              .then((_) {}, onError: (Object e) => cancelled = e),
        );
        async.flushMicrotasks();
        expect(scanner.state, ScannerState.live);

        unawaited(scanner.close());
        async.flushMicrotasks();
        expect(cancelled, isA<StateError>());
        expect(scanner.state, ScannerState.closed);

        Object? timedOut;
        unawaited(
          scanner
              .scan(timeout: const Duration(milliseconds: 50))
              .then((_) {}, onError: (Object e) => timedOut = e),
        );
        async.flushMicrotasks();
        expect(scanner.state, ScannerState.live);
        async.elapse(const Duration(milliseconds: 50));
        expect(timedOut, isA<TimeoutException>());

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test('park cancels an in-flight scan', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);

        Object? cancelled;
        unawaited(
          scanner
              .scan(timeout: const Duration(seconds: 30))
              .then((_) {}, onError: (Object e) => cancelled = e),
        );
        async.flushMicrotasks();

        unawaited(scanner.park());
        async.flushMicrotasks();
        expect(cancelled, isA<StateError>());
        expect(scanner.state, ScannerState.parked);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('platform events', () {
    test('a background close fails the pending scan promptly', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);

        Object? error;
        unawaited(
          scanner
              .scan(timeout: const Duration(seconds: 30))
              .then((_) {}, onError: (Object e) => error = e),
        );
        async.flushMicrotasks();

        platform.emitStatus(const ScannerStatus(state: ScannerState.closed));
        async.flushMicrotasks();

        expect(error, isA<StateError>());
        expect(scanner.state, ScannerState.closed);
      });
    });

    test('a failure event fails the pending scan with ScannerException', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);

        Object? error;
        unawaited(
          scanner
              .scan(timeout: const Duration(seconds: 30))
              .then((_) {}, onError: (Object e) => error = e),
        );
        async.flushMicrotasks();

        platform.emitStatus(
          const ScannerStatus(
            state: ScannerState.failed,
            errorCode: 'camera_disconnected',
          ),
        );
        async.flushMicrotasks();

        expect(error, isA<ScannerException>());
        expect(
          (error! as ScannerException).status.errorCode,
          'camera_disconnected',
        );
        expect(scanner.state, ScannerState.failed);
      });
    });
  });

  group('transport failures', () {
    test('a throwing drive surfaces as ScannerException(failed)', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        platform.nextDriveResult = (_) => throw PlatformException(code: 'boom');
        final scanner = InstantBarcodeScanner(platform: platform);

        Object? error;
        unawaited(
          scanner.warmUp().then((_) {}, onError: (Object e) => error = e),
        );
        async.flushMicrotasks();

        expect(error, isA<ScannerException>());
        final status = (error! as ScannerException).status;
        expect(status.state, ScannerState.failed);
        expect(status.errorCode, 'boom');
      });
    });

    test('a failed capabilities lookup is not cached', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        var calls = 0;
        platform.capabilitiesHandler = () async {
          calls++;
          if (calls == 1) {
            throw PlatformException(code: 'channel_error');
          }
          return const ScannerCapabilities(
            supportsPark: true,
            supportsTrueClose: true,
          );
        };
        final scanner = InstantBarcodeScanner(platform: platform);

        Object? error;
        unawaited(
          scanner.warmUp().then((_) {}, onError: (Object e) => error = e),
        );
        async.flushMicrotasks();
        expect(error, isA<ScannerException>());

        unawaited(scanner.warmUp());
        async.flushMicrotasks();
        expect(scanner.state, ScannerState.parked);
        expect(calls, 2);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('degraded capabilities', () {
    test('without park support warmUp opens and park closes', () {
      fakeAsync((async) {
        final platform = FakePlatform()
          ..capabilitiesResult = const ScannerCapabilities(
            supportsPark: false,
            supportsTrueClose: true,
          );
        final scanner = InstantBarcodeScanner(platform: platform);

        unawaited(scanner.warmUp());
        async.flushMicrotasks();
        expect(scanner.state, ScannerState.open);
        expect(platform.drives, [ScannerState.open]);

        unawaited(scanner.park());
        async.flushMicrotasks();
        expect(scanner.state, ScannerState.closed);
        expect(platform.drives, [ScannerState.open, ScannerState.closed]);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test('without park support a handoff resumes at open, not parked', () {
      fakeAsync((async) {
        final platform = FakePlatform()
          ..capabilitiesResult = const ScannerCapabilities(
            supportsPark: false,
            supportsTrueClose: true,
          );
        final scanner = InstantBarcodeScanner(platform: platform);

        unawaited(scanner.warmUp());
        async.flushMicrotasks();
        unawaited(scanner.beginNfcHandoff());
        async.flushMicrotasks();
        unawaited(scanner.endNfcHandoff());
        async.flushMicrotasks();

        expect(scanner.state, ScannerState.open);
        expect(platform.drives, [
          ScannerState.open,
          ScannerState.closed,
          ScannerState.open,
        ]);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });
  });
}
