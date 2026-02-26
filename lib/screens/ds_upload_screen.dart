import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/ds_upload_service.dart';

/// DS 데이터 업로드 화면 - ZIP 파싱 → EC2 청크 업로드 → DynamoDB 적재
class DsUploadScreen extends StatefulWidget {
  const DsUploadScreen({super.key});

  @override
  State<DsUploadScreen> createState() => _DsUploadScreenState();
}

class _DsUploadScreenState extends State<DsUploadScreen> {
  static const Color _uploadColor = Color(0xFF42A5F5);

  final DsUploadService _uploadService = DsUploadService();

  bool _isProcessing = false;
  String _currentStage = '';
  double _progress = 0;
  String? _resultMessage;
  bool? _isSuccess;

  Future<void> _startUpload() async {
    final authService = context.read<AuthService>();
    final uploadedBy = authService.userId ?? 'unknown';

    setState(() {
      _isProcessing = true;
      _currentStage = '시작 중...';
      _progress = 0;
      _resultMessage = null;
      _isSuccess = null;
    });

    try {
      final message = await _uploadService.pickAndUpload(
        uploadedBy: uploadedBy,
        onProgress: (stage, percent) {
          if (mounted) {
            setState(() {
              _currentStage = stage;
              _progress = percent / 100;
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _isProcessing = false;
          _resultMessage = message;
          _isSuccess = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isProcessing = false;
          _resultMessage = e.toString().replaceFirst('Exception: ', '');
          _isSuccess = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        title: const Text('DS 데이터 업로드'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 600),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildHeader(),
                const SizedBox(height: 32),
                _buildInstructionsCard(),
                const SizedBox(height: 24),
                if (_isProcessing) _buildProgressSection(),
                if (_resultMessage != null) _buildResultSection(),
                const SizedBox(height: 24),
                _buildActionButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: _uploadColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Icon(Icons.cloud_upload_outlined, color: _uploadColor, size: 48),
        ),
        const SizedBox(height: 16),
        const Text(
          'DS 데이터 업로드',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'DS ZIP 파일을 파싱하여 서버 DB에 적재합니다',
          style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildInstructionsCard() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.info_outline, color: Colors.blue.shade400, size: 20),
            const SizedBox(width: 8),
            const Text(
              '사용 방법',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ]),
          const SizedBox(height: 12),
          _buildStep('1', '전파관리소에서 DS ZIP 파일을 다운로드합니다'),
          _buildStep('2', '아래 버튼을 클릭하여 ZIP 파일을 선택합니다'),
          _buildStep('3', '파일명에서 지역코드와 날짜가 자동 감지됩니다'),
          _buildStep('4', '파싱 후 서버 DB에 자동으로 적재됩니다'),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.shade200),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.lightbulb_outline, size: 16, color: Colors.amber.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '파일명 형식: SKT(50)20260203.xls\n'
                    '(50) = 지역코드, 20260203 = 날짜',
                    style: TextStyle(fontSize: 12, color: Colors.amber.shade900),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _uploadColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Text(
              number,
              style: const TextStyle(
                color: _uploadColor,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _buildProgressSection() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _progress,
              backgroundColor: Colors.grey.shade200,
              valueColor: const AlwaysStoppedAnimation<Color>(_uploadColor),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _currentStage,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 4),
          Text(
            '${(_progress * 100).toInt()}%',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultSection() {
    final isOk = _isSuccess == true;
    final color = isOk ? Colors.green : Colors.red;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isOk ? Icons.check_circle : Icons.error,
            color: color,
            size: 22,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _resultMessage!,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade800),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton() {
    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        onPressed: _isProcessing ? null : _startUpload,
        icon: Icon(_isProcessing ? Icons.hourglass_top : Icons.cloud_upload),
        label: Text(
          _isProcessing ? '업로드 진행 중...' : 'ZIP 파일 선택 및 업로드 시작',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _uploadColor,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey.shade300,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
