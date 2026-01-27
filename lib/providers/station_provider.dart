import 'package:flutter/foundation.dart';
import '../models/radio_station.dart';
import '../services/excel_service.dart';
import '../services/geocoding_service.dart';
import '../services/storage_service.dart';
import '../services/cloud_data_service.dart';

class StationProvider extends ChangeNotifier {
  final StorageService _storageService;
  final ExcelService _excelService = ExcelService();
  final GeocodingService _geocodingService = GeocodingService();
  CloudDataService? _cloudDataService;

  List<RadioStation> _stations = [];
  bool _isLoading = false;
  String? _errorMessage;
  RadioStation? _selectedStation;
  String _searchQuery = '';
  Set<String> _selectedCategories = {};

  /// 데이터 로드 완료 여부 (중복 로드 방지)
  bool _isDataLoaded = false;

  // 진행률 관련 상태
  double _loadingProgress = 0.0; // 0.0 ~ 1.0
  String _loadingStatus = ''; // 현재 작업 상태 메시지
  int _totalItems = 0;
  int _processedItems = 0;

  // 클라우드 ID 매핑 (로컬 ID -> 클라우드 ID)
  final Map<String, String> _cloudIdMap = {};
  // 카테고리 클라우드 ID 매핑 (카테고리명 -> 클라우드 카테고리 ID)
  final Map<String, String> _cloudCategoryIdMap = {};
  // 카테고리별 원본 Excel S3 키 매핑 (카테고리명 -> originalExcelKey)
  final Map<String, String> _categoryOriginalExcelKeyMap = {};
  // 카테고리별 원본 Excel 바이트 캐시 (클라우드 연결 없이도 서식 유지 export용)
  final Map<String, Uint8List> _originalExcelBytesCache = {};

  StationProvider(this._storageService);

  List<RadioStation> get stations => _stations;
  List<RadioStation> get stationsWithCoordinates =>
      _filteredStations.where((s) => s.hasCoordinates).toList();
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  double get loadingProgress => _loadingProgress;
  String get loadingStatus => _loadingStatus;
  int get totalItems => _totalItems;
  int get processedItems => _processedItems;
  RadioStation? get selectedStation => _selectedStation;
  String get searchQuery => _searchQuery;
  Set<String> get selectedCategories => _selectedCategories;

  // 모든 카테고리 목록 (파일명 기준)
  List<String> get categories {
    final cats = _stations
        .map((s) => s.categoryName ?? '기타')
        .toSet()
        .toList();
    cats.sort();
    return cats;
  }

  // 카테고리별 스테이션 맵 (createdAt 순으로 정렬하여 원본 Excel 순서 유지)
  Map<String, List<RadioStation>> get stationsByCategory {
    final map = <String, List<RadioStation>>{};
    for (final station in _stations) {
      final category = station.categoryName ?? '기타';
      map.putIfAbsent(category, () => []);
      map[category]!.add(station);
    }
    // 각 카테고리의 스테이션을 createdAt 순으로 정렬 (원본 Excel 순서 유지)
    for (final category in map.keys) {
      map[category]!.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    }
    return map;
  }

