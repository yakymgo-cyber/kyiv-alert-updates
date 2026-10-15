import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:frontend/data/kyiv_gazetteer.dart';

/// Сервіс голосового сповіщення (TTS) для "Нічного вартового" та критичних загроз
class VoiceAlertService {
  static final VoiceAlertService instance = VoiceAlertService._internal();
  VoiceAlertService._internal();

  FlutterTts? _flutterTts;
  bool _isInitialized = false;
  bool _isEnabled = true;
  DateTime? _mutedUntil;

  // Захист від повторів (cooldown 120 сек) для кожної цілі
  final Map<String, DateTime> _threatCooldowns = {};

  bool get isEnabled => _isEnabled;
  bool get isMuted => _mutedUntil != null && DateTime.now().isBefore(_mutedUntil!);

  /// Увімкнення/вимкнення голосу з персистентним збереженням
  Future<void> setEnabled(bool enabled) async {
    _isEnabled = enabled;
    if (!enabled) {
      await stop();
    }
    await _saveSettings();
  }

  /// Тимчасова тиша (наприклад, 15 хвилин)
  void muteFor(Duration duration) {
    _mutedUntil = DateTime.now().add(duration);
    stop();
  }

  void unmute() {
    _mutedUntil = null;
  }

  /// Ініціалізація рушія TTS
  Future<void> init() async {
    if (_isInitialized || kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) return;
    try {
      await _loadSettings();
      _flutterTts = FlutterTts();

      // Налаштування української мови та спокійного темпу
      await _flutterTts!.setLanguage('uk-UA');
      await _flutterTts!.setSpeechRate(0.52);
      await _flutterTts!.setPitch(1.0);

      if (!kIsWeb && Platform.isAndroid) {
        await _flutterTts!.setVolume(1.0);
      }

      _isInitialized = true;
    } catch (e) {
      debugPrint('VoiceAlertService init error: $e');
    }
  }

  /// Зупинити поточне мовлення
  Future<void> stop() async {
    try {
      await _flutterTts?.stop();
    } catch (_) {}
  }

  /// Озвучення довільного тексту українською
  Future<void> speak(String text) async {
    if (!_isEnabled || isMuted) return;
    try {
      if (!_isInitialized) {
        await init();
      }
      if (_flutterTts != null) {
        await _flutterTts!.stop();
        await _flutterTts!.speak(text);
      }
    } catch (e) {
      debugPrint('VoiceAlertService speak error: $e');
    }
  }

  /// Озвучення загрози балістики для Києва та області
  Future<void> announceBallistics() async {
    const key = 'ballistics_alert';
    final now = DateTime.now();
    final lastTime = _threatCooldowns[key];
    if (lastTime != null && now.difference(lastTime).inSeconds < 120) {
      return; // 2 хвилини cooldown
    }
    _threatCooldowns[key] = now;

    await speak('Увага! Загроза балістики для Києва та області. Перейдіть в укриття!');
  }

  /// Озвучення небезпеки біля зони безпеки
  Future<void> announceThreatNearZone({
    required String threatKey,
    required String threatType,
    required String zoneName,
    required double distanceKm,
    required double etaMinutes,
  }) async {
    final now = DateTime.now();
    final lastTime = _threatCooldowns[threatKey];
    if (lastTime != null && now.difference(lastTime).inSeconds < 120) {
      return; // 2 хвилини cooldown для цієї цілі
    }
    _threatCooldowns[threatKey] = now;

    final friendlyType = toFriendlyVoiceThreatType(threatType);
    final distStr = distanceKm < 10 ? distanceKm.toStringAsFixed(1) : distanceKm.round().toString();
    final etaStr = etaMinutes.ceil().clamp(1, 120).toString();

    final text = 'Увага! $friendlyType поблизу зони $zoneName. Відстань $distStr кілометрів, час підльоту близько $etaStr хвилин.';
    await speak(text);
  }

  /// Перетворення системного типу загрози на природний український голос
  static String toFriendlyVoiceThreatType(String type) {
    switch (type) {
      case 'shahed_jet':
        return 'Реактивний БпЛА';
      case 'shahed':
        return 'Ударний БпЛА';
      case 'missile_ballistic':
        return 'Балістична ціль';
      case 'missile_cruise':
        return 'Крилата ракета';
      case 'missile_hypersonic':
        return 'Гіперзвукова ракета';
      case 'kab':
        return 'Керована авіабомба';
      case 'uav_recon':
        return 'Розвідувальний дрон';
      case 'uav_guided':
        return 'Керований дрон';
      default:
        return 'Повітряна ціль';
    }
  }

  Future<void> _loadSettings() async {
    try {
      final file = await getAppStorageFile('voice_settings.json');
      if (file != null && await file.exists()) {
        final content = await file.readAsString();
        final map = json.decode(content) as Map<String, dynamic>;
        if (map['enabled'] is bool) {
          _isEnabled = map['enabled'] as bool;
        }
      }
    } catch (_) {}
  }

  Future<void> _saveSettings() async {
    try {
      final file = await getAppStorageFile('voice_settings.json');
      if (file != null) {
        await file.writeAsString(json.encode({'enabled': _isEnabled}));
      }
    } catch (_) {}
  }
}
