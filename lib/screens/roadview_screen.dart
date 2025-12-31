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
          const SnackBar(content: Text('카카오맵을 열 수 없습니다.')),
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
          const SnackBar(content: Text('로드뷰를 열 수 없습니다.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.stationName),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: '카카오맵에서 열기',
            onPressed: _openKakaoRoadview,
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.streetview,
              size: 80,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 24),
            Text(
              widget.stationName,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              '위치: ${widget.latitude.toStringAsFixed(6)}, ${widget.longitude.toStringAsFixed(6)}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _openKakaoRoadview,
              icon: const Icon(Icons.streetview),
              label: const Text('카카오 로드뷰에서 보기'),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _openKakaoMap,
              icon: const Icon(Icons.map_outlined),
              label: const Text('카카오맵에서 보기'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
