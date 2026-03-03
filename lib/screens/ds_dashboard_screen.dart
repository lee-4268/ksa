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
import '../widgets/user_profile_button.dart';

/// DS 데이터 관리 대시보드 - 업로드 + 조회 + Export + 삭제
class DsDashboardScreen extends StatefulWidget {
  const DsDashboardScreen({super.key});

  @override
  State<DsDashboardScreen> createState() => _DsDashboardScreenState();
}

class _DsDashboardScreenState extends State<DsDashboardScreen> {
  static const Color _accentColor = Color(0xFF5C6BC0);
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
    final token = context.read<AuthService>().authToken;
    _dataService.setAuthToken(token);
    _uploadService.setAuthToken(token);
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
      try {
        final authToken = context.read<AuthService>().authToken;
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
              onProgress('원본 ZIP에서 Excel 생성 중...', 3);
              // EC2 프록시 URL 사용 (S3 CORS 우회)
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
              );
              if (mounted) {
                setState(() => _exportingId = null);
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(result)));
              }
              return;
            }

            // 2. pre-built xlsx → presign 직접 다운로드
            if (type == 'xlsx') {
              onProgress('xlsx 다운로드 중...', 10);
              final result = await platform_export.downloadXlsxFromUrl(
                url: data['url'] as String,
                filename: filename,
                onProgress: onProgress,
              );
              if (mounted) {
                setState(() => _exportingId = null);
                ScaffoldMessenger.of(context)
                    .showSnackBar(SnackBar(content: Text(result)));
              }
              return;
            }
          }
        }
      } catch (e) {
        debugPrint('S3 presign/export 실패 (서버 빌드로 전환): $e');
      }

      // 3. 폴백: 서버사이드 빌드 (/ds/export-xlsx) — old DynamoDB 데이터용
      onProgress('서버에서 Excel 생성 중...', 5);
      final exportUri =
          Uri.parse('$_baseUrl/ds/export-xlsx').replace(queryParameters: params);
      final result = await platform_export.downloadXlsxFromUrl(
        url: exportUri.toString(),
        filename: filename,
        onProgress: onProgress,
      );

      if (mounted) {
        setState(() => _exportingId = null);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(result)));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _exportingId = null);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Export 실패: ${e.toString().replaceFirst("Exception: ", "")}'),
          backgroundColor: Colors.red,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: const Text('DS 데이터 관리'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading
                ? null
                : () {
                    if (_isUploading) {
                      setState(() {
                        _isUploading = false;
                        _uploadStage = '';
                        _uploadProgress = 0;
                      });
                    }
                    _loadStats();
                  },
            tooltip: '새로고침',
          ),
          UserProfileButton(
            onLogout: () {
              context.read<AuthService>().signOut();
              Navigator.of(context).popUntil((route) => route.isFirst);
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
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
                value: _uploadProgress,
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
                  child: Text(_uploadStage,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      overflow: TextOverflow.ellipsis),
                ),
                Text('${(_uploadProgress * 100).toInt()}%',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey.shade700)),
              ],
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
              // 데이터 없음
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
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedDivision,
              isDense: true,
              dropdownColor: Colors.white,
              borderRadius: BorderRadius.circular(12),
              icon: Icon(Icons.keyboard_arrow_down, size: 20, color: Colors.grey.shade600),
              style: const TextStyle(fontSize: 14, color: Colors.black87),
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
                      Text('${upload.formattedDate}  |  코드: ${upload.divisionCode}',
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
                          Text('${upload.formattedDate}  |  코드: ${upload.divisionCode}',
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
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('삭제되었습니다. DynamoDB 레코드는 백그라운드에서 정리됩니다.'),
            ),
          );
          _loadStats();
          // 백그라운드 삭제 완료 후 재갱신 (혹시 남아있는 데이터 반영)
          Future.delayed(const Duration(seconds: 15), () {
            if (mounted) _loadStats();
          });
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('삭제 실패: $e'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }
}

