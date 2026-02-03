import 'dart:convert';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:flutter/foundation.dart';

/// 감사 로그 액션 타입
enum AuditAction {
  create,
  update,
  delete,
  approve,
  reject,
  suspend,
  restore,
  rollback,
  login,
  logout,
}

/// 감사 로그 모델
class AuditLogEntry {
  final String id;
  final AuditAction action;
  final String entityType;
  final String entityId;
  final String userId;
  final String? userEmail;
  final String? userName;
  final String? userTeamId;
  final String? userTeamName;
  final DateTime timestamp;
  final Map<String, dynamic>? previousData;
  final Map<String, dynamic>? newData;
  final List<String>? changedFields;
  final bool canRollback;
  final DateTime? rolledBackAt;
  final String? rolledBackBy;

  AuditLogEntry({
    required this.id,
    required this.action,
    required this.entityType,
    required this.entityId,
    required this.userId,
    this.userEmail,
    this.userName,
    this.userTeamId,
    this.userTeamName,
    required this.timestamp,
    this.previousData,
    this.newData,
    this.changedFields,
    this.canRollback = true,
    this.rolledBackAt,
    this.rolledBackBy,
  });

  factory AuditLogEntry.fromJson(Map<String, dynamic> json) {
    return AuditLogEntry(
      id: json['id'] as String,
      action: AuditAction.values.firstWhere(
        (a) => a.name.toUpperCase() == json['action'],
        orElse: () => AuditAction.update,
      ),
      entityType: json['entityType'] as String,
      entityId: json['entityId'] as String,
      userId: json['userId'] as String,
      userEmail: json['userEmail'] as String?,
      userName: json['userName'] as String?,
      userTeamId: json['userTeamId'] as String?,
      userTeamName: json['userTeamName'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
      previousData: json['previousData'] != null
          ? jsonDecode(json['previousData'] as String) as Map<String, dynamic>
          : null,
      newData: json['newData'] != null
          ? jsonDecode(json['newData'] as String) as Map<String, dynamic>
          : null,
      changedFields: (json['changedFields'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      canRollback: json['canRollback'] as bool? ?? true,
      rolledBackAt: json['rolledBackAt'] != null
          ? DateTime.parse(json['rolledBackAt'] as String)
          : null,
      rolledBackBy: json['rolledBackBy'] as String?,
    );
  }
}

/// 감사 로그 서비스
class AuditService extends ChangeNotifier {
  String? _currentUserId;
  String? _currentUserEmail;
  String? _currentUserName;
  String? _currentTeamId;
  String? _currentTeamName;

  /// 현재 사용자 컨텍스트 설정
  void setUserContext({
    required String userId,
    String? email,
    String? name,
    String? teamId,
    String? teamName,
  }) {
    _currentUserId = userId;
    _currentUserEmail = email;
    _currentUserName = name;
    _currentTeamId = teamId;
    _currentTeamName = teamName;
  }

  /// 감사 로그 기록
  Future<bool> log({
    required AuditAction action,
    required String entityType,
    required String entityId,
    Map<String, dynamic>? previousData,
    Map<String, dynamic>? newData,
    List<String>? changedFields,
    bool canRollback = true,
  }) async {
    if (_currentUserId == null) {
      debugPrint('AuditService: 사용자 컨텍스트가 설정되지 않음');
      return false;
    }

    const mutation = '''
      mutation CreateAuditLog(\$input: CreateAuditLogInput!) {
        createAuditLog(input: \$input) {
          id
        }
      }
    ''';

    final input = <String, dynamic>{
      'action': action.name.toUpperCase(),
      'entityType': entityType,
      'entityId': entityId,
      'userId': _currentUserId,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'canRollback': canRollback,
    };

    if (_currentUserEmail != null) input['userEmail'] = _currentUserEmail;
    if (_currentUserName != null) input['userName'] = _currentUserName;
    if (_currentTeamId != null) input['userTeamId'] = _currentTeamId;
    if (_currentTeamName != null) input['userTeamName'] = _currentTeamName;
    if (previousData != null) input['previousData'] = jsonEncode(previousData);
    if (newData != null) input['newData'] = jsonEncode(newData);
    if (changedFields != null) input['changedFields'] = changedFields;

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {'input': input},
        authorizationMode: APIAuthorizationType.apiKey,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        debugPrint('AuditService 오류: ${response.errors}');
        return false;
      }

      debugPrint('AuditService: 로그 기록 완료 - $action on $entityType:$entityId');
      return true;
    } catch (e) {
      debugPrint('AuditService 예외: $e');
      return false;
    }
  }

  /// 로그인 이벤트 기록
  Future<bool> logLogin(String userId, String? email) async {
    _currentUserId = userId;
    _currentUserEmail = email;

    return log(
      action: AuditAction.login,
      entityType: 'User',
      entityId: userId,
      canRollback: false,
    );
  }

  /// 로그아웃 이벤트 기록
  Future<bool> logLogout() async {
    if (_currentUserId == null) return false;

    final result = await log(
      action: AuditAction.logout,
      entityType: 'User',
      entityId: _currentUserId!,
      canRollback: false,
    );

    // 컨텍스트 클리어
    _currentUserId = null;
    _currentUserEmail = null;
    _currentUserName = null;
    _currentTeamId = null;
    _currentTeamName = null;

    return result;
  }

  /// 변경된 필드 감지
  static List<String> detectChangedFields(
    Map<String, dynamic> previous,
    Map<String, dynamic> current,
  ) {
    final changedFields = <String>[];
    final allKeys = {...previous.keys, ...current.keys};

    for (final key in allKeys) {
      final prevValue = previous[key];
      final currValue = current[key];

      if (prevValue != currValue) {
        changedFields.add(key);
      }
    }

    return changedFields;
  }

  /// 감사 로그 조회 (관리자용)
  Future<List<AuditLogEntry>> listAuditLogs({
    String? entityType,
    String? entityId,
    String? userId,
    AuditAction? action,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 50,
  }) async {
    const query = '''
      query ListAuditLogs(\$filter: ModelAuditLogFilterInput, \$limit: Int, \$nextToken: String) {
        listAuditLogs(filter: \$filter, limit: \$limit, nextToken: \$nextToken) {
          items {
            id
            action
            entityType
            entityId
            userId
            userEmail
            userName
            userTeamId
            userTeamName
            timestamp
            previousData
            newData
            changedFields
            canRollback
            rolledBackAt
            rolledBackBy
          }
          nextToken
        }
      }
    ''';

    final filter = <String, dynamic>{};

    if (entityType != null) {
      filter['entityType'] = {'eq': entityType};
    }
    if (entityId != null) {
      filter['entityId'] = {'eq': entityId};
    }
    if (userId != null) {
      filter['userId'] = {'eq': userId};
    }
    if (action != null) {
      filter['action'] = {'eq': action.name.toUpperCase()};
    }
    if (startDate != null || endDate != null) {
      final timestampFilter = <String, dynamic>{};
      if (startDate != null) {
        timestampFilter['ge'] = startDate.toUtc().toIso8601String();
      }
      if (endDate != null) {
        timestampFilter['le'] = endDate.toUtc().toIso8601String();
      }
      filter['timestamp'] = timestampFilter;
    }

    try {
      final request = GraphQLRequest<String>(
        document: query,
        variables: {
          if (filter.isNotEmpty) 'filter': filter,
          'limit': limit,
        },
        authorizationMode: APIAuthorizationType.apiKey,
      );

      final response = await Amplify.API.query(request: request).response;

      if (response.errors.isNotEmpty) {
        debugPrint('AuditService 조회 오류: ${response.errors}');
        return [];
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      final items = data['listAuditLogs']['items'] as List<dynamic>;

      return items
          .map((item) => AuditLogEntry.fromJson(item as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    } catch (e) {
      debugPrint('AuditService 조회 예외: $e');
      return [];
    }
  }

  /// 특정 엔티티의 변경 이력 조회
  Future<List<AuditLogEntry>> getEntityHistory(
    String entityType,
    String entityId,
  ) async {
    return listAuditLogs(
      entityType: entityType,
      entityId: entityId,
      limit: 100,
    );
  }

  /// 롤백 수행
  Future<bool> rollback(String auditLogId) async {
    // 1. 감사 로그 조회
    const getQuery = '''
      query GetAuditLog(\$id: ID!) {
        getAuditLog(id: \$id) {
          id
          action
          entityType
          entityId
          previousData
          newData
          canRollback
          rolledBackAt
        }
      }
    ''';

    try {
      final getRequest = GraphQLRequest<String>(
        document: getQuery,
        variables: {'id': auditLogId},
        authorizationMode: APIAuthorizationType.apiKey,
      );

      final getResponse = await Amplify.API.query(request: getRequest).response;

      if (getResponse.errors.isNotEmpty || getResponse.data == null) {
        debugPrint('롤백 대상 조회 실패');
        return false;
      }

      final logData = jsonDecode(getResponse.data!) as Map<String, dynamic>;
      final auditLog = logData['getAuditLog'] as Map<String, dynamic>?;

      if (auditLog == null) {
        debugPrint('감사 로그를 찾을 수 없음');
        return false;
      }

      if (auditLog['canRollback'] != true) {
        debugPrint('롤백 불가능한 로그');
        return false;
      }

      if (auditLog['rolledBackAt'] != null) {
        debugPrint('이미 롤백된 로그');
        return false;
      }

      final entityType = auditLog['entityType'] as String;
      final entityId = auditLog['entityId'] as String;
      final previousDataStr = auditLog['previousData'] as String?;

      if (previousDataStr == null) {
        debugPrint('이전 데이터 없음 - 롤백 불가');
        return false;
      }

      final previousData =
          jsonDecode(previousDataStr) as Map<String, dynamic>;

      // 2. 엔티티 타입에 따라 롤백 수행
      bool rollbackSuccess = false;
      switch (entityType) {
        case 'TeamInspectionData':
          rollbackSuccess =
              await _rollbackTeamInspectionData(entityId, previousData);
          break;
        case 'MasterStation':
          rollbackSuccess = await _rollbackMasterStation(entityId, previousData);
          break;
        case 'UserProfile':
          rollbackSuccess = await _rollbackUserProfile(entityId, previousData);
          break;
        default:
          debugPrint('지원되지 않는 엔티티 타입: $entityType');
          return false;
      }

      if (!rollbackSuccess) return false;

      // 3. 원본 로그의 롤백 상태 업데이트
      const updateMutation = '''
        mutation UpdateAuditLog(\$input: UpdateAuditLogInput!) {
          updateAuditLog(input: \$input) {
            id
          }
        }
      ''';

      final updateRequest = GraphQLRequest<String>(
        document: updateMutation,
        variables: {
          'input': {
            'id': auditLogId,
            'rolledBackAt': DateTime.now().toUtc().toIso8601String(),
            'rolledBackBy': _currentUserId,
            'canRollback': false,
          }
        },
        authorizationMode: APIAuthorizationType.apiKey,
      );

      await Amplify.API.mutate(request: updateRequest).response;

      // 4. 롤백 감사 로그 기록
      await log(
        action: AuditAction.rollback,
        entityType: entityType,
        entityId: entityId,
        previousData: auditLog['newData'] != null
            ? jsonDecode(auditLog['newData'] as String)
            : null,
        newData: previousData,
        canRollback: false,
      );

      return true;
    } catch (e) {
      debugPrint('롤백 예외: $e');
      return false;
    }
  }

  Future<bool> _rollbackTeamInspectionData(
    String entityId,
    Map<String, dynamic> previousData,
  ) async {
    const mutation = '''
      mutation UpdateTeamInspectionData(\$input: UpdateTeamInspectionDataInput!) {
        updateTeamInspectionData(input: \$input) {
          id
        }
      }
    ''';

    final input = <String, dynamic>{'id': entityId};

    // 롤백 가능한 필드들만 복원
    final rollbackFields = [
      'isInspected',
      'inspectionDate',
      'scheduledDate',
      'memo',
      'remarks',
      'photoKeys',
    ];

    for (final field in rollbackFields) {
      if (previousData.containsKey(field)) {
        input[field] = previousData[field];
      }
    }

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {'input': input},
        authorizationMode: APIAuthorizationType.apiKey,
      );

      final response = await Amplify.API.mutate(request: request).response;
      return response.errors.isEmpty;
    } catch (e) {
      debugPrint('TeamInspectionData 롤백 실패: $e');
      return false;
    }
  }

  Future<bool> _rollbackMasterStation(
    String entityId,
    Map<String, dynamic> previousData,
  ) async {
    const mutation = '''
      mutation UpdateMasterStation(\$input: UpdateMasterStationInput!) {
        updateMasterStation(input: \$input) {
          id
        }
      }
    ''';

    final input = <String, dynamic>{'id': entityId};

    final rollbackFields = [
      'stationName',
      'address',
      'latitude',
      'longitude',
      'frequency',
      'stationType',
      'stationOwner',
      'installationType',
      'remarks',
    ];

    for (final field in rollbackFields) {
      if (previousData.containsKey(field)) {
        input[field] = previousData[field];
      }
    }

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {'input': input},
        authorizationMode: APIAuthorizationType.apiKey,
      );

      final response = await Amplify.API.mutate(request: request).response;
      return response.errors.isEmpty;
    } catch (e) {
      debugPrint('MasterStation 롤백 실패: $e');
      return false;
    }
  }

  Future<bool> _rollbackUserProfile(
    String entityId,
    Map<String, dynamic> previousData,
  ) async {
    const mutation = '''
      mutation UpdateUserProfile(\$input: UpdateUserProfileInput!) {
        updateUserProfile(input: \$input) {
          id
        }
      }
    ''';

    final input = <String, dynamic>{'id': entityId};

    final rollbackFields = [
      'status',
      'role',
      'teamId',
      'divisionId',
    ];

    for (final field in rollbackFields) {
      if (previousData.containsKey(field)) {
        input[field] = previousData[field];
      }
    }

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {'input': input},
        authorizationMode: APIAuthorizationType.apiKey,
      );

      final response = await Amplify.API.mutate(request: request).response;
      return response.errors.isEmpty;
    } catch (e) {
      debugPrint('UserProfile 롤백 실패: $e');
      return false;
    }
  }
}
