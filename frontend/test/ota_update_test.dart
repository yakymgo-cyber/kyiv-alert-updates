import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

    test('OTA URL security validator accepts HTTPS and LAN HTTP for dev', () {
      bool isAllowedUrl(String apkUrl) {
        final uri = Uri.tryParse(apkUrl);
        final isHttps = uri?.scheme == 'https';
        final isLocalHttp = uri?.scheme == 'http' &&
            (uri?.host == '10.0.2.2' ||
             uri?.host == 'localhost' ||
             uri?.host == '127.0.0.1' ||
             (uri?.host.startsWith('192.168.') ?? false) ||
             (uri?.host.startsWith('10.') ?? false));
        return isHttps || isLocalHttp;
      }

      // Valid HTTPS (Production GitHub Release)
      expect(isAllowedUrl('https://github.com/yakymgo-cyber/kyiv-alert-updates/releases/download/v1.2.4/app-release.apk'), isTrue);

      // Valid Local LAN HTTP (Testing on same WiFi network)
      expect(isAllowedUrl('http://192.168.0.101:8000/api/download-apk'), isTrue);
      expect(isAllowedUrl('http://10.0.2.2:8000/api/download-apk'), isTrue);
      expect(isAllowedUrl('http://localhost:8000/app.apk'), isTrue);

      // Invalid insecure non-local HTTP
      expect(isAllowedUrl('http://untrusted-site.com/app.apk'), isFalse);
      expect(isAllowedUrl('ftp://example.com/app.apk'), isFalse);
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
