import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/ds_data_service.dart';
import '../services/ds_upload_service.dart';
import '../services/inspection_service.dart';
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

  // DS 변경이력 — 본부별 카운트 (divisionId → 활성 건수)
  Map<String, int> _changeHistoryCountByDivision = {};

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
      _loadChangeHistoryCount();
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

  Future<void> _loadChangeHistoryCount() async {
    try {
      final svc = InspectionService()
        ..setAuthToken(context.read<AuthService>().authToken);
      // 화면에 표시 중인 본부들에 대해 병렬로 카운트 조회
      if (_stats == null) return;
      final divisionIds = <String>{};
      for (final u in _stats!.uploads) {
        if (u.divisionId.isNotEmpty) divisionIds.add(u.divisionId);
      }
      final futures = divisionIds.map((d) async => MapEntry(d, await svc.getDsChangeHistoryCount(divisionId: d)));
      final entries = await Future.wait(futures);
      if (!mounted) return;
      setState(() {
        _changeHistoryCountByDivision = {for (final e in entries) e.key: e.value};
      });
    } catch (_) {}
  }

  Future<void> _showDsChangeHistoryDialog(String divisionId) async {
    final svc = InspectionService()
      ..setAuthToken(context.read<AuthService>().authToken);
    final canCancel = context.read<AuthService>().isAdmin;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _DsChangeHistoryBulkDialog(
        svc: svc,
        canCancel: canCancel,
        divisionId: divisionId,
      ),
    );
    _loadChangeHistoryCount();
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

  Future<void> _startExport(DsUploadInfo upload) async {
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
      };
      final filename = '${upload.divisionName}_${upload.actualDate}_DS.xlsx';

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
              if (data['building'] == true) {
                if (mounted) {
                  setState(() => _exportingId = null);
                  final d = ProgressDialog(context);
                  await d.error(message: 'xlsx 빌드가 진행 중입니다. 잠시 후 다시 시도해 주세요.');
                }
                return;
              }
              onProgress('Excel 파일 생성 준비 중...', 3);
              final proxyUri = Uri.parse('$_baseUrl/ds/proxy-raw-zip')
                  .replace(queryParameters: params);
              final metaJson = jsonEncode({
                'divisionName': upload.divisionName,
                'divisionId': upload.divisionId,
                'divisionCode': upload.divisionCode,
                'importDate': upload.actualDate,
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
                // 데이터 변경요청은 admin/manager만 (운영 절차상 본부관리자가 수행)
                if (context.read<AuthService>().isAdmin) ...[
                  const SizedBox(width: 4),
                  TextButton.icon(
                    onPressed: () => _showPartialDsUploadDialog(),
                    icon: Icon(Icons.upload_file_outlined, size: 18, color: Colors.deepOrange.shade600),
                    label: Text('데이터 변경요청',
                        style: TextStyle(color: Colors.deepOrange.shade600, fontSize: 13)),
                  ),
                ],
                if ((_changeHistoryCountByDivision[upload.divisionId] ?? 0) > 0) ...[
                  const SizedBox(width: 2),
                  InkWell(
                    onTap: () => _showDsChangeHistoryDialog(upload.divisionId),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E88E5).withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF1E88E5).withValues(alpha: 0.30)),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.history, size: 12, color: Color(0xFF1565C0)),
                        const SizedBox(width: 4),
                        Text('변경내역 ${_changeHistoryCountByDivision[upload.divisionId] ?? 0}건',
                            style: const TextStyle(fontSize: 11, color: Color(0xFF1565C0), fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                ],
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

  Future<void> _showPartialDsUploadDialog() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xls', 'xlsx'],
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;
    final f = picked.files.first;
    final bytes = f.bytes;
    if (bytes == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('파일을 읽을 수 없습니다.')));
      return;
    }

    if (!mounted) return;

    // 1. 미리보기 로딩
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final svc = InspectionService()
      ..setAuthToken(context.read<AuthService>().authToken);

    Map<String, dynamic> preview;
    try {
      preview = await svc.previewPartialDsUpdate(Uint8List.fromList(bytes), f.name);
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('미리보기 실패: $e'), backgroundColor: Colors.red));
      return;
    }
    if (!mounted) return;
    Navigator.pop(context);

    final diffs = List<Map<String, dynamic>>.from(preview['diffs'] ?? []);
    final licCount = preview['license_count'] ?? 0;

    // 2. Modern Minimal 확인 다이얼로그 (체크박스)
    // checked[i] = true → 적용, false → 제외
    final checked = List<bool>.filled(diffs.length, true);

    String diffKey(Map<String, dynamic> d) =>
        '${d['허가번호']}#${d['필드명']}#${d['장치번호'] ?? ''}';

    final excludedKeys = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 32),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE17055).withValues(alpha: 0.10),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.compare_arrows_rounded,
                      color: Color(0xFFE17055), size: 26),
                ),
                const SizedBox(height: 14),
                const Text('DS 데이터 변경 확인',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800,
                        color: Color(0xFF111827))),
                const SizedBox(height: 4),
                Text('허가번호 $licCount국소 · 변경항목 ${diffs.length}건',
                    style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
                const SizedBox(height: 16),
                if (diffs.isEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Text('변경되는 항목이 없습니다.',
                        style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
                  )
                else
                  Container(
                    constraints: const BoxConstraints(maxHeight: 320),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF9FAFB),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: List.generate(diffs.length, (i) {
                            final d = diffs[i];
                            final hn = d['허가번호'] ?? '';
                            final jn = (d['장치번호'] as String? ?? '').isNotEmpty
                                ? ' #${d['장치번호']}' : '';
                            final field = d['필드명'] ?? '';
                            final before = d['변경전'] ?? '';
                            final after = d['변경후'] ?? '';
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Checkbox(
                                    value: checked[i],
                                    activeColor: const Color(0xFF2563EB),
                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    visualDensity: VisualDensity.compact,
                                    onChanged: (v) => setS(() => checked[i] = v ?? true),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Opacity(
                                      opacity: checked[i] ? 1.0 : 0.4,
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text('$hn$jn · $field',
                                              style: const TextStyle(
                                                  fontSize: 12, fontWeight: FontWeight.w600,
                                                  color: Color(0xFF374151))),
                                          const SizedBox(height: 4),
                                          Row(children: [
                                            Expanded(
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(
                                                    horizontal: 8, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFFFEDED),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  before.isEmpty ? '(없음)' : before,
                                                  style: const TextStyle(
                                                      fontSize: 11, color: Color(0xFFB91C1C)),
                                                ),
                                              ),
                                            ),
                                            const Padding(
                                              padding: EdgeInsets.symmetric(horizontal: 6),
                                              child: Icon(Icons.arrow_forward,
                                                  size: 14, color: Color(0xFF9CA3AF)),
                                            ),
                                            Expanded(
                                              child: Container(
                                                padding: const EdgeInsets.symmetric(
                                                    horizontal: 8, vertical: 4),
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFFECFDF5),
                                                  borderRadius: BorderRadius.circular(6),
                                                ),
                                                child: Text(
                                                  after.isEmpty ? '(없음)' : after,
                                                  style: const TextStyle(
                                                      fontSize: 11, color: Color(0xFF065F46)),
                                                ),
                                              ),
                                            ),
                                          ]),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: 0,
                    ),
                    onPressed: diffs.isEmpty || checked.every((c) => !c)
                        ? null
                        : () {
                            final excluded = [
                              for (int i = 0; i < diffs.length; i++)
                                if (!checked[i]) diffKey(diffs[i]),
                            ];
                            Navigator.pop(ctx, excluded);
                          },
                    child: Text(
                      checked.every((c) => !c)
                          ? '선택 없음'
                          : '적용 (${checked.where((c) => c).length}건)',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text('취소',
                      style: TextStyle(fontSize: 14, color: Color(0xFF9CA3AF))),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
    if (excludedKeys == null || !mounted) return;

    // 3. 적용
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      final result = await svc.applyPartialDsUpdate(Uint8List.fromList(bytes), f.name,
          excludedKeys: excludedKeys);
      if (!mounted) return;
      Navigator.pop(context);
      final applied = result['applied'] ?? 0;
      final matched = result['matched_changes'] ?? 0;
      final done = (result['schedule_done'] as List?)?.length ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('패치 $applied/$matched건 · 점검완료 자동 전환 $done건'),
        backgroundColor: const Color(0xFF1A8754),
        duration: const Duration(seconds: 5),
      ));
      _loadChangeHistoryCount();
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('적용 실패: $e'), backgroundColor: Colors.red,
      ));
    }
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

