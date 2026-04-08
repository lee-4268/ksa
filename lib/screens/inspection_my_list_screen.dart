import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/radio_station.dart';
import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../widgets/user_profile_button.dart';
import 'inspection_result_screen.dart';

// MapScreen과 동일한 조건부 import
import 'map_screen_web.dart' if (dart.library.io) 'map_screen_mobile.dart'
    as platform_map;

class InspectionMyListScreen extends StatefulWidget {
  const InspectionMyListScreen({super.key});

  @override
  State<InspectionMyListScreen> createState() => _InspectionMyListScreenState();
}

class _InspectionMyListScreenState extends State<InspectionMyListScreen> {
  final GlobalKey<platform_map.PlatformMapWidgetState> _mapKey =
      GlobalKey<platform_map.PlatformMapWidgetState>();

  late final InspectionService _svc;
  int _year = DateTime.now().year;

  List<Map<String, dynamic>> _assignedItems = [];
  bool _loadingInsp = false;
  String? _inspError;

  String _sortOrder = '최신순';

  String _selectedWeek = '';
  List<String> _weekOptions = [];

  // 드래그 (모바일)
  double _listHeightRatio = 0.40;
  static const double _minListRatio = 0.15;
  static const double _maxListRatio = 0.85;

  @override
  void initState() {
    super.initState();
    _svc = InspectionService()
      ..setAuthToken(context.read<AuthService>().authToken);
    _loadWeeks();
    _loadInspection();
  }

  Future<void> _loadWeeks() async {
    try {
      final weeks = await _svc.getMyListWeeks(_year);
      if (mounted) setState(() => _weekOptions = weeks);
    } catch (_) {}
  }

  Future<void> _loadInspection() async {
    setState(() { _loadingInsp = true; _inspError = null; });
    try {
      final items = await _svc.getMyList(_year, week: _selectedWeek);
      setState(() => _assignedItems = items);
    } catch (e) {
      setState(() => _inspError = e.toString());
    } finally {
      setState(() => _loadingInsp = false);
    }
  }

  // 지도 마커: inspection_targets의 위경도(Kakao 지오코딩 결과) 사용
  List<RadioStation> get _markerStations {
    final result = <RadioStation>[];
    for (final item in _assignedItems) {
      final ln  = (item['허가번호'] as String? ?? '').trim();
      final lat = (item['위도'] as num?)?.toDouble();
      final lng = (item['경도'] as num?)?.toDouble();
      if (lat == null || lng == null || lat == 0 || lng == 0) continue;
      final status = item['status'] as String? ?? '검사대기';
      result.add(RadioStation(
        id: ln,
        stationName: item['호출명칭'] as String? ?? ln,
        address: item['도로명주소'] as String?
            ?? item['설치장소'] as String?
            ?? item['t_설치장소'] as String? ?? '',
        latitude: lat,
        longitude: lng,
        licenseNumber: ln,
        inspectionStatus: status == '합격'
            ? InspectionStatus.passed
            : status == '불합격'
                ? InspectionStatus.failed
                : InspectionStatus.pending,
      ));
    }
    return result;
  }

  void _onMarkerTap(RadioStation station) {
    if (station.hasCoordinates) _mapKey.currentState?.moveToStation(station);
    final item = _assignedItems.firstWhere(
      (i) => (i['허가번호'] as String? ?? '').trim() == station.licenseNumber.trim(),
      orElse: () => {'허가번호': station.licenseNumber, '호출명칭': station.stationName},
    );
    _showInspectionSheet(item);
  }

