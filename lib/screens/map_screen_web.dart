// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import '../models/radio_station.dart';

/// 검사대기 마커 이미지 경로 (파란색)
const String _pendingMarkerPath = 'images/marker_pending.svg';

/// 검사완료 마커 이미지 경로 (빨간색)
const String _inspectedMarkerPath = 'images/marker_inspected.svg';

/// 웹 플랫폼용 카카오맵 위젯
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
  late String _viewId;
  late String _containerId;
  bool _isMapReady = false;
  bool _isKakaoLoaded = false;
  Timer? _kakaoCheckTimer;
  String? _errorMessage;
  String _lastStationsHash = ''; // 이전 상태 해시 저장용

  @override
  void initState() {
    super.initState();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    _viewId = 'kakao-map-$timestamp';
    _containerId = 'map-container-$timestamp';
    _checkKakaoSdkLoaded();
    _setupMessageListener();
  }

  @override
  void dispose() {
    _kakaoCheckTimer?.cancel();
    super.dispose();
  }

  void _checkKakaoSdkLoaded() {
    int checkCount = 0;
    const maxChecks = 50;

    _kakaoCheckTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      checkCount++;

      if (_checkKakaoGlobal()) {
        timer.cancel();
        debugPrint('카카오맵 SDK 로드 완료');
        setState(() {
          _isKakaoLoaded = true;
        });
        _registerView();
      } else if (checkCount >= maxChecks) {
        timer.cancel();
        debugPrint('카카오맵 SDK 로드 시간 초과');
        setState(() {
          _errorMessage = '카카오맵 SDK를 로드할 수 없습니다.\n카카오 개발자 콘솔에서 localhost 도메인이 등록되어 있는지 확인하세요.';
        });
      }
    });
  }

  bool _checkKakaoGlobal() {
    try {
      final kakao = js.context['kakao'];
      if (kakao == null) return false;
      final maps = kakao['maps'];
      return maps != null;
    } catch (e) {
      debugPrint('카카오 SDK 체크 오류: $e');
      return false;
    }
  }

  void _setupMessageListener() {
    html.window.onMessage.listen((event) {
      if (event.data is Map) {
        final data = event.data as Map;
        if (data['type'] == 'markerClick') {
          final lat = data['lat'] as num?;
          final lng = data['lng'] as num?;

          if (lat != null && lng != null && widget.onMarkerTap != null) {
            // 같은 좌표에 있는 모든 스테이션 찾기
            final stationsAtLocation = widget.stations.where((s) =>
              s.hasCoordinates &&
              s.latitude == lat.toDouble() &&
              s.longitude == lng.toDouble()
            ).toList();

            if (stationsAtLocation.length > 1) {
              // 여러 개면 선택 다이얼로그 표시
              _showStationSelectionDialog(stationsAtLocation);
            } else if (stationsAtLocation.length == 1) {
              // 1개면 바로 콜백 호출
              widget.onMarkerTap!(stationsAtLocation.first);
            }
          }
        }
      }
    });
  }

  /// 겹친 마커 선택 다이얼로그
  void _showStationSelectionDialog(List<RadioStation> stations) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.layers, color: Colors.blue),
            const SizedBox(width: 8),
            Text('${stations.length}개 장소가 겹쳐있습니다'),
          ],
        ),
        content: SizedBox(
          width: 320,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: stations.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final station = stations[index];
              return ListTile(
                leading: Icon(
                  Icons.location_on,
                  color: station.isInspected ? Colors.red : Colors.blue,
                ),
                title: Text(
                  station.displayName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                  station.address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                trailing: station.isInspected
                    ? const Icon(Icons.check_circle, color: Colors.green, size: 20)
                    : null,
                onTap: () {
                  Navigator.pop(ctx);
                  widget.onMarkerTap?.call(station);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  void _registerView() {
    ui_web.platformViewRegistry.registerViewFactory(_viewId, (int viewId) {
      final container = html.DivElement()
        ..id = _containerId
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.backgroundColor = '#e8e8e8';

      Future.delayed(const Duration(milliseconds: 300), () {
        _initializeMap();
      });

      return container;
    });

    if (mounted) {
      setState(() {});
    }
  }

  void _initializeMap() {
    final jsCode = '''
      (function() {
        if (typeof kakao === 'undefined' || typeof kakao.maps === 'undefined') {
          console.error('Kakao Maps SDK not loaded yet');
          return;
        }

        var container = document.getElementById('$_containerId');
        if (!container) {
          console.error('Map container not found: $_containerId');
          return;
        }

        var options = {
          center: new kakao.maps.LatLng(36.5, 127.5),
          level: 13
        };

        var map = new kakao.maps.Map(container, options);
        window['kakaoMapInstance_$_containerId'] = map;

        var infowindow = new kakao.maps.InfoWindow({zIndex: 1});
        window['kakaoInfoWindow_$_containerId'] = infowindow;

        window['kakaoMapMarkers_$_containerId'] = [];

        console.log('Kakao Map initialized: $_containerId');
      })();
    ''';

    final scriptElement = html.ScriptElement()..text = jsCode;
    html.document.body?.append(scriptElement);

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        // 초기 해시 저장
        _lastStationsHash = _getStationsHash(widget.stations);
        _updateMarkers();
        setState(() {
          _isMapReady = true;
        });
      }
    });
  }

  /// 상태 변경 감지를 위한 해시 생성 (ID + isInspected 조합)
  String _getStationsHash(List<RadioStation> stations) {
    return stations.map((s) => '${s.id}:${s.isInspected}').join(',');
  }

  @override
  void didUpdateWidget(PlatformMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // stations 리스트가 변경되었을 때 마커 업데이트
    if (_isMapReady) {
      final newHash = _getStationsHash(widget.stations);

      // 이전에 저장된 해시와 비교 (oldWidget 비교 대신)
      if (_lastStationsHash != newHash) {
        debugPrint('Stations hash changed: $_lastStationsHash -> $newHash');
        _lastStationsHash = newHash;
        _updateMarkers();
      }
    }
  }

  void _updateMarkers() {
    if (!_isKakaoLoaded) {
      debugPrint('Kakao not loaded, skipping marker update');
      return;
    }

    debugPrint('Updating markers for ${widget.stations.length} stations');

    // 기존 마커 및 오버레이 제거
    final clearJs = '''
      (function() {
        if (typeof kakao === 'undefined') return;
        var markers = window['kakaoMapMarkers_$_containerId'] || [];
        var overlays = window['kakaoMapOverlays_$_containerId'] || [];
        console.log('Clearing ' + markers.length + ' markers and ' + overlays.length + ' overlays');
        markers.forEach(function(marker) {
          marker.setMap(null);
        });
        overlays.forEach(function(overlay) {
          overlay.setMap(null);
        });
        window['kakaoMapMarkers_$_containerId'] = [];
        window['kakaoMapOverlays_$_containerId'] = [];
      })();
    ''';
    html.document.body?.append(html.ScriptElement()..text = clearJs);

    // 새 마커 추가
    for (final station in widget.stations) {
      if (!station.hasCoordinates) {
        debugPrint('Station ${station.id} has no coordinates');
        continue;
      }

      final escapedName = _escapeJs(station.displayName);
      final escapedAddress = _escapeJs(station.address);
      final stationId = station.id;

      debugPrint('Adding marker for ${station.displayName} at ${station.latitude}, ${station.longitude}');

      // 검사완료 여부에 따른 마커 색상 결정
      final isInspected = station.isInspected;

      // SVG 마커 이미지 경로 (검사대기: 파란색, 검사완료: 빨간색)
      final markerImagePath = isInspected
          ? _inspectedMarkerPath
          : _pendingMarkerPath;

      final addMarkerJs = '''
        (function() {
          if (typeof kakao === 'undefined') {
            console.error('kakao not defined');
            return;
          }
          var map = window['kakaoMapInstance_$_containerId'];
          var infowindow = window['kakaoInfoWindow_$_containerId'];
          if (!map) {
            console.error('Map not found: $_containerId');
            return;
          }

          var position = new kakao.maps.LatLng(${station.latitude}, ${station.longitude});

          // 원본 SVG 파일 경로 사용
          var imageSrc = "$markerImagePath";
          var imageSize = new kakao.maps.Size(30, 30);
          var imageOption = {offset: new kakao.maps.Point(15, 30)};
          var markerImage = new kakao.maps.MarkerImage(imageSrc, imageSize, imageOption);

          var marker = new kakao.maps.Marker({
            position: position,
            map: map,
            image: markerImage,
            title: '$escapedName'
          });

          window['kakaoMapMarkers_$_containerId'].push(marker);

          console.log('Marker added: $escapedName (inspected: $isInspected)');

          // 마커에 표시할 인포윈도우 내용
          var isInspectedFlag = ${isInspected ? 'true' : 'false'};
          var iwContent = '<div style="padding:12px 16px;width:250px;font-size:13px;box-sizing:border-box;">' +
            '<div style="color:#333;font-weight:bold;margin-bottom:8px;word-break:keep-all;line-height:1.4;">$escapedName</div>' +
            '<div style="color:#666;font-size:12px;line-height:1.5;word-wrap:break-word;white-space:pre-wrap;">$escapedAddress</div>' +
            (isInspectedFlag ? '<div style="color:#FF0000;font-size:11px;font-weight:bold;margin-top:8px;">✓ 검사완료</div>' : '') +
            '</div>';

          kakao.maps.event.addListener(marker, 'click', function() {
            infowindow.setContent(iwContent);
            infowindow.open(map, marker);

            window.postMessage({
              type: 'markerClick',
              stationId: '$stationId',
              lat: ${station.latitude},
              lng: ${station.longitude}
            }, '*');
          });
        })();
      ''';
      html.document.body?.append(html.ScriptElement()..text = addMarkerJs);
    }

    // 마커가 있으면 첫 번째 마커로 중심 이동 및 줌 레벨 조정
    if (widget.stations.isNotEmpty) {
      final stationsWithCoords = widget.stations.where((s) => s.hasCoordinates).toList();
      if (stationsWithCoords.isNotEmpty) {
        // 마커가 여러 개면 모든 마커가 보이도록 bounds 설정
        if (stationsWithCoords.length > 1) {
          _fitBounds(stationsWithCoords);
        } else {
          // 마커가 1개면 해당 위치로 이동
          final first = stationsWithCoords.first;
          setCenter(first.latitude!, first.longitude!);
          setLevel(3);
        }
      }
    }
  }

  void _fitBounds(List<RadioStation> stations) {
    final boundsJs = StringBuffer();
    boundsJs.write('''
      (function() {
        if (typeof kakao === 'undefined') return;
        var map = window['kakaoMapInstance_$_containerId'];
        if (!map) return;

        var bounds = new kakao.maps.LatLngBounds();
    ''');

    for (final station in stations) {
      if (station.hasCoordinates) {
        boundsJs.write('''
        bounds.extend(new kakao.maps.LatLng(${station.latitude}, ${station.longitude}));
        ''');
      }
    }

    boundsJs.write('''
        map.setBounds(bounds);
        console.log('Bounds set for ${stations.length} markers');
      })();
    ''');

    html.document.body?.append(html.ScriptElement()..text = boundsJs.toString());
  }

  String _escapeJs(String text) {
    return text
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('"', '\\"')
        .replaceAll('\n', ' ')
        .replaceAll('\r', ' ');
  }

  void setCenter(double lat, double lng) {
    final jsCode = '''
      (function() {
        if (typeof kakao === 'undefined') return;
        var map = window['kakaoMapInstance_$_containerId'];
        if (map) {
          var moveLatLon = new kakao.maps.LatLng($lat, $lng);
          map.setCenter(moveLatLon);
          console.log('Center set to: $lat, $lng');
        }
      })();
    ''';
    html.document.body?.append(html.ScriptElement()..text = jsCode);
  }

  void setLevel(int level) {
    final jsCode = '''
      (function() {
        if (typeof kakao === 'undefined') return;
        var map = window['kakaoMapInstance_$_containerId'];
        if (map) {
          map.setLevel($level);
          console.log('Level set to: $level');
        }
      })();
    ''';
    html.document.body?.append(html.ScriptElement()..text = jsCode);
  }

  @override
  Widget build(BuildContext context) {
    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _errorMessage = null;
                  });
                  _checkKakaoSdkLoaded();
                },
                child: const Text('다시 시도'),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isKakaoLoaded) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('카카오맵 로딩 중...'),
          ],
        ),
      );
    }

    return HtmlElementView(viewType: _viewId);
  }
}
