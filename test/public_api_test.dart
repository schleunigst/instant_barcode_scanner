import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The platform boundary is a test seam, not an extension point, and the
/// public enums are open sets. Both rules must stay visible to consumers.
void main() {
  test('the platform boundary is not exported from the library barrel', () {
    final barrel = File('lib/instant_barcode_scanner.dart').readAsStringSync();
    expect(barrel, isNot(contains('InstantBarcodeScannerPlatform')));
  });

  test('the enum-growth and platform rules are published in the README', () {
    final readme = File('README.md').readAsStringSync();
    expect(readme, contains('non-exhaustive'));
    expect(readme, contains('is not public API'));
  });
}