  void _showInspectionSheet(Map<String, dynamic> item) {
    final licenseNo = (item['허가번호'] as String? ?? '').trim();
    final callname  = (item['호출명칭'] as String? ?? licenseNo).trim();
    _mapKey.currentState?.setMapDraggable(false);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        height: MediaQuery.of(context).size.height * 0.88,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InspectionResultScreen(
          isSheet: true,
          year: _year,
          licenseNo: licenseNo,
          callname: callname,
          initialData: item,
        ),
      ),
    ).whenComplete(() {
      _mapKey.currentState?.setMapDraggable(true);
      _loadInspection();
    });
  }

  void _onItemTap(Map<String, dynamic> item) {
    final licenseNo = (item['허가번호'] as String? ?? '').trim();
    final callname  = (item['호출명칭'] as String? ?? licenseNo).trim();
    final lat = (item['위도'] as num?)?.toDouble();
    final lng = (item['경도'] as num?)?.toDouble();
    if (lat != null && lng != null && lat != 0 && lng != 0) {
      final synth = RadioStation(
        id: licenseNo, stationName: callname,
        address: item['도로명주소'] as String? ?? item['설치장소'] as String? ?? '',
        latitude: lat, longitude: lng, licenseNumber: licenseNo,
      );
      _mapKey.currentState?.moveToStation(synth);
    }
    _showInspectionSheet(item);
  }

  @override
  Widget build(BuildContext context) {
    final markers = _markerStations;
    final screenWidth = MediaQuery.of(context).size.width;
    final isWideScreen = kIsWeb && screenWidth >= 700;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: isWideScreen
          ? _buildWideLayout(markers)
          : _buildNarrowLayout(markers),
    );
  }

  // ── Wide Screen ───────────────────────────────────────────────────────

  Widget _buildWideLayout(List<RadioStation> markerStations) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final listWidth = (constraints.maxWidth * 0.30).clamp(320.0, 400.0);
        return Column(
          children: [
            Container(color: Colors.white, child: SafeArea(bottom: false, child: _buildHeader())),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    child: Stack(
                      children: [
                        platform_map.PlatformMapWidget(
                          key: _mapKey,
                          stations: markerStations,
                          onMarkerTap: _onMarkerTap,
                        ),
                        Positioned(right: 16, bottom: 16, child: _buildMyLocationButton()),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: listWidth,
                    child: _buildDetailList(isWebLayout: true),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  // ── Narrow / Mobile ───────────────────────────────────────────────────

  Widget _buildNarrowLayout(List<RadioStation> markerStations) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final screenHeight = constraints.maxHeight;
        final listHeight = screenHeight * _listHeightRatio;

        return Stack(
          children: [
            Positioned.fill(
              child: Column(
                children: [
                  Container(color: Colors.white, child: SafeArea(bottom: false, child: _buildHeader())),
                  Expanded(
                    child: Stack(
                      children: [
                        platform_map.PlatformMapWidget(
                          key: _mapKey,
                          stations: markerStations,
                          onMarkerTap: _onMarkerTap,
                        ),
                        Positioned(
                          right: 16,
                          bottom: _listHeightRatio * screenHeight + 16,
                          child: _buildMyLocationButton(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0, right: 0, bottom: 0, height: listHeight,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (_) => _mapKey.currentState?.setMapDraggable(false),
                onPointerUp: (_) => _mapKey.currentState?.setMapDraggable(true),
                onPointerCancel: (_) => _mapKey.currentState?.setMapDraggable(true),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onVerticalDragUpdate: (details) {
                    setState(() {
                      _listHeightRatio = (_listHeightRatio - details.delta.dy / screenHeight)
                          .clamp(_minListRatio, _maxListRatio);
                    });
                  },
                  onVerticalDragEnd: (_) => _mapKey.currentState?.setMapDraggable(true),
                  onHorizontalDragUpdate: (_) {},
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(0, -2)),
                      ],
                    ),
                    child: Column(
                      children: [
                        Center(
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 12),
                            width: 40, height: 4,
                            decoration: BoxDecoration(color: Colors.grey[400], borderRadius: BorderRadius.circular(2)),
                          ),
                        ),
                        Expanded(child: _buildDetailList()),
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

  // ── Header ────────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          if (Navigator.canPop(context))
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, color: Colors.black54, size: 20),
              onPressed: () => Navigator.pop(context),
            ),
          const Text('수검 관리',
              style: TextStyle(color: Colors.black87, fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          if (_weekOptions.isNotEmpty) _buildWeekDropdown(),
          const Spacer(),
          if (_loadingInsp)
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: Colors.black54),
            tooltip: '새로고침',
            onPressed: _loadingInsp ? null : _loadInspection,
          ),
          UserProfileButton(onLogout: () => context.read<AuthService>().signOut()),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildYearChips() {
    final years = [DateTime.now().year - 1, DateTime.now().year, DateTime.now().year + 1];
    return Row(
      children: years.map((y) {
        final selected = y == _year;
        return GestureDetector(
          onTap: () {
            if (_year != y) {
              setState(() { _year = y; _selectedWeek = ''; _weekOptions = []; });
              _loadWeeks();
              _loadInspection();
            }
          },
          child: Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: selected ? const Color(0xFFE53935) : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('$y년',
                style: TextStyle(
                  fontSize: 12,
                  color: selected ? Colors.white : Colors.black54,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                )),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildWeekDropdown() {
    const primaryColor = Color(0xFFE53935);
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: '', child: Text('전체 주차')),
      ..._weekOptions.map((w) => DropdownMenuItem(value: w, child: Text(w))),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: false,
          isDense: true,
          icon: const Icon(Icons.arrow_drop_down, color: primaryColor, size: 20),
          dropdownColor: Colors.white,

          borderRadius: BorderRadius.circular(12),
          style: const TextStyle(color: Colors.black87, fontSize: 13),
          value: _selectedWeek,
          items: items,
          onChanged: (v) {
            setState(() => _selectedWeek = v ?? '');
            _loadInspection();
          },
        ),
      ),
    );
  }

  // ── 상세 리스트 ────────────────────────────────────────────────────────

  Widget _buildDetailList({bool isWebLayout = false}) {
    // 주차별 그룹핑
    final weekGroups = <String, List<Map<String, dynamic>>>{};
    for (final item in _assignedItems) {
      final key = item['수검예정주차'] as String? ?? '미정';
      weekGroups.putIfAbsent(key, () => []).add(item);
    }
    final sortedWeeks = weekGroups.keys.toList()..sort();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: isWebLayout
            ? [BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 10, offset: const Offset(-2, 0))]
            : null,
      ),
      child: Column(
        children: [
          if (isWebLayout)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
                ),
              ),
            ),

          // 헤더
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
                  child: Icon(Icons.assignment_outlined, color: Colors.red.shade400, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('수검 대상 $_year년',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      Text(
                        _inspError != null ? '로드 오류' : '${_assignedItems.length}개 국소',
                        style: TextStyle(
                          fontSize: 12,
                          color: _inspError != null ? Colors.red : Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isDense: true,
                      value: _sortOrder,
                      icon: Icon(Icons.arrow_drop_down, color: const Color(0xFFE53935), size: 20),
                      dropdownColor: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      style: const TextStyle(color: Colors.black87, fontSize: 13),
                      items: const [
                        DropdownMenuItem(value: '최신순', child: Text('최신순')),
                        DropdownMenuItem(value: '주차순', child: Text('주차순')),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _sortOrder = v);
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // 오류 배너
          if (_inspError != null)
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(8)),
              child: Row(
                children: [
                  Icon(Icons.error_outline, color: Colors.red[700], size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text('수검 목록 로드 실패: $_inspError',
                      style: TextStyle(fontSize: 12, color: Colors.red[800]))),
                  TextButton(onPressed: _loadInspection, child: const Text('재시도')),
                ],
              ),
            ),

          // 빈 목록
          if (_assignedItems.isEmpty && _inspError == null && !_loadingInsp)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.assignment_outlined, size: 48, color: Colors.grey.shade300),
                    const SizedBox(height: 12),
                    Text('$_year년 배정된 수검 항목이 없습니다.',
                        style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
                    const SizedBox(height: 4),
                    Text('담당자가 일정을 등록하면 표시됩니다.',
                        style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
                  ],
                ),
              ),
            )
          else if (_assignedItems.isNotEmpty)
            Expanded(
              child: RefreshIndicator(
                onRefresh: _loadInspection,
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: sortedWeeks.length,
                  itemBuilder: (context, gi) {
                    final week = sortedWeeks[gi];
                    final weekItems = weekGroups[week]!;
                    final weekDone = weekItems.where((it) =>
                        (it['status'] as String?) == '합격' ||
                        (it['status'] as String?) == '불합격').length;

                    // 조별 그룹핑 ('조' 필드 기준, 없으면 '')
                    final joGroups = <String, List<Map<String, dynamic>>>{};
                    for (final item in weekItems) {
                      final jo = (item['조'] as String? ?? '').trim();
                      joGroups.putIfAbsent(jo, () => []).add(item);
                    }
                    final hasJo = joGroups.keys.any((k) => k.isNotEmpty);
                    final sortedJos = joGroups.keys.toList()..sort((a, b) {
                      if (a.isEmpty) return 1;
                      if (b.isEmpty) return -1;
                      return a.compareTo(b);
                    });

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 주차 헤더
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Row(children: [
                            Container(width: 3, height: 14,
                                decoration: BoxDecoration(
                                    color: const Color(0xFFE53935),
                                    borderRadius: BorderRadius.circular(2))),
                            const SizedBox(width: 8),
                            Expanded(child: Text(week,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.black87))),
                            const SizedBox(width: 8),
                            Text('$weekDone/${weekItems.length}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: weekDone == weekItems.length ? const Color(0xFF43A047) : Colors.grey.shade500,
                                    fontWeight: FontWeight.w600)),
                          ]),
                        ),
                        // 조별 펼치기 or 단순 리스트
                        if (hasJo)
                          ...sortedJos.map((jo) {
                            final joItems = joGroups[jo]!;
                            final joDone = joItems.where((it) =>
                                (it['status'] as String?) == '합격' ||
                                (it['status'] as String?) == '불합격').length;
                            final joLabel = jo.isEmpty ? '조 미지정' : jo;
                            return _buildJoSection(joLabel, joItems, joDone);
                          })
                        else
                          ...weekItems.map(_buildInspectionItem),
                        const Divider(height: 1),
                      ],
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildJoSection(String joLabel, List<Map<String, dynamic>> items, int done) {
    const primaryColor = Color(0xFFE53935);
    const blueColor = Color(0xFF1E88E5);
    final isUnassigned = joLabel == '조 미지정';
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
        childrenPadding: EdgeInsets.zero,
        leading: Container(
          width: 28, height: 28,
          decoration: BoxDecoration(
            color: isUnassigned
                ? Colors.grey.shade100
                : blueColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(
            isUnassigned ? Icons.help_outline : Icons.group,
            size: 16,
            color: isUnassigned ? Colors.grey.shade400 : blueColor,
          ),
        ),
        title: Text(joLabel,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: isUnassigned ? Colors.grey.shade500 : blueColor)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$done/${items.length}',
                style: TextStyle(
                    fontSize: 12,
                    color: done == items.length ? const Color(0xFF43A047) : Colors.grey.shade500,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 18, color: Colors.black38),
          ],
        ),
        children: items.map(_buildInspectionItem).toList(),
      ),
    );
  }

  // ── 수검 아이템 카드 ───────────────────────────────────────────────────

  Widget _buildInspectionItem(Map<String, dynamic> item) {
    final licenseNo = item['허가번호'] as String? ?? '';
    final callname  = item['호출명칭'] as String? ?? licenseNo;
    final region    = item['지역'] as String? ?? '';
    final status    = item['status'] as String? ?? '검사대기';
    final inspDate  = item['검사일'] as String? ?? '';
    final hasCoords = (item['위도'] as num? ?? 0) != 0 && (item['경도'] as num? ?? 0) != 0;

    final Color statusColor;
    final IconData statusIcon;
    switch (status) {
      case '합격':
        statusColor = const Color(0xFF43A047);
        statusIcon  = Icons.check_circle_outline;
        break;
      case '불합격':
        statusColor = const Color(0xFFE53935);
        statusIcon  = Icons.cancel_outlined;
        break;
      default:
        statusColor = const Color(0xFF9E9E9E);
        statusIcon  = Icons.pending_outlined;
    }

    return InkWell(
      onTap: () => _onItemTap(item),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 위치 아이콘 (좌표 유무로 색상 구분)
            Stack(
              children: [
                Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(
                    color: status == '합격'
                        ? Colors.green.shade50
                        : (hasCoords ? Colors.blue.shade50 : Colors.grey.shade100),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    hasCoords ? Icons.location_on : Icons.location_off,
                    color: status == '합격'
                        ? Colors.green
                        : (hasCoords ? Colors.blue : Colors.grey),
                    size: 26,
                  ),
                ),
                if (status == '합격')
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(4)),
                      child: const Icon(Icons.check, color: Colors.white, size: 12),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(callname,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Row(children: [
                    if (region.isNotEmpty) ...[
                      Icon(Icons.location_on_outlined, size: 12, color: Colors.grey.shade400),
                      const SizedBox(width: 2),
                      Text(region, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                      const SizedBox(width: 6),
                    ],
                    Text(licenseNo, style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                  ]),
                  const SizedBox(height: 4),
                  Wrap(spacing: 4, children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(statusIcon, size: 11, color: statusColor),
                        const SizedBox(width: 3),
                        Text(status, style: TextStyle(fontSize: 10, color: statusColor, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                    if (inspDate.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4A90D9).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text('검사일 $inspDate',
                            style: const TextStyle(fontSize: 10, color: Color(0xFF4A90D9))),
                      ),
                  ]),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Colors.black26),
          ],
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  Widget _buildMyLocationButton() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () {
            _mapKey.currentState?.onGeolocationError = (error) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(error), backgroundColor: Colors.red),
                );
              }
            };
            _mapKey.currentState?.moveToCurrentLocation();
          },
          child: const Padding(
            padding: EdgeInsets.all(12),
            child: Icon(Icons.my_location, color: Colors.black87, size: 24),
          ),
        ),
      ),
    );
  }
}
