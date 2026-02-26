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

  @override
  void initState() {
    super.initState();
    _loadStats();
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

      // 1. S3 고속 경로 시도
      bool usedS3 = false;
      try {
        final presignUri = Uri.parse('$_baseUrl/ds/export-presign').replace(queryParameters: params);
        final presignResp = await http.get(presignUri);

        if (presignResp.statusCode == 200) {
          final presignData = jsonDecode(presignResp.body);
          if (presignData['success'] == true) {
            if (!mounted) return;
            final type = presignData['type'] as String? ?? 'zip';

            if (type == 'xlsx') {
              // 1a. pre-built xlsx 직접 다운로드 (가장 빠름)
              setState(() {
                _exportStage = 'xlsx 다운로드 중...';
                _exportProgress = 0.1;
              });

              final filename =
                  '${upload.divisionName}_${upload.actualDate}_DS.xlsx';
              final result = await platform_export.downloadXlsxFromUrl(
                url: presignData['url'] as String,
                filename: filename,
                onProgress: (stage, percent) {
                  if (mounted) {
                    setState(() {
                      _exportStage = stage;
                      _exportProgress = percent / 100;
                    });
                  }
                },
              );

              usedS3 = true;
              if (mounted) {
                setState(() => _exportingId = null);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(result)),
                );
              }
              return;
            }

            if (type == 'zip') {
              // 1b. 원본 ZIP → 브라우저 merge → xlsx
              setState(() {
                _exportStage = 'S3에서 원본 다운로드 중...';
                _exportProgress = 0.02;
              });

              final metaJson = jsonEncode({
                'divisionId': upload.divisionId,
                'divisionCode': upload.divisionCode,
                'divisionName': upload.divisionName,
                'importDate': upload.actualDate,
              });

              final result = await platform_export.exportDsFromS3(
                s3Url: presignData['url'] as String,
                metaJson: metaJson,
                onProgress: (stage, percent) {
                  if (mounted) {
                    setState(() {
                      _exportStage = stage;
                      _exportProgress = percent / 100;
                    });
                  }
                },
              );

              usedS3 = true;
              if (mounted) {
                setState(() => _exportingId = null);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(result)),
                );
              }
              return;
            }
          }
        }
      } catch (e) {
        debugPrint('S3 Export 실패, DB 폴백으로 전환: $e');
      }

      // 2. DB 폴백 (S3에 원본이 없는 경우)
      if (!usedS3) {
        if (!mounted) return;
        setState(() {
          _exportStage = '서버에서 데이터 가져오는 중...';
          _exportProgress = 0;
        });

        final uri = Uri.parse('$_baseUrl/ds/export').replace(queryParameters: params);
        final response = await http.get(uri);

        if (response.statusCode != 200) {
          throw Exception('데이터 조회 실패: ${response.statusCode}');
        }

        final body = jsonDecode(response.body);
        if (body['success'] != true) {
          throw Exception(body['message'] ?? '데이터 조회 실패');
        }

        if (!mounted) return;
        setState(() {
          _exportStage = 'xlsx 생성 중...';
          _exportProgress = 0.3;
        });

        final result = await platform_export.exportDsToXlsx(
          jsonData: response.body,
          onProgress: (stage, percent) {
            if (mounted) {
              setState(() {
                _exportStage = stage;
                _exportProgress = 0.3 + (percent / 100) * 0.7;
              });
            }
          },
        );

        if (mounted) {
          setState(() => _exportingId = null);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result)),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _exportingId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export 실패: ${e.toString().replaceFirst("Exception: ", "")}'),
            backgroundColor: Colors.red,
          ),
        );
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
                    // 수동 새로고침: 업로드가 stuck된 경우 상태 초기화
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
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildUploadSection(),
                        const SizedBox(height: 20),
                        _buildSummaryCards(),
                        const SizedBox(height: 20),
                        _buildDivisionFilter(),
                        const SizedBox(height: 16),
                        _buildDivisionAnalytics(),
                        const SizedBox(height: 16),
                        _buildUploadList(),
                      ],
                    ),
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

  Widget _buildSummaryCards() {
    final stats = _stats!;
    final cards = [
      _SummaryData('본부', '${stats.divisions.length}개', Icons.business, _accentColor),
      _SummaryData('업로드', '${stats.totalUploads}건', Icons.cloud_done, Colors.green),
      _SummaryData('총 행수', DsDataService.formatNumber(stats.totalRows), Icons.table_rows, Colors.orange),
    ];

    return Row(
      children: cards.map((c) {
        return Expanded(
          child: Container(
            margin: EdgeInsets.only(right: c == cards.last ? 0 : 8),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(c.icon, color: c.color, size: 24),
                const SizedBox(height: 8),
                Text(c.value,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(c.label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ],
            ),
          ),
        );
      }).toList(),
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
              items: [
                const DropdownMenuItem(value: 'all', child: Text('전체')),
                ...DsDataService.dsDivisionNames.entries.map((e) {
                  return DropdownMenuItem(value: e.key, child: Text(e.value));
                }),
              ],
              onChanged: (v) => setState(() => _selectedDivision = v ?? 'all'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDivisionAnalytics() {
    final uploads = _filteredUploads;
    if (uploads.isEmpty) return const SizedBox.shrink();

    final divisionTotals = <String, int>{};
    for (final u in uploads) {
      divisionTotals[u.divisionName] = (divisionTotals[u.divisionName] ?? 0) + u.totalRows;
    }

    final maxRows = divisionTotals.values.fold(0, (a, b) => a > b ? a : b);
    if (maxRows == 0) return const SizedBox.shrink();

    final sorted = divisionTotals.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

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
          Row(children: [
            Icon(Icons.bar_chart, size: 20, color: _accentColor),
            const SizedBox(width: 8),
            const Text('본부별 데이터 현황', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
          ]),
          const SizedBox(height: 16),
          ...sorted.map((entry) {
            final ratio = entry.value / maxRows;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(entry.key, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                      Text(
                        '${DsDataService.formatNumber(entry.value)}행',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: ratio,
                      backgroundColor: Colors.grey.shade100,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _accentColor.withValues(alpha: 0.4 + ratio * 0.6),
                      ),
                      minHeight: 8,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
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
                      minHeight: 4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(_exportStage,
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
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
                TextButton.icon(
                  onPressed: () => _confirmDelete(upload),
                  icon: Icon(Icons.delete_outline, size: 18, color: Colors.red.shade400),
                  label: Text('삭제', style: TextStyle(color: Colors.red.shade400, fontSize: 13)),
                ),
                const SizedBox(width: 4),
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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('데이터 삭제'),
        content: Text(
          '${upload.divisionName} ${upload.formattedDate} (코드: ${upload.divisionCode})\n'
          '${DsDataService.formatNumber(upload.totalRows)}행을 삭제하시겠습니까?\n\n'
          '이 작업은 되돌릴 수 없습니다.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('삭제', style: TextStyle(color: Colors.red.shade600)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await _dataService.deleteData(
          upload.divisionId,
          upload.actualDate,
          divisionCode: upload.divisionCode,
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

class _SummaryData {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  _SummaryData(this.label, this.value, this.icon, this.color);
}
