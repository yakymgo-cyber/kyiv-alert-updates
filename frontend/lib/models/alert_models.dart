import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

/// Базові константи версії додатку за замовчуванням
const int kDefaultVersionCode = 39;
const String kDefaultVersionName = '1.2.37';

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
    final rawId = (json['id'] ?? '').toString().trim();
    final safeId = rawId.length > 64 ? rawId.substring(0, 64) : (rawId.isEmpty ? 'zone_default' : rawId);
    final rawName = (json['name'] ?? '').toString().replaceAll(RegExp(r'<[^>]*>'), '').trim();
    final safeName = rawName.length > 60 ? rawName.substring(0, 60) : (rawName.isEmpty ? 'Зона безпеки' : rawName);
    final rawAddr = (json['address'] ?? '').toString().replaceAll(RegExp(r'<[^>]*>'), '').trim();
    final safeAddr = rawAddr.length > 140 ? rawAddr.substring(0, 140) : rawAddr;

    final rawLat = (json['lat'] as num?)?.toDouble() ?? 50.4501;
    final rawLon = (json['lon'] as num?)?.toDouble() ?? 30.5234;
    final safeLat = (rawLat.isNaN || rawLat.isInfinite) ? 50.4501 : rawLat.clamp(-90.0, 90.0);
    final safeLon = (rawLon.isNaN || rawLon.isInfinite) ? 30.5234 : rawLon.clamp(-180.0, 180.0);

    final rawRadius = (json['radiusMeters'] as num?)?.toDouble() ?? 4000.0;
    final safeRadius = (rawRadius.isNaN || rawRadius.isInfinite) ? 4000.0 : rawRadius.clamp(500.0, 50000.0);

    return WatchedLocation(
      id: safeId,
      name: safeName,
      address: safeAddr,
      point: LatLng(safeLat, safeLon),
      radiusMeters: safeRadius,
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

  static const _trustedApkHosts = {
    'github.com',
    'objects.githubusercontent.com',
    'raw.githubusercontent.com',
  };

  static const _blockedRemoteLocationKeys = {
    'києва', 'київ', 'умань', 'залізн', 'десни', 'десна', 'дніпра', 'борщ', 'кло', 'азс',
  };

  static bool _isTrustedApkUrl(String url) {
    if (url.isEmpty || url.length > 512) return false;
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.scheme == 'https' &&
        _trustedApkHosts.any((h) => uri.host == h || uri.host.endsWith('.$h'));
  }

  factory RemoteConfig.fromJson(Map<String, dynamic> json) {
    final Map<String, (double, double, String)> locations = {};
    if (json['extra_locations'] is Map) {
      (json['extra_locations'] as Map).forEach((k, v) {
        final keyStr = k.toString().toLowerCase().trim();
        if (keyStr.startsWith('лук\'ян') || keyStr.startsWith('лукʼян') || keyStr.startsWith('лук’ян') || keyStr.startsWith('лукян')) {
          return; // Лук'янівка — виключно метро Лук'янівка (Київ)!
        }
        if (_blockedRemoteLocationKeys.contains(keyStr)) {
          return; // Отруєні ключі (загальні слова/топоніми поза контекстом)
        }
        if (keyStr.length >= 3 && keyStr.length <= 35 && v is Map && v['lat'] != null && v['lon'] != null) {
          final lat = (v['lat'] as num).toDouble();
          final lon = (v['lon'] as num).toDouble();
          // Перевірка географічних меж України / Київської області
          if (!lat.isNaN && !lon.isNaN && lat >= 48.0 && lat <= 53.0 && lon >= 28.0 && lon <= 34.0) {
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

    final rawVersionName = (json['version_name']?.toString() ?? kDefaultVersionName)
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
    final safeVersionName = rawVersionName.length > 24
        ? rawVersionName.substring(0, 24)
        : (rawVersionName.isEmpty ? kDefaultVersionName : rawVersionName);

    final rawApkUrl = (json['apk_url']?.toString() ?? '').trim();
    final safeApkUrl = _isTrustedApkUrl(rawApkUrl) ? rawApkUrl : '';

    final rawChangelog = (json['changelog']?.toString() ?? '')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .trim();
    final safeChangelog = rawChangelog.length > 1500
        ? rawChangelog.substring(0, 1500)
        : rawChangelog;

    return RemoteConfig(
      versionCode: (json['version_code'] as num?)?.toInt() ?? kDefaultVersionCode,
      versionName: safeVersionName,
      apkUrl: safeApkUrl,
      changelog: safeChangelog,
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
  final List<LatLng> waypoints; // усі точки, які послідовно пройшла ця ціль
  final String? lastPostId; // ID останнього повідомлення в ланцюжку цієї цілі

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
    this.waypoints = const [],
    this.lastPostId,
  });

  ThreatMarker copyWith({
    String? id,
    String? type,
    String? label,
    LatLng? point,
    LatLng? prevPoint,
    double? speed,
    double? azimuth,
    int? altitude,
    DateTime? timestamp,
    String? rawText,
    String? channel,
    bool? isExiting,
    List<LatLng>? waypoints,
    String? lastPostId,
  }) {
    return ThreatMarker(
      id: id ?? this.id,
      type: type ?? this.type,
      label: label ?? this.label,
      point: point ?? this.point,
      prevPoint: prevPoint ?? this.prevPoint,
      speed: speed ?? this.speed,
      azimuth: azimuth ?? this.azimuth,
      altitude: altitude ?? this.altitude,
      timestamp: timestamp ?? this.timestamp,
      rawText: rawText ?? this.rawText,
      channel: channel ?? this.channel,
      isExiting: isExiting ?? this.isExiting,
      waypoints: waypoints ?? this.waypoints,
      lastPostId: lastPostId ?? this.lastPostId,
    );
  }

  /// Розрахунок кінематично екстрапольованої позиції вперед за курсом
  LatLng currentExtrapolatedPosition(DateTime now) {
    if (azimuth == null) return point;
    final double elapsedSeconds = (now.difference(timestamp).inMilliseconds / 1000.0).clamp(0.0, 3600.0);
    if (elapsedSeconds <= 0) return point;

    // Зміщення вперед уздовж курсу bearing зі швидкістю speed (не далі ніж на 15 км)
    final double speedMs = speed * (1000.0 / 3600.0);
    final double distanceMeters = math.min(speedMs * elapsedSeconds, 15000.0);

    const double earthRadius = 6378137.0;
    final double d = distanceMeters / earthRadius;
    final double bearingRad = azimuth! * math.pi / 180.0;
    final double lat1 = point.latitude * math.pi / 180.0;
    final double lon1 = point.longitude * math.pi / 180.0;

    final double lat2 = math.asin(
      math.sin(lat1) * math.cos(d) + math.cos(lat1) * math.sin(d) * math.cos(bearingRad),
    );
    final double lon2 = lon1 + math.atan2(
      math.sin(bearingRad) * math.sin(d) * math.cos(lat1),
      math.cos(d) - math.sin(lat1) * math.sin(lat2),
    );

    return LatLng(lat2 * 180.0 / math.pi, lon2 * 180.0 / math.pi);
  }
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
  final int? replyToMsgId;
  final String? postId;
  final String? replyToPostId;
  final String? replyQuotedText;

  const AlertMessage({
    required this.id,
    required this.channel,
    required this.text,
    required this.time,
    this.type,
    this.threats = const [],
    this.rawHtml = '',
    this.replyToMsgId,
    this.postId,
    this.replyToPostId,
    this.replyQuotedText,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'channel': channel,
    'text': text,
    'time': time.toIso8601String(),
    'type': type,
    'threats': threats,
    'rawHtml': rawHtml,
    'reply_to_msg_id': replyToMsgId,
    'replyToMsgId': replyToMsgId,
    'post_id': postId,
    'postId': postId,
    'reply_to_post_id': replyToPostId,
    'replyToPostId': replyToPostId,
    'reply_quoted_text': replyQuotedText,
    'replyQuotedText': replyQuotedText,
  };

  factory AlertMessage.fromJson(Map<String, dynamic> json) => AlertMessage(
    id: json['id'] as int? ?? 0,
    channel: json['channel']?.toString() ?? '',
    text: json['text']?.toString() ?? '',
    time: DateTime.tryParse(json['time']?.toString() ?? '') ?? DateTime.now(),
    type: json['type']?.toString(),
    threats: (json['threats'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ?? const [],
    rawHtml: json['rawHtml']?.toString() ?? '',
    replyToMsgId: (json['reply_to_msg_id'] as num?)?.toInt(),
    postId: json['post_id']?.toString() ?? json['postId']?.toString(),
    replyToPostId: json['reply_to_post_id']?.toString() ?? json['replyToPostId']?.toString(),
    replyQuotedText: json['reply_quoted_text']?.toString() ?? json['replyQuotedText']?.toString(),
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
