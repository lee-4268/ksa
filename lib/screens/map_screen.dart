import 'package:flutter/foundation.dart' show kIsWeb;
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
  String _sortOrder = '최신순'; // 정렬 순서
  bool _isEditMode = false; // 편집 모드
  final Set<String> _selectedStationIds = {}; // 선택된 스테이션 ID들

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
    // 웹에서는 좌우 레이아웃, 모바일에서는 상하 레이아웃
    if (kIsWeb) {
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
          // 좌우 분할: 지도(왼쪽) + 리스트(오른쪽)
          Expanded(
            child: Row(
              children: [
                // 지도 (왼쪽 70%)
                Expanded(
                  flex: 7,
                  child: platform_map.PlatformMapWidget(
                    key: _mapKey,
                    stations: provider.stationsWithCoordinates,
                    onMarkerTap: _showStationDetail,
                  ),
                ),
                // 카테고리 리스트 (오른쪽 30%)
                SizedBox(
                  width: 360,
                  child: _buildCategorySheet(provider, isWebLayout: true),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // 모바일: 기존 상하 레이아웃
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

    // flex 값 계산 (소수점을 정수로 변환하여 부드러운 전환)
    final mapFlex = ((1 - _sheetSize) * 100).round().clamp(20, 80);
    final sheetFlex = (_sheetSize * 100).round().clamp(20, 80);

    // 웹에서는 좌우 레이아웃
    if (kIsWeb) {
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
          // 좌우 분할: 지도(왼쪽) + 리스트(오른쪽)
          Expanded(
            child: Row(
              children: [
                // 지도 영역 (왼쪽)
                Expanded(
                  flex: 7,
                  child: Stack(
                    children: [
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
                // 상세 리스트 (오른쪽)
                SizedBox(
                  width: 400,
                  child: _buildDetailList(provider, categoryStations, isWebLayout: true),
                ),
              ],
            ),
          ),
        ],
      );
    }

    // 모바일: 기존 상하 레이아웃
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
          flex: mapFlex,
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
          flex: sheetFlex,
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
  Widget _buildCategorySheet(StationProvider provider, {bool isWebLayout = false}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: isWebLayout
            ? BorderRadius.zero
            : const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: isWebLayout ? const Offset(-2, 0) : const Offset(0, -2),
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

  /// 정렬된 스테이션 목록 반환
  List<RadioStation> _getSortedStations(List<RadioStation> stations) {
    final sorted = List<RadioStation>.from(stations);

    switch (_sortOrder) {
      case '주소순':
        sorted.sort((a, b) => a.address.compareTo(b.address));
        break;
      case '최신순':
      default:
        // 기본 순서 유지 (가져온 순서)
        break;
    }

    return sorted;
  }

  /// 상세 리스트 (deep.png 스타일)
  Widget _buildDetailList(StationProvider provider, List<RadioStation> stations, {bool isWebLayout = false}) {
    final sortedStations = _getSortedStations(stations);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: isWebLayout
            ? BorderRadius.zero
            : const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: isWebLayout ? const Offset(-2, 0) : const Offset(0, -2),
          ),
        ],
      ),
      child: Column(
        children: [
          // 드래그 가능한 헤더 영역 전체
          GestureDetector(
            onVerticalDragUpdate: (details) {
              final delta = details.delta.dy / MediaQuery.of(context).size.height;
              final newSize = (_sheetSize - delta).clamp(0.2, 0.7);
              if ((newSize - _sheetSize).abs() > 0.005) {
                setState(() {
                  _sheetSize = newSize;
                });
              }
            },
            onVerticalDragEnd: (details) {
              setState(() {
                if (_sheetSize < 0.35) {
                  _sheetSize = 0.2;
                } else if (_sheetSize > 0.55) {
                  _sheetSize = 0.7;
                } else {
                  _sheetSize = 0.4;
                }
              });
            },
            behavior: HitTestBehavior.opaque,
            child: Column(
              children: [
                // 드래그 핸들
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12),
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
                              _isEditMode
                                  ? '${_selectedStationIds.length}개 선택됨'
                                  : '비공개 · ${sortedStations.length}개',
                              style: TextStyle(
                                fontSize: 12,
                                color: _isEditMode ? Colors.red : Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_isEditMode) ...[
                        // 편집 모드: 삭제 버튼
                        TextButton(
                          onPressed: _selectedStationIds.isEmpty
                              ? null
                              : () => _deleteSelectedStations(provider),
                          child: Text(
                            '삭제',
                            style: TextStyle(
                              color: _selectedStationIds.isEmpty ? Colors.grey : Colors.red,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        // 완료 버튼
                        OutlinedButton(
                          onPressed: () {
                            setState(() {
                              _isEditMode = false;
                              _selectedStationIds.clear();
                            });
                          },
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            side: BorderSide(color: Colors.blue),
                          ),
                          child: const Text('완료', style: TextStyle(fontSize: 12, color: Colors.blue)),
                        ),
                      ] else
                        // 일반 모드: 편집 버튼
                        OutlinedButton(
                          onPressed: () {
                            setState(() {
                              _isEditMode = true;
                              _selectedStationIds.clear();
                            });
                          },
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            side: BorderSide(color: Colors.grey[300]!),
                          ),
                          child: const Text('편집', style: TextStyle(fontSize: 12)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // 편집 모드일 때 전체 선택/해제 옵션
          if (_isEditMode)
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        if (_selectedStationIds.length == sortedStations.length) {
                          _selectedStationIds.clear();
                        } else {
                          _selectedStationIds.clear();
                          _selectedStationIds.addAll(sortedStations.map((s) => s.id));
                        }
                      });
                    },
                    child: Row(
                      children: [
                        Icon(
                          _selectedStationIds.length == sortedStations.length
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 20,
                          color: Colors.blue,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '전체 선택',
                          style: TextStyle(fontSize: 13, color: Colors.grey[700]),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_selectedStationIds.length}/${sortedStations.length}',
                    style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                  ),
                ],
              ),
            )
          else
            // 필터 탭 (전체만)
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  _buildFilterChip('전체', true),
                  const Spacer(),
                  // 정렬 드롭다운
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      setState(() {
                        _sortOrder = value;
                      });
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(value: '최신순', child: Text('최신순')),
                      PopupMenuItem(value: '주소순', child: Text('주소순')),
                    ],
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _sortOrder,
                          style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                        ),
                        Icon(Icons.keyboard_arrow_down, size: 18, color: Colors.grey[600]),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // 정보 없는 장소 알림
          if (!_isEditMode && sortedStations.any((s) => !s.hasCoordinates))
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
                    '정보가 없거나 위치가 변경된 장소 ${sortedStations.where((s) => !s.hasCoordinates).length}',
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
              itemCount: sortedStations.length,
              separatorBuilder: (_, __) => Divider(height: 1, indent: _isEditMode ? 56 : 16, endIndent: 16),
              itemBuilder: (context, index) {
                final station = sortedStations[index];
                return _buildStationListItem(station);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 선택된 스테이션들 삭제
  void _deleteSelectedStations(StationProvider provider) {
    if (_selectedStationIds.isEmpty) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('선택 항목 삭제'),
        content: Text('${_selectedStationIds.length}개의 항목을 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              for (final id in _selectedStationIds) {
                provider.deleteStation(id);
              }
              setState(() {
                _selectedStationIds.clear();
                _isEditMode = false;
              });
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
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
        onSelected: null,
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
    final isSelected = _selectedStationIds.contains(station.id);

    return InkWell(
      onTap: () {
        if (_isEditMode) {
          // 편집 모드에서는 체크박스 토글
          setState(() {
            if (isSelected) {
              _selectedStationIds.remove(station.id);
            } else {
              _selectedStationIds.add(station.id);
            }
          });
        } else {
          _showStationDetail(station);
        }
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        color: isSelected ? Colors.blue.shade50 : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 편집 모드일 때 체크박스
            if (_isEditMode) ...[
              Padding(
                padding: const EdgeInsets.only(right: 12, top: 16),
                child: Icon(
                  isSelected ? Icons.check_box : Icons.check_box_outline_blank,
                  color: isSelected ? Colors.blue : Colors.grey[400],
                  size: 24,
                ),
              ),
            ],
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
            // 더보기 버튼 (편집 모드가 아닐 때만)
            if (!_isEditMode)
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
