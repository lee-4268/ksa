import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// DS 업로드 서비스 — Upload-Zero-Build (EC2 경유 S3 업로드 + 메타데이터 파싱)
///
/// 흐름:
///   1. ZIP → POST /ds/upload-raw (EC2 스트리밍 → S3, CORS 불필요)
///   2. POST /ds/enqueue → jobId 수신
///   3. GET /ds/job/{jobId} 폴링 (3초 간격) → 서버 진행률 표시
///   4. 서버가 메타데이터만 파싱 → ZIP을 S3에 그대로 보관 (~10초)
class DsUploadService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  static const _s3Timeout = Duration(minutes: 10);    // 대용량 ZIP S3 업로드
  static const _apiTimeout = Duration(seconds: 30);   // API 호출
  static const _pollInterval = Duration(seconds: 3);  // 폴링 간격
  static const _maxPollDuration = Duration(minutes: 3);  // 최대 대기 시간 (Upload-Zero-Build)

  String? _authToken;
  void setAuthToken(String? token) => _authToken = token;

  // DS 지역코드 → 본부명 (서버 DS_REGION_CODE_MAP과 동일)
  static const _divisionNames = {
    '10': '수도권',
    '20': '경남본부',
    '30': '서부본부',
    '40': '강원본부',
    '50': '충청본부',
    '55': '충청본부',
    '60': '경북본부',
    '70': '서부본부',
  };

  /// ZIP 파일(들) 선택 → S3 업로드 → 서버 처리 → 완료 메시지 반환
  Future<String> pickAndUpload({
    required String uploadedBy,
    required void Function(String stage, double percent) onProgress,
  }) async {
    onProgress('파일 선택 중...', 0);

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withData: true,
      allowMultiple: true,
    );

    if (result == null || result.files.isEmpty) {
      throw Exception('파일이 선택되지 않았습니다.');
    }

    final files = result.files.where((f) => f.bytes != null).toList();
    if (files.isEmpty) throw Exception('파일을 읽을 수 없습니다.');

    debugPrint('선택된 파일 수: ${files.length}');

    final results = <String>[];
    final isMulti = files.length > 1;

    for (var i = 0; i < files.length; i++) {
      final file = files[i];
      final bytes = file.bytes!;
      final prefix = isMulti ? '[${i + 1}/${files.length}] ' : '';

      if (isMulti) {
        try {
          final msg = await _uploadSingleFile(
            bytes: bytes,
            fileName: file.name,
            uploadedBy: uploadedBy,
            onProgress: (stage, percent) {
              final base = (i / files.length) * 100;
              onProgress('$prefix$stage', base + percent / files.length);
            },
          );
          results.add('✓ ${file.name}\n$msg');
        } catch (e) {
          results.add('✗ ${file.name}: ${e.toString().replaceFirst('Exception: ', '')}');
        }
      } else {
        final msg = await _uploadSingleFile(
          bytes: bytes,
          fileName: file.name,
          uploadedBy: uploadedBy,
          onProgress: onProgress,
        );
        results.add(msg);
      }
    }

    return results.join('\n\n─────────────────\n\n');
  }

  Future<String> _uploadSingleFile({
    required Uint8List bytes,
    required String fileName,
    required String uploadedBy,
    required void Function(String stage, double percent) onProgress,
  }) async {
    // ── 1단계: ZIP → EC2 경유 S3 업로드 (/ds/upload-raw) ──────────────────
    // S3 CORS 설정 없이도 동작 (EC2가 스트리밍으로 S3에 저장)
    onProgress('ZIP 업로드 중...', 5);

    final uploadReq = http.MultipartRequest(
      'POST',
      Uri.parse('$_baseUrl/ds/upload-raw'),
    )
      ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        bytes,
        filename: fileName,
      ));
    if (_authToken != null) {
      uploadReq.headers['Authorization'] = 'Bearer $_authToken';
    }

    final uploadStreamedResp = await uploadReq.send().timeout(_s3Timeout);
    final uploadResp = await http.Response.fromStream(uploadStreamedResp);

    if (uploadResp.statusCode != 200) {
      throw Exception('ZIP 업로드 실패 (${uploadResp.statusCode}): ${uploadResp.body}');
    }

    final uploadData = jsonDecode(uploadResp.body) as Map<String, dynamic>;
    if (uploadData['success'] != true) {
      throw Exception('ZIP 업로드 실패: ${uploadData['detail'] ?? uploadData['message']}');
    }

    final s3Key = uploadData['s3Key'] as String;
    debugPrint('ZIP EC2→S3 업로드 완료: $s3Key (${bytes.length ~/ 1024}KB)');

    // ── 2단계: 서버에 처리 요청 (enqueue) ───────────────────────────────
    onProgress('서버 처리 요청 중...', 20);

    final enqueueResp = await http.post(
      Uri.parse('$_baseUrl/ds/enqueue'),
      headers: {
        'Content-Type': 'application/json',
        if (_authToken != null) 'Authorization': 'Bearer $_authToken',
      },
      body: jsonEncode({
        's3Key': s3Key,
        'fileName': fileName,
        'uploadedBy': uploadedBy,
      }),
    ).timeout(_apiTimeout);

    if (enqueueResp.statusCode != 200) {
      throw Exception('서버 처리 요청 실패 (${enqueueResp.statusCode}): ${enqueueResp.body}');
    }

    final enqueueData = jsonDecode(enqueueResp.body) as Map<String, dynamic>;
    if (enqueueData['success'] != true) {
      throw Exception('서버 처리 요청 실패: ${enqueueData['detail'] ?? enqueueData['message']}');
    }

    final jobId = enqueueData['jobId'] as String;
    final queuePos = enqueueData['queuePosition'] as int? ?? 1;

    debugPrint('DS 잡 enqueued: $jobId (큐 위치: $queuePos)');

    // ── 4단계: 서버 처리 완료까지 폴링 (3초 간격) ──────────────────────
    if (queuePos > 1) {
      onProgress('서버 대기 중... ($queuePos번째)', 22);
    } else {
      onProgress('서버 처리 시작 중...', 22);
    }

    final deadline = DateTime.now().add(_maxPollDuration);

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(_pollInterval);

      try {
        final jobResp = await http.get(
          Uri.parse('$_baseUrl/ds/job/$jobId'),
          headers: {
            if (_authToken != null) 'Authorization': 'Bearer $_authToken',
          },
        ).timeout(_apiTimeout);

        if (jobResp.statusCode != 200) {
          debugPrint('폴링 HTTP 오류: ${jobResp.statusCode}, 재시도...');
          continue;
        }

        final jobData = jsonDecode(jobResp.body) as Map<String, dynamic>;
        final job = jobData['job'] as Map<String, dynamic>? ?? {};
        final status = job['status'] as String? ?? 'queued';
        final stage = job['stage'] as String? ?? '처리 중...';
        final serverPercent = (job['percent'] as num?)?.toDouble() ?? 0;
        final queuePosition = job['queuePosition'] as int?;

        // 진행률: S3 업로드 20% + 서버처리 80%
        final displayPercent = 20.0 + (serverPercent / 100.0) * 80.0;
        final displayStage = (queuePosition != null && queuePosition > 1)
            ? '$stage (대기 $queuePosition번째)'
            : stage;
        onProgress(displayStage, displayPercent);

        if (status == 'completed') {
          // 완료
          final divisionCode = job['divisionCode'] as String? ?? '';
          final importDate = job['importDate'] as String? ?? '';
          final totalRows = job['totalRows'] as int? ?? 0;
          final sheetStats = job['sheetStats'] as Map<String, dynamic>? ?? {};
          final divName = _divisionNames[divisionCode] ?? job['divisionId'] ?? '';
          final formattedDate = importDate.length == 8
              ? '${importDate.substring(0, 4)}-${importDate.substring(4, 6)}-${importDate.substring(6, 8)}'
              : importDate;

          return '$divName $formattedDate\n'
              '${sheetStats.length}개 시트, ${_formatNumber(totalRows)}행 업로드 완료';
        }

        if (status == 'failed') {
          final error = job['error'] as String? ?? '알 수 없는 오류';
          throw Exception('서버 처리 실패: $error');
        }
      } catch (e) {
        // 서버 처리 실패는 rethrow, 네트워크 오류는 재시도
        if (e is Exception && e.toString().contains('서버 처리 실패')) {
          rethrow;
        }
        debugPrint('폴링 오류 (재시도): $e');
      }
    }

    throw Exception('서버 처리 타임아웃 (${_maxPollDuration.inMinutes}분 초과).\n'
        '처리가 계속 진행 중일 수 있으니 잠시 후 새로고침하세요.');
  }

  static String _formatNumber(int num) {
    return num.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]},',
    );
  }
}
