// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/community_service.dart';
import '../widgets/progress_dialog.dart';
import '../widgets/rich_content_editor.dart';
import '../widgets/rich_content_viewer.dart';

/// 공지사항 화면 — 목록 / 상세 / 작성·수정 3가지 뷰를 상태로 전환
class NoticeBoardScreen extends StatefulWidget {
  final bool showHeader;
  const NoticeBoardScreen({super.key, this.showHeader = true});

  @override
  State<NoticeBoardScreen> createState() => _NoticeBoardScreenState();
}

enum _ViewMode { list, detail, write }

class _NoticeBoardScreenState extends State<NoticeBoardScreen> {
  static const _primary = Color(0xFFE53935);
  static const _divisions = [
    '전체', '강남', '강북', '경기', '인천', '충청', '강원', '경남', '경북', '서부',
  ];

  final _svc = CommunityService();
  bool _initialized = false;

  // ── 공통 상태 ──
  _ViewMode _mode = _ViewMode.list;

  // ── 목록 ──
  bool _loading = false;
  List<Map<String, dynamic>> _items = [];
  int _total = 0;
  int _page = 1;
  final int _pageSize = 20;
  String _selectedDivision = '전체';
  final _searchCtrl = TextEditingController();
  String _searchText = '';

  // ── 상세 ──
  Map<String, dynamic>? _detail;
  bool _detailLoading = false;

