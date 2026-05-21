import 'dart:async';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../widgets/app_loader.dart';
import '../widgets/progress_dialog.dart';
import 'inspection_result_screen.dart';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

// 워크플로우 상태 전체 토큰 (대시보드 → 일정화면 상태칩과 동일 코드)
// 'RECHECK' 토큰은 별도로 재점검 토글을 활성화하는 특수 값

class _InspColSpec {
  final String key, label;
  final double w;
  final int si; // sort index, -1 = not sortable
  final bool hideable;
  const _InspColSpec(this.key, this.label, this.w, this.si, {this.hideable = true});
}

const _kInspCols = <_InspColSpec>[
  _InspColSpec('__chk',     '',             48,  -1, hideable: false),
  _InspColSpec('__sched',   '수검일정',     110,   1, hideable: false),
  _InspColSpec('허가번호',   '허가번호',     120,   2, hideable: false),
  _InspColSpec('호출명칭',   '호출명칭',     180,   3, hideable: false),
  _InspColSpec('국종군',     '국종군',        80,   4),
  _InspColSpec('부서',       'KCA부서',      120,   5),
  _InspColSpec('연도주기',   '연도주기',      70,   6),
  _InspColSpec('설치장소',   '설치장소',     160,   7, hideable: false),
  _InspColSpec('도로명주소', '도로명주소',   180,   8),
  _InspColSpec('장치수',     '장치수',        60,   9),
  _InspColSpec('통시',       '통시',          80,  10),
  _InspColSpec('공대',       '공대',          80,  11),
  _InspColSpec('zpprac1',   'ERP활용구분',   90,  12),
  _InspColSpec('시기조정',   '시기조정',      80,  13),
  _InspColSpec('기준연도',   '기준연도',      80,  14),
  _InspColSpec('skt본부',   'SKT본부',      100,  15, hideable: false),
  _InspColSpec('access담당','Access담당',   110,  16, hideable: false),
  _InspColSpec('품질개선팀', '품질개선팀',   110,  17, hideable: false),
  _InspColSpec('검사결과',   '검사결과',      80,  18, hideable: false),
];

class InspectionScheduleScreen extends StatefulWidget {
  final void Function(List<String> licenseNos, String? accessDivision, bool multiDivision,
      {List<String>? schedulePks, Map<String, Map<String, String>>? schedMap})? onCompareNavigate;
  final List<String>? initialLicenseNos;
  /// 초기 워크플로우 상태 필터 (홈 대시보드 카드에서 점프 시).
  /// 'RECHECK' 토큰이면 _recheckOnly 토글을 켜고 statusFilter는 비움.
  final String? initialStatusFilter;
  const InspectionScheduleScreen({super.key, this.onCompareNavigate,
      this.initialLicenseNos, this.initialStatusFilter});
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
  final _hdrHorizCtrl = ScrollController();
  bool _hScrollSyncing = false;
  final Map<String, double> _colWidths = {for (final c in _kInspCols) c.key: c.w};
  Set<String> _hiddenCols = {'부서', '연도주기', '도로명주소', '시기조정', '기준연도'};

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
  String _pHdqt = '', _pTeam = '', _pSearch = '', _pScheduled = '', _pSchedWeek = '', _pCrew = '';
  List<String> _pQuarters = [], _pKcaResults = [];

  // applied 필터 (실제 쿼리)
  String _aHdqt = '', _aTeam = '', _aSearch = '', _aScheduled = '';
  String _aSchedWeek = ''; // 수검예정주차 필터 (매트릭스 카드 클릭 시 세팅)
  String _aCrew = '';      // 조 필터 (클라이언트 사이드, schedule 매핑 기반)
  List<String> _aQuarters = [], _aNationGroups = [], _aKcaResults = [];

  // 매트릭스 탭 전용 필터
  String _mHdqt = '', _mTeam = '', _mWeek = '', _mMonth = '';
  // 수검일정별 현황 월 네비게이션 (기본: 현재 달)
  int _navMonth = DateTime.now().month;

  // 다중 선택 (일괄 일정 등록)
  final _selectedLicenseNos = <String>{};
  // 이미 일정 등록된 허가번호 세트
  Set<String> _scheduledNos = {};
  // 허가번호 → pre_check_status 맵 (사전점검완료 칩용)
  Map<String, String> _targetPreCheckMap = {};
  // 허가번호 → 수검예정주차 맵
  Map<String, String> _scheduleWeekMap = {};
  // 허가번호 → workflow_status 맵 (Phase 1)
  Map<String, String> _scheduleStatusMap = {};
  // 허가번호 → schedule pk 맵 (상태 전환 호출용)
  Map<String, String> _schedulePkMap = {};
  // 허가번호 → 전파관리소 접수번호 (Phase 3)
  Map<String, String> _scheduleSubmissionMap = {};
  // 허가번호 → 조
  Map<String, String> _scheduleCrewMap = {};
  // 허가번호 → 재점검 필요 (Phase 4)
  Set<String> _scheduleNeedsRecheck = <String>{};
  // 워크플로우 상태 필터 (빈 리스트 = 전체)
  List<String> _statusFilters = [];
  List<String> _pStatusFilters = [];   // pending (다이얼로그 적용 전)
  List<String> _pNationGroups = [];    // 밴드선택 pending (복수 선택)
  // 재점검 필요 건만 보기 (Phase 4)
  bool _recheckOnly = false;
  // SLA 임계점 초과 건만 보기 (Phase 5)
  bool _overdueOnly = false;

  List<Map<String, dynamic>> _items = [];
  int _total = 0;
  int _page = 1;
  bool _loading = false;
  String? _error;

  // 테이블 정렬
  int? _sortColIdx;
  bool _sortAsc = true;

