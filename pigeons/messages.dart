import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/pigeon/messages.g.dart',
    kotlinOut: 'android/src/main/kotlin/dev/instantbarcode/instant_barcode_scanner/pigeon/Messages.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'dev.instantbarcode.instant_barcode_scanner.pigeon',
    ),
    dartPackageName: 'instant_barcode_scanner',
  ),
)
/// The mechanism state, as confirmed by the platform.
///
/// `opening`, `closing` are transient; all others are stable states that a
/// `driveTo` call can target and that can be reported to the app.
enum PlatformState { closed, opening, open, parked, live, closing, failed }

/// Barcode symbologies reported by the decoder.
enum PlatformBarcodeFormat {
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

/// Which way the selected camera faces.
enum PlatformCameraFacing { back, front, external }

/// A camera lens class on devices with multiple back/front cameras.
enum PlatformCameraLensType { any, normal, wide, zoom }

/// Semantic value kind decoded from the barcode.
enum PlatformBarcodeValueType {
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

/// A point in analysis-frame coordinates (upright, origin top-left).
class PlatformPoint {
  PlatformPoint(this.x, this.y);

  final double x;
  final double y;
}

/// A rectangle in analysis-frame coordinates (upright, origin top-left).
class PlatformRect {
  PlatformRect(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;
}

/// How aggressively duplicate detections are suppressed.
enum PlatformDetectionSpeed { noDuplicates, normal, unrestricted }

/// Immutable scanner configuration applied before the first command.
///
/// Hard format lists are fixed for the controller lifetime: changing them is
/// a reconfiguration (dispose + new controller). [facing] and [lensType] may
/// also change through `switchCamera`.
class PlatformScannerConfig {
  PlatformScannerConfig(
    this.facing,
    this.lensType,
    this.formats,
    this.torchEnabled,
    this.initialZoom,
    this.targetWidth,
    this.targetHeight,
    this.detectionSpeed,
    this.detectionTimeoutMs,
    this.invertImage,
  );

  final PlatformCameraFacing facing;
  final PlatformCameraLensType lensType;

  /// Empty means every format the decoder supports.
  final List<PlatformBarcodeFormat> formats;

  /// Whether the torch should come on when streaming starts.
  final bool torchEnabled;

  /// Initial zoom, normalized 0..1 across the camera's zoom range.
  final double? initialZoom;

  /// Preferred analysis/preview width, or null for the package default.
  final int? targetWidth;

  /// Preferred analysis/preview height, or null for the package default.
  final int? targetHeight;

  /// Duplicate-suppression policy for decoded frames.
  final PlatformDetectionSpeed detectionSpeed;

  /// Minimum time between analyzed frames in `normal` mode.
  final int detectionTimeoutMs;

  /// Invert frame colors before decoding (white-on-black symbols).
  final bool invertImage;
}

/// A single decoded barcode.
///
/// [rawBytes] is the payload exactly as encoded in the symbol, when the
/// decoder can provide it. [text] is a best-effort lossy interpretation.
/// [displayValue] is the human-readable form (for WiFi/contact/URL values),
/// [valueType] is the semantic kind, and geometry is in upright analysis-frame
/// coordinates.
class PlatformBarcode {
  PlatformBarcode(
    this.format,
    this.rawBytes,
    this.text,
    this.displayValue,
    this.valueType,
    this.boundingBox,
    this.corners,
  );

  final PlatformBarcodeFormat format;
  final Uint8List? rawBytes;
  final String? text;
  final String? displayValue;
  final PlatformBarcodeValueType valueType;
  final PlatformRect? boundingBox;
  final List<PlatformPoint>? corners;
}

/// A confirmed mechanism state.
class PlatformSnapshot {
  PlatformSnapshot(this.state, this.errorCode, this.errorMessage);

