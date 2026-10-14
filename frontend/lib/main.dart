import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'desktop_map_wrapper.dart';

import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';

String _staticTestModeTime = DateTime.now().toUtc().toIso8601String();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
      title: 'Kyiv Alert Monitor',
      scrollBehavior: NoStretchScrollBehavior(), 
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF121212),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E1E1E),
          elevation: 0,
        ),
        cardColor: const Color(0xFF1E1E1E),
      ),
      home: const MainScreen(),
    );
  }
}

final geoJsonProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final jsonString = await rootBundle.loadString('assets/ukraine.geojson');
  return json.decode(jsonString);
});

class AlertsNotifier extends Notifier<Map<String, bool>> {
  Timer? _timer;

  @override
  Map<String, bool> build() {
    ref.onDispose(() {
      _timer?.cancel();
    });
    
    _scheduleNextFetch(0);
    return {};
  }

  void _scheduleNextFetch(int seconds) {
    _timer?.cancel();
    _timer = Timer(Duration(seconds: seconds), _fetchData);
  }

  Future<void> _fetchData() async {
    try {
      final response = await http.get(Uri.parse('https://ubilling.net.ua/aerialalerts/'));
      if (response.statusCode == 200) {
        final data = json.decode(utf8.decode(response.bodyBytes));
        Map<String, bool> alerts = {};
        final states = data['states'] as Map<String, dynamic>;
        states.forEach((key, value) {
          alerts[key] = value['alertnow'] == true;
        });
        
        state = alerts;

        bool hasActiveAlert = alerts['м. Київ'] == true || alerts['Київська область'] == true;
        _scheduleNextFetch(hasActiveAlert ? 15 : 10);
        return;
      }
    } catch (_) {}
    
    _scheduleNextFetch(10);
  }
}

final alertsProvider = NotifierProvider<AlertsNotifier, Map<String, bool>>(() {
  return AlertsNotifier();
});

class WatchedLocation {
  final String id;
  final String name;
  final String address;
  final LatLng point;
  final double radiusMeters;
  final bool enabled;

  const WatchedLocation({
    required this.id,
    required this.name,
    required this.address,
    required this.point,
    this.radiusMeters = 4000.0,
    this.enabled = true,
  });

  WatchedLocation copyWith({
    String? id,
    String? name,
    String? address,
    LatLng? point,
    double? radiusMeters,
    bool? enabled,
  }) {
    return WatchedLocation(
      id: id ?? this.id,
      name: name ?? this.name,
      address: address ?? this.address,
      point: point ?? this.point,
      radiusMeters: radiusMeters ?? this.radiusMeters,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'address': address,
    'lat': point.latitude,
    'lon': point.longitude,
    'radiusMeters': radiusMeters,
    'enabled': enabled,
  };

  factory WatchedLocation.fromJson(Map<String, dynamic> json) {
    return WatchedLocation(
      id: json['id'] as String,
      name: json['name'] as String,
      address: json['address'] as String? ?? '',
      point: LatLng((json['lat'] as num).toDouble(), (json['lon'] as num).toDouble()),
      radiusMeters: (json['radiusMeters'] as num?)?.toDouble() ?? 4000.0,
      enabled: json['enabled'] as bool? ?? true,
    );
  }
}

String? _cachedAppFilesDir;

Future<String?> _getAppFilesDirPath() async {
  if (_cachedAppFilesDir != null) return _cachedAppFilesDir;
  if (!kIsWeb && Platform.isAndroid) {
    try {
      const platform = MethodChannel('ua.kyiv.alert.monitor/widget');
      final String? path = await platform.invokeMethod<String>('getFilesDir');
      if (path != null && path.isNotEmpty) {
        _cachedAppFilesDir = path;
        return path;
      }
    } catch (_) {}
  } else if (!kIsWeb && Platform.isWindows) {
    final envAppdata = Platform.environment['APPDATA'];
    if (envAppdata != null) {
      final dir = Directory('$envAppdata/KyivAlert');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _cachedAppFilesDir = dir.path;
      return dir.path;
    }
  }
  return null;
}

Future<File?> _getAppStorageFile(String fileName) async {
  try {
    final dirPath = await _getAppFilesDirPath();
    if (dirPath != null) {
      return File('$dirPath/$fileName');
    }
    return File(fileName);
  } catch (_) {
    return null;
  }
}

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

Future<List<Map<String, dynamic>>> searchStreetAddress(String query) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return [];
  try {
    final uri = Uri.parse(
      'https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent('$trimmed, Київська область')}&limit=5&accept-language=uk',
    );
    final response = await http.get(
      uri,
      headers: {'User-Agent': 'ua.kyiv.alert.monitor'},
    ).timeout(const Duration(seconds: 4));
    if (response.statusCode == 200) {
      final List data = json.decode(utf8.decode(response.bodyBytes));
      return data.map((item) => {
        'display_name': (item['display_name'] ?? '').toString(),
        'lat': double.tryParse(item['lat']?.toString() ?? '') ?? 0.0,
        'lon': double.tryParse(item['lon']?.toString() ?? '') ?? 0.0,
      }).where((m) => (m['lat'] as double) != 0.0).toList();
    }
  } catch (_) {}
  return [];
}

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

const Set<String> _kExternalBorderKeys = {
  'житомирщин', 'житомирськ', 'житомир', 'малин', 'коростень', 'радомишл', 'овруч',
  'чернігівщин', 'черкащин', 'вінниччин', 'полтавщин',
  'прилук', 'ніжин', 'носівк', 'ічня', 'пирятин', 'лубни', 'золотонош', 'канів',
  'корсунь', 'мрин', 'вертіївк', 'мала дівиц', 'линовиц', 'остер', 'козелец', 'кіпті',
  'курськ', 'брянськ', 'бєлгород', 'белгород', 'воронеж', 'орел', 'орл',
  'крим', 'чауд', 'приморсько-ахтарськ', 'єйськ', 'енгельс', 'ахтубінськ',
  'саваслейк', 'олень', 'каспій', 'мозир', 'гомел', 'тул', 'ростов',
};

const Set<String> _kFarRegions = {
  'луцьк', 'хмель', 'хмельницьк', 'кременчук', 'одещин', 'одес', 'запоріж', 'дніпр', 'харків',
  'львів', 'рівн', 'рівнен', 'терноп', 'франківськ', 'волин', 'миколаїв', 'херсон', 'сум',
  'кропивницьк', 'кіровоград', 'полтавськ', 'полтав', 'чернівц', 'закарпат',
  'вінниц', 'вінниччин', 'черкас', 'черкащин', 'житомир', 'чернігів',
};

const _kBaseKyivLocations = <String, (double, double, String)>{
  'київ': (50.450, 30.523, 'Київ'),
  'центр': (50.450, 30.523, 'Київ (Центр)'),
  'голосіїв': (50.395, 30.512, 'Голосіїв'),
  'теремк': (50.375, 30.452, 'Теремки'),
  'деміїв': (50.404, 30.518, 'Деміївка'),
  'вднг': (50.381, 30.477, 'ВДНГ'),
  'феофані': (50.345, 30.488, 'Феофанія'),
  'пирогів': (50.354, 30.512, 'Пирогів'),
  'пирогов': (50.354, 30.512, 'Пирогів'),
  'корчуват': (50.368, 30.548, 'Корчувате'),
  'конча': (50.303, 30.575, 'Конча-Заспа'),
  'чапаєвк': (50.318, 30.562, 'Віта-Литовська'),
  'дарниц': (50.413, 30.638, 'Дарниця'),
  'дврз': (50.446, 30.671, 'ДВРЗ'),
  'рембаз': (50.428, 30.672, 'Рембаза'),
  'позняк': (50.401, 30.633, 'Позняки'),
  'осокорк': (50.391, 30.615, 'Осокорки'),
  'бортнич': (50.384, 30.692, 'Бортничі'),
  'вирлиц': (50.403, 30.666, 'Вирлиця'),
  'харківськ': (50.415, 30.653, 'Харківський масив'),
  'червоний хутір': (50.408, 30.682, 'Червоний Хутір'),
  'деснян': (50.518, 30.603, 'Деснянський р-н'),
  'троєщин': (50.514, 30.598, 'Троєщина'),
  'троя': (50.514, 30.598, 'Троєщина'),
  'трою': (50.514, 30.598, 'Троєщина'),
  'лісов': (50.476, 30.627, 'Лісовий масив'),
  'биківн': (50.476, 30.668, 'Биківня'),
  'дніпров': (50.452, 30.604, 'Дніпровський р-н'),
  'воскресенк': (50.485, 30.595, 'Воскресенка'),
  'березняк': (50.426, 30.601, 'Березняки'),
  'русанівк': (50.439, 30.596, 'Русанівка'),
  'радужн': (50.488, 30.584, 'Райдужний'),
  'райдужн': (50.488, 30.584, 'Райдужний'),
  'оболон': (50.508, 30.498, 'Оболонь'),
  'пуща': (50.543, 30.347, 'Пуща-Водиця'),
  'мінськ': (50.522, 30.470, 'Мінський масив'),
  'пріорк': (50.502, 30.456, 'Пріорка'),
  'куренів': (50.489, 30.464, 'Куренівка'),
  'печерськ': (50.432, 30.542, 'Печерськ'),
  'звіринець': (50.418, 30.556, 'Звіринець'),
  'теличк': (50.400, 30.568, 'Теличка'),
  'поділ': (50.465, 30.513, 'Поділ'),
  'подол': (50.465, 30.513, 'Поділ'),
  'виноградар': (50.511, 30.419, 'Виноградар'),
  'святошин': (50.457, 30.364, 'Святошин'),
  'білич': (50.468, 30.342, 'Біличі'),
  'новобілич': (50.476, 30.338, 'Новобіличі'),
  'академ': (50.465, 30.355, 'Академмістечко'),
  'борщагів': (50.422, 30.376, 'Борщагівка'),
  'відрадн': (50.432, 30.422, 'Відрадний'),
  'солом\'ян': (50.428, 30.478, 'Солом\'янка'),
  'солом': (50.428, 30.478, 'Солом\'янка'),
  'жулян': (50.395, 30.441, 'Жуляни'),
  'шулявк': (50.454, 30.445, 'Шулявка'),
  'караваєв': (50.441, 30.445, 'Караваєві Дачі'),
  'лук\'янів': (50.462, 30.473, 'Лук\'янівка'),
  'лукянів': (50.462, 30.473, 'Лук\'янівка'),
  'сирец': (50.476, 30.440, 'Сирець'),
  'сирц': (50.476, 30.440, 'Сирець'),
  'нивк': (50.458, 30.404, 'Нивки'),
  'берковец': (50.490, 30.370, 'Берковець'),
  'берківц': (50.490, 30.370, 'Берковець'),
  'шевченк': (50.461, 30.482, 'Шевченківський р-н'),
  'татарк': (50.471, 30.481, 'Татарка'),
  'видубич': (50.402, 30.561, 'Видубичі'),
  'гідропарк': (50.445, 30.576, 'Гідропарк'),
  'труханів': (50.462, 30.545, 'Труханів острів'),
  'васильків': (50.178, 30.316, 'Васильків'),
  'васильков': (50.178, 30.316, 'Васильків'),
  'васік': (50.178, 30.316, 'Васильків'),
  'крушинк': (50.231, 30.366, 'Крушинка'),
  'глевах': (50.267, 30.319, 'Глеваха'),
  'калинівк': (50.228, 30.228, 'Калинівка'),
  'кобці': (50.185, 30.255, 'Кобці'),
  'біла церкв': (49.795, 30.116, 'Біла Церква'),
  'білу церкв': (49.795, 30.116, 'Біла Церква'),
  'білої церкв': (49.795, 30.116, 'Біла Церква'),
  'узин': (49.824, 30.413, 'Узин'),
  'фастів': (50.081, 29.914, 'Фастів'),
  'фастов': (50.081, 29.914, 'Фастів'),
  'макарів': (50.459, 29.803, 'Макарів'),
  'макаров': (50.459, 29.803, 'Макарів'),
  'бородянк': (50.645, 29.923, 'Бородянка'),
  'ірпін': (50.518, 30.239, 'Ірпінь'),
  'ірпен': (50.518, 30.239, 'Ірпінь'),
  'буч': (50.547, 30.222, 'Буча'),
  'гостомел': (50.575, 30.258, 'Гостомель'),
  'чайк': (50.434, 30.297, 'Чайки'),
  'стоянк': (50.457, 30.245, 'Стоянка'),
  'ворзел': (50.544, 30.158, 'Ворзель'),
  'коцюбинськ': (50.491, 30.332, 'Коцюбинське'),
  'вишнев': (50.393, 30.366, 'Вишневе'),
  'крюківщин': (50.373, 30.366, 'Крюківщина'),
  'софіївськ': (50.410, 30.366, 'Софіївська Борщагівка'),
  'петропавлівськ': (50.435, 30.340, 'Петропавлівська Борщагівка'),
  'боярк': (50.329, 30.293, 'Боярка'),
  'чабан': (50.342, 30.424, 'Чабани'),
  'гатному': (50.356, 30.402, 'Гатне'),
  'гатне': (50.356, 30.402, 'Гатне'),
  'хотів': (50.334, 30.468, 'Хотів'),
  'хотов': (50.334, 30.468, 'Хотів'),
  'лісник': (50.305, 30.513, 'Лісники'),
  'ходосівк': (50.273, 30.516, 'Ходосівка'),
  'підгірц': (50.244, 30.547, 'Підгірці'),
  'козин': (50.211, 30.660, 'Козин'),
  'обухів': (50.117, 30.630, 'Обухів'),
  'обухов': (50.117, 30.630, 'Обухів'),
  'українк': (50.144, 30.741, 'Українка'),
  'трипілл': (50.116, 30.768, 'Трипілля'),
  'кагарлик': (49.866, 30.822, 'Кагарлик'),
  'ржищів': (49.967, 31.043, 'Ржищів'),
  'миронівк': (49.664, 30.985, 'Миронівка'),
  'богуслав': (49.546, 30.873, 'Богуслав'),
  'рокітн': (49.689, 30.475, 'Рокитне'),
  'рокитн': (49.689, 30.475, 'Рокитне'),
  'таращ': (49.562, 30.505, 'Тараща'),
  'сквир': (49.731, 29.664, 'Сквира'),
  'тітіїв': (49.366, 29.688, 'Тетіїв'),
  'тетіїв': (49.366, 29.688, 'Тетіїв'),
  'переяслав': (50.076, 31.455, 'Переяслав'),
  'яготин': (50.256, 31.782, 'Яготин'),
  'березан': (50.307, 31.472, 'Березань'),
  'баришівк': (50.354, 31.320, 'Баришівка'),
  'бориспіль': (50.354, 30.956, 'Бориспіль'),
  'бориспол': (50.354, 30.956, 'Бориспіль'),
  'бориспл': (50.354, 30.956, 'Бориспіль'),
  'борісп': (50.354, 30.956, 'Бориспіль'),
  'броварськ': (50.511, 30.790, 'Броварський р-н'),
  'обухівськ': (50.117, 30.630, 'Обухівський р-н'),
  'фастівськ': (50.081, 29.914, 'Фастівський р-н'),
  'бучанськ': (50.547, 30.222, 'Бучанський р-н'),
  'вишгородськ': (50.584, 30.488, 'Вишгородський р-н'),
  'білоцерківськ': (49.795, 30.116, 'Білоцерківський р-н'),
  'щаслив': (50.379, 30.803, 'Щасливе'),
  'проліск': (50.391, 30.780, 'Проліски'),
  'гора': (50.369, 30.862, 'Гора'),
  'чубинськ': (50.381, 30.849, 'Чубинське'),
  'княжич': (50.461, 30.783, 'Княжичі'),
  'требух': (50.483, 30.896, 'Требухів'),
  'красил': (50.448, 30.942, 'Красилівка'),
  'гоголів': (50.517, 30.982, 'Гоголів'),
  'велика димерк': (50.592, 30.914, 'Велика Димерка'),
  'димерк': (50.592, 30.914, 'Велика Димерка'),
  'калита': (50.751, 31.026, 'Калита'),
  'вороньків': (50.219, 30.898, 'Вороньків'),
  'процева': (50.236, 30.789, 'Проців'),
  'проців': (50.236, 30.789, 'Проців'),
  'гнідин': (50.331, 30.713, 'Гнідин'),
  'вишеньк': (50.298, 30.686, 'Вишеньки'),
  'бровар': (50.511, 30.790, 'Бровари'),
  'зазим': (50.569, 30.685, 'Зазим\'я'),
  'погреб': (50.546, 30.642, 'Погреби'),
  'пухівк': (50.606, 30.716, 'Пухівка'),
  'літки': (50.669, 30.753, 'Літки'),
  'вишгород': (50.584, 30.488, 'Вишгород'),
  'море': (50.680, 30.450, 'Київське море'),
  'водосховище': (50.680, 30.450, 'Київське море'),
  'київське море': (50.680, 30.450, 'Київське море'),
  'хотянівк': (50.612, 30.562, 'Хотянівка'),
  'новосілк': (50.354, 30.462, 'Новосілки'),
  'петрівц': (50.629, 30.435, 'Нові Петрівці'),
  'лютіж': (50.684, 30.395, 'Лютіж'),
  'димер': (50.781, 30.301, 'Димер'),
  'іванків': (50.934, 29.897, 'Іванків'),
  'іванков': (50.934, 29.897, 'Іванків'),
  
    'фурси': (49.771, 29.967, 'Фурси'),
    'вільшанк': (49.715, 30.046, 'Мала Вільшанка'),
    'бакал': (49.791, 30.026, 'Бакали'),
    'володарк': (49.525, 29.919, 'Володарка'),
    'дмитрівк': (50.457, 30.019, 'Дмитрівка'),
    'петрашівк': (49.764, 30.076, 'Петрашівка'),
  'славутич': (51.517, 30.763, 'Славутич'),
  'дзвінков': (50.252, 30.075, 'Дзвінкове'),
  'немішаєв': (50.563, 30.091, 'Немішаєве'),
  'клавдієв': (50.583, 30.008, 'Клавдієво-Тарасове'),
  'пісківк': (50.706, 29.595, 'Пісківка'),
  'чзв': (51.276, 30.222, 'Чорнобильська ЗВ'),
  'чорнобил': (51.276, 30.222, 'Чорнобильська ЗВ'),
  'прип\'ят': (51.404, 30.054, 'Прип\'ять'),
  'ксаверівк': (50.046, 30.217, 'Ксаверівка'),
  'пшеничн': (50.093, 30.205, 'Пшеничне'),
  'митниц': (50.129, 30.243, 'Митниця'),
  'устимівк': (49.958, 30.022, 'Устимівка'),
  'гребінк': (49.956, 30.171, 'Гребінки'),
  'солтанівк': (50.171, 30.198, 'Велика Солтанівка'),
  'хлепч': (50.188, 30.181, 'Хлепча'),
  'багрин': (50.217, 30.213, 'Багрин'),
  'плесецьк': (50.221, 30.109, 'Плесецьке'),
  'забір\'я': (50.321, 30.217, 'Забір\'я'),
  'забірʼя': (50.321, 30.217, 'Забір\'я'),
  'горенк': (50.557, 30.318, 'Горенка'),
  'катюжанк': (50.804, 30.133, 'Катюжанка'),
  'страхолісс': (51.077, 30.394, 'Страхолісся'),
  'вася': (50.178, 30.316, 'Васильків'),
  'столиц': (50.450, 30.523, 'Київ (Столиця)'),
  'басан': (50.565, 31.511, 'Нова Басань'),
  'згурівк': (50.490, 31.780, 'Згурівка'),
  'кіпті': (51.056, 31.151, 'Кіпті'),
  'козелец': (50.916, 31.119, 'Козелець'),
  'остер': (50.950, 30.880, 'Остер'),
  'почайн': (50.497, 30.518, 'Почайна'),
  'високе': (50.600, 31.230, 'Високе'),
  'столоц': (50.450, 30.523, 'Київ (Столиця)'),
  'боря': (50.354, 30.956, 'Бориспіль'),
  'борік': (50.354, 30.956, 'Бориспіль'),
  'борик': (50.354, 30.956, 'Бориспіль'),
  'рогозів': (50.243, 31.050, 'Рогозів'),
  'артемівк': (50.313, 31.026, 'Артемівка'),

  // Додано з повідомлень каналів
  'вєнік': (50.511, 30.419, 'Виноградар'),
  'венік': (50.511, 30.419, 'Виноградар'),
  'летовище': (50.401, 30.451, 'Аеропорт Жуляни'),
  'кардачі': (50.441, 30.445, 'Караваєві Дачі'),
  'борщага': (50.418, 30.367, 'Борщагівка'),
  'чоколівк': (50.432, 30.456, 'Чоколівка'),
  'батиєв': (50.428, 30.495, 'Батиєва гора'),
  'черепанов': (50.433, 30.520, 'Черепанова гора'),
  'липки': (50.443, 30.536, 'Липки'),
  'клов': (50.438, 30.540, 'Клов'),
  'мишоловк': (50.377, 30.532, 'Мишоловка'),
  'совки': (50.412, 30.472, 'Совки'),
  'протасів': (50.424, 30.502, 'Протасів Яр'),
  'байков': (50.418, 30.511, 'Байкове'),
  'нова забудов': (50.432, 30.512, 'Нова Забудова'),
  'євбаз': (50.447, 30.495, 'Галицька пл. (Євбаз)'),
  'зоопарк': (50.455, 30.465, 'КПІ / Зоопарк'),
  'політех': (50.450, 30.466, 'КПІ'),
  'дубки': (50.478, 30.418, 'Сирець (Дубки)'),
  'мостицьк': (50.505, 30.433, 'Мостицький масив'),
  'сирецьк': (50.488, 30.445, 'Сирецька'),
  'водогін': (50.556, 30.464, 'Водогін'),
  'міністерк': (50.542, 30.475, 'Озеро Міністерка'),
  'дамба': (50.588, 30.512, 'Вишгородська дамба'),
  'муромець': (50.505, 30.544, 'Парк Муромець'),
  'рибальськ': (50.475, 30.530, 'Рибальський острів'),
  'тец 6': (50.533, 30.663, 'ТЕЦ-6'),
  'русанівські сади': (50.465, 30.582, 'Русанівські сади'),
  'нижні сади': (50.365, 30.605, 'Осокорки (Нижні сади)'),
  'патона': (50.427, 30.582, 'Міст Патона'),
  'ретровіл': (50.503, 30.417, 'ТРЦ Retroville'),
  'республік': (50.374, 30.448, 'ТРЦ Respublika'),
  'іподром': (50.378, 30.468, 'Іподром'),
  'одеська пл': (50.372, 30.457, 'Одеська площа'),
  'волинськ': (50.416, 30.433, 'Пост Волинський'),
  'столичн': (50.365, 30.535, 'Столичне шосе'),
  'осещин': (50.578, 30.533, 'Осещина'),
  'рожівк': (50.568, 30.742, 'Рожівка'),
  'залісс': (50.662, 30.865, 'Парк Залісся'),
  'скибин': (50.565, 30.835, 'Скибин'),
  'луб\'янк': (50.652, 30.174, 'Луб\'янка'),
  'озера': (50.618, 30.208, 'Озера'),
  'демидів': (50.718, 30.335, 'Демидів'),
  'козарович': (50.768, 30.362, 'Козаровичі'),
  'глібівк': (50.808, 30.365, 'Глібівка'),
  'сухолучч': (50.945, 30.435, 'Сухолуччя'),
  'дитяток': (51.115, 30.145, 'Дитятки'),
  'дитятки': (51.115, 30.145, 'Дитятки'),
  'оране': (51.055, 30.125, 'Оране'),
  'крячк': (50.210, 30.270, 'Крячки'),
  'путрівк': (50.211, 30.264, 'Путрівка'),
  'залізн': (50.228, 30.342, 'Залізне'),
  'борисів': (50.205, 30.352, 'Борисів'),
  'кодак': (50.098, 30.309, 'Кодаки'),
  'барахт': (50.122, 30.382, 'Барахти'),
  'погреби васильків': (50.142, 30.422, 'Погреби (Васильків)'),
  'святопетрівськ': (50.385, 30.325, 'Святопетрівське'),
  'білогородк': (50.395, 30.231, 'Білогородка'),
  'горенич': (50.422, 30.208, 'Гореничі'),
  'шпитьк': (50.418, 30.125, 'Шпитьки'),
  'петрушк': (50.432, 30.165, 'Петрушки'),
  'бобриц': (50.345, 30.192, 'Бобриця'),
  'музич': (50.362, 30.118, 'Музичі'),
  'малютянк': (50.298, 30.258, 'Малютянка'),
  'мархалівк': (50.265, 30.362, 'Мархалівка'),
  'віта': (50.312, 30.388, 'Віта-Поштова'),
  'мощун': (50.555, 30.195, 'Мощун'),
  'лавін': (50.395, 30.447, 'Лавіна Молл'),
  'лівий берег': (50.430, 30.610, 'Лівий берег'),
  'правобережж': (50.440, 30.480, 'Правобережжя'),

  // Населені пункти Київщини та вектори виходу на сусідні області
  'заворич': (50.704, 31.132, 'Заворичі'),
  'калинівка бровар': (50.562, 30.865, 'Калинівка (Бровари)'),
  'богдан': (50.625, 30.915, 'Богданівка'),
  'медвин': (49.395, 30.785, 'Медвин'),
  'бовкун': (49.615, 30.585, 'Бовкун'),
  'карапиш': (49.705, 30.655, 'Карапиші'),
  'ясногородк': (50.352, 30.038, 'Ясногородка'),
  'бишів': (50.264, 29.914, 'Бишів'),
  'поліськ': (51.242, 29.395, 'Поліське'),
  'горностайпіл': (51.072, 30.252, 'Горностайпіль'),
  'житомирщин': (50.720, 29.220, 'Житомирщина (Захід)'),
  'житомирськ': (50.720, 29.220, 'Житомирщина (Захід)'),
  'житомир': (50.254, 28.658, 'Житомир'),
  'малин': (50.768, 29.245, 'Малин (Житомирщина)'),
  'коростень': (50.952, 28.648, 'Коростень (Житомирщина)'),
  'радомишл': (50.495, 29.235, 'Радомишль (Житомирщина)'),
  'овруч': (51.325, 28.805, 'Овруч (Житомирщина)'),
  'чернігівщин': (51.150, 31.100, 'Чернігівщина (Північ)'),
  'черкащин': (49.450, 31.300, 'Черкащина (Південь)'),
  'вінниччин': (49.400, 29.300, 'Вінниччина (Пд-Захід)'),
  'полтавщин': (50.050, 32.200, 'Полтавщина (Схід)'),

  // Північ та Вишгородський/Чорнобильський напрямок
  'стещин': (51.108, 30.088, 'Стещино'),
  'овдієва': (50.985, 30.312, 'Овдієва Нива'),
  'любимівк': (50.742, 30.258, 'Любимівка'),
  'рови': (50.875, 30.315, 'Рови'),
  'круги': (50.855, 30.295, 'Круги'),
  'рикун': (50.815, 30.295, 'Рикунь'),
  'гуту-межигірськ': (50.655, 30.325, 'Гута-Межигірська'),
  'гута': (50.655, 30.325, 'Гута-Межигірська'),
  'синяк': (50.678, 30.268, 'Синяк'),
  'раківк': (50.652, 30.245, 'Раківка'),
  'воропаївк': (50.915, 30.015, 'Воропаївка'),
  'кухарі': (50.815, 29.595, 'Кухарі'),
  'зорин': (51.055, 30.185, 'Зорин'),
  'вахівк': (50.935, 30.195, 'Вахівка'),
  'зимовищ': (51.425, 30.195, 'Зимовище'),
  'коленц': (50.925, 29.925, 'Коленці'),

  // Захід та Бучанський/Макарівський напрямок
  'бабинц': (50.682, 29.985, 'Бабинці'),
  'мирча': (50.745, 29.835, 'Мирча'),
  'качали': (50.685, 29.845, 'Качали'),
  'загальц': (50.672, 29.805, 'Загальці'),
  'нова гребля': (50.595, 29.875, 'Нова Гребля'),
  'вабля': (50.625, 29.905, 'Вабля'),
  'дружня': (50.622, 29.965, 'Дружня'),
  'плахтянк': (50.535, 29.945, 'Плахтянка'),
  'андріївк': (50.552, 29.835, 'Андріївка'),
  'личанк': (50.405, 30.105, 'Личанка'),
  'бузов': (50.415, 30.042, 'Бузова'),
  'неграш': (50.375, 30.145, 'Неграші'),
  'гурівщин': (50.428, 30.095, 'Гурівщина'),
  'мрію': (50.432, 30.118, 'Мрія (Житомирська траса)'),
  'кодра': (50.595, 29.555, 'Кодра'),

  // Південь та Васильківський/Обухівський/Кагарлицький напрямок
  'степок': (49.985, 30.425, 'Степок'),
  'ленди': (50.065, 30.555, 'Ленди'),
  'слобідк': (50.095, 30.585, 'Черняхівська Слобідка'),
  'тростинк': (50.045, 30.395, 'Тростинка'),
  'кулібаб': (50.162, 30.285, 'Кулібаба'),
  'застугн': (50.185, 30.295, 'Застугна'),
  'кожухівк': (50.252, 30.242, 'Кожухівка'),
  'здорівк': (50.218, 30.248, 'Здорівка'),
  'дібров': (50.205, 30.215, 'Діброва'),
  'руликів': (50.125, 30.185, 'Руликів'),
  'рославич': (50.232, 30.445, 'Рославичі'),
  'гвоздів': (50.248, 30.482, 'Гвоздів'),
  'кренич': (50.245, 30.525, 'Креничі'),
  'дмитрович': (50.195, 30.545, 'Дмитровичі'),
  'безрадич': (50.175, 30.555, 'Нові/Старі Безрадичі'),
  'гудимов': (50.085, 30.525, 'Гудимове'),
  'шевенківк': (50.025, 30.465, 'Шевченківка'),
  'копачів': (50.098, 30.488, 'Копачів'),
  'велика бугаївк': (50.228, 30.415, 'Велика Бугаївка'),
  'бугаївк': (50.228, 30.415, 'Велика Бугаївка'),
  'землянк': (49.725, 30.545, 'Землянка'),
  'ромашки': (49.728, 30.602, 'Ромашки'),
  'бакумівк': (49.718, 30.625, 'Бакумівка'),
  'острійки': (49.775, 30.295, 'Острійки'),
  'бендюгівк': (49.915, 30.715, 'Бендюгівка'),
  'стави': (49.855, 30.725, 'Стави'),
  'розаліївк': (49.895, 30.355, 'Розаліївка'),
  'лютарі': (49.625, 30.825, 'Лютарі'),
  'телешівк': (49.685, 30.585, 'Телешівка'),
  'шпендівк': (49.785, 30.685, 'Шпендівка'),
  'запрудд': (49.735, 30.685, 'Запруддя'),
  'мирівк': (49.925, 30.785, 'Мирівка'),
  'матяшівк': (50.005, 30.635, 'Матяшівка'),
  'григорівк': (50.045, 30.625, 'Григорівка'),
  'ісайки': (49.515, 30.785, 'Ісайки'),
  'дмитренк': (49.465, 30.815, 'Дмитренки'),

  // Схід та лівобережжя
  'гостролучч': (50.435, 31.295, 'Гостролуччя'),
  'мала стариц': (50.455, 31.155, 'Мала Стариця'),
  'олександрівк': (50.392, 30.892, 'Олександрівка (Бориспіль)'),
  'олександрівки': (50.392, 30.892, 'Велика/Мала Олександрівка'),
  'мала олександрівк': (50.398, 30.858, 'Мала Олександрівка'),
  'велика олександрівк': (50.392, 30.892, 'Велика Олександрівка'),
  'велику олександрівк': (50.392, 30.892, 'Велика Олександрівка'),

  // Північно-східний ракетний коридор (Чернігівщина / Прилуцький напрямок)
  'прилук': (50.590, 32.385, 'Прилуки'),
  'бобровиц': (50.745, 31.388, 'Бобровиця'),
  'ніжин': (51.048, 31.886, 'Ніжин'),
  'носівк': (50.930, 31.580, 'Носівка'),
  'ічня': (50.862, 32.392, 'Ічня'),
  'пирятин': (50.240, 32.500, 'Пирятин'),
  'лубни': (50.016, 32.996, 'Лубни'),
  'золотонош': (49.668, 32.035, 'Золотоноша'),
  'канів': (49.750, 31.460, 'Канів'),
  'корсунь': (49.420, 31.270, 'Корсунь-Шевченківський'),
  'мрин': (51.055, 31.525, 'Мрин'),
  'вертіївк': (51.165, 31.845, 'Вертіївка'),
  'мала дівиц': (50.705, 32.165, 'Мала Дівиця'),
  'линовиц': (50.475, 32.405, 'Линовиця'),

  // Додаткові сленгові скорочення Києва
  'петропавлівк': (50.435, 30.340, 'Петропавлівська Борщагівка'),
  'південну борщагівк': (50.408, 30.395, 'Південна Борщагівка'),
  'софіївк': (50.410, 30.366, 'Софіївська Борщагівка'),
  'заспа': (50.303, 30.575, 'Конча-Заспа'),
  'шухевич': (50.495, 30.568, 'просп. Шухевича'),
  'майдан незалежност': (50.450, 30.523, 'Майдан Незалежності'),
  'лісове кладовищ': (50.498, 30.635, 'Лісове кладовище'),
  'файна': (50.474, 30.405, 'ЖК Файна Таун'),
  'комфорт': (50.435, 30.622, 'ЖК Комфорт Таун'),
  'епіцентр боярка': (50.342, 30.325, 'Боярка (Епіцентр)'),

  // Часті одруківки каналів
  'береовец': (50.490, 30.370, 'Берковець'),
  'берервец': (50.490, 30.370, 'Берковець'),
  'куркнівк': (50.489, 30.464, 'Куренівка'),
  'страхолвсс': (51.077, 30.394, 'Страхолісся'),
  'карариш': (49.705, 30.655, 'Карапиші'),
  'тромтинк': (50.045, 30.395, 'Тростинка'),
  'бархат': (50.122, 30.382, 'Барахти'),
  'гаоздів': (50.248, 30.482, 'Гвоздів'),
  'лівобережк': (50.451, 30.598, 'Лівобережна'),

  // Пускові майданчики балістики та авіації
  'курськ': (51.7308, 36.1930, 'Курськ (Пуск)'),
  'брянськ': (53.2435, 34.3639, 'Брянськ (Пуск)'),
  'бєлгород': (50.5997, 36.5982, 'Бєлгород (Пуск)'),
  'белгород': (50.5997, 36.5982, 'Бєлгород (Пуск)'),
  'воронеж': (51.6607, 39.2002, 'Воронеж (Пуск)'),
  'орел': (52.9707, 36.0643, 'Орел (Пуск)'),
  'орл': (52.9707, 36.0643, 'Орел (Пуск)'),
  'крим': (45.7089, 34.3933, 'Крим (Пуск)'),
  'чауд': (45.0000, 35.8333, 'Чауда (Пуск)'),
  'приморсько-ахтарськ': (46.0464, 38.1749, 'Приморсько-Ахтарськ (Пуск)'),
  'єйськ': (46.7118, 38.2758, 'Єйськ (Пуск)'),
  'енгельс': (51.4833, 46.1167, 'Енгельс (Пуск)'),
  'ахтубінськ': (48.2882, 46.1667, 'Ахтубінськ (Пуск)'),
  'саваслейк': (55.4578, 42.3167, 'Саваслейка (Пуск)'),
  'олень': (68.1500, 33.4667, 'Оленья (Пуск)'),
  'каспій': (43.0, 50.0, 'Каспій (Пуск)'),
  'мозир': (52.0495, 29.2559, 'Мозир (Пуск)'),
  'гомел': (52.4345, 30.9754, 'Гомель (Пуск)'),
  'тул': (54.1930, 37.6190, 'Тула (Пуск)'),
  'ростов': (47.2313, 39.7233, 'Ростов (Пуск)'),
};


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
      return 300;
  }
}

