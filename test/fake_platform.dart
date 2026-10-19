import 'dart:async';

import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

/// Platform fake with the real async shape: [driveTo] never completes
/// synchronously, the state event is delivered before the reply (pigeon
/// order), and a call can be held, failed, or confirmed with a different
/// state than requested — the cases the native mechanism produces when
/// commands are retargeted or converge badly.
class FakePlatform implements InstantBarcodeScannerPlatform {
  final List<ScannerState> drives = [];
  ScannerState current = ScannerState.closed;
  bool disposed = false;
  int disposeCalls = 0;
  int textureCalls = 0;
  ScannerCapabilities capabilitiesResult = const ScannerCapabilities(
    supportsPark: true,
    supportsTrueClose: true,
  );

  final List<Completer<ScannerStatus>> _held = [];
  Future<int> Function()? textureHandler;
  ScannerStatus Function(ScannerState target)? nextDriveResult;
  bool holdDrives = false;

  void Function(ScannerStatus status)? _onState;
  void Function(List<ScanResult> results)? _onBarcodes;

  @override
  void setEventHandlers({
    required void Function(ScannerStatus status) onState,
    required void Function(List<ScanResult> results) onBarcodes,
  }) {
    _onState = onState;
    _onBarcodes = onBarcodes;
  }

  @override
  Future<int> getTextureId() {
    textureCalls++;
    final handler = textureHandler;
    if (handler != null) {
      return handler();
    }
    return Future.value(42);
  }

  @override
  Future<ScannerCapabilities> getCapabilities() =>
      Future.value(capabilitiesResult);

  @override
  Future<ScannerStatus> driveTo(ScannerState target) {
    drives.add(target);
    final result = nextDriveResult;
    if (result != null) {
      nextDriveResult = null;
      return Future.value(_confirm(result(target)));
    }
    if (holdDrives) {
      final completer = Completer<ScannerStatus>();
      _held.add(completer);
      return completer.future;
    }
    return Future.value(_confirm(ScannerStatus(state: target)));
  }

  @override
  Future<void> dispose() {
    disposeCalls++;
    disposed = true;
    return Future.value();
  }

  /// Finish the oldest held [driveTo] call, confirming [actual] as the state
  /// the mechanism ended up in.
  void completeHeld(ScannerState actual) {
    final completer = _held.removeAt(0);
    completer.complete(_confirm(ScannerStatus(state: actual)));
  }

  ScannerStatus _confirm(ScannerStatus status) {
    current = status.state;
    _onState?.call(status);
    return status;
  }

  void emit(List<ScanResult> results) => _onBarcodes?.call(results);
}
