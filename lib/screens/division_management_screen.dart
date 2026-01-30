import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/division_data_service.dart';
import '../services/auth_service.dart';

/// 전체 대상 관리 화면 (본부 담당자 전용)
class DivisionManagementScreen extends StatefulWidget {
  const DivisionManagementScreen({super.key});

  @override
  State<DivisionManagementScreen> createState() => _DivisionManagementScreenState();
}

class _DivisionManagementScreenState extends State<DivisionManagementScreen>
    with SingleTickerProviderStateMixin {
  // 테마 색상
  static const Color _primaryColor = Color(0xFFE53935);
  static const Color _blueAccent = Color(0xFF4A90D9);
  static const Color _greenColor = Color(0xFF43A047);

  late TabController _tabController;
  String _searchQuery = '';
  String? _selectedTeamFilter;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    // 데이터 로드
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final authService = context.read<AuthService>();
      final divisionService = context.read<DivisionDataService>();

      // 본부 정보 설정
      if (authService.currentDivisionId != null) {
        divisionService.setDivision(
          authService.currentDivisionId!,
          authService.currentDivisionName ?? '본부',
        );
        divisionService.loadFromCloud();
      }
    });
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
      body: Consumer<DivisionDataService>(
        builder: (context, service, _) {
          if (service.isLoading) {
            return _buildLoadingOverlay(service);
          }

          return Column(
            children: [
              // 본부 통계 요약
              _buildStatsSummary(service),
              // 탭 바
              _buildTabBar(),
              // 탭 내용
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildTargetListTab(service),
                    _buildTeamAssignmentTab(service),
                  ],
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: _buildFAB(),
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
      title: Consumer<DivisionDataService>(
        builder: (context, service, _) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.business, color: _primaryColor, size: 24),
              const SizedBox(width: 8),
              Text(
                '${service.currentDivisionName ?? ''} 전체 대상 관리',
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          );
        },
      ),
      actions: [
        // Export 버튼
        Consumer<DivisionDataService>(
          builder: (context, service, _) {
            if (!service.hasOriginalExcel) return const SizedBox.shrink();
            return IconButton(
              icon: const Icon(Icons.file_download_outlined, color: _blueAccent),
              tooltip: '원본 서식으로 내보내기',
              onPressed: () => _exportToExcel(service),
            );
          },
        ),
        // Import 버튼
        IconButton(
          icon: const Icon(Icons.file_upload_outlined, color: _greenColor),
          tooltip: 'Excel 가져오기',
          onPressed: _importFromExcel,
        ),
      ],
    );
  }

  Widget _buildLoadingOverlay(DivisionDataService service) {
    return Container(
      color: Colors.white,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 200,
              child: LinearProgressIndicator(
                value: service.loadingProgress,
                backgroundColor: Colors.grey.shade200,
                valueColor: const AlwaysStoppedAnimation<Color>(_primaryColor),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              service.loadingStatus,
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 8),
            Text(
              '${(service.loadingProgress * 100).toInt()}%',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsSummary(DivisionDataService service) {
    final stats = service.stats;
    final weeklyStats = service.weeklyStats;

    return Container(
      margin: const EdgeInsets.all(16),
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
              const Icon(Icons.analytics_outlined, color: _blueAccent, size: 22),
              const SizedBox(width: 8),
              Text(
                '${service.currentDivisionName ?? ''} 전체 진행률',
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
            child: LinearProgressIndicator(
              value: stats.progressRate,
              minHeight: 12,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(
                stats.progressRate >= 0.8 ? _greenColor : _blueAccent,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${stats.inspected}/${stats.total}',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 14,
                ),
              ),
              Text(
                '${(stats.progressRate * 100).toStringAsFixed(1)}%',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
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
                '이번주 진행률 (${DateTime.now().month}월 ${weeklyStats.weekNumber}주차)',
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
            child: LinearProgressIndicator(
              value: weeklyStats.progressRate,
              minHeight: 8,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(
                weeklyStats.progressRate >= 0.8 ? _greenColor : Colors.orange,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${weeklyStats.completed}/${weeklyStats.scheduled} (${(weeklyStats.progressRate * 100).toStringAsFixed(0)}%)',
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: TabBar(
        controller: _tabController,
        labelColor: _primaryColor,
        unselectedLabelColor: Colors.grey,
        indicatorColor: _primaryColor,
        indicatorWeight: 3,
        tabs: const [
          Tab(text: '대상 목록'),
          Tab(text: '팀별 현황'),
        ],
      ),
    );
  }

  Widget _buildTargetListTab(DivisionDataService service) {
    final targets = service.targets;

    if (targets.isEmpty) {
      return _buildEmptyState();
    }

    // 검색 및 필터 적용
    var filteredTargets = targets.where((t) {
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        return t.stationName.toLowerCase().contains(query) ||
               t.address.toLowerCase().contains(query) ||
               t.licenseNumber.toLowerCase().contains(query);
      }
      return true;
    }).where((t) {
      if (_selectedTeamFilter != null) {
        return t.assignedTeamName == _selectedTeamFilter;
      }
      return true;
    }).toList();

    return Column(
      children: [
        // 검색 바
        _buildSearchBar(service),
        // 목록
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: filteredTargets.length,
            itemBuilder: (context, index) {
              return _buildTargetCard(filteredTargets[index], service);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSearchBar(DivisionDataService service) {
    final teams = service.targetsByTeam.keys.toList();

    return Container(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          // 검색 필드
          Expanded(
            flex: 3,
            child: TextField(
              decoration: InputDecoration(
                hintText: '국소명, 주소, 허가번호 검색...',
                prefixIcon: const Icon(Icons.search, size: 20),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
            ),
          ),
          const SizedBox(width: 12),
          // 팀 필터
          Expanded(
            flex: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String?>(
                  value: _selectedTeamFilter,
                  hint: const Text('팀 필터'),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: null, child: Text('전체')),
                    ...teams.map((team) => DropdownMenuItem(
                      value: team,
                      child: Text(team, overflow: TextOverflow.ellipsis),
                    )),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _selectedTeamFilter = value;
                    });
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTargetCard(DivisionInspectionTarget target, DivisionDataService service) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showTargetDetail(target, service),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 검사 상태 아이콘
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: target.isInspected
                          ? _greenColor.withValues(alpha: 0.1)
                          : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      target.isInspected ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: target.isInspected ? _greenColor : Colors.grey,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 국소명
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          target.stationName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          target.address,
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontSize: 13,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  // 팀 배지
                  if (target.assignedTeamName != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: _blueAccent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        target.assignedTeamName!,
                        style: const TextStyle(
                          color: _blueAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
              if (target.scheduledDate != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.event, size: 14, color: Colors.grey.shade500),
                    const SizedBox(width: 4),
                    Text(
                      '예정일: ${_formatDate(target.scheduledDate!)}',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTeamAssignmentTab(DivisionDataService service) {
    final teamStats = service.teamStats;

    if (teamStats.isEmpty) {
      return _buildEmptyState();
    }

    // 진행률 기준 정렬
    final sortedTeams = teamStats.entries.toList()
      ..sort((a, b) => b.value.progressRate.compareTo(a.value.progressRate));

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sortedTeams.length,
      itemBuilder: (context, index) {
        final entry = sortedTeams[index];
        return _buildTeamProgressCard(entry.key, entry.value);
      },
    );
  }

  Widget _buildTeamProgressCard(String teamName, TeamStats stats) {
    Color progressColor;
    if (stats.progressRate >= 0.8) {
      progressColor = _greenColor;
    } else if (stats.progressRate >= 0.5) {
      progressColor = Colors.orange;
    } else {
      progressColor = _primaryColor;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  teamName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
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
                    '${(stats.progressRate * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: progressColor,
                    ),
                  ),
              ],
            ),
            if (stats.total > 0) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: stats.progressRate,
                  minHeight: 8,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${stats.inspected}/${stats.total} 완료',
                style: TextStyle(
                  color: Colors.grey.shade600,
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_open_outlined, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            '등록된 대상이 없습니다',
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            icon: const Icon(Icons.file_upload_outlined),
            label: const Text('Excel 파일 가져오기'),
            onPressed: _importFromExcel,
          ),
        ],
      ),
    );
  }

  Widget _buildFAB() {
    return FloatingActionButton.extended(
      onPressed: _showQuickActions,
      backgroundColor: _primaryColor,
      icon: const Icon(Icons.add),
      label: const Text('빠른 작업'),
    );
  }

  void _showQuickActions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE8F5E9),
                    child: Icon(Icons.file_upload, color: _greenColor),
                  ),
                  title: const Text('Excel 가져오기'),
                  subtitle: const Text('수검 대상 일괄 등록'),
                  onTap: () {
                    Navigator.pop(context);
                    _importFromExcel();
                  },
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE3F2FD),
                    child: Icon(Icons.file_download, color: _blueAccent),
                  ),
                  title: const Text('Excel 내보내기'),
                  subtitle: const Text('원본 서식 유지 + 수정사항 반영'),
                  onTap: () {
                    Navigator.pop(context);
                    _exportToExcel(context.read<DivisionDataService>());
                  },
                ),
                ListTile(
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFFFF3E0),
                    child: Icon(Icons.group_add, color: Colors.orange),
                  ),
                  title: const Text('팀 일괄 배정'),
                  subtitle: const Text('대상을 팀별로 배정'),
                  onTap: () {
                    Navigator.pop(context);
                    _showBulkAssignDialog();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _importFromExcel() async {
    final service = context.read<DivisionDataService>();
    final success = await service.importFromExcel();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? '${service.targets.length}개 대상을 가져왔습니다.'
              : service.errorMessage ?? 'Import 실패'),
          backgroundColor: success ? _greenColor : Colors.red,
        ),
      );
    }
  }

  Future<void> _exportToExcel(DivisionDataService service) async {
    final filePath = await service.exportWithOriginalFormat();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(filePath != null
              ? 'Excel 파일이 저장되었습니다.'
              : service.errorMessage ?? 'Export 실패'),
          backgroundColor: filePath != null ? _greenColor : Colors.red,
        ),
      );
    }
  }

  void _showTargetDetail(DivisionInspectionTarget target, DivisionDataService service) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.7,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) {
            return _TargetDetailSheet(
              target: target,
              service: service,
              scrollController: scrollController,
            );
          },
        );
      },
    );
  }

  void _showBulkAssignDialog() {
    // TODO: 팀 일괄 배정 다이얼로그 구현
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('팀 일괄 배정 기능은 추후 구현됩니다.')),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}

