import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/station_provider.dart';
import '../services/auth_service.dart';
import '../services/cloud_data_service.dart';
import '../services/weather_service.dart';
import 'division_management_screen.dart';
import 'dashboard_screen.dart';
import 'admin/admin_panel_screen.dart';
import 'ds_dashboard_screen.dart';
import 'ds_merge_screen.dart';
import 'callname_screen.dart';
import 'certificate_screen.dart';
import 'erp_ds_compare_screen.dart';
import 'inspection_schedule_screen.dart';
import 'inspection_my_list_screen.dart';
import 'notice_board_screen.dart';
import 'request_board_screen.dart';

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

  // ── 메뉴 정의 ──

  List<_MenuItem> _buildMenuItems(AuthService auth) {
    return [
      _MenuItem('홈', Icons.home_outlined, const Color(0xFF374151), description: '메인 화면'),
      _MenuItem('전국 현황', Icons.insights_outlined, const Color(0xFF14B8A6), description: '전국 무선국 현황 대시보드'),
      _MenuItem('수검 관리', Icons.map_outlined, const Color(0xFF3B82F6), description: '수검 대상 지도 및 관리'),
      _MenuItem('일정 및 통계', Icons.event_note_outlined, const Color(0xFF10B981), description: '수검 일정 조회 및 통계'),
      _MenuItem('DS 데이터', Icons.storage_outlined, const Color(0xFF8B5CF6), description: 'DS 데이터 조회 및 분석'),
      _MenuItem('DS 병합', Icons.merge_outlined, const Color(0xFFF59E0B), description: 'DS 데이터 병합 처리'),
      _MenuItem('호출명칭', Icons.sync_alt_outlined, const Color(0xFFEF4444), description: '호출명칭 검색 및 비교'),
      _MenuItem('설치확인서', Icons.description_outlined, const Color(0xFF06B6D4), description: '설치확인서 조회 및 관리'),
      _MenuItem('전산비교', Icons.compare_outlined, const Color(0xFF2563EB), description: 'ERP·DS 전산 데이터 비교'),
      _MenuItem('공지사항', Icons.campaign_outlined, const Color(0xFFE53935), description: '조직 내 공지사항'),
      _MenuItem('요청사항', Icons.chat_bubble_outline, const Color(0xFF7C3AED), description: '문의 및 요청사항 등록'),
      if (auth.isDivisionAdmin)
        _MenuItem('대상 관리', Icons.business_outlined, const Color(0xFF7C3AED), description: '본부별 수검 대상 관리'),
      if (auth.isSuperAdmin)
        _MenuItem('관리자', Icons.settings_outlined, const Color(0xFF6366F1), description: '시스템 설정 및 사용자 관리'),
    ];
  }

  // 아코디언 그룹 정의
  static const _menuGroups = [
    _MenuGroup('현황 관리', Icons.insights_outlined, Color(0xFF14B8A6), ['전국 현황']),
    _MenuGroup('수검 관리', Icons.map_outlined, Color(0xFF3B82F6), ['수검 관리', '일정 및 통계']),
    _MenuGroup('DS 관리', Icons.storage_outlined, Color(0xFF8B5CF6), ['DS 데이터', 'DS 병합']),
    _MenuGroup('서류 관리', Icons.folder_outlined, Color(0xFFEF4444), ['호출명칭', '설치확인서', '전산비교']),
    _MenuGroup('커뮤니티', Icons.forum_outlined, Color(0xFFE53935), ['공지사항', '요청사항']),
  ];

  Widget _buildPage(int index, AuthService auth) {
    // 관리자/본부관리자에 따라 인덱스 매핑이 달라짐
    final items = _buildMenuItems(auth);
    if (index >= items.length) index = 0;
    final title = items[index].title;

    switch (title) {
      case '홈': return _HomeContent(onNavigate: (i) => setState(() => _selectedIndex = i), menuItems: items);
      case '전국 현황': return const DashboardScreen();
      case '수검 관리': return const InspectionMyListScreen();
      case '일정 및 통계': return const InspectionScheduleScreen();
      case 'DS 데이터': return const DsDashboardScreen();
      case 'DS 병합': return const DsMergeScreen();
      case '호출명칭': return const CallnameScreen();
      case '설치확인서': return const CertificateScreen();
      case '전산비교': return const ErpDsCompareScreen();
      case '공지사항': return const NoticeBoardScreen();
      case '요청사항': return const RequestBoardScreen();
      case '대상 관리': return const DivisionManagementScreen();
      case '관리자': return const AdminPanelScreen();
      default: return _HomeContent(onNavigate: (i) => setState(() => _selectedIndex = i), menuItems: items);
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
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(Icons.cell_tower, color: Colors.white, size: 18),
              ),
              if (!collapsed) ...[
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('KCA', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _textPrimary, letterSpacing: 0.5)),
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
                  fontWeight: hasSelectedChild ? FontWeight.w600 : FontWeight.w500,
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
        const SizedBox(width: 12),
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

  @override
  void initState() {
    super.initState();
    _loadWeather();
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
              constraints: const BoxConstraints(maxWidth: 960),
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
                  const SizedBox(height: 28),

                  const Text('바로가기',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                  const SizedBox(height: 4),
                  const Text('자주 사용하는 기능에 빠르게 접근하세요.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
                  const SizedBox(height: 16),

                  // 카드 그리드
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final w = constraints.maxWidth;
                      final crossCount = w > 640 ? 3 : w > 400 ? 2 : 1;
                      final ratio = w > 640 ? 2.0 : w > 400 ? 1.8 : 3.2;
                      return GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossCount,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: ratio,
                        ),
                        itemCount: cards.length,
                        itemBuilder: (_, i) {
                          final card = cards[i];
                          // 전체 menuItems에서 해당 카드의 인덱스를 찾아서 onNavigate에 전달
                          final menuIndex = widget.menuItems.indexOf(card);
                          return _buildCard(card, () => widget.onNavigate(menuIndex));
                        },
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

  Widget _buildCard(_MenuItem item, VoidCallback onTap) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          hoverColor: const Color(0xFFF9FAFB),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: item.color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(item.icon, size: 18, color: item.color),
                    ),
                    const Spacer(),
                    Icon(Icons.arrow_forward_ios, size: 12, color: Colors.grey.shade300),
                  ],
                ),
                const SizedBox(height: 12),
                Text(item.title,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                if (item.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(item.description,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
