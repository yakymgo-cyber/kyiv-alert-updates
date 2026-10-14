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
  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (PointerSignalEvent event) {
        if (event is PointerScrollEvent) {
          final camera = widget.mapController.camera;
          
          // Detect mouse wheel vs trackpad scroll. 
          // Mouse wheel on Windows usually emits a delta of exactly 120.0 or 100.0, or at least > 40.
          // Trackpad scrolls have small fractional values and frequent events.
          bool isMouseWheel = event.kind == PointerDeviceKind.mouse && (event.scrollDelta.dy.abs() >= 40.0 || event.scrollDelta.dx == 0 && event.scrollDelta.dy.abs() % 10 == 0);
          
          if (isMouseWheel) {
            // ZOOOOOM
            final zoomDelta = event.scrollDelta.dy > 0 ? -0.5 : 0.5;
            final newZoom = (camera.zoom + zoomDelta).clamp(5.0, 18.0);
            widget.mapController.move(camera.center, newZoom);
          } else {
            // PAAAN
            final currentCenter = camera.latLngToScreenOffset(camera.center);
            final newCenterPixels = Offset(currentCenter.dx + event.scrollDelta.dx, currentCenter.dy + event.scrollDelta.dy);
            final newCenterLatLng = camera.screenOffsetToLatLng(newCenterPixels);
            widget.mapController.move(newCenterLatLng, camera.zoom);
          }
        }
      },
      onPointerPanZoomUpdate: (PointerPanZoomUpdateEvent event) {
        final camera = widget.mapController.camera;
        if (event.scale != 1.0) {
          // ZOOOOOM
          // event.scale is relative to 1.0. For example, 1.1 means zoom in by 10%.
          // We map it to map zoom levels:
          final zoomDelta = (event.scale - 1.0) * 2.0; 
          final newZoom = (camera.zoom + zoomDelta).clamp(5.0, 18.0);
          widget.mapController.move(camera.center, newZoom);
        } else if (event.panDelta.dx != 0 || event.panDelta.dy != 0) {
          // PAAAN
          final currentCenter = camera.latLngToScreenOffset(camera.center);
          final newCenterPixels = Offset(currentCenter.dx - event.panDelta.dx, currentCenter.dy - event.panDelta.dy);
          final newCenterLatLng = camera.screenOffsetToLatLng(newCenterPixels);
          widget.mapController.move(newCenterLatLng, camera.zoom);
        }
      },
      child: widget.child,
    );
  }
}
