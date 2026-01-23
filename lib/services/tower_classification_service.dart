import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 철탑형태 분류 서비스 - FastAPI 기반 YOLOv8 모델 연동
class TowerClassificationService {
  // FastAPI 서버 URL
  static const String _baseUrl = 'https://c3jictzagh.execute-api.ap-northeast-2.amazonaws.com';

  // 분류 클래스 정보 (9개 클래스)
  static const Map<int, Map<String, String>> classNames = {
    0: {'en': 'simple_pole', 'kr': '간이폴, 분산폴 및 비기준 설치대', 'short': '간이폴'},
    1: {'en': 'steel_pipe', 'kr': '강관주', 'short': '강관주'},
    2: {'en': 'complex_type', 'kr': '복합형', 'short': '복합형'},
    3: {'en': 'indoor', 'kr': '옥내, 터널, 지하 등', 'short': '옥내'},
    4: {'en': 'single_pole_building', 'kr': '원폴(건물)', 'short': '원폴(건물)'},
    5: {'en': 'tower_building', 'kr': '철탑(건물)', 'short': '철탑(건물)'},
    6: {'en': 'tower_ground', 'kr': '철탑(지면)', 'short': '철탑(지면)'},
    7: {'en': 'telecom_pole', 'kr': '통신주', 'short': '통신주'},
    8: {'en': 'frame_mount', 'kr': '프레임', 'short': '프레임'},
  };

  // 영문 클래스명으로 한글 클래스명 조회
  static String getKoreanClassName(String englishName) {
    for (final entry in classNames.entries) {
      if (entry.value['en'] == englishName) {
        return entry.value['kr'] ?? englishName;
      }
    }
    return englishName;
  }

  // 영문 클래스명으로 짧은 한글 클래스명 조회
  static String getShortClassName(String englishName) {
    for (final entry in classNames.entries) {
      if (entry.value['en'] == englishName) {
        return entry.value['short'] ?? englishName;
      }
    }
    return englishName;
  }

  /// 서버 연결 상태 확인
  /// Returns: (isConnected, isModelLoaded, errorMessage)
  Future<ServerStatus> checkServerConnection() async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/health'),
      ).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final isHealthy = data['status'] == 'healthy';
        final isModelLoaded = data['model_loaded'] == true;

        return ServerStatus(
          isConnected: isHealthy,
          isModelLoaded: isModelLoaded,
          modelPath: data['model_path'] as String?,
        );
      }
      return ServerStatus(isConnected: false, isModelLoaded: false);
    } catch (e) {
      debugPrint('서버 연결 확인 실패: $e');
      return ServerStatus(isConnected: false, isModelLoaded: false, error: e.toString());
    }
  }

  /// 단일 이미지 분류
  Future<ClassificationResult> classifySingle(
    Uint8List imageBytes,
    String filename, {
    double confThreshold = 0.5,
  }) async {
    try {
      final uri = Uri.parse('$_baseUrl/predict?conf_threshold=$confThreshold');

      final request = http.MultipartRequest('POST', uri)
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          imageBytes,
          filename: filename,
        ));

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 30),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data['success'] == true) {
          final prediction = data['prediction'];
          final top5List = (data['top5'] as List).map((item) => Top5Prediction(
            rank: item['rank'],
            className: item['class_name'],
            classNameKr: item['class_name_kr'],
            confidence: (item['confidence'] as num).toDouble(),
          )).toList();

          return ClassificationResult(
            className: prediction['class_name'],
            classNameKr: prediction['class_name_kr'],
            shortName: prediction['short_name'],
            confidence: (prediction['confidence'] as num).toDouble(),
            top5: top5List,
            isConfident: data['is_confident'] ?? false,
            processingTimeMs: (data['processing_time_ms'] as num?)?.toDouble(),
          );
        }
      }

      throw Exception('분류 실패: ${response.statusCode} - ${response.body}');
    } catch (e) {
      debugPrint('분류 오류: $e');
      rethrow;
    }
  }

  /// 앙상블 분류 (여러 이미지)
  Future<EnsembleResult> classifyEnsemble(
    List<Uint8List> imageBytesList,
    List<String> filenames, {
    String method = 'mean',
    double confThreshold = 0.5,
  }) async {
    try {
      final uri = Uri.parse(
        '$_baseUrl/predict/ensemble?method=$method&conf_threshold=$confThreshold',
      );

      final request = http.MultipartRequest('POST', uri);

      for (int i = 0; i < imageBytesList.length; i++) {
        request.files.add(http.MultipartFile.fromBytes(
          'files',
          imageBytesList[i],
          filename: filenames[i],
        ));
      }

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 60),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data['success'] == true) {
          final finalPrediction = data['final_prediction'];
          final top5List = (data['top5'] as List).map((item) => Top5Prediction(
            rank: item['rank'],
            className: item['class_name'],
            classNameKr: item['class_name_kr'],
            confidence: (item['confidence'] as num).toDouble(),
          )).toList();

          final individualPredictions = (data['individual_predictions'] as List)
            .map((item) => IndividualPrediction(
              filename: item['filename'],
              prediction: item['prediction'],
              predictionKr: item['prediction_kr'],
              confidence: (item['confidence'] as num).toDouble(),
            ))
            .toList();

          return EnsembleResult(
            method: data['method'],
            numImages: data['num_images'],
            finalPrediction: ClassificationResult(
              className: finalPrediction['class_name'],
              classNameKr: finalPrediction['class_name_kr'],
              shortName: finalPrediction['short_name'],
              confidence: (finalPrediction['confidence'] as num).toDouble(),
              top5: top5List,
              isConfident: data['is_confident'] ?? false,
              processingTimeMs: (data['processing_time_ms'] as num?)?.toDouble(),
            ),
            individualPredictions: individualPredictions,
            isConfident: data['is_confident'] ?? false,
            processingTimeMs: (data['processing_time_ms'] as num?)?.toDouble(),
          );
        }
      }

      throw Exception('앙상블 분류 실패: ${response.statusCode} - ${response.body}');
    } catch (e) {
      debugPrint('앙상블 분류 오류: $e');
      rethrow;
    }
  }

  /// 지원 클래스 목록 조회
  Future<List<ClassInfo>> getClassList() async {
    try {
      final response = await http.get(Uri.parse('$_baseUrl/classes')).timeout(
        const Duration(seconds: 10),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return (data['classes'] as List).map((item) => ClassInfo(
          id: item['id'],
          name: item['name'],
          nameKr: item['name_kr'],
          shortName: item['short_name'],
        )).toList();
      }

      throw Exception('클래스 목록 조회 실패: ${response.statusCode}');
    } catch (e) {
      debugPrint('클래스 목록 조회 오류: $e');
      rethrow;
    }
  }

  /// 피드백 제출 (분류 결과 수정)
  /// 이미지와 올바른 라벨을 S3에 저장하여 향후 재학습에 활용
  Future<FeedbackResult> submitFeedback({
    required Uint8List imageBytes,
    required String filename,
    required String originalClass,
    required String correctedClass,
  }) async {
    try {
      final uri = Uri.parse('$_baseUrl/feedback');

      final request = http.MultipartRequest('POST', uri)
        ..fields['original_class'] = originalClass
        ..fields['corrected_class'] = correctedClass
        ..files.add(http.MultipartFile.fromBytes(
          'file',
          imageBytes,
          filename: filename,
        ));

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 30),
      );
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data['success'] == true) {
          return FeedbackResult(
            success: true,
            message: data['message'] ?? '피드백이 저장되었습니다.',
            s3Key: data['s3_key'],
          );
        }
      }

      throw Exception('피드백 저장 실패: ${response.statusCode} - ${response.body}');
    } catch (e) {
      debugPrint('피드백 저장 오류: $e');
      return FeedbackResult(
        success: false,
        message: '피드백 저장 실패: $e',
      );
    }
  }

  /// 9개 클래스 목록 반환 (피드백용)
  static List<ClassOption> getClassOptions() {
    return classNames.entries.map((entry) => ClassOption(
      id: entry.key,
      englishName: entry.value['en']!,
      koreanName: entry.value['kr']!,
      shortName: entry.value['short']!,
    )).toList();
  }
}

