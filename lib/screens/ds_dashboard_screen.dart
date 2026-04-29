import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/ds_data_service.dart';
import '../services/ds_upload_service.dart';
import '../services/ds_export_service_stub.dart'
    if (dart.library.html) '../services/ds_export_service_web.dart' as platform_export;
import 'ds_data_screen.dart';
import '../widgets/progress_dialog.dart';
import '../widgets/user_profile_button.dart';

/// DS 데이터 관리 대시보드 - 업로드 + 조회 + Export + 삭제
class DsDashboardScreen extends StatefulWidget {
  const DsDashboardScreen({super.key});

  @override
  State<DsDashboardScreen> createState() => _DsDashboardScreenState();
}

class _DsDashboardScreenState extends State<DsDashboardScreen> {
  static const Color _accentColor = Color(0xFF5C6BC0);

  /// 병합 코드 표시용: 대표코드 → "30+70" 형태
  static const _mergedCodeDisplay = {'30': '30+70', '50': '50+55'};
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  final DsDataService _dataService = DsDataService();
  final DsUploadService _uploadService = DsUploadService();

  // 통계
  bool _isLoading = true;
  String? _error;
  DsStatsResult? _stats;
  String _selectedDivision = 'all';

  // 업로드 상태
  bool _isUploading = false;
  String _uploadStage = '';
  double _uploadProgress = 0;
  String? _uploadResult;
  bool? _uploadSuccess;

  // Export 상태
  String? _exportingId; // 현재 export 중인 upload의 식별자
  String _exportStage = '';
  double _exportProgress = 0;

  // 자동 갱신 (uploading 레코드 존재 시 10초마다)
  Timer? _autoRefreshTimer;

