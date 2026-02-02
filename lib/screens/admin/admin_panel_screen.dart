import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/auth_service.dart';
import '../../services/admin_service.dart';
import 'user_approval_screen.dart';
import 'audit_log_screen.dart';
import 'team_management_screen.dart';

/// 관리자 패널 화면
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final adminService = context.read<AdminService>();
    await adminService.loadPendingUsers();
  }

  @override
  Widget build(BuildContext context) {
    final authService = context.watch<AuthService>();
    final adminService = context.watch<AdminService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('관리자 패널'),
        backgroundColor: const Color(0xFFE53935),
        foregroundColor: Colors.white,
      ),
      body: RefreshIndicator(
        onRefresh: _loadData,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 현재 관리자 정보
            _buildAdminInfoCard(authService),
            const SizedBox(height: 24),

            // 메뉴 섹션
            const Text(
              '관리 메뉴',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),

            // 사용자 승인 관리
            _buildMenuCard(
              icon: Icons.person_add,
              iconColor: Colors.orange,
              title: '사용자 승인 관리',
              subtitle: '승인 대기 중인 사용자: ${adminService.pendingCount}명',
              badge: adminService.pendingCount > 0 ? adminService.pendingCount : null,
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const UserApprovalScreen(),
                  ),
                );
              },
            ),

            // 팀 관리 (최고 관리자만)
            if (authService.isSuperAdmin)
              _buildMenuCard(
                icon: Icons.groups,
                iconColor: Colors.blue,
                title: '팀 관리',
                subtitle: '본부 및 팀 생성, 멤버 관리',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const TeamManagementScreen(),
                    ),
                  );
                },
              ),

            // 감사 로그
            _buildMenuCard(
              icon: Icons.history,
              iconColor: Colors.purple,
              title: '감사 로그',
              subtitle: '데이터 변경 이력 조회',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AuditLogScreen(),
                  ),
                );
              },
            ),

            // 전체 사용자 관리 (본부 관리자 이상만)
            if (authService.isDivisionAdmin)
              _buildMenuCard(
                icon: Icons.manage_accounts,
                iconColor: Colors.teal,
                title: '사용자 관리',
                subtitle: '전체 사용자 목록 및 권한 관리',
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const UserApprovalScreen(showAllUsers: true),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminInfoCard(AuthService authService) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 30,
              backgroundColor: const Color(0xFFE53935).withValues(alpha: 0.1),
              child: const Icon(
                Icons.admin_panel_settings,
                size: 32,
                color: Color(0xFFE53935),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    authService.userName ?? authService.userEmail ?? '관리자',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _getRoleName(authService.userRole),
                    style: TextStyle(
                      color: Colors.grey[600],
                    ),
                  ),
                  if (authService.currentTeamName != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      '${authService.currentDivisionName ?? ''} - ${authService.currentTeamName}',
                      style: TextStyle(
                        color: Colors.grey[500],
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    int? badge,
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Stack(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor),
            ),
            if (badge != null && badge > 0)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    color: Colors.red,
                    shape: BoxShape.circle,
                  ),
                  constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                  child: Text(
                    badge > 99 ? '99+' : badge.toString(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
          ],
        ),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  String _getRoleName(AppUserRole role) {
    switch (role) {
      case AppUserRole.superAdmin:
        return '최고 관리자';
      case AppUserRole.divisionAdmin:
        return '본부 관리자';
      case AppUserRole.teamAdmin:
        return '팀 관리자';
      case AppUserRole.member:
        return '일반 멤버';
    }
  }
}
