import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../widgets/korea_map_widget.dart';
import '../services/inspection_service.dart';

/// 전국 현황 대시보드 화면
class DashboardScreen extends StatefulWidget {
  final bool showStats;
  final void Function(String region)? onRegionSelected;
  final void Function(String team)? onTeamSelected;
  final String? selectedRegion; // 외부에서 선택 상태 동기화
  final String? selectedTeam;   // 외부에서 선택 팀 동기화
  const DashboardScreen({
    super.key,
    this.showStats = true,
    this.onRegionSelected,
    this.onTeamSelected,
    this.selectedRegion,
    this.selectedTeam,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  static const Color _primaryColor = Color(0xFFE53935);
  static const Color _blueAccent = Color(0xFF4A90D9);
  String? _selectedRegion;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  final _inspSvc = InspectionService();
  final int _progressYear = DateTime.now().year;
  bool _progressLoaded = false; // didChangeDependencies 중복 호출 방지

  // 본부 선택 시 그 본부의 팀별 진행률
  List<Map<String, dynamic>> _teams = [];
  bool _teamsLoading = false;
  String? _teamsLoadedForRegion; // 어느 본부의 팀을 로드했는지

  // access담당 컬럼 값 → map key 매핑
  static const Map<String, String> _hdqtKeyMap = {
    '강남': 'gangnam', '강북': 'gangbuk', '인천': 'incheon',
    '경기': 'gyeonggi', '강원': 'gangwon', '충청': 'chungcheong',
    '경북': 'gyeongbuk', '경남': 'gyeongnam', '서부': 'seobu',
  };

  Map<String, RegionData> _regionData = {
    'gangnam':     RegionData(name: '강남본부',  shortName: '강남',  total: 0, completed: 0),
    'gangbuk':     RegionData(name: '강북본부',  shortName: '강북',  total: 0, completed: 0),
    'incheon':     RegionData(name: '인천본부',  shortName: '인천',  total: 0, completed: 0),
    'gyeonggi':    RegionData(name: '경기본부',  shortName: '경기',  total: 0, completed: 0),
    'gangwon':     RegionData(name: '강원본부',  shortName: '강원',  total: 0, completed: 0),
    'chungcheong': RegionData(name: '충청본부',  shortName: '충청',  total: 0, completed: 0),
    'gyeongbuk':   RegionData(name: '경북본부',  shortName: '경북',  total: 0, completed: 0),
    'gyeongnam':   RegionData(name: '경남본부',  shortName: '경남',  total: 0, completed: 0),
    'seobu':       RegionData(name: '서부본부',  shortName: '서부',  total: 0, completed: 0),
  };

  @override
  void initState() {
    super.initState();
    // 외부에서 초기 선택 본부가 주어진 경우 반영
    if (widget.selectedRegion != null && widget.selectedRegion!.isNotEmpty) {
      _selectedRegion = _shortNameToKey(widget.selectedRegion!);
    }
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _animationController.forward();
  }

  @override
  void didUpdateWidget(DashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedRegion != widget.selectedRegion) {
      final key = widget.selectedRegion != null && widget.selectedRegion!.isNotEmpty
          ? _shortNameToKey(widget.selectedRegion!)
          : null;
      if (key != _selectedRegion) {
        setState(() => _selectedRegion = key);
        if (key != null) _loadTeamsForRegion(widget.selectedRegion!);
        else setState(() { _teams = []; _teamsLoadedForRegion = null; });
      }
    }
  }

  Future<void> _loadTeamsForRegion(String regionShortName) async {
    if (_teamsLoadedForRegion == regionShortName) return;
    setState(() { _teamsLoading = true; _teamsLoadedForRegion = regionShortName; });
    try {
      final items = await _inspSvc.getProgressByTeam(_progressYear, regionShortName);
      if (!mounted) return;
      setState(() { _teams = items; _teamsLoading = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() { _teams = []; _teamsLoading = false; });
    }
  }

  /// shortName('강남') → map key('gangnam')
  static String? _shortNameToKey(String shortName) {
    const m = {
      '강남': 'gangnam', '강북': 'gangbuk', '인천': 'incheon',
      '경기': 'gyeonggi', '강원': 'gangwon', '충청': 'chungcheong',
      '경북': 'gyeongbuk', '경남': 'gyeongnam', '서부': 'seobu',
    };
    return m[shortName];
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final token = context.read<AuthService>().authToken;
    _inspSvc.setAuthToken(token);
    if (!_progressLoaded) {
      _progressLoaded = true;
      _loadProgress();
    }
  }

  Future<void> _loadProgress() async {
    try {
      final items = await _inspSvc.getProgress(_progressYear);
      if (!mounted) return;
      final updated = Map<String, RegionData>.from(_regionData);
      for (final item in items) {
        final hdqt = item['본부'] as String? ?? '';
        final key = _hdqtKeyMap[hdqt];
        if (key == null) continue;
        final existing = updated[key]!;
        updated[key] = RegionData(
          name: existing.name,
          shortName: existing.shortName,
          total: (item['total'] as num).toInt(),
          completed: (item['completed'] as num).toInt(),
        );
      }
      setState(() => _regionData = updated);
    } catch (_) {
      // 실패 시 기존 데이터 유지 (silent fail)
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  int get _totalStations =>
      _regionData.values.fold(0, (sum, r) => sum + r.total);
  int get _completedStations =>
      _regionData.values.fold(0, (sum, r) => sum + r.completed);
  double get _overallProgress =>
      _totalStations > 0 ? _completedStations / _totalStations : 0.0;

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    // 임베드 모드: 부모 SizedBox에서 높이 지정됨
    if (!widget.showStats) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 700;
          if (isWide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: _buildMapCard()),
                const SizedBox(width: 16),
                Expanded(flex: 2, child: _buildRegionDetailCard()),
              ],
            );
          } else {
            // 모바일: 세로 배치, 각각 고정 높이
            final halfH = constraints.maxHeight / 2 - 8;
            return Column(
              children: [
                SizedBox(height: halfH, child: _buildMapCard()),
                const SizedBox(height: 16),
                SizedBox(height: halfH, child: _buildRegionDetailCard()),
              ],
            );
          }
        },
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth > 800;
        if (isWide) {
          return _buildWideLayout();
        } else {
          return _buildNarrowLayout();
        }
      },
    );
  }

  /// 넓은 화면 (웹/태블릿)
  Widget _buildWideLayout() {

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          _buildStatsRow(),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              final mapHeight = constraints.maxWidth * 0.45;
              return SizedBox(
                height: mapHeight.clamp(350, 500),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: _buildMapCard()),
                    const SizedBox(width: 24),
                    Expanded(flex: 2, child: _buildRegionDetailCard()),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// 좁은 화면 (모바일)
  Widget _buildNarrowLayout() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // 상단 통계 카드 (세로 배치)
          if (widget.showStats) ...[
            _buildStatsColumn(),
            const SizedBox(height: 16),
          ],
          // 지도
          _buildMapCard(),
          const SizedBox(height: 16),
          // 지역 상세
          _buildRegionDetailCard(),
        ],
      ),
    );
  }

  Widget _buildStatsRow() {
    return Row(
      children: [
        Expanded(child: _buildStatCard(
          '전체 무선국',
          _totalStations.toString(),
          Icons.cell_tower,
          _blueAccent,
        )),
        const SizedBox(width: 16),
        Expanded(child: _buildStatCard(
          '수검 완료',
          _completedStations.toString(),
          Icons.check_circle,
          const Color(0xFF43A047),
        )),
        const SizedBox(width: 16),
        Expanded(child: _buildStatCard(
          '미수검',
          (_totalStations - _completedStations).toString(),
          Icons.pending_outlined,
          const Color(0xFFFFA726),
        )),
        const SizedBox(width: 16),
        Expanded(child: _buildStatCard(
          '전체 진행률',
          '${(_overallProgress * 100).toStringAsFixed(1)}%',
          Icons.trending_up,
          _primaryColor,
        )),
      ],
    );
  }

  Widget _buildStatsColumn() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _buildStatCard(
              '전체 무선국',
              _totalStations.toString(),
              Icons.cell_tower,
              _blueAccent,
              compact: true,
            )),
            const SizedBox(width: 12),
            Expanded(child: _buildStatCard(
              '수검 완료',
              _completedStations.toString(),
              Icons.check_circle,
              const Color(0xFF43A047),
              compact: true,
            )),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildStatCard(
              '미수검',
              (_totalStations - _completedStations).toString(),
              Icons.pending_outlined,
              const Color(0xFFFFA726),
              compact: true,
            )),
            const SizedBox(width: 12),
            Expanded(child: _buildStatCard(
              '전체 진행률',
              '${(_overallProgress * 100).toStringAsFixed(1)}%',
              Icons.trending_up,
              _primaryColor,
              compact: true,
            )),
          ],
        ),
      ],
    );
  }

  Widget _buildStatCard(
    String title,
    String value,
    IconData icon,
    Color color, {
    bool compact = false,
  }) {
    return Container(
      padding: EdgeInsets.all(compact ? 14 : 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(compact ? 6 : 8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color, size: compact ? 18 : 22),
              ),
              const Spacer(),
            ],
          ),
          SizedBox(height: compact ? 10 : 16),
          Text(
            value,
            style: TextStyle(
              fontSize: compact ? 22 : 28,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              color: Color(0xFF6B7280),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapCard() {
    return Container(
      constraints: const BoxConstraints(minHeight: 480),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.map_outlined, color: _blueAccent, size: 22),
              const SizedBox(width: 8),
              const Text(
                '전국 수검 현황',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const Spacer(),
              _buildLegend(),
            ],
          ),
          const SizedBox(height: 20),
          // 전체 진행률 바
          _buildOverallProgressBar(),
          const SizedBox(height: 20),
          // 지도
          SizedBox(
            height: 380,
            child: KoreaMapWidget(
              regionData: _regionData,
              selectedRegion: _selectedRegion,
              onRegionTap: (regionId, data) {
                setState(() {
                  _selectedRegion = regionId;
                });
                // 부모에게 본부 shortName 전달
                final shortName = _regionData[regionId]?.shortName ?? '';
                widget.onRegionSelected?.call(shortName);
                if (shortName.isNotEmpty) _loadTeamsForRegion(shortName);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegend() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildLegendItem('80%+', const Color(0xFF43A047)),
        const SizedBox(width: 12),
        _buildLegendItem('50-80%', const Color(0xFFFFA726)),
        const SizedBox(width: 12),
        _buildLegendItem('50%-', const Color(0xFFE53935)),
      ],
    );
  }

  Widget _buildLegendItem(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  Widget _buildOverallProgressBar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '전체 진행률',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade600,
              ),
            ),
            Text(
              '$_completedStations / $_totalStations (${(_overallProgress * 100).toStringAsFixed(1)}%)',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: _overallProgress,
            minHeight: 10,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation(
              _overallProgress >= 0.8
                  ? const Color(0xFF43A047)
                  : _overallProgress >= 0.5
                      ? const Color(0xFFFFA726)
                      : _primaryColor,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRegionDetailCard() {
    final selectedData = _selectedRegion != null
        ? _regionData[_selectedRegion]
        : null;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (selectedData != null)
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 18),
                  tooltip: '본부 목록',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () {
                    setState(() {
                      _selectedRegion = null;
                      _teams = [];
                      _teamsLoadedForRegion = null;
                    });
                    widget.onRegionSelected?.call('');
                    widget.onTeamSelected?.call('');
                  },
                )
              else
                const Icon(Icons.analytics_outlined, color: _blueAccent, size: 22),
              const SizedBox(width: 8),
              Text(
                selectedData != null ? '${selectedData.name} · 팀별' : '본부별 현황',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: SingleChildScrollView(
              child: selectedData != null
                  ? _buildTeamList(selectedData)
                  : _buildRegionList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTeamList(RegionData region) {
    if (_teamsLoading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_teams.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(Icons.groups_outlined, size: 36, color: Colors.grey.shade400),
            const SizedBox(height: 8),
            Text('이 본부의 팀 데이터가 없습니다',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (int i = 0; i < _teams.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _buildTeamListItem(_teams[i]),
        ],
      ],
    );
  }

  Widget _buildTeamListItem(Map<String, dynamic> team) {
    final name = (team['팀'] as String?) ?? '';
    final total = (team['total'] as num?)?.toInt() ?? 0;
    final completed = (team['completed'] as num?)?.toInt() ?? 0;
    final percent = (team['percent'] as num?)?.toDouble() ?? 0.0;
    final rate = total > 0 ? completed / total : 0.0;
    final isSelected = widget.selectedTeam == name;
    final shortName = name.replaceAll('품질개선팀', '');
    return InkWell(
      onTap: () => widget.onTeamSelected?.call(name),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F6FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? _blueAccent : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    shortName.isNotEmpty ? shortName : name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text('${percent.toStringAsFixed(1)}%',
                    style: TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold,
                        color: _getProgressColor(rate))),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: rate.clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: Colors.grey.shade200,
                valueColor: AlwaysStoppedAnimation(_getProgressColor(rate)),
              ),
            ),
            const SizedBox(height: 4),
            Text('$completed / $total',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }

  Widget _buildRegionList() {
    const _regionOrder = ['gangnam', 'gangbuk', 'incheon', 'gyeonggi', 'gyeongnam', 'gyeongbuk', 'seobu', 'chungcheong', 'gangwon'];
    final sortedRegions = _regionData.entries.toList()
      ..sort((a, b) {
        final ai = _regionOrder.indexOf(a.key);
        final bi = _regionOrder.indexOf(b.key);
        return (ai < 0 ? 99 : ai).compareTo(bi < 0 ? 99 : bi);
      });

    return Column(
      children: [
        for (int index = 0; index < sortedRegions.length; index++) ...[
          if (index > 0) const SizedBox(height: 8),
          _buildRegionListItem(sortedRegions[index], index),
        ],
      ],
    );
  }

  Widget _buildRegionListItem(MapEntry<String, RegionData> entry, int index) {
    final data = entry.value;

    return InkWell(
      onTap: () {
        setState(() => _selectedRegion = entry.key);
        widget.onRegionSelected?.call(data.shortName);
        _loadTeamsForRegion(data.shortName);
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F6FA),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _selectedRegion == entry.key
                ? _blueAccent
                : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          children: [
            // 순위
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: index < 3
                    ? _getProgressColor(data.progressRate).withValues(alpha: 0.1)
                    : Colors.grey.shade200,
                shape: BoxShape.circle,
              ),
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: index < 3
                      ? _getProgressColor(data.progressRate)
                      : Colors.grey.shade600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            // 지역명
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    data.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${data.completed}/${data.total}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            // 진행률
            SizedBox(
              width: 80,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${data.progressPercent}%',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: _getProgressColor(data.progressRate),
                    ),
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: data.progressRate,
                      minHeight: 4,
                      backgroundColor: Colors.grey.shade300,
                      valueColor: AlwaysStoppedAnimation(
                        _getProgressColor(data.progressRate),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getProgressColor(double rate) {
    if (rate >= 0.8) return const Color(0xFF43A047);
    if (rate >= 0.5) return const Color(0xFFFFA726);
    return const Color(0xFFE53935);
  }

}
