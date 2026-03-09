import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/ds_data_service.dart';
import '../services/erp_ds_compare_service.dart';

class ErpDsCompareScreen extends StatefulWidget {
  const ErpDsCompareScreen({super.key});

  @override
  State<ErpDsCompareScreen> createState() => _ErpDsCompareScreenState();
}

class _ErpDsCompareScreenState extends State<ErpDsCompareScreen> {
  static const _themeColor = Color(0xFF1565C0);

  // 본부 목록 (Auth 기준)
  static const _divisionOptions = [
    {'id': 'gangnam', 'name': '강남'},
    {'id': 'gangbuk', 'name': '강북'},
    {'id': 'gyeonggi', 'name': '경기'},
    {'id': 'incheon', 'name': '인천'},
    {'id': 'gangwon', 'name': '강원'},
    {'id': 'chungcheong', 'name': '충청'},
    {'id': 'gyeongbuk', 'name': '경북'},
    {'id': 'gyeongnam', 'name': '경남'},
    {'id': 'seobu', 'name': '서부'},
  ];

  final _service = ErpDsCompareService();
  final _dsService = DsDataService();
  final _inputCtrl = TextEditingController();

  int _step = 0; // 0: 설정+입력, 1: 결과
  String? _selectedDivisionId;
  List<DsUploadInfo> _dsUploads = [];
  DsUploadInfo? _selectedUpload;
  bool _loadingUploads = false;
  bool _comparing = false;
  String? _error;
  ErpDsCompareResult? _result;
  String _filter = '전체'; // 전체/일치/불일치/확인필요

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthService>();
      _service.setAuthToken(auth.authToken);
      _dsService.setAuthToken(auth.authToken);
      final divId = auth.currentDivisionId;
      if (divId != null) {
        setState(() => _selectedDivisionId = divId);
        _loadDsUploads(divId);
      }
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  String _getDsDivisionId(String authDivId) {
    return DsDataService.authToDsDivision[authDivId] ?? authDivId;
  }

  Future<void> _loadDsUploads(String authDivId) async {
    final dsDivId = _getDsDivisionId(authDivId);
    setState(() {
      _loadingUploads = true;
      _dsUploads = [];
      _selectedUpload = null;
    });
    try {
      final stats = await _dsService.getStats(divisionId: dsDivId);
      final completed =
          stats.uploads.where((u) => u.status == 'completed').toList();
      if (mounted) {
        setState(() {
          _dsUploads = completed;
          _selectedUpload = completed.isNotEmpty ? completed.first : null;
          _loadingUploads = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingUploads = false;
          _error = 'DS 업로드 조회 실패: $e';
        });
      }
    }
  }

