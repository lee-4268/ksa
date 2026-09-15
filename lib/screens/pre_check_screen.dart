import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/pre_check_service.dart';
import '../widgets/app_loader.dart';
import '../widgets/progress_dialog.dart';
import 'change_notification_screen.dart';
import 'erp_ds_compare_screen.dart';

/// 사전 대조 — 일정 등록 이전 단계를 한 화면에서 잇는다.
///
/// 대상 목록 → 전산 비교 → 변경 신고 순서가 곧 업무 순서다. 탭을 옮길 때
/// 선택한 국소가 따라가므로 중간에 허가번호를 다시 입력할 일이 없다.
///
/// 본부담당자가 무선국 일정 화면에서 대상을 골라 묶음 이름과 함께 요청하고,
/// 품개팀이 전산비교·변경신고 요청을 하고, 최종 완료는 본부담당자가 친다.
/// 완료(PRE_CHECKED)된 국소만 일정 등록 대상이 된다.
class PreCheckScreen extends StatefulWidget {
  final int? initialYear;

  // 무선국 일정 화면에서 '전산비교'로 넘어온 경우. 전산 비교 탭이 열린 채로
  //   시작한다 — 전산 비교는 단독 메뉴가 없고 이 화면의 탭으로만 존재한다.
  final List<String>? initialCompareLicenseNos;
  final String? initialCompareDivision;
  final bool initialCompareMultiDivision;
  final List<String>? initialCompareSchedulePks;
  final Map<String, Map<String, String>>? initialCompareSchedMap;

  /// 전산 비교에서 일정 화면으로 되돌아가는 콜백(홈 셸이 탭 전환을 처리한다).
  final void Function(List<String> licenseNos)? onScheduleNavigate;

  const PreCheckScreen({
    super.key,
    this.initialYear,
    this.initialCompareLicenseNos,
    this.initialCompareDivision,
    this.initialCompareMultiDivision = false,
    this.initialCompareSchedulePks,
    this.initialCompareSchedMap,
    this.onScheduleNavigate,
  });

  @override
  State<PreCheckScreen> createState() => _PreCheckScreenState();
}

