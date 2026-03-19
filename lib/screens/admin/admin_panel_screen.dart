import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/auth_service.dart';
import '../../services/callname_service.dart';
import '../../services/inspection_service.dart';
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
  final _inspSvc = InspectionService();
  bool _dbUploading = false;
  double _uploadProgress = 0;
  String _uploadStage = '';
  String? _dbStatusText;
  List<dynamic> _dbFiles = [];
  bool _initialized = false;

  // KCA Import
  bool _kcaImporting = false;
  double _kcaProgress = 0;
  String _kcaStage = '';
  List<Map<String, dynamic>> _kcaMeta = [];
  bool _kcaPreviewLoading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final token = context.read<AuthService>().authToken;
      _callnameService.setAuthToken(token);
      _inspSvc.setAuthToken(token);
      _loadDbStatus();
      _loadKcaMeta();
    }
  }

  Future<void> _loadKcaMeta() async {
    try {
      final items = await _inspSvc.getMeta();
      if (mounted) setState(() => _kcaMeta = items);
    } catch (_) {}
  }

  Future<void> _importKcaFile() async {
    final yearCtrl = TextEditingController(text: '${DateTime.now().year}');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('KCA 수검대상 파일 Import',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('KCA에서 받은 수검대상 Excel 파일을 업로드합니다.\n(복사본 20XX년 정기검사...최종.xlsx)',
              style: TextStyle(fontSize: 13, color: Colors.black54)),
          const SizedBox(height: 16),
          TextField(
            controller: yearCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '검사 연도',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              isDense: true,
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE53935), foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('파일 선택'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final year = int.tryParse(yearCtrl.text) ?? DateTime.now().year;

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final file = picked.files.first;
    if (file.bytes == null) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('파일을 읽을 수 없습니다.'), backgroundColor: Colors.red));
      return;
    }

    setState(() { _kcaImporting = true; _kcaProgress = 0; _kcaStage = '업로드 중...'; });
    try {
      final s3Key = await _inspSvc.uploadRaw(file.bytes!, file.name);
      setState(() => _kcaStage = '처리 대기 중...');
      final auth = context.read<AuthService>();
      final jobId = await _inspSvc.enqueue(s3Key, year, auth.userName ?? '');

      for (var i = 0; i < 240; i++) {
        await Future.delayed(const Duration(seconds: 5));
        if (!mounted) return;
        final status = await _inspSvc.jobStatus(jobId);
        final pct = (status['percent'] as num?)?.toDouble() ?? 0;
        final stage = status['stage'] as String? ?? '';
        setState(() { _kcaProgress = pct / 100; _kcaStage = stage; });
        if (status['status'] == 'complete') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(stage), backgroundColor: Colors.green));
          }
          _loadKcaMeta();
          return;
        } else if (status['status'] == 'error') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Import 실패: ${status['stage'] ?? ''}'), backgroundColor: Colors.red));
          }
          return;
        }
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('시간 초과 — 나중에 확인하세요.'), backgroundColor: Colors.orange));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('오류: $e'), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() { _kcaImporting = false; _kcaProgress = 0; _kcaStage = ''; });
    }
  }

  Future<void> _showKcaPreview() async {
    if (_kcaMeta.isEmpty) return;
    final year = _kcaMeta.first['year'] as int? ?? DateTime.now().year;
    setState(() => _kcaPreviewLoading = true);
    try {
      final res = await _inspSvc.getData(year: year, pageSize: 50);
      if (!mounted) return;
      final items = List<Map<String, dynamic>>.from(res['items'] ?? []);
      final total = (res['total'] as num?)?.toInt() ?? 0;
      showDialog(
        context: context,
        builder: (ctx) => _KcaPreviewDialog(year: year, items: items, total: total),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('미리보기 실패: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _kcaPreviewLoading = false);
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
      _uploadStage = '서버에 파일 전송 중...';
    });
    try {
      // 1) 파일 전송 → jobId 반환
      final jobId = await _callnameService.uploadDbFile(
        Uint8List.fromList(file.bytes!),
        file.name,
        replace: replace,
      );

      // 2) 2초 간격 폴링으로 진행률 추적
      while (mounted) {
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) break;

        final job = await _callnameService.getUploadJobStatus(jobId);
        final status = job['status'] as String? ?? '';
        final stage = job['stage'] as String? ?? '';
        final percent = (job['percent'] as num?)?.toDouble() ?? 0;

        setState(() {
          _uploadStage = stage;
          _uploadProgress = percent / 100;
        });

        if (status == 'completed') {
          final result = job['result'] as Map<String, dynamic>?;
          final msg = result?['message'] as String? ?? '업로드 완료';
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(msg), backgroundColor: Colors.green),
            );
            _loadDbStatus();
          }
          break;
        } else if (status == 'failed') {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(stage), backgroundColor: Colors.red),
            );
          }
          break;
        }
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

          // KCA 수검대상 Import (관리자 이상)
          if (authService.isAdmin)
            _buildKcaImportCard(),

          // 호출명칭 DB 관리 (최고 관리자만)
          if (authService.userRole == AppUserRole.superAdmin)
            _buildCallnameDbCard(),
        ],
      ),
    );
  }

  Widget _buildKcaImportCard() {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xFFE53935).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.upload_file, color: Color(0xFFE53935)),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('KCA 수검대상 Import',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                  SizedBox(height: 2),
                  Text('정기검사 대상 Excel 파일 업로드',
                      style: TextStyle(color: Colors.grey, fontSize: 13)),
                ]),
              ),
            ]),
            if (_kcaMeta.isNotEmpty) ...[
              const SizedBox(height: 10),
              ..._kcaMeta.map((m) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Icon(Icons.check_circle_outline, size: 14, color: Colors.green.shade600),
                  const SizedBox(width: 6),
                  Text(
                    '${m['year']}년 — ${((m['total_skt'] as int? ?? 0) + (m['total_sheet1'] as int? ?? 0)).toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (x) => '${x[1]},')}행'
                    ' (정기 ${m['total_skt'] ?? 0} / 시기조정 ${m['total_sheet1'] ?? 0})',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                  const SizedBox(width: 8),
                  Text(m['imported_by'] ?? '', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                ]),
              )),
            ],
            const SizedBox(height: 12),
            if (_kcaImporting)
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _kcaProgress > 0 ? _kcaProgress : null,
                    minHeight: 6,
                    backgroundColor: Colors.red.shade100,
                    valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFE53935)),
                  ),
                ),
                const SizedBox(height: 6),
                Text(_kcaStage, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ])
            else
              Row(children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _importKcaFile,
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: Text(_kcaMeta.isEmpty ? 'Excel 파일 Import' : '재 Import'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE53935),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                if (_kcaMeta.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _kcaPreviewLoading ? null : _showKcaPreview,
                    icon: _kcaPreviewLoading
                        ? const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.table_view, size: 18),
                    label: const Text('미리보기'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFE53935),
                      side: const BorderSide(color: Color(0xFFE53935)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ]),
          ],
        ),
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
  static const Color _themeColor = Color(0xFF1565C0);

  final List<dynamic> files;

  const _DataPreviewDialog({required this.files});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: const BoxDecoration(
                color: Color(0xFFF5F7FA),
                borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: _themeColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.visibility, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    '호출명칭 DB 미리보기 (최대 50행)',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                      color: Colors.black87,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20, color: Colors.black54),
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
                      Container(
                        color: Colors.white,
                        child: TabBar(
                          isScrollable: true,
                          labelColor: _themeColor,
                          unselectedLabelColor: Colors.grey.shade600,
                          indicatorColor: _themeColor,
                          labelStyle: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          tabs: files.map((f) {
                            final name = f['name'] as String? ?? '';
                            return Tab(text: name.length > 30 ? '${name.substring(0, 30)}...' : name);
                          }).toList(),
                        ),
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
                            return const Center(
                              child: Text('데이터 없음',
                                  style: TextStyle(color: Colors.grey, fontSize: 14)),
                            );
                          }

                          return Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(10),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _themeColor.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    '$count행 표시',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: _themeColor,
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Scrollbar(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: SingleChildScrollView(
                                      child: DataTable(
                                        headingRowColor: WidgetStateProperty.all(
                                            const Color(0xFFF5F7FA)),
                                        headingRowHeight: 38,
                                        dataRowMinHeight: 30,
                                        dataRowMaxHeight: 38,
                                        columnSpacing: 16,
                                        horizontalMargin: 16,
                                        headingTextStyle: const TextStyle(
                                          fontWeight: FontWeight.w600,
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

// ── KCA 수검대상 미리보기 다이얼로그 ────────────────────────────

class _KcaPreviewDialog extends StatelessWidget {
  final int year;
  final List<Map<String, dynamic>> items;
  final int total;

  const _KcaPreviewDialog({
    required this.year,
    required this.items,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    // key → 헤더명
    const colDefs = [
      ('허가번호',    '허가번호'),
      ('호출명칭',    '호출명칭'),
      ('분기',       '분기'),
      ('국종군',      '국종군'),
      ('access담당', '본부'),
      ('품질개선팀',  '팀'),
      ('kca검토결과', 'KCA결과'),
      ('시기조정',    '시기조정'),
      ('설치장소',    '설치장소'),
      ('도로명주소',  '도로명주소'),
      ('통시',       '통시'),
      ('skt본부',    'SKT본부'),
      ('허가상태',    '허가상태'),
    ];
    const wideKeys = {'호출명칭', '설치장소', '도로명주소'};
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200, maxHeight: 640),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 헤더
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
            child: Row(children: [
              const Icon(Icons.table_view, color: Color(0xFFE53935), size: 20),
              const SizedBox(width: 8),
              Text('$year년 수검대상 미리보기',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Text('(상위 ${items.length}건 / 총 ${_fmt(total)}건)',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
          ),
          const Divider(height: 16),
          // 테이블
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: DataTable(
                  headingRowColor: WidgetStateProperty.all(Colors.grey.shade50),
                  dataRowMinHeight: 36,
                  dataRowMaxHeight: 40,
                  columnSpacing: 14,
                  headingTextStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.black54),
                  dataTextStyle: const TextStyle(fontSize: 11),
                  columns: colDefs.map((c) => DataColumn(label: Text(c.$2))).toList(),
                  rows: items.map((item) => DataRow(
                    cells: colDefs.map((c) {
                      final val = item[c.$1]?.toString() ?? '';
                      if (c.$1 == 'kca검토결과') return DataCell(_chip(val));
                      return DataCell(SizedBox(
                        width: wideKeys.contains(c.$1) ? 160 : null,
                        child: Text(val, overflow: TextOverflow.ellipsis),
                      ));
                    }).toList(),
                  )).toList(),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _chip(String val) {
    Color color = Colors.grey;
    if (val.contains('대상')) { color = const Color(0xFF43A047); }
    else if (val.contains('진행')) { color = const Color(0xFF4A90D9); }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Text(val, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }

  static String _fmt(int n) => n.toString()
      .replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
}
