import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../models/radio_station.dart';
import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../widgets/progress_dialog.dart';
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
  String _selectedInspectionDate = '';

  String _selectedWeek = '';
  List<String> _weekOptions = [];

  // 본부 관리자용 팀 필터
  bool _isDivisionAdmin = false;
  bool _isLocationActive = false;
  bool _isSatellite = false;
  String _selectedTeam = '';
  List<String> _teamOptions = [];

  // 조/검사관 필터 (클라이언트 필터링)
  String _selectedJo = '';
  String _selectedInspector = '';

  // 경로 계획 모드
  bool _isRoutePlanMode = false;
  final List<RadioStation> _routeSelectedStations = [];
  bool _isCalculatingRoute = false;
  List<RadioStation>? _routeResult;
  bool _routeHasMyLocation = false;

  // 드래그 (모바일)
  double _listHeightRatio = 0.40;
  static const double _minListRatio = 0.15;
  static const double _maxListRatio = 0.85;

  @override
  void initState() {
    super.initState();
    _svc = InspectionService()
      ..setAuthToken(context.read<AuthService>().authToken);
    final auth = context.read<AuthService>();
    _isDivisionAdmin = auth.isDivisionAdmin || auth.isSuperAdmin;
    if (_isDivisionAdmin) _loadTeams();
    _loadWeeks();
    _loadInspection();
    // 진입 시 내 위치 자동 활성화
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (!mounted) return;
        _mapKey.currentState?.startLocationTracking();
        setState(() => _isLocationActive = true);
      });
    });
  }

  Future<void> _loadTeams() async {
    try {
      final orgMap = await _svc.getOrgMap(_year);
      final map = (orgMap['org_map'] as Map?)?.cast<String, dynamic>()
          ?? (orgMap['org'] as Map?)?.cast<String, dynamic>()
          ?? {};
      final auth = context.read<AuthService>();
      final myHdqt = (auth.userDepartment ?? '').replaceAll('Access담당', '').trim();
      List<String> teams = [];
      if (auth.isSuperAdmin) {
        // 수퍼 관리자: 모든 팀
        for (final v in map.values) {
          teams.addAll((v as List).cast<String>());
        }
        teams = teams.toSet().toList()..sort();
      } else if (myHdqt.isNotEmpty && map.containsKey(myHdqt)) {
        teams = List<String>.from(map[myHdqt] as List);
      }
      if (mounted) setState(() => _teamOptions = teams);
    } catch (_) {}
  }

  Future<void> _loadWeeks() async {
    try {
      final weeks = await _svc.getMyListWeeks(_year, team: _selectedTeam);
      if (mounted) setState(() => _weekOptions = weeks);
    } catch (_) {}
  }

  Future<void> _loadInspection() async {
    setState(() { _loadingInsp = true; _inspError = null; });
    try {
      final items = await _svc.getMyList(_year, week: _selectedWeek, team: _selectedTeam);
      setState(() => _assignedItems = items);
    } catch (e) {
      setState(() => _inspError = e.toString());
    } finally {
      setState(() => _loadingInsp = false);
    }
  }

  List<Map<String, dynamic>> get _filteredItems => _assignedItems.where((item) {
    if (_selectedJo.isNotEmpty && (item['조'] as String? ?? '').trim() != _selectedJo) return false;
    if (_selectedInspector.isNotEmpty && (item['검사관'] as String? ?? '').trim() != _selectedInspector) return false;
    if (_selectedInspectionDate.isNotEmpty) {
      final inspectionDate = _normalizeInspectionDate(item['검사일'] as String? ?? '');
      if (inspectionDate != _selectedInspectionDate) return false;
    }
    return true;
  }).toList();

  String _normalizeInspectionDate(String value) {
    final digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 8) {
      return digits.substring(2);
    }
    if (digits.length == 6) {
      return digits;
    }
    return value.trim();
  }

  String _displayInspectionDate(String value) {
    final normalized = _normalizeInspectionDate(value);
    if (normalized.length == 6 && RegExp(r'^\d{6}$').hasMatch(normalized)) {
      return normalized;
    }
    return value.trim();
  }

  List<String> get _inspectionDateOptions {
    final dates = _assignedItems
        .map((item) => _normalizeInspectionDate(item['검사일'] as String? ?? ''))
        .where((date) => date.isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));
    return dates;
  }

  // 지도 마커: inspection_targets의 위경도(Kakao 지오코딩 결과) 사용
  List<RadioStation> get _markerStations {
    final result = <RadioStation>[];
    for (final item in _filteredItems) {
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
            : status.startsWith('불합격')
                ? InspectionStatus.failed
                : status.startsWith('부적합')
                    ? InspectionStatus.inadequate
                    : InspectionStatus.pending,
      ));
    }
    return result;
  }

  void _onMarkerTap(RadioStation station) {
    if (_isRoutePlanMode) {
      _toggleRouteStation(station);
      // 마커 클릭 시 JS에서 zoom/drag가 꺼지므로 즉시 복원
      _mapKey.currentState?.setMapDraggable(true);
      return;
    }
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
                        if (_isRoutePlanMode)
                          Positioned(
                            left: 0, right: 0, bottom: 0,
                            child: _buildRoutePlanPanel(),
                          ),
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
                        if (_isRoutePlanMode)
                          Positioned(
                            left: 0, right: 0,
                            bottom: _listHeightRatio * screenHeight,
                            child: _buildRoutePlanPanel(),
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
          if (_isDivisionAdmin && _teamOptions.isNotEmpty) ...[
            _buildTeamDropdown(),
            const SizedBox(width: 8),
          ],
          if (_weekOptions.isNotEmpty) ...[
            _buildWeekDropdown(),
            const SizedBox(width: 8),
          ],
          _buildJoDropdown(),
          _buildInspectorDropdown(),
          const Spacer(),
          if (_loadingInsp)
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          IconButton(
            icon: Icon(Icons.alt_route,
                color: _isRoutePlanMode ? Colors.blue : Colors.black54),
            tooltip: '경로 계획',
            onPressed: _toggleRoutePlanMode,
          ),
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
              setState(() { _year = y; _selectedWeek = ''; _weekOptions = []; _selectedTeam = ''; _teamOptions = []; _selectedJo = ''; _selectedInspector = ''; });
              if (_isDivisionAdmin) _loadTeams();
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

  Widget _buildTeamDropdown() {
    const primaryColor = Color(0xFFE53935);
    final items = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: '', child: Text('전체 팀')),
      ..._teamOptions.map((t) => DropdownMenuItem(value: t, child: Text(t))),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _selectedTeam.isNotEmpty ? primaryColor : Colors.grey.shade300),
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
          value: _selectedTeam,
          items: items,
          onChanged: (v) {
            setState(() { _selectedTeam = v ?? ''; _selectedWeek = ''; _weekOptions = []; _selectedJo = ''; _selectedInspector = ''; });
            _loadWeeks();
            _loadInspection();
          },
        ),
      ),
    );
  }

  Widget _buildJoDropdown() {
    const primaryColor = Color(0xFFE53935);
    final joOptions = _assignedItems
        .map((i) => (i['조'] as String? ?? '').trim())
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList()..sort();
    if (joOptions.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _selectedJo.isNotEmpty ? primaryColor : Colors.grey.shade300),
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
          value: joOptions.contains(_selectedJo) ? _selectedJo : '',
          items: [
            const DropdownMenuItem(value: '', child: Text('전체 조')),
            ...joOptions.map((j) => DropdownMenuItem(value: j, child: Text(j))),
          ],
          onChanged: (v) => setState(() { _selectedJo = v ?? ''; _selectedInspector = ''; }),
        ),
      ),
    );
  }

  Widget _buildInspectorDropdown() {
    const primaryColor = Color(0xFFE53935);
    final filtered = _selectedJo.isEmpty
        ? _assignedItems
        : _assignedItems.where((i) => (i['조'] as String? ?? '').trim() == _selectedJo).toList();
    final inspectorOptions = filtered
        .map((i) => (i['검사관'] as String? ?? '').trim())
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList()..sort();
    if (inspectorOptions.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _selectedInspector.isNotEmpty ? primaryColor : Colors.grey.shade300),
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
          value: inspectorOptions.contains(_selectedInspector) ? _selectedInspector : '',
          items: [
            const DropdownMenuItem(value: '', child: Text('전체 검사관')),
            ...inspectorOptions.map((v) => DropdownMenuItem(value: v, child: Text(v))),
          ],
          onChanged: (v) => setState(() => _selectedInspector = v ?? ''),
        ),
      ),
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
    final inspectionDateOptions = _inspectionDateOptions;

    // 주차별 그룹핑
    final weekGroups = <String, List<Map<String, dynamic>>>{};
    for (final item in _filteredItems) {
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                            _inspError != null ? '로드 오류' : '${_filteredItems.length}개 국소',
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
                if (inspectionDateOptions.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: _selectedInspectionDate.isNotEmpty
                            ? const Color(0xFF4A90D9).withValues(alpha: 0.10)
                            : Colors.white,
                        border: Border.all(
                          color: _selectedInspectionDate.isNotEmpty
                              ? const Color(0xFF4A90D9)
                              : Colors.grey.shade300,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isDense: true,
                          value: _selectedInspectionDate,
                          icon: Icon(
                            Icons.arrow_drop_down,
                            color: _selectedInspectionDate.isNotEmpty
                                ? const Color(0xFF4A90D9)
                                : const Color(0xFFE53935),
                            size: 20,
                          ),
                          dropdownColor: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          style: TextStyle(
                            color: _selectedInspectionDate.isNotEmpty
                                ? const Color(0xFF4A90D9)
                                : Colors.black87,
                            fontSize: 13,
                            fontWeight: _selectedInspectionDate.isNotEmpty
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                          items: [
                            const DropdownMenuItem(value: '', child: Text('전체 검사일')),
                            ...inspectionDateOptions.map(
                              (date) => DropdownMenuItem(
                                value: date,
                                child: Text(date),
                              ),
                            ),
                          ],
                          onChanged: (v) {
                            setState(() => _selectedInspectionDate = v ?? '');
                          },
                        ),
                      ),
                    ),
                  ),
                ],
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
                        ((it['status'] as String?) ?? '').startsWith('불합격') ||
                        (it['status'] as String?) == '부적합').length;

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
                                ((it['status'] as String?) ?? '').startsWith('불합격') ||
                                (it['status'] as String?) == '부적합').length;
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
        title: Row(
          children: [
            Text(joLabel,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isUnassigned ? Colors.grey.shade500 : blueColor)),
            if (!isUnassigned) ...[
              const SizedBox(width: 6),
              Builder(builder: (_) {
                final inspectors = items
                    .map((i) => (i['검사관'] as String? ?? '').trim())
                    .where((v) => v.isNotEmpty)
                    .toSet()
                    .join(', ');
                if (inspectors.isEmpty) return const SizedBox.shrink();
                return Text('($inspectors)',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500, fontWeight: FontWeight.normal));
              }),
            ],
          ],
        ),
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
    final licenseNo  = item['허가번호'] as String? ?? '';
    final callname   = item['호출명칭'] as String? ?? licenseNo;
    final region     = item['지역'] as String? ?? '';
    final status     = item['status'] as String? ?? '검사대기';
    final inspDate   = _displayInspectionDate(item['검사일'] as String? ?? '');
    final hasCoords  = (item['위도'] as num? ?? 0) != 0 && (item['경도'] as num? ?? 0) != 0;
    final jo         = (item['조'] as String? ?? '').trim();
    final inspector  = (item['검사관'] as String? ?? '').trim();

    final Color statusColor;
    final IconData statusIcon;
    if (status == '합격') {
      statusColor = const Color(0xFF43A047);
      statusIcon  = Icons.check_circle_outline;
    } else if (status.startsWith('불합격')) {
      statusColor = const Color(0xFFE53935);
      statusIcon  = Icons.cancel_outlined;
    } else if (status.startsWith('부적합')) {
      statusColor = const Color(0xFFF57C00);
      statusIcon  = Icons.warning_amber_outlined;
    } else {
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
            // 위치 아이콘 (상태별 색상 — 마커와 동일)
            Stack(
              children: [
                Container(
                  width: 56, height: 56,
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    hasCoords ? Icons.location_on : Icons.location_off,
                    color: statusColor,
                    size: 26,
                  ),
                ),
                if (status == '합격')
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(color: statusColor, borderRadius: BorderRadius.circular(4)),
                      child: const Icon(Icons.check, color: Colors.white, size: 12),
                    ),
                  ),
                if (status.startsWith('불합격'))
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(color: statusColor, borderRadius: BorderRadius.circular(4)),
                      child: const Icon(Icons.close, color: Colors.white, size: 12),
                    ),
                  ),
                if (status.startsWith('부적합'))
                  Positioned(
                    right: 0, bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: BoxDecoration(color: statusColor, borderRadius: BorderRadius.circular(4)),
                      child: const Icon(Icons.warning_amber, color: Colors.white, size: 12),
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
            if (jo.isNotEmpty || inspector.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 8, right: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (jo.isNotEmpty)
                      Text(jo, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFE53935))),
                    if (inspector.isNotEmpty)
                      Text(inspector, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 위성뷰 토글
        _mapFloatingButton(
          icon: _isSatellite ? Icons.map : Icons.satellite_alt,
          color: _isSatellite ? const Color(0xFF4285F4) : Colors.black87,
          onTap: () {
            setState(() => _isSatellite = !_isSatellite);
            _mapKey.currentState?.setMapType(_isSatellite);
          },
        ),
        const SizedBox(height: 8),
        // 내 위치 버튼 (토글: 꺼짐 ↔ 현재 위치 + 방향 표시)
        _mapFloatingButton(
          icon: _isLocationActive ? Icons.navigation : Icons.my_location,
          color: _isLocationActive ? const Color(0xFF4285F4) : Colors.black87,
          onTap: () {
            _mapKey.currentState?.onGeolocationError = (error) {
              if (mounted) {
                final d = ProgressDialog(context);
                d.error(message: error);
              }
            };
            if (_isLocationActive) {
              _mapKey.currentState?.stopLocationTracking();
              _mapKey.currentState?.clearLocationMarker();
            } else {
              _mapKey.currentState?.startLocationTracking();
            }
            setState(() => _isLocationActive = !_isLocationActive);
          },
        ),
      ],
    );
  }

  // ── 경로 계획 ─────────────────────────────────────────────────────────

  void _toggleRoutePlanMode() {
    setState(() {
      _isRoutePlanMode = !_isRoutePlanMode;
      if (!_isRoutePlanMode) {
        _routeSelectedStations.clear();
        _routeResult = null;
        _routeHasMyLocation = false;
        _mapKey.currentState?.clearRouteOverlay();
      }
    });
    // 경로 모드 On/Off 관계없이 지도 조작 항상 활성화
    _mapKey.currentState?.setMapDraggable(true);
  }

  void _toggleRouteStation(RadioStation station) {
    setState(() {
      final idx = _routeSelectedStations.indexWhere((s) => s.id == station.id);
      if (idx >= 0) {
        _routeSelectedStations.removeAt(idx);
      } else {
        _routeSelectedStations.add(station);
      }
      _routeResult = null;
      _mapKey.currentState?.clearRouteOverlay();
      _mapKey.currentState?.setRouteSelectedMarkers(
        _routeSelectedStations.map((s) => s.id).toList(),
      );
    });
  }

  Future<void> _calculateOptimalRoute() async {
    if (_routeSelectedStations.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('최소 2개 이상의 국소를 선택하세요.')),
      );
      return;
    }
    setState(() => _isCalculatingRoute = true);
    try {
      final stations = List<RadioStation>.from(_routeSelectedStations);
      final myLat = _mapKey.currentState?.currentLat;
      final myLng = _mapKey.currentState?.currentLng;
      final hasMyLocation = myLat != null && myLng != null;
      if (!hasMyLocation) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('내 위치를 확인 중입니다. 위치 버튼을 눌러 위치를 활성화해 주세요.'),
            duration: Duration(seconds: 3),
          ),
        );
      }

      // 내 위치를 포함한 전체 좌표 목록 (내 위치가 index 0)
      final allCoords = <String>[];
      if (hasMyLocation) allCoords.add('$myLng,$myLat');
      allCoords.addAll(stations.map((s) => '${s.longitude},${s.latitude}'));

      final coordsStr = allCoords.join(';');
      final tableResp = await http
          .get(Uri.parse(
              'https://router.project-osrm.org/table/v1/driving/$coordsStr?annotations=duration'))
          .timeout(const Duration(seconds: 30));
      if (tableResp.statusCode != 200) throw Exception('OSRM 서버 오류');
      final tableData = json.decode(tableResp.body) as Map<String, dynamic>;
      final durations = (tableData['durations'] as List)
          .map((row) => (row as List).map((v) => (v as num).toDouble()).toList())
          .toList();

      final offset = hasMyLocation ? 1 : 0; // 내 위치 offset
      final n = stations.length;
      final visited = List.filled(n + offset, false);
      final order = <int>[];
      // 출발: 내 위치(0) 또는 첫 번째 국소(0)
      int current = 0;
      visited[current] = true;
      for (int step = 0; step < n; step++) {
        double best = double.infinity;
        int next = -1;
        for (int j = offset; j < n + offset; j++) {
          if (!visited[j] && durations[current][j] < best) {
            best = durations[current][j];
            next = j;
          }
        }
        visited[next] = true;
        order.add(next - offset); // stations 인덱스로 변환
        current = next;
      }
      final orderedStations = order.map((i) => stations[i]).toList();

      final routeCoords = orderedStations.map((s) => '${s.longitude},${s.latitude}').join(';');
      final routeResp = await http
          .get(Uri.parse(
              'https://router.project-osrm.org/route/v1/driving/$routeCoords?overview=full&geometries=geojson'))
          .timeout(const Duration(seconds: 30));

      List<List<double>>? polylineCoords;
      if (routeResp.statusCode == 200) {
        final routeData = json.decode(routeResp.body) as Map<String, dynamic>;
        final routes = routeData['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final coordsList =
              ((routes[0] as Map)['geometry'] as Map?)?['coordinates'] as List?;
          if (coordsList != null) {
            polylineCoords = coordsList
                .map((c) => [(c as List)[0] as double, c[1] as double])
                .toList();
          }
        }
      }

      setState(() {
        _routeResult = orderedStations;
        _routeHasMyLocation = hasMyLocation;
        _isCalculatingRoute = false;
      });
      _mapKey.currentState?.drawRouteOverlay(
        orderedStations: orderedStations,
        polylineCoords: polylineCoords,
      );
    } catch (e) {
      setState(() => _isCalculatingRoute = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('경로 계산 실패: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildRoutePlanPanel() {
    final hasResult = _routeResult != null;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 8, offset: const Offset(0, -2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: Colors.blue,
            child: Row(
              children: [
                const Icon(Icons.alt_route, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hasResult
                        ? '최적 경로 (${_routeResult!.length}개 국소)'
                        : '경로 계획 모드 — 방문할 국소를 선택하세요',
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton(
                  onPressed: _toggleRoutePlanMode,
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('종료', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
          if (hasResult) _buildRouteResultList() else _buildRouteSelectionList(),
        ],
      ),
    );
  }

  Widget _buildRouteSelectionList() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_routeSelectedStations.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('지도에서 마커를 탭하여 국소를 선택하세요',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _routeSelectedStations.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final s = _routeSelectedStations[index];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 12,
                      backgroundColor: Colors.blue,
                      child: Text('${index + 1}',
                          style: const TextStyle(color: Colors.white, fontSize: 11)),
                    ),
                    title: Text(s.displayName, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(s.address,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11)),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => _toggleRouteStation(s),
                    ),
                  );
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _routeSelectedStations.length < 2 || _isCalculatingRoute
                    ? null
                    : _calculateOptimalRoute,
                icon: _isCalculatingRoute
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.navigation, size: 18),
                label: Text(_isCalculatingRoute
                    ? '계산 중...'
                    : '최적 경로 계산 (${_routeSelectedStations.length}개)'),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue, foregroundColor: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRouteResultList() {
    final stations = _routeResult!;
    // 내 위치 출발 포함 시 총 아이템 수 = 1 + stations.length
    final totalItems = _routeHasMyLocation ? stations.length + 1 : stations.length;
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: totalItems,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                // 내 위치 출발 행
                if (_routeHasMyLocation && index == 0) {
                  return ListTile(
                    dense: true,
                    leading: const CircleAvatar(
                      radius: 12,
                      backgroundColor: Colors.green,
                      child: Icon(Icons.my_location, color: Colors.white, size: 13),
                    ),
                    title: const Text('내 위치', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    trailing: const Text('출발', style: TextStyle(fontSize: 11, color: Colors.green)),
                  );
                }
                final stationIndex = _routeHasMyLocation ? index - 1 : index;
                final s = stations[stationIndex];
                final isLast = stationIndex == stations.length - 1;
                final displayIndex = _routeHasMyLocation ? index : index + 1;
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 12,
                    backgroundColor: isLast ? Colors.red : Colors.blue,
                    child: Text('$displayIndex',
                        style: const TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                  title: Text(s.displayName, style: const TextStyle(fontSize: 13)),
                  subtitle: Text(s.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11)),
                  trailing: isLast
                      ? const Text('도착', style: TextStyle(fontSize: 11, color: Colors.red))
                      : null,
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  setState(() {
                    _routeResult = null;
                    _mapKey.currentState?.clearRouteOverlay();
                    _mapKey.currentState?.setRouteSelectedMarkers(
                      _routeSelectedStations.map((s) => s.id).toList(),
                    );
                  });
                },
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('다시 선택'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _mapFloatingButton({required IconData icon, required Color color, required VoidCallback onTap}) {
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
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, color: color, size: 22),
          ),
        ),
      ),
    );
  }
}
