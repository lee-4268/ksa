import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class NotificationItem {
  final int id;
  final String type; // 'notice' | 'comment' | 'status'
  final String title;
  final String body;
  final String relatedType; // 'notice' | 'request'
  final int relatedId;
  final bool isRead;
  final String createdAt;

  NotificationItem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.relatedType,
    required this.relatedId,
    required this.isRead,
    required this.createdAt,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> j) => NotificationItem(
        id: j['id'] as int? ?? 0,
        type: j['type'] as String? ?? '',
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        relatedType: j['related_type'] as String? ?? '',
        relatedId: j['related_id'] as int? ?? 0,
        isRead: (j['is_read'] as int? ?? 0) == 1,
        createdAt: j['created_at'] as String? ?? '',
      );
}

class NotificationService extends ChangeNotifier {
  static const _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );
  static const _pollInterval = Duration(seconds: 30);

  int _unreadCount = 0;
  List<NotificationItem> _items = [];
  Timer? _timer;
  String? _token;
  bool _fetching = false;

  int get unreadCount => _unreadCount;
  List<NotificationItem> get items => List.unmodifiable(_items);

  void start(String token) {
    _token = token;
    _timer?.cancel();
    fetch(); // 즉시 1회
    _timer = Timer.periodic(_pollInterval, (_) => fetch());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _token = null;
    _unreadCount = 0;
    _items = [];
    notifyListeners();
  }

  Future<void> fetch() async {
    if (_token == null || _fetching) return;
    _fetching = true;
    try {
      final resp = await http
          .get(
            Uri.parse('$_baseUrl/notifications'),
            headers: {'Authorization': 'Bearer $_token'},
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = json.decode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
        _unreadCount = data['unread_count'] as int? ?? 0;
        _items = (data['items'] as List? ?? [])
            .map((e) => NotificationItem.fromJson(e as Map<String, dynamic>))
            .toList();
        notifyListeners();
      }
    } catch (_) {
      // 폴링 실패는 조용히 무시
    } finally {
      _fetching = false;
    }
  }

  Future<void> readAll() async {
    if (_token == null) return;
    try {
      await http.post(
        Uri.parse('$_baseUrl/notifications/read-all'),
        headers: {'Authorization': 'Bearer $_token'},
      ).timeout(const Duration(seconds: 10));
      for (var i = 0; i < _items.length; i++) {
        final item = _items[i];
        if (!item.isRead) {
          _items[i] = NotificationItem(
            id: item.id, type: item.type, title: item.title, body: item.body,
            relatedType: item.relatedType, relatedId: item.relatedId,
            isRead: true, createdAt: item.createdAt,
          );
        }
      }
      _unreadCount = 0;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> readOne(int notifId) async {
    if (_token == null) return;
    try {
      await http.post(
        Uri.parse('$_baseUrl/notifications/$notifId/read'),
        headers: {'Authorization': 'Bearer $_token'},
      ).timeout(const Duration(seconds: 10));
      final idx = _items.indexWhere((e) => e.id == notifId);
      if (idx >= 0 && !_items[idx].isRead) {
        final item = _items[idx];
        _items[idx] = NotificationItem(
          id: item.id, type: item.type, title: item.title, body: item.body,
          relatedType: item.relatedType, relatedId: item.relatedId,
          isRead: true, createdAt: item.createdAt,
        );
        _unreadCount = (_unreadCount - 1).clamp(0, 9999);
        notifyListeners();
      }
    } catch (_) {}
  }

  /// 시간 표시 (예: 방금 전, 5분 전, 2시간 전, 어제, 3일 전)
  static String relativeTime(String isoString) {
    if (isoString.isEmpty) return '';
    try {
      final dt = DateTime.parse(isoString).toLocal();
      final diff = DateTime.now().difference(dt);
      if (diff.inMinutes < 1) return '방금 전';
      if (diff.inMinutes < 60) return '${diff.inMinutes}분 전';
      if (diff.inHours < 24) return '${diff.inHours}시간 전';
      if (diff.inDays == 1) return '어제';
      if (diff.inDays < 7) return '${diff.inDays}일 전';
      return '${dt.month}/${dt.day}';
    } catch (_) {
      return '';
    }
  }
}