  // 필터링된 스테이션 목록
  List<RadioStation> get _filteredStations {
    return _stations.where((station) {
      // 카테고리 필터
      if (_selectedCategories.isNotEmpty) {
        final category = station.categoryName ?? '기타';
        if (!_selectedCategories.contains(category)) {
          return false;
        }
      }

      // 검색 필터
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        return station.stationName.toLowerCase().contains(query) ||
            station.address.toLowerCase().contains(query) ||
            (station.callSign?.toLowerCase().contains(query) ?? false) ||
            station.licenseNumber.toLowerCase().contains(query);
      }

      return true;
    }).toList();
  }

  List<RadioStation> get filteredStations => _filteredStations;

  /// 검색어 설정
  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  /// 카테고리 선택 토글
  void toggleCategory(String category) {
    if (_selectedCategories.contains(category)) {
      _selectedCategories.remove(category);
    } else {
      _selectedCategories.add(category);
    }
    notifyListeners();
  }

  /// 모든 카테고리 선택
  void selectAllCategories() {
    _selectedCategories = categories.toSet();
    notifyListeners();
  }

  /// 모든 카테고리 선택 해제
  void clearCategorySelection() {
    _selectedCategories.clear();
    notifyListeners();
  }

  /// 저장된 무선국 데이터 로드 (클라우드 우선)
  Future<void> loadStations({bool forceReload = false}) async {
    // 중복 로드 방지: 이미 로딩 중이거나 데이터가 로드된 경우 스킵
    if (_isLoading) {
      debugPrint('loadStations: 이미 로딩 중, 스킵');
      return;
    }
    if (_isDataLoaded && !forceReload) {
      debugPrint('loadStations: 이미 데이터 로드됨, 스킵 (현재 ${_stations.length}개)');
      return;
    }

    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      debugPrint('loadStations: CloudDataService 상태 = ${_cloudDataService != null ? "연결됨" : "null"}');

      // 클라우드에서 데이터 로드 시도
      if (_cloudDataService != null) {
        _loadingStatus = '클라우드에서 데이터 로드 중...';
        notifyListeners();

        debugPrint('loadStations: 클라우드 로드 시작...');
        final cloudSuccess = await _loadFromCloud();
        debugPrint('loadStations: 클라우드 로드 결과 = $cloudSuccess');

        if (cloudSuccess) {
          debugPrint('클라우드에서 데이터 로드 완료: ${_stations.length}개');
          _isDataLoaded = true;
          _isLoading = false;
          _loadingStatus = '';
          notifyListeners();
          return;
        }
      }

      // 클라우드 실패 시 처리
      if (_cloudDataService != null) {
        // 클라우드 서비스가 연결되어 있으면 오류 메시지 표시
        debugPrint('클라우드 로드 실패! 오류 발생');
        _errorMessage = '클라우드 연결 오류가 발생했습니다. 네트워크를 확인하세요.';
        _stations = [];
      } else {
        // 클라우드 서비스가 없으면 로컬에서 로드 (오프라인 모드)
        debugPrint('오프라인 모드: 로컬에서 데이터 로드 시도');
        _stations = _storageService.getAllStations();
        debugPrint('로컬에서 로드 완료: ${_stations.length}개');
      }
      _isDataLoaded = true;
    } catch (e) {
      _errorMessage = '데이터 로드 실패: $e';
      debugPrint(_errorMessage);
    } finally {
      _isLoading = false;
      _loadingStatus = '';
      notifyListeners();
    }
  }

  /// 클라우드에서 데이터 로드 (내부 함수) - 최적화됨
  Future<bool> _loadFromCloud() async {
    if (_cloudDataService == null) {
      debugPrint('_loadFromCloud: CloudDataService가 null');
      return false;
    }

    try {
      debugPrint('_loadFromCloud: 클라우드에서 카테고리 조회 시작...');

      // 1. 카테고리 목록 조회 (1회만 호출)
      final categories = await _cloudDataService!.listCategories();
      debugPrint('_loadFromCloud: 카테고리 ${categories.length}개 조회됨');

      if (categories.isEmpty) {
        debugPrint('클라우드에 카테고리 없음, 빈 상태로 시작');
        // 로컬 캐시도 비우고 빈 상태로 시작 (PC/모바일 간 데이터 불일치 방지)
        await _storageService.clearAllStations();
        _stations = [];
        return true;
      }

      // 2. 로컬 데이터 및 메모리 완전 초기화 (중복 방지)
      await _storageService.clearAllStations();
      _stations = []; // clear() 대신 새 리스트 할당으로 확실히 초기화
      _cloudIdMap.clear();
      _cloudCategoryIdMap.clear();
      _categoryOriginalExcelKeyMap.clear();

      // 3. 카테고리별 스테이션 로드 - 중복 방지를 위해 Set 사용
      final stationIdSet = <String>{}; // 이미 추가된 스테이션 ID 추적
      final allStationsToSave = <RadioStation>[];

      for (final cat in categories) {
        final catName = cat['name'] as String;
        final catId = cat['id'] as String;
        _cloudCategoryIdMap[catName] = catId;

        // 원본 Excel S3 키 저장 (있는 경우)
        final originalExcelKey = cat['originalExcelKey'] as String?;
        if (originalExcelKey != null && originalExcelKey.isNotEmpty) {
          _categoryOriginalExcelKeyMap[catName] = originalExcelKey;
          debugPrint('카테고리 "$catName" 원본 Excel 키: $originalExcelKey');
        }

        // 카테고리별 스테이션 조회
        final stations = await _cloudDataService!.listStationsByCategory(catId);

        for (final station in stations) {
          final cloudId = station.id;

          // 중복 체크: 이미 추가된 스테이션은 스킵
          if (stationIdSet.contains(cloudId)) {
            debugPrint('중복 스테이션 스킵: $cloudId');
            continue;
          }

          stationIdSet.add(cloudId);
          final stationWithCategory = station.copyWith(categoryName: catName);
          allStationsToSave.add(stationWithCategory);
          _cloudIdMap[cloudId] = cloudId;
        }
      }

      // 4. 메모리에 한 번에 할당 (중복 없이)
      _stations = List<RadioStation>.from(allStationsToSave);

      // 5. 로컬에 일괄 저장 (배치 처리로 성능 향상)
      if (allStationsToSave.isNotEmpty) {
        await _storageService.saveStations(allStationsToSave);
      }

      debugPrint('클라우드에서 ${_stations.length}개 스테이션 로드 완료 (중복 제거됨)');
      return true;
    } catch (e, stackTrace) {
      debugPrint('============================================');
      debugPrint('클라우드에서 데이터 로드 실패!');
      debugPrint('오류: $e');
      debugPrint('스택 트레이스: $stackTrace');
      debugPrint('============================================');
      return false;
    }
  }

  /// 진행률 업데이트 헬퍼
  void _updateProgress(double progress, String status, {int? total, int? processed}) {
    _loadingProgress = progress;
    _loadingStatus = status;
    if (total != null) _totalItems = total;
    if (processed != null) _processedItems = processed;
    notifyListeners();
  }

  /// Excel 파일에서 무선국 데이터 가져오기
  Future<void> importFromExcel() async {
    _isLoading = true;
    _errorMessage = null;
    _loadingProgress = 0.0;
    _loadingStatus = '파일 선택 중...';
    _totalItems = 0;
    _processedItems = 0;
    notifyListeners();

    try {
      debugPrint('===== Excel Import 시작 =====');
      debugPrint('기존 스테이션 수: ${_stations.length}');

      // 파일 선택 및 파싱 (10%)
      _updateProgress(0.05, 'Excel 파일 읽는 중...');

      // UI 업데이트를 위한 짧은 지연 (로딩 인디케이터가 표시되도록)
      await Future.delayed(const Duration(milliseconds: 50));

      final result = await _excelService.importExcelFile();

      if (result == null) {
        debugPrint('파일 선택 취소됨');
        _isLoading = false;
        _loadingProgress = 0.0;
        _loadingStatus = '';
        notifyListeners();
        return;
      }

      _updateProgress(0.15, 'Excel 데이터 분석 중...');
      await Future.delayed(const Duration(milliseconds: 50));

      final importedStations = result.stations;
      debugPrint('파일명: ${result.fileName}');
      debugPrint('Import된 스테이션 수: ${importedStations.length}');

      if (importedStations.isEmpty) {
        debugPrint('경고: Import된 스테이션이 0개입니다!');
        _errorMessage = '파일에서 데이터를 찾을 수 없습니다. 시트 구조를 확인해주세요.';
        _isLoading = false;
        _loadingProgress = 0.0;
        _loadingStatus = '';
        notifyListeners();
        return;
      }

      // 좌표가 없는 무선국 수 계산
      final stationsNeedingGeocode = importedStations.where((s) => !s.hasCoordinates && s.address.isNotEmpty).toList();
      final totalToGeocode = stationsNeedingGeocode.length;
      _totalItems = totalToGeocode;
      _processedItems = 0;

      _updateProgress(0.20, '지오코딩 준비 중... (0/$totalToGeocode)', total: totalToGeocode, processed: 0);

      // 좌표가 없는 무선국에 대해 지오코딩 수행 (20% ~ 90%)
      int geocodedCount = 0;
      for (int i = 0; i < importedStations.length; i++) {
        final station = importedStations[i];
        if (!station.hasCoordinates && station.address.isNotEmpty) {
          final coords = await _geocodingService.getCoordinatesFromAddress(
            station.address,
          );
          if (coords != null) {
            importedStations[i] = station.copyWith(
              latitude: coords['latitude'],
              longitude: coords['longitude'],
            );
            geocodedCount++;
          }
          _processedItems++;

          // 진행률 업데이트 (20% ~ 90% 구간)
          final geocodeProgress = 0.20 + (0.70 * _processedItems / totalToGeocode);
          if (_processedItems % 5 == 0 || _processedItems == totalToGeocode) {
            _updateProgress(geocodeProgress, '주소 변환 중... ($_processedItems/$totalToGeocode)', processed: _processedItems);
          }
        }
      }
      debugPrint('지오코딩 완료: $geocodedCount개');

      final categoryName = result.fileName;

      // ==================== 기존 동일 카테고리 데이터 삭제 (중복 방지) ====================
      final existingCategoryStations = _stations
          .where((s) => (s.categoryName ?? '기타') == categoryName)
          .toList();

      if (existingCategoryStations.isNotEmpty) {
        debugPrint('기존 카테고리 "$categoryName" 데이터 ${existingCategoryStations.length}개 삭제');
        _updateProgress(0.55, '기존 데이터 정리 중...');

        // 클라우드에서 기존 스테이션 삭제
        if (_cloudDataService != null) {
          final cloudCategoryId = _cloudCategoryIdMap[categoryName];
          if (cloudCategoryId != null) {
            for (final station in existingCategoryStations) {
              final cloudId = _cloudIdMap[station.id];
              if (cloudId != null) {
                try {
                  await _cloudDataService!.deleteStation(cloudId);
                } catch (e) {
                  debugPrint('기존 스테이션 클라우드 삭제 실패: $e');
                }
                _cloudIdMap.remove(station.id);
              }
            }
            // 기존 카테고리 삭제
            try {
              await _cloudDataService!.deleteCategory(cloudCategoryId);
            } catch (e) {
              debugPrint('기존 카테고리 클라우드 삭제 실패: $e');
            }
            _cloudCategoryIdMap.remove(categoryName);
          }
        }

        // 로컬에서 기존 스테이션 삭제
        for (final station in existingCategoryStations) {
          await _storageService.deleteStation(station.id);
        }
        _stations.removeWhere((s) => (s.categoryName ?? '기타') == categoryName);
      }

      // ==================== 원본 Excel 바이트 캐시 저장 (서식 유지 export용) ====================
      if (result.originalBytes != null) {
        _originalExcelBytesCache[categoryName] = result.originalBytes!;
        debugPrint('========== Import 완료 - 원본 서식 유지 상태 ==========');
        debugPrint('카테고리: $categoryName');
        debugPrint('원본 Excel 로컬 캐시: ✓ 저장됨 (${result.originalBytes!.length} bytes)');
        debugPrint('클라우드 연결: ${_cloudDataService != null ? "✓ 연결됨" : "✗ 미연결 (로컬 캐시만 사용)"}');
        debugPrint('원본 서식 유지 Export: ✓ 가능');
        debugPrint('=====================================================');
      }

      // ==================== 클라우드 업로드 (자동) ====================
      if (_cloudDataService != null) {
        _updateProgress(0.60, '클라우드에 업로드 중...');
        await Future.delayed(const Duration(milliseconds: 50));

        try {
          // 1. 새 카테고리 생성
          final cloudCategoryId = await _cloudDataService!.createCategory(categoryName);

          if (cloudCategoryId != null) {
            _cloudCategoryIdMap[categoryName] = cloudCategoryId;

            // 2. 원본 Excel 파일을 S3에 업로드 (서식 유지 export용)
            if (result.originalBytes != null) {
              try {
                final originalExcelPath = await _cloudDataService!.uploadOriginalExcel(
                  result.originalBytes!,
                  categoryName,
                );
                if (originalExcelPath != null) {
                  await _cloudDataService!.updateCategoryOriginalExcelKey(
                    cloudCategoryId,
                    originalExcelPath,
                  );
                  // S3 키를 메모리 맵에도 저장 (카테고리 삭제 시 S3 파일 삭제용)
                  _categoryOriginalExcelKeyMap[categoryName] = originalExcelPath;
                  debugPrint('원본 Excel S3 업로드 완료: $originalExcelPath');
                }
              } catch (e) {
                debugPrint('원본 Excel 업로드 실패 (무시됨): $e');
              }
            }

            // 2. 각 무선국 클라우드 업로드
            final totalStations = importedStations.length;
            int uploadedCount = 0;

            for (int i = 0; i < importedStations.length; i++) {
              final station = importedStations[i];

              // 클라우드에 업로드
              final cloudStationId = await _cloudDataService!.createStation(station, cloudCategoryId);

              if (cloudStationId != null) {
                // 로컬 ID를 클라우드 ID로 업데이트 (일관성 유지)
                importedStations[i] = station.copyWith(
                  id: cloudStationId,
                  categoryName: categoryName,
                );
                _cloudIdMap[cloudStationId] = cloudStationId;
                uploadedCount++;
              }

              // 진행률 업데이트 (60% ~ 90%)
              final uploadProgress = 0.60 + (0.30 * (i + 1) / totalStations);
              if ((i + 1) % 5 == 0 || i == totalStations - 1) {
                _updateProgress(uploadProgress, '클라우드 업로드 중... (${i + 1}/$totalStations)');
              }
            }

            debugPrint('클라우드 업로드 완료: $uploadedCount/$totalStations');
          } else {
            debugPrint('카테고리 생성 실패, 로컬에만 저장');
          }
        } catch (cloudError) {
          debugPrint('클라우드 업로드 오류 (로컬만 저장): $cloudError');
          // 클라우드 오류 시 로컬에만 저장
        }
      }

      // 로컬 저장 (캐시)
      _updateProgress(0.92, '데이터 저장 중...');
      await Future.delayed(const Duration(milliseconds: 50));

      debugPrint('저장 전 Storage 스테이션 수: ${_storageService.getAllStations().length}');
      await _storageService.saveStations(importedStations);
      debugPrint('저장 후 Storage 스테이션 수: ${_storageService.getAllStations().length}');

      _updateProgress(0.98, '완료 중...');
      await Future.delayed(const Duration(milliseconds: 50));

      _stations = _storageService.getAllStations();
      debugPrint('최종 _stations 수: ${_stations.length}');
      debugPrint('===== Excel Import 완료 =====');

      _updateProgress(1.0, '완료!');
    } catch (e) {
      debugPrint('Excel 가져오기 오류: $e');
      _errorMessage = 'Excel 가져오기 실패: $e';
    } finally {
      _isLoading = false;
      _loadingProgress = 0.0;
      _loadingStatus = '';
      notifyListeners();
    }
  }

  /// 무선국 선택
  void selectStation(RadioStation? station) {
    _selectedStation = station;
    notifyListeners();
  }

  /// 메모 업데이트 (자동 클라우드 동기화)
  Future<void> updateMemo(String id, String memo) async {
    try {
      await _storageService.updateMemo(id, memo);
      final index = _stations.indexWhere((s) => s.id == id);
      if (index != -1) {
        _stations[index] = _stations[index].copyWith(memo: memo);
        if (_selectedStation?.id == id) {
          _selectedStation = _stations[index];
        }
        notifyListeners();

        // 클라우드 동기화 (백그라운드)
        _syncStationToCloud(_stations[index]);
      }
    } catch (e) {
      _errorMessage = '메모 저장 실패: $e';
      notifyListeners();
    }
  }

  /// 검사 완료 상태 업데이트 (자동 클라우드 동기화)
  Future<void> updateInspectionStatus(String id, bool isInspected) async {
    try {
      await _storageService.updateInspectionStatus(id, isInspected);
      final index = _stations.indexWhere((s) => s.id == id);
      if (index != -1) {
        _stations[index] = _stations[index].copyWith(
          isInspected: isInspected,
          inspectionDate: isInspected ? DateTime.now() : null,
        );
        if (_selectedStation?.id == id) {
          _selectedStation = _stations[index];
        }
        notifyListeners();

        // 클라우드 동기화 (백그라운드)
        _syncStationToCloud(_stations[index]);
      }
    } catch (e) {
      _errorMessage = '상태 업데이트 실패: $e';
      notifyListeners();
    }
  }

  /// 사진 경로 업데이트 (자동 클라우드 동기화)
  Future<void> updatePhotoPaths(String id, List<String> photoPaths) async {
    try {
      await _storageService.updatePhotoPaths(id, photoPaths);
      final index = _stations.indexWhere((s) => s.id == id);
      if (index != -1) {
        _stations[index] = _stations[index].copyWith(photoPaths: photoPaths);
        if (_selectedStation?.id == id) {
          _selectedStation = _stations[index];
        }
        notifyListeners();

        // 클라우드 동기화 (백그라운드)
        _syncStationToCloud(_stations[index]);
      }
    } catch (e) {
      _errorMessage = '사진 저장 실패: $e';
      notifyListeners();
    }
  }

  /// 설치대(철탑형태) 업데이트 (자동 클라우드 동기화)
  Future<void> updateInstallationType(String id, String installationType) async {
    try {
      await _storageService.updateInstallationType(id, installationType);
      final index = _stations.indexWhere((s) => s.id == id);
      if (index != -1) {
        _stations[index] = _stations[index].copyWith(installationType: installationType);
        if (_selectedStation?.id == id) {
          _selectedStation = _stations[index];
        }
        notifyListeners();

        // 클라우드 동기화 (백그라운드)
        _syncStationToCloud(_stations[index]);
      }
    } catch (e) {
      _errorMessage = '설치대 저장 실패: $e';
      notifyListeners();
    }
  }

  /// 무선국 삭제 (자동 클라우드 동기화)
  Future<void> deleteStation(String id) async {
    try {
      // 클라우드에서 먼저 삭제 시도
      final cloudId = _cloudIdMap[id];
      if (_cloudDataService != null && cloudId != null) {
        try {
          await _cloudDataService!.deleteStation(cloudId);
        } catch (e) {
          debugPrint('클라우드 삭제 실패: $e');
        }
        _cloudIdMap.remove(id);
      }

      await _storageService.deleteStation(id);
      _stations.removeWhere((s) => s.id == id);
      if (_selectedStation?.id == id) {
        _selectedStation = null;
      }
      notifyListeners();
    } catch (e) {
      _errorMessage = '삭제 실패: $e';
      notifyListeners();
    }
  }

  /// 단일 스테이션 클라우드 동기화 (백그라운드)
  Future<void> _syncStationToCloud(RadioStation station) async {
    if (_cloudDataService == null) return;

    try {
      final cloudId = _cloudIdMap[station.id];
      final categoryName = station.categoryName ?? '기타';
      final cloudCategoryId = _cloudCategoryIdMap[categoryName];

      if (cloudId != null && cloudCategoryId != null) {
        // 기존 스테이션 업데이트
        await _cloudDataService!.updateStation(station, cloudCategoryId);
        debugPrint('클라우드 동기화 완료: ${station.id}');
      } else if (cloudCategoryId != null) {
        // 새 스테이션 생성
        final newCloudId = await _cloudDataService!.createStation(station, cloudCategoryId);
        if (newCloudId != null) {
          _cloudIdMap[station.id] = newCloudId;
          debugPrint('클라우드에 새 스테이션 생성: ${station.id} -> $newCloudId');
        }
      }
    } catch (e) {
      debugPrint('클라우드 동기화 오류 (무시됨): $e');
    }
  }

  /// 카테고리별 데이터 삭제 (자동 클라우드 동기화)
  /// [onProgress] 콜백으로 진행률 전달 (0.0 ~ 1.0)
  Future<void> deleteCategoryData(String category, {Function(double)? onProgress}) async {
    debugPrint('========== 카테고리 삭제 시작 ==========');
    debugPrint('카테고리: $category');

    try {
      final stationsToDelete = _stations
          .where((s) => (s.categoryName ?? '기타') == category)
          .toList();

      final totalCount = stationsToDelete.length;
      int processedCount = 0;

      // 클라우드에서 카테고리 삭제
      final cloudCategoryId = _cloudCategoryIdMap[category];
      if (_cloudDataService != null && cloudCategoryId != null) {
        try {
          // 1. S3에서 원본 Excel 파일 삭제
          final originalExcelKey = _categoryOriginalExcelKeyMap[category];
          if (originalExcelKey != null && originalExcelKey.isNotEmpty) {
            debugPrint('S3 원본 Excel 삭제 시도: $originalExcelKey');
            final deleted = await _cloudDataService!.deleteOriginalExcel(originalExcelKey);
            debugPrint('S3 원본 Excel 삭제 ${deleted ? "성공" : "실패"}: $originalExcelKey');
          }

          // 2. 해당 카테고리의 모든 스테이션 삭제
          for (final station in stationsToDelete) {
            final cloudId = _cloudIdMap[station.id];
            if (cloudId != null) {
              await _cloudDataService!.deleteStation(cloudId);
              _cloudIdMap.remove(station.id);
            }
            processedCount++;
            // 클라우드 삭제 진행률 (0% ~ 50%)
            onProgress?.call(processedCount / totalCount * 0.5);
          }

          // 3. 카테고리 삭제
          await _cloudDataService!.deleteCategory(cloudCategoryId);
          debugPrint('클라우드 카테고리 삭제 완료: $cloudCategoryId');
        } catch (e) {
          debugPrint('클라우드 카테고리 삭제 실패: $e');
        }
        _cloudCategoryIdMap.remove(category);
      } else {
        // 클라우드 서비스 없으면 바로 50%로 설정
        onProgress?.call(0.5);
      }

      // 로컬 캐시 및 매핑 정리
      _originalExcelBytesCache.remove(category);
      _categoryOriginalExcelKeyMap.remove(category);
      debugPrint('로컬 캐시 및 S3 키 매핑 삭제 완료: $category');

      // 로컬 삭제 (50% ~ 100%)
      processedCount = 0;
      for (final station in stationsToDelete) {
        await _storageService.deleteStation(station.id);
        processedCount++;
        // 로컬 삭제 진행률 (50% ~ 100%)
        onProgress?.call(0.5 + processedCount / totalCount * 0.5);
      }

      _stations.removeWhere((s) => (s.categoryName ?? '기타') == category);
      _selectedCategories.remove(category);

      if (_selectedStation != null &&
          (_selectedStation!.categoryName ?? '기타') == category) {
        _selectedStation = null;
      }

      debugPrint('========== 카테고리 삭제 완료 ==========');
      notifyListeners();
    } catch (e) {
      debugPrint('카테고리 삭제 실패: $e');
      _errorMessage = '카테고리 삭제 실패: $e';
      notifyListeners();
    }
  }

  /// 모든 데이터 삭제
  Future<void> clearAllData() async {
    try {
      await _storageService.clearAllStations();
      _stations.clear();
      _selectedStation = null;
      _selectedCategories.clear();
      _cloudIdMap.clear();
      _cloudCategoryIdMap.clear();
      _categoryOriginalExcelKeyMap.clear();
      _isDataLoaded = false; // 데이터 로드 상태 초기화
      notifyListeners();
    } catch (e) {
      _errorMessage = '데이터 삭제 실패: $e';
      notifyListeners();
    }
  }

  /// 로그아웃 시 상태 초기화
  void resetForLogout() {
    _stations.clear();
    _selectedStation = null;
    _selectedCategories.clear();
    _cloudIdMap.clear();
    _cloudCategoryIdMap.clear();
    _categoryOriginalExcelKeyMap.clear();
    _isDataLoaded = false;
    _cloudDataService = null;
    notifyListeners();
  }

  /// 에러 메시지 초기화
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// CloudDataService 설정
  void setCloudDataService(CloudDataService service) {
    _cloudDataService = service;
    debugPrint('========== 클라우드 서비스 연결 상태 ==========');
    debugPrint('CloudDataService 연결됨: ${_cloudDataService != null}');
    debugPrint('===============================================');
  }

  /// 클라우드 연결 여부 확인
  bool get isCloudConnected => _cloudDataService != null;

  /// 클라우드 연결 상태 상세 로그 출력
  void printCloudStatus() {
    debugPrint('========== 클라우드/S3 연결 상태 상세 ==========');
    debugPrint('CloudDataService 연결: ${_cloudDataService != null ? "✓ 연결됨" : "✗ 미연결"}');
    debugPrint('카테고리 클라우드 ID 매핑: ${_cloudCategoryIdMap.length}개');
    debugPrint('원본 Excel S3 키 매핑: ${_categoryOriginalExcelKeyMap.length}개');
    debugPrint('원본 Excel 로컬 캐시: ${_originalExcelBytesCache.length}개');

    if (_categoryOriginalExcelKeyMap.isNotEmpty) {
      debugPrint('--- S3 원본 Excel 키 목록 ---');
      _categoryOriginalExcelKeyMap.forEach((category, key) {
        debugPrint('  - $category: $key');
      });
    }

    if (_originalExcelBytesCache.isNotEmpty) {
      debugPrint('--- 로컬 캐시 원본 Excel 목록 ---');
      _originalExcelBytesCache.forEach((category, bytes) {
        debugPrint('  - $category: ${bytes.length} bytes');
      });
    }

    debugPrint('===============================================');
  }

  // ==================== 클라우드 동기화 기능 ====================

  /// 카테고리별 데이터를 클라우드로 업로드
  Future<bool> syncCategoryToCloud(String category) async {
    if (_cloudDataService == null) {
      _errorMessage = '클라우드 서비스가 초기화되지 않았습니다.';
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _loadingStatus = '클라우드 업로드 중...';
    notifyListeners();

    try {
      final categoryStations = stationsByCategory[category] ?? [];
      if (categoryStations.isEmpty) {
        _errorMessage = '업로드할 데이터가 없습니다.';
        _isLoading = false;
        notifyListeners();
        return false;
      }

      final success = await _cloudDataService!.syncLocalToCloud(
        categoryName: category,
        stations: categoryStations,
      );

      _isLoading = false;
      _loadingStatus = '';
      notifyListeners();

      return success;
    } catch (e) {
      _errorMessage = '클라우드 업로드 실패: $e';
      _isLoading = false;
      _loadingStatus = '';
      notifyListeners();
      return false;
    }
  }

  /// 모든 카테고리를 클라우드로 업로드
  Future<bool> syncAllToCloud() async {
    if (_cloudDataService == null) {
      _errorMessage = '클라우드 서비스가 초기화되지 않았습니다.';
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _loadingStatus = '클라우드 업로드 준비 중...';
    _totalItems = categories.length;
    _processedItems = 0;
    notifyListeners();

    try {
      bool allSuccess = true;

      for (final category in categories) {
        _loadingStatus = '$category 업로드 중...';
        notifyListeners();

        final categoryStations = stationsByCategory[category] ?? [];
        if (categoryStations.isNotEmpty) {
          final success = await _cloudDataService!.syncLocalToCloud(
            categoryName: category,
            stations: categoryStations,
          );
          if (!success) allSuccess = false;
        }

        _processedItems++;
        _loadingProgress = _processedItems / _totalItems;
        notifyListeners();
      }

      _isLoading = false;
      _loadingStatus = '';
      _loadingProgress = 0.0;
      notifyListeners();

      return allSuccess;
    } catch (e) {
      _errorMessage = '클라우드 업로드 실패: $e';
      _isLoading = false;
      _loadingStatus = '';
      _loadingProgress = 0.0;
      notifyListeners();
      return false;
    }
  }

  /// 클라우드에서 데이터 다운로드
  Future<bool> syncFromCloud() async {
    if (_cloudDataService == null) {
      _errorMessage = '클라우드 서비스가 초기화되지 않았습니다.';
      notifyListeners();
      return false;
    }

    _isLoading = true;
    _loadingStatus = '클라우드에서 다운로드 중...';
    notifyListeners();

    try {
      final cloudData = await _cloudDataService!.syncCloudToLocal();

      if (cloudData.isEmpty) {
        _isLoading = false;
        _loadingStatus = '';
        notifyListeners();
        return true; // 데이터가 없어도 성공
      }

      _loadingStatus = '데이터 저장 중...';
      notifyListeners();

      // 다운로드한 데이터를 로컬에 저장
      for (final entry in cloudData.entries) {
        await _storageService.saveStations(entry.value);
      }

      // 로컬 데이터 다시 로드
      _stations = _storageService.getAllStations();

      _isLoading = false;
      _loadingStatus = '';
      notifyListeners();

      return true;
    } catch (e) {
      _errorMessage = '클라우드 다운로드 실패: $e';
      _isLoading = false;
      _loadingStatus = '';
      notifyListeners();
      return false;
    }
  }

  /// 카테고리별 데이터를 Excel로 내보내기
  /// saveOnly: true면 저장만, false면 공유 다이얼로그도 표시
  Future<String?> exportCategoryToExcel(String category, {bool saveOnly = false}) async {
    try {
      final categoryStations = stationsByCategory[category] ?? [];
      if (categoryStations.isEmpty) {
        throw Exception('내보낼 데이터가 없습니다.');
      }

      final filePath = await _excelService.exportToExcel(categoryStations, category, saveOnly: saveOnly);
      return filePath;
    } catch (e) {
      _errorMessage = 'Excel 내보내기 실패: $e';
      notifyListeners();
      return null;
    }
  }

  /// 카테고리에 원본 Excel이 있는지 확인 (캐시 또는 S3)
  bool hasOriginalExcel(String category) {
    // 1. 메모리 캐시에 있는지 확인
    if (_originalExcelBytesCache.containsKey(category)) {
      return true;
    }
    // 2. S3 키가 있는지 확인
    return _categoryOriginalExcelKeyMap.containsKey(category) &&
           _categoryOriginalExcelKeyMap[category]!.isNotEmpty;
  }

  /// 원본 Excel 서식을 유지하여 내보내기 (수검여부/특이사항 컬럼만 추가)
  /// saveOnly: true면 저장만, false면 공유 다이얼로그도 표시
  Future<String?> exportCategoryWithOriginalFormat(String category, {bool saveOnly = false}) async {
    debugPrint('========== 원본 서식 유지 Export 시작 ==========');
    debugPrint('카테고리: $category');
    debugPrint('로컬 캐시 존재: ${_originalExcelBytesCache.containsKey(category) ? "✓" : "✗"}');
    debugPrint('S3 키 존재: ${_categoryOriginalExcelKeyMap.containsKey(category) ? "✓" : "✗"}');
    debugPrint('클라우드 연결: ${_cloudDataService != null ? "✓" : "✗"}');

    try {
      final categoryStations = stationsByCategory[category] ?? [];
      if (categoryStations.isEmpty) {
        throw Exception('내보낼 데이터가 없습니다.');
      }

      Uint8List? originalBytes;

      // 1. 메모리 캐시에서 먼저 확인
      if (_originalExcelBytesCache.containsKey(category)) {
        originalBytes = _originalExcelBytesCache[category];
        debugPrint('→ 원본 Excel 소스: 로컬 캐시 (${originalBytes?.length ?? 0} bytes)');
      }
      // 2. 캐시가 없으면 S3에서 다운로드 시도
      else if (_cloudDataService != null) {
        final originalExcelKey = _categoryOriginalExcelKeyMap[category];
        if (originalExcelKey != null && originalExcelKey.isNotEmpty) {
          debugPrint('→ 원본 Excel 소스: S3 다운로드 시도 ($originalExcelKey)');
          originalBytes = await _cloudDataService!.downloadOriginalExcel(originalExcelKey);
          if (originalBytes != null) {
            debugPrint('→ S3 다운로드 성공: ${originalBytes.length} bytes');
            // 다운로드한 바이트를 캐시에 저장
            _originalExcelBytesCache[category] = originalBytes;
          }
        }
      } else {
        debugPrint('→ 클라우드 미연결 & 캐시 없음');
      }

      if (originalBytes == null) {
        throw Exception('원본 Excel 파일이 없습니다. 일반 내보내기를 사용해주세요.');
      }

      // 원본 서식 유지하여 내보내기
      final filePath = await _excelService.exportWithOriginalFormat(
        originalBytes,
        categoryStations,
        category,
        saveOnly: saveOnly,
      );
      return filePath;
    } catch (e) {
      _errorMessage = '원본 서식 Excel 내보내기 실패: $e';
      notifyListeners();
      return null;
    }
  }

  /// Excel 파일 공유
  Future<void> shareExcelFile(String filePath) async {
    try {
      await _excelService.shareExcelFile(filePath);
    } catch (e) {
      _errorMessage = '파일 공유 실패: $e';
      notifyListeners();
    }
  }
}
