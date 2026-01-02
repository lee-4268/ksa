import 'package:flutter/foundation.dart';
import 'package:kakao_maps_flutter/kakao_maps_flutter.dart';
import 'config/api_keys.dart';

/// 모바일 플랫폼용 카카오맵 SDK 초기화 (kakao_maps_flutter - 네이티브 SDK)
Future<void> initializeKakaoSdk() async {
  try {
    // kakao_maps_flutter는 네이티브 앱 키로 초기화
    await KakaoMapsFlutter.init(ApiKeys.kakaoNativeAppKey);
    debugPrint('카카오맵 SDK 초기화 성공');
  } catch (e) {
    // 초기화 실패해도 앱은 계속 실행 (맵만 표시 안됨)
    debugPrint('카카오맵 SDK 초기화 실패: $e');
  }
}
