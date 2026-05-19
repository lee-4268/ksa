import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'providers/station_provider.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'services/storage_service.dart';
import 'services/auth_service.dart';
import 'services/cloud_data_service.dart';
import 'services/audit_service.dart';
import 'services/team_context_service.dart';
import 'services/admin_service.dart';
import 'services/division_data_service.dart';
import 'services/notification_service.dart';
import 'widgets/app_loader.dart';
import 'services/photo_storage_service.dart';

// 모바일용 조건부 import
import 'main_init_stub.dart' if (dart.library.io) 'main_init_mobile.dart'
    as platform_init;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 한국어 locale 데이터 초기화 (달력용)
  await initializeDateFormatting('ko_KR');

  // 모바일에서만 카카오맵 SDK 초기화
  await platform_init.initializeKakaoSdk();

  // Hive 초기화
  final storageService = StorageService();
  await storageService.init();

  runApp(MyApp(storageService: storageService));
}

class MyApp extends StatelessWidget {
  final StorageService storageService;

  const MyApp({super.key, required this.storageService});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthService()),
        ChangeNotifierProvider(create: (_) => CloudDataService()),
        ChangeNotifierProvider(create: (_) => TeamContextService()),
        ChangeNotifierProvider(create: (_) => AuditService()),
        ChangeNotifierProvider(create: (_) => DivisionDataService()),
        ChangeNotifierProxyProvider<AuditService, AdminService>(
          create: (ctx) => AdminService(ctx.read<AuditService>()),
          update: (_, auditService, adminService) =>
              adminService ?? AdminService(auditService),
        ),
        ChangeNotifierProvider(create: (_) => NotificationService()),
        ChangeNotifierProvider(
          create: (_) => StationProvider(storageService),
        ),
      ],
      child: MaterialApp(
        title: '무선국 수검 시스템',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFFE53935),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
          fontFamily: 'SamsungOne',
          scaffoldBackgroundColor: Colors.white,
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            backgroundColor: Colors.white,
            foregroundColor: Colors.black87,
            elevation: 0,
            scrolledUnderElevation: 0,
            surfaceTintColor: Colors.transparent,
          ),
          dialogTheme: const DialogThemeData(
            backgroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
          ),
          dropdownMenuTheme: const DropdownMenuThemeData(
            textStyle: TextStyle(fontFamily: 'SamsungOne'),
          ),
          cardTheme: CardThemeData(
            elevation: 0,
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: Colors.grey.shade200),
            ),
          ),
          elevatedButtonTheme: ElevatedButtonThemeData(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE53935),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        home: const AuthWrapper(),
      ),
    );
  }
}

/// 인증 상태에 따라 화면 전환
class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  bool _sessionExpiredShown = false;
  AuthService? _authService;

  @override
  void initState() {
    super.initState();
    // AuthService 초기화 (로그인 상태 확인)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _authService = context.read<AuthService>();
      _authService!.addListener(_onAuthStateChanged);
      _authService!.init();
    });
  }

  @override
  void dispose() {
    _authService?.removeListener(_onAuthStateChanged);
    super.dispose();
  }

  void _onAuthStateChanged() {
    // AuthService 상태 변화 시 강제 rebuild + 토큰 전파
    if (mounted) {
      debugPrint('AuthWrapper: AuthService 상태 변경 감지, rebuild 트리거');
      _propagateAuthToken();
      setState(() {});
    }
  }

  /// AuthService의 토큰을 모든 서비스에 전파
  void _propagateAuthToken() {
    final auth = context.read<AuthService>();
    final token = auth.authToken;
    context.read<CloudDataService>().setAuthToken(token);
    context.read<TeamContextService>().setAuthToken(token);
    PhotoStorageService.setAuthToken(token);
    final notifSvc = context.read<NotificationService>();
    if (token != null) {
      notifSvc.start(token);
    } else {
      notifSvc.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // context.watch로도 감지하되, 명시적 리스너로도 백업
    final authService = context.watch<AuthService>();

    debugPrint('AuthWrapper rebuild: isInitialized=${authService.isInitialized}, isSignedIn=${authService.isSignedIn}');

    // 초기화 중
    if (!authService.isInitialized) {
      return Scaffold(
        body: Center(
          child: AppLoader(message: '로딩 중...'),
        ),
      );
    }

    // 세션 만료 시 메시지 표시 (한 번만)
    if (authService.isSessionExpired && !_sessionExpiredShown) {
      _sessionExpiredShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('세션이 만료되어 자동 로그아웃되었습니다.'),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 3),
            ),
          );
        }
      });
    }

    // 세션 만료가 아닐 때 플래그 리셋
    if (!authService.isSessionExpired) {
      _sessionExpiredShown = false;
    }

    // 로그인 상태에 따라 화면 분기
    if (authService.isSignedIn) {
      return const HomeScreen();
    } else {
      return const LoginScreen();
    }
  }
}
