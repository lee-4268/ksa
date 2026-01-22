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
      void callback(JSAny? result, JSAny? status) {
        try {
          final statusStr = (status as JSString?)?.toDart ?? '';

          if (statusStr == 'OK') {
            // result는 배열 형태
            final resultArray = result as JSArray?;
            if (resultArray != null && resultArray.length > 0) {
              // 첫 번째 결과 사용
              final firstResult = resultArray.toDart[0];

              // region_2depth_name (시/군/구) 추출
              final region2 = _getProperty(firstResult, 'region_2depth_name');
              if (region2 != null && region2.isNotEmpty) {
                debugPrint('카카오 SDK 역지오코딩 성공: $region2');
                completer.complete(region2);
                return;
              }

              // 없으면 region_1depth_name (시/도) 사용
              final region1 = _getProperty(firstResult, 'region_1depth_name');
              if (region1 != null && region1.isNotEmpty) {
                debugPrint('카카오 SDK 역지오코딩 성공 (1depth): $region1');
                completer.complete(region1);
                return;
              }
            }
            completer.complete(null);
          } else {
            debugPrint('카카오 SDK 역지오코딩 실패: $statusStr');
            completer.complete(null);
          }
        } catch (e) {
          debugPrint('카카오 SDK 콜백 처리 오류: $e');
          completer.complete(null);
        }
      }

      // JavaScript 함수 호출
      _callKakaoGeocoder(lat, lon, callback.toJS);

      // 타임아웃 3초
      return await completer.future.timeout(
        const Duration(seconds: 3),
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

  /// JavaScript 객체에서 속성 값 추출
  static String? _getProperty(JSAny? obj, String propertyName) {
    if (obj == null) return null;
    try {
      final value = _jsGetProperty(obj, propertyName.toJS);
      if (value != null) {
        return (value as JSString?)?.toDart;
      }
    } catch (e) {
      debugPrint('속성 추출 오류 ($propertyName): $e');
    }
    return null;
  }
}

/// JavaScript에서 카카오 Geocoder 호출
@JS('_callKakaoGeocoderFromDart')
external void _callKakaoGeocoder(double lat, double lon, JSFunction callback);

/// JavaScript 객체 속성 접근
@JS('_getPropertyFromDart')
external JSAny? _jsGetProperty(JSAny obj, JSString propertyName);
