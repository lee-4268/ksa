import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/excel_export_stub.dart'
    if (dart.library.io) '../services/excel_export_mobile.dart'
    if (dart.library.html) '../services/excel_export_web.dart' as platform_export;
import '../services/inspection_service.dart';
import '../widgets/app_loader.dart';
import '../widgets/progress_dialog.dart';

/// 본부 → 팀 목록 매핑
const _orgMap = <String, List<String>>{
  '강남': ['강남품질개선팀', '관악품질개선팀', '강동품질개선팀', '양천품질개선팀'],
  '강북': ['용산품질개선팀', '종로품질개선팀', '성수품질개선팀', '수유품질개선팀', '지하철품질개선팀'],
  '인천': ['북인천품질개선팀', '남인천품질개선팀', '부천품질개선팀', '일산품질개선팀', '남양주품질개선팀', '의정부품질개선팀'],
  '경기': ['하남품질개선팀', '평택품질개선팀', '수원품질개선팀', '분당품질개선팀', '용인품질개선팀'],
  '경남': ['동부산품질개선팀', '서부산품질개선팀', '김해품질개선팀', '울산품질개선팀', '진주품질개선팀', '창원품질개선팀'],
  '경북': ['동대구품질개선팀', '서대구품질개선팀', '경산품질개선팀', '포항품질개선팀', '안동품질개선팀', '구미품질개선팀'],
  '서부': ['서광주품질개선팀', '동광주품질개선팀', '목포품질개선팀', '순천품질개선팀', '제주품질개선팀', '전주품질개선팀', '군산품질개선팀'],
  '충청': ['대전품질개선팀', '천안품질개선팀', '세종품질개선팀', '서산품질개선팀', '서청주품질개선팀', '동청주품질개선팀', '충주품질개선팀'],
  '강원': ['원주품질개선팀', '춘천품질개선팀', '강릉품질개선팀'],
};

/// 부적합 관리 화면
class InadequateManagementScreen extends StatefulWidget {
  const InadequateManagementScreen({super.key});

  @override
  State<InadequateManagementScreen> createState() =>
      _InadequateManagementScreenState();
}

class _InadequateManagementScreenState extends State<InadequateManagementScreen> {
  static const Color primaryColor = Color(0xFFE53935);
  static const Color _border = Color(0xFFE5E7EB);
  static const Color _surfaceColor = Colors.white;
  static const Color _bgColor = Color(0xFFF5F6FA);

  late final InspectionService _svc;
  late bool _isAdmin;
  late bool _isSuperAdmin;
  late bool _isDivisionAdmin;
  late String _myRegion; 
  late String _myTeam;   

  int _year = DateTime.now().year;
  bool _loading = false;
  bool _syncing = false;
  bool _exporting = false;
  String? _error;

  int _totalCount = 0;
  int _incompleteCount = 0;
  int _completeCount = 0;
  int _excludedCount = 0;

  String _selectedRegion = '';
  String _selectedTeam = '';
  String _selectedStatus = '';

  List<Map<String, dynamic>> _items = [];
  int _page = 1;
  int _pageSize = 100;
  int _totalItems = 0;

  final Set<int> _checkedIds = {};
  String? _sortColumn;
  bool _sortAsc = true;
  int? _hoveredRowIndex;

  String _searchField = 'callname'; 
  String _searchValues = ''; 
  final TextEditingController _searchCtrl = TextEditingController();

  bool _isSummaryExpanded = false;

  static const _regionOptions = ['', '강남', '강북', '경기', '인천', '강원', '충청', '경북', '경남', '서부'];
  static const _statusOptions = ['', '미완료', '완료', '대상제외'];

  List<String> get _teamOptions {
    if (_selectedRegion.isEmpty) return [];
    return _orgMap[_selectedRegion] ?? [];
  }

  static const _columns = [
    ('본부', 'region'),
    ('팀', 'ons팀'),
    ('허가번호', '허가번호'),
    ('호출명칭', '호출명칭'),
    ('주소', '주소'),
    ('검사일자', '검사일자'),
    ('시정기한', '시정기한'),
    ('불합격내용', '불합격내용'),
    ('불합격상세', '불합격상세'),
    ('상태', 'status'),
    ('심의차수', '심의차수'),
  ];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthService>();
    _svc = InspectionService()..setAuthToken(auth.authToken);
    _isSuperAdmin = auth.isSuperAdmin;
    _isDivisionAdmin = auth.isDivisionAdmin;
    _isAdmin = _isSuperAdmin || _isDivisionAdmin;
    
