import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';

/// 사용자 프로필 버튼 - 탭하면 사용자 정보 + 로그아웃 팝업 표시
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

  void _showProfilePopup(BuildContext context, AuthService auth) {
    final RenderBox button = context.findRenderObject() as RenderBox;
    final Offset offset = button.localToGlobal(Offset.zero);
    final Size size = button.size;

    showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (dialogContext) {
        return Stack(
          children: [
            // 바깥 영역 탭하면 닫기
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.pop(dialogContext),
                child: Container(color: Colors.transparent),
              ),
            ),
            // 팝업 카드
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
                  width: 260,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 프로필 아이콘
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: Colors.grey.shade100,
                        child: Icon(
                          Icons.person,
                          size: 32,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // 이름
                      Text(
                        auth.userName ?? auth.userId ?? '',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 16),
                      // 사용자 정보 리스트
                      _buildInfoRow('사번', auth.userId),
                      _buildInfoRow('본부', auth.userDepartment),
                      _buildInfoRow('팀', auth.userTeam),
                      if (auth.userJobTitle != null)
                        _buildInfoRow('직책', auth.userJobTitle),
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

  Widget _buildInfoRow(String label, String? value) {
    if (value == null || value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
          ),
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

        return InkWell(
          onTap: () => _showProfilePopup(context, auth),
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.person_outline,
                  size: 20,
                  color: textColor,
                ),
                const SizedBox(width: 4),
                Text(
                  '$displayName님',
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w500,
                    color: textColor,
                  ),
                ),
                Icon(
                  Icons.arrow_drop_down,
                  size: 20,
                  color: textColor,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
