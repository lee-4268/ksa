import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/station_provider.dart';
import 'screens/map_screen.dart';
import 'services/storage_service.dart';

// 모바일용 조건부 import
import 'main_init_stub.dart' if (dart.library.io) 'main_init_mobile.dart'
    as platform_init;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 모바일에서만 카카오맵 SDK 초기화
  platform_init.initializeKakaoSdk();

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
        home: const MapScreen(),
      ),
    );
  }
}
