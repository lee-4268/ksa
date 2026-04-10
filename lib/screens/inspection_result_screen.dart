import 'dart:async';
import 'dart:typed_data';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../services/kakao_geocoding_web.dart';
import 'tower_classification_screen.dart';
import '../widgets/progress_dialog.dart';

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
    final dialog = ProgressDialog(context);
    dialog.show(message: '저장 중...');
    try {
      // 합격/불합격 저장 시 검사일 자동 세팅
      if (_status == '합격' || _status.startsWith('불합격')) {
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
      await dialog.complete(message: '저장 완료');
      await _loadData();
    } catch (e) {
      await dialog.error(message: '저장 실패: $e');
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

  Future<void> _openRoadview({
    double? lat,
    double? lng,
    required String address,
    required String title,
  }) async {
    double? resolvedLat = lat;
    double? resolvedLng = lng;

    // 위경도가 없으면 주소로 지오코딩
    if ((resolvedLat == null || resolvedLng == null) && address.isNotEmpty) {
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(strokeWidth: 2),
                SizedBox(width: 16),
                Text('위치 검색 중...'),
              ]),
            ),
          ),
        ),
      );

      final result = await KakaoAddressGeocoder.addressToCoords(address);
      if (mounted) Navigator.of(context).pop(); // 로딩 닫기

      if (result != null) {
        resolvedLat = result.lat;
        resolvedLng = result.lng;
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('주소로 위치를 찾을 수 없습니다.'),
            backgroundColor: Colors.red,
          ));
        }
        return;
      }
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => _RoadviewDialog(lat: resolvedLat!, lng: resolvedLng!, title: title),
    );
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
    final latStr  = target?['위도']?.toString() ?? '';
    final lngStr  = target?['경도']?.toString() ?? '';
    final lat     = double.tryParse(latStr);
    final lng     = double.tryParse(lngStr);

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
          onPressed: (lat != null && lng != null) || address.isNotEmpty
              ? () => _openRoadview(lat: lat, lng: lng, address: address, title: name)
              : null,
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
        if (_status == '합격')           _statusBadge('합격',         _green),
        if (_status.startsWith('불합격')) _statusBadge(_status,        _primary),
        if (_status == '검사대기')        _statusBadge('검사대기', Colors.grey.shade500),
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

    final installAddr = target?['설치장소']?.toString()
        ?? target?['도로명주소']?.toString() ?? '';
    final navLat = double.tryParse(lat);
    final navLng = double.tryParse(lng);

    return _card(
      title: '기본 정보',
      icon: Icons.info_outline,
      iconColor: _primary,
      child: Column(children: [
        _infoRow('허가번호',
            target?['허가번호']?.toString() ?? widget.licenseNo),
        // 설치장소 + 내비게이션 버튼
        if (installAddr.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: 80,
                child: Text('설치장소',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
              ),
              Expanded(child: Text(installAddr, style: const TextStyle(fontSize: 13))),
              if (navLat != null && navLng != null) ...[
                _naviButton('Tmap', const Color(0xFF005BAC), () => _openTmap(navLat, navLng, installAddr)),
                const SizedBox(width: 4),
                _naviButton('카카오', const Color(0xFFFEE500), () => _openKakaoNavi(navLat, navLng, installAddr),
                    textColor: Colors.black87),
                const SizedBox(width: 4),
                _naviButton('네이버', const Color(0xFF03C75A), () => _openNaverNavi(navLat, navLng, installAddr)),
              ],
            ]),
          ),
        _infoRow('호출명칭',
            target?['호출명칭']?.toString() ?? widget.callname),
        if (gain.isNotEmpty)      _infoRow('이득(dB)', gain),
        if (antCount.isNotEmpty)  _infoRow('기수',     antCount),
        if (mountType.isNotEmpty) _infoRow('설치대',   mountType),
        if (facilityNames.isNotEmpty || serial.isNotEmpty)
          _infoRow('일련번호 및 통합시설명칭',
              facilityNames.isNotEmpty ? facilityNames.join('\n') : serial),
        if (lat.isNotEmpty && lng.isNotEmpty)
          _infoRow('좌표', '$lat, $lng'),
        if (_inspDateCtrl.text.isNotEmpty)
          _infoRow('검사일', _fmtDate(_inspDateCtrl.text)),
        if ((_data?['result']?['입력자'] ?? '').toString().isNotEmpty)
          _infoRow('입회자', _data!['result']['입력자'].toString()),
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
        if (_status.startsWith('불합격')) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Text('불합격 구분',
                style: TextStyle(fontSize: 12, color: Colors.black45)),
            const SizedBox(width: 10),
            _failTypeChip('불합격(서류)'),
            const SizedBox(width: 8),
            _failTypeChip('불합격(성능)'),
          ]),
        ],
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
    final selected = label == '불합격'
        ? _status.startsWith('불합격')
        : _status == label;
    return GestureDetector(
      onTap: () => setState(() {
        if (label == '불합격') {
          // 이미 불합격 계열이면 유지, 아니면 기본값으로
          if (!_status.startsWith('불합격')) _status = '불합격(서류)';
        } else {
          _status = label;
        }
      }),
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

  Widget _failTypeChip(String label) {
    final selected = _status == label;
    return GestureDetector(
      onTap: () => setState(() => _status = label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? _primary : _primary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: selected ? _primary : _primary.withValues(alpha: 0.25)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: selected ? Colors.white : _primary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  // ── 메모 편집 다이얼로그 ────────────────────────────────

  Future<void> _editMemo() async {
    // ── 공통 스타일 정의 (이 함수 내부에서만 사용) ──
    const Color _darkBtn = Color(0xFF111827); // 세련된 블랙 톤 강조색
    const Color _primaryBlue = Color(0xFF2563EB); // 저장/추가 등 긍정 액션

    // 공통 SaaS 스타일 다이얼로그 취소/초기화 버튼 스타일
    ButtonStyle _cancelBtnStyle() {
      return OutlinedButton.styleFrom(
        foregroundColor: Colors.grey.shade700,
        side: BorderSide(color: Colors.grey.shade300),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      );
    }

    // 공통 SaaS 스타일 저장/확인 버튼 스타일
    ButtonStyle _actionBtnStyle(Color color) {
      return ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      );
    }

    // ── 다이얼로그 로직 시작 ──
    // 1. 기존 메모 내용을 가져와서 컨트롤러 초기화 (기존 로직 유지)
    final ctrl = TextEditingController(text: _memoCtrl.text); 

    // 2. 다이얼로그 호출
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false, // 바깥 영역 터치로 닫기 방지 (UX 개선)
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent, // 기본 그림자 색상 제거
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), // 곡률 축소
        
        // ── 헤더 (제목 + X 버튼) ──
        titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '특이사항 메모 수정',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: Colors.black54),
              onPressed: () => Navigator.pop(ctx), // X 버튼 UX
            ),
          ],
        ),

        // ── 본문 (TextField) ──
        contentPadding: EdgeInsets.zero, // 스크롤을 위해 패딩 제거
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 320, 
            maxHeight: MediaQuery.sizeOf(context).height * 0.4, // Responsive max height
          ),
          child: SingleChildScrollView( // 키보드 올라왔을 때 오버플로우 방지
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctrl,
                  maxLines: 5,
                  autofocus: true,
                  style: const TextStyle(fontSize: 14, height: 1.6, color: Color(0xFF374151)), // Style
                  decoration: InputDecoration( // 플랫 입력 스타일
                    hintText: '특이사항 내용을 입력하세요...',
                    hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                    contentPadding: const EdgeInsets.all(16),
                    filled: true,
                    fillColor: Colors.grey.shade50,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: Colors.grey.shade300)),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: Colors.grey.shade300)),
                    focusedBorder: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(6)), borderSide: BorderSide(color: _darkBtn)),
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── 하단 액션 버튼 ──
        actionsPadding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        actions: [
          SizedBox(
            height: 42,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(ctx),
              style: _cancelBtnStyle(),
              child: const Text('취소')),
          ),
          const SizedBox(width: 8), // 버튼 간격
          SizedBox(
            height: 42,
            child: ElevatedButton(
              style: _actionBtnStyle(_primaryBlue), // 기존 파란색 강조 유지
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('저장 완료'),
            ),
          ),
        ],
      ),
    );

    // 3. 결과 처리 (기존 로직 유지)
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
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: (context.read<AuthService>().isSuperAdmin || context.read<AuthService>().isDivisionAdmin)
              ? Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primary,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 44),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                        icon: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2))
                            : const Icon(Icons.save_outlined, size: 18),
                        label: Text(_saving ? '저장 중...' : '저장',
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w500)),
                        onPressed: _saving ? null : _save,
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _primary,
                        side: BorderSide(color: _primary.withValues(alpha: 0.5)),
                        minimumSize: const Size(120, 44),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('삭제',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w500)),
                      onPressed: _delete,
                    ),
                  ],
                )
              : ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 44),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.save_outlined, size: 18),
                  label: Text(_saving ? '저장 중...' : '저장',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500)),
                  onPressed: _saving ? null : _save,
                ),
        ),
      ]),
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

  Widget _naviButton(String label, Color bgColor, VoidCallback onTap, {Color textColor = Colors.white}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: textColor)),
      ),
    );
  }

  void _openTmap(double lat, double lng, String name) {
    final encoded = Uri.encodeComponent(name);
    // 모바일 브라우저에서는 tmap:// 딥링크로 앱 직접 호출
    html.window.open(
      'tmap://route?goalx=$lng&goaly=$lat&goalname=$encoded',
      '_blank',
    );
  }

  void _openKakaoNavi(double lat, double lng, String name) {
    html.window.open(
      'kakaomap://route?ep=$lat,$lng&by=CAR',
      '_blank',
    );
  }

  void _openNaverNavi(double lat, double lng, String name) {
    final encoded = Uri.encodeComponent(name);
    html.window.open(
      'nmap://route/car?dlat=$lat&dlng=$lng&dname=$encoded&appname=com.kca.ksa',
      '_blank',
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

// ── 로드뷰 다이얼로그 ──────────────────────────────────────────

class _RoadviewDialog extends StatefulWidget {
  final double lat;
  final double lng;
  final String title;

  const _RoadviewDialog({
    required this.lat,
    required this.lng,
    required this.title,
  });

  @override
  State<_RoadviewDialog> createState() => _RoadviewDialogState();
}

class _RoadviewDialogState extends State<_RoadviewDialog> {
  static const Color _primary = Color(0xFFE53935);
  late final String _viewId;
  late final String _rvId;   // 로드뷰 div id
  late final String _mapId;  // 미니맵 div id
  late final String _noId;   // 미제공 안내 div id

  @override
  void initState() {
    super.initState();
    final ts = DateTime.now().millisecondsSinceEpoch;
    _viewId = 'rv-wrap-$ts';
    _rvId   = 'rv-$ts';
    _mapId  = 'rv-map-$ts';
    _noId   = 'rv-no-$ts';
    _registerView();
  }

  void _registerView() {
    ui_web.platformViewRegistry.registerViewFactory(_viewId, (int viewId) {
      // 최상위 컨테이너
      final wrap = html.DivElement()
        ..id = _viewId
        ..style.position = 'relative'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.background = '#1a1a1a';

      // 로드뷰 영역
      final rvDiv = html.DivElement()
        ..id = _rvId
        ..style.width = '100%'
        ..style.height = '100%';

      // 미니맵 영역
      final mapDiv = html.DivElement()
        ..id = _mapId
        ..style.position = 'absolute'
        ..style.bottom = '16px'
        ..style.right = '16px'
        ..style.width = '180px'
        ..style.height = '140px'
        ..style.border = '2px solid #fff'
        ..style.borderRadius = '8px'
        ..style.boxShadow = '0 2px 8px rgba(0,0,0,0.4)'
        ..style.zIndex = '10';

      // 로드뷰 미제공 안내
      final noDiv = html.DivElement()
        ..id = _noId
        ..style.display = 'none'
        ..style.position = 'absolute'
        ..style.top = '0'
        ..style.left = '0'
        ..style.right = '0'
        ..style.bottom = '0'
        ..style.background = '#1a1a1a'
        ..style.color = '#fff'
        ..style.flexDirection = 'column'
        ..style.alignItems = 'center'
        ..style.justifyContent = 'center'
        ..style.gap = '12px'
        ..style.fontFamily = 'sans-serif'
        ..innerHtml = '<div style="font-size:48px;opacity:0.5">🚫</div>'
                      '<p style="font-size:14px;opacity:0.7">이 위치에서는 로드뷰를 제공하지 않습니다.</p>';

      wrap..append(rvDiv)..append(mapDiv)..append(noDiv);

      // 부모 document의 kakao SDK를 그대로 사용해 초기화
      Future.delayed(const Duration(milliseconds: 150), () => _initRoadview());

      return wrap;
    });
  }

  void _initRoadview() {
    final lat = widget.lat;
    final lng = widget.lng;
    final jsCode = '''
(function() {
  var rvEl  = document.getElementById('$_rvId');
  var mapEl = document.getElementById('$_mapId');
  var noEl  = document.getElementById('$_noId');
  if (!rvEl || !mapEl || typeof kakao === 'undefined') return;

  var position = new kakao.maps.LatLng($lat, $lng);

  var roadview = new kakao.maps.Roadview(rvEl);
  var rvClient = new kakao.maps.RoadviewClient();

  var map = new kakao.maps.Map(mapEl, { center: position, level: 3 });
  var marker = new kakao.maps.Marker({ position: position, map: map });

  var personIcon = '<div style="width:28px;height:28px;background:#E53935;border:2px solid #fff;'
    + 'border-radius:50%;display:flex;align-items:center;justify-content:center;'
    + 'color:#fff;font-size:14px;box-shadow:0 2px 4px rgba(0,0,0,0.5);">&#x1F464;</div>';

  var overlay = new kakao.maps.CustomOverlay({
    position: position, content: personIcon, map: map, yAnchor: 1.0
  });

  rvClient.getNearestPanoId(position, 300, function(panoId) {
    if (panoId !== null) {
      roadview.setPanoId(panoId, position);

      kakao.maps.event.addListener(roadview, 'viewpoint_changed', function() {
        var vp = roadview.getViewpoint();
        overlay.setContent(
          '<div style="width:28px;height:28px;background:#E53935;border:2px solid #fff;'
          + 'border-radius:50%;display:flex;align-items:center;justify-content:center;'
          + 'color:#fff;font-size:14px;box-shadow:0 2px 4px rgba(0,0,0,0.5);'
          + 'transform:rotate(' + vp.pan + 'deg);">&#x1F464;</div>'
        );
      });

      kakao.maps.event.addListener(roadview, 'position_changed', function() {
        var p = roadview.getPosition();
        map.setCenter(p);
        marker.setPosition(p);
        overlay.setPosition(p);
      });
    } else {
      noEl.style.display = 'flex';
    }
  });
})();
''';

    html.document.body?.append(
      html.ScriptElement()..text = jsCode,
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(16),
      child: Container(
        width: screenSize.width * 0.85,
        height: screenSize.height * 0.80,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.4), blurRadius: 24)],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Column(children: [
            // 헤더
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              color: const Color(0xFF1C1C1E),
              child: Row(children: [
                const Icon(Icons.streetview, color: Color(0xFFE53935), size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
              ]),
            ),
            // 로드뷰 iframe
            Expanded(child: HtmlElementView(viewType: _viewId)),
          ]),
        ),
      ),
    );
  }
}
