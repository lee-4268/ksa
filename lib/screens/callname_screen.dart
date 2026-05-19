import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/callname_service.dart';
import '../widgets/app_loader.dart';
import '../widgets/progress_dialog.dart';
import 'callname_download_stub.dart'
    if (dart.library.html) 'callname_download_web.dart' as download_helper;

/// 분석 상태
enum _AnalysisState { pending, analyzing, complete, error }

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
  Map<String, dynamic>? _uploadResult;
  String? _uploadId;

  // Step 1: 필터
  final Map<String, List<String>> _filters = {};
  final Map<String, List<Map<String, dynamic>>> _columnValues = {};
  int? _filteredRows;
  int? _targetCallnames;
  bool _loadingPreview = false;
  _AnalysisState _analysisState = _AnalysisState.pending;
  final Set<String> _expandedFilters = {};
  final Map<String, String> _filterSearchQueries = {};
  String? _selectedFilterCol;
  final Map<String, bool> _loadingColumnValues = {};

  Timer? _previewDebounce;

  // Sample 양식
  bool _loadingSamples = false;
  List<Map<String, dynamic>> _sampleTemplates = [];
  bool _samplesLoaded = false;

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
  void dispose() {
    _previewDebounce?.cancel();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final token = context.read<AuthService>().authToken;
      _service.setAuthToken(token);
      _loadSampleTemplates();
    }
  }

  // ── Sample 양식 ──

  Future<void> _loadSampleTemplates() async {
    if (mounted) setState(() => _loadingSamples = true);
    try {
      final list = await _service.listSampleTemplates();
      if (!mounted) return;
      setState(() {
        _sampleTemplates = list;
        _samplesLoaded = true;
        _loadingSamples = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _samplesLoaded = true;
        _loadingSamples = false;
      });
    }
  }

  Future<void> _pickAndUploadSample() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'xls'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;

    final progress = ProgressDialog(context);
    progress.show(message: '샘플 양식 업로드 중...');
    try {
      await _service.uploadSampleTemplate(
        Uint8List.fromList(file.bytes!),
        file.name,
      );
      await _loadSampleTemplates();
      await progress.complete(message: '샘플 양식이 업로드되었습니다.');
    } catch (e) {
      await progress.error(message: '업로드 실패: $e');
    }
  }

  Future<void> _downloadSample(String name) async {
    try {
      final data = await _service.getSampleTemplateDownloadUrl(name);
      final url = data['url'] as String? ?? '';
      final filename = data['filename'] as String? ?? name;
      if (url.isNotEmpty) {
        download_helper.openDownloadUrl(url, filename);
      }
    } catch (e) {
      if (mounted) {
        final d = ProgressDialog(context);
        await d.error(message: '다운로드 실패: $e');
      }
    }
  }

  Future<void> _deleteSample(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('샘플 양식 삭제'),
        content: Text('"$name" 파일을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final progress = ProgressDialog(context);
    progress.show(message: '삭제 중...');
    try {
      await _service.deleteSampleTemplate(name);
      await _loadSampleTemplates();
      await progress.complete(message: '삭제되었습니다.');
    } catch (e) {
      await progress.error(message: '삭제 실패: $e');
    }
  }

  // ── Step 0: 파일 업로드 ──

  Future<FilePickerResult?> _tryPickFile() async {
    try {
      return await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
        withData: true,
      );
    } catch (e) {
      debugPrint('FilePicker 오류: $e');
      return null;
    }
  }

  Future<void> _pickAndUpload() async {
    // Flutter Web file_picker 8.x: 화면 진입 후 첫 호출 시
    // window focus 이벤트가 change 이벤트보다 먼저 발생하여
    // null을 반환하는 알려진 이슈.
    // 해결: 다이얼로그가 열린 시간을 측정하여 비정상적으로 빠르면 재시도.
    final stopwatch = Stopwatch()..start();
    var result = await _tryPickFile();
    stopwatch.stop();

    if ((result == null || result.files.isEmpty) &&
        stopwatch.elapsedMilliseconds < 2000) {
      // 2초 미만에 null 반환 → 사용자가 취소한 것이 아닌 focus race condition
      result = await _tryPickFile();
      if (result == null || result.files.isEmpty) return;
    } else if (result == null || result.files.isEmpty) {
      return;
    }

    final file = result.files.first;
    if (file.bytes == null) {
      debugPrint('FilePicker: bytes가 null (파일 읽기 실패)');
      return;
    }

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
        _analysisState = _AnalysisState.pending;
        _step = 1;
      });
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
    if (mounted) {
      setState(() => _analysisState = _AnalysisState.analyzing);
    }
    while (mounted &&
        _uploadId != null &&
        _step == 1 &&
        _analysisState == _AnalysisState.analyzing) {
      try {
        final result = await _service.getAnalysisStatus(_uploadId!);
        final status = result['status'] as String?;
        if (status == 'complete') {
          setState(() {
            _analysisState = _AnalysisState.complete;
            _filteredRows = result['filtered_rows'] as int?;
            _targetCallnames = result['target_callnames'] as int?;
            // 분석에서 감지된 컬럼으로 갱신
            if (_uploadResult != null) {
              final cols = result['columns'] as List?;
              if (cols != null && cols.isNotEmpty) {
                _uploadResult!['columns'] = cols;
              }
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
          setState(() => _analysisState = _AnalysisState.error);
          break;
        }
      } catch (_) {}
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

  void _updatePreview() {
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 300), () {
      _fetchPreview();
    });
  }

  Future<void> _fetchPreview() async {
    if (_uploadId == null) return;
    setState(() => _loadingPreview = true);
    try {
      final result = await _service.previewFiltered(_uploadId!, _filters);
      if (!mounted) return;
      setState(() {
        _filteredRows = result['filtered_rows'] as int?;
        _targetCallnames = result['target_callnames'] as int?;
        _loadingPreview = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loadingPreview = false);
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
      final processResult =
          await _service.startProcess(_uploadId!, _filters);
      final processId = processResult['process_id'] as String;

      setState(() {
        _processId = processId;
        _progressMessage = '매칭 진행 중...';
      });

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
        final d = ProgressDialog(context);
        await d.error(message: '다운로드 실패: $e');
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
      _analysisState = _AnalysisState.pending;
      _expandedFilters.clear();
      _filterSearchQueries.clear();
      _selectedFilterCol = null;
      _loadingColumnValues.clear();
      _processId = null;
      _matchResult = null;
      _processError = null;
      _progress = 0;
    });
  }

  /// 필터 추가 — 드롭다운 선택 즉시 패널 생성, 값은 비동기 로딩
  void _addFilter(String column) {
    setState(() {
      _filters[column] = []; // 빈 상태로 시작 (아무것도 선택 안 됨)
      _expandedFilters.add(column);
      _selectedFilterCol = null;
    });
    _loadColumnValuesAsync(column);
  }

  Future<void> _loadColumnValuesAsync(String column) async {
    if (_columnValues.containsKey(column)) return;
    setState(() => _loadingColumnValues[column] = true);
    try {
      final values = await _service.getColumnValues(_uploadId!, column);
      if (!mounted) return;
      setState(() {
        _columnValues[column] = values;
        // 처음 로드 시 모든 값 선택
        _filters[column] =
            values.map((v) => v['value'] as String? ?? '').toList();
        _loadingColumnValues.remove(column);
      });
      _updatePreview();
    } catch (e) {
      if (mounted) {
        setState(() => _loadingColumnValues.remove(column));
      }
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFB),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 700),
            child: Column(
              children: [
                _buildStepIndicator(),
                const SizedBox(height: 24),
                if (_step == 0) ...[
                  _buildSampleTemplateCard(),
                  const SizedBox(height: 16),
                  _buildUploadStep(),
                ],
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
                            color:
                                isActive ? Colors.white : Colors.grey.shade600,
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

  // ── Sample 양식 카드 ──

  Widget _buildSampleTemplateCard() {
    final isAdmin = context.watch<AuthService>().isSuperAdmin;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.description_outlined,
                    color: _primary, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('샘플 양식',
                      style: TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15)),
                ),
                if (isAdmin)
                  TextButton.icon(
                    onPressed:
                        _loadingSamples ? null : _pickAndUploadSample,
                    icon: const Icon(Icons.upload, size: 16),
                    label: const Text('양식 업로드'),
                    style: TextButton.styleFrom(
                      foregroundColor: _primary,
                      visualDensity: VisualDensity.compact,
                    ),
                  )
                else
                  IconButton(
                    onPressed:
                        _loadingSamples ? null : _loadSampleTemplates,
                    icon: const Icon(Icons.refresh, size: 18),
                    tooltip: '새로고침',
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              isAdmin
                  ? '관리자가 업로드한 양식을 사용자가 다운받아 대상을 수기 입력 후 매칭에 사용합니다.'
                  : '양식을 다운받아 대상을 수기 입력 후 매칭에 사용하세요.',
              style:
                  TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 12),
            if (_loadingSamples && !_samplesLoaded)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else if (_sampleTemplates.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Text(
                  isAdmin
                      ? '등록된 샘플 양식이 없습니다. 위 "양식 업로드" 버튼으로 업로드하세요.'
                      : '등록된 샘플 양식이 없습니다. 관리자에게 문의하세요.',
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey.shade600),
                ),
              )
            else
              Column(
                children: _sampleTemplates
                    .map((f) => _buildSampleRow(f, isAdmin))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSampleRow(Map<String, dynamic> f, bool isAdmin) {
    final name = f['name'] as String? ?? '';
    final size = f['size'] as int? ?? 0;
    final lastModified = f['last_modified'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.insert_drive_file_outlined,
              size: 18, color: Colors.grey.shade600),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  '${_formatSize(size)}'
                  '${lastModified != null ? ' · ${_formatDate(lastModified)}' : ''}',
                  style: TextStyle(
                      fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => _downloadSample(name),
            icon: const Icon(Icons.download, size: 18),
            tooltip: '다운로드',
            visualDensity: VisualDensity.compact,
          ),
          if (isAdmin)
            IconButton(
              onPressed: () => _deleteSample(name),
              icon: Icon(Icons.delete_outline,
                  size: 18, color: Colors.red.shade400),
              tooltip: '삭제',
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '$bytes B';
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final y = dt.year.toString().padLeft(4, '0');
      final mo = dt.month.toString().padLeft(2, '0');
      final d = dt.day.toString().padLeft(2, '0');
      return '$y-$mo-$d';
    } catch (_) {
      return iso;
    }
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
              AppLoader(message: '파일 업로드 중...')
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

    final isAnalyzing = _analysisState == _AnalysisState.pending ||
        _analysisState == _AnalysisState.analyzing;
    final isComplete = _analysisState == _AnalysisState.complete;

    // 분석 완료 후에만 신뢰할 수 있는 값
    final totalRows = data['total_rows'] as int? ?? 0;
    final columns = (data['columns'] as List?)?.cast<String>() ?? [];
    final detectedCallname = data['detected_callname_col'] as String?;
    final detectedTongsi = data['detected_tongsi_col'] as String?;
    final detectedZpwina = data['detected_zpwina_col'] as String?;
    final detectedZpwino = data['detected_zpwino_col'] as String?;

    // 필터 가능한 컬럼
    final excludeCols = {
      detectedCallname,
      detectedTongsi,
      detectedZpwina,
      detectedZpwino,
    }.whereType<String>().toSet();
    final filterableCols =
        columns.where((c) => !excludeCols.contains(c)).toList();
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

                // 분석 중: 로딩 플레이스홀더
                if (isAnalyzing) ...[
                  _loadingInfoRow('전체 행 수'),
                  _loadingInfoRow('호출명칭 컬럼'),
                  _loadingInfoRow('통시 컬럼'),
                  const SizedBox(height: 8),
                  _analyzingBanner(),
                ],

                // 분석 완료: 실제 값 표시
                if (isComplete) ...[
                  _fileInfoRow(
                      '전체 행 수', '${_formatNumber(totalRows)}행', null),
                  _fileInfoRow(
                    '호출명칭 컬럼',
                    detectedCallname ?? '감지 안됨',
                    detectedCallname != null ? '자동감지' : null,
                  ),
                  _fileInfoRow(
                    '통시 컬럼',
                    detectedTongsi ?? '감지 안됨',
                    detectedTongsi != null ? '자동감지' : null,
                  ),
                  // 감지 실패 경고
                  if (detectedCallname == null || detectedTongsi == null) ...[
                    const SizedBox(height: 8),
                    _detectionWarning(detectedCallname, detectedTongsi),
                  ] else ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
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
                ],

                // 분석 에러
                if (_analysisState == _AnalysisState.error) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline,
                            size: 16, color: Colors.red.shade600),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '파일 분석 중 오류가 발생했습니다. 다시 업로드해주세요.',
                            style: TextStyle(
                                fontSize: 12, color: Colors.red.shade700),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
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

                if (isAnalyzing)
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
                        Text('파일 분석 완료 후 필터를 설정할 수 있습니다.',
                            style: TextStyle(
                                color: Colors.grey.shade600, fontSize: 13)),
                      ],
                    ),
                  )
                else if (isComplete && filterableCols.isNotEmpty)
                  Text('특정 조건으로 매칭 범위를 좁힐 수 있습니다.',
                      style: TextStyle(
                          color: Colors.grey.shade600, fontSize: 13))
                else if (isComplete && filterableCols.isEmpty)
                  Text('필터 가능한 컬럼이 없습니다.',
                      style: TextStyle(
                          color: Colors.grey.shade600, fontSize: 13)),

                const SizedBox(height: 12),

                // 드롭다운 — 선택 시 바로 필터 추가
                if (isComplete && availableCols.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: null,
                        hint: Text('필터할 컬럼 선택...',
                            style: TextStyle(
                                fontSize: 13,
                                color: Colors.grey.shade500)),
                        isExpanded: true,
                        isDense: true,
                        icon: Icon(Icons.arrow_drop_down,
                            color: _primary, size: 20),
                        dropdownColor: Colors.white,

                        borderRadius: BorderRadius.circular(12),
                        style: const TextStyle(
                          color: Colors.black87,
                          fontSize: 13,
                        ),
                        items: availableCols.map((col) {
                          return DropdownMenuItem(
                            value: col,
                            child: Text(col),
                          );
                        }).toList(),
                        onChanged: (col) {
                          if (col != null) _addFilter(col);
                        },
                      ),
                    ),
                  ),

                // 인라인 필터 그룹
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
            child: isAnalyzing
                ? Row(
                    children: [
                      const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '분석 완료 후 매칭 대상 수가 표시됩니다.',
                          style: TextStyle(
                              fontSize: 13, color: Colors.grey.shade600),
                        ),
                      ),
                    ],
                  )
                : _loadingPreview
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: AppLoader(),
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
            onPressed: isComplete &&
                    (_filteredRows ?? 0) > 0 &&
                    detectedCallname != null
                ? _startMatching
                : null,
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

  // ── 필터 그룹 위젯 ──

  Widget _buildFilterGroup(String column) {
    final values = _columnValues[column] ?? [];
    final selected = _filters[column] ?? [];
    final isExpanded = _expandedFilters.contains(column);
    final searchQuery = _filterSearchQueries[column] ?? '';
    final isLoading = _loadingColumnValues[column] == true;

    final filteredValues = searchQuery.isEmpty
        ? values
        : values
            .where((v) => (v['value'] as String? ?? '')
                .toLowerCase()
                .contains(searchQuery.toLowerCase()))
            .toList();

    final selectedCount = selected.length;
    final totalCount = values.length;

    final visibleValues =
        filteredValues.map((v) => v['value'] as String? ?? '').toList();
    final visibleCheckedCount =
        visibleValues.where((v) => selected.contains(v)).length;
    final allVisibleSelected = visibleValues.isNotEmpty &&
        visibleCheckedCount == visibleValues.length;
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
            onTap: () => setState(() {
              if (isExpanded) {
                _expandedFilters.remove(column);
              } else {
                _expandedFilters.add(column);
              }
            }),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
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
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (q) =>
                    setState(() => _filterSearchQueries[column] = q),
              ),
            ),
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
                onChanged: (_) {
                  setState(() {
                    final newSelected = Set<String>.from(selected);
                    if (allVisibleSelected) {
                      // 전체 선택 상태 → 전체 해제
                      newSelected.removeAll(visibleValues);
                    } else {
                      // 미선택 또는 부분 선택 → 전체 선택
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
              constraints: const BoxConstraints(maxHeight: 240),
              child: isLoading || values.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Center(
                          child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2)),
                          const SizedBox(height: 8),
                          Text('값 로딩 중...',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade600)),
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
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 12),
              Text(_processError!,
                  style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 16),
              OutlinedButton(
                  onPressed: _reset, child: const Text('다시 시도')),
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
              _resultRow('총 매칭',
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
              TextButton(
                  onPressed: _reset, child: const Text('새 파일 매칭')),
            ],
          ],
        ),
      ),
    );
  }

  // ── Helpers ──

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

  Widget _loadingInfoRow(String label) {
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
          Container(
            width: 80,
            height: 14,
            decoration: BoxDecoration(
              color: Colors.grey.shade200,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _analyzingBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.orange.shade200),
      ),
      child: Row(
        children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.orange.shade600)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '대용량 파일 분석 중입니다. 잠시만 기다려주세요...',
              style:
                  TextStyle(fontSize: 12, color: Colors.orange.shade800),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detectionWarning(String? callnameCol, String? tongsiCol) {
    final missing = <String>[];
    if (callnameCol == null) missing.add('호출명칭');
    if (tongsiCol == null) missing.add('통시');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber, size: 16, color: Colors.red.shade600),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${missing.join(", ")} 컬럼을 자동 감지하지 못했습니다. '
              '파일의 첫 번째 행에 해당 컬럼명이 있는지 확인해주세요.',
              style:
                  TextStyle(fontSize: 12, color: Colors.red.shade700),
            ),
          ),
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
              style:
                  TextStyle(fontSize: 14, color: Colors.grey.shade700)),
          Text(value,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.bold)),
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
