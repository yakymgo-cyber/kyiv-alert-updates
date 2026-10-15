import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:frontend/data/kyiv_gazetteer.dart';
import 'package:frontend/models/alert_models.dart';

double _projectedForwardDistance(LatLng locPoint, LatLng pPrev, LatLng pLast, double maxDistanceMeters) {
  const distance = Distance();
  final double midLatRad = (pPrev.latitude + pLast.latitude + locPoint.latitude) / 3.0 * math.pi / 180.0;
  const double metersPerLat = 111132.95;
  final double metersPerLon = 111132.95 * math.cos(midLatRad);

  final double ax = pLast.longitude * metersPerLon;
  final double ay = pLast.latitude * metersPerLat;
  final double vx = (pLast.longitude - pPrev.longitude) * metersPerLon;
  final double vy = (pLast.latitude - pPrev.latitude) * metersPerLat;
  final double vLen = math.sqrt(vx * vx + vy * vy);
  if (vLen < 1.0) return distance.as(LengthUnit.Meter, locPoint, pLast);

  final double dirX = vx / vLen;
  final double dirY = vy / vLen;

  final double bx = ax + dirX * maxDistanceMeters;
  final double by = ay + dirY * maxDistanceMeters;

  final double cx = locPoint.longitude * metersPerLon;
  final double cy = locPoint.latitude * metersPerLat;

  final double abx = bx - ax;
  final double aby = by - ay;
  final double ab2 = abx * abx + aby * aby;

  final double acx = cx - ax;
  final double acy = cy - ay;
  final double t = (acx * abx + acy * aby) / ab2;
  final double clampedT = t.clamp(0.0, 1.0);
  final double projX = ax + clampedT * abx;
  final double projY = ay + clampedT * aby;
  final double dx = cx - projX;
  final double dy = cy - projY;
  return math.sqrt(dx * dx + dy * dy);
}

String _formatEta(double distanceMeters, double speedMs) {
  if (distanceMeters < 1500.0) {
    return 'НАД ВАМИ!';
  }
  if (speedMs <= 0.0) return '~? хв';
  final int etaSec = (distanceMeters / speedMs).round();
  final int mins = etaSec ~/ 60;
  final int secs = etaSec % 60;
  if (mins > 0) {
    return '~$mins хв $secs с';
  } else {
    return '~$secs с';
  }
}


int getThreatTtlSeconds(String rawType, {bool isExitingOblast = false}) {
  if (isExitingOblast) return 45;
  switch (rawType) {
    case 'missile_ballistic':
    case 'missile_hypersonic':
      return 120;
    case 'missile_cruise':
    case 'missile_supersonic':
    case 'kab':
      return 180;
    case 'shahed':
    case 'shahed_jet':
    case 'uav_guided':
    case 'uav_recon':
    case 'uav_decoy':
    default:
      return 1320; // 22 хвилини активного TTL на радарі (діапазон 20-25 хв)
  }
}


String cleanHtmlString(String html, {int maxLength = 600}) {
  final maxSafe = math.max(maxLength + 500, 4000);
  final safeHtml = html.length > maxSafe ? html.substring(0, maxSafe) : html;
  var text = safeHtml.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');
  text = text
      .replaceAll('&quot;', '"')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&apos;', "'")
      .replaceAll('&#39;', "'")
      .replaceAll('&#33;', '!')
      .replaceAll('&laquo;', '«')
      .replaceAll('&raquo;', '»')
      .replaceAll('&ndash;', '–')
      .replaceAll('&mdash;', '—')
      .replaceAll('&hellip;', '…')
      .replaceAll('&rsquo;', '’')
      .replaceAll('&lsquo;', '‘')
      .replaceAll('&rdquo;', '”')
      .replaceAll('&ldquo;', '“');
  text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    return (code != null && code > 0 && code <= 0x10FFFF) ? String.fromCharCode(code) : m.group(0)!;
  });
  text = text.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m.group(1)!, radix: 16);
    return (code != null && code > 0 && code <= 0x10FFFF) ? String.fromCharCode(code) : m.group(0)!;
  });
  // Видаляємо невидимі керівні та zero-width символи (захист від prompt/text injection)
  text = text.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\u200B-\u200F\uFEFF]'), '');
  text = text.replaceAll(RegExp(r'http\S+'), '');
  text = text.replaceAll(RegExp(r'@\w+'), '');

  const adMarkers = ['підписатись', 'наш резерв', 'надіслати новину', 'джерело', 'більше новин', 'реклама', 'зв\'язок з', 'підписка'];
  final cleanLines = <String>[];
  for (final line in text.split('\n')) {
    final lower = line.toLowerCase();
    if (adMarkers.any((m) => lower.contains(m))) continue;
    if (line.trim().isNotEmpty) cleanLines.add(line.trim());
  }
  final joined = cleanLines.join('\n');
  if (joined.length <= maxLength) return joined;
  final lastSpace = joined.lastIndexOf(' ', maxLength);
  final minThreshold = maxLength > 100 ? maxLength - 100 : maxLength;
  return (lastSpace > minThreshold) ? '${joined.substring(0, lastSpace)}...' : '${joined.substring(0, maxLength)}...';
}

