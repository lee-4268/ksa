import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';

/// 로그인 화면 - i-NET 계정 로그인 + SMS OTP 2차 인증
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _devLoginEnabled = false;

  // OTP 입력
  final _otpController = TextEditingController();
  String? _otpFieldError;
  int _resendCooldown = 0; // 초
  Timer? _resendTimer;

  // 테마 색상 (레드/코랄 계열)
  static const Color _primaryColor = Color(0xFFE53935);

  // 테스트 계정 기본 팀 매핑
  static const _testAccounts = [
    {'empno': 'TEST_GN', 'name': '테스트_강남', 'region': '강남Access담당', 'role': 'member', 'team': '강남품질개선팀'},
    {'empno': 'TEST_GB', 'name': '테스트_강북', 'region': '강북Access담당', 'role': 'member', 'team': '용산품질개선팀'},
    {'empno': 'TEST_IC', 'name': '테스트_인천', 'region': '인천Access담당', 'role': 'member', 'team': '북인천품질개선팀'},
    {'empno': 'TEST_GG', 'name': '테스트_경기', 'region': '경기Access담당', 'role': 'member', 'team': '하남품질개선팀'},
    {'empno': 'TEST_GW', 'name': '테스트_강원', 'region': '강원Access담당', 'role': 'member', 'team': '원주품질개선팀'},
    {'empno': 'TEST_CC', 'name': '테스트_충청', 'region': '충청Access담당', 'role': 'member', 'team': '대전품질개선팀'},
    {'empno': 'TEST_KB', 'name': '테스트_경북', 'region': '경북Access담당', 'role': 'member', 'team': '포항품질개선팀'},
    {'empno': 'TEST_KN', 'name': '테스트_경남', 'region': '경남Access담당', 'role': 'member', 'team': '동부산품질개선팀'},
    {'empno': 'TEST_SB', 'name': '테스트_서부', 'region': '서부Access담당', 'role': 'member', 'team': '서광주품질개선팀'},
  ];

  @override
  void initState() {
    super.initState();
    _checkDevLogin();
  }

  void _checkDevLogin() async {
    final auth = context.read<AuthService>();
    final enabled = await auth.isDevLoginEnabled();
    if (mounted) setState(() => _devLoginEnabled = enabled);
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _otpController.dispose();
    _resendTimer?.cancel();
    super.dispose();
  }

  // ===== 로그인 =====

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    final authService = context.read<AuthService>();
    final success = await authService.signIn(
      _usernameController.text.trim(),
      _passwordController.text,
    );

    if (!mounted) return;

    if (success && authService.awaitingOtp) {
      // OTP 화면 진입 → 재발송 쿨다운 시작 (30초)
      _startResendCooldown(30);
      return;
    }

    if (!success && authService.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(authService.errorMessage!),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // ===== OTP =====

  void _startResendCooldown(int seconds) {
    _resendTimer?.cancel();
    setState(() => _resendCooldown = seconds);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() {
        _resendCooldown--;
        if (_resendCooldown <= 0) t.cancel();
      });
    });
  }

  Future<void> _handleVerifyOtp() async {
    final otp = _otpController.text.trim();
    if (otp.length != 6) {
      setState(() => _otpFieldError = '6자리 인증번호를 입력하세요');
      return;
    }
    setState(() => _otpFieldError = null);

    final auth = context.read<AuthService>();
    final success = await auth.verifyOtp(otp);

    if (!mounted) return;
    if (!success && auth.errorMessage != null) {
      setState(() => _otpFieldError = auth.errorMessage);
    }
    // 성공 시 AuthWrapper가 감지해 HomeScreen으로 전환
  }

  Future<void> _handleResendOtp() async {
    if (_resendCooldown > 0) return;
    final auth = context.read<AuthService>();
    final success = await auth.resendOtp();
    if (!mounted) return;

    if (success) {
      _otpController.clear();
      setState(() => _otpFieldError = null);
      _startResendCooldown(60);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('인증번호가 재발송되었습니다.'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    } else if (auth.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(auth.errorMessage!), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _handleCancelOtp() async {
    _resendTimer?.cancel();
    _otpController.clear();
    setState(() {
      _otpFieldError = null;
      _resendCooldown = 0;
    });
    await context.read<AuthService>().signOut();
  }

  // ===== 비밀번호 필드 =====

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      obscuringCharacter: '*',
      textInputAction: TextInputAction.done,
      onFieldSubmitted: (_) => _handleLogin(),
      style: const TextStyle(fontSize: 15, letterSpacing: 0),
      decoration: InputDecoration(
        hintText: '비밀번호 입력',
        hintStyle: TextStyle(color: Colors.grey[400]),
        filled: true,
        fillColor: Colors.grey[50],
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.grey[300]!),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _primaryColor, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.red),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.red, width: 1.5),
        ),
        suffixIcon: IconButton(
          icon: Icon(
            _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            color: Colors.grey[500],
            size: 20,
          ),
          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
        ),
      ),
      validator: (v) => (v == null || v.isEmpty) ? '비밀번호를 입력하세요' : null,
    );
  }

  // ===== OTP 패널 =====

  Widget _buildOtpPanel(AuthService auth) {
    final phone = auth.maskedPhone ?? '등록된 번호';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 헤더
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.sms_outlined, size: 32, color: _primaryColor),
            const SizedBox(width: 10),
            const Text(
              'SMS 인증',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: _primaryColor),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // 안내 박스
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.blue[50],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.blue[200]!),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.smartphone_outlined, size: 16, color: Colors.blue[700]),
                  const SizedBox(width: 8),
                  Text(
                    phone,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue[900],
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '위 번호로 발송된 6자리 인증번호를 입력하세요.\n유효시간: 5분',
                style: TextStyle(fontSize: 12, color: Colors.blue[700]),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // OTP 입력
        Text(
          '인증번호',
          style: TextStyle(fontSize: 13, color: Colors.grey[700], fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _otpController,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          maxLength: 6,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onSubmitted: (_) => _handleVerifyOtp(),
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            letterSpacing: 8,
          ),
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            hintText: '000000',
            hintStyle: TextStyle(color: Colors.grey[300], fontSize: 24, letterSpacing: 8),
            counterText: '',
            filled: true,
            fillColor: Colors.grey[50],
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: _otpFieldError != null ? Colors.red : Colors.grey[300]!),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: _otpFieldError != null ? Colors.red : Colors.grey[300]!),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(
                color: _otpFieldError != null ? Colors.red : _primaryColor,
                width: 1.5,
              ),
            ),
            errorText: _otpFieldError,
          ),
          onChanged: (_) {
            if (_otpFieldError != null) setState(() => _otpFieldError = null);
          },
        ),
        const SizedBox(height: 20),

        // 확인 버튼
        ElevatedButton(
          onPressed: auth.isLoading ? null : _handleVerifyOtp,
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            backgroundColor: _primaryColor,
            foregroundColor: Colors.white,
            disabledBackgroundColor: _primaryColor.withValues(alpha: 0.6),
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: auth.isLoading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.verified_outlined, size: 18),
                    SizedBox(width: 8),
                    Text('인증 완료', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  ],
                ),
        ),
        const SizedBox(height: 12),

        // 재발송 + 취소 버튼 행
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (_resendCooldown > 0 || auth.isLoading) ? null : _handleResendOtp,
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(
                  _resendCooldown > 0 ? '재발송 (${_resendCooldown}s)' : '재발송',
                  style: const TextStyle(fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: auth.isLoading ? null : _handleCancelOtp,
                icon: const Icon(Icons.arrow_back, size: 16),
                label: const Text('다시 로그인', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  foregroundColor: Colors.grey[600],
                  side: BorderSide(color: Colors.grey[300]!),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ===== 로그인 폼 =====

  Widget _buildLoginForm(AuthService auth) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 로고 영역
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cell_tower, size: 36, color: _primaryColor),
              const SizedBox(width: 12),
              const Text(
                '무선국 수검 시스템',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _primaryColor),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '로그인',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey[600], fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 24),

          // i-NET 안내
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.blue[50],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue[200]!),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: Colors.blue[700]),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '아이디와 패스워드는 i-NET 계정과 동일합니다.',
                    style: TextStyle(fontSize: 13, color: Colors.blue[800], fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 아이디
          Text('아이디', style: TextStyle(fontSize: 13, color: Colors.grey[700], fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          TextFormField(
            controller: _usernameController,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.next,
            style: const TextStyle(fontSize: 15, letterSpacing: 0),
            decoration: InputDecoration(
              hintText: '아이디 입력',
              hintStyle: TextStyle(color: Colors.grey[400]),
              filled: true,
              fillColor: Colors.grey[50],
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.grey[300]!),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.grey[300]!),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _primaryColor, width: 1.5),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Colors.red),
              ),
            ),
            validator: (v) => (v == null || v.isEmpty) ? '아이디를 입력하세요' : null,
          ),
          const SizedBox(height: 20),

          // 비밀번호
          Text('비밀번호', style: TextStyle(fontSize: 13, color: Colors.grey[700], fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          _buildPasswordField(),
          const SizedBox(height: 32),

          // 로그인 버튼
          ElevatedButton(
            onPressed: auth.isLoading ? null : _handleLogin,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: _primaryColor,
              foregroundColor: Colors.white,
              disabledBackgroundColor: _primaryColor.withValues(alpha: 0.6),
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: auth.isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lock_outline, size: 18),
                      SizedBox(width: 8),
                      Text('Login', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    ],
                  ),
          ),

          // 개발용 테스트 로그인
          if (_devLoginEnabled) ...[
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 12),
            Text(
              '개발용 테스트 로그인',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey[500], fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: _testAccounts.map((acc) {
                final isAdmin = acc['role'] == 'admin';
                return OutlinedButton(
                  onPressed: () => _handleDevLogin(acc),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    side: BorderSide(
                      color: isAdmin ? Colors.orange.shade400 : Colors.grey.shade300,
                    ),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                  child: Text(
                    acc['region']!.replaceAll('본부', '').replaceAll('담당', ''),
                    style: TextStyle(
                      fontSize: 11,
                      color: isAdmin ? Colors.orange.shade700 : Colors.grey.shade700,
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 20,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Consumer<AuthService>(
                  builder: (context, auth, _) {
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: auth.awaitingOtp
                          ? KeyedSubtree(
                              key: const ValueKey('otp'),
                              child: _buildOtpPanel(auth),
                            )
                          : KeyedSubtree(
                              key: const ValueKey('login'),
                              child: _buildLoginForm(auth),
                            ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleDevLogin(Map<String, String> acc) async {
    final auth = context.read<AuthService>();
    final success = await auth.devLogin(
      empno: acc['empno']!,
      name: acc['name']!,
      region: acc['region']!,
      role: acc['role']!,
      team: acc['team'] ?? '',
    );
    if (!mounted) return;
    if (!success && auth.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(auth.errorMessage!), backgroundColor: Colors.red),
      );
    }
  }
}
