import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../config/api_keys.dart';

class GeocodingService {
  static const String _restApiKey = ApiKeys.kakaoRestApiKey;

  /// 주소를 좌표로 변환 (카카오 지오코딩)
  Future<Map<String, double>?> getCoordinatesFromAddress(String address) async {
    try {
      final encodedAddress = Uri.encodeComponent(address);
      final url = Uri.parse(
        'https://dapi.kakao.com/v2/local/search/address.json?query=$encodedAddress',
      );

      final response = await http.get(
        url,
        headers: {
          'Authorization': 'KakaoAK $_restApiKey',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['documents'] != null && (data['documents'] as List).isNotEmpty) {
          final firstResult = data['documents'][0];
          return {
            'latitude': double.parse(firstResult['y']),
            'longitude': double.parse(firstResult['x']),
          };
        }

        // 주소 검색 결과가 없으면 키워드 검색 시도
        return await _searchByKeyword(address);
      } else {
        debugPrint('지오코딩 API 오류: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      debugPrint('지오코딩 오류: $e');
    }
    return null;
  }

  /// 키워드로 장소 검색 (주소 검색 실패 시 대체)
  Future<Map<String, double>?> _searchByKeyword(String keyword) async {
    try {
      final encodedKeyword = Uri.encodeComponent(keyword);
      final url = Uri.parse(
        'https://dapi.kakao.com/v2/local/search/keyword.json?query=$encodedKeyword',
      );

      final response = await http.get(
        url,
        headers: {
          'Authorization': 'KakaoAK $_restApiKey',
        },
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['documents'] != null && (data['documents'] as List).isNotEmpty) {
          final firstResult = data['documents'][0];
          return {
            'latitude': double.parse(firstResult['y']),
            'longitude': double.parse(firstResult['x']),
          };
        }
      }
    } catch (e) {
      debugPrint('키워드 검색 오류: $e');
    }
    return null;
  }

  /// 여러 주소를 한번에 좌표로 변환
  Future<List<Map<String, double>?>> getCoordinatesFromAddresses(
    List<String> addresses,
  ) async {
    final List<Map<String, double>?> results = [];

    for (final address in addresses) {
      // API 호출 제한을 위한 딜레이
      await Future.delayed(const Duration(milliseconds: 100));
      final coords = await getCoordinatesFromAddress(address);
      results.add(coords);
    }

    return results;
  }
}
