import 'package:excel/excel.dart' as xl;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/excel_export_stub.dart'
    if (dart.library.io) '../services/excel_export_mobile.dart'
    if (dart.library.html) '../services/excel_export_web.dart' as platform_export;
import '../services/inspection_service.dart';
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

class _InadequateManagementScreenState
    extends State<InadequateManagementScreen> {
  static const Color primaryColor = Color(0xFFE53935);
  static const Color _border = Color(0xFFE5E7EB);

  late final InspectionService _svc;
  late bool _isAdmin;

  int _year = DateTime.now().year;
  bool _loading = false;
  bool _syncing = false;
  bool _exporting = false;
  String? _error;

  // 통계
  int _totalCount = 0;
  int _incompleteCount = 0;
  int _completeCount = 0;
  int _excludedCount = 0;

  // 필터
  String _selectedRegion = '';
  String _selectedTeam = '';
  String _selectedStatus = '';

  // 데이터
  List<Map<String, dynamic>> _items = [];
  int _page = 1;
  int _pageSize = 100;
  int _totalItems = 0;

  // 복수선택
  final Set<int> _checkedIds = {};

  // 정렬
  String? _sortColumn;
  bool _sortAsc = true;

  bool _isSummaryExpanded = false;

  static const _regionOptions = [
    '', '강남', '강북', '경기', '인천',
    '강원', '충청', '경북', '경남', '서부',
  ];

  static const _statusOptions = ['', '미완료', '완료', '대상제외'];

  // 본부 선택에 따른 팀 목록
  List<String> get _teamOptions {
    if (_selectedRegion.isEmpty) return [];
    return _orgMap[_selectedRegion] ?? [];
  }

  // 컬럼 정의: (표시명, 데이터키)
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
  void initState() {
    super.initState();
    final auth = context.read<AuthService>();
    _svc = InspectionService()..setAuthToken(auth.authToken);
    _isAdmin = auth.isSuperAdmin || auth.isDivisionAdmin;
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() { _loading = true; _error = null; _checkedIds.clear(); });
    try {
      final results = await Future.wait([
        _svc.getInadequateStats(_year),
        _svc.getInadequateList(
          _year,
          region: _selectedRegion,
          team: _selectedTeam,
          status: _selectedStatus,
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
          // 정렬 적용
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
      // 날짜 형식이면 숫자 비교처럼
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
    try {
      // 전체 데이터 가져오기 (페이지 없이)
      final res = await _svc.getInadequateList(
        _year,
        region: _selectedRegion,
        team: _selectedTeam,
        status: _selectedStatus,
        page: 1,
        pageSize: 9999,
      );
      final allItems = List<Map<String, dynamic>>.from(res['items'] ?? []);

      // 정렬 적용
      if (_sortColumn != null) {
        final col = _sortColumn!;
        allItems.sort((a, b) {
          final va = (a[col] ?? '').toString();
          final vb = (b[col] ?? '').toString();
          return _sortAsc ? va.compareTo(vb) : vb.compareTo(va);
        });
      }

      // Excel 생성
      final excel = xl.Excel.createExcel();
      const sheetName = '부적합관리';
      excel.rename(excel.getDefaultSheet()!, sheetName);
      final sheet = excel[sheetName];

      final headerStyle = xl.CellStyle(
        bold: true,
        backgroundColorHex: xl.ExcelColor.fromHexString('#E53935'),
      );

      final headers = ['본부', '팀', '허가번호', '호출명칭', '주소', '검사일자', '시정기한', '불합격내용', '불합격상세', '상태', '심의차수'];
      final keys = ['region', 'ons팀', '허가번호', '호출명칭', '주소', '검사일자', '시정기한', '불합격내용', '불합격상세', 'status', '심의차수'];

      for (int i = 0; i < headers.length; i++) {
        final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
        cell.value = xl.TextCellValue(headers[i]);
        cell.cellStyle = headerStyle;
      }

      for (int r = 0; r < allItems.length; r++) {
        final item = allItems[r];
        for (int c = 0; c < keys.length; c++) {
          final cell = sheet.cell(xl.CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1));
          final val = (item[keys[c]] ?? '').toString();
          cell.value = xl.TextCellValue(val);
        }
      }

      final widths = [10.0, 18.0, 14.0, 20.0, 28.0, 12.0, 12.0, 20.0, 28.0, 8.0, 8.0];
      for (int i = 0; i < widths.length; i++) {
        sheet.setColumnWidth(i, widths[i]);
      }

      final bytes = excel.encode();
      if (bytes == null) throw Exception('Excel 파일 생성 실패');
      await platform_export.saveExcelFile(Uint8List.fromList(bytes), '부적합관리_$_year.xlsx');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('엑셀 내보내기 실패: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Widget _buildBulkActionBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: primaryColor.withValues(alpha: 0.06),
        border: const Border(
          bottom: BorderSide(color: Color(0xFFE5E7EB)),
          top: BorderSide(color: Color(0xFFE5E7EB)),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: primaryColor,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '${_checkedIds.length}건 선택됨',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white),
            ),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: _showBulkEditDialog,
            icon: const Icon(Icons.edit_outlined, size: 15),
            label: const Text('일괄 처리'),
            style: ElevatedButton.styleFrom(
              backgroundColor: primaryColor,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => setState(() => _checkedIds.clear()),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF6B7280),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            child: const Text('선택 해제', style: TextStyle(fontSize: 13)),
          ),
        ],
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
            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              elevation: 0,
              backgroundColor: Colors.white,
              child: Container(
                width: 440,
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 헤더
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

                    // 상태 선택
                    const Text('처리 상태', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
                    const SizedBox(height: 6),
                    const Text('변경 없음으로 두면 상태는 유지됩니다', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
                    const SizedBox(height: 10),
                    Row(
                      children: ['', '미완료', '완료', '대상제외'].map((s) {
                        final isSelected = selectedStatus == s;
                        final label = s.isEmpty ? '변경 없음' : s;
                        return Expanded(
                          child: GestureDetector(
                            onTap: () => setDialogState(() => selectedStatus = s),
                            child: Container(
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: isSelected ? (s.isEmpty ? const Color(0xFF374151) : primaryColor) : Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isSelected ? (s.isEmpty ? const Color(0xFF374151) : primaryColor) : const Color(0xFFD1D5DB),
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  color: isSelected ? Colors.white : const Color(0xFF4B5563),
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 24),

                    // 심의차수
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

                    // 버튼
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

                            // 상태도 없고 심의차수도 없으면 무시
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
            return Dialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              elevation: 0,
              backgroundColor: Colors.white,
              child: Container(
                width: 440,
                padding: const EdgeInsets.all(24),
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
                    Row(
                      children: ['미완료', '완료', '대상제외'].map((s) {
                        final isSelected = selectedStatus == s;
                        return Expanded(
                          child: GestureDetector(
                            onTap: () => setDialogState(() => selectedStatus = s),
                            child: Container(
                              margin: const EdgeInsets.only(right: 8),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: isSelected ? primaryColor : Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: isSelected ? primaryColor : const Color(0xFFD1D5DB)),
                                boxShadow: isSelected
                                    ? [BoxShadow(color: primaryColor.withValues(alpha: 0.25), blurRadius: 4, offset: const Offset(0, 2))]
                                    : [],
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                s,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                  color: isSelected ? Colors.white : const Color(0xFF4B5563),
                                ),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFB),
      body: Column(
        children: [
          _buildHeader(),
          if (_error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Colors.red.shade50,
              child: Text(_error!, style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
            ),
          if (_isAdmin && _checkedIds.isNotEmpty) _buildBulkActionBar(),
          _buildSummaryCards(),
          _buildFilters(),
          Expanded(child: _loading ? const Center(child: CircularProgressIndicator()) : _buildTable()),
          _buildPagination(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_outlined, color: primaryColor, size: 22),
          const SizedBox(width: 10),
          const Text(
            '부적합 관리',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
          ),
          const Spacer(),
          // Excel 내보내기
          OutlinedButton.icon(
            onPressed: _exporting ? null : _doExport,
            icon: _exporting
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.download_outlined, size: 16),
            label: Text(_exporting ? '내보내는 중...' : 'Excel 내보내기'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF16A34A),
              side: const BorderSide(color: Color(0xFF16A34A)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          if (_isAdmin) ...[
            const SizedBox(width: 10),
            ElevatedButton.icon(
              onPressed: _syncing ? null : _doSync,
              icon: _syncing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.sync, size: 18),
              label: Text(_syncing ? '동기화 중...' : '동기화'),
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummaryCards() {
    final isMobile = MediaQuery.of(context).size.width < 600;

    final cards = [
      _SummaryInfo('전체', _totalCount, const Color(0xFF374151), Icons.list_alt),
      _SummaryInfo('미완료', _incompleteCount, const Color(0xFFEF4444), Icons.pending_outlined),
      _SummaryInfo('완료', _completeCount, const Color(0xFF22C55E), Icons.check_circle_outline),
      _SummaryInfo('대상제외', _excludedCount, const Color(0xFF6B7280), Icons.remove_circle_outline),
    ];

    if (isMobile) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          children: [
            Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: () => setState(() => _isSummaryExpanded = !_isSummaryExpanded),
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _border),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.bar_chart, size: 18, color: Color(0xFF6B7280)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '전체 $_totalCount · 미완료 $_incompleteCount · 완료 $_completeCount · 제외 $_excludedCount',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF374151)),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Icon(_isSummaryExpanded ? Icons.expand_less : Icons.expand_more, size: 22, color: const Color(0xFF9CA3AF)),
                    ],
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: cards.map((c) {
          return Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _border),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: c.color.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(c.icon, color: c.color, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.label, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                        const SizedBox(height: 2),
                        Text('${c.count}건', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.color), overflow: TextOverflow.ellipsis),
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

  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        children: [
          // 본부 필터
          _buildDropdown(
            width: 140,
            value: _selectedRegion,
            items: _regionOptions,
            hint: '전체 본부',
            onChanged: (v) {
              setState(() {
                _selectedRegion = v ?? '';
                _selectedTeam = ''; // 본부 바뀌면 팀 초기화
                _page = 1;
              });
              _loadData();
            },
          ),
          const SizedBox(width: 8),
          // 팀 필터 (본부 선택 시만 활성화)
          _buildDropdown(
            width: 175,
            value: _selectedTeam,
            items: ['', ..._teamOptions],
            hint: '전체 팀',
            enabled: _selectedRegion.isNotEmpty,
            onChanged: (v) {
              setState(() { _selectedTeam = v ?? ''; _page = 1; });
              _loadData();
            },
          ),
          const SizedBox(width: 8),
          // 상태 필터
          _buildDropdown(
            width: 130,
            value: _selectedStatus,
            items: _statusOptions,
            hint: '전체 상태',
            onChanged: (v) {
              setState(() { _selectedStatus = v ?? ''; _page = 1; });
              _loadData();
            },
          ),
          const Spacer(),
          Text('총 $_totalItems건', style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        ],
      ),
    );
  }

  Widget _buildDropdown({
    required double width,
    required String value,
    required List<String> items,
    required String hint,
    required ValueChanged<String?> onChanged,
    bool enabled = true,
  }) {
    return SizedBox(
      width: width,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.4,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(10),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isExpanded: true,
              isDense: true,
              icon: Icon(Icons.arrow_drop_down, color: primaryColor, size: 20),
              dropdownColor: Colors.white,
              style: const TextStyle(color: Colors.black87, fontSize: 13),
              value: items.contains(value) ? value : '',
              borderRadius: BorderRadius.circular(10),
              items: items.map((r) {
                return DropdownMenuItem(value: r, child: Text(r.isEmpty ? hint : r));
              }).toList(),
              onChanged: enabled ? onChanged : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTable() {
    if (_items.isEmpty) {
      return const Center(
        child: Text('데이터가 없습니다.', style: TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _border),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SingleChildScrollView(
            child: DataTable(
              headingRowColor: WidgetStateProperty.all(const Color(0xFFF9FAFB)),
              headingTextStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
              dataTextStyle: const TextStyle(fontSize: 12, color: Color(0xFF111827)),
              columnSpacing: 16,
              horizontalMargin: 12,
              dataRowMinHeight: 40,
              dataRowMaxHeight: 56,
              sortColumnIndex: _sortColumn != null
                  ? _columns.indexWhere((c) => c.$2 == _sortColumn) + (_isAdmin ? 1 : 0)
                  : null,
              sortAscending: _sortAsc,
              columns: [
                if (_isAdmin)
                  DataColumn(
                    label: Checkbox(
                      tristate: true,
                      value: _checkedIds.isEmpty
                          ? false
                          : _checkedIds.length == _items.length
                              ? true
                              : null,
                      activeColor: primaryColor,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            _checkedIds.addAll(_items.map((e) => e['id'] as int));
                          } else {
                            _checkedIds.clear();
                          }
                        });
                      },
                    ),
                  ),
                ..._columns.map((c) => DataColumn(
                  label: Text(c.$1),
                  onSort: (i, asc) => _onSort(c.$2),
                )),
              ],
              rows: _items.map((item) {
                final id = item['id'] as int;
                final checked = _checkedIds.contains(id);
                return DataRow(
                  selected: checked,
                  color: checked
                      ? WidgetStateProperty.all(primaryColor.withValues(alpha: 0.06))
                      : null,
                  onSelectChanged: _isAdmin
                      ? (v) {
                          setState(() {
                            if (v == true) {
                              _checkedIds.add(id);
                            } else {
                              _checkedIds.remove(id);
                            }
                          });
                        }
                      : null,
                  cells: [
                    if (_isAdmin) const DataCell(SizedBox.shrink()),
                    DataCell(Text(_str(item, 'region').isNotEmpty ? _str(item, 'region') : _str(item, 'skt본부'), overflow: TextOverflow.ellipsis)),
                    DataCell(Text(_str(item, 'ons팀'), overflow: TextOverflow.ellipsis)),
                    DataCell(Text(_str(item, '허가번호'), overflow: TextOverflow.ellipsis)),
                    DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 140), child: Text(_str(item, '호출명칭'), overflow: TextOverflow.ellipsis))),
                    DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 180), child: Text(_str(item, '주소'), overflow: TextOverflow.ellipsis))),
                    DataCell(Text(_str(item, '검사일자'))),
                    DataCell(_buildDeadlineCell(item)),
                    DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 140), child: Text(_str(item, '불합격내용'), overflow: TextOverflow.ellipsis))),
                    DataCell(ConstrainedBox(constraints: const BoxConstraints(maxWidth: 180), child: Text(_str(item, '불합격상세'), overflow: TextOverflow.ellipsis))),
                    DataCell(
                      _buildStatusChip(_str(item, 'status')),
                      onTap: _isAdmin ? () => _showEditDialog(item) : null,
                    ),
                    DataCell(Text(_str(item, '심의차수'))),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
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
        fontWeight: overdue ? FontWeight.w600 : null,
        fontSize: 12,
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(status.isEmpty ? '미완료' : status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  Widget _buildPagination() {
    final totalPages = (_totalItems / _pageSize).ceil().clamp(1, 9999);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: _border)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
            onPressed: _page > 1 ? () { setState(() => _page--); _loadData(); } : null,
          ),
          const SizedBox(width: 8),
          Text('$_page / $totalPages', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed: _page < totalPages ? () { setState(() => _page++); _loadData(); } : null,
          ),
        ],
      ),
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
