import 'dart:convert';

import 'package:http/http.dart' as http;

/// ERP vs DS 전산자료 비교 서비스
class ErpDsCompareService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  static const _apiTimeout = Duration(seconds: 120);

  String? _authToken;
  void setAuthToken(String? token) => _authToken = token;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${_authToken ?? ''}',
        'Content-Type': 'application/json',
      };

  /// ERP vs DS 비교 실행
  Future<ErpDsCompareResult> compare({
    required List<String> zpwinoList,
    required String divisionId,
    required String divisionCode,
    required String importDate,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/erp-ds/compare'),
          headers: _headers,
          body: json.encode({
            'zpwino_list': zpwinoList,
            'division_id': divisionId,
            'division_code': divisionCode,
            'import_date': importDate,
          }),
        )
        .timeout(_apiTimeout);
    if (resp.statusCode != 200) {
      final body = json.decode(utf8.decode(resp.bodyBytes));
      throw Exception(body['detail'] ?? '비교 실패');
    }
    final data = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return ErpDsCompareResult.fromJson(data);
  }
}

/// 비교 결과
class ErpDsCompareResult {
  final int total;
  final int erpFound;
  final int dsDeviceFound;
  final int dsAntennaFound;
  final List<String> warnings;
  final Map<String, int> summary;
  final List<CompareItem> items;
  final Map<String, Map<String, String>> resolveMap; // {zpwino: {input, type}}

  ErpDsCompareResult({
    required this.total,
    required this.erpFound,
    required this.dsDeviceFound,
    required this.dsAntennaFound,
    required this.warnings,
    required this.summary,
    required this.items,
    required this.resolveMap,
  });

  factory ErpDsCompareResult.fromJson(Map<String, dynamic> json) {
    final summaryRaw = json['summary'] as Map<String, dynamic>? ?? {};
    final resolveRaw = json['resolve_map'] as Map<String, dynamic>? ?? {};
    final resolveMap = resolveRaw.map((k, v) {
      final m = v as Map<String, dynamic>? ?? {};
      return MapEntry(k, {
        'input': m['input']?.toString() ?? '',
        'type': m['type']?.toString() ?? '',
      });
    });
    return ErpDsCompareResult(
      total: json['total'] as int? ?? 0,
      erpFound: json['erp_found'] as int? ?? 0,
      dsDeviceFound: json['ds_device_found'] as int? ?? 0,
      dsAntennaFound: json['ds_antenna_found'] as int? ?? 0,
      warnings: (json['warnings'] as List?)?.map((e) => e.toString()).toList() ?? [],
      summary: summaryRaw.map((k, v) => MapEntry(k, v is int ? v : 0)),
      items: (json['items'] as List?)
              ?.map((e) => CompareItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      resolveMap: resolveMap,
    );
  }
}

/// 개별 비교 항목
class CompareItem {
  final String zpwino;
  final String zpwina;
  final String areaHdofcNm;
  final bool erpFound;
  final String erpZpirty3;
  final String erpSerial;
  final String dsTowerType;
  final String dsSerial;
  final String towerMatch;
  final String serialMatch;

  CompareItem({
    required this.zpwino,
    required this.zpwina,
    required this.areaHdofcNm,
    required this.erpFound,
    required this.erpZpirty3,
    required this.erpSerial,
    required this.dsTowerType,
    required this.dsSerial,
    required this.towerMatch,
    required this.serialMatch,
  });

  factory CompareItem.fromJson(Map<String, dynamic> json) {
    return CompareItem(
      zpwino: json['zpwino'] ?? '',
      zpwina: json['zpwina'] ?? '',
      areaHdofcNm: json['area_hdofc_nm'] ?? '',
      erpFound: json['erp_found'] == true,
      erpZpirty3: json['erp_zpirty3'] ?? '',
      erpSerial: json['erp_serial'] ?? '',
      dsTowerType: json['ds_tower_type'] ?? '',
      dsSerial: json['ds_serial'] ?? '',
      towerMatch: json['tower_match'] ?? '',
      serialMatch: json['serial_match'] ?? '',
    );
  }
}
