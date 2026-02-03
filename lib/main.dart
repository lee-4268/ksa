import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_api/amplify_api.dart';
import 'package:amplify_storage_s3/amplify_storage_s3.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'amplifyconfiguration.dart';
import 'providers/station_provider.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';
import 'screens/pending_approval_screen.dart';
import 'services/storage_service.dart';
import 'services/auth_service.dart';
import 'services/cloud_data_service.dart';
import 'services/photo_storage_service.dart';
import 'services/audit_service.dart';
import 'services/team_context_service.dart';
import 'services/admin_service.dart';
import 'services/division_data_service.dart';

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

  // Amplify 초기화
  await _configureAmplify();

  runApp(MyApp(storageService: storageService));
}

Future<void> _configureAmplify() async {
  try {
    // Amplify 플러그인 추가 (Auth, API만 - Storage는 설정 시에만)
    final authPlugin = AmplifyAuthCognito();
    final apiPlugin = AmplifyAPI();

    // S3 Storage 설정이 있는지 확인
    final hasStorageConfig = amplifyconfig.contains('"awsS3StoragePlugin"') ||
        amplifyconfig.contains('"S3TransferUtility"');

    if (hasStorageConfig) {
      final storagePlugin = AmplifyStorageS3();
      await Amplify.addPlugins([authPlugin, apiPlugin, storagePlugin]);
      debugPrint('Amplify 초기화: Auth, API, Storage 플러그인 추가');
    } else {
      await Amplify.addPlugins([authPlugin, apiPlugin]);
      debugPrint('Amplify 초기화: Auth, API 플러그인만 추가 (Storage 설정 없음)');
    }

    // Amplify 구성
    await Amplify.configure(amplifyconfig);

    // S3 Storage 설정 확인 (플러그인이 있을 때만)
    if (hasStorageConfig) {
      await PhotoStorageService.checkStorageConfiguration();
    }

    debugPrint('Amplify 초기화 완료');
  } on AmplifyAlreadyConfiguredException {
    debugPrint('Amplify가 이미 구성되어 있습니다.');
  } catch (e) {
    debugPrint('Amplify 초기화 오류: $e');
  }
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
        ChangeNotifierProvider(
          create: (_) => StationProvider(storageService),
        ),
      ],
      child: MaterialApp(
        title: '무선국 관리 시스템',
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
  @override
  void initState() {
    super.initState();
    // AuthService 초기화 (로그인 상태 확인)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AuthService>().init();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthService>(
      builder: (context, authService, child) {
        // 초기화 중
        if (!authService.isInitialized) {
          return const Scaffold(
            body: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('로딩 중...'),
                ],
              ),
            ),
          );
        }

        // 세션 만료 시 메시지 표시
        if (authService.isSessionExpired) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('세션이 만료되어 자동 로그아웃되었습니다.'),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 3),
              ),
            );
          });
        }

        // 로그인 상태에 따라 화면 분기
        if (authService.isSignedIn) {
          // AuditService 사용자 컨텍스트 설정
          final auditService = context.read<AuditService>();
          auditService.setUserContext(
            userId: authService.userId ?? '',
            email: authService.userEmail,
            name: authService.userName,
            teamId: authService.currentTeamId,
            teamName: authService.currentTeamName,
          );

          // 승인 상태 확인
          if (authService.isPendingApproval || authService.isRejected) {
            return const PendingApprovalScreen();
          }

          if (authService.isSuspended) {
            return Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.block, size: 64, color: Colors.red),
                    const SizedBox(height: 16),
                    const Text(
                      '계정이 정지되었습니다',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text('관리자에게 문의하세요.'),
                    const SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: () => authService.signOut(),
                      child: const Text('로그아웃'),
                    ),
                  ],
                ),
              ),
            );
          }

          // 프로필이 없는 경우 (신규 사용자) - 프로필 생성 시도
          if (authService.hasNoProfile) {
            WidgetsBinding.instance.addPostFrameCallback((_) async {
              await authService.createUserProfile();
            });
            return const Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('프로필 생성 중...'),
                  ],
                ),
              ),
            );
          }

          // 승인된 사용자만 홈 화면 접근
          return const HomeScreen();
        } else {
          return const LoginScreen();
        }
      },
    );
  }
}
