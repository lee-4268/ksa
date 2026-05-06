import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/radio_station.dart';
import '../providers/station_provider.dart';

class StationListDrawer extends StatefulWidget {
  const StationListDrawer({super.key});

  @override
  State<StationListDrawer> createState() => _StationListDrawerState();
}

class _StationListDrawerState extends State<StationListDrawer> {
  String _searchQuery = '';
  String _filterStatus = 'all'; // all, pending, completed

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: MediaQuery.of(context).size.width * 0.85,
      child: SafeArea(
        child: Column(
          children: [
            // 헤더
            Container(
              padding: const EdgeInsets.all(16),
              color: Theme.of(context).colorScheme.inversePrimary,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '무선국 목록',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // 검색 필드
                  TextField(
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value;
                      });
                    },
                    decoration: InputDecoration(
                      hintText: '국소명, 허가번호, 주소 검색...',
                      prefixIcon: const Icon(Icons.search),
                      filled: true,
                      fillColor: Colors.white,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // 필터 버튼
            Padding(
              padding: const EdgeInsets.all(8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildFilterChip('전체', 'all'),
                    const SizedBox(width: 6),
                    _buildFilterChip('대기', 'pending', Colors.orange),
                    const SizedBox(width: 6),
                    _buildFilterChip('합격', 'passed', Colors.green),
                    const SizedBox(width: 6),
                    _buildFilterChip('불합격', 'failed', Colors.red),
                  ],
                ),
              ),
            ),

            // 목록
            Expanded(
              child: Consumer<StationProvider>(
                builder: (context, provider, child) {
                  final filteredStations = _filterStations(provider.stations);

                  if (filteredStations.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.inbox,
                            size: 64,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '무선국 데이터가 없습니다.',
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: () {
                              Navigator.pop(context);
                              provider.importFromExcel();
                            },
                            icon: const Icon(Icons.file_upload),
                            label: const Text('Excel 파일 가져오기'),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: filteredStations.length,
                    separatorBuilder: (context, index) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final station = filteredStations[index];
                      return _buildStationCard(context, station);
                    },
                  );
                },
              ),
            ),

            // 통계 정보
            Consumer<StationProvider>(
              builder: (context, provider, child) {
                final total = provider.stations.length;
                final pending = provider.stations.where((s) => s.inspectionStatus == InspectionStatus.pending).length;
                final passed = provider.stations.where((s) => s.inspectionStatus == InspectionStatus.passed).length;
                final failed = provider.stations.where((s) => s.inspectionStatus == InspectionStatus.failed).length;

                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    border: Border(
                      top: BorderSide(color: Colors.grey[300]!),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildStatItem('전체', total, Colors.blue),
                      _buildStatItem('대기', pending, Colors.orange),
                      _buildStatItem('합격', passed, Colors.green),
                      _buildStatItem('불합격', failed, Colors.red),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterChip(String label, String value, [Color? color]) {
    final isSelected = _filterStatus == value;
    return FilterChip(
      label: Text(
        label,
        style: TextStyle(
          color: isSelected ? Colors.white : (color ?? Colors.grey[700]),
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      selected: isSelected,
      onSelected: (selected) {
        setState(() {
          _filterStatus = value;
        });
      },
      selectedColor: color ?? Theme.of(context).colorScheme.primary,
      backgroundColor: color?.withValues(alpha: 0.1),
      checkmarkColor: Colors.white,
    );
  }

  List<RadioStation> _filterStations(List<RadioStation> stations) {
    return stations.where((station) {
      // 상태 필터 (3가지 상태)
      if (_filterStatus == 'pending' && station.inspectionStatus != InspectionStatus.pending) return false;
      if (_filterStatus == 'passed' && station.inspectionStatus != InspectionStatus.passed) return false;
      if (_filterStatus == 'failed' && station.inspectionStatus != InspectionStatus.failed) return false;

      // 검색 필터
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        return station.stationName.toLowerCase().contains(query) ||
            station.licenseNumber.toLowerCase().contains(query) ||
            station.address.toLowerCase().contains(query);
      }

      return true;
    }).toList();
  }

  /// 검사 상태별 색상
  Color _getStatusColor(InspectionStatus status) {
    switch (status) {
      case InspectionStatus.pending:
        return Colors.orange;
      case InspectionStatus.passed:
        return Colors.green;
      case InspectionStatus.failed:
        return Colors.red;
      case InspectionStatus.inadequate:
        return Colors.purple;
    }
  }

  /// 검사 상태별 아이콘
  IconData _getStatusIcon(InspectionStatus status) {
    switch (status) {
      case InspectionStatus.pending:
        return Icons.hourglass_empty;
      case InspectionStatus.passed:
        return Icons.check_circle;
      case InspectionStatus.failed:
        return Icons.cancel;
      case InspectionStatus.inadequate:
        return Icons.warning_amber;
    }
  }

  Widget _buildStationCard(BuildContext context, RadioStation station) {
    final statusColor = _getStatusColor(station.inspectionStatus);
    final statusIcon = _getStatusIcon(station.inspectionStatus);

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: statusColor,
          child: Icon(
            statusIcon,
            color: Colors.white,
          ),
        ),
        title: Text(
          station.stationName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    station.inspectionStatusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    station.licenseNumber,
                    style: TextStyle(color: Colors.grey[600], fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              station.address,
              style: TextStyle(color: Colors.grey[600], fontSize: 11),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        trailing: Icon(
          station.hasCoordinates ? Icons.location_on : Icons.location_off,
          color: station.hasCoordinates ? Colors.green : Colors.grey,
          size: 20,
        ),
        onTap: () {
          Navigator.pop(context);
          context.read<StationProvider>().selectStation(station);
        },
      ),
    );
  }

  Widget _buildStatItem(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          count.toString(),
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: Colors.grey[600],
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
