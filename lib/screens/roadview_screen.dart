import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class RoadviewScreen extends StatefulWidget {
  final double latitude;
  final double longitude;
  final String stationName;

  const RoadviewScreen({
    super.key,
    required this.latitude,
    required this.longitude,
    required this.stationName,
  });

  @override
  State<RoadviewScreen> createState() => _RoadviewScreenState();
}

class _RoadviewScreenState extends State<RoadviewScreen> {
  // 테마 색상 (로그인 페이지와 일관성)
  static const Color _primaryColor = Color(0xFFE53935);

  String _getKakaoMapUrl() {
    return 'https://map.kakao.com/link/map/${Uri.encodeComponent(widget.stationName)},${widget.latitude},${widget.longitude}';
  }

  String _getKakaoRoadviewUrl() {
    return 'https://map.kakao.com/link/roadview/${widget.latitude},${widget.longitude}';
  }

  Future<void> _openKakaoMap() async {
    final Uri kakaoMapUri = Uri.parse(_getKakaoMapUrl());

    if (await canLaunchUrl(kakaoMapUri)) {
      await launchUrl(kakaoMapUri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('카카오맵을 열 수 없습니다.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _openKakaoRoadview() async {
    final Uri roadviewUri = Uri.parse(_getKakaoRoadviewUrl());

    if (await canLaunchUrl(roadviewUri)) {
      await launchUrl(roadviewUri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('로드뷰를 열 수 없습니다.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black87),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.stationName,
          style: const TextStyle(
            color: Colors.black87,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              color: _primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: IconButton(
              icon: Icon(Icons.open_in_new, color: _primaryColor),
              tooltip: '카카오맵에서 열기',
              onPressed: _openKakaoRoadview,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 20,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 아이콘
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: _primaryColor.withValues(alpha: 0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.streetview,
                        size: 48,
                        color: _primaryColor,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // 스테이션 이름
                    Text(
                      widget.stationName,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),

                    // 좌표 정보
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.location_on, size: 16, color: Colors.grey[600]),
                          const SizedBox(width: 4),
                          Text(
                            '${widget.latitude.toStringAsFixed(6)}, ${widget.longitude.toStringAsFixed(6)}',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[600],
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),

                    // 구분선
                    Divider(color: Colors.grey[200]),
                    const SizedBox(height: 24),

                    // 안내 텍스트
                    Text(
                      '외부 앱에서 위치를 확인하세요',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 로드뷰 버튼 (메인)
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _openKakaoRoadview,
                        icon: const Icon(Icons.streetview),
                        label: const Text('카카오 로드뷰에서 보기'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 지도 버튼 (서브)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _openKakaoMap,
                        icon: Icon(Icons.map_outlined, color: _primaryColor),
                        label: Text(
                          '카카오맵에서 보기',
                          style: TextStyle(color: _primaryColor),
                        ),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          side: BorderSide(color: _primaryColor),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // 하단 안내
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, size: 18, color: Colors.blue.shade600),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '로드뷰 서비스가 해당 위치에서 제공되지 않을 수 있습니다.',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.blue.shade700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
