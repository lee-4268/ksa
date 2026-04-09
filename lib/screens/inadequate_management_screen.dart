import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../widgets/progress_dialog.dart';

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
  String? _error;

  // 통계
  int _totalCount = 0;
  int _incompleteCount = 0;
  int _completeCount = 0;
  int _excludedCount = 0;

  // 필터
  String _selectedRegion = '';
  String _selectedStatus = '';

  // 데이터
  List<Map<String, dynamic>> _items = [];
  int _page = 1;
  int _pageSize = 100;
  int _totalItems = 0;

  bool _isSummaryExpanded = false;

  static const _regionOptions = [
    '', '강남', '강북', '경기', '인천',
    '강원', '충청', '경북', '경남', '서부',
  ];

  static const _statusOptions = ['', '미완료', '완료', '대상제외'];

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthService>();
    _svc = InspectionService()..setAuthToken(auth.authToken);
    _isAdmin = auth.isSuperAdmin || auth.isDivisionAdmin;
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _svc.getInadequateStats(_year),
        _svc.getInadequateList(
          _year,
          region: _selectedRegion,
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
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _doSync() async {
    setState(() => _syncing = true);
    try {
      await _svc.syncInadequate(_year);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('동기화 완료'), backgroundColor: Colors.green),
        );
        _page = 1;
        _loadData();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('동기화 실패: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
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
                    // 1. 헤더 영역 (아이콘 + 제목 + 서브타이틀)
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

                    // 2. 정보 요약 카드 (어떤 내용을 수정하는지 참고용)
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
                          // 👇 불합격 상세 추가 부분
                          _buildDialogInfoRow('불합격상세', item['불합격상세']?.toString() ?? '-'),
                          const SizedBox(height: 8),
                          _buildDialogInfoRow('시정기한', item['시정기한']?.toString() ?? '-'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    // 3. 상태 선택 버튼 (모던한 탭 스타일)
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
                                border: Border.all(
                                  color: isSelected ? primaryColor : const Color(0xFFD1D5DB),
                                ),
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

                    // 4. 심의차수 입력
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

                    // 5. 하단 액션 버튼
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

                              if (mounted) {
                                Navigator.pop(ctx);
                                _loadData();
                              }
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

  // 다이얼로그 내부 요약 정보 출력을 위한 헬퍼 위젯 (클래스 내부 아무 곳에나 추가)
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
          if (_isAdmin)
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

    // 📱 모바일 환경: 접기/펼치기 기능 적용 (터치 물결 효과 추가)
    if (isMobile) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          children: [
            // 1) 클릭 가능한 요약 바 (Material + InkWell 적용)
            Material(
              color: Colors.white, // Container의 배경색을 Material로 이동
              borderRadius: BorderRadius.circular(10),
              child: InkWell(
                onTap: () {
                  setState(() {
                    _isSummaryExpanded = !_isSummaryExpanded;
                  });
                },
                borderRadius: BorderRadius.circular(10), // 모서리 둥글게 물결치도록 설정
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _border), 
                    // ⚠️ 여기서 color: Colors.white를 빼야 물결이 보입니다!
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
                      // 질문자님 예시처럼 좀 더 부드러운 아이콘으로 변경
                      Icon(
                        _isSummaryExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 22,
                        color: const Color(0xFF9CA3AF),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            
            // 2) 펼쳐졌을 때 보이는 카드 영역 (2x2 배열)
            if (_isSummaryExpanded) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  _buildMobileCard(cards[0]),
                  const SizedBox(width: 8),
                  _buildMobileCard(cards[1]),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _buildMobileCard(cards[2]),
                  const SizedBox(width: 8),
                  _buildMobileCard(cards[3]),
                ],
              ),
            ],
          ],
        ),
      );
    }

    // 💻 PC/태블릿 환경: 기존처럼 4개 가로 배치
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
                        Text(
                          '${c.count}건',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: c.color),
                          overflow: TextOverflow.ellipsis,
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

  Widget _buildFilters() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(
        children: [
          // 본부 dropdown
          SizedBox(
            width: 150,
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
                  value: _selectedRegion,
                  borderRadius: BorderRadius.circular(10),
                  items: _regionOptions.map((r) {
                    return DropdownMenuItem(value: r, child: Text(r.isEmpty ? '전체 본부' : r));
                  }).toList(),
                  onChanged: (v) {
                    setState(() {
                      _selectedRegion = v ?? '';
                      _page = 1;
                    });
                    _loadData();
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 상태 dropdown
          SizedBox(
            width: 130,
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
                  value: _selectedStatus,
                  borderRadius: BorderRadius.circular(10),
                  items: _statusOptions.map((s) {
                    return DropdownMenuItem(value: s, child: Text(s.isEmpty ? '전체 상태' : s));
                  }).toList(),
                  onChanged: (v) {
                    setState(() {
                      _selectedStatus = v ?? '';
                      _page = 1;
                    });
                    _loadData();
                  },
                ),
              ),
            ),
          ),
          const Spacer(),
          Text(
            '총 $_totalItems건',
            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
          ),
        ],
      ),
    );
  }

  Widget _buildTable() {
    if (_items.isEmpty) {
      return const Center(
        child: Text('데이터가 없습니다.', style: TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
      );
    }

    const columns = [
      '본부', '팀', '허가번호', '호출명칭', '주소', '검사일자',
      '시정기한', '불합격내용', '불합격상세', '상태', '심의차수',
    ];

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
              headingTextStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF374151),
              ),
              dataTextStyle: const TextStyle(fontSize: 12, color: Color(0xFF111827)),
              columnSpacing: 16,
              horizontalMargin: 12,
              dataRowMinHeight: 40,
              dataRowMaxHeight: 56,
              columns: columns.map((c) => DataColumn(label: Text(c))).toList(),
              rows: _items.map((item) {
                return DataRow(
                  onSelectChanged: _isAdmin ? (_) => _showEditDialog(item) : null,
                  cells: [
                    DataCell(Text(_str(item, 'region') .isNotEmpty ? _str(item, 'region') : _str(item, 'skt본부'), overflow: TextOverflow.ellipsis)),
                    DataCell(Text(_str(item, 'ons팀'), overflow: TextOverflow.ellipsis)),
                    DataCell(Text(_str(item, '허가번호'), overflow: TextOverflow.ellipsis)),
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 140),
                        child: Text(_str(item, '호출명칭'), overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(_str(item, '주소'), overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    DataCell(Text(_str(item, '검사일자'))),
                    DataCell(_buildDeadlineCell(item)),
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 140),
                        child: Text(_str(item, '불합격내용'), overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(_str(item, '불합격상세'), overflow: TextOverflow.ellipsis),
                      ),
                    ),
                    DataCell(_buildStatusChip(_str(item, 'status'))),
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
      default: // 미완료
        bg = const Color(0xFFFEE2E2);
        fg = const Color(0xFFDC2626);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        status.isEmpty ? '미완료' : status,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
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
            onPressed: _page > 1
                ? () {
                    setState(() => _page--);
                    _loadData();
                  }
                : null,
          ),
          const SizedBox(width: 8),
          Text(
            '$_page / $totalPages',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed: _page < totalPages
                ? () {
                    setState(() => _page++);
                    _loadData();
                  }
                : null,
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
              decoration: BoxDecoration(
                color: c.color.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(c.icon, color: c.color, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.label, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                  const SizedBox(height: 2),
                  Text(
                    '${c.count}건',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: c.color),
                    overflow: TextOverflow.ellipsis,
                  ),
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
