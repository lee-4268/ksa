import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:http/http.dart' as http;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/auth_service.dart';
import '../../services/callname_service.dart';
import '../../services/inspection_service.dart';
import '../../widgets/progress_dialog.dart';
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

  // 지오코딩
  bool _geocoding = false;
  String? _geocodeResult;

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

  Future<void> _runGeocode() async {
    final year = DateTime.now().year;
    setState(() { _geocoding = true; _geocodeResult = null; });
    try {
      final result = await _inspSvc.geocodeTargets(year);
      final updated = result['updated'] as int? ?? 0;
      final total   = result['total']   as int? ?? 0;
      if (mounted) setState(() => _geocodeResult = '$year년 $updated/$total 건 좌표 업데이트 완료');
    } catch (e) {
      if (mounted) setState(() => _geocodeResult = '오류: $e');
    } finally {
      if (mounted) setState(() => _geocoding = false);
    }
  }

  /// dart:html로 직접 파일 선택 — FilePicker 패키지의 웹 불안정 이슈 우회
  Future<({String name, Uint8List bytes})?> _pickXlsxFile() {
    final completer = Completer<({String name, Uint8List bytes})?>();
    final input = html.FileUploadInputElement()..accept = '.xlsx';

    input.onChange.listen((_) {
      final files = input.files;
      if (files == null || files.isEmpty) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }
      final reader = html.FileReader();
      reader.onLoadEnd.listen((_) {
        final data = reader.result;
        if (data is List<int>) {
          completer.complete((name: files[0]!.name, bytes: Uint8List.fromList(data)));
        } else {
          if (!completer.isCompleted) completer.complete(null);
        }
      });
      reader.readAsArrayBuffer(files[0]!);
    });

    input.click();
    return completer.future;
  }

  Future<void> _importKcaFile() async {
    if (_kcaImporting) return;

    // 1) dart:html로 직접 파일 선택 — 안정적
    final result = await _pickXlsxFile();
    if (!mounted) return;
    if (result == null) return;

    // 2) 파일 선택 후 연도 확인 다이얼로그
    final fileName = result.name;
    final fileBytes = result.bytes;
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
          Text('선택된 파일: $fileName',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          Text('${(fileBytes.length / 1024 / 1024).toStringAsFixed(1)} MB',
              style: const TextStyle(fontSize: 12, color: Colors.black45)),
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
            child: const Text('업로드 시작'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final year = int.tryParse(yearCtrl.text) ?? DateTime.now().year;

    // 3) 업로드 시작
    _inspSvc.setAuthToken(context.read<AuthService>().authToken);
    setState(() { _kcaImporting = true; _kcaProgress = 0; _kcaStage = '업로드 중...'; });
    try {
      final s3Key = await _inspSvc.uploadRaw(fileBytes, fileName);
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
          // 스테이징 완료 → 필터링 다이얼로그 열기
          if (mounted) {
            setState(() { _kcaImporting = false; _kcaProgress = 0; _kcaStage = ''; });
            final confirmed = await showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (ctx) => _KcaStagingFilterDialog(
                inspSvc: _inspSvc,
                year: year,
              ),
            );
            if (confirmed == true) {
              if (mounted) { final d = ProgressDialog(context); await d.complete(message: '수검대상 Import 완료'); }
              _loadKcaMeta();
            }
          }
          return;
        } else if (status['status'] == 'error') {
          if (mounted) { final d = ProgressDialog(context); await d.error(message: 'Import 실패: ${status['stage'] ?? ''}'); }
          return;
        }
      }
      if (mounted) { final d = ProgressDialog(context); await d.error(message: '시간 초과 — 나중에 확인하세요.'); }
    } catch (e) {
      if (mounted) { final d = ProgressDialog(context); await d.error(message: '오류: $e'); }
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
      if (mounted) { final d = ProgressDialog(context); await d.error(message: '미리보기 실패: $e'); }
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
            final d = ProgressDialog(context);
            await d.complete(message: msg);
            _loadDbStatus();
          }
          break;
        } else if (status == 'failed') {
          if (mounted) {
            final d = ProgressDialog(context);
            await d.error(message: stage);
          }
          break;
        }
      }
    } catch (e) {
      if (mounted) { final d = ProgressDialog(context); await d.error(message: '업로드 실패: $e'); }
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
        final d = ProgressDialog(context);
        await d.error(message: '미리볼 데이터가 없습니다.');
        return;
      }

      showDialog(
        context: context,
        builder: (ctx) => _DataPreviewDialog(files: files),
      );
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        final d = ProgressDialog(context);
        await d.error(message: '미리보기 실패: $e');
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
      backgroundColor: const Color(0xFFFAFAFB),
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

          // 메뉴 사용 통계 (최고 관리자만)
          if (authService.userRole == AppUserRole.superAdmin)
            _buildMenuCard(
              icon: Icons.analytics_outlined,
              iconColor: Colors.indigo,
              title: '메뉴 사용 통계',
              subtitle: '사용자별/메뉴별 접속 현황',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const MenuUsageStatsScreen(),
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
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _geocoding ? null : _runGeocode,
                    icon: _geocoding
                        ? const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.location_on_outlined, size: 18),
                    label: const Text('좌표 갱신'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.blue,
                      side: const BorderSide(color: Colors.blue),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ]),
              if (_geocodeResult != null) ...[
                const SizedBox(height: 8),
                Text(_geocodeResult!,
                    style: TextStyle(
                        fontSize: 12,
                        color: _geocodeResult!.startsWith('오류') ? Colors.red : Colors.green.shade700)),
              ],
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

