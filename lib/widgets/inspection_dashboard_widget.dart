import 'package:flutter/material.dart';
import '../services/inspection_service.dart';
import 'app_loader.dart';

/// 홈 화면 "내 할 일" 대시보드 섹션.
/// 역할별로 자동 분기: admin=전사 / manager=자기 본부 / member=자기 본부+팀
class InspectionDashboardWidget extends StatefulWidget {
  final InspectionService svc;
  final int year;
  final void Function(String workflowStatus)? onStatusTap;
  final VoidCallback? onRecheckTap;
  final VoidCallback? onOverdueTap;
  final void Function(String pk)? onScheduleTap;

  const InspectionDashboardWidget({
    super.key,
    required this.svc,
    required this.year,
    this.onStatusTap,
    this.onRecheckTap,
    this.onOverdueTap,
    this.onScheduleTap,
  });

  @override
  State<InspectionDashboardWidget> createState() => _InspectionDashboardWidgetState();
}

class _InspectionDashboardWidgetState extends State<InspectionDashboardWidget> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant InspectionDashboardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.year != widget.year) _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final d = await widget.svc.getDashboard(widget.year);
      if (!mounted) return;
      setState(() { _data = d; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = '$e'; });
    }
  }

  static const _statusOrder = [
    ('PRE_CHECKED', '사전점검완료', Color(0xFF00897B)),
    ('REGISTERED', '등록됨', Color(0xFF6E7780)),
    ('PRE_CHECK', '사전점검중', Color(0xFF6B47DC)),
    ('PRE_CHECK_DONE', '점검완료', Color(0xFF1A8754)),
    ('CHANGE_FILING', '변경개설중', Color(0xFFE17055)),
    ('RE_CHECK', '재점검대기', Color(0xFFE17055)),
    ('REPORT_ISSUED', '내역서발급', Color(0xFF0984E3)),
    ('SUBMITTED', '접수완료', Color(0xFF0984E3)),
    ('INSPECTED', '수검완료', Color(0xFF2D3436)),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: _loading
          ? SizedBox(height: 100, child: AppLoader.centered())
          : _error != null
              ? _buildError()
              : _buildContent(),
    );
  }

  Widget _buildError() {
    return Row(children: [
      Icon(Icons.error_outline, size: 18, color: Colors.red.shade400),
      const SizedBox(width: 8),
      Expanded(child: Text('대시보드 로드 실패: $_error',
          style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
      TextButton(onPressed: _load, child: const Text('재시도')),
    ]);
  }

  Widget _buildContent() {
    final d = _data!;
    final role = d['role'] as String? ?? 'member';
    final scope = d['scope'] as String? ?? '';
    final counts = Map<String, dynamic>.from(d['counts'] ?? {});
    final recheck = (d['recheck'] as num?)?.toInt() ?? 0;
    final overdueTotal = (d['overdue_total'] as num?)?.toInt() ?? 0;
    final deadlineItems = List<Map<String, dynamic>>.from(d['deadline_items'] ?? []);

    final roleLabel = switch (role) {
      'admin' => '관리자',
      'manager' => '본부 관리자',
      _ => '내 팀',
    };

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // 헤더
      Row(children: [
        const Icon(Icons.dashboard_outlined, size: 18, color: Color(0xFF1565C0)),
        const SizedBox(width: 8),
        const Text('내 할 일',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF6FF),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text('$roleLabel · $scope',
              style: const TextStyle(fontSize: 10, color: Color(0xFF1565C0),
                  fontWeight: FontWeight.w600)),
        ),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.refresh, size: 16, color: Color(0xFF6B7280)),
          tooltip: '새로고침',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          onPressed: _load,
        ),
      ]),
      const SizedBox(height: 10),
      // 상태별 카운트 카드 + 알림 카드 통합 그리드 (반응형)
      LayoutBuilder(builder: (_, cst) {
        final perRow = cst.maxWidth > 720 ? 4 : cst.maxWidth > 480 ? 3 : 2;
        final w = (cst.maxWidth - 8 * (perRow - 1)) / perRow;
        final cards = <Widget>[
          ..._statusOrder.map((entry) {
            final (code, label, color) = entry;
            final n = (counts[code] as num?)?.toInt() ?? 0;
            return SizedBox(
              width: w,
              child: _StatusCard(
                label: label, count: n, color: color,
                onTap: n == 0 ? null : () => widget.onStatusTap?.call(code),
              ),
            );
          }),
          if (recheck > 0)
            SizedBox(
              width: w,
              child: _GridAlertCard(
                icon: Icons.warning_amber_rounded,
                color: const Color(0xFFE17055),
                label: '재점검 필요',
                count: recheck,
                onTap: widget.onRecheckTap,
              ),
            ),
          if (overdueTotal > 0)
            SizedBox(
              width: w,
              child: _GridAlertCard(
                icon: Icons.schedule_outlined,
                color: const Color(0xFFE53935),
                label: 'SLA 지연',
                count: overdueTotal,
                onTap: widget.onOverdueTap,
              ),
            ),
        ];
        return Wrap(spacing: 8, runSpacing: 8, children: cards);
      }),
      // 시정기한 도래
      if (deadlineItems.isNotEmpty) ...[
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFFDE68A)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 섹션 헤더
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                decoration: const BoxDecoration(
                  color: Color(0xFFFFFBEB),
                  border: Border(bottom: BorderSide(color: Color(0xFFFDE68A))),
                ),
                child: Row(children: [
                  const Icon(Icons.timer_outlined, size: 14, color: Color(0xFFD97706)),
                  const SizedBox(width: 6),
                  const Text('시정기한 도래',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                          color: Color(0xFF92400E))),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('${deadlineItems.length}건',
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                            color: Color(0xFFD97706))),
                  ),
                ]),
              ),
              // 아이템 목록
              ...deadlineItems.asMap().entries.map((e) => Column(children: [
                if (e.key > 0)
                  const Divider(height: 1, thickness: 1, color: Color(0xFFE5E7EB)),
                _DeadlineRow(item: e.value),
              ])),
            ],
          ),
        ),
      ],
    ]);
  }
}

class _StatusCard extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final VoidCallback? onTap;
  const _StatusCard({
    required this.label, required this.count, required this.color, this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: count > 0 ? color.withValues(alpha: 0.06) : const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: count > 0 ? color.withValues(alpha: 0.3) : Colors.grey.shade200),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                  color: count > 0 ? color : Colors.grey.shade500)),
          const SizedBox(height: 2),
          Text('$count',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700,
                  color: count > 0 ? color : Colors.grey.shade400)),
        ]),
      ),
    );
  }
}

class _GridAlertCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final int count;
  final VoidCallback? onTap;
  const _GridAlertCard({
    required this.icon, required this.color,
    required this.label, required this.count, this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.6), width: 1.5),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
            ),
            Icon(icon, size: 13, color: color),
          ]),
          const SizedBox(height: 2),
          Text('$count',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
        ]),
      ),
    );
  }
}

class _DeadlineRow extends StatelessWidget {
  final Map<String, dynamic> item;
  const _DeadlineRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final name     = '${item['호출명칭'] ?? ''}';
    final lic      = '${item['허가번호'] ?? ''}';
    final deadline = '${item['시정기한'] ?? ''}';
    final region   = '${item['region']   ?? ''}';
    final dLeft    = (item['d_left'] as num?)?.toInt() ?? 0;

    final color = dLeft <= 7
        ? const Color(0xFFE53935)
        : dLeft <= 14
            ? const Color(0xFFE17055)
            : const Color(0xFFF59E0B);

    final displayName = name.isNotEmpty ? name : lic;
    final subText     = name.isNotEmpty ? lic : region;

    return SizedBox(
      height: 52,
      child: Row(
        children: [
          // 긴급도 좌측 stripe
          Container(width: 3, color: color),
          const SizedBox(width: 12),
          // D-X 배지
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withValues(alpha: 0.25)),
            ),
            child: Text(
              'D-$dLeft',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: color),
            ),
          ),
          const SizedBox(width: 10),
          // 이름 + 허가번호/본부
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  displayName,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                      color: Color(0xFF111827)),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
                if (subText.isNotEmpty)
                  Text(
                    subText,
                    style: const TextStyle(fontSize: 10, color: Color(0xFF9CA3AF)),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 시정기한 날짜 (우측 정렬)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  deadline,
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500,
                      color: Color(0xFF374151)),
                ),
                const Text(
                  '시정기한',
                  style: TextStyle(fontSize: 9, color: Color(0xFF9CA3AF)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
