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
  /// 맵 초기 위치 (null이면 서울역 좌표 사용)
  final RadioStation? initialStation;
  /// 맵 초기 줌 레벨 (null이면 기본값 사용)
  final int? initialZoomLevel;

  const PlatformMapWidget({
    super.key,
    required this.stations,
    this.onMarkerTap,
    this.initialStation,
    this.initialZoomLevel,
  });

  @override
  State<PlatformMapWidget> createState() => PlatformMapWidgetState();
}

class PlatformMapWidgetState extends State<PlatformMapWidget> {
  late String _viewId;
  late String _containerId;
  bool _isMapReady = false;
  bool _isKakaoLoaded = false;
  Timer? _kakaoCheckTimer;
  String? _errorMessage;
  StreamSubscription? _messageSubscription; // 메시지 리스너 구독

  /// 마커 상태 캐시: stationId -> isInspected (증분 업데이트용)
  final Map<String, bool> _markerStateCache = {};

  /// 마커가 맵에 존재하는지 추적
  final Set<String> _existingMarkerIds = {};

  /// 맵 드래그 활성화 상태 (외부에서 제어 가능)
  bool _mapDraggable = true;

  /// 맵 드래그 비활성화 (리스트 오버레이 드래그 시 호출)
  void setMapDraggable(bool draggable) {
    if (_mapDraggable == draggable) return;
    _mapDraggable = draggable;
    _updateMapDraggable(draggable);
  }

  void _updateMapDraggable(bool draggable) {
    if (!_isMapReady) return;
    final jsCode = '''
      (function() {
        var map = window['kakaoMapInstance_$_containerId'];
        if (map) {
          map.setDraggable($draggable);
          map.setZoomable($draggable);
          console.log('Map draggable set to: $draggable');
        }
      })();
    ''';
    html.document.body?.append(html.ScriptElement()..text = jsCode);
  }

  /// GPS 현재 위치 가져오기 및 맵 중앙 이동
  void moveToCurrentLocation({Function(double lat, double lng)? onSuccess, Function(String error)? onError}) {
    final jsCode = '''
      (function() {
        if (!navigator.geolocation) {
          window.postMessage({type: 'geolocationError', error: 'GPS가 지원되지 않습니다.'}, '*');
          return;
        }

        navigator.geolocation.getCurrentPosition(
          function(position) {
            var lat = position.coords.latitude;
            var lng = position.coords.longitude;

            var map = window['kakaoMapInstance_$_containerId'];
            if (map) {
              var moveLatLon = new kakao.maps.LatLng(lat, lng);
              map.setCenter(moveLatLon);
              map.setLevel(3);
              console.log('Moved to current location: ' + lat + ', ' + lng);
            }

            // 현재 위치 마커 업데이트
            window.postMessage({type: 'currentLocation', lat: lat, lng: lng}, '*');
          },
          function(error) {
            var errorMsg = '';
            switch(error.code) {
              case error.PERMISSION_DENIED:
                errorMsg = '위치 권한이 거부되었습니다.';
                break;
              case error.POSITION_UNAVAILABLE:
                errorMsg = '위치 정보를 사용할 수 없습니다.';
                break;
              case error.TIMEOUT:
                errorMsg = '위치 요청 시간이 초과되었습니다.';
                break;
              default:
                errorMsg = '알 수 없는 오류가 발생했습니다.';
            }
            window.postMessage({type: 'geolocationError', error: errorMsg}, '*');
          },
          {enableHighAccuracy: true, timeout: 10000, maximumAge: 0}
        );
      })();
    ''';
    html.document.body?.append(html.ScriptElement()..text = jsCode);
  }

