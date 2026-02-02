import 'dart:async';
import 'dart:convert';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 사용자 상태 (승인 관련)
enum UserApprovalStatus {
  pending,
  approved,
  rejected,
  suspended,
  noProfile, // 프로필이 아직 생성되지 않음
}

/// 사용자 역할
enum AppUserRole {
  superAdmin,
  divisionAdmin,
  teamAdmin,
  member,
}

/// AWS Cognito 기반 인증 서비스
class AuthService extends ChangeNotifier {
  AuthUser? _currentUser;
  bool _isLoading = false;
  String? _errorMessage;
  bool _isInitialized = false;

  // 사용자 프로필 관련
  String? _profileId;
  UserApprovalStatus _approvalStatus = UserApprovalStatus.noProfile;
  AppUserRole _userRole = AppUserRole.member;
  String? _currentTeamId;
  String? _currentTeamName;
  String? _currentDivisionId;
  String? _currentDivisionName;

  /// 세션 타임아웃 (2시간 = 7200초)
  static const Duration sessionTimeout = Duration(hours: 2);

  /// 세션 만료 시간 저장 키
  static const String _sessionExpiryKey = 'session_expiry_time';

  /// 세션 타이머
  Timer? _sessionTimer;

  /// 세션 만료 예정 시간 (절대 시간)
  DateTime? _sessionExpiryTime;

  /// 세션 만료 여부
  bool _isSessionExpired = false;
  bool get isSessionExpired => _isSessionExpired;

  AuthUser? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  bool get isSignedIn => _currentUser != null;
  String? get errorMessage => _errorMessage;
  bool get isInitialized => _isInitialized;

  // 프로필 및 승인 상태 Getters
  String? get profileId => _profileId;
  UserApprovalStatus get approvalStatus => _approvalStatus;
  AppUserRole get userRole => _userRole;
  String? get currentTeamId => _currentTeamId;
  String? get currentTeamName => _currentTeamName;
  String? get currentDivisionId => _currentDivisionId;
  String? get currentDivisionName => _currentDivisionName;

  bool get isPendingApproval => _approvalStatus == UserApprovalStatus.pending;
  bool get isApproved => _approvalStatus == UserApprovalStatus.approved;
  bool get isRejected => _approvalStatus == UserApprovalStatus.rejected;
  bool get isSuspended => _approvalStatus == UserApprovalStatus.suspended;
  bool get hasNoProfile => _approvalStatus == UserApprovalStatus.noProfile;

  bool get isSuperAdmin => _userRole == AppUserRole.superAdmin;
  bool get isDivisionAdmin => _userRole == AppUserRole.divisionAdmin || isSuperAdmin;
  bool get isTeamAdmin => _userRole == AppUserRole.teamAdmin || isDivisionAdmin;
  bool get isAdmin => isTeamAdmin;

  /// 현재 사용자 ID
  String? get userId => _currentUser?.userId;

  /// 현재 사용자 이메일
  String? get userEmail {
    final details = _currentUser?.signInDetails.toJson();
    if (details != null && details['username'] != null) {
      return details['username'].toString();
    }
    return null;
  }

  /// 현재 사용자 이름 (name attribute)
  String? _userName;
  String? get userName => _userName;

  /// 현재 사용자 연락처 (phone_number attribute)
  String? _userPhoneNumber;
  String? get userPhoneNumber => _userPhoneNumber;

  /// 사용자 속성 조회 (이름, 연락처 등)
  Future<void> fetchUserAttributes() async {
    if (!isSignedIn) return;

    try {
      final attributes = await Amplify.Auth.fetchUserAttributes();
      for (final attr in attributes) {
        if (attr.userAttributeKey == AuthUserAttributeKey.name) {
          _userName = attr.value;
        } else if (attr.userAttributeKey == AuthUserAttributeKey.phoneNumber) {
          _userPhoneNumber = attr.value;
        }
      }
      notifyListeners();
    } catch (e) {
      debugPrint('사용자 속성 조회 오류: $e');
    }
  }

