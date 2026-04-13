import 'dart:async';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/ds_data_service.dart';
import '../services/erp_ds_compare_service.dart';
import '../services/inspection_service.dart';
import 'inspection_result_screen.dart';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

class InspectionScheduleScreen extends StatefulWidget {
  const InspectionScheduleScreen({super.key});
  @override
  State<InspectionScheduleScreen> createState() => _InspectionScheduleScreenState();
}

class _InspectionScheduleScreenState extends State<InspectionScheduleScreen>
    with SingleTickerProviderStateMixin {
  static const Color _primary = Color(0xFFE53935);
  static const Color _green = Color(0xFF43A047);
  static const Color _blue = Color(0xFF4A90D9);
  static const Color _orange = Color(0xFFFF9800);

  late final InspectionService _svc;
  late final TabController _tabCtrl;
  final _searchCtrl = TextEditingController();
  final _horizontalScrollCtrl = ScrollController();

  int _year = DateTime.now().year;
  String _sheet = 'all';

  // org-map 옵션
  Map<String, List<String>> _orgMap = {};
  List<String> _hdqts = [];          // 정렬된 본부 목록 (캐시)
  List<String> _currentTeams = [];   // 현재 선택 본부의 팀 목록 (캐시)
  List<String> _allQuarters = [];
  List<String> _allNationGroups = [];
  List<String> _allKcaResults = [];

  // pending 필터 (UI 선택 중)
  String _pHdqt = '', _pTeam = '', _pSearch = '', _pScheduled = '', _pSchedWeek = '';
  List<String> _pQuarters = [], _pNationGroups = [], _pKcaResults = [];

  // applied 필터 (실제 쿼리)
  String _aHdqt = '', _aTeam = '', _aSearch = '', _aScheduled = '';
  String _aSchedWeek = ''; // 수검예정주차 필터 (매트릭스 카드 클릭 시 세팅)
  List<String> _aQuarters = [], _aNationGroups = [], _aKcaResults = [];

  // 매트릭스 탭 전용 필터
  String _mHdqt = '', _mTeam = '', _mWeek = '', _mMonth = '';
  // 수검일정별 현황 월 네비게이션 (기본: 현재 달)
  int _navMonth = DateTime.now().month;

  // 다중 선택 (일괄 일정 등록)
  final _selectedLicenseNos = <String>{};
  // 이미 일정 등록된 허가번호 세트
  Set<String> _scheduledNos = {};
  // 허가번호 → 수검예정주차 맵
  Map<String, String> _scheduleWeekMap = {};

  List<Map<String, dynamic>> _items = [];
  int _total = 0;
  int _page = 1;
  bool _loading = false;
  String? _error;

  // 테이블 정렬
  int? _sortColIdx;
  bool _sortAsc = true;

  // 정렬 컬럼 인덱스 → 데이터 키 (체크박스 컬럼 제외, 1부터 시작)
  static const _scheduleColKeys = [
    null, // 0: 체크박스
    '수검일정', '허가번호', '호출명칭', '국종군', '부서',
    '연도주기', '설치장소', '도로명주소',
    '장치수', '통시', '공대', 'zpprac1', '시기조정', '기준연도',
    'SKT본부', 'Access담당', '품질개선팀', '검사결과',
  ];

  void _onScheduleSort(int colIdx, bool asc) {
    final key = _scheduleColKeys[colIdx];
    if (key == null) return;
    setState(() {
      _sortColIdx = colIdx;
      _sortAsc = asc;
      _items.sort((a, b) {
        final av = (a[key] ?? '').toString();
        final bv = (b[key] ?? '').toString();
        final an = double.tryParse(av);
        final bn = double.tryParse(bv);
        if (an != null && bn != null) return asc ? an.compareTo(bn) : bn.compareTo(an);
        return asc ? av.compareTo(bv) : bv.compareTo(av);
      });
    });
  }

  Map<String, dynamic> _matrix = {};
  List<String> _quarters = [];
  List<Map<String, dynamic>> _schedules = [];

  // 미배정 현황
  int _unassignedTotal = 0;
  Map<String, dynamic> _unassignedByRegion = {};
  Map<String, dynamic> _unassignedByReason = {};
  List<Map<String, dynamic>> _unassignedItems = [];
  bool _unassignedCapped = false;

  Map<String, dynamic>? _detailData;
  String? _detailLicenseNo;
  bool _detailLoading = false;

  // 권한 캐시 (build 중 context.read 반복 방지)
  late bool _isAdmin;
  late bool _isSuperAdmin;
  late bool _isDivisionAdmin;
  late String _myHdqt;
  late String _myTeam;

  void _cacheAuthValues() {
    final auth = context.read<AuthService>();
    final role = auth.userRoleStr;
    _isAdmin = role == 'admin' || role == 'manager';
    _isSuperAdmin = auth.isSuperAdmin;
    _isDivisionAdmin = auth.isDivisionAdmin;
    final dept = auth.userDepartment ?? '';
    _myHdqt = dept.replaceAll('Access담당', '').trim();
    _myTeam = auth.userTeam ?? '';
  }

  /// 해당 item에 대해 일정 등록/체크 권한이 있는지
  bool _canManageItem(Map<String, dynamic> item) {
    if (_isSuperAdmin) return true;
    if (_isDivisionAdmin) {
      final itemHdqt = '${item['access담당'] ?? ''}';
      return itemHdqt == _myHdqt;
    }
    return false; // member
  }

  bool _isScheduled(String licenseNo) => _scheduledNos.contains(licenseNo);

  Map<String, List<String>> get _activeFilters {
    final f = <String, List<String>>{};
    if (_aHdqt.isNotEmpty) f['access담당'] = [_aHdqt];
    if (_aTeam.isNotEmpty) f['품질개선팀'] = [_aTeam];
    if (_aQuarters.isNotEmpty) f['분기'] = _aQuarters;
    if (_aNationGroups.isNotEmpty) f['국종군'] = _aNationGroups;
    if (_aKcaResults.isNotEmpty) f['kca검토결과'] = _aKcaResults;
    return f;
  }

  bool get _hasActiveFilters =>
      _aHdqt.isNotEmpty || _aTeam.isNotEmpty || _aQuarters.isNotEmpty ||
      _aNationGroups.isNotEmpty || _aKcaResults.isNotEmpty || _aSearch.isNotEmpty ||
      _aScheduled.isNotEmpty || _aSchedWeek.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _svc = InspectionService()..setAuthToken(context.read<AuthService>().authToken);
    _cacheAuthValues();
    _applyDefaultFilter();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadOrgMap();
      _loadAll();
    });
  }

  void _applyDefaultFilter() {
    if (_isSuperAdmin) return; // superadmin은 전체 조회
    if (_myHdqt.isNotEmpty) {
      _pHdqt = _myHdqt;
      _aHdqt = _myHdqt;
      _mHdqt = _myHdqt; // 매트릭스 탭 본부 필터 자동 적용
    }
    // member(일반 팀원)인 경우 팀까지 자동 필터 (org_map에 있는 팀만)
    if (!_isAdmin && _myTeam.isNotEmpty) {
      final teams = _orgMap[_myHdqt] ?? [];
      if (teams.contains(_myTeam)) {
        _pTeam = _myTeam;
        _aTeam = _myTeam;
      }
    }
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    _horizontalScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() { _loading = true; _error = null; });
    final results = await Future.wait([
      _fetchData(),
      _fetchSummary(),
      _fetchUnassigned(),
      _fetchScheduledNos(),
    ]);
    if (!mounted) return;
    final dataRes   = results[0] as Map<String, dynamic>?;
    final summRes   = results[1] as Map<String, dynamic>?;
    final unassRes  = results[2] as Map<String, dynamic>?;
    final schedResult = results[3] as ({Set<String> nos, Map<String, String> weekMap, List<Map<String, dynamic>> schedules})?;
    setState(() {
      _loading = false;
      if (dataRes != null) {
        _items = List<Map<String, dynamic>>.from(dataRes['items'] ?? []);
        _total = (dataRes['total'] as num?)?.toInt() ?? 0;
      } else {
        _error = '데이터 로드 실패';
      }
      if (summRes != null) {
        _matrix = Map<String, dynamic>.from(summRes['matrix'] ?? {});
        _quarters = List<String>.from(summRes['quarters'] ?? []);
      }
      if (unassRes != null) {
        _unassignedTotal = (unassRes['total'] as num?)?.toInt() ?? 0;
        _unassignedByRegion = Map<String, dynamic>.from(unassRes['by_region'] ?? {});
        _unassignedByReason = Map<String, dynamic>.from(unassRes['by_reason'] ?? {});
        _unassignedItems = List<Map<String, dynamic>>.from(unassRes['items'] ?? []);
        _unassignedCapped = unassRes['items_capped'] == true;
      }
      if (schedResult != null) {
        _scheduledNos = schedResult.nos;
        _scheduleWeekMap = schedResult.weekMap;
        _schedules = schedResult.schedules;
      }
    });
  }

  Future<Map<String, dynamic>?> _fetchData() async {
    try {
      return await _svc.getData(
        year: _year, sheet: _sheet,
        filters: _activeFilters,
        search: _aSearch,
        addr: _aSearch,
        page: _page, pageSize: 100,
        scheduleYn: _aScheduled,
        scheduleWeek: _aSchedWeek,
      );
    } catch (_) { return null; }
  }

  Future<Map<String, dynamic>?> _fetchSummary() async {
    try {
      return await _svc.getSummary(
        year: _year, sheet: _sheet,
        filters: _activeFilters,
        search: _aSearch,
        addr: _aSearch,
        scheduleYn: _aScheduled,
      );
    } catch (_) { return null; }
  }

  Future<Map<String, dynamic>?> _fetchUnassigned() async {
    try {
      return await _svc.getUnassigned(_year);
    } catch (_) { return null; }
  }

  Future<({Set<String> nos, Map<String, String> weekMap, List<Map<String, dynamic>> schedules})?> _fetchScheduledNos() async {
    try {
      final schedules = await _svc.getSchedules(_year);
      final nos = <String>{};
      final weekMap = <String, String>{};
      for (final s in schedules) {
        final no = (s['허가번호'] as String? ?? '').trim();
        if (no.isEmpty) continue;
        nos.add(no);
        final week = (s['수검예정주차'] as String? ?? '').trim();
        if (week.isNotEmpty) weekMap[no] = week;
      }
      return (nos: nos, weekMap: weekMap, schedules: schedules);
    } catch (_) { return null; }
  }

  // 일정 등록/수정/삭제 후 목록만 갱신
  Future<void> _loadScheduledNos() async {
    final result = await _fetchScheduledNos();
    if (!mounted || result == null) return;
    setState(() {
      _scheduledNos = result.nos;
      _scheduleWeekMap = result.weekMap;
      _schedules = result.schedules;
    });
  }

  // 페이지 이동 시 데이터만 갱신
  Future<void> _loadData() async {
    setState(() { _loading = true; _error = null; });
    final res = await _fetchData();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res != null) {
        _items = List<Map<String, dynamic>>.from(res['items'] ?? []);
        _total = (res['total'] as num?)?.toInt() ?? 0;
      } else {
        _error = '데이터 로드 실패';
      }
    });
  }

  Future<void> _loadOrgMap() async {
    try {
      final res = await _svc.getOrgMap(_year);
      setState(() {
        _orgMap = {};
        final org = res['org'] as Map<String, dynamic>? ?? {};
        org.forEach((hdqt, teams) {
          _orgMap[hdqt] = (teams as List? ?? []).map((e) => '$e').toList();
        });
        _hdqts = _orgMap.keys.toList()..sort();
        _currentTeams = _pHdqt.isNotEmpty ? (_orgMap[_pHdqt] ?? []) : [];
        _allQuarters = (res['quarters'] as List? ?? []).map((e) => '$e').toList();
        _allNationGroups = (res['nation_groups'] as List? ?? []).map((e) => '$e').toList();
        _allKcaResults = (res['kca_results'] as List? ?? []).map((e) => '$e').toList();
      });
    } catch (_) {}
  }

  Future<void> _loadDetail(String licenseNo) async {
    setState(() { _detailLoading = true; _detailData = null; _detailLicenseNo = licenseNo; });
    try {
      final data = await _svc.getDetail(_year, licenseNo);
      if (!mounted) return;
      setState(() { _detailData = data; _detailLoading = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() => _detailLoading = false);
    }
  }

  void _applyFilters() {
    // setState 없이 먼저 값 업데이트 → _loadAll의 setState로 한 번만 리빌드
    _aHdqt = _pHdqt; _aTeam = _pTeam; _aSearch = _pSearch;
    _aScheduled = _pScheduled;
    _aSchedWeek = _pSchedWeek;
    _aQuarters = List.from(_pQuarters);
    _aNationGroups = List.from(_pNationGroups);
    _aKcaResults = List.from(_pKcaResults);
    _page = 1;
    _loadAll();
  }

  void _resetFilters() {
    _pHdqt = _pTeam = _pSearch = _pScheduled = _pSchedWeek = '';
    _aHdqt = _aTeam = _aSearch = _aScheduled = _aSchedWeek = '';
    _pQuarters = []; _pNationGroups = []; _pKcaResults = [];
    _aQuarters = []; _aNationGroups = []; _aKcaResults = [];
    _searchCtrl.clear();
    _page = 1;
    _selectedLicenseNos.clear();
    _loadAll();
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red.shade700 : Colors.black87,
      behavior: SnackBarBehavior.floating,
    ));
  }

  /// 로딩 팝업을 띄우면서 비동기 작업 실행 후 팝업 자동 닫기
  Future<T> _withLoading<T>(String message, Future<T> Function() task) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: Dialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: _primary),
              ),
              const SizedBox(width: 16),
              Text(message, style: const TextStyle(fontSize: 14)),
            ]),
          ),
        ),
      ),
    );
    try {
      return await task();
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  String _formatNumber(int n) => n.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');

  // ── Schedule 등록 ───────────────────────────────────────

  Future<void> _showScheduleDialog(Map<String, dynamic> item) async {
    final existing = item['schedule']?['수검예정주차'] as String? ?? '';
    final match = RegExp(r'(\d+)월\s*(\d+)주차').firstMatch(existing);
    final initMonth = match != null ? int.tryParse(match.group(1)!) : null;
    final initWeek = match != null ? int.tryParse(match.group(2)!) : null;

    final existingInspector = item['schedule']?['검사관'] as String? ?? '';
    final existingJo = item['schedule']?['조'] as String? ?? '';
    final inspectorCtrl = TextEditingController(text: existingInspector);
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        int? selMonth = initMonth;
        int? selWeek = initWeek;
        String selJo = existingJo;
        return StatefulBuilder(
          builder: (ctx, setDlgState) => AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text(item['schedule'] != null ? '수검 일정 수정' : '수검 일정 등록',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            content: SizedBox(
              width: 320,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${item['호출명칭'] ?? ''}\n${item['허가번호'] ?? ''}',
                    style: const TextStyle(fontSize: 13, color: Colors.black54)),
                const SizedBox(height: 20),
                Row(children: [
                  Expanded(child: _weekDropdown('월', selMonth,
                      List.generate(12, (i) => i + 1),
                      (m) => '$m월',
                      (v) => setDlgState(() => selMonth = v))),
                  const SizedBox(width: 12),
                  Expanded(child: _weekDropdown('주차', selWeek,
                      List.generate(5, (i) => i + 1),
                      (w) => '$w주차',
                      (v) => setDlgState(() => selWeek = v))),
                ]),
                if (selMonth != null && selWeek != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: _blue.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('$selMonth월 $selWeek주차',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: _blue, fontWeight: FontWeight.w600)),
                  ),
                ],
                const SizedBox(height: 16),
                _weekDropdown('조 (선택)', selJo.isEmpty ? null : int.tryParse(selJo.replaceAll('조', '')),
                    [1, 2, 3, 4, 5], (i) => '$i조',
                    (v) => setDlgState(() => selJo = v != null ? '$v조' : ''),
                    nullable: true),
                const SizedBox(height: 16),
                TextField(
                  controller: inspectorCtrl,
                  decoration: InputDecoration(
                    labelText: '검사관',
                    hintText: '검사관 이름 입력',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                onPressed: selMonth != null && selWeek != null
                    ? () => Navigator.pop(ctx, {'month': selMonth!, 'week': selWeek!, '검사관': inspectorCtrl.text.trim(), '조': selJo})
                    : null,
                child: const Text('저장'),
              ),
            ],
          ),
        );
      },
    );
    inspectorCtrl.dispose();
    if (result == null) return;
    final weekStr = '${result['month']}월 ${result['week']}주차';
    try {
      await _withLoading('일정 저장 중...', () => _svc.upsertSchedule({
        'year': _year,
        '허가번호': item['허가번호'],
        '호출명칭': item['호출명칭'] ?? '',
        '분기': item['분기'] ?? '',
        'skt본부': item['skt본부'] ?? '',
        'access담당': item['access담당'] ?? '',
        '품질개선팀': item['품질개선팀'] ?? '',
        '수검예정주차': weekStr,
        '수검시작일': '',
        '수검종료일': '',
        '지역': '',
        '검사관': result['검사관'] ?? '',
        '조': result['조'] ?? '',
      }));
      _showSnack('일정이 저장되었습니다.');
      await Future.wait([
        _loadData(),
        if (_detailLicenseNo != null) _loadDetail(_detailLicenseNo!),
        _loadScheduledNos(),
      ]);
    } catch (e) {
      _showSnack('저장 실패: $e', isError: true);
    }
  }

  Future<void> _deleteScheduleConfirm(String licenseNo, String callname) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('일정 제거', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(callname, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          Text(licenseNo, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 12),
          const Text('수검 일정을 제거하시겠습니까?', style: TextStyle(fontSize: 14)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('제거'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _withLoading('일정 삭제 중...', () => _svc.deleteSchedule(_year, licenseNo));
      _showSnack('일정이 제거되었습니다.');
      await Future.wait([
        _loadData(),
        if (_detailLicenseNo != null) _loadDetail(_detailLicenseNo!),
        _loadScheduledNos(),
      ]);
    } catch (e) {
      _showSnack('제거 실패: $e', isError: true);
    }
  }

  List<Widget> _buildBulkActionButtons() {
    final scheduledSelected = _items
        .where((item) {
          final no = '${item['허가번호'] ?? ''}';
          return _selectedLicenseNos.contains(no) && _isScheduled(no);
        }).toList();
    final unscheduledSelected = _items
        .where((item) {
          final no = '${item['허가번호'] ?? ''}';
          return _selectedLicenseNos.contains(no) && !_isScheduled(no);
        }).toList();

    const btnShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(10)),
    );
    const btnPad = EdgeInsets.symmetric(horizontal: 14, vertical: 8);

    return [
      if (unscheduledSelected.isNotEmpty)
        ElevatedButton.icon(
          icon: const Icon(Icons.event_available, size: 16),
          label: Text('${unscheduledSelected.length}건 일정 등록'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _blue, foregroundColor: Colors.white,
            shape: btnShape, padding: btnPad,
          ),
          onPressed: () => _showBulkUpsertDialog(unscheduledSelected, '일정 등록'),
        ),
      if (scheduledSelected.isNotEmpty) ...[
        if (unscheduledSelected.isNotEmpty) const SizedBox(width: 8),
        ElevatedButton.icon(
          icon: const Icon(Icons.edit_calendar, size: 16),
          label: Text('${scheduledSelected.length}건 일정 수정'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _blue, foregroundColor: Colors.white,
            shape: btnShape, padding: btnPad,
          ),
          onPressed: () => _showBulkUpsertDialog(scheduledSelected, '일정 수정'),
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          icon: const Icon(Icons.delete_outline, size: 16),
          label: Text('${scheduledSelected.length}건 일정 제거'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _primary, foregroundColor: Colors.white,
            shape: btnShape, padding: btnPad,
          ),
          onPressed: () => _showBulkDeleteDialog(scheduledSelected),
        ),
      ],
    ];
  }

  // ── 전산비교 다이얼로그 ─────────────────────────────────────

  Future<void> _showCompareDialog() async {
    final auth = context.read<AuthService>();
    final compareService = ErpDsCompareService()..setAuthToken(auth.authToken);
    final dsService = DsDataService()..setAuthToken(auth.authToken);
    final licenseNos = _selectedLicenseNos.toList();

    // 선택된 항목의 access담당 추출 → 최다 본부 기준으로 DS 파일 자동 선택
    final accessValues = _items
        .where((item) => _selectedLicenseNos.contains('${item['허가번호'] ?? ''}'))
        .map((item) => (item['access담당'] as String? ?? '').trim())
        .where((v) => v.isNotEmpty)
        .toList();
    final counter = <String, int>{};
    for (final v in accessValues) counter[v] = (counter[v] ?? 0) + 1;
    final dominantAccess = counter.isEmpty ? null
        : counter.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final uniqueAccess = counter.keys.toSet();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _CompareDialog(
        licenseNos: licenseNos,
        accessDivisionName: dominantAccess,
        multiDivision: uniqueAccess.length > 1,
        compareService: compareService,
        dsService: dsService,
      ),
    );
  }

  Future<void> _showBulkUpsertDialog(List<Map<String, dynamic>> targetItems, String actionTitle) async {
    if (targetItems.isEmpty) return;

    final inspectorCtrl = TextEditingController();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        int? selMonth;
        int? selWeek;
        String selJo = '';
        return StatefulBuilder(
          builder: (ctx, setDlgState) => AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('$actionTitle (${targetItems.length}건)',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            content: SizedBox(
              width: 400,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _blue.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('선택된 국소 (${targetItems.length}건):',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    ...targetItems.take(5).map((item) => Text(
                      '• ${item['호출명칭'] ?? ''} (${item['허가번호'] ?? ''})',
                      style: const TextStyle(fontSize: 12),
                    )),
                    if (targetItems.length > 5)
                      Text('…외 ${targetItems.length - 5}건',
                          style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  ]),
                ),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(child: _weekDropdown('월', selMonth,
                      List.generate(12, (i) => i + 1),
                      (m) => '$m월',
                      (v) => setDlgState(() => selMonth = v))),
                  const SizedBox(width: 12),
                  Expanded(child: _weekDropdown('주차', selWeek,
                      List.generate(5, (i) => i + 1),
                      (w) => '$w주차',
                      (v) => setDlgState(() => selWeek = v))),
                ]),
                if (selMonth != null && selWeek != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    decoration: BoxDecoration(
                      color: _blue.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('$selMonth월 $selWeek주차',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, color: _blue, fontWeight: FontWeight.w600)),
                  ),
                ],
                const SizedBox(height: 16),
                _weekDropdown('조 (선택)', selJo.isEmpty ? null : int.tryParse(selJo.replaceAll('조', '')),
                    [1, 2, 3, 4, 5], (i) => '$i조',
                    (v) => setDlgState(() => selJo = v != null ? '$v조' : ''),
                    nullable: true),
                const SizedBox(height: 16),
                TextField(
                  controller: inspectorCtrl,
                  decoration: InputDecoration(
                    labelText: '검사관',
                    hintText: '검사관 이름 입력',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                onPressed: selMonth != null && selWeek != null
                    ? () => Navigator.pop(ctx, {'month': selMonth!, 'week': selWeek!, '검사관': inspectorCtrl.text.trim(), '조': selJo})
                    : null,
                child: const Text('저장'),
              ),
            ],
          ),
        );
      },
    );
    inspectorCtrl.dispose();
    if (result == null) return;
    final weekStr = '${result['month']}월 ${result['week']}주차';
    final inspector = result['검사관'] as String? ?? '';
    final jo = result['조'] as String? ?? '';

    int successCount = 0, failCount = 0;
    await _withLoading('일정 등록 중... (${targetItems.length}건)', () async {
      final results = await Future.wait(
        targetItems.map((item) => _svc.upsertSchedule({
          'year': _year,
          '허가번호': item['허가번호'],
          '호출명칭': item['호출명칭'] ?? '',
          '분기': item['분기'] ?? '',
          'skt본부': item['skt본부'] ?? '',
          'access담당': item['access담당'] ?? '',
          '품질개선팀': item['품질개선팀'] ?? '',
          '수검예정주차': weekStr,
          '수검시작일': '',
          '수검종료일': '',
          '지역': '',
          '검사관': inspector,
          '조': jo,
        }).then((_) => true).catchError((_) => false)),
      );
      successCount = results.where((r) => r).length;
      failCount = results.where((r) => !r).length;
    });
    setState(() => _selectedLicenseNos.clear());
    await Future.wait([_loadData(), _loadScheduledNos()]);
    if (failCount == 0) {
      _showSnack('$successCount건 일정이 저장되었습니다.');
    } else {
      _showSnack('$successCount건 저장, $failCount건 실패', isError: true);
    }
  }

  Future<void> _showBulkDeleteDialog(List<Map<String, dynamic>> targetItems) async {
    if (targetItems.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('일정 제거 (${targetItems.length}건)',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('제거할 국소 (${targetItems.length}건):',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                ...targetItems.take(5).map((item) => Text(
                  '• ${item['호출명칭'] ?? ''} (${item['허가번호'] ?? ''})',
                  style: const TextStyle(fontSize: 12),
                )),
                if (targetItems.length > 5)
                  Text('…외 ${targetItems.length - 5}건',
                      style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ]),
            ),
            const SizedBox(height: 12),
            const Text('선택된 국소의 수검 일정을 모두 제거하시겠습니까?',
                style: TextStyle(fontSize: 14)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('제거'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    int successCount = 0, failCount = 0;
    await _withLoading('일정 삭제 중... (${targetItems.length}건)', () async {
      final results = await Future.wait(
        targetItems.map((item) =>
          _svc.deleteSchedule(_year, '${item['허가번호'] ?? ''}')
            .then((_) => true).catchError((_) => false)),
      );
      successCount = results.where((r) => r).length;
      failCount = results.where((r) => !r).length;
    });
    setState(() => _selectedLicenseNos.clear());
    await Future.wait([_loadData(), _loadScheduledNos()]);
    if (failCount == 0) {
      _showSnack('$successCount건 일정이 제거되었습니다.');
    } else {
      _showSnack('$successCount건 제거, $failCount건 실패', isError: true);
    }
  }

  Future<void> _exportExcel() async {
    if (_aHdqt.isEmpty) {
      _showSnack('Excel 다운로드를 하려면 본부 필터를 선택하세요.', isError: true);
      return;
    }
    try {
      _showSnack('Excel 다운로드 중...');
      final bytes = await _svc.exportXlsx(
        year: _year, sheet: _sheet,
        filters: _activeFilters,
        search: _aSearch,
        addr: _aSearch,
      );
      final blob = html.Blob([bytes],
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)
        ..setAttribute('download', '수검대상_$_year년.xlsx')
        ..click();
      html.Url.revokeObjectUrl(url);
    } catch (e) {
      _showSnack('Excel 다운로드 실패: $e', isError: true);
    }
  }

  Future<void> _showAddFromStagingDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _AddFromStagingDialog(
        svc: _svc,
        year: _year,
        orgMap: _orgMap,
        hdqts: _hdqts,
        allQuarters: _allQuarters,
        allNationGroups: _allNationGroups,
        onConfirm: (licenseNos) async {
          Navigator.pop(ctx);
          int ok = 0;
          for (final no in licenseNos) {
            try {
              await _svc.addFromStaging(_year, no);
              ok++;
            } catch (_) {}
          }
          _loadData();
          _loadOrgMap();
          _showSnack('$ok건이 수검 대상에 추가되었습니다 (검토여부: 대상 추가)');
        },
      ),
    );
  }

  Future<void> _showInspectionReportDialog() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _InspectionReportDialog(
        svc: _svc,
        year: _year,
        orgMap: _orgMap,
        hdqts: _hdqts,
        allQuarters: _allQuarters,
        allNationGroups: _allNationGroups,
        allKcaResults: _allKcaResults,
        onConfirm: (licenseNos, sheetTitle) {
          Navigator.pop(ctx);
          _exportInspectionReport(licenseNos: licenseNos, sheetTitle: sheetTitle);
        },
      ),
    );
  }

  Future<void> _exportInspectionReport({
    List<String> licenseNos = const [],
    String sheetTitle = '',
  }) async {
    try {
      _showSnack('검사내역서 생성 중...');
      final bytes = await _svc.exportInspectionReport(
        year: _year,
        licenseNos: licenseNos,
        sheetTitle: sheetTitle,
      );
      final label = sheetTitle.isNotEmpty ? sheetTitle : '전체';
      final blob = html.Blob([bytes],
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)
        ..setAttribute('download', '검사내역서_${_year}년_$label.xlsx')
        ..click();
      html.Url.revokeObjectUrl(url);
      _showSnack('검사내역서 다운로드 완료');
    } catch (e) {
      _showSnack('검사내역서 생성 실패: $e', isError: true);
    }
  }

  Widget _weekDropdown<T>(String hint, T? value, List<T> items,
      String Function(T) label, ValueChanged<T?> onChanged, {bool nullable = false}) {
    final menuItems = [
      if (nullable) DropdownMenuItem<T>(value: null, child: Text(hint, style: const TextStyle(fontSize: 13, color: Colors.black45))),
      ...items.map((v) => DropdownMenuItem(value: v, child: Text(label(v)))),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          isExpanded: true,
          isDense: true,
          hint: Text(hint, style: const TextStyle(fontSize: 13)),
          value: value,
          icon: Icon(Icons.arrow_drop_down, color: _blue, size: 20),
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          style: const TextStyle(color: Colors.black87, fontSize: 13),
          items: menuItems,
          onChanged: onChanged,
        ),
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFB),
      body: Column(
        children: [
          Container(
            color: Colors.white,
            child: TabBar(
              controller: _tabCtrl,
              labelColor: _primary,
              unselectedLabelColor: Colors.grey,
              indicatorColor: _primary,
              tabs: const [Tab(text: '매트릭스'), Tab(text: '수검 대상 현황')],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _buildMain()),
                if (_detailLicenseNo != null) _buildDetailPanel(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMain() {
    return Column(children: [
      // 탭별 필터바: 수검 대상 현황 탭은 기존 필터, 매트릭스 탭은 별도 필터
      AnimatedBuilder(
        animation: _tabCtrl,
        builder: (_, __) => _tabCtrl.index == 0 ? _buildMatrixFilterBar() : _buildFilterBar(),
      ),
      Expanded(
        child: TabBarView(
          controller: _tabCtrl,
          children: [_buildMatrixTab(), _buildDataTab()],
        ),
      ),
    ]);
  }

  // ── 필터 바 ────────────────────────────────────────────

  Widget _buildFilterBar() {

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: 연도, 시트, 검색창, 총건수, 일괄등록 버튼
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _yearDropdown(),
              _sheetDropdown(),
              SizedBox(
                width: 280,
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _pSearch = v),
                  decoration: InputDecoration(
                    hintText: '호출명칭, 허가번호 또는 주소 (복수검색: 쉼표/공백 구분)',
                    hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18, color: Colors.grey.shade400),
                    filled: true,
                    fillColor: const Color(0xFFF9FAFB),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: _primary, width: 1.5),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  style: const TextStyle(fontSize: 13),
                  onSubmitted: (_) => _applyFilters(),
                ),
              ),
              if (_total > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F9FF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFBAE6FD)),
                  ),
                  child: Text('${_formatNumber(_total)}건',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF0369A1))),
                ),
              if (_isAdmin)
                OutlinedButton.icon(
                  icon: const Icon(Icons.add_circle_outline, size: 16),
                  label: const Text('대상 추가', style: TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF7B1FA2),
                    side: const BorderSide(color: Color(0xFF7B1FA2)),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                  onPressed: _showAddFromStagingDialog,
                ),
              if (_isAdmin && _selectedLicenseNos.isNotEmpty) ..._buildBulkActionButtons(),
              if (_selectedLicenseNos.isNotEmpty) ...[
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.compare_arrows, size: 16),
                  label: Text('${_selectedLicenseNos.length}건 전산비교'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1565C0),
                    foregroundColor: Colors.white,
                    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(10))),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                  onPressed: _showCompareDialog,
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: Colors.grey.shade200),
          const SizedBox(height: 12),
          // Row 2: 필터 드롭다운 + 적용/초기화
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _filterDropdown('본부', _pHdqt, ['', ..._hdqts],
                  (v) => setState(() { _pHdqt = v!; _pTeam = ''; _currentTeams = _orgMap[v] ?? []; })),
              _filterDropdown('팀', _pTeam, ['', ..._currentTeams],
                  (v) => setState(() => _pTeam = v!)),
              _buildMultiDropdown('분기', _pQuarters, _allQuarters,
                  (v) => setState(() => _pQuarters = v)),
              _buildMultiDropdown('밴드선택', _pNationGroups, _allNationGroups,
                  (v) => setState(() => _pNationGroups = v)),
              _buildMultiDropdown('검토여부', _pKcaResults, _allKcaResults,
                  (v) => setState(() => _pKcaResults = v)),
              _filterDropdown('일정등록', _pScheduled, const ['', 'Y', 'N'],
                  (v) => setState(() => _pScheduled = v ?? ''),
                  displayMap: const {'Y': '등록', 'N': '미등록'}),
              Builder(builder: (_) {
                final allWeeks = <String>{};
                for (final s in _schedules) {
                  final w = (s['수검예정주차'] as String? ?? '').trim();
                  if (w.isNotEmpty) allWeeks.add(w);
                }
                final weekOptions = <String>['', ...allWeeks.toList()
                  ..sort((a, b) {
                    final na = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
                    final nb = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
                    return na.compareTo(nb);
                  })];
                return _filterDropdown('수검일정', _pSchedWeek, weekOptions,
                    (v) => setState(() => _pSchedWeek = v ?? ''));
              }),
              const SizedBox(width: 4),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary, foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  elevation: 0,
                ),
                onPressed: _applyFilters,
                child: const Text('적용', style: TextStyle(fontSize: 13)),
              ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.grey.shade600,
                  side: BorderSide(color: Colors.grey.shade300),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                ),
                onPressed: _resetFilters,
                child: const Text('초기화', style: TextStyle(fontSize: 13)),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.file_download, size: 16),
                label: const Text('Excel', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF43A047),
                  side: const BorderSide(color: Color(0xFF43A047)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
                onPressed: _exportExcel,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.assignment, size: 16),
                label: const Text('검사내역서', style: TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1565C0),
                  side: const BorderSide(color: Color(0xFF1565C0)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
                onPressed: _showInspectionReportDialog,
              ),
            ],
          ),
          if (_hasActiveFilters) ...[
            const SizedBox(height: 10),
            _buildActiveFilterChips(),
          ],
        ],
      ),
    );
  }

  // ── 매트릭스 탭 전용 필터바 ──────────────────────────────

  Widget _buildMatrixFilterBar() {
    // 수검일정(주차) 목록: _schedules에서 추출
    final allWeeks = <String>{};
    for (final s in _schedules) {
      final w = (s['수검예정주차'] as String? ?? '').trim();
      if (w.isNotEmpty) allWeeks.add(w);
    }
    final weekOptions = <String>['', ...allWeeks.toList()
      ..sort((a, b) {
        final na = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        final nb = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        return na.compareTo(nb);
      })];

    // 월 목록: 주차에서 추출
    String extractMonthLabel(String week) {
      final m = RegExp(r'(\d+)월').firstMatch(week);
      return m != null ? '${m.group(1)}월' : '기타';
    }
    final allMonths = <String>{};
    for (final w in allWeeks) {
      allMonths.add(extractMonthLabel(w));
    }
    final monthOptions = <String>['', '전체', ...allMonths.toList()
      ..sort((a, b) {
        final na = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        final nb = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        return na.compareTo(nb);
      })];

    // 매트릭스 탭 팀 옵션: 선택된 본부 기준
    final mTeamOpts = <String>['', ...(_mHdqt.isNotEmpty ? (_orgMap[_mHdqt] ?? []) : _orgMap.values.expand((v) => v).toSet().toList()..sort())];

    final now = DateTime.now();
    final String monthHint = _mMonth.isEmpty
        ? '${now.month - 1 > 0 ? now.month - 1 : 12}~${now.month + 1 <= 12 ? now.month + 1 : 1}월'
        : _mMonth;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _yearDropdown(),
          _filterDropdown('본부', _mHdqt, ['', ..._hdqts], (v) {
            setState(() { _mHdqt = v ?? ''; _mTeam = ''; });
          }),
          _filterDropdown('팀', _mTeam, mTeamOpts, (v) {
            setState(() => _mTeam = v ?? '');
          }),
          _filterDropdown('수검일정', _mWeek, weekOptions, (v) {
            setState(() => _mWeek = v ?? '');
          }),
          // 월 필터 (기본: 현재 ±1개월)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(
                color: _mMonth.isNotEmpty ? _primary : Colors.grey.shade300,
                width: _mMonth.isNotEmpty ? 1.5 : 1,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: monthOptions.contains(_mMonth) ? _mMonth : '',
                isDense: true,
                icon: Icon(Icons.arrow_drop_down,
                    color: _mMonth.isNotEmpty ? _primary : Colors.grey.shade500, size: 20),
                dropdownColor: Colors.white,
                borderRadius: BorderRadius.circular(12),
                style: TextStyle(
                    color: _mMonth.isNotEmpty ? _primary : Colors.black87, fontSize: 13),
                hint: Text('월 ($monthHint)',
                    style: TextStyle(
                        fontSize: 13,
                        color: _mMonth.isEmpty ? _primary.withValues(alpha: 0.8) : Colors.black87)),
                items: monthOptions.map((m) => DropdownMenuItem(
                  value: m,
                  child: Text(
                    m.isEmpty ? '기본 (±1개월)' : m == '전체' ? '전체 월' : m,
                    style: const TextStyle(fontSize: 13),
                  ),
                )).toList(),
                onChanged: (v) {
                  final val = v ?? '';
                  final monthNum = int.tryParse(val.replaceAll(RegExp(r'[^0-9]'), ''));
                  setState(() {
                    _mMonth = val;
                    if (monthNum != null && monthNum >= 1 && monthNum <= 12) _navMonth = monthNum;
                  });
                },
              ),
            ),
          ),
          if ((_isSuperAdmin ? _mHdqt.isNotEmpty : _mHdqt != _myHdqt) || _mTeam.isNotEmpty || _mWeek.isNotEmpty || _mMonth.isNotEmpty)
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey.shade600,
                side: BorderSide(color: Colors.grey.shade300),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
              onPressed: () => setState(() { _mHdqt = _isSuperAdmin ? '' : _myHdqt; _mTeam = ''; _mWeek = ''; _mMonth = ''; }),
              child: const Text('초기화', style: TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }

  Widget _yearDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: _year,
          isDense: true,
          icon: Icon(Icons.arrow_drop_down, color: _primary, size: 20),
          dropdownColor: Colors.white,

          borderRadius: BorderRadius.circular(12),
          style: const TextStyle(color: Colors.black87, fontSize: 13),
          items: List.generate(5, (i) => DateTime.now().year - 1 + i)
              .map((y) => DropdownMenuItem(value: y, child: Text('$y년')))
              .toList(),
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              _year = v;
              _pHdqt = _pTeam = _pSearch = '';
              _aHdqt = _aTeam = _aSearch = '';
              _pQuarters = []; _pNationGroups = []; _pKcaResults = [];
              _aQuarters = []; _aNationGroups = []; _aKcaResults = [];
              _searchCtrl.clear();
              _selectedLicenseNos.clear();
            });
            _loadOrgMap();
            _loadAll();
          },
        ),
      ),
    );
  }

  Widget _sheetDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _sheet,
          isDense: true,
          icon: Icon(Icons.arrow_drop_down, color: _primary, size: 20),
          dropdownColor: Colors.white,

          borderRadius: BorderRadius.circular(12),
          style: const TextStyle(color: Colors.black87, fontSize: 13),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('전체')),
            DropdownMenuItem(value: 'SKT', child: Text('정기검사')),
            DropdownMenuItem(value: 'sheet1', child: Text('시기조정')),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() => _sheet = v);
            _loadAll();
          },
        ),
      ),
    );
  }

  Widget _filterDropdown(String label, String value, List<String> options,
      void Function(String?) onChanged, {Map<String, String>? displayMap}) {
    // options에 없는 value면 빈 문자열로 폴백 (로딩 중 assertion 방지)
    final safeValue = options.contains(value) ? value : '';
    String display(String v) {
      if (v.isEmpty) return label;
      return displayMap?[v] ?? v;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: safeValue.isNotEmpty ? _primary : Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: safeValue,
          isDense: true,
          icon: Icon(Icons.arrow_drop_down,
              color: safeValue.isNotEmpty ? _primary : Colors.grey, size: 20),
          dropdownColor: Colors.white,

          borderRadius: BorderRadius.circular(12),
          style: const TextStyle(color: Colors.black87, fontSize: 13),
          items: options
              .map((v) => DropdownMenuItem(
                    value: v,
                    child: Text(
                      display(v),
                      style: TextStyle(
                          color: v.isEmpty ? Colors.grey.shade500 : Colors.black87),
                    ),
                  ))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildMultiDropdown(String label, List<String> selected, List<String> options,
      void Function(List<String>) onChanged) {
    final hasVal = selected.isNotEmpty;
    final displayText = hasVal ? '$label (${selected.length})' : label;
    return GestureDetector(
      onTap: () async {
        final result = await showDialog<List<String>>(
          context: context,
          builder: (ctx) => _MultiSelectDialog(
            title: label, options: options, selected: selected,
          ),
        );
        if (result != null) onChanged(result);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: hasVal ? _primary : Colors.grey.shade300),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(displayText,
              style: TextStyle(fontSize: 13,
                  color: hasVal ? _primary : Colors.grey.shade600)),
          const SizedBox(width: 4),
          Icon(Icons.arrow_drop_down,
              color: hasVal ? _primary : Colors.grey, size: 20),
        ]),
      ),
    );
  }

  Widget _buildActiveFilterChips() {
    final chips = <Widget>[];
    void addChip(String label, String val, VoidCallback onDel) {
      chips.add(Chip(
        label: Text('$label: $val', style: const TextStyle(fontSize: 11, color: Color(0xFF374151))),
        backgroundColor: const Color(0xFFF3F4F6),
        side: BorderSide(color: Colors.grey.shade300),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        deleteIcon: Icon(Icons.close, size: 14, color: Colors.grey.shade500),
        onDeleted: onDel,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ));
    }

    if (_aHdqt.isNotEmpty) {
      addChip('본부', _aHdqt, () {
        setState(() { _pHdqt = ''; _aHdqt = ''; _pTeam = ''; _aTeam = ''; _page = 1; });
        _loadAll();
      });
    }
    if (_aTeam.isNotEmpty) {
      addChip('팀', _aTeam, () {
        setState(() { _pTeam = ''; _aTeam = ''; _page = 1; });
        _loadAll();
      });
    }
    if (_aQuarters.isNotEmpty) {
      addChip('분기', _aQuarters.join(', '), () {
        setState(() { _pQuarters = []; _aQuarters = []; _page = 1; });
        _loadAll();
      });
    }
    if (_aNationGroups.isNotEmpty) {
      addChip('밴드', _aNationGroups.join(', '), () {
        setState(() { _pNationGroups = []; _aNationGroups = []; _page = 1; });
        _loadAll();
      });
    }
    if (_aKcaResults.isNotEmpty) {
      addChip('검토여부', _aKcaResults.join(', '), () {
        setState(() { _pKcaResults = []; _aKcaResults = []; _page = 1; });
        _loadAll();
      });
    }
    if (_aSearch.isNotEmpty) {
      addChip('검색', _aSearch, () {
        setState(() { _pSearch = ''; _aSearch = ''; _searchCtrl.clear(); _page = 1; });
        _loadAll();
      });
    }
    if (_aScheduled.isNotEmpty) {
      addChip('일정등록', _aScheduled == 'Y' ? '등록됨' : '미등록', () {
        _pScheduled = ''; _aScheduled = ''; _page = 1;
        _loadAll();
      });
    }
    if (_aSchedWeek.isNotEmpty) {
      addChip('수검일정', _aSchedWeek, () {
        setState(() { _pSchedWeek = ''; _aSchedWeek = ''; _page = 1; });
        _loadAll();
      });
    }
    return Wrap(spacing: 6, runSpacing: 4, children: chips);
  }

  // ── 데이터 탭 ─────────────────────────────────────────

  Widget _buildDataTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('오류: $_error', style: const TextStyle(color: Colors.red)));
    if (_items.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.search_off_rounded, size: 40, color: Colors.grey.shade300),
          const SizedBox(height: 8),
          Text('$_year년 $_sheet 데이터 없음',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 14)),
          const SizedBox(height: 4),
          Text(_hasActiveFilters ? '필터 조건을 변경하거나 초기화하세요' : '관리자 패널에서 KCA 파일을 Import하세요',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
        ]),
      );
    }

    // 체크 가능한 항목: 권한 있는 모든 항목 (배정 여부 무관)
    final checkableItems = _isAdmin
        ? _items.where((item) {
            final no = '${item['허가번호'] ?? ''}';
            return no.isNotEmpty && _canManageItem(item);
          }).toList()
        : <Map<String, dynamic>>[];

    final allChecked = checkableItems.isNotEmpty &&
        checkableItems.every((item) => _selectedLicenseNos.contains('${item['허가번호'] ?? ''}'));
    final someChecked = !allChecked &&
        checkableItems.any((item) => _selectedLicenseNos.contains('${item['허가번호'] ?? ''}'));

    final headerStyle = TextStyle(
      fontSize: 12, fontWeight: FontWeight.w700, color: Colors.black87,
    );
    const cellStyle = TextStyle(fontSize: 12, color: Color(0xFF374151));

    return Column(children: [
      Expanded(
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E7EB)),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Scrollbar(
              controller: _horizontalScrollCtrl,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _horizontalScrollCtrl,
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: DataTable(
                    sortColumnIndex: _sortColIdx,
                    sortAscending: _sortAsc,
                    headingRowColor: WidgetStateProperty.all(_primary.withValues(alpha: 0.12)),
                    headingRowHeight: 44,
                    dataRowMinHeight: 42,
                    dataRowMaxHeight: 46,
                    columnSpacing: 20,
                    horizontalMargin: 16,
                    showCheckboxColumn: false,
                    dividerThickness: 1,
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
                    ),
                    columns: [
                      DataColumn(label: _isAdmin
                          ? Checkbox(
                              value: someChecked ? null : allChecked,
                              tristate: true,
                              activeColor: _primary,
                              onChanged: checkableItems.isEmpty ? null : (v) {
                                setState(() {
                                  if (v == true) {
                                    for (final item in checkableItems) {
                                      final no = '${item['허가번호'] ?? ''}';
                                      if (no.isNotEmpty) _selectedLicenseNos.add(no);
                                    }
                                  } else {
                                    for (final item in checkableItems) {
                                      _selectedLicenseNos.remove('${item['허가번호'] ?? ''}');
                                    }
                                  }
                                });
                              },
                            )
                          : const SizedBox(width: 24)),
                      DataColumn(label: Text('수검일정', style: headerStyle), onSort: (i, a) => _onScheduleSort(1, a)),
                      DataColumn(label: Text('허가번호', style: headerStyle), onSort: (i, a) => _onScheduleSort(2, a)),
                      DataColumn(label: Text('호출명칭', style: headerStyle), onSort: (i, a) => _onScheduleSort(3, a)),
                      DataColumn(label: Text('국종군', style: headerStyle), onSort: (i, a) => _onScheduleSort(4, a)),
                      DataColumn(label: Text('KCA부서', style: headerStyle), onSort: (i, a) => _onScheduleSort(5, a)),
                      DataColumn(label: Text('연도주기', style: headerStyle), onSort: (i, a) => _onScheduleSort(6, a)),
                      DataColumn(label: Text('설치장소', style: headerStyle), onSort: (i, a) => _onScheduleSort(7, a)),
                      DataColumn(label: Text('도로명주소', style: headerStyle), onSort: (i, a) => _onScheduleSort(8, a)),
                      DataColumn(label: Text('장치수', style: headerStyle), onSort: (i, a) => _onScheduleSort(9, a)),
                      DataColumn(label: Text('통시', style: headerStyle), onSort: (i, a) => _onScheduleSort(10, a)),
                      DataColumn(label: Text('공대', style: headerStyle), onSort: (i, a) => _onScheduleSort(11, a)),
                      DataColumn(label: Text('활용구분', style: headerStyle), onSort: (i, a) => _onScheduleSort(12, a)),
                      DataColumn(label: Text('시기조정', style: headerStyle), onSort: (i, a) => _onScheduleSort(13, a)),
                      DataColumn(label: Text('기준연도', style: headerStyle), onSort: (i, a) => _onScheduleSort(14, a)),
                      DataColumn(label: Text('SKT본부', style: headerStyle), onSort: (i, a) => _onScheduleSort(15, a)),
                      DataColumn(label: Text('Access담당', style: headerStyle), onSort: (i, a) => _onScheduleSort(16, a)),
                      DataColumn(label: Text('품질개선팀', style: headerStyle), onSort: (i, a) => _onScheduleSort(17, a)),
                      DataColumn(label: Text('검사결과', style: headerStyle), onSort: (i, a) => _onScheduleSort(18, a)),
                    ],
                    rows: _items.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final item = entry.value;
                      final licenseNo = '${item['허가번호'] ?? ''}';
                      final isSelected = _detailLicenseNo == licenseNo;
                      final isChecked = _selectedLicenseNos.contains(licenseNo);
                      return DataRow(
                        selected: isSelected,
                        color: WidgetStateProperty.resolveWith((states) {
                          if (states.contains(WidgetState.selected)) return _primary.withValues(alpha: 0.06);
                          if (idx.isEven) return const Color(0xFFFAFAFB);
                          return Colors.white;
                        }),
                        onSelectChanged: (_) => _loadDetail(licenseNo),
                        cells: [
                          DataCell(_buildRowCheckbox(item, licenseNo, isChecked)),
                          DataCell(Text(_scheduleWeekMap[licenseNo] ?? '', style: cellStyle)),
                          DataCell(Text(licenseNo, style: cellStyle)),
                          DataCell(SizedBox(width: 180, child: Text('${item['호출명칭'] ?? ''}', style: cellStyle.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis))),
                          DataCell(Text('${item['국종군'] ?? ''}', style: cellStyle)),
                          DataCell(Text((item['부서'] as String? ?? '').replaceFirst(RegExp(r'^\d+\.\s*'), ''), style: cellStyle)),
                          DataCell(Text('${item['연도주기'] ?? ''}', style: cellStyle)),
                          DataCell(SizedBox(width: 160, child: Text('${item['설치장소'] ?? ''}', style: cellStyle, overflow: TextOverflow.ellipsis))),
                          DataCell(SizedBox(width: 180, child: Text('${item['도로명주소'] ?? ''}', style: cellStyle, overflow: TextOverflow.ellipsis))),
                          DataCell(Text('${item['장치수'] ?? ''}', style: cellStyle)),
                          DataCell(Text('${item['통시'] ?? ''}', style: cellStyle)),
                          DataCell(Text('${item['공대'] ?? ''}', style: cellStyle)),
                          DataCell(Text('${item['zpprac1'] ?? ''}', style: cellStyle)),
                          DataCell(Text('${item['시기조정'] ?? ''}', style: cellStyle)),
                          DataCell(Text('${item['기준연도'] ?? ''}', style: cellStyle)),
                          DataCell(Text('${item['skt본부'] ?? ''}', style: cellStyle)),
                          DataCell(Text('${item['access담당'] ?? ''}', style: cellStyle)),
                          DataCell(Text('${item['품질개선팀'] ?? ''}', style: cellStyle)),
                          DataCell(_buildResultChip('${item['검사결과'] ?? ''}')),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      _buildPagination(),
    ]);
  }

  Widget _buildRowCheckbox(Map<String, dynamic> item, String licenseNo, bool isChecked) {
    // member: 체크박스 미표시
    if (!_isAdmin) return const SizedBox(width: 24);

    // 본부관리자: 본인 본부 외 항목 비활성화
    if (!_canManageItem(item)) {
      return Tooltip(
        message: '다른 본부의 국소입니다',
        child: Checkbox(value: false, activeColor: _primary, onChanged: null),
      );
    }

    // 이미 일정 등록된 항목: 파란 체크박스 (체크 가능, 수정/제거 대상 선택용)
    final color = _isScheduled(licenseNo) ? _blue : _primary;
    return Checkbox(
      value: isChecked,
      activeColor: color,
      side: BorderSide(color: color.withValues(alpha: 0.6), width: 1.5),
      onChanged: (v) {
        setState(() {
          if (v == true) { _selectedLicenseNos.add(licenseNo); }
          else { _selectedLicenseNos.remove(licenseNo); }
        });
      },
    );
  }

  Widget _buildStatusChip(String val) {
    if (val.isEmpty) return const SizedBox.shrink();
    Color color = Colors.grey;
    IconData icon = Icons.circle;
    if (val.contains('허가')) { color = _green; icon = Icons.check_circle_outline; }
    else if (val.contains('취소') || val.contains('폐지')) { color = _primary; icon = Icons.cancel_outlined; }
    else if (val.contains('정지')) { color = _orange; icon = Icons.warning_amber; }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 4),
      Text(val, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500)),
    ]);
  }

  Widget _buildKcaChip(String val) {
    Color color = Colors.grey;
    if (val.contains('대상')) { color = _green; }
    else if (val.contains('진행')) { color = _blue; }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Text(val, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildResultChip(String val) {
    if (val.isEmpty) return const SizedBox.shrink();
    Color color;
    if (val == '합격') { color = _green; }
    else if (val.startsWith('불합격')) { color = _primary; }
    else if (val.startsWith('부적합')) { color = _orange; }
    else { color = Colors.grey; }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Text(val, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _buildPagination() {
    final totalPages = (_total / 100).ceil();
    if (totalPages <= 1) return const SizedBox(height: 12);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '${_formatNumber((_page - 1) * 100 + 1)}-${_formatNumber((_page * 100).clamp(0, _total))} / ${_formatNumber(_total)}',
            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
          ),
          Row(children: [
            _paginationButton(Icons.chevron_left, _page > 1, () { setState(() => _page--); _loadData(); }),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text('$_page / $totalPages', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
            ),
            const SizedBox(width: 4),
            _paginationButton(Icons.chevron_right, _page < totalPages, () { setState(() => _page++); _loadData(); }),
          ]),
        ],
      ),
    );
  }

  Widget _paginationButton(IconData icon, bool enabled, VoidCallback onTap) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: enabled ? Colors.white : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: enabled ? const Color(0xFFD1D5DB) : const Color(0xFFE5E7EB)),
        ),
        child: Icon(icon, size: 18, color: enabled ? const Color(0xFF374151) : const Color(0xFFD1D5DB)),
      ),
    );
  }

  // ── 매트릭스 탭 ──────────────────────────────────────

  Widget _buildMatrixTab() {
    // 매트릭스 필터 적용: 본부/팀 기준으로 클라이언트 필터
    final filteredMatrix = <String, dynamic>{};
    _matrix.forEach((hdqt, teamMapRaw) {
      if (_mHdqt.isNotEmpty && hdqt != _mHdqt) return;
      final teamMap = teamMapRaw as Map<String, dynamic>? ?? {};
      if (_mTeam.isNotEmpty) {
        if (!teamMap.containsKey(_mTeam)) return;
        filteredMatrix[hdqt] = {_mTeam: teamMap[_mTeam]};
      } else {
        filteredMatrix[hdqt] = teamMap;
      }
    });

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (filteredMatrix.isEmpty && _matrix.isEmpty) {
      return const Center(child: Text('데이터 없음', style: TextStyle(color: Colors.black38)));
    }

    final hdqts = filteredMatrix.keys.toList()..sort();
    final rows = <TableRow>[];

    rows.add(TableRow(
      decoration: BoxDecoration(color: Colors.grey.shade100),
      children: [
        _matrixCell('본부', isHeader: true),
        _matrixCell('팀', isHeader: true),
        ..._quarters.map((q) => _matrixCell(q, isHeader: true)),
        _matrixCell('합계', isHeader: true),
      ],
    ));

    for (final hdqt in hdqts) {
      final teamMap = filteredMatrix[hdqt] as Map<String, dynamic>? ?? {};
      final teams = teamMap.keys.toList()..sort();
      final hdqtTotal = _quarters.fold<int>(0, (s, q) =>
          s + teams.fold<int>(0, (s2, t) => s2 + (((teamMap[t] as Map?)?.containsKey(q) == true ? (teamMap[t] as Map)[q] : 0) as num).toInt()));

      for (var i = 0; i < teams.length; i++) {
        final team = teams[i];
        final teamData = teamMap[team] as Map<String, dynamic>? ?? {};
        final teamTotal = _quarters.fold<int>(0, (s, q) => s + ((teamData[q] as num?)?.toInt() ?? 0));
        rows.add(TableRow(
          decoration: i == 0 ? BoxDecoration(color: _primary.withValues(alpha: 0.04)) : null,
          children: [
            i == 0 ? _matrixCell(hdqt, isHdqt: true) : _matrixCell(''),
            _matrixCell(team, isTeam: true),
            ..._quarters.map((q) => _matrixCell('${(teamData[q] as num?)?.toInt() ?? 0}')),
            _matrixCell('$teamTotal', isBold: true),
          ],
        ));
      }

      rows.add(TableRow(
        decoration: BoxDecoration(color: Colors.grey.shade50),
        children: [
          _matrixCell('소계', isBold: true),
          _matrixCell(''),
          ..._quarters.map((q) {
            final cnt = teams.fold<int>(0, (s, t) =>
                s + (((teamMap[t] as Map?)?.containsKey(q) == true ? (teamMap[t] as Map)[q] : 0) as num).toInt());
            return _matrixCell('$cnt', isBold: true);
          }),
          _matrixCell('$hdqtTotal', isBold: true),
        ],
      ));
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 미배정 배너
          if (_unassignedTotal > 0) ...[
            _buildUnassignedBanner(),
            const SizedBox(height: 16),
          ],
          // 수검일정별 현황 카드 (필터 적용)
          if (_schedules.isNotEmpty) ...[
            _buildScheduleStatusSection(),
            const SizedBox(height: 16),
          ],
          // 매트릭스 테이블
          if (rows.length > 1)
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE5E7EB)),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Table(
                  border: TableBorder.all(color: const Color(0xFFE5E7EB)),
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  children: rows,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── 수검일정별 현황 (본부/팀별) ────────────────────────────

  /// 매트릭스 카드에서 건수 클릭 시 수검 대상 현황 탭으로 전환하며 필터 적용
  void _navigateToDataTabWithFilter({required String week, String hdqt = '', String team = ''}) {
    setState(() {
      // 수검일정 필터 (pending/applied 동기화)
      _pSchedWeek = week; _aSchedWeek = week;
      // 일정등록 여부 필터
      _pScheduled = 'Y'; _aScheduled = 'Y';
      // 본부 필터
      final validHdqt = hdqt.isNotEmpty && hdqt != '미지정' ? hdqt : '';
      _pHdqt = validHdqt; _aHdqt = validHdqt;
      _currentTeams = validHdqt.isNotEmpty ? (_orgMap[validHdqt] ?? []) : [];
      // 팀 필터
      final validTeam = team.isNotEmpty && team != '미지정' ? team : '';
      _pTeam = validTeam; _aTeam = validTeam;
      _page = 1;
    });
    _tabCtrl.animateTo(1);
    _loadAll();
  }

  Widget _buildScheduleStatusSection() {
    // 매트릭스 필터 적용: 본부/팀/주차
    final filteredSchedules = _schedules.where((s) {
      final week = (s['수검예정주차'] as String? ?? '').trim();
      final hdqt = (s['access담당'] as String? ?? '').trim();
      final team = (s['품질개선팀'] as String? ?? '').trim();
      if (_mWeek.isNotEmpty && week != _mWeek) return false;
      if (_mHdqt.isNotEmpty && hdqt != _mHdqt) return false;
      if (_mTeam.isNotEmpty && team != _mTeam) return false;
      return week.isNotEmpty;
    }).toList();

    // 수검예정주차 → (본부 또는 팀) → 건수
    // 본부 필터가 걸린 경우 팀별로, 아닌 경우 본부별로 집계
    final groupByTeam = _mHdqt.isNotEmpty;
    final weekMap = <String, Map<String, int>>{};
    for (final s in filteredSchedules) {
      final week = (s['수검예정주차'] as String? ?? '').trim();
      final groupVal = groupByTeam
          ? (s['품질개선팀'] as String? ?? '').trim()
          : (s['access담당'] as String? ?? '').trim();
      final groupKey = groupVal.isEmpty ? '미지정' : groupVal;
      weekMap.putIfAbsent(week, () => {});
      weekMap[week]![groupKey] = (weekMap[week]![groupKey] ?? 0) + 1;
    }

    // 주차 정렬
    final weeks = weekMap.keys.toList()
      ..sort((a, b) {
        final na = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        final nb = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        return na.compareTo(nb);
      });

    final totalFiltered = filteredSchedules.length;

    // 월별 그룹화
    String extractMonth(String week) {
      final m = RegExp(r'(\d+)월').firstMatch(week);
      return m != null ? '${m.group(1)}월' : '기타';
    }

    final monthGroups = <String, List<String>>{};
    for (final week in weeks) {
      monthGroups.putIfAbsent(extractMonth(week), () => []).add(week);
    }
    final allMonths = monthGroups.keys.toList()
      ..sort((a, b) {
        final na = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        final nb = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
        return na.compareTo(nb);
      });

    // 표시 모드 결정
    // _mMonth == ''    → 네비게이션 모드 (_navMonth 기준 현재 달만)
    // _mMonth == '전체' → 전체 달 표시 (그룹 헤더 포함)
    // _mMonth == 'N월' → 해당 달만 표시 (네비게이션 없음)
    final isNavMode = _mMonth.isEmpty;
    final isAllMode = _mMonth == '전체';

    final months = isAllMode
        ? allMonths
        : isNavMode
            ? allMonths.where((m) {
                final n = int.tryParse(m.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
                return n == _navMonth;
              }).toList()
            : allMonths.where((m) => m == _mMonth).toList();

    // 오늘 기준 현재 주차 레이블 (M월 N주차)
    final now = DateTime.now();
    final currentWeekLabel = '${now.month}월 ${((now.day - 1) ~/ 7) + 1}주차';

    // 네비게이션 모드에서 이전/다음 달 계산
    final prevMonth = _navMonth > 1 ? _navMonth - 1 : 12;
    final nextMonth = _navMonth < 12 ? _navMonth + 1 : 1;
    // 이전/다음달 버튼은 데이터 유무와 무관하게 달 번호 범위로만 판단
    const hasPrev = true;
    const hasNext = true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 타이틀 행
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Container(
                width: 3, height: 16,
                decoration: BoxDecoration(color: _primary, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 8),
              const Text(
                '수검일정별 현황',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: _primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$totalFiltered건',
                  style: TextStyle(fontSize: 11, color: _primary, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '건수 클릭 시 해당 조건으로 이동',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ],
          ),
        ),

        // 네비게이션 바 (기본 모드에서만)
        if (isNavMode)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                // 이전달 버튼
                _NavButton(
                  label: '이전달',
                  icon: Icons.chevron_left,
                  enabled: hasPrev,
                  onTap: hasPrev ? () => setState(() => _navMonth = prevMonth) : null,
                ),
                const SizedBox(width: 8),
                // 현재 표시 달
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  decoration: BoxDecoration(
                    color: _navMonth == now.month
                        ? _blue.withValues(alpha: 0.1)
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _navMonth == now.month
                          ? _blue.withValues(alpha: 0.4)
                          : Colors.grey.shade300,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_navMonth == now.month) ...[
                        Container(
                          width: 6, height: 6,
                          decoration: BoxDecoration(color: _blue, shape: BoxShape.circle),
                        ),
                        const SizedBox(width: 5),
                      ],
                      Text(
                        '$_navMonth월',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: _navMonth == now.month ? _blue : Colors.black87,
                        ),
                      ),
                      if (months.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          '${months.fold<int>(0, (s, mo) => s + (monthGroups[mo]?.fold<int>(0, (a, w) => a + (weekMap[w]?.values.fold<int>(0, (x, y) => x + y) ?? 0)) ?? 0))}건',
                          style: TextStyle(fontSize: 11, color: _navMonth == now.month ? _blue : Colors.grey.shade600),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // 다음달 버튼
                _NavButton(
                  label: '다음달',
                  icon: Icons.chevron_right,
                  iconRight: true,
                  enabled: hasNext,
                  onTap: hasNext ? () => setState(() => _navMonth = nextMonth) : null,
                ),
              ],
            ),
          ),

        // 카드 영역
        if (months.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              weeks.isNotEmpty
                  ? '$_navMonth월에 등록된 일정이 없습니다.'
                  : '조건에 맞는 일정이 없습니다.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: months.map((month) {
              final monthWeeks = monthGroups[month]!;
              final monthTotal = monthWeeks.fold<int>(0, (s, w) =>
                  s + (weekMap[w]?.values.fold<int>(0, (a, b) => a + b) ?? 0));
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 전체 달 표시 모드에서만 월 그룹 헤더 표시
                    if (isAllMode)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: _primary.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: _primary.withValues(alpha: 0.2)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.calendar_month_outlined, size: 14, color: _primary),
                                  const SizedBox(width: 5),
                                  Text(month,
                                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _primary)),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(color: _primary, borderRadius: BorderRadius.circular(8)),
                                    child: Text('$monthTotal건',
                                        style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(child: Container(height: 1, color: const Color(0xFFE5E7EB))),
                          ],
                        ),
                      ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: monthWeeks.map((week) => _buildWeekCard(
                        week, weekMap[week]!,
                        isCurrentWeek: week == currentWeekLabel,
                        groupByTeam: groupByTeam,
                      )).toList(),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildWeekCard(String week, Map<String, int> hdqtData, {bool isCurrentWeek = false, bool groupByTeam = false}) {
    final totalCount = hdqtData.values.fold<int>(0, (s, c) => s + c);
    final hdqts = hdqtData.keys.toList()..sort();

    // 현재 주차 강조 색상
    const accentColor = Color(0xFF0D47A1);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: 200,
          decoration: BoxDecoration(
            color: isCurrentWeek ? const Color(0xFFF0F4FF) : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isCurrentWeek ? accentColor.withValues(alpha: 0.6) : const Color(0xFFE5E7EB),
              width: isCurrentWeek ? 1.8 : 1,
            ),
            boxShadow: isCurrentWeek
                ? [BoxShadow(color: accentColor.withValues(alpha: 0.15), blurRadius: 12, offset: const Offset(0, 4))]
                : [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 카드 헤더
              InkWell(
                onTap: () => _navigateToDataTabWithFilter(
                  week: week,
                  hdqt: groupByTeam ? _mHdqt : '',
                ),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isCurrentWeek
                        ? accentColor.withValues(alpha: 0.12)
                        : _blue.withValues(alpha: 0.08),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                    border: Border(bottom: BorderSide(
                      color: isCurrentWeek
                          ? accentColor.withValues(alpha: 0.25)
                          : _blue.withValues(alpha: 0.15),
                    )),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isCurrentWeek ? Icons.today : Icons.calendar_today_outlined,
                        size: 14,
                        color: isCurrentWeek ? accentColor : _blue,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          week,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: isCurrentWeek ? accentColor : _blue,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: isCurrentWeek ? accentColor : _blue,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$totalCount건',
                          style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // 본부별/팀별 목록
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: hdqts.map((hdqt) => InkWell(
                    onTap: () => groupByTeam
                        ? _navigateToDataTabWithFilter(week: week, hdqt: _mHdqt, team: hdqt)
                        : _navigateToDataTabWithFilter(week: week, hdqt: hdqt),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                      child: Row(
                        children: [
                          Container(
                            width: 6, height: 6,
                            decoration: BoxDecoration(
                              color: isCurrentWeek ? accentColor : _primary,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(hdqt,
                                style: const TextStyle(fontSize: 12, color: Color(0xFF374151))),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: isCurrentWeek
                                  ? accentColor.withValues(alpha: 0.08)
                                  : _primary.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${hdqtData[hdqt]}건',
                              style: TextStyle(
                                fontSize: 12,
                                color: isCurrentWeek ? accentColor : _primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 2),
                          Icon(Icons.arrow_forward_ios, size: 10, color: Colors.grey.shade400),
                        ],
                      ),
                    ),
                  )).toList(),
                ),
              ),
            ],
          ),
        ),
        // 현재 주차 배지
        if (isCurrentWeek)
          Positioned(
            top: -8,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: accentColor,
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [BoxShadow(color: accentColor.withValues(alpha: 0.4), blurRadius: 4, offset: const Offset(0, 2))],
                ),
                child: const Text(
                  '이번 주',
                  style: TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _reasonChip(String label, dynamic count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text('$label $count건', style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500)),
    );
  }

  Widget _buildUnassignedBanner() {
    final regionEntries = _unassignedByRegion.entries.toList();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _orange.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _orange.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(Icons.warning_amber_rounded, size: 18, color: _orange),
              ),
              const SizedBox(width: 10),
              Text('미배정 $_unassignedTotal건',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _orange)),
              const SizedBox(width: 8),
              Text('본부/팀이 매핑되지 않은 항목', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              if (_unassignedByReason.isNotEmpty) ...[
                const SizedBox(width: 12),
                _reasonChip('코드없음', _unassignedByReason['코드없음'] ?? 0, const Color(0xFF6B7280)),
                const SizedBox(width: 4),
                _reasonChip('ERP미매칭', _unassignedByReason['ERP미매칭'] ?? 0, const Color(0xFFDC2626)),
              ],
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.list_alt, size: 16),
                label: const Text('상세보기', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(foregroundColor: _orange),
                onPressed: () => _showUnassignedDialog(),
              ),
            ],
          ),
          if (regionEntries.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: regionEntries.take(10).map((e) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7ED),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _orange.withValues(alpha: 0.2)),
                ),
                child: Text('${e.key}  ${e.value}건',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF92400E))),
              )).toList(),
            ),
          ],
        ],
      ),
    );
  }

  void _showUnassignedDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Icon(Icons.warning_amber_rounded, color: _orange, size: 22),
          const SizedBox(width: 8),
          Text('미배정 항목 ($_unassignedTotal건)',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ]),
        content: SizedBox(
          width: 700,
          height: 500,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 지역별 요약
              if (_unassignedByRegion.isNotEmpty) ...[
                const Text('지역별 분포', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: _unassignedByRegion.entries.map((e) => Chip(
                        label: Text('${e.key}: ${e.value}건', style: const TextStyle(fontSize: 11)),
                        backgroundColor: const Color(0xFFFFF7ED),
                        side: BorderSide(color: _orange.withValues(alpha: 0.2)),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      )).toList(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 8),
              ],
              // 상세 목록
              Row(children: [
                Text('상세 목록 (${_unassignedItems.length}건 표시)', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                if (_unassignedCapped) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(4)),
                    child: Text('전체 $_unassignedTotal건 중 500건만 표시 (Excel 다운로드로 전체 확인)',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF92400E))),
                  ),
                ],
              ]),
              const SizedBox(height: 8),
              Expanded(
                child: SingleChildScrollView(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      headingRowColor: WidgetStateProperty.all(const Color(0xFFF9FAFB)),
                      headingRowHeight: 38,
                      dataRowMinHeight: 36,
                      dataRowMaxHeight: 40,
                      columnSpacing: 16,
                      columns: const [
                        DataColumn(label: Text('미배정원인', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                        DataColumn(label: Text('허가번호', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                        DataColumn(label: Text('호출명칭', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                        DataColumn(label: Text('도로명주소', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                        DataColumn(label: Text('국종군', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                        DataColumn(label: Text('분기', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                        DataColumn(label: Text('통시', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
                      ],
                      rows: _unassignedItems.map((item) {
                        final reason = item['미배정원인'] as String? ?? '';
                        final isErp = reason == 'ERP미매칭';
                        return DataRow(cells: [
                          DataCell(Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: isErp ? const Color(0xFFFEE2E2) : const Color(0xFFF3F4F6),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(reason,
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500,
                                    color: isErp ? const Color(0xFFDC2626) : const Color(0xFF6B7280))),
                          )),
                          DataCell(Text('${item['허가번호'] ?? ''}', style: const TextStyle(fontSize: 11))),
                          DataCell(SizedBox(width: 150, child: Text('${item['호출명칭'] ?? ''}', style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis))),
                          DataCell(SizedBox(width: 200, child: Text('${item['도로명주소'] ?? ''}', style: const TextStyle(fontSize: 11), overflow: TextOverflow.ellipsis))),
                          DataCell(Text('${item['국종군'] ?? ''}', style: const TextStyle(fontSize: 11))),
                          DataCell(Text('${item['분기'] ?? ''}', style: const TextStyle(fontSize: 11))),
                          DataCell(Text('${item['통시'] ?? ''}', style: const TextStyle(fontSize: 11))),
                        ]);
                      }).toList(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  Widget _matrixCell(String text,
      {bool isHeader = false, bool isHdqt = false, bool isTeam = false, bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: (isHeader || isBold || isHdqt) ? FontWeight.w600 : FontWeight.normal,
          color: isHeader ? Colors.black54 : isHdqt ? _primary : Colors.black87,
        ),
        textAlign: (isHdqt || isTeam) ? TextAlign.left : TextAlign.center,
      ),
    );
  }

  // ── 상세 패널 ─────────────────────────────────────────

  Widget _buildDetailPanel() {
    return Container(
      width: 380,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: const Color(0xFFE5E7EB))),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 16, offset: const Offset(-4, 0))],
      ),
      child: _detailLoading
          ? const Center(child: CircularProgressIndicator())
          : _detailData == null
              ? const Center(child: Text('데이터 없음', style: TextStyle(color: Colors.black38)))
              : _buildDetailContent(),
    );
  }

  Widget _buildDetailContent() {
    final d = _detailData!;
    final target = d['target'] as Map<String, dynamic>?;
    final ds = d['ds'] as Map<String, dynamic>?;
    final schedule = d['schedule'] as Map<String, dynamic>?;
    final result = d['result'] as Map<String, dynamic>?;

    final dsGeneral = ds?['일반사항'] as Map<String, dynamic>?;
    final dsDevices = List<Map<String, dynamic>>.from(ds?['장치'] ?? []);
    final dsAntennas = List<Map<String, dynamic>>.from(ds?['안테나'] ?? []);

    final callname = (target?['호출명칭'] ?? dsGeneral?['호출명칭'] ?? '') as String;
    final stationName = (dsGeneral?['무선국명'] ?? '') as String;
    final licenseNo = (target?['허가번호'] ?? '') as String;
    final location = (target?['도로명주소'] ?? target?['설치장소'] ?? '') as String;
    final kisuList = dsAntennas.map((a) => a['기'] ?? '').where((v) => v.toString().isNotEmpty).map((v) => v.toString()).toSet().toList();
    final gainList = dsAntennas.map((a) => a['이득'] ?? '').where((v) => v.toString().isNotEmpty).map((v) => v.toString()).toSet().toList();
    final installTypeSet = dsAntennas.map((a) => a['공중선주설치형태명'] ?? '').where((v) => v.toString().isNotEmpty).toSet();
    final serialList = dsDevices.map((dv) => dv['기기일련번호'] ?? '').where((v) => v.toString().isNotEmpty).map((v) => v.toString()).toSet().toList();
    final callnameList = List<Map<String, dynamic>>.from(d['callname_list'] ?? []);
    // eqp_ser_no(zpcname) 형식으로 조합, 중복 제거
    final facilityNames = callnameList
        .where((e) => (e['zpcname'] as String? ?? '').isNotEmpty)
        .map((e) {
          final ser = (e['eqp_ser_no'] as String? ?? '').trim();
          final name = (e['zpcname'] as String? ?? '').trim();
          return ser.isNotEmpty ? '$ser($name)' : name;
        })
        .toSet()
        .toList();

    final statusColor = result == null ? Colors.grey
        : result['status'] == '합격' ? _green
        : (result['status'] as String? ?? '').startsWith('불합격') ? _primary
        : (result['status'] as String? ?? '').startsWith('부적합') ? _orange
        : Colors.grey;
    final statusText = result?['status'] ?? '검사대기';

    return Column(children: [
      Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(callname, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              if (stationName.isNotEmpty && stationName != callname)
                Text(stationName, style: const TextStyle(fontSize: 11, color: Colors.black45)),
              if (schedule != null) ...[
                const SizedBox(height: 4),
                _scheduleTag(schedule),
              ],
            ]),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8)),
            child: Text(statusText, style: TextStyle(fontSize: 12, color: statusColor, fontWeight: FontWeight.w600)),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () => setState(() { _detailData = null; _detailLicenseNo = null; }),
          ),
        ]),
      ),
      Divider(height: 1, color: Colors.grey.shade100),
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _sectionHeader('기본 정보', Icons.info_outline, _primary),
            _infoRow('허가번호', licenseNo),
            _infoRow('설치장소', location),
            _infoRow('호출명칭', callname),
            if (facilityNames.isNotEmpty || serialList.isNotEmpty) _infoRow(
              '일련번호 및 통합시설명칭',
              facilityNames.isNotEmpty
                  ? facilityNames.join('\n')
                  : serialList.join('\n'),
            ),
            if (gainList.isNotEmpty) _infoRow('이득(dB)', gainList.join('  ')),
            if (kisuList.isNotEmpty) _infoRow('기수', kisuList.join('  ')),
            if (installTypeSet.isNotEmpty) _infoRow('설치대', installTypeSet.join(', ')),
            _infoRow('분기', target?['분기'] ?? ''),
            _infoRow('국종군', target?['국종군'] ?? ''),
            _infoRow('KCA검토결과', target?['kca검토결과'] ?? ''),

            const SizedBox(height: 16),
            _sectionHeader('수검 일정', Icons.calendar_month, _blue),
            if (schedule != null) ...[
              _infoRow('담당', '${target?['access담당'] ?? ''} / ${target?['품질개선팀'] ?? ''}'),
              _infoRow('예정주차', schedule['수검예정주차'] ?? ''),
              if ((schedule['조'] as String? ?? '').isNotEmpty)
                _infoRow('조', schedule['조'] ?? ''),
              if ((schedule['검사관'] as String? ?? '').isNotEmpty)
                _infoRow('검사관', schedule['검사관'] ?? ''),
              _infoRow('지역', schedule['지역'] ?? ''),
            ] else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('일정 미등록', style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
              ),
            if (_isAdmin)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: schedule != null
                    ? Row(children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.edit_calendar, size: 16),
                            label: const Text('일정 수정', style: TextStyle(fontSize: 13)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _blue,
                              side: BorderSide(color: _blue),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () => _showScheduleDialog({...?target, 'schedule': schedule}),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.delete_outline, size: 16),
                          label: const Text('제거', style: TextStyle(fontSize: 13)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _primary,
                            side: BorderSide(color: _primary),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () => _deleteScheduleConfirm(licenseNo, callname),
                        ),
                      ])
                    : OutlinedButton.icon(
                        icon: const Icon(Icons.edit_calendar, size: 16),
                        label: const Text('일정 등록', style: TextStyle(fontSize: 13)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: _blue,
                          side: BorderSide(color: _blue),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        onPressed: () => _showScheduleDialog({...?target, 'schedule': schedule}),
                      ),
              ),

            const SizedBox(height: 16),
            _sectionHeader('수검 결과', Icons.assignment_turned_in_outlined, _green),
            _buildResultSection(result, callname),

            if (_isAdmin) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('수검 관리 화면으로', style: TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () => Navigator.push(context, MaterialPageRoute(
                    builder: (_) => InspectionResultScreen(
                      year: _year,
                      licenseNo: licenseNo,
                      callname: callname,
                      initialData: d,
                    ),
                  )).then((_) { if (_detailLicenseNo != null) _loadDetail(_detailLicenseNo!); }),
                ),
              ),
            ],
          ]),
        ),
      ),
    ]);
  }

  Widget _scheduleTag(Map<String, dynamic> schedule) {
    final week = schedule['수검예정주차'] ?? '';
    final jo = schedule['조'] as String? ?? '';
    final label = [week, if (jo.isNotEmpty) jo].where((s) => s.isNotEmpty).join(' ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: _blue.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
      child: Text(label, style: TextStyle(fontSize: 11, color: _blue)),
    );
  }

  Widget _sectionHeader(String title, IconData icon, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _infoRow(String label, String value) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 90, child: Text(label, style: TextStyle(fontSize: 13, color: Colors.grey.shade600))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
      ]),
    );
  }

  Widget _buildResultSection(Map<String, dynamic>? result, String callname) {
    if (result == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('결과 미입력', style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
      );
    }

    // 사진 S3키 목록
    final rawPhotos = result['사진S3키'];
    final photoKeys = <String>[];
    if (rawPhotos is List) {
      for (final k in rawPhotos) {
        final s = k.toString();
        if (s.isNotEmpty) photoKeys.add(s);
      }
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _infoRow('상태', result['status'] ?? ''),
      _infoRow('검사일', result['검사일'] ?? ''),
      if ((result['입력자'] ?? '').isNotEmpty) _infoRow('입회자', result['입력자'] ?? ''),
      _infoRow('철탑형태', result['철탑형태'] ?? ''),
      if ((result['메모'] ?? '').isNotEmpty) _infoRow('특이사항', result['메모'] ?? ''),
      if (photoKeys.isNotEmpty) ...[
        const SizedBox(height: 10),
        Row(children: [
          Text('특이사항 사진',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          const Spacer(),
          if (photoKeys.length > 1)
            _ZipDownloadButton(
              photoKeys: photoKeys,
              callname: callname,
              svc: _svc,
            ),
        ]),
        const SizedBox(height: 8),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 1,
          ),
          itemCount: photoKeys.length,
          itemBuilder: (context, i) {
            final s3Key = photoKeys[i];
            return FutureBuilder<Uint8List>(
              future: _svc.getPhotoData(s3Key),
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
                final bytes = snap.data!;
                return GestureDetector(
                  onTap: () => _showPhotoViewer(context, photoKeys, bytes, i),
                  child: Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(bytes, fit: BoxFit.cover,
                          width: double.infinity, height: double.infinity),
                    ),
                    Positioned(
                      top: 4, right: 4,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: Colors.black45,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Icon(Icons.zoom_in, size: 14, color: Colors.white),
                      ),
                    ),
                  ]),
                );
              },
            );
          },
        ),
      ],
    ]);
  }

  void _showPhotoViewer(BuildContext context, List<String> photoKeys,
      Uint8List initialBytes, int initialIndex) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => _PhotoViewerDialog(
        photoKeys: photoKeys,
        initialBytes: initialBytes,
        initialIndex: initialIndex,
        svc: _svc,
      ),
    );
  }
}

