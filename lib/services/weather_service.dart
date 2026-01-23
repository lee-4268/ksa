import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:geolocator/geolocator.dart';
import 'kakao_geocoding_web.dart' if (dart.library.io) 'kakao_geocoding_stub.dart';

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

  /// 지역명 가져오기
  /// 웹: 카카오맵 JavaScript SDK 사용 (CORS 문제 없음)
  /// 모바일: 카카오 REST API 사용
  static Future<String?> _getLocationName(double lat, double lon) async {
    // 웹 플랫폼에서는 카카오맵 JavaScript SDK를 통한 역지오코딩 사용
    if (kIsWeb) {
      debugPrint('웹 플랫폼: 카카오맵 SDK 역지오코딩 시도 (lat=$lat, lon=$lon)');
      final locationName = await KakaoGeocodingWeb.getLocationName(lat, lon);
      if (locationName != null) {
        debugPrint('웹 플랫폼: 카카오맵 SDK 역지오코딩 성공 = $locationName');
        return locationName;
      }
      // SDK 실패 시 격자 좌표 기반 폴백
      debugPrint('웹 플랫폼: SDK 실패, 격자 좌표 기반 폴백');
      final grid = _convertToGrid(lat, lon);
      return _getLocationNameFromGrid(grid['nx']!, grid['ny']!);
    }

    // 모바일: 카카오 REST API 사용
    try {
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
          final region = documents.first;
          final region1 = region['region_1depth_name'] as String? ?? '';
          final region2 = region['region_2depth_name'] as String? ?? '';

          return _extractCityName(region1, region2);
        }
      } else {
        debugPrint('카카오 API 응답 오류: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('지역명 가져오기 실패: $e');
    }

    // 모바일에서도 API 실패 시 격자 좌표 기반 폴백
    final grid = _convertToGrid(lat, lon);
    return _getLocationNameFromGrid(grid['nx']!, grid['ny']!);
  }

  /// "시" 단위까지만 추출
  /// 특별시/광역시: "서울시", "인천시", "부산시"
  /// 도 단위: region2에서 "ㅇㅇ시" 추출 (예: "안양시 만안구" → "안양시")
  static String? _extractCityName(String region1, String region2) {
    // 특별시/광역시인 경우
    if (region1.contains('특별시') || region1.contains('광역시') || region1.contains('특별자치시')) {
      return region1
          .replaceAll('특별시', '시')
          .replaceAll('광역시', '시')
          .replaceAll('특별자치시', '시');
    }

    // 도 단위: region2에서 "시" 단위 추출
    if (region2.isNotEmpty) {
      final siMatch = RegExp(r'^(\S+시)').firstMatch(region2);
      if (siMatch != null) {
        return siMatch.group(1); // "안양시", "수원시", "부천시" 등
      }
      // "시"가 없으면 첫 단어 반환 (군 등)
      return region2.split(' ').first;
    }

    return region1.isNotEmpty ? region1 : null;
  }

  /// 격자 좌표(nx, ny)로 지역명 찾기
  /// 기상청 격자 좌표는 약 5km 해상도이므로 대략적인 지역 매핑
  static String? _getLocationNameFromGrid(int nx, int ny) {
    // 주요 도시/지역의 격자 좌표 매핑 (기상청 격자 좌표 기준)
    // 격자 좌표는 범위로 매핑 (±2 허용)

    final regions = [
      // 서울특별시
      _GridRegion(60, 127, '서울시'),
      _GridRegion(61, 126, '서울시'),
      _GridRegion(61, 127, '서울시'),
      _GridRegion(62, 126, '서울시'),

      // 경기도
      _GridRegion(60, 120, '수원시'),
      _GridRegion(60, 121, '수원시'),
      _GridRegion(62, 120, '성남시'),
      _GridRegion(64, 128, '의정부시'),
      _GridRegion(55, 124, '안양시'),
      _GridRegion(58, 125, '부천시'),
      _GridRegion(56, 126, '광명시'),
      _GridRegion(51, 125, '시흥시'),
      _GridRegion(52, 123, '안산시'),
      _GridRegion(57, 119, '용인시'),
      _GridRegion(62, 123, '고양시'),
      _GridRegion(64, 124, '파주시'),
      _GridRegion(55, 127, '김포시'),
      _GridRegion(68, 100, '평택시'),
      _GridRegion(57, 112, '평택시'),
      _GridRegion(62, 114, '화성시'),
      _GridRegion(63, 111, '오산시'),
      _GridRegion(61, 118, '군포시'),
      _GridRegion(63, 119, '의왕시'),
      _GridRegion(64, 119, '안성시'),
      _GridRegion(66, 131, '양주시'),
      _GridRegion(64, 118, '이천시'),
      _GridRegion(71, 131, '포천시'),
      _GridRegion(69, 125, '동두천시'),
      _GridRegion(76, 122, '가평군'),
      _GridRegion(73, 134, '연천군'),
      _GridRegion(70, 121, '양평군'),
      _GridRegion(68, 117, '여주시'),
      _GridRegion(69, 107, '광주시'),
      _GridRegion(64, 116, '하남시'),
      _GridRegion(65, 121, '구리시'),
      _GridRegion(66, 123, '남양주시'),

      // 인천광역시
      _GridRegion(55, 124, '인천시'),
      _GridRegion(54, 125, '인천시'),
      _GridRegion(55, 125, '인천시'),

      // 부산광역시
      _GridRegion(98, 76, '부산시'),
      _GridRegion(99, 75, '부산시'),
      _GridRegion(98, 75, '부산시'),

      // 대구광역시
      _GridRegion(89, 90, '대구시'),
      _GridRegion(88, 90, '대구시'),

      // 대전광역시
      _GridRegion(67, 100, '대전시'),
      _GridRegion(68, 100, '대전시'),

      // 광주광역시
      _GridRegion(58, 74, '광주시'),
      _GridRegion(59, 74, '광주시'),

      // 울산광역시
      _GridRegion(102, 84, '울산시'),
      _GridRegion(101, 84, '울산시'),

      // 세종특별자치시
      _GridRegion(66, 103, '세종시'),

      // 강원도
      _GridRegion(73, 134, '춘천시'),
      _GridRegion(92, 131, '강릉시'),
      _GridRegion(87, 141, '속초시'),
      _GridRegion(76, 139, '홍천군'),
      _GridRegion(84, 123, '원주시'),
      _GridRegion(93, 124, '삼척시'),
      _GridRegion(86, 127, '정선군'),
      _GridRegion(90, 135, '동해시'),
      _GridRegion(85, 138, '양양군'),
      _GridRegion(80, 130, '횡성군'),
      _GridRegion(77, 125, '영월군'),
      _GridRegion(81, 118, '평창군'),
      _GridRegion(84, 129, '태백시'),
      _GridRegion(73, 139, '인제군'),
      _GridRegion(70, 141, '고성군'),
      _GridRegion(73, 127, '화천군'),
      _GridRegion(72, 139, '양구군'),
      _GridRegion(81, 106, '철원군'),

      // 충청북도
      _GridRegion(69, 107, '청주시'),
      _GridRegion(76, 114, '충주시'),
      _GridRegion(76, 106, '제천시'),
      _GridRegion(65, 105, '보은군'),
      _GridRegion(73, 97, '옥천군'),
      _GridRegion(71, 99, '영동군'),
      _GridRegion(64, 111, '증평군'),
      _GridRegion(67, 106, '진천군'),
      _GridRegion(69, 112, '괴산군'),
      _GridRegion(64, 115, '음성군'),
      _GridRegion(80, 119, '단양군'),

      // 충청남도
      _GridRegion(68, 100, '천안시'),
      _GridRegion(55, 106, '공주시'),
      _GridRegion(51, 95, '보령시'),
      _GridRegion(68, 95, '아산시'),
      _GridRegion(55, 99, '서산시'),
      _GridRegion(63, 89, '논산시'),
      _GridRegion(60, 102, '계룡시'),
      _GridRegion(52, 99, '당진시'),
      _GridRegion(62, 101, '금산군'),
      _GridRegion(56, 92, '부여군'),
      _GridRegion(51, 86, '서천군'),
      _GridRegion(46, 89, '청양군'),
      _GridRegion(48, 100, '홍성군'),
      _GridRegion(56, 103, '예산군'),
      _GridRegion(48, 109, '태안군'),

      // 전라북도
      _GridRegion(63, 89, '전주시'),
      _GridRegion(56, 80, '군산시'),
      _GridRegion(54, 76, '익산시'),
      _GridRegion(61, 79, '정읍시'),
      _GridRegion(55, 71, '남원시'),
      _GridRegion(63, 75, '김제시'),
      _GridRegion(72, 70, '완주군'),
      _GridRegion(68, 72, '진안군'),
      _GridRegion(68, 68, '무주군'),
      _GridRegion(74, 74, '장수군'),
      _GridRegion(66, 84, '임실군'),
      _GridRegion(68, 78, '순창군'),
      _GridRegion(56, 83, '고창군'),
      _GridRegion(51, 72, '부안군'),

      // 전라남도
      _GridRegion(51, 67, '목포시'),
      _GridRegion(67, 62, '여수시'),
      _GridRegion(70, 70, '순천시'),
      _GridRegion(59, 66, '나주시'),
      _GridRegion(73, 66, '광양시'),
      _GridRegion(52, 71, '담양군'),
      _GridRegion(61, 66, '곡성군'),
      _GridRegion(57, 64, '구례군'),
      _GridRegion(52, 56, '고흥군'),
      _GridRegion(48, 59, '보성군'),
      _GridRegion(59, 52, '화순군'),
      _GridRegion(50, 67, '장흥군'),
      _GridRegion(59, 56, '강진군'),
      _GridRegion(50, 53, '해남군'),
      _GridRegion(56, 66, '영암군'),
      _GridRegion(56, 71, '무안군'),
      _GridRegion(48, 74, '함평군'),
      _GridRegion(52, 77, '영광군'),
      _GridRegion(56, 63, '장성군'),
      _GridRegion(48, 62, '완도군'),
      _GridRegion(56, 50, '진도군'),
      _GridRegion(33, 33, '신안군'),
      _GridRegion(66, 55, '여천시'),

      // 경상북도
      _GridRegion(91, 106, '포항시'),
      _GridRegion(91, 90, '경주시'),
      _GridRegion(80, 91, '김천시'),
      _GridRegion(89, 91, '안동시'),
      _GridRegion(81, 81, '구미시'),
      _GridRegion(88, 83, '영주시'),
      _GridRegion(83, 95, '영천시'),
      _GridRegion(81, 84, '상주시'),
      _GridRegion(77, 93, '문경시'),
      _GridRegion(89, 101, '경산시'),
      _GridRegion(75, 88, '의성군'),
      _GridRegion(79, 78, '청송군'),
      _GridRegion(87, 76, '영양군'),
      _GridRegion(91, 77, '영덕군'),
      _GridRegion(82, 76, '청도군'),
      _GridRegion(83, 80, '고령군'),
      _GridRegion(83, 73, '성주군'),
      _GridRegion(87, 68, '칠곡군'),
      _GridRegion(77, 86, '예천군'),
      _GridRegion(90, 77, '봉화군'),
      _GridRegion(92, 86, '울진군'),
      _GridRegion(99, 95, '울릉군'),

      // 경상남도
      _GridRegion(91, 77, '창원시'),
      _GridRegion(89, 77, '진주시'),
      _GridRegion(95, 77, '통영시'),
      _GridRegion(77, 68, '사천시'),
      _GridRegion(90, 69, '김해시'),
      _GridRegion(87, 68, '밀양시'),
      _GridRegion(95, 74, '거제시'),
      _GridRegion(91, 74, '양산시'),
      _GridRegion(72, 74, '의령군'),
      _GridRegion(79, 75, '함안군'),
      _GridRegion(76, 80, '창녕군'),
      _GridRegion(81, 75, '고성군'),
      _GridRegion(72, 63, '남해군'),
      _GridRegion(80, 67, '하동군'),
      _GridRegion(74, 67, '산청군'),
      _GridRegion(82, 68, '함양군'),
      _GridRegion(81, 63, '거창군'),
      _GridRegion(83, 68, '합천군'),

      // 제주특별자치도
      _GridRegion(52, 38, '제주시'),
      _GridRegion(53, 38, '제주시'),
      _GridRegion(52, 33, '서귀포시'),
    ];

    // 가장 가까운 지역 찾기 (거리 기반)
    String? closestRegion;
    int minDistance = 999;

    for (final region in regions) {
      final distance = (region.nx - nx).abs() + (region.ny - ny).abs();
      if (distance < minDistance) {
        minDistance = distance;
        closestRegion = region.name;
      }
    }

    // 거리가 10 이하일 때만 반환 (약 50km 이내)
    if (minDistance <= 10) {
      return closestRegion;
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

/// 격자 좌표-지역명 매핑 클래스
class _GridRegion {
  final int nx;
  final int ny;
  final String name;

  const _GridRegion(this.nx, this.ny, this.name);
}
