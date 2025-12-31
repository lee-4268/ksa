import 'package:flutter/material.dart';
import 'package:kakao_map_plugin/kakao_map_plugin.dart';
import '../models/radio_station.dart';

/// 모바일 플랫폼용 카카오맵 위젯 (Android/iOS)
class PlatformMapWidget extends StatefulWidget {
  final List<RadioStation> stations;
  final Function(RadioStation)? onMarkerTap;

  const PlatformMapWidget({
    super.key,
    required this.stations,
    this.onMarkerTap,
  });

  @override
  State<PlatformMapWidget> createState() => _PlatformMapWidgetState();
}

class _PlatformMapWidgetState extends State<PlatformMapWidget> {
  KakaoMapController? _mapController;
  Set<Marker> _markers = {};

  @override
  void didUpdateWidget(PlatformMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.stations != oldWidget.stations) {
      _addMarkers(widget.stations);
    }
  }

  void _addMarkers(List<RadioStation> stations) {
    final markers = <Marker>{};

    for (final station in stations) {
      if (!station.hasCoordinates) continue;

      // 카카오맵 스타일 마커 - 호출명칭 표시
      final markerName = station.displayName;

      final marker = Marker(
        markerId: station.id,
        latLng: LatLng(station.latitude!, station.longitude!),
        infoWindowContent: '''
          <div style="
            padding: 8px 12px;
            background: white;
            border-radius: 8px;
            box-shadow: 0 2px 6px rgba(0,0,0,0.15);
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
          ">
            <div style="
              font-size: 14px;
              font-weight: 600;
              color: #333;
              margin-bottom: 4px;
            ">$markerName</div>
            <div style="
              font-size: 12px;
              color: #666;
            ">${station.address}</div>
          </div>
        ''',
        infoWindowRemovable: true,
      );

      markers.add(marker);
    }

    setState(() {
      _markers = markers;
    });

    // 첫 번째 마커로 이동
    if (stations.isNotEmpty && _mapController != null) {
      final firstStation = stations.firstWhere(
        (s) => s.hasCoordinates,
        orElse: () => stations.first,
      );
      if (firstStation.hasCoordinates) {
        _mapController?.setCenter(
          LatLng(firstStation.latitude!, firstStation.longitude!),
        );
        _mapController?.setLevel(10);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return KakaoMap(
      onMapCreated: (controller) {
        _mapController = controller;
        _addMarkers(widget.stations);
      },
      center: LatLng(36.5, 127.5),
      currentLevel: 13,
      markers: _markers.toList(),
      onMarkerTap: (markerId, latLng, zoomLevel) {
        if (widget.onMarkerTap != null) {
          final station = widget.stations.firstWhere(
            (s) => s.id == markerId,
            orElse: () => widget.stations.first,
          );
          widget.onMarkerTap!(station);
        }
      },
    );
  }
}
