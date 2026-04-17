import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:table_calendar/table_calendar.dart';
import '../models/radio_station.dart';
import '../providers/station_provider.dart';
import '../services/division_data_service.dart';
import '../services/auth_service.dart';
import '../services/kca_export_service.dart';
import '../widgets/user_profile_button.dart';

// 플랫폼별 Excel 저장 (웹: 다운로드, 모바일: 파일 저장 + 공유)
import '../services/excel_export_stub.dart'
    if (dart.library.io) '../services/excel_export_mobile.dart'
    if (dart.library.html) '../services/excel_export_web.dart' as platform_export;

/// 일정 관리 및 통계 대시보드 화면
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen>
    with SingleTickerProviderStateMixin {
  // 테마 색상
  static const Color _primaryColor = Color(0xFFE53935);
  static const Color _blueAccent = Color(0xFF4A90D9);
  static const Color _greenColor = Color(0xFF43A047);
  static const Color _orangeColor = Color(0xFFFF9800);
  static const Color _purpleColor = Color(0xFF7B1FA2);

  // 9개 본부 목록 (id, name)
  static const List<Map<String, String>> _divisions = [
    {'id': 'gangnam', 'name': '강남본부'},
    {'id': 'gangbuk', 'name': '강북본부'},
    {'id': 'incheon', 'name': '인천본부'},
    {'id': 'gyeonggi', 'name': '경기본부'},
    {'id': 'gangwon', 'name': '강원본부'},
    {'id': 'chungcheong', 'name': '충청본부'},
    {'id': 'gyeongbuk', 'name': '경북본부'},
    {'id': 'gyeongnam', 'name': '경남본부'},
    {'id': 'seobu', 'name': '서부본부'},
  ];

  // 선택된 본부
  String? _selectedDivisionId;
  String _selectedDivisionName = '강남본부';

  // 달력 관련 상태
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  // 탭 컨트롤러
  late TabController _tabController;

  // 카테고리 확장 상태
  final Map<String, bool> _categoryExpanded = {};

  @override
  void initState() {
    super.initState();
    _selectedDay = DateTime.now();
    _tabController = TabController(length: 2, vsync: this);

    // 본부 데이터 로드 및 초기 선택 설정
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initSelectedDivision();
      _loadDivisionData();
    });
  }

  /// 사용자 본부에 따라 초기 선택 설정
  void _initSelectedDivision() {
    final authService = context.read<AuthService>();
    final userDivisionId = authService.currentDivisionId;

    // 사용자의 본부가 9개 본부 중 하나인지 확인
    final matchingDivision = _divisions.firstWhere(
      (d) => d['id'] == userDivisionId,
      orElse: () => _divisions.first, // 본사 등 9개 본부에 없으면 첫 번째(강남본부) 선택
    );

    setState(() {
      _selectedDivisionId = matchingDivision['id'];
      _selectedDivisionName = matchingDivision['name']!;
    });
  }

  void _loadDivisionData() {
    final divisionService = context.read<DivisionDataService>();

    if (_selectedDivisionId != null) {
      divisionService.setDivision(
        _selectedDivisionId!,
        _selectedDivisionName,
      );
      divisionService.loadFromCloud();
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 선택된 본부 사용 (드롭다운에서 선택)
    final divisionId = _selectedDivisionId;
    final divisionName = _selectedDivisionName;

    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: _buildAppBar(),
      body: Consumer2<StationProvider, DivisionDataService>(
        builder: (context, stationProvider, divisionService, _) {
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 본부 전체 진행률 + 이번주 진행률
                _buildDivisionStatsDashboard(stationProvider, divisionId, divisionName),
                const SizedBox(height: 16),
                // 팀별 진행률 (DivisionDataService 사용 - Excel import 데이터)
                _buildTeamProgressSection(divisionService),
                const SizedBox(height: 16),
                // 탭 (카테고리별 진도율 / 날짜별 통계)
                _buildTabSection(stationProvider, divisionId),
                const SizedBox(height: 16),
                // 달력 (예정일 + 완료일)
                _buildCalendar(stationProvider, divisionId),
                const SizedBox(height: 16),
                // 선택된 날짜의 검사 목록
                _buildSelectedDayInspections(stationProvider, divisionId),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 본부 전체 진행률 대시보드
  Widget _buildDivisionStatsDashboard(StationProvider provider, String? divisionId, String divisionName) {
    // 본부 필터링된 스테이션
    final divisionStations = provider.getStationsByDivision(divisionId);
    final total = divisionStations.length;
    final inspected = divisionStations.where((s) => s.isInspected).length;
    final progressRate = total > 0 ? inspected / total : 0.0;

    // 이번 주 통계 계산
    final now = DateTime.now();
    final weekStart = now.subtract(Duration(days: now.weekday - 1));
    final weekEnd = weekStart.add(const Duration(days: 6));

    final scheduledThisWeek = divisionStations.where((s) {
      if (s.scheduledDate == null) return false;
      return s.scheduledDate!.isAfter(weekStart.subtract(const Duration(days: 1))) &&
             s.scheduledDate!.isBefore(weekEnd.add(const Duration(days: 1)));
    }).toList();

    final completedThisWeek = scheduledThisWeek.where((s) => s.isInspected).length;
    final weeklyProgressRate = scheduledThisWeek.isNotEmpty
        ? completedThisWeek / scheduledThisWeek.length
        : 0.0;
    final weekNumber = ((now.difference(DateTime(now.year, 1, 1)).inDays +
        DateTime(now.year, 1, 1).weekday - 1) / 7).ceil();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 본부 전체 진행률
          Row(
            children: [
              const Icon(Icons.business, color: _blueAccent, size: 22),
              const SizedBox(width: 8),
              Text(
                '$divisionName 전체 진행률',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 진행률 바
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progressRate),
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) {
                return LinearProgressIndicator(
                  value: value,
                  minHeight: 14,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    progressRate >= 0.8 ? _greenColor : _blueAccent,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '$inspected/$total',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 14,
                ),
              ),
              Text(
                '${(progressRate * 100).toStringAsFixed(1)}%',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ],
          ),
          const Divider(height: 32),
          // 이번 주 진행률
          Row(
            children: [
              const Icon(Icons.date_range, color: _greenColor, size: 20),
              const SizedBox(width: 8),
              Text(
                '이번주 진행률 (${DateTime.now().month}월 $weekNumber주차)',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: weeklyProgressRate),
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) {
                return LinearProgressIndicator(
                  value: value,
                  minHeight: 10,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    weeklyProgressRate >= 0.8 ? _greenColor : _orangeColor,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$completedThisWeek/${scheduledThisWeek.length} (${(weeklyProgressRate * 100).toStringAsFixed(0)}%)',
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  /// 팀별 진행률 섹션
  Widget _buildTeamProgressSection(DivisionDataService service) {
    final teamStats = service.teamStats;

    if (teamStats.isEmpty) {
      return const SizedBox.shrink();
    }

    // 진행률 기준 정렬
    final sortedTeams = teamStats.entries.toList()
      ..sort((a, b) => b.value.progressRate.compareTo(a.value.progressRate));

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.groups, color: _purpleColor, size: 22),
              SizedBox(width: 8),
              Text(
                '팀별 진행률',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...sortedTeams.map((entry) => _buildTeamProgressRow(entry.key, entry.value)),
        ],
      ),
    );
  }

  Widget _buildTeamProgressRow(String teamName, TeamStats stats) {
    Color progressColor;
    if (stats.progressRate >= 0.8) {
      progressColor = _greenColor;
    } else if (stats.progressRate >= 0.5) {
      progressColor = _orangeColor;
    } else {
      progressColor = _primaryColor;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                teamName,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (stats.total == 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    '대상 없음',
                    style: TextStyle(
                      color: Colors.grey,
                      fontSize: 11,
                    ),
                  ),
                )
              else
                Text(
                  '${stats.inspected}/${stats.total} (${(stats.progressRate * 100).toStringAsFixed(0)}%)',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                  ),
                ),
            ],
          ),
          if (stats.total > 0) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: stats.progressRate),
                duration: const Duration(milliseconds: 800),
                curve: Curves.easeOutCubic,
                builder: (context, value, _) {
                  return LinearProgressIndicator(
                    value: value,
                    minHeight: 8,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.white,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.black87),
        onPressed: () => Navigator.pop(context),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.calendar_month, color: _primaryColor, size: 24),
          const SizedBox(width: 8),
          // 본부 선택 드롭다운
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _selectedDivisionId,
                icon: const Icon(Icons.arrow_drop_down, color: _primaryColor, size: 20),
                isDense: true,
                dropdownColor: Colors.white,

                borderRadius: BorderRadius.circular(12),
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 13,
                ),
                items: _divisions.map((division) {
                  return DropdownMenuItem<String>(
                    value: division['id'],
                    child: Text(division['name']!),
                  );
                }).toList(),
                onChanged: (String? newDivisionId) {
                  if (newDivisionId != null) {
                    final selectedDivision = _divisions.firstWhere(
                      (d) => d['id'] == newDivisionId,
                    );
                    setState(() {
                      _selectedDivisionId = newDivisionId;
                      _selectedDivisionName = selectedDivision['name']!;
                    });
                    // 본부 변경 시 DivisionDataService도 업데이트
                    final divisionService = context.read<DivisionDataService>();
                    divisionService.setDivision(newDivisionId, selectedDivision['name']!);
                    divisionService.loadFromCloud();
                  }
                },
              ),
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            '일정 및 통계',
            style: TextStyle(
              color: Colors.black87,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      centerTitle: true,
      actions: [
        // Manager 이상만 KCA 호환 Excel Export 가능
        if (context.watch<AuthService>().isAdmin)
          IconButton(
            tooltip: 'KCA Excel 내보내기',
            icon: const Icon(Icons.file_download_outlined, color: Colors.black87),
            onPressed: _showKcaExportDialog,
          ),
        UserProfileButton(
          onLogout: () {
            context.read<AuthService>().signOut();
            Navigator.of(context).popUntil((route) => route.isFirst);
          },
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  /// KCA playground Import 호환 Excel 내보내기 다이얼로그
  Future<void> _showKcaExportDialog() async {
    final auth = context.read<AuthService>();

    // 지역본부 소속이면 해당 본부가 기본값 (변경 가능)
    final userShortName = auth.currentDivisionShortName;
    var selectedDivisionId = _selectedDivisionId ?? _divisions.first['id']!;
    if (userShortName != null) {
      final matching = _divisions.firstWhere(
        (d) => (d['name'] ?? '').startsWith(userShortName),
        orElse: () => _divisions.first,
      );
      selectedDivisionId = matching['id']!;
    }

    var selectedYear = DateTime.now().year;
    final years = List<int>.generate(5, (i) => DateTime.now().year - i);

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              title: Row(
                children: const [
                  Icon(Icons.file_download_outlined, color: _primaryColor, size: 22),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'KCA Playground용 Excel 내보내기',
                      style: TextStyle(fontSize: 16),
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '수검대상 / 수검일정 / 수검결과 3개 시트가 포함됩니다.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  const SizedBox(height: 16),
                  // 연도
                  DropdownButtonFormField<int>(
                    initialValue: selectedYear,
                    decoration: const InputDecoration(
                      labelText: '연도',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: years
                        .map((y) => DropdownMenuItem(value: y, child: Text('$y')))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setDialogState(() => selectedYear = v);
                    },
                  ),
                  const SizedBox(height: 12),
                  // 본부
                  DropdownButtonFormField<String>(
                    initialValue: selectedDivisionId,
                    decoration: const InputDecoration(
                      labelText: '본부',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _divisions
                        .map((d) => DropdownMenuItem(
                              value: d['id'],
                              child: Text(d['name']!),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setDialogState(() => selectedDivisionId = v);
                    },
                  ),
                  if (userShortName != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      '자동 선택됨: $userShortName본부 (변경 가능)',
                      style: const TextStyle(fontSize: 11, color: _blueAccent),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('취소'),
                ),
                ElevatedButton.icon(
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('내보내기'),
                  onPressed: () {
                    Navigator.pop(dialogCtx);
                    final division = _divisions
                        .firstWhere((d) => d['id'] == selectedDivisionId);
                    _runKcaExport(
                      year: selectedYear,
                      divisionId: division['id']!,
                      divisionName: division['name']!,
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 실제 Export 실행 (로딩 표시 → Excel 생성 → 파일 저장)
  Future<void> _runKcaExport({
    required int year,
    required String divisionId,
    required String divisionName,
  }) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final auth = context.read<AuthService>();

    // 본부명 → short name (예: "경북본부" → "경북")
    final shortName = divisionName.replaceAll('본부', '');

    // 로딩 다이얼로그
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('Excel 생성 중...')),
          ],
        ),
      ),
    );

    try {
      final exporter = KcaExportService(authToken: auth.authToken);
      final bytes = await exporter.buildKcaImportExcel(
        year: year,
        divisionShortName: shortName,
      );

      final fileName = '수검데이터_${divisionName}_$year.xlsx';
      await platform_export.saveExcelFile(bytes, fileName, saveOnly: false);

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // 로딩 닫기
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text('내보내기 완료: $fileName'),
          backgroundColor: _greenColor,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // 로딩 닫기
      scaffoldMessenger.showSnackBar(
        SnackBar(
          content: Text('내보내기 실패: $e'),
          backgroundColor: _primaryColor,
        ),
      );
    }
  }

  /// 탭 섹션 (카테고리별 진도율 / 날짜별 통계)
  Widget _buildTabSection(StationProvider provider, String? divisionId) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // 탭 바
          Container(
            margin: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(10),
            ),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              labelColor: _primaryColor,
              unselectedLabelColor: Colors.grey.shade600,
              labelStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              tabs: const [
                Tab(text: '카테고리별 진도율'),
                Tab(text: '날짜별 완료 통계'),
              ],
            ),
          ),
          // 탭 콘텐츠
          SizedBox(
            height: _calculateTabHeight(provider, divisionId),
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildCategoryProgress(provider, divisionId),
                _buildDateStats(provider, divisionId),
              ],
            ),
          ),
        ],
      ),
    );
  }

  double _calculateTabHeight(StationProvider provider, String? divisionId) {
    final categories = provider.getCategoriesForDivision(divisionId);
    // 기본 높이 + 카테고리 수에 따른 높이
    final categoryHeight = categories.length * 60.0;
    return categoryHeight.clamp(200.0, 400.0);
  }

  /// 카테고리별 진도율
  Widget _buildCategoryProgress(StationProvider provider, String? divisionId) {
    final categories = provider.getCategoriesForDivision(divisionId);
    if (categories.isEmpty) {
      return const Center(
        child: Text('데이터가 없습니다', style: TextStyle(color: Colors.grey)),
      );
    }

    final stationsByCategory = provider.getStationsByCategoryForDivision(divisionId);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: categories.length,
      itemBuilder: (context, index) {
        final category = categories[index];
        final categoryStations = stationsByCategory[category] ?? [];
        final total = categoryStations.length;
        final inspected = categoryStations.where((s) => s.isInspected).length;
        final rate = total > 0 ? (inspected / total) : 0.0;

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      category,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        '$inspected / $total (${(rate * 100).toStringAsFixed(0)}%)',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 예정일 설정 버튼
                      GestureDetector(
                        onTap: () => _showScheduleDialog(context, provider, category),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: _blueAccent.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Icon(
                            Icons.event_note,
                            size: 16,
                            color: _blueAccent,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: rate),
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) {
                    return LinearProgressIndicator(
                      value: value,
                      minHeight: 8,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        rate >= 0.8
                            ? _greenColor
                            : rate >= 0.5
                                ? _orangeColor
                                : _primaryColor,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 날짜별 완료 통계
  Widget _buildDateStats(StationProvider provider, String? divisionId) {
    final categoryDateStats = provider.getCategoryDateStatsForDivision(divisionId);

    if (categoryDateStats.isEmpty) {
      return const Center(
        child: Text('완료된 검사가 없습니다', style: TextStyle(color: Colors.grey)),
      );
    }

    final stationsByCategory = provider.getStationsByCategoryForDivision(divisionId);

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: categoryDateStats.length,
      itemBuilder: (context, index) {
        final category = categoryDateStats.keys.elementAt(index);
        final dateStats = categoryDateStats[category]!;
        final isExpanded = _categoryExpanded[category] ?? false;

        // 날짜별 정렬 (최신순)
        final sortedDates = dateStats.keys.toList()
          ..sort((a, b) => b.compareTo(a));

        final totalCompleted = dateStats.values.fold(0, (sum, count) => sum + count);
        final categoryStations = stationsByCategory[category] ?? [];
        final totalInCategory = categoryStations.length;

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            children: [
              // 카테고리 헤더 (탭하면 펼치기/접기)`
              InkWell(
                onTap: () {
                  setState(() {
                    _categoryExpanded[category] = !isExpanded;
                  });
                },
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: _greenColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.folder_outlined, color: _greenColor, size: 16),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          category,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '$totalCompleted / $totalInCategory',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        isExpanded ? Icons.expand_less : Icons.expand_more,
                        color: Colors.grey.shade600,
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
              // 날짜별 상세 (펼쳐진 경우)
              if (isExpanded)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(10),
                      bottomRight: Radius.circular(10),
                    ),
                  ),
                  child: Column(
                    children: sortedDates.take(5).map((date) {
                      final count = dateStats[date]!;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          children: [
                            const SizedBox(width: 32),
                            Icon(Icons.check_circle, color: _greenColor, size: 14),
                            const SizedBox(width: 8),
                            Text(
                              '${date.month}월 ${date.day}일',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade700,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: _greenColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '$count건',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: _greenColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 예정일 설정 다이얼로그
  void _showScheduleDialog(BuildContext context, StationProvider provider, String category) {
    DateTime selectedDate = DateTime.now();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.event_note, color: _blueAccent, size: 24),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$category\n검사 예정일 설정',
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 300,
          height: 350,
          child: StatefulBuilder(
            builder: (context, setDialogState) {
              return TableCalendar(
                firstDay: DateTime.now(),
                lastDay: DateTime.now().add(const Duration(days: 365)),
                focusedDay: selectedDate,
                locale: 'ko_KR',
                selectedDayPredicate: (day) => isSameDay(selectedDate, day),
                onDaySelected: (selected, focused) {
                  setDialogState(() {
                    selectedDate = selected;
                  });
                },
                calendarStyle: CalendarStyle(
                  selectedDecoration: const BoxDecoration(
                    color: _blueAccent,
                    shape: BoxShape.circle,
                  ),
                  todayDecoration: BoxDecoration(
                    color: _blueAccent.withValues(alpha: 0.3),
                    shape: BoxShape.circle,
                  ),
                ),
                headerStyle: const HeaderStyle(
                  formatButtonVisible: false,
                  titleCentered: true,
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () async {
              final scaffoldMessenger = ScaffoldMessenger.of(context);
              Navigator.pop(context);
              await provider.setCategoryScheduledDate(category, selectedDate);
              if (mounted) {
                scaffoldMessenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      '$category 예정일이 ${selectedDate.month}월 ${selectedDate.day}일로 설정되었습니다',
                    ),
                    backgroundColor: _greenColor,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _blueAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text('설정'),
          ),
        ],
      ),
    );
  }

  /// 달력 위젯 (예정일 + 완료일)
  Widget _buildCalendar(StationProvider provider, String? divisionId) {
    final inspectionDates = provider.getInspectionDateMapForDivision(divisionId);
    final scheduledDates = provider.getScheduledDateMapForDivision(divisionId);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Row(
              children: [
                const Icon(Icons.calendar_today, color: _primaryColor, size: 22),
                const SizedBox(width: 8),
                const Text(
                  '검사 일정',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
                const Spacer(),
                // 범례
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _greenColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: _greenColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '완료',
                        style: TextStyle(
                          fontSize: 11,
                          color: _greenColor.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _blueAccent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          color: _blueAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '예정',
                        style: TextStyle(
                          fontSize: 11,
                          color: _blueAccent.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          TableCalendar<RadioStation>(
            firstDay: DateTime.utc(2020, 1, 1),
            lastDay: DateTime.utc(2030, 12, 31),
            focusedDay: _focusedDay,
            calendarFormat: _calendarFormat,
            locale: 'ko_KR',
            selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
            onDaySelected: (selectedDay, focusedDay) {
              setState(() {
                _selectedDay = selectedDay;
                _focusedDay = focusedDay;
              });
            },
            onFormatChanged: (format) {
              setState(() {
                _calendarFormat = format;
              });
            },
            onPageChanged: (focusedDay) {
              _focusedDay = focusedDay;
            },
            eventLoader: (day) {
              final dateKey = DateTime(day.year, day.month, day.day);
              final inspected = inspectionDates[dateKey] ?? [];
              final scheduled = scheduledDates[dateKey] ?? [];
              return [...inspected, ...scheduled];
            },
            calendarBuilders: CalendarBuilders(
              markerBuilder: (context, date, events) {
                final dateKey = DateTime(date.year, date.month, date.day);
                final inspectedCount = (inspectionDates[dateKey] ?? []).length;
                final scheduledCount = (scheduledDates[dateKey] ?? []).length;

                if (inspectedCount == 0 && scheduledCount == 0) {
                  return null;
                }

                return Positioned(
                  bottom: 1,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (inspectedCount > 0)
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: const BoxDecoration(
                            color: _greenColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                      if (scheduledCount > 0)
                        Container(
                          width: 6,
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 1),
                          decoration: const BoxDecoration(
                            color: _blueAccent,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
            calendarStyle: CalendarStyle(
              todayDecoration: BoxDecoration(
                color: _blueAccent.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
              todayTextStyle: const TextStyle(
                color: Colors.black87,
                fontWeight: FontWeight.bold,
              ),
              selectedDecoration: const BoxDecoration(
                color: _primaryColor,
                shape: BoxShape.circle,
              ),
              selectedTextStyle: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
              outsideDaysVisible: false,
            ),
            headerStyle: HeaderStyle(
              formatButtonVisible: true,
              titleCentered: true,
              formatButtonDecoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(8),
              ),
              formatButtonTextStyle: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade700,
              ),
              titleTextStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
              leftChevronIcon: Icon(Icons.chevron_left, color: Colors.grey.shade700),
              rightChevronIcon: Icon(Icons.chevron_right, color: Colors.grey.shade700),
            ),
            daysOfWeekStyle: DaysOfWeekStyle(
              weekdayStyle: TextStyle(color: Colors.grey.shade700, fontSize: 12),
              weekendStyle: TextStyle(color: _primaryColor.withValues(alpha: 0.7), fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// 선택된 날짜의 검사 목록
  Widget _buildSelectedDayInspections(StationProvider provider, String? divisionId) {
    if (_selectedDay == null) return const SizedBox.shrink();

    final dateKey = DateTime(_selectedDay!.year, _selectedDay!.month, _selectedDay!.day);
    final inspectionMap = provider.getInspectionDateMapForDivision(divisionId);
    final scheduledMap = provider.getScheduledDateMapForDivision(divisionId);

    final inspectedStations = inspectionMap[dateKey] ?? [];
    final scheduledStations = scheduledMap[dateKey] ?? [];

    final dateString = '${_selectedDay!.year}년 ${_selectedDay!.month}월 ${_selectedDay!.day}일';

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.list_alt, color: _blueAccent, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  dateString,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 검사 완료 섹션
          if (inspectedStations.isNotEmpty) ...[
            _buildSectionHeader('검사 완료', inspectedStations.length, _greenColor),
            const SizedBox(height: 8),
            ...inspectedStations.map((station) => _buildStationItem(station, isCompleted: true)),
          ],
          // 검사 예정 섹션
          if (scheduledStations.isNotEmpty) ...[
            if (inspectedStations.isNotEmpty) const SizedBox(height: 16),
            _buildSectionHeader('검사 예정', scheduledStations.length, _blueAccent),
            const SizedBox(height: 8),
            ...scheduledStations.map((station) => _buildStationItem(station, isCompleted: false)),
          ],
          // 데이터 없음
          if (inspectedStations.isEmpty && scheduledStations.isEmpty) ...[
            const SizedBox(height: 12),
            Center(
              child: Column(
                children: [
                  Icon(Icons.event_busy, size: 48, color: Colors.grey.shade300),
                  const SizedBox(height: 8),
                  Text(
                    '일정이 없습니다',
                    style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, int count, Color color) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$count건',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStationItem(RadioStation station, {required bool isCompleted}) {
    final color = isCompleted ? _greenColor : _blueAccent;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              isCompleted ? Icons.check_circle : Icons.schedule,
              color: color,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  station.displayName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  station.address,
                  style: TextStyle(
                    color: Colors.grey.shade600,
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _orangeColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                station.categoryName!,
                style: TextStyle(
                  fontSize: 10,
                  color: _orangeColor.withValues(alpha: 0.8),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}
