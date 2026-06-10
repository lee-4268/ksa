import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../widgets/progress_dialog.dart';

/// 로그인 화면 - i-NET 계정 로그인 + SMS OTP 2차 인증
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // ── 로그인 폼 ──────────────────────────────────────────────
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _devLoginEnabled = false;

  // ── OTP 6자리 개별 박스 ────────────────────────────────────
  final List<TextEditingController> _digitControllers =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _digitFocusNodes =
      List.generate(6, (_) => FocusNode());
  String? _otpError;
  int _resendCooldown = 0;
  Timer? _resendTimer;

  // ── 테마 ──────────────────────────────────────────────────
  static const Color _primary   = Color(0xFFE53935);
  static const Color _textDark  = Color(0xFF111827);
  static const Color _textMid   = Color(0xFF6B7280);
  static const Color _border    = Color(0xFFE5E7EB);
  static const Color _bgPage    = Color(0xFFF5F5F5);

  // ── 테스트 계정 ────────────────────────────────────────────
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
    for (final c in _digitControllers) { c.dispose(); }
    for (final f in _digitFocusNodes) { f.dispose(); }
    _resendTimer?.cancel();
    super.dispose();
  }

  // ── OTP 6자리 합치기 ───────────────────────────────────────
  String get _otpValue =>
      _digitControllers.map((c) => c.text).join();

  // ── 재발송 쿨다운 타이머 ────────────────────────────────────
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

  // ── 개별 자리 입력 처리 ────────────────────────────────────
  void _onDigitChanged(int index, String value) {
    if (_otpError != null) setState(() => _otpError = null);

    // 붙여넣기: 6자리 한번에 입력 처리
    if (value.length > 1) {
      final digits = value.replaceAll(RegExp(r'\D'), '');
      for (int i = 0; i < 6 && i < digits.length; i++) {
        _digitControllers[i].text = digits[i];
      }
      final next = (digits.length < 6 ? digits.length : 5);
      _digitFocusNodes[next].requestFocus();
      setState(() {});
      return;
    }

    if (value.isNotEmpty && index < 5) {
      _digitFocusNodes[index + 1].requestFocus();
    }
    setState(() {});
  }

  // ── 백스페이스 처리 ────────────────────────────────────────
  void _onDigitKeyEvent(int index, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        _digitControllers[index].text.isEmpty &&
        index > 0) {
      _digitFocusNodes[index - 1].requestFocus();
      _digitControllers[index - 1].clear();
      setState(() {});
    }
  }

  // ── 로그인 처리 ────────────────────────────────────────────
  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = context.read<AuthService>();
    final success = await auth.signIn(
      _usernameController.text.trim(),
      _passwordController.text,
    );
    if (!mounted) return;
    if (success && auth.awaitingOtp) {
      _startResendCooldown(30);
      return;
    }
    if (!success && auth.errorMessage != null) {
      await ProgressDialog(context).error(message: auth.errorMessage!);
    }
  }

  // ── OTP 검증 ───────────────────────────────────────────────
  Future<void> _handleVerifyOtp() async {
    final otp = _otpValue;
    if (otp.length != 6) {
      setState(() => _otpError = '인증번호 6자리를 모두 입력해주세요');
      return;
    }
    final auth = context.read<AuthService>();
    final success = await auth.verifyOtp(otp);
    if (!mounted) return;
    if (!success && auth.errorMessage != null) {
      // 오류 시 입력 초기화
      for (final c in _digitControllers) { c.clear(); }
      _digitFocusNodes[0].requestFocus();
      setState(() => _otpError = auth.errorMessage);
    }
  }

  // ── OTP 재발송 ─────────────────────────────────────────────
  Future<void> _handleResendOtp() async {
    if (_resendCooldown > 0) return;
    final auth = context.read<AuthService>();
    final success = await auth.resendOtp();
    if (!mounted) return;
    if (success) {
      for (final c in _digitControllers) { c.clear(); }
      _digitFocusNodes[0].requestFocus();
      setState(() => _otpError = null);
      _startResendCooldown(auth.resendCooldownSeconds);
      await ProgressDialog(context).complete(message: '인증번호가 재발송되었습니다');
    } else if (auth.errorMessage != null) {
      await ProgressDialog(context).error(message: auth.errorMessage!);
    }
  }

  // ── OTP 취소 (로그인 화면으로) ─────────────────────────────
  Future<void> _handleCancelOtp() async {
    _resendTimer?.cancel();
    for (final c in _digitControllers) c.clear();
    setState(() { _otpError = null; _resendCooldown = 0; });
    await context.read<AuthService>().signOut();
  }

  // ══════════════════════════════════════════════════════════
  // OTP 패널 (Modern Minimal)
  // ══════════════════════════════════════════════════════════

  Widget _buildOtpPanel(AuthService auth) {
    final phone = auth.maskedPhone ?? '';
    final filled = _otpValue.length;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 아이콘 + 타이틀 ────────────────────────────────
        Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.shield_outlined, color: _primary, size: 28),
            ),
            const SizedBox(height: 16),
            const Text(
              '2차 인증',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: _textDark,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 6),
            if (phone.isNotEmpty)
              Text(
                '$phone 으로 발송된\n6자리 인증번호를 입력하세요',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: _textMid,
                  height: 1.5,
                ),
              ),
          ],
        ),
        const SizedBox(height: 32),

        // ── 6자리 개별 박스 ────────────────────────────────
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: List.generate(6, (i) => _buildDigitBox(i, auth)),
        ),

        // ── 에러 메시지 ────────────────────────────────────
        if (_otpError != null) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.error_outline, size: 14, color: Colors.red),
              const SizedBox(width: 4),
              Text(
                _otpError!,
                style: const TextStyle(fontSize: 12, color: Colors.red),
              ),
            ],
          ),
        ],
        const SizedBox(height: 28),

        // ── 인증 완료 버튼 ─────────────────────────────────
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          child: ElevatedButton(
            onPressed: (auth.isLoading || filled < 6) ? null : _handleVerifyOtp,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 15),
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: _border,
              disabledForegroundColor: _textMid,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: auth.isLoading
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    '인증 완료',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.2,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 16),

        // ── 재발송 + 다시 로그인 ────────────────────────────
        Row(
          children: [
            // 재발송 버튼
            Expanded(
              child: TextButton(
                onPressed: (_resendCooldown > 0 || auth.isLoading)
                    ? null
                    : _handleResendOtp,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  foregroundColor: _resendCooldown > 0 ? _textMid : _primary,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.refresh_rounded,
                      size: 15,
                      color: _resendCooldown > 0 ? _textMid : _primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _resendCooldown > 0
                          ? '재발송 ${_resendCooldown}s'
                          : '재발송',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: _resendCooldown > 0 ? _textMid : _primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 구분선
            Container(width: 1, height: 20, color: _border),

            // 다시 로그인
            Expanded(
              child: TextButton(
                onPressed: auth.isLoading ? null : _handleCancelOtp,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  foregroundColor: _textMid,
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.arrow_back_rounded, size: 15, color: _textMid),
                    SizedBox(width: 4),
                    Text(
                      '다시 로그인',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: _textMid,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── 개별 자리 박스 ─────────────────────────────────────────
  Widget _buildDigitBox(int index, AuthService auth) {
    final isFocused = _digitFocusNodes[index].hasFocus;
    final hasValue = _digitControllers[index].text.isNotEmpty;
    final hasError = _otpError != null;

    Color borderColor;
    if (hasError) {
      borderColor = Colors.red;
    } else if (isFocused) {
      borderColor = _primary;
    } else if (hasValue) {
      borderColor = _primary.withValues(alpha: 0.4);
    } else {
      borderColor = _border;
    }

    return SizedBox(
      width: 44,
      height: 52,
      child: KeyboardListener(
        focusNode: FocusNode(),
        onKeyEvent: (e) => _onDigitKeyEvent(index, e),
        child: TextField(
          controller: _digitControllers[index],
          focusNode: _digitFocusNodes[index],
          enabled: !auth.isLoading,
          keyboardType: TextInputType.number,
          textInputAction: index < 5 ? TextInputAction.next : TextInputAction.done,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          maxLength: 1,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: hasError ? Colors.red : _textDark,
          ),
          onChanged: (v) => _onDigitChanged(index, v),
          onSubmitted: (_) {
            if (index == 5) _handleVerifyOtp();
          },
          decoration: InputDecoration(
            counterText: '',
            filled: true,
            fillColor: hasValue
                ? _primary.withValues(alpha: 0.04)
                : Colors.white,
            contentPadding: EdgeInsets.zero,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: borderColor, width: 1.5),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                color: hasError ? Colors.red : _primary,
                width: 2,
              ),
            ),
            disabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: _border),
            ),
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // 로그인 폼
  // ══════════════════════════════════════════════════════════

  Widget _buildLoginForm(AuthService auth) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 로고
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.cell_tower, size: 36, color: _primary),
              const SizedBox(width: 12),
              const Text(
                '무선국 수검 시스템',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: _primary,
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '로그인',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: _textMid),
          ),
          const SizedBox(height: 28),

          // i-NET 안내
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: const Color(0xFFF0F4FF),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFD0DBFF)),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, size: 15, color: Color(0xFF4B6BFB)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '아이디와 패스워드는 i-NET 계정과 동일합니다.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF3451B2),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // 아이디
          _buildLabel('아이디'),
          const SizedBox(height: 6),
          TextFormField(
            controller: _usernameController,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.next,
            style: const TextStyle(fontSize: 14, color: _textDark),
            decoration: _inputDecoration('아이디 입력'),
            validator: (v) => (v == null || v.isEmpty) ? '아이디를 입력하세요' : null,
          ),
          const SizedBox(height: 18),

          // 비밀번호
          _buildLabel('비밀번호'),
          const SizedBox(height: 6),
          TextFormField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            obscuringCharacter: '•',
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _handleLogin(),
            style: const TextStyle(fontSize: 14, color: _textDark),
            decoration: _inputDecoration('비밀번호 입력').copyWith(
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: _textMid,
                  size: 18,
                ),
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
              ),
            ),
            validator: (v) => (v == null || v.isEmpty) ? '비밀번호를 입력하세요' : null,
          ),
          const SizedBox(height: 28),

          // 로그인 버튼
          ElevatedButton(
            onPressed: auth.isLoading ? null : _handleLogin,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 15),
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: _primary.withValues(alpha: 0.5),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: auth.isLoading
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Text(
                    'Login',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
          ),

          // 개발용 테스트 로그인
          if (_devLoginEnabled) ...[
            const SizedBox(height: 24),
            Divider(color: _border),
            const SizedBox(height: 10),
            Text(
              '개발용 테스트 로그인',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: _textMid.withValues(alpha: 0.7)),
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    side: BorderSide(
                      color: isAdmin
                          ? Colors.orange.shade300
                          : Colors.grey.shade300,
                    ),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6)),
                  ),
                  child: Text(
                    acc['region']!
                        .replaceAll('본부', '')
                        .replaceAll('담당', ''),
                    style: TextStyle(
                      fontSize: 11,
                      color: isAdmin
                          ? Colors.orange.shade700
                          : Colors.grey.shade600,
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

  // ── 공통 라벨 ──────────────────────────────────────────────
  Widget _buildLabel(String text) => Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: _textDark,
          letterSpacing: 0.1,
        ),
      );

  // ── 공통 InputDecoration ────────────────────────────────────
  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: _textMid, fontSize: 14),
        filled: true,
        fillColor: const Color(0xFFFAFAFB),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.red),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Colors.red, width: 1.5),
        ),
      );

  // ══════════════════════════════════════════════════════════
  // build
  // ══════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgPage,
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
                      color: Colors.black.withValues(alpha: 0.07),
                      blurRadius: 24,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Consumer<AuthService>(
                  builder: (context, auth, _) {
                    return AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.04),
                            end: Offset.zero,
                          ).animate(anim),
                          child: child,
                        ),
                      ),
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

  // ── 개발 로그인 ────────────────────────────────────────────
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
      await ProgressDialog(context).error(message: auth.errorMessage!);
    }
  }
}
