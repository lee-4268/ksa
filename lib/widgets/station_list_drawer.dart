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
              child: Row(
                children: [
                  _buildFilterChip('전체', 'all'),
                  const SizedBox(width: 8),
                  _buildFilterChip('검사 대기', 'pending'),
                  const SizedBox(width: 8),
                  _buildFilterChip('검사 완료', 'completed'),
                ],
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
                final completed = provider.stations.where((s) => s.isInspected).length;
                final pending = total - completed;

                return Container(
                  padding: const EdgeInsets.all(16),
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
                      _buildStatItem('완료', completed, Colors.green),
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

  Widget _buildFilterChip(String label, String value) {
    final isSelected = _filterStatus == value;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (selected) {
        setState(() {
          _filterStatus = value;
        });
      },
      selectedColor: Theme.of(context).colorScheme.primaryContainer,
    );
  }

  List<RadioStation> _filterStations(List<RadioStation> stations) {
    return stations.where((station) {
      // 상태 필터
      if (_filterStatus == 'pending' && station.isInspected) return false;
      if (_filterStatus == 'completed' && !station.isInspected) return false;

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

  Widget _buildStationCard(BuildContext context, RadioStation station) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor:
              station.isInspected ? Colors.green : Colors.orange,
          child: Icon(
            station.isInspected ? Icons.check : Icons.pending,
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
            Text(
              station.licenseNumber,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
            ),
            Text(
              station.address,
              style: TextStyle(color: Colors.grey[600], fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        trailing: Icon(
          station.hasCoordinates ? Icons.location_on : Icons.location_off,
          color: station.hasCoordinates ? Colors.green : Colors.grey,
        ),
        onTap: () {
          Navigator.pop(context);
          context.read<StationProvider>().selectStation(station);
          // TODO: 지도에서 해당 마커로 이동
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
