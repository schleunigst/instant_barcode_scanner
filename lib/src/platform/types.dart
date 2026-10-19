import 'dart:typed_data';

/// Symbologies the scanner can report.
///
/// The set mirrors what ML Kit's barcode model can decode.
enum BarcodeFormat {
  aztec,
  codabar,
  code39,
  code93,
  code128,
  dataMatrix,
  ean8,
  ean13,
  itf,
  pdf417,
  qrCode,
  upcA,
  upcE,
  unknown,
}

/// A single decoded barcode.
///
/// [rawBytes] is the payload exactly as encoded in the symbol, when the
/// decoder can provide it — never re-encoded or transformed. Backend
/// systems that must see the original bytes (for example Aztec payloads)
/// should consume this field.
///
/// [text] is a best-effort, lossy interpretation of the payload produced by
/// the decoder. It may be null, and it may not round-trip to [rawBytes].
class ScanResult {
  const ScanResult({required this.format, this.rawBytes, this.text});

  final BarcodeFormat format;
  final Uint8List? rawBytes;
  final String? text;

  @override
  String toString() =>
      'ScanResult($format, rawBytes: ${rawBytes?.length ?? 0} bytes, '
      'text: ${text == null ? 'null' : '"$text"'})';
}

/// The mechanism state, as confirmed by the platform.
///
/// v0.1 reports stable states: `closed`, `open`, `parked`, `live` and
/// `failed`. `opening` and `closing` are part of the platform contract but
/// are not emitted yet.
///
/// Only `live` captures frames; only `live` keeps the camera indicator lit.
/// `parked` keeps the camera device open with the session configured but
/// repeating stopped, so the preview holds its last frame (black if none was
/// ever displayed). `closed` releases the camera device — the OS indicator
/// goes out and foreground camera users are notified truthfully. `failed`
/// means the mechanism could not reach a requested target; the camera has
/// already been released at that point.
enum ScannerState { closed, opening, open, parked, live, closing, failed }

/// A confirmed state plus the last failure, if any.
class ScannerStatus {
  const ScannerStatus({required this.state, this.errorCode, this.errorMessage});

  final ScannerState state;

  /// Non-null when the mechanism failed to reach a requested target.
  final String? errorCode;
  final String? errorMessage;

  bool get hasError => errorCode != null;

  @override
  String toString() =>
      'ScannerStatus($state${errorCode == null ? '' : ', $errorCode'})';
}

/// What the platform mechanism can do on this device.
class ScannerCapabilities {
  const ScannerCapabilities({
    required this.supportsPark,
    required this.supportsTrueClose,
  });

  /// The mechanism can hold a configured session whose repeating request is
  /// stopped (`parked`), so a re-scan does not pay device-open and session
  /// configuration again.
  final bool supportsPark;

  /// Releasing from `parked` truthfully closes the camera device, so the
  /// OS-level camera-in-use indicator reflects the actual state.
  final bool supportsTrueClose;
}

/// Thrown when the mechanism could not reach a requested state.
class ScannerException implements Exception {
  const ScannerException(this.status);

  /// The confirmed status the mechanism ended up in instead.
  final ScannerStatus status;

  @override
  String toString() {
    final code = status.errorCode;
    final message = status.errorMessage;
    if (code == null) {
      return 'ScannerException(${status.state})';
    }
    if (message == null) {
      return 'ScannerException(${status.state}, $code)';
    }
    return 'ScannerException(${status.state}, $code: $message)';
  }
}
