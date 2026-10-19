/// A session-scoped barcode scanner for Flutter.
///
/// The camera stays warm between scans for fast re-scans, releases truthfully
/// when idle, and returns raw barcode bytes alongside best-effort text.
library;

export 'src/controller.dart' show InstantBarcodeScanner;
export 'src/platform/platform.dart' show InstantBarcodeScannerPlatform;
export 'src/platform/policy.dart' show ScannerPolicy;
export 'src/platform/types.dart'
    show
        BarcodeFormat,
        ScanResult,
        ScannerCapabilities,
        ScannerException,
        ScannerState,
        ScannerStatus;
export 'src/view.dart' show InstantBarcodeScannerView;
