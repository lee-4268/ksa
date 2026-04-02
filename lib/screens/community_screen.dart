import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/community_service.dart';
import 'notice_board_screen.dart';
import 'request_board_screen.dart';

/// 커뮤니티 통합 화면 — 요약 카드 + 탭(요청 및 문의 / 공지)
class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key});

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  static const _primary = Color(0xFFE53935);
  static const _bg = Color(0xFFFAFAFB);

  final _svc = CommunityService();
  bool _statsLoading = true;
  int _selectedTab = 0; // 0 = 요청 및 문의, 1 = 공지

  // 통계
  int _myTotal = 0;
  int _myReceived = 0;   // 접수
  int _myProcessing = 0; // 처리중
  int _myDone = 0;       // 완료

  int _allTotal = 0;
  int _allReceived = 0;
  int _allProcessing = 0;
  int _allDone = 0;

  int _noticeTotal = 0;

  @override
  void initState() {
    super.initState();
    _svc.setAuthToken(context.read<AuthService>().authToken);
    _loadStats();
  }

  Future<void> _loadStats() async {
    setState(() => _statsLoading = true);
    try {
      final stats = await _svc.getStats();
      if (!mounted) return;
      final my = stats['my'] as Map<String, dynamic>? ?? {};
      final all = stats['all'] as Map<String, dynamic>? ?? {};
      setState(() {
        _myTotal = (my['total'] as int?) ?? 0;
        _myReceived = (my['접수'] as int?) ?? 0;
        _myProcessing = (my['처리중'] as int?) ?? 0;
        _myDone = (my['완료'] as int?) ?? 0;
        _allTotal = (all['total'] as int?) ?? 0;
        _allReceived = (all['접수'] as int?) ?? 0;
        _allProcessing = (all['처리중'] as int?) ?? 0;
        _allDone = (all['완료'] as int?) ?? 0;
        _noticeTotal = (stats['notices'] as int?) ?? 0;
        _statsLoading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _statsLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          // ── 요약 카드 ──
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            child: _buildSummaryCards(),
          ),
          const SizedBox(height: 20),

          // ── 탭 바 ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _buildTabBar(),
          ),
          const SizedBox(height: 4),

          // ── 탭 콘텐츠 ──
          Expanded(
            child: _selectedTab == 0
                ? const RequestBoardScreen(showHeader: false)
                : const NoticeBoardScreen(showHeader: false),
          ),
        ],
      ),
    );
  }

  // ── 요약 카드 Row ──

  Widget _buildSummaryCards() {
    if (_statsLoading) {
      return const SizedBox(
        height: 100,
        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }

    return Row(
      children: [
        Expanded(child: _buildStatCard(
          title: '개인별 요청 현황',
          icon: Icons.person_outline,
          iconColor: const Color(0xFF3B82F6),
          total: _myTotal,
          details: [
            _StatDetail('접수', _myReceived, const Color(0xFF3B82F6)),
            _StatDetail('처리중', _myProcessing, const Color(0xFFF59E0B)),
            _StatDetail('완료', _myDone, const Color(0xFF10B981)),
          ],
        )),
        const SizedBox(width: 16),
        Expanded(child: _buildStatCard(
          title: '전체 요청 현황',
          icon: Icons.groups_outlined,
          iconColor: const Color(0xFF8B5CF6),
          total: _allTotal,
          details: [
            _StatDetail('접수', _allReceived, const Color(0xFF3B82F6)),
            _StatDetail('처리중', _allProcessing, const Color(0xFFF59E0B)),
            _StatDetail('완료', _allDone, const Color(0xFF10B981)),
          ],
        )),
        const SizedBox(width: 16),
        Expanded(child: _buildStatCard(
          title: '공지 현황',
          icon: Icons.campaign_outlined,
          iconColor: _primary,
          total: _noticeTotal,
          details: [],
        )),
      ],
    );
  }

  Widget _buildStatCard({
    required String title,
    required IconData icon,
    required Color iconColor,
    required int total,
    required List<_StatDetail> details,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 20, color: iconColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text('$total', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              const SizedBox(width: 4),
              Text('건', style: TextStyle(fontSize: 14, color: Colors.grey.shade500)),
              if (details.isNotEmpty) ...[
                const Spacer(),
                ...details.map((d) => Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Column(
                    children: [
                      Text(d.label, style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                      const SizedBox(height: 2),
                      Text('${d.count}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: d.color)),
                    ],
                  ),
                )),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // ── 탭 바 ──

  Widget _buildTabBar() {
    return Row(
      children: [
        _buildTab('요청 및 문의', 0),
        const SizedBox(width: 4),
        _buildTab('공지', 1),
        const Spacer(),
      ],
    );
  }

  Widget _buildTab(String label, int index) {
    final selected = _selectedTab == index;
    return GestureDetector(
      onTap: () {
        if (_selectedTab != index) {
          setState(() => _selectedTab = index);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? _primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: selected ? null : Border.all(color: Colors.grey.shade300),
        ),
        child: Text(label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? Colors.white : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }
}

class _StatDetail {
  final String label;
  final int count;
  final Color color;
  const _StatDetail(this.label, this.count, this.color);
}
