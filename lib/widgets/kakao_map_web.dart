import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import '../models/radio_station.dart';
import '../config/api_keys.dart';

/// 웹 플랫폼 전용 카카오맵 위젯
class KakaoMapWeb extends StatefulWidget {
  final List<RadioStation> stations;
  final Function(RadioStation)? onMarkerTap;
  final double initialLat;
  final double initialLng;
  final int initialLevel;

  const KakaoMapWeb({
    super.key,
    required this.stations,
    this.onMarkerTap,
    this.initialLat = 36.5,
    this.initialLng = 127.5,
    this.initialLevel = 13,
  });

  @override
  State<KakaoMapWeb> createState() => _KakaoMapWebState();
}

class _KakaoMapWebState extends State<KakaoMapWeb> {
  late String _viewId;
  bool _isMapReady = false;

  @override
  void initState() {
    super.initState();
    _viewId = 'kakao-map-${DateTime.now().millisecondsSinceEpoch}';
    _registerView();
  }

  void _registerView() {
    ui_web.platformViewRegistry.registerViewFactory(_viewId, (int viewId) {
      final container = html.DivElement()
        ..id = 'map-container-$viewId'
        ..style.width = '100%'
        ..style.height = '100%';

      // 지도 초기화를 약간 지연시켜 DOM이 준비되도록 함
      Future.delayed(const Duration(milliseconds: 100), () {
        _initializeMap(container.id);
      });

      return container;
    });
  }

  void _initializeMap(String containerId) {
    final jsCode = '''
      (function() {
        var container = document.getElementById('$containerId');
        if (!container) {
          console.error('Map container not found');
          return;
        }

        var options = {
          center: new kakao.maps.LatLng(${widget.initialLat}, ${widget.initialLng}),
          level: ${widget.initialLevel}
        };

        var map = new kakao.maps.Map(container, options);
        window.kakaoMapInstance_$containerId = map;

        // 마커 추가
        var markers = [];
        var infowindow = new kakao.maps.InfoWindow({zIndex: 1});

        ${_generateMarkersJs(containerId)}

        window.kakaoMapMarkers_$containerId = markers;
      })();
    ''';

    final scriptElement = html.ScriptElement()..text = jsCode;
    html.document.body?.append(scriptElement);

    setState(() {
      _isMapReady = true;
    });
  }

  String _generateMarkersJs(String containerId) {
    final buffer = StringBuffer();

    for (final station in widget.stations) {
      if (!station.hasCoordinates) continue;

      final escapedName = station.stationName
          .replaceAll("'", "\\'")
          .replaceAll('"', '\\"')
          .replaceAll('\n', ' ');
      final escapedLicense = station.licenseNumber
          .replaceAll("'", "\\'")
          .replaceAll('"', '\\"')
          .replaceAll('\n', ' ');

      buffer.writeln('''
        (function() {
          var position = new kakao.maps.LatLng(${station.latitude}, ${station.longitude});
          var marker = new kakao.maps.Marker({
            position: position,
            map: map
          });
          markers.push({id: '${station.id}', marker: marker});

          kakao.maps.event.addListener(marker, 'click', function() {
            var content = '<div style="padding:10px;min-width:150px;">' +
              '<strong>$escapedName</strong><br>' +
              '<span style="color:#666;">$escapedLicense</span>' +
              '</div>';
            infowindow.setContent(content);
            infowindow.open(map, marker);

            // Flutter로 이벤트 전달
            window.postMessage({
              type: 'markerClick',
              stationId: '${station.id}'
            }, '*');
          });
        })();
      ''');
    }

    return buffer.toString();
  }

  @override
  void didUpdateWidget(KakaoMapWeb oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 무선국 목록이 변경되면 마커 업데이트
    if (widget.stations != oldWidget.stations && _isMapReady) {
      _updateMarkers();
    }
  }

  void _updateMarkers() {
    // 기존 마커 제거 후 새로 추가하는 JavaScript 실행
    final containerId = 'map-container-${_viewId.split('-').last}';
    final jsCode = '''
      (function() {
        var map = window.kakaoMapInstance_$containerId;
        var oldMarkers = window.kakaoMapMarkers_$containerId || [];

        // 기존 마커 제거
        oldMarkers.forEach(function(item) {
          item.marker.setMap(null);
        });

        var markers = [];
        var infowindow = new kakao.maps.InfoWindow({zIndex: 1});

        ${_generateMarkersJs(containerId)}

        window.kakaoMapMarkers_$containerId = markers;
      })();
    ''';

    final scriptElement = html.ScriptElement()..text = jsCode;
    html.document.body?.append(scriptElement);
  }

  /// 지도 중심 이동
  void setCenter(double lat, double lng) {
    final containerId = 'map-container-${_viewId.split('-').last}';
    final jsCode = '''
      (function() {
        var map = window.kakaoMapInstance_$containerId;
        if (map) {
          var moveLatLon = new kakao.maps.LatLng($lat, $lng);
          map.setCenter(moveLatLon);
        }
      })();
    ''';
    final scriptElement = html.ScriptElement()..text = jsCode;
    html.document.body?.append(scriptElement);
  }

  /// 지도 레벨 설정
  void setLevel(int level) {
    final containerId = 'map-container-${_viewId.split('-').last}';
    final jsCode = '''
      (function() {
        var map = window.kakaoMapInstance_$containerId;
        if (map) {
          map.setLevel($level);
        }
      })();
    ''';
    final scriptElement = html.ScriptElement()..text = jsCode;
    html.document.body?.append(scriptElement);
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewId);
  }
}
