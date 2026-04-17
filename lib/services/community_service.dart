import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// 커뮤니티(공지사항/요청사항) 서비스
class CommunityService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );
  static const _apiTimeout = Duration(seconds: 30);

  String? _authToken;
  void setAuthToken(String? token) => _authToken = token;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${_authToken ?? ''}',
        'Content-Type': 'application/json',
      };

  // ── 통계 ────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getStats() async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/community/stats'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('통계 조회 실패');
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  // ── 공지사항 ────────────────────────────────────────────────

  Future<Map<String, dynamic>> getNotices({
    String? division,
    String? search,
    int page = 1,
    int pageSize = 20,
  }) async {
    final uri = Uri.parse('$_baseUrl/community/notices').replace(
      queryParameters: {
        'page': '$page',
        'pageSize': '$pageSize',
        if (division != null && division.isNotEmpty) 'division': division,
        if (search != null && search.isNotEmpty) 'search': search,
      },
    );
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? '공지사항 조회 실패');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getNotice(int id) async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/community/notices/$id'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? '공지사항 상세 조회 실패');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> viewNotice(int id) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/community/notices/$id/view'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? '조회수 증가 실패');
    }
  }

  Future<int> createNotice(String title, String content, {String division = '전체', List<String> images = const [], List<Map<String, String>> attachments = const []}) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/community/notices'),
      headers: _headers,
      body: json.encode({'title': title, 'content': content, 'division': division, 'images': images, 'attachments': attachments}),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['detail'] ?? '공지사항 생성 실패');
    }
    final notice = body['notice'] as Map<String, dynamic>?;
    return (notice?['id'] as num?)?.toInt() ?? 0;
  }

  Future<void> updateNotice(int id, String title, String content, {String division = '전체', List<String> images = const [], List<Map<String, String>> attachments = const []}) async {
    final resp = await http.put(
      Uri.parse('$_baseUrl/community/notices/$id'),
      headers: _headers,
      body: json.encode({'title': title, 'content': content, 'division': division, 'images': images, 'attachments': attachments}),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? '공지사항 수정 실패');
    }
  }

  Future<void> deleteNotice(int id) async {
    final resp = await http.delete(
      Uri.parse('$_baseUrl/community/notices/$id'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('공지사항 삭제 실패');
  }

  // ── 요청사항 ────────────────────────────────────────────────

  Future<Map<String, dynamic>> getRequests({
    String? status,
    String? search,
    int page = 1,
    int pageSize = 20,
  }) async {
    final uri = Uri.parse('$_baseUrl/community/requests').replace(
      queryParameters: {
        'page': '$page',
        'pageSize': '$pageSize',
        if (status != null && status.isNotEmpty) 'status': status,
        if (search != null && search.isNotEmpty) 'search': search,
      },
    );
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? '요청사항 조회 실패');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getRequest(int id) async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/community/requests/$id'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? '요청사항 상세 조회 실패');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> viewRequest(int id) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/community/requests/$id/view'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? '조회수 증가 실패');
    }
  }

  Future<int> createRequest(String title, String content, {bool isSecret = false, String secretPassword = '', List<String> images = const []}) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/community/requests'),
      headers: _headers,
      body: json.encode({
        'title': title, 'content': content,
        'is_secret': isSecret, 'secret_password': secretPassword,
        'images': images,
      }),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['detail'] ?? '요청사항 생성 실패');
    }
    final req = body['request'] as Map<String, dynamic>?;
    return (req?['id'] as num?)?.toInt() ?? 0;
  }

  Future<void> updateRequest(int id, String title, String content, {List<String> images = const []}) async {
    final resp = await http.put(
      Uri.parse('$_baseUrl/community/requests/$id'),
      headers: _headers,
      body: json.encode({'title': title, 'content': content, 'images': images}),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? '요청사항 수정 실패');
    }
  }

  Future<void> deleteRequest(int id) async {
    final resp = await http.delete(
      Uri.parse('$_baseUrl/community/requests/$id'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('요청사항 삭제 실패');
  }

  // ── 댓글 ────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getComments(int requestId) async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/community/requests/$requestId/comments'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? '댓글 조회 실패');
    }
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['comments'] ?? []);
  }

  Future<Map<String, dynamic>> createComment(int requestId, String content) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/community/requests/$requestId/comments'),
      headers: _headers,
      body: json.encode({'content': content}),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['detail'] ?? '댓글 등록 실패');
    }
    return (body['comment'] as Map<String, dynamic>?) ?? {};
  }

  Future<Map<String, dynamic>> updateComment(int commentId, String content) async {
    final resp = await http.put(
      Uri.parse('$_baseUrl/community/comments/$commentId'),
      headers: _headers,
      body: json.encode({'content': content}),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['detail'] ?? '댓글 수정 실패');
    }
    return (body['comment'] as Map<String, dynamic>?) ?? {};
  }

  Future<void> deleteComment(int commentId) async {
    final resp = await http.delete(
      Uri.parse('$_baseUrl/community/comments/$commentId'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('댓글 삭제 실패');
  }

  /// 이미지 업로드
  Future<Map<String, dynamic>> uploadImage(Uint8List bytes, String filename) async {
    final uri = Uri.parse('$_baseUrl/community/upload-image');
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await request.send().timeout(const Duration(minutes: 2));
    final body = json.decode(await streamed.stream.bytesToString());
    if (streamed.statusCode != 200) throw Exception(body['detail'] ?? '이미지 업로드 실패');
    return body as Map<String, dynamic>;
  }

  /// 일반 파일 업로드
  Future<Map<String, dynamic>> uploadFile(Uint8List bytes, String filename) async {
    final uri = Uri.parse('$_baseUrl/community/upload-file');
    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await request.send().timeout(const Duration(minutes: 5));
    final body = json.decode(await streamed.stream.bytesToString());
    if (streamed.statusCode != 200) throw Exception(body['detail'] ?? '파일 업로드 실패');
    return body as Map<String, dynamic>;
  }

  /// 이미지 URL 생성
  String getImageUrl(String imageKey) => '$_baseUrl/community/images/$imageKey';

  /// 첨부파일 다운로드 URL 생성
  String getFileUrl(String fileKey) => '$_baseUrl/community/files/$fileKey';

  /// 첨부파일 바이트 다운로드 (인증 헤더 포함)
  Future<Uint8List> downloadFile(String fileKey) async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/community/files/$fileKey'),
      headers: _headers,
    ).timeout(const Duration(minutes: 5));
    if (resp.statusCode != 200) throw Exception('파일 다운로드 실패');
    return resp.bodyBytes;
  }

  Future<void> updateRequestStatus(int id, String status) async {
    final resp = await http.put(
      Uri.parse('$_baseUrl/community/requests/$id/status'),
      headers: _headers,
      body: json.encode({'status': status}),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(body['detail'] ?? '상태 변경 실패');
    }
  }
}
