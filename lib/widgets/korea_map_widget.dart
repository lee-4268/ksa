import 'package:flutter/material.dart';
import 'package:countries_world_map/countries_world_map.dart';
import 'package:countries_world_map/data/maps/countries/south_korea.dart';

/// 본부별 데이터 모델
class RegionData {
  final String name;
  final String shortName;
  final int total;
  final int completed;
  final Color baseColor;

  RegionData({
    required this.name,
    required this.shortName,
    required this.total,
    required this.completed,
    this.baseColor = const Color(0xFF4A90D9),
  });

  double get progressRate => total > 0 ? completed / total : 0.0;
  int get progressPercent => (progressRate * 100).round();
}

/// 실제 한반도 SVG 지도 위젯 (countries_world_map 패키지 사용)
/// 라벨은 지도 바깥에 배치하고 선으로 연결
class KoreaMapWidget extends StatefulWidget {
  final Map<String, RegionData> regionData;
  final Function(String regionId, RegionData data)? onRegionTap;
  final String? selectedRegion;

  const KoreaMapWidget({
    super.key,
    required this.regionData,
    this.onRegionTap,
    this.selectedRegion,
  });

  @override
  State<KoreaMapWidget> createState() => _KoreaMapWidgetState();
}

class _KoreaMapWidgetState extends State<KoreaMapWidget> {
  // 호버 상태
  String? _hoveredRegion;

  // 본부별 시도 매핑
  static const Map<String, List<String>> _regionToProvinces = {
    'gangbuk': ['KR-11'],
    'gangnam': ['KR-11'],
    'incheon': ['KR-28'],
    'gyeonggi': ['KR-41'],
    'gangwon': ['KR-42'],
    'chungcheong': ['KR-43', 'KR-44', 'KR-30', 'KR-50'],
    'gyeongbuk': ['KR-47', 'KR-27'],
    'gyeongnam': ['KR-48', 'KR-26', 'KR-31'],
    'seobu': ['KR-45', 'KR-46', 'KR-29', 'KR-49'],
  };

  // 지역 중심점 좌표 (지도 내 상대 위치 - SVG viewBox 524x630 기준)
  // 실제 시도 위치에 맞게 조정
  static const Map<String, Offset> _regionCenters = {
    'incheon': Offset(0.18, 0.20),      // 인천: 서북부
    'gangbuk': Offset(0.30, 0.19),      // 강북(서울): 서울 상단 (노란점)
    'gangnam': Offset(0.30, 0.21),      // 강남(서울): 서울 하단 (빨간점)
    'gyeonggi': Offset(0.30, 0.25),     // 경기: 서울 주변
    'gangwon': Offset(0.53, 0.15),      // 강원: 동북부
    'chungcheong': Offset(0.35, 0.40),  // 충청: 중부
    'gyeongbuk': Offset(0.60, 0.42),    // 경북: 동부
    'seobu': Offset(0.30, 0.62),        // 서부(전라): 서남부
    'gyeongnam': Offset(0.52, 0.60),    // 경남: 동남부
  };

  // 왼쪽에 배치할 본부들 (서쪽 지역)
  static const List<String> _leftRegions = ['incheon', 'gyeonggi', 'chungcheong', 'seobu'];

  // 오른쪽에 배치할 본부들 (동쪽 지역)
  static const List<String> _rightRegions = ['gangbuk', 'gangnam', 'gangwon', 'gyeongbuk', 'gyeongnam'];

  late Map<String, String> _provinceToRegion;

  @override
  void initState() {
    super.initState();
    _provinceToRegion = {};
    for (final entry in _regionToProvinces.entries) {
      for (final province in entry.value) {
        _provinceToRegion[province] = entry.key;
      }
    }
  }

  Color _getProgressColor(double rate) {
    if (rate >= 0.8) return const Color(0xFF43A047);
    if (rate >= 0.5) return const Color(0xFFFFA726);
    return const Color(0xFFE53935);
  }

  Color? _getProvinceColor(String provinceCode) {
    final regionId = _provinceToRegion[provinceCode];
    if (regionId == null) return Colors.grey.shade300;

    final data = widget.regionData[regionId];
    if (data == null) return Colors.grey.shade300;

    final isSelected = widget.selectedRegion == regionId;
    final isHovered = _hoveredRegion == regionId;
    final isHighlighted = isSelected || isHovered;
    final baseColor = _getProgressColor(data.progressRate);

    return isHighlighted
        ? baseColor.withValues(alpha: 0.95)
        : baseColor.withValues(alpha: 0.65);
  }

