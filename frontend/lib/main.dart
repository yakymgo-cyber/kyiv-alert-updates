import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_analytics/firebase_analytics.dart';

import 'desktop_map_wrapper.dart';

// Модульні компоненти проєкту
import 'package:frontend/models/alert_models.dart';
import 'package:frontend/data/kyiv_gazetteer.dart';
import 'package:frontend/services/threat_parser.dart';
import 'package:frontend/services/update_service.dart';
import 'package:frontend/ui/sheets/morning_digest_sheet.dart';
import 'package:frontend/ui/sheets/watched_locations_sheet.dart';
import 'package:frontend/services/voice_alert_service.dart';
import 'package:frontend/services/live_radar_notification_service.dart';
import 'package:frontend/services/cached_tile_provider.dart';

// Ре-експорт для сумісності з тестами та зовнішніми модулями
export 'package:frontend/models/alert_models.dart';
export 'package:frontend/data/kyiv_gazetteer.dart';
export 'package:frontend/services/threat_parser.dart';
export 'package:frontend/services/update_service.dart';
export 'package:frontend/ui/sheets/morning_digest_sheet.dart';
export 'package:frontend/ui/sheets/watched_locations_sheet.dart';
export 'package:frontend/services/voice_alert_service.dart';
export 'package:frontend/services/live_radar_notification_service.dart';
export 'package:frontend/services/cached_tile_provider.dart';


// Аліаси та зв'язки для зворотної сумісності
const _kFarRegions = kFarRegions;
const _kExternalBorderKeys = kExternalBorderKeys;
Map<String, (double, double, String)> get _kKyivLocations => kKyivLocations;
set _kKyivLocations(Map<String, (double, double, String)> val) => kKyivLocations = val;
Map<String, (double, double, String)> get _kBaseKyivLocations => kKyivRegionLocations;
Map<String, (double, double, String)> get _learnedLocations => learnedLocations;
List<String> get _dynamicExtraChannels => dynamicExtraChannels;
set _dynamicExtraChannels(List<String> val) => dynamicExtraChannels = val;
List<String> get _dynamicDangerKeywords => dynamicDangerKeywords;
set _dynamicDangerKeywords(List<String> val) => dynamicDangerKeywords = val;
List<String> get _dynamicClearKeywords => dynamicClearKeywords;
set _dynamicClearKeywords(List<String> val) => dynamicClearKeywords = val;
Future<File?> _getAppStorageFile(String fileName) => getAppStorageFile(fileName);
Future<void> _loadLearnedLocations() => loadLearnedLocations();
String _cleanHtmlText(String html, {int maxLength = 600}) => cleanHtmlText(html, maxLength: maxLength);
String _categorizeLocalMessage(String text) => ThreatParser.categorizeLocalMessage(text);
String _getDefaultThreatLabel(String type) => getDefaultThreatLabel(type);
double _getDefaultThreatSpeed(String type) => getDefaultThreatSpeed(type);
int _getThreatLevel(bool isAlert, bool isKyivRegion, List<Map<String, dynamic>> threats, {bool globalMissileThreat = false}) => getThreatLevel(isAlert, isKyivRegion, threats, globalMissileThreat: globalMissileThreat);
Color _getAlertFillColor(int threatLevel) => getAlertFillColor(threatLevel);
Color _getAlertBorderColor(int threatLevel, {bool defaultFaint = true}) => getAlertBorderColor(threatLevel, defaultFaint: defaultFaint);
double _minDistanceToPointMeters(LatLng center, List<LatLng> path) => minDistanceToPointMeters(center, path);
double _calculateBearing(LatLng from, LatLng to) => calculateBearing(from, to);
Polygon _buildForecastCone(LatLng currentPos, double bearing, double speedMs, Color color, bool isUav, {double opacity = 1.0}) => buildForecastCone(currentPos, bearing, speedMs, color, isUav, opacity: opacity);
(LatLng, double) _calculateCirclingPosAndAngle(LatLng center, double timeSec, {double phaseOffset = 0.0, double radiusScale = 1.0, bool clockwise = true}) => calculateCirclingPosAndAngle(center, timeSec, phaseOffset: phaseOffset, radiusScale: radiusScale, clockwise: clockwise);
(LatLng, double) _interpolatePosAndAngle(List<LatLng> path, double fraction) => interpolatePosAndAngle(path, fraction);
String _formatEta(double distanceMeters, double speedMs) => formatEta(distanceMeters, speedMs);
double _projectedForwardDistance(LatLng locPoint, LatLng pPrev, LatLng pLast, double maxDistanceMeters) => projectedForwardDistance(locPoint, pPrev, pLast, maxDistanceMeters);

String _staticTestModeTime = DateTime.now().toUtc().toIso8601String();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Ініціалізація Firebase Analytics
  try {
    await Firebase.initializeApp();
    final analytics = FirebaseAnalytics.instance;
    await analytics.setAnalyticsCollectionEnabled(true);
    await analytics.logAppOpen();
    await analytics.logEvent(
      name: 'app_open_kyiv_alert',
      parameters: {
        'version': kCurrentVersionName,
        'build': kCurrentVersionCode,
      },
    );
  } catch (e) {
    debugPrint('Firebase init: $e');
  }

  await _loadLearnedLocations();
  runApp(const ProviderScope(child: KyivAlertApp()));
}

class NoStretchScrollBehavior extends ScrollBehavior {
  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) {
    return child; 
  }
}

class KyivAlertApp extends StatelessWidget {
  const KyivAlertApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kyiv Alert — Тактичний Радар',
      debugShowCheckedModeBanner: false,
      scrollBehavior: NoStretchScrollBehavior(),
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0E14),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF111622),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          shape: Border(
            bottom: BorderSide(color: Color(0xFF1F2738), width: 1),
          ),
        ),
        cardColor: const Color(0xFF151C28),
        snackBarTheme: const SnackBarThemeData(
          contentTextStyle: TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w500),
          backgroundColor: Color(0xFF1C2333),
          behavior: SnackBarBehavior.floating,
        ),
      ),
      navigatorObservers: [
        if (Firebase.apps.isNotEmpty)
          FirebaseAnalyticsObserver(analytics: FirebaseAnalytics.instance),
      ],
      home: const MainScreen(),
    );
  }
}

void _populateCachedRegionPolygons(Map<String, dynamic> geoJson) {
  if (_kCachedRegionPolygons.isNotEmpty) return;
  final features = geoJson['features'] as List?;
  if (features == null) return;
  for (final feature in features) {
    final props = feature['properties'];
    if (props == null) continue;
    final name = (props['name:uk'] ?? props['name'] ?? '').toString();
    final geometry = feature['geometry'];
    if (geometry == null || name.isEmpty) continue;

    final type = geometry['type'];
    final coords = geometry['coordinates'];
    final List<List<LatLng>> polyList = [];

    if (type == 'Polygon') {
      final List<LatLng> points = (coords[0] as List)
          .map((p) => LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()))
          .toList();
      polyList.add(points);
    } else if (type == 'MultiPolygon') {
      for (final poly in (coords as List)) {
        final List<LatLng> points = (poly[0] as List)
            .map((p) => LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()))
            .toList();
        polyList.add(points);
      }
    }
    _kCachedRegionPolygons[name] = polyList;
  }
}

final geoJsonProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final jsonString = await rootBundle.loadString('assets/ukraine.geojson');
  final decoded = json.decode(jsonString) as Map<String, dynamic>;
  _populateCachedRegionPolygons(decoded);
  return decoded;
});

class AlertsNotifier extends Notifier<Map<String, bool>> {
  Timer? _timer;
  final http.Client _httpClient = http.Client();
  bool _disposed = false;
  bool _isFetching = false;
  int _cycleCount = 0;
  final Map<String, bool> _cachedUbillingAlerts = {};
  final Map<String, bool> _cachedUkraineAlarmAlerts = {};

  static const List<String> _kKyivOblastDistricts = [
    'білоцерківський',
    'бориспільський',
    'броварський',
    'бучанський',
    'вишгородський',
    'обухівський',
    'фастівський',
  ];

  static const Set<String> _kKyivOblastUkraineAlarmDistrictIds = {
    '14', // Київська область
    '73', // Білоцерківський район
    '74', // Вишгородський район
    '75', // Бучанський район
    '76', // Обухівський район
    '77', // Фастівський район
    '78', // Бориспільський район
    '79', // Броварський район
  };

  @override
  Map<String, bool> build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      _httpClient.close();
    });

    _scheduleNextFetch(0);
    return {};
  }

  void _scheduleNextFetch(int seconds) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(Duration(seconds: seconds), _fetchData);
  }

  Future<void> refreshNow() => _fetchData();

  /// Отримує стан повітряних тривог та їхній рівень (Yellow = БпЛА, Red = Ракети)
  /// напряму з https://map.ukrainealarm.com/api/v2/data/mapUpdate
  Future<({int? cityLevel, int? oblastLevel})> _fetchUkraineAlarmMapUpdate() async {
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final resp = await _httpClient.get(
        Uri.parse('https://map.ukrainealarm.com/api/v2/data/mapUpdate?_t=$ts'),
        headers: const {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept': 'application/json',
          'Referer': 'https://map.ukrainealarm.com/',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
        },
      ).timeout(const Duration(seconds: 4));

      if (resp.statusCode != 200 || resp.bodyBytes.length > 524288) {
        return (cityLevel: null, oblastLevel: null);
      }

      final data = json.decode(utf8.decode(resp.bodyBytes, allowMalformed: true));
      if (data is! Map<String, dynamic>) {
        return (cityLevel: null, oblastLevel: null);
      }
      final alertsList = data['alerts'];
      if (alertsList is! List) {
        return (cityLevel: null, oblastLevel: null);
      }

      int cityLevel = 1;
      int oblastLevel = 1;
      final Map<String, int> oblastMaxLevels = {};

      for (final item in alertsList) {
        if (item is! Map) continue;
        final String regionId = (item['regionId'] ?? '').toString().trim();
        final String regionName = (item['regionName'] ?? '').toString().trim();
        final String regionNameLower = regionName.toLowerCase();
        final activeAlerts = item['activeAlerts'];
        if (activeAlerts is! List || activeAlerts.isEmpty) continue;

        int entryAirLevel = 1;
        for (final a in activeAlerts) {
          if (a is! Map) continue;
          final String aType = (a['type'] ?? '').toString().toUpperCase();
          if (aType != 'AIR' && aType != '1') continue;

          int levelForThisAlert = 2; // За замовчуванням повітряна тривога = Жовта (2)
          final levels = a['activeAlertLevels'];
          if (levels is List) {
            for (final lv in levels) {
              if (lv is! Map) continue;
              final String alertLevelStr = (lv['alertLevel'] ?? '').toString().toLowerCase();
              final String reasonStr = (lv['reason'] ?? '').toString().toLowerCase();
              if (alertLevelStr == 'red' ||
                  reasonStr.contains('червоний') ||
                  reasonStr.contains('ракет')) {
                levelForThisAlert = 3;
                break;
              }
            }
          }
          if (levelForThisAlert > entryAirLevel) {
            entryAirLevel = levelForThisAlert;
          }
        }

        if (entryAirLevel < 2) continue;

        if (regionId == '31' || regionName == 'м. Київ' || regionNameLower == 'київ') {
          if (entryAirLevel > cityLevel) cityLevel = entryAirLevel;
        } else if (_kKyivOblastUkraineAlarmDistrictIds.contains(regionId) ||
            regionName == 'Київська область' ||
            _kKyivOblastDistricts.any((d) => regionNameLower.contains(d))) {
          if (entryAirLevel > oblastLevel) oblastLevel = entryAirLevel;
        } else if (regionName.endsWith('область') || regionName.contains('Крим')) {
          final prev = oblastMaxLevels[regionName] ?? 1;
          if (entryAirLevel > prev) {
            oblastMaxLevels[regionName] = entryAirLevel;
          }
        }
      }

      _cachedUkraineAlarmAlerts.clear();
      oblastMaxLevels.forEach((regionName, lvl) {
        _cachedUkraineAlarmAlerts[regionName] = lvl >= 2;
        _cachedUkraineAlarmAlerts['__red_$regionName'] = lvl == 3;
      });
      _cachedUkraineAlarmAlerts['м. Київ'] = cityLevel >= 2;
      _cachedUkraineAlarmAlerts['__red_м. Київ'] = cityLevel == 3;
      _cachedUkraineAlarmAlerts['Київська область'] = oblastLevel >= 2;
      _cachedUkraineAlarmAlerts['__red_Київська область'] = oblastLevel == 3;

      return (cityLevel: cityLevel, oblastLevel: oblastLevel);
    } catch (_) {
      return (cityLevel: null, oblastLevel: null);
    }
  }

  Future<List<(DateTime, String)>> _fetchTelegramChannelPosts(String channel) async {
    try {
      final dynamicBefore = 90000000 + (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 9000000;
      final resp = await _httpClient.get(
        Uri.parse('https://t.me/s/$channel?before=$dynamicBefore'),
        headers: const {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
        },
      ).timeout(const Duration(seconds: 4));

      if (resp.statusCode != 200 || resp.bodyBytes.length > 524288) {
        return const [];
      }
      final html = utf8.decode(resp.bodyBytes, allowMalformed: true);
      final blocks = html.split('tgme_widget_message_wrap');
      final List<(DateTime, String)> posts = [];
      final nowUtc = DateTime.now().toUtc();

      for (int i = 1; i < blocks.length; i++) {
        final b = blocks[i];
        final timeMatch = RegExp(r'datetime="([^"]+)"').firstMatch(b);
        final textMatch = RegExp(
          r'<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>',
          dotAll: true,
        ).firstMatch(b);
        if (timeMatch == null || textMatch == null) continue;
        final dt = DateTime.tryParse(timeMatch.group(1)!)?.toUtc();
        if (dt == null || nowUtc.difference(dt).inHours > 18) continue;

        final clean = _cleanHtmlText(textMatch.group(1)!, maxLength: 600)
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (clean.isNotEmpty) {
          posts.add((dt, clean));
        }
      }
      return posts;
    } catch (_) {
      return const [];
    }
  }

  /// Отримує офіційний рівень тривоги в м. Київ із каналів КМВА (VA_Kyiv) та КМДА (KyivCityOfficial):
  /// 1 = Відбій / Немає тривоги, 2 = Жовта тривога (Шахеди/БпЛА), 3 = Червона тривога (Ракети)
  Future<int?> _fetchOfficialKyivCityLevel() async {
    final results = await Future.wait([
      _fetchTelegramChannelPosts('VA_Kyiv'),
      _fetchTelegramChannelPosts('KyivCityOfficial'),
    ]);

    final List<(DateTime, int)> events = [];
    for (final postList in results) {
      for (final (dt, text) in postList) {
        final t = text.toLowerCase();
        // Ігноруємо погодні попередження та тижневі дайджести
        if (t.contains('протягом цього тижня') ||
            t.contains('найважливіше за тиждень') ||
            t.contains('туман') ||
            t.contains('укргідрометцентр') ||
            t.contains('рівень небезпечності')) {
          continue;
        }

        if (t.contains('відбій повітряної тривоги') ||
            t.contains('відбій тривоги') ||
            t.contains('air siren all clear')) {
          events.add((dt, 1));
        } else if ((t.contains('червоний рівень') &&
                (t.contains('тривог') || t.contains('загроз') || t.contains('небезпек'))) ||
            t.contains('оголошена ракетна загроза') ||
            t.contains('через ракетну загрозу') ||
            t.contains('missile threat') ||
            ((t.contains('оголошено повітряну тривогу') ||
                    t.contains('повітряна тривога в києві') ||
                    t.contains('повітряна тривога у києві') ||
                    t.contains('у києві оголошена повітряну тривогу') ||
                    t.contains('у києві оголошена повітряна тривога')) &&
                (t.contains('🔴') ||
                    t.contains('ракет') ||
                    t.contains('баліст') ||
                    t.contains('міг') ||
                    t.contains('кинджал')))) {
          events.add((dt, 3));
        } else if ((t.contains('жовтий рівень') &&
                (t.contains('тривог') || t.contains('загроз') || t.contains('небезпек'))) ||
            t.contains('дронова небезпека') ||
            t.contains('через дронову загрозу') ||
            t.contains('drone threat') ||
            t.contains('загроза ударних бпла') ||
            t.contains('оголошено повітряну тривогу') ||
            t.contains('повітряна тривога в києві') ||
            t.contains('повітряна тривога у києві') ||
            t.contains('у києві оголошена повітряна тривога')) {
          events.add((dt, 2));
        }
      }
    }

    if (events.isEmpty) return null;
    events.sort((a, b) => a.$1.compareTo(b.$1));
    return events.last.$2;
  }

  /// Отримує офіційний рівень тривоги в Київській області з каналу КОВА (kyivoda):
  /// 1 = Відбій / Немає тривоги, 2 = Жовта тривога (Шахеди/БпЛА), 3 = Червона тривога (Ракети)
  Future<int?> _fetchOfficialKyivOblastLevel() async {
    final posts = await _fetchTelegramChannelPosts('kyivoda');
    if (posts.isEmpty) return null;

    posts.sort((a, b) => a.$1.compareTo(b.$1));
    final Map<String, int> districtLevels = {
      for (final d in _kKyivOblastDistricts) d: 1,
    };
    bool hasAnyOfficialEvent = false;

    for (final (_, text) in posts) {
      final t = text.toLowerCase();
      if (t.contains('відбій повітряної тривоги')) {
        hasAnyOfficialEvent = true;
        if (t.contains('досі триває у:')) {
          final afterPart = t.split('досі триває у:').last;
          for (final d in _kKyivOblastDistricts) {
            districtLevels[d] = afterPart.contains(d) ? 2 : 1;
          }
        } else {
          for (final d in _kKyivOblastDistricts) {
            districtLevels[d] = 1;
          }
        }
      } else {
        final headerPart = t.split('—').first;
        for (final d in _kKyivOblastDistricts) {
          if (headerPart.contains(d)) {
            if (t.contains('червоний рівень') || t.contains('ракетна загроза') || t.contains('🔴')) {
              districtLevels[d] = 3;
              hasAnyOfficialEvent = true;
            } else if (t.contains('жовтий рівень') || t.contains('дронова загроза') || t.contains('🟡')) {
              districtLevels[d] = 2;
              hasAnyOfficialEvent = true;
            }
          }
        }
      }
    }

    if (!hasAnyOfficialEvent) return null;
    return districtLevels.values.fold<int>(1, math.max);
  }

  Future<void> _fetchData() async {
    if (_disposed || _isFetching) return;
    _isFetching = true;
    _cycleCount++;
    try {
      final bool shouldPollUbilling = _cachedUbillingAlerts.isEmpty || (_cycleCount % 3 == 1);

      final Future<void> ubillingFuture = shouldPollUbilling
          ? () async {
              try {
                final ts = DateTime.now().millisecondsSinceEpoch;
                final response = await _httpClient.get(
                  Uri.parse('https://ubilling.net.ua/aerialalerts/?_t=$ts'),
                  headers: const {
                    'Cache-Control': 'no-cache, no-store, must-revalidate',
                    'Pragma': 'no-cache',
                  },
                ).timeout(const Duration(seconds: 4));
                if (response.statusCode == 200 && response.bodyBytes.length <= 262144) {
                  final data = json.decode(utf8.decode(response.bodyBytes));
                  final states = data['states'] as Map<String, dynamic>?;
                  if (states != null) {
                    states.forEach((key, value) {
                      _cachedUbillingAlerts[key] = value['alertnow'] == true;
                    });
                  }
                }
              } catch (_) {}
            }()
          : Future.value();

      final results = await Future.wait([
        _fetchUkraineAlarmMapUpdate(),
        _fetchOfficialKyivCityLevel(),
        _fetchOfficialKyivOblastLevel(),
        ubillingFuture,
      ]);

      if (_disposed) return;

      final uaLevels = results[0] as ({int? cityLevel, int? oblastLevel});
      final int? tgCityLevel = results[1] as int?;
      final int? tgOblastLevel = results[2] as int?;

      final Map<String, bool> alerts = Map<String, bool>.from(_cachedUbillingAlerts);
      _cachedUkraineAlarmAlerts.forEach((k, v) {
        alerts[k] = v;
      });

      // Звіряємо map.ukrainealarm.com із офіційними каналами КМВА/КМДА/КОВА:
      // map.ukrainealarm.com дає миттєвий статус і рівень (Yellow/Red), а при розбіжності в рівні під час тривоги враховуємо найвищий рівень (Red = 3)
      int? effectiveCityLevel = uaLevels.cityLevel ?? tgCityLevel;
      if (uaLevels.cityLevel != null && tgCityLevel != null) {
        if (uaLevels.cityLevel! >= 2 && tgCityLevel == 3) {
          effectiveCityLevel = 3;
        }
      }

      int? effectiveOblastLevel = uaLevels.oblastLevel ?? tgOblastLevel;
      if (uaLevels.oblastLevel != null && tgOblastLevel != null) {
        if (uaLevels.oblastLevel! >= 2 && tgOblastLevel == 3) {
          effectiveOblastLevel = 3;
        }
      }

      if (effectiveCityLevel != null) {
        alerts['м. Київ'] = effectiveCityLevel >= 2;
        alerts['__red_м. Київ'] = effectiveCityLevel == 3;
      }
      if (effectiveOblastLevel != null) {
        alerts['Київська область'] = effectiveOblastLevel >= 2;
        alerts['__red_Київська область'] = effectiveOblastLevel == 3;
      }

      state = alerts;
    } catch (_) {
    } finally {
      _isFetching = false;
    }

    _scheduleNextFetch(6);
  }
}

final alertsProvider = NotifierProvider<AlertsNotifier, Map<String, bool>>(() {
  return AlertsNotifier();
});

// --- Інтеграція радарних цілей https://map.ukrainealarm.com/ ---
const double _kUaViewboxWidth = 260.0;
const double _kUaViewboxHeight = 175.0;
const double _kUaWest = 22.137059;
const double _kUaEast = 40.2275801;
const double _kUaSouth = 44.184598;
const double _kUaNorth = 52.3791473;

double _uaToRadians(double deg) => deg * math.pi / 180.0;
double _uaToDegrees(double rad) => rad * 180.0 / math.pi;
double _uaMercatorY(double lat) => math.log(math.tan(math.pi / 4.0 + _uaToRadians(lat) / 2.0));

/// Конвертує нормалізовані Mercator-координати (x, y + markerOffsetX, markerOffsetY)
/// із https://map.ukrainealarm.com/api/v2/data/targetsForMapsState/public?separateTracks=true у LatLng
LatLng _ukraineAlarmNormalizedToLatLng(
  double normX,
  double normY, {
  double offsetX = 0.0,
  double offsetY = 0.0,
}) {
  final double projWidth = _uaToRadians(_kUaEast - _kUaWest);
  final double projHeight = _uaMercatorY(_kUaNorth) - _uaMercatorY(_kUaSouth);
  final double projScale = math.min(_kUaViewboxWidth / projWidth, _kUaViewboxHeight / projHeight);
  final double projOffsetX = (_kUaViewboxWidth - projWidth * projScale) / 2.0;
  final double projOffsetY = (_kUaViewboxHeight - projHeight * projScale) / 2.0;

  final double mapX = (normX + offsetX) * _kUaViewboxWidth;
  final double mapY = (normY + offsetY) * _kUaViewboxHeight;
  final double lon = _kUaWest + _uaToDegrees((mapX - projOffsetX) / projScale);
  final double projLat = _uaMercatorY(_kUaNorth) - (mapY - projOffsetY) / projScale;
  final double lat = _uaToDegrees(2.0 * math.atan(math.exp(projLat)) - math.pi / 2.0);
  return LatLng(lat, lon);
}

LatLng _offsetLatLngByBearingMeters(LatLng origin, double bearingDegrees, double distanceMeters) {
  const double earthRadius = 6378137.0;
  final double angDist = distanceMeters / earthRadius;
  final double brng = _uaToRadians(bearingDegrees);
  final double lat1 = _uaToRadians(origin.latitude);
  final double lon1 = _uaToRadians(origin.longitude);

  final double lat2 = math.asin(
    math.sin(lat1) * math.cos(angDist) + math.cos(lat1) * math.sin(angDist) * math.cos(brng),
  );
  final double lon2 = lon1 +
      math.atan2(
        math.sin(brng) * math.sin(angDist) * math.cos(lat1),
        math.cos(angDist) - math.sin(lat1) * math.sin(lat2),
      );
  return LatLng(_uaToDegrees(lat2), _uaToDegrees(lon2));
}

bool _isPointInPolygonRings(LatLng point, List<List<LatLng>> rings) {
  for (final poly in rings) {
    if (poly.length < 3) continue;
    bool inside = false;
    for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final xi = poly[i].longitude, yi = poly[i].latitude;
      final xj = poly[j].longitude, yj = poly[j].latitude;
      final intersect = ((yi > point.latitude) != (yj > point.latitude)) &&
          (point.longitude < (xj - xi) * (point.latitude - yi) / ((yj - yi) == 0 ? 1e-12 : (yj - yi)) + xi);
      if (intersect) inside = !inside;
    }
    if (inside) return true;
  }
  return false;
}

/// Перевіряє, чи точка знаходиться в межах м. Київ або Київської області
/// (або на безпосередньому підльоті <= 10 км до кордону Київської області з курсом всередину області)
bool _isPointInKyivOblastOrCity(LatLng point, {double? headingDeg}) {
  if (_isPointInKyivCity(point)) return true;
  final oblastPolys = _kCachedRegionPolygons['Київська область'];
  if (oblastPolys != null && oblastPolys.isNotEmpty) {
    if (_isPointInPolygonRings(point, oblastPolys)) return true;
    if (headingDeg != null) {
      // Якщо ціль за <= 10 км від межі області і її вектор вказує всередину Київської області
      final LatLng aheadPt = _offsetLatLngByBearingMeters(point, headingDeg, 10000.0);
      if (_isPointInPolygonRings(aheadPt, oblastPolys) || _isPointInKyivCity(aheadPt)) {
        return true;
      }
    }
    return false;
  }
  // Fallback до завантаження GeoJSON: координатний прямокутник Київської області
  return point.latitude >= 49.18 &&
      point.latitude <= 51.55 &&
      point.longitude >= 29.25 &&
      point.longitude <= 32.20;
}

String _findNearestKyivSettlementName(LatLng point) {
  String bestName = _isPointInKyivCity(point) ? 'Київ' : 'Київська область';
  double bestDist = double.infinity;
  const distance = Distance();
  _kKyivLocations.forEach((key, val) {
    if (_kExternalBorderKeys.contains(key)) return;
    if (key == 'київ' || key == 'київщин') return;
    final d = distance.as(LengthUnit.Meter, point, LatLng(val.$1, val.$2));
    if (d < bestDist && d <= 22000.0) {
      bestDist = d;
      bestName = val.$3;
    }
  });
  return bestName;
}

class UkraineAlarmTargetsNotifier extends Notifier<List<Map<String, dynamic>>> {
  Timer? _timer;
  final http.Client _httpClient = http.Client();
  bool _disposed = false;
  bool _isFetching = false;
  final Map<String, Map<String, dynamic>> _trackedTargets = {};

  @override
  List<Map<String, dynamic>> build() {
    _disposed = false;
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      _httpClient.close();
    });
    _scheduleNextFetch(0);
    return const [];
  }

  void _scheduleNextFetch(int seconds) {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(Duration(seconds: seconds), _fetchTargets);
  }

  Future<void> refreshNow() => _fetchTargets();

  (String, String, double) _classifyUkraineAlarmTarget(
    String detectedType,
    String iconName,
    String formular, {
    String? prevType,
    String? prevLabel,
    double? prevSpeed,
  }) {
    final dt = detectedType.toLowerCase();
    final ic = iconName.toLowerCase();
    final fm = formular.toLowerCase();

    if (dt.isEmpty && ic.isEmpty && fm.isEmpty && prevType != null && prevLabel != null && prevSpeed != null) {
      return (prevType, prevLabel, prevSpeed);
    }

    if (dt.contains('shahedjet') || ic.contains('shahed_jet') || fm.contains('реакт')) {
      return ('shahed_jet', 'Реактивний БпЛА', 550.0);
    }
    if (dt.contains('mesh') || ic.contains('mesh') || fm.contains('mesh')) {
      return ('uav_guided', 'Удар. mesh-дрон 🎮', 195.0);
    }
    if (dt.contains('orlan') || ic.contains('orlan') || ic.contains('ic_drone') || fm.contains('розвід')) {
      return ('uav_recon', 'РозвідБпЛА 👁️', 130.0);
    }
    if (dt.contains('kab') || ic.contains('airbomb') || fm.contains('каб')) {
      return ('kab', 'КАБ / КАР', 850.0);
    }
    if (dt.contains('ballistic') || ic.contains('ballistic') || fm.contains('баліст')) {
      return ('missile_ballistic', 'Балістична ціль', 5000.0);
    }
    if (dt.contains('missile') || dt.contains('banderol') || ic.contains('missile') || ic.contains('banderol') || fm.contains('ракет') || fm.contains('бандерол')) {
      return ('missile_cruise', 'Крилата ракета', 850.0);
    }
    if (prevType != null && prevType != 'shahed' && dt == 'shahed') {
      return (prevType, prevLabel ?? 'Шахед / БпЛА', prevSpeed ?? 185.0);
    }
    return ('shahed', 'Шахед / БпЛА', 185.0);
  }

  Future<void> _fetchTargets() async {
    if (_disposed || _isFetching) return;
    _isFetching = true;
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final resp = await _httpClient.get(
        Uri.parse('https://map.ukrainealarm.com/api/v2/data/targetsForMapsState/public?separateTracks=true&_t=$ts'),
        headers: const {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Accept': 'application/json',
          'Referer': 'https://map.ukrainealarm.com/',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
        },
      ).timeout(const Duration(seconds: 4));

      if (resp.statusCode == 200 && resp.bodyBytes.length <= 524288) {
        final data = json.decode(utf8.decode(resp.bodyBytes, allowMalformed: true));
        if (data is Map<String, dynamic>) {
          final nowUtc = DateTime.now().toUtc();
          final rawTargets = (data['targets'] as List?) ?? const [];
          final rawFromList = (data['movement'] is Map ? (data['movement']['from'] as List?) : null) ?? const [];

          final Map<String, LatLng> fromByTrackId = {};
          for (final f in rawFromList) {
            if (f is! Map) continue;
            final tid = (f['trackId'] ?? '').toString();
            final fx = (f['x'] as num?)?.toDouble();
            final fy = (f['y'] as num?)?.toDouble();
            if (tid.isNotEmpty && fx != null && fy != null) {
              final offX = (f['markerOffsetX'] as num?)?.toDouble() ?? 0.0;
              final offY = (f['markerOffsetY'] as num?)?.toDouble() ?? 0.0;
              fromByTrackId[tid] = _ukraineAlarmNormalizedToLatLng(fx, fy, offsetX: offX, offsetY: offY);
            }
          }

          final Set<String> seenActiveIds = {};
          const distance = Distance();

          for (final raw in rawTargets) {
            if (raw is! Map) continue;
            final String trackId = (raw['trackId'] ?? '').toString().trim();
            final double? nx = (raw['x'] as num?)?.toDouble();
            final double? ny = (raw['y'] as num?)?.toDouble();
            if (trackId.isEmpty || nx == null || ny == null) continue;

            final double offX = (raw['markerOffsetX'] as num?)?.toDouble() ?? 0.0;
            final double offY = (raw['markerOffsetY'] as num?)?.toDouble() ?? 0.0;
            final LatLng currentPt = _ukraineAlarmNormalizedToLatLng(nx, ny, offsetX: offX, offsetY: offY);
            final double? heading = (raw['heading'] as num?)?.toDouble();
            final int count = (raw['currentCount'] as num?)?.toInt() ?? 1;
            final bool isFading = raw['isFading'] == true;

            final prevEntry = _trackedTargets[trackId];
            final bool isInKyivRegion = _isPointInKyivOblastOrCity(currentPt, headingDeg: heading);

            if (!isInKyivRegion) {
              if (prevEntry != null && prevEntry['wasInKyivRegion'] == true) {
                // Ціль щойно вийшла за межі Київської області
                prevEntry['isExitingOblast'] = true;
                prevEntry['point'] = currentPt;
                prevEntry['lastSeenAt'] = nowUtc;
                prevEntry['disappearedAt'] ??= nowUtc;
              }
              continue;
            }

            seenActiveIds.add(trackId);

            final String rawDetectedType = (raw['detectedType'] ?? '').toString();
            final String rawIconName = (raw['iconName'] ?? '').toString();
            final String rawFormular = (raw['formular'] ?? '').toString();

            final (type, label, speed) = _classifyUkraineAlarmTarget(
              rawDetectedType,
              rawIconName,
              rawFormular,
              prevType: prevEntry?['type'] as String?,
              prevLabel: prevEntry?['label'] as String?,
              prevSpeed: prevEntry?['speed'] as double?,
            );

            LatLng? predictedPt;
            if (raw['prediction'] is Map) {
              final pred = raw['prediction'] as Map;
              final toX = (pred['toX'] as num?)?.toDouble();
              final toY = (pred['toY'] as num?)?.toDouble();
              if (toX != null && toY != null) {
                predictedPt = _ukraineAlarmNormalizedToLatLng(toX, toY);
              }
            }

            final String nearestName = _findNearestKyivSettlementName(currentPt);

            if (prevEntry == null) {
              final List<LatLng> waypoints = [];
              final List<String> locNames = [];
              final LatLng? fromPt = fromByTrackId[trackId];
              if (fromPt != null && distance.as(LengthUnit.Meter, fromPt, currentPt) >= 250.0) {
                waypoints.add(fromPt);
                final fromName = _findNearestKyivSettlementName(fromPt);
                if (fromName.isNotEmpty) locNames.add(fromName);
              } else if (heading != null) {
                final LatLng tailPt = _offsetLatLngByBearingMeters(currentPt, (heading + 180.0) % 360.0, 2400.0);
                waypoints.add(tailPt);
              }
              waypoints.add(currentPt);
              if (nearestName.isNotEmpty && (locNames.isEmpty || locNames.last != nearestName)) {
                locNames.add(nearestName);
              }

              _trackedTargets[trackId] = {
                'trackId': trackId,
                'type': type,
                'label': label,
                'speed': speed,
                'point': currentPt,
                'predictedPt': predictedPt,
                'heading': heading ?? prevEntry?['heading'],
                'count': count,
                'isFading': isFading,
                'waypoints': waypoints,
                'locNames': locNames,
                'nearestName': nearestName,
                'firstSeenAt': nowUtc,
                'lastMovedAt': nowUtc,
                'lastSeenAt': nowUtc,
                'disappearedAt': null,
                'wasInKyivRegion': true,
                'isExitingOblast': false,
              };
            } else {
              final LatLng prevPt = prevEntry['point'] as LatLng;
              final double movedMeters = distance.as(LengthUnit.Meter, prevPt, currentPt);
              final List<LatLng> waypoints = List<LatLng>.from((prevEntry['waypoints'] as List<LatLng>?) ?? [prevPt]);
              final List<String> locNames = List<String>.from((prevEntry['locNames'] as List<String>?) ?? []);

              DateTime lastMovedAt = (prevEntry['lastMovedAt'] as DateTime?) ?? nowUtc;
              if (movedMeters >= 85.0) {
                lastMovedAt = nowUtc;
                if (waypoints.isEmpty || distance.as(LengthUnit.Meter, waypoints.last, currentPt) >= 280.0) {
                  waypoints.add(currentPt);
                  if (waypoints.length > 10) {
                    waypoints.removeAt(0);
                  }
                } else {
                  waypoints[waypoints.length - 1] = currentPt;
                }
                if (nearestName.isNotEmpty && (locNames.isEmpty || locNames.last != nearestName)) {
                  locNames.add(nearestName);
                  if (locNames.length > 4) {
                    locNames.removeAt(0);
                  }
                }
              } else if (heading != null && waypoints.length == 1) {
                final LatLng tailPt = _offsetLatLngByBearingMeters(currentPt, (heading + 180.0) % 360.0, 2400.0);
                waypoints.insert(0, tailPt);
              }

              prevEntry['type'] = type;
              prevEntry['label'] = label;
              prevEntry['speed'] = speed;
              prevEntry['point'] = currentPt;
              prevEntry['predictedPt'] = predictedPt;
              if (heading != null) prevEntry['heading'] = heading;
              prevEntry['count'] = count;
              prevEntry['isFading'] = isFading;
              prevEntry['waypoints'] = waypoints;
              prevEntry['locNames'] = locNames;
              prevEntry['nearestName'] = nearestName;
              prevEntry['lastMovedAt'] = lastMovedAt;
              prevEntry['lastSeenAt'] = nowUtc;
              prevEntry['disappearedAt'] = null;
              prevEntry['wasInKyivRegion'] = true;
              prevEntry['isExitingOblast'] = false;
            }
          }

          // Позначаємо цілі, які зникли з радара map.ukrainealarm.com, та прибираємо старі (> 3 хв після зникнення)
          final List<String> toRemove = [];
          _trackedTargets.forEach((tid, entry) {
            if (!seenActiveIds.contains(tid)) {
              entry['disappearedAt'] ??= nowUtc;
              final DateTime disappearedAt = entry['disappearedAt'] as DateTime;
              if (nowUtc.difference(disappearedAt).inSeconds > kLostTrackRetentionSec) {
                toRemove.add(tid);
              }
            }
          });
          for (final tid in toRemove) {
            _trackedTargets.remove(tid);
          }

          if (!_disposed) {
            state = _trackedTargets.values.map((e) => Map<String, dynamic>.from(e)).toList();
          }
        }
      }
    } catch (_) {
    } finally {
      _isFetching = false;
    }

    _scheduleNextFetch(5);
  }
}

final ukraineAlarmTargetsProvider = NotifierProvider<UkraineAlarmTargetsNotifier, List<Map<String, dynamic>>>(() {
  return UkraineAlarmTargetsNotifier();
});



class WatchedLocationsNotifier extends Notifier<List<WatchedLocation>> {
  static const _defaultLocations = [
    WatchedLocation(
      id: 'kyiv_center_default',
      name: 'Київ (Центр)',
      address: 'Майдан Незалежності, Київ',
      point: LatLng(50.4501, 30.5234),
      radiusMeters: 4000.0,
      enabled: true,
    ),
  ];

  @override
  List<WatchedLocation> build() {
    _loadFromDisk();
    return _defaultLocations;
  }

  Future<void> _loadFromDisk() async {
    try {
      final file = await _getAppStorageFile('watched_locations.json');
      if (file != null && await file.exists()) {
        if (await file.length() > 524288) return;
        final content = await file.readAsString();
        final list = json.decode(content) as List;
        if (list.isNotEmpty) {
          state = list.map((e) => WatchedLocation.fromJson(e as Map<String, dynamic>)).toList();
        }
      }
    } catch (_) {}
  }

  Future<void> _saveToDisk() async {
    try {
      final file = await _getAppStorageFile('watched_locations.json');
      if (file != null) {
        final content = json.encode(state.map((e) => e.toJson()).toList());
        await file.writeAsString(content);
      }
    } catch (_) {}
  }

  void addLocation(WatchedLocation loc) {
    state = [...state, loc];
    _saveToDisk();
  }

  void removeLocation(String id) {
    state = state.where((l) => l.id != id).toList();
    _saveToDisk();
  }

  void toggleLocation(String id) {
    state = [
      for (final loc in state)
        if (loc.id == id) loc.copyWith(enabled: !loc.enabled) else loc
    ];
    _saveToDisk();
  }

  void updateRadius(String id, double radius) {
    state = [
      for (final loc in state)
        if (loc.id == id) loc.copyWith(radiusMeters: radius) else loc
    ];
    _saveToDisk();
  }
}

