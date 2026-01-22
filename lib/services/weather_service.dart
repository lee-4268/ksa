import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';

/// 날씨 정보 모델
class WeatherInfo {
  final String condition; // 맑음, 흐림, 구름많음, 비, 눈 등
  final String icon; // 이모지 아이콘
  final double? temperature; // 기온 (선택)
  final String? locationName; // 지역명 (예: 평택시, 화성시)

  WeatherInfo({
    required this.condition,
    required this.icon,
    this.temperature,
    this.locationName,
  });
}

/// 기상청 날씨 서비스
class WeatherService {
  // 기상청 초단기실황 API (공공데이터포털)
  // 실제 서비스키는 공공데이터포털에서 발급받아야 합니다
  static const String _serviceKey = 'UBG8tBW43f1rTQXOjXsfgPlxewnI/nNtlKaX5HzLsiwFjjFZJ6dee7lmAoZ7452c6ZVWWDKMLEiaGsasY7RiYg=='; // TODO: 실제 키로 교체
  static const String _baseUrl = 'http://apis.data.go.kr/1360000/VilageFcstInfoService_2.0';

  /// 현재 위치의 날씨 정보 가져오기
  static Future<WeatherInfo> getCurrentWeather() async {
    try {
      // 위치 권한 확인 및 현재 위치 가져오기
      final position = await _getCurrentPosition();

      if (position != null) {
        debugPrint('위치 가져오기 성공: ${position.latitude}, ${position.longitude}');

        // 위경도를 기상청 격자 좌표로 변환
        final grid = _convertToGrid(position.latitude, position.longitude);

        // 지역명 가져오기 (역지오코딩)
        final locationName = await _getLocationName(position.latitude, position.longitude);
        debugPrint('지역명: $locationName');

        // 기상청 API 호출
        return await _fetchWeatherFromKMA(grid['nx']!, grid['ny']!, locationName);
      } else {
        debugPrint('위치를 가져올 수 없음 - 웹 브라우저 위치 권한을 확인하세요');
      }
    } catch (e) {
      debugPrint('날씨 정보 가져오기 실패: $e');
    }

    // 기본값 반환 (API 실패 시) - 위치 정보 없이 날씨만 표시
    return _getDefaultWeather();
  }

