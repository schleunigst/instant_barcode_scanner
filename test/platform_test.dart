import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';
import 'package:instant_barcode_scanner/src/pigeon/messages.g.dart' as pigeon;
import 'package:instant_barcode_scanner/src/platform/platform.dart';

/// Tests of the pigeon boundary itself: the mapping the controller never
/// sees, exercised through a mocked binary messenger. This is the automated
/// coverage of the raw-bytes pass-through.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const hostPrefix =
      'dev.flutter.pigeon.instant_barcode_scanner.ScannerHostApi';
  const flutterPrefix =
      'dev.flutter.pigeon.instant_barcode_scanner.ScannerFlutterApi';
  const hostMethods = [
    'configure',
    'getTextureId',
    'getCapabilities',
    'driveTo',
    'switchCamera',
    'setTorch',
    'setZoom',
    'updateScanWindow',
    'analyzeImage',
    'dispose',
  ];

  void mockHost(
    String method,
    Future<Object?> Function(List<Object?> args) handler,
  ) {
    messenger.setMockMessageHandler('$hostPrefix.$method', (data) async {
      final codec = pigeon.ScannerHostApi.pigeonChannelCodec;
      final decoded =
          codec.decodeMessage(data) as List<Object?>? ?? const <Object?>[];
      final result = await handler(decoded);
      return codec.encodeMessage(<Object?>[result]);
    });
  }

  Future<void> deliverFlutterApi(String method, List<Object?> args) async {
    await messenger.handlePlatformMessage(
      '$flutterPrefix.$method',
      pigeon.ScannerFlutterApi.pigeonChannelCodec.encodeMessage(args as Object),
      (_) {},
    );
  }

  tearDown(() {
    for (final method in hostMethods) {
      messenger.setMockMessageHandler('$hostPrefix.$method', null);
    }
  });

  test('driveTo forwards the target and maps the confirmed snapshot', () async {
    Object? requested;
    mockHost('driveTo', (args) async {
      requested = args.first;
      return pigeon.PlatformSnapshot(state: pigeon.PlatformState.parked);
    });

    final platform = MethodChannelInstantBarcodeScannerPlatform();
    final status = await platform.driveTo(ScannerState.parked);

    expect(requested, pigeon.PlatformState.parked);
    expect(status.state, ScannerState.parked);
    expect(status.hasError, isFalse);
  });

  test('an error snapshot maps to errorCode and errorMessage', () async {
    mockHost(
      'driveTo',
      (args) async => pigeon.PlatformSnapshot(
        state: pigeon.PlatformState.closed,
        errorCode: 'open_failed',
        errorMessage: 'camera device failed to open',
      ),
    );

    final platform = MethodChannelInstantBarcodeScannerPlatform();
    final status = await platform.driveTo(ScannerState.parked);

    expect(status.state, ScannerState.closed);
    expect(status.hasError, isTrue);
    expect(status.errorCode, 'open_failed');
    expect(status.errorMessage, 'camera device failed to open');
  });

  test('getTextureId and getCapabilities map', () async {
    mockHost('getTextureId', (args) async => 7);
    mockHost(
      'getCapabilities',
      (args) async => pigeon.PlatformCapabilities(
        supportsPark: false,
        supportsTrueClose: true,
        supportsTorch: false,
        supportsZoom: false,
        minZoom: 1,
        maxZoom: 1,
      ),
    );

    final platform = MethodChannelInstantBarcodeScannerPlatform();

    expect(await platform.getTextureId(), 7);
    final caps = await platform.getCapabilities();
    expect(caps.supportsPark, isFalse);
    expect(caps.supportsTrueClose, isTrue);
  });

  test('state events from the platform reach the registered sink', () async {
    final platform = MethodChannelInstantBarcodeScannerPlatform();
    ScannerStatus? received;
    platform.setEventHandlers(
      onState: (s) => received = s,
      onBarcodes: (_) {},
      onPreviewMetrics: (_) {},
    );

    await deliverFlutterApi('onStateChanged', <Object?>[
      pigeon.PlatformSnapshot(
        state: pigeon.PlatformState.failed,
        errorCode: 'disconnected',
        errorMessage: 'camera device was disconnected',
      ),
    ]);

    expect(received?.state, ScannerState.failed);
    expect(received?.errorCode, 'disconnected');
  });

  test('raw bytes pass through untouched and text stays best-effort', () async {
    final platform = MethodChannelInstantBarcodeScannerPlatform();
    List<ScanResult>? received;
    platform.setEventHandlers(
      onState: (_) {},
      onBarcodes: (results) => received = results,
      onPreviewMetrics: (_) {},
    );

    final raw = Uint8List.fromList([0x00, 0xFF, 0x80, 0x0A]);
    await deliverFlutterApi('onBarcodes', <Object?>[
      <pigeon.PlatformBarcode>[
        pigeon.PlatformBarcode(
          format: pigeon.PlatformBarcodeFormat.aztec,
          rawBytes: raw,
          displayValue: 'https://example.com',
          valueType: pigeon.PlatformBarcodeValueType.url,
          boundingBox: pigeon.PlatformRect(
            left: 10,
            top: 20,
            right: 110,
            bottom: 220,
          ),
          corners: <pigeon.PlatformPoint>[
            pigeon.PlatformPoint(x: 10, y: 20),
            pigeon.PlatformPoint(x: 110, y: 20),
            pigeon.PlatformPoint(x: 110, y: 220),
            pigeon.PlatformPoint(x: 10, y: 220),
          ],
        ),
      ],
    ]);

    expect(received, hasLength(1));
    expect(received!.single.format, BarcodeFormat.aztec);
    expect(received!.single.rawBytes, raw);
    expect(received!.single.text, isNull);
    expect(received!.single.displayValue, 'https://example.com');
    expect(received!.single.type, BarcodeType.url);
    expect(received!.single.boundingBox, const Rect.fromLTRB(10, 20, 110, 220));
    expect(received!.single.corners, const <Offset>[
      Offset(10, 20),
      Offset(110, 20),
      Offset(110, 220),
      Offset(10, 220),
    ]);
  });

  test(
    'scan window maps to a normalized pigeon rect and back to null',
    () async {
      final calls = <Object?>[];
      mockHost('updateScanWindow', (args) async {
        calls.add(args.first);
        return null;
      });

      final platform = MethodChannelInstantBarcodeScannerPlatform();
      await platform.updateScanWindow(const Rect.fromLTRB(0.1, 0.2, 0.9, 0.8));
      await platform.updateScanWindow(null);

      expect(calls, hasLength(2));
      final rect = calls.first! as pigeon.PlatformRect;
      expect(rect.left, 0.1);
      expect(rect.top, 0.2);
      expect(rect.right, 0.9);
      expect(rect.bottom, 0.8);
      expect(calls.last, isNull);
    },
  );

  test('analyzeImage forwards the path and maps the decoded batch', () async {
    String? requested;
    mockHost('analyzeImage', (args) async {
      requested = args.first! as String;
      return <pigeon.PlatformBarcode>[
        pigeon.PlatformBarcode(
          format: pigeon.PlatformBarcodeFormat.qrCode,
          rawBytes: Uint8List.fromList([1, 2, 3]),
          text: 'hello',
          displayValue: 'hello',
          valueType: pigeon.PlatformBarcodeValueType.text,
          boundingBox: null,
          corners: null,
        ),
      ];
    });

    final platform = MethodChannelInstantBarcodeScannerPlatform();
    final results = await platform.analyzeImage('/tmp/label.png');

    expect(requested, '/tmp/label.png');
    expect(results, hasLength(1));
    expect(results.single.format, BarcodeFormat.qrCode);
    expect(results.single.text, 'hello');
    expect(results.single.type, BarcodeType.text);
  });

  test(
    'a controller drives the full stack through the pigeon mapping',
    () async {
      mockHost('getTextureId', (args) async => 3);
      mockHost(
        'getCapabilities',
        (args) async => pigeon.PlatformCapabilities(
          supportsPark: true,
          supportsTrueClose: true,
          supportsTorch: true,
          supportsZoom: true,
          minZoom: 1,
          maxZoom: 8,
        ),
      );
      mockHost('configure', (args) async => null);
      mockHost(
        'driveTo',
        (args) async =>
            pigeon.PlatformSnapshot(state: args.first! as pigeon.PlatformState),
      );
      mockHost('dispose', (args) async => null);

      final platform = MethodChannelInstantBarcodeScannerPlatform();
      final scanner = InstantBarcodeScanner(platform: platform);

      await scanner.warmUp();
      expect(scanner.textureId.value, 3);
      expect(scanner.state, ScannerState.parked);

      await scanner.close();
      expect(scanner.state, ScannerState.closed);

      await scanner.dispose();
    },
  );
}
