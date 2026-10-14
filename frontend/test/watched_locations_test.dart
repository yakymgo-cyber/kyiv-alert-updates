import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:frontend/main.dart';

void main() {
  group('WatchedLocation Model Tests', () {
    test('toJson and fromJson preserves data accurately', () {
      const loc = WatchedLocation(
        id: 'test_home',
        name: 'Дім',
        address: 'вул. Хрещатик, 22',
        point: LatLng(50.4501, 30.5234),
        radiusMeters: 3500.0,
        enabled: true,
      );

      final jsonMap = loc.toJson();
      final restored = WatchedLocation.fromJson(jsonMap);

      expect(restored.id, equals('test_home'));
      expect(restored.name, equals('Дім'));
      expect(restored.address, equals('вул. Хрещатик, 22'));
      expect(restored.point.latitude, closeTo(50.4501, 0.0001));
      expect(restored.point.longitude, closeTo(30.5234, 0.0001));
      expect(restored.radiusMeters, equals(3500.0));
      expect(restored.enabled, isTrue);
    });

    test('copyWith updates properties correctly', () {
      const loc = WatchedLocation(
        id: 'loc_1',
        name: 'Офіс',
        address: 'Хрещатик, 1',
        point: LatLng(50.4501, 30.5234),
        radiusMeters: 4000.0,
        enabled: true,
      );

      final disabled = loc.copyWith(enabled: false, radiusMeters: 2000.0);
      expect(disabled.enabled, isFalse);
      expect(disabled.radiusMeters, equals(2000.0));
      expect(disabled.name, equals('Офіс'));
    });
  });

  group('Safety Zone Radar Projection Tests', () {
    test('minDistanceToPoint returns infinity for empty path', () {
      expect(minDistanceToPointMeters(const LatLng(50.45, 30.52), []), equals(double.infinity));
    });

    test('minDistanceToPoint calculates direct distance for single point', () {
      const center = LatLng(50.4501, 30.5234);
      final dist = minDistanceToPointMeters(center, [center]);
      expect(dist, closeTo(0.0, 1.0));
    });

    test('minDistanceToPoint calculates perpendicular projection correctly', () {
      // Path from (50.40, 30.50) to (50.50, 30.50)
      const p1 = LatLng(50.40, 30.50);
      const p2 = LatLng(50.50, 30.50);
      // Center at (50.45, 30.50) which lies directly on the segment
      const onPath = LatLng(50.45, 30.50);
      final distOn = minDistanceToPointMeters(onPath, [p1, p2]);
      expect(distOn, closeTo(0.0, 50.0));

      // Point offset eastward by 0.05 degrees longitude (approx 3.5 km)
      const offsetPoint = LatLng(50.45, 30.55);
      final distOffset = minDistanceToPointMeters(offsetPoint, [p1, p2]);
      expect(distOffset, greaterThan(3000.0));
      expect(distOffset, lessThan(4500.0));
    });
  });
}