  /// 역지오코딩으로 지역명 가져오기 (카카오 API 사용)
  static Future<String?> _getLocationName(double lat, double lon) async {
    try {
      // 카카오 REST API 키 (geocoding_service.dart와 동일한 키 사용)
      const kakaoApiKey = '6dd0c0e78e66ff915c1590bd3d7ab09d';

      final url = Uri.parse(
        'https://dapi.kakao.com/v2/local/geo/coord2regioncode.json'
        '?x=$lon&y=$lat'
      );

      final response = await http.get(
        url,
        headers: {'Authorization': 'KakaoAK $kakaoApiKey'},
      ).timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final documents = data['documents'] as List?;

        if (documents != null && documents.isNotEmpty) {
          // region_2depth_name이 시/군/구 이름 (예: 평택시, 화성시)
          final region = documents.first;
          final region2 = region['region_2depth_name'] as String?;
          if (region2 != null && region2.isNotEmpty) {
            return region2;
          }
          // 없으면 region_1depth_name 사용 (예: 경기도, 서울특별시)
          final region1 = region['region_1depth_name'] as String?;
          return region1;
        }
      }
    } catch (e) {
      debugPrint('지역명 가져오기 실패: $e');
    }
    return null;
  }

  /// 현재 위치 가져오기
  static Future<Position?> _getCurrentPosition() async {
    try {
      // 위치 서비스 활성화 확인
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return null;
      }

      // 권한 확인
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return null;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return null;
      }

      // 현재 위치 가져오기
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
      );
    } catch (e) {
      debugPrint('위치 가져오기 실패: $e');
      return null;
    }
  }

  /// 기상청 API에서 날씨 정보 가져오기
  static Future<WeatherInfo> _fetchWeatherFromKMA(int nx, int ny, String? locationName) async {
    try {
      final now = DateTime.now();
      final baseDate = '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';

      // 정시 기준 (매시 30분 이후에 발표)
      int hour = now.hour;
      if (now.minute < 40) {
        hour = hour - 1;
        if (hour < 0) hour = 23;
      }
      final baseTime = '${hour.toString().padLeft(2, '0')}00';

      final url = Uri.parse(
        '$_baseUrl/getUltraSrtNcst'
        '?serviceKey=$_serviceKey'
        '&numOfRows=10'
        '&pageNo=1'
        '&dataType=JSON'
        '&base_date=$baseDate'
        '&base_time=$baseTime'
        '&nx=$nx'
        '&ny=$ny'
      );

      final response = await http.get(url).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final items = data['response']?['body']?['items']?['item'] as List?;

        if (items != null && items.isNotEmpty) {
          String? pty; // 강수형태
          String? sky; // 하늘상태
          double? temp; // 기온

          for (var item in items) {
            switch (item['category']) {
              case 'PTY': // 강수형태: 0없음, 1비, 2비/눈, 3눈, 4소나기
                pty = item['obsrValue'];
                break;
              case 'SKY': // 하늘상태: 1맑음, 3구름많음, 4흐림
                sky = item['obsrValue'];
                break;
              case 'T1H': // 기온
                temp = double.tryParse(item['obsrValue'].toString());
                break;
            }
          }

          return _parseWeather(pty, sky, temp, locationName);
        }
      }
    } catch (e) {
      debugPrint('기상청 API 호출 실패: $e');
    }

    return _getDefaultWeather(locationName);
  }

  /// 날씨 코드를 한글과 이모지로 변환
  static WeatherInfo _parseWeather(String? pty, String? sky, double? temp, String? locationName) {
    // 강수형태 우선 체크
    if (pty != null && pty != '0') {
      switch (pty) {
        case '1':
        case '4':
          return WeatherInfo(condition: '비', icon: '🌧️', temperature: temp, locationName: locationName);
        case '2':
          return WeatherInfo(condition: '비/눈', icon: '🌨️', temperature: temp, locationName: locationName);
        case '3':
          return WeatherInfo(condition: '눈', icon: '❄️', temperature: temp, locationName: locationName);
      }
    }

    // 하늘상태
    switch (sky) {
      case '1':
        return WeatherInfo(condition: '맑음', icon: '☀️', temperature: temp, locationName: locationName);
      case '3':
        return WeatherInfo(condition: '구름많음', icon: '⛅', temperature: temp, locationName: locationName);
      case '4':
        return WeatherInfo(condition: '흐림', icon: '☁️', temperature: temp, locationName: locationName);
    }

    return _getDefaultWeather(locationName);
  }

  /// 기본 날씨 (API 실패 시)
  static WeatherInfo _getDefaultWeather([String? locationName]) {
    // 시간대별 기본 날씨 추정
    final hour = DateTime.now().hour;
    if (hour >= 6 && hour < 18) {
      return WeatherInfo(condition: '맑음', icon: '☀️', locationName: locationName);
    } else {
      return WeatherInfo(condition: '맑음', icon: '🌙', locationName: locationName);
    }
  }

  /// 위경도를 기상청 격자 좌표로 변환 (LCC 변환)
  static Map<String, int> _convertToGrid(double lat, double lon) {
    const double RE = 6371.00877; // 지구 반경(km)
    const double GRID = 5.0; // 격자 간격(km)
    const double SLAT1 = 30.0; // 표준 위도1
    const double SLAT2 = 60.0; // 표준 위도2
    const double OLON = 126.0; // 기준점 경도
    const double OLAT = 38.0; // 기준점 위도
    const double XO = 43; // 기준점 X좌표
    const double YO = 136; // 기준점 Y좌표

    const double DEGRAD = 3.141592653589793 / 180.0;

    double re = RE / GRID;
    double slat1 = SLAT1 * DEGRAD;
    double slat2 = SLAT2 * DEGRAD;
    double olon = OLON * DEGRAD;
    double olat = OLAT * DEGRAD;

    double sn = (log(cos(slat1) / cos(slat2))) /
                log(tan(3.141592653589793 * 0.25 + slat2 * 0.5) / tan(3.141592653589793 * 0.25 + slat1 * 0.5));
    double sf = pow(tan(3.141592653589793 * 0.25 + slat1 * 0.5), sn) * cos(slat1) / sn;
    double ro = re * sf / pow(tan(3.141592653589793 * 0.25 + olat * 0.5), sn);

    double ra = re * sf / pow(tan(3.141592653589793 * 0.25 + lat * DEGRAD * 0.5), sn);
    double theta = lon * DEGRAD - olon;
    if (theta > 3.141592653589793) theta -= 2.0 * 3.141592653589793;
    if (theta < -3.141592653589793) theta += 2.0 * 3.141592653589793;
    theta *= sn;

    int nx = (ra * sin(theta) + XO + 0.5).floor();
    int ny = (ro - ra * cos(theta) + YO + 0.5).floor();

    return {'nx': nx, 'ny': ny};
  }
}

// dart:math 함수들
double log(double x) => x > 0 ? _log(x) : 0;
double _log(double x) {
  if (x <= 0) return double.negativeInfinity;
  double result = 0;
  while (x >= 2) {
    x /= 2.718281828459045;
    result++;
  }
  while (x < 1) {
    x *= 2.718281828459045;
    result--;
  }
  double y = x - 1;
  double term = y;
  double sum = term;
  for (int i = 2; i < 100; i++) {
    term *= -y * (i - 1) / i;
    sum += term;
    if (term.abs() < 1e-15) break;
  }
  return result + sum;
}

double pow(double base, double exp) {
  if (exp == 0) return 1;
  if (base == 0) return 0;
  return _exp(exp * log(base));
}

double _exp(double x) {
  double result = 1;
  double term = 1;
  for (int i = 1; i < 100; i++) {
    term *= x / i;
    result += term;
    if (term.abs() < 1e-15) break;
  }
  return result;
}

double sin(double x) {
  x = x % (2 * 3.141592653589793);
  double result = 0;
  double term = x;
  for (int i = 1; i < 50; i++) {
    result += term;
    term *= -x * x / ((2 * i) * (2 * i + 1));
  }
  return result;
}

double cos(double x) {
  x = x % (2 * 3.141592653589793);
  double result = 0;
  double term = 1;
  for (int i = 0; i < 50; i++) {
    result += term;
    term *= -x * x / ((2 * i + 1) * (2 * i + 2));
  }
  return result;
}

double tan(double x) => sin(x) / cos(x);
