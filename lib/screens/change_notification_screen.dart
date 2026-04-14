import 'dart:html' as html;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../widgets/progress_dialog.dart';

/// 변경개설신고 관리 화면
class ChangeNotificationScreen extends StatefulWidget {
  const ChangeNotificationScreen({super.key});

  @override
  State<ChangeNotificationScreen> createState() =>
      _ChangeNotificationScreenState();
}

class _ChangeNotificationScreenState extends State<ChangeNotificationScreen> {
  static const _primary = Color(0xFFE53935);
  static const _border = Color(0xFFE5E7EB);
  static const _surface = Colors.white;
  static const _bg = Color(0xFFF4F5F7);
  static const _textPrimary = Color(0xFF111827);
  static const _textSecondary = Color(0xFF6B7280);

  bool _processing = false;
  String? _result;
  String? _error;
  List<PlatformFile> _selectedFiles = [];

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
      final uri = Uri.parse(
        '${const String.fromEnvironment('API_BASE_URL', defaultValue: 'https://api-sko-kca.skons.net')}/document/change-notification',
      );
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer ${token ?? ''}'
        ..files.add(http.MultipartFile.fromBytes(
          'file1',
          _selectedFiles[0].bytes!,
          filename: _selectedFiles[0].name,
        ))
        ..files.add(http.MultipartFile.fromBytes(
          'file2',
          _selectedFiles[1].bytes!,
          filename: _selectedFiles[1].name,
        ));

      final streamed =
          await request.send().timeout(const Duration(minutes: 5));

      if (!mounted) return;

      if (streamed.statusCode == 200) {
        final bytes = await streamed.stream.toBytes();
        final changeCount = streamed.headers['x-change-count'] ?? '0';
        final targetCount = streamed.headers['x-target-count'] ?? '0';
        final changeTypesRaw = streamed.headers['x-change-types'] ?? '';
        final typeLabel = changeTypesRaw.isNotEmpty ? Uri.decodeComponent(changeTypesRaw) : '변경';
        final fileName = '변경적용($typeLabel)_DS파일.xlsx';

        // Auto download
        final blob = html.Blob([bytes],
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
        final url = html.Url.createObjectUrlFromBlob(blob);
        html.AnchorElement(href: url)
          ..setAttribute('download', fileName)
          ..click();
        html.Url.revokeObjectUrl(url);

        await dialog.complete(message: '변경 완료\n대상 $targetCount건, 적용 $changeCount건');
        setState(() => _result =
            '변경 대상: $targetCount건, 변경 적용: $changeCount건\n$fileName 다운로드 완료');
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

  void _showAlert(String title, String message) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Text(message, style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('확인')),
        ],
      ),
    );
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Title
                const Text(
                  '변경개설신고 관리',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: _textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '무선국 변경개설신고 파일(A)과 DS 파일(B) 2개를 업로드하면,\n변경 대상을 자동으로 비교하여 DS 파일에 반영된 결과를 다운로드합니다.',
                  style: TextStyle(
                    fontSize: 13,
                    color: _textSecondary,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 24),

                // Upload area card
                Container(
                  decoration: BoxDecoration(
                    color: _surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _border),
                  ),
                  child: Column(
                    children: [
                      // Drop zone
                      InkWell(
                        onTap: _processing ? null : _pickFiles,
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(12)),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFAFAFB),
                            borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(12)),
                          ),
                          child: Column(
                            children: [
                              Icon(
                                Icons.cloud_upload_outlined,
                                size: 48,
                                color: _primary.withValues(alpha: 0.6),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _selectedFiles.isEmpty
                                    ? '클릭하여 파일 2개를 선택하세요'
                                    : '파일이 선택되었습니다 (클릭하여 변경)',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: _textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '변경개설신고 파일 (A) + DS 파일 (B)  |  .xls, .xlsx',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Selected files display
                      if (_selectedFiles.isNotEmpty) ...[
                        const Divider(height: 1, color: _border),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              for (var i = 0; i < _selectedFiles.length; i++)
                                Padding(
                                  padding: EdgeInsets.only(
                                      bottom:
                                          i < _selectedFiles.length - 1 ? 8 : 0),
                                  child: Row(
                                    children: [
                                      Icon(Icons.insert_drive_file_outlined,
                                          size: 18, color: _primary),
                                      const SizedBox(width: 8),
                                      Text(
                                        i == 0 ? '파일 A: ' : '파일 B: ',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: _textSecondary,
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          _selectedFiles[i].name,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            color: _textPrimary,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Text(
                                        _formatSize(_selectedFiles[i].size),
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: _textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],

                      // Action button
                      const Divider(height: 1, color: _border),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: SizedBox(
                          width: double.infinity,
                          height: 44,
                          child: ElevatedButton.icon(
                            onPressed: _processing || _selectedFiles.length != 2
                                ? null
                                : _process,
                            icon: _processing
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.play_arrow, size: 20),
                            label: Text(
                              _processing ? '처리 중...' : '변경 적용 실행',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primary,
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: Colors.grey.shade300,
                              disabledForegroundColor: Colors.grey.shade500,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                              elevation: 0,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Result display
                if (_result != null)
                  Container(
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
                          child: Text(
                            _result!,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF166534),
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Error display
                if (_error != null)
                  Container(
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
                          child: Text(
                            _error!,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF991B1B),
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
