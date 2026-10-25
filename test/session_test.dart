import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

import 'fake_platform.dart';

const _qr = ScanResult(format: BarcodeFormat.qrCode, text: 'hello');

void main() {
  test('start warms once and pause/resume are idempotent', () {
    fakeAsync((async) {
      final platform = FakePlatform();
      final session = ScanSession(platform: platform);

      unawaited(session.start());
      async.flushMicrotasks();
      expect(session.isStarted, isTrue);
      expect(session.isPaused, isFalse);
      expect(session.state, ScannerState.parked);
      expect(platform.drives, [ScannerState.parked]);

      unawaited(session.start());
      async.flushMicrotasks();
      expect(platform.drives, [ScannerState.parked]);

      unawaited(session.pause());
      async.flushMicrotasks();
      expect(session.isPaused, isTrue);
      expect(platform.drives, [ScannerState.parked]);

      unawaited(session.pause());
      async.flushMicrotasks();
      expect(platform.drives, [ScannerState.parked]);

      unawaited(session.resume());
      async.flushMicrotasks();
      expect(session.isPaused, isFalse);
      expect(platform.drives, [ScannerState.parked, ScannerState.parked]);

      unawaited(session.dispose());
      async.flushMicrotasks();
    });
  });

  test('pause and resume before start do not open the camera', () {
    fakeAsync((async) {
      final platform = FakePlatform();
      final session = ScanSession(platform: platform);

      unawaited(session.pause());
      async.flushMicrotasks();
      expect(session.isStarted, isFalse);
      expect(session.isPaused, isFalse);
      expect(platform.drives, isEmpty);

      unawaited(session.dispose());
      async.flushMicrotasks();
    });
  });

  test('scan starts the session and clears the paused flag', () {
    fakeAsync((async) {
      final platform = FakePlatform();
      final session = ScanSession(platform: platform);

      unawaited(session.pause());
      async.flushMicrotasks();

      ScanResult? result;
      unawaited(session.scan().then((value) => result = value));
      async.flushMicrotasks();
      expect(session.isStarted, isTrue);
      expect(session.isPaused, isFalse);
      expect(session.state, ScannerState.live);

      platform.emit(const [_qr]);
      async.flushMicrotasks();
      expect(result, _qr);

      unawaited(session.dispose());
      async.flushMicrotasks();
    });
  });

  test('without park support pause closes and resume reopens', () {
    fakeAsync((async) {
      final platform = FakePlatform()
        ..capabilitiesResult = const ScannerCapabilities(
          supportsPark: false,
          supportsTrueClose: true,
        );
      final session = ScanSession(platform: platform);

      unawaited(session.start());
      async.flushMicrotasks();
      expect(session.state, ScannerState.open);

      unawaited(session.pause());
      async.flushMicrotasks();
      expect(session.state, ScannerState.closed);
      expect(session.isPaused, isTrue);

      unawaited(session.resume());
      async.flushMicrotasks();
      expect(session.state, ScannerState.open);
      expect(session.isPaused, isFalse);

      unawaited(session.dispose());
      async.flushMicrotasks();
    });
  });

  test('pause after the idle policy closed does not reopen', () {
    fakeAsync((async) {
      final platform = FakePlatform();
      final session = ScanSession(platform: platform);

      unawaited(session.start());
      async.flushMicrotasks();
      platform.emitStatus(const ScannerStatus(state: ScannerState.closed));

      unawaited(session.pause());
      async.flushMicrotasks();
      expect(session.isPaused, isTrue);
      expect(platform.drives, [ScannerState.parked]);

      unawaited(session.resume());
      async.flushMicrotasks();
      expect(session.isPaused, isFalse);
      expect(platform.drives, [ScannerState.parked, ScannerState.parked]);

      unawaited(session.dispose());
      async.flushMicrotasks();
    });
  });

  test('dispose is idempotent and rejects further use', () async {
    final platform = FakePlatform();
    final session = ScanSession(platform: platform);

    await session.dispose();
    expect(session.isDisposed, isTrue);
    await session.dispose();
    expect(platform.disposeCalls, 1);

    expect(() => session.start(), throwsStateError);
    expect(() => session.resume(), throwsStateError);
    await expectLater(session.scan(), throwsStateError);
    await session.pause();
  });
}
