import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform/platform.dart';
import 'platform/policy.dart';
import 'platform/types.dart';

/// A session-scoped barcode scanner.
///
/// The scanner keeps a warm camera session between reads instead of paying
/// the full open/configure cost on every scan, and it releases truthfully
/// when the app is done: when [status] is `closed`, the camera device is
/// closed, not just "stopped feeding".
///
/// Typical use:
///
/// ```dart
/// final scanner = InstantBarcodeScanner();
/// await scanner.warmUp();          // walk to the tab / screen
/// final result = await scanner.scan();
/// // ... handle result ...
/// await scanner.dispose();         // leave the screen
/// ```
///
/// The idle policy ([ScannerPolicy]) steps the scanner down on its own:
/// `live` → `parked` after [ScannerPolicy.parkAfter] without a delivered
/// read, and `parked` → `closed` after [ScannerPolicy.closeAfter].
///
/// When the app is backgrounded the platform closes the camera; the scanner
/// reports `closed` and does not reopen on its own — call [warmUp] (or
/// [scan]) when the app comes back.
///
/// Only one live instance per app is supported: the platform boundary is a
/// per-engine singleton and two controllers would steal each other's events.
class InstantBarcodeScanner {
  InstantBarcodeScanner({
    ScannerConfig config = const ScannerConfig(),
    InstantBarcodeScannerPlatform? platform,
    this.policy = const ScannerPolicy(),
  }) : _config = config,
       _zoomScale = ValueNotifier(config.initialZoom ?? 0),
       _platform = platform ?? InstantBarcodeScannerPlatform.instance {
    _platform.setEventHandlers(
      onState: _handleStatus,
      onBarcodes: _handleBarcodes,
    );
  }

  final InstantBarcodeScannerPlatform _platform;

  /// The active configuration. [switchCamera] updates facing/lens; every
  /// other field is fixed for the controller lifetime.
  ScannerConfig _config;

  /// The idle policy this scanner follows.
  final ScannerPolicy policy;

  final ValueNotifier<ScannerStatus> _status = ValueNotifier(
    const ScannerStatus(state: ScannerState.closed),
  );
  final ValueNotifier<int?> _textureId = ValueNotifier(null);
  final ValueNotifier<TorchState> _torchState = ValueNotifier(TorchState.off);
  final ValueNotifier<double> _zoomScale;
  final StreamController<ScanResult> _scanController =
      StreamController<ScanResult>.broadcast();
  final StreamController<ScanEvent> _eventController =
      StreamController<ScanEvent>.broadcast();

  Future<int>? _textureFuture;
  Future<ScannerCapabilities>? _capabilities;
  Future<void>? _configureFuture;
  bool? _parkSupported;
  bool? _supportsTorch;
  bool _torchAppliedFromConfig = false;
  Timer? _idleTimer;
  Future<ScanResult>? _activeScan;
  Completer<ScanResult>? _pendingScan;
  bool _handoff = false;
  ScannerState? _handoffResumeTarget;
  Completer<void>? _handoffEnded;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  /// Drives are serialized in call order: the queue makes a late `warmUp`
  /// unable to park the camera under a scan that started after it, and keeps
  /// dispose behind the commands it must not tear down.
  Future<void> _commandTail = Future<void>.value();

  /// The confirmed state of the mechanism, with the last failure if any.
  ///
  /// A mid-session failure (disconnect, configure error) surfaces as
  /// [ScannerState.failed] with [ScannerStatus.errorCode] set; the platform
  /// has already closed the camera at that point. Call [warmUp] or [scan]
  /// to retry.
  ValueListenable<ScannerStatus> get status => _status;

  /// Convenience for `status.value.state`.
  ScannerState get state => _status.value.state;

  /// Texture id of the camera preview; null until the texture exists.
  ValueListenable<int?> get textureId => _textureId;

  /// The configuration this scanner runs with (facing/lens reflect
  /// [switchCamera]).
  ScannerConfig get config => _config;

  /// The selected camera's torch state. `unavailable` when the hardware has
  /// no flashlight; `off` again whenever streaming stops.
  ValueListenable<TorchState> get torchState => _torchState;

