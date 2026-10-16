import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import '../data/kyiv_gazetteer.dart';

/// 1x1 transparent RGBA PNG bytes fallback to prevent FlutterMap uncaught exceptions.
final Uint8List kTransparent1x1Png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0B, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x00, 0x00, 0x00,
  0x02, 0x00, 0x01, 0xE2, 0x21, 0xBC, 0x33, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Custom [TileProvider] that caches OpenStreetMap PNG tiles locally on disk.
/// - If tile exists on disk and is < 14 days old: served immediately from disk.
/// - If missing or stale: downloaded via HTTP (timeout 6s, User-Agent 'ua.kyiv.alert.monitor/1.2') and saved to disk.
/// - If network fails and stale tile exists on disk: served from disk (blackout resilience).
/// - If neither network nor cache available: returns 1x1 transparent PNG.
class LocalCachedTileProvider extends TileProvider {
  LocalCachedTileProvider({super.headers});

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    return CachedTileImageProvider(
      url: url,
      coordinates: coordinates,
      headers: headers,
    );
  }
}

class CachedTileImageProvider extends ImageProvider<CachedTileImageProvider> {
  static final http.Client _sharedClient = http.Client();
  static const int _maxTileBytes = 524288; // 512 KB max tile size

  final String url;
  final TileCoordinates coordinates;
  final Map<String, String> headers;

  const CachedTileImageProvider({
    required this.url,
    required this.coordinates,
    this.headers = const {},
  });

  static bool _isValidPng(Uint8List bytes) {
    return bytes.length >= 8 &&
        bytes.length <= _maxTileBytes &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A;
  }

  @override
  Future<CachedTileImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<CachedTileImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    CachedTileImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(_loadAsync(key, decode));
  }

  Future<ImageInfo> _loadAsync(
    CachedTileImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    Uint8List? imageBytes;
    File? tileFile;

    final int z = key.coordinates.z;
    final int x = key.coordinates.x;
    final int y = key.coordinates.y;

    if (z >= 0 && z <= 22 && x >= 0 && y >= 0) {
      try {
        tileFile = await getAppStorageFile(
          'map_tiles/tile_${z}_${x}_$y.png',
        );
      } catch (_) {
        tileFile = null;
      }
    }

    // 1. Check if file exists and is younger than 14 days
    if (tileFile != null) {
      try {
        if (await tileFile.exists()) {
          final stat = await tileFile.stat();
          final age = DateTime.now().difference(stat.modified);
          if (age.inDays < 14 && stat.size > 8 && stat.size <= _maxTileBytes) {
            final diskBytes = await tileFile.readAsBytes();
            if (_isValidPng(diskBytes)) {
              imageBytes = diskBytes;
            }
          }
        }
      } catch (_) {
        // Disk read issue, proceed to network
      }
    }

    // 2. Fetch from network if not cached or stale
    if (imageBytes == null || imageBytes.isEmpty) {
      try {
        final uri = Uri.tryParse(key.url);
        if (uri != null && uri.scheme == 'https') {
          final requestHeaders = {
            'User-Agent': 'ua.kyiv.alert.monitor/1.2',
            ...key.headers,
          };
          final response = await _sharedClient
              .get(uri, headers: requestHeaders)
              .timeout(const Duration(seconds: 6));

          if (response.statusCode == 200 && _isValidPng(response.bodyBytes)) {
            imageBytes = response.bodyBytes;
            if (tileFile != null) {
              final f = tileFile;
              final bytesToSave = response.bodyBytes;
              Future.microtask(() async {
                try {
                  if (!await f.parent.exists()) {
                    await f.parent.create(recursive: true);
                  }
                  await f.writeAsBytes(bytesToSave, flush: true);
                } catch (_) {}
              });
            }
          }
        }
      } catch (_) {
        // Network timeout / offline
      }
    }

    // 3. Fallback to stale cache during blackout or network error
    if ((imageBytes == null || imageBytes.isEmpty) && tileFile != null) {
      try {
        if (await tileFile.exists()) {
          final diskBytes = await tileFile.readAsBytes();
          if (_isValidPng(diskBytes)) {
            imageBytes = diskBytes;
          }
        }
      } catch (_) {}
    }

    // 4. Fallback to 1x1 transparent PNG if completely unavailable
    if (imageBytes == null || imageBytes.isEmpty) {
      imageBytes = kTransparent1x1Png;
    }

    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(imageBytes);
      final codec = await decode(buffer);
      final frame = await codec.getNextFrame();
      return ImageInfo(image: frame.image);
    } catch (_) {
      final buffer = await ui.ImmutableBuffer.fromUint8List(kTransparent1x1Png);
      final codec = await decode(buffer);
      final frame = await codec.getNextFrame();
      return ImageInfo(image: frame.image);
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CachedTileImageProvider &&
        other.url == url &&
        other.coordinates.x == coordinates.x &&
        other.coordinates.y == coordinates.y &&
        other.coordinates.z == coordinates.z;
  }

  @override
  int get hashCode =>
      Object.hash(url, coordinates.x, coordinates.y, coordinates.z);
}
