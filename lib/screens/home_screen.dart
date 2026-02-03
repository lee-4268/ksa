import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/station_provider.dart';
import '../services/auth_service.dart';
import '../services/cloud_data_service.dart';
import '../services/weather_service.dart';
import 'map_screen.dart';
import 'login_screen.dart';
import 'schedule_screen.dart';
import 'division_management_screen.dart';
import 'admin/admin_panel_screen.dart';
import '../widgets/user_profile_button.dart';

/// 메인 홈 화면 - 메뉴 선택 인터페이스
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  // 테마 색상
  static const Color _primaryColor = Color(0xFFE53935);
  static const Color _blueAccent = Color(0xFF4A90D9);
  static const Color _greenColor = Color(0xFF43A047);
  static const Color _indigoColor = Color(0xFF5C6BC0);

  // 날씨 정보
  WeatherInfo? _weatherInfo;
  bool _isLoadingWeather = true;

  @override
  void initState() {
    super.initState();
    _loadWeather();
    _loadCloudData();
  }

  /// 로그인 직후 클라우드 데이터 로드 (일정 및 통계에서 바로 사용 가능)
  Future<void> _loadCloudData() async {
    final provider = context.read<StationProvider>();
    final cloudService = context.read<CloudDataService>();
    final authService = context.read<AuthService>();

    // 사용자가 로그인되어 있을 때만 CloudDataService 연결 및 데이터 로드
    if (authService.isSignedIn) {
      provider.setCloudDataService(cloudService, userId: authService.userId);
      await provider.loadStations();
    }
  }

  Future<void> _loadWeather() async {
    try {
      final weather = await WeatherService.getCurrentWeather();
      if (mounted) {
        setState(() {
          _weatherInfo = weather;
          _isLoadingWeather = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingWeather = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.white,
      appBar: _buildAppBar(),
      drawer: _buildDrawer(),
      body: _buildBody(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.menu, color: Colors.black54),
        onPressed: () {
          _scaffoldKey.currentState?.openDrawer();
        },
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
        const SizedBox(width: 4),
      ],
    );
  }

  /// 사이드 메뉴 Drawer
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
                        if (auth.userDepartment != null ||
                            auth.userTeam != null) ...[
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
                        const SizedBox(height: 2),
                        Text(
                          auth.userId ?? '',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 12,
                          ),
                        ),
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
          // 하단 로그아웃
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: Colors.grey.shade200)),
            ),
            child: ListTile(
              leading: Icon(Icons.logout, color: Colors.grey.shade600),
              title: Text(
                '로그아웃',
                style: TextStyle(color: Colors.grey.shade700),
              ),
              onTap: _handleLogout,
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 8),
        ],
      ),
    );
  }

  /// Drawer 메뉴 아이템
  Widget _buildDrawerItem({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
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
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        onTap: onTap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  /// 메인 바디
  Widget _buildBody() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 환영 메시지 + 날씨
          _buildWelcomeSection(),
          const SizedBox(height: 28),
          // 메뉴 카드들
          _buildMenuCards(),
        ],
      ),
    );
  }

  /// 요일 한글 변환
  String _getWeekdayName(int weekday) {
    const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
    return weekdays[weekday - 1];
  }

  /// 환영 메시지 섹션
  Widget _buildWelcomeSection() {
    final now = DateTime.now();
    final weekday = _getWeekdayName(now.weekday);
    final dateString = '${now.year}년 ${now.month}월 ${now.day}일($weekday)';

    return Consumer<AuthService>(
      builder: (context, auth, _) {
        // AuthService의 userName 사용 (실명)
        final displayName = auth.userName ?? auth.userId ?? '사용자';

        // 날씨 및 지역 정보 텍스트 구성
        String weatherText = '';
        if (_isLoadingWeather) {
          weatherText = '날씨 정보를 불러오는 중...';
        } else if (_weatherInfo != null) {
          // 기온 문자열 생성 (한글 '도' 사용)
          String tempStr = '';
          if (_weatherInfo!.temperature != null) {
            final temp = _weatherInfo!.temperature!;
            tempStr = '${temp.toStringAsFixed(0)}도';
          }

          // 지역명 포함 여부에 따라 문구 생성
          if (_weatherInfo!.locationName != null && tempStr.isNotEmpty) {
            weatherText = '현재 ${_weatherInfo!.locationName}의 기온은 $tempStr, 날씨는 ${_weatherInfo!.condition}입니다. ${_weatherInfo!.icon}';
          } else if (_weatherInfo!.locationName != null) {
            weatherText = '현재 ${_weatherInfo!.locationName}의 날씨는 ${_weatherInfo!.condition}입니다. ${_weatherInfo!.icon}';
          } else if (tempStr.isNotEmpty) {
            weatherText = '현재 기온은 $tempStr, 날씨는 ${_weatherInfo!.condition}입니다. ${_weatherInfo!.icon}';
          } else {
            weatherText = '현재 날씨는 ${_weatherInfo!.condition}입니다. ${_weatherInfo!.icon}';
          }
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    '안녕하세요!',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  '👋',
                  style: TextStyle(fontSize: 28),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '$displayName님, 오늘은 $dateString이고',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade700,
                height: 1.6,
              ),
            ),
            if (weatherText.isNotEmpty)
              Text(
                weatherText,
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey.shade700,
                  height: 1.6,
                ),
              ),
            const SizedBox(height: 6),
            Text(
              '원하는 기능을 선택해주세요.',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 메뉴 카드들
  Widget _buildMenuCards() {
    return Consumer<AuthService>(
      builder: (context, auth, _) {
        return Column(
          children: [
            _buildMenuCard(
              icon: Icons.description_outlined,
              title: '수검 관리',
              description: '무선국 현장 검사 및 실시간 수검 데이터를 체계적으로 관리합니다.',
              buttonText: '관리하기',
              buttonIcon: Icons.arrow_forward,
              iconBackgroundColor: _blueAccent.withValues(alpha: 0.1),
              iconColor: _blueAccent,
              onTap: () => _navigateToScreen(const MapScreen()),
            ),
            const SizedBox(height: 16),
            _buildMenuCard(
              icon: Icons.calendar_month,
              title: '일정 및 통계',
              description: '검사 일정을 달력으로 확인하고, 카테고리별 진도율을 한눈에 파악합니다.',
              buttonText: '확인하기',
              buttonIcon: Icons.arrow_forward,
              iconBackgroundColor: _greenColor.withValues(alpha: 0.1),
              iconColor: _greenColor,
              onTap: () => _navigateToScreen(const ScheduleScreen()),
            ),
            // 관리자 패널 카드 (관리자만 표시)
            if (auth.isAdmin) ...[
              const SizedBox(height: 16),
              _buildMenuCard(
                icon: Icons.admin_panel_settings,
                title: '관리자 패널',
                description: '사용자 가입 승인, 팀 관리, 감사 로그를 확인합니다.',
                buttonText: '관리하기',
                buttonIcon: Icons.arrow_forward,
                iconBackgroundColor: _indigoColor.withValues(alpha: 0.1),
                iconColor: _indigoColor,
                onTap: () => _navigateToScreen(const AdminPanelScreen()),
              ),
            ],
          ],
        );
      },
    );
  }

  /// 메뉴 카드 위젯
  Widget _buildMenuCard({
    required IconData icon,
    required String title,
    required String description,
    required String buttonText,
    required IconData buttonIcon,
    required Color iconBackgroundColor,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 아이콘
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: iconBackgroundColor,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(icon, color: iconColor, size: 26),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                // 타이틀
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const SizedBox(height: 8),
                // 설명
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey.shade600,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                // 버튼
                Row(
                  children: [
                    Text(
                      buttonText,
                      style: TextStyle(
                        color: iconColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(buttonIcon, color: iconColor, size: 18),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 화면 이동 (Drawer에서 호출)
  void _navigateFromDrawer(Widget screen) {
    Navigator.pop(context); // Drawer 닫기
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  /// 화면 이동 (카드에서 호출)
  void _navigateToScreen(Widget screen) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  /// 로그아웃 처리
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
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => const LoginScreen()),
          (route) => false,
        );
      }
    }
  }
}
