import 'dart:convert';
import 'dart:html' as html;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../widgets/progress_dialog.dart';
import '../widgets/app_loader.dart';

class ChangeNotificationScreen extends StatefulWidget {
  const ChangeNotificationScreen({super.key});

  @override
  State<ChangeNotificationScreen> createState() =>
      _ChangeNotificationScreenState();
}

class _ChangeNotificationScreenState extends State<ChangeNotificationScreen> {
  static const _primary = Color(0xFFE53935);
  static const _blue = Color(0xFF3B82F6);
  static const _border = Color(0xFFE5E7EB);
  static const _surface = Colors.white;
  static const _bg = Color(0xFFF5F6FA);
  static const _textPrimary = Color(0xFF111827);
  static const _textSecondary = Color(0xFF6B7280);

  bool _processing = false;
  bool _applying = false;
  bool _downloadingTemplate = false;
  bool _uploadingTemplate = false;
  String? _result;
  String? _error;
  List<PlatformFile> _selectedFiles = [];

  // diff 상태
  List<Map<String, dynamic>> _diff = [];
  Set<String> _selectedStations = {};

  // Phase 2: 탭 모드 ('legacy' = 기존 A+B 업로드, 'requests' = 변경 요청 목록)
  String _mode = 'legacy';
  final InspectionService _inspectionSvc = InspectionService();
  List<Map<String, dynamic>> _changeRequests = [];
  // schedule_pk → schedule 메타 (품질개선팀/주차/조/access담당/year)
  Map<String, Map<String, dynamic>> _scheduleMetaMap = {};
  bool _loadingRequests = false;

  // 혁신팀 탭 드릴다운 필터 — 요청이 실존하는 본부→팀→주차만 옵션으로 노출.
  // 주차는 범위(시작~끝) 선택 (몇 주치를 몰아서 받는 경우 대응).
  String _fltHdqt = '';
  String _fltTeam = '';
  String _fltWeekFrom = '';
  String _fltWeekTo = '';
  bool _downloadingMerged = false;

  static const _apiBase = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  Future<void> _downloadSample() async {
    setState(() => _downloadingTemplate = true);
    try {
      final token = context.read<AuthService>().authToken;
      final resp = await http.get(
        Uri.parse('$_apiBase/document/change-notification-sample'),
        headers: {'Authorization': 'Bearer ${token ?? ''}'},
      ).timeout(const Duration(seconds: 30));
      if (!mounted) return;
      if (resp.statusCode == 200) {
        final url = (json.decode(resp.body) as Map<String, dynamic>)['url'] as String? ?? '';
        if (url.isNotEmpty) {
          html.AnchorElement(href: url).click();
        }
      } else if (resp.statusCode == 404) {
        _showAlert('샘플 없음', '샘플 양식 파일이 없습니다. 관리자에게 문의하세요.');
      } else {
        _showAlert('오류', '다운로드 실패: ${resp.body}');
      }
    } catch (e) {
      if (mounted) _showAlert('오류', '다운로드 중 오류: $e');
    } finally {
      if (mounted) setState(() => _downloadingTemplate = false);
    }
  }

