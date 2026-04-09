import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/community_service.dart';

/// 요청사항 게시판 화면
class RequestBoardScreen extends StatefulWidget {
  final bool showHeader;
  const RequestBoardScreen({super.key, this.showHeader = true});

  @override
  State<RequestBoardScreen> createState() => _RequestBoardScreenState();
}

enum _ViewMode { list, detail, write }

class _RequestBoardScreenState extends State<RequestBoardScreen> {
  static const _primaryColor = Color(0xFFE53935);

  final _svc = CommunityService();

  // ── 상태 ──
  _ViewMode _viewMode = _ViewMode.list;
  bool _loading = false;
  String? _error;

  // 목록
  List<dynamic> _items = [];
  int _total = 0;
  int _page = 1;
  int _totalPages = 1;
  static const _pageSize = 20;

  // 필터
  String _statusFilter = '';
  final _searchController = TextEditingController();

  // 상세
  Map<String, dynamic>? _detail;
  List<Map<String, dynamic>> _comments = [];
  final _commentController = TextEditingController();

  // 글쓰기/수정
  int? _editId;
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  bool _isSecret = false;
  final _passwordController = TextEditingController();
  List<String> _images = [];
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _svc.setAuthToken(context.read<AuthService>().authToken);
    _fetchList();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _titleController.dispose();
    _contentController.dispose();
    _passwordController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  // ── API 호출 ──

