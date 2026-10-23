import 'dart:ui' show Offset, Rect;

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

  /// Apply the fixed controller configuration. Called before the first call
  /// that touches camera hardware and awaited by every such call.
  Future<void> configure(ScannerConfig config);

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

  /// Switch to another facing/lens while preserving the confirmed state.
  Future<ScannerStatus> switchCamera(
    CameraFacing facing,
    CameraLensType lensType,
  );

  /// Turn the torch on/off on the live camera.
  Future<void> setTorch(bool enabled);

  /// Set the zoom ratio in device units (clamped by the platform).
  Future<void> setZoom(double ratio);

  /// Restrict decoding to [window] (normalized 0..1, upright analysis frame);
  /// null clears the restriction.
  Future<void> updateScanWindow(Rect? window);

  /// Decode barcodes from an image file; no camera session required.
  Future<List<ScanResult>> analyzeImage(String path);

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
  Future<List<ScanResult>> analyzeImage(String path) async {
    final results = await _hostApi.analyzeImage(path);
    return results.map(_resultFromPigeon).toList(growable: false);
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
  Future<void> configure(ScannerConfig config) async {
    final resolution = config.cameraResolution;
    await _hostApi.configure(
      pigeon.PlatformScannerConfig(
        facing: _facingToPigeon(config.facing),
        lensType: _lensTypeToPigeon(config.lensType),
        formats: config.formats.map(_formatToPigeon).toList(),
        torchEnabled: config.torchEnabled,
        initialZoom: config.initialZoom,
        targetWidth: resolution?.width.round(),
        targetHeight: resolution?.height.round(),
        detectionSpeed: _detectionToPigeon(config.detectionSpeed),
        detectionTimeoutMs: config.detectionTimeout.inMilliseconds,
        invertImage: config.invertImage,
      ),
    );
  }

  @override
  Future<int> getTextureId() => _hostApi.getTextureId();

  @override
  Future<ScannerCapabilities> getCapabilities() async {
    final caps = await _hostApi.getCapabilities();
    return ScannerCapabilities(
      supportsPark: caps.supportsPark,
      supportsTrueClose: caps.supportsTrueClose,
      supportsTorch: caps.supportsTorch,
      supportsZoom: caps.supportsZoom,
      minZoom: caps.minZoom,
      maxZoom: caps.maxZoom,
    );
  }

  @override
  Future<ScannerStatus> driveTo(ScannerState target) async {
    final snapshot = await _hostApi.driveTo(_stateToPigeon(target));
    return _statusFromPigeon(snapshot);
  }

  @override
  Future<ScannerStatus> switchCamera(
    CameraFacing facing,
    CameraLensType lensType,
  ) async {
    final snapshot = await _hostApi.switchCamera(
      _facingToPigeon(facing),
      _lensTypeToPigeon(lensType),
    );
    return _statusFromPigeon(snapshot);
  }

  @override
  Future<void> setTorch(bool enabled) => _hostApi.setTorch(enabled);

  @override
  Future<void> setZoom(double ratio) => _hostApi.setZoom(ratio);

  @override
  Future<void> updateScanWindow(Rect? window) {
    return _hostApi.updateScanWindow(
      window == null
          ? null
          : pigeon.PlatformRect(
              left: window.left,
              top: window.top,
              right: window.right,
              bottom: window.bottom,
            ),
    );
  }

  @override
  Future<void> dispose() => _hostApi.dispose();
}

pigeon.PlatformCameraFacing _facingToPigeon(CameraFacing facing) {
  return switch (facing) {
    CameraFacing.back => pigeon.PlatformCameraFacing.back,
    CameraFacing.front => pigeon.PlatformCameraFacing.front,
    CameraFacing.external => pigeon.PlatformCameraFacing.external,
  };
}

pigeon.PlatformCameraLensType _lensTypeToPigeon(CameraLensType lensType) {
  return switch (lensType) {
    CameraLensType.any => pigeon.PlatformCameraLensType.any,
    CameraLensType.normal => pigeon.PlatformCameraLensType.normal,
    CameraLensType.wide => pigeon.PlatformCameraLensType.wide,
    CameraLensType.zoom => pigeon.PlatformCameraLensType.zoom,
  };
}

