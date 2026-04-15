import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../providers/station_provider.dart';
import '../services/auth_service.dart';
import '../services/cloud_data_service.dart';
import '../services/weather_service.dart';
import 'admin/admin_panel_screen.dart';
import 'ds_dashboard_screen.dart';
import 'ds_merge_screen.dart';
import 'callname_screen.dart';
import 'certificate_screen.dart';
import 'erp_ds_compare_screen.dart';
import 'inadequate_management_screen.dart';
import 'change_notification_screen.dart';
import 'inspection_schedule_screen.dart';
import 'inspection_my_list_screen.dart';
import 'inspection_results_screen.dart';
import 'community_screen.dart';
import '../services/community_service.dart';
import '../services/notification_service.dart';

/// 앱 셸 — 사이드바 상시 표시 + 오른쪽 콘텐츠 전환
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // 디자인 토큰
  static const _bg = Color(0xFFFAFAFB);
  static const _surface = Colors.white;
  static const _border = Color(0xFFE5E7EB);
  static const _textPrimary = Color(0xFF111827);
  static const _textSecondary = Color(0xFF6B7280);
  static const _accent = Color(0xFFE53935);
  static const _sidebarWidth = 240.0;

  int _selectedIndex = 0;
  bool _sidebarCollapsed = false;

  @override
  void initState() {
    super.initState();
    _loadCloudData();
  }

  Future<void> _loadCloudData() async {
    final provider = context.read<StationProvider>();
    final cloudService = context.read<CloudDataService>();
    final authService = context.read<AuthService>();
    if (authService.isSignedIn) {
      provider.setCloudDataService(cloudService, userId: authService.userId);
      await provider.loadStations();
    }
  }

  // ── 메뉴 접속 로그 ──

  void _logMenuAccess(String menuName) {
    // Fire and forget — don't await
    final token = context.read<AuthService>().authToken;
    if (token == null) return;
    http.post(
      Uri.parse('${const String.fromEnvironment('API_BASE_URL', defaultValue: 'https://api-sko-kca.skons.net')}/admin/menu-log'),
      headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
      body: json.encode({'menu': menuName}),
    ).ignore();
  }

  // ── 메뉴 정의 ──

  List<_MenuItem> _buildMenuItems(AuthService auth) {
    return [
      _MenuItem('홈', Icons.home_outlined, const Color(0xFF374151), description: '메인 화면'),
      _MenuItem('현장 수검 Map', Icons.map_outlined, const Color(0xFF3B82F6), description: '수검 대상 지도 및 관리'),
      _MenuItem('일정 및 통계', Icons.event_note_outlined, const Color(0xFF10B981), description: '수검 일정 조회 및 통계'),
      _MenuItem('실적 관리', Icons.bar_chart_outlined, const Color(0xFFE53935), description: '본부별 수검 실적 현황'),
      _MenuItem('DS 데이터', Icons.storage_outlined, const Color(0xFF8B5CF6), description: 'DS 데이터 조회 및 분석'),
      _MenuItem('DS 병합', Icons.merge_outlined, const Color(0xFFF59E0B), description: 'DS 데이터 병합 처리'),
      _MenuItem('호출명칭', Icons.sync_alt_outlined, const Color(0xFFEF4444), description: '호출명칭 검색 및 비교'),
      _MenuItem('설치확인서', Icons.description_outlined, const Color(0xFF06B6D4), description: '설치확인서 조회 및 관리'),
      _MenuItem('전산비교', Icons.compare_outlined, const Color(0xFF2563EB), description: 'ERP·DS 전산 데이터 비교'),
      _MenuItem('부적합 관리', Icons.warning_amber_outlined, const Color(0xFFE53935), description: '부적합 현황 관리'),
      _MenuItem('변경개설신고', Icons.swap_horiz_outlined, const Color(0xFFE53935), description: '변경개설신고 파일 비교 및 적용'),
      _MenuItem('커뮤니티', Icons.forum_outlined, const Color(0xFFE53935), description: '공지사항 및 요청사항'),
      if (auth.isSuperAdmin)
        _MenuItem('관리자', Icons.settings_outlined, const Color(0xFF6366F1), description: '시스템 설정 및 사용자 관리'),
    ];
  }

  // 아코디언 그룹 정의
  static const _menuGroups = [
    _MenuGroup('수검 관리', Icons.map_outlined, Color(0xFF3B82F6), ['실적 관리', '일정 및 통계', '현장 수검 Map']),
    _MenuGroup('허가현황 관리', Icons.storage_outlined, Color(0xFF8B5CF6), ['DS 데이터', 'DS 병합']),
    _MenuGroup('서류 관리', Icons.folder_outlined, Color(0xFFEF4444), ['호출명칭', '설치확인서', '전산비교', '부적합 관리', '변경개설신고']),
  ];

  Widget _buildPage(int index, AuthService auth) {
    // 관리자/본부관리자에 따라 인덱스 매핑이 달라짐
    final items = _buildMenuItems(auth);
    if (index >= items.length) index = 0;
    final title = items[index].title;

    switch (title) {
      case '홈': return _HomeContent(onNavigate: (i) { setState(() => _selectedIndex = i); _logMenuAccess(items[i].title); }, menuItems: items);
      case '실적 관리': return const InspectionResultsScreen();
      case '일정 및 통계': return const InspectionScheduleScreen();
      case '현장 수검 Map': return const InspectionMyListScreen();
      case 'DS 데이터': return const DsDashboardScreen();
      case 'DS 병합': return const DsMergeScreen();
      case '호출명칭': return const CallnameScreen();
      case '설치확인서': return const CertificateScreen();
      case '전산비교': return const ErpDsCompareScreen();
      case '부적합 관리': return const InadequateManagementScreen();
      case '변경개설신고': return const ChangeNotificationScreen();
      case '커뮤니티': return CommunityScreen();
      case '관리자': return const AdminPanelScreen();
      default: return _HomeContent(onNavigate: (i) { setState(() => _selectedIndex = i); _logMenuAccess(items[i].title); }, menuItems: items);
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 800;

    return Consumer<AuthService>(
      builder: (context, auth, _) {
        final items = _buildMenuItems(auth);
        if (_selectedIndex >= items.length) _selectedIndex = 0;

        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: _bg,
          drawer: isWide ? null : _buildDrawer(auth, items),
          body: isWide
              ? Row(children: [
                  _buildSidebar(auth, items),
                  const VerticalDivider(width: 1, color: _border),
                  Expanded(child: _buildContentArea(auth, items)),
                ])
              : Column(children: [
                  _buildMobileAppBar(items),
                  Expanded(child: _buildPage(_selectedIndex, auth)),
                ]),
        );
      },
    );
  }

  // ── 모바일 AppBar ──

  Widget _buildMobileAppBar(List<_MenuItem> items) {
    final item = items[_selectedIndex];
    return Container(
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(bottom: BorderSide(color: _border)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.menu, color: _textSecondary, size: 22),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
            const SizedBox(width: 4),
            Icon(item.icon, size: 18, color: item.color),
            const SizedBox(width: 8),
            Text(item.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: _textPrimary)),
            const Spacer(),
            _buildUserAvatar(),
          ],
        ),
      ),
    );
  }

  // ── Drawer (모바일) ──

  Widget _buildDrawer(AuthService auth, List<_MenuItem> items) {
    return Drawer(
      backgroundColor: _surface,
      shape: const RoundedRectangleBorder(),
      child: _buildSidebarContent(auth, items, inDrawer: true),
    );
  }

  // ── 사이드바 (데스크탑) ──

  Widget _buildSidebar(AuthService auth, List<_MenuItem> items) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: _sidebarCollapsed ? 64 : _sidebarWidth,
      decoration: const BoxDecoration(color: _surface),
      child: _buildSidebarContent(auth, items),
    );
  }

  Widget _buildSidebarContent(AuthService auth, List<_MenuItem> items, {bool inDrawer = false}) {
    final collapsed = _sidebarCollapsed && !inDrawer;

    return Column(
      children: [
        // 로고
        Container(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 16,
            left: collapsed ? 12 : 16, right: collapsed ? 12 : 16, bottom: 16,
          ),
          child: Row(
            children: [
              InkWell(
                onTap: () {
                  setState(() => _selectedIndex = 0);
                  _logMenuAccess('홈');
                  if (inDrawer) Navigator.pop(context);
                },
                borderRadius: BorderRadius.circular(9),
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: _accent,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Icon(Icons.cell_tower, color: Colors.white, size: 18),
                ),
              ),
              if (!collapsed) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: InkWell(
                    onTap: () {
                      setState(() => _selectedIndex = 0);
                      _logMenuAccess('홈');
                      if (inDrawer) Navigator.pop(context);
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: const Text('SKO 무선국', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _textPrimary, letterSpacing: 0.5)),
                  ),
                ),
                InkWell(
                  onTap: () => setState(() => _sidebarCollapsed = !_sidebarCollapsed),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.chevron_left, size: 18, color: Colors.grey.shade400),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (collapsed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: () => setState(() => _sidebarCollapsed = false),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade400),
              ),
            ),
          ),
        // 사용자 정보 (로고 바로 아래)
        Padding(
          padding: EdgeInsets.symmetric(horizontal: collapsed ? 8 : 10, vertical: 8),
          child: collapsed
              ? _buildUserAvatar()
              : _buildSidebarUser(auth),
        ),
        const Divider(height: 1, color: _border),

        // 메뉴
        Expanded(
          child: collapsed
              ? ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                  children: items.map((item) {
                    final i = items.indexOf(item);
                    final isSelected = _selectedIndex == i;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Tooltip(
                        message: item.title,
                        child: InkWell(
                          onTap: () {
                            setState(() => _selectedIndex = i);
                            _logMenuAccess(item.title);
                            if (inDrawer) Navigator.pop(context);
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            decoration: BoxDecoration(
                              color: isSelected ? item.color.withValues(alpha: 0.08) : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Center(
                              child: Icon(item.icon, size: 20,
                                  color: isSelected ? item.color : _textSecondary),
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                  children: [
                    // 홈 (단일)
                    _buildSidebarMenuItem(items, 0, inDrawer),
                    const SizedBox(height: 4),
                    // 아코디언 그룹
                    for (final group in _menuGroups)
                      _buildSidebarAccordion(group, items, inDrawer),
                    // 대상 관리, 관리자 (조건부 단일 메뉴)
                    for (var i = 0; i < items.length; i++)
                      if (!_menuGroups.any((g) => g.childTitles.contains(items[i].title)) && items[i].title != '홈')
                        _buildSidebarMenuItem(items, i, inDrawer),
                  ],
                ),
        ),
        SizedBox(height: MediaQuery.of(context).padding.bottom),
      ],
    );
  }

  Widget _buildSidebarMenuItem(List<_MenuItem> items, int i, bool inDrawer) {
    final item = items[i];
    final isSelected = _selectedIndex == i;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: isSelected ? item.color.withValues(alpha: 0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: () {
            setState(() => _selectedIndex = i);
            _logMenuAccess(item.title);
            if (inDrawer) Navigator.pop(context);
          },
          borderRadius: BorderRadius.circular(8),
          hoverColor: const Color(0xFFF3F4F6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(item.icon, size: 18, color: isSelected ? item.color : _textSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(item.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                      color: isSelected ? item.color : const Color(0xFF374151),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarAccordion(_MenuGroup group, List<_MenuItem> items, bool inDrawer) {
    final hasSelectedChild = group.childTitles.any((t) {
      final idx = items.indexWhere((m) => m.title == t);
      return idx >= 0 && _selectedIndex == idx;
    });

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: hasSelectedChild,
          tilePadding: const EdgeInsets.symmetric(horizontal: 10),
          childrenPadding: const EdgeInsets.only(bottom: 2),
          dense: true,
          visualDensity: VisualDensity.compact,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          collapsedShape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          iconColor: _textSecondary,
          collapsedIconColor: _textSecondary,
          title: Row(
            children: [
              Icon(group.icon, size: 18, color: hasSelectedChild ? group.color : _textSecondary),
              const SizedBox(width: 10),
              Text(
                group.title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: hasSelectedChild ? group.color : const Color(0xFF374151),
                ),
              ),
            ],
          ),
          children: group.childTitles.map((title) {
            final idx = items.indexWhere((m) => m.title == title);
            if (idx < 0) return const SizedBox.shrink();
            final item = items[idx];
            final isSelected = _selectedIndex == idx;
            return Align(
              alignment: Alignment.centerLeft,
              child: Material(
                color: isSelected ? item.color.withValues(alpha: 0.08) : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                child: InkWell(
                  onTap: () {
                    setState(() => _selectedIndex = idx);
                    _logMenuAccess(item.title);
                    if (inDrawer) Navigator.pop(context);
                  },
                  borderRadius: BorderRadius.circular(6),
                  hoverColor: const Color(0xFFF3F4F6),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.only(left: 38, top: 7, bottom: 7, right: 10),
                    child: Text(item.title,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                        color: isSelected ? item.color : const Color(0xFF4B5563),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildSidebarUser(AuthService auth) {
    final name = auth.userName ?? auth.userId ?? '';
    final dept = [auth.userDepartment, auth.userTeam].where((s) => s != null && s.isNotEmpty).join(' / ');
    final remaining = auth.remainingSessionMinutes;
    final hours = remaining ~/ 60;
    final minutes = remaining % 60;
    final timeText = hours > 0 ? '$hours:${minutes.toString().padLeft(2, '0')}' : '$minutes분';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: _accent.withValues(alpha: 0.1),
                child: Text(
                  name.isNotEmpty ? name[0] : '?',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _accent),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _textPrimary),
                        overflow: TextOverflow.ellipsis),
                    if (dept.isNotEmpty)
                      Text(dept, style: const TextStyle(fontSize: 10, color: _textSecondary),
                          overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.timer_outlined, size: 12, color: remaining < 30 ? Colors.orange : Colors.grey.shade400),
              const SizedBox(width: 4),
              Text(timeText, style: TextStyle(fontSize: 10, color: remaining < 30 ? Colors.orange : _textSecondary)),
              const Spacer(),
              InkWell(
                onTap: () { auth.extendSession(); setState(() {}); },
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('연장', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: Color(0xFF3B82F6))),
                ),
              ),
              const SizedBox(width: 6),
              InkWell(
                onTap: _handleLogout,
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(Icons.logout, size: 14, color: Colors.grey.shade400),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildUserAvatar() {
    return Consumer<AuthService>(
      builder: (context, auth, _) {
        final name = auth.userName ?? auth.userId ?? '';
        return InkWell(
          onTap: _handleLogout,
          borderRadius: BorderRadius.circular(20),
          child: CircleAvatar(
            radius: 16,
            backgroundColor: _accent.withValues(alpha: 0.1),
            child: Text(name.isNotEmpty ? name[0] : '?',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _accent)),
          ),
        );
      },
    );
  }

  // ── 콘텐츠 영역 ──

  Widget _buildContentArea(AuthService auth, List<_MenuItem> items) {
    return Column(
      children: [
        // 상단 바
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: const BoxDecoration(
            color: _surface,
            border: Border(bottom: BorderSide(color: _border)),
          ),
          child: Row(
            children: [
              Text(items[_selectedIndex].title,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: _textPrimary)),
              const Spacer(),
              _buildUserChip(auth),
            ],
          ),
        ),
        // 콘텐츠
        Expanded(child: _buildPage(_selectedIndex, auth)),
      ],
    );
  }

  Widget _buildUserChip(AuthService auth) {
    final name = auth.userName ?? auth.userId ?? '';
    final remaining = auth.remainingSessionMinutes;
    final isWarning = remaining < 30;
    final hours = remaining ~/ 60;
    final minutes = remaining % 60;
    final timeText = hours > 0 ? '$hours:${minutes.toString().padLeft(2, '0')}' : '$minutes분';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer_outlined, size: 14, color: isWarning ? Colors.orange : Colors.grey.shade400),
        const SizedBox(width: 4),
        Text(timeText, style: TextStyle(fontSize: 12, color: isWarning ? Colors.orange : _textSecondary)),
        const SizedBox(width: 8),
        // 벨 아이콘 + 배지
        Consumer<NotificationService>(
          builder: (context, notifSvc, _) {
            final unread = notifSvc.unreadCount;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  icon: Icon(
                    unread > 0 ? Icons.notifications_rounded : Icons.notifications_none_rounded,
                    size: 22,
                    color: unread > 0 ? _accent : Colors.grey.shade500,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: '알림',
                  onPressed: () => _showNotificationPanel(context, notifSvc),
                ),
                if (unread > 0)
                  Positioned(
                    right: 2,
                    top: 2,
                    child: IgnorePointer(
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: const BoxDecoration(
                          color: _accent,
                          shape: BoxShape.circle,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          unread > 9 ? '9+' : '$unread',
                          style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(width: 4),
        CircleAvatar(
          radius: 14,
          backgroundColor: _accent.withValues(alpha: 0.1),
          child: Text(name.isNotEmpty ? name[0] : '?',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _accent)),
        ),
        const SizedBox(width: 8),
        Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: _textPrimary)),
      ],
    );
  }

  void _showNotificationPanel(BuildContext context, NotificationService notifSvc) {
    showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => _NotificationPanel(
        notifSvc: notifSvc,
        onNavigate: (relatedType, relatedId) {
          Navigator.of(ctx).pop();
          _navigateToCommunity(relatedType, relatedId);
        },
      ),
    );
  }

  void _navigateToCommunity(String relatedType, int relatedId) {
    final items = _buildMenuItems(context.read<AuthService>());
    final idx = items.indexWhere((m) => m.title == '커뮤니티');
    if (idx < 0) return;
    setState(() => _selectedIndex = idx);
    // 딥링크: CommunityScreen에 타겟 전달
    WidgetsBinding.instance.addPostFrameCallback((_) {
      CommunityScreen.navigateTo(context, relatedType: relatedType, relatedId: relatedId);
    });
  }

  // ── 로그아웃 ──

  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('로그아웃', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: const Text('로그아웃 하시겠습니까?', style: TextStyle(fontSize: 14, color: _textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소', style: TextStyle(color: _textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: _accent),
            child: const Text('로그아웃'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await context.read<AuthService>().signOut();
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    }
  }
}

// ── 메뉴 아이템 모델 ──

class _MenuItem {
  final String title;
  final IconData icon;
  final Color color;
  final String description;
  const _MenuItem(this.title, this.icon, this.color, {this.description = ''});
}

class _MenuGroup {
  final String title;
  final IconData icon;
  final Color color;
  final List<String> childTitles;
  const _MenuGroup(this.title, this.icon, this.color, this.childTitles);
}

// ── 홈 콘텐츠 (카드 메뉴 + 인사말) ──

class _HomeContent extends StatefulWidget {
  final void Function(int index) onNavigate;
  final List<_MenuItem> menuItems;
  const _HomeContent({required this.onNavigate, required this.menuItems});

  @override
  State<_HomeContent> createState() => _HomeContentState();
}

class _HomeContentState extends State<_HomeContent> {
  WeatherInfo? _weather;
  bool _loadingWeather = true;

  // 커뮤니티
  final _commSvc = CommunityService();
  bool _commTab = true; // true=공지사항, false=요청사항
  List<Map<String, dynamic>> _commItems = [];
  bool _commLoading = true;

  // 일일 접속자
  int _dailyVisitors = 0;

  // 바로가기 캐러셀
  int _carouselPage = 0;
  late final PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _commSvc.setAuthToken(context.read<AuthService>().authToken);
    _loadWeather();
    _loadComm();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadComm() async {
    setState(() => _commLoading = true);
    try {
      if (_commTab) {
        // 공지사항: 사용자 본부에 따라 필터링
        final auth = context.read<AuthService>();
        // notices.division은 '강북','충청' 등 짧은 한글명으로 저장됨
        final divisionName = auth.currentDivisionShortName; // null이면 지역본부 아님

        Future<List<Map<String, dynamic>>> fetchNotices;
        if (divisionName != null) {
          // 지역본부 소속: '전체' 카테고리 공지 + 본부 카테고리 공지 합쳐서 표시
          fetchNotices = Future.wait([
            _commSvc.getNotices(division: '전체', pageSize: 20),       // 전체 카테고리
            _commSvc.getNotices(division: divisionName, pageSize: 20), // 본부 카테고리
          ]).then((results) {
            final all = <Map<String, dynamic>>{};
            for (final res in results) {
              for (final item in List<Map<String, dynamic>>.from(res['notices'] ?? [])) {
                all.add(item);
              }
            }
            final seen = <dynamic>{};
            final deduped = all.where((item) => seen.add(item['id'])).toList();
            deduped.sort((a, b) {
              final da = a['created_at'] as String? ?? '';
              final db = b['created_at'] as String? ?? '';
              return db.compareTo(da);
            });
            return deduped.take(5).toList();
          });
        } else {
          // 지역본부 아님: '전체' 카테고리만
          fetchNotices = _commSvc.getNotices(division: '전체', pageSize: 5).then(
            (res) => List<Map<String, dynamic>>.from(res['notices'] ?? []),
          );
        }

        final results = await Future.wait([fetchNotices, _commSvc.getStats()]);
        final notices = results[0] as List<Map<String, dynamic>>;
        final stats = results[1] as Map<String, dynamic>;
        if (mounted) setState(() {
          _commItems = notices;
          _dailyVisitors = (stats['daily_visitors'] as int?) ?? 0;
          _commLoading = false;
        });
      } else {
        // 요청사항: 기존과 동일
        final futures = await Future.wait([
          _commSvc.getRequests(pageSize: 5),
          _commSvc.getStats(),
        ]);
        final res = futures[0] as Map<String, dynamic>;
        final stats = futures[1] as Map<String, dynamic>;
        if (mounted) setState(() {
          _commItems = List<Map<String, dynamic>>.from(res['requests'] ?? []);
          _dailyVisitors = (stats['daily_visitors'] as int?) ?? 0;
          _commLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() { _commItems = []; _commLoading = false; });
    }
  }

  Future<void> _loadWeather() async {
    try {
      final w = await WeatherService.getCurrentWeather();
      if (mounted) setState(() { _weather = w; _loadingWeather = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingWeather = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthService>(
      builder: (context, auth, _) {
        final now = DateTime.now();
        final weekday = ['월', '화', '수', '목', '금', '토', '일'][now.weekday - 1];
        final name = auth.userName ?? auth.userId ?? '사용자';
        // 홈(0번)을 제외한 나머지 메뉴만 카드로 표시
        final cards = widget.menuItems.where((m) => m.title != '홈').toList();

        return SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 2000),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 인사 배너
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1E293B), Color(0xFF334155)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('안녕하세요, $name님',
                            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white)),
                        const SizedBox(height: 8),
                        Text(
                          '${now.year}년 ${now.month}월 ${now.day}일 ($weekday)${_weatherText()}',
                          style: TextStyle(fontSize: 14, color: Colors.white.withValues(alpha: 0.7), height: 1.5),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ── 커뮤니티 위젯 + 일일 접속자 (반응형) ──
                  LayoutBuilder(
                    builder: (context, cst) {
                      final wide = cst.maxWidth > 600;
                      if (wide) {
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 3, child: _buildCommunityWidget()),
                            const SizedBox(width: 16),
                            Expanded(flex: 1, child: _buildDailyVisitorCard()),
                          ],
                        );
                      }
                      return _buildCommunityWidget();
                    },
                  ),
                  const SizedBox(height: 20),

                  const SizedBox(height: 20),

                  const Text('바로가기',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                  const SizedBox(height: 4),
                  const Text('자주 사용하는 기능에 빠르게 접근하세요.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
                  const SizedBox(height: 16),

                  // 카드 캐러셀 (PageView 애니메이션)
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final w = constraints.maxWidth;
                      final perPage = w > 800 ? 5 : w > 600 ? 4 : w > 400 ? 3 : 2;
                      final totalPages = (cards.length / perPage).ceil();
                      final hasPrev = _carouselPage > 0;
                      final hasNext = _carouselPage < totalPages - 1;

                      return Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE5E7EB)),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: hasPrev ? () {
                                _pageController.previousPage(
                                  duration: const Duration(milliseconds: 350),
                                  curve: Curves.easeInOut,
                                );
                              } : null,
                              icon: Icon(Icons.chevron_left,
                                  color: hasPrev ? const Color(0xFF374151) : Colors.grey.shade300),
                              splashRadius: 20,
                            ),
                            Expanded(
                              child: SizedBox(
                                height: 150,
                                child: PageView.builder(
                                  controller: _pageController,
                                  onPageChanged: (p) => setState(() => _carouselPage = p),
                                  itemCount: totalPages,
                                  itemBuilder: (_, pageIdx) {
                                    final start = pageIdx * perPage;
                                    final end = (start + perPage).clamp(0, cards.length);
                                    final visible = cards.sublist(start, end);
                                    return Row(
                                      children: [
                                        ...visible.map((card) {
                                          final menuIndex = widget.menuItems.indexOf(card);
                                          return Expanded(
                                            child: Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 6),
                                              child: _buildCarouselCard(card, () => widget.onNavigate(menuIndex)),
                                            ),
                                          );
                                        }),
                                        ...List.generate(
                                          (perPage - visible.length).clamp(0, perPage),
                                          (_) => const Expanded(child: SizedBox()),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: hasNext ? () {
                                _pageController.nextPage(
                                  duration: const Duration(milliseconds: 350),
                                  curve: Curves.easeInOut,
                                );
                              } : null,
                              icon: Icon(Icons.chevron_right,
                                  color: hasNext ? const Color(0xFF374151) : Colors.grey.shade300),
                              splashRadius: 20,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _weatherText() {
    if (_loadingWeather || _weather == null) return '';
    final w = _weather!;
    final temp = w.temperature != null ? '${w.temperature!.toStringAsFixed(0)}°' : '';
    final loc = w.locationName ?? '';
    if (loc.isNotEmpty && temp.isNotEmpty) return '  ·  $loc $temp ${w.condition} ${w.icon}';
    if (temp.isNotEmpty) return '  ·  $temp ${w.condition} ${w.icon}';
    return '  ·  ${w.condition} ${w.icon}';
  }

  Widget _buildDailyVisitorCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        children: [
          Icon(Icons.people_outline, size: 28, color: Colors.blue.shade400),
          const SizedBox(height: 10),
          Text('$_dailyVisitors',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, color: Colors.blue.shade600)),
          const SizedBox(height: 4),
          Text('오늘 접속자',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
        ],
      ),
    );
  }

  Widget _buildCommunityWidget() {
    // 커뮤니티 메뉴 인덱스 찾기
    int commIdx() {
      final idx = widget.menuItems.indexWhere((m) => m.title == '커뮤니티');
      return idx >= 0 ? idx : 0;
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 헤더: 커뮤니티 → + 탭 버튼
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 12, 0),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => widget.onNavigate(commIdx()),
                  child: Row(children: [
                    const Text('커뮤니티',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                    const SizedBox(width: 4),
                    Icon(Icons.arrow_forward_ios, size: 12, color: Colors.grey.shade400),
                  ]),
                ),
                const SizedBox(width: 16),
                _commTabBtn('공지사항', true),
                const SizedBox(width: 4),
                _commTabBtn('요청사항', false),
                const Spacer(),
              ],
            ),
          ),
          const Divider(height: 20),
          // 목록
          if (_commLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: SizedBox(width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else if (_commItems.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text(
                _commTab ? '등록된 공지사항이 없습니다.' : '등록된 요청사항이 없습니다.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
              )),
            )
          else
            ...List.generate(_commItems.length, (i) {
              final item = _commItems[i];
              final title = item['title'] as String? ?? '';
              final date = (item['created_at'] as String? ?? '').split('T').first;
              final isSecret = !_commTab && (item['is_secret'] == true || item['is_secret'] == 1);
              return InkWell(
                onTap: () => widget.onNavigate(commIdx()),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      if (!_commTab) ...[
                        _statusDot(item['status'] as String? ?? '접수'),
                        const SizedBox(width: 8),
                      ],
                      if (isSecret) ...[
                        Icon(Icons.lock, size: 13, color: Colors.grey.shade400),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(title,
                            style: const TextStyle(fontSize: 13, color: Color(0xFF374151)),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      const SizedBox(width: 12),
                      Text(date,
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                    ],
                  ),
                ),
              );
            }),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _commTabBtn(String label, bool isNotice) {
    final selected = _commTab == isNotice;
    return GestureDetector(
      onTap: () {
        if (_commTab != isNotice) {
          setState(() => _commTab = isNotice);
          _loadComm();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1E293B) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: selected ? null : Border.all(color: Colors.grey.shade300),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              color: selected ? Colors.white : Colors.grey.shade600,
            )),
      ),
    );
  }

  Widget _statusDot(String status) {
    final color = status == '완료' ? Colors.green
        : status == '처리중' ? Colors.orange
        : Colors.blue;
    return Container(
      width: 7, height: 7,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  Widget _buildCarouselCard(_MenuItem item, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        hoverColor: const Color(0xFFF3F4F6),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: item.color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(item.icon, size: 22, color: item.color),
              ),
              const SizedBox(height: 10),
              Text(item.title,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                  textAlign: TextAlign.center),
              if (item.description.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(item.description,
                    style: const TextStyle(fontSize: 10, color: Color(0xFF9CA3AF)),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── 알림 패널 다이얼로그 ──────────────────────────────────────

class _NotificationPanel extends StatelessWidget {
  final NotificationService notifSvc;
  final void Function(String relatedType, int relatedId) onNavigate;

  const _NotificationPanel({required this.notifSvc, required this.onNavigate});

  static const _accent = Color(0xFFE53935);
  static const _border = Color(0xFFE5E7EB);
  static const _textPrimary = Color(0xFF111827);

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.only(top: 56, right: 16),
        child: Material(
          elevation: 12,
          borderRadius: BorderRadius.circular(14),
          color: Colors.white,
          child: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 헤더
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.notifications_rounded, size: 18, color: _accent),
                      const SizedBox(width: 8),
                      const Text('알림',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _textPrimary)),
                      const Spacer(),
                      if (notifSvc.unreadCount > 0)
                        TextButton(
                          onPressed: notifSvc.readAll,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            minimumSize: Size.zero,
                          ),
                          child: const Text('전체 읽음',
                              style: TextStyle(fontSize: 12, color: _accent)),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: _border),
                // 목록
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 400),
                  child: notifSvc.items.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 40),
                          child: Column(
                            children: [
                              Icon(Icons.notifications_off_outlined, size: 36, color: Color(0xFFD1D5DB)),
                              SizedBox(height: 8),
                              Text('새 알림이 없습니다',
                                  style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                            ],
                          ),
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: notifSvc.items.length,
                          separatorBuilder: (_, __) => const Divider(height: 1, color: _border),
                          itemBuilder: (ctx, i) {
                            final item = notifSvc.items[i];
                            return _NotificationTile(
                              item: item,
                              onTap: () {
                                notifSvc.readOne(item.id);
                                if (item.relatedId > 0 && item.relatedType.isNotEmpty) {
                                  onNavigate(item.relatedType, item.relatedId);
                                } else {
                                  Navigator.of(ctx).pop();
                                }
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final NotificationItem item;
  final VoidCallback onTap;

  const _NotificationTile({required this.item, required this.onTap});

  static const _accent = Color(0xFFE53935);
  static const _textPrimary = Color(0xFF111827);
  static const _textSecondary = Color(0xFF6B7280);

  IconData get _icon {
    switch (item.type) {
      case 'comment': return Icons.chat_bubble_outline_rounded;
      case 'status': return Icons.check_circle_outline_rounded;
      case 'notice': return Icons.campaign_outlined;
      default: return Icons.notifications_none_rounded;
    }
  }

  Color get _iconColor {
    switch (item.type) {
      case 'comment': return const Color(0xFF3B82F6);
      case 'status': return const Color(0xFF10B981);
      case 'notice': return _accent;
      default: return const Color(0xFF6B7280);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: item.isRead ? Colors.white : const Color(0xFFFFF5F5),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 아이콘
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _iconColor.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(_icon, size: 18, color: _iconColor),
            ),
            const SizedBox(width: 12),
            // 내용
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.title,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: item.isRead ? FontWeight.w500 : FontWeight.w700,
                            color: _textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!item.isRead)
                        Container(
                          width: 7,
                          height: 7,
                          margin: const EdgeInsets.only(left: 6, top: 2),
                          decoration: const BoxDecoration(
                            color: _accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.body,
                    style: const TextStyle(fontSize: 12, color: _textSecondary, height: 1.4),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    NotificationService.relativeTime(item.createdAt),
                    style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
