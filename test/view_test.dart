import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:instant_barcode_scanner/instant_barcode_scanner.dart';

import 'fake_platform.dart';

Widget _host(Widget child) {
  return Directionality(textDirection: TextDirection.ltr, child: child);
}

void main() {
  testWidgets('placeholder and overlay render before the first frame', (
    tester,
  ) async {
    final scanner = InstantBarcodeScanner(platform: FakePlatform());
    await tester.pumpWidget(
      _host(
        InstantBarcodeScannerView(
          controller: scanner,
          placeholderBuilder: (_) => const SizedBox(key: Key('placeholder')),
          overlayBuilder: (_) => const SizedBox(key: Key('overlay')),
        ),
      ),
    );

    expect(find.byKey(const Key('placeholder')), findsOneWidget);
    expect(find.byKey(const Key('overlay')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await scanner.dispose();
  });

  testWidgets('metrics drive rotation, mirroring and fit', (tester) async {
    final platform = FakePlatform();
    final scanner = InstantBarcodeScanner(platform: platform);
    await scanner.warmUp();
    expect(scanner.textureId.value, 42);

    platform.emitPreviewMetrics(
      const PreviewMetrics(
        size: Size(1280, 720),
        rotationDegrees: 90,
        mirrored: true,
      ),
    );

    await tester.pumpWidget(
      _host(
        InstantBarcodeScannerView(controller: scanner, fit: BoxFit.contain),
      ),
    );

    final fitted = tester.widget<FittedBox>(find.byType(FittedBox));
    expect(fitted.fit, BoxFit.contain);

    final rotated = tester.widget<RotatedBox>(find.byType(RotatedBox));
    expect(rotated.quarterTurns, 1);

    final transforms = tester
        .widgetList<Transform>(find.byType(Transform))
        .where((widget) => widget.transform.entry(0, 0) == -1)
        .toList();
    expect(transforms, hasLength(1));

    await tester.pumpWidget(const SizedBox());
    await scanner.dispose();
  });

  testWidgets('no metrics falls back to the raw texture', (tester) async {
    final platform = FakePlatform();
    final scanner = InstantBarcodeScanner(platform: platform);
    await scanner.warmUp();

    await tester.pumpWidget(
      _host(InstantBarcodeScannerView(controller: scanner)),
    );

    expect(find.byType(Texture), findsOneWidget);
    expect(find.byType(FittedBox), findsNothing);
    expect(find.byType(RotatedBox), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await scanner.dispose();
  });
}
