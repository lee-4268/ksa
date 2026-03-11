import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 사용자 역할 (호환성 유지)
enum AppUserRole {
  superAdmin,
  divisionAdmin,
  teamAdmin,
  member,
}

/// i-NET (SKons SSO) 기반 인증 서비스
class AuthService extends ChangeNotifier {
  bool _isSignedIn = false;
  bool _isLoading = false;
  String? _errorMessage;
  bool _isInitialized = false;

  // 사용자 정보
  String? _userId;
  String? _userName;
  String? _userDepartment; // 본부/부서
  String? _userTeam; // 팀
  String _userRoleStr = 'member'; // "admin", "manager", "member"
  String? _authToken; // 서버 발급 HMAC 토큰

  /// 세션 타임아웃 (2시간)
  static const Duration sessionTimeout = Duration(hours: 2);

  /// SharedPreferences 키
  static const String _sessionExpiryKey = 'session_expiry_time';
  static const String _isSignedInKey = 'is_signed_in';
  static const String _userIdKey = 'user_id';
  static const String _userNameKey = 'user_name';
  static const String _userDepartmentKey = 'user_department';
  static const String _userTeamKey = 'user_team';
  static const String _userRoleKey = 'user_role';
  static const String _authTokenKey = 'auth_token';

  /// 세션 타이머
  Timer? _sessionTimer;
  DateTime? _sessionExpiryTime;

  bool _isSessionExpired = false;
  bool get isSessionExpired => _isSessionExpired;

  bool get isLoading => _isLoading;
  bool get isSignedIn => _isSignedIn;
  String? get errorMessage => _errorMessage;
  bool get isInitialized => _isInitialized;

  // 토큰
  String? get authToken => _authToken;

