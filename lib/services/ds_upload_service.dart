import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// 조건부 import - 플랫폼별 DS 파싱
import 'ds_upload_service_stub.dart'
    if (dart.library.html) 'ds_upload_service_web.dart' as platform_upload;

class DsUploadService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  /// ZIP 파일을 선택하고 DS 파일을 파싱 + EC2에 청크 업로드
  Future<String> pickAndUpload({
    required String uploadedBy,
    required void Function(String stage, double percent) onProgress,
  }) async {
    onProgress('파일 선택 중...', 0);

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      withData: true,
    );

    if (result == null || result.files.isEmpty) {
      throw Exception('파일이 선택되지 않았습니다.');
    }

    final file = result.files.first;
    final Uint8List? bytes = file.bytes;

    if (bytes == null) {
      throw Exception('파일을 읽을 수 없습니다.');
    }

    debugPrint('ZIP 파일 선택됨: ${file.name} (${bytes.length} bytes)');

    String metaJson;
    var uploadInitDone = false;
    String? divisionId;
    String? importDate;
    var chunkCount = 0;
    var failedChunks = 0;

    // JS에서 파싱 → 청크마다 EC2로 POST
    metaJson = await platform_upload.parseDsForUpload(
      zipBytes: bytes,
      onChunk: (String chunkJson) async {
        // 첫 번째 청크에서 upload-init 호출
        if (!uploadInitDone) {
          final chunkData = jsonDecode(chunkJson);
          divisionId = chunkData['divisionId'];
          importDate = chunkData['importDate'];

          try {
            final initResponse = await http.post(
              Uri.parse('$_baseUrl/ds/upload-init'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'divisionId': divisionId,
                'divisionCode': chunkData['divisionCode'] ?? '',
                'importDate': importDate,
                'fileName': '',
                'uploadedBy': uploadedBy,
              }),
            );
            if (initResponse.statusCode == 200) {
              uploadInitDone = true;
              debugPrint('DS upload-init 성공');
            }
          } catch (e) {
            debugPrint('DS upload-init 실패: $e');
          }
        }

        // 청크 데이터 EC2로 전송
        try {
          final response = await http.post(
            Uri.parse('$_baseUrl/ds/upload-chunk'),
            headers: {'Content-Type': 'application/json'},
            body: chunkJson,
          );
          if (response.statusCode == 200) {
            chunkCount++;
          } else {
            failedChunks++;
            debugPrint('청크 업로드 실패: ${response.statusCode}');
          }
        } catch (e) {
          failedChunks++;
          debugPrint('청크 업로드 오류: $e');
        }
      },
      onProgress: onProgress,
    );

    // ─────────────────────────────────────────────────────────
    // 1단계: S3에 원본 ZIP 업로드 (Export 고속화용)
    // ─────────────────────────────────────────────────────────
    try {
      final tempMeta = metaJson.isNotEmpty ? jsonDecode(metaJson) : null;
      if (tempMeta != null) {
        final presignResp = await http.get(Uri.parse(
          '$_baseUrl/ds/upload-presign?divisionId=${tempMeta['divisionId']}'
          '&divisionCode=${tempMeta['divisionCode']}'
          '&importDate=${tempMeta['importDate']}',
        ));
        if (presignResp.statusCode == 200) {
          final presignData = jsonDecode(presignResp.body);
          if (presignData['success'] == true) {
            final s3Url = presignData['url'] as String;
            await http.put(
              Uri.parse(s3Url),
              headers: {'Content-Type': 'application/zip'},
              body: bytes,
            );
            debugPrint('S3 원본 ZIP 업로드 완료');
          }
        }
      }
    } catch (e) {
      debugPrint('S3 ZIP 업로드 실패 (비치명적): $e');
    }

    // ─────────────────────────────────────────────────────────
    // 2단계: upload-finalize 호출 (xlsx 빌드보다 반드시 먼저!)
    // buildDsXlsxAndUploadToS3가 대용량 파일에서 브라우저 OOM으로
    // 탭을 죽이기 때문에, finalize를 먼저 호출해야 status가
    // "completed"로 갱신됨. xlsx 빌드 실패해도 데이터는 안전.
    // ─────────────────────────────────────────────────────────
    if (metaJson.isNotEmpty) {
      final meta = jsonDecode(metaJson);

      // upload-init이 아직 안됐으면 여기서 처리
      if (!uploadInitDone) {
        await http.post(
          Uri.parse('$_baseUrl/ds/upload-init'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'divisionId': meta['divisionId'],
            'divisionCode': meta['divisionCode'],
            'importDate': meta['importDate'],
            'fileName': meta['fileName'] ?? '',
            'uploadedBy': uploadedBy,
          }),
        );
      }

      onProgress('업로드 완료 처리 중...', 97);
      try {
        await http.post(
          Uri.parse('$_baseUrl/ds/upload-finalize'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'divisionId': meta['divisionId'],
            'divisionCode': meta['divisionCode'] ?? '',
            'importDate': meta['importDate'],
            'sheetStats': meta['sheetStats'],
            'totalRows': meta['totalRows'],
          }),
        );
        debugPrint('DS upload-finalize 성공');
      } catch (e) {
        debugPrint('DS upload-finalize 실패: $e');
      }

      // ─────────────────────────────────────────────────────
      // 3단계: pre-built xlsx 생성 (소규모 파일만, 비동기)
      // 20만행 초과 시 건너뜀: 대용량 파일은 브라우저 메모리 부족
      // (OOM)으로 탭이 죽을 수 있음. ZIP 기반 Export로 폴백.
      // ─────────────────────────────────────────────────────
      final totalRowsForXlsx = meta['totalRows'] as int? ?? 0;
      if (totalRowsForXlsx <= 200000) {
        try {
          final xlsxPresignResp = await http.get(Uri.parse(
            '$_baseUrl/ds/xlsx-upload-presign?divisionId=${meta['divisionId']}'
            '&divisionCode=${meta['divisionCode']}'
            '&importDate=${meta['importDate']}',
          ));
          if (xlsxPresignResp.statusCode == 200) {
            final xlsxPresignData = jsonDecode(xlsxPresignResp.body);
            if (xlsxPresignData['success'] == true) {
              final xlsxPutUrl = xlsxPresignData['url'] as String;
              // 비동기 fire-and-forget: finalize 이미 완료됐으므로
              // xlsx 빌드 실패해도 업로드 성공에 영향 없음
              platform_upload.buildDsXlsxAndUploadToS3(
                zipBytes: bytes,
                xlsxPutUrl: xlsxPutUrl,
                metaJson: metaJson,
                onProgress: (stage, percent) {
                  onProgress('xlsx 생성 중: $stage', percent);
                },
              ).catchError((e) {
                debugPrint('xlsx 빌드 실패 (무시): $e');
              });
            }
          }
        } catch (e) {
          debugPrint('xlsx presign 실패 (비치명적): $e');
        }
      } else {
        debugPrint('총 $totalRowsForXlsx행 → xlsx 빌드 건너뜀 (ZIP Export 사용)');
      }

      final divName = meta['divisionName'] ?? meta['divisionId'];
      final date = meta['importDate'] ?? '';
      final total = meta['totalRows'] ?? 0;
      final formattedDate =
          date.length == 8 ? '${date.substring(0, 4)}-${date.substring(4, 6)}-${date.substring(6, 8)}' : date;

      return '$divName $formattedDate\n'
          '${meta['sheetOrder']?.length ?? 0}개 시트, ${_formatNumber(total)}행 업로드 완료\n'
          '(청크 $chunkCount개 전송${failedChunks > 0 ? ", 실패 $failedChunks개" : ""})';
    }

    throw Exception('파싱 결과를 받지 못했습니다.');
  }

  static String _formatNumber(dynamic num) {
    if (num == null) return '0';
    final n = num is int ? num : int.tryParse(num.toString()) ?? 0;
    return n.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]},',
    );
  }
}