  List<String> _parseZpwinoList() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return [];
    return text
        .split(RegExp(r'[\n,;]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
  }

  Future<void> _doCompare() async {
    final list = _parseZpwinoList();
    if (list.isEmpty) {
      setState(() => _error = '허가번호를 입력하세요.');
      return;
    }
    if (list.length > 500) {
      setState(() => _error = '최대 500건까지 비교 가능합니다.');
      return;
    }
    if (_selectedUpload == null) {
      setState(() => _error = 'DS 업로드를 선택하세요.');
      return;
    }
    setState(() {
      _comparing = true;
      _error = null;
    });
    try {
      final result = await _service.compare(
        zpwinoList: list,
        divisionId: _selectedUpload!.divisionId,
        divisionCode: _selectedUpload!.divisionCode,
        importDate: _selectedUpload!.actualDate,
      );
      if (mounted) {
        setState(() {
          _result = result;
          _step = 1;
          _comparing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _comparing = false;
        });
      }
    }
  }

  void _reset() {
    setState(() {
      _step = 0;
      _result = null;
      _filter = '전체';
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('전산자료 비교',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 18)),
        backgroundColor: _themeColor,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: _step == 0 ? _buildInputStep() : _buildResultStep(),
          ),
        ),
      ),
    );
  }

  // ── Step 0: 설정 + 입력 ──

  Widget _buildInputStep() {
    final zpwinoCount = _parseZpwinoList().length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 본부 선택
        _card(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _sectionTitle(Icons.business, '본부 선택'),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: _selectedDivisionId,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              items: _divisionOptions
                  .map((d) => DropdownMenuItem(
                      value: d['id'], child: Text(d['name']!)))
                  .toList(),
              onChanged: (val) {
                if (val != null) {
                  setState(() => _selectedDivisionId = val);
                  _loadDsUploads(val);
                }
              },
            ),
          ]),
        ),

        const SizedBox(height: 12),

        // DS 업로드 선택
        _card(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _sectionTitle(Icons.folder_open, 'DS 파일 선택'),
            const SizedBox(height: 8),
            if (_loadingUploads)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_dsUploads.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('해당 본부에 업로드된 DS 파일이 없습니다.',
                    style: TextStyle(color: Colors.grey)),
              )
            else
              DropdownButtonFormField<DsUploadInfo>(
                value: _selectedUpload,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
                items: _dsUploads.map((u) {
                  final label =
                      '${u.divisionName} - ${u.actualDate} (${u.totalRows}행)';
                  return DropdownMenuItem(value: u, child: Text(label));
                }).toList(),
                onChanged: (val) => setState(() => _selectedUpload = val),
              ),
          ]),
        ),

        const SizedBox(height: 12),

        // 허가번호 입력
        _card(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              _sectionTitle(Icons.input, '허가번호 입력'),
              const Spacer(),
              Text('$zpwinoCount / 500건',
                  style: TextStyle(
                    fontSize: 12,
                    color: zpwinoCount > 500 ? Colors.red : Colors.grey,
                    fontWeight: FontWeight.w500,
                  )),
            ]),
            const SizedBox(height: 8),
            TextField(
              controller: _inputCtrl,
              maxLines: 10,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '허가번호를 입력하세요\n(줄바꿈, 쉼표, 세미콜론으로 구분)',
                hintStyle: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ]),
        ),

        const SizedBox(height: 16),

        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!,
                style: const TextStyle(color: Colors.red, fontSize: 13)),
          ),

        // 비교 시작 버튼
        SizedBox(
          height: 48,
          child: ElevatedButton.icon(
            onPressed: _comparing ||
                    zpwinoCount == 0 ||
                    _selectedUpload == null
                ? null
                : _doCompare,
            icon: _comparing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.compare_arrows),
            label: Text(_comparing ? '비교 중...' : '비교 시작'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _themeColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      ],
    );
  }

  // ── Step 1: 결과 ──

  Widget _buildResultStep() {
    final r = _result!;
    final filteredItems = _getFilteredItems();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 경고
        if (r.warnings.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: r.warnings
                    .map((w) => Row(children: [
                          const Icon(Icons.warning_amber,
                              size: 16, color: Colors.orange),
                          const SizedBox(width: 6),
                          Expanded(
                              child: Text(w,
                                  style: const TextStyle(fontSize: 13))),
                        ]))
                    .toList(),
              ),
            ),
          ),

        // 요약 카드
        _card(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              _sectionTitle(Icons.analytics, '비교 결과 요약'),
              const Spacer(),
              TextButton.icon(
                onPressed: _reset,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('다시 입력', style: TextStyle(fontSize: 12)),
              ),
            ]),
            const SizedBox(height: 12),
            // 조회 통계
            Row(children: [
              _statChip('전체', r.total, Colors.grey),
              const SizedBox(width: 8),
              _statChip('ERP', r.erpFound, Colors.blue),
              const SizedBox(width: 8),
              _statChip('DS장치', r.dsDeviceFound, Colors.teal),
              const SizedBox(width: 8),
              _statChip('DS안테나', r.dsAntennaFound, Colors.indigo),
            ]),
            const SizedBox(height: 12),
            // 설치대 비교
            _summaryRow('설치대', r.summary),
            const SizedBox(height: 8),
            // 일련번호 비교
            _summaryRow('일련번호', r.summary, prefix: 'serial'),
          ]),
        ),

        const SizedBox(height: 12),

        // 필터 칩
        _card(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _sectionTitle(Icons.filter_list, '필터'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              _filterChip('전체', filteredItems.length),
              _filterChip('일치', null),
              _filterChip('부분일치', null),
              _filterChip('불일치', null),
              _filterChip('확인필요', null),
            ]),
          ]),
        ),

        const SizedBox(height: 12),

        // 결과 테이블
        _card(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _sectionTitle(Icons.table_chart, '상세 결과 (${filteredItems.length}건)'),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(Colors.grey.shade100),
                columnSpacing: 16,
                horizontalMargin: 12,
                dataRowMinHeight: 36,
                dataRowMaxHeight: 52,
                columns: const [
                  DataColumn(label: Text('허가번호', style: _headerStyle)),
                  DataColumn(label: Text('호출명칭', style: _headerStyle)),
                  DataColumn(label: Text('본부', style: _headerStyle)),
                  DataColumn(label: Text('ERP 설치대', style: _headerStyle)),
                  DataColumn(label: Text('DS 설치대', style: _headerStyle)),
                  DataColumn(label: Text('설치대 비교', style: _headerStyle)),
                  DataColumn(label: Text('ERP 일련번호', style: _headerStyle)),
                  DataColumn(label: Text('DS 일련번호', style: _headerStyle)),
                  DataColumn(label: Text('일련번호 비교', style: _headerStyle)),
                ],
                rows: filteredItems.map((item) {
                  return DataRow(cells: [
                    DataCell(Text(item.zpwino, style: _cellStyle)),
                    DataCell(SizedBox(
                        width: 100,
                        child: Text(item.zpwina,
                            style: _cellStyle,
                            overflow: TextOverflow.ellipsis))),
                    DataCell(Text(item.areaHdofcNm, style: _cellStyle)),
                    DataCell(SizedBox(
                        width: 100,
                        child: Text(item.erpZpirty3, style: _cellStyle))),
                    DataCell(SizedBox(
                        width: 100,
                        child: Text(item.dsTowerType, style: _cellStyle))),
                    DataCell(_matchChip(item.towerMatch)),
                    DataCell(SizedBox(
                        width: 120,
                        child: Text(item.erpSerial,
                            style: _cellStyle,
                            overflow: TextOverflow.ellipsis))),
                    DataCell(SizedBox(
                        width: 120,
                        child: Text(item.dsSerial,
                            style: _cellStyle,
                            overflow: TextOverflow.ellipsis))),
                    DataCell(_matchChip(item.serialMatch)),
                  ]);
                }).toList(),
              ),
            ),
          ]),
        ),
      ],
    );
  }

  // ── Helpers ──

  List<CompareItem> _getFilteredItems() {
    if (_result == null) return [];
    if (_filter == '전체') return _result!.items;
    return _result!.items.where((it) {
      return it.towerMatch == _filter || it.serialMatch == _filter;
    }).toList();
  }

  Widget _card(Widget child) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      child: child,
    );
  }

  Widget _sectionTitle(IconData icon, String title) {
    return Row(children: [
      Icon(icon, size: 18, color: _themeColor),
      const SizedBox(width: 6),
      Text(title,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
    ]);
  }

  Widget _statChip(String label, int value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text('$label $value',
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _summaryRow(String label, Map<String, int> summary,
      {String prefix = 'tower'}) {
    final match = (summary['${prefix}_match'] ?? 0) +
        (summary['${prefix}_partial'] ?? 0);
    final mismatch = summary['${prefix}_mismatch'] ?? 0;
    final check = summary['${prefix}_check'] ?? 0;
    final total = match + mismatch + check;
    final rate = total > 0 ? (match / total * 100).toStringAsFixed(1) : '-';
    return Row(children: [
      SizedBox(
          width: 70,
          child: Text('$label:',
              style:
                  const TextStyle(fontWeight: FontWeight.w500, fontSize: 13))),
      _miniStat('일치', match, Colors.green),
      const SizedBox(width: 6),
      _miniStat('불일치', mismatch, Colors.red),
      const SizedBox(width: 6),
      _miniStat('확인필요', check, Colors.orange),
      const Spacer(),
      Text('일치율 $rate%',
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
    ]);
  }

  Widget _miniStat(String label, int count, Color color) {
    return Text('$label $count',
        style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w500));
  }

  Widget _filterChip(String label, int? count) {
    final selected = _filter == label;
    return ChoiceChip(
      label: Text(count != null ? '$label ($count)' : label,
          style: TextStyle(fontSize: 12, color: selected ? Colors.white : null)),
      selected: selected,
      selectedColor: _themeColor,
      onSelected: (_) => setState(() => _filter = label),
    );
  }

  Widget _matchChip(String status) {
    Color bg;
    Color fg;
    switch (status) {
      case '일치':
        bg = Colors.green.shade50;
        fg = Colors.green.shade700;
        break;
      case '부분일치':
        bg = Colors.blue.shade50;
        fg = Colors.blue.shade700;
        break;
      case '불일치':
        bg = Colors.red.shade50;
        fg = Colors.red.shade700;
        break;
      default:
        bg = Colors.orange.shade50;
        fg = Colors.orange.shade700;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Text(status,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  static const _headerStyle =
      TextStyle(fontWeight: FontWeight.w600, fontSize: 12);
  static const _cellStyle = TextStyle(fontSize: 12);
}
