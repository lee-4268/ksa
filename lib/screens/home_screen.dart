import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.menu, color: Colors.black87),
          onPressed: () {
            _scaffoldKey.currentState?.openDrawer();
          },
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cell_tower, color: _primaryColor, size: 28),
            const SizedBox(width: 8),
            const Text(
              '무선국 관리 시스템',
              style: TextStyle(
                color: Colors.black87,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.black54),
            tooltip: '로그아웃',
            onPressed: _handleLogout,
          ),
        ],
      ),
      drawer: _buildDrawer(),
      body: _buildMenuGrid(),
    );
  }

  /// 사이드 메뉴 Drawer
  Widget _buildDrawer() {
    return Drawer(
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
            decoration: BoxDecoration(
              color: _primaryColor,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.cell_tower,
                  color: Colors.white,
                  size: 48,
                ),
                const SizedBox(height: 12),
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
                _buildDrawerItem(
                  icon: Icons.map_outlined,
                  title: '수검 관리',
                  subtitle: '무선국 검사 및 현장 수검 관리',
                  onTap: () => _navigateFromDrawer(const MapScreen()),
                ),
                _buildDrawerItem(
                  icon: Icons.photo_camera_outlined,
                  title: '철탑형태 분류',
                  subtitle: 'AI 기반 설치형태 자동 분류',
                  onTap: () => _navigateFromDrawer(const TowerClassificationScreen()),
                ),
                const Divider(height: 1),
                // 추후 메뉴 확장을 위한 공간
                // _buildDrawerItem(
                //   icon: Icons.analytics_outlined,
                //   title: '통계',
                //   subtitle: '검사 현황 및 통계 분석',
                //   onTap: () {},
                // ),
                // _buildDrawerItem(
                //   icon: Icons.settings_outlined,
                //   title: '설정',
                //   subtitle: '앱 설정 및 환경설정',
                //   onTap: () {},
                // ),
              ],
            ),
          ),
          // 하단 로그아웃
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('로그아웃'),
            onTap: _handleLogout,
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
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: _primaryColor),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
      ),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    );
  }

  /// 메인 화면 메뉴 그리드
  Widget _buildMenuGrid() {
    return Container(
      color: const Color(0xFFF5F5F5),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 환영 메시지
              Consumer<AuthService>(
                builder: (context, auth, _) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '안녕하세요!',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey[800],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '원하시는 기능을 선택해주세요.',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
              // 메뉴 카드 그리드
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // 화면 너비에 따라 그리드 열 수 결정
                    final crossAxisCount = constraints.maxWidth > 600 ? 3 : 2;
                    return GridView.count(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                      childAspectRatio: 1.1,
                      children: [
                        _buildMenuCard(
                          icon: Icons.map_outlined,
                          title: '수검 관리',
                          description: '무선국 검사 및\n현장 수검 관리',
                          color: Colors.blue,
                          onTap: () => _navigateToScreen(const MapScreen()),
                        ),
                        _buildMenuCard(
                          icon: Icons.photo_camera_outlined,
                          title: '철탑형태 분류',
                          description: 'AI 기반\n설치형태 자동 분류',
                          color: Colors.orange,
                          onTap: () => _navigateToScreen(const TowerClassificationScreen()),
                        ),
                        // 추후 메뉴 확장을 위한 공간 (필요 시 주석 해제)
                        // _buildMenuCard(
                        //   icon: Icons.analytics_outlined,
                        //   title: '통계',
                        //   description: '검사 현황 및\n통계 분석',
                        //   color: Colors.green,
                        //   onTap: () {},
                        // ),
                        // _buildMenuCard(
                        //   icon: Icons.settings_outlined,
                        //   title: '설정',
                        //   description: '앱 설정 및\n환경설정',
                        //   color: Colors.purple,
                        //   onTap: () {},
                        // ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 메뉴 카드 위젯
  Widget _buildMenuCard({
    required IconData icon,
    required String title,
    required String description,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  size: 28,
                  color: color,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 2),
              Flexible(
                child: Text(
                  description,
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.grey[600],
                  ),
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ),
            ],
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

  /// 화면 이동 (그리드 카드에서 호출)
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
        title: const Text('로그아웃'),
        content: const Text('로그아웃 하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
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