  /// 인증 헤더 (Bearer 토큰 포함)
  Map<String, String> get authHeaders => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    if (_authToken != null) 'Authorization': 'Bearer $_authToken',
  };

  // 사용자 정보 Getters
  String? get userId => _userId;
  String? get userEmail => _userId;
  String? get userName => _userName;
  String? get userDepartment => _userDepartment;
  String? get userTeam => _userTeam;

  // 본부명 → 본부 ID 매핑
  static const Map<String, String> _divisionNameToId = {
    '강남본부': 'gangnam',
    '강남': 'gangnam',
    '강북본부': 'gangbuk',
    '강북': 'gangbuk',
    '인천본부': 'incheon',
    '인천': 'incheon',
    '경기본부': 'gyeonggi',
    '경기': 'gyeonggi',
    '강원본부': 'gangwon',
    '강원': 'gangwon',
    '충청본부': 'chungcheong',
    '충청': 'chungcheong',
    '경북본부': 'gyeongbuk',
    '경북': 'gyeongbuk',
    '경남본부': 'gyeongnam',
    '경남': 'gyeongnam',
    '서부본부': 'seobu',
    '서부': 'seobu',
  };

  // 역할 관련
  String get userRoleStr => _userRoleStr;
  AppUserRole get userRole {
    switch (_userRoleStr) {
      case 'admin': return AppUserRole.superAdmin;
      case 'manager': return AppUserRole.divisionAdmin;
      default: return AppUserRole.member;
    }
  }
  String? get profileId => null;
  String? get currentTeamId => null;
  String? get currentTeamName => _userTeam;
  String? get currentDivisionId => _getDivisionIdFromName(_userDepartment);
  String? get currentDivisionName => _userDepartment;

  /// 본부명으로부터 본부 ID 추출
  static String? _getDivisionIdFromName(String? departmentName) {
    if (departmentName == null) return null;
    return _divisionNameToId[departmentName];
  }
  bool get isPendingApproval => false;
  bool get isApproved => _isSignedIn;
  bool get isRejected => false;
  bool get isSuspended => false;
  bool get hasNoProfile => false;
  bool get isSuperAdmin => _userRoleStr == 'admin';
  bool get isDivisionAdmin => _userRoleStr == 'manager';
  bool get isTeamAdmin => false;
  bool get isAdmin => _userRoleStr == 'admin' || _userRoleStr == 'manager';

  /// 업로드/삭제 권한 (admin, manager만)
  bool get canUpload => _userRoleStr == 'admin' || _userRoleStr == 'manager';
  bool get canDelete => _userRoleStr == 'admin' || _userRoleStr == 'manager';

  /// 초기화 - 저장된 로그인 상태 복원
  Future<void> init() async {
    if (_isInitialized) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSignedIn = prefs.getBool(_isSignedInKey) ?? false;

      if (savedSignedIn) {
        final isExpired = await _checkStoredSessionExpiry();

        if (isExpired) {
          debugPrint('저장된 세션 만료로 로그아웃');
          _isSessionExpired = true;
          await _clearLoginState();
        } else {
          _isSignedIn = true;
          _userId = prefs.getString(_userIdKey);
          _userName = prefs.getString(_userNameKey);
          _userDepartment = prefs.getString(_userDepartmentKey);
          _userTeam = prefs.getString(_userTeamKey);
          _userRoleStr = prefs.getString(_userRoleKey) ?? 'member';
          _authToken = prefs.getString(_authTokenKey);
          debugPrint('로그인 상태 복원: $_userId ($_userName, 역할: $_userRoleStr)');
          _startSessionTimerWithExistingExpiry();
        }
      } else {
        debugPrint('로그인 필요');
        await _clearSessionExpiry();
      }
    } catch (e) {
      debugPrint('Auth 초기화 오류: $e');
    }

    _isInitialized = true;
    notifyListeners();
  }

  /// SSO 로그인 프록시 URL (EC2 FastAPI 경유)
  static const String _loginUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );
  String get _loginEndpoint => '$_loginUrl/auth/login';

  /// 로그인 (SKons SSO 인증 + AppSync에서 사용자 정보 조회)
  Future<bool> signIn(String username, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      // 1. SKons SSO 인증
      final response = await http.post(
        Uri.parse(_loginEndpoint),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'username': username,
          'password': password,
        }),
      );

      debugPrint('SSO 응답 [${response.statusCode}]: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final result = data['result'] as String?;

        if (result == 'ok') {
          // 2. SSO 인증 성공 → 토큰 저장 + 즉시 로그인 상태 반영
          _authToken = data['token'] as String?;
          _isSignedIn = true;
          _userId = username;
          _userName = username; // 임시로 사번 표시
          _isLoading = false;

          debugPrint('로그인 성공: $_userId, isSignedIn=$_isSignedIn');

          // 즉시 UI 갱신
          notifyListeners();

          // 웹 환경에서 확실한 UI 업데이트를 위해 다음 프레임에서 한 번 더 알림
          Future.microtask(() => notifyListeners());

          _saveLoginState();
          _startSessionTimerBackground();

          // 3. 사용자 상세 정보 비동기 조회 (화면 전환 후 백그라운드)
          _lookupAndUpdateUserInfo(username);

          return true;
        } else {
          _errorMessage = '아이디 또는 비밀번호가 올바르지 않습니다.';
          debugPrint('SSO 인증 실패: result=$result');
        }
      } else if (response.statusCode == 400 || response.statusCode == 401) {
        // 400 Bad Request, 401 Unauthorized → 인증 실패
        _errorMessage = '아이디 또는 비밀번호가 올바르지 않습니다.';
        debugPrint('SSO 인증 실패: ${response.statusCode}');
      } else if (response.statusCode == 403) {
        _errorMessage = '접근 권한이 없습니다.';
        debugPrint('SSO 접근 거부: ${response.statusCode}');
      } else if (response.statusCode >= 500) {
        _errorMessage = '서버 오류가 발생했습니다. 잠시 후 다시 시도해주세요.';
        debugPrint('SSO 서버 오류: ${response.statusCode}');
      } else {
        _errorMessage = '로그인 중 오류가 발생했습니다. (${response.statusCode})';
        debugPrint('SSO 요청 실패: ${response.statusCode}');
      }

      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('로그인 오류: $e');
      if (e.toString().contains('SocketException') ||
          e.toString().contains('HandshakeException') ||
          e.toString().contains('Network') ||
          e.toString().contains('Failed to fetch')) {
        _errorMessage = '네트워크 연결을 확인해주세요.';
      } else {
        _errorMessage = '로그인 중 오류가 발생했습니다.';
      }
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  /// FastAPI 서버(EC2)에서 사번으로 사용자 정보 조회

  /// 사용자 상세 정보를 비동기로 조회하여 UI 갱신
  void _lookupAndUpdateUserInfo(String empno) async {
    final userInfo = await _lookupUserFromApi(empno);
    if (userInfo != null && _isSignedIn && _userId == empno) {
      _userName = userInfo['name'] as String? ?? empno;
      _userDepartment = userInfo['region'] as String?;
      _userTeam = userInfo['team'] as String?;
      _userRoleStr = userInfo['role'] as String? ?? 'member';
      debugPrint('사용자 정보 업데이트: $_userName (본부: $_userDepartment, 팀: $_userTeam, 역할: $_userRoleStr)');
      notifyListeners();
      _saveLoginState();
    }
  }

  Future<Map<String, dynamic>?> _lookupUserFromApi(String empno) async {
    try {
      final response = await http.get(
        Uri.parse('$_loginUrl/users/$empno'),
        headers: authHeaders,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['success'] == true) {
          debugPrint('사용자 정보 조회 성공: $empno');
          return data;
        }
      }

      debugPrint('사용자 정보 조회 실패: ${response.statusCode}');
      return null;
    } catch (e) {
      debugPrint('사용자 정보 조회 예외: $e');
      return null;
    }
  }

  /// 로그아웃
  Future<void> signOut() async {
    _stopSessionTimer();

    _isSignedIn = false;
    _isSessionExpired = false;
    _isLoading = false;
    _userId = null;
    _userName = null;
    _userDepartment = null;
    _userTeam = null;
    _userRoleStr = 'member';
    _authToken = null;

    notifyListeners();

    await _clearLoginState();
    debugPrint('로그아웃 완료');
  }

  /// 에러 메시지 클리어
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  // ===== 로그인 상태 저장/복원 =====

  Future<void> _saveLoginState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_isSignedInKey, true);
      if (_userId != null) await prefs.setString(_userIdKey, _userId!);
      if (_userName != null) await prefs.setString(_userNameKey, _userName!);
      if (_userDepartment != null) {
        await prefs.setString(_userDepartmentKey, _userDepartment!);
      }
      if (_userTeam != null) {
        await prefs.setString(_userTeamKey, _userTeam!);
      }
      await prefs.setString(_userRoleKey, _userRoleStr);
      if (_authToken != null) {
        await prefs.setString(_authTokenKey, _authToken!);
      }
    } catch (e) {
      debugPrint('로그인 상태 저장 오류: $e');
    }
  }

  Future<void> _clearLoginState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_isSignedInKey);
      await prefs.remove(_userIdKey);
      await prefs.remove(_userNameKey);
      await prefs.remove(_userDepartmentKey);
      await prefs.remove(_userTeamKey);
      await prefs.remove(_userRoleKey);
      await prefs.remove(_authTokenKey);
      await _clearSessionExpiry();
    } catch (e) {
      debugPrint('로그인 상태 삭제 오류: $e');
    }
  }

  // ===== 세션 타이머 관리 =====

  void _startSessionTimerWithExistingExpiry() {
    _stopSessionTimer();
    _isSessionExpired = false;

    if (_sessionExpiryTime == null) {
      _startSessionTimerBackground();
      return;
    }

    _sessionTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _checkSessionTimeout();
    });

    final remaining = _sessionExpiryTime!.difference(DateTime.now());
    debugPrint('세션 타이머 복원: ${remaining.inMinutes}분 남음');
  }

  /// 세션 타이머 시작 (백그라운드, await 불필요)
  void _startSessionTimerBackground() {
    _stopSessionTimer();
    _isSessionExpired = false;

    _sessionExpiryTime = DateTime.now().add(sessionTimeout);
    _saveSessionExpiry(_sessionExpiryTime!); // await 하지 않음

    _sessionTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _checkSessionTimeout();
    });

    debugPrint('세션 타이머 시작: ${sessionTimeout.inHours}시간 후 자동 로그아웃');
  }

  void _stopSessionTimer() {
    _sessionTimer?.cancel();
    _sessionTimer = null;
  }

  Future<void> _saveSessionExpiry(DateTime expiryTime) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionExpiryKey, expiryTime.toIso8601String());
    } catch (e) {
      debugPrint('세션 만료 시간 저장 오류: $e');
    }
  }

  Future<void> _clearSessionExpiry() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionExpiryKey);
    } catch (e) {
      debugPrint('세션 만료 시간 삭제 오류: $e');
    }
  }

  Future<bool> _checkStoredSessionExpiry() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final expiryStr = prefs.getString(_sessionExpiryKey);
      if (expiryStr != null) {
        final storedExpiry = DateTime.parse(expiryStr);
        if (DateTime.now().isAfter(storedExpiry)) {
          debugPrint('저장된 세션이 이미 만료됨: $storedExpiry');
          await _clearSessionExpiry();
          return true;
        } else {
          _sessionExpiryTime = storedExpiry;
          return false;
        }
      }
    } catch (e) {
      debugPrint('세션 만료 시간 확인 오류: $e');
    }
    return false;
  }

  void _checkSessionTimeout() {
    if (_sessionExpiryTime == null || !_isSignedIn) return;

    if (DateTime.now().isAfter(_sessionExpiryTime!)) {
      debugPrint('세션 타임아웃');
      _handleSessionExpired();
    }
  }

  Future<void> _handleSessionExpired() async {
    _stopSessionTimer();
    _isSessionExpired = true;
    _isSignedIn = false;
    _userId = null;
    _userName = null;
    _userDepartment = null;
    _userTeam = null;
    _userRoleStr = 'member';

    notifyListeners();

    await _clearLoginState();
    debugPrint('세션 만료로 자동 로그아웃');
  }

  /// 세션 연장 (서버 토큰도 갱신)
  Future<void> extendSession() async {
    if (!_isSignedIn || _authToken == null) return;
    // 서버에 토큰 갱신 요청
    try {
      final response = await http.post(
        Uri.parse('$_loginUrl/auth/refresh'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_authToken',
        },
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final newToken = data['token'] as String?;
        if (newToken != null && newToken.isNotEmpty) {
          _authToken = newToken;
        }
      }
    } catch (e) {
      debugPrint('토큰 갱신 실패 (로컬 세션만 연장): $e');
    }
    _sessionExpiryTime = DateTime.now().add(sessionTimeout);
    await _saveSessionExpiry(_sessionExpiryTime!);
    _saveLoginState();
    debugPrint('세션 연장: 2시간 추가 (토큰 갱신 포함)');
    notifyListeners();
  }

  /// API 응답에서 갱신된 토큰 체크 및 적용
  void checkAndRefreshToken(http.Response response) {
    final newToken = response.headers['x-refreshed-token'];
    if (newToken != null && newToken.isNotEmpty && _isSignedIn) {
      _authToken = newToken;
      _sessionExpiryTime = DateTime.now().add(sessionTimeout);
      _saveLoginState();
      _saveSessionExpiry(_sessionExpiryTime!);
      debugPrint('토큰 자동 갱신 완료');
    }
  }

  /// StreamedResponse에서 갱신된 토큰 체크 및 적용
  void checkAndRefreshTokenFromHeaders(Map<String, String> headers) {
    final newToken = headers['x-refreshed-token'];
    if (newToken != null && newToken.isNotEmpty && _isSignedIn) {
      _authToken = newToken;
      _sessionExpiryTime = DateTime.now().add(sessionTimeout);
      _saveLoginState();
      _saveSessionExpiry(_sessionExpiryTime!);
      debugPrint('토큰 자동 갱신 완료');
    }
  }

  /// 남은 세션 시간 (분)
  int get remainingSessionMinutes {
    if (_sessionExpiryTime == null) return 0;
    final remaining = _sessionExpiryTime!.difference(DateTime.now());
    return remaining.inMinutes.clamp(0, sessionTimeout.inMinutes);
  }
}
