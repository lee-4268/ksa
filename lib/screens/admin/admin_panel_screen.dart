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
  String? _dbStatusText;
  List<dynamic> _dbFiles = [];
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
        final fileCount = status['file_count'] as int? ?? 0;
        final totalSize = status['total_size'] as int? ?? 0;
        final files = status['files'] as List<dynamic>? ?? [];
        setState(() {
          _dbFiles = files;
          if (fileCount == 0) {
            _dbStatusText = '업로드된 파일 없음';
          } else {
            _dbStatusText = '파일 $fileCount개 (${_formatBytes(totalSize)})';
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _dbStatusText = '조회 실패');
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

  Future<void> _showDataPreview() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final preview = await _callnameService.getDbPreview(limit: 50);
      if (!mounted) return;
      Navigator.pop(context); // 로딩 닫기

      final files = preview['files'] as List<dynamic>? ?? [];
      if (files.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('미리볼 데이터가 없습니다.')),
        );
        return;
      }

      showDialog(
        context: context,
        builder: (ctx) => _DataPreviewDialog(files: files),
      );
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('미리보기 실패: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
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
                        _dbStatusText ?? '로딩 중...',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            // 파일 목록
            if (_dbFiles.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...(_dbFiles.map((f) {
                final name = f['name'] as String? ?? '';
                final size = f['size'] as int? ?? 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(Icons.description_outlined, size: 14, color: Colors.grey.shade500),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        _formatBytes(size),
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                );
              })),
            ],
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
              Column(
                children: [
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
                  if (_dbFiles.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _showDataPreview,
                        icon: const Icon(Icons.visibility_outlined, size: 18),
                        label: const Text('데이터 미리보기'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.blue.shade700,
                        ),
                      ),
                    ),
                  ],
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

/// 데이터 미리보기 다이얼로그
class _DataPreviewDialog extends StatelessWidget {
  final List<dynamic> files;

  const _DataPreviewDialog({required this.files});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 900,
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 헤더
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Row(
                children: [
                  Icon(Icons.visibility, color: Colors.blue.shade700, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '호출명칭 DB 미리보기 (최대 50행)',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: Colors.blue.shade700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            // 내용
            Flexible(
              child: DefaultTabController(
                length: files.length,
                child: Column(
                  children: [
                    if (files.length > 1)
                      TabBar(
                        isScrollable: true,
                        labelColor: Colors.blue.shade700,
                        tabs: files.map((f) {
                          final name = f['name'] as String? ?? '';
                          return Tab(text: name.length > 30 ? '${name.substring(0, 30)}...' : name);
                        }).toList(),
                      ),
                    Expanded(
                      child: TabBarView(
                        children: files.map((f) {
                          final headers = (f['headers'] as List<dynamic>?)
                                  ?.map((h) => h.toString())
                                  .toList() ??
                              [];
                          final rows = (f['rows'] as List<dynamic>?)
                                  ?.map((r) => (r as List<dynamic>)
                                      .map((c) => c.toString())
                                      .toList())
                                  .toList() ??
                              [];
                          final count = f['preview_count'] as int? ?? 0;

                          if (headers.isEmpty) {
                            return const Center(child: Text('데이터 없음'));
                          }

                          return Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  '$count행 표시',
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                ),
                              ),
                              Expanded(
                                child: Scrollbar(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: SingleChildScrollView(
                                      child: DataTable(
                                        headingRowHeight: 36,
                                        dataRowMinHeight: 28,
                                        dataRowMaxHeight: 36,
                                        columnSpacing: 16,
                                        headingTextStyle: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                          color: Colors.black87,
                                        ),
                                        dataTextStyle: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.black87,
                                        ),
                                        columns: headers
                                            .map((h) => DataColumn(label: Text(h)))
                                            .toList(),
                                        rows: rows.map((row) {
                                          return DataRow(
                                            cells: List.generate(headers.length, (i) {
                                              final val = i < row.length ? row[i] : '';
                                              return DataCell(
                                                ConstrainedBox(
                                                  constraints: const BoxConstraints(maxWidth: 200),
                                                  child: Text(
                                                    val,
                                                    overflow: TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              );
                                            }),
                                          );
                                        }).toList(),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
