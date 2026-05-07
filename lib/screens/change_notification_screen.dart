import 'dart:convert';
import 'dart:html' as html;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../widgets/progress_dialog.dart';

class ChangeNotificationScreen extends StatefulWidget {
  const ChangeNotificationScreen({super.key});

  @override
  State<ChangeNotificationScreen> createState() =>
      _ChangeNotificationScreenState();
}

class _ChangeNotificationScreenState extends State<ChangeNotificationScreen> {
  static const _primary = Color(0xFFE53935);
  static const _blue = Color(0xFF1E88E5);
  static const _border = Color(0xFFE5E7EB);
  static const _surface = Colors.white;
  static const _bg = Color(0xFFF4F5F7);
  static const _textPrimary = Color(0xFF111827);
  static const _textSecondary = Color(0xFF6B7280);

  bool _processing = false;
  bool _applying = false;
  bool _downloadingTemplate = false;
  bool _uploadingTemplate = false;
  String? _result;
  String? _error;
  List<PlatformFile> _selectedFiles = [];

  // diff 상태
  List<Map<String, dynamic>> _diff = [];
  Set<String> _selectedStations = {};

  static const _apiBase = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  Future<void> _downloadSample() async {
    setState(() => _downloadingTemplate = true);
    try {
      final token = context.read<AuthService>().authToken;
      final resp = await http.get(
        Uri.parse('$_apiBase/document/change-notification-sample'),
        headers: {'Authorization': 'Bearer ${token ?? ''}'},
      ).timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (resp.statusCode == 200) {
        final url = (json.decode(resp.body) as Map<String, dynamic>)['url'] as String? ?? '';
        if (url.isNotEmpty) {
          html.AnchorElement(href: url).click();
        }
      } else if (resp.statusCode == 404) {
        _showAlert('샘플 없음', '샘플 양식 파일이 없습니다. 관리자에게 문의하세요.');
      } else {
        _showAlert('오류', '다운로드 실패: ${resp.body}');
      }
    } catch (e) {
      if (mounted) _showAlert('오류', '다운로드 중 오류: $e');
    } finally {
      if (mounted) setState(() => _downloadingTemplate = false);
    }
  }

