import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// EC2 FastAPI를 통한 S3 사진 저장 서비스
/// S3가 설정되지 않은 경우 base64 data URL을 사용
class PhotoStorageService {
  /// API 서버 URL (EC2 FastAPI)
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  /// S3 Storage가 설정되어 있는지 확인
  static bool _isStorageConfigured = true; // EC2 API 사용 시 항상 true

  static bool get isStorageConfigured => _isStorageConfigured;

  /// Storage 설정 확인 (EC2 API 상태 확인)
  static Future<void> checkStorageConfiguration() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/health'),
      ).timeout(const Duration(seconds: 5));

      _isStorageConfigured = response.statusCode == 200;
      debugPrint('EC2 API Storage 상태: $_isStorageConfigured');
    } catch (e) {
      _isStorageConfigured = false;
      debugPrint('EC2 API 연결 오류: $e');
    }
  }

  /// 사진 업로드 (EC2 경유 S3 또는 base64)
  /// [bytes] - 이미지 바이트 데이터
  /// [fileName] - 파일명 (확장자 포함)
  /// [stationId] - 스테이션 ID (S3 경로용)
  /// [userId] - 사용자 ID (사번, 앱 레벨 격리용)
  /// 반환: S3 키 (s3://...) 또는 base64 data URL
  static Future<String?> uploadPhoto({
    required Uint8List bytes,
    required String fileName,
    required String stationId,
    String? userId,
  }) async {
    // EC2 API가 설정되어 있으면 S3에 업로드
    if (_isStorageConfigured) {
      return await _uploadToS3(bytes, fileName, stationId, userId);
    }

    // EC2 API가 없으면 base64로 인코딩
    return _encodeToBase64(bytes, fileName);
  }

  /// EC2 경유 S3에 업로드
  static Future<String?> _uploadToS3(
    Uint8List bytes,
    String fileName,
    String stationId,
    String? userId,
  ) async {
    try {
      final userPrefix = userId ?? 'unknown';

      // multipart/form-data로 파일 업로드
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/upload/photo'),
      );

      request.fields['owner'] = userPrefix;
      request.fields['stationId'] = stationId;
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: fileName,
        ),
      );

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['success'] == true) {
          final key = data['key'] as String;
          debugPrint('S3 업로드 완료: $key');
          return 's3://$key';
        }
      }

      debugPrint('S3 업로드 실패: ${response.body}');
      // S3 실패 시 base64로 폴백
      return _encodeToBase64(bytes, fileName);
    } catch (e) {
      debugPrint('S3 업로드 오류: $e');
      // S3 실패 시 base64로 폴백
      return _encodeToBase64(bytes, fileName);
    }
  }

  /// base64로 인코딩
  static String _encodeToBase64(Uint8List bytes, String fileName) {
    final base64String = base64Encode(bytes);

    // MIME 타입 추정
    String mimeType = 'image/jpeg';
    final name = fileName.toLowerCase();
    if (name.endsWith('.png')) {
      mimeType = 'image/png';
    } else if (name.endsWith('.gif')) {
      mimeType = 'image/gif';
    } else if (name.endsWith('.webp')) {
      mimeType = 'image/webp';
    }

    return 'data:$mimeType;base64,$base64String';
  }

  /// 사진 URL 가져오기
  /// S3 키인 경우 presigned URL 생성, 그 외에는 그대로 반환
  static Future<String> getPhotoUrl(String photoPath) async {
    // S3 키인 경우
    if (photoPath.startsWith('s3://')) {
      if (!_isStorageConfigured) {
        throw Exception('EC2 API가 설정되지 않았습니다.');
      }

      try {
        final key = photoPath.substring(5); // 's3://' 제거

        final response = await http.get(
          Uri.parse('$_baseUrl/download/presigned?key=${Uri.encodeComponent(key)}'),
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data['success'] == true) {
            return data['url'] as String;
          }
        }

        debugPrint('Presigned URL 생성 실패: ${response.body}');
        throw Exception('사진을 불러올 수 없습니다.');
      } catch (e) {
        debugPrint('S3 URL 생성 오류: $e');
        throw Exception('사진을 불러올 수 없습니다: $e');
      }
    }

    // base64 data URL 또는 일반 URL은 그대로 반환
    return photoPath;
  }

  /// 사진 삭제 (S3인 경우만)
  static Future<void> deletePhoto(String photoPath) async {
    if (!photoPath.startsWith('s3://')) return;
    if (!_isStorageConfigured) return;

    try {
      final key = photoPath.substring(5); // 's3://' 제거

      final response = await http.delete(
        Uri.parse('$_baseUrl/storage/${Uri.encodeComponent(key)}'),
      );

      if (response.statusCode == 200) {
        debugPrint('S3 사진 삭제 완료: $key');
      } else {
        debugPrint('S3 사진 삭제 실패: ${response.body}');
      }
    } catch (e) {
      debugPrint('S3 사진 삭제 오류: $e');
      rethrow;
    }
  }

  /// photoPath가 유효한 URL인지 확인
  static bool isValidPhotoUrl(String photoPath) {
    // base64 data URL
    if (photoPath.startsWith('data:')) return true;

    // S3 키 (나중에 URL로 변환 필요)
    if (photoPath.startsWith('s3://')) return true;

    // HTTP URL
    if (photoPath.startsWith('http://') || photoPath.startsWith('https://')) {
      return true;
    }

    // blob URL은 만료됨
    if (photoPath.startsWith('blob:')) return false;

    // 기타 (로컬 파일 경로 등)
    return !kIsWeb;
  }
}
