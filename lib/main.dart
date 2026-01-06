import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_auth_cognito/amplify_auth_cognito.dart';
import 'package:amplify_api/amplify_api.dart';

import 'amplifyconfiguration.dart';
import 'providers/station_provider.dart';
import 'screens/map_screen.dart';
import 'screens/login_screen.dart';
import 'services/storage_service.dart';
import 'services/auth_service.dart';
import 'services/cloud_data_service.dart';

// 모바일용 조건부 import
import 'main_init_stub.dart' if (dart.library.io) 'main_init_mobile.dart'
    as platform_init;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
    // Amplify 플러그인 추가
    final authPlugin = AmplifyAuthCognito();
    final apiPlugin = AmplifyAPI();

    await Amplify.addPlugins([authPlugin, apiPlugin]);

    // Amplify 구성
    await Amplify.configure(amplifyconfig);

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
        ChangeNotifierProvider(
          create: (_) => StationProvider(storageService),
        ),
      ],
      child: MaterialApp(
        title: '무선국 검사 관리',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
          appBarTheme: const AppBarTheme(
            centerTitle: true,
          ),
          cardTheme: CardThemeData(
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
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

        // 로그인 상태에 따라 화면 분기
        if (authService.isSignedIn) {
          return const MapScreen();
        } else {
          return const LoginScreen();
        }
      },
    );
  }
}