  /// 사용자 프로필 로드 (승인 상태 확인)
  Future<void> loadUserProfile() async {
    if (_currentUser == null) return;

    // ★ 핵심 최적화: Cognito 그룹을 먼저 빠르게 확인
    // Cognito 그룹에 속해있으면 DB 상태와 관계없이 즉시 승인 처리
    // 이렇게 하면 "승인 대기중" 화면이 잠시 뜨는 현상 방지
    final isInCognitoGroup = await _checkUserInCognitoGroup();
    if (isInCognitoGroup) {
      debugPrint('Cognito 그룹 확인 완료 - 즉시 승인 상태로 설정');
      _approvalStatus = UserApprovalStatus.approved;
      // UI 먼저 업데이트 (빠른 응답)
      notifyListeners();
    }

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
        variables: {'cognitoUserId': _currentUser!.userId},
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.query(request: request).response;

      if (response.errors.isNotEmpty) {
        debugPrint('프로필 로드 오류: ${response.errors}');
        _approvalStatus = UserApprovalStatus.noProfile;
        notifyListeners();
        return;
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      final items = data['userProfileByCognitoId']['items'] as List<dynamic>;

      if (items.isEmpty) {
        // Cognito 그룹에 속해있으면 프로필이 없어도 승인 상태 유지
        if (!isInCognitoGroup) {
          _approvalStatus = UserApprovalStatus.noProfile;
        }
        debugPrint('사용자 프로필 없음 - 생성 필요');
      } else {
        final profile = items.first as Map<String, dynamic>;
        _profileId = profile['id'] as String?;

        // DB 상태 파싱 (Cognito 그룹으로 이미 승인된 경우 무시)
        final statusStr = profile['status'] as String?;
        final dbStatus = switch (statusStr?.toUpperCase()) {
          'PENDING' => UserApprovalStatus.pending,
          'APPROVED' => UserApprovalStatus.approved,
          'REJECTED' => UserApprovalStatus.rejected,
          'SUSPENDED' => UserApprovalStatus.suspended,
          _ => UserApprovalStatus.pending,
        };

        // Cognito 그룹으로 이미 승인된 경우 DB 상태 무시 (단, SUSPENDED/REJECTED는 예외)
        if (!isInCognitoGroup) {
          _approvalStatus = dbStatus;
        } else if (dbStatus == UserApprovalStatus.suspended) {
          // 정지된 계정은 Cognito 그룹에 있어도 정지 상태 유지
          _approvalStatus = UserApprovalStatus.suspended;
        }
        // rejected는 Cognito 그룹에 있으면 무시 (그룹에 추가됐으면 승인된 것)

        // 역할 파싱 (Cognito 그룹에서 이미 설정된 경우 덮어쓰지 않음 - 그룹 기반 역할이 우선)
        if (!isInCognitoGroup) {
          final roleStr = profile['role'] as String?;
          _userRole = switch (roleStr?.toUpperCase().replaceAll('_', '')) {
            'SUPERADMIN' => AppUserRole.superAdmin,
            'DIVISIONADMIN' => AppUserRole.divisionAdmin,
            'TEAMADMIN' => AppUserRole.teamAdmin,
            _ => AppUserRole.member,
          };
        }

        // 팀/본부 정보 (DB에서 가져온 정보 사용, Cognito에서 설정 안된 경우)
        _currentTeamId = profile['teamId'] as String?;
        _currentDivisionId = profile['divisionId'] as String?;

        final team = profile['team'] as Map<String, dynamic>?;
        if (team != null) {
          if (_currentTeamName == null) {
            _currentTeamName = team['name'] as String?;
          }
          final division = team['division'] as Map<String, dynamic>?;
          if (division != null && _currentDivisionName == null) {
            _currentDivisionName = division['name'] as String?;
          }
        }

        debugPrint('프로필 로드 완료 (DB): dbStatus=$dbStatus, finalStatus=$_approvalStatus, role=$_userRole, team=$_currentTeamName');

        // DB가 PENDING인데 Cognito 그룹에 있으면 DB 업데이트
        if (isInCognitoGroup && dbStatus == UserApprovalStatus.pending) {
          debugPrint('DB 상태가 PENDING이지만 Cognito 그룹에 있음 - DB 자동 업데이트');
          await _autoApproveUserProfile();
        }

        debugPrint('프로필 로드 완료 (최종): status=$_approvalStatus, role=$_userRole, division=$_currentDivisionName, team=$_currentTeamName');
      }

      notifyListeners();
    } catch (e) {
      debugPrint('프로필 로드 예외: $e');
      _approvalStatus = UserApprovalStatus.noProfile;
      notifyListeners();
    }
  }

