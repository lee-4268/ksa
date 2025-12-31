import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/radio_station.dart';
import '../providers/station_provider.dart';

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

  @override
  void initState() {
    super.initState();
    _memoController = TextEditingController(text: widget.station.memo ?? '');
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
          return SingleChildScrollView(
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
                        onPressed: widget.onRoadviewTap,
                        icon: const Icon(Icons.streetview),
                        label: const Text('로드뷰'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Colors.white,
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

                  // 액션 버튼
                  _buildActionButtons(context),
                ],
              ),
            ),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '기본 정보',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const Divider(),
            _buildInfoRow('허가번호', widget.station.licenseNumber),
            _buildInfoRow('설치장소', widget.station.address),
            if (widget.station.callSign != null && widget.station.callSign!.isNotEmpty)
              _buildInfoRow('호출명칭', widget.station.callSign!),
            if (widget.station.gain != null && widget.station.gain!.isNotEmpty)
              _buildInfoRow('이득(dB)', widget.station.gain!),
            if (widget.station.antennaCount != null && widget.station.antennaCount!.isNotEmpty)
              _buildInfoRow('기수', widget.station.antennaCount!),
            if (widget.station.remarks != null && widget.station.remarks!.isNotEmpty)
              _buildInfoRow('비고', widget.station.remarks!),
            if (widget.station.frequency != null && widget.station.frequency!.isNotEmpty)
              _buildInfoRow('주파수', widget.station.frequency!),
            if (widget.station.stationType != null && widget.station.stationType!.isNotEmpty)
              _buildInfoRow('종류', widget.station.stationType!),
            if (widget.station.owner != null && widget.station.owner!.isNotEmpty)
              _buildInfoRow('소유자', widget.station.owner!),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '특이사항 메모',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: Icon(_isEditing ? Icons.check : Icons.edit),
                  onPressed: () {
                    if (_isEditing) {
                      _saveMemo();
                    }
                    setState(() {
                      _isEditing = !_isEditing;
                    });
                  },
                ),
              ],
            ),
            const Divider(),
            if (_isEditing)
              TextField(
                controller: _memoController,
                maxLines: 5,
                decoration: const InputDecoration(
                  hintText: '검사 중 발견한 특이사항을 입력하세요...',
                  border: OutlineInputBorder(),
                ),
              )
            else
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.station.memo?.isNotEmpty == true
                      ? widget.station.memo!
                      : '메모가 없습니다.',
                  style: TextStyle(
                    color: widget.station.memo?.isNotEmpty == true
                        ? Colors.black87
                        : Colors.grey,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _toggleInspectionStatus(context),
            icon: Icon(
              widget.station.isInspected
                  ? Icons.cancel
                  : Icons.check_circle,
            ),
            label: Text(
              widget.station.isInspected ? '검사 취소' : '검사 완료',
            ),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => _deleteStation(context),
            icon: const Icon(Icons.delete, color: Colors.red),
            label: const Text('삭제', style: TextStyle(color: Colors.red)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
              side: const BorderSide(color: Colors.red),
            ),
          ),
        ),
      ],
    );
  }

  void _saveMemo() {
    final provider = context.read<StationProvider>();
    provider.updateMemo(widget.station.id, _memoController.text);
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
}
