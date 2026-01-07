import 'dart:convert';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:flutter/foundation.dart';
import '../models/radio_station.dart';

/// AWS AppSync GraphQL API를 통한 클라우드 데이터 서비스
class CloudDataService extends ChangeNotifier {
  bool _isLoading = false;
  String? _errorMessage;
  bool _isSyncing = false;

  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isSyncing => _isSyncing;

  // ==================== Category CRUD ====================

  /// 카테고리 생성
  Future<String?> createCategory(String name) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      const mutation = '''
        mutation CreateCategory(\$input: CreateCategoryInput!) {
          createCategory(input: \$input) {
            id
            name
            createdAt
            updatedAt
            owner
          }
        }
      ''';

      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': {
            'name': name,
          },
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.hasErrors) {
        _errorMessage = response.errors.map((e) => e.message).join(', ');
        debugPrint('카테고리 생성 오류: $_errorMessage');
        _isLoading = false;
        notifyListeners();
        return null;
      }

      final data = response.data;
      if (data != null) {
        final jsonData = _parseJson(data);
        final categoryId = jsonData?['createCategory']?['id'] as String?;
        debugPrint('카테고리 생성 완료: $categoryId');
        _isLoading = false;
        notifyListeners();
        return categoryId;
      }

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

  /// 모든 카테고리 조회 (페이지네이션 처리)
  Future<List<Map<String, dynamic>>> listCategories() async {
    try {
      const query = '''
        query ListCategories(\$limit: Int, \$nextToken: String) {
          listCategories(limit: \$limit, nextToken: \$nextToken) {
            items {
              id
              name
              createdAt
              updatedAt
              owner
            }
            nextToken
          }
        }
      ''';

      final allCategories = <Map<String, dynamic>>[];
      String? nextToken;

      // 페이지네이션 처리 - 모든 데이터를 가져올 때까지 반복
      do {
        final request = GraphQLRequest<String>(
          document: query,
          variables: {
            'limit': 1000, // 한 번에 최대 1000개 요청
            if (nextToken != null) 'nextToken': nextToken,
          },
          authorizationMode: APIAuthorizationType.userPools,
        );

        final response = await Amplify.API.query(request: request).response;

        if (response.hasErrors) {
          final errorMsg = response.errors.map((e) => e.message).join(', ');
          debugPrint('카테고리 목록 조회 오류: $errorMsg');
          throw Exception('카테고리 목록 조회 실패: $errorMsg');
        }

        final data = response.data;
        if (data != null) {
          final jsonData = _parseJson(data);
          final listCategories = jsonData?['listCategories'];
          final items = listCategories?['items'] as List?;

          if (items != null && items.isNotEmpty) {
            allCategories.addAll(items.cast<Map<String, dynamic>>());
          }

          // 다음 페이지 토큰
          nextToken = listCategories?['nextToken'] as String?;
        } else {
          break;
        }
      } while (nextToken != null);

      debugPrint('카테고리 ${allCategories.length}개 조회');
      return allCategories;
    } catch (e) {
      debugPrint('카테고리 목록 조회 실패: $e');
      rethrow; // 오류를 상위로 전파하여 fallback 로직이 작동하도록 함
    }
  }

  /// 카테고리 삭제
  Future<bool> deleteCategory(String categoryId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      const mutation = '''
        mutation DeleteCategory(\$input: DeleteCategoryInput!) {
          deleteCategory(input: \$input) {
            id
          }
        }
      ''';

      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': {'id': categoryId},
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      _isLoading = false;
      notifyListeners();

      if (response.hasErrors) {
        _errorMessage = response.errors.map((e) => e.message).join(', ');
        return false;
      }

      return true;
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
      const mutation = '''
        mutation CreateStation(\$input: CreateStationInput!) {
          createStation(input: \$input) {
            id
            categoryId
            stationName
            licenseNumber
            address
            latitude
            longitude
            callSign
            gain
            antennaCount
            remarks
            typeApprovalNumber
            frequency
            stationType
            stationOwner
            isInspected
            inspectionDate
            memo
            photoKeys
            createdAt
            updatedAt
          }
        }
      ''';

      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': {
            'categoryId': categoryId,
            'stationName': station.stationName,
            'licenseNumber': station.licenseNumber,
            'address': station.address,
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
            'isInspected': station.isInspected,
            'inspectionDate': station.inspectionDate?.toUtc().toIso8601String(),
            'memo': station.memo,
            'photoKeys': station.photoPaths,
          },
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.hasErrors) {
        _errorMessage = response.errors.map((e) => e.message).join(', ');
        debugPrint('무선국 생성 오류: $_errorMessage');
        _isLoading = false;
        notifyListeners();
        return null;
      }

      final data = response.data;
      if (data != null) {
        final jsonData = _parseJson(data);
        final stationId = jsonData?['createStation']?['id'] as String?;
        debugPrint('무선국 생성 완료: $stationId');
        _isLoading = false;
        notifyListeners();
        return stationId;
      }

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

  /// 카테고리별 무선국 목록 조회 (페이지네이션 처리)
  Future<List<RadioStation>> listStationsByCategory(String categoryId) async {
    try {
      const query = '''
        query ListStations(\$filter: ModelStationFilterInput, \$limit: Int, \$nextToken: String) {
          listStations(filter: \$filter, limit: \$limit, nextToken: \$nextToken) {
            items {
              id
              categoryId
              stationName
              licenseNumber
              address
              latitude
              longitude
              callSign
              gain
              antennaCount
              remarks
              typeApprovalNumber
              frequency
              stationType
              stationOwner
              isInspected
              inspectionDate
              memo
              photoKeys
              createdAt
              updatedAt
            }
            nextToken
          }
        }
      ''';

      final allStations = <RadioStation>[];
      String? nextToken;

      // 페이지네이션 처리 - 모든 데이터를 가져올 때까지 반복
      do {
        final request = GraphQLRequest<String>(
          document: query,
          variables: {
            'filter': {
              'categoryId': {'eq': categoryId},
            },
            'limit': 1000, // 한 번에 최대 1000개 요청
            if (nextToken != null) 'nextToken': nextToken,
          },
          authorizationMode: APIAuthorizationType.userPools,
        );

        final response = await Amplify.API.query(request: request).response;

        if (response.hasErrors) {
          debugPrint('무선국 목록 조회 오류: ${response.errors}');
          break;
        }

        final data = response.data;
        if (data != null) {
          final jsonData = _parseJson(data);
          final listStations = jsonData?['listStations'];
          final items = listStations?['items'] as List?;

          if (items != null && items.isNotEmpty) {
            allStations.addAll(
              items.map((item) => _mapToRadioStation(item as Map<String, dynamic>))
            );
          }

          // 다음 페이지 토큰
          nextToken = listStations?['nextToken'] as String?;
        } else {
          break;
        }
      } while (nextToken != null);

      debugPrint('카테고리 $categoryId: ${allStations.length}개 스테이션 조회');
      return allStations;
    } catch (e) {
      debugPrint('무선국 목록 조회 실패: $e');
      return [];
    }
  }

  /// 모든 무선국 조회 (페이지네이션 처리)
  Future<List<RadioStation>> listAllStations() async {
    try {
      const query = '''
        query ListStations(\$limit: Int, \$nextToken: String) {
          listStations(limit: \$limit, nextToken: \$nextToken) {
            items {
              id
              categoryId
              stationName
              licenseNumber
              address
              latitude
              longitude
              callSign
              gain
              antennaCount
              remarks
              typeApprovalNumber
              frequency
              stationType
              stationOwner
              isInspected
              inspectionDate
              memo
              photoKeys
              createdAt
              updatedAt
            }
            nextToken
          }
        }
      ''';

      final allStations = <RadioStation>[];
      String? nextToken;

      // 페이지네이션 처리 - 모든 데이터를 가져올 때까지 반복
      do {
        final request = GraphQLRequest<String>(
          document: query,
          variables: {
            'limit': 1000, // 한 번에 최대 1000개 요청
            if (nextToken != null) 'nextToken': nextToken,
          },
          authorizationMode: APIAuthorizationType.userPools,
        );

        final response = await Amplify.API.query(request: request).response;

        if (response.hasErrors) {
          debugPrint('전체 무선국 목록 조회 오류: ${response.errors}');
          break;
        }

        final data = response.data;
        if (data != null) {
          final jsonData = _parseJson(data);
          final listStations = jsonData?['listStations'];
          final items = listStations?['items'] as List?;

          if (items != null && items.isNotEmpty) {
            allStations.addAll(
              items.map((item) => _mapToRadioStation(item as Map<String, dynamic>))
            );
          }

          // 다음 페이지 토큰
          nextToken = listStations?['nextToken'] as String?;
        } else {
          break;
        }
      } while (nextToken != null);

      debugPrint('전체 스테이션 ${allStations.length}개 조회');
      return allStations;
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
      const mutation = '''
        mutation UpdateStation(\$input: UpdateStationInput!) {
          updateStation(input: \$input) {
            id
          }
        }
      ''';

      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': {
            'id': station.id,
            'categoryId': categoryId,
            'stationName': station.stationName,
            'licenseNumber': station.licenseNumber,
            'address': station.address,
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
            'isInspected': station.isInspected,
            'inspectionDate': station.inspectionDate?.toUtc().toIso8601String(),
            'memo': station.memo,
            'photoKeys': station.photoPaths,
          },
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      _isLoading = false;
      notifyListeners();

      if (response.hasErrors) {
        _errorMessage = response.errors.map((e) => e.message).join(', ');
        debugPrint('무선국 업데이트 오류: $_errorMessage');
        return false;
      }

      debugPrint('무선국 업데이트 완료: ${station.id}');
      return true;
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
      const mutation = '''
        mutation DeleteStation(\$input: DeleteStationInput!) {
          deleteStation(input: \$input) {
            id
          }
        }
      ''';

      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': {'id': stationId},
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      _isLoading = false;
      notifyListeners();

      if (response.hasErrors) {
        _errorMessage = response.errors.map((e) => e.message).join(', ');
        return false;
      }

      return true;
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

  Map<String, dynamic>? _parseJson(String data) {
    try {
      if (data.isEmpty || !data.startsWith('{')) {
        return null;
      }
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return Map<String, dynamic>.from(decoded as Map);
    } catch (e) {
      debugPrint('JSON 파싱 오류: $e');
      return null;
    }
  }

  RadioStation _mapToRadioStation(Map<String, dynamic> data) {
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
}