  final PlatformState state;
  final String? errorCode;
  final String? errorMessage;
}

/// What the platform mechanism can do on this device.
class PlatformCapabilities {
  PlatformCapabilities(
    this.supportsPark,
    this.supportsTrueClose,
    this.supportsTorch,
    this.supportsZoom,
    this.minZoom,
    this.maxZoom,
  );

  /// Session config can be kept parked (device open, session configured,
  /// streaming stopped) and driven back to `live` quickly.
  final bool supportsPark;

  /// Release after `parked` truthfully closes the camera device.
  final bool supportsTrueClose;

  /// The selected camera has a controllable torch.
  final bool supportsTorch;

  /// The selected camera supports optical/digital zoom control.
  final bool supportsZoom;

  /// Minimum zoom ratio (usually 1.0).
  final double minZoom;

  /// Maximum zoom ratio for the selected camera.
  final double maxZoom;
}

/// Geometry of the preview texture, in buffer pixels plus the clockwise
/// rotation and mirroring needed to display it upright.
class PlatformPreviewMetrics {
  PlatformPreviewMetrics(
    this.width,
    this.height,
    this.rotationDegrees,
    this.mirrored,
  );

  final int width;
  final int height;

  /// Clockwise rotation to apply before display (0/90/180/270).
  final int rotationDegrees;

  /// Whether the preview should be mirrored horizontally (front cameras).
  final bool mirrored;
}

/// Commands from Dart to the platform.
///
/// All state transitions go through [driveTo]; it completes when the
/// mechanism has reached a stable state and that state is emitted on
/// [ScannerFlutterApi.onStateChanged]. If a newer command supersedes a
/// pending one, the pending future completes with the latest confirmed
/// snapshot instead of the requested target; callers decide whether to
/// retry.
@HostApi()
abstract class ScannerHostApi {
  /// Apply the controller configuration. Called once before any other call
  /// that needs camera hardware; the configuration is fixed for the
  /// controller lifetime (except facing/lens through [switchCamera]).
  @async
  void configure(PlatformScannerConfig config);

  /// Texture id for the camera preview. The texture is created on first
  /// call and lives until [dispose].
  @async
  int getTextureId();

  @async
  PlatformCapabilities getCapabilities();

  /// Drive the mechanism toward [target].
  @async
  PlatformSnapshot driveTo(PlatformState target);

  /// Switch camera while preserving the current confirmed state (closed
  /// stays closed, parked stays parked, live stays live).
  @async
  PlatformSnapshot switchCamera(
    PlatformCameraFacing facing,
    PlatformCameraLensType lensType,
  );

  /// Turn the torch on/off while live. Fails when the camera has no flash.
  @async
  void setTorch(bool enabled);

  /// Set the zoom ratio (device units, clamped by the platform).
  @async
  void setZoom(double ratio);

  /// Restrict decoding to a rectangle normalized to 0..1 in upright
  /// analysis-frame coordinates. Null clears the restriction.
  @async
  void updateScanWindow(PlatformRect? window);

  /// Decode barcodes from an image file on disk; no camera or permission
  /// required. Applies the configured barcode formats.
  @async
  List<PlatformBarcode> analyzeImage(String path);

  /// Reset the plugin: shut the mechanism down, release all resources and
  /// return to the initial state. A new session can follow this call; the
  /// texture is re-created on the next [getTextureId].
  ///
  /// `@async` so Dart only resumes after the camera is truthfully closed.
  @async
  void dispose();
}

/// Events from the platform to Dart.
@FlutterApi()
abstract class ScannerFlutterApi {
  /// Every confirmed state change, including transient `opening`/`closing`
  /// snapshots and unexpected failures.
  void onStateChanged(PlatformSnapshot snapshot);

  /// A batch of barcodes decoded while `live`.
  void onBarcodes(List<PlatformBarcode> barcodes);

  /// The preview texture's buffer size and display transform changed.
  void onPreviewMetrics(PlatformPreviewMetrics metrics);
}
