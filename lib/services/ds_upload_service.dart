import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// 웹 전용 파일 선택 (file_picker focus 버그 우회)
import 'file_picker_stub.dart'
    if (dart.library.html) 'file_picker_web.dart' as web_picker;

/// DS 업로드 서비스 — Upload-Zero-Build (EC2 경유 S3 업로드 + 메타데이터 파싱)
///
/// 흐름 (단일 ZIP):
///   1. ZIP → POST /ds/upload-raw (EC2 스트리밍 → S3)
///   2. POST /ds/enqueue → jobId
///   3. GET /ds/job/{jobId} 폴링 → 완료
///
/// 흐름 (복수 ZIP — 같은 지역코드):
///   1. 지역코드별 그룹핑
///   2. 각 ZIP → POST /ds/upload-raw → s3Key 수집
///   3. POST /ds/enqueue-multi (s3Keys 배열) → jobId
///   4. GET /ds/job/{jobId} 폴링 → 서버 병합+처리 → 완료
class DsUploadService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  static const _s3Timeout = Duration(minutes: 10);    // 대용량 ZIP S3 업로드
  static const _apiTimeout = Duration(seconds: 30);   // API 호출
  static const _pollInterval = Duration(seconds: 3);  // 폴링 간격
  static const _maxPollDuration = Duration(minutes: 3);       // 단일 ZIP
  static const _maxPollDurationMulti = Duration(minutes: 10); // 복수 ZIP 병합

  String? _authToken;
  void Function(String newToken)? onTokenRefreshed;
  void setAuthToken(String? token) => _authToken = token;

  /// 현재 폴링 중인 jobId (취소용)
  String? _currentJobId;
  String? get currentJobId => _currentJobId;

  /// 업로드 잡 취소
  Future<void> cancelCurrentJob() async {
    final jobId = _currentJobId;
    if (jobId == null) return;
    try {
      await http.delete(
        Uri.parse('$_baseUrl/ds/job/$jobId'),
        headers: {
          if (_authToken != null) 'Authorization': 'Bearer $_authToken',
        },
      ).timeout(_apiTimeout);
    } catch (e) {
      debugPrint('잡 취소 실패: $e');
    }
  }

  // DS 지역코드 → 본부명 (서버 DS_REGION_CODE_MAP과 동일)
  static const _divisionNames = {
    '10': '수도권',
    '20': '경남본부',
    '30': '서부본부',
    '40': '강원본부',
    '50': '충청본부',
    '60': '경북본부',
  };

  /// 유효 지역코드
  static const _validRegionCodes = {'10', '20', '26', '30', '40', '50', '55', '60', '70', '80'};

  /// 같은 본부로 병합되는 코드 (70→30 서부, 55→50 충청, 26→20 경남, 80→30 서부)
  static const _mergedCodes = {'70': '30', '55': '50', '26': '20', '80': '30'};

  /// 병합 코드 표시용: 대표코드 → "30+70+80" 형태
  static const _mergedCodeDisplay = {'30': '30+70+80', '50': '50+55', '20': '20+26'};

  /// ZIP 파일명에서 지역코드 추출 + 병합 코드 정규화
  /// "SKT(70)20260303.zip" → "30" (서부본부로 병합)
  static String? _parseDivisionCode(String fileName) {
    final match = RegExp(r'\((\d+)\)').firstMatch(fileName);
    if (match == null) return null;
    final code = match.group(1)!;
    if (!_validRegionCodes.contains(code)) return null;
    return _mergedCodes[code] ?? code; // 70→30, 55→50
  }

  /// 파일 목록을 지역코드별로 그룹핑 (미사용 코드 필터링)
  static Map<String, List<web_picker.PickedFile>> _groupByRegion(List<web_picker.PickedFile> files) {
    final groups = <String, List<web_picker.PickedFile>>{};
    for (final file in files) {
      final code = _parseDivisionCode(file.name);
      if (code == null) continue;
      groups.putIfAbsent(code, () => []).add(file);
    }
    return groups;
  }

  /// ZIP 파일(들) 선택 → 지역코드별 그룹핑 → S3 업로드 → 서버 처리 → 완료 메시지
  Future<String> pickAndUpload({
    required String uploadedBy,
    required void Function(String stage, double percent) onProgress,
  }) async {
    onProgress('파일 선택 중...', 0);

    final picked = await web_picker.pickFilesWeb(
      accept: '.zip',
      multiple: true,
    );

    if (picked == null || picked.isEmpty) {
      throw Exception('파일이 선택되지 않았습니다.');
    }

    final files = picked;
    debugPrint('선택된 파일 수: ${files.length}');

    // 지역코드별 그룹핑
    final groups = _groupByRegion(files);
    if (groups.isEmpty) {
      throw Exception('유효한 지역코드를 가진 파일이 없습니다.\n'
          '파일명에 (10), (20) 등 지역코드가 포함되어야 합니다.');
    }

    // 건너뛴 파일 목록
    final skippedFiles = files.where((f) => _parseDivisionCode(f.name) == null).toList();
    if (skippedFiles.isNotEmpty) {
      debugPrint('건너뛴 파일 (알 수 없는 지역코드): ${skippedFiles.map((f) => f.name).join(', ')}');
    }

    final results = <String>[];
    final groupEntries = groups.entries.toList();
    final totalGroups = groupEntries.length;

    for (var gi = 0; gi < totalGroups; gi++) {
      final entry = groupEntries[gi];
      final code = entry.key;
      final regionFiles = entry.value;
      final divisionName = _divisionNames[code] ?? '지역$code';
      final groupPrefix = totalGroups > 1 ? '[$divisionName] ' : '';

      try {
        if (regionFiles.length == 1) {
          // 단일 파일: 기존 flow
          final msg = await _uploadSingleFile(
            file: regionFiles.first,
            uploadedBy: uploadedBy,
            onProgress: (stage, percent) {
              final base = (gi / totalGroups) * 100;
              onProgress('$groupPrefix$stage', base + percent / totalGroups);
            },
          );
          results.add('$divisionName: $msg');
        } else {
          // 복수 파일: 병합 업로드
          final msg = await _uploadMultiFiles(
            files: regionFiles,
            uploadedBy: uploadedBy,
            onProgress: (stage, percent) {
              final base = (gi / totalGroups) * 100;
              onProgress('$groupPrefix$stage', base + percent / totalGroups);
            },
          );
          results.add('$divisionName: $msg');
        }
      } catch (e) {
        results.add('$divisionName: ${e.toString().replaceFirst('Exception: ', '')}');
      }
    }

    // 건너뛴 파일 안내
    if (skippedFiles.isNotEmpty) {
      results.add('건너뛴 파일 (${skippedFiles.length}개): '
          '${skippedFiles.map((f) => f.name).join(', ')}');
    }

    return results.join('\n\n─────────────────\n\n');
  }

  /// 단일 ZIP 업로드 (기존 flow — 변경 없음)
  Future<String> _uploadSingleFile({
    required web_picker.PickedFile file,
    required String uploadedBy,
    required void Function(String stage, double percent) onProgress,
  }) async {
    // ── 1단계: ZIP → EC2 경유 S3 업로드 ──
    onProgress('ZIP 업로드 중... 0%', 5);

    final s3Key = await _uploadToS3(file, onProgress: (p) {
      onProgress('ZIP 업로드 중... ${(p * 100).toInt()}%', 5 + p * 15);
    });

    // ── 2단계: 서버에 처리 요청 (enqueue) ──
    onProgress('서버 처리 요청 중...', 20);

    final enqueueResp = await http.post(
      Uri.parse('$_baseUrl/ds/enqueue'),
      headers: {
        'Content-Type': 'application/json',
        if (_authToken != null) 'Authorization': 'Bearer $_authToken',
      },
      body: jsonEncode({
        's3Key': s3Key,
        'fileName': file.name,
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

    // ── 3단계: 폴링 ──
    return _pollJob(jobId, queuePos, onProgress, _maxPollDuration, 20.0, 80.0);
  }

  /// 복수 ZIP 병합 업로드
  Future<String> _uploadMultiFiles({
    required List<web_picker.PickedFile> files,
    required String uploadedBy,
    required void Function(String stage, double percent) onProgress,
  }) async {
    final totalFiles = files.length;
    final tempIds = <String>[];
    final fileNames = <String>[];

    // Phase 1: 모든 ZIP → EC2 디스크 직접 업로드 (0~50%), 5개씩 병렬
    const batchSize = 3;
    final uploadedPercents = List<double>.filled(totalFiles, 0.0);
    final tempIdResults = List<String>.filled(totalFiles, '');
    fileNames.addAll(files.map((f) => f.name));

    for (var batchStart = 0; batchStart < totalFiles; batchStart += batchSize) {
      final batchEnd = (batchStart + batchSize).clamp(0, totalFiles);
      final batch = List.generate(batchEnd - batchStart, (j) {
        final i = batchStart + j;
        final file = files[i];
        return _uploadToTemp(file, onProgress: (p) {
          uploadedPercents[i] = p;
          final totalPercent = uploadedPercents.fold(0.0, (a, b) => a + b) / totalFiles * 50;
          onProgress(
            'ZIP 업로드 중 ($batchEnd/$totalFiles) ${(totalPercent * 2).toInt()}%',
            totalPercent,
          );
        }).then((tempId) => tempIdResults[i] = tempId);
      });
      await Future.wait(batch);
    }
    tempIds.addAll(tempIdResults);

    // Phase 2: 병합 잡 생성 (50~55%)
    onProgress('서버 병합 요청 중... ($totalFiles개 파일)', 52);

    final enqueueResp = await http.post(
      Uri.parse('$_baseUrl/ds/enqueue-multi'),
      headers: {
        'Content-Type': 'application/json',
        if (_authToken != null) 'Authorization': 'Bearer $_authToken',
      },
      body: jsonEncode({
        'tempIds': tempIds,
        'fileNames': fileNames,
        'uploadedBy': uploadedBy,
      }),
    ).timeout(_apiTimeout);

    if (enqueueResp.statusCode != 200) {
      throw Exception('서버 병합 요청 실패 (${enqueueResp.statusCode}): ${enqueueResp.body}');
    }

    final enqueueData = jsonDecode(enqueueResp.body) as Map<String, dynamic>;
    if (enqueueData['success'] != true) {
      throw Exception('서버 병합 요청 실패: ${enqueueData['detail'] ?? enqueueData['message']}');
    }

    final jobId = enqueueData['jobId'] as String;
    final queuePos = enqueueData['queuePosition'] as int? ?? 1;
    debugPrint('DS multi-job enqueued: $jobId ($totalFiles개 ZIP, 큐 위치: $queuePos)');

    // Phase 3: 폴링 (55~100%, 타임아웃 10분)
    final resultMsg = await _pollJob(
      jobId, queuePos, onProgress, _maxPollDurationMulti, 55.0, 45.0,
    );

    return '$resultMsg\n$totalFiles개 ZIP 병합';
  }

  /// ZIP 파일을 S3에 업로드하고 s3Key 반환 (XHR 스트리밍 — 진행률 포함)
  Future<String> _uploadToS3(
    web_picker.PickedFile file, {
    void Function(double progress)? onProgress,
  }) async {
    final htmlFile = file.htmlFile;
    String respBody;
    if (htmlFile != null) {
      respBody = await web_picker.uploadFileXhr(
        url: '$_baseUrl/ds/upload-raw',
        file: htmlFile,
        fieldName: 'file',
        headers: {if (_authToken != null) 'Authorization': 'Bearer $_authToken'},
        onProgress: onProgress,
      );
    } else {
      // fallback: bytes 방식 (stub 환경)
      final bytes = await file.bytes;
      final uploadReq = http.MultipartRequest('POST', Uri.parse('$_baseUrl/ds/upload-raw'))
        ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
        ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: file.name));
      final streamedResp = await uploadReq.send().timeout(_s3Timeout);
      respBody = await http.Response.fromStream(streamedResp).then((r) => r.body);
    }

    final data = jsonDecode(respBody) as Map<String, dynamic>;
    if (data['success'] != true) {
      throw Exception('ZIP 업로드 실패: ${data['detail'] ?? data['message']}');
    }
    debugPrint('ZIP EC2→S3 업로드 완료: ${data['s3Key']} (${file.size ~/ 1024}KB)');
    return data['s3Key'] as String;
  }

  /// ZIP 파일을 EC2 디스크에 직접 업로드하고 tempId 반환 (병합용, XHR 스트리밍)
  Future<String> _uploadToTemp(
    web_picker.PickedFile file, {
    void Function(double progress)? onProgress,
  }) async {
    final htmlFile = file.htmlFile;
    String respBody;
    if (htmlFile != null) {
      respBody = await web_picker.uploadFileXhr(
        url: '$_baseUrl/ds/upload-temp',
        file: htmlFile,
        fieldName: 'file',
        headers: {if (_authToken != null) 'Authorization': 'Bearer $_authToken'},
        onProgress: onProgress,
      );
    } else {
      final bytes = await file.bytes;
      final uploadReq = http.MultipartRequest('POST', Uri.parse('$_baseUrl/ds/upload-temp'))
        ..headers['Authorization'] = 'Bearer ${_authToken ?? ''}'
        ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: file.name));
      final streamedResp = await uploadReq.send().timeout(_s3Timeout);
      respBody = await http.Response.fromStream(streamedResp).then((r) => r.body);
    }

    final data = jsonDecode(respBody) as Map<String, dynamic>;
    if (data['success'] != true) {
      throw Exception('ZIP 업로드 실패: ${data['detail'] ?? data['message']}');
    }
    debugPrint('ZIP EC2 직접 업로드 완료: ${data['tempId']} (${file.size ~/ 1024}KB)');
    return data['tempId'] as String;
  }

  /// 잡 상태 폴링 → 완료 메시지 반환
  Future<String> _pollJob(
    String jobId,
    int queuePos,
    void Function(String stage, double percent) onProgress,
    Duration timeout,
    double basePercent,
    double percentRange,
  ) async {
    _currentJobId = jobId;

    if (queuePos > 1) {
      onProgress('서버 대기 중... ($queuePos번째)', basePercent);
    } else {
      onProgress('서버 처리 시작 중...', basePercent);
    }

    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(_pollInterval);

      try {
        final jobResp = await http.get(
          Uri.parse('$_baseUrl/ds/job/$jobId'),
          headers: {
            if (_authToken != null) 'Authorization': 'Bearer $_authToken',
          },
        ).timeout(_apiTimeout);

        // 토큰 자동 갱신 체크
        final refreshedToken = jobResp.headers['x-refreshed-token'];
        if (refreshedToken != null && refreshedToken.isNotEmpty) {
          _authToken = refreshedToken;
          onTokenRefreshed?.call(refreshedToken);
        }

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

        final displayPercent = basePercent + (serverPercent / 100.0) * percentRange;
        final displayStage = (queuePosition != null && queuePosition > 1)
            ? '$stage (대기 $queuePosition번째)'
            : stage;
        onProgress(displayStage, displayPercent);

        if (status == 'cancelled') {
          _currentJobId = null;
          throw Exception('업로드가 취소되었습니다.');
        }

        if (status == 'completed') {
          _currentJobId = null;
          final divisionCode = job['divisionCode'] as String? ?? '';
          final importDate = job['importDate'] as String? ?? '';
          final totalRows = job['totalRows'] as int? ?? 0;
          final sheetStats = job['sheetStats'] as Map<String, dynamic>? ?? {};
          final divName = _divisionNames[divisionCode] ?? job['divisionId'] ?? '';
          final codeDisplay = _mergedCodeDisplay[divisionCode] ?? divisionCode;
          final formattedDate = importDate.length == 8
              ? '${importDate.substring(0, 4)}-${importDate.substring(4, 6)}-${importDate.substring(6, 8)}'
              : importDate;

          return '$divName (코드: $codeDisplay) $formattedDate\n'
              '${sheetStats.length}개 시트, ${_formatNumber(totalRows)}행 업로드 완료';
        }

        if (status == 'failed') {
          _currentJobId = null;
          final error = job['error'] as String? ?? '알 수 없는 오류';
          throw Exception('서버 처리 실패: $error');
        }
      } catch (e) {
        if (e is Exception && e.toString().contains('서버 처리 실패')) {
          rethrow;
        }
        debugPrint('폴링 오류 (재시도): $e');
      }
    }

    throw Exception('서버 처리 타임아웃 (${timeout.inMinutes}분 초과).\n'
        '처리가 계속 진행 중일 수 있으니 잠시 후 새로고침하세요.');
  }

  static String _formatNumber(int num) {
    return num.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]},',
    );
  }
}
