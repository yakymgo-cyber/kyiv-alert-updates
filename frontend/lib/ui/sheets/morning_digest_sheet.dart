import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:frontend/models/alert_models.dart';
import 'package:frontend/services/threat_parser.dart';

class _ExpandableNewsItem extends StatefulWidget {
  final String text;
  final Color bulletColor;
  final TextStyle style;

  const _ExpandableNewsItem({
    required this.text,
    required this.bulletColor,
    required this.style,
  });

  @override
  State<_ExpandableNewsItem> createState() => _ExpandableNewsItemState();
}

class _ExpandableNewsItemState extends State<_ExpandableNewsItem> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () {
          setState(() {
            _isExpanded = !_isExpanded;
          });
        },
        borderRadius: BorderRadius.circular(6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('• ', style: TextStyle(color: widget.bulletColor, fontSize: 14)),
            Expanded(
              child: Text(
                widget.text,
                maxLines: _isExpanded ? null : 4,
                overflow: _isExpanded ? TextOverflow.visible : TextOverflow.ellipsis,
                style: widget.style,
              ),
            ),
          ],
        ),
      ),
    );
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



  void showMorningDigestSheet(
  BuildContext context, {
  required List<dynamic> messages,
  required List<WatchedLocation> watchedLocations,
  bool isNightWatchMode = false,
}) {
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

        Future<List<String>> fetchTelegramPreview(String channel, int limit) async {
          try {
            final response = await http.get(
              Uri.parse('https://t.me/s/$channel'),
              headers: {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'},
            ).timeout(const Duration(seconds: 7));
            if (response.statusCode == 200) {
              final html = response.body;
              final blocks = html.split('tgme_widget_message_wrap');
              final list = <String>[];
              final startIdx = blocks.length > limit * 3 ? blocks.length - limit * 3 : 1;
              for (int i = startIdx; i < blocks.length; i++) {
                final block = blocks[i];
                final mainTextMatches = RegExp(r'tgme_widget_message_text(?![^>]*reply)[^>]*>([\s\S]*?)</div>').allMatches(block);
                if (mainTextMatches.isNotEmpty) {
                  final raw = mainTextMatches.first.group(1);
                  if (raw != null) {
                    final clean = cleanHtmlString(raw, maxLength: 3500);
                    if (clean.isNotEmpty) {
                      list.add(clean);
                    }
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
            // messages passed as argument
            // watchedLocations passed as argument

            // Автономне / бекенд завантаження новин при відкритті
            if (!hasInitiatedFetch) {
              hasInitiatedFetch = true;
              Future.microtask(() async {
                try {
                  // 1. Спроба завантажити з бекенду (тільки у Debug-режимі)
                  if (kDebugMode) {
                    try {
                      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/digest')).timeout(const Duration(seconds: 3));
                      if (res.statusCode == 200) {
                        final data = jsonDecode(utf8.decode(res.bodyBytes));
                        if (data is Map && data['energy_news'] is List && data['transport_news'] is List) {
                          setSheetState(() {
                            energyNews = (data['energy_news'] as List).map((e) => cleanHtmlString(e.toString(), maxLength: 3500)).where((s) => s.isNotEmpty).toList();
                            transportNews = (data['transport_news'] as List).map((e) => cleanHtmlString(e.toString(), maxLength: 3500)).where((s) => s.isNotEmpty).toList();
                            isLoadingNews = false;
                          });
                          return;
                        }
                      }
                    } catch (_) {}
                  }

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
                    energyNews = filteredEnergy.take(4).map((e) => cleanHtmlString(e, maxLength: 3500)).where((s) => s.isNotEmpty).toList();
                    transportNews = filteredTransport.take(4).map((e) => cleanHtmlString(e, maxLength: 3500)).where((s) => s.isNotEmpty).toList();
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
            DateTime? activeBallisticUntil;

            const ppoKeywords = ['ппо', 'працює ппо', 'робота ппо', 'роботі ппо', 'збиття', 'збито', 'мінус', 'ліквідовано'];
            const clearKeywords = ['відбій', 'чисто', 'тихо', 'дорозвідка', 'локаційно втрачено', 'немає цілей'];
            const missileKeywords = [
              'ракет', 'крилаті', 'баліст', 'іскандер', 'кинджал', 'циркон', 'калібр',
              'х-101', 'х-22', 'х-32', 'х-59', 'х-69', 'онікс', 'с-300', 'с-400',
              'швидкісна', 'швидкісні', 'виходи', 'багато цілей', 'цілей йде'
            ];
            const negativeMissileWords = ['не підтверд', 'не фіксу', 'хибн', 'відбій', 'чисто'];

            final Set<String> threatenedZoneNames = {};
            final activeZones = watchedLocations.where((l) => l.enabled).toList();

            // Фільтруємо повідомлення за останні 10 годин і сортуємо хронологічно
            final recentMessages = messages.where((msg) {
              if (msg['date'] == null) return false;
              try {
                final t = DateTime.parse(msg['date'].toString()).toUtc();
                return !t.isBefore(cutoff);
              } catch (_) {
                return false;
              }
            }).toList();

            recentMessages.sort((a, b) {
              final da = DateTime.tryParse(a['date']?.toString() ?? '')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0);
              final db = DateTime.tryParse(b['date']?.toString() ?? '')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0);
              return da.compareTo(db);
            });

            for (final msg in recentMessages) {
              DateTime? msgTime;
              try {
                msgTime = DateTime.parse(msg['date'].toString()).toUtc();
              } catch (_) {}

              final text = (msg['text'] ?? '').toString();
              final tLower = text.toLowerCase();
              final bool hasNegative = negativeMissileWords.any((nw) => tLower.contains(nw));

              // Перевірка на тригери ракет / балістики: ТІЛЬКИ явні ракетні слова, '!!!!' або одне-два слова капсом без локацій
              final bool isExplicitBallisticTrigger = !hasNegative && (
                missileKeywords.any((mk) => tLower.contains(mk)) ||
                RegExp(r'^(?:УВАГА|ЦІЛЬ|ПУСК|ВИХОДИ|ШВИДКІСНА|БАЛІСТИКА)[!\s⚠️]*$').hasMatch(text.trim()) ||
                text.contains('!!!!')
              );

              if (isExplicitBallisticTrigger && msgTime != null) {
                final windowEnd = msgTime.add(const Duration(minutes: 4));
                if (activeBallisticUntil == null || windowEnd.isAfter(activeBallisticUntil)) {
                  activeBallisticUntil = windowEnd;
                }
              }

              final bool inBallisticWindow = msgTime != null &&
                  activeBallisticUntil != null &&
                  (msgTime.isBefore(activeBallisticUntil) || msgTime.isAtSameMomentAs(activeBallisticUntil));

              final threats = (msg['threats'] as List?) ?? [];
              final bool textHasMissile = !hasNegative && (
                missileKeywords.any((mk) => tLower.contains(mk)) ||
                inBallisticWindow
              );

              for (final t in threats) {
                totalThreats++;
                final tType = (t['type'] ?? 'shahed').toString().toLowerCase();
                final tRaw = (t['rawText'] ?? '').toString().toLowerCase();

                final bool isMissile = inBallisticWindow ||
                    tType.contains('missile') ||
                    tType.contains('ballistic') ||
                    tType.contains('hypersonic') ||
                    tType.contains('cruise') ||
                    tType.contains('supersonic') ||
                    tType == 'kab' ||
                    textHasMissile ||
                    (!negativeMissileWords.any((nw) => tRaw.contains(nw)) &&
                        missileKeywords.any((mk) => tRaw.contains(mk)));

                if (isMissile) {
                  missileCount++;
                } else {
                  uavCount++;
                }

                final path = (t['path'] as List?) ?? [];
                for (final loc in activeZones) {
                  final double effectiveRadius = loc.radiusMeters + (isNightWatchMode ? 3500.0 : 0.0);
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

              // Якщо в пості не було окремих parsed threats, але є ракетні слова або діє балістичне вікно:
              if (threats.isEmpty && (textHasMissile || isExplicitBallisticTrigger || inBallisticWindow)) {
                totalThreats++;
                missileCount++;
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
                              Expanded(
                                child: Text(
                                  'Підсумки ночі (за останні 10 годин)',
                                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                                ),
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
                              Expanded(
                                child: Text(
                                  'Стан енергетики Києва (ДТЕК / КОВА)',
                                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                                ),
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
                            ...energyNews.take(2).map((item) {
                              final cleanItem = cleanHtmlString(item, maxLength: 3500);
                              return _ExpandableNewsItem(
                                text: cleanItem,
                                bulletColor: Colors.amberAccent,
                                style: TextStyle(color: Colors.grey.shade300, fontSize: 12, height: 1.3),
                              );
                            }),
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
                              Expanded(
                                child: Text(
                                  'Транспорт та Святошин / Борщагівка',
                                  style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 14),
                                ),
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
                              final cleanItem = cleanHtmlString(item, maxLength: 3500);
                              final bool isPriority = cleanItem.contains('[Святошин/Борщагівка]');
                              return _ExpandableNewsItem(
                                text: cleanItem,
                                bulletColor: isPriority ? Colors.amberAccent : Colors.cyanAccent,
                                style: TextStyle(
                                  color: isPriority ? Colors.white : Colors.grey.shade300,
                                  fontWeight: isPriority ? FontWeight.w500 : FontWeight.normal,
                                  fontSize: 12,
                                  height: 1.3,
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
                                    content: Text(
                                      '📋 Ранковий звіт успішно скопійовано!',
                                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                                    ),
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