  /// 현재 위치 마커 표시/업데이트
  void _showCurrentLocationMarker(double lat, double lng) {
    final jsCode = '''
      (function() {
        if (typeof kakao === 'undefined') return;
        var map = window['kakaoMapInstance_$_containerId'];
        if (!map) return;

        // 기존 현재 위치 마커 제거
        var existingMarker = window['kakaoCurrentLocationMarker_$_containerId'];
        var existingCircle = window['kakaoCurrentLocationCircle_$_containerId'];
        if (existingMarker) {
          existingMarker.setMap(null);
        }
        if (existingCircle) {
          existingCircle.setMap(null);
        }

        var position = new kakao.maps.LatLng($lat, $lng);

        // 현재 위치 원 (정확도 표시)
        var circle = new kakao.maps.Circle({
          center: position,
          radius: 30,
          strokeWeight: 1,
          strokeColor: '#4285F4',
          strokeOpacity: 0.8,
          strokeStyle: 'solid',
          fillColor: '#4285F4',
          fillOpacity: 0.15
        });
        circle.setMap(map);
        window['kakaoCurrentLocationCircle_$_containerId'] = circle;

        // 현재 위치 마커 (파란 점)
        var markerContent = '<div style="' +
          'width: 20px;' +
          'height: 20px;' +
          'background: #4285F4;' +
          'border: 3px solid white;' +
          'border-radius: 50%;' +
          'box-shadow: 0 2px 6px rgba(0,0,0,0.3);' +
          '"></div>';

        var customOverlay = new kakao.maps.CustomOverlay({
          position: position,
          content: markerContent,
          yAnchor: 0.5,
          xAnchor: 0.5,
          zIndex: 10
        });
        customOverlay.setMap(map);
        window['kakaoCurrentLocationMarker_$_containerId'] = customOverlay;

        console.log('Current location marker shown at: $lat, $lng');
      })();
    ''';
    html.document.body?.append(html.ScriptElement()..text = jsCode);
  }

  /// 특정 스테이션 위치로 카메라 이동 (외부에서 호출 가능)
  void moveToStation(RadioStation station) {
    if (!station.hasCoordinates || !_isMapReady) return;
    setCenter(station.latitude!, station.longitude!);
    setLevel(3);
  }

  /// 특정 스테이션 위치로 카메라 이동 (줌 레벨 지정 가능)
  void moveToStationWithLevel(RadioStation station, int zoomLevel) {
    if (!station.hasCoordinates || !_isMapReady) return;
    setCenter(station.latitude!, station.longitude!);
    // 카카오맵 웹 레벨: 1=가장 확대, 14=가장 축소
    // Flutter에서 12는 구/시 단위이므로 웹에서는 약 6-7 정도
    final webLevel = (14 - zoomLevel).clamp(1, 14);
    setLevel(webLevel);
  }