String cleanHtmlText(String html, {int maxLength = 600}) => cleanHtmlString(html, maxLength: maxLength);



  int? _extractAltitude(String text) {
    final tLower = text.toLowerCase();
    final mExplicit = RegExp(r'(?:висот[аі]|h|alt)\s*[:=-]?\s*(\d{3,5})\b', caseSensitive: false).firstMatch(tLower);
    if (mExplicit != null) {
      final val = int.tryParse(mExplicit.group(1)!);
      if (val != null && val >= 100 && val <= 10000) return val;
      if (val != null && val > 10000) return null;
    }
    final m = RegExp(r'\b(\d{3,5})\s*(?:м|метр|m)(?![а-яіїєґa-z])', caseSensitive: false).firstMatch(tLower);
    if (m != null) {
      final val = int.tryParse(m.group(1)!);
      if (val != null && val >= 50 && val <= 10000) return val;
      if (val != null && val > 10000) return null;
    }
    final matches = RegExp(r'\b(\d{3,4})\b').allMatches(text);
    for (final match in matches) {
      final val = int.tryParse(match.group(1)!);
      if (val != null && val >= 300 && val <= 10000 && val % 10 == 0) {
        return val;
      }
    }
    return null;
  }

  
  Map<String, dynamic> _analyzeLocalThreat(String text, {int? altitudeMeters}) {
    final tLower = text.toLowerCase();

    final bool hasExplicitDrone = tLower.contains('шахед') ||
        tLower.contains('бпла') ||
        tLower.contains('мопед') ||
        tLower.contains('двз') ||
        tLower.contains('дрон') ||
        tLower.contains('геран');

    // Балістичний тригер: ТІЛЬКИ явні ракетні маркери, '!!!!' або суто ізольоване одне-два слова капсом ('УВАГА', 'ЦІЛЬ', 'ПУСК', 'ВИХОДИ', 'ШВИДКІСНА', 'БАЛІСТИКА') без населених пунктів
    final bool hasBallisticMarker = tLower.contains('швидкісна') ||
        tLower.contains('швидкісні') ||
        tLower.contains('виходи') ||
        tLower.contains('багато цілей') ||
        tLower.contains('цілей йде') ||
        tLower.contains('цілі йдуть') ||
        text.contains('!!!!') ||
        RegExp(r'^(?:УВАГА|ЦІЛЬ|ПУСК|ВИХОДИ|ШВИДКІСНА|БАЛІСТИКА)[!\s⚠️]*$').hasMatch(text.trim());

    // Якщо вказано висоту типову для БпЛА (300..10000 м) — це гарантовано не балістика
    final bool hasUavAltitude = (altitudeMeters != null && altitudeMeters >= 300 && altitudeMeters <= 10000);

    if (tLower.contains('каб') || tLower.contains('кар ') || tLower.contains('керован') || tLower.contains('уфаб')) {
      return {'type': 'kab', 'speed': 850.0, 'label': 'КАБ / КАР'};
    } else if (tLower.contains('на керуванні') || tLower.contains('🎮') || tLower.contains('сікер') || tLower.contains('оптичн') || tLower.contains('старлінк')) {
      return {'type': 'uav_guided', 'speed': 220.0, 'label': 'БпЛА на керуванні 🎮'};
    } else if (tLower.contains('розвідник') || tLower.contains('орлан') || tLower.contains('зала') || tLower.contains('zala') || tLower.contains('суперкам') || tLower.contains('supercam') || tLower.contains('ланцет')) {
      return {'type': 'uav_recon', 'speed': 130.0, 'label': 'РозвідБпЛА 👁️', 'isCircling': true};
    } else if (tLower.contains('пародія') || tLower.contains('гербера') || tLower.contains('імітатор') || tLower.contains('фальш') || tLower.contains('пінопласт')) {
      return {'type': 'uav_decoy', 'speed': 160.0, 'label': 'Імітатор / Фальш-ціль'};
    } else if (!hasUavAltitude) {
      if (tLower.contains('кинджал') || tLower.contains('циркон') || tLower.contains('гіперзвук')) {
        return {'type': 'missile_hypersonic', 'speed': 12000.0, 'label': 'Гіперзвукова ракета'};
      } else if (tLower.contains('баліст') || tLower.contains('іскандер') || tLower.contains('кн-23') || tLower.contains('kn-23') || tLower.contains('с-300') || tLower.contains('с-400') || tLower.contains('☄')) {
        return {'type': 'missile_ballistic', 'speed': 5000.0, 'label': 'Балістична / Швидкісна ціль'};
      } else if (!hasExplicitDrone && hasBallisticMarker) {
        return {'type': 'missile_ballistic', 'speed': 5000.0, 'label': 'Балістична / Швидкісна ціль'};
      } else if (tLower.contains('х-22') || tLower.contains('х-32') || tLower.contains('онікс') || tLower.contains('х-31') || tLower.contains('х-59') || tLower.contains('х-69')) {
        return {'type': 'missile_supersonic', 'speed': 3200.0, 'label': 'Надзвукова ракета (Х-22/Онікс)'};
      } else if (tLower.contains('крилат') || tLower.contains('х-101') || tLower.contains('калібр') || tLower.contains('іскандер-к') || (tLower.contains('ракет') && !tLower.contains('реактив'))) {
        return {'type': 'missile_cruise', 'speed': 900.0, 'label': 'Крилата ракета'};
      }
    }

    final bool hasPistonDrone = tLower.contains('звичайний') ||
        tLower.contains('звичайні') ||
        tLower.contains('звч') ||
        tLower.contains('не реактив') ||
        tLower.contains('двз') ||
        tLower.contains('мопед') ||
        tLower.contains('повільн');

    bool highAlt = (altitudeMeters != null && altitudeMeters >= 2000);
    if (!highAlt) {
      final altMatch = RegExp(r'(\d+(?:[.,]\d+)?)\s*(м|км)\b', caseSensitive: false).firstMatch(tLower);
      if (altMatch != null) {
        final val = double.tryParse(altMatch.group(1)!.replaceAll(',', '.')) ?? 0.0;
        final unit = altMatch.group(2)!.toLowerCase();
        if ((unit == 'км' && val >= 2.0) || (unit == 'м' && val >= 2000.0)) {
          highAlt = true;
        }
      }
    }

    final bool isJet = !hasPistonDrone && (
        tLower.contains('реактив') ||
        tLower.contains('реактів') ||
        tLower.contains('реакти') ||
        tLower.contains('реакт ') ||
        tLower.contains('швидкісн') ||
        tLower.contains('бандерол') ||
        tLower.contains('герань-3') ||
        tLower.contains('герань 3') ||
        tLower.contains('турбо') ||
        highAlt);

    if (isJet) {
      return {'type': 'shahed_jet', 'speed': 480.0, 'label': 'Реактивний БпЛА'};
    }
    return {'type': 'shahed', 'speed': 185.0, 'label': 'Ударний БпЛА (Шахед)'};
  }

  
  String _categorizeLocalMessage(String text) {
    final tLower = text.toLowerCase();
    const offtopic = ['футбол', 'матч', 'гол', 'рахунок', 'динамо', 'шахтар', 'збірна', 'пенальті', 'розіграш', 'реклама', 'спонсор'];
    if (offtopic.any((kw) => tLower.contains(kw))) return 'ignore';

    final bool isCasualtyOrAftermath = tLower.contains('загибл') ||
        tLower.contains('постраждал') ||
        tLower.contains('дснс') ||
        tLower.contains('пожеж') ||
        tLower.contains('уламк') ||
        tLower.contains('підсумки') ||
        tLower.contains('за ніч') ||
        tLower.contains('станом на');
    if (text.trim().length < 40 &&
        (tLower.contains('знищено') ||
         tLower.contains('ліквідован') ||
         tLower.contains('збито') ||
         tLower.contains('мінус') ||
         tLower.contains('відбито')) &&
        !isCasualtyOrAftermath) {
      return 'clear';
    }

    const news = ['відомо про', 'загибл', 'постраждал', 'внаслідок', 'наслідк', 'відбито', 'знищено', 'пошкоджен', 'зведення', 'підсумки', 'станом на', 'уламк', 'пожеж', 'жертв', 'ліквідован', 'врятован', 'на місці', 'дснс'];
    if (news.any((kw) => tLower.contains(kw))) return 'news';

    const clear = [
      'відбій', 'зелений', 'безпек', 'дорозвідка', 'чисто', 'локаційно', 'втрачено',
      'не спостерігається', 'не фіксується', 'немає цілей', 'без фіксаці', 'фіксацій немає',
      'не фіксуються', 'чисте небо', 'попередньо чисто', 'все походу', 'та все, нема', 'нема вже',
      'немає', 'нема', 'зникло', 'зник', 'чисто по',
    ];
    if (clear.any((kw) => tLower.contains(kw)) || dynamicClearKeywords.any((kw) => tLower.contains(kw))) return 'clear';

    const danger = [
      'вибух', 'ракет', 'шахед', 'баліст', 'бпла', 'мопед', 'пуск', 'сікер', 'реактив',
      'бандерол', 'зниження', '🎮', '🅿️', '🛵', '☄', 'розворот', 'в бік', 'далі на',
      'курс', 'коло ріже', 'скинув висоту', 'точка входу', 'міг', 'mig', 'кинджал', 'циркон',
      'звичайний', 'не реактив', 'ще один', 'напрямок', 'вектор', 'північніше', 'південніше',
      'західніше', 'східніше', 'розвернувся', 'звернув', 'падає',
      'ціль', 'швидкісна', 'швидкісні', 'виходи', 'прилуки', 'бобровиця', 'згурівк', 'штуки',
      'багато цілей', 'цілей йде', 'цілі йдуть', 'група цілей', 'увага !!', 'увага!!',
    ];
    if (danger.any((kw) => tLower.contains(kw)) ||
        dynamicDangerKeywords.any((kw) => tLower.contains(kw)) ||
        RegExp(r'^\s*\+\s*\S+').hasMatch(tLower) ||
        text.contains('!!!') ||
        (text.contains('!!') && text.trim().length <= 45)) {
      return 'danger';
    }

    if (tLower.contains('тривог') || tLower.contains('увага') || tLower.contains('укритт') || tLower.contains('сектор')) {
      return 'alert';
    }
    return 'info';
  }


  List<Map<String, dynamic>> _parseLocalThreats(String text) {
    // 1. Специфічні стоп-слова всеукраїнських зведень та інших регіонів
    const globalDigestStopWords = [
      'кроп', 'кропивницьк', 'знам\'ян', 'знамян', 'олександрі', 'павлиш', 
      'горішні плавні', 'омельник', 'лихівка', 'жовті води', 'карлівка', 
      'берестин', 'чутове', 'магдалинівк', 'кобеля', 'перещепин', 'долинськ',
      'устинівк', 'широке', 'кривий ріг', 'херсонщин', 'миколаївщин', 'запоріжж',
      'дніпропетров', 'харківщин', 'сумщин', 'донеччин', 'луганщин', 'одещин'
    ];

    final tLower = text.toLowerCase();
    final bool hasGlobalStopWord = globalDigestStopWords.any((sw) {
      if (sw == 'олександрі') {
        return tLower.contains('олександрі') && !tLower.contains('олександрів');
      }
      return tLower.contains(sw);
    });
    if (hasGlobalStopWord) {
      // Якщо це глобальне зведення іншого регіону — одразу повертаємо порожній список (ігноруємо)
      return [];
    }

    // 2. Фільтр на всеукраїнські та міжрегіональні дайджести
    // Якщо всі локації належать Київщині / Києву — НІКОЛИ не блокуємо
    final Set<String> externalMatches = {};
    for (final r in kFarRegions) {
      if (tLower.contains(r)) externalMatches.add(r);
    }
    for (final b in kExternalBorderKeys) {
      if (tLower.contains(b)) externalMatches.add(b);
    }

    final bool hasTrajectory = tLower.contains('->') || tLower.contains('—>') || tLower.contains('-->');
    if ((externalMatches.length >= 3 && !hasTrajectory) || externalMatches.length >= 4) {
      // Це зведення-простиня з багатьма зовнішніми регіонами — відсіюємо
      return [];
    }

    checkAndAutoGeocodeLocations(text);
    final globalAlt = _extractAltitude(text);
    final globalThreat = _analyzeLocalThreat(text, altitudeMeters: globalAlt);
    final textWithoutReply = text.replaceAll(RegExp(r'^↪️.*?\n'), '');
    final cleanLower = textWithoutReply.toLowerCase();

    final bool hasMultipleDrones = RegExp(r'(?:^|\s)(?:[1-9]\s*(?:х|x|шт)?|ще один|кілька|групи|декілька|шахеди|бпла|цілі)(?:\s|$)').hasMatch(cleanLower);
    final bool hasSplitters = textWithoutReply.contains(' та ') || textWithoutReply.contains(' і ') || textWithoutReply.contains(',');
    List<String> lines = [];
    for (final rawLine in textWithoutReply.split('\n')) {
      if (hasMultipleDrones && hasSplitters && !rawLine.toLowerCase().contains('через')) {
        lines.addAll(rawLine.replaceAll(' та ', '\n').replaceAll(' і ', '\n').replaceAll(',', '\n').split('\n'));
      } else {
        lines.add(rawLine);
      }
    }
    final List<Map<String, dynamic>> parsed = [];
    const negations = ['не йде', 'не летить', 'не фіксується', 'немає', 'відбій', 'чисто'];

    for (final line in lines) {
      final stripped = line.trim();
      if (stripped.isEmpty) continue;
      final lineLower = ' ${stripped.toLowerCase()} ';
      if (negations.any((n) => lineLower.contains(n))) continue;

      // 2. Фільтр сусідніх та далеких регіонів
      const neighborOblastKeys = {'житомирщин', 'чернігівщин', 'черкащин', 'вінниччин', 'полтавщин'};
      final bool hasNeighborOblast = neighborOblastKeys.any((r) => lineLower.contains(r));
      final bool hasFarRegion = kFarRegions.any((r) => lineLower.contains(r));

      // Для ключів сусідніх областей дозволяємо рядок ТІЛЬКИ тоді, коли в цьому ж самому рядку (line) є конкретне місто/село Київської області (не просто слово "київщина", а реальний населений пункт із kKyivLocations, що не входить у kExternalBorderKeys)
      final bool hasConcreteKyivLocInLine = kKyivLocations.keys.any((k) =>
        !kExternalBorderKeys.contains(k) &&
        k != 'київщин' &&
        lineLower.contains(k)
      );

      if (hasNeighborOblast && !hasConcreteKyivLocInLine) {
        continue;
      }
      if (hasFarRegion && !hasConcreteKyivLocInLine) {
        continue;
      }

      final headerCheck = stripped.toLowerCase().replaceAll(RegExp(r'[^а-яіїєґa-z]'), '');
      if (headerCheck == 'київщина' || headerCheck == 'київ' || headerCheck == 'київськаобласть' || headerCheck == 'київтаобласть') {
        continue;
      }

      final searchLine = lineLower.replaceAll(RegExp(r'київщин\w*|київськ\w*'), '        ');
      final List<(int, int, String, (double, double, String))> rawLocs = [];

      kKyivLocations.forEach((key, data) {
        int startPos = 0;
        while (true) {
          final idx = searchLine.indexOf(key, startPos);
          if (idx == -1) break;
          final isWordStart = (idx == 0 || !RegExp(r'[а-яіїєґa-z0-9]').hasMatch(searchLine[idx - 1]));
          if (isWordStart) {
            bool isFalseMatch = false;
            if (key == 'гора') {
              final prefix = searchLine.substring(math.max(0, idx - 15), idx).toLowerCase();
              if (prefix.contains('батиєв') || prefix.contains('черепанов')) {
                isFalseMatch = true;
              }
            } else if (key == 'море') {
              final prefix = searchLine.substring(math.max(0, idx - 10), idx).toLowerCase();
              if (prefix.contains('чорн')) {
                isFalseMatch = true;
              }
            }
            if (!isFalseMatch) {
              rawLocs.add((idx, idx + key.length, key, data));
            }
          }
          startPos = idx + key.length;
        }
      });

      if (rawLocs.isEmpty) continue;

      // 1. Жорстке правило прив'язки до Київщини (Border & Neighbor Regions Filter):
      final bool hasInternalKyivLoc = rawLocs.any((item) => !kExternalBorderKeys.contains(item.$3));
      if (!hasInternalKyivLoc) {
        continue;
      }

      // Фільтруємо перекриття: якщо один знайдений ключ є частиною іншого довшого збігу (наприклад, "житомир" всередині "житомирщину")
      final List<(int, int, String, (double, double, String))> locs = [];
      for (int i = 0; i < rawLocs.length; i++) {
        final a = rawLocs[i];
        bool isSubsumed = false;
        final lenA = a.$2 - a.$1;
        for (int j = 0; j < rawLocs.length; j++) {
          if (i == j) continue;
          final b = rawLocs[j];
          final lenB = b.$2 - b.$1;
          final bool overlaps = (a.$1 < b.$2 && b.$1 < a.$2);
          if (overlaps && (lenB > lenA || (lenB == lenA && j < i))) {
            isSubsumed = true;
            break;
          }
        }
        if (!isSubsumed) {
          locs.add(a);
        }
      }

      locs.sort((a, b) => a.$1.compareTo(b.$1));

      // Розумна обробка подвійних локацій через слеш "Локація1/Локація2" (Sector Midpoint)
      final List<(int, int, String, (double, double, String))> mergedLocs = [];
      int locIdx = 0;
      while (locIdx < locs.length) {
        if (locIdx + 1 < locs.length) {
          final a = locs[locIdx];
          final b = locs[locIdx + 1];
          if (a.$2 <= b.$1) {
            final between = searchLine.substring(a.$2, b.$1);
            if (RegExp(r'^[\sа-яіїєґa-z.\-]*\/[\sа-яіїєґa-z.\-]*$', caseSensitive: false).hasMatch(between)) {
              final lat = (a.$4.$1 + b.$4.$1) / 2.0;
              final lon = (a.$4.$2 + b.$4.$2) / 2.0;
              final name = '${a.$4.$3} / ${b.$4.$3}';
              mergedLocs.add((a.$1, b.$2, '${a.$3}/${b.$3}', (lat, lon, name)));
              locIdx += 2;
              continue;
            }
          }
        }
        mergedLocs.add((locs[locIdx].$1, locs[locIdx].$2, locs[locIdx].$3, locs[locIdx].$4));
        locIdx++;
      }

      final Set<String> addedNames = {};
      final List<Map<String, dynamic>> path = [];
      for (final item in mergedLocs) {
        final itemKey = item.$3;
        final data = item.$4;
        if (!addedNames.contains(data.$3)) {
          double lat = data.$1;
          double lon = data.$2;
          String displayName = data.$3;

          // Компасні модифікатори ("східніше", "західніше", "північніше", "південніше")
          final startIdx = math.max(0, item.$1 - 25);
          final endIdx = math.min(searchLine.length, item.$2 + 25);
          final surrounding = searchLine.substring(startIdx, endIdx);

          bool hasCompassModifier = false;
          if (surrounding.contains('східніш') || surrounding.contains('на схід')) {
            lon += 0.075;
            displayName = 'Східніше $displayName';
            hasCompassModifier = true;
          } else if (surrounding.contains('західніш') || surrounding.contains('на захід')) {
            lon -= 0.075;
            displayName = 'Західніше $displayName';
            hasCompassModifier = true;
          } else if (surrounding.contains('північніш') || surrounding.contains('на північ')) {
            lat += 0.045;
            displayName = 'Північніше $displayName';
            hasCompassModifier = true;
          } else if (surrounding.contains('південніш') || surrounding.contains('на південь')) {
            lat -= 0.045;
            displayName = 'Південніше $displayName';
            hasCompassModifier = true;
          }

          path.add({'name': displayName, 'lat': lat, 'lon': lon, 'hasCompass': hasCompassModifier, 'key': itemKey});
          addedNames.add(data.$3);
        }
      }

      // Directional reordering: "від/через/біля/район X" = start/transit, "на/курсом на/вектор на Y" = destination
      if (path.length >= 2) {
        Map<String, dynamic>? toItem;
        Map<String, dynamic>? fromItem;

        for (int pi = 0; pi < path.length; pi++) {
          final item = path[pi];
          final rawName = (item['name'] as String).toLowerCase();
          final locName = rawName.replaceAll(RegExp(r'^(північніше|південніше|західніше|східніше)\s+'), '');
          final cleanBase = locName.replaceAll(RegExp(r'\s*\([^)]*\)'), '').replaceAll('межа ', '').trim();

          final Set<String> searchStems = {};
          if (item['key'] != null) {
            final k = item['key'].toString().toLowerCase();
            searchStems.add(k);
            if (k.length > 5) searchStems.add(k.substring(0, k.length - 2));
          }
          if (cleanBase.isNotEmpty) {
            searchStems.add(cleanBase);
            searchStems.add(cleanBase.substring(0, math.min(4, cleanBase.length)));
          }
          if (locName.contains('водосховищ') || locName.contains('море')) {
            searchStems.add('водосховищ');
            searchStems.add('моря');
            searchStems.add('море');
          }
          if (locName.contains('черкащ')) {
            searchStems.add('черкас');
            searchStems.add('черкащ');
          }
          if (locName.contains('житомир')) searchStems.add('житомир');
          if (locName.contains('чернігів')) searchStems.add('чернігів');
          if (locName.contains('полтав')) searchStems.add('полтав');
          if (locName.contains('вінниц')) searchStems.add('вінниц');
          if (locName.contains('тетіїв')) searchStems.add('теті');
          if (locName.contains('трахтемир')) searchStems.add('трахтемир');

          bool matchedAsOrigin = false;
          for (final stem in searchStems) {
            if (stem.length < 3) continue;
            final fromPattern = RegExp(
              r'(?:від|з|із|з-під|виліт з|заходить з|через|повз|біля|вже біля|з району|в районі)\s+[~≈]?\s*(?:району?\s+)?\S*' + RegExp.escape(stem),
              caseSensitive: false,
            );
            final initialPosPattern = RegExp(
              r'(?:на|у|в)\s+\S*' + RegExp.escape(stem) + r'\S*\s+(?:\S+\s+){0,3}(?:в район|у район|на район|курсом(?:\s+на)?|вектор(?:ом)?(?:\s+на)?|у бік|в бік|у напрямку|в напрямку)\b',
              caseSensitive: false,
            );
            if (fromPattern.hasMatch(lineLower) || initialPosPattern.hasMatch(lineLower)) {
              fromItem ??= item;
              matchedAsOrigin = true;
              break;
            }
          }

          if (!matchedAsOrigin) {
            for (final stem in searchStems) {
              if (stem.length < 3) continue;
              final explicitToPattern = RegExp(
                r'(?:курсом(?:\s+на)?|курс(?:\s+на)?|вектором(?:\s+на)?|вектор(?:\s+на)?|у напрямку|в напрямку|у бік|в бік|на район|в район|у район|до)\s+[~≈]?\s*(?:району?\s+)?\S*' + RegExp.escape(stem),
                caseSensitive: false,
              );
              final generalToPattern = RegExp(
                r'(?:на|в|у)\s+[~≈]?\s*(?:району?\s+)?\S*' + RegExp.escape(stem),
                caseSensitive: false,
              );
              if (explicitToPattern.hasMatch(lineLower)) {
                toItem = item;
                break;
              } else if (generalToPattern.hasMatch(lineLower)) {
                toItem ??= item;
              }
            }
          }
        }

        if (fromItem != null && toItem != null && identical(fromItem, toItem)) {
          fromItem = null;
        }

        if (fromItem != null) {
          path.remove(fromItem);
          path.insert(0, fromItem);
        }

        final compassIdx = path.indexWhere((p) => p['hasCompass'] == true);
        if (compassIdx != -1 && toItem != null && path.indexOf(toItem) < compassIdx) {
          path.remove(toItem);
          path.add(toItem);
        } else if (toItem != null && path.indexOf(toItem) != path.length - 1) {
          path.remove(toItem);
          path.add(toItem);
        }
      }

      if (path.length >= 2 && path.last['name'] == 'Київ') {
        final p1 = path[path.length - 2];
        final p2 = path.last;
        double lat1 = p1['lat'];
        double lon1 = p1['lon'];
        double lat2 = p2['lat'];
        double lon2 = p2['lon'];

        double dLat = lat2 - lat1;
        double dLon = lon2 - lon1;
        double dist = math.sqrt(dLat * dLat + dLon * dLon);
        
        double kyivRadius = 0.13; 
        if (dist > kyivRadius) {
          double ratio = (dist - kyivRadius) / dist;
          p2['lat'] = lat1 + dLat * ratio;
          p2['lon'] = lon1 + dLon * ratio;
        }
      }

      final lineAlt = _extractAltitude(line) ?? globalAlt;
      final lineThreat = _analyzeLocalThreat(line, altitudeMeters: lineAlt);
      final bool isCircling = lineLower.contains('кружля') || lineLower.contains('крутить') || lineLower.contains('намоту') || (lineThreat['isCircling'] == true);
      final bool isDescending = lineLower.contains('зниження') || lineLower.contains('знижується') || lineLower.contains('падає') || lineLower.contains('пікірує') || lineLower.contains('низько') || (lineAlt != null && lineAlt <= 1500);

      final String? altitudeStr = lineAlt != null ? '$lineAlt м' : null;

      final match = RegExp(r"(?:^|[\s\W_])([1-9]|один|два|три|чотири|п'ять|шість|декілька|кілька)\s*(?:х|x|шт|штук|шт\.)?(?:\s|$)", caseSensitive: false).firstMatch(lineLower);
      int count = 1;
      if (match != null) {
        final qStr = match.group(1)!;
        if (qStr == 'декілька' || qStr == 'кілька') {
          count = 3;
        } else if (qStr == 'один') {
          count = 1;
        } else if (qStr == 'два') {
          count = 2;
        } else if (qStr == 'три') {
          count = 3;
        } else if (qStr == 'чотири') {
          count = 4;
        } else if (qStr == 'п\'ять') {
          count = 5;
        } else if (qStr == 'шість') {
          count = 6;
        } else {
          count = int.tryParse(qStr) ?? 1;
        }
      }
      
      final effectiveType = (lineThreat['type'] != null && lineThreat['type'] != 'shahed')
          ? lineThreat['type']
          : (globalThreat['type'] ?? 'shahed');
      final effectiveSpeed = (lineThreat['type'] != null && lineThreat['type'] != 'shahed')
          ? lineThreat['speed']
          : (globalThreat['speed'] ?? 185.0);
      final effectiveLabel = (lineThreat['type'] != null && lineThreat['type'] != 'shahed')
          ? lineThreat['label']
          : (globalThreat['label'] ?? _getDefaultThreatLabel(effectiveType));

      for (int c = 0; c < count; c++) {
        parsed.add({
          'type': effectiveType,
          'speed': effectiveSpeed,
          'label': effectiveLabel,
          'path': List<Map<String, dynamic>>.from(path),
          'isCircling': isCircling,
          'altitude': altitudeStr,
          'altitudeMeters': lineAlt,
          'isDescending': isDescending,
        });
      }
    }

    // 3. Блок "в зону" виконується ТІЛЬКИ якщо не знайдено жодного конкретного населеного пункту (parsed.isEmpty)
    if (parsed.isEmpty) {
      final inZoneMatch = RegExp(
        r'(?:^|[\s\W_])(?:([1-9]|кілька|багато)\s*(?:х|x|шт|штук|шт\.)?\s*)?(?:в|у)\s*(?:зону|відповідальність|наш сектор)',
        caseSensitive: false,
      ).firstMatch(tLower);
      if (inZoneMatch != null) {
        int quantity = 1;
        if (inZoneMatch.group(1) != null) {
          final qStr = inZoneMatch.group(1)!;
          if (qStr == 'кілька' || qStr == 'багато') {
            quantity = 3;
          } else {
            quantity = int.tryParse(qStr) ?? 1;
          }
        }
        for (int i = 0; i < quantity; i++) {
          parsed.add({
            'path': <LatLng>[],
            'route': 'В зоні відповідальності',
            'speed': globalThreat['speed'] ?? 185.0,
            'type': globalThreat['type'] ?? 'shahed',
            'label': globalThreat['label'] ?? 'Ударний БпЛА (Шахед)',
            'altitude': globalAlt != null ? '$globalAlt м' : null,
            'altitudeMeters': globalAlt,
            'isCircling': globalThreat['isCircling'] == true,
            'isDescending': globalAlt != null && globalAlt <= 1500,
          });
        }
      }
    }
    return parsed;
  }


  String _normalizeForDedup(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^а-яіїєґa-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  bool _isSimilarText(String normA, String normB) {
    if (normA.isEmpty || normB.isEmpty) return false;
    if (normA == normB) return true;
    if (normA.length >= 12 && normB.length >= 12) {
      if (normA.contains(normB) || normB.contains(normA)) return true;
      final wordsA = normA.split(' ').where((w) => w.length > 2).toSet();
      final wordsB = normB.split(' ').where((w) => w.length > 2).toSet();
      if (wordsA.length >= 3 && wordsB.length >= 3) {
        final intersection = wordsA.intersection(wordsB).length;
        final minLen = math.min(wordsA.length, wordsB.length);
        if (intersection / minLen >= 0.8) return true;
      }
    }
    return false;
  }

  List<dynamic> _deduplicateMessages(List<dynamic> rawMsgs) {
    final Set<String> seenIds = {};
    final List<dynamic> keptChronological = [];
    final List<String> keptNorms = [];
    final nowUtc = DateTime.now().toUtc();

    // Проходимо від старіших до новіших, щоб залишати першоджерело і відсікати повторні дублікати
    for (final msg in rawMsgs.reversed) {
      if (msg['date'] != null) {
        try {
          final msgTime = DateTime.parse(msg['date'].toString()).toUtc();
          if (nowUtc.difference(msgTime).inHours >= 12) {
            continue;
          }
        } catch (_) {}
      }

      final ch = (msg['channel'] ?? '').toString();
      final id = msg['id'];
      if (id != null && id != 0 && id != '0') {
        final idKey = '$ch:$id';
        if (seenIds.contains(idKey)) continue;
        seenIds.add(idKey);
      }

      final norm = _normalizeForDedup((msg['text'] ?? '').toString());
      if (norm.isEmpty) continue;

      bool isDup = false;
      final checkStart = keptNorms.length > 25 ? keptNorms.length - 25 : 0;
      for (int i = checkStart; i < keptNorms.length; i++) {
        if (_isSimilarText(norm, keptNorms[i])) {
          try {
            final timeA = DateTime.parse(msg['date'].toString());
            final timeB = DateTime.parse(keptChronological[i]['date'].toString());
            if (timeA.difference(timeB).inMinutes.abs() < 10) {
               isDup = true;
               break;
            }
          } catch (_) {
            isDup = true;
            break;
          }
        }
      }
      if (isDup) continue;

      // Розумна гео-дедуплікація (Geo-Deduplication) між різними каналами
      if (msg['date'] != null) {
        DateTime? msgTime;
        try {
          msgTime = DateTime.parse(msg['date'].toString()).toUtc();
        } catch (_) {}

        if (msgTime != null) {
          final List<Map<String, dynamic>> msgThreats = (msg['threats'] is List && (msg['threats'] as List).isNotEmpty)
              ? List<Map<String, dynamic>>.from(msg['threats'])
              : _parseLocalThreats((msg['text'] ?? '').toString());

          if (msgThreats.isNotEmpty) {
            const distanceCalc = Distance();
            final geoCheckStart = keptChronological.length > 25 ? keptChronological.length - 25 : 0;

            for (int i = keptChronological.length - 1; i >= geoCheckStart; i--) {
              final prevMsg = keptChronological[i];
              DateTime? prevTime;
              if (prevMsg['date'] != null) {
                try {
                  prevTime = DateTime.parse(prevMsg['date'].toString()).toUtc();
                } catch (_) {}
              }
              if (prevTime == null) continue;

              final int timeDiffSec = msgTime.difference(prevTime).inSeconds.abs();
              // Якщо повідомлення з іншого каналу вийшло з різницею у часі <= 120 секунд
              if (timeDiffSec <= 120) {
                final List<Map<String, dynamic>> prevThreats = (prevMsg['threats'] is List && (prevMsg['threats'] as List).isNotEmpty)
                    ? List<Map<String, dynamic>>.from(prevMsg['threats'])
                    : _parseLocalThreats((prevMsg['text'] ?? '').toString());

                if (prevThreats.isEmpty) continue;

                bool geoMatchFound = false;
                for (final tNew in msgThreats) {
                  final newType = (tNew['type'] ?? 'shahed').toString();
                  final newPath = tNew['path'] as List?;
                  if (newPath == null || newPath.isEmpty) continue;

                  final ptNew = newPath.first;
                  double latNew = 0.0;
                  double lonNew = 0.0;
                  if (ptNew is LatLng) {
                    latNew = ptNew.latitude;
                    lonNew = ptNew.longitude;
                  } else if (ptNew is Map) {
                    latNew = (ptNew['lat'] as num?)?.toDouble() ?? 0.0;
                    lonNew = (ptNew['lon'] as num?)?.toDouble() ?? 0.0;
                  }
                  if (latNew == 0.0 && lonNew == 0.0) continue;
                  final pNew = LatLng(latNew, lonNew);

                  for (final tPrev in prevThreats) {
                    final prevType = (tPrev['type'] ?? 'shahed').toString();
                    // Має такий самий тип загрози (наприклад, обидва shahed або обидва ракетні)
                    final bool sameType = (newType == prevType) ||
                        (newType.startsWith('shahed') && prevType.startsWith('shahed')) ||
                        (newType.contains('missile') && prevType.contains('missile'));
                    if (!sameType) continue;

                    final prevPath = tPrev['path'] as List?;
                    if (prevPath == null || prevPath.isEmpty) continue;
                    final ptPrev = prevPath.first;
                    double latPrev = 0.0;
                    double lonPrev = 0.0;
                    if (ptPrev is LatLng) {
                      latPrev = ptPrev.latitude;
                      lonPrev = ptPrev.longitude;
                    } else if (ptPrev is Map) {
                      latPrev = (ptPrev['lat'] as num?)?.toDouble() ?? 0.0;
                      lonPrev = (ptPrev['lon'] as num?)?.toDouble() ?? 0.0;
                    }
                    if (latPrev == 0.0 && lonPrev == 0.0) continue;
                    final pPrev = LatLng(latPrev, lonPrev);

                    // Координати в радіусі <= 6.0 км
                    final double distKm = distanceCalc.as(LengthUnit.Kilometer, pNew, pPrev);
                    if (distKm <= 6.0) {
                      geoMatchFound = true;
                      break;
                    }
                  }
                  if (geoMatchFound) break;
                }

                if (geoMatchFound) {
                  isDup = true;
                  // Об'єднуємо підпис джерела (наприклад, "Kyiv AirDefense / SK_DM_SK")
                  final prevCh = (prevMsg['channel'] ?? '').toString();
                  final newCh = (msg['channel'] ?? '').toString();
                  if (newCh.isNotEmpty && prevCh.isNotEmpty && !prevCh.contains(newCh)) {
                    if (prevMsg is Map) {
                      prevMsg['channel'] = '$prevCh / $newCh';
                    }
                  }
                  break;
                }
              }
            }
          }
        }
      }
      if (isDup) continue;

      keptChronological.add(msg);
      keptNorms.add(norm);
    }

    return keptChronological.reversed.toList();
  }


String _getDefaultThreatLabel(String type) {
  switch (type) {
    case 'missile_hypersonic': return 'Гіперзвукова ракета';
    case 'missile_ballistic': return 'Балістична / Швидкісна ціль';
    case 'missile_supersonic': return 'Надзвукова ракета (Х-22/Онікс)';
    case 'missile_cruise': return 'Крилата ракета';
    case 'kab': return 'КАБ / КАР';
    case 'uav_guided': return 'БпЛА на керуванні 🎮';
    case 'uav_recon': return 'РозвідБпЛА 👁️';
    case 'uav_decoy': return 'Імітатор / Фальш-ціль';
    case 'shahed_jet': return 'Реактивний БпЛА';
    case 'shahed':
    default: return 'Ударний БпЛА (Шахед)';
  }
}

double _getDefaultThreatSpeed(String type) {
  switch (type) {
    case 'missile_hypersonic': return 12000.0;
    case 'missile_ballistic': return 5000.0;
    case 'missile_supersonic': return 3200.0;
    case 'missile_cruise': return 900.0;
    case 'kab': return 850.0;
    case 'uav_guided': return 220.0;
    case 'uav_recon': return 130.0;
    case 'uav_decoy': return 160.0;
    case 'shahed_jet': return 480.0;
    case 'shahed':
    default: return 185.0;
  }
}

int _getThreatLevel(bool isAlert, bool isKyivRegion, List<Map<String, dynamic>> threats, {bool globalMissileThreat = false}) {
  if (!isAlert) return 1;
  bool hasMissiles = globalMissileThreat || threats.any((t) => 
      t['type'] == 'missile_ballistic' || 
      t['type'] == 'missile_hypersonic' || 
      t['type'] == 'missile_supersonic' ||
      t['type'] == 'missile_cruise' ||
      t['type'] == 'kab'
  );
  if (hasMissiles) return 3; 
  return 2; 
}

Color _getAlertFillColor(int threatLevel) {
  if (threatLevel == 3) return Colors.red.withValues(alpha: 0.45);
  if (threatLevel == 2) return const Color(0xFFF57C00).withValues(alpha: 0.45);
  return Colors.transparent;
}

Color _getAlertBorderColor(int threatLevel, {bool defaultFaint = true}) {
  if (threatLevel == 3) return Colors.redAccent.withValues(alpha: 0.9);
  if (threatLevel == 2) return const Color(0xFFF57C00).withValues(alpha: 0.9);
  return defaultFaint ? Colors.white.withValues(alpha: 0.1) : Colors.transparent;
}

double minDistanceToPointMeters(LatLng center, List<LatLng> path) {
  if (path.isEmpty) return double.infinity;
  const distance = Distance();
  if (path.length == 1) {
    return distance.as(LengthUnit.Meter, center, path.first);
  }

  double minDistance = double.infinity;
  for (int i = 0; i < path.length - 1; i++) {
    final p1 = path[i];
    final p2 = path[i + 1];

    final double midLatRad = (p1.latitude + p2.latitude + center.latitude) / 3.0 * math.pi / 180.0;
    const double metersPerLat = 111132.95;
    final double metersPerLon = 111132.95 * math.cos(midLatRad);

    final double ax = p1.longitude * metersPerLon;
    final double ay = p1.latitude * metersPerLat;
    final double bx = p2.longitude * metersPerLon;
    final double by = p2.latitude * metersPerLat;
    final double cx = center.longitude * metersPerLon;
    final double cy = center.latitude * metersPerLat;

    final double abx = bx - ax;
    final double aby = by - ay;
    final double ab2 = abx * abx + aby * aby;

    double segDist;
    if (ab2 < 1.0) {
      final double dcx = cx - ax;
      final double dcy = cy - ay;
      segDist = math.sqrt(dcx * dcx + dcy * dcy);
    } else {
      final double acx = cx - ax;
      final double acy = cy - ay;
      final double t = (acx * abx + acy * aby) / ab2;
      final double clampedT = t.clamp(0.0, 1.0);
      final double projX = ax + clampedT * abx;
      final double projY = ay + clampedT * aby;
      final double dx = cx - projX;
      final double dy = cy - projY;
      segDist = math.sqrt(dx * dx + dy * dy);
    }

    if (segDist < minDistance) {
      minDistance = segDist;
    }
  }
  return minDistance;
}


List<LatLng> _generateCirclePolygon(LatLng center, double radiusInMeters) {
  final List<LatLng> circle = [];
  const int points = 32;
  const double earthRadius = 6378137.0;
  final double lat = center.latitude * math.pi / 180.0;
  final double lng = center.longitude * math.pi / 180.0;
  final double d = radiusInMeters / earthRadius;

  for (int i = 0; i <= points; i++) {
    final double bearing = i * 2 * math.pi / points;
    final double targetLat = math.asin(math.sin(lat) * math.cos(d) + math.cos(lat) * math.sin(d) * math.cos(bearing));
    final double targetLng = lng + math.atan2(math.sin(bearing) * math.sin(d) * math.cos(lat), math.cos(d) - math.sin(lat) * math.sin(targetLat));
    circle.add(LatLng(targetLat * 180.0 / math.pi, targetLng * 180.0 / math.pi));
  }
  return circle;
}




  double _calculateBearing(LatLng from, LatLng to) {
    final double lat1 = from.latitude * math.pi / 180.0;
    final double lon1 = from.longitude * math.pi / 180.0;
    final double lat2 = to.latitude * math.pi / 180.0;
    final double lon2 = to.longitude * math.pi / 180.0;
    final double dLon = lon2 - lon1;
    final double y = math.sin(dLon) * math.cos(lat2);
    final double x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return math.atan2(y, x);
  }

  Polygon _buildForecastCone(LatLng currentPos, double bearing, double speedMs, Color color, bool isUav) {
    final double coneDistMeters = (speedMs * 150.0).clamp(1500.0, isUav ? 8000.0 : 25000.0);
    const double halfAngleRad = 16.0 * math.pi / 180.0;
    const double earthRadius = 6378137.0;
    final double d = coneDistMeters / earthRadius;
    final double lat1 = currentPos.latitude * math.pi / 180.0;
    final double lon1 = currentPos.longitude * math.pi / 180.0;

    final List<LatLng> conePoints = [currentPos];
    const int arcSegments = 8;
    for (int s = 0; s <= arcSegments; s++) {
      final double relAngle = -halfAngleRad + (2.0 * halfAngleRad * s / arcSegments);
      final double b = bearing + relAngle;
      final double lat2 = math.asin(math.sin(lat1) * math.cos(d) + math.cos(lat1) * math.sin(d) * math.cos(b));
      final double lon2 = lon1 + math.atan2(math.sin(b) * math.sin(d) * math.cos(lat1), math.cos(d) - math.sin(lat1) * math.sin(lat2));
      conePoints.add(LatLng(lat2 * 180.0 / math.pi, lon2 * 180.0 / math.pi));
    }
    conePoints.add(currentPos);

    return Polygon(
      points: conePoints,
      color: color.withValues(alpha: 0.10),
      borderColor: color.withValues(alpha: 0.35),
      borderStrokeWidth: 1.0,
    );
  }

  (LatLng, double) _calculateCirclingPosAndAngle(LatLng center, double timeSec) {
    const double iconRotationOffset = math.pi / 4; // Іконки дивляться праворуч-вгору (45°)
    final double omega = 2.0 * math.pi / 25.0; // Повний оберт за 25 секунд
    final double angle = omega * (timeSec % 25.0);

    // Радіус орбіти: ~2.5 км (0.016 lat, 0.026 lon)
    final double lat = center.latitude + 0.016 * math.sin(angle);
    final double lon = center.longitude + 0.026 * math.cos(angle);

    final double dyScreen = -0.016 * math.cos(angle);
    final double dxScreen = -0.026 * math.sin(angle);
    final double dxCorrected = math.cos(math.pi / 180.0 * center.latitude) * dxScreen;
    final double angleRad = math.atan2(dyScreen, dxCorrected);

    return (LatLng(lat, lon), angleRad + iconRotationOffset);
  }

  (LatLng, double) _interpolatePosAndAngle(List<LatLng> path, double fraction) {
    const double iconRotationOffset = math.pi / 4; // Іконки дивляться праворуч-вгору (45°)
    if (path.length == 1) {
      return (path.first, 0.0);
    }
    if (fraction >= 1.0) {
      LatLng center = path.last;
      double angleRad = 0.0;
      if (path.length >= 2) {
        final start = path[path.length - 2];
        final end = path.last;
        angleRad = math.atan2(start.latitude - end.latitude, math.cos(math.pi / 180.0 * start.latitude) * (end.longitude - start.longitude));
        return (center, angleRad + iconRotationOffset);
      }
      return (center, 0.0);
    }

    final clamped = fraction.clamp(0.0, 1.0);
    final totalSegments = path.length - 1;
    final exactSegment = clamped * totalSegments;
    final segIndex = exactSegment.floor().clamp(0, totalSegments - 1);
    final segFraction = exactSegment - segIndex;

    final start = path[segIndex];
    final end = path[segIndex + 1];
    final pos = LatLng(
      start.latitude + (end.latitude - start.latitude) * segFraction,
      start.longitude + (end.longitude - start.longitude) * segFraction,
    );

    final dyScreen = start.latitude - end.latitude;
    final dxScreen = end.longitude - start.longitude;
    final dxCorrected = math.cos(math.pi / 180.0 * start.latitude) * dxScreen;
    final angleRad = math.atan2(dyScreen, dxCorrected);

    return (pos, angleRad + iconRotationOffset);
  }



// Публічні аліаси функцій для експорту
List<dynamic> deduplicateMessages(List<dynamic> rawMsgs) => _deduplicateMessages(rawMsgs);
List<Map<String, dynamic>> parseLocalThreats(String text) => _parseLocalThreats(text);
int? extractAltitude(String text) => _extractAltitude(text);
Map<String, dynamic> analyzeLocalThreat(String text, {int? altitudeMeters}) => _analyzeLocalThreat(text, altitudeMeters: altitudeMeters);
String getSeverityForMessage(String text) => _categorizeLocalMessage(text);
String categorizeLocalMessage(String text) => _categorizeLocalMessage(text);
double calculateBearing(LatLng from, LatLng to) => _calculateBearing(from, to);
Polygon buildForecastCone(LatLng currentPos, double bearing, double speedMs, Color color, bool isUav) => _buildForecastCone(currentPos, bearing, speedMs, color, isUav);
(LatLng, double) calculateCirclingPosAndAngle(LatLng center, double timeSec) => _calculateCirclingPosAndAngle(center, timeSec);
(LatLng, double) interpolatePosAndAngle(List<LatLng> path, double fraction) => _interpolatePosAndAngle(path, fraction);
double projectedForwardDistance(LatLng locPoint, LatLng pPrev, LatLng pLast, double maxDistanceMeters) => _projectedForwardDistance(locPoint, pPrev, pLast, maxDistanceMeters);
String formatEta(double distanceMeters, double speedMs) => _formatEta(distanceMeters, speedMs);
String getDefaultThreatLabel(String type) => _getDefaultThreatLabel(type);
double getDefaultThreatSpeed(String type) => _getDefaultThreatSpeed(type);
int getThreatLevel(bool isAlert, bool isKyivRegion, List<Map<String, dynamic>> threats, {bool globalMissileThreat = false}) => _getThreatLevel(isAlert, isKyivRegion, threats, globalMissileThreat: globalMissileThreat);
Color getAlertFillColor(int threatLevel) => _getAlertFillColor(threatLevel);
Color getAlertBorderColor(int threatLevel, {bool defaultFaint = true}) => _getAlertBorderColor(threatLevel, defaultFaint: defaultFaint);
List<LatLng> generateCirclePolygon(LatLng center, double radiusInMeters) => _generateCirclePolygon(center, radiusInMeters);

StrategicLaunchEvent? detectStrategicLaunch(List<dynamic> messages, {DateTime? now}) => _detectStrategicLaunch(messages, now: now);

StrategicLaunchEvent? _detectStrategicLaunch(List<dynamic> messages, {DateTime? now}) {

  final currentTime = (now ?? DateTime.now()).toUtc();
  DateTime? latestClearTime;

  for (final m in messages) {
    final text = (m['text'] ?? '').toString().toLowerCase();
    final dateStr = m['date']?.toString();
    final mTime = (dateStr != null ? DateTime.tryParse(dateStr)?.toUtc() : null) ?? currentTime;
    if (currentTime.difference(mTime).inMinutes.abs() > 90) continue;
    if (text.contains('відбій по ракетах') ||
        text.contains('відбій загрози кр') ||
        text.contains('чисто по бортах') ||
        text.contains('відбій ту-95') ||
        text.contains('посадка бортів')) {
      if (latestClearTime == null || mTime.isAfter(latestClearTime)) {
        latestClearTime = mTime;
      }
    }
  }

  StrategicLaunchEvent? bestEvent;

  for (final m in messages) {
    final rawText = (m['text'] ?? '').toString();
    final text = rawText.toLowerCase();
    final dateStr = m['date']?.toString();
    final mTime = (dateStr != null ? DateTime.tryParse(dateStr)?.toUtc() : null) ?? currentTime;
    final diffMins = currentTime.difference(mTime).inMinutes.abs();
    if (diffMins > 90) continue;
    if (latestClearTime != null && latestClearTime.isAfter(mTime)) continue;

    // Ту-95МС / Х-101: ("пуски" | "пуск" | "маневр пуску") + ("ту-95" | "ту95" | "енгельс" | "каспій" | "оленегорськ" | "х-101")
    final bool hasLaunchTu = text.contains('пуски') ||
        text.contains('пуск ') ||
        text.contains('пуск!') ||
        text.contains('маневр пуску') ||
        text.contains('пускові маневри') ||
        text.contains('здійснено пуск');
    final bool hasTuTargets = text.contains('ту-95') ||
        text.contains('ту95') ||
        text.contains('енгельс') ||
        text.contains('каспій') ||
        text.contains('оленегорськ') ||
        text.contains('олень') ||
        text.contains('х-101') ||
        text.contains('х101');

    // Калібр: ("пуски" | "вихід") + ("калібр" | "чорного моря" | "новоросійськ")
    final bool hasLaunchKalibr = text.contains('пуски') ||
        text.contains('вихід') ||
        text.contains('пуск ') ||
        text.contains('пуск!') ||
        text.contains('залп');
    final bool hasKalibrTargets = text.contains('калібр') ||
        text.contains('чорного моря') ||
        text.contains('новоросійськ');

    StrategicLaunchEvent? event;
    if (hasLaunchTu && hasTuTargets) {
      event = StrategicLaunchEvent(
        type: 'Х-101 (Ту-95МС)',
        estimatedArrivalMinutes: 65,
        timestamp: mTime,
        rawText: rawText,
      );
    } else if (hasLaunchKalibr && hasKalibrTargets) {
      event = StrategicLaunchEvent(
        type: 'КРМБ «Калібр» (Море)',
        estimatedArrivalMinutes: 50,
        timestamp: mTime,
        rawText: rawText,
      );
    }

    if (event != null) {
      if (bestEvent == null || mTime.isAfter(bestEvent.timestamp)) {
        bestEvent = event;
      }
    }
  }

  return bestEvent;
}

class ThreatParser {
  static int? extractAltitude(String text) => _extractAltitude(text);
  static Map<String, dynamic> analyzeLocalThreat(String text, {int? altitudeMeters}) => _analyzeLocalThreat(text, altitudeMeters: altitudeMeters);
  static List<Map<String, dynamic>> parseLocalThreats(String text) => _parseLocalThreats(text);
  static String categorizeLocalMessage(String text) => _categorizeLocalMessage(text);
  static List<dynamic> deduplicateMessages(List<dynamic> rawMsgs) => _deduplicateMessages(rawMsgs);
  static StrategicLaunchEvent? detectStrategicLaunch(List<dynamic> messages, {DateTime? now}) => _detectStrategicLaunch(messages, now: now);
}



