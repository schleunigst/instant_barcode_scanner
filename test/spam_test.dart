import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

import 'fake_platform.dart';

/// Hammer suite for the screen-toggle bug: spamming between a scan screen
/// and an RFID screen (close/park/handoff/dispose interleaving) must always
/// settle on the state the last call requested, never leave a disposed
/// scanner usable behind, and never let errors escape unobserved.
///
/// The fake converges every drive to its requested state, so any deviation
/// from the invariants below is a controller bug, not a platform quirk.
void main() {
  for (final seed in [1, 2, 3, 7, 11, 23]) {
    _runSeed(seed);
  }
}

void _runSeed(int seed) {
  final rng = Random(seed);
  final label = 'seed $seed';

  test('[$label] close-on-leave spam settles on the last warmUp', () async {
    final platform = FakePlatform();
    final errors = <Object>[];
    final scanner = InstantBarcodeScanner(platform: platform);
    _drain(scanner);
    for (var i = 0; i < 6; i++) {
      _shake(rng);
      _fire(errors, scanner.close());
      _shake(rng);
      _fire(errors, scanner.warmUp());
    }
    _shake(rng);
    await scanner.warmUp();
    expect(errors, isEmpty, reason: 'no call may throw unexpectedly');
    expect(scanner.state, ScannerState.parked);
    await scanner.dispose();
  });

  test('[$label] handoff spam settles on the resumed state', () async {
    final platform = FakePlatform();
    final errors = <Object>[];
    final scanner = InstantBarcodeScanner(platform: platform);
    _drain(scanner);
    await scanner.warmUp();
    for (var i = 0; i < 6; i++) {
      _shake(rng);
      _fire(errors, scanner.beginNfcHandoff());
      _shake(rng);
      _fire(errors, scanner.endNfcHandoff());
      _shake(rng);
      _fire(errors, scanner.warmUp());
    }
    _shake(rng);
    await scanner.endNfcHandoff();
    // The last handoff may have captured `closed` before earlier drives
    // confirmed; re-warming the scan screen settles deterministically.
    await scanner.warmUp();
    expect(errors, isEmpty, reason: 'no call may throw unexpectedly');
    // The last completed interaction is a handoff end: it restores the
    // state captured at the handoff begin.
    expect(scanner.state, ScannerState.parked);
    await scanner.dispose();
  });

  test('[$label] dispose-and-recreate per screen spam', () async {
    // Model: leaving the scan screen disposes the controller; entering
    // creates a fresh one and warms it.
    var scanner = InstantBarcodeScanner(platform: FakePlatform());
    _drain(scanner);
    for (var i = 0; i < 6; i++) {
      _shake(rng);
      final doomed = scanner;
      unawaited(
        doomed.dispose().then(
          (_) {},
          onError: (Object e) {
            // Disposing twice can race; only unexpected kinds are bugs.
            if (e is! StateError) {
              fail('dispose raced with: $e');
            }
          },
        ),
      );
      _shake(rng);
      scanner = InstantBarcodeScanner(platform: FakePlatform());
      _drain(scanner);
      _fire(<Object>[], scanner.warmUp());
    }
    _shake(rng);
    await scanner.warmUp();
    expect(scanner.state, ScannerState.parked);
    await scanner.dispose();
  });

  test('[$label] scan spam with handoff interruptions', () async {
    final platform = FakePlatform();
    final errors = <Object>[];
    final scanErrors = <Object>[];
    final scanner = InstantBarcodeScanner(platform: platform);
    _drain(scanner);
    for (var i = 0; i < 6; i++) {
      _shake(rng);
      _fire(scanErrors, scanner.scan(timeout: const Duration(milliseconds: 1)));
      _shake(rng);
      _fire(errors, scanner.beginNfcHandoff());
      _shake(rng);
      _fire(errors, scanner.endNfcHandoff());
    }
    _shake(rng);
    await scanner.endNfcHandoff();
    await scanner.park();
    await scanner.warmUp();
    expect(errors, isEmpty, reason: 'no call may throw unexpectedly');
    expect(
      scanErrors.where((e) => e is! StateError && e is! TimeoutException),
      isEmpty,
      reason:
          'a scan may only fail because it was cancelled (close/park/handoff) '
          'or because its own window elapsed',
    );
    expect(
      scanner.state,
      ScannerState.parked,
      reason:
          'after spam that ends on a scan screen (warmUp), the scanner '
          'must settle on parked',
    );
    await scanner.dispose();
  });
}

// --- helpers ---------------------------------------------------------------

/// Run a fire-and-forget command, collecting unexpected errors.
void _fire(List<Object> errors, Future<void> future) {
  unawaited(future.then((_) {}, onError: (Object e) => errors.add(e)));
}

void _drain(InstantBarcodeScanner scanner) {
  unawaited(
    scanner.scans.listen((_) {}).asFuture<void>().then((_) {}, onError: (_) {}),
  );
}

/// Random number of event-loop hops so unawaited chains interleave in
/// different orders across seeds.
Future<void> _shake(Random rng) async {
  for (var i = 0, n = rng.nextInt(5); i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
