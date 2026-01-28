import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:table_calendar/table_calendar.dart';
import '../models/radio_station.dart';
import '../providers/station_provider.dart';

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
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: _buildAppBar(),
      body: Consumer<StationProvider>(
        builder: (context, provider, _) {
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 통계 대시보드 (예상 완료일 포함)
                _buildStatsDashboard(provider),
                const SizedBox(height: 16),
                // 탭 (카테고리별 진도율 / 날짜별 통계)
                _buildTabSection(provider),
                const SizedBox(height: 16),
                // 달력 (예정일 + 완료일)
                _buildCalendar(provider),
                const SizedBox(height: 16),
                // 선택된 날짜의 검사 목록
                _buildSelectedDayInspections(provider),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
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
      title: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.calendar_month, color: _primaryColor, size: 24),
          SizedBox(width: 8),
          Text(
            '일정 및 통계',
            style: TextStyle(
              color: Colors.black87,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      centerTitle: true,
    );
  }

  /// 통계 대시보드 (예상 완료일 포함)
  Widget _buildStatsDashboard(StationProvider provider) {
    final stations = provider.stations;
    final total = stations.length;
    final inspected = stations.where((s) => s.isInspected).length;
    final pending = total - inspected;
    final progressRate = total > 0 ? (inspected / total * 100) : 0.0;

    // 예상 완료일 계산
    final estimatedDate = provider.getEstimatedCompletionDate();
    final dailyRate = provider.getDailyInspectionRate();

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
          const Row(
            children: [
              Icon(Icons.analytics_outlined, color: _blueAccent, size: 22),
              SizedBox(width: 8),
              Text(
                '전체 진도율',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          // 진도율 원형 그래프
          Row(
            children: [
              // 원형 진도율
              SizedBox(
                width: 100,
                height: 100,
                child: Stack(
                  children: [
                    SizedBox(
                      width: 100,
                      height: 100,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: progressRate / 100),
                        duration: const Duration(milliseconds: 800),
                        curve: Curves.easeOutCubic,
                        builder: (context, value, _) {
                          return CircularProgressIndicator(
                            value: value,
                            strokeWidth: 10,
                            backgroundColor: Colors.grey.shade200,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              progressRate >= 80
                                  ? _greenColor
                                  : progressRate >= 50
                                      ? _orangeColor
                                      : _primaryColor,
                            ),
                          );
                        },
                      ),
                    ),
                    Center(
                      child: Text(
                        '${progressRate.toStringAsFixed(1)}%',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 24),
              // 통계 수치
              Expanded(
                child: Column(
                  children: [
                    _buildStatRow(
                      icon: Icons.cell_tower,
                      label: '전체 무선국',
                      value: '$total',
                      color: _blueAccent,
                    ),
                    const SizedBox(height: 12),
                    _buildStatRow(
                      icon: Icons.check_circle,
                      label: '검사 완료',
                      value: '$inspected',
                      color: _greenColor,
                    ),
                    const SizedBox(height: 12),
                    _buildStatRow(
                      icon: Icons.pending,
                      label: '검사 대기',
                      value: '$pending',
                      color: _orangeColor,
                    ),
                  ],
                ),
              ),
            ],
          ),
          // 예상 완료일 섹션
          if (pending > 0) ...[
            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: _purpleColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.event_available, color: _purpleColor, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '예상 완료일',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        estimatedDate != null
                            ? '${estimatedDate.year}년 ${estimatedDate.month}월 ${estimatedDate.day}일'
                            : '데이터 부족',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: _blueAccent.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.speed, color: _blueAccent, size: 16),
                      const SizedBox(width: 4),
                      Text(
                        '일 ${dailyRate.toStringAsFixed(1)}건',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _blueAccent,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatRow({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: color, size: 16),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
            ),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }

  /// 탭 섹션 (카테고리별 진도율 / 날짜별 통계)
  Widget _buildTabSection(StationProvider provider) {
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
            height: _calculateTabHeight(provider),
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildCategoryProgress(provider),
                _buildDateStats(provider),
              ],
            ),
          ),
        ],
      ),
    );
  }

  double _calculateTabHeight(StationProvider provider) {
    final categories = provider.categories;
    // 기본 높이 + 카테고리 수에 따른 높이
    final categoryHeight = categories.length * 60.0;
    return categoryHeight.clamp(200.0, 400.0);
  }

  /// 카테고리별 진도율
  Widget _buildCategoryProgress(StationProvider provider) {
    final categories = provider.categories;
    if (categories.isEmpty) {
      return const Center(
        child: Text('데이터가 없습니다', style: TextStyle(color: Colors.grey)),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      itemCount: categories.length,
      itemBuilder: (context, index) {
        final category = categories[index];
        final categoryStations = provider.stationsByCategory[category] ?? [];
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
  Widget _buildDateStats(StationProvider provider) {
    final categoryDateStats = provider.getCategoryDateStats();

    if (categoryDateStats.isEmpty) {
      return const Center(
        child: Text('완료된 검사가 없습니다', style: TextStyle(color: Colors.grey)),
      );
    }

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
        final categoryStations = provider.stationsByCategory[category] ?? [];
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
              // 카테고리 헤더 (탭하면 펼치기/접기)
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
  Widget _buildCalendar(StationProvider provider) {
    final inspectionDates = provider.inspectionDateMap;
    final scheduledDates = provider.scheduledDateMap;

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
  Widget _buildSelectedDayInspections(StationProvider provider) {
    if (_selectedDay == null) return const SizedBox.shrink();

    final dateKey = DateTime(_selectedDay!.year, _selectedDay!.month, _selectedDay!.day);
    final inspectionMap = provider.inspectionDateMap;
    final scheduledMap = provider.scheduledDateMap;

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
