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
/// 본부담당자가 대상을 선정(요청)하고, 품개팀이 전산비교와 변경신고 요청을 하고,
/// 품혁담당자가 관리소에 신고하고, 최종 완료는 다시 본부담당자가 친다.
/// 완료(PRE_CHECKED)된 국소만 무선국 일정 화면에서 일정 등록 대상이 된다.
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
  static const Color _themeColor = Color(0xFF1565C0);
  static const Color _border = Color(0xFFE5E7EB);
  static const Color _bg = Color(0xFFF9FAFB);
  static const Color _textPrimary = Color(0xFF111827);
  static const Color _textSecondary = Color(0xFF6B7280);
  static const Color _greenColor = Color(0xFF1A8754);
  static const Color _amber = Color(0xFFF59E0B);
  static const Color _danger = Color(0xFFB85B3D);

  final _service = PreCheckService();

  late final TabController _tab;
  late int _year;

  // 대상 목록 상태
  bool _loading = false;
  String? _error;
  List<PreCheckTarget> _items = [];
  int _total = 0;
  Map<String, int> _counts = {};
  List<({String team, int count})> _teams = [];

  String _fltStatus = '';
  String _fltTeam = '';
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
        q: _search,
      );
      final sum = await _service.summary(_year);
      if (!mounted) return;
      setState(() {
        _items = list.items;
        _total = list.total;
        _role = list.role;
        _myTeam = list.myTeam;
        _counts = sum.counts;
        _teams = sum.teams;
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

  List<PreCheckTarget> get _selectedItems =>
      _items.where((e) => _selected.contains(e.licenseNo)).toList();

  // ── 액션 ────────────────────────────────────────────────────
  Future<void> _runAction(
      String label, Future<PreCheckActionResult> Function() run) async {
    if (_selected.isEmpty) return;
    final dialog = ProgressDialog(context);
    try {
      final res = await run();
      if (!mounted) return;
      await dialog.complete(message: '$label — ${res.describe()}');
      _selected.clear();
      await _reload();
    } catch (e) {
      if (!mounted) return;
      await dialog.error(message: '$label 실패\n$e');
    }
  }

  Future<void> _requestSelected() => _runAction(
      '사전대조 요청',
      () => _service.request(
          year: _year, licenseNos: _selected.toList()));

  Future<void> _completeSelected() => _runAction(
      '사전대조 완료',
      () => _service.complete(
          year: _year, licenseNos: _selected.toList()));

  Future<void> _fileSelected() => _runAction(
      '신고 완료',
      () => _service.file(year: _year, licenseNos: _selected.toList()));

  Future<void> _revertSelected() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('사전대조 되돌리기', style: TextStyle(fontSize: 16)),
        content: Text('${_selected.length}건을 미요청 상태로 되돌립니다.\n'
            '일정이 이미 등록된 국소는 제외됩니다.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('되돌리기',
                  style: TextStyle(color: _danger))),
        ],
      ),
    );
    if (ok != true) return;
    await _runAction('되돌리기',
        () => _service.revert(year: _year, licenseNos: _selected.toList()));
  }

  /// 선택한 국소를 들고 전산비교 탭으로 넘어간다. 품개팀이면 착수 표시도 같이.
  Future<void> _goCompare() async {
    if (_selected.isEmpty) return;
    final targets = _selectedItems.map((e) => e.licenseNo).toList();
    // 착수 표시는 실패해도 비교 자체를 막지 않는다 — 상태는 보조 정보다.
    try {
      await _service.start(year: _year, licenseNos: targets);
    } catch (e) {
      debugPrint('pre-check start 실패(무시): $e');
    }
    if (!mounted) return;
    setState(() {
      _compareTargets = targets;
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
            color: Colors.white,
            elevation: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TabBar(
                  controller: _tab,
                  labelColor: _themeColor,
                  unselectedLabelColor: _textSecondary,
                  indicatorColor: _themeColor,
                  tabs: [
                    Tab(text: '대상 목록${_total > 0 ? ' ($_total)' : ''}'),
                    Tab(text: '전산 비교'
                        '${_compareTargets.isNotEmpty ? ' (${_compareTargets.length})' : ''}'),
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
      return const Center(child: AppLoader());
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: _danger, size: 32),
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: _textSecondary)),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _reload, child: const Text('다시 시도')),
        ]),
      );
    }
    return Column(children: [
      _buildFilterBar(),
      _buildActionBar(),
      const Divider(height: 1, color: _border),
      Expanded(child: _buildList()),
    ]);
  }

  Widget _buildFilterBar() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final s in PreCheckStatus.ordered)
            _statusChip(s, _counts[s == PreCheckStatus.none ? 'NONE' : s] ?? 0),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          // 팀 필터. 본부는 서버가 강제로 좁히므로 선택지가 없다 —
          //   품개팀원도 본인 본부 전체가 보이고, 팀만 좁혀 보는 구조.
          SizedBox(
            width: 200,
            child: DropdownButtonFormField<String>(
              initialValue: _fltTeam.isEmpty ? '' : _fltTeam,
              isDense: true,
              decoration: const InputDecoration(
                labelText: '품질개선팀',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('전체')),
                if (_myTeam.isNotEmpty)
                  DropdownMenuItem(value: _myTeam, child: Text('$_myTeam (내 팀)')),
                for (final t in _teams)
                  if (t.team != _myTeam)
                    DropdownMenuItem(
                        value: t.team, child: Text('${t.team} (${t.count})')),
              ],
              onChanged: (v) {
                setState(() => _fltTeam = v ?? '');
                _reload();
              },
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 240,
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: '허가번호 · 호출명칭',
                isDense: true,
                border: const OutlineInputBorder(),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search, size: 18),
                  onPressed: () {
                    setState(() => _search = _searchCtrl.text.trim());
                    _reload();
                  },
                ),
              ),
              onSubmitted: (v) {
                setState(() => _search = v.trim());
                _reload();
              },
            ),
          ),
          const Spacer(),
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          IconButton(
            tooltip: '새로고침',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: _reload,
          ),
        ]),
      ]),
    );
  }

  Widget _statusChip(String s, int count) {
    final selected = _fltStatus == (s == PreCheckStatus.none ? 'NONE' : s);
    final label = '${PreCheckStatus.label(s)} $count';
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (v) {
        setState(() =>
            _fltStatus = v ? (s == PreCheckStatus.none ? 'NONE' : s) : '');
        _reload();
      },
      selectedColor: _statusColor(s).withValues(alpha: 0.18),
      side: BorderSide(
          color: selected ? _statusColor(s) : _border),
    );
  }

  static Color _statusColor(String s) => switch (s) {
        PreCheckStatus.requested => const Color(0xFF4A90D9),
        PreCheckStatus.inProgress => _amber,
        PreCheckStatus.reviewed => const Color(0xFF7C3AED),
        PreCheckStatus.changeRequested => const Color(0xFFE17055),
        PreCheckStatus.changeFiled => const Color(0xFF0891B2),
        PreCheckStatus.done => _greenColor,
        _ => const Color(0xFF9CA3AF),
      };

  Widget _buildActionBar() {
    final sel = _selectedItems;
    final n = sel.length;
    // 버튼은 '선택한 것들이 실제로 그 전이를 할 수 있는가'로 켠다. 상태가 섞여
    //   있으면 서버가 일부를 '상태불가'로 떨구고, 그 결과를 그대로 보여준다.
    final canRequest =
        _isManager && sel.any((e) => e.status == PreCheckStatus.none);
    final canComplete = _isManager &&
        sel.any((e) =>
            e.status == PreCheckStatus.reviewed ||
            e.status == PreCheckStatus.changeFiled);
    final canFile = _isManager &&
        sel.any((e) => e.status == PreCheckStatus.changeRequested);
    final canCompare = sel.isNotEmpty;

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(children: [
        Text(n == 0 ? '선택 없음' : '$n건 선택',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: n == 0 ? _textSecondary : _textPrimary)),
        if (!_isManager && _myTeam.isNotEmpty) ...[
          const SizedBox(width: 10),
          Text('· 내 팀($_myTeam) 국소만 선택할 수 있습니다',
              style: const TextStyle(fontSize: 11, color: _textSecondary)),
        ],
        const Spacer(),
        if (_isManager) ...[
          OutlinedButton.icon(
            icon: const Icon(Icons.undo, size: 14, color: _danger),
            label: const Text('되돌리기', style: TextStyle(color: _danger)),
            style: OutlinedButton.styleFrom(
                side: const BorderSide(color: _danger)),
            onPressed: n == 0 ? null : _revertSelected,
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.assignment_outlined, size: 14),
            label: const Text('사전대조 요청'),
            onPressed: canRequest ? _requestSelected : null,
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.outgoing_mail, size: 14),
            label: const Text('신고 완료'),
            onPressed: canFile ? _fileSelected : null,
          ),
          const SizedBox(width: 8),
        ],
        ElevatedButton.icon(
          icon: const Icon(Icons.compare_arrows, size: 14),
          label: const Text('전산 비교'),
          style: ElevatedButton.styleFrom(
              backgroundColor: _themeColor, foregroundColor: Colors.white),
          onPressed: canCompare ? _goCompare : null,
        ),
        if (_isManager) ...[
          const SizedBox(width: 8),
          ElevatedButton.icon(
            icon: const Icon(Icons.verified_outlined, size: 14),
            label: const Text('사전대조 완료'),
            style: ElevatedButton.styleFrom(
                backgroundColor: _greenColor, foregroundColor: Colors.white),
            onPressed: canComplete ? _completeSelected : null,
          ),
        ],
      ]),
    );
  }

  Widget _buildList() {
    if (_items.isEmpty) {
      return const Center(
        child: Text('대상이 없습니다', style: TextStyle(color: _textSecondary)),
      );
    }
    final editable = _items.where((e) => e.editable).toList();
    final allChecked =
        editable.isNotEmpty && editable.every((e) => _selected.contains(e.licenseNo));

    return Column(children: [
      Container(
        color: const Color(0xFFF3F4F6),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          // 일괄체크는 '지금 화면에 보이는 것 중 내가 손댈 수 있는 것' 전부.
          Checkbox(
            value: allChecked,
            tristate: false,
            onChanged: editable.isEmpty
                ? null
                : (v) => setState(() {
                      if (v == true) {
                        _selected.addAll(editable.map((e) => e.licenseNo));
                      } else {
                        _selected
                            .removeAll(editable.map((e) => e.licenseNo));
                      }
                    }),
          ),
          Text('전체 선택 (${editable.length})',
              style: const TextStyle(fontSize: 12, color: _textSecondary)),
          const Spacer(),
          if (editable.length != _items.length)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                  '타 팀 ${_items.length - editable.length}건은 조회만 가능',
                  style: const TextStyle(fontSize: 11, color: _textSecondary)),
            ),
        ]),
      ),
      Expanded(
        child: ListView.separated(
          itemCount: _items.length,
          separatorBuilder: (_, _) =>
              const Divider(height: 1, color: _border),
          itemBuilder: (_, i) => _buildRow(_items[i]),
        ),
      ),
    ]);
  }

  Widget _buildRow(PreCheckTarget t) {
    final checked = _selected.contains(t.licenseNo);
    return Opacity(
      // 타 팀 건은 흐리게 — 보이지만 내 일이 아니라는 걸 한눈에.
      opacity: t.editable ? 1.0 : 0.55,
      child: InkWell(
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
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(children: [
            Checkbox(
              value: checked,
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
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.callName.isEmpty ? '(호출명칭 없음)' : t.callName,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: _textPrimary),
                      overflow: TextOverflow.ellipsis),
                  Text(t.licenseNo,
                      style: const TextStyle(
                          fontSize: 11, color: _textSecondary)),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Text(
                  t.roadAddress.isNotEmpty ? t.roadAddress : t.installPlace,
                  style: const TextStyle(fontSize: 12, color: _textSecondary),
                  overflow: TextOverflow.ellipsis),
            ),
            Expanded(
              flex: 2,
              child: Text(t.qualityTeam.isEmpty ? '-' : t.qualityTeam,
                  style: const TextStyle(fontSize: 12, color: _textSecondary),
                  overflow: TextOverflow.ellipsis),
            ),
            SizedBox(width: 96, child: _statusBadge(t.status)),
            SizedBox(
              width: 64,
              child: t.hasSchedule
                  ? const Text('일정있음',
                      style: TextStyle(fontSize: 11, color: _greenColor),
                      textAlign: TextAlign.center)
                  : const SizedBox.shrink(),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _statusBadge(String s) {
    final c = _statusColor(s);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.withValues(alpha: 0.35)),
      ),
      child: Text(PreCheckStatus.label(s),
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: c),
          textAlign: TextAlign.center),
    );
  }
}
