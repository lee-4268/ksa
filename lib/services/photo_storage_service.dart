import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:amplify_storage_s3/amplify_storage_s3.dart';

/// AWS S3를 이용한 사진 저장 서비스
/// S3가 설정되지 않은 경우 base64 data URL을 사용
class PhotoStorageService {
  /// S3 Storage가 설정되어 있는지 확인
  static bool _isStorageConfigured = false;
  static bool get isStorageConfigured => _isStorageConfigured;

  /// Storage 설정 확인
  static Future<void> checkStorageConfiguration() async {
    try {
      // S3 플러그인이 등록되어 있는지 확인
      final plugins = Amplify.Storage.getPluginKeys();
      _isStorageConfigured = plugins.isNotEmpty;
      debugPrint('S3 Storage 설정 상태: $_isStorageConfigured');
    } catch (e) {
      _isStorageConfigured = false;
      debugPrint('S3 Storage 확인 오류: $e');
    }
  }

  /// 사진 업로드 (S3 또는 base64)
  /// [bytes] - 이미지 바이트 데이터
  /// [fileName] - 파일명 (확장자 포함)
  /// [stationId] - 스테이션 ID (S3 경로용)
  /// 반환: S3 키 (s3://...) 또는 base64 data URL
  static Future<String?> uploadPhoto({
    required Uint8List bytes,
    required String fileName,
    required String stationId,
  }) async {
    // S3가 설정되어 있으면 S3에 업로드
    if (_isStorageConfigured) {
      return await _uploadToS3(bytes, fileName, stationId);
    }

    // S3가 없으면 base64로 인코딩
    return _encodeToBase64(bytes, fileName);
  }

  /// S3에 업로드
  static Future<String?> _uploadToS3(
    Uint8List bytes,
    String fileName,
    String stationId,
  ) async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final key = 'photos/$stationId/${timestamp}_$fileName';

      final result = await Amplify.Storage.uploadData(
        data: StorageDataPayload.bytes(bytes),
        path: StoragePath.fromString(key),
        options: const StorageUploadDataOptions(
          accessLevel: StorageAccessLevel.private,
        ),
      ).result;

      debugPrint('S3 업로드 완료: ${result.uploadedItem.path}');
      // S3 키 반환 (나중에 getUrl로 URL 생성)
      return 's3://$key';
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
        throw Exception('S3 Storage가 설정되지 않았습니다.');
      }

      try {
        final key = photoPath.substring(5); // 's3://' 제거
        final result = await Amplify.Storage.getUrl(
          path: StoragePath.fromString(key),
          options: const StorageGetUrlOptions(
            accessLevel: StorageAccessLevel.private,
            pluginOptions: S3GetUrlPluginOptions(
              expiresIn: Duration(hours: 1), // 1시간 유효
            ),
          ),
        ).result;

        return result.url.toString();
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
      final key = photoPath.substring(5);
      await Amplify.Storage.remove(
        path: StoragePath.fromString(key),
        options: const StorageRemoveOptions(
          accessLevel: StorageAccessLevel.private,
        ),
      ).result;
      debugPrint('S3 사진 삭제 완료: $key');
    } catch (e) {
      debugPrint('S3 사진 삭제 오류: $e');
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
