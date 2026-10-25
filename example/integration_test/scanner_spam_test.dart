import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

/// Real-plugin spam harness: toggles between the two screen behaviors of the
/// integration target app at event-loop speed:
///
///   scan screen  = warmUp() (and waits a moment parked)
///   rfid screen  = dispose + recreate (model A), or NFC handoff (model B)
///
/// It ends on the scan screen with an awaited warmUp and asserts the
/// scanner settled on `parked` — the regression for the "stays black with
/// state: closed" bug after fast screen toggling.
void main() {
  testWidgets('spam settles parked (dispose model, zero-sleep burst)', (
    tester,
  ) async {
    var scanner = InstantBarcodeScanner();
    final log = <ScannerState>[];
    void track() => scanner.status.addListener(() => log.add(scanner.state));

    track();
    await scanner.warmUp();
    expect(scanner.state, ScannerState.parked);

    for (var i = 0; i < 40; i++) {
      final leaving = scanner;
      final disposed = leaving.dispose();
      scanner = InstantBarcodeScanner();
      // Fire-and-forget on purpose: a later iteration may dispose this
      // controller before the queued warmUp starts, which completes with a
      // StateError by contract. Apps should observe fire-and-forget errors;
      // this harness only cares about the settled state.
      unawaited(scanner.warmUp().catchError((Object _) {}));
      track();
      await disposed;
    }
    await scanner.warmUp();
    expect(
      scanner.state,
      ScannerState.parked,
      reason:
          'after a zero-sleep recreate+warmUp burst ending on the scan '
          'screen, the scanner must settle parked (history: $log)',
    );
    expect(scanner.textureId.value, isNotNull);
    await scanner.dispose();
  });

  testWidgets('spam settles parked (handoff model, zero-sleep burst)', (
    tester,
  ) async {
    final scanner = InstantBarcodeScanner();
    final log = <ScannerState>[];
    scanner.status.addListener(() => log.add(scanner.state));

    await scanner.warmUp();
    expect(scanner.state, ScannerState.parked);

    for (var i = 0; i < 40; i++) {
      scanner.beginNfcHandoff();
      scanner.warmUp();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      scanner.endNfcHandoff();
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await scanner.warmUp();
    expect(
      scanner.state,
      ScannerState.parked,
      reason:
          'after a zero-sleep handoff+warmUp burst ending on the scan '
          'screen, the scanner must settle parked (history: $log)',
    );
    expect(scanner.textureId.value, isNotNull);
    await scanner.dispose();
  });
}
