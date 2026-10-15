# -*- coding: utf-8 -*-
import sys

with open('frontend/lib/main.dart', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Update empty path branch
old_empty_path = """                                          existing['rawText'] = msg['text']?.toString() ?? '';
                                          existing['msgId'] = msg['id'];
                                          existing['channel'] = msg['channel'];"""

new_empty_path = """                                          existing['rawText'] = msg['text']?.toString() ?? '';
                                          existing['msgId'] = msg['id'];
                                          final hist = (existing['historyMsgIds'] as Set<dynamic>? ?? <dynamic>{});
                                          hist.add(msg['id']);
                                          existing['historyMsgIds'] = hist;
                                          existing['channel'] = msg['channel'];"""

assert old_empty_path in content, "old_empty_path not found"
content = content.replace(old_empty_path, new_empty_path, 1)

# 2. Update main merge loop
old_merge_block = """                                        // Якщо цілі з одного повідомлення і ми їх розділили (parseLocalThreats повернув кілька) — не об'єднуємо їх між собою!
                                        if (existing['msgId'] == msg['id']) {
                                          continue;
                                        }

                                        // Розрахунок дозволеної дистанції з урахуванням жорсткого кінематичного правила Multi-Target Tracking
                                        final bool isAnyMissile = isMissileThreat || existingIsMissile || activeBallisticOrMissileContext;
                                        final bool isJetThreat = (existingType == 'shahed_jet' || rawType == 'shahed_jet');
                                        final double effSpeed = isAnyMissile ? math.max(speed, 5000.0) : (isJetThreat ? math.max(speed, 480.0) : speed);

                                        // maxDistanceKm = (speedKmh * elapsedHours * 1.4).clamp(4.0, 22.0)
                                        final double maxDistanceKm = isAnyMissile
                                            ? (effSpeed * timeDiffHours * 1.2).clamp(10.0, 80.0)
                                            : (effSpeed * timeDiffHours * 1.4).clamp(4.0, 22.0);
                                        final double allowedDistMeters = maxDistanceKm * 1000.0;

                                        // Якщо нова точка знаходиться далі ніж allowedDistMeters (максимум 22 км для БпЛА) —
                                        // це ОКРЕМА нова ціль! Не зливати і не видаляти стару ціль!
                                        if (distMeters > allowedDistMeters) {
                                          continue;
                                        }

                                        // Заборона малювання лінії вектора між точками з різних повідомлень, якщо відстань > 25 км
                                        if (distMeters > 25000.0) {
                                          continue;
                                        }

                                        // Об'єднуємо послідовні точки однієї цілі
                                        if (distMeters <= allowedDistMeters) {
                                        if (isAnyMissile) {
                                          if (existing['type'] != 'missile_hypersonic' && existing['type'] != 'missile_cruise') {
                                            existing['type'] = 'missile_ballistic';
                                            existing['speed'] = 5000.0;
                                            existing['label'] = 'Балістична / Швидкісна ціль';
                                          }
                                        } else if (isJetThreat) {
                                          // No Downgrade: якщо ціль була або стала shahed_jet, не повертати до shahed
                                          if (!hasPistonDroneInMsg) {
                                            existing['type'] = 'shahed_jet';
                                            existing['speed'] = 480.0;
                                            existing['label'] = 'Реактивний БпЛА';
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
                                            if (d > 500 && d <= 25000.0) {
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
                                          existing['channel'] = msg['channel'];"""

new_merge_block = """                                        // Якщо цілі з одного повідомлення і ми їх розділили (parseLocalThreats повернув кілька) — не об'єднуємо їх між собою!
                                        if (existing['msgId'] == msg['id']) {
                                          continue;
                                        }

                                        // Перевірка на явну відповідь (reply) у Telegram-каналі:
                                        final replyToId = msg['reply_to_msg_id'];
                                        final existingHistory = existing['historyMsgIds'] as Set<dynamic>?;
                                        final bool isExplicitReply = (replyToId != null &&
                                            (existing['msgId'] == replyToId || (existingHistory != null && existingHistory.contains(replyToId))));

                                        // Маркери наявності окремих/нових цілей
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

                                        if (hasMultiTargetMarker && !isExplicitReply) {
                                          continue;
                                        }

                                        // Розрахунок дозволеної дистанції з урахуванням кінематики:
                                        // Для реактивних БпЛА (480-600 км/год) вектор руху за 3-5 хв становить 30-50 км!
                                        final bool isAnyMissile = isMissileThreat || existingIsMissile || activeBallisticOrMissileContext;
                                        final bool isJetThreat = (existingType == 'shahed_jet' || rawType == 'shahed_jet');
                                        final double effSpeed = isAnyMissile ? math.max(speed, 5000.0) : (isJetThreat ? math.max(speed, 480.0) : speed);

                                        final double maxDistanceKm = isAnyMissile
                                            ? (effSpeed * timeDiffHours * 1.2).clamp(10.0, 90.0)
                                            : (isJetThreat
                                                ? (effSpeed * timeDiffHours * 1.6).clamp(10.0, 70.0)
                                                : (effSpeed * timeDiffHours * 1.4).clamp(4.0, 22.0));
                                        final double allowedDistMeters = maxDistanceKm * 1000.0;
                                        final double maxAllowedLegMeters = isAnyMissile ? 90000.0 : (isJetThreat ? 70000.0 : 25000.0);

                                        // Перевірка допустимої відстані:
                                        if (!isExplicitReply) {
                                          if (distMeters > allowedDistMeters || distMeters > maxAllowedLegMeters) {
                                            continue;
                                          }
                                        } else {
                                          // Прямий Reply у Telegram гарантує послідовність повідомлень одного треку
                                          if (distMeters > (isJetThreat ? 75000.0 : (isAnyMissile ? 95000.0 : 35000.0))) {
                                            continue;
                                          }
                                        }

                                        // Об'єднуємо послідовні точки однієї цілі
                                        if (isAnyMissile) {
                                          if (existing['type'] != 'missile_hypersonic' && existing['type'] != 'missile_cruise') {
                                            existing['type'] = 'missile_ballistic';
                                            existing['speed'] = 5000.0;
                                            existing['label'] = 'Балістична / Швидкісна ціль';
                                          }
                                        } else if (isJetThreat) {
                                          // No Downgrade: якщо ціль була або стала shahed_jet, не повертати до shahed
                                          if (!hasPistonDroneInMsg) {
                                            existing['type'] = 'shahed_jet';
                                            existing['speed'] = 480.0;
                                            existing['label'] = 'Реактивний БпЛА';
                                          }
                                        }

                                        bool pointAdded = false;
                                        for (int k = 0; k < path.length; k++) {
                                          final pt = path[k];
                                          final d = const Distance().as(LengthUnit.Meter, existingPath.last, pt);
                                          if (d > 500 && (d <= maxAllowedLegMeters || isExplicitReply)) {
                                            existingPath.add(pt);
                                            pointAdded = true;
                                            if (k < locNames.length && (existingNames.isEmpty || existingNames.last != locNames[k])) {
                                              existingNames.add(locNames[k]);
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
                                        final hist = (existing['historyMsgIds'] as Set<dynamic>? ?? <dynamic>{});
                                        hist.add(msg['id']);
                                        existing['historyMsgIds'] = hist;
                                        existing['channel'] = msg['channel'];"""

assert old_merge_block in content, "old_merge_block not found"
content = content.replace(old_merge_block, new_merge_block, 1)

# 3. Update threats.add initialization to include historyMsgIds
old_threats_add = """                                      'text': msgTextLower,
                                      'rawText': msg['text']?.toString() ?? '',
                                      'msgId': msg['id'],
                                      'channel': msg['channel'],"""

new_threats_add = """                                      'text': msgTextLower,
                                      'rawText': msg['text']?.toString() ?? '',
                                      'msgId': msg['id'],
                                      'historyMsgIds': <dynamic>{msg['id']},
                                      'channel': msg['channel'],"""

assert old_threats_add in content, "old_threats_add not found"
content = content.replace(old_threats_add, new_threats_add, 1)

# 4. Update messages without locations to check replyToId first
old_alt_block = """                                  final msgChannel = msg['channel'];
                                  Map<String, dynamic>? targetThreat;
                                  for (int ti = threats.length - 1; ti >= 0; ti--) {"""

new_alt_block = """                                  final replyToId = msg['reply_to_msg_id'];
                                  Map<String, dynamic>? targetThreat;
                                  if (replyToId != null) {
                                    for (int ti = threats.length - 1; ti >= 0; ti--) {
                                      final candidate = threats[ti];
                                      final history = candidate['historyMsgIds'] as Set<dynamic>?;
                                      if (candidate['msgId'] == replyToId || (history != null && history.contains(replyToId))) {
                                        targetThreat = candidate;
                                        break;
                                      }
                                    }
                                  }

                                  final msgChannel = msg['channel'];
                                  if (targetThreat == null) {
                                    for (int ti = threats.length - 1; ti >= 0; ti--) {"""

old_alt_fallback = """                                  if (targetThreat == null && threats.isNotEmpty) {
                                    for (int ti = threats.length - 1; ti >= 0; ti--) {
                                      final candidate = threats[ti];
                                      final candTime = candidate['lastUpdated'] as DateTime?;
                                      if (candTime != null && msgTime.difference(candTime).inMinutes.abs() <= 3) {
                                        targetThreat = candidate;
                                        break;
                                      }
                                    }
                                  }"""

new_alt_fallback = """                                  }

                                  if (targetThreat == null && threats.isNotEmpty) {
                                    for (int ti = threats.length - 1; ti >= 0; ti--) {
                                      final candidate = threats[ti];
                                      final candTime = candidate['lastUpdated'] as DateTime?;
                                      if (candTime != null && msgTime.difference(candTime).inMinutes.abs() <= 3) {
                                        targetThreat = candidate;
                                        break;
                                      }
                                    }
                                  }"""

assert old_alt_block in content, "old_alt_block not found"
content = content.replace(old_alt_block, new_alt_block, 1)
assert old_alt_fallback in content, "old_alt_fallback not found"
content = content.replace(old_alt_fallback, new_alt_fallback, 1)

with open('frontend/lib/main.dart', 'w', encoding='utf-8') as f:
    f.write(content)

print("SUCCESS: main.dart updated successfully!")
