import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/community_service.dart';
import '../widgets/progress_dialog.dart';

/// 요청사항 게시판 화면
class RequestBoardScreen extends StatefulWidget {
  final bool showHeader;
  final int? openRequestId;
  const RequestBoardScreen({super.key, this.showHeader = true, this.openRequestId});

  @override
  State<RequestBoardScreen> createState() => _RequestBoardScreenState();
}

enum _ViewMode { list, detail, write }

class _RequestBoardScreenState extends State<RequestBoardScreen> {
  static const _primaryColor = Color(0xFFE53935);
  static const _darkBtnColor = Color(0xFF111827); // 세련된 블랙 톤 강조색

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
  int? _editingCommentId;
  final _editCommentController = TextEditingController();

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
    _fetchList().then((_) {
      if (widget.openRequestId != null && mounted) {
        _openDetail(widget.openRequestId!);
      }
    });
  }

  @override
  void didUpdateWidget(RequestBoardScreen old) {
    super.didUpdateWidget(old);
    if (widget.openRequestId != null && widget.openRequestId != old.openRequestId) {
      _openDetail(widget.openRequestId!);
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _titleController.dispose();
    _contentController.dispose();
    _passwordController.dispose();
    _commentController.dispose();
    _editCommentController.dispose();
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

  void _showImageViewer(String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.black87,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 5.0,
              child: Image.network(url, fit: BoxFit.contain),
            ),
            Positioned(
              top: 8, right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
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
      _showValidation('이미지는 최대 5개까지 첨부할 수 있습니다.');
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
      _showValidation('이미지 크기는 5MB 이하만 가능합니다.');
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
      if (mounted) { final d = ProgressDialog(context); await d.error(message: '이미지 업로드 실패: $e'); }
    } finally {
      setState(() => _uploading = false);
    }
  }

  Future<void> _savePost() async {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    if (title.isEmpty || content.isEmpty) {
      _showValidation('제목과 내용을 입력해주세요.');
      return;
    }
    setState(() => _loading = true);
    try {
      if (_editId != null) {
        await _svc.updateRequest(_editId!, title, content, images: _images);
        if (mounted) { final d = ProgressDialog(context); await d.complete(message: '수정되었습니다.'); }
      } else {
        await _svc.createRequest(title, content, isSecret: _isSecret, secretPassword: _passwordController.text.trim(), images: _images);
        if (mounted) { final d = ProgressDialog(context); await d.complete(message: '등록되었습니다.'); }
      }
      _page = 1;
      await _fetchList();
      setState(() => _viewMode = _ViewMode.list);
    } catch (e) {
      if (mounted) { final d = ProgressDialog(context); await d.error(message: '저장 실패: $e'); }
      setState(() => _loading = false);
    }
  }

  Future<void> _deletePost(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        title: const Text('삭제 확인', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        content: const Text('이 글을 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다.', style: TextStyle(fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('취소', style: TextStyle(color: Colors.grey.shade700))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('삭제', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _loading = true);
    try {
      await _svc.deleteRequest(id);
      if (mounted) { final d = ProgressDialog(context); await d.complete(message: '삭제되었습니다.'); }
      _page = 1;
      await _fetchList();
      setState(() => _viewMode = _ViewMode.list);
    } catch (e) {
      if (mounted) { final d = ProgressDialog(context); await d.error(message: '삭제 실패: $e'); }
      setState(() => _loading = false);
    }
  }

  Future<void> _changeStatus(int id, String status) async {
    final dialog = ProgressDialog(context);
    dialog.show(message: '상태 변경 중...');
    try {
      await _svc.updateRequestStatus(id, status);
      final res = await _svc.getRequest(id);
      if (mounted) setState(() => _detail = res);
      await dialog.complete(message: '상태가 변경되었습니다.');
    } catch (e) {
      await dialog.error(message: '상태 변경 실패: $e');
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
      if (mounted) { final d = ProgressDialog(context); await d.error(message: '댓글 등록 실패: $e'); }
    }
  }

  void _startEditComment(int commentId, String currentContent) {
    setState(() {
      _editingCommentId = commentId;
      _editCommentController.text = currentContent;
    });
  }

  void _cancelEditComment() {
    setState(() {
      _editingCommentId = null;
      _editCommentController.clear();
    });
  }

  Future<void> _submitEditComment(int commentId, int requestId) async {
    final newContent = _editCommentController.text.trim();
    if (newContent.isEmpty) return;
    try {
      await _svc.updateComment(commentId, newContent);
      final comments = await _svc.getComments(requestId);
      setState(() {
        _comments = comments;
        _editingCommentId = null;
        _editCommentController.clear();
      });
    } catch (e) {
      if (mounted) { final d = ProgressDialog(context); await d.error(message: '댓글 수정 실패: $e'); }
    }
  }

  Future<void> _deleteComment(int commentId, int requestId) async {
    try {
      await _svc.deleteComment(commentId);
      final comments = await _svc.getComments(requestId);
      setState(() => _comments = comments);
    } catch (e) {
      if (mounted) { final d = ProgressDialog(context); await d.error(message: '댓글 삭제 실패: $e'); }
    }
  }

  void _showValidation(String msg) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Text(msg, style: const TextStyle(fontSize: 14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('확인')),
        ],
      ),
    );
  }

  // ── 빌드 ──

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
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
      padding: EdgeInsets.all(isNarrow ? 16 : 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 타이틀
          if (widget.showHeader) ...[
            const Text('요청사항',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            const SizedBox(height: 6),
            Text('문의 및 요청사항을 등록하고 처리 현황을 확인하세요.',
                style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
            const SizedBox(height: 24),
          ],

          // 툴바
          _buildToolbar(isNarrow: isNarrow),
          const SizedBox(height: 12),

          // 테이블
          Expanded(child: _buildTable()),

          // 페이지네이션
          if (_total > 0) _buildPagination(),
        ],
      )
    );
  }

  Widget _buildToolbar({required bool isNarrow}) {
    final filter = Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(6),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: false,
          icon: Icon(Icons.unfold_more, color: Colors.grey.shade500, size: 18),
          dropdownColor: Colors.white,
          borderRadius: BorderRadius.circular(8),
          style: const TextStyle(color: Color(0xFF374151), fontSize: 13, fontWeight: FontWeight.w500),
          value: _statusFilter,
          items: const [
            DropdownMenuItem(value: '', child: Text('상태 전체')),
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
      height: 38,
      child: TextField(
        controller: _searchController,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: '검색어 입력',
          hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
          prefixIcon: Icon(Icons.search, size: 18, color: Colors.grey.shade500),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
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
            borderSide: const BorderSide(color: _primaryColor),
          ),
        ),
        onSubmitted: (_) {
          _page = 1;
          _fetchList();
        },
      ),
    );

    final writeBtn = SizedBox(
      height: 38,
      child: ElevatedButton.icon(
        onPressed: () => _openWrite(),
        icon: const Icon(Icons.edit_outlined, size: 16),
        label: const Text('글쓰기', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        style: ElevatedButton.styleFrom(
          backgroundColor: _darkBtnColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
      ),
    );

    if (isNarrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('총 ', style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
              Text('$_total', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
              Text('건', style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              filter,
              const SizedBox(width: 8),
              Expanded(child: search),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: writeBtn),
        ],
      );
    }

    return Row(
      children: [
        Text('총 ', style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
        Text('$_total', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
        Text('건', style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
        const Spacer(),
        filter,
        const SizedBox(width: 8),
        SizedBox(width: 200, child: search),
        const SizedBox(width: 8),
        writeBtn,
      ],
    );
  }

  Widget _buildTable() {
    final isNarrow = MediaQuery.of(context).size.width < 760;
    
    if (_error != null) {
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
            Icon(Icons.info_outline, size: 48, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _fetchList,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('다시 시도'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.grey.shade700,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ],
        ),
      );
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
            Text('등록된 요청사항이 없습니다.', style: TextStyle(fontSize: 14, color: Colors.grey.shade500)),
          ],
        ),
      );
    }

    if (isNarrow) {
      return ListView.separated(
        itemCount: _items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (_, i) => _buildMobileCard(_items[i], i),
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
          // 헤더
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            ),
            child: Row(
              children: [
                SizedBox(width: 60, child: Text('번호', textAlign: TextAlign.center, style: _headerStyle())),
                Expanded(flex: 5, child: Text('제목', style: _headerStyle())),
                SizedBox(width: 80, child: Text('상태', textAlign: TextAlign.center, style: _headerStyle())),
                SizedBox(width: 100, child: Text('등록자', textAlign: TextAlign.center, style: _headerStyle())),
                SizedBox(width: 100, child: Text('등록일', textAlign: TextAlign.center, style: _headerStyle())),
                SizedBox(width: 60, child: Text('조회', textAlign: TextAlign.center, style: _headerStyle())),
              ],
            ),
          ),
          Divider(height: 1, color: Colors.grey.shade300),
          
          // 행
          Expanded(
            child: ListView.separated(
              itemCount: _items.length,
              separatorBuilder: (_, _) => Divider(height: 1, color: Colors.grey.shade200),
              itemBuilder: (_, i) => _buildRow(_items[i], i),
            ),
          ),
        ],
      ),
    );
  }

  TextStyle _headerStyle() => TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade700);

  Widget _buildRow(Map<String, dynamic> item, int index) {
    final id = item['id'] as int? ?? 0;
    final rowNum = item['번호'] ?? (index + 1);
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
      hoverColor: Colors.grey.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            SizedBox(width: 60, child: Text('$rowNum', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade500))),
            Expanded(
              flex: 5,
              child: Row(
                children: [
                  if (isSecret)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.lock_outline, size: 14, color: Colors.grey.shade400),
                    ),
                  Flexible(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, color: Color(0xFF111827), fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: 80, child: Center(child: _statusBadge(status))),
            SizedBox(width: 100, child: Text(author, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade600))),
            SizedBox(width: 100, child: Text(createdAt, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade600))),
            SizedBox(width: 60, child: Text('$views', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Colors.grey.shade500))),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileCard(Map<String, dynamic> item, int index) {
    final id = item['id'] as int? ?? 0;
    final rowNum = item['번호'] ?? (index + 1);
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
                  _statusBadge(status),
                  const Spacer(),
                  Icon(Icons.visibility_outlined, size: 14, color: Colors.grey.shade400),
                  const SizedBox(width: 4),
                  Text('$views', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isSecret)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, right: 6),
                      child: Icon(Icons.lock_outline, size: 16, color: Colors.grey.shade400),
                    ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF111827), height: 1.4),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Text(author, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('|', style: TextStyle(color: Colors.grey.shade300, fontSize: 12)),
                  ),
                  Text(createdAt, style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
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
    Color border;
    switch (status) {
      case '접수':
        bg = const Color(0xFFEFF6FF);
        fg = const Color(0xFF2563EB);
        border = const Color(0xFFBFDBFE);
        break;
      case '처리중':
        bg = const Color(0xFFFFFBEB);
        fg = const Color(0xFFD97706);
        border = const Color(0xFFFDE68A);
        break;
      case '완료':
        bg = const Color(0xFFECFDF5);
        fg = const Color(0xFF059669);
        border = const Color(0xFFA7F3D0);
        break;
      default:
        bg = Colors.grey.shade100;
        fg = Colors.grey.shade700;
        border = Colors.grey.shade300;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(status,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
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
          _pageBtn('<<', () { _page = 1; _fetchList(); }, enabled: _page > 1),
          _pageBtn('<', () { _page--; _fetchList(); }, enabled: _page > 1),
          for (int p = start; p <= end; p++)
            _pageBtn('$p', () { _page = p; _fetchList(); }, selected: p == _page),
          _pageBtn('>', () { _page++; _fetchList(); }, enabled: _page < _totalPages),
          _pageBtn('>>', () { _page = _totalPages; _fetchList(); }, enabled: _page < _totalPages),
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
            color: selected ? _darkBtnColor : Colors.white, // 통일된 강조색
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: selected ? _darkBtnColor : Colors.grey.shade300),
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
          InkWell(
            onTap: () {
              setState(() => _viewMode = _ViewMode.list);
              _fetchList();
            },
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
          
          // 카드
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 상태 뱃지 & 관리자 상태 변경
                    Row(
                      children: [
                        _statusBadge(status),
                        const Spacer(),
                        if (isAdmin) ...[
                          Text('상태 변경', style: TextStyle(fontSize: 12, color: Colors.grey.shade500, fontWeight: FontWeight.w600)),
                          const SizedBox(width: 8),
                          Container(
                            height: 32,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                isExpanded: false,
                                isDense: true,
                                icon: Icon(Icons.unfold_more, color: Colors.grey.shade500, size: 16),
                                dropdownColor: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                style: const TextStyle(color: Color(0xFF374151), fontSize: 13),
                                value: status,
                                items: const [
                                  DropdownMenuItem(value: '접수', child: Text('접수')),
                                  DropdownMenuItem(value: '처리중', child: Text('처리중')),
                                  DropdownMenuItem(value: '완료', child: Text('완료')),
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
                      ],
                    ),
                    const SizedBox(height: 16),

                    // 제목
                    Text(
                      title,
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Color(0xFF111827), height: 1.3),
                    ),
                    const SizedBox(height: 20),
                    
                    // 메타 정보
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Row(
                        children: [
                          _detailInfoItem(Icons.person_outline, authorDisplay),
                          _verticalDivider(),
                          _detailInfoItem(Icons.calendar_today_outlined, createdAt),
                          _verticalDivider(),
                          _detailInfoItem(Icons.visibility_outlined, '조회 $views'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),

                    // 본문
                    SelectableText(
                      content,
                      style: const TextStyle(fontSize: 15, color: Color(0xFF374151), height: 1.8),
                    ),

                    // 첨부 이미지
                    if (_parseImages(_detail!['images']).isNotEmpty) ...[
                      const SizedBox(height: 40),
                      Text('첨부 이미지', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade800)),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: _parseImages(_detail!['images']).map((key) {
                          final url = _svc.getImageUrl(key);
                          return GestureDetector(
                            onTap: () => _showImageViewer(url),
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: Container(
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.grey.shade200),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    url,
                                    width: 300,
                                    fit: BoxFit.cover,
                                    loadingBuilder: (_, child, progress) {
                                      if (progress == null) return child;
                                      return SizedBox(
                                        width: 300,
                                        height: 200,
                                        child: Center(child: CircularProgressIndicator(color: _primaryColor, strokeWidth: 2)),
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
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],

                    // 수정/삭제
                    if (isMine || isAdmin) ...[
                      const SizedBox(height: 40),
                      Divider(color: Colors.grey.shade200),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (isMine)
                            OutlinedButton.icon(
                              onPressed: () => _openWrite(editItem: _detail),
                              icon: const Icon(Icons.edit_outlined, size: 16),
                              label: const Text('수정'),
                              style: _actionButtonStyle(Colors.grey.shade700),
                            ),
                          if (isMine) const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () => _deletePost(id),
                            icon: const Icon(Icons.delete_outline, size: 16),
                            label: const Text('삭제'),
                            style: _actionButtonStyle(Colors.red),
                          ),
                        ],
                      ),
                    ],

                    // ── 댓글 섹션 ──
                    const SizedBox(height: 40),
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade200),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.chat_bubble_outline, size: 18, color: Colors.grey.shade700),
                              const SizedBox(width: 8),
                              Text(
                                '댓글 ${_comments.length}',
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          
                          // 댓글 입력 폼
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _commentController,
                                  style: const TextStyle(fontSize: 14),
                                  maxLines: 3,
                                  minLines: 1,
                                  decoration: InputDecoration(
                                    hintText: '댓글을 남겨주세요',
                                    hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                                      borderSide: const BorderSide(color: _darkBtnColor),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                height: 46, // 텍스트 필드 기본 높이와 맞춤
                                child: ElevatedButton(
                                  onPressed: () => _submitComment(id),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _darkBtnColor,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                    elevation: 0,
                                    padding: const EdgeInsets.symmetric(horizontal: 20),
                                  ),
                                  child: const Text('등록', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ],
                          ),
                          
                          if (_comments.isNotEmpty) const SizedBox(height: 24),
                          
                          // 댓글 목록
                          ..._comments.map((c) {
                            final cIsMine = c['is_mine'] == true || c['is_mine'] == 1;
                            final cAuthor = c['author_name'] ?? '';
                            final cOrg = c['author_org'] as String? ?? '';
                            final cDisplay = cOrg.isNotEmpty ? '$cAuthor($cOrg)' : cAuthor;
                            final cDate = _formatDate(c['created_at'] as String?);
                            final cUpdatedAt = c['updated_at'] as String? ?? '';
                            final cEdited = cUpdatedAt.isNotEmpty;
                            final cContent = c['content'] ?? '';
                            final cId = c['id'] as int? ?? 0;

                            final isEditing = _editingCommentId == cId;

                            return Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: isEditing ? const Color(0xFFFFFBE6) : Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: isEditing ? const Color(0xFFE53935).withValues(alpha: 0.3) : Colors.grey.shade200,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(cDisplay, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                                      const SizedBox(width: 8),
                                      Text(cDate, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                                      if (cEdited && !isEditing)
                                        Padding(
                                          padding: const EdgeInsets.only(left: 6),
                                          child: Text('(수정됨)', style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                                        ),
                                      const Spacer(),
                                      if (!isEditing && cIsMine)
                                        InkWell(
                                          onTap: () => _startEditComment(cId, cContent),
                                          borderRadius: BorderRadius.circular(4),
                                          child: Padding(
                                            padding: const EdgeInsets.all(4),
                                            child: Icon(Icons.edit_outlined, size: 14, color: Colors.grey.shade400),
                                          ),
                                        ),
                                      if (!isEditing && (cIsMine || isAdmin))
                                        InkWell(
                                          onTap: () => _deleteComment(cId, id),
                                          borderRadius: BorderRadius.circular(4),
                                          child: Padding(
                                            padding: const EdgeInsets.all(4),
                                            child: Icon(Icons.close, size: 14, color: Colors.grey.shade400),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (isEditing) ...[
                                    TextField(
                                      controller: _editCommentController,
                                      maxLines: null,
                                      autofocus: true,
                                      style: const TextStyle(fontSize: 14, height: 1.5, color: Color(0xFF374151)),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: Colors.grey.shade300)),
                                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFE53935), width: 1.5)),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        TextButton(
                                          onPressed: _cancelEditComment,
                                          style: TextButton.styleFrom(
                                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                          ),
                                          child: Text('취소', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                                        ),
                                        const SizedBox(width: 8),
                                        ElevatedButton(
                                          onPressed: () => _submitEditComment(cId, id),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: const Color(0xFFE53935),
                                            foregroundColor: Colors.white,
                                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                          ),
                                          child: const Text('저장', style: TextStyle(fontSize: 12)),
                                        ),
                                      ],
                                    ),
                                  ] else
                                    Text(cContent, style: const TextStyle(fontSize: 14, height: 1.5, color: Color(0xFF374151))),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
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
          child: InkWell(
            onTap: () {
              setState(() => _viewMode = _detail != null ? _ViewMode.detail : _ViewMode.list);
            },
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.arrow_back_ios_new, size: 14, color: Colors.grey.shade600),
                  const SizedBox(width: 6),
                  Text(isEdit ? '수정 취소' : '작성 취소', style: TextStyle(fontSize: 14, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(isEdit ? '요청사항 수정' : '새 요청사항 작성',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                  const SizedBox(height: 24),

                  // 제목
                  _inputLabel('제목'),
                  TextField(
                    controller: _titleController,
                    style: const TextStyle(fontSize: 14),
                    decoration: _inputDecoration('제목을 입력하세요'),
                  ),
                  const SizedBox(height: 20),

                  // 비밀글 설정 (신규 작성 시만)
                  if (!isEdit) ...[
                    _inputLabel('공개 설정'),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade50,
                        border: Border.all(color: Colors.grey.shade200),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              SizedBox(
                                width: 20,
                                height: 20,
                                child: Checkbox(
                                  value: _isSecret,
                                  activeColor: _darkBtnColor,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                  side: BorderSide(color: Colors.grey.shade400),
                                  onChanged: (v) => setState(() => _isSecret = v ?? false),
                                ),
                              ),
                              const SizedBox(width: 8),
                              const Text('비밀글로 작성하기', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF374151))),
                            ],
                          ),
                          if (_isSecret) ...[
                            const SizedBox(height: 12),
                            SizedBox(
                              width: 300,
                              child: TextField(
                                controller: _passwordController,
                                obscureText: true,
                                decoration: _inputDecoration('비밀번호를 설정해주세요 (조회 시 필요)').copyWith(
                                  prefixIcon: Icon(Icons.lock_outline, size: 18, color: Colors.grey.shade500),
                                ),
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],

                  // 내용
                  _inputLabel('내용'),
                  TextField(
                    controller: _contentController,
                    maxLines: 15,
                    style: const TextStyle(fontSize: 15, height: 1.6),
                    decoration: _inputDecoration('요청하실 상세 내용을 입력하세요').copyWith(
                      contentPadding: const EdgeInsets.all(16),
                    ),
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
                  const SizedBox(height: 40),
                  Divider(color: Colors.grey.shade200),
                  const SizedBox(height: 16),

                  // 버튼
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton(
                        onPressed: _loading ? null : () {
                          setState(() => _viewMode = _detail != null ? _ViewMode.detail : _ViewMode.list);
                        },
                        style: _actionButtonStyle(Colors.grey.shade700),
                        child: const Text('취소'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _loading ? null : _savePost,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _darkBtnColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          elevation: 0,
                          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        child: _loading 
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : Text(isEdit ? '수정 완료' : '등록 완료'),
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
        borderSide: const BorderSide(color: _darkBtnColor),
      ),
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