import 'package:excel/excel.dart' as excel_pkg;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/ds_data_service.dart';
import '../services/erp_ds_compare_service.dart';
import '../services/inspection_service.dart';
import '../services/excel_export_stub.dart'
    if (dart.library.io) '../services/excel_export_mobile.dart'
    if (dart.library.html) '../services/excel_export_web.dart' as platform_export;
import '../services/kakao_geocoding_web.dart';
import '../widgets/app_loader.dart';
import '../widgets/progress_dialog.dart';
import '../widgets/user_profile_button.dart';
import 'inspection_result_screen.dart' show RoadviewDialog;
import 'tower_classification_screen.dart';

class ErpDsCompareScreen extends StatefulWidget {
  final List<String>? initialLicenseNos;
  final String? initialAccessDivision;
  final bool initialMultiDivision;
  final List<String>? initialSchedulePks;
  final Map<String, Map<String, String>>? initialSchedMap;
  final void Function(List<String> licenseNos)? onScheduleNavigate;

  const ErpDsCompareScreen({
    super.key,
    this.initialLicenseNos,
    this.initialAccessDivision,
    this.initialMultiDivision = false,
    this.initialSchedulePks,
    this.initialSchedMap,
    this.onScheduleNavigate,
  });

  @override
  State<ErpDsCompareScreen> createState() => _ErpDsCompareScreenState();
}

class _ErpDsCompareScreenState extends State<ErpDsCompareScreen> {
  // 기존 메뉴들과 통일된 컬러 팔레트
  static const Color _primaryColor = Color(0xFFE53935);
  static const Color _blueAccent = Color(0xFF4A90D9);
  static const Color _greenColor = Color(0xFF43A047);
  static const Color _themeColor = Color(0xFF1565C0);

  // access담당 한글명 → auth division ID
  static const Map<String, String> _accessToAuthId = {
    '강남': 'gangnam', '강남본부': 'gangnam',
    '강북': 'gangbuk', '강북본부': 'gangbuk',
    '경기': 'gyeonggi', '경기본부': 'gyeonggi',
    '인천': 'incheon', '인천본부': 'incheon',
    '강원': 'gangwon', '강원본부': 'gangwon',
    '충청': 'chungcheong', '충청본부': 'chungcheong',
    '경북': 'gyeongbuk', '경북본부': 'gyeongbuk',
    '경남': 'gyeongnam', '경남본부': 'gyeongnam',
    '서부': 'seobu', '서부본부': 'seobu',
  };

  // 본부 목록
  static const _divisionOptions = [
    {'id': 'gangnam', 'name': '강남'},
    {'id': 'gangbuk', 'name': '강북'},
    {'id': 'gyeonggi', 'name': '경기'},
    {'id': 'incheon', 'name': '인천'},
    {'id': 'gangwon', 'name': '강원'},
    {'id': 'chungcheong', 'name': '충청'},
    {'id': 'gyeongbuk', 'name': '경북'},
    {'id': 'gyeongnam', 'name': '경남'},
    {'id': 'seobu', 'name': '서부'},
  ];

  final _service = ErpDsCompareService();
  final _dsService = DsDataService();
  final _inspectionService = InspectionService();
  final _inputCtrl = TextEditingController();

  Map<String, Map<String, String>>? _schedMap;

  int _step = 0;
  String? _selectedDivisionId;
  List<DsUploadInfo> _dsUploads = [];
  DsUploadInfo? _selectedUpload;
  bool _loadingUploads = false;
  bool _comparing = false;
  String? _error;
  ErpDsCompareResult? _result;
  String _filter = '전체';
  Set<String> _selectedForPreCheck = {};
  bool _markingPreCheck = false;

  // 결과 테이블: 컬럼 정의 (가용 폭에 비례 분배)
  static const List<String> _colTitles = [
    '허가번호', '호출명칭', '본부', '통시', '공대',
    'ERP 설치대', 'DS 설치대', '설치대 비교',
    'ERP 일련번호', 'DS 일련번호', '일련번호 비교',
    'ERP활용구분', 'DS활용구분', '활용구분비교',
  ];
  static const List<double> _colFlex = [
    13, 16, 8, 9, 9,
    14, 14, 11,
    18, 18, 13,
    12, 12, 11,
  ];

  // 그룹 경계: 이 인덱스 컬럼 오른쪽에 진한 구분선 그림
  static const Set<int> _groupBoundaryRight = {7, 10};
  // 비교 배지 컬럼: 창 크기에 따라 FittedBox로 자동 축소
  static const Set<int> _chipCols = {7, 10, 13};

  // 사용자가 드래그로 조정한 컬럼 너비. null이면 가용폭에 비례 분배.
  List<double>? _colWidths;
  double _lastTableWidth = 0;
  static const double _minColWidth = 50.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final auth = context.read<AuthService>();
      _service.setAuthToken(auth.authToken);
      _dsService.setAuthToken(auth.authToken);
      _inspectionService.setAuthToken(auth.authToken);

      // 일정화면에서 넘어온 경우 허가번호 자동 입력
      if (widget.initialLicenseNos != null && widget.initialLicenseNos!.isNotEmpty) {
        _inputCtrl.text = widget.initialLicenseNos!.join('\n');
        _schedMap = widget.initialSchedMap;
        setState(() {});
      }

      // 본부 결정: initialAccessDivision → 내 본부 순서로 fallback
      String? divId;
      if (widget.initialAccessDivision != null) {
        divId = _accessToAuthId[widget.initialAccessDivision!];
      }
      divId ??= auth.currentDivisionId;

