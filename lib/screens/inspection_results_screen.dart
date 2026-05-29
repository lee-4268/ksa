import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../widgets/app_loader.dart';
import '../widgets/progress_dialog.dart';
import 'dashboard_screen.dart';

/// 실적 관리 대시보드 (v6 PDF 리포트 레이아웃 재현)
class InspectionResultsScreen extends StatefulWidget {
  const InspectionResultsScreen({super.key});

  @override
  State<InspectionResultsScreen> createState() =>
      _InspectionResultsScreenState();
}

class _InspectionResultsScreenState extends State<InspectionResultsScreen>
    with SingleTickerProviderStateMixin {
  static const Color _primary = Color(0xFFE53935);
  static const Color _green = Color(0xFF4CAF50);
  static const Color _blue = Color(0xFF2196F3);
  static const Color _orange = Color(0xFFFF9800);

  static const List<Color> _donutColors = [
    Color(0xFFE53935),
    Color(0xFF2196F3),
    Color(0xFFFFC107),
    Color(0xFF4CAF50),
    Color(0xFF9C27B0),
    Color(0xFF607D8B),
  ];

  static const List<String> _monthTabs = [
    'ACC 누적', '1월', '2월', '3월', '4월', '5월', '6월',
    '7월', '8월', '9월', '10월', '11월', '12월',
  ];

  static const List<String> _regionOrder = [
    '강남', '강북', '인천', '경기', '경남', '경북', '서부', '충청', '강원',
  ];

  late final InspectionService _svc;
  late TabController _tabCtrl;

  int _year = DateTime.now().year;
  bool _loading = false;
  String? _error;
  bool _uploading = false;

  // 대시보드 데이터
  Map<String, dynamic> _dashboard = {};
  Map<String, dynamic> _monthlyData = {};
  Map<String, dynamic> _analysis = {};
  // 장비 Type별 차트는 본부/팀 선택과 무관하게 전체 데이터 유지
  Map<String, dynamic> _analysisAll = {};
  Map<String, dynamic> _weeklyTrend = {};
  Map<String, dynamic> _regionWeeklyTrend = {};
  List<Map<String, dynamic>> _reportLines = [];

  String _selectedRegion = '';
  String _selectedTeam = ''; // 본부 안에서 선택된 팀(ons팀, 예: '평택품질개선팀')
  String _failureChartTeam = ''; // 불합격 항목별 비율 차트만 별도로 필터링하는 팀
  List<String> _regionTeams = []; // 현재 본부의 팀 이름 목록 (불합격 항목별 토글용)
  int _selectedQuarter = 0; // 0=전체, 1=1Q, 2=2Q, 3=3Q, 4=4Q
  late bool _isAdmin;

  // 테이블 정렬

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: _monthTabs.length, vsync: this);
    _tabCtrl.addListener(_onTabChanged);
    final auth = context.read<AuthService>();
    _svc = InspectionService()..setAuthToken(auth.authToken);
    _isAdmin = auth.isSuperAdmin || auth.isDivisionAdmin;
    _loadData();
  }

  @override
  void dispose() {
    _tabCtrl.removeListener(_onTabChanged);
    _tabCtrl.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabCtrl.indexIsChanging) {
      _loadData();
    }
  }

  Future<void> _loadRegionTeams(String region) async {
    try {
      final items = await _svc.getProgressByTeam(_year, region);
      if (!mounted) return;
      setState(() {
        _regionTeams = items
            .map((e) => (e['팀'] as String?) ?? '')
            .where((s) => s.isNotEmpty)
            .toList()
          ..sort();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _regionTeams = []);
    }
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rgn = _selectedRegion;
      final tm = _selectedTeam;
      // 본부 선택 + 팀 미선택 → 본부 안 팀별 분해 (groupBy=team)
      final groupBy = rgn.isNotEmpty && tm.isEmpty ? 'team' : '';
      if (_tabCtrl.index == 0) {
        final dash = await _svc.getResultsDashboard(_year,
            region: rgn, team: tm, groupBy: groupBy);
        if (!mounted) return;
        setState(() {
          _dashboard = dash;
          _monthlyData = dash;
        });
      } else {
        final month = _tabCtrl.index.toString();
        final data = await _svc.getResultsMonthly(_year, month,
            region: rgn, team: tm, groupBy: groupBy);
        if (!mounted) return;
        if (_dashboard.isEmpty) {
          final dash = await _svc.getResultsDashboard(_year,
              region: rgn, team: tm, groupBy: groupBy);
          if (!mounted) return;
          _dashboard = dash;
        }
        setState(() {
          _monthlyData = data;
        });
      }
      // 차트 데이터 (별도 try-catch)
      // analysis만은 차트별 토글(_failureChartTeam)이 있으면 그 값을 우선 사용
      final analysisTeam = _failureChartTeam.isNotEmpty ? _failureChartTeam : tm;
      try {
        final results = await Future.wait([
          _svc.getResultsAnalysis(_year, region: rgn, team: analysisTeam),
          _svc.getResultsWeeklyTrend(_year, region: rgn, team: tm),
          _svc.getResultsSummaryReport(_year, region: rgn, team: tm),
          // weekly-trend-by-region: region 지정 시 자동으로 그 본부 팀별 trend 반환
          _svc.getResultsWeeklyTrendByRegion(_year, region: rgn),
          // 장비Type별 차트용 — 본부/팀 무관 전체 분석. region/team 둘 다 비어있는 응답이
          // 이미 _analysis로 들어오는 경우(필터 미적용) 중복 호출 피하려고 조건부.
          if (rgn.isNotEmpty || tm.isNotEmpty)
            _svc.getResultsAnalysis(_year)
          else
            Future.value(<String, dynamic>{}),
        ]);
        if (!mounted) return;
        setState(() {
          _analysis = results[0];
          _weeklyTrend = results[1];
          final report = results[2];
          _reportLines =
              List<Map<String, dynamic>>.from(report['lines'] ?? []);
          _regionWeeklyTrend = results[3];
          // 필터 없을 땐 _analysis가 곧 전체 데이터, 있을 땐 별도 호출 결과 사용
          _analysisAll = (rgn.isNotEmpty || tm.isNotEmpty)
              ? results[4]
              : results[0];
        });
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── 파일 업로드 ──

  Future<FilePickerResult?> _tryPickFile() async {
    try {
      return await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
        allowMultiple: true,
        withData: true,
      );
    } catch (e) {
      debugPrint('FilePicker 오류: $e');
      return null;
    }
  }

  Future<void> _pickAndUpload() async {
    final stopwatch = Stopwatch()..start();
    var result = await _tryPickFile();
    stopwatch.stop();

    if (result == null && stopwatch.elapsedMilliseconds < 500) {
      await Future.delayed(const Duration(milliseconds: 300));
      result = await _tryPickFile();
    }
    if (result == null || result.files.isEmpty) return;

    final files = result.files.where((f) => f.bytes != null).toList();
    if (files.isEmpty) {
      if (mounted) {
        final dialog = ProgressDialog(context);
        dialog.show(message: '파일 읽기 실패');
        await dialog.error(message: '파일을 읽을 수 없습니다.\n파일을 다시 선택해주세요.');
      }
      return;
    }

    final dialog = ProgressDialog(context);
    setState(() => _uploading = true);
    int totalCount = 0;
    int successCount = 0;
    final errors = <String>[];

    try {
      dialog.show(message: '업로드 중...\n(1/${files.length})\n${files.first.name}');
      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        try {
          final resp = await _svc.uploadResults(
            Uint8List.fromList(file.bytes!),
            file.name,
          );
          totalCount += (resp['count'] as int?) ?? 0;
          successCount++;
        } catch (e) {
          errors.add('${file.name}: $e');
        }
      }
      if (!mounted) return;
      if (errors.isEmpty) {
        await dialog.complete(message: '업로드 완료\n${files.length}개 파일\n$totalCount건 처리');
      } else {
        await dialog.error(message: '$successCount/${files.length}개 성공\n실패: ${errors.length}개');
      }
      _loadData();
    } catch (e) {
      if (!mounted) return;
      await dialog.error(message: '업로드 실패');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

// ── Excel 다운로드 ──

static const _divisions = ['', '강남', '강북', '인천', '경기', '경남', '경북', '서부', '충청', '강원'];

Future<void> _downloadExcel() async {
  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) {
      // 내부 상태 관리를 위한 변수들
      final Set<String> selDivisions = {};
      final Set<String> selMonths = {};
      final Set<String> selWeeks = {};
      List<String> weekOptions = [];
      bool weekLoading = false;

      final months = List.generate(12, (i) => '${i + 1}월');
      final activeDivisions = _divisions.where((d) => d.isNotEmpty).toList();

      return StatefulBuilder(builder: (ctx, setS) {
        
        // 주차 데이터를 비동기로 불러오는 함수
        Future<void> loadWeeks() async {
          setS(() { 
            weekLoading = true; 
            selWeeks.clear(); 
            weekOptions = []; 
          });
          
          final monthParam = selMonths.length == 1 ? selMonths.first : '';
          final regionParam = selDivisions.length == 1 ? selDivisions.first : '';
          
          try {
            final ws = await _svc.getResultsWeeks(_year, month: monthParam, region: regionParam);
            setS(() { 
              weekOptions = ws;
              weekLoading = false; 
            });
          } catch (e) {
            setS(() => weekLoading = false);
          }
        }

        // 공통 섹션 헤더 (라벨 + 전체선택 버튼)
        Widget sectionHeader({
          required String title, 
          required bool isAllSelected, 
          required VoidCallback onToggle
        }) {
          return Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black87)),
                TextButton(
                  onPressed: onToggle,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    isAllSelected ? '전체 해제' : '전체 선택',
                    style: TextStyle(fontSize: 12, color: _primary, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          );
        }

        // 세련된 커스텀 칩 위젯
        Widget selectChip(String label, bool isSelected, VoidCallback onTap) {
          return InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? _primary.withOpacity(0.08) : Colors.grey.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected ? _primary : Colors.grey.shade300,
                  width: isSelected ? 1.5 : 1,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: isSelected ? _primary : Colors.black87,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          );
        }

        return AlertDialog(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 10),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: _green.withOpacity(0.1), borderRadius: BorderRadius.circular(10)),
                child: Icon(Icons.description_outlined, color: _green, size: 20),
              ),
              const SizedBox(width: 12),
              const Text('Excel 다운로드 옵션', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ],
          ),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // --- 본부 선택 섹션 ---
                  sectionHeader(
                    title: '본부 지역',
                    isAllSelected: selDivisions.length == activeDivisions.length && activeDivisions.isNotEmpty,
                    onToggle: () {
                      setS(() {
                        if (selDivisions.length == activeDivisions.length) {
                          selDivisions.clear();
                        } else {
                          selDivisions.addAll(activeDivisions);
                        }
                        selWeeks.clear(); weekOptions = [];
                      });
                    },
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: activeDivisions.map((d) {
                      final sel = selDivisions.contains(d);
                      return selectChip(d, sel, () {
                        setS(() {
                          if (sel) selDivisions.remove(d); else selDivisions.add(d);
                          selWeeks.clear(); weekOptions = [];
                        });
                      });
                    }).toList(),
                  ),
                  const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Divider(height: 1)),

                  // --- 월 선택 섹션 ---
                  sectionHeader(
                    title: '해당 월',
                    isAllSelected: selMonths.length == months.length,
                    onToggle: () {
                      setS(() {
                        if (selMonths.length == months.length) {
                          selMonths.clear();
                        } else {
                          selMonths.addAll(months);
                        }
                        selWeeks.clear(); weekOptions = [];
                      });
                      if (selMonths.isNotEmpty) loadWeeks();
                    },
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: months.map((m) {
                      final sel = selMonths.contains(m);
                      return selectChip(m, sel, () {
                        setS(() {
                          if (sel) selMonths.remove(m); else selMonths.add(m);
                          selWeeks.clear(); weekOptions = [];
                        });
                        if (selMonths.isNotEmpty) loadWeeks();
                      });
                    }).toList(),
                  ),
                  const Padding(padding: EdgeInsets.symmetric(vertical: 12), child: Divider(height: 1)),

                  // --- 주차 선택 섹션 ---
                  sectionHeader(
                    title: '주차 선택',
                    isAllSelected: weekOptions.isNotEmpty && selWeeks.length == weekOptions.length,
                    onToggle: () {
                      if (weekOptions.isEmpty) return;
                      setS(() {
                        if (selWeeks.length == weekOptions.length) {
                          selWeeks.clear();
                        } else {
                          selWeeks.addAll(weekOptions);
                        }
                      });
                    },
                  ),
                  if (weekLoading)
                    Center(child: Padding(padding: const EdgeInsets.all(20), child: AppLoader()))
                  else if (weekOptions.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(12)),
                      child: Text('월을 선택하면 주차 정보가 표시됩니다.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: weekOptions.map((w) {
                        final sel = selWeeks.contains(w);
                        return selectChip(w, sel, () => setS(() {
                          if (sel) selWeeks.remove(w); else selWeeks.add(w);
                        }));
                      }).toList(),
                    ),
                ],
              ),
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          actions: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Colors.grey.shade300),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text('취소', style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, {
                      'regions': selDivisions.toList(),
                      'months': selMonths.toList(),
                      'weeks': selWeeks.toList(),
                    }),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _green,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('다운로드 시작', style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        );
      });
    },
  );

  // 리턴값이 없으면 중단
  if (result == null) return;

  // ── 이후 엑셀 다운로드 로직 (기존 유지) ──
  final dialog = ProgressDialog(context);
  dialog.show(message: 'Excel 다운로드\n준비 중...');
  try {
    final regions = (result['regions'] as List<String>? ?? []);
    final months = (result['months'] as List<String>? ?? []);
    final weeks = (result['weeks'] as List<String>? ?? []);
    
    final bytes = await _svc.exportResultsXlsx(_year, regions: regions, weeks: weeks);
    if (!mounted) return;

    final fileSuffix = [
      if (regions.isNotEmpty) regions.join('+'),
      if (months.isNotEmpty) months.join('+'),
      if (weeks.isNotEmpty) weeks.join('+'),
      if (regions.isEmpty && months.isEmpty && weeks.isEmpty) '전체',
    ].join('_');

    final blob = html.Blob([bytes], 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement()
      ..href = url
      ..download = '실적_결과장_${_year}_$fileSuffix.xlsx'
      ..style.display = 'none';
    html.document.body?.children.add(anchor);
    anchor.click();
    html.document.body?.children.remove(anchor);
    html.Url.revokeObjectUrl(url);

    await dialog.complete(message: '다운로드 완료');
  } catch (e) {
    if (!mounted) return;
    await dialog.error(message: '다운로드 실패');
  }
}


  // ── 숫자 포맷 ──

  String _fmt(dynamic v) {
    if (v == null) return '-';
    final n = v is num ? v : num.tryParse(v.toString()) ?? 0;
    if (n is double || (n is int && n.abs() >= 1000)) {
      return n.toInt().toString().replaceAllMapped(
          RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    }
    return n.toString();
  }

  String _pct(dynamic v) {
    if (v == null) return '-';
    final n = v is num ? v.toDouble() : double.tryParse(v.toString()) ?? 0;
    final pct = n <= 1.0 ? n * 100 : n;
    return '${pct.toStringAsFixed(1)}%';
  }

  double _toDouble(dynamic v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  double _asPercent(dynamic v) {
    final raw = _toDouble(v);
    return raw <= 1.0 ? raw * 100 : raw;
  }

  String _regionName(Map<String, dynamic> r, {String fallback = '-'}) {
    return r['name'] ?? r['본부'] ?? r['region'] ?? fallback;
  }

  /// 팀명 단축: '평택품질개선팀' → '평택'
  String _shortTeamName(String name) =>
      name.endsWith('품질개선팀') ? name.substring(0, name.length - 5) : name;

  /// 합격율 표시/판정용 통일 값: 소숫점 둘째 자리에서 버림 (1자리 표시).
  /// 표시 텍스트("98.5%")와 임계값 비교가 일치하도록 화면 전체에서 이 값으로 통일.
  double _truncTo1(double v) => (v * 10).floorToDouble() / 10;

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF5F6FA),
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 40),
        child: Column(
          children: [
            _buildActionBar(),
            _buildSummaryCards(),
            // 조건부 children은 Column의 자식 위치 인덱스를 바꿔
            // 아래 DashboardScreen이 unmount/remount되는 race condition을 유발하므로,
            // 빈 상태에서도 SizedBox.shrink()로 자리를 유지.
            _reportLines.isNotEmpty
                ? _buildSummaryReport()
                : const SizedBox.shrink(),
            (_selectedRegion.isNotEmpty || _selectedTeam.isNotEmpty)
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                    child: Row(children: [
                      Icon(Icons.filter_alt, size: 16, color: _primary),
                      const SizedBox(width: 6),
                      Text(
                        _selectedTeam.isNotEmpty
                            ? '$_selectedRegion · $_selectedTeam 필터 적용 중'
                            : '$_selectedRegion 본부 필터 적용 중',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFE53935)),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _selectedRegion = '';
                            _selectedTeam = '';
                            _failureChartTeam = '';
                          });
                          _loadData();
                        },
                        child: const Text('전체 보기', style: TextStyle(fontSize: 12)),
                      ),
                    ]),
                  )
                : const SizedBox.shrink(),
                  // 전국 수검 현황 지도 + 본부 상세
                  LayoutBuilder(
                    builder: (context, cst) {
                      if (cst.maxWidth < 700) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: SizedBox(
                          height: 550,
                          child: DashboardScreen(
                            showStats: false,
                            selectedRegion: _selectedRegion,
                            selectedTeam: _selectedTeam,
                            onRegionSelected: (region) {
                              if (_selectedRegion != region || _selectedTeam.isNotEmpty) {
                                setState(() {
                                  _selectedRegion = region;
                                  _selectedTeam = '';
                                  _failureChartTeam = '';
                                  _regionTeams = [];
                                });
                                _loadData();
                                if (region.isNotEmpty) _loadRegionTeams(region);
                              }
                            },
                            onTeamSelected: (team) {
                              if (_selectedTeam != team) {
                                setState(() => _selectedTeam = team);
                                _loadData();
                              }
                            },
                          ),
                        ),
                      );
                    },
                  ),
            _buildBody(),
          ],
        ),
      ),
    );
  }

  // ── 연도 선택 ──

  Widget _buildYearSelector() {
    final now = DateTime.now().year;
    final years = [now - 1, now, now + 1];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: years.map((y) {
        final selected = _year == y;
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: ChoiceChip(
            label: Text('$y',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? Colors.white
                        : const Color(0xFF374151))),
            selected: selected,
            selectedColor: _primary,
            backgroundColor: Colors.grey.shade100,
            side: BorderSide.none,
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            onSelected: (v) {
              if (v && _year != y) {
                setState(() => _year = y);
                _loadData();
              }
            },
          ),
        );
      }).toList(),
    );
  }

  // ── 액션 바 (헤더 대체 — 업로드/다운로드 + 날짜) ──

  Widget _buildActionBar() {
    return LayoutBuilder(builder: (context, cst) {
      final isMobile = cst.maxWidth < 600;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: Row(
          children: [
            _buildLastUploadBadge(),
            const Spacer(),
            if (_isAdmin) ...[
              _uploading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : isMobile
                      ? IconButton(
                          onPressed: _pickAndUpload,
                          icon: const Icon(Icons.upload_file, size: 18),
                          color: _primary,
                          tooltip: '결과장 업로드',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        )
                      : TextButton.icon(
                          onPressed: _pickAndUpload,
                          icon: const Icon(Icons.upload_file, size: 16),
                          label: const Text('결과장 업로드', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                          style: TextButton.styleFrom(
                            foregroundColor: _primary,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          ),
                        ),
              const SizedBox(width: 4),
            ],
            isMobile
                ? IconButton(
                    onPressed: _downloadExcel,
                    icon: const Icon(Icons.file_download, size: 18),
                    color: _green,
                    tooltip: 'Excel 다운로드',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  )
                : TextButton.icon(
                    onPressed: _downloadExcel,
                    icon: const Icon(Icons.file_download, size: 16),
                    label: const Text('Excel 다운로드', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    style: TextButton.styleFrom(
                      foregroundColor: _green,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    ),
                  ),
          ],
        ),
      );
    });
  }

  // ── 최근 업로드 배지 ──

  Widget _buildLastUploadBadge() {
    final lastUpload = (_dashboard['last_upload'] as String? ?? '').trim();
    if (lastUpload.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.upload_file_outlined, size: 13, color: Color(0xFF9CA3AF)),
        const SizedBox(width: 4),
        Text(
          '최근 업로드: $lastUpload',
          style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
        ),
        const SizedBox(width: 12),
      ],
    );
  }


  // ── 요약 카드 ──

  Widget _buildSummaryCards() {
    final t = (_dashboard['total'] as Map<String, dynamic>?) ?? {};
    final total = t['수검국소'] ?? 0;
    final perfRate = t['성능합격율'] ?? 0;
    final docRate = t['서류합격율'] ?? 0;
    final tgt = (_dashboard['target'] as Map<String, dynamic>?) ?? {};
    final targetTotal = tgt['전체'] ?? 0;
    final progress = (targetTotal > 0 && total is num && targetTotal is num)
        ? total / targetTotal
        : 0;

    final cards = [
      _summaryCard('수검국소', _fmt(total), Icons.location_on, _blue),
      _summaryCard('성능합격율', _pct(perfRate), Icons.check_circle, _green, target: 'SLA 98.5%'),
      _summaryCard('서류합격율', _pct(docRate), Icons.description, _orange, target: 'SLA 85.5%'),
      _summaryCard('진도율', _pct(progress), Icons.trending_up, _primary),
    ];

    return LayoutBuilder(builder: (context, cst) {
      final isMobile = cst.maxWidth < 600;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: isMobile
            ? Column(children: [
                Row(children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 10),
                  Expanded(child: cards[1]),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: cards[2]),
                  const SizedBox(width: 10),
                  Expanded(child: cards[3]),
                ]),
              ])
            : Row(children: [
                Expanded(child: cards[0]),
                const SizedBox(width: 10),
                Expanded(child: cards[1]),
                const SizedBox(width: 10),
                Expanded(child: cards[2]),
                const SizedBox(width: 10),
                Expanded(child: cards[3]),
              ]),
      );
    });
  }

  Widget _summaryCard(
      String label, String value, IconData icon, Color color, {String? target}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 2)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 컬러 상단 스트라이프
          Container(height: 3, color: color),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, size: 20, color: color),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(label,
                              style: const TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF6B7280),
                                  fontWeight: FontWeight.w500)),
                          if (target != null)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF3F4F6),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: const Color(0xFFD1D5DB)),
                              ),
                              child: Text(target,
                                  style: const TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF6B7280))),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 400),
                        transitionBuilder: (child, anim) => FadeTransition(
                          opacity: anim,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 0.3),
                              end: Offset.zero,
                            ).animate(anim),
                            child: child,
                          ),
                        ),
                        child: Text(value,
                            key: ValueKey(value),
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                                color: color,
                                letterSpacing: -0.5)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Summary Report ──

  Widget _buildSummaryReport() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 타이틀
          Row(
            children: [
              Container(
                width: 3,
                height: 18,
                decoration: BoxDecoration(
                  color: _orange,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.summarize, size: 16, color: _orange),
              const SizedBox(width: 6),
              const Text('현황 리포트',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111827))),
            ],
          ),
          const SizedBox(height: 12),
          // 리포트 라인들
          ..._reportLines.map((line) {
            final type = line['type'] ?? 'detail';
            final text = line['text'] ?? '';
            if (type == 'header') {
              return Padding(
                padding: const EdgeInsets.only(bottom: 4, top: 8),
                child: Text(text,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827),
                        height: 1.5)),
              );
            } else if (type == 'perf_ok' || type == 'doc_ok') {
              return Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFDCFCE7),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle, size: 16, color: Color(0xFF16A34A)),
                          const SizedBox(width: 6),
                          Text(text,
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF16A34A),
                                  height: 1.5)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            } else if (type == 'perf_fail' || type == 'doc_fail') {
              return Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEE2E2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFFDC2626)),
                          const SizedBox(width: 6),
                          Text(text,
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFFDC2626),
                                  height: 1.5)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            } else if (type == 'highlight') {
              return Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Text(text,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFDC2626),
                        height: 1.6)),
              );
            } else if (type == 'sub') {
              return Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Text(text,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: Color(0xFF9CA3AF),
                        height: 1.6)),
              );
            } else {
              return Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text(text,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF374151),
                        height: 1.6)),
              );
            }
          }),
        ],
      ),
    );
  }

  // ── 탭 바 ──

  Widget _buildTabBar() {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: TabBar(
        controller: _tabCtrl,
        isScrollable: true,
        labelColor: _primary,
        unselectedLabelColor: const Color(0xFF6B7280),
        indicatorColor: _primary,
        indicatorWeight: 2.5,
        labelStyle:
            const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle:
            const TextStyle(fontSize: 13, fontWeight: FontWeight.w400),
        tabAlignment: TabAlignment.start,
        tabs: _monthTabs.map((t) => Tab(text: t)).toList(),
      ),
    );
  }

  // ── 본문 ──

  Widget _buildBody() {
    if (_loading) {
      return AppLoader.centered(color: _primary);
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Color(0xFF6B7280))),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('다시 시도'),
              style: TextButton.styleFrom(foregroundColor: _primary),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 900;
        final isMobile = constraints.maxWidth < 600;
        return Padding(
          padding: EdgeInsets.all(isMobile ? 8 : 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isWide) ...[
                // ── Row 1: 본부별 실적 + 파이차트 (좌) | 본부별 목표 대비 (우) ──
                // IntrinsicHeight(
                //   child: Row(
                //     crossAxisAlignment: CrossAxisAlignment.stretch,
                //     children: [
                //       Expanded(
                //         flex: 5,
                //         child: Column(children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildDataTable(),
                          const SizedBox(height: 14),
                        //   Expanded(child: _buildFailureDonutSection()),
                        // ]),
                          _buildFailureDonutSection(),
                        ],
                      ),
                  //     const SizedBox(width: 14),
                  //     Expanded(flex: 5, child: _buildRegionBarChart()),
                  //   ],
                  // ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(flex: 5, child: _buildRegionBarChart()),
                  ],
                ),
              ] else ...[
                // Single column layout for narrow screens
                _buildDataTable(),
                const SizedBox(height: 14),
                _buildFailureDonutSection(),
                const SizedBox(height: 14),
                _buildRegionBarChart(),
              ],
              const SizedBox(height: 14),

              // ── D. 성능 합격율 주별 Trend (combo chart) ──
              _buildWeeklyTrendCombo(),
              const SizedBox(height: 14),

              // ── E. Acc.담당별 주별 Trend (3x3 grid) ──
              _buildRegionWeeklyGrid(),
              const SizedBox(height: 14),

              // ── F. 장비 Type별 불합격 현황 크로스탭 + 요약 ──
              if (isWide)
                // Builder(
                //   builder: (context) {
                //     final summaryWidget = _buildEquipTypeSummary();
                //     return IntrinsicHeight(
                //       child: Row(
                //         crossAxisAlignment: CrossAxisAlignment.stretch,
                //         children: [
                //           Expanded(flex: 5, child: _buildEquipTypeCrosstab()),
                //           const SizedBox(width: 14),
                //           Expanded(flex: 5, child: summaryWidget),
                //         ],
                //       ),
                //     );
                //   },
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: _buildEquipTypeCrosstab(),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      flex: 5,
                      child: _buildEquipTypeSummary(),
                    ),
                  ],
                )
              else ...[
                _buildEquipTypeCrosstab(),
                const SizedBox(height: 14),
                _buildEquipTypeSummary(),
              ],
            ],
          ),
        );
      },
    );
  }

  // ── 차트 공통 섹션 래퍼 ──

  Widget _chartSection({
    required String title,
    required IconData icon,
    required Color iconColor,
    required Widget child,
  }) {
    return LayoutBuilder(builder: (context, cst) {
      final p = cst.maxWidth < 400 ? 10.0 : 16.0;
      return _chartSectionInner(title: title, icon: icon, iconColor: iconColor, child: child, padding: p);
    });
  }

  Widget _chartSectionInner({
    required String title,
    required IconData icon,
    required Color iconColor,
    required Widget child,
    double padding = 16,
  }) {
    return Container(
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
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
                width: 3,
                height: 16,
                decoration: BoxDecoration(
                  color: iconColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Icon(icon, size: 15, color: iconColor),
              const SizedBox(width: 5),
              Text(title,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111827))),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // A. 본부별 실적 테이블
  // ══════════════════════════════════════════════════════════

  // 컬럼 인덱스 → 정렬 키 매핑

  Widget _buildDataTable() {
    final regionData =
        List<Map<String, dynamic>>.from(_monthlyData['regions'] ?? []);
    Map<String, dynamic> totals =
        Map<String, dynamic>.from(_monthlyData['totals'] ?? {});

    if (totals.isEmpty && regionData.isNotEmpty) {
      double totalS = 0, comp = 0, adj = 0, cls = 0;
      double pPass = 0, pFail = 0, dPass = 0, dFail = 0;
      for (var r in regionData) {
        totalS += _toDouble(r['수검국소'] ?? r['total']);
        comp += _toDouble(r['완료'] ?? r['completed']);
        adj += _toDouble(r['시기조정'] ?? r['adjusted']);
        cls += _toDouble(r['폐국'] ?? r['폐'] ?? r['closed']);
        pPass += _toDouble(r['성능합격'] ?? r['perf_pass']);
        pFail += _toDouble(r['성능불합격'] ?? r['perf_fail']);
        dPass += _toDouble(r['서류합격'] ?? r['doc_pass']);
        dFail += _toDouble(r['서류불합격'] ?? r['doc_fail']);
      }
      totals = {
        'name': '합계',
        '수검국소': totalS, '완료': comp, '시기조정': adj, '폐국': cls,
        '성능합격': pPass, '성능불합격': pFail, '서류합격': dPass, '서류불합격': dFail,
        '성능합격율': (pPass + pFail) > 0 ? (pPass / (pPass + pFail)) : 0.0,
        '서류합격율': (dPass + dFail) > 0 ? (dPass / (dPass + dFail)) : 0.0,
      };
    }

    // _regionOrder 순서로 고정 정렬
    final sortedRegions = [...regionData]..sort((a, b) {
        final ai = _regionOrder.indexOf(_regionName(a, fallback: ''));
        final bi = _regionOrder.indexOf(_regionName(b, fallback: ''));
        return (ai < 0 ? 99 : ai).compareTo(bi < 0 ? 99 : bi);
      });

    final allRows = [...sortedRegions, if (totals.isNotEmpty) totals];

    DataColumn col(String label, {bool numeric = false}) =>
        DataColumn(
          label: Center(child: Text(label)),
          numeric: numeric,
          headingRowAlignment: MainAxisAlignment.center,
        );

    final byTeam = (_dashboard['groupBy'] as String?) == 'team' || _selectedTeam.isNotEmpty;
    return _chartSection(
      title: byTeam ? '팀별 현황' : '본부별 현황',
      icon: Icons.table_chart,
      iconColor: _blue,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(const Color(0xFFF3F4F6)),
          headingRowHeight: 38,
          dataRowMinHeight: 36,
          dataRowMaxHeight: 36,
          columnSpacing: 20,
          horizontalMargin: 12,
          border: TableBorder.all(
            color: const Color(0xFFE5E7EB),
            width: 0.5,
            borderRadius: BorderRadius.circular(8),
          ),
          headingTextStyle: const TextStyle(
              fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF374151)),
          dataTextStyle: const TextStyle(fontSize: 11, color: Color(0xFF111827)),
          columns: [
            col(byTeam ? '팀' : '본부'),
            col('수검국소', numeric: true),
            col('완료', numeric: true),
            col('시기조정', numeric: true),
            col('폐국', numeric: true),
            col('성능합격', numeric: true),
            col('성능불합', numeric: true),
            col('서류합격', numeric: true),
            col('서류불합', numeric: true),
            col('성능합격율', numeric: true),
            col('서류합격율', numeric: true),
          ],
          rows: allRows.asMap().entries.map((entry) {
            final i = entry.key;
            final r = entry.value;
            final isTotalRow = i == allRows.length - 1 && totals.isNotEmpty;
            final isEven = i.isEven;
            final perfRate = _truncTo1(_asPercent(r['성능합격율'] ?? r['perf_pass_rate']));
            final docRate = _truncTo1(_asPercent(r['서류합격율'] ?? r['doc_pass_rate']));
            final style = TextStyle(
              fontSize: 11,
              fontWeight: isTotalRow ? FontWeight.w700 : FontWeight.w400,
              color: const Color(0xFF111827),
            );

            return DataRow(
              color: WidgetStateProperty.all(
                isTotalRow
                    ? const Color(0xFFEEF2FF)
                    : isEven
                        ? Colors.white
                        : const Color(0xFFFAFAFB),
              ),
              cells: [
                DataCell(Center(child: Text(
                  byTeam && !isTotalRow
                      ? _shortTeamName(_regionName(r, fallback: '-'))
                      : _regionName(r, fallback: isTotalRow ? '합계' : '-'),
                  style: style))),
                DataCell(Center(child: Text(_fmt(r['수검국소'] ?? r['total']), style: style))),
                DataCell(Center(child: Text(_fmt(r['완료'] ?? r['completed']), style: style))),
                DataCell(Center(child: Text(_fmt(r['시기조정'] ?? r['adjusted']), style: style))),
                DataCell(Center(child: Text(_fmt(r['폐국'] ?? r['폐'] ?? r['closed']), style: style))),
                DataCell(Center(child: Text(_fmt(r['성능합격'] ?? r['perf_pass']), style: style))),
                DataCell(Center(child: Text(_fmt(r['성능불합격'] ?? r['perf_fail']), style: style))),
                DataCell(Center(child: Text(_fmt(r['서류합격'] ?? r['doc_pass']), style: style))),
                DataCell(Center(child: Text(_fmt(r['서류불합격'] ?? r['doc_fail']), style: style))),
                DataCell(Center(child: _buildRateCell(perfRate, isPerfRate: true, isBold: isTotalRow))),
                DataCell(Center(child: _buildRateCell(docRate, isPerfRate: false, isBold: isTotalRow))),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildRateCell(double rate,
      {required bool isPerfRate, required bool isBold}) {
    Color bgColor;
    Color textColor;

    if (isPerfRate) {
      if (rate >= 98.5) {
        bgColor = const Color(0xFFDCFCE7);
        textColor = const Color(0xFF16A34A);
      } else if (rate >= 95) {
        bgColor = const Color(0xFFFEF9C3);
        textColor = const Color(0xFFCA8A04);
      } else {
        bgColor = const Color(0xFFFEE2E2);
        textColor = const Color(0xFFDC2626);
      }
    } else {
      if (rate >= 85.5) {
        bgColor = const Color(0xFFDCFCE7);
        textColor = const Color(0xFF16A34A);
      } else if (rate >= 80) {
        bgColor = const Color(0xFFFEF9C3);
        textColor = const Color(0xFFCA8A04);
      } else {
        bgColor = const Color(0xFFFEE2E2);
        textColor = const Color(0xFFDC2626);
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${rate.toStringAsFixed(1)}%',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11,
          fontWeight: isBold ? FontWeight.w700 : FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // B. 불합격 항목별 비율 (성능/서류) — TWO DONUT CHARTS
  // ══════════════════════════════════════════════════════════

  Widget _buildFailureDonutSection() {
    final perfFailures =
        List<Map<String, dynamic>>.from(_analysis['성능불합격'] ?? []);
    final docFailures =
        List<Map<String, dynamic>>.from(_analysis['서류불합격'] ?? []);
    if (perfFailures.isEmpty && docFailures.isEmpty) {
      return const SizedBox.shrink();
    }

    return _chartSection(
      title: '불합격 항목별 비율 (성능/서류)',
      icon: Icons.pie_chart_outline,
      iconColor: _primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 본부 선택 시 그 본부의 팀명(지역명만) 토글 버튼
          if (_selectedRegion.isNotEmpty && _regionTeams.isNotEmpty) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _failureTeamChip(label: '전체', team: ''),
                for (final t in _regionTeams)
                  _failureTeamChip(label: _shortTeamName(t), team: t),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Expanded(
            child: _donutChart(
              label: '성능 불합격 사유',
              items: perfFailures,
              nameKey: '사유',
              countKey: '건수',
              ratioKey: '비율',
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _donutChart(
              label: '서류 불합격 사유',
              items: docFailures,
              nameKey: '사유',
              countKey: '건수',
              ratioKey: '비율',
            ),
          ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _failureTeamChip({required String label, required String team}) {
    final isSelected = _failureChartTeam == team;
    return ChoiceChip(
      label: Text(label,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isSelected ? Colors.white : const Color(0xFF374151))),
      selected: isSelected,
      selectedColor: _primary,
      backgroundColor: const Color(0xFFF3F4F6),
      side: BorderSide(
          color: isSelected ? _primary : const Color(0xFFE5E7EB)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
      onSelected: (v) {
        if (!v && isSelected) return;
        if (_failureChartTeam != team) {
          setState(() => _failureChartTeam = team);
          _loadFailureChartOnly();
        }
      },
    );
  }

  /// 불합격 차트(analysis API)만 따로 갱신 — 전체 페이지 재렌더 방지.
  Future<void> _loadFailureChartOnly() async {
    try {
      final data = await _svc.getResultsAnalysis(
        _year,
        region: _selectedRegion,
        team: _failureChartTeam,
      );
      if (!mounted) return;
      setState(() => _analysis = data);
    } catch (_) {
      // 실패 시 기존 데이터 유지
    }
  }

  Widget _donutChart({
    required String label,
    required List<Map<String, dynamic>> items,
    required String nameKey,
    required String countKey,
    required String ratioKey,
  }) {
    if (items.isEmpty) {
      return Column(
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF374151))),
          const SizedBox(height: 8),
          const Text('데이터 없음',
              style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
        ],
      );
    }

    // Top 5 + 기타
    final top5 = items.take(5).toList();
    final restCount = items.length > 5
        ? items.skip(5).fold<double>(0, (s, e) => s + _toDouble(e[countKey] ?? 0))
        : 0.0;

    final slices = <_DonutSlice>[];
    double total = 0;
    for (var i = 0; i < top5.length; i++) {
      final count = _toDouble(top5[i][countKey] ?? 0);
      total += count;
      slices.add(_DonutSlice(
        name: top5[i][nameKey]?.toString() ?? '-',
        value: count,
        color: _donutColors[i % _donutColors.length],
      ));
    }
    if (restCount > 0) {
      total += restCount;
      slices.add(_DonutSlice(
        name: '기타',
        value: restCount,
        color: const Color(0xFFBDBDBD),
      ));
    }

    return Column(
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF374151))),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, cst) {
            final donutSize = cst.maxWidth < 300 ? 120.0 : 160.0;
            return SizedBox(
              width: donutSize,
              height: donutSize,
              child: CustomPaint(
                painter: _DonutPainter(slices: slices, total: total),
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        ...slices.map((s) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: s.color,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.name,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF374151)),
                      overflow: TextOverflow.ellipsis),
                ),
                Text('${s.value.toInt()}건',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF6B7280))),
              ],
            ),
          );
        }),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════
  // C. 본부별 목표 대비 합격율 바 차트
  // ══════════════════════════════════════════════════════════

  Widget _buildRegionBarChart() {
    final regionData =
        List<Map<String, dynamic>>.from(_monthlyData['regions'] ?? []);
    if (regionData.isEmpty) return const SizedBox.shrink();

    final byTeam = (_monthlyData['groupBy'] as String?) == 'team' || _selectedTeam.isNotEmpty;
    // 본부 모드일 때만 _regionOrder 정렬, 팀 모드는 이름순
    if (!byTeam) {
      regionData.sort((a, b) {
        final ai = _regionOrder.indexOf(_regionName(a, fallback: ''));
        final bi = _regionOrder.indexOf(_regionName(b, fallback: ''));
        return (ai < 0 ? 99 : ai).compareTo(bi < 0 ? 99 : bi);
      });
    } else {
      regionData.sort((a, b) => _regionName(a).compareTo(_regionName(b)));
    }

    const double perfTarget = 98.5;
    const double docTarget = 85.5;
    const Color perfColor = Color(0xFF4CAF50);
    const Color docColor = Color(0xFF2196F3);
    const Color missColor = Color(0xFFE53935);

    // 전사 합격율: regions에서 직접 계산
    double pPass = 0, pFail = 0, dPass = 0, dFail = 0;
    for (var r in regionData) {
      pPass += _toDouble(r['성능합격'] ?? r['perf_pass']);
      pFail += _toDouble(r['성능불합격'] ?? r['perf_fail']);
      dPass += _toDouble(r['서류합격'] ?? r['doc_pass']);
      dFail += _toDouble(r['서류불합격'] ?? r['doc_fail']);
    }
    final totalPerf = _truncTo1((pPass + pFail) > 0 ? (pPass / (pPass + pFail)) * 100 : 0.0);
    final totalDoc = _truncTo1((dPass + dFail) > 0 ? (dPass / (dPass + dFail)) * 100 : 0.0);
    final totalPerfPass = totalPerf >= perfTarget;
    final totalDocPass = totalDoc >= docTarget;

    return _chartSection(
      title: byTeam ? '팀별 목표 대비 합격율' : '본부별 목표 대비 합격율',
      icon: Icons.assessment,
      iconColor: _blue,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 범례
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              _legendDot(perfColor, '성능 (목표 $perfTarget%)'),
              _legendDot(docColor, '서류 (목표 $docTarget%)'),
              _legendDot(missColor, '미달'),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 12, height: 2, color: const Color(0xFF333333)),
                  const SizedBox(width: 4),
                  const Text('목표', style: TextStyle(fontSize: 10, color: Color(0xFF6B7280))),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          // 본부별/팀별 바 차트 행
          ...regionData.map((r) {
            final rawName = _regionName(r);
            final name = byTeam ? _shortTeamName(rawName) : rawName;
            final perf = _truncTo1(_asPercent(r['성능합격율'] ?? r['perf_pass_rate']));
            final doc = _truncTo1(_asPercent(r['서류합격율'] ?? r['doc_pass_rate']));
            final perfPass = perf >= perfTarget;
            final docPass = doc >= docTarget;

            return Container(
              margin: const EdgeInsets.only(bottom: 22),
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    child: Text(name,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1F2937))),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      children: [
                        _regionBar(
                          value: perf,
                          color: perfPass ? perfColor : missColor,
                          targetPct: perfTarget / 100,
                          height: 20,
                        ),
                        const SizedBox(height: 4),
                        _regionBar(
                          value: doc,
                          color: docPass ? docColor : missColor,
                          targetPct: docTarget / 100,
                          height: 20,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 50,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${perf.toStringAsFixed(1)}%',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: perfPass ? perfColor : missColor)),
                        const SizedBox(height: 6),
                        Text('${doc.toStringAsFixed(1)}%',
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: docPass ? docColor : missColor)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
          // ── 합계 행 ──
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFEEF2FF),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFC7D2FE)),
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 36,
                  child: Text('합계',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1F2937))),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    children: [
                      _regionBar(
                        value: totalPerf,
                        color: totalPerfPass ? perfColor : missColor,
                        targetPct: perfTarget / 100,
                        height: 22,
                      ),
                      const SizedBox(height: 4),
                      _regionBar(
                        value: totalDoc,
                        color: totalDocPass ? docColor : missColor,
                        targetPct: docTarget / 100,
                        height: 22,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 50,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${totalPerf.toStringAsFixed(1)}%',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: totalPerfPass ? perfColor : missColor)),
                      const SizedBox(height: 6),
                      Text('${totalDoc.toStringAsFixed(1)}%',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: totalDocPass ? docColor : missColor)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 본부별 목표 대비 합격율 개별 바
  Widget _regionBar({
    required double value,
    required Color color,
    required double targetPct,
    required double height,
  }) {
    final fraction = (value / 100).clamp(0.0, 1.0);
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          return Stack(
            children: [
              // 배경
              Container(
                width: totalWidth,
                height: height,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              // 값 바
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeOutCubic,
                width: totalWidth * fraction,
                height: height,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [color, color.withValues(alpha: 0.75)],
                  ),
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              // 목표선
              Positioned(
                left: (totalWidth * targetPct.clamp(0.0, 1.0) - 1),
                top: 0,
                bottom: 0,
                child: Container(
                  width: 2,
                  color: const Color(0xFF333333),
                ),
              ),
            ],
          );
        },
      ),
    );
  }


  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
      ],
    );
  }

  // ══════════════════════════════════════════════════════════
  // D. 성능 합격율 주별 Trend — COMBO CHART (bars + line + table)
  // ══════════════════════════════════════════════════════════

  Widget _buildWeeklyTrendCombo() {
    final allWeeks =
        List<Map<String, dynamic>>.from(_weeklyTrend['weeks'] ?? []);
    if (allWeeks.isEmpty) return const SizedBox.shrink();

    final weeks = _filterByQuarter(allWeeks);

    return _chartSection(
      title: '합격율 주별 Trend',
      icon: Icons.timeline,
      iconColor: _green,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 분기 선택 + 범례
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildQuarterSelector(),
              _legendDot(const Color(0xFF90CAF9), '대상 건수'),
              _legendDot(_primary, '성능 합격율'),
              _legendDot(const Color(0xFF2196F3), '서류 합격율'),
              _legendDot(_primary.withValues(alpha: 0.5), '성능 목표 98.5%'),
              _legendDot(const Color(0xFF2196F3).withValues(alpha: 0.5), '서류 목표 85.5%'),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 220,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return CustomPaint(
                  size: Size(constraints.maxWidth, 220),
                  painter: _ComboChartPainter(
                    weeks: weeks,
                    asPercent: _asPercent,
                    toDouble: _toDouble,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          // Data table — 월별 배치 (분기 선택 시 균등 분배)
          _buildMonthlyTables(weeks),
        ],
      ),
    );
  }

  Widget _buildMonthlyTables(List<Map<String, dynamic>> weeks) {
    final monthGroups = _groupWeeksByMonth(weeks);
    final isQuarter = _selectedQuarter > 0;

    // 전체: 빈 달 포함, 분기: 데이터 있는 달만
    final entries = isQuarter
        ? monthGroups.entries.where((e) => e.value.isNotEmpty).toList()
        : monthGroups.entries.toList();
    if (entries.isEmpty) return const SizedBox.shrink();

    final double fontSize = isQuarter ? 12 : 9;
    final double headingH = isQuarter ? 40 : 28;
    final double rowH = isQuarter ? 38 : 26;
    final double colSpacing = isQuarter ? 20 : 10;
    final double margin = isQuarter ? 12 : 6;

    Widget buildTable(String month, List<Map<String, dynamic>> monthWeeks) {
      return DataTable(
        headingRowColor: WidgetStateProperty.all(const Color(0xFFF3F4F6)),
        headingRowHeight: headingH,
        dataRowMinHeight: rowH,
        dataRowMaxHeight: rowH,
        columnSpacing: colSpacing,
        horizontalMargin: margin,
        border: TableBorder.all(
          color: const Color(0xFFE5E7EB),
          width: 0.5,
          borderRadius: BorderRadius.circular(6),
        ),
        headingTextStyle: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, color: const Color(0xFF374151)),
        dataTextStyle: TextStyle(fontSize: fontSize, color: const Color(0xFF111827)),
        columns: [
          DataColumn(label: Center(child: Text(month)), numeric: isQuarter, headingRowAlignment: MainAxisAlignment.center),
          const DataColumn(label: Center(child: Text('대상')), numeric: true, headingRowAlignment: MainAxisAlignment.center),
          const DataColumn(label: Center(child: Text('성능불합')), numeric: true, headingRowAlignment: MainAxisAlignment.center),
          const DataColumn(label: Center(child: Text('성능합격율')), numeric: true, headingRowAlignment: MainAxisAlignment.center),
          const DataColumn(label: Center(child: Text('서류불합')), numeric: true, headingRowAlignment: MainAxisAlignment.center),
          const DataColumn(label: Center(child: Text('서류합격율')), numeric: true, headingRowAlignment: MainAxisAlignment.center),
        ],
        rows: monthWeeks.map((w) {
          final rate = _truncTo1(_asPercent(w['합격율'] ?? 0));
          final docRate = _truncTo1(_asPercent(w['서류합격율'] ?? 0));
          final weekLabel = (w['주차'] ?? '-').toString().replaceAll(RegExp(r'^\d+월'), '');
          return DataRow(cells: [
            DataCell(Center(child: Text(weekLabel, style: TextStyle(fontSize: fontSize)))),
            DataCell(Center(child: Text(_fmt(w['수검'] ?? 0), style: TextStyle(fontSize: fontSize)))),
            DataCell(Center(child: Text(_fmt(w['불합격'] ?? 0), style: TextStyle(fontSize: fontSize)))),
            DataCell(Center(child: Text('${rate.toStringAsFixed(1)}%',
                style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600,
                    color: rate >= 98.5 ? const Color(0xFF2E7D32) : _primary)))),
            DataCell(Center(child: Text(_fmt(w['서류불합격'] ?? 0), style: TextStyle(fontSize: fontSize)))),
            DataCell(Center(child: Text('${docRate.toStringAsFixed(1)}%',
                style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600,
                    color: docRate >= 85.5 ? const Color(0xFF2E7D32) : _blue)))),
          ]);
        }).toList(),
      );
    }

    // 분기 선택 시 (3개월) → 가로 스크롤로 균등 배분
    if (isQuarter) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: entries.map((e) {
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: buildTable(e.key, e.value),
            );
          }).toList(),
        ),
      );
    }

    // 전체 선택 시 → 스크롤 + 컴팩트
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: entries.map((e) {
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: buildTable(e.key, e.value),
          );
        }).toList(),
      ),
    );
  }

  /// 주차를 월별로 그룹핑 (분기 필터 반영)
  Map<String, List<Map<String, dynamic>>> _groupWeeksByMonth(List<Map<String, dynamic>> weeks) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    // 분기에 맞는 월만 초기화
    final int startMonth = _selectedQuarter == 0 ? 1 : (_selectedQuarter - 1) * 3 + 1;
    final int endMonth = _selectedQuarter == 0 ? 12 : _selectedQuarter * 3;
    for (int m = startMonth; m <= endMonth; m++) {
      grouped['$m월'] = [];
    }
    for (final w in weeks) {
      final wk = (w['주차'] ?? '').toString();
      final match = RegExp(r'^(\d{1,2})월').firstMatch(wk);
      final month = match != null ? '${match.group(1)}월' : '기타';
      if (grouped.containsKey(month)) {
        grouped[month]!.add(w);
      }
    }
    return grouped;
  }

  /// 주차 데이터를 분기로 필터링 (0=전체)
  List<Map<String, dynamic>> _filterByQuarter(List<Map<String, dynamic>> weeks) {
    if (_selectedQuarter == 0) return weeks;
    final startMonth = (_selectedQuarter - 1) * 3 + 1;
    final endMonth = _selectedQuarter * 3;
    return weeks.where((w) {
      final wk = (w['주차'] ?? '').toString();
      final match = RegExp(r'^(\d{1,2})월').firstMatch(wk);
      if (match == null) return false;
      final month = int.tryParse(match.group(1)!) ?? 0;
      return month >= startMonth && month <= endMonth;
    }).toList();
  }

  /// 분기 선택 버튼
  Widget _buildQuarterSelector() {
    const labels = ['전체', '1Q', '2Q', '3Q', '4Q'];
    return Row(
      children: labels.asMap().entries.map((entry) {
        final idx = entry.key;
        final label = entry.value;
        final isSelected = _selectedQuarter == idx;
        return Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => setState(() => _selectedQuarter = idx),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: isSelected ? _primary : Colors.white,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: isSelected ? _primary : const Color(0xFFD1D5DB),
                  ),
                ),
                child: Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: isSelected ? Colors.white : const Color(0xFF6B7280))),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // ══════════════════════════════════════════════════════════
  // E. Acc.담당별 주별 Trend — 9 SMALL LINE CHARTS (3x3 grid)
  // ══════════════════════════════════════════════════════════

  Widget _buildRegionWeeklyGrid() {
    final regionsMap = (_regionWeeklyTrend['regions']
            as Map<String, dynamic>?) ??
        {};
    if (regionsMap.isEmpty) return const SizedBox.shrink();
    final byTeam = (_regionWeeklyTrend['groupBy'] as String?) == 'team';

    // Build ordered list
    final charts = <Widget>[];
    if (byTeam) {
      // 팀 모드: 응답 키(팀명) 그대로, 알파벳/가나다 정렬
      final keys = regionsMap.keys.toList()..sort();
      for (final key in keys) {
        final weekList =
            _filterByQuarter(List<Map<String, dynamic>>.from(regionsMap[key] as List));
        charts.add(_smallLineChart(_shortTeamName(key), weekList));
      }
    } else {
      // 본부 모드: _regionOrder 정렬
      for (final rName in _regionOrder) {
        final data = regionsMap[rName];
        final weekList = data != null
            ? _filterByQuarter(List<Map<String, dynamic>>.from(data as List))
            : <Map<String, dynamic>>[];
        charts.add(_smallLineChart(rName, weekList));
      }
      for (final key in regionsMap.keys) {
        if (!_regionOrder.contains(key)) {
          final weekList =
              _filterByQuarter(List<Map<String, dynamic>>.from(regionsMap[key] as List));
          charts.add(_smallLineChart(key, weekList));
        }
      }
    }

    return _chartSection(
      title: byTeam ? '팀별 주별 Trend' : 'Acc.담당별 주별 Trend',
      icon: Icons.grid_view,
      iconColor: _primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              _legendDot(_primary, '성능 합격율'),
              _legendDot(const Color(0xFF2196F3), '서류 합격율'),
              _legendDot(_primary.withValues(alpha: 0.4), '성능 목표 98.5%'),
              _legendDot(const Color(0xFF2196F3).withValues(alpha: 0.4), '서류 목표 85.5%'),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
        builder: (context, constraints) {
          final cols = constraints.maxWidth >= 900
              ? 3
              : (constraints.maxWidth >= 500 ? 2 : 1);
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: charts.map((c) {
              final w = (constraints.maxWidth - (cols - 1) * 12) / cols;
              return SizedBox(width: w, child: c);
            }).toList(),
          );
        },
      ),
        ],
      ),
    );
  }

  /// 주차 라벨을 "1월1주" 형식으로
  static String _formatWeekLabel(String raw) {
    final m = RegExp(r'(\d+)월(\d+)주').firstMatch(raw);
    if (m != null) return '${m[1]}월${m[2]}주';
    return raw;
  }

  Widget _smallLineChart(
      String regionName, List<Map<String, dynamic>> weekData) {
    final perfValues =
        weekData.map((w) => _asPercent(w['합격율'] ?? 0)).toList();
    final docValues =
        weekData.map((w) => _asPercent(w['서류합격율'] ?? 0)).toList();
    final labels = weekData
        .map((w) => _formatWeekLabel((w['주차'] ?? '').toString()))
        .toList();

    return GestureDetector(
      onTap: () => _showExpandedChart(regionName, perfValues, docValues, labels),
      child: Container(
        height: 200,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F6FA),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(regionName,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF374151))),
                const Spacer(),
                Icon(Icons.open_in_full, size: 14, color: Colors.grey.shade400),
              ],
            ),
            const SizedBox(height: 6),
            Expanded(
              child: perfValues.isEmpty
                  ? const Center(
                      child: Text('데이터 없음',
                          style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFF9CA3AF))))
                  : CustomPaint(
                      size: Size.infinite,
                      painter: _SmallLineChartPainter(
                        values: perfValues,
                        values2: docValues,
                        labels: labels,
                        target: 98.5,
                        lineColor: _primary,
                        line2Color: const Color(0xFF2196F3),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _showExpandedChart(String regionName, List<double> perfValues, List<double> docValues, List<String> labels) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: '',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 300),
      transitionBuilder: (ctx, anim, secondaryAnim, child) {
        final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
        return FadeTransition(
          opacity: anim,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.8, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
      pageBuilder: (ctx, anim, secondaryAnim) => Center(
        child: Dialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 60),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.timeline, size: 20, color: _primary),
                    const SizedBox(width: 8),
                    Text('$regionName 주별 Trend',
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF111827))),
                    const Spacer(),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close, size: 20),
                      splashRadius: 18,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _legendDot(_primary, '성능 합격율'),
                    const SizedBox(width: 12),
                    _legendDot(const Color(0xFF2196F3), '서류 합격율'),
                    const SizedBox(width: 12),
                    _legendDot(_primary.withValues(alpha: 0.5), '목표 98.5%'),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 350,
                  child: perfValues.isEmpty
                      ? const Center(child: Text('데이터 없음'))
                      : CustomPaint(
                          size: Size.infinite,
                          painter: _SmallLineChartPainter(
                            values: perfValues,
                            values2: docValues,
                            labels: labels,
                            target: 98.5,
                            lineColor: _primary,
                            line2Color: const Color(0xFF2196F3),
                            fontSize: 13,
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // F. 장비 Type별 불합격 현황 (Top3) — CROSS-TAB TABLE
  // ══════════════════════════════════════════════════════════

  Widget _buildEquipTypeCrosstab() {
    // 장비 Type별 차트는 본부/팀 필터 무관하게 전체 데이터 사용
    final crosstab = List<Map<String, dynamic>>.from(
        _analysisAll['장비타입별_크로스탭'] ?? []);
    if (crosstab.isEmpty) return const SizedBox.shrink();

    // Collect all regions across all rows
    final allRegions = <String>{};
    for (final row in crosstab) {
      final m = (row['본부별'] as Map<String, dynamic>?) ?? {};
      allRegions.addAll(m.keys);
    }
    // Use region order, then extras
    final orderedRegions = <String>[];
    for (final r in _regionOrder) {
      if (allRegions.contains(r)) orderedRegions.add(r);
    }
    for (final r in allRegions) {
      if (!orderedRegions.contains(r)) orderedRegions.add(r);
    }

    // Compute grand total for ratio
    final grandTotal = crosstab.isNotEmpty
        ? _toDouble(crosstab.last['총합계'] ?? 0)
        : 1.0;

    return _chartSection(
      title: '장비 Type별 불합격 현황 (Top3)',
      icon: Icons.router,
      iconColor: _orange,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor:
              WidgetStateProperty.all(const Color(0xFFF3F4F6)),
          headingRowHeight: 44,
          dataRowMinHeight: 48,
          dataRowMaxHeight: 48,
          columnSpacing: 24,
          horizontalMargin: 12,
          border: TableBorder.all(
            color: const Color(0xFFE5E7EB),
            width: 0.5,
            borderRadius: BorderRadius.circular(8),
          ),
          headingTextStyle: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Color(0xFF374151)),
          dataTextStyle:
              const TextStyle(fontSize: 11, color: Color(0xFF111827)),
          columns: [
            const DataColumn(label: Center(child: Text('구분')), headingRowAlignment: MainAxisAlignment.center),
            ...orderedRegions
                .map((r) => DataColumn(label: Center(child: Text(r)), numeric: true, headingRowAlignment: MainAxisAlignment.center)),
            const DataColumn(label: Center(child: Text('총합계')), numeric: true, headingRowAlignment: MainAxisAlignment.center),
            const DataColumn(label: Center(child: Text('비율')), numeric: true, headingRowAlignment: MainAxisAlignment.center),
          ],
          rows: crosstab.asMap().entries.map((entry) {
            final i = entry.key;
            final row = entry.value;
            final typeName = row['타입'] ?? '-';
            final byRegion =
                (row['본부별'] as Map<String, dynamic>?) ?? {};
            final total = _toDouble(row['총합계'] ?? 0);
            final isTotalRow = typeName == '성능불합격(건)';
            final isEven = i.isEven;
            final ratio =
                grandTotal > 0 ? (total / grandTotal * 100) : 0.0;
            final style = TextStyle(
              fontSize: 11,
              fontWeight: isTotalRow ? FontWeight.w700 : FontWeight.w400,
              color: const Color(0xFF111827),
            );

            return DataRow(
              color: WidgetStateProperty.all(
                isTotalRow
                    ? const Color(0xFFEEF2FF)
                    : isEven
                        ? Colors.white
                        : const Color(0xFFFAFAFB),
              ),
              cells: [
                DataCell(Center(child: Text(typeName, style: style))),
                ...orderedRegions.map((r) {
                  final v = byRegion[r];
                  return DataCell(Center(child:
                      Text(v != null ? _fmt(v) : '-', style: style)));
                }),
                DataCell(Center(child: Text(_fmt(total.toInt()),
                    style: style.copyWith(fontWeight: FontWeight.w700)))),
                DataCell(Center(child: Text(
                    isTotalRow ? '100%' : '${ratio.toStringAsFixed(1)}%',
                    style: style))),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // F-2. 장비 Type별 불합격 요약 (비율 바 + 본부별 분포)
  // ══════════════════════════════════════════════════════════

  Widget _buildEquipTypeSummary() {
    // 장비 Type별 차트는 본부/팀 필터 무관하게 전체 데이터 사용
    final crosstab = List<Map<String, dynamic>>.from(
        _analysisAll['장비타입별_크로스탭'] ?? []);
    // 합계 행 제외
    final items = crosstab.where((r) => r['타입'] != '성능불합격(건)').toList();
    if (items.isEmpty) return const SizedBox.shrink();

    final grandTotal = items.fold<double>(
        0, (sum, r) => sum + _toDouble(r['총합계'] ?? 0));

    const colors = [
      Color(0xFFE53935), Color(0xFFFF7043), Color(0xFFFFA726),
      Color(0xFFAB47BC), Color(0xFF42A5F5), Color(0xFF66BB6A),
      Color(0xFF78909C), Color(0xFFEC407A), Color(0xFF26A69A),
    ];

    return _chartSection(
      title: '장비 Type별 불합격 비율',
      icon: Icons.donut_small,
      iconColor: _primary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 비율 스택 바
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 28,
              child: Row(
                children: items.asMap().entries.map((entry) {
                  final i = entry.key;
                  final r = entry.value;
                  final total = _toDouble(r['총합계'] ?? 0);
                  final ratio = grandTotal > 0 ? total / grandTotal : 0.0;
                  if (ratio <= 0) return const SizedBox.shrink();
                  return Expanded(
                    flex: (ratio * 1000).round().clamp(1, 1000),
                    child: Container(
                      color: colors[i % colors.length],
                      alignment: Alignment.center,
                      child: ratio >= 0.08
                          ? Text('${(ratio * 100).toStringAsFixed(1)}%',
                              style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white))
                          : null,
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 각 장비별 상세
          ...items.asMap().entries.map((entry) {
            final i = entry.key;
            final r = entry.value;
            final typeName = r['타입'] ?? '-';
            final total = _toDouble(r['총합계'] ?? 0);
            final ratio = grandTotal > 0 ? (total / grandTotal * 100) : 0.0;
            final color = colors[i % colors.length];

            // 본부별 데이터에서 최다 본부 찾기
            final byRegion = (r['본부별'] as Map<String, dynamic>?) ?? {};
            String topRegion = '-';
            double topVal = 0;
            byRegion.forEach((k, v) {
              final val = _toDouble(v);
              if (val > topVal) {
                topVal = val;
                topRegion = k;
              }
            });

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 36,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(typeName,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1F2937))),
                        const SizedBox(height: 2),
                        Text('최다 본부: $topRegion (${topVal.toInt()}건)',
                            style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFF6B7280))),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('${total.toInt()}건',
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF1F2937))),
                      Text('${ratio.toStringAsFixed(1)}%',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: color)),
                    ],
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════
// Data classes
// ══════════════════════════════════════════════════════════

class _DonutSlice {
  final String name;
  final double value;
  final Color color;
  const _DonutSlice(
      {required this.name, required this.value, required this.color});
}

// ══════════════════════════════════════════════════════════
// Custom Painters
// ══════════════════════════════════════════════════════════

/// Donut chart using Canvas.drawArc
class _DonutPainter extends CustomPainter {
  final List<_DonutSlice> slices;
  final double total;

  _DonutPainter({required this.slices, required this.total});

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0 || slices.isEmpty) return;

    final center = Offset(size.width / 2, size.height / 2);
    final labelMargin = math.min(size.width, size.height) * 0.18;
    final outerRadius = math.min(size.width, size.height) / 2 - labelMargin;
    final innerRadius = outerRadius * 0.45;

    // 단일 슬라이스 100% 케이스: arcTo(2π)가 그려지지 않는 Flutter 동작 우회.
    // 외부 원 채우고 내부 흰 원으로 도넛 모양 만들기.
    if (slices.length == 1) {
      canvas.drawCircle(center, outerRadius, Paint()..color = slices[0].color);
      canvas.drawCircle(center, innerRadius, Paint()..color = Colors.white);
    }

    double startAngle = -math.pi / 2;

    // 1단계: 슬라이스를 filled arc로 그리기 (단일 슬라이스는 위에서 이미 처리)
    final sliceAngles = <double>[];
    for (int i = 0; i < slices.length; i++) {
      final slice = slices[i];
      final sweepAngle = 2 * math.pi * (slice.value / total);

      // 단일 슬라이스는 위에서 그렸으므로 path 그리기 생략, 각도만 기록
      if (slices.length > 1) {
        // 외부 arc path
        final path = Path()
          ..moveTo(
            center.dx + innerRadius * math.cos(startAngle),
            center.dy + innerRadius * math.sin(startAngle),
          )
          ..lineTo(
            center.dx + outerRadius * math.cos(startAngle),
            center.dy + outerRadius * math.sin(startAngle),
          )
          ..arcTo(
            Rect.fromCircle(center: center, radius: outerRadius),
            startAngle,
            sweepAngle,
            false,
          )
          ..lineTo(
            center.dx + innerRadius * math.cos(startAngle + sweepAngle),
            center.dy + innerRadius * math.sin(startAngle + sweepAngle),
          )
          ..arcTo(
            Rect.fromCircle(center: center, radius: innerRadius),
            startAngle + sweepAngle,
            -sweepAngle,
            false,
          )
          ..close();

        canvas.drawPath(path, Paint()..color = slice.color);
      }

      sliceAngles.add(startAngle + sweepAngle / 2);
      startAngle += sweepAngle;
    }

    // 2단계: 슬라이스 경계에 흰색 구분선 (단일 슬라이스는 경계가 없으므로 생략)
    if (slices.length > 1) {
      startAngle = -math.pi / 2;
      final dividerPaint = Paint()
        ..color = Colors.white
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      for (int i = 0; i < slices.length; i++) {
        final sweepAngle = 2 * math.pi * (slices[i].value / total);
        startAngle += sweepAngle;
        final innerPt = Offset(
          center.dx + innerRadius * math.cos(startAngle),
          center.dy + innerRadius * math.sin(startAngle),
        );
        final outerPt = Offset(
          center.dx + outerRadius * math.cos(startAngle),
          center.dy + outerRadius * math.sin(startAngle),
        );
        canvas.drawLine(innerPt, outerPt, dividerPaint);
      }
    }

    // 2단계: 라벨 Y좌표 겹침 방지
    const minLabelGap = 16.0;
    final labelInfos = <_LabelInfo>[];
    for (int i = 0; i < slices.length; i++) {
      final pct = slices[i].value / total * 100;
      if (pct < 1) continue;
      final midAngle = sliceAngles[i];
      final cosA = math.cos(midAngle);
      final sinA = math.sin(midAngle);
      final rawY = center.dy + (outerRadius + labelMargin * 0.7) * sinA;
      labelInfos.add(_LabelInfo(
        index: i,
        midAngle: midAngle,
        cosA: cosA,
        sinA: sinA,
        isRight: cosA >= 0,
        rawY: rawY,
        adjustedY: rawY,
      ));
    }

    // 좌/우 각각 Y좌표 겹침 해소
    for (final isRight in [true, false]) {
      final group = labelInfos.where((l) => l.isRight == isRight).toList();
      group.sort((a, b) => a.rawY.compareTo(b.rawY));
      for (int j = 1; j < group.length; j++) {
        if (group[j].adjustedY - group[j - 1].adjustedY < minLabelGap) {
          group[j].adjustedY = group[j - 1].adjustedY + minLabelGap;
        }
      }
    }

    // 3단계: 연결선 + 라벨 그리기
    for (final info in labelInfos) {
      final slice = slices[info.index];
      final pct = slice.value / total * 100;

      final lineStart = Offset(
        center.dx + (outerRadius + 3) * info.cosA,
        center.dy + (outerRadius + 3) * info.sinA,
      );
      final elbowX = center.dx + (outerRadius + labelMargin * 0.5) * info.cosA;
      final elbow = Offset(elbowX, info.adjustedY);
      final hEndX = info.isRight
          ? elbowX + labelMargin * 0.4
          : elbowX - labelMargin * 0.4;
      final hEnd = Offset(hEndX, info.adjustedY);

      final linePaint = Paint()
        ..color = const Color(0xFFBBBBBB)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;
      canvas.drawLine(lineStart, elbow, linePaint);
      canvas.drawLine(elbow, hEnd, linePaint);

      // 컬러 점
      final dotX = info.isRight ? hEnd.dx + 5 : hEnd.dx - 5;
      canvas.drawCircle(Offset(dotX, hEnd.dy), 3.5, Paint()..color = slice.color);

      // 퍼센트 텍스트
      final tp = TextPainter(
        text: TextSpan(
          text: '${pct.toStringAsFixed(pct >= 10 ? 0 : 1)}%',
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Color(0xFF374151),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final textX = info.isRight ? dotX + 7 : dotX - 7 - tp.width;
      tp.paint(canvas, Offset(textX, hEnd.dy - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.slices != slices || old.total != total;
}

class _LabelInfo {
  final int index;
  final double midAngle;
  final double cosA;
  final double sinA;
  final bool isRight;
  final double rawY;
  double adjustedY;

  _LabelInfo({
    required this.index,
    required this.midAngle,
    required this.cosA,
    required this.sinA,
    required this.isRight,
    required this.rawY,
    required this.adjustedY,
  });
}

/// Combo chart: vertical bars (대상건수) + line (합격율) + target dashed line
class _ComboChartPainter extends CustomPainter {
  final List<Map<String, dynamic>> weeks;
  final double Function(dynamic) asPercent;
  final double Function(dynamic) toDouble;

  _ComboChartPainter({
    required this.weeks,
    required this.asPercent,
    required this.toDouble,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (weeks.isEmpty) return;

    const double leftPad = 40;
    const double rightPad = 40;
    const double topPad = 10;
    const double bottomPad = 30;

    final chartW = size.width - leftPad - rightPad;
    final chartH = size.height - topPad - bottomPad;

    // Calculate scales
    final maxCount = weeks.fold<double>(
        0, (m, w) => math.max(m, toDouble(w['수검'] ?? 0)));
    final yMaxCount = (maxCount * 1.2).ceilToDouble();

    // Rate 80-100 (서류 목표 85.5% 포함)
    const rateMin = 80.0;
    const rateMax = 100.0;

    final barWidth = (chartW / weeks.length) * 0.5;
    final spacing = chartW / weeks.length;

    // Draw grid lines (horizontal)
    final gridPaint = Paint()
      ..color = const Color(0xFFE5E7EB)
      ..strokeWidth = 0.5;

    for (int i = 0; i <= 4; i++) {
      final y = topPad + chartH * (i / 4);
      canvas.drawLine(
        Offset(leftPad, y),
        Offset(size.width - rightPad, y),
        gridPaint,
      );
    }

    // Draw bars
    final barPaint = Paint()..color = const Color(0xFF90CAF9);
    for (int i = 0; i < weeks.length; i++) {
      final count = toDouble(weeks[i]['수검'] ?? 0);
      final barH = yMaxCount > 0 ? (count / yMaxCount) * chartH : 0.0;
      final x = leftPad + spacing * i + (spacing - barWidth) / 2;
      final y = topPad + chartH - barH;
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, y, barWidth, barH),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        ),
        barPaint,
      );
    }

    void _drawDashedLine(Canvas canvas, double y, Color color) {
      final paint = Paint()..color = color..strokeWidth = 1.0;
      const dashW = 5.0, dashS = 3.0;
      double dx = leftPad;
      while (dx < size.width - rightPad) {
        canvas.drawLine(Offset(dx, y), Offset(math.min(dx + dashW, size.width - rightPad), y), paint);
        dx += dashW + dashS;
      }
    }

    void _drawLine(Canvas canvas, List<Offset> points, Color color) {
      if (points.length < 2) return;
      final paint = Paint()..color = color..strokeWidth = 2.0..style = PaintingStyle.stroke;
      final path = Path()..moveTo(points[0].dx, points[0].dy);
      for (int i = 1; i < points.length; i++) path.lineTo(points[i].dx, points[i].dy);
      canvas.drawPath(path, paint);
      for (final p in points) {
        canvas.drawCircle(p, 4, Paint()..color = color..style = PaintingStyle.fill);
        canvas.drawCircle(p, 2.5, Paint()..color = Colors.white..style = PaintingStyle.fill);
      }
    }

    // 목표선 98.5% (성능)
    final perfTargetY = topPad + chartH * (1 - (98.5 - rateMin) / (rateMax - rateMin));
    _drawDashedLine(canvas, perfTargetY, const Color(0xFFE53935).withOpacity(0.6));

    // 목표선 85.5% (서류)
    final docTargetY = topPad + chartH * (1 - (85.5 - rateMin) / (rateMax - rateMin));
    _drawDashedLine(canvas, docTargetY, const Color(0xFF2196F3).withOpacity(0.6));

    // 성능 합격율 라인
    final perfPoints = <Offset>[];
    for (int i = 0; i < weeks.length; i++) {
      final rate = asPercent(weeks[i]['합격율'] ?? 0);
      final clamped = rate.clamp(rateMin, rateMax);
      final x = leftPad + spacing * i + spacing / 2;
      final y = topPad + chartH * (1 - (clamped - rateMin) / (rateMax - rateMin));
      perfPoints.add(Offset(x, y));
    }
    _drawLine(canvas, perfPoints, const Color(0xFFE53935));

    // 서류 합격율 라인
    final docPoints = <Offset>[];
    for (int i = 0; i < weeks.length; i++) {
      final rate = asPercent(weeks[i]['서류합격율'] ?? 0);
      final clamped = rate.clamp(rateMin, rateMax);
      final x = leftPad + spacing * i + spacing / 2;
      final y = topPad + chartH * (1 - (clamped - rateMin) / (rateMax - rateMin));
      docPoints.add(Offset(x, y));
    }
    _drawLine(canvas, docPoints, const Color(0xFF2196F3));

    // Y-axis labels (left = count)
    final textStyle = TextStyle(
        fontSize: 9, color: const Color(0xFF9CA3AF));
    for (int i = 0; i <= 4; i++) {
      final val = (yMaxCount * (4 - i) / 4).toInt();
      _drawText(canvas, '$val', Offset(leftPad - 4, topPad + chartH * (i / 4)),
          textStyle, TextAlign.right, 36);
    }

    // Y-axis labels (right = rate)
    for (int i = 0; i <= 4; i++) {
      final val = rateMax - (rateMax - rateMin) * (i / 4);
      final label = val == val.toInt().toDouble()
          ? '${val.toInt()}%'
          : '${val.toStringAsFixed(1)}%';
      _drawText(
          canvas,
          label,
          Offset(size.width - rightPad + 4, topPad + chartH * (i / 4)),
          textStyle,
          TextAlign.left,
          36);
    }

    // X-axis labels
    for (int i = 0; i < weeks.length; i++) {
      final label = (weeks[i]['주차'] ?? '').toString();
      final shortLabel =
          label.length > 4 ? label.substring(0, 4) : label;
      _drawText(
        canvas,
        shortLabel,
        Offset(
            leftPad + spacing * i + spacing / 2, topPad + chartH + 6),
        textStyle,
        TextAlign.center,
        spacing,
      );
    }
  }

  void _drawText(Canvas canvas, String text, Offset position,
      TextStyle style, TextAlign align, double maxWidth) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: align,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);

    double dx;
    if (align == TextAlign.right) {
      dx = position.dx - tp.width;
    } else if (align == TextAlign.center) {
      dx = position.dx - tp.width / 2;
    } else {
      dx = position.dx;
    }
    tp.paint(canvas, Offset(dx, position.dy - tp.height / 2));
  }

  @override
  bool shouldRepaint(covariant _ComboChartPainter old) =>
      old.weeks != weeks;
}

/// Small line chart for per-region weekly trend
class _SmallLineChartPainter extends CustomPainter {
  final List<double> values;
  final List<double> values2;
  final List<String> labels;
  final double target;
  final Color lineColor;
  final Color line2Color;
  final double fontSize;

  _SmallLineChartPainter({
    required this.values,
    this.values2 = const [],
    this.labels = const [],
    required this.target,
    required this.lineColor,
    this.line2Color = const Color(0xFF2196F3),
    this.fontSize = 9,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;

    const double pad = 4;
    const double bottomPad = 40;
    final chartW = size.width - pad * 2;
    final chartH = size.height - pad - bottomPad;

    // Y range: 성능 + 서류 모두 고려
    double dataMin = values.fold<double>(100, math.min);
    if (values2.isNotEmpty) {
      dataMin = math.min(dataMin, values2.fold<double>(100, math.min));
    }
    final yMin = math.min(dataMin - 2, 80.0).floorToDouble();
    const yMax = 100.0;
    final yRange = yMax - yMin;

    double yFor(double v) {
      final clamped = v.clamp(yMin, yMax);
      return pad + chartH * (1 - (clamped - yMin) / yRange);
    }

    double xFor(int i) {
      if (values.length == 1) return pad + chartW / 2;
      return pad + chartW * i / (values.length - 1);
    }

    // 목표선 그리기 헬퍼
    void drawTarget(double targetVal, Color color) {
      final ty = yFor(targetVal);
      final dp = Paint()
        ..color = color.withValues(alpha: 0.4)
        ..strokeWidth = 1.0;
      const dw = 4.0;
      const ds = 2.0;
      double dx2 = pad;
      while (dx2 < size.width - pad) {
        canvas.drawLine(
          Offset(dx2, ty),
          Offset(math.min(dx2 + dw, size.width - pad), ty),
          dp,
        );
        dx2 += dw + ds;
      }
      final tlp = TextPainter(
        text: TextSpan(
            text: '${targetVal.toStringAsFixed(1)}%',
            style: TextStyle(fontSize: fontSize, color: color.withValues(alpha: 0.6))),
        textDirection: TextDirection.ltr,
      )..layout();
      tlp.paint(canvas, Offset(size.width - pad - tlp.width, ty - tlp.height - 1));
    }

    // 성능 목표선 (98.5%)
    drawTarget(target, lineColor);
    // 서류 목표선 (85.5%)
    if (values2.isNotEmpty) {
      drawTarget(85.5, line2Color);
    }

    void _drawLine(List<double> vals, Color color) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;
      final dot = Paint()
        ..color = color
        ..style = PaintingStyle.fill;

      final pts = <Offset>[];
      for (int i = 0; i < vals.length; i++) {
        pts.add(Offset(xFor(i), yFor(vals[i])));
      }
      if (pts.length >= 2) {
        final path = Path()..moveTo(pts[0].dx, pts[0].dy);
        for (int i = 1; i < pts.length; i++) {
          path.lineTo(pts[i].dx, pts[i].dy);
        }
        canvas.drawPath(path, paint);
      }
      for (final p in pts) {
        canvas.drawCircle(p, 3, dot);
        canvas.drawCircle(p, 1.5, Paint()..color = Colors.white..style = PaintingStyle.fill);
      }
    }

    // 서류 라인 (뒤에 먼저 그리기)
    if (values2.isNotEmpty) {
      _drawLine(values2, line2Color);
    }

    // 성능 라인
    _drawLine(values, lineColor);

    // X-axis labels (45° rotated)
    if (labels.isNotEmpty) {
      final step = values.length > 12 ? 2 : 1;
      for (int i = 0; i < values.length && i < labels.length; i += step) {
        final ltp = TextPainter(
          text: TextSpan(
              text: labels[i],
              style: TextStyle(fontSize: fontSize, color: const Color(0xFF6B7280))),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout();
        final lx = xFor(i);
        final ly = pad + chartH + 4;
        canvas.save();
        canvas.translate(lx, ly);
        canvas.rotate(0.785);
        ltp.paint(canvas, Offset.zero);
        canvas.restore();
      }
    }

    // Last value labels (성능 + 서류)
    if (values.isNotEmpty) {
      final lastVal = values.last;
      final lastPt = Offset(xFor(values.length - 1), yFor(lastVal));
      final valTp = TextPainter(
        text: TextSpan(
            text: '${lastVal.toStringAsFixed(1)}%',
            style: TextStyle(
                fontSize: fontSize + 1,
                fontWeight: FontWeight.w700,
                color: lastVal >= target ? const Color(0xFF2E7D32) : lineColor)),
        textDirection: TextDirection.ltr,
      )..layout();
      double labelX = lastPt.dx - valTp.width / 2;
      labelX = labelX.clamp(0, size.width - valTp.width);
      valTp.paint(canvas, Offset(labelX, lastPt.dy - valTp.height - 3));
    }
    if (values2.isNotEmpty) {
      final lastVal2 = values2.last;
      final lastPt2 = Offset(xFor(values2.length - 1), yFor(lastVal2));
      final valTp2 = TextPainter(
        text: TextSpan(
            text: '${lastVal2.toStringAsFixed(1)}%',
            style: TextStyle(
                fontSize: fontSize + 1,
                fontWeight: FontWeight.w700,
                color: line2Color)),
        textDirection: TextDirection.ltr,
      )..layout();
      double labelX2 = lastPt2.dx - valTp2.width / 2;
      labelX2 = labelX2.clamp(0, size.width - valTp2.width);
      // 성능 라벨과 겹치지 않도록 아래쪽에 표시
      valTp2.paint(canvas, Offset(labelX2, lastPt2.dy + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _SmallLineChartPainter old) =>
      old.values != values || old.values2 != values2 || old.target != target || old.fontSize != fontSize;
}
