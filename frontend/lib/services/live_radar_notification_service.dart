import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:latlong2/latlong.dart';
import 'package:frontend/models/alert_models.dart';
import 'package:frontend/services/voice_alert_service.dart';

const int kLiveRadarNotificationId = 1001;

@pragma('vm:entry-point')
void liveRadarBackgroundNotificationHandler(NotificationResponse response) {
  LiveRadarNotificationService.instance.handleAction(response.actionId);
}

/// Сервіс закріпленого інтерактивного сповіщення "Живий радар" на екрані блокування
class LiveRadarNotificationService {
  static final LiveRadarNotificationService instance = LiveRadarNotificationService._internal();
  LiveRadarNotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  bool _isDismissedByUser = false;
  DateTime? _alarmMutedUntil;
  VoidCallback? onMuteRequested;

  bool get isAlarmMuted => _alarmMutedUntil != null && DateTime.now().isBefore(_alarmMutedUntil!);

  void muteAlarmFor(Duration duration) {
    _alarmMutedUntil = DateTime.now().add(duration);
    onMuteRequested?.call();
  }

  void unmuteAlarm() {
    _alarmMutedUntil = null;
  }

  /// Ініціалізація каналу сповіщень
  Future<void> init() async {
    if (_isInitialized || kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwinSettings = DarwinInitializationSettings();
      const linuxSettings = LinuxInitializationSettings(defaultActionName: 'Open');

      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
        macOS: darwinSettings,
        linux: linuxSettings,
      );

      await _notificationsPlugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (response) {
          handleAction(response.actionId);
        },
        onDidReceiveBackgroundNotificationResponse: liveRadarBackgroundNotificationHandler,
      );

      // Створення каналу з низькою важливістю для тихого оновлення
      if (!kIsWeb && Platform.isAndroid) {
        final androidImplementation = _notificationsPlugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
        if (androidImplementation != null) {
          const channel = AndroidNotificationChannel(
            'kyiv_live_radar',
            'Живий радар Київщини',
            description: 'Відображення статусу найближчих загроз на заблокованому екрані',
            importance: Importance.low,
            playSound: false,
            enableVibration: false,
            showBadge: false,
          );
          await androidImplementation.createNotificationChannel(channel);
        }
      }

