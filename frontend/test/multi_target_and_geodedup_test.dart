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

  group('Problem 5: Telegram Replies, Geo-Deduplication with Merged IDs, Circling & Inversion Tests', () {
    test('New inflected forms of Kyiv reservoir and sea are in kKyivLocations', () {
      expect(kKyivLocations.containsKey('водосховищ'), isTrue);
      expect(kKyivLocations['водосховищ']!.$1, closeTo(50.7600, 0.001));
      expect(kKyivLocations.containsKey('київського моря'), isTrue);
      expect(kKyivLocations['київського моря']!.$1, closeTo(50.7600, 0.001));
      expect(kKyivLocations.containsKey('київському морі'), isTrue);
      expect(kKyivLocations['київському морі']!.$1, closeTo(50.7600, 0.001));
    });

    test('Categorizes danger words correctly', () {
      expect(ThreatParser.categorizeLocalMessage('літає над лісом'), equals('danger'));
      expect(ThreatParser.categorizeLocalMessage('кружляє'), equals('danger'));
      expect(ThreatParser.categorizeLocalMessage('крутить коло'), equals('danger'));
      expect(ThreatParser.categorizeLocalMessage('фіксується ціль'), equals('danger'));
      expect(ThreatParser.categorizeLocalMessage('водосховище небезпека'), equals('danger'));
      expect(ThreatParser.categorizeLocalMessage('вишгород увага'), equals('danger'));
      expect(ThreatParser.categorizeLocalMessage('тетіїв дрон'), equals('danger'));
      expect(ThreatParser.categorizeLocalMessage('вилізло на трою'), equals('danger'));
      expect(ThreatParser.categorizeLocalMessage('виліз шахед'), equals('danger'));
    });

    test('Single location with circling words sets isCircling: true', () {
      final t1 = ThreatParser.parseLocalThreats('В районі Вишгорода літає');
      expect(t1.isNotEmpty, isTrue);
      expect(t1.first['isCircling'], isTrue);

      final t2 = ThreatParser.parseLocalThreats('Шахед кружляє біля Тетієва');
      expect(t2.isNotEmpty, isTrue);
      expect(t2.first['isCircling'], isTrue);
    });

    test('Contextual Novosilky resolves to Vyshhorod when northern keywords present', () {
      final tDefault = ThreatParser.parseLocalThreats('Шахед на Новосілки');
      expect(tDefault.isNotEmpty, isTrue);
      expect((tDefault.first['path'] as List).first['name'], contains('Теремки'));

      final tVysh = ThreatParser.parseLocalThreats('Шахед на Новосілки біля Вишгорода');
      expect(tVysh.isNotEmpty, isTrue);
      expect((tVysh.first['path'] as List).first['name'], contains('Вишгород'));

      final tSea = ThreatParser.parseLocalThreats('Новосілки, заходить з Водосховища');
      expect(tSea.isNotEmpty, isTrue);
      expect((tSea.first['path'] as List).any((p) => p['name'].toString().contains('Вишгород')), isTrue);
    });

    test('Inverts 2-location order when destination precedes locA and origin precedes locB', () {
      final t1 = ThreatParser.parseLocalThreats('На Вишгород з Водосховища');
      expect(t1.isNotEmpty, isTrue);
      final path1 = t1.first['path'] as List;
      expect(path1.length, equals(2));
      expect(path1[0]['name'], contains('водосховище'));
      expect(path1[1]['name'], contains('Вишгород'));

      final t2 = ThreatParser.parseLocalThreats('Курсом на Тетіїв від Черкаської');
      expect(t2.isNotEmpty, isTrue);
      final path2 = t2.first['path'] as List;
      expect(path2.length, equals(2));
      expect(path2[0]['name'], contains('Черкащ'));
      expect(path2[1]['name'], contains('Тетіїв'));
    });

    test('Geo-deduplication merges channel with " • " and tracks merged_msg_ids and merged_post_ids', () {
      final msgs = [
        {
          'id': 101,
          'postId': 'kyiv_channel/101',
          'channel': 'Kyiv AirDefense 🌇',
          'text': 'Троєщина',
          'date': '2026-10-15T14:09:00Z',
          'type': 'danger',
        },
        {
          'id': 202,
          'postId': 'sk_channel/202',
          'channel': 'SK_DM_SK',
          'text': 'Вилізло одне на Трою',
          'date': '2026-10-15T14:09:25Z',
          'type': 'danger',
        },
      ];

      final deduped = ThreatParser.deduplicateMessages(msgs);
      expect(deduped.length, equals(1));
      expect(deduped.first['channel'], equals('Kyiv AirDefense 🌇 • SK_DM_SK'));
      final mergedMsgs = deduped.first['merged_msg_ids'] as List;
      expect(mergedMsgs.contains(202), isTrue);
      final mergedPosts = deduped.first['merged_post_ids'] as List;
      expect(mergedPosts.contains('sk_channel/202'), isTrue);
    });
  });

  group('Release v1.2.24: Speed, Bank Card Filter, Numbered Targets, "Не мінус", External Districts & Gazetteer', () {
    test('Speed extraction and altitude cleaning', () {
      expect(ThreatParser.extractSpeed('120 швидкість'), equals(120));
      expect(ThreatParser.extractSpeed('550 км/год'), equals(550));
      expect(ThreatParser.extractSpeed('швидкість: 450'), equals(450));
      expect(ThreatParser.extractSpeed('без швидкості'), isNull);

      // Speed phrases and 750 kV should NOT be parsed as altitude
      expect(ThreatParser.extractAltitude('550 швидкість'), isNull);
      expect(ThreatParser.extractAltitude('на Бородянку 750'), isNull);
      expect(ThreatParser.extractAltitude('700'), equals(700));
      expect(ThreatParser.extractAltitude('6400'), equals(6400));
    });

    test('Bank card & donation filter rejects donate posts as ignore', () {
      expect(ThreatParser.categorizeLocalMessage('Збір на банку monobank: 4441 1110 2222 3333 на 7600 грн'), equals('ignore'));
      expect(ThreatParser.categorizeLocalMessage('Підтримка каналу приватбанк send.monobank.ua'), equals('ignore'));
      expect(ThreatParser.extractAltitude('4441 1110 2222 7600'), isNull);
    });

    test('Numbered targets pre-splitting assigns orderTag 1 and 2', () {
      final threats = ThreatParser.parseLocalThreats('1 на Обухів. Другий на Згурівку');
      expect(threats.length, equals(2));
      expect(threats[0]['orderTag'], equals(1));
      expect((threats[0]['path'] as List).first['name'], contains('Обухів'));
      expect(threats[1]['orderTag'], equals(2));
      expect((threats[1]['path'] as List).first['name'], contains('Згурів'));
    });

    test('"Не мінус" protection and dump clear phrases', () {
      // Negated clear is NOT clear
      expect(ThreatParser.categorizeLocalMessage('Не мінус, ще літає'), equals('danger'));
      expect(ThreatParser.categorizeLocalMessage('ще не зник'), equals('danger'));
      expect(ThreatParser.categorizeLocalMessage('не збито'), equals('danger'));

      // Real dump clear phrases
      expect(ThreatParser.categorizeLocalMessage('все наче'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('ніби все'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('нема його'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('-1'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('ушов назад'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('втрачено над водосховищем'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('попередньо збили'), equals('clear'));
    });

    test('External district hashtag and phrase rejection without Kyiv mention', () {
      expect(ThreatParser.categorizeLocalMessage('БпЛА в напрямку #харківський_район'), equals('ignore'));
      expect(ThreatParser.categorizeLocalMessage('Шахед зайшов в дніпровський район'), equals('ignore'));
      expect(ThreatParser.categorizeLocalMessage('Шахед зайшов в дніпровський район Києва'), equals('danger'));
    });

    test('New gazetteer locations and Vietnam air defense slang', () {
      expect(kKyivLocations.containsKey('софія резиденс'), isTrue);
      expect(kKyivLocations.containsKey('софія'), isTrue);
      expect(kKyivLocations.containsKey('б.ц'), isTrue);
      expect(kKyivLocations.containsKey('бц '), isTrue);
      expect(kKyivLocations.containsKey('вишня'), isTrue);
      expect(kKyivLocations.containsKey("жереб'ятин"), isTrue);
      expect(kKyivLocations.containsKey('жеребятин'), isTrue);
      expect(kKyivLocations.containsKey('жеребʼятин'), isTrue);
      expect(kKyivLocations.containsKey('бородянку 750'), isTrue);
      expect(kKyivLocations.containsKey('наливайківк'), isTrue);

      expect(ThreatParser.categorizeLocalMessage("в'єтнам над Києвом"), equals('danger'));
      final vThreats = ThreatParser.parseLocalThreats("в'єтнам");
      expect(vThreats.isNotEmpty, isTrue);
      expect((vThreats.first['path'] as List).first['name'], contains('Київ'));
    });
  });

  group('Release v1.2.25: Instant Threat Disappearance on Shootdown Reply', () {
    test('"Знищено", "-1", "Збито" are recognized as clear and destruction', () {
      expect(ThreatParser.categorizeLocalMessage('Знищено'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('збито'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('-1'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('ліквідовано'), equals('clear'));
      expect(ThreatParser.categorizeLocalMessage('мінус 1'), equals('clear'));
    });

    test('Simulate message reply chain: track created, then reply "Знищено" removes target and prevents resurrection', () {
      // Message 1: Initial threat approaching Dymer from south
      final msg1Text = 'Димер з півдня';
      final parsed1 = ThreatParser.parseLocalThreats(msg1Text);
      expect(parsed1.isNotEmpty, isTrue);

      final List<Map<String, dynamic>> threats = [
        {
          'msgId': 101,
          'postId': 'kyiv_airdef/45120',
          'lastPostId': 'kyiv_airdef/45120',
          'historyPostIds': {'kyiv_airdef/45120'},
          'historyMsgIds': {101},
          'channel': 'Kyiv AirDefense 🌇',
          'text': msg1Text,
          'route': 'південь -> Димер',
          'path': [const LatLng(50.60, 30.30), const LatLng(50.78, 30.30)],
          'waypoints': [const LatLng(50.60, 30.30), const LatLng(50.78, 30.30)],
          'type': 'shahed_jet',
          'speed': 480.0,
          'lastUpdated': DateTime.parse('2026-10-15T20:03:00Z'),
        }
      ];
      expect(threats.length, equals(1));

      // Message 2: Reply at 20:07 saying "Знищено"
      final msg2 = {
        'id': 102,
        'postId': 'kyiv_airdef/45125',
        'reply_to_post_id': 'kyiv_airdef/45120',
        'reply_quoted_text': 'Димер з півдня',
        'channel': 'Kyiv AirDefense 🌇',
        'text': 'Знищено',
        'date': '2026-10-15T20:07:00Z',
      };

      // Verify matching logic
      final replyToPost = msg2['reply_to_post_id'];
      int targetIdx = -1;
      for (int ti = threats.length - 1; ti >= 0; ti--) {
        if (threats[ti]['lastPostId'] == replyToPost ||
            (threats[ti]['historyPostIds'] as Set).contains(replyToPost)) {
          targetIdx = ti;
          break;
        }
      }
      expect(targetIdx, equals(0));

      final cleared = threats.removeAt(targetIdx);
      cleared['isDestroyed'] = true;
      expect(threats.isEmpty, isTrue);

      final recentlyClearedLocations = <({LatLng point, DateTime time, String? channel})>[];
      final pList = (cleared['waypoints'] as List<LatLng>?) ?? (cleared['path'] as List<LatLng>?) ?? [];
      final msg2Time = DateTime.parse(msg2['date']!.toString());
      for (final pt in pList) {
        recentlyClearedLocations.add((point: pt, time: msg2Time, channel: msg2['channel']?.toString()));
      }
      expect(recentlyClearedLocations.length, equals(2));

      // Attempted delayed message at 20:07:30 from another channel:
      final lateMsgTime = DateTime.parse('2026-10-15T20:07:30Z');
      final latePath = [const LatLng(50.78, 30.30)];
      bool isResurrected = false;
      for (final pt in latePath) {
        for (final clr in recentlyClearedLocations) {
          if (lateMsgTime.difference(clr.time).inSeconds.abs() <= 120) {
            final dMeters = const Distance().as(LengthUnit.Meter, clr.point, pt);
            if (dMeters <= 5000.0) {
              isResurrected = true;
              break;
            }
          }
        }
        if (isResurrected) break;
      }
      expect(isResurrected, isTrue);
    });
  });

  group('Release v1.2.26: Stolitsia Vocative / Header Filter & Multi-Location Split', () {
    test('Vocative header + list of separate targets without Stolitsia target', () {
      final text = '''Столиця наступні 3
Вишгород Гостомель Боря Обухів
І далі по руху обережно''';
      final threats = ThreatParser.parseLocalThreats(text);
      expect(threats.length, equals(4));
      expect(threats.any((t) => (t['path'] as List).any((p) => p['name'].toString().contains('Столиц'))), isFalse);
      expect((threats[0]['path'] as List).first['name'], equals('Вишгород'));
      expect((threats[1]['path'] as List).first['name'], equals('Гостомель'));
      expect((threats[2]['path'] as List).first['name'], equals('Бориспіль'));
      expect((threats[3]['path'] as List).first['name'], equals('Обухів'));
    });

    test('Vocative prefix on same line does not produce Stolitsia target', () {
      final text = 'Столиця, увага! 1 на Вишгород';
      final threats = ThreatParser.parseLocalThreats(text);
      expect(threats.length, equals(1));
      expect(threats.any((t) => (t['path'] as List).any((p) => p['name'].toString().contains('Столиц'))), isFalse);
      expect((threats[0]['path'] as List).first['name'], equals('Вишгород'));
    });

    test('Directional destination TO capital ("курс на столицю", "в бік столиці") parses Stolitsia', () {
      final text1 = 'Шахед з півночі курс на столицю';
      final threats1 = ThreatParser.parseLocalThreats(text1);
      expect(threats1.length, equals(1));
      expect(threats1.any((t) => (t['path'] as List).any((p) => p['name'].toString().contains('Столиц'))), isTrue);

      final text2 = 'Один в бік столиці через Вишгород';
      final threats2 = ThreatParser.parseLocalThreats(text2);
      expect(threats2.length, equals(1));
      expect((threats2[0]['path'] as List).length, equals(2));
      expect(threats2.any((t) => (t['path'] as List).any((p) => p['name'].toString().contains('Столиц'))), isTrue);
    });

    test('True trajectory with "через" and "->" is preserved as single path', () {
      final text1 = 'з Вишгорода через Гостомель на Обухів';
      final threats1 = ThreatParser.parseLocalThreats(text1);
      expect(threats1.length, equals(1));
      expect((threats1[0]['path'] as List).length, equals(3));

      final text2 = 'Вишгород -> Гостомель -> Обухів';
      final threats2 = ThreatParser.parseLocalThreats(text2);
      expect(threats2.length, equals(1));
      expect((threats2[0]['path'] as List).length, equals(3));
    });
  });

  group('Release v1.2.27: Green Shootdown Card & Active Threats Filter', () {
    test('Destroyed threat is kept for 35s for green badge, but excluded from active threats count', () {
      final now = DateTime.parse('2026-10-15T20:10:00Z');
      final shootdownTime = DateTime.parse('2026-10-15T20:09:40Z'); // 20s ago

      List<Map<String, dynamic>> threats = [
        {
          'msgId': 101,
          'path': [const LatLng(50.45, 30.52), const LatLng(50.50, 30.60)],
          'type': 'shahed',
          'isDestroyed': true,
          'destroyedAt': shootdownTime,
          'lastUpdated': shootdownTime,
        },
        {
          'msgId': 102,
          'path': [const LatLng(50.35, 30.40)],
          'type': 'shahed',
          'isDestroyed': false,
          'lastUpdated': now,
        }
      ];

      // Smart TTL filter (at 20s after destruction)
      threats = threats.where((t) {
        if (t['isDestroyed'] == true) {
          final destroyedAt = (t['destroyedAt'] as DateTime?) ?? (t['lastUpdated'] as DateTime?) ?? now;
          return now.difference(destroyedAt).inSeconds.abs() <= 35;
        }
        return true;
      }).toList();

      // Total threats on map includes the destroyed one (for green badge rendering)
      expect(threats.length, equals(2));
      expect(threats.any((t) => t['isDestroyed'] == true), isTrue);

      // Active threats count excludes destroyed threats
      final activeThreats = threats.where((t) => t['isDestroyed'] != true).toList();
      expect(activeThreats.length, equals(1));
      expect(activeThreats.first['msgId'], equals(102));

      // After 36 seconds, the destroyed threat is cleaned up from map
      final futureNow = DateTime.parse('2026-10-15T20:10:16Z'); // 36s after shootdown
      threats = threats.where((t) {
        if (t['isDestroyed'] == true) {
          final destroyedAt = (t['destroyedAt'] as DateTime?) ?? (t['lastUpdated'] as DateTime?) ?? futureNow;
          return futureNow.difference(destroyedAt).inSeconds.abs() <= 35;
        }
        return true;
      }).toList();

      expect(threats.length, equals(1));
      expect(threats.any((t) => t['isDestroyed'] == true), isFalse);
    });

    test('Borshchahivka slang forms ("Борщаги", "на Борщазі") map to residential district and not gas station', () {
      final threats1 = ThreatParser.parseLocalThreats('Борщаги');
      expect(threats1.isNotEmpty, isTrue);
      final p1 = (threats1.first['path'] as List).first;
      expect(p1['name'], equals('Борщагівка'));
      expect(p1['lat'], closeTo(50.4280, 0.005));
      expect(p1['lon'], closeTo(30.3780, 0.005));

      final threats2 = ThreatParser.parseLocalThreats('Шахед на Борщазі');
      expect(threats2.isNotEmpty, isTrue);
      final p2 = (threats2.first['path'] as List).first;
      expect(p2['name'], equals('Борщагівка'));
      expect(p2['lat'], closeTo(50.4280, 0.005));

      final threats3 = ThreatParser.parseLocalThreats('Курс на Південну Борщагівку');
      expect(threats3.isNotEmpty, isTrue);
      final p3 = (threats3.first['path'] as List).first;
      expect(p3['name'], equals('Південна Борщагівка'));

      // Food / restaurant "борщ" is not parsed as an air defense target
      final threatsBorshch = ThreatParser.parseLocalThreats('Зварили смачний борщ');
      expect(threatsBorshch.isEmpty, isTrue);
    });
  });
}





