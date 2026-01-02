# Kakao Maps SDK - 난독화 제외 규칙
# kakao_maps_flutter 패키지의 네이티브 JNI 연동에 필요한 클래스들

# 카카오맵 SDK 전체 패키지 유지
-keep class com.kakao.vectormap.** { *; }
-keep class com.kakao.maps.** { *; }

# 카카오맵 내부 클래스 유지 (JNI 연동 필수)
-keep class com.kakao.vectormap.internal.** { *; }
-keep class com.kakao.vectormap.internal.MapViewHolder { *; }
-keep class com.kakao.vectormap.internal.RenderViewOptions { *; }
-keep class com.kakao.vectormap.internal.EngineHandler { *; }

# 네이티브 메서드 유지
-keepclasseswithmembernames class * {
    native <methods>;
}

# Flutter Platform View 관련
-keep class io.flutter.plugin.platform.** { *; }

# 카카오맵 Flutter 플러그인
-keep class kakao_maps_flutter.** { *; }
