import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

import 'fake_platform.dart';

const _qr = ScanResult(format: BarcodeFormat.qrCode, text: 'hello');
const _aztec = ScanResult(format: BarcodeFormat.aztec, text: 'other');

const _policy = ScannerPolicy(
  parkAfter: Duration(seconds: 5),
  closeAfter: Duration(seconds: 20),
);

void main() {
  group('session', () {
    test('warmUp creates the texture once and parks', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);

        unawaited(scanner.warmUp());
        unawaited(scanner.warmUp());
        async.flushMicrotasks();
        async.elapse(Duration.zero);

        expect(platform.current, ScannerState.parked);
        expect(scanner.textureId.value, 42);
        expect(platform.textureCalls, 1);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
        expect(platform.disposed, isTrue);
      });
    });

    test('scan drives live and the first barcode satisfies it', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);
        final streamed = <ScanResult>[];
        scanner.scans.listen(streamed.add);

        ScanResult? result;
        unawaited(scanner.scan().then((value) => result = value));
        async.flushMicrotasks();
        expect(platform.current, ScannerState.live);

        platform.emit([_qr, _aztec]);
        async.flushMicrotasks();

        expect(result, _qr);
        expect(streamed, [_qr, _aztec]);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test('concurrent scans share one future', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);

        final first = scanner.scan();
        final second = scanner.scan();
        expect(identical(first, second), isTrue);

        async.flushMicrotasks();
        expect(platform.drives, [ScannerState.live]);

        platform.emit([_qr]);
        async.flushMicrotasks();

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('idle policy', () {
    test('steps live -> parked -> closed', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(
          platform: platform,
          policy: _policy,
        );

        unawaited(scanner.scan().catchError((Object e) => _qr));
        async.flushMicrotasks();
        platform.emit([_qr]);
        async.flushMicrotasks();
        expect(platform.current, ScannerState.live);

        async.elapse(const Duration(seconds: 5));
        expect(platform.current, ScannerState.parked);

        async.elapse(const Duration(seconds: 20));
        expect(platform.current, ScannerState.closed);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test('does not park mid-scan', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(
          platform: platform,
          policy: _policy,
        );

        unawaited(
          scanner
              .scan(timeout: const Duration(seconds: 30))
              .catchError((Object e) => _qr),
        );
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 15));
        expect(platform.current, ScannerState.live);

        platform.emit([_qr]);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        expect(platform.current, ScannerState.parked);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test('a barcode after a timeout does not reset the countdown', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(
          platform: platform,
          policy: _policy,
        );
        final streamed = <ScanResult>[];
        scanner.scans.listen(streamed.add);

        unawaited(
          scanner
              .scan(timeout: const Duration(seconds: 3))
              .catchError((Object e) => _qr),
        );
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();

        // A late frame arrives with no scan waiting for it: it reaches the
        // stream but must not keep the camera lit.
        platform.emit([_qr]);
        async.flushMicrotasks();
        expect(streamed, [_qr]);

        async.elapse(const Duration(seconds: 2));
        expect(platform.current, ScannerState.parked);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test('park() while parked re-arms the close timer', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(
          platform: platform,
          policy: _policy,
        );

        unawaited(scanner.warmUp());
        async.flushMicrotasks();
        expect(platform.current, ScannerState.parked);

        async.elapse(const Duration(seconds: 15));
        unawaited(scanner.park());
        async.flushMicrotasks();
        expect(platform.current, ScannerState.parked);

        // 25 s since warmUp, but only 10 s since the explicit park: the
        // session must still be warm.
        async.elapse(const Duration(seconds: 10));
        expect(platform.current, ScannerState.parked);

        async.elapse(const Duration(seconds: 10));
        expect(platform.current, ScannerState.closed);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('failures', () {
    test('a failed convergence throws and surfaces failed status', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);
        platform.nextDriveResult = (target) => const ScannerStatus(
          state: ScannerState.closed,
          errorCode: 'open_failed',
          errorMessage: 'camera device failed to open',
        );

        Object? error;
        unawaited(
          scanner.warmUp().catchError((Object e) {
            error = e;
          }),
        );
        async.flushMicrotasks();

        expect(error, isA<ScannerException>());
        final failure = error! as ScannerException;
        expect(failure.status.errorCode, 'open_failed');
        expect(scanner.status.value.state, ScannerState.failed);
        expect(
          scanner.status.value.errorMessage,
          'camera device failed to open',
        );

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test('a scan can retry after a failure', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);
        platform.nextDriveResult = (target) => const ScannerStatus(
          state: ScannerState.closed,
          errorCode: 'configure_failed',
          errorMessage: 'capture session failed to configure',
        );

        Object? error;
        unawaited(
          scanner.scan().catchError((Object e) {
            error = e;
            return _qr;
          }),
        );
        async.flushMicrotasks();
        expect(error, isA<ScannerException>());
        expect(scanner.state, ScannerState.failed);

        ScanResult? result;
        unawaited(scanner.scan().then((value) => result = value));
        async.flushMicrotasks();
        expect(scanner.state, ScannerState.live);

        platform.emit([_qr]);
        async.flushMicrotasks();
        expect(result, _qr);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test('close() throws when the mechanism is retargeted instead', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(
          platform: platform,
          policy: _policy,
        );
        platform.nextDriveResult = (target) =>
            const ScannerStatus(state: ScannerState.parked);

        Object? error;
        unawaited(
          scanner.close().catchError((Object e) {
            error = e;
          }),
        );
        async.flushMicrotasks();

        expect(error, isA<ScannerException>());
        expect((error! as ScannerException).status.state, ScannerState.parked);
        expect(scanner.state, ScannerState.parked);

        // The confirmed parked state still idles down: never trust a command
        // that did not reach its target, but do honor what was confirmed.
        async.elapse(const Duration(seconds: 20));
        expect(scanner.state, ScannerState.closed);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('NFC handoff', () {
    test('begin closes, end restores the previous state', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(
          platform: platform,
          policy: _policy,
        );

        unawaited(
          scanner
              .scan(timeout: const Duration(seconds: 30))
              .catchError((Object e) => _qr),
        );
        async.flushMicrotasks();
        expect(scanner.state, ScannerState.live);

        unawaited(scanner.beginNfcHandoff());
        async.flushMicrotasks();
        expect(scanner.state, ScannerState.closed);
        expect(platform.drives.last, ScannerState.closed);

        // A scan requested while the handoff is active waits for it to end
        // rather than failing: hosts switch screens and scan within the same
        // frame as endNfcHandoff() is issued.
        ScanResult? queued;
        unawaited(scanner.scan().then((ScanResult result) => queued = result));
        async.flushMicrotasks();
        expect(platform.drives.last, ScannerState.closed);

        // No idle step while the handoff is active.
        async.elapse(const Duration(minutes: 2));
        expect(scanner.state, ScannerState.closed);

        unawaited(scanner.endNfcHandoff());
        async.flushMicrotasks();
        expect(scanner.state, ScannerState.live);
        expect(platform.drives.last, ScannerState.live);

        platform.emit(<ScanResult>[_qr]);
        async.flushMicrotasks();
        expect(queued, _qr);

        // The burst window resumes: park after 5 s.
        async.elapse(const Duration(seconds: 5));
        expect(scanner.state, ScannerState.parked);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test('a scan queued behind a handoff fails on dispose', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(
          platform: platform,
          policy: _policy,
        );

        unawaited(scanner.beginNfcHandoff());
        async.flushMicrotasks();
        expect(scanner.state, ScannerState.closed);

        Object? error;
        unawaited(
          scanner.scan().catchError((Object e) {
            error = e;
            return _qr;
          }),
        );
        async.flushMicrotasks();
        expect(error, isNull);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
        expect(error, isA<StateError>());
      });
    });

    test('a failed begin releases the handoff lock', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);
        const failure = ScannerStatus(
          state: ScannerState.closed,
          errorCode: 'repeating_failed',
          errorMessage: 'repeating request failed',
        );
        platform.nextDriveResult = (target) => failure;

        Object? handoffError;
        unawaited(
          scanner.beginNfcHandoff().catchError((Object e) {
            handoffError = e;
          }),
        );
        async.flushMicrotasks();
        expect(handoffError, isA<ScannerException>());

        // The scanner is not stuck in handoff mode: scan() may run and fails
        // for the platform's reason, not with a handoff StateError.
        platform.nextDriveResult = (target) => failure;
        Object? scanError;
        unawaited(
          scanner.scan().catchError((Object e) {
            scanError = e;
            return _qr;
          }),
        );
        async.flushMicrotasks();
        expect(scanError, isA<ScannerException>());
        expect(scanError, isNot(isA<StateError>()));

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });
  });

  group('dispose', () {
    test('completes a pending scan with a StateError', () {
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
        expect(scanner.state, ScannerState.live);

        unawaited(scanner.dispose());
        async.flushMicrotasks();

        expect(error, isA<StateError>());
        expect(platform.disposed, isTrue);
      });
    });

    test('rejects further use and never throws from state getters', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);

        unawaited(scanner.dispose());
        async.flushMicrotasks();

        expect(scanner.state, ScannerState.closed);
        expect(scanner.textureId.value, isNull);
        expect(platform.disposeCalls, 1);
        expect(() => scanner.scan(), throwsStateError);

        Object? warmUpError;
        unawaited(
          scanner.warmUp().catchError((Object e) {
            warmUpError = e;
          }),
        );
        async.flushMicrotasks();
        expect(warmUpError, isA<StateError>());
        expect(scanner.scans, isNotNull);
      });
    });
  });

  group('texture', () {
    test('a failed lookup is not cached', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);
        var fail = true;
        platform.textureHandler = () async {
          if (fail) {
            throw StateError('texture unavailable');
          }
          return 7;
        };

        Object? error;
        unawaited(
          scanner.warmUp().catchError((Object e) {
            error = e;
          }),
        );
        async.flushMicrotasks();
        expect(error, isA<StateError>());

        fail = false;
        unawaited(scanner.warmUp());
        async.flushMicrotasks();
        expect(scanner.textureId.value, 7);
        expect(platform.textureCalls, 2);

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });

    test('concurrent warmUp and scan share one lookup', () {
      fakeAsync((async) {
        final platform = FakePlatform();
        final scanner = InstantBarcodeScanner(platform: platform);
        final texture = Completer<int>();
        platform.textureHandler = () => texture.future;

        unawaited(scanner.warmUp());
        unawaited(scanner.scan().catchError((Object e) => _qr));
        async.flushMicrotasks();
        expect(platform.textureCalls, 1);

        texture.complete(42);
        async.flushMicrotasks();
        async.flushMicrotasks();
        expect(scanner.textureId.value, 42);
        expect(platform.textureCalls, 1);
        expect(
          platform.drives,
          containsAll([ScannerState.parked, ScannerState.live]),
        );

        unawaited(scanner.dispose());
        async.flushMicrotasks();
      });
    });
  });
}
