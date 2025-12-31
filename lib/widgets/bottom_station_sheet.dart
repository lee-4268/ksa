import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/radio_station.dart';
import '../providers/station_provider.dart';

class BottomStationSheet extends StatefulWidget {
  final Function(RadioStation) onStationTap;

  const BottomStationSheet({
    super.key,
    required this.onStationTap,
  });

  @override
  State<BottomStationSheet> createState() => _BottomStationSheetState();
}

class _BottomStationSheetState extends State<BottomStationSheet> {
  final DraggableScrollableController _sheetController =
      DraggableScrollableController();

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: 0.25,
      minChildSize: 0.12,
      maxChildSize: 0.85,
      snap: true,
      snapSizes: const [0.25, 0.5, 0.85],
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Consumer<StationProvider>(
            builder: (context, provider, child) {
              return CustomScrollView(
                controller: scrollController,
                slivers: [
                  // 드래그 핸들 및 헤더
                  SliverToBoxAdapter(
                    child: _buildHeader(provider),
                  ),
                  // 카테고리 탭
                  SliverToBoxAdapter(
                    child: _buildCategoryTabs(provider),
                  ),
                  // 스테이션 리스트
                  _buildStationList(provider),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildHeader(StationProvider provider) {
    final filteredCount = provider.filteredStations.length;

    return Column(
      children: [
        // 드래그 핸들
        Container(
          margin: const EdgeInsets.symmetric(vertical: 10),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.grey[300],
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        // 헤더 정보
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.location_on, color: Colors.red[400], size: 20),
                  const SizedBox(width: 4),
                  Text(
                    '장소',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey[800],
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Icon(Icons.route, color: Colors.blue[400], size: 18),
                  const SizedBox(width: 4),
                  Text(
                    '경로',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 리스트 정보
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '전체 리스트 $filteredCount',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey[900],
                ),
              ),
              Row(
                children: [
                  Text(
                    '최신순',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[600],
                    ),
                  ),
                  Icon(Icons.keyboard_arrow_down,
                      size: 18, color: Colors.grey[600]),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 새 리스트 만들기 버튼
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: InkWell(
            onTap: () => provider.importFromExcel(),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey[300]!),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add, size: 18, color: Colors.grey[600]),
                  const SizedBox(width: 4),
                  Text(
                    '새 리스트 만들기',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[700],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildCategoryTabs(StationProvider provider) {
    final categories = provider.categories;

    if (categories.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      height: 80,
      padding: const EdgeInsets.only(bottom: 8),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: categories.length,
        itemBuilder: (context, index) {
          final category = categories[index];
          final stationCount =
              provider.stationsByCategory[category]?.length ?? 0;
          final isSelected = provider.selectedCategories.contains(category);

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: _buildCategoryCard(
              category: category,
              count: stationCount,
              isSelected: isSelected,
              onTap: () => provider.toggleCategory(category),
              onLongPress: () => _showCategoryOptions(category),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCategoryCard({
    required String category,
    required int count,
    required bool isSelected,
    required VoidCallback onTap,
    required VoidCallback onLongPress,
  }) {
    // 카테고리별 아이콘 및 색상
    IconData icon;
    Color iconColor;

    if (category.contains('안테나') || category.contains('사진')) {
      icon = Icons.camera_alt;
      iconColor = Colors.orange;
    } else if (category.contains('내 장소') || category.contains('장소')) {
      icon = Icons.location_on;
      iconColor = Colors.red;
    } else {
      icon = Icons.folder;
      iconColor = Colors.blue;
    }

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: 80,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue.shade50 : Colors.grey[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? Colors.blue : Colors.grey[200]!,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: iconColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: iconColor, size: 20),
                ),
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.grey[700],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              category,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? Colors.blue : Colors.grey[700],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStationList(StationProvider provider) {
    final stations = provider.filteredStations;

    if (stations.isEmpty) {
      return SliverFillRemaining(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.inbox, size: 48, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text(
                '등록된 무선국이 없습니다.',
                style: TextStyle(color: Colors.grey[600]),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => provider.importFromExcel(),
                icon: const Icon(Icons.file_upload),
                label: const Text('Excel 파일 가져오기'),
              ),
            ],
          ),
        ),
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final station = stations[index];
          return _buildStationItem(station);
        },
        childCount: stations.length,
      ),
    );
  }

  Widget _buildStationItem(RadioStation station) {
    return InkWell(
      onTap: () => widget.onStationTap(station),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Colors.grey[200]!),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 아이콘
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: station.hasCoordinates
                    ? Colors.blue.shade50
                    : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                station.hasCoordinates ? Icons.location_on : Icons.location_off,
                color: station.hasCoordinates ? Colors.blue : Colors.grey,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            // 정보
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 호출명칭 또는 국소명
                  Text(
                    station.displayName,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  // 주소
                  Text(
                    station.address,
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[600],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  // 태그들
                  Row(
                    children: [
                      if (station.categoryName != null)
                        _buildTag(station.categoryName!, Colors.blue),
                      if (station.gain != null && station.gain!.isNotEmpty)
                        _buildTag('${station.gain}dB', Colors.green),
                      if (station.antennaCount != null &&
                          station.antennaCount!.isNotEmpty)
                        _buildTag('${station.antennaCount}기', Colors.orange),
                    ],
                  ),
                ],
              ),
            ),
            // 검사 상태 표시
            if (station.isInspected)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.shade100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '완료',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.green.shade700,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTag(String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  void _showCategoryOptions(String category) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: Text('$category 삭제'),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteCategory(category);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteCategory(String category) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('카테고리 삭제'),
        content: Text('$category의 모든 데이터를 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              context.read<StationProvider>().deleteCategoryData(category);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
  }
}