  bool _initialized = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final authService = context.read<AuthService>();
    final token = authService.authToken;
    _dataService.setAuthToken(token);
    _uploadService.setAuthToken(token);
    _uploadService.onTokenRefreshed = (newToken) {
      authService.checkAndRefreshToken(
        http.Response('', 200, headers: {'x-refreshed-token': newToken}),
      );
    };
    if (!_initialized) {
      _initialized = true;
      _loadStats();
    }
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  void _scheduleAutoRefresh() {
    _autoRefreshTimer?.cancel();
    final hasUploading = _stats?.uploads.any((u) => u.status == 'uploading') ?? false;
    if (hasUploading) {
      _autoRefreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (mounted && !_isLoading) _loadStats();
      });
    }
  }

  Future<void> _loadStats() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final stats = await _dataService.getStats();
      if (mounted) {
        setState(() {
          _stats = stats;
          _isLoading = false;
        });
        _scheduleAutoRefresh();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _isLoading = false;
        });
      }
    }
  }

  List<DsUploadInfo> get _filteredUploads {
    if (_stats == null) return [];
    if (_selectedDivision == 'all') return _stats!.uploads;
    return _stats!.uploads.where((u) => u.divisionId == _selectedDivision).toList();
  }

  // ============================================================
  // 업로드
  // ============================================================
  Future<void> _startUpload() async {
    final authService = context.read<AuthService>();
    final uploadedBy = authService.userId ?? 'unknown';

    setState(() {
      _isUploading = true;
      _uploadStage = '시작 중...';
      _uploadProgress = 0;
      _uploadResult = null;
      _uploadSuccess = null;
    });

    try {
      final message = await _uploadService.pickAndUpload(
        uploadedBy: uploadedBy,
        onProgress: (stage, percent) {
          if (mounted) {
            setState(() {
              _uploadStage = stage;
              _uploadProgress = percent / 100;
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _isUploading = false;
          _uploadResult = message;
          _uploadSuccess = true;
        });
        _loadStats(); // 업로드 완료 후 즉시 갱신
        // DynamoDB eventual consistency 대비 3초 후 재갱신
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) _loadStats();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isUploading = false;
          _uploadResult = e.toString().replaceFirst('Exception: ', '');
          _uploadSuccess = false;
        });
        _loadStats(); // 실패 시에도 목록 갱신 (stuck 레코드 표시)
      }
    }
  }

  // ============================================================
  // Excel Export
  // ============================================================

  static const _sudoHdqts = ['강남', '강북', '경기', '인천'];
  static const Color _green = Color(0xFF43A047);

  Future<String?> _showHdqtSelectDialog(DsUploadInfo upload) async {
    // 수도권 본부(divisionCode 10)만 dialog 표시
    final isSuDo = upload.divisionCode == '10'
        || (upload.divisionName ?? '').contains('수도권');
    if (!isSuDo) return null; // 수도권 아니면 dialog 없이 전체 다운로드

    // 빌드 상태 먼저 조회
    Map<String, bool> cached = {};
    bool isBuilding = false;
    bool inQueue = false;
    String? currentHdqt;
    int? estimatedRemainingSec;
    try {
      final authToken = context.read<AuthService>().authToken;
      final uri = Uri.parse('$_baseUrl/ds/xlsx-build-status').replace(queryParameters: {
        'divisionId': upload.divisionId,
        'divisionCode': upload.divisionCode,
        'importDate': upload.actualDate,
      });
      final resp = await http.get(uri, headers: {
        if (authToken != null) 'Authorization': 'Bearer $authToken',
      }).timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        isBuilding = data['building'] == true;
        inQueue = data['in_queue'] == true;
        currentHdqt = data['current'] as String?;
        estimatedRemainingSec = data['estimated_remaining_sec'] as int?;
        final rawCached = data['cached'] as Map<String, dynamic>? ?? {};
        cached = rawCached.map((k, v) => MapEntry(k, v == true));
      }
    } catch (_) {}

    String _fmtRemaining(int? secs) {
      if (secs == null) return '';
      if (secs <= 0) return '곧 완료';
      final m = secs ~/ 60;
      final s = secs % 60;
      if (m == 0) return '약 ${s}초';
      if (s == 0) return '약 ${m}분';
      return '약 ${m}분 ${s}초';
    }

    String? selected;
    if (!mounted) return null;
    return showDialog<String?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          // 본부 선택 시 캐시 없으면 다운로드 불가 (전체는 항상 허용)
          final selectedNotCached = selected != null && selected!.isNotEmpty
              && cached[selected] == false;
          final canDownload = selected != null && !selectedNotCached;

          Widget selectChip(String label, bool isSelected, VoidCallback onTap, {bool? hasCached, bool isCurrent = false}) {
            final Color borderColor;
            final Color bgColor;
            final Color textColor;
            if (isSelected) {
              borderColor = _green;
              bgColor = _green.withOpacity(0.08);
              textColor = _green;
            } else {
              borderColor = Colors.grey.shade300;
              bgColor = Colors.grey.shade50;
              textColor = Colors.black87;
            }
            Widget? trailingIcon;
            if (isCurrent) {
              trailingIcon = const SizedBox(
                width: 10, height: 10,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.orange),
              );
            } else if (hasCached == true) {
              trailingIcon = const Icon(Icons.check_circle, size: 12, color: Color(0xFF43A047));
            } else if (hasCached == false) {
              trailingIcon = Icon(Icons.hourglass_empty, size: 12, color: Colors.grey.shade400);
            }
            return InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: borderColor, width: isSelected ? 1.5 : 1),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label, style: TextStyle(fontSize: 12, color: textColor,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                    if (trailingIcon != null) ...[
                      const SizedBox(width: 4),
                      trailingIcon,
                    ],
                  ],
                ),
              ),
            );
          }

          return AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 10),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.description_outlined, color: _green, size: 20),
                ),
                const SizedBox(width: 12),
                const Text('Excel 다운로드 옵션',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('본부 선택',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87)),
                  const SizedBox(height: 4),
                  Text('수도권 DS 파일을 본부별로 분리하여 다운로드합니다.',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  if (isBuilding || inQueue) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange.shade200),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 12, height: 12,
                              child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.orange)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              [
                                if (inQueue && !isBuilding) 'xlsx 빌드 대기 중...'
                                else if (currentHdqt != null) '$currentHdqt 본부 xlsx 빌드 중...'
                                else 'xlsx 빌드 중...',
                                if (estimatedRemainingSec != null)
                                  '(완료까지 ${_fmtRemaining(estimatedRemainingSec)} 남음)',
                              ].join(' '),
                              style: TextStyle(fontSize: 11, color: Colors.orange.shade800),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  // 선택한 본부 캐시 없을 때 경고
                  if (selectedNotCached) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.red.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.red.shade200),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, size: 15, color: Colors.red.shade700),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '$selected 본부 xlsx가 아직 준비되지 않았습니다.\n빌드 완료 후 다시 시도해 주세요.'
                              '${estimatedRemainingSec != null ? '\n예상 대기: ${_fmtRemaining(estimatedRemainingSec)}' : ''}',
                              style: TextStyle(fontSize: 11, color: Colors.red.shade800, height: 1.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  // 범례
                  Row(
                    children: [
                      const Icon(Icons.check_circle, size: 11, color: Color(0xFF43A047)),
                      const SizedBox(width: 3),
                      Text('캐시됨', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                      const SizedBox(width: 10),
                      Icon(Icons.hourglass_empty, size: 11, color: Colors.grey.shade400),
                      const SizedBox(width: 3),
                      Text('빌드 필요', style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      selectChip('전체 (분리 없음)', selected == '', () => setS(() => selected = '')),
                      ..._sudoHdqts.map((h) => selectChip(
                        h, selected == h, () => setS(() => selected = h),
                        hasCached: cached[h],
                        isCurrent: currentHdqt == h,
                      )),
                    ],
                  ),
                ],
              ),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            actions: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, null),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.grey.shade300),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text('취소',
                          style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: canDownload
                          ? () => Navigator.pop(ctx, selected)
                          : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _green,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('다운로드 시작',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _startExport(DsUploadInfo upload) async {
    // 수도권이면 본부 선택 dialog 먼저
    final isSuDo = upload.divisionCode == '10'
        || (upload.divisionName ?? '').contains('수도권');
    String? selectedHdqt;
    if (isSuDo) {
      final dlgResult = await _showHdqtSelectDialog(upload);
      if (dlgResult == null) return; // 취소
      selectedHdqt = dlgResult.isEmpty ? null : dlgResult;
    }

    final exportId = '${upload.divisionId}_${upload.actualDate}_${upload.divisionCode}';
    setState(() {
      _exportingId = exportId;
      _exportStage = '준비 중...';
      _exportProgress = 0;
    });

    try {
      final params = <String, String>{
        'divisionId': upload.divisionId,
        'importDate': upload.actualDate,
        'divisionCode': upload.divisionCode,
        if (selectedHdqt != null) 'hdqt': selectedHdqt,
      };
      final hdqtSuffix = selectedHdqt != null ? '_$selectedHdqt' : '';
      final filename = '${upload.divisionName}${hdqtSuffix}_${upload.actualDate}_DS.xlsx';

      void onProgress(String stage, double percent) {
        if (mounted) {
          setState(() {
            _exportStage = stage;
            _exportProgress = percent / 100;
          });
        }
      }

      // S3 presign 확인 → type별 분기
      final authToken = context.read<AuthService>().authToken;
      try {
        final presignUri =
            Uri.parse('$_baseUrl/ds/export-presign').replace(queryParameters: params);
        final presignResp =
            await http.get(presignUri, headers: {
              if (authToken != null) 'Authorization': 'Bearer $authToken',
            }).timeout(const Duration(seconds: 10));

        if (presignResp.statusCode == 200) {
          final data = jsonDecode(presignResp.body);

          if (data['success'] == true) {
            final type = data['type'] as String?;

            // 1. 원본 ZIP → EC2 프록시 → 브라우저 병합 (신규 업로드)
            if (type == 'zip') {
              // 서버에서 xlsx 빌드 진행 중이면 안내 후 중단 (수도권은 ZIP fallback으로 진행)
              if (data['building'] == true && !isSuDo) {
                if (mounted) {
                  setState(() => _exportingId = null);
                  final d = ProgressDialog(context);
                  await d.error(message: 'xlsx 빌드가 진행 중입니다. 잠시 후 다시 시도해 주세요.');
                }
                return;
              }
              onProgress('Excel 파일 생성 준비 중...', 3);
              // EC2 프록시 URL 사용 (S3 CORS 우회)
              final proxyUri = Uri.parse('$_baseUrl/ds/proxy-raw-zip')
                  .replace(queryParameters: params);
              final metaJson = jsonEncode({
                'divisionName': upload.divisionName,
                'divisionId': upload.divisionId,
                'divisionCode': upload.divisionCode,
                'importDate': upload.actualDate,
                if (selectedHdqt != null) 'hdqt': selectedHdqt,
              });
              final result = await platform_export.exportDsFromS3(
                s3Url: proxyUri.toString(),
                metaJson: metaJson,
                onProgress: onProgress,
                authToken: authToken,
              );
              if (mounted) {
                setState(() => _exportingId = null);
                final d = ProgressDialog(context);
                await d.complete(message: result);
              }
              return;
            }

            // 2. pre-built xlsx → EC2 프록시 다운로드
            if (type == 'xlsx') {
              onProgress('Excel 파일 다운로드 중...', 10);
              final result = await platform_export.downloadXlsxFromUrl(
                url: data['url'] as String,
                filename: filename,
                onProgress: onProgress,
                authToken: authToken,
              );
              if (mounted) {
                setState(() => _exportingId = null);
                final d = ProgressDialog(context);
                await d.complete(message: result);
              }
              return;
            }
          }
        }
      } catch (e) {
        debugPrint('S3 presign/export 실패 (서버 빌드로 전환): $e');
      }

      // 3. 폴백: 서버사이드 빌드 (/ds/export-xlsx) — old DynamoDB 데이터용
      onProgress('Excel 파일 생성 중...', 5);
      final exportUri =
          Uri.parse('$_baseUrl/ds/export-xlsx').replace(queryParameters: params);
      final result = await platform_export.downloadXlsxFromUrl(
        url: exportUri.toString(),
        filename: filename,
        onProgress: onProgress,
        authToken: authToken,
      );

      if (mounted) {
        setState(() => _exportingId = null);
        final d = ProgressDialog(context);
        await d.complete(message: result);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _exportingId = null);
        final d = ProgressDialog(context);
        await d.error(message: 'Export 실패: ${e.toString().replaceFirst("Exception: ", "")}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFB),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildErrorView()
              : RefreshIndicator(
                  onRefresh: _loadStats,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    child: Builder(builder: (ctx) {
                      final auth = ctx.watch<AuthService>();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (auth.canUpload) _buildUploadSection(),
                          if (auth.canUpload) const SizedBox(height: 20),
                          _buildDivisionFreshness(),
                          const SizedBox(height: 20),
                          _buildDivisionFilter(),
                          const SizedBox(height: 16),
                          _buildUploadList(),
                        ],
                      );
                    }),
                  ),
                ),
    );
  }

  // ============================================================
  // 업로드 섹션
  // ============================================================
  Widget _buildUploadSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 업로드 버튼
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _isUploading ? null : _startUpload,
              icon: Icon(_isUploading ? Icons.hourglass_top : Icons.cloud_upload),
              label: Text(
                _isUploading ? '업로드 진행 중...' : 'DS ZIP 파일 업로드',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF42A5F5),
                foregroundColor: Colors.white,
                disabledBackgroundColor: Colors.grey.shade300,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          // 업로드 진행률
          if (_isUploading) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: _uploadProgress == 0 ? null : _uploadProgress,
                backgroundColor: Colors.grey.shade200,
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF42A5F5)),
                minHeight: 6,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      if (_uploadProgress == 0) ...[
                        SizedBox(
                          width: 12, height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            valueColor: AlwaysStoppedAnimation<Color>(Colors.grey.shade500),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Text(
                          _uploadProgress == 0
                              ? '$_uploadStage (대용량 파일은 시간이 걸릴 수 있습니다)'
                              : _uploadStage,
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_uploadProgress > 0)
                  Text('${(_uploadProgress * 100).toInt()}%',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey.shade700)),
              ],
            ),
            const SizedBox(height: 6),
            Text('업로드가 완료될 때까지 이 화면을 유지해 주세요.',
                style: TextStyle(fontSize: 11, color: Colors.orange.shade700)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: SizedBox(
                height: 32,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await _uploadService.cancelCurrentJob();
                    if (mounted) {
                      setState(() {
                        _isUploading = false;
                        _uploadResult = '업로드가 취소되었습니다.';
                        _uploadSuccess = false;
                      });
                    }
                  },
                  icon: const Icon(Icons.cancel_outlined, size: 16),
                  label: const Text('업로드 취소', style: TextStyle(fontSize: 12)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red, width: 1),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ),
            ),
          ],
          // 업로드 결과
          if (_uploadResult != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (_uploadSuccess == true ? Colors.green : Colors.red).withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: (_uploadSuccess == true ? Colors.green : Colors.red).withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _uploadSuccess == true ? Icons.check_circle : Icons.error,
                    color: _uploadSuccess == true ? Colors.green : Colors.red,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_uploadResult!,
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade800)),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
          const SizedBox(height: 16),
          Text(_error!, style: TextStyle(color: Colors.grey.shade700)),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _loadStats,
            icon: const Icon(Icons.refresh),
            label: const Text('다시 시도'),
          ),
        ],
      ),
    );
  }

  /// 본부별 데이터 최신 현황 — 현재 달 기준으로 업데이트 필요 여부 표시
  Widget _buildDivisionFreshness() {
    final uploads = _stats?.uploads ?? [];
    final now = DateTime.now();
    final currentYm = '${now.year}${now.month.toString().padLeft(2, '0')}'; // e.g. "202603"
    final currentMonthLabel = '${now.year}년 ${now.month}월';

    // 본부별 최신 업로드 날짜 수집
    final latestByDivision = <String, DsUploadInfo>{};
    for (final u in uploads) {
      final existing = latestByDivision[u.divisionId];
      if (existing == null || u.actualDate.compareTo(existing.actualDate) > 0) {
        latestByDivision[u.divisionId] = u;
      }
    }

    // 전체 본부 목록 (데이터 없는 본부도 포함)
    final allDivisions = DsDataService.dsDivisionNames.entries.toList();

    // 업데이트 필요 본부 수
    int outdatedCount = 0;
    for (final entry in allDivisions) {
      final latest = latestByDivision[entry.key];
      if (latest == null) {
        outdatedCount++;
      } else {
        final dataYm = latest.actualDate.length >= 6 ? latest.actualDate.substring(0, 6) : '';
        if (dataYm != currentYm) outdatedCount++;
      }
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.update, size: 20, color: _accentColor),
              const SizedBox(width: 8),
              Text('본부별 데이터 현황', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '기준: $currentMonthLabel',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '※ 본부코드: 수도권 10 · 강원 40 · 경남 20 · 경북 60 · 충남 50 · 충북 55 · 전남 30 · 전북 70 · 울산 26 · 제주 80',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
          ),
          if (outdatedCount > 0) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orange.shade700),
                  const SizedBox(width: 8),
                  Text(
                    '$outdatedCount개 본부 데이터 업데이트 필요',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.orange.shade800),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          ...allDivisions.map((entry) {
            final divId = entry.key;
            final divName = entry.value;
            final latest = latestByDivision[divId];

            if (latest == null) {
              return _buildFreshnessRow(divName, null, null, currentYm);
            }

            final dataYm = latest.actualDate.length >= 6 ? latest.actualDate.substring(0, 6) : '';
            return _buildFreshnessRow(divName, latest.actualDate, dataYm, currentYm);
          }),
        ],
      ),
    );
  }

  Widget _buildFreshnessRow(String divName, String? actualDate, String? dataYm, String currentYm) {
    final bool isCurrent = dataYm == currentYm;
    final bool hasData = actualDate != null && dataYm != null;

    String monthLabel;
    if (!hasData) {
      monthLabel = '데이터 없음';
    } else {
      final year = actualDate.substring(0, 4);
      final month = actualDate.substring(4, 6);
      monthLabel = '$year년 ${int.parse(month)}월';
    }

    final Color statusColor;
    final IconData statusIcon;
    final String statusText;

    if (!hasData) {
      statusColor = Colors.grey;
      statusIcon = Icons.remove_circle_outline;
      statusText = '미등록';
    } else if (isCurrent) {
      statusColor = Colors.green;
      statusIcon = Icons.check_circle;
      statusText = '최신';
    } else {
      statusColor = Colors.orange;
      statusIcon = Icons.error_outline;
      statusText = '업데이트 필요';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: hasData && !isCurrent
              ? Colors.orange.withValues(alpha: 0.04)
              : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: hasData && !isCurrent
                ? Colors.orange.withValues(alpha: 0.2)
                : Colors.grey.shade200,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.business, size: 16, color: Colors.grey.shade500),
            const SizedBox(width: 8),
            Expanded(
              child: Text(divName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                monthLabel,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700, fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 8),
            Icon(statusIcon, size: 16, color: statusColor),
            const SizedBox(width: 4),
            Text(
              statusText,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: statusColor),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDivisionFilter() {
    return Row(
      children: [
        Icon(Icons.filter_list, size: 20, color: Colors.grey.shade600),
        const SizedBox(width: 8),
        const Text('본부 필터:', style: TextStyle(fontWeight: FontWeight.w500)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedDivision,
              isDense: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              icon: Icon(Icons.arrow_drop_down, size: 20, color: _accentColor),
              style: const TextStyle(fontSize: 13, color: Colors.black87),
              items: [
                DropdownMenuItem(
                  value: 'all',
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.select_all, size: 16, color: _accentColor),
                      const SizedBox(width: 8),
                      const Text('전체'),
                    ],
                  ),
                ),
                ...DsDataService.dsDivisionNames.entries.map((e) {
                  return DropdownMenuItem(
                    value: e.key,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.business, size: 16, color: Colors.grey.shade500),
                        const SizedBox(width: 8),
                        Text(e.value),
                      ],
                    ),
                  );
                }),
              ],
              onChanged: (v) => setState(() => _selectedDivision = v ?? 'all'),
            ),
          ),
        ),
      ],
    );
  }


  Widget _buildUploadList() {
    final uploads = _filteredUploads;

    if (uploads.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          children: [
            Icon(Icons.inbox_outlined, size: 48, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('업로드된 데이터가 없습니다', style: TextStyle(color: Colors.grey.shade500)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.list_alt, size: 20, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Text('업로드 목록 (${uploads.length}건)',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
        ]),
        const SizedBox(height: 12),
        ...uploads.map((u) => _buildUploadCard(u)),
      ],
    );
  }

  Widget _buildUploadCard(DsUploadInfo upload) {
    final isCompleted = upload.status == 'completed';
    final statusColor = isCompleted ? Colors.green : Colors.orange;
    final exportId = '${upload.divisionId}_${upload.actualDate}_${upload.divisionCode}';
    final isExporting = _exportingId == exportId;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          // 헤더
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _accentColor.withValues(alpha: 0.04),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _accentColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.storage, color: _accentColor, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(upload.divisionName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 2),
                      Text('${upload.formattedDate}  |  코드: ${_mergedCodeDisplay[upload.divisionCode] ?? upload.divisionCode}',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    isCompleted ? '완료' : upload.status,
                    style: TextStyle(fontSize: 12, color: statusColor, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          // 통계
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                _buildStatChip(Icons.table_rows, '${DsDataService.formatNumber(upload.totalRows)}행'),
                const SizedBox(width: 12),
                _buildStatChip(Icons.tab, '${upload.sheetCount}개 시트'),
                const SizedBox(width: 12),
                if (upload.uploadedAt.isNotEmpty)
                  _buildStatChip(Icons.access_time, _formatTime(upload.uploadedAt)),
              ],
            ),
          ),
          // 시트 상세
          if (upload.sheetStats.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: upload.sheetStats.entries.map((e) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${e.key}: ${DsDataService.formatNumber(e.value)}',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
                    ),
                  );
                }).toList(),
              ),
            ),
          // Export 진행률
          if (isExporting)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _exportProgress,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
                      minHeight: 6,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(_exportStage,
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                            overflow: TextOverflow.ellipsis),
                      ),
                      Text('${(_exportProgress * 100).toInt()}%',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey.shade700)),
                    ],
                  ),
                ],
              ),
            ),
          // 액션 버튼
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.grey.shade100)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (context.read<AuthService>().canDelete) ...[
                  TextButton.icon(
                    onPressed: () => _confirmDelete(upload),
                    icon: Icon(Icons.delete_outline, size: 18, color: Colors.red.shade400),
                    label: Text('삭제', style: TextStyle(color: Colors.red.shade400, fontSize: 13)),
                  ),
                  const SizedBox(width: 4),
                ],
                TextButton.icon(
                  onPressed: isExporting ? null : () => _startExport(upload),
                  icon: Icon(Icons.download, size: 18,
                      color: isExporting ? Colors.grey : Colors.green.shade600),
                  label: Text(
                    isExporting ? 'Export 중...' : 'Excel',
                    style: TextStyle(
                      color: isExporting ? Colors.grey : Colors.green.shade600,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                FilledButton.icon(
                  onPressed: () => _navigateToData(upload),
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('조회', style: TextStyle(fontSize: 13)),
                  style: FilledButton.styleFrom(
                    backgroundColor: _accentColor,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.grey.shade500),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      ],
    );
  }

  String _formatTime(String isoTime) {
    try {
      final dt = DateTime.parse(isoTime).toLocal();
      return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return isoTime.length > 16 ? isoTime.substring(0, 16) : isoTime;
    }
  }

  void _navigateToData(DsUploadInfo upload) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DsDataScreen(
          divisionId: upload.divisionId,
          divisionName: upload.divisionName,
          importDate: upload.actualDate,
          divisionCode: upload.divisionCode,
          sheetStats: upload.sheetStats,
        ),
      ),
    );
  }

  Future<void> _confirmDelete(DsUploadInfo upload) async {
    final userId = context.read<AuthService>().userId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.delete_outline, color: Colors.red.shade400, size: 28),
                ),
                const SizedBox(height: 16),
                const Text(
                  '데이터 삭제',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Icon(Icons.business, size: 16, color: Colors.grey.shade500),
                          const SizedBox(width: 8),
                          Text(upload.divisionName,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.calendar_today, size: 14, color: Colors.grey.shade500),
                          const SizedBox(width: 8),
                          Text('${upload.formattedDate}  |  코드: ${_mergedCodeDisplay[upload.divisionCode] ?? upload.divisionCode}',
                              style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.table_rows, size: 14, color: Colors.grey.shade500),
                          const SizedBox(width: 8),
                          Text('${DsDataService.formatNumber(upload.totalRows)}행',
                              style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '이 작업은 되돌릴 수 없습니다.',
                  style: TextStyle(fontSize: 13, color: Colors.red.shade400),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.grey.shade700,
                          side: BorderSide(color: Colors.grey.shade300),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('취소', style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade500,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('삭제', style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (confirmed == true) {
      try {
        await _dataService.deleteData(
          upload.divisionId,
          upload.actualDate,
          divisionCode: upload.divisionCode,
          userId: userId,
        );
        if (mounted) {
          final d = ProgressDialog(context);
          await d.complete(message: '삭제되었습니다.');
          _loadStats();
          // 백그라운드 삭제 완료 후 재갱신 (혹시 남아있는 데이터 반영)
          Future.delayed(const Duration(seconds: 15), () {
            if (mounted) _loadStats();
          });
        }
      } catch (e) {
        if (mounted) {
          final d = ProgressDialog(context);
          await d.error(message: '삭제 실패: $e');
        }
      }
    }
  }
}

