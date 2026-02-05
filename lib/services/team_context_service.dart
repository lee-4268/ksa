import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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

/// 본부 모델
class Division {
  final String id;
  final String name;
  final String code;
  final String? description;

  Division({
    required this.id,
    required this.name,
    required this.code,
    this.description,
  });

  factory Division.fromJson(Map<String, dynamic> json) {
    return Division(
      id: json['id'] as String,
      name: json['name'] as String,
      code: json['code'] as String,
      description: json['description'] as String?,
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
  final Division? division;

  Team({
    required this.id,
    required this.divisionId,
    required this.name,
    required this.code,
    this.description,
    this.division,
  });

  factory Team.fromJson(Map<String, dynamic> json) {
    return Team(
      id: json['id'] as String,
      divisionId: json['divisionId'] as String,
      name: json['name'] as String,
      code: json['code'] as String,
      description: json['description'] as String?,
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
      cognitoUserId: json['cognitoUserId'] as String? ?? json['empno'] as String? ?? '',
      email: json['email'] as String? ?? '',
      name: json['name'] as String?,
      phoneNumber: json['phoneNumber'] as String?,
      teamId: json['teamId'] as String?,
      divisionId: json['divisionId'] as String?,
      status: UserStatus.values.firstWhere(
        (s) => s.name.toUpperCase() == json['status'],
        orElse: () => UserStatus.approved, // i-NET 사용자는 기본 APPROVED
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

/// 팀 컨텍스트 서비스 - 현재 사용자의 팀/본부 정보 관리 (EC2 REST API 사용)
class TeamContextService extends ChangeNotifier {
  /// API 서버 URL
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

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

  UserRole get currentRole => _currentProfile?.role ?? UserRole.member;
  UserStatus get currentStatus => _currentProfile?.status ?? UserStatus.approved;

  bool get isSuperAdmin => currentRole == UserRole.superAdmin;
  bool get isDivisionAdmin => currentRole == UserRole.divisionAdmin || isSuperAdmin;
  bool get isTeamAdmin => currentRole == UserRole.teamAdmin || isDivisionAdmin;
  bool get isAdmin => isTeamAdmin;

  bool get canManageUsers => isDivisionAdmin;
  bool get canManageTeams => isDivisionAdmin;
  bool get canViewAuditLogs => isTeamAdmin;
  bool get canApproveUsers => isTeamAdmin;

  bool get isPending => _currentProfile?.isPending ?? false;
  bool get isApproved => _currentProfile?.isApproved ?? true; // i-NET 사용자는 기본 승인

  /// 사번으로 사용자 프로필 로드 (EC2 경유 DynamoDB)
  Future<void> loadUserProfile(String empno) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/users/$empno'),
        headers: {'Accept': 'application/json'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          // 사용자 정보를 AppUserProfile로 변환
          _currentProfile = AppUserProfile(
            id: empno,
            cognitoUserId: empno,
            email: data['email'] as String? ?? '',
            name: data['name'] as String?,
            phoneNumber: data['phone'] as String?,
            teamId: null, // i-NET 테이블에서 team 필드명 확인 필요
            divisionId: null,
            status: UserStatus.approved, // i-NET 사용자는 자동 승인
            role: UserRole.member,
          );

          // 본부/팀 정보 설정 (i-NET 테이블 구조에 따라 수정 필요)
          if (data['region'] != null) {
            _currentDivision = Division(
              id: data['region'] as String,
              name: data['region'] as String,
              code: data['region'] as String,
            );
          }
          if (data['team'] != null) {
            _currentTeam = Team(
              id: data['team'] as String,
              divisionId: _currentDivision?.id ?? '',
              name: data['team'] as String,
              code: data['team'] as String,
              division: _currentDivision,
            );
          }

          debugPrint('사용자 프로필 로드 완료: ${_currentProfile?.name}');
        } else {
          debugPrint('사용자 정보 없음: $empno');
          _currentProfile = null;
        }
      } else {
        debugPrint('사용자 프로필 로드 실패: ${response.statusCode}');
      }

      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _errorMessage = '프로필 로드 오류: $e';
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 새 사용자 프로필 생성 (i-NET 인증에서는 불필요)
  Future<AppUserProfile?> createUserProfile({
    required String cognitoUserId,
    required String email,
    String? name,
    String? phoneNumber,
  }) async {
    // i-NET 인증에서는 프로필 생성 불필요 (이미 존재함)
    debugPrint('createUserProfile: i-NET 인증에서는 불필요');
    return null;
  }

  /// 모든 본부 목록 조회 (현재 stub - EC2 API 추가 필요)
  Future<void> loadDivisions() async {
    _isLoading = true;
    notifyListeners();

    // EC2 API에 divisions 엔드포인트 추가 필요
    debugPrint('loadDivisions: EC2 API 구현 필요');

    _isLoading = false;
    notifyListeners();
  }

  /// 특정 본부의 팀 목록 조회 (현재 stub - EC2 API 추가 필요)
  Future<void> loadTeamsByDivision(String divisionId) async {
    // EC2 API에 teams 엔드포인트 추가 필요
    debugPrint('loadTeamsByDivision: EC2 API 구현 필요');
  }

  /// 모든 팀 목록 조회 (현재 stub - EC2 API 추가 필요)
  Future<void> loadAllTeams() async {
    _isLoading = true;
    notifyListeners();

    // EC2 API에 teams 엔드포인트 추가 필요
    debugPrint('loadAllTeams: EC2 API 구현 필요');

    _isLoading = false;
    notifyListeners();
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