  /// Cognito 그룹 멤버십 확인 및 역할/소속 정보 추출
  Future<bool> _checkUserInCognitoGroup() async {
    try {
      // JWT 토큰에서 그룹 정보 추출 (캐시된 세션 사용 - 빠름)
      // forceRefresh 제거: JWT 토큰에 이미 그룹 정보가 포함되어 있음
      final session = await Amplify.Auth.fetchAuthSession();

      // CognitoAuthSession으로 캐스팅하여 토큰 접근
      if (session is CognitoAuthSession) {
        final idToken = session.userPoolTokensResult.valueOrNull?.idToken;
        if (idToken != null) {
          // JWT 토큰 디코딩 (페이로드 부분)
          final parts = idToken.raw.split('.');
          if (parts.length == 3) {
            final payload = parts[1];
            // Base64 패딩 추가
            final normalizedPayload = base64.normalize(payload);
            final decoded = utf8.decode(base64.decode(normalizedPayload));
            final claims = jsonDecode(decoded) as Map<String, dynamic>;

            // cognito:groups 클레임 확인
            final groups = claims['cognito:groups'] as List<dynamic>?;
            if (groups != null && groups.isNotEmpty) {
              debugPrint('사용자 Cognito 그룹: $groups');

              // 그룹 이름에서 역할 및 소속 정보 추출
              _extractRoleFromGroups(groups.cast<String>());

              return true;
            }
          }
        }
      }
      return false;
    } catch (e) {
      debugPrint('Cognito 그룹 확인 오류: $e');
      return false;
    }
  }

  /// Cognito 그룹 이름에서 역할 추출 (단순화된 3그룹 구조)
  /// - SuperAdmin: 시스템 전체 관리
  /// - DivisionAdmins: 본부 관리자
  /// - AllMembers: 승인된 일반 사용자
  /// 세부 권한(divisionId, teamId)은 DB UserProfile에서 관리
  void _extractRoleFromGroups(List<String> groups) {
    // 우선순위: SuperAdmin > DivisionAdmins > AllMembers
    for (final group in groups) {
      if (group == 'SuperAdmin' || group == 'SuperAdmins') {
        _userRole = AppUserRole.superAdmin;
        debugPrint('역할 설정: SuperAdmin (그룹: $group)');
        return;
      }
    }

    for (final group in groups) {
      if (group == 'DivisionAdmins') {
        _userRole = AppUserRole.divisionAdmin;
        debugPrint('역할 설정: DivisionAdmin (그룹: $group)');
        return;
      }
    }

    // AllMembers 또는 기타 그룹에 속해있으면 일반 멤버
    if (groups.isNotEmpty) {
      _userRole = AppUserRole.member;
      debugPrint('역할 설정: Member (그룹: ${groups.join(", ")})');
    }
  }

