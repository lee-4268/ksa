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

  // 진행률 관련 상태
  double _loadingProgress = 0.0; // 0.0 ~ 1.0
  String _loadingStatus = ''; // 현재 작업 상태 메시지
  int _totalItems = 0;
  int _processedItems = 0;

  // 클라우드 ID 매핑 (로컬 ID -> 클라우드 ID)
  final Map<String, String> _cloudIdMap = {};
  // 카테고리 클라우드 ID 매핑 (카테고리명 -> 클라우드 카테고리 ID)
  final Map<String, String> _cloudCategoryIdMap = {};

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

  // 카테고리별 스테이션 맵
  Map<String, List<RadioStation>> get stationsByCategory {
    final map = <String, List<RadioStation>>{};
    for (final station in _stations) {
      final category = station.categoryName ?? '기타';
      map.putIfAbsent(category, () => []);
      map[category]!.add(station);
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
  Future<void> loadStations() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      // 클라우드에서 데이터 로드 시도
      if (_cloudDataService != null) {
        _loadingStatus = '클라우드에서 데이터 로드 중...';
        notifyListeners();

        final cloudSuccess = await _loadFromCloud();
        if (cloudSuccess) {
          debugPrint('클라우드에서 데이터 로드 완료: ${_stations.length}개');
          _isLoading = false;
          _loadingStatus = '';
          notifyListeners();
          return;
        }
      }

      // 클라우드 실패 시 로컬에서 로드 (fallback)
      debugPrint('로컬에서 데이터 로드 시도');
      _stations = _storageService.getAllStations();
      debugPrint('로컬에서 로드 완료: ${_stations.length}개');
    } catch (e) {
      _errorMessage = '데이터 로드 실패: $e';
      debugPrint(_errorMessage);
    } finally {
      _isLoading = false;
      _loadingStatus = '';
      notifyListeners();
    }
  }

  /// 클라우드에서 데이터 로드 (내부 함수)
  Future<bool> _loadFromCloud() async {
    if (_cloudDataService == null) return false;

    try {
      final cloudData = await _cloudDataService!.syncCloudToLocal();

      // 클라우드에 데이터가 없으면 로컬 데이터 유지
      if (cloudData.isEmpty) {
        debugPrint('클라우드에 데이터 없음, 로컬 데이터 유지');
        _stations = _storageService.getAllStations();
        return true;
      }

      // 클라우드 데이터로 교체
      await _storageService.clearAllStations();
      _stations.clear();
      _cloudIdMap.clear();
      _cloudCategoryIdMap.clear();

      // 카테고리 목록 조회
      final categories = await _cloudDataService!.listCategories();
      for (final cat in categories) {
        final catName = cat['name'] as String;
        final catId = cat['id'] as String;
        _cloudCategoryIdMap[catName] = catId;
      }

      for (final entry in cloudData.entries) {
        final categoryName = entry.key;
        final stations = entry.value;

        // 스테이션 저장 (로컬 캐시)
        for (final station in stations) {
          final stationWithCategory = station.copyWith(categoryName: categoryName);
          await _storageService.saveStation(stationWithCategory);
          _stations.add(stationWithCategory);

          // 클라우드 ID 매핑
          _cloudIdMap[stationWithCategory.id] = station.id;
        }
      }

      return true;
    } catch (e) {
      debugPrint('클라우드에서 데이터 로드 실패: $e');
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

      // ==================== 클라우드 업로드 (자동) ====================
      if (_cloudDataService != null) {
        _updateProgress(0.60, '클라우드에 업로드 중...');
        await Future.delayed(const Duration(milliseconds: 50));

        try {
          // 1. 카테고리 생성 또는 조회
          String? cloudCategoryId = _cloudCategoryIdMap[categoryName];

          if (cloudCategoryId == null) {
            // 기존 카테고리 확인
            final categories = await _cloudDataService!.listCategories();
            for (final cat in categories) {
              if (cat['name'] == categoryName) {
                cloudCategoryId = cat['id'] as String;
                _cloudCategoryIdMap[categoryName] = cloudCategoryId;
                break;
              }
            }

            // 없으면 새로 생성
            if (cloudCategoryId == null) {
              cloudCategoryId = await _cloudDataService!.createCategory(categoryName);
              if (cloudCategoryId != null) {
                _cloudCategoryIdMap[categoryName] = cloudCategoryId;
              }
            }
          }

          // 2. 각 무선국 클라우드 업로드
          if (cloudCategoryId != null) {
            final totalStations = importedStations.length;
            int uploadedCount = 0;

            for (int i = 0; i < importedStations.length; i++) {
              final station = importedStations[i];

              // 클라우드에 업로드
              final cloudStationId = await _cloudDataService!.createStation(station, cloudCategoryId);

              if (cloudStationId != null) {
                _cloudIdMap[station.id] = cloudStationId;
                uploadedCount++;
              }

              // 진행률 업데이트 (60% ~ 90%)
              final uploadProgress = 0.60 + (0.30 * (i + 1) / totalStations);
              if ((i + 1) % 5 == 0 || i == totalStations - 1) {
                _updateProgress(uploadProgress, '클라우드 업로드 중... (${i + 1}/$totalStations)');
              }
            }

            debugPrint('클라우드 업로드 완료: $uploadedCount/$totalStations');
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
  Future<void> deleteCategoryData(String category) async {
    try {
      final stationsToDelete = _stations
          .where((s) => (s.categoryName ?? '기타') == category)
          .toList();

      // 클라우드에서 카테고리 삭제
      final cloudCategoryId = _cloudCategoryIdMap[category];
      if (_cloudDataService != null && cloudCategoryId != null) {
        try {
          // 먼저 해당 카테고리의 모든 스테이션 삭제
          for (final station in stationsToDelete) {
            final cloudId = _cloudIdMap[station.id];
            if (cloudId != null) {
              await _cloudDataService!.deleteStation(cloudId);
              _cloudIdMap.remove(station.id);
            }
          }
          // 카테고리 삭제
          await _cloudDataService!.deleteCategory(cloudCategoryId);
        } catch (e) {
          debugPrint('클라우드 카테고리 삭제 실패: $e');
        }
        _cloudCategoryIdMap.remove(category);
      }

      for (final station in stationsToDelete) {
        await _storageService.deleteStation(station.id);
      }

      _stations.removeWhere((s) => (s.categoryName ?? '기타') == category);
      _selectedCategories.remove(category);

      if (_selectedStation != null &&
          (_selectedStation!.categoryName ?? '기타') == category) {
        _selectedStation = null;
      }
      notifyListeners();
    } catch (e) {
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
      notifyListeners();
    } catch (e) {
      _errorMessage = '데이터 삭제 실패: $e';
      notifyListeners();
    }
  }

  /// 에러 메시지 초기화
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// CloudDataService 설정
  void setCloudDataService(CloudDataService service) {
    _cloudDataService = service;
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
