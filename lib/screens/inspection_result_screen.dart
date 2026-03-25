import 'dart:async';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import 'tower_classification_screen.dart';

class InspectionResultScreen extends StatefulWidget {
  final int year;
  final String licenseNo;
  final String callname;
  final Map<String, dynamic>? initialData;
  final bool isSheet;

  const InspectionResultScreen({
    super.key,
    required this.year,
    required this.licenseNo,
    required this.callname,
    this.initialData,
    this.isSheet = false,
  });

  @override
  State<InspectionResultScreen> createState() => _InspectionResultScreenState();
}

class _InspectionResultScreenState extends State<InspectionResultScreen> {
  static const Color _primary = Color(0xFFE53935);
  static const Color _green  = Color(0xFF43A047);
  static const Color _blue   = Color(0xFF4A90D9);
  static const Color _purple = Color(0xFF9C27B0);

  late final InspectionService _svc;

  Map<String, dynamic>? _data;
  bool _loading     = false;
  bool _saving      = false;
  String? _error;

  final _towerTypeCtrl = TextEditingController();
  final _memoCtrl      = TextEditingController();
  final _inspDateCtrl  = TextEditingController(); // 내부 보관용 (UI에서 숨김)
  String _status = '검사대기';

  List<Map<String, dynamic>> _photos = [];
  bool _photoLoading = false;

