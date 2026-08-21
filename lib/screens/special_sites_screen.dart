import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/inspection_service.dart';
import '../widgets/progress_dialog.dart';

/// 특이국소 유형 목록 (백엔드 VALID_SPECIAL_TYPES와 동일하게 유지)
const kSpecialSiteTypes = ['지하철', '터널', '야간출입', '기타'];

/// 본부 → 팀 목록 매핑 (부적합 관리 화면과 동일)
const _orgMap = <String, List<String>>{
  '강남': ['강남품질개선팀', '관악품질개선팀', '강동품질개선팀', '양천품질개선팀'],
  '강북': ['용산품질개선팀', '종로품질개선팀', '성수품질개선팀', '수유품질개선팀', '지하철품질개선팀'],
  '인천': ['북인천품질개선팀', '남인천품질개선팀', '부천품질개선팀', '일산품질개선팀', '남양주품질개선팀', '의정부품질개선팀'],
  '경기': ['하남품질개선팀', '평택품질개선팀', '수원품질개선팀', '분당품질개선팀', '용인품질개선팀'],
  '경남': ['동부산품질개선팀', '서부산품질개선팀', '김해품질개선팀', '울산품질개선팀', '진주품질개선팀', '창원품질개선팀'],
  '경북': ['동대구품질개선팀', '서대구품질개선팀', '경산품질개선팀', '포항품질개선팀', '안동품질개선팀', '구미품질개선팀'],
  '서부': ['서광주품질개선팀', '동광주품질개선팀', '목포품질개선팀', '순천품질개선팀', '제주품질개선팀', '전주품질개선팀', '군산품질개선팀'],
  '충청': ['대전품질개선팀', '천안품질개선팀', '세종품질개선팀', '서산품질개선팀', '서청주품질개선팀', '동청주품질개선팀', '충주품질개선팀'],
  '강원': ['원주품질개선팀', '춘천품질개선팀', '강릉품질개선팀'],
};

/// 유형별 표시 색 — 일정 화면 행 배경색에서도 재사용
const kSpecialSiteColors = <String, Color>{
  '지하철': Color(0xFF8E24AA),
  '터널': Color(0xFFF57C00),
  '야간출입': Color(0xFF3949AB),
  '기타': Color(0xFF6B7280),
};

/// 특이국소 관리 화면 (서류 관리)
class SpecialSitesScreen extends StatefulWidget {
  const SpecialSitesScreen({super.key});

  @override
  State<SpecialSitesScreen> createState() => _SpecialSitesScreenState();
}

class _SpecialSitesScreenState extends State<SpecialSitesScreen> {
  static const Color _primary = Color(0xFFE53935);
  static const Color _border = Color(0xFFE5E7EB);

  late final InspectionService _svc;
  late final bool _canManage;
  late final bool _isSuperAdmin;
  late final String _myRegion;

  /// manager 는 본인 본부 행만 선택/삭제 가능 (백엔드에도 동일 격리 존재)
  bool _canTouchRow(Map<String, dynamic> it) {
    if (_isSuperAdmin) return true;
    if (_myRegion.isEmpty) return false;
    return '${it['access담당'] ?? it['skt본부'] ?? ''}'.trim().startsWith(_myRegion);
  }

  bool _loading = false;
  List<Map<String, dynamic>> _items = [];
  String _typeFilter = '';
  String _regionFilter = '';
  String _teamFilter = '';
  String _search = '';
  final _searchCtrl = TextEditingController();
  final Set<String> _checked = {};