// ── 사진 전체화면 뷰어 ─────────────────────────────────────

class _PhotoViewerDialog extends StatefulWidget {
  final List<String> photoKeys;
  final Uint8List initialBytes;
  final int initialIndex;
  final InspectionService svc;

  const _PhotoViewerDialog({
    required this.photoKeys,
    required this.initialBytes,
    required this.initialIndex,
    required this.svc,
  });

  @override
  State<_PhotoViewerDialog> createState() => _PhotoViewerDialogState();
}

class _PhotoViewerDialogState extends State<_PhotoViewerDialog> {
  late int _index;
  late Uint8List _bytes;
  bool _loading = false;
  final _transformCtrl = TransformationController();

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _bytes = widget.initialBytes;
  }

  @override
  void dispose() {
    _transformCtrl.dispose();
    super.dispose();
  }

  Future<void> _goto(int idx) async {
    if (idx < 0 || idx >= widget.photoKeys.length) return;
    setState(() { _loading = true; });
    try {
      final bytes = await widget.svc.getPhotoData(widget.photoKeys[idx]);
      _transformCtrl.value = Matrix4.identity();
      setState(() { _index = idx; _bytes = bytes; });
    } finally {
      setState(() { _loading = false; });
    }
  }

  void _download() {
    final ext = widget.photoKeys[_index].split('.').last.toLowerCase();
    final mime = ext == 'png' ? 'image/png' : 'image/jpeg';
    final fileName = 'photo_${_index + 1}.$ext';
    final blob = html.Blob([_bytes], mime);
    final url = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.photoKeys.length;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(12),
      child: Stack(children: [
        // 사진 (핀치/줌)
        Center(
          child: _loading
              ? const CircularProgressIndicator(color: Colors.white)
              : InteractiveViewer(
                  transformationController: _transformCtrl,
                  minScale: 0.5,
                  maxScale: 5.0,
                  child: Image.memory(_bytes, fit: BoxFit.contain),
                ),
        ),

        // 상단 바: 인덱스 + 닫기
        Positioned(
          top: 0, left: 0, right: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [Colors.black54, Colors.transparent],
              ),
            ),
            child: Row(children: [
              Text('${_index + 1} / $total',
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              const Spacer(),
              // 현재 사진 다운로드
              IconButton(
                icon: const Icon(Icons.download, color: Colors.white),
                tooltip: '다운로드',
                onPressed: _download,
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
          ),
        ),

        // 이전 버튼
        if (_index > 0)
          Positioned(
            left: 4, top: 0, bottom: 0,
            child: Center(
              child: IconButton(
                icon: const Icon(Icons.chevron_left, color: Colors.white, size: 36),
                onPressed: () => _goto(_index - 1),
              ),
            ),
          ),

        // 다음 버튼
        if (_index < total - 1)
          Positioned(
            right: 4, top: 0, bottom: 0,
            child: Center(
              child: IconButton(
                icon: const Icon(Icons.chevron_right, color: Colors.white, size: 36),
                onPressed: () => _goto(_index + 1),
              ),
            ),
          ),
      ]),
    );
  }
}

