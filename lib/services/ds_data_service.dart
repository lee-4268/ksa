import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// DS 데이터 조회/삭제 서비스
class DsDataService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  /// Auth 본부 ID → DS 본부 ID 매핑
  static const Map<String, String> authToDsDivision = {
    'gangnam': 'sudogwon',
    'gangbuk': 'sudogwon',
    'incheon': 'sudogwon',
    'gyeonggi': 'sudogwon',
    'gangwon': 'gangwon',
    'chungcheong': 'chungcheong',
    'gyeongbuk': 'gyeongbuk',
    'gyeongnam': 'gyeongnam',
    'seobu': 'seobu',
  };

  /// DS 본부 목록
  static const Map<String, String> dsDivisionNames = {
    'sudogwon': '수도권',
    'gangwon': '강원본부',
    'gyeongnam': '경남본부',
    'gyeongbuk': '경북본부',
    'chungcheong': '충청본부',
    'seobu': '서부본부',
  };

  /// 업로드 통계 조회
  Future<DsStatsResult> getStats({String? divisionId}) async {
    final params = <String, String>{};
    if (divisionId != null) params['divisionId'] = divisionId;

    final uri = Uri.parse('$_baseUrl/ds/stats').replace(queryParameters: params.isNotEmpty ? params : null);
    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception('통계 조회 실패: ${response.statusCode}');
    }

    final body = jsonDecode(response.body);
    if (body['success'] != true) {
      throw Exception('통계 조회 실패');
    }

    final uploads = (body['uploads'] as List).map((item) {
      final sk = item['importDate']?.toString() ?? '';
      String actualDate = sk;
      String divisionCode = item['divisionCode']?.toString() ?? '';

      // SK format: "divisionCode#importDate" (e.g., "50#20260203")
      if (sk.contains('#')) {
        final parts = sk.split('#');
        divisionCode = parts[0];
        actualDate = parts[1];
      }

      final sheetStatsRaw = item['sheetStats'] as Map<String, dynamic>? ?? {};

      return DsUploadInfo(
        divisionId: item['divisionId'] ?? '',
        divisionCode: divisionCode,
        divisionName: item['divisionName'] ?? dsDivisionNames[item['divisionId']] ?? '',
        importDateSk: sk,
        actualDate: actualDate,
        uploadedBy: item['uploadedBy'] ?? '',
        uploadedAt: item['uploadedAt'] ?? '',
        fileName: item['fileName'] ?? '',
        status: item['status'] ?? '',
        sheetStats: sheetStatsRaw.map((k, v) => MapEntry(k, v is int ? v : int.tryParse(v.toString()) ?? 0)),
        totalRows: item['totalRows'] is int ? item['totalRows'] : int.tryParse(item['totalRows']?.toString() ?? '0') ?? 0,
      );
    }).toList();

    // 최신순 정렬
    uploads.sort((a, b) => b.actualDate.compareTo(a.actualDate));

    return DsStatsResult(uploads: uploads);
  }

  /// 데이터 조회 (페이징)
  Future<DsDataPage> getData({
    required String divisionId,
    required String sheetName,
    String? importDate,
    int limit = 100,
    String? lastKey,
    String? search,
    String? divisionCode,
  }) async {
    final params = <String, String>{
      'divisionId': divisionId,
      'sheetName': sheetName,
      'limit': limit.toString(),
    };
    if (importDate != null) params['importDate'] = importDate;
    if (lastKey != null) params['lastKey'] = lastKey;
    if (search != null && search.isNotEmpty) params['search'] = search;
    if (divisionCode != null) params['divisionCode'] = divisionCode;

    final uri = Uri.parse('$_baseUrl/ds/data').replace(queryParameters: params);
    final response = await http.get(uri);

    if (response.statusCode != 200) {
      throw Exception('데이터 조회 실패: ${response.statusCode}');
    }

    final body = jsonDecode(response.body);
    if (body['success'] != true) {
      throw Exception('데이터 조회 실패');
    }

    final items = (body['items'] as List).map((item) {
      final dataRaw = item['data'] as Map<String, dynamic>? ?? {};
      return DsRecord(
        divisionId: item['divisionId'] ?? '',
        sk: item['sk'] ?? '',
        sheetName: item['sheetName'] ?? '',
        importDate: item['importDate'] ?? '',
        divisionCode: item['divisionCode'] ?? '',
        data: dataRaw.map((k, v) => MapEntry(k, v?.toString() ?? '')),
      );
    }).toList();

    final headersList = body['headers'] as List<dynamic>?;
    return DsDataPage(
      items: items,
      count: body['count'] ?? items.length,
      lastEvaluatedKey: body['lastEvaluatedKey'],
      headers: headersList?.cast<String>(),
    );
  }

  /// 데이터 삭제
  Future<int> deleteData(String divisionId, String importDate, {String? divisionCode}) async {
    final params = <String, String>{
      'divisionId': divisionId,
      'importDate': importDate,
    };
    if (divisionCode != null) params['divisionCode'] = divisionCode;

    final uri = Uri.parse('$_baseUrl/ds/data').replace(queryParameters: params);
    final response = await http.delete(uri);

    if (response.statusCode != 200) {
      throw Exception('삭제 실패: ${response.statusCode}');
    }

    final body = jsonDecode(response.body);
    debugPrint('DS 데이터 삭제: ${body['deletedCount']}건');
    return body['deletedCount'] ?? 0;
  }

  static String formatNumber(dynamic num) {
    if (num == null) return '0';
    final n = num is int ? num : int.tryParse(num.toString()) ?? 0;
    return n.toString().replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (match) => '${match[1]},',
    );
  }
}

// ============================================================
// Models
// ============================================================

class DsStatsResult {
  final List<DsUploadInfo> uploads;

  DsStatsResult({required this.uploads});

  int get totalRows => uploads.fold(0, (sum, u) => sum + u.totalRows);
  int get totalUploads => uploads.length;
  Set<String> get divisions => uploads.map((u) => u.divisionId).toSet();
}

class DsUploadInfo {
  final String divisionId;
  final String divisionCode;
  final String divisionName;
  final String importDateSk;
  final String actualDate;
  final String uploadedBy;
  final String uploadedAt;
  final String fileName;
  final String status;
  final Map<String, int> sheetStats;
  final int totalRows;

  DsUploadInfo({
    required this.divisionId,
    required this.divisionCode,
    required this.divisionName,
    required this.importDateSk,
    required this.actualDate,
    required this.uploadedBy,
    required this.uploadedAt,
    required this.fileName,
    required this.status,
    required this.sheetStats,
    required this.totalRows,
  });

  String get formattedDate {
    if (actualDate.length == 8) {
      return '${actualDate.substring(0, 4)}-${actualDate.substring(4, 6)}-${actualDate.substring(6, 8)}';
    }
    return actualDate;
  }

  int get sheetCount => sheetStats.length;
}

class DsDataPage {
  final List<DsRecord> items;
  final int count;
  final String? lastEvaluatedKey;
  final List<String>? headers;

  DsDataPage({required this.items, required this.count, this.lastEvaluatedKey, this.headers});

  bool get hasMore => lastEvaluatedKey != null;
}

class DsRecord {
  final String divisionId;
  final String sk;
  final String sheetName;
  final String importDate;
  final String divisionCode;
  final Map<String, String> data;

  DsRecord({
    required this.divisionId,
    required this.sk,
    required this.sheetName,
    required this.importDate,
    required this.divisionCode,
    required this.data,
  });
}