  Future<void> _uploadSample() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xls', 'xlsx', 'zip'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    setState(() => _uploadingTemplate = true);
    try {
      final token = context.read<AuthService>().authToken;
      final uri = Uri.parse('$_apiBase/document/change-notification-sample');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer ${token ?? ''}'
        ..files.add(http.MultipartFile.fromBytes('file', file.bytes!, filename: file.name));
      final streamed = await request.send().timeout(const Duration(minutes: 2));
      if (!mounted) return;
      if (streamed.statusCode == 200) {
        _showAlert('업로드 완료', '샘플 양식이 업로드되었습니다.');
      } else {
        final body = await streamed.stream.bytesToString();
        if (!mounted) return;
        _showAlert('업로드 실패', body);
      }
    } catch (e) {
      if (mounted) _showAlert('오류', '업로드 중 오류: $e');
    } finally {
      if (mounted) setState(() => _uploadingTemplate = false);
    }
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xls', 'xlsx'],
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    if (result.files.length != 2) {
      _showAlert('파일 2개를 선택해주세요', '변경개설신고 파일과 DS 파일을 함께 선택해주세요.');
      return;
    }
    setState(() {
      _selectedFiles = result.files;
      _result = null;
      _error = null;
      _diff = [];
      _selectedStations = {};
    });
  }

  Future<void> _process() async {
    if (_selectedFiles.length != 2) {
      _showAlert('파일 미선택', '파일 2개를 먼저 선택해주세요.');
      return;
    }
    final dialog = ProgressDialog(context);
    dialog.show(message: '변경 적용 중...');
    try {
      final token = context.read<AuthService>().authToken;
      final uri = Uri.parse('$_apiBase/document/change-notification');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer ${token ?? ''}'
        ..files.add(http.MultipartFile.fromBytes(
          'file1', _selectedFiles[0].bytes!, filename: _selectedFiles[0].name))
        ..files.add(http.MultipartFile.fromBytes(
          'file2', _selectedFiles[1].bytes!, filename: _selectedFiles[1].name));

      final streamed = await request.send().timeout(const Duration(minutes: 5));
      if (!mounted) return;

      if (streamed.statusCode == 200) {
        final bodyBytes = await streamed.stream.toBytes();
        final bodyJson = json.decode(utf8.decode(bodyBytes)) as Map<String, dynamic>;

        final xlsB64 = bodyJson['xls_base64'] as String? ?? '';
        final filename = bodyJson['filename'] as String? ?? '변경적용_DS파일.xls';
        final changeCount = bodyJson['change_count'] as int? ?? 0;
        final targetCount = bodyJson['target_count'] as int? ?? 0;
        final diffRaw = (bodyJson['diff'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();

        // xls 자동 다운로드
        if (xlsB64.isNotEmpty) {
          final bytes = base64Decode(xlsB64);
          final blob = html.Blob([bytes], 'application/vnd.ms-excel');
          final url = html.Url.createObjectUrlFromBlob(blob);
          html.AnchorElement(href: url)
            ..setAttribute('download', filename)
            ..click();
          html.Url.revokeObjectUrl(url);
        }

        await dialog.complete(message: '변경 완료\n대상 $targetCount건, 적용 $changeCount건');
        setState(() {
          _result = '변경 대상: $targetCount건, 변경 적용: $changeCount건\n$filename 다운로드 완료';
          _diff = diffRaw;
          _selectedStations = diffRaw.map((d) => d['허가번호'] as String).toSet();
        });
      } else {
        final body = await streamed.stream.bytesToString();
        await dialog.error(message: '처리 실패');
        setState(() => _error = '처리 실패: $body');
      }
    } catch (e) {
      if (mounted) await dialog.error(message: '오류 발생');
      setState(() => _error = '오류: $e');
    }
  }

  Future<void> _applyChanges() async {
    if (_selectedStations.isEmpty) return;
    setState(() => _applying = true);
    try {
      final token = context.read<AuthService>().authToken;
      final now = DateTime.now();
      final dateStr =
          '${now.year.toString().substring(2)}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final uri = Uri.parse('$_apiBase/document/apply-change-notification');
      final resp = await http
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer ${token ?? ''}',
              'Content-Type': 'application/json',
            },
            body: json.encode({
              'selected': _selectedStations.toList(),
              'diff': _diff,
              'applied_date': dateStr,
            }),
          )
          .timeout(const Duration(minutes: 2));

      if (!mounted) return;
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final notFound = (data['not_found'] as List<dynamic>? ?? []).cast<String>();
        setState(() {
          _applying = false;
          _diff.removeWhere((d) => _selectedStations.contains(d['허가번호']));
          _selectedStations.clear();
        });
        if (notFound.isNotEmpty) {
          _showAlert(
            '반영 완료 (일부 경고)',
            '${data['applied']}건 반영 완료.\n\n'
            '아래 국소는 수검 대상 또는 DS 데이터에 없어 반영되지 않았습니다:\n'
            '${notFound.join('\n')}',
          );
        } else {
          _showAlert('반영 완료',
              '${data['applied']}건 변경이 수검결과 화면에 반영되었습니다.\n변경된 필드 옆에 ($dateStr 변경) 배지가 표시됩니다.');
        }
      } else {
        setState(() => _applying = false);
        _showAlert('반영 실패', '서버 오류: ${resp.body}');
      }
    } catch (e) {
      if (mounted) setState(() => _applying = false);
      _showAlert('오류', '반영 중 오류: $e');
    }
  }

  void _showAlert(String title, String message) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Text(message, style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('확인')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('변경개설신고 관리',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: _textPrimary)),
                const SizedBox(height: 8),
                Text(
                  '무선국 변경개설신고 파일(A)과 DS 파일(B) 2개를 업로드하면,\n'
                  '변경 대상을 자동으로 비교하여 DS 파일에 반영된 결과를 다운로드하고\n'
                  '수검결과 화면에도 즉시 반영할 수 있습니다.',
                  style: TextStyle(fontSize: 13, color: _textSecondary, height: 1.6),
                ),
                const SizedBox(height: 16),
                _buildSampleRow(),
                const SizedBox(height: 24),

                // 업로드 카드
                _buildUploadCard(),

                const SizedBox(height: 16),

                // 결과 메시지
                if (_result != null) _buildResultBanner(),
                if (_error != null) _buildErrorBanner(),

                // diff 섹션
                if (_diff.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _buildDiffSection(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSampleRow() {
    final isAdmin = context.read<AuthService>().isAdmin;
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: _downloadingTemplate ? null : _downloadSample,
          icon: _downloadingTemplate
              ? const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: _blue))
              : const Icon(Icons.download, size: 16, color: _blue),
          label: const Text('샘플 양식 다운로드',
              style: TextStyle(fontSize: 13, color: _blue)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: _blue),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
        ),
        if (isAdmin) ...[
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: _uploadingTemplate ? null : _uploadSample,
            icon: _uploadingTemplate
                ? const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.upload, size: 16),
            label: const Text('샘플 업로드', style: TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(
              foregroundColor: _textSecondary,
              side: const BorderSide(color: _border),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildUploadCard() {
    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: _processing ? null : _pickFiles,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 36),
              decoration: const BoxDecoration(
                color: Color(0xFFFAFAFB),
                borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Column(
                children: [
                  Icon(Icons.cloud_upload_outlined,
                      size: 44, color: _primary.withValues(alpha: 0.6)),
                  const SizedBox(height: 10),
                  Text(
                    _selectedFiles.isEmpty
                        ? '클릭하여 파일 2개를 선택하세요'
                        : '파일이 선택되었습니다 (클릭하여 변경)',
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _textPrimary),
                  ),
                  const SizedBox(height: 4),
                  const Text('변경개설신고 파일 (A) + DS 파일 (B)  |  .xls, .xlsx',
                      style: TextStyle(fontSize: 12, color: _textSecondary)),
                ],
              ),
            ),
          ),
          if (_selectedFiles.isNotEmpty) ...[
            const Divider(height: 1, color: _border),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (var i = 0; i < _selectedFiles.length; i++)
                    Padding(
                      padding: EdgeInsets.only(
                          bottom: i < _selectedFiles.length - 1 ? 8 : 0),
                      child: Row(
                        children: [
                          Icon(Icons.insert_drive_file_outlined,
                              size: 18, color: _primary),
                          const SizedBox(width: 8),
                          Text(i == 0 ? '파일 A: ' : '파일 B: ',
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: _textSecondary)),
                          Expanded(
                            child: Text(_selectedFiles[i].name,
                                style: const TextStyle(
                                    fontSize: 13, color: _textPrimary),
                                overflow: TextOverflow.ellipsis),
                          ),
                          Text(_formatSize(_selectedFiles[i].size),
                              style: const TextStyle(
                                  fontSize: 11, color: _textSecondary)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          const Divider(height: 1, color: _border),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                onPressed:
                    _processing || _selectedFiles.length != 2 ? null : _process,
                icon: _processing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_arrow, size: 20),
                label: Text(_processing ? '처리 중...' : '변경 적용 실행',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade300,
                  disabledForegroundColor: Colors.grey.shade500,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultBanner() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF16A34A), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_result!,
                style: const TextStyle(
                    fontSize: 13, color: Color(0xFF166534), height: 1.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_error!,
                style: const TextStyle(
                    fontSize: 13, color: Color(0xFF991B1B), height: 1.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildDiffSection() {
    final allSelected = _diff.isNotEmpty &&
        _selectedStations.length == _diff.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // diff 카드
        Container(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 헤더
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Text('변경 내역',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: _textPrimary)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: _primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('${_diff.length}개 국소',
                          style: const TextStyle(
                              fontSize: 12,
                              color: _primary,
                              fontWeight: FontWeight.w600)),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() {
                        if (allSelected) {
                          _selectedStations.clear();
                        } else {
                          _selectedStations = _diff
                              .map((d) => d['허가번호'] as String)
                              .toSet();
                        }
                      }),
                      style: TextButton.styleFrom(
                        foregroundColor: _blue,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(allSelected ? '전체 해제' : '전체 선택',
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: _border),

              // 국소 리스트
              ..._diff.asMap().entries.map((entry) {
                final idx = entry.key;
                final station = entry.value;
                final hn = station['허가번호'] as String;
                final callname = station['호출명칭'] as String? ?? '';
                final changes = (station['changes'] as List<dynamic>? ?? [])
                    .cast<Map<String, dynamic>>();
                final isSelected = _selectedStations.contains(hn);

                return Column(
                  children: [
                    if (idx > 0) const Divider(height: 1, color: _border),
                    InkWell(
                      onTap: () => setState(() {
                        if (isSelected) {
                          _selectedStations.remove(hn);
                        } else {
                          _selectedStations.add(hn);
                        }
                      }),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 12, 16, 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Checkbox(
                              value: isSelected,
                              onChanged: (_) => setState(() {
                                if (isSelected) {
                                  _selectedStations.remove(hn);
                                } else {
                                  _selectedStations.add(hn);
                                }
                              }),
                              activeColor: _blue,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    callname.isNotEmpty ? callname : hn,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: _textPrimary),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(hn,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: _textSecondary)),
                                  const SizedBox(height: 8),
                                  ...changes.map(_buildChangeRow),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // 반영 버튼
        SizedBox(
          height: 44,
          child: ElevatedButton.icon(
            onPressed: _selectedStations.isEmpty || _applying
                ? null
                : _applyChanges,
            icon: _applying
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_alt, size: 20),
            label: Text(
              _applying
                  ? '반영 중...'
                  : '선택 반영 (${_selectedStations.length}개 국소)',
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _blue,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey.shade300,
              disabledForegroundColor: Colors.grey.shade500,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChangeRow(Map<String, dynamic> change) {
    final field = change['field'] as String? ?? '';
    final before = change['before'] as String? ?? '';
    final after = change['after'] as String? ?? '';
    final jn = change['장치번호'] as String? ?? '';
    final label = field + (jn.isNotEmpty ? ' (장치$jn)' : '');

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label,
                style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFE65100),
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 12, color: _textPrimary),
                children: [
                  if (before.isNotEmpty) ...[
                    TextSpan(
                        text: before,
                        style: const TextStyle(
                            color: Color(0xFF9E9E9E),
                            decoration: TextDecoration.lineThrough)),
                    const TextSpan(text: '  →  '),
                  ],
                  TextSpan(
                      text: after,
                      style: const TextStyle(
                          color: Color(0xFF1B5E20),
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
