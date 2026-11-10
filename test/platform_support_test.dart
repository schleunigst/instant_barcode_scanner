import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

import 'fake_platform.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'a channel error off Android is reported as unsupported_platform',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final platform = FakePlatform()
        ..capabilitiesHandler = () => Future<ScannerCapabilities>.error(
          PlatformException(code: 'channel-error'),
        );
      final scanner = InstantBarcodeScanner(platform: platform);

      await expectLater(
        scanner.warmUp(),
        throwsA(
          isA<ScannerException>().having(
            (error) => error.status.errorCode,
            'errorCode',
            'unsupported_platform',
          ),
        ),
      );
    },
  );

  test('a channel error on Android stays a transport error', () async {
    final platform = FakePlatform()
      ..capabilitiesHandler = () => Future<ScannerCapabilities>.error(
        PlatformException(code: 'channel-error'),
      );
    final scanner = InstantBarcodeScanner(platform: platform);

    await expectLater(
      scanner.warmUp(),
      throwsA(
        isA<ScannerException>().having(
          (error) => error.status.errorCode,
          'errorCode',
          'channel-error',
        ),
      ),
    );
  });
}
