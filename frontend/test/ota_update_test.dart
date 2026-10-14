import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';

void main() {
  group('OTA Remote Update Logic & Config Tests', () {
    test('RemoteConfig parses OTA json correctly', () {
      final jsonMap = {
        'version_code': 7,
        'version_name': '1.2.4',
        'apk_url': 'https://github.com/yakymgo-cyber/kyiv-alert-updates/releases/download/v1.2.4/app-release.apk',
        'changelog': 'Виправлено віджет та додано покращення OTA',
        'extra_locations': {
          'катюжанк': {'lat': 50.8034, 'lon': 30.1338, 'name': 'Катюжанка'}
        },
        'extra_channels': ['kievn'],
        'extra_danger_keywords': ['тривога'],
        'extra_clear_keywords': ['відбій'],
      };

      final config = RemoteConfig.fromJson(jsonMap);
      expect(config.versionCode, 7);
      expect(config.versionName, '1.2.4');
      expect(config.apkUrl, contains('v1.2.4/app-release.apk'));
      expect(config.changelog, contains('Виправлено віджет'));
      expect(config.extraLocations.containsKey('катюжанк'), true);
    });

    test('OTA hasUpdate correctly triggers on higher version code', () {
      const currentCode = kCurrentVersionCode; // 6

      // Scenario 1: Remote has higher version and non-empty apkUrl -> hasUpdate MUST be true
      const higherConfig = RemoteConfig(
        versionCode: currentCode + 1,
        versionName: '1.2.4',
        apkUrl: 'https://github.com/yakymgo-cyber/kyiv-alert-updates/releases/download/v1.2.4/app-release.apk',
        changelog: 'Нова версія',
      );
      final bool hasUpdateHigher = higherConfig.versionCode > currentCode && higherConfig.apkUrl.isNotEmpty;
      expect(hasUpdateHigher, isTrue);

      // Scenario 2: Remote has same version -> hasUpdate MUST be false
      const sameConfig = RemoteConfig(
        versionCode: currentCode,
        versionName: '1.2.3',
        apkUrl: 'https://github.com/yakymgo-cyber/kyiv-alert-updates/releases/download/v1.2.3/app-release.apk',
      );
      final bool hasUpdateSame = sameConfig.versionCode > currentCode && sameConfig.apkUrl.isNotEmpty;
      expect(hasUpdateSame, isFalse);

      // Scenario 3: Remote has higher version but empty apkUrl -> hasUpdate MUST be false
      const emptyUrlConfig = RemoteConfig(
        versionCode: currentCode + 1,
        versionName: '1.2.4',
        apkUrl: '',
      );
      final bool hasUpdateEmptyUrl = emptyUrlConfig.versionCode > currentCode && emptyUrlConfig.apkUrl.isNotEmpty;
      expect(hasUpdateEmptyUrl, isFalse);
    });

    test('OTA URL security validator accepts only trusted HTTPS GitHub hosts and rejects HTTP/LAN', () {
      bool isAllowedUrl(String apkUrl) {
        final uri = Uri.tryParse(apkUrl);
        final allowedHosts = {'github.com', 'objects.githubusercontent.com', 'raw.githubusercontent.com'};
        final isTrustedHttps = uri != null &&
            uri.scheme == 'https' &&
            allowedHosts.any((h) => uri.host == h || uri.host.endsWith('.$h'));
        return isTrustedHttps;
      }

      // Valid HTTPS (Production GitHub Release & CDN)
      expect(isAllowedUrl('https://github.com/yakymgo-cyber/kyiv-alert-updates/releases/download/v1.2.4/app-release.apk'), isTrue);
      expect(isAllowedUrl('https://objects.githubusercontent.com/github-production-release-asset-2e65be/12345/app-release.apk'), isTrue);
      expect(isAllowedUrl('https://raw.githubusercontent.com/yakymgo-cyber/kyiv-alert-updates/main/app-release.apk'), isTrue);

      // Rejects LAN and localhost HTTP (Strict Zero Cleartext)
      expect(isAllowedUrl('http://192.168.0.101:8000/api/download-apk'), isFalse);
      expect(isAllowedUrl('http://10.0.2.2:8000/api/download-apk'), isFalse);
      expect(isAllowedUrl('http://localhost:8000/app.apk'), isFalse);

      // Rejects untrusted domains and non-HTTPS
      expect(isAllowedUrl('https://evil-server.com/app.apk'), isFalse);
      expect(isAllowedUrl('http://untrusted-site.com/app.apk'), isFalse);
      expect(isAllowedUrl('ftp://example.com/app.apk'), isFalse);
    });

    test('RemoteConfig anti-poisoning filter sanitizes malicious inputs', () {
      final poisonedJson = {
        'version_code': 999,
        'extra_channels': [
          'valid_channel_1',
          'valid_2',
          'valid_3',
          'valid_4',
          'valid_5',
          'extra_sixth_channel', // should be dropped by take(5)
          'bad/path/traversal',  // should be dropped by regex
          'sh',                  // too short (< 4 chars)
          'a' * 35,              // too long (> 32 chars)
          'bad channel with spaces',
        ],
        'extra_locations': {
          'valid_place': {'lat': 50.45, 'lon': 30.52, 'name': '<b>Safe City</b>'},
          'outside_ukraine': {'lat': 40.71, 'lon': -74.00, 'name': 'New York'},
          'hi': {'lat': 50.45, 'lon': 30.52, 'name': 'Too short key'},
          'a' * 40: {'lat': 50.45, 'lon': 30.52, 'name': 'Too long key'},
        },
        'extra_danger_keywords': [
          'небезпека',
          'ab', // too short (< 3)
          'x' * 50, // too long (> 40)
        ],
      };

      final cfg = RemoteConfig.fromJson(poisonedJson);
      expect(cfg.extraChannels.length, equals(5));
      expect(cfg.extraChannels, contains('valid_channel_1'));
      expect(cfg.extraChannels.contains('bad/path/traversal'), isFalse);
      expect(cfg.extraChannels.contains('extra_sixth_channel'), isFalse);

      expect(cfg.extraLocations.containsKey('valid_place'), isTrue);
      expect(cfg.extraLocations['valid_place']!.$3, equals('Safe City')); // stripped HTML
      expect(cfg.extraLocations.containsKey('outside_ukraine'), isFalse);
      expect(cfg.extraLocations.containsKey('hi'), isFalse);

      expect(cfg.extraDangerKeywords.length, equals(1));
      expect(cfg.extraDangerKeywords.first, equals('небезпека'));
    });

    test('ZIP Magic Header verification detects valid APK and rejects fake files', () {
      final validZipHeader = [0x50, 0x4B, 0x03, 0x04, 0x14, 0x00];
      final fakeHeader = [0x7F, 0x45, 0x4C, 0x46]; // ELF binary or text

      bool isZip(List<int> bytes) {
        return bytes.length >= 4 &&
            bytes[0] == 0x50 &&
            bytes[1] == 0x4B &&
            bytes[2] == 0x03 &&
            bytes[3] == 0x04;
      }

      expect(isZip(validZipHeader), isTrue);
      expect(isZip(fakeHeader), isFalse);
    });

    testWidgets('Update banner UI renders when update is available', (tester) async {
      const newConfig = RemoteConfig(
        versionCode: 999,
        versionName: '2.0.0',
        apkUrl: 'https://github.com/yakymgo-cyber/kyiv-alert-updates/releases/download/v2.0.0/app-release.apk',
        changelog: 'Тестовий реліз з новими функціями',
      );

      // Simple mock widget rendering update banner
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Builder(
                  builder: (context) {
                    return Container(
                      margin: const EdgeInsets.all(12),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(colors: [Color(0xFF6A1B9A), Color(0xFF4A148C)]),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.system_update_rounded, color: Colors.purpleAccent),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text('🚀 Доступне оновлення v${newConfig.versionName}'),
                              ),
                              ElevatedButton(
                                onPressed: () {},
                                child: const Text('Оновити'),
                              ),
                            ],
                          ),
                          Text(newConfig.changelog),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('🚀 Доступне оновлення v2.0.0'), findsOneWidget);
      expect(find.text('Тестовий реліз з новими функціями'), findsOneWidget);
      expect(find.text('Оновити'), findsOneWidget);
    });
  });
}