      if (divId != null) {
        setState(() => _selectedDivisionId = divId);
        _loadDsUploads(divId);
      }
    });
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  String _getDsDivisionId(String authDivId) {
    return DsDataService.authToDsDivision[authDivId] ?? authDivId;
  }

  Future<void> _loadDsUploads(String authDivId) async {
    final dsDivId = _getDsDivisionId(authDivId);
    setState(() {
      _loadingUploads = true;
      _dsUploads = [];
      _selectedUpload = null;
    });
    try {
      final stats = await _dsService.getStats(divisionId: dsDivId);
      final completed =
          stats.uploads.where((u) => u.status == 'completed').toList();
      if (mounted) {
        setState(() {
          _dsUploads = completed;
          _selectedUpload = completed.isNotEmpty ? completed.first : null;
          _loadingUploads = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingUploads = false;
          _error = 'DS 업로드 조회 실패: $e';
        });
      }
    }
  }

  List<String> _parseZpwinoList() {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return [];
    return text
        .split(RegExp(r'[\n,;]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
  }

  Future<void> _doCompare() async {
    final list = _parseZpwinoList();
    if (list.isEmpty) {
      setState(() => _error = '검색어를 입력하세요.');
      return;
    }
    if (list.length > 500) {
      setState(() => _error = '최대 500건까지 비교 가능합니다.');
      return;
    }
    if (_selectedUpload == null) {
      setState(() => _error = 'DS 업로드를 선택하세요.');
      return;
    }
    setState(() {
      _comparing = true;
      _error = null;
    });
    try {
      final result = await _service.compare(
        zpwinoList: list,
        divisionId: _selectedUpload!.divisionId,
        divisionCode: _selectedUpload!.divisionCode,
        importDate: _selectedUpload!.actualDate,
      );
      if (mounted) {
        setState(() {
          _result = result;
          _step = 1;
          _comparing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _comparing = false;
        });
      }
    }
  }

  void _reset() {
    setState(() {
      _step = 0;
      _result = null;
      _filter = '전체';
      _error = null;
    });
  }

  Future<void> _exportInspectionReport() async {
    final licenseNos = _result!.items.map((e) => e.zpwino).toList();
    final d = ProgressDialog(context);
    d.show(message: '검사내역서 생성 중...');
    try {
      final year = DateTime.now().year;
      final bytes = await _inspectionService.exportInspectionReport(
        year: year,
        licenseNos: licenseNos,
        sheetTitle: '전산비교_${licenseNos.length}건',
      );
      final fileName = '검사내역서_${year}년_전산비교.xlsx';
      await platform_export.saveExcelFile(bytes, fileName);
      await d.complete(message: '검사내역서 다운로드 완료');
    } catch (e) {
      await d.error(message: '검사내역서 생성 실패: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: _step == 0
            ? Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1200),
                  child: _buildInputStep(),
                ),
              )
            : _buildResultStep(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: Colors.white,
      foregroundColor: const Color(0xFF111827),
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      bottom: const PreferredSize(
        preferredSize: Size.fromHeight(1),
        child: Divider(height: 1, color: Color(0xFFE5E7EB)),
      ),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Color(0xFF111827)),
        onPressed: () => Navigator.pop(context),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: _themeColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(
              Icons.compare_arrows,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            '전산자료 비교',
            style: TextStyle(
              color: Color(0xFF111827),
              fontSize: 17,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
      centerTitle: true,
      actions: [
        UserProfileButton(
          onLogout: () async {
            await context.read<AuthService>().signOut();
            if (mounted) {
              Navigator.of(context).popUntil((route) => route.isFirst);
            }
          },
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  // ── Step 0: 설정 + 입력 ──

  Widget _buildInputStep() {
    final zpwinoCount = _parseZpwinoList().length;
    final divisionName = _divisionOptions
        .where((d) => d['id'] == _selectedDivisionId)
        .map((d) => d['name']!)
        .firstOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 일정화면에서 자동 입력된 경우 안내
        if (widget.initialLicenseNos != null && widget.initialLicenseNos!.isNotEmpty) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: _themeColor.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _themeColor.withValues(alpha: 0.2)),
            ),
            child: Row(children: [
              const Icon(Icons.check_circle_outline, size: 16, color: _themeColor),
              const SizedBox(width: 8),
              Text(
                '일정 및 통계에서 ${widget.initialLicenseNos!.length}건 자동 입력됨',
                style: const TextStyle(fontSize: 13, color: _themeColor, fontWeight: FontWeight.w500),
              ),
            ]),
          ),
          if (widget.initialMultiDivision)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.orange.shade200),
              ),
              child: Row(children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '선택된 항목에 여러 본부가 포함되어 있습니다. '
                    'Access담당 기준 가장 많은 본부(${widget.initialAccessDivision})의 DS 파일로 자동 조회됩니다.',
                    style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                  ),
                ),
              ]),
            ),
        ],
        // 본부 + DS 파일 선택 카드
        _buildCard(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // 본부 선택
            Row(
              children: [
                const Icon(Icons.business, color: _themeColor, size: 22),
                const SizedBox(width: 8),
                const Text(
                  '본부 선택',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                if (divisionName != null) ...[
                  const Spacer(),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _themeColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      divisionName,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _themeColor,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(10),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedDivisionId,
                  icon: const Icon(Icons.arrow_drop_down,
                      color: _themeColor, size: 20),
                  isExpanded: true,
                  isDense: true,
                  dropdownColor: Colors.white,

                  borderRadius: BorderRadius.circular(12),
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 13,
                  ),
                  items: _divisionOptions.map((d) {
                    return DropdownMenuItem(
                      value: d['id'],
                      child: Text(d['name']!),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() => _selectedDivisionId = val);
                      _loadDsUploads(val);
                    }
                  },
                ),
              ),
            ),

            const SizedBox(height: 20),
            const Divider(height: 1),
            const SizedBox(height: 20),

            // DS 파일 선택
            Row(
              children: [
                const Icon(Icons.folder_open, color: _themeColor, size: 22),
                const SizedBox(width: 8),
                const Text(
                  'DS 파일 선택',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (_selectedUpload != null)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _greenColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_selectedUpload!.totalRows}행',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _greenColor,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loadingUploads)
              Padding(
                padding: const EdgeInsets.all(16),
                child: AppLoader.centered(),
              )
            else if (_dsUploads.isEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F6FA),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 18, color: Colors.grey.shade500),
                    const SizedBox(width: 8),
                    Text(
                      '해당 본부에 업로드된 DS 파일이 없습니다.',
                      style: TextStyle(
                          color: Colors.grey.shade600, fontSize: 13),
                    ),
                  ],
                ),
              )
            else
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<DsUploadInfo>(
                    value: _selectedUpload,
                    icon: const Icon(Icons.arrow_drop_down,
                        color: _themeColor, size: 20),
                    isExpanded: true,
                    isDense: true,
                    dropdownColor: Colors.white,

                    borderRadius: BorderRadius.circular(12),
                    style: const TextStyle(
                      color: Colors.black87,
                      fontSize: 13,
                    ),
                    items: _dsUploads.map((u) {
                      final label =
                          '${u.divisionName} - ${u.actualDate} (${u.totalRows}행)';
                      return DropdownMenuItem(
                          value: u, child: Text(label));
                    }).toList(),
                    onChanged: (val) =>
                        setState(() => _selectedUpload = val),
                  ),
                ),
              ),
          ]),
        ),

        const SizedBox(height: 16),

        // 검색어 입력 카드
        _buildCard(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.search, color: _themeColor, size: 22),
              const SizedBox(width: 8),
              const Text(
                '검색어 입력',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: zpwinoCount > 500
                      ? _primaryColor.withValues(alpha: 0.1)
                      : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$zpwinoCount / 500건',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: zpwinoCount > 500
                        ? _primaryColor
                        : Colors.grey.shade600,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: TextField(
                controller: _inputCtrl,
                maxLines: 10,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.all(14),
                  hintText:
                      '허가번호, 호출명칭, 주소를 입력하세요\n(줄바꿈, 쉼표, 세미콜론으로 구분)\n\n예: 3220056100000756\n     SKT홍대\n     서울시 마포구...',
                  hintStyle: TextStyle(
                      color: Colors.grey.shade400, fontSize: 13),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
        ),

        const SizedBox(height: 16),

        if (_error != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.red.shade50,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.red.shade200),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline,
                    size: 18, color: Colors.red.shade600),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_error!,
                      style: TextStyle(
                          color: Colors.red.shade700, fontSize: 13)),
                ),
              ],
            ),
          ),

        // 비교 시작 버튼
        SizedBox(
          height: 50,
          child: ElevatedButton.icon(
            onPressed: _comparing ||
                    zpwinoCount == 0 ||
                    _selectedUpload == null
                ? null
                : _doCompare,
            icon: _comparing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.compare_arrows),
            label: Text(
              _comparing ? '비교 중...' : '비교 시작',
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _themeColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              elevation: 0,
            ),
          ),
        ),
      ],
    );
  }

  // ── Step 1: 결과 ──

  Widget _buildResultStep() {
    final r = _result!;
    final filteredItems = _getFilteredItems();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 경고
        if (r.warnings.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: r.warnings.map((w) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber, size: 16, color: Colors.orange.shade700),
                        const SizedBox(width: 8),
                        Expanded(child: Text(w,
                            style: TextStyle(fontSize: 13, color: Colors.orange.shade800))),
                      ],
                    ),
                  )).toList(),
            ),
          ),

        // 사전점검 회신 카드: 불일치가 있거나 일정과 연결된 경우 표시
        if (_hasAnyMismatch(r) || (widget.initialSchedulePks?.isNotEmpty ?? false)) ...[
          _buildPreCheckReplyCard(r),
          const SizedBox(height: 16),
        ],
        // 요약 카드
        _buildCard(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.analytics_outlined,
                  color: _themeColor, size: 22),
              const SizedBox(width: 8),
              const Text(
                '비교 결과 요약',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _reset,
                icon: const Icon(Icons.refresh, size: 16),
                label:
                    const Text('다시 입력', style: TextStyle(fontSize: 13)),
                style: TextButton.styleFrom(foregroundColor: _blueAccent),
              ),
            ]),
            const SizedBox(height: 16),
            // 조회 통계
            Wrap(spacing: 8, runSpacing: 8, children: [
              _buildStatChip('전체', r.total, Colors.grey.shade600),
              _buildStatChip('ERP', r.erpFound, _blueAccent),
              _buildStatChip(
                  'DS장치', r.dsDeviceFound, const Color(0xFF00897B)),
              _buildStatChip(
                  'DS안테나', r.dsAntennaFound, const Color(0xFF5C6BC0)),
            ]),
            const SizedBox(height: 16),
            _buildSummaryRow('설치대', r.summary),
            const SizedBox(height: 10),
            _buildSummaryRow('일련번호', r.summary, prefix: 'serial'),
          ]),
        ),

        const SizedBox(height: 16),

        // 필터 칩
        _buildCard(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.filter_list, color: _themeColor, size: 22),
              SizedBox(width: 8),
              Text(
                '필터',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _buildFilterChip('전체', filteredItems.length),
              _buildFilterChip('일치', null),
              _buildFilterChip('부분일치', null),
              _buildFilterChip('불일치', null),
              _buildFilterChip('DS누락', null),
              _buildFilterChip('확인필요', null),
            ]),
          ]),
        ),

        const SizedBox(height: 16),

        // 결과 테이블
        _buildCard(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.table_chart, color: _themeColor, size: 22),
              const SizedBox(width: 8),
              const Text(
                '상세 결과',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _themeColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${filteredItems.length}건',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _themeColor,
                  ),
                ),
              ),
              const Spacer(),
              if (context.read<AuthService>().isAdmin) ...[
                ElevatedButton.icon(
                  onPressed: _selectedForPreCheck.isEmpty || _markingPreCheck
                      ? null
                      : _markPreChecked,
                  icon: _markingPreCheck
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.check_circle_outline, size: 16),
                  label: Text(
                    _selectedForPreCheck.isEmpty
                        ? '사전점검완료로 표시'
                        : '사전점검완료 (${_selectedForPreCheck.length}건)',
                    style: const TextStyle(fontSize: 13),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00897B),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade300,
                    disabledForegroundColor: Colors.grey.shade500,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              if (widget.onScheduleNavigate != null) ...[
                ElevatedButton.icon(
                  onPressed: () => widget.onScheduleNavigate!(
                      _result!.items.map((e) => e.zpwino).toList()),
                  icon: const Icon(Icons.event_note, size: 16),
                  label: const Text('일정 및 통계로 이동', style: TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6A1B9A),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              ElevatedButton.icon(
                onPressed: _exportInspectionReport,
                icon: const Icon(Icons.assignment, size: 16),
                label: const Text('검사내역서 출력', style: TextStyle(fontSize: 13)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  elevation: 0,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _exportExcel,
                icon: const Icon(Icons.download, size: 16),
                label: const Text('엑셀 다운로드', style: TextStyle(fontSize: 13)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  elevation: 0,
                ),
              ),
            ]),
            const SizedBox(height: 12),
            _buildResultTable(filteredItems, r),
          ]),
        ),
      ],
    );
  }

  // ── Excel Export ──

  Future<void> _exportExcel() async {
    final r = _result;
    if (r == null) return;

    try {
      final excel = excel_pkg.Excel.createExcel();
      final sheetName = '전산자료비교';
      excel.rename(excel.getDefaultSheet()!, sheetName);
      final sheet = excel[sheetName];

      // 헤더
      final headers = [
        '허가번호', '호출명칭', '본부', '통시', '공대',
        'ERP 설치대', 'DS 설치대', '설치대 비교',
        'ERP 일련번호', 'DS 일련번호', '일련번호 비교',
        'ERP활용구분', 'DS활용구분', '활용구분비교',
      ];
      for (var i = 0; i < headers.length; i++) {
        final cell = sheet.cell(
            excel_pkg.CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0));
        cell.value = excel_pkg.TextCellValue(headers[i]);
        cell.cellStyle = excel_pkg.CellStyle(
          bold: true,
          backgroundColorHex: excel_pkg.ExcelColor.fromHexString('#D9E1F2'),
        );
      }

      // 데이터 행
      final items = _getFilteredItems();
      for (var rowIdx = 0; rowIdx < items.length; rowIdx++) {
        final item = items[rowIdx];

        final values = [
          item.zpwino, _zpwina(item), _areaHdofcNm(item),
          _tongsi(item), _gongdae(item),
          item.erpZpirty3, item.dsTowerType, item.towerMatch,
          item.erpSerial, item.dsSerial, item.serialMatch,
          _erpPrac1(item), item.dsPrac1, _prac1Match(item),
        ];
        for (var colIdx = 0; colIdx < values.length; colIdx++) {
          sheet
              .cell(excel_pkg.CellIndex.indexByColumnRow(
                  columnIndex: colIdx, rowIndex: rowIdx + 1))
              .value = excel_pkg.TextCellValue(values[colIdx]);
        }
      }

      // 컬럼 너비 설정
      final widths = [15.0, 15.0, 10.0, 15.0, 15.0, 20.0, 20.0, 10.0, 8.0, 8.0, 10.0, 20.0, 20.0, 10.0];
      for (var i = 0; i < widths.length; i++) {
        sheet.setColumnWidth(i, widths[i]);
      }

      final bytes = excel.encode();
      if (bytes == null) return;

      final now = DateTime.now();
      final fileName =
          '전산자료비교_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.xlsx';

      await platform_export.saveExcelFile(Uint8List.fromList(bytes), fileName);

      if (mounted) {
        final d = ProgressDialog(context);
        await d.complete(message: '$fileName 다운로드 완료');
      }
    } catch (e) {
      if (mounted) {
        final d = ProgressDialog(context);
        await d.error(message: '엑셀 다운로드 실패: $e');
      }
    }
  }

  // ── 결과 테이블 (헤더 sticky + 가용 폭에 비례 분배) ──

  Widget _buildResultTable(List<CompareItem> items, ErpDsCompareResult r) {
    const tableHeight = 560.0;
    const chkW = 36.0;
    final isAdmin = context.read<AuthService>().isAdmin;

    return SizedBox(
      height: tableHeight,
      child: LayoutBuilder(
        builder: (ctx, cons) {
          _ensureColWidths(isAdmin ? cons.maxWidth - chkW : cons.maxWidth);
          final widths = _colWidths!;
          final allSelected = items.isNotEmpty &&
              items.every((it) => _selectedForPreCheck.contains(it.zpwino));
          return Column(
            children: [
              // 헤더 (sticky)
              Container(
                decoration: const BoxDecoration(
                  color: Color(0xFFF5F7FA),
                  border: Border(
                    top: BorderSide(color: Color(0xFFE0E4EA)),
                    bottom: BorderSide(color: Color(0xFFE0E4EA)),
                  ),
                ),
                height: 44,
                child: Row(
                  children: [
                    if (isAdmin)
                      SizedBox(
                        width: chkW,
                        height: 44,
                        child: Checkbox(
                          value: allSelected,
                          tristate: false,
                          activeColor: const Color(0xFF00897B),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          onChanged: (_) => setState(() {
                            if (allSelected) {
                              _selectedForPreCheck.removeAll(items.map((e) => e.zpwino));
                            } else {
                              _selectedForPreCheck.addAll(items.map((e) => e.zpwino));
                            }
                          }),
                        ),
                      ),
                    ...List.generate(_colTitles.length, (i) => _buildHeaderCell(i, widths[i])),
                  ],
                ),
              ),
              // 바디 (세로 스크롤)
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemExtent: 48,
                  itemBuilder: (ctx, idx) {
                    return _buildDataRow(items[idx], r, idx, widths, isAdmin ? chkW : 0);
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // 가용 폭 변동 시: 기존 비율 유지하며 너비를 재정규화. 최초 진입 시에는 _colFlex로 초기화.
  void _ensureColWidths(double maxWidth) {
    if (maxWidth <= 0) return;
    if (_colWidths == null) {
      final flexSum = _colFlex.fold<double>(0, (a, b) => a + b);
      _colWidths = _colFlex.map((f) => maxWidth * f / flexSum).toList();
      _lastTableWidth = maxWidth;
      return;
    }
    if ((maxWidth - _lastTableWidth).abs() > 0.5) {
      final cur = _colWidths!;
      final curSum = cur.fold<double>(0, (a, b) => a + b);
      if (curSum > 0) {
        _colWidths = cur.map((w) => w * maxWidth / curSum).toList();
      }
      _lastTableWidth = maxWidth;
    }
  }

  // 컬럼 i와 i+1 경계에서 드래그: i는 늘어나고 i+1은 줄어든다 (합계 유지 → 컨테이너 넘침 없음).
  void _onResizeColumn(int i, double delta) {
    final widths = _colWidths;
    if (widths == null || i < 0 || i >= widths.length - 1) return;
    final left = widths[i];
    final right = widths[i + 1];
    double newLeft = left + delta;
    double newRight = right - delta;
    if (newLeft < _minColWidth) {
      newRight -= (_minColWidth - newLeft);
      newLeft = _minColWidth;
    }
    if (newRight < _minColWidth) {
      newLeft -= (_minColWidth - newRight);
      newRight = _minColWidth;
    }
    if (newLeft < _minColWidth || newRight < _minColWidth) return;
    setState(() {
      widths[i] = newLeft;
      widths[i + 1] = newRight;
    });
  }

  Widget _buildHeaderCell(int i, double width) {
    final isGroupBoundary = _groupBoundaryRight.contains(i);
    final isLast = i == _colTitles.length - 1;
    return SizedBox(
      width: width,
      height: 44,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: width,
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: isGroupBoundary
                ? const BoxDecoration(
                    border: Border(
                      right: BorderSide(color: Color(0xFF9AA3AE), width: 2),
                    ),
                  )
                : null,
            child: Text(
              _colTitles[i],
              style: _headerStyle,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
          if (!isLast && !isGroupBoundary)
            Positioned(
              right: 8,
              top: 10,
              bottom: 10,
              child: Container(width: 1, color: const Color(0xFFD1D5DB)),
            ),
          if (!isLast)
            Positioned(
              right: -4,
              top: 0,
              bottom: 0,
              width: 8,
              child: _buildResizeHandle(i),
            ),
        ],
      ),
    );
  }

  Widget _buildResizeHandle(int i) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (d) => _onResizeColumn(i, d.delta.dx),
        child: const SizedBox.expand(),
      ),
    );
  }

  Widget _buildDataRow(
      CompareItem item, ErpDsCompareResult r, int idx, List<double> widths,
      [double chkW = 0]) {
    final isSelected = _selectedForPreCheck.contains(item.zpwino);
    final cells = <Widget>[
      // 0 허가번호
      Text(item.zpwino,
          style: _cellStyle,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center),
      // 1 호출명칭
      Text(_zpwina(item),
          style: _cellStyle,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center),
      // 2 본부
      Text(_areaHdofcNm(item),
          style: _cellStyle,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center),
      // 3 통시
      Text(_tongsi(item),
          style: _cellStyle,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center),
      // 4 공대
      Text(_gongdae(item),
          style: _cellStyle,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center),
      // 5 ERP 설치대
      Text(item.erpZpirty3,
          style: _cellStyle,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center),
      // 6 DS 설치대
      Text(item.dsTowerType,
          style: _cellStyle,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center),
      // 7 설치대 비교
      _buildMatchChip(item.towerMatch, item: item),
      // 8 ERP 일련번호
      Tooltip(
          message: item.erpSerial,
          child: Text(item.erpSerial,
              style: _cellStyle,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center)),
      // 9 DS 일련번호
      Tooltip(
          message: item.dsSerial,
          child: Text(item.dsSerial,
              style: _cellStyle,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center)),
      // 10 일련번호 비교
      _buildMatchChip(item.serialMatch),
      // 11 ERP활용구분
      Text(_erpPrac1(item),
          style: _cellStyle,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center),
      // 12 DS활용구분
      Text(item.dsPrac1,
          style: _cellStyle,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center),
      // 13 활용구분비교
      _buildMatchChip(_prac1Match(item)),
    ];

    return Container(
      decoration: BoxDecoration(
        color: isSelected
            ? const Color(0xFF00897B).withValues(alpha: 0.08)
            : (idx.isEven ? Colors.white : const Color(0xFFFAFBFC)),
        border: const Border(bottom: BorderSide(color: Color(0xFFEEF1F5))),
      ),
      child: Row(
        children: [
          if (chkW > 0)
            SizedBox(
              width: chkW,
              height: 48,
              child: Checkbox(
                value: isSelected,
                activeColor: const Color(0xFF00897B),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (_) => setState(() {
                  if (isSelected) {
                    _selectedForPreCheck.remove(item.zpwino);
                  } else {
                    _selectedForPreCheck.add(item.zpwino);
                  }
                }),
              ),
            ),
          ...List.generate(cells.length, (i) {
            final isGroupBoundary = _groupBoundaryRight.contains(i);
            return Container(
              width: widths[i],
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.center,
              decoration: isGroupBoundary
                  ? const BoxDecoration(
                      border: Border(
                        right: BorderSide(color: Color(0xFF9AA3AE), width: 2),
                      ),
                    )
                  : null,
              child: _chipCols.contains(i)
                  ? FittedBox(fit: BoxFit.scaleDown, child: cells[i])
                  : cells[i],
            );
          }),
        ],
      ),
    );
  }

  // ── Helpers ──

  bool _hasAnyMismatch(ErpDsCompareResult r) {
    final s = r.summary;
    return (s['tower_mismatch'] ?? 0) > 0 || (s['serial_mismatch'] ?? 0) > 0 ||
        (s['tower_ds_missing'] ?? 0) > 0 || (s['serial_ds_missing'] ?? 0) > 0;
  }

  // schedMap 오버레이: 일정화면에서 넘어온 값 우선, 없으면 백엔드 값
  String _tongsi(CompareItem item) {
    final v = _schedMap?[item.zpwino]?['통시'] ?? '';
    return v.isNotEmpty ? v : item.tongsi;
  }
  String _gongdae(CompareItem item) {
    final v = _schedMap?[item.zpwino]?['공대'] ?? '';
    return v.isNotEmpty ? v : item.gongdae;
  }
  String _erpPrac1(CompareItem item) {
    final v = _schedMap?[item.zpwino]?['zpprac1'] ?? '';
    return v.isNotEmpty ? v : item.erpPrac1;
  }

  String _prac1Match(CompareItem item) {
    final erp = _erpPrac1(item);
    final ds = item.dsPrac1;
    if (erp.isNotEmpty && ds.isNotEmpty) return erp == ds ? '일치' : '불일치';
    if (erp.isNotEmpty && ds.isEmpty) return 'DS누락';
    if (erp.isEmpty && ds.isNotEmpty) return 'ERP누락';
    return '';
  }
  String _zpwina(CompareItem item) {
    final v = _schedMap?[item.zpwino]?['호출명칭'] ?? '';
    return v.isNotEmpty ? v : item.zpwina;
  }
  String _areaHdofcNm(CompareItem item) {
    final v = _schedMap?[item.zpwino]?['본부'] ?? '';
    return v.isNotEmpty ? v : item.areaHdofcNm;
  }

  List<CompareItem> _getFilteredItems() {
    if (_result == null) return [];
    if (_filter == '전체') return _result!.items;
    return _result!.items.where((it) {
      return it.towerMatch == _filter || it.serialMatch == _filter || _prac1Match(it) == _filter;
    }).toList();
  }

  Widget _buildCard(Widget child) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildStatChip(String label, int value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text('$label $value',
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: color)),
    );
  }

  // 사전점검 회신 카드 (Phase 1)
  Widget _buildPreCheckReplyCard(ErpDsCompareResult r) {
    final s = r.summary;
    final mismatch = (s['tower_mismatch'] ?? 0) + (s['serial_mismatch'] ?? 0);
    final dsMissing = (s['tower_ds_missing'] ?? 0) + (s['serial_ds_missing'] ?? 0);
    final check = (s['tower_check'] ?? 0) + (s['serial_check'] ?? 0);
    final blocked = mismatch > 0 || dsMissing > 0;
    final hasPks = widget.initialSchedulePks?.isNotEmpty ?? false;
    final pkCount = widget.initialSchedulePks?.length ?? 0;

    return _buildCard(
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── 헤더 (일정 연결된 경우만 사전점검 회신 뱃지 표시)
        Row(children: [
          const Icon(Icons.assignment_turned_in_outlined, color: Color(0xFF6B47DC), size: 22),
          const SizedBox(width: 8),
          const Text('사전점검',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87)),
          const SizedBox(width: 8),
          if (hasPks)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF6B47DC).withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('수검 건 $pkCount건',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Color(0xFF6B47DC))),
            ),
        ]),
        const SizedBox(height: 12),

        // ── 불일치 섹션 (schedulePks와 무관하게 표시)
        if (blocked) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _primaryColor.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _primaryColor.withValues(alpha: 0.2)),
            ),
            child: Row(children: [
              Icon(Icons.error_outline, size: 16, color: _primaryColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '불일치 $mismatch건 / DS누락 $dsMissing건이 있습니다.\n'
                  '변경 필요한 항목을 명시하여 변경개설 요청을 작성해주세요.',
                  style: const TextStyle(fontSize: 12, color: _primaryColor),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.edit_note, size: 16),
              label: const Text('변경개설 요청 작성'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE17055),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => _openChangeRequestDialog(r),
            ),
          ]),
          if (hasPks) const SizedBox(height: 12),
        ],

        // ── 사전점검 회신 섹션 (일정 연결된 경우만)
        if (hasPks && !blocked) ...[
          Text(
            check > 0
                ? '확인필요 $check건은 ACTA/시설현황 등 외부 사이트에서 직접 확인 후 회신해주세요.'
                : '모든 항목이 일치합니다. 회신 가능 상태입니다.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          ),
          const SizedBox(height: 12),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            ElevatedButton.icon(
              icon: const Icon(Icons.check_circle_outline, size: 16),
              label: const Text('이상 없음 회신'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6B47DC),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => _submitPreCheckReply(r),
            ),
          ]),
        ] else if (hasPks && blocked) ...[
          // 불일치 있지만 schedulePks 있음 → 점검완료 회신 대신 안내
          Text(
            '불일치 항목 변경개설 신고 후 점검완료 회신이 가능합니다.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ]),
    );
  }

  Future<void> _submitPreCheckReply(ErpDsCompareResult r) async {
    final pks = widget.initialSchedulePks ?? const [];
    if (pks.isEmpty) return;

    final s = r.summary;
    final check = (s['tower_check'] ?? 0) + (s['serial_check'] ?? 0);

    bool acked = false;
    if (check > 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('확인필요 항목 포함 회신', style: TextStyle(fontSize: 16)),
          content: Text(
              '확인필요 $check건이 포함되어 있습니다.\n\n'
              '⚠ ACTA/시설현황 등 외부 사이트에서 외부 확인이 완료된 것으로 간주됩니다. 진행하시겠습니까?',
              style: const TextStyle(fontSize: 13)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6B47DC), foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('회신 진행'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      acked = true;
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Text('이상 없음 회신', style: TextStyle(fontSize: 16)),
          content: Text(
              '${pks.length}건을 점검완료 상태로 회신합니다.\n\n'
              '회신 후 [사전점검중] → [점검완료] 로 상태가 변경됩니다.',
              style: const TextStyle(fontSize: 13)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF6B47DC), foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('회신'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }

    int success = 0;
    final failed = <String>[];
    for (final pk in pks) {
      try {
        await _inspectionService.submitPreCheckResult(
          pk, s, confirmationAcknowledged: acked);
        success++;
      } catch (e) {
        failed.add('$pk: $e');
      }
    }

    if (!mounted) return;
    final msg = failed.isEmpty
        ? '점검완료 회신 성공: $success/${pks.length}건'
        : '회신 결과: $success/${pks.length}건 성공\n실패: ${failed.length}건';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: failed.isEmpty ? const Color(0xFF1A8754) : _primaryColor,
    ));
  }

  // 변경개설 요청 작성 다이얼로그 (Phase 2)
  Future<void> _openChangeRequestDialog(ErpDsCompareResult r) async {
    final pks = widget.initialSchedulePks ?? const [];

    final isAdmin = context.read<AuthService>().isAdmin;
    if (pks.isEmpty && !isAdmin) {
      await ProgressDialog(context).error(message: '수검 건 미연결\n요청 작성 불가');
      return;
    }

    // 불일치/DS누락 행만 추려서 후보 제공
    final candidates = r.items.where((it) =>
      it.towerMatch == '불일치' || it.towerMatch == 'DS누락' ||
      it.serialMatch == '불일치' || it.serialMatch == 'DS누락'
    ).toList();

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ChangeRequestDialog(
        candidates: candidates,
        schedulePks: pks,
        service: _inspectionService,
      ),
    );
  }

  Widget _buildSummaryRow(String label, Map<String, int> summary,
      {String prefix = 'tower'}) {
    final match = (summary['${prefix}_match'] ?? 0) +
        (summary['${prefix}_partial'] ?? 0);
    final mismatch = summary['${prefix}_mismatch'] ?? 0;
    final dsMissing = summary['${prefix}_ds_missing'] ?? 0;
    final check = summary['${prefix}_check'] ?? 0;
    final total = match + mismatch + dsMissing + check;
    final rate = total > 0 ? (match / total * 100).toStringAsFixed(1) : '-';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        SizedBox(
            width: 70,
            child: Text(label,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13))),
        _buildMiniStat('일치', match, _greenColor),
        const SizedBox(width: 10),
        _buildMiniStat('불일치', mismatch, _primaryColor),
        const SizedBox(width: 10),
        _buildMiniStat('DS누락', dsMissing, const Color(0xFFB85B3D)),
        const SizedBox(width: 10),
        _buildMiniStat('확인필요', check, Colors.orange),
        const Spacer(),
        Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: _themeColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text('일치율 $rate%',
              style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                  color: _themeColor)),
        ),
      ]),
    );
  }

  Widget _buildMiniStat(String label, int count, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text('$label $count',
            style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _buildFilterChip(String label, int? count) {
    final selected = _filter == label;
    return ChoiceChip(
      label: Text(
        count != null ? '$label ($count)' : label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: selected ? Colors.white : Colors.grey.shade700,
        ),
      ),
      selected: selected,
      selectedColor: _themeColor,
      backgroundColor: Colors.grey.shade100,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected ? _themeColor : Colors.grey.shade300,
        ),
      ),
      onSelected: (_) => setState(() => _filter = label),
    );
  }

  Widget _buildMatchChip(String status, {CompareItem? item}) {
    Color bg;
    Color fg;
    switch (status) {
      case '일치':
        bg = _greenColor.withValues(alpha: 0.1);
        fg = _greenColor;
        break;
      case '부분일치':
        bg = _blueAccent.withValues(alpha: 0.1);
        fg = _blueAccent;
        break;
      case '불일치':
        bg = _primaryColor.withValues(alpha: 0.1);
        fg = _primaryColor;
        break;
      case 'DS누락':
        bg = const Color(0xFFE17055).withValues(alpha: 0.1);
        fg = const Color(0xFFB85B3D);
        break;
      default:
        bg = Colors.orange.withValues(alpha: 0.1);
        fg = Colors.orange.shade700;
    }

    final chipContent = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: (status == '불일치' || status == '확인필요') && item != null
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              Text(status,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
              const SizedBox(width: 4),
              Icon(Icons.open_in_new, size: 11, color: fg),
            ])
          : Text(status,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
    );

    if ((status == '불일치' || status == '확인필요') && item != null) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _openTowerMismatchModal(item),
          child: chipContent,
        ),
      );
    }
    return chipContent;
  }

  Future<void> _markPreChecked() async {
    final licenseNos = _selectedForPreCheck.toList();
    if (licenseNos.isEmpty) return;
    setState(() => _markingPreCheck = true);
    try {
      final auth = context.read<AuthService>();
      _inspectionService.setAuthToken(auth.authToken);
      final result = await _inspectionService.markPreChecked(licenseNos);
      if (!mounted) return;
      setState(() => _selectedForPreCheck.clear());
      final schedules = result['updated_schedules'] ?? 0;
      final targets = result['updated_targets'] ?? 0;
      final msg = schedules > 0 && targets > 0
          ? '사전점검완료 처리: 일정있음 $schedules건(점검완료↑), 일정없음 $targets건'
          : schedules > 0
              ? '사전점검완료 처리: $schedules건 → 점검완료(PRE_CHECK_DONE) 전환'
              : '사전점검완료 표시: $targets건';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF00897B),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('실패: $e'),
        backgroundColor: Colors.red,
      ));
    } finally {
      if (mounted) setState(() => _markingPreCheck = false);
    }
  }

  void _openTowerMismatchModal(CompareItem item) {
    showDialog(
      context: context,
      builder: (_) => TowerMismatchModal(item: item),
    );
  }

  static const _headerStyle = TextStyle(
    fontWeight: FontWeight.w600,
    fontSize: 13,
    color: Colors.black87,
  );
  static const _cellStyle = TextStyle(fontSize: 13);
}