  @override
  void initState() {
    super.initState();
    _svc = InspectionService()
      ..setAuthToken(context.read<AuthService>().authToken);
    if (widget.initialData != null) _applyData(widget.initialData!);
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
      _memoCtrl.text      = result['메모']    ?? '';
      _inspDateCtrl.text  = result['검사일']  ?? '';
      _status = result['status'] ?? '검사대기';
      // 사진S3키: List<String> → List<Map>
      final raw = result['사진S3키'];
      if (raw is List) {
        _photos = raw.map((k) => <String, dynamic>{'s3Key': k.toString()}).toList();
      }
    }
  }

  Future<void> _loadData() async {
    // initialData가 이미 있으면 로딩 스피너 없이 백그라운드 갱신
    if (_data == null) setState(() { _loading = true; });
    setState(() => _error = null);
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
      // 합격/불합격 저장 시 검사일 자동 세팅
      if (_status == '합격' || _status == '불합격') {
        if (_inspDateCtrl.text.isEmpty) {
          final now = DateTime.now();
          _inspDateCtrl.text =
              '${now.year}${now.month.toString().padLeft(2, '0')}'
              '${now.day.toString().padLeft(2, '0')}';
        }
      }
      await _svc.upsertResult({
        'year'   : widget.year,
        '허가번호': widget.licenseNo,
        'status' : _status,
        '철탑형태': _towerTypeCtrl.text,
        '메모'   : _memoCtrl.text,
        '검사일' : _inspDateCtrl.text,
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

  // ── 로드뷰 ─────────────────────────────────────────────

  Future<void> _openRoadview(String address) async {
    if (address.isEmpty) return;
    final uri = Uri.parse(
        'https://map.naver.com/v5/search/${Uri.encodeComponent(address)}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ── 철탑형태 AI 분류 ────────────────────────────────────

  Future<void> _classifyTowerType() async {
    final result = await Navigator.push<TowerClassificationResult>(
      context,
      MaterialPageRoute(
        builder: (_) => TowerClassificationScreen(
          stationName: widget.callname,
          returnResult: true,
        ),
      ),
    );
    if (result != null && result.installationType != null) {
      setState(() => _towerTypeCtrl.text = result.installationType!);
    }
  }

  // ── 삭제 ──────────────────────────────────────────────

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('수검 기록 삭제', style: TextStyle(fontSize: 16)),
        content: const Text('이 수검 기록을 삭제하시겠습니까?\n저장된 일정 및 결과가 모두 삭제됩니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: _primary, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _svc.deleteSchedule(widget.year, widget.licenseNo);
      if (mounted) {
        _showSnack('삭제되었습니다.');
        Navigator.pop(context, true);
      }
    } catch (e) {
      _showSnack('삭제 실패: $e', isError: true);
    }
  }

  // ── Build ──────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.isSheet) {
      return _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('오류: $_error', style: const TextStyle(color: Colors.red)))
              : _buildLayout();
    }
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: Text('오류: $_error',
                        style: const TextStyle(color: Colors.red)))
                : _buildLayout(),
      ),
    );
  }

  Widget _buildLayout() {
    final d        = _data;
    final target   = d?['target']   as Map<String, dynamic>?;
    final ds       = d?['ds']       as Map<String, dynamic>?;
    final schedule = d?['schedule'] as Map<String, dynamic>?;

    return Column(children: [
      // 드래그 핸들
      Center(
        child: Container(
          width: 40, height: 4,
          margin: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: Colors.grey.shade300,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
      // 스크롤 본문
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _buildHeader(target, ds, schedule),
            const SizedBox(height: 16),
            _buildBasicInfoCard(target, ds),
            const SizedBox(height: 12),
            _buildTowerTypeCard(),
            const SizedBox(height: 12),
            if (schedule != null) ...[
              _buildScheduleCard(schedule),
              const SizedBox(height: 12),
            ],
            _buildResultCard(),
            const SizedBox(height: 8),
          ]),
        ),
      ),
      // 하단 고정 영역
      _buildBottomBar(),
    ]);
  }

  // ── 헤더 ───────────────────────────────────────────────

  Widget _buildHeader(
    Map<String, dynamic>? target,
    Map<String, dynamic>? ds,
    Map<String, dynamic>? schedule,
  ) {
    final name    = target?['호출명칭']?.toString() ?? widget.callname;
    final address = target?['도로명주소']?.toString()
                 ?? target?['설치장소']?.toString() ?? '';

    // 통합시설명칭: DS 일반사항에서 통합시설명칭 → 무선국명 순서로 fallback
    final dsGeneral      = ds?['일반사항'] as Map<String, dynamic>?;
    final zpcname        = dsGeneral?['통합시설명칭']?.toString() ?? '';
    final muSunGukMyeong = dsGeneral?['무선국명']?.toString() ?? '';
    final subtitle       = zpcname.isNotEmpty ? zpcname : muSunGukMyeong;

    // 일정 태그
    String schedTag = '';
    if (schedule != null) {
      final week   = schedule['수검예정주차']?.toString() ?? '';
      final start  = schedule['수검시작일']?.toString()   ?? '';
      final end    = schedule['수검종료일']?.toString()   ?? '';
      final hq     = schedule['skt본부']?.toString()     ?? '';
      final region = schedule['지역']?.toString()        ?? '';
      schedTag = week;
      if (start.isNotEmpty && end.isNotEmpty) schedTag += '($start~$end)';
      if (hq.isNotEmpty)     schedTag += '_$hq';
      if (region.isNotEmpty) schedTag += '_$region';
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 뒤로가기 (시트 모드에선 숨김 — 드래그 핸들로 닫음)
        if (!widget.isSheet)
          Padding(
            padding: const EdgeInsets.only(top: 3, right: 6),
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: const Icon(Icons.arrow_back_ios_new,
                  size: 16, color: Colors.black54),
            ),
          ),
        // 호출명칭 + 통합시설명칭
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold, height: 1.2)),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
          ]),
        ),
        // 로드뷰 버튼
        const SizedBox(width: 8),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: _primary,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            elevation: 0,
          ),
          icon: const Icon(Icons.streetview, size: 16),
          label: const Text('로드뷰',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          onPressed:
              address.isNotEmpty ? () => _openRoadview(address) : null,
        ),
      ]),
      const SizedBox(height: 10),
      // 태그 행
      Row(children: [
        if (schedTag.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(schedTag,
                style: TextStyle(
                    fontSize: 11,
                    color: Colors.blue.shade700,
                    fontWeight: FontWeight.w500)),
          ),
        if (schedTag.isNotEmpty) const SizedBox(width: 6),
        if (_status == '합격')    _statusBadge('합격',    _green),
        if (_status == '불합격')  _statusBadge('불합격',  _primary),
        if (_status == '검사대기') _statusBadge('검사대기', Colors.grey.shade500),
      ]),
    ]);
  }

  Widget _statusBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
      child: Text(label,
          style: const TextStyle(
              fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
    );
  }

  // ── 기본 정보 ───────────────────────────────────────────

  /// 안테나 목록에서 key에 해당하는 값을 중복 제거 후 공백으로 연결
  String _antennaField(List<dynamic> list, String key) {
    final seen = <String>{};
    final vals = list
        .map((a) => (a as Map<String, dynamic>)[key]?.toString().trim() ?? '')
        .where((v) => v.isNotEmpty && seen.add(v))
        .toList();
    return vals.join(' ');
  }

  /// 기기일련번호: 중복 제거 후 줄바꿈으로 연결
  String _serialNumbers(List<dynamic> list) {
    final seen = <String>{};
    final vals = list
        .map((a) => (a as Map<String, dynamic>)['기기일련번호']?.toString().trim() ?? '')
        .where((v) => v.isNotEmpty && seen.add(v))
        .toList();
    return vals.join('\n');
  }

  String _fmtDate(String raw) {
    if (raw.length == 8 && RegExp(r'^\d{8}$').hasMatch(raw)) {
      return '${raw.substring(0, 4)}-${raw.substring(4, 6)}-${raw.substring(6, 8)}';
    }
    return raw;
  }

  Widget _buildBasicInfoCard(
      Map<String, dynamic>? target, Map<String, dynamic>? ds) {
    final antennaList = (ds?['안테나'] as List<dynamic>?) ?? [];
    final deviceList  = (ds?['장치']  as List<dynamic>?) ?? [];
    final gain      = _antennaField(antennaList, '이득');
    final antCount  = _antennaField(antennaList, '기');
    final mountType = _antennaField(antennaList, '공중선주 설치형태명').isNotEmpty
        ? _antennaField(antennaList, '공중선주 설치형태명')
        : _antennaField(antennaList, '공중선주설치형태명');
    final serial    = _serialNumbers(deviceList);  // 기기일련번호는 ds['장치'] 테이블
    final callnameList = List<Map<String, dynamic>>.from(_data?['callname_list'] ?? []);
    final facilityNames = callnameList
        .where((e) => (e['zpcname'] as String? ?? '').isNotEmpty)
        .map((e) {
          final ser = (e['eqp_ser_no'] as String? ?? '').trim();
          final name = (e['zpcname'] as String? ?? '').trim();
          return ser.isNotEmpty ? '$ser($name)' : name;
        })
        .toSet()
        .toList();
    final lat  = target?['위도']?.toString() ?? '';
    final lng  = target?['경도']?.toString() ?? '';
    final coord = (lat.isNotEmpty && lng.isNotEmpty) ? '$lat, $lng' : '';

    return _card(
      title: '기본 정보',
      icon: Icons.info_outline,
      iconColor: _primary,
      child: Column(children: [
        _infoRow('허가번호',
            target?['허가번호']?.toString() ?? widget.licenseNo),
        _infoRow('설치장소',
            target?['설치장소']?.toString()
                ?? target?['도로명주소']?.toString() ?? ''),
        _infoRow('호출명칭',
            target?['호출명칭']?.toString() ?? widget.callname),
        if (gain.isNotEmpty)      _infoRow('이득(dB)', gain),
        if (antCount.isNotEmpty)  _infoRow('기수',     antCount),
        if (mountType.isNotEmpty) _infoRow('설치대',   mountType),
        if (facilityNames.isNotEmpty || serial.isNotEmpty)
          _infoRow('일련번호 및 통합시설명칭',
              facilityNames.isNotEmpty ? facilityNames.join('\n') : serial),
        if (coord.isNotEmpty)     _infoRow('좌표',     coord),
        if (_inspDateCtrl.text.isNotEmpty)
          _infoRow('검사일', _fmtDate(_inspDateCtrl.text)),
      ]),
    );
  }

  // ── 철탑형태 분류 ───────────────────────────────────────

  Widget _buildTowerTypeCard() {
    final current = _towerTypeCtrl.text;
    return _card(
      title: '철탑형태 분류',
      subtitle: current.isNotEmpty ? '현재: $current' : null,
      icon: Icons.settings_input_antenna,
      iconColor: _purple,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          'AI를 활용하여 철탑/안테나 설치형태를 자동으로 분류합니다.',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _purple,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              elevation: 0,
            ),
            icon: const Text('✨', style: TextStyle(fontSize: 16)),
            label: const Text(
              '철탑형태 분류하기',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            onPressed: _classifyTowerType,
          ),
        ),
      ]),
    );
  }

  // ── 수검 일정 ───────────────────────────────────────────

  Widget _buildScheduleCard(Map<String, dynamic> schedule) {
    return _card(
      title: '수검 일정',
      icon: Icons.calendar_month,
      iconColor: _blue,
      child: Column(children: [
        _infoRow('예정주차', schedule['수검예정주차']?.toString() ?? ''),
        _infoRow('지역',    schedule['지역']?.toString()        ?? ''),
        _infoRow('담당팀',  schedule['품질개선팀']?.toString()  ?? ''),
      ]),
    );
  }

  // ── 수검 결과 입력 (합격/불합격 + 메모 + 사진 통합) ──────

  Widget _buildResultCard() {
    return _card(
      title: '수검 결과 입력',
      icon: Icons.assignment_turned_in_outlined,
      iconColor: _green,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 검사 결과 선택
        const Text('검사 결과',
            style: TextStyle(fontSize: 13, color: Colors.black54)),
        const SizedBox(height: 8),
        Row(children: [
          _statusChip('합격',   _green),
          const SizedBox(width: 8),
          _statusChip('불합격', _primary),
          const SizedBox(width: 8),
          _statusChip('검사대기', Colors.grey),
        ]),
        const SizedBox(height: 16),

        // 특이사항 메모
        _sectionLabel('특이사항 메모', Icons.edit_note, onTap: _editMemo),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Text(
            _memoCtrl.text.isEmpty ? '(메모 없음)' : _memoCtrl.text,
            style: TextStyle(
                fontSize: 13,
                color: _memoCtrl.text.isEmpty
                    ? Colors.grey.shade400
                    : Colors.grey.shade800),
          ),
        ),
        const SizedBox(height: 16),

        // 특이사항 사진
        _sectionLabel('특이사항 사진', Icons.photo_camera_outlined,
            onTap: _photoLoading ? null : _addPhoto),
        const SizedBox(height: 8),
        if (_photos.isNotEmpty) ...[
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
          const SizedBox(height: 12),
        ],
        if (_photos.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('등록된 사진이 없습니다',
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey.shade400)),
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
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(vertical: 14),
              elevation: 0,
            ),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : const Text('저장',
                    style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }

  Widget _sectionLabel(String label, IconData icon, {VoidCallback? onTap}) {
    return Row(children: [
      Icon(icon, size: 15, color: Colors.grey.shade600),
      const SizedBox(width: 5),
      Text(label,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700)),
      const Spacer(),
      if (onTap != null)
        GestureDetector(
          onTap: onTap,
          child: Icon(
            label.contains('메모') ? Icons.edit : Icons.add_photo_alternate_outlined,
            size: 18,
            color: Colors.grey.shade500,
          ),
        ),
    ]);
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
          border: Border.all(
              color: selected ? color : color.withValues(alpha: 0.3)),
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

  // ── 메모 편집 다이얼로그 ────────────────────────────────

  Future<void> _editMemo() async {
    final ctrl = TextEditingController(text: _memoCtrl.text);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('특이사항 메모'),
        content: TextField(
          controller: ctrl,
          maxLines: 5,
          autofocus: true,
          decoration: InputDecoration(
            border:
                OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            hintText: '특이사항을 입력하세요',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: _primary, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('확인'),
          ),
        ],
      ),
    );
    if (result != null) setState(() => _memoCtrl.text = result);
  }

  // ── 사진 ──────────────────────────────────────────────

  Widget _buildPhotoThumb(Map<String, dynamic> photo) {
    final s3Key = photo['s3Key'] as String? ?? '';
    // 업로드 직후엔 bytes가 캐시됨, 이후엔 백엔드 프록시로 로드 (CORS 우회)
    final cachedBytes = photo['_bytes'] as Uint8List?;
    return Stack(children: [
      FutureBuilder<Uint8List>(
        future: cachedBytes != null
            ? Future.value(cachedBytes)
            : _svc.getPhotoData(s3Key),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return Container(
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                  child: CircularProgressIndicator(strokeWidth: 2)),
            );
          }
          if (!snap.hasData || snap.hasError) {
            return Container(
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.broken_image, color: Colors.grey),
            );
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(snap.data!, fit: BoxFit.cover),
          );
        },
      ),
      Positioned(
        top: 4, right: 4,
        child: GestureDetector(
          onTap: () => _deletePhoto(s3Key),
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: const BoxDecoration(
                color: _primary, shape: BoxShape.circle),
            child: const Icon(Icons.close, size: 14, color: Colors.white),
          ),
        ),
      ),
    ]);
  }

  Future<void> _addPhoto() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) {
      _showSnack('파일을 읽을 수 없습니다.', isError: true);
      return;
    }
    setState(() => _photoLoading = true);
    try {
      final res = await _svc.uploadPhoto(
          widget.year, widget.licenseNo, file.bytes!, file.name);
      // bytes 캐싱 → 업로드 직후 Image.memory로 바로 표시 (CORS 우회)
      res['_bytes'] = file.bytes;
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
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: _primary, foregroundColor: Colors.white),
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

  // ── 하단 고정 바 ────────────────────────────────────────

  Widget _buildBottomBar() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(children: [
            _bottomBtn('검사대기', Icons.hourglass_empty_rounded, Colors.grey),
            const SizedBox(width: 8),
            _bottomBtn('합격',    Icons.check_circle_outline,   _green),
            const SizedBox(width: 8),
            _bottomBtn('불합격',  Icons.cancel_outlined,        _primary),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: _primary,
              side: BorderSide(color: _primary.withValues(alpha: 0.5)),
              minimumSize: const Size(double.infinity, 44),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('삭제',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            onPressed: _delete,
          ),
        ),
      ]),
    );
  }

  Widget _bottomBtn(String label, IconData icon, Color color) {
    final selected = _status == label;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _status = label),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? color : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: selected ? color : Colors.grey.shade300),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 22,
                color: selected ? Colors.white : color),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : color,
                )),
          ]),
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────

  Widget _card({
    required String title,
    String? subtitle,
    required IconData icon,
    required Color iconColor,
    Widget? headerAction,
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
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: iconColor),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  if (subtitle != null)
                    Text(subtitle,
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500)),
                ]),
          ),
          if (headerAction != null) headerAction,
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
        SizedBox(
          width: 80,
          child: Text(label,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
      ]),
    );
  }
}
