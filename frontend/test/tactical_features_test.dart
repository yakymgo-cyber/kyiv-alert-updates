import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/services/threat_parser.dart';
import 'package:frontend/services/voice_alert_service.dart';
import 'package:frontend/services/live_radar_notification_service.dart';

void main() {
  group('Tactical Feature 1: Strategic Launch Detector & Timer', () {
    test('Detects Tu-95MS / Kh-101 strategic launch within 90 minutes', () {
      final now = DateTime.utc(2026, 10, 15, 4, 30);
      final messages = [
        {
          'id': 1,
          'text': 'Здійснено пуски крилатих ракет Х-101 з району Каспію бортами Ту-95МС!',
          'date': '2026-10-15T04:10:00Z',
        },
        {
          'id': 2,
          'text': 'Зліт 4 бортів Ту-95 з Оленья',
          'date': '2026-10-15T03:00:00Z',
        }
      ];

      final event = detectStrategicLaunch(messages, now: now);
      expect(event, isNotNull);
      expect(event!.type, 'Х-101 (Ту-95МС)');
      expect(event.estimatedArrivalMinutes, 65);
      expect(event.timestamp, DateTime.utc(2026, 10, 15, 4, 10));

      // 4:10 + 65 min = 5:15 arrival. From 4:30, remaining = 45 min
      expect(event.remainingMinutes(now), 45);
      expect(event.isExpired(now), isFalse);
    });

    test('Detects Sea-launched Kalibr cruise missile launches', () {
      final now = DateTime.utc(2026, 10, 15, 6, 0);
      final messages = [
        {
          'id': 10,
          'text': 'Зафіксовано пуски Калібрів з акваторії Чорного моря (Новоросійськ)!',
          'date': '2026-10-15T05:40:00Z',
        }
      ];

      final event = detectStrategicLaunch(messages, now: now);
      expect(event, isNotNull);
      expect(event!.type, 'КРМБ «Калібр» (Море)');
      expect(event.estimatedArrivalMinutes, 50);

      // 5:40 + 50 min = 6:30 arrival. From 6:00, remaining = 30 min
      expect(event.remainingMinutes(now), 30);
    });

    test('Ignores old messages (> 90 min) and respects clear messages', () {
      final now = DateTime.utc(2026, 10, 15, 7, 0);
      final oldMessages = [
        {
          'id': 1,
          'text': 'Пуски Х-101 Ту-95МС',
          'date': '2026-10-15T05:00:00Z', // 120 min ago
        }
      ];
      expect(detectStrategicLaunch(oldMessages, now: now), isNull);

      final clearedMessages = [
        {
          'id': 2,
          'text': 'Пуски Х-101 Ту-95МС',
          'date': '2026-10-15T06:10:00Z',
        },
        {
          'id': 3,
          'text': 'Відбій по ракетах! Чисто по бортах.',
          'date': '2026-10-15T06:30:00Z',
        }
      ];
      expect(detectStrategicLaunch(clearedMessages, now: now), isNull);
    });
  });

  group('Tactical Feature 2: Voice Alert Service & Friendly Threat Labels', () {
    test('Friendly voice threat labels translation', () {
      expect(VoiceAlertService.toFriendlyVoiceThreatType('shahed_jet'), 'Реактивний БпЛА');
      expect(VoiceAlertService.toFriendlyVoiceThreatType('shahed'), 'Ударний БпЛА');
      expect(VoiceAlertService.toFriendlyVoiceThreatType('missile_ballistic'), 'Балістична ціль');
      expect(VoiceAlertService.toFriendlyVoiceThreatType('missile_cruise'), 'Крилата ракета');
      expect(VoiceAlertService.toFriendlyVoiceThreatType('kab'), 'Керована авіабомба');
    });

    test('VoiceAlertService mute and enable toggles', () {
      final voice = VoiceAlertService.instance;
      voice.setEnabled(true);
      expect(voice.isEnabled, isTrue);

      voice.muteFor(const Duration(minutes: 15));
      expect(voice.isMuted, isTrue);

      voice.unmute();
      expect(voice.isMuted, isFalse);
    });
  });

  group('Tactical Feature 3: Live Radar Notification Service', () {
    test('Action handling for mute and dismiss', () {
      final radarNotif = LiveRadarNotificationService.instance;
      radarNotif.unmuteAlarm();
      expect(radarNotif.isAlarmMuted, isFalse);

      radarNotif.handleAction('mute_15m');
      expect(radarNotif.isAlarmMuted, isTrue);
      expect(VoiceAlertService.instance.isMuted, isTrue);

      radarNotif.unmuteAlarm();
      VoiceAlertService.instance.unmute();
    });
  });
}
