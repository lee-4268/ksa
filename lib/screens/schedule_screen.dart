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

class _ScheduleScreenState extends State<ScheduleScreen> {
  // 테마 색상
  static const Color _primaryColor = Color(0xFFE53935);
  static const Color _blueAccent = Color(0xFF4A90D9);
  static const Color _greenColor = Color(0xFF43A047);
  static const Color _orangeColor = Color(0xFFFF9800);

  // 달력 관련 상태
  CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  @override
  void initState() {
    super.initState();
    _selectedDay = DateTime.now();
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
                // 통계 대시보드
                _buildStatsDashboard(provider),
                const SizedBox(height: 16),
                // 카테고리별 진도율
                _buildCategoryProgress(provider),
                const SizedBox(height: 16),
                // 달력
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

  /// 통계 대시보드
  Widget _buildStatsDashboard(StationProvider provider) {
    final stations = provider.stations;
    final total = stations.length;
    final inspected = stations.where((s) => s.isInspected).length;
    final pending = total - inspected;
    final progressRate = total > 0 ? (inspected / total * 100) : 0.0;

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
                      child: CircularProgressIndicator(
                        value: progressRate / 100,
                        strokeWidth: 10,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          progressRate >= 80
                              ? _greenColor
                              : progressRate >= 50
                                  ? _orangeColor
                                  : _primaryColor,
                        ),
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

  /// 카테고리별 진도율
  Widget _buildCategoryProgress(StationProvider provider) {
    final categories = provider.categories;
    if (categories.isEmpty) {
      return const SizedBox.shrink();
    }

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
              Icon(Icons.folder_outlined, color: _orangeColor, size: 22),
              SizedBox(width: 8),
              Text(
                '카테고리별 진도율',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...categories.map((category) {
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
                      Text(
                        '$inspected / $total (${(rate * 100).toStringAsFixed(0)}%)',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: rate,
                      minHeight: 8,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        rate >= 0.8
                            ? _greenColor
                            : rate >= 0.5
                                ? _orangeColor
                                : _primaryColor,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  /// 달력 위젯
  Widget _buildCalendar(StationProvider provider) {
    // 검사 완료된 날짜별 무선국 수 계산
    final inspectionDates = _getInspectionDateMap(provider.stations);

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
                        '검사완료',
                        style: TextStyle(
                          fontSize: 11,
                          color: _greenColor.withValues(alpha: 0.8),
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
              return inspectionDates[dateKey] ?? [];
            },
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
              markerDecoration: const BoxDecoration(
                color: _greenColor,
                shape: BoxShape.circle,
              ),
              markerSize: 6,
              markersMaxCount: 3,
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

  /// 검사 날짜별 무선국 맵 생성
  Map<DateTime, List<RadioStation>> _getInspectionDateMap(List<RadioStation> stations) {
    final map = <DateTime, List<RadioStation>>{};
    for (final station in stations) {
      if (station.isInspected && station.inspectionDate != null) {
        final dateKey = DateTime(
          station.inspectionDate!.year,
          station.inspectionDate!.month,
          station.inspectionDate!.day,
        );
        map.putIfAbsent(dateKey, () => []);
        map[dateKey]!.add(station);
      }
    }
    return map;
  }

  /// 선택된 날짜의 검사 목록
  Widget _buildSelectedDayInspections(StationProvider provider) {
    if (_selectedDay == null) return const SizedBox.shrink();

    final dateKey = DateTime(_selectedDay!.year, _selectedDay!.month, _selectedDay!.day);
    final inspectionMap = _getInspectionDateMap(provider.stations);
    final dayStations = inspectionMap[dateKey] ?? [];

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
                  '$dateString 검사 완료',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: dayStations.isEmpty
                      ? Colors.grey.shade100
                      : _greenColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${dayStations.length}건',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: dayStations.isEmpty ? Colors.grey : _greenColor,
                  ),
                ),
              ),
            ],
          ),
          if (dayStations.isEmpty) ...[
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  Icon(Icons.event_busy, size: 48, color: Colors.grey.shade300),
                  const SizedBox(height: 8),
                  Text(
                    '검사 완료된 무선국이 없습니다',
                    style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ] else ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 8),
            ...dayStations.map((station) => _buildStationItem(station)),
          ],
        ],
      ),
    );
  }

  Widget _buildStationItem(RadioStation station) {
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
              color: _greenColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.check_circle, color: _greenColor, size: 20),
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
                color: _blueAccent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                station.categoryName!,
                style: TextStyle(
                  fontSize: 10,
                  color: _blueAccent.withValues(alpha: 0.8),
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
