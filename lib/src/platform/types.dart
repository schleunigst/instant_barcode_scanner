import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

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

/// Semantic value kind decoded from the barcode payload.
enum BarcodeType {
  unknown,
  contactInfo,
  email,
  isbn,
  phone,
  product,
  sms,
  text,
  url,
  wifi,
  geo,
  calendarEvent,
  driverLicense,
}

/// Which way the selected camera faces.
enum CameraFacing { back, front, external }

/// A camera lens class on devices with multiple cameras.
///
/// [any] keeps the platform's default choice for the facing direction.
enum CameraLensType { any, normal, wide, zoom }

/// Geometry of the preview texture: buffer size plus the clockwise rotation
/// and mirroring needed to display it upright.
class PreviewMetrics {
  const PreviewMetrics({
    required this.size,
    required this.rotationDegrees,
    required this.mirrored,
  });

  /// Buffer size in pixels, in the camera's native orientation.
  final Size size;

  /// Clockwise rotation to apply before display (0/90/180/270).
  final int rotationDegrees;

  /// Whether the preview should be mirrored horizontally (front cameras).
  final bool mirrored;

  @override
  bool operator ==(Object other) {
    return other is PreviewMetrics &&
        other.size == size &&
        other.rotationDegrees == rotationDegrees &&
        other.mirrored == mirrored;
  }

  @override
  int get hashCode => Object.hash(size, rotationDegrees, mirrored);

  @override
  String toString() =>
      'PreviewMetrics($size, rotation: $rotationDegrees, '
      'mirrored: $mirrored)';
}

/// The confirmed torch state of the selected camera.
enum TorchState {
  off,
  on,

  /// The selected camera has no controllable torch.
  unavailable,
}

/// One decoder event: every barcode found in a single analyzed frame.
///
/// `InstantBarcodeScanner.scanEvents` emits these raw batches; `scans`
/// flattens them and `scan()` resolves with the first barcode.
class ScanEvent {
  ScanEvent(List<ScanResult> barcodes)
    : barcodes = List<ScanResult>.unmodifiable(barcodes);

  final List<ScanResult> barcodes;

  @override
  String toString() => 'ScanEvent(${barcodes.length} barcodes)';
}

/// How aggressively duplicate detections are suppressed.
enum DetectionSpeed {
  /// Decode every frame, but only report a batch when its set of raw values
  /// differs from the previous reported batch. The same barcode is not
  /// reported again until a different barcode has been reported.
  noDuplicates,

  /// Decode frames at most once per [ScannerConfig.detectionTimeout].
  normal,

  /// Decode and report every frame.
  unrestricted,
}

/// Immutable scanner configuration.
///
/// Applied before the first command. Hardware/format changes require a new
/// controller (dispose is a reset); [InstantBarcodeScanner.switchCamera] is
/// the exception for facing/lens.
class ScannerConfig {
  const ScannerConfig({
    this.facing = CameraFacing.back,
    this.lensType = CameraLensType.any,
    this.formats = const <BarcodeFormat>[],
    this.torchEnabled = false,
    this.initialZoom,
    this.detectionSpeed = DetectionSpeed.normal,
    this.detectionTimeout = const Duration(milliseconds: 250),
    this.invertImage = false,
    this.cameraResolution,
  }) : assert(
         initialZoom == null || (initialZoom >= 0 && initialZoom <= 1),
         'initialZoom is normalized to 0..1',
       );

  /// Back, front or external camera.
  final CameraFacing facing;

  /// Lens class to prefer on the selected facing.
  final CameraLensType lensType;

  /// Symbologies to decode. Empty means everything the platform supports.
  final List<BarcodeFormat> formats;

  /// Turn the torch on when streaming starts.
  final bool torchEnabled;

  /// Initial zoom, normalized 0..1 across the camera's zoom range.
  final double? initialZoom;

  /// Duplicate-suppression policy; fixed for the controller lifetime.
  final DetectionSpeed detectionSpeed;

  /// Minimum time between decoded frames in [DetectionSpeed.normal].
  final Duration detectionTimeout;

  /// Invert frame colors before decoding, for white-on-black symbols.
  /// Android-only; other platforms may ignore it.
  final bool invertImage;

  /// Preferred analysis and preview resolution, or null for the package
  /// default (1280x720 budget). Android-only; other platforms may ignore it
  /// and report it through capabilities.
  final Size? cameraResolution;

  ScannerConfig copyWith({CameraFacing? facing, CameraLensType? lensType}) {
    return ScannerConfig(
      facing: facing ?? this.facing,
      lensType: lensType ?? this.lensType,
      formats: formats,
      torchEnabled: torchEnabled,
      initialZoom: initialZoom,
      detectionSpeed: detectionSpeed,
      detectionTimeout: detectionTimeout,
      invertImage: invertImage,
      cameraResolution: cameraResolution,
    );
  }
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
  const ScanResult({
    required this.format,
    this.rawBytes,
    this.text,
    this.displayValue,
    this.type = BarcodeType.unknown,
    this.boundingBox,
    this.corners,
  });

  final BarcodeFormat format;
  final Uint8List? rawBytes;
  final String? text;

  /// Human-readable form of the payload (for WiFi, contact, URL, and similar
  /// structured values). Null when the decoder does not provide one.
  final String? displayValue;

  /// Semantic kind of the payload.
  final BarcodeType type;

  /// Bounding box in upright analysis-frame coordinates, when reported.
  ///
  /// Preview widgets can map these to view coordinates once size/rotation
  /// information lands; they are not widget coordinates.
  final Rect? boundingBox;

  /// Corner points in upright analysis-frame coordinates, when reported.
  final List<Offset>? corners;

  @override
  String toString() =>
      'ScanResult($format, type: $type, '
      'rawBytes: ${rawBytes?.length ?? 0} bytes, '
      'text: ${text == null ? 'null' : '"$text"'}'
      '${displayValue == null ? '' : ', displayValue: "$displayValue"'}'
      '${boundingBox == null ? '' : ', box: $boundingBox'})';
}

/// The mechanism state, as confirmed by the platform.
///
/// `opening` and `closing` are transient states emitted while the platform
/// converges. The other states are stable targets: `closed`, `open`,
/// `parked`, `live` and `failed`.
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
    this.supportsTorch = false,
    this.supportsZoom = false,
    this.minZoom = 1.0,
    this.maxZoom = 1.0,
  });

  /// The mechanism can hold a configured session whose repeating request is
  /// stopped (`parked`), so a re-scan does not pay device-open and session
  /// configuration again.
  final bool supportsPark;

  /// Releasing from `parked` truthfully closes the camera device, so the
  /// OS-level camera-in-use indicator reflects the actual state.
  ///
  /// When false, `close()` still asks the platform to
  /// release the camera, but `beginNfcHandoff()` refuses
  /// to run because handing the camera to another process cannot be made
  /// safe without a truthful close.
  final bool supportsTrueClose;

  /// The selected camera has a controllable torch.
  final bool supportsTorch;

  /// The selected camera supports zoom control.
  final bool supportsZoom;

  /// Minimum zoom ratio (usually 1.0).
  final double minZoom;

  /// Maximum zoom ratio for the selected camera.
  final double maxZoom;
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