      _isInitialized = true;
    } catch (e) {
      debugPrint('LiveRadarNotificationService init error: $e');
    }
  }

  /// Обробка дій користувача зі сповіщення
  void handleAction(String? actionId) {
    if (actionId == 'mute_15m') {
      VoiceAlertService.instance.muteFor(const Duration(minutes: 15));
      muteAlarmFor(const Duration(minutes: 15));
    } else if (actionId == 'dismiss_radar') {
      dismiss();
    }
  }

  /// Приховування сповіщення користувачем
  Future<void> dismiss() async {
    _isDismissedByUser = true;
    await cancelNotification();
  }

  /// Скасування та зняття сповіщення
  Future<void> cancelNotification() async {
    if (kIsWeb) return;
    try {
      await _notificationsPlugin.cancel(kLiveRadarNotificationId);
    } catch (_) {}
  }

  /// Оновлення або зняття сповіщення залежно від ситуації на радарі
  Future<void> updateRadarStatus({
    required List<Map<String, dynamic>> threats,
    required List<WatchedLocation> watchedLocations,
    required bool isAlertKyiv,
    required bool isAlertRegion,
  }) async {
    if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (!_isInitialized) {
      await init();
    }

    final bool hasActiveAlert = isAlertKyiv || isAlertRegion;
    final bool hasThreats = threats.isNotEmpty;

    // Якщо все чисто — знімаємо сповіщення та скидаємо статус приховування
    if (!hasThreats && !hasActiveAlert) {
      _isDismissedByUser = false;
      await cancelNotification();
      return;
    }

    // Якщо користувач натиснув "Приховати", не показуємо, доки загрози не змінилися кардинально
    if (_isDismissedByUser) {
      return;
    }

    try {
      String title = '📡 Радар Київщини';
      String body = '';

      if (hasThreats) {
        title = '📡 Радар Київщини: активних цілей — ${threats.length}';

        // Шукаємо найближчу ціль до будь-якої активної зони безпеки
        final enabledZones = watchedLocations.where((l) => l.enabled).toList();
        Map<String, dynamic>? closestThreat;
        WatchedLocation? targetZone;
        double minDistanceMeters = double.infinity;

        const distanceCalc = Distance();

        for (final t in threats) {
          final pts = (t['path'] as List<LatLng>?) ?? [];
          final currentPoint = pts.isNotEmpty ? pts.last : (t['point'] as LatLng?);
          if (currentPoint == null) continue;

          if (enabledZones.isNotEmpty) {
            for (final zone in enabledZones) {
              final d = distanceCalc.as(LengthUnit.Meter, zone.point, currentPoint);
              if (d < minDistanceMeters) {
                minDistanceMeters = d;
                closestThreat = t;
                targetZone = zone;
              }
            }
          } else {
            // За замовчуванням рахуємо до центру Києва
            const kyivCenter = LatLng(50.4501, 30.5234);
            final d = distanceCalc.as(LengthUnit.Meter, kyivCenter, currentPoint);
            if (d < minDistanceMeters) {
              minDistanceMeters = d;
              closestThreat = t;
            }
          }
        }

        if (closestThreat != null) {
          final rawType = closestThreat['type']?.toString() ?? 'shahed';
          final friendlyType = VoiceAlertService.toFriendlyVoiceThreatType(rawType);
          final location = (closestThreat['route'] ?? closestThreat['label'] ?? 'Київщина').toString();
          final distKm = minDistanceMeters / 1000.0;
          final speedMs = ((closestThreat['speed'] as num?)?.toDouble() ?? 185.0) / 3.6;
          final etaMin = (speedMs > 5.0 ? (minDistanceMeters / speedMs / 60.0) : 0.0).ceil().clamp(1, 120);

          if (targetZone != null) {
            body = '⚠️ Найближча: $friendlyType ($location) • ${distKm.toStringAsFixed(1)} км до «${targetZone.name}» (~$etaMin хв)';
          } else {
            body = '⚠️ Найближча: $friendlyType ($location) • ${distKm.toStringAsFixed(1)} км до Києва (~$etaMin хв)';
          }
        } else {
          body = '⚠️ Повітряні цілі фіксуються в напрямку Київщини. Перебувайте в укриттях.';
        }
      } else if (hasActiveAlert) {
        title = '🚨 Повітряна тривога в Києві та області';
        body = '⚠️ Загроза ракетного удару / ударних дронів. Перейдіть в укриття!';
      }

      final androidDetails = AndroidNotificationDetails(
        'kyiv_live_radar',
        'Живий радар Київщини',
        channelDescription: 'Відображення статусу найближчих загроз на заблокованому екрані',
        importance: Importance.low,
        priority: Priority.low,
        visibility: NotificationVisibility.public,
        ongoing: true,
        autoCancel: false,
        showWhen: true,
        icon: '@mipmap/ic_launcher',
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            'mute_15m',
            '🔇 Тиша 15 хв',
            showsUserInterface: false,
            cancelNotification: false,
          ),
          AndroidNotificationAction(
            'dismiss_radar',
            'Приховати',
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ],
      );

      final notificationDetails = NotificationDetails(
        android: androidDetails,
        iOS: const DarwinNotificationDetails(
          presentAlert: false,
          presentBadge: false,
          presentSound: false,
        ),
      );

      await _notificationsPlugin.show(
        kLiveRadarNotificationId,
        title,
        body,
        notificationDetails,
      );
    } catch (e) {
      debugPrint('LiveRadarNotification update error: $e');
    }
  }
}
