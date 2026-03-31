import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/community_service.dart';

/// 공지사항 화면 — 목록 / 상세 / 작성·수정 3가지 뷰를 상태로 전환
class NoticeBoardScreen extends StatefulWidget {
  const NoticeBoardScreen({super.key});

  @override
  State<NoticeBoardScreen> createState() => _NoticeBoardScreenState();
}

enum _ViewMode { list, detail, write }

class _NoticeBoardScreenState extends State<NoticeBoardScreen> {
  static const _primary = Color(0xFFE53935);
  static const _divisions = [
    '전체', '강남', '강북', '경기', '인천', '충청', '강원', '경남', '경북', '서부',
  ];

  final _svc = CommunityService();
  bool _initialized = false;

  // ── 공통 상태 ──
  _ViewMode _mode = _ViewMode.list;

  // ── 목록 ──
  bool _loading = false;
  List<Map<String, dynamic>> _items = [];
  int _total = 0;
  int _page = 1;
  final int _pageSize = 20;
  String _selectedDivision = '전체';
  final _searchCtrl = TextEditingController();
  String _searchText = '';

  // ── 상세 ──
  Map<String, dynamic>? _detail;
  bool _detailLoading = false;

  // ── 작성/수정 ──
  bool _isEditing = false; // true = 수정, false = 신규
  int? _editId;
  final _titleCtrl = TextEditingController();
  final _contentCtrl = TextEditingController();
  String _writeDivision = '전체';
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _svc.setAuthToken(context.read<AuthService>().authToken);
      _fetchList();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _titleCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  // ── 데이터 ──

