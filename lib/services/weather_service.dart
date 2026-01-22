import 'dart:convert';
import 'dart:math' as math;
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
  static const String _baseUrl = 'https://apis.data.go.kr/1360000/VilageFcstInfoService_2.0';

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
  /// 웹 플랫폼에서는 CORS 문제로 REST API 직접 호출 불가 → 모바일에서만 동작
  static Future<String?> _getLocationName(double lat, double lon) async {
    // 웹 플랫폼에서는 카카오 REST API 직접 호출 시 CORS 에러 발생
    // 웹에서는 지역명 없이 기온만 표시
    if (kIsWeb) {
      debugPrint('웹 플랫폼: 카카오 역지오코딩 건너뜀 (CORS 제한)');
      return null;
    }

    try {
      // 카카오 REST API 키 (모바일에서만 사용)
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
      } else {
        debugPrint('카카오 API 응답 오류: ${response.statusCode}');
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
      debugPrint('위치 서비스 활성화 여부: $serviceEnabled');
      if (!serviceEnabled) {
        debugPrint('위치 서비스가 비활성화되어 있습니다.');
        return null;
      }

      // 권한 확인
      LocationPermission permission = await Geolocator.checkPermission();
      debugPrint('현재 위치 권한 상태: $permission');
      if (permission == LocationPermission.denied) {
        debugPrint('위치 권한 요청 중...');
        permission = await Geolocator.requestPermission();
        debugPrint('위치 권한 요청 결과: $permission');
        if (permission == LocationPermission.denied) {
          debugPrint('위치 권한이 거부되었습니다.');
          return null;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        debugPrint('위치 권한이 영구적으로 거부되었습니다.');
        return null;
      }

      // 먼저 마지막으로 알려진 위치 시도 (빠름)
      debugPrint('마지막으로 알려진 위치 확인 중...');
      try {
        final lastPosition = await Geolocator.getLastKnownPosition();
        if (lastPosition != null) {
          debugPrint('마지막 위치 발견: lat=${lastPosition.latitude}, lon=${lastPosition.longitude}');
          // 마지막 위치가 있으면 바로 사용 (더 빠른 응답)
          // 백그라운드에서 현재 위치 갱신은 하지 않음
          return lastPosition;
        }
      } catch (e) {
        debugPrint('마지막 위치 확인 실패: $e');
      }

      // 마지막 위치가 없으면 현재 위치 가져오기 (타임아웃 15초)
      debugPrint('현재 위치 가져오는 중...');
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          debugPrint('위치 가져오기 타임아웃 (15초)');
          throw Exception('위치 가져오기 타임아웃');
        },
      );
      debugPrint('위치 획득 성공: lat=${position.latitude}, lon=${position.longitude}');
      return position;
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

      debugPrint('기상청 API 요청: baseDate=$baseDate, baseTime=$baseTime, nx=$nx, ny=$ny');

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

      final response = await http.get(url).timeout(const Duration(seconds: 10));
      debugPrint('기상청 API 응답 코드: ${response.statusCode}');

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        // 응답 코드 확인
        final resultCode = data['response']?['header']?['resultCode'];
        final resultMsg = data['response']?['header']?['resultMsg'];
        debugPrint('기상청 API 결과: $resultCode - $resultMsg');

        if (resultCode != '00') {
          debugPrint('기상청 API 오류: $resultMsg');
          return _getDefaultWeather(locationName);
        }

        final items = data['response']?['body']?['items']?['item'] as List?;

        if (items != null && items.isNotEmpty) {
          String? pty; // 강수형태
          double? temp; // 기온
          double? reh; // 습도

          for (var item in items) {
            final category = item['category'];
            final value = item['obsrValue']?.toString();
            debugPrint('기상 데이터: $category = $value');

            switch (category) {
              case 'PTY': // 강수형태: 0없음, 1비, 2비/눈, 3눈, 4소나기
                pty = value;
                break;
              case 'T1H': // 기온
                temp = double.tryParse(value ?? '');
                break;
              case 'REH': // 습도
                reh = double.tryParse(value ?? '');
                break;
            }
          }

          debugPrint('파싱 결과: pty=$pty, temp=$temp, reh=$reh');
          return _parseWeatherFromNcst(pty, temp, locationName);
        } else {
          debugPrint('기상청 API 응답에 items가 없음');
        }
      } else {
        debugPrint('기상청 API HTTP 오류: ${response.statusCode}');
        debugPrint('응답 본문: ${response.body}');
      }
    } catch (e) {
      debugPrint('기상청 API 호출 실패: $e');
    }

    return _getDefaultWeather(locationName);
  }

  /// 초단기실황(getUltraSrtNcst) API 응답 파싱
  /// 초단기실황은 SKY(하늘상태) 항목이 없고 PTY(강수형태)와 T1H(기온)만 제공
  static WeatherInfo _parseWeatherFromNcst(String? pty, double? temp, String? locationName) {
    // 강수형태 체크
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

    // 강수 없음 - 시간대별 기본 아이콘 (낮/밤)
    final hour = DateTime.now().hour;
    if (hour >= 6 && hour < 18) {
      return WeatherInfo(condition: '맑음', icon: '☀️', temperature: temp, locationName: locationName);
    } else {
      return WeatherInfo(condition: '맑음', icon: '🌙', temperature: temp, locationName: locationName);
    }
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

    const double DEGRAD = math.pi / 180.0;

    double re = RE / GRID;
    double slat1 = SLAT1 * DEGRAD;
    double slat2 = SLAT2 * DEGRAD;
    double olon = OLON * DEGRAD;
    double olat = OLAT * DEGRAD;

    double sn = math.log(math.cos(slat1) / math.cos(slat2)) /
                math.log(math.tan(math.pi * 0.25 + slat2 * 0.5) / math.tan(math.pi * 0.25 + slat1 * 0.5));
    double sf = math.pow(math.tan(math.pi * 0.25 + slat1 * 0.5), sn) * math.cos(slat1) / sn;
    double ro = re * sf / math.pow(math.tan(math.pi * 0.25 + olat * 0.5), sn);

    double ra = re * sf / math.pow(math.tan(math.pi * 0.25 + lat * DEGRAD * 0.5), sn);
    double theta = lon * DEGRAD - olon;
    if (theta > math.pi) theta -= 2.0 * math.pi;
    if (theta < -math.pi) theta += 2.0 * math.pi;
    theta *= sn;

    int nx = (ra * math.sin(theta) + XO + 0.5).floor();
    int ny = (ro - ra * math.cos(theta) + YO + 0.5).floor();

    debugPrint('좌표 변환: lat=$lat, lon=$lon → nx=$nx, ny=$ny');
    return {'nx': nx, 'ny': ny};
  }
}
