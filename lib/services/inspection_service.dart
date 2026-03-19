import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// 수검 일정 관리 서비스
class InspectionService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );
  static const _apiTimeout = Duration(seconds: 30);
  static const _uploadTimeout = Duration(minutes: 10);

  String? _authToken;
  void setAuthToken(String? token) => _authToken = token;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${_authToken ?? ''}',
        'Content-Type': 'application/json',
      };

  // ── Import ──────────────────────────────────────────────

  Future<String> uploadRaw(Uint8List bytes, String filename) async {
    final uri = Uri.parse('$_baseUrl/inspection/upload-raw');
    final req = http.Request('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..headers['X-Filename'] = Uri.encodeComponent(filename)
      ..headers['Content-Type'] = 'application/octet-stream'
      ..bodyBytes = bytes;
    final streamed = await req.send().timeout(_uploadTimeout);
    final body = json.decode(await streamed.stream.bytesToString()) as Map<String, dynamic>;
    if (streamed.statusCode != 200) throw Exception(body['detail'] ?? '업로드 실패');
    return body['s3Key'] as String;
  }

  Future<String> enqueue(String s3Key, int year, String uploadedBy) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/enqueue'),
      headers: _headers,
      body: json.encode({'s3Key': s3Key, 'year': year, 'uploadedBy': uploadedBy}),
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '잡 생성 실패');
    return body['jobId'] as String;
  }

  Future<Map<String, dynamic>> jobStatus(String jobId) async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/inspection/job/$jobId'),
      headers: _headers,
    ).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  // ── Meta ─────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getMeta() async {
    final resp = await http.get(
      Uri.parse('$_baseUrl/inspection/meta'),
      headers: _headers,
    ).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  // ── Query ────────────────────────────────────────────────

  Future<Map<String, dynamic>> getOrgMap(int year) async {
    final uri = Uri.parse('$_baseUrl/inspection/org-map').replace(
        queryParameters: {'year': '$year'});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<List<String>> getColumnValues(int year, String col, {String sheet = 'all'}) async {
    final uri = Uri.parse('$_baseUrl/inspection/column-values').replace(
        queryParameters: {'year': '$year', 'col': col, 'sheet': sheet});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<String>.from(body['values'] ?? []);
  }

  Future<Map<String, dynamic>> getData({
    required int year,
    String sheet = 'all',
    Map<String, List<String>> filters = const {},
    String search = '',
    int page = 1,
    int pageSize = 100,
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/data'),
      headers: _headers,
      body: json.encode({
        'year': year, 'sheet': sheet,
        'filters': filters, 'search': search,
        'page': page, 'page_size': pageSize,
      }),
    ).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getSummary({
    required int year,
    String sheet = 'all',
    Map<String, List<String>> filters = const {},
  }) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/summary'),
      headers: _headers,
      body: json.encode({'year': year, 'sheet': sheet, 'filters': filters}),
    ).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getDetail(int year, String licenseNo) async {
    final uri = Uri.parse('$_baseUrl/inspection/detail').replace(
        queryParameters: {'year': '$year', '허가번호': licenseNo});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  // ── Schedule ─────────────────────────────────────────────

  Future<void> upsertSchedule(Map<String, dynamic> data) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/schedule'),
      headers: _headers,
      body: json.encode(data),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '일정 저장 실패');
    }
  }

  Future<void> deleteSchedule(int year, String licenseNo) async {
    final resp = await http.delete(
      Uri.parse('$_baseUrl/inspection/schedule/$year/${Uri.encodeComponent(licenseNo)}'),
      headers: _headers,
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('일정 삭제 실패');
  }

  Future<List<Map<String, dynamic>>> getSchedules(int year, {String accessTeam = ''}) async {
    final uri = Uri.parse('$_baseUrl/inspection/schedules').replace(queryParameters: {
      'year': '$year',
      if (accessTeam.isNotEmpty) 'access담당': accessTeam,
    });
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  // ── Result ───────────────────────────────────────────────

  Future<void> upsertResult(Map<String, dynamic> data) async {
    final resp = await http.post(
      Uri.parse('$_baseUrl/inspection/result'),
      headers: _headers,
      body: json.encode(data),
    ).timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final b = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      throw Exception(b['detail'] ?? '결과 저장 실패');
    }
  }

  Future<Map<String, dynamic>> uploadPhoto(
      int year, String licenseNo, Uint8List bytes, String filename) async {
    final uri = Uri.parse('$_baseUrl/inspection/result/photo').replace(
        queryParameters: {'year': '$year', '허가번호': licenseNo});
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await req.send().timeout(_uploadTimeout);
    final body = json.decode(await streamed.stream.bytesToString()) as Map<String, dynamic>;
    if (streamed.statusCode != 200) throw Exception(body['detail'] ?? '사진 업로드 실패');
    return body;
  }

  Future<void> deletePhoto(int year, String licenseNo, String s3Key) async {
    final uri = Uri.parse('$_baseUrl/inspection/result/photo').replace(
        queryParameters: {'year': '$year', '허가번호': licenseNo, 's3_key': s3Key});
    final resp = await http.delete(uri, headers: _headers).timeout(_apiTimeout);
    if (resp.statusCode != 200) throw Exception('사진 삭제 실패');
  }

  Future<String> getPhotoUrl(String s3Key) async {
    final uri = Uri.parse('$_baseUrl/inspection/result/photo-url').replace(
        queryParameters: {'s3_key': s3Key});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return body['url'] as String;
  }

  Future<List<Map<String, dynamic>>> getMyList(int year) async {
    final uri = Uri.parse('$_baseUrl/inspection/my-list').replace(
        queryParameters: {'year': '$year'});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  Future<List<Map<String, dynamic>>> getProgress(int year) async {
    final uri = Uri.parse('$_baseUrl/inspection/progress').replace(
        queryParameters: {'year': '$year'});
    final resp = await http.get(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return List<Map<String, dynamic>>.from(body['items'] ?? []);
  }

  Future<String> buildDsDetail(String divisionId, String importDate) async {
    final uri = Uri.parse('$_baseUrl/inspection/build-ds-detail').replace(
        queryParameters: {'division_id': divisionId, 'import_date': importDate});
    final resp = await http.post(uri, headers: _headers).timeout(_apiTimeout);
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['detail'] ?? '빌드 실패');
    return body['jobId'] as String;
  }
}
