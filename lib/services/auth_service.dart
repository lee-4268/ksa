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

  /// Django 백엔드 로그인 API URL
  static const String _loginUrl =
      'https://dev-monitoring-api.skons.net/accounts/login/';

  /// 로그인 (Django LoginView → SKons SSO 인증 + UserProfile 반환)
  Future<bool> signIn(String username, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
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

      debugPrint('로그인 응답 [${response.statusCode}]: ${response.body}');

      if (response.statusCode == 200) {
        // 성공: UserProfile 데이터 반환
        final data = jsonDecode(response.body) as Map<String, dynamic>;

        _isSignedIn = true;
        _userId = data['username'] as String? ?? username;
        _userName = data['first_name'] as String? ?? username;
        _userDepartment = data['region'] as String?;
        _userJobTitle = data['job_title'] as String?;

        // team 필드에 본부+팀명이 합쳐져 있으므로 본부(region) 부분 제거
        final rawTeam = data['team'] as String?;
        if (rawTeam != null && _userDepartment != null && rawTeam.contains(_userDepartment!)) {
          _userTeam = rawTeam.replaceFirst(_userDepartment!, '').trim();
          if (_userTeam!.isEmpty) _userTeam = rawTeam;
        } else {
          _userTeam = rawTeam;
        }

        debugPrint('로그인 성공: $_userId (이름: $_userName, 본부: $_userDepartment, 팀: $_userTeam, 직책: $_userJobTitle)');

        // UI를 먼저 갱신 (페이지 전환)
        _isLoading = false;
        notifyListeners();

        // 백그라운드에서 상태 저장 (await 하지 않음)
        _saveLoginState();
        _startSessionTimerBackground();

        return true;
      } else if (response.statusCode == 401) {
        _errorMessage = '아이디 또는 비밀번호가 올바르지 않습니다.';
        debugPrint('로그인 실패: 인증 실패');
      } else if (response.statusCode == 404) {
        _errorMessage = '등록되지 않은 사용자입니다.\n관리자에게 문의하세요.';
        debugPrint('로그인 실패: UserProfile 없음');
      } else {
        _errorMessage = '로그인 중 오류가 발생했습니다. (${response.statusCode})';
        debugPrint('로그인 실패: ${response.statusCode}');
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