/// 대상 상세 정보 시트
class _TargetDetailSheet extends StatefulWidget {
  final DivisionInspectionTarget target;
  final DivisionDataService service;
  final ScrollController scrollController;

  const _TargetDetailSheet({
    required this.target,
    required this.service,
    required this.scrollController,
  });

  @override
  State<_TargetDetailSheet> createState() => _TargetDetailSheetState();
}

class _TargetDetailSheetState extends State<_TargetDetailSheet> {
  static const Color _primaryColor = Color(0xFFE53935);
  static const Color _greenColor = Color(0xFF43A047);

  late TextEditingController _memoController;
  late bool _isInspected;
  DateTime? _scheduledDate;

  @override
  void initState() {
    super.initState();
    _memoController = TextEditingController(text: widget.target.memo ?? '');
    _isInspected = widget.target.isInspected;
    _scheduledDate = widget.target.scheduledDate;
  }

  @override
  void dispose() {
    _memoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      child: ListView(
        controller: widget.scrollController,
        children: [
          // 헤더
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _isInspected
                      ? _greenColor.withValues(alpha: 0.1)
                      : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _isInspected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: _isInspected ? _greenColor : Colors.grey,
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.target.stationName,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.target.licenseNumber,
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // 기본 정보
          _buildInfoSection('기본 정보', [
            _buildInfoRow('주소', widget.target.address),
            if (widget.target.callSign != null)
              _buildInfoRow('호출명칭', widget.target.callSign!),
            if (widget.target.installationType != null)
              _buildInfoRow('설치대', widget.target.installationType!),
            if (widget.target.gain != null)
              _buildInfoRow('이득', widget.target.gain!),
          ]),
          const SizedBox(height: 20),

          // 검사 상태
          _buildInfoSection('검사 정보', [
            // 검사 완료 토글
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('검사 완료'),
                Switch(
                  value: _isInspected,
                  activeColor: _greenColor,
                  onChanged: (value) {
                    setState(() {
                      _isInspected = value;
                    });
                  },
                ),
              ],
            ),
            const Divider(),
            // 예정일
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('검사 예정일'),
              subtitle: Text(
                _scheduledDate != null
                    ? '${_scheduledDate!.year}-${_scheduledDate!.month.toString().padLeft(2, '0')}-${_scheduledDate!.day.toString().padLeft(2, '0')}'
                    : '미지정',
              ),
              trailing: TextButton(
                onPressed: _selectScheduledDate,
                child: const Text('변경'),
              ),
            ),
          ]),
          const SizedBox(height: 20),

          // 메모
          const Text(
            '메모',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _memoController,
            maxLines: 4,
            decoration: InputDecoration(
              hintText: '특이사항을 입력하세요...',
              filled: true,
              fillColor: Colors.grey.shade50,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 24),

          // 저장 버튼
          ElevatedButton(
            onPressed: _saveChanges,
            style: ElevatedButton.styleFrom(
              backgroundColor: _primaryColor,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              '저장',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.grey.shade600,
                fontSize: 14,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _selectScheduledDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _scheduledDate ?? DateTime.now(),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (picked != null) {
      setState(() {
        _scheduledDate = picked;
      });
    }
  }

  void _saveChanges() {
    widget.service.updateTarget(
      widget.target.id,
      memo: _memoController.text.isNotEmpty ? _memoController.text : null,
      isInspected: _isInspected,
      inspectionDate: _isInspected ? DateTime.now() : null,
      scheduledDate: _scheduledDate,
    );

    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('저장되었습니다.'),
        backgroundColor: Color(0xFF43A047),
      ),
    );
  }
}