// ── 스테이징 필터 다이얼로그 ───────────────────────────────

class _KcaStagingFilterDialog extends StatefulWidget {
  final InspectionService inspSvc;
  final int year;
  const _KcaStagingFilterDialog({required this.inspSvc, required this.year});

  @override
  State<_KcaStagingFilterDialog> createState() => _KcaStagingFilterDialogState();
}

class _KcaStagingFilterDialogState extends State<_KcaStagingFilterDialog> {
  static const _primary = Color(0xFFE53935);
  static const _filterableCols = [
    '분기', '국종군', '허가상태', 'kca검토결과', '시기조정',
    'skt본부', 'access담당', '품질개선팀',
    '부서', '연도주기', '검사주기', '기준연도',
    '설치장소', '도로명주소', '장치수', '통시', '공대',
  ];

  final Map<String, List<String>> _filters = {};
  final Map<String, List<Map<String, dynamic>>> _columnValues = {};
  final Set<String> _expandedFilters = {};
  final Map<String, String> _filterSearchQueries = {};
  final Map<String, bool> _loadingColumnValues = {};
  String? _selectedFilterCol;

  int? _totalRows;
  int? _filteredRows;
  bool _loadingPreview = false;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    setState(() => _loadingPreview = true);
    try {
      final res = await widget.inspSvc.getStagingPreview(widget.year, _filters);
      if (mounted) {
        setState(() {
          _totalRows = res['total'] as int? ?? 0;
          _filteredRows = res['filtered'] as int? ?? 0;
          _loadingPreview = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingPreview = false);
    }
  }

  void _addFilter(String column) {
    setState(() {
      _filters[column] = [];
      _expandedFilters.add(column);
      _selectedFilterCol = null;
    });
    _loadColumnValuesAsync(column);
  }

  Future<void> _loadColumnValuesAsync(String column) async {
    if (_columnValues.containsKey(column)) return;
    setState(() => _loadingColumnValues[column] = true);
    try {
      final values = await widget.inspSvc.getStagingColumnValues(widget.year, column);
      if (!mounted) return;
      setState(() {
        _columnValues[column] = values;
        _filters[column] = values.map((v) => v['value'] as String? ?? '').toList();
        _loadingColumnValues.remove(column);
      });
      _loadPreview();
    } catch (_) {
      if (mounted) setState(() => _loadingColumnValues.remove(column));
    }
  }

  void _updatePreview() {
    _loadPreview();
  }

  Future<void> _confirm() async {
    setState(() => _confirming = true);
    try {
      await widget.inspSvc.confirmStaging(widget.year, _filters);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        final d = ProgressDialog(context);
        await d.error(message: '확정 실패: $e');
        setState(() => _confirming = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final availableCols = _filterableCols.where((c) => !_filters.containsKey(c)).toList();

    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 헤더
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF5F7FA),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.filter_list, color: _primary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('수검대상 필터 설정 (${widget.year}년)',
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text('Import된 데이터를 필터링하여 수검대상을 확정합니다.',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _confirming ? null : () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
            ),

            // 필터 미리보기
            Container(
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F4FF),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFBBDEFB)),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 18, color: Colors.blue.shade700),
                  const SizedBox(width: 10),
                  _loadingPreview
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : Expanded(
                          child: Text(
                            '전체 ${_fmtN(_totalRows ?? 0)}건 중 ${_fmtN(_filteredRows ?? 0)}건 선택됨',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.blue.shade800),
                          ),
                        ),
                ],
              ),
            ),

            // 필터 추가 드롭다운
            if (availableCols.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.grey.shade300),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            isDense: true,
                            icon: Icon(Icons.arrow_drop_down, color: _primary, size: 20),
                            dropdownColor: Colors.white,

                            borderRadius: BorderRadius.circular(12),
                            style: const TextStyle(color: Colors.black87, fontSize: 13),
                            hint: const Text('필터 추가할 컬럼 선택...', style: TextStyle(fontSize: 13)),
                            value: _selectedFilterCol,
                            items: availableCols.map((c) =>
                                DropdownMenuItem(value: c, child: Text(c))).toList(),
                            onChanged: (col) {
                              if (col != null) _addFilter(col);
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // 필터 목록 (스크롤)
            Expanded(
              child: _filters.isEmpty
                  ? Center(
                      child: Text('필터를 추가하지 않으면 전체 데이터가 Import됩니다.',
                          style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      children: _filters.keys.map((col) => _buildFilterGroup(col)).toList(),
                    ),
            ),

            // 하단 버튼
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _confirming ? null : () => Navigator.pop(context, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('취소'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: _confirming || _filteredRows == null || _filteredRows == 0
                          ? null
                          : _confirm,
                      icon: _confirming
                          ? const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.check, size: 18),
                      label: Text(_confirming
                          ? '확정 중...'
                          : '${_fmtN(_filteredRows ?? 0)}건 확정'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterGroup(String column) {
    final values = _columnValues[column] ?? [];
    final selected = _filters[column] ?? [];
    final isExpanded = _expandedFilters.contains(column);
    final searchQuery = _filterSearchQueries[column] ?? '';
    final isLoading = _loadingColumnValues[column] == true;

    final filteredValues = searchQuery.isEmpty
        ? values
        : values.where((v) => (v['value'] as String? ?? '')
            .toLowerCase().contains(searchQuery.toLowerCase())).toList();

    final selectedCount = selected.length;
    final totalCount = values.length;

    final visibleValues = filteredValues.map((v) => v['value'] as String? ?? '').toList();
    final visibleCheckedCount = visibleValues.where((v) => selected.contains(v)).length;
    final allVisibleSelected = visibleValues.isNotEmpty && visibleCheckedCount == visibleValues.length;
    final someVisibleSelected = visibleCheckedCount > 0 && visibleCheckedCount < visibleValues.length;

    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() {
              if (isExpanded) { _expandedFilters.remove(column); }
              else { _expandedFilters.add(column); }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                      size: 20, color: Colors.grey.shade600),
                  const SizedBox(width: 4),
                  Expanded(child: Text(column,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('$selectedCount / $totalCount개 선택',
                        style: TextStyle(fontSize: 11, color: _primary)),
                  ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () {
                      setState(() {
                        _filters.remove(column);
                        _expandedFilters.remove(column);
                        _filterSearchQueries.remove(column);
                      });
                      _updatePreview();
                    },
                    child: Icon(Icons.close, size: 18, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                decoration: InputDecoration(
                  hintText: '검색...',
                  hintStyle: const TextStyle(fontSize: 13),
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (q) => setState(() => _filterSearchQueries[column] = q),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                tristate: true,
                title: const Text('(모두 선택)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                value: allVisibleSelected ? true : someVisibleSelected ? null : false,
                onChanged: (_) {
                  setState(() {
                    final newSelected = Set<String>.from(selected);
                    if (allVisibleSelected) {
                      newSelected.removeAll(visibleValues);
                    } else {
                      newSelected.addAll(visibleValues);
                    }
                    _filters[column] = newSelected.toList();
                  });
                  _updatePreview();
                },
              ),
            ),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: isLoading || values.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: 20, height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(height: 8),
                          Text('값 로딩 중...', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                        ],
                      )),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: filteredValues.length,
                      itemBuilder: (_, i) {
                        final v = filteredValues[i];
                        final val = v['value'] as String? ?? '';
                        final count = v['count'] as int? ?? 0;
                        final checked = selected.contains(val);
                        return CheckboxListTile(
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(val.isEmpty ? '(빈 값)' : val,
                              style: TextStyle(
                                fontSize: 13,
                                fontStyle: val.isEmpty ? FontStyle.italic : FontStyle.normal,
                              )),
                          secondary: Text(_fmtN(count),
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                          value: checked,
                          onChanged: (v) {
                            setState(() {
                              if (v == true) { selected.add(val); }
                              else { selected.remove(val); }
                              _filters[column] = List.from(selected);
                            });
                            _updatePreview();
                          },
                        );
                      },
                    ),
            ),
          ],
        ],
      ),
    );
  }

  static String _fmtN(int n) => n.toString()
      .replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
}

