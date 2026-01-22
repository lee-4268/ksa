import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/weather_service.dart';
import 'map_screen.dart';
import 'tower_classification_screen.dart';
import 'login_screen.dart';

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
  static const Color _orangeAccent = Color(0xFFF5A623);

  // 날씨 정보
  WeatherInfo? _weatherInfo;
  bool _isLoadingWeather = true;

  @override
  void initState() {
    super.initState();
    _loadWeather();
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
        IconButton(
          icon: const Icon(Icons.logout_outlined, color: Colors.black54),
          tooltip: '로그아웃',
          onPressed: _handleLogout,
        ),
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
                    return Text(
                      auth.userEmail ?? '',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 13,
                      ),
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
                  icon: Icons.camera_alt_outlined,
                  title: '철탑형태 분류',
                  subtitle: 'AI 기반 설치형태 자동 분류',
                  color: _orangeAccent,
                  onTap: () => _navigateFromDrawer(const TowerClassificationScreen()),
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
        // AuthService의 userName 사용 (없으면 이메일에서 추출)
        String displayName = auth.userName ?? '사용자';
        if (displayName == '사용자' && auth.userEmail != null && auth.userEmail!.contains('@')) {
          displayName = auth.userEmail!.split('@')[0];
        }

        // 날씨 및 지역 정보 텍스트 구성
        String weatherText = '';
        if (_isLoadingWeather) {
          weatherText = '날씨 정보를 불러오는 중...';
        } else if (_weatherInfo != null) {
          // 기온 문자열 생성 (섭씨 기호 사용)
          String tempStr = '';
          if (_weatherInfo!.temperature != null) {
            final temp = _weatherInfo!.temperature!;
            tempStr = '${temp.toStringAsFixed(0)}℃';
          }

          // 지역명 포함 여부에 따라 문구 생성
          if (_weatherInfo!.locationName != null && tempStr.isNotEmpty) {
            weatherText = '현재 ${_weatherInfo!.locationName}의 기온은 $tempStr이고 날씨는 ${_weatherInfo!.condition}입니다. ${_weatherInfo!.icon}';
          } else if (_weatherInfo!.locationName != null) {
            weatherText = '현재 ${_weatherInfo!.locationName}의 날씨는 ${_weatherInfo!.condition}입니다. ${_weatherInfo!.icon}';
          } else if (tempStr.isNotEmpty) {
            weatherText = '현재 기온은 $tempStr이고 날씨는 ${_weatherInfo!.condition}입니다. ${_weatherInfo!.icon}';
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
              '관리하시려는 기능을 선택해주세요.',
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
          icon: Icons.camera_alt_outlined,
          title: '철탑형태 분류',
          description: 'AI 기반 이미지 분석을 통해 설치된 철탑의 형태를 자동으로 분류합니다.',
          buttonText: '분석 시작',
          buttonIcon: Icons.auto_awesome,
          iconBackgroundColor: _orangeAccent.withValues(alpha: 0.1),
          iconColor: _orangeAccent,
          onTap: () => _navigateToScreen(const TowerClassificationScreen()),
        ),
      ],
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
    String? badge,
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
                    const Spacer(),
                    // AI 뱃지 (있을 경우)
                    if (badge != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: _orangeAccent.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          badge,
                          style: TextStyle(
                            color: _orangeAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
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