// ── ZIP 일괄 다운로드 버튼 ────────────────────────────────

class _ZipDownloadButton extends StatefulWidget {
  final List<String> photoKeys;
  final String callname;
  final InspectionService svc;

  const _ZipDownloadButton({
    required this.photoKeys,
    required this.callname,
    required this.svc,
  });

  @override
  State<_ZipDownloadButton> createState() => _ZipDownloadButtonState();
}

class _ZipDownloadButtonState extends State<_ZipDownloadButton> {
  bool _downloading = false;

  Future<void> _downloadZip() async {
    setState(() => _downloading = true);
    try {
      final archive = Archive();
      for (var i = 0; i < widget.photoKeys.length; i++) {
        final key = widget.photoKeys[i];
        final bytes = await widget.svc.getPhotoData(key);
        final ext = key.split('.').last.toLowerCase();
        archive.addFile(ArchiveFile('photo_${i + 1}.$ext', bytes.length, bytes));
      }
      final zipBytes = ZipEncoder().encode(archive)!;
      final safeName = widget.callname.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final blob = html.Blob([Uint8List.fromList(zipBytes)], 'application/zip');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)
        ..setAttribute('download', '$safeName.zip')
        ..click();
      html.Url.revokeObjectUrl(url);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _downloading ? null : _downloadZip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.blue.shade200),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _downloading
              ? SizedBox(
                  width: 12, height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.blue.shade600))
              : Icon(Icons.download, size: 13, color: Colors.blue.shade700),
          const SizedBox(width: 4),
          Text(
            _downloading ? '압축 중...' : 'ZIP 다운로드',
            style: TextStyle(
                fontSize: 12,
                color: Colors.blue.shade700,
                fontWeight: FontWeight.w500),
          ),
        ]),
      ),
    );
  }
}

