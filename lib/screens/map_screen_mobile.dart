import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kakao_maps_flutter/kakao_maps_flutter.dart';
import '../models/radio_station.dart';
import '../main_init_mobile.dart' show isX86Emulator;

/// 모바일 플랫폼용 카카오맵 위젯 (Android/iOS)
/// kakao_maps_flutter 패키지 사용 - 네이티브 SDK 직접 연동으로 빠른 로딩
class PlatformMapWidget extends StatefulWidget {
  final List<RadioStation> stations;
  final Function(RadioStation)? onMarkerTap;

  const PlatformMapWidget({
    super.key,
    required this.stations,
    this.onMarkerTap,
  });

  @override
  State<PlatformMapWidget> createState() => PlatformMapWidgetState();
}

class PlatformMapWidgetState extends State<PlatformMapWidget>
    with AutomaticKeepAliveClientMixin<PlatformMapWidget> {
  KakaoMapController? _mapController;
  StreamSubscription? _labelClickSubscription;

  /// AutomaticKeepAliveClientMixin: 위젯 상태를 유지하여 지도 재생성 방지
  @override
  bool get wantKeepAlive => true;

  /// 마커 캐시: stationId -> isInspected 상태
  final Map<String, bool> _stateCache = {};

  /// 현재 등록된 마커 ID Set
  final Set<String> _registeredMarkerIds = {};

  /// 초기 로딩 완료 여부
  bool _initialLoadComplete = false;

  /// 맵 로딩 상태
  bool _isMapLoading = true;

  /// 에러 메시지
  String? _errorMessage;

  /// 마커 스타일/레이어 초기화 완료 여부
  bool _markerSetupComplete = false;

  /// 마커 스타일 ID
  static const String _pendingStyleId = 'pending_marker_style';
  static const String _inspectedStyleId = 'inspected_marker_style';

  /// 마커 아이콘 PNG 바이트 (SVG에서 변환)
  Uint8List? _pendingIconBytes;
  Uint8List? _inspectedIconBytes;

  /// 특정 스테이션 위치로 카메라 이동 (외부에서 호출 가능)
  Future<void> moveToStation(RadioStation station) async {
    if (_mapController == null || !station.hasCoordinates) return;

    await _mapController?.moveCamera(
      cameraUpdate: CameraUpdate(
        position: LatLng(
          latitude: station.latitude!,
          longitude: station.longitude!,
        ),
        zoomLevel: 15, // 확대된 상태로 이동 (3은 대한민국 전체, 15는 상세)
      ),
    );
  }

  /// 특정 스테이션 위치로 카메라 이동 (줌 레벨 지정 가능)
  Future<void> moveToStationWithLevel(RadioStation station, int zoomLevel) async {
    if (_mapController == null || !station.hasCoordinates) return;

    await _mapController?.moveCamera(
      cameraUpdate: CameraUpdate(
        position: LatLng(
          latitude: station.latitude!,
          longitude: station.longitude!,
        ),
        zoomLevel: zoomLevel, // 지정된 줌 레벨로 이동 (12: 구/시 단위)
      ),
    );
  }

  /// 여러 스테이션을 한눈에 볼 수 있도록 지도 범위 조정
  Future<void> fitToStations(List<RadioStation> stations) async {
    if (_mapController == null || stations.isEmpty) return;

    // 좌표가 있는 스테이션만 필터링
    final validStations = stations.where((s) => s.hasCoordinates).toList();
    if (validStations.isEmpty) return;

    // 마커 1개일 경우 해당 위치로 이동
    if (validStations.length == 1) {
      await moveToStation(validStations.first);
      return;
    }

    // fitPoints를 위한 좌표 리스트 생성
    final points = validStations
        .map((s) => LatLng(latitude: s.latitude!, longitude: s.longitude!))
        .toList();

    // CameraUpdate의 fitPoints 사용하여 모든 마커가 보이도록 조정
    await _mapController?.moveCamera(
      cameraUpdate: CameraUpdate(
        fitPoints: points,
        padding: 80, // 여백 추가
      ),
    );
  }

  /// 마커 아이콘 로드 (PNG 파일에서 직접 로드)
  /// image/검사대기.png, image/검사완료.png 파일 필요
  Future<void> _loadMarkerIcons() async {
    if (_pendingIconBytes != null && _inspectedIconBytes != null) return;

    try {
      // PNG 파일 로드 (assets에서)
      final pendingData = await rootBundle.load('image/검사대기.png');
      final inspectedData = await rootBundle.load('image/검사완료.png');

      _pendingIconBytes = pendingData.buffer.asUint8List();
      _inspectedIconBytes = inspectedData.buffer.asUint8List();
      debugPrint('마커 아이콘 로드 완료');
    } catch (e) {
      debugPrint('마커 아이콘 로드 오류: $e');
    }
  }

  @override
  void dispose() {
    _labelClickSubscription?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(PlatformMapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    // stations 리스트가 변경되었을 때만 증분 업데이트
    if (_initialLoadComplete && _mapController != null) {
      _updateMarkersIncrementally(widget.stations);
    }
  }

  /// 마커 클릭 이벤트 리스너 설정
  void _setupMarkerClickListener() {
    _labelClickSubscription = _mapController?.onLabelClickedStream.listen((event) async {
      if (widget.onMarkerTap == null) return;

      // 클릭된 마커의 스테이션 찾기
      final clickedStation = widget.stations.firstWhere(
        (s) => s.id == event.labelId,
        orElse: () => widget.stations.first,
      );

      // 같은 좌표에 있는 다른 마커들 찾기 (반경 0.0001도 = 약 11m 이내)
      const double threshold = 0.0001;
      final overlappingStations = widget.stations.where((s) {
        if (!s.hasCoordinates || !clickedStation.hasCoordinates) return false;
        final latDiff = (s.latitude! - clickedStation.latitude!).abs();
        final lngDiff = (s.longitude! - clickedStation.longitude!).abs();
        return latDiff < threshold && lngDiff < threshold;
      }).toList();

      // 겹친 마커가 2개 이상이면 선택 다이얼로그 표시
      if (overlappingStations.length > 1) {
        _showOverlappingMarkersDialog(overlappingStations);
      } else {
        widget.onMarkerTap!(clickedStation);
      }
    });
  }

  /// 겹친 마커 선택 다이얼로그 표시
  void _showOverlappingMarkersDialog(List<RadioStation> stations) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 헤더
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.layers, color: Colors.blue),
                    const SizedBox(width: 8),
                    Text(
                      '겹친 마커 ${stations.length}개',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              // 마커 리스트
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.4,
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: stations.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final station = stations[index];
                    return ListTile(
                      leading: Icon(
                        Icons.location_on,
                        color: station.isInspected ? Colors.red : Colors.blue,
                      ),
                      title: Text(
                        station.displayName,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Text(
                        station.isInspected ? '검사완료' : '검사대기',
                        style: TextStyle(
                          color: station.isInspected ? Colors.red : Colors.blue,
                          fontSize: 12,
                        ),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () {
                        Navigator.pop(context);
                        widget.onMarkerTap!(station);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 마커 스타일 및 레이어 초기화 (필수)
  Future<void> _setupMarkerStyleAndLayer() async {
    if (_mapController == null || _markerSetupComplete) return;

    try {
      // 0. 마커 아이콘 로드 (SVG -> PNG 변환)
      await _loadMarkerIcons();

      if (_pendingIconBytes == null || _inspectedIconBytes == null) {
        debugPrint('마커 아이콘 로드 실패');
        return;
      }

      // 1. 마커 스타일 등록 (검사대기, 검사완료 두 가지)
      // 웹 버전과 동일한 디자인: 검사대기=파란색(0xFF0066CC), 검사완료=빨간색(0xFFFF0000)
      final markerStyles = [
        MarkerStyle(
          styleId: _pendingStyleId,
          perLevels: [
            MarkerPerLevelStyle.fromBytes(
              bytes: _pendingIconBytes!,
              textStyle: const MarkerTextStyle(
                fontSize: 24,                    // 웹버전 11px보다 크게 (모바일 가독성)
                fontColorArgb: 0xFF0066CC,       // 파란색 (웹버전과 동일)
                strokeThickness: 2,              // 외곽선 두께
                strokeColorArgb: 0xFFFFFFFF,     // 흰색 외곽선
              ),
              level: 0,
            ),
          ],
        ),
        MarkerStyle(
          styleId: _inspectedStyleId,
          perLevels: [
            MarkerPerLevelStyle.fromBytes(
              bytes: _inspectedIconBytes!,
              textStyle: const MarkerTextStyle(
                fontSize: 24,                    // 웹버전 11px보다 크게 (모바일 가독성)
                fontColorArgb: 0xFFFF0000,       // 빨간색 (웹버전과 동일)
                strokeThickness: 2,              // 외곽선 두께
                strokeColorArgb: 0xFFFFFFFF,     // 흰색 외곽선
              ),
              level: 0,
            ),
          ],
        ),
      ];

      await _mapController!.registerMarkerStyles(styles: markerStyles);
      debugPrint('마커 스타일 등록 완료 (검사대기, 검사완료)');

      // 2. 마커 레이어 생성
      await _mapController!.addMarkerLayer(
        layerId: KakaoMapController.defaultLabelLayerId,
        zOrder: 1000,
        clickable: true,
      );
      debugPrint('마커 레이어 생성 완료');

      _markerSetupComplete = true;
    } catch (e) {
      debugPrint('마커 스타일/레이어 초기화 오류: $e');
    }
  }

  /// 증분 마커 업데이트 - 변경된 마커만 처리
  Future<void> _updateMarkersIncrementally(List<RadioStation> stations) async {
    if (_mapController == null) return;

    final currentStationIds = <String>{};
    final markersToAdd = <MarkerOption>[];
    final idsToRemove = <String>[];
    bool hasChanges = false;

    for (final station in stations) {
      if (!station.hasCoordinates) continue;

      currentStationIds.add(station.id);

      // 기존 상태와 비교
      final cachedState = _stateCache[station.id];
      final currentState = station.isInspected;

      if (cachedState == null) {
        // 새로운 마커 추가
        markersToAdd.add(_createMarkerOption(station));
        _stateCache[station.id] = currentState;
        _registeredMarkerIds.add(station.id);
        hasChanges = true;
        debugPrint('마커 추가: ${station.displayName}');
      } else if (cachedState != currentState) {
        // 상태가 변경된 마커 - 삭제 후 재추가
        idsToRemove.add(station.id);
        markersToAdd.add(_createMarkerOption(station));
        _stateCache[station.id] = currentState;
        hasChanges = true;
        debugPrint('마커 업데이트: ${station.displayName} (${cachedState ? "완료→대기" : "대기→완료"})');
      }
    }

    // 삭제된 마커 처리
    final removedIds = _registeredMarkerIds.difference(currentStationIds);
    for (final removedId in removedIds) {
      idsToRemove.add(removedId);
      _stateCache.remove(removedId);
      _registeredMarkerIds.remove(removedId);
      hasChanges = true;
      debugPrint('마커 삭제: $removedId');
    }

    // 변경사항 적용
    if (hasChanges) {
      // 삭제할 마커 제거
      if (idsToRemove.isNotEmpty) {
        await _mapController?.removeMarkers(ids: idsToRemove);
      }
      // 새 마커 추가
      if (markersToAdd.isNotEmpty) {
        await _mapController?.addMarkers(markerOptions: markersToAdd);
      }
      debugPrint('증분 업데이트 완료');
    }
  }

  /// MarkerOption 생성 헬퍼 (검사 상태에 따라 다른 스타일 적용)
  MarkerOption _createMarkerOption(RadioStation station) {
    return MarkerOption(
      id: station.id,
      latLng: LatLng(
        latitude: station.latitude!,
        longitude: station.longitude!,
      ),
      text: station.displayName,
      styleId: station.isInspected ? _inspectedStyleId : _pendingStyleId,
    );
  }


  @override
  Widget build(BuildContext context) {
    // AutomaticKeepAliveClientMixin 필수 호출
    super.build(context);

    // x86 에뮬레이터에서는 대체 UI 표시
    if (isX86Emulator) {
      return _buildEmulatorFallbackUI();
    }

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
                    _isMapLoading = true;
                  });
                },
                child: const Text('다시 시도'),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      children: [
        _buildMap(),
        // 로딩 인디케이터
        if (_isMapLoading)
          Container(
            color: Colors.white,
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('카카오맵 로딩 중...'),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// x86 에뮬레이터용 대체 UI
  Widget _buildEmulatorFallbackUI() {
    return Container(
      color: Colors.grey[200],
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.map_outlined, size: 64, color: Colors.grey[400]),
              const SizedBox(height: 16),
              const Text(
                '카카오맵 미지원 환경',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'x86 에뮬레이터에서는 카카오맵을\n사용할 수 없습니다.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue[200]!),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lightbulb_outline, size: 20, color: Colors.blue[700]),
                    const SizedBox(height: 4),
                    Text(
                      '실제 기기 또는 웹에서 테스트하세요',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue[700],
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.stations.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '${widget.stations.length}개 스테이션 로드됨',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey[500],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 지도 준비 완료까지 대기 후 마커 초기화
  Future<void> _waitForMapReadyAndInitialize() async {
    // 네이티브에서 onMapReady 콜백이 호출될 때까지 대기
    // kakao_maps_flutter SDK 내부에서 _isReady 플래그가 설정될 시간 필요
    const maxRetries = 20;
    const retryDelay = Duration(milliseconds: 200);

    for (int i = 0; i < maxRetries; i++) {
      await Future.delayed(retryDelay);

      if (!mounted || _mapController == null) return;

      try {
        // 마커 스타일/레이어 초기화 시도
        await _setupMarkerStyleAndLayer();

        if (_markerSetupComplete) {
          debugPrint('지도 준비 완료 (${(i + 1) * 200}ms 후)');
          // 마커 초기화
          await _loadMarkersAfterSetup();
          return;
        }
      } catch (e) {
        debugPrint('지도 준비 대기 중... (${i + 1}/$maxRetries): $e');
      }
    }

    debugPrint('지도 준비 시간 초과');
  }

  /// 마커 스타일/레이어 설정 완료 후 마커 로드
  Future<void> _loadMarkersAfterSetup() async {
    if (_mapController == null || !_markerSetupComplete) return;

    _stateCache.clear();
    _registeredMarkerIds.clear();

    final markerOptions = <MarkerOption>[];

    for (final station in widget.stations) {
      if (!station.hasCoordinates) continue;

      markerOptions.add(_createMarkerOption(station));
      _stateCache[station.id] = station.isInspected;
      _registeredMarkerIds.add(station.id);
    }

    // 마커 일괄 추가
    if (markerOptions.isNotEmpty) {
      try {
        await _mapController?.addMarkers(markerOptions: markerOptions);
        debugPrint('${markerOptions.length}개 마커 추가 완료');
      } catch (e) {
        debugPrint('마커 추가 오류: $e');
      }
    }

    if (mounted) {
      setState(() {
        _initialLoadComplete = true;
      });
    }
  }

  Widget _buildMap() {
    try {
      return KakaoMap(
        onMapCreated: (controller) {
          debugPrint('카카오맵 네이티브 SDK 로드 완료');
          _mapController = controller;
          _setupMarkerClickListener();
          if (mounted) {
            setState(() {
              _isMapLoading = false;
            });
          }
          // 지도가 완전히 준비될 때까지 대기 후 마커 초기화
          _waitForMapReadyAndInitialize();
        },
        // 서울역 좌표로 초기화 (구/시 수준으로 확대)
        // 카카오맵 레벨: 숫자가 높을수록 확대됨 (3=한반도 전체, 15=구/시 수준)
        initialPosition: const LatLng(
          latitude: 37.5546,
          longitude: 126.9706,
        ),
        initialLevel: 15,
      );
    } catch (e) {
      debugPrint('카카오맵 위젯 생성 오류: $e');
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.map_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text('지도를 로드할 수 없습니다.\n$e', textAlign: TextAlign.center),
          ],
        ),
      );
    }
  }
}