  void _handleProvinceTap(String provinceCode, String provinceName, TapUpDetails details) {
    final regionId = _provinceToRegion[provinceCode];
    if (regionId == null) return;

    final data = widget.regionData[regionId];
    if (data != null) {
      widget.onRegionTap?.call(regionId, data);
    }
  }

  // 지도 위 호버 감지 오버레이
  List<Widget> _buildHoverOverlays(double mapWidth, double mapHeight) {
    return _regionCenters.entries.map((entry) {
      final regionId = entry.key;
      final center = entry.value;
      final data = widget.regionData[regionId];

      if (data == null) return const SizedBox.shrink();

      // 지역 크기에 따른 호버 영역 크기 조정
      final hoverSize = _getHoverAreaSize(regionId, mapWidth, mapHeight);

      return Positioned(
        left: mapWidth * center.dx - hoverSize / 2,
        top: mapHeight * center.dy - hoverSize / 2,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hoveredRegion = regionId),
          onExit: (_) => setState(() => _hoveredRegion = null),
          child: GestureDetector(
            onTap: () => widget.onRegionTap?.call(regionId, data),
            child: Container(
              width: hoverSize,
              height: hoverSize,
              decoration: const BoxDecoration(
                color: Colors.transparent,
              ),
            ),
          ),
        ),
      );
    }).toList();
  }

  // 지역별 호버 영역 크기
  double _getHoverAreaSize(String regionId, double mapWidth, double mapHeight) {
    final baseSize = mapWidth * 0.12;
    switch (regionId) {
      case 'gangbuk':
      case 'gangnam':
        return baseSize * 0.6; // 서울은 작게
      case 'incheon':
        return baseSize * 0.7;
      case 'gyeonggi':
        return baseSize * 0.8;
      case 'gangwon':
      case 'gyeongbuk':
        return baseSize * 1.2; // 큰 지역은 크게
      case 'chungcheong':
      case 'seobu':
      case 'gyeongnam':
        return baseSize;
      default:
        return baseSize;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 라벨 영역 폭
        const labelAreaWidth = 70.0;

        // 지도가 사용할 수 있는 영역 (양쪽 라벨 영역 제외)
        final availableWidth = constraints.maxWidth - (labelAreaWidth * 2);
        final availableHeight = constraints.maxHeight;

        // 지도 비율 (가로:세로 = 524:630 ≈ 0.83)
        const mapAspectRatio = 524.0 / 630.0;

        double mapWidth, mapHeight;

        if (availableWidth / availableHeight > mapAspectRatio) {
          mapHeight = availableHeight;
          mapWidth = mapHeight * mapAspectRatio;
        } else {
          mapWidth = availableWidth;
          mapHeight = mapWidth / mapAspectRatio;
        }

        // 지도 위치 (중앙)
        final mapLeft = labelAreaWidth + (availableWidth - mapWidth) / 2;
        final mapTop = (availableHeight - mapHeight) / 2;

        return Stack(
          children: [
            // 연결선 (라벨과 지역 연결)
            CustomPaint(
              size: Size(constraints.maxWidth, constraints.maxHeight),
              painter: _ConnectionLinePainter(
                regionData: widget.regionData,
                regionCenters: _regionCenters,
                mapLeft: mapLeft,
                mapTop: mapTop,
                mapWidth: mapWidth,
                mapHeight: mapHeight,
                labelAreaWidth: labelAreaWidth,
                selectedRegion: widget.selectedRegion,
                hoveredRegion: _hoveredRegion,
                getProgressColor: _getProgressColor,
              ),
            ),

            // 한국 지도 (중앙)
            Positioned(
              left: mapLeft,
              top: mapTop,
              width: mapWidth,
              height: mapHeight,
              child: Stack(
                children: [
                  // 지도
                  SimpleMap(
                    instructions: SMapSouthKorea.instructions,
                    defaultColor: Colors.grey.shade300,
                    countryBorder: CountryBorder(color: const Color(0xFF455A64), width: 1),
                    colors: SMapSouthKoreaColors(
                      kr11: _getProvinceColor('KR-11'),
                      kr26: _getProvinceColor('KR-26'),
                      kr27: _getProvinceColor('KR-27'),
                      kr28: _getProvinceColor('KR-28'),
                      kr29: _getProvinceColor('KR-29'),
                      kr30: _getProvinceColor('KR-30'),
                      kr31: _getProvinceColor('KR-31'),
                      kr41: _getProvinceColor('KR-41'),
                      kr42: _getProvinceColor('KR-42'),
                      kr43: _getProvinceColor('KR-43'),
                      kr44: _getProvinceColor('KR-44'),
                      kr45: _getProvinceColor('KR-45'),
                      kr46: _getProvinceColor('KR-46'),
                      kr47: _getProvinceColor('KR-47'),
                      kr48: _getProvinceColor('KR-48'),
                      kr49: _getProvinceColor('KR-49'),
                      kr50: _getProvinceColor('KR-50'),
                    ).toMap(),
                    callback: _handleProvinceTap,
                  ),
                  // 호버 감지 오버레이
                  ..._buildHoverOverlays(mapWidth, mapHeight),
                ],
              ),
            ),

            // 왼쪽 라벨들
            ..._buildLeftLabels(labelAreaWidth, mapTop, mapHeight),

            // 오른쪽 라벨들
            ..._buildRightLabels(constraints.maxWidth, labelAreaWidth, mapTop, mapHeight),
          ],
        );
      },
    );
  }

  List<Widget> _buildLeftLabels(double labelAreaWidth, double mapTop, double mapHeight) {
    final labels = <Widget>[];
    final regions = _leftRegions.where((id) => widget.regionData.containsKey(id)).toList();

    if (regions.isEmpty) return labels;

    final spacing = mapHeight / (regions.length + 1);

    for (int i = 0; i < regions.length; i++) {
      final regionId = regions[i];
      final data = widget.regionData[regionId]!;
      final isSelected = widget.selectedRegion == regionId;
      final y = mapTop + spacing * (i + 1);

      labels.add(
        Positioned(
          left: 4,
          top: y - 22,
          width: labelAreaWidth - 8,
          child: _buildLabelWidget(regionId, data, isSelected),
        ),
      );
    }

    return labels;
  }

  List<Widget> _buildRightLabels(double totalWidth, double labelAreaWidth, double mapTop, double mapHeight) {
    final labels = <Widget>[];
    final regions = _rightRegions.where((id) => widget.regionData.containsKey(id)).toList();

    if (regions.isEmpty) return labels;

    final spacing = mapHeight / (regions.length + 1);

    for (int i = 0; i < regions.length; i++) {
      final regionId = regions[i];
      final data = widget.regionData[regionId]!;
      final isSelected = widget.selectedRegion == regionId;
      final y = mapTop + spacing * (i + 1);

      labels.add(
        Positioned(
          right: 4,
          top: y - 22,
          width: labelAreaWidth - 8,
          child: _buildLabelWidget(regionId, data, isSelected),
        ),
      );
    }

    return labels;
  }

  Widget _buildLabelWidget(String regionId, RegionData data, bool isSelected) {
    final isHovered = _hoveredRegion == regionId;
    final isHighlighted = isSelected || isHovered;
    final progressColor = _getProgressColor(data.progressRate);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hoveredRegion = regionId),
      onExit: (_) => setState(() => _hoveredRegion = null),
      child: GestureDetector(
        onTap: () => widget.onRegionTap?.call(regionId, data),
        child: AnimatedScale(
          scale: isHovered ? 1.08 : 1.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            width: 80,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            decoration: BoxDecoration(
            color: isHovered
                ? progressColor.withValues(alpha: 0.08)
                : Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isHighlighted ? progressColor : Colors.grey.shade400,
              width: isHighlighted ? 2 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: isHighlighted
                    ? progressColor.withValues(alpha: 0.3)
                    : Colors.black.withValues(alpha: 0.12),
                blurRadius: isHighlighted ? 8 : 4,
                offset: const Offset(0, 2),
                spreadRadius: isHovered ? 1 : 0,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isHighlighted ? progressColor : Colors.grey.shade800,
                ),
                child: Text(data.shortName),
              ),
              const SizedBox(height: 2),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: progressColor,
                ),
                child: Text('${data.progressPercent}%'),
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${data.completed}/${data.total}',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.grey.shade600,
                  ),
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