class _MultiSelectDialog extends StatefulWidget {
  final String title;
  final List<String> options;
  final List<String> selected;
  const _MultiSelectDialog({required this.title, required this.options, required this.selected});

  @override
  State<_MultiSelectDialog> createState() => _MultiSelectDialogState();
}

class _MultiSelectDialogState extends State<_MultiSelectDialog> {
  late final List<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = List.from(widget.selected);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(widget.title,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      contentPadding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      content: SizedBox(
        width: 260,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // 전체 선택/해제
          CheckboxListTile(
            dense: true,
            title: const Text('전체', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            value: _selected.length == widget.options.length && widget.options.isNotEmpty
                ? true
                : _selected.isEmpty ? false : null,
            tristate: true,
            activeColor: const Color(0xFFE53935),
            onChanged: (v) => setState(() {
              if (v == true) { _selected
                ..clear()
                ..addAll(widget.options); }
              else { _selected.clear(); }
            }),
          ),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: ListView(
              shrinkWrap: true,
              children: widget.options.map((opt) => CheckboxListTile(
                dense: true,
                title: Text(opt, style: const TextStyle(fontSize: 13)),
                value: _selected.contains(opt),
                activeColor: const Color(0xFFE53935),
                onChanged: (v) => setState(() {
                  if (v == true) { _selected.add(opt); }
                  else { _selected.remove(opt); }
                }),
              )).toList(),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFE53935),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('적용'),
        ),
      ],
    );
  }
}