Map<String, (double, double, String)> _kKyivLocations = Map.of(_kBaseKyivLocations);
Map<String, (double, double, String)> _learnedLocations = {};
final Set<String> _pendingOrFailedGeocodes = {};
VoidCallback? _onNewLocationLearned;

String stemLocationCandidate(String word) {
  var lower = word.toLowerCase();
  const vowels = {'а', 'я', 'у', 'ю', 'і', 'и', 'о', 'е'};
  if (lower.length >= 6 && vowels.contains(lower[lower.length - 1])) {
    lower = lower.substring(0, lower.length - 1);
  }
  return lower;
}

const _kLocationStopWords = <String>{
  'київщина', 'київська', 'київ', 'увага', 'тривога', 'шахед', 'шахеди', 'шахеда',
  'ракета', 'ракети', 'балістика', 'північ', 'південь', 'захід', 'схід',
  'дніпро', 'україна', 'область', 'області', 'район', 'району', 'сектор',
  'напрямок', 'напрямку', 'вектор', 'курс', 'пуски', 'виходи', 'збиття',
  'відбій', 'чисто', 'повітряна', 'небезпека', 'група', 'групи', 'ціль', 'цілі'
};

Future<void> _loadLearnedLocations() async {
  try {
    final file = await _getAppStorageFile('learned_locations.json');
    if (file != null && await file.exists()) {
      final content = await file.readAsString();
      final Map<String, dynamic> data = json.decode(content);
      for (final entry in data.entries) {
        final val = entry.value;
        if (val is Map) {
          final lat = (val['lat'] as num?)?.toDouble();
          final lon = (val['lon'] as num?)?.toDouble();
          final name = (val['name'] ?? entry.key).toString();
          if (lat != null && lon != null) {
            _learnedLocations[entry.key] = (lat, lon, name);
            _kKyivLocations[entry.key] = (lat, lon, name);
          }
        }
      }
    }
  } catch (_) {}
}

Future<void> _saveLearnedLocations() async {
  try {
    final file = await _getAppStorageFile('learned_locations.json');
    if (file != null) {
      final Map<String, dynamic> out = {};
      for (final e in _learnedLocations.entries) {
        out[e.key] = {
          'lat': e.value.$1,
          'lon': e.value.$2,
          'name': e.value.$3,
        };
      }
      await file.writeAsString(json.encode(out));
    }
  } catch (_) {}
}

Future<void> _autoGeocodeLocation(String rawWord, String stem) async {
  try {
    final uri = Uri.parse(
      'https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeComponent("$rawWord, Київська область")}&viewbox=29.2,51.6,32.2,49.1&bounded=1&limit=1&accept-language=uk'
    );
    final response = await http.get(uri, headers: {
      'User-Agent': 'ua.kyiv.alert.monitor/1.0 (contact: admin@kyivalert.ua)',
    }).timeout(const Duration(seconds: 4));

    if (response.statusCode == 200) {
      final list = json.decode(response.body);
      if (list is List && list.isNotEmpty) {
        final item = list[0] as Map<String, dynamic>;
        final lat = double.tryParse(item['lat']?.toString() ?? '');
        final lon = double.tryParse(item['lon']?.toString() ?? '');
        if (lat != null && lon != null) {
          if (lat >= 49.1 && lat <= 51.6 && lon >= 29.2 && lon <= 32.2) {
            final displayName = item['display_name']?.toString().split(',')[0].trim() ?? rawWord;
            _learnedLocations[stem] = (lat, lon, displayName);
            _kKyivLocations[stem] = (lat, lon, displayName);
            await _saveLearnedLocations();
            _onNewLocationLearned?.call();
          }
        }
      }
    }
  } catch (_) {}
}

void _checkAndAutoGeocodeLocations(String text) {
  final candidateRegex = RegExp(
    r'(?:на|через|біля|поблизу|район[іу]?|повз|від|з|із|в бік|у бік|курсом на|вектор на)\s+([А-ЯІЇЄҐ][а-яіїєґ\x27ʼ\-]{3,})'
  );
  for (final m in candidateRegex.allMatches(text)) {
    final rawWord = m.group(1);
    if (rawWord == null) continue;
    final rawLower = rawWord.toLowerCase();
    if (_kLocationStopWords.contains(rawLower)) continue;
    final stem = stemLocationCandidate(rawWord);
    if (!_kKyivLocations.containsKey(stem) && !_pendingOrFailedGeocodes.contains(stem)) {
      _pendingOrFailedGeocodes.add(stem);
      _autoGeocodeLocation(rawWord, stem);
      break; // Максимум 1 нове геокодування за один прохід для захисту від бану Nominatim (1 запит/сек)
    }
  }
}
List<String> _dynamicExtraChannels = [];
List<String> _dynamicDangerKeywords = [];
List<String> _dynamicClearKeywords = [];

const int kCurrentVersionCode = 7;
const String kCurrentVersionName = '1.2.4';

class RemoteConfig {
  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String changelog;
  final Map<String, (double, double, String)> extraLocations;
  final List<String> extraChannels;
  final List<String> extraDangerKeywords;
  final List<String> extraClearKeywords;

  const RemoteConfig({
    this.versionCode = kCurrentVersionCode,
    this.versionName = kCurrentVersionName,
    this.apkUrl = '',
    this.changelog = '',
    this.extraLocations = const {},
    this.extraChannels = const [],
    this.extraDangerKeywords = const [],
    this.extraClearKeywords = const [],
  });

