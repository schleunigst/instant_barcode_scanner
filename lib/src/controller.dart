import 'dart:async';

import 'package:flutter/foundation.dart';

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
class InstantBarcodeScanner {
  InstantBarcodeScanner({
    InstantBarcodeScannerPlatform? platform,
    this.policy = const ScannerPolicy(),
  }) : _platform = platform ?? InstantBarcodeScannerPlatform.instance {
    _platform.setEventHandlers(
      onState: _handleStatus,
      onBarcodes: _handleBarcodes,
    );
  }

  final InstantBarcodeScannerPlatform _platform;

  /// The idle policy this scanner follows.
  final ScannerPolicy policy;

  final ValueNotifier<ScannerStatus> _status = ValueNotifier(
    const ScannerStatus(state: ScannerState.closed),
  );
  final ValueNotifier<int?> _textureId = ValueNotifier(null);
  final StreamController<ScanResult> _scanController =
      StreamController<ScanResult>.broadcast();

  Future<int>? _textureFuture;
  Future<ScannerCapabilities>? _capabilities;
  Timer? _idleTimer;
  Future<ScanResult>? _activeScan;
  Completer<ScanResult>? _pendingScan;
  bool _handoff = false;
  ScannerState? _handoffResumeTarget;
  Completer<void>? _handoffEnded;
  bool _disposed = false;

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

  /// Every barcode decoded while `live`, in arrival order.
  ///
  /// [scan] delivers the first barcode of its window through its future; the
  /// stream additionally carries barcodes that arrive after [scan] returned
  /// or timed out.
  Stream<ScanResult> get scans => _scanController.stream;

  /// What the platform mechanism can do on this device.
  Future<ScannerCapabilities> get capabilities =>
      _capabilities ??= _platform.getCapabilities();

  /// Prepare for scanning: create the preview texture and drive to `parked`
  /// (device open, session configured, repeating stopped).
  ///
  /// A scan after this pays only the resume cost — no device open, no
  /// session configuration.
  Future<void> warmUp() async {
    _ensureUsable();
    final caps = await capabilities;
    if (!caps.supportsPark) {
      // No warm state below `live` exists on this platform; [scan] opens
      // directly.
      return;
    }
    await _ensureTexture();
    final status = await _platform.driveTo(ScannerState.parked);
    _requireState(status, ScannerState.parked);
    _setStatus(status);
    _touchIdle();
  }

  /// Drive to `live` and wait for the first barcode.
  ///
  /// Concurrent calls share one scan. Times out after [timeout] without a
  /// barcode; the scanner is left live for a subsequent [park] or idle
  /// step-down. If an NFC handoff is active, the scan waits for it to end
  /// first; [timeout] covers the scan window only.
  Future<ScanResult> scan({Duration timeout = const Duration(seconds: 10)}) {
    _ensureUsable();
    final active = _activeScan;
    if (active != null) {
      return active;
    }
    final Future<ScanResult> future = _runScan(timeout);
    return _activeScan = future.whenComplete(() {
      _activeScan = null;
    });
  }