  void _onScheduleSort(int si, bool asc) {
    final col = _kInspCols.firstWhere((c) => c.si == si,
        orElse: () => const _InspColSpec('', '', 0, -1));
    if (col.key.isEmpty) return;
    setState(() {
      _sortColIdx = si;
      _sortAsc = asc;
      _items.sort((a, b) {
        final av = (a[col.key] ?? '').toString();
        final bv = (b[col.key] ?? '').toString();
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

  // 진도율 현황
  int _progressTotal = 0;
  int _progressCompleted = 0;
  double _progressPercent = 0.0;
  List<Map<String, dynamic>> _progressByHdqt = [];
  bool _progressLoading = false;

  // 미배정 현황
  int _unassignedTotal = 0;
  Map<String, dynamic> _unassignedByRegion = {};
  Map<String, dynamic> _unassignedByReason = {};
  List<Map<String, dynamic>> _unassignedItems = [];
  bool _unassignedCapped = false;

  Map<String, dynamic>? _detailData;
  String? _detailLicenseNo;
  bool _detailLoading = false;

  // SKO-OCEAN 시설점검 사진 (공대 기준)
  List<Map<String, dynamic>> _sislPhotos = [];
  bool _sislLoading = false;
  String? _sislNeosKey;

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

  /// 해당 item에 대해 일정 등록/체크 권한이 있는지 (admin/manager 전용)
  bool _canManageItem(Map<String, dynamic> item) {
    if (_isSuperAdmin) return true;
    if (_isDivisionAdmin) {
      final itemHdqt = '${item['access담당'] ?? ''}';
      return itemHdqt == _myHdqt;
    }
    return false; // member
  }

  /// 해당 item이 본인 본부 소속인지 (member 포함, 전산비교 체크박스용)
  bool _isMyDivision(Map<String, dynamic> item) {
    if (_isSuperAdmin) return true;
    if (_myHdqt.isEmpty) return false;
    final itemHdqt = '${item['access담당'] ?? ''}';
    return itemHdqt == _myHdqt;
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
      _aScheduled.isNotEmpty || _aSchedWeek.isNotEmpty || _aCrew.isNotEmpty ||
      _statusFilters.isNotEmpty || _recheckOnly || _overdueOnly;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _svc = InspectionService()..setAuthToken(context.read<AuthService>().authToken);
    _cacheAuthValues();
    _applyDefaultFilter();
    if (widget.initialLicenseNos != null && widget.initialLicenseNos!.isNotEmpty) {
      final searchText = widget.initialLicenseNos!.join(',');
      _pSearch = searchText;
      _aSearch = searchText;
      _searchCtrl.text = searchText;
    }
    // 홈 대시보드 → 상태칩 자동 적용
    final f = widget.initialStatusFilter;
    if (f != null && f.isNotEmpty) {
      if (f == 'RECHECK') {
        _recheckOnly = true;
      } else if (f == 'OVERDUE') {
        _overdueOnly = true;
      } else {
        _pStatusFilters = _statusFilters = [f];
      }
    }
    _hdrHorizCtrl.addListener(_syncHdrScroll);
    _horizontalScrollCtrl.addListener(_syncDataScroll);
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
    // member(일반 팀원)인 경우 팀까지 자동 필터
    // 주의: initState에서는 _orgMap이 아직 비어있으므로 검증 없이 바로 적용.
    // 잘못된 팀명이면 백엔드에서 결과가 비어 사용자가 인지 가능.
    if (!_isAdmin && _myTeam.isNotEmpty) {
      _pTeam = _myTeam;
      _aTeam = _myTeam;
    }
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    _horizontalScrollCtrl.dispose();
    _hdrHorizCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    setState(() { _loading = true; _error = null; });

    // Phase 5 성능: 메인 데이터 + 일정 매핑(state badge용)만 동기 대기.
    // 나머지(매트릭스/미배정/진도율)는 백그라운드로 채워 메인 화면 즉시 노출.
    final primary = await Future.wait([
      _fetchData(),
      _fetchScheduledNos(),   // 상태 배지/접수번호/조 매핑 — 행 그리는데 필요
    ]);
    if (!mounted) return;
    final dataRes = primary[0] as Map<String, dynamic>?;
    final schedResult = primary[1] as ({Set<String> nos, Map<String, String> weekMap, List<Map<String, dynamic>> schedules, Map<String, String> statusMap, Map<String, String> pkMap, Map<String, String> submissionMap, Map<String, String> crewMap, Set<String> needsRecheck})?;
    setState(() {
      _loading = false;
      if (dataRes != null) {
        _items = List<Map<String, dynamic>>.from(dataRes['items'] ?? []);
        _total = (dataRes['total'] as num?)?.toInt() ?? 0;
        _targetPreCheckMap = {
          for (final it in _items)
            if ((it['pre_check_status'] ?? '').toString().isNotEmpty)
              '${it['허가번호'] ?? ''}': '${it['pre_check_status']}',
        };
      } else {
        _error = '데이터 로드 실패';
      }
      if (schedResult != null) {
        _scheduledNos = schedResult.nos;
        _scheduleWeekMap = schedResult.weekMap;
        _schedules = schedResult.schedules;
        _scheduleStatusMap = schedResult.statusMap;
        _schedulePkMap = schedResult.pkMap;
        _scheduleSubmissionMap = schedResult.submissionMap;
        _scheduleCrewMap = schedResult.crewMap;
        _scheduleNeedsRecheck = schedResult.needsRecheck;
      }
    });

    // 후순위 API — 백그라운드로 채워짐 (도착 시마다 setState)
    unawaited(_fetchSummary().then((summRes) {
      if (!mounted || summRes == null) return;
      setState(() {
        _matrix = Map<String, dynamic>.from(summRes['matrix'] ?? {});
        _quarters = List<String>.from(summRes['quarters'] ?? []);
      });
    }));
    unawaited(_fetchUnassigned().then((unassRes) {
      if (!mounted || unassRes == null) return;
      setState(() {
        _unassignedTotal = (unassRes['total'] as num?)?.toInt() ?? 0;
        _unassignedByRegion = Map<String, dynamic>.from(unassRes['by_region'] ?? {});
        _unassignedByReason = Map<String, dynamic>.from(unassRes['by_reason'] ?? {});
        _unassignedItems = List<Map<String, dynamic>>.from(unassRes['items'] ?? []);
        _unassignedCapped = unassRes['items_capped'] == true;
      });
    }));
    unawaited(_fetchProgressByResult().then((progRes) {
      if (!mounted || progRes == null) return;
      setState(() {
        _progressTotal = (progRes['total'] as num?)?.toInt() ?? 0;
        _progressCompleted = (progRes['completed'] as num?)?.toInt() ?? 0;
        _progressPercent = (progRes['percent'] as num?)?.toDouble() ?? 0.0;
        _progressByHdqt = List<Map<String, dynamic>>.from(progRes['by_hdqt'] ?? []);
      });
    }));
  }

  Future<Map<String, dynamic>?> _fetchProgressByResult() async {
    try {
      return await _svc.getProgressByResult(_year);
    } catch (_) { return null; }
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
        // Phase 5: 워크플로우 상태/재점검/SLA 지연도 서버에 전달
        // (클라이언트 _filteredItems도 동일 조건 → 멱등 OK)
        workflowStatuses: _statusFilters,
        needsRecheck: _recheckOnly ? '1' : '',
        overdueOnly: _overdueOnly ? '1' : '',
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

  Future<({Set<String> nos, Map<String, String> weekMap, List<Map<String, dynamic>> schedules, Map<String, String> statusMap, Map<String, String> pkMap, Map<String, String> submissionMap, Map<String, String> crewMap, Set<String> needsRecheck})?> _fetchScheduledNos() async {
    try {
      final schedules = await _svc.getSchedules(_year);
      final nos = <String>{};
      final weekMap = <String, String>{};
      final statusMap = <String, String>{};
      final pkMap = <String, String>{};
      final submissionMap = <String, String>{};
      final crewMap = <String, String>{};
      final needsRecheck = <String>{};
      for (final s in schedules) {
        final no = (s['허가번호'] as String? ?? '').trim();
        if (no.isEmpty) continue;
        nos.add(no);
        final week = (s['수검예정주차'] as String? ?? '').trim();
        if (week.isNotEmpty) weekMap[no] = week;
        final st = (s['workflow_status'] as String? ?? '').trim();
        if (st.isNotEmpty) statusMap[no] = st;
        final pk = (s['pk'] as String? ?? '').trim();
        if (pk.isNotEmpty) pkMap[no] = pk;
        final submission = (s['submission_no'] as String? ?? '').trim();
        if (submission.isNotEmpty) submissionMap[no] = submission;
        final crew = (s['조'] as String? ?? '').trim();
        if (crew.isNotEmpty) crewMap[no] = crew;
        if ((s['needs_recheck'] as String? ?? '') == '1') needsRecheck.add(no);
      }
      return (
        nos: nos, weekMap: weekMap, schedules: schedules,
        statusMap: statusMap, pkMap: pkMap, submissionMap: submissionMap,
        crewMap: crewMap, needsRecheck: needsRecheck,
      );
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
      _scheduleStatusMap = result.statusMap;
      _schedulePkMap = result.pkMap;
      _scheduleSubmissionMap = result.submissionMap;
      _scheduleCrewMap = result.crewMap;
      _scheduleNeedsRecheck = result.needsRecheck;
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
        _targetPreCheckMap = {
          for (final it in _items)
            if ((it['pre_check_status'] ?? '').toString().isNotEmpty)
              '${it['허가번호'] ?? ''}': '${it['pre_check_status']}',
        };
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
    setState(() {
      _detailLoading = true;
      _detailData = null;
      _detailLicenseNo = licenseNo;
      _sislPhotos = [];
      _sislNeosKey = null;
    });
    try {
      final data = await _svc.getDetail(_year, licenseNo);
      if (!mounted) return;
      setState(() { _detailData = data; _detailLoading = false; });
      // 사진은 메인 로드 끝나면 백그라운드 트리거
      _maybeLoadSislPhotos();
    } catch (_) {
      if (!mounted) return;
      setState(() => _detailLoading = false);
    }
  }

  /// 공대(NeOSCode) 추출 — target 우선, fallback 으로 callname_list 의 zpkcode.
  String _extractNeosCode() {
    final target = _detailData?['target'] as Map<String, dynamic>?;
    final fromTarget = (target?['공대'] ?? '').toString().trim();
    if (fromTarget.isNotEmpty) return fromTarget;
    final cl = _detailData?['callname_list'];
    if (cl is List) {
      for (final e in cl) {
        if (e is Map) {
          final v = (e['zpkcode'] ?? e['공대'] ?? '').toString().trim();
          if (v.isNotEmpty) return v;
        }
      }
    }
    return '';
  }

  Future<void> _maybeLoadSislPhotos() async {
    final neos = _extractNeosCode();
    if (neos.isEmpty) {
      setState(() { _sislPhotos = []; _sislNeosKey = null; });
      return;
    }
    if (_sislNeosKey == neos) return;
    _sislNeosKey = neos;
    setState(() => _sislLoading = true);
    try {
      final items = await _svc.listSislPhotos(neosCode: neos);
      if (!mounted) return;
      setState(() => _sislPhotos = items);
    } catch (_) {
      if (mounted) setState(() => _sislPhotos = []);
    } finally {
      if (mounted) setState(() => _sislLoading = false);
    }
  }

  Future<void> _cancelDsChange(int id, String label, String before, String after) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('변경 되돌리기', style: TextStyle(fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text('"$after" → "$before"',
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          const SizedBox(height: 10),
          const Text('워크플로우 상태는 변경되지 않습니다.',
              style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE17055), foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('되돌리기'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _svc.cancelDsChange(id);
      if (_detailLicenseNo != null) await _loadDetail(_detailLicenseNo!);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('되돌리기 실패: $e')));
    }
  }

  void _applyFilters() {
    // setState 없이 먼저 값 업데이트 → _loadAll의 setState로 한 번만 리빌드
    _aHdqt = _pHdqt; _aTeam = _pTeam; _aSearch = _pSearch;
    _aScheduled = _pScheduled;
    _aSchedWeek = _pSchedWeek;
    _aCrew = _pCrew;
    _statusFilters = List.from(_pStatusFilters);
    _aQuarters = List.from(_pQuarters);
    _aNationGroups = List.from(_pNationGroups);
    _aKcaResults = List.from(_pKcaResults);
    _page = 1;
    _selectedLicenseNos.clear();
    _loadAll();
  }

  void _resetFilters() {
    _pHdqt = _pTeam = _pSearch = _pScheduled = _pSchedWeek = _pCrew = '';
    _aHdqt = _aTeam = _aSearch = _aScheduled = _aSchedWeek = _aCrew = '';
    _pStatusFilters = []; _statusFilters = [];
    _pNationGroups = [];
    _pQuarters = []; _pKcaResults = [];
    _aQuarters = []; _aNationGroups = []; _aKcaResults = [];
    _searchCtrl.clear();
    _page = 1;
    _selectedLicenseNos.clear();
    _loadAll();
  }

  Future<void> _showSuccess(String msg) async {
    if (!mounted) return;
    final d = ProgressDialog(context);
    await d.complete(message: msg);
  }

  Future<void> _showError(String msg) async {
    if (!mounted) return;
    final d = ProgressDialog(context);
    await d.error(message: msg);
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
    final existingWeek = _extractScheduleWeek(item);
    final (initMonth, initWeek) = _parseWeekParts(existingWeek);

    final existingInspector = _extractScheduleText(item, '검사관');
    final existingJo = _extractScheduleText(item, '조');
    final inspectorCtrl = TextEditingController(text: existingInspector);
    final joCtrl = TextEditingController(text: existingJo);
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        int? selMonth = initMonth;
        int? selWeek = initWeek;
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
                TextField(
                  controller: joCtrl,
                  decoration: InputDecoration(
                    labelText: '조 (선택)',
                    hintText: '조 입력',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
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
                    ? () => Navigator.pop(ctx, {'month': selMonth!, 'week': selWeek!, '검사관': inspectorCtrl.text.trim(), '조': joCtrl.text.trim()})
                    : null,
                child: const Text('저장'),
              ),
            ],
          ),
        );
      },
    );
    joCtrl.dispose();
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
      await _showSuccess('일정이 저장되었습니다.');
      await Future.wait([
        _loadData(),
        if (_detailLicenseNo != null) _loadDetail(_detailLicenseNo!),
        _loadScheduledNos(),
      ]);
    } catch (e) {
      await _showError('저장 실패: $e');
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
      await _showSuccess('일정이 제거되었습니다.');
      await Future.wait([
        _loadData(),
        if (_detailLicenseNo != null) _loadDetail(_detailLicenseNo!),
        _loadScheduledNos(),
      ]);
    } catch (e) {
      await _showError('제거 실패: $e');
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
    // REGISTERED 상태인 일정만 사전점검 의뢰 대상
    final registeredSelected = scheduledSelected.where((item) {
      final no = '${item['허가번호'] ?? ''}';
      return (_scheduleStatusMap[no] ?? 'REGISTERED') == 'REGISTERED';
    }).toList();
    // REPORT_ISSUED 상태인 일정만 접수번호 일괄 입력 대상
    final reportIssuedSelected = scheduledSelected.where((item) {
      final no = '${item['허가번호'] ?? ''}';
      return (_scheduleStatusMap[no] ?? 'REGISTERED') == 'REPORT_ISSUED';
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
      if (registeredSelected.isNotEmpty) ...[
        const SizedBox(width: 8),
        ElevatedButton.icon(
          icon: const Icon(Icons.assignment_turned_in, size: 16),
          label: Text('${registeredSelected.length}건 사전점검 의뢰'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF6B47DC), foregroundColor: Colors.white,
            shape: btnShape, padding: btnPad,
          ),
          onPressed: () => _requestPreCheck(registeredSelected),
        ),
      ],
      if (reportIssuedSelected.isNotEmpty) ...[
        const SizedBox(width: 8),
        ElevatedButton.icon(
          icon: const Icon(Icons.confirmation_number_outlined, size: 16),
          label: Text('${reportIssuedSelected.length}건 접수번호 일괄 입력'),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0984E3), foregroundColor: Colors.white,
            shape: btnShape, padding: btnPad,
          ),
          onPressed: () => _bulkInputSubmission(reportIssuedSelected),
        ),
      ],
    ];
  }

  Future<void> _bulkInputSubmission(List<Map<String, dynamic>> items) async {
    final pks = items
        .map((it) => _schedulePkMap['${it['허가번호'] ?? ''}'] ?? '')
        .where((p) => p.isNotEmpty)
        .toList();
    if (pks.isEmpty) {
      await _showError('접수번호 입력 대상이 없습니다.');
      return;
    }
    await _promptBulkSubmission(
      schedulePks: pks,
      headline: '접수번호 일괄 입력',
      note: '선택한 ${pks.length}건 모두에 같은 접수번호가 적용됩니다.',
    );
  }

  Future<void> _requestPreCheck(List<Map<String, dynamic>> items) async {
    final pks = items
        .map((it) => _schedulePkMap['${it['허가번호'] ?? ''}'] ?? '')
        .where((p) => p.isNotEmpty)
        .toList();
    if (pks.isEmpty) {
      await _showError('사전점검 의뢰 대상이 없습니다.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('사전점검 의뢰', style: TextStyle(fontSize: 16)),
        content: Text(
            '선택한 ${pks.length}건을 품질개선팀에 사전점검 의뢰합니다.\n\n'
            '의뢰 후 상태가 [등록됨] → [사전점검중] 으로 변경됩니다.',
            style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF6B47DC), foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('의뢰'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final result = await _withLoading(
        '사전점검 의뢰 중... (${pks.length}건)',
        () => _svc.transitionStatusBulk(pks, 'PRE_CHECK', memo: '사전점검 의뢰'),
      );
      final succeeded = (result['succeeded'] as num?)?.toInt() ?? 0;
      final total = (result['total'] as num?)?.toInt() ?? pks.length;
      await _showSuccess('사전점검 의뢰 완료: $succeeded/$total건');
      setState(() => _selectedLicenseNos.clear());
      await _loadScheduledNos();
    } catch (e) {
      await _showError('의뢰 실패: $e');
    }
  }

  // 워크플로우 상태 배지
  Widget _buildStatusBadge(String? status) {
    final s = (status ?? 'REGISTERED').isEmpty ? 'REGISTERED' : status!;
    final (label, color) = switch (s) {
      'PRE_CHECKED' => ('사전점검완료', const Color(0xFF00897B)),
      'REGISTERED' => ('등록됨', const Color(0xFF6E7780)),
      'PRE_CHECK' => ('사전점검중', const Color(0xFF6B47DC)),
      'PRE_CHECK_DONE' => ('점검완료', const Color(0xFF1A8754)),
      'CHANGE_FILING' => ('변경개설중', const Color(0xFFE17055)),
      'RE_CHECK' => ('재점검대기', const Color(0xFFE17055)),
      'REPORT_ISSUED' => ('내역서발급', const Color(0xFF0984E3)),
      'SUBMITTED' => ('접수완료', const Color(0xFF0984E3)),
      'INSPECTED' => ('수검완료', const Color(0xFF2D3436)),
      _ => (s, const Color(0xFF6E7780)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }

  // ── 전산비교 화면 이동 ─────────────────────────────────────

  void _navigateToCompare() {
    final licenseNos = _selectedLicenseNos.toList();
    final accessValues = _items
        .where((item) => _selectedLicenseNos.contains('${item['허가번호'] ?? ''}'))
        .map((item) => (item['access담당'] as String? ?? '').trim())
        .where((v) => v.isNotEmpty)
        .toList();
    final counter = <String, int>{};
    for (final v in accessValues) counter[v] = (counter[v] ?? 0) + 1;
    final dominantAccess = counter.isEmpty ? null
        : counter.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final multiDivision = counter.keys.length > 1;

    // schedule pk 매핑 (있는 것만)
    final schedulePks = licenseNos
        .map((no) => _schedulePkMap[no] ?? '')
        .where((p) => p.isNotEmpty)
        .toList();

    // 통시/공대/zpprac1 맵 (일정화면에서 이미 로드된 값 전달)
    final schedMap = <String, Map<String, String>>{};
    for (final item in _items) {
      final no = '${item['허가번호'] ?? ''}';
      if (_selectedLicenseNos.contains(no)) {
        schedMap[no] = {
          '통시': '${item['통시'] ?? ''}',
          '공대': '${item['공대'] ?? ''}',
          'zpprac1': '${item['zpprac1'] ?? ''}',
          '호출명칭': '${item['호출명칭'] ?? ''}',
          '본부': '${item['skt본부'] ?? ''}',
        };
      }
    }

    setState(() => _selectedLicenseNos.clear());
    widget.onCompareNavigate?.call(
      licenseNos, dominantAccess, multiDivision,
      schedulePks: schedulePks.isEmpty ? null : schedulePks,
      schedMap: schedMap.isEmpty ? null : schedMap,
    );
  }

  Future<void> _showBulkUpsertDialog(List<Map<String, dynamic>> targetItems, String actionTitle) async {
    if (targetItems.isEmpty) return;

    final commonInspector = _resolveCommonScheduleText(targetItems, '검사관');
    final commonJo = _resolveCommonScheduleText(targetItems, '조');
    final commonWeek = _resolveCommonScheduleWeek(targetItems);
    final (initMonth, initWeek) = _parseWeekParts(commonWeek);
    final inspectorCtrl = TextEditingController(text: commonInspector);
    final joCtrl = TextEditingController(text: commonJo);
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) {
        int? selMonth = initMonth;
        int? selWeek = initWeek;
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
                TextField(
                  controller: joCtrl,
                  decoration: InputDecoration(
                    labelText: '조 (선택)',
                    hintText: '조 입력',
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
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
                    ? () => Navigator.pop(ctx, {'month': selMonth!, 'week': selWeek!, '검사관': inspectorCtrl.text.trim(), '조': joCtrl.text.trim()})
                    : null,
                child: const Text('저장'),
              ),
            ],
          ),
        );
      },
    );
    joCtrl.dispose();
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
      await _showSuccess('$successCount건 일정이 저장되었습니다.');
    } else {
      await _showError('$successCount건 저장, $failCount건 실패');
    }
  }