/// 분류 결과 (단일 이미지)
class ClassificationResult {
  final String className;
  final String classNameKr;
  final String shortName;
  final double confidence;
  final List<Top5Prediction> top5;
  final bool isConfident;
  final double? processingTimeMs;

  ClassificationResult({
    required this.className,
    required this.classNameKr,
    required this.shortName,
    required this.confidence,
    required this.top5,
    required this.isConfident,
    this.processingTimeMs,
  });
}

/// Top-5 예측 결과
class Top5Prediction {
  final int rank;
  final String className;
  final String classNameKr;
  final double confidence;

  Top5Prediction({
    required this.rank,
    required this.className,
    required this.classNameKr,
    required this.confidence,
  });
}

/// 앙상블 결과
class EnsembleResult {
  final String method;
  final int numImages;
  final ClassificationResult finalPrediction;
  final List<IndividualPrediction> individualPredictions;
  final bool isConfident;
  final double? processingTimeMs;

  EnsembleResult({
    required this.method,
    required this.numImages,
    required this.finalPrediction,
    required this.individualPredictions,
    required this.isConfident,
    this.processingTimeMs,
  });
}

/// 개별 이미지 예측 결과
class IndividualPrediction {
  final String filename;
  final String prediction;
  final String predictionKr;
  final double confidence;

  IndividualPrediction({
    required this.filename,
    required this.prediction,
    required this.predictionKr,
    required this.confidence,
  });
}

/// 클래스 정보
class ClassInfo {
  final int id;
  final String name;
  final String nameKr;
  final String shortName;

  ClassInfo({
    required this.id,
    required this.name,
    required this.nameKr,
    required this.shortName,
  });
}

/// 서버 상태 정보
class ServerStatus {
  final bool isConnected;
  final bool isModelLoaded;
  final String? modelPath;
  final String? error;

  ServerStatus({
    required this.isConnected,
    required this.isModelLoaded,
    this.modelPath,
    this.error,
  });

  bool get isReady => isConnected && isModelLoaded;
}

/// 피드백 결과
class FeedbackResult {
  final bool success;
  final String message;
  final String? s3Key;

  FeedbackResult({
    required this.success,
    required this.message,
    this.s3Key,
  });
}

/// 클래스 선택 옵션 (피드백용)
class ClassOption {
  final int id;
  final String englishName;
  final String koreanName;
  final String shortName;

  ClassOption({
    required this.id,
    required this.englishName,
    required this.koreanName,
    required this.shortName,
  });
}
