import 'package:flutter/foundation.dart';
import '../models/radio_station.dart';
import '../services/excel_service.dart';
import '../services/geocoding_service.dart';
import '../services/storage_service.dart';

class StationProvider extends ChangeNotifier {
  final StorageService _storageService;
  final ExcelService _excelService = ExcelService();
  final GeocodingService _geocodingService = GeocodingService();

  List<RadioStation> _stations = [];
  bool _isLoading = false;
  String? _errorMessage;
  RadioStation? _selectedStation;
  String _searchQuery = '';
  Set<String> _selectedCategories = {};

  StationProvider(this._storageService);

  List<RadioStation> get stations => _stations;
  List<RadioStation> get stationsWithCoordinates =>
      _filteredStations.where((s) => s.hasCoordinates).toList();
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
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

  /// 저장된 무선국 데이터 로드
  Future<void> loadStations() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _stations = _storageService.getAllStations();
    } catch (e) {
      _errorMessage = '데이터 로드 실패: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Excel 파일에서 무선국 데이터 가져오기
  Future<void> importFromExcel() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      debugPrint('===== Excel Import 시작 =====');
      debugPrint('기존 스테이션 수: ${_stations.length}');

      final result = await _excelService.importExcelFile();

      if (result == null) {
        debugPrint('파일 선택 취소됨');
        _isLoading = false;
        notifyListeners();
        return;
      }

      final importedStations = result.stations;
      debugPrint('파일명: ${result.fileName}');
      debugPrint('Import된 스테이션 수: ${importedStations.length}');

      if (importedStations.isEmpty) {
        debugPrint('경고: Import된 스테이션이 0개입니다!');
        _errorMessage = '파일에서 데이터를 찾을 수 없습니다. 시트 구조를 확인해주세요.';
        _isLoading = false;
        notifyListeners();
        return;
      }

      // 좌표가 없는 무선국에 대해 지오코딩 수행
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
        }
      }
      debugPrint('지오코딩 완료: $geocodedCount개');

      // 저장 및 목록 업데이트
      debugPrint('저장 전 Storage 스테이션 수: ${_storageService.getAllStations().length}');
      await _storageService.saveStations(importedStations);
      debugPrint('저장 후 Storage 스테이션 수: ${_storageService.getAllStations().length}');

      _stations = _storageService.getAllStations();
      debugPrint('최종 _stations 수: ${_stations.length}');
      debugPrint('===== Excel Import 완료 =====');
    } catch (e) {
      debugPrint('Excel 가져오기 오류: $e');
      _errorMessage = 'Excel 가져오기 실패: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 무선국 선택
  void selectStation(RadioStation? station) {
    _selectedStation = station;
    notifyListeners();
  }

  /// 메모 업데이트
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
      }
    } catch (e) {
      _errorMessage = '메모 저장 실패: $e';
      notifyListeners();
    }
  }

  /// 검사 완료 상태 업데이트
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
      }
    } catch (e) {
      _errorMessage = '상태 업데이트 실패: $e';
      notifyListeners();
    }
  }

  /// 사진 경로 업데이트
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
      }
    } catch (e) {
      _errorMessage = '사진 저장 실패: $e';
      notifyListeners();
    }
  }

  /// 무선국 삭제
  Future<void> deleteStation(String id) async {
    try {
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

  /// 카테고리별 데이터 삭제
  Future<void> deleteCategoryData(String category) async {
    try {
      final stationsToDelete = _stations
          .where((s) => (s.categoryName ?? '기타') == category)
          .toList();

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
