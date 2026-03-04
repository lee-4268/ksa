import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 호출명칭 매칭 서비스 — S3 DB 기반 통시/Access담당/품질개선팀 자동 매칭
class CallnameService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  static const _uploadTimeout = Duration(minutes: 5);
  static const _apiTimeout = Duration(seconds: 30);

  String? _authToken;
  void setAuthToken(String? token) => _authToken = token;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${_authToken ?? ''}',
        'Content-Type': 'application/json',
      };

  /// 호출명칭 DB 상태 조회
  Future<Map<String, dynamic>> getDbStatus() async {
    final resp = await http
        .get(Uri.parse('$_baseUrl/callname/db-status'),
            headers: _headers)
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('DB 상태 조회 실패: ${resp.statusCode}');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 호출명칭 DB 미리보기 (첫 N행)
  Future<Map<String, dynamic>> getDbPreview({int limit = 50}) async {
    final resp = await http
        .get(
          Uri.parse('$_baseUrl/callname/db-preview')
              .replace(queryParameters: {'limit': limit.toString()}),
          headers: _headers,
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('DB 미리보기 실패: ${resp.statusCode}');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 관리자: DB CSV/Excel 업로드 (replace=true면 기존 DB 교체)
  Future<Map<String, dynamic>> uploadDbFile(
      Uint8List bytes, String filename, {
      bool replace = true,
      void Function(String stage, double progress)? onProgress,
  }) async {
    onProgress?.call('업로드 준비 중...', 0.0);

    final uri = Uri.parse('$_baseUrl/callname/upload-csv')
        .replace(queryParameters: {'replace': replace.toString()});
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: filename));

    onProgress?.call('서버에 업로드 중...', 0.2);

    final streamed = await req.send().timeout(_uploadTimeout);

    onProgress?.call('서버에서 처리 중...', 0.6);

    final respBytes = await streamed.stream.toBytes();
    if (streamed.statusCode != 200) {
      throw Exception(
          'DB 업로드 실패: ${utf8.decode(respBytes)}');
    }

    onProgress?.call('완료', 1.0);
    return json.decode(utf8.decode(respBytes)) as Map<String, dynamic>;
  }

  /// Excel 파일 업로드 → 컬럼 감지 + 매칭 대상 건수
  Future<Map<String, dynamic>> uploadExcel(
      Uint8List bytes, String filename) async {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/callname/upload'),
    )
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: filename));

    final streamed = await req.send().timeout(_uploadTimeout);
    final respBytes = await streamed.stream.toBytes();
    if (streamed.statusCode != 200) {
      final body = utf8.decode(respBytes);
      throw Exception('업로드 실패: $body');
    }
    return json.decode(utf8.decode(respBytes)) as Map<String, dynamic>;
  }

  /// 컬럼 고유값 조회 (필터 UI용)
  Future<List<Map<String, dynamic>>> getColumnValues(
      String uploadId, String column) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/callname/upload/$uploadId/column-values'),
          headers: _headers,
          body: json.encode({'column': column}),
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('컬럼 조회 실패: ${resp.statusCode}');
    }
    final data = json.decode(utf8.decode(resp.bodyBytes));
    return (data['values'] as List).cast<Map<String, dynamic>>();
  }

  /// 필터 미리보기 → 매칭 대상 건수
  Future<Map<String, dynamic>> previewFiltered(
      String uploadId, Map<String, List<String>> filters) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/callname/upload/$uploadId/preview'),
          headers: _headers,
          body: json.encode({'filters': filters}),
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('미리보기 실패: ${resp.statusCode}');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 매칭 시작
  Future<Map<String, dynamic>> startProcess(
      String uploadId, Map<String, List<String>> filters) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/callname/process'),
          headers: _headers,
          body: json.encode({'upload_id': uploadId, 'filters': filters}),
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final body = utf8.decode(resp.bodyBytes);
      throw Exception('매칭 시작 실패: $body');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// SSE 스트림으로 매칭 진행률 수신
  Stream<Map<String, dynamic>> processStream(String processId) async* {
    final uri = Uri.parse('$_baseUrl/callname/process/$processId/stream');
    final req = http.Request('GET', uri);
    req.headers['Authorization'] = 'Bearer ${_authToken ?? ''}';
    req.headers['Accept'] = 'text/event-stream';

    final client = http.Client();
    try {
      final streamed = await client.send(req).timeout(_uploadTimeout);
      final lines = streamed.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        if (line.startsWith('data: ')) {
          try {
            final data =
                json.decode(line.substring(6)) as Map<String, dynamic>;
            yield data;
            if (data['type'] == 'complete' || data['type'] == 'error') {
              break;
            }
          } catch (_) {}
        }
      }
    } finally {
      client.close();
    }
  }

  /// 결과 다운로드 URL 조회
  Future<Map<String, dynamic>> getDownloadUrl(String processId) async {
    final resp = await http
        .get(
          Uri.parse('$_baseUrl/callname/process/$processId/download'),
          headers: _headers,
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('다운로드 URL 조회 실패: ${resp.statusCode}');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }
}
