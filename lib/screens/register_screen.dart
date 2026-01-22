import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';

/// 회원가입 화면 - 로그인 페이지와 일관된 디자인
class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isVerificationStep = false;
  String? _pendingEmail;

  // 테마 색상 (로그인 페이지와 동일)
  static const Color _primaryColor = Color(0xFFE53935);

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _handleSignUp() async {
    if (!_formKey.currentState!.validate()) return;

    final authService = context.read<AuthService>();
    final result = await authService.signUp(
      email: _emailController.text.trim(),
      password: _passwordController.text,
      name: _nameController.text.trim(),
      phoneNumber: _phoneController.text.trim(),
    );

    if (result != null && mounted) {
      if (result.isSignUpComplete) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('회원가입이 완료되었습니다. 로그인하세요.'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      } else {
        setState(() {
          _isVerificationStep = true;
          _pendingEmail = _emailController.text.trim();
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('인증 코드가 이메일로 발송되었습니다.'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } else if (mounted && authService.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(authService.errorMessage!),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _handleVerification() async {
    if (_codeController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('인증 코드를 입력하세요.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final authService = context.read<AuthService>();
    final success = await authService.confirmSignUp(
      _pendingEmail!,
      _codeController.text.trim(),
    );

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('이메일 인증이 완료되었습니다. 로그인하세요.'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.pop(context);
    } else if (mounted && authService.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(authService.errorMessage!),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _resendCode() async {
    if (_pendingEmail == null) return;

    final authService = context.read<AuthService>();
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final success = await authService.resendSignUpCode(_pendingEmail!);

    if (mounted) {
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text(success ? '인증 코드가 재발송되었습니다.' : (authService.errorMessage ?? '재발송 실패')),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  /// 입력 필드 스타일 (웹에서 텍스트 겹침 방지용 시스템 폰트)
  static const TextStyle _inputTextStyle = TextStyle(
    fontSize: 15,
    fontFamily: null, // 시스템 기본 폰트
    letterSpacing: 0,
  );

  /// 입력 필드 데코레이션 빌더
  InputDecoration _buildInputDecoration({
    required String label,
    required String hint,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        color: Colors.grey[400],
        fontFamily: null,
      ),
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
      suffixIcon: suffixIcon,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          _isVerificationStep ? '이메일 인증' : '회원가입',
          style: const TextStyle(
            color: Colors.black87,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
      ),
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
                child: _isVerificationStep
                    ? _buildVerificationForm()
                    : _buildSignUpForm(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSignUpForm() {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 헤더
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.person_add_outlined, size: 32, color: _primaryColor),
              const SizedBox(width: 8),
              Text(
                '회원가입',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: _primaryColor,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '계정을 생성하여 서비스를 이용하세요',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 32),

          // 이름 입력
          Text(
            '이름 (선택)',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[700],
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _nameController,
            textInputAction: TextInputAction.next,
            style: _inputTextStyle,
            decoration: _buildInputDecoration(
              label: '이름',
              hint: '이름 입력 (선택사항)',
            ),
          ),
          const SizedBox(height: 20),

          // 이메일 입력
          Text(
            '이메일',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[700],
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            style: _inputTextStyle,
            decoration: _buildInputDecoration(
              label: '이메일',
              hint: '이메일 주소 입력',
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return '이메일을 입력하세요';
              }
              if (!value.contains('@')) {
                return '올바른 이메일 형식이 아닙니다';
              }
              return null;
            },
          ),
          const SizedBox(height: 20),

          // 연락처 입력
          Text(
            '연락처 (선택)',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[700],
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
            style: _inputTextStyle,
            decoration: _buildInputDecoration(
              label: '연락처',
              hint: '하이픈(-) 없이 숫자만 입력',
            ),
            validator: (value) {
              if (value != null && value.isNotEmpty) {
                // 숫자만 추출
                final digitsOnly = value.replaceAll(RegExp(r'[^0-9]'), '');
                if (digitsOnly.length < 10 || digitsOnly.length > 11) {
                  return '올바른 연락처 형식이 아닙니다';
                }
              }
              return null;
            },
          ),
          const SizedBox(height: 20),

          // 비밀번호 입력
          Text(
            '비밀번호',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[700],
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            obscuringCharacter: '•',
            textInputAction: TextInputAction.next,
            style: _inputTextStyle,
            decoration: _buildInputDecoration(
              label: '비밀번호',
              hint: '8자 이상 입력',
              suffixIcon: IconButton(
                icon: Icon(
                  _obscurePassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: Colors.grey[500],
                  size: 20,
                ),
                onPressed: () {
                  setState(() {
                    _obscurePassword = !_obscurePassword;
                  });
                },
              ),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return '비밀번호를 입력하세요';
              }
              if (value.length < 8) {
                return '비밀번호는 8자 이상이어야 합니다';
              }
              return null;
            },
          ),
          const SizedBox(height: 20),

          // 비밀번호 확인
          Text(
            '비밀번호 확인',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey[700],
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _confirmPasswordController,
            obscureText: _obscureConfirmPassword,
            obscuringCharacter: '•',
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _handleSignUp(),
            style: _inputTextStyle,
            decoration: _buildInputDecoration(
              label: '비밀번호 확인',
              hint: '비밀번호 재입력',
              suffixIcon: IconButton(
                icon: Icon(
                  _obscureConfirmPassword
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: Colors.grey[500],
                  size: 20,
                ),
                onPressed: () {
                  setState(() {
                    _obscureConfirmPassword = !_obscureConfirmPassword;
                  });
                },
              ),
            ),
            validator: (value) {
              if (value == null || value.isEmpty) {
                return '비밀번호 확인을 입력하세요';
              }
              if (value != _passwordController.text) {
                return '비밀번호가 일치하지 않습니다';
              }
              return null;
            },
          ),
          const SizedBox(height: 32),

          // 회원가입 버튼
          Consumer<AuthService>(
            builder: (context, auth, child) {
              return ElevatedButton(
                onPressed: auth.isLoading ? null : _handleSignUp,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: _primaryColor,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: _primaryColor.withValues(alpha: 0.6),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: auth.isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text(
                        '회원가입',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
              );
            },
          ),
          const SizedBox(height: 16),

          // 로그인 링크
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '이미 계정이 있으신가요?',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[600],
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  '로그인',
                  style: TextStyle(
                    fontSize: 13,
                    color: _primaryColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVerificationForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 헤더 아이콘
        Icon(
          Icons.mark_email_read_outlined,
          size: 48,
          color: _primaryColor,
        ),
        const SizedBox(height: 16),
        const Text(
          '이메일 인증',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '$_pendingEmail로\n인증 코드가 발송되었습니다.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey[600],
            height: 1.5,
          ),
        ),
        const SizedBox(height: 32),

        // 인증 코드 입력
        Text(
          '인증 코드',
          style: TextStyle(
            fontSize: 13,
            color: Colors.grey[700],
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 24,
            letterSpacing: 8,
            fontWeight: FontWeight.w600,
            fontFamily: null, // 시스템 기본 폰트
          ),
          decoration: _buildInputDecoration(
            label: '인증 코드',
            hint: '000000',
          ),
        ),
        const SizedBox(height: 32),

        // 인증 버튼
        Consumer<AuthService>(
          builder: (context, auth, child) {
            return ElevatedButton(
              onPressed: auth.isLoading ? null : _handleVerification,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: _primaryColor,
                foregroundColor: Colors.white,
                disabledBackgroundColor: _primaryColor.withValues(alpha: 0.6),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: auth.isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      '인증 완료',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            );
          },
        ),
        const SizedBox(height: 16),

        // 코드 재발송
        Consumer<AuthService>(
          builder: (context, auth, child) {
            return TextButton(
              onPressed: auth.isLoading ? null : _resendCode,
              child: Text(
                '인증 코드 재발송',
                style: TextStyle(
                  color: Colors.grey[600],
                  decoration: TextDecoration.underline,
                ),
              ),
            );
          },
        ),

        // 이메일 변경
        TextButton(
          onPressed: () {
            setState(() {
              _isVerificationStep = false;
              _pendingEmail = null;
              _codeController.clear();
            });
          },
          child: Text(
            '이메일 변경',
            style: TextStyle(
              color: _primaryColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
