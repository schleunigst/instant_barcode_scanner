import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

import 'controller.dart';
import 'platform/platform.dart';
import 'platform/policy.dart';
import 'platform/types.dart';

/// A lifecycle facade over [InstantBarcodeScanner].
///
/// The scanner already keeps its camera warm and steps down on its own; this
/// session adds explicit, idempotent `start`, `pause`, `resume`, and `dispose`
/// calls so a screen can map its own lifecycle onto the camera without
/// coordinating state flags.
///
/// [start] warms the camera without streaming. [pause] parks it, keeping the
/// device warm; on a platform without park support it closes instead. The idle
/// policy may close the camera while paused, and [resume] or [scan] reopens it.
///
/// ```dart
/// final session = ScanSession();
/// await session.start();
/// final result = await session.scan();
/// await session.pause();
/// await session.dispose();
/// ```
class ScanSession {
  ScanSession({
    ScannerConfig? config,
    InstantBarcodeScannerPlatform? platform,
    ScannerPolicy policy = const ScannerPolicy(),
  }) : scanner = InstantBarcodeScanner(
         config: config,
         platform: platform,
         policy: policy,
       );

  /// The underlying scanner, for controls this facade does not wrap.
  final InstantBarcodeScanner scanner;

  bool _started = false;
  bool _paused = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  /// True after a successful [start] and before [dispose].
  bool get isStarted => _started;

  /// True while the session is paused by [pause].
  bool get isPaused => _paused;

  /// True once [dispose] has been called.
  bool get isDisposed => _disposed;

  /// The scanner status.
  ValueListenable<ScannerStatus> get status => scanner.status;

  /// The confirmed scanner state.
  ScannerState get state => scanner.state;

  /// The preview texture id, if one exists.
  ValueListenable<int?> get textureId => scanner.textureId;

  /// Preview buffer geometry.
  ValueListenable<PreviewMetrics?> get previewMetrics => scanner.previewMetrics;

  /// Analysis-frame geometry for result coordinates.
  ValueListenable<AnalysisMetrics?> get analysisMetrics =>
      scanner.analysisMetrics;

  /// The selected camera's torch state.
  ValueListenable<TorchState> get torchState => scanner.torchState;

  /// Normalized zoom scale.
  ValueListenable<double> get zoomScale => scanner.zoomScale;

  /// Every barcode decoded while live.
  Stream<ScanResult> get scans => scanner.scans;

  /// Raw per-frame barcode batches.
  Stream<ScanEvent> get scanEvents => scanner.scanEvents;

  /// What the platform mechanism can do on this device.
  Future<ScannerCapabilities> get capabilities => scanner.capabilities;

  /// The scanner configuration.
  ScannerConfig get config => scanner.config;

  /// Warm the camera without streaming.
  ///
  /// Idempotent. Does nothing while already started and not paused, including
  /// when a scan is in flight or the scanner is live.
  Future<void> start() {
    _ensureNotDisposed();
    return _serialize(() async {
      if (_disposed) {
        return;
      }
      final current = scanner.state;
      if (_started &&
          !_paused &&
          current != ScannerState.closed &&
          current != ScannerState.failed) {
        return;
      }
      await scanner.warmUp();
      if (_disposed) {
        return;
      }
      _started = true;
      _paused = false;
    });
  }

  /// Park the camera (or close it on platforms without park support).
  ///
  /// A scan in flight is cancelled. No-op before [start], while already
  /// paused, or after [dispose]. If the idle policy already closed the camera,
  /// the session records the paused state without reopening it.
  Future<void> pause() {
    if (_disposed) {
      return Future<void>.value();
    }
    return _serialize(() async {
      if (_disposed || !_started || _paused) {
        return;
      }
      final current = scanner.state;
      if (current != ScannerState.closed &&
          current != ScannerState.failed &&
          current != ScannerState.parked) {
        await scanner.park();
      }
      if (!_disposed) {
        _paused = true;
      }
    });
  }

  /// Warm the camera again after [pause], or start it if needed.
  ///
  /// No-op when already started and not paused.
  Future<void> resume() {
    _ensureNotDisposed();
    return _serialize(() async {
      if (_disposed) {
        return;
      }
      final current = scanner.state;
      final needsWarmUp =
          !_started ||
          _paused ||
          current == ScannerState.closed ||
          current == ScannerState.failed;
      if (!needsWarmUp) {
        return;
      }
      await scanner.warmUp();
      if (_disposed) {
        return;
      }
      _started = true;
      _paused = false;
    });
  }

  /// Scan, starting or resuming the session first when necessary.
  Future<ScanResult> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _ensureNotDisposed();
    if (!_started) {
      await start();
    } else if (_paused ||
        state == ScannerState.closed ||
        state == ScannerState.failed) {
      await resume();
    }
    _started = true;
    _paused = false;
    final result = await scanner.scan(timeout: timeout);
    if (!_disposed) {
      _started = true;
      _paused = false;
    }
    return result;
  }

  /// Switch the active camera while preserving the session state.
  Future<void> switchCamera({CameraFacing? facing, CameraLensType? lensType}) {
    _ensureNotDisposed();
    return scanner.switchCamera(facing: facing, lensType: lensType);
  }

  /// Turn the torch on or off. Enabling requires the scanner to be live.
  Future<void> setTorch(bool enabled) {
    _ensureNotDisposed();
    return scanner.setTorch(enabled);
  }

  /// Toggle the torch. Enabling requires the scanner to be live.
  Future<void> toggleTorch() {
    _ensureNotDisposed();
    return scanner.toggleTorch();
  }

  /// Set normalized zoom, 0..1.
  Future<void> setZoom(double ratio) {
    _ensureNotDisposed();
    return scanner.setZoom(ratio);
  }

  /// Reset to the widest field of view.
  Future<void> resetZoom() {
    _ensureNotDisposed();
    return scanner.resetZoom();
  }

  /// Restrict decoding to a normalized rectangle, or clear it with null.
  Future<void> updateScanWindow(Rect? window) {
    _ensureNotDisposed();
    return scanner.updateScanWindow(window);
  }

  /// Decode a still image without opening the camera.
  Future<List<ScanResult>> analyzeImage(String path) {
    _ensureNotDisposed();
    return scanner.analyzeImage(path);
  }

  /// Release the camera for an NFC handoff.
  Future<void> beginNfcHandoff() {
    _ensureNotDisposed();
    return scanner.beginNfcHandoff();
  }

  /// Return to the state captured by [beginNfcHandoff].
  Future<void> endNfcHandoff() {
    _ensureNotDisposed();
    return scanner.endNfcHandoff();
  }

  /// Dispose the session and its scanner. Idempotent.
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) {
      return existing;
    }
    _disposed = true;
    _started = false;
    _paused = false;
    final future = scanner.dispose();
    _disposeFuture = future;
    return future;
  }

  Future<void> _tail = Future<void>.value();

  Future<void> _serialize(Future<void> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('ScanSession was disposed');
    }
  }
}