  String _extractScheduleText(Map<String, dynamic> item, String key) {
    final schedule = item['schedule'];
    if (schedule is Map) {
      final value = schedule[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString().trim();
      }
    }
    final directValue = item[key];
    if (directValue != null && directValue.toString().trim().isNotEmpty) {
      return directValue.toString().trim();
    }
    final licenseNo = '${item['허가번호'] ?? ''}'.trim();
    if (licenseNo.isNotEmpty) {
      for (final s in _schedules) {
        final no = '${s['허가번호'] ?? ''}'.trim();
        if (no != licenseNo) continue;
        final value = s[key];
        if (value != null && value.toString().trim().isNotEmpty) {
          return value.toString().trim();
        }
      }
    }
    return '';
  }

  String _extractScheduleWeek(Map<String, dynamic> item) {
    final fromSchedule = _extractScheduleText(item, '수검예정주차');
    if (fromSchedule.isNotEmpty) return fromSchedule;
    final licenseNo = '${item['허가번호'] ?? ''}'.trim();
    if (licenseNo.isNotEmpty) {
      final fromMap = _scheduleWeekMap[licenseNo]?.trim() ?? '';
      if (fromMap.isNotEmpty) return fromMap;
    }
    return '';
  }

  String _resolveCommonScheduleText(List<Map<String, dynamic>> items, String key) {
    final values = items
        .map((item) => _extractScheduleText(item, key))
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList();
    if (values.length == 1) return values.first;
    return '';
  }

  String _resolveCommonScheduleWeek(List<Map<String, dynamic>> items) {
    final values = items
        .map(_extractScheduleWeek)
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList();
    if (values.length == 1) return values.first;
    return '';
  }

