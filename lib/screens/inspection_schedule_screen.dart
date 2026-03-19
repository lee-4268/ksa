import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../widgets/user_profile_button.dart';
import 'inspection_result_screen.dart';

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

  // 필터
  int _year = DateTime.now().year;
  String _sheet = 'all';
  final Map<String, List<String>> _filters = {};
  final Map<String, List<String>> _columnValues = {};
  final Set<String> _expandedFilters = {};
  final Map<String, String> _filterSearch = {};
  final List<String> _filterableCols = ['분기', '국종군', 'skt본부', 'access담당', '품질개선팀', 'kca검토결과'];
  String? _addingCol;

  // 데이터
  List<Map<String, dynamic>> _items = [];
  int _total = 0;
  int _page = 1;
  bool _loading = false;
  String? _error;

  // 매트릭스
  Map<String, dynamic> _matrix = {};
  List<String> _quarters = [];

  // 상세 패널
  Map<String, dynamic>? _detailData;
  String? _detailLicenseNo;
  bool _detailLoading = false;

  bool get _isAdmin {
    final role = context.read<AuthService>().userRoleStr;
    return role == 'admin' || role == 'manager';
  }

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _svc = InspectionService()..setAuthToken(context.read<AuthService>().authToken);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    await Future.wait([_loadData(), _loadSummary()]);
  }

  Future<void> _loadData() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await _svc.getData(
        year: _year, sheet: _sheet, filters: _filters, page: _page, pageSize: 100);
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
      final res = await _svc.getSummary(year: _year, sheet: _sheet, filters: _filters);
      setState(() {
        _matrix = Map<String, dynamic>.from(res['matrix'] ?? {});
        _quarters = List<String>.from(res['quarters'] ?? []);
      });
    } catch (_) {}
  }

  Future<void> _loadColumnValues(String col) async {
    if (_columnValues.containsKey(col)) return;
    try {
      final vals = await _svc.getColumnValues(_year, col, sheet: _sheet);
      setState(() => _columnValues[col] = vals);
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

  void _addFilter(String col) async {
    setState(() => _addingCol = null);
    await _loadColumnValues(col);
    setState(() {
      if (!_filters.containsKey(col)) _filters[col] = [];
      _expandedFilters.add(col);
    });
  }

  void _removeFilter(String col) {
    setState(() {
      _filters.remove(col);
      _columnValues.remove(col);
      _expandedFilters.remove(col);
      _filterSearch.remove(col);
    });
    _loadAll();
  }

  void _applyFilter() {
    setState(() { _page = 1; });
    _loadAll();
  }

  // ── Import ─────────────────────────────────────────────

  Future<void> _showImportDialog() async {
    // 파일 선택은 별도 구현 필요 (file_picker 패키지 사용 권장)
    // 여기서는 import 연도 입력 다이얼로그만 표시
    final yearCtrl = TextEditingController(text: '$_year');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('KCA 수검대상 파일 Import', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('KCA에서 받은 수검대상 Excel 파일을 업로드합니다.\n(복사본 2026년 정기검사...최종.xlsx 형식)', style: TextStyle(fontSize: 13, color: Colors.black54)),
          const SizedBox(height: 16),
          TextField(
            controller: yearCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '검사 연도',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('파일 선택 후 업로드'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final year = int.tryParse(yearCtrl.text) ?? _year;

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) { _showSnack('파일 데이터를 읽을 수 없습니다.', isError: true); return; }

    _showSnack('업로드 중... (${file.name})');
    try {
      final s3Key = await _svc.uploadRaw(file.bytes!, file.name);
      final auth = context.read<AuthService>();
      final jobId = await _svc.enqueue(s3Key, year, auth.userName ?? '');
      _showSnack('처리 중... 잠시 후 새로고침하세요. (jobId: $jobId)');
      // 폴링
      for (var i = 0; i < 60; i++) {
        await Future.delayed(const Duration(seconds: 5));
        final status = await _svc.jobStatus(jobId);
        if (status['status'] == 'done') {
          _showSnack('Import 완료!');
          setState(() { _year = year; _columnValues.clear(); });
          _loadAll();
          return;
        } else if (status['status'] == 'error') {
          _showSnack('Import 실패: ${status['error'] ?? ''}', isError: true);
          return;
        }
      }
      _showSnack('시간 초과 — 잠시 후 새로고침하세요.', isError: true);
    } catch (e) {
      _showSnack('오류: $e', isError: true);
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
        title: Text(
          '수검 일정 등록',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
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
      title: const Text('일정 및 통계', style: TextStyle(color: Colors.black87, fontSize: 18, fontWeight: FontWeight.w600)),
      bottom: TabBar(
        controller: _tabCtrl,
        labelColor: _primary,
        unselectedLabelColor: Colors.grey,
        indicatorColor: _primary,
        tabs: const [Tab(text: '수검 대상 현황'), Tab(text: '매트릭스')],
      ),
      actions: [
        if (_isAdmin)
          TextButton.icon(
            icon: const Icon(Icons.upload_file, size: 18),
            label: const Text('Import', style: TextStyle(fontSize: 13)),
            style: TextButton.styleFrom(foregroundColor: _primary),
            onPressed: _showImportDialog,
          ),
        const SizedBox(width: 8),
        UserProfileButton(
          onLogout: () => context.read<AuthService>().signOut(),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildMain() {
    return Column(children: [
      _buildControlBar(),
      _buildFilterChips(),
      Expanded(
        child: TabBarView(
          controller: _tabCtrl,
          children: [_buildDataTab(), _buildMatrixTab()],
        ),
      ),
    ]);
  }

  // ── 컨트롤바 (연도/시트/필터추가) ──────────────────────────

  Widget _buildControlBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(children: [
        // 연도 선택
        Container(
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
                setState(() { _year = v; _columnValues.clear(); });
                _loadAll();
              },
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 시트 선택
        Container(
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
                setState(() { _sheet = v; _columnValues.clear(); });
                _loadAll();
              },
            ),
          ),
        ),
        const Spacer(),
        // 총 건수
        if (_total > 0)
          Text('총 ${_total.toString().replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},')}건',
              style: const TextStyle(fontSize: 13, color: Colors.black54)),
        const SizedBox(width: 12),
        // 필터 추가
        _buildAddFilterButton(),
      ]),
    );
  }

  Widget _buildAddFilterButton() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: null,
          hint: Row(children: [
            Icon(Icons.add, size: 16, color: _primary),
            const SizedBox(width: 4),
            Text('필터 추가', style: TextStyle(fontSize: 13, color: _primary)),
          ]),
          isDense: true,
          icon: Icon(Icons.arrow_drop_down, color: _primary, size: 20),
          dropdownColor: Colors.white,
          style: const TextStyle(color: Colors.black87, fontSize: 13),
          items: _filterableCols
              .where((c) => !_filters.containsKey(c))
              .map((c) => DropdownMenuItem(value: c, child: Text(c)))
              .toList(),
          onChanged: (v) { if (v != null) _addFilter(v); },
        ),
      ),
    );
  }

  // ── 필터 칩 ────────────────────────────────────────────

  Widget _buildFilterChips() {
    if (_filters.isEmpty) return const SizedBox.shrink();
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _filters.keys.map((col) => _buildFilterGroup(col)).toList(),
      ),
    );
  }

  Widget _buildFilterGroup(String col) {
    final vals = _columnValues[col] ?? [];
    final selected = _filters[col] ?? [];
    final search = _filterSearch[col] ?? '';
    final expanded = _expandedFilters.contains(col);
    final filtered = vals.where((v) => search.isEmpty || v.toLowerCase().contains(search.toLowerCase())).toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade200),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(children: [
        // 헤더
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => expanded ? _expandedFilters.remove(col) : _expandedFilters.add(col)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(children: [
              Text(col, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              if (selected.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: _primary, borderRadius: BorderRadius.circular(10)),
                  child: Text('${selected.length}', style: const TextStyle(color: Colors.white, fontSize: 11)),
                ),
              const Spacer(),
              Icon(expanded ? Icons.expand_less : Icons.expand_more, size: 18, color: Colors.grey),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => _removeFilter(col),
                child: Icon(Icons.close, size: 16, color: Colors.grey.shade500),
              ),
            ]),
          ),
        ),
        if (expanded) ...[
          // 검색
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: TextField(
              onChanged: (v) => setState(() => _filterSearch[col] = v),
              decoration: InputDecoration(
                hintText: '검색...',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 16),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
            ),
          ),
          // 전체 선택
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Checkbox(
                value: selected.length == vals.length && vals.isNotEmpty ? true
                    : selected.isEmpty ? false : null,
                tristate: true,
                activeColor: _primary,
                onChanged: (v) {
                  setState(() {
                    if (v == true) _filters[col] = List.from(vals);
                    else _filters[col] = [];
                  });
                  _applyFilter();
                },
              ),
              const Text('전체', style: TextStyle(fontSize: 13)),
            ]),
          ),
          // 항목 목록
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView(
              shrinkWrap: true,
              children: filtered.map((v) {
                final checked = selected.contains(v);
                return InkWell(
                  onTap: () {
                    setState(() {
                      checked ? _filters[col]!.remove(v) : (_filters[col] ??= []).add(v);
                    });
                    _applyFilter();
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                    child: Row(children: [
                      Checkbox(value: checked, activeColor: _primary,
                          onChanged: (b) {
                            setState(() { b! ? (_filters[col] ??= []).add(v) : _filters[col]!.remove(v); });
                            _applyFilter();
                          }),
                      Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
                    ]),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ]),
    );
  }

  // ── 데이터 탭 ─────────────────────────────────────────

  Widget _buildDataTab() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('오류: $_error', style: const TextStyle(color: Colors.red)));
    if (_items.isEmpty) return const Center(child: Text('데이터 없음\nKCA 파일을 Import하세요', textAlign: TextAlign.center, style: TextStyle(color: Colors.black38)));

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
              columns: const [
                DataColumn(label: Text('호출명칭', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                DataColumn(label: Text('분기', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                DataColumn(label: Text('국종군', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                DataColumn(label: Text('Access담당', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                DataColumn(label: Text('품질개선팀', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                DataColumn(label: Text('KCA검토결과', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
                DataColumn(label: Text('시기조정', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
              ],
              rows: _items.map((item) {
                final isSelected = _detailLicenseNo == item['허가번호'];
                return DataRow(
                  selected: isSelected,
                  color: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) return _primary.withValues(alpha: 0.06);
                    return null;
                  }),
                  onSelectChanged: (_) => _loadDetail(item['허가번호'] as String? ?? ''),
                  cells: [
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
    if (val.contains('대상')) color = _green;
    else if (val.contains('진행')) color = _blue;
    else if (val.contains('X')) color = Colors.grey;
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
    final teams = _matrix.keys.toList()..sort();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Table(
        border: TableBorder.all(color: Colors.grey.shade200, borderRadius: BorderRadius.circular(8)),
        defaultColumnWidth: const IntrinsicColumnWidth(),
        children: [
          // 헤더
          TableRow(
            decoration: BoxDecoration(color: Colors.grey.shade100),
            children: [
              _matrixCell('팀', isHeader: true),
              ..._quarters.map((q) => _matrixCell(q, isHeader: true)),
              _matrixCell('합계', isHeader: true),
            ],
          ),
          // 데이터
          ...teams.map((team) {
            final row = _matrix[team] as Map<String, dynamic>? ?? {};
            final total = _quarters.fold<int>(0, (s, q) => s + ((row[q] as num?)?.toInt() ?? 0));
            return TableRow(children: [
              _matrixCell(team, isTeam: true),
              ..._quarters.map((q) => _matrixCell('${(row[q] as num?)?.toInt() ?? 0}')),
              _matrixCell('$total', isBold: true),
            ]);
          }),
        ],
      ),
    );
  }

  Widget _matrixCell(String text, {bool isHeader = false, bool isTeam = false, bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: (isHeader || isBold) ? FontWeight.w600 : FontWeight.normal,
          color: isHeader ? Colors.black54 : isTeam ? _primary : Colors.black87,
        ),
        textAlign: isTeam ? TextAlign.left : TextAlign.center,
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
      // 헤더
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
            // 기본 정보
            _sectionHeader('기본 정보', Icons.info_outline, const Color(0xFFE53935)),
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
            // 수검 일정
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
                  label: Text(schedule != null ? '일정 수정' : '일정 등록', style: const TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _blue,
                    side: BorderSide(color: _blue),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () => _showScheduleDialog({
                    ...?target, 'schedule': schedule,
                  }),
                ),
              ),

            const SizedBox(height: 16),
            // 수검 결과
            _sectionHeader('수검 결과', Icons.assignment_turned_in_outlined, _green),
            _buildResultSection(result),

            const SizedBox(height: 16),
            // 팀원 수검 관리 이동
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
