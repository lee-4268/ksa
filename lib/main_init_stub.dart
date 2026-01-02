/// 카카오맵 SDK 초기화 상태 (웹에서는 항상 true)
bool kakaoMapInitialized = true;

/// x86 에뮬레이터 여부 (웹에서는 항상 false)
bool isX86Emulator = false;

/// 웹 플랫폼용 stub - 카카오맵 SDK 초기화 불필요
Future<void> initializeKakaoSdk() async {
  // 웹에서는 index.html에서 JavaScript SDK를 직접 로드하므로
  // 별도의 초기화가 필요하지 않습니다.
}