pigeon.PlatformDetectionSpeed _detectionToPigeon(DetectionSpeed speed) {
  return switch (speed) {
    DetectionSpeed.noDuplicates => pigeon.PlatformDetectionSpeed.noDuplicates,
    DetectionSpeed.normal => pigeon.PlatformDetectionSpeed.normal,
    DetectionSpeed.unrestricted => pigeon.PlatformDetectionSpeed.unrestricted,
  };
}

pigeon.PlatformBarcodeFormat _formatToPigeon(BarcodeFormat format) {
  return switch (format) {
    BarcodeFormat.aztec => pigeon.PlatformBarcodeFormat.aztec,
    BarcodeFormat.codabar => pigeon.PlatformBarcodeFormat.codabar,
    BarcodeFormat.code39 => pigeon.PlatformBarcodeFormat.code39,
    BarcodeFormat.code93 => pigeon.PlatformBarcodeFormat.code93,
    BarcodeFormat.code128 => pigeon.PlatformBarcodeFormat.code128,
    BarcodeFormat.dataMatrix => pigeon.PlatformBarcodeFormat.dataMatrix,
    BarcodeFormat.ean8 => pigeon.PlatformBarcodeFormat.ean8,
    BarcodeFormat.ean13 => pigeon.PlatformBarcodeFormat.ean13,
    BarcodeFormat.itf => pigeon.PlatformBarcodeFormat.itf,
    BarcodeFormat.pdf417 => pigeon.PlatformBarcodeFormat.pdf417,
    BarcodeFormat.qrCode => pigeon.PlatformBarcodeFormat.qrCode,
    BarcodeFormat.upcA => pigeon.PlatformBarcodeFormat.upcA,
    BarcodeFormat.upcE => pigeon.PlatformBarcodeFormat.upcE,
    BarcodeFormat.unknown => pigeon.PlatformBarcodeFormat.unknown,
  };
}

ScannerStatus _statusFromPigeon(pigeon.PlatformSnapshot snapshot) {
  return ScannerStatus(
    state: _stateFromPigeon(snapshot.state),
    errorCode: snapshot.errorCode,
    errorMessage: snapshot.errorMessage,
  );
}

ScanResult _resultFromPigeon(pigeon.PlatformBarcode barcode) {
  final box = barcode.boundingBox;
  return ScanResult(
    format: _formatFromPigeon(barcode.format),
    rawBytes: barcode.rawBytes,
    text: barcode.text,
    displayValue: barcode.displayValue,
    type: _typeFromPigeon(barcode.valueType),
    boundingBox: box == null
        ? null
        : Rect.fromLTRB(box.left, box.top, box.right, box.bottom),
    corners: barcode.corners
        ?.map((point) => Offset(point.x, point.y))
        .toList(growable: false),
  );
}

BarcodeType _typeFromPigeon(pigeon.PlatformBarcodeValueType type) {
  return switch (type) {
    pigeon.PlatformBarcodeValueType.unknown => BarcodeType.unknown,
    pigeon.PlatformBarcodeValueType.contactInfo => BarcodeType.contactInfo,
    pigeon.PlatformBarcodeValueType.email => BarcodeType.email,
    pigeon.PlatformBarcodeValueType.isbn => BarcodeType.isbn,
    pigeon.PlatformBarcodeValueType.phone => BarcodeType.phone,
    pigeon.PlatformBarcodeValueType.product => BarcodeType.product,
    pigeon.PlatformBarcodeValueType.sms => BarcodeType.sms,
    pigeon.PlatformBarcodeValueType.text => BarcodeType.text,
    pigeon.PlatformBarcodeValueType.url => BarcodeType.url,
    pigeon.PlatformBarcodeValueType.wifi => BarcodeType.wifi,
    pigeon.PlatformBarcodeValueType.geo => BarcodeType.geo,
    pigeon.PlatformBarcodeValueType.calendarEvent => BarcodeType.calendarEvent,
    pigeon.PlatformBarcodeValueType.driverLicense => BarcodeType.driverLicense,
  };
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
