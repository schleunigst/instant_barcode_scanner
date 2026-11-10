import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Android snippet is the install path: if it omits the feature opt-out,
/// publishing apps that treat scanning as optional silently lose camera-less
/// devices on the Play Store.
void main() {
  test(
    'the Android setup snippet declares the camera permission and opt-out',
    () {
      final readme = File('README.md').readAsStringSync();
      final start = readme.indexOf('## Android setup');
      expect(
        start,
        isNonNegative,
        reason: 'README has an Android setup section',
      );
      final section = readme.substring(start);
      final block = RegExp(r'```xml\n([\s\S]*?)```').firstMatch(section);
      expect(block, isNotNull, reason: 'the setup section has an XML block');
      final xml = block!.group(1)!;

      expect(xml, contains('android.permission.CAMERA'));
      expect(xml, contains('android.hardware.camera.any'));
      expect(xml, contains('android:required="false"'));
    },
  );
}