    final dept = auth.userDepartment ?? '';
    _myRegion = dept.isNotEmpty ? (auth.currentDivisionShortName ?? '') : '';
    final rawTeam = auth.userTeam ?? '';
    _myTeam = (_myRegion.isNotEmpty && (_orgMap[_myRegion]?.contains(rawTeam) ?? false))
        ? rawTeam
        : '';
    _applyDefaultFilter();
    _loadData();
  }

  void _applyDefaultFilter() {
    if (_isSuperAdmin) return; 
    if (_myRegion.isNotEmpty) {
      _selectedRegion = _myRegion;
    }
    if (!_isDivisionAdmin && _myTeam.isNotEmpty) {
      _selectedTeam = _myTeam;
    }
  }

  Future<void> _loadData() async {
    setState(() { _loading = true; _error = null; _checkedIds.clear(); });
    try {
      final results = await Future.wait([
        _svc.getInadequateStats(_year, region: _selectedRegion, team: _selectedTeam),
        _svc.getInadequateList(
          _year,
          region: _selectedRegion,
          team: _selectedTeam,
          status: _selectedStatus,
          searchField: _searchValues.isNotEmpty ? _searchField : '',
          searchValues: _searchValues,
          page: _page,
          pageSize: _pageSize,
        ),
      ]);
      final stats = results[0];
      final listData = results[1];
      if (mounted) {
        setState(() {
          _totalCount = stats['total'] as int? ?? 0;
          _incompleteCount = stats['미완료'] as int? ?? 0;
          _completeCount = stats['완료'] as int? ?? 0;
          _excludedCount = stats['대상제외'] as int? ?? 0;
          _items = List<Map<String, dynamic>>.from(listData['items'] ?? []);
          _totalItems = listData['total'] as int? ?? 0;
          _loading = false;
          if (_sortColumn != null) _applySort();
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = '$e'; });
    }
  }

  void _applySort() {
    final col = _sortColumn!;
    _items.sort((a, b) {
      final va = (a[col] ?? '').toString();
      final vb = (b[col] ?? '').toString();
      final cmp = va.compareTo(vb);
      return _sortAsc ? cmp : -cmp;
    });
  }

  void _onSort(String col) {
    setState(() {
      if (_sortColumn == col) {
        _sortAsc = !_sortAsc;
      } else {
        _sortColumn = col;
        _sortAsc = true;
      }
      _applySort();
    });
  }

  Future<void> _doSync() async {
    setState(() => _syncing = true);
    final dialog = ProgressDialog(context);
    dialog.show(message: '데이터를 동기화하는 중...');
    try {
      await _svc.syncInadequate(_year);
      await dialog.complete(message: '동기화 완료');
      if (mounted) { _page = 1; _loadData(); }
    } catch (e) {
      await dialog.error(message: '동기화 실패: $e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _doExport() async {
    setState(() => _exporting = true);
    final dialog = ProgressDialog(context);
    dialog.show(message: 'Excel 파일 생성 중...');
    try {
      final bytes = await _svc.exportInadequateXlsx(
        _year,
        region: _selectedRegion,
        team: _selectedTeam,
        status: _selectedStatus,
        searchField: _searchValues.isNotEmpty ? _searchField : '',
        searchValues: _searchValues,
      );
      await dialog.complete(message: 'Excel 내보내기 완료');
      final suffix = [_selectedRegion, _selectedTeam, '$_year'].where((s) => s.isNotEmpty).join('_');
      await platform_export.saveExcelFile(bytes, '부적합관리_$suffix.xlsx');
    } catch (e) {
      await dialog.error(message: '엑셀 내보내기 실패: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      body: Column(
        children: [
          _buildHeader(),
          if (_error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.red.shade50,
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red.shade700, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_error!, style: TextStyle(color: Colors.red.shade700, fontSize: 13))),
                ],
              ),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSummaryCards(),
                  const SizedBox(height: 16),
                  _buildUnifiedToolbar(), // 반응형 툴바 적용
                  if (_isAdmin && _checkedIds.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _buildBulkActionBar(),
                  ],
                  const SizedBox(height: 8),
                  if (_loading)
                    Padding(
                      padding: const EdgeInsets.all(40.0),
                      child: AppLoader.centered(color: primaryColor),
                    )
                  else
                    _buildTable(),
                ],
              ),
            ),
          ),
          if (!_loading && _items.isNotEmpty) _buildPagination(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final isMobile = MediaQuery.of(context).size.width < 768;
    
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 16 : 24, 
        vertical: isMobile ? 12 : 16
      ),
      decoration: const BoxDecoration(
        color: _surfaceColor,
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.warning_amber_rounded, color: primaryColor, size: 22),
          ),
          const SizedBox(width: 12),
          Text(
            '부적합 관리',
            style: TextStyle(
              fontSize: isMobile ? 16 : 18, 
              fontWeight: FontWeight.bold, 
              color: const Color(0xFF111827)
            ),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: _exporting ? null : _doExport,
            icon: _exporting
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.file_download_outlined, size: 16),
            label: Text(isMobile ? '저장' : (_exporting ? '내보내는 중...' : 'Excel 저장')),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF059669),
              side: const BorderSide(color: Color(0xFF059669)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 10 : 16, vertical: 10),
              textStyle: TextStyle(fontSize: isMobile ? 12 : 13, fontWeight: FontWeight.w600),
            ),
          ),
          if (_isAdmin) ...[
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _syncing ? null : _doSync,
              icon: _syncing
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.sync, size: 16),
              label: Text(isMobile ? '동기화' : (_syncing ? '동기화 중...' : '동기화')),
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: EdgeInsets.symmetric(horizontal: isMobile ? 10 : 16, vertical: 10),
                textStyle: TextStyle(fontSize: isMobile ? 12 : 13, fontWeight: FontWeight.w600),
                elevation: 0,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummaryCards() {
    final isMobile = MediaQuery.of(context).size.width < 768;
    final cards = [
      _SummaryInfo('전체 데이터', _totalCount, const Color(0xFF4B5563), Icons.dataset_outlined),
      _SummaryInfo('미완료 건수', _incompleteCount, const Color(0xFFEF4444), Icons.pending_actions),
      _SummaryInfo('조치 완료', _completeCount, const Color(0xFF10B981), Icons.check_circle_outline),
      _SummaryInfo('대상 제외', _excludedCount, const Color(0xFF9CA3AF), Icons.do_not_disturb_alt),
    ];

    if (isMobile) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 4, offset: const Offset(0, 2))],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => setState(() => _isSummaryExpanded = !_isSummaryExpanded),
                  borderRadius: BorderRadius.circular(10),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Row(
                      children: [
                        const Icon(Icons.bar_chart, size: 18, color: Color(0xFF6B7280)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '전체 $_totalCount · 미완료 $_incompleteCount · 완료 $_completeCount · 제외 $_excludedCount',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(_isSummaryExpanded ? Icons.expand_less : Icons.expand_more, size: 22, color: const Color(0xFF9CA3AF)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_isSummaryExpanded) ...[
              const SizedBox(height: 10),
              Row(children: [_buildMobileCard(cards[0]), const SizedBox(width: 8), _buildMobileCard(cards[1])]),
              const SizedBox(height: 8),
              Row(children: [_buildMobileCard(cards[2]), const SizedBox(width: 8), _buildMobileCard(cards[3])]),
            ],
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: cards.map((c) {
          return Expanded(
            child: Container(
              margin: EdgeInsets.only(right: c == cards.last ? 0 : 12),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _border.withOpacity(0.5)),
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8, offset: const Offset(0, 2)),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: c.color.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(c.icon, color: c.color, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF6B7280))),
                        const SizedBox(height: 4),
                        Text(
                          '${c.count}건', 
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: c.color, letterSpacing: -0.5), 
                          overflow: TextOverflow.ellipsis
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  /// 명시적인 PC/모바일 반응형 툴바
  Widget _buildUnifiedToolbar() {
    final isMobile = MediaQuery.of(context).size.width < 768;
    
    final hint = switch (_searchField) {
      'license' => '허가번호 입력 (쉼표 구분)',
      'address' => '주소 입력 (쉼표 구분)',
      _ => '호출명칭 입력 (쉼표 구분)',
    };

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 20),
      child: Container(
        padding: EdgeInsets.all(isMobile ? 16 : 20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border.withOpacity(0.5)),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 6, offset: const Offset(0, 2)),
          ],
        ),
        child: isMobile ? _buildMobileToolbar(hint) : _buildDesktopToolbar(hint),
      ),
    );
  }

  /// PC용 가로 넓은 툴바 (기존 장점 복원)
  Widget _buildDesktopToolbar(String hint) {
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 16,
      children: [
        // 필터 영역
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.filter_list, size: 18, color: Color(0xFF6B7280)),
            const SizedBox(width: 8),
            _buildModernDropdown(
              width: 120,
              value: _selectedRegion,
              items: _regionOptions,
              hint: '본부 전체',
              onChanged: (v) {
                setState(() {
                  _selectedRegion = v ?? '';
                  _selectedTeam = ''; 
                  _page = 1;
                });
                _loadData();
              },
            ),
            const SizedBox(width: 8),
            _buildModernDropdown(
              width: 150,
              value: _selectedTeam,
              items: ['', ..._teamOptions],
              hint: '팀 전체',
              enabled: _selectedRegion.isNotEmpty,
              onChanged: (v) {
                setState(() { _selectedTeam = v ?? ''; _page = 1; });
                _loadData();
              },
            ),
            const SizedBox(width: 8),
            _buildModernDropdown(
              width: 120,
              value: _selectedStatus,
              items: _statusOptions,
              hint: '상태 전체',
              onChanged: (v) {
                setState(() { _selectedStatus = v ?? ''; _page = 1; });
                _loadData();
              },
            ),
          ],
        ),
        // 검색 영역 및 조회 건수
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildModernDropdown(
              width: 110,
              value: _searchField,
              items: const ['callname', 'license', 'address'],
              itemLabels: const {'callname': '호출명칭', 'license': '허가번호', 'address': '주소'},
              hint: '검색 기준',
              onChanged: (v) => setState(() => _searchField = v ?? 'callname'),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 260,
              height: 40,
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                  filled: true,
                  fillColor: const Color(0xFFF9FAFB), 
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: primaryColor, width: 1.5)),
                  suffixIcon: _searchCtrl.text.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.cancel, size: 16, color: Color(0xFF9CA3AF)),
                          onPressed: () {
                            _searchCtrl.clear();
                            if (_searchValues.isNotEmpty) {
                              setState(() { _searchValues = ''; _page = 1; });
                              _loadData();
                            }
                          },
                        )
                      : null,
                ),
                style: const TextStyle(fontSize: 13),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _doSearch(),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              height: 40,
              child: ElevatedButton(
                onPressed: _doSearch,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1F2937),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('검색', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(8)),
              child: Text('총 $_totalItems건', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF4B5563))),
            ),
          ],
        ),
      ],
    );
  }

  /// 모바일용 세로 툴바 (오버플로우 방지)
  Widget _buildMobileToolbar(String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _buildModernDropdown(
                width: double.infinity,
                value: _selectedRegion,
                items: _regionOptions,
                hint: '본부 전체',
                onChanged: (v) {
                  setState(() { _selectedRegion = v ?? ''; _selectedTeam = ''; _page = 1; });
                  _loadData();
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _buildModernDropdown(
                width: double.infinity,
                value: _selectedTeam,
                items: ['', ..._teamOptions],
                hint: '팀 전체',
                enabled: _selectedRegion.isNotEmpty,
                onChanged: (v) {
                  setState(() { _selectedTeam = v ?? ''; _page = 1; });
                  _loadData();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildModernDropdown(
          width: double.infinity,
          value: _selectedStatus,
          items: _statusOptions,
          hint: '상태 전체',
          onChanged: (v) {
            setState(() { _selectedStatus = v ?? ''; _page = 1; });
            _loadData();
          },
        ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 16),
          child: Divider(height: 1, color: Color(0xFFE5E7EB)),
        ),
        _buildModernDropdown(
          width: double.infinity,
          value: _searchField,
          items: const ['callname', 'license', 'address'],
          itemLabels: const {'callname': '호출명칭', 'license': '허가번호', 'address': '주소'},
          hint: '검색 기준',
          onChanged: (v) => setState(() => _searchField = v ?? 'callname'),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 40,
          child: TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
              filled: true,
              fillColor: const Color(0xFFF9FAFB), 
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 0),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: primaryColor)),
              suffixIcon: _searchCtrl.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.cancel, size: 16, color: Color(0xFF9CA3AF)),
                      onPressed: () {
                        _searchCtrl.clear();
                        if (_searchValues.isNotEmpty) {
                          setState(() { _searchValues = ''; _page = 1; });
                          _loadData();
                        }
                      },
                    )
                  : null,
            ),
            style: const TextStyle(fontSize: 13),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _doSearch(),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 40,
          child: ElevatedButton(
            onPressed: _doSearch,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1F2937),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('검색', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: Text('조회 결과: 총 $_totalItems건', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF6B7280))),
        ),
      ],
    );
  }

  void _doSearch() {
    final input = _searchCtrl.text.trim();
    setState(() {
      _searchValues = input;
      _page = 1;
    });
    _loadData();
  }

  Widget _buildModernDropdown({
    required double width,
    required String value,
    required List<String> items,
    Map<String, String>? itemLabels,
    required String hint,
    required ValueChanged<String?> onChanged,
    bool enabled = true,
  }) {
    return SizedBox(
      width: width,
      height: 40,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.5,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFF9FAFB),
            border: Border.all(color: const Color(0xFFE5E7EB)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              icon: const Icon(Icons.unfold_more, color: Color(0xFF9CA3AF), size: 16),
              dropdownColor: Colors.white,
              style: const TextStyle(color: Color(0xFF111827), fontSize: 13, fontWeight: FontWeight.w500),
              value: items.contains(value) ? value : items.first,
              borderRadius: BorderRadius.circular(10),
              items: items.map((r) {
                final label = itemLabels != null ? (itemLabels[r] ?? r) : r;
                return DropdownMenuItem(value: r, child: Text(r.isEmpty ? hint : label));
              }).toList(),
              onChanged: enabled ? onChanged : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTable() {
    final isMobile = MediaQuery.of(context).size.width < 768;

    if (_items.isEmpty) {
      return Container(
        height: 200,
        margin: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 20),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: _border)),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.inbox_outlined, size: 40, color: Color(0xFFD1D5DB)),
              SizedBox(height: 12),
              Text('조회된 데이터가 없습니다.', style: TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
            ],
          ),
        ),
      );
    }

    // flex weights (11 columns, total = 15.0)
    const colWeights = [0.8, 1.0, 1.5, 1.6, 2.4, 1.1, 1.1, 1.8, 2.2, 1.0, 0.5];
    const totalWeight = 15.0;
    const checkboxW = 44.0;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 20),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.01), blurRadius: 4, offset: const Offset(0, 1)),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(builder: (_, cst) {
          final tableW = cst.maxWidth;
          final flexW = tableW - (_isAdmin ? checkboxW : 0.0);
          final colWidths = List.generate(
            _columns.length,
            (i) => (flexW * colWeights[i] / totalWeight).clamp(40.0, double.infinity),
          );

          int ci = 0;
          final cwMap = <int, TableColumnWidth>{};
          if (_isAdmin) cwMap[ci++] = const FixedColumnWidth(checkboxW);
          for (int i = 0; i < _columns.length; i++) {
            cwMap[ci++] = FixedColumnWidth(colWidths[i]);
          }

          return Table(
            columnWidths: cwMap,
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: const TableBorder(
              horizontalInside: BorderSide(color: Color(0xFFF0F0F0), width: 0.5),
            ),
            children: [
              _buildFlexHeaderRow(),
              ..._items.asMap().entries.map((e) => _buildFlexDataRow(e.key, e.value)),
            ],
          );
        }),
      ),
    );
  }

  TableRow _buildFlexHeaderRow() {
    final cells = <Widget>[];

    if (_isAdmin) {
      cells.add(Container(
        height: 48,
        color: const Color(0xFFF3F4F6),
        alignment: Alignment.center,
        child: Checkbox(
          tristate: true,
          value: _checkedIds.isEmpty ? false : _checkedIds.length == _items.length ? true : null,
          activeColor: primaryColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          onChanged: (v) => setState(() {
            if (v == true) {
              _checkedIds.addAll(_items.map((e) => e['id'] as int));
            } else {
              _checkedIds.clear();
            }
          }),
        ),
      ));
    }

    for (final (label, field) in _columns) {
      final isSort = _sortColumn == field;
      cells.add(InkWell(
        onTap: () => _onSort(field),
        child: Container(
          height: 48,
          color: const Color(0xFFF3F4F6),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            Expanded(
              child: Text(label,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF374151)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              isSort
                  ? (_sortAsc ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded)
                  : Icons.unfold_more_rounded,
              size: 13,
              color: isSort ? primaryColor : const Color(0xFFD1D5DB),
            ),
          ]),
        ),
      ));
    }

    return TableRow(children: cells);
  }

  TableRow _buildFlexDataRow(int index, Map<String, dynamic> item) {
    final id = item['id'] as int;
    final checked = _checkedIds.contains(id);
    final hovered = _hoveredRowIndex == index;

    Color rowBg() {
      if (checked) return primaryColor.withValues(alpha: 0.08);
      if (hovered) return primaryColor.withValues(alpha: 0.04);
      return index.isEven ? Colors.white : const Color(0xFFFAFAFA);
    }

    Widget cell(Widget content, {bool checkboxCell = false}) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hoveredRowIndex = index),
        onExit: (_) {
          if (_hoveredRowIndex == index) setState(() => _hoveredRowIndex = null);
        },
        child: GestureDetector(
          onTap: checkboxCell
              ? () => setState(() {
                  if (checked) { _checkedIds.remove(id); } else { _checkedIds.add(id); }
                })
              : () => _showEditDialog(item),
          child: Container(
            height: 48,
            color: rowBg(),
            padding: checkboxCell ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 12),
            alignment: checkboxCell ? Alignment.center : Alignment.centerLeft,
            child: content,
          ),
        ),
      );
    }

    const ts = TextStyle(fontSize: 13, color: Color(0xFF111827));
    const tsAddr = TextStyle(fontSize: 13, color: Color(0xFF4B5563));
    const tsGray = TextStyle(fontSize: 13, color: Color(0xFF6B7280));
    const tsBold = TextStyle(fontSize: 13, color: Color(0xFF111827), fontWeight: FontWeight.w500);

    return TableRow(children: [
      if (_isAdmin)
        cell(
          Checkbox(
            value: checked,
            activeColor: primaryColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            onChanged: (v) => setState(() {
              if (v == true) { _checkedIds.add(id); } else { _checkedIds.remove(id); }
            }),
          ),
          checkboxCell: true,
        ),
      cell(Text(_str(item, 'region').isNotEmpty ? _str(item, 'region') : _str(item, 'skt본부'), overflow: TextOverflow.ellipsis, style: ts)),
      cell(Text(_str(item, 'ons팀'), overflow: TextOverflow.ellipsis, style: ts)),
      cell(Text(_str(item, '허가번호'), overflow: TextOverflow.ellipsis, style: ts)),
      cell(Text(_str(item, '호출명칭'), overflow: TextOverflow.ellipsis, style: tsBold)),
      cell(Text(_str(item, '주소'), overflow: TextOverflow.ellipsis, style: tsAddr)),
      cell(Text(_str(item, '검사일자'), style: ts)),
      cell(_buildDeadlineCell(item)),
      cell(Text(_str(item, '불합격내용'), overflow: TextOverflow.ellipsis, style: ts)),
      cell(Text(_str(item, '불합격상세'), overflow: TextOverflow.ellipsis, style: tsGray)),
      cell(_buildStatusChip(_str(item, 'status'))),
      cell(Text(_str(item, '심의차수'), style: tsBold)),
    ]);
  }

  Widget _buildDeadlineCell(Map<String, dynamic> item) {
    final deadline = _str(item, '시정기한');
    if (deadline.isEmpty) return const Text('-');
    bool overdue = false;
    try {
      final dt = DateTime.parse(deadline.replaceAll('.', '-').replaceAll('/', '-'));
      overdue = dt.isBefore(DateTime.now()) && _str(item, '상태') != '완료';
    } catch (_) {}
    return Text(
      deadline,
      style: TextStyle(
        color: overdue ? Colors.red : null,
        fontWeight: overdue ? FontWeight.bold : null,
        fontSize: 13,
      ),
    );
  }

  Widget _buildStatusChip(String status) {
    Color bg;
    Color fg;
    switch (status) {
      case '완료':
        bg = const Color(0xFFDCFCE7);
        fg = const Color(0xFF16A34A);
        break;
      case '대상제외':
        bg = const Color(0xFFF3F4F6);
        fg = const Color(0xFF6B7280);
        break;
      default:
        bg = const Color(0xFFFEE2E2);
        fg = const Color(0xFFDC2626);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(status.isEmpty ? '미완료' : status, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: fg)),
    );
  }

  Widget _buildPagination() {
    final totalPages = (_totalItems / _pageSize).ceil().clamp(1, 9999);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: _border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 24),
            onPressed: _page > 1 ? () { setState(() => _page--); _loadData(); } : null,
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(8)
            ),
            child: Text('$_page / $totalPages', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 24),
            onPressed: _page < totalPages ? () { setState(() => _page++); _loadData(); } : null,
          ),
        ],
      ),
    );
  }

  Widget _buildBulkActionBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: primaryColor.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: primaryColor.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: primaryColor,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${_checkedIds.length}건',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '선택됨',
              style: TextStyle(fontSize: 13, color: primaryColor, fontWeight: FontWeight.w500),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _showBulkEditDialog,
              icon: Icon(Icons.edit_outlined, size: 13, color: primaryColor),
              label: Text('일괄 처리', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: primaryColor)),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                backgroundColor: primaryColor.withValues(alpha: 0.12),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              onTap: () => setState(() => _checkedIds.clear()),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.close, size: 15, color: primaryColor.withValues(alpha: 0.5)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showBulkEditDialog() {
    String selectedStatus = '';
    final reviewCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, setDialogState) {
            final screenWidth = MediaQuery.of(context).size.width;
            
            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              elevation: 0,
              backgroundColor: Colors.white,
              child: Container(
                width: screenWidth < 500 ? screenWidth * 0.9 : 440,
                padding: EdgeInsets.all(screenWidth < 500 ? 16 : 24),
                child: SingleChildScrollView( 
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: primaryColor.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.checklist, size: 24, color: primaryColor),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('일괄 처리', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF111827))),
                                const SizedBox(height: 4),
                                Text('선택된 ${_checkedIds.length}건에 동일하게 적용됩니다', style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Divider(height: 1, color: Color(0xFFE5E7EB)),
                      ),
                      const Text('처리 상태', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
                      const SizedBox(height: 6),
                      const Text('변경 없음으로 두면 상태는 유지됩니다', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
                      const SizedBox(height: 10),
                      
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: ['', '미완료', '완료', '대상제외'].map((s) {
                          final isSelected = selectedStatus == s;
                          final label = s.isEmpty ? '변경 없음' : s;
                          return InkWell(
                            onTap: () => setDialogState(() => selectedStatus = s),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                              decoration: BoxDecoration(
                                color: isSelected ? (s.isEmpty ? const Color(0xFF374151) : primaryColor) : Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected ? (s.isEmpty ? const Color(0xFF374151) : primaryColor) : const Color(0xFFD1D5DB),
                                ),
                              ),
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  color: isSelected ? Colors.white : const Color(0xFF4B5563),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 24),
                      const Text('심의차수', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
                      const SizedBox(height: 6),
                      const Text('입력하지 않으면 심의차수는 유지됩니다', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
                      const SizedBox(height: 10),
                      TextField(
                        controller: reviewCtrl,
                        decoration: InputDecoration(
                          hintText: '예: 1차, 2차...',
                          hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                          filled: true,
                          fillColor: const Color(0xFFF9FAFB),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: primaryColor)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        ),
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 32),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                              foregroundColor: const Color(0xFF6B7280),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Text('취소', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primaryColor,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () async {
                              final ids = _checkedIds.toList();
                              final status = selectedStatus;
                              final review = reviewCtrl.text.trim();

                              if (status.isEmpty && review.isEmpty) {
                                Navigator.pop(ctx);
                                return;
                              }

                              Navigator.pop(ctx);

                              final dialog = ProgressDialog(context);
                              dialog.show(message: '${ids.length}건 처리 중...');
                              try {
                                await Future.wait(
                                  ids.map((id) => _svc.updateInadequate(
                                    id,
                                    status: status,
                                    reviewRound: review,
                                  )),
                                );
                                await dialog.complete(message: '${ids.length}건 처리 완료');
                                if (mounted) _loadData();
                              } catch (e) {
                                await dialog.error(message: '처리 실패: $e');
                              }
                            },
                            child: Text('${_checkedIds.length}건 저장', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showEditDialog(Map<String, dynamic> item) {
    if (!_isAdmin) return;

    String selectedStatus = (item['status'] ?? '미완료') as String;
    final reviewCtrl = TextEditingController(text: (item['심의차수'] ?? '') as String);

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, setDialogState) {
            final screenWidth = MediaQuery.of(context).size.width;

            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              elevation: 0,
              backgroundColor: Colors.white,
              child: Container(
                width: screenWidth < 500 ? screenWidth * 0.9 : 440,
                padding: EdgeInsets.all(screenWidth < 500 ? 16 : 24),
                child: SingleChildScrollView( 
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: primaryColor.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(Icons.edit_document, size: 24, color: primaryColor),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${item['호출명칭'] ?? item['허가번호'] ?? '정보 없음'}',
                                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF111827)),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '허가번호: ${item['허가번호'] ?? '-'}',
                                  style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Divider(height: 1, color: Color(0xFFE5E7EB)),
                      ),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF9FAFB),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFFE5E7EB)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildDialogInfoRow('불합격내용', item['불합격내용']?.toString() ?? '-'),
                            const SizedBox(height: 8),
                            _buildDialogInfoRow('불합격상세', item['불합격상세']?.toString() ?? '-'),
                            const SizedBox(height: 8),
                            _buildDialogInfoRow('시정기한', item['시정기한']?.toString() ?? '-'),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text('처리 상태', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
                      const SizedBox(height: 10),
                      
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: ['미완료', '완료', '대상제외'].map((s) {
                          final isSelected = selectedStatus == s;
                          return InkWell(
                            onTap: () => setDialogState(() => selectedStatus = s),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 18),
                              decoration: BoxDecoration(
                                color: isSelected ? primaryColor : Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: isSelected ? primaryColor : const Color(0xFFD1D5DB)),
                                boxShadow: isSelected
                                    ? [BoxShadow(color: primaryColor.withValues(alpha: 0.25), blurRadius: 4, offset: const Offset(0, 2))]
                                    : [],
                              ),
                              child: Text(
                                s,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  color: isSelected ? Colors.white : const Color(0xFF4B5563),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 24),
                      const Text('심의차수', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
                      const SizedBox(height: 10),
                      TextField(
                        controller: reviewCtrl,
                        decoration: InputDecoration(
                          hintText: '예: 1차, 2차...',
                          hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                          filled: true,
                          fillColor: const Color(0xFFF9FAFB),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: primaryColor),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        ),
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(height: 32),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                              foregroundColor: const Color(0xFF6B7280),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Text('취소', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primaryColor,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            onPressed: () async {
                              final id = item['id'] as int?;
                              if (id == null) return;
                              final dialog = ProgressDialog(context);
                              dialog.show(message: '저장 중...');
                              try {
                                await _svc.updateInadequate(
                                  id,
                                  status: selectedStatus,
                                  reviewRound: reviewCtrl.text.trim(),
                                );
                                await dialog.complete(message: '저장 완료');
                                if (mounted) { Navigator.pop(ctx); _loadData(); }
                              } catch (e) {
                                await dialog.error(message: '저장 실패: $e');
                              }
                            },
                            child: const Text('저장', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDialogInfoRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 70,
          child: Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
        ),
        Expanded(
          child: Text(value, style: const TextStyle(fontSize: 13, color: Color(0xFF111827), fontWeight: FontWeight.w500)),
        ),
      ],
    );
  }

  String _str(Map<String, dynamic> m, String key) => (m[key] ?? '').toString();

  Widget _buildMobileCard(_SummaryInfo c) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _border),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: c.color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
              child: Icon(c.icon, color: c.color, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.label, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                  const SizedBox(height: 2),
                  Text('${c.count}건', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.color), overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryInfo {
  final String label;
  final int count;
  final Color color;
  final IconData icon;
  const _SummaryInfo(this.label, this.count, this.color, this.icon);
}