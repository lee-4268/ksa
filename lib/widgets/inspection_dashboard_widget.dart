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
      // 시정기한 도래 국소
      if (deadlineItems.isNotEmpty) ...[
        const SizedBox(height: 10),
        const Text('시정기한 도래',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                color: Color(0xFF6B7280))),
        const SizedBox(height: 4),
        ...deadlineItems.map((it) => _DeadlineRow(item: it)),
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
    final name = '${item['호출명칭'] ?? ''}';
    final lic = '${item['허가번호'] ?? ''}';
    final deadline = '${item['시정기한'] ?? ''}';
    final dLeft = (item['d_left'] as num?)?.toInt() ?? 0;
    final isUrgent = dLeft <= 14;
    final color = dLeft <= 7
        ? const Color(0xFFE53935)
        : dLeft <= 14
            ? const Color(0xFFE17055)
            : const Color(0xFF6B7280);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: isUrgent ? 0.12 : 0.06),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text('D-$dLeft',
              style: TextStyle(fontSize: 10, color: color,
                  fontWeight: FontWeight.w700)),
        ),
        const SizedBox(width: 6),
        Text(deadline,
            style: const TextStyle(fontSize: 10, color: Color(0xFF6B7280),
                fontWeight: FontWeight.w500)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(name.isNotEmpty ? name : lic,
              style: const TextStyle(fontSize: 12, color: Color(0xFF111827)),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ]),
    );
  }
}
