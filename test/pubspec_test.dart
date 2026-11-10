import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pub_semver/pub_semver.dart';

/// Guards the declared compatibility floor against drifting out of sync:
/// a Flutter floor that ships a Dart older than the SDK floor makes the
/// package unresolvable for every version in between.
void main() {
  test('the Flutter floor ships a Dart that satisfies the SDK floor', () {
    final pubspec = _readPubspec();
    final environment = pubspec['environment'] as Map<String, dynamic>;
    final sdk = VersionConstraint.parse(environment['sdk'] as String);
    final flutter = VersionConstraint.parse(environment['flutter'] as String);

    // Flutter 3.32 ships Dart 3.8. It is the declared floor because it is the
    // oldest SDK whose formatter/tooling matches this repo; lower Flutters are
    // untested and would need their own CI leg before being claimed.
    const dartAtFlutterFloor = '3.8.0';
    expect(
      flutter.allows(Version.parse('3.32.0')),
      isTrue,
      reason: 'the Flutter floor should be 3.32.0 or lower',
    );
    expect(
      sdk.allows(Version.parse(dartAtFlutterFloor)),
      isTrue,
      reason: 'Flutter 3.16 ships Dart 3.2; the SDK constraint must accept it',
    );
  });
}

Map<String, dynamic> _readPubspec() {
  final source = File('pubspec.yaml').readAsStringSync();
  final environment = <String, dynamic>{};
  var inEnvironment = false;
  for (final line in source.split('\n')) {
    if (line.startsWith('environment:')) {
      inEnvironment = true;
      continue;
    }
    if (!inEnvironment) {
      continue;
    }
    if (line.isNotEmpty && !line.startsWith(' ')) {
      break;
    }
    final match = RegExp(r'^\s+(\w+):\s*(.+)$').firstMatch(line);
    if (match != null) {
      final value = match.group(2)!.trim();
      environment[match.group(1)!] = value.replaceAll(
        RegExp(r'''^['"]|['"]$'''),
        '',
      );
    }
  }
  return <String, dynamic>{'environment': environment};
}