class _PreCheckScreenState extends State<PreCheckScreen>
    with SingleTickerProviderStateMixin {
  // 변경 신고(변경개설신고 관리) 화면과 같은 토큰을 쓴다 — 두 탭이 한 화면이라
  //   색·모서리·간격이 다르면 바로 티가 난다.
  static const Color _themeColor = Color(0xFF1565C0);
  static const Color _border = Color(0xFFE5E7EB);
  static const Color _surface = Colors.white;
  static const Color _bg = Color(0xFFF5F6FA);
  static const Color _textPrimary = Color(0xFF111827);
  static const Color _textSecondary = Color(0xFF6B7280);
  static const Color _greenColor = Color(0xFF1A8754);
  static const Color _danger = Color(0xFFB85B3D);

  final _service = PreCheckService();

  late final TabController _tab;
  late int _year;

  bool _loading = false;
  String? _error;
  List<PreCheckTarget> _items = [];
  int _total = 0;
  Map<String, int> _counts = {};
  List<({String team, int count})> _teams = [];
  List<({String batch, int count})> _batches = [];

  String _fltStatus = '';
  String _fltTeam = '';
  String _fltBatch = '';
  String _search = '';
  final _searchCtrl = TextEditingController();

  /// 허가번호 집합. editable 이 아닌 행은 여기 들어오지 않는다.
  final Set<String> _selected = {};

  /// 전산비교 탭으로 넘길 국소. 탭을 옮기는 순간 고정된다 — 이후 목록에서
  /// 선택을 바꿔도 비교 중인 화면이 흔들리지 않아야 한다.
  List<String> _compareTargets = [];

  // 일정 화면에서 넘어온 비교 컨텍스트. 목록에서 직접 고른 경우엔 비어 있다.
  String? _compareDivision;
  bool _compareMultiDivision = false;
  List<String>? _compareSchedulePks;
  Map<String, Map<String, String>>? _compareSchedMap;

  String _role = 'member';
  String _myTeam = '';

  bool get _isManager => _role == 'admin' || _role == 'manager';
  bool get _hasFilter =>
      _fltBatch.isNotEmpty ||
      _fltTeam.isNotEmpty ||
      _fltStatus.isNotEmpty ||
      _search.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _year = widget.initialYear ?? DateTime.now().year;
    final fromSchedule = widget.initialCompareLicenseNos;
    if (fromSchedule != null && fromSchedule.isNotEmpty) {
      _compareTargets = fromSchedule;
      _compareDivision = widget.initialCompareDivision;
      _compareMultiDivision = widget.initialCompareMultiDivision;
      _compareSchedulePks = widget.initialCompareSchedulePks;
      _compareSchedMap = widget.initialCompareSchedMap;
      _tab.index = 1;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthService>();
      _service.setAuthToken(auth.authToken);
      _reload();
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _service.targets(
        year: _year,
        status: _fltStatus,
        team: _fltTeam,
        batch: _fltBatch,
        q: _search,
      );
      final sum = await _service.summary(_year, batch: _fltBatch);
      if (!mounted) return;
      setState(() {
        _items = list.items;
        _total = list.total;
        _role = list.role;
        _myTeam = list.myTeam;
        _counts = sum.counts;
        _teams = sum.teams;
        _batches = sum.batches;
        // 목록에서 사라진 선택은 버린다(필터 변경·상태 전이 후 유령 선택 방지).
        final visible = _items.map((e) => e.licenseNo).toSet();
        _selected.removeWhere((e) => !visible.contains(e));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  // ── 액션 ────────────────────────────────────────────────────
  Future<void> _runAction(String label, List<String> nos,
      Future<PreCheckActionResult> Function(List<String>) run) async {
    if (nos.isEmpty) return;
    final dialog = ProgressDialog(context);
    try {
      final res = await run(nos);
      if (!mounted) return;
      await dialog.complete(message: '$label — ${res.describe()}');
      _selected.removeAll(nos);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      await dialog.error(message: '$label 실패\n$e');
    }
  }

  Future<void> _complete(List<String> nos) => _runAction('사전대조 완료', nos,
      (n) => _service.complete(year: _year, licenseNos: n));

  Future<void> _file(List<String> nos) => _runAction(
      '신고 완료', nos, (n) => _service.file(year: _year, licenseNos: n));

  Future<void> _revert(List<String> nos) async {
    if (nos.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('사전대조 되돌리기', style: TextStyle(fontSize: 16)),
        content: Text('${nos.length}건을 미요청 상태로 되돌립니다.\n'
            '일정이 이미 등록된 국소는 제외됩니다.',
            style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('되돌리기', style: TextStyle(color: _danger))),
        ],
      ),
    );
    if (ok != true) return;
    await _runAction(
        '되돌리기', nos, (n) => _service.revert(year: _year, licenseNos: n));
  }

  /// 선택한 국소를 들고 전산비교 탭으로 넘어간다. 착수 표시도 같이.
  Future<void> _goCompare(List<String> nos) async {
    if (nos.isEmpty) return;
    // 착수 표시는 실패해도 비교 자체를 막지 않는다 — 상태는 보조 정보다.
    try {
      await _service.start(year: _year, licenseNos: nos);
    } catch (e) {
      debugPrint('pre-check start 실패(무시): $e');
    }
    if (!mounted) return;
    setState(() {
      _compareTargets = nos;
      // 목록에서 직접 고른 건 일정과 무관하다. 일정 화면에서 넘어왔던 컨텍스트가
      //   남아 있으면 엉뚱한 일정에 회신이 붙으므로 반드시 지운다.
      _compareDivision = null;
      _compareMultiDivision = false;
      _compareSchedulePks = null;
      _compareSchedMap = null;
    });
    _tab.animateTo(1);
    _reload();
  }

  // ── 빌드 ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          Material(
            color: _surface,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TabBar(
                  controller: _tab,
                  labelColor: _themeColor,
                  unselectedLabelColor: _textSecondary,
                  indicatorColor: _themeColor,
                  labelStyle: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w700),
                  unselectedLabelStyle: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w500),
                  tabs: [
                    Tab(text: '대상 목록${_total > 0 ? ' $_total' : ''}'),
                    Tab(text: '전산 비교'
                        '${_compareTargets.isNotEmpty ? ' ${_compareTargets.length}' : ''}'),
                    const Tab(text: '변경 신고'),
                  ],
                ),
                const Divider(height: 1, color: _border),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _buildTargetsTab(),
                ErpDsCompareScreen(
                  key: ValueKey(_compareTargets.join(',')),
                  initialLicenseNos:
                      _compareTargets.isEmpty ? null : _compareTargets,
                  initialAccessDivision: _compareDivision,
                  initialMultiDivision: _compareMultiDivision,
                  initialSchedulePks: _compareSchedulePks,
                  initialSchedMap: _compareSchedMap,
                  onScheduleNavigate: widget.onScheduleNavigate,
                  preCheckYear: _year,
                  onPreCheckChanged: _reload,
                ),
                const ChangeNotificationScreen(embedded: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTargetsTab() {
    if (_loading && _items.isEmpty) {
      return Padding(
          padding: const EdgeInsets.all(40), child: AppLoader.centered());
    }
    if (_error != null) {
      return _emptyCard(Icons.error_outline, '대상을 불러오지 못했습니다', _error!,
          action: OutlinedButton(
              onPressed: _reload, child: const Text('다시 시도')));
    }

    // 묶음 → 팀 → 국소. 서버가 요청시각·묶음 순으로 정렬해 준다.
    final bundles = <String, List<PreCheckTarget>>{};
    for (final t in _items) {
      bundles.putIfAbsent(t.batch, () => []).add(t);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildFilterBar(),
              const SizedBox(height: 10),
              Row(children: [
                Text(
                    '묶음 ${bundles.length}개 · 국소 ${_items.length}건'
                    '${_selected.isNotEmpty ? ' · ${_selected.length}건 선택' : ''}',
                    style: const TextStyle(
                        fontSize: 13, color: _textSecondary)),
                if (!_isManager && _myTeam.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text('· 내 팀($_myTeam) 국소만 선택할 수 있습니다',
                      style: const TextStyle(
                          fontSize: 12, color: _textSecondary)),
                ],
                const Spacer(),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  tooltip: '새로고침',
                  onPressed: _reload,
                ),
              ]),
              const SizedBox(height: 8),
              if (_items.isEmpty)
                _hasFilter
                    ? _emptyCard(Icons.filter_alt_off_outlined,
                        '조건에 맞는 대상이 없습니다', '필터를 바꿔보세요.')
                    : _emptyCard(
                        Icons.inbox_outlined,
                        '요청된 사전대조 대상이 없습니다',
                        '무선국 일정 화면에서 본부담당자가 대상을 선택해\n'
                            '[사전대조 요청]을 하면 여기에 묶음으로 나타납니다.')
              else
                ...bundles.entries
                    .map((e) => _buildBundleCard(e.key, e.value)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyCard(IconData icon, String title, String desc,
      {Widget? action}) {
    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(children: [
        Icon(icon, size: 40, color: Colors.grey.shade400),
        const SizedBox(height: 10),
        Text(title,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700, color: _textPrimary)),
        const SizedBox(height: 4),
        Text(desc,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 13, color: _textSecondary, height: 1.5)),
        if (action != null) ...[const SizedBox(height: 12), action],
      ]),
    );
  }

  // ── 필터 바 ─────────────────────────────────────────────────
  // 부적합 관리·변경 요청 목록의 드롭다운과 같은 룩 (40px, F9FAFB, radius 8).
  Widget _dd(String label, String value, List<String> options,
      ValueChanged<String> onChanged,
      {double width = 150, Map<String, String>? labels}) {
    final items = ['', ...options];
    final safe = items.contains(value) ? value : '';
    return SizedBox(
      width: width,
      height: 40,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            isExpanded: true,
            icon: const Icon(Icons.unfold_more,
                color: Color(0xFF9CA3AF), size: 16),
            dropdownColor: Colors.white,
            style: const TextStyle(
                color: _textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
            value: safe,
            borderRadius: BorderRadius.circular(10),
            items: items
                .map((v) => DropdownMenuItem(
                    value: v,
                    child: Text(v.isEmpty ? label : (labels?[v] ?? v),
                        overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: (v) => onChanged(v ?? ''),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    final statusLabels = {
      for (final s in PreCheckStatus.ordered)
        s: '${PreCheckStatus.label(s)} ${_counts[s] ?? 0}'
    };
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Icon(Icons.filter_list, size: 18, color: _textSecondary),
          _dd('요청 묶음', _fltBatch, _batches.map((b) => b.batch).toList(), (v) {
            setState(() {
              _fltBatch = v;
              _selected.clear();
            });
            _reload();
          },
              width: 200,
              labels: {for (final b in _batches) b.batch: '${b.batch} (${b.count})'}),
          _dd('품질개선팀', _fltTeam, _teams.map((t) => t.team).toList(), (v) {
            setState(() => _fltTeam = v);
            _reload();
          },
              width: 170,
              labels: {
                for (final t in _teams)
                  t.team: t.team == _myTeam
                      ? '${t.team} (내 팀)'
                      : '${t.team} (${t.count})'
              }),
          _dd('진행 상태', _fltStatus, PreCheckStatus.ordered, (v) {
            setState(() => _fltStatus = v);
            _reload();
          }, width: 160, labels: statusLabels),
          SizedBox(
            width: 210,
            height: 40,
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: '허가번호 · 호출명칭',
                hintStyle: const TextStyle(fontSize: 13),
                filled: true,
                fillColor: const Color(0xFFF9FAFB),
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: _border)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: _border)),
                suffixIcon: const Icon(Icons.search,
                    size: 18, color: Color(0xFF9CA3AF)),
              ),
              onSubmitted: (v) {
                setState(() => _search = v.trim());
                _reload();
              },
            ),
          ),
          if (_hasFilter)
            TextButton.icon(
              onPressed: () {
                setState(() {
                  _fltBatch = '';
                  _fltTeam = '';
                  _fltStatus = '';
                  _search = '';
                  _searchCtrl.clear();
                  _selected.clear();
                });
                _reload();
              },
              icon: const Icon(Icons.filter_alt_off_outlined, size: 15),
              label: const Text('초기화', style: TextStyle(fontSize: 12.5)),
            ),
        ],
      ),
    );
  }

  // ── 묶음 카드 ───────────────────────────────────────────────
  Widget _buildBundleCard(String batch, List<PreCheckTarget> items) {
    final byTeam = <String, List<PreCheckTarget>>{};
    for (final t in items) {
      byTeam.putIfAbsent(t.qualityTeam.isEmpty ? '(팀 미배정)' : t.qualityTeam,
          () => []).add(t);
    }
    final editable = items.where((e) => e.editable).toList();
    final picked =
        items.where((e) => _selected.contains(e.licenseNo)).toList();
    final allChecked = editable.isNotEmpty &&
        editable.every((e) => _selected.contains(e.licenseNo));

    // 진행 상태 요약 pill — 묶음이 어디까지 갔는지 한 줄로 보인다.
    final byStatus = <String, int>{};
    for (final t in items) {
      byStatus[t.status] = (byStatus[t.status] ?? 0) + 1;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: _border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 묶음 헤더
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            if (editable.isNotEmpty)
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: allChecked,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.addAll(editable.map((e) => e.licenseNo));
                    } else {
                      _selected.removeAll(editable.map((e) => e.licenseNo));
                    }
                  }),
                ),
              )
            else
              const Icon(Icons.layers, size: 18, color: _themeColor),
            const SizedBox(width: 8),
            Text(batch.isEmpty ? '(묶음없음)' : batch,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _textPrimary)),
            const SizedBox(width: 10),
            Expanded(
              child: Wrap(spacing: 6, runSpacing: 4, children: [
                for (final s in PreCheckStatus.ordered)
                  if ((byStatus[s] ?? 0) > 0)
                    _pill('${PreCheckStatus.label(s)} ${byStatus[s]}',
                        _statusColor(s)),
              ]),
            ),
            Text('${items.length}국소',
                style: const TextStyle(fontSize: 11, color: _textSecondary)),
          ]),
          const SizedBox(height: 12),
          ...byTeam.entries.map((e) => _buildTeamSection(e.key, e.value)),
          if (picked.isNotEmpty) ...[
            const SizedBox(height: 12),
            _buildCardActions(picked),
          ],
        ]),
      ),
    );
  }

  Widget _pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }

  /// 팀 섹션 — 변경 요청 목록의 국소 섹션과 같은 FAFAFA 블록.
  Widget _buildTeamSection(String team, List<PreCheckTarget> items) {
    final editable = items.where((e) => e.editable).toList();
    final allChecked = editable.isNotEmpty &&
        editable.every((e) => _selected.contains(e.licenseNo));
    final mine = team == _myTeam;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            if (editable.isNotEmpty)
              SizedBox(
                width: 22,
                height: 22,
                child: Checkbox(
                  value: allChecked,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.addAll(editable.map((e) => e.licenseNo));
                    } else {
                      _selected.removeAll(editable.map((e) => e.licenseNo));
                    }
                  }),
                ),
              )
            else
              const SizedBox(width: 22),
            const SizedBox(width: 4),
            Text(team,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: mine ? _themeColor : _danger)),
            if (mine) ...[
              const SizedBox(width: 5),
              _pill('내 팀', _themeColor),
            ],
            const Spacer(),
            Text('${items.length}건',
                style: const TextStyle(fontSize: 11, color: _textSecondary)),
          ]),
          const SizedBox(height: 4),
          ...items.map(_buildRow),
        ]),
      ),
    );
  }

  Widget _buildRow(PreCheckTarget t) {
    final checked = _selected.contains(t.licenseNo);
    final addr =
        t.roadAddress.isNotEmpty ? t.roadAddress : t.installPlace;
    return Opacity(
      // 타 팀 건은 흐리게 — 보이지만 내 일이 아니라는 걸 한눈에.
      opacity: t.editable ? 1.0 : 0.5,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: !t.editable
            ? null
            : () => setState(() {
                  if (checked) {
                    _selected.remove(t.licenseNo);
                  } else {
                    _selected.add(t.licenseNo);
                  }
                }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
          child: Row(children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: checked,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: !t.editable
                    ? null
                    : (v) => setState(() {
                          if (v == true) {
                            _selected.add(t.licenseNo);
                          } else {
                            _selected.remove(t.licenseNo);
                          }
                        }),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              flex: 5,
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: t.callName.isEmpty ? '(호출명칭 없음)' : t.callName,
                      style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: _textPrimary)),
                  TextSpan(
                      text: '  ${t.licenseNo}',
                      style: const TextStyle(
                          fontSize: 11, color: _textSecondary)),
                ]),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 6,
              child: Text(addr,
                  style: const TextStyle(fontSize: 11, color: _textSecondary),
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            _pill(PreCheckStatus.label(t.status), _statusColor(t.status)),
            SizedBox(
              width: 58,
              child: t.hasSchedule
                  ? const Text('일정있음',
                      style: TextStyle(fontSize: 10, color: _greenColor),
                      textAlign: TextAlign.right)
                  : const SizedBox.shrink(),
            ),
          ]),
        ),
      ),
    );
  }

  /// 카드 하단 액션 — 그 묶음에서 고른 건에만 적용된다.
  Widget _buildCardActions(List<PreCheckTarget> picked) {
    final nos = picked.map((e) => e.licenseNo).toList();
    final canComplete = _isManager &&
        picked.any((e) =>
            e.status == PreCheckStatus.reviewed ||
            e.status == PreCheckStatus.changeFiled);
    final canFile = _isManager &&
        picked.any((e) => e.status == PreCheckStatus.changeRequested);

    return Row(children: [
      if (_isManager)
        OutlinedButton.icon(
          icon: const Icon(Icons.undo, size: 14, color: _danger),
          label: Text('되돌리기 (${nos.length})',
              style: const TextStyle(color: _danger, fontSize: 12.5)),
          style: OutlinedButton.styleFrom(
              side: const BorderSide(color: _danger),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8))),
          onPressed: () => _revert(nos),
        ),
      const Spacer(),
      OutlinedButton.icon(
        icon: const Icon(Icons.compare_arrows, size: 14),
        label: Text('전산 비교 (${nos.length})',
            style: const TextStyle(fontSize: 12.5)),
        style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
        onPressed: () => _goCompare(nos),
      ),
      if (canFile) ...[
        const SizedBox(width: 8),
        _filledAction(Icons.outgoing_mail, '신고 완료',
            const Color(0xFF0984E3), () => _file(nos)),
      ],
      if (canComplete) ...[
        const SizedBox(width: 8),
        _filledAction(Icons.verified_outlined, '사전대조 완료', _greenColor,
            () => _complete(nos)),
      ],
    ]);
  }

  Widget _filledAction(
      IconData icon, String label, Color color, VoidCallback onPressed) {
    return ElevatedButton.icon(
      icon: Icon(icon, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 12.5)),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: onPressed,
    );
  }

  static Color _statusColor(String s) => switch (s) {
        PreCheckStatus.requested => const Color(0xFF4A90D9),
        PreCheckStatus.inProgress => const Color(0xFFD97706),
        PreCheckStatus.reviewed => const Color(0xFF7C3AED),
        PreCheckStatus.changeRequested => const Color(0xFFE17055),
        PreCheckStatus.changeFiled => const Color(0xFF0891B2),
        PreCheckStatus.done => _greenColor,
        _ => const Color(0xFF9CA3AF),
      };
}
