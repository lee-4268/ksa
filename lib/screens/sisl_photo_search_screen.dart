import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../widgets/sisl_photo_widgets.dart';
import '../widgets/progress_dialog.dart';

/// 시설물 사진 검색 — SKO-OCEAN 사진을 본부/팀/국소명/주소로 검색.
/// 좌측: 추출 국소 목록(통시·공대코드 + 이미지 건수) / 우측: 사진 그리드.
class SislPhotoSearchScreen extends StatefulWidget {
  const SislPhotoSearchScreen({super.key});

  @override
  State<SislPhotoSearchScreen> createState() => _SislPhotoSearchScreenState();
}

class _SislPhotoSearchScreenState extends State<SislPhotoSearchScreen> {
  static const _primary = Color(0xFFE53935);
  static const _border = Color(0xFFE5E7EB);
  static const _bg = Color(0xFFFAFAFB);
  static const _textPrimary = Color(0xFF111827);
  static const _textSecondary = Color(0xFF6B7280);

  final _svc = InspectionService();
  final _facilityCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();

  // 필터 옵션
  Map<String, List<String>> _org = {}; // 본부 → 팀 목록
  bool _optionsLoading = true;
  String _hdqt = '';
  String _team = '';

  // 검색 결과
  bool _searching = false;
  bool _searched = false;
  List<Map<String, dynamic>> _groups = []; // 국소별 그룹
  int _totalPhotos = 0;
  // 좌측 선택 (null = 전체)
  String? _selectedNeos;

  @override
  void initState() {
    super.initState();
    _svc.setAuthToken(context.read<AuthService>().authToken);
    _loadOptions();
  }

  @override
  void dispose() {
    _facilityCtrl.dispose();
    _addressCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    try {
      final org = await _svc.getSislFilterOptions();
      if (!mounted) return;
      setState(() {
        _org = org;
        _optionsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _optionsLoading = false);
    }
  }

  List<String> get _teamsForHdqt =>
      _hdqt.isEmpty ? const [] : (_org[_hdqt] ?? const []);

  Future<void> _search() async {
    final facility = _facilityCtrl.text.trim();
    final address = _addressCtrl.text.trim();
    if (_hdqt.isEmpty && _team.isEmpty && facility.isEmpty && address.isEmpty) {
      await ProgressDialog(context).error(message: '본부·팀·국소명·주소 중\n하나 이상 입력하세요');
      return;
    }
    setState(() {
      _searching = true;
      _selectedNeos = null;
    });
    try {
      final res = await _svc.searchSislPhotos(
        hdqt: _hdqt,
        team: _team,
        facility: facility,
        address: address,
      );
      if (!mounted) return;
      setState(() {
        _groups = List<Map<String, dynamic>>.from(res['groups'] ?? const []);
        _totalPhotos = (res['total_photos'] as int?) ?? 0;
        _searched = true;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _groups = [];
        _totalPhotos = 0;
        _searched = true;
        _searching = false;
      });
      if (mounted) await ProgressDialog(context).error(message: '검색에 실패했습니다');
    }
  }

  void _reset() {
    setState(() {
      _hdqt = '';
      _team = '';
      _facilityCtrl.clear();
      _addressCtrl.clear();
      _groups = [];
      _totalPhotos = 0;
      _selectedNeos = null;
      _searched = false;
    });
  }

  // 우측에 표시할 사진들 (선택 국소 없으면 전체 평면화)
  List<Map<String, dynamic>> get _visiblePhotos {
    final out = <Map<String, dynamic>>[];
    for (final g in _groups) {
      if (_selectedNeos != null && g['neos_code'] != _selectedNeos) continue;
      final name = (g['국소명'] ?? '').toString();
      final addr = (g['주소'] ?? '').toString();
      for (final p in List<Map<String, dynamic>>.from(g['photos'] ?? const [])) {
        out.add({...p, '국소명': name, '주소': addr});
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _bg,
      child: Column(
        children: [
          _buildSearchBar(),
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator())
                : !_searched
                    ? _buildEmptyHint()
                    : _groups.isEmpty
                        ? _buildNoResult()
                        : _buildResultBody(),
          ),
        ],
      ),
    );
  }

