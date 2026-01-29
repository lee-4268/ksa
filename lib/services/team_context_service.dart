import 'dart:convert';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:flutter/foundation.dart';

/// 사용자 역할
enum UserRole {
  superAdmin,
  divisionAdmin,
  teamAdmin,
  member,
}

/// 사용자 상태
enum UserStatus {
  pending,
  approved,
  rejected,
  suspended,
}

/// 부서 모델
class Division {
  final String id;
  final String name;
  final String code;
  final String? description;
  final String adminGroup;
  final String memberGroup;

  Division({
    required this.id,
    required this.name,
    required this.code,
    this.description,
    required this.adminGroup,
    required this.memberGroup,
  });

  factory Division.fromJson(Map<String, dynamic> json) {
    return Division(
      id: json['id'] as String,
      name: json['name'] as String,
      code: json['code'] as String,
      description: json['description'] as String?,
      adminGroup: json['adminGroup'] as String,
      memberGroup: json['memberGroup'] as String,
    );
  }
}

/// 팀 모델
class Team {
  final String id;
  final String divisionId;
  final String name;
  final String code;
  final String? description;
  final String adminGroup;
  final String memberGroup;
  final Division? division;

  Team({
    required this.id,
    required this.divisionId,
    required this.name,
    required this.code,
    this.description,
    required this.adminGroup,
    required this.memberGroup,
    this.division,
  });

