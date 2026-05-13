import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/route_basket.dart';

class RouteBasketService {
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );
  static const _timeout = Duration(seconds: 30);

  String? _authToken;
  void setAuthToken(String? token) => _authToken = token;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer ${_authToken ?? ''}',
        'Content-Type': 'application/json',
      };

  Future<List<RouteBasketEntry>> getAll() async {
    final resp = await http
        .get(Uri.parse('$_baseUrl/route-basket'), headers: _headers)
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('경로 담기 로드 실패');
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    final entries = body['entries'] as List? ?? [];
    return entries
        .map((e) => RouteBasketEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<RouteBasketEntry> save({
    required String title,
    required String weekLabel,
    required String joLabel,
    required List<BasketStation> stations,
  }) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/route-basket'),
          headers: _headers,
          body: json.encode({
            'title': title,
            'week_label': weekLabel,
            'jo_label': joLabel,
            'stations': stations.map((s) => s.toJson()).toList(),
          }),
        )
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('경로 담기 저장 실패');
    final body = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return RouteBasketEntry.fromJson(body['entry'] as Map<String, dynamic>);
  }

  Future<void> updateStations(String entryId, List<BasketStation> stations) async {
    final resp = await http
        .patch(
          Uri.parse('$_baseUrl/route-basket/$entryId'),
          headers: _headers,
          body: json.encode({'stations': stations.map((s) => s.toJson()).toList()}),
        )
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('경로 수정 실패');
  }

  Future<void> delete(String entryId) async {
    final resp = await http
        .delete(Uri.parse('$_baseUrl/route-basket/$entryId'), headers: _headers)
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('경로 담기 삭제 실패');
  }
}