// ── 검사내역서 대상 선택 다이얼로그 ──────────────────────────

class _InspectionReportDialog extends StatefulWidget {
  final InspectionService svc;
  final int year;
  final Map<String, List<String>> orgMap;
  final List<String> hdqts;
  final List<String> allQuarters;
  final List<String> allNationGroups;
  final List<String> allKcaResults;
  final void Function(List<String> licenseNos, String sheetTitle) onConfirm;

  const _InspectionReportDialog({
    required this.svc,
    required this.year,
    required this.orgMap,
    required this.hdqts,
    required this.allQuarters,
    required this.allNationGroups,
    required this.allKcaResults,
    required this.onConfirm,
  });

  @override
  State<_InspectionReportDialog> createState() => _InspectionReportDialogState();
}

class _InspectionReportDialogState extends State<_InspectionReportDialog> {
  static const Color _blue = Color(0xFF1565C0);

  // 필터 상태
  String _hdqt = '', _team = '', _quarter = '', _nationGroup = '', _kcaResult = '';
  final _searchCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();

  // 목록 상태
  List<Map<String, dynamic>> _candidates = [];   // 좌측 후보 목록
  List<Map<String, dynamic>> _confirmed = [];    // 우측 선정 목록
  final _leftChecked = <String>{};   // 좌측 체크된 허가번호
  final _rightChecked = <String>{};  // 우측 체크된 허가번호
  bool _loading = false;
  int _total = 0;

