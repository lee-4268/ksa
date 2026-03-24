import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../widgets/user_profile_button.dart';
import 'inspection_result_screen.dart';

class InspectionMyListScreen extends StatefulWidget {
  const InspectionMyListScreen({super.key});

  @override
  State<InspectionMyListScreen> createState() => _InspectionMyListScreenState();
}

class _InspectionMyListScreenState extends State<InspectionMyListScreen> {
  static const Color _primary   = Color(0xFFE53935);
  static const Color _green     = Color(0xFF43A047);
  static const Color _blue      = Color(0xFF4A90D9);
  static const Color _grey      = Color(0xFF9E9E9E);

  late final InspectionService _svc;
  int _year = DateTime.now().year;
  List<Map<String, dynamic>> _items = [];
  bool _loading = false;
  String? _error;

  // 검색
  final _searchCtrl = TextEditingController();
  String _search = '';

  @override
  void initState() {
    super.initState();
    _svc = InspectionService()
      ..setAuthToken(context.read<AuthService>().authToken);
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final items = await _svc.getMyList(_year);
      setState(() => _items = items);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    if (_search.isEmpty) return _items;
    final q = _search.toLowerCase();
    return _items.where((item) {
      return (item['호출명칭'] ?? '').toString().toLowerCase().contains(q) ||
             (item['허가번호'] ?? '').toString().toLowerCase().contains(q) ||
             (item['지역'] ?? '').toString().toLowerCase().contains(q);
    }).toList();
  }

  // 수검예정주차 기준으로 그룹핑
  Map<String, List<Map<String, dynamic>>> get _grouped {
    final result = <String, List<Map<String, dynamic>>>{};
    for (final item in _filtered) {
      final key = item['수검예정주차'] as String? ?? '미정';
      result.putIfAbsent(key, () => []).add(item);
    }
    // 주차 오름차순 정렬
    final sorted = Map.fromEntries(
      result.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: _buildAppBar(),
      body: Column(children: [
        _buildSearchBar(),
        Expanded(child: _buildBody()),
      ]),
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
      title: Row(children: [
        const Text('수검 관리',
            style: TextStyle(color: Colors.black87, fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        _buildYearChips(),
      ]),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh_rounded, color: Colors.black54),
          tooltip: '새로고침',
          onPressed: _loading ? null : _load,
        ),
        UserProfileButton(onLogout: () => context.read<AuthService>().signOut()),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildYearChips() {
    final years = [DateTime.now().year - 1, DateTime.now().year, DateTime.now().year + 1];
    return Row(
      children: years.map((y) {
        final selected = y == _year;
        return GestureDetector(
          onTap: () {
            if (_year != y) { setState(() => _year = y); _load(); }
          },
          child: Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: selected ? _primary : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('$y년',
                style: TextStyle(
                  fontSize: 12,
                  color: selected ? Colors.white : Colors.black54,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                )),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: TextField(
        controller: _searchCtrl,
        decoration: InputDecoration(
          hintText: '호출명칭, 허가번호, 지역 검색',
          hintStyle: const TextStyle(fontSize: 13),
          prefixIcon: const Icon(Icons.search, size: 18, color: Colors.black38),
          suffixIcon: _search.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  onPressed: () {
                    _searchCtrl.clear();
                    setState(() => _search = '');
                  },
                )
              : null,
          isDense: true,
          filled: true,
          fillColor: Colors.grey.shade100,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
        ),
        onChanged: (v) => setState(() => _search = v),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 40),
          const SizedBox(height: 8),
          Text('오류: $_error', style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: _load, child: const Text('다시 시도')),
        ]),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.assignment_outlined, size: 48, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text('$_year년 배정된 수검 항목이 없습니다.',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
          const SizedBox(height: 4),
          Text('일정 및 통계 화면에서 담당자가 일정을 등록하면 표시됩니다.',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
        ]),
      );
    }
    if (_filtered.isEmpty) {
      return Center(
        child: Text('"$_search" 검색 결과 없음',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: _buildGroupedList(),
    );
  }

  Widget _buildGroupedList() {
    final grouped = _grouped;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      itemCount: grouped.length,
      itemBuilder: (context, i) {
        final week = grouped.keys.elementAt(i);
        final items = grouped[week]!;
        final firstItem = items.first;
        final startDate = firstItem['수검시작일'] ?? '';
        final endDate = firstItem['수검종료일'] ?? '';
        final dateRange = (startDate.isNotEmpty && endDate.isNotEmpty)
            ? '$startDate ~ $endDate'
            : '';

        // 해당 주차 완료 통계
        final done = items.where((it) =>
            (it['status'] as String?) == '합격' ||
            (it['status'] as String?) == '불합격').length;

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 주차 헤더
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
            child: Row(children: [
              Container(
                width: 3, height: 14,
                decoration: BoxDecoration(
                  color: _primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(week,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: Colors.black87)),
              ),
              if (dateRange.isNotEmpty)
                Text(dateRange,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              const SizedBox(width: 8),
              Text('$done / ${items.length}',
                  style: TextStyle(
                      fontSize: 12,
                      color: done == items.length ? _green : Colors.grey.shade500,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
          // 항목 리스트
          ...items.map((item) => _buildItemCard(item)),
        ]);
      },
    );
  }

  Widget _buildItemCard(Map<String, dynamic> item) {
    final licenseNo = item['허가번호'] as String? ?? '';
    final callname  = item['호출명칭'] as String? ?? licenseNo;
    final region    = item['지역'] as String? ?? '';
    final status    = item['status'] as String? ?? '검사대기';
    final inspDate  = item['검사일'] as String? ?? '';

    final Color statusColor;
    final IconData statusIcon;
    switch (status) {
      case '합격':
        statusColor = _green; statusIcon = Icons.check_circle_outline; break;
      case '불합격':
        statusColor = _primary; statusIcon = Icons.cancel_outlined; break;
      default:
        statusColor = _grey; statusIcon = Icons.pending_outlined;
    }

    return GestureDetector(
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(
          builder: (_) => InspectionResultScreen(
            year: _year,
            licenseNo: licenseNo,
            callname: callname,
            initialData: {'schedule': item, 'result': item},
          ),
        ));
        _load(); // 돌아왔을 때 목록 갱신
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(children: [
          // 상태 아이콘
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(statusIcon, size: 18, color: statusColor),
          ),
          const SizedBox(width: 12),

          // 메인 정보
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(callname,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Row(children: [
                if (region.isNotEmpty) ...[
                  Icon(Icons.location_on_outlined, size: 12, color: Colors.grey.shade400),
                  const SizedBox(width: 2),
                  Text(region,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                  const SizedBox(width: 8),
                ],
                Text(licenseNo,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
              ]),
              if (inspDate.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text('검사일: $inspDate',
                    style: TextStyle(fontSize: 11, color: _blue)),
              ],
            ]),
          ),

          // 상태 뱃지
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: statusColor.withValues(alpha: 0.3)),
            ),
            child: Text(status,
                style: TextStyle(
                    fontSize: 12, color: statusColor, fontWeight: FontWeight.w600)),
          ),

          const SizedBox(width: 4),
          Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade300),
        ]),
      ),
    );
  }
}
