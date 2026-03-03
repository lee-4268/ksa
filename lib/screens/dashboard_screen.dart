import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../widgets/korea_map_widget.dart';
import 'map_screen.dart';
import 'schedule_screen.dart';
import 'division_management_screen.dart';
import 'admin/admin_panel_screen.dart';
import 'ds_dashboard_screen.dart';
import 'ds_merge_screen.dart';
import '../widgets/user_profile_button.dart';

/// 전국 현황 대시보드 화면
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  static const Color _primaryColor = Color(0xFFE53935);
  static const Color _blueAccent = Color(0xFF4A90D9);
  static const Color _greenColor = Color(0xFF43A047);
  static const Color _indigoColor = Color(0xFF5C6BC0);

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  String? _selectedRegion;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  // 샘플 데이터 (실제로는 API에서 가져와야 함)
  // 9개 본부: 강남, 강북, 인천, 경기, 경남, 경북, 서부, 충청, 강원
  final Map<String, RegionData> _regionData = {
    'gangnam': RegionData(
      name: '강남본부',
      shortName: '강남',
      total: 480,  // 강남, 관악, 강동, 양천
      completed: 442,
    ),
    'gangbuk': RegionData(
      name: '강북본부',
      shortName: '강북',
      total: 520,  // 용산, 종로, 성수, 수유
      completed: 478,
    ),
    'incheon': RegionData(
      name: '인천본부',
      shortName: '인천',
      total: 680,  // 북인천, 남인천, 부천, 일산, 남양주, 의정부
      completed: 578,
    ),
    'gyeonggi': RegionData(
      name: '경기본부',
      shortName: '경기',
      total: 620,  // 수원, 평택, 하남, 분당, 용인
      completed: 521,
    ),
    'gangwon': RegionData(
      name: '강원본부',
      shortName: '강원',
      total: 320,  // 원주, 춘천, 강릉
      completed: 250,
    ),
    'chungcheong': RegionData(
      name: '충청본부',
      shortName: '충청',
      total: 580,  // 대전, 천안, 세종, 서산, 서청주, 동청주, 충주
      completed: 493,
    ),
    'gyeongbuk': RegionData(
      name: '경북본부',
      shortName: '경북',
      total: 540,  // 동대구, 서대구, 경산, 포항, 안동, 구미
      completed: 351,
    ),
    'gyeongnam': RegionData(
      name: '경남본부',
      shortName: '경남',
      total: 650,  // 동부산, 서부산, 김해, 울산, 진주, 창원
      completed: 462,
    ),
    'seobu': RegionData(
      name: '서부본부',
      shortName: '서부',
      total: 590,  // 서광주, 동광주, 목포, 순천, 제주, 전주, 군산
      completed: 519,
    ),
  };

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  int get _totalStations =>
      _regionData.values.fold(0, (sum, r) => sum + r.total);
  int get _completedStations =>
      _regionData.values.fold(0, (sum, r) => sum + r.completed);
  double get _overallProgress =>
      _totalStations > 0 ? _completedStations / _totalStations : 0.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: _buildAppBar(),
      drawer: _buildDrawer(),
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: _buildBody(),
      ),
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: Colors.white,
      child: Column(
        children: [
          // 헤더
          Container(
            width: double.infinity,
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 24,
              bottom: 24,
              left: 20,
              right: 20,
            ),
            decoration: const BoxDecoration(
              color: _primaryColor,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.cell_tower,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                    const Spacer(),
                    // 로그아웃 버튼
                    IconButton(
                      onPressed: _handleLogout,
                      icon: const Icon(Icons.logout, color: Colors.white),
                      tooltip: '로그아웃',
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.15),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  '무선국 관리 시스템',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Consumer<AuthService>(
                  builder: (context, auth, _) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          auth.userName ?? auth.userId ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (auth.userDepartment != null || auth.userTeam != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            [auth.userDepartment, auth.userTeam]
                                .where((s) => s != null)
                                .join(' / '),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
          // 메뉴 리스트
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                const SizedBox(height: 8),
                _buildDrawerItem(
                  icon: Icons.dashboard_rounded,
                  title: '전국 현황',
                  subtitle: '본부별 수검 진행률 및 로드맵',
                  color: const Color(0xFF00897B),
                  isSelected: true,
                  onTap: () => Navigator.pop(context),
                ),
                _buildDrawerItem(
                  icon: Icons.description_outlined,
                  title: '수검 관리',
                  subtitle: '무선국 검사 및 현장 수검 관리',
                  color: _blueAccent,
                  onTap: () => _navigateFromDrawer(const MapScreen()),
                ),
                _buildDrawerItem(
                  icon: Icons.calendar_month,
                  title: '일정 및 통계',
                  subtitle: '검사 일정 관리 및 진도율 확인',
                  color: _greenColor,
                  onTap: () => _navigateFromDrawer(const ScheduleScreen()),
                ),
                _buildDrawerItem(
                  icon: Icons.storage,
                  title: 'DS 데이터 관리',
                  subtitle: '업로드, 조회, Excel Export 통합 관리',
                  color: const Color(0xFF5C6BC0),
                  onTap: () => _navigateFromDrawer(const DsDashboardScreen()),
                ),
                _buildDrawerItem(
                  icon: Icons.merge_type,
                  title: 'DS 파일 병합',
                  subtitle: 'ZIP 파일을 병합하여 Excel 다운로드',
                  color: const Color(0xFFF57C00),
                  onTap: () => _navigateFromDrawer(const DsMergeScreen()),
                ),
                // 전체 대상 관리 (본부 담당자만 표시)
                Consumer<AuthService>(
                  builder: (context, auth, _) {
                    if (auth.isDivisionAdmin) {
                      return _buildDrawerItem(
                        icon: Icons.business,
                        title: '전체 대상 관리',
                        subtitle: '본부 수검 대상 등록 및 관리',
                        color: const Color(0xFF7B1FA2),
                        onTap: () => _navigateFromDrawer(const DivisionManagementScreen()),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
                // 관리자 메뉴 (관리자만 표시)
                Consumer<AuthService>(
                  builder: (context, auth, _) {
                    if (auth.isAdmin) {
                      return _buildDrawerItem(
                        icon: Icons.admin_panel_settings,
                        title: '관리자 패널',
                        subtitle: '사용자 승인 및 팀 관리',
                        color: _indigoColor,
                        onTap: () => _navigateFromDrawer(const AdminPanelScreen()),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Divider(height: 32),
                ),
              ],
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }

  Widget _buildDrawerItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
    bool isSelected = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 15,
            color: isSelected ? color : null,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        onTap: onTap,
        selected: isSelected,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        selectedTileColor: color.withValues(alpha: 0.05),
      ),
    );
  }

  void _navigateFromDrawer(Widget screen) {
    Navigator.pop(context);
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  Future<void> _handleLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('로그아웃'),
        content: const Text('로그아웃 하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('취소', style: TextStyle(color: Colors.grey.shade600)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: _primaryColor),
            child: const Text('로그아웃'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      await context.read<AuthService>().signOut();
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.menu, color: Colors.black54),
        onPressed: () => _scaffoldKey.currentState?.openDrawer(),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _primaryColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.cell_tower,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            '무선국 관리 시스템',
            style: TextStyle(
              color: Colors.black87,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      centerTitle: true,
      actions: [
        UserProfileButton(onLogout: _handleLogout),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 800;

        if (isWide) {
          return _buildWideLayout();
        } else {
          return _buildNarrowLayout();
        }
      },
    );
  }

  /// 넓은 화면 (웹/태블릿)
  Widget _buildWideLayout() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          // 상단 통계 카드
          _buildStatsRow(),
          const SizedBox(height: 24),
          // 지도 + 지역 상세 (가로 배치)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: _buildMapCard(),
              ),
              const SizedBox(width: 24),
              Expanded(
                flex: 2,
                child: _buildRegionDetailCard(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 좁은 화면 (모바일)
  Widget _buildNarrowLayout() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // 상단 통계 카드 (세로 배치)
          _buildStatsColumn(),
          const SizedBox(height: 16),
          // 지도
          _buildMapCard(),
          const SizedBox(height: 16),
          // 지역 상세
          _buildRegionDetailCard(),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    return Row(
      children: [
        Expanded(child: _buildStatCard(
          '전체 무선국',
          _totalStations.toString(),
          Icons.cell_tower,
          _blueAccent,
        )),
        const SizedBox(width: 16),
        Expanded(child: _buildStatCard(
          '수검 완료',
          _completedStations.toString(),
          Icons.check_circle,
          const Color(0xFF43A047),
        )),
        const SizedBox(width: 16),
        Expanded(child: _buildStatCard(
          '미수검',
          (_totalStations - _completedStations).toString(),
          Icons.pending_outlined,
          const Color(0xFFFFA726),
        )),
        const SizedBox(width: 16),
        Expanded(child: _buildStatCard(
          '전체 진행률',
          '${(_overallProgress * 100).toStringAsFixed(1)}%',
          Icons.trending_up,
          _primaryColor,
        )),
      ],
    );
  }

  Widget _buildStatsColumn() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _buildStatCard(
              '전체 무선국',
              _totalStations.toString(),
              Icons.cell_tower,
              _blueAccent,
              compact: true,
            )),
            const SizedBox(width: 12),
            Expanded(child: _buildStatCard(
              '수검 완료',
              _completedStations.toString(),
              Icons.check_circle,
              const Color(0xFF43A047),
              compact: true,
            )),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildStatCard(
              '미수검',
              (_totalStations - _completedStations).toString(),
              Icons.pending_outlined,
              const Color(0xFFFFA726),
              compact: true,
            )),
            const SizedBox(width: 12),
            Expanded(child: _buildStatCard(
              '전체 진행률',
              '${(_overallProgress * 100).toStringAsFixed(1)}%',
              Icons.trending_up,
              _primaryColor,
              compact: true,
            )),
          ],
        ),
      ],
    );
  }

  Widget _buildStatCard(
    String title,
    String value,
    IconData icon,
    Color color, {
    bool compact = false,
  }) {
    return Container(
      padding: EdgeInsets.all(compact ? 14 : 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(compact ? 6 : 8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: compact ? 18 : 22),
              ),
              const Spacer(),
            ],
          ),
          SizedBox(height: compact ? 10 : 16),
          Text(
            value,
            style: TextStyle(
              fontSize: compact ? 22 : 28,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: TextStyle(
              fontSize: compact ? 12 : 14,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapCard() {
    return Container(
      constraints: const BoxConstraints(minHeight: 480),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.map_outlined, color: _blueAccent, size: 22),
              const SizedBox(width: 8),
              const Text(
                '전국 수검 현황',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const Spacer(),
              _buildLegend(),
            ],
          ),
          const SizedBox(height: 20),
          // 전체 진행률 바
          _buildOverallProgressBar(),
          const SizedBox(height: 20),
          // 지도
          SizedBox(
            height: 380,
            child: KoreaMapWidget(
              regionData: _regionData,
              selectedRegion: _selectedRegion,
              onRegionTap: (regionId, data) {
                setState(() {
                  _selectedRegion = regionId;
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegend() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildLegendItem('80%+', const Color(0xFF43A047)),
        const SizedBox(width: 12),
        _buildLegendItem('50-80%', const Color(0xFFFFA726)),
        const SizedBox(width: 12),
        _buildLegendItem('50%-', const Color(0xFFE53935)),
      ],
    );
  }

  Widget _buildLegendItem(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  Widget _buildOverallProgressBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '전체 진행률',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade600,
              ),
            ),
            Text(
              '$_completedStations / $_totalStations (${(_overallProgress * 100).toStringAsFixed(1)}%)',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: _overallProgress,
            minHeight: 10,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation(
              _overallProgress >= 0.8
                  ? const Color(0xFF43A047)
                  : _overallProgress >= 0.5
                      ? const Color(0xFFFFA726)
                      : _primaryColor,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRegionDetailCard() {
    final selectedData = _selectedRegion != null
        ? _regionData[_selectedRegion]
        : null;

    return Container(
      constraints: const BoxConstraints(minHeight: 400),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.analytics_outlined, color: _blueAccent, size: 22),
              const SizedBox(width: 8),
              Text(
                selectedData != null ? '${selectedData.name} 상세' : '본부별 현황',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (selectedData != null)
            _buildSelectedRegionDetail(selectedData)
          else
            _buildRegionList(),
        ],
      ),
    );
  }

  Widget _buildSelectedRegionDetail(RegionData data) {
    final remaining = data.total - data.completed;

    return Column(
      children: [
        // 큰 진행률 원형
        Center(
          child: SizedBox(
            width: 140,
            height: 140,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 140,
                  height: 140,
                  child: CircularProgressIndicator(
                    value: data.progressRate,
                    strokeWidth: 12,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: AlwaysStoppedAnimation(_getProgressColor(data.progressRate)),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${data.progressPercent}%',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: _getProgressColor(data.progressRate),
                      ),
                    ),
                    Text(
                      '진행률',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        // 상세 수치
        _buildDetailRow('전체 무선국', data.total.toString(), Icons.cell_tower),
        const SizedBox(height: 12),
        _buildDetailRow('수검 완료', data.completed.toString(), Icons.check_circle,
            color: const Color(0xFF43A047)),
        const SizedBox(height: 12),
        _buildDetailRow('미수검', remaining.toString(), Icons.pending_outlined,
            color: const Color(0xFFFFA726)),
        const SizedBox(height: 20),
        // 선택 해제 버튼
        TextButton.icon(
          onPressed: () => setState(() => _selectedRegion = null),
          icon: const Icon(Icons.list, size: 18),
          label: const Text('전체 목록 보기'),
          style: TextButton.styleFrom(
            foregroundColor: _blueAccent,
          ),
        ),
      ],
    );
  }

  Widget _buildDetailRow(String label, String value, IconData icon, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color ?? Colors.grey.shade600),
          const SizedBox(width: 12),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade700,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color ?? Colors.grey.shade800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRegionList() {
    final sortedRegions = _regionData.entries.toList()
      ..sort((a, b) => b.value.progressRate.compareTo(a.value.progressRate));

    return Column(
      children: [
        for (int index = 0; index < sortedRegions.length; index++) ...[
          if (index > 0) const SizedBox(height: 8),
          _buildRegionListItem(sortedRegions[index], index),
        ],
      ],
    );
  }

  Widget _buildRegionListItem(MapEntry<String, RegionData> entry, int index) {
    final data = entry.value;

    return InkWell(
      onTap: () => setState(() => _selectedRegion = entry.key),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.grey.shade50,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _selectedRegion == entry.key
                ? _blueAccent
                : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          children: [
            // 순위
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: index < 3
                    ? _getProgressColor(data.progressRate).withValues(alpha: 0.1)
                    : Colors.grey.shade200,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: index < 3
                      ? _getProgressColor(data.progressRate)
                      : Colors.grey.shade600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            // 지역명
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${data.completed}/${data.total}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            // 진행률
            SizedBox(
              width: 80,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${data.progressPercent}%',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: _getProgressColor(data.progressRate),
                    ),
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: data.progressRate,
                      minHeight: 4,
                      backgroundColor: Colors.grey.shade300,
                      valueColor: AlwaysStoppedAnimation(
                        _getProgressColor(data.progressRate),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getProgressColor(double rate) {
    if (rate >= 0.8) return const Color(0xFF43A047);
    if (rate >= 0.5) return const Color(0xFFFFA726);
    return const Color(0xFFE53935);
  }

}
