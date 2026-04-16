import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/community_service.dart';
import 'notice_board_screen.dart';
import 'request_board_screen.dart';

/// 알림에서 커뮤니티 특정 글로 이동할 때 사용하는 글로벌 키
final _communityScreenKey = GlobalKey<_CommunityScreenState>();

/// 커뮤니티 통합 화면
class CommunityScreen extends StatefulWidget {
  CommunityScreen() : super(key: _communityScreenKey);

  /// 알림 클릭 시 외부에서 호출: 해당 탭 + 글로 이동
  static void navigateTo(BuildContext context, {required String relatedType, required int relatedId}) {
    _communityScreenKey.currentState?._openDeepLink(relatedType, relatedId);
  }

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  static const _primary = Color(0xFFE53935);
  static const _bg = Color(0xFFFAFAFB);
  static const _border = Color(0xFFE5E7EB);

  final _svc = CommunityService();
  bool _statsLoading = true;
  int _selectedTab = 0; // 0 = 공지, 1 = 요청 및 문의

  // 딥링크: 알림 클릭 시 특정 글로 이동
  int? _deepLinkNoticeId;
  int? _deepLinkRequestId;

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

  /// 모바일에서 상단 통계 카드 접기 (기본 접힘)
  bool _mobileStatsExpanded = false;

  @override
  void initState() {
    super.initState();
    _svc.setAuthToken(context.read<AuthService>().authToken);
    _loadStats();
  }

  void _openDeepLink(String relatedType, int relatedId) {
    if (relatedType == 'notice') {
      setState(() {
        _selectedTab = 0;
        _deepLinkNoticeId = relatedId;
        _deepLinkRequestId = null;
      });
    } else if (relatedType == 'request') {
      setState(() {
        _selectedTab = 1;
        _deepLinkRequestId = relatedId;
        _deepLinkNoticeId = null;
      });
    }
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
    final narrow = MediaQuery.sizeOf(context).width < 760;
    final hPad = narrow ? 12.0 : 24.0;
    final vTop = narrow ? 12.0 : 24.0;
    final gapAfterStats = narrow ? 10.0 : 20.0;

    return Material(
      color: _bg,
      child: Column(
        // 👇 start 대신 stretch를 사용해야 에러가 나지 않고 화면 너비를 안전하게 확보합니다!
        crossAxisAlignment: CrossAxisAlignment.stretch, 
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(hPad, vTop, hPad, 0),
            child: _buildSummaryCards(),
          ),
          SizedBox(height: gapAfterStats),

          Padding(
            padding: EdgeInsets.symmetric(horizontal: hPad),
            child: _buildTabBar(), // 여기에 걸어둔 Align 덕분에 탭은 왼쪽에 붙습니다.
          ),
          SizedBox(height: narrow ? 8 : 12),

          Expanded(
            child: IndexedStack(
              index: _selectedTab,
              children: [
                NoticeBoardScreen(showHeader: false, openNoticeId: _deepLinkNoticeId),
                RequestBoardScreen(showHeader: false, openRequestId: _deepLinkRequestId),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCards() {
    return LayoutBuilder(
      builder: (context, cst) {
        final isNarrow = cst.maxWidth < 760;

        if (_statsLoading) {
          return SizedBox(
            height: isNarrow ? 44 : 108,
            child: const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }

        final cards = [
          _buildStatCard(
            title: '개인별 요청',
            icon: Icons.person_outline,
            iconColor: const Color(0xFF3B82F6),
            total: _myTotal,
            details: [
              _StatDetail('접수', _myReceived, const Color(0xFF3B82F6)),
              _StatDetail('처리중', _myProcessing, const Color(0xFFF59E0B)),
              _StatDetail('완료', _myDone, const Color(0xFF10B981)),
            ],
          ),
          _buildStatCard(
            title: '전체 요청',
            icon: Icons.groups_outlined,
            iconColor: const Color(0xFF8B5CF6),
            total: _allTotal,
            details: [
              _StatDetail('접수', _allReceived, const Color(0xFF3B82F6)),
              _StatDetail('처리중', _allProcessing, const Color(0xFFF59E0B)),
              _StatDetail('완료', _allDone, const Color(0xFF10B981)),
            ],
          ),
          _buildStatCard(
            title: '공지',
            icon: Icons.campaign_outlined,
            iconColor: _primary,
            total: _noticeTotal,
            details: const [],
          ),
        ];

        if (isNarrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                child: InkWell(
                  onTap: () =>
                      setState(() => _mobileStatsExpanded = !_mobileStatsExpanded),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _border),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.stacked_bar_chart,
                            size: 18, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '개인 $_myTotal · 전체 $_allTotal · 공지 $_noticeTotal',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: Colors.grey.shade800,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(
                          _mobileStatsExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 22,
                          color: Colors.grey.shade600,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (_mobileStatsExpanded) ...[
                const SizedBox(height: 10),
                ...cards.map((card) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: card,
                    )),
              ],
            ],
          );
        }

        final cardMinWidth = 250.0;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: cards
              .map(
                (card) => SizedBox(
                  width: cardMinWidth,
                  child: card,
                ),
              )
              .toList(),
        );
      },
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 18, color: iconColor),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF374151),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$total',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827),
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '건',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey.shade500,
                ),
              ),
              if (details.isNotEmpty) ...[
                const Spacer(),
                ...details.map(
                  (d) => Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          d.label,
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${d.count}',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: d.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

Widget _buildTabBar() {
    return Align(
      alignment: Alignment.centerLeft, // 왼쪽 정렬 (요약 카드 시작선과 맞춤)
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min, // 💡 핵심: 내부 요소 크기만큼만 너비 차지
          children: [
            _buildTab('공지', 0), // Expanded 제거
            const SizedBox(width: 4),
            _buildTab('요청 및 문의', 1), // Expanded 제거
          ],
        ),
      ),
    );
  }

  Widget _buildTab(String label, int index) {
    final selected = _selectedTab == index;
    return InkWell(
      onTap: () {
        if (_selectedTab != index) {
          setState(() => _selectedTab = index);
        }
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 38,
        // 💡 핵심: 고정된 비율 대신 텍스트 양옆에 여백을 주어 버튼 크기 생성
        padding: const EdgeInsets.symmetric(horizontal: 24), 
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? _primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? Colors.white : const Color(0xFF4B5563),
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
