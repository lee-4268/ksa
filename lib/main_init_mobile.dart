import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:kakao_maps_flutter/kakao_maps_flutter.dart';
import 'config/api_keys.dart';

/// 카카오맵 SDK 초기화 상태
bool kakaoMapInitialized = false;

/// x86 에뮬레이터 여부 (ARM 네이티브 라이브러리 비호환)
bool isX86Emulator = false;

/// 에뮬레이터 및 x86 아키텍처 감지
Future<bool> _checkIsX86Emulator() async {
  if (!Platform.isAndroid) return false;

  try {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;

    // 에뮬레이터 여부 확인
    final isEmulator = !androidInfo.isPhysicalDevice;

    // 지원되는 ABI 확인
    // 에뮬레이터가 x86_64를 첫 번째로 지원하면 x86 기반 에뮬레이터임
    // (ARM 번역 레이어가 있어도 네이티브 라이브러리는 x86로 로드 시도)
    final supportedAbis = androidInfo.supportedAbis;
    final primaryAbi = supportedAbis.isNotEmpty ? supportedAbis.first : '';
    final isX86Primary = primaryAbi.contains('x86');

    debugPrint('디바이스 정보: isEmulator=$isEmulator, ABIs=$supportedAbis, primaryAbi=$primaryAbi');

    // 에뮬레이터이고 기본 ABI가 x86인 경우
    // 카카오맵 네이티브 SDK는 ARM 전용이므로 x86 에뮬레이터에서 크래시 발생
    if (isEmulator && isX86Primary) {
      debugPrint('x86 기반 에뮬레이터 감지됨 - 카카오맵 SDK 비호환');
      return true;
    }

    return false;
  } catch (e) {
    debugPrint('에뮬레이터 감지 실패: $e');
    return false;
  }
}

/// 모바일 플랫폼용 카카오맵 SDK 초기화 (kakao_maps_flutter - 네이티브 SDK)
Future<void> initializeKakaoSdk() async {
  // x86 에뮬레이터 체크
  isX86Emulator = await _checkIsX86Emulator();

  if (isX86Emulator) {
    debugPrint('x86 에뮬레이터 감지됨 - 카카오맵 SDK 초기화 건너뜀');
    debugPrint('※ 카카오맵 네이티브 SDK는 ARM 아키텍처만 지원합니다.');
    debugPrint('※ 실제 기기 또는 웹 버전에서 테스트하세요.');
    kakaoMapInitialized = false;
    return;
  }

  try {
    // kakao_maps_flutter는 네이티브 앱 키로 초기화
    await KakaoMapsFlutter.init(ApiKeys.kakaoNativeAppKey);
    kakaoMapInitialized = true;
    debugPrint('카카오맵 SDK 초기화 성공');
  } catch (e) {
    // 초기화 실패해도 앱은 계속 실행 (맵만 표시 안됨)
    kakaoMapInitialized = false;
    debugPrint('카카오맵 SDK 초기화 실패: $e');
  }
}
