import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:frontend/models/alert_models.dart';
import 'package:frontend/services/threat_parser.dart';
import 'package:frontend/data/kyiv_gazetteer.dart';

void main() {
  group('Telegram Reply & Route Stitching Models', () {
    test('AlertMessage serialization with postId, replyToPostId and replyQuotedText', () {
      final msg = AlertMessage(
        id: 12345,
        channel: 'kyiv_airdef',
        text: 'Шахед на Вишгород',
        time: DateTime.utc(2026, 10, 15, 12, 0, 0),
        postId: 'kyiv_airdef/12345',
        replyToPostId: 'kyiv_airdef/12340',
        replyQuotedText: '1х БпЛА через Водосховище',
      );

      final json = msg.toJson();
      expect(json['id'], 12345);
      expect(json['postId'], 'kyiv_airdef/12345');
      expect(json['replyToPostId'], 'kyiv_airdef/12340');
      expect(json['replyQuotedText'], '1х БпЛА через Водосховище');

      final fromJson = AlertMessage.fromJson(json);
      expect(fromJson.postId, 'kyiv_airdef/12345');
      expect(fromJson.replyToPostId, 'kyiv_airdef/12340');
      expect(fromJson.replyQuotedText, '1х БпЛА через Водосховище');
    });

    test('ThreatMarker waypoints, lastPostId and currentExtrapolatedPosition', () {
      const p1 = LatLng(50.7600, 30.5000); // Водосховище
      const p2 = LatLng(50.5833, 30.4833); // Вишгород
      const p3 = LatLng(50.4501, 30.5234); // Київ

      final marker = ThreatMarker(
        id: 't-1',
        type: 'shahed',
        label: 'Шахед / БпЛА',
        point: p3,
        prevPoint: p2,
        speed: 180.0,
        azimuth: 180.0, // курс на південь
        timestamp: DateTime.utc(2026, 10, 15, 12, 0, 0),
        waypoints: const [p1, p2, p3],
        lastPostId: 'kyiv_airdef/12350',
      );

      expect(marker.waypoints.length, 3);
      expect(marker.lastPostId, 'kyiv_airdef/12350');

      // 60 секунд польоту на південь зі швидкістю 180 км/год = 50 м/с -> 3000 м
      final extrapolated = marker.currentExtrapolatedPosition(DateTime.utc(2026, 10, 15, 12, 1, 0));
      expect(extrapolated.latitude, lessThan(p3.latitude)); // зміщення на південь
      final dist = const Distance().as(LengthUnit.Meter, p3, extrapolated);
      expect(dist, closeTo(3000.0, 50.0));
    });
  });

  group('Gazetteer & Contextual Toponyms', () {
    test('Dnipro River corridor is protected from far transit filtering', () {
      final threats = parseLocalThreats('По Дніпру на південь зі швидкістю 120');
      expect(threats.isNotEmpty, isTrue);
      final path = (threats.first['path'] as List);
      expect(path.isNotEmpty, isTrue);
      // Має вказувати на русло Дніпра (50.40, 30.56)
      final loc = path.first;
      expect((loc['lat'] as num).toDouble(), closeTo(50.40, 0.05));
    });

    test('Contextual Novosilky resolution: Desna vs Teremky', () {
      // 1. Північні Новосілки (біля Вишгорода / Десни)
      final northThreats = parseLocalThreats('Шахед біля Новосілок біля Десни');
      expect(northThreats.isNotEmpty, isTrue);
      final northLoc = (northThreats.first['path'] as List).first;
      expect((northLoc['lat'] as num).toDouble(), closeTo(50.628, 0.05));
      expect(northLoc['name'], contains('Вишгород'));

      // 2. Південні Новосілки (біля Теремків / Голосієва)
      final southThreats = parseLocalThreats('Шахед Новосілки біля Теремків');
      expect(southThreats.isNotEmpty, isTrue);
      final southLoc = (southThreats.first['path'] as List).first;
      expect((southLoc['lat'] as num).toDouble(), closeTo(50.355, 0.05));
      expect(southLoc['name'], contains('Теремки'));
    });

    test('Vita-Lytovska and Vita-Poshtova in gazetteer', () {
      expect(kKyivLocations.containsKey('віта-литовськ'), isTrue);
      expect(kKyivLocations.containsKey('віта-поштов'), isTrue);

      final threats = parseLocalThreats('БпЛА в напрямку Віта-Литовська');
      expect(threats.isNotEmpty, isTrue);
      final loc = (threats.first['path'] as List).first;
      expect((loc['lat'] as num).toDouble(), closeTo(50.318, 0.02));
    });
  });

  group('HTML Telegram Reply Extraction Logic', () {
    test('Cleans reply quote before extracting main text', () {
      const sampleHtml = '''
      <div class="tgme_widget_message_wrap">
        <div class="tgme_widget_message" data-post="kyiv_airdef/5555">
          <div class="tgme_widget_message_text">
            <a class="tgme_widget_message_reply" href="https://t.me/kyiv_airdef/5550">
              <div class="tgme_widget_message_author_name">Kyiv Air Defense</div>
              <div class="tgme_widget_message_text">Шахед через Водосховище</div>
            </a>
            Шахед вже біля Вишгорода курсом на південь
          </div>
          <time datetime="2026-10-15T12:10:00+00:00"></time>
        </div>
      </div>
      ''';

      // 1. data-post
      final postMatch = RegExp(r'data-post="([^"]+)"').firstMatch(sampleHtml);
      expect(postMatch?.group(1), 'kyiv_airdef/5555');

      // 2. reply
      final replyMatch = RegExp(r'<a[^>]*class="[^"]*tgme_widget_message_reply[^"]*"[^>]*href="https?://t\.me/([^"]+)"[\s\S]*?</a>').firstMatch(sampleHtml);
      expect(replyMatch, isNotNull);
      expect(replyMatch?.group(1), 'kyiv_airdef/5550');

      // 3. Strip reply block before extracting main text
      final stripped = sampleHtml.replaceAll(RegExp(r'<a[^>]*class="[^"]*tgme_widget_message_reply[^"]*"[\s\S]*?</a>'), '');
      final mainMatches = RegExp(r'tgme_widget_message_text(?![^>]*reply)[^>]*>([\s\S]*?)</div>').allMatches(stripped);
      final cleanMain = mainMatches.last.group(1)!.trim();
      expect(cleanMain, contains('Шахед вже біля Вишгорода курсом на південь'));
      expect(cleanMain.contains('Водосховище'), isFalse); // Цитата не забруднює основний текст!
    });
  });
}
