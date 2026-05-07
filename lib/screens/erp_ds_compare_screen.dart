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
import '../widgets/progress_dialog.dart';
import '../widgets/user_profile_button.dart';
import 'inspection_result_screen.dart' show RoadviewDialog;
import 'tower_classification_screen.dart';

class ErpDsCompareScreen extends StatefulWidget {
  final List<String>? initialLicenseNos;
  final String? initialAccessDivision;
  final bool initialMultiDivision;
  final void Function(List<String> licenseNos)? onScheduleNavigate;

  const ErpDsCompareScreen({
    super.key,
    this.initialLicenseNos,
    this.initialAccessDivision,
    this.initialMultiDivision = false,
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

  int _step = 0;
  String? _selectedDivisionId;
  List<DsUploadInfo> _dsUploads = [];
  DsUploadInfo? _selectedUpload;
  bool _loadingUploads = false;
  bool _comparing = false;
  String? _error;
  ErpDsCompareResult? _result;
  String _filter = '전체';

  // 결과 테이블: 컬럼 정의 (가용 폭에 비례 분배)
  // 컬럼 순서: 허가번호, 호출명칭, 본부, 통시, 공대,
  //           ERP 설치대, DS 설치대, 설치대 비교,
  //           ERP 기수, DS 기수, 기수 비교,
  //           ERP 일련번호, DS 일련번호, 일련번호 비교
  static const List<String> _colTitles = [
    '허가번호', '호출명칭', '본부', '통시', '공대',
    'ERP 설치대', 'DS 설치대', '설치대 비교',
    'ERP 기수', 'DS 기수', '기수 비교',
    'ERP 일련번호', 'DS 일련번호', '일련번호 비교',
  ];
  // 가중치: 텍스트 분량/중요도에 따라
  static const List<double> _colFlex = [
    13, 16, 8, 9, 9,
    14, 14, 11,
    8, 8, 10,
    16, 16, 11,
  ];

  // 그룹 경계: 이 인덱스 컬럼 오른쪽에 진한 구분선 그림
  // 7 = 설치대 비교 / 10 = 기수 비교 / 13 = 일련번호 비교(끝)
  static const Set<int> _groupBoundaryRight = {7, 10};

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
      backgroundColor: const Color(0xFFFAFAFB),
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
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.black87),
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
              color: Colors.black87,
              fontSize: 18,
              fontWeight: FontWeight.w600,
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
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2)),
              )
            else if (_dsUploads.isEmpty)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey.shade200),
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
              children: r.warnings
                  .map((w) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.warning_amber,
                                size: 16, color: Colors.orange.shade700),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(w,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: Colors.orange.shade800))),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),

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
            _buildSummaryRow('기수', r.summary, prefix: 'antenna'),
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
        'ERP 기수', 'DS 기수', '기수 비교',
        'ERP 일련번호', 'DS 일련번호', '일련번호 비교',
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
          item.zpwino, item.zpwina, item.areaHdofcNm,
          item.tongsi, item.gongdae,
          item.erpZpirty3, item.dsTowerType, item.towerMatch,
          item.erpMaxSeqno, item.dsAntennaKiMax, item.antennaMatch,
          item.erpSerial, item.dsSerial, item.serialMatch,
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

    return SizedBox(
      height: tableHeight,
      child: LayoutBuilder(
        builder: (ctx, cons) {
          final widths = _computeColWidths(cons.maxWidth);
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
                  children: List.generate(_colTitles.length, (i) {
                    return _buildHeaderCell(i, widths[i]);
                  }),
                ),
              ),
              // 바디 (가로 스크롤 없음, 세로만)
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemExtent: 48,
                  itemBuilder: (ctx, idx) {
                    return _buildDataRow(items[idx], r, idx, widths);
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  List<double> _computeColWidths(double maxWidth) {
    final flexSum = _colFlex.fold<double>(0, (a, b) => a + b);
    return _colFlex.map((f) => maxWidth * f / flexSum).toList();
  }

  Widget _buildHeaderCell(int i, double width) {
    final isGroupBoundary = _groupBoundaryRight.contains(i);
    return Container(
      width: width,
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
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
      ),
    );
  }

  Widget _buildDataRow(
      CompareItem item, ErpDsCompareResult r, int idx, List<double> widths) {
    final cells = <Widget>[
      // 0 허가번호
      Text(item.zpwino,
          style: _cellStyle, overflow: TextOverflow.ellipsis),
      // 1 호출명칭
      Text(item.zpwina,
          style: _cellStyle, overflow: TextOverflow.ellipsis),
      // 2 본부
      Text(item.areaHdofcNm,
          style: _cellStyle, overflow: TextOverflow.ellipsis),
      // 3 통시
      Text(item.tongsi,
          style: _cellStyle, overflow: TextOverflow.ellipsis),
      // 4 공대
      Text(item.gongdae,
          style: _cellStyle, overflow: TextOverflow.ellipsis),
      // 5 ERP 설치대
      Text(item.erpZpirty3,
          style: _cellStyle, overflow: TextOverflow.ellipsis),
      // 6 DS 설치대
      Text(item.dsTowerType,
          style: _cellStyle, overflow: TextOverflow.ellipsis),
      // 7 설치대 비교
      _buildMatchChip(item.towerMatch, item: item),
      // 8 ERP 기수
      Text(item.erpMaxSeqno,
          style: _cellStyle, overflow: TextOverflow.ellipsis),
      // 9 DS 기수
      Text(item.dsAntennaKiMax,
          style: _cellStyle, overflow: TextOverflow.ellipsis),
      // 10 기수 비교
      _buildMatchChip(item.antennaMatch),
      // 11 ERP 일련번호
      Tooltip(
          message: item.erpSerial,
          child: Text(item.erpSerial,
              style: _cellStyle, overflow: TextOverflow.ellipsis)),
      // 12 DS 일련번호
      Tooltip(
          message: item.dsSerial,
          child: Text(item.dsSerial,
              style: _cellStyle, overflow: TextOverflow.ellipsis)),
      // 13 일련번호 비교
      _buildMatchChip(item.serialMatch),
    ];

    return Container(
      decoration: BoxDecoration(
        color: idx.isEven ? Colors.white : const Color(0xFFFAFBFC),
        border: const Border(
          bottom: BorderSide(color: Color(0xFFEEF1F5)),
        ),
      ),
      child: Row(
        children: List.generate(cells.length, (i) {
          final isGroupBoundary = _groupBoundaryRight.contains(i);
          return Container(
            width: widths[i],
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            decoration: isGroupBoundary
                ? const BoxDecoration(
                    border: Border(
                      right: BorderSide(color: Color(0xFF9AA3AE), width: 2),
                    ),
                  )
                : null,
            child: cells[i],
          );
        }),
      ),
    );
  }

  // ── Helpers ──

  List<CompareItem> _getFilteredItems() {
    if (_result == null) return [];
    if (_filter == '전체') return _result!.items;
    return _result!.items.where((it) {
      return it.towerMatch == _filter || it.serialMatch == _filter || it.antennaMatch == _filter;
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

  Widget _buildSummaryRow(String label, Map<String, int> summary,
      {String prefix = 'tower'}) {
    final match = (summary['${prefix}_match'] ?? 0) +
        (summary['${prefix}_partial'] ?? 0);
    final mismatch = summary['${prefix}_mismatch'] ?? 0;
    final check = summary['${prefix}_check'] ?? 0;
    final total = match + mismatch + check;
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
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey.shade200),
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