final watchedLocationsProvider = NotifierProvider<WatchedLocationsNotifier, List<WatchedLocation>>(() {
  return WatchedLocationsNotifier();
});

const int kCurrentVersionCode = kDefaultVersionCode;
const String kCurrentVersionName = kDefaultVersionName;


class RemoteConfigNotifier extends Notifier<RemoteConfig> {
  Timer? _refreshTimer;

  @override
  RemoteConfig build() {
    _init();
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      _fetchRemoteConfig();
    });
    ref.onDispose(() {
      _refreshTimer?.cancel();
    });
    return const RemoteConfig();
  }

  Future<void> _init() async {
    // 1. Спочатку завантажуємо кеш, щоб миттєво підтягнути локальні дані без блокування
    await _loadFromCache();
    // 2. Робимо мережевий запит із повторними спробами (на випадок затримки мережі при старті/ребуті)
    await _fetchRemoteConfigWithRetries();
  }

  Future<void> _loadFromCache() async {
    try {
      final file = await _getAppStorageFile('remote_config_cache.json');
      if (file != null && await file.exists()) {
        if (await file.length() > 524288) return;
        final content = await file.readAsString();
        final jsonMap = json.decode(content) as Map<String, dynamic>;
        final cfg = RemoteConfig.fromJson(jsonMap);
        // Захист від затирання: оновлюємо стан з кешу тільки якщо поточний стан є дефолтним або кеш новіший
        if (state.versionCode <= cfg.versionCode) {
          state = cfg;
          await _loadLearnedLocations();
          _kKyivLocations = {..._learnedLocations, ..._kBaseKyivLocations, ...cfg.extraLocations};
          _dynamicExtraChannels = cfg.extraChannels;
          _dynamicDangerKeywords = cfg.extraDangerKeywords;
          _dynamicClearKeywords = cfg.extraClearKeywords;
        }
      }
    } catch (_) {}
  }

  Future<void> _saveToCache(RemoteConfig cfg) async {
    try {
      final file = await _getAppStorageFile('remote_config_cache.json');
      if (file != null) {
        await file.writeAsString(json.encode(cfg.toJson()));
      }
    } catch (_) {}
  }

  Future<void> _fetchRemoteConfigWithRetries() async {
    bool ok = await _fetchRemoteConfig();
    if (!ok) {
      // Перша повторна спроба через 4 секунди (якщо Wi-Fi/LTE ще підключається після перезавантаження)
      await Future.delayed(const Duration(seconds: 4));
      ok = await _fetchRemoteConfig();
      if (!ok) {
        // Друга повторна спроба через 10 секунд
        await Future.delayed(const Duration(seconds: 10));
        await _fetchRemoteConfig();
      }
    }
  }

  Future<bool> _fetchRemoteConfig() async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final urls = [
      'https://raw.githubusercontent.com/yakymgo-cyber/kyiv-alert-updates/main/remote_config.json?t=$timestamp',
    ];

    for (final url in urls) {
      try {
        final response = await http.get(
          Uri.parse(url),
          headers: {
            'Cache-Control': 'no-cache, no-store, must-revalidate',
            'Pragma': 'no-cache',
            'Expires': '0',
          },
        ).timeout(const Duration(seconds: 12));
        if (response.statusCode == 200 && response.bodyBytes.length <= 262144) {
          final jsonMap = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          final cfg = RemoteConfig.fromJson(jsonMap);
          state = cfg;
          _kKyivLocations = {..._learnedLocations, ..._kBaseKyivLocations, ...cfg.extraLocations};
          _dynamicExtraChannels = cfg.extraChannels;
          _dynamicDangerKeywords = cfg.extraDangerKeywords;
          _dynamicClearKeywords = cfg.extraClearKeywords;
          await _saveToCache(cfg);
          return true;
        }
      } catch (e) {
        debugPrint('RemoteConfig fetch error: $e');
      }
    }
    return false;
  }

  Future<bool> refresh() => _fetchRemoteConfig();
}

final remoteConfigProvider = NotifierProvider<RemoteConfigNotifier, RemoteConfig>(() {
  return RemoteConfigNotifier();
});


class MessagesNotifier extends Notifier<List<dynamic>> {
  Timer? _timer;
  final http.Client _httpClient = http.Client();
  final Map<String, int> _lastChannelPostId = {};
  final Map<String, List<Map<String, dynamic>>> _channelMessagesCache = {};
  int _pollCycleCount = 0;
  bool _isFirstLoad = true;
  bool _disposed = false;
  bool _isFetching = false;
  int _backendSkipCycles = 0;

  @override
  List<dynamic> build() {
    _disposed = false;
    onNewLocationLearned = () {
      if (!_disposed) {
        state = [...state];
      }
    };
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      _httpClient.close();
      onNewLocationLearned = null;
    });

    loadLearnedLocations();
    _fetchData();
    return [];
  }

  int? extractAltitude(String text) => ThreatParser.extractAltitude(text);
  int? extractSpeed(String text) => ThreatParser.extractSpeed(text);
  List<Map<String, dynamic>> parseLocalThreats(String text) => ThreatParser.parseLocalThreats(text);
  String cleanHtmlText(String html, {int maxLength = 600}) => cleanHtmlString(html, maxLength: maxLength);
  String categorizeLocalMessage(String text) => ThreatParser.categorizeLocalMessage(text);
  List<dynamic> deduplicateMessages(List<dynamic> rawMsgs) => ThreatParser.deduplicateMessages(rawMsgs);

  Future<void> refreshNow() => _fetchData();

  String _decodeLocalToken() {
    const encoded = [49, 3, 51, 12, 5, 59, 22, 63, 8, 46, 5, 9, 63, 25, 40, 31, 46, 5, 99, 99, 104, 107];
    return String.fromCharCodes(encoded.map((b) => b ^ 0x5A));
  }

  List<Map<String, dynamic>> _parseChannelHtml(String html, (String, String, bool) ch) {
    final blocks = html.split('tgme_widget_message_wrap');
    final List<Map<String, dynamic>> chMsgs = [];
    if (blocks.length <= 1) return chMsgs;

    int maxSeenId = _lastChannelPostId[ch.$1] ?? 0;
    final startIdx = blocks.length > 18 ? blocks.length - 18 : 1;

    for (int i = startIdx; i < blocks.length; i++) {
      final b = blocks[i];
      final timeMatch = RegExp(r'<time datetime="([^"]+)"').firstMatch(b);
      final postMatch = RegExp(r'data-post="([^"]+)"').firstMatch(b);
      final String? postId = postMatch?.group(1);
      final idMatch = RegExp(r'data-post="[^/]+/(\d+)"').firstMatch(b);
      final int msgId = int.tryParse(postId?.split('/').last ?? '') ?? (int.tryParse(idMatch?.group(1) ?? '0') ?? i);

      // Фіксуємо максимальний ID поста на каналі ДО будь-яких фільтрів Києва,
      // щоб інкрементальний XHR (?after=) завжди запитував лише найновіші пости!
      if (msgId > maxSeenId && msgId > 10) {
        maxSeenId = msgId;
      }

      final replyHrefMatch = RegExp(r'tgme_widget_message_reply[^>]*href="(?:https?://t\.me/|/)?([^"]+)"').firstMatch(b);
      final String? replyToPostId = replyHrefMatch?.group(1);
      final int? replyToId = replyToPostId != null ? int.tryParse(replyToPostId.split('/').last) : null;

      String? replyQuotedText;
      final replyBlockMatch = RegExp(r'<a[^>]*class="[^"]*tgme_widget_message_reply[^"]*"[\s\S]*?</a>').firstMatch(b);
      if (replyBlockMatch != null) {
        final replyBlock = replyBlockMatch.group(0)!;
        final rTextMatch = RegExp(r'tgme_widget_message_reply_text[^>]*>([\s\S]*?)</div>').firstMatch(replyBlock);
        if (rTextMatch != null) {
          replyQuotedText = _cleanHtmlText(rTextMatch.group(1)!).replaceAll('\n', ' ').trim();
        } else {
          final clean = _cleanHtmlText(replyBlock).replaceAll('\n', ' ').trim();
          if (clean.isNotEmpty) replyQuotedText = clean;
        }
      }

      // Вирізаємо блок цитати reply перед парсингом основного тексту!
      final bWithoutReply = b.replaceAll(RegExp(r'<a[^>]*class="[^"]*tgme_widget_message_reply[^"]*"[\s\S]*?</a>'), '');

      final mainTextMatches = RegExp(r'tgme_widget_message_text(?![^>]*reply)[^>]*>([\s\S]*?)</div>').allMatches(bWithoutReply);
      final textMatch = mainTextMatches.isNotEmpty
          ? mainTextMatches.last
          : RegExp(r'tgme_widget_message_text[^>]*>([\s\S]*?)</div>').allMatches(bWithoutReply).lastOrNull;

      if (textMatch == null || timeMatch == null) continue;

      DateTime? msgTime;
      try {
        msgTime = DateTime.parse(timeMatch.group(1)!).toUtc();
      } catch (_) {}
      if (msgTime != null && DateTime.now().toUtc().difference(msgTime).inHours >= 12) {
        continue;
      }

      String cleanText = _cleanHtmlText(textMatch.group(1)!);
      if (cleanText.isEmpty) continue;

      final tLower = cleanText.toLowerCase();

      // Спеціальний фільтр для каналу air_alert_ua
      if (ch.$1 == 'air_alert_ua') {
        const allowedAirAlertKeywords = [
          'київ', 'бровар', 'борисп', 'бучан', 'фастів', 'обухів', 'вишгород', 'білоцерків'
        ];
        if (!allowedAirAlertKeywords.any((kw) => tLower.contains(kw))) {
          continue;
        }
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

      if (hasExtHashtag || hasExtPhrase) {
        continue;
      }

      final msgType = _categorizeLocalMessage(cleanText);
      if (msgType == 'ignore') continue;

      // 1. Специфічні стоп-слова всеукраїнських зведень та інших регіонів
      const globalDigestStopWords = [
        'кроп', 'кропивницьк', 'знам\'ян', 'знамян', 'олександрі', 'павлиш',
        'горішні плавні', 'омельник', 'лихівка', 'жовті води', 'карлівка',
        'берестин', 'чутове', 'магдалинівк', 'кобеля', 'перещепин', 'долинськ',
        'устинівк', 'широке', 'кривий ріг', 'херсонщин', 'миколаївщин', 'запоріжж',
        'дніпропетров', 'харківщин', 'сумщин', 'донеччин', 'луганщин', 'одещин'
      ];
      final bool hasGlobalStopWord = globalDigestStopWords.any((sw) {
        if (sw == 'олександрі') {
          return tLower.contains('олександрі') && !tLower.contains('олександрів');
        }
        return tLower.contains(sw);
      });
      if (hasGlobalStopWord) {
        continue;
      }

      // 2. Фільтр на всеукраїнські та міжрегіональні дайджести
      final Set<String> externalMatches = {};
      for (final r in _kFarRegions) {
        if (tLower.contains(r)) externalMatches.add(r);
      }
      for (final b in _kExternalBorderKeys) {
        if (tLower.contains(b)) externalMatches.add(b);
      }

      final bool hasTrajectory = tLower.contains('->') || tLower.contains('—>') || tLower.contains('-->');
      if ((externalMatches.length >= 3 && !hasTrajectory) || externalMatches.length >= 4) {
        continue;
      }

      final lowerCheck = cleanText.toLowerCase();

      // Фільтрація суто іногородніх постів для ВСІХ каналів (включно з kyiv_airdef)
      const kyivStrictAnchors = [
        'київ', 'київщин', 'область', 'бровар', 'борисп', 'обухів',
        'васильків', 'біла церкв', 'фастів', 'вишгород', 'буч', 'ірпін',
        'іванків', 'славутич', 'згурівк', 'яготин', 'переяслав', 'березан',
        'баришівк', 'кагарлик', 'миронівк', 'богуслав', 'рокитн', 'сквир',
        'тетіїв', 'чзв', 'зону', 'столиц',
      ];
      final bool hasKyivStrictAnchor = kyivStrictAnchors.any((a) => lowerCheck.contains(a)) ||
          _kKyivLocations.keys.any((k) => !_kExternalBorderKeys.contains(k) && lowerCheck.contains(k));

      final bool isDniproWaterway = lowerCheck.contains('по дніпру') ||
          lowerCheck.contains('вздовж дніпра') ||
          lowerCheck.contains('руслом дніпра') ||
          lowerCheck.contains('через дніпро');

      const farTransitPhrases = [
        'в полтавську', 'на полтавський', 'в полтав', 'на полтав', 'полтавськ',
        'у вінницьку', 'на вінницьку', 'у вінниц', 'на вінниц', 'вінницьк',
        'на луцьк', 'луцьк', 'на хмель', 'хмельницьк', 'хмельниц',
        'на кременчук', 'кременчук', 'одещин', 'в одес', 'на одес', 'одес',
        'запоріж', 'харків', 'львів', 'рівнен', 'терноп',
        'франківськ', 'волин', 'миколаїв', 'херсон', 'сумськ', 'кропивницьк',
        'чернівц', 'закарпат',
        'в дніпро', 'на дніпро', 'у дніпро', 'до дніпра', 'дніпропетровськ',
      ];
      final bool hasFarTransit = !isDniproWaterway && (farTransitPhrases.any((p) => lowerCheck.contains(p)) ||
          _kFarRegions.any((r) => lowerCheck.contains(r)));

      if (hasFarTransit && !hasKyivStrictAnchor) {
        continue;
      }

      if (ch.$3) {
        if (!hasKyivStrictAnchor) {
          continue;
        }
      }

      final threats = (msgType == 'news') ? <Map<String, dynamic>>[] : parseLocalThreats(cleanText);
      if (threats.isEmpty) {
        final bool hasExternalOrFar = _kFarRegions.any((r) => lowerCheck.contains(r)) ||
            _kExternalBorderKeys.any((b) => lowerCheck.contains(b));
        final bool hasKyivAnchor = lowerCheck.contains('київ') ||
            lowerCheck.contains('столиц') ||
            lowerCheck.contains('київщин') ||
            lowerCheck.contains('в зону');
        if (hasExternalOrFar && !hasKyivAnchor) {
          continue;
        }
      }
      final effectiveType = threats.isNotEmpty ? 'danger' : msgType;
      chMsgs.add({
        'id': msgId,
        'postId': postId,
        'reply_to_post_id': replyToPostId,
        'reply_quoted_text': replyQuotedText,
        'text': cleanText,
        'date': timeMatch.group(1)!,
        'type': effectiveType,
        'channel': ch.$2,
        'reply_to_msg_id': replyToId,
        'threats': threats,
      });
    }

    if (maxSeenId > 0) {
      _lastChannelPostId[ch.$1] = maxSeenId;
    }
    return chMsgs;
  }

  bool _mergeChannelMessages(String chKey, List<Map<String, dynamic>> incoming) {
    if (incoming.isEmpty) return false;
    final existing = _channelMessagesCache[chKey] ?? <Map<String, dynamic>>[];
    final Map<int, Map<String, dynamic>> byId = {
      for (final m in existing) (m['id'] as int? ?? 0): m,
    };

    bool hasChanges = false;
    for (final msg in incoming) {
      final int id = msg['id'] as int? ?? 0;
      final prev = byId[id];
      if (prev == null || prev['text'] != msg['text']) {
        hasChanges = true;
      }
      byId[id] = msg;
    }

    final nowUtc = DateTime.now().toUtc();
    final merged = byId.values.where((m) {
      final dt = DateTime.tryParse(m['date']?.toString() ?? '')?.toUtc();
      return dt == null || nowUtc.difference(dt).inHours < 12;
    }).toList();

    merged.sort((a, b) => b['date'].toString().compareTo(a['date'].toString()));
    _channelMessagesCache[chKey] = merged.take(35).toList();
    return hasChanges;
  }

  List<Map<String, dynamic>> _buildCombinedDeduplicatedList() {
    final List<Map<String, dynamic>> allMsgs = [];
    for (final list in _channelMessagesCache.values) {
      for (final m in list) {
        // Копіюємо Map, щоб гео-дедуплікація не мутувала об'єкти у по-канальному кеші
        allMsgs.add(Map<String, dynamic>.from(m));
      }
    }
    allMsgs.sort((a, b) => b['date'].toString().compareTo(a['date'].toString()));
    return deduplicateMessages(allMsgs).cast<Map<String, dynamic>>().take(100).toList();
  }

  Future<List<Map<String, dynamic>>> _fetchSingleChannel((String, String, bool) ch) async {
    final String chKey = ch.$1;
    final int? knownLastId = _lastChannelPostId[chKey];
    final bool hasCache = (_channelMessagesCache[chKey]?.isNotEmpty ?? false);
    final bool useIncrementalXhr = knownLastId != null &&
        knownLastId > 2 &&
        hasCache &&
        (_pollCycleCount % 6 != 0);

    // 1. Надшвидке інкрементальне XHR-опитування POST ?after=<lastId - 2> (обходить CDN-кеш і важить ~6 КБ замість 100 КБ)
    if (useIncrementalXhr) {
      try {
        final uri = Uri.parse('https://t.me/s/$chKey?after=${knownLastId - 2}');
        final resp = await _httpClient.post(
          uri,
          headers: {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
            'X-Requested-With': 'XMLHttpRequest',
            'Accept': 'application/json, text/javascript, */*; q=0.01',
            'Origin': 'https://t.me',
            'Referer': 'https://t.me/s/$chKey',
            'Cache-Control': 'no-cache, no-store, must-revalidate',
            'Pragma': 'no-cache',
          },
        ).timeout(const Duration(seconds: 4));

        if (resp.statusCode == 200 && resp.bodyBytes.length <= 524288) {
          final rawStr = utf8.decode(resp.bodyBytes, allowMalformed: true).trim();
          if (rawStr.isEmpty || rawStr == '""') {
            return const <Map<String, dynamic>>[];
          }
          String html = rawStr;
          if (rawStr.startsWith('"')) {
            try {
              final decoded = json.decode(rawStr);
              if (decoded is String) {
                html = decoded;
              }
            } catch (_) {}
          }
          return _parseChannelHtml(html, ch);
        }
      } catch (_) {
        // При помилці XHR плавно переходимо до GET ?before=
      }
    }

    // 2. Повна синхронізація з параметром ?before= (нативний параметр Telegram, який гарантовано обходить кеш статики /s/)
    try {
      final int dynamicBefore = (knownLastId != null && knownLastId > 0)
          ? (knownLastId + 50 + (_pollCycleCount % 29))
          : (90000000 + (DateTime.now().millisecondsSinceEpoch ~/ 1000) % 9000000);
      final uri = Uri.parse('https://t.me/s/$chKey?before=$dynamicBefore');
      final resp = await _httpClient.get(
        uri,
        headers: const {
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Cache-Control': 'no-cache, no-store, must-revalidate',
          'Pragma': 'no-cache',
          'Expires': '0',
        },
      ).timeout(const Duration(seconds: 6));

      if (resp.statusCode != 200 || resp.bodyBytes.length > 524288) {
        return const <Map<String, dynamic>>[];
      }
      final html = utf8.decode(resp.bodyBytes, allowMalformed: true);
      return _parseChannelHtml(html, ch);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  Future<List<Map<String, dynamic>>> _fetchDirectTelegramChannels() async {
    _pollCycleCount++;
    final baseChannels = [
      ('kyiv_airdef', 'Kyiv AirDefense 🌇', false),
      ('war_monitor', 'monitor', true),
      ('SK_DM_SK', 'SK_DM_SK', true),
      ('air_alert_ua', 'Повітряна тривога', true),
    ];
    final extraChs = _dynamicExtraChannels.map((c) => (c, c, true)).toList();
    final channels = [...baseChannels, ...extraChs];

    final futures = channels.map((ch) async {
      final chMsgs = await _fetchSingleChannel(ch);
      if (chMsgs.isNotEmpty) {
        final bool changed = _mergeChannelMessages(ch.$1, chMsgs);
        // Прогресивне (streaming) оновлення UI: щойно швидкий канал приніс нове повідомлення —
        // одразу оновлюємо радар, не чекаючи завершення повільніших каналів!
        if (changed && !_disposed && !_isFirstLoad) {
          final progressiveList = _buildCombinedDeduplicatedList();
          if (progressiveList.isNotEmpty) {
            state = progressiveList;
          }
        }
      }
      return chMsgs;
    });

    await Future.wait(futures);
    return _buildCombinedDeduplicatedList();
  }

  Future<void> _fetchData() async {
    if (_disposed || _isFetching) return;
    _isFetching = true;
    try {
      bool fetchedFromBackend = false;

      // 1. Локальний loopback тільки для емулятора Android на ПК (10.0.2.2) виключно у Debug-режимі
      if (kDebugMode) {
        if (_backendSkipCycles > 0) {
          _backendSkipCycles--;
        } else {
          try {
            final response = await _httpClient.get(
              Uri.parse('http://10.0.2.2:8000/api/messages'),
              headers: {'X-API-Key': _decodeLocalToken()},
            ).timeout(const Duration(milliseconds: 350));
            if (response.statusCode == 200 && response.bodyBytes.length <= 262144) {
              final data = json.decode(utf8.decode(response.bodyBytes));
              final List<dynamic> msgs = data['messages'] ?? [];
              if (msgs.isNotEmpty && !_disposed) {
                state = deduplicateMessages(msgs);
                fetchedFromBackend = true;
                _backendSkipCycles = 0;
              }
            } else {
              _backendSkipCycles = 200;
            }
          } catch (_) {
            _backendSkipCycles = 200;
          }
        }
      }

      // 2. Автономний HTTPS-режим із підтримкою Keep-Alive та інкрементального XHR POST ?after=
      if (!fetchedFromBackend) {
        try {
          final directMsgs = await _fetchDirectTelegramChannels();
          if (directMsgs.isNotEmpty && !_disposed) {
            state = directMsgs;
          }
        } catch (_) {}
      }
    } finally {
      _isFetching = false;
    }

    if (_disposed) return;
    _isFirstLoad = false;
    _timer?.cancel();
    final alerts = ref.read(alertsProvider);
    final bool isAlert = alerts['м. Київ'] == true || alerts['Київська область'] == true;
    final bool hasThreats = state.any((m) => m['type'] == 'danger');
    // Інтервал опитування: 2.5 с під час тривоги або активних загроз, 4.0 с у спокійному режимі
    final int nextIntervalMs = (isAlert || hasThreats) ? 2500 : 4000;
    _timer = Timer(Duration(milliseconds: nextIntervalMs), _fetchData);
  }

  bool get isLoading => _isFirstLoad && state.isEmpty;
}

final messagesProvider = NotifierProvider<MessagesNotifier, List<dynamic>>(() {
  return MessagesNotifier();
});

const LatLng kyivCenter = LatLng(50.4501, 30.5234);
final Map<String, List<List<LatLng>>> _kCachedRegionPolygons = {};

bool _isPointInKyivCity(LatLng point) {
  final kyivPolys = _kCachedRegionPolygons['м. Київ'];
  if (kyivPolys != null && kyivPolys.isNotEmpty) {
    for (final poly in kyivPolys) {
      if (poly.length < 3) continue;
      bool inside = false;
      for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
        final xi = poly[i].longitude, yi = poly[i].latitude;
        final xj = poly[j].longitude, yj = poly[j].latitude;
        final intersect = ((yi > point.latitude) != (yj > point.latitude)) &&
            (point.longitude < (xj - xi) * (point.latitude - yi) / ((yj - yi) == 0 ? 1e-12 : (yj - yi)) + xi);
        if (intersect) inside = !inside;
      }
      if (inside) return true;
    }
    return false;
  }
  return point.latitude >= 50.2132 &&
      point.latitude <= 50.5908 &&
      point.longitude >= 30.2361 &&
      point.longitude <= 30.8264;
}

List<Polygon> _buildAlertPolygons(Map<String, dynamic> geoJson, Map<String, bool> alerts, List<Map<String, dynamic>> threats, {bool globalMissileThreat = false}) {
  // Кешуємо розпарсені координати областей та м. Київ один раз за все життя додатку
  if (_kCachedRegionPolygons.isEmpty) {
    final features = geoJson['features'] as List;
    for (var feature in features) {
      final props = feature['properties'];
      final name = (props['name:uk'] ?? props['name'] ?? '').toString();
      final geometry = feature['geometry'];
      if (geometry == null) continue;
      
      final type = geometry['type'];
      final coords = geometry['coordinates'];
      final List<List<LatLng>> polyList = [];

      if (type == 'Polygon') {
        final List<LatLng> points = (coords[0] as List)
            .map((p) => LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()))
            .toList();
        polyList.add(points);
      } else if (type == 'MultiPolygon') {
        for (var poly in (coords as List)) {
          final List<LatLng> points = (poly[0] as List)
              .map((p) => LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()))
              .toList();
          polyList.add(points);
        }
      }
      _kCachedRegionPolygons[name] = polyList;
    }
  }

  final List<Polygon> polygons = [];
  final List<List<LatLng>>? kyivCityHole = _kCachedRegionPolygons['м. Київ'];

  for (final entry in _kCachedRegionPolygons.entries) {
    final name = entry.key;
    final isAlert = alerts[name] == true;
    final isKyivRegion = (name == 'Київська область');
    final isKyivCity = (name == 'м. Київ');

    final bool isRegionRed = alerts.containsKey('__red_$name')
        ? (alerts['__red_$name'] == true)
        : globalMissileThreat;

    final threatLevel = _getThreatLevel(isAlert, isKyivRegion || isKyivCity, threats, globalMissileThreat: isRegionRed);
    final fill = _getAlertFillColor(threatLevel);
    final border = (isKyivCity && threatLevel == 1)
        ? Colors.white.withValues(alpha: 0.28)
        : _getAlertBorderColor(threatLevel);
    final holes = isKyivRegion ? kyivCityHole : null;

    for (final points in entry.value) {
      polygons.add(
        Polygon(
          points: points,
          color: fill,
          borderColor: border,
          borderStrokeWidth: isKyivCity ? (threatLevel >= 2 ? 1.8 : 1.3) : 1.0,
          holePointsList: holes,
        ),
      );
    }
  }
  return polygons;
}

class TestMessageIndexNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void setIndex(int index) => state = index;
}

final testMessageIndexProvider = NotifierProvider<TestMessageIndexNotifier, int>(() {
  return TestMessageIndexNotifier();
});

final testModeProvider = NotifierProvider<TestModeNotifier, bool>(() {
  return TestModeNotifier();
});

class TestModeNotifier extends Notifier<bool> {
  Timer? _timer;
  @override
  bool build() {
    ref.onDispose(() => _timer?.cancel());
    return false;
  }

  void toggle() {
    state = !state;
    _timer?.cancel();
    if (state) {
      ref.read(testMessageIndexProvider.notifier).setIndex(1);
      _timer = Timer.periodic(const Duration(seconds: 4), (t) {
        final current = ref.read(testMessageIndexProvider);
        if (current >= 7) {
          t.cancel();
        } else {
          ref.read(testMessageIndexProvider.notifier).setIndex(current + 1);
        }
      });
    } else {
      ref.read(testMessageIndexProvider.notifier).setIndex(0);
    }
  }
}


class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}


