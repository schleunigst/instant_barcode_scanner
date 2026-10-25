import 'dart:async';
import 'dart:ui' show Rect;

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
  Future<ScannerCapabilities> Function()? capabilitiesHandler;
  ScannerStatus Function(ScannerState target)? nextDriveResult;
  Future<ScannerStatus> Function(CameraFacing facing, CameraLensType lensType)?
  switchHandler;
  Future<void> Function(bool enabled)? torchHandler;
  Future<void> Function(double ratio)? zoomHandler;
  Future<List<ScanResult>> Function(String path)? analyzeImageHandler;
  bool holdDrives = false;

  ScannerConfig? configured;
  int analyzedFrames = 0;
  bool torch = false;
  double zoomRatio = 1.0;
  Rect? scanWindow;
  List<ScanResult> analyzeImageResult = const [];
  final List<String> analyzedPaths = [];
  final List<(CameraFacing, CameraLensType)> switches = [];

  void Function(ScannerStatus status)? _onState;
  void Function(List<ScanResult> results)? _onBarcodes;
  void Function(PreviewMetrics metrics)? _onPreviewMetrics;
  void Function(AnalysisMetrics metrics)? _onAnalysisFrame;

  @override
  void setEventHandlers({
    required void Function(ScannerStatus status) onState,
    required void Function(List<ScanResult> results) onBarcodes,
    required void Function(PreviewMetrics metrics) onPreviewMetrics,
    required void Function(AnalysisMetrics metrics) onAnalysisFrame,
  }) {
    _onState = onState;
    _onBarcodes = onBarcodes;
    _onPreviewMetrics = onPreviewMetrics;
    _onAnalysisFrame = onAnalysisFrame;
  }

  @override
  Future<void> configure(ScannerConfig config) {
    configured = config;
    return Future.value();
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
  Future<ScannerCapabilities> getCapabilities() {
    final handler = capabilitiesHandler;
    if (handler != null) {
      return handler();
    }
    return Future.value(capabilitiesResult);
  }

  @override
  Future<int> getAnalyzedFrames() => Future.value(analyzedFrames);

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

  @override
  Future<ScannerStatus> switchCamera(
    CameraFacing facing,
    CameraLensType lensType,
  ) {
    switches.add((facing, lensType));
    final handler = switchHandler;
    if (handler != null) {
      return handler(facing, lensType);
    }
    return Future.value(ScannerStatus(state: current));
  }

  @override
  Future<void> setTorch(bool enabled) {
    torch = enabled;
    return torchHandler?.call(enabled) ?? Future.value();
  }

  @override
  Future<void> setZoom(double ratio) {
    zoomRatio = ratio;
    return zoomHandler?.call(ratio) ?? Future.value();
  }

  @override
  Future<void> updateScanWindow(Rect? window) {
    scanWindow = window;
    return Future.value();
  }

  @override
  Future<List<ScanResult>> analyzeImage(String path) {
    analyzedPaths.add(path);
    return analyzeImageHandler?.call(path) ?? Future.value(analyzeImageResult);
  }

  /// Finish the oldest held [driveTo] call, confirming [actual] as the state
  /// the mechanism ended up in.
  void completeHeld(ScannerState actual) {
    final completer = _held.removeAt(0);
    completer.complete(_confirm(ScannerStatus(state: actual)));
  }

  /// Deliver a state event without a drive call: backgrounding, unplugging,
  /// or an idle step-down confirmed by the mechanism itself.
  void emitStatus(ScannerStatus status) {
    current = status.state;
    _onState?.call(status);
  }

  ScannerStatus _confirm(ScannerStatus status) {
    current = status.state;
    _onState?.call(status);
    return status;
  }

  void emit(List<ScanResult> results) => _onBarcodes?.call(results);

  void emitPreviewMetrics(PreviewMetrics metrics) =>
      _onPreviewMetrics?.call(metrics);

  void emitAnalysisFrame(AnalysisMetrics metrics) =>
      _onAnalysisFrame?.call(metrics);
}
