// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/foundation.dart';

/// 카카오맵 JavaScript SDK를 통한 역지오코딩 (웹 전용)
/// CORS 문제 없이 JavaScript SDK를 직접 호출하여 정확한 지역명 획득
class KakaoGeocodingWeb {
  /// 위경도 좌표로 지역명 가져오기 (역지오코딩)
  static Future<String?> getLocationName(double lat, double lon) async {
    if (!kIsWeb) {
      debugPrint('KakaoGeocodingWeb은 웹 플랫폼에서만 사용 가능합니다.');
      return null;
    }

    try {
      final completer = Completer<String?>();

      // JavaScript 콜백 함수 생성
      void callback(JSAny? result) {
        try {
          debugPrint('카카오 SDK 콜백 호출됨');

          if (result == null) {
            debugPrint('카카오 SDK 결과 null');
            completer.complete(null);
            return;
          }

          // result는 문자열 (지역명) 또는 null
          final resultStr = (result as JSString?)?.toDart;
          debugPrint('카카오 SDK 역지오코딩 결과: $resultStr');
          completer.complete(resultStr);
        } catch (e) {
          debugPrint('카카오 SDK 콜백 처리 오류: $e');
          completer.complete(null);
        }
      }

      // JavaScript 함수 호출
      _callKakaoGeocoder(lat, lon, callback.toJS);

      // 타임아웃 5초
      return await completer.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          debugPrint('카카오 SDK 역지오코딩 타임아웃');
          return null;
        },
      );
    } catch (e) {
      debugPrint('카카오 SDK 역지오코딩 오류: $e');
      return null;
    }
  }
}

/// JavaScript에서 카카오 Geocoder 호출
@JS('_callKakaoGeocoderFromDart')
external void _callKakaoGeocoder(double lat, double lon, JSFunction callback);