  factory Team.fromJson(Map<String, dynamic> json) {
    return Team(
      id: json['id'] as String,
      divisionId: json['divisionId'] as String,
      name: json['name'] as String,
      code: json['code'] as String,
      description: json['description'] as String?,
      adminGroup: json['adminGroup'] as String,
      memberGroup: json['memberGroup'] as String,
      division: json['division'] != null
          ? Division.fromJson(json['division'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// 사용자 프로필 모델
class AppUserProfile {
  final String id;
  final String cognitoUserId;
  final String email;
  final String? name;
  final String? phoneNumber;
  final String? teamId;
  final String? divisionId;
  final UserStatus status;
  final UserRole role;
  final String? approvedBy;
  final DateTime? approvedAt;
  final String? rejectionReason;
  final Team? team;

  AppUserProfile({
    required this.id,
    required this.cognitoUserId,
    required this.email,
    this.name,
    this.phoneNumber,
    this.teamId,
    this.divisionId,
    required this.status,
    required this.role,
    this.approvedBy,
    this.approvedAt,
    this.rejectionReason,
    this.team,
  });

  factory AppUserProfile.fromJson(Map<String, dynamic> json) {
    return AppUserProfile(
      id: json['id'] as String,
      cognitoUserId: json['cognitoUserId'] as String,
      email: json['email'] as String,
      name: json['name'] as String?,
      phoneNumber: json['phoneNumber'] as String?,
      teamId: json['teamId'] as String?,
      divisionId: json['divisionId'] as String?,
      status: UserStatus.values.firstWhere(
        (s) => s.name.toUpperCase() == json['status'],
        orElse: () => UserStatus.pending,
      ),
      role: UserRole.values.firstWhere(
        (r) => r.name.toUpperCase() == (json['role'] as String?)?.replaceAll('_', ''),
        orElse: () => UserRole.member,
      ),
      approvedBy: json['approvedBy'] as String?,
      approvedAt: json['approvedAt'] != null
          ? DateTime.parse(json['approvedAt'] as String)
          : null,
      rejectionReason: json['rejectionReason'] as String?,
      team: json['team'] != null
          ? Team.fromJson(json['team'] as Map<String, dynamic>)
          : null,
    );
  }

  bool get isPending => status == UserStatus.pending;
  bool get isApproved => status == UserStatus.approved;
  bool get isRejected => status == UserStatus.rejected;
  bool get isSuspended => status == UserStatus.suspended;
}

/// 팀 컨텍스트 서비스 - 현재 사용자의 팀/부서 정보 관리
class TeamContextService extends ChangeNotifier {
  AppUserProfile? _currentProfile;
  Team? _currentTeam;
  Division? _currentDivision;
  List<Team> _availableTeams = [];
  List<Division> _availableDivisions = [];
  bool _isLoading = false;
  String? _errorMessage;

  // Getters
  AppUserProfile? get currentProfile => _currentProfile;
  Team? get currentTeam => _currentTeam;
  Division? get currentDivision => _currentDivision;
  List<Team> get availableTeams => _availableTeams;
  List<Division> get availableDivisions => _availableDivisions;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  String? get currentTeamId => _currentTeam?.id;
  String? get currentTeamName => _currentTeam?.name;
  String? get currentDivisionId => _currentDivision?.id;
  String? get currentDivisionName => _currentDivision?.name;
  String? get currentTeamGroup => _currentTeam?.memberGroup;
  String? get currentDivisionGroup => _currentDivision?.memberGroup;

  UserRole get currentRole => _currentProfile?.role ?? UserRole.member;
  UserStatus get currentStatus => _currentProfile?.status ?? UserStatus.pending;

  bool get isSuperAdmin => currentRole == UserRole.superAdmin;
  bool get isDivisionAdmin => currentRole == UserRole.divisionAdmin || isSuperAdmin;
  bool get isTeamAdmin => currentRole == UserRole.teamAdmin || isDivisionAdmin;
  bool get isAdmin => isTeamAdmin;

  bool get canManageUsers => isDivisionAdmin;
  bool get canManageTeams => isDivisionAdmin;
  bool get canViewAuditLogs => isTeamAdmin;
  bool get canApproveUsers => isTeamAdmin;

  bool get isPending => _currentProfile?.isPending ?? true;
  bool get isApproved => _currentProfile?.isApproved ?? false;

  /// Cognito 사용자 ID로 프로필 로드
  Future<void> loadUserProfile(String cognitoUserId) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    const query = '''
      query GetUserProfile(\$cognitoUserId: String!) {
        userProfileByCognitoId(cognitoUserId: \$cognitoUserId) {
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
            rejectionReason
            team {
              id
              divisionId
              name
              code
              description
              adminGroup
              memberGroup
              division {
                id
                name
                code
                description
                adminGroup
                memberGroup
              }
            }
          }
        }
      }
    ''';

    try {
      final request = GraphQLRequest<String>(
        document: query,
        variables: {'cognitoUserId': cognitoUserId},
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.query(request: request).response;

      if (response.errors.isNotEmpty) {
        _errorMessage = '프로필 로드 실패: ${response.errors.first.message}';
        _isLoading = false;
        notifyListeners();
        return;
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      final items = data['userProfileByCognitoId']['items'] as List<dynamic>;

      if (items.isEmpty) {
        // 프로필이 없으면 새로 생성 필요
        _currentProfile = null;
        _currentTeam = null;
        _currentDivision = null;
      } else {
        final profileData = items.first as Map<String, dynamic>;
        _currentProfile = AppUserProfile.fromJson(profileData);
        _currentTeam = _currentProfile?.team;
        _currentDivision = _currentTeam?.division;
      }

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _errorMessage = '프로필 로드 오류: $e';
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 새 사용자 프로필 생성 (회원가입 시)
  Future<AppUserProfile?> createUserProfile({
    required String cognitoUserId,
    required String email,
    String? name,
    String? phoneNumber,
  }) async {
    const mutation = '''
      mutation CreateUserProfile(\$input: CreateUserProfileInput!) {
        createUserProfile(input: \$input) {
          id
          cognitoUserId
          email
          name
          phoneNumber
          status
          role
          createdAt
        }
      }
    ''';

    final input = <String, dynamic>{
      'cognitoUserId': cognitoUserId,
      'email': email,
      'status': 'PENDING',
      'role': 'MEMBER',
    };

    if (name != null) input['name'] = name;
    if (phoneNumber != null) input['phoneNumber'] = phoneNumber;

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {'input': input},
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        debugPrint('프로필 생성 실패: ${response.errors}');
        return null;
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      final profileData = data['createUserProfile'] as Map<String, dynamic>;

      _currentProfile = AppUserProfile.fromJson(profileData);
      notifyListeners();

      return _currentProfile;
    } catch (e) {
      debugPrint('프로필 생성 오류: $e');
      return null;
    }
  }

  /// 모든 부서 목록 조회 (관리자용)
  Future<void> loadDivisions() async {
    const query = '''
      query ListDivisions {
        listDivisions(limit: 100) {
          items {
            id
            name
            code
            description
            adminGroup
            memberGroup
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
        debugPrint('부서 목록 로드 실패: ${response.errors}');
        return;
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      final items = data['listDivisions']['items'] as List<dynamic>;

      _availableDivisions = items
          .map((item) => Division.fromJson(item as Map<String, dynamic>))
          .toList();

      notifyListeners();
    } catch (e) {
      debugPrint('부서 목록 로드 오류: $e');
    }
  }

  /// 특정 부서의 팀 목록 조회
  Future<void> loadTeamsByDivision(String divisionId) async {
    const query = '''
      query ListTeamsByDivision(\$divisionId: ID!) {
        teamsByDivisionIdAndName(divisionId: \$divisionId, limit: 100) {
          items {
            id
            divisionId
            name
            code
            description
            adminGroup
            memberGroup
          }
        }
      }
    ''';

    try {
      final request = GraphQLRequest<String>(
        document: query,
        variables: {'divisionId': divisionId},
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.query(request: request).response;

      if (response.errors.isNotEmpty) {
        debugPrint('팀 목록 로드 실패: ${response.errors}');
        return;
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      final items = data['teamsByDivisionIdAndName']['items'] as List<dynamic>;

      _availableTeams = items
          .map((item) => Team.fromJson(item as Map<String, dynamic>))
          .toList();

      notifyListeners();
    } catch (e) {
      debugPrint('팀 목록 로드 오류: $e');
    }
  }

  /// 모든 팀 목록 조회
  Future<void> loadAllTeams() async {
    const query = '''
      query ListTeams {
        listTeams(limit: 100) {
          items {
            id
            divisionId
            name
            code
            description
            adminGroup
            memberGroup
            division {
              id
              name
              code
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
        debugPrint('팀 목록 로드 실패: ${response.errors}');
        return;
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      final items = data['listTeams']['items'] as List<dynamic>;

      _availableTeams = items
          .map((item) => Team.fromJson(item as Map<String, dynamic>))
          .toList();

      notifyListeners();
    } catch (e) {
      debugPrint('팀 목록 로드 오류: $e');
    }
  }

  /// 승인 상태 새로고침
  Future<void> refreshApprovalStatus() async {
    if (_currentProfile?.cognitoUserId == null) return;
    await loadUserProfile(_currentProfile!.cognitoUserId);
  }

  /// 컨텍스트 클리어 (로그아웃 시)
  void clear() {
    _currentProfile = null;
    _currentTeam = null;
    _currentDivision = null;
    _availableTeams = [];
    _availableDivisions = [];
    _errorMessage = null;
    notifyListeners();
  }
}
