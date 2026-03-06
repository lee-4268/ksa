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
  int? _targetCallnames;
  bool _loadingPreview = false;
  bool _analysisComplete = false; // 백그라운드 분석 완료 여부
  final Set<String> _expandedFilters = {}; // 펼쳐진 필터 그룹
  final Map<String, String> _filterSearchQueries = {}; // 필터 내 검색어
  String? _selectedFilterCol; // 드롭다운 선택된 컬럼
  bool _addingFilter = false; // 필터 추가 로딩 중

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
            _targetCallnames = result['target_callnames'] as int?;
            _analysisComplete = true;
            // 분석에서 감지된 컬럼으로 갱신 (upload-complete 누락 보완)
            final cols = result['columns'] as List?;
            if (cols != null && cols.isNotEmpty && _uploadResult != null) {
              _uploadResult!['columns'] = cols;
              _uploadResult!['total_rows'] = result['total_rows'];
              _uploadResult!['detected_callname_col'] =
                  result['detected_callname_col'];
              _uploadResult!['detected_tongsi_col'] =
                  result['detected_tongsi_col'];
              _uploadResult!['detected_zpwina_col'] =
                  result['detected_zpwina_col'];
              _uploadResult!['detected_zpwino_col'] =
                  result['detected_zpwino_col'];
            }
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
        _targetCallnames = result['target_callnames'] as int?;
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
      _targetCallnames = null;
      _analysisComplete = false;
      _expandedFilters.clear();
      _filterSearchQueries.clear();
      _selectedFilterCol = null;
      _addingFilter = false;
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
    final detectedCallname = data['detected_callname_col'] as String?;
    final detectedTongsi = data['detected_tongsi_col'] as String?;
    final detectedZpwina = data['detected_zpwina_col'] as String?;
    final detectedZpwino = data['detected_zpwino_col'] as String?;

    // 필터 가능한 컬럼: 감지된 키 컬럼과 통시 제외
    final excludeCols = {
      detectedCallname,
      detectedTongsi,
      detectedZpwina,
      detectedZpwino,
    }.whereType<String>().toSet();
    final filterableCols =
        columns.where((c) => !excludeCols.contains(c)).toList();

    // 아직 추가하지 않은 컬럼만 드롭다운에 표시
    final availableCols =
        filterableCols.where((c) => !_filters.containsKey(c)).toList();

    return Column(
      children: [
        // ── 파일 정보 카드 ──
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.description, color: _primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        data['filename'] as String? ?? '',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _fileInfoRow(
                    '전체 행 수', '${_formatNumber(totalRows)}행', null),
                _fileInfoRow(
                    '호출명칭 컬럼',
                    detectedCallname ?? '감지 안됨',
                    detectedCallname != null ? '자동감지' : null),
                _fileInfoRow(
                    '통시 컬럼',
                    detectedTongsi ?? '감지 안됨',
                    detectedTongsi != null ? '자동감지' : null),
                const SizedBox(height: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          size: 16, color: Colors.blue.shade600),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '통시 값이 비어있는 행만 매칭 대상으로 처리됩니다.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.blue.shade700),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // ── 필터 설정 카드 ──
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('필터 설정',
                    style:
                        TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                const SizedBox(height: 4),
                if (!_analysisComplete)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        const SizedBox(
                            width: 14,
                            height: 14,
                            child:
                                CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        Text('파일 분석 중... 잠시만 기다려주세요.',
                            style: TextStyle(
                                color: Colors.grey.shade600, fontSize: 13)),
                      ],
                    ),
                  )
                else
                  Text('특정 조건으로 매칭 범위를 좁힐 수 있습니다.',
                      style: TextStyle(
                          color: Colors.grey.shade600, fontSize: 13)),
                const SizedBox(height: 12),

                // 컬럼 드롭다운 + 추가 버튼
                if (_analysisComplete && availableCols.isNotEmpty)
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _selectedFilterCol,
                              hint: const Text('컬럼 선택...',
                                  style: TextStyle(fontSize: 13)),
                              isExpanded: true,
                              items: availableCols.map((col) {
                                return DropdownMenuItem(
                                  value: col,
                                  child: Text(col,
                                      style: const TextStyle(fontSize: 13)),
                                );
                              }).toList(),
                              onChanged: _addingFilter
                                  ? null
                                  : (col) {
                                      setState(
                                          () => _selectedFilterCol = col);
                                    },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        height: 42,
                        child: ElevatedButton(
                          onPressed: _addingFilter ||
                                  _selectedFilterCol == null
                              ? null
                              : () => _addFilter(_selectedFilterCol!),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          child: _addingFilter
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white))
                              : const Text('+ 추가',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ),

                // 인라인 필터 그룹들
                ..._filters.keys.map((col) => _buildFilterGroup(col)),
              ],
            ),
          ),
        ),

        const SizedBox(height: 16),

        // ── 매칭 대상 요약 카드 ──
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: _loadingPreview
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    ),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              _formatNumber(_targetCallnames ?? 0),
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: _primary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text('고유 호출명칭',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey.shade600)),
                          ],
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 48,
                        color: Colors.grey.shade300,
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              _formatNumber(_filteredRows ?? 0),
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: _primary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text('매칭 대상 행',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.grey.shade600)),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ),

        const SizedBox(height: 16),

        // ── 버튼 ──
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: (_filteredRows ?? 0) > 0 ? _startMatching : null,
            icon: const Icon(Icons.play_arrow),
            label: const Text('매칭 시작'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _reset,
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('다시 업로드'),
          ),
        ),
      ],
    );
  }

  /// 필터 추가 (드롭다운 선택 후 + 추가 버튼 클릭)
  Future<void> _addFilter(String column) async {
    setState(() => _addingFilter = true);
    try {
      await _loadColumnValues(column);
      if (!mounted) return;

      final values = _columnValues[column] ?? [];
      // 기본: 모두 선택
      setState(() {
        _filters[column] =
            values.map((v) => v['value'] as String? ?? '').toList();
        _expandedFilters.add(column);
        _selectedFilterCol = null;
        _addingFilter = false;
      });
      _updatePreview();
    } catch (e) {
      if (mounted) {
        setState(() => _addingFilter = false);
      }
    }
  }

  /// 필터 그룹 위젯 (인라인)
  Widget _buildFilterGroup(String column) {
    final values = _columnValues[column] ?? [];
    final selected = _filters[column] ?? [];
    final isExpanded = _expandedFilters.contains(column);
    final searchQuery = _filterSearchQueries[column] ?? '';

    // 검색 필터링
    final filteredValues = searchQuery.isEmpty
        ? values
        : values
            .where((v) => (v['value'] as String? ?? '')
                .toLowerCase()
                .contains(searchQuery.toLowerCase()))
            .toList();

    final selectedCount = selected.length;
    final totalCount = values.length;

    // 보이는 항목 기준으로 모두 선택/부분 선택 판별
    final visibleValues = filteredValues
        .map((v) => v['value'] as String? ?? '')
        .toList();
    final visibleCheckedCount =
        visibleValues.where((v) => selected.contains(v)).length;
    final allVisibleSelected =
        visibleValues.isNotEmpty && visibleCheckedCount == visibleValues.length;
    final someVisibleSelected =
        visibleCheckedCount > 0 && visibleCheckedCount < visibleValues.length;

    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // 헤더
          InkWell(
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expandedFilters.remove(column);
                } else {
                  _expandedFilters.add(column);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 20,
                    color: Colors.grey.shade600,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(column,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '$selectedCount / $totalCount개 선택',
                      style: TextStyle(fontSize: 11, color: _primary),
                    ),
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
                    child: Icon(Icons.close,
                        size: 18, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),

          // 펼쳐진 내용
          if (isExpanded) ...[
            const Divider(height: 1),
            // 검색 입력
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                decoration: InputDecoration(
                  hintText: '검색...',
                  hintStyle: const TextStyle(fontSize: 13),
                  prefixIcon:
                      const Icon(Icons.search, size: 18),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (q) {
                  setState(() => _filterSearchQueries[column] = q);
                },
              ),
            ),
            // 모두 선택 체크박스 (tristate: 일부 선택 시 null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: CheckboxListTile(
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                tristate: true,
                title: const Text('(모두 선택)',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
                value: allVisibleSelected
                    ? true
                    : someVisibleSelected
                        ? null
                        : false,
                onChanged: (v) {
                  setState(() {
                    final newSelected = Set<String>.from(selected);
                    if (v == true || v == null) {
                      // null(indeterminate) 클릭 시에도 모두 선택
                      newSelected.addAll(visibleValues);
                    } else {
                      newSelected.removeAll(visibleValues);
                    }
                    _filters[column] = newSelected.toList();
                  });
                  _updatePreview();
                },
              ),
            ),
            const Divider(height: 1),
            // 값 목록
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240),
              child: values.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                          child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2))),
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
                                  fontStyle: val.isEmpty
                                      ? FontStyle.italic
                                      : FontStyle.normal)),
                          secondary: Text(_formatNumber(count),
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600)),
                          value: checked,
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                selected.add(val);
                              } else {
                                selected.remove(val);
                              }
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

  Widget _fileInfoRow(String label, String value, String? badge) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: TextStyle(
                    fontSize: 13, color: Colors.grey.shade600)),
          ),
          Text(value, style: const TextStyle(fontSize: 13)),
          if (badge != null) ...[
            const SizedBox(width: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Text(badge,
                  style: TextStyle(
                      fontSize: 10, color: Colors.green.shade700)),
            ),
          ],
        ],
      ),
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