  Future<void> _fetchList() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await _svc.getRequests(
        status: _statusFilter.isEmpty ? null : _statusFilter,
        search: _searchController.text.trim().isEmpty
            ? null
            : _searchController.text.trim(),
        page: _page,
        pageSize: _pageSize,
      );
      setState(() {
        _items = (res['requests'] as List?) ?? [];
        _total = (res['total'] as int?) ?? 0;
        _totalPages = (_total / _pageSize).ceil().clamp(1, 9999);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = _friendlyError(e);
        _loading = false;
      });
    }
  }

  String _friendlyError(dynamic e) {
    final msg = e.toString();
    if (msg.contains('비밀글')) return '비밀글은 작성자와 관리자만 열람할 수 있습니다.';
    if (msg.contains('Timeout') || msg.contains('timeout')) return '서버 응답이 지연되고 있습니다. 잠시 후 다시 시도해주세요.';
    if (msg.contains('Failed to fetch') || msg.contains('SocketException')) return '서버에 연결할 수 없습니다. 네트워크 상태를 확인해주세요.';
    if (msg.contains('403')) return '접근 권한이 없습니다.';
    if (msg.contains('404')) return '요청하신 글을 찾을 수 없습니다.';
    return '일시적인 오류가 발생했습니다. 잠시 후 다시 시도해주세요.';
  }

  Future<void> _openDetail(int id) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _svc.viewRequest(id);
      final res = await _svc.getRequest(id);
      List<Map<String, dynamic>> comments = [];
      try { comments = await _svc.getComments(id); } catch (_) {}
      setState(() {
        _detail = res;
        _comments = comments;
        _viewMode = _ViewMode.detail;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = _friendlyError(e);
        _loading = false;
      });
    }
  }

  void _openWrite({Map<String, dynamic>? editItem}) {
    _editId = editItem?['id'] as int?;
    _titleController.text = (editItem?['title'] as String?) ?? '';
    _contentController.text = (editItem?['content'] as String?) ?? '';
    _isSecret = editItem?['is_secret'] == true || editItem?['is_secret'] == 1;
    _passwordController.clear();
    _images = _parseImages(editItem?['images']);
    setState(() => _viewMode = _ViewMode.write);
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
      _showSnack('이미지는 최대 5개까지 첨부할 수 있습니다.');
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
      _showSnack('이미지 크기는 5MB 이하만 가능합니다.');
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
      _showSnack('이미지 업로드 실패: $e');
    } finally {
      setState(() => _uploading = false);
    }
  }

  Future<void> _savePost() async {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    if (title.isEmpty || content.isEmpty) {
      _showSnack('제목과 내용을 입력해주세요.');
      return;
    }
    setState(() => _loading = true);
    try {
      if (_editId != null) {
        await _svc.updateRequest(_editId!, title, content, images: _images);
        _showSnack('수정되었습니다.');
      } else {
        await _svc.createRequest(title, content, isSecret: _isSecret, secretPassword: _passwordController.text.trim(), images: _images);
        _showSnack('등록되었습니다.');
      }
      _page = 1;
      await _fetchList();
      setState(() => _viewMode = _ViewMode.list);
    } catch (e) {
      _showSnack('저장 실패: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _deletePost(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('삭제 확인'),
        content: const Text('이 글을 삭제하시겠습니까?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('삭제', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _loading = true);
    try {
      await _svc.deleteRequest(id);
      _showSnack('삭제되었습니다.');
      _page = 1;
      await _fetchList();
      setState(() => _viewMode = _ViewMode.list);
    } catch (e) {
      _showSnack('삭제 실패: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _changeStatus(int id, String status) async {
    setState(() => _loading = true);
    try {
      await _svc.updateRequestStatus(id, status);
      final res = await _svc.getRequest(id);
      setState(() {
        _detail = res;
        _loading = false;
      });
      _showSnack('상태가 변경되었습니다.');
    } catch (e) {
      _showSnack('상태 변경 실패: $e');
      setState(() => _loading = false);
    }
  }

  Future<void> _submitComment(int requestId) async {
    final text = _commentController.text.trim();
    if (text.isEmpty) return;
    try {
      await _svc.createComment(requestId, text);
      _commentController.clear();
      final comments = await _svc.getComments(requestId);
      setState(() => _comments = comments);
    } catch (e) {
      _showSnack('댓글 등록 실패: $e');
    }
  }

  Future<void> _deleteComment(int commentId, int requestId) async {
    try {
      await _svc.deleteComment(commentId);
      final comments = await _svc.getComments(requestId);
      setState(() => _comments = comments);
    } catch (e) {
      _showSnack('댓글 삭제 실패: $e');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  // ── 빌드 ──

  @override
  Widget build(BuildContext context) {
    return Container(
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_viewMode) {
      case _ViewMode.list:
        return _buildListView();
      case _ViewMode.detail:
        return _buildDetailView();
      case _ViewMode.write:
        return _buildWriteView();
    }
  }

  // ════════════════════════════════════════════════════════════
  //  목록 뷰
  // ════════════════════════════════════════════════════════════

  Widget _buildListView() {
    final isNarrow = MediaQuery.of(context).size.width < 760;
    return Padding(
      padding: EdgeInsets.all(isNarrow ? 12 : 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 타이틀
          if (widget.showHeader) ...[
            const Text('요청사항',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('문의 및 요청사항을 등록합니다.',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
            const SizedBox(height: 20),
          ],

          // 툴바
          _buildToolbar(isNarrow: isNarrow),
          const SizedBox(height: 12),

          // 테이블
          Expanded(child: _buildTable()),

          // 페이지네이션
          const SizedBox(height: 12),
          _buildPagination(),
        ],
      )
    );
  }

  Widget _buildToolbar({required bool isNarrow}) {
    final filter = Container(
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
          icon: Icon(Icons.arrow_drop_down, color: _primaryColor, size: 20),
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(12),
          style: const TextStyle(color: Colors.black87, fontSize: 13),
          value: _statusFilter,
          items: const [
            DropdownMenuItem(value: '', child: Text('전체')),
            DropdownMenuItem(value: '접수', child: Text('접수')),
            DropdownMenuItem(value: '처리중', child: Text('처리중')),
            DropdownMenuItem(value: '완료', child: Text('완료')),
          ],
          onChanged: (v) {
            _statusFilter = v ?? '';
            _page = 1;
            _fetchList();
          },
        ),
      ),
    );

    final search = SizedBox(
      height: 36,
      child: TextField(
        controller: _searchController,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: '검색어 입력',
          hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300),
          ),
          suffixIcon: IconButton(
            icon: const Icon(Icons.search, size: 18),
            onPressed: () {
              _page = 1;
              _fetchList();
            },
          ),
        ),
        onSubmitted: (_) {
          _page = 1;
          _fetchList();
        },
      ),
    );

    final writeBtn = SizedBox(
      height: 36,
      child: ElevatedButton.icon(
        onPressed: () => _openWrite(),
        icon: const Icon(Icons.edit, size: 16),
        label: const Text('글쓰기', style: TextStyle(fontSize: 13)),
        style: ElevatedButton.styleFrom(
          backgroundColor: _primaryColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          elevation: 0,
        ),
      ),
    );

    if (isNarrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('총 $_total건',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(
            children: [
              filter,
              const SizedBox(width: 8),
              Expanded(child: search),
            ],
          ),
          const SizedBox(height: 8),
          writeBtn,
        ],
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('총 $_total건',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        filter,
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: search,
        ),
        writeBtn,
      ],
    );
  }

  Widget _buildTable() {
    final isNarrow = MediaQuery.of(context).size.width < 760;
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.info_outline, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _fetchList,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('다시 시도'),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 48, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text('등록된 요청사항이 없습니다.',
                style: TextStyle(fontSize: 14, color: Colors.grey.shade500)),
          ],
        ),
      );
    }

    if (isNarrow) {
      return ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _buildMobileCard(_items[i]),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          // 헤더
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: const Row(
              children: [
                SizedBox(width: 60, child: Text('번호',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black54))),
                Expanded(
                    flex: 5,
                    child: Text('제목',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.black54))),
                SizedBox(width: 70, child: Text('상태',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black54))),
                SizedBox(width: 80, child: Text('등록자',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black54))),
                SizedBox(width: 90, child: Text('등록일',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black54))),
                SizedBox(width: 50, child: Text('조회',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Colors.black54))),
              ],
            ),
          ),
          const Divider(height: 1),
          // 행
          Expanded(
            child: ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) => _buildRow(_items[i]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(Map<String, dynamic> item) {
    final id = item['id'] as int? ?? 0;
    final rowNum = item['번호'] ?? id;
    final title = item['title'] as String? ?? '';
    final status = item['status'] as String? ?? '접수';
    final authorName = item['author_name'] as String? ?? '';
    final authorOrg = item['author_org'] as String? ?? '';
    final author = authorOrg.isNotEmpty ? '$authorName($authorOrg)' : authorName;
    final createdAt = _formatDate(item['created_at'] as String?);
    final views = (item['view_count'] as int?) ?? 0;
    final isSecret = item['is_secret'] == true || item['is_secret'] == 1;

    return InkWell(
      onTap: () => _openDetail(id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            SizedBox(
                width: 60,
                child: Text('$rowNum',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13))),
            Expanded(
              flex: 5,
              child: Row(
                children: [
                  if (isSecret)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(Icons.lock, size: 14, color: Colors.grey.shade500),
                    ),
                  Flexible(
                    child: Text(title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            ),
            SizedBox(width: 70, child: Center(child: _statusBadge(status))),
            SizedBox(
                width: 80,
                child: Text(author,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13))),
            SizedBox(
                width: 90,
                child: Text(createdAt,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600))),
            SizedBox(
                width: 50,
                child: Text('$views',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600))),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileCard(Map<String, dynamic> item) {
    final id = item['id'] as int? ?? 0;
    final rowNum = item['번호'] ?? id;
    final title = item['title'] as String? ?? '';
    final status = item['status'] as String? ?? '접수';
    final authorName = item['author_name'] as String? ?? '';
    final authorOrg = item['author_org'] as String? ?? '';
    final author = authorOrg.isNotEmpty ? '$authorName($authorOrg)' : authorName;
    final createdAt = _formatDate(item['created_at'] as String?);
    final views = (item['view_count'] as int?) ?? 0;
    final isSecret = item['is_secret'] == true || item['is_secret'] == 1;

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _openDetail(id),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '$rowNum',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(width: 8),
                  _statusBadge(status),
                  const Spacer(),
                  Text(
                    '조회 $views',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isSecret)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, right: 4),
                      child: Icon(Icons.lock, size: 14, color: Colors.grey.shade500),
                    ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.person_outline, size: 14, color: Colors.grey.shade500),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.calendar_today_outlined, size: 13, color: Colors.grey.shade500),
                  const SizedBox(width: 4),
                  Text(
                    createdAt,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusBadge(String status) {
    Color bg;
    Color fg;
    switch (status) {
      case '접수':
        bg = const Color(0xFFE3F2FD);
        fg = const Color(0xFF1565C0);
        break;
      case '처리중':
        bg = const Color(0xFFFFF3E0);
        fg = const Color(0xFFE65100);
        break;
      case '완료':
        bg = const Color(0xFFE8F5E9);
        fg = const Color(0xFF2E7D32);
        break;
      default:
        bg = Colors.grey.shade100;
        fg = Colors.grey.shade700;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(status,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  Widget _buildPagination() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left, size: 20),
          onPressed: _page > 1
              ? () {
                  _page--;
                  _fetchList();
                }
              : null,
        ),
        for (int p = 1; p <= _totalPages; p++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: InkWell(
              onTap: p == _page
                  ? null
                  : () {
                      _page = p;
                      _fetchList();
                    },
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: p == _page ? _primaryColor : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('$p',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          p == _page ? FontWeight.bold : FontWeight.normal,
                      color: p == _page ? Colors.white : Colors.black87,
                    )),
              ),
            ),
          ),
        IconButton(
          icon: const Icon(Icons.chevron_right, size: 20),
          onPressed: _page < _totalPages
              ? () {
                  _page++;
                  _fetchList();
                }
              : null,
        ),
      ],
    );
  }

  // ════════════════════════════════════════════════════════════
  //  상세 뷰
  // ════════════════════════════════════════════════════════════

  Widget _buildDetailView() {
    if (_detail == null) return const SizedBox.shrink();

    final auth = context.read<AuthService>();
    final id = _detail!['id'] as int? ?? 0;
    final title = _detail!['title'] as String? ?? '';
    final content = _detail!['content'] as String? ?? '';
    final status = _detail!['status'] as String? ?? '접수';
    final authorName = _detail!['author_name'] as String? ?? '';
    final authorOrg = _detail!['author_org'] as String? ?? '';
    final authorDisplay = authorOrg.isNotEmpty ? '$authorName($authorOrg)' : authorName;
    final createdAt = _formatDate(_detail!['created_at'] as String?);
    final views = (_detail!['view_count'] as int?) ?? 0;
    final isMine = _detail!['is_mine'] == true || _detail!['is_mine'] == 1;
    final isAdmin = auth.isAdmin;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 뒤로가기
          TextButton.icon(
            onPressed: () {
              setState(() => _viewMode = _ViewMode.list);
              _fetchList();
            },
            icon: const Icon(Icons.arrow_back, size: 18),
            label: const Text('목록으로'),
            style: TextButton.styleFrom(foregroundColor: Colors.black54),
          ),
          const SizedBox(height: 12),
          // 카드
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 제목 + 상태 (좁은 폭에서는 세로 배치로 오버플로우 방지)
                    LayoutBuilder(
                      builder: (context, c) {
                        const titleStyle = TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold);
                        if (c.maxWidth < 760) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title,
                                  style: titleStyle, softWrap: true),
                              const SizedBox(height: 8),
                              _statusBadge(status),
                            ],
                          );
                        }
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(title,
                                  style: titleStyle,
                                  softWrap: true),
                            ),
                            const SizedBox(width: 12),
                            _statusBadge(status),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    // 메타 정보
                    Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _metaChip(Icons.person_outline, authorDisplay),
                        _metaChip(Icons.calendar_today, createdAt),
                        _metaChip(Icons.visibility_outlined, '조회 $views'),
                      ],
                    ),
                    const Divider(height: 32),

                    // 본문
                    SelectableText(content,
                        style: const TextStyle(fontSize: 14, height: 1.7)),

                    // 첨부 이미지
                    if (_parseImages(_detail!['images']).isNotEmpty) ...[
                      const SizedBox(height: 24),
                      const Divider(),
                      const SizedBox(height: 12),
                      Text('첨부 이미지', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: _parseImages(_detail!['images']).map((key) {
                          return ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              _svc.getImageUrl(key),
                              width: 240,
                              fit: BoxFit.cover,
                              loadingBuilder: (_, child, progress) {
                                if (progress == null) return child;
                                return SizedBox(
                                  width: 240,
                                  height: 160,
                                  child: Center(child: CircularProgressIndicator(
                                    value: progress.expectedTotalBytes != null
                                        ? progress.cumulativeBytesLoaded / progress.expectedTotalBytes!
                                        : null,
                                    color: _primaryColor,
                                    strokeWidth: 2,
                                  )),
                                );
                              },
                              errorBuilder: (_, __, ___) => Container(
                                width: 240,
                                height: 160,
                                color: Colors.grey.shade100,
                                child: Icon(Icons.broken_image, size: 40, color: Colors.grey.shade400),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                    const SizedBox(height: 32),

                    // 관리자 상태 변경
                    if (isAdmin) ...[
                      const Divider(),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Text('상태 변경:',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border:
                                  Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                isExpanded: false,
                                isDense: true,
                                icon: Icon(Icons.arrow_drop_down,
                                    color: _primaryColor, size: 20),
                                dropdownColor: Colors.white,

                                borderRadius: BorderRadius.circular(12),
                                style: const TextStyle(
                                    color: Colors.black87, fontSize: 13),
                                value: status,
                                items: const [
                                  DropdownMenuItem(
                                      value: '접수', child: Text('접수')),
                                  DropdownMenuItem(
                                      value: '처리중', child: Text('처리중')),
                                  DropdownMenuItem(
                                      value: '완료', child: Text('완료')),
                                ],
                                onChanged: (v) {
                                  if (v != null && v != status) {
                                    _changeStatus(id, v);
                                  }
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],

                    // 수정/삭제
                    if (isMine || isAdmin) ...[
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          if (isMine)
                            OutlinedButton.icon(
                              onPressed: () => _openWrite(editItem: _detail),
                              icon: const Icon(Icons.edit, size: 16),
                              label: const Text('수정'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.black87,
                                side: BorderSide(color: Colors.grey.shade300),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          if (isMine) const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () => _deletePost(id),
                            icon: const Icon(Icons.delete_outline, size: 16),
                            label: const Text('삭제'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                              side: const BorderSide(color: Colors.red),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ],
                      ),
                    ],

                    // ── 댓글 섹션 ──
                    const Divider(height: 32),
                    Text(
                      '댓글 ${_comments.length}건',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    // 댓글 입력
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _commentController,
                            style: const TextStyle(fontSize: 13),
                            decoration: InputDecoration(
                              hintText: '댓글을 입력하세요',
                              hintStyle: TextStyle(
                                  fontSize: 13,
                                  color: Colors.grey.shade400),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                    color: Colors.grey.shade300),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(
                                    color: Colors.grey.shade300),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(
                                    color: _primaryColor),
                              ),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 36,
                          child: ElevatedButton(
                            onPressed: () => _submitComment(id),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primaryColor,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                  borderRadius:
                                      BorderRadius.circular(8)),
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16),
                            ),
                            child: const Text('등록',
                                style: TextStyle(fontSize: 13)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // 댓글 목록
                    ..._comments.map((c) {
                      final cIsMine = c['is_mine'] == true ||
                          c['is_mine'] == 1;
                      final cAuthor = c['author_name'] ?? '';
                      final cOrg = c['author_org'] as String? ?? '';
                      final cDisplay = cOrg.isNotEmpty
                          ? '$cAuthor($cOrg)'
                          : cAuthor;
                      final cDate =
                          _formatDate(c['created_at'] as String?);
                      final cContent = c['content'] ?? '';
                      final cId = c['id'] as int? ?? 0;

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border:
                              Border.all(color: Colors.grey.shade200),
                        ),
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(cDisplay,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight:
                                            FontWeight.w600)),
                                const SizedBox(width: 8),
                                Text(cDate,
                                    style: TextStyle(
                                        fontSize: 11,
                                        color:
                                            Colors.grey.shade500)),
                                const Spacer(),
                                if (cIsMine || isAdmin)
                                  InkWell(
                                    onTap: () =>
                                        _deleteComment(cId, id),
                                    borderRadius:
                                        BorderRadius.circular(4),
                                    child: Padding(
                                      padding:
                                          const EdgeInsets.all(4),
                                      child: Icon(
                                          Icons.close,
                                          size: 14,
                                          color: Colors
                                              .grey.shade400),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(cContent,
                                style: const TextStyle(
                                    fontSize: 13, height: 1.5)),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaChip(IconData icon, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: Colors.grey.shade500),
        const SizedBox(width: 4),
        Text(text,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      ],
    );
  }

  // ════════════════════════════════════════════════════════════
  //  글쓰기/수정 뷰
  // ════════════════════════════════════════════════════════════

  Widget _buildWriteView() {
    final isEdit = _editId != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
          child: TextButton.icon(
            onPressed: () {
              setState(() => _viewMode =
                  _detail != null ? _ViewMode.detail : _ViewMode.list);
            },
            icon: const Icon(Icons.arrow_back, size: 18),
            label: Text(isEdit ? '상세로 돌아가기' : '목록으로'),
            style: TextButton.styleFrom(foregroundColor: Colors.black54),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(isEdit ? '요청사항 수정' : '요청사항 등록',
                      style: const TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 20),

                    // 제목
                    const Text('제목',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _titleController,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '제목을 입력하세요',
                        hintStyle: TextStyle(
                            fontSize: 13, color: Colors.grey.shade400),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              BorderSide(color: Colors.grey.shade300),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              BorderSide(color: Colors.grey.shade300),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 내용
                    const Text('내용',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _contentController,
                      maxLines: 12,
                      style: const TextStyle(fontSize: 14),
                      decoration: InputDecoration(
                        hintText: '내용을 입력하세요',
                        hintStyle: TextStyle(
                            fontSize: 13, color: Colors.grey.shade400),
                        contentPadding: const EdgeInsets.all(12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              BorderSide(color: Colors.grey.shade300),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              BorderSide(color: Colors.grey.shade300),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // 이미지 첨부
                    const Text('이미지 첨부',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: (_uploading || _images.length >= 5) ? null : _pickImage,
                          icon: _uploading
                              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: _primaryColor))
                              : const Icon(Icons.add_photo_alternate_outlined, size: 18),
                          label: Text(_uploading ? '업로드 중...' : '이미지 추가', style: const TextStyle(fontSize: 13)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _primaryColor,
                            side: const BorderSide(color: _primaryColor),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text('${_images.length}/5', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                      ],
                    ),
                    if (_images.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: List.generate(_images.length, (i) {
                          return Stack(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  _svc.getImageUrl(_images[i]),
                                  width: 120,
                                  height: 90,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    width: 120, height: 90,
                                    color: Colors.grey.shade100,
                                    child: Icon(Icons.broken_image, color: Colors.grey.shade400),
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 2,
                                right: 2,
                                child: InkWell(
                                  onTap: () => setState(() => _images.removeAt(i)),
                                  child: Container(
                                    decoration: const BoxDecoration(
                                      color: Colors.black54,
                                      shape: BoxShape.circle,
                                    ),
                                    padding: const EdgeInsets.all(3),
                                    child: const Icon(Icons.close, size: 14, color: Colors.white),
                                  ),
                                ),
                              ),
                            ],
                          );
                        }),
                      ),
                    ],
                    const SizedBox(height: 12),

                    // 비밀글 (신규 작성 시만)
                    if (!isEdit) ...[
                      Row(
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: Checkbox(
                              value: _isSecret,
                              activeColor: _primaryColor,
                              onChanged: (v) =>
                                  setState(() => _isSecret = v ?? false),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text('비밀글',
                              style: TextStyle(fontSize: 13)),
                        ],
                      ),
                      if (_isSecret) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          width: 300,
                          child: TextField(
                            controller: _passwordController,
                            obscureText: true,
                            decoration: InputDecoration(
                              hintText: '비밀번호를 입력하세요',
                              hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                              prefixIcon: const Icon(Icons.lock_outline, size: 18),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(color: Colors.grey.shade300),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                                borderSide: BorderSide(color: Colors.grey.shade300),
                              ),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                              isDense: true,
                              filled: true,
                              fillColor: Colors.white,
                            ),
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 24),

                    // 버튼
                    Row(
                      children: [
                        ElevatedButton(
                          onPressed: _savePost,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _primaryColor,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          child: Text(isEdit ? '수정' : '등록'),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: () {
                            setState(() => _viewMode = _detail != null
                                ? _ViewMode.detail
                                : _ViewMode.list);
                          },
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.black87,
                            side: BorderSide(color: Colors.grey.shade300),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          child: const Text('취소'),
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

  // ── 유틸 ──

  String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return '-';
    try {
      final dt = DateTime.parse(iso);
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }
}
