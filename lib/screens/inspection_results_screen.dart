import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import '../services/auth_service.dart';
import '../services/inspection_service.dart';
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
  Map<String, dynamic> _weeklyTrend = {};
  Map<String, dynamic> _regionWeeklyTrend = {};
  List<Map<String, dynamic>> _reportLines = [];

  String _selectedRegion = '';
  late bool _isAdmin;

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

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rgn = _selectedRegion;
      if (_tabCtrl.index == 0) {
        final dash = await _svc.getResultsDashboard(_year, region: rgn);
        if (!mounted) return;
        setState(() {
          _dashboard = dash;
          _monthlyData = dash;
        });
      } else {
        final month = _tabCtrl.index.toString();
        final data = await _svc.getResultsMonthly(_year, month, region: rgn);
        if (!mounted) return;
        if (_dashboard.isEmpty) {
          final dash = await _svc.getResultsDashboard(_year, region: rgn);
          if (!mounted) return;
          _dashboard = dash;
        }
        setState(() {
          _monthlyData = data;
        });
      }
      // 차트 데이터 (별도 try-catch)
      try {
        final results = await Future.wait([
          _svc.getResultsAnalysis(_year, region: rgn),
          _svc.getResultsWeeklyTrend(_year, region: rgn),
          _svc.getResultsSummaryReport(_year, region: rgn),
          _svc.getResultsWeeklyTrendByRegion(_year, region: rgn),
        ]);
        if (!mounted) return;
        setState(() {
          _analysis = results[0];
          _weeklyTrend = results[1];
          final report = results[2];
          _reportLines =
              List<Map<String, dynamic>>.from(report['lines'] ?? []);
          _regionWeeklyTrend = results[3];
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
    if (files.isEmpty) return;

    setState(() => _uploading = true);
    int totalCount = 0;
    int successCount = 0;
    final errors = <String>[];

    try {
      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        try {
          _snack('업로드 중... (${i + 1}/${files.length}) ${file.name}');
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
        _snack('전체 업로드 완료: ${files.length}개 파일, $totalCount건 처리');
      } else {
        _snack(
            '$successCount/${files.length}개 성공 ($totalCount건), 실패: ${errors.length}개',
            isError: true);
      }
      _loadData();
    } catch (e) {
      if (!mounted) return;
      _snack('업로드 실패: $e', isError: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  // ── Excel 다운로드 ──

  Future<void> _downloadExcel() async {
    _snack('Excel 다운로드 준비 중...');
    try {
      final tab = _tabCtrl.index == 0 ? 'acc' : '${_tabCtrl.index}월';
      final week = _tabCtrl.index == 0 ? '' : '${_tabCtrl.index}월';
      final bytes = await _svc.exportResultsXlsx(_year, week: week);
      if (!mounted) return;
      final blob = html.Blob([bytes],
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      final url = html.Url.createObjectUrlFromBlob(blob);
      final anchor = html.AnchorElement()
        ..href = url
        ..download = '실적_결과장_${_year}_$tab.xlsx'
        ..style.display = 'none';
      html.document.body?.children.add(anchor);
      anchor.click();
      html.document.body?.children.remove(anchor);
      html.Url.revokeObjectUrl(url);
      _snack('다운로드 완료');
    } catch (e) {
      if (!mounted) return;
      _snack('다운로드 실패: $e', isError: true);
    }
  }

  void _snack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 13)),
      backgroundColor: isError ? Colors.red.shade700 : _primary,
      duration: Duration(seconds: isError ? 4 : 2),
    ));
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

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFFAFAFB),
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 40),
              child: Column(
                children: [
                  _buildSummaryCards(),
                  if (_reportLines.isNotEmpty) _buildSummaryReport(),
                  if (_selectedRegion.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      child: Row(children: [
                        Icon(Icons.filter_alt, size: 16, color: _primary),
                        const SizedBox(width: 6),
                        Text('$_selectedRegion 본부 필터 적용 중',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFE53935))),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: () { setState(() => _selectedRegion = ''); _loadData(); },
                          child: const Text('전체 보기', style: TextStyle(fontSize: 12)),
                        ),
                      ]),
                    ),
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
                            onRegionSelected: (region) {
                              if (_selectedRegion != region) {
                                setState(() => _selectedRegion = region);
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
          ),
        ],
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

  // ── 상단 헤더 ──

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(
        children: [
          const Spacer(),
          if (_isAdmin) ...[
            _uploading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(
                    onPressed: _pickAndUpload,
                    icon: const Icon(Icons.upload_file, size: 20),
                    tooltip: '실적 결과장 업로드',
                    color: _primary,
                    splashRadius: 20,
                  ),
            const SizedBox(width: 4),
          ],
          IconButton(
            onPressed: _downloadExcel,
            icon: const Icon(Icons.download, size: 20),
            tooltip: 'Excel 다운로드',
            color: _green,
            splashRadius: 20,
          ),
        ],
      ),
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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Expanded(
              child: _summaryCard(
                  '수검국소', _fmt(total), Icons.location_on, _blue)),
          const SizedBox(width: 10),
          Expanded(
              child: _summaryCard(
                  '성능합격율', _pct(perfRate), Icons.check_circle, _green)),
          const SizedBox(width: 10),
          Expanded(
              child: _summaryCard(
                  '서류합격율', _pct(docRate), Icons.description, _orange)),
          const SizedBox(width: 10),
          Expanded(
              child: _summaryCard(
                  '진도율', _pct(progress), Icons.trending_up, _primary)),
        ],
      ),
    );
  }

  Widget _summaryCard(
      String label, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
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
                Text(label,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(value,
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: color)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Summary Report (yellow box) ──

  Widget _buildSummaryReport() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFDE7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFEB3B), width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _reportLines.map((line) {
          final type = line['type'] ?? 'detail';
          final text = line['text'] ?? '';
          if (type == 'header') {
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF333333),
                      height: 1.5)),
            );
          } else if (type == 'highlight') {
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFE53935),
                      height: 1.5)),
            );
          } else {
            return Text(text,
                style: TextStyle(
                  fontSize: 11,
                  color: type == 'sub'
                      ? const Color(0xFF555555)
                      : const Color(0xFF333333),
                  height: 1.5,
                ));
          }
        }).toList(),
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
      return const Center(
          child:
              CircularProgressIndicator(color: _primary, strokeWidth: 2));
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
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // ── Row 1: 본부별 실적 + 파이차트 (좌) | 본부별 목표 대비 (우) ──
              if (isWide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Column(children: [
                        _buildDataTable(),
                        const SizedBox(height: 14),
                        _buildFailureDonutSection(),
                      ]),
                    ),
                    const SizedBox(width: 14),
                    Expanded(flex: 5, child: _buildRegionBarChart()),
                  ],
                )
              else ...[
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

              // ── F. 장비 Type별 불합격 현황 크로스탭 ──
              _buildEquipTypeCrosstab(),
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
    return Container(
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
          Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 6),
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

  Widget _buildDataTable() {
    final regionData =
        List<Map<String, dynamic>>.from(_monthlyData['regions'] ?? []);
    final totals =
        _monthlyData['totals'] as Map<String, dynamic>? ?? {};

    return _chartSection(
      title: '본부별 실적',
      icon: Icons.table_chart,
      iconColor: _blue,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor:
              WidgetStateProperty.all(const Color(0xFFF3F4F6)),
          headingRowHeight: 36,
          dataRowMinHeight: 32,
          dataRowMaxHeight: 32,
          columnSpacing: 12,
          horizontalMargin: 12,
          headingTextStyle: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Color(0xFF374151)),
          dataTextStyle:
              const TextStyle(fontSize: 11, color: Color(0xFF111827)),
          columns: const [
            DataColumn(label: Text('본부')),
            DataColumn(label: Text('수검국소'), numeric: true),
            DataColumn(label: Text('완료'), numeric: true),
            DataColumn(label: Text('시기조정'), numeric: true),
            DataColumn(label: Text('폐'), numeric: true),
            DataColumn(label: Text('성능합격'), numeric: true),
            DataColumn(label: Text('성능불합'), numeric: true),
            DataColumn(label: Text('서류합격'), numeric: true),
            DataColumn(label: Text('서류불합'), numeric: true),
            DataColumn(label: Text('성능합격율'), numeric: true),
            DataColumn(label: Text('서류합격율'), numeric: true),
          ],
          rows: [
            ...regionData.map((r) => _buildDataRow(r, isBold: false)),
            if (totals.isNotEmpty)
              _buildDataRow(totals, isBold: true),
          ],
        ),
      ),
    );
  }

  DataRow _buildDataRow(Map<String, dynamic> r, {required bool isBold}) {
    final style = TextStyle(
      fontSize: 11,
      fontWeight: isBold ? FontWeight.w700 : FontWeight.w400,
      color: const Color(0xFF111827),
    );

    final perfRate = _asPercent(r['성능합격율'] ?? r['perf_pass_rate']);
    final docRate = _asPercent(r['서류합격율'] ?? r['doc_pass_rate']);

    return DataRow(
      color: isBold
          ? WidgetStateProperty.all(const Color(0xFFFFF8E1))
          : null,
      cells: [
        DataCell(Text(
            _regionName(r, fallback: isBold ? '합계' : '-'),
            style: style)),
        DataCell(
            Text(_fmt(r['수검국소'] ?? r['total']), style: style)),
        DataCell(
            Text(_fmt(r['완료'] ?? r['completed']), style: style)),
        DataCell(
            Text(_fmt(r['시기조정'] ?? r['adjusted']), style: style)),
        DataCell(Text(_fmt(r['폐'] ?? r['closed']), style: style)),
        DataCell(
            Text(_fmt(r['성능합격'] ?? r['perf_pass']), style: style)),
        DataCell(Text(
            _fmt(r['성능불합격'] ?? r['perf_fail']), style: style)),
        DataCell(
            Text(_fmt(r['서류합격'] ?? r['doc_pass']), style: style)),
        DataCell(Text(
            _fmt(r['서류불합격'] ?? r['doc_fail']), style: style)),
        DataCell(
            _buildRateCell(perfRate, isPerfRate: true, isBold: isBold)),
        DataCell(
            _buildRateCell(docRate, isPerfRate: false, isBold: isBold)),
      ],
    );
  }

  Widget _buildRateCell(double rate,
      {required bool isPerfRate, required bool isBold}) {
    Color bgColor;
    Color textColor;

    if (isPerfRate) {
      if (rate >= 98) {
        bgColor = const Color(0xFFE8F5E9);
        textColor = const Color(0xFF2E7D32);
      } else if (rate >= 95) {
        bgColor = const Color(0xFFFFF8E1);
        textColor = const Color(0xFFF57F17);
      } else {
        bgColor = const Color(0xFFFFEBEE);
        textColor = const Color(0xFFC62828);
      }
    } else {
      if (rate >= 85) {
        bgColor = const Color(0xFFE8F5E9);
        textColor = const Color(0xFF2E7D32);
      } else if (rate >= 80) {
        bgColor = const Color(0xFFFFF8E1);
        textColor = const Color(0xFFF57F17);
      } else {
        bgColor = const Color(0xFFFFEBEE);
        textColor = const Color(0xFFC62828);
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '${rate.toStringAsFixed(1)}%',
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
      child: Row(
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
    );
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
        SizedBox(
          width: 130,
          height: 130,
          child: CustomPaint(
            painter: _DonutPainter(slices: slices, total: total),
          ),
        ),
        const SizedBox(height: 10),
        ...slices.map((s) {
          final pctVal = total > 0 ? (s.value / total * 100) : 0.0;
          return Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: s.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(s.name,
                      style: const TextStyle(
                          fontSize: 10, color: Color(0xFF374151)),
                      overflow: TextOverflow.ellipsis),
                ),
                Text('${s.value.toInt()}건',
                    style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xFF6B7280))),
                const SizedBox(width: 6),
                Text('${pctVal.toStringAsFixed(1)}%',
                    style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF374151))),
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

    const double perfTarget = 98.5;
    const double docTarget = 85.5;
    const Color perfColor = Color(0xFF4CAF50);
    const Color docColor = Color(0xFF2196F3);
    const Color missColor = Color(0xFFE53935);
    final Color barBg = Colors.grey.shade100;

    return _chartSection(
      title: '본부별 목표 대비 합격율',
      icon: Icons.assessment,
      iconColor: _blue,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _legendDot(perfColor, '성능 (목표 $perfTarget%)'),
              const SizedBox(width: 16),
              _legendDot(docColor, '서류 (목표 $docTarget%)'),
              const SizedBox(width: 16),
              _legendDot(missColor, '미달'),
            ],
          ),
          const SizedBox(height: 12),
          ...regionData.map((r) {
            final name = _regionName(r);
            final perf =
                _asPercent(r['성능합격율'] ?? r['perf_pass_rate']);
            final doc =
                _asPercent(r['서류합격율'] ?? r['doc_pass_rate']);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 52,
                    child: Text(name,
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF374151))),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      children: [
                        _horizontalBar(
                          value: perf,
                          maxValue: 100,
                          color: perf >= perfTarget
                              ? perfColor
                              : missColor,
                          bgColor: barBg,
                          label: '${perf.toStringAsFixed(1)}%',
                          targetPct: perfTarget / 100,
                        ),
                        const SizedBox(height: 3),
                        _horizontalBar(
                          value: doc,
                          maxValue: 100,
                          color: doc >= docTarget
                              ? docColor
                              : missColor,
                          bgColor: barBg,
                          label: '${doc.toStringAsFixed(1)}%',
                          targetPct: docTarget / 100,
                        ),
                      ],
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

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label,
            style:
                const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
      ],
    );
  }

  Widget _horizontalBar({
    required double value,
    required double maxValue,
    required Color color,
    required Color bgColor,
    required String label,
    double? targetPct,
  }) {
    final fraction = (value / maxValue).clamp(0.0, 1.0);
    return SizedBox(
      height: 16,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final totalWidth = constraints.maxWidth;
          return Stack(
            children: [
              Container(
                width: totalWidth,
                height: 16,
                decoration: BoxDecoration(
                  color: bgColor,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              Container(
                width: totalWidth * fraction,
                height: 16,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              if (targetPct != null)
                Positioned(
                  left: totalWidth * targetPct.clamp(0.0, 1.0) - 1,
                  top: 0,
                  bottom: 0,
                  child: Container(width: 2, color: const Color(0xFF333333)),
                ),
              Positioned(
                right: 4,
                top: 1,
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF374151))),
              ),
            ],
          );
        },
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // D. 성능 합격율 주별 Trend — COMBO CHART (bars + line + table)
  // ══════════════════════════════════════════════════════════

  Widget _buildWeeklyTrendCombo() {
    final weeks =
        List<Map<String, dynamic>>.from(_weeklyTrend['weeks'] ?? []);
    if (weeks.isEmpty) return const SizedBox.shrink();

    return _chartSection(
      title: '성능 합격율 주별 Trend',
      icon: Icons.timeline,
      iconColor: _green,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 범례
          Row(
            children: [
              _legendDot(const Color(0xFF90CAF9), '대상 건수'),
              const SizedBox(width: 16),
              _legendDot(_primary, '합격율 (%)'),
              const SizedBox(width: 16),
              _legendDot(
                  _primary.withValues(alpha: 0.5), '목표 98.5%'),
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
          // Data table — 월별 가로 배치
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _groupWeeksByMonth(weeks).entries.map((entry) {
                final month = entry.key;
                final monthWeeks = entry.value;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: DataTable(
                    headingRowColor: WidgetStateProperty.all(const Color(0xFFF3F4F6)),
                    headingRowHeight: 28,
                    dataRowMinHeight: 26,
                    dataRowMaxHeight: 26,
                    columnSpacing: 10,
                    horizontalMargin: 6,
                    headingTextStyle: const TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
                    dataTextStyle: const TextStyle(fontSize: 9, color: Color(0xFF111827)),
                    columns: [
                      DataColumn(label: Text('$month')),
                      const DataColumn(label: Text('대상'), numeric: true),
                      const DataColumn(label: Text('불합'), numeric: true),
                      const DataColumn(label: Text('합격율'), numeric: true),
                    ],
                    rows: monthWeeks.map((w) {
                      final rate = _asPercent(w['합격율'] ?? 0);
                      final weekLabel = (w['주차'] ?? '-').toString().replaceAll(RegExp(r'^\d+월'), '');
                      return DataRow(cells: [
                        DataCell(Text(weekLabel, style: const TextStyle(fontSize: 9))),
                        DataCell(Text(_fmt(w['수검'] ?? 0), style: const TextStyle(fontSize: 9))),
                        DataCell(Text(_fmt(w['불합격'] ?? 0), style: const TextStyle(fontSize: 9))),
                        DataCell(Text('${rate.toStringAsFixed(1)}%',
                            style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600,
                                color: rate >= 98.5 ? const Color(0xFF2E7D32) : _primary))),
                      ]);
                    }).toList(),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  /// 주차를 월별로 그룹핑 (1월~12월 전부 포함)
  Map<String, List<Map<String, dynamic>>> _groupWeeksByMonth(List<Map<String, dynamic>> weeks) {
    final grouped = <String, List<Map<String, dynamic>>>{};
    // 1~12월 빈 리스트 초기화
    for (int m = 1; m <= 12; m++) {
      grouped['$m월'] = [];
    }
    for (final w in weeks) {
      final wk = (w['주차'] ?? '').toString();
      final match = RegExp(r'^(\d{1,2})월').firstMatch(wk);
      final month = match != null ? '${match.group(1)}월' : '기타';
      grouped.putIfAbsent(month, () => []).add(w);
    }
    return grouped;
  }

  // ══════════════════════════════════════════════════════════
  // E. Acc.담당별 주별 Trend — 9 SMALL LINE CHARTS (3x3 grid)
  // ══════════════════════════════════════════════════════════

  Widget _buildRegionWeeklyGrid() {
    final regionsMap = (_regionWeeklyTrend['regions']
            as Map<String, dynamic>?) ??
        {};
    if (regionsMap.isEmpty) return const SizedBox.shrink();

    // Build ordered list using _regionOrder, fill missing
    final charts = <Widget>[];
    for (final rName in _regionOrder) {
      final data = regionsMap[rName];
      final weekList = data != null
          ? List<Map<String, dynamic>>.from(data as List)
          : <Map<String, dynamic>>[];
      charts.add(_smallLineChart(rName, weekList));
    }
    // Any extra regions not in _regionOrder
    for (final key in regionsMap.keys) {
      if (!_regionOrder.contains(key)) {
        final weekList =
            List<Map<String, dynamic>>.from(regionsMap[key] as List);
        charts.add(_smallLineChart(key, weekList));
      }
    }

    return _chartSection(
      title: 'Acc.담당별 주별 Trend',
      icon: Icons.grid_view,
      iconColor: _primary,
      child: LayoutBuilder(
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
    );
  }

  /// 주차 라벨을 "1-1", "1-2" 등으로 축약
  static String _abbreviateWeekLabel(String raw) {
    // "1월1주" → "1-1", "12월4주" → "12-4"
    final m = RegExp(r'(\d+)월(\d+)주').firstMatch(raw);
    if (m != null) return '${m[1]}-${m[2]}';
    return raw.length > 3 ? raw.substring(0, 3) : raw;
  }

  Widget _smallLineChart(
      String regionName, List<Map<String, dynamic>> weekData) {
    final values =
        weekData.map((w) => _asPercent(w['합격율'] ?? 0)).toList();
    final labels = weekData
        .map((w) => _abbreviateWeekLabel((w['주차'] ?? '').toString()))
        .toList();

    return Container(
      height: 160,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(regionName,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF374151))),
          const SizedBox(height: 4),
          Expanded(
            child: values.isEmpty
                ? const Center(
                    child: Text('데이터 없음',
                        style: TextStyle(
                            fontSize: 10,
                            color: Color(0xFF9CA3AF))))
                : CustomPaint(
                    size: Size.infinite,
                    painter: _SmallLineChartPainter(
                      values: values,
                      labels: labels,
                      target: 98.5,
                      lineColor: _primary,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // F. 장비 Type별 불합격 현황 (Top3) — CROSS-TAB TABLE
  // ══════════════════════════════════════════════════════════

  Widget _buildEquipTypeCrosstab() {
    final crosstab = List<Map<String, dynamic>>.from(
        _analysis['장비타입별_크로스탭'] ?? []);
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
          headingRowHeight: 34,
          dataRowMinHeight: 30,
          dataRowMaxHeight: 30,
          columnSpacing: 14,
          horizontalMargin: 10,
          headingTextStyle: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Color(0xFF374151)),
          dataTextStyle:
              const TextStyle(fontSize: 10, color: Color(0xFF111827)),
          columns: [
            const DataColumn(label: Text('구분')),
            ...orderedRegions
                .map((r) => DataColumn(label: Text(r), numeric: true)),
            const DataColumn(label: Text('총합계'), numeric: true),
            const DataColumn(label: Text('비율'), numeric: true),
          ],
          rows: crosstab.map((row) {
            final typeName = row['타입'] ?? '-';
            final byRegion =
                (row['본부별'] as Map<String, dynamic>?) ?? {};
            final total = _toDouble(row['총합계'] ?? 0);
            final isTotal = typeName == '성능불합격(건)';
            final ratio =
                grandTotal > 0 ? (total / grandTotal * 100) : 0.0;
            final style = TextStyle(
              fontSize: 10,
              fontWeight: isTotal ? FontWeight.w700 : FontWeight.w400,
              color: const Color(0xFF111827),
            );

            return DataRow(
              color: isTotal
                  ? WidgetStateProperty.all(
                      const Color(0xFFFFF8E1))
                  : null,
              cells: [
                DataCell(Text(typeName, style: style)),
                ...orderedRegions.map((r) {
                  final v = byRegion[r];
                  return DataCell(
                      Text(v != null ? _fmt(v) : '-', style: style));
                }),
                DataCell(Text(_fmt(total.toInt()),
                    style: style.copyWith(fontWeight: FontWeight.w700))),
                DataCell(Text(
                    isTotal ? '100%' : '${ratio.toStringAsFixed(1)}%',
                    style: style)),
              ],
            );
          }).toList(),
        ),
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
    final radius = math.min(size.width, size.height) / 2 - 4;
    final innerRadius = radius * 0.55;
    double startAngle = -math.pi / 2;

    for (final slice in slices) {
      final sweepAngle = 2 * math.pi * (slice.value / total);
      final paint = Paint()
        ..color = slice.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius - innerRadius
        ..strokeCap = StrokeCap.butt;
      canvas.drawArc(
        Rect.fromCircle(
            center: center,
            radius: (radius + innerRadius) / 2),
        startAngle,
        sweepAngle,
        false,
        paint,
      );
      startAngle += sweepAngle;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.slices != slices || old.total != total;
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

    // Rate always 90-100
    const rateMin = 90.0;
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

    // Draw target line at 98.5%
    final targetY =
        topPad + chartH * (1 - (98.5 - rateMin) / (rateMax - rateMin));
    final dashedPaint = Paint()
      ..color = const Color(0xFFE53935)
      ..strokeWidth = 1.0;
    const dashW = 5.0;
    const dashS = 3.0;
    double dx = leftPad;
    while (dx < size.width - rightPad) {
      canvas.drawLine(
        Offset(dx, targetY),
        Offset(math.min(dx + dashW, size.width - rightPad), targetY),
        dashedPaint,
      );
      dx += dashW + dashS;
    }

    // Draw rate line with markers
    final linePaint = Paint()
      ..color = const Color(0xFFE53935)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    final dotPaint = Paint()
      ..color = const Color(0xFFE53935)
      ..style = PaintingStyle.fill;

    final points = <Offset>[];
    for (int i = 0; i < weeks.length; i++) {
      final rate = asPercent(weeks[i]['합격율'] ?? 0);
      final clamped = rate.clamp(rateMin, rateMax);
      final x = leftPad + spacing * i + spacing / 2;
      final y = topPad +
          chartH * (1 - (clamped - rateMin) / (rateMax - rateMin));
      points.add(Offset(x, y));
    }

    if (points.length >= 2) {
      final path = Path()..moveTo(points[0].dx, points[0].dy);
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
      canvas.drawPath(path, linePaint);
    }

    for (final p in points) {
      canvas.drawCircle(p, 4, dotPaint);
      canvas.drawCircle(
          p,
          2.5,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.fill);
    }

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
  final List<String> labels;
  final double target;
  final Color lineColor;

  _SmallLineChartPainter({
    required this.values,
    this.labels = const [],
    required this.target,
    required this.lineColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;

    const double pad = 4;
    const double bottomPad = 14; // extra space for X-axis labels
    final chartW = size.width - pad * 2;
    final chartH = size.height - pad - bottomPad;

    // Y range: auto from min value, at least 90-100
    final dataMin = values.fold<double>(100, math.min);
    final yMin = math.min(dataMin - 2, 90.0).floorToDouble();
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

    // Target dashed line
    final targetY = yFor(target);
    final dashedPaint = Paint()
      ..color = lineColor.withValues(alpha: 0.4)
      ..strokeWidth = 1.0;
    const dw = 4.0;
    const ds = 2.0;
    double dx = pad;
    while (dx < size.width - pad) {
      canvas.drawLine(
        Offset(dx, targetY),
        Offset(math.min(dx + dw, size.width - pad), targetY),
        dashedPaint,
      );
      dx += dw + ds;
    }

    // Target label
    final tp = TextPainter(
      text: TextSpan(
          text: '${target.toStringAsFixed(1)}%',
          style: TextStyle(fontSize: 8, color: lineColor.withValues(alpha: 0.6))),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(size.width - pad - tp.width, targetY - tp.height - 1));

    // Data line
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final dotPaint = Paint()
      ..color = lineColor
      ..style = PaintingStyle.fill;

    final points = <Offset>[];
    for (int i = 0; i < values.length; i++) {
      points.add(Offset(xFor(i), yFor(values[i])));
    }

    if (points.length >= 2) {
      final path = Path()..moveTo(points[0].dx, points[0].dy);
      for (int i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
      canvas.drawPath(path, linePaint);
    }

    for (final p in points) {
      canvas.drawCircle(p, 3, dotPaint);
      canvas.drawCircle(
          p,
          1.5,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.fill);
    }

    // X-axis labels (abbreviated)
    if (labels.isNotEmpty) {
      // Show every Nth label to avoid overlap
      final step = values.length > 8 ? 2 : 1;
      for (int i = 0; i < values.length && i < labels.length; i += step) {
        final ltp = TextPainter(
          text: TextSpan(
              text: labels[i],
              style: const TextStyle(fontSize: 7, color: Color(0xFF9CA3AF))),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout();
        final lx = xFor(i) - ltp.width / 2;
        ltp.paint(canvas, Offset(lx.clamp(0, size.width - ltp.width), pad + chartH + 2));
      }
    }

    // Last value label
    if (values.isNotEmpty) {
      final lastVal = values.last;
      final lastPt = points.last;
      final valTp = TextPainter(
        text: TextSpan(
            text: '${lastVal.toStringAsFixed(1)}%',
            style: TextStyle(
                fontSize: 8,
                fontWeight: FontWeight.w700,
                color: lastVal >= target
                    ? const Color(0xFF2E7D32)
                    : lineColor)),
        textDirection: TextDirection.ltr,
      )..layout();
      double labelX = lastPt.dx - valTp.width / 2;
      if (labelX + valTp.width > size.width) {
        labelX = size.width - valTp.width;
      }
      if (labelX < 0) labelX = 0;
      valTp.paint(canvas, Offset(labelX, lastPt.dy - valTp.height - 3));
    }
  }

  @override
  bool shouldRepaint(covariant _SmallLineChartPainter old) =>
      old.values != values || old.target != target;
}
