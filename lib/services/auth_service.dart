import 'dart:async';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:flutter/foundation.dart';

/// AWS Cognito 기반 인증 서비스
class AuthService extends ChangeNotifier {
  AuthUser? _currentUser;
  bool _isLoading = false;
  String? _errorMessage;
  bool _isInitialized = false;

  /// 세션 타임아웃 (2시간 = 7200초)
  static const Duration sessionTimeout = Duration(hours: 2);

  /// 세션 타이머
  Timer? _sessionTimer;

  /// 마지막 활동 시간
  DateTime? _lastActivityTime;

  /// 세션 만료 여부
  bool _isSessionExpired = false;
  bool get isSessionExpired => _isSessionExpired;

  AuthUser? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  bool get isSignedIn => _currentUser != null;
  String? get errorMessage => _errorMessage;
  bool get isInitialized => _isInitialized;

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
        _currentUser = await Amplify.Auth.getCurrentUser();
        debugPrint('로그인 상태: ${_currentUser?.userId}');
        // 사용자 속성(이름 등) 조회 - 백그라운드에서 비동기 처리 (로그인 속도 개선)
        fetchUserAttributes();
        // 기존 세션에도 타이머 시작
        _startSessionTimer();
      } else {
        debugPrint('로그인 필요');
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
  void _startSessionTimer() {
    _stopSessionTimer();
    _lastActivityTime = DateTime.now();
    _isSessionExpired = false;

    // 1분마다 세션 만료 체크
    _sessionTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _checkSessionTimeout();
    });

    debugPrint('세션 타이머 시작: ${sessionTimeout.inHours}시간 후 자동 로그아웃');
  }

  /// 세션 타이머 중지
  void _stopSessionTimer() {
    _sessionTimer?.cancel();
    _sessionTimer = null;
  }

  /// 세션 타임아웃 체크
  void _checkSessionTimeout() {
    if (_lastActivityTime == null || _currentUser == null) return;

    final elapsed = DateTime.now().difference(_lastActivityTime!);
    if (elapsed >= sessionTimeout) {
      debugPrint('세션 타임아웃: ${elapsed.inMinutes}분 경과');
      _handleSessionExpired();
    }
  }

  /// 세션 만료 처리
  Future<void> _handleSessionExpired() async {
    _stopSessionTimer();
    _isSessionExpired = true;

    try {
      await Amplify.Auth.signOut();
      _currentUser = null;
      debugPrint('세션 만료로 자동 로그아웃');
    } catch (e) {
      debugPrint('자동 로그아웃 오류: $e');
    }

    notifyListeners();
  }

  /// 사용자 활동 갱신 (화면 터치, 데이터 조작 시 호출)
  void updateActivity() {
    if (_currentUser == null) return;
    _lastActivityTime = DateTime.now();
  }

  /// 세션 연장 (버튼 클릭 시 호출)
  void extendSession() {
    if (_currentUser == null) return;
    _lastActivityTime = DateTime.now();
    debugPrint('세션 연장: 2시간 추가');
    notifyListeners();
  }

  /// 남은 세션 시간 (분)
  int get remainingSessionMinutes {
    if (_lastActivityTime == null) return 0;
    final elapsed = DateTime.now().difference(_lastActivityTime!);
    final remaining = sessionTimeout - elapsed;
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
