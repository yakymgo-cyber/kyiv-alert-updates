import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/data/kyiv_gazetteer.dart';
import 'package:frontend/models/alert_models.dart';
import 'package:frontend/services/threat_parser.dart';

/// Регресійні тести на реальних шаблонах повідомлень масованої атаки на Київ 15–16.10.
void main() {
  group('Attack 15-16.10: gazetteer coverage', () {
    test('New micro-locations exist in kKyivLocations', () {
      for (final key in ['коцюб', 'межигір', 'васильківська', 'багринова гора', 'шевченков', 'лісович']) {
        expect(kKyivLocations.containsKey(key), isTrue, reason: 'missing $key');
      }
      expect(kKyivLocations['коцюб']!.$1, closeTo(50.4910, 0.01));
      expect(kKyivLocations['межигір']!.$1, closeTo(50.6150, 0.01));
    });

    test('Poisoned remote extra_locations are ignored', () {
      final cfg = RemoteConfig.fromJson({
        'extra_locations': {
          'києва': {'lat': 50.39, 'lon': 30.21, 'name': 'Києво-Святошинський'},
          'умань': {'lat': 49.78, 'lon': 30.12, 'name': 'Уманьпиво'},
          'залізн': {'lat': 50.20, 'lon': 30.35, 'name': 'Залізне'},
          'десни': {'lat': 50.55, 'lon': 30.61, 'name': 'стариця Десни'},
          'горенк': {'lat': 50.55957, 'lon': 30.31226, 'name': 'Горенка'},
        },
      });
      expect(cfg.extraLocations.containsKey('києва'), isFalse);
      expect(cfg.extraLocations.containsKey('умань'), isFalse);
      expect(cfg.extraLocations.containsKey('залізн'), isFalse);
      expect(cfg.extraLocations.containsKey('десни'), isFalse);
      expect(cfg.extraLocations.containsKey('горенк'), isTrue);
    });
  });

  group('Attack 15-16.10: parser patterns', () {
    test('Unicode apostrophes (ʼ, ’) resolve Межигірʼя', () {
      for (final txt in ['Межигірʼя', 'Межигір’я', "Межигір'я"]) {
        final t = ThreatParser.parseLocalThreats(txt);
        expect(t.isNotEmpty, isTrue, reason: txt);
        expect((t.first['path'] as List).last['lat'], closeTo(50.6150, 0.02), reason: txt);
      }
    });

    test('"На Коцюбу" is parsed as a directional single point', () {
      final t = ThreatParser.parseLocalThreats('На Коцюбу');
      expect(t.isNotEmpty, isTrue);
      expect((t.first['path'] as List).last['lat'], closeTo(50.4910, 0.02));
    });

    test('Багринова гора is not confused with the town of Гора', () {
      final t = ThreatParser.parseLocalThreats('Багринова гора');
      expect(t.isNotEmpty, isTrue);
      final p = (t.first['path'] as List).last;
      expect(p['lat'], closeTo(50.3785, 0.02));
      expect(p['lon'], closeTo(30.5315, 0.02));
    });

    test('Васильківська street resolves inside Kyiv, not Vasylkiv town', () {
      final t = ThreatParser.parseLocalThreats('Васильківська');
      expect(t.isNotEmpty, isTrue);
      final p = (t.first['path'] as List).last;
      expect(p['lat'], closeTo(50.3933, 0.02));
      expect(p['lon'], closeTo(30.4883, 0.02));
    });

    test('Шевченкове and Лісовичі resolve to oblast villages', () {
      final t1 = ThreatParser.parseLocalThreats('Шевченкове');
      expect(t1.isNotEmpty, isTrue);
      expect((t1.first['path'] as List).last['lon'], closeTo(30.2464, 0.03));

      final t2 = ThreatParser.parseLocalThreats('Лісовичі');
      expect(t2.isNotEmpty, isTrue);
      expect((t2.first['path'] as List).last['lat'], closeTo(50.8164, 0.03));
    });

    test('Altitude with "шв" speed telemetry (2700м 459шв)', () {
      expect(ThreatParser.extractAltitude('2700м 459шв'), equals(2700));
      expect(ThreatParser.extractAltitude('6900м 412шв'), equals(6900));
    });

    test('Destroyed slang is classified as clear', () {
      expect(ThreatParser.categorizeLocalMessage('Впав'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('Сконав'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('Вʼєбало'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage("В'єбало"), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('Не впав'), isNot(equals('clear')));
    });
  });
}