  /// Zoom, normalized 0..1 across the selected camera's range.
  ValueListenable<double> get zoomScale => _zoomScale;

  /// Every barcode decoded while `live`, in arrival order.
  ///
  /// [scan] delivers the first barcode of its window through its future; the
  /// stream additionally carries barcodes that arrive after [scan] returned
  /// or timed out. The stream is broadcast and does not replay: subscribe
  /// before calling [scan] if the first read matters.
  Stream<ScanResult> get scans => _scanController.stream;

  /// Raw decoder batches: one [ScanEvent] per analyzed frame that decoded
  /// anything, carrying every barcode in that frame.
  ///
  /// Broadcast, no replay. [scans] is the flattened convenience view.
  Stream<ScanEvent> get scanEvents => _eventController.stream;

  /// What the platform mechanism can do on this device.
  ///
  /// Failures are not cached: a transient channel error does not poison
  /// later calls.
  Future<ScannerCapabilities> get capabilities {
    final cached = _capabilities;
    if (cached != null) {
      return cached;
    }
    final future = _loadCapabilities();
    _capabilities = future;
    future.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_capabilities, future)) {
          _capabilities = null;
        }
      },
    );
    return future;
  }

  Future<ScannerCapabilities> _loadCapabilities() async {
    await _ensureConfigured();
    try {
      final caps = await _platform.getCapabilities();
      _parkSupported = caps.supportsPark;
      _supportsTorch = caps.supportsTorch;
      if (!caps.supportsTorch) {
        _torchState.value = TorchState.unavailable;
      } else if (_torchState.value != TorchState.on) {
        _torchState.value = TorchState.off;
      }
      if (!caps.supportsZoom) {
        _zoomScale.value = 0;
      }
      return caps;
    } on PlatformException catch (e) {
      throw _platformFailure(e);
    }
  }

  /// Apply the fixed controller configuration exactly once, before any call
  /// that needs camera hardware. Failures are not cached.
  Future<void> _ensureConfigured() {
    final existing = _configureFuture;
    if (existing != null) {
      return existing;
    }
    final future = _platform.configure(_config).catchError((Object error) {
      if (error is PlatformException) {
        throw _platformFailure(error);
      }
      throw error;
    });
    _configureFuture = future;
    future.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_configureFuture, future)) {
          _configureFuture = null;
        }
      },
    );
    return future;
  }

  ScannerException _platformFailure(PlatformException e) {
    return ScannerException(
      ScannerStatus(
        state: state,
        errorCode: e.code.isEmpty ? 'platform_error' : e.code,
        errorMessage: e.message,
      ),
    );
  }

  /// Prepare for scanning: create the preview texture and drive to `parked`
  /// (device open, session configured, repeating stopped).
  ///
  /// A scan after this pays only the resume cost — no device open, no
  /// session configuration. On a platform without park support this drives
  /// to `open` instead.
  ///
  /// Does nothing while an NFC handoff is active: the camera belongs to the
  /// host until [endNfcHandoff].
  Future<void> warmUp() async {
    final scanActiveAtCall = _activeScan != null;
    _ensureUsable();
    await _enqueue(() async {
      _ensureUsable();
      if (_handoff) {
        return;
      }
      final caps = await capabilities;
      _ensureUsable();
      if (_handoff) {
        return;
      }
      await _ensureTexture();
      _ensureUsable();
      if (_handoff || scanActiveAtCall) {
        // The queue runs this action before any scan requested afterwards, so
        // parking here is safe — unless a scan was already running when
        // warmUp was called. Then parking would pull the camera out from
        // under it (and a late warmUp must never do that).
        return;
      }
      final target = caps.supportsPark
          ? ScannerState.parked
          : ScannerState.open;
      await _confirm(target);
    });
  }

  /// Drive to `live` and wait for the first barcode.
  ///
  /// Concurrent calls share one scan. Times out after [timeout] without a
  /// barcode; the scanner is left live for a subsequent [park] or idle
  /// step-down. If an NFC handoff is active, the scan waits for it to end
  /// first; [timeout] covers the scan window only.
  ///
  /// [close] or [park] while a scan is in flight cancels it with a
  /// [StateError]; a camera failure while `live` fails it with a
  /// [ScannerException].
  Future<ScanResult> scan({Duration timeout = const Duration(seconds: 10)}) {
    _ensureUsable();
    final active = _activeScan;
    if (active != null) {
      return active;
    }
    final Future<ScanResult> future = _runScan(timeout);
    late final Future<ScanResult> tracked;
    tracked = future.whenComplete(() {
      // Only clear our own slot: a close/park/handoff may have cancelled
      // this scan and a newer scan may already own it.
      if (identical(_activeScan, tracked)) {
        _activeScan = null;
      }
    });
    return _activeScan = tracked;
  }

  Future<ScanResult> _runScan(Duration timeout) async {
    await _waitForHandoffEnd();
    await _ensureTexture();
    // The handoff may have started while the texture was resolving.
    await _waitForHandoffEnd();
    final completer = Completer<ScanResult>();
    _pendingScan = completer;
    // dispose()/handoff/close may fail this completer while this method is
    // suspended; keep that error observed so it never becomes an unhandled
    // zone error. The real await below still receives it.
    unawaited(completer.future.then((_) {}, onError: (Object _) {}));
    _touchIdle();
    try {
      final confirmed = await _enqueue<ScannerStatus?>(() async {
        _ensureUsable();
        if (!identical(_pendingScan, completer)) {
          // A close/park/handoff cancelled this scan before the drive ran.
          // The completer already carries the cancellation error.
          return null;
        }
        return _drive(ScannerState.live);
      });
      if (confirmed == null) {
        return await completer.future;
      }
      _ensureUsable();
      _adopt(confirmed);
      _requireState(confirmed, ScannerState.live);
      _touchIdle();
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          throw TimeoutException('no barcode within $timeout', timeout);
        },
      );
    } finally {
      if (identical(_pendingScan, completer)) {
        _pendingScan = null;
      }
    }
  }

  /// Switch to the other facing camera (or to an explicit facing/lens),
  /// preserving the confirmed state: live stays live, parked stays parked,
  /// closed stays closed.
  ///
  /// Hardware changes are camera-scoped: capabilities are re-read on next
  /// use and torch/zoom state resets. Formats stay fixed for the controller
  /// lifetime.
  Future<void> switchCamera({
    CameraFacing? facing,
    CameraLensType? lensType,
  }) async {
    _ensureUsable();
    await _enqueue(() async {
      _ensureUsable();
      final before = _status.value.state;
      final nextFacing =
          facing ??
          (_config.facing == CameraFacing.back
              ? CameraFacing.front
              : CameraFacing.back);
      final nextLens = lensType ?? _config.lensType;
      if (nextFacing == _config.facing && nextLens == _config.lensType) {
        return;
      }
      _cancelIdle();
      await _ensureConfigured();
      ScannerStatus status;
      try {
        status = await _platform.switchCamera(nextFacing, nextLens);
      } on PlatformException catch (e) {
        throw _platformFailure(e);
      }
      _adopt(status);
      final expected = before == ScannerState.failed
          ? ScannerState.closed
          : before;
      _requireState(status, expected);
      _config = _config.copyWith(facing: nextFacing, lensType: nextLens);
      _capabilities = null;
      _supportsTorch = null;
      _torchState.value = TorchState.off;
      _zoomScale.value = 0;
      _touchIdle();
    });
  }

  /// Turn the torch on or off. Requires `live`; the torch always goes off
  /// when streaming stops.
  Future<void> setTorch(bool enabled) async {
    _ensureUsable();
    if (enabled && state != ScannerState.live) {
      throw StateError('the torch can only be enabled while live');
    }
    await _ensureConfigured();
    final caps = await capabilities;
    if (!caps.supportsTorch) {
      throw ScannerException(
        ScannerStatus(
          state: state,
          errorCode: 'unsupported',
          errorMessage: 'the selected camera has no controllable torch',
        ),
      );
    }
    try {
      await _platform.setTorch(enabled);
    } on PlatformException catch (e) {
      throw _platformFailure(e);
    }
    _torchState.value = enabled ? TorchState.on : TorchState.off;
  }

  /// Toggle the torch. No-op when the camera has no flash.
  Future<void> toggleTorch() => setTorch(_torchState.value != TorchState.on);

  /// Set zoom, normalized 0..1 across the selected camera's range.
  Future<void> setZoom(double scale) async {
    _ensureUsable();
    if (!(scale >= 0 && scale <= 1)) {
      throw RangeError.range(scale, 0, 1, 'scale');
    }
    await _ensureConfigured();
    final caps = await capabilities;
    if (!caps.supportsZoom) {
      throw ScannerException(
        ScannerStatus(
          state: state,
          errorCode: 'unsupported',
          errorMessage: 'the selected camera does not support zoom',
        ),
      );
    }
    final ratio = caps.minZoom + scale * (caps.maxZoom - caps.minZoom);
    try {
      await _platform.setZoom(ratio);
    } on PlatformException catch (e) {
      throw _platformFailure(e);
    }
    _zoomScale.value = scale;
  }

  /// Return to the widest field of view.
  Future<void> resetZoom() => setZoom(0);

  /// Decode barcodes from an image file at [path].
  ///
  /// Works without a camera session (no permission needed) and does not
  /// change scanner state. Applies the configured barcode formats and
  /// [updateScanWindow] is ignored for still images.
  Future<List<ScanResult>> analyzeImage(String path) async {
    _ensureUsable();
    await _ensureConfigured();
    try {
      return await _platform.analyzeImage(path);
    } on PlatformException catch (e) {
      throw ScannerException(
        ScannerStatus(
          state: status.value.state,
          errorCode: e.code,
          errorMessage: e.message,
        ),
      );
    }
  }

  /// Restrict decoding to [window], normalized to 0..1 in upright
  /// analysis-frame coordinates, or clear it with null.
  ///
  /// A barcode is reported only when all of its detected corners fall inside
  /// the window. Safe before [warmUp]; the restriction survives park/close and
  /// camera switches for the controller lifetime.
  Future<void> updateScanWindow(Rect? window) async {
    _ensureUsable();
    if (window != null &&
        (!window.isFinite ||
            window.left < 0 ||
            window.top < 0 ||
            window.right > 1 ||
            window.bottom > 1 ||
            window.left >= window.right ||
            window.top >= window.bottom)) {
      throw ArgumentError.value(
        window,
        'window',
        'must be normalized to 0..1 with left < right and top < bottom',
      );
    }
    await _enqueue(() async {
      _ensureUsable();
      await _ensureConfigured();
      try {
        await _platform.updateScanWindow(window);
      } on PlatformException catch (e) {
        throw _platformFailure(e);
      }
    });
  }

  /// Stop streaming, keep the session warm (`parked`). On a platform without
  /// park support this degrades to [close].
  ///
  /// Cancels an in-flight [scan]. Does nothing while an NFC handoff is
  /// active.
  Future<void> park() async {
    _ensureUsable();
    await _enqueue(() async {
      _ensureUsable();
      if (_handoff) {
        return;
      }
      _cancelIdle();
      _failPendingScan(StateError('scan() was cancelled by park()'));
      _activeScan = null;
      final caps = await capabilities;
      _ensureUsable();
      final target = caps.supportsPark
          ? ScannerState.parked
          : ScannerState.closed;
      await _confirm(target);
    });
  }

  /// Release the camera device. The OS camera indicator goes out.
  ///
  /// Cancels an in-flight [scan].
  Future<void> close() async {
    _ensureUsable();
    await _enqueue(() async {
      _ensureUsable();
      _cancelIdle();
      _failPendingScan(StateError('scan() was cancelled by close()'));
      _activeScan = null;
      await _confirm(ScannerState.closed);
    });
  }

  /// Release the camera before an NFC handoff and suppress the idle policy
  /// until [endNfcHandoff] is called. A scan in flight fails with a
  /// [StateError]; a scan requested while the handoff is active waits for the
  /// handoff to end.
  ///
  /// Completes only once the platform confirms the device is closed and the
  /// camera HAL reports it available again, so it is safe to open an NFC
  /// reader right after the await.
  ///
  /// Reentrant: calling it while a handoff is already active returns once
  /// that handoff is confirmed, without changing its resume target.
  Future<void> beginNfcHandoff() async {
    _ensureUsable();
    if (_handoff) {
      await (_handoffEnded?.future ?? Future<void>.value());
      return;
    }
    _handoffResumeTarget = switch (_status.value.state) {
      ScannerState.live => ScannerState.live,
      ScannerState.parked => ScannerState.parked,
      ScannerState.open => ScannerState.open,
      _ => ScannerState.closed,
    };
    _handoffEnded = Completer<void>();
    _handoff = true;
    _cancelIdle();
    _failPendingScan(StateError('scan() was interrupted by an NFC handoff'));
    _activeScan = null;
    final done = _enqueue(() async {
      _ensureUsable();
      await _confirm(ScannerState.closed);
    });
    // On failure the handoff did not happen: put the scanner back on the idle
    // policy instead of leaving it live forever.
    return done.catchError((Object error, StackTrace stack) {
      if (!_disposed) {
        _clearHandoff();
        _touchIdle();
      }
      Error.throwWithStackTrace(error, stack);
    });
  }

  /// End an NFC handoff: drive back to the state captured when the handoff
  /// began, then let the idle policy take over.
  Future<void> endNfcHandoff() {
    if (_disposed || !_handoff) {
      return Future<void>.value();
    }
    _handoff = false;
    final target = _resumeTarget(_handoffResumeTarget);
    _handoffResumeTarget = null;
    if (target == null || target == ScannerState.closed) {
      _completeHandoffWaiters();
      _touchIdle();
      return Future<void>.value();
    }
    final done = _enqueue(() async {
      if (_disposed) {
        return;
      }
      await _confirm(target);
    });
    return done.whenComplete(() {
      _completeHandoffWaiters();
      _touchIdle();
    });
  }

  /// Release everything: platform mechanism, texture, listeners.
  ///
  /// A [scan] in flight completes with a [StateError]. The platform call is
  /// a reset — the plugin can serve a new controller afterwards. Repeated
  /// calls return the same future, so awaiting [dispose] always guarantees
  /// teardown even when several callers race.
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) {
      return existing;
    }
    _disposed = true;
    _cancelIdle();
    _completeHandoffWaiters();
    _handoff = false;
    _handoffResumeTarget = null;
    _failPendingScan(
      StateError(
        'InstantBarcodeScanner was disposed while a scan was in flight',
      ),
    );
    _activeScan = null;
    final future = _enqueue(() async {
      try {
        await _platform.dispose();
      } finally {
        _textureId.value = null;
      }
    });
    _disposeFuture = future;
    unawaited(_scanController.close());
    unawaited(_eventController.close());
    return future;
  }

  /// Wait until no handoff is active. [dispose] wakes waiters too, so a scan
  /// queued behind a handoff fails rather than hangs.
  Future<void> _waitForHandoffEnd() async {
    while (_handoff && !_disposed) {
      final ended = _handoffEnded ??= Completer<void>();
      await ended.future;
    }
    _ensureUsable();
  }

  void _clearHandoff() {
    _handoff = false;
    _handoffResumeTarget = null;
    _completeHandoffWaiters();
  }

  void _completeHandoffWaiters() {
    final ended = _handoffEnded;
    _handoffEnded = null;
    if (ended != null && !ended.isCompleted) {
      ended.complete();
    }
  }

  ScannerState? _resumeTarget(ScannerState? target) {
    if (target == ScannerState.parked && _parkSupported == false) {
      return ScannerState.open;
    }
    return target;
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _commandTail.then((_) => action());
    _commandTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<ScannerStatus> _drive(ScannerState target) async {
    await _ensureConfigured();
    try {
      return await _platform.driveTo(target);
    } on PlatformException catch (e) {
      return ScannerStatus(
        state: ScannerState.failed,
        errorCode: e.code.isEmpty ? 'platform_error' : e.code,
        errorMessage: e.message,
      );
    }
  }

  /// Drive to [target], adopt the confirmed snapshot, and throw a
  /// [ScannerException] if the mechanism did not converge.
  Future<void> _confirm(ScannerState target) async {
    final status = await _drive(target);
    _adopt(status);
    _requireState(status, target);
    _touchIdle();
  }

  Future<int> _ensureTexture() async {
    final existing = _textureId.value;
    if (existing != null) {
      return existing;
    }
    await _ensureConfigured();
    final pending = _textureFuture;
    if (pending != null) {
      return pending;
    }
    final future = _platform.getTextureId();
    _textureFuture = future;
    try {
      final id = await future;
      if (!_disposed) {
        _textureId.value = id;
      }
      return id;
    } on PlatformException catch (e) {
      throw ScannerException(
        ScannerStatus(
          state: state,
          errorCode: 'platform_error',
          errorMessage: e.message,
        ),
      );
    } finally {
      // Not cached on failure: a transient error must not poison later calls.
      _textureFuture = null;
    }
  }

  void _handleStatus(ScannerStatus status) {
    if (_disposed) {
      return;
    }
    _adopt(status);
    final pending = _pendingScan;
    if (pending != null && !pending.isCompleted) {
      if (status.hasError) {
        _failPendingScan(ScannerException(status));
        _activeScan = null;
      } else if (status.state == ScannerState.closed && !_handoff) {
        // The camera went away underneath the scan (backgrounded activity,
        // external close). Report it now instead of waiting for the timeout.
        _failPendingScan(
          StateError('the camera was closed while a scan was in flight'),
        );
        _activeScan = null;
      }
    }
    _touchIdle();
  }

  /// Adopt a confirmed status. Errors surface as `failed`: the platform has
  /// already released the camera when it reports them.
  void _adopt(ScannerStatus status) {
    if (_disposed) {
      return;
    }
    if (status.hasError) {
      _status.value = ScannerStatus(
        state: ScannerState.failed,
        errorCode: status.errorCode,
        errorMessage: status.errorMessage,
      );
    } else {
      _status.value = status;
    }
    if (status.state == ScannerState.live) {
      if (_config.torchEnabled && !_torchAppliedFromConfig) {
        _torchAppliedFromConfig = true;
        if (_supportsTorch != false) {
          _torchState.value = TorchState.on;
        }
      }
    } else if (_torchState.value == TorchState.on) {
      // The torch is a live-only control; leaving live turns it off.
      _torchState.value = _supportsTorch == false
          ? TorchState.unavailable
          : TorchState.off;
    }
  }

  void _failPendingScan(Object error) {
    final pending = _pendingScan;
    _pendingScan = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error);
    }
  }

  void _handleBarcodes(List<ScanResult> results) {
    if (results.isEmpty || _disposed || _handoff) {
      return;
    }
    final pending = _pendingScan;
    if (pending != null && !pending.isCompleted && state == ScannerState.live) {
      pending.complete(results.first);
      // A delivered read ends a burst: this is the only event that resets the
      // idle countdown. Decoded frames alone must not, or a barcode left in
      // view would keep the camera lit forever.
      _touchIdle();
    }
    if (!_scanController.isClosed) {
      for (final result in results) {
        _scanController.add(result);
      }
    }
    if (!_eventController.isClosed) {
      _eventController.add(ScanEvent(results));
    }
  }

  void _cancelIdle() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _touchIdle() {
    _cancelIdle();
    if (_disposed || _handoff) {
      return;
    }
    final delay = policy.idleDelay(state);
    if (delay == null) {
      return;
    }
    _idleTimer = Timer(delay, () {
      unawaited(_stepDown());
    });
  }

  Future<void> _stepDown() async {
    if (_disposed || _handoff) {
      return;
    }
    if (_activeScan != null) {
      _touchIdle();
      return;
    }
    var next = policy.idleTarget(state);
    if (next == ScannerState.parked && _parkSupported == false) {
      next = ScannerState.closed;
    }
    if (next == null) {
      return;
    }
    try {
      await _confirm(next);
    } catch (_) {
      // Failures surface through the status stream; stepping down is
      // best-effort.
      _touchIdle();
    }
  }

  void _requireState(ScannerStatus status, ScannerState target) {
    if (status.state != target || status.hasError) {
      throw ScannerException(status);
    }
  }

  void _ensureUsable() {
    if (_disposed) {
      throw StateError('InstantBarcodeScanner has been disposed');
    }
  }
}
