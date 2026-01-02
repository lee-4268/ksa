import 'dart:async';
import 'package:flutter/material.dart';
import 'package:kakao_maps_flutter/kakao_maps_flutter.dart';
import '../models/radio_station.dart';

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
  State<PlatformMapWidget> createState() => _PlatformMapWidgetState();
}

class _PlatformMapWidgetState extends State<PlatformMapWidget> {
  KakaoMapController? _mapController;
  StreamSubscription? _labelClickSubscription;

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
    _labelClickSubscription = _mapController?.onLabelClickedStream.listen((event) {
      if (widget.onMarkerTap != null) {
        final station = widget.stations.firstWhere(
          (s) => s.id == event.labelId,
          orElse: () => widget.stations.first,
        );
        widget.onMarkerTap!(station);
      }
    });
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

  /// MarkerOption 생성 헬퍼
  MarkerOption _createMarkerOption(RadioStation station) {
    return MarkerOption(
      id: station.id,
      latLng: LatLng(
        latitude: station.latitude!,
        longitude: station.longitude!,
      ),
      text: station.displayName,
    );
  }

  /// 초기 마커 로딩 (첫 로드 시에만 사용)
  Future<void> _initializeMarkers(List<RadioStation> stations) async {
    if (_mapController == null) return;

    _stateCache.clear();
    _registeredMarkerIds.clear();

    final markerOptions = <MarkerOption>[];

    for (final station in stations) {
      if (!station.hasCoordinates) continue;

      markerOptions.add(_createMarkerOption(station));
      _stateCache[station.id] = station.isInspected;
      _registeredMarkerIds.add(station.id);
    }

    // 마커 일괄 추가
    if (markerOptions.isNotEmpty) {
      await _mapController?.addMarkers(markerOptions: markerOptions);
    }

    setState(() {
      _initialLoadComplete = true;
    });

    // 카메라 이동
    _moveCameraToStations(stations);
  }

  /// 스테이션 목록에 맞게 카메라 이동
  Future<void> _moveCameraToStations(List<RadioStation> stations) async {
    final stationsWithCoords = stations.where((s) => s.hasCoordinates).toList();
    if (stationsWithCoords.isEmpty || _mapController == null) return;

    if (stationsWithCoords.length == 1) {
      // 단일 마커면 해당 위치로 이동
      final station = stationsWithCoords.first;
      await _mapController?.moveCamera(
        cameraUpdate: CameraUpdate(
          position: LatLng(latitude: station.latitude!, longitude: station.longitude!),
          zoomLevel: 5,
        ),
      );
    } else {
      // 여러 마커면 전체가 보이도록 중심점 계산
      double sumLat = 0, sumLng = 0;
      for (final s in stationsWithCoords) {
        sumLat += s.latitude!;
        sumLng += s.longitude!;
      }
      final centerLat = sumLat / stationsWithCoords.length;
      final centerLng = sumLng / stationsWithCoords.length;

      await _mapController?.moveCamera(
        cameraUpdate: CameraUpdate(
          position: LatLng(latitude: centerLat, longitude: centerLng),
          zoomLevel: 10,
        ),
      );
    }
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
          _initializeMarkers(widget.stations);
        },
        initialPosition: const LatLng(
          latitude: 36.5,
          longitude: 127.5,
        ),
        initialLevel: 13,
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
