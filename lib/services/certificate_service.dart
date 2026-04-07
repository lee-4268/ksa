import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// 설치확인서 생성 서비스 — 개별/일괄 PDF·HWPX 생성
class CertificateService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  static const _apiTimeout = Duration(seconds: 60);
  static const _generateTimeout = Duration(minutes: 3);
  static const _uploadTimeout = Duration(minutes: 5);
  static const _batchTimeout = Duration(minutes: 30);

  String? _authToken;
  void setAuthToken(String? token) => _authToken = token;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${_authToken ?? ''}',
        'Content-Type': 'application/json',
      };

  /// 허가번호/호출명칭 개별 조회
  Future<Map<String, dynamic>> lookup(String query) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/cert/lookup'),
          headers: _headers,
          body: json.encode({'query': query}),
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final msg = _parseError(resp);
      throw Exception(msg);
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 개별 설치확인서 생성 (PDF/HWPX) → 바이너리 반환
  Future<Uint8List> generate({
    required Map<String, dynamic> formData,
    required String format,
    List<String>? photosBase64,
    String? blueprintBase64,
  }) async {
    final body = {
      'form_data': formData,
      'format': format,
      if (photosBase64 != null && photosBase64.isNotEmpty)
        'photos': photosBase64,
      if (blueprintBase64 != null) 'blueprint': blueprintBase64,
    };

    final req = http.Request(
      'POST',
      Uri.parse('$_baseUrl/cert/generate'),
    );
    req.headers['Authorization'] = 'Bearer ${_authToken ?? ''}';
    req.headers['Content-Type'] = 'application/json';
    req.body = json.encode(body);

    final client = http.Client();
    try {
      final streamed = await client.send(req).timeout(_generateTimeout);
      if (streamed.statusCode != 200) {
        final respBytes = await streamed.stream.toBytes();
        final msg = utf8.decode(respBytes);
        throw Exception('생성 실패: $msg');
      }
      return await streamed.stream.toBytes();
    } finally {
      client.close();
    }
  }

  /// 허가번호 목록 일괄 조회 (최대 500건)
  Future<Map<String, dynamic>> batchLookup(List<String> zpwinoList) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/cert/batch/lookup'),
          headers: _headers,
          body: json.encode({'zpwino_list': zpwinoList}),
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final msg = _parseError(resp);
      throw Exception(msg);
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// 사진 ZIP 파일 업로드 → 허가번호별 자동 매칭
  Future<Map<String, dynamic>> uploadPhotos(
      Uint8List zipBytes, String filename) async {
    final req = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/cert/batch/upload-photos'),
    )
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(
          http.MultipartFile.fromBytes('file', zipBytes, filename: filename));

    final streamed = await req.send().timeout(_uploadTimeout);
    final respBytes = await streamed.stream.toBytes();
    if (streamed.statusCode != 200) {
      throw Exception('사진 업로드 실패: ${utf8.decode(respBytes)}');
    }
    return json.decode(utf8.decode(respBytes)) as Map<String, dynamic>;
  }

  /// 일괄 설치확인서 생성 (SSE 스트리밍)
  Stream<Map<String, dynamic>> batchGenerate({
    required List<Map<String, dynamic>> items,
    required Map<String, dynamic> common,
    String? photoJobId,
  }) async* {
    final body = {
      'items': items,
      'common': common,
      if (photoJobId != null) 'photo_job_id': photoJobId,
    };

    final uri = Uri.parse('$_baseUrl/cert/batch/generate');
    final req = http.Request('POST', uri);
    req.headers['Authorization'] = 'Bearer ${_authToken ?? ''}';
    req.headers['Content-Type'] = 'application/json';
    req.headers['Accept'] = 'text/event-stream';
    req.body = json.encode(body);

    final client = http.Client();
    try {
      final streamed = await client.send(req).timeout(_batchTimeout);
      if (streamed.statusCode != 200) {
        final respBytes = await streamed.stream.toBytes();
        throw Exception('일괄 생성 실패: ${utf8.decode(respBytes)}');
      }

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

  /// 일괄 생성 결과 다운로드 URL 조회
  Future<Map<String, dynamic>> getDownloadUrl(String jobId) async {
    final resp = await http
        .get(
          Uri.parse('$_baseUrl/cert/batch/download/$jobId'),
          headers: _headers,
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final msg = _parseError(resp);
      throw Exception(msg);
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  /// ACTA 로그인 → accessToken 반환
  Future<String> actaLogin(String userId, String cUserPwd) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/acta/login'),
          headers: _headers,
          body: json.encode({'userId': userId, 'cUserPwd': cUserPwd}),
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final msg = _parseError(resp);
      throw Exception(msg);
    }
    final data = json.decode(utf8.decode(resp.bodyBytes));
    return data['accessToken'] as String;
  }

  /// 허가번호 + ACTA 토큰 → atfl_uuid 조회
  Future<Map<String, dynamic>> actaDrawing(String zpwino, String actaToken) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/acta/drawing'),
          headers: _headers,
          body: json.encode({'zpwino': zpwino, 'actaToken': actaToken}),
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final msg = _parseError(resp);
      throw Exception(msg);
    }
    return json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }

  String _parseError(http.Response resp) {
    try {
      final body = json.decode(utf8.decode(resp.bodyBytes));
      return body['detail'] ?? '오류: ${resp.statusCode}';
    } catch (_) {
      return '오류: ${resp.statusCode}';
    }
  }
}
