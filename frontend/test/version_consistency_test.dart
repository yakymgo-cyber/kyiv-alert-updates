import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/alert_models.dart';

/// Захист від розсинхронізації версій: якщо код збірки в Dart-константі
/// відстає від pubspec / remote_config, банер оновлення ніколи не зникне.
void main() {
  test('kDefaultVersionCode/Name match pubspec.yaml version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*([\d.]+)\+(\d+)', multiLine: true).firstMatch(pubspec);
    expect(m, isNotNull);
    expect(kDefaultVersionName, equals(m!.group(1)));
    expect(kDefaultVersionCode, equals(int.parse(m.group(2)!)));
  });

  test('Published remote_config.json does not exceed the app build', () {
    for (final path in ['../remote_config.json', '../backend/remote_config.json']) {
      final f = File(path);
      if (!f.existsSync()) continue;
      final cfg = RegExp(r'"version_code":\s*(\d+)').firstMatch(f.readAsStringSync());
      expect(cfg, isNotNull, reason: path);
      expect(int.parse(cfg!.group(1)!), lessThanOrEqualTo(kDefaultVersionCode), reason: path);
    }
  });
}