  Future<ScanResult> _runScan(Duration timeout) async {
    await _waitForHandoffEnd();
    await _ensureTexture();
    // The handoff may have started while the texture was resolving.
    await _waitForHandoffEnd();
    final completer = Completer<ScanResult>();
    _pendingScan = completer;
    // dispose()/handoff may fail this completer while this method is
    // suspended on the drive call; keep that error observed so it never
    // becomes an unhandled zone error. The real await below still receives it.
    unawaited(completer.future.then((_) {}, onError: (Object _) {}));
    _touchIdle();
    try {
      final confirmed = await _platform.driveTo(ScannerState.live);
      _requireState(confirmed, ScannerState.live);
      _setStatus(confirmed);
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

  /// Stop streaming, keep the session warm (`parked`). On a platform without
  /// park support this degrades to [close].
  Future<void> park() async {
    _ensureUsable();
    _idleTimer?.cancel();
    _idleTimer = null;
    final caps = await capabilities;
    final target = caps.supportsPark
        ? ScannerState.parked
        : ScannerState.closed;
    final status = await _platform.driveTo(target);
    _requireState(status, target);
    _setStatus(status);
    _touchIdle();
  }

  /// Release the camera device. The OS camera indicator goes out.
  Future<void> close() async {
    _ensureUsable();
    _idleTimer?.cancel();
    _idleTimer = null;
    final status = await _platform.driveTo(ScannerState.closed);
    _requireState(status, ScannerState.closed);
    _setStatus(status);
    _touchIdle();
  }

  /// Release the camera before an NFC handoff and suppress the idle policy
  /// until [endNfcHandoff] is called. A scan in flight fails with a
  /// [StateError]; a scan requested while the handoff is active waits for the
  /// handoff to end.
  ///
  /// Completes only once the platform confirms the device is closed and the
  /// camera HAL reports it available again, so it is safe to open an NFC
  /// reader right after the await.
  Future<void> beginNfcHandoff() async {
    _ensureUsable();
    _handoffResumeTarget = switch (_status.value.state) {
      ScannerState.live => ScannerState.live,
      ScannerState.parked => ScannerState.parked,
      ScannerState.open => ScannerState.open,
      _ => ScannerState.closed,
    };
    _handoffEnded = Completer<void>();
    _handoff = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    final pending = _pendingScan;
    _pendingScan = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        StateError('scan() was interrupted by an NFC handoff'),
      );
    }
    try {
      final status = await _platform.driveTo(ScannerState.closed);
      _requireState(status, ScannerState.closed);
      _setStatus(status);
    } catch (_) {
      _clearHandoff();
      rethrow;
    }
  }

  /// End an NFC handoff: drive back to the state captured when the handoff
  /// began, then let the idle policy take over.
  Future<void> endNfcHandoff() async {
    if (!_handoff) {
      return;
    }
    _handoff = false;
    final target = _handoffResumeTarget;
    _handoffResumeTarget = null;
    if (target == null || target == ScannerState.closed) {
      _completeHandoffWaiters();
      return;
    }
    try {
      final status = await _platform.driveTo(target);
      _requireState(status, target);
      _setStatus(status);
      _touchIdle();
    } finally {
      _completeHandoffWaiters();
    }
  }

  /// Release everything: platform mechanism, texture, listeners.
  ///
  /// A [scan] in flight completes with a [StateError]. The platform call is
  /// a reset — the plugin can serve a new controller afterwards.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _completeHandoffWaiters();
    final pending = _pendingScan;
    _pendingScan = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(
        StateError(
          'InstantBarcodeScanner was disposed while a scan was in flight',
        ),
      );
    }
    try {
      await _platform.dispose();
    } finally {
      _textureId.value = null;
      await _scanController.close();
    }
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

  Future<int> _ensureTexture() async {
    final existing = _textureId.value;
    if (existing != null) {
      return existing;
    }
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
    } finally {
      // Not cached on failure: a transient error must not poison later calls.
      _textureFuture = null;
    }
  }

  void _handleStatus(ScannerStatus status) {
    if (_disposed) {
      return;
    }
    _setStatus(status);
    _touchIdle();
  }

  /// Adopt a confirmed status. Errors surface as `failed`: the platform has
  /// already released the camera when it reports them.
  void _setStatus(ScannerStatus status) {
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
  }

  void _handleBarcodes(List<ScanResult> results) {
    if (results.isEmpty || _disposed) {
      return;
    }
    final pending = _pendingScan;
    if (pending != null && !pending.isCompleted) {
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
  }

  void _touchIdle() {
    _idleTimer?.cancel();
    _idleTimer = null;
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
    final next = policy.idleTarget(state);
    if (next == null) {
      return;
    }
    try {
      await _platform.driveTo(next);
    } catch (_) {
      // Failures surface through the status stream; stepping down is
      // best-effort.
    }
    _touchIdle();
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
