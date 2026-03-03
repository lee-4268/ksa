/// 카카오 개발자 플랫폼 API 키 설정
/// 빌드 시 --dart-define 으로 주입:
///   flutter build web --dart-define=KAKAO_JS_KEY=xxx --dart-define=KAKAO_REST_KEY=xxx --dart-define=KAKAO_NATIVE_KEY=xxx
class ApiKeys {
  /// 카카오 JavaScript 키 (웹/지도용)
  static const String kakaoJavaScriptKey = String.fromEnvironment('KAKAO_JS_KEY', defaultValue: '');

  /// 카카오 REST API 키 (지오코딩용)
  static const String kakaoRestApiKey = String.fromEnvironment('KAKAO_REST_KEY', defaultValue: '');

  /// 카카오 Native 앱 키 (Android/iOS용)
  static const String kakaoNativeAppKey = String.fromEnvironment('KAKAO_NATIVE_KEY', defaultValue: '');
}