  /// UserProfile 자동 승인 업데이트
  Future<void> _autoApproveUserProfile() async {
    if (_profileId == null) return;

    const mutation = '''
      mutation UpdateUserProfileStatus(\$input: UpdateUserProfileInput!) {
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
            'id': _profileId,
            'status': 'APPROVED',
            'approvedAt': DateTime.now().toUtc().toIso8601String(),
            'approvedBy': 'AUTO_COGNITO_GROUP',
          }
        },
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isEmpty) {
        _approvalStatus = UserApprovalStatus.approved;
        debugPrint('UserProfile 자동 승인 완료');
      } else {
        debugPrint('UserProfile 자동 승인 실패: ${response.errors}');
      }
    } catch (e) {
      debugPrint('UserProfile 자동 승인 예외: $e');
    }
  }

  /// 사용자 프로필 생성 (회원가입 완료 후)
  Future<bool> createUserProfile() async {
    if (_currentUser == null) return false;

    const mutation = '''
      mutation CreateUserProfile(\$input: CreateUserProfileInput!) {
        createUserProfile(input: \$input) {
          id
          status
          role
        }
      }
    ''';

    final input = <String, dynamic>{
      'cognitoUserId': _currentUser!.userId,
      'email': userEmail ?? '',
      'status': 'PENDING',
      'role': 'MEMBER',
    };

    if (_userName != null) input['name'] = _userName;
    if (_userPhoneNumber != null) input['phoneNumber'] = _userPhoneNumber;

    try {
      final request = GraphQLRequest<String>(
        document: mutation,
        variables: {'input': input},
        authorizationMode: APIAuthorizationType.userPools,
      );

      final response = await Amplify.API.mutate(request: request).response;

      if (response.errors.isNotEmpty) {
        debugPrint('프로필 생성 실패: ${response.errors}');
        return false;
      }

      final data = jsonDecode(response.data!) as Map<String, dynamic>;
      _profileId = data['createUserProfile']['id'] as String?;
      _approvalStatus = UserApprovalStatus.pending;
      _userRole = AppUserRole.member;

      debugPrint('프로필 생성 완료: $_profileId');
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('프로필 생성 예외: $e');
      return false;
    }
  }

  /// 승인 상태 새로고침
  Future<void> refreshApprovalStatus() async {
    await loadUserProfile();
  }

  /// 프로필 정보 클리어 (로그아웃 시)
  void _clearProfileInfo() {
    _profileId = null;
    _approvalStatus = UserApprovalStatus.noProfile;
    _userRole = AppUserRole.member;
    _currentTeamId = null;
    _currentTeamName = null;
    _currentDivisionId = null;
    _currentDivisionName = null;
  }

  /// 초기화 - 현재 로그인 상태 확인
  Future<void> init() async {
    if (_isInitialized) return;

    try {
      // Identity Pool 자격 증명 요청을 건너뛰고 User Pool 토큰만 확인
      // forceRefresh: false로 설정하여 불필요한 네트워크 요청 방지
      final session = await Amplify.Auth.fetchAuthSession(
        options: const FetchAuthSessionOptions(forceRefresh: false),
      );

      if (session.isSignedIn) {
        // 저장된 세션 만료 시간 확인 (브라우저 종료 후에도 유지)
        final isExpired = await _checkStoredSessionExpiry();

        if (isExpired) {
          // 세션이 만료됨 - 로그아웃 처리
          debugPrint('저장된 세션 만료로 로그아웃');
          _isSessionExpired = true;
          await Amplify.Auth.signOut();
        } else {
          _currentUser = await Amplify.Auth.getCurrentUser();
          debugPrint('로그인 상태: ${_currentUser?.userId}');
          // 사용자 속성(이름 등) 조회 - 백그라운드에서 비동기 처리 (로그인 속도 개선)
          fetchUserAttributes();
          // 사용자 프로필 로드 (승인 상태 확인)
          await loadUserProfile();
          // 세션 타이머 시작 (기존 만료 시간 유지)
          _startSessionTimerWithExistingExpiry();
        }
      } else {
        debugPrint('로그인 필요');
        // 로그인 안 된 상태면 저장된 세션 만료 시간 삭제
        await _clearSessionExpiry();
      }
    } on AuthException catch (e) {
      // 로그인되지 않은 상태에서는 정상적인 오류 - 무시
      debugPrint('Auth 세션 확인: ${e.message}');
    } catch (e) {
      debugPrint('Auth 초기화 오류: $e');
    }

    _isInitialized = true;
    notifyListeners();
  }

  /// 기존 만료 시간으로 세션 타이머 시작 (앱 재시작 시)
  void _startSessionTimerWithExistingExpiry() {
    _stopSessionTimer();
    _isSessionExpired = false;

    // 이미 _sessionExpiryTime이 _checkStoredSessionExpiry에서 복원됨
    if (_sessionExpiryTime == null) {
      // 만료 시간이 없으면 새로 설정
      _startSessionTimer();
      return;
    }

    // 1분마다 세션 만료 체크
    _sessionTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _checkSessionTimeout();
    });

    final remaining = _sessionExpiryTime!.difference(DateTime.now());
    debugPrint('세션 타이머 복원: ${remaining.inMinutes}분 남음 (만료: $_sessionExpiryTime)');
  }

  /// 회원가입
  Future<SignUpResult?> signUp({
    required String email,
    required String password,
    String? name,
    String? phoneNumber,
  }) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final userAttributes = <AuthUserAttributeKey, String>{
        AuthUserAttributeKey.email: email,
      };
      if (name != null && name.isNotEmpty) {
        userAttributes[AuthUserAttributeKey.name] = name;
      }
      // 연락처 저장 (하이픈 없이 숫자만, +82 형식으로 저장)
      if (phoneNumber != null && phoneNumber.isNotEmpty) {
        // 숫자만 추출
        final digitsOnly = phoneNumber.replaceAll(RegExp(r'[^0-9]'), '');
        // 한국 번호 형식으로 변환 (+82로 시작하게)
        String formattedPhone = digitsOnly;
        if (digitsOnly.startsWith('0')) {
          formattedPhone = '+82${digitsOnly.substring(1)}';
        } else if (!digitsOnly.startsWith('+')) {
          formattedPhone = '+82$digitsOnly';
        }
        userAttributes[AuthUserAttributeKey.phoneNumber] = formattedPhone;
      }

      final result = await Amplify.Auth.signUp(
        username: email,
        password: password,
        options: SignUpOptions(userAttributes: userAttributes),
      );

      debugPrint('회원가입 결과: ${result.isSignUpComplete}');
      _isLoading = false;
      notifyListeners();
      return result;
    } on AuthException catch (e) {
      _errorMessage = _mapAuthError(e);
      debugPrint('회원가입 오류: $_errorMessage');
      _isLoading = false;
      notifyListeners();
      return null;
    }
  }

  /// 이메일 인증 코드 확인
  Future<bool> confirmSignUp(String email, String code) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await Amplify.Auth.confirmSignUp(
        username: email,
        confirmationCode: code,
      );

      _isLoading = false;
      notifyListeners();
      return result.isSignUpComplete;
    } on AuthException catch (e) {
      _errorMessage = _mapAuthError(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// 인증 코드 재전송
  Future<bool> resendSignUpCode(String email) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await Amplify.Auth.resendSignUpCode(username: email);
      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _errorMessage = _mapAuthError(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// 로그인
  Future<bool> signIn(String email, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      // 로그인 시도 (기존 세션 로그아웃 제거 - 불필요한 네트워크 요청)
      final result = await Amplify.Auth.signIn(
        username: email,
        password: password,
      );

      if (result.isSignedIn) {
        // getCurrentUser 호출을 병렬로 처리하지 않고 필수이므로 await
        // 하지만 fetchUserAttributes는 백그라운드에서 처리
        _currentUser = await Amplify.Auth.getCurrentUser();
        debugPrint('로그인 성공: ${_currentUser?.userId}');
        // 사용자 속성(이름 등) 조회 - 백그라운드에서 비동기 처리 (로그인 속도 개선)
        fetchUserAttributes();
        // 사용자 프로필 로드 (승인 상태 확인)
        await loadUserProfile();
        // 세션 타이머 시작 (2시간 비활성 시 자동 로그아웃)
        _startSessionTimer();
      }

      _isLoading = false;
      notifyListeners();
      return result.isSignedIn;
    } on AuthException catch (e) {
      // 이미 로그인된 상태에서 다시 로그인 시도하는 경우
      if (e.message.toLowerCase().contains('already') ||
          e.message.toLowerCase().contains('signed in')) {
        // 기존 세션 로그아웃 후 재시도
        try {
          await Amplify.Auth.signOut();
          // 재귀 호출로 다시 로그인 시도
          return signIn(email, password);
        } catch (_) {
          _errorMessage = _mapAuthError(e);
          _isLoading = false;
          notifyListeners();
          return false;
        }
      }

      _errorMessage = _mapAuthError(e);
      debugPrint('로그인 오류: $_errorMessage');
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// 로그아웃
  Future<void> signOut() async {
    _isLoading = true;
    notifyListeners();

    // 세션 타이머 중지
    _stopSessionTimer();

    try {
      await Amplify.Auth.signOut();
      _currentUser = null;
      _isSessionExpired = false;
      // 프로필 정보 클리어
      _clearProfileInfo();
      _userName = null;
      _userPhoneNumber = null;
      debugPrint('로그아웃 완료');
    } catch (e) {
      debugPrint('로그아웃 오류: $e');
    }

    _isLoading = false;
    notifyListeners();
  }

  /// 비밀번호 재설정 요청
  Future<bool> resetPassword(String email) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await Amplify.Auth.resetPassword(username: email);
      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _errorMessage = _mapAuthError(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// 비밀번호 재설정 확인
  Future<bool> confirmResetPassword(
    String email,
    String code,
    String newPassword,
  ) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await Amplify.Auth.confirmResetPassword(
        username: email,
        confirmationCode: code,
        newPassword: newPassword,
      );
      _isLoading = false;
      notifyListeners();
      return true;
    } on AuthException catch (e) {
      _errorMessage = _mapAuthError(e);
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// 에러 메시지 클리어
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// 세션 타이머 시작 (로그인 후 호출)
  Future<void> _startSessionTimer() async {
    _stopSessionTimer();
    _isSessionExpired = false;

    // 세션 만료 시간 설정 및 저장 (현재 시간 + 2시간)
    _sessionExpiryTime = DateTime.now().add(sessionTimeout);
    await _saveSessionExpiry(_sessionExpiryTime!);

    // 1분마다 세션 만료 체크
    _sessionTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _checkSessionTimeout();
    });

    debugPrint('세션 타이머 시작: ${sessionTimeout.inHours}시간 후 자동 로그아웃 (만료: $_sessionExpiryTime)');
  }

  /// 세션 타이머 중지
  void _stopSessionTimer() {
    _sessionTimer?.cancel();
    _sessionTimer = null;
  }

  /// 세션 만료 시간 저장 (로컬 스토리지)
  Future<void> _saveSessionExpiry(DateTime expiryTime) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionExpiryKey, expiryTime.toIso8601String());
    } catch (e) {
      debugPrint('세션 만료 시간 저장 오류: $e');
    }
  }

  /// 세션 만료 시간 불러오기 (로컬 스토리지)
  Future<DateTime?> _loadSessionExpiry() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final expiryStr = prefs.getString(_sessionExpiryKey);
      if (expiryStr != null) {
        return DateTime.parse(expiryStr);
      }
    } catch (e) {
      debugPrint('세션 만료 시간 불러오기 오류: $e');
    }
    return null;
  }

  /// 세션 만료 시간 삭제 (로컬 스토리지)
  Future<void> _clearSessionExpiry() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionExpiryKey);
    } catch (e) {
      debugPrint('세션 만료 시간 삭제 오류: $e');
    }
  }

  /// 저장된 세션 만료 시간 확인 (앱 시작 시 호출)
  Future<bool> _checkStoredSessionExpiry() async {
    final storedExpiry = await _loadSessionExpiry();
    if (storedExpiry != null) {
      if (DateTime.now().isAfter(storedExpiry)) {
        // 이미 만료됨
        debugPrint('저장된 세션이 이미 만료됨: $storedExpiry');
        await _clearSessionExpiry();
        return true; // 만료됨
      } else {
        // 아직 유효함 - 만료 시간 복원
        _sessionExpiryTime = storedExpiry;
        debugPrint('세션 복원: 만료 시간 $storedExpiry');
        return false; // 유효함
      }
    }
    return false;
  }

  /// 세션 타임아웃 체크
  void _checkSessionTimeout() {
    if (_sessionExpiryTime == null || _currentUser == null) return;

    if (DateTime.now().isAfter(_sessionExpiryTime!)) {
      debugPrint('세션 타임아웃: 만료 시간 초과');
      _handleSessionExpired();
    }
  }

  /// 세션 만료 처리
  Future<void> _handleSessionExpired() async {
    _stopSessionTimer();
    _isSessionExpired = true;
    await _clearSessionExpiry();

    try {
      await Amplify.Auth.signOut();
      _currentUser = null;
      debugPrint('세션 만료로 자동 로그아웃');
    } catch (e) {
      debugPrint('자동 로그아웃 오류: $e');
    }

    notifyListeners();
  }

  /// 사용자 활동 갱신 (화면 터치, 데이터 조작 시 호출) - 세션 연장하지 않음
  void updateActivity() {
    // 절대 시간 기반이므로 활동 갱신 불필요
  }

  /// 세션 연장 (버튼 클릭 시 호출)
  Future<void> extendSession() async {
    if (_currentUser == null) return;
    _sessionExpiryTime = DateTime.now().add(sessionTimeout);
    await _saveSessionExpiry(_sessionExpiryTime!);
    debugPrint('세션 연장: 2시간 추가 (만료: $_sessionExpiryTime)');
    notifyListeners();
  }

  /// 남은 세션 시간 (분)
  int get remainingSessionMinutes {
    if (_sessionExpiryTime == null) return 0;
    final remaining = _sessionExpiryTime!.difference(DateTime.now());
    return remaining.inMinutes.clamp(0, sessionTimeout.inMinutes);
  }

  /// 에러 메시지 매핑
  String _mapAuthError(AuthException e) {
    final message = e.message.toLowerCase();

    if (message.contains('user not found') || message.contains('usernotfoundexception')) {
      return '등록되지 않은 이메일입니다.';
    } else if (message.contains('incorrect') || message.contains('not authorized')) {
      return '이메일 또는 비밀번호가 올바르지 않습니다.';
    } else if (message.contains('user already exists') || message.contains('usernameexists')) {
      return '이미 등록된 이메일입니다.';
    } else if (message.contains('code mismatch') || message.contains('codemismatch')) {
      return '인증 코드가 올바르지 않습니다.';
    } else if (message.contains('invalid password') || message.contains('invalidpassword')) {
      return '비밀번호는 8자 이상이어야 합니다.';
    } else if (message.contains('limit exceeded') || message.contains('limitexceeded')) {
      return '요청 횟수가 초과되었습니다. 잠시 후 다시 시도해주세요.';
    } else if (message.contains('network')) {
      return '네트워크 연결을 확인해주세요.';
    } else if (message.contains('invalid parameter') || message.contains('invalidparameter')) {
      return '입력 형식이 올바르지 않습니다.';
    }

    return e.message;
  }
}