  // ── 상단 검색바 ──
  Widget _buildSearchBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: _optionsLoading
          ? const SizedBox(
              height: 40,
              child: Center(child: SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))),
            )
          : LayoutBuilder(builder: (ctx, c) {
              final wide = c.maxWidth >= 900;
              final fields = <({int flex, Widget w})>[
                (flex: 3, w: _labeledField('본부', _hdqtDropdown())),
                (flex: 3, w: _labeledField('팀', _teamDropdown())),
                (flex: 4, w: _labeledField('국소명', _textField(_facilityCtrl, '국소명 입력'))),
                (flex: 4, w: _labeledField('주소', _textField(_addressCtrl, '주소 입력'))),
              ];
              final buttons = Row(mainAxisSize: MainAxisSize.min, children: [
                ElevatedButton.icon(
                  onPressed: _search,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('검색', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _reset,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _textSecondary,
                    side: const BorderSide(color: _border),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('초기화'),
                ),
              ]);

              if (wide) {
                return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  for (final f in fields) ...[Expanded(flex: f.flex, child: f.w), const SizedBox(width: 12)],
                  buttons,
                ]);
              }
              return Column(children: [
                Wrap(spacing: 12, runSpacing: 10, children: [
                  for (final f in fields)
                    SizedBox(width: (c.maxWidth - 12) / 2, child: f.w),
                ]),
                const SizedBox(height: 12),
                Align(alignment: Alignment.centerRight, child: buttons),
              ]);
            }),
    );
  }

  Widget _labeledField(String label, Widget field) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _textSecondary)),
      const SizedBox(height: 4),
      field,
    ]);
  }

  Widget _hdqtDropdown() {
    final items = ['', ..._org.keys];
    return _dropdownBox(
      DropdownButton<String>(
        isExpanded: true,
        isDense: true,
        value: _hdqt,
        icon: const Icon(Icons.arrow_drop_down, color: _primary, size: 20),
        dropdownColor: Colors.white,
        borderRadius: BorderRadius.circular(12),
        style: const TextStyle(color: Colors.black87, fontSize: 13),
        items: items
            .map((v) => DropdownMenuItem(value: v, child: Text(v.isEmpty ? '전체' : v)))
            .toList(),
        onChanged: (v) => setState(() {
          _hdqt = v ?? '';
          _team = ''; // 본부 변경 시 팀 초기화
        }),
      ),
    );
  }

  Widget _teamDropdown() {
    final teams = _teamsForHdqt;
    final items = ['', ...teams];
    return _dropdownBox(
      DropdownButton<String>(
        isExpanded: true,
        isDense: true,
        value: items.contains(_team) ? _team : '',
        icon: const Icon(Icons.arrow_drop_down, color: _primary, size: 20),
        dropdownColor: Colors.white,
        borderRadius: BorderRadius.circular(12),
        style: const TextStyle(color: Colors.black87, fontSize: 13),
        items: items
            .map((v) => DropdownMenuItem(value: v, child: Text(v.isEmpty ? '전체' : v)))
            .toList(),
        onChanged: _hdqt.isEmpty ? null : (v) => setState(() => _team = v ?? ''),
      ),
    );
  }

  Widget _dropdownBox(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(child: child),
    );
  }

  Widget _textField(TextEditingController ctrl, String hint) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(fontSize: 13),
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _search(),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        filled: true,
        fillColor: Colors.white,
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
          borderSide: const BorderSide(color: _primary),
        ),
      ),
    );
  }

  // ── 결과 본문 (좌: 국소 목록 / 우: 사진 그리드) ──
  Widget _buildResultBody() {
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: 230, child: _buildNeosList()),
      const VerticalDivider(width: 1, color: _border),
      Expanded(child: _buildPhotoGrid()),
    ]);
  }

  Widget _buildNeosList() {
    return Container(
      color: Colors.white,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: Text('추출 국소 (${_groups.length})',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _textPrimary)),
        ),
        // '전체' 항목
        _neosTile(
          name: '전체 보기',
          tongsi: null,
          neos: null,
          count: _totalPhotos,
          selected: _selectedNeos == null,
          onTap: () => setState(() => _selectedNeos = null),
        ),
        const Divider(height: 1, color: _border),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: _groups.length,
            itemBuilder: (_, i) {
              final g = _groups[i];
              final neos = (g['neos_code'] ?? '').toString();
              return _neosTile(
                name: (g['국소명'] ?? '').toString(),
                tongsi: (g['통시코드'] ?? '').toString(),
                neos: neos,
                count: (g['photo_count'] as int?) ?? 0,
                selected: _selectedNeos == neos,
                onTap: () => setState(() => _selectedNeos = neos),
              );
            },
          ),
        ),
      ]),
    );
  }

  Widget _neosTile({
    required String name,
    required String? tongsi,
    required String? neos,
    required int count,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? _primary.withValues(alpha: 0.06) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? _primary : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name.isEmpty ? '(국소명 없음)' : name,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                  color: selected ? _primary : _textPrimary,
                ),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            if (tongsi != null && tongsi.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('통시: $tongsi', style: const TextStyle(fontSize: 10.5, color: _textSecondary)),
            ],
            if (neos != null && neos.isNotEmpty)
              Text('공대: $neos', style: const TextStyle(fontSize: 10.5, color: _textSecondary)),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF2196F3),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('이미지 $count건',
                  style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildPhotoGrid() {
    final photos = _visiblePhotos;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Text('총 ${photos.length}개의 사진',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _textPrimary)),
      ),
      Expanded(
        child: photos.isEmpty
            ? const Center(child: Text('표시할 사진이 없습니다', style: TextStyle(color: _textSecondary)))
            : LayoutBuilder(builder: (ctx, c) {
                final cols = c.maxWidth >= 1100
                    ? 4
                    : c.maxWidth >= 820
                        ? 3
                        : c.maxWidth >= 520
                            ? 2
                            : 1;
                return GridView.builder(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: photos.length,
                  itemBuilder: (_, i) => _photoCard(photos, i),
                );
              }),
      ),
    ]);
  }

  Widget _photoCard(List<Map<String, dynamic>> photos, int i) {
    final p = photos[i];
    final url = (p['url'] ?? '').toString();
    final name = (p['국소명'] ?? '').toString();
    final addr = (p['주소'] ?? '').toString();
    final date = fmtSislDate(p['upload_date']);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            child: SislPhotoTile(
              url: url,
              label: '',
              onTap: () => _openViewer(photos, i),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name.isEmpty ? '(국소명 없음)' : name,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: _textPrimary),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            Text('시설물점검($date)',
                style: const TextStyle(fontSize: 11, color: _primary, fontWeight: FontWeight.w500)),
            const SizedBox(height: 3),
            Text(addr,
                style: const TextStyle(fontSize: 11, color: _textSecondary, height: 1.3),
                maxLines: 2, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]),
    );
  }

  void _openViewer(List<Map<String, dynamic>> photos, int index) {
    showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (_) => SislPhotoViewer(items: photos, initialIndex: index),
    );
  }

  Widget _buildEmptyHint() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.image_search_outlined, size: 56, color: Colors.grey.shade300),
        const SizedBox(height: 12),
        const Text('본부·팀·국소명·주소로 시설물 사진을 검색하세요',
            style: TextStyle(fontSize: 14, color: _textSecondary)),
      ]),
    );
  }

  Widget _buildNoResult() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.search_off, size: 56, color: Colors.grey.shade300),
        const SizedBox(height: 12),
        const Text('검색 결과가 없습니다',
            style: TextStyle(fontSize: 14, color: _textSecondary)),
        const SizedBox(height: 4),
        const Text('조건을 바꿔 다시 검색해 보세요',
            style: TextStyle(fontSize: 12, color: _textSecondary)),
      ]),
    );
  }
}
