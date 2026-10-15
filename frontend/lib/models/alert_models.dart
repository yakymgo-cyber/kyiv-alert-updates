import 'package:latlong2/latlong.dart';

/// Базові константи версії додатку за замовчуванням
const int kDefaultVersionCode = 20;
const String kDefaultVersionName = '1.2.17';

/// Модель зони спостереження (Зона безпеки)
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

/// Модель віддаленої конфігурації із захистом від Poisoning-атак
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
    this.versionCode = kDefaultVersionCode,
    this.versionName = kDefaultVersionName,
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
        final keyStr = k.toString().toLowerCase().trim();
        if (keyStr.length >= 3 && keyStr.length <= 35 && v is Map && v['lat'] != null && v['lon'] != null) {
          final lat = (v['lat'] as num).toDouble();
          final lon = (v['lon'] as num).toDouble();
          // Перевірка географічних меж України / Київської області
          if (lat >= 48.0 && lat <= 53.0 && lon >= 28.0 && lon <= 34.0) {
            final rawName = (v['name'] ?? k).toString();
            final cleanName = rawName.replaceAll(RegExp(r'<[^>]*>'), '').replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();
            final safeName = cleanName.length > 40 ? cleanName.substring(0, 40) : cleanName;
            locations[keyStr] = (lat, lon, safeName);
          }
        }
      });
    }

    final channelRegex = RegExp(r'^[a-zA-Z0-9_]{4,32}$');
    final List<String> channels = (json['extra_channels'] as List?)
            ?.map((e) => e.toString().trim())
            .where((ch) => channelRegex.hasMatch(ch))
            .take(5)
            .toList() ??
        const [];

    final List<String> dangerKws = (json['extra_danger_keywords'] as List?)
            ?.map((e) => e.toString().trim())
            .where((kw) => kw.length >= 3 && kw.length <= 40)
            .take(30)
            .toList() ??
        const [];

    final List<String> clearKws = (json['extra_clear_keywords'] as List?)
            ?.map((e) => e.toString().trim())
            .where((kw) => kw.length >= 3 && kw.length <= 40)
            .take(30)
            .toList() ??
        const [];

    return RemoteConfig(
      versionCode: (json['version_code'] as num?)?.toInt() ?? kDefaultVersionCode,
      versionName: json['version_name']?.toString() ?? kDefaultVersionName,
      apkUrl: json['apk_url']?.toString() ?? '',
      changelog: json['changelog']?.toString() ?? '',
      extraLocations: locations,
      extraChannels: channels,
      extraDangerKeywords: dangerKws,
      extraClearKeywords: clearKws,
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

/// Модель маркера загрози на радарі
class ThreatMarker {
  final String id;
  final String type;
  final String label;
  final LatLng point;
  final LatLng? prevPoint;
  final double speed;
  final double? azimuth;
  final int? altitude;
  final DateTime timestamp;
  final String rawText;
  final String channel;
  final bool isExiting;

  const ThreatMarker({
    required this.id,
    required this.type,
    required this.label,
    required this.point,
    this.prevPoint,
    this.speed = 185.0,
    this.azimuth,
    this.altitude,
    required this.timestamp,
    this.rawText = '',
    this.channel = '',
    this.isExiting = false,
  });
}

/// Модель повідомлення з моніторингових каналів
class AlertMessage {
  final int id;
  final String channel;
  final String text;
  final DateTime time;
  final String? type;
  final List<Map<String, dynamic>> threats;
  final String rawHtml;

  const AlertMessage({
    required this.id,
    required this.channel,
    required this.text,
    required this.time,
    this.type,
    this.threats = const [],
    this.rawHtml = '',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'channel': channel,
    'text': text,
    'time': time.toIso8601String(),
    'type': type,
    'threats': threats,
    'rawHtml': rawHtml,
  };

  factory AlertMessage.fromJson(Map<String, dynamic> json) => AlertMessage(
    id: json['id'] as int? ?? 0,
    channel: json['channel']?.toString() ?? '',
    text: json['text']?.toString() ?? '',
    time: DateTime.tryParse(json['time']?.toString() ?? '') ?? DateTime.now(),
    type: json['type']?.toString(),
    threats: (json['threats'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ?? const [],
    rawHtml: json['rawHtml']?.toString() ?? '',
  );
}

typedef Message = AlertMessage;

/// Подія фіксації пусків стратегічної авіації або морських ракетоносіїв
class StrategicLaunchEvent {
  final String type; // 'Х-101 (Ту-95МС)' або 'КРМБ «Калібр» (Море)'
  final int estimatedArrivalMinutes; // 65 або 50
  final DateTime timestamp;
  final String rawText;

  const StrategicLaunchEvent({
    required this.type,
    required this.estimatedArrivalMinutes,
    required this.timestamp,
    this.rawText = '',
  });

  DateTime get estimatedArrivalTime => timestamp.add(Duration(minutes: estimatedArrivalMinutes));

  int remainingMinutes([DateTime? fromTime]) {
    final now = fromTime ?? DateTime.now().toUtc();
    return estimatedArrivalTime.difference(now).inMinutes;
  }

  bool isExpired([DateTime? fromTime]) {
    final now = fromTime ?? DateTime.now().toUtc();
    return now.difference(timestamp).inMinutes > 120 || remainingMinutes(now) < -30;
  }

  Map<String, dynamic> toJson() => {
    'type': type,
    'estimatedArrivalMinutes': estimatedArrivalMinutes,
    'timestamp': timestamp.toIso8601String(),
    'rawText': rawText,
  };

  factory StrategicLaunchEvent.fromJson(Map<String, dynamic> json) => StrategicLaunchEvent(
    type: json['type']?.toString() ?? '',
    estimatedArrivalMinutes: (json['estimatedArrivalMinutes'] as num?)?.toInt() ?? 60,
    timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ?? DateTime.now(),
    rawText: json['rawText']?.toString() ?? '',
  );
}