class _MainScreenState extends ConsumerState<MainScreen> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  bool _isSettingsMenuOpen = false;
  late final AnimationController _settingsAnimController;
  late final Animation<double> _settingsAnimation;

  void _toggleSettingsMenu() {
    setState(() {
      _isSettingsMenuOpen = !_isSettingsMenuOpen;
      if (_isSettingsMenuOpen) {
        _settingsAnimController.forward();
      } else {
        _settingsAnimController.reverse();
      }
    });
  }

  void _closeSettingsMenu() {
    if (_isSettingsMenuOpen) {
      setState(() {
        _isSettingsMenuOpen = false;
        _settingsAnimController.reverse();
      });
    }
  }
  final MapController _mapController = MapController();
  Timer? _mapCameraAnimTimer;

  void _animatedMapMove(LatLng destLocation, double destZoom) {
    _mapCameraAnimTimer?.cancel();
    if (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        _mapController.move(destLocation, destZoom);
      } catch (_) {}
      return;
    }
    try {
      final startCenter = _mapController.camera.center;
      final startZoom = _mapController.camera.zoom;
      const int totalSteps = 14;
      int step = 0;
      _mapCameraAnimTimer = Timer.periodic(const Duration(milliseconds: 28), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        step++;
        final double t = Curves.easeOutCubic.transform((step / totalSteps).clamp(0.0, 1.0));
        final double lat = startCenter.latitude + (destLocation.latitude - startCenter.latitude) * t;
        final double lon = startCenter.longitude + (destLocation.longitude - startCenter.longitude) * t;
        final double zoom = startZoom + (destZoom - startZoom) * t;
        try {
          _mapController.move(LatLng(lat, lon), zoom);
        } catch (_) {
          timer.cancel();
          return;
        }
        if (step >= totalSteps) {
          timer.cancel();
        }
      });
    } catch (_) {
      try {
        _mapController.move(destLocation, destZoom);
      } catch (_) {}
    }
  }

  final Set<String> _alertedLocationThreatKeys = {};

  final GlobalKey _radarRepaintKey = GlobalKey();
  DateTime? _lastWidgetSyncTime;
  Timer? _widgetSyncDebounceTimer;
  String? _lastWidgetSyncSignature;

  bool _isReplayMode = false;
  double _replayOffsetMinutes = 0.0;
  bool _isReplayPlaying = false;
  Timer? _replayPlayTimer;
  dynamic _selectedThreatMsgId;

  LatLng? _rulerTargetPoint;
  Timer? _rulerClearTimer;
  String _feedFilter = 'all'; // 'all', 'threats', 'defenseClear'
  bool _isSmartFocusActive = false;

  bool _isDownloadingUpdate = false;
  double _downloadProgress = 0.0;

  bool _isNightWatchMode = false;
  DateTime? _lastNightWatchAlarmTime;
  DateTime? _nightWatchDismissedUntil;
  DateTime? _dismissedLaunchTimestamp;

  // Мемоізація розрахунку траєкторій та загроз
  String? _cachedTrajectorySignature;
  List<Map<String, dynamic>> _cachedThreats = [];
  List<Map<String, dynamic>> _cachedActiveAirDefenses = [];
  String? _cachedNorthThreatLabel;
  String? _cachedSouthThreatLabel;
  bool _cachedHasMissiles = false;
  List<Map<String, dynamic>> _cachedLostTracks = [];

  void _triggerNightWatchAlarm() {
    final now = DateTime.now();
    if (LiveRadarNotificationService.instance.isAlarmMuted || VoiceAlertService.instance.isMuted) {
      return;
    }
    if (_nightWatchDismissedUntil != null && now.isBefore(_nightWatchDismissedUntil!)) {
      return;
    }
    if (_lastNightWatchAlarmTime != null && now.difference(_lastNightWatchAlarmTime!).inSeconds < 15) {
      return;
    }
    _lastNightWatchAlarmTime = now;

    Future.microtask(() async {
      for (int i = 0; i < 3; i++) {
        HapticFeedback.heavyImpact();
        SystemSound.play(SystemSoundType.alert);
        if (i < 2) {
          await Future.delayed(const Duration(milliseconds: 400));
        }
      }
    });
  }

  Map<String, dynamic>? _analyzeStrategicThreat(List<dynamic> messages, DateTime now) {
    DateTime? latestClearTime;
    for (final m in messages) {
      final text = (m['text'] ?? '').toString().toLowerCase();
      final dateStr = m['date']?.toString();
      final mTime = (dateStr != null ? DateTime.tryParse(dateStr)?.toUtc() : null) ?? now;
      if (now.difference(mTime).inMinutes.abs() > 180) continue;
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

    Map<String, dynamic>? strategicThreat;
    for (final m in messages) {
      final text = (m['text'] ?? '').toString().toLowerCase();
      final dateStr = m['date']?.toString();
      final mTime = (dateStr != null ? DateTime.tryParse(dateStr)?.toUtc() : null) ?? now;
      final diffMins = now.difference(mTime).inMinutes.abs();
      if (diffMins > 180) continue;

      if (latestClearTime != null && latestClearTime.isAfter(mTime)) continue;

      final bool isLaunches = text.contains('пуски х-101') ||
          text.contains('пускові маневри') ||
          text.contains('пуск крилатих') ||
          text.contains('залп калібр') ||
          text.contains('пуск калібр');

      final bool isAviation = text.contains('ту-95') ||
          text.contains('ту-22') ||
          text.contains('олень') ||
          text.contains('енгельс') ||
          text.contains('зліт бортів') ||
          text.contains('ракетоносі');

      if (isLaunches) {
        if (strategicThreat == null || (strategicThreat['priority'] as int) < 2 || mTime.isAfter(strategicThreat['time'] as DateTime)) {
          strategicThreat = {
            'priority': 2,
            'title': '🚀 Зафіксовано пуски КР: очікується підліт',
            'subtitle': diffMins == 0 ? 'щойно' : '$diffMins хв тому',
            'time': mTime,
            'isLaunch': true,
          };
        }
      } else if (isAviation) {
        if (strategicThreat == null || ((strategicThreat['priority'] as int) < 2 && mTime.isAfter(strategicThreat['time'] as DateTime))) {
          strategicThreat = {
            'priority': 1,
            'title': '✈️ Стратегічна авіація в повітрі (відстеження пусків)',
            'subtitle': diffMins == 0 ? 'щойно' : '$diffMins хв тому',
            'time': mTime,
            'isLaunch': false,
          };
        }
      }
    }

    return strategicThreat;
  }

  Widget _buildStrategicAviationChip(Map<String, dynamic> strategicAlert) {
    final isLaunch = strategicAlert['isLaunch'] == true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isLaunch
              ? [const Color(0xFFD84315), const Color(0xFF4A148C)]
              : [const Color(0xFFE65100), const Color(0xFF311B92)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: (isLaunch ? Colors.deepOrangeAccent : Colors.purpleAccent).withValues(alpha: 0.35),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ],
        border: Border.all(
          color: isLaunch ? Colors.orangeAccent : Colors.purpleAccent.withValues(alpha: 0.7),
          width: 1.2,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              strategicAlert['title'] as String,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '• ${strategicAlert['subtitle']}',
            style: const TextStyle(color: Colors.white70, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildStrategicLaunchBanner(StrategicLaunchEvent launchEvent, DateTime now) {
    final remMin = launchEvent.remainingMinutes(now);
    final estArrival = launchEvent.estimatedArrivalTime.toLocal();
    final timeStr = '${estArrival.hour.toString().padLeft(2, '0')}:${estArrival.minute.toString().padLeft(2, '0')}';

    String titleText;
    if (remMin > 0) {
      titleText = '🚀 Зафіксовано пуски ${launchEvent.type} • Орієнтовний час входу в простір Київщини: ~$remMin хв (о $timeStr)';
    } else if (remMin >= -25) {
      titleText = '🚨 Пуски ${launchEvent.type} • Ракети в повітряному просторі! (розрахунковий час був о $timeStr)';
    } else {
      titleText = '🚀 Пуски ${launchEvent.type} • Відстеження повітряної обстановки';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFFB71C1C), Color(0xFF4A148C)],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.redAccent.withValues(alpha: 0.4),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
        border: Border.all(
          color: Colors.redAccent.withValues(alpha: 0.8),
          width: 1.4,
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.rocket_launch, color: Colors.amberAccent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              titleText,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12.0,
              ),
            ),
          ),
          const SizedBox(width: 6),
          InkWell(
            onTap: () {
              setState(() {
                _dismissedLaunchTimestamp = launchEvent.timestamp;
              });
            },
            borderRadius: BorderRadius.circular(14),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.close, color: Colors.white70, size: 16),
            ),
          ),
        ],
      ),
    );
  }

  void _copyThreatSummary(BuildContext context, Map<String, dynamic> threat, List<WatchedLocation> watchedLocations) {
    final now = DateTime.now();
    final timeStr = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final label = threat['label'] ?? _formatThreatType(threat['type']?.toString() ?? '');
    final route = threat['route'] ?? 'Київський сектор';
    final speed = (threat['speed'] as num?)?.toInt() ?? 185;
    final alt = threat['altitude'] ?? (threat['altitudeMeters'] != null ? '${threat['altitudeMeters']} м' : null);
    final isDescending = threat['isDescending'] == true;
    final isCircling = threat['isCircling'] == true;

    final path = (threat['path'] as List<LatLng>?) ?? [];
    final curPt = path.isNotEmpty ? path.last : const LatLng(50.4501, 30.5234);

    final List<String> locLines = [];
    const distance = Distance();
    for (final loc in watchedLocations.where((l) => l.enabled)) {
      final distMeters = distance.as(LengthUnit.Meter, loc.point, curPt);
      final speedMs = speed * (1000.0 / 3600.0);
      final etaStr = _formatEta(distMeters, speedMs);
      locLines.add('📍 До "${loc.name}": ${(distMeters / 1000.0).toStringAsFixed(1)} км (підліт: $etaStr)');
    }

    final sb = StringBuffer();
    sb.writeln('⚠️ [Kyiv Alert Monitor • $timeStr]');
    sb.writeln('Ціль: $label');
    sb.writeln('Курс: $route');
    sb.write('Швидкість: ~$speed км/год');
    if (alt != null) sb.write(' • Висота: $alt');
    if (isDescending) sb.write(' (ЗНИЖУЄТЬСЯ!)');
    if (isCircling) sb.write(' [Кружляє]');
    sb.writeln();

    if (locLines.isNotEmpty) {
      sb.writeln('Розрахунок дистанції:');
      for (final line in locLines) {
        sb.writeln(line);
      }
    }

    final summary = sb.toString().trim();
    Clipboard.setData(ClipboardData(text: summary));

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          '📋 Зведення скопійовано для відправки рідним!',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
        ),
        backgroundColor: Color(0xFF00838F),
        duration: Duration(seconds: 3),
      ),
    );
  }

  DateTime? _lastResumeCheck;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settingsAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    _settingsAnimation = CurvedAnimation(
      parent: _settingsAnimController,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeInCubic,
    );
    _initAndroidPermissions();
    VoiceAlertService.instance.init();
    LiveRadarNotificationService.instance.init();
    LiveRadarNotificationService.instance.onMuteRequested = () {
      if (mounted) {
        setState(() {
          _nightWatchDismissedUntil = DateTime.now().add(const Duration(minutes: 15));
        });
      }
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _settingsAnimController.dispose();
    _mapCameraAnimTimer?.cancel();
    _replayPlayTimer?.cancel();
    _widgetSyncDebounceTimer?.cancel();
    _rulerClearTimer?.cancel();
    LiveRadarNotificationService.instance.cancelNotification();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(messagesProvider.notifier).refreshNow();
      ref.read(alertsProvider.notifier).refreshNow();
      ref.read(ukraineAlarmTargetsProvider.notifier).refreshNow();
      final now = DateTime.now();
      if (_lastResumeCheck == null || now.difference(_lastResumeCheck!).inSeconds > 60) {
        _lastResumeCheck = now;
        ref.read(remoteConfigProvider.notifier).refresh();
      }
    }
  }

  Future<void> _manualCheckForUpdates(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.cyanAccent),
            ),
            SizedBox(width: 12),
            Text(
              'Перевіряємо наявність оновлень...',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        duration: Duration(seconds: 2),
      ),
    );
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref.read(remoteConfigProvider.notifier).refresh();
    if (!mounted) return;
    final cfg = ref.read(remoteConfigProvider);
    if (cfg.versionCode > kCurrentVersionCode && cfg.apkUrl.isNotEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '🚀 Доступне оновлення v${cfg.versionName} (збірка ${cfg.versionCode})! Банер зʼявився вгорі.',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
          ),
          backgroundColor: Colors.purple.shade700,
          duration: const Duration(seconds: 4),
        ),
      );
    } else if (ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '✅ У вас встановлена найновіша версія (v$kCurrentVersionName, збірка $kCurrentVersionCode).',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
          ),
          backgroundColor: Colors.green.shade800,
          duration: const Duration(seconds: 3),
        ),
      );
    } else {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            '⚠️ Не вдалося звʼязатися із сервером оновлень. Перевірте зʼєднання з мережею.',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
          ),
          backgroundColor: Color(0xFFC65100),
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  void _initAndroidPermissions() {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        const platform = MethodChannel('ua.kyiv.alert.monitor/widget');
        platform.invokeMethod('ensureAndroidPermissions');
      } catch (_) {}
    }
  }

  Widget _buildFeedFilterChip({
    required String label,
    required String filterKey,
    required Color activeColor,
  }) {
    final bool isSelected = _feedFilter == filterKey;
    return InkWell(
      onTap: () {
        setState(() {
          _feedFilter = filterKey;
        });
      },
      borderRadius: BorderRadius.circular(18),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? activeColor.withValues(alpha: 0.22)
              : const Color(0xFF182030),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected ? activeColor.withValues(alpha: 0.85) : const Color(0xFF283246),
            width: isSelected ? 1.3 : 1.0,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: activeColor.withValues(alpha: 0.22),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontSize: 11.5,
            letterSpacing: 0.2,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  void _stopReplayTimer() {
    _replayPlayTimer?.cancel();
    _replayPlayTimer = null;
    _isReplayPlaying = false;
  }

  void _toggleReplayPlay() {
    if (_isReplayPlaying) {
      _stopReplayTimer();
      setState(() {});
    } else {
      setState(() {
        _isReplayPlaying = true;
        if (_replayOffsetMinutes >= -0.5) {
          _replayOffsetMinutes = -30.0;
        }
      });
      _replayPlayTimer?.cancel();
      _replayPlayTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() {
          _replayOffsetMinutes += 0.1;
          if (_replayOffsetMinutes >= 0.0) {
            _replayOffsetMinutes = 0.0;
            _stopReplayTimer();
          }
        });
      });
    }
  }

  String _getReplayTimeLabel() {
    if (_replayOffsetMinutes >= -0.2) {
      return '🔴 НАЖИВО';
    }
    final offsetMins = _replayOffsetMinutes.round().abs();
    final targetTime = DateTime.now().toUtc().add(Duration(seconds: (_replayOffsetMinutes * 60).round()));
    final kyivHour = (targetTime.hour + 3) % 24;
    final hourStr = kyivHour.toString().padLeft(2, '0');
    final minStr = targetTime.minute.toString().padLeft(2, '0');
    return '⏪ -$offsetMins хв ($hourStr:$minStr)';
  }

  String _formatThreatType(String type) {
    switch (type) {
      case 'missile_hypersonic': return 'Гіперзвукова ракета';
      case 'missile_ballistic': return 'Балістична ракета';
      case 'missile_supersonic': return 'Надзвукова ракета (Х-22/Онікс)';
      case 'missile_cruise': return 'Крилата ракета';
      case 'kab': return 'КАБ / КАР';
      case 'uav_guided': return 'БпЛА на керуванні 🎮';
      case 'uav_recon': return 'РозвідБпЛА 👁️';
      case 'uav_decoy': return 'Імітатор / Фальш-ціль';
      case 'shahed_jet': return 'Реактивний БпЛА';
      case 'shahed': return 'Ударний БпЛА (Шахед)';
      default:
        if (type.contains('missile')) return 'Ракета';
        return 'Ціль ($type)';
    }
  }

  Future<void> _downloadAndInstallApk(String apkUrl) async {
    await UpdateService.downloadAndInstallApk(
      apkUrl: apkUrl,
      onProgress: (progress) {
        if (mounted) setState(() => _downloadProgress = progress);
      },
      onError: (err) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(err, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
              backgroundColor: const Color(0xFFC62828),
            ),
          );
        }
      },
      onSavedNonAndroid: (path) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Файл оновлення збережено: $path', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
              backgroundColor: const Color(0xFF2E7D32),
            ),
          );
        }
      },
      onPermissionRequired: () {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                '⚠️ Дозвольте "Встановлювати невідомі додатки" на відкритому екрані та натисніть "Оновити" ще раз.',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
              ),
              duration: Duration(seconds: 7),
              backgroundColor: Color(0xFFB26A00),
            ),
          );
        }
      },
      onDownloadingChanged: (isDownloading) {
        if (mounted) setState(() => _isDownloadingUpdate = isDownloading);
      },
    );
  }

  Widget _buildUpdateBanner(RemoteConfig config) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF6A1B9A), Color(0xFF4A148C)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.6), width: 1.5),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.system_update_rounded, color: Colors.purpleAccent, size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '🚀 Доступне оновлення v${config.versionName}',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                ),
              ),
              if (!_isDownloadingUpdate)
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purpleAccent,
                    foregroundColor: Colors.white,
                    elevation: 2,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  onPressed: () => _downloadAndInstallApk(config.apkUrl),
                  child: const Text('Оновити', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                )
              else
                Text(
                  '${(_downloadProgress * 100).toInt()}%',
                  style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent, fontSize: 13),
                ),
            ],
          ),
          if (config.changelog.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              config.changelog,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (_isDownloadingUpdate) ...[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _downloadProgress > 0 ? _downloadProgress : null,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.greenAccent),
                minHeight: 5,
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _scheduleWidgetSync(Map<String, bool> alerts, List<Map<String, dynamic>> threats, List<dynamic> messages) {
    if (kIsWeb || !Platform.isAndroid) return;
    final firstId = messages.isNotEmpty ? (messages.first['id'] ?? 0) : 0;
    final sig = '${alerts["м. Київ"]}_${alerts["__red_м. Київ"]}_${alerts["Київська область"]}_${alerts["__red_Київська область"]}_${threats.length}_$firstId';
    if (sig == _lastWidgetSyncSignature) return;
    _lastWidgetSyncSignature = sig;

    _widgetSyncDebounceTimer?.cancel();
    _widgetSyncDebounceTimer = Timer(const Duration(milliseconds: 1000), () {
      final now = DateTime.now();
      if (_lastWidgetSyncTime != null && now.difference(_lastWidgetSyncTime!).inSeconds < 10) {
        final waitSec = 10 - now.difference(_lastWidgetSyncTime!).inSeconds;
        _widgetSyncDebounceTimer = Timer(Duration(seconds: waitSec), () {
          _syncAndroidWidgetAndLockScreen(alerts, threats, messages);
        });
        return;
      }
      _syncAndroidWidgetAndLockScreen(alerts, threats, messages);
    });
  }

  Future<void> _syncAndroidWidgetAndLockScreen(
    Map<String, bool> alerts,
    List<Map<String, dynamic>> threats,
    List<dynamic> messages,
  ) async {
    if (kIsWeb || !Platform.isAndroid) return;

    final bool kyivCityAlert = alerts['м. Київ'] == true;
    final bool kyivOblastAlert = alerts['Київська область'] == true;
    final bool anyAlert = kyivCityAlert || kyivOblastAlert;
    final bool isOfficialRedAlert = (kyivCityAlert && alerts['__red_м. Київ'] == true) ||
        (kyivOblastAlert && alerts['__red_Київська область'] == true);

    String statusTitle = "БЕЗПЕЧНО";
    if (isOfficialRedAlert) {
      statusTitle = "РАКЕТНА ТРИВОГА";
    } else if (anyAlert) {
      statusTitle = "ТРИВОГА (БПЛА)";
    }

    String nearestInfo = "Немає загроз поблизу";
    if (threats.isNotEmpty) {
      const distance = Distance();
      double minDistanceMeters = double.infinity;
      Map<String, dynamic>? closestThreat;
      String locName = "Київ";

      final watchedLocations = ref.read(watchedLocationsProvider).where((l) => l.enabled).toList();
      final evalLocations = watchedLocations.isNotEmpty
          ? watchedLocations
          : [
              WatchedLocation(
                id: 'default_kyiv',
                name: 'Київ',
                address: 'м. Київ',
                point: const LatLng(50.4501, 30.5234),
                radiusMeters: 15000,
                enabled: true,
              )
            ];

      for (final loc in evalLocations) {
        for (final t in threats) {
          final path = (t['path'] as List<dynamic>?)?.cast<LatLng>() ?? [];
          if (path.isEmpty) continue;
          final curPt = path.last;
          final d = distance.as(LengthUnit.Meter, loc.point, curPt);
          if (d < minDistanceMeters) {
            minDistanceMeters = d;
            closestThreat = t;
            locName = loc.name;
          }
        }
      }

      if (closestThreat != null) {
        final distKm = (minDistanceMeters / 1000.0).toStringAsFixed(1);
        final rawType = closestThreat['type']?.toString() ?? 'shahed';
        final threatName = _formatThreatType(rawType);
        final route = closestThreat['route'] ?? closestThreat['direction'];
        final speedKmh = (closestThreat['speed'] as num?)?.toDouble() ?? 185.0;
        final speedMs = speedKmh * (1000.0 / 3600.0);
        final etaMin = (minDistanceMeters / speedMs / 60.0).round();

        final buffer = StringBuffer('$locName: $distKm км • $threatName');
        if (route != null && route.toString().trim().isNotEmpty) {
          buffer.write(' → $route');
        }
        if (etaMin > 0 && etaMin <= 120) {
          buffer.write(' ($etaMin хв)');
        }
        nearestInfo = buffer.toString();
      }
    } else if (anyAlert) {
      nearestInfo = "Укриття: загроза в повітряному просторі";
    }

    String lastMsgText = "";
    if (messages.isNotEmpty) {
      final rawText = (messages.first['text'] ?? '').toString().replaceAll('\n', ' ').trim();
      lastMsgText = rawText.length > 100 ? '${rawText.substring(0, 100)}...' : rawText;
    }

    final now = DateTime.now();
    final updatedTime = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    final bool isAlert = anyAlert;

    final threatsList = threats.map((t) {
      final rawPath = t['path'];
      List<Map<String, double>> pathList = [];
      if (rawPath is List) {
        for (final p in rawPath) {
          if (p is LatLng) {
            pathList.add({'lat': p.latitude, 'lon': p.longitude});
          } else if (p is Map && p['lat'] != null && p['lon'] != null) {
            pathList.add({'lat': (p['lat'] as num).toDouble(), 'lon': (p['lon'] as num).toDouble()});
          }
        }
      }
      return {
        'type': t['type']?.toString() ?? 'shahed',
        'label': t['label']?.toString() ?? t['typeName']?.toString() ?? _formatThreatType(t['type']?.toString() ?? 'shahed'),
        'speed': (t['speed'] as num?)?.toDouble() ?? 185.0,
        'isDescending': t['isDescending'] == true,
        'altitude': (t['altitudeMeters'] as num?)?.toDouble() ?? 0.0,
        'route': t['route']?.toString() ?? t['direction']?.toString() ?? '',
        'path': pathList,
      };
    }).toList();

    final watchedLocationsList = ref.read(watchedLocationsProvider).map((loc) => {
      'id': loc.id,
      'name': loc.name,
      'lat': loc.point.latitude,
      'lon': loc.point.longitude,
      'radiusMeters': loc.radiusMeters,
      'enabled': loc.enabled,
    }).toList();

    try {
      _lastWidgetSyncTime = DateTime.now();
      const channel = MethodChannel('ua.kyiv.alert.monitor/widget');
      await channel.invokeMethod('updateWidget', {
        'statusTitle': statusTitle,
        'activeCount': threats.length,
        'nearestInfo': nearestInfo,
        'lastMsgText': lastMsgText,
        'updatedTime': updatedTime,
        'isAlert': isAlert,
        'radarPng': null,
        'threats': threatsList,
        'watchedLocations': watchedLocationsList,
      });
    } catch (e) {
      debugPrint('Error updating widget: $e');
    }
  }

  void _showMorningDigestSheet(BuildContext context) {
    showMorningDigestSheet(
      context,
      messages: ref.read(messagesProvider),
      watchedLocations: ref.read(watchedLocationsProvider),
      isNightWatchMode: _isNightWatchMode,
    );
  }

  void _showWatchedLocationsSheet(BuildContext context) {
    showWatchedLocationsSheet(
      context: context,
      ref: ref,
      mapController: _mapController,
      watchedLocationsProvider: watchedLocationsProvider,
    );
  }

  void _showAddPointFromMapDialog(BuildContext context, LatLng point) {
    showAddPointFromMapDialog(
      context: context,
      point: point,
      ref: ref,
      watchedLocationsProvider: watchedLocationsProvider,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;

    final isTestMode = ref.watch(testModeProvider);
    final watchedLocations = ref.watch(watchedLocationsProvider);
    var messages = ref.watch(messagesProvider);
    final geoJsonAsync = ref.watch(geoJsonProvider);
    var alerts = ref.watch(alertsProvider); 
    final ukraineAlarmTargets = ref.watch(ukraineAlarmTargetsProvider);
    final remoteConfig = ref.watch(remoteConfigProvider);
    final bool hasUpdate = remoteConfig.versionCode > kCurrentVersionCode && remoteConfig.apkUrl.isNotEmpty; 

    if (isTestMode) {
      final testCount = ref.watch(testMessageIndexProvider);
      final bool isTestRed = testCount >= 5 && testCount <= 7;
      final bool isTestClear = testCount >= 11;
      alerts = {
        'м. Київ': !isTestClear,
        '__red_м. Київ': isTestRed,
        'Київська область': !isTestClear,
        '__red_Київська область': isTestRed,
      };
      
      final allTestMessages = [
          {
            'id': 1011,
            'type': 'clear',
            'channel': 'war_monitor',
            'text': 'Відбій ракетної небезпеки по всій області!',
            'date': _staticTestModeTime,
            'threats': []
          },
          {
            'id': 1010,
            'type': 'clear',
            'channel': 'war_monitor',
            'text': 'Київ відбій по шахедам, чисто!',
            'date': _staticTestModeTime,
            'threats': []
          },
          {
            'id': 1009,
            'type': 'danger',
            'channel': 'war_monitor',
            'text': 'Шахеди в межах Києва, працює ППО! Залишився один над Оболонню',
            'date': _staticTestModeTime,
            'threats': []
          },
          {
            'id': 1008,
            'type': 'clear',
            'channel': 'war_monitor',
            'text': 'Київ дорозвідка по балістиці. Ракети чисто.',
            'date': _staticTestModeTime,
            'threats': []
          },
          {
            'id': 1007,
            'type': 'danger',
            'channel': 'war_monitor',
            'text': 'Кинджали на Київ!',
            'date': _staticTestModeTime,
            'threats': []
          },
          {
            'id': 1006,
            'type': 'danger',
            'channel': 'war_monitor',
            'text': 'УВАГА! Загроза балістики з Криму на Київ! Іскандер-М',
            'date': _staticTestModeTime,
            'threats': []
          },
          {
            'id': 1005,
            'type': 'danger',
            'channel': 'war_monitor',
            'text': 'Крилаті ракети через Чернігівщину курсом на Київ! Вже біля Славутича!',
            'date': _staticTestModeTime,
            'threats': []
          },
          {
            'id': 1004,
            'type': 'info',
            'channel': 'war_monitor',
            'text': 'Пуски крилатих ракет Х-101 з Ту-95мс!',
            'date': _staticTestModeTime,
            'threats': []
          },
          {
            'id': 1003,
            'type': 'danger',
            'channel': 'war_monitor',
            'text': 'Шахеди на Фастів та Обухів!',
            'date': _staticTestModeTime,
            'threats': []
          },
          {
            'id': 1002,
            'type': 'danger',
            'channel': 'war_monitor',
            'text': 'Зафіксовано запуск 10х шахедів з півдня, вектор на Білу Церкву',
            'date': _staticTestModeTime,
            'threats': []
          },
          {
            'id': 1001,
            'type': 'info',
            'channel': 'war_monitor',
            'text': 'УВАГА! Зліт 4х бортів ТУ-95мс з аеродрому Оленья.',
            'date': _staticTestModeTime,
            'threats': []
          }
      ];
      messages = allTestMessages.sublist(allTestMessages.length - testCount);
    } else {
      final nowUtc = _isReplayMode
          ? DateTime.now().toUtc().add(Duration(seconds: (_replayOffsetMinutes * 60).round()))
          : DateTime.now().toUtc();
      messages = ThreatParser.filterOperationalMessages(messages, nowUtc: nowUtc);
    }

    final isLoadingInitial = ref.read(messagesProvider.notifier).isLoading && !isTestMode;
    final bool headerKyivAlert = alerts['м. Київ'] == true;
    final bool headerKyivRed = headerKyivAlert && alerts['__red_м. Київ'] == true;
    final bool headerOblastAlert = alerts['Київська область'] == true;
    final bool headerOblastRed = headerOblastAlert && alerts['__red_Київська область'] == true;
    final bool headerAnyAlert = headerKyivAlert || headerOblastAlert;
    final bool headerAnyRed = headerKyivRed || headerOblastRed;
    final Color headerAlertAccent = headerAnyRed
        ? Colors.redAccent
        : (headerAnyAlert ? const Color(0xFFFFC107) : Colors.cyanAccent);
    final Color headerKyivColor = !headerKyivAlert
        ? Colors.greenAccent
        : (headerKyivRed ? Colors.redAccent : const Color(0xFFFFC107));
    final Color headerOblastColor = !headerOblastAlert
        ? Colors.greenAccent
        : (headerOblastRed ? Colors.redAccent : const Color(0xFFFFC107));
    final bool isDesktopHeader = MediaQuery.of(context).size.width > 800;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 58,
        titleSpacing: 14,
        title: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: headerAlertAccent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: headerAlertAccent.withValues(alpha: 0.55),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: headerAlertAccent.withValues(alpha: 0.25),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: Icon(
                Icons.radar_rounded,
                size: 20,
                color: headerAlertAccent,
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'KYIV ALERT 🇺🇦',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 16.5,
                letterSpacing: 0.6,
                color: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2234),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF2B3752), width: 0.8),
              ),
              child: Text(
                'v$kCurrentVersionName',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white60,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            if (isDesktopHeader) ...[
              const SizedBox(width: 18),
              Container(width: 1, height: 22, color: const Color(0xFF253047)),
              const SizedBox(width: 14),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
                decoration: BoxDecoration(
                  color: headerKyivColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: headerKyivColor.withValues(alpha: 0.45),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      headerKyivAlert ? Icons.warning_amber_rounded : Icons.verified_user_outlined,
                      size: 14,
                      color: headerKyivColor,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      !headerKyivAlert
                          ? 'м. Київ: Чисто'
                          : (headerKyivRed ? 'м. Київ: РАКЕТНА ТРИВОГА' : 'м. Київ: ТРИВОГА (БпЛА)'),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: !headerKyivAlert
                            ? Colors.greenAccent.shade100
                            : (headerKyivRed ? Colors.redAccent.shade100 : const Color(0xFFFFE082)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4.5),
                decoration: BoxDecoration(
                  color: headerOblastColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: headerOblastColor.withValues(alpha: 0.45),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      headerOblastAlert ? Icons.warning_amber_rounded : Icons.shield_outlined,
                      size: 14,
                      color: headerOblastColor,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      !headerOblastAlert
                          ? 'Київщина: Чисто'
                          : (headerOblastRed ? 'Київщина: РАКЕТНА ТРИВОГА' : 'Київщина: ТРИВОГА (БпЛА)'),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: !headerOblastAlert
                            ? Colors.greenAccent.shade100
                            : (headerOblastRed ? Colors.redAccent.shade100 : const Color(0xFFFFE082)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.coffee_outlined, color: Colors.amberAccent, size: 21),
            tooltip: 'Зведення (Ранковий брифінг)',
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF182032),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: const BorderSide(color: Color(0xFF28334A), width: 0.8),
              ),
            ),
            onPressed: () {
              _closeSettingsMenu();
              _showMorningDigestSheet(context);
            },
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: Icon(_isNightWatchMode ? Icons.bedtime : Icons.bedtime_outlined, size: 21),
            color: _isNightWatchMode ? Colors.amberAccent : Colors.white70,
            tooltip: _isNightWatchMode ? "Режим 'Нічний вартовий' (УВІМКНЕНО, +3.5 км до зон)" : "Режим 'Нічний вартовий' (Вимкнено)",
            style: IconButton.styleFrom(
              backgroundColor: _isNightWatchMode ? const Color(0xFF2A1B4E) : const Color(0xFF182032),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: _isNightWatchMode ? Colors.amberAccent.withValues(alpha: 0.6) : const Color(0xFF28334A),
                  width: 0.8,
                ),
              ),
            ),
            onPressed: () {
              setState(() {
                _isNightWatchMode = !_isNightWatchMode;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    _isNightWatchMode
                        ? '🌙 Режим "Нічний вартовий" увімкнено! Радіус зон розширено на +3.5 км, увімкнено готовність до гучних сигналів тривоги.'
                        : '☀️ Режим "Нічний вартовий" вимкнено.',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  duration: const Duration(seconds: 3),
                  backgroundColor: _isNightWatchMode ? const Color(0xFF2A164D) : const Color(0xFF2C2C34),
                ),
              );
            },
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: AnimatedRotation(
              turns: _isSettingsMenuOpen ? 0.25 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                _isSettingsMenuOpen ? Icons.close_rounded : Icons.tune_rounded,
                size: 21,
                color: _isSettingsMenuOpen ? Colors.cyanAccent : Colors.white70,
              ),
            ),
            style: IconButton.styleFrom(
              backgroundColor: _isSettingsMenuOpen ? const Color(0xFF122C38) : const Color(0xFF182032),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: _isSettingsMenuOpen ? Colors.cyanAccent.withValues(alpha: 0.6) : const Color(0xFF28334A),
                  width: 0.8,
                ),
              ),
            ),
            tooltip: 'Налаштування та інструменти',
            onPressed: _toggleSettingsMenu,
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: isLoadingInitial 
        ? const Center(child: CircularProgressIndicator(color: Colors.redAccent))
        : Stack(
            children: [
              Column(
                children: [
                  if (hasUpdate) _buildUpdateBanner(remoteConfig),
              Expanded(
                child: LayoutBuilder(
            builder: (context, constraints) {
              final bool isWide = constraints.maxWidth > 800;
              final mapWidget = Expanded(
                  flex: isWide ? 7 : 12,
                  child: Container(
                    margin: EdgeInsets.fromLTRB(12.0, 12.0, isWide ? 6.0 : 12.0, 12.0),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: headerAnyRed
                            ? Colors.redAccent.withValues(alpha: 0.48)
                            : (headerAnyAlert
                                ? const Color(0xFFFFC107).withValues(alpha: 0.42)
                                : const Color(0xFF222C40)),
                        width: 1.2,
                      ),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 14, offset: Offset(0, 6))
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(15),
                      child: Builder(
                        builder: (context) {
                          final bool kyivCityAlert = alerts['м. Київ'] == true;
                          final bool kyivOblastAlert = alerts['Київська область'] == true;
                          final bool anyAlert = kyivCityAlert || kyivOblastAlert;
                          final now = _isReplayMode
                              ? DateTime.now().toUtc().add(Duration(seconds: (_replayOffsetMinutes * 60).round()))
                              : DateTime.now().toUtc();

                          final topMsgsSig = messages.take(12).map((m) {
                            final mergedLen = (m['merged_msg_ids'] as List?)?.length ?? 0;
                            final txtLen = (m['text'] ?? '').toString().length;
                            return '${m['id']}:${m['date']}:$txtLen:$mergedLen';
                          }).join('|');
                          final uaSig = ukraineAlarmTargets.map((u) {
                            final pt = u['point'] as LatLng?;
                            final disp = u['disappearedAt'] != null ? 'L' : 'A';
                            return '${u['trackId']}:$disp:${pt?.latitude.toStringAsFixed(3)}:${pt?.longitude.toStringAsFixed(3)}:${u['heading']}';
                          }).join('|');
                          final trajectorySig = '${topMsgsSig}_${messages.length}_${uaSig}_${alerts['м. Київ']}_${alerts['__red_м. Київ']}_${alerts['Київська область']}_${alerts['__red_Київська область']}_${_isReplayMode}_${_replayOffsetMinutes.toStringAsFixed(1)}_${now.millisecondsSinceEpoch ~/ 2500}';

                          List<Map<String, dynamic>> activeAirDefenses = [];
                          String? northThreatLabel;
                          String? southThreatLabel;
                          List<Map<String, dynamic>> threats = [];
                          List<Map<String, dynamic>> lostTracks = [];
                          bool hasMissiles = false;

                          if (_cachedTrajectorySignature == trajectorySig) {
                            activeAirDefenses = _cachedActiveAirDefenses.map((a) => Map<String, dynamic>.from(a)).toList();
                            northThreatLabel = _cachedNorthThreatLabel;
                            southThreatLabel = _cachedSouthThreatLabel;
                            threats = _cachedThreats.map((t) => Map<String, dynamic>.from(t)).toList();
                            lostTracks = _cachedLostTracks.map((l) => Map<String, dynamic>.from(l)).toList();
                            hasMissiles = _cachedHasMissiles;
                            if (_selectedThreatMsgId != null) {
                              final hasSelected = threats.any((t) => t['isDestroyed'] != true && (t['msgId'] == _selectedThreatMsgId || (t['historyMsgIds'] as Set?)?.contains(_selectedThreatMsgId) == true));
                              if (!hasSelected) {
                                _selectedThreatMsgId = null;
                              }
                            }
                          } else {
                            final Set<String> addedAirDefLocs = {};
                            bool sectorThreatCancelled = false;

                          for (var msg in messages.take(40)) {
                            if (msg['date'] == null) continue;
                            DateTime mTime = now;
                            try {
                              mTime = DateTime.parse(msg['date']).toUtc();
                              if (_isReplayMode && mTime.isAfter(now)) continue;
                              if (!_isReplayMode && mTime.isAfter(now)) mTime = now;
                            } catch (_) {
                              continue;
                            }
                            final diffSec = now.difference(mTime).inMilliseconds / 1000.0;
                            final txt = (msg['text'] ?? '').toString();
                            final txtLower = txt.toLowerCase();

                            final bool isSectorClear = msg['type'] == 'clear' ||
                                txtLower.contains('відбій') ||
                                txtLower.contains('чисто') ||
                                txtLower.contains('без фіксаці') ||
                                txtLower.contains('чисте небо') ||
                                txtLower.contains('тихо') ||
                                txtLower.contains('знят') ||
                                txtLower.contains('не спостерігається') ||
                                txtLower.contains('немає');

                            if (isSectorClear) {
                              sectorThreatCancelled = true;
                            }

                            // Індикатор роботи ППО (активний 90 секунд)
                            if (diffSec >= 0 && diffSec <= 90.0) {
                              final bool isAdActive = txtLower.contains('працює ппо') ||
                                  txtLower.contains('робота ппо') ||
                                  txtLower.contains('роботі ппо') ||
                                  txtLower.contains('вибух') ||
                                  txtLower.contains('гучно');

                              if (isAdActive) {
                                double? adLat;
                                double? adLon;
                                String? adLocName;

                                if (msg['threats'] is List && (msg['threats'] as List).isNotEmpty) {
                                  for (var th in msg['threats']) {
                                    if (th['path'] is List && (th['path'] as List).isNotEmpty) {
                                      final pItem = (th['path'] as List).last;
                                      if (pItem is LatLng) {
                                        adLat = pItem.latitude;
                                        adLon = pItem.longitude;
                                        adLocName = 'Київський сектор';
                                        break;
                                      } else if (pItem is Map && pItem['lat'] != null && pItem['lon'] != null) {
                                        adLat = (pItem['lat'] as num).toDouble();
                                        adLon = (pItem['lon'] as num).toDouble();
                                        adLocName = pItem['name']?.toString() ?? 'Київський сектор';
                                        break;
                                      }
                                    }
                                  }
                                }

                                if (adLat == null || adLon == null) {
                                  final searchLine = ' $txtLower '.replaceAll(RegExp(r'київщин\w*|київськ\w*'), '        ');
                                  _kKyivLocations.forEach((key, data) {
                                    if (adLat != null) return;
                                    int idx = searchLine.indexOf(key);
                                    if (idx != -1) {
                                      final isWordStart = (idx == 0 || !RegExp(r'[а-яіїєґa-z0-9]').hasMatch(searchLine[idx - 1]));
                                      if (isWordStart) {
                                        adLat = data.$1;
                                        adLon = data.$2;
                                        adLocName = data.$3;
                                      }
                                    }
                                  });
                                }

                                if (adLat != null && adLon != null && adLocName != null) {
                                  final locKey = '${adLat!.toStringAsFixed(2)}_${adLon!.toStringAsFixed(2)}';
                                  if (!addedAirDefLocs.contains(locKey)) {
                                    addedAirDefLocs.add(locKey);
                                    activeAirDefenses.add({
                                      'lat': adLat,
                                      'lon': adLon,
                                      'name': adLocName,
                                      'time': mTime,
                                      'text': txt,
                                    });
                                  }
                                }
                              }
                            }

                            // Індикатор сектору загрози на краю мапи (до 20 хв)
                            // Відображається ТІЛЬКИ коли активна тривога (anyAlert == true) і після загрози не було відбою
                            if (anyAlert && !sectorThreatCancelled && now.difference(mTime).inMinutes <= 20) {
                              final bool hasBallisticExplicit = txtLower.contains('баліст') ||
                                  txtLower.contains('іскандер') ||
                                  txtLower.contains('с-300') ||
                                  txtLower.contains('с-400') ||
                                  txtLower.contains('кинджал') ||
                                  txtLower.contains('циркон') ||
                                  txtLower.contains('ракет') ||
                                  txtLower.contains('швидкісн');

                              final bool hasUavExplicit = txtLower.contains('шахед') ||
                                  txtLower.contains('бпла') ||
                                  txtLower.contains('реактив') ||
                                  txtLower.contains('реактів') ||
                                  txtLower.contains('мопед') ||
                                  txtLower.contains('залітати');

                              if (hasBallisticExplicit) {
                                if (northThreatLabel == null) {
                                  if (txtLower.contains('брянськ')) {
                                    northThreatLabel = '⬆️ ЗАГРОЗА БАЛІСТИКИ З ПІВНОЧІ (Брянськ)';
                                  } else if (txtLower.contains('курськ')) {
                                    northThreatLabel = '↗️ ЗАГРОЗА БАЛІСТИКИ З ПІВНІЧНОГО СХОДУ (Курськ)';
                                  } else if (txtLower.contains('воронеж')) {
                                    northThreatLabel = '↗️ ЗАГРОЗА БАЛІСТИКИ ЗІ СХОДУ (Воронеж)';
                                  }
                                }
                                if (southThreatLabel == null) {
                                  if (txtLower.contains('чауд')) {
                                    southThreatLabel = '⬇️ ЗАГРОЗА БАЛІСТИКИ З ПІВДНЯ (Чауда, Крим)';
                                  } else if (txtLower.contains('крим')) {
                                    southThreatLabel = '⬇️ ЗАГРОЗА БАЛІСТИКИ З ПІВДНЯ (Крим)';
                                  }
                                }
                              } else if (hasUavExplicit) {
                                if (northThreatLabel == null) {
                                  if (txtLower.contains('брянськ')) {
                                    northThreatLabel = '⬆️ ОЧІКУЄТЬСЯ ЗАХІД БПЛА З ПІВНОЧІ (Брянськ)';
                                  } else if (txtLower.contains('курськ')) {
                                    northThreatLabel = '↗️ ОЧІКУЄТЬСЯ ЗАХІД БПЛА З ПІВНІЧНОГО СХОДУ (Курськ)';
                                  } else if (txtLower.contains('воронеж')) {
                                    northThreatLabel = '↗️ ОЧІКУЄТЬСЯ ЗАХІД БПЛА ЗІ СХОДУ (Воронеж)';
                                  }
                                }
                                if (southThreatLabel == null) {
                                  if (txtLower.contains('чауд') || txtLower.contains('крим')) {
                                    southThreatLabel = '⬇️ ОЧІКУЄТЬСЯ ЗАХІД БПЛА З ПІВДНЯ (Крим)';
                                  }
                                }
                              }
                            }
                          }

                          if (!anyAlert || sectorThreatCancelled) {
                            northThreatLabel = null;
                            southThreatLabel = null;
                          }

                          threats = [];
                          final List<({LatLng point, DateTime time, String? channel})> recentlyClearedLocations = [];
                          final List<({LatLng? point, DateTime time})> explicitDestroyedEvents = [];
                          DateTime? lastKyivCityClearTime;
                          DateTime? lastFullOblastClearTime;

                          final bool hasRecentDangerMsg = messages.take(25).any((m) {
                            if (m['type'] != 'danger' || m['date'] == null) return false;
                            final dt = DateTime.tryParse(m['date'].toString())?.toUtc();
                            return dt != null && now.difference(dt).inMinutes.abs() <= 20;
                          });
                          if ((anyAlert || hasRecentDangerMsg || ukraineAlarmTargets.isNotEmpty) && messages.isNotEmpty) {
                            final recentMsgs = messages.take(120).where((msg) {
                              if (msg['date'] == null) return true;
                              try {
                                final msgTime = DateTime.parse(msg['date']).toUtc();
                                if (_isReplayMode && msgTime.isAfter(now)) return false;
                                return now.difference(msgTime).inMinutes <= 25;
                              } catch (_) {
                                return true;
                              }
                            }).toList().reversed.toList();

                            bool activeBallisticOrMissileContext = false;
                            DateTime? missileContextTime;
                            bool activeJetDroneContext = false;
                            DateTime? jetContextTime;
                            String? normPost(dynamic p) {
                              if (p == null) return null;
                              final s = p.toString().toLowerCase().split('?').first.trim();
                              return s.isEmpty ? null : s;
                            }

                            for (var msg in recentMsgs) {
                              DateTime msgTime = now;
                              if (msg['date'] != null) {
                                try {
                                  msgTime = DateTime.parse(msg['date']).toUtc();
                                  if (!_isReplayMode && msgTime.isAfter(now)) {
                                    msgTime = now;
                                  }
                                } catch (_) {}
                              }

                              final rawMsgText = (msg['text'] ?? '')
                                  .toString()
                                  .replaceAll(RegExp(r'[\u02BC\u2019\u2018\u02B9\u00B4]'), "'");
                              final msgTextLower = rawMsgText.toLowerCase();

                              final bool hasExplicitDroneInMsg = msgTextLower.contains('шахед') ||
                                  msgTextLower.contains('бпла') ||
                                  msgTextLower.contains('мопед') ||
                                  msgTextLower.contains('дрон') ||
                                  msgTextLower.contains('звичайний') ||
                                  msgTextLower.contains('двз') ||
                                  msgTextLower.contains('кружляє') ||
                                  msgTextLower.contains('геран');

                              final bool hasPistonDroneInMsg = msgTextLower.contains('звичайний') ||
                                  msgTextLower.contains('звичайні') ||
                                  msgTextLower.contains('звч') ||
                                  msgTextLower.contains('не реактив') ||
                                  msgTextLower.contains('двз') ||
                                  msgTextLower.contains('мопед') ||
                                  msgTextLower.contains('повільн') ||
                                  msgTextLower.contains('розвідник');

                              final int? msgAlt = ref.read(messagesProvider.notifier).extractAltitude(rawMsgText);
                              final bool msgHasHighAlt = msgAlt != null && msgAlt >= 2000;

                              final bool isJetTrigger = !hasPistonDroneInMsg && (
                                  msgTextLower.contains('реактив') ||
                                  msgTextLower.contains('реактів') ||
                                  msgTextLower.contains('реакти') ||
                                  msgTextLower.contains('реакт ') ||
                                  msgTextLower.contains('швидкісн') ||
                                  msgTextLower.contains('бандерол') ||
                                  msgTextLower.contains('герань-3') ||
                                  msgTextLower.contains('герань 3') ||
                                  msgTextLower.contains('турбо') ||
                                  msgHasHighAlt
                              );

                              if (isJetTrigger) {
                                activeJetDroneContext = true;
                                jetContextTime = msgTime;
                              }

                              if (jetContextTime != null && msgTime.difference(jetContextTime).inMinutes.abs() > 20) {
                                activeJetDroneContext = false;
                              }

                              // а) коротке повідомлення капсом РІВНО з одного або двох слів капсом без назв населених пунктів:
                              final trimmedText = rawMsgText.trim();
                              final bool isShortCaps = RegExp(r'^(?:УВАГА|ЦІЛЬ|ПУСК|ВИХОДИ|ШВИДКІСНА|БАЛІСТИКА|СХОВАЛИСЬ|В УКРИТТЯ|УКРИТТЯ)[!\s⚠️]*$', caseSensitive: false).hasMatch(trimmedText);

                              // б) повідомлення зі словами "баліст", "іскандер", "кинджал", "циркон", "с-300", "с-400", "х-101", "х-22", "х-32", "х-59", "х-69", "калібр", "онікс", "ракет", "швидкісна", "швидкісні", "виходи", "багато цілей", "цілей йде", "цілі йдуть", "сховались", "в укриття", "брянськ"
                              final bool isExplicitBallisticWord = msgTextLower.contains('баліст') ||
                                  msgTextLower.contains('іскандер') ||
                                  msgTextLower.contains('кинджал') ||
                                  msgTextLower.contains('циркон') ||
                                  msgTextLower.contains('с-300') ||
                                  msgTextLower.contains('с-400') ||
                                  msgTextLower.contains('х-101') ||
                                  msgTextLower.contains('х-22') ||
                                  msgTextLower.contains('х-32') ||
                                  msgTextLower.contains('х-59') ||
                                  msgTextLower.contains('х-69') ||
                                  msgTextLower.contains('калібр') ||
                                  msgTextLower.contains('онікс') ||
                                  (msgTextLower.contains('ракет') && !msgTextLower.contains('реактив')) ||
                                  msgTextLower.contains('швидкісна') ||
                                  msgTextLower.contains('швидкісні') ||
                                  msgTextLower.contains('виходи') ||
                                  msgTextLower.contains('багато цілей') ||
                                  msgTextLower.contains('цілей йде') ||
                                  msgTextLower.contains('цілі йдуть') ||
                                  msgTextLower.contains('сховались') ||
                                  msgTextLower.contains('в укриття') ||
                                  (msgTextLower.contains('брянськ') && msgTextLower.contains('баліст')) ||
                                  (msgTextLower.contains('курськ') && msgTextLower.contains('баліст'));

                              // в) наявність 4 знаків оклику поспіль '!!!!'
                              final bool hasFourExclamations = rawMsgText.contains('!!!!');

                              final bool isMissileTrigger = (isShortCaps || isExplicitBallisticWord || hasFourExclamations) && !hasExplicitDroneInMsg;

                              if (isMissileTrigger) {
                                activeBallisticOrMissileContext = true;
                                missileContextTime = msgTime;
                              }

                              if (missileContextTime != null && msgTime.difference(missileContextTime).inMinutes.abs() > 6) {
                                activeBallisticOrMissileContext = false;
                              }

                              bool hasDangerAlso = msgTextLower.contains('загроз') ||
                                  msgTextLower.contains('баліст') ||
                                  msgTextLower.contains('ракет') ||
                                  msgTextLower.contains('пуск') ||
                                  _dynamicDangerKeywords.any((k) => msgTextLower.contains(k));

                              final bool isNegatedClear = msgTextLower.contains('не мінус') ||
                                  msgTextLower.contains('не зник') ||
                                  msgTextLower.contains('не збито') ||
                                  msgTextLower.contains('не впав');

                              // Якщо повідомлено про збиття конкретної цілі ("немає його, збиття, холодні ноги, впав, сконав") —
                              // помічаємо як збиту/втрачену на 35 секунд
                              final bool isDestroyedMsg = !isNegatedClear && (
                                  msgTextLower.contains('немає його') ||
                                  msgTextLower.contains('нема його') ||
                                  msgTextLower.contains('збиття') ||
                                  msgTextLower.contains('збито') ||
                                  msgTextLower.contains('попередньо збили') ||
                                  msgTextLower.contains('мінус') ||
                                  msgTextLower.contains('-1') ||
                                  msgTextLower.contains('холодні ноги') ||
                                  msgTextLower.contains('👣') ||
                                  msgTextLower.contains('здох') ||
                                  msgTextLower.contains('сконав') ||
                                  msgTextLower.contains('впав') ||
                                  msgTextLower.contains('в\'єбало') ||
                                  msgTextLower.contains('вєбало') ||
                                  msgTextLower.contains('все він') ||
                                  msgTextLower.contains('він все') ||
                                  msgTextLower.contains('все походу') ||
                                  msgTextLower.contains('все наче') ||
                                  msgTextLower.contains('наче все') ||
                                  msgTextLower.contains('ніби все') ||
                                  msgTextLower.contains('ушов назад') ||
                                  msgTextLower.contains('втрачено над') ||
                                  msgTextLower.contains('посадили') ||
                                  msgTextLower.contains('приземлили') ||
                                  msgTextLower.contains('ліквідовано') ||
                                  msgTextLower.contains('знищено'));

                              if (isDestroyedMsg) {
                                LatLng? explicitDestroyLoc;
                                for (final entry in _kKyivLocations.entries) {
                                  if (entry.key.length >= 4 &&
                                      !_kExternalBorderKeys.contains(entry.key) &&
                                      entry.key != 'київ' &&
                                      entry.key != 'київщин' &&
                                      msgTextLower.contains(entry.key)) {
                                    explicitDestroyLoc = LatLng(entry.value.$1, entry.value.$2);
                                    break;
                                  }
                                }
                                explicitDestroyedEvents.add((point: explicitDestroyLoc, time: msgTime));
                                if (explicitDestroyLoc != null) {
                                  recentlyClearedLocations.add((point: explicitDestroyLoc, time: msgTime, channel: msg['channel']?.toString()));
                                }
                                if (threats.isNotEmpty) {
                                  final msgChannel = msg['channel']?.toString();
                                  final replyToPostId = normPost(msg['reply_to_post_id'] ?? msg['replyToPostId']);
                                  final replyToId = msg['reply_to_msg_id'] ?? msg['replyToId'];
                                  final replyQuoted = (msg['reply_quoted_text'] ?? msg['replyQuotedText'])?.toString().toLowerCase().trim();
                                  final mergedMsgIds = (msg['merged_msg_ids'] as List?)?.cast<dynamic>() ?? [];
                                  final mergedPostIds = (msg['merged_post_ids'] as List?)?.map((p) => normPost(p)).whereType<String>().toList() ?? [];

                                  int targetIdx = -1;

                                  // 1. Reply matching by post_id or msg_id
                                  if (replyToPostId != null || replyToId != null) {
                                    for (int ti = threats.length - 1; ti >= 0; ti--) {
                                      final candidate = threats[ti];
                                      if (candidate['isDestroyed'] == true) continue;
                                      final lastPostId = normPost(candidate['lastPostId']);
                                      final histPosts = candidate['historyPostIds'] as Set<dynamic>?;
                                      final normHistPosts = histPosts?.map((p) => normPost(p)).whereType<String>().toSet();
                                      final history = candidate['historyMsgIds'] as Set<dynamic>?;

                                      final bool matchPost = replyToPostId != null &&
                                          (lastPostId == replyToPostId ||
                                           (normHistPosts != null && (normHistPosts.contains(replyToPostId) || mergedPostIds.any((mp) => normHistPosts.contains(mp)))));
                                      final bool matchMsgId = replyToId != null &&
                                          (candidate['msgId'] == replyToId ||
                                           (history != null && (history.contains(replyToId) || mergedMsgIds.any((mid) => history.contains(mid)))));

                                      if (matchPost || matchMsgId) {
                                        targetIdx = ti;
                                        break;
                                      }
                                    }
                                  }

                                  // 2. Reply matching by quoted text
                                  if (targetIdx == -1 && replyQuoted != null && replyQuoted.isNotEmpty) {
                                    final List<String> quotedLocKeys = [];
                                    for (final k in _kKyivLocations.keys) {
                                      if (k.length >= 3 && replyQuoted.contains(k)) {
                                        quotedLocKeys.add(k);
                                      }
                                    }
                                    for (int ti = threats.length - 1; ti >= 0; ti--) {
                                      final candidate = threats[ti];
                                      if (candidate['isDestroyed'] == true) continue;
                                      if (msgChannel != null && candidate['channel'] != null && candidate['channel'] != msgChannel) {
                                        continue;
                                      }
                                      final r = (candidate['route'] ?? '').toString().toLowerCase();
                                      final txt = (candidate['text'] ?? '').toString().toLowerCase();
                                      final rawT = (candidate['rawText'] ?? '').toString().toLowerCase();
                                      final lNames = (candidate['locNames'] as List?)?.map((e) => e.toString().toLowerCase()).toList() ?? [];
                                      bool match = quotedLocKeys.any((k) => r.contains(k) || txt.contains(k) || rawT.contains(k) || lNames.any((ln) => ln.contains(k)));
                                      if (!match && txt.isNotEmpty && (replyQuoted.contains(txt) || txt.contains(replyQuoted))) {
                                        match = true;
                                      }
                                      if (match) {
                                        targetIdx = ti;
                                        break;
                                      }
                                    }
                                    if (targetIdx == -1 && quotedLocKeys.isNotEmpty) {
                                      for (int ti = threats.length - 1; ti >= 0; ti--) {
                                        final candidate = threats[ti];
                                        if (candidate['isDestroyed'] == true) continue;
                                        final r = (candidate['route'] ?? '').toString().toLowerCase();
                                        final txt = (candidate['text'] ?? '').toString().toLowerCase();
                                        final rawT = (candidate['rawText'] ?? '').toString().toLowerCase();
                                        final lNames = (candidate['locNames'] as List?)?.map((e) => e.toString().toLowerCase()).toList() ?? [];
                                        if (quotedLocKeys.any((k) => r.contains(k) || txt.contains(k) || rawT.contains(k) || lNames.any((ln) => ln.contains(k)))) {
                                          targetIdx = ti;
                                          break;
                                        }
                                      }
                                    }
                                  }

                                  // 3. Перевірка чи вказано порядковий номер цілі (orderTag)
                                  if (targetIdx == -1) {
                                    int? targetOrderTag;
                                    if (msgTextLower.contains('перший') || msgTextLower.contains('1-й') || msgTextLower.contains('1й')) {
                                      targetOrderTag = 1;
                                    } else if (msgTextLower.contains('другий') || msgTextLower.contains('2-й') || msgTextLower.contains('2й')) {
                                      targetOrderTag = 2;
                                    } else if (msgTextLower.contains('третій') || msgTextLower.contains('3-й') || msgTextLower.contains('3й')) {
                                      targetOrderTag = 3;
                                    }

                                    if (targetOrderTag != null) {
                                      for (int ti = threats.length - 1; ti >= 0; ti--) {
                                        if (threats[ti]['orderTag'] == targetOrderTag && threats[ti]['isDestroyed'] != true) {
                                          targetIdx = ti;
                                          break;
                                        }
                                      }
                                    }
                                  }

                                  // 4. Перевірка чи вказано конкретну локацію цілі: "Той що Брусилів мінус" або "Брусилів мінус"
                                  if (targetIdx == -1) {
                                    String? matchedLocationKey;
                                    for (final k in _kKyivLocations.keys) {
                                      if (k.length >= 4 && msgTextLower.contains(k)) {
                                        matchedLocationKey = k;
                                        break;
                                      }
                                    }

                                    if (matchedLocationKey != null) {
                                      for (int ti = threats.length - 1; ti >= 0; ti--) {
                                        final t = threats[ti];
                                        if (t['isDestroyed'] == true) continue;
                                        final r = (t['route'] ?? '').toString().toLowerCase();
                                        final lNames = (t['locNames'] as List?)?.map((e) => e.toString().toLowerCase()).toList() ?? [];
                                        if (r.contains(matchedLocationKey) || lNames.any((ln) => ln.contains(matchedLocationKey!))) {
                                          targetIdx = ti;
                                          break;
                                        }
                                      }
                                    }
                                  }

                                  // 5. Fallback: найновіша незнищена ціль
                                  if (targetIdx == -1) {
                                    for (int ti = threats.length - 1; ti >= 0; ti--) {
                                      if (threats[ti]['isDestroyed'] != true) {
                                        targetIdx = ti;
                                        break;
                                      }
                                    }
                                  }

                                  if (targetIdx != -1) {
                                    final targetToDestroy = threats[targetIdx];
                                    targetToDestroy['isDestroyed'] = true;
                                    targetToDestroy['destroyedAt'] = msgTime;
                                    final p = (targetToDestroy['path'] as List<LatLng>?) ?? [];
                                    if (p.isNotEmpty) {
                                      recentlyClearedLocations.add((point: p.last, time: msgTime, channel: msg['channel']?.toString()));
                                    }
                                    if (_selectedThreatMsgId != null && (_selectedThreatMsgId == targetToDestroy['msgId'] || (targetToDestroy['historyMsgIds'] as Set?)?.contains(_selectedThreatMsgId) == true)) {
                                      _selectedThreatMsgId = null;
                                    }
                                  }
                                }
                                if (!hasDangerAlso) continue;
                              }

                              // Якщо в хронології вийшло повідомлення про відбій / чисто / дорозвідку / втрату цілі —
                              // стираємо старі цілі відповідно до сектора (Київ чи вся область)
                              final bool isClearMsg = !isNegatedClear && (msg['type'] == 'clear' ||
                                  msgTextLower.contains('відбій') ||
                                  msgTextLower.contains('чисто') ||
                                  msgTextLower.contains('дорозвідка') ||
                                  msgTextLower.contains('локаційно') ||
                                  msgTextLower.contains('втрачено') ||
                                  msgTextLower.contains('тихо') ||
                                  msgTextLower.contains('знят') ||
                                  msgTextLower.contains('немає') ||
                                  msgTextLower.contains('нема його') ||
                                  msgTextLower.contains('не спостерігається') ||
                                  msgTextLower.contains('без фіксаці') ||
                                  msgTextLower.contains('фіксацій немає') ||
                                  msgTextLower.contains('не фіксуються') ||
                                  msgTextLower.contains('чисте небо') ||
                                  msgTextLower.contains('попередньо чисто') ||
                                  msgTextLower.contains('все походу') ||
                                  msgTextLower.contains('все наче') ||
                                  msgTextLower.contains('ніби все') ||
                                  msgTextLower.contains('ушов назад') ||
                                  msgTextLower.contains('втрачено над') ||
                                  msgTextLower.contains('та все, нема') ||
                                  msgTextLower.contains('нема вже') ||
                                  msgTextLower.contains('знив') ||
                                  msgTextLower.contains('зник') ||
                                  _dynamicClearKeywords.any((k) => msgTextLower.contains(k)));

                              if (isClearMsg) {
                                final bool isFullOblastClear = (msgTextLower.contains('відбій') && !msgTextLower.contains('по ракетах')) ||
                                    msgTextLower.contains('область чисто') ||
                                    msgTextLower.contains('чисто по області') ||
                                    msgTextLower.contains('в області чисто') ||
                                    msgTextLower.contains('по області відбій') ||
                                    msgTextLower.contains('по області чисто') ||
                                    msgTextLower.contains('ракети чисто') ||
                                    msgTextLower.contains('балістика чисто') ||
                                    msgTextLower.contains('дорозвідка по балістиці') ||
                                    msgTextLower.contains('чисте небо');
                                final bool onlyClearMissiles = (msgTextLower.contains('балістик') || msgTextLower.contains('ракет') || msgTextLower.contains('кинджал')) && !msgTextLower.contains('загроза баліст') && !msgTextLower.contains('загроза ракет');
                                
                                if (onlyClearMissiles || isFullOblastClear) {
                                  activeBallisticOrMissileContext = false;
                                  missileContextTime = null;
                                }
                                final bool onlyClearUavs = msgTextLower.contains('бпла') || msgTextLower.contains('шахед') || msgTextLower.contains('мопед') || msgTextLower.contains('дрон');
                                if (onlyClearUavs || isFullOblastClear) {
                                  activeJetDroneContext = false;
                                  jetContextTime = null;
                                }

                                final bool isKyivCityClear = msgTextLower.contains('київ') &&
                                    !msgTextLower.contains('київщин') &&
                                    !msgTextLower.contains('област');

                                if (isKyivCityClear) {
                                  if (!onlyClearMissiles) {
                                    lastKyivCityClearTime = msgTime;
                                  }
                                  // Якщо написали "Київ чисто" — прибираємо цілі лише в адміністративних межах міста Київ
                                  threats.removeWhere((t) {
                                    if (onlyClearUavs && !onlyClearMissiles && (t['type'] == 'missile_ballistic' || t['type'] == 'missile_cruise' || t['type'] == 'missile_hypersonic' || t['type'] == 'missile_supersonic' || t['type'] == 'kab')) return false;
                                    if (onlyClearMissiles && !onlyClearUavs && !t['type'].toString().contains('missile')) return false;
                                    final p = (t['path'] as List<LatLng>).last;
                                    final shouldRemove = _isPointInKyivCity(p);
                                    if (shouldRemove) {
                                      final pList = (t['waypoints'] as List<LatLng>?) ?? (t['path'] as List<LatLng>?) ?? [p];
                                      for (final pt in pList) {
                                        recentlyClearedLocations.add((point: pt, time: msgTime, channel: msg['channel']?.toString()));
                                      }
                                      if (_selectedThreatMsgId != null && (_selectedThreatMsgId == t['msgId'] || (t['historyMsgIds'] as Set?)?.contains(_selectedThreatMsgId) == true)) {
                                        _selectedThreatMsgId = null;
                                      }
                                    }
                                    return shouldRemove;
                                  });
                                } else if (isFullOblastClear) {
                                  if (!onlyClearMissiles) {
                                    lastFullOblastClearTime = msgTime;
                                  }
                                  // Повний офіційний відбій або чисто по всій області — очищуємо всі цілі області
                                  threats.removeWhere((t) {
                                    if (onlyClearUavs && !onlyClearMissiles && (t['type'] == 'missile_ballistic' || t['type'] == 'missile_cruise' || t['type'] == 'missile_hypersonic' || t['type'] == 'missile_supersonic' || t['type'] == 'kab')) return false;
                                    if (onlyClearMissiles && !onlyClearUavs && !t['type'].toString().contains('missile')) return false;
                                    final pList = (t['waypoints'] as List<LatLng>?) ?? (t['path'] as List<LatLng>?) ?? [];
                                    for (final pt in pList) {
                                      recentlyClearedLocations.add((point: pt, time: msgTime, channel: msg['channel']?.toString()));
                                    }
                                    if (_selectedThreatMsgId != null && (_selectedThreatMsgId == t['msgId'] || (t['historyMsgIds'] as Set?)?.contains(_selectedThreatMsgId) == true)) {
                                      _selectedThreatMsgId = null;
                                    }
                                    return true;
                                  });
                                } else {
                                  // Локальне повідомлення ("І зникло", "Локаційно чисто", "Втрачено", "Не фіксується", "Знив")
                                  final specificLocs = kKyivLocations.entries.where((e) =>
                                    !kExternalBorderKeys.contains(e.key) &&
                                    e.key != 'київ' && e.key != 'київщин' && e.key != 'центр' &&
                                    msgTextLower.contains(e.key)
                                  ).toList();

                                  if (specificLocs.isNotEmpty) {
                                    for (final loc in specificLocs) {
                                      recentlyClearedLocations.add((point: LatLng(loc.value.$1, loc.value.$2), time: msgTime, channel: msg['channel']?.toString()));
                                    }
                                    // Якщо вказано конкретний район/місто (наприклад "Бровари чисто") — позначаємо як збиту/втрачену в радіусі <= 14 км
                                    for (final t in threats) {
                                      if (t['isDestroyed'] == true) continue;
                                      final path = t['path'] as List<LatLng>;
                                      if (path.isEmpty) continue;
                                      final shouldClear = specificLocs.any((loc) {
                                        final locPt = LatLng(loc.value.$1, loc.value.$2);
                                        return const Distance().as(LengthUnit.Meter, locPt, path.last) <= 14000;
                                      });
                                      if (shouldClear) {
                                        t['isDestroyed'] = true;
                                        t['destroyedAt'] = msgTime;
                                        final pList = (t['waypoints'] as List<LatLng>?) ?? (t['path'] as List<LatLng>?) ?? path;
                                        for (final pt in pList) {
                                          recentlyClearedLocations.add((point: pt, time: msgTime, channel: msg['channel']?.toString()));
                                        }
                                        if (_selectedThreatMsgId != null && (_selectedThreatMsgId == t['msgId'] || (t['historyMsgIds'] as Set?)?.contains(_selectedThreatMsgId) == true)) {
                                          _selectedThreatMsgId = null;
                                        }
                                      }
                                    }
                                  } else {
                                    // Без вказання конкретного району (наприклад "Немає", "Зникло", "Локаційно чисто", "Знив") —
                                    // гасимо ціль від ТОГО САМОГО каналу (до 10 хв) або точний reply (до 20 хв), або найсвіжішу ціль (до 180с)
                                    if (threats.isNotEmpty) {
                                      int targetIdx = -1;
                                      final msgChannel = msg['channel']?.toString();
                                      final replyToPostId = normPost(msg['reply_to_post_id'] ?? msg['replyToPostId']);
                                      final replyToId = msg['reply_to_msg_id'] ?? msg['replyToId'];
                                      final mergedMsgIds = (msg['merged_msg_ids'] as List?)?.cast<dynamic>() ?? [];
                                      final mergedPostIds = (msg['merged_post_ids'] as List?)?.map((p) => normPost(p)).whereType<String>().toList() ?? [];

                                      // 1. Пріоритет: точний reply на повідомлення треку (через replyToPostId або replyToId)
                                      if (replyToPostId != null || replyToId != null) {
                                        for (int ti = threats.length - 1; ti >= 0; ti--) {
                                          final candidate = threats[ti];
                                          if (candidate['isDestroyed'] == true) continue;
                                          final lastPostId = normPost(candidate['lastPostId']);
                                          final histPosts = candidate['historyPostIds'] as Set<dynamic>?;
                                          final normHistPosts = histPosts?.map((p) => normPost(p)).whereType<String>().toSet();
                                          final history = candidate['historyMsgIds'] as Set<dynamic>?;

                                          final bool matchPost = replyToPostId != null &&
                                              (lastPostId == replyToPostId ||
                                               (normHistPosts != null && (normHistPosts.contains(replyToPostId) || mergedPostIds.any((mp) => normHistPosts.contains(mp)))));
                                          final bool matchMsgId = replyToId != null &&
                                              (candidate['msgId'] == replyToId ||
                                               (history != null && (history.contains(replyToId) || mergedMsgIds.any((mid) => history.contains(mid)))));

                                          if (matchPost || matchMsgId) {
                                            targetIdx = ti;
                                            break;
                                          }
                                        }
                                      }

                                      // 2. Якщо не знайдено за reply — шукаємо найновішу загрозу від цього ж каналу (до 10 хв)
                                      // 1.1 Reply за quoted text
                                      final replyQuoted = (msg['reply_quoted_text'] ?? msg['replyQuotedText'])?.toString().toLowerCase().trim();
                                      if (targetIdx == -1 && replyQuoted != null && replyQuoted.isNotEmpty) {
                                        final List<String> quotedLocKeys = [];
                                        for (final k in _kKyivLocations.keys) {
                                          if (k.length >= 3 && replyQuoted.contains(k)) {
                                            quotedLocKeys.add(k);
                                          }
                                        }
                                        for (int ti = threats.length - 1; ti >= 0; ti--) {
                                          final candidate = threats[ti];
                                          if (candidate['isDestroyed'] == true) continue;
                                          if (msgChannel != null && candidate['channel'] != null && candidate['channel'] != msgChannel) {
                                            continue;
                                          }
                                          final r = (candidate['route'] ?? '').toString().toLowerCase();
                                          final txt = (candidate['text'] ?? '').toString().toLowerCase();
                                          final rawT = (candidate['rawText'] ?? '').toString().toLowerCase();
                                          final lNames = (candidate['locNames'] as List?)?.map((e) => e.toString().toLowerCase()).toList() ?? [];
                                          bool match = quotedLocKeys.any((k) => r.contains(k) || txt.contains(k) || rawT.contains(k) || lNames.any((ln) => ln.contains(k)));
                                          if (!match && txt.isNotEmpty && (replyQuoted.contains(txt) || txt.contains(replyQuoted))) {
                                            match = true;
                                          }
                                          if (match) {
                                            targetIdx = ti;
                                            break;
                                          }
                                        }
                                        if (targetIdx == -1 && quotedLocKeys.isNotEmpty) {
                                          for (int ti = threats.length - 1; ti >= 0; ti--) {
                                            final candidate = threats[ti];
                                            if (candidate['isDestroyed'] == true) continue;
                                            final r = (candidate['route'] ?? '').toString().toLowerCase();
                                            final txt = (candidate['text'] ?? '').toString().toLowerCase();
                                            final rawT = (candidate['rawText'] ?? '').toString().toLowerCase();
                                            final lNames = (candidate['locNames'] as List?)?.map((e) => e.toString().toLowerCase()).toList() ?? [];
                                            if (quotedLocKeys.any((k) => r.contains(k) || txt.contains(k) || rawT.contains(k) || lNames.any((ln) => ln.contains(k)))) {
                                              targetIdx = ti;
                                              break;
                                            }
                                          }
                                        }
                                      }

                                      if (targetIdx == -1 && msgChannel != null) {
                                        for (int ti = threats.length - 1; ti >= 0; ti--) {
                                          if (threats[ti]['isDestroyed'] == true) continue;
                                          final tCh = threats[ti]['channel']?.toString();
                                          final lastUpd = threats[ti]['lastUpdated'] as DateTime?;
                                          if (tCh == msgChannel && lastUpd != null && msgTime.difference(lastUpd).inMinutes.abs() <= 10) {
                                            targetIdx = ti;
                                            break;
                                          }
                                        }
                                      }

                                      // 3. Якщо і так не знайдено — беремо найсвіжішу ціль за останні 180с
                                      if (targetIdx == -1) {
                                        for (int ti = threats.length - 1; ti >= 0; ti--) {
                                          if (threats[ti]['isDestroyed'] == true) continue;
                                          final lastUpd = threats[ti]['lastUpdated'] as DateTime?;
                                          if (lastUpd != null && msgTime.difference(lastUpd).inSeconds.abs() <= 180) {
                                            targetIdx = ti;
                                            break;
                                          }
                                        }
                                      }

                                      if (targetIdx != -1) {
                                        final cleared = threats[targetIdx];
                                        cleared['isDestroyed'] = true;
                                        cleared['destroyedAt'] = msgTime;
                                        final pList = (cleared['waypoints'] as List<LatLng>?) ?? (cleared['path'] as List<LatLng>?) ?? [];
                                        for (final pt in pList) {
                                          recentlyClearedLocations.add((point: pt, time: msgTime, channel: msg['channel']?.toString()));
                                        }
                                        if (_selectedThreatMsgId != null && (_selectedThreatMsgId == cleared['msgId'] || (cleared['historyMsgIds'] as Set?)?.contains(_selectedThreatMsgId) == true)) {
                                          _selectedThreatMsgId = null;
                                        }
                                      }
                                    }
                                  }
                                }
                                
                                if (!hasDangerAlso) continue;
                              }

                              if (msgTextLower.contains('не йде') ||
                                  msgTextLower.contains('не летить') ||
                                  msgTextLower.contains('не фіксується') ||
                                  msg['type'] == 'news') {
                                if (!hasDangerAlso) continue;
                              }

                              // msgTime вже ініціалізовано на початку циклу

                              // Довгі повідомлення (> 100 символів: попередження про ймовірні цілі майбутніх атак,
                              // зведення тощо) не виводять цілі на карту — лише відображаються у стрічці
                              if (rawMsgText.trim().length > 100) continue;

                              List<dynamic> rawThreats = (msg['threats'] as List?) ?? [];
                              if (rawThreats.isEmpty) {
                                rawThreats = ref.read(messagesProvider.notifier).parseLocalThreats(msg['text']?.toString() ?? '');
                              }

                              // Примусове переоцінювання кешованих msg['threats'] під час активного балістичного або реактивного контексту
                              final List<Map<String, dynamic>> msgThreats = [];
                              for (var item in rawThreats) {
                                if (item is Map) {
                                  final Map<String, dynamic> copy = Map<String, dynamic>.from(item);
                                  if (activeBallisticOrMissileContext && !hasExplicitDroneInMsg) {
                                    final curType = (copy['type'] ?? 'shahed').toString();
                                    if (curType == 'shahed' || curType == 'shahed_jet' || curType == 'unknown') {
                                      copy['type'] = 'missile_ballistic';
                                      copy['speed'] = 5000.0;
                                      copy['label'] = 'Балістична ціль';
                                    }
                                  } else if (activeJetDroneContext && !hasPistonDroneInMsg) {
                                    final curType = (copy['type'] ?? 'shahed').toString();
                                    final alt = copy['altitudeMeters'] as int?;
                                    if ((curType == 'shahed' || curType == 'unknown') && (alt == null || alt >= 1500)) {
                                      copy['type'] = 'shahed_jet';
                                      copy['speed'] = 550.0;
                                      copy['label'] = 'Реактивний БпЛА';
                                    }
                                  }
                                  msgThreats.add(copy);
                                }
                              }

                              if (msgThreats.isNotEmpty) {
                                for (int threatIdx = 0; threatIdx < msgThreats.length; threatIdx++) {
                                  final t = msgThreats[threatIdx];
                                  final double staggerDelay = threatIdx * 35.0;
                                  List<LatLng> path = [];
                                  List<String> locNames = [];
                                  if (t['path'] != null) {
                                    for (var loc in t['path']) {
                                      try {
                                        double lat = (loc['lat'] as num).toDouble();
                                        double lon = (loc['lon'] as num).toDouble();
                                        String locName = (loc['name'] ?? '').toString();

                                        // Захист від хибної точки в центрі Києва через заголовок "Київщина:"
                                        bool isKyivCenterCoord = (lat - 50.450).abs() < 0.005 && (lon - 30.523).abs() < 0.005;
                                        if (isKyivCenterCoord &&
                                            msgTextLower.contains('київщин') &&
                                            !msgTextLower.contains('на київ') &&
                                            !msgTextLower.contains('м. київ')) {
                                          continue;
                                        }

                                        final pt = LatLng(lat, lon);
                                        path.add(pt);
                                        if (locName.isNotEmpty) {
                                          locNames.add(locName);
                                        }
                                      } catch (_) {
                                        // Ігноруємо некоректні координати окремої точки
                                      }
                                    }
                                  }

                                  if (path.isEmpty) continue;

                                  final bool hasMultiTargetWords = msgTextLower.contains('ще один') ||
                                      msgTextLower.contains('новий') ||
                                      msgTextLower.contains('нова') ||
                                      msgTextLower.contains('другий') ||
                                      msgTextLower.contains('ще 1') ||
                                      msgTextLower.contains('ще 2');

                                  if (!hasMultiTargetWords && path.isNotEmpty) {
                                    final checkPts = (t['waypoints'] as List<LatLng>?) ?? path;
                                    bool isResurrected = false;
                                    for (final pt in checkPts) {
                                      for (final clr in recentlyClearedLocations) {
                                        final secDiff = msgTime.difference(clr.time).inSeconds.abs();
                                        if (secDiff <= 120) {
                                          final dMeters = const Distance().as(LengthUnit.Meter, clr.point, pt);
                                          if (dMeters <= 5000.0) {
                                            isResurrected = true;
                                            break;
                                          }
                                        }
                                      }
                                      if (isResurrected) break;
                                    }
                                    if (isResurrected) {
                                      continue;
                                    }
                                  }

                                  // Розумне розведення рою (Swarm Lateral Offset):
                                  if (msgThreats.length > 1 && threatIdx > 0) {
                                    final side = (threatIdx % 2 == 1) ? 1.0 : -1.0;
                                    final rank = (threatIdx + 1) ~/ 2;
                                    double perpLat = 0.0;
                                    double perpLon = 0.0;
                                    double dirLat = 0.0;
                                    double dirLon = 0.0;
                                    if (path.length >= 2) {
                                      final dLat = path.last.latitude - path.first.latitude;
                                      final dLon = path.last.longitude - path.first.longitude;
                                      final dist = math.sqrt(dLat * dLat + dLon * dLon);
                                      if (dist > 0.0001) {
                                        dirLat = dLat / dist;
                                        dirLon = dLon / dist;
                                        perpLat = -dLon / dist;
                                        perpLon = dLat / dist;
                                      }
                                    }
                                    if (perpLat == 0.0 && perpLon == 0.0) {
                                      perpLat = 0.707;
                                      perpLon = -0.707;
                                      dirLat = 0.707;
                                      dirLon = 0.707;
                                    }
                                    final latOff = perpLat * (side * rank * 0.006) + dirLat * (-rank * 0.004);
                                    final lonOff = perpLon * (side * rank * 0.006) + dirLon * (-rank * 0.004);
                                    path = path.map((pt) => LatLng(pt.latitude + latOff, pt.longitude + lonOff)).toList();
                                  }

                                  final bool hasExplicitDroneInMsg = msgTextLower.contains('шахед') ||
                                      msgTextLower.contains('бпла') ||
                                      msgTextLower.contains('мопед') ||
                                      msgTextLower.contains('двз') ||
                                      msgTextLower.contains('дрон') ||
                                      msgTextLower.contains('геран');

                                  final bool isExitingOblast = msgTextLower.contains('вийшов в житомирськ') ||
                                      msgTextLower.contains('вийшов у житомирськ') ||
                                      msgTextLower.contains('вийшов в черкаськ') ||
                                      msgTextLower.contains('покинув область') ||
                                      msgTextLower.contains('за межі області') ||
                                      msgTextLower.contains('в житомирську пішов');

                                  String rawType = (t['type'] ?? 'shahed').toString();
                                  if (rawType == 'unknown') {
                                    rawType = 'shahed';
                                  }

                                  if (activeBallisticOrMissileContext && !hasExplicitDroneInMsg) {
                                    if (rawType == 'shahed' || rawType == 'shahed_jet') {
                                      rawType = 'missile_ballistic';
                                    }
                                  } else if (activeJetDroneContext && !hasPistonDroneInMsg) {
                                    final alt = t['altitudeMeters'] as int?;
                                    if (rawType == 'shahed' && (alt == null || alt >= 1500)) {
                                      rawType = 'shahed_jet';
                                    }
                                  }

                                  String defaultLabel = _getDefaultThreatLabel(rawType);
                                  double defaultSpeed = _getDefaultThreatSpeed(rawType);
                                  double speed = (t['speed'] as num?)?.toDouble() ?? defaultSpeed;
                                  if (rawType == 'missile_ballistic' && speed < 1000.0) {
                                    speed = 5000.0;
                                  } else if (rawType == 'shahed_jet' && speed < 300.0) {
                                    speed = 550.0;
                                  }

                                  String effectiveLabel = (t['label'] ?? '').toString();
                                  if (effectiveLabel.isEmpty || 
                                      (rawType == 'missile_ballistic' && effectiveLabel.contains('Шахед')) ||
                                      (rawType == 'shahed_jet' && (effectiveLabel.contains('Шахед') || effectiveLabel.contains('185')))) {
                                    effectiveLabel = defaultLabel;
                                  }

                                  final bool isMissileThreat = rawType.contains('missile') ||
                                      rawType.contains('ballistic') ||
                                      rawType.contains('hypersonic') ||
                                      rawType.contains('cruise') ||
                                      rawType.contains('supersonic') ||
                                      rawType == 'kab';

                                  final msgPostId = normPost(msg['postId'] ?? msg['post_id']);
                                  final replyToPostId = normPost(msg['reply_to_post_id'] ?? msg['replyToPostId']);
                                  final replyQuotedText = msg['reply_quoted_text']?.toString() ?? msg['replyQuotedText']?.toString();
                                  final replyToId = msg['reply_to_msg_id'] ?? msg['replyToId'];
                                  final mergedMsgIds = (msg['merged_msg_ids'] as List?)?.cast<dynamic>() ?? [];
                                  final mergedPostIds = (msg['merged_post_ids'] as List?)?.map((p) => normPost(p)).whereType<String>().toList() ?? [];

                                  bool mergedIntoExisting = false;
                                  final bool isNewDirectional = (t['isDirectional'] == true) && path.length == 1;

                                  void applySmartWaypointAppend(Map<String, dynamic> target, DateTime updateTime) {
                                    final existingWaypoints = (target['waypoints'] as List<LatLng>?) ??
                                        List<LatLng>.from((target['path'] as List<LatLng>?) ?? []);
                                    final existingNames = (target['locNames'] as List<String>?) ?? [];
                                    final prevTime = (target['lastUpdated'] as DateTime?) ?? updateTime;
                                    final double dtSec = updateTime.difference(prevTime).inSeconds.abs().toDouble();
                                    final double spdKmh = (target['speed'] as num?)?.toDouble() ?? 185.0;
                                    final double spdMs = spdKmh * (1000.0 / 3600.0);

                                    // Якщо попередня точка була прогнозним вектором ("На Гатне", "На Коцюбу"),
                                    // але нова точка прийшла раніше, ніж ціль фізично долетіла туди, і курс змінився —
                                    // прибираємо або замінюємо недосягнуту прогнозну точку, щоб не малювати хибний зигзаг!
                                    if (target['hasPendingTarget'] == true && existingWaypoints.length >= 2 && path.isNotEmpty) {
                                      final prevConfirmedPt = existingWaypoints[existingWaypoints.length - 2];
                                      final pendingPt = existingWaypoints.last;
                                      final newPt = path.first;
                                      final double legDistM = const Distance().as(LengthUnit.Meter, prevConfirmedPt, pendingPt);
                                      final double flownM = spdMs * dtSec;
                                      final double progress = legDistM > 80.0 ? (flownM / legDistM) : 1.0;

                                      final double v1Lat = pendingPt.latitude - prevConfirmedPt.latitude;
                                      final double v1Lon = pendingPt.longitude - prevConfirmedPt.longitude;
                                      final double v2Lat = newPt.latitude - pendingPt.latitude;
                                      final double v2Lon = newPt.longitude - pendingPt.longitude;
                                      final double dot = v1Lat * v2Lat + v1Lon * v2Lon;
                                      final double distPrevToNew = const Distance().as(LengthUnit.Meter, prevConfirmedPt, newPt);

                                      if (progress < 0.65 && (dot < 0.0 || distPrevToNew < legDistM * 0.92)) {
                                        if (progress >= 0.18 && flownM >= 450.0) {
                                          final double clampedP = progress.clamp(0.18, 0.55);
                                          existingWaypoints[existingWaypoints.length - 1] = LatLng(
                                            prevConfirmedPt.latitude + v1Lat * clampedP,
                                            prevConfirmedPt.longitude + v1Lon * clampedP,
                                          );
                                        } else {
                                          existingWaypoints.removeLast();
                                        }
                                        if (existingNames.length >= 2) {
                                          existingNames.removeLast();
                                        }
                                      }
                                    }

                                    bool pointAdded = false;
                                    for (int k = 0; k < path.length; k++) {
                                      final pt = path[k];
                                      final d = existingWaypoints.isEmpty
                                          ? 999999.0
                                          : const Distance().as(LengthUnit.Meter, existingWaypoints.last, pt);
                                      if (d > 350.0) {
                                        existingWaypoints.add(pt);
                                        pointAdded = true;
                                        if (k < locNames.length && (existingNames.isEmpty || existingNames.last != locNames[k])) {
                                          existingNames.add(locNames[k]);
                                        }
                                      }
                                    }
                                    target['waypoints'] = existingWaypoints;
                                    target['path'] = existingWaypoints.length >= 2
                                        ? [existingWaypoints[existingWaypoints.length - 2], existingWaypoints.last]
                                        : List<LatLng>.from(existingWaypoints);
                                    target['locNames'] = existingNames;
                                    target['route'] = existingNames.isNotEmpty ? existingNames.join(' → ') : target['route'];
                                    target['hasPendingTarget'] = isNewDirectional;
                                    if (pointAdded) {
                                      target['lastUpdated'] = updateTime;
                                    }
                                  }

                                  // 1. Пріоритет 1: Telegram Reply (replyToPostId або replyToId)
                                  final bool hasExplicitReply = replyToPostId != null || replyToId != null;
                                  if (hasExplicitReply && threats.isNotEmpty) {
                                    for (var existing in threats) {
                                      if (existing['isDestroyed'] == true) continue;
                                      final lastPostId = normPost(existing['lastPostId']);
                                      final histPosts = existing['historyPostIds'] as Set<dynamic>?;
                                      final normHistPosts = histPosts?.map((p) => normPost(p)).whereType<String>().toSet();
                                      final histMsgIds = existing['historyMsgIds'] as Set<dynamic>?;
                                      final existingMsgId = existing['msgId'];

                                      final bool matchPost = replyToPostId != null &&
                                          (lastPostId == replyToPostId ||
                                           (normHistPosts != null && (normHistPosts.contains(replyToPostId) || mergedPostIds.any((mp) => normHistPosts.contains(mp)))));
                                      final bool matchId = replyToId != null &&
                                          (existingMsgId == replyToId ||
                                           (histMsgIds != null && (histMsgIds.contains(replyToId) || mergedMsgIds.any((mid) => histMsgIds.contains(mid)))));

                                      if (matchPost || matchId) {
                                        applySmartWaypointAppend(existing, msgTime);
                                        if (isExitingOblast) {
                                          if (existing['route'] != null && !existing['route'].toString().contains('(Вихід з області)')) {
                                            existing['route'] = '${existing['route']} (Вихід з області)';
                                          }
                                          existing['isExitingOblast'] = true;
                                          existing['ttl'] = 45;
                                        }

                                        existing['lastUpdated'] = msgTime;
                                        existing['lastPostId'] = msgPostId;
                                        final histPostsSet = (existing['historyPostIds'] as Set<dynamic>? ?? <dynamic>{});
                                        if (msgPostId != null) histPostsSet.add(msgPostId);
                                        for (final mp in mergedPostIds) {
                                          histPostsSet.add(mp);
                                        }
                                        existing['historyPostIds'] = histPostsSet;

                                        existing['msgId'] = msg['id'];
                                        final histMsgs = (existing['historyMsgIds'] as Set<dynamic>? ?? <dynamic>{});
                                        if (msg['id'] != null) histMsgs.add(msg['id']);
                                        for (final mid in mergedMsgIds) {
                                          histMsgs.add(mid);
                                        }
                                        existing['historyMsgIds'] = histMsgs;
                                        existing['channel'] = msg['channel'];
                                        existing['text'] = msgTextLower;
                                        existing['rawText'] = msg['text']?.toString() ?? '';

                                        final bool existingIsMissile = (existing['type'] ?? '').toString().contains('missile') || existing['type'] == 'kab';
                                        final bool existingIsJet = existing['type'] == 'shahed_jet';
                                        if (existingIsJet && rawType == 'shahed' && !hasPistonDroneInMsg) {
                                          rawType = 'shahed_jet';
                                          effectiveLabel = _getDefaultThreatLabel('shahed_jet');
                                          speed = math.max((existing['speed'] as num?)?.toDouble() ?? 550.0, 550.0);
                                        }
                                        if (!existingIsMissile || rawType.contains('missile') || rawType == 'kab') {
                                          existing['type'] = rawType;
                                          existing['label'] = effectiveLabel;
                                          existing['speed'] = (t['speed'] as num?)?.toDouble() ?? speed;
                                        }
                                        if (t['orderTag'] != null) existing['orderTag'] ??= t['orderTag'];
                                        if (t['isCircling'] == true) existing['isCircling'] = true;
                                        if (t['altitude'] != null) existing['altitude'] = t['altitude'];
                                        if (t['altitudeMeters'] != null) {
                                          final prevAlt = existing['altitudeMeters'] as int?;
                                          final newAlt = t['altitudeMeters'] as int;
                                          if (prevAlt != null && prevAlt - newAlt >= 300) {
                                            existing['isDescending'] = true;
                                          }
                                          existing['altitudeMeters'] = newAlt;
                                        }
                                        if (t['isDescending'] == true) existing['isDescending'] = true;

                                        mergedIntoExisting = true;
                                        break;
                                      }
                                    }
                                  }

                                  // Fallback: якщо це Reply, але батьківська ціль не знайдена в пам'яті (вимита TTL),
                                  // проте у replyQuotedText є назва локації — використовуємо її як початкову точку (From)
                                  if (!mergedIntoExisting && hasExplicitReply && replyQuotedText != null && replyQuotedText.isNotEmpty) {
                                    final quotedThreats = ref.read(messagesProvider.notifier).parseLocalThreats(replyQuotedText);
                                    if (quotedThreats.isNotEmpty) {
                                      final qPath = quotedThreats.first['path'] as List<dynamic>?;
                                      if (qPath != null && qPath.isNotEmpty) {
                                        final qLoc = qPath.last;
                                        try {
                                          final qLat = (qLoc['lat'] as num).toDouble();
                                          final qLon = (qLoc['lon'] as num).toDouble();
                                          final qName = (qLoc['name'] ?? '').toString();
                                          final qPt = LatLng(qLat, qLon);
                                          if (path.isEmpty || const Distance().as(LengthUnit.Meter, qPt, path.first) > 500) {
                                            path.insert(0, qPt);
                                            if (qName.isNotEmpty) {
                                              locNames.insert(0, qName);
                                            }
                                          }
                                        } catch (_) {}
                                      }
                                    }
                                  }

                                  // 2. Обробка повідомлень без Reply (або якщо Reply не зіставився)
                                  if (!mergedIntoExisting) {
                                    if (path.isNotEmpty) {
                                      for (var existing in threats) {
                                        if (existing['isDestroyed'] == true) continue;
                                        final existingPath = (existing['path'] as List<LatLng>?) ?? [];
                                        if (existingPath.isEmpty) {
                                          existing['path'] = List<LatLng>.from(path);
                                          existing['waypoints'] = List<LatLng>.from(path);
                                          existing['hasPendingTarget'] = isNewDirectional;
                                          String effectiveRoute = (t['route'] ?? '').toString();
                                          if (isExitingOblast && !effectiveRoute.contains('(Вихід з області)')) {
                                            effectiveRoute = effectiveRoute.isEmpty ? 'Вихід з області' : '$effectiveRoute (Вихід з області)';
                                          }
                                          existing['route'] = effectiveRoute;
                                          existing['isExitingOblast'] = isExitingOblast;
                                          existing['ttl'] = getThreatTtlSeconds(rawType, isExitingOblast: isExitingOblast);
                                          existing['lastUpdated'] = msgTime;
                                          existing['lastPostId'] = msgPostId;
                                          if (msgPostId != null) {
                                            final histPosts = (existing['historyPostIds'] as Set<dynamic>? ?? <dynamic>{});
                                            histPosts.add(msgPostId);
                                            existing['historyPostIds'] = histPosts;
                                          }
                                          existing['text'] = msgTextLower;
                                          existing['rawText'] = msg['text']?.toString() ?? '';
                                          existing['msgId'] = msg['id'];
                                          final hist = (existing['historyMsgIds'] as Set<dynamic>? ?? <dynamic>{});
                                          hist.add(msg['id']);
                                          existing['historyMsgIds'] = hist;
                                          existing['channel'] = msg['channel'];
                                          existing['locNames'] = List<String>.from(locNames);

                                          final bool existingIsMissile = existing['type'] != null &&
                                              (existing['type'].toString().contains('missile') || existing['type'] == 'kab');
                                          final bool existingIsJet = existing['type'] == 'shahed_jet';

                                          if (existingIsJet && rawType == 'shahed' && !hasPistonDroneInMsg) {
                                            rawType = 'shahed_jet';
                                            effectiveLabel = _getDefaultThreatLabel('shahed_jet');
                                            speed = math.max((existing['speed'] as num?)?.toDouble() ?? 550.0, 550.0);
                                          }

                                          if (!existingIsMissile || rawType.contains('missile') || rawType == 'kab') {
                                            existing['type'] = rawType;
                                            existing['label'] = effectiveLabel;
                                            existing['speed'] = (t['speed'] as num?)?.toDouble() ?? speed;
                                          }
                                          if (t['orderTag'] != null) existing['orderTag'] ??= t['orderTag'];
                                          if (t['isCircling'] == true) existing['isCircling'] = true;
                                          if (t['altitude'] != null) existing['altitude'] = t['altitude'];
                                          if (t['altitudeMeters'] != null) {
                                            final prevAlt = existing['altitudeMeters'] as int?;
                                            final newAlt = t['altitudeMeters'] as int;
                                            if (prevAlt != null && prevAlt - newAlt >= 300) {
                                              existing['isDescending'] = true;
                                            }
                                            existing['altitudeMeters'] = newAlt;
                                          }
                                          if (t['isDescending'] == true) existing['isDescending'] = true;
                                          mergedIntoExisting = true;
                                          break;
                                        }
                                      }
                                    }

                                    if (!mergedIntoExisting) {
                                      Map<String, dynamic>? bestCandidate;
                                      double bestCandidateScore = double.infinity;

                                      for (var existing in threats) {
                                        if (existing['isDestroyed'] == true) continue;
                                        final existingType = (existing['type'] ?? '').toString();
                                        final bool existingIsMissile = existingType.contains('missile') ||
                                            existingType.contains('ballistic') ||
                                            existingType.contains('hypersonic') ||
                                            existingType.contains('cruise') ||
                                            existingType.contains('supersonic') ||
                                            existingType == 'kab';

                                        final bool canMergeType = (existingType == rawType) ||
                                            (existingType == 'shahed_jet' && rawType == 'shahed') ||
                                            (existingType == 'shahed' && rawType == 'shahed_jet') ||
                                            isMissileThreat ||
                                            existingIsMissile;

                                        if (!canMergeType) continue;

                                        final existingPath = (existing['path'] as List<LatLng>?) ?? [];
                                        if (existingPath.isEmpty) continue;
                                        final existingWaypoints = (existing['waypoints'] as List<LatLng>?) ?? existingPath;
                                        final existingTime = (existing['lastUpdated'] as DateTime?) ?? msgTime;
                                        final double timeDiffSeconds = msgTime.difference(existingTime).inSeconds.abs().toDouble();

                                        if (existing['msgId'] == msg['id']) {
                                          continue;
                                        }

                                        // Підтримка нумерованих цілей ("Перший / Другий")
                                        if (t['orderTag'] != null && existing['orderTag'] != null && existing['orderTag'] != t['orderTag']) {
                                          continue;
                                        }

                                        final bool hasMultiTargetMarker = msgTextLower.contains('ще ') ||
                                            msgTextLower.contains('ще один') ||
                                            msgTextLower.contains('ще 1') ||
                                            msgTextLower.contains('ще 2') ||
                                            msgTextLower.contains('новий') ||
                                            msgTextLower.contains('інший') ||
                                            msgTextLower.contains('пара ') ||
                                            msgTextLower.contains('2х') ||
                                            msgTextLower.contains('3х') ||
                                            msgTextLower.contains('двоє');

                                        if (hasMultiTargetMarker) {
                                          continue;
                                        }

                                        final existingSpeedKmh = (existing['speed'] as num?)?.toDouble() ?? 185.0;
                                        final existingSpeedMs = existingSpeedKmh * (1000.0 / 3600.0);
                                        final double extraElapsedSec = timeDiffSeconds.clamp(0.0, 900.0);
                                        final LatLng currentExtrapolatedPos;
                                        if (existingPath.length >= 2 && extraElapsedSec > 0) {
                                          final lastPt = existingPath.last;
                                          final prevPt = existingPath[existingPath.length - 2];
                                          final double extraDistM = math.min(existingSpeedMs * extraElapsedSec, 15000.0);
                                          final double bearingRad = _calculateBearing(prevPt, lastPt);
                                          const double earthRadius = 6378137.0;
                                          final double d = extraDistM / earthRadius;
                                          final double lat1 = lastPt.latitude * math.pi / 180.0;
                                          final double lon1 = lastPt.longitude * math.pi / 180.0;
                                          final double lat2 = math.asin(math.sin(lat1) * math.cos(d) + math.cos(lat1) * math.sin(d) * math.cos(bearingRad));
                                          final double lon2 = lon1 + math.atan2(math.sin(bearingRad) * math.sin(d) * math.cos(lat1), math.cos(d) - math.sin(lat1) * math.sin(lat2));
                                          currentExtrapolatedPos = LatLng(lat2 * 180.0 / math.pi, lon2 * 180.0 / math.pi);
                                        } else {
                                          currentExtrapolatedPos = existingPath.last;
                                        }

                                        final double distFromExtrapolatedMeters = const Distance().as(LengthUnit.Meter, currentExtrapolatedPos, path.first);
                                        final double distFromLastPtMeters = const Distance().as(LengthUnit.Meter, existingPath.last, path.first);
                                        double distFromPrevConfirmedMeters = distFromLastPtMeters;
                                        if (existing['hasPendingTarget'] == true && existingWaypoints.length >= 2) {
                                          distFromPrevConfirmedMeters = const Distance().as(
                                            LengthUnit.Meter,
                                            existingWaypoints[existingWaypoints.length - 2],
                                            path.first,
                                          );
                                        }
                                        // Враховуємо мінімальну дистанцію між екстрапольованою точкою та останнім підтвердженим орієнтиром,
                                        // щоб розвороти на 90°-180° не розривали маршрут на кілька окремих іконок!
                                        final double effectiveStitchDistMeters = math.min(
                                          distFromExtrapolatedMeters,
                                          math.min(distFromLastPtMeters, distFromPrevConfirmedMeters),
                                        );

                                        // Втрачена фіксація (шахед не фіксувався довше свого часу життя):
                                        // відновлюємо ціль лише якщо нова точка потрапила в невидиме коло пошуку,
                                        // яке росте від місця втрати фіксації зі швидкістю цієї цілі
                                        if (isLostTrackableType(existingType) && existing['isExitingOblast'] != true) {
                                          final double sinceLostSec = timeDiffSeconds - getThreatLifetimeSeconds(existing);
                                          if (sinceLostSec > 0) {
                                            if (sinceLostSec > kLostTrackRetentionSec) continue;
                                            final double searchRadiusMeters = kLostTrackBaseRadiusMeters + existingSpeedMs * sinceLostSec;
                                            if (distFromLastPtMeters > searchRadiusMeters) continue;
                                          }
                                        }

                                        if (path.length >= 2) {
                                          if (effectiveStitchDistMeters > 7000.0) {
                                            continue; // Окремий вектор >= 2 точок за межами 7 км не склеюємо!
                                          }
                                        }

                                        // а) Крос-канальна дедуплікація
                                        final existingChannel = existing['channel']?.toString();
                                        final msgChannel = msg['channel']?.toString();
                                        final bool isSameChannel = (existingChannel != null && msgChannel != null && existingChannel == msgChannel);
                                        final bool isCrossChannelDuplicate = (existingChannel != null && msgChannel != null && !isSameChannel) &&
                                            timeDiffSeconds <= 90.0 &&
                                            effectiveStitchDistMeters <= 5000.0;

                                        if (isCrossChannelDuplicate) {
                                          existing['msgId'] = msg['id'];
                                          if (msgPostId != null) {
                                            existing['lastPostId'] = msgPostId;
                                            final histPosts = (existing['historyPostIds'] as Set<dynamic>? ?? <dynamic>{});
                                            histPosts.add(msgPostId);
                                            existing['historyPostIds'] = histPosts;
                                          }
                                          final histMsgs = (existing['historyMsgIds'] as Set<dynamic>? ?? <dynamic>{});
                                          histMsgs.add(msg['id']);
                                          existing['historyMsgIds'] = histMsgs;
                                          if (t['isCircling'] == true) existing['isCircling'] = true;
                                          if (t['altitude'] != null) existing['altitude'] = t['altitude'];
                                          if (t['altitudeMeters'] != null) existing['altitudeMeters'] = t['altitudeMeters'];
                                          if (t['isDescending'] == true) existing['isDescending'] = true;
                                          if (t['orderTag'] != null) existing['orderTag'] ??= t['orderTag'];
                                          mergedIntoExisting = true;
                                          break;
                                        }

                                        // б) Кінематичний поріг: для БпЛА > 22 км — гарантовано різні цілі!
                                        final bool isAnyMissile = isMissileThreat || existingIsMissile || activeBallisticOrMissileContext;
                                        final bool isJetThreat = (existingType == 'shahed_jet' || rawType == 'shahed_jet');

                                        final bool isSequentialSameChannelSinglePoint = isSameChannel &&
                                            path.length == 1 &&
                                            timeDiffSeconds <= 180.0 &&
                                            !hasMultiTargetMarker;

                                        if (!isAnyMissile && !isJetThreat) {
                                          if (effectiveStitchDistMeters > (isSequentialSameChannelSinglePoint ? 16000.0 : 22000.0)) {
                                            continue;
                                          }
                                        } else if (isJetThreat) {
                                          if (effectiveStitchDistMeters > 65000.0) {
                                            continue;
                                          }
                                        } else {
                                          if (effectiveStitchDistMeters > 90000.0) {
                                            continue;
                                          }
                                        }

                                        final double timeDiffHours = timeDiffSeconds / 3600.0;
                                        final double effSpeed = isAnyMissile ? math.max(speed, 5000.0) : (isJetThreat ? math.max(speed, 550.0) : speed);
                                        double maxAllowedKm = isAnyMissile
                                            ? (effSpeed * timeDiffHours * 1.2).clamp(10.0, 90.0)
                                            : (isJetThreat
                                                ? (effSpeed * timeDiffHours * 1.6).clamp(10.0, 65.0)
                                                : (effSpeed * timeDiffHours * 1.4).clamp(4.5, 22.0));
                                        if (isSequentialSameChannelSinglePoint) {
                                          maxAllowedKm = math.max(maxAllowedKm, 15.0);
                                        } else if (!isAnyMissile && !isJetThreat && !isSameChannel && path.length == 1 && timeDiffSeconds <= 120.0) {
                                          maxAllowedKm = math.min(maxAllowedKm, 8.5);
                                        }
                                        if (effectiveStitchDistMeters > maxAllowedKm * 1000.0) {
                                          continue;
                                        }

                                        final double candidateScore = effectiveStitchDistMeters +
                                            (timeDiffSeconds * 12.0) -
                                            (isSameChannel ? 5000.0 : 0.0) -
                                            (isSameChannel && timeDiffSeconds <= 90.0 ? 3000.0 : 0.0);
                                        if (candidateScore < bestCandidateScore) {
                                          bestCandidateScore = candidateScore;
                                          bestCandidate = existing;
                                        }
                                      }

                                      if (!mergedIntoExisting && bestCandidate != null) {
                                        final existing = bestCandidate;
                                        final existingType = (existing['type'] ?? '').toString();
                                        final bool existingIsMissile = existingType.contains('missile') ||
                                            existingType.contains('ballistic') ||
                                            existingType.contains('hypersonic') ||
                                            existingType.contains('cruise') ||
                                            existingType.contains('supersonic') ||
                                            existingType == 'kab';
                                        final bool isAnyMissile = isMissileThreat || existingIsMissile || activeBallisticOrMissileContext;
                                        final bool isJetThreat = (existingType == 'shahed_jet' || rawType == 'shahed_jet');
                                        final DateTime? prevFixTime = existing['lastUpdated'] as DateTime?;
                                        final bool wasLostTrack = isLostTrackableType(existingType) &&
                                            existing['isExitingOblast'] != true &&
                                            prevFixTime != null &&
                                            msgTime.difference(prevFixTime).inSeconds > getThreatLifetimeSeconds(existing);

                                        if (isAnyMissile) {
                                          if (existing['type'] != 'missile_hypersonic' && existing['type'] != 'missile_cruise') {
                                            existing['type'] = 'missile_ballistic';
                                            existing['speed'] = 5000.0;
                                            existing['label'] = 'Балістична / Швидкісна ціль';
                                          }
                                        } else if (isJetThreat) {
                                          if (!hasPistonDroneInMsg) {
                                            existing['type'] = 'shahed_jet';
                                            existing['speed'] = math.max((existing['speed'] as num?)?.toDouble() ?? 550.0, (t['speed'] as num?)?.toDouble() ?? 550.0);
                                            existing['label'] = 'Реактивний БпЛА';
                                          }
                                        } else if (t['speed'] != null && (t['speed'] as num) > 0) {
                                          existing['speed'] = (t['speed'] as num).toDouble();
                                        }

                                        applySmartWaypointAppend(existing, msgTime);
                                        // Фіксацію втраченої цілі відновлено — повертаємо її на мапу
                                        if (wasLostTrack) {
                                          existing['lastUpdated'] = msgTime;
                                        }

                                        if (isExitingOblast) {
                                          if (existing['route'] != null && !existing['route'].toString().contains('(Вихід з області)')) {
                                            existing['route'] = '${existing['route']} (Вихід з області)';
                                          }
                                          existing['isExitingOblast'] = true;
                                          existing['ttl'] = 45;
                                        }
                                        existing['text'] = msgTextLower;
                                        existing['rawText'] = msg['text']?.toString() ?? '';
                                        existing['msgId'] = msg['id'];
                                        existing['lastPostId'] = msgPostId;
                                        if (msgPostId != null) {
                                          final histPosts = (existing['historyPostIds'] as Set<dynamic>? ?? <dynamic>{});
                                          histPosts.add(msgPostId);
                                          existing['historyPostIds'] = histPosts;
                                        }
                                        final hist = (existing['historyMsgIds'] as Set<dynamic>? ?? <dynamic>{});
                                        hist.add(msg['id']);
                                        existing['historyMsgIds'] = hist;
                                        existing['channel'] = msg['channel'];
                                        if (t['isCircling'] == true) existing['isCircling'] = true;
                                        if (t['altitude'] != null) existing['altitude'] = t['altitude'];
                                        if (t['altitudeMeters'] != null) {
                                          final prevAlt = existing['altitudeMeters'] as int?;
                                          final newAlt = t['altitudeMeters'] as int;
                                          if (prevAlt != null && prevAlt - newAlt >= 300) {
                                            existing['isDescending'] = true;
                                          }
                                          existing['altitudeMeters'] = newAlt;
                                        }
                                        if (t['isDescending'] == true) existing['isDescending'] = true;
                                        if (t['orderTag'] != null) existing['orderTag'] ??= t['orderTag'];
                                        mergedIntoExisting = true;
                                      }
                                    }
                                  }

                                  if (!mergedIntoExisting) {
                                    String initialRoute = t['route'] ?? (locNames.isNotEmpty ? locNames.join(' → ') : 'Київський сектор');
                                    if (isExitingOblast && !initialRoute.contains('(Вихід з області)')) {
                                      initialRoute = '$initialRoute (Вихід з області)';
                                    }
                                    threats.add({
                                      'type': rawType,
                                      'label': effectiveLabel,
                                      'locNames': locNames,
                                      'route': initialRoute,
                                      'isExitingOblast': isExitingOblast,
                                      'ttl': getThreatTtlSeconds(rawType, isExitingOblast: isExitingOblast),
                                      'speed': (t['speed'] as num?)?.toDouble() ?? speed,
                                      'orderTag': t['orderTag'],
                                      'path': path,
                                      'waypoints': List<LatLng>.from(path),
                                      'hasPendingTarget': isNewDirectional,
                                      'lastPostId': msgPostId,
                                      'historyPostIds': <dynamic>{?msgPostId},
                                      'lastUpdated': msgTime,
                                      'staggerDelay': staggerDelay,
                                      'text': msgTextLower,
                                      'rawText': msg['text']?.toString() ?? '',
                                      'msgId': msg['id'],
                                      'historyMsgIds': <dynamic>{msg['id']},
                                      'channel': msg['channel'],
                                      'isCircling': t['isCircling'] == true,
                                      'altitude': t['altitude'],
                                      'altitudeMeters': t['altitudeMeters'],
                                      'isDescending': t['isDescending'] == true,
                                    });
                                  }
                                }
                              } else {
                                // Повідомлення без локацій: прив'язка одиночних повідомлень висоти / зниження / скасування курсу ("Ні") до останньої активної цілі
                                final text = msg['text']?.toString() ?? '';
                                final alt = ref.read(messagesProvider.notifier).extractAltitude(text);
                                final speed = ref.read(messagesProvider.notifier).extractSpeed(text);
                                final isDescKeyword = msgTextLower.contains('зниження') ||
                                    msgTextLower.contains('знижується') ||
                                    msgTextLower.contains('падає') ||
                                    msgTextLower.contains('пікірує') ||
                                    msgTextLower.contains('скинув висоту') ||
                                    msgTextLower.contains('низько');
                                final bool isCirclingKeyword = msgTextLower.contains('літає') ||
                                    msgTextLower.contains('кружля') ||
                                    msgTextLower.contains('крутить') ||
                                    msgTextLower.contains('намоту') ||
                                    msgTextLower.contains('мотає') ||
                                    msgTextLower.contains('мотають') ||
                                    msgTextLower.contains('нарізає') ||
                                    msgTextLower.contains('накручу') ||
                                    msgTextLower.contains('круги');
                                final bool isCourseCancelKeyword = RegExp(
                                  r'^(?:ні|нє|ніт|відміна|не туди|повернув|розвернувся|звернув|змінив курс|крутить назад)[!.,\s]*$',
                                  caseSensitive: false,
                                ).hasMatch(msgTextLower.trim());
                                final bool isExitOblastKeyword = RegExp(
                                  r'^(?:вийшли|вийшов|інші вийшли|покинув область|вийшли з області|вийшов з області)[!.,\s]*$',
                                  caseSensitive: false,
                                ).hasMatch(msgTextLower.trim());
                                final replyToId = msg['reply_to_msg_id'] ?? msg['replyToId'];
                                final replyToPostId = normPost(msg['reply_to_post_id'] ?? msg['replyToPostId']);
                                final bool hasExplicitReply = replyToPostId != null || replyToId != null;

                                if (alt != null || speed != null || isCirclingKeyword || isDescKeyword || isCourseCancelKeyword || isExitOblastKeyword || hasExplicitReply) {
                                    if (alt != null) {
                                      activeBallisticOrMissileContext = false;
                                    }
                                    final replyToId = msg['reply_to_msg_id'] ?? msg['replyToId'];
                                    final replyToPostId = normPost(msg['reply_to_post_id'] ?? msg['replyToPostId']);
                                    final mergedMsgIds = (msg['merged_msg_ids'] as List?)?.cast<dynamic>() ?? [];
                                    final mergedPostIds = (msg['merged_post_ids'] as List?)?.map((p) => normPost(p)).whereType<String>().toList() ?? [];

                                    Map<String, dynamic>? targetThreat;
                                    if (replyToPostId != null || replyToId != null) {
                                      for (int ti = threats.length - 1; ti >= 0; ti--) {
                                        final candidate = threats[ti];
                                        if (candidate['isDestroyed'] == true) continue;
                                        final lastPostId = normPost(candidate['lastPostId']);
                                        final histPosts = candidate['historyPostIds'] as Set<dynamic>?;
                                        final normHistPosts = histPosts?.map((p) => normPost(p)).whereType<String>().toSet();
                                        final history = candidate['historyMsgIds'] as Set<dynamic>?;

                                        final bool matchPost = replyToPostId != null &&
                                            (lastPostId == replyToPostId ||
                                             (normHistPosts != null && (normHistPosts.contains(replyToPostId) || mergedPostIds.any((mp) => normHistPosts.contains(mp)))));
                                        final bool matchId = replyToId != null &&
                                            (candidate['msgId'] == replyToId ||
                                             (history != null && (history.contains(replyToId) || mergedMsgIds.any((mid) => history.contains(mid)))));

                                        if (matchPost || matchId) {
                                          targetThreat = candidate;
                                          break;
                                        }
                                      }
                                    }

                                  final msgChannel = msg['channel'];
                                  if (targetThreat == null) {
                                    for (int ti = threats.length - 1; ti >= 0; ti--) {
                                      final candidate = threats[ti];
                                      if (candidate['isDestroyed'] == true) continue;
                                      if (msgChannel != null && candidate['channel'] != null && candidate['channel'] != msgChannel) {
                                        continue;
                                      }
                                      final candTime = candidate['lastUpdated'] as DateTime?;
                                      if (candTime != null && msgTime.difference(candTime).inMinutes.abs() <= 3) {
                                        targetThreat = candidate;
                                        break;
                                      }
                                    }
                                  }

                                  if (targetThreat == null && threats.isNotEmpty) {
                                    for (int ti = threats.length - 1; ti >= 0; ti--) {
                                      final candidate = threats[ti];
                                      if (candidate['isDestroyed'] == true) continue;
                                      final candTime = candidate['lastUpdated'] as DateTime?;
                                      if (candTime != null && msgTime.difference(candTime).inMinutes.abs() <= 3) {
                                        targetThreat = candidate;
                                        break;
                                      }
                                    }
                                  }

                                  if (targetThreat != null) {
                                    if (isCourseCancelKeyword && targetThreat['hasPendingTarget'] == true) {
                                      final wp = (targetThreat['waypoints'] as List<LatLng>?) ?? [];
                                      final ln = (targetThreat['locNames'] as List<String>?) ?? [];
                                      if (wp.length >= 2) {
                                        wp.removeLast();
                                        targetThreat['waypoints'] = wp;
                                        targetThreat['path'] = wp.length >= 2
                                            ? [wp[wp.length - 2], wp.last]
                                            : List<LatLng>.from(wp);
                                      }
                                      if (ln.length >= 2) {
                                        ln.removeLast();
                                        targetThreat['locNames'] = ln;
                                        targetThreat['route'] = ln.join(' → ');
                                      }
                                      targetThreat['hasPendingTarget'] = false;
                                    }
                                    if (isExitOblastKeyword) {
                                      targetThreat['isExitingOblast'] = true;
                                      targetThreat['ttl'] = 45;
                                      if (targetThreat['route'] != null && !targetThreat['route'].toString().contains('(Вихід з області)')) {
                                        targetThreat['route'] = '${targetThreat['route']} (Вихід з області)';
                                      }
                                    }
                                    if (isCirclingKeyword) {
                                      targetThreat['isCircling'] = true;
                                    }
                                    if (speed != null) {
                                      targetThreat['speed'] = speed.toDouble();
                                      if (speed >= 350.0 && targetThreat['type'] == 'shahed') {
                                        targetThreat['type'] = 'shahed_jet';
                                        targetThreat['label'] = 'Реактивний БпЛА';
                                      }
                                    }
                                    if (alt != null) {
                                      final prevAlt = targetThreat['altitudeMeters'] as int?;
                                      if ((prevAlt != null && prevAlt - alt >= 300) || alt <= 1500 || isDescKeyword) {
                                        targetThreat['isDescending'] = true;
                                      }
                                      targetThreat['altitudeMeters'] = alt;
                                      targetThreat['altitude'] = '$alt м';

                                      // Якщо targetThreat мав помилковий тип 'missile_ballistic', змінюємо на БпЛА зі швидкістю 185 або 480
                                      if (targetThreat['type'] == 'missile_ballistic') {
                                        if (alt < 2000) {
                                          targetThreat['type'] = 'shahed';
                                          targetThreat['label'] = 'Шахед / БпЛА';
                                          targetThreat['speed'] = 185.0;
                                        } else {
                                          targetThreat['type'] = 'shahed_jet';
                                          targetThreat['label'] = 'Реактивний БпЛА';
                                          targetThreat['speed'] = 550.0;
                                        }
                                      } else if (targetThreat['type'] == 'shahed_jet') {
                                        // НІКОЛИ не понижувати вже встановлений тип shahed_jet назад до shahed, коли висота падає нижче 2000 м
                                        targetThreat['isDescending'] = true;
                                        targetThreat['speed'] = math.max((targetThreat['speed'] as num?)?.toDouble() ?? 550.0, 550.0);
                                      } else if (alt >= 2000 && targetThreat['type'] == 'shahed') {
                                        targetThreat['type'] = 'shahed_jet';
                                        targetThreat['label'] = 'Реактивний БпЛА';
                                        targetThreat['speed'] = 550.0;
                                      }
                                    } else if (isDescKeyword) {
                                      targetThreat['isDescending'] = true;
                                    }
                                    targetThreat['lastUpdated'] = msgTime;
                                      final msgPostId = normPost(msg['postId'] ?? msg['post_id']);
                                      if (msgPostId != null) {
                                        targetThreat['lastPostId'] = msgPostId;
                                        final histPostsSet = (targetThreat['historyPostIds'] as Set<dynamic>? ?? <dynamic>{});
                                        histPostsSet.add(msgPostId);
                                        for (final mp in mergedPostIds) {
                                          histPostsSet.add(mp);
                                        }
                                        targetThreat['historyPostIds'] = histPostsSet;
                                      }
                                      if (msg['id'] != null) {
                                        targetThreat['msgId'] = msg['id'];
                                        final histMsgs = (targetThreat['historyMsgIds'] as Set<dynamic>? ?? <dynamic>{});
                                        histMsgs.add(msg['id']);
                                        for (final mid in mergedMsgIds) {
                                          histMsgs.add(mid);
                                        }
                                        targetThreat['historyMsgIds'] = histMsgs;
                                      }
                                    }
                                  }
                                }
                            }

                            // Залишаємо активні цілі за Smart TTL (балістика 120с, КР 180с, шахед/реактивний шахед 300с або до кінця маршруту, інші БпЛА 1320с, вихід з області 45с) та щойно збиті цілі (35с для показу зеленої картки збиття)
                            // Шахеди без фіксації довше часу життя прибираються з мапи та лічильника, а на місці втрати фіксації ставиться знак питання
                            lostTracks = [];
                            threats = threats.where((t) {
                              if (t['isDestroyed'] == true) {
                                final destroyedAt = (t['destroyedAt'] as DateTime?) ?? (t['lastUpdated'] as DateTime?) ?? now;
                                return now.difference(destroyedAt).inSeconds.abs() <= 35;
                              }
                              final lastUpd = t['lastUpdated'] as DateTime?;
                              if (lastUpd == null) return true;
                              final int lifetime = getThreatLifetimeSeconds(t);
                              final int elapsed = now.difference(lastUpd).inSeconds;
                              if (elapsed <= lifetime) return true;

                              final String typeStr = (t['type'] ?? '').toString();
                              if (isLostTrackableType(typeStr) && t['isExitingOblast'] != true && elapsed - lifetime <= kLostTrackRetentionSec) {
                                final lostPath = t['path'] as List<LatLng>?;
                                if (lostPath != null && lostPath.isNotEmpty) {
                                  lostTracks.add({
                                    'point': lostPath.last,
                                    'lostAt': lastUpd.add(Duration(seconds: lifetime)),
                                    'type': typeStr,
                                    'msgId': t['msgId'],
                                  });
                                }
                              }
                              return false;
                            }).toList();

                            // Якщо ціль щойно з'явилась (1 точка) і не кружляє на місці — будуємо вектор підльоту,
                            // щоб одразу було видно напрямок руху до населеного пункту
                            for (var t in threats) {
                              final path = t['path'] as List<LatLng>;
                              final txt = (t['text'] ?? '').toString().toLowerCase();
                              final rawType = (t['type'] ?? '').toString();

                              if (t['isDestroyed'] != true && path.length == 1 && t['isCircling'] != true) {
                                final targetPt = path.first;
                                double dLat = 0.0;
                                double dLon = 0.0;
                                bool shouldBuildVector = false;

                                if (rawType == 'missile_hypersonic') {
                                  // Кинджал / гіперзвук: завжди з північно-східного ракетонебезпечного напрямку РФ (~130 км)
                                  dLat = 0.85;
                                  dLon = 1.35;
                                  shouldBuildVector = true;
                                } else if (rawType == 'missile_ballistic' || rawType == 'missile_supersonic') {
                                  // Балістика: південь (Крим/Чауда) чи північний схід (Брянськ/Курськ)
                                  if (txt.contains('крим') || txt.contains('чауд') || txt.contains('півд')) {
                                    dLat = -1.10;
                                    dLon = 0.15;
                                  } else {
                                    dLat = 0.95;
                                    dLon = 0.55;
                                  }
                                  shouldBuildVector = true;
                                } else if (rawType == 'missile_cruise') {
                                  // Крилата ракета з 1 точкою
                                  dLat = 0.55;
                                  dLon = 0.75;
                                  shouldBuildVector = true;
                                } else if (!txt.contains('кружляє') && !txt.contains('крутить') && !txt.contains('біля') && !txt.contains('над ') && !txt.contains('район')) {
                                  // Звичайний БпЛА (~6 км)
                                  if (txt.contains('з півночі') || txt.contains('на південь')) {
                                    dLat = 0.05;
                                  } else if (txt.contains('з півдня') || txt.contains('на північ')) {
                                    dLat = -0.05;
                                  } else if (txt.contains('зі сходу') || txt.contains('на захід')) {
                                    dLon = 0.07;
                                  } else if (txt.contains('з заходу') || txt.contains('на схід')) {
                                    dLon = -0.07;
                                  } else {
                                    final vLat = targetPt.latitude - kyivCenter.latitude;
                                    final vLon = targetPt.longitude - kyivCenter.longitude;
                                    final norm = math.sqrt(vLat * vLat + vLon * vLon);
                                    if (norm > 0.02) {
                                      dLat = (vLat / norm) * 0.045;
                                      dLon = (vLon / norm) * 0.065;
                                    } else {
                                      dLat = 0.035;
                                      dLon = 0.055;
                                    }
                                  }
                                  shouldBuildVector = true;
                                }

                                if (shouldBuildVector && (dLat != 0.0 || dLon != 0.0)) {
                                  final startPt = LatLng(targetPt.latitude + dLat, targetPt.longitude + dLon);
                                  path.insert(0, startPt);
                                  t['waypoints'] = List<LatLng>.from(path);
                                }
                              }
                            }
                          }

                          // Звіряємо цілі з радара https://map.ukrainealarm.com/ (м. Київ та Київська область)
                          // із нашими Telegram-каналами щодо корегування маршруту, зникнення та збиття
                          if (!isTestMode && !_isReplayMode && ukraineAlarmTargets.isNotEmpty) {
                            const distance = Distance();
                            for (final ua in ukraineAlarmTargets) {
                              final String trackId = (ua['trackId'] ?? '').toString();
                              final LatLng? uaPt = ua['point'] as LatLng?;
                              if (trackId.isEmpty || uaPt == null) continue;

                              final DateTime uaLastMoved = (ua['lastMovedAt'] as DateTime?) ?? now;
                              final DateTime? uaDisappearedAt = ua['disappearedAt'] as DateTime?;
                              final String uaType = (ua['type'] ?? 'shahed').toString();
                              final String uaLabel = (ua['label'] ?? 'Шахед / БпЛА').toString();
                              final double uaSpeed = (ua['speed'] as num?)?.toDouble() ?? 185.0;
                              final double? uaHeading = (ua['heading'] as num?)?.toDouble();
                              final LatLng? uaPredictedPt = ua['predictedPt'] as LatLng?;
                              final bool uaIsExiting = ua['isExitingOblast'] == true;

                              if (!_isPointInKyivOblastOrCity(uaPt, headingDeg: uaHeading) && !uaIsExiting) {
                                continue;
                              }

                              // 1. Звірка зникнення та збиття за повідомленнями в Telegram-каналах:
                              // а) Якщо в каналах оголошено "область чисто / відбій" або "Київ чисто" після останнього руху цілі
                              if (lastFullOblastClearTime != null &&
                                  lastFullOblastClearTime.isAfter(uaLastMoved.subtract(const Duration(seconds: 40)))) {
                                continue;
                              }
                              if (_isPointInKyivCity(uaPt) &&
                                  lastKyivCityClearTime != null &&
                                  lastKyivCityClearTime.isAfter(uaLastMoved.subtract(const Duration(seconds: 40)))) {
                                continue;
                              }

                              // б) Якщо в каналах повідомлено про збиття ("мінус", "збито", "впав", "нема його") поблизу
                              DateTime? matchedDestroyTime;
                              for (final ev in explicitDestroyedEvents) {
                                if (ev.time.isAfter(uaLastMoved.subtract(const Duration(seconds: 45)))) {
                                  if (ev.point != null) {
                                    if (distance.as(LengthUnit.Meter, ev.point!, uaPt) <= 15000.0) {
                                      matchedDestroyTime = ev.time;
                                      break;
                                    }
                                  } else if (now.difference(ev.time).inSeconds.abs() <= 90 && threats.every((t) => t['isDestroyed'] == true)) {
                                    matchedDestroyTime = ev.time;
                                    break;
                                  }
                                }
                              }
                              if (matchedDestroyTime != null) {
                                if (now.difference(matchedDestroyTime).inSeconds.abs() <= 35 && uaDisappearedAt == null) {
                                  final String uaNearest = (ua['nearestName'] ?? _findNearestKyivSettlementName(uaPt)).toString();
                                  threats.add({
                                    'type': uaType,
                                    'label': uaLabel,
                                    'locNames': <String>[uaNearest],
                                    'route': uaNearest,
                                    'isExitingOblast': false,
                                    'ttl': 35,
                                    'speed': uaSpeed,
                                    'path': <LatLng>[uaPt],
                                    'waypoints': <LatLng>[uaPt],
                                    'hasPendingTarget': false,
                                    'lastUpdated': matchedDestroyTime,
                                    'destroyedAt': matchedDestroyTime,
                                    'isDestroyed': true,
                                    'staggerDelay': 0.0,
                                    'text': '$uaLabel $uaNearest збито'.toLowerCase(),
                                    'rawText': '💥 Ціль збито ($uaNearest)',
                                    'msgId': 'ua_destroyed_$trackId',
                                    'historyMsgIds': <dynamic>{'ua_destroyed_$trackId'},
                                    'channel': 'UkraineAlarm Radar 📡',
                                    'uaTrackId': trackId,
                                  });
                                }
                                continue;
                              }

                              // в) Якщо в каналах повідомлено "локаційно чисто / втрачено / без фіксації" в радіусі <= 14 км
                              final bool isLocallyClearedByTg = recentlyClearedLocations.any((clr) =>
                                  clr.time.isAfter(uaLastMoved.subtract(const Duration(seconds: 30))) &&
                                  distance.as(LengthUnit.Meter, clr.point, uaPt) <= 14000.0);
                              if (isLocallyClearedByTg) {
                                continue;
                              }

                              final int uaTtl = getThreatTtlSeconds(uaType, isExitingOblast: uaIsExiting);
                              final int elapsedSinceMoved = now.difference(uaLastMoved).inSeconds;

                              // 2. Обробка зникнення цілі з радара map.ukrainealarm.com (або відсутності руху > 5 хв для шахедів):
                              if (uaDisappearedAt != null || elapsedSinceMoved > uaTtl) {
                                final DateTime effectiveLostTime = uaDisappearedAt ?? uaLastMoved.add(Duration(seconds: uaTtl));
                                final int sinceLostSec = now.difference(effectiveLostTime).inSeconds;
                                if (isLostTrackableType(uaType) &&
                                    !uaIsExiting &&
                                    sinceLostSec >= 0 &&
                                    sinceLostSec <= kLostTrackRetentionSec) {
                                  final double spdMs = uaSpeed * (1000.0 / 3600.0);
                                  final double recoveryRadiusM = kLostTrackBaseRadiusMeters + spdMs * sinceLostSec;

                                  // Перевіряємо, чи наші Telegram-канали продовжили маршрут цієї цілі в межах радіуса пошуку
                                  final bool continuedByTelegram = threats.any((tg) {
                                    if (tg['isDestroyed'] == true) return false;
                                    final tgPath = (tg['path'] as List<LatLng>?) ?? const [];
                                    if (tgPath.isEmpty) return false;
                                    return distance.as(LengthUnit.Meter, uaPt, tgPath.last) <= math.max(recoveryRadiusM, 16000.0);
                                  });

                                  if (!continuedByTelegram) {
                                    final bool alreadyInLost = lostTracks.any((lt) =>
                                        distance.as(LengthUnit.Meter, lt['point'] as LatLng, uaPt) <= 2500.0);
                                    if (!alreadyInLost) {
                                      lostTracks.add({
                                        'point': uaPt,
                                        'lostAt': effectiveLostTime,
                                        'type': uaType,
                                        'msgId': 'ua_$trackId',
                                      });
                                    }
                                  }
                                }
                                continue;
                              }

                              // 3. Звірка та корегування маршруту з активними цілями з Telegram-каналів:
                              final bool uaIsMissile = uaType.contains('missile') || uaType == 'kab';
                              Map<String, dynamic>? matchedTgThreat;
                              double bestMatchDist = double.infinity;

                              for (final tg in threats) {
                                if (tg['isDestroyed'] == true || tg['uaTrackId'] != null) continue;
                                final String tgType = (tg['type'] ?? 'shahed').toString();
                                final bool tgIsMissile = tgType.contains('missile') || tgType == 'kab';
                                if (uaIsMissile != tgIsMissile) continue;

                                final List<LatLng> tgPath = (tg['path'] as List<LatLng>?) ?? const [];
                                if (tgPath.isEmpty) continue;
                                final List<LatLng> tgWaypoints = (tg['waypoints'] as List<LatLng>?) ?? tgPath;

                                double d = distance.as(LengthUnit.Meter, uaPt, tgPath.last);
                                if (tgPath.length >= 2) {
                                  d = math.min(d, distance.as(LengthUnit.Meter, uaPt, tgPath.first));
                                }
                                if (tgWaypoints.length >= 2) {
                                  d = math.min(
                                    d,
                                    distance.as(LengthUnit.Meter, uaPt, tgWaypoints[tgWaypoints.length - 2]),
                                  );
                                }

                                final double maxMergeDist = (uaIsMissile || uaType == 'shahed_jet' || tgType == 'shahed_jet')
                                    ? 42000.0
                                    : 22000.0;
                                if (d <= maxMergeDist && d < bestMatchDist) {
                                  bestMatchDist = d;
                                  matchedTgThreat = tg;
                                }
                              }

                              // Якщо ціль відновила фіксацію всередині уявного кола втраченої цілі ('?') — відновлюємо її та прибираємо '?'
                              lostTracks.removeWhere((lt) {
                                final LatLng ltPt = lt['point'] as LatLng;
                                final DateTime ltTime = (lt['lostAt'] as DateTime?) ?? now;
                                final double sinceLostSec = now.difference(ltTime).inSeconds.clamp(0, kLostTrackRetentionSec).toDouble();
                                final double spdMs = uaSpeed * (1000.0 / 3600.0);
                                final double radiusM = kLostTrackBaseRadiusMeters + spdMs * sinceLostSec;
                                return distance.as(LengthUnit.Meter, ltPt, uaPt) <= radiusM;
                              });

                              final String uaNearestName = (ua['nearestName'] ?? _findNearestKyivSettlementName(uaPt)).toString();

                              if (matchedTgThreat != null) {
                                matchedTgThreat['uaTrackId'] = trackId;
                                final DateTime tgTime = (matchedTgThreat['lastUpdated'] as DateTime?) ?? now;
                                final List<LatLng> tgPath = List<LatLng>.from((matchedTgThreat['path'] as List<LatLng>?) ?? const []);
                                final List<LatLng> tgWaypoints = List<LatLng>.from((matchedTgThreat['waypoints'] as List<LatLng>?) ?? tgPath);
                                final List<String> tgLocNames = List<String>.from((matchedTgThreat['locNames'] as List<String>?) ?? const []);

                                final bool tgHasNewerCourseVector = (matchedTgThreat['hasPendingTarget'] == true ||
                                        tgTime.isAfter(uaLastMoved.subtract(const Duration(seconds: 25)))) &&
                                    tgPath.isNotEmpty &&
                                    distance.as(LengthUnit.Meter, uaPt, tgPath.last) >= 1200.0;

                                if (tgHasNewerCourseVector) {
                                  // Корегування маршруту: точна поточна координата береться з радара UkraineAlarm (uaPt),
                                  // а цільовий напрямок руху — зі свіжого повідомлення моніторингового каналу (tgPath.last)
                                  matchedTgThreat['path'] = <LatLng>[uaPt, tgPath.last];
                                  if (tgWaypoints.length >= 2) {
                                    tgWaypoints[tgWaypoints.length - 2] = uaPt;
                                  } else {
                                    tgWaypoints.insert(0, uaPt);
                                  }
                                  matchedTgThreat['waypoints'] = tgWaypoints;
                                } else {
                                  // Радар UkraineAlarm має свіжіше фактичне положення / курс: оновлюємо позицію та вектор
                                  if (uaPredictedPt != null && distance.as(LengthUnit.Meter, uaPt, uaPredictedPt) >= 600.0) {
                                    matchedTgThreat['path'] = <LatLng>[uaPt, uaPredictedPt];
                                  } else if (uaHeading != null) {
                                    final LatLng tailPt = _offsetLatLngByBearingMeters(uaPt, (uaHeading + 180.0) % 360.0, 2400.0);
                                    matchedTgThreat['path'] = <LatLng>[tailPt, uaPt];
                                  } else if (tgWaypoints.isNotEmpty && distance.as(LengthUnit.Meter, tgWaypoints.last, uaPt) >= 400.0) {
                                    tgWaypoints.add(uaPt);
                                    matchedTgThreat['path'] = <LatLng>[tgWaypoints[tgWaypoints.length - 2], tgWaypoints.last];
                                    matchedTgThreat['waypoints'] = tgWaypoints;
                                  }
                                  if (uaNearestName.isNotEmpty && (tgLocNames.isEmpty || tgLocNames.last != uaNearestName)) {
                                    tgLocNames.add(uaNearestName);
                                    matchedTgThreat['locNames'] = tgLocNames;
                                    matchedTgThreat['route'] = tgLocNames.join(' → ');
                                  }
                                }

                                if (uaLastMoved.isAfter(tgTime)) {
                                  matchedTgThreat['lastUpdated'] = uaLastMoved;
                                }
                                if (uaType == 'shahed_jet' && matchedTgThreat['type'] == 'shahed') {
                                  matchedTgThreat['type'] = 'shahed_jet';
                                  matchedTgThreat['label'] = 'Реактивний БпЛА';
                                  matchedTgThreat['speed'] = math.max((matchedTgThreat['speed'] as num?)?.toDouble() ?? 550.0, 550.0);
                                } else if ((uaType == 'uav_guided' || uaType == 'uav_recon') && matchedTgThreat['type'] == 'shahed') {
                                  matchedTgThreat['type'] = uaType;
                                  matchedTgThreat['label'] = uaLabel;
                                }
                              } else {
                                // Ціль є на радарі map.ukrainealarm.com у Київській області / Києві, але ще не описана в тексті каналів
                                List<LatLng> uaWaypoints = List<LatLng>.from((ua['waypoints'] as List<LatLng>?) ?? <LatLng>[uaPt]);
                                if (uaWaypoints.length == 1 && uaHeading != null) {
                                  uaWaypoints.insert(
                                    0,
                                    _offsetLatLngByBearingMeters(uaPt, (uaHeading + 180.0) % 360.0, 2400.0),
                                  );
                                }
                                final List<LatLng> uaActivePath = uaWaypoints.length >= 2
                                    ? <LatLng>[uaWaypoints[uaWaypoints.length - 2], uaWaypoints.last]
                                    : List<LatLng>.from(uaWaypoints);
                                final List<String> uaLocNames = List<String>.from(
                                  (ua['locNames'] as List<String>?) ?? <String>[uaNearestName],
                                );
                                String uaRoute = uaLocNames.isNotEmpty ? uaLocNames.join(' → ') : uaNearestName;
                                if (uaIsExiting && !uaRoute.contains('(Вихід з області)')) {
                                  uaRoute = '$uaRoute (Вихід з області)';
                                }

                                threats.add({
                                  'type': uaType,
                                  'label': uaLabel,
                                  'locNames': uaLocNames,
                                  'route': uaRoute,
                                  'isExitingOblast': uaIsExiting,
                                  'ttl': uaTtl,
                                  'speed': uaSpeed,
                                  'path': uaActivePath,
                                  'waypoints': uaWaypoints,
                                  'hasPendingTarget': false,
                                  'lastUpdated': uaLastMoved,
                                  'staggerDelay': 0.0,
                                  'text': '$uaLabel $uaRoute'.toLowerCase(),
                                  'rawText': '📡 Радар UkraineAlarm: $uaLabel • $uaRoute',
                                  'msgId': 'ua_$trackId',
                                  'historyMsgIds': <dynamic>{'ua_$trackId'},
                                  'channel': 'UkraineAlarm Radar 📡',
                                  'uaTrackId': trackId,
                                  'isCircling': false,
                                  'isDescending': false,
                                });
                              }
                            }
                          }

                          hasMissiles = threats.any((t) => 
                              t['type'] == 'missile_ballistic' || 
                              t['type'] == 'missile_hypersonic' || 
                              t['type'] == 'missile_supersonic' ||
                              t['type'] == 'missile_cruise' ||
                              t['type'] == 'kab'
                          );
                          
                          if (!hasMissiles) {
                            for (var msg in messages.take(30)) {
                              if (msg['date'] == null) continue;
                              try {
                                DateTime? msgTime;
                                try {
                                  msgTime = DateTime.parse(msg['date']).toUtc();
                                } catch (_) {}
                                if (msgTime == null) continue;

                                final diffMins = now.difference(msgTime).inMinutes.abs();
                                if (diffMins > 30) {
                                  break; // Захист: повідомлення старше 30 хвилин ніколи не активують статус ракетної загрози!
                                }

                                final txt = (msg['text'] ?? '').toString().toLowerCase();
                                final bool isClearMsg = msg['type'] == 'clear' ||
                                    txt.contains('відбій') ||
                                    txt.contains('чисто') ||
                                    txt.contains('знят') ||
                                    txt.contains('тихо') ||
                                    txt.contains('дорозвідка') ||
                                    txt.contains('локаційно') ||
                                    txt.contains('без фіксаці') ||
                                    txt.contains('фіксацій немає') ||
                                    txt.contains('не фіксуються') ||
                                    txt.contains('чисте небо') ||
                                    txt.contains('попередньо чисто') ||
                                    txt.contains('все походу') ||
                                    txt.contains('та все, нема') ||
                                    txt.contains('нема вже');

                                // Якщо ми знайшли повідомлення про явний відбій ракет / балістики, загроза скасована!
                                final bool isExplicitMissileClear = isClearMsg && (
                                  txt.contains('по баліст') ||
                                  txt.contains('по ракет') ||
                                  txt.contains('по кинджал') ||
                                  txt.contains('ракети чисто') ||
                                  txt.contains('балістика чисто') ||
                                  txt.contains('дорозвідка по балістиці') ||
                                  txt.contains('дорозвідка по ракетах') ||
                                  (txt.contains('відбій') && !txt.contains('бпла') && !txt.contains('шахед'))
                                );
                                if (isExplicitMissileClear) {
                                  break;
                                }

                                // Захист статусу hasMissiles від помилкового спрацьовування на відбої та реактивні БпЛА
                                const missileNegations = ['не підтверд', 'не фіксу', 'хибн', 'відбій', 'чисто', 'реактив', 'шахед', 'бпла'];
                                if (missileNegations.any((neg) => txt.contains(neg))) {
                                  continue;
                                }

                                if (txt.contains('міг') || txt.contains('mig') || txt.contains('кинджал') || txt.contains('кинжал')) {
                                  if (diffMins <= 30 && anyAlert) {
                                    hasMissiles = true;
                                    break;
                                  }
                                }

                                final bool isBallisticText = txt.contains('баліст') ||
                                    txt.contains('циркон') ||
                                    txt.contains('іскандер') ||
                                    txt.contains('х-101') ||
                                    txt.contains('онікс') ||
                                    txt.contains('крилат') ||
                                    txt.contains('ракет') ||
                                    txt.contains('сховались') ||
                                    txt.contains('в укриття') ||
                                    (txt.contains('брянськ') && txt.contains('баліст')) ||
                                    (txt.contains('курськ') && txt.contains('баліст')) ||
                                    RegExp(r'^(?:увага|ціль|пуск|виходи|швидкісна|балістика|сховались|в укриття)[!\s⚠️]*$', caseSensitive: false).hasMatch(txt.trim());

                                if (diffMins <= 12 && isBallisticText) {
                                  hasMissiles = true;
                                  break;
                                }
                              } catch (_) {}
                            }
                          }

                          _cachedTrajectorySignature = trajectorySig;
                          _cachedActiveAirDefenses = activeAirDefenses.map((a) => Map<String, dynamic>.from(a)).toList();
                          _cachedNorthThreatLabel = northThreatLabel;
                          _cachedSouthThreatLabel = southThreatLabel;
                          _cachedThreats = threats.map((t) => Map<String, dynamic>.from(t)).toList();
                          _cachedHasMissiles = hasMissiles;
                          _cachedLostTracks = lostTracks.map((l) => Map<String, dynamic>.from(l)).toList();
                        }
                          
                          final activeWatchedLocations = watchedLocations.where((l) => l.enabled).toList();
                          final Set<String> threatLocationIds = {};
                          Map<String, dynamic>? closestDangerThreat;
                          WatchedLocation? dangerLocation;
                          double closestDistMeters = double.infinity;
                          double dangerSpeedMs = 0.0;

                          if (threats.isEmpty) {
                            _alertedLocationThreatKeys.clear();
                          } else {
                            for (final loc in activeWatchedLocations) {
                              for (final t in threats) {
                                if (t['isDestroyed'] == true) continue;
                                final path = (t['path'] as List<LatLng>?) ?? [];
                                if (path.isEmpty) continue;

                                const distance = Distance();
                                final currentPt = path.last;
                                final double directDist = distance.as(LengthUnit.Meter, loc.point, currentPt);
                                final double minPathDist = _minDistanceToPointMeters(loc.point, path);

                                final speedKmh = (t['speed'] as num?)?.toDouble() ?? 500.0;
                                final speedMs = speedKmh * (1000.0 / 3600.0);

                                bool isApproaching = true;
                                double forwardDist = directDist;
                                if (path.length >= 2) {
                                  final pPrev = path[path.length - 2];
                                  final pLast = path.last;
                                  final double vx = (pLast.longitude - pPrev.longitude) * math.cos(pLast.latitude * math.pi / 180.0);
                                  final double vy = pLast.latitude - pPrev.latitude;
                                  final double tx = (loc.point.longitude - pLast.longitude) * math.cos(pLast.latitude * math.pi / 180.0);
                                  final double ty = loc.point.latitude - pLast.latitude;
                                  final double dot = vx * tx + vy * ty;
                                  isApproaching = dot > 0;

                                  final double maxConeDist = (speedMs * 150.0).clamp(2000.0, 25000.0);
                                  forwardDist = _projectedForwardDistance(loc.point, pPrev, pLast, maxConeDist);
                                }

                                final double effectiveRadius = loc.radiusMeters + (_isNightWatchMode ? 3500.0 : 0.0);
                                final bool isInRadius = directDist <= effectiveRadius || minPathDist <= effectiveRadius;
                                final bool intersectsTrajectory = isApproaching && (forwardDist <= effectiveRadius);

                                if (isInRadius || intersectsTrajectory) {
                                  threatLocationIds.add(loc.id);
                                  if (directDist < closestDistMeters) {
                                    closestDistMeters = directDist;
                                    closestDangerThreat = t;
                                    dangerLocation = loc;
                                    dangerSpeedMs = speedMs;
                                  }

                                  final threatKey = '${loc.id}:${t['msgId'] ?? t['route'] ?? t['label']}';
                                  if (!_alertedLocationThreatKeys.contains(threatKey)) {
                                    _alertedLocationThreatKeys.add(threatKey);
                                    if (_isNightWatchMode) {
                                      _triggerNightWatchAlarm();
                                    } else {
                                      HapticFeedback.heavyImpact();
                                      SystemSound.play(SystemSoundType.alert);
                                    }

                                    final double dKm = directDist / 1000.0;
                                    final double etaMins = (speedMs > 5.0 ? (directDist / speedMs / 60.0) : 0.0);
                                    VoiceAlertService.instance.announceThreatNearZone(
                                      threatKey: threatKey,
                                      threatType: t['type']?.toString() ?? 'shahed',
                                      zoneName: loc.name,
                                      distanceKm: dKm,
                                      etaMinutes: etaMins,
                                    );
                                  }
                                }
                              }
                            }
                          }

                          final activeThreats = threats.where((t) => t['isDestroyed'] != true).toList();
                          final bool isOfficialRedAlert = (kyivCityAlert && alerts['__red_м. Київ'] == true) ||
                              (kyivOblastAlert && alerts['__red_Київська область'] == true);
                          int overallStatus = 1;
                          if (isOfficialRedAlert) {
                            overallStatus = 3;
                          } else if (anyAlert) {
                            overallStatus = 2;
                          }

                          if (overallStatus == 3) {
                            final threatKey = 'ballistic_alert:${alerts['__red_м. Київ']}_${alerts['__red_Київська область']}_${activeThreats.map((t) => t['msgId']).join(',')}';
                            if (!_alertedLocationThreatKeys.contains(threatKey)) {
                              _alertedLocationThreatKeys.add(threatKey);
                              if (_isNightWatchMode) {
                                _triggerNightWatchAlarm();
                              }
                              VoiceAlertService.instance.announceBallistics();
                            }
                          }

                          final bool isWakeupBannerVisible = _isNightWatchMode &&
                              (threatLocationIds.isNotEmpty || overallStatus == 3) &&
                              (_nightWatchDismissedUntil == null || now.isAfter(_nightWatchDismissedUntil!));

                          final strategicAlert = _analyzeStrategicThreat(messages, now);
                          final launchEvent = detectStrategicLaunch(messages, now: now);
                          final bool isLaunchDismissed = _dismissedLaunchTimestamp != null &&
                              launchEvent != null &&
                              _dismissedLaunchTimestamp == launchEvent.timestamp;

                          Color statusColor = Colors.green;
                          String statusText = "Безпечно";
                          
                          if (overallStatus == 3) {
                            statusColor = Colors.redAccent;
                            statusText = "Ракетна тривога";
                          } else if (overallStatus == 2) {
                            statusColor = const Color(0xFFFFC107);
                            statusText = "Тривога (БпЛА)";
                          }

                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              _scheduleWidgetSync(alerts, activeThreats, messages);
                              LiveRadarNotificationService.instance.updateRadarStatus(
                                threats: activeThreats,
                                watchedLocations: watchedLocations,
                                isAlertKyiv: alerts['м. Київ'] == true,
                                isAlertRegion: alerts['Київська область'] == true,
                              );
                              if (isWakeupBannerVisible) {
                                _triggerNightWatchAlarm();
                              }
                            }
                          });

                          return Stack(
                            children: [
                              SizedBox.expand(
                                child: DesktopMapWrapper(
                                  mapController: _mapController,
                                  child: RepaintBoundary(
                                    key: _radarRepaintKey,
                                    child: FlutterMap(
                                      mapController: _mapController,
                                      options: MapOptions(
                                        initialCenter: const LatLng(50.4501, 30.5234),
                                        initialZoom: isWide ? 8.2 : 8.8,
                                        onTap: (tapPosition, point) {
                                          if (_selectedThreatMsgId != null) {
                                            setState(() {
                                              _selectedThreatMsgId = null;
                                            });
                                          } else {
                                            _rulerClearTimer?.cancel();
                                            setState(() {
                                              _rulerTargetPoint = point;
                                            });
                                            _rulerClearTimer = Timer(const Duration(seconds: 5), () {
                                              if (mounted) {
                                                setState(() {
                                                  _rulerTargetPoint = null;
                                                });
                                              }
                                            });
                                          }
                                        },
                                        onLongPress: (tapPosition, point) => _showAddPointFromMapDialog(context, point),
                                  interactionOptions: const InteractionOptions(
                                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate & ~InteractiveFlag.scrollWheelZoom,
                                  ),
                                  cameraConstraint: CameraConstraint.contain(
                                    bounds: LatLngBounds(
                                      LatLng(isWide ? 48.5 : 49.1, isWide ? 27.5 : 29.2),
                                      LatLng(isWide ? 52.0 : 51.4, isWide ? 33.5 : 32.2),
                                    ),
                                  ),
                                ),
                                children: [
                                  ColorFiltered(
                                    colorFilter: const ColorFilter.matrix([
                                      -0.2126, -0.7152, -0.0722, 0, 255,
                                      -0.2126, -0.7152, -0.0722, 0, 255,
                                      -0.2126, -0.7152, -0.0722, 0, 255,
                                            0,       0,       0, 1,   0,
                                    ]),
                                    child: TileLayer(
                                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                      userAgentPackageName: 'ua.kyiv.alert.monitor',
                                      tileProvider: LocalCachedTileProvider(),
                                    ),
                                  ),
                                  if (geoJsonAsync.hasValue)
                                    PolygonLayer(
                                      polygons: _buildAlertPolygons(geoJsonAsync.value!, alerts, threats, globalMissileThreat: overallStatus == 3),
                                    ),
                                  if (activeWatchedLocations.isNotEmpty)
                                    CircleLayer(
                                      circles: [
                                        ...activeWatchedLocations.map((loc) {
                                          final bool isThreat = threatLocationIds.contains(loc.id);
                                          return CircleMarker(
                                            point: loc.point,
                                            radius: loc.radiusMeters,
                                            useRadiusInMeter: true,
                                            color: isThreat
                                                ? Colors.redAccent.withValues(alpha: 0.35)
                                                : const Color(0xFF9C27B0).withValues(alpha: 0.15),
                                            borderColor: isThreat ? Colors.redAccent : const Color(0xFF9C27B0),
                                            borderStrokeWidth: isThreat ? 2.5 : 1.5,
                                          );
                                        }),
                                        if (_isNightWatchMode)
                                          ...activeWatchedLocations.map((loc) {
                                            return CircleMarker(
                                              point: loc.point,
                                              radius: loc.radiusMeters + 3500.0,
                                              useRadiusInMeter: true,
                                              color: Colors.amber.withValues(alpha: 0.05),
                                              borderColor: Colors.amberAccent.withValues(alpha: 0.6),
                                              borderStrokeWidth: 1.2,
                                            );
                                          }),
                                      ],
                                    ),
                                  if (activeWatchedLocations.isNotEmpty)
                                    MarkerLayer(
                                      markers: activeWatchedLocations.map((loc) {
                                        final bool isThreat = threatLocationIds.contains(loc.id);
                                        final color = isThreat ? Colors.redAccent : const Color(0xFF9C27B0);
                                        return Marker(
                                          point: loc.point,
                                          width: 80,
                                          height: 32,
                                          alignment: Alignment.center,
                                          child: Stack(
                                            alignment: Alignment.center,
                                            clipBehavior: Clip.none,
                                            children: [
                                              // Точка-мітка в центрі (8x8 px)
                                              Container(
                                                width: 8,
                                                height: 8,
                                                decoration: BoxDecoration(
                                                  color: color,
                                                  shape: BoxShape.circle,
                                                  border: Border.all(color: Colors.white, width: 1.5),
                                                  boxShadow: const [
                                                    BoxShadow(color: Colors.black87, blurRadius: 3, offset: Offset(0, 1)),
                                                  ],
                                                ),
                                              ),
                                              // Компактний напівпрозорий бейдж над точкою
                                              Positioned(
                                                top: -12,
                                                child: Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black.withValues(alpha: 0.8),
                                                    borderRadius: BorderRadius.circular(4),
                                                    border: Border.all(color: color.withValues(alpha: 0.8), width: 0.8),
                                                    boxShadow: const [
                                                      BoxShadow(color: Colors.black45, blurRadius: 3, offset: Offset(0, 1)),
                                                    ],
                                                  ),
                                                  child: Text(
                                                    loc.name,
                                                    maxLines: 1,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      color: color,
                                                      fontSize: 8.5,
                                                      fontWeight: FontWeight.bold,
                                                      height: 1.1,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  RepaintBoundary(
                                    child: AnimatedThreatsLayer(
                                      threats: threats,
                                      lostTracks: lostTracks,
                                      airDefenses: activeAirDefenses,
                                      selectedMsgId: _selectedThreatMsgId,
                                      onSelectThreat: (msgId) {
                                        setState(() {
                                          _selectedThreatMsgId = msgId;
                                        });
                                      },
                                      effectiveNow: (_isReplayMode || isTestMode) ? now : null,
                                    ),
                                  ),
                                  if (_rulerTargetPoint != null) ...[
                                    PolylineLayer(
                                      polylines: [
                                        Polyline(
                                          points: [
                                            (watchedLocations.where((l) => l.enabled).firstOrNull?.point ?? const LatLng(50.4501, 30.5234)),
                                            _rulerTargetPoint!,
                                          ],
                                          color: Colors.purpleAccent,
                                          strokeWidth: 2.2,
                                          pattern: StrokePattern.dashed(segments: const [6, 4]),
                                        ),
                                      ],
                                    ),
                                    CircleLayer(
                                      circles: [
                                        CircleMarker(
                                          point: _rulerTargetPoint!,
                                          radius: 5,
                                          color: Colors.purpleAccent,
                                          borderColor: Colors.white,
                                          borderStrokeWidth: 1.5,
                                        ),
                                      ],
                                    ),
                                    MarkerLayer(
                                      markers: [
                                        Marker(
                                          point: _rulerTargetPoint!,
                                          width: 360,
                                          height: 38,
                                          alignment: Alignment.topCenter,
                                          child: Builder(
                                            builder: (context) {
                                              final homeLoc = watchedLocations.where((l) => l.enabled).firstOrNull;
                                              final LatLng originPt = homeLoc?.point ?? const LatLng(50.4501, 30.5234);
                                              final String originName = homeLoc?.name ?? 'Київ';
                                              final double distMeters = const Distance().as(LengthUnit.Meter, originPt, _rulerTargetPoint!);
                                              final double distKm = distMeters / 1000.0;
                                              final int jetMin = (distKm / 550.0 * 60.0).round().clamp(1, 180);
                                              final int uavMin = (distKm / 185.0 * 60.0).round().clamp(1, 999);
                                              final int missileSec = (distMeters / 250.0).round().clamp(1, 9999);
                                              return FractionalTranslation(
                                                translation: const Offset(0.0, -1.2),
                                                child: Center(
                                                  child: Container(
                                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                                    decoration: BoxDecoration(
                                                      color: const Color(0xE625073E),
                                                      borderRadius: BorderRadius.circular(10),
                                                      border: Border.all(color: Colors.purpleAccent, width: 1.2),
                                                      boxShadow: [
                                                        BoxShadow(
                                                          color: Colors.purpleAccent.withValues(alpha: 0.5),
                                                          blurRadius: 8,
                                                          spreadRadius: 1,
                                                        ),
                                                      ],
                                                    ),
                                                    child: Text(
                                                      "📏 ${distKm.toStringAsFixed(1)} км від '$originName' • Реактив: ~$jetMin хв • БпЛА: ~$uavMin хв • Ракета: ~$missileSec с",
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 10.5,
                                                        fontWeight: FontWeight.bold,
                                                        letterSpacing: 0.2,
                                                      ),
                                                      textAlign: TextAlign.center,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                              ),
                              ),
                              ),
                              if (isWakeupBannerVisible)
                                Positioned(
                                  top: 0,
                                  left: 0,
                                  right: 0,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [Color(0xFFB71C1C), Color(0xFF6A1B9A)],
                                        begin: Alignment.centerLeft,
                                        end: Alignment.centerRight,
                                      ),
                                      border: const Border(bottom: BorderSide(color: Colors.amberAccent, width: 2)),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.redAccent.withValues(alpha: 0.6),
                                          blurRadius: 14,
                                          spreadRadius: 2,
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.bedtime, color: Colors.amberAccent, size: 24),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const Text(
                                                '🌙 НІЧНИЙ ВАРТОВИЙ: ЗАГРОЗА У ЗОНІ БЕЗПЕКИ!',
                                                style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 12.0),
                                              ),
                                              Text(
                                                overallStatus == 3
                                                    ? 'Фіксується балістична/надзвукова загроза! Терміново пройдіть в укриття!'
                                                    : (dangerLocation != null
                                                        ? 'Ціль наближається до "${dangerLocation.name}" (~${(closestDistMeters / 1000.0).toStringAsFixed(1)} км). Підліт: ${_formatEta(closestDistMeters, dangerSpeedMs)}.'
                                                        : 'Ціль зайшла в розширений нічний периметр (+3.5 км). Перейдіть у безпечне місце!'),
                                                style: const TextStyle(color: Colors.white70, fontSize: 10.5),
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        TextButton(
                                          style: TextButton.styleFrom(
                                            backgroundColor: Colors.black45,
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                            minimumSize: Size.zero,
                                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                          ),
                                          onPressed: () {
                                            setState(() {
                                              _nightWatchDismissedUntil = DateTime.now().add(const Duration(minutes: 5));
                                            });
                                          },
                                          child: const Text('Відкласти (5хв)', style: TextStyle(color: Colors.yellowAccent, fontSize: 10.5, fontWeight: FontWeight.bold)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              Positioned(
                                top: isWakeupBannerVisible ? 60 : 16,
                                left: 16,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8.5),
                                  decoration: BoxDecoration(
                                    color: const Color(0xEB0E1420),
                                    borderRadius: BorderRadius.circular(22),
                                    border: Border.all(color: statusColor.withValues(alpha: 0.65), width: 1.2),
                                    boxShadow: [
                                      BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 10, offset: const Offset(0, 3)),
                                      BoxShadow(color: statusColor.withValues(alpha: 0.25), blurRadius: 10, spreadRadius: 1),
                                    ],
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          color: statusColor,
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(color: statusColor, blurRadius: 7, spreadRadius: 1.5)
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 9),
                                      Text(
                                        statusText,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 13,
                                          letterSpacing: 0.2,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (closestDangerThreat != null && dangerLocation != null)
                                Positioned(
                                  top: isWakeupBannerVisible ? 104 : 60,
                                  left: 16,
                                  right: 16,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xE5B71C1C),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: Colors.redAccent, width: 1.5),
                                      boxShadow: const [
                                        BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 3)),
                                      ],
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.warning_amber_rounded, color: Colors.yellowAccent, size: 26),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            '⚠️ ЗАГРОЗА БІЛЯ "${dangerLocation.name.toUpperCase()}" (~${(closestDistMeters / 1000.0).toStringAsFixed(1)} км) | Підліт: ${_formatEta(closestDistMeters, dangerSpeedMs)} | ${_formatThreatType(closestDangerThreat['type'].toString())}${closestDangerThreat['isDescending'] == true ? ' (ЗНИЖУЄТЬСЯ!)' : ''}',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 12.0,
                                              height: 1.25,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        InkWell(
                                          onTap: () {
                                            _animatedMapMove(dangerLocation!.point, 13.0);
                                          },
                                          borderRadius: BorderRadius.circular(20),
                                          child: Container(
                                            padding: const EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                              color: Colors.black38,
                                              borderRadius: BorderRadius.circular(20),
                                              border: Border.all(color: Colors.white30, width: 0.5),
                                            ),
                                            child: const Icon(Icons.my_location, color: Colors.white, size: 20),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              if (anyAlert && northThreatLabel != null) ...[
                                Builder(
                                  builder: (context) {
                                    final bool isNorthUav = northThreatLabel!.contains('БПЛА');
                                    final Color accentCol = isNorthUav ? Colors.orangeAccent : Colors.redAccent;
                                    final Color bgCol = isNorthUav ? const Color(0xE67A3800) : const Color(0xE67F0000);
                                    return Stack(
                                      children: [
                                        Positioned(
                                          top: 0,
                                          left: 0,
                                          right: 0,
                                          height: 48,
                                          child: IgnorePointer(
                                            child: Container(
                                              decoration: BoxDecoration(
                                                gradient: LinearGradient(
                                                  begin: Alignment.topCenter,
                                                  end: Alignment.bottomCenter,
                                                  colors: [
                                                    accentCol.withValues(alpha: 0.35),
                                                    Colors.transparent,
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          top: (isWakeupBannerVisible ? 104 : 60) + (closestDangerThreat != null && dangerLocation != null ? 52 : 0),
                                          left: 16,
                                          right: 16,
                                          child: Center(
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                              decoration: BoxDecoration(
                                                color: bgCol,
                                                borderRadius: BorderRadius.circular(16),
                                                border: Border.all(color: accentCol, width: 1.5),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: accentCol.withValues(alpha: 0.5),
                                                    blurRadius: 10,
                                                    spreadRadius: 2,
                                                  )
                                                ],
                                              ),
                                              child: Text(
                                                northThreatLabel,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w900,
                                                  letterSpacing: 0.3,
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ],
                              if (launchEvent != null && !isLaunchDismissed)
                                Positioned(
                                  top: (isWakeupBannerVisible ? 104 : 60) +
                                      (closestDangerThreat != null && dangerLocation != null ? 52 : 0) +
                                      (anyAlert && northThreatLabel != null ? 36 : 0),
                                  left: 16,
                                  right: 16,
                                  child: Center(
                                    child: _buildStrategicLaunchBanner(launchEvent, now),
                                  ),
                                )
                              else if (strategicAlert != null)
                                Positioned(
                                  top: (isWakeupBannerVisible ? 104 : 60) +
                                      (closestDangerThreat != null && dangerLocation != null ? 52 : 0) +
                                      (anyAlert && northThreatLabel != null ? 36 : 0),
                                  left: 16,
                                  right: 16,
                                  child: Center(
                                    child: _buildStrategicAviationChip(strategicAlert),
                                  ),
                                ),
                              if (anyAlert && southThreatLabel != null) ...[
                                Builder(
                                  builder: (context) {
                                    final bool isSouthUav = southThreatLabel!.contains('БПЛА');
                                    final Color accentCol = isSouthUav ? Colors.orangeAccent : Colors.redAccent;
                                    final Color bgCol = isSouthUav ? const Color(0xE67A3800) : const Color(0xE67F0000);
                                    return Stack(
                                      children: [
                                        Positioned(
                                          bottom: 0,
                                          left: 0,
                                          right: 0,
                                          height: 48,
                                          child: IgnorePointer(
                                            child: Container(
                                              decoration: BoxDecoration(
                                                gradient: LinearGradient(
                                                  begin: Alignment.bottomCenter,
                                                  end: Alignment.topCenter,
                                                  colors: [
                                                    accentCol.withValues(alpha: 0.35),
                                                    Colors.transparent,
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          bottom: _selectedThreatMsgId != null ? 190 : (_isReplayMode ? 140 : 60),
                                          left: 16,
                                          right: 16,
                                          child: Center(
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                              decoration: BoxDecoration(
                                                color: bgCol,
                                                borderRadius: BorderRadius.circular(16),
                                                border: Border.all(color: accentCol, width: 1.5),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: accentCol.withValues(alpha: 0.5),
                                                    blurRadius: 10,
                                                    spreadRadius: 2,
                                                  )
                                                ],
                                              ),
                                              child: Text(
                                                southThreatLabel,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w900,
                                                  letterSpacing: 0.3,
                                                ),
                                                textAlign: TextAlign.center,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ],
                              if (threats.any((t) => t['isDestroyed'] != true))
                                Positioned(
                                  top: isWakeupBannerVisible ? 60 : 16,
                                  right: 16,
                                  child: GestureDetector(
                                    onTap: () {
                                      showModalBottomSheet(
                                        context: context,
                                        backgroundColor: const Color(0xFF1E1E1E),
                                        shape: const RoundedRectangleBorder(
                                          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                                        ),
                                        builder: (ctx) {
                                          return Padding(
                                            padding: const EdgeInsets.all(16.0),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: Colors.grey.shade600, borderRadius: BorderRadius.circular(2))),
                                                const Text('Активні цілі на радарі (останні 5 хв)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                                                const SizedBox(height: 12),
                                                ...threats.where((t) => t['isDestroyed'] != true).map((t) {
                                                  final typeStr = t['type'].toString();
                                                  final isMissile = typeStr.contains('missile');
                                                  final isJet = typeStr == 'shahed_jet';
                                                  final color = isMissile ? Colors.redAccent : (isJet ? Colors.deepOrangeAccent : Colors.white70);
                                                  final isCircling = t['isCircling'] == true;
                                                  final alt = t['altitude'] as String?;
                                                  final altStr = alt != null ? '\nВисота: $alt' : '';
                                                  final circlingStr = isCircling ? ' [Кружляє]' : '';
                                                  return ListTile(
                                                    dense: true,
                                                    leading: Container(
                                                      width: 36,
                                                      height: 36,
                                                      padding: const EdgeInsets.all(6),
                                                      decoration: BoxDecoration(
                                                        color: color.withValues(alpha: 0.15),
                                                        shape: BoxShape.circle,
                                                      ),
                                                      child: _buildThreatAssetIcon(typeStr, size: 22.0),
                                                    ),
                                                    title: Text('${t['label']}$circlingStr', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                                    subtitle: Text('Курс: ${t['route']}\nШвидкість: ~${(t['speed'] as num).toInt()} км/год$altStr', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                                    trailing: IconButton(
                                                      icon: const Icon(Icons.copy_rounded, color: Colors.cyanAccent, size: 20),
                                                      tooltip: 'Скопіювати зведення для рідних',
                                                      onPressed: () {
                                                        _copyThreatSummary(context, t, activeWatchedLocations);
                                                      },
                                                    ),
                                                    isThreeLine: true,
                                                  );
                                                }),
                                                const SizedBox(height: 8),
                                              ],
                                            ),
                                          );
                                        }
                                      );
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8.5),
                                      decoration: BoxDecoration(
                                        color: const Color(0xEB1A0F14),
                                        borderRadius: BorderRadius.circular(22),
                                        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.8), width: 1.2),
                                        boxShadow: [
                                          BoxShadow(color: Colors.black.withValues(alpha: 0.55), blurRadius: 10, offset: const Offset(0, 3)),
                                          BoxShadow(color: Colors.redAccent.withValues(alpha: 0.28), blurRadius: 10, spreadRadius: 1),
                                        ],
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.radar_rounded, color: Colors.redAccent, size: 19),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Активні цілі: ${threats.where((t) => t['isDestroyed'] != true).length}',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w800,
                                              fontSize: 13,
                                              letterSpacing: 0.2,
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          const Icon(Icons.keyboard_arrow_down_rounded, color: Colors.white70, size: 18),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              if (_isReplayMode)
                                Positioned(
                                  bottom: 70,
                                  left: 16,
                                  right: 16,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xF2121824),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.6), width: 1.2),
                                      boxShadow: const [
                                        BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 4))
                                      ],
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Row(
                                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                          children: [
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                IconButton(
                                                  icon: Icon(
                                                    _isReplayPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                                                    color: Colors.cyanAccent,
                                                    size: 30,
                                                  ),
                                                  tooltip: _isReplayPlaying ? 'Пауза' : 'Відтворити',
                                                  onPressed: _toggleReplayPlay,
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  _getReplayTimeLabel(),
                                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                                ),
                                              ],
                                            ),
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                TextButton.icon(
                                                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                                                  icon: const Icon(Icons.fiber_manual_record, color: Colors.redAccent, size: 10),
                                                  label: const Text('Наживо', style: TextStyle(color: Colors.white70, fontSize: 12)),
                                                  onPressed: () {
                                                    setState(() {
                                                      _replayOffsetMinutes = 0.0;
                                                      _stopReplayTimer();
                                                    });
                                                  },
                                                ),
                                                IconButton(
                                                  icon: const Icon(Icons.close, color: Colors.grey, size: 20),
                                                  tooltip: 'Закрити повтор',
                                                  onPressed: () {
                                                    setState(() {
                                                      _isReplayMode = false;
                                                      _replayOffsetMinutes = 0.0;
                                                      _stopReplayTimer();
                                                    });
                                                  },
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                        SliderTheme(
                                          data: SliderTheme.of(context).copyWith(
                                            trackHeight: 3,
                                            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                                            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                            activeTrackColor: Colors.cyanAccent,
                                            thumbColor: Colors.cyanAccent,
                                            inactiveTrackColor: Colors.grey.shade700,
                                          ),
                                          child: Slider(
                                            value: _replayOffsetMinutes,
                                            min: -30.0,
                                            max: 0.0,
                                            divisions: 60,
                                            onChanged: (val) {
                                              setState(() {
                                                _replayOffsetMinutes = val;
                                              });
                                            },
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              Positioned(
                                bottom: 16,
                                left: 16,
                                child: ActionChip(
                                  avatar: Icon(
                                    _isReplayMode ? Icons.replay : Icons.history,
                                    color: _isReplayMode ? Colors.cyanAccent : Colors.white70,
                                    size: 18,
                                  ),
                                  label: Text(
                                    _isReplayMode ? 'Історія увімкнена' : '⏪ Історія (30 хв)',
                                    style: TextStyle(
                                      color: _isReplayMode ? Colors.cyanAccent : Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                  backgroundColor: _isReplayMode ? const Color(0xFF0A323A) : const Color(0xEB111724),
                                  side: BorderSide(
                                    color: _isReplayMode ? Colors.cyanAccent : const Color(0xFF2B3750),
                                    width: 1.1,
                                  ),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                  onPressed: () {
                                    setState(() {
                                      _isReplayMode = !_isReplayMode;
                                      if (!_isReplayMode) {
                                        _replayOffsetMinutes = 0.0;
                                        _stopReplayTimer();
                                      } else {
                                        _replayOffsetMinutes = -15.0;
                                      }
                                    });
                                  },
                                ),
                              ),
                              Positioned(
                                bottom: 16,
                                right: 16,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (isWide) ...[
                                      Container(
                                        decoration: BoxDecoration(
                                          color: const Color(0xEB111724),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: const Color(0xFF2B3750), width: 1.0),
                                          boxShadow: const [
                                            BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 3)),
                                          ],
                                        ),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            InkWell(
                                              borderRadius: const BorderRadius.vertical(top: Radius.circular(11)),
                                              onTap: () {
                                                final cam = _mapController.camera;
                                                _animatedMapMove(cam.center, (cam.zoom + 0.7).clamp(5.0, 18.0));
                                              },
                                              child: const Padding(
                                                padding: EdgeInsets.all(9.0),
                                                child: Icon(Icons.add_rounded, color: Colors.white, size: 20),
                                              ),
                                            ),
                                            Container(width: 22, height: 1, color: const Color(0xFF28334A)),
                                            InkWell(
                                              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(11)),
                                              onTap: () {
                                                final cam = _mapController.camera;
                                                _animatedMapMove(cam.center, (cam.zoom - 0.7).clamp(5.0, 18.0));
                                              },
                                              child: const Padding(
                                                padding: EdgeInsets.all(9.0),
                                                child: Icon(Icons.remove_rounded, color: Colors.white, size: 20),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                    ],
                                    FloatingActionButton.small(
                                      backgroundColor: const Color(0xEB111724),
                                      foregroundColor: Colors.cyanAccent,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        side: const BorderSide(color: Color(0xFF2B3750), width: 1.0),
                                      ),
                                      tooltip: _isSmartFocusActive
                                          ? 'Огляд Київщини'
                                          : (threats.isNotEmpty && watchedLocations.any((l) => l.enabled)
                                              ? 'Фокус: Загроза - Дім'
                                              : 'Центрувати на Київ'),
                                      onPressed: () {
                                        final activeHome = watchedLocations.where((l) => l.enabled).firstOrNull;
                                        if (!_isSmartFocusActive && threats.isNotEmpty && activeHome != null) {
                                          double minDistance = double.infinity;
                                          LatLng? closestPt;

                                          for (final t in threats) {
                                            final pts = (t['path'] as List<LatLng>?) ?? [];
                                            final pt = pts.isNotEmpty ? pts.last : null;
                                            if (pt != null) {
                                              final dist = const Distance().as(LengthUnit.Meter, activeHome.point, pt);
                                              if (dist < minDistance) {
                                                minDistance = dist;
                                                closestPt = pt;
                                              }
                                            }
                                          }

                                          if (closestPt != null) {
                                            final midLat = (activeHome.point.latitude + closestPt.latitude) / 2.0;
                                            final midLon = (activeHome.point.longitude + closestPt.longitude) / 2.0;
                                            _animatedMapMove(LatLng(midLat, midLon), 9.8);
                                            setState(() {
                                              _isSmartFocusActive = true;
                                            });
                                            return;
                                          }
                                        }

                                        _animatedMapMove(const LatLng(50.4501, 30.5234), isWide ? 8.2 : 8.8);
                                        setState(() {
                                          _isSmartFocusActive = false;
                                        });
                                      },
                                      child: Icon(
                                        _isSmartFocusActive ? Icons.zoom_out_map : Icons.my_location,
                                        size: 20,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (_selectedThreatMsgId != null)
                                Builder(
                                  builder: (context) {
                                    final inspectedThreat = threats.cast<Map<String, dynamic>?>().firstWhere(
                                      (t) => t?['msgId'] == _selectedThreatMsgId,
                                      orElse: () => null,
                                    );
                                    if (inspectedThreat == null) return const SizedBox.shrink();

                                    final int updSecAgo = inspectedThreat['lastUpdated'] != null
                                        ? now.difference(inspectedThreat['lastUpdated'] as DateTime).inSeconds.abs()
                                        : 0;
                                    final String timeAgoStr = '${updSecAgo ~/ 60} хв ${updSecAgo % 60} с тому';

                                    final pathPts = (inspectedThreat['path'] as List<LatLng>?) ?? [];
                                    final curPt = pathPts.isNotEmpty ? pathPts.last : const LatLng(50.4501, 30.5234);
                                    final distParts = watchedLocations.where((l) => l.enabled).map((loc) {
                                      final dKm = (const Distance().as(LengthUnit.Meter, loc.point, curPt) / 1000.0).toStringAsFixed(1);
                                      return '${loc.name}: $dKm км';
                                    }).toList();
                                    final String distStr = distParts.isNotEmpty ? distParts.join(' • ') : '';

                                    final String postText = (inspectedThreat['rawText'] ?? inspectedThreat['text'] ?? '').toString();

                                    return Positioned(
                                      bottom: _isReplayMode ? 140 : 66,
                                      left: 12,
                                      right: 12,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () {},
                                        child: Container(
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: const Color(0xF51A1A1A),
                                            borderRadius: BorderRadius.circular(14),
                                            border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.8), width: 1.2),
                                            boxShadow: const [
                                              BoxShadow(color: Colors.black87, blurRadius: 10, offset: Offset(0, 4))
                                            ],
                                          ),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Container(
                                                    width: 28,
                                                    height: 28,
                                                    padding: const EdgeInsets.all(4),
                                                    decoration: BoxDecoration(
                                                      color: Colors.black45,
                                                      shape: BoxShape.circle,
                                                      border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.6), width: 1),
                                                    ),
                                                    child: _buildThreatAssetIcon(inspectedThreat['type'].toString(), size: 18.0),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(
                                                      inspectedThreat['label'] ?? _formatThreatType(inspectedThreat['type'].toString()),
                                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                  InkWell(
                                                    onTap: () {
                                                      _copyThreatSummary(context, inspectedThreat, activeWatchedLocations);
                                                    },
                                                    borderRadius: BorderRadius.circular(16),
                                                    child: const Padding(
                                                      padding: EdgeInsets.symmetric(horizontal: 6.0, vertical: 4.0),
                                                      child: Row(
                                                        mainAxisSize: MainAxisSize.min,
                                                        children: [
                                                          Icon(Icons.copy_rounded, color: Colors.cyanAccent, size: 15),
                                                          SizedBox(width: 4),
                                                          Text('Поділитися', style: TextStyle(color: Colors.cyanAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 4),
                                                  InkWell(
                                                    onTap: () {
                                                      setState(() {
                                                        _selectedThreatMsgId = null;
                                                      });
                                                    },
                                                    borderRadius: BorderRadius.circular(16),
                                                    child: const Padding(
                                                      padding: EdgeInsets.all(4.0),
                                                      child: Icon(Icons.close, color: Colors.grey, size: 18),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Text('🧭 ${inspectedThreat['route']}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                                              const SizedBox(height: 4),
                                              Wrap(
                                                spacing: 12,
                                                runSpacing: 4,
                                                children: [
                                                  Text('⚡ ~${(inspectedThreat['speed'] as num?)?.toInt() ?? 185} км/год', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                                                  Text('📏 ${inspectedThreat['altitude'] ?? (inspectedThreat['altitudeMeters'] != null ? '${inspectedThreat['altitudeMeters']} м' : 'Висота не вказана')}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
                                                  Text('⏱️ $timeAgoStr', style: const TextStyle(color: Colors.amberAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                                                ],
                                              ),
                                              if (distStr.isNotEmpty) ...[
                                                const SizedBox(height: 4),
                                                Text('📍 Відстань: $distStr', style: const TextStyle(color: Colors.cyanAccent, fontSize: 11)),
                                              ],
                                              if (postText.isNotEmpty) ...[
                                                const SizedBox(height: 6),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                                  decoration: BoxDecoration(
                                                    color: Colors.black45,
                                                    borderRadius: BorderRadius.circular(6),
                                                    border: Border.all(color: Colors.white12, width: 0.5),
                                                  ),
                                                  child: Text(
                                                    postText,
                                                    style: const TextStyle(color: Colors.white70, fontSize: 10.5, fontStyle: FontStyle.italic),
                                                    maxLines: 2,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                            ],
                          );
                        }
                      ),
                    ),
                  ),
                );
                final filteredMessages = messages.where((msg) {
                  if (_feedFilter == 'threats') {
                    return msg['type'] == 'danger' || msg['type'] == 'alert';
                  } else if (_feedFilter == 'defenseClear') {
                    final t = (msg['text'] ?? '').toString().toLowerCase();
                    return msg['type'] == 'clear' ||
                        t.contains('ппо') ||
                        t.contains('робота ппо') ||
                        t.contains('збиття') ||
                        t.contains('збито') ||
                        t.contains('відбій') ||
                        t.contains('ліквідовано') ||
                        t.contains('знищено');
                  }
                  return true;
                }).toList();

                final listWidget = Expanded(
                  flex: isWide ? 3 : 8,
                  child: Container(
                    margin: isWide
                        ? const EdgeInsets.fromLTRB(6.0, 12.0, 12.0, 12.0)
                        : EdgeInsets.zero,
                    decoration: isWide
                        ? BoxDecoration(
                            color: const Color(0xFF101520),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFF212B3F), width: 1.2),
                            boxShadow: const [
                              BoxShadow(color: Colors.black54, blurRadius: 14, offset: Offset(0, 6)),
                            ],
                          )
                        : null,
                    child: GestureDetector(
                      behavior: HitTestBehavior.translucent,
                      onTap: () {
                        if (_selectedThreatMsgId != null) {
                          setState(() {
                            _selectedThreatMsgId = null;
                          });
                        }
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (isWide)
                            Container(
                              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                              decoration: const BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(color: Color(0xFF1E273A), width: 1),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.rss_feed_rounded, color: Colors.cyanAccent, size: 17),
                                  const SizedBox(width: 8),
                                  const Expanded(
                                    child: Text(
                                      'ОПЕРАТИВНА СТРІЧКА',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 0.7,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1A2336),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: const Color(0xFF2B3954), width: 0.8),
                                    ),
                                    child: Text(
                                      '${filteredMessages.length}',
                                      style: const TextStyle(
                                        color: Colors.cyanAccent,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  _buildFeedFilterChip(
                                    label: 'Усі (${messages.length})',
                                    filterKey: 'all',
                                    activeColor: Colors.blueAccent,
                                  ),
                                  const SizedBox(width: 8),
                                  _buildFeedFilterChip(
                                    label: '🚨 Цілі на радарі',
                                    filterKey: 'threats',
                                    activeColor: Colors.redAccent,
                                  ),
                                  const SizedBox(width: 8),
                                  _buildFeedFilterChip(
                                    label: '🛡️ ППО / Відбої',
                                    filterKey: 'defenseClear',
                                    activeColor: Colors.cyanAccent,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            child: filteredMessages.isEmpty
                                ? Center(
                                    child: Text(
                                      _feedFilter == 'all' ? 'Немає нових повідомлень' : 'Немає повідомлень за цим фільтром',
                                      style: const TextStyle(color: Colors.grey),
                                    ),
                                  )
                                : ListView.builder(
                                    padding: const EdgeInsets.fromLTRB(12.0, 2.0, 12.0, 12.0),
                                    itemCount: filteredMessages.length,
                                    itemBuilder: (context, index) {
                                      final msg = filteredMessages[index];

                                      IconData iconData = Icons.info_outline_rounded;
                                      Color iconColor = Colors.blueAccent;

                                      if (msg['type'] == 'danger') {
                                        iconData = Icons.warning_amber_rounded;
                                        iconColor = Colors.redAccent;
                                      } else if (msg['type'] == 'alert') {
                                        iconData = Icons.notifications_active_rounded;
                                        iconColor = Colors.orangeAccent;
                                      } else if (msg['type'] == 'clear') {
                                        iconData = Icons.check_circle_outline_rounded;
                                        iconColor = Colors.greenAccent;
                                      } else if (msg['type'] == 'news') {
                                        iconData = Icons.article_outlined;
                                        iconColor = Colors.blueGrey.shade300;
                                      }

                                      String timeStr = '';
                                      if (msg['date'] != null) {
                                        try {
                                          final utc = DateTime.parse(msg['date']).toUtc();
                                          bool isSummerTime = false;
                                          if (utc.month > 3 && utc.month < 10) {
                                            isSummerTime = true;
                                          } else if (utc.month == 3) {
                                            final lastSundayDay = 31 - (DateTime.utc(utc.year, 3, 31).weekday % 7);
                                            if (utc.day >= lastSundayDay) isSummerTime = true;
                                          } else if (utc.month == 10) {
                                            final lastSundayDay = 31 - (DateTime.utc(utc.year, 10, 31).weekday % 7);
                                            if (utc.day < lastSundayDay) isSummerTime = true;
                                          }
                                          final kyivTime = utc.add(Duration(hours: isSummerTime ? 3 : 2));
                                          final hhMm = '${kyivTime.hour.toString().padLeft(2, '0')}:${kyivTime.minute.toString().padLeft(2, '0')}';

                                          final nowKyiv = DateTime.now().toUtc().add(Duration(hours: isSummerTime ? 3 : 2));
                                          final diff = nowKyiv.difference(kyivTime);

                                          final bool isDifferentDay = nowKyiv.year != kyivTime.year || nowKyiv.month != kyivTime.month || nowKyiv.day != kyivTime.day;
                                          final bool isYesterday = isDifferentDay && (DateTime(nowKyiv.year, nowKyiv.month, nowKyiv.day).difference(DateTime(kyivTime.year, kyivTime.month, kyivTime.day)).inDays == 1);

                                          if (isYesterday) {
                                            timeStr = 'Вчора, $hhMm';
                                          } else if (isDifferentDay) {
                                            timeStr = '${kyivTime.day.toString().padLeft(2, '0')}.${kyivTime.month.toString().padLeft(2, '0')}, $hhMm';
                                          } else if (diff.inHours >= 3) {
                                            timeStr = 'Сьогодні, $hhMm';
                                          } else {
                                            timeStr = hhMm;
                                          }
                                        } catch (_) {}
                                      }

                                      final bool isSelected = _selectedThreatMsgId != null && _selectedThreatMsgId == msg['id'];
                                      final bool hasRadarPoint = (msg['threats'] is List && (msg['threats'] as List).isNotEmpty);

                                      return Container(
                                        margin: const EdgeInsets.only(bottom: 8.5),
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? const Color(0xFF17263B)
                                              : (msg['type'] == 'danger'
                                                  ? const Color(0xFF1A1722)
                                                  : const Color(0xFF151C2A)),
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(
                                            color: isSelected
                                                ? Colors.cyanAccent
                                                : (msg['type'] == 'danger'
                                                    ? Colors.redAccent.withValues(alpha: 0.28)
                                                    : const Color(0xFF222C42)),
                                            width: isSelected ? 1.4 : 1.0,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withValues(alpha: 0.25),
                                              blurRadius: 6,
                                              offset: const Offset(0, 2),
                                            ),
                                          ],
                                        ),
                                        child: Material(
                                          color: Colors.transparent,
                                          child: InkWell(
                                            borderRadius: BorderRadius.circular(12),
                                            onTap: () {
                                              List<dynamic> targetThreats = (msg['threats'] as List?) ?? [];
                                              if (targetThreats.isEmpty) {
                                                targetThreats = ref.read(messagesProvider.notifier).parseLocalThreats(msg['text']?.toString() ?? '');
                                              }
                                              LatLng? targetPos;
                                              for (var th in targetThreats) {
                                                if (th['path'] is List && (th['path'] as List).isNotEmpty) {
                                                  final pItem = (th['path'] as List).last;
                                                  if (pItem is LatLng) {
                                                    targetPos = pItem;
                                                    break;
                                                  } else if (pItem is Map && pItem['lat'] != null && pItem['lon'] != null) {
                                                    targetPos = LatLng((pItem['lat'] as num).toDouble(), (pItem['lon'] as num).toDouble());
                                                    break;
                                                  }
                                                }
                                              }
                                              if (targetPos != null) {
                                                _animatedMapMove(targetPos, 10.8);
                                                setState(() {
                                                  _selectedThreatMsgId = msg['id'];
                                                });
                                              }
                                            },
                                            child: IntrinsicHeight(
                                              child: Row(
                                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                                children: [
                                                  Container(
                                                    width: 4,
                                                    decoration: BoxDecoration(
                                                      color: iconColor,
                                                      borderRadius: const BorderRadius.only(
                                                        topLeft: Radius.circular(12),
                                                        bottomLeft: Radius.circular(12),
                                                      ),
                                                    ),
                                                  ),
                                                  Expanded(
                                                    child: Padding(
                                                      padding: const EdgeInsets.fromLTRB(11, 10, 12, 10),
                                                      child: Column(
                                                        crossAxisAlignment: CrossAxisAlignment.start,
                                                        children: [
                                                          Row(
                                                            children: [
                                                              Container(
                                                                padding: const EdgeInsets.all(5),
                                                                decoration: BoxDecoration(
                                                                  color: iconColor.withValues(alpha: 0.16),
                                                                  borderRadius: BorderRadius.circular(7),
                                                                ),
                                                                child: Icon(iconData, color: iconColor, size: 15),
                                                              ),
                                                              const SizedBox(width: 7),
                                                              Expanded(
                                                                child: Text(
                                                                  msg['channel'] ?? '',
                                                                  maxLines: 1,
                                                                  overflow: TextOverflow.ellipsis,
                                                                  style: const TextStyle(
                                                                    color: Colors.white70,
                                                                    fontSize: 11.5,
                                                                    fontWeight: FontWeight.w600,
                                                                  ),
                                                                ),
                                                              ),
                                                              if (hasRadarPoint) ...[
                                                                Container(
                                                                  margin: const EdgeInsets.only(right: 6),
                                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                                  decoration: BoxDecoration(
                                                                    color: Colors.cyanAccent.withValues(alpha: 0.14),
                                                                    borderRadius: BorderRadius.circular(6),
                                                                    border: Border.all(
                                                                      color: Colors.cyanAccent.withValues(alpha: 0.4),
                                                                      width: 0.7,
                                                                    ),
                                                                  ),
                                                                  child: const Row(
                                                                    mainAxisSize: MainAxisSize.min,
                                                                    children: [
                                                                      Icon(Icons.radar_rounded, size: 11, color: Colors.cyanAccent),
                                                                      SizedBox(width: 3),
                                                                      Text(
                                                                        'Радар',
                                                                        style: TextStyle(
                                                                          color: Colors.cyanAccent,
                                                                          fontSize: 10,
                                                                          fontWeight: FontWeight.w700,
                                                                        ),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                ),
                                                              ],
                                                              Text(
                                                                timeStr,
                                                                style: TextStyle(
                                                                  color: Colors.grey.shade400,
                                                                  fontSize: 11.5,
                                                                  fontWeight: FontWeight.w700,
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                          const SizedBox(height: 7),
                                                          if (msg['reply_quoted_text'] != null && msg['reply_quoted_text'].toString().trim().isNotEmpty) ...[
                                                            Container(
                                                              margin: const EdgeInsets.only(bottom: 6.0),
                                                              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                                                              decoration: BoxDecoration(
                                                                color: Colors.purple.withValues(alpha: 0.12),
                                                                borderRadius: BorderRadius.circular(6.0),
                                                                border: const Border(
                                                                  left: BorderSide(color: Colors.purpleAccent, width: 3.0),
                                                                ),
                                                              ),
                                                              child: Row(
                                                                mainAxisSize: MainAxisSize.min,
                                                                children: [
                                                                  const Icon(Icons.reply, size: 13, color: Colors.purpleAccent),
                                                                  const SizedBox(width: 4),
                                                                  Flexible(
                                                                    child: Text(
                                                                      'У відповідь на: ${msg['reply_quoted_text']}',
                                                                      maxLines: 2,
                                                                      overflow: TextOverflow.ellipsis,
                                                                      style: const TextStyle(
                                                                        color: Colors.purpleAccent,
                                                                        fontSize: 11.5,
                                                                        fontStyle: FontStyle.italic,
                                                                        fontWeight: FontWeight.w500,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                          ] else if (msg['reply_to_post_id'] != null) ...[
                                                            Container(
                                                              margin: const EdgeInsets.only(bottom: 6.0),
                                                              padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                                                              decoration: BoxDecoration(
                                                                color: Colors.purple.withValues(alpha: 0.12),
                                                                borderRadius: BorderRadius.circular(6.0),
                                                                border: const Border(
                                                                  left: BorderSide(color: Colors.purpleAccent, width: 3.0),
                                                                ),
                                                              ),
                                                              child: const Row(
                                                                mainAxisSize: MainAxisSize.min,
                                                                children: [
                                                                  Icon(Icons.reply, size: 13, color: Colors.purpleAccent),
                                                                  SizedBox(width: 4),
                                                                  Text(
                                                                    'У відповідь на попередній пост',
                                                                    style: TextStyle(
                                                                      color: Colors.purpleAccent,
                                                                      fontSize: 11.5,
                                                                      fontStyle: FontStyle.italic,
                                                                      fontWeight: FontWeight.w500,
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                          ],
                                                          Text(
                                                            msg['text'] ?? '',
                                                            style: const TextStyle(
                                                              fontSize: 13.8,
                                                              height: 1.36,
                                                              color: Color(0xFFEDF0F7),
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
                return isWide ? Row(children: [mapWidget, listWidget]) : Column(children: [mapWidget, listWidget]);
              }
            ),
          ),
        ],
      ),
      if (_isSettingsMenuOpen)
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _closeSettingsMenu,
            child: Container(
              color: Colors.black.withValues(alpha: 0.2),
            ),
          ),
        ),
      Positioned(
        top: 6,
        right: 8,
        child: SizeTransition(
          sizeFactor: _settingsAnimation,
          alignment: Alignment.topCenter,
          child: FadeTransition(
            opacity: _settingsAnimation,
            child: _buildSettingsDropdownMenu(context, isTestMode, watchedLocations, remoteConfig),
          ),
        ),
      ),
    ],
  ),
);
  }

  Widget _buildSettingsDropdownMenu(
    BuildContext context,
    bool isTestMode,
    List<WatchedLocation> watchedLocations,
    RemoteConfig remoteConfig,
  ) {
    final bool hasUpdate = remoteConfig.versionCode > kCurrentVersionCode && remoteConfig.apkUrl.isNotEmpty;
    final isVoiceEnabled = VoiceAlertService.instance.isEnabled;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: 255,
        decoration: BoxDecoration(
          color: const Color(0xF71C1D26),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.65),
              blurRadius: 20,
              spreadRadius: 2,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(
                children: [
                  const Icon(Icons.tune_rounded, size: 16, color: Colors.cyanAccent),
                  const SizedBox(width: 8),
                  Text(
                    'НАЛАШТУВАННЯ',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.0,
                      color: Colors.white.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.1)),
            _buildDropdownItem(
              icon: Icons.edit_location_alt_outlined,
              iconColor: Colors.purpleAccent,
              title: 'Мої зони безпеки',
              subtitle: '${watchedLocations.length} зон під наглядом',
              onTap: () {
                _closeSettingsMenu();
                _showWatchedLocationsSheet(context);
              },
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
            _buildDropdownItem(
              icon: isVoiceEnabled ? Icons.record_voice_over : Icons.voice_over_off,
              iconColor: isVoiceEnabled ? Colors.cyanAccent : Colors.grey,
              title: 'Голосовий диктор',
              subtitle: isVoiceEnabled ? 'Озвучення увімкнено' : 'Вимкнено',
              trailing: Transform.scale(
                scale: 0.75,
                child: Switch.adaptive(
                  value: isVoiceEnabled,
                  activeThumbColor: Colors.cyanAccent,
                  onChanged: (val) async {
                    await VoiceAlertService.instance.setEnabled(val);
                    if (!mounted) return;
                    setState(() {});
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          val
                              ? '🔊 Голосовий диктор увімкнено! Сповіщення озвучуватимуться українською.'
                              : '🔇 Голосовий диктор вимкнено.',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        duration: const Duration(seconds: 2),
                        backgroundColor: val ? const Color(0xFF004D40) : const Color(0xFF2C2C34),
                      ),
                    );
                  },
                ),
              ),
              onTap: () async {
                final newVal = !isVoiceEnabled;
                await VoiceAlertService.instance.setEnabled(newVal);
                if (!mounted) return;
                setState(() {});
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      newVal
                          ? '🔊 Голосовий диктор увімкнено! Сповіщення озвучуватимуться українською.'
                          : '🔇 Голосовий диктор вимкнено.',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                    ),
                    duration: const Duration(seconds: 2),
                    backgroundColor: newVal ? const Color(0xFF004D40) : const Color(0xFF2C2C34),
                  ),
                );
              },
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
            _buildDropdownItem(
              icon: Icons.system_update_alt_rounded,
              iconColor: hasUpdate ? Colors.orangeAccent : Colors.cyanAccent,
              title: 'Перевірити оновлення',
              subtitle: hasUpdate ? 'Доступна нова версія!' : 'Поточна v$kCurrentVersionName',
              trailing: hasUpdate
                  ? Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Colors.orangeAccent,
                        shape: BoxShape.circle,
                      ),
                    )
                  : null,
              onTap: () {
                _closeSettingsMenu();
                _manualCheckForUpdates(context);
              },
            ),
            Divider(height: 1, color: Colors.white.withValues(alpha: 0.06)),
            _buildDropdownItem(
              icon: isTestMode ? Icons.bug_report : Icons.bug_report_outlined,
              iconColor: isTestMode ? Colors.greenAccent : Colors.grey,
              title: 'Тестовий режим',
              subtitle: isTestMode ? 'Активний (емуляція)' : 'Вимкнено',
              trailing: Transform.scale(
                scale: 0.75,
                child: Switch.adaptive(
                  value: isTestMode,
                  activeThumbColor: Colors.greenAccent,
                  onChanged: (val) {
                    ref.read(testModeProvider.notifier).toggle();
                    _staticTestModeTime = DateTime.now().toUtc().toIso8601String();
                  },
                ),
              ),
              onTap: () {
                ref.read(testModeProvider.notifier).toggle();
                _staticTestModeTime = DateTime.now().toUtc().toIso8601String();
              },
            ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _buildDropdownItem({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: iconColor.withValues(alpha: 0.35), width: 1),
              ),
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.6),
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

Widget _buildThreatAssetIcon(String type, {double? size}) {
  final double iconSize = size ?? ((type.contains('missile') || type == 'kab') ? 20.0 : 17.0);
  if (type == 'shahed_jet') {
    return Image.asset(
      'assets/shahed_jet_hq.png',
      width: iconSize,
      height: iconSize,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  } else if (type == 'shahed') {
    return Image.asset(
      'assets/shahed_hq.png',
      width: iconSize,
      height: iconSize,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  } else if (type == 'uav_guided') {
    return ColorFiltered(
      colorFilter: const ColorFilter.mode(Colors.pinkAccent, BlendMode.srcATop),
      child: Image.asset(
        'assets/shahed_hq.png',
        width: iconSize,
        height: iconSize,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  } else if (type == 'uav_recon') {
    return ColorFiltered(
      colorFilter: const ColorFilter.mode(Colors.cyanAccent, BlendMode.srcATop),
      child: Image.asset(
        'assets/shahed_hq.png',
        width: iconSize,
        height: iconSize,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  } else if (type == 'uav_decoy') {
    return ColorFiltered(
      colorFilter: const ColorFilter.mode(Colors.blueGrey, BlendMode.srcATop),
      child: Image.asset(
        'assets/shahed_hq.png',
        width: iconSize,
        height: iconSize,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  } else if (type == 'missile_ballistic' || type == 'missile_hypersonic') {
    return Image.asset(
      'assets/missile_ballistic_hq.png',
      width: iconSize,
      height: iconSize,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  } else if (type == 'missile_supersonic') {
    return ColorFiltered(
      colorFilter: const ColorFilter.mode(Colors.deepOrange, BlendMode.srcATop),
      child: Image.asset(
        'assets/missile_cruise_hq.png',
        width: iconSize,
        height: iconSize,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  } else if (type == 'kab') {
    return ColorFiltered(
      colorFilter: const ColorFilter.mode(Colors.amber, BlendMode.srcATop),
      child: Image.asset(
        'assets/missile_cruise_hq.png',
        width: iconSize,
        height: iconSize,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.high,
      ),
    );
  } else if (type == 'missile_cruise') {
    return Image.asset(
      'assets/missile_cruise_hq.png',
      width: iconSize,
      height: iconSize,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  } else {
    return Image.asset(
      'assets/shahed_hq.png',
      width: iconSize,
      height: iconSize,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
  }
}

class AnimatedThreatsLayer extends StatefulWidget {
  final List<Map<String, dynamic>> threats;
  final List<Map<String, dynamic>> lostTracks;
  final List<Map<String, dynamic>> airDefenses;
  final dynamic selectedMsgId;
  final ValueChanged<dynamic>? onSelectThreat;
  final DateTime? effectiveNow;

  const AnimatedThreatsLayer({
    super.key,
    required this.threats,
    this.lostTracks = const [],
    this.airDefenses = const [],
    this.selectedMsgId,
    this.onSelectThreat,
    this.effectiveNow,
  });

  @override
  State<AnimatedThreatsLayer> createState() => _AnimatedThreatsLayerState();
}

class _AnimatedThreatsLayerState extends State<AnimatedThreatsLayer> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  int _lastFrameTimestampMs = 0;
  Widget? _cachedLayerWidget;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    );
    if (widget.threats.isNotEmpty || widget.airDefenses.isNotEmpty || widget.lostTracks.isNotEmpty) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(AnimatedThreatsLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _cachedLayerWidget = null;
    final hasItems = widget.threats.isNotEmpty || widget.airDefenses.isNotEmpty || widget.lostTracks.isNotEmpty;
    if (hasItems && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!hasItems && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _getTrailColor(String type) {
    switch (type) {
      case 'missile_hypersonic': return Colors.purpleAccent;
      case 'missile_ballistic': return Colors.redAccent;
      case 'missile_supersonic': return Colors.deepOrange;
      case 'missile_cruise': return Colors.orangeAccent;
      case 'kab': return Colors.amber;
      case 'uav_guided': return Colors.pinkAccent;
      case 'uav_recon': return Colors.cyanAccent;
      case 'uav_decoy': return Colors.blueGrey;
      case 'shahed_jet': return Colors.deepOrangeAccent;
      case 'shahed':
      default: return Colors.white70;
    }
  }

  List<LatLng> _generateCatmullRomSpline(List<LatLng> points, {int samplesPerSegment = 6}) {
    if (points.length < 3) return points;
    final List<LatLng> result = [];
    for (int i = 0; i < points.length - 1; i++) {
      final p0 = i == 0 ? points[0] : points[i - 1];
      final p1 = points[i];
      final p2 = points[i + 1];
      final p3 = (i + 2 < points.length) ? points[i + 2] : points[i + 1];

      for (int j = 0; j < samplesPerSegment; j++) {
        final double t = j / samplesPerSegment;
        final double t2 = t * t;
        final double t3 = t2 * t;

        final double lat = 0.5 * (
          (2.0 * p1.latitude) +
          (-p0.latitude + p2.latitude) * t +
          (2.0 * p0.latitude - 5.0 * p1.latitude + 4.0 * p2.latitude - p3.latitude) * t2 +
          (-p0.latitude + 3.0 * p1.latitude - 3.0 * p2.latitude + p3.latitude) * t3
        );
        final double lon = 0.5 * (
          (2.0 * p1.longitude) +
          (-p0.longitude + p2.longitude) * t +
          (2.0 * p0.longitude - 5.0 * p1.longitude + 4.0 * p2.longitude - p3.longitude) * t2 +
          (-p0.longitude + 3.0 * p1.longitude - 3.0 * p2.longitude + p3.longitude) * t3
        );
        result.add(LatLng(lat, lon));
      }
    }
    result.add(points.last);
    return result;
  }

  LatLng _projectLatLng(LatLng origin, double bearingRad, double distanceMeters) {
    if (distanceMeters.abs() < 0.1) return origin;
    const double earthRadius = 6378137.0;
    final double d = distanceMeters / earthRadius;
    final double lat1 = origin.latitude * math.pi / 180.0;
    final double lon1 = origin.longitude * math.pi / 180.0;
    final double lat2 = math.asin(
      math.sin(lat1) * math.cos(d) + math.cos(lat1) * math.sin(d) * math.cos(bearingRad),
    );
    final double lon2 = lon1 + math.atan2(
      math.sin(bearingRad) * math.sin(d) * math.cos(lat1),
      math.cos(d) - math.sin(lat1) * math.sin(lat2),
    );
    return LatLng(lat2 * 180.0 / math.pi, lon2 * 180.0 / math.pi);
  }

  (LatLng, double, double) _interpolateCatmullRomLeg(
    LatLng p0,
    LatLng p1,
    LatLng p2,
    LatLng p3,
    double t,
  ) {
    const double iconRotationOffset = math.pi / 4;
    final double tc = t.clamp(0.0, 1.0);
    final double t2 = tc * tc;
    final double t3 = t2 * tc;

    final double lat = 0.5 * (
      (2.0 * p1.latitude) +
      (-p0.latitude + p2.latitude) * tc +
      (2.0 * p0.latitude - 5.0 * p1.latitude + 4.0 * p2.latitude - p3.latitude) * t2 +
      (-p0.latitude + 3.0 * p1.latitude - 3.0 * p2.latitude + p3.latitude) * t3
    );
    final double lon = 0.5 * (
      (2.0 * p1.longitude) +
      (-p0.longitude + p2.longitude) * tc +
      (2.0 * p0.longitude - 5.0 * p1.longitude + 4.0 * p2.longitude - p3.longitude) * t2 +
      (-p0.longitude + 3.0 * p1.longitude - 3.0 * p2.longitude + p3.longitude) * t3
    );

    final double dLatDt = 0.5 * (
      (-p0.latitude + p2.latitude) +
      2.0 * (2.0 * p0.latitude - 5.0 * p1.latitude + 4.0 * p2.latitude - p3.latitude) * tc +
      3.0 * (-p0.latitude + 3.0 * p1.latitude - 3.0 * p2.latitude + p3.latitude) * t2
    );
    final double dLonDt = 0.5 * (
      (-p0.longitude + p2.longitude) +
      2.0 * (2.0 * p0.longitude - 5.0 * p1.longitude + 4.0 * p2.longitude - p3.longitude) * tc +
      3.0 * (-p0.longitude + 3.0 * p1.longitude - 3.0 * p2.longitude + p3.longitude) * t2
    );

    final pos = LatLng(lat, lon);
    final double dyScreen = -dLatDt;
    final double dxCorrected = math.cos(math.pi / 180.0 * lat) * dLonDt;
    if (dyScreen.abs() > 1e-7 || dxCorrected.abs() > 1e-7) {
      final double rotRad = math.atan2(dyScreen, dxCorrected) + iconRotationOffset;
      final double bearingRad = math.atan2(dxCorrected, dLatDt);
      return (pos, rotRad, bearingRad);
    }
    final fallback = _interpolatePosAndAngle([p1, p2], tc);
    return (pos, fallback.$2, _calculateBearing(p1, p2));
  }

  String _compassDirectionFromBearing(double bearingRad) {
    final double deg = ((bearingRad * 180.0 / math.pi) % 360.0 + 360.0) % 360.0;
    const dirs = ['Пн', 'Пн-Сх', 'Сх', 'Пд-Сх', 'Пд', 'Пд-Зх', 'Зх', 'Пн-Зх'];
    final int idx = ((deg + 22.5) / 45.0).floor() % 8;
    return dirs[idx];
  }

  @override
  Widget build(BuildContext context) {
    if (widget.threats.isEmpty && widget.airDefenses.isEmpty && widget.lostTracks.isEmpty) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final effectiveNow = widget.effectiveNow ?? DateTime.now().toUtc();

        // 3-рівневий адаптивний FPS:
        // 60 мс (~16.6 FPS) — ППО, радарний пінг нової цілі (< 12с), хвиля збиття, стрімке зниження, ракети/реактиви або виділена ціль
        // 100 мс (10 FPS) — активний політ по маршруту або кружляння на орбіті
        // 300 мс (~3.3 FPS) — енергоощадний інерційний режим під час тривалих тривог
        final bool hasUrgentAnimation = widget.airDefenses.isNotEmpty ||
            widget.selectedMsgId != null ||
            widget.threats.any((t) {
              if (t['isDestroyed'] == true) return true;
              final msgTime = (t['lastUpdated'] as DateTime?) ?? effectiveNow;
              final elapsed = effectiveNow.difference(msgTime).inSeconds;
              if (elapsed >= -5 && elapsed <= 12) return true;
              final typeStr = (t['type'] ?? '').toString();
              return t['isDescending'] == true ||
                  typeStr.contains('missile') ||
                  typeStr == 'kab' ||
                  typeStr == 'shahed_jet';
            });
        final bool hasActiveFlight = !hasUrgentAnimation &&
            widget.threats.any((t) {
              if (t['isDestroyed'] == true) return false;
              if (t['isCircling'] == true) return true;
              final msgTime = (t['lastUpdated'] as DateTime?) ?? effectiveNow;
              return effectiveNow.difference(msgTime).inSeconds < 160;
            });
        final int throttleIntervalMs = hasUrgentAnimation ? 60 : (hasActiveFlight ? 100 : 300);
        if (_cachedLayerWidget != null && (nowMs - _lastFrameTimestampMs) < throttleIntervalMs) {
          return _cachedLayerWidget!;
        }
        _lastFrameTimestampMs = nowMs;

        List<Polygon> forecastPolygons = [];
        List<Marker> markers = [];
        List<Polyline> polylines = [];
        List<CircleMarker> targetCircles = [];

        // 1. Попередній розрахунок кінематичних координат, кутів та миттєвої швидкості
        final Map<int, LatLng> activePositions = {};
        final Map<int, double> activeRotations = {};
        final Map<int, double> activeElapsedSecs = {};
        final Map<int, double> activeEffectiveElapsedSecs = {};
        final Map<int, double> activeSpeedMs = {};
        final Map<int, double> activeGeoBearings = {};
        final Map<int, double> activeFractions = {};
        final Map<int, bool> activeInOrbit = {};

        for (var i = 0; i < widget.threats.length; i++) {
          final t = widget.threats[i];
          final path = t['path'] as List<LatLng>;
          if (path.isEmpty) continue;
          final bool isDestroyed = t['isDestroyed'] == true;
          final msgTime = (t['lastUpdated'] as DateTime?) ?? effectiveNow;
          final rawElapsedSec = effectiveNow.difference(msgTime).inMilliseconds / 1000.0;
          final elapsedSec = rawElapsedSec < 0.0 ? 0.0 : rawElapsedSec;
          final staggerDelay = (t['staggerDelay'] as num?)?.toDouble() ?? 0.0;
          final effectiveElapsedSec = elapsedSec - staggerDelay;

          if (isDestroyed) {
            activePositions[i] = path.last;
            activeRotations[i] = 0.0;
            activeElapsedSecs[i] = elapsedSec;
            activeEffectiveElapsedSecs[i] = effectiveElapsedSec;
            activeSpeedMs[i] = 0.0;
            activeGeoBearings[i] = 0.0;
            activeFractions[i] = 1.0;
            activeInOrbit[i] = false;
            continue;
          }

          final typeStr = (t['type'] ?? '').toString();
          final int threatTtl = getThreatLifetimeSeconds(t);
          if (elapsedSec > threatTtl) continue;

          final speedKmh = (t['speed'] as num?)?.toDouble() ?? 500.0;
          final baseSpeedMs = speedKmh * (1000.0 / 3600.0);
          double currentInstantSpeedMs = baseSpeedMs;

          final waypoints = (t['waypoints'] as List<LatLng>?) ?? path;
          final activeLeg = path.length >= 2 ? [path[path.length - 2], path.last] : path;
          double legDistance = 0;
          if (activeLeg.length >= 2) {
            legDistance = const Distance().as(LengthUnit.Meter, activeLeg[0], activeLeg[1]);
          }
          final realTravelSec = activeLeg.length == 1 ? 0.0 : (legDistance / baseSpeedMs);

          LatLng currentPos;
          double rotationAngle;
          double geoBearing = 0.0;
          if (path.length >= 2) {
            geoBearing = _calculateBearing(path[path.length - 2], path.last);
          }

          final bool isMissile = typeStr.contains('missile') || typeStr == 'kab';
          final bool isCircling = t['isCircling'] == true;
          final int msgIdHash = (t['msgId'] is int) ? (t['msgId'] as int) : t['msgId'].hashCode;
          final double targetPhaseOffset = ((i * 1.6180339) + (msgIdHash.abs() % 17) * 0.37) % (2.0 * math.pi);
          final bool orbitClockwise = (i + msgIdHash.abs()) % 2 == 0;

          double fraction = 0.0;
          bool inOrbit = false;

          if (isCircling) {
            // Десинхронізована орбіта кружляння для уникнення накладання кількох цілей в одній точці
            final double radiusScale = 0.85 + ((i % 3) * 0.14);
            final circleRes = _calculateCirclingPosAndAngle(
              path.last,
              elapsedSec.clamp(0.0, 3600.0),
              phaseOffset: targetPhaseOffset,
              radiusScale: radiusScale,
              clockwise: orbitClockwise,
            );
            currentPos = circleRes.$1;
            rotationAngle = circleRes.$2;
            geoBearing = (math.pi / 2.0) - (rotationAngle - math.pi / 4.0);
            fraction = 1.0;
            inOrbit = true;
          } else if (path.length == 1 && !isMissile) {
            // Одиночна локація без вектора (напр. "БпЛА над Броварами" або "в районі Обухова"):
            // плавне патрулювання над вказаним районом замість "мертвої" статичної іконки
            final circleRes = _calculateCirclingPosAndAngle(
              path.first,
              elapsedSec.clamp(0.0, 3600.0),
              phaseOffset: targetPhaseOffset,
              radiusScale: 0.45,
              clockwise: orbitClockwise,
            );
            currentPos = circleRes.$1;
            rotationAngle = circleRes.$2;
            geoBearing = (math.pi / 2.0) - (rotationAngle - math.pi / 4.0);
            fraction = 1.0;
            inOrbit = true;
          } else {
            if (realTravelSec > 0) {
              if (effectiveElapsedSec > 0) {
                fraction = effectiveElapsedSec / realTravelSec;
              }
            } else {
              fraction = 1.0;
            }

            if (fraction < 1.0 && waypoints.length >= 3) {
              // Плавне проходження поворотів по кривій Catmull-Rom для маршрутів із >= 3 точками
              final p0 = waypoints[waypoints.length - 3];
              final p1 = waypoints[waypoints.length - 2];
              final p2 = waypoints.last;
              final p3 = waypoints.last;
              final splineRes = _interpolateCatmullRomLeg(p0, p1, p2, p3, fraction);
              currentPos = splineRes.$1;
              rotationAngle = splineRes.$2;
              geoBearing = splineRes.$3;
            } else {
              final interpRes = _interpolatePosAndAngle(activeLeg, fraction.clamp(0.0, 1.0));
              currentPos = interpRes.$1;
              rotationAngle = interpRes.$2;
            }

            // Експоненційна інерційна екстраполяція після досягнення кінцевої точки маршруту
            if (fraction >= 1.0 && path.length >= 2) {
              final double extraTimeSec = (effectiveElapsedSec - realTravelSec).clamp(0.0, 300.0);
              if (extraTimeSec > 0) {
                final bool isLastPtKyiv = (path.last.latitude - 50.450).abs() < 0.05 &&
                    (path.last.longitude - 30.523).abs() < 0.05;
                // Часова стала загасання швидкості tau (сек) та ліміт інерційного вибігу
                final double tau = isMissile ? 75.0 : (isLastPtKyiv ? 55.0 : 135.0);
                final double maxExtraMeters = isMissile ? 18000.0 : (isLastPtKyiv ? 2800.0 : 9500.0);
                final double decayFactor = math.exp(-extraTimeSec / tau);
                currentInstantSpeedMs = baseSpeedMs * decayFactor.clamp(0.25, 1.0);
                final double extraDistMeters = (baseSpeedMs * tau * (1.0 - decayFactor)).clamp(0.0, maxExtraMeters);

                final LatLng coastedPos = _projectLatLng(path.last, geoBearing, extraDistMeters);

                // Якщо БпЛА тривалий час не отримує нових точок або дійшов до центру Києва —
                // плавно переходить у мікро-орбіту баражування в районі виходу
                final double loiterThresholdSec = isLastPtKyiv ? 35.0 : 115.0;
                if (!isMissile && extraTimeSec > loiterThresholdSec) {
                  final double loiterTime = extraTimeSec - loiterThresholdSec;
                  final double blend = (loiterTime / 20.0).clamp(0.0, 1.0);
                  final circleRes = _calculateCirclingPosAndAngle(
                    coastedPos,
                    loiterTime,
                    phaseOffset: geoBearing,
                    radiusScale: 0.35 * blend,
                    clockwise: orbitClockwise,
                  );
                  currentPos = circleRes.$1;
                  rotationAngle = circleRes.$2;
                  geoBearing = (math.pi / 2.0) - (rotationAngle - math.pi / 4.0);
                  inOrbit = blend > 0.6;
                } else {
                  currentPos = coastedPos;
                }
              }
            }
          }

          activePositions[i] = currentPos;
          activeRotations[i] = rotationAngle;
          activeElapsedSecs[i] = elapsedSec;
          activeEffectiveElapsedSecs[i] = effectiveElapsedSec;
          activeSpeedMs[i] = currentInstantSpeedMs;
          activeGeoBearings[i] = geoBearing;
          activeFractions[i] = fraction;
          activeInOrbit[i] = inOrbit;
        }

        // 2. Кластеризація рою: якщо в радіусі 1.5 км рухається група з >= 3 однотипних цілей
        final Map<int, int> leadClusterBadges = {};
        final Set<int> clusteredIndices = {};

        for (var i in activePositions.keys) {
          if (clusteredIndices.contains(i)) continue;
          final tI = widget.threats[i];
          if (tI['isDestroyed'] == true) continue;
          final posI = activePositions[i]!;
          final typeI = tI['type'].toString();

          final List<int> group = [i];
          for (var j in activePositions.keys) {
            if (i == j) continue;
            final tJ = widget.threats[j];
            if (tJ['isDestroyed'] == true) continue;
            if (tJ['type'].toString() != typeI) continue;
            final posJ = activePositions[j]!;
            final dMeters = const Distance().as(LengthUnit.Meter, posI, posJ);
            if (dMeters <= 1500.0) {
              group.add(j);
            }
          }

          if (group.length >= 3) {
            group.sort();
            leadClusterBadges[group.first] = group.length;
            clusteredIndices.addAll(group);
          }
        }

        // 3. Анімовані концентричні кола роботи ППО (протягом 90 секунд)
        if (widget.airDefenses.isNotEmpty) {
          for (var ad in widget.airDefenses) {
            final adPos = LatLng(ad['lat'], ad['lon']);
            final adTime = (ad['time'] as DateTime?) ?? effectiveNow;
            final adElapsedSec = (effectiveNow.difference(adTime).inMilliseconds / 1000.0).clamp(0.0, 90.0);
            if (adElapsedSec > 90.0) continue;

            final double pulse1 = (_controller.value * 2.0) % 1.0;
            final double pulse2 = (_controller.value * 2.0 + 0.5) % 1.0;

            targetCircles.add(
              CircleMarker(
                point: adPos,
                radius: 12.0 + pulse1 * 32.0,
                color: Colors.cyanAccent.withValues(alpha: (1.0 - pulse1) * 0.35),
                borderColor: Colors.cyanAccent.withValues(alpha: (1.0 - pulse1) * 0.8),
                borderStrokeWidth: 1.5,
              ),
            );
            targetCircles.add(
              CircleMarker(
                point: adPos,
                radius: 12.0 + pulse2 * 32.0,
                color: Colors.blueAccent.withValues(alpha: (1.0 - pulse2) * 0.25),
                borderColor: Colors.lightBlueAccent.withValues(alpha: (1.0 - pulse2) * 0.7),
                borderStrokeWidth: 1.5,
              ),
            );

            markers.add(
              Marker(
                point: adPos,
                width: 140,
                height: 36,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xF0081220),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.cyanAccent, width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.cyanAccent.withValues(alpha: 0.6),
                          blurRadius: 8,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.shield, color: Colors.cyanAccent, size: 14),
                        const SizedBox(width: 4),
                        Text(
                          '🛡️ ППО: ${ad['name']}',
                          style: const TextStyle(
                            color: Colors.cyanAccent,
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }
        }

        // 4. Рендеринг активних цілей та тактичної візуалізації
        for (var i = 0; i < widget.threats.length; i++) {
          if (!activePositions.containsKey(i)) continue;
          final t = widget.threats[i];
          final path = t['path'] as List<LatLng>;
          final currentPos = activePositions[i]!;
          final rotationAngle = activeRotations[i]!;
          final elapsedSec = activeElapsedSecs[i]!;
          final speedMs = activeSpeedMs[i]!;
          final geoBearing = activeGeoBearings[i]!;
          final activeFraction = activeFractions[i] ?? 1.0;
          final inOrbit = activeInOrbit[i] ?? false;

          final bool isDestroyed = t['isDestroyed'] == true;
          final typeStr = t['type'].toString();
          final trailColor = _getTrailColor(typeStr);
          final bool isCircling = t['isCircling'] == true;
          final bool isDescending = t['isDescending'] == true;
          final String? altitude = t['altitude'] as String?;
          final int? altitudeMeters = t['altitudeMeters'] as int?;
          final double baseSpeedKmh = (t['speed'] as num?)?.toDouble() ?? 185.0;

          final bool isSelected = widget.selectedMsgId != null &&
              (t['msgId'] == widget.selectedMsgId ||
                  (t['historyMsgIds'] as Set?)?.contains(widget.selectedMsgId) == true);

          // Старіння контакту (Confidence Decay):
          double opacity = 1.0;
          bool isGhost = false;
          String? decayTimeTag;

          final int ttlForDecay = getThreatLifetimeSeconds(t);
          if (elapsedSec <= ttlForDecay * 0.4) {
            opacity = 1.0;
          } else if (elapsedSec <= ttlForDecay * 0.7) {
            opacity = 0.72;
            final minAgo = (elapsedSec / 60).floor();
            decayTimeTag = minAgo > 0 ? '$minAgoхв' : '${elapsedSec.round()}с';
          } else {
            opacity = 0.42;
            isGhost = true;
            final minAgo = (elapsedSec / 60).floor();
            decayTimeTag = minAgo > 0 ? '$minAgoхв' : '${elapsedSec.round()}с';
          }

          // Лінія маршруту та пройденої траєкторії (waypoints) із триступеневим загасанням шлейфу,
          // напрямними шевронами (›) вздовж відрізків та тактичними плашками поворотних орієнтирів
          final waypoints = (t['waypoints'] as List<LatLng>?) ?? path;
          final locNamesList = (t['locNames'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];
          // У звичайному режимі обмежуємо шлейф останніми 10 вузлами (щоб довгі 20-точкові петлі не захаращували карту),
          // а при виділенні (isSelected) показуємо повну історію маршруту від входу в область
          final int maxTrailNodes = isSelected ? waypoints.length : 10;
          final int wpStartOffset = waypoints.length > maxTrailNodes ? waypoints.length - maxTrailNodes : 0;
          final List<LatLng> visibleWaypoints = waypoints.sublist(wpStartOffset);

          final List<LatLng> trailRaw = visibleWaypoints.isNotEmpty
              ? (visibleWaypoints.length > 1
                  ? [...visibleWaypoints.sublist(0, visibleWaypoints.length - 1), currentPos]
                  : [currentPos])
              : (path.length > 6 ? path.sublist(path.length - 6) : path);
          final smoothPoints = _generateCatmullRomSpline(trailRaw);

          if (smoothPoints.length >= 2) {
            if (isSelected) {
              polylines.add(
                Polyline(
                  points: smoothPoints,
                  color: Colors.cyanAccent.withValues(alpha: 0.45),
                  strokeWidth: 8.0,
                ),
              );
              polylines.add(
                Polyline(
                  points: smoothPoints,
                  color: Colors.cyanAccent,
                  strokeWidth: 3.2,
                ),
              );
            } else if (isDestroyed) {
              polylines.add(
                Polyline(
                  points: smoothPoints,
                  color: Colors.greenAccent.withValues(alpha: 0.22),
                  strokeWidth: 4.5,
                ),
              );
              polylines.add(
                Polyline(
                  points: smoothPoints,
                  color: Colors.greenAccent.withValues(alpha: 0.75),
                  strokeWidth: 2.0,
                  pattern: StrokePattern.dashed(segments: const [6, 4]),
                ),
              );
            } else if (smoothPoints.length >= 9) {
              // Триступеневий тактичний шлейф:
              // 1) Давній хвіст (0..35%) — тонкий напівпрозорий пунктир
              // 2) Середній марш (35..70%) — середній штрих
              // 3) Свіжий слід за ціллю (70..100%) — яскравий неоновий ореол
              final int split1 = (smoothPoints.length * 0.35).floor().clamp(1, smoothPoints.length - 3);
              final int split2 = (smoothPoints.length * 0.70).floor().clamp(split1 + 1, smoothPoints.length - 2);
              final List<LatLng> ghostSegment = smoothPoints.sublist(0, split1 + 1);
              final List<LatLng> midSegment = smoothPoints.sublist(split1, split2 + 1);
              final List<LatLng> recentSegment = smoothPoints.sublist(split2);

              polylines.add(
                Polyline(
                  points: ghostSegment,
                  color: trailColor.withValues(alpha: 0.24 * opacity),
                  strokeWidth: 1.3,
                  pattern: StrokePattern.dashed(segments: const [3, 6]),
                ),
              );
              polylines.add(
                Polyline(
                  points: midSegment,
                  color: trailColor.withValues(alpha: 0.54 * opacity),
                  strokeWidth: 1.9,
                  pattern: StrokePattern.dashed(segments: const [5, 4]),
                ),
              );
              polylines.add(
                Polyline(
                  points: recentSegment,
                  color: trailColor.withValues(alpha: 0.25 * opacity),
                  strokeWidth: 5.2,
                ),
              );
              polylines.add(
                Polyline(
                  points: recentSegment,
                  color: trailColor.withValues(alpha: 0.94 * opacity),
                  strokeWidth: 2.4,
                  pattern: StrokePattern.dashed(segments: const [6, 4]),
                ),
              );
            } else if (smoothPoints.length >= 6) {
              final int splitIdx = (smoothPoints.length * 0.45).floor().clamp(1, smoothPoints.length - 2);
              final List<LatLng> olderSegment = smoothPoints.sublist(0, splitIdx + 1);
              final List<LatLng> recentSegment = smoothPoints.sublist(splitIdx);

              polylines.add(
                Polyline(
                  points: olderSegment,
                  color: trailColor.withValues(alpha: 0.38 * opacity),
                  strokeWidth: 1.6,
                  pattern: StrokePattern.dashed(segments: const [4, 5]),
                ),
              );
              polylines.add(
                Polyline(
                  points: recentSegment,
                  color: trailColor.withValues(alpha: 0.24 * opacity),
                  strokeWidth: 5.0,
                ),
              );
              polylines.add(
                Polyline(
                  points: recentSegment,
                  color: trailColor.withValues(alpha: 0.90 * opacity),
                  strokeWidth: 2.3,
                  pattern: StrokePattern.dashed(segments: const [6, 4]),
                ),
              );
            } else {
              polylines.add(
                Polyline(
                  points: smoothPoints,
                  color: trailColor.withValues(alpha: 0.24 * opacity),
                  strokeWidth: 5.0,
                ),
              );
              polylines.add(
                Polyline(
                  points: smoothPoints,
                  color: trailColor.withValues(alpha: 0.88 * opacity),
                  strokeWidth: 2.2,
                  pattern: StrokePattern.dashed(segments: const [6, 4]),
                ),
              );
            }
          }

          // Напрямні шеврони (›) посередині сегментів маршруту для візуального читання складних петель і розворотів
          if (!isDestroyed && trailRaw.length >= 2) {
            final int maxChevrons = isSelected ? trailRaw.length - 1 : 4;
            final int startLeg = math.max(0, (trailRaw.length - 1) - maxChevrons);
            for (int seg = startLeg; seg < trailRaw.length - 1; seg++) {
              final LatLng pA = trailRaw[seg];
              final LatLng pB = trailRaw[seg + 1];
              final double segDistM = const Distance().as(LengthUnit.Meter, pA, pB);
              if (segDistM < 1100.0) continue;
              final LatLng midPt = LatLng(
                (pA.latitude + pB.latitude) * 0.5,
                (pA.longitude + pB.longitude) * 0.5,
              );
              final double legBearing = _calculateBearing(pA, pB);
              final double barbLenM = (segDistM * 0.14).clamp(220.0, 680.0);
              const double barbAngle = 148.0 * math.pi / 180.0;
              final LatLng leftWing = _projectLatLng(midPt, legBearing + barbAngle, barbLenM);
              final LatLng rightWing = _projectLatLng(midPt, legBearing - barbAngle, barbLenM);
              final double legProgress = (seg + 1) / (trailRaw.length - 1);
              final Color chevColor = isSelected
                  ? Colors.cyanAccent.withValues(alpha: 0.92)
                  : trailColor.withValues(alpha: (0.38 + 0.50 * legProgress) * opacity);
              polylines.add(
                Polyline(
                  points: [leftWing, midPt, rightWing],
                  color: chevColor,
                  strokeWidth: isSelected ? 2.2 : 1.7,
                ),
              );
            }
          }

          // Лінія до цільової точки маршруту, поки ціль ще летить по відрізку (activeFraction < 1.0)
          if (!isDestroyed && !isCircling && activeFraction < 0.98 && path.length >= 2) {
            polylines.add(
              Polyline(
                points: [currentPos, path.last],
                color: trailColor.withValues(alpha: 0.35 * opacity),
                strokeWidth: 1.4,
                pattern: const StrokePattern.dotted(),
              ),
            );
          }

          // Вузлові точки (waypoint dots) та тактичні підписи пройдених орієнтирів (breadcrumbs)
          if (!isDestroyed && visibleWaypoints.length >= 2) {
            final bool isDenseClusterFollower = clusteredIndices.contains(i) && !leadClusterBadges.containsKey(i);
            final List<LatLng> labeledPoints = [currentPos];

            for (int w = 0; w < visibleWaypoints.length - 1; w++) {
              final double wpFade = (w + 1) / visibleWaypoints.length;
              final LatLng wpPt = visibleWaypoints[w];
              targetCircles.add(
                CircleMarker(
                  point: wpPt,
                  radius: isSelected ? 3.6 : 2.8,
                  color: isSelected
                      ? Colors.cyanAccent.withValues(alpha: 0.85)
                      : trailColor.withValues(alpha: (0.35 + 0.45 * wpFade) * opacity),
                  borderColor: Colors.black87,
                  borderStrokeWidth: 1.0,
                ),
              );

              // Визначаємо назву вузлової точки з locNamesList (вирівнюючи з кінця списку waypoints)
              final int globalWpIdx = wpStartOffset + w;
              final int nameOffset = waypoints.length - locNamesList.length;
              final int nameIdx = globalWpIdx - nameOffset;
              final bool shouldShowWpLabel = nameIdx >= 0 &&
                  nameIdx < locNamesList.length &&
                  (isSelected
                      ? (w >= visibleWaypoints.length - 7)
                      : (!isDenseClusterFollower && w == visibleWaypoints.length - 2 && elapsedSec <= 210));

              if (shouldShowWpLabel) {
                final String wpName = locNamesList[nameIdx].trim();
                final bool farEnough = wpName.isNotEmpty &&
                    labeledPoints.every((lp) => const Distance().as(LengthUnit.Meter, lp, wpPt) >= 1300.0);
                if (farEnough) {
                  labeledPoints.add(wpPt);
                  markers.add(
                    Marker(
                      point: wpPt,
                      width: 110,
                      height: 20,
                      child: Center(
                        child: Opacity(
                          opacity: (isSelected ? 0.95 : (0.72 * opacity)).clamp(0.0, 1.0),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xCC09131C),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: (isSelected ? Colors.cyanAccent : trailColor).withValues(alpha: 0.55),
                                width: 0.7,
                              ),
                            ),
                            child: Text(
                              wpName,
                              style: TextStyle(
                                color: isSelected ? Colors.cyanAccent : Colors.white.withValues(alpha: 0.88),
                                fontSize: 7.2,
                                fontWeight: FontWeight.w600,
                                height: 1.0,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                }
              }
            }

            // Підпис цільового орієнтира (path.last), якщо ціль ще летить до нього або виділена
            if (locNamesList.isNotEmpty &&
                (!isDenseClusterFollower || isSelected) &&
                (isSelected || (activeFraction < 0.88 && elapsedSec <= 180))) {
              final LatLng destPt = path.last;
              final String destName = locNamesList.last.trim();
              final bool destFarEnough = destName.isNotEmpty &&
                  labeledPoints.every((lp) => const Distance().as(LengthUnit.Meter, lp, destPt) >= 1300.0);
              if (destFarEnough) {
                markers.add(
                  Marker(
                    point: destPt,
                    width: 120,
                    height: 22,
                    child: Center(
                      child: Opacity(
                        opacity: (isSelected ? 0.98 : (0.82 * opacity)).clamp(0.0, 1.0),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.2),
                          decoration: BoxDecoration(
                            color: const Color(0xD90A1622),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: (isSelected ? Colors.cyanAccent : trailColor).withValues(alpha: 0.75),
                              width: 0.85,
                            ),
                          ),
                          child: Text(
                            '→ $destName',
                            style: TextStyle(
                              color: isSelected ? Colors.cyanAccent : trailColor,
                              fontSize: 7.5,
                              fontWeight: FontWeight.bold,
                              height: 1.0,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }
            }
          }

          // Якщо ціль збита/знищена — хвиля детонації + тактична плашка
          if (isDestroyed) {
            final destroyedAt = (t['destroyedAt'] as DateTime?) ?? (t['lastUpdated'] as DateTime?) ?? effectiveNow;
            final double destroyedElapsed = (effectiveNow.difference(destroyedAt).inMilliseconds / 1000.0).clamp(0.0, 35.0);
            final double waveFade = (1.0 - (destroyedElapsed / 35.0)).clamp(0.15, 1.0);
            final double wavePulse = (_controller.value * 2.5) % 1.0;

            targetCircles.add(
              CircleMarker(
                point: path.last,
                radius: 8.0 + wavePulse * 18.0,
                color: Colors.greenAccent.withValues(alpha: (1.0 - wavePulse) * 0.25 * waveFade),
                borderColor: Colors.greenAccent.withValues(alpha: (1.0 - wavePulse) * 0.75 * waveFade),
                borderStrokeWidth: 1.5,
              ),
            );

            markers.add(
              Marker(
                point: path.last,
                width: 220,
                height: 48,
                child: Opacity(
                  opacity: waveFade,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xE60A1E14),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.greenAccent, width: 1.2),
                          boxShadow: const [
                            BoxShadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 2))
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.shield, color: Colors.greenAccent, size: 14),
                            SizedBox(width: 4),
                            Text(
                              'Ціль знищено / втрачено',
                              style: TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 9.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Icon(Icons.check_circle_outline, color: Colors.greenAccent, size: 18),
                    ],
                  ),
                ),
              ),
            );
            continue;
          }

          // Якщо кружляє — показуємо пунктирну орбіту баражування
          if (isCircling) {
            final double radiusScale = 0.85 + ((i % 3) * 0.14);
            final orbitPoints = <LatLng>[];
            for (int s = 0; s <= 32; s++) {
              final a = (s / 32.0) * 2.0 * math.pi;
              orbitPoints.add(LatLng(
                path.last.latitude + 0.015 * radiusScale * math.sin(a),
                path.last.longitude + 0.024 * radiusScale * math.cos(a),
              ));
            }
            polylines.add(
              Polyline(
                points: orbitPoints,
                color: trailColor.withValues(alpha: 0.55 * opacity),
                strokeWidth: 1.5,
                pattern: const StrokePattern.dotted(),
              ),
            );
          }

          // Кільце в кінцевій точці маршруту
          targetCircles.add(
            CircleMarker(
              point: path.last,
              radius: isCircling ? 4 : 5.5,
              color: trailColor.withValues(alpha: 0.30 * opacity),
              borderColor: trailColor.withValues(alpha: 0.9 * opacity),
              borderStrokeWidth: 1.4,
            ),
          );

          // Вектор випередження (Velocity Leader Line) на 1 хвилину польоту вперед
          // із 30-секундною поділкою та тактичним наконечником стрілки (chevron)
          if (!isCircling && !inOrbit && path.length >= 2) {
            final double leadDistMeters = (speedMs * 60.0).clamp(500.0, 30000.0);
            final LatLng midLeadPt = _projectLatLng(currentPos, geoBearing, leadDistMeters * 0.5);
            final LatLng leaderEndPt = _projectLatLng(currentPos, geoBearing, leadDistMeters);

            final Color leaderColor = trailColor.withValues(alpha: (opacity * 0.80).clamp(0.22, 0.92));

            polylines.add(
              Polyline(
                points: [currentPos, leaderEndPt],
                color: leaderColor,
                strokeWidth: 1.6,
                pattern: StrokePattern.dashed(segments: const [6, 4]),
              ),
            );

            // Проміжна поділка +30 секунд
            targetCircles.add(
              CircleMarker(
                point: midLeadPt,
                radius: 2.0,
                color: leaderColor,
                borderColor: Colors.black54,
                borderStrokeWidth: 0.8,
              ),
            );

            // Наконечник стрілки напрямку (chevron) у точці +60 секунд
            final double barbLenMeters = (leadDistMeters * 0.22).clamp(280.0, 1400.0);
            const double barbAngleOffset = 152.0 * math.pi / 180.0;
            final LatLng leftBarb = _projectLatLng(leaderEndPt, geoBearing + barbAngleOffset, barbLenMeters);
            final LatLng rightBarb = _projectLatLng(leaderEndPt, geoBearing - barbAngleOffset, barbLenMeters);

            polylines.add(
              Polyline(
                points: [leftBarb, leaderEndPt, rightBarb],
                color: trailColor.withValues(alpha: opacity),
                strokeWidth: 1.8,
              ),
            );
          }

          // Якщо ціль виділена (Tap-to-Inspect) — подвійне радарне кільце захоплення
          if (isSelected) {
            final double selPulse = 0.5 + 0.5 * math.sin(_controller.value * 2.0 * math.pi * 3.0);
            targetCircles.add(
              CircleMarker(
                point: currentPos,
                radius: 17.0 + selPulse * 4.0,
                color: Colors.cyanAccent.withValues(alpha: 0.18),
                borderColor: Colors.cyanAccent,
                borderStrokeWidth: 2.0,
              ),
            );
          }

          final bool isUav = typeStr == 'shahed' ||
              typeStr == 'shahed_jet' ||
              typeStr == 'uav_guided' ||
              typeStr == 'uav_recon' ||
              typeStr == 'uav_decoy';
          final bool isMissile = typeStr.contains('missile') || typeStr == 'kab';
          final bool isHighSpeedThreat = isMissile || typeStr == 'shahed_jet';

          // Акустичний радіус чутності (3200 м) для БпЛА
          if (isUav) {
            targetCircles.add(
              CircleMarker(
                point: currentPos,
                radius: 3200,
                useRadiusInMeter: true,
                color: Colors.yellow.withValues(alpha: 0.035 * opacity),
                borderColor: trailColor.withValues(alpha: 0.20 * opacity),
                borderStrokeWidth: 1.0,
              ),
            );
          }

          // Пульсуючий радарний ореол для швидкісних цілей (балістика, крилаті ракети, реактивні БпЛА)
          if (isHighSpeedThreat && !isDescending) {
            final double hsPulse = ((_controller.value * 3.0) + (i * 0.27)) % 1.0;
            targetCircles.add(
              CircleMarker(
                point: currentPos,
                radius: 10.0 + hsPulse * 14.0,
                useRadiusInMeter: false,
                color: trailColor.withValues(alpha: (1.0 - hsPulse) * 0.22 * opacity),
                borderColor: trailColor.withValues(alpha: (1.0 - hsPulse) * 0.75 * opacity),
                borderStrokeWidth: 1.4,
              ),
            );
          }

          // Радарний сонар-пінг виявлення нової або щойно оновленої цілі (перші 12 секунд)
          if (elapsedSec >= 0.0 && elapsedSec <= 12.0 && !isDescending) {
            final double pingWindowFade = (1.0 - (elapsedSec / 12.0)).clamp(0.15, 1.0);
            final double pingPhase = ((_controller.value * 2.4) + (i * 0.19)) % 1.0;
            targetCircles.add(
              CircleMarker(
                point: currentPos,
                radius: 9.0 + pingPhase * 22.0,
                useRadiusInMeter: false,
                color: trailColor.withValues(alpha: (1.0 - pingPhase) * 0.26 * pingWindowFade * opacity),
                borderColor: Colors.white.withValues(alpha: (1.0 - pingPhase) * 0.85 * pingWindowFade * opacity),
                borderStrokeWidth: 1.5,
              ),
            );
          }

          // Прогнозний конус розльоту (з масштабуванням прозорості за Confidence Decay)
          if (!isCircling && !inOrbit && path.length >= 2) {
            forecastPolygons.add(
              _buildForecastCone(currentPos, geoBearing, speedMs, trailColor, isUav, opacity: opacity),
            );
          }

          // Індикатор стрімкого зниження / падіння
          if (isDescending) {
            final double pulse = 0.5 + 0.5 * math.sin(_controller.value * 2.0 * math.pi * 4.0);
            targetCircles.add(
              CircleMarker(
                point: currentPos,
                radius: 14 + pulse * 8,
                useRadiusInMeter: false,
                color: Colors.redAccent.withValues(alpha: (0.25 + 0.2 * pulse) * opacity),
                borderColor: Colors.redAccent.withValues(alpha: opacity),
                borderStrokeWidth: 2.0,
              ),
            );
          }

          final double iconSize = isMissile ? 20.0 : 17.0;
          final visualContent = _buildThreatAssetIcon(typeStr, size: iconSize);
          final glowingIcon = Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: isDescending
                      ? Colors.redAccent.withValues(alpha: 0.75 * opacity)
                      : (isSelected
                          ? Colors.cyanAccent.withValues(alpha: 0.8 * opacity)
                          : trailColor.withValues(alpha: 0.55 * opacity)),
                  blurRadius: isSelected ? 6 : 3.5,
                  spreadRadius: isSelected ? 1.0 : 0.3,
                )
              ],
            ),
            child: visualContent,
          );

          // Кольорова індикація висоти (Echelon Color) та телеметрії:
          // > 3500 м: Colors.lightBlueAccent (висотний)
          // 1500..3500 м: Colors.amberAccent (середній)
          // < 1500 м або зниження: Colors.redAccent з префіксом ↓
          Color badgeColor;
          String badgeText = '';

          if (isDescending || (altitudeMeters != null && altitudeMeters < 1500)) {
            badgeColor = Colors.redAccent;
            final aStr = altitude ?? (altitudeMeters != null ? '$altitudeMeters м' : 'ЗНИЖЕННЯ');
            badgeText = '↓ $aStr';
          } else if (altitudeMeters != null && altitudeMeters > 3500) {
            badgeColor = Colors.lightBlueAccent;
            badgeText = altitude ?? '$altitudeMeters м';
          } else if (altitudeMeters != null && altitudeMeters >= 1500 && altitudeMeters <= 3500) {
            badgeColor = Colors.amberAccent;
            badgeText = altitude ?? '$altitudeMeters м';
          } else if (isCircling || inOrbit) {
            badgeColor = trailColor;
            badgeText = altitude != null ? '⟳ $altitude' : '⟳ кружляє';
          } else if (altitude != null) {
            badgeColor = trailColor;
            badgeText = altitude;
          } else {
            badgeColor = isSelected ? Colors.cyanAccent : trailColor;
          }

          // При виділенні цілі (Tap-to-Inspect) додаємо живу телеметрію швидкості та курсу
          if (isSelected) {
            final String compassDir = _compassDirectionFromBearing(geoBearing);
            final String telemetryStr = '${baseSpeedKmh.round()} км/год $compassDir';
            badgeText = badgeText.isNotEmpty ? '$badgeText • $telemetryStr' : telemetryStr;
          }

          if (decayTimeTag != null) {
            if (badgeText.isNotEmpty) {
              badgeText = '$badgeText • $decayTimeTag';
            } else {
              badgeText = decayTimeTag;
            }
          }

          final int? clusterCount = leadClusterBadges[i];
          final bool isNonLeadClusterMember = clusteredIndices.contains(i) && clusterCount == null;
          // Приховуємо дублюючі підписи у рядових дронів щільного рою, щоб не засмічувати карту
          final bool hasBadge = badgeText.isNotEmpty && (!isNonLeadClusterMember || isSelected || isDescending);
          final badgeBg = isDescending
              ? Colors.red.shade900.withValues(alpha: 0.88 * opacity)
              : (isSelected
                  ? const Color(0xEE071E26)
                  : Colors.black.withValues(alpha: 0.85 * opacity));

          // Розумне розведення підписів (4 слоти) для сусідніх цілей у радіусі 3.5 км
          int nearbyRank = 0;
          if (hasBadge) {
            for (final entry in activePositions.entries) {
              if (entry.key < i &&
                  const Distance().as(LengthUnit.Meter, currentPos, entry.value) < 3500.0) {
                nearbyRank++;
              }
            }
          }
          final double badgeTopOffset = switch (nearbyRank % 4) {
            0 => 25.0,
            1 => -16.0,
            2 => 36.0,
            _ => -27.0,
          };

          // Плавний пружний імпульс масштабу при появі нової цілі (перші 1.8 секунди)
          final double spawnScale = (elapsedSec >= 0.0 && elapsedSec < 1.8)
              ? (1.0 + 0.22 * math.sin((elapsedSec / 1.8) * math.pi))
              : 1.0;

          markers.add(
            Marker(
              point: currentPos,
              width: 38,
              height: 38,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  widget.onSelectThreat?.call(t['msgId']);
                },
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    Transform.scale(
                      scale: spawnScale,
                      child: Transform.rotate(
                        angle: rotationAngle,
                        child: Opacity(
                          opacity: opacity,
                          child: glowingIcon,
                        ),
                      ),
                    ),
                    if (isGhost)
                      Positioned(
                        top: -4,
                        left: -4,
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.8), width: 1),
                          ),
                          child: const Text('?', style: TextStyle(color: Colors.orangeAccent, fontSize: 8.5, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    if (clusterCount != null && clusterCount >= 3)
                      Positioned(
                        top: -6,
                        right: -10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade700,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.white, width: 1.0),
                            boxShadow: const [
                              BoxShadow(color: Colors.black87, blurRadius: 4, offset: Offset(0, 2))
                            ],
                          ),
                          child: Text(
                            '×$clusterCount',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9.5,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    if (hasBadge)
                      Positioned(
                        top: badgeTopOffset,
                        left: -65,
                        right: -65,
                        child: Center(
                          child: Opacity(
                            opacity: opacity,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.2),
                              decoration: BoxDecoration(
                                color: badgeBg,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: (isSelected ? Colors.cyanAccent : badgeColor).withValues(alpha: 0.85),
                                  width: isSelected ? 1.1 : 0.8,
                                ),
                              ),
                              child: Text(
                                badgeText,
                                style: TextStyle(
                                  color: isSelected ? Colors.cyanAccent : badgeColor,
                                  fontSize: 8,
                                  fontWeight: FontWeight.bold,
                                  height: 1.0,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        }

        // Знак питання на місці втрати фіксації шахеда (прибирається через 3 хвилини, коло пошуку відновлення на мапі не малюється)
        for (final lost in widget.lostTracks) {
          final lostPt = lost['point'];
          if (lostPt is! LatLng) continue;
          final lostAt = lost['lostAt'] as DateTime?;
          if (lostAt != null && effectiveNow.difference(lostAt).inSeconds > kLostTrackRetentionSec) {
            continue;
          }
          markers.add(
            Marker(
              point: lostPt,
              width: 22,
              height: 22,
              child: IgnorePointer(
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.8), width: 1.2),
                  ),
                  child: const Text('?', style: TextStyle(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.bold, height: 1.0)),
                ),
              ),
            ),
          );
        }

        final layerWidget = Stack(
          children: [
            if (forecastPolygons.isNotEmpty) PolygonLayer(polygons: forecastPolygons),
            PolylineLayer(polylines: polylines),
            CircleLayer(circles: targetCircles),
            MarkerLayer(markers: markers),
          ],
        );
        _cachedLayerWidget = layerWidget;
        return layerWidget;
      },
    );
  }
}



