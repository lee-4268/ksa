import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/radio_station.dart';
import '../providers/station_provider.dart';
import '../services/auth_service.dart';
import '../services/cloud_data_service.dart';
import '../widgets/station_detail_sheet.dart';
import 'roadview_screen.dart';
import 'login_screen.dart';

// 조건부 import
import 'map_screen_web.dart' if (dart.library.io) 'map_screen_mobile.dart'
    as platform_map;

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen>
    with AutomaticKeepAliveClientMixin<MapScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// AutomaticKeepAliveClientMixin: 위젯 상태 유지하여 지도 재생성 방지
  @override
  bool get wantKeepAlive => true;
  final GlobalKey<platform_map.PlatformMapWidgetState> _mapKey = GlobalKey<platform_map.PlatformMapWidgetState>();
  final GlobalKey<platform_map.PlatformMapWidgetState> _detailMapKey = GlobalKey<platform_map.PlatformMapWidgetState>();
  final TextEditingController _detailSearchController = TextEditingController();
  final FocusNode _detailSearchFocusNode = FocusNode();

  String? _selectedCategory; // 선택된 카테고리
  String? _lastFittedCategory; // 마지막으로 fitToStations 호출된 카테고리
  RadioStation? _targetStationOnCategoryEnter; // 카테고리 진입 시 이동할 스테이션 (검색에서 선택한 경우)
  RadioStation? _initialMapStation; // 맵 초기 위치 스테이션
  int? _initialMapZoomLevel; // 맵 초기 줌 레벨
  String _sortOrder = '최신순'; // 정렬 순서
  bool _isEditMode = false; // 편집 모드
  bool _isSearchMode = false; // 상세 화면 검색 모드
  String _detailSearchQuery = ''; // 상세 화면 검색어
  final Set<String> _selectedStationIds = {}; // 선택된 스테이션 ID들

  // 드래그 관련 상태 (맵 리사이즈 없이 리스트만 드래그)
  double _listHeightRatio = 0.35; // 리스트 높이 비율 (0.15 ~ 0.85) - 기본값 낮춤
  static const double _minListRatio = 0.15; // 최소 15%로 줄여서 맵이 더 많이 보이도록
  static const double _maxListRatio = 0.85; // 최대 85%로 늘려서 리스트를 더 크게 볼 수 있도록

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // CloudDataService 연결 후 데이터 로드
      final provider = context.read<StationProvider>();
      final cloudService = context.read<CloudDataService>();
      final authService = context.read<AuthService>();

      // 사용자가 로그인되어 있을 때만 CloudDataService 연결
      if (authService.isSignedIn) {
        provider.setCloudDataService(cloudService);
      }
      provider.loadStations();
    });
  }

  @override
  void dispose() {
    _detailSearchController.dispose();
    _detailSearchFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // AutomaticKeepAliveClientMixin 필수 호출
    super.build(context);

    return Scaffold(
      key: _scaffoldKey,
      // 키보드가 올라와도 레이아웃이 리사이즈되지 않도록 설정
      // 이렇게 하면 지도가 키보드에 의해 깜빡이는 현상 방지
      resizeToAvoidBottomInset: false,
      body: Consumer<StationProvider>(
        builder: (context, provider, child) {
          if (provider.isLoading) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // 진행률 바
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: provider.loadingProgress > 0 ? provider.loadingProgress : null,
                        minHeight: 12,
                        backgroundColor: Colors.grey[200],
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
                      ),
                    ),
                    const SizedBox(height: 16),
                    // 진행률 퍼센트
                    Text(
                      '${(provider.loadingProgress * 100).toInt()}%',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 상태 메시지
                    Text(
                      provider.loadingStatus.isNotEmpty
                          ? provider.loadingStatus
                          : '데이터 로딩 중...',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                      ),
                      textAlign: TextAlign.center,
                    ),
                    // 처리 항목 수 (지오코딩 중일 때)
                    if (provider.totalItems > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '${provider.processedItems} / ${provider.totalItems}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        ),
                      ),
                  ],
                ),
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
    // 화면 너비에 따라 레이아웃 결정 (모바일 웹에서도 모바일 레이아웃 적용)
    final screenWidth = MediaQuery.of(context).size.width;
    final isWideScreen = screenWidth >= 700; // 700px 이상이면 좌우 분할 레이아웃

    if (kIsWeb && isWideScreen) {
      return Column(
        children: [
          // 상단 SafeArea + 환영 헤더 (검색창 대신 환영 문구와 로그아웃 버튼)
          Container(
            color: Colors.white,
            child: SafeArea(
              bottom: false,
              child: _WelcomeHeaderWidget(
                onLogout: _handleLogout,
                onHome: () => Navigator.pop(context),
              ),
            ),
          ),
          // 좌우 분할: 지도(왼쪽) + 리스트(오른쪽)
          Expanded(
            child: Row(
              children: [
                // 지도 (왼쪽 70%) - 카테고리 목록에서는 마커 없이 표시 (최적화)
                Expanded(
                  flex: 7,
                  child: Stack(
                    children: [
                      platform_map.PlatformMapWidget(
                        key: _mapKey,
                        stations: const [], // 카테고리 목록에서는 마커 표시 안함
                        onMarkerTap: _showStationDetail,
                      ),
                      // 내 위치 버튼
                      Positioned(
                        right: 16,
                        bottom: 16,
                        child: _buildMyLocationButton(_mapKey),
                      ),
                    ],
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

    // 모바일: 맵 고정 크기 + 드래그 가능한 리스트 오버레이
    // 맵은 전체 화면 크기로 고정하고 리스트를 맵 위에 오버레이로 표시
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenHeight = constraints.maxHeight;
        final listHeight = screenHeight * _listHeightRatio;

        return Stack(
          children: [
            // 맵 - 고정 크기로 전체 공간 차지 (리사이즈 없음)
            Positioned.fill(
              child: Column(
                children: [
                  // 상단 SafeArea + 환영 헤더 (검색창 대신 환영 문구와 로그아웃 버튼)
                  Container(
                    color: Colors.white,
                    child: SafeArea(
                      bottom: false,
                      child: _WelcomeHeaderWidget(
                        onLogout: _handleLogout,
                        onHome: () => Navigator.pop(context),
                      ),
                    ),
                  ),
                  // 지도 - 남은 공간 전체 사용 (카테고리 목록에서는 마커 없이 표시)
                  Expanded(
                    child: Container(
                      color: const Color(0xFFF0F0F0),
                      child: Stack(
                        children: [
                          platform_map.PlatformMapWidget(
                            key: _mapKey,
                            stations: const [], // 카테고리 목록에서는 마커 표시 안함 (최적화)
                            onMarkerTap: _showStationDetail,
                          ),
                          // 내 위치 버튼
                          Positioned(
                            right: 16,
                            bottom: _listHeightRatio * MediaQuery.of(context).size.height + 16,
                            child: _buildMyLocationButton(_mapKey),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 리스트 오버레이 - 드래그로 높이 조절
            // 맵 드래그 비활성화 API 사용 (웹에서 HtmlElementView 이벤트 문제 해결)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: listHeight,
              child: Listener(
                behavior: HitTestBehavior.opaque, // 맵으로 이벤트 전달 방지
                onPointerDown: (_) {
                  // 리스트 터치 시 맵 드래그 비활성화
                  _mapKey.currentState?.setMapDraggable(false);
                },
                onPointerUp: (_) {
                  // 터치 종료 시 맵 드래그 활성화
                  _mapKey.currentState?.setMapDraggable(true);
                },
                onPointerCancel: (_) {
                  // 터치 취소 시 맵 드래그 활성화
                  _mapKey.currentState?.setMapDraggable(true);
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (details) {
                    setState(() {
                      _listHeightRatio = (_listHeightRatio - details.delta.dy / screenHeight)
                          .clamp(_minListRatio, _maxListRatio);
                    });
                  },
                  onVerticalDragEnd: (_) {
                    // 드래그 종료 시 맵 드래그 활성화
                    _mapKey.currentState?.setMapDraggable(true);
                  },
                  onHorizontalDragUpdate: (_) {}, // 수평 드래그도 소비
                  child: Container(
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
                        Center(
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 12),
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.grey[400],
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        // 콘텐츠
                        Expanded(child: _buildCategorySheet(provider)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 지도 + 상세 리스트 화면 (deep.png 스타일)
  Widget _buildMapDetailView(StationProvider provider) {
    final categoryStations = provider.stationsByCategory[_selectedCategory] ?? [];
    final stationsWithCoords = categoryStations.where((s) => s.hasCoordinates).toList();

    // 카테고리 변경 시 맵 이동 처리
    if (_lastFittedCategory != _selectedCategory) {
      _lastFittedCategory = _selectedCategory;

      // 이동할 스테이션 결정 (검색에서 선택한 스테이션 우선, 없으면 첫 번째 스테이션)
      RadioStation? targetStation;
      int zoomLevel = 12;

      if (_targetStationOnCategoryEnter != null && _targetStationOnCategoryEnter!.hasCoordinates) {
        // 검색 드롭다운에서 스테이션을 선택한 경우 - 해당 스테이션으로 이동
        targetStation = _targetStationOnCategoryEnter;
        zoomLevel = 15; // 상세 줌 레벨
        debugPrint('검색에서 선택한 스테이션으로 이동: ${targetStation!.stationName}');
      } else if (stationsWithCoords.isNotEmpty) {
        // 단순 카테고리 선택 - 첫 번째 스테이션으로 이동
        targetStation = stationsWithCoords.first;
        zoomLevel = 12; // 구/시 레벨
        debugPrint('첫 번째 스테이션으로 이동: ${targetStation.stationName}');
      }

      _initialMapStation = targetStation;
      _initialMapZoomLevel = zoomLevel;
      _targetStationOnCategoryEnter = null; // 사용 후 초기화

      // 맵이 준비된 후 해당 위치로 이동 (백업용 - initialStation이 적용되지 않을 경우)
      // 웹에서는 맵 초기화에 약 800ms 소요 (300ms + 500ms), 모바일에서는 더 빠름
      if (targetStation != null && targetStation.hasCoordinates) {
        final stationToMove = targetStation; // 클로저 캡처용 로컬 변수
        final levelToUse = zoomLevel;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Future.delayed(const Duration(milliseconds: 1000), () {
            if (!mounted) return;
            final mapState = _detailMapKey.currentState;
            if (mapState != null) {
              debugPrint('백업 moveToStation 호출: ${stationToMove.stationName}');
              if (levelToUse == 15) {
                mapState.moveToStation(stationToMove);
              } else {
                mapState.moveToStationWithLevel(stationToMove, levelToUse);
              }
            }
          });
        });
      }
    }

    // 화면 너비에 따라 레이아웃 결정 (모바일 웹에서도 모바일 레이아웃 적용)
    final screenWidth = MediaQuery.of(context).size.width;
    final isWideScreen = screenWidth >= 700;

    if (kIsWeb && isWideScreen) {
      return LayoutBuilder(
        builder: (context, constraints) {
          // 화면 너비에 따라 리스트 너비 조정 (최소 320, 최대 400)
          final listWidth = (constraints.maxWidth * 0.3).clamp(320.0, 400.0);

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
                    // 지도 영역 (왼쪽) - Expanded로 남은 공간 모두 사용
                    Expanded(
                      child: Stack(
                        children: [
                          platform_map.PlatformMapWidget(
                            key: _detailMapKey,
                            stations: stationsWithCoords,
                            onMarkerTap: _showStationDetail,
                            initialStation: _initialMapStation,
                            initialZoomLevel: _initialMapZoomLevel,
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
                                    // 카테고리 목록으로 돌아갈 때 초기 위치 정보 초기화
                                    _lastFittedCategory = null;
                                    _initialMapStation = null;
                                    _initialMapZoomLevel = null;
                                  });
                                },
                              ),
                            ),
                          ),
                          // 내 위치 버튼
                          Positioned(
                            right: 16,
                            bottom: 16,
                            child: _buildMyLocationButton(_detailMapKey),
                          ),
                        ],
                      ),
                    ),
                    // 상세 리스트 (오른쪽) - 반응형 너비
                    SizedBox(
                      width: listWidth,
                      child: _buildDetailList(provider, categoryStations, isWebLayout: true),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      );
    }

    // 모바일: 맵 고정 크기 + 드래그 가능한 리스트 오버레이
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenHeight = constraints.maxHeight;
        final listHeight = screenHeight * _listHeightRatio;

        return Stack(
          children: [
            // 맵 - 고정 크기로 전체 공간 차지 (리사이즈 없음)
            Positioned.fill(
              child: Column(
                children: [
                  // 상단 SafeArea + 뒤로가기 + 카테고리명
                  Container(
                    color: Colors.white,
                    child: SafeArea(
                      bottom: false,
                      child: _buildDetailHeader(provider),
                    ),
                  ),
                  // 지도 - 남은 공간 전체 사용
                  Expanded(
                    child: Container(
                      color: const Color(0xFFF0F0F0),
                      child: Stack(
                        children: [
                          // 지도 - 선택된 카테고리의 마커만 표시 (초기 위치 설정)
                          platform_map.PlatformMapWidget(
                            key: _detailMapKey,
                            stations: stationsWithCoords,
                            onMarkerTap: _showStationDetail,
                            initialStation: _initialMapStation,
                            initialZoomLevel: _initialMapZoomLevel,
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
                                    // 카테고리 목록으로 돌아갈 때 초기 위치 정보 초기화
                                    _lastFittedCategory = null;
                                    _initialMapStation = null;
                                    _initialMapZoomLevel = null;
                                  });
                                },
                              ),
                            ),
                          ),
                          // 내 위치 버튼
                          Positioned(
                            right: 16,
                            bottom: _listHeightRatio * MediaQuery.of(context).size.height + 16,
                            child: _buildMyLocationButton(_detailMapKey),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 리스트 오버레이 - 드래그로 높이 조절
            // 맵 드래그 비활성화 API 사용 (웹에서 HtmlElementView 이벤트 문제 해결)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: listHeight,
              child: Listener(
                behavior: HitTestBehavior.opaque, // 맵으로 이벤트 전달 방지
                onPointerDown: (_) {
                  // 리스트 터치 시 맵 드래그 비활성화
                  _detailMapKey.currentState?.setMapDraggable(false);
                },
                onPointerUp: (_) {
                  // 터치 종료 시 맵 드래그 활성화
                  _detailMapKey.currentState?.setMapDraggable(true);
                },
                onPointerCancel: (_) {
                  // 터치 취소 시 맵 드래그 활성화
                  _detailMapKey.currentState?.setMapDraggable(true);
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (details) {
                    setState(() {
                      _listHeightRatio = (_listHeightRatio - details.delta.dy / screenHeight)
                          .clamp(_minListRatio, _maxListRatio);
                    });
                  },
                  onVerticalDragEnd: (_) {
                    // 드래그 종료 시 맵 드래그 활성화
                    _detailMapKey.currentState?.setMapDraggable(true);
                  },
                  onHorizontalDragUpdate: (_) {}, // 수평 드래그도 소비
                  child: Container(
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
                        Center(
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 12),
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.grey[400],
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                        // 콘텐츠
                        Expanded(child: _buildDetailList(provider, categoryStations)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDetailHeader(StationProvider provider) {
    final categoryStations = provider.stationsByCategory[_selectedCategory] ?? [];

    // 검색 모드일 때 - 오버레이 드롭다운 위젯 사용
    if (_isSearchMode) {
      return _DetailSearchHeaderWidget(
        categoryStations: categoryStations,
        detailMapKey: _detailMapKey,
        onStationSelected: (station) {
          _showStationDetail(station);
        },
        onBackPressed: () {
          setState(() {
            _isSearchMode = false;
            _detailSearchQuery = '';
            _detailSearchController.clear();
          });
        },
      );
    }

    // 일반 모드
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              setState(() {
                _selectedCategory = null;
                _isSearchMode = false;
                _detailSearchQuery = '';
                // 카테고리 목록으로 돌아갈 때 초기 위치 정보 초기화
                _lastFittedCategory = null;
                _initialMapStation = null;
                _initialMapZoomLevel = null;
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
              setState(() {
                _isSearchMode = true;
              });
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
            : BorderRadius.zero, // 드래그 핸들에서 borderRadius 처리
        boxShadow: isWebLayout
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 10,
                  offset: const Offset(-2, 0),
                ),
              ]
            : null, // 모바일에서는 드래그 핸들에서 그림자 처리
      ),
      child: Column(
        children: [
          // 핸들 - 웹에서만 표시 (모바일에서는 _buildDraggableSheet에서 처리)
          if (isWebLayout)
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
                      final stations = provider.stationsByCategory[category] ?? [];
                      final count = stations.length;
                      final completedCount = stations.where((s) => s.isInspected).length;
                      final pendingCount = count - completedCount;
                      return _buildCategoryItem(
                        category,
                        count,
                        pendingCount: pendingCount,
                        completedCount: completedCount,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryItem(String category, int count, {int pendingCount = 0, int completedCount = 0}) {
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
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '$count개 장소',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey[600],
                        ),
                      ),
                      // 검사대기 건수 (파란색)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '대기:$pendingCount',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.blue[700],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      // 검사완료 건수 (빨간색)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '완료:$completedCount',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.red[700],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
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
    // 검색어 필터링 적용
    var filteredStations = stations;
    if (_detailSearchQuery.isNotEmpty) {
      final query = _detailSearchQuery.toLowerCase();
      filteredStations = stations.where((s) {
        return s.displayName.toLowerCase().contains(query) ||
               s.address.toLowerCase().contains(query) ||
               (s.stationName.toLowerCase().contains(query));
      }).toList();
    }
    final sortedStations = _getSortedStations(filteredStations);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: isWebLayout
            ? BorderRadius.zero
            : BorderRadius.zero, // 드래그 핸들에서 borderRadius 처리
        boxShadow: isWebLayout
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.1),
                  blurRadius: 10,
                  offset: const Offset(-2, 0),
                ),
              ]
            : null, // 모바일에서는 드래그 핸들에서 그림자 처리
      ),
      child: Column(
        children: [
          // 핸들 - 웹에서만 표시 (모바일에서는 _buildDraggableSheet에서 처리)
          if (isWebLayout)
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

          // 정보 없는 장소 알림 (클릭 시 상세 목록 표시)
          if (!_isEditMode && sortedStations.any((s) => !s.hasCoordinates))
            GestureDetector(
              onTap: () => _showNoLocationStationsList(sortedStations.where((s) => !s.hasCoordinates).toList()),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.location_off, color: Colors.orange[700], size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '정보가 없거나 위치가 변경된 장소 ${sortedStations.where((s) => !s.hasCoordinates).length}',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.orange[800],
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '상세보기',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.orange[800],
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right, color: Colors.orange[700], size: 18),
                  ],
                ),
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
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
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
          // 맵 중앙을 해당 스테이션 위치로 이동
          if (station.hasCoordinates) {
            _detailMapKey.currentState?.moveToStation(station);
          }
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
            // 썸네일 또는 아이콘 (검사 상태에 따라 색상 변경)
            Stack(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: station.isInspected
                        ? Colors.green.shade50
                        : (station.hasCoordinates ? Colors.blue.shade50 : Colors.grey.shade100),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    station.hasCoordinates ? Icons.location_on : Icons.location_off,
                    color: station.isInspected
                        ? Colors.green
                        : (station.hasCoordinates ? Colors.blue : Colors.grey),
                    size: 28,
                  ),
                ),
                // 검사 완료 표시
                if (station.isInspected)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.green,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Icon(Icons.check, color: Colors.white, size: 12),
                    ),
                  ),
              ],
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
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      // 검사 상태 태그
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: station.isInspected ? Colors.green.shade50 : Colors.orange.shade50,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          station.isInspected ? '검사완료' : '검사대기',
                          style: TextStyle(
                            fontSize: 10,
                            color: station.isInspected ? Colors.green[700] : Colors.orange[700],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
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
    final provider = context.read<StationProvider>();
    final stationCount = provider.stationsByCategory[category]?.length ?? 0;

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('카테고리 삭제'),
        content: Text('$category의 모든 데이터($stationCount개)를 삭제하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              _deleteCategoryWithProgress(category, stationCount);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
  }

  /// 카테고리 삭제 시 진행률 표시 (import 스타일 - 전체 화면 오버레이)
  Future<void> _deleteCategoryWithProgress(String category, int totalCount) async {
    // 진행률 상태 관리
    final progressNotifier = ValueNotifier<double>(0.0);
    final statusNotifier = ValueNotifier<String>('$category 삭제 준비 중...');

    // 전체 화면 진행률 오버레이 표시
    final overlayEntry = OverlayEntry(
      builder: (context) => Material(
        color: Colors.white,
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 진행률 바
                  ValueListenableBuilder<double>(
                    valueListenable: progressNotifier,
                    builder: (context, progress, _) {
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: progress > 0 ? progress : null,
                          minHeight: 12,
                          backgroundColor: Colors.grey[200],
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.red),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  // 진행률 퍼센트
                  ValueListenableBuilder<double>(
                    valueListenable: progressNotifier,
                    builder: (context, progress, _) {
                      return Text(
                        '${(progress * 100).toInt()}%',
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.red,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  // 상태 메시지
                  ValueListenableBuilder<String>(
                    valueListenable: statusNotifier,
                    builder: (context, status, _) {
                      return Text(
                        status,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                        ),
                        textAlign: TextAlign.center,
                      );
                    },
                  ),
                  // 처리 항목 수
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ValueListenableBuilder<double>(
                      valueListenable: progressNotifier,
                      builder: (context, progress, _) {
                        final processed = (progress * totalCount).toInt();
                        return Text(
                          '$processed / $totalCount',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[500],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // 오버레이 삽입
    Overlay.of(context).insert(overlayEntry);

    try {
      // 삭제 실행 (진행률 콜백 전달)
      statusNotifier.value = '$category 삭제 중...';
      await context.read<StationProvider>().deleteCategoryData(
        category,
        onProgress: (progress) {
          progressNotifier.value = progress;
        },
      );

      progressNotifier.value = 1.0;
      statusNotifier.value = '삭제 완료!';

      // 잠시 대기 후 오버레이 제거
      await Future.delayed(const Duration(milliseconds: 500));

      if (!mounted) return;

      // 오버레이 제거
      overlayEntry.remove();
      progressNotifier.dispose();
      statusNotifier.dispose();

      // 완료 메시지
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$category가 삭제되었습니다.'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;

      // 오버레이 제거
      overlayEntry.remove();
      progressNotifier.dispose();
      statusNotifier.dispose();

      // 오류 메시지
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('삭제 실패: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
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

  /// 위치 정보 없는 스테이션 목록 다이얼로그
  void _showNoLocationStationsList(List<RadioStation> stations) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 드래그 핸들
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 헤더
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.location_off,
                      size: 32,
                      color: Colors.orange.shade600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '위치 정보 없는 장소',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '총 ${stations.length}개의 장소',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey[600],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey[50],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '아래 장소들은 주소 정보가 정확하지 않거나, 위치가 변경되었거나, 아직 좌표가 등록되지 않아 지도에 표시되지 않습니다.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                        height: 1.4,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: Colors.grey[200]),
            // 스테이션 목록
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: stations.length,
                separatorBuilder: (_, __) => Divider(height: 1, indent: 16, endIndent: 16, color: Colors.grey[200]),
                itemBuilder: (context, index) {
                  final station = stations[index];
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                    leading: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.orange.shade700,
                          ),
                        ),
                      ),
                    ),
                    title: Text(
                      station.displayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 4),
                        Text(
                          station.address,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (station.licenseNumber.isNotEmpty && station.licenseNumber != '-') ...[
                          const SizedBox(height: 2),
                          Text(
                            '허가번호: ${station.licenseNumber}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey[500],
                            ),
                          ),
                        ],
                      ],
                    ),
                    trailing: Icon(
                      Icons.chevron_right,
                      color: Colors.grey[400],
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      _showStationDetail(station);
                    },
                  );
                },
              ),
            ),
            // 하단 닫기 버튼
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE53935),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: const Text(
                      '닫기',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 내 위치 버튼 빌드
  Widget _buildMyLocationButton(GlobalKey<platform_map.PlatformMapWidgetState> mapKey) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            // GPS 오류 콜백 설정
            mapKey.currentState?.onGeolocationError = (error) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(error),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            };
            // 현재 위치로 이동
            mapKey.currentState?.moveToCurrentLocation();
          },
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Icon(
              Icons.my_location,
              color: Colors.black87,
              size: 24,
            ),
          ),
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

  /// 로그아웃 처리 (팝업 없이 바로 로그아웃)
  Future<void> _handleLogout() async {
    final authService = context.read<AuthService>();
    final stationProvider = context.read<StationProvider>();

    // StationProvider 상태 초기화 (중복 로드 방지)
    stationProvider.resetForLogout();

    await authService.signOut();

    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    }
  }

  // 테마 색상 (로그인 페이지와 동일)
  static const Color _dialogPrimaryColor = Color(0xFFE53935);

  /// Excel 내보내기 - 저장/공유 선택 팝업 (일관된 디자인)
  Future<void> _exportCategoryToExcel(String category) async {
    final provider = context.read<StationProvider>();
    final hasOriginalExcel = provider.hasOriginalExcel(category);

    // 원본 Excel이 있는 경우 형식 선택 다이얼로그 먼저 표시
    bool useOriginalFormat = false;
    if (hasOriginalExcel) {
      final formatChoice = await showDialog<String>(
        context: context,
        builder: (context) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Container(
            padding: const EdgeInsets.all(24),
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 헤더 아이콘
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.description_outlined,
                    color: Colors.blue,
                    size: 28,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  '내보내기 형식 선택',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '원본 파일의 서식을 유지하거나\n새 서식으로 내보낼 수 있습니다.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 24),
                // 원본 서식 유지 버튼
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.pop(context, 'original'),
                    icon: const Icon(Icons.auto_awesome, size: 18),
                    label: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('원본 서식 유지', style: TextStyle(fontWeight: FontWeight.w600)),
                        Text('(수검여부/특이사항 컬럼만 추가)', style: TextStyle(fontSize: 11)),
                      ],
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // 새 서식 버튼
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context, 'new'),
                    icon: const Icon(Icons.table_chart_outlined, size: 18),
                    label: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('새 서식으로 내보내기'),
                        Text('(전체 컬럼 재구성)', style: TextStyle(fontSize: 11)),
                      ],
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      side: BorderSide(color: Colors.grey[300]!),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      foregroundColor: Colors.grey[700],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                // 취소 버튼
                TextButton(
                  onPressed: () => Navigator.pop(context, 'cancel'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.grey[600],
                  ),
                  child: const Text('취소'),
                ),
              ],
            ),
          ),
        ),
      );

      if (formatChoice == null || formatChoice == 'cancel') return;
      if (!mounted) return;
      useOriginalFormat = (formatChoice == 'original');
    }

    // 저장/공유 선택 다이얼로그 표시
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          padding: const EdgeInsets.all(24),
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 헤더 아이콘
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: _dialogPrimaryColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.file_download_outlined,
                  color: _dialogPrimaryColor,
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Excel 내보내기',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '파일을 어떻게 처리하시겠습니까?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 24),
              // 버튼들
              Row(
                children: [
                  // 기기에 저장 버튼
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.pop(context, 'save'),
                      icon: const Icon(Icons.save_alt, size: 18),
                      label: const Text('기기에 저장'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(color: Colors.grey[300]!),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        foregroundColor: Colors.grey[700],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 외부로 공유 버튼
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => Navigator.pop(context, 'share'),
                      icon: const Icon(Icons.share, size: 18),
                      label: const Text('공유'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: _dialogPrimaryColor,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // 취소 버튼
              TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.grey[600],
                ),
                child: const Text('취소'),
              ),
            ],
          ),
        ),
      ),
    );

    if (choice == null || choice == 'cancel') return;
    if (!mounted) return;

    // 로딩 표시 (일관된 디자인)
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: _dialogPrimaryColor),
              const SizedBox(height: 20),
              const Text(
                'Excel 파일 생성 중...',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    try {
      // saveOnly: 'save' 선택 시 저장만, 'share' 선택 시 공유 다이얼로그 표시
      final saveOnly = (choice == 'save');

      // 원본 서식 유지 또는 새 서식 내보내기
      final String? filePath;
      if (useOriginalFormat) {
        filePath = await provider.exportCategoryWithOriginalFormat(category, saveOnly: saveOnly);
      } else {
        filePath = await provider.exportCategoryToExcel(category, saveOnly: saveOnly);
      }

      if (!mounted) return;
      Navigator.pop(context); // 로딩 다이얼로그 닫기

      if (filePath != null) {
        if (choice == 'save') {
          // 기기에 저장 완료 다이얼로그 표시 (일관된 디자인)
          if (mounted) {
            showDialog(
              context: context,
              builder: (context) => Dialog(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                child: Container(
                  padding: const EdgeInsets.all(24),
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 성공 아이콘
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check_circle_outline,
                          color: Colors.green,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        '저장 완료',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '$category 검사 결과가\n저장되었습니다.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey[600],
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey[100],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.folder_outlined, size: 20, color: Colors.grey[600]),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                filePath!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey[700],
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () => Navigator.pop(context),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            backgroundColor: _dialogPrimaryColor,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: const Text(
                            '확인',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }
        }
        // share 선택 시 이미 exportCategoryToExcel에서 공유 다이얼로그가 표시됨
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // 로딩 다이얼로그 닫기

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Excel 내보내기 실패: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
}

/// 환영 헤더 위젯 (검색창 대신 환영 문구와 로그아웃 버튼 표시)
class _WelcomeHeaderWidget extends StatefulWidget {
  final VoidCallback onLogout;
  final VoidCallback? onHome;

  const _WelcomeHeaderWidget({
    required this.onLogout,
    this.onHome,
  });

  @override
  State<_WelcomeHeaderWidget> createState() => _WelcomeHeaderWidgetState();
}

class _WelcomeHeaderWidgetState extends State<_WelcomeHeaderWidget> {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
      child: Consumer<AuthService>(
        builder: (context, authService, _) {
          final userName = authService.userName;
          final displayName = userName != null && userName.isNotEmpty
              ? userName
              : (authService.userEmail?.split('@').first ?? '사용자');
          final remainingMinutes = authService.remainingSessionMinutes;
          final hours = remainingMinutes ~/ 60;
          final minutes = remainingMinutes % 60;
          final timeText = hours > 0 ? '$hours시간 $minutes분' : '$minutes분';

          return Row(
            children: [
              // 뒤로가기 버튼 (홈으로)
              if (widget.onHome != null) ...[
                IconButton(
                  onPressed: widget.onHome,
                  icon: const Icon(Icons.arrow_back, size: 22, color: Colors.black87),
                  tooltip: '홈으로',
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(),
                ),
                const SizedBox(width: 8),
              ],
              // 환영 문구 + 남은 시간
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '$displayName님, 어서오세요.',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Icon(
                          Icons.timer_outlined,
                          size: 13,
                          color: remainingMinutes <= 30 ? Colors.orange : Colors.grey[500],
                        ),
                        const SizedBox(width: 3),
                        Text(
                          timeText,
                          style: TextStyle(
                            fontSize: 11,
                            color: remainingMinutes <= 30 ? Colors.orange : Colors.grey[600],
                          ),
                        ),
                        const SizedBox(width: 6),
                        // 세션 연장 버튼
                        GestureDetector(
                          onTap: () {
                            authService.extendSession();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('세션이 2시간 연장되었습니다.'),
                                duration: Duration(seconds: 2),
                                backgroundColor: Colors.green,
                              ),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.blue.shade50,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.blue.shade200),
                            ),
                            child: Text(
                              '연장',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.blue[700],
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 로그아웃 버튼
              TextButton.icon(
                onPressed: widget.onLogout,
                icon: const Icon(Icons.logout, size: 16, color: Colors.red),
                label: const Text('로그아웃', style: TextStyle(color: Colors.red, fontSize: 12)),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 검색바 위젯 (별도 StatefulWidget으로 분리하여 맵 리빌드 방지)
/// 드롭다운은 오버레이로 표시하여 맵 사이즈에 영향 없음
class _SearchBarWidget extends StatefulWidget {
  final List<RadioStation> stations;
  final GlobalKey<platform_map.PlatformMapWidgetState>? mapKey;
  final Function(RadioStation station) onStationSelected;
  /// 카테고리 선택 콜백 - 선택한 스테이션도 함께 전달하여 해당 위치로 이동
  final Function(String? category, RadioStation? targetStation) onCategorySelected;

  const _SearchBarWidget({
    required this.stations,
    this.mapKey,
    required this.onStationSelected,
    required this.onCategorySelected,
  });

  @override
  State<_SearchBarWidget> createState() => _SearchBarWidgetState();
}

class _SearchBarWidgetState extends State<_SearchBarWidget> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  bool _showSearchSuggestions = false;
  String _searchQuery = '';

  @override
  void dispose() {
    _removeOverlay();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _updateOverlay() {
    _removeOverlay();

    final query = _searchQuery.toLowerCase();
    final suggestions = query.isEmpty
        ? <RadioStation>[]
        : widget.stations.where((station) {
            return station.stationName.toLowerCase().contains(query) ||
                station.address.toLowerCase().contains(query) ||
                (station.callSign?.toLowerCase().contains(query) ?? false) ||
                station.licenseNumber.toLowerCase().contains(query);
          }).take(8).toList();

    if (!_showSearchSuggestions || suggestions.isEmpty) {
      return;
    }

    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        width: MediaQuery.of(context).size.width - 24, // margin 12 * 2
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 48), // 검색바 높이만큼 아래로
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 250),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: suggestions.length,
                itemBuilder: (context, index) {
                  final station = suggestions[index];
                  return InkWell(
                    onTap: () {
                      _searchController.text = station.stationName;
                      setState(() {
                        _searchQuery = station.stationName;
                        _showSearchSuggestions = false;
                      });
                      _removeOverlay();
                      _searchFocusNode.unfocus();

                      // 맵 중앙을 해당 스테이션 위치로 이동
                      if (station.hasCoordinates) {
                        widget.mapKey?.currentState?.moveToStation(station);
                      }

                      // 해당 스테이션의 카테고리로 이동 (선택한 스테이션 정보도 함께 전달)
                      if (station.categoryName != null) {
                        widget.onCategorySelected(station.categoryName, station);
                      }

                      widget.onStationSelected(station);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          Icon(
                            station.isInspected ? Icons.check_circle : Icons.radio_button_unchecked,
                            size: 18,
                            color: station.isInspected ? Colors.red : Colors.blue,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  station.stationName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                    fontSize: 14,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  station.address,
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 12,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          if (station.categoryName != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.grey[200],
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                station.categoryName!,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey[700],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  @override
  Widget build(BuildContext context) {
    // 검색바만 반환 (고정 높이) - 드롭다운은 오버레이로 별도 표시
    return CompositedTransformTarget(
      link: _layerLink,
      child: Container(
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
          focusNode: _searchFocusNode,
          onChanged: (value) {
            setState(() {
              _searchQuery = value;
              _showSearchSuggestions = value.isNotEmpty;
            });
            _updateOverlay();
          },
          onTap: () {
            if (_searchController.text.isNotEmpty) {
              setState(() {
                _showSearchSuggestions = true;
              });
              _updateOverlay();
            }
          },
          decoration: InputDecoration(
            hintText: '주소, 국소명 검색',
            hintStyle: TextStyle(color: Colors.grey[500], fontSize: 15),
            prefixIcon: Icon(Icons.search, color: Colors.grey[600]),
            suffixIcon: _searchController.text.isNotEmpty
                ? IconButton(
                    icon: Icon(Icons.clear, color: Colors.grey[600]),
                    onPressed: () {
                      _searchController.clear();
                      setState(() {
                        _searchQuery = '';
                        _showSearchSuggestions = false;
                      });
                      _removeOverlay();
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
      ),
    );
  }
}

/// 상세 페이지 검색 헤더 위젯 (오버레이 드롭다운으로 맵 영향 방지)
class _DetailSearchHeaderWidget extends StatefulWidget {
  final List<RadioStation> categoryStations;
  final GlobalKey<platform_map.PlatformMapWidgetState>? detailMapKey;
  final Function(RadioStation station) onStationSelected;
  final VoidCallback onBackPressed;

  const _DetailSearchHeaderWidget({
    required this.categoryStations,
    this.detailMapKey,
    required this.onStationSelected,
    required this.onBackPressed,
  });

  @override
  State<_DetailSearchHeaderWidget> createState() => _DetailSearchHeaderWidgetState();
}

class _DetailSearchHeaderWidgetState extends State<_DetailSearchHeaderWidget> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  String _searchQuery = '';

  @override
  void dispose() {
    _removeOverlay();
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _updateOverlay() {
    _removeOverlay();

    final query = _searchQuery.toLowerCase();
    final suggestions = query.isEmpty
        ? <RadioStation>[]
        : widget.categoryStations.where((station) {
            return station.stationName.toLowerCase().contains(query) ||
                station.address.toLowerCase().contains(query) ||
                (station.callSign?.toLowerCase().contains(query) ?? false);
          }).take(8).toList();

    if (suggestions.isEmpty) {
      return;
    }

    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        width: MediaQuery.of(context).size.width - 16, // margin 8 * 2
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 48),
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              constraints: const BoxConstraints(maxHeight: 200),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: suggestions.length,
                itemBuilder: (context, index) {
                  final station = suggestions[index];
                  return InkWell(
                    onTap: () {
                      _searchController.text = station.stationName;
                      setState(() {
                        _searchQuery = station.stationName;
                      });
                      _removeOverlay();
                      _searchFocusNode.unfocus();

                      // 해당 스테이션으로 맵 중앙을 이동
                      if (station.hasCoordinates) {
                        widget.detailMapKey?.currentState?.moveToStation(station);
                      }
                      widget.onStationSelected(station);
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      child: Row(
                        children: [
                          Icon(
                            station.isInspected ? Icons.check_circle : Icons.radio_button_unchecked,
                            size: 16,
                            color: station.isInspected ? Colors.red : Colors.blue,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  station.stationName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w500,
                                    fontSize: 13,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  station.address,
                                  style: TextStyle(
                                    color: Colors.grey[600],
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () {
                _removeOverlay();
                widget.onBackPressed();
              },
            ),
            Expanded(
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                autofocus: true,
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value;
                  });
                  _updateOverlay();
                },
                onTap: () {
                  if (_searchController.text.isNotEmpty) {
                    _updateOverlay();
                  }
                },
                decoration: InputDecoration(
                  hintText: '국소명, 주소 검색',
                  hintStyle: TextStyle(color: Colors.grey[500], fontSize: 15),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                ),
              ),
            ),
            if (_searchController.text.isNotEmpty)
              IconButton(
                icon: Icon(Icons.clear, color: Colors.grey[600]),
                onPressed: () {
                  _searchController.clear();
                  setState(() {
                    _searchQuery = '';
                  });
                  _removeOverlay();
                },
              ),
          ],
        ),
      ),
    );
  }
}
