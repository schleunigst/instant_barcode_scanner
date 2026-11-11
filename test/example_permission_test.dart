import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The plugin owns the CAMERA prompt. The example must not ask a second time,
/// or the two requests race on the same permission.
void main() {
  test('the example lets the plugin own the camera prompt', () {
    for (final path in [
      'example/lib/main.dart',
      'example/lib/verify_main.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('permission_handler')), reason: path);
      expect(source, isNot(contains('Permission.camera')), reason: path);
      expect(source, contains('plugin owns the CAMERA prompt'), reason: path);
    }
    final pubspec = File('example/pubspec.yaml').readAsStringSync();
    expect(pubspec, isNot(contains('permission_handler')));
  });
}
