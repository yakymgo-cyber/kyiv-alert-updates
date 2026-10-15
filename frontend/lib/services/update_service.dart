import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Сервіс безпечного завантаження та встановлення оновлень APK
class UpdateService {
  static const allowedHosts = {
    'github.com',
    'objects.githubusercontent.com',
    'raw.githubusercontent.com'
  };

  /// Перевірка безпеки URL: виключно HTTPS та довірені сервери GitHub
  static bool isTrustedHttps(String apkUrl) {
    final uri = Uri.tryParse(apkUrl);
    return uri != null &&
        uri.scheme == 'https' &&
        allowedHosts.any((h) => uri.host == h || uri.host.endsWith('.$h'));
  }

  /// Завантаження та виклик нативного інсталятора з контролем DoS (150 МБ) та сигнатури ZIP
  static Future<void> downloadAndInstallApk({
    required String apkUrl,
    required void Function(double progress) onProgress,
    required void Function(String error) onError,
    required void Function(String filePath) onSavedNonAndroid,
    required void Function() onPermissionRequired,
    required void Function(bool isDownloading) onDownloadingChanged,
  }) async {
    if (!isTrustedHttps(apkUrl)) {
      onError('Помилка безпеки: завантаження APK дозволено виключно через HTTPS з офіційних серверів GitHub');
      return;
    }

    onDownloadingChanged(true);
    onProgress(0.0);

    try {
      final uri = Uri.parse(apkUrl);
      String cacheDir = '';
      if (!kIsWeb && Platform.isAndroid) {
        try {
          const channel = MethodChannel('ua.kyiv.alert.monitor/widget');
          cacheDir = await channel.invokeMethod<String>('getCacheDir') ?? '';
        } catch (_) {}
      }

      File apkFile;
      if (cacheDir.isNotEmpty) {
        apkFile = File('$cacheDir/update.apk');
      } else {
        final envTemp = Platform.environment['TEMP'] ?? Platform.environment['TMP'];
        apkFile = File(envTemp != null ? '$envTemp/update.apk' : 'update.apk');
      }

      // Видаляємо попередній файл оновлення перед завантаженням
      if (await apkFile.exists()) {
        try {
          await apkFile.delete();
        } catch (_) {}
      }

      const int maxApkBytes = 157286400; // 150 МБ ліміт проти DoS
      final client = http.Client();
      try {
        final request = http.Request('GET', uri);
        final response = await client.send(request);

        if (response.statusCode != 200) {
          throw Exception('Сервер повернув код ${response.statusCode}');
        }

        final totalBytes = response.contentLength ?? 0;
        if (totalBytes > maxApkBytes) {
          throw Exception('Розмір оновлення ($totalBytes байт) перевищує ліміт безпеки (150 МБ)');
        }

        int receivedBytes = 0;
        final sink = apkFile.openWrite();
        try {
          await for (final chunk in response.stream.timeout(const Duration(seconds: 45))) {
            receivedBytes += chunk.length;
            if (receivedBytes > maxApkBytes) {
              throw Exception('Перевищено максимальний ліміт розміру файлу (150 МБ)');
            }
            sink.add(chunk);
            if (totalBytes > 0) {
              onProgress((receivedBytes / totalBytes).clamp(0.0, 1.0));
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
      } finally {
        client.close();
      }

      // Перевірка сигнатури APK (ZIP Magic Header: 0x50, 0x4B, 0x03, 0x04)
      if (await apkFile.exists()) {
        final headerBytes = await apkFile.openRead(0, 4).first;
        final bool isZipMagic = headerBytes.length >= 4 &&
            headerBytes[0] == 0x50 &&
            headerBytes[1] == 0x4B &&
            headerBytes[2] == 0x03 &&
            headerBytes[3] == 0x04;
        if (!isZipMagic) {
          try {
            await apkFile.delete();
          } catch (_) {}
          throw Exception('Помилка безпеки: завантажений файл не є валідним APK-пакетом (невірна сигнатура)');
        }
      } else {
        throw Exception('Файл оновлення не знайдено після завантаження');
      }

      onDownloadingChanged(false);

      if (!kIsWeb && Platform.isAndroid) {
        const channel = MethodChannel('ua.kyiv.alert.monitor/widget');
        try {
          await channel.invokeMethod('installApk', {'filePath': apkFile.path});
        } on PlatformException catch (pe) {
          if (pe.code == 'PERMISSION_REQUIRED') {
            onPermissionRequired();
            return;
          }
          rethrow;
        }
      } else {
        onSavedNonAndroid(apkFile.path);
      }
    } catch (e) {
      onDownloadingChanged(false);
      onError('Помилка оновлення: $e');
    }
  }
}
