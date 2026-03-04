import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/auth_service.dart';
import '../../services/callname_service.dart';
import 'user_management_screen.dart';
import 'audit_log_screen.dart';

/// 관리자 패널 화면 (간소화됨 - 사내 계정 DB 연동 대비)
class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  final _callnameService = CallnameService();
  bool _dbUploading = false;
  double _uploadProgress = 0;
  String _uploadStage = '';
  String? _dbStatus;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final token = context.read<AuthService>().authToken;
      _callnameService.setAuthToken(token);
      _loadDbStatus();
    }
  }

  Future<void> _loadDbStatus() async {
    try {
      final status = await _callnameService.getDbStatus();
      if (mounted) {
        final rows = status['rows'] as int? ?? 0;
        final loaded = status['loaded'] as bool? ?? false;
        setState(() {
          _dbStatus = loaded ? '${_formatNumber(rows)}행 로드됨' : '미로드';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _dbStatus = '조회 실패');
    }
  }

  Future<void> _uploadDbFile({required bool replace}) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx', 'xls'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;

    setState(() {
      _dbUploading = true;
      _uploadProgress = 0;
      _uploadStage = '업로드 준비 중...';
    });
    try {
      final resp = await _callnameService.uploadDbFile(
        Uint8List.fromList(file.bytes!),
        file.name,
        replace: replace,
        onProgress: (stage, progress) {
          if (mounted) {
            setState(() {
              _uploadStage = stage;
              _uploadProgress = progress;
            });
          }
        },
      );
      final msg = resp['message'] as String? ?? '업로드 완료';
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.green),
        );
        _loadDbStatus();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('업로드 실패: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _dbUploading = false;
          _uploadProgress = 0;
          _uploadStage = '';
        });
      }
    }
  }

  String _formatNumber(int n) {
    return n.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
  }

  @override
  Widget build(BuildContext context) {
    final authService = context.watch<AuthService>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('관리자 패널'),
        backgroundColor: const Color(0xFFE53935),
        foregroundColor: Colors.white,
      ),
      body: ListView(
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

          // 사용자 관리 (권한 설정)
          _buildMenuCard(
            icon: Icons.manage_accounts,
            iconColor: Colors.teal,
            title: '사용자 관리',
            subtitle: '사용자 권한 설정 및 관리',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const UserManagementScreen(),
                ),
              );
            },
          ),

          // 감사 로그 (최고 관리자만)
          if (authService.userRole == AppUserRole.superAdmin)
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

          // 호출명칭 DB 관리 (최고 관리자만)
          if (authService.userRole == AppUserRole.superAdmin)
            _buildCallnameDbCard(),
        ],
      ),
    );
  }

  Widget _buildCallnameDbCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.storage, color: Colors.orange),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('호출명칭 DB 관리',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                      const SizedBox(height: 2),
                      Text(
                        _dbStatus ?? '로딩 중...',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              '호출명칭 매칭에 사용되는 DB 파일을 업데이트합니다.\nCSV/Excel 파일을 업로드할 수 있습니다.',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
            const SizedBox(height: 12),
            if (_dbUploading)
              Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _uploadProgress > 0 ? _uploadProgress : null,
                      minHeight: 6,
                      backgroundColor: Colors.orange.shade100,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.orange.shade600),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _uploadStage,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _uploadDbFile(replace: false),
                      icon: const Icon(Icons.add_circle_outline, size: 18),
                      label: const Text('파일 추가'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orange.shade700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _uploadDbFile(replace: true),
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      label: const Text('전체 교체'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade600,
                      ),
                    ),
                  ),
                ],
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
    required VoidCallback onTap,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: iconColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: iconColor),
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
