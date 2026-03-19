import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../widgets/user_profile_button.dart';
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

  int _year = DateTime.now().year;
  String _sheet = 'all';

  // org-map 옵션
  Map<String, List<String>> _orgMap = {};
  List<String> _allQuarters = [];
  List<String> _allNationGroups = [];
  List<String> _allKcaResults = [];

  // pending 필터 (UI 선택 중)
  String _pHdqt = '', _pTeam = '', _pSearch = '';
  List<String> _pQuarters = [], _pNationGroups = [], _pKcaResults = [];

  // applied 필터 (실제 쿼리)
  String _aHdqt = '', _aTeam = '', _aSearch = '';
  List<String> _aQuarters = [], _aNationGroups = [], _aKcaResults = [];

  // 다중 선택 (일괄 일정 등록)
  final _selectedLicenseNos = <String>{};

  List<Map<String, dynamic>> _items = [];
  int _total = 0;
  int _page = 1;
  bool _loading = false;
  String? _error;

  Map<String, dynamic> _matrix = {};
  List<String> _quarters = [];

  Map<String, dynamic>? _detailData;
  String? _detailLicenseNo;
  bool _detailLoading = false;

  bool get _isAdmin {
    final role = context.read<AuthService>().userRoleStr;
    return role == 'admin' || role == 'manager';
  }

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
      _aNationGroups.isNotEmpty || _aKcaResults.isNotEmpty || _aSearch.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _svc = InspectionService()..setAuthToken(context.read<AuthService>().authToken);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadOrgMap();
      _loadAll();
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    await Future.wait([_loadData(), _loadSummary()]);
  }

  Future<void> _loadData() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await _svc.getData(
        year: _year, sheet: _sheet,
        filters: _activeFilters,
        search: _aSearch,
        page: _page, pageSize: 100,
      );
      setState(() {
        _items = List<Map<String, dynamic>>.from(res['items'] ?? []);
        _total = (res['total'] as num?)?.toInt() ?? 0;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _loadSummary() async {
    try {
      final res = await _svc.getSummary(year: _year, sheet: _sheet, filters: _activeFilters);
      setState(() {
        _matrix = Map<String, dynamic>.from(res['matrix'] ?? {});
        _quarters = List<String>.from(res['quarters'] ?? []);
      });
    } catch (_) {}
  }

  Future<void> _loadOrgMap() async {
    try {
      final res = await _svc.getOrgMap(_year);
      setState(() {
        _orgMap = {};
        final org = res['org'] as Map<String, dynamic>? ?? {};
        org.forEach((hdqt, teams) {
          _orgMap[hdqt] = List<String>.from(teams as List? ?? []);
        });
        _allQuarters = List<String>.from(res['quarters'] ?? []);
        _allNationGroups = List<String>.from(res['nation_groups'] ?? []);
        _allKcaResults = List<String>.from(res['kca_results'] ?? []);
      });
    } catch (_) {}
  }

  Future<void> _loadDetail(String licenseNo) async {
    setState(() { _detailLoading = true; _detailData = null; _detailLicenseNo = licenseNo; });
    try {
      final data = await _svc.getDetail(_year, licenseNo);
      setState(() => _detailData = data);
    } catch (_) {
    } finally {
      setState(() => _detailLoading = false);
    }
  }

  void _applyFilters() {
    setState(() {
      _aHdqt = _pHdqt; _aTeam = _pTeam; _aSearch = _pSearch;
      _aQuarters = List.from(_pQuarters);
      _aNationGroups = List.from(_pNationGroups);
      _aKcaResults = List.from(_pKcaResults);
      _page = 1;
    });
    _loadAll();
  }

  void _resetFilters() {
    setState(() {
      _pHdqt = _pTeam = _pSearch = '';
      _aHdqt = _aTeam = _aSearch = '';
      _pQuarters = []; _pNationGroups = []; _pKcaResults = [];
      _aQuarters = []; _aNationGroups = []; _aKcaResults = [];
      _searchCtrl.clear();
      _page = 1;
      _selectedLicenseNos.clear();
    });
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

  String _formatNumber(int n) => n.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');

  // ── Schedule 등록 ───────────────────────────────────────

  Future<void> _showScheduleDialog(Map<String, dynamic> item) async {
    final weekCtrl = TextEditingController(text: item['schedule']?['수검예정주차'] ?? '');
    final startCtrl = TextEditingController(text: item['schedule']?['수검시작일'] ?? '');
    final endCtrl = TextEditingController(text: item['schedule']?['수검종료일'] ?? '');
    final regionCtrl = TextEditingController(text: item['schedule']?['지역'] ?? '');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('수검 일정 등록',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${item['호출명칭'] ?? ''}\n${item['허가번호'] ?? ''}',
                style: const TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 16),
            _dialogField(weekCtrl, '수검예정주차', '예: 1월 3주차'),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _dialogField(startCtrl, '시작일', '20260119')),
              const SizedBox(width: 8),
              Expanded(child: _dialogField(endCtrl, '종료일', '20260123')),
            ]),
            const SizedBox(height: 10),
            _dialogField(regionCtrl, '지역', '예: 화성시'),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _svc.upsertSchedule({
        'year': _year,
        '허가번호': item['허가번호'],
        '호출명칭': item['호출명칭'] ?? '',
        '분기': item['분기'] ?? '',
        'skt본부': item['skt본부'] ?? '',
        'access담당': item['access담당'] ?? '',
        '품질개선팀': item['품질개선팀'] ?? '',
        '수검예정주차': weekCtrl.text,
        '수검시작일': startCtrl.text,
        '수검종료일': endCtrl.text,
        '지역': regionCtrl.text,
      });
      _showSnack('일정이 저장되었습니다.');
      if (_detailLicenseNo != null) await _loadDetail(_detailLicenseNo!);
    } catch (e) {
      _showSnack('저장 실패: $e', isError: true);
    }
  }

  Future<void> _showBulkScheduleDialog() async {
    final selectedItems = _items
        .where((item) => _selectedLicenseNos.contains(item['허가번호'] as String? ?? ''))
        .toList();
    if (selectedItems.isEmpty) return;

    final weekCtrl = TextEditingController();
    final startCtrl = TextEditingController();
    final endCtrl = TextEditingController();
    final regionCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('일괄 일정 등록 (${selectedItems.length}건)',
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
                Text('선택된 국소 (${selectedItems.length}건):',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                ...selectedItems.take(5).map((item) => Text(
                  '• ${item['호출명칭'] ?? ''} (${item['허가번호'] ?? ''})',
                  style: const TextStyle(fontSize: 12),
                )),
                if (selectedItems.length > 5)
                  Text('…외 ${selectedItems.length - 5}건',
                      style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ]),
            ),
            const SizedBox(height: 16),
            _dialogField(weekCtrl, '수검예정주차', '예: 1월 3주차'),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _dialogField(startCtrl, '시작일', '20260119')),
              const SizedBox(width: 8),
              Expanded(child: _dialogField(endCtrl, '종료일', '20260123')),
            ]),
            const SizedBox(height: 10),
            _dialogField(regionCtrl, '지역', '예: 화성시'),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    int successCount = 0, failCount = 0;
    for (final item in selectedItems) {
      try {
        await _svc.upsertSchedule({
          'year': _year,
          '허가번호': item['허가번호'],
          '호출명칭': item['호출명칭'] ?? '',
          '분기': item['분기'] ?? '',
          'skt본부': item['skt본부'] ?? '',
          'access담당': item['access담당'] ?? '',
          '품질개선팀': item['품질개선팀'] ?? '',
          '수검예정주차': weekCtrl.text,
          '수검시작일': startCtrl.text,
          '수검종료일': endCtrl.text,
          '지역': regionCtrl.text,
        });
        successCount++;
      } catch (_) {
        failCount++;
      }
    }
    setState(() => _selectedLicenseNos.clear());
    if (failCount == 0) {
      _showSnack('$successCount건 일정이 저장되었습니다.');
    } else {
      _showSnack('$successCount건 저장, $failCount건 실패', isError: true);
    }
  }

  Widget _dialogField(TextEditingController ctrl, String label, String hint) {
    return TextField(
      controller: ctrl,
      decoration: InputDecoration(
        labelText: label, hintText: hint,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: _buildAppBar(),
      body: Row(
        children: [
          Expanded(child: _buildMain()),
          if (_detailLicenseNo != null) _buildDetailPanel(),
        ],
      ),
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
      title: const Text('일정 및 통계',
          style: TextStyle(color: Colors.black87, fontSize: 18, fontWeight: FontWeight.w600)),
      bottom: TabBar(
        controller: _tabCtrl,
        labelColor: _primary,
        unselectedLabelColor: Colors.grey,
        indicatorColor: _primary,
        tabs: const [Tab(text: '수검 대상 현황'), Tab(text: '매트릭스')],
      ),
      actions: [
        UserProfileButton(onLogout: () => context.read<AuthService>().signOut()),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildMain() {
    return Column(children: [
      _buildFilterBar(),
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
    final hdqts = _orgMap.keys.toList()..sort();
    final teams = _pHdqt.isNotEmpty ? (_orgMap[_pHdqt] ?? <String>[]) : <String>[];

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: 연도, 시트, 검색창, 총건수, 일괄등록 버튼
          Row(children: [
            _yearDropdown(),
            const SizedBox(width: 10),
            _sheetDropdown(),
            const SizedBox(width: 12),
            SizedBox(
              width: 260,
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _pSearch = v),
                decoration: InputDecoration(
                  hintText: '호출명칭 또는 허가번호',
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 18),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onSubmitted: (_) => _applyFilters(),
              ),
            ),
            const Spacer(),
            if (_total > 0)
              Text('총 ${_formatNumber(_total)}건',
                  style: const TextStyle(fontSize: 13, color: Colors.black54)),
            if (_selectedLicenseNos.isNotEmpty) ...[
              const SizedBox(width: 12),
              ElevatedButton.icon(
                icon: const Icon(Icons.event_available, size: 16),
                label: Text('${_selectedLicenseNos.length}건 일정 등록'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _blue, foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                ),
                onPressed: _showBulkScheduleDialog,
              ),
            ],
          ]),
          const SizedBox(height: 10),
          // Row 2: 필터 드롭다운 + 적용/초기화
          Row(children: [
            _filterDropdown('본부', _pHdqt, ['', ...hdqts],
                (v) => setState(() { _pHdqt = v!; _pTeam = ''; })),
            const SizedBox(width: 8),
            _filterDropdown('팀', _pTeam, ['', ...teams],
                (v) => setState(() => _pTeam = v!)),
            const SizedBox(width: 8),
            _buildMultiDropdown('분기', _pQuarters, _allQuarters,
                (v) => setState(() => _pQuarters = v)),
            const SizedBox(width: 8),
            _buildMultiDropdown('밴드선택', _pNationGroups, _allNationGroups,
                (v) => setState(() => _pNationGroups = v)),
            const SizedBox(width: 8),
            _buildMultiDropdown('검토여부', _pKcaResults, _allKcaResults,
                (v) => setState(() => _pKcaResults = v)),
            const SizedBox(width: 12),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              ),
              onPressed: _applyFilters,
              child: const Text('적용', style: TextStyle(fontSize: 13)),
            ),
            const SizedBox(width: 8),
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
          ]),
          if (_hasActiveFilters) ...[
            const SizedBox(height: 8),
            _buildActiveFilterChips(),
          ],
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
          style: const TextStyle(color: Colors.black87, fontSize: 14),
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
          style: const TextStyle(color: Colors.black87, fontSize: 14),
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
      void Function(String?) onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: value.isNotEmpty ? _primary : Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          icon: Icon(Icons.arrow_drop_down,
              color: value.isNotEmpty ? _primary : Colors.grey, size: 20),
          dropdownColor: Colors.white,
          style: const TextStyle(color: Colors.black87, fontSize: 13),
          items: options
              .map((v) => DropdownMenuItem(
                    value: v,
                    child: Text(
                      v.isEmpty ? label : v,
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
        label: Text('$label: $val', style: const TextStyle(fontSize: 12)),
        backgroundColor: _primary.withValues(alpha: 0.08),
        deleteIcon: const Icon(Icons.close, size: 14),
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
    return Wrap(spacing: 6, runSpacing: 4, children: chips);
  }

  // ── 데이터 탭 ─────────────────────────────────────────

  Widget _buildDataTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('오류: $_error', style: const TextStyle(color: Colors.red)));
    if (_items.isEmpty) return const Center(
        child: Text('데이터 없음\nKCA 파일을 Import하세요',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.black38)));

    final allChecked = _items.isNotEmpty &&
        _items.every((item) => _selectedLicenseNos.contains(item['허가번호'] as String? ?? ''));
    final someChecked = !allChecked &&
        _items.any((item) => _selectedLicenseNos.contains(item['허가번호'] as String? ?? ''));

    return Column(children: [
      Expanded(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            child: DataTable(
              headingRowColor: WidgetStateProperty.all(Colors.grey.shade50),
              dataRowMinHeight: 40,
              dataRowMaxHeight: 44,
              columnSpacing: 16,
              showCheckboxColumn: false,
              columns: [
                DataColumn(label: Checkbox(
                  value: someChecked ? null : allChecked,
                  tristate: true,
                  activeColor: _primary,
                  onChanged: (v) {
                    setState(() {
                      if (v == true) {
                        for (final item in _items) {
                          final no = item['허가번호'] as String? ?? '';
                          if (no.isNotEmpty) _selectedLicenseNos.add(no);
                        }
                      } else {
                        for (final item in _items) {
                          _selectedLicenseNos.remove(item['허가번호'] as String? ?? '');
                        }
                      }
                    });
                  },
                )),
                const DataColumn(label: Text('호출명칭', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                const DataColumn(label: Text('분기', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                const DataColumn(label: Text('국종군', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                const DataColumn(label: Text('Access담당', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                const DataColumn(label: Text('품질개선팀', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                const DataColumn(label: Text('KCA검토결과', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                const DataColumn(label: Text('시기조정', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
              ],
              rows: _items.map((item) {
                final licenseNo = item['허가번호'] as String? ?? '';
                final isSelected = _detailLicenseNo == licenseNo;
                final isChecked = _selectedLicenseNos.contains(licenseNo);
                return DataRow(
                  selected: isSelected,
                  color: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) return _primary.withValues(alpha: 0.06);
                    return null;
                  }),
                  onSelectChanged: (_) => _loadDetail(licenseNo),
                  cells: [
                    DataCell(Checkbox(
                      value: isChecked,
                      activeColor: _primary,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) { _selectedLicenseNos.add(licenseNo); }
                          else { _selectedLicenseNos.remove(licenseNo); }
                        });
                      },
                    )),
                    DataCell(SizedBox(width: 200, child: Text(item['호출명칭'] ?? '', style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis))),
                    DataCell(Text(item['분기'] ?? '', style: const TextStyle(fontSize: 12))),
                    DataCell(Text(item['국종군'] ?? '', style: const TextStyle(fontSize: 12))),
                    DataCell(Text(item['access담당'] ?? '', style: const TextStyle(fontSize: 12))),
                    DataCell(Text(item['품질개선팀'] ?? '', style: const TextStyle(fontSize: 12))),
                    DataCell(_buildKcaChip(item['kca검토결과'] ?? '')),
                    DataCell(Text(item['시기조정'] ?? '', style: const TextStyle(fontSize: 12))),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
      _buildPagination(),
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

  Widget _buildPagination() {
    final totalPages = (_total / 100).ceil();
    if (totalPages <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton(icon: const Icon(Icons.chevron_left), onPressed: _page > 1 ? () { setState(() => _page--); _loadData(); } : null),
        Text('$_page / $totalPages', style: const TextStyle(fontSize: 13)),
        IconButton(icon: const Icon(Icons.chevron_right), onPressed: _page < totalPages ? () { setState(() => _page++); _loadData(); } : null),
      ]),
    );
  }

  // ── 매트릭스 탭 ──────────────────────────────────────

  Widget _buildMatrixTab() {
    if (_matrix.isEmpty) return const Center(child: Text('데이터 없음', style: TextStyle(color: Colors.black38)));
    final hdqts = _matrix.keys.toList()..sort();
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
      final teamMap = _matrix[hdqt] as Map<String, dynamic>? ?? {};
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
      child: Table(
        border: TableBorder.all(color: Colors.grey.shade200),
        defaultColumnWidth: const IntrinsicColumnWidth(),
        children: rows,
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
        border: Border(left: BorderSide(color: Colors.grey.shade200)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10)],
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
    final kisuList = dsAntennas.map((a) => a['기'] ?? '').where((v) => v.toString().isNotEmpty).toList();
    final gainList = dsAntennas.map((a) => a['이득'] ?? '').where((v) => v.toString().isNotEmpty).toList();
    final installTypeSet = dsAntennas.map((a) => a['공중선주설치형태명'] ?? '').where((v) => v.toString().isNotEmpty).toSet();
    final serialList = dsDevices.map((dv) => dv['기기일련번호'] ?? '').where((v) => v.toString().isNotEmpty).toList();

    final statusColor = result == null ? Colors.grey
        : result['status'] == '합격' ? _green
        : result['status'] == '불합격' ? _primary
        : _orange;
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
            if (gainList.isNotEmpty) _infoRow('이득(dB)', gainList.join('  ')),
            if (kisuList.isNotEmpty) _infoRow('기수', kisuList.join('  ')),
            if (installTypeSet.isNotEmpty) _infoRow('설치대', installTypeSet.join(', ')),
            if (serialList.isNotEmpty) _infoRow('기기일련번호', serialList.take(3).join('\n')),
            _infoRow('분기', target?['분기'] ?? ''),
            _infoRow('국종군', target?['국종군'] ?? ''),
            _infoRow('KCA검토결과', target?['kca검토결과'] ?? ''),

            const SizedBox(height: 16),
            _sectionHeader('수검 일정', Icons.calendar_month, _blue),
            if (schedule != null) ...[
              _infoRow('담당', '${target?['access담당'] ?? ''} / ${target?['품질개선팀'] ?? ''}'),
              _infoRow('예정주차', schedule['수검예정주차'] ?? ''),
              _infoRow('예정기간', '${schedule['수검시작일'] ?? ''} ~ ${schedule['수검종료일'] ?? ''}'),
              _infoRow('지역', schedule['지역'] ?? ''),
            ] else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text('일정 미등록', style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
              ),
            if (_isAdmin)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.edit_calendar, size: 16),
                  label: Text(schedule != null ? '일정 수정' : '일정 등록',
                      style: const TextStyle(fontSize: 13)),
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
            _buildResultSection(result),

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
          ]),
        ),
      ),
    ]);
  }

  Widget _scheduleTag(Map<String, dynamic> schedule) {
    final week = schedule['수검예정주차'] ?? '';
    final team = schedule['access담당'] ?? '';
    final region = schedule['지역'] ?? '';
    final label = [week, team, region].where((s) => s.isNotEmpty).join('_');
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

  Widget _buildResultSection(Map<String, dynamic>? result) {
    if (result == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('결과 미입력', style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _infoRow('상태', result['status'] ?? ''),
      _infoRow('검사일', result['검사일'] ?? ''),
      _infoRow('철탑형태', result['철탑형태'] ?? ''),
      if ((result['메모'] ?? '').isNotEmpty) _infoRow('특이사항', result['메모'] ?? ''),
    ]);
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
