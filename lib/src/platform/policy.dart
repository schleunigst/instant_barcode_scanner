import 'types.dart';

/// Idle policy: how long the scanner may stay in a warm state without
/// activity before it steps down toward `closed`.
///
/// The policy is pure and lives in Dart on purpose: the native mechanism
/// only executes state transitions it is asked for, and the Dart side owns
/// the decisions about when to make them.
class ScannerPolicy {
  const ScannerPolicy({
    this.parkAfter = const Duration(seconds: 5),
    this.closeAfter = const Duration(minutes: 5),
  });

  /// How long to keep streaming (`live`) after the last delivered read
  /// before stepping down to `parked`.
  final Duration parkAfter;

  /// How long to keep a parked session before closing the camera device.
  final Duration closeAfter;

  /// How long to stay in [current] without activity, or null if [current]
  /// has no idle timeout.
  Duration? idleDelay(ScannerState current) {
    return switch (current) {
      ScannerState.live => parkAfter,
      ScannerState.parked => closeAfter,
      _ => null,
    };
  }

  /// The state to step down to when [current] has been idle, or null if
  /// [current] has no idle step.
  ScannerState? idleTarget(ScannerState current) {
    return switch (current) {
      ScannerState.live => ScannerState.parked,
      ScannerState.parked => ScannerState.closed,
      _ => null,
    };
  }
}
