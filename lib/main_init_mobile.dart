import 'package:kakao_map_plugin/kakao_map_plugin.dart';
import 'config/api_keys.dart';

/// 모바일 플랫폼용 카카오맵 SDK 초기화
void initializeKakaoSdk() {
  AuthRepository.initialize(appKey: ApiKeys.kakaoJavaScriptKey);
}