  @override
  void initState() {
    super.initState();
    final auth = context.read<AuthService>();
    _svc = InspectionService()..setAuthToken(auth.authToken);
    _canManage = auth.isAdmin; // admin + manager
    _isSuperAdmin = auth.isSuperAdmin;
    _myRegion = auth.currentDivisionShortName ?? '';
    // 본인 본부/팀 자동 필터 (superAdmin 제외 — 부적합 관리와 동일 패턴)
    if (!auth.isSuperAdmin) {
      final myRegion = auth.currentDivisionShortName ?? '';
      if (myRegion.isNotEmpty && _orgMap.containsKey(myRegion)) {
        _regionFilter = myRegion;
        final myTeam = (auth.userTeam ?? '').trim();
        if (!auth.isDivisionAdmin &&
            (_orgMap[myRegion]?.contains(myTeam) ?? false)) {
          _teamFilter = myTeam;
        }
      }
    }
    if (_canManage) {
      _load();
    } else {
      // member 접근 차단 — 안내 후 화면은 잠금 상태 유지
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final d = ProgressDialog(context);
        d.error(message: '권한이 없습니다 (관리자/매니저 전용)');
      });
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final items = await _svc.getSpecialSites();
      if (!mounted) return;
      setState(() {
        _items = items;
        _checked.removeWhere((no) => !items.any((it) => it['허가번호'] == no));
      });
    } catch (e) {
      if (mounted) {
        final d = ProgressDialog(context);
        await d.error(message: '특이국소 조회 실패');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> get _filtered {
    return _items.where((it) {
      if (_typeFilter.isNotEmpty && it['유형'] != _typeFilter) return false;
      if (_regionFilter.isNotEmpty) {
        final region = '${it['access담당'] ?? it['skt본부'] ?? ''}'.trim();
        if (!region.startsWith(_regionFilter)) return false;
      }
      if (_teamFilter.isNotEmpty && '${it['품질개선팀'] ?? ''}'.trim() != _teamFilter) {
        return false;
      }
      if (_search.isNotEmpty) {
        final terms = _search
            .split(RegExp(r'[,\s]+'))
            .map((t) => t.trim().toLowerCase())
            .where((t) => t.isNotEmpty);
        final hay =
            '${it['허가번호'] ?? ''} ${it['호출명칭'] ?? ''} ${it['설치장소'] ?? ''}'.toLowerCase();
        if (!terms.any(hay.contains)) return false;
      }
      return true;
    }).toList();
  }

  String _fmtDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    return iso.length >= 10 ? iso.substring(0, 10) : iso;
  }

  // ── CSV 가져오기 (Playground 특이국소 내보내기 파일 → 전체 교체) ──
  Future<void> _importCsv() async {
    final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom, allowedExtensions: ['csv'], withData: true);
    if (picked == null || picked.files.isEmpty) return;
    final bytes = picked.files.first.bytes;
    if (bytes == null || !mounted) return;

    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('﻿')) text = text.substring(1); // BOM 제거
    final rows = _parseCsv(text);
    if (rows.length < 2) {
      final d = ProgressDialog(context);
      await d.error(message: 'CSV에 데이터가 없습니다');
      return;
    }
    final header = rows.first.map((h) => h.trim()).toList();
    final iType = header.indexOf('유형');
    final iNo = header.indexOf('허가번호');
    final iMemo = header.indexOf('메모');
    final iBy = header.indexOf('등록자');
    final iAt = header.indexOf('등록일시');
    if (iType < 0 || iNo < 0) {
      final d = ProgressDialog(context);
      await d.error(message: '유형/허가번호 컬럼을 찾을 수 없습니다');
      return;
    }
    String cell(List<String> r, int i) => (i >= 0 && i < r.length) ? r[i].trim() : '';

    final items = <Map<String, dynamic>>[];
    final typeCount = <String, int>{};
    for (final r in rows.skip(1)) {
      final no = cell(r, iNo);
      final t = cell(r, iType);
      if (no.isEmpty || t.isEmpty) continue;
      items.add({
        '허가번호': no,
        '유형': t,
        '메모': cell(r, iMemo),
        '등록자': cell(r, iBy),
        '등록일시': cell(r, iAt),
      });
      typeCount[t] = (typeCount[t] ?? 0) + 1;
    }
    if (items.isEmpty || !mounted) {
      if (mounted) {
        final d = ProgressDialog(context);
        await d.error(message: '가져올 행이 없습니다');
      }
      return;
    }

    final summary = typeCount.entries.map((e) => '${e.key} ${e.value}건').join(' · ');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('특이국소 CSV 가져오기',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('CSV ${items.length}건 ($summary)', style: const TextStyle(fontSize: 13.5)),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF7ED),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFED7AA)),
            ),
            child: const Text('기존 특이국소 목록은 CSV 내용으로 전체 교체됩니다.',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF92400E))),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary, foregroundColor: Colors.white, elevation: 0),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('전체 교체'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    final dialog = ProgressDialog(context);
    dialog.show(message: '${items.length}건 가져오는 중...');
    try {
      final res = await _svc.importSpecialSites(items);
      final excluded = List.from(res['not_found'] ?? []).length +
          List.from(res['invalid_type'] ?? []).length;
      await dialog.complete(
          message: '${res['imported']}건 가져오기 완료'
              '${excluded > 0 ? ' (대상 미발견 등 제외 $excluded건)' : ''}');
      _checked.clear();
      await _load();
    } catch (e) {
      await dialog.error(message: '가져오기 실패');
    }
  }

  /// RFC4180 CSV 파서 (따옴표 필드 내 쉼표/줄바꿈/이스케이프 지원)
  List<List<String>> _parseCsv(String text) {
    final rows = <List<String>>[];
    final field = StringBuffer();
    var row = <String>[];
    bool inQuotes = false;
    for (int i = 0; i < text.length; i++) {
      final c = text[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"') {
        inQuotes = true;
      } else if (c == ',') {
        row.add(field.toString());
        field.clear();
      } else if (c == '\r' || c == '\n') {
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
        row.add(field.toString());
        field.clear();
        if (row.length > 1 || row.first.trim().isNotEmpty) rows.add(row);
        row = <String>[];
      } else {
        field.write(c);
      }
    }
    row.add(field.toString());
    if (row.length > 1 || row.first.trim().isNotEmpty) rows.add(row);
    return rows;
  }


  Future<void> _deleteChecked() async {
    if (_checked.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('특이국소 삭제', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text('${_checked.length}건을 특이국소에서 제외할까요?',
            style: const TextStyle(fontSize: 13.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('삭제', style: TextStyle(color: _primary))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final dialog = ProgressDialog(context);
    dialog.show(message: '삭제 중...');
    try {
      final deleted = await _svc.deleteSpecialSites(_checked.toList());
      await dialog.complete(message: '$deleted건 삭제 완료');
      _checked.clear();
      await _load();
    } catch (e) {
      await dialog.error(message: '삭제 실패');
    }
  }

  Widget _filterDropdown(String label, String value, List<String> options,
      ValueChanged<String> onChanged) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isDense: true,
          icon: const Icon(Icons.arrow_drop_down, color: _primary, size: 20),
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          style: const TextStyle(color: Colors.black87, fontSize: 13),
          value: value,
          items: [
            DropdownMenuItem(value: '', child: Text('$label 전체')),
            ...options.map((o) => DropdownMenuItem(value: o, child: Text(o))),
          ],
          onChanged: (v) => onChanged(v ?? ''),
        ),
      ),
    );
  }

  Widget _typeChip(String type) {
    final color = kSpecialSiteColors[type] ?? const Color(0xFF6B7280);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(type,
          style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_canManage) {
      return Container(
        color: const Color(0xFFFAFAFB),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                  color: Color(0xFFF3F4F6), shape: BoxShape.circle),
              child: Icon(Icons.lock_outline, size: 36, color: Colors.grey.shade400),
            ),
            const SizedBox(height: 16),
            const Text('권한이 없습니다',
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
            const SizedBox(height: 6),
            Text('특이국소 관리는 관리자/매니저 전용 메뉴입니다',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          ]),
        ),
      );
    }
    final rows = _filtered;
    final isNarrow = MediaQuery.of(context).size.width < 600;

    return Container(
      color: const Color(0xFFFAFAFB),
      child: Column(children: [
        // 필터 카드
        Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _border),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 8,
                  offset: const Offset(0, 2)),
            ],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 3, height: 16,
                decoration: BoxDecoration(
                    color: _primary, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.fmd_bad_outlined, size: 14, color: Color(0xFF6B7280)),
              const SizedBox(width: 4),
              const Text('특이국소 관리',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
              const SizedBox(width: 8),
              Text('지하철·터널·야간출입 등 일정 계획 시 참고할 국소',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ]),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFF0F9FF),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFBAE6FD)),
              ),
              child: Row(children: [
                const Icon(Icons.info_outline, size: 14, color: Color(0xFF0369A1)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _isSuperAdmin
                        ? '특이국소 등록·수정은 Playground Web에서 합니다. 변경 후 CSV를 내려받아 [CSV 가져오기]로 반영하세요.'
                        : '특이국소 등록·수정은 Playground Web에서 합니다.',
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF0369A1)),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ...['', ...kSpecialSiteTypes].map((t) {
                  final selected = _typeFilter == t;
                  return ChoiceChip(
                    label: Text(t.isEmpty ? '전체' : t, style: const TextStyle(fontSize: 12.5)),
                    selected: selected,
                    onSelected: (_) => setState(() => _typeFilter = t),
                    selectedColor: _primary,
                    labelStyle: TextStyle(
                        color: selected ? Colors.white : const Color(0xFF374151)),
                    backgroundColor: Colors.white,
                    side: BorderSide(color: selected ? _primary : Colors.grey.shade300),
                    showCheckmark: false,
                  );
                }),
                _filterDropdown('본부', _regionFilter, _orgMap.keys.toList(),
                    (v) => setState(() {
                      _regionFilter = v;
                      _teamFilter = '';
                    })),
                _filterDropdown(
                    '팀',
                    _teamFilter,
                    _regionFilter.isEmpty ? const [] : (_orgMap[_regionFilter] ?? []),
                    (v) => setState(() => _teamFilter = v)),
                SizedBox(
                  width: isNarrow ? double.infinity : 260,
                  height: 38,
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _search = v),
                    decoration: InputDecoration(
                      hintText: '허가번호, 호출명칭, 설치장소 검색',
                      hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF9CA3AF)),
                      filled: true,
                      fillColor: const Color(0xFFF9FAFB),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: _border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: _border),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F9FF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFBAE6FD)),
                  ),
                  child: Text('${rows.length}건',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF0369A1))),
                ),
                if (_isSuperAdmin)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.upload_file_outlined, size: 16),
                    label: const Text('CSV 가져오기', style: TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF7B1FA2),
                      side: const BorderSide(color: Color(0xFF7B1FA2)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    ),
                    onPressed: _importCsv,
                  ),
                if (_canManage && _checked.isNotEmpty)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: Text('${_checked.length}건 삭제', style: const TextStyle(fontSize: 13)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _primary,
                      side: const BorderSide(color: _primary),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    ),
                    onPressed: _deleteChecked,
                  ),
              ],
            ),
          ]),
        ),
        const SizedBox(height: 12),
        // 목록
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
            ),
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _primary))
                : rows.isEmpty
                    ? Center(
                        child: Text('등록된 특이국소가 없습니다',
                            style: TextStyle(fontSize: 13, color: Colors.grey.shade500)))
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                                minWidth: MediaQuery.of(context).size.width - 32),
                            child: SingleChildScrollView(
                              child: DataTable(
                                headingRowColor:
                                    const WidgetStatePropertyAll(Color(0xFFF3F4F6)),
                                headingTextStyle: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF374151)),
                                dataTextStyle: const TextStyle(
                                    fontSize: 12.5, color: Color(0xFF111827)),
                                columnSpacing: 20,
                                horizontalMargin: 14,
                                columns: [
                                  if (_canManage)
                                    DataColumn(label: Builder(builder: (_) {
                                      final nos = rows
                                          .where(_canTouchRow)
                                          .map((it) => '${it['허가번호'] ?? ''}')
                                          .toSet();
                                      final allChecked = nos.isNotEmpty &&
                                          nos.every(_checked.contains);
                                      final someChecked =
                                          nos.any(_checked.contains);
                                      return Checkbox(
                                        tristate: true,
                                        value: allChecked
                                            ? true
                                            : (someChecked ? null : false),
                                        onChanged: (_) => setState(() {
                                          if (allChecked) {
                                            _checked.removeAll(nos);
                                          } else {
                                            _checked.addAll(nos);
                                          }
                                        }),
                                      );
                                    })),
                                  const DataColumn(label: Text('유형')),
                                  const DataColumn(label: Text('허가번호')),
                                  const DataColumn(label: Text('호출명칭')),
                                  const DataColumn(label: Text('본부')),
                                  const DataColumn(label: Text('팀')),
                                  const DataColumn(label: Text('설치장소')),
                                  const DataColumn(label: Text('메모')),
                                  const DataColumn(label: Text('등록자')),
                                  const DataColumn(label: Text('등록일')),
                                ],
                                rows: rows.map((it) {
                                  final no = '${it['허가번호'] ?? ''}';
                                  return DataRow(
                                    cells: [
                                      if (_canManage)
                                        DataCell(Checkbox(
                                          value: _checked.contains(no),
                                          onChanged: _canTouchRow(it)
                                              ? (v) => setState(() {
                                                    if (v == true) {
                                                      _checked.add(no);
                                                    } else {
                                                      _checked.remove(no);
                                                    }
                                                  })
                                              : null, // 타본부 행 — 선택 불가
                                        )),
                                      DataCell(_typeChip('${it['유형'] ?? ''}')),
                                      DataCell(Text(no)),
                                      DataCell(Text('${it['호출명칭'] ?? ''}')),
                                      DataCell(Text('${it['access담당'] ?? it['skt본부'] ?? ''}')),
                                      DataCell(Text('${it['품질개선팀'] ?? ''}')),
                                      DataCell(ConstrainedBox(
                                        constraints: const BoxConstraints(maxWidth: 220),
                                        child: Text('${it['설치장소'] ?? ''}',
                                            overflow: TextOverflow.ellipsis),
                                      )),
                                      DataCell(ConstrainedBox(
                                        constraints: const BoxConstraints(maxWidth: 160),
                                        child: Text('${it['메모'] ?? ''}',
                                            overflow: TextOverflow.ellipsis),
                                      )),
                                      DataCell(Text('${it['등록자'] ?? ''}')),
                                      DataCell(Text(_fmtDate('${it['등록일시'] ?? ''}'))),
                                    ],
                                  );
                                }).toList(),
                              ),
                            ),
                          ),
                        ),
                      ),
          ),
        ),
      ]),
    );
  }
}
