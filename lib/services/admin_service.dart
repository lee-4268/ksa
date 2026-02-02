import 'dart:convert';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:flutter/foundation.dart';
import 'team_context_service.dart';
import 'audit_service.dart';

/// 관리자 서비스 - 사용자 승인, 팀 관리 등
class AdminService extends ChangeNotifier {
  final AuditService _auditService;

  List<AppUserProfile> _pendingUsers = [];
  List<AppUserProfile> _allUsers = [];
  bool _isLoading = false;
  String? _errorMessage;

  AdminService(this._auditService);

  // Getters
  List<AppUserProfile> get pendingUsers => _pendingUsers;
  List<AppUserProfile> get allUsers => _allUsers;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  int get pendingCount => _pendingUsers.length;

  /// 승인 대기 중인 사용자 목록 조회
  Future<void> loadPendingUsers() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    const query = '''
      query ListPendingUsers {
        listUserProfiles(filter: { status: { eq: PENDING } }, limit: 100) {
          items {
            id
            cognitoUserId
            email
            name
            phoneNumber
            teamId
            divisionId
            status
            role
            createdAt
          }
        }
      }
    ''';

    try {
      final request = GraphQLRequest<String>(
        document: query,
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.query(request: request).response;

      if (response.errors.isNotEmpty) {
        _errorMessage = '목록 로드 실패: ${response.errors.first.message}';
        _isLoading = false;
        notifyListeners();
        return;
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      final items = data['listUserProfiles']['items'] as List<dynamic>;

      // null 필터링 및 중복 제거 (cognitoUserId 기준)
      final seen = <String>{};
      _pendingUsers = items
          .where((item) => item != null)
          .map((item) => AppUserProfile.fromJson(item as Map<String, dynamic>))
          .where((user) {
            if (seen.contains(user.cognitoUserId)) {
              return false;
            }
            seen.add(user.cognitoUserId);
            return true;
          })
          .toList();

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _errorMessage = '목록 로드 오류: $e';
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 모든 사용자 목록 조회
  Future<void> loadAllUsers() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    const query = '''
      query ListAllUsers {
        listUserProfiles(limit: 500) {
          items {
            id
            cognitoUserId
            email
            name
            phoneNumber
            teamId
            divisionId
            status
            role
            approvedBy
            approvedAt
            createdAt
            team {
              id
              name
              division {
                id
                name
              }
            }
          }
        }
      }
    ''';

    try {
      final request = GraphQLRequest<String>(
        document: query,
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.query(request: request).response;

      if (response.errors.isNotEmpty) {
        _errorMessage = '목록 로드 실패: ${response.errors.first.message}';
        _isLoading = false;
        notifyListeners();
        return;
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      final items = data['listUserProfiles']['items'] as List<dynamic>;

      // null 필터링 및 중복 제거 (cognitoUserId 기준)
      final seen = <String>{};
      _allUsers = items
          .where((item) => item != null)
          .map((item) => AppUserProfile.fromJson(item as Map<String, dynamic>))
          .where((user) {
            if (seen.contains(user.cognitoUserId)) {
              return false;
            }
            seen.add(user.cognitoUserId);
            return true;
          })
          .toList();

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _errorMessage = '목록 로드 오류: $e';
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 사용자 승인 (단순화된 구조 - 그룹 필드 없음, divisionId/teamId로 앱 레벨 권한 관리)
  Future<bool> approveUser({
    required String profileId,
    required String teamId,
    required String divisionId,
    required String approverUserId,
    UserRole role = UserRole.member,
  }) async {
    const mutation = '''
      mutation ApproveUser(\$input: UpdateUserProfileInput!) {
        updateUserProfile(input: \$input) {
          id
          status
          role
          teamId
          divisionId
          approvedBy
          approvedAt
        }
      }
    ''';

    final input = {
      'id': profileId,
      'status': 'APPROVED',
      'role': role.name.toUpperCase().replaceAllMapped(
            RegExp(r'([a-z])([A-Z])'),
            (m) => '${m[1]}_${m[2]}',
          ),
      'teamId': teamId,
      'divisionId': divisionId,
      'approvedBy': approverUserId,
      'approvedAt': DateTime.now().toUtc().toIso8601String(),
    };

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {'input': input},
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        _errorMessage = '승인 실패: ${response.errors.first.message}';
        notifyListeners();
        return false;
      }

      // 감사 로그 기록
      await _auditService.log(
        action: AuditAction.approve,
        entityType: 'UserProfile',
        entityId: profileId,
        newData: {
          'status': 'APPROVED',
          'teamId': teamId,
          'role': role.name,
        },
      );

      // 목록 새로고침
      await loadPendingUsers();

      return true;
    } catch (e) {
      _errorMessage = '승인 오류: $e';
      notifyListeners();
      return false;
    }
  }

  /// 사용자 거부
  Future<bool> rejectUser({
    required String profileId,
    required String reason,
  }) async {
    const mutation = '''
      mutation RejectUser(\$input: UpdateUserProfileInput!) {
        updateUserProfile(input: \$input) {
          id
          status
          rejectionReason
        }
      }
    ''';

    final input = {
      'id': profileId,
      'status': 'REJECTED',
      'rejectionReason': reason,
    };

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {'input': input},
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        _errorMessage = '거부 실패: ${response.errors.first.message}';
        notifyListeners();
        return false;
      }

      // 감사 로그 기록
      await _auditService.log(
        action: AuditAction.reject,
        entityType: 'UserProfile',
        entityId: profileId,
        newData: {
          'status': 'REJECTED',
          'rejectionReason': reason,
        },
      );

      // 목록 새로고침
      await loadPendingUsers();

      return true;
    } catch (e) {
      _errorMessage = '거부 오류: $e';
      notifyListeners();
      return false;
    }
  }

  /// 사용자 정지
  Future<bool> suspendUser(String profileId, String reason) async {
    // 기존 데이터 조회
    final previousData = await _getUserProfile(profileId);

    const mutation = '''
      mutation SuspendUser(\$input: UpdateUserProfileInput!) {
        updateUserProfile(input: \$input) {
          id
          status
        }
      }
    ''';

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': {
            'id': profileId,
            'status': 'SUSPENDED',
          }
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        _errorMessage = '정지 실패: ${response.errors.first.message}';
        notifyListeners();
        return false;
      }

      // 감사 로그 기록
      await _auditService.log(
        action: AuditAction.suspend,
        entityType: 'UserProfile',
        entityId: profileId,
        previousData: previousData,
        newData: {'status': 'SUSPENDED'},
      );

      await loadAllUsers();
      return true;
    } catch (e) {
      _errorMessage = '정지 오류: $e';
      notifyListeners();
      return false;
    }
  }

  /// 사용자 복원 (정지 해제)
  Future<bool> restoreUser(String profileId) async {
    const mutation = '''
      mutation RestoreUser(\$input: UpdateUserProfileInput!) {
        updateUserProfile(input: \$input) {
          id
          status
        }
      }
    ''';

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': {
            'id': profileId,
            'status': 'APPROVED',
          }
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        _errorMessage = '복원 실패: ${response.errors.first.message}';
        notifyListeners();
        return false;
      }

      // 감사 로그 기록
      await _auditService.log(
        action: AuditAction.restore,
        entityType: 'UserProfile',
        entityId: profileId,
        newData: {'status': 'APPROVED'},
      );

      await loadAllUsers();
      return true;
    } catch (e) {
      _errorMessage = '복원 오류: $e';
      notifyListeners();
      return false;
    }
  }

  /// 사용자 역할 변경
  Future<bool> changeUserRole(String profileId, UserRole newRole) async {
    final previousData = await _getUserProfile(profileId);

    const mutation = '''
      mutation ChangeUserRole(\$input: UpdateUserProfileInput!) {
        updateUserProfile(input: \$input) {
          id
          role
        }
      }
    ''';

    final roleString = newRole.name.toUpperCase().replaceAllMapped(
          RegExp(r'([a-z])([A-Z])'),
          (m) => '${m[1]}_${m[2]}',
        );

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': {
            'id': profileId,
            'role': roleString,
          }
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        _errorMessage = '역할 변경 실패: ${response.errors.first.message}';
        notifyListeners();
        return false;
      }

      // 감사 로그 기록
      await _auditService.log(
        action: AuditAction.update,
        entityType: 'UserProfile',
        entityId: profileId,
        previousData: previousData,
        newData: {'role': roleString},
        changedFields: ['role'],
      );

      await loadAllUsers();
      return true;
    } catch (e) {
      _errorMessage = '역할 변경 오류: $e';
      notifyListeners();
      return false;
    }
  }

  /// 본부 생성 (단순화된 구조 - 그룹 필드 없음)
  Future<String?> createDivision({
    required String name,
    required String code,
    String? description,
  }) async {
    const mutation = '''
      mutation CreateDivision(\$input: CreateDivisionInput!) {
        createDivision(input: \$input) {
          id
          name
          code
        }
      }
    ''';

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': {
            'name': name,
            'code': code,
            'description': description,
          }
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        _errorMessage = '본부 생성 실패: ${response.errors.first.message}';
        notifyListeners();
        return null;
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      final divisionId = data['createDivision']['id'] as String;

      // 감사 로그 기록
      await _auditService.log(
        action: AuditAction.create,
        entityType: 'Division',
        entityId: divisionId,
        newData: {'name': name, 'code': code},
      );

      return divisionId;
    } catch (e) {
      _errorMessage = '본부 생성 오류: $e';
      notifyListeners();
      return null;
    }
  }

  /// 팀 생성 (단순화된 구조 - 그룹 필드 없음)
  Future<String?> createTeam({
    required String divisionId,
    required String name,
    required String code,
    String? description,
  }) async {
    const mutation = '''
      mutation CreateTeam(\$input: CreateTeamInput!) {
        createTeam(input: \$input) {
          id
          name
          code
        }
      }
    ''';

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': {
            'divisionId': divisionId,
            'name': name,
            'code': code,
            'description': description,
          }
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        _errorMessage = '팀 생성 실패: ${response.errors.first.message}';
        notifyListeners();
        return null;
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      final teamId = data['createTeam']['id'] as String;

      // 감사 로그 기록
      await _auditService.log(
        action: AuditAction.create,
        entityType: 'Team',
        entityId: teamId,
        newData: {'name': name, 'code': code, 'divisionId': divisionId},
      );

      return teamId;
    } catch (e) {
      _errorMessage = '팀 생성 오류: $e';
      notifyListeners();
      return null;
    }
  }

  /// 팀 정보 조회
  Future<Team?> _getTeam(String teamId) async {
    const query = '''
      query GetTeam(\$id: ID!) {
        getTeam(id: \$id) {
          id
          divisionId
          name
          code
          description
        }
      }
    ''';

    try {
      final request = GraphQLRequest<String>(
        document: query,
        variables: {'id': teamId},
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.query(request: request).response;

      if (response.errors.isNotEmpty || response.data == null) {
        return null;
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      final teamData = data['getTeam'] as Map<String, dynamic>?;

      if (teamData == null) return null;

      return Team.fromJson(teamData);
    } catch (e) {
      debugPrint('팀 조회 오류: $e');
      return null;
    }
  }

  /// 사용자 프로필 조회
  Future<Map<String, dynamic>?> _getUserProfile(String profileId) async {
    const query = '''
      query GetUserProfile(\$id: ID!) {
        getUserProfile(id: \$id) {
          id
          status
          role
          teamId
          divisionId
        }
      }
    ''';

    try {
      final request = GraphQLRequest<String>(
        document: query,
        variables: {'id': profileId},
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.query(request: request).response;

      if (response.errors.isNotEmpty || response.data == null) {
        return null;
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      return data['getUserProfile'] as Map<String, dynamic>?;
    } catch (e) {
      debugPrint('프로필 조회 오류: $e');
      return null;
    }
  }

  /// 팀 삭제
  Future<bool> deleteTeam(String teamId) async {
    const mutation = '''
      mutation DeleteTeam(\$input: DeleteTeamInput!) {
        deleteTeam(input: \$input) {
          id
        }
      }
    ''';

    try {
      // 팀 정보 조회 (감사 로그용)
      final team = await _getTeam(teamId);

      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': {'id': teamId}
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        _errorMessage = '팀 삭제 실패: ${response.errors.first.message}';
        notifyListeners();
        return false;
      }

      // 감사 로그 기록
      await _auditService.log(
        action: AuditAction.delete,
        entityType: 'Team',
        entityId: teamId,
        previousData: team != null
            ? {'name': team.name, 'code': team.code}
            : null,
      );

      return true;
    } catch (e) {
      _errorMessage = '팀 삭제 오류: $e';
      notifyListeners();
      return false;
    }
  }

  /// 본부 삭제
  Future<bool> deleteDivision(String divisionId) async {
    const mutation = '''
      mutation DeleteDivision(\$input: DeleteDivisionInput!) {
        deleteDivision(input: \$input) {
          id
        }
      }
    ''';

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {
          'input': {'id': divisionId}
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        _errorMessage = '본부 삭제 실패: ${response.errors.first.message}';
        notifyListeners();
        return false;
      }

      // 감사 로그 기록
      await _auditService.log(
        action: AuditAction.delete,
        entityType: 'Division',
        entityId: divisionId,
      );

      return true;
    } catch (e) {
      _errorMessage = '본부 삭제 오류: $e';
      notifyListeners();
      return false;
    }
  }

  /// 에러 메시지 클리어
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// PENDING 사용자 일괄 자동 승인 (Cognito 그룹 기반)
  /// 이미 Cognito 그룹에 있는 사용자들의 DB 상태를 APPROVED로 업데이트
  /// @param currentUserId 현재 로그인한 사용자의 Cognito ID (자신의 계정 우선 처리)
  /// @param teamId 기본 배정할 팀 ID (선택사항)
  /// @param divisionId 기본 배정할 본부 ID (선택사항)
  Future<int> autoApprovePendingUsers({
    required String currentUserId,
    String? teamId,
    String? divisionId,
  }) async {
    int approvedCount = 0;

    // 1. 현재 사용자의 프로필 찾기 및 우선 처리
    for (final user in _pendingUsers) {
      if (user.cognitoUserId == currentUserId) {
        final success = await _forceApproveUser(
          profileId: user.id,
          teamId: teamId ?? user.teamId,
          divisionId: divisionId ?? user.divisionId,
        );
        if (success) {
          approvedCount++;
          debugPrint('현재 사용자 자동 승인 완료: ${user.email}');
        }
        break;
      }
    }

    // 목록 새로고침
    await loadPendingUsers();

    return approvedCount;
  }

  /// 사용자 강제 승인 (관리자 권한으로 DB 직접 업데이트)
  Future<bool> _forceApproveUser({
    required String profileId,
    String? teamId,
    String? divisionId,
  }) async {
    const mutation = '''
      mutation ForceApproveUser(\$input: UpdateUserProfileInput!) {
        updateUserProfile(input: \$input) {
          id
          status
        }
      }
    ''';

    final input = <String, dynamic>{
      'id': profileId,
      'status': 'APPROVED',
      'approvedBy': 'AUTO_MIGRATION',
      'approvedAt': DateTime.now().toUtc().toIso8601String(),
    };

    if (teamId != null) input['teamId'] = teamId;
    if (divisionId != null) input['divisionId'] = divisionId;

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {'input': input},
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        debugPrint('강제 승인 실패: ${response.errors.first.message}');
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('강제 승인 오류: $e');
      return false;
    }
  }

  /// 특정 사용자 목록 일괄 승인
  Future<int> batchApproveUsers({
    required List<String> profileIds,
    required String teamId,
    required String divisionId,
    required String approverUserId,
  }) async {
    int successCount = 0;

    for (final profileId in profileIds) {
      final success = await approveUser(
        profileId: profileId,
        teamId: teamId,
        divisionId: divisionId,
        approverUserId: approverUserId,
      );
      if (success) successCount++;
    }

    return successCount;
  }
}