// ═══════════════════════════════════════════════════════════════
// 메뉴 사용 통계 화면
// ═══════════════════════════════════════════════════════════════

class MenuUsageStatsScreen extends StatefulWidget {
  const MenuUsageStatsScreen({super.key});

  @override
  State<MenuUsageStatsScreen> createState() => _MenuUsageStatsScreenState();
}

class _MenuUsageStatsScreenState extends State<MenuUsageStatsScreen> {
  bool _loading = true;
  int _days = 30;
  List<Map<String, dynamic>> _menuCounts = [];
  List<Map<String, dynamic>> _userCounts = [];
  List<Map<String, dynamic>> _daily = [];

  // 디자인 컬러 팔레트
  static const _bgColor = Color(0xFFF3F4F6);
  static const _cardColor = Colors.white;
  static const _menuColor = Color(0xFF3B82F6); // 모던 블루
  static const _userColor = Color(0xFF8B5CF6); // 퍼플
  static const _dailyColor = Color(0xFF10B981); // 에메랄드 그린

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    
    try {
      final token = context.read<AuthService>().authToken;
      final uri = Uri.parse('https://api-sko-kca.skons.net/admin/menu-stats')
          .replace(queryParameters: {'days': '$_days'});
          
      final resp = await http.get(uri, headers: {
        'Authorization': 'Bearer ${token ?? ''}',
        'Content-Type': 'application/json',
      });
      
      if (resp.statusCode == 200) {
        final body = json.decode(utf8.decode(resp.bodyBytes));
        if (mounted) {
          setState(() {
            _menuCounts = List<Map<String, dynamic>>.from(body['menu_counts'] ?? []);
            _userCounts = List<Map<String, dynamic>>.from(body['user_counts'] ?? []);
            _daily = List<Map<String, dynamic>>.from(body['daily'] ?? []);
          });
        }
      }
    } catch (e) {
      debugPrint('Stats Load Error: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        title: const Text('메뉴 사용 통계', style: TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF1F2937),
        elevation: 0,
        centerTitle: false,
        actions: [
          _buildDaysDropdown(),
          const SizedBox(width: 16),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(strokeWidth: 3, color: _menuColor),
            )
          : RefreshIndicator(
              onRefresh: _load,
              color: _menuColor,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildDataCard(
                      title: '메뉴별 접속 횟수',
                      icon: Icons.dashboard_rounded,
                      iconColor: _menuColor,
                      child: _buildHorizontalList(_menuCounts, 'menu_name', _menuColor),
                    ),
                    const SizedBox(height: 16),
                    _buildDataCard(
                      title: '사용자별 접속 횟수 (Top 20)',
                      icon: Icons.people_alt_rounded,
                      iconColor: _userColor,
                      child: _buildHorizontalList(_userCounts, 'user_name', _userColor, fallbackKey: 'user_id'),
                    ),
                    const SizedBox(height: 16),
                    _buildDataCard(
                      title: '일별 접속 추이',
                      icon: Icons.insights_rounded,
                      iconColor: _dailyColor,
                      child: _buildDailyChart(),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }

  /// 상단 기간 선택 드롭다운 (세련된 버튼 스타일)
  Widget _buildDaysDropdown() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: _days,
          icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
          items: const [
            DropdownMenuItem(value: 7, child: Text('최근 7일')),
            DropdownMenuItem(value: 30, child: Text('최근 30일')),
            DropdownMenuItem(value: 90, child: Text('최근 90일')),
          ],
          onChanged: (v) {
            if (v != null && v != _days) {
              _days = v;
              _load();
            }
          },
        ),
      ),
    );
  }

  /// 섹션을 감싸는 공통 카드 위젯
  Widget _buildDataCard({
    required String title,
    required IconData icon,
    required Color iconColor,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: iconColor.withOpacity(0.1), shape: BoxShape.circle),
                child: Icon(icon, size: 20, color: iconColor),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Color(0xFF1F2937)),
              ),
            ],
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    );
  }

  /// 가로 막대 그래프 리스트 (메뉴별, 사용자별 공통)
  Widget _buildHorizontalList(List<Map<String, dynamic>> data, String labelKey, Color color, {String? fallbackKey}) {
    if (data.isEmpty) return const Center(child: Text('데이터가 없습니다.', style: TextStyle(color: Colors.grey)));

    final maxCount = (data.first['cnt'] as num?)?.toInt() ?? 1;

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: data.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final item = data[index];
        final label = item[labelKey]?.toString() ?? (fallbackKey != null ? item[fallbackKey]?.toString() : null) ?? '-';
        final count = (item['cnt'] as num?)?.toInt() ?? 0;
        final ratio = maxCount > 0 ? (count / maxCount).clamp(0.0, 1.0) : 0.0;

        return Row(
          children: [
            SizedBox(
              width: 100,
              child: Text(
                label,
                style: const TextStyle(fontSize: 13, color: Color(0xFF4B5563), fontWeight: FontWeight.w500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  Container(
                    height: 12,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  FractionallySizedBox(
                    widthFactor: ratio == 0 ? 0.01 : ratio,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutCubic,
                      height: 12,
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 40,
              child: Text(
                '$count',
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1F2937)),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 일별 접속 추이 (세로 막대 그래프)
  Widget _buildDailyChart() {
    if (_daily.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(20), child: Text('데이터가 없습니다.', style: TextStyle(color: Colors.grey))));

    // 반복문 밖에서 최대값 한 번만 계산하여 성능 최적화
    final maxDailyCnt = _daily.fold<int>(1, (m, e) {
      final v = (e['cnt'] as num?)?.toInt() ?? 0;
      return v > m ? v : m;
    });

    return SizedBox(
      height: 180,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: _daily.map((d) {
          final cnt = (d['cnt'] as num?)?.toInt() ?? 0;
          final heightRatio = maxDailyCnt > 0 ? (cnt / maxDailyCnt) : 0.0;
          final displayHeight = (heightRatio * 130).clamp(4.0, 130.0);
          
          String dayStr = d['day']?.toString() ?? '';
          if (dayStr.length >= 5) dayStr = dayStr.substring(5).replaceFirst('-', '/'); // "MM/DD" 형태

          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    cnt > 0 ? '$cnt' : '', // 0일 경우 숫자 숨김 처리
                    style: const TextStyle(fontSize: 10, color: Color(0xFF6B7280), fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 600),
                    curve: Curves.easeOutBack,
                    height: displayHeight,
                    width: double.infinity,
                    constraints: const BoxConstraints(maxWidth: 24),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _dailyColor.withOpacity(0.7),
                          _dailyColor,
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    dayStr,
                    style: const TextStyle(fontSize: 9, color: Color(0xFF9CA3AF)),
                    maxLines: 1,
                    overflow: TextOverflow.visible,
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