  // ── 작성/수정 ──
  bool _isEditing = false;
  int? _editId;
  final _titleCtrl = TextEditingController();
  String _htmlContent = '';
  String _editorViewId = '0';
  final _editorKey = GlobalKey<RichContentEditorState>();
  String _writeDivision = '전체';
  bool _saving = false;
  List<String> _images = [];
  List<Map<String, String>> _attachments = []; // {url, filename, ext}
  bool _uploading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _svc.setAuthToken(context.read<AuthService>().authToken);
      _fetchList();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _titleCtrl.dispose();
    super.dispose();
  }

  // ── 데이터 ──

  Future<void> _fetchList() async {
    setState(() => _loading = true);
    try {
      final res = await _svc.getNotices(
        division: _selectedDivision == '전체' ? null : _selectedDivision,
        search: _searchText.isEmpty ? null : _searchText,
        page: _page,
        pageSize: _pageSize,
      );
      setState(() {
        _items = List<Map<String, dynamic>>.from(res['notices'] ?? []);
        _total = res['total'] ?? 0;
      });
    } catch (e) {
      _snack('공지사항 조회 실패: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _openDetail(int id) async {
    setState(() {
      _mode = _ViewMode.detail;
      _detailLoading = true;
      _detail = null;
    });
    try {
      await _svc.viewNotice(id);
      final data = await _svc.getNotice(id);
      setState(() => _detail = data);
    } catch (e) {
      _snack('상세 조회 실패: $e');
      setState(() => _mode = _ViewMode.list);
    } finally {
      setState(() => _detailLoading = false);
    }
  }

  void _openWrite() {
    _isEditing = false;
    _editId = null;
    _titleCtrl.clear();
    _htmlContent = '';
    _editorViewId = DateTime.now().millisecondsSinceEpoch.toString();
    _writeDivision = '전체';
    _images = [];
    _attachments = [];
    setState(() => _mode = _ViewMode.write);
  }

  void _openEdit(Map<String, dynamic> item) {
    _isEditing = true;
    _editId = item['id'] as int?;
    _titleCtrl.text = item['title'] ?? '';
    _htmlContent = item['content'] ?? '';
    _editorViewId = DateTime.now().millisecondsSinceEpoch.toString();
    _writeDivision = item['division'] ?? '전체';
    _images = _parseImages(item['images']);
    _attachments = _parseAttachments(item['attachments']);
    setState(() => _mode = _ViewMode.write);
  }

  List<String> _parseImages(dynamic raw) {
    if (raw is List) return raw.cast<String>();
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = json.decode(raw);
        if (decoded is List) return decoded.cast<String>();
      } catch (_) {}
    }
    return [];
  }

  Future<void> _pickImage() async {
    if (_images.length >= 5) {
      _snack('이미지는 최대 5개까지 첨부할 수 있습니다.');
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;
    if (file.bytes!.length > 5 * 1024 * 1024) {
      _snack('이미지 크기는 5MB 이하만 가능합니다.');
      return;
    }
    setState(() => _uploading = true);
    try {
      final res = await _svc.uploadImage(file.bytes!, file.name);
      final url = res['url'] as String? ?? '';
      if (url.isNotEmpty) {
        setState(() => _images.add(url));
      }
    } catch (e) {
      _snack('이미지 업로드 실패: $e');
    } finally {
      setState(() => _uploading = false);
    }
  }

  Future<void> _pickFile() async {
    if (_attachments.length >= 10) {
      _snack('파일은 최대 10개까지 첨부할 수 있습니다.');
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    for (final file in result.files) {
      if (_attachments.length >= 10) break;
      if (file.bytes == null) continue;
      if (file.bytes!.length > 50 * 1024 * 1024) {
        _snack('${file.name}: 50MB 이하 파일만 첨부할 수 있습니다.');
        continue;
      }
      setState(() => _uploading = true);
      try {
        final res = await _svc.uploadFile(file.bytes!, file.name);
        final url = res['url'] as String? ?? '';
        final ext = res['ext'] as String? ?? '';
        if (url.isNotEmpty) {
          setState(() => _attachments.add({'url': url, 'filename': file.name, 'ext': ext}));
        }
      } catch (e) {
        _snack('${file.name} 업로드 실패: $e');
      } finally {
        setState(() => _uploading = false);
      }
    }
  }

  List<Map<String, String>> _parseAttachments(dynamic raw) {
    if (raw == null) return [];
    try {
      List decoded;
      if (raw is String) {
        decoded = json.decode(raw) as List;
      } else if (raw is List) {
        decoded = raw;
      } else {
        return [];
      }
      return decoded.map((e) {
        if (e is Map) {
          return {'url': e['url']?.toString() ?? '', 'filename': e['filename']?.toString() ?? '', 'ext': e['ext']?.toString() ?? ''};
        }
        return <String, String>{};
      }).where((e) => e['url']!.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    final rawHtml = _editorKey.currentState?.getHtml() ?? _htmlContent;
    // <br>만 있거나 공백만인 경우 빈 것으로 처리
    final content = rawHtml.replaceAll(RegExp(r'<br\s*/?>'), '').trim();
    if (title.isEmpty) {
      _snack('제목을 입력해주세요.');
      return;
    }
    if (content.isEmpty) {
      _snack('내용을 입력해주세요.');
      return;
    }
    setState(() => _saving = true);
    final dialog = ProgressDialog(context);
    dialog.show(message: _isEditing ? '수정 중...' : '등록 중...');
    try {
      if (_isEditing && _editId != null) {
        await _svc.updateNotice(_editId!, title, content, division: _writeDivision, images: _images, attachments: _attachments);
        await dialog.complete(message: '공지사항이 수정되었습니다.');
        _openDetail(_editId!);
      } else {
        final newId = await _svc.createNotice(title, content, division: _writeDivision, images: _images, attachments: _attachments);
        await dialog.complete(message: '공지사항이 등록되었습니다.');
        _openDetail(newId);
      }
    } catch (e) {
      await dialog.error(message: '저장 실패');
    } finally {
      setState(() => _saving = false);
    }
  }

  Future<void> _delete(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: const Text('공지사항 삭제', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: const Text('정말 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.', style: TextStyle(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('취소', style: TextStyle(color: Colors.grey.shade700))),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final dialog = ProgressDialog(context);
    dialog.show(message: '삭제 중...');
    try {
      await _svc.deleteNotice(id);
      await dialog.complete(message: '삭제되었습니다.');
      setState(() => _mode = _ViewMode.list);
      _fetchList();
    } catch (e) {
      await dialog.error(message: '삭제 실패');
    }
  }

  void _backToList() {
    setState(() => _mode = _ViewMode.list);
    _fetchList();
  }

  void _snack(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        content: Text(msg, style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('확인')),
        ],
      ),
    );
  }

  // ── 페이지네이션 ──

  int get _totalPages => (_total / _pageSize).ceil().clamp(1, 9999);

  void _goPage(int p) {
    if (p < 1 || p > _totalPages || p == _page) return;
    _page = p;
    _fetchList();
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 760;
    final pad = narrow ? 16.0 : 24.0;
    
    return Material(
      color: Colors.transparent, // 상위 배경색을 그대로 따라감
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: switch (_mode) {
          _ViewMode.list => _buildList(),
          _ViewMode.detail => _buildDetail(),
          _ViewMode.write => _buildWrite(),
        },
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  LIST VIEW
  // ═══════════════════════════════════════════════════════════════

  Widget _buildList() {
    final auth = context.read<AuthService>();
    final canWrite = auth.isSuperAdmin || auth.isDivisionAdmin;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showHeader) ...[
          const Text('공지사항', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          const SizedBox(height: 6),
          Text(
            '조직 내 중요 안내 및 공지사항을 확인하세요.',
            style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 24),
        ],

        // 본부 탭
        _buildDivisionTabs(),
        const SizedBox(height: 20),

        // 총 건수 + 검색 + 글쓰기 (정갈한 배치)
        Row(
          children: [
            Text('총 ', style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
            Text('$_total', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
            Text('건', style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
            
            const Spacer(),
            
            // 검색창
            SizedBox(
              width: 200,
              height: 38,
              child: TextField(
                controller: _searchCtrl,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: '검색어 입력',
                  hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                  prefixIcon: Icon(Icons.search, size: 18, color: Colors.grey.shade500),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: _primary),
                  ),
                ),
                onSubmitted: (_) {
                  _searchText = _searchCtrl.text.trim();
                  _page = 1;
                  _fetchList();
                },
              ),
            ),
            
            if (canWrite) ...[
              const SizedBox(width: 8),
              SizedBox(
                height: 38,
                child: ElevatedButton.icon(
                  onPressed: _openWrite,
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('글쓰기', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF111827), // 세련된 블랙 톤 강조색
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),

        // 테이블 영역
        Expanded(child: _buildTable()),

        // 페이지네이션
        if (_total > 0) _buildPagination(),
      ],
    );
  }

  Widget _buildDivisionTabs() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: _divisions.map((d) {
          final selected = d == _selectedDivision;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () {
                _selectedDivision = d;
                _page = 1;
                _fetchList();
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: selected ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: selected ? _primary : Colors.grey.shade300,
                    width: selected ? 1.5 : 1.0, // 선택 시 테두리를 살짝 두껍게
                  ),
                ),
                child: Text(
                  d,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: selected ? _primary : Colors.grey.shade600,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTable() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _primary));
    }
    if (_items.isEmpty) {
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inbox_outlined, size: 48, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text('등록된 공지사항이 없습니다.', style: TextStyle(fontSize: 14, color: Colors.grey.shade500)),
          ],
        ),
      );
    }

    final isNarrow = MediaQuery.sizeOf(context).width < 760;
    if (isNarrow) {
      return ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _buildNoticeMobileCard(_items[i], i),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        children: [
          // 테이블 헤더
          Container(
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                SizedBox(width: 60, child: Text('번호', textAlign: TextAlign.center, style: _headerStyle())),
                Expanded(flex: 5, child: Text('제목', style: _headerStyle())),
                SizedBox(width: 120, child: Text('등록자', textAlign: TextAlign.center, style: _headerStyle())),
                SizedBox(width: 100, child: Text('등록일', textAlign: TextAlign.center, style: _headerStyle())),
                SizedBox(width: 60, child: Text('조회', textAlign: TextAlign.center, style: _headerStyle())),
              ],
            ),
          ),
          Divider(height: 1, color: Colors.grey.shade300),

          // 테이블 행 (Row)
          Expanded(
            child: ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => Divider(height: 1, color: Colors.grey.shade200),
              itemBuilder: (_, i) {
                final item = _items[i];
                final id = item['id'] ?? 0;
                final rowNum = item['번호'] ?? (i + 1);
                final title = item['title'] ?? '';
                final authorName = item['author_name'] ?? item['author'] ?? '';
                final authorOrg = item['author_org'] as String? ?? '';
                final author = authorOrg.isNotEmpty ? '$authorName($authorOrg)' : authorName;
                final date = _fmtDate(item['created_at']);
                final views = item['view_count'] ?? 0;

                return InkWell(
                  onTap: () => _openDetail(id),
                  hoverColor: Colors.grey.shade50, // 마우스 오버 시 피드백
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Row(
                      children: [
                        SizedBox(width: 60, child: Text('$rowNum', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade500))),
                        Expanded(
                          flex: 5,
                          child: Text(
                            title,
                            style: const TextStyle(fontSize: 14, color: Color(0xFF111827), fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(width: 120, child: Text(author, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade600))),
                        SizedBox(width: 100, child: Text(date, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade600))),
                        SizedBox(width: 60, child: Text('$views', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade500))),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  TextStyle _headerStyle() => TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700);

  Widget _buildNoticeMobileCard(Map<String, dynamic> item, int index) {
    final id = item['id'] ?? 0;
    final rowNum = item['번호'] ?? (index + 1);
    final title = item['title'] ?? '';
    final authorName = item['author_name'] ?? item['author'] ?? '';
    final authorOrg = item['author_org'] as String? ?? '';
    final author = authorOrg.isNotEmpty ? '$authorName($authorOrg)' : authorName;
    final date = _fmtDate(item['created_at']);
    final views = item['view_count'] ?? 0;
    final division = item['division'] as String? ?? '';

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openDetail(id),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(4)),
                    child: Text('No.$rowNum', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
                  ),
                  const SizedBox(width: 8),
                  if (division.isNotEmpty && division != '전체') ...[
                    _metaChip(division),
                  ],
                  const Spacer(),
                  Icon(Icons.visibility_outlined, size: 14, color: Colors.grey.shade400),
                  const SizedBox(width: 4),
                  Text('$views', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF111827), height: 1.4),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(author, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('|', style: TextStyle(color: Colors.grey.shade300, fontSize: 12)),
                  ),
                  Text(date, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPagination() {
    const maxButtons = 5;
    int start = ((_page - 1) ~/ maxButtons) * maxButtons + 1;
    int end = (start + maxButtons - 1).clamp(1, _totalPages);

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _pageBtn('<<', () => _goPage(1), enabled: _page > 1),
          _pageBtn('<', () => _goPage(_page - 1), enabled: _page > 1),
          for (int p = start; p <= end; p++)
            _pageBtn('$p', () => _goPage(p), selected: p == _page),
          _pageBtn('>', () => _goPage(_page + 1), enabled: _page < _totalPages),
          _pageBtn('>>', () => _goPage(_totalPages), enabled: _page < _totalPages),
        ],
      ),
    );
  }

  Widget _pageBtn(String label, VoidCallback onTap, {bool selected = false, bool enabled = true}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? _primary : Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: selected ? _primary : Colors.grey.shade300),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? Colors.white : (enabled ? Colors.grey.shade700 : Colors.grey.shade400),
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  DETAIL VIEW
  // ═══════════════════════════════════════════════════════════════

  Widget _buildDetail() {
    if (_detailLoading || _detail == null) {
      return const Center(child: CircularProgressIndicator(color: _primary));
    }
    final d = _detail!;
    final isMine = d['is_mine'] == true || d['is_mine'] == 1;
    final isAdmin = context.read<AuthService>().isAdmin;
    
    final title = d['title'] ?? '';
    final authorName = d['author_name'] ?? d['author'] ?? '';
    final authorOrg = d['author_org'] as String? ?? '';
    final author = authorOrg.isNotEmpty ? '$authorName($authorOrg)' : authorName;
    final date = _fmtDate(d['created_at']);
    final views = d['view_count'] ?? 0;
    final content = d['content'] ?? '';
    final division = d['division'] ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _backToList,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_back_ios_new, size: 14, color: Colors.grey.shade600),
                const SizedBox(width: 6),
                Text('목록으로 돌아가기', style: TextStyle(fontSize: 14, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32), // 넉넉한 내부 패딩
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 상단 메타 (본부 등)
                  if (division.toString().trim().isNotEmpty) ...[
                    _metaChip(division.toString()),
                    const SizedBox(height: 12),
                  ],
                  
                  // 제목
                  Text(
                    title,
                    style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Color(0xFF111827), height: 1.3),
                  ),
                  const SizedBox(height: 20),
                  
                  // 작성자, 날짜, 조회수 (깔끔한 회색 바 형태로 묶음)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Row(
                      children: [
                        _detailInfoItem(Icons.person_outline, author),
                        _verticalDivider(),
                        _detailInfoItem(Icons.calendar_today_outlined, date),
                        _verticalDivider(),
                        _detailInfoItem(Icons.visibility_outlined, '조회 $views'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  
                  // 본문 — 테이블이면 행 수 기반, 아니면 텍스트 길이 기반으로 높이 추정
                  RichContentViewer(
                    viewId: '${d['id']}_${d['updated_at'] ?? d['created_at'] ?? '0'}',
                    content: content,
                    height: () {
                      final rowCount = RegExp(r'<tr[^>]*>', caseSensitive: false).allMatches(content).length;
                      if (rowCount > 0) return (rowCount * 36.0 + 80).clamp(120, 2000);
                      return (content.length / 40 * 24).clamp(120, 2000);
                    }(),
                  ),
                  
                  // 첨부 이미지
                  if (_parseImages(d['images']).isNotEmpty) ...[
                    const SizedBox(height: 40),
                    Text('첨부 이미지', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade800)),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: _parseImages(d['images']).map((key) {
                        return Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade200),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              _svc.getImageUrl(key),
                              width: 300, // 살짝 키움
                              fit: BoxFit.cover,
                              loadingBuilder: (_, child, progress) {
                                if (progress == null) return child;
                                return SizedBox(
                                  width: 300,
                                  height: 200,
                                  child: Center(child: CircularProgressIndicator(color: _primary, strokeWidth: 2)),
                                );
                              },
                              errorBuilder: (_, __, ___) => Container(
                                width: 300,
                                height: 200,
                                color: Colors.grey.shade50,
                                child: Icon(Icons.image_not_supported_outlined, size: 40, color: Colors.grey.shade300),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],

                  // 첨부파일
                  if (_parseAttachments(d['attachments']).isNotEmpty) ...[
                    const SizedBox(height: 40),
                    Text('첨부파일', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade800)),
                    const SizedBox(height: 12),
                    ..._parseAttachments(d['attachments']).map((att) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: InkWell(
                          onTap: () async {
                            final dialog = ProgressDialog(context);
                            dialog.show(message: '다운로드 중...');
                            try {
                              final bytes = await _svc.downloadFile(att['url']!);
                              final blob = html.Blob([bytes]);
                              final blobUrl = html.Url.createObjectUrlFromBlob(blob);
                              html.AnchorElement(href: blobUrl)
                                ..setAttribute('download', att['filename'] ?? 'file')
                                ..click();
                              html.Url.revokeObjectUrl(blobUrl);
                              await dialog.complete(message: '다운로드 완료');
                            } catch (e) {
                              await dialog.error(message: '다운로드 실패');
                            }
                          },
                          borderRadius: BorderRadius.circular(6),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade50,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.grey.shade200),
                            ),
                            child: Row(
                              children: [
                                Icon(_fileIcon(att['ext'] ?? ''), size: 18, color: _primary),
                                const SizedBox(width: 10),
                                Expanded(child: Text(att['filename'] ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
                                Icon(Icons.download_outlined, size: 16, color: Colors.grey.shade500),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                  ],

                  // 수정/삭제 버튼
                  if (isMine || isAdmin) ...[
                    const SizedBox(height: 40),
                    Divider(color: Colors.grey.shade200),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (isMine)
                          OutlinedButton(
                            onPressed: () => _openEdit(d),
                            style: _actionButtonStyle(Colors.grey.shade700),
                            child: const Text('수정'),
                          ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () => _delete(d['id'] as int),
                          style: _actionButtonStyle(Colors.red),
                          child: const Text('삭제'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _detailInfoItem(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.grey.shade500),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(fontSize: 13, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _verticalDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Text('|', style: TextStyle(color: Colors.grey.shade300, fontSize: 14)),
    );
  }

  ButtonStyle _actionButtonStyle(Color color) {
    return OutlinedButton.styleFrom(
      foregroundColor: color,
      side: BorderSide(color: color.withOpacity(0.3)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
  }

  Widget _metaChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _primary.withOpacity(0.08),
        borderRadius: BorderRadius.circular(4), // 모서리를 덜 둥글게
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, color: _primary, fontWeight: FontWeight.w600),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  WRITE / EDIT VIEW
  // ═══════════════════════════════════════════════════════════════

  Widget _buildWrite() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _saving ? null : _backToList,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.arrow_back_ios_new, size: 14, color: Colors.grey.shade600),
                const SizedBox(width: 6),
                Text(_isEditing ? '수정 취소' : '작성 취소', style: TextStyle(fontSize: 14, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isEditing ? '공지사항 수정' : '새 공지사항 작성',
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                  ),
                  const SizedBox(height: 24),

                  // 제목
                  _inputLabel('제목'),
                  TextField(
                    controller: _titleCtrl,
                    style: const TextStyle(fontSize: 14),
                    decoration: _inputDecoration('공지사항 제목을 입력하세요'),
                  ),
                  const SizedBox(height: 20),

                  // 대상 본부
                  _inputLabel('대상 본부'),
                  Container(
                    width: 200, // 전체 너비를 차지하지 않고 정갈하게 길이 제한
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        icon: Icon(Icons.unfold_more, color: Colors.grey.shade500, size: 20),
                        dropdownColor: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        style: const TextStyle(color: Color(0xFF374151), fontSize: 14),
                        value: _writeDivision,
                        items: _divisions.map((d) => DropdownMenuItem(value: d, child: Text(d))).toList(),
                        onChanged: (v) {
                          if (v != null) setState(() => _writeDivision = v);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // 내용
                  _inputLabel('내용'),
                  RichContentEditor(
                    key: _editorKey,
                    viewId: _editorViewId,
                    initialHtml: _htmlContent,
                    height: 320,
                    onImagePaste: (bytes, filename) async {
                      final res = await _svc.uploadImage(bytes, filename);
                      return _svc.getImageUrl(res['url'] as String? ?? '');
                    },
                  ),
                  const SizedBox(height: 24),

                  // 이미지 첨부
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _inputLabel('첨부 이미지', paddingBottom: 0),
                      const SizedBox(width: 12),
                      Text('${_images.length} / 5', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      InkWell(
                        onTap: (_uploading || _images.length >= 5) ? null : _pickImage,
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            border: Border.all(color: Colors.grey.shade300, style: BorderStyle.solid),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _uploading
                              ? const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                              : Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.add_photo_alternate_outlined, color: Colors.grey.shade500, size: 24),
                                    const SizedBox(height: 4),
                                    Text('추가', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: List.generate(_images.length, (i) {
                              return Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Container(
                                      width: 80,
                                      height: 80,
                                      decoration: BoxDecoration(
                                        border: Border.all(color: Colors.grey.shade200),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: Image.network(
                                          _svc.getImageUrl(_images[i]),
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) => Icon(Icons.broken_image, color: Colors.grey.shade300),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      top: -6,
                                      right: -6,
                                      child: InkWell(
                                        onTap: () => setState(() => _images.removeAt(i)),
                                        child: Container(
                                          decoration: const BoxDecoration(
                                            color: Color(0xFF111827),
                                            shape: BoxShape.circle,
                                          ),
                                          padding: const EdgeInsets.all(4),
                                          child: const Icon(Icons.close, size: 12, color: Colors.white),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // 파일 첨부
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _inputLabel('파일 첨부', paddingBottom: 0),
                      const SizedBox(width: 12),
                      Text('${_attachments.length} / 10', style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: (_uploading || _attachments.length >= 10) ? null : _pickFile,
                    icon: _uploading
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.attach_file, size: 16),
                    label: const Text('파일 선택'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.grey.shade700,
                      side: BorderSide(color: Colors.grey.shade300),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      textStyle: const TextStyle(fontSize: 13),
                    ),
                  ),
                  if (_attachments.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ...List.generate(_attachments.length, (i) {
                      final att = _attachments[i];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.grey.shade200),
                          ),
                          child: Row(
                            children: [
                              Icon(_fileIcon(att['ext'] ?? ''), size: 16, color: Colors.grey.shade600),
                              const SizedBox(width: 8),
                              Expanded(child: Text(att['filename'] ?? '', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
                              InkWell(
                                onTap: () => setState(() => _attachments.removeAt(i)),
                                child: Icon(Icons.close, size: 16, color: Colors.grey.shade500),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],

                  const SizedBox(height: 40),
                  Divider(color: Colors.grey.shade200),
                  const SizedBox(height: 16),

                  // 하단 버튼
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: _saving ? null : _backToList,
                        style: _actionButtonStyle(Colors.grey.shade700),
                        child: const Text('취소'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _saving ? null : _save,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _primary,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                          elevation: 0,
                          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        child: _saving
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : Text(_isEditing ? '수정 완료' : '등록 완료'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _inputLabel(String text, {double paddingBottom = 8}) {
    return Padding(
      padding: EdgeInsets.only(bottom: paddingBottom),
      child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(fontSize: 14, color: Colors.grey.shade400),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: Colors.grey.shade300),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: _primary),
      ),
    );
  }

  IconData _fileIcon(String ext) {
    switch (ext.toLowerCase()) {
      case '.pdf': return Icons.picture_as_pdf_outlined;
      case '.xlsx': case '.xls': case '.csv': return Icons.table_chart_outlined;
      case '.pptx': case '.ppt': return Icons.slideshow_outlined;
      case '.docx': case '.doc': case '.hwp': case '.hwpx': return Icons.description_outlined;
      case '.zip': return Icons.folder_zip_outlined;
      case '.jpg': case '.jpeg': case '.png': case '.gif': case '.webp': return Icons.image_outlined;
      default: return Icons.attach_file;
    }
  }

  // ── Util ──

  String _fmtDate(dynamic v) {
    if (v == null) return '-';
    final s = v.toString();
    if (s.length >= 10) return s.substring(0, 10);
    return s;
  }
}