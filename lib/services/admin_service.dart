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

      _pendingUsers = items
          .map((item) => AppUserProfile.fromJson(item as Map<String, dynamic>))
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

      _allUsers = items
          .map((item) => AppUserProfile.fromJson(item as Map<String, dynamic>))
          .toList();

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _errorMessage = '목록 로드 오류: $e';
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 사용자 승인
  Future<bool> approveUser({
    required String profileId,
    required String teamId,
    required String divisionId,
    required String approverUserId,
    UserRole role = UserRole.member,
  }) async {
    // 팀 정보 조회 (그룹명 가져오기)
    final team = await _getTeam(teamId);
    if (team == null) {
      _errorMessage = '팀 정보를 찾을 수 없습니다';
      notifyListeners();
      return false;
    }

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
          teamAdminGroup
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
      'teamAdminGroup': team.adminGroup,
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

  /// 부서 생성
  Future<String?> createDivision({
    required String name,
    required String code,
    String? description,
  }) async {
    final adminGroup = 'Division_${code}_Admin';
    final memberGroup = 'Division_${code}_Member';

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
            'adminGroup': adminGroup,
            'memberGroup': memberGroup,
          }
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        _errorMessage = '부서 생성 실패: ${response.errors.first.message}';
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
      _errorMessage = '부서 생성 오류: $e';
      notifyListeners();
      return null;
    }
  }

  /// 팀 생성
  Future<String?> createTeam({
    required String divisionId,
    required String divisionCode,
    required String name,
    required String code,
    String? description,
  }) async {
    final divisionAdminGroup = 'Division_${divisionCode}_Admin';
    final adminGroup = 'Team_${divisionCode}_${code}_Admin';
    final memberGroup = 'Team_${divisionCode}_${code}_Member';

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
            'divisionAdminGroup': divisionAdminGroup,
            'adminGroup': adminGroup,
            'memberGroup': memberGroup,
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
          adminGroup
          memberGroup
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

  /// 에러 메시지 클리어
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