  /// 여러 스테이션을 한눈에 볼 수 있도록 지도 범위 조정
  void fitToStations(List<RadioStation> stations) {
    if (!_isMapReady || stations.isEmpty) return;

    final validStations = stations.where((s) => s.hasCoordinates).toList();
    if (validStations.isEmpty) return;

    if (validStations.length == 1) {
      moveToStation(validStations.first);
      return;
    }

    _fitBounds(validStations);
  }

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
    _messageSubscription?.cancel(); // 메시지 리스너 구독 취소
    super.dispose();
  }

  void _checkKakaoSdkLoaded() {
    int checkCount = 0;
    const maxChecks = 150; // 30초로 늘림 (150 * 200ms)

    // 먼저 kakao.maps.load() 호출 시도 (autoload=false 모드)
    _tryLoadKakaoMaps();

    _kakaoCheckTimer = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      checkCount++;

      // window.kakaoMapsLoaded 플래그 또는 직접 체크
      if (_checkKakaoMapsLoaded() || _checkKakaoGlobal()) {
        timer.cancel();
        debugPrint('카카오맵 SDK 로드 완료 (체크 횟수: $checkCount)');
        setState(() {
          _isKakaoLoaded = true;
        });
        _registerView();
      } else if (checkCount >= maxChecks) {
        timer.cancel();
        debugPrint('카카오맵 SDK 로드 시간 초과 (30초)');
        setState(() {
          _errorMessage = '카카오맵 SDK를 로드할 수 없습니다.\n네트워크 연결을 확인하거나 페이지를 새로고침해주세요.\n\n카카오 개발자 콘솔에서 현재 도메인이 등록되어 있는지 확인하세요.';
        });
      }
    });
  }

  /// window.kakaoMapsLoaded 플래그 확인
  bool _checkKakaoMapsLoaded() {
    try {
      final loaded = js.context['kakaoMapsLoaded'];
      return loaded == true;
    } catch (e) {
      return false;
    }
  }

  /// autoload=false 모드에서 kakao.maps.load() 호출
  void _tryLoadKakaoMaps() {
    final loadScript = '''
      (function() {
        if (typeof kakao !== 'undefined' && kakao.maps && typeof kakao.maps.load === 'function') {
          kakao.maps.load(function() {
            console.log('카카오맵 SDK 수동 로드 완료');
            window.kakaoMapsLoaded = true;
          });
        }
      })();
    ''';
    html.document.body?.append(html.ScriptElement()..text = loadScript);
  }

  bool _checkKakaoGlobal() {
    try {
      final kakao = js.context['kakao'];
      if (kakao == null) return false;
      final maps = kakao['maps'];
      if (maps == null) return false;
      // LatLng 클래스가 있는지 확인 (load 완료 여부)
      final latLng = maps['LatLng'];
      return latLng != null;
    } catch (e) {
      debugPrint('카카오 SDK 체크 오류: $e');
      return false;
    }
  }

  /// 위치 오류 콜백 (외부에서 설정 가능)
  Function(String error)? onGeolocationError;

  void _setupMessageListener() {
    // 기존 구독이 있으면 취소하고 새로 등록
    _messageSubscription?.cancel();
    _messageSubscription = html.window.onMessage.listen((event) {
      if (event.data is Map) {
        final data = event.data as Map;
        if (data['type'] == 'markerClick') {
          final lat = data['lat'] as num?;
          final lng = data['lng'] as num?;

          if (lat != null && lng != null && widget.onMarkerTap != null) {
            // 같은 좌표에 있는 모든 스테이션 찾기 (ID 기준 중복 제거)
            final seenIds = <String>{};
            final stationsAtLocation = widget.stations.where((s) {
              if (!s.hasCoordinates) return false;
              if (s.latitude != lat.toDouble()) return false;
              if (s.longitude != lng.toDouble()) return false;
              // ID 중복 체크
              if (seenIds.contains(s.id)) return false;
              seenIds.add(s.id);
              return true;
            }).toList();

            if (stationsAtLocation.length > 1) {
              // 여러 개면 선택 다이얼로그 표시
              _showStationSelectionDialog(stationsAtLocation);
            } else if (stationsAtLocation.length == 1) {
              // 1개면 바로 콜백 호출
              widget.onMarkerTap!(stationsAtLocation.first);
            }
          }
        } else if (data['type'] == 'currentLocation') {
          // 현재 위치 수신 - 마커 표시
          final lat = data['lat'] as num?;
          final lng = data['lng'] as num?;
          if (lat != null && lng != null) {
            _showCurrentLocationMarker(lat.toDouble(), lng.toDouble());
          }
        } else if (data['type'] == 'geolocationError') {
          // 위치 오류 처리
          final error = data['error'] as String?;
          if (error != null && onGeolocationError != null) {
            onGeolocationError!(error);
          }
        }
      }
    });
  }

  /// 겹친 마커 선택 다이얼로그
  void _showStationSelectionDialog(List<RadioStation> stations) {
    // 다이얼로그가 열리면 지도 상호작용 비활성화
    setMapDraggable(false);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
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
    ).whenComplete(() {
      // 다이얼로그가 닫히면 지도 상호작용 활성화
      setMapDraggable(true);
    });
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

        // 서울역 좌표로 초기화 (빠른 로딩 - 확대된 상태)
        var options = {
          center: new kakao.maps.LatLng(37.5546, 126.9706),
          level: 3
        };

        var map = new kakao.maps.Map(container, options);
        window['kakaoMapInstance_$_containerId'] = map;

        var infowindow = new kakao.maps.InfoWindow({zIndex: 1});
        window['kakaoInfoWindow_$_containerId'] = infowindow;

        window['kakaoMapMarkers_$_containerId'] = [];

        // 맵 클릭 시 InfoWindow만 닫음 (지도 상호작용은 Flutter에서 관리)
        kakao.maps.event.addListener(map, 'click', function() {
          infowindow.close();
          window.postMessage({type: 'infoWindowClosed'}, '*');
          console.log('InfoWindow closed');
        });

        console.log('Kakao Map initialized: $_containerId');
      })();
    ''';

    final scriptElement = html.ScriptElement()..text = jsCode;
    html.document.body?.append(scriptElement);

    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        // 초기 마커 로딩
        _initializeMarkers();
        setState(() {
          _isMapReady = true;
        });
      }
    });
  }

  @override
  void didUpdateWidget(PlatformMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // stations 리스트가 변경되었을 때만 증분 마커 업데이트
    // 리스트 내용이 실제로 변경되었는지 확인 (맵 이동 시 불필요한 업데이트 방지)
    if (_isMapReady) {
      final oldIds = oldWidget.stations.map((s) => s.id).toSet();
      final newIds = widget.stations.map((s) => s.id).toSet();
      final statesChanged = widget.stations.any((s) {
        final cached = _markerStateCache[s.id];
        return cached != null && cached != s.isInspected;
      });

      // ID 집합이 다르거나 상태가 변경된 경우에만 업데이트
      if (!_setsEqual(oldIds, newIds) || statesChanged) {
        debugPrint('마커 업데이트 필요: oldIds=${oldIds.length}, newIds=${newIds.length}, statesChanged=$statesChanged');
        _updateMarkersIncrementally();
      }
    }
  }

  /// 두 Set이 동일한지 비교
  bool _setsEqual<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  /// 초기 마커 로딩 (첫 로드 시에만 사용)
  void _initializeMarkers() {
    if (!_isKakaoLoaded) return;

    _markerStateCache.clear();
    _existingMarkerIds.clear();

    for (final station in widget.stations) {
      if (!station.hasCoordinates) continue;
      _addSingleMarker(station);
      _markerStateCache[station.id] = station.isInspected;
      _existingMarkerIds.add(station.id);
    }

    // initialStation이 지정된 경우 해당 위치로 이동 (검색 드롭다운에서 선택한 경우)
    if (widget.initialStation != null && widget.initialStation!.hasCoordinates) {
      debugPrint('initialStation으로 이동: ${widget.initialStation!.stationName}');
      setCenter(widget.initialStation!.latitude!, widget.initialStation!.longitude!);
      // initialZoomLevel이 지정된 경우 해당 레벨로, 아니면 기본값 3
      final zoomLevel = widget.initialZoomLevel ?? 15;
      // 카카오맵 웹 레벨: 1=가장 확대, 14=가장 축소
      final webLevel = (14 - zoomLevel).clamp(1, 14);
      setLevel(webLevel);
    } else {
      _adjustMapBounds();
    }
  }

  /// 증분 마커 업데이트 - 변경된 마커만 처리
  void _updateMarkersIncrementally() {
    if (!_isKakaoLoaded) return;

    final currentStationIds = <String>{};
    bool hasChanges = false;

    for (final station in widget.stations) {
      if (!station.hasCoordinates) continue;

      currentStationIds.add(station.id);
      final cachedState = _markerStateCache[station.id];
      final currentState = station.isInspected;

      if (cachedState == null) {
        // 새로운 마커 추가
        _addSingleMarker(station);
        _markerStateCache[station.id] = currentState;
        _existingMarkerIds.add(station.id);
        hasChanges = true;
        debugPrint('마커 추가: ${station.displayName}');
      } else if (cachedState != currentState) {
        // 상태가 변경된 마커만 업데이트 (삭제 후 재추가)
        _removeSingleMarker(station.id);
        _addSingleMarker(station);
        _markerStateCache[station.id] = currentState;
        hasChanges = true;
        debugPrint('마커 업데이트: ${station.displayName} (${cachedState ? "완료→대기" : "대기→완료"})');
      }
    }

    // 삭제된 마커 처리
    final removedIds = _existingMarkerIds.difference(currentStationIds);
    for (final removedId in removedIds) {
      _removeSingleMarker(removedId);
      _markerStateCache.remove(removedId);
      _existingMarkerIds.remove(removedId);
      hasChanges = true;
      debugPrint('마커 삭제: $removedId');
    }

    if (hasChanges) {
      debugPrint('증분 업데이트 완료');
    }
  }

  /// 단일 마커 제거 (라벨 포함)
  void _removeSingleMarker(String stationId) {
    final escapedId = _escapeJs(stationId);
    final removeJs = '''
      (function() {
        if (typeof kakao === 'undefined') return;
        var markersMap = window['kakaoMapMarkersMap_$_containerId'] || {};
        var labelsMap = window['kakaoMapLabelsMap_$_containerId'] || {};

        // 마커 제거
        var marker = markersMap['$escapedId'];
        if (marker) {
          marker.setMap(null);
          delete markersMap['$escapedId'];
        }

        // 라벨 제거
        var label = labelsMap['$escapedId'];
        if (label) {
          label.setMap(null);
          delete labelsMap['$escapedId'];
        }

        console.log('Marker and label removed: $escapedId');
      })();
    ''';
    html.document.body?.append(html.ScriptElement()..text = removeJs);
  }

  /// 단일 마커 추가 (라벨 포함)
  void _addSingleMarker(RadioStation station) {
    final escapedName = _escapeJs(station.displayName);
    final escapedAddress = _escapeJs(station.address);
    final escapedId = _escapeJs(station.id);
    final isInspected = station.isInspected;
    final markerImagePath = isInspected ? _inspectedMarkerPath : _pendingMarkerPath;
    final labelColor = isInspected ? '#FF0000' : '#0066CC';

    final addMarkerJs = '''
      (function() {
        if (typeof kakao === 'undefined') return;
        var map = window['kakaoMapInstance_$_containerId'];
        var infowindow = window['kakaoInfoWindow_$_containerId'];
        if (!map) return;

        // 마커 맵 초기화
        if (!window['kakaoMapMarkersMap_$_containerId']) {
          window['kakaoMapMarkersMap_$_containerId'] = {};
        }
        var markersMap = window['kakaoMapMarkersMap_$_containerId'];

        // 라벨 오버레이 맵 초기화
        if (!window['kakaoMapLabelsMap_$_containerId']) {
          window['kakaoMapLabelsMap_$_containerId'] = {};
        }
        var labelsMap = window['kakaoMapLabelsMap_$_containerId'];

        var position = new kakao.maps.LatLng(${station.latitude}, ${station.longitude});

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

        // 마커 아래에 라벨 추가 (CustomOverlay 사용)
        var labelContent = '<div style="' +
          'padding: 3px 8px;' +
          'background: white;' +
          'border: 1px solid $labelColor;' +
          'border-radius: 4px;' +
          'font-size: 11px;' +
          'font-weight: bold;' +
          'color: $labelColor;' +
          'white-space: nowrap;' +
          'box-shadow: 0 1px 3px rgba(0,0,0,0.2);' +
          'text-align: center;' +
          'max-width: 120px;' +
          'overflow: hidden;' +
          'text-overflow: ellipsis;' +
          '">' + '$escapedName' + '</div>';

        var labelOverlay = new kakao.maps.CustomOverlay({
          position: position,
          content: labelContent,
          yAnchor: -0.3,
          zIndex: 1
        });
        labelOverlay.setMap(map);

        // 마커 맵에 저장
        markersMap['$escapedId'] = marker;
        labelsMap['$escapedId'] = labelOverlay;

        // 마커 배열에도 추가 (bounds 계산용)
        if (!window['kakaoMapMarkers_$_containerId']) {
          window['kakaoMapMarkers_$_containerId'] = [];
        }
        window['kakaoMapMarkers_$_containerId'].push(marker);

        var isInspectedFlag = ${isInspected ? 'true' : 'false'};
        var iwContent = '<div style="padding:12px 16px;width:250px;font-size:13px;box-sizing:border-box;">' +
          '<div style="color:#333;font-weight:bold;margin-bottom:8px;word-break:keep-all;line-height:1.4;">$escapedName</div>' +
          '<div style="color:#666;font-size:12px;line-height:1.5;word-wrap:break-word;white-space:pre-wrap;">$escapedAddress</div>' +
          (isInspectedFlag ? '<div style="color:#FF0000;font-size:11px;font-weight:bold;margin-top:8px;">✓ 검사완료</div>' : '') +
          '</div>';

        kakao.maps.event.addListener(marker, 'click', function() {
          infowindow.setContent(iwContent);
          infowindow.open(map, marker);

          // 상세정보 창이 열리면 지도 드래그/줌 비활성화
          map.setDraggable(false);
          map.setZoomable(false);
          console.log('InfoWindow opened, map interaction disabled');

          window.postMessage({
            type: 'markerClick',
            stationId: '$escapedId',
            lat: ${station.latitude},
            lng: ${station.longitude}
          }, '*');
        });

        console.log('Marker added with label: $escapedName (inspected: $isInspected)');
      })();
    ''';
    html.document.body?.append(html.ScriptElement()..text = addMarkerJs);
  }

  /// 맵 bounds 조정
  void _adjustMapBounds() {
    final stationsWithCoords = widget.stations.where((s) => s.hasCoordinates).toList();
    if (stationsWithCoords.isEmpty) return;

    if (stationsWithCoords.length > 1) {
      _fitBounds(stationsWithCoords);
    } else {
      final first = stationsWithCoords.first;
      setCenter(first.latitude!, first.longitude!);
      setLevel(3);
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
