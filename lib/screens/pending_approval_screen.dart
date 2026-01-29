import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';

/// 승인 대기 화면 - 관리자 승인 전까지 표시
class PendingApprovalScreen extends StatefulWidget {
  const PendingApprovalScreen({super.key});

  @override
  State<PendingApprovalScreen> createState() => _PendingApprovalScreenState();
}

class _PendingApprovalScreenState extends State<PendingApprovalScreen> {
  bool _isRefreshing = false;

  Future<void> _checkApprovalStatus() async {
    setState(() => _isRefreshing = true);

    final authService = context.read<AuthService>();
    await authService.refreshApprovalStatus();

    setState(() => _isRefreshing = false);

    if (mounted) {
      if (authService.isApproved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('승인이 완료되었습니다!'),
            backgroundColor: Colors.green,
          ),
        );
      } else if (authService.isRejected) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('가입이 거부되었습니다. 관리자에게 문의하세요.'),
            backgroundColor: Colors.red,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('아직 승인 대기 중입니다.'),
          ),
        );
      }
    }
  }

  Future<void> _handleLogout() async {
    final authService = context.read<AuthService>();
    await authService.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final authService = context.watch<AuthService>();

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // 상태 아이콘
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: authService.isRejected
                      ? Colors.red.withValues(alpha: 0.1)
                      : Colors.orange.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  authService.isRejected
                      ? Icons.cancel_outlined
                      : Icons.hourglass_empty,
                  size: 64,
                  color: authService.isRejected ? Colors.red : Colors.orange,
                ),
              ),
              const SizedBox(height: 32),

              // 제목
              Text(
                authService.isRejected ? '가입 거부됨' : '승인 대기 중',
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),

              // 설명
              Text(
                authService.isRejected
                    ? '관리자에 의해 가입이 거부되었습니다.\n자세한 내용은 관리자에게 문의하세요.'
                    : '관리자 승인 후 서비스를 이용하실 수 있습니다.\n승인이 완료되면 이 화면이 자동으로 전환됩니다.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey[600],
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),

              // 계정 정보
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    _buildInfoRow('이메일', authService.userEmail ?? '-'),
                    if (authService.userName != null) ...[
                      const Divider(),
                      _buildInfoRow('이름', authService.userName!),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 32),

              // 승인 상태 확인 버튼
              if (!authService.isRejected)
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _isRefreshing ? null : _checkApprovalStatus,
                    icon: _isRefreshing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: Text(_isRefreshing ? '확인 중...' : '승인 상태 확인'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              const SizedBox(height: 16),

              // 로그아웃 버튼
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: _handleLogout,
                  icon: const Icon(Icons.logout),
                  label: const Text('로그아웃'),
                ),
              ),

              const Spacer(),

              // 안내 메시지
              Text(
                '문의: 관리자에게 연락하여 승인을 요청하세요.',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[500],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 14,
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }
}
