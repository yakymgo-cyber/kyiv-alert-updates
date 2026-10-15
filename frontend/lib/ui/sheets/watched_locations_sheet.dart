import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:frontend/data/kyiv_gazetteer.dart';
import 'package:frontend/models/alert_models.dart';
import 'package:frontend/services/voice_alert_service.dart';


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


  void showWatchedLocationsSheet({
  required BuildContext context,
  required WidgetRef ref,
  required MapController mapController,
  required dynamic watchedLocationsProvider,
}) async {
    final searchCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    double radiusKm = 4.0;
    List<Map<String, dynamic>> searchResults = [];
    bool isSearching = false;
    bool isAddingNew = false;
    Map<String, dynamic>? selectedResult;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
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
                        Row(
                          children: [
                            IconButton(
                              tooltip: VoiceAlertService.instance.isEnabled
                                  ? 'Голосовий диктор (Увімкнено)'
                                  : 'Голосовий диктор (Вимкнено)',
                              icon: Icon(
                                VoiceAlertService.instance.isEnabled
                                    ? Icons.record_voice_over
                                    : Icons.voice_over_off,
                                color: VoiceAlertService.instance.isEnabled
                                    ? Colors.cyanAccent
                                    : Colors.grey,
                                size: 22,
                              ),
                              onPressed: () async {
                                await VoiceAlertService.instance.setEnabled(!VoiceAlertService.instance.isEnabled);
                                setSheetState(() {});
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, color: Colors.grey),
                              onPressed: () => Navigator.pop(sheetContext),
                            ),
                          ],
                        ),
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
                                mapController.move(loc.point, 13.5);
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
                                    const SnackBar(
                                      content: Text(
                                        'Спочатку знайдіть та виберіть адресу!',
                                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                                      ),
                                    ),
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
                                mapController.move(newLoc.point, 13.5);
                                Navigator.pop(sheetContext);

                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Зону "$name" успішно додано!',
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                                    ),
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

    searchCtrl.dispose();
    nameCtrl.dispose();
  }

  void showAddPointFromMapDialog({
  required BuildContext context,
  required LatLng point,
  required WidgetRef ref,
  required dynamic watchedLocationsProvider,
}) async {
    final nameCtrl = TextEditingController(text: 'Моя точка');
    double radiusKm = 4.0;

    await showModalBottomSheet(
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
                            content: Text(
                              'Зону "$name" успішно додано!',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                            ),
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

    nameCtrl.dispose();
  }
