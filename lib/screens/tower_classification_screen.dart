import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:typed_data';
import '../services/tower_classification_service.dart';

/// 철탑형태 분류 화면 - AI 자동 분류
class TowerClassificationScreen extends StatefulWidget {
  const TowerClassificationScreen({super.key});

  @override
  State<TowerClassificationScreen> createState() => _TowerClassificationScreenState();
}

class _TowerClassificationScreenState extends State<TowerClassificationScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TowerClassificationService _classificationService = TowerClassificationService();
  final ImagePicker _imagePicker = ImagePicker();

  // 상태
  bool _isLoading = false;
  bool _isServerConnected = false;
  bool _isModelLoaded = false;
  bool _isCheckingServer = true;
  String? _errorMessage;

  // 단일 이미지 분류
  List<SelectedImage> _selectedImages = [];
  ClassificationResult? _singleResult;

  // 앙상블 분류
  List<SelectedImage> _ensembleImages = [];
  EnsembleResult? _ensembleResult;
  String _ensembleMethod = 'mean';

  // 테마 색상
  static const Color _primaryColor = Color(0xFFE53935);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _checkServerConnection();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// 서버 연결 상태 확인
  Future<void> _checkServerConnection() async {
    setState(() => _isCheckingServer = true);
    try {
      final status = await _classificationService.checkServerConnection();
      setState(() {
        _isServerConnected = status.isConnected;
        _isModelLoaded = status.isModelLoaded;
        _isCheckingServer = false;
        _errorMessage = null;

        if (!status.isConnected) {
          _errorMessage = '분류 서버에 연결할 수 없습니다.';
        } else if (!status.isModelLoaded) {
          _errorMessage = 'AI 모델이 로드되지 않았습니다.';
        }
      });
    } catch (e) {
      setState(() {
        _isServerConnected = false;
        _isModelLoaded = false;
        _isCheckingServer = false;
        _errorMessage = '서버 연결 확인 실패: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          '철탑형태 분류',
          style: TextStyle(
            color: Colors.black87,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
        actions: [
          // 서버 상태 표시
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: _buildServerStatusIndicator(),
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: _primaryColor,
          unselectedLabelColor: Colors.grey,
          indicatorColor: _primaryColor,
          tabs: const [
            Tab(text: '단일 이미지', icon: Icon(Icons.image)),
            Tab(text: '앙상블', icon: Icon(Icons.collections)),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildSingleImageTab(),
          _buildEnsembleTab(),
        ],
      ),
    );
  }

  /// 서버 상태 인디케이터
  Widget _buildServerStatusIndicator() {
    if (_isCheckingServer) {
      return const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    // 서버 연결됨 + 모델 로드됨 = 초록색
    // 서버 연결됨 + 모델 미로드 = 주황색
    // 서버 연결 안됨 = 빨간색
    final Color iconColor;
    final IconData iconData;
    final String tooltip;

    if (_isServerConnected && _isModelLoaded) {
      iconColor = Colors.green;
      iconData = Icons.cloud_done;
      tooltip = '서버 연결됨 (모델 준비 완료)';
    } else if (_isServerConnected && !_isModelLoaded) {
      iconColor = Colors.orange;
      iconData = Icons.cloud_sync;
      tooltip = '서버 연결됨 (모델 미로드)';
    } else {
      iconColor = Colors.red;
      iconData = Icons.cloud_off;
      tooltip = '서버 연결 안됨';
    }

    return IconButton(
      icon: Icon(iconData, color: iconColor),
      tooltip: tooltip,
      onPressed: _checkServerConnection,
    );
  }

  /// 단일 이미지 탭
  Widget _buildSingleImageTab() {
    return Container(
      color: const Color(0xFFF5F5F5),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 에러 메시지
            if (_errorMessage != null) _buildErrorBanner(),

            // 서버 연결 안됨 또는 모델 미로드 경고
            if ((!_isServerConnected || !_isModelLoaded) && !_isCheckingServer)
              _buildServerWarning(),

            // 이미지 선택 카드
            _buildImageSelectionCard(
              images: _selectedImages,
              maxImages: 1,
              onPickGallery: () => _pickImage(false),
              onPickCamera: () => _pickImage(true),
              onRemove: (index) {
                setState(() {
                  _selectedImages.removeAt(index);
                  _singleResult = null;
                });
              },
            ),
            const SizedBox(height: 16),

            // 분류 버튼 (서버 연결 + 모델 로드 필요)
            if (_selectedImages.isNotEmpty)
              _buildClassifyButton(
                onPressed: _isLoading || !_isServerConnected || !_isModelLoaded ? null : _classifySingleImage,
                label: '분류 실행',
              ),

            // 분류 결과
            if (_singleResult != null) ...[
              const SizedBox(height: 24),
              _buildSingleResultCard(_singleResult!),
            ],
          ],
        ),
      ),
    );
  }

  /// 앙상블 탭
  Widget _buildEnsembleTab() {
    return Container(
      color: const Color(0xFFF5F5F5),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 에러 메시지
            if (_errorMessage != null) _buildErrorBanner(),

            // 서버 연결 안됨 또는 모델 미로드 경고
            if ((!_isServerConnected || !_isModelLoaded) && !_isCheckingServer)
              _buildServerWarning(),

            // 앙상블 방법 선택
            _buildEnsembleMethodCard(),
            const SizedBox(height: 16),

            // 이미지 선택 카드
            _buildImageSelectionCard(
              images: _ensembleImages,
              maxImages: 10,
              onPickGallery: () => _pickEnsembleImage(false),
              onPickCamera: () => _pickEnsembleImage(true),
              onRemove: (index) {
                setState(() {
                  _ensembleImages.removeAt(index);
                  _ensembleResult = null;
                });
              },
            ),
            const SizedBox(height: 16),

            // 분류 버튼 (서버 연결 + 모델 로드 필요)
            if (_ensembleImages.length >= 2)
              _buildClassifyButton(
                onPressed: _isLoading || !_isServerConnected || !_isModelLoaded ? null : _classifyEnsemble,
                label: '앙상블 분류 실행 (${_ensembleImages.length}장)',
              ),

            // 분류 결과
            if (_ensembleResult != null) ...[
              const SizedBox(height: 24),
              _buildEnsembleResultCard(_ensembleResult!),
            ],
          ],
        ),
      ),
    );
  }

  /// 에러 배너
  Widget _buildErrorBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: Colors.red[50],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red[200]!),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: Colors.red, fontSize: 13),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() => _errorMessage = null),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  /// 서버 연결 경고
  Widget _buildServerWarning() {
    // 서버 연결됨 + 모델 미로드
    if (_isServerConnected && !_isModelLoaded) {
      return Container(
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.orange[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange[200]!),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.model_training, color: Colors.orange, size: 36),
            const SizedBox(height: 8),
            const Text(
              'AI 모델이 로드되지 않았습니다',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.orange),
            ),
            const SizedBox(height: 4),
            Text(
              '모델 파일을 찾을 수 없습니다.',
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _checkServerConnection,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('다시 확인', style: TextStyle(fontSize: 12)),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.orange,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              ),
            ),
          ],
        ),
      );
    }

    // 서버 연결 안됨
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.red[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red[200]!),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off, color: Colors.red[700], size: 36),
          const SizedBox(height: 8),
          Text(
            '분류 서버에 연결할 수 없습니다',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.red[700]),
          ),
          const SizedBox(height: 4),
          Text(
            '서버 실행 여부를 확인해주세요.',
            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _checkServerConnection,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('다시 연결', style: TextStyle(fontSize: 12)),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.red,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
          ),
        ],
      ),
    );
  }

  /// 앙상블 방법 선택 카드
  Widget _buildEnsembleMethodCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune, color: _primaryColor, size: 24),
                const SizedBox(width: 8),
                const Text(
                  '앙상블 방법',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _buildMethodChip('mean', '평균'),
                const SizedBox(width: 8),
                _buildMethodChip('max', '최대값'),
                const SizedBox(width: 8),
                _buildMethodChip('vote', '투표'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _getMethodDescription(),
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMethodChip(String value, String label) {
    final isSelected = _ensembleMethod == value;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() {
            _ensembleMethod = value;
            _ensembleResult = null;
          });
        }
      },
      selectedColor: _primaryColor.withValues(alpha: 0.2),
      labelStyle: TextStyle(
        color: isSelected ? _primaryColor : Colors.grey[700],
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      ),
    );
  }

  String _getMethodDescription() {
    switch (_ensembleMethod) {
      case 'mean':
        return '모든 이미지의 예측 확률을 평균하여 최종 결과 도출';
      case 'max':
        return '각 클래스별 최대 확률값을 사용하여 최종 결과 도출';
      case 'vote':
        return '각 이미지의 예측 결과에 투표하여 다수결로 최종 결과 도출';
      default:
        return '';
    }
  }

  /// 이미지 선택 카드
  Widget _buildImageSelectionCard({
    required List<SelectedImage> images,
    required int maxImages,
    required VoidCallback onPickGallery,
    required VoidCallback onPickCamera,
    required Function(int) onRemove,
  }) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.photo_library, color: _primaryColor, size: 24),
                const SizedBox(width: 8),
                Text(
                  maxImages == 1 ? '이미지 선택' : '이미지 선택 (${images.length}/$maxImages)',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              maxImages == 1
                  ? '분류할 철탑/안테나 사진을 선택하세요.'
                  : '동일 철탑의 여러 각도 사진을 선택하세요. (2~10장)',
              style: TextStyle(fontSize: 13, color: Colors.grey[600]),
            ),
            const SizedBox(height: 16),

            // 선택된 이미지 표시
            if (images.isNotEmpty)
              SizedBox(
                height: 120,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: images.length + (images.length < maxImages ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index < images.length) {
                      return _buildImageThumbnail(images[index], () => onRemove(index));
                    }
                    // 추가 버튼
                    return _buildAddButton(onPickGallery);
                  },
                ),
              )
            else
              // 이미지 선택 버튼
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onPickGallery,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('갤러리'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: BorderSide(color: _primaryColor),
                        foregroundColor: _primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onPickCamera,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: const Text('카메라'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: BorderSide(color: _primaryColor),
                        foregroundColor: _primaryColor,
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageThumbnail(SelectedImage image, VoidCallback onRemove) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              image.bytes,
              width: 100,
              height: 100,
              fit: BoxFit.cover,
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.red,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddButton(VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 100,
        height: 100,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          color: Colors.grey[200],
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey[400]!, style: BorderStyle.solid),
        ),
        child: Icon(Icons.add_photo_alternate, size: 32, color: Colors.grey[600]),
      ),
    );
  }

  /// 분류 버튼
  Widget _buildClassifyButton({
    required VoidCallback? onPressed,
    required String label,
  }) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        backgroundColor: _primaryColor,
        foregroundColor: Colors.white,
        disabledBackgroundColor: Colors.grey[300],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: _isLoading
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.auto_fix_high, size: 20),
                const SizedBox(width: 8),
                Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ],
            ),
    );
  }

  /// 단일 분류 결과 카드
  Widget _buildSingleResultCard(ClassificationResult result) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.analytics, color: _primaryColor, size: 24),
                const SizedBox(width: 8),
                const Text(
                  '분류 결과',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (result.processingTimeMs != null)
                  Text(
                    '${result.processingTimeMs!.toStringAsFixed(0)}ms',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
              ],
            ),
            const Divider(height: 24),

            // 메인 결과
            _buildMainResult(
              className: result.classNameKr,
              shortName: result.shortName,
              confidence: result.confidence,
              isConfident: result.isConfident,
            ),
            const SizedBox(height: 16),

            // Top-5 결과
            _buildTop5Results(result.top5),

            // 피드백 버튼
            const SizedBox(height: 16),
            _buildFeedbackButton(
              originalClassEn: result.className,
              originalClassKr: result.classNameKr,
              imageBytes: _selectedImages.isNotEmpty ? _selectedImages.first.bytes : null,
              filename: _selectedImages.isNotEmpty ? _selectedImages.first.name : null,
            ),
          ],
        ),
      ),
    );
  }

  /// 앙상블 결과 카드
  Widget _buildEnsembleResultCard(EnsembleResult result) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.analytics, color: _primaryColor, size: 24),
                const SizedBox(width: 8),
                const Text(
                  '앙상블 결과',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${result.method.toUpperCase()} (${result.numImages}장)',
                    style: TextStyle(fontSize: 11, color: Colors.blue[700]),
                  ),
                ),
              ],
            ),
            if (result.processingTimeMs != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '처리 시간: ${result.processingTimeMs!.toStringAsFixed(0)}ms',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
              ),
            const Divider(height: 24),

            // 최종 결과
            _buildMainResult(
              className: result.finalPrediction.classNameKr,
              shortName: result.finalPrediction.shortName,
              confidence: result.finalPrediction.confidence,
              isConfident: result.isConfident,
            ),
            const SizedBox(height: 16),

            // 개별 이미지 결과
            const Text(
              '개별 이미지 결과',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            ...result.individualPredictions.map((p) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      p.filename,
                      style: const TextStyle(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    p.predictionKr,
                    style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(p.confidence * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: p.confidence >= 0.5 ? Colors.green : Colors.orange,
                    ),
                  ),
                ],
              ),
            )),

            const SizedBox(height: 16),
            // Top-5 결과
            _buildTop5Results(result.finalPrediction.top5),

            // 피드백 버튼 (앙상블 결과에도 추가)
            const SizedBox(height: 16),
            _buildFeedbackButton(
              originalClassEn: result.finalPrediction.className,
              originalClassKr: result.finalPrediction.classNameKr,
              imageBytes: _ensembleImages.isNotEmpty ? _ensembleImages.first.bytes : null,
              filename: _ensembleImages.isNotEmpty ? _ensembleImages.first.name : null,
            ),
          ],
        ),
      ),
    );
  }

  /// 메인 결과 위젯
  Widget _buildMainResult({
    required String className,
    required String shortName,
    required double confidence,
    required bool isConfident,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isConfident ? Colors.green[50] : Colors.orange[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isConfident ? Colors.green[200]! : Colors.orange[200]!,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isConfident ? Colors.green : Colors.orange,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              isConfident ? Icons.check_circle : Icons.warning,
              color: Colors.white,
              size: 32,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shortName,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  className,
                  style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${(confidence * 100).toStringAsFixed(1)}%',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: isConfident ? Colors.green[700] : Colors.orange[700],
                ),
              ),
              Text(
                isConfident ? '신뢰도 높음' : '신뢰도 낮음',
                style: TextStyle(
                  fontSize: 11,
                  color: isConfident ? Colors.green[700] : Colors.orange[700],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Top-5 결과 위젯
  Widget _buildTop5Results(List<Top5Prediction> top5) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Top-5 예측',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        ...top5.map((p) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: p.rank == 1 ? _primaryColor : Colors.grey[300],
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${p.rank}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: p.rank == 1 ? Colors.white : Colors.grey[700],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  p.classNameKr,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              SizedBox(
                width: 100,
                child: LinearProgressIndicator(
                  value: p.confidence,
                  backgroundColor: Colors.grey[200],
                  valueColor: AlwaysStoppedAnimation<Color>(
                    p.rank == 1 ? _primaryColor : Colors.grey,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 50,
                child: Text(
                  '${(p.confidence * 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: p.rank == 1 ? FontWeight.bold : FontWeight.normal,
                    color: p.rank == 1 ? _primaryColor : Colors.grey[700],
                  ),
                  textAlign: TextAlign.right,
                ),
              ),
            ],
          ),
        )),
      ],
    );
  }

  /// 이미지 선택 (단일)
  Future<void> _pickImage(bool fromCamera) async {
    try {
      final pickedFile = await _imagePicker.pickImage(
        source: fromCamera ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );

      if (pickedFile != null) {
        final bytes = await pickedFile.readAsBytes();
        setState(() {
          _selectedImages = [SelectedImage(name: pickedFile.name, bytes: bytes)];
          _singleResult = null;
          _errorMessage = null;
        });
      }
    } catch (e) {
      setState(() => _errorMessage = '이미지 선택 오류: $e');
    }
  }

  /// 이미지 선택 (앙상블)
  Future<void> _pickEnsembleImage(bool fromCamera) async {
    if (_ensembleImages.length >= 10) {
      setState(() => _errorMessage = '최대 10장까지 선택 가능합니다.');
      return;
    }

    try {
      if (fromCamera) {
        final pickedFile = await _imagePicker.pickImage(
          source: ImageSource.camera,
          maxWidth: 1024,
          maxHeight: 1024,
          imageQuality: 85,
        );
        if (pickedFile != null) {
          final bytes = await pickedFile.readAsBytes();
          setState(() {
            _ensembleImages.add(SelectedImage(name: pickedFile.name, bytes: bytes));
            _ensembleResult = null;
            _errorMessage = null;
          });
        }
      } else {
        final pickedFiles = await _imagePicker.pickMultiImage(
          maxWidth: 1024,
          maxHeight: 1024,
          imageQuality: 85,
        );
        for (final file in pickedFiles) {
          if (_ensembleImages.length >= 10) break;
          final bytes = await file.readAsBytes();
          setState(() {
            _ensembleImages.add(SelectedImage(name: file.name, bytes: bytes));
          });
        }
        setState(() {
          _ensembleResult = null;
          _errorMessage = null;
        });
      }
    } catch (e) {
      setState(() => _errorMessage = '이미지 선택 오류: $e');
    }
  }

  /// 단일 이미지 분류 실행
  Future<void> _classifySingleImage() async {
    if (_selectedImages.isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await _classificationService.classifySingle(
        _selectedImages.first.bytes,
        _selectedImages.first.name,
      );

      setState(() {
        _singleResult = result;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = '분류 실패: $e';
        _isLoading = false;
      });
    }
  }

  /// 앙상블 분류 실행
  Future<void> _classifyEnsemble() async {
    if (_ensembleImages.length < 2) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await _classificationService.classifyEnsemble(
        _ensembleImages.map((e) => e.bytes).toList(),
        _ensembleImages.map((e) => e.name).toList(),
        method: _ensembleMethod,
      );

      setState(() {
        _ensembleResult = result;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = '앙상블 분류 실패: $e';
        _isLoading = false;
      });
    }
  }

  /// 피드백 버튼 위젯
  Widget _buildFeedbackButton({
    required String originalClassEn,
    required String originalClassKr,
    Uint8List? imageBytes,
    String? filename,
  }) {
    return OutlinedButton.icon(
      onPressed: imageBytes != null && filename != null
          ? () => _showClassSelectionDialog(
                originalClassEn: originalClassEn,
                originalClassKr: originalClassKr,
                imageBytes: imageBytes,
                filename: filename,
              )
          : null,
      icon: const Icon(Icons.edit_note, size: 18),
      label: const Text('결과 수정'),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.orange[700],
        side: BorderSide(color: Colors.orange[300]!),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      ),
    );
  }

  /// 클래스 선택 다이얼로그 표시
  Future<void> _showClassSelectionDialog({
    required String originalClassEn,
    required String originalClassKr,
    required Uint8List imageBytes,
    required String filename,
  }) async {
    final classOptions = TowerClassificationService.getClassOptions();

    final selectedClass = await showDialog<ClassOption>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.edit, color: _primaryColor, size: 24),
            const SizedBox(width: 8),
            const Text('올바른 클래스 선택', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 18, color: Colors.grey),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '현재 분류: $originalClassKr',
                        style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '올바른 철탑 유형을 선택해주세요:',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: classOptions.length,
                  itemBuilder: (context, index) {
                    final option = classOptions[index];
                    final isCurrentClass = option.englishName == originalClassEn;

                    return ListTile(
                      dense: true,
                      leading: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: isCurrentClass ? Colors.grey[300] : _primaryColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${option.id + 1}',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: isCurrentClass ? Colors.grey : _primaryColor,
                          ),
                        ),
                      ),
                      title: Text(
                        option.shortName,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: isCurrentClass ? Colors.grey : Colors.black87,
                        ),
                      ),
                      subtitle: Text(
                        option.koreanName,
                        style: TextStyle(
                          fontSize: 12,
                          color: isCurrentClass ? Colors.grey : Colors.grey[600],
                        ),
                      ),
                      trailing: isCurrentClass
                          ? Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.grey[200],
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                '현재',
                                style: TextStyle(fontSize: 11, color: Colors.grey),
                              ),
                            )
                          : const Icon(Icons.chevron_right, color: Colors.grey),
                      enabled: !isCurrentClass,
                      onTap: isCurrentClass ? null : () => Navigator.of(context).pop(option),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
        ],
      ),
    );

    // 클래스가 선택되었으면 피드백 제출
    if (selectedClass != null) {
      await _submitFeedback(
        imageBytes: imageBytes,
        filename: filename,
        originalClass: originalClassEn,
        correctedClass: selectedClass.englishName,
        correctedClassKr: selectedClass.shortName,
      );
    }
  }

  /// 피드백 제출
  Future<void> _submitFeedback({
    required Uint8List imageBytes,
    required String filename,
    required String originalClass,
    required String correctedClass,
    required String correctedClassKr,
  }) async {
    // 로딩 다이얼로그 표시
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('피드백 저장 중...'),
          ],
        ),
      ),
    );

    try {
      final result = await _classificationService.submitFeedback(
        imageBytes: imageBytes,
        filename: filename,
        originalClass: originalClass,
        correctedClass: correctedClass,
      );

      // 로딩 다이얼로그 닫기
      if (mounted) Navigator.of(context).pop();

      // 결과 표시
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(
                  result.success ? Icons.check_circle : Icons.error,
                  color: Colors.white,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    result.success
                        ? '피드백이 저장되었습니다. (수정: $correctedClassKr)'
                        : result.message,
                  ),
                ),
              ],
            ),
            backgroundColor: result.success ? Colors.green : Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      // 로딩 다이얼로그 닫기
      if (mounted) Navigator.of(context).pop();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('피드백 저장 실패: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

/// 선택된 이미지 데이터
class SelectedImage {
  final String name;
  final Uint8List bytes;

  SelectedImage({required this.name, required this.bytes});
}
