import 'dart:convert';

import 'package:http/http.dart' as http;

/// 안테나 방위각 batch 조회 서비스 (현장 수검 Map 부채꼴 표시용)
class AzimuthService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  static const _apiTimeout = Duration(seconds: 30);

  String? _authToken;
  void setAuthToken(String? token) => _authToken = token;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${_authToken ?? ''}',
        'Content-Type': 'application/json',
      };

  /// {zpwino: [AntennaSector...]} 형태로 반환
  Future<Map<String, List<AntennaSector>>> fetchBatch(
      List<String> zpwinoList) async {
    if (zpwinoList.isEmpty) return {};

    final resp = await http
        .post(
          Uri.parse('$_baseUrl/azimuths/batch'),
          headers: _headers,
          body: json.encode({'zpwino_list': zpwinoList}),
        )
        .timeout(_apiTimeout);

    if (resp.statusCode != 200) {
      throw Exception('방위각 조회 실패: ${resp.statusCode}');
    }
    final data = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final items = data['items'] as Map<String, dynamic>? ?? {};
    final result = <String, List<AntennaSector>>{};
    items.forEach((zpwino, listRaw) {
      final list = (listRaw as List?) ?? [];
      result[zpwino] = list
          .map((e) => AntennaSector.fromJson(e as Map<String, dynamic>))
          .toList();
    });
    return result;
  }
}

/// (service, band) 단위 안테나 섹터
class AntennaSector {
  final String service; // LTE / 5G / 3G / WCDMA / CDMA
  final String band; // 800M / 1.8G / 2.1G / 2.6G / 3.5G / 28G
  final List<int> swings; // 방위각 0~359

  AntennaSector(
      {required this.service, required this.band, required this.swings});

  factory AntennaSector.fromJson(Map<String, dynamic> json) {
    return AntennaSector(
      service: json['service']?.toString() ?? '',
      band: json['band']?.toString() ?? '',
      swings: ((json['swings'] as List?) ?? [])
          .map((e) => (e as num).toInt())
          .toList(),
    );
  }

  String get key => '$service-$band'; // "LTE-800M", "5G-3.5G"
}

/// 지원 밴드 목록 (UI 드롭다운 + 색상 매핑용)
class BandSpec {
  final String service;
  final String band;
  final String label; // UI 표시용
  final int colorRgb; // 0xRRGGBB

  const BandSpec(this.service, this.band, this.label, this.colorRgb);

  String get key => '$service-$band';
}

const List<BandSpec> kSupportedBands = [
  BandSpec('LTE', '800M', 'LTE 800M', 0xFF1565C0),
  BandSpec('LTE', '1.8G', 'LTE 1.8G', 0xFF00897B),
  BandSpec('LTE', '2.1G', 'LTE 2.1G', 0xFF7B1FA2),
  BandSpec('LTE', '2.6G', 'LTE 2.6G', 0xFF4A90D9),
  BandSpec('5G', '3.5G', '5G 3.5G', 0xFFE53935),
  BandSpec('5G', '28G', '5G 28G', 0xFFF57C00),
  BandSpec('3G', '', '3G', 0xFF616161),
  BandSpec('WCDMA', '', 'WCDMA', 0xFF616161),
];
