import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';

/// 사용자 프로필 버튼 - AppBar 오른쪽에 사용자 정보 표시 + 팝업
class UserProfileButton extends StatelessWidget {
  final VoidCallback onLogout;
  final Color textColor;
  final double fontSize;

  const UserProfileButton({
    super.key,
    required this.onLogout,
    this.textColor = Colors.black87,
    this.fontSize = 13,
  });

  static String _roleLabel(String role) {
    switch (role) {
      case 'admin':
        return '관리자';
      case 'manager':
        return '매니저';
      default:
        return '일반';
    }
  }

  static Color _roleColor(String role) {
    switch (role) {
      case 'admin':
        return const Color(0xFFE53935);
      case 'manager':
        return const Color(0xFF5C6BC0);
      default:
        return const Color(0xFF78909C);
    }
  }

  void _showProfilePopup(BuildContext context, AuthService auth) {
    final RenderBox button = context.findRenderObject() as RenderBox;
    final Offset offset = button.localToGlobal(Offset.zero);
    final Size size = button.size;
    final role = auth.userRoleStr;

    showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (dialogContext) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.pop(dialogContext),
                child: Container(color: Colors.transparent),
              ),
            ),
            Positioned(
              top: offset.dy + size.height + 4,
              right: MediaQuery.of(context).size.width -
                  offset.dx -
                  size.width,
              child: Material(
                elevation: 8,
                borderRadius: BorderRadius.circular(12),
                shadowColor: Colors.black26,
                child: Container(
                  width: 280,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 프로필 헤더
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 24,
                            backgroundColor: _roleColor(role).withValues(alpha: 0.1),
                            child: Icon(
                              Icons.person,
                              size: 28,
                              color: _roleColor(role),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  auth.userName ?? auth.userId ?? '',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: _roleColor(role).withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    _roleLabel(role),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: _roleColor(role),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Divider(height: 1, color: Colors.grey.shade200),
                      const SizedBox(height: 12),
                      // 상세 정보
                      _buildInfoRow(Icons.badge_outlined, '사번', auth.userId),
                      _buildInfoRow(Icons.business_outlined, '본부', auth.userDepartment),
                      _buildInfoRow(Icons.groups_outlined, '팀', auth.userTeam),
                      const SizedBox(height: 16),
                      // 로그아웃 버튼
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Navigator.pop(dialogContext);
                            onLogout();
                          },
                          icon: const Icon(Icons.logout, size: 16),
                          label: const Text('로그아웃'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade500),
          const SizedBox(width: 8),
          SizedBox(
            width: 36,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade500,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Colors.black87,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthService>(
      builder: (context, auth, _) {
        final displayName = auth.userName ?? auth.userId ?? '사용자';
        final dept = auth.userDepartment;
        final team = auth.userTeam;
        final role = auth.userRoleStr;

        // 본부/팀 요약 텍스트
        String subtitle = '';
        if (dept != null && dept.isNotEmpty) {
          subtitle = dept;
          if (team != null && team.isNotEmpty) {
            subtitle += ' / $team';
          }
        }

        return InkWell(
          onTap: () => _showProfilePopup(context, auth),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 프로필 아이콘
                CircleAvatar(
                  radius: 14,
                  backgroundColor: _roleColor(role).withValues(alpha: 0.12),
                  child: Icon(
                    Icons.person,
                    size: 16,
                    color: _roleColor(role),
                  ),
                ),
                const SizedBox(width: 10),
                // 이름 + 본부/팀
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          displayName,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                        ),
                        const SizedBox(width: 6),
                        // 권한 뱃지
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: _roleColor(role).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _roleLabel(role),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: _roleColor(role),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.expand_more,
                  size: 18,
                  color: Colors.grey.shade500,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