  // 생성 상태
  bool _generating = false;

  List<String> get _teams =>
      _hdqt.isNotEmpty ? (widget.orgMap[_hdqt] ?? []) : [];

  @override
  void initState() {
    super.initState();
    _loadCandidates();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _titleCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCandidates() async {
    setState(() { _loading = true; _candidates = []; _leftChecked.clear(); });
    try {
      final filters = <String, List<String>>{};
      if (_hdqt.isNotEmpty) filters['access담당'] = [_hdqt];
      if (_team.isNotEmpty) filters['품질개선팀'] = [_team];
      if (_quarter.isNotEmpty) filters['분기'] = [_quarter];
      if (_nationGroup.isNotEmpty) filters['국종군'] = [_nationGroup];
      if (_kcaResult.isNotEmpty) filters['kca검토결과'] = [_kcaResult];

      final search = _searchCtrl.text.trim();
      final result = await widget.svc.getData(
        year: widget.year,
        filters: filters,
        search: search,
        addr: search,
        page: 1,
        pageSize: 500,
      );
      final items = List<Map<String, dynamic>>.from(result['items'] ?? []);
      // 이미 우측에 있는 항목 제외
      final confirmedNos = _confirmed.map((e) => e['허가번호'] as String).toSet();
      setState(() {
        _total = result['total'] as int? ?? 0;
        _candidates = items.where((e) => !confirmedNos.contains(e['허가번호'])).toList();
      });
    } catch (e) {
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _moveToRight() {
    if (_leftChecked.isEmpty) return;
    final moving = _candidates.where((e) => _leftChecked.contains(e['허가번호'])).toList();
    setState(() {
      _confirmed.addAll(moving);
      _candidates.removeWhere((e) => _leftChecked.contains(e['허가번호']));
      _leftChecked.clear();
    });
  }

  void _moveToLeft() {
    if (_rightChecked.isEmpty) return;
    final moving = _confirmed.where((e) => _rightChecked.contains(e['허가번호'])).toList();
    setState(() {
      _candidates.addAll(moving);
      _confirmed.removeWhere((e) => _rightChecked.contains(e['허가번호']));
      _rightChecked.clear();
    });
  }

  void _toggleLeft(String no) => setState(() {
    if (_leftChecked.contains(no)) _leftChecked.remove(no);
    else _leftChecked.add(no);
  });

  void _toggleRight(String no) => setState(() {
    if (_rightChecked.contains(no)) _rightChecked.remove(no);
    else _rightChecked.add(no);
  });

  void _selectAllLeft() => setState(() {
    if (_leftChecked.length == _candidates.length) {
      _leftChecked.clear();
    } else {
      _leftChecked.addAll(_candidates.map((e) => e['허가번호'] as String));
    }
  });

  void _selectAllRight() => setState(() {
    if (_rightChecked.length == _confirmed.length) {
      _rightChecked.clear();
    } else {
      _rightChecked.addAll(_confirmed.map((e) => e['허가번호'] as String));
    }
  });

  Widget _dropdown(String hint, String? value, List<String> items, ValueChanged<String?> onChanged) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true, isDense: true,
          hint: Text(hint, style: const TextStyle(fontSize: 12)),
          value: value?.isEmpty == true ? null : value,
          icon: const Icon(Icons.arrow_drop_down, size: 18),
          dropdownColor: Colors.white,

          borderRadius: BorderRadius.circular(12),
          style: const TextStyle(fontSize: 12, color: Colors.black87),
          items: [
            DropdownMenuItem(value: '', child: Text('전체', style: TextStyle(color: Colors.grey.shade500))),
            ...items.map((v) => DropdownMenuItem(value: v, child: Text(v))),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _itemTile(Map<String, dynamic> item, bool checked, VoidCallback onTap) {
    final no = item['허가번호'] as String? ?? '';
    final name = item['호출명칭'] as String? ?? '';
    final team = item['품질개선팀'] as String? ?? '';
    final quarter = item['분기'] as String? ?? '';
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: checked ? Colors.blue.shade50 : Colors.transparent,
          border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
        ),
        child: Row(children: [
          SizedBox(
            width: 20, height: 20,
            child: Checkbox(
              value: checked, onChanged: (_) => onTap(),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              activeColor: _blue,
              side: BorderSide(color: Colors.grey.shade400),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              Text('$no  $team  $quarter',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: SizedBox(
        width: screenSize.width * 0.85,
        height: screenSize.height * 0.85,
        child: Column(children: [
          // ── 헤더 ──
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
            decoration: BoxDecoration(
              color: _blue,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(children: [
              const Icon(Icons.assignment, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              const Text('검사내역서 대상 선택',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 20),
                onPressed: () => Navigator.pop(context),
                padding: EdgeInsets.zero, constraints: const BoxConstraints(),
              ),
            ]),
          ),

          // ── ① 필터 패널 ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.grey.shade50,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: _dropdown('본부', _hdqt, widget.hdqts, (v) {
                  setState(() { _hdqt = v ?? ''; _team = ''; });
                  _loadCandidates();
                })),
                const SizedBox(width: 8),
                Expanded(child: _dropdown('팀', _team, _teams, (v) {
                  setState(() => _team = v ?? '');
                  _loadCandidates();
                })),
                const SizedBox(width: 8),
                Expanded(child: _dropdown('분기', _quarter, widget.allQuarters, (v) {
                  setState(() => _quarter = v ?? '');
                  _loadCandidates();
                })),
                const SizedBox(width: 8),
                Expanded(child: _dropdown('밴드선택', _nationGroup, widget.allNationGroups, (v) {
                  setState(() => _nationGroup = v ?? '');
                  _loadCandidates();
                })),
                const SizedBox(width: 8),
                Expanded(child: _dropdown('검토여부', _kcaResult, widget.allKcaResults, (v) {
                  setState(() => _kcaResult = v ?? '');
                  _loadCandidates();
                })),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 34,
                    child: TextField(
                      controller: _searchCtrl,
                      decoration: InputDecoration(
                        hintText: '복수검색 가능 (쉼표/공백 구분)',
                        hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                        prefixIcon: const Icon(Icons.search, size: 16),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: Colors.grey.shade300)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: Colors.grey.shade300)),
                        contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 10),
                        isDense: true,
                        filled: true, fillColor: Colors.white,
                      ),
                      style: const TextStyle(fontSize: 12),
                      onSubmitted: (_) => _loadCandidates(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.search, size: 14),
                  label: const Text('검색', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _blue, foregroundColor: Colors.white,
                    minimumSize: const Size(70, 34),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  onPressed: _loadCandidates,
                ),
              ]),
            ]),
          ),
          const Divider(height: 1),

          // ── ② 좌측 목록  ↔  ③ 우측 목록 ──
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // 좌측: 후보 목록
              Expanded(
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    color: Colors.grey.shade100,
                    child: Row(children: [
                      GestureDetector(
                        onTap: _selectAllLeft,
                        child: Row(children: [
                          SizedBox(
                            width: 18, height: 18,
                            child: Checkbox(
                              value: _candidates.isNotEmpty &&
                                  _leftChecked.length == _candidates.length,
                              onChanged: (_) => _selectAllLeft(),
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              activeColor: _blue,
                              side: BorderSide(color: Colors.grey.shade400),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('후보 목록', style: TextStyle(fontSize: 12,
                              fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                        ]),
                      ),
                      const Spacer(),
                      if (_loading)
                        SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: _blue))
                      else
                        Text(
                          '${_candidates.length}건 표시 / 전체 $_total건',
                          style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                        ),
                    ]),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _candidates.isEmpty
                            ? Center(child: Text('결과 없음',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade400)))
                            : ListView.builder(
                                itemCount: _candidates.length,
                                itemBuilder: (_, i) {
                                  final item = _candidates[i];
                                  final no = item['허가번호'] as String? ?? '';
                                  return _itemTile(item, _leftChecked.contains(no),
                                      () => _toggleLeft(no));
                                },
                              ),
                  ),
                ]),
              ),

              // 중앙 화살표
              Container(
                width: 44,
                color: Colors.grey.shade50,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Tooltip(
                    message: '선정 목록으로 이동',
                    child: Material(
                      color: _leftChecked.isEmpty ? Colors.grey.shade300 : _blue,
                      borderRadius: BorderRadius.circular(6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: _leftChecked.isEmpty ? null : _moveToRight,
                        child: const SizedBox(
                          width: 32, height: 32,
                          child: Icon(Icons.arrow_forward, color: Colors.white, size: 16),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Tooltip(
                    message: '후보 목록으로 복원',
                    child: Material(
                      color: _rightChecked.isEmpty ? Colors.grey.shade300 : Colors.orange,
                      borderRadius: BorderRadius.circular(6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: _rightChecked.isEmpty ? null : _moveToLeft,
                        child: const SizedBox(
                          width: 32, height: 32,
                          child: Icon(Icons.arrow_back, color: Colors.white, size: 16),
                        ),
                      ),
                    ),
                  ),
                ]),
              ),

              const VerticalDivider(width: 1),

              // 우측: 선정 목록
              Expanded(
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    color: Colors.blue.shade50,
                    child: Row(children: [
                      GestureDetector(
                        onTap: _selectAllRight,
                        child: Row(children: [
                          SizedBox(
                            width: 18, height: 18,
                            child: Checkbox(
                              value: _confirmed.isNotEmpty &&
                                  _rightChecked.length == _confirmed.length,
                              onChanged: (_) => _selectAllRight(),
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              activeColor: Colors.orange,
                              side: BorderSide(color: Colors.grey.shade400),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('선정 목록', style: TextStyle(fontSize: 12,
                              fontWeight: FontWeight.w600, color: _blue)),
                        ]),
                      ),
                      const Spacer(),
                      Text('${_confirmed.length}건',
                          style: TextStyle(fontSize: 10, color: _blue,
                              fontWeight: FontWeight.w600)),
                    ]),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _confirmed.isEmpty
                        ? Center(child: Text('← 버튼으로 대상을 추가하세요',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade400)))
                        : ListView.builder(
                            itemCount: _confirmed.length,
                            itemBuilder: (_, i) {
                              final item = _confirmed[i];
                              final no = item['허가번호'] as String? ?? '';
                              return _itemTile(item, _rightChecked.contains(no),
                                  () => _toggleRight(no));
                            },
                          ),
                  ),
                ]),
              ),
            ]),
          ),

          const Divider(height: 1),

          // ── 하단: 시트 제목 + 버튼 ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              const Text('시트 제목', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: TextField(
                    controller: _titleCtrl,
                    decoration: InputDecoration(
                      hintText: '예: 남구_동대구(78)_김성욱',
                      hintStyle: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: Colors.grey.shade300)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide(color: Colors.grey.shade300)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              TextButton(
                onPressed: _generating ? null : () => Navigator.pop(context),
                child: const Text('취소'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                icon: _generating
                    ? const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.download, size: 16),
                label: Text(_generating ? '생성 중...' : '검사내역서 생성 (${_confirmed.length}건)',
                    style: const TextStyle(fontSize: 13)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _confirmed.isEmpty ? Colors.grey.shade400 : _blue,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(160, 38),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
                onPressed: (_confirmed.isEmpty || _generating) ? null : () {
                  widget.onConfirm(
                    _confirmed.map((e) => e['허가번호'] as String).toList(),
                    _titleCtrl.text.trim(),
                  );
                },
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── 대상 추가 선택 다이얼로그 ──────────────────────────

class _AddFromStagingDialog extends StatefulWidget {
  final InspectionService svc;
  final int year;
  final Map<String, List<String>> orgMap;
  final List<String> hdqts;
  final List<String> allQuarters;
  final List<String> allNationGroups;
  final void Function(List<String> licenseNos) onConfirm;

  const _AddFromStagingDialog({
    required this.svc,
    required this.year,
    required this.orgMap,
    required this.hdqts,
    required this.allQuarters,
    required this.allNationGroups,
    required this.onConfirm,
  });

  @override
  State<_AddFromStagingDialog> createState() => _AddFromStagingDialogState();
}

class _AddFromStagingDialogState extends State<_AddFromStagingDialog> {
  static const Color _purple = Color(0xFF7B1FA2);

  String _hdqt = '', _team = '', _quarter = '', _nationGroup = '';
  final _searchCtrl = TextEditingController();

  List<Map<String, dynamic>> _candidates = [];
  List<Map<String, dynamic>> _selected = [];
  final _leftChecked = <String>{};
  final _rightChecked = <String>{};
  bool _loading = false;
  int _total = 0;
  bool _adding = false;
  Map<String, dynamic>? _searchFeedback;

  List<String> get _teams => _hdqt.isNotEmpty ? (widget.orgMap[_hdqt] ?? []) : [];

  @override
  void initState() {
    super.initState();
    _loadCandidates();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCandidates() async {
    setState(() { _loading = true; _candidates = []; _leftChecked.clear(); _searchFeedback = null; });
    try {
      final filters = <String, List<String>>{};
      if (_hdqt.isNotEmpty) filters['access담당'] = [_hdqt];
      if (_team.isNotEmpty) filters['품질개선팀'] = [_team];
      if (_quarter.isNotEmpty) filters['분기'] = [_quarter];
      if (_nationGroup.isNotEmpty) filters['국종군'] = [_nationGroup];
      final result = await widget.svc.getStagingItems(
        widget.year,
        filters: filters,
        search: _searchCtrl.text.trim(),
      );
      final items = List<Map<String, dynamic>>.from(result['items'] ?? []);
      final selectedNos = _selected.map((e) => e['허가번호'] as String).toSet();
      setState(() {
        _total = result['total'] as int? ?? 0;
        _candidates = items.where((e) => !selectedNos.contains(e['허가번호'])).toList();
        _searchFeedback = result['search_feedback'] as Map<String, dynamic>?;
      });
    } catch (e) {
      debugPrint('[대상추가 검색 에러] $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _moveToRight() {
    if (_leftChecked.isEmpty) return;
    final moving = _candidates.where((e) => _leftChecked.contains(e['허가번호'])).toList();
    setState(() {
      _selected.addAll(moving);
      _candidates.removeWhere((e) => _leftChecked.contains(e['허가번호']));
      _leftChecked.clear();
    });
  }

  void _moveToLeft() {
    if (_rightChecked.isEmpty) return;
    final moving = _selected.where((e) => _rightChecked.contains(e['허가번호'])).toList();
    setState(() {
      _candidates.addAll(moving);
      _selected.removeWhere((e) => _rightChecked.contains(e['허가번호']));
      _rightChecked.clear();
    });
  }

  void _toggleLeft(String no) => setState(() {
    if (_leftChecked.contains(no)) _leftChecked.remove(no); else _leftChecked.add(no);
  });

  void _toggleRight(String no) => setState(() {
    if (_rightChecked.contains(no)) _rightChecked.remove(no); else _rightChecked.add(no);
  });

  void _selectAllLeft() => setState(() {
    if (_leftChecked.length == _candidates.length) _leftChecked.clear();
    else _leftChecked.addAll(_candidates.map((e) => e['허가번호'] as String));
  });

  void _selectAllRight() => setState(() {
    if (_rightChecked.length == _selected.length) _rightChecked.clear();
    else _rightChecked.addAll(_selected.map((e) => e['허가번호'] as String));
  });

  Widget _dropdown(String hint, String? value, List<String> items, ValueChanged<String?> onChanged) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true, isDense: true,
          hint: Text(hint, style: const TextStyle(fontSize: 12)),
          value: value?.isEmpty == true ? null : value,
          icon: const Icon(Icons.arrow_drop_down, size: 18),
          dropdownColor: Colors.white,

          borderRadius: BorderRadius.circular(12),
          style: const TextStyle(fontSize: 12, color: Colors.black87),
          items: [
            DropdownMenuItem(value: '', child: Text('전체', style: TextStyle(color: Colors.grey.shade500))),
            ...items.map((v) => DropdownMenuItem(value: v, child: Text(v))),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _itemTile(Map<String, dynamic> item, bool checked, VoidCallback onTap) {
    final no = item['허가번호'] as String? ?? '';
    final name = item['호출명칭'] as String? ?? '';
    final team = item['품질개선팀'] as String? ?? '';
    final quarter = item['분기'] as String? ?? '';
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: checked ? Colors.purple.shade50 : Colors.transparent,
          border: Border(bottom: BorderSide(color: Colors.grey.shade100)),
        ),
        child: Row(children: [
          SizedBox(
            width: 20, height: 20,
            child: Checkbox(
              value: checked, onChanged: (_) => onTap(),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              activeColor: _purple,
              side: BorderSide(color: Colors.grey.shade400),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              Text('$no  $team  $quarter',
                  style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ]),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: SizedBox(
        width: screenSize.width * 0.85,
        height: screenSize.height * 0.85,
        child: Column(children: [
          // ── 헤더 ──
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
            decoration: const BoxDecoration(
              color: _purple,
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(children: [
              const Icon(Icons.add_circle_outline, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              const Text('대상 추가',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 20),
                onPressed: () => Navigator.pop(context),
                padding: EdgeInsets.zero, constraints: const BoxConstraints(),
              ),
            ]),
          ),

          // ── 필터 패널 ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.grey.shade50,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: _dropdown('본부', _hdqt, widget.hdqts, (v) {
                  setState(() { _hdqt = v ?? ''; _team = ''; });
                  _loadCandidates();
                })),
                const SizedBox(width: 8),
                Expanded(child: _dropdown('팀', _team, _teams, (v) {
                  setState(() => _team = v ?? '');
                  _loadCandidates();
                })),
                const SizedBox(width: 8),
                Expanded(child: _dropdown('분기', _quarter, widget.allQuarters, (v) {
                  setState(() => _quarter = v ?? '');
                  _loadCandidates();
                })),
                const SizedBox(width: 8),
                Expanded(child: _dropdown('밴드선택', _nationGroup, widget.allNationGroups, (v) {
                  setState(() => _nationGroup = v ?? '');
                  _loadCandidates();
                })),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: 34,
                    child: TextField(
                      controller: _searchCtrl,
                      decoration: InputDecoration(
                        hintText: '복수검색 가능 (쉼표/공백 구분)',
                        hintStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
                        prefixIcon: const Icon(Icons.search, size: 16),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: Colors.grey.shade300)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: Colors.grey.shade300)),
                        contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 10),
                        isDense: true, filled: true, fillColor: Colors.white,
                      ),
                      style: const TextStyle(fontSize: 12),
                      onSubmitted: (_) => _loadCandidates(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  icon: const Icon(Icons.search, size: 14),
                  label: const Text('검색', style: TextStyle(fontSize: 12)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _purple, foregroundColor: Colors.white,
                    minimumSize: const Size(70, 34),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  onPressed: _loadCandidates,
                ),
              ]),
              if (_searchFeedback != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue.shade200),
                  ),
                  child: Row(children: [
                    Icon(Icons.info_outline, size: 14, color: Colors.blue.shade700),
                    const SizedBox(width: 8),
                    Expanded(child: Text.rich(
                      TextSpan(style: const TextStyle(fontSize: 11), children: [
                        TextSpan(text: '검색 ${_searchFeedback!['searched']}건  '),
                        TextSpan(text: '후보 ${_searchFeedback!['found']}건',
                            style: TextStyle(color: Colors.green.shade700, fontWeight: FontWeight.w600)),
                        const TextSpan(text: '  '),
                        TextSpan(text: '이미 추가됨 ${_searchFeedback!['already_added']}건',
                            style: TextStyle(color: Colors.orange.shade800, fontWeight: FontWeight.w600)),
                        const TextSpan(text: '  '),
                        TextSpan(text: '미발견 ${_searchFeedback!['not_found']}건',
                            style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600)),
                      ]),
                    )),
                  ]),
                ),
              ],
            ]),
          ),
          const Divider(height: 1),

          // ── 좌우 패널 ──
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // 좌측: 후보 목록
              Expanded(
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    color: Colors.grey.shade100,
                    child: Row(children: [
                      GestureDetector(
                        onTap: _selectAllLeft,
                        child: Row(children: [
                          SizedBox(
                            width: 18, height: 18,
                            child: Checkbox(
                              value: _candidates.isNotEmpty && _leftChecked.length == _candidates.length,
                              onChanged: (_) => _selectAllLeft(),
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              activeColor: _purple,
                              side: BorderSide(color: Colors.grey.shade400),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('후보 목록', style: TextStyle(fontSize: 12,
                              fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                        ]),
                      ),
                      const Spacer(),
                      if (_loading)
                        SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2, color: _purple))
                      else
                        Text('${_candidates.length}건 표시 / 전체 $_total건',
                            style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                    ]),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : _candidates.isEmpty
                            ? Center(child: Text('결과 없음',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade400)))
                            : ListView.builder(
                                itemCount: _candidates.length,
                                itemBuilder: (_, i) {
                                  final item = _candidates[i];
                                  final no = item['허가번호'] as String? ?? '';
                                  return _itemTile(item, _leftChecked.contains(no), () => _toggleLeft(no));
                                },
                              ),
                  ),
                ]),
              ),

              // 중앙 화살표
              Container(
                width: 44,
                color: Colors.grey.shade50,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Tooltip(
                    message: '추가할 목록으로 이동',
                    child: Material(
                      color: _leftChecked.isEmpty ? Colors.grey.shade300 : _purple,
                      borderRadius: BorderRadius.circular(6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: _leftChecked.isEmpty ? null : _moveToRight,
                        child: const SizedBox(width: 32, height: 32,
                            child: Icon(Icons.arrow_forward, color: Colors.white, size: 16)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Tooltip(
                    message: '후보 목록으로 복원',
                    child: Material(
                      color: _rightChecked.isEmpty ? Colors.grey.shade300 : Colors.orange,
                      borderRadius: BorderRadius.circular(6),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: _rightChecked.isEmpty ? null : _moveToLeft,
                        child: const SizedBox(width: 32, height: 32,
                            child: Icon(Icons.arrow_back, color: Colors.white, size: 16)),
                      ),
                    ),
                  ),
                ]),
              ),

              const VerticalDivider(width: 1),

              // 우측: 추가할 목록
              Expanded(
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    color: Colors.purple.shade50,
                    child: Row(children: [
                      GestureDetector(
                        onTap: _selectAllRight,
                        child: Row(children: [
                          SizedBox(
                            width: 18, height: 18,
                            child: Checkbox(
                              value: _selected.isNotEmpty && _rightChecked.length == _selected.length,
                              onChanged: (_) => _selectAllRight(),
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              activeColor: Colors.orange,
                              side: BorderSide(color: Colors.grey.shade400),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text('추가할 목록', style: TextStyle(fontSize: 12,
                              fontWeight: FontWeight.w600, color: _purple)),
                        ]),
                      ),
                      const Spacer(),
                      Text('${_selected.length}건',
                          style: const TextStyle(fontSize: 10, color: _purple,
                              fontWeight: FontWeight.w600)),
                    ]),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _selected.isEmpty
                        ? Center(child: Text('→ 버튼으로 대상을 선택하세요',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade400)))
                        : ListView.builder(
                            itemCount: _selected.length,
                            itemBuilder: (_, i) {
                              final item = _selected[i];
                              final no = item['허가번호'] as String? ?? '';
                              return _itemTile(item, _rightChecked.contains(no), () => _toggleRight(no));
                            },
                          ),
                  ),
                ]),
              ),
            ]),
          ),

          const Divider(height: 1),

          // ── 하단 버튼 ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(children: [
              const Spacer(),
              TextButton(
                onPressed: _adding ? null : () => Navigator.pop(context),
                child: const Text('취소'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                icon: _adding
                    ? const SizedBox(width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.add_circle_outline, size: 16),
                label: Text(_adding ? '추가 중...' : '대상 추가 (${_selected.length}건)',
                    style: const TextStyle(fontSize: 13)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _selected.isEmpty ? Colors.grey.shade400 : _purple,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(160, 38),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
                onPressed: (_selected.isEmpty || _adding) ? null : () {
                  setState(() => _adding = true);
                  widget.onConfirm(_selected.map((e) => e['허가번호'] as String).toList());
                },
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── 전산비교 다이얼로그 ────────────────────────────────────────────

class _CompareDialog extends StatefulWidget {
  final List<String> licenseNos;
  final String? accessDivisionName; // access담당 컬럼 기준 본부명 (최다 빈도)
  final bool multiDivision;         // 선택 항목에 복수 본부 섞여 있는지
  final ErpDsCompareService compareService;
  final DsDataService dsService;

  const _CompareDialog({
    required this.licenseNos,
    required this.accessDivisionName,
    required this.multiDivision,
    required this.compareService,
    required this.dsService,
  });

  @override
  State<_CompareDialog> createState() => _CompareDialogState();
}

class _CompareDialogState extends State<_CompareDialog> {
  static const Color _theme = Color(0xFF1565C0);
  static const Color _green = Color(0xFF43A047);
  static const Color _red = Color(0xFFE53935);

  // access담당 한글명 → auth division ID
  static const Map<String, String> _accessToAuthId = {
    '강남': 'gangnam', '강남본부': 'gangnam',
    '강북': 'gangbuk', '강북본부': 'gangbuk',
    '경기': 'gyeonggi', '경기본부': 'gyeonggi',
    '인천': 'incheon', '인천본부': 'incheon',
    '강원': 'gangwon', '강원본부': 'gangwon',
    '충청': 'chungcheong', '충청본부': 'chungcheong',
    '경북': 'gyeongbuk', '경북본부': 'gyeongbuk',
    '경남': 'gyeongnam', '경남본부': 'gyeongnam',
    '서부': 'seobu', '서부본부': 'seobu',
  };

  bool _loadingUploads = true;
  List<DsUploadInfo> _uploads = [];
  DsUploadInfo? _selectedUpload;
  bool _comparing = false;
  ErpDsCompareResult? _result;
  String _filter = '전체';
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadUploads();
  }

  Future<void> _loadUploads() async {
    final name = widget.accessDivisionName;
    if (name == null || name.isEmpty) {
      setState(() { _loadingUploads = false; _error = 'Access담당 본부 정보를 찾을 수 없습니다.'; });
      return;
    }
    final authId = _accessToAuthId[name];
    if (authId == null) {
      setState(() { _loadingUploads = false; _error = '본부명 "$name"을 DS 본부로 매핑할 수 없습니다.'; });
      return;
    }
    final dsDivId = DsDataService.authToDsDivision[authId] ?? authId;
    try {
      final stats = await widget.dsService.getStats(divisionId: dsDivId);
      final completed = stats.uploads.where((u) => u.status == 'completed').toList();
      if (mounted) {
        setState(() {
          _uploads = completed;
          _selectedUpload = completed.isNotEmpty ? completed.first : null;
          _loadingUploads = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loadingUploads = false; _error = 'DS 파일 조회 실패: $e'; });
    }
  }

  Future<void> _doCompare() async {
    if (_selectedUpload == null) {
      setState(() => _error = 'DS 파일을 선택하세요.');
      return;
    }
    setState(() { _comparing = true; _error = null; });
    try {
      final result = await widget.compareService.compare(
        zpwinoList: widget.licenseNos,
        divisionId: _selectedUpload!.divisionId,
        divisionCode: _selectedUpload!.divisionCode,
        importDate: _selectedUpload!.actualDate,
      );
      if (mounted) setState(() { _result = result; _comparing = false; });
    } catch (e) {
      if (mounted) setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _comparing = false;
      });
    }
  }

  List<CompareItem> _filteredItems() {
    if (_result == null) return [];
    if (_filter == '전체') return _result!.items;
    return _result!.items.where((it) => it.towerMatch == _filter || it.serialMatch == _filter).toList();
  }

  Color _matchColor(String match) {
    switch (match) {
      case '일치': return _green;
      case '부분일치': return const Color(0xFFFF9800);
      case '불일치': return _red;
      default: return Colors.grey;
    }
  }

  Widget _matchChip(String match) {
    if (match.isEmpty) return Text('-', style: TextStyle(fontSize: 12, color: Colors.grey.shade400));
    final color = _matchColor(match);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(match, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _statChip(String label, int value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
      child: Text('$label $value', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFFFAFAFB),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 860),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 헤더
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(color: _theme, borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.compare_arrows, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 10),
                  const Text('전산비교', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.black87)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: _theme.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('${widget.licenseNos.length}건',
                        style: const TextStyle(fontSize: 12, color: _theme, fontWeight: FontWeight.w600)),
                  ),
                  const Spacer(),
                  if (_result != null)
                    TextButton.icon(
                      onPressed: () => setState(() { _result = null; _filter = '전체'; _error = null; }),
                      icon: const Icon(Icons.refresh, size: 15),
                      label: const Text('다시 설정', style: TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(foregroundColor: _theme),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                    splashRadius: 18,
                  ),
                ],
              ),
            ),

            // 본문
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: _result == null ? _buildSetup() : _buildResult(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSetup() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 복수 본부 경고
        if (widget.multiDivision)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange.shade700),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '선택된 항목에 여러 본부가 포함되어 있습니다. '
                  'Access담당 기준 가장 많은 본부(${widget.accessDivisionName})의 DS 파일로 자동 조회됩니다.',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                ),
              ),
            ]),
          ),

        // DS 파일 선택
        _card(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.folder_open, color: _theme, size: 20),
              const SizedBox(width: 8),
              const Text('DS 파일', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              if (widget.accessDivisionName != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _theme.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${widget.accessDivisionName} 기준 자동 조회',
                    style: const TextStyle(fontSize: 11, color: _theme, fontWeight: FontWeight.w500),
                  ),
                ),
              const Spacer(),
              if (_selectedUpload != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: _green.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: Text('${_selectedUpload!.totalRows}행',
                      style: const TextStyle(fontSize: 12, color: _green, fontWeight: FontWeight.w600)),
                ),
            ]),
            const SizedBox(height: 10),
            if (_loadingUploads)
              const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)))
            else if (_uploads.isEmpty)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('업로드된 DS 파일이 없습니다.', style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
              )
            else
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<DsUploadInfo>(
                    value: _selectedUpload,
                    isExpanded: true,
                    isDense: true,
                    icon: const Icon(Icons.arrow_drop_down, color: _theme, size: 20),
                    dropdownColor: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    style: const TextStyle(color: Colors.black87, fontSize: 13),
                    items: _uploads.map((u) => DropdownMenuItem(
                      value: u,
                      child: Text('${u.divisionName} - ${u.actualDate} (${u.totalRows}행)'),
                    )).toList(),
                    onChanged: (v) => setState(() => _selectedUpload = v),
                  ),
                ),
              ),
          ],
        )),

        const SizedBox(height: 12),

        // 허가번호 목록 미리보기
        _card(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.list_alt, color: _theme, size: 20),
              const SizedBox(width: 8),
              Text('비교 대상 허가번호 (${widget.licenseNos.length}건)',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 10),
            Container(
              height: 100,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                border: Border.all(color: Colors.grey.shade200),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SingleChildScrollView(
                child: Text(
                  widget.licenseNos.join('\n'),
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
            ),
          ],
        )),

        const SizedBox(height: 16),

        if (_error != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(children: [
              Icon(Icons.error_outline, size: 16, color: Colors.red.shade600),
              const SizedBox(width: 8),
              Expanded(child: Text(_error!, style: TextStyle(fontSize: 13, color: Colors.red.shade700))),
            ]),
          ),

        SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            onPressed: (_comparing || _selectedUpload == null || _loadingUploads) ? null : _doCompare,
            icon: _comparing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.compare_arrows),
            label: Text(_comparing ? '비교 중...' : '비교 시작', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: _theme, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResult() {
    final r = _result!;
    final items = _filteredItems();

    // 요약 통계 계산
    final towerMatch = (r.summary['tower_match'] ?? 0) + (r.summary['tower_partial'] ?? 0);
    final towerMismatch = r.summary['tower_mismatch'] ?? 0;
    final towerCheck = r.summary['tower_check'] ?? 0;
    final serialMatch = (r.summary['serial_match'] ?? 0) + (r.summary['serial_partial'] ?? 0);
    final serialMismatch = r.summary['serial_mismatch'] ?? 0;
    final serialCheck = r.summary['serial_check'] ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 경고
        if (r.warnings.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: r.warnings.map((w) => Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber, size: 15, color: Colors.orange.shade700),
                  const SizedBox(width: 6),
                  Expanded(child: Text(w, style: TextStyle(fontSize: 12, color: Colors.orange.shade800))),
                ],
              )).toList(),
            ),
          ),

        // 요약
        _card(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.analytics_outlined, color: _theme, size: 20),
              SizedBox(width: 8),
              Text('비교 결과 요약', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _statChip('전체', r.total, Colors.grey.shade600),
              _statChip('ERP', r.erpFound, const Color(0xFF4A90D9)),
              _statChip('DS장치', r.dsDeviceFound, const Color(0xFF00897B)),
              _statChip('DS안테나', r.dsAntennaFound, const Color(0xFF5C6BC0)),
            ]),
            const SizedBox(height: 12),
            // 설치대 요약
            _summaryRow('설치대', towerMatch, towerMismatch, towerCheck),
            const SizedBox(height: 8),
            _summaryRow('일련번호', serialMatch, serialMismatch, serialCheck),
          ],
        )),

        const SizedBox(height: 12),

        // 필터
        _card(Wrap(
          spacing: 8, runSpacing: 8,
          children: ['전체', '일치', '부분일치', '불일치', '확인필요'].map((f) => ChoiceChip(
            label: Text(f, style: TextStyle(fontSize: 12, color: _filter == f ? Colors.white : Colors.black87)),
            selected: _filter == f,
            selectedColor: _theme,
            backgroundColor: Colors.grey.shade100,
            onSelected: (_) => setState(() => _filter = f),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            side: BorderSide(color: _filter == f ? _theme : Colors.grey.shade300),
          )).toList(),
        )),

        const SizedBox(height: 12),

        // 결과 테이블
        _card(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.table_chart, color: _theme, size: 20),
              const SizedBox(width: 8),
              const Text('상세 결과', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: _theme.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                child: Text('${items.length}건', style: const TextStyle(fontSize: 12, color: _theme, fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(const Color(0xFFF5F7FA)),
                columnSpacing: 14,
                horizontalMargin: 10,
                dataRowMinHeight: 38,
                dataRowMaxHeight: 52,
                headingRowHeight: 40,
                columns: const [
                  DataColumn(label: Text('허가번호', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  DataColumn(label: Text('호출명칭', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  DataColumn(label: Text('본부', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  DataColumn(label: Text('ERP 설치대', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  DataColumn(label: Text('DS 설치대', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  DataColumn(label: Text('설치대 비교', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  DataColumn(label: Text('ERP 일련번호', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  DataColumn(label: Text('DS 일련번호', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                  DataColumn(label: Text('일련번호 비교', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
                ],
                rows: items.map((item) => DataRow(cells: [
                  DataCell(SizedBox(width: 150, child: Text(item.zpwino, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
                  DataCell(SizedBox(width: 100, child: Text(item.zpwina, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
                  DataCell(Text(item.areaHdofcNm, style: const TextStyle(fontSize: 12))),
                  DataCell(SizedBox(width: 110, child: Text(item.erpZpirty3, style: const TextStyle(fontSize: 12)))),
                  DataCell(SizedBox(width: 110, child: Text(item.dsTowerType, style: const TextStyle(fontSize: 12)))),
                  DataCell(_matchChip(item.towerMatch)),
                  DataCell(SizedBox(width: 130, child: Text(item.erpSerial, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
                  DataCell(SizedBox(width: 130, child: Text(item.dsSerial, style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
                  DataCell(_matchChip(item.serialMatch)),
                ])).toList(),
              ),
            ),
          ],
        )),
      ],
    );
  }

  Widget _summaryRow(String label, int match, int mismatch, int check) {
    final total = match + mismatch + check;
    final rate = total > 0 ? (match / total * 100).toStringAsFixed(1) : '-';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        SizedBox(width: 60, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13))),
        _miniStat('일치', match, _green),
        const SizedBox(width: 8),
        _miniStat('불일치', mismatch, _red),
        const SizedBox(width: 8),
        _miniStat('확인필요', check, const Color(0xFFFF9800)),
        const Spacer(),
        Text('일치율 $rate%', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1565C0))),
      ]),
    );
  }

  Widget _miniStat(String label, int value, Color color) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text('$label $value', style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500)),
    ]);
  }

  Widget _card(Widget child) {
    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: child,
    );
  }
}

// ── 이전달/다음달 네비게이션 버튼 ──────────────────────────────────

class _NavButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool iconRight;
  final bool enabled;
  final VoidCallback? onTap;

  const _NavButton({
    required this.label,
    required this.icon,
    this.iconRight = false,
    required this.enabled,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled ? const Color(0xFF374151) : Colors.grey.shade400;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: enabled ? Colors.white : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: enabled ? Colors.grey.shade300 : Colors.grey.shade200),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: iconRight
              ? [
                  Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500)),
                  const SizedBox(width: 2),
                  Icon(icon, size: 16, color: color),
                ]
              : [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 2),
                  Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500)),
                ],
        ),
      ),
    );
  }
}