  Future<void> _uploadSample() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xls', 'xlsx', 'zip'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    setState(() => _uploadingTemplate = true);
    try {
      final token = context.read<AuthService>().authToken;
      final uri = Uri.parse('$_apiBase/document/change-notification-sample');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer ${token ?? ''}'
        ..files.add(http.MultipartFile.fromBytes('file', file.bytes!, filename: file.name));
      final streamed = await request.send().timeout(const Duration(minutes: 2));
      if (!mounted) return;
      if (streamed.statusCode == 200) {
        _showAlert('업로드 완료', '샘플 양식이 업로드되었습니다.');
      } else {
        final body = await streamed.stream.bytesToString();
        if (!mounted) return;
        _showAlert('업로드 실패', body);
      }
    } catch (e) {
      if (mounted) _showAlert('오류', '업로드 중 오류: $e');
    } finally {
      if (mounted) setState(() => _uploadingTemplate = false);
    }
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xls', 'xlsx'],
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    if (result.files.length != 2) {
      _showAlert('파일 2개를 선택해주세요', '변경개설신고 파일과 DS 파일을 함께 선택해주세요.');
      return;
    }
    setState(() {
      _selectedFiles = result.files;
      _result = null;
      _error = null;
      _diff = [];
      _selectedStations = {};
    });
  }

  Future<void> _process() async {
    if (_selectedFiles.length != 2) {
      _showAlert('파일 미선택', '파일 2개를 먼저 선택해주세요.');
      return;
    }
    final dialog = ProgressDialog(context);
    dialog.show(message: '변경 적용 중...');
    try {
      final token = context.read<AuthService>().authToken;
      final uri = Uri.parse('$_apiBase/document/change-notification');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer ${token ?? ''}'
        ..files.add(http.MultipartFile.fromBytes(
          'file1', _selectedFiles[0].bytes!, filename: _selectedFiles[0].name))
        ..files.add(http.MultipartFile.fromBytes(
          'file2', _selectedFiles[1].bytes!, filename: _selectedFiles[1].name));

      final streamed = await request.send().timeout(const Duration(minutes: 5));
      if (!mounted) return;

      if (streamed.statusCode == 200) {
        final bodyBytes = await streamed.stream.toBytes();
        final bodyJson = json.decode(utf8.decode(bodyBytes)) as Map<String, dynamic>;

        final xlsB64 = bodyJson['xls_base64'] as String? ?? '';
        final filename = bodyJson['filename'] as String? ?? '변경적용_DS파일.xls';
        final changeCount = bodyJson['change_count'] as int? ?? 0;
        final targetCount = bodyJson['target_count'] as int? ?? 0;
        final diffRaw = (bodyJson['diff'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>();

        // xls 자동 다운로드
        if (xlsB64.isNotEmpty) {
          final bytes = base64Decode(xlsB64);
          final blob = html.Blob([bytes], 'application/vnd.ms-excel');
          final url = html.Url.createObjectUrlFromBlob(blob);
          html.AnchorElement(href: url)
            ..setAttribute('download', filename)
            ..click();
          html.Url.revokeObjectUrl(url);
        }

        await dialog.complete(message: '변경 완료\n대상 $targetCount건, 적용 $changeCount건');
        setState(() {
          _result = '변경 대상: $targetCount건, 변경 적용: $changeCount건\n$filename 다운로드 완료';
          _diff = diffRaw;
          _selectedStations = diffRaw.map((d) => d['허가번호'] as String).toSet();
        });
      } else {
        final body = await streamed.stream.bytesToString();
        await dialog.error(message: '처리 실패');
        setState(() => _error = '처리 실패: $body');
      }
    } catch (e) {
      if (mounted) await dialog.error(message: '오류 발생');
      setState(() => _error = '오류: $e');
    }
  }

  Future<void> _applyChanges() async {
    if (_selectedStations.isEmpty) return;
    setState(() => _applying = true);
    try {
      final token = context.read<AuthService>().authToken;
      final now = DateTime.now();
      final dateStr =
          '${now.year.toString().substring(2)}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      final uri = Uri.parse('$_apiBase/document/apply-change-notification');
      final resp = await http
          .post(
            uri,
            headers: {
              'Authorization': 'Bearer ${token ?? ''}',
              'Content-Type': 'application/json',
            },
            body: json.encode({
              'selected': _selectedStations.toList(),
              'diff': _diff,
              'applied_date': dateStr,
            }),
          )
          .timeout(const Duration(minutes: 2));

      if (!mounted) return;
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final notFound = (data['not_found'] as List<dynamic>? ?? []).cast<String>();
        setState(() {
          _applying = false;
          _diff.removeWhere((d) => _selectedStations.contains(d['허가번호']));
          _selectedStations.clear();
        });
        if (notFound.isNotEmpty) {
          _showAlert(
            '반영 완료 (일부 경고)',
            '${data['applied']}건 반영 완료.\n\n'
            '아래 국소는 수검 대상 또는 DS 데이터에 없어 반영되지 않았습니다:\n'
            '${notFound.join('\n')}',
          );
        } else {
          _showAlert('반영 완료',
              '${data['applied']}건 변경이 수검결과 화면에 반영되었습니다.\n변경된 필드 옆에 ($dateStr 변경) 배지가 표시됩니다.');
        }
      } else {
        setState(() => _applying = false);
        _showAlert('반영 실패', '서버 오류: ${resp.body}');
      }
    } catch (e) {
      if (mounted) setState(() => _applying = false);
      _showAlert('오류', '반영 중 오류: $e');
    }
  }

  void _showAlert(String title, String message) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: Text(message, style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('확인')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 변경개설신고는 admin/manager만 접근 가능 (member 차단)
    final isAdmin = context.watch<AuthService>().isAdmin;
    if (!isAdmin) {
      return Scaffold(
        backgroundColor: _bg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: const BoxDecoration(
                  color: Color(0xFFFEF2F2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.lock_outline_rounded,
                    color: Color(0xFFEF4444), size: 28),
              ),
              const SizedBox(height: 12),
              const Text('접근 권한이 없습니다',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: _textPrimary)),
              const SizedBox(height: 4),
              const Text('변경개설신고는 관리자/매니저만 이용할 수 있습니다.',
                  style: TextStyle(fontSize: 13, color: _textSecondary)),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: _bg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('변경개설신고 관리',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        color: _textPrimary)),
                const SizedBox(height: 12),
                _buildModeSwitcher(),
                const SizedBox(height: 16),
                if (_mode == 'requests') _buildRequestsView()
                else ..._buildLegacyView(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeSwitcher() {
    Widget pill(String value, IconData icon, String label) {
      final selected = _mode == value;
      return InkWell(
        onTap: () {
          setState(() => _mode = value);
          if (value == 'requests') _loadRequests();
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFE17055) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: selected ? Colors.white : _textSecondary),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : _textSecondary,
                )),
          ]),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        pill('requests', Icons.fact_check_outlined, '변경 요청 목록 (혁신팀)'),
        pill('legacy', Icons.upload_file_outlined, 'A+B 업로드 / 신고서 생성'),
      ]),
    );
  }

  List<Widget> _buildLegacyView() {
    return [
      Text(
        '무선국 변경개설신고 파일(A)과 DS 파일(B) 2개를 업로드하면,\n'
        '변경 대상을 자동으로 비교하여 DS 파일에 반영된 결과를 다운로드합니다.\n'
        '※ DS DB 패치는 [DS 데이터 → 데이터 변경요청] 메뉴에서만 수행됩니다.',
        style: TextStyle(fontSize: 13, color: _textSecondary, height: 1.6),
      ),
      const SizedBox(height: 16),
      _buildSampleRow(),
      const SizedBox(height: 24),
      _buildUploadCard(),
      const SizedBox(height: 16),
      if (_result != null) _buildResultBanner(),
      if (_error != null) _buildErrorBanner(),
      if (_diff.isNotEmpty) ...[
        const SizedBox(height: 8),
        _buildDiffSection(),
      ],
    ];
  }

  Future<void> _loadRequests() async {
    setState(() { _loadingRequests = true; });
    try {
      final auth = context.read<AuthService>();
      _inspectionSvc.setAuthToken(auth.authToken);
      // 본부별 격리:
      // - superadmin: 전체
      // - 그 외: 본인 본부만
      String accessTeam = '';
      if (!auth.isSuperAdmin) {
        final dept = (auth.userDepartment ?? '').replaceAll('Access담당', '').trim();
        accessTeam = dept;
      }
      // change_request 와 schedule 메타 동시 조회
      final futures = await Future.wait([
        _inspectionSvc.listChangeRequests(accessTeam: accessTeam),
        _inspectionSvc.getSchedules(DateTime.now().year, accessTeam: accessTeam),
      ]);
      final reqs = futures[0] as List<Map<String, dynamic>>;
      final scheds = futures[1] as List<Map<String, dynamic>>;
      final metaMap = <String, Map<String, dynamic>>{};
      for (final s in scheds) {
        final pk = (s['pk'] ?? '').toString();
        if (pk.isNotEmpty) metaMap[pk] = s;
      }
      if (!mounted) return;
      setState(() {
        _changeRequests = reqs;
        _scheduleMetaMap = metaMap;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '목록 조회 실패: $e');
    } finally {
      if (mounted) setState(() => _loadingRequests = false);
    }
  }

  /// 묶음 키 생성: 품질개선팀_주차_N조
  String _bundleKey(Map<String, dynamic> sched) {
    final qt = (sched['품질개선팀'] ?? '').toString().trim();
    final wk = (sched['수검예정주차'] ?? '').toString().trim();
    final tmRaw = (sched['조'] ?? '').toString().trim();
    final tm = tmRaw.isEmpty ? '' : (tmRaw.endsWith('조') ? tmRaw : '$tmRaw조');
    return [qt, wk, tm].where((s) => s.isNotEmpty).join('_');
  }

  /// 주차 문자열('9월 1주차') → 정렬/범위 비교용 키 (월*10+주). 못 읽으면 -1.
  int _weekKey(String w) {
    final m = RegExp(r'(\d{1,2})\s*월\s*(\d{1,2})\s*주').firstMatch(w);
    if (m == null) return -1;
    return int.parse(m.group(1)!) * 10 + int.parse(m.group(2)!);
  }

  String _hdqtOf(Map<String, dynamic> sched) =>
      (sched['access담당'] ?? '').toString().replaceAll('Access담당', '').trim();

  /// 드릴다운 필터 적용된 요청 목록
  List<Map<String, dynamic>> get _filteredRequests {
    final fromK = _fltWeekFrom.isEmpty ? -1 : _weekKey(_fltWeekFrom);
    final toK = _fltWeekTo.isEmpty ? 999 : _weekKey(_fltWeekTo);
    return _changeRequests.where((r) {
      final sched = _scheduleMetaMap[(r['schedule_pk'] ?? '').toString()] ?? {};
      if (_fltHdqt.isNotEmpty && _hdqtOf(sched) != _fltHdqt) return false;
      if (_fltTeam.isNotEmpty &&
          (sched['품질개선팀'] ?? '').toString().trim() != _fltTeam) return false;
      if (_fltWeekFrom.isNotEmpty || _fltWeekTo.isNotEmpty) {
        final wk = _weekKey((sched['수검예정주차'] ?? '').toString());
        if (wk < 0 || wk < fromK || wk > toK) return false;
      }
      return true;
    }).toList();
  }

  Widget _buildRequestsView() {
    if (_loadingRequests) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: AppLoader.centered(),
      );
    }
    if (_changeRequests.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: _surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _border),
        ),
        child: Column(children: [
          Icon(Icons.inbox_outlined, size: 40, color: Colors.grey.shade400),
          const SizedBox(height: 8),
          Text('처리 대기 중인 변경 요청이 없습니다.',
              style: TextStyle(fontSize: 13, color: _textSecondary)),
        ]),
      );
    }

    final filtered = _filteredRequests;

    // 묶음(품질개선팀_주차_조) 단위로 그룹핑.
    // 각 change_request는 schedule_pk를 가지며, schedule 메타는 _scheduleMetaMap에서 가져옴.
    final bundles = <String, List<Map<String, dynamic>>>{};
    final bundleMeta = <String, Map<String, dynamic>>{};
    for (final r in filtered) {
      final spk = (r['schedule_pk'] ?? '').toString();
      final sched = _scheduleMetaMap[spk] ?? {};
      final key = _bundleKey(sched);
      bundles.putIfAbsent(key, () => []).add(r);
      bundleMeta.putIfAbsent(key, () => sched);
    }

    final keys = bundles.keys.toList()..sort();
    return Column(
      children: [
        _buildRequestFilterBar(filtered),
        const SizedBox(height: 10),
        Row(children: [
          Text('묶음 ${bundles.length}개 / 수검 건 ${filtered.map((r) => r['schedule_pk']).toSet().length}건 / 항목 ${filtered.length}개'
              '${filtered.length != _changeRequests.length ? ' (전체 ${_changeRequests.length}개 중 필터됨)' : ''}',
              style: TextStyle(fontSize: 13, color: _textSecondary)),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: '새로고침',
            onPressed: _loadRequests,
          ),
        ]),
        const SizedBox(height: 8),
        if (filtered.isEmpty)
          Container(
            padding: const EdgeInsets.all(30),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
            ),
            child: Text('필터 조건에 해당하는 변경 요청이 없습니다.',
                style: TextStyle(fontSize: 13, color: _textSecondary)),
          )
        else
          ...keys.map((k) => _buildBundleCard(k, bundles[k]!, bundleMeta[k]!)),
      ],
    );
  }

  /// 드릴다운 필터 바 — 본부 → 팀 → 주차(시작~끝). 각 단계 옵션은 상위 선택
  /// 범위에 요청이 실존하는 값만 노출한다.
  Widget _buildRequestFilterBar(List<Map<String, dynamic>> filtered) {
    // 옵션 소스: 요청이 있는 일정 메타들
    final schedsAll = _changeRequests
        .map((r) => _scheduleMetaMap[(r['schedule_pk'] ?? '').toString()] ?? {})
        .where((s) => s.isNotEmpty)
        .toList();

    final hdqts = schedsAll.map(_hdqtOf).where((h) => h.isNotEmpty).toSet().toList()
      ..sort();

    final teamScope = _fltHdqt.isEmpty
        ? schedsAll
        : schedsAll.where((s) => _hdqtOf(s) == _fltHdqt).toList();
    final teams = teamScope
        .map((s) => (s['품질개선팀'] ?? '').toString().trim())
        .where((t) => t.isNotEmpty)
        .toSet()
        .toList()
      ..sort();

    final weekScope = _fltTeam.isEmpty
        ? teamScope
        : teamScope
            .where((s) => (s['품질개선팀'] ?? '').toString().trim() == _fltTeam)
            .toList();
    final weeks = weekScope
        .map((s) => (s['수검예정주차'] ?? '').toString().trim())
        .where((w) => w.isNotEmpty && _weekKey(w) >= 0)
        .toSet()
        .toList()
      ..sort((a, b) => _weekKey(a).compareTo(_weekKey(b)));

    // 부적합 관리 화면의 _buildModernDropdown 과 동일한 룩 (40px, F9FAFB, radius 8)
    Widget dd(String label, String value, List<String> options,
        ValueChanged<String> onChanged,
        {double width = 130, bool enabled = true}) {
      final items = ['', ...options];
      final safe = items.contains(value) ? value : '';
      return SizedBox(
        width: width,
        height: 40,
        child: Opacity(
          opacity: enabled ? 1.0 : 0.5,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFF9FAFB),
              border: Border.all(color: const Color(0xFFE5E7EB)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                isExpanded: true,
                icon: const Icon(Icons.unfold_more,
                    color: Color(0xFF9CA3AF), size: 16),
                dropdownColor: Colors.white,
                style: const TextStyle(color: Color(0xFF111827),
                    fontSize: 13, fontWeight: FontWeight.w500),
                value: safe,
                borderRadius: BorderRadius.circular(10),
                items: items
                    .map((v) => DropdownMenuItem(
                        value: v, child: Text(v.isEmpty ? label : v)))
                    .toList(),
                onChanged: enabled ? (v) => onChanged(v ?? '') : null,
              ),
            ),
          ),
        ),
      );
    }

    final hasFilter = _fltHdqt.isNotEmpty || _fltTeam.isNotEmpty ||
        _fltWeekFrom.isNotEmpty || _fltWeekTo.isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Icon(Icons.filter_list, size: 18, color: Color(0xFF6B7280)),
          dd('본부', _fltHdqt, hdqts, (v) => setState(() {
                _fltHdqt = v;
                _fltTeam = '';
                _fltWeekFrom = '';
                _fltWeekTo = '';
              }), width: 120),
          dd('팀', _fltTeam, teams, (v) => setState(() {
                _fltTeam = v;
                _fltWeekFrom = '';
                _fltWeekTo = '';
              }), width: 150, enabled: _fltHdqt.isNotEmpty),
          dd('주차 시작', _fltWeekFrom, weeks, (v) => setState(() {
                _fltWeekFrom = v;
                // 시작이 끝보다 뒤면 끝을 함께 이동
                if (_fltWeekTo.isNotEmpty && v.isNotEmpty &&
                    _weekKey(v) > _weekKey(_fltWeekTo)) {
                  _fltWeekTo = v;
                }
              })),
          const Text('~', style: TextStyle(fontSize: 13)),
          dd('주차 끝', _fltWeekTo, weeks, (v) => setState(() {
                _fltWeekTo = v;
                if (_fltWeekFrom.isNotEmpty && v.isNotEmpty &&
                    _weekKey(v) < _weekKey(_fltWeekFrom)) {
                  _fltWeekFrom = v;
                }
              })),
          if (hasFilter)
            TextButton.icon(
              onPressed: () => setState(() {
                _fltHdqt = '';
                _fltTeam = '';
                _fltWeekFrom = '';
                _fltWeekTo = '';
              }),
              icon: const Icon(Icons.filter_alt_off_outlined, size: 15),
              label: const Text('초기화', style: TextStyle(fontSize: 12.5)),
            ),
          ElevatedButton.icon(
            onPressed: (filtered.isEmpty || _downloadingMerged)
                ? null
                : () => _downloadMergedForm(filtered),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A8754),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: _downloadingMerged
                ? const SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.file_download_outlined, size: 16),
            label: Text(
              '필터 결과 통합 신고서 (${filtered.map((r) => r['schedule_pk']).toSet().length}국소)',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  /// 필터된 요청 전체를 하나의 xls 신고서로 다운로드 (팀별 개별 다운로드 → 병합 불편 해소)
  Future<void> _downloadMergedForm(List<Map<String, dynamic>> filtered) async {
    final pks = filtered
        .map((r) => (r['schedule_pk'] ?? '').toString())
        .where((p) => p.isNotEmpty)
        .toSet()
        .toList();
    if (pks.isEmpty) return;
    setState(() => _downloadingMerged = true);
    try {
      _inspectionSvc.setAuthToken(context.read<AuthService>().authToken);
      final parts = <String>[
        if (_fltHdqt.isNotEmpty) _fltHdqt,
        if (_fltTeam.isNotEmpty) _fltTeam,
        if (_fltWeekFrom.isNotEmpty || _fltWeekTo.isNotEmpty)
          '${_fltWeekFrom.isEmpty ? weeksFirstLabel() : _fltWeekFrom}~${_fltWeekTo.isEmpty ? weeksLastLabel() : _fltWeekTo}',
      ];
      final label = parts.isEmpty ? '변경개설신고_전체' : parts.join('_');
      final bytes = await _inspectionSvc.generateChangeFormByPks(pks, label);
      final blob = html.Blob([bytes], 'application/vnd.ms-excel');
      final url = html.Url.createObjectUrlFromBlob(blob);
      html.AnchorElement(href: url)
        ..download = '$label.xls'
        ..click();
      html.Url.revokeObjectUrl(url);
    } catch (e) {
      if (mounted) await ProgressDialog(context).error(message: '통합 신고서 생성 실패: $e');
    } finally {
      if (mounted) setState(() => _downloadingMerged = false);
    }
  }

  // 라벨용 — 필터 범위 한쪽만 지정된 경우 실존 주차의 처음/끝을 표기
  String weeksFirstLabel() {
    final ws = _filteredRequests
        .map((r) => (_scheduleMetaMap[(r['schedule_pk'] ?? '').toString()]
                ?['수검예정주차'] ?? '').toString())
        .where((w) => _weekKey(w) >= 0)
        .toList()
      ..sort((a, b) => _weekKey(a).compareTo(_weekKey(b)));
    return ws.isEmpty ? '' : ws.first;
  }

  String weeksLastLabel() {
    final ws = _filteredRequests
        .map((r) => (_scheduleMetaMap[(r['schedule_pk'] ?? '').toString()]
                ?['수검예정주차'] ?? '').toString())
        .where((w) => _weekKey(w) >= 0)
        .toList()
      ..sort((a, b) => _weekKey(a).compareTo(_weekKey(b)));
    return ws.isEmpty ? '' : ws.last;
  }

  Widget _buildBundleCard(String bundleKey, List<Map<String, dynamic>> items, Map<String, dynamic> meta) {
    // 묶음 내 schedule_pk → 항목들
    final byPk = <String, List<Map<String, dynamic>>>{};
    for (final it in items) {
      byPk.putIfAbsent('${it['schedule_pk']}', () => []).add(it);
    }
    final qt = (meta['품질개선팀'] ?? '').toString();
    final wk = (meta['수검예정주차'] ?? '').toString();
    final tmRaw = (meta['조'] ?? '').toString().trim();
    final tm = tmRaw.isEmpty ? '' : (tmRaw.endsWith('조') ? tmRaw : '$tmRaw조');
    final access = (meta['access담당'] ?? '').toString();

    final allRequested = items.every((it) => it['status'] == 'REQUESTED');
    final anyRequested = items.any((it) => it['status'] == 'REQUESTED');
    final allFiledOrLater = items.every((it) =>
      it['status'] == 'FILED' || it['status'] == 'APPLIED' || it['status'] == 'VERIFIED');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: _border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // 묶음 헤더: 팀 + 주차 + 조
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            const Icon(Icons.layers, size: 18, color: Color(0xFFE17055)),
            const SizedBox(width: 6),
            Expanded(child: Wrap(spacing: 8, runSpacing: 4, children: [
              if (access.isNotEmpty) _bundlePill(access, const Color(0xFF6B47DC)),
              if (qt.isNotEmpty) _bundlePill(qt, const Color(0xFFE17055)),
              if (wk.isNotEmpty) _bundlePill(wk, const Color(0xFF0984E3)),
              if (tm.isNotEmpty) _bundlePill(tm, const Color(0xFF1A8754)),
            ])),
            Text('${byPk.length}국소 · ${items.length}항목',
                style: TextStyle(fontSize: 11, color: _textSecondary)),
          ]),
          const SizedBox(height: 12),
          // 국소별 항목 리스트
          ...byPk.entries.map((e) => _buildScheduleSection(e.key, e.value)),
          const SizedBox(height: 12),
          Row(children: [
            // 묶음 내 REQUESTED 1건 이상이면 묶음 전체 취소 가능 (위험 액션은 좌측)
            if (anyRequested)
              OutlinedButton.icon(
                icon: const Icon(Icons.delete_sweep_outlined, size: 14, color: Color(0xFFB85B3D)),
                label: Text('묶음 전체 취소 (${items.where((it) => (it['status'] ?? '') == 'REQUESTED').length})',
                    style: const TextStyle(color: Color(0xFFB85B3D))),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFB85B3D)),
                ),
                onPressed: () => _cancelBundle(byPk.keys.toList(), bundleKey,
                    items.where((it) => (it['status'] ?? '') == 'REQUESTED').length),
              ),
            const Spacer(),
            OutlinedButton.icon(
              icon: const Icon(Icons.download, size: 14),
              label: const Text('묶음 A파일 다운로드'),
              onPressed: () => _downloadBundleForm(meta, bundleKey),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.task_alt, size: 14),
              label: Text(allRequested ? '묶음 신고 완료' : (anyRequested ? '미신고만 처리' : '처리 완료')),
              style: ElevatedButton.styleFrom(
                backgroundColor: anyRequested ? const Color(0xFF1A8754) : Colors.grey,
                foregroundColor: Colors.white,
              ),
              onPressed: !anyRequested ? null
                  : () => _markBundleFiled(byPk.keys.toList(), bundleKey),
            ),
          ]),
          if (allFiledOrLater)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '※ 신고 완료된 묶음입니다. 부분 DS 회신 받으면 [DS 데이터 → 데이터 변경요청]에서 적용해주세요.',
                style: TextStyle(fontSize: 11, color: _textSecondary),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _bundlePill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }

  Widget _buildScheduleSection(String schedulePk, List<Map<String, dynamic>> items) {
    final license = items.first['허가번호'] ?? '';
    // 카드 단위 메모: 같은 카드의 항목들은 모두 동일한 memo를 갖고 INSERT됨 (erp_ds_compare_screen 참조)
    final cardMemo = (items.first['memo'] ?? '').toString().trim();
    // REQUESTED 상태 항목이 2건 이상이면 "전체 취소" 버튼 노출
    final requestedCount = items.where((it) => (it['status'] ?? '') == 'REQUESTED').length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('$license',
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFB85B3D)))),
            if (requestedCount >= 2)
              InkWell(
                onTap: () => _cancelChangeRequestBulk(schedulePk, '$license', requestedCount),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.delete_sweep_outlined,
                        size: 13, color: Colors.grey.shade600),
                    const SizedBox(width: 3),
                    Text('전체 취소 ($requestedCount)',
                        style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.w500)),
                  ]),
                ),
              ),
          ]),
          const SizedBox(height: 4),
          ...items.map((it) => _buildRequestItemRow(it)),
          if (cardMemo.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('📝 $cardMemo',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                      fontStyle: FontStyle.italic)),
            ),
        ]),
      ),
    );
  }

  Future<void> _cancelBundle(
      List<String> schedulePks, String bundleKey, int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFEF2F2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.delete_sweep_rounded,
                      color: Color(0xFFB85B3D), size: 24),
                ),
                const SizedBox(height: 16),
                const Text(
                  '묶음 전체 취소',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '"$bundleKey" 묶음 ${schedulePks.length}국소의\n변경 요청 $count건을 모두 취소합니다.\n각 일정은 [사전점검중] 상태로 원복됩니다.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: Color(0xFF6B7280),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFB85B3D),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text('$count건 모두 취소',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('닫기',
                        style: TextStyle(
                            color: Color(0xFF9CA3AF), fontSize: 13)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    _inspectionSvc.setAuthToken(context.read<AuthService>().authToken);
    final progress = ProgressDialog(context);
    progress.show(message: '취소 중...');
    try {
      final res = await _inspectionSvc.cancelChangeRequestBulk(
          schedulePks: schedulePks);
      if (!mounted) return;
      final cancelled = (res['cancelled'] as num?)?.toInt() ?? 0;
      final reverted = (res['reverted_pks'] as List?)?.length ?? 0;
      await progress.complete(
        message: reverted > 0
            ? '$cancelled건 취소 완료\n$reverted개 국소 사전점검중으로 원복됨'
            : '$cancelled건 취소 완료',
      );
      if (!mounted) return;
      await _loadRequests();
    } catch (e) {
      if (!mounted) return;
      await progress.error(message: '묶음 취소 실패: $e');
    }
  }

  Future<void> _cancelChangeRequestBulk(
      String schedulePk, String license, int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFEF2F2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.delete_sweep_rounded,
                      color: Color(0xFFB85B3D), size: 24),
                ),
                const SizedBox(height: 16),
                const Text(
                  '카드 전체 취소',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$license 의 변경 요청 $count건을 모두 취소합니다.\n[사전점검중] 상태로 원복됩니다.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: Color(0xFF6B7280),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFB85B3D),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text('$count건 모두 취소',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('닫기',
                        style: TextStyle(
                            color: Color(0xFF9CA3AF), fontSize: 13)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    _inspectionSvc.setAuthToken(context.read<AuthService>().authToken);
    final progress = ProgressDialog(context);
    progress.show(message: '취소 중...');
    try {
      final res = await _inspectionSvc.cancelChangeRequestBulk(
          schedulePks: [schedulePk]);
      if (!mounted) return;
      final cancelled = (res['cancelled'] as num?)?.toInt() ?? 0;
      final reverted = (res['reverted_pks'] as List?)?.isNotEmpty ?? false;
      await progress.complete(
        message: reverted
            ? '$cancelled건 취소 완료\n사전점검중으로 원복됨'
            : '$cancelled건 취소 완료',
      );
      if (!mounted) return;
      await _loadRequests();
    } catch (e) {
      if (!mounted) return;
      await progress.error(message: '일괄 취소 실패: $e');
    }
  }

  Widget _buildRequestItemRow(Map<String, dynamic> item) {
    final field = item['field'] ?? '';
    final dev = (item['장치번호'] ?? '').toString();
    final before = item['before_value'] ?? '';
    final after = item['after_value'] ?? '';
    final status = (item['status'] ?? '').toString();
    final crId = (item['id'] as num?)?.toInt() ?? 0;
    // memo는 카드 단위라 _buildScheduleSection에서 한 번만 표시 (여기 중복 표시 X)
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 92, child: Text(field,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
        if (dev.isNotEmpty)
          SizedBox(width: 70, child: Text('장치 $dev',
              style: const TextStyle(fontSize: 12, color: Colors.grey)))
        else
          const SizedBox(width: 70),
        Expanded(child: Text('$before  →  $after',
            style: const TextStyle(fontSize: 12))),
        const SizedBox(width: 8),
        _buildStatusPill(status, small: true),
        // REQUESTED 상태만 취소 가능
        if (status == 'REQUESTED' && crId > 0) ...[
          const SizedBox(width: 6),
          InkWell(
            onTap: () => _cancelChangeRequest(crId, '$field ${dev.isNotEmpty ? "(장치$dev)" : ""}'),
            borderRadius: BorderRadius.circular(10),
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.close, size: 16, color: Color(0xFFB85B3D)),
            ),
          ),
        ],
      ]),
    );
  }

  Future<void> _cancelChangeRequest(int crId, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFEF2F2),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close_rounded,
                      color: Color(0xFFB85B3D), size: 24),
                ),
                const SizedBox(height: 16),
                const Text(
                  '변경 요청 취소',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '"$label" 항목을 취소합니다.\n같은 일정의 모든 요청이 취소되면\n[사전점검중] 상태로 원복됩니다.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: Color(0xFF6B7280),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFB85B3D),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('취소하기',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('닫기',
                        style: TextStyle(
                            color: Color(0xFF9CA3AF), fontSize: 13)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    _inspectionSvc.setAuthToken(context.read<AuthService>().authToken);
    try {
      final res = await _inspectionSvc.cancelChangeRequest(crId);
      if (!mounted) return;
      final reverted = res['reverted_workflow'] == true;
      await ProgressDialog(context).complete(
        message: reverted ? '취소 완료\n사전점검중으로 원복됨' : '취소 완료',
      );
      if (!mounted) return;
      await _loadRequests();
    } catch (e) {
      if (!mounted) return;
      await ProgressDialog(context).error(message: '취소 실패: $e');
    }
  }

  Widget _buildStatusPill(String status, {bool small = false}) {
    final (label, color) = switch (status) {
      'REQUESTED' => ('요청', const Color(0xFFE17055)),
      'FILED' => ('신고완료', const Color(0xFF0984E3)),
      'APPLIED' => ('DB반영', const Color(0xFF6B47DC)),
      'VERIFIED' => ('검증완료', const Color(0xFF1A8754)),
      _ => (status, Colors.grey),
    };
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 8, vertical: small ? 2 : 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label,
          style: TextStyle(
            fontSize: small ? 10 : 11,
            fontWeight: FontWeight.w600,
            color: color,
          )),
    );
  }

  Future<void> _downloadBundleForm(Map<String, dynamic> meta, String bundleKey) async {
    try {
      _inspectionSvc.setAuthToken(context.read<AuthService>().authToken);
      final qt = (meta['품질개선팀'] ?? '').toString();
      final wk = (meta['수검예정주차'] ?? '').toString();
      final tm = (meta['조'] ?? '').toString();
      final year = (meta['year'] as num?)?.toInt() ?? DateTime.now().year;
      final bytes = await _inspectionSvc.generateChangeRequestForm(
        qualityTeam: qt,
        week: wk,
        team: tm,
        year: year,
      );
      final blob = html.Blob([bytes], 'application/vnd.ms-excel');
      final url = html.Url.createObjectUrlFromBlob(blob);
      final filename = '${bundleKey.isEmpty ? "변경개설신고" : bundleKey}.xls';
      html.AnchorElement(href: url)
        ..download = filename
        ..click();
      html.Url.revokeObjectUrl(url);
    } catch (e) {
      if (!mounted) return;
      await ProgressDialog(context).error(message: '다운로드 실패: $e');
    }
  }

  Future<void> _markBundleFiled(List<String> schedulePks, String bundleKey) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('묶음 신고 완료', style: TextStyle(fontSize: 16)),
        content: Text(
          '"$bundleKey" 묶음 ${schedulePks.length}국소의 변경개설 신고를 완료했습니까?\n\n'
          '확인 시 모두 [재점검 대기] 상태로 전환되며, 다음날 부분 DS 회신을 받아 적용해야 합니다.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A8754), foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('신고 완료'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      _inspectionSvc.setAuthToken(context.read<AuthService>().authToken);
      final result = await _inspectionSvc.markChangeRequestFiled(schedulePks: schedulePks);
      if (!mounted) return;
      final succeeded = (result['succeeded'] as num?)?.toInt() ?? 0;
      final total = (result['total'] as num?)?.toInt() ?? schedulePks.length;
      await ProgressDialog(context).complete(message: '묶음 신고 완료: $succeeded/$total건 → 재점검 대기');
      if (!mounted) return;
      await _loadRequests();
    } catch (e) {
      if (!mounted) return;
      await ProgressDialog(context).error(message: '실패: $e');
    }
  }

  Widget _buildSampleRow() {
    final isAdmin = context.read<AuthService>().isSuperAdmin;
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: _downloadingTemplate ? null : _downloadSample,
          icon: _downloadingTemplate
              ? const SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: _blue))
              : const Icon(Icons.download, size: 16, color: _blue),
          label: const Text('샘플 양식 다운로드',
              style: TextStyle(fontSize: 13, color: _blue)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: _blue),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
        ),
        if (isAdmin) ...[
          const SizedBox(width: 10),
          OutlinedButton.icon(
            onPressed: _uploadingTemplate ? null : _uploadSample,
            icon: _uploadingTemplate
                ? const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.upload, size: 16),
            label: const Text('샘플 업로드', style: TextStyle(fontSize: 13)),
            style: OutlinedButton.styleFrom(
              foregroundColor: _textSecondary,
              side: const BorderSide(color: _border),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildUploadCard() {
    return Container(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: _processing ? null : _pickFiles,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 36),
              decoration: const BoxDecoration(
                color: Color(0xFFFAFAFB),
                borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Column(
                children: [
                  Icon(Icons.cloud_upload_outlined,
                      size: 44, color: _primary.withValues(alpha: 0.6)),
                  const SizedBox(height: 10),
                  Text(
                    _selectedFiles.isEmpty
                        ? '클릭하여 파일 2개를 선택하세요'
                        : '파일이 선택되었습니다 (클릭하여 변경)',
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _textPrimary),
                  ),
                  const SizedBox(height: 4),
                  const Text('변경개설신고 파일 (A) + DS 파일 (B)  |  .xls, .xlsx',
                      style: TextStyle(fontSize: 12, color: _textSecondary)),
                ],
              ),
            ),
          ),
          if (_selectedFiles.isNotEmpty) ...[
            const Divider(height: 1, color: _border),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (var i = 0; i < _selectedFiles.length; i++)
                    Padding(
                      padding: EdgeInsets.only(
                          bottom: i < _selectedFiles.length - 1 ? 8 : 0),
                      child: Row(
                        children: [
                          Icon(Icons.insert_drive_file_outlined,
                              size: 18, color: _primary),
                          const SizedBox(width: 8),
                          Text(i == 0 ? '파일 A: ' : '파일 B: ',
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: _textSecondary)),
                          Expanded(
                            child: Text(_selectedFiles[i].name,
                                style: const TextStyle(
                                    fontSize: 13, color: _textPrimary),
                                overflow: TextOverflow.ellipsis),
                          ),
                          Text(_formatSize(_selectedFiles[i].size),
                              style: const TextStyle(
                                  fontSize: 11, color: _textSecondary)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
          const Divider(height: 1, color: _border),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                onPressed:
                    _processing || _selectedFiles.length != 2 ? null : _process,
                icon: _processing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_arrow, size: 20),
                label: Text(_processing ? '처리 중...' : '변경 적용 실행',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: Colors.grey.shade300,
                  disabledForegroundColor: Colors.grey.shade500,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultBanner() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle, color: Color(0xFF16A34A), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_result!,
                style: const TextStyle(
                    fontSize: 13, color: Color(0xFF166534), height: 1.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_error!,
                style: const TextStyle(
                    fontSize: 13, color: Color(0xFF991B1B), height: 1.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildDiffSection() {
    final allSelected = _diff.isNotEmpty &&
        _selectedStations.length == _diff.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // diff 카드
        Container(
          decoration: BoxDecoration(
            color: _surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 헤더
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Text('변경 내역',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: _textPrimary)),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: _primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text('${_diff.length}개 국소',
                          style: const TextStyle(
                              fontSize: 12,
                              color: _primary,
                              fontWeight: FontWeight.w600)),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() {
                        if (allSelected) {
                          _selectedStations.clear();
                        } else {
                          _selectedStations = _diff
                              .map((d) => d['허가번호'] as String)
                              .toSet();
                        }
                      }),
                      style: TextButton.styleFrom(
                        foregroundColor: _blue,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(allSelected ? '전체 해제' : '전체 선택',
                          style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: _border),

              // 국소 리스트
              ..._diff.asMap().entries.map((entry) {
                final idx = entry.key;
                final station = entry.value;
                final hn = station['허가번호'] as String;
                final callname = station['호출명칭'] as String? ?? '';
                final changes = (station['changes'] as List<dynamic>? ?? [])
                    .cast<Map<String, dynamic>>();
                final isSelected = _selectedStations.contains(hn);

                return Column(
                  children: [
                    if (idx > 0) const Divider(height: 1, color: _border),
                    InkWell(
                      onTap: () => setState(() {
                        if (isSelected) {
                          _selectedStations.remove(hn);
                        } else {
                          _selectedStations.add(hn);
                        }
                      }),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 12, 16, 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Checkbox(
                              value: isSelected,
                              onChanged: (_) => setState(() {
                                if (isSelected) {
                                  _selectedStations.remove(hn);
                                } else {
                                  _selectedStations.add(hn);
                                }
                              }),
                              activeColor: _blue,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    callname.isNotEmpty ? callname : hn,
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: _textPrimary),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(hn,
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: _textSecondary)),
                                  const SizedBox(height: 8),
                                  ...changes.map(_buildChangeRow),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // 반영 버튼
        SizedBox(
          height: 44,
          child: ElevatedButton.icon(
            onPressed: _selectedStations.isEmpty || _applying
                ? null
                : _applyChanges,
            icon: _applying
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save_alt, size: 20),
            label: Text(
              _applying
                  ? '반영 중...'
                  : '선택 반영 (${_selectedStations.length}개 국소)',
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _blue,
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.grey.shade300,
              disabledForegroundColor: Colors.grey.shade500,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChangeRow(Map<String, dynamic> change) {
    final field = change['field'] as String? ?? '';
    final before = change['before'] as String? ?? '';
    final after = change['after'] as String? ?? '';
    final jn = change['장치번호'] as String? ?? '';
    final label = field + (jn.isNotEmpty ? ' (장치$jn)' : '');

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(label,
                style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFFE65100),
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(fontSize: 12, color: _textPrimary),
                children: [
                  if (before.isNotEmpty) ...[
                    TextSpan(
                        text: before,
                        style: const TextStyle(
                            color: Color(0xFF9E9E9E),
                            decoration: TextDecoration.lineThrough)),
                    const TextSpan(text: '  →  '),
                  ],
                  TextSpan(
                      text: after,
                      style: const TextStyle(
                          color: Color(0xFF1B5E20),
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