  Future<void> _fetchList() async {
    setState(() => _loading = true);
    try {
      final res = await _svc.getNotices(
        division: _selectedDivision == '전체' ? null : _selectedDivision,
        search: _searchText.isEmpty ? null : _searchText,
        page: _page,
        pageSize: _pageSize,
      );
      setState(() {
        _items = List<Map<String, dynamic>>.from(res['notices'] ?? []);
        _total = res['total'] ?? 0;
      });
    } catch (e) {
      _snack('공지사항 조회 실패: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _openDetail(int id) async {
    setState(() {
      _mode = _ViewMode.detail;
      _detailLoading = true;
      _detail = null;
    });
    try {
      await _svc.viewNotice(id);
      final data = await _svc.getNotice(id);
      setState(() => _detail = data);
    } catch (e) {
      _snack('상세 조회 실패: $e');
      setState(() => _mode = _ViewMode.list);
    } finally {
      setState(() => _detailLoading = false);
    }
  }

  void _openWrite() {
    _isEditing = false;
    _editId = null;
    _titleCtrl.clear();
    _contentCtrl.clear();
    _writeDivision = '전체';
    setState(() => _mode = _ViewMode.write);
  }

  void _openEdit(Map<String, dynamic> item) {
    _isEditing = true;
    _editId = item['id'] as int?;
    _titleCtrl.text = item['title'] ?? '';
    _contentCtrl.text = item['content'] ?? '';
    _writeDivision = item['division'] ?? '전체';
    setState(() => _mode = _ViewMode.write);
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    final content = _contentCtrl.text.trim();
    if (title.isEmpty) {
      _snack('제목을 입력해주세요.');
      return;
    }
    if (content.isEmpty) {
      _snack('내용을 입력해주세요.');
      return;
    }
    setState(() => _saving = true);
    try {
      if (_isEditing && _editId != null) {
        await _svc.updateNotice(_editId!, title, content, division: _writeDivision);
        _snack('공지사항이 수정되었습니다.');
        _openDetail(_editId!);
      } else {
        final newId = await _svc.createNotice(title, content, division: _writeDivision);
        _snack('공지사항이 등록되었습니다.');
        _openDetail(newId);
      }
    } catch (e) {
      _snack('저장 실패: $e');
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('공지사항 삭제'),
        content: const Text('정말 삭제하시겠습니까?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _svc.deleteNotice(id);
      _snack('삭제되었습니다.');
      setState(() => _mode = _ViewMode.list);
      _fetchList();
    } catch (e) {
      _snack('삭제 실패: $e');
    }
  }

  void _backToList() {
    setState(() => _mode = _ViewMode.list);
    _fetchList();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── 페이지네이션 ──

  int get _totalPages => (_total / _pageSize).ceil().clamp(1, 9999);

  void _goPage(int p) {
    if (p < 1 || p > _totalPages || p == _page) return;
    _page = p;
    _fetchList();
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: switch (_mode) {
          _ViewMode.list => _buildList(),
          _ViewMode.detail => _buildDetail(),
          _ViewMode.write => _buildWrite(),
        },
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  LIST VIEW
  // ═══════════════════════════════════════════════════════════════

  Widget _buildList() {
    final auth = context.read<AuthService>();
    final canWrite = auth.isSuperAdmin || auth.isDivisionAdmin;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 타이틀 ──
        const Text('공지사항', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 4),
        Text(
          '조직 내 공지사항을 확인하고 공유할 수 있습니다.',
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 20),

        // ── 본부 탭 ──
        _buildDivisionTabs(),
        const SizedBox(height: 16),

        // ── 총 건수 + 검색 + 글쓰기 ──
        Row(
          children: [
            Text('총 $_total건', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const Spacer(),
            SizedBox(
              width: 220,
              height: 36,
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: '검색어를 입력하세요',
                  hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                  prefixIcon: Icon(Icons.search, size: 18, color: Colors.grey.shade400),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: _primary),
                  ),
                ),
                onSubmitted: (_) {
                  _searchText = _searchCtrl.text.trim();
                  _page = 1;
                  _fetchList();
                },
              ),
            ),
            if (canWrite) ...[
              const SizedBox(width: 8),
              SizedBox(
                height: 36,
                child: ElevatedButton.icon(
                  onPressed: _openWrite,
                  icon: const Icon(Icons.edit, size: 16),
                  label: const Text('글쓰기', style: TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),

        // ── 테이블 ──
        Expanded(child: _buildTable()),

        // ── 페이지네이션 ──
        if (_total > 0) _buildPagination(),
      ],
    );
  }

  Widget _buildDivisionTabs() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _divisions.map((d) {
          final selected = d == _selectedDivision;
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () {
                _selectedDivision = d;
                _page = 1;
                _fetchList();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                decoration: BoxDecoration(
                  color: selected ? _primary : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: selected ? _primary : Colors.grey.shade300),
                ),
                child: Text(
                  d,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    color: selected ? Colors.white : Colors.grey.shade700,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTable() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _primary));
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.campaign_outlined, size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text(
              '등록된 공지사항이 없습니다',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          // 헤더
          Container(
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: const Row(
              children: [
                SizedBox(width: 60, child: Text('번호', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                Expanded(flex: 5, child: Text('제목', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                SizedBox(width: 80, child: Text('등록자', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                SizedBox(width: 100, child: Text('등록일', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                SizedBox(width: 60, child: Text('조회', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
              ],
            ),
          ),
          Divider(height: 1, color: Colors.grey.shade200),

          // 행
          Expanded(
            child: ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => Divider(height: 1, color: Colors.grey.shade100),
              itemBuilder: (_, i) {
                final item = _items[i];
                final id = item['id'] ?? 0;
                final rowNum = item['번호'] ?? (i + 1);
                final title = item['title'] ?? '';
                final authorName = item['author_name'] ?? item['author'] ?? '';
                final authorOrg = item['author_org'] as String? ?? '';
                final author = authorOrg.isNotEmpty ? '$authorName($authorOrg)' : authorName;
                final date = _fmtDate(item['created_at']);
                final views = item['view_count'] ?? 0;

                return InkWell(
                  onTap: () => _openDetail(id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                    child: Row(
                      children: [
                        SizedBox(width: 60, child: Text('$rowNum', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade600))),
                        Expanded(
                          flex: 5,
                          child: Text(
                            title,
                            style: const TextStyle(fontSize: 13),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(width: 80, child: Text('$author', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade600))),
                        SizedBox(width: 100, child: Text(date, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade600))),
                        SizedBox(width: 60, child: Text('$views', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade600))),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPagination() {
    const maxButtons = 5;
    int start = ((_page - 1) ~/ maxButtons) * maxButtons + 1;
    int end = (start + maxButtons - 1).clamp(1, _totalPages);

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _pageBtn('<<', () => _goPage(1), enabled: _page > 1),
          _pageBtn('<', () => _goPage(_page - 1), enabled: _page > 1),
          for (int p = start; p <= end; p++)
            _pageBtn('$p', () => _goPage(p), selected: p == _page),
          _pageBtn('>', () => _goPage(_page + 1), enabled: _page < _totalPages),
          _pageBtn('>>', () => _goPage(_totalPages), enabled: _page < _totalPages),
        ],
      ),
    );
  }

  Widget _pageBtn(String label, VoidCallback onTap, {bool selected = false, bool enabled = true}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? _primary : Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: selected ? _primary : Colors.grey.shade300),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              color: selected ? Colors.white : (enabled ? Colors.grey.shade700 : Colors.grey.shade300),
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  DETAIL VIEW
  // ═══════════════════════════════════════════════════════════════

  Widget _buildDetail() {
    if (_detailLoading || _detail == null) {
      return const Center(child: CircularProgressIndicator(color: _primary));
    }
    final d = _detail!;
    final isMine = d['is_mine'] == true || d['is_mine'] == 1;
    final isAdmin = context.read<AuthService>().isAdmin;
    final title = d['title'] ?? '';
    final authorName = d['author_name'] ?? d['author'] ?? '';
    final authorOrg = d['author_org'] as String? ?? '';
    final author = authorOrg.isNotEmpty ? '$authorName($authorOrg)' : authorName;
    final date = _fmtDate(d['created_at']);
    final views = d['view_count'] ?? 0;
    final content = d['content'] ?? '';
    final division = d['division'] ?? '';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 뒤로가기
          TextButton.icon(
            onPressed: _backToList,
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('목록으로', style: TextStyle(fontSize: 13)),
            style: TextButton.styleFrom(foregroundColor: Colors.grey.shade700),
          ),
          const SizedBox(height: 8),

          // 카드
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 제목
                  Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),

                  // 메타
                  Row(
                    children: [
                      if (division.isNotEmpty) ...[
                        _metaChip(division),
                        const SizedBox(width: 12),
                      ],
                      Icon(Icons.person_outline, size: 15, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Text(author, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                      const SizedBox(width: 16),
                      Icon(Icons.calendar_today_outlined, size: 14, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Text(date, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                      const SizedBox(width: 16),
                      Icon(Icons.visibility_outlined, size: 15, color: Colors.grey.shade500),
                      const SizedBox(width: 4),
                      Text('조회 $views', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                    ],
                  ),
                  const Divider(height: 32),

                  // 본문
                  SelectableText(
                    content,
                    style: const TextStyle(fontSize: 14, height: 1.7),
                  ),

                  // 하단 구분선 + 수정/삭제 버튼
                  if (isMine || isAdmin) ...[
                    const SizedBox(height: 32),
                    const Divider(),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (isMine)
                          OutlinedButton.icon(
                            onPressed: () => _openEdit(d),
                            icon: const Icon(Icons.edit_outlined, size: 16),
                            label: const Text('수정'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.grey.shade700,
                              side: BorderSide(color: Colors.grey.shade300),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            ),
                          ),
                        if (isMine) const SizedBox(width: 8),
                        OutlinedButton.icon(
                          onPressed: () => _delete(d['id'] as int),
                          icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                          label: const Text('삭제', style: TextStyle(color: Colors.red)),
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(color: Colors.red.shade200),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
  }

  Widget _metaChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: _primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12, color: _primary, fontWeight: FontWeight.w500)),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  WRITE / EDIT VIEW
  // ═══════════════════════════════════════════════════════════════

  Widget _buildWrite() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 뒤로가기
        TextButton.icon(
          onPressed: _backToList,
          icon: const Icon(Icons.arrow_back, size: 18),
          label: Text(_isEditing ? '수정 취소' : '작성 취소', style: const TextStyle(fontSize: 13)),
          style: TextButton.styleFrom(foregroundColor: Colors.grey.shade700),
        ),
        const SizedBox(height: 8),

        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isEditing ? '공지사항 수정' : '공지사항 작성',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 20),

                // 제목
                const Text('제목', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                TextField(
                  controller: _titleCtrl,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '공지사항 제목을 입력하세요',
                    hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: _primary),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 본부 선택
                const Text('대상 본부', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Container(
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
                      icon: const Icon(Icons.arrow_drop_down, color: _primary, size: 20),
                      dropdownColor: Colors.white,
                      style: const TextStyle(color: Colors.black87, fontSize: 13),
                      value: _writeDivision,
                      items: _divisions
                          .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _writeDivision = v);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // 내용
                const Text('내용', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Expanded(
                  child: TextField(
                    controller: _contentCtrl,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: const TextStyle(fontSize: 14, height: 1.6),
                    decoration: InputDecoration(
                      hintText: '공지사항 내용을 입력하세요',
                      hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                      contentPadding: const EdgeInsets.all(14),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: Colors.grey.shade300),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: _primary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                // 버튼
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: _saving ? null : _backToList,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.grey.shade700,
                        side: BorderSide(color: Colors.grey.shade300),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                      child: const Text('취소', style: TextStyle(fontSize: 13)),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _saving ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        elevation: 0,
                      ),
                      child: _saving
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text(_isEditing ? '수정' : '등록', style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Util ──

  String _fmtDate(dynamic v) {
    if (v == null) return '-';
    final s = v.toString();
    if (s.length >= 10) return s.substring(0, 10);
    return s;
  }
}
