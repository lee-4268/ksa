import 'dart:async';
import 'package:flutter/material.dart';
import '../services/inspection_service.dart';

/// 우상단 종 아이콘 + 안 읽음 배지 + 클릭 시 알림 패널.
class NotificationBellButton extends StatefulWidget {
  final InspectionService svc;
  final Color iconColor;

  const NotificationBellButton({
    super.key,
    required this.svc,
    this.iconColor = Colors.black87,
  });

  @override
  State<NotificationBellButton> createState() => _NotificationBellButtonState();
}

class _NotificationBellButtonState extends State<NotificationBellButton> {
  int _unread = 0;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    // 60초마다 안 읽음 카운트 폴링 (적당한 절충 — WebSocket 미사용 환경)
    _poll = Timer.periodic(const Duration(seconds: 60), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    try {
      final n = await widget.svc.getUnreadNotificationCount();
      if (!mounted) return;
      setState(() => _unread = n);
    } catch (_) {
      // 인증 만료 등 — 조용히 무시
    }
  }

  Future<void> _openPanel() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _NotificationPanel(svc: widget.svc),
    );
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(clipBehavior: Clip.none, children: [
      IconButton(
        icon: Icon(Icons.notifications_outlined, color: widget.iconColor, size: 22),
        tooltip: '알림',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        onPressed: _openPanel,
      ),
      if (_unread > 0)
        Positioned(
          right: 4, top: 4,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFE53935),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              constraints: const BoxConstraints(minWidth: 18, minHeight: 14),
              child: Text(
                _unread > 99 ? '99+' : '$_unread',
                style: const TextStyle(
                  color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold,
                  height: 1.0,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
    ]);
  }
}

class _NotificationPanel extends StatefulWidget {
  final InspectionService svc;
  const _NotificationPanel({required this.svc});

  @override
  State<_NotificationPanel> createState() => _NotificationPanelState();
}

class _NotificationPanelState extends State<_NotificationPanel> {
  bool _loading = true;
  bool _unreadOnly = false;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await widget.svc.getNotifications(unreadOnly: _unreadOnly, limit: 100);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('알림 조회 실패: $e')),
      );
    }
  }

  Future<void> _markAllRead() async {
    try {
      await widget.svc.markNotificationsRead();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('일괄 읽음 실패: $e')),
      );
    }
  }

  Future<void> _markOneRead(int id) async {
    try {
      await widget.svc.markNotificationsRead(ids: [id]);
      // 낙관적 갱신
      setState(() {
        final i = _items.indexWhere((e) => e['id'] == id);
        if (i >= 0) _items[i] = {..._items[i], 'read_at': DateTime.now().toIso8601String()};
      });
    } catch (_) {}
  }

  String _typeLabel(String type) {
    return switch (type) {
      'PRE_CHECK_REQUESTED' => '사전점검 의뢰',
      'PRE_CHECK_REPLIED'   => '사전점검 회신',
      'CHANGE_REQUESTED'    => '변경개설 작성 요청',
      'CHANGE_FILED'        => '전파관리소 신고 완료',
      'RE_CHECK_DONE'       => '부분 DS 적용 완료',
      'REPORT_ISSUED'       => '검사내역서 발급',
      'SUBMITTED'           => '전파관리소 접수 완료',
      'INSPECTED'           => '수검 완료',
      'SLA_OVERDUE'         => '지연 알림',
      _                     => type,
    };
  }

  Color _typeColor(String type) {
    return switch (type) {
      'PRE_CHECK_REQUESTED' => const Color(0xFF6B47DC),
      'PRE_CHECK_REPLIED' || 'RE_CHECK_DONE' => const Color(0xFF1A8754),
      'CHANGE_REQUESTED' || 'CHANGE_FILED' => const Color(0xFFE17055),
      'REPORT_ISSUED' || 'SUBMITTED' => const Color(0xFF0984E3),
      'INSPECTED' => const Color(0xFF2D3436),
      'SLA_OVERDUE' => const Color(0xFFE53935),
      _ => const Color(0xFF6E7780),
    };
  }

  String _timeAgo(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final t = DateTime.parse(iso).toLocal();
      final diff = DateTime.now().difference(t);
      if (diff.inSeconds < 60) return '방금';
      if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
      if (diff.inHours < 24) return '${diff.inHours}시간 전';
      if (diff.inDays < 7) return '${diff.inDays}일 전';
      return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: SizedBox(
        width: screenSize.width > 600 ? 480 : screenSize.width * 0.9,
        height: screenSize.height * 0.75,
        child: Column(children: [
          // 헤더
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
            decoration: const BoxDecoration(
              color: Color(0xFFF8F9FA),
              borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
              border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
            ),
            child: Row(children: [
              const Icon(Icons.notifications, color: Color(0xFF1565C0), size: 20),
              const SizedBox(width: 8),
              const Text('알림',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const Spacer(),
              // 안 읽음만 토글
              FilterChip(
                label: Text('안 읽음만',
                    style: TextStyle(fontSize: 11,
                        color: _unreadOnly ? Colors.white : const Color(0xFF6B7280))),
                selected: _unreadOnly,
                showCheckmark: false,
                backgroundColor: Colors.white,
                selectedColor: const Color(0xFF1565C0),
                side: BorderSide(color: Colors.grey.shade300),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onSelected: (v) {
                  setState(() => _unreadOnly = v);
                  _load();
                },
              ),
              const SizedBox(width: 6),
              TextButton.icon(
                icon: const Icon(Icons.done_all, size: 14),
                label: const Text('모두 읽음', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF1565C0),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 32),
                ),
                onPressed: _markAllRead,
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () => Navigator.pop(context),
              ),
            ]),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _items.isEmpty
                    ? Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.notifications_off_outlined,
                              size: 48, color: Colors.grey.shade300),
                          const SizedBox(height: 8),
                          Text(_unreadOnly ? '안 읽은 알림이 없습니다' : '알림이 없습니다',
                              style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                        ]),
                      )
                    : ListView.builder(
                        itemCount: _items.length,
                        itemBuilder: (_, i) {
                          final n = _items[i];
                          final id = n['id'] as int;
                          final type = '${n['type'] ?? ''}';
                          final msg = '${n['message'] ?? ''}';
                          final read = n['read_at'] != null;
                          final color = _typeColor(type);
                          return InkWell(
                            onTap: read ? null : () => _markOneRead(id),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: read ? Colors.white : const Color(0xFFF0F9FF),
                                border: Border(
                                  bottom: BorderSide(color: Colors.grey.shade100),
                                  left: BorderSide(
                                      color: read ? Colors.transparent : color,
                                      width: 3),
                                ),
                              ),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(_typeLabel(type),
                                      style: TextStyle(
                                          fontSize: 10, color: color,
                                          fontWeight: FontWeight.w600)),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(msg,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: const Color(0xFF111827),
                                            fontWeight: read
                                                ? FontWeight.normal
                                                : FontWeight.w600,
                                          )),
                                      const SizedBox(height: 2),
                                      Text(_timeAgo(n['created_at'] as String?),
                                          style: TextStyle(
                                              fontSize: 10,
                                              color: Colors.grey.shade500)),
                                    ],
                                  ),
                                ),
                                if (!read)
                                  Container(
                                    width: 8, height: 8,
                                    margin: const EdgeInsets.only(top: 4, left: 6),
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF1565C0),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                              ]),
                            ),
                          );
                        },
                      ),
          ),
        ]),
      ),
    );
  }
}
