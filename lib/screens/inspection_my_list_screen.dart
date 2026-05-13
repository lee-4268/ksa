// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../models/radio_station.dart';
import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../models/route_basket.dart';
import '../services/route_basket_service.dart';
import '../widgets/progress_dialog.dart';
import '../widgets/user_profile_button.dart';
import 'inspection_result_screen.dart';

// MapScreen과 동일한 조건부 import
import 'map_screen_web.dart' if (dart.library.io) 'map_screen_mobile.dart'
    as platform_map;
import '../services/azimuth_service.dart';

enum _PolygonPhase { idle, drawing, selectEndpoints, calculating, result }

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

  // Phase 4: 수검 가능 건만 보기 (전파관리소 접수 완료 이상)
  // SUBMITTED / REPORT_ISSUED(접수번호 스킵 케이스) / INSPECTED(완료·재방문)
  bool _readyOnly = true;

  // 폴리곤 경로 담기
  _PolygonPhase _polygonPhase = _PolygonPhase.idle;
  int _polygonVertexCount = 0;
  List<RadioStation> _polygonStations = [];
  int _polygonDupeCount = 0;
  RadioStation? _polygonStart;
  RadioStation? _polygonEnd;
  List<RadioStation>? _polygonRouteResult;

  // 경로 담기 바구니
  late final RouteBasketService _basketSvc;
  List<RouteBasketEntry> _routeBaskets = [];
  bool _savingBasket = false;

  // 안테나 방위각 표시
  late final AzimuthService _azSvc;
  bool _showAzimuth = false;
  bool _azBandsExpanded = true;
  Map<String, List<AntennaSector>> _azimuthData = {};
  Set<String> _activeBandKeys = const {
    'LTE-800M', 'LTE-1.8G', 'LTE-2.1G', 'LTE-2.6G', 'LTE-멀티',
    '5G-3.5G', '5G-28G',
  };
  bool _loadingAzimuth = false;

  // 드래그 (모바일)
  double _listHeightRatio = 0.40;
  static const double _minListRatio = 0.15;
  static const double _maxListRatio = 0.85;

  @override
  void initState() {
    super.initState();
    final token = context.read<AuthService>().authToken;
    _svc = InspectionService()..setAuthToken(token);
    _azSvc = AzimuthService()..setAuthToken(token);
    _basketSvc = RouteBasketService()..setAuthToken(token);
    final auth = context.read<AuthService>();
    _isDivisionAdmin = auth.isDivisionAdmin || auth.isSuperAdmin;
    if (_isDivisionAdmin) _loadTeams();
    _loadWeeks();
    _loadInspection();
    _loadBaskets();
    // 진입 시 내 위치 자동 활성화 + 폴리곤 콜백 등록
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (!mounted) return;
        _mapKey.currentState?.startLocationTracking();
        setState(() => _isLocationActive = true);
      });
      _mapKey.currentState?.setPolygonCallback(
        onVertices: _onPolygonVerticesReceived,
        onCount: (c) => setState(() => _polygonVertexCount = c),
      );
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
      setState(() {
        _assignedItems = items;
        _azimuthData = {}; // 마커 셋이 바뀌었으므로 무효화
      });
      if (_showAzimuth) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final stations = _markerStations;
          _loadAzimuth(stations).then((_) {
            if (mounted) _applyAzimuth(stations);
          });
        });
      }
    } catch (e) {
      setState(() => _inspError = e.toString());
    } finally {
      setState(() => _loadingInsp = false);
    }
  }

  // Phase 4: 수검 가능 상태 — 전파관리소 접수가 끝났거나 그 이후
  static const _readyStatuses = {'SUBMITTED', 'REPORT_ISSUED', 'INSPECTED'};

  List<Map<String, dynamic>> get _filteredItems => _assignedItems.where((item) {
    if (_selectedJo.isNotEmpty && (item['조'] as String? ?? '').trim() != _selectedJo) return false;
    if (_selectedInspector.isNotEmpty && (item['검사관'] as String? ?? '').trim() != _selectedInspector) return false;
    if (_selectedInspectionDate.isNotEmpty) {
      final inspectionDate = _normalizeInspectionDate(item['검사일'] as String? ?? '');
      if (inspectionDate != _selectedInspectionDate) return false;
    }
    if (_readyOnly) {
      final wf = (item['workflow_status'] as String? ?? '').trim();
      if (!_readyStatuses.contains(wf)) return false;
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

  // ── 안테나 방위각 ─────────────────────────────────────────────
  Future<void> _toggleAzimuth(bool on, List<RadioStation> markerStations) async {
    setState(() => _showAzimuth = on);
    if (!on) {
      _mapKey.currentState?.clearAzimuthSectors();
      return;
    }
    if (_azimuthData.isEmpty) {
      await _loadAzimuth(markerStations);
    }
    _applyAzimuth(markerStations);
  }

  Future<void> _loadAzimuth(List<RadioStation> markerStations) async {
    final ids = markerStations
        .map((s) => s.licenseNumber.trim())
        .where((z) => z.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return;
    setState(() => _loadingAzimuth = true);
    try {
      final data = await _azSvc.fetchBatch(ids);
      if (!mounted) return;
      // ignore: avoid_print
      print('[azimuth] fetched stations=${data.length}/${ids.length}, '
          'sectorsTotal=${data.values.fold<int>(0, (a, l) => a + l.length)}');
      setState(() {
        _azimuthData = data;
        _loadingAzimuth = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingAzimuth = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('방위각 조회 실패: $e')),
      );
    }
  }

  void _applyAzimuth(List<RadioStation> markerStations) {
    if (!_showAzimuth) return;
    final stationAz = <String, List<Map<String, dynamic>>>{};
    final stationLL = <String, List<double>>{};
    for (final st in markerStations) {
      if (!st.hasCoordinates) continue;
      final z = st.licenseNumber.trim();
      if (z.isEmpty) continue;
      final secs = _azimuthData[z];
      if (secs == null || secs.isEmpty) continue;
      stationAz[st.id] = secs
          .map((s) => {
                'service': s.service,
                'band': s.band,
                'swings': s.swings,
              })
          .toList();
      stationLL[st.id] = [st.latitude!, st.longitude!];
    }
    final colorMap = <String, String>{
      for (final b in kSupportedBands)
        b.key: '#${b.colorRgb.toRadixString(16).padLeft(8, '0').substring(2)}',
    };
    _mapKey.currentState?.setAzimuthSectors(
      stationAzimuths: stationAz,
      stationLatLng: stationLL,
      activeBandKeys: _activeBandKeys.toList(),
      bandColors: colorMap,
    );
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
                        Positioned(
                          left: 12, top: 12,
                          child: _buildAzimuthControl(markerStations),
                        ),
                        Positioned(right: 16, bottom: 16, child: _buildMyLocationButton()),
                        if (kIsWeb && _polygonPhase == _PolygonPhase.idle)
                          Positioned(right: 12, top: 12, child: _buildPolygonEntryButton()),
                        if (_polygonPhase != _PolygonPhase.idle)
                          Positioned(
                            left: 0, right: 0, bottom: 0,
                            child: MouseRegion(
                              onEnter: (_) => _mapKey.currentState?.setMapDraggable(false),
                              onExit: (_) => _mapKey.currentState?.setMapDraggable(true),
                              child: _buildPolygonPanel(),
                            ),
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
                          left: 12, top: 12,
                          child: _buildAzimuthControl(markerStations),
                        ),
                        Positioned(
                          right: 16,
                          bottom: _listHeightRatio * screenHeight + 16,
                          child: _buildMyLocationButton(),
                        ),
                        if (kIsWeb && _polygonPhase == _PolygonPhase.idle)
                          Positioned(right: 12, top: 12, child: _buildPolygonEntryButton()),
                        if (_polygonPhase != _PolygonPhase.idle)
                          Positioned(
                            left: 0, right: 0,
                            bottom: _listHeightRatio * screenHeight,
                            child: MouseRegion(
                              onEnter: (_) => _mapKey.currentState?.setMapDraggable(false),
                              onExit: (_) => _mapKey.currentState?.setMapDraggable(true),
                              child: _buildPolygonPanel(),
                            ),
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
    final hasDropdowns = (_isDivisionAdmin && _teamOptions.isNotEmpty)
        || _weekOptions.isNotEmpty
        || _assignedItems.any((i) => (i['조'] as String? ?? '').isNotEmpty)
        || _assignedItems.any((i) => (i['검사관'] as String? ?? '').isNotEmpty);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1행: 제목 + 우측 아이콘
          Row(
            children: [
              if (Navigator.canPop(context))
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new, color: Colors.black54, size: 20),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () => Navigator.pop(context),
                ),
              const Text('수검 관리',
                  style: TextStyle(color: Colors.black87, fontSize: 17, fontWeight: FontWeight.w600)),
              const Spacer(),
              if (_loadingInsp)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              IconButton(
                icon: const Icon(Icons.refresh_rounded, color: Colors.black54, size: 22),
                tooltip: '새로고침',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: _loadingInsp ? null : _loadInspection,
              ),
              UserProfileButton(onLogout: () => context.read<AuthService>().signOut()),
              const SizedBox(width: 4),
            ],
          ),
          // 2행: 드롭다운 필터 (있을 때만, Flexible로 균등 분배)
          if (hasDropdowns)
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 4),
              child: Builder(builder: (context) {
                final hasJo = _assignedItems.any((i) => (i['조'] as String? ?? '').trim().isNotEmpty);
                final filtered = _selectedJo.isEmpty
                    ? _assignedItems
                    : _assignedItems.where((i) => (i['조'] as String? ?? '').trim() == _selectedJo).toList();
                final hasInspector = filtered.any((i) => (i['검사관'] as String? ?? '').trim().isNotEmpty);
                return Row(
                  children: [
                    if (_isDivisionAdmin && _teamOptions.isNotEmpty) ...[
                      Flexible(child: _buildTeamDropdown(expanded: true)),
                      const SizedBox(width: 6),
                    ],
                    if (_weekOptions.isNotEmpty) ...[
                      Flexible(child: _buildWeekDropdown(expanded: true)),
                      const SizedBox(width: 6),
                    ],
                    if (hasJo) ...[
                      Flexible(child: _buildJoDropdown(expanded: true)),
                      if (hasInspector) const SizedBox(width: 6),
                    ],
                    if (hasInspector) ...[
                      Flexible(child: _buildInspectorDropdown(expanded: true)),
                      const SizedBox(width: 6),
                    ],
                    _buildReadyOnlyToggle(),
                  ],
                );
              }),
            ),
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

  Widget _buildTeamDropdown({bool expanded = false}) {
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
          isExpanded: expanded,
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

  Widget _buildJoDropdown({bool expanded = false}) {
    const primaryColor = Color(0xFFE53935);
    final joOptions = _assignedItems
        .map((i) => (i['조'] as String? ?? '').trim())
        .where((v) => v.isNotEmpty)
        .toSet()
        .toList()..sort();
    if (joOptions.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: expanded ? null : const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _selectedJo.isNotEmpty ? primaryColor : Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: expanded,
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

  Widget _buildReadyOnlyToggle() {
    const primaryColor = Color(0xFFE53935);
    final c = _readyOnly ? primaryColor : Colors.grey.shade400;
    return Tooltip(
      message: _readyOnly
          ? '수검 가능 건(접수완료 이후)만 표시 중 — 끄면 전체'
          : '전체 일정 표시 중 — 켜면 수검 가능 건만',
      child: InkWell(
        onTap: () => setState(() => _readyOnly = !_readyOnly),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: _readyOnly ? primaryColor.withValues(alpha: 0.08) : Colors.white,
            border: Border.all(color: c),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_readyOnly ? Icons.filter_alt : Icons.filter_alt_off, size: 14, color: c),
            const SizedBox(width: 4),
            Text('수검가능',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c)),
          ]),
        ),
      ),
    );
  }

  Widget _buildInspectorDropdown({bool expanded = false}) {
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
      margin: expanded ? null : const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _selectedInspector.isNotEmpty ? primaryColor : Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: expanded,
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

  Widget _buildWeekDropdown({bool expanded = false}) {
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
          isExpanded: expanded,
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

    // 주차별 그룹핑 (각 그룹 내 호출명칭 오름차순)
    final weekGroups = <String, List<Map<String, dynamic>>>{};
    for (final item in _filteredItems) {
      final key = item['수검예정주차'] as String? ?? '미정';
      weekGroups.putIfAbsent(key, () => []).add(item);
    }
    for (final list in weekGroups.values) {
      list.sort((a, b) => (a['호출명칭'] as String? ?? '').compareTo(b['호출명칭'] as String? ?? ''));
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
                            return _buildJoSection(week, joLabel, joItems, joDone);
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

  Widget _buildJoSection(String weekLabel, String joLabel, List<Map<String, dynamic>> items, int done) {
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
        children: [
          _buildBasketEntriesInJo(weekLabel, joLabel),
          ...items.map(_buildInspectionItem),
        ],
      ),
    );
  }

  Widget _buildBasketEntriesInJo(String weekLabel, String joLabel) {
    final baskets = _routeBaskets.where((e) => e.weekLabel == weekLabel && e.joLabel == joLabel).toList();
    if (baskets.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 16, 4),
          child: Row(
            children: [
              const Icon(Icons.route, size: 13, color: Color(0xFFE53935)),
              const SizedBox(width: 4),
              Text('경로 담기 (${baskets.length})',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFE53935))),
            ],
          ),
        ),
        ...baskets.map((entry) => _buildBasketEntryTile(entry)),
        const Divider(height: 1, indent: 20),
      ],
    );
  }

  Widget _buildBasketEntryTile(RouteBasketEntry entry) {
    return InkWell(
      onTap: () {
        final stations = entry.stations.map((bs) => RadioStation(
          id: bs.id,
          stationName: bs.name,
          address: '',
          licenseNumber: bs.id,
          latitude: bs.lat,
          longitude: bs.lng,
          inspectionStatus: InspectionStatus.pending,
        )).toList();
        _mapKey.currentState?.clearRouteOverlay();
        _mapKey.currentState?.drawRouteOverlay(orderedStations: stations);
        _showBasketStationList(entry, stations);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
        child: Row(
          children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(color: const Color(0xFFE53935).withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)),
              child: const Icon(Icons.bookmark, size: 16, color: Color(0xFFE53935)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.title,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87)),
                  Text('${entry.stations.length}개 국소',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16, color: Colors.black38),
              onPressed: () => _confirmDeleteBasket(entry),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            ),
          ],
        ),
      ),
    );
  }

  void _showBasketStationList(RouteBasketEntry entry, List<RadioStation> stations) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10),
              width: 36, height: 4,
              decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Row(
                children: [
                  const Icon(Icons.bookmark, size: 18, color: Color(0xFFE53935)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(entry.title,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                  Text('${stations.length}개 국소',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                ],
              ),
            ),
            const Divider(height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: stations.length,
                separatorBuilder: (_, _) => const Divider(height: 1, indent: 20),
                itemBuilder: (_, i) {
                  final s = stations[i];
                  final isFirst = i == 0;
                  final isLast = i == stations.length - 1;
                  final color = isFirst ? Colors.green : (isLast ? Colors.red : const Color(0xFFE53935));
                  final tag = isFirst ? '출발' : (isLast ? '도착' : '${i + 1}');
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 13,
                      backgroundColor: color,
                      child: Text(tag, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                    title: Text(s.displayName, style: const TextStyle(fontSize: 13)),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteBasket(RouteBasketEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('경로 삭제', style: TextStyle(fontSize: 15)),
        content: Text('"${entry.title}" 경로를 삭제하시겠습니까?', style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok == true) _deleteBasket(entry.entryId);
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

  Widget _buildAzimuthControl(List<RadioStation> markerStations) {
    return Material(
      color: Colors.white,
      elevation: 3,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: const BoxConstraints(maxWidth: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cell_tower, size: 18, color: Color(0xFF1565C0)),
                const SizedBox(width: 6),
                const Text('안테나 방향',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                if (_loadingAzimuth)
                  const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Transform.scale(
                    scale: 0.8,
                    child: Switch(
                      value: _showAzimuth,
                      onChanged: (v) => _toggleAzimuth(v, markerStations),
                      activeColor: const Color(0xFF1565C0),
                    ),
                  ),
                if (_showAzimuth)
                  InkWell(
                    onTap: () =>
                        setState(() => _azBandsExpanded = !_azBandsExpanded),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        _azBandsExpanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 20,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
              ],
            ),
            if (_showAzimuth && _azBandsExpanded) ...[
              const Divider(height: 8),
              Wrap(
                spacing: 4,
                runSpacing: 2,
                children: kSupportedBands.where((b) {
                  // 3G/WCDMA는 빈 band이므로 둘 중 하나만(WCDMA만) 표시 — 키가 'WCDMA-'
                  if (b.service == '3G') return false;
                  return true;
                }).map((b) {
                  final selected = _activeBandKeys.contains(b.key);
                  return FilterChip(
                    label: Text(
                      b.label,
                      style: TextStyle(
                        fontSize: 11,
                        color: selected
                            ? Colors.white
                            : Color(b.colorRgb),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    selected: selected,
                    showCheckmark: false,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize:
                        MaterialTapTargetSize.shrinkWrap,
                    backgroundColor: Color(b.colorRgb).withValues(alpha: 0.10),
                    selectedColor: Color(b.colorRgb),
                    side: BorderSide(color: Color(b.colorRgb), width: 1),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                    onSelected: (sel) {
                      setState(() {
                        if (sel) {
                          _activeBandKeys = {..._activeBandKeys, b.key};
                        } else {
                          _activeBandKeys = {..._activeBandKeys}..remove(b.key);
                        }
                      });
                      _applyAzimuth(markerStations);
                    },
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMyLocationButton() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 전체 뷰 리셋
        _mapFloatingButton(
          icon: Icons.zoom_out_map,
          color: Colors.black87,
          onTap: () => _mapKey.currentState?.resetView(),
        ),
        const SizedBox(height: 8),
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

  // ── 경로 담기 바구니 ─────────────────────────────────────────────────

  Future<void> _loadBaskets() async {
    try {
      final entries = await _basketSvc.getAll();
      if (mounted) setState(() => _routeBaskets = entries);
    } catch (_) {}
  }

  Future<void> _deleteBasket(String entryId) async {
    try {
      await _basketSvc.delete(entryId);
      if (mounted) setState(() => _routeBaskets.removeWhere((e) => e.entryId == entryId));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('삭제 실패: $e'), backgroundColor: Colors.red));
    }
  }

  // ── 폴리곤 경로 계획 ──────────────────────────────────────────────────

  bool _isPointInPolygon(double lat, double lng, List<List<double>> polygon) {
    bool inside = false;
    int n = polygon.length;
    int j = n - 1;
    for (int i = 0; i < n; j = i++) {
      final yi = polygon[i][0], xi = polygon[i][1];
      final yj = polygon[j][0], xj = polygon[j][1];
      if ((yi > lat) != (yj > lat) && lng < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    return inside;
  }

  void _onPolygonVerticesReceived(List<List<double>> vertices) {
    if (vertices.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('꼭짓점이 3개 이상 필요합니다.')));
      return;
    }
    // 폴리곤 내 국소 필터 (좌표 없는 국소 제외)
    final inside = _markerStations.where((s) {
      final lat = s.latitude, lng = s.longitude;
      if (lat == null || lng == null) return false;
      return _isPointInPolygon(lat, lng, vertices);
    }).toList();
    // 같은 좌표(다른 밴드) 중복 제거: 첫 번째만 선택
    final seen = <String>{};
    final deduped = <RadioStation>[];
    for (final s in inside) {
      final key = '${s.latitude?.toStringAsFixed(5)},${s.longitude?.toStringAsFixed(5)}';
      if (seen.add(key)) deduped.add(s);
    }
    final dupeCount = inside.length - deduped.length;
    if (deduped.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('선택된 구역 내 국소가 없습니다.')));
      setState(() => _polygonPhase = _PolygonPhase.idle);
      _mapKey.currentState?.clearPolygonOverlay();
      return;
    }
    setState(() {
      _polygonStations = deduped;
      _polygonDupeCount = dupeCount;
      _polygonStart = null;
      _polygonEnd = null;
      _polygonRouteResult = null;
      _polygonPhase = _PolygonPhase.selectEndpoints;
    });
  }

  Future<void> _calculatePolygonRoute() async {
    final start = _polygonStart!;
    final end = _polygonEnd!;
    final middles = _polygonStations.where((s) => s.id != start.id && s.id != end.id).toList();

    setState(() => _polygonPhase = _PolygonPhase.calculating);
    try {
      final osrmStations = [start, ...middles];
      final coordsStr = osrmStations.map((s) => '${s.longitude},${s.latitude}').join(';');

      List<RadioStation> orderedStations;
      if (middles.isEmpty) {
        orderedStations = [start, end];
      } else {
        final tableResp = await http
            .get(Uri.parse('https://router.project-osrm.org/table/v1/driving/$coordsStr?annotations=duration'))
            .timeout(const Duration(seconds: 30));
        if (tableResp.statusCode != 200) throw Exception('OSRM 서버 오류');
        final tableData = json.decode(tableResp.body) as Map<String, dynamic>;
        final durations = (tableData['durations'] as List)
            .map((row) => (row as List).map((v) => (v as num).toDouble()).toList())
            .toList();

        // Nearest Neighbor: start 고정(index 0), middles 최적화, end는 마지막에 append
        int current = 0;
        final visited = List.filled(osrmStations.length, false);
        visited[0] = true;
        final order = <RadioStation>[start];
        for (int step = 0; step < middles.length; step++) {
          double best = double.infinity;
          int next = -1;
          for (int j = 1; j < osrmStations.length; j++) {
            if (!visited[j] && durations[current][j] < best) {
              best = durations[current][j];
              next = j;
            }
          }
          visited[next] = true;
          order.add(osrmStations[next]);
          current = next;
        }
        order.add(end);
        orderedStations = order;
      }

      final routeCoords = orderedStations.map((s) => '${s.longitude},${s.latitude}').join(';');
      final routeResp = await http
          .get(Uri.parse('https://router.project-osrm.org/route/v1/driving/$routeCoords?overview=full&geometries=geojson'))
          .timeout(const Duration(seconds: 30));

      List<List<double>>? polylineCoords;
      if (routeResp.statusCode == 200) {
        final routeData = json.decode(routeResp.body) as Map<String, dynamic>;
        final routes = routeData['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final coordsList = ((routes[0] as Map)['geometry'] as Map?)?['coordinates'] as List?;
          if (coordsList != null) {
            polylineCoords = coordsList
                .map((c) => [(c as List)[0] as double, c[1] as double])
                .toList();
          }
        }
      }

      setState(() {
        _polygonRouteResult = orderedStations;
        _polygonPhase = _PolygonPhase.result;
      });
      _mapKey.currentState?.drawRouteOverlay(orderedStations: orderedStations, polylineCoords: polylineCoords);
    } catch (e) {
      setState(() => _polygonPhase = _PolygonPhase.selectEndpoints);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('경로 계산 실패: $e'), backgroundColor: Colors.red));
    }
  }

  void _resetPolygonMode() {
    setState(() {
      _polygonPhase = _PolygonPhase.idle;
      _polygonVertexCount = 0;
      _polygonStations = [];
      _polygonDupeCount = 0;
      _polygonStart = null;
      _polygonEnd = null;
      _polygonRouteResult = null;
    });
    _mapKey.currentState?.clearPolygonOverlay();
    _mapKey.currentState?.clearRouteOverlay();
  }

  // ── 폴리곤 경로 UI ────────────────────────────────────────────────────

  Widget _buildPolygonEntryButton() {
    return _mapFloatingButton(
      icon: Icons.polyline,
      color: const Color(0xFFE53935),
      onTap: () {
        setState(() {
          _polygonPhase = _PolygonPhase.drawing;
          _polygonVertexCount = 0;
        });
        _mapKey.currentState?.startPolygonDraw();
      },
    );
  }

  Widget _buildPolygonPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 8, offset: const Offset(0, -2))],
      ),
      child: switch (_polygonPhase) {
        _PolygonPhase.drawing => _buildPolygonDrawingPanel(),
        _PolygonPhase.selectEndpoints => _buildPolygonSelectPanel(),
        _PolygonPhase.calculating => _buildPolygonCalculatingPanel(),
        _PolygonPhase.result => _buildPolygonResultPanel(),
        _ => const SizedBox.shrink(),
      },
    );
  }

  Widget _buildPolygonDrawingPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: const Color(0xFFE53935),
          child: Row(
            children: [
              const Icon(Icons.polyline, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _polygonVertexCount == 0
                      ? '지도를 클릭해 구역 꼭짓점 추가'
                      : '꼭짓점 $_polygonVertexCount개 추가됨 (최소 3개)',
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
              TextButton(
                onPressed: () {
                  _mapKey.currentState?.cancelPolygonDraw();
                  _resetPolygonMode();
                },
                style: TextButton.styleFrom(foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('취소', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _polygonVertexCount >= 3
                  ? () => _mapKey.currentState?.finishPolygonDraw()
                  : null,
              icon: const Icon(Icons.check, size: 18),
              label: const Text('구역 확정'),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE53935), foregroundColor: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPolygonSelectPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: const Color(0xFFE53935),
          child: Row(
            children: [
              const Icon(Icons.place, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('출발·도착 선택 — ${_polygonStations.length}개 국소',
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                    if (_polygonDupeCount > 0)
                      Text('겹친 위치 $_polygonDupeCount건 자동처리',
                          style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  ],
                ),
              ),
              TextButton(
                onPressed: _resetPolygonMode,
                style: TextButton.styleFrom(foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('닫기', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        Container(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: _polygonStations.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = _polygonStations[i];
              final isStart = _polygonStart?.id == s.id;
              final isEnd = _polygonEnd?.id == s.id;
              return ListTile(
                dense: true,
                title: Text(s.displayName, style: const TextStyle(fontSize: 13)),
                subtitle: Text(s.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _endpointChip('출발', isStart, Colors.green, () {
                      setState(() { _polygonStart = isStart ? null : s; if (_polygonEnd?.id == s.id) _polygonEnd = null; });
                    }),
                    const SizedBox(width: 4),
                    _endpointChip('도착', isEnd, Colors.red, () {
                      setState(() { _polygonEnd = isEnd ? null : s; if (_polygonStart?.id == s.id) _polygonStart = null; });
                    }),
                  ],
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
              onPressed: _polygonStart != null && _polygonEnd != null ? _calculatePolygonRoute : null,
              icon: const Icon(Icons.navigation, size: 18),
              label: const Text('최적 경로 계산'),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE53935), foregroundColor: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _endpointChip(String label, bool selected, Color color, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? color : color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color, width: 1),
        ),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: selected ? Colors.white : color)),
      ),
    );
  }

  Widget _buildPolygonCalculatingPanel() {
    return const Padding(
      padding: EdgeInsets.all(20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text('최적 경로 계산 중...', style: TextStyle(fontSize: 13)),
        ],
      ),
    );
  }

  Widget _buildPolygonResultPanel() {
    final stations = _polygonRouteResult!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: const Color(0xFFE53935),
          child: Row(
            children: [
              const Icon(Icons.alt_route, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text('최적 경로 — ${stations.length}개 국소',
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
              ),
              TextButton(
                onPressed: _resetPolygonMode,
                style: TextButton.styleFrom(foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 8), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('닫기', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
        Container(
          constraints: const BoxConstraints(maxHeight: 180),
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: stations.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = stations[i];
              final isFirst = i == 0;
              final isLast = i == stations.length - 1;
              final color = isFirst ? Colors.green : (isLast ? Colors.red : const Color(0xFFE53935));
              final tag = isFirst ? '출발' : (isLast ? '도착' : '${i + 1}');
              return ListTile(
                dense: true,
                leading: CircleAvatar(radius: 12, backgroundColor: color, child: Text(tag, style: const TextStyle(color: Colors.white, fontSize: 10))),
                title: Text(s.displayName, style: const TextStyle(fontSize: 13)),
                subtitle: Text(s.address, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => setState(() {
                    _polygonPhase = _PolygonPhase.selectEndpoints;
                    _polygonRouteResult = null;
                    _mapKey.currentState?.clearRouteOverlay();
                  }),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('다시 선택', style: TextStyle(fontSize: 13)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _savingBasket ? null : () => _showSaveBasketDialog(stations),
                  icon: _savingBasket
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.bookmark_add, size: 16),
                  label: const Text('담기', style: TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE53935), foregroundColor: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showSaveBasketDialog(List<RadioStation> orderedStations) async {
    // 주차/조 후보 추출 (국소들이 속한 주차·조 다수결)
    final weekCounts = <String, int>{};
    final joCounts = <String, int>{};
    for (final s in orderedStations) {
      final item = _assignedItems.firstWhere(
        (i) => (i['허가번호'] as String? ?? '').trim() == s.licenseNumber.trim(),
        orElse: () => {},
      );
      final w = (item['수검예정주차'] as String? ?? '').trim();
      final j = (item['조'] as String? ?? '').trim();
      if (w.isNotEmpty) weekCounts[w] = (weekCounts[w] ?? 0) + 1;
      if (j.isNotEmpty) joCounts[j] = (joCounts[j] ?? 0) + 1;
    }
    String defaultWeek = weekCounts.isEmpty ? (_selectedWeek.isNotEmpty ? _selectedWeek : '') : (weekCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key);
    String defaultJo = joCounts.isEmpty ? (_selectedJo.isNotEmpty ? _selectedJo : '') : (joCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key);

    final now = DateTime.now();
    final defaultTitle = '${now.month}/${now.day}';
    final titleCtrl = TextEditingController(text: defaultTitle);

    final weekOptions = _weekOptions.isNotEmpty ? _weekOptions : (defaultWeek.isNotEmpty ? [defaultWeek] : []);
    final joSet = _assignedItems.map((i) => (i['조'] as String? ?? '').trim()).where((v) => v.isNotEmpty).toSet().toList()..sort();
    final joOptions = joSet.isNotEmpty ? joSet : (defaultJo.isNotEmpty ? [defaultJo] : []);

    String selWeek = weekOptions.contains(defaultWeek) ? defaultWeek : (weekOptions.isNotEmpty ? weekOptions.first : defaultWeek);
    String selJo = joOptions.contains(defaultJo) ? defaultJo : (joOptions.isNotEmpty ? joOptions.first : defaultJo);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('경로 담기', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('제목', style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              TextField(
                controller: titleCtrl,
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              if (weekOptions.isNotEmpty) ...[
                const Text('주차', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                DropdownButtonFormField<String>(
                  initialValue: weekOptions.contains(selWeek) ? selWeek : weekOptions.first,
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                  items: weekOptions.map<DropdownMenuItem<String>>((w) => DropdownMenuItem<String>(value: w, child: Text(w, style: const TextStyle(fontSize: 13)))).toList(),
                  onChanged: (v) => setDlg(() => selWeek = v ?? selWeek),
                ),
                const SizedBox(height: 12),
              ],
              if (joOptions.isNotEmpty) ...[
                const Text('조', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                DropdownButtonFormField<String>(
                  initialValue: joOptions.contains(selJo) ? selJo : joOptions.first,
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                  items: joOptions.map<DropdownMenuItem<String>>((j) => DropdownMenuItem<String>(value: j, child: Text(j, style: const TextStyle(fontSize: 13)))).toList(),
                  onChanged: (v) => setDlg(() => selJo = v ?? selJo),
                ),
              ],
              const SizedBox(height: 8),
              Text('${orderedStations.length}개 국소 순서 저장', style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE53935), foregroundColor: Colors.white),
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _savingBasket = true);
    try {
      final entry = await _basketSvc.save(
        title: titleCtrl.text.trim().isEmpty ? defaultTitle : titleCtrl.text.trim(),
        weekLabel: selWeek,
        joLabel: selJo,
        stations: orderedStations.map((s) => BasketStation(id: s.id, name: s.displayName, lat: s.latitude ?? 0, lng: s.longitude ?? 0)).toList(),
      );
      if (mounted) {
        setState(() {
          _routeBaskets.insert(0, entry);
          _savingBasket = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('경로가 "${entry.title}"으로 저장됐습니다.'), backgroundColor: Colors.green));
        _resetPolygonMode();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _savingBasket = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('저장 실패: $e'), backgroundColor: Colors.red));
      }
    }
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
