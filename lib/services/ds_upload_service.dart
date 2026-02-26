import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ds_upload_service_stub.dart'
    if (dart.library.html) 'ds_upload_service_web.dart' as platform_upload;

class DsUploadService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  // HTTP 타임아웃 상수 — 행잉 방지 핵심
  static const _chunkTimeout = Duration(seconds: 60);
  static const _initTimeout = Duration(seconds: 60);
  static const _finalizeTimeout = Duration(seconds: 60);

  /// ZIP 파일(들)을 선택하고 DS 파일을 파싱 + EC2에 청크 업로드
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
    // ── 상태 변수 ──────────────────────────────────────────────────────────
    // uploadInitStarted: await 전에 동기적으로 true 설정 → 병렬 배치 내 중복 방지
    var uploadInitStarted = false;
    var uploadInitDone = false;
    var chunkCount = 0;
    var failedChunks = 0;

    // ── 1단계: JS에서 ZIP 파싱 + 청크 업로드 ──────────────────────────────
    final metaJson = await platform_upload.parseDsForUpload(
      zipBytes: bytes,
      onChunk: (String chunkJson) async {
        // 첫 번째 청크에서만 upload-init 호출
        // uploadInitStarted를 await 전에 동기적으로 설정 (병렬 배치 내 중복 방지 핵심)
        if (!uploadInitStarted) {
          uploadInitStarted = true; // ← await 전 동기 설정 (중요!)
          final chunkData = jsonDecode(chunkJson);
          try {
            final resp = await http.post(
              Uri.parse('$_baseUrl/ds/upload-init'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'divisionId': chunkData['divisionId'],
                'divisionCode': chunkData['divisionCode'] ?? '',
                'importDate': chunkData['importDate'],
                'fileName': fileName,
                'uploadedBy': uploadedBy,
              }),
            ).timeout(_initTimeout);
            uploadInitDone = resp.statusCode == 200;
            debugPrint('upload-init: ${resp.statusCode}');
          } catch (e) {
            debugPrint('upload-init 오류 (계속 진행): $e');
          }
        }

        // 청크 업로드 — 타임아웃 필수 (행잉 방지)
        try {
          final resp = await http.post(
            Uri.parse('$_baseUrl/ds/upload-chunk'),
            headers: {'Content-Type': 'application/json'},
            body: chunkJson,
          ).timeout(_chunkTimeout);
          if (resp.statusCode == 200) {
            chunkCount++;
          } else {
            failedChunks++;
            debugPrint('청크 업로드 실패: ${resp.statusCode}');
          }
        } catch (e) {
          failedChunks++;
          debugPrint('청크 업로드 오류: $e');
        }
      },
      onProgress: onProgress,
    );

    if (metaJson.isEmpty) throw Exception('파싱 결과를 받지 못했습니다.');
    final meta = jsonDecode(metaJson) as Map<String, dynamic>;

    // ── 2단계: S3에 원본 ZIP 업로드 (비치명적, 백그라운드) ─────────────────
    _uploadZipToS3(bytes: bytes, meta: meta).catchError((e) {
      debugPrint('S3 ZIP 업로드 실패 (무시): $e');
    });

    // ── 3단계: upload-init 미완료 시 여기서 재시도 ─────────────────────────
    if (!uploadInitDone) {
      try {
        await http.post(
          Uri.parse('$_baseUrl/ds/upload-init'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'divisionId': meta['divisionId'],
            'divisionCode': meta['divisionCode'] ?? '',
            'importDate': meta['importDate'],
            'fileName': fileName,
            'uploadedBy': uploadedBy,
          }),
        ).timeout(_initTimeout);
        debugPrint('upload-init 재시도 완료');
      } catch (e) {
        debugPrint('upload-init 재시도 오류: $e');
      }
    }

    // ── 4단계: upload-finalize (반드시 xlsx 빌드보다 먼저) ─────────────────
    onProgress('업로드 완료 처리 중...', 97);
    try {
      final resp = await http.post(
        Uri.parse('$_baseUrl/ds/upload-finalize'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'divisionId': meta['divisionId'],
          'divisionCode': meta['divisionCode'] ?? '',
          'importDate': meta['importDate'],
          'sheetStats': meta['sheetStats'],
          'totalRows': meta['totalRows'],
        }),
      ).timeout(_finalizeTimeout);
      debugPrint('upload-finalize: ${resp.statusCode}');
    } catch (e) {
      debugPrint('upload-finalize 실패: $e');
    }

    // ── 5단계: pre-built xlsx 생성 (20만행 이하, fire-and-forget) ──────────
    final totalRows = meta['totalRows'] as int? ?? 0;
    if (totalRows <= 200000) {
      _buildAndUploadXlsx(bytes: bytes, meta: meta, metaJson: metaJson, onProgress: onProgress)
          .catchError((e) => debugPrint('xlsx 빌드 실패 (무시): $e'));
    } else {
      debugPrint('총 ${meta['totalRows']}행 → xlsx 빌드 건너뜀 (ZIP Export 사용)');
    }

    // ── 결과 반환 ──────────────────────────────────────────────────────────
    final divName = meta['divisionName'] ?? meta['divisionId'];
    final date = meta['importDate'] as String? ?? '';
    final formattedDate = date.length == 8
        ? '${date.substring(0, 4)}-${date.substring(4, 6)}-${date.substring(6, 8)}'
        : date;

    return '$divName $formattedDate\n'
        '${(meta['sheetOrder'] as List?)?.length ?? 0}개 시트, ${_formatNumber(totalRows)}행 업로드 완료\n'
        '(청크 $chunkCount개 전송${failedChunks > 0 ? ", 실패 $failedChunks개" : ""})';
  }

  Future<void> _uploadZipToS3({required Uint8List bytes, required Map<String, dynamic> meta}) async {
    final resp = await http.get(Uri.parse(
      '$_baseUrl/ds/upload-presign'
      '?divisionId=${meta['divisionId']}'
      '&divisionCode=${meta['divisionCode']}'
      '&importDate=${meta['importDate']}',
    )).timeout(const Duration(seconds: 30));

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['success'] == true) {
        await http.put(
          Uri.parse(data['url'] as String),
          headers: {'Content-Type': 'application/zip'},
          body: bytes,
        ).timeout(const Duration(minutes: 5));
        debugPrint('S3 원본 ZIP 업로드 완료');
      }
    }
  }

  Future<void> _buildAndUploadXlsx({
    required Uint8List bytes,
    required Map<String, dynamic> meta,
    required String metaJson,
    required void Function(String stage, double percent) onProgress,
  }) async {
    final resp = await http.get(Uri.parse(
      '$_baseUrl/ds/xlsx-upload-presign'
      '?divisionId=${meta['divisionId']}'
      '&divisionCode=${meta['divisionCode']}'
      '&importDate=${meta['importDate']}',
    )).timeout(const Duration(seconds: 30));

    if (resp.statusCode == 200) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      if (data['success'] == true) {
        await platform_upload.buildDsXlsxAndUploadToS3(
          zipBytes: bytes,
          xlsxPutUrl: data['url'] as String,
          metaJson: metaJson,
          onProgress: (stage, percent) => onProgress('xlsx 생성 중: $stage', percent),
        );
        debugPrint('xlsx S3 업로드 완료');
      }
    }
  }

  static String _formatNumber(int num) {
    return num.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]},',
    );
  }
}