  (int?, int?) _parseWeekParts(String weekText) {
    final match = RegExp(r'(\d+)월\s*(\d+)주차').firstMatch(weekText);
    if (match == null) return (null, null);
    return (
      int.tryParse(match.group(1)!),
      int.tryParse(match.group(2)!),
    );
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
      await _showSuccess('$successCount건 일정이 제거되었습니다.');
    } else {
      await _showError('$successCount건 제거, $failCount건 실패');
    }
  }

  Future<void> _exportExcel() async {
    // 본부 선택 다이얼로그 (최대 3개)
    final selected = await _showDivisionSelectDialog();
    if (selected == null || selected.isEmpty) return;

    // 선택한 본부로 필터 override (나머지 필터는 적용된 것 유지)
    final filters = Map<String, List<String>>.from(_activeFilters);
    filters['access담당'] = selected;
    // 선택 본부가 현재 화면 본부와 다르면 팀 필터는 무시 (팀 매칭 안 맞을 수 있음)
    if (selected.length > 1 || (selected.isNotEmpty && selected.first != _aHdqt)) {
      filters.remove('품질개선팀');
    }

    final dlg = ProgressDialog(context);
    try {
      dlg.show(message: 'Excel 다운로드 중...');
      final bytes = await _svc.exportXlsx(
        year: _year, sheet: _sheet,
        filters: filters,
        search: _aSearch,
        addr: _aSearch,
      );
      final blob = html.Blob([bytes],
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      final url = html.Url.createObjectUrlFromBlob(blob);
      final label = selected.length == 1 ? selected.first : '${selected.length}개본부';
      html.AnchorElement(href: url)
        ..setAttribute('download', '수검데이터_${label}_$_year년.xlsx')
        ..click();
      html.Url.revokeObjectUrl(url);
      await dlg.complete(message: 'Excel 다운로드 완료');
    } catch (e) {
      await dlg.error(message: 'Excel 다운로드 실패: $e');
    }
  }

  Future<List<String>?> _showDivisionSelectDialog() async {
    final initial = <String>{};
    if (_aHdqt.isNotEmpty) initial.add(_aHdqt);
    final selected = Set<String>.from(initial);
    const maxCount = 3;

    return showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          Widget selectChip(String label, bool isSelected, bool disabled, VoidCallback onTap) {
            return InkWell(
              onTap: disabled ? null : onTap,
              borderRadius: BorderRadius.circular(8),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected
                      ? _green.withOpacity(0.08)
                      : disabled ? Colors.grey.shade100 : Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected ? _green : Colors.grey.shade300,
                    width: isSelected ? 1.5 : 1,
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: isSelected ? _green : disabled ? Colors.grey.shade400 : Colors.black87,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            );
          }

          return AlertDialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 10),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.description_outlined, color: _green, size: 20),
                ),
                const SizedBox(width: 12),
                const Text('Excel 다운로드 옵션',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
            content: SizedBox(
              width: 500,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('본부 선택',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87)),
                        Row(
                          children: [
                            Text('최대 $maxCount개 (${selected.length}/$maxCount)',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: () => setS(() {
                                if (selected.length == _hdqts.length) {
                                  selected.clear();
                                } else {
                                  selected.clear();
                                  selected.addAll(_hdqts.take(maxCount));
                                }
                              }),
                              style: TextButton.styleFrom(
                                minimumSize: Size.zero,
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: Text(
                                selected.length == _hdqts.length ? '전체 해제' : '전체 선택',
                                style: TextStyle(fontSize: 12, color: _green, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _hdqts.map((h) {
                        final isSel = selected.contains(h);
                        final disabled = !isSel && selected.length >= maxCount;
                        return selectChip(h, isSel, disabled, () {
                          setS(() {
                            if (isSel) selected.remove(h); else selected.add(h);
                          });
                        });
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            actions: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, null),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Colors.grey.shade300),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text('취소',
                          style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: selected.isEmpty
                          ? null
                          : () => Navigator.pop(ctx, selected.toList()),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _green,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('다운로드 시작',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
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
          _showSuccess('$ok건이 수검 대상에 추가되었습니다 (검토여부: 대상 추가)');
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
        myHdqt: _myHdqt,
        myTeam: _myTeam,
        onConfirm: (schedulePks, sheetTitle) {
          Navigator.pop(ctx);
          _generateInspectionReport(schedulePks: schedulePks, sheetTitle: sheetTitle);
        },
      ),
    );
  }

  Future<void> _generateInspectionReport({
    required List<String> schedulePks,
    String sheetTitle = '',
  }) async {
    final dlg = ProgressDialog(context);
    bool downloaded = false;
    try {
      dlg.show(message: '검사내역서 생성 중...');
      final bytes = await _svc.generateInspectionReport(
        schedulePks: schedulePks,
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
      await dlg.complete(message: '검사내역서 다운로드 완료');
      downloaded = true;
    } catch (e) {
      await dlg.error(message: '검사내역서 생성 실패: $e');
    }
    if (!downloaded || !mounted) return;
    // 발급 직후 접수번호 일괄 입력 옵션 (스킵 가능 — 추후 일정 화면에서 일괄 입력도 가능)
    await _promptBulkSubmission(
      schedulePks: schedulePks,
      headline: '검사내역서 발급 완료',
      note: '전파관리소 접수가 완료됐다면 접수번호를 일괄로 입력할 수 있습니다.\n(나중에 일정 화면에서 다중 선택 → 일괄 입력도 가능)',
    );
    _loadData();  // workflow_status 변경 반영
  }

  /// 접수번호 일괄 입력 다이얼로그.
  /// schedulePks가 비어있으면 무동작. 사용자가 [건너뛰기]면 false 반환.
  Future<bool> _promptBulkSubmission({
    required List<String> schedulePks,
    String headline = '접수번호 일괄 입력',
    String note = '',
  }) async {
    if (schedulePks.isEmpty) return false;
    final ctrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(headline, style: const TextStyle(fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('대상: ${schedulePks.length}건',
              style: const TextStyle(fontSize: 12, color: Color(0xFF6E7780))),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(note,
                style: const TextStyle(fontSize: 11, color: Color(0xFF6E7780))),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '접수번호',
              hintText: '예: 2026-0123',
              helperText: '접수일은 입력한 시점으로 자동 기록됩니다.',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => Navigator.pop(ctx, true),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('건너뛰기'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (result != true) return false;
    final no = ctrl.text.trim();
    if (no.isEmpty) {
      await _showError('접수번호를 입력하세요.');
      return false;
    }
    try {
      final res = await _svc.submitInspectionBulk(
        schedulePks: schedulePks, submissionNo: no);
      final succeeded = res['succeeded'] as int? ?? 0;
      final total = res['total'] as int? ?? 0;
      await _showSuccess('접수번호 저장: $succeeded/$total건');
      _loadData();
      return true;
    } catch (e) {
      await _showError('저장 실패: $e');
      return false;
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
              tabs: const [Tab(text: '수검 대상 현황'), Tab(text: '매트릭스')],
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
        builder: (_, __) => _tabCtrl.index == 0 ? _buildFilterBar() : _buildMatrixFilterBar(),
      ),
      Expanded(
        child: TabBarView(
          controller: _tabCtrl,
          children: [_buildDataTab(), _buildMatrixTab()],
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
                Builder(builder: (_) {
                  // 조 필터는 클라이언트 사이드라 _total(서버 카운트)에 미반영.
                  // 조/상태/재점검/SLA 필터 활성 시 현재 페이지에서 필터된 건수를 표시.
                  final clientFiltered = _aCrew.isNotEmpty || _statusFilters.isNotEmpty
                      || _recheckOnly || _overdueOnly;
                  final shown = clientFiltered ? _filteredItems.length : _total;
                  final truncated = clientFiltered && _total > _items.length;
                  return Tooltip(
                    message: truncated
                        ? '서버 전체 ${_formatNumber(_total)}건 중 현재 페이지 ${_formatNumber(_items.length)}건만 클라이언트 필터 대상. 더 정확히 보려면 본부/팀/주차 필터를 먼저 좁혀주세요.'
                        : '서버 전체 ${_formatNumber(_total)}건',
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0F9FF),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFBAE6FD)),
                      ),
                      child: Text(
                        clientFiltered
                            ? '${_formatNumber(shown)}건 / 전체 ${_formatNumber(_total)}건'
                            : '${_formatNumber(_total)}건',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF0369A1))),
                    ),
                  );
                }),
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
                  onPressed: _navigateToCompare,
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
                  (v) => setState(() {
                    _pHdqt = v!;
                    _pTeam = '';
                    _pSchedWeek = '';
                    _pCrew = '';
                    _currentTeams = _orgMap[v] ?? [];
                  })),
              _filterDropdown('팀', _pTeam, ['', ..._currentTeams],
                  (v) => setState(() {
                    _pTeam = v!;
                    _pSchedWeek = '';
                    _pCrew = '';
                  })),
              _filterDropdown('일정등록', _pScheduled, const ['', 'Y', 'N'],
                  (v) => setState(() => _pScheduled = v ?? ''),
                  displayMap: const {'Y': '등록', 'N': '미등록'}),
              Builder(builder: (_) {
                // 주차 옵션 — 본부/팀 필터에 따라 좁혀짐
                final weeks = <String>{};
                for (final s in _schedules) {
                  if (_pHdqt.isNotEmpty &&
                      (s['access담당'] as String? ?? '').trim() != _pHdqt) continue;
                  if (_pTeam.isNotEmpty &&
                      (s['품질개선팀'] as String? ?? '').trim() != _pTeam) continue;
                  final w = (s['수검예정주차'] as String? ?? '').trim();
                  if (w.isNotEmpty) weeks.add(w);
                }
                final weekOptions = <String>['', ...weeks.toList()
                  ..sort((a, b) {
                    final na = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
                    final nb = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
                    return na.compareTo(nb);
                  })];
                return _filterDropdown('수검일정', _pSchedWeek, weekOptions,
                    (v) => setState(() {
                      _pSchedWeek = v ?? '';
                      _pCrew = '';
                    }));
              }),
              Builder(builder: (_) {
                // 조 옵션 — 현재 필터링된 schedules에서 distinct 수집
                final crews = <String>{};
                for (final s in _schedules) {
                  if (_pHdqt.isNotEmpty &&
                      (s['access담당'] as String? ?? '').trim() != _pHdqt) continue;
                  if (_pTeam.isNotEmpty &&
                      (s['품질개선팀'] as String? ?? '').trim() != _pTeam) continue;
                  if (_pSchedWeek.isNotEmpty &&
                      (s['수검예정주차'] as String? ?? '').trim() != _pSchedWeek) continue;
                  final c = (s['조'] as String? ?? '').trim();
                  if (c.isNotEmpty) crews.add(c);
                }
                final crewOptions = <String>['', ...crews.toList()..sort()];
                return _filterDropdown('조', _pCrew, crewOptions,
                    (v) => setState(() => _pCrew = v ?? ''));
              }),
              _buildMultiDropdown('밴드선택', _pNationGroups, _allNationGroups,
                  (v) => setState(() => _pNationGroups = v)),
              _buildMultiDropdown(
                '상태', _pStatusFilters,
                const ['미배정', 'REGISTERED', 'PRE_CHECKED', 'PRE_CHECK',
                       'PRE_CHECK_DONE', 'CHANGE_FILING', 'RE_CHECK',
                       'REPORT_ISSUED', 'SUBMITTED', 'INSPECTED'],
                (v) => setState(() => _pStatusFilters = v),
                displayMap: const {
                  '미배정': '미배정',
                  'REGISTERED': '등록됨',
                  'PRE_CHECKED': '사전점검완료',
                  'PRE_CHECK': '사전점검중',
                  'PRE_CHECK_DONE': '점검완료',
                  'CHANGE_FILING': '변경개설중',
                  'RE_CHECK': '재점검대기',
                  'REPORT_ISSUED': '내역서발급',
                  'SUBMITTED': '접수완료',
                  'INSPECTED': '수검완료',
                },
              ),
              StatefulBuilder(builder: (_, ss) => OutlinedButton.icon(
                icon: Icon(Icons.warning_amber_rounded, size: 14,
                    color: _recheckOnly ? Colors.white : const Color(0xFFE17055)),
                label: Text('재점검 필요', style: TextStyle(fontSize: 13,
                    color: _recheckOnly ? Colors.white : const Color(0xFFE17055))),
                style: OutlinedButton.styleFrom(
                  backgroundColor: _recheckOnly ? const Color(0xFFE17055) : Colors.white,
                  side: const BorderSide(color: Color(0xFFE17055)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onPressed: () {
                  setState(() { _recheckOnly = !_recheckOnly; _page = 1; _selectedLicenseNos.clear(); });
                  _loadAll();
                },
              )),
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
              _pHdqt = _pTeam = _pSearch = _pCrew = '';
              _aHdqt = _aTeam = _aSearch = _aCrew = '';
              _pNationGroups = [];
              _pQuarters = []; _pKcaResults = [];
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
      void Function(List<String>) onChanged, {Map<String, String>? displayMap}) {
    final hasVal = selected.isNotEmpty;
    final displayText = hasVal ? '$label (${selected.length})' : label;
    return GestureDetector(
      onTap: () async {
        final result = await showDialog<List<String>>(
          context: context,
          builder: (ctx) => _MultiSelectDialog(
            title: label, options: options, selected: selected,
            displayMap: displayMap,
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
        setState(() { _pHdqt = ''; _aHdqt = ''; _pTeam = ''; _aTeam = ''; _page = 1; _selectedLicenseNos.clear(); });
        _loadAll();
      });
    }
    if (_aTeam.isNotEmpty) {
      addChip('팀', _aTeam, () {
        setState(() { _pTeam = ''; _aTeam = ''; _page = 1; _selectedLicenseNos.clear(); });
        _loadAll();
      });
    }
    if (_aQuarters.isNotEmpty) {
      addChip('분기', _aQuarters.join(', '), () {
        setState(() { _pQuarters = []; _aQuarters = []; _page = 1; _selectedLicenseNos.clear(); });
        _loadAll();
      });
    }
    if (_aNationGroups.isNotEmpty) {
      addChip('밴드', _aNationGroups.join(', '), () {
        setState(() { _pNationGroups = []; _aNationGroups = []; _page = 1; _selectedLicenseNos.clear(); });
        _loadAll();
      });
    }
    if (_statusFilters.isNotEmpty) {
      const statusLabels = {
        '미배정': '미배정', 'REGISTERED': '등록됨', 'PRE_CHECKED': '사전점검완료',
        'PRE_CHECK': '사전점검중', 'PRE_CHECK_DONE': '점검완료',
        'CHANGE_FILING': '변경개설중', 'RE_CHECK': '재점검대기',
        'REPORT_ISSUED': '내역서발급', 'SUBMITTED': '접수완료', 'INSPECTED': '수검완료',
      };
      final label = _statusFilters.map((s) => statusLabels[s] ?? s).join(', ');
      addChip('상태', label, () {
        setState(() { _pStatusFilters = []; _statusFilters = []; _page = 1; _selectedLicenseNos.clear(); });
        _loadAll();
      });
    }
    if (_aKcaResults.isNotEmpty) {
      addChip('검토여부', _aKcaResults.join(', '), () {
        setState(() { _pKcaResults = []; _aKcaResults = []; _page = 1; _selectedLicenseNos.clear(); });
        _loadAll();
      });
    }
    if (_aSearch.isNotEmpty) {
      addChip('검색', _aSearch, () {
        setState(() { _pSearch = ''; _aSearch = ''; _searchCtrl.clear(); _page = 1; _selectedLicenseNos.clear(); });
        _loadAll();
      });
    }
    if (_aScheduled.isNotEmpty) {
      addChip('일정등록', _aScheduled == 'Y' ? '등록됨' : '미등록', () {
        setState(() { _pScheduled = ''; _aScheduled = ''; _page = 1; _selectedLicenseNos.clear(); });
        _loadAll();
      });
    }
    if (_aSchedWeek.isNotEmpty) {
      addChip('수검일정', _aSchedWeek, () {
        setState(() { _pSchedWeek = ''; _aSchedWeek = ''; _page = 1; _selectedLicenseNos.clear(); });
        _loadAll();
      });
    }
    if (_aCrew.isNotEmpty) {
      addChip('조', _aCrew, () {
        // 조는 클라이언트 필터라 API 재요청 불필요 (setState만으로 _filteredItems 재계산)
        setState(() { _pCrew = ''; _aCrew = ''; _selectedLicenseNos.clear(); });
      });
    }
    if (_recheckOnly) {
      addChip('재점검', '필요', () {
        setState(() { _recheckOnly = false; _page = 1; _selectedLicenseNos.clear(); });
        _loadAll();
      });
    }
    if (_overdueOnly) {
      addChip('SLA', '지연', () {
        setState(() { _overdueOnly = false; _page = 1; _selectedLicenseNos.clear(); });
        _loadAll();
      });
    }
    return Wrap(spacing: 6, runSpacing: 4, children: chips);
  }

  // ── 데이터 탭 ─────────────────────────────────────────

  Widget _buildDataTab() {
    if (_loading) return AppLoader.centered();
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

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [_buildColumnToggleButton()],
        ),
      ),
      Expanded(
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E7EB)),
            boxShadow: [
              BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
            ],
          ),
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final scale = _totalColWidth < constraints.maxWidth
                  ? constraints.maxWidth / _totalColWidth
                  : 1.0;
              return ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Column(
                  children: [
                    Container(
                      height: 44,
                      color: _primary.withValues(alpha: 0.12),
                      child: SingleChildScrollView(
                        controller: _hdrHorizCtrl,
                        scrollDirection: Axis.horizontal,
                        physics: const ClampingScrollPhysics(),
                        child: _buildCustomHeader(scale),
                      ),
                    ),
                    const Divider(height: 1, thickness: 1, color: Color(0xFFE5E7EB)),
                    Expanded(
                      child: Scrollbar(
                        controller: _horizontalScrollCtrl,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: _horizontalScrollCtrl,
                          scrollDirection: Axis.horizontal,
                          physics: const ClampingScrollPhysics(),
                          child: SizedBox(
                            width: _totalColWidth * scale,
                            child: ListView.builder(
                              itemCount: _filteredItems.length,
                              itemBuilder: (ctx, i) =>
                                  _buildCustomRow(_filteredItems[i], i, scale),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
      _buildPagination(),
    ]);
  }

  // 워크플로우 상태 필터 + 조 필터 + 재점검 필터 (클라이언트) 적용된 items
  List<Map<String, dynamic>> get _filteredItems {
    Iterable<Map<String, dynamic>> rows = _items;
    // 조 필터 (schedule 매핑 기반)
    if (_aCrew.isNotEmpty) {
      rows = rows.where((it) {
        final no = '${it['허가번호'] ?? ''}';
        return (_scheduleCrewMap[no] ?? '') == _aCrew;
      });
    }
    // 워크플로우 상태 필터 (서버 필터와 동일 조건 — 페이지 내 멱등 재적용)
    if (_statusFilters.isNotEmpty) {
      rows = rows.where((it) {
        final no = '${it['허가번호'] ?? ''}';
        return _statusFilters.any((f) {
          if (f == '미배정') return !_isScheduled(no);
          if (f == 'PRE_CHECKED') {
            return !_isScheduled(no) && (_targetPreCheckMap[no] ?? '').isNotEmpty;
          }
          if (!_isScheduled(no)) return false;
          return (_scheduleStatusMap[no] ?? 'REGISTERED') == f;
        });
      });
    }
    // 재점검 필요 (불합격/부적합 결과)
    if (_recheckOnly) {
      rows = rows.where((it) =>
          _scheduleNeedsRecheck.contains('${it['허가번호'] ?? ''}'));
    }
    return rows.toList();
  }

  Widget _buildScheduleCell(String licenseNo) {
    final week = _scheduleWeekMap[licenseNo] ?? '';
    final status = _scheduleStatusMap[licenseNo];
    final submission = _scheduleSubmissionMap[licenseNo] ?? '';
    if (week.isEmpty && status == null) {
      final preCheck = _targetPreCheckMap[licenseNo] ?? '';
      if (preCheck.isNotEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [_buildStatusBadge(preCheck)],
        );
      }
      return const SizedBox.shrink();
    }
    final showSubmission = status == 'SUBMITTED' && submission.isNotEmpty;
    final needsRecheck =
        status == 'INSPECTED' && _scheduleNeedsRecheck.contains(licenseNo);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (week.isNotEmpty)
          Text(week, style: const TextStyle(fontSize: 12, color: Color(0xFF2D3436)),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        if (status != null) ...[
          if (week.isNotEmpty) const SizedBox(height: 2),
          // SUBMITTED → 배지 옆에 접수번호 / INSPECTED+재점검 → 배지 옆에 재점검 칩 (셀 높이 제한 안 침범)
          showSubmission
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  _buildStatusBadge(status),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Tooltip(
                      message: '접수번호: $submission',
                      child: Text('#$submission',
                          style: const TextStyle(
                              fontSize: 10, color: Color(0xFF0984E3),
                              fontWeight: FontWeight.w600),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ])
              : needsRecheck
                  ? Row(mainAxisSize: MainAxisSize.min, children: [
                      _buildStatusBadge(status),
                      const SizedBox(width: 4),
                      Tooltip(
                        message: '검사 결과 합격이 아님 — 재점검 필요',
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE17055).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE17055), width: 1),
                          ),
                          child: const Text('재점검',
                              style: TextStyle(
                                  fontSize: 9, color: Color(0xFFE17055),
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ])
                  : _buildStatusBadge(status),
        ],
      ],
    );
  }

  Widget _buildRowCheckbox(Map<String, dynamic> item, String licenseNo, bool isChecked) {
    final scheduled = _isScheduled(licenseNo);

    // member: 일정 등록된 항목만 체크 가능 (전산비교 대상 선택용)
    if (!_isAdmin) {
      if (!scheduled) return const SizedBox(width: 24);
      // 본부 격리: 자기 본부 외 비활성
      if (!_isMyDivision(item)) {
        return Tooltip(
          message: '다른 본부의 국소입니다',
          child: Checkbox(value: false, activeColor: _blue, onChanged: null),
        );
      }
      return Checkbox(
        value: isChecked,
        activeColor: _blue,
        side: BorderSide(color: _blue.withValues(alpha: 0.6), width: 1.5),
        onChanged: (v) {
          setState(() {
            if (v == true) { _selectedLicenseNos.add(licenseNo); }
            else { _selectedLicenseNos.remove(licenseNo); }
          });
        },
      );
    }

    // 본부관리자: 본인 본부 외 항목 비활성화
    if (!_canManageItem(item)) {
      return Tooltip(
        message: '다른 본부의 국소입니다',
        child: Checkbox(value: false, activeColor: _primary, onChanged: null),
      );
    }

    // 이미 일정 등록된 항목: 파란 체크박스 (체크 가능, 수정/제거 대상 선택용)
    final color = scheduled ? _blue : _primary;
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

  // ── 수평 스크롤 동기화 ─────────────────────────────────────
  void _syncHdrScroll() {
    if (_hScrollSyncing || !_horizontalScrollCtrl.hasClients) return;
    _hScrollSyncing = true;
    _horizontalScrollCtrl.jumpTo(_hdrHorizCtrl.offset);
    _hScrollSyncing = false;
  }

  void _syncDataScroll() {
    if (_hScrollSyncing || !_hdrHorizCtrl.hasClients) return;
    _hScrollSyncing = true;
    _hdrHorizCtrl.jumpTo(_horizontalScrollCtrl.offset);
    _hScrollSyncing = false;
  }

  // ── 컬럼 너비 합계 ────────────────────────────────────────
  double get _totalColWidth => _kInspCols
      .where((c) => !_hiddenCols.contains(c.key))
      .fold(0.0, (sum, c) => sum + (_colWidths[c.key] ?? c.w));

  // ── 컬럼 표시/숨김 다이얼로그 ────────────────────────────
  void _showColumnDialog() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final hiddenCount = _hiddenCols.length;
          return Dialog(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: SizedBox(
              width: 280,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 헤더
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 18, 14, 12),
                    child: Row(
                      children: [
                        Container(
                          width: 32, height: 32,
                          decoration: BoxDecoration(
                            color: _primary.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(Icons.view_column_outlined, size: 17, color: _primary),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text('컬럼 표시 설정',
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                        ),
                        if (hiddenCount > 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF3F4F6),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('$hiddenCount 숨김',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.grey.shade600,
                                    fontWeight: FontWeight.w600)),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFFF3F4F6)),
                  // 컬럼 목록
                  ...(_kInspCols.where((c) => c.hideable).map((col) {
                    final isVisible = !_hiddenCols.contains(col.key);
                    return InkWell(
                      onTap: () {
                        setLocal(() {});
                        setState(() {
                          if (isVisible) {
                            _hiddenCols.add(col.key);
                          } else {
                            _hiddenCols.remove(col.key);
                          }
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
                        child: Row(
                          children: [
                            Icon(
                              isVisible ? Icons.check_circle : Icons.radio_button_unchecked,
                              size: 17,
                              color: isVisible ? _primary : Colors.grey.shade400,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(col.label,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: isVisible ? Colors.black87 : Colors.grey.shade500,
                                    fontWeight: isVisible ? FontWeight.w500 : FontWeight.w400,
                                  )),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: isVisible
                                    ? const Color(0xFFDCFCE7)
                                    : const Color(0xFFF3F4F6),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                isVisible ? '표시' : '숨김',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: isVisible
                                      ? const Color(0xFF16A34A)
                                      : Colors.grey.shade500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  })),
                  const Divider(height: 1, color: Color(0xFFF3F4F6)),
                  // 닫기
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                    child: SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: TextButton.styleFrom(
                          backgroundColor: const Color(0xFFF9FAFB),
                          foregroundColor: Colors.black87,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('닫기',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildColumnToggleButton() {
    final hiddenCount = _hiddenCols.length;
    return InkWell(
      onTap: _showColumnDialog,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.view_column_outlined, size: 15,
              color: Color(0xFF6B7280)),
          const SizedBox(width: 5),
          Text('컬럼',
              style: const TextStyle(fontSize: 12, color: Color(0xFF374151))),
          if (hiddenCount > 0) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('$hiddenCount 숨김',
                  style: TextStyle(fontSize: 10, color: _primary,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ]),
      ),
    );
  }

  // ── 커스텀 테이블 헤더 ────────────────────────────────────
  Widget _buildCustomHeader(double scale) {
    const hStyle = TextStyle(
        fontSize: 12, fontWeight: FontWeight.w700, color: Colors.black87);
    final visibleCols =
        _kInspCols.where((c) => !_hiddenCols.contains(c.key)).toList();
    return Row(
      children: visibleCols.asMap().entries.map((e) {
        final isLast = e.key == visibleCols.length - 1;
        final col = e.value;
        final w = (_colWidths[col.key] ?? col.w) * scale;
        final isSorted = _sortColIdx == col.si && col.si > 0;
        return SizedBox(
          width: w,
          height: 44,
          child: Stack(
            children: [
              if (col.key == '__chk')
                _buildHeaderCheckbox()
              else
                GestureDetector(
                  onTap: col.si > 0
                      ? () => _onScheduleSort(
                          col.si, _sortColIdx == col.si ? !_sortAsc : true)
                      : null,
                  child: Container(
                    width: w,
                    height: 44,
                    padding: const EdgeInsets.only(left: 8, right: 16),
                    alignment: Alignment.centerLeft,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(col.label, style: hStyle,
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (isSorted) ...[
                          const SizedBox(width: 2),
                          Icon(
                            _sortAsc
                                ? Icons.arrow_upward
                                : Icons.arrow_downward,
                            size: 11,
                            color: _primary,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              // 컬럼 구분선 (우측)
              if (!isLast)
                Positioned(
                  right: 8,
                  top: 10,
                  bottom: 10,
                  child: Container(
                      width: 1, color: const Color(0xFFD1D5DB)),
                ),
              // 열 너비 조절 핸들
              if (col.key != '__chk')
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    child: GestureDetector(
                      onHorizontalDragUpdate: (d) {
                        setState(() {
                          _colWidths[col.key] =
                              ((_colWidths[col.key] ?? col.w) + d.delta.dx / scale)
                                  .clamp(40.0, 480.0);
                        });
                      },
                      child: Container(
                          width: 8, color: Colors.transparent),
                    ),
                  ),
                ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _buildHeaderCheckbox() {
    final source = _filteredItems;
    final checkable = _isAdmin
        ? source
            .where((it) =>
                '${it['허가번호'] ?? ''}'.isNotEmpty && _canManageItem(it))
            .toList()
        : source
            .where((it) {
              final no = '${it['허가번호'] ?? ''}';
              return no.isNotEmpty && _isScheduled(no) && _isMyDivision(it);
            })
            .toList();
    final allChk = checkable.isNotEmpty &&
        checkable.every(
            (it) => _selectedLicenseNos.contains('${it['허가번호'] ?? ''}'));
    final someChk = !allChk &&
        checkable.any(
            (it) => _selectedLicenseNos.contains('${it['허가번호'] ?? ''}'));
    return Center(
      child: Checkbox(
        value: someChk ? null : allChk,
        tristate: true,
        activeColor: _isAdmin ? _primary : _blue,
        onChanged: checkable.isEmpty
            ? null
            : (v) {
                setState(() {
                  if (v == true) {
                    for (final it in checkable) {
                      final no = '${it['허가번호'] ?? ''}';
                      if (no.isNotEmpty) _selectedLicenseNos.add(no);
                    }
                  } else {
                    for (final it in checkable) {
                      _selectedLicenseNos.remove('${it['허가번호'] ?? ''}');
                    }
                  }
                });
              },
      ),
    );
  }

  // ── 커스텀 테이블 행 ─────────────────────────────────────
  Widget _buildCustomRow(Map<String, dynamic> item, int idx, double scale) {
    final licenseNo = '${item['허가번호'] ?? ''}';
    final isSelected = _detailLicenseNo == licenseNo;
    final isChecked = _selectedLicenseNos.contains(licenseNo);
    final visibleCols =
        _kInspCols.where((c) => !_hiddenCols.contains(c.key)).toList();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _loadDetail(licenseNo),
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: isSelected
                ? _primary.withValues(alpha: 0.06)
                : (idx.isEven ? const Color(0xFFFAFAFB) : Colors.white),
            border: const Border(
                bottom: BorderSide(color: Color(0xFFE5E7EB), width: 0.5)),
          ),
          child: Row(
            children: visibleCols.map((col) {
              final w = (_colWidths[col.key] ?? col.w) * scale;
              return SizedBox(
                width: w,
                height: 44,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: ClipRect(
                    child: OverflowBox(
                      minHeight: 0,
                      maxHeight: double.infinity,
                      alignment: Alignment.centerLeft,
                      child: _buildCellContent(
                          col.key, item, licenseNo, isChecked),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildCellContent(String key, Map<String, dynamic> item,
      String licenseNo, bool isChecked) {
    const cs = TextStyle(fontSize: 12, color: Color(0xFF374151));
    switch (key) {
      case '__chk':
        return _buildRowCheckbox(item, licenseNo, isChecked);
      case '__sched':
        return _buildScheduleCell(licenseNo);
      case '허가번호':
        return Text(licenseNo, style: cs);
      case '호출명칭':
        return Text('${item['호출명칭'] ?? ''}',
            style: cs.copyWith(fontWeight: FontWeight.w600),
            overflow: TextOverflow.ellipsis);
      case '부서':
        return Text(
            (item['부서'] as String? ?? '')
                .replaceFirst(RegExp(r'^\d+\.\s*'), ''),
            style: cs,
            overflow: TextOverflow.ellipsis);
      case '설치장소':
        return Text('${item['설치장소'] ?? ''}',
            style: cs, overflow: TextOverflow.ellipsis);
      case '도로명주소':
        return Text('${item['도로명주소'] ?? ''}',
            style: cs, overflow: TextOverflow.ellipsis);
      case '검사결과':
        return _buildResultChip('${item['검사결과'] ?? ''}',
            wfStatus: _scheduleStatusMap[licenseNo]);
      default:
        return Text('${item[key] ?? ''}',
            style: cs, overflow: TextOverflow.ellipsis);
    }
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

  Widget _buildResultChip(String val, {String? wfStatus}) {
    if (val.isEmpty) return const SizedBox.shrink();
    // Phase 4: 두 status 분리 — INSPECTED 미만에선 검사결과 숨김
    //   (워크플로우 상태가 없으면(미배정) 검사결과도 의미 없음 → 숨김)
    if (wfStatus != 'INSPECTED') return const SizedBox.shrink();
    Color color;
    if (val == '합격') { color = _green; }
    else if (val.startsWith('불합격')) { color = _primary; }
    else if (val.startsWith('부적합')) { color = _orange; }
    else { color = Colors.grey; }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Text(val, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
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
    if (_loading) {
      return AppLoader.centered();
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
          // 진도율 현황 카드
          if (_progressTotal > 0) ...[
            _buildProgressSection(),
            const SizedBox(height: 16),
          ],
          // 수검일정별 현황 카드 (필터 적용)
          if (_schedules.isNotEmpty) ...[
            _buildScheduleStatusSection(),
            const SizedBox(height: 16),
          ],
        ],
      ),
    );
  }

  // ── 진도율 현황 ──────────────────────────────────────────

  Widget _buildProgressSection() {
    final percent = _progressPercent;
    final color = percent >= 80
        ? const Color(0xFF43A047)
        : percent >= 50
            ? const Color(0xFFFF9800)
            : const Color(0xFFE53935);

    // 매트릭스 필터(본부/팀) 적용된 본부 목록만 표시
    final filteredByHdqt = _progressByHdqt.where((item) {
      if (_mHdqt.isNotEmpty && item['본부'] != _mHdqt) return false;
      return true;
    }).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 헤더
          Row(children: [
            const Icon(Icons.trending_up, size: 18, color: Color(0xFF374151)),
            const SizedBox(width: 6),
            const Text('진도율 현황', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${percent.toStringAsFixed(1)}%',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
              ),
            ),
            const Spacer(),
            Text(
              '$_progressCompleted건 / $_progressTotal건',
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            ),
          ]),
          const SizedBox(height: 10),
          // 전체 진도율 바
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: percent / 100,
              minHeight: 10,
              backgroundColor: Colors.grey.shade100,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          // 본부별 진도율
          if (filteredByHdqt.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: filteredByHdqt.map((item) {
                final hdqt = item['본부'] as String;
                final pct = (item['percent'] as num).toDouble();
                final total = item['total'] as int;
                final completed = item['completed'] as int;
                const c = Color(0xFF4A90D9);
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: c.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: c.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(hdqt, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF1F2937))),
                      const SizedBox(height: 3),
                      Text(
                        '$completed/$total (${pct.toStringAsFixed(1)}%)',
                        style: const TextStyle(fontSize: 13, color: c),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
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
      _selectedLicenseNos.clear();
    });
    _tabCtrl.animateTo(0);   // 새 탭 순서: 0=수검대상현황, 1=매트릭스
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

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 헤더
          Row(children: [
            const Icon(Icons.event_note_outlined, size: 18, color: Color(0xFF374151)),
            const SizedBox(width: 6),
            const Text('수검일정별 현황', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$totalFiltered건',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _primary),
              ),
            ),
            const Spacer(),
            Text(
              '건수 클릭 시 이동',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
            ),
          ]),

          // 네비게이션 바 (기본 모드에서만)
          if (isNavMode) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                _NavButton(
                  label: '이전달',
                  icon: Icons.chevron_left,
                  enabled: hasPrev,
                  onTap: hasPrev ? () => setState(() => _navMonth = prevMonth) : null,
                ),
                const SizedBox(width: 8),
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
                _NavButton(
                  label: '다음달',
                  icon: Icons.chevron_right,
                  iconRight: true,
                  enabled: hasNext,
                  onTap: hasNext ? () => setState(() => _navMonth = nextMonth) : null,
                ),
              ],
            ),
          ],

          const SizedBox(height: 14),
          Container(height: 1, color: const Color(0xFFF3F4F6)),
          const SizedBox(height: 14),

          // 카드 영역
          if (months.isEmpty)
            Text(
              weeks.isNotEmpty
                  ? '$_navMonth월에 등록된 일정이 없습니다.'
                  : '조건에 맞는 일정이 없습니다.',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
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
      ),
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
          ? AppLoader.centered()
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
    // 공중선별 한 줄 요약 (이득/기수 통합) + 장치별 라벨링 (설치대/형검/일련번호)
    final antennaSummary = _antennaSummary(dsAntennas);
    String installType = _fieldByDevice(dsAntennas, '공중선주 설치형태명');
    if (installType.isEmpty) {
      installType = _fieldByDevice(dsAntennas, '공중선주설치형태명');
    }
    final serialText = _fieldByDevice(dsDevices, '기기일련번호');
    final typeApprovalText = _fieldByDevice(dsDevices, '형식검정번호');
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
            if (facilityNames.isNotEmpty || serialText.isNotEmpty) _infoRow(
              '일련번호 및 통합시설명칭',
              facilityNames.isNotEmpty ? facilityNames.join('\n') : serialText,
            ),
            if (antennaSummary.isNotEmpty) _infoRow('공중선', antennaSummary),
            if (installType.isNotEmpty) _infoRow('설치대', installType),
            if (typeApprovalText.isNotEmpty) _infoRow('형식검정번호', typeApprovalText),
            _infoRow('분기', target?['분기'] ?? ''),
            _infoRow('국종군', target?['국종군'] ?? ''),
            _infoRow('KCA검토결과', target?['kca검토결과'] ?? ''),

            ...() {
              final dsChanges = List<Map<String, dynamic>>.from(d['ds_changes'] ?? []);
              if (dsChanges.isEmpty) return <Widget>[];
              return [
                const SizedBox(height: 16),
                _sectionHeader('DS 변경이력', Icons.compare_arrows_rounded, const Color(0xFF1E88E5)),
                ...dsChanges.map((c) {
                  final field = c['필드명'] as String? ?? '';
                  final before = c['변경전값'] as String? ?? '';
                  final after = c['변경후값'] as String? ?? '';
                  final date = c['변경일자'] as String? ?? '';
                  final jn = c['장치번호'] as String? ?? '';
                  final id = c['id'] as int? ?? 0;
                  final cancelled = (c['cancelled'] ?? '0') == '1';
                  final label = jn.isNotEmpty ? '$field (장치$jn)' : field;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(
                          child: Text(label,
                              style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w600,
                                  color: cancelled ? const Color(0xFF9CA3AF) : const Color(0xFF374151),
                                  decoration: cancelled ? TextDecoration.lineThrough : null)),
                        ),
                        if (cancelled)
                          Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE17055).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: const Text('취소됨',
                                style: TextStyle(fontSize: 9, color: Color(0xFFE17055), fontWeight: FontWeight.w700)),
                          ),
                        if (date.isNotEmpty)
                          Text(() {
                            if (date.length == 6 && RegExp(r'^\d{6}$').hasMatch(date)) {
                              return '${date.substring(0, 2)}.${date.substring(2, 4)}.${date.substring(4, 6)}';
                            }
                            return date;
                          }(),
                          style: const TextStyle(fontSize: 10, color: Color(0xFF9CA3AF))),
                        if (!cancelled && _isAdmin && id > 0) ...[
                          const SizedBox(width: 6),
                          InkWell(
                            onTap: () => _cancelDsChange(id, label, before, after),
                            borderRadius: BorderRadius.circular(4),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Icon(Icons.undo, size: 11, color: Color(0xFFE17055)),
                                SizedBox(width: 2),
                                Text('되돌리기',
                                    style: TextStyle(fontSize: 9, color: Color(0xFFE17055), fontWeight: FontWeight.w600)),
                              ]),
                            ),
                          ),
                        ],
                      ]),
                      const SizedBox(height: 4),
                      Row(children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: cancelled ? Colors.grey.shade100 : const Color(0xFFFFEDED),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(before.isEmpty ? '(없음)' : before,
                                style: TextStyle(
                                    fontSize: 10,
                                    color: cancelled ? Colors.grey.shade500 : const Color(0xFFB91C1C),
                                    decoration: cancelled ? TextDecoration.lineThrough : null)),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(Icons.arrow_forward, size: 12, color: Color(0xFF9CA3AF)),
                        ),
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                            decoration: BoxDecoration(
                              color: cancelled ? Colors.grey.shade100 : const Color(0xFFECFDF5),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(after.isEmpty ? '(없음)' : after,
                                style: TextStyle(
                                    fontSize: 10,
                                    color: cancelled ? Colors.grey.shade500 : const Color(0xFF065F46),
                                    decoration: cancelled ? TextDecoration.lineThrough : null)),
                          ),
                        ),
                      ]),
                    ]),
                  );
                }),
              ];
            }(),

            // SKO-OCEAN 시설점검 사진 (사내망에서만 표시)
            ..._buildSislPhotoSection(),

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
                )).then((_) {
                  if (!mounted) return;
                  _loadData();
                  if (_detailLicenseNo != null) _loadDetail(_detailLicenseNo!);
                }),
              ),
            ),
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

  // SKO-OCEAN 사진 섹션. 로딩 중·사진 있을 때만 노출. 빈 응답은 카드 자체 숨김.
  List<Widget> _buildSislPhotoSection() {
    if (!_sislLoading && _sislPhotos.isEmpty) return const [];
    return [
      const SizedBox(height: 16),
      Row(children: [
        _sectionHeader('현장 점검 사진 (SKO-OCEAN)', Icons.photo_library_outlined, const Color(0xFF06B6D4)),
        if (_sislPhotos.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10, left: 4),
            child: Text('${_sislPhotos.length}장',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
          ),
      ]),
      if (_sislLoading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Center(child: SizedBox(width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))),
        )
      else ...[
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Icon(Icons.info_outline, size: 11, color: Colors.grey.shade500),
            const SizedBox(width: 3),
            Text('사진은 사내망에서만 표시됩니다',
                style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
          ]),
        ),
        LayoutBuilder(builder: (ctx, c) {
          final cols = c.maxWidth >= 360 ? 3 : 2;
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
              childAspectRatio: 1.0,
            ),
            itemCount: _sislPhotos.length,
            itemBuilder: (_, i) {
              final p = _sislPhotos[i];
              final url = (p['url'] ?? '').toString();
              final dt = (p['upload_date'] ?? '').toString();
              final label = dt.length == 8
                  ? '${dt.substring(0,4)}-${dt.substring(4,6)}-${dt.substring(6,8)}'
                  : dt;
              return _SchedSislPhotoTile(
                url: url,
                label: label,
                onTap: () => _showSchedSislPhotoViewer(i),
              );
            },
          );
        }),
      ],
    ];
  }

  void _showSchedSislPhotoViewer(int initialIndex) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) => _SchedSislPhotoViewer(
        items: _sislPhotos,
        initialIndex: initialIndex,
      ),
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

  /// 장치번호별로 값을 묶어 표시.
  /// - groupSep: 장치 간 구분자 (기본 줄바꿈)
  /// - innerSep: 같은 장치 내 여러 값 구분자 (기본 ' · ')
  /// - 장치가 1개뿐이면 라벨 생략하고 값만 innerSep로 연결
  String _fieldByDevice(List<dynamic> rows, String key,
      {String groupSep = '\n', String innerSep = ' · '}) {
    final byJn = <String, List<String>>{};
    final order = <String>[];
    for (final r in rows) {
      final m = r as Map<String, dynamic>;
      final jn = (m['장치번호']?.toString().trim() ?? '');
      final v  = (m[key]?.toString().trim() ?? '');
      if (v.isEmpty) continue;
      final bucket = byJn.putIfAbsent(jn, () {
        order.add(jn);
        return <String>[];
      });
      if (!bucket.contains(v)) bucket.add(v);
    }
    if (byJn.isEmpty) return '';
    order.sort((a, b) {
      final ai = int.tryParse(a);
      final bi = int.tryParse(b);
      if (ai != null && bi != null) return ai.compareTo(bi);
      if (ai != null) return -1;
      if (bi != null) return 1;
      return a.compareTo(b);
    });
    if (order.length == 1) {
      return byJn[order.first]!.join(innerSep);
    }
    return order.map((jn) {
      final label = jn.isEmpty ? '장치' : '장치$jn';
      return '$label: ${byJn[jn]!.join(innerSep)}';
    }).join(groupSep);
  }

  /// 공중선 요약: (장치번호, 공중선일련번호) 단위로
  ///   "장치1 · #ANT001  기2 / 이득 13.5"
  /// 형태 한 줄씩. 장치/공중선 단일이면 라벨 자동 축약.
  String _antennaSummary(List<dynamic> list) {
    final groups = <String, _SchedAntGroup>{};
    final orderKeys = <String>[];
    for (final r in list) {
      final m = r as Map<String, dynamic>;
      final jn   = (m['장치번호']?.toString().trim() ?? '');
      final sn   = (m['공중선일련번호']?.toString().trim() ?? '');
      final gi   = (m['기']?.toString().trim() ?? '');
      final gain = (m['이득']?.toString().trim() ?? '');
      if (jn.isEmpty && sn.isEmpty && gi.isEmpty && gain.isEmpty) continue;
      final key = '$jn|$sn';
      final g = groups.putIfAbsent(key, () {
        orderKeys.add(key);
        return _SchedAntGroup(jn: jn, sn: sn);
      });
      final pair = '$gi|$gain';
      if (!g.pairsKey.contains(pair)) {
        g.pairsKey.add(pair);
        g.pairs.add(_SchedGainCount(gain: gain, count: gi));
      }
    }
    if (groups.isEmpty) return '';
    orderKeys.sort((a, b) {
      final ga = groups[a]!, gb = groups[b]!;
      final ai = int.tryParse(ga.jn);
      final bi = int.tryParse(gb.jn);
      if (ai != null && bi != null) {
        final c = ai.compareTo(bi);
        if (c != 0) return c;
      } else if (ai != null) {
        return -1;
      } else if (bi != null) {
        return 1;
      }
      return ga.sn.compareTo(gb.sn);
    });
    final distinctJn = groups.values.map((g) => g.jn).toSet();
    final singleDevice = distinctJn.length <= 1;
    return orderKeys.map((k) {
      final g = groups[k]!;
      final devLabel = singleDevice
          ? null
          : (g.jn.isEmpty ? '장치' : '장치${g.jn}');
      final snLabel = g.sn.isEmpty ? null : '#${g.sn}';
      final pairs = g.pairs.map((p) {
        final c = p.count.isEmpty ? '' : '기${p.count}';
        final v = p.gain.isEmpty ? '' : '이득 ${p.gain}';
        if (c.isEmpty && v.isEmpty) return '';
        if (c.isEmpty) return v;
        if (v.isEmpty) return c;
        return '$c / $v';
      }).where((s) => s.isNotEmpty).join(' · ');
      final head = [devLabel, snLabel].whereType<String>().join(' · ');
      if (head.isEmpty) return pairs;
      if (pairs.isEmpty) return head;
      return '$head  $pairs';
    }).join('\n');
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
  final Map<String, String>? displayMap;
  const _MultiSelectDialog({required this.title, required this.options, required this.selected, this.displayMap});

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
    final allSelected = widget.options.isNotEmpty && _selected.length == widget.options.length;
    final noneSelected = _selected.isEmpty;
    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // 아이콘 헤더
            Container(
              width: 52, height: 52,
              decoration: BoxDecoration(
                color: const Color(0xFFE53935).withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.filter_list_rounded,
                  color: Color(0xFFE53935), size: 26),
            ),
            const SizedBox(height: 12),
            Text(widget.title,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w800,
                    color: Color(0xFF111827))),
            const SizedBox(height: 16),
            // 옵션 리스트 (F9FAFB 배경 컨테이너)
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // 전체 선택/해제
                CheckboxListTile(
                  dense: true,
                  title: const Text('전체',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                          color: Color(0xFF374151))),
                  value: allSelected ? true : noneSelected ? false : null,
                  tristate: true,
                  activeColor: const Color(0xFF2563EB),
                  checkColor: Colors.white,
                  side: const BorderSide(color: Color(0xFFD1D5DB)),
                  onChanged: (v) => setState(() {
                    if (v == true) { _selected..clear()..addAll(widget.options); }
                    else { _selected.clear(); }
                  }),
                ),
                Divider(height: 1, color: Colors.grey.shade200),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 280),
                  child: ListView(
                    shrinkWrap: true,
                    children: widget.options.map((opt) => CheckboxListTile(
                      dense: true,
                      title: Text(widget.displayMap?[opt] ?? opt,
                          style: const TextStyle(fontSize: 13,
                              color: Color(0xFF374151))),
                      value: _selected.contains(opt),
                      activeColor: const Color(0xFF2563EB),
                      checkColor: Colors.white,
                      side: const BorderSide(color: Color(0xFFD1D5DB)),
                      onChanged: (v) => setState(() {
                        if (v == true) { _selected.add(opt); }
                        else { _selected.remove(opt); }
                      }),
                    )).toList(),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 20),
            // 적용 버튼 (전폭)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: () => Navigator.pop(context, _selected),
                child: const Text('적용',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
            // 취소 버튼
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('취소',
                  style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── 검사내역서 대상 선택 다이얼로그 ──────────────────────────

class _InspectionReportDialog extends StatefulWidget {
  final InspectionService svc;
  final int year;
  final Map<String, List<String>> orgMap;
  final List<String> hdqts;
  final String myHdqt;
  final String myTeam;
  final void Function(List<String> schedulePks, String sheetTitle) onConfirm;

  const _InspectionReportDialog({
    required this.svc,
    required this.year,
    required this.orgMap,
    required this.hdqts,
    required this.myHdqt,
    required this.myTeam,
    required this.onConfirm,
  });

  @override
  State<_InspectionReportDialog> createState() => _InspectionReportDialogState();
}

class _InspectionReportDialogState extends State<_InspectionReportDialog> {
  static const Color _blue = Color(0xFF1565C0);

  // 워크플로우 상태 코드 ↔ 표시명
  static const Map<String, String> _statusLabels = {
    'REGISTERED': '등록됨',
    'PRE_CHECK': '사전점검중',
    'PRE_CHECK_DONE': '점검완료',
    'CHANGE_FILING': '변경개설중',
    'RE_CHECK': '재점검대기',
    'REPORT_ISSUED': '내역서발급',
    'SUBMITTED': '접수완료',
    'INSPECTED': '수검완료',
  };

  // 필터 상태 (본부/팀/주차/조/상태)
  String _hdqt = '', _team = '', _week = '', _crew = '', _status = '';
  final _titleCtrl = TextEditingController();

  // 전체 schedules (한 번 로드 후 클라이언트 필터)
  List<Map<String, dynamic>> _allSchedules = [];

  // 목록 상태
  List<Map<String, dynamic>> _candidates = [];   // 좌측 후보 목록
  List<Map<String, dynamic>> _confirmed = [];    // 우측 선정 목록
  final _leftChecked = <String>{};   // 좌측 체크된 pk
  final _rightChecked = <String>{};  // 우측 체크된 pk
  bool _loading = false;

  // 드롭다운 옵션 — schedules에서 distinct 수집 (현재 필터 반영)
  List<String> get _hdqtOptions =>
      _distinctFrom(_allSchedules, 'access담당');
  List<String> get _teamOptions => _distinctFrom(
      _allSchedules.where((s) => _hdqt.isEmpty || _norm(s['access담당']) == _hdqt),
      '품질개선팀');
  List<String> get _weekOptions => _distinctFrom(
      _allSchedules.where((s) =>
          (_hdqt.isEmpty || _norm(s['access담당']) == _hdqt) &&
          (_team.isEmpty || _norm(s['품질개선팀']) == _team)),
      '수검예정주차');
  List<String> get _crewOptions => _distinctFrom(
      _allSchedules.where((s) =>
          (_hdqt.isEmpty || _norm(s['access담당']) == _hdqt) &&
          (_team.isEmpty || _norm(s['품질개선팀']) == _team) &&
          (_week.isEmpty || _norm(s['수검예정주차']) == _week)),
      '조');

  @override
  void initState() {
    super.initState();
    // 로그인 사용자 기준 본부/팀 자동 선택
    _hdqt = widget.myHdqt;
    _team = widget.myTeam;
    _loadAllSchedules();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  String _norm(dynamic v) => (v as String? ?? '').trim();

  List<String> _distinctFrom(Iterable<Map<String, dynamic>> rows, String key) {
    final s = <String>{};
    for (final r in rows) {
      final v = _norm(r[key]);
      if (v.isNotEmpty) s.add(v);
    }
    final list = s.toList()..sort();
    return list;
  }

  Future<void> _loadAllSchedules() async {
    setState(() => _loading = true);
    try {
      final items = await widget.svc.getSchedules(widget.year);
      setState(() => _allSchedules = items);
      _applyFilter();
    } catch (e) {
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _applyFilter() {
    final confirmedPks = _confirmed.map((e) => e['pk'] as String).toSet();
    final filtered = _allSchedules.where((s) {
      if (_hdqt.isNotEmpty && _norm(s['access담당']) != _hdqt) return false;
      if (_team.isNotEmpty && _norm(s['품질개선팀']) != _team) return false;
      if (_week.isNotEmpty && _norm(s['수검예정주차']) != _week) return false;
      if (_crew.isNotEmpty && _norm(s['조']) != _crew) return false;
      if (_status.isNotEmpty && _norm(s['workflow_status']) != _status) return false;
      return !confirmedPks.contains(s['pk']);
    }).toList();
    filtered.sort((a, b) => _norm(a['허가번호']).compareTo(_norm(b['허가번호'])));
    setState(() {
      _candidates = filtered;
      _leftChecked.clear();
    });
  }

  void _moveToRight() {
    if (_leftChecked.isEmpty) return;
    final moving = _candidates.where((e) => _leftChecked.contains(e['pk'])).toList();
    setState(() {
      _confirmed.addAll(moving);
      _candidates.removeWhere((e) => _leftChecked.contains(e['pk']));
      _leftChecked.clear();
    });
  }

  void _moveToLeft() {
    if (_rightChecked.isEmpty) return;
    setState(() {
      _confirmed.removeWhere((e) => _rightChecked.contains(e['pk']));
      _rightChecked.clear();
    });
    _applyFilter();   // 다시 필터에 맞으면 좌측에 복원, 아니면 사라짐
  }

  void _toggleLeft(String pk) => setState(() {
    if (_leftChecked.contains(pk)) _leftChecked.remove(pk);
    else _leftChecked.add(pk);
  });

  void _toggleRight(String pk) => setState(() {
    if (_rightChecked.contains(pk)) _rightChecked.remove(pk);
    else _rightChecked.add(pk);
  });

  void _selectAllLeft() => setState(() {
    if (_leftChecked.length == _candidates.length) {
      _leftChecked.clear();
    } else {
      _leftChecked.addAll(_candidates.map((e) => e['pk'] as String));
    }
  });

  void _selectAllRight() => setState(() {
    if (_rightChecked.length == _confirmed.length) {
      _rightChecked.clear();
    } else {
      _rightChecked.addAll(_confirmed.map((e) => e['pk'] as String));
    }
  });

  Widget _statusDropdown() {
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
          hint: const Text('상태', style: TextStyle(fontSize: 12)),
          value: _status.isEmpty ? null : _status,
          icon: const Icon(Icons.arrow_drop_down, size: 18),
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          style: const TextStyle(fontSize: 12, color: Colors.black87),
          items: [
            DropdownMenuItem(value: '', child: Text('전체', style: TextStyle(color: Colors.grey.shade500))),
            ..._statusLabels.entries.map((e) =>
                DropdownMenuItem(value: e.key, child: Text(e.value))),
          ],
          onChanged: (v) => setState(() => _status = v ?? ''),
        ),
      ),
    );
  }

  Widget _dropdown(String hint, String? value, List<String> items, ValueChanged<String?> onChanged) {
    // value가 옵션 밖이면 null로 안전화 (동적 옵션이라 발생 가능)
    final safeValue = (value == null || value.isEmpty || !items.contains(value)) ? null : value;
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
          value: safeValue,
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

  Widget _statusChip(String? status) {
    final s = (status ?? 'REGISTERED').isEmpty ? 'REGISTERED' : status!;
    final (label, color) = switch (s) {
      'REGISTERED' => ('등록됨', const Color(0xFF6E7780)),
      'PRE_CHECK' => ('사전점검중', const Color(0xFF6B47DC)),
      'PRE_CHECK_DONE' => ('점검완료', const Color(0xFF1A8754)),
      'CHANGE_FILING' => ('변경개설중', const Color(0xFFE17055)),
      'RE_CHECK' => ('재점검대기', const Color(0xFFE17055)),
      'REPORT_ISSUED' => ('내역서발급', const Color(0xFF0984E3)),
      'SUBMITTED' => ('접수완료', const Color(0xFF0984E3)),
      'INSPECTED' => ('수검완료', const Color(0xFF2D3436)),
      _ => (s, const Color(0xFF6E7780)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _itemTile(Map<String, dynamic> item, bool checked, VoidCallback onTap) {
    final no = item['허가번호'] as String? ?? '';
    final name = item['호출명칭'] as String? ?? '';
    final team = _norm(item['품질개선팀']);
    final week = _norm(item['수검예정주차']);
    final crew = _norm(item['조']);
    final inspector = _norm(item['검사관']);
    final status = _norm(item['workflow_status']);
    final meta = [team, week, crew, if (inspector.isNotEmpty) inspector]
        .where((s) => s.isNotEmpty).join(' · ');
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
              Row(children: [
                Expanded(
                  child: Text(name,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 6),
                _statusChip(status),
              ]),
              Text('$no  $meta',
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

          // ── ① 필터 패널 (본부/팀/주차/조/상태 + 적용) ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.grey.shade50,
            child: Row(children: [
              Expanded(child: _dropdown('본부', _hdqt, _hdqtOptions, (v) {
                setState(() {
                  _hdqt = v ?? '';
                  // 하위 옵션에 없는 값이면 초기화
                  if (_team.isNotEmpty && !_teamOptions.contains(_team)) _team = '';
                  if (_week.isNotEmpty && !_weekOptions.contains(_week)) _week = '';
                  if (_crew.isNotEmpty && !_crewOptions.contains(_crew)) _crew = '';
                });
              })),
              const SizedBox(width: 8),
              Expanded(child: _dropdown('팀', _team, _teamOptions, (v) {
                setState(() {
                  _team = v ?? '';
                  if (_week.isNotEmpty && !_weekOptions.contains(_week)) _week = '';
                  if (_crew.isNotEmpty && !_crewOptions.contains(_crew)) _crew = '';
                });
              })),
              const SizedBox(width: 8),
              Expanded(child: _dropdown('주차', _week, _weekOptions, (v) {
                setState(() {
                  _week = v ?? '';
                  if (_crew.isNotEmpty && !_crewOptions.contains(_crew)) _crew = '';
                });
              })),
              const SizedBox(width: 8),
              Expanded(child: _dropdown('조', _crew, _crewOptions, (v) {
                setState(() => _crew = v ?? '');
              })),
              const SizedBox(width: 8),
              Expanded(child: _statusDropdown()),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.check, size: 14),
                label: const Text('적용', style: TextStyle(fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _blue, foregroundColor: Colors.white,
                  minimumSize: const Size(70, 34),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
                onPressed: _applyFilter,
              ),
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
                          '${_candidates.length}건 / 전체 ${_allSchedules.length}건',
                          style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                        ),
                    ]),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _loading
                        ? AppLoader.centered()
                        : _candidates.isEmpty
                            ? Center(child: Text('필터 결과 없음 — [적용] 클릭',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade400)))
                            : ListView.builder(
                                itemCount: _candidates.length,
                                itemBuilder: (_, i) {
                                  final item = _candidates[i];
                                  final pk = item['pk'] as String? ?? '';
                                  return _itemTile(item, _leftChecked.contains(pk),
                                      () => _toggleLeft(pk));
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
                              final pk = item['pk'] as String? ?? '';
                              return _itemTile(item, _rightChecked.contains(pk),
                                  () => _toggleRight(pk));
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
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.download, size: 16),
                label: Text('검사내역서 발급 (${_confirmed.length}건)',
                    style: const TextStyle(fontSize: 13)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _confirmed.isEmpty ? Colors.grey.shade400 : _blue,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(160, 38),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
                onPressed: _confirmed.isEmpty ? null : () {
                  widget.onConfirm(
                    _confirmed.map((e) => e['pk'] as String).toList(),
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
                        ? AppLoader.centered()
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

// 안테나 그룹: (장치번호, 공중선일련번호) 단위로 (기, 이득) 짝 묶음
class _SchedAntGroup {
  final String jn;
  final String sn;
  final List<_SchedGainCount> pairs = [];
  final Set<String> pairsKey = {};
  _SchedAntGroup({required this.jn, required this.sn});
}

class _SchedGainCount {
  final String gain;
  final String count;
  _SchedGainCount({required this.gain, required this.count});
}

// SKO-OCEAN 사진 platform view 캐시 (inspection_schedule 화면 전용 namespace)
final Set<String> _schedSislRegistered = <String>{};

String _schedViewType(String url) {
  final last = url.split('/').last;
  return 'sched-sisl-${last.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '')}';
}

void _ensureSchedSislRegistered(String url, {String fit = 'cover'}) {
  final viewType = _schedViewType(url) + (fit == 'cover' ? '-cv' : '-ct');
  if (_schedSislRegistered.contains(viewType)) return;
  _schedSislRegistered.add(viewType);
  ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
    final wrap = html.DivElement()
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.overflow = 'hidden'
      ..style.backgroundColor = '#F3F4F6';
    final img = html.ImageElement()
      ..src = url
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.objectFit = fit
      ..style.display = 'block';
    img.onError.listen((_) {
      img.remove();
      final ph = html.DivElement()
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.display = 'flex'
        ..style.alignItems = 'center'
        ..style.justifyContent = 'center'
        ..style.color = '#9CA3AF'
        ..innerHtml = '<svg width="26" height="26" viewBox="0 0 24 24" fill="currentColor">'
            '<path d="M21 19V5c0-1.1-.9-2-2-2H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2zM8.5 13.5l2.5 3.01L14.5 12l4.5 6H5l3.5-4.5z"/>'
            '</svg>';
      wrap.append(ph);
    });
    wrap.append(img);
    return wrap;
  });
}

class _SchedSislPhotoTile extends StatelessWidget {
  final String url;
  final String label;
  final VoidCallback onTap;
  const _SchedSislPhotoTile({required this.url, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    _ensureSchedSislRegistered(url, fit: 'cover');
    final viewType = '${_schedViewType(url)}-cv';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Stack(fit: StackFit.expand, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: HtmlElementView(viewType: viewType),
        ),
        if (label.isNotEmpty)
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(6)),
              ),
              child: Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 9),
                  textAlign: TextAlign.center,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
      ]),
    );
  }
}

class _SchedSislPhotoViewer extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final int initialIndex;
  const _SchedSislPhotoViewer({required this.items, required this.initialIndex});

  @override
  State<_SchedSislPhotoViewer> createState() => _SchedSislPhotoViewerState();
}

class _SchedSislPhotoViewerState extends State<_SchedSislPhotoViewer> {
  late final PageController _ctrl;
  late int _idx;
  final Map<int, int> _rotations = {};
  final Map<int, TransformationController> _transforms = {};

  @override
  void initState() {
    super.initState();
    _idx = widget.initialIndex;
    _ctrl = PageController(initialPage: _idx);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    for (final t in _transforms.values) {
      t.dispose();
    }
    super.dispose();
  }

  TransformationController _txCtrl(int i) =>
      _transforms.putIfAbsent(i, () => TransformationController());

  void _rotateLeft() {
    setState(() {
      _rotations[_idx] = ((_rotations[_idx] ?? 0) - 1) % 4;
      if ((_rotations[_idx] ?? 0) < 0) _rotations[_idx] = _rotations[_idx]! + 4;
    });
  }

  void _rotateRight() {
    setState(() {
      _rotations[_idx] = ((_rotations[_idx] ?? 0) + 1) % 4;
    });
  }

  void _zoomIn() {
    final t = _txCtrl(_idx);
    final m = t.value.clone();
    if (m.getMaxScaleOnAxis() >= 5.0) return;
    m.scaleByDouble(1.4, 1.4, 1.0, 1.0);
    t.value = m;
  }

  void _zoomOut() {
    final t = _txCtrl(_idx);
    final m = t.value.clone();
    if (m.getMaxScaleOnAxis() <= 0.5) return;
    final s = 1 / 1.4;
    m.scaleByDouble(s, s, 1.0, 1.0);
    t.value = m;
  }

  void _resetTransform() {
    setState(() {
      _txCtrl(_idx).value = Matrix4.identity();
      _rotations[_idx] = 0;
    });
  }

  String _fmt(dynamic raw) {
    final s = (raw ?? '').toString();
    if (s.length == 8) {
      return '${s.substring(0,4)}-${s.substring(4,6)}-${s.substring(6,8)}';
    }
    return s;
  }

  void _downloadCurrent() {
    final item = widget.items[_idx];
    final url = (item['url'] ?? '').toString();
    if (url.isEmpty) return;
    final neos = (item['neos_code'] ?? '').toString();
    final dt = (item['upload_date'] ?? '').toString();
    final guid = (item['guid'] ?? '').toString();
    var ext = '.jpg';
    final lastDot = url.lastIndexOf('.');
    final lastSlash = url.lastIndexOf('/');
    if (lastDot > lastSlash) {
      final e = url.substring(lastDot).toLowerCase();
      if (e.length <= 5 && RegExp(r'^\.[a-z0-9]+$').hasMatch(e)) ext = e;
    }
    final fname = '${neos.isEmpty ? "sisl" : neos}_${dt.isEmpty ? "" : "${dt}_"}$guid$ext';

    final anchor = html.AnchorElement(href: url)
      ..download = fname
      ..target = '_blank'
      ..rel = 'noopener'
      ..style.display = 'none';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.items[_idx];
    final rotation = _rotations[_idx] ?? 0;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: Colors.transparent,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.75),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
          ),
          child: Row(children: [
            Text('${_idx + 1} / ${widget.items.length}',
                style: const TextStyle(color: Colors.white, fontSize: 13)),
            const SizedBox(width: 12),
            Flexible(
              child: Text('${_fmt(item['upload_date'])} · 분류 ${item['reg_cls']}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                  overflow: TextOverflow.ellipsis),
            ),
            const Spacer(),
            IconButton(
              tooltip: '닫기',
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
          ]),
        ),
        Flexible(
          child: Container(
            color: Colors.black,
            child: PageView.builder(
              controller: _ctrl,
              itemCount: widget.items.length,
              onPageChanged: (i) => setState(() => _idx = i),
              itemBuilder: (_, i) {
                final url = (widget.items[i]['url'] ?? '').toString();
                _ensureSchedSislRegistered(url, fit: 'contain');
                final viewType = '${_schedViewType(url)}-ct';
                final rot = _rotations[i] ?? 0;
                return InteractiveViewer(
                  transformationController: _txCtrl(i),
                  minScale: 0.5,
                  maxScale: 5.0,
                  child: RotatedBox(
                    quarterTurns: rot,
                    child: HtmlElementView(viewType: viewType),
                  ),
                );
              },
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.75),
            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            IconButton(tooltip: '왼쪽으로 회전',
                icon: const Icon(Icons.rotate_left, color: Colors.white, size: 22),
                onPressed: _rotateLeft, visualDensity: VisualDensity.compact),
            IconButton(tooltip: '오른쪽으로 회전',
                icon: const Icon(Icons.rotate_right, color: Colors.white, size: 22),
                onPressed: _rotateRight, visualDensity: VisualDensity.compact),
            IconButton(tooltip: '확대',
                icon: const Icon(Icons.zoom_in, color: Colors.white, size: 22),
                onPressed: _zoomIn, visualDensity: VisualDensity.compact),
            IconButton(tooltip: '축소',
                icon: const Icon(Icons.zoom_out, color: Colors.white, size: 22),
                onPressed: _zoomOut, visualDensity: VisualDensity.compact),
            IconButton(tooltip: '원래대로',
                icon: const Icon(Icons.restore, color: Colors.white, size: 22),
                onPressed: _resetTransform, visualDensity: VisualDensity.compact),
            IconButton(tooltip: '다운로드',
                icon: const Icon(Icons.download_rounded, color: Colors.white, size: 22),
                onPressed: _downloadCurrent, visualDensity: VisualDensity.compact),
            if (rotation != 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text('${rotation * 90}°',
                    style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ),
          ]),
        ),
      ]),
    );
  }
}

