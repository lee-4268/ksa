import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/radio_station.dart';
import '../providers/station_provider.dart';
import '../widgets/station_detail_sheet.dart';
import 'roadview_screen.dart';

// 조건부 import
import 'map_screen_web.dart' if (dart.library.io) 'map_screen_mobile.dart'
    as platform_map;

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _mapKey = GlobalKey();
  final TextEditingController _searchController = TextEditingController();

  String? _selectedCategory; // 선택된 카테고리
  double _sheetSize = 0.4; // 하단 시트 크기 비율

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<StationProvider>().loadStations();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      body: Consumer<StationProvider>(
        builder: (context, provider, child) {
          if (provider.isLoading) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('데이터 로딩 중...'),
                ],
              ),
            );
          }

          // 카테고리가 선택되지 않았으면 카테고리 목록 화면
          if (_selectedCategory == null) {
            return _buildCategoryListView(provider);
          }

          // 카테고리가 선택되었으면 지도 + 상세 리스트 화면
          return _buildMapDetailView(provider);
        },
      ),
    );
  }

  /// 카테고리 목록 화면 (sample.png의 '내 장소', '안테나사진' 등)
  Widget _buildCategoryListView(StationProvider provider) {
    return Column(
      children: [
        // 상단 SafeArea + 검색바
        Container(
          color: Colors.white,
          child: SafeArea(
            bottom: false,
            child: _buildSearchBar(provider),
          ),
        ),

        // 지도 (전체 대한민국)
        Expanded(
          flex: 5,
          child: platform_map.PlatformMapWidget(
            key: _mapKey,
            stations: provider.stationsWithCoordinates,
            onMarkerTap: _showStationDetail,
          ),
        ),

        // 하단 카테고리 리스트
        Expanded(
          flex: 5,
          child: _buildCategorySheet(provider),
        ),
      ],
    );
  }

  /// 지도 + 상세 리스트 화면 (deep.png 스타일)
  Widget _buildMapDetailView(StationProvider provider) {
    final categoryStations = provider.stationsByCategory[_selectedCategory] ?? [];
    final stationsWithCoords = categoryStations.where((s) => s.hasCoordinates).toList();

    return Column(
      children: [
        // 상단 SafeArea + 뒤로가기 + 카테고리명
        Container(
          color: Colors.white,
          child: SafeArea(
            bottom: false,
            child: _buildDetailHeader(provider),
          ),
        ),

        // 지도 영역
        Expanded(
          flex: (10 * (1 - _sheetSize)).round(),
          child: Stack(
            children: [
              // 지도 - 선택된 카테고리의 마커만 표시
              platform_map.PlatformMapWidget(
                stations: stationsWithCoords,
                onMarkerTap: _showStationDetail,
              ),

              // X 버튼 (닫기)
              Positioned(
                top: 8,
                right: 16,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      setState(() {
                        _selectedCategory = null;
                      });
                    },
                  ),
                ),
              ),
            ],
          ),
        ),

        // 하단 상세 리스트
        Expanded(
          flex: (10 * _sheetSize).round(),
          child: _buildDetailList(provider, categoryStations),
        ),
      ],
    );
  }

  Widget _buildSearchBar(StationProvider provider) {
    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: TextField(
        controller: _searchController,
        onChanged: (value) => provider.setSearchQuery(value),
        decoration: InputDecoration(
          hintText: '주소, 국소명 검색',
          hintStyle: TextStyle(color: Colors.grey[500], fontSize: 15),
          prefixIcon: Icon(Icons.search, color: Colors.grey[600]),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.clear, color: Colors.grey[600]),
                  onPressed: () {
                    _searchController.clear();
                    provider.setSearchQuery('');
                    setState(() {});
                  },
                )
              : null,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
        ),
      ),
    );
  }

  Widget _buildDetailHeader(StationProvider provider) {
    final categoryStations = provider.stationsByCategory[_selectedCategory] ?? [];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              setState(() {
                _selectedCategory = null;
              });
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _selectedCategory ?? '',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '${categoryStations.length}개 장소',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
          // 검색 아이콘
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              // 검색 기능
            },
          ),
        ],
      ),
    );
  }

  /// 카테고리 목록 시트 (sample.png 스타일)
  Widget _buildCategorySheet(StationProvider provider) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          // 드래그 핸들
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // 탭 (장소 / 경로)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                _buildTab('장소', Icons.location_on, true),
                const SizedBox(width: 24),
                _buildTab('경로', Icons.route, false),
              ],
            ),
          ),

          const Divider(height: 24),

          // 전체 리스트 헤더
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '전체 리스트 ${provider.categories.length}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Row(
                  children: [
                    Text(
                      '최신순',
                      style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                    ),
                    Icon(Icons.keyboard_arrow_down, size: 18, color: Colors.grey[600]),
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
              onTap: _importExcel,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey[300]!),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add, size: 20, color: Colors.grey[600]),
                    const SizedBox(width: 8),
                    Text(
                      '새 리스트 만들기',
                      style: TextStyle(fontSize: 14, color: Colors.grey[700]),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          // 카테고리 리스트
          Expanded(
            child: provider.categories.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.folder_open, size: 48, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text(
                          '등록된 리스트가 없습니다.',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: provider.categories.length,
                    itemBuilder: (context, index) {
                      final category = provider.categories[index];
                      final count = provider.stationsByCategory[category]?.length ?? 0;
                      return _buildCategoryItem(category, count);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTab(String label, IconData icon, bool isSelected) {
    return Row(
      children: [
        Icon(
          icon,
          size: 20,
          color: isSelected ? Colors.red[400] : Colors.grey[500],
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
            color: isSelected ? Colors.grey[900] : Colors.grey[500],
          ),
        ),
      ],
    );
  }

  Widget _buildCategoryItem(String category, int count) {
    // 카테고리별 아이콘/색상
    IconData icon;
    Color iconColor;
    Color bgColor;

    if (category.contains('안테나') || category.contains('사진')) {
      icon = Icons.camera_alt;
      iconColor = Colors.orange;
      bgColor = Colors.orange.shade50;
    } else if (category.contains('장소')) {
      icon = Icons.star;
      iconColor = Colors.amber;
      bgColor = Colors.amber.shade50;
    } else {
      icon = Icons.folder;
      iconColor = Colors.blue;
      bgColor = Colors.blue.shade50;
    }

    return InkWell(
      onTap: () {
        setState(() {
          _selectedCategory = category;
        });
      },
      onLongPress: () => _showCategoryOptions(category),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey[200]!),
        ),
        child: Row(
          children: [
            // 아이콘
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(width: 12),
            // 정보
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    category,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$count개 장소',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.grey[600],
                    ),
                  ),
                ],
              ),
            ),
            // Excel 내보내기 버튼
            IconButton(
              icon: Icon(Icons.file_download_outlined, color: Colors.blue[400], size: 22),
              onPressed: () => _exportCategoryToExcel(category),
              tooltip: 'Excel 내보내기',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 8),
            // 삭제 버튼
            IconButton(
              icon: Icon(Icons.delete_outline, color: Colors.grey[500], size: 22),
              onPressed: () => _confirmDeleteCategory(category),
              tooltip: '리스트 삭제',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 4),
            // 화살표
            Icon(Icons.chevron_right, color: Colors.grey[400]),
          ],
        ),
      ),
    );
  }

  /// 상세 리스트 (deep.png 스타일)
  Widget _buildDetailList(StationProvider provider, List<RadioStation> stations) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          // 드래그 핸들
          GestureDetector(
            onVerticalDragUpdate: (details) {
              setState(() {
                _sheetSize -= details.delta.dy / MediaQuery.of(context).size.height;
                _sheetSize = _sheetSize.clamp(0.2, 0.7);
              });
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              color: Colors.transparent,
              child: Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),

          // 카테고리 정보 헤더
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.amber.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.star, color: Colors.amber, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _selectedCategory ?? '',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        '비공개 · ${stations.length}개',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton(
                  onPressed: () {},
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    side: BorderSide(color: Colors.grey[300]!),
                  ),
                  child: const Text('편집', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // 필터 탭
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _buildFilterChip('최신순', true),
                _buildFilterChip('전체', false),
                _buildFilterChip('주소/위치', false),
                _buildFilterChip('음식점', false),
                _buildFilterChip('BAR', false),
              ],
            ),
          ),

          // 정보 없는 장소 알림
          if (stations.any((s) => !s.hasCoordinates))
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.blue[700], size: 18),
                  const SizedBox(width: 8),
                  Text(
                    '정보가 없거나 위치가 변경된 장소 ${stations.where((s) => !s.hasCoordinates).length}',
                    style: TextStyle(
                      fontSize: 13,
                      color: Colors.blue[700],
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.chevron_right, color: Colors.blue[700], size: 18),
                ],
              ),
            ),

          // 장소 리스트
          Expanded(
            child: ListView.separated(
              padding: EdgeInsets.zero,
              itemCount: stations.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 16, endIndent: 16),
              itemBuilder: (context, index) {
                final station = stations[index];
                return _buildStationListItem(station);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String label, bool isSelected) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: FilterChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (_) {},
        selectedColor: Colors.green.shade100,
        checkmarkColor: Colors.green,
        labelStyle: TextStyle(
          fontSize: 12,
          color: isSelected ? Colors.green[700] : Colors.grey[700],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _buildStationListItem(RadioStation station) {
    return InkWell(
      onTap: () => _showStationDetail(station),
      child: Container(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 썸네일 또는 아이콘
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: station.hasCoordinates ? Colors.blue.shade50 : Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                station.hasCoordinates ? Icons.location_on : Icons.location_off,
                color: station.hasCoordinates ? Colors.blue : Colors.grey,
                size: 28,
              ),
            ),
            const SizedBox(width: 12),
            // 정보
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 주소 (메인 타이틀)
                  Text(
                    station.address,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  // 호출명칭/국소명
                  if (station.callSign != null || station.stationName.isNotEmpty)
                    Text(
                      station.displayName,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[600],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 4),
                  // 태그
                  Row(
                    children: [
                      if (station.gain != null && station.gain!.isNotEmpty)
                        _buildSmallTag('${station.gain}dB'),
                      if (station.antennaCount != null && station.antennaCount!.isNotEmpty)
                        _buildSmallTag('${station.antennaCount}기'),
                      if (station.licenseNumber.isNotEmpty && station.licenseNumber != '-')
                        _buildSmallTag(station.licenseNumber),
                    ],
                  ),
                ],
              ),
            ),
            // 더보기 버튼
            IconButton(
              icon: Icon(Icons.more_vert, color: Colors.grey[400]),
              onPressed: () => _showStationOptions(station),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSmallTag(String text) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: Colors.grey[600],
        ),
      ),
    );
  }

  void _showStationDetail(RadioStation station) {
    final provider = context.read<StationProvider>();
    provider.selectStation(station);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => StationDetailSheet(
        station: station,
        onRoadviewTap: () {
          Navigator.pop(context);
          _openRoadview(station);
        },
      ),
    );
  }

  void _showStationOptions(RadioStation station) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.streetview),
              title: const Text('로드뷰 보기'),
              onTap: () {
                Navigator.pop(context);
                _openRoadview(station);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('메모 수정'),
              onTap: () {
                Navigator.pop(context);
                _showStationDetail(station);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('삭제', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                context.read<StationProvider>().deleteStation(station.id);
              },
            ),
          ],
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
              leading: const Icon(Icons.edit),
              title: const Text('이름 변경'),
              onTap: () {
                Navigator.pop(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: Text('$category 삭제', style: const TextStyle(color: Colors.red)),
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

  void _openRoadview(RadioStation station) {
    if (!station.hasCoordinates) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('좌표 정보가 없습니다.')),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RoadviewScreen(
          latitude: station.latitude!,
          longitude: station.longitude!,
          stationName: station.displayName,
        ),
      ),
    );
  }

  Future<void> _importExcel() async {
    final provider = context.read<StationProvider>();
    await provider.importFromExcel();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${provider.stations.length}개의 무선국을 가져왔습니다.'),
        ),
      );
    }
  }

  /// Excel 내보내기
  Future<void> _exportCategoryToExcel(String category) async {
    final provider = context.read<StationProvider>();

    // 로딩 표시
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    try {
      final filePath = await provider.exportCategoryToExcel(category);

      if (!mounted) return;
      Navigator.pop(context); // 로딩 다이얼로그 닫기

      if (filePath != null) {
        // 완료 다이얼로그 표시
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Excel 내보내기 완료'),
            content: Text('$category 검사 결과가 저장되었습니다.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('확인'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // 로딩 다이얼로그 닫기

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Excel 내보내기 실패: $e')),
      );
    }
  }
}
