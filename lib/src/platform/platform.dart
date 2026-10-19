import '../pigeon/messages.g.dart' as pigeon;
import 'types.dart';

/// The platform boundary.
///
/// The controller talks only to this interface; the method-channel
/// implementation below maps it onto the pigeon-generated host API. Tests
/// substitute a fake by assigning [instance].
abstract class InstantBarcodeScannerPlatform {
  static InstantBarcodeScannerPlatform? _instance;

  static InstantBarcodeScannerPlatform get instance =>
      _instance ??= MethodChannelInstantBarcodeScannerPlatform();

  static set instance(InstantBarcodeScannerPlatform value) => _instance = value;

  /// Register the controller's event sinks. Called once per controller.
  void setEventHandlers({
    required void Function(ScannerStatus status) onState,
    required void Function(List<ScanResult> results) onBarcodes,
  });

  /// Texture id for the camera preview; the texture is created on first
  /// call and survives a [dispose] reset (it is engine-scoped, not
  /// controller-scoped).
  Future<int> getTextureId();

  Future<ScannerCapabilities> getCapabilities();

  /// Drive the mechanism toward [target] and complete with the confirmed
  /// status. The future may complete with a state other than [target] if the
  /// mechanism failed or was retargeted; callers must check the result.
  ///
  /// For `closed`, completion additionally waits until the camera HAL reports
  /// the device available again.
  Future<ScannerStatus> driveTo(ScannerState target);

  /// Reset the mechanism and release all resources. The platform can serve a
  /// new session afterwards; it is not a terminal shutdown.
  Future<void> dispose();
}

/// Production implementation, backed by the pigeon host API.
class MethodChannelInstantBarcodeScannerPlatform
    implements InstantBarcodeScannerPlatform, pigeon.ScannerFlutterApi {
  MethodChannelInstantBarcodeScannerPlatform({pigeon.ScannerHostApi? hostApi})
    : _hostApi = hostApi ?? pigeon.ScannerHostApi() {
    pigeon.ScannerFlutterApi.setUp(this);
  }

  final pigeon.ScannerHostApi _hostApi;

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
  void onStateChanged(pigeon.PlatformSnapshot snapshot) {
    _onState?.call(_statusFromPigeon(snapshot));
  }

  @override
  void onBarcodes(List<pigeon.PlatformBarcode> barcodes) {
    _onBarcodes?.call(barcodes.map(_resultFromPigeon).toList());
  }

  @override
  Future<int> getTextureId() => _hostApi.getTextureId();

  @override
  Future<ScannerCapabilities> getCapabilities() async {
    final caps = await _hostApi.getCapabilities();
    return ScannerCapabilities(
      supportsPark: caps.supportsPark,
      supportsTrueClose: caps.supportsTrueClose,
    );
  }

  @override
  Future<ScannerStatus> driveTo(ScannerState target) async {
    final snapshot = await _hostApi.driveTo(_stateToPigeon(target));
    return _statusFromPigeon(snapshot);
  }

  @override
  Future<void> dispose() => _hostApi.dispose();
}

ScannerStatus _statusFromPigeon(pigeon.PlatformSnapshot snapshot) {
  return ScannerStatus(
    state: _stateFromPigeon(snapshot.state),
    errorCode: snapshot.errorCode,
    errorMessage: snapshot.errorMessage,
  );
}

ScanResult _resultFromPigeon(pigeon.PlatformBarcode barcode) {
  return ScanResult(
    format: _formatFromPigeon(barcode.format),
    rawBytes: barcode.rawBytes,
    text: barcode.text,
  );
}

ScannerState _stateFromPigeon(pigeon.PlatformState state) {
  return switch (state) {
    pigeon.PlatformState.closed => ScannerState.closed,
    pigeon.PlatformState.opening => ScannerState.opening,
    pigeon.PlatformState.open => ScannerState.open,
    pigeon.PlatformState.parked => ScannerState.parked,
    pigeon.PlatformState.live => ScannerState.live,
    pigeon.PlatformState.closing => ScannerState.closing,
    pigeon.PlatformState.failed => ScannerState.failed,
  };
}

pigeon.PlatformState _stateToPigeon(ScannerState state) {
  return switch (state) {
    ScannerState.closed => pigeon.PlatformState.closed,
    ScannerState.opening => pigeon.PlatformState.opening,
    ScannerState.open => pigeon.PlatformState.open,
    ScannerState.parked => pigeon.PlatformState.parked,
    ScannerState.live => pigeon.PlatformState.live,
    ScannerState.closing => pigeon.PlatformState.closing,
    ScannerState.failed => pigeon.PlatformState.failed,
  };
}

BarcodeFormat _formatFromPigeon(pigeon.PlatformBarcodeFormat format) {
  return switch (format) {
    pigeon.PlatformBarcodeFormat.aztec => BarcodeFormat.aztec,
    pigeon.PlatformBarcodeFormat.codabar => BarcodeFormat.codabar,
    pigeon.PlatformBarcodeFormat.code39 => BarcodeFormat.code39,
    pigeon.PlatformBarcodeFormat.code93 => BarcodeFormat.code93,
    pigeon.PlatformBarcodeFormat.code128 => BarcodeFormat.code128,
    pigeon.PlatformBarcodeFormat.dataMatrix => BarcodeFormat.dataMatrix,
    pigeon.PlatformBarcodeFormat.ean8 => BarcodeFormat.ean8,
    pigeon.PlatformBarcodeFormat.ean13 => BarcodeFormat.ean13,
    pigeon.PlatformBarcodeFormat.itf => BarcodeFormat.itf,
    pigeon.PlatformBarcodeFormat.pdf417 => BarcodeFormat.pdf417,
    pigeon.PlatformBarcodeFormat.qrCode => BarcodeFormat.qrCode,
    pigeon.PlatformBarcodeFormat.upcA => BarcodeFormat.upcA,
    pigeon.PlatformBarcodeFormat.upcE => BarcodeFormat.upcE,
    pigeon.PlatformBarcodeFormat.unknown => BarcodeFormat.unknown,
  };
}
