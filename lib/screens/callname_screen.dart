import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/callname_service.dart';
import 'callname_download_stub.dart'
    if (dart.library.html) 'callname_download_web.dart' as download_helper;

/// 호출명칭 매칭 화면 — 3단계 (업로드 → 필터 → 매칭/다운로드)
class CallnameScreen extends StatefulWidget {
  const CallnameScreen({super.key});

  @override
  State<CallnameScreen> createState() => _CallnameScreenState();
}

class _CallnameScreenState extends State<CallnameScreen> {
  static const _primary = Color(0xFFE53935);

  final _service = CallnameService();
  int _step = 0; // 0=업로드, 1=필터, 2=매칭

  // Step 0: 업로드 결과
  bool _uploading = false;
  String? _uploadError;
  Map<String, dynamic>? _uploadResult; // upload_id, columns, etc.
  String? _uploadId;

  // Step 1: 필터
  final Map<String, List<String>> _filters = {};
  final Map<String, List<Map<String, dynamic>>> _columnValues = {};
  int? _filteredRows;
  bool _loadingPreview = false;
  bool _analysisComplete = false; // 백그라운드 분석 완료 여부

  // Step 2: 매칭
  bool _processing = false;
  String? _processId;
  double _progress = 0;
  String _progressMessage = '';
  String _progressDetail = '';
  Map<String, dynamic>? _matchResult;
  String? _processError;

  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final token = context.read<AuthService>().authToken;
      _service.setAuthToken(token);
    }
  }

  // ── Step 0: 파일 업로드 ──

  Future<void> _pickAndUpload() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) return;

    setState(() {
      _uploading = true;
      _uploadError = null;
      _uploadResult = null;
    });

    try {
      final data = await _service.uploadExcel(
        Uint8List.fromList(file.bytes!),
        file.name,
      );
      setState(() {
        _uploading = false;
        _uploadResult = data;
        _uploadId = data['upload_id'] as String?;
        _filteredRows = data['filtered_rows'] as int?;
        _analysisComplete = false;
        _step = 1;
      });
      // 백그라운드 분석 폴링 시작
      _pollAnalysis();
    } catch (e) {
      setState(() {
        _uploading = false;
        _uploadError = e.toString();
      });
    }
  }

  // ── 백그라운드 분석 폴링 ──

  Future<void> _pollAnalysis() async {
    while (mounted && _uploadId != null && _step == 1 && !_analysisComplete) {
      try {
        final result = await _service.getAnalysisStatus(_uploadId!);
        final status = result['status'] as String?;
        if (status == 'complete') {
          setState(() {
            _filteredRows = result['filtered_rows'] as int?;
            _analysisComplete = true;
          });
          break;
        } else if (status == 'error') {
          setState(() => _analysisComplete = true);
          break;
        }
      } catch (_) {
        // 폴링 오류 무시
      }
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  // ── Step 1: 필터 ──

  Future<void> _loadColumnValues(String column) async {
    if (_columnValues.containsKey(column) || _uploadId == null) return;
    try {
      final values = await _service.getColumnValues(_uploadId!, column);
      setState(() => _columnValues[column] = values);
    } catch (e) {
      debugPrint('컬럼 조회 실패: $e');
    }
  }

  Future<void> _updatePreview() async {
    if (_uploadId == null) return;
    setState(() => _loadingPreview = true);
    try {
      final result = await _service.previewFiltered(_uploadId!, _filters);
      setState(() {
        _filteredRows = result['filtered_rows'] as int?;
        _loadingPreview = false;
      });
    } catch (e) {
      setState(() => _loadingPreview = false);
    }
  }

  // ── Step 2: 매칭 실행 ──

  Future<void> _startMatching() async {
    if (_uploadId == null) return;

    setState(() {
      _processing = true;
      _processError = null;
      _matchResult = null;
      _progress = 0;
      _progressMessage = '매칭 준비 중...';
      _progressDetail = '';
      _step = 2;
    });

    try {
      // 매칭 시작
      final processResult =
          await _service.startProcess(_uploadId!, _filters);
      final processId = processResult['process_id'] as String;

      setState(() {
        _processId = processId;
        _progressMessage = '매칭 진행 중...';
      });

      // SSE 스트림 구독
      await for (final event in _service.processStream(processId)) {
        final type = event['type'] as String?;
        if (type == 'progress') {
          setState(() {
            _progress = (event['progress'] as num?)?.toDouble() ?? 0;
            _progressMessage = event['message'] as String? ?? '';
            _progressDetail = event['detail'] as String? ?? '';
          });
        } else if (type == 'complete') {
          setState(() {
            _processing = false;
            _progress = 100;
            _progressMessage = event['message'] as String? ?? '완료';
            _matchResult = event;
          });
          break;
        } else if (type == 'error') {
          setState(() {
            _processing = false;
            _processError = event['message'] as String? ?? '매칭 실패';
          });
          break;
        }
      }
    } catch (e) {
      setState(() {
        _processing = false;
        _processError = e.toString();
      });
    }
  }

  Future<void> _downloadResult() async {
    if (_processId == null) return;
    try {
      final data = await _service.getDownloadUrl(_processId!);
      final url = data['url'] as String? ?? '';
      final filename = data['filename'] as String? ?? 'result.xlsx';
      if (url.isNotEmpty) {
        download_helper.openDownloadUrl(url, filename);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('다운로드 실패: $e')),
        );
      }
    }
  }

  void _reset() {
    setState(() {
      _step = 0;
      _uploadResult = null;
      _uploadId = null;
      _uploadError = null;
      _filters.clear();
      _columnValues.clear();
      _filteredRows = null;
      _analysisComplete = false;
      _processId = null;
      _matchResult = null;
      _processError = null;
      _progress = 0;
    });
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('호출명칭 매칭'),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Column(
              children: [
                _buildStepIndicator(),
                const SizedBox(height: 24),
                if (_step == 0) _buildUploadStep(),
                if (_step == 1) _buildFilterStep(),
                if (_step == 2) _buildProcessStep(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStepIndicator() {
    const steps = ['파일 업로드', '필터 설정', '매칭 실행'];
    return Row(
      children: List.generate(steps.length, (i) {
        final isActive = i == _step;
        final isCompleted = i < _step;
        return Expanded(
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isCompleted
                      ? Colors.green
                      : isActive
                          ? _primary
                          : Colors.grey.shade300,
                ),
                child: Center(
                  child: isCompleted
                      ? const Icon(Icons.check, color: Colors.white, size: 16)
                      : Text('${i + 1}',
                          style: TextStyle(
                            color: isActive ? Colors.white : Colors.grey.shade600,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          )),
                ),
              ),
              const SizedBox(width: 6),
              Text(steps[i],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                    color: isActive ? _primary : Colors.grey.shade600,
                  )),
              if (i < steps.length - 1)
                Expanded(
                  child: Container(
                    height: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    color: isCompleted ? Colors.green : Colors.grey.shade300,
                  ),
                ),
            ],
          ),
        );
      }),
    );
  }

  // ── Step 0: 업로드 UI ──

  Widget _buildUploadStep() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.upload_file, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            const Text('정기검사 대상 Excel 파일을 업로드하세요',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('xlsx, xls 파일 지원',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            const SizedBox(height: 20),
            if (_uploading)
              const Column(
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 12),
                  Text('파일 분석 중...'),
                ],
              )
            else
              ElevatedButton.icon(
                onPressed: _pickAndUpload,
                icon: const Icon(Icons.folder_open),
                label: const Text('파일 선택'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                ),
              ),
            if (_uploadError != null) ...[
              const SizedBox(height: 12),
              Text(_uploadError!,
                  style: const TextStyle(color: Colors.red, fontSize: 13)),
            ],
          ],
        ),
      ),
    );
  }

  // ── Step 1: 필터 UI ──

  Widget _buildFilterStep() {
    final data = _uploadResult;
    if (data == null) return const SizedBox.shrink();

    final totalRows = data['total_rows'] as int? ?? 0;
    final columns = (data['columns'] as List?)?.cast<String>() ?? [];
    final detectedTongsi = data['detected_tongsi_col'] as String?;
    final detectedZpwina = data['detected_zpwina_col'] as String?;
    final detectedZpwino = data['detected_zpwino_col'] as String?;

    // 필터 가능한 컬럼: 감지된 키 컬럼과 통시 제외
    final excludeCols = {detectedTongsi, detectedZpwina, detectedZpwino}
        .whereType<String>()
        .toSet();
    final filterableCols =
        columns.where((c) => !excludeCols.contains(c)).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 파일 정보
            _infoRow('파일명', data['filename'] as String? ?? ''),
            _infoRow('총 행수', '${_formatNumber(totalRows)}행'),
            _infoRow('감지 컬럼',
                '호출명칭=${detectedZpwina ?? "없음"}, 허가번호=${detectedZpwino ?? "없음"}, 통시=${detectedTongsi ?? "없음"}'),

            const Divider(height: 32),

            // 매칭 대상 건수
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.filter_alt, color: _primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('매칭 대상 (통시 빈값)',
                            style: TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 14)),
                        const SizedBox(height: 2),
                        _loadingPreview
                            ? const SizedBox(
                                width: 80,
                                child: LinearProgressIndicator())
                            : Text(
                                '${_formatNumber(_filteredRows ?? 0)}행',
                                style: TextStyle(
                                    color: _primary,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16),
                              ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // 필터 선택
            const Text('필터 설정 (선택사항)',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 8),
            if (!_analysisComplete)
              Row(
                children: [
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text('파일 분석 중... 잠시만 기다려주세요.',
                      style: TextStyle(
                          color: Colors.grey.shade600, fontSize: 13)),
                ],
              )
            else
              Text('특정 조건으로 매칭 범위를 좁힐 수 있습니다.',
                  style:
                      TextStyle(color: Colors.grey.shade600, fontSize: 13)),
            const SizedBox(height: 12),

            // 필터 가능한 컬럼 칩
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: filterableCols.take(10).map((col) {
                final isSelected = _filters.containsKey(col);
                return ActionChip(
                  label: Text(col,
                      style: TextStyle(
                          fontSize: 12,
                          color: isSelected ? Colors.white : Colors.black87)),
                  backgroundColor:
                      isSelected ? _primary : Colors.grey.shade200,
                  onPressed:
                      _analysisComplete ? () => _showFilterDialog(col) : null,
                );
              }).toList(),
            ),

            // 활성 필터 표시
            if (_filters.isNotEmpty) ...[
              const SizedBox(height: 12),
              ..._filters.entries.map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Icon(Icons.filter_list, size: 14, color: _primary),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            '${e.key}: ${e.value.join(", ")}',
                            style: const TextStyle(fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        InkWell(
                          onTap: () {
                            setState(() => _filters.remove(e.key));
                            _updatePreview();
                          },
                          child: const Icon(Icons.close, size: 16),
                        ),
                      ],
                    ),
                  )),
            ],

            const SizedBox(height: 24),

            // 버튼
            Row(
              children: [
                OutlinedButton(
                  onPressed: _reset,
                  child: const Text('처음으로'),
                ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed:
                      (_filteredRows ?? 0) > 0 ? _startMatching : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('매칭 시작'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 28, vertical: 14),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showFilterDialog(String column) async {
    await _loadColumnValues(column);
    if (!mounted) return;

    final values = _columnValues[column] ?? [];
    final selected = Set<String>.from(_filters[column] ?? []);

    await showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDialogState) {
          return AlertDialog(
            title: Text('$column 필터', style: const TextStyle(fontSize: 16)),
            content: SizedBox(
              width: 350,
              height: 400,
              child: values.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : ListView.builder(
                      itemCount: values.length,
                      itemBuilder: (_, i) {
                        final v = values[i];
                        final val = v['value'] as String? ?? '';
                        final count = v['count'] as int? ?? 0;
                        final checked = selected.contains(val);
                        return CheckboxListTile(
                          dense: true,
                          title: Text(val, style: const TextStyle(fontSize: 13)),
                          subtitle: Text('${_formatNumber(count)}건',
                              style: const TextStyle(fontSize: 11)),
                          value: checked,
                          onChanged: (v) {
                            setDialogState(() {
                              if (v == true) {
                                selected.add(val);
                              } else {
                                selected.remove(val);
                              }
                            });
                          },
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  setDialogState(() => selected.clear());
                },
                child: const Text('초기화'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('취소'),
              ),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    if (selected.isEmpty) {
                      _filters.remove(column);
                    } else {
                      _filters[column] = selected.toList();
                    }
                  });
                  Navigator.pop(ctx);
                  _updatePreview();
                },
                child: const Text('적용'),
              ),
            ],
          );
        });
      },
    );
  }

  // ── Step 2: 매칭 진행 + 결과 UI ──

  Widget _buildProcessStep() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            if (_processing) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: _progress / 100,
                backgroundColor: Colors.grey.shade200,
                color: _primary,
                minHeight: 8,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 16),
              Text('${_progress.toStringAsFixed(0)}%',
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: _primary)),
              const SizedBox(height: 8),
              Text(_progressMessage,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              if (_progressDetail.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(_progressDetail,
                    style: TextStyle(
                        fontSize: 12, color: Colors.grey.shade600)),
              ],
            ],
            if (_processError != null) ...[
              const Icon(Icons.error_outline,
                  color: Colors.red, size: 48),
              const SizedBox(height: 12),
              Text(_processError!,
                  style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 16),
              OutlinedButton(onPressed: _reset, child: const Text('다시 시도')),
            ],
            if (_matchResult != null) ...[
              const Icon(Icons.check_circle,
                  color: Colors.green, size: 56),
              const SizedBox(height: 16),
              Text('매칭 완료',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.green.shade700)),
              const SizedBox(height: 12),
              _resultRow(
                  '총 매칭',
                  '${_formatNumber(_matchResult!['matched'] ?? 0)} / ${_formatNumber(_matchResult!['total'] ?? 0)}행'),
              _resultRow('zpwina 매칭',
                  '${_formatNumber(_matchResult!['zpwina_matched'] ?? 0)}행'),
              _resultRow('zpwino 매칭',
                  '${_formatNumber(_matchResult!['zpwino_matched'] ?? 0)}행'),
              _resultRow('교차 매칭',
                  '${_formatNumber(_matchResult!['cross_matched'] ?? 0)}행'),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _downloadResult,
                icon: const Icon(Icons.download),
                label: const Text('결과 다운로드'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 32, vertical: 14),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(onPressed: _reset, child: const Text('새 파일 매칭')),
            ],
          ],
        ),
      ),
    );
  }

  // ── Helpers ──

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    fontWeight: FontWeight.w500)),
          ),
          Expanded(
              child: Text(value,
                  style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _resultRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('$label: ',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade700)),
          Text(value,
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  String _formatNumber(int n) {
    if (n >= 1000) {
      return n.toString().replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    }
    return n.toString();
  }
}
