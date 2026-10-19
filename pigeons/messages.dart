import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/pigeon/messages.g.dart',
    kotlinOut:
        'android/src/main/kotlin/dev/instantbarcode/instant_barcode_scanner/pigeon/Messages.g.kt',
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

/// A single decoded barcode.
///
/// [rawBytes] is the payload exactly as encoded in the symbol, when the
/// decoder can provide it. [text] is a best-effort lossy interpretation.
class PlatformBarcode {
  PlatformBarcode(this.format, this.rawBytes, this.text);

  final PlatformBarcodeFormat format;
  final Uint8List? rawBytes;
  final String? text;
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
  PlatformCapabilities(this.supportsPark, this.supportsTrueClose);

  /// Session config can be kept parked (device open, session configured,
  /// streaming stopped) and driven back to `live` quickly.
  final bool supportsPark;

  /// Release after `parked` truthfully closes the camera device.
  final bool supportsTrueClose;
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
  /// Texture id for the camera preview. The texture is created on first
  /// call and lives until [dispose].
  @async
  int getTextureId();

  @async
  PlatformCapabilities getCapabilities();

  /// Drive the mechanism toward [target].
  @async
  PlatformSnapshot driveTo(PlatformState target);

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
  /// Every confirmed (stable) state change plus unexpected failures.
  void onStateChanged(PlatformSnapshot snapshot);

  /// A batch of barcodes decoded while `live`.
  void onBarcodes(List<PlatformBarcode> barcodes);
}
