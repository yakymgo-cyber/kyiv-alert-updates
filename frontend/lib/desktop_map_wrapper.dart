import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

class DesktopMapWrapper extends StatefulWidget {
  final MapController mapController;
  final Widget child;

  const DesktopMapWrapper({super.key, required this.mapController, required this.child});

  @override
  State<DesktopMapWrapper> createState() => _DesktopMapWrapperState();
}

class _DesktopMapWrapperState extends State<DesktopMapWrapper> {
  double _baseScale = 1.0;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (PointerSignalEvent event) {
        if (event is PointerScrollEvent) {
          final camera = widget.mapController.camera;

          bool isMouseWheel = event.kind == PointerDeviceKind.mouse &&
              (event.scrollDelta.dy.abs() >= 30.0 ||
                  (event.scrollDelta.dx == 0 && event.scrollDelta.dy.abs() % 10 == 0));

          if (isMouseWheel) {
            final zoomDelta = event.scrollDelta.dy > 0 ? -0.4 : 0.4;
            final oldZoom = camera.zoom;
            final newZoom = (oldZoom + zoomDelta).clamp(5.0, 18.0);
            if ((newZoom - oldZoom).abs() < 0.001) return;

            // Zoom towards mouse cursor position
            final cursorOffset = event.localPosition;
            final centerOffset = camera.latLngToScreenOffset(camera.center);
            final scaleFactor = 1.0 - (1.0 / (zoomDelta > 0 ? 1.32 : 0.76));
            final shiftedPixels = Offset(
              centerOffset.dx + (cursorOffset.dx - centerOffset.dx) * scaleFactor * 0.45,
              centerOffset.dy + (cursorOffset.dy - centerOffset.dy) * scaleFactor * 0.45,
            );
            final newCenter = camera.screenOffsetToLatLng(shiftedPixels);
            widget.mapController.move(newCenter, newZoom);
          } else {
            final currentCenter = camera.latLngToScreenOffset(camera.center);
            final newCenterPixels = Offset(
              currentCenter.dx + event.scrollDelta.dx,
              currentCenter.dy + event.scrollDelta.dy,
            );
            final newCenterLatLng = camera.screenOffsetToLatLng(newCenterPixels);
            widget.mapController.move(newCenterLatLng, camera.zoom);
          }
        }
      },
      onPointerPanZoomStart: (PointerPanZoomStartEvent event) {
        _baseScale = 1.0;
      },
      onPointerPanZoomUpdate: (PointerPanZoomUpdateEvent event) {
        final camera = widget.mapController.camera;
        if ((event.scale - _baseScale).abs() > 0.005) {
          final zoomDelta = (event.scale - _baseScale) * 2.2;
          _baseScale = event.scale;
          final newZoom = (camera.zoom + zoomDelta).clamp(5.0, 18.0);
          widget.mapController.move(camera.center, newZoom);
        } else if (event.panDelta.dx != 0 || event.panDelta.dy != 0) {
          final currentCenter = camera.latLngToScreenOffset(camera.center);
          final newCenterPixels = Offset(
            currentCenter.dx - event.panDelta.dx,
            currentCenter.dy - event.panDelta.dy,
          );
          final newCenterLatLng = camera.screenOffsetToLatLng(newCenterPixels);
          widget.mapController.move(newCenterLatLng, camera.zoom);
        }
      },
      child: widget.child,
    );
  }
}

