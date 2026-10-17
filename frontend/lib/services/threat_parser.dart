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
      return 300; // 5 хвилин: Київ та область покриті датчиками — без фіксації 5 хв ціль вважається втраченою
    case 'uav_guided':
    case 'uav_recon':
    case 'uav_decoy':
    default:
      return 1320; // 22 хвилини активного TTL на радарі (діапазон 20-25 хв)
  }
}

/// Скільки секунд тримати знак питання на місці втрати фіксації (і шукати відновлення цілі)
const int kLostTrackRetentionSec = 600;

/// Базовий радіус невидимого кола пошуку відновлення (похибка геокодування районів), м
const double kLostTrackBaseRadiusMeters = 3000.0;

/// Типи цілей, для яких діє логіка втрати фіксації / знака питання / відновлення
bool isLostTrackableType(String rawType) => rawType == 'shahed' || rawType == 'shahed_jet';

/// Повний час життя цілі на мапі (с). Для шахедів — TTL (5 хв), але не раніше,
/// ніж ціль долетить до останньої точки свого маршруту (якщо маршрут довший за TTL).
int getThreatLifetimeSeconds(Map<String, dynamic> t) {
  final String typeStr = (t['type'] ?? '').toString();
  final bool isExiting = t['isExitingOblast'] == true;
  final int ttl = (t['ttl'] as int?) ?? getThreatTtlSeconds(typeStr, isExitingOblast: isExiting);
  if (isExiting || !isLostTrackableType(typeStr)) return ttl;

  final dynamic path = t['path'];
  if (path is! List || path.length < 2) return ttl;
  final dynamic a = path[path.length - 2];
  final dynamic b = path.last;
  if (a is! LatLng || b is! LatLng) return ttl;

  final double speedKmh = (t['speed'] as num?)?.toDouble() ?? 185.0;
  final double speedMs = speedKmh * (1000.0 / 3600.0);
  if (speedMs <= 0) return ttl;

  final double legMeters = const Distance().as(LengthUnit.Meter, a, b);
  final double stagger = (t['staggerDelay'] as num?)?.toDouble() ?? 0.0;
  final int routeSec = (legMeters / speedMs + stagger).ceil();
  return math.max(ttl, routeSec);
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
  // Нормалізуємо всі варіанти апострофів (iOS/macOS ʼ U+02BC, типографські ’ ‘ ´) до стандартного ASCII '
  text = text.replaceAll(RegExp(r'[\u02BC\u2019\u2018\u02B9\u00B4]'), "'");
  text = text.replaceAll(RegExp(r'http\S+'), '');
  text = text.replaceAll(RegExp(r'@\w+'), '');

  const adMarkers = [
    'підписатись', 'наш резерв', 'надіслати новину', 'джерело', 'більше новин', 'реклама', 'зв\'язок з', 'підписка',
    'monobank', 'send.monobank', 'приватбанк', 'банку', 'підтримку каналу', 'закинути на', '4441 1110', '5375 4141',
  ];
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

  int? _extractSpeed(String text) {
    final tLower = text.toLowerCase();
    final match = RegExp(
      r'(?:^|[^\wа-яіїєґ])(\d{2,4})\s*(?:км/год|км\\год|швидкість|швидк|шв)(?![а-яіїєґa-z0-9])|(?<![а-яіїєґa-z0-9])(?:швидкість|швидк|шв)\s*[:=-]?\s*(\d{2,4})(?![а-яіїєґa-z0-9])',
      caseSensitive: false,
    ).firstMatch(tLower);
    if (match != null) {
      final rawVal = match.group(1) ?? match.group(2);
      if (rawVal != null) {
        final val = int.tryParse(rawVal);
        if (val != null && val >= 60 && val <= 9500) {
          return val;
        }
      }
    }
    return null;
  }

  int? _extractAltitude(String text) {
    var tClean = text.toLowerCase();
    // 1) Видаляємо конструкції швидкості (включно з "459шв"), номери банківських карток та "750" (підстанція ПС 750 / на Бородянку 750)
    tClean = tClean.replaceAll(RegExp(r'\b\d{4}(?:[\s-]+\d{4}){3}\b'), '');
    tClean = tClean.replaceAll(RegExp(r'(?:^|[^\wа-яіїєґ])(\d{2,4})\s*(?:км/год|км\\год|швидкість|швидк|шв)(?![а-яіїєґa-z0-9])|(?<![а-яіїєґa-z0-9])(?:швидкість|швидк|шв)\s*[:=-]?\s*(\d{2,4})(?![а-яіїєґa-z0-9])', caseSensitive: false), ' ');
    tClean = tClean.replaceAll(RegExp(r'(?:або|бородянк[а-яіїєґa-z0-9]*|пс)\s+750(?:\s*кв)?(?![а-яіїєґa-z0-9])', caseSensitive: false), ' ');
    tClean = tClean.replaceAll(RegExp(r'\b750\s*(?:кв|кіловольт)\b', caseSensitive: false), ' ');

    final mExplicit = RegExp(r'(?:висот[аі]|h|alt)\s*[:=-]?\s*(\d{3,5})\b', caseSensitive: false).firstMatch(tClean);
    if (mExplicit != null) {
      final val = int.tryParse(mExplicit.group(1)!);
      if (val != null && val >= 100 && val <= 10000) return val;
      if (val != null && val > 10000) return null;
    }
    final m = RegExp(r'\b(\d{3,5})\s*(?:м|метр|m)(?![а-яіїєґa-z])', caseSensitive: false).firstMatch(tClean);
    if (m != null) {
      final val = int.tryParse(m.group(1)!);
      if (val != null && val >= 50 && val <= 10000) return val;
      if (val != null && val > 10000) return null;
    }
    final matches = RegExp(r'\b(\d{3,4})\b').allMatches(tClean);
    for (final match in matches) {
      final val = int.tryParse(match.group(1)!);
      if (val != null && val >= 300 && val <= 10000 && val % 10 == 0) {
        return val;
      }
    }
    return null;
  }

  
  Map<String, dynamic> _analyzeLocalThreat(String text, {int? altitudeMeters, int? speedKmh}) {
    final tLower = text.toLowerCase();
    final explicitSpeed = (speedKmh ?? _extractSpeed(text))?.toDouble();

    final bool hasExplicitDrone = tLower.contains('шахед') ||
        tLower.contains('бпла') ||
        tLower.contains('мопед') ||
        tLower.contains('двз') ||
        tLower.contains('дрон') ||
        tLower.contains('геран');

    // Балістичний тригер: ТІЛЬКИ явні ракетні маркери, '!!!!' або суто ізольоване одне-два слова капсом ('УВАГА', 'ЦІЛЬ', 'ПУСК', 'ВИХОДИ', 'ШВИДКІСНА', 'БАЛІСТИКА', 'СХОВАЛИСЬ', 'В УКРИТТЯ', 'УКРИТТЯ') без населених пунктів
    final bool hasBallisticMarker = tLower.contains('швидкісна') ||
        tLower.contains('швидкісні') ||
        tLower.contains('виходи') ||
        tLower.contains('багато цілей') ||
        tLower.contains('цілей йде') ||
        tLower.contains('цілі йдуть') ||
        tLower.contains('сховались') ||
        tLower.contains('в укриття') ||
        tLower.contains('укриття') ||
        (tLower.contains('брянськ') && tLower.contains('баліст')) ||
        (tLower.contains('курськ') && tLower.contains('баліст')) ||
        (tLower.contains('воронеж') && tLower.contains('баліст')) ||
        text.contains('!!!!') ||
        RegExp(r'^(?:УВАГА|ЦІЛЬ|ПУСК|ВИХОДИ|ШВИДКІСНА|БАЛІСТИКА|СХОВАЛИСЬ|В УКРИТТЯ|УКРИТТЯ)[!\s⚠️]*$', caseSensitive: false).hasMatch(text.trim());

    // Якщо вказано висоту типову для БпЛА (300..10000 м) — це гарантовано не балістика
    final bool hasUavAltitude = (altitudeMeters != null && altitudeMeters >= 300 && altitudeMeters <= 10000);

    if (tLower.contains('каб') || tLower.contains('кар ') || tLower.contains('керован') || tLower.contains('уфаб')) {
      return {'type': 'kab', 'speed': explicitSpeed ?? 850.0, 'label': 'КАБ / КАР'};
    } else if (tLower.contains('на керуванні') || tLower.contains('🎮') || tLower.contains('сікер') || tLower.contains('оптичн') || tLower.contains('старлінк')) {
      return {'type': 'uav_guided', 'speed': explicitSpeed ?? 220.0, 'label': 'БпЛА на керуванні 🎮'};
    } else if (tLower.contains('розвідник') || tLower.contains('орлан') || tLower.contains('зала') || tLower.contains('zala') || tLower.contains('суперкам') || tLower.contains('supercam') || tLower.contains('ланцет')) {
      return {'type': 'uav_recon', 'speed': explicitSpeed ?? 130.0, 'label': 'РозвідБпЛА 👁️', 'isCircling': true};
    } else if (tLower.contains('пародія') || tLower.contains('гербера') || tLower.contains('імітатор') || tLower.contains('фальш') || tLower.contains('пінопласт')) {
      return {'type': 'uav_decoy', 'speed': explicitSpeed ?? 160.0, 'label': 'Імітатор / Фальш-ціль'};
    } else if (!hasUavAltitude) {
      if (tLower.contains('кинджал') || tLower.contains('циркон') || tLower.contains('гіперзвук')) {
        return {'type': 'missile_hypersonic', 'speed': explicitSpeed ?? 12000.0, 'label': 'Гіперзвукова ракета'};
      } else if (tLower.contains('баліст') || tLower.contains('іскандер') || tLower.contains('кн-23') || tLower.contains('kn-23') || tLower.contains('с-300') || tLower.contains('с-400') || tLower.contains('☄')) {
        return {'type': 'missile_ballistic', 'speed': explicitSpeed ?? 5000.0, 'label': 'Балістична / Швидкісна ціль'};
      } else if (!hasExplicitDrone && hasBallisticMarker) {
        return {'type': 'missile_ballistic', 'speed': explicitSpeed ?? 5000.0, 'label': 'Балістична / Швидкісна ціль'};
      } else if (tLower.contains('х-22') || tLower.contains('х-32') || tLower.contains('онікс') || tLower.contains('х-31') || tLower.contains('х-59') || tLower.contains('х-69')) {
        return {'type': 'missile_supersonic', 'speed': explicitSpeed ?? 3200.0, 'label': 'Надзвукова ракета (Х-22/Онікс)'};
      } else if (tLower.contains('крилат') || tLower.contains('х-101') || tLower.contains('калібр') || tLower.contains('іскандер-к') || (tLower.contains('ракет') && !tLower.contains('реактив'))) {
        return {'type': 'missile_cruise', 'speed': explicitSpeed ?? 900.0, 'label': 'Крилата ракета'};
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
      return {'type': 'shahed_jet', 'speed': explicitSpeed ?? 550.0, 'label': 'Реактивний БпЛА'};
    }
    return {'type': 'shahed', 'speed': explicitSpeed ?? 185.0, 'label': 'Ударний БпЛА (Шахед)'};
  }

  
  String _categorizeLocalMessage(String rawText) {
    final text = rawText.replaceAll(RegExp(r'[\u02BC\u2019\u2018\u02B9\u00B4]'), "'");
    final tLower = text.toLowerCase();
    const offtopic = [
      'футбол', 'матч', 'гол', 'рахунок', 'динамо', 'шахтар', 'збірна', 'пенальті', 'розіграш', 'реклама', 'спонсор',
      'monobank', 'send.monobank', 'приватбанк', 'банку', 'підтримку каналу', 'закинути на', '4441 1110', '5375 4141',
    ];
    if (offtopic.any((kw) => tLower.contains(kw)) ||
        RegExp(r'\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b').hasMatch(text)) {
      return 'ignore';
    }

    // Блокування повітряних тривог інших областей (air_alert_ua хештеги)
    const externalDistrictHashtags = [
      '#харківський_район', '#дніпровський_район', '#камянський_район', '#кам\'янський_район',
      '#криворізький_район', '#синельниківський_район', '#павлоградський_район', '#новомосковський_район',
      '#чугуївський_район', '#ізюмський_район', '#богодухівський_район', '#лозівський_район',
      '#красноградський_район', '#сумський_район', '#охтирський_район', '#конотопський_район',
      '#шосткинський_район',
    ];
    final bool hasExtHashtag = externalDistrictHashtags.any((tag) => tLower.contains(tag));
    final bool hasExtPhrase = (tLower.contains('в харківський район') ||
        tLower.contains('у харківський район') ||
        tLower.contains('в дніпровський район') ||
        tLower.contains('у дніпровський район')) && !(tLower.contains('київ') || tLower.contains('києв'));
    if (hasExtHashtag || hasExtPhrase) return 'ignore';

    final bool isCasualtyOrAftermath = tLower.contains('загибл') ||
        tLower.contains('постраждал') ||
        tLower.contains('дснс') ||
        tLower.contains('пожеж') ||
        tLower.contains('уламк') ||
        tLower.contains('підсумки') ||
        tLower.contains('за ніч') ||
        tLower.contains('станом на');

    final bool isNegatedClear = tLower.contains('не мінус') ||
        tLower.contains('не зник') ||
        tLower.contains('не збито') ||
        tLower.contains('не впав');

    if (!isNegatedClear && text.trim().length < 40 &&
        (tLower.contains('знищено') ||
         tLower.contains('ліквідован') ||
         tLower.contains('збито') ||
         tLower.contains('мінус') ||
         tLower.contains('-1') ||
         tLower.contains('впав') ||
         tLower.contains('в\'єбало') ||
         tLower.contains('вєбало') ||
         tLower.contains('сконав') ||
         tLower.contains('він все') ||
         tLower.contains('наче все') ||
         tLower.contains('все наче') ||
         tLower.contains('ніби все') ||
         tLower.contains('нема його') ||
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
      'немає', 'нема', 'зникло', 'зник', 'знив', 'чисто по',
      'все наче', 'наче все', 'ніби все', 'він все', 'нема його', '-1', 'ушов назад',
      'втрачено над', 'попередньо збили', 'впав', 'сконав', 'в\'єбало', 'вєбало', 'інші вийшли',
    ];
    final bool hasClearKeyword = !isNegatedClear && (clear.any((kw) {
      if (kw == 'безпек') {
        return tLower.contains('безпек') && !tLower.contains('небезпек');
      }
      return tLower.contains(kw);
    }) || dynamicClearKeywords.any((kw) => tLower.contains(kw)));
    if (hasClearKeyword) return 'clear';

    const danger = [
      'небезпек', 'вибух', 'ракет', 'шахед', 'баліст', 'бпла', 'мопед', 'пуск', 'сікер', 'реактив',
      'бандерол', 'зниження', '🎮', '🅿️', '🛵', '☄', 'розворот', 'в бік', 'далі на',
      'курс', 'коло ріже', 'скинув висоту', 'точка входу', 'міг', 'mig', 'кинджал', 'циркон',
      'звичайний', 'не реактив', 'ще один', 'напрямок', 'вектор', 'північніше', 'південніше',
      'західніше', 'східніше', 'розвернувся', 'звернув', 'падає',
      'ціль', 'швидкісна', 'швидкісні', 'виходи', 'прилуки', 'бобровиця', 'згурівк', 'штуки',
      'багато цілей', 'цілей йде', 'цілі йдуть', 'група цілей', 'увага !!', 'увага!!',
      'літає', 'кружляє', 'крутить', 'фіксується', 'водосховищ', 'вишгород', 'тетіїв', 'вилізло', 'виліз',
      'в\'єтнам', 'вєтнам', 'не мінус', 'не зник', 'не збито',
      'сховались', 'в укриття', 'брянськ',
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


  List<Map<String, dynamic>> _parseLocalThreats(String rawText) {
    final text = rawText.replaceAll(RegExp(r'[\u02BC\u2019\u2018\u02B9\u00B4]'), "'");
    final tLower = text.toLowerCase();

    // Блокування повітряних тривог інших областей (air_alert_ua хештеги)
    const externalDistrictHashtags = [
      '#харківський_район', '#дніпровський_район', '#камянський_район', '#кам\'янський_район',
      '#криворізький_район', '#синельниківський_район', '#павлоградський_район', '#новомосковський_район',
      '#чугуївський_район', '#ізюмський_район', '#богодухівський_район', '#лозівський_район',
      '#красноградський_район', '#сумський_район', '#охтирський_район', '#конотопський_район',
      '#шосткинський_район',
    ];
    final bool hasExtHashtag = externalDistrictHashtags.any((tag) => tLower.contains(tag));
    final bool hasExtPhrase = (tLower.contains('в харківський район') ||
        tLower.contains('у харківський район') ||
        tLower.contains('в дніпровський район') ||
        tLower.contains('у дніпровський район')) && !(tLower.contains('київ') || tLower.contains('києв'));

    if (hasExtHashtag || hasExtPhrase) {
      return [];
    }

    // 1. Специфічні стоп-слова всеукраїнських зведень та інших регіонів
    const globalDigestStopWords = [
      'кроп', 'кропивницьк', 'знам\'ян', 'знамян', 'олександрі', 'павлиш', 
      'горішні плавні', 'омельник', 'лихівка', 'жовті води', 'карлівка', 
      'берестин', 'чутове', 'магдалинівк', 'кобеля', 'перещепин', 'долинськ',
      'устинівк', 'широке', 'кривий ріг', 'херсонщин', 'миколаївщин', 'запоріжж',
      'дніпропетров', 'харківщин', 'сумщин', 'донеччин', 'луганщин', 'одещин',
      'могилів подільськ', 'могилів-подільськ'
    ];

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
    final globalSpeed = _extractSpeed(text);
    final globalThreat = _analyzeLocalThreat(text, altitudeMeters: globalAlt, speedKmh: globalSpeed);
    final textWithoutReply = text.replaceAll(RegExp(r'^↪️.*?\n'), '');
    final cleanLower = textWithoutReply.toLowerCase();

    final bool hasMultipleDrones = RegExp(r'(?:^|\s)(?:[1-9]\s*(?:х|x|шт)?|ще один|кілька|групи|декілька|шахеди|бпла|цілі|перший|другий|наступн\w*)(?:\s|$)').hasMatch(cleanLower);
    final bool hasSplitters = textWithoutReply.contains(' та ') || textWithoutReply.contains(' і ') || textWithoutReply.contains(',');

    // Розбиваємо текст перед словами Другий, Третій, 2-й, 3-й, Той що на окремі рядки
    final preSplitText = textWithoutReply.replaceAllMapped(
      RegExp(r'(?:[\s.,;]+)(Другий|Третій|2-й|3-й|Той що)(?![а-яіїєґa-z0-9])', caseSensitive: false),
      (m) => '\n${m.group(1)}',
    );

    List<String> lines = [];
    for (final rawLine in preSplitText.split('\n')) {
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

      // 1. Пропускаємо чисті рядки-заголовки / звернення до аудиторії (наприклад "Столиця наступні 3", "Столиця увага", "Київщина наступні 2", "Область, увага")
      final bool isHeaderLine = RegExp(
        r'^(?:столиц[яіею]|київ|київщин[аі]|област[іь])\s*(?:[:!,—–-]|наступн\w*|уваг\w*|обережн\w*|в укритт\w*|готуй\w*|працю\w*|чутн\w*|гучн\w*|зараз|без панік\w*|тривог\w*|відбій|\s|\d+)*$',
        caseSensitive: false,
      ).hasMatch(stripped);
      if (isHeaderLine) continue;

      // 2. Якщо звернення на початку рядка з цілями (наприклад "Столиця! 1 на Вишгород" або "Столиця наступні: Вишгород, Бориспіль") — вирізаємо звернення
      String workingLine = stripped.replaceFirst(
        RegExp(r'^(?:столиц[яіею]|київ|київщин[аі]|област[іь])\s*[:!,—–-]?\s+(?:наступн\w*(?:\s*[:\d]+)?|уваг\w*|обережн\w*|в укритт\w*|готуй\w*|працю\w*|чутн\w*|гучн\w*|зараз|без панік\w*|тривог\w*|відбій)\s*[:!,—–-]?\s*', caseSensitive: false),
        '',
      ).replaceFirst(
        RegExp(r'^(?:столиц[яіею]|київ|київщин[аі]|област[іь])\s*[:!,—–-]\s*', caseSensitive: false),
        '',
      );
      if (workingLine.trim().isEmpty) continue;

      final lineLower = ' ${workingLine.toLowerCase()} ';
      if (negations.any((n) => lineLower.contains(n))) continue;

      // 2. Фільтр сусідніх та далеких регіонів
      const neighborOblastKeys = {'житомирщин', 'чернігівщин', 'черкащин', 'вінниччин', 'полтавщин'};
      final bool hasNeighborOblast = neighborOblastKeys.any((r) => lineLower.contains(r));
      final bool hasFarRegion = kFarRegions.any((r) => lineLower.contains(r));

      final bool isDniproRiverCorridor = lineLower.contains('по дніпру') ||
          lineLower.contains('вздовж дніпра') ||
          lineLower.contains('руслом дніпра') ||
          lineLower.contains('через дніпро');

      // Для ключів сусідніх областей дозволяємо рядок ТІЛЬКИ тоді, коли в цьому ж самому рядку (line) є конкретне місто/село Київської області (не просто слово "київщина", а реальний населений пункт із kKyivLocations, що не входить у kExternalBorderKeys)
      final bool hasConcreteKyivLocInLine = kKyivLocations.keys.any((k) =>
        !kExternalBorderKeys.contains(k) &&
        k != 'київщин' &&
        lineLower.contains(k)
      );

      if (hasNeighborOblast && !hasConcreteKyivLocInLine && !isDniproRiverCorridor) {
        continue;
      }
      if (hasFarRegion && !hasConcreteKyivLocInLine && !isDniproRiverCorridor) {
        continue;
      }

      final headerCheck = workingLine.toLowerCase().replaceAll(RegExp(r'[^а-яіїєґa-z]'), '');
      if (headerCheck == 'київщина' || headerCheck == 'київ' || headerCheck == 'київськаобласть' || headerCheck == 'київтаобласть' || headerCheck == 'столиця') {
        continue;
      }

      // Захищаємо конкретні інфраструктурні об'єкти (Київська ГЕС, Київська ГАЕС) перед видаленням загального слова "київськ"
      var searchLine = lineLower.replaceAllMapped(
        RegExp(r'київськ[а-яіїєґ]*\s+(гес|гаес)\b', caseSensitive: false),
        (m) => ' ${m.group(1)} ',
      );
      searchLine = searchLine.replaceAll(RegExp(r'київщин[а-яіїєґ]*|київськ[а-яіїєґ]*', caseSensitive: false), '        ');
      final List<(int, int, String, (double, double, String))> rawLocs = [];

      kKyivLocations.forEach((key, data) {
        int startPos = 0;
        while (true) {
          final idx = searchLine.indexOf(key, startPos);
          if (idx == -1) break;
          final isWordStart = (idx == 0 || !RegExp(r'[а-яіїєґa-z0-9]').hasMatch(searchLine[idx - 1]));
          if (isWordStart) {
            bool isFalseMatch = false;
            final afterIdx = idx + key.length;
            final restOfWord = searchLine.substring(afterIdx, math.min(searchLine.length, afterIdx + 12)).toLowerCase();
            if (key == 'гес' || key == 'гаес') {
              if (afterIdx < searchLine.length && RegExp(r'[а-яіїєґa-z0-9]').hasMatch(searchLine[afterIdx])) {
                isFalseMatch = true;
              }
            } else if (key == 'гора') {
              final prefix = searchLine.substring(math.max(0, idx - 18), idx).toLowerCase();
              if (prefix.contains('батиєв') ||
                  prefix.contains('черепанов') ||
                  prefix.contains('багрин') ||
                  prefix.contains('чорн') ||
                  prefix.contains('лис') ||
                  prefix.contains('вітрян') ||
                  prefix.contains('щекавиц') ||
                  prefix.contains('замков') ||
                  prefix.contains('юрковиц') ||
                  prefix.contains('володимир') ||
                  prefix.contains('червон')) {
                isFalseMatch = true;
              }
            } else if (key == 'багрин') {
              if (restOfWord.startsWith('ов')) {
                // "Багринова гора" / "Багринову гору" — це Голосіїв у Києві, а не с. Багрин!
                isFalseMatch = true;
              }
            } else if (key == 'васильків') {
              if (restOfWord.startsWith('ськ') && !searchLine.contains('район') && !searchLine.contains('р-н')) {
                // "Васильківська" (метро у Києві) або "Сергія Васильківського" — не м. Васильків!
                isFalseMatch = true;
              }
            } else if (key == 'поділ') {
              final prefix = searchLine.substring(math.max(0, idx - 18), idx).toLowerCase();
              if (restOfWord.startsWith('ьськ') &&
                  (prefix.contains('могилів') || prefix.contains('кам\'янець') || prefix.contains('камянець'))) {
                isFalseMatch = true;
              }
            } else if (key == 'харківськ') {
              if ((restOfWord.startsWith('а ') || restOfWord.startsWith('у ') || restOfWord.startsWith('ій ')) &&
                  !searchLine.contains('площ') &&
                  !searchLine.contains('шосе') &&
                  !searchLine.contains('масив')) {
                // "Харківська багато" (область) без слова масив/площа/шосе
                isFalseMatch = true;
              }
            } else if (key == 'чабан' || key == 'березан') {
              if (restOfWord.startsWith('к')) {
                // "Чабанка" (Одещина) або "Березанка" (Миколаївщина)
                isFalseMatch = true;
              }
            } else if (key == 'крим') {
              if (restOfWord.startsWith('ін') || restOfWord.startsWith('ськ')) {
                isFalseMatch = true;
              }
            } else if (key == 'море') {
              final prefix = searchLine.substring(math.max(0, idx - 10), idx).toLowerCase();
              if (prefix.contains('чорн')) {
                isFalseMatch = true;
              }
            } else if (key == 'столиц') {
              final prefix = searchLine.substring(math.max(0, idx - 30), idx).toLowerCase().trim();
              final suffix = searchLine.substring(idx + key.length, math.min(searchLine.length, idx + key.length + 30)).toLowerCase().trim();

              final bool hasDirectionalPrefix = prefix.endsWith('на') ||
                  prefix.endsWith('до') ||
                  prefix.endsWith('бік') ||
                  prefix.endsWith('напрямку') ||
                  prefix.endsWith('напрямок') ||
                  prefix.endsWith('курсом') ||
                  prefix.endsWith('вектор') ||
                  prefix.endsWith('вектором') ||
                  prefix.endsWith('над') ||
                  prefix.endsWith('підлітає') ||
                  prefix.endsWith('заходить') ||
                  prefix.endsWith('рухається') ||
                  prefix.endsWith('повз') ||
                  prefix.endsWith('біля') ||
                  prefix.endsWith('район') ||
                  prefix.endsWith('->') ||
                  prefix.endsWith('—>') ||
                  prefix.endsWith('>');

              final bool hasDirectionalSuffix = suffix.startsWith('->') ||
                  suffix.startsWith('—>') ||
                  suffix.startsWith('>') ||
                  suffix.startsWith('з півдня') ||
                  suffix.startsWith('з півночі') ||
                  suffix.startsWith('зі сходу') ||
                  suffix.startsWith('з заходу');

              // Якщо це просто звернення до читачів (наприклад "Столиця наступні 3", "Столиця увага", "Столиця!") — це НЕ ціль!
              if (!hasDirectionalPrefix && !hasDirectionalSuffix) {
                isFalseMatch = true;
              }
            } else if (key == 'борщ' || key == 'борщу' || key == 'борщем') {
              isFalseMatch = true;
            } else if (key == 'круги') {
              final hasCirclingVerb = searchLine.contains('мота') ||
                  searchLine.contains('наріз') ||
                  searchLine.contains('робит') ||
                  searchLine.contains('вертит') ||
                  searchLine.contains('накруч') ||
                  searchLine.contains('кружл');
              final hasExplicitVillagePreposition = searchLine.contains('с. круги') ||
                  searchLine.contains('село круги') ||
                  searchLine.contains('до кругів') ||
                  searchLine.contains('біля кругів') ||
                  searchLine.contains('через круги') ||
                  searchLine.contains('повз круги');
              if (hasCirclingVerb || !hasExplicitVillagePreposition) {
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

          if (itemKey.contains('новосілк') || itemKey.contains('новосілок') || displayName.contains('Новосілк')) {
            // Динамічний вибір між Вишгородом (біля Десни) та Теремками
            if (lineLower.contains('вишгород') || lineLower.contains('десн') || lineLower.contains('троєщин') ||
                lineLower.contains('троя') || lineLower.contains('трою') || lineLower.contains('водосховищ') ||
                lineLower.contains('хотянівк') || lineLower.contains('осещин') || lineLower.contains('погреб') ||
                lineLower.contains('зазим') || lineLower.contains('пухівк') || lineLower.contains('пірнов') ||
                lineLower.contains('лівий берег') || lineLower.contains('північ')) {
              lat = 50.6280;
              lon = 30.6120;
              displayName = 'Новосілки (Вишгород)';
            } else {
              lat = 50.3550;
              lon = 30.4560;
              displayName = 'Новосілки (Теремки)';
            }
          }

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

          path.add({'name': displayName, 'lat': lat, 'lon': lon, 'hasCompass': hasCompassModifier, 'key': itemKey, 'start': item.$1, 'end': item.$2});
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

      // Перевірка порядку для маршруту з 2 локацій [locA, locB]:
      // Якщо перед locA стоїть прийменник цілі ("на ", "в район", "у район", "курсом на ", "вектор на ", "до "),
      // а перед locB прийменник джерела ("з ", "із ", "від ", "зі ", "з боку ") — міняємо [locB, locA]!
      if (path.length == 2) {
        final startA = (path[0]['start'] as int?) ?? 0;
        final startB = (path[1]['start'] as int?) ?? 0;
        final preA = searchLine.substring(math.max(0, startA - 30), startA).trimRight();
        final preB = searchLine.substring(math.max(0, startB - 30), startB).trimRight();

        final bool hasTargetPreA = RegExp(
          r'(?:^|[\s,])(?:на|в район|у район|на район|курсом на|вектор на|вектором на|до)(?:\s+[~≈])?$',
          caseSensitive: false,
        ).hasMatch(preA);

        final bool hasOriginPreB = RegExp(
          r'(?:^|[\s,])(?:з|із|від|зі|з боку)(?:\s+(?:району?|боку))?(?:\s+[~≈])?$',
          caseSensitive: false,
        ).hasMatch(preB);

        if (hasTargetPreA && hasOriginPreB) {
          final temp = path[0];
          path[0] = path[1];
          path[1] = temp;
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

      int? lineOrderTag;
      final lLower = line.toLowerCase();
      if (RegExp(r'(?:^|\s)(?:перший|1-й|1й)(?![а-яіїєґa-z0-9])|^\s*1\s+на(?![а-яіїєґa-z0-9])').hasMatch(lLower)) {
        lineOrderTag = 1;
      } else if (RegExp(r'(?:^|\s)(?:другий|2-й|2й)(?![а-яіїєґa-z0-9])|^\s*2\s+на(?![а-яіїєґa-z0-9])').hasMatch(lLower)) {
        lineOrderTag = 2;
      } else if (RegExp(r'(?:^|\s)(?:третій|3-й|3й)(?![а-яіїєґa-z0-9])|^\s*3\s+на(?![а-яіїєґa-z0-9])').hasMatch(lLower)) {
        lineOrderTag = 3;
      } else if (lines.length >= 2 && lines.any((l) => RegExp(r'(?:другий|2-й|2й)(?![а-яіїєґa-z0-9])', caseSensitive: false).hasMatch(l.toLowerCase()))) {
        if (lines.indexOf(line) == 0) lineOrderTag = 1;
      }

      final lineAlt = _extractAltitude(line) ?? globalAlt;
      final lineSpeed = _extractSpeed(line) ?? globalSpeed;
      final lineThreat = _analyzeLocalThreat(line, altitudeMeters: lineAlt, speedKmh: lineSpeed);
      final bool circlingWordsInLine = lineLower.contains('літає') ||
          lineLower.contains('кружля') ||
          lineLower.contains('крутить') ||
          lineLower.contains('намоту') ||
          lineLower.contains('мотає') ||
          lineLower.contains('мотають') ||
          lineLower.contains('нарізає') ||
          lineLower.contains('накручу') ||
          lineLower.contains('круги') ||
          RegExp(r'в районі.*?літає', caseSensitive: false).hasMatch(lineLower);
      final bool isCircling = circlingWordsInLine ||
          (lineThreat['isCircling'] == true) ||
          (path.length == 1 && (lineLower.contains('літає') || lineLower.contains('кружляє') || lineLower.contains('крутить')));
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
      final effectiveSpeed = (lineSpeed != null)
          ? lineSpeed.toDouble()
          : ((lineThreat['type'] != null && lineThreat['type'] != 'shahed')
              ? lineThreat['speed']
              : (globalThreat['speed'] ?? 185.0));
      final effectiveLabel = (lineThreat['type'] != null && lineThreat['type'] != 'shahed')
          ? lineThreat['label']
          : (globalThreat['label'] ?? _getDefaultThreatLabel(effectiveType));

      final bool hasTrajectoryIndicators = lineLower.contains('->') ||
          lineLower.contains('—>') ||
          lineLower.contains('-->') ||
          lineLower.contains('>') ||
          lineLower.contains('через') ||
          lineLower.contains('повз') ||
          lineLower.contains('транзитом') ||
          lineLower.contains('курсом') ||
          lineLower.contains('вектор') ||
          lineLower.contains('в бік') ||
          lineLower.contains('у бік') ||
          lineLower.contains('напрямк') ||
          lineLower.contains('заходить') ||
          lineLower.contains('підлітає') ||
          RegExp(r'\b(?:з|від|із)\s+[а-яіїєґa-z0-9\s]+?\s+на\b', caseSensitive: false).hasMatch(lineLower);

      final bool isOverheadFix = lineLower.contains('над ') ||
          lineLower.contains('біля ') ||
          lineLower.contains('поблизу ') ||
          lineLower.contains('в районі') ||
          lineLower.contains('у районі') ||
          lineLower.contains('пролітає') ||
          lineLower.contains('вже на ');
      final bool isDirectionalSinglePoint = path.length == 1 &&
          !isCircling &&
          !isOverheadFix &&
          RegExp(
            r'(?:^|[\s,;:])(?:на|в бік|у бік|курсом(?:\s+на)?|курс(?:\s+на)?|вектор(?:ом)?(?:\s+на)?|у напрямку|в напрямку|далі на|повернув на|розвернувся на|звернув на|до)\s+',
            caseSensitive: false,
          ).hasMatch(lineLower);

      final bool isSeparateTargetsList = !hasTrajectoryIndicators && (hasMultipleDrones || path.length >= 3);
      if (isSeparateTargetsList) {
        for (final loc in path) {
          parsed.add({
            'type': effectiveType,
            'speed': effectiveSpeed,
            'label': effectiveLabel,
            'path': [Map<String, dynamic>.from(loc)],
            'isCircling': isCircling,
            'isDirectional': isDirectionalSinglePoint,
            'altitude': altitudeStr,
            'altitudeMeters': lineAlt,
            'isDescending': isDescending,
            'orderTag': lineOrderTag,
          });
        }
      } else {
        for (int c = 0; c < count; c++) {
          parsed.add({
            'type': effectiveType,
            'speed': effectiveSpeed,
            'label': effectiveLabel,
            'path': List<Map<String, dynamic>>.from(path),
            'isCircling': isCircling,
            'isDirectional': isDirectionalSinglePoint,
            'altitude': altitudeStr,
            'altitudeMeters': lineAlt,
            'isDescending': isDescending,
            'orderTag': lineOrderTag,
          });
        }
      }
    }

    if (parsed.isEmpty) {
      final bool hasVietnamSlang = cleanLower.contains('в\'єтнам') || cleanLower.contains('вєтнам');
      if (hasVietnamSlang) {
        parsed.add({
          'type': 'shahed',
          'speed': 185.0,
          'label': 'Активна робота ППО (Київ) 💥',
          'path': [
            {'name': 'Київ (ППО)', 'lat': 50.450, 'lon': 30.523}
          ],
          'isCircling': false,
          'altitude': globalAlt != null ? '$globalAlt м' : null,
          'altitudeMeters': globalAlt,
          'isDescending': false,
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

    // Гарантуємо порядок від найновіших до найстаріших перед обробкою
    final sortedMsgs = List<dynamic>.from(rawMsgs);
    sortedMsgs.sort((a, b) {
      if (a is Map && b is Map && a['date'] != null && b['date'] != null) {
        return b['date'].toString().compareTo(a['date'].toString());
      }
      return 0;
    });

    // Проходимо від старіших до новіших, щоб залишати першоджерело і відсікати повторні дублікати
    for (final msg in sortedMsgs.reversed) {
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
          final isMsgDanger = msg['type'] == 'danger' || _categorizeLocalMessage((msg['text'] ?? '').toString()) == 'danger';
          final newCh = (msg['channel'] ?? '').toString().trim();

          if (isMsgDanger && newCh.isNotEmpty) {
            final List<Map<String, dynamic>> msgThreats = (msg['threats'] is List && (msg['threats'] as List).isNotEmpty)
                ? List<Map<String, dynamic>>.from(msg['threats'])
                : _parseLocalThreats((msg['text'] ?? '').toString());

            if (msgThreats.isNotEmpty) {
              const distanceCalc = Distance();
              final geoCheckStart = keptChronological.length > 25 ? keptChronological.length - 25 : 0;

              for (int i = keptChronological.length - 1; i >= geoCheckStart; i--) {
                final prevMsg = keptChronological[i];
                final prevCh = (prevMsg['channel'] ?? '').toString().trim();
                if (prevCh.isEmpty || prevCh == newCh) continue;

                final isPrevDanger = prevMsg['type'] == 'danger' || _categorizeLocalMessage((prevMsg['text'] ?? '').toString()) == 'danger';
                if (!isPrevDanger) continue;

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

                    final ptNew = newPath.last;
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
                      final ptPrev = prevPath.last;
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

                      // Кінцеві координати (threats -> path.last) в радіусі <= 5500 метрів
                      final double distM = distanceCalc.as(LengthUnit.Meter, pNew, pPrev);
                      if (distM <= 5500.0) {
                        geoMatchFound = true;
                        break;
                      }
                    }
                    if (geoMatchFound) break;
                  }

                  if (geoMatchFound) {
                    isDup = true;
                    if (prevMsg is Map) {
                      // Об'єднуємо підпис джерела у хронологічному порядку (наприклад, "Kyiv AirDefense 🌇 • SK_DM_SK")
                      final earlierCh = (msgTime.isBefore(prevTime)) ? newCh : prevCh;
                      final laterCh = (msgTime.isBefore(prevTime)) ? prevCh : newCh;
                      if (!prevCh.contains(newCh)) {
                        prevMsg['channel'] = '$earlierCh • $laterCh';
                      }
                      final mergedMsgIds = (prevMsg['merged_msg_ids'] as List?)?.toList() ?? [];
                      if (msg['id'] != null && !mergedMsgIds.contains(msg['id'])) {
                        mergedMsgIds.add(msg['id']);
                      }
                      prevMsg['merged_msg_ids'] = mergedMsgIds;

                      final mergedPostIds = (prevMsg['merged_post_ids'] as List?)?.map((p) => p.toString()).toList() ?? [];
                      final pId = msg['postId']?.toString() ?? msg['post_id']?.toString();
                      if (pId != null && pId.isNotEmpty && !mergedPostIds.contains(pId)) {
                        mergedPostIds.add(pId);
                      }
                      prevMsg['merged_post_ids'] = mergedPostIds;
                    }
                    break;
                  }
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

  /// Фільтрує повідомлення для оперативного відображення на радарі та у стрічці:
  /// Якщо є активні повідомлення за останні [maxAgeMinutes] (за замовчуванням 240 хв / 4 год),
  /// відсікає застарілі ранкові повідомлення або повідомлення минулих сесій, що висять внизу списку.
  /// Якщо ж за останні 4 години нічого не було (період спокою), повертає останні [fallbackCount] повідомлень,
  /// щоб користувач бачив останній статус безпеки (напр. відбій).
  List<T> _filterOperationalMessages<T>(
    List<T> messages, {
    DateTime? nowUtc,
    int maxAgeMinutes = 240,
    int fallbackCount = 5,
  }) {
    if (messages.isEmpty) return [];
    final now = nowUtc ?? DateTime.now().toUtc();
    final recent = messages.where((msg) {
      if (msg is Map && msg['date'] != null) {
        try {
          final dt = DateTime.parse(msg['date'].toString()).toUtc();
          return now.difference(dt).inMinutes <= maxAgeMinutes;
        } catch (_) {
          return true;
        }
      }
      return true;
    }).toList();

    if (recent.isNotEmpty) {
      return recent;
    }
    return messages.take(fallbackCount).toList();
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
    case 'shahed_jet': return 550.0;
    case 'shahed':
    default: return 185.0;
  }
}

int _getThreatLevel(bool isAlert, bool isKyivRegion, List<Map<String, dynamic>> threats, {bool globalMissileThreat = false}) {
  if (!isAlert) return 1;
  if (globalMissileThreat) return 3;
  return 2;
}

Color _getAlertFillColor(int threatLevel) {
  if (threatLevel == 3) return const Color(0xFFE53935).withValues(alpha: 0.44);
  if (threatLevel == 2) return const Color(0xFFFFC107).withValues(alpha: 0.36);
  return Colors.transparent;
}

Color _getAlertBorderColor(int threatLevel, {bool defaultFaint = true}) {
  if (threatLevel == 3) return Colors.redAccent.withValues(alpha: 0.95);
  if (threatLevel == 2) return const Color(0xFFFFD54F).withValues(alpha: 0.95);
  return defaultFaint ? Colors.white.withValues(alpha: 0.14) : Colors.transparent;
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

  Polygon _buildForecastCone(LatLng currentPos, double bearing, double speedMs, Color color, bool isUav, {double opacity = 1.0}) {
    final double coneDistMeters = (speedMs * 150.0).clamp(1500.0, isUav ? 8000.0 : 25000.0);
    const double halfAngleRad = 16.0 * math.pi / 180.0;
    const double earthRadius = 6378137.0;
    final double d = coneDistMeters / earthRadius;
    final double lat1 = currentPos.latitude * math.pi / 180.0;
    final double lon1 = currentPos.longitude * math.pi / 180.0;

    final List<LatLng> conePoints = [currentPos];
    const int arcSegments = 12;
    for (int s = 0; s <= arcSegments; s++) {
      final double relAngle = -halfAngleRad + (2.0 * halfAngleRad * s / arcSegments);
      final double b = bearing + relAngle;
      final double lat2 = math.asin(math.sin(lat1) * math.cos(d) + math.cos(lat1) * math.sin(d) * math.cos(b));
      final double lon2 = lon1 + math.atan2(math.sin(b) * math.sin(d) * math.cos(lat1), math.cos(d) - math.sin(lat1) * math.sin(lat2));
      conePoints.add(LatLng(lat2 * 180.0 / math.pi, lon2 * 180.0 / math.pi));
    }
    conePoints.add(currentPos);

    final double safeOpacity = opacity.clamp(0.15, 1.0);
    return Polygon(
      points: conePoints,
      color: color.withValues(alpha: 0.10 * safeOpacity),
      borderColor: color.withValues(alpha: 0.35 * safeOpacity),
      borderStrokeWidth: 1.0,
    );
  }

  (LatLng, double) _calculateCirclingPosAndAngle(
    LatLng center,
    double timeSec, {
    double phaseOffset = 0.0,
    double radiusScale = 1.0,
    bool clockwise = true,
  }) {
    const double iconRotationOffset = math.pi / 4; // Іконки дивляться праворуч-вгору (45°)
    final double periodSec = (25.0 * radiusScale.clamp(0.4, 1.5));
    final double omega = (2.0 * math.pi / periodSec) * (clockwise ? 1.0 : -1.0);
    final double angle = omega * timeSec + phaseOffset;

    // Базовий радіус орбіти: ~2.2 км (0.015 lat, 0.024 lon), масштабується за radiusScale
    final double rLat = 0.015 * radiusScale;
    final double rLon = 0.024 * radiusScale;
    final double lat = center.latitude + rLat * math.sin(angle);
    final double lon = center.longitude + rLon * math.cos(angle);

    final double dirSign = clockwise ? 1.0 : -1.0;
    final double dyScreen = -rLat * math.cos(angle) * dirSign;
    final double dxScreen = -rLon * math.sin(angle) * dirSign;
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
int? extractSpeed(String text) => _extractSpeed(text);
Map<String, dynamic> analyzeLocalThreat(String text, {int? altitudeMeters, int? speedKmh}) => _analyzeLocalThreat(text, altitudeMeters: altitudeMeters, speedKmh: speedKmh);
String getSeverityForMessage(String text) => _categorizeLocalMessage(text);
String categorizeLocalMessage(String text) => _categorizeLocalMessage(text);
double calculateBearing(LatLng from, LatLng to) => _calculateBearing(from, to);
Polygon buildForecastCone(LatLng currentPos, double bearing, double speedMs, Color color, bool isUav, {double opacity = 1.0}) => _buildForecastCone(currentPos, bearing, speedMs, color, isUav, opacity: opacity);
(LatLng, double) calculateCirclingPosAndAngle(LatLng center, double timeSec, {double phaseOffset = 0.0, double radiusScale = 1.0, bool clockwise = true}) => _calculateCirclingPosAndAngle(center, timeSec, phaseOffset: phaseOffset, radiusScale: radiusScale, clockwise: clockwise);
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
  static int? extractSpeed(String text) => _extractSpeed(text);
  static Map<String, dynamic> analyzeLocalThreat(String text, {int? altitudeMeters, int? speedKmh}) => _analyzeLocalThreat(text, altitudeMeters: altitudeMeters, speedKmh: speedKmh);
  static List<Map<String, dynamic>> parseLocalThreats(String text) => _parseLocalThreats(text);
  static String categorizeLocalMessage(String text) => _categorizeLocalMessage(text);
  static List<dynamic> deduplicateMessages(List<dynamic> rawMsgs) => _deduplicateMessages(rawMsgs);
  static List<T> filterOperationalMessages<T>(
    List<T> messages, {
    DateTime? nowUtc,
    int maxAgeMinutes = 240,
    int fallbackCount = 5,
  }) => _filterOperationalMessages<T>(
    messages,
    nowUtc: nowUtc,
    maxAgeMinutes: maxAgeMinutes,
    fallbackCount: fallbackCount,
  );
  static StrategicLaunchEvent? detectStrategicLaunch(List<dynamic> messages, {DateTime? now}) => _detectStrategicLaunch(messages, now: now);
}