  factory RemoteConfig.fromJson(Map<String, dynamic> json) {
    final Map<String, (double, double, String)> locations = {};
    if (json['extra_locations'] is Map) {
      (json['extra_locations'] as Map).forEach((k, v) {
        if (v is Map && v['lat'] != null && v['lon'] != null) {
          final lat = (v['lat'] as num).toDouble();
          final lon = (v['lon'] as num).toDouble();
          final name = v['name']?.toString() ?? k.toString();
          locations[k.toString().toLowerCase().trim()] = (lat, lon, name);
        }
      });
    }

    return RemoteConfig(
      versionCode: (json['version_code'] as num?)?.toInt() ?? kCurrentVersionCode,
      versionName: json['version_name']?.toString() ?? kCurrentVersionName,
      apkUrl: json['apk_url']?.toString() ?? '',
      changelog: json['changelog']?.toString() ?? '',
      extraLocations: locations,
      extraChannels: (json['extra_channels'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      extraDangerKeywords: (json['extra_danger_keywords'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      extraClearKeywords: (json['extra_clear_keywords'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    );
  }

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> locs = {};
    extraLocations.forEach((k, v) {
      locs[k] = {'lat': v.$1, 'lon': v.$2, 'name': v.$3};
    });
    return {
      'version_code': versionCode,
      'version_name': versionName,
      'apk_url': apkUrl,
      'changelog': changelog,
      'extra_locations': locs,
      'extra_channels': extraChannels,
      'extra_danger_keywords': extraDangerKeywords,
      'extra_clear_keywords': extraClearKeywords,
    };
  }
}

class RemoteConfigNotifier extends Notifier<RemoteConfig> {
  Timer? _refreshTimer;

  @override
  RemoteConfig build() {
    _loadFromCache();
    _fetchRemoteConfig();
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(minutes: 30), (_) {
      _fetchRemoteConfig();
    });
    ref.onDispose(() {
      _refreshTimer?.cancel();
    });
    return const RemoteConfig();
  }

  Future<void> _loadFromCache() async {
    try {
      final file = await _getAppStorageFile('remote_config_cache.json');
      if (file != null && await file.exists()) {
        final content = await file.readAsString();
        final jsonMap = json.decode(content) as Map<String, dynamic>;
        final cfg = RemoteConfig.fromJson(jsonMap);
        state = cfg;
        await _loadLearnedLocations();
        _kKyivLocations = {..._kBaseKyivLocations, ...cfg.extraLocations, ..._learnedLocations};
        _dynamicExtraChannels = cfg.extraChannels;
        _dynamicDangerKeywords = cfg.extraDangerKeywords;
        _dynamicClearKeywords = cfg.extraClearKeywords;
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

  Future<void> _fetchRemoteConfig() async {
    final urls = [
      'https://raw.githubusercontent.com/yakymgo-cyber/kyiv-alert-updates/main/remote_config.json',
    ];

    for (final url in urls) {
      try {
        final response = await http.get(
          Uri.parse(url),
          headers: {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
        ).timeout(const Duration(seconds: 5));
        if (response.statusCode == 200) {
          final jsonMap = json.decode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
          final cfg = RemoteConfig.fromJson(jsonMap);
          state = cfg;
          _kKyivLocations = {..._kBaseKyivLocations, ...cfg.extraLocations, ..._learnedLocations};
          _dynamicExtraChannels = cfg.extraChannels;
          _dynamicDangerKeywords = cfg.extraDangerKeywords;
          _dynamicClearKeywords = cfg.extraClearKeywords;
          _saveToCache(cfg);
          break;
        }
      } catch (_) {}
    }
  }

  Future<void> refresh() => _fetchRemoteConfig();
}

final remoteConfigProvider = NotifierProvider<RemoteConfigNotifier, RemoteConfig>(() {
  return RemoteConfigNotifier();
});

class MessagesNotifier extends Notifier<List<dynamic>> {
  Timer? _timer;
  bool _isFirstLoad = true;
  int _backendSkipCycles = 0;

  @override
  List<dynamic> build() {
    _onNewLocationLearned = () {
      state = [...state];
    };
    ref.onDispose(() {
      _timer?.cancel();
      _onNewLocationLearned = null;
    });
    
    _loadLearnedLocations();
    _fetchData();
    return [];
  }

  int? _extractAltitude(String text) {
    final tLower = text.toLowerCase();
    final m = RegExp(r'(\d{3,4})\s*(?:м|метр|m)(?![а-яіїєґa-z])', caseSensitive: false).firstMatch(tLower);
    if (m != null) {
      final val = int.tryParse(m.group(1)!);
      if (val != null) return val;
    }
    final matches = RegExp(r'\b(\d{3,4})\b').allMatches(text);
    for (final match in matches) {
      final val = int.tryParse(match.group(1)!);
      if (val != null && val >= 300 && val <= 7500 && val % 10 == 0) {
        return val;
      }
    }
    return null;
  }

  int? extractAltitude(String text) => _extractAltitude(text);

  Map<String, dynamic> _analyzeLocalThreat(String text, {int? altitudeMeters}) {
    final tLower = text.toLowerCase();

    final bool hasExplicitDrone = tLower.contains('шахед') ||
        tLower.contains('бпла') ||
        tLower.contains('мопед') ||
        tLower.contains('двз') ||
        tLower.contains('дрон') ||
        tLower.contains('геран');

    final bool hasBallisticMarker = tLower.contains('швидкісна') ||
        tLower.contains('швидкісні') ||
        tLower.contains('виходи') ||
        tLower.contains('багато цілей') ||
        tLower.contains('цілей йде') ||
        tLower.contains('цілі йдуть') ||
        tLower.contains('група цілей') ||
        RegExp(r'(?:^|[\s\W_])(?:ЦІЛЬ|УВАГА!?|ПУСК|ВИХОДИ)(?:$|[\s\W_])').hasMatch(text) ||
        text.contains('!!!!') ||
        (text.contains('!!') && text.trim().length <= 35) ||
        tLower.contains('увага !!') ||
        tLower.contains('увага!!');

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
    } else if (tLower.contains('каб') || tLower.contains('кар ') || tLower.contains('керован') || tLower.contains('уфаб')) {
      return {'type': 'kab', 'speed': 850.0, 'label': 'КАБ / КАР'};
    } else if (tLower.contains('на керуванні') || tLower.contains('🎮') || tLower.contains('сікер') || tLower.contains('оптичн') || tLower.contains('старлінк')) {
      return {'type': 'uav_guided', 'speed': 220.0, 'label': 'БпЛА на керуванні 🎮'};
    } else if (tLower.contains('розвідник') || tLower.contains('орлан') || tLower.contains('зала') || tLower.contains('zala') || tLower.contains('суперкам') || tLower.contains('supercam') || tLower.contains('ланцет')) {
      return {'type': 'uav_recon', 'speed': 130.0, 'label': 'РозвідБпЛА 👁️', 'isCircling': true};
    } else if (tLower.contains('пародія') || tLower.contains('гербера') || tLower.contains('імітатор') || tLower.contains('фальш') || tLower.contains('пінопласт')) {
      return {'type': 'uav_decoy', 'speed': 160.0, 'label': 'Імітатор / Фальш-ціль'};
    }

    bool highAlt = (altitudeMeters != null && altitudeMeters >= 4000);
    if (!highAlt) {
      final altMatch = RegExp(r'(\d+(?:[.,]\d+)?)\s*(м|км)\b', caseSensitive: false).firstMatch(tLower);
      if (altMatch != null) {
        final val = double.tryParse(altMatch.group(1)!.replaceAll(',', '.')) ?? 0.0;
        final unit = altMatch.group(2)!.toLowerCase();
        if ((unit == 'км' && val >= 4.0) || (unit == 'м' && val >= 4000.0)) {
          highAlt = true;
        }
      }
    }

    final bool isJet = tLower.contains('реактив') || tLower.contains('швидкісн') || tLower.contains('бандерол') || tLower.contains('герань-3') || highAlt;
    if (isJet) {
      return {'type': 'shahed_jet', 'speed': 500.0, 'label': 'Реактивний БпЛА'};
    }
    return {'type': 'shahed', 'speed': 185.0, 'label': 'Ударний БпЛА (Шахед)'};
  }

  String categorizeLocalMessage(String text) => _categorizeLocalMessage(text);

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
    ];
    if (clear.any((kw) => tLower.contains(kw)) || _dynamicClearKeywords.any((kw) => tLower.contains(kw))) return 'clear';

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
        _dynamicDangerKeywords.any((kw) => tLower.contains(kw)) ||
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

  List<Map<String, dynamic>> parseLocalThreats(String text) {
    _checkAndAutoGeocodeLocations(text);
    final globalAlt = _extractAltitude(text);
    final globalThreat = _analyzeLocalThreat(text, altitudeMeters: globalAlt);
    final textWithoutReply = text.replaceAll(RegExp(r'^↪️.*?\n'), '');
    final tLower = textWithoutReply.toLowerCase();

    final bool hasMultipleDrones = RegExp(r'(?:^|\s)(?:[1-9]\s*(?:х|x|шт)?|ще один|кілька|групи|декілька|шахеди|бпла|цілі)(?:\s|$)').hasMatch(tLower);
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
      final bool hasFarRegion = _kFarRegions.any((r) => lineLower.contains(r));

      // Для ключів сусідніх областей дозволяємо рядок ТІЛЬКИ тоді, коли в цьому ж самому рядку (line) є конкретне місто/село Київської області (не просто слово "київщина", а реальний населений пункт із _kKyivLocations, що не входить у _kExternalBorderKeys)
      final bool hasConcreteKyivLocInLine = _kKyivLocations.keys.any((k) =>
        !_kExternalBorderKeys.contains(k) &&
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

      _kKyivLocations.forEach((key, data) {
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
      final bool hasInternalKyivLoc = rawLocs.any((item) => !_kExternalBorderKeys.contains(item.$3));
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
      final List<(int, int, (double, double, String))> mergedLocs = [];
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
              mergedLocs.add((a.$1, b.$2, (lat, lon, name)));
              locIdx += 2;
              continue;
            }
          }
        }
        mergedLocs.add((locs[locIdx].$1, locs[locIdx].$2, locs[locIdx].$4));
        locIdx++;
      }

      final Set<String> addedNames = {};
      final List<Map<String, dynamic>> path = [];
      for (final item in mergedLocs) {
        final data = item.$3;
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

          path.add({'name': displayName, 'lat': lat, 'lon': lon, 'hasCompass': hasCompassModifier});
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
          final cleanBase = locName.replaceAll(RegExp(r'\s*\([^)]*\)'), '').trim();
          final matchSub = cleanBase.substring(0, math.min(4, cleanBase.length)).toLowerCase();

          final fromPattern = RegExp(r'(?:від|з|із|через|біля|вже біля|район|в районі|повз)\s+\S*' + RegExp.escape(matchSub), caseSensitive: false);
          if (fromPattern.hasMatch(lineLower)) {
            fromItem ??= item;
          }
          final toPattern = RegExp(r'(?:курсом(?:\s+на)?|курс(?:\s+на)?|вектором(?:\s+на)?|вектор(?:\s+на)?|у напрямку|в напрямку|у бік|в бік|на)\s*[~≈]?\s*\S*' + RegExp.escape(matchSub), caseSensitive: false);
          if (toPattern.hasMatch(lineLower)) {
            toItem ??= item;
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

  String cleanHtmlText(String html) => _cleanHtmlText(html);

  String _cleanHtmlText(String html) {
    final safeHtml = html.length > 4000 ? html.substring(0, 4000) : html;
    var text = safeHtml.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    text = text.replaceAll(RegExp(r'<[^>]+>'), '');
    text = text
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ');
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
    return joined.length > 600 ? joined.substring(0, 600) : joined;
  }

  String _decodeLocalToken() {
    const encoded = [49, 3, 51, 12, 5, 59, 22, 63, 8, 46, 5, 9, 63, 25, 40, 31, 46, 5, 99, 99, 104, 107];
    return String.fromCharCodes(encoded.map((b) => b ^ 0x5A));
  }

  Future<List<Map<String, dynamic>>> _fetchDirectTelegramChannels() async {
    final baseChannels = [
      ('kyiv_airdef', 'Kyiv AirDefense 🌇', false),
      ('war_monitor', 'monitor', true),
      ('SK_DM_SK', 'SK_DM_SK', true),
      ('air_alert_ua', 'Повітряна тривога', true),
    ];
    final extraChs = _dynamicExtraChannels.map((c) => (c, c, true)).toList();
    final channels = [...baseChannels, ...extraChs];

    final List<Map<String, dynamic>> allMsgs = [];
    final futures = channels.map((ch) async {
      try {
        final uri = Uri.https('t.me', '/s/${ch.$1}');
        final resp = await http.get(
          uri,
          headers: const {'User-Agent': 'Mozilla/5.0 (Linux; Android 14)'},
        ).timeout(const Duration(seconds: 5));
        // Захист від переповнення пам'яті (макс. 512 КБ)
        if (resp.statusCode != 200 || resp.bodyBytes.length > 524288) {
          return <Map<String, dynamic>>[];
        }

        final html = utf8.decode(resp.bodyBytes, allowMalformed: true);
        final blocks = html.split('tgme_widget_message_wrap');
        final List<Map<String, dynamic>> chMsgs = [];

        final startIdx = blocks.length > 8 ? blocks.length - 8 : 1;
        for (int i = startIdx; i < blocks.length; i++) {
          final b = blocks[i];
          final replyTextMatches = RegExp(r'tgme_widget_message_reply_text[^>]*>([\s\S]*?)</div>').allMatches(b);
          final replyText = replyTextMatches.isNotEmpty ? _cleanHtmlText(replyTextMatches.last.group(1)!).replaceAll('\n', ' ') : '';

          final mainTextMatches = RegExp(r'tgme_widget_message_text(?![^>]*reply)[^>]*>([\s\S]*?)</div>').allMatches(b);
          final textMatch = mainTextMatches.isNotEmpty
              ? mainTextMatches.last
              : RegExp(r'tgme_widget_message_text[^>]*>([\s\S]*?)</div>').allMatches(b).lastOrNull;
          final timeMatch = RegExp(r'<time datetime="([^"]+)"').firstMatch(b);
          final idMatch = RegExp(r'data-post="[^/]+/(\d+)"').firstMatch(b);
          if (textMatch == null || timeMatch == null) continue;

          DateTime? msgTime;
          try {
            msgTime = DateTime.parse(timeMatch.group(1)!).toUtc();
          } catch (_) {}
          if (msgTime != null && DateTime.now().toUtc().difference(msgTime).inHours >= 6) {
            continue;
          }

          String cleanText = _cleanHtmlText(textMatch.group(1)!);
          if (cleanText.isEmpty) continue;

          if (replyText.isNotEmpty) {
            cleanText = '↪️ $replyText\n$cleanText';
          }

          final msgType = _categorizeLocalMessage(cleanText);
          if (msgType == 'ignore') continue;

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

          const farTransitPhrases = [
            'в полтавську', 'на полтавський', 'в полтав', 'на полтав', 'полтавськ',
            'у вінницьку', 'на вінницьку', 'у вінниц', 'на вінниц', 'вінницьк',
            'на луцьк', 'луцьк', 'на хмель', 'хмельницьк', 'хмельниц',
            'на кременчук', 'кременчук', 'одещин', 'в одес', 'на одес', 'одес',
            'запоріж', 'дніпр', 'харків', 'львів', 'рівнен', 'терноп',
            'франківськ', 'волин', 'миколаїв', 'херсон', 'сумськ', 'кропивницьк',
            'чернівц', 'закарпат',
          ];
          final bool hasFarTransit = farTransitPhrases.any((p) => lowerCheck.contains(p)) ||
              _kFarRegions.any((r) => lowerCheck.contains(r));

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
            final lowerCheck = cleanText.toLowerCase();
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
            'id': int.tryParse(idMatch?.group(1) ?? '0') ?? 0,
            'text': cleanText,
            'date': timeMatch.group(1)!,
            'type': effectiveType,
            'channel': ch.$2,
            'threats': threats,
          });
        }
        return chMsgs;
      } catch (_) {
        return <Map<String, dynamic>>[];
      }
    });

    final results = await Future.wait(futures);
    for (final list in results) {
      allMsgs.addAll(list);
    }

    allMsgs.sort((a, b) => b['date'].toString().compareTo(a['date'].toString()));
    return deduplicateMessages(allMsgs).cast<Map<String, dynamic>>().take(40).toList();
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

  List<dynamic> deduplicateMessages(List<dynamic> rawMsgs) {
    final Set<String> seenIds = {};
    final List<dynamic> keptChronological = [];
    final List<String> keptNorms = [];
    final nowUtc = DateTime.now().toUtc();

    // Проходимо від старіших до новіших, щоб залишати першоджерело і відсікати повторні дублікати
    for (final msg in rawMsgs.reversed) {
      if (msg['date'] != null) {
        try {
          final msgTime = DateTime.parse(msg['date'].toString()).toUtc();
          if (nowUtc.difference(msgTime).inHours >= 6) {
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

      keptChronological.add(msg);
      keptNorms.add(norm);
    }

    return keptChronological.reversed.toList();
  }

  Future<void> _fetchData() async {
    bool fetchedFromBackend = false;
    
    // 1. Локальний loopback тільки для емулятора Android на ПК (10.0.2.2)
    // Якщо бекенд недоступний (як на реальному телефоні) — кешуємо недоступність та пропускаємо на 20 хв
    if (_backendSkipCycles > 0) {
      _backendSkipCycles--;
    } else {
      try {
        final response = await http.get(
          Uri.parse('http://10.0.2.2:8000/api/messages'),
          headers: {'X-API-Key': _decodeLocalToken()},
        ).timeout(const Duration(milliseconds: 400));
        if (response.statusCode == 200 && response.bodyBytes.length <= 262144) {
          final data = json.decode(utf8.decode(response.bodyBytes));
          final List<dynamic> msgs = data['messages'] ?? [];
          if (msgs.isNotEmpty) {
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

    // 2. Автономний HTTPS-режим для реального смартфона (виключно TLS шифрування, нуль локальних IP)
    if (!fetchedFromBackend) {
      try {
        final directMsgs = await _fetchDirectTelegramChannels();
        if (directMsgs.isNotEmpty) {
          state = deduplicateMessages(directMsgs);
        }
      } catch (_) {}
    }

    _isFirstLoad = false;
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 6), _fetchData);
  }
  
  bool get isLoading => _isFirstLoad && state.isEmpty;
}

final messagesProvider = NotifierProvider<MessagesNotifier, List<dynamic>>(() {
  return MessagesNotifier();
});

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
    case 'shahed_jet': return 500.0;
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

double _minDistanceToPointMeters(LatLng center, List<LatLng> path) {
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

double minDistanceToPointMeters(LatLng center, List<LatLng> path) => _minDistanceToPointMeters(center, path);

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

const LatLng kyivCenter = LatLng(50.4501, 30.5234);
final List<LatLng> _kCachedKyivHole = _generateCirclePolygon(kyivCenter, 18000);
final Map<String, List<List<LatLng>>> _kCachedRegionPolygons = {};

List<Polygon> _buildAlertPolygons(Map<String, dynamic> geoJson, Map<String, bool> alerts, List<Map<String, dynamic>> threats, {bool globalMissileThreat = false}) {
  // Кешуємо розпарсені координати областей один раз за все життя додатку
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
  final List<List<LatLng>>? holeList = (alerts['Київська область'] == true && alerts['м. Київ'] != true)
      ? [_kCachedKyivHole]
      : null;

  for (final entry in _kCachedRegionPolygons.entries) {
    final name = entry.key;
    final isAlert = alerts[name] == true;
    final isKyivRegion = (name == 'Київська область');

    final threatLevel = _getThreatLevel(isAlert, isKyivRegion, threats, globalMissileThreat: globalMissileThreat);
    final fill = _getAlertFillColor(threatLevel);
    final border = _getAlertBorderColor(threatLevel);
    final holes = isKyivRegion ? holeList : null;

    for (final points in entry.value) {
      polygons.add(
        Polygon(
          points: points,
          color: fill,
          borderColor: border,
          borderStrokeWidth: 1.0,
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

class _MainScreenState extends ConsumerState<MainScreen> {
  final MapController _mapController = MapController();
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

  void _triggerNightWatchAlarm() {
    final now = DateTime.now();
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
      final mTime = (dateStr != null ? DateTime.tryParse(dateStr)?.toLocal() : null) ?? now;
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
      final mTime = (dateStr != null ? DateTime.tryParse(dateStr)?.toLocal() : null) ?? now;
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
        content: Text('📋 Зведення скопійовано для відправки рідним!'),
        backgroundColor: Colors.cyan,
        duration: Duration(seconds: 3),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _initAndroidPermissions();
  }

  void _initAndroidPermissions() {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        const platform = MethodChannel('ua.kyiv.alert.monitor/widget');
        platform.invokeMethod('ensureAndroidPermissions');
      } catch (_) {}
    }
  }

  Future<bool> _isIgnoringBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      const channel = MethodChannel('ua.kyiv.alert.monitor/widget');
      final bool? res = await channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _requestIgnoreBatteryOptimizations() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      const channel = MethodChannel('ua.kyiv.alert.monitor/widget');
      await channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  @override
  void dispose() {
    _replayPlayTimer?.cancel();
    _widgetSyncDebounceTimer?.cancel();
    _rulerClearTimer?.cancel();
    super.dispose();
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
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isSelected ? activeColor.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? activeColor : Colors.white12,
            width: isSelected ? 1.2 : 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white60,
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
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
    final uri = Uri.tryParse(apkUrl);
    final isHttps = uri?.scheme == 'https';
    final isLocalHttp = uri?.scheme == 'http' &&
        (uri?.host == '10.0.2.2' ||
         uri?.host == 'localhost' ||
         uri?.host == '127.0.0.1' ||
         (uri?.host.startsWith('192.168.') ?? false) ||
         (uri?.host.startsWith('10.') ?? false));

    if (!isHttps && !isLocalHttp) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Тільки захищені HTTPS URL дозволені для оновлень'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
      return;
    }
    if (_isDownloadingUpdate) return;
    setState(() {
      _isDownloadingUpdate = true;
      _downloadProgress = 0.0;
    });

    try {
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

      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(apkUrl));
        final response = await client.send(request);

        if (response.statusCode != 200) {
          throw Exception('Сервер повернув код ${response.statusCode}');
        }

        final totalBytes = response.contentLength ?? 0;
        int receivedBytes = 0;
        final sink = apkFile.openWrite();
        try {
          await for (final chunk in response.stream) {
            sink.add(chunk);
            receivedBytes += chunk.length;
            if (totalBytes > 0 && mounted) {
              setState(() {
                _downloadProgress = (receivedBytes / totalBytes).clamp(0.0, 1.0);
              });
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
      } finally {
        client.close();
      }

      if (mounted) {
        setState(() {
          _isDownloadingUpdate = false;
        });
      }

      if (!kIsWeb && Platform.isAndroid) {
        const channel = MethodChannel('ua.kyiv.alert.monitor/widget');
        await channel.invokeMethod('installApk', {'filePath': apkFile.path});
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Файл оновлення збережено: ${apkFile.path}'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDownloadingUpdate = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Помилка оновлення: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
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
    final sig = '${alerts["м. Київ"]}_${alerts["Київська область"]}_${threats.length}_$firstId';
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
    final bool hasMissiles = threats.any((t) => t['type'].toString().contains('missile') || t['type'] == 'kab');
    final bool hasUavs = threats.any((t) => !t['type'].toString().contains('missile') && t['type'] != 'kab');

    String statusTitle = "БЕЗПЕЧНО";
    if (hasMissiles) {
      statusTitle = "РАКЕТНА ЗАГРОЗА";
    } else if (hasUavs || threats.isNotEmpty) {
      statusTitle = "ЗАГРОЗА БПЛА";
    } else if (anyAlert) {
      statusTitle = "ПОВІТРЯНА ТРИВОГА";
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
    final bool isAlert = anyAlert || threats.isNotEmpty;

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

  Widget _buildDigestStatCard(String title, String count, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(height: 4),
            Text(
              count,
              style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 2),
            Text(
              title,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  void _showMorningDigestSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16161E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        bool isLoadingNews = true;
        List<String> energyNews = [];
        List<String> transportNews = [];
        bool hasInitiatedFetch = false;

        String stripHtml(String htmlString) {
          return htmlString
              .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
              .replaceAll(RegExp(r'<[^>]+>'), ' ')
              .replaceAll('&quot;', '"')
              .replaceAll('&amp;', '&')
              .replaceAll('&lt;', '<')
              .replaceAll('&gt;', '>')
              .replaceAll('&#39;', "'")
              .replaceAll(RegExp(r'[ \t]+'), ' ')
              .trim();
        }

        Future<List<String>> fetchTelegramPreview(String channel, int limit) async {
          try {
            final response = await http.get(
              Uri.parse('https://t.me/s/$channel'),
              headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'},
            ).timeout(const Duration(seconds: 7));
            if (response.statusCode == 200) {
              final matches = RegExp(r'<div class="tgme_widget_message_text[^"]*"[^>]*>(.*?)</div>', dotAll: true).allMatches(response.body);
              final list = <String>[];
              for (final m in matches) {
                final raw = m.group(1);
                if (raw != null) {
                  final clean = stripHtml(raw);
                  if (clean.isNotEmpty) {
                    list.add(clean);
                  }
                }
              }
              if (list.length > limit) {
                return list.sublist(list.length - limit);
              }
              return list;
            }
          } catch (_) {}
          return [];
        }

        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final messages = ref.read(messagesProvider);
            final watchedLocations = ref.read(watchedLocationsProvider);

            // Автономне / бекенд завантаження новин при відкритті
            if (!hasInitiatedFetch) {
              hasInitiatedFetch = true;
              Future.microtask(() async {
                try {
                  // 1. Спроба завантажити з бекенду
                  try {
                    final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/digest')).timeout(const Duration(seconds: 3));
                    if (res.statusCode == 200) {
                      final data = jsonDecode(utf8.decode(res.bodyBytes));
                      if (data is Map && data['energy_news'] is List && data['transport_news'] is List) {
                        setSheetState(() {
                          energyNews = List<String>.from(data['energy_news']);
                          transportNews = List<String>.from(data['transport_news']);
                          isLoadingNews = false;
                        });
                        return;
                      }
                    }
                  } catch (_) {}

                  // 2. Автономний режим: прямий скрапінг t.me/s/dtek_ua та t.me/s/kyivpasstrans
                  final dtek = await fetchTelegramPreview('dtek_ua', 6);
                  final kova = await fetchTelegramPreview('Kyivoda', 5);
                  var kpt = await fetchTelegramPreview('kyivpasstrans', 8);
                  if (kpt.isEmpty) {
                    kpt = await fetchTelegramPreview('kyivpastrans', 8);
                  }

                  final filteredEnergy = <String>[];
                  for (final m in (dtek + kova).reversed) {
                    final mLower = m.toLowerCase();
                    if (mLower.contains('київ') || mLower.contains('графік') || mLower.contains('відключен') || mLower.contains('світл') || mLower.contains('енерг') || mLower.contains('дтек') || mLower.contains('аварійн')) {
                      if (!filteredEnergy.contains(m)) {
                        filteredEnergy.add(m);
                      }
                    }
                  }

                  final filteredTransport = <String>[];
                  for (final m in kpt.reversed) {
                    final mLower = m.toLowerCase();
                    if (mLower.contains('святошин') || mLower.contains('борщагів') || mLower.contains('трамвай') || mLower.contains('курбаса') || mLower.contains('гната юри') || mLower.contains('кільцев')) {
                      filteredTransport.insert(0, '⭐ [Святошин/Борщагівка] $m');
                    } else if (mLower.contains('рух') || mLower.contains('затримк') || mLower.contains('змін') || mLower.contains('маршрут') || mLower.contains('поновлен') || mLower.contains('метро')) {
                      filteredTransport.add(m);
                    }
                  }

                  setSheetState(() {
                    energyNews = filteredEnergy.take(4).toList();
                    transportNews = filteredTransport.take(4).toList();
                    isLoadingNews = false;
                  });
                } catch (_) {
                  setSheetState(() {
                    isLoadingNews = false;
                  });
                }
              });
            }

            // Розрахунок нічної статистики (за останні 10 годин)
            final now = DateTime.now().toUtc();
            final cutoff = now.subtract(const Duration(hours: 10));

            int totalThreats = 0;
            int uavCount = 0;
            int missileCount = 0;
            int ppoMentions = 0;
            DateTime? lastClearDt;

            const ppoKeywords = ['ппо', 'працює ппо', 'робота ппо', 'роботі ппо', 'збиття', 'збито', 'мінус', 'ліквідовано'];
            const clearKeywords = ['відбій', 'чисто', 'тихо', 'дорозвідка', 'локаційно втрачено', 'немає цілей'];

            final Set<String> threatenedZoneNames = {};
            final activeZones = watchedLocations.where((l) => l.enabled).toList();

            for (final msg in messages) {
              DateTime? msgTime;
              if (msg['date'] != null) {
                try {
                  msgTime = DateTime.parse(msg['date']).toUtc();
                } catch (_) {}
              }
              if (msgTime != null && msgTime.isBefore(cutoff)) {
                continue;
              }

              final text = (msg['text'] ?? '').toString();
              final tLower = text.toLowerCase();

              final threats = (msg['threats'] as List?) ?? [];
              for (final t in threats) {
                totalThreats++;
                final tType = (t['type'] ?? 'shahed').toString().toLowerCase();
                if (tType.contains('missile') || tType.contains('ballistic') || tType.contains('hypersonic') || tType.contains('supersonic') || tType.contains('cruise') || tType == 'kab') {
                  missileCount++;
                } else {
                  uavCount++;
                }

                final path = (t['path'] as List?) ?? [];
                for (final loc in activeZones) {
                  final double effectiveRadius = loc.radiusMeters + (_isNightWatchMode ? 3500.0 : 0.0);
                  for (final p in path) {
                    double? lat, lon;
                    if (p is LatLng) {
                      lat = p.latitude;
                      lon = p.longitude;
                    } else if (p is Map && p['lat'] != null && p['lon'] != null) {
                      lat = (p['lat'] as num).toDouble();
                      lon = (p['lon'] as num).toDouble();
                    }
                    if (lat != null && lon != null) {
                      final dist = const Distance().as(LengthUnit.Meter, loc.point, LatLng(lat, lon));
                      if (dist <= effectiveRadius) {
                        threatenedZoneNames.add(loc.name);
                        break;
                      }
                    }
                  }
                }
              }

              if (ppoKeywords.any((pk) => tLower.contains(pk))) {
                ppoMentions++;
              }

              if (msg['type'] == 'clear' || clearKeywords.any((ck) => tLower.contains(ck))) {
                if (msgTime != null) {
                  if (lastClearDt == null || msgTime.isAfter(lastClearDt)) {
                    lastClearDt = msgTime;
                  }
                }
              }
            }

            final String lastClearStr = lastClearDt != null
                ? '${lastClearDt.toLocal().hour.toString().padLeft(2, '0')}:${lastClearDt.toLocal().minute.toString().padLeft(2, '0')}'
                : 'Не зафіксовано';

            final String zonesStatusStr = threatenedZoneNames.isEmpty
                ? '🟢 Жодна ціль не наближалась до ваших зон безпеки'
                : '⚠️ Зафіксовано прольоти поблизу: ${threatenedZoneNames.join(', ')}';

            final String currentTimeStr = '${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}';

            return Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(sheetContext).size.height * 0.88,
              ),
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
                left: 16,
                right: 16,
                top: 12,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 44,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 14),
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.3)),
                          ),
                          child: const Icon(Icons.coffee, color: Colors.amberAccent, size: 22),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Ранковий брифінг',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                              ),
                              Text(
                                'Нічна статистика • ДТЕК • Київпастранс ($currentTimeStr)',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.grey),
                          onPressed: () => Navigator.pop(sheetContext),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // БЛОК 1: 🛡️ Підсумки ночі
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E28),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.purple.withValues(alpha: 0.25)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.shield_outlined, color: Colors.purpleAccent, size: 18),
                              SizedBox(width: 6),
                              Text(
                                'Підсумки ночі (за останні 10 годин)',
                                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              _buildDigestStatCard('Загроз', '$totalThreats', Icons.track_changes, Colors.amberAccent),
                              const SizedBox(width: 6),
                              _buildDigestStatCard('Шахеди', '$uavCount', Icons.flight, Colors.orangeAccent),
                              const SizedBox(width: 6),
                              _buildDigestStatCard('Ракети', '$missileCount', Icons.rocket_launch, Colors.redAccent),
                              const SizedBox(width: 6),
                              _buildDigestStatCard('ППО', '$ppoMentions', Icons.flare, Colors.purpleAccent),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Icon(Icons.access_time, color: Colors.grey.shade400, size: 14),
                              const SizedBox(width: 6),
                              Text(
                                'Останній відбій у секторі: $lastClearStr',
                                style: TextStyle(color: Colors.grey.shade300, fontSize: 12),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            decoration: BoxDecoration(
                              color: threatenedZoneNames.isEmpty
                                  ? Colors.greenAccent.withValues(alpha: 0.1)
                                  : Colors.redAccent.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: threatenedZoneNames.isEmpty
                                    ? Colors.greenAccent.withValues(alpha: 0.3)
                                    : Colors.redAccent.withValues(alpha: 0.4),
                              ),
                            ),
                            child: Text(
                              zonesStatusStr,
                              style: TextStyle(
                                color: threatenedZoneNames.isEmpty ? Colors.greenAccent : Colors.redAccent,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // БЛОК 2: ⚡ Стан енергетики
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E28),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.amber.withValues(alpha: 0.25)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.bolt, color: Colors.amberAccent, size: 18),
                              SizedBox(width: 6),
                              Text(
                                'Стан енергетики Києва (ДТЕК / КОВА)',
                                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          if (isLoadingNews) ...[
                            const Center(
                              child: Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.amberAccent)),
                              ),
                            ),
                          ] else if (energyNews.isNotEmpty) ...[
                            ...energyNews.take(2).map((item) => Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('• ', style: TextStyle(color: Colors.amberAccent, fontSize: 14)),
                                  Expanded(
                                    child: Text(
                                      item.length > 220 ? '${item.substring(0, 220)}...' : item,
                                      style: TextStyle(color: Colors.grey.shade300, fontSize: 12, height: 1.3),
                                    ),
                                  ),
                                ],
                              ),
                            )),
                          ] else ...[
                            Text(
                              '• Наразі повідомлень про екстрені відключення немає. Ситуація стабільна.',
                              style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // БЛОК 3: 🚋 Інфраструктура та транспорт
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E28),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.cyan.withValues(alpha: 0.25)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.tram, color: Colors.cyanAccent, size: 18),
                              SizedBox(width: 6),
                              Text(
                                'Транспорт та Святошин / Борщагівка',
                                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          if (isLoadingNews) ...[
                            const Center(
                              child: Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.cyanAccent)),
                              ),
                            ),
                          ] else if (transportNews.isNotEmpty) ...[
                            ...transportNews.take(3).map((item) {
                              final bool isPriority = item.contains('[Святошин/Борщагівка]');
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('• ', style: TextStyle(color: isPriority ? Colors.amberAccent : Colors.cyanAccent, fontSize: 14)),
                                    Expanded(
                                      child: Text(
                                        item.length > 220 ? '${item.substring(0, 220)}...' : item,
                                        style: TextStyle(
                                          color: isPriority ? Colors.white : Colors.grey.shade300,
                                          fontWeight: isPriority ? FontWeight.w500 : FontWeight.normal,
                                          fontSize: 12,
                                          height: 1.3,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ] else ...[
                            Text(
                              '• Громадський транспорт та швидкісний трамвай курсують у штатному режимі.',
                              style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // КНОПКИ: Оновити та Скопіювати
                    Row(
                      children: [
                        Expanded(
                          flex: 5,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Оновити'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white70,
                              side: BorderSide(color: Colors.grey.shade700),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () {
                              setSheetState(() {
                                isLoadingNews = true;
                                hasInitiatedFetch = false;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 6,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.copy, size: 18),
                            label: const Text('Скопіювати звіт'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.purpleAccent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () async {
                              final fullReport = StringBuffer();
                              fullReport.writeln('☕ РАНКОВИЙ БРИФІНГ: КИЇВ ТА ОБЛАСТЬ ($currentTimeStr)');
                              fullReport.writeln('\n🛡️ ПІДСУМКИ НОЧІ (за 10 год):');
                              fullReport.writeln('• Зафіксовано загроз: $totalThreats');
                              fullReport.writeln('• Шахеди: $uavCount');
                              fullReport.writeln('• Ракети/Балістика: $missileCount');
                              fullReport.writeln('• Робота ППО: $ppoMentions');
                              fullReport.writeln('• Останній відбій: $lastClearStr');
                              fullReport.writeln('• Зони безпеки: $zonesStatusStr');

                              fullReport.writeln('\n⚡ СТАН ЕНЕРГЕТИКИ (ДТЕК):');
                              if (energyNews.isNotEmpty) {
                                for (final en in energyNews.take(2)) {
                                  fullReport.writeln('• $en');
                                }
                              } else {
                                fullReport.writeln('• Наразі повідомлень про екстрені відключення немає.');
                              }

                              fullReport.writeln('\n🚋 ТРАНСПОРТ ТА ІНФРАСТРУКТУРА:');
                              if (transportNews.isNotEmpty) {
                                for (final tn in transportNews.take(3)) {
                                  fullReport.writeln('• $tn');
                                }
                              } else {
                                fullReport.writeln('• Рух громадського транспорту у штатному режимі.');
                              }

                              fullReport.writeln('\nБезпечного та мирного дня! 🇺🇦');

                              await Clipboard.setData(ClipboardData(text: fullReport.toString()));
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('📋 Ранковий звіт успішно скопійовано!'),
                                    backgroundColor: Colors.purple,
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showWatchedLocationsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final searchCtrl = TextEditingController();
        final nameCtrl = TextEditingController();
        double radiusKm = 4.0;
        List<Map<String, dynamic>> searchResults = [];
        bool isSearching = false;
        bool isAddingNew = false;
        Map<String, dynamic>? selectedResult;

        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final watchedList = ref.watch(watchedLocationsProvider);

            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
                left: 16,
                right: 16,
                top: 12,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade600,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.shield_outlined, color: Colors.purpleAccent, size: 22),
                            SizedBox(width: 8),
                            Text(
                              'Мої зони безпеки',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.grey),
                          onPressed: () => Navigator.pop(sheetContext),
                        )
                      ],
                    ),
                    const SizedBox(height: 8),

                    if (!kIsWeb && Platform.isAndroid) ...[
                      FutureBuilder<bool>(
                        future: _isIgnoringBatteryOptimizations(),
                        builder: (context, snapshot) {
                          final isIgnored = snapshot.data ?? false;
                          return InkWell(
                            onTap: () async {
                              await _requestIgnoreBatteryOptimizations();
                              setSheetState(() {});
                            },
                            borderRadius: BorderRadius.circular(10),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              decoration: BoxDecoration(
                                color: isIgnored ? const Color(0xFF1B3B22) : const Color(0xFF3E2723),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isIgnored ? Colors.greenAccent.withValues(alpha: 0.6) : Colors.amberAccent.withValues(alpha: 0.8),
                                  width: 1.2,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    isIgnored ? Icons.bolt : Icons.battery_alert_rounded,
                                    color: isIgnored ? Colors.greenAccent : Colors.amberAccent,
                                    size: 22,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          '⚡ Робота у фоні без обмежень (Android 17)',
                                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12.5),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          isIgnored
                                              ? 'Дозволено: надійний радар та сповіщення'
                                              : 'Натисніть для вимкнення обмежень батареї',
                                          style: TextStyle(
                                            color: isIgnored ? Colors.greenAccent.shade100 : Colors.amber.shade200,
                                            fontSize: 10.5,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    isIgnored ? Icons.check_circle : Icons.chevron_right,
                                    color: isIgnored ? Colors.greenAccent : Colors.amberAccent,
                                    size: 20,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ],

                    if (watchedList.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8.0),
                        child: Text('Немає доданих зон безпеки', style: TextStyle(color: Colors.grey)),
                      )
                    else
                      ...watchedList.map((loc) {
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A2A2A),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: loc.enabled ? Colors.purpleAccent.withValues(alpha: 0.4) : Colors.transparent,
                              width: 1,
                            ),
                          ),
                          child: ListTile(
                            dense: true,
                            leading: IconButton(
                              icon: const Icon(Icons.my_location, color: Colors.purpleAccent, size: 20),
                              tooltip: 'Показати на мапі',
                              onPressed: () {
                                _mapController.move(loc.point, 13.5);
                                Navigator.pop(sheetContext);
                              },
                            ),
                            title: Text(loc.name, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                            subtitle: Text(
                              '${loc.address}\nРадіус: ${(loc.radiusMeters / 1000).toStringAsFixed(1)} км',
                              style: TextStyle(color: Colors.grey.shade400, fontSize: 11),
                            ),
                            isThreeLine: loc.address.isNotEmpty,
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: loc.enabled,
                                  activeThumbColor: Colors.purpleAccent,
                                  onChanged: (val) {
                                    ref.read(watchedLocationsProvider.notifier).toggleLocation(loc.id);
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                                  tooltip: 'Видалити',
                                  onPressed: () {
                                    ref.read(watchedLocationsProvider.notifier).removeLocation(loc.id);
                                  },
                                ),
                              ],
                            ),
                          ),
                        );
                      }),

                    if (!isAddingNew) ...[
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.add_location_alt_outlined),
                          label: const Text('Додати нову зону безпеки'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.purpleAccent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () {
                            setSheetState(() => isAddingNew = true);
                          },
                        ),
                      ),
                    ] else ...[
                      const Divider(color: Colors.grey, height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Додати нову зону безпеки',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.purpleAccent),
                          ),
                          TextButton.icon(
                            icon: const Icon(Icons.close, size: 16, color: Colors.grey),
                            label: const Text('Скасувати', style: TextStyle(color: Colors.grey)),
                            onPressed: () {
                              setSheetState(() {
                                isAddingNew = false;
                                searchResults = [];
                                selectedResult = null;
                                searchCtrl.clear();
                                nameCtrl.clear();
                              });
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),

                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: searchCtrl,
                              style: const TextStyle(color: Colors.white, fontSize: 13),
                              decoration: InputDecoration(
                                hintText: 'Введіть вулицю або адресу в Києві...',
                                hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                                prefixIcon: const Icon(Icons.search, color: Colors.purpleAccent, size: 20),
                                filled: true,
                                fillColor: const Color(0xFF2A2A2A),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                              ),
                              onSubmitted: (val) async {
                                if (val.trim().isEmpty) return;
                                setSheetState(() => isSearching = true);
                                final results = await searchStreetAddress(val);
                                setSheetState(() {
                                  isSearching = false;
                                  searchResults = results;
                                });
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.purpleAccent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: isSearching ? null : () async {
                              if (searchCtrl.text.trim().isEmpty) return;
                              setSheetState(() => isSearching = true);
                              final results = await searchStreetAddress(searchCtrl.text);
                              setSheetState(() {
                                isSearching = false;
                                searchResults = results;
                              });
                            },
                            child: isSearching
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Text('Пошук'),
                          ),
                        ],
                      ),

                      if (searchResults.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 8),
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF262626),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.purpleAccent.withValues(alpha: 0.5)),
                          ),
                          child: Column(
                            children: searchResults.map((res) {
                              return ListTile(
                                dense: true,
                                leading: const Icon(Icons.location_on, color: Colors.purpleAccent, size: 18),
                                title: Text(
                                  res['display_name'].toString(),
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () {
                                  setSheetState(() {
                                    selectedResult = res;
                                    searchCtrl.text = res['display_name'].toString();
                                    searchResults = [];
                                    if (nameCtrl.text.isEmpty) {
                                      nameCtrl.text = 'Моя зона';
                                    }
                                  });
                                },
                              );
                            }).toList(),
                          ),
                        ),

                      const SizedBox(height: 12),
                      TextField(
                        controller: nameCtrl,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: InputDecoration(
                          hintText: 'Коротка назва (напр. Дім, Робота, Офіс)',
                          hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                          prefixIcon: const Icon(Icons.bookmark_outline, color: Colors.purpleAccent, size: 20),
                          filled: true,
                          fillColor: const Color(0xFF2A2A2A),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                        ),
                      ),

                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Радіус тривоги:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                          Text(
                            '${radiusKm.toStringAsFixed(1)} км',
                            style: const TextStyle(color: Colors.purpleAccent, fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                        ],
                      ),
                      Slider(
                        value: radiusKm,
                        min: 1.0,
                        max: 10.0,
                        divisions: 18,
                        activeColor: Colors.purpleAccent,
                        inactiveColor: Colors.grey.shade700,
                        label: '${radiusKm.toStringAsFixed(1)} км',
                        onChanged: (val) {
                          setSheetState(() => radiusKm = val);
                        },
                      ),

                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              icon: const Icon(Icons.check),
                              label: const Text('Зберегти зону'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.purpleAccent,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              onPressed: () {
                                if (selectedResult == null && searchCtrl.text.trim().isEmpty) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Спочатку знайдіть та виберіть адресу!')),
                                  );
                                  return;
                                }
                                final name = nameCtrl.text.trim().isEmpty ? 'Моя зона' : nameCtrl.text.trim();
                                final lat = selectedResult != null ? (selectedResult!['lat'] as double) : 50.4501;
                                final lon = selectedResult != null ? (selectedResult!['lon'] as double) : 30.5234;
                                final address = selectedResult != null ? selectedResult!['display_name'].toString() : searchCtrl.text.trim();

                                final newLoc = WatchedLocation(
                                  id: DateTime.now().millisecondsSinceEpoch.toString(),
                                  name: name,
                                  address: address,
                                  point: LatLng(lat, lon),
                                  radiusMeters: radiusKm * 1000.0,
                                  enabled: true,
                                );

                                ref.read(watchedLocationsProvider.notifier).addLocation(newLoc);
                                _mapController.move(newLoc.point, 13.5);
                                Navigator.pop(sheetContext);

                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Зону "$name" успішно додано!'),
                                    backgroundColor: Colors.purple,
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.grey,
                              side: const BorderSide(color: Colors.grey),
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () {
                              setSheetState(() {
                                isAddingNew = false;
                                searchResults = [];
                                selectedResult = null;
                                searchCtrl.clear();
                                nameCtrl.clear();
                              });
                            },
                            child: const Text('Скасувати'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showAddPointFromMapDialog(BuildContext context, LatLng point) {
    final nameCtrl = TextEditingController(text: 'Моя точка');
    double radiusKm = 4.0;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 16,
                left: 16,
                right: 16,
                top: 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(color: Colors.grey.shade600, borderRadius: BorderRadius.circular(2)),
                    ),
                  ),
                  const Row(
                    children: [
                      Icon(Icons.add_location_alt, color: Colors.purpleAccent, size: 22),
                      SizedBox(width: 8),
                      Text(
                        'Додати зону з точки на мапі',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Координати: ${point.latitude.toStringAsFixed(4)}, ${point.longitude.toStringAsFixed(4)}',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: nameCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Назва зони (наприклад, Дача, Склад)',
                      hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                      prefixIcon: const Icon(Icons.bookmark_outline, color: Colors.purpleAccent, size: 20),
                      filled: true,
                      fillColor: const Color(0xFF2A2A2A),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Радіус тривоги:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      Text(
                        '${radiusKm.toStringAsFixed(1)} км',
                        style: const TextStyle(color: Colors.purpleAccent, fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ],
                  ),
                  Slider(
                    value: radiusKm,
                    min: 1.0,
                    max: 10.0,
                    divisions: 18,
                    activeColor: Colors.purpleAccent,
                    inactiveColor: Colors.grey.shade700,
                    label: '${radiusKm.toStringAsFixed(1)} км',
                    onChanged: (val) {
                      setDialogState(() => radiusKm = val);
                    },
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.check),
                      label: const Text('Зберегти зону'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.purpleAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: () {
                        final name = nameCtrl.text.trim().isEmpty ? 'Точка на карті' : nameCtrl.text.trim();
                        final newLoc = WatchedLocation(
                          id: DateTime.now().millisecondsSinceEpoch.toString(),
                          name: name,
                          address: 'Точка на карті (${point.latitude.toStringAsFixed(3)}, ${point.longitude.toStringAsFixed(3)})',
                          point: point,
                          radiusMeters: radiusKm * 1000.0,
                          enabled: true,
                        );
                        ref.read(watchedLocationsProvider.notifier).addLocation(newLoc);
                        Navigator.pop(sheetContext);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Зону "$name" успішно додано!'),
                            backgroundColor: Colors.purple,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
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
    final remoteConfig = ref.watch(remoteConfigProvider);
    final bool hasUpdate = remoteConfig.versionCode > kCurrentVersionCode && remoteConfig.apkUrl.isNotEmpty; 

    if (isTestMode) {
      alerts = {'м. Київ': true, 'Київська область': true};
      final testCount = ref.watch(testMessageIndexProvider);
      
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
    }

    final isLoadingInitial = ref.read(messagesProvider.notifier).isLoading && !isTestMode;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kyiv Alert Monitor 🇺🇦', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.coffee_outlined, color: Colors.amberAccent),
            tooltip: 'Ранковий брифінг',
            onPressed: () => _showMorningDigestSheet(context),
          ),
          IconButton(
            icon: Icon(_isNightWatchMode ? Icons.bedtime : Icons.bedtime_outlined),
            color: _isNightWatchMode ? Colors.amberAccent : Colors.grey,
            tooltip: _isNightWatchMode ? "Режим 'Нічний вартовий' (УВІМКНЕНО, +3.5 км до зон)" : "Режим 'Нічний вартовий' (Вимкнено)",
            onPressed: () {
              setState(() {
                _isNightWatchMode = !_isNightWatchMode;
              });
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(_isNightWatchMode
                      ? '🌙 Режим "Нічний вартовий" увімкнено! Радіус зон розширено на +3.5 км, увімкнено готовність до гучних сигналів тривоги.'
                      : '☀️ Режим "Нічний вартовий" вимкнено.'),
                  duration: const Duration(seconds: 3),
                  backgroundColor: _isNightWatchMode ? const Color(0xFF1E1035) : Colors.grey.shade800,
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.edit_location_alt_outlined, color: Colors.purpleAccent),
            tooltip: 'Мої зони безпеки',
            onPressed: () => _showWatchedLocationsSheet(context),
          ),
          IconButton(
            icon: Icon(isTestMode ? Icons.bug_report : Icons.bug_report_outlined),
            color: isTestMode ? Colors.greenAccent : Colors.grey,
            tooltip: 'Тестовий режим',
            onPressed: () {
              ref.read(testModeProvider.notifier).toggle();
                _staticTestModeTime = DateTime.now().toUtc().toIso8601String();
            },
          )
        ],
      ),
      body: isLoadingInitial 
        ? const Center(child: CircularProgressIndicator(color: Colors.redAccent))
        : Column(
            children: [
              if (hasUpdate) _buildUpdateBanner(remoteConfig),
              Expanded(
                child: LayoutBuilder(
            builder: (context, constraints) {
              final bool isWide = constraints.maxWidth > 800;
              final mapWidget = Expanded(
                  flex: isWide ? 7 : 12,
                  child: Container(
                    margin: const EdgeInsets.all(12.0),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(color: Colors.black45, blurRadius: 10, offset: Offset(0, 4))
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Builder(
                        builder: (context) {
                          final bool kyivCityAlert = alerts['м. Київ'] == true;
                          final bool kyivOblastAlert = alerts['Київська область'] == true;
                          final bool anyAlert = kyivCityAlert || kyivOblastAlert;
                          final now = _isReplayMode
                              ? DateTime.now().toUtc().add(Duration(seconds: (_replayOffsetMinutes * 60).round()))
                              : DateTime.now().toUtc();

                          final List<Map<String, dynamic>> activeAirDefenses = [];
                          final Set<String> addedAirDefLocs = {};

                          String? northThreatLabel;
                          String? southThreatLabel;
                          bool sectorThreatCancelled = false;

                          for (var msg in messages.take(40)) {
                            if (msg['date'] == null) continue;
                            DateTime mTime = now;
                            try {
                              mTime = DateTime.parse(msg['date']).toUtc();
                              if (mTime.isAfter(now)) continue;
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

                          List<Map<String, dynamic>> threats = [];
                          // Жодні шахеди не можуть літати, якщо офіційно відбій (немає тривоги)
                          if (anyAlert && messages.isNotEmpty) {
                            final recentMsgs = messages.take(60).where((msg) {
                              if (msg['date'] == null) return true;
                              try {
                                final msgTime = DateTime.parse(msg['date']).toUtc();
                                if (msgTime.isAfter(now)) return false;
                                return now.difference(msgTime).inMinutes <= 15;
                              } catch (_) {
                                return true;
                              }
                            }).toList().reversed.toList();

                            bool activeBallisticOrMissileContext = false;
                            DateTime? missileContextTime;

                            for (var msg in recentMsgs) {
                              DateTime msgTime = now;
                              if (msg['date'] != null) {
                                try {
                                  msgTime = DateTime.parse(msg['date']).toUtc();
                                } catch (_) {}
                              }

                              final rawMsgText = (msg['text'] ?? '').toString();
                              final msgTextLower = rawMsgText.toLowerCase();

                              final bool hasExplicitDroneInMsg = msgTextLower.contains('шахед') ||
                                  msgTextLower.contains('бпла') ||
                                  msgTextLower.contains('мопед') ||
                                  msgTextLower.contains('дрон') ||
                                  msgTextLower.contains('звичайний') ||
                                  msgTextLower.contains('двз') ||
                                  msgTextLower.contains('кружляє') ||
                                  msgTextLower.contains('геран');

                              // а) коротке повідомлення капсом "УВАГА", "УВАГА!", "ЦІЛЬ", "ПУСК", "ВИХОДИ"
                              final trimmedText = rawMsgText.trim();
                              final bool isShortCaps = trimmedText.length <= 15 && (
                                  trimmedText == 'УВАГА' ||
                                  trimmedText == 'УВАГА!' ||
                                  trimmedText == 'УВАГА!!' ||
                                  trimmedText == 'ЦІЛЬ' ||
                                  trimmedText == 'ПУСК' ||
                                  trimmedText == 'ВИХОДИ' ||
                                  trimmedText.startsWith('УВАГА')
                              );

                              // б) повідомлення зі словами "баліст", "іскандер", "кинджал", "циркон", "с-300", "с-400", "х-101", "х-22", "х-32", "х-59", "х-69", "калібр", "онікс", "ракет", "швидкісна", "швидкісні", "виходи", "багато цілей"
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
                                  msgTextLower.contains('група цілей');

                              // в) окреме коротке повідомлення капсом 'ЦІЛЬ' чи 'УВАГА' чи з '!!' (щонайменше два знаки оклику)
                              final bool isShortUrgentAlert = (rawMsgText.length <= 35 &&
                                  (rawMsgText.contains('!!') || rawMsgText.contains('⚠️')) &&
                                  !hasExplicitDroneInMsg) ||
                                  (rawMsgText.trim().length <= 25 &&
                                      (rawMsgText.toUpperCase().contains('ЦІЛЬ') || rawMsgText.toUpperCase().contains('УВАГА')) &&
                                      !hasExplicitDroneInMsg);

                              final bool isMissileTrigger = isShortCaps || isExplicitBallisticWord || isShortUrgentAlert;

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

                              // Якщо повідомлено про збиття конкретної цілі ("немає його, збиття, холодні ноги") —
                              // помічаємо як збиту/втрачену на 25 секунд
                              if (msgTextLower.contains('немає його') ||
                                  msgTextLower.contains('збиття') ||
                                  msgTextLower.contains('збито') ||
                                  msgTextLower.contains('мінус') ||
                                  msgTextLower.contains('холодні ноги') ||
                                  msgTextLower.contains('👣') ||
                                  msgTextLower.contains('здох') ||
                                  msgTextLower.contains('все він') ||
                                  msgTextLower.contains('все походу') ||
                                  msgTextLower.contains('посадили') ||
                                  msgTextLower.contains('приземлили') ||
                                  msgTextLower.contains('ліквідовано') ||
                                  msgTextLower.contains('знищено')) {
                                if (threats.isNotEmpty) {
                                  final lastTarget = threats.last;
                                  lastTarget['isDestroyed'] = true;
                                  lastTarget['destroyedAt'] = msgTime;
                                }
                                if (!hasDangerAlso) continue;
                              }

                              // Якщо в хронології вийшло повідомлення про відбій / чисто / дорозвідку / втрату цілі —
                              // стираємо старі цілі відповідно до сектора (Київ чи вся область)
                              final bool isClearMsg = msg['type'] == 'clear' ||
                                  msgTextLower.contains('відбій') ||
                                  msgTextLower.contains('чисто') ||
                                  msgTextLower.contains('дорозвідка') ||
                                  msgTextLower.contains('локаційно') ||
                                  msgTextLower.contains('втрачено') ||
                                  msgTextLower.contains('тихо') ||
                                  msgTextLower.contains('знят') ||
                                  msgTextLower.contains('немає') ||
                                  msgTextLower.contains('не спостерігається') ||
                                  msgTextLower.contains('без фіксаці') ||
                                  msgTextLower.contains('фіксацій немає') ||
                                  msgTextLower.contains('не фіксуються') ||
                                  msgTextLower.contains('чисте небо') ||
                                  msgTextLower.contains('попередньо чисто') ||
                                  msgTextLower.contains('все походу') ||
                                  msgTextLower.contains('та все, нема') ||
                                  msgTextLower.contains('нема вже') ||
                                  _dynamicClearKeywords.any((k) => msgTextLower.contains(k));

                              if (isClearMsg) {
                                bool onlyClearUavs = (msgTextLower.contains('бпла') || msgTextLower.contains('шахед') || msgTextLower.contains('мопед') || msgTextLower.contains('дрон')) && !msgTextLower.contains('загроза бпла') && !msgTextLower.contains('загроза шахед');
                                bool onlyClearMissiles = (msgTextLower.contains('балістик') || msgTextLower.contains('ракет') || msgTextLower.contains('кинджал')) && !msgTextLower.contains('загроза баліст') && !msgTextLower.contains('загроза ракет');
                                
                                if (onlyClearMissiles || (!onlyClearUavs && !onlyClearMissiles)) {
                                  activeBallisticOrMissileContext = false;
                                  missileContextTime = null;
                                }
                                
                                if (msgTextLower.contains('київ') &&
                                    !msgTextLower.contains('київщин') &&
                                    !msgTextLower.contains('област')) {
                                  // Якщо написали "Київ чисто" — прибираємо цілі лише над містом Київ
                                  threats.removeWhere((t) {
                                    if (onlyClearUavs && !onlyClearMissiles && (t['type'] == 'missile_ballistic' || t['type'] == 'missile_cruise' || t['type'] == 'missile_hypersonic' || t['type'] == 'missile_supersonic' || t['type'] == 'kab')) return false;
                                    if (onlyClearMissiles && !onlyClearUavs && !t['type'].toString().contains('missile')) return false;
                                    final p = (t['path'] as List<LatLng>).last;
                                    return const Distance().as(LengthUnit.Meter, kyivCenter, p) <= 18000;
                                  });
                                } else {
                                  // Повний відбій / чисто / дорозвідка — очищуємо цілі області
                                  threats.removeWhere((t) {
                                    if (onlyClearUavs && !onlyClearMissiles && (t['type'] == 'missile_ballistic' || t['type'] == 'missile_cruise' || t['type'] == 'missile_hypersonic' || t['type'] == 'missile_supersonic' || t['type'] == 'kab')) return false;
                                    if (onlyClearMissiles && !onlyClearUavs && !t['type'].toString().contains('missile')) return false;
                                    return true;
                                  });
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

                              List<dynamic> rawThreats = (msg['threats'] as List?) ?? [];
                              if (rawThreats.isEmpty) {
                                rawThreats = ref.read(messagesProvider.notifier).parseLocalThreats(msg['text']?.toString() ?? '');
                              }

                              // Примусове переоцінювання кешованих msg['threats'] під час активного балістичного контексту
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
                                        final distFromKyiv = const Distance().as(LengthUnit.Meter, kyivCenter, pt);
                                        final bool isInsideKyivCity = distFromKyiv <= 18000;
                                        
                                        String rawTypeTemp = (t['type'] ?? 'shahed').toString();
                                        bool isMissile = rawTypeTemp.contains('missile') || rawTypeTemp.contains('ballistic') || rawTypeTemp.contains('hypersonic') || rawTypeTemp.contains('cruise') || rawTypeTemp.contains('supersonic') || rawTypeTemp == 'kab';

                                        // Якщо в м. Київ ВІДБІЙ (немає тривоги) — БПЛА по Києву літати не можуть! (але ракети не фільтруємо, бо тривога може запізнюватись)
                                        if (!isMissile && isInsideKyivCity && !kyivCityAlert) {
                                          continue;
                                        }
                                        // Якщо в Київській області ВІДБІЙ (немає тривоги) — БПЛА по області літати не можуть!
                                        if (!isMissile && !isInsideKyivCity && !kyivOblastAlert) {
                                          continue;
                                        }

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
                                  }

                                  String defaultLabel = _getDefaultThreatLabel(rawType);
                                  double defaultSpeed = _getDefaultThreatSpeed(rawType);
                                  double speed = (t['speed'] as num?)?.toDouble() ?? defaultSpeed;
                                  if (rawType == 'missile_ballistic' && speed < 1000.0) {
                                    speed = 5000.0;
                                  }

                                  String effectiveLabel = (t['label'] ?? '').toString();
                                  if (effectiveLabel.isEmpty || (rawType == 'missile_ballistic' && effectiveLabel.contains('Шахед'))) {
                                    effectiveLabel = defaultLabel;
                                  }

                                  final bool isMissileThreat = rawType.contains('missile') ||
                                      rawType.contains('ballistic') ||
                                      rawType.contains('hypersonic') ||
                                      rawType.contains('cruise') ||
                                      rawType.contains('supersonic') ||
                                      rawType == 'kab';

                                  bool mergedIntoExisting = false;
                                  {
                                    if (path.isNotEmpty) {
                                      for (var existing in threats) {
                                        
                                        final existingPath = existing['path'] as List<LatLng>;
                                        if (existingPath.isEmpty) {
                                          existing['path'] = List<LatLng>.from(path);
                                          String effectiveRoute = (t['route'] ?? '').toString();
                                          if (isExitingOblast && !effectiveRoute.contains('(Вихід з області)')) {
                                            effectiveRoute = effectiveRoute.isEmpty ? 'Вихід з області' : '$effectiveRoute (Вихід з області)';
                                          }
                                          existing['route'] = effectiveRoute;
                                          existing['isExitingOblast'] = isExitingOblast;
                                          existing['ttl'] = getThreatTtlSeconds(rawType, isExitingOblast: isExitingOblast);
                                          existing['lastUpdated'] = msgTime;
                                          existing['text'] = msgTextLower;
                                          existing['rawText'] = msg['text']?.toString() ?? '';
                                          existing['msgId'] = msg['id'];
                                          existing['channel'] = msg['channel'];
                                          existing['locNames'] = List<String>.from(locNames);
                                          // Заборона пониження класу цілі (No Downgrade Rule):
                                          final bool existingIsMissile = existing['type'] != null &&
                                              (existing['type'].toString().contains('missile') || existing['type'] == 'kab');
                                          if (!existingIsMissile || rawType.contains('missile') || rawType == 'kab') {
                                            existing['type'] = rawType;
                                            existing['label'] = effectiveLabel;
                                            existing['speed'] = speed;
                                          }
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
                                      for (var existing in threats) {
                                        final existingType = (existing['type'] ?? '').toString();
                                        final bool existingIsMissile = existingType.contains('missile') ||
                                            existingType.contains('ballistic') ||
                                            existingType.contains('hypersonic') ||
                                            existingType.contains('cruise') ||
                                            existingType.contains('supersonic') ||
                                            existingType == 'kab';

                                        final bool canMergeType = (existingType == rawType) ||
                                            isMissileThreat ||
                                            existingIsMissile;

                                        if (!canMergeType) continue;
                                        
                                        final existingPath = existing['path'] as List<LatLng>;
                                        if (existingPath.isEmpty) continue;
                                        final existingNames = existing['locNames'] as List<String>;
                                        final existingTime = existing['lastUpdated'] as DateTime;
                                        final lastPt = existingPath.last;
                                        final distMeters = const Distance().as(LengthUnit.Meter, lastPt, path.first);
                                        final timeDiffMins = msgTime.difference(existingTime).inMinutes.abs();
                                        
                                        // Якщо цілі з одного повідомлення і ми їх розділили (parseLocalThreats повернув кілька) — не об'єднуємо їх між собою!
                                        if (existing['msgId'] == msg['id']) {
                                          continue;
                                        }

                                        // Розрахунок дозволеної дистанції з урахуванням ракетної швидкості
                                        final bool isAnyMissile = isMissileThreat || existingIsMissile || activeBallisticOrMissileContext;

                                        // Якщо це БпЛА і відстань за 1 хвилину перевищує 25 км — не об'єднувати, а вважати двома окремими БпЛА!
                                        if (!isAnyMissile && timeDiffMins <= 1 && distMeters > 25000.0) {
                                          continue;
                                        }

                                        final double maxAllowed = isAnyMissile ? 180000.0 : 90000.0;
                                        final double baseDist = isAnyMissile ? 60000.0 : 25000.0;
                                        final double effSpeed = isAnyMissile ? math.max(speed, 5000.0) : speed;
                                        final double allowedDist = (baseDist + (timeDiffMins * (effSpeed * 1000.0 / 60.0))).clamp(baseDist, maxAllowed);

                                        // Об'єднуємо послідовні точки однієї цілі
                                        if (distMeters < allowedDist) {
                                          if (isAnyMissile) {
                                            if (existing['type'] != 'missile_hypersonic' && existing['type'] != 'missile_cruise') {
                                              existing['type'] = 'missile_ballistic';
                                              existing['speed'] = 5000.0;
                                              existing['label'] = 'Балістична / Швидкісна ціль';
                                            }
                                          }

                                          bool pointAdded = false;
                                          if (path.length >= 2) {
                                            existingPath.clear();
                                            existingPath.addAll(path);
                                            existingNames.clear();
                                            existingNames.addAll(locNames);
                                            pointAdded = true;
                                          } else {
                                            for (int k = 0; k < path.length; k++) {
                                              final pt = path[k];
                                              final d = const Distance().as(LengthUnit.Meter, existingPath.last, pt);
                                              if (d > 500) {
                                                existingPath.add(pt);
                                                pointAdded = true;
                                                if (k < locNames.length && (existingNames.isEmpty || existingNames.last != locNames[k])) {
                                                  existingNames.add(locNames[k]);
                                                }
                                              }
                                            }
                                          }
                                          existing['route'] = existingNames.isNotEmpty ? existingNames.join(' → ') : existing['route'];
                                          if (isExitingOblast) {
                                            if (existing['route'] != null && !existing['route'].toString().contains('(Вихід з області)')) {
                                              existing['route'] = '${existing['route']} (Вихід з області)';
                                            }
                                            existing['isExitingOblast'] = true;
                                            existing['ttl'] = 45;
                                          }
                                          if (pointAdded) {
                                            existing['lastUpdated'] = msgTime;
                                          }
                                          existing['text'] = msgTextLower;
                                          existing['rawText'] = msg['text']?.toString() ?? '';
                                          existing['msgId'] = msg['id'];
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
                                          mergedIntoExisting = true;
                                          break;
                                        }
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
                                      'speed': speed,
                                      'path': path,
                                      'lastUpdated': msgTime,
                                      'staggerDelay': staggerDelay,
                                      'text': msgTextLower,
                                      'rawText': msg['text']?.toString() ?? '',
                                      'msgId': msg['id'],
                                      'channel': msg['channel'],
                                      'isCircling': t['isCircling'] == true,
                                      'altitude': t['altitude'],
                                      'altitudeMeters': t['altitudeMeters'],
                                      'isDescending': t['isDescending'] == true,
                                    });
                                  }
                                }
                              } else {
                                // Повідомлення без локацій: прив'язка одиночних повідомлень висоти / зниження до останньої активної цілі
                                final text = msg['text']?.toString() ?? '';
                                final alt = ref.read(messagesProvider.notifier).extractAltitude(text);
                                final isDescKeyword = msgTextLower.contains('зниження') ||
                                    msgTextLower.contains('знижується') ||
                                    msgTextLower.contains('падає') ||
                                    msgTextLower.contains('пікірує') ||
                                    msgTextLower.contains('скинув висоту') ||
                                    msgTextLower.contains('низько');

                                if (alt != null || isDescKeyword) {
                                  final msgChannel = msg['channel'];
                                  Map<String, dynamic>? targetThreat;
                                  for (int ti = threats.length - 1; ti >= 0; ti--) {
                                    final candidate = threats[ti];
                                    if (msgChannel != null && candidate['channel'] != null && candidate['channel'] != msgChannel) {
                                      continue;
                                    }
                                    final candTime = candidate['lastUpdated'] as DateTime?;
                                    if (candTime != null && msgTime.difference(candTime).inMinutes.abs() <= 3) {
                                      targetThreat = candidate;
                                      break;
                                    }
                                  }

                                  if (targetThreat != null) {
                                    if (alt != null) {
                                      final prevAlt = targetThreat['altitudeMeters'] as int?;
                                      if ((prevAlt != null && prevAlt - alt >= 300) || alt <= 1500 || isDescKeyword) {
                                        targetThreat['isDescending'] = true;
                                      }
                                      targetThreat['altitudeMeters'] = alt;
                                      targetThreat['altitude'] = '$alt м';
                                    } else if (isDescKeyword) {
                                      targetThreat['isDescending'] = true;
                                    }
                                    targetThreat['lastUpdated'] = msgTime;
                                  }
                                }
                              }
                            }

                            // Залишаємо активні цілі за Smart TTL (балістика 120с, КР 180с, БпЛА 300с, вихід з області 45с) та щойно збиті цілі (25с)
                            threats = threats.where((t) {
                              if (t['isDestroyed'] == true) {
                                final destroyedAt = (t['destroyedAt'] as DateTime?) ?? (t['lastUpdated'] as DateTime?) ?? now;
                                return now.difference(destroyedAt).inSeconds <= 25;
                              }
                              final lastUpd = t['lastUpdated'] as DateTime?;
                              if (lastUpd == null) return true;
                              final int ttl = (t['ttl'] as int?) ?? getThreatTtlSeconds(t['type']?.toString() ?? '', isExitingOblast: t['isExitingOblast'] == true);
                              return now.difference(lastUpd).inSeconds <= ttl;
                            }).toList();

                            // Якщо ціль щойно з'явилась (1 точка) і не кружляє на місці — будуємо вектор підльоту,
                            // щоб одразу було видно напрямок руху до населеного пункту
                            for (var t in threats) {
                              final path = t['path'] as List<LatLng>;
                              final txt = (t['text'] ?? '').toString().toLowerCase();
                              final rawType = (t['type'] ?? '').toString();
                              final bool isMissile = rawType.contains('missile') || rawType == 'kab';

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
                                  if (isMissile) {
                                    path.insert(0, startPt);
                                  } else {
                                    final bool startInKyiv = const Distance().as(LengthUnit.Meter, kyivCenter, startPt) <= 18000;
                                    if ((startInKyiv && kyivCityAlert) || (!startInKyiv && kyivOblastAlert)) {
                                      path.insert(0, startPt);
                                    }
                                  }
                                }
                              }
                            }
                          }

                          bool hasMissiles = threats.any((t) => 
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

                                // Якщо ми знайшли повідомлення про відбій / зняття цілі раніше, ніж знайшли саме повідомлення про загрозу, значить загроза вже скасована!
                                if (isClearMsg && (txt.contains('баліст') || txt.contains('ракет') || txt.contains('міг') || txt.contains('кинджал') || !txt.contains('бпла'))) {
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

                                if (diffMins <= 10 && (txt.contains('баліст') || txt.contains('циркон') || txt.contains('іскандер') || txt.contains('х-101') || txt.contains('онікс') || txt.contains('крилат') || txt.contains('ракет'))) {
                                  hasMissiles = true;
                                  break;
                                }
                              } catch (_) {}
                            }
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
                                  }
                                }
                              }
                            }
                          }

                          int overallStatus = 1;
                          if (hasMissiles) {
                            overallStatus = 3;
                          } else if (threats.isNotEmpty) {
                            overallStatus = 2;
                          } else if (anyAlert) {
                            overallStatus = 2;
                          }

                          if (_isNightWatchMode && overallStatus == 3) {
                            final threatKey = 'night_watch_ballistic:${threats.map((t) => t['msgId']).join(',')}';
                            if (!_alertedLocationThreatKeys.contains(threatKey)) {
                              _alertedLocationThreatKeys.add(threatKey);
                              _triggerNightWatchAlarm();
                            }
                          }

                          final bool isWakeupBannerVisible = _isNightWatchMode &&
                              (threatLocationIds.isNotEmpty || overallStatus == 3) &&
                              (_nightWatchDismissedUntil == null || now.isAfter(_nightWatchDismissedUntil!));

                          final strategicAlert = _analyzeStrategicThreat(messages, now);

                          Color statusColor = Colors.green;
                          String statusText = "Безпечно";
                          
                          if (overallStatus == 3) {
                            statusColor = Colors.redAccent;
                            statusText = "Ракетна загроза";
                          } else if (overallStatus == 2) {
                            statusColor = Colors.orangeAccent;
                            statusText = "Загроза БПЛА";
                          }

                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              _scheduleWidgetSync(alerts, threats, messages);
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
                                    ),
                                  ),
                                  if (geoJsonAsync.hasValue)
                                    PolygonLayer(
                                      polygons: _buildAlertPolygons(geoJsonAsync.value!, alerts, threats, globalMissileThreat: overallStatus == 3),
                                    ),
                                  if (alerts['м. Київ'] == true)
                                    CircleLayer(
                                      circles: [
                                        CircleMarker(
                                          point: const LatLng(50.4501, 30.5234),
                                          radius: 18000,
                                          useRadiusInMeter: true,
                                          color: _getAlertFillColor(overallStatus),
                                          borderColor: _getAlertBorderColor(overallStatus),
                                          borderStrokeWidth: 1.5,
                                        )
                                      ],
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
                                  AnimatedThreatsLayer(
                                    threats: threats,
                                    airDefenses: activeAirDefenses,
                                    selectedMsgId: _selectedThreatMsgId,
                                    onSelectThreat: (msgId) {
                                      setState(() {
                                        _selectedThreatMsgId = msgId;
                                      });
                                    },
                                    effectiveNow: now,
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
                                          width: 320,
                                          height: 38,
                                          alignment: Alignment.topCenter,
                                          child: Builder(
                                            builder: (context) {
                                              final homeLoc = watchedLocations.where((l) => l.enabled).firstOrNull;
                                              final LatLng originPt = homeLoc?.point ?? const LatLng(50.4501, 30.5234);
                                              final String originName = homeLoc?.name ?? 'Київ';
                                              final double distMeters = const Distance().as(LengthUnit.Meter, originPt, _rulerTargetPoint!);
                                              final double distKm = distMeters / 1000.0;
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
                                                      "📏 ${distKm.toStringAsFixed(1)} км від '$originName' • БпЛА: ~$uavMin хв • Ракета: ~$missileSec с",
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
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.black87,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: statusColor.withValues(alpha: 0.5), width: 1),
                                    boxShadow: [
                                      BoxShadow(color: statusColor.withValues(alpha: 0.3), blurRadius: 8, spreadRadius: 1)
                                    ]
                                  ),
                                  child: Row(
                                    children: [
                                      Container(
                                        width: 10,
                                        height: 10,
                                        decoration: BoxDecoration(
                                          color: statusColor,
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(color: statusColor, blurRadius: 6, spreadRadius: 2)
                                          ]
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        statusText,
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                      )
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
                                            _mapController.move(dangerLocation!.point, 13.0);
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
                              if (strategicAlert != null)
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
                              if (threats.isNotEmpty)
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
                                                ...threats.map((t) {
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
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      decoration: BoxDecoration(
                                        color: Colors.black87,
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(color: Colors.redAccent, width: 1),
                                        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4, offset: Offset(0, 2))],
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 20),
                                          const SizedBox(width: 8),
                                          Text(
                                            'Активні цілі: ${threats.length}',
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                          )
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
                                      color: const Color(0xF21C1C1C),
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
                                  backgroundColor: _isReplayMode ? const Color(0xFF003840) : const Color(0xFF1E1E1E),
                                  side: BorderSide(
                                    color: _isReplayMode ? Colors.cyanAccent : Colors.white24,
                                    width: 1,
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
                                child: FloatingActionButton.small(
                                  backgroundColor: const Color(0xFF1E1E1E),
                                  foregroundColor: Colors.white,
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
                                        _mapController.move(LatLng(midLat, midLon), 9.8);
                                        setState(() {
                                          _isSmartFocusActive = true;
                                        });
                                        return;
                                      }
                                    }

                                    _mapController.move(const LatLng(50.4501, 30.5234), isWide ? 8.2 : 8.8);
                                    setState(() {
                                      _isSmartFocusActive = false;
                                    });
                                  },
                                  child: Icon(
                                    _isSmartFocusActive ? Icons.zoom_out_map : Icons.my_location,
                                    size: 20,
                                  ),
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
                                              Wrap(
                                                spacing: 12,
                                                runSpacing: 4,
                                                children: [
                                                  Text('🧭 ${inspectedThreat['route']}', style: const TextStyle(color: Colors.white70, fontSize: 11)),
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
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
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
                                  padding: const EdgeInsets.symmetric(horizontal: 12.0),
                                  itemCount: filteredMessages.length,
                                  itemBuilder: (context, index) {
                                    final msg = filteredMessages[index];
                          
                          IconData iconData = Icons.info_outline;
                          Color iconColor = Colors.blueAccent;
                          
                          if (msg['type'] == 'danger') {
                            iconData = Icons.warning_rounded;
                            iconColor = Colors.redAccent;
                          } else if (msg['type'] == 'alert') {
                            iconData = Icons.notifications_active;
                            iconColor = Colors.orangeAccent;
                          } else if (msg['type'] == 'clear') {
                            iconData = Icons.check_circle;
                            iconColor = Colors.green;
                          } else if (msg['type'] == 'news') {
                            iconData = Icons.article;
                            iconColor = Colors.grey;
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
                          
                          return Card(
                            margin: const EdgeInsets.only(bottom: 8.0),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: isSelected
                                  ? const BorderSide(color: Colors.cyanAccent, width: 1.5)
                                  : BorderSide.none,
                            ),
                            child: ListTile(
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
                                  _mapController.move(targetPos, 10.8);
                                  setState(() {
                                    _selectedThreatMsgId = msg['id'];
                                  });
                                }
                              },
                              leading: CircleAvatar(
                                backgroundColor: iconColor.withValues(alpha: 0.2),
                                child: Icon(iconData, color: iconColor),
                              ),
                              title: Text(
                                msg['text'] ?? '',
                                style: const TextStyle(fontSize: 14),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      msg['channel'] ?? '',
                                      style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                                    ),
                                    Text(
                                      timeStr,
                                      style: TextStyle(color: Colors.grey.shade500, fontSize: 12, fontWeight: FontWeight.bold),
                                    ),
                                  ],
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
            );
                return isWide ? Row(children: [mapWidget, listWidget]) : Column(children: [mapWidget, listWidget]);
              }
            ),
          ),
        ],
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
  final List<Map<String, dynamic>> airDefenses;
  final dynamic selectedMsgId;
  final ValueChanged<dynamic>? onSelectThreat;
  final DateTime? effectiveNow;

  const AnimatedThreatsLayer({
    super.key,
    required this.threats,
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
    if (widget.threats.isNotEmpty || widget.airDefenses.isNotEmpty) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(AnimatedThreatsLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _cachedLayerWidget = null;
    final hasItems = widget.threats.isNotEmpty || widget.airDefenses.isNotEmpty;
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

  @override
  Widget build(BuildContext context) {
    if (widget.threats.isEmpty && widget.airDefenses.isEmpty) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (_cachedLayerWidget != null && (nowMs - _lastFrameTimestampMs) < 80) {
          return _cachedLayerWidget!;
        }
        _lastFrameTimestampMs = nowMs;

        List<Polygon> forecastPolygons = [];
        List<Marker> markers = [];
        List<Polyline> polylines = [];
        List<CircleMarker> targetCircles = [];

        final effectiveNow = widget.effectiveNow ?? DateTime.now().toUtc();

        // 1. Попередній розрахунок координат для кластеризації рою
        final Map<int, LatLng> activePositions = {};
        final Map<int, double> activeRotations = {};
        final Map<int, double> activeElapsedSecs = {};
        final Map<int, double> activeEffectiveElapsedSecs = {};
        final Map<int, double> activeSpeedMs = {};
        final Map<int, double> activeGeoBearings = {};

        for (var i = 0; i < widget.threats.length; i++) {
          final t = widget.threats[i];
          final path = t['path'] as List<LatLng>;
          if (path.isEmpty) continue;
          final bool isDestroyed = t['isDestroyed'] == true;
          final msgTime = (t['lastUpdated'] as DateTime?) ?? effectiveNow;
          final elapsedSec = effectiveNow.difference(msgTime).inMilliseconds / 1000.0;
          final int threatTtl = (t['ttl'] as int?) ?? getThreatTtlSeconds(t['type']?.toString() ?? '', isExitingOblast: t['isExitingOblast'] == true);
          if (elapsedSec > threatTtl && !isDestroyed) continue;

          final speedKmh = (t['speed'] as num?)?.toDouble() ?? 500.0;
          final speedMs = speedKmh * (1000.0 / 3600.0);
          final staggerDelay = (t['staggerDelay'] as num?)?.toDouble() ?? 0.0;
          final effectiveElapsedSec = elapsedSec - staggerDelay;

          final activeLeg = path.length >= 2 ? [path[path.length - 2], path.last] : path;
          double legDistance = 0;
          if (activeLeg.length >= 2) {
            legDistance = const Distance().as(LengthUnit.Meter, activeLeg[0], activeLeg[1]);
          }
          final realTravelSec = activeLeg.length == 1 ? 0.0 : (legDistance / speedMs);

          LatLng currentPos;
          double rotationAngle;
          double geoBearing = 0.0;
          if (path.length >= 2) {
            geoBearing = _calculateBearing(path[path.length - 2], path.last);
          }

          final bool isCircling = t['isCircling'] == true;
          if (isCircling) {
            final circleRes = _calculateCirclingPosAndAngle(path.last, elapsedSec);
            currentPos = circleRes.$1;
            rotationAngle = circleRes.$2;
          } else {
            double fraction = 0.0;
            if (realTravelSec > 0) {
              if (effectiveElapsedSec > 0) {
                fraction = effectiveElapsedSec / realTravelSec;
              }
            } else {
              fraction = 1.0;
            }

            final interpRes = _interpolatePosAndAngle(activeLeg, fraction.clamp(0.0, 1.0));
            currentPos = interpRes.$1;
            rotationAngle = interpRes.$2;

            final typeStr = (t['type'] ?? '').toString();
            final bool isMissile = typeStr.contains('missile') || typeStr == 'kab';
            final bool isLastPtKyiv = (path.last.latitude - 50.450).abs() < 0.05 && (path.last.longitude - 30.523).abs() < 0.05;

            if (!isMissile && !isLastPtKyiv && fraction >= 1.0 && path.length >= 2 && elapsedSec <= 240.0) {
              final double extraTimeSec = (effectiveElapsedSec - realTravelSec).clamp(0.0, 240.0);
              if (extraTimeSec > 0) {
                final double extraDistMeters = (extraTimeSec * speedMs * 0.35).clamp(0.0, 5000.0);
                const double earthRadius = 6378137.0;
                final double d = extraDistMeters / earthRadius;
                final double lat1 = path.last.latitude * math.pi / 180.0;
                final double lon1 = path.last.longitude * math.pi / 180.0;
                final double lat2 = math.asin(math.sin(lat1) * math.cos(d) + math.cos(lat1) * math.sin(d) * math.cos(geoBearing));
                final double lon2 = lon1 + math.atan2(math.sin(geoBearing) * math.sin(d) * math.cos(lat1), math.cos(d) - math.sin(lat1) * math.sin(lat2));
                currentPos = LatLng(lat2 * 180.0 / math.pi, lon2 * 180.0 / math.pi);
              }
            }
          }

          activePositions[i] = currentPos;
          activeRotations[i] = rotationAngle;
          activeElapsedSecs[i] = elapsedSec;
          activeEffectiveElapsedSecs[i] = effectiveElapsedSec;
          activeSpeedMs[i] = speedMs;
          activeGeoBearings[i] = geoBearing;
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

        // 4. Рендеринг активних цілей
        for (var i = 0; i < widget.threats.length; i++) {
          if (!activePositions.containsKey(i)) continue;
          final t = widget.threats[i];
          final path = t['path'] as List<LatLng>;
          final currentPos = activePositions[i]!;
          final rotationAngle = activeRotations[i]!;
          final elapsedSec = activeElapsedSecs[i]!;
          final speedMs = activeSpeedMs[i]!;
          final geoBearing = activeGeoBearings[i]!;

          final bool isDestroyed = t['isDestroyed'] == true;
          final typeStr = t['type'].toString();
          final trailColor = _getTrailColor(typeStr);
          final bool isCircling = t['isCircling'] == true;
          final bool isDescending = t['isDescending'] == true;
          final String? altitude = t['altitude'] as String?;
          final int? altitudeMeters = t['altitudeMeters'] as int?;

          final bool isSelected = widget.selectedMsgId != null && t['msgId'] == widget.selectedMsgId;

          // Старіння контакту (Confidence Decay):
          // Confidence Decay масштабується за адаптивним TTL цілі:
          // 0..40% TTL: 100% яскравість (opacity 1.0), неонове світіння
          // 40..70% TTL: opacity 0.7 + мітка часу
          // > 70% TTL: режим "Ghost" (opacity 0.4 + ?)
          double opacity = 1.0;
          bool isGhost = false;
          String? decayTimeTag;

          final int ttlForDecay = (t['ttl'] as int?) ?? getThreatTtlSeconds(typeStr, isExitingOblast: t['isExitingOblast'] == true);
          if (elapsedSec <= ttlForDecay * 0.4) {
            opacity = 1.0;
          } else if (elapsedSec <= ttlForDecay * 0.7) {
            opacity = 0.7;
            final minAgo = (elapsedSec / 60).floor();
            decayTimeTag = minAgo > 0 ? '$minAgoхв' : '${elapsedSec.round()}с';
          } else {
            opacity = 0.4;
            isGhost = true;
            final minAgo = (elapsedSec / 60).floor();
            decayTimeTag = minAgo > 0 ? '$minAgoхв' : '${elapsedSec.round()}с';
          }

          // Лінія маршруту
          final trailRaw = path.length > 6 ? path.sublist(path.length - 6) : path;
          final smoothPoints = _generateCatmullRomSpline(trailRaw);

          if (smoothPoints.length >= 2) {
            if (isSelected) {
              polylines.add(
                Polyline(
                  points: smoothPoints,
                  color: Colors.cyanAccent.withValues(alpha: 0.5),
                  strokeWidth: 8.0,
                ),
              );
              polylines.add(
                Polyline(
                  points: smoothPoints,
                  color: Colors.cyanAccent,
                  strokeWidth: 3.5,
                ),
              );
            } else {
              polylines.add(
                Polyline(
                  points: smoothPoints,
                  color: isDestroyed 
                      ? Colors.greenAccent.withValues(alpha: 0.25)
                      : trailColor.withValues(alpha: 0.25 * opacity),
                  strokeWidth: 5.0,
                ),
              );
              polylines.add(
                Polyline(
                  points: smoothPoints,
                  color: isDestroyed 
                      ? Colors.greenAccent.withValues(alpha: 0.8)
                      : trailColor.withValues(alpha: 0.85 * opacity),
                  strokeWidth: 2.0,
                  pattern: const StrokePattern.dotted(),
                ),
              );
            }
          }

          // Якщо ціль збита/знищена
          if (isDestroyed) {
            markers.add(
              Marker(
                point: path.last,
                width: 220,
                height: 48,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black87,
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
            );
            continue;
          }

          // Якщо кружляє
          if (isCircling) {
            final orbitPoints = <LatLng>[];
            for (int s = 0; s <= 32; s++) {
              final a = (s / 32.0) * 2.0 * math.pi;
              orbitPoints.add(LatLng(
                path.last.latitude + 0.016 * math.sin(a),
                path.last.longitude + 0.026 * math.cos(a),
              ));
            }
            polylines.add(
              Polyline(
                points: orbitPoints,
                color: trailColor.withValues(alpha: 0.6 * opacity),
                strokeWidth: 1.5,
                pattern: const StrokePattern.dotted(),
              ),
            );
          }

          // Кільце в кінцевій точці
          targetCircles.add(
            CircleMarker(
              point: path.last,
              radius: isCircling ? 4 : 6,
              color: trailColor.withValues(alpha: 0.35 * opacity),
              borderColor: trailColor.withValues(alpha: opacity),
              borderStrokeWidth: 1.5,
            ),
          );

          // Вектор випередження (Leader Line) на 1 хвилину польоту вперед із точкою-зарубкою
          if (!isCircling && path.length >= 2) {
            final double leadDistMeters = (speedMs * 60.0).clamp(500.0, 30000.0);
            const double earthRadius = 6378137.0;
            final double dLead = leadDistMeters / earthRadius;
            final double lat1 = currentPos.latitude * math.pi / 180.0;
            final double lon1 = currentPos.longitude * math.pi / 180.0;
            final double lat2 = math.asin(math.sin(lat1) * math.cos(dLead) + math.cos(lat1) * math.sin(dLead) * math.cos(geoBearing));
            final double lon2 = lon1 + math.atan2(math.sin(geoBearing) * math.sin(dLead) * math.cos(lat1), math.cos(dLead) - math.sin(lat1) * math.sin(lat2));
            final LatLng leaderEndPt = LatLng(lat2 * 180.0 / math.pi, lon2 * 180.0 / math.pi);

            polylines.add(
              Polyline(
                points: [currentPos, leaderEndPt],
                color: trailColor.withValues(alpha: (opacity * 0.75).clamp(0.2, 0.9)),
                strokeWidth: 1.5,
                pattern: StrokePattern.dashed(segments: const [6, 4]),
              ),
            );
            targetCircles.add(
              CircleMarker(
                point: leaderEndPt,
                radius: 3.0,
                color: trailColor.withValues(alpha: opacity),
                borderColor: Colors.black87,
                borderStrokeWidth: 1.0,
              ),
            );
          }

          // Якщо ціль виділена (Tap-to-Inspect) - підсвічуємо кільцем
          if (isSelected) {
            targetCircles.add(
              CircleMarker(
                point: currentPos,
                radius: 18,
                color: Colors.cyanAccent.withValues(alpha: 0.2),
                borderColor: Colors.cyanAccent,
                borderStrokeWidth: 2.0,
              ),
            );
          }

          final bool isUav = typeStr == 'shahed' || typeStr == 'shahed_jet' || typeStr == 'uav_guided' || typeStr == 'uav_recon' || typeStr == 'uav_decoy';

          // Акустичний радіус чутності (3200 м) для БпЛА
          if (isUav) {
            targetCircles.add(
              CircleMarker(
                point: currentPos,
                radius: 3200,
                useRadiusInMeter: true,
                color: Colors.yellow.withValues(alpha: 0.04 * opacity),
                borderColor: trailColor.withValues(alpha: 0.22 * opacity),
                borderStrokeWidth: 1.0,
              ),
            );
          }

          // Прогнозний конус розльоту
          if (!isCircling && path.length >= 2) {
            forecastPolygons.add(_buildForecastCone(currentPos, geoBearing, speedMs, trailColor, isUav));
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

          final bool isMissile = typeStr.contains('missile') || typeStr == 'kab';
          final double iconSize = isMissile ? 20.0 : 17.0;
          final visualContent = _buildThreatAssetIcon(typeStr, size: iconSize);
          final glowingIcon = Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: isDescending 
                      ? Colors.redAccent.withValues(alpha: 0.7 * opacity) 
                      : trailColor.withValues(alpha: 0.5 * opacity),
                  blurRadius: 3,
                  spreadRadius: 0.2,
                )
              ],
            ),
            child: visualContent,
          );

          // Кольорова індикація висоти (Echelon Color):
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
          } else if (isCircling) {
            badgeColor = trailColor;
            badgeText = altitude != null ? '⟳ $altitude' : '⟳ кружляє';
          } else if (altitude != null) {
            badgeColor = trailColor;
            badgeText = altitude;
          } else {
            badgeColor = trailColor;
          }

          if (decayTimeTag != null) {
            if (badgeText.isNotEmpty) {
              badgeText = '$badgeText • $decayTimeTag';
            } else {
              badgeText = decayTimeTag;
            }
          }
          final bool hasBadge = badgeText.isNotEmpty;
          final badgeBg = isDescending 
              ? Colors.red.shade900.withValues(alpha: 0.85 * opacity) 
              : Colors.black.withValues(alpha: 0.85 * opacity);

          final int? clusterCount = leadClusterBadges[i];

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
                    Transform.rotate(
                      angle: rotationAngle,
                      child: Opacity(
                        opacity: opacity,
                        child: glowingIcon,
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
                        top: activePositions.entries.any(
                          (entry) => entry.key != i && const Distance().as(LengthUnit.Meter, currentPos, entry.value) < 2500.0,
                        ) ? (i % 2 == 0 ? 25.0 : -15.0) : 25.0,
                        left: -50,
                        right: -50,
                        child: Center(
                          child: Opacity(
                            opacity: opacity,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: badgeBg,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: badgeColor.withValues(alpha: 0.8), width: 0.8),
                              ),
                              child: Text(
                                badgeText,
                                style: TextStyle(
                                  color: badgeColor,
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



