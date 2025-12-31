// 모바일 플랫폼용 stub 파일 (웹이 아닌 플랫폼에서 사용)
// 웹 전용 위젯이므로 모바일에서는 빈 위젯 반환

import 'package:flutter/material.dart';
import '../models/radio_station.dart';

/// 모바일 플랫폼용 stub 위젯 (웹에서만 실제 구현 사용)
class KakaoMapWeb extends StatelessWidget {
  final List<RadioStation> stations;
  final Function(RadioStation)? onMarkerTap;
  final double initialLat;
  final double initialLng;
  final int initialLevel;

  const KakaoMapWeb({
    super.key,
    required this.stations,
    this.onMarkerTap,
    this.initialLat = 36.5,
    this.initialLng = 127.5,
    this.initialLevel = 13,
  });

  void setCenter(double lat, double lng) {}
  void setLevel(int level) {}

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text('웹 전용 지도 위젯입니다.'),
    );
  }
}