/// 라벨과 지역을 연결하는 선을 그리는 Painter
class _ConnectionLinePainter extends CustomPainter {
  final Map<String, RegionData> regionData;
  final Map<String, Offset> regionCenters;
  final double mapLeft;
  final double mapTop;
  final double mapWidth;
  final double mapHeight;
  final double labelAreaWidth;
  final String? selectedRegion;
  final String? hoveredRegion;
  final Color Function(double) getProgressColor;

  static const List<String> _leftRegions = ['incheon', 'gyeonggi', 'chungcheong', 'seobu'];
  static const List<String> _rightRegions = ['gangbuk', 'gangnam', 'gangwon', 'gyeongbuk', 'gyeongnam'];

  _ConnectionLinePainter({
    required this.regionData,
    required this.regionCenters,
    required this.mapLeft,
    required this.mapTop,
    required this.mapWidth,
    required this.mapHeight,
    required this.labelAreaWidth,
    required this.selectedRegion,
    required this.hoveredRegion,
    required this.getProgressColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 왼쪽 라벨 연결선
    final leftRegions = _leftRegions.where((id) => regionData.containsKey(id)).toList();
    final leftSpacing = mapHeight / (leftRegions.length + 1);

    for (int i = 0; i < leftRegions.length; i++) {
      final regionId = leftRegions[i];
      final center = regionCenters[regionId];
      if (center == null) continue;

      final data = regionData[regionId]!;
      final isSelected = selectedRegion == regionId;
      final isHovered = hoveredRegion == regionId;

      // 라벨 오른쪽 끝점
      final labelY = mapTop + leftSpacing * (i + 1);
      final labelEndX = labelAreaWidth - 4;

      // 지역 중심점
      final regionX = mapLeft + mapWidth * center.dx;
      final regionY = mapTop + mapHeight * center.dy;

      _drawConnectionLine(
        canvas,
        Offset(labelEndX, labelY),
        Offset(regionX, regionY),
        getProgressColor(data.progressRate),
        isSelected,
        isHovered,
      );
    }

    // 오른쪽 라벨 연결선
    final rightRegions = _rightRegions.where((id) => regionData.containsKey(id)).toList();
    final rightSpacing = mapHeight / (rightRegions.length + 1);

    for (int i = 0; i < rightRegions.length; i++) {
      final regionId = rightRegions[i];
      final center = regionCenters[regionId];
      if (center == null) continue;

      final data = regionData[regionId]!;
      final isSelected = selectedRegion == regionId;
      final isHovered = hoveredRegion == regionId;

      // 라벨 왼쪽 끝점
      final labelY = mapTop + rightSpacing * (i + 1);
      final labelStartX = size.width - labelAreaWidth + 4;

      // 지역 중심점
      final regionX = mapLeft + mapWidth * center.dx;
      final regionY = mapTop + mapHeight * center.dy;

      _drawConnectionLine(
        canvas,
        Offset(labelStartX, labelY),
        Offset(regionX, regionY),
        getProgressColor(data.progressRate),
        isSelected,
        isHovered,
      );
    }
  }

  void _drawConnectionLine(Canvas canvas, Offset start, Offset end, Color color, bool isSelected, bool isHovered) {
    final isHighlighted = isSelected || isHovered;
    final paint = Paint()
      ..color = color.withValues(alpha: isHighlighted ? 0.9 : 0.4)
      ..strokeWidth = isHighlighted ? 2.5 : 1.5
      ..style = PaintingStyle.stroke;

    final path = Path();
    path.moveTo(start.dx, start.dy);

    // 부드러운 곡선으로 연결
    final midX = (start.dx + end.dx) / 2;
    path.quadraticBezierTo(midX, start.dy, end.dx, end.dy);

    canvas.drawPath(path, paint);

    // 끝점에 작은 원 표시
    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(end, isHighlighted ? 5 : 3, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _ConnectionLinePainter oldDelegate) {
    return oldDelegate.selectedRegion != selectedRegion ||
           oldDelegate.hoveredRegion != hoveredRegion ||
           oldDelegate.regionData != regionData;
  }
}
