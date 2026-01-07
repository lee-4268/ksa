import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../models/radio_station.dart';
import '../providers/station_provider.dart';
import '../services/photo_storage_service.dart';

class StationDetailSheet extends StatefulWidget {
  final RadioStation station;
  final VoidCallback onRoadviewTap;

  const StationDetailSheet({
    super.key,
    required this.station,
    required this.onRoadviewTap,
  });

  @override
  State<StationDetailSheet> createState() => _StationDetailSheetState();
}

class _StationDetailSheetState extends State<StationDetailSheet> {
  late TextEditingController _memoController;
  bool _isEditing = false;
  final ImagePicker _imagePicker = ImagePicker();
  List<String> _photoPaths = [];
  String _currentMemo = ''; // 현재 저장된 메모 (실시간 반영용)

  // 테마 색상 (로그인 페이지와 일관성)
  static const Color _primaryColor = Color(0xFFE53935);

  @override
  void initState() {
    super.initState();
    _memoController = TextEditingController(text: widget.station.memo ?? '');
    _photoPaths = List<String>.from(widget.station.photoPaths ?? []);
    _currentMemo = widget.station.memo ?? '';
  }

  @override
  void dispose() {
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) {
          // 스크롤 가능한 콘텐츠
          final scrollableContent = SingleChildScrollView(
            controller: scrollController,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 드래그 핸들
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey[300],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // 헤더
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 호출명칭 (메인 타이틀)
                            Text(
                              widget.station.displayName,
                              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            // ERP국소명 (서브 타이틀)
                            if (widget.station.callSign != null &&
                                widget.station.callSign != widget.station.stationName)
                              Text(
                                widget.station.stationName,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.grey[600],
                                ),
                              ),
                            const SizedBox(height: 8),
                            // 카테고리 및 상태 태그
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                if (widget.station.categoryName != null)
                                  _buildTag(
                                    widget.station.categoryName!,
                                    Colors.blue,
                                  ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: widget.station.isInspected
                                        ? Colors.green.shade100
                                        : Colors.orange.shade100,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    widget.station.isInspected ? '검사 완료' : '검사 대기',
                                    style: TextStyle(
                                      color: widget.station.isInspected
                                          ? Colors.green.shade700
                                          : Colors.orange.shade700,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // 로드뷰 버튼
                      ElevatedButton.icon(
                        onPressed: widget.station.hasCoordinates
                            ? widget.onRoadviewTap
                            : () => _showNoLocationDialog(),
                        icon: Icon(
                          widget.station.hasCoordinates
                              ? Icons.streetview
                              : Icons.location_off,
                        ),
                        label: Text(
                          widget.station.hasCoordinates ? '로드뷰' : '위치정보 없음',
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: widget.station.hasCoordinates
                              ? _primaryColor
                              : Colors.grey[400],
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // 상세 정보
                  _buildInfoSection(context),
                  const SizedBox(height: 24),

                  // 메모 섹션
                  _buildMemoSection(context),
                  const SizedBox(height: 24),

                  // 사진 섹션
                  _buildPhotoSection(context),
                  const SizedBox(height: 24),

                  // 액션 버튼
                  _buildActionButtons(context),
                ],
              ),
            ),
          );

          // 모든 플랫폼에서 이벤트가 맵으로 전파되지 않도록 차단
          // GestureDetector의 behavior: HitTestBehavior.opaque로 터치/마우스 이벤트 소비
          return GestureDetector(
            behavior: HitTestBehavior.opaque, // 모든 이벤트를 이 위젯에서 처리
            onHorizontalDragUpdate: (_) {}, // 수평 드래그 소비
            onVerticalDragUpdate: (_) {}, // 수직 드래그 소비 (DraggableScrollableSheet과 충돌하지 않음)
            child: kIsWeb
                ? Listener(
                    behavior: HitTestBehavior.opaque, // 이벤트를 이 위젯에서 처리
                    onPointerSignal: (event) {
                      // 마우스 휠 이벤트를 감지하여 스크롤 처리
                      if (event is PointerScrollEvent) {
                        // GestureBinding을 통해 이벤트를 소비 (전파 차단)
                        GestureBinding.instance.pointerSignalResolver.register(event, (event) {
                          // 스크롤 델타를 사용하여 ScrollController로 직접 스크롤
                          final scrollEvent = event as PointerScrollEvent;
                          final delta = scrollEvent.scrollDelta.dy;
                          final currentOffset = scrollController.offset;
                          final maxOffset = scrollController.position.maxScrollExtent;
                          final minOffset = scrollController.position.minScrollExtent;

                          // 새 오프셋 계산 (범위 내로 제한)
                          final newOffset = (currentOffset + delta).clamp(minOffset, maxOffset);
                          scrollController.jumpTo(newOffset);
                        });
                      }
                    },
                    child: scrollableContent,
                  )
                : scrollableContent,
          );
        },
      ),
    );
  }

  Widget _buildTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w500,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildInfoSection(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.info_outline, color: _primaryColor, size: 20),
                ),
                const SizedBox(width: 12),
                Text(
                  '기본 정보',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(color: Colors.grey[200]),
            _buildInfoRow('허가번호', widget.station.licenseNumber),
            if (widget.station.typeApprovalNumber != null && widget.station.typeApprovalNumber!.isNotEmpty)
              _buildInfoRow('형식검정번호', widget.station.typeApprovalNumber!),
            _buildInfoRow('설치장소', widget.station.address),
            if (widget.station.callSign != null && widget.station.callSign!.isNotEmpty)
              _buildInfoRow('호출명칭', widget.station.callSign!),
            if (widget.station.gain != null && widget.station.gain!.isNotEmpty)
              _buildInfoRow('이득(dB)', widget.station.gain!),
            if (widget.station.antennaCount != null && widget.station.antennaCount!.isNotEmpty)
              _buildInfoRow('기수', widget.station.antennaCount!),
            if (widget.station.remarks != null && widget.station.remarks!.isNotEmpty)
              _buildInfoRow('비고', widget.station.remarks!),
            if (widget.station.stationType != null && widget.station.stationType!.isNotEmpty)
              _buildInfoRow('팀명', widget.station.stationType!),
            if (widget.station.hasCoordinates)
              _buildInfoRow(
                '좌표',
                '${widget.station.latitude!.toStringAsFixed(6)}, ${widget.station.longitude!.toStringAsFixed(6)}',
              ),
            if (widget.station.inspectionDate != null)
              _buildInfoRow(
                '검사일',
                _formatDate(widget.station.inspectionDate!),
              ),
            // 좌표 정보가 없는 경우 경고 표시
            if (!widget.station.hasCoordinates) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '위치 정보가 없어 지도에 표시되지 않습니다.',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.orange.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.grey,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemoSection(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.note_alt_outlined, color: Colors.blue.shade600, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '특이사항 메모',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Container(
                  decoration: BoxDecoration(
                    color: _isEditing ? _primaryColor.withValues(alpha: 0.1) : Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: IconButton(
                    icon: Icon(
                      _isEditing ? Icons.check : Icons.edit,
                      color: _isEditing ? _primaryColor : Colors.grey[600],
                    ),
                    onPressed: () {
                      if (_isEditing) {
                        _saveMemo();
                      }
                      setState(() {
                        _isEditing = !_isEditing;
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(color: Colors.grey[200]),
            if (_isEditing)
              TextField(
                controller: _memoController,
                maxLines: 5,
                decoration: InputDecoration(
                  hintText: '검사 중 발견한 특이사항을 입력하세요...',
                  hintStyle: TextStyle(color: Colors.grey[400]),
                  filled: true,
                  fillColor: Colors.grey[50],
                  contentPadding: const EdgeInsets.all(14),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey[300]!),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: _primaryColor, width: 1.5),
                  ),
                ),
              )
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: Text(
                  _currentMemo.isNotEmpty
                      ? _currentMemo
                      : '메모가 없습니다.',
                  style: TextStyle(
                    color: _currentMemo.isNotEmpty
                        ? Colors.black87
                        : Colors.grey[400],
                    height: 1.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotoSection(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.green.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(Icons.photo_camera_outlined, color: Colors.green.shade600, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '특이사항 사진',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    if (!kIsWeb)
                      Container(
                        margin: const EdgeInsets.only(right: 4),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: IconButton(
                          icon: Icon(Icons.camera_alt, color: Colors.grey[600]),
                          tooltip: '카메라로 촬영',
                          onPressed: () => _takePhoto(ImageSource.camera),
                        ),
                      ),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: IconButton(
                        icon: Icon(Icons.photo_library, color: Colors.grey[600]),
                        tooltip: kIsWeb ? 'PC에서 파일 선택' : '갤러리에서 선택',
                        onPressed: () => _takePhoto(ImageSource.gallery),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(color: Colors.grey[200]),
            if (_photoPaths.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.photo_camera, size: 32, color: Colors.grey[400]),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '등록된 사진이 없습니다.',
                      style: TextStyle(
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      kIsWeb
                          ? '갤러리 버튼을 눌러 PC에서 사진을 선택하세요.'
                          : '카메라 또는 갤러리 버튼을 눌러 사진을 추가하세요.',
                      style: TextStyle(color: Colors.grey[400], fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: _photoPaths.length,
                itemBuilder: (context, index) {
                  return _buildPhotoThumbnail(index);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotoThumbnail(int index) {
    final photoPath = _photoPaths[index];

    // PhotoStorageService를 사용하여 유효한 URL인지 체크
    final isValidUrl = PhotoStorageService.isValidPhotoUrl(photoPath);

    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onTap: () {
            if (!isValidUrl) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('이 사진은 세션이 만료되어 더 이상 표시할 수 없습니다.'),
                  backgroundColor: Colors.orange,
                ),
              );
            } else {
              _showPhotoViewer(index);
            }
          },
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: kIsWeb
                ? _buildWebImage(photoPath)
                : Image.file(
                    File(photoPath),
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      return Container(
                        color: Colors.grey[300],
                        child: const Icon(Icons.broken_image, color: Colors.grey),
                      );
                    },
                  ),
          ),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: GestureDetector(
            onTap: () => _deletePhoto(index),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, color: Colors.white, size: 16),
            ),
          ),
        ),
      ],
    );
  }

  /// 웹용 이미지 위젯 (S3 URL인 경우 presigned URL 변환)
  Widget _buildWebImage(String photoPath) {
    // S3 키인 경우 FutureBuilder로 URL 가져오기
    if (photoPath.startsWith('s3://')) {
      return FutureBuilder<String>(
        future: PhotoStorageService.getPhotoUrl(photoPath),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Container(
              color: Colors.grey[200],
              child: const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Container(
              color: Colors.grey[200],
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.image_not_supported, color: Colors.grey[400], size: 24),
                  const SizedBox(height: 4),
                  Text(
                    '로드 실패',
                    style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                  ),
                ],
              ),
            );
          }
          return Image.network(
            snapshot.data!,
            fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
              return Container(
                color: Colors.grey[200],
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.image_not_supported, color: Colors.grey[400], size: 24),
                    const SizedBox(height: 4),
                    Text(
                      '만료됨',
                      style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    }

    // 일반 URL 또는 base64
    return Image.network(
      photoPath,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return Container(
          color: Colors.grey[200],
          child: const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return Container(
          color: Colors.grey[200],
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.image_not_supported, color: Colors.grey[400], size: 24),
              const SizedBox(height: 4),
              Text(
                '만료됨',
                style: TextStyle(fontSize: 10, color: Colors.grey[500]),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _takePhoto(ImageSource source) async {
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (pickedFile == null) return;

      String savedPath;

      if (kIsWeb) {
        // 웹에서는 PhotoStorageService를 사용하여 S3 또는 base64로 저장
        final bytes = await pickedFile.readAsBytes();
        final result = await PhotoStorageService.uploadPhoto(
          bytes: bytes,
          fileName: pickedFile.name,
          stationId: widget.station.id,
        );

        if (result == null) {
          throw Exception('사진 업로드 실패');
        }
        savedPath = result;
      } else {
        // 모바일에서는 앱 내부 저장소에 사진 복사
        final appDir = await getApplicationDocumentsDirectory();
        final photoDir = Directory('${appDir.path}/photos/${widget.station.id}');
        if (!await photoDir.exists()) {
          await photoDir.create(recursive: true);
        }

        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final fileName = 'photo_$timestamp.jpg';
        savedPath = '${photoDir.path}/$fileName';

        await File(pickedFile.path).copy(savedPath);
      }

      setState(() {
        _photoPaths.add(savedPath);
      });

      // 저장소에 업데이트
      _savePhotos();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('사진이 추가되었습니다.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('사진 추가 실패: $e')),
        );
      }
    }
  }

  void _deletePhoto(int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('사진 삭제'),
        content: const Text('이 사진을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);

              // 파일 삭제
              try {
                final file = File(_photoPaths[index]);
                if (await file.exists()) {
                  await file.delete();
                }
              } catch (e) {
                debugPrint('파일 삭제 오류: $e');
              }

              setState(() {
                _photoPaths.removeAt(index);
              });

              _savePhotos();

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('사진이 삭제되었습니다.')),
                );
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
  }

  void _showPhotoViewer(int initialIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _PhotoViewerPage(
          photoPaths: _photoPaths,
          initialIndex: initialIndex,
          stationName: widget.station.displayName,
        ),
      ),
    );
  }

  void _savePhotos() {
    final provider = context.read<StationProvider>();
    provider.updatePhotoPaths(widget.station.id, _photoPaths);
  }

  Widget _buildActionButtons(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: () => _toggleInspectionStatus(context),
            icon: Icon(
              widget.station.isInspected
                  ? Icons.cancel_outlined
                  : Icons.check_circle_outline,
            ),
            label: Text(
              widget.station.isInspected ? '검사 취소' : '검사 완료',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.station.isInspected
                  ? Colors.grey[200]
                  : Colors.green,
              foregroundColor: widget.station.isInspected
                  ? Colors.grey[700]
                  : Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _deleteStation(context),
            icon: Icon(Icons.delete_outline, color: _primaryColor),
            label: Text('삭제', style: TextStyle(color: _primaryColor)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
              side: BorderSide(color: _primaryColor),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _saveMemo() {
    final provider = context.read<StationProvider>();
    final newMemo = _memoController.text;
    provider.updateMemo(widget.station.id, newMemo);

    // 로컬 상태도 업데이트하여 실시간 반영
    setState(() {
      _currentMemo = newMemo;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('메모가 저장되었습니다.')),
    );
  }

  Future<void> _toggleInspectionStatus(BuildContext context) async {
    final provider = context.read<StationProvider>();
    final wasInspected = widget.station.isInspected;

    // 상태 업데이트 완료까지 대기
    await provider.updateInspectionStatus(
      widget.station.id,
      !wasInspected,
    );

    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasInspected ? '검사 완료가 취소되었습니다.' : '검사 완료로 표시되었습니다.',
          ),
        ),
      );
    }
  }

  void _deleteStation(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('삭제 확인'),
        content: Text('${widget.station.displayName}을(를) 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
              context.read<StationProvider>().deleteStation(widget.station.id);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  /// 위치 정보 없음 안내 다이얼로그
  void _showNoLocationDialog() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Container(
          padding: const EdgeInsets.all(24),
          constraints: const BoxConstraints(maxWidth: 400),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 아이콘
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.location_off,
                  size: 48,
                  color: Colors.orange.shade600,
                ),
              ),
              const SizedBox(height: 20),
              // 타이틀
              const Text(
                '위치 정보 없음',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              // 설명
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '이 장소는 다음 이유 중 하나로 인해 지도에서 정확한 위치를 표시할 수 없습니다:',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[700],
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _buildReasonItem(
                      Icons.edit_location_alt,
                      '주소 정보가 정확하지 않음',
                      '등록된 주소로 좌표를 찾을 수 없습니다.',
                    ),
                    const SizedBox(height: 8),
                    _buildReasonItem(
                      Icons.wrong_location,
                      '위치가 변경된 장소',
                      '기존 위치에서 이전되었거나 폐쇄된 장소일 수 있습니다.',
                    ),
                    const SizedBox(height: 8),
                    _buildReasonItem(
                      Icons.help_outline,
                      '신규 등록 장소',
                      '아직 좌표 정보가 입력되지 않은 새로운 장소입니다.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // 안내 메시지
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _primaryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 18, color: _primaryColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '현장 방문 시 실제 주소를 확인해 주세요.',
                        style: TextStyle(
                          fontSize: 13,
                          color: _primaryColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // 닫기 버튼
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    '확인',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 위치 없음 이유 항목 위젯
  Widget _buildReasonItem(IconData icon, String title, String description) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Colors.orange.shade600),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 사진 전체 화면 뷰어
class _PhotoViewerPage extends StatefulWidget {
  final List<String> photoPaths;
  final int initialIndex;
  final String stationName;

  const _PhotoViewerPage({
    required this.photoPaths,
    required this.initialIndex,
    required this.stationName,
  });

  @override
  State<_PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<_PhotoViewerPage> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${widget.stationName} (${_currentIndex + 1}/${widget.photoPaths.length})',
          style: const TextStyle(fontSize: 16),
        ),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.photoPaths.length,
        onPageChanged: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        itemBuilder: (context, index) {
          final photoPath = widget.photoPaths[index];
          return InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: Center(
              child: kIsWeb
                  ? Image.network(
                      photoPath,
                      fit: BoxFit.contain,
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return Center(
                          child: CircularProgressIndicator(
                            value: loadingProgress.expectedTotalBytes != null
                                ? loadingProgress.cumulativeBytesLoaded /
                                    loadingProgress.expectedTotalBytes!
                                : null,
                            color: Colors.white,
                          ),
                        );
                      },
                      errorBuilder: (context, error, stackTrace) {
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.image_not_supported, color: Colors.grey, size: 64),
                            const SizedBox(height: 16),
                            const Text(
                              '이미지를 불러올 수 없습니다.',
                              style: TextStyle(color: Colors.grey),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '세션이 만료되었거나 이미지가 삭제되었습니다.',
                              style: TextStyle(color: Colors.grey[600], fontSize: 12),
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.arrow_back, color: Colors.white),
                              label: const Text('돌아가기', style: TextStyle(color: Colors.white)),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Colors.white),
                              ),
                            ),
                          ],
                        );
                      },
                    )
                  : Image.file(
                      File(photoPath),
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.broken_image, color: Colors.grey, size: 64),
                            SizedBox(height: 16),
                            Text(
                              '이미지를 불러올 수 없습니다.',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ],
                        );
                      },
                    ),
            ),
          );
        },
      ),
    );
  }
}