// ── 설치대 불일치 상세 모달 ──────────────────────────────────────

class TowerMismatchModal extends StatefulWidget {
  final CompareItem item;
  const TowerMismatchModal({super.key, required this.item});

  @override
  State<TowerMismatchModal> createState() => _TowerMismatchModalState();
}

class _TowerMismatchModalState extends State<TowerMismatchModal> {
  static const Color _red = Color(0xFFE53935);
  bool _roadviewLoading = false;

  Future<void> _openRoadview() async {
    final item = widget.item;
    final title = item.zpwina.isNotEmpty ? item.zpwina : item.zpwino;

    // 1순위: 위경도 직접 사용
    if (item.lat != null && item.lng != null) {
      showDialog(
        context: context,
        builder: (_) => RoadviewDialog(lat: item.lat!, lng: item.lng!, title: title),
      );
      return;
    }

    // 2순위: 주소 지오코딩
    final address = item.address;
    if (address.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('위치 정보가 없어 로드뷰를 열 수 없습니다.')),
      );
      return;
    }
    setState(() => _roadviewLoading = true);
    final coords = await KakaoAddressGeocoder.addressToCoords(address);
    if (!mounted) return;
    setState(() => _roadviewLoading = false);
    if (coords == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('위치를 찾을 수 없습니다.')),
      );
      return;
    }
    showDialog(
      context: context,
      builder: (_) => RoadviewDialog(lat: coords.lat, lng: coords.lng, title: title),
    );
  }

  Future<void> _openTowerClassification() async {
    await Navigator.push<TowerClassificationResult>(
      context,
      MaterialPageRoute(
        builder: (_) => TowerClassificationScreen(
          stationName: widget.item.zpwina.isNotEmpty
              ? widget.item.zpwina
              : widget.item.zpwino,
          returnResult: false,
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 90,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 13,
                  color: Colors.black54,
                  fontWeight: FontWeight.w500)),
        ),
        Expanded(
          child: Text(
            value.isNotEmpty ? value : '-',
            style: const TextStyle(fontSize: 13, color: Colors.black87),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 헤더
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.warning_amber_rounded, size: 14, color: _red),
                    const SizedBox(width: 4),
                    Text('설치대 불일치',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: _red)),
                  ]),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ]),
              const SizedBox(height: 16),
              // 무선국 정보
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F6FA),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _infoRow('호출명칭', item.zpwina),
                    _infoRow('허가번호', item.zpwino),
                    if (item.address.isNotEmpty) _infoRow('주소', item.address),
                    const Divider(height: 16),
                    _infoRow('ERP 설치대', item.erpZpirty3),
                    _infoRow('DS 설치대', item.dsTowerType),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // 기능 버튼
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _roadviewLoading ? null : _openRoadview,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1565C0),
                      side: const BorderSide(color: Color(0xFF1565C0)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    icon: _roadviewLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.streetview, size: 18),
                    label: const Text('로드뷰',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _openTowerClassification,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _red,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      elevation: 0,
                    ),
                    icon: const Icon(Icons.camera_alt_outlined, size: 18),
                    label: const Text('철탑형태 분류',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 변경개설 요청 작성 다이얼로그 (Phase 2) ────────────────────────
class _ChangeRequestDialog extends StatefulWidget {
  final List<CompareItem> candidates;
  final List<String> schedulePks;
  final InspectionService service;
  const _ChangeRequestDialog({
    required this.candidates,
    required this.schedulePks,
    required this.service,
  });
  @override
  State<_ChangeRequestDialog> createState() => _ChangeRequestDialogState();
}

// 카드 내 개별 변경 행
class _FieldRow {
  String field;
  String deviceNo;
  String beforeValue;
  String afterValue;
  _FieldRow({this.field = '일련번호', this.deviceNo = '', this.beforeValue = '', this.afterValue = ''});
}

// 허가번호 단위 카드 (여러 행 포함)
class _ChangeRequestEntry {
  String licenseNo;
  String memo;
  List<_FieldRow> rows;
  _ChangeRequestEntry({required this.licenseNo, this.memo = '', List<_FieldRow>? rows})
      : rows = rows ?? [_FieldRow()];
}

class _ChangeRequestDialogState extends State<_ChangeRequestDialog> {
  static const _fields = ['일련번호', '형식검정번호', '설치형태', '설치장소'];
  static const _deviceFields = {'일련번호', '형식검정번호'};
  static const _towerOptions = [
    '철탑(지면)', '철탑(건물)', '강관주', '통신주', '원폴(건물)',
    '모노폴', '프레임', '복합형(원폴,분산프레임 등)',
    '쌍통신주', '한전주(KT통신주)', '기설물',
    '간이폴, 분산폴 및 비기준 설치대', '옥내, 터널, 지하, 차량', '옥내외 혼합형',
  ];
  static const _orange = Color(0xFFE17055);
  static const _orangeDark = Color(0xFFB85B3D);

  final List<_ChangeRequestEntry> _entries = [];
  bool _submitting = false;

  int get _totalRows => _entries.fold(0, (s, e) => s + e.rows.length);

  @override
  void initState() {
    super.initState();
    if (widget.candidates.isNotEmpty) _addEntryFor(widget.candidates.first);
  }

  void _addEntryFor(CompareItem it) {
    String field = '일련번호';
    String before = it.dsSerial;
    if (it.towerMatch == '불일치' || it.towerMatch == 'DS누락') {
      field = '설치형태';
      before = it.dsTowerType;
    }
    setState(() => _entries.add(_ChangeRequestEntry(
      licenseNo: it.zpwino,
      rows: [_FieldRow(field: field, beforeValue: before)],
    )));
  }

  void _removeEntry(int ei) => setState(() => _entries.removeAt(ei));

  String _dsValueFor(CompareItem item, String field) {
    switch (field) {
      case '일련번호': return item.dsSerial;
      case '형식검정번호': return item.dsFormNo;
      case '설치형태': return item.dsTowerType;
      case '설치장소': return item.address;
      default: return '';
    }
  }

  void _addRow(int ei) {
    final licenseNo = _entries[ei].licenseNo;
    final item = widget.candidates.firstWhere(
      (c) => c.zpwino == licenseNo,
      orElse: () => widget.candidates.first,
    );
    setState(() => _entries[ei].rows.add(_FieldRow(beforeValue: _dsValueFor(item, '일련번호'))));
  }

  void _removeRow(int ei, int ri) {
    setState(() {
      if (_entries[ei].rows.length == 1) {
        _entries.removeAt(ei);
      } else {
        _entries[ei].rows.removeAt(ri);
      }
    });
  }

  String _schedulePkFor(String licenseNo) {
    for (final pk in widget.schedulePks) {
      final parts = pk.split('#');
      if (parts.length >= 2 && parts[1] == licenseNo) return pk;
    }
    return '';
  }

  Future<void> _submit() async {
    if (_entries.isEmpty) return;
    for (final e in _entries) {
      for (final r in e.rows) {
        if (r.afterValue.trim().isEmpty) {
          await ProgressDialog(context).error(message: '변경 후 값을\n입력해주세요');
          return;
        }
        if (_deviceFields.contains(r.field) && r.deviceNo.trim().isEmpty) {
          await ProgressDialog(context).error(message: '장치번호를\n입력해주세요');
          return;
        }
      }
    }
    final byPk = <String, List<Map<String, String>>>{};
    final byLicense = <String, List<Map<String, String>>>{};  // pk 없는 경우
    for (final e in _entries) {
      final pk = _schedulePkFor(e.licenseNo);
      final rowData = e.rows.map((r) => {
        'field': r.field, 'before_value': r.beforeValue,
        'after_value': r.afterValue, '장치번호': r.deviceNo, 'memo': e.memo,
      }).toList();
      if (pk.isEmpty) {
        byLicense.putIfAbsent(e.licenseNo, () => []).addAll(rowData);
      } else {
        byPk.putIfAbsent(pk, () => []).addAll(rowData);
      }
    }

    setState(() => _submitting = true);
    int total = 0;
    final failed = <String>[];
    for (final entry in byPk.entries) {
      try {
        final n = await widget.service.createChangeRequest(entry.key, entry.value);
        total += n;
      } catch (e) {
        failed.add('${entry.key}: $e');
      }
    }
    for (final entry in byLicense.entries) {
      try {
        final n = await widget.service.createChangeRequestDirect(entry.key, entry.value);
        total += n;
      } catch (e) {
        failed.add('${entry.key}: $e');
      }
    }
    if (!mounted) return;
    Navigator.pop(context);
    final d = ProgressDialog(context);
    if (failed.isEmpty) {
      await d.complete(message: '요청 등록 완료\n$total건');
    } else {
      await d.error(message: '$total건 등록\n실패 ${failed.length}건');
    }
  }

  Widget _dropdown<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    double? width,
  }) {
    final inner = DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        isExpanded: true, isDense: true, value: value,
        icon: const Icon(Icons.arrow_drop_down, color: _orange, size: 20),
        dropdownColor: Colors.white,
        borderRadius: BorderRadius.circular(12),
        style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
        items: items,
        onChanged: _submitting ? null : onChanged,
      ),
    );
    final box = Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFD1D5DB)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: inner,
    );
    return width != null ? box : Expanded(child: box);
  }

  InputDecoration _inputDeco(String label) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _orange, width: 1.5)),
  );

  @override
  Widget build(BuildContext context) {
    final addedNos = _entries.map((e) => e.licenseNo).toSet();
    final remaining = widget.candidates.where((c) => !addedNos.contains(c.zpwino)).toList();

    return Dialog(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 700),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // ── 헤더
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
            child: Stack(alignment: Alignment.topRight, children: [
              Center(child: Column(children: [
                Container(
                  width: 52, height: 52,
                  decoration: BoxDecoration(
                    color: _orange.withValues(alpha: 0.12), shape: BoxShape.circle),
                  child: const Icon(Icons.edit_note_rounded, color: _orange, size: 26),
                ),
                const SizedBox(height: 10),
                const Text('변경개설 요청 작성',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
              ])),
              GestureDetector(
                onTap: _submitting ? null : () => Navigator.pop(context),
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(6)),
                  child: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: Text(
              '장치 단위(일련번호/형식검정번호)는 장치번호 필수\n국소 단위(설치형태/설치장소)는 장치번호 불필요',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500, height: 1.5),
            ),
          ),
          const Divider(height: 20),
          // ── 카드 목록
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: Column(children: [
                for (int ei = 0; ei < _entries.length; ei++) _buildEntryCard(ei),
                if (remaining.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final c in remaining)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: _orange,
                          backgroundColor: _orange.withValues(alpha: 0.07),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.add, size: 14),
                        label: Text('${c.zpwino} 추가',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        onPressed: _submitting ? null : () => _addEntryFor(c),
                      ),
                  ]),
                ],
                const SizedBox(height: 12),
              ]),
            ),
          ),
          // ── 하단 버튼
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(children: [
              const Divider(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: _submitting
                      ? const SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send_rounded, size: 16),
                  label: Text(
                    _submitting ? '제출 중...' : '$_totalRows건 신고 요청 등록',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _orange, foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _submitting || _entries.isEmpty ? null : _submit,
                ),
              ),
              TextButton(
                onPressed: _submitting ? null : () => Navigator.pop(context),
                child: const Text('취소', style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 13)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _buildEntryCard(int ei) {
    final e = _entries[ei];
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6FA),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 허가번호 헤더 + 카드 삭제
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _orange.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
            child: Text(e.licenseNo,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _orangeDark)),
          ),
          const Spacer(),
          GestureDetector(
            onTap: _submitting ? null : () => _removeEntry(ei),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(6)),
              child: const Icon(Icons.delete_outline, size: 16, color: Color(0xFF9CA3AF)),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        // 변경 행들
        for (int ri = 0; ri < e.rows.length; ri++) ...[
          if (ri > 0) const Divider(height: 16, color: Color(0xFFE5E7EB)),
          _buildFieldRow(ei, ri, e.rows[ri]),
        ],
        const SizedBox(height: 10),
        // + 항목 추가 버튼
        GestureDetector(
          onTap: _submitting ? null : () => _addRow(ei),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: _orange.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _orange.withValues(alpha: 0.2)),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.add, size: 14, color: _orange),
              const SizedBox(width: 4),
              const Text('항목 추가', style: TextStyle(fontSize: 12, color: _orange, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        // 메모 (카드 공통)
        TextFormField(
          initialValue: e.memo,
          decoration: _inputDeco('메모 (선택)'),
          style: const TextStyle(fontSize: 13),
          onChanged: (v) => e.memo = v,
        ),
      ]),
    );
  }

  Widget _buildFieldRow(int ei, int ri, _FieldRow r) {
    final isDevice = _deviceFields.contains(r.field);
    final isTower = r.field == '설치형태';
    return Column(children: [
      Row(children: [
        _dropdown<String>(
          value: r.field,
          items: _fields.map((f) => DropdownMenuItem(value: f,
              child: Text(f, style: const TextStyle(fontSize: 13)))).toList(),
          onChanged: (v) {
            if (v == null) return;
            final licenseNo = _entries[ei].licenseNo;
            final item = widget.candidates.firstWhere(
              (c) => c.zpwino == licenseNo,
              orElse: () => widget.candidates.first,
            );
            setState(() {
              r.field = v;
              r.beforeValue = _dsValueFor(item, v);
              if (!_deviceFields.contains(v)) r.deviceNo = '';
            });
          },
        ),
        if (isDevice) ...[
          const SizedBox(width: 8),
          SizedBox(width: 110, child: TextFormField(
            initialValue: r.deviceNo,
            decoration: _inputDeco('장치번호'),
            style: const TextStyle(fontSize: 13),
            onChanged: (v) => r.deviceNo = v,
          )),
        ],
        const SizedBox(width: 8),
        // 행 삭제
        GestureDetector(
          onTap: _submitting ? null : () => _removeRow(ei, ri),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(6)),
            child: const Icon(Icons.remove, size: 14, color: Color(0xFF9CA3AF)),
          ),
        ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: TextFormField(
          key: ValueKey('before_${ei}_${ri}_${r.beforeValue}'),
          initialValue: r.beforeValue,
          decoration: _inputDeco('DS 현재값'),
          readOnly: true,
          style: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
        )),
        const SizedBox(width: 8),
        if (isTower)
          _dropdown<String>(
            value: _towerOptions.contains(r.afterValue) ? r.afterValue : _towerOptions.first,
            items: _towerOptions.map((t) => DropdownMenuItem(value: t,
                child: Text(t, style: const TextStyle(fontSize: 13)))).toList(),
            onChanged: (v) => setState(() => r.afterValue = v ?? ''),
          )
        else
          Expanded(child: TextFormField(
            initialValue: r.afterValue,
            decoration: _inputDeco('변경 후 값'),
            style: const TextStyle(fontSize: 13),
            onChanged: (v) => r.afterValue = v,
          )),
      ]),
    ]);
  }
}