/// DS 변경 이력 묶음 다이얼로그
/// - 업로드 세션(upload_id) 단위로 트리뷰 헤더
/// - 헤더 펼치면 그 묶음의 행 목록
/// - 행별 체크박스 + 일괄 되돌리기 + 허가번호 검색
class _DsChangeHistoryBulkDialog extends StatefulWidget {
  final InspectionService svc;
  final bool canCancel;
  final String divisionId;

  const _DsChangeHistoryBulkDialog({
    required this.svc,
    required this.canCancel,
    required this.divisionId,
  });

  @override
  State<_DsChangeHistoryBulkDialog> createState() => _DsChangeHistoryBulkDialogState();
}

class _DsChangeHistoryBulkDialogState extends State<_DsChangeHistoryBulkDialog> {
  bool _loading = true;
  List<Map<String, dynamic>> _uploads = [];     // 업로드 묶음 헤더
  Map<String, List<Map<String, dynamic>>> _itemsByUpload = {};
  Set<String> _expanded = {};                   // 펼쳐진 upload_id
  final Set<int> _selected = {};                // 선택된 이력 id
  final _searchCtrl = TextEditingController();
  String _searchTerm = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final uploads = await widget.svc.listDsChangeHistoryUploads(divisionId: widget.divisionId);
      // 검색 활성 시 전체 이력을 미리 가져와서 필터 (펼침 무관)
      Map<String, List<Map<String, dynamic>>> map = {};
      if (_searchTerm.isNotEmpty) {
        final items = await widget.svc.listDsChangeHistory(
          divisionId: widget.divisionId,
          search: _searchTerm,
        );
        for (final it in items) {
          final uid = (it['upload_id'] ?? '').toString();
          map.putIfAbsent(uid, () => []).add(it);
        }
        // 검색 결과가 있는 묶음만 표시
        final hitUploadIds = map.keys.toSet();
        if (!mounted) return;
        setState(() {
          _uploads = uploads.where((u) => hitUploadIds.contains(u['upload_id'])).toList();
          _itemsByUpload = map;
          _expanded = hitUploadIds;  // 검색 시 자동 펼침
          _loading = false;
        });
      } else {
        if (!mounted) return;
        setState(() {
          _uploads = uploads;
          _itemsByUpload = {};
          _expanded.clear();
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('조회 실패: $e')));
    }
  }

  Future<void> _toggleExpand(String uploadId) async {
    if (_expanded.contains(uploadId)) {
      setState(() => _expanded.remove(uploadId));
      return;
    }
    // 아직 로드 안 됐으면 가져오기
    if (!_itemsByUpload.containsKey(uploadId)) {
      try {
        final items = await widget.svc.listDsChangeHistory(uploadId: uploadId);
        if (!mounted) return;
        _itemsByUpload[uploadId] = items;
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('상세 조회 실패: $e')));
        return;
      }
    }
    setState(() => _expanded.add(uploadId));
  }

  Future<void> _bulkCancel() async {
    if (_selected.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFEF2F2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.undo_rounded,
                      color: Color(0xFFEF4444), size: 24),
                ),
                const SizedBox(height: 16),
                Text(
                  '${_selected.length}건 되돌리기',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '선택한 변경 이력을 되돌립니다.\n워크플로우 상태는 변경되지 않습니다.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: Color(0xFF6B7280),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('되돌리기', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('취소',
                        style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true) return;
    try {
      final res = await widget.svc.bulkCancelDsChanges(_selected.toList());
      if (!mounted) return;
      final succeeded = (res['succeeded'] as num?)?.toInt() ?? 0;
      final failed = (res['failed'] as num?)?.toInt() ?? 0;
      final skipped = (res['skipped'] as num?)?.toInt() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('되돌리기 완료: 성공 $succeeded · 실패 $failed · 스킵 $skipped'),
      ));
      _selected.clear();
      _itemsByUpload.clear();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('일괄 되돌리기 실패: $e')));
    }
  }

  Future<void> _cancelOne(int id) async {
    try {
      await widget.svc.cancelDsChange(id);
      _itemsByUpload.clear();
      _selected.remove(id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('되돌리기 실패: $e')));
    }
  }

  String _fmtDate(String raw) {
    if (raw.length == 6 && RegExp(r'^\d{6}$').hasMatch(raw)) {
      return '${raw.substring(0, 2)}.${raw.substring(2, 4)}.${raw.substring(4, 6)}';
    }
    return raw;
  }

  String _fmtTime(String iso) {
    if (iso.isEmpty) return '';
    try {
      final t = DateTime.parse(iso).toLocal();
      return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
             '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Column(children: [
          // 헤더 — 알림 다이얼로그와 같은 톤 (Modern Minimal)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 16, 16),
            child: Row(children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: const BoxDecoration(
                  color: Color(0xFFFEF2F2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.history_rounded,
                    color: Color(0xFFEF4444), size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'DS 변경 이력',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${widget.divisionId.isEmpty ? "전체 본부" : widget.divisionId} · 업로드 묶음 ${_uploads.length}건',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 20, color: Color(0xFF9CA3AF)),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
          ),
          // 검색 + 일괄 되돌리기
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Row(children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFF9FAFB),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
                    decoration: InputDecoration(
                      hintText: '허가번호 검색 (하이픈 무시)',
                      hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                      prefixIcon: const Icon(Icons.search_rounded, size: 18, color: Color(0xFF9CA3AF)),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      suffixIcon: _searchTerm.isEmpty ? null : IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 16, color: Color(0xFF9CA3AF)),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _searchTerm = '');
                          _load();
                        },
                      ),
                    ),
                    onSubmitted: (v) {
                      setState(() => _searchTerm = v.trim());
                      _load();
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (widget.canCancel && _selected.isNotEmpty)
                ElevatedButton.icon(
                  icon: const Icon(Icons.undo_rounded, size: 16),
                  label: Text('${_selected.length}건 되돌리기',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    minimumSize: const Size(0, 44),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _bulkCancel,
                ),
            ]),
          ),
          // 본문
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _uploads.isEmpty
                    ? Center(child: Text(
                        _searchTerm.isEmpty ? '변경 이력이 없습니다' : '검색 결과가 없습니다',
                        style: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        itemCount: _uploads.length,
                        itemBuilder: (_, i) {
                          final u = _uploads[i];
                          final uploadId = u['upload_id'] as String? ?? '';
                          final isExpanded = _expanded.contains(uploadId);
                          final items = _itemsByUpload[uploadId] ?? [];
                          return _buildUploadGroup(u, uploadId, isExpanded, items);
                        },
                      ),
          ),
        ]),
      ),
    );
  }

  Widget _buildUploadGroup(Map<String, dynamic> u, String uploadId, bool isExpanded, List<Map<String, dynamic>> items) {
    final active = (u['active_count'] as num?)?.toInt() ?? 0;
    final cancelled = (u['cancelled_count'] as num?)?.toInt() ?? 0;
    final total = (u['total'] as num?)?.toInt() ?? 0;
    final filename = u['uploaded_filename'] as String? ?? '(파일명 없음)';
    final uploadedBy = u['uploaded_by'] as String? ?? '';
    final uploadedAt = u['uploaded_at'] as String? ?? '';

    // 활성 행만 체크 가능
    final activeItems = items.where((it) => (it['cancelled'] ?? '0') != '1').toList();
    final activeIds = activeItems.map((it) => it['id'] as int).toSet();
    final allChecked = activeIds.isNotEmpty && activeIds.every(_selected.contains);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(children: [
        InkWell(
          onTap: () => _toggleExpand(uploadId),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Icon(isExpanded ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                  size: 20, color: const Color(0xFF9CA3AF)),
              const SizedBox(width: 8),
              if (widget.canCancel && isExpanded && activeIds.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: SizedBox(
                    width: 22, height: 22,
                    child: Checkbox(
                      value: allChecked,
                      tristate: false,
                      activeColor: const Color(0xFF2563EB),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _selected.addAll(activeIds);
                          } else {
                            _selected.removeAll(activeIds);
                          }
                        });
                      },
                    ),
                  ),
                ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(filename,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827),
                        letterSpacing: -0.2,
                      ),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 3),
                  Text('${_fmtTime(uploadedAt)} · ${uploadedBy.isEmpty ? "-" : uploadedBy}',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
                ]),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  cancelled > 0 ? '활성 $active / 전체 $total · 취소 $cancelled' : '활성 $active / 전체 $total',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF2563EB),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ]),
          ),
        ),
        if (isExpanded)
          Container(
            decoration: const BoxDecoration(
              color: Color(0xFFF9FAFB),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(13)),
              border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
            ),
            child: Column(children: items.map(_buildItemRow).toList()),
          ),
      ]),
    );
  }

  Widget _buildItemRow(Map<String, dynamic> r) {
    final id = r['id'] as int? ?? 0;
    final cancelled = (r['cancelled'] ?? '0') == '1';
    final hn = r['허가번호'] ?? '';
    final field = r['필드명'] ?? '';
    final jn = r['장치번호'] ?? '';
    final before = r['변경전값'] ?? '';
    final after = r['변경후값'] ?? '';
    final date = r['변경일자'] ?? '';
    final label = jn.toString().isNotEmpty ? '$field · $jn' : '$field';
    final checked = _selected.contains(id);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFEEF0F3))),
      ),
      child: Row(children: [
        if (widget.canCancel)
          SizedBox(
            width: 22, height: 22,
            child: Checkbox(
              value: cancelled ? false : checked,
              activeColor: const Color(0xFF2563EB),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              onChanged: cancelled ? null : (v) {
                setState(() {
                  if (v == true) {
                    _selected.add(id);
                  } else {
                    _selected.remove(id);
                  }
                });
              },
            ),
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('$hn',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF2563EB),
                  )),
              const SizedBox(width: 10),
              Flexible(
                child: Text(label,
                    style: TextStyle(
                      fontSize: 13,
                      color: cancelled ? const Color(0xFF9CA3AF) : const Color(0xFF111827),
                      fontWeight: FontWeight.w600,
                      decoration: cancelled ? TextDecoration.lineThrough : null,
                    ),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              Text(_fmtDate(date),
                  style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
              if (cancelled) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('취소됨',
                      style: TextStyle(fontSize: 9, color: Color(0xFFEF4444), fontWeight: FontWeight.w700)),
                ),
              ],
            ]),
            const SizedBox(height: 3),
            Text('$before → $after',
                style: TextStyle(
                  fontSize: 11,
                  color: cancelled ? const Color(0xFFC1C5CC) : const Color(0xFF6B7280),
                )),
          ]),
        ),
        if (!cancelled && widget.canCancel)
          TextButton.icon(
            icon: const Icon(Icons.undo_rounded, size: 14),
            label: const Text('되돌리기', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF2563EB),
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => _cancelOne(id),
          ),
      ]),
    );
  }
}

