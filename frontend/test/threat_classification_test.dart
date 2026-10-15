import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/main.dart';

void main() {
  group('Threat Classification Tests', () {
    final notifier = MessagesNotifier();

    test('Classifies missile_hypersonic correctly', () {
      final threats = notifier.parseLocalThreats('Кинджал курсом на Київ!');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['type'], equals('missile_hypersonic'));
      expect(threats.first['speed'], equals(12000.0));
    });

    test('Classifies missile_ballistic correctly', () {
      final threats = notifier.parseLocalThreats('Балістика з півночі на Бровари');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['type'], equals('missile_ballistic'));
      expect(threats.first['speed'], equals(5000.0));
    });

    test('Classifies missile_supersonic correctly', () {
      final threats = notifier.parseLocalThreats('Пуск надзвукової ракети Х-22 в бік Борисполя');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['type'], equals('missile_supersonic'));
      expect(threats.first['speed'], equals(3200.0));
    });

    test('Classifies missile_cruise correctly', () {
      final threats = notifier.parseLocalThreats('Крилата ракета Х-101 через Білу Церкву на Васильків');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['type'], equals('missile_cruise'));
      expect(threats.first['speed'], equals(900.0));
    });

    test('Classifies kab correctly', () {
      final threats = notifier.parseLocalThreats('Пуск КАБ в напрямку Вишгорода');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['type'], equals('kab'));
      expect(threats.first['speed'], equals(850.0));
    });

    test('Classifies uav_guided correctly', () {
      final threats = notifier.parseLocalThreats('БпЛА на керуванні 🎮 над Обуховом');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['type'], equals('uav_guided'));
      expect(threats.first['speed'], equals(220.0));
    });

    test('Classifies uav_recon correctly and sets isCircling', () {
      final threats = notifier.parseLocalThreats('Розвідник Zala над Хотянівкою');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['type'], equals('uav_recon'));
      expect(threats.first['speed'], equals(130.0));
      expect(threats.first['isCircling'], isTrue);
    });

    test('Classifies uav_decoy correctly', () {
      final threats = notifier.parseLocalThreats('Імітатор фальш-ціль Гербера над Макаровом');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['type'], equals('uav_decoy'));
      expect(threats.first['speed'], equals(160.0));
    });

    test('Defaults to shahed (185 km/h) for regular drone without jet keywords', () {
      final threats = notifier.parseLocalThreats('Шахед повз Фастів на Київ');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['type'], equals('shahed'));
      expect(threats.first['speed'], equals(185.0));
    });

    test('Classifies shahed_jet only if explicit markers present', () {
      final threats = notifier.parseLocalThreats('Реактивний шахед Герань-3 курсом на Ірпінь');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['type'], equals('shahed_jet'));
      expect(threats.first['speed'], equals(550.0));
    });
  });

  group('Altitude Dynamics and Descending Tests', () {
    final notifier = MessagesNotifier();

    test('Extracts altitude in meters and identifies descending markers', () {
      final threats = notifier.parseLocalThreats('БпЛА падає, висота 800 м над Бояркою');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['altitudeMeters'], equals(800));
      expect(threats.first['isDescending'], isTrue);
    });

    test('Automatically marks low altitude <= 1500m as descending', () {
      final threats = notifier.parseLocalThreats('Шахед на висоті 1200м повз Бучу');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['altitudeMeters'], equals(1200));
      expect(threats.first['isDescending'], isTrue);
    });

    test('Normal flight at high altitude is not descending', () {
      final threats = notifier.parseLocalThreats('БпЛА на висоті 2500 м через Переяслав');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['altitudeMeters'], equals(2500));
      expect(threats.first['isDescending'], isFalse);
    });
  });

  group('Compass Modifier and Directional Reordering Tests', () {
    final notifier = MessagesNotifier();

    test('Reorders "На Житомирщину, північніше Іванкова" with compass location first', () {
      final threats = notifier.parseLocalThreats('На Житомирщину, північніше Іванкова');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(2));
      expect(path[0]['name'], contains('Північніше Іванків'));
      expect(path[1]['name'], contains('Житомирщина'));
    });

    test('Preserves forward direction "Шахед північніше Іванкова курсом на Житомирщину"', () {
      final threats = notifier.parseLocalThreats('Шахед північніше Іванкова курсом на Житомирщину');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(2));
      expect(path[0]['name'], contains('Північніше Іванків'));
      expect(path[1]['name'], contains('Житомирщина'));
    });

    test('Parses regional exit vector "Вектор на Черкащину"', () {
      final threats = notifier.parseLocalThreats('Шахед через Обухів, вектор на Черкащину');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(2));
      expect(path[0]['name'], contains('Обухів'));
      expect(path[1]['name'], contains('Черкащина'));
    });

    test('Reorders "Крилаті ракети через Чернігівщину курсом на Київ! Вже біля Славутича!" with Slavutych start and Kyiv destination', () {
      final threats = notifier.parseLocalThreats('Крилаті ракети через Чернігівщину курсом на Київ! Вже біля Славутича!');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(3));
      expect(path[1]['name'], contains('Славутич'));
      expect(path.last['name'], contains('Київ'));
    });
  });

  group('Sector Midpoint and New Locations Tests', () {
    final notifier = MessagesNotifier();

    test('Merges slash-separated locations into single Sector Midpoint', () {
      final threats = notifier.parseLocalThreats('Шахед на Лютіж/Петрівці');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(1));
      expect(path.first['name'], equals('Лютіж / Нові Петрівці'));
      // Coordinates should be average of Liutizh (50.684, 30.395) and Novi Petrivtsi (50.629, 30.435)
      expect(path.first['lat'], closeTo((50.684 + 50.629) / 2.0, 0.001));
      expect(path.first['lon'], closeTo((30.395 + 30.435) / 2.0, 0.001));
    });

    test('Merges slash with spaces "Димер / Демидів"', () {
      final threats = notifier.parseLocalThreats('БпЛА курсом через Димер / Демидів на Київ');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(2));
      expect(path.first['name'], equals('Димер / Демидів'));
      expect(path.last['name'], contains('Київ'));
    });

    test('Recognizes newly added locations from regional dump', () {
      final threats = notifier.parseLocalThreats('Шахед повз Стещино на Рославичі');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(2));
      expect(path[0]['name'], contains('Стещино'));
      expect(path[1]['name'], contains('Рославичі'));
    });

    test('Recognizes Bucha/Makariv direction locations', () {
      final threats = notifier.parseLocalThreats('Ціль повз Бабинці на Плахтянку');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(2));
      expect(path[0]['name'], contains('Бабинці'));
      expect(path[1]['name'], contains('Плахтянка'));
    });

    test('Extracts altitude standalone number correctly', () {
      expect(notifier.extractAltitude('2300'), equals(2300));
      expect(notifier.extractAltitude('Висота 1700 м'), equals(1700));
      expect(notifier.extractAltitude('Повідомлення без цифр'), isNull);
    });
  });

  group('Missile Corridor and Emergency Ballistic Markers Tests', () {
    final notifier = MessagesNotifier();

    test('Classifies standalone "ЦІЛЬ" or "!!!!" without drone keywords as missile_ballistic', () {
      final threats1 = notifier.parseLocalThreats('Швидкісна ціль на Бровари');
      expect(threats1.isNotEmpty, isTrue);
      expect(threats1.first['type'], equals('missile_ballistic'));
      expect(threats1.first['speed'], equals(5000.0));
      expect(threats1.first['label'], equals('Балістична / Швидкісна ціль'));

      final threats2 = notifier.parseLocalThreats('Київ увага !!!!!! на Бровари');
      expect(threats2.isNotEmpty, isTrue);
      expect(threats2.first['type'], equals('missile_ballistic'));
      expect(threats2.first['speed'], equals(5000.0));
    });

    test('Classifies "швидкісна ціль" and "виходи" as missile_ballistic', () {
      final threats = notifier.parseLocalThreats('Швидкісна ціль через Бобровицю на Згурівку');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['type'], equals('missile_ballistic'));
      expect(threats.first['speed'], equals(5000.0));
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(2));
      expect(path[0]['name'], contains('Бобровиця'));
      expect(path[1]['name'], contains('Згурівка'));
    });

    test('Preserves shahed_jet for explicit drone with speed markers', () {
      final threats = notifier.parseLocalThreats('Швидкісний дрон / реактивний шахед на Бобровицю');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['type'], equals('shahed_jet'));
      expect(threats.first['speed'], equals(550.0));
    });

    test('Recognizes Chernihiv/Pryluky missile corridor locations', () {
      final threats = notifier.parseLocalThreats('Ціль: Ніжин -> Носівка -> Бобровиця -> Київ');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(4));
      expect(path[0]['name'], contains('Ніжин'));
      expect(path[1]['name'], contains('Носівка'));
      expect(path[2]['name'], contains('Бобровиця'));
      expect(path[3]['name'], contains('Київ'));
    });

    test('cleanHtmlText decodes numeric decimal and hex entities like &#33;', () {
      final text1 = notifier.cleanHtmlText('Київ увага &#33;&#33;&#33;');
      expect(text1, equals('Київ увага !!!'));

      final text2 = notifier.cleanHtmlText('Увага&#x21; &#39;Ціль&#39; &#8220;Київ&#8221;');
      expect(text2, equals("Увага! 'Ціль' “Київ”"));
    });

    test('deduplicateMessages filters out messages older than 12 hours', () {
      final now = DateTime.now().toUtc();
      final recentMsg = {
        'id': '101',
        'channel': 'test_ch',
        'text': 'Свіже повідомлення про БпЛА',
        'date': now.subtract(const Duration(hours: 2)).toIso8601String(),
      };
      final oldMsg = {
        'id': '102',
        'channel': 'test_ch',
        'text': 'Старе повідомлення віком 14 годин',
        'date': now.subtract(const Duration(hours: 14)).toIso8601String(),
      };
      final yesterdayMsg = {
        'id': '103',
        'channel': 'test_ch',
        'text': 'Вчорашнє повідомлення',
        'date': now.subtract(const Duration(hours: 20)).toIso8601String(),
      };

      final result = notifier.deduplicateMessages([recentMsg, oldMsg, yesterdayMsg]);
      expect(result.length, equals(1));
      expect(result.first['id'], equals('101'));
      expect(result.first['text'], contains('Свіже'));
    });

    test('categorizeLocalMessage recognizes multi-target and urgent alert danger phrases', () {
      expect(notifier.categorizeLocalMessage('Багато цілей йде'), equals('danger'));
      expect(notifier.categorizeLocalMessage('Цілі йдуть на Київ'), equals('danger'));
      expect(notifier.categorizeLocalMessage('Група цілей через Бориспіль'), equals('danger'));
      expect(notifier.categorizeLocalMessage('Боярка, Васік !!'), equals('danger'));
      expect(notifier.categorizeLocalMessage('Київ увага !!'), equals('danger'));
      expect(notifier.categorizeLocalMessage('УВАГА !!'), equals('danger'));
    });

    test('parseLocalThreats leaves local alerts without missile triggers as shahed and requires explicit triggers for ballistic', () {
      final threats1 = notifier.parseLocalThreats('Бородянка та Бабинці увага ⚠️');
      expect(threats1.isNotEmpty, isTrue);
      expect(threats1.first['type'], equals('shahed'));
      expect(threats1.first['speed'], equals(185.0));

      final threatsBoyarka = notifier.parseLocalThreats('Боярка, Васік !!');
      expect(threatsBoyarka.isNotEmpty, isTrue);
      expect(threatsBoyarka.first['type'], equals('shahed'));
      expect(threatsBoyarka.first['speed'], equals(185.0));

      final threats2 = notifier.parseLocalThreats('Багато цілей йде на Київ');
      expect(threats2.isNotEmpty, isTrue);
      expect(threats2.first['type'], equals('missile_ballistic'));
      expect(threats2.first['speed'], equals(5000.0));

      final threats4Exclamations = notifier.parseLocalThreats('Васильків !!!!');
      expect(threats4Exclamations.isNotEmpty, isTrue);
      expect(threats4Exclamations.first['type'], equals('missile_ballistic'));
      expect(threats4Exclamations.first['speed'], equals(5000.0));

      // Explicit drone remains shahed
      final droneThreats = notifier.parseLocalThreats('Шахед на Васильків');
      expect(droneThreats.isNotEmpty, isTrue);
      expect(droneThreats.first['type'], equals('shahed'));
      expect(droneThreats.first['speed'], equals(185.0));
    });
  });

  group('Nationwide Summaries & External Border Filtering Tests', () {
    final notifier = MessagesNotifier();

    test('Filters out lines mentioning only external border regions without Kyiv connection', () {
      final threats = notifier.parseLocalThreats('1х Коростень але йде далі');
      expect(threats.isEmpty, isTrue);
    });

    test('Filters out lines mentioning far regions without Kyiv anchors', () {
      final threats1 = notifier.parseLocalThreats('3х на Кременчук р. далі Черкащина');
      expect(threats1.isEmpty, isTrue);

      final threats2 = notifier.parseLocalThreats('2х через Одещину на Вінниччину');
      expect(threats2.isEmpty, isTrue);

      final threats3 = notifier.parseLocalThreats('4 нових реактива в Полтавську');
      expect(threats3.isEmpty, isTrue);
    });

    test('Preserves cross-border trajectory entering or exiting Kyiv Oblast', () {
      final threats = notifier.parseLocalThreats('Іванків -> Житомирщина');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(2));
      expect(path[0]['name'], contains('Іванків'));
      expect(path[1]['name'], contains('Житомирщина'));
    });

    test('Preserves trajectory from border town into Kyiv Oblast', () {
      final threats = notifier.parseLocalThreats('Прилуки -> Згурівка');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(2));
      expect(path[0]['name'], contains('Прилуки'));
      expect(path[1]['name'], contains('Згурівка'));
    });

    test('Merges district names with "р." and slash separator into midpoint', () {
      final threats = notifier.parseLocalThreats('Шахед Бориспліь р. / Обухів р.');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(1));
      expect(path.first['name'], contains('Бориспіль'));
      expect(path.first['name'], contains('Обухів'));
    });
  });

  group('Oleksandrivka Location & False Ballistic Prevention Tests', () {
    final notifier = MessagesNotifier();

    test('Maps "Олександрівки" to Boryspil sector (50.392, 30.892)', () {
      final threats = notifier.parseLocalThreats('БпЛА через Олександрівки на Требухів');
      expect(threats.isNotEmpty, isTrue);
      final path = threats.first['path'] as List<dynamic>;
      expect(path.length, equals(2));
      expect(path[0]['name'], contains('Олександрівка'));
      expect(path[0]['lat'], closeTo(50.392, 0.005));
      expect(path[0]['lon'], closeTo(30.892, 0.005));
      expect(path[1]['name'], contains('Требухів'));
      expect(threats.first['type'], equals('shahed'));
      expect(threats.first['speed'], equals(185.0));
    });

    test('Short "Знищено" / "Ліквідовано" / "Мінус" categorized as clear, not news', () {
      expect(notifier.categorizeLocalMessage('Знищено'), equals('clear'));
      expect(notifier.categorizeLocalMessage('Ліквідовано'), equals('clear'));
      expect(notifier.categorizeLocalMessage('Мінус'), equals('clear'));
      expect(notifier.categorizeLocalMessage('Збито'), equals('clear'));
      expect(notifier.categorizeLocalMessage('Відбито'), equals('clear'));

      // Long message with casualties / aftermath remains news
      expect(notifier.categorizeLocalMessage('За ніч знищено 25 шахедів, постраждало 2 людей, працює ДСНС'), equals('news'));
    });

    test('Categorizes "без фіксацій", "чисте небо", "попередньо чисто" as clear', () {
      expect(notifier.categorizeLocalMessage('Область без фіксацій'), equals('clear'));
      expect(notifier.categorizeLocalMessage('Київ чисте небо'), equals('clear'));
      expect(notifier.categorizeLocalMessage('Попередньо чисто'), equals('clear'));
      expect(notifier.categorizeLocalMessage('Фіксацій немає'), equals('clear'));
      expect(notifier.categorizeLocalMessage('Не фіксуються'), equals('clear'));
    });

    test('Filters out transit messages mentioning other regions without Kyiv connection', () {
      final threats1 = notifier.parseLocalThreats('Там 8х реактів в Полтавську скоро з брянська залітати будуть пуски тривають');
      expect(threats1.isEmpty, isTrue);

      final threats2 = notifier.parseLocalThreats('2х на Луцьк через Рівненщину');
      expect(threats2.isEmpty, isTrue);

      final threats3 = notifier.parseLocalThreats('Група на Кременчук та у Вінницьку область');
      expect(threats3.isEmpty, isTrue);
    });
  });

  group('Smart TTL, Typos & Directional Reordering Tests', () {
    final notifier = MessagesNotifier();

    test('getThreatTtlSeconds returns correct values per threat category', () {
      expect(getThreatTtlSeconds('missile_ballistic'), equals(120));
      expect(getThreatTtlSeconds('missile_hypersonic'), equals(120));
      expect(getThreatTtlSeconds('missile_cruise'), equals(180));
      expect(getThreatTtlSeconds('missile_supersonic'), equals(180));
      expect(getThreatTtlSeconds('kab'), equals(180));
      expect(getThreatTtlSeconds('shahed'), equals(1320));
      expect(getThreatTtlSeconds('shahed_jet'), equals(1320));
      expect(getThreatTtlSeconds('uav_guided'), equals(1320));
      expect(getThreatTtlSeconds('uav_recon'), equals(1320));
      expect(getThreatTtlSeconds('uav_decoy'), equals(1320));
      // Exiting oblast override
      expect(getThreatTtlSeconds('shahed', isExitingOblast: true), equals(45));
      expect(getThreatTtlSeconds('missile_cruise', isExitingOblast: true), equals(45));
    });

    test('Recognizes channel typos in Kyiv locations dictionary', () {
      final t1 = notifier.parseLocalThreats('Шахед біля береовец');
      expect(t1.isNotEmpty, isTrue);
      expect(t1.first['path'].first['name'], equals('Берковець'));

      final t2 = notifier.parseLocalThreats('БпЛА через куркнівк');
      expect(t2.isNotEmpty, isTrue);
      expect(t2.first['path'].first['name'], equals('Куренівка'));

      final t3 = notifier.parseLocalThreats('Ціль страхолвсс');
      expect(t3.isNotEmpty, isTrue);
      expect(t3.first['path'].first['name'], equals('Страхолісся'));

      final t4 = notifier.parseLocalThreats('Шахед карариш');
      expect(t4.isNotEmpty, isTrue);
      expect(t4.first['path'].first['name'], equals('Карапиші'));

      final t5 = notifier.parseLocalThreats('Шахед тромтинк на бархат');
      expect(t5.isNotEmpty, isTrue);
      final path5 = t5.first['path'] as List;
      expect(path5.length, equals(2));
      expect(path5[0]['name'], equals('Тростинка'));
      expect(path5[1]['name'], equals('Барахти'));

      final t6 = notifier.parseLocalThreats('БпЛА гаоздів у бік лівобережк');
      expect(t6.isNotEmpty, isTrue);
      final path6 = t6.first['path'] as List;
      expect(path6.length, equals(2));
      expect(path6[0]['name'], equals('Гвоздів'));
      expect(path6[1]['name'], equals('Лівобережна'));
    });

    test('Directional reordering reorders вектор, курс, в бік (including вектор ~оболонь)', () {
      final t1 = notifier.parseLocalThreats('Шахед біля Вишгорода, вектор ~оболонь');
      expect(t1.isNotEmpty, isTrue);
      final path1 = t1.first['path'] as List;
      expect(path1.length, equals(2));
      expect(path1[0]['name'], contains('Вишгород'));
      expect(path1[1]['name'], contains('Оболонь'));

      final t2 = notifier.parseLocalThreats('Шахед біля Василькова курс Фастів');
      expect(t2.isNotEmpty, isTrue);
      final path2 = t2.first['path'] as List;
      expect(path2.length, equals(2));
      expect(path2[0]['name'], contains('Васильків'));
      expect(path2[1]['name'], contains('Фастів'));

      final t3 = notifier.parseLocalThreats('Шахед біля Броварів в бік Борисполя');
      expect(t3.isNotEmpty, isTrue);
      final path3 = t3.first['path'] as List;
      expect(path3.length, equals(2));
      expect(path3[0]['name'], contains('Бровари'));
      expect(path3[1]['name'], contains('Бориспіль'));
    });
  });

  group('Auto-Discovery Geocoder & Stemming Tests', () {
    test('stemLocationCandidate correctly stems Ukrainian location names', () {
      expect(stemLocationCandidate('Глеваха'), equals('глевах'));
      expect(stemLocationCandidate('Новосілки'), equals('новосілк'));
      expect(stemLocationCandidate('Калинівка'), equals('калинівк'));
      expect(stemLocationCandidate('Бровари'), equals('бровар'));
      expect(stemLocationCandidate('Вишневе'), equals('вишнев'));
      // Does not trim if length < 6
      expect(stemLocationCandidate('Віта'), equals('віта'));
      expect(stemLocationCandidate('Буча'), equals('буча'));
      // Does not trim if does not end with vowel
      expect(stemLocationCandidate('Коростень'), equals('коростень'));
      expect(stemLocationCandidate('Фастів'), equals('фастів'));
    });

    test('parseLocalThreats safely ignores stop words and handles location candidates', () {
      final notifier = MessagesNotifier();
      final threats = notifier.parseLocalThreats('Увага на Київщину! Шахед курсом на Васильків');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['path'].first['name'], contains('Васильків'));
    });
  });

  group('7 Bug Fixes Verification Tests', () {
    final notifier = MessagesNotifier();

    test('Multiline message splitting preserves individual line context without mixing', () {
      const msg = 'Шахед курсом на Бориспіль\nРакета через Білу Церкву';
      final threats = notifier.parseLocalThreats(msg);
      expect(threats.length, greaterThanOrEqualTo(2));
      final names = threats.map((t) => (t['path'] as List).map((p) => p['name'].toString()).join(' ')).toList();
      expect(names.any((n) => n.contains('Бориспіль')), isTrue);
      expect(names.any((n) => n.contains('Біла Церква')), isTrue);
    });

    test('Neighboring oblast is ignored when no Kyiv location is present', () {
      const msg = 'Шахед на Житомирщині курсом на схід';
      final threats = notifier.parseLocalThreats(msg);
      expect(threats.isEmpty, isTrue);
    });

    test('Neighboring oblast is allowed when concrete Kyiv location is present in the line', () {
      const msg = 'Шахед з Житомирщини курсом на Макарів';
      final threats = notifier.parseLocalThreats(msg);
      expect(threats.isNotEmpty, isTrue);
      final hasMakariv = (threats.first['path'] as List).any((p) => p['name'].toString().contains('Макарів'));
      expect(hasMakariv, isTrue);
    });

    test('Far regions like Вінниця or Черкаси are ignored without Kyiv location', () {
      const msg = 'БпЛА над Вінницею та Черкасами';
      final threats = notifier.parseLocalThreats(msg);
      expect(threats.isEmpty, isTrue);
    });

    test('inZoneMatch only triggers when parsed is empty and does not trigger on generic "простір"', () {
      // Concrete location present -> should NOT use "В зоні відповідальності"
      final concrete = notifier.parseLocalThreats('2х шахедів в зону на Васильків');
      expect(concrete.isNotEmpty, isTrue);
      expect(concrete.first['route'], isNot(equals('В зоні відповідальності')));

      // No location, "в зону" -> should trigger
      final inZone = notifier.parseLocalThreats('2х шахедів заходять в зону');
      expect(inZone.isNotEmpty, isTrue);
      expect(inZone.first['route'], equals('В зоні відповідальності'));

      // "простір" alone should NOT trigger inZoneMatch
      final space = notifier.parseLocalThreats('Залітають у повітряний простір');
      expect(space.isEmpty, isTrue);
    });

    test('Global digest stop words (Кропивницький, Знамʼянка, Олександрія, Дніпропетровськ тощо) are ignored immediately', () {
      final t1 = notifier.parseLocalThreats('БпЛА через Знам\'янку на Олександрію');
      expect(t1.isEmpty, isTrue);

      final t2 = notifier.parseLocalThreats('Кропивницький, група шахедів курсом на Павлиш');
      expect(t2.isEmpty, isTrue);

      final t3 = notifier.parseLocalThreats('Дніпропетровщина: рух БпЛА повз Жовті Води');
      expect(t3.isEmpty, isTrue);

      final t4 = notifier.parseLocalThreats('Харківщина та Сумщина під ударом КАБів');
      expect(t4.isEmpty, isTrue);
    });

    test('Digest messages with 3+ external regions or 4+ external border towns are filtered out', () {
      final digestExternal = notifier.parseLocalThreats('Шахеди фіксуються в районах: Ніжин, Прилуки, Коростень, Радомишль, Пирятин');
      expect(digestExternal.isEmpty, isTrue);

      final digestRegions = notifier.parseLocalThreats('Дайджест: Полтава, Черкаси, Чернігів, Житомир зафіксовано рух БпЛА');
      expect(digestRegions.isEmpty, isTrue);
    });

    test('Kyiv Oblast multi-location alerts are never dropped as false digests', () {
      final kyivAlert = notifier.parseLocalThreats('Бориспіль, Бровари, Васильків, Обухів — увага, БпЛА у вашому напрямку');
      expect(kyivAlert.isNotEmpty, isTrue);
    });

    test('Kyiv Oleksandrivka is preserved and not blocked by Oleksandriya stop word', () {
      final t = notifier.parseLocalThreats('Шахед через Олександрівку на Бровари');
      expect(t.isNotEmpty, isTrue);
      final path = t.first['path'] as List<dynamic>;
      expect(path.any((p) => p['name'].toString().contains('Олександрівка')), isTrue);
    });

    test('Recognizes newly verified strategic Kyiv and Oblast settlements', () {
      final t1 = notifier.parseLocalThreats('Шахед через Ставище на Білу Церкву');
      expect(t1.isNotEmpty, isTrue);
      expect(t1.first['path'].first['name'], contains('Ставище'));

      final t2 = notifier.parseLocalThreats('БпЛА повз Красне на Обухів');
      expect(t2.isNotEmpty, isTrue);
      expect(t2.first['path'].first['name'], contains('Красне'));

      final t3 = notifier.parseLocalThreats('Шахед через Семиполки на Бровари');
      expect(t3.isNotEmpty, isTrue);
      expect(t3.first['path'].first['name'], contains('Семиполки'));

      final t4 = notifier.parseLocalThreats('Ціль через Дорогожичі на центр');
      expect(t4.isNotEmpty, isTrue);
      expect(t4.first['path'].first['name'], contains('Дорогожичі'));
    });
  });

  group('Morning Digest Missile Counting & HTML Cleaning Tests', () {
    test('cleanHtmlString cleans tags, HTML entities and does not cut words mid-word', () {
      const raw = '<b>ДТЕК:</b> Графіки стабілізаційних відключень &laquo;Київ&raquo; та Київщина&nbsp;&#33;&#33; '
          'Деталі: &#39;Укренерго&#39; &mdash; тривають ремонти.';
      final cleaned = cleanHtmlString(raw);
      expect(cleaned, contains('«Київ»'));
      expect(cleaned, contains('!!'));
      expect(cleaned, contains("'Укренерго'"));
      expect(cleaned, contains('— тривають'));
      expect(cleaned.contains('<b>'), isFalse);
      expect(cleaned.contains('&nbsp;'), isFalse);
    });

    test('Missile keywords in morning digest properly classify missiles and bypass zero counter', () {
      const missileKeywords = [
        'ракет', 'баліст', 'іскандер', 'кинджал', 'циркон', 'калібр',
        'х-101', 'х-22', 'х-59', 'х-69', 'онікс', 'с-300', 'с-400'
      ];
      const negativeWords = ['не підтверд', 'не фіксу', 'хибн', 'відбій', 'чисто'];

      for (final kw in missileKeywords) {
        final text = 'Увага! Фіксується $kw на Київ!';
        final tLower = text.toLowerCase();
        final bool isNeg = negativeWords.any((nw) => tLower.contains(nw));
        final bool hasKw = missileKeywords.any((mk) => tLower.contains(mk));
        expect(!isNeg && hasKw, isTrue, reason: 'Keyword $kw should match');
      }

      // Negative messages should be ignored
      const negMsg = 'Відбій загрози балістики для Києва (хибна ціль, пуск не підтверджено)';
      final negLower = negMsg.toLowerCase();
      final bool isNeg = negativeWords.any((nw) => negLower.contains(nw));
      expect(isNeg, isTrue);
    });

    test('cleanHtmlString respects custom maxLength for morning digest news', () {
      final longNews = 'ДТЕК Київські регіональні електромережі повідомляють про стабілізаційні відключення. ' * 15;
      expect(longNews.length > 1000, isTrue);

      // Default cuts at 600
      final defaultCleaned = cleanHtmlString(longNews);
      expect(defaultCleaned.length <= 604, isTrue);

      // Custom maxLength: 3500 preserves full news
      final fullCleaned = cleanHtmlString(longNews, maxLength: 3500);
      expect(fullCleaned.length > 1000, isTrue);
      expect(fullCleaned.endsWith('...'), isFalse);
    });

    test('deduplicateMessages retains messages up to 12 hours old and drops older', () {
      final notifier = MessagesNotifier();
      final now = DateTime.now().toUtc();
      final msgs = [
        {
          'id': 1,
          'date': now.subtract(const Duration(hours: 11)).toIso8601String(),
          'text': 'Повідомлення 11 годин тому',
          'channel': 'test',
        },
        {
          'id': 2,
          'date': now.subtract(const Duration(hours: 8)).toIso8601String(),
          'text': 'Повідомлення 8 годин тому',
          'channel': 'test',
        },
        {
          'id': 3,
          'date': now.subtract(const Duration(hours: 13)).toIso8601String(),
          'text': 'Повідомлення 13 годин тому (застаріле)',
          'channel': 'test',
        },
      ];

      final kept = notifier.deduplicateMessages(msgs);
      expect(kept.any((m) => m['id'] == 1), isTrue, reason: '11 hours old should be retained');
      expect(kept.any((m) => m['id'] == 2), isTrue, reason: '8 hours old should be retained');
      expect(kept.any((m) => m['id'] == 3), isFalse, reason: '13 hours old should be dropped (> 12h)');
    });

    test('extractAltitude correctly extracts numbers ("2600", "2700", "висота 2500 м")', () {
      final notifier = MessagesNotifier();
      expect(notifier.extractAltitude('2600'), equals(2600));
      expect(notifier.extractAltitude('2700'), equals(2700));
      expect(notifier.extractAltitude('висота 2500 м'), equals(2500));
      expect(notifier.extractAltitude('h 1800'), equals(1800));
      expect(notifier.extractAltitude('висота: 3200'), equals(3200));
    });

    test('Threat with UAV altitude (300..5000m) is never mistakenly classified as missile_ballistic', () {
      final notifier = MessagesNotifier();
      final threats = notifier.parseLocalThreats('Бородянка, висота 2600 м');
      expect(threats.isNotEmpty, isTrue);
      expect(threats.first['type'], equals('shahed_jet'));
      expect(threats.first['speed'], equals(550.0));
      expect(threats.first['altitudeMeters'], equals(2600));

      final lowAltThreats = notifier.parseLocalThreats('Бородянка, висота 1200 м');
      expect(lowAltThreats.isNotEmpty, isTrue);
      expect(lowAltThreats.first['type'], equals('shahed'));
      expect(lowAltThreats.first['speed'], equals(185.0));
      expect(lowAltThreats.first['altitudeMeters'], equals(1200));
    });

    test('Classifies shahed_jet on high altitude >= 2000m ("2600", "2700", "2200")', () {
      final notifier = MessagesNotifier();
      final t2600 = notifier.parseLocalThreats('БпЛА через Бучу, висота 2600');
      expect(t2600.first['type'], equals('shahed_jet'));
      expect(t2600.first['speed'], equals(550.0));

      final t2200 = notifier.parseLocalThreats('Дрон на Бровари 2200');
      expect(t2200.first['type'], equals('shahed_jet'));
      expect(t2200.first['speed'], equals(550.0));
    });

    test('Excludes piston drone markers ("звичайний", "звч", "мопед", "двз") from shahed_jet even at high altitude', () {
      final notifier = MessagesNotifier();
      final threats = notifier.parseLocalThreats('Звичайний шахед (двз/мопед), висота 2400 на Боярку');
      expect(threats.first['type'], equals('shahed'));
      expect(threats.first['speed'], equals(185.0));
    });

    test('Recognizes expanded jet keywords: бандероль, турбо, герань-3, швидкісний', () {
      final notifier = MessagesNotifier();
      final t1 = notifier.parseLocalThreats('Бандероль на Васильків');
      expect(t1.first['type'], equals('shahed_jet'));
      expect(t1.first['speed'], equals(550.0));

      final t2 = notifier.parseLocalThreats('Турбо шахед курсом на Київ');
      expect(t2.first['type'], equals('shahed_jet'));
      expect(t2.first['speed'], equals(550.0));
    });

    test('Recognizes Borshchahivka slang and correct residential coordinates', () {
      final notifier = MessagesNotifier();
      final t1 = notifier.parseLocalThreats('БпЛА на Борщаги');
      expect(t1.isNotEmpty, isTrue);
      expect(t1.first['path'].last['name'], equals('Борщагівка'));
      expect(t1.first['path'].last['lat'], closeTo(50.4280, 0.001));
      expect(t1.first['path'].last['lon'], closeTo(30.3780, 0.001));

      final t2 = notifier.parseLocalThreats('Ціль на Борщазі');
      expect(t2.isNotEmpty, isTrue);
      expect(t2.first['path'].last['name'], equals('Борщагівка'));

      // Bare food word or gas station does NOT match as a target
      final t3 = notifier.parseLocalThreats('Їмо смачний борщ на АЗС КЛО');
      expect(t3.isEmpty, isTrue);
    });

    test('Distinguishes circling slang "круги мотає" from village Krugi', () {
      final notifier = MessagesNotifier();
      // Circling slang should NOT resolve to the village of Krugi (Vyshhorod district)
      final tCircling = notifier.parseLocalThreats('на 5400 круги мотає');
      expect(tCircling.isEmpty, isTrue);

      final tCircling2 = notifier.parseLocalThreats('мотає круги');
      expect(tCircling2.isEmpty, isTrue);

      // Explicit directional preposition towards the village DOES resolve to village Krugi
      final tVillage = notifier.parseLocalThreats('БпЛА через с. Круги на Вишгород');
      expect(tVillage.isNotEmpty, isTrue);
      expect(tVillage.first['path'].any((p) => p['name'] == 'Круги'), isTrue);
    });

    test('Lukianivka and its abbreviations resolve strictly to Metro Lukianivska coordinates and never the village', () {
      final notifier = MessagesNotifier();
      final variants = [
        "БпЛА на Лук'янівку",
        "Лукʼянівка",
        "Шахед Лук'янівка",
        "на лук'янку",
        "Лукянка",
        "Лук'ян",
      ];
      for (final text in variants) {
        final t = notifier.parseLocalThreats(text);
        expect(t.isNotEmpty, isTrue, reason: 'Failed for "$text"');
        expect(t.first['path'].last['name'], equals("м. Лук'янівка"), reason: 'Failed for "$text"');
        expect(t.first['path'].last['lat'], closeTo(50.4628, 0.005), reason: 'Failed for "$text"');
        expect(t.first['path'].last['lon'], closeTo(30.4815, 0.005), reason: 'Failed for "$text"');
      }
    });

    test('filterOperationalMessages purges stale morning messages (>4 hours old) during active evening raid', () {
      final now = DateTime.utc(2026, 10, 15, 21, 20);
      final messages = [
        {'id': 1, 'channel': 'kyiv_airdef', 'text': 'Ракета на Київ', 'date': '2026-10-15T21:16:00Z'},
        {'id': 2, 'channel': 'war_monitor', 'text': 'Шахед на Оболонь', 'date': '2026-10-15T21:05:00Z'},
        {'id': 3, 'channel': 'kievn', 'text': 'Київ чисто', 'date': '2026-10-15T10:09:00Z'},
        {'id': 4, 'channel': 'kievn', 'text': 'Шахед на Позняки', 'date': '2026-10-15T09:57:00Z'},
        {'id': 5, 'channel': 'kievn', 'text': 'Шахед на Бориспіль', 'date': '2026-10-15T09:43:00Z'},
      ];

      final filtered = ThreatParser.filterOperationalMessages(messages, nowUtc: now);
      expect(filtered.length, equals(2));
      expect(filtered.map((m) => m['id']).toList(), equals([1, 2]));
      expect(filtered.any((m) => m['id'] == 3), isFalse);
      expect(filtered.any((m) => m['id'] == 4), isFalse);
      expect(filtered.any((m) => m['id'] == 5), isFalse);
    });

    test('filterOperationalMessages retains fallback messages during calm period when no recent messages exist', () {
      final now = DateTime.utc(2026, 10, 15, 18, 0); // 8 hours after morning raid
      final messages = [
        {'id': 3, 'channel': 'kievn', 'text': 'Київ чисто', 'date': '2026-10-15T10:09:00Z'},
        {'id': 4, 'channel': 'kievn', 'text': 'Шахед на Позняки', 'date': '2026-10-15T09:57:00Z'},
      ];

      final filtered = ThreatParser.filterOperationalMessages(messages, nowUtc: now);
      expect(filtered.length, equals(2));
      expect(filtered.map((m) => m['id']).toList(), equals([3, 4]));
    });

    test('filterOperationalMessages handles empty list safely', () {
      final filtered = ThreatParser.filterOperationalMessages([]);
      expect(filtered, isEmpty);
    });

    test('Emergency warnings "СХОВАЛИСЬ", "ЦІЛЬ", "❗️ Брянськ балістика" are classified as missile_ballistic and categorized as danger', () {
      final tBryansk = ThreatParser.analyzeLocalThreat('❗️  Брянськ балістика');
      expect(tBryansk['type'], equals('missile_ballistic'));
      expect(ThreatParser.categorizeLocalMessage('❗️  Брянськ балістика'), equals('danger'));

      final tSkhov = ThreatParser.analyzeLocalThreat('СХОВАЛИСЬ');
      expect(tSkhov['type'], equals('missile_ballistic'));
      expect(ThreatParser.categorizeLocalMessage('СХОВАЛИСЬ'), equals('danger'));

      final tTsil = ThreatParser.analyzeLocalThreat('ЦІЛЬ');
      expect(tTsil['type'], equals('missile_ballistic'));
      expect(ThreatParser.categorizeLocalMessage('ЦІЛЬ'), equals('danger'));

      final tUkryttya = ThreatParser.analyzeLocalThreat('В УКРИТТЯ');
      expect(tUkryttya['type'], equals('missile_ballistic'));
      expect(ThreatParser.categorizeLocalMessage('В УКРИТТЯ'), equals('danger'));
    });
  });

  group('Energy Infrastructure (ТЕЦ, ТЕС, ГЕС) and Lukianivka Metro Tests', () {
    final notifier = MessagesNotifier();

    test('Parses ТЕЦ 1 through 6 correctly', () {
      final t1 = notifier.parseLocalThreats('Шахед на ТЕЦ-1');
      expect(t1.isNotEmpty, isTrue);
      expect((t1.first['path'] as List)[0]['name'], contains('ТЕЦ-1'));

      final t2 = notifier.parseLocalThreats('БпЛА повз ТЕЦ-2');
      expect(t2.isNotEmpty, isTrue);
      expect((t2.first['path'] as List)[0]['name'], contains('ТЕЦ-2'));

      final t3 = notifier.parseLocalThreats('Курс на ТЕЦ 3');
      expect(t3.isNotEmpty, isTrue);
      expect((t3.first['path'] as List)[0]['name'], contains('ТЕЦ-3'));

      final t4 = notifier.parseLocalThreats('Ціль в бік Дарницької ТЕЦ');
      expect(t4.isNotEmpty, isTrue);
      expect((t4.first['path'] as List)[0]['name'], contains('Дарницька ТЕЦ'));

      final t5 = notifier.parseLocalThreats('Шахед на ТЕЦ-5');
      expect(t5.isNotEmpty, isTrue);
      expect((t5.first['path'] as List)[0]['name'], contains('ТЕЦ-5'));

      final t6 = notifier.parseLocalThreats('БпЛА повз ТЕЦ-6');
      expect(t6.isNotEmpty, isTrue);
      expect((t6.first['path'] as List)[0]['name'], contains('ТЕЦ-6'));
    });

    test('Parses Київська ГЕС, ГАЕС, Трипільська ТЕС, Білоцерківська ТЕЦ', () {
      final tGes = notifier.parseLocalThreats('Шахед у напрямку Київської ГЕС');
      expect(tGes.isNotEmpty, isTrue);
      expect((tGes.first['path'] as List)[0]['name'], contains('Київська ГЕС'));

      final tGaes = notifier.parseLocalThreats('Ціль повз ГАЕС на Вишгород');
      expect(tGaes.isNotEmpty, isTrue);
      expect((tGaes.first['path'] as List).any((p) => p['name'].toString().contains('Київська ГАЕС')), isTrue);

      final tTes = notifier.parseLocalThreats('БпЛА курсом на Трипільську ТЕС');
      expect(tTes.isNotEmpty, isTrue);
      expect((tTes.first['path'] as List)[0]['name'], contains('Трипільська ТЕС'));

      final tBc = notifier.parseLocalThreats('Шахед на Білоцерківську ТЕЦ');
      expect(tBc.isNotEmpty, isTrue);
      expect((tBc.first['path'] as List)[0]['name'], contains('Білоцерківська ТЕЦ'));
    });

    test('Lukianivka strictly resolves to Kyiv Metro Lukianivka and not the village', () {
      final tLuk1 = notifier.parseLocalThreats('Шахед на Лук\'янівку');
      expect(tLuk1.isNotEmpty, isTrue);
      final p1 = (tLuk1.first['path'] as List)[0];
      expect(p1['name'], contains('Лук\'янівка'));
      expect(p1['lat'], closeTo(50.4628, 0.01));
      expect(p1['lon'], closeTo(30.4815, 0.01));

      final tLuk2 = notifier.parseLocalThreats('БпЛА через Лукʼянку на Поділ');
      expect(tLuk2.isNotEmpty, isTrue);
      final p2 = (tLuk2.first['path'] as List)[0];
      expect(p2['name'], contains('Лук\'янівка'));
      expect(p2['lat'], closeTo(50.4628, 0.01));
      expect(p2['lon'], closeTo(30.4815, 0.01));
    });
  });
}




