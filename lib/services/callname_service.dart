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
  static const _processTimeout = Duration(minutes: 5);

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

  /// 관리자: DB CSV/Excel 업로드 → jobId 반환 (비동기 처리)
  Future<String> uploadDbFile(
      Uint8List bytes, String filename, {
      bool replace = true,
  }) async {
    final uri = Uri.parse('$_baseUrl/callname/upload-csv')
        .replace(queryParameters: {'replace': replace.toString()});
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: filename));

    final streamed = await req.send().timeout(_uploadTimeout);
    final respBytes = await streamed.stream.toBytes();
    if (streamed.statusCode != 200) {
      throw Exception(
          'DB 업로드 실패: ${utf8.decode(respBytes)}');
    }

    final data = json.decode(utf8.decode(respBytes)) as Map<String, dynamic>;
    return data['jobId'] as String;
  }

  /// 업로드 잡 상태 폴링
  Future<Map<String, dynamic>> getUploadJobStatus(String jobId) async {
    final resp = await http
        .get(
          Uri.parse('$_baseUrl/callname/upload-job/$jobId'),
          headers: _headers,
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('잡 상태 조회 실패: ${resp.statusCode}');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// Excel 파일 업로드 → 컬럼 감지 + 매칭 대상 건수
  /// 2단계: upload-raw(S3 스트리밍) → upload-complete(파싱)
  Future<Map<String, dynamic>> uploadExcel(
      Uint8List bytes, String filename) async {
    // ── Step 1: S3 스트리밍 업로드 (파싱 없음, ALB timeout 방지) ──
    final rawReq = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/callname/upload-raw'),
    )
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: filename));

    final rawStreamed = await rawReq.send().timeout(_uploadTimeout);
    final rawBytes = await rawStreamed.stream.toBytes();
    if (rawStreamed.statusCode != 200) {
      final body = utf8.decode(rawBytes);
      throw Exception('업로드 실패: $body');
    }
    final rawData = json.decode(utf8.decode(rawBytes)) as Map<String, dynamic>;

    // ── Step 2: 서버에서 S3 파일 파싱 (VPC 내부, 빠름) ──
    final completeResp = await http
        .post(
          Uri.parse('$_baseUrl/callname/upload-complete'),
          headers: _headers,
          body: json.encode({
            'uploadId': rawData['uploadId'],
            's3Key': rawData['s3Key'],
            'filename': rawData['filename'],
            'ext': rawData['ext'],
          }),
        )
        .timeout(const Duration(minutes: 3));
    if (completeResp.statusCode != 200) {
      final body = utf8.decode(completeResp.bodyBytes);
      throw Exception('파싱 실패: $body');
    }
    return json.decode(utf8.decode(completeResp.bodyBytes))
        as Map<String, dynamic>;
  }

  /// 백그라운드 분석 상태 조회 (폴링용)
  Future<Map<String, dynamic>> getAnalysisStatus(String uploadId) async {
    final resp = await http
        .get(
          Uri.parse('$_baseUrl/callname/upload/$uploadId/analysis'),
          headers: _headers,
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('분석 상태 조회 실패: ${resp.statusCode}');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
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
        .timeout(_processTimeout);
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

  /// Sample 양식 목록 조회 (모든 사용자)
  Future<List<Map<String, dynamic>>> listSampleTemplates() async {
    final resp = await http
        .get(Uri.parse('$_baseUrl/callname/sample-template'),
            headers: _headers)
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('샘플 양식 목록 조회 실패: ${resp.statusCode}');
    }
    final data = json.decode(utf8.decode(resp.bodyBytes));
    return ((data['files'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
  }

  /// Sample 양식 업로드 (admin 전용)
  Future<void> uploadSampleTemplate(
      Uint8List bytes, String filename) async {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/callname/sample-template'),
    )
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes('file', bytes,
          filename: filename));
    final streamed = await req.send().timeout(_uploadTimeout);
    final body = await streamed.stream.toBytes();
    if (streamed.statusCode != 200) {
      throw Exception('샘플 양식 업로드 실패: ${utf8.decode(body)}');
    }
  }

  /// Sample 양식 다운로드 URL 조회
  Future<Map<String, dynamic>> getSampleTemplateDownloadUrl(
      String name) async {
    final resp = await http
        .get(
          Uri.parse('$_baseUrl/callname/sample-template/download')
              .replace(queryParameters: {'name': name}),
          headers: _headers,
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('샘플 양식 다운로드 URL 조회 실패: ${resp.statusCode}');
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// Sample 양식 삭제 (admin 전용)
  Future<void> deleteSampleTemplate(String name) async {
    final resp = await http
        .delete(
          Uri.parse('$_baseUrl/callname/sample-template')
              .replace(queryParameters: {'name': name}),
          headers: _headers,
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      throw Exception('샘플 양식 삭제 실패: ${resp.statusCode}');
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
