import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../widgets/user_profile_button.dart';

class InspectionResultScreen extends StatefulWidget {
  final int year;
  final String licenseNo;
  final String callname;
  final Map<String, dynamic>? initialData;

  const InspectionResultScreen({
    super.key,
    required this.year,
    required this.licenseNo,
    required this.callname,
    this.initialData,
  });

  @override
  State<InspectionResultScreen> createState() => _InspectionResultScreenState();
}

class _InspectionResultScreenState extends State<InspectionResultScreen> {
  static const Color _primary = Color(0xFFE53935);
  static const Color _green = Color(0xFF43A047);
  static const Color _blue = Color(0xFF4A90D9);

  late final InspectionService _svc;

  Map<String, dynamic>? _data;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  // 입력 컨트롤러
  final _towerTypeCtrl = TextEditingController();
  final _memoCtrl = TextEditingController();
  final _inspDateCtrl = TextEditingController();
  String _status = '검사대기';

  // 사진 목록
  List<Map<String, dynamic>> _photos = [];
  bool _photoLoading = false;

  @override
  void initState() {
    super.initState();
    _svc = InspectionService()
      ..setAuthToken(context.read<AuthService>().authToken);
    if (widget.initialData != null) {
      _applyData(widget.initialData!);
    }
    // 항상 서버에서 전체 데이터 로드 (사진, DS 정보 등 완전한 데이터)
    _loadData();
  }

  @override
  void dispose() {
    _towerTypeCtrl.dispose();
    _memoCtrl.dispose();
    _inspDateCtrl.dispose();
    super.dispose();
  }

  void _applyData(Map<String, dynamic> d) {
    _data = d;
    final result = d['result'] as Map<String, dynamic>?;
    if (result != null) {
      _towerTypeCtrl.text = result['철탑형태'] ?? '';
      _memoCtrl.text = result['메모'] ?? '';
      _inspDateCtrl.text = result['검사일'] ?? '';
      _status = result['status'] ?? '검사대기';
      _photos = List<Map<String, dynamic>>.from(result['photos'] ?? []);
    }
  }

