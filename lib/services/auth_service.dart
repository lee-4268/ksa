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
  String? _userJobTitle; // 직책

  /// 세션 타임아웃 (2시간)
  static const Duration sessionTimeout = Duration(hours: 2);

  /// SharedPreferences 키
  static const String _sessionExpiryKey = 'session_expiry_time';
  static const String _isSignedInKey = 'is_signed_in';
  static const String _userIdKey = 'user_id';
  static const String _userNameKey = 'user_name';
  static const String _userDepartmentKey = 'user_department';
  static const String _userTeamKey = 'user_team';
  static const String _userJobTitleKey = 'user_job_title';

  /// 세션 타이머
  Timer? _sessionTimer;
  DateTime? _sessionExpiryTime;

  bool _isSessionExpired = false;
  bool get isSessionExpired => _isSessionExpired;

  bool get isLoading => _isLoading;
  bool get isSignedIn => _isSignedIn;
  String? get errorMessage => _errorMessage;
  bool get isInitialized => _isInitialized;

  // 사용자 정보 Getters
  String? get userId => _userId;
  String? get userEmail => _userId;
  String? get userName => _userName;
  String? get userDepartment => _userDepartment;
  String? get userTeam => _userTeam;
  String? get userJobTitle => _userJobTitle;

  // 호환성 유지 - 역할/승인 관련 (기본값 반환)
  AppUserRole get userRole => AppUserRole.member;
  String? get profileId => null;
  String? get currentTeamId => null;
  String? get currentTeamName => _userTeam;
  String? get currentDivisionId => null;
  String? get currentDivisionName => _userDepartment;
  bool get isPendingApproval => false;
  bool get isApproved => _isSignedIn;
  bool get isRejected => false;
  bool get isSuspended => false;
  bool get hasNoProfile => false;
  bool get isSuperAdmin => false;
  bool get isDivisionAdmin => false;
  bool get isTeamAdmin => false;
  bool get isAdmin => false;

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
          _userJobTitle = prefs.getString(_userJobTitleKey);
          debugPrint('로그인 상태 복원: $_userId ($_userName)');
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

  /// SSO 로그인 프록시 URL (CORS 우회를 위해 API Gateway 경유)
  static const String _loginUrl =
      'https://c3jictzagh.execute-api.ap-northeast-2.amazonaws.com/auth/login';

  /// 로그인 (SKons SSO 인증 + AppSync에서 사용자 정보 조회)
  Future<bool> signIn(String username, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      // 1. SKons SSO 인증
      final response = await http.post(
        Uri.parse(_loginUrl),
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
          // 2. SSO 인증 성공 → 즉시 로그인 상태 반영
          _isSignedIn = true;
          _userId = username;
          _userName = username; // 임시로 사번 표시
          _isLoading = false;
          notifyListeners(); // 즉시 UI 갱신 → HomeScreen 전환

          _saveLoginState();
          _startSessionTimerBackground();

          // 3. 사용자 상세 정보 비동기 조회 (화면 전환 후 백그라운드)
          _lookupAndUpdateUserInfo(username);

          return true;
        } else {
          _errorMessage = '아이디 또는 비밀번호가 올바르지 않습니다.';
          debugPrint('SSO 인증 실패: result=$result');
        }
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

  /// FastAPI 서버(API Gateway)에서 사번으로 사용자 정보 조회
  static const String _userApiBaseUrl =
      'https://c3jictzagh.execute-api.ap-northeast-2.amazonaws.com';

  /// 사용자 상세 정보를 비동기로 조회하여 UI 갱신
  void _lookupAndUpdateUserInfo(String empno) async {
    final userInfo = await _lookupUserFromApi(empno);
    if (userInfo != null && _isSignedIn && _userId == empno) {
      _userName = userInfo['name'] as String? ?? empno;
      _userDepartment = userInfo['region'] as String?;
      _userTeam = userInfo['team'] as String?;
      _userJobTitle = userInfo['job_title'] as String?;
      debugPrint('사용자 정보 업데이트: $_userName (본부: $_userDepartment, 팀: $_userTeam)');
      notifyListeners();
      _saveLoginState();
    }
  }

  Future<Map<String, dynamic>?> _lookupUserFromApi(String empno) async {
    try {
      final response = await http.get(
        Uri.parse('$_userApiBaseUrl/users/$empno'),
        headers: {'Content-Type': 'application/json'},
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
    _userJobTitle = null;

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
      if (_userJobTitle != null) {
        await prefs.setString(_userJobTitleKey, _userJobTitle!);
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
      await prefs.remove(_userJobTitleKey);
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
    _userJobTitle = null;

    notifyListeners();

    await _clearLoginState();
    debugPrint('세션 만료로 자동 로그아웃');
  }

  /// 세션 연장
  Future<void> extendSession() async {
    if (!_isSignedIn) return;
    _sessionExpiryTime = DateTime.now().add(sessionTimeout);
    await _saveSessionExpiry(_sessionExpiryTime!);
    debugPrint('세션 연장: 2시간 추가');
    notifyListeners();
  }

  /// 남은 세션 시간 (분)
  int get remainingSessionMinutes {
    if (_sessionExpiryTime == null) return 0;
    final remaining = _sessionExpiryTime!.difference(DateTime.now());
    return remaining.inMinutes.clamp(0, sessionTimeout.inMinutes);
  }
}
