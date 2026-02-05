import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/radio_station.dart';

/// EC2 FastAPI를 통한 클라우드 데이터 서비스 (REST API)
class CloudDataService extends ChangeNotifier {
  bool _isLoading = false;
  String? _errorMessage;
  bool _isSyncing = false;

  /// API 서버 URL (EC2 FastAPI)
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  /// 앱 레벨 사용자 격리용 userId (사번)
  String? _userId;
  String? get userId => _userId;
  void setUserId(String? userId) {
    _userId = userId;
    debugPrint('CloudDataService userId 설정: $userId');
  }

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isSyncing => _isSyncing;

  // HTTP 헤더
  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  // ==================== Category CRUD ====================

  /// 카테고리 생성
  Future<String?> createCategory(String name, {String? originalExcelKey}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final body = {
        'name': name,
        'owner': _userId ?? '',
        if (originalExcelKey != null) 'originalExcelKey': originalExcelKey,
      };

      final response = await http.post(
        Uri.parse('$_baseUrl/categories'),
        headers: _headers,
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final categoryId = data['category']['id'] as String?;
          debugPrint('카테고리 생성 완료: $categoryId');
          _isLoading = false;
          notifyListeners();
          return categoryId;
        }
      }

      _errorMessage = '카테고리 생성 실패: ${response.body}';
      debugPrint(_errorMessage);
      _isLoading = false;
      notifyListeners();
      return null;
    } catch (e) {
      _errorMessage = '카테고리 생성 실패: $e';
      debugPrint(_errorMessage);
      _isLoading = false;
      notifyListeners();
      return null;
    }
  }

  /// 모든 카테고리 조회
  Future<List<Map<String, dynamic>>> listCategories() async {
    try {
      if (_userId == null) {
        debugPrint('userId가 설정되지 않음');
        return [];
      }

      final response = await http.get(
        Uri.parse('$_baseUrl/categories?owner=$_userId'),
        headers: _headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final categories = (data['categories'] as List).cast<Map<String, dynamic>>();
          debugPrint('카테고리 ${categories.length}개 조회');
          return categories;
        }
      }

      debugPrint('카테고리 목록 조회 실패: ${response.body}');
      return [];
    } catch (e) {
      debugPrint('카테고리 목록 조회 실패: $e');
      return [];
    }
  }

  /// 카테고리 삭제
  Future<bool> deleteCategory(String categoryId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await http.delete(
        Uri.parse('$_baseUrl/categories/$categoryId'),
        headers: _headers,
      );

      _isLoading = false;
      notifyListeners();

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['success'] == true;
      }

      _errorMessage = '카테고리 삭제 실패: ${response.body}';
      return false;
    } catch (e) {
      _errorMessage = '카테고리 삭제 실패: $e';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // ==================== Station CRUD ====================

  /// 무선국 생성
  Future<String?> createStation(RadioStation station, String categoryId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final body = {
        'categoryId': categoryId,
        'owner': _userId ?? '',
        'stationName': station.stationName,
        'address': station.address,
        'licenseNumber': station.licenseNumber,
        'latitude': station.latitude,
        'longitude': station.longitude,
        'callSign': station.callSign,
        'gain': station.gain,
        'antennaCount': station.antennaCount,
        'remarks': station.remarks,
        'typeApprovalNumber': station.typeApprovalNumber,
        'frequency': station.frequency,
        'stationType': station.stationType,
        'stationOwner': station.owner,
        'installationType': station.installationType,
        'isInspected': station.isInspected,
        'inspectionDate': station.inspectionDate?.toUtc().toIso8601String(),
        'memo': station.memo,
        'photoKeys': station.photoPaths,
      };

      final response = await http.post(
        Uri.parse('$_baseUrl/stations'),
        headers: _headers,
        body: jsonEncode(body),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final stationId = data['station']['id'] as String?;
          debugPrint('무선국 생성 완료: $stationId');
          _isLoading = false;
          notifyListeners();
          return stationId;
        }
      }

      _errorMessage = '무선국 생성 실패: ${response.body}';
      debugPrint(_errorMessage);
      _isLoading = false;
      notifyListeners();
      return null;
    } catch (e) {
      _errorMessage = '무선국 생성 실패: $e';
      debugPrint(_errorMessage);
      _isLoading = false;
      notifyListeners();
      return null;
    }
  }

  /// 카테고리별 무선국 목록 조회
  Future<List<RadioStation>> listStationsByCategory(String categoryId) async {
    try {
      if (_userId == null) {
        debugPrint('userId가 설정되지 않음');
        return [];
      }

      final response = await http.get(
        Uri.parse('$_baseUrl/stations?owner=$_userId&categoryId=$categoryId'),
        headers: _headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final items = (data['stations'] as List).cast<Map<String, dynamic>>();
          final stations = items.map((item) => _mapToRadioStation(item)).toList();
          debugPrint('카테고리 $categoryId: ${stations.length}개 스테이션 조회');
          return stations;
        }
      }

      debugPrint('무선국 목록 조회 실패: ${response.body}');
      return [];
    } catch (e) {
      debugPrint('무선국 목록 조회 실패: $e');
      return [];
    }
  }

  /// 모든 무선국 조회
  Future<List<RadioStation>> listAllStations() async {
    try {
      if (_userId == null) {
        debugPrint('userId가 설정되지 않음');
        return [];
      }

      final response = await http.get(
        Uri.parse('$_baseUrl/stations?owner=$_userId'),
        headers: _headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final items = (data['stations'] as List).cast<Map<String, dynamic>>();
          final stations = items.map((item) => _mapToRadioStation(item)).toList();
          debugPrint('전체 스테이션 ${stations.length}개 조회');
          return stations;
        }
      }

      debugPrint('전체 무선국 목록 조회 실패: ${response.body}');
      return [];
    } catch (e) {
      debugPrint('전체 무선국 목록 조회 실패: $e');
      return [];
    }
  }

  /// 무선국 업데이트
  Future<bool> updateStation(RadioStation station, String categoryId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final body = {
        'stationName': station.stationName,
        'address': station.address,
        'licenseNumber': station.licenseNumber,
        'latitude': station.latitude,
        'longitude': station.longitude,
        'callSign': station.callSign,
        'gain': station.gain,
        'antennaCount': station.antennaCount,
        'remarks': station.remarks,
        'typeApprovalNumber': station.typeApprovalNumber,
        'frequency': station.frequency,
        'stationType': station.stationType,
        'stationOwner': station.owner,
        'installationType': station.installationType,
        'isInspected': station.isInspected,
        'inspectionDate': station.inspectionDate?.toUtc().toIso8601String(),
        'memo': station.memo,
        'photoKeys': station.photoPaths,
      };

      final response = await http.put(
        Uri.parse('$_baseUrl/stations/${station.id}'),
        headers: _headers,
        body: jsonEncode(body),
      );

      _isLoading = false;
      notifyListeners();

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          debugPrint('무선국 업데이트 완료: ${station.id}');
          return true;
        }
      }

      _errorMessage = '무선국 업데이트 실패: ${response.body}';
      debugPrint(_errorMessage);
      return false;
    } catch (e) {
      _errorMessage = '무선국 업데이트 실패: $e';
      debugPrint(_errorMessage);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// 무선국 삭제
  Future<bool> deleteStation(String stationId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await http.delete(
        Uri.parse('$_baseUrl/stations/$stationId'),
        headers: _headers,
      );

      _isLoading = false;
      notifyListeners();

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['success'] == true;
      }

      _errorMessage = '무선국 삭제 실패: ${response.body}';
      return false;
    } catch (e) {
      _errorMessage = '무선국 삭제 실패: $e';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // ==================== 동기화 기능 ====================

  /// 로컬 데이터를 클라우드로 업로드 (카테고리 단위)
  Future<bool> syncLocalToCloud({
    required String categoryName,
    required List<RadioStation> stations,
  }) async {
    _isSyncing = true;
    _errorMessage = null;
    notifyListeners();

    try {
      // 1. 카테고리 생성 또는 찾기
      final categories = await listCategories();
      String? categoryId;

      for (final cat in categories) {
        if (cat['name'] == categoryName) {
          categoryId = cat['id'] as String?;
          break;
        }
      }

      if (categoryId == null) {
        categoryId = await createCategory(categoryName);
        if (categoryId == null) {
          _isSyncing = false;
          notifyListeners();
          return false;
        }
      }

      // 2. 각 무선국 업로드
      int successCount = 0;
      for (final station in stations) {
        final stationId = await createStation(station, categoryId);
        if (stationId != null) {
          successCount++;
        }
      }

      debugPrint('동기화 완료: $successCount/${stations.length} 무선국 업로드');

      _isSyncing = false;
      notifyListeners();
      return successCount == stations.length;
    } catch (e) {
      _errorMessage = '동기화 실패: $e';
      debugPrint(_errorMessage);
      _isSyncing = false;
      notifyListeners();
      return false;
    }
  }

  /// 클라우드 데이터를 로컬로 다운로드
  Future<Map<String, List<RadioStation>>> syncCloudToLocal() async {
    _isSyncing = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = <String, List<RadioStation>>{};

      // 1. 모든 카테고리 가져오기
      final categories = await listCategories();

      // 2. 각 카테고리의 무선국 가져오기
      for (final category in categories) {
        final categoryId = category['id'] as String;
        final categoryName = category['name'] as String;

        final stations = await listStationsByCategory(categoryId);

        // categoryName 설정
        for (var i = 0; i < stations.length; i++) {
          stations[i] = stations[i].copyWith(categoryName: categoryName);
        }

        result[categoryName] = stations;
      }

      debugPrint('클라우드에서 ${result.length}개 카테고리, ${result.values.fold(0, (sum, list) => sum + list.length)}개 무선국 다운로드');

      _isSyncing = false;
      notifyListeners();
      return result;
    } catch (e) {
      _errorMessage = '클라우드 데이터 다운로드 실패: $e';
      debugPrint(_errorMessage);
      _isSyncing = false;
      notifyListeners();
      return {};
    }
  }

  // ==================== Helper Methods ====================

  RadioStation _mapToRadioStation(Map<String, dynamic> data) {
    final installationType = data['installationType'] as String?;
    return RadioStation(
      id: data['id'] as String? ?? '',
      stationName: data['stationName'] as String? ?? '',
      licenseNumber: data['licenseNumber'] as String? ?? '',
      address: data['address'] as String? ?? '',
      latitude: (data['latitude'] as num?)?.toDouble(),
      longitude: (data['longitude'] as num?)?.toDouble(),
      callSign: data['callSign'] as String?,
      gain: data['gain'] as String?,
      antennaCount: data['antennaCount'] as String?,
      remarks: data['remarks'] as String?,
      typeApprovalNumber: data['typeApprovalNumber'] as String?,
      frequency: data['frequency'] as String?,
      stationType: data['stationType'] as String?,
      owner: data['stationOwner'] as String?,
      installationType: installationType,
      originalInstallationType: installationType,
      isInspected: data['isInspected'] as bool? ?? false,
      inspectionDate: data['inspectionDate'] != null
          ? DateTime.tryParse(data['inspectionDate'] as String)
          : null,
      memo: data['memo'] as String?,
      photoPaths: (data['photoKeys'] as List?)?.cast<String>(),
      createdAt: data['createdAt'] != null
          ? DateTime.tryParse(data['createdAt'] as String)
          : null,
      updatedAt: data['updatedAt'] != null
          ? DateTime.tryParse(data['updatedAt'] as String)
          : null,
    );
  }

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  // ==================== Tower Classification CRUD ====================

  /// 철탑 분류 결과 생성
  Future<String?> createTowerClassification({
    required String imageKey,
    required String imageName,
    required String className,
    required String classNameKr,
    required double confidence,
    required bool isConfident,
    String? top5Predictions,
    String? ensembleMethod,
    List<String>? ensembleImageKeys,
    double? processingTimeMs,
  }) async {
    // 현재 EC2 API에는 classifications 엔드포인트가 없음
    // 필요 시 추후 구현
    debugPrint('createTowerClassification: 현재 미구현 (EC2 API 추가 필요)');
    return null;
  }

  /// 철탑 분류 결과 목록 조회 (최신순)
  Future<List<Map<String, dynamic>>> listTowerClassifications({int limit = 50}) async {
    // 현재 EC2 API에는 classifications 엔드포인트가 없음
    debugPrint('listTowerClassifications: 현재 미구현 (EC2 API 추가 필요)');
    return [];
  }

  /// 철탑 분류 결과 삭제
  Future<bool> deleteTowerClassification(String id) async {
    // 현재 EC2 API에는 classifications 엔드포인트가 없음
    debugPrint('deleteTowerClassification: 현재 미구현 (EC2 API 추가 필요)');
    return false;
  }

  // ==================== 원본 Excel 관리 (EC2 경유 S3) ====================

  /// 원본 Excel 파일을 S3에 업로드 (EC2 경유)
  Future<String?> uploadOriginalExcel(Uint8List bytes, String categoryName, {String? userId}) async {
    try {
      final userPrefix = userId ?? _userId ?? 'unknown';

      // multipart/form-data로 파일 업로드
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/upload/excel'),
      );

      request.fields['owner'] = userPrefix;
      request.fields['categoryName'] = categoryName;
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: '$categoryName.xlsx',
        ),
      );

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final key = data['key'] as String;
          debugPrint('원본 Excel 업로드 완료: $key');
          return key;
        }
      }

      debugPrint('원본 Excel 업로드 실패: ${response.body}');
      return null;
    } catch (e) {
      debugPrint('원본 Excel 업로드 실패: $e');
      return null;
    }
  }

  /// S3에서 원본 Excel 파일 다운로드 (Presigned URL 경유)
  Future<Uint8List?> downloadOriginalExcel(String storedPath) async {
    try {
      // Presigned URL 획득
      final presignedResponse = await http.get(
        Uri.parse('$_baseUrl/download/presigned?key=${Uri.encodeComponent(storedPath)}'),
        headers: _headers,
      );

      if (presignedResponse.statusCode != 200) {
        debugPrint('Presigned URL 획득 실패: ${presignedResponse.body}');
        return null;
      }

      final presignedData = jsonDecode(presignedResponse.body);
      if (presignedData['success'] != true) {
        return null;
      }

      final presignedUrl = presignedData['url'] as String;

      // S3에서 직접 다운로드
      final downloadResponse = await http.get(Uri.parse(presignedUrl));

      if (downloadResponse.statusCode == 200) {
        debugPrint('원본 Excel 다운로드 완료: ${downloadResponse.bodyBytes.length} bytes');
        return downloadResponse.bodyBytes;
      }

      debugPrint('원본 Excel 다운로드 실패: ${downloadResponse.statusCode}');
      return null;
    } catch (e) {
      debugPrint('원본 Excel 다운로드 실패: $e');
      return null;
    }
  }

  /// S3에서 원본 Excel 파일 삭제
  Future<bool> deleteOriginalExcel(String storedPath) async {
    try {
      debugPrint('원본 Excel S3 삭제 시작: $storedPath');

      final response = await http.delete(
        Uri.parse('$_baseUrl/storage/${Uri.encodeComponent(storedPath)}'),
        headers: _headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          debugPrint('원본 Excel S3 삭제 완료: $storedPath');
          return true;
        }
      }

      debugPrint('원본 Excel S3 삭제 실패: ${response.body}');
      return false;
    } catch (e) {
      debugPrint('원본 Excel S3 삭제 실패: $e');
      return false;
    }
  }

  /// 카테고리의 originalExcelKey 업데이트
  Future<bool> updateCategoryOriginalExcelKey(String categoryId, String originalExcelKey) async {
    try {
      final response = await http.put(
        Uri.parse('$_baseUrl/categories/$categoryId?originalExcelKey=${Uri.encodeComponent(originalExcelKey)}'),
        headers: _headers,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          debugPrint('카테고리 originalExcelKey 업데이트 완료');
          return true;
        }
      }

      debugPrint('카테고리 originalExcelKey 업데이트 실패: ${response.body}');
      return false;
    } catch (e) {
      debugPrint('카테고리 originalExcelKey 업데이트 실패: $e');
      return false;
    }
  }
}