  Future<void> _loadData() async {
    setState(() { _loading = true; _error = null; });
    try {
      final d = await _svc.getDetail(widget.year, widget.licenseNo);
      setState(() => _applyData(d));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await _svc.upsertResult({
        'year': widget.year,
        '허가번호': widget.licenseNo,
        'status': _status,
        '철탑형태': _towerTypeCtrl.text,
        '메모': _memoCtrl.text,
        '검사일': _inspDateCtrl.text,
      });
      _showSnack('저장되었습니다.');
      await _loadData();
    } catch (e) {
      _showSnack('저장 실패: $e', isError: true);
    } finally {
      setState(() => _saving = false);
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red.shade700 : Colors.black87,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── Build ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: _buildAppBar(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('오류: $_error', style: const TextStyle(color: Colors.red)))
              : _buildBody(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new, color: Colors.black54, size: 20),
        onPressed: () => Navigator.pop(context),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.callname,
              style: const TextStyle(color: Colors.black87, fontSize: 16, fontWeight: FontWeight.w600)),
          Text(widget.licenseNo,
              style: const TextStyle(color: Colors.black45, fontSize: 12)),
        ],
      ),
      actions: [
        UserProfileButton(
          onLogout: () => context.read<AuthService>().signOut(),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildBody() {
    final d = _data;
    final schedule = d?['schedule'] as Map<String, dynamic>?;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 일정 정보 카드
        if (schedule != null) _buildScheduleCard(schedule),

        const SizedBox(height: 16),

        // 수검 결과 입력 카드
        _buildResultCard(),

        const SizedBox(height: 16),

        // 사진 카드
        _buildPhotoCard(),
      ]),
    );
  }

  Widget _buildScheduleCard(Map<String, dynamic> schedule) {
    return _card(
      title: '수검 일정',
      icon: Icons.calendar_month,
      iconColor: _blue,
      child: Column(children: [
        _infoRow('예정주차', schedule['수검예정주차'] ?? ''),
        _infoRow('예정기간',
            '${schedule['수검시작일'] ?? ''} ~ ${schedule['수검종료일'] ?? ''}'),
        _infoRow('지역', schedule['지역'] ?? ''),
        _infoRow('담당팀', schedule['access담당'] ?? ''),
      ]),
    );
  }

  Widget _buildResultCard() {
    return _card(
      title: '수검 결과 입력',
      icon: Icons.assignment_turned_in_outlined,
      iconColor: _green,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 합격/불합격
        const Text('검사 결과', style: TextStyle(fontSize: 13, color: Colors.black54)),
        const SizedBox(height: 8),
        Row(children: [
          _statusChip('합격', _green),
          const SizedBox(width: 8),
          _statusChip('불합격', _primary),
          const SizedBox(width: 8),
          _statusChip('검사대기', Colors.grey),
        ]),
        const SizedBox(height: 14),

        // 검사일
        TextField(
          controller: _inspDateCtrl,
          decoration: InputDecoration(
            labelText: '검사일',
            hintText: '예: 20260119',
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        const SizedBox(height: 10),

        // 철탑형태
        TextField(
          controller: _towerTypeCtrl,
          decoration: InputDecoration(
            labelText: '철탑형태',
            hintText: '예: 단주, 삼각주, 四각주...',
            isDense: true,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        const SizedBox(height: 10),

        // 특이사항
        TextField(
          controller: _memoCtrl,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: '특이사항',
            hintText: '특이사항을 입력하세요',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        const SizedBox(height: 16),

        // 저장 버튼
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Text('저장', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }

  Widget _statusChip(String label, Color color) {
    final selected = _status == label;
    return GestureDetector(
      onTap: () => setState(() => _status = label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? color : color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? color : color.withValues(alpha: 0.3)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: selected ? Colors.white : color,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildPhotoCard() {
    return _card(
      title: '특이사항 사진',
      icon: Icons.photo_camera_outlined,
      iconColor: _blue,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 사진 그리드
        if (_photos.isNotEmpty)
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1,
            ),
            itemCount: _photos.length,
            itemBuilder: (context, i) => _buildPhotoThumb(_photos[i]),
          ),
        if (_photos.isNotEmpty) const SizedBox(height: 12),

        // 사진 추가 버튼
        OutlinedButton.icon(
          icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
          label: const Text('사진 추가', style: TextStyle(fontSize: 13)),
          style: OutlinedButton.styleFrom(
            foregroundColor: _blue,
            side: BorderSide(color: _blue),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _photoLoading ? null : _addPhoto,
        ),
      ]),
    );
  }

  Widget _buildPhotoThumb(Map<String, dynamic> photo) {
    final s3Key = photo['s3Key'] as String? ?? '';
    return Stack(
      children: [
        FutureBuilder<String>(
          future: _svc.getPhotoUrl(s3Key),
          builder: (context, snap) {
            if (!snap.hasData) {
              return Container(
                color: Colors.grey.shade100,
                child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            return ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(snap.data!, fit: BoxFit.cover,
                  errorBuilder: (ctx, e, st) =>
                      Container(color: Colors.grey.shade200,
                          child: const Icon(Icons.broken_image, color: Colors.grey))),
            );
          },
        ),
        Positioned(
          top: 4, right: 4,
          child: GestureDetector(
            onTap: () => _deletePhoto(s3Key),
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                  color: Colors.black54, borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.close, size: 12, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _addPhoto() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) { _showSnack('파일을 읽을 수 없습니다.', isError: true); return; }
    setState(() => _photoLoading = true);
    try {
      final res = await _svc.uploadPhoto(widget.year, widget.licenseNo, file.bytes!, file.name);
      setState(() => _photos.add(res));
    } catch (e) {
      _showSnack('업로드 실패: $e', isError: true);
    } finally {
      setState(() => _photoLoading = false);
    }
  }

  Future<void> _deletePhoto(String s3Key) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('사진 삭제', style: TextStyle(fontSize: 16)),
        content: const Text('이 사진을 삭제하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _svc.deletePhoto(widget.year, widget.licenseNo, s3Key);
      setState(() => _photos.removeWhere((p) => p['s3Key'] == s3Key));
    } catch (e) {
      _showSnack('삭제 실패: $e', isError: true);
    }
  }

  // ── Helpers ───────────────────────────────────────────

  Widget _card({
    required String title,
    required IconData icon,
    required Color iconColor,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, size: 16, color: iconColor),
          ),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 14),
        child,
      ]),
    );
  }

  Widget _infoRow(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 80, child: Text(label, style: TextStyle(fontSize: 13, color: Colors.grey.shade600))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
      ]),
    );
  }
}
