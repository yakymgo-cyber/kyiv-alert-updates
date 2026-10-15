import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:frontend/data/kyiv_gazetteer.dart';
import 'package:frontend/services/threat_parser.dart';

void main() {
  group('Problem 1: Gazetteer & Directional Vectors', () {
    test('Tetiyiv, Reservoir and border markers are in kKyivLocations', () {
      expect(kKyivLocations.containsKey('тетіїв'), isTrue);
      expect(kKyivLocations['тетіїв']!.$1, closeTo(49.3658, 0.001));
      expect(kKyivLocations['тетіїв']!.$2, closeTo(29.6900, 0.001));
      expect(kKyivLocations['тетіїв']!.$3, equals('Тетіїв'));

      expect(kKyivLocations.containsKey('тетієва'), isTrue);
      expect(kKyivLocations.containsKey('тетіївський'), isTrue);

      expect(kKyivLocations.containsKey('водосховище'), isTrue);
      expect(kKyivLocations['водосховище']!.$1, closeTo(50.7600, 0.001));
      expect(kKyivLocations['водосховище']!.$2, closeTo(30.5000, 0.001));

      expect(kKyivLocations.containsKey('водосховищі'), isTrue);
      expect(kKyivLocations.containsKey('водосховища'), isTrue);
      expect(kKyivLocations.containsKey('київське море'), isTrue);
      expect(kKyivLocations.containsKey('моря'), isTrue);

      expect(kKyivLocations.containsKey('черкаської'), isTrue);
      expect(kKyivLocations['черкаської']!.$1, closeTo(49.1800, 0.001));
      expect(kKyivLocations['черкаської']!.$2, closeTo(30.1000, 0.001));
      expect(kKyivLocations['черкаської']!.$3, equals('межа Черкащини'));

      expect(kKyivLocations.containsKey('житомирської'), isTrue);
      expect(kKyivLocations['житомирської']!.$1, closeTo(50.2500, 0.001));
      expect(kKyivLocations['житомирської']!.$2, closeTo(29.3500, 0.001));

      expect(kKyivLocations.containsKey('чернігівської'), isTrue);
      expect(kKyivLocations['чернігівської']!.$1, closeTo(51.1500, 0.001));
      expect(kKyivLocations['чернігівської']!.$2, closeTo(30.9500, 0.001));

      expect(kKyivLocations.containsKey('полтавської'), isTrue);
      expect(kKyivLocations['полтавської']!.$1, closeTo(50.0500, 0.001));
      expect(kKyivLocations['полтавської']!.$2, closeTo(32.1500, 0.001));

      expect(kKyivLocations.containsKey('вінницької'), isTrue);
      expect(kKyivLocations['вінницької']!.$1, closeTo(49.3500, 0.001));
      expect(kKyivLocations['вінницької']!.$2, closeTo(29.2500, 0.001));
    });

    test('Parses "На Водосховищі один в район Вишгорода" from North to South', () {
      final threats = ThreatParser.parseLocalThreats('На Водосховищі один в район Вишгорода');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List;
      expect(path.length, equals(2));
      // First is Reservoir (50.76, 30.50), second is Vyshhorod (50.584, 30.488)
      expect(path.first['lat'], closeTo(50.7600, 0.01));
      expect(path.first['lon'], closeTo(30.5000, 0.01));
      expect(path.last['lat'], closeTo(50.584, 0.01));
      expect(path.last['lon'], closeTo(30.488, 0.01));
      // North to south: first lat > second lat
      expect(path.first['lat'] > path.last['lat'], isTrue);
    });

    test('Parses "З Черкаської на район Тетіїв" from South to North', () {
      final threats = ThreatParser.parseLocalThreats('З Черкаської на район Тетіїв');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List;
      expect(path.length, equals(2));
      // First is Cherkasy border (49.18, 30.10), second is Tetiyiv (49.3658, 29.69)
      expect(path.first['lat'], closeTo(49.1800, 0.01));
      expect(path.first['lon'], closeTo(30.1000, 0.01));
      expect(path.last['lat'], closeTo(49.3658, 0.01));
      expect(path.last['lon'], closeTo(29.6900, 0.01));
      // South to north: first lat < second lat
      expect(path.first['lat'] < path.last['lat'], isTrue);
    });
  });

  group('Problem 3: Smart Geo-Deduplication', () {
    test('Deduplicates messages from different channels at same coords within 120s and merges channel labels', () {
      final rawMsgs = [
        {
          'id': 101,
          'channel': 'Kyiv AirDefense',
          'text': 'Троєщина',
          'date': '2026-10-15T14:09:00Z',
          'type': 'danger',
        },
        {
          'id': 202,
          'channel': 'SK_DM_SK',
          'text': 'Вилізло одне на Трою',
          'date': '2026-10-15T14:09:30Z',
          'type': 'danger',
        },
      ];

      final deduped = ThreatParser.deduplicateMessages(rawMsgs);
      expect(deduped.length, equals(1));
      expect(deduped.first['channel'], contains('Kyiv AirDefense'));
      expect(deduped.first['channel'], contains('SK_DM_SK'));
    });

    test('Does NOT deduplicate distant targets (> 6 km) even within same minute', () {
      final rawMsgs = [
        {
          'id': 101,
          'channel': 'Kyiv AirDefense',
          'text': 'Троєщина',
          'date': '2026-10-15T14:09:00Z',
          'type': 'danger',
        },
        {
          'id': 303,
          'channel': 'war_monitor',
          'text': 'Тетіїв шахед',
          'date': '2026-10-15T14:09:15Z',
          'type': 'danger',
        },
      ];

      final deduped = ThreatParser.deduplicateMessages(rawMsgs);
      expect(deduped.length, equals(2));
    });
  });

  group('Problem 4: Sequential Threat Tracking & Jet UAV Flight Vector', () {
    test('Trakhtemyriv is present in kKyivLocations and gazetteer', () {
      expect(kKyivLocations.containsKey('трахтемирів'), isTrue);
      expect(kKyivLocations['трахтемирів']!.$1, closeTo(49.9850, 0.001));
      expect(kKyivLocations['трахтемирів']!.$2, closeTo(31.3300, 0.001));
      expect(kKyivLocations['трахтемирів']!.$3, equals('Трахтемирів'));
      expect(kKyivLocations.containsKey('трахтемир'), isTrue);
      expect(kKyivLocations.containsKey('трахтемиров'), isTrue);
    });

    test('Extracts high altitude for Jet UAVs up to 10000m', () {
      expect(ThreatParser.extractAltitude('На Миронівку, 7700 м'), equals(7700));
      expect(ThreatParser.extractAltitude('На Рокитне, 6200'), equals(6200));
      expect(ThreatParser.extractAltitude('12000 м'), isNull); // > 10000m should be rejected
    });

    test('Categorizes "немає", "нема", "зник", "зникло" as clear messages', () {
      expect(ThreatParser.categorizeLocalMessage('Немає'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('нема'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('зник'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('зникло'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('локаційно чисто'), equals('clear'));
    });

    test('Parses sequential jet drone locations correctly', () {
      final t1 = ThreatParser.parseLocalThreats('Реактивний на Трахтемирів');
      expect(t1.isNotEmpty, isTrue);
      expect(t1.first['type'], equals('shahed_jet'));
      expect((t1.first['path'] as List).first['lat'], closeTo(49.9850, 0.01));

      final t2 = ThreatParser.parseLocalThreats('На Миронівку, 7700 м');
      expect(t2.isNotEmpty, isTrue);
      expect(t2.first['altitude'], equals('7700 м'));
      expect((t2.first['path'] as List).first['lat'], closeTo(49.6580, 0.01));

      final t3 = ThreatParser.parseLocalThreats('На Рокитне, 6200');
      expect(t3.isNotEmpty, isTrue);
      expect(t3.first['altitude'], equals('6200 м'));
      expect((t3.first['path'] as List).first['lat'], closeTo(49.6939, 0.01));

      final t4 = ThreatParser.parseLocalThreats('Вектор Володарка');
      expect(t4.isNotEmpty, isTrue);
      expect((t4.first['path'] as List).first['lat'], closeTo(49.5200, 0.01));
    });
  });
}

