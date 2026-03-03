import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// 감사 로그 액션 타입
enum AuditAction {
  create,
  update,
  delete,
  approve,
  reject,
  suspend,
  restore,
  rollback,
  login,
  logout,
}

/// 감사 로그 모델
class AuditLogEntry {
  final String id;
  final AuditAction action;
  final String entityType;
  final String entityId;
  final String userId;
  final String? userEmail;
  final String? userName;
  final String? userTeamId;
  final String? userTeamName;
  final DateTime timestamp;
  final Map<String, dynamic>? previousData;
  final Map<String, dynamic>? newData;
  final List<String>? changedFields;
  final bool canRollback;
  final DateTime? rolledBackAt;
  final String? rolledBackBy;

  AuditLogEntry({
    required this.id,
    required this.action,
    required this.entityType,
    required this.entityId,
    required this.userId,
    this.userEmail,
    this.userName,
    this.userTeamId,
    this.userTeamName,
    required this.timestamp,
    this.previousData,
    this.newData,
    this.changedFields,
    this.canRollback = true,
    this.rolledBackAt,
    this.rolledBackBy,
  });

  factory AuditLogEntry.fromJson(Map<String, dynamic> json) {
    return AuditLogEntry(
      id: json['id'] as String,
      action: AuditAction.values.firstWhere(
        (a) => a.name.toUpperCase() == json['action'],
        orElse: () => AuditAction.update,
      ),
      entityType: json['entityType'] as String,
      entityId: json['entityId'] as String,
      userId: json['userId'] as String,
      userEmail: json['userEmail'] as String?,
      userName: json['userName'] as String?,
      userTeamId: json['userTeamId'] as String?,
      userTeamName: json['userTeamName'] as String?,
      timestamp: DateTime.parse(json['timestamp'] as String),
      previousData: json['previousData'] != null
          ? jsonDecode(json['previousData'] as String) as Map<String, dynamic>
          : null,
      newData: json['newData'] != null
          ? jsonDecode(json['newData'] as String) as Map<String, dynamic>
          : null,
      changedFields: (json['changedFields'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(),
      canRollback: json['canRollback'] as bool? ?? true,
      rolledBackAt: json['rolledBackAt'] != null
          ? DateTime.parse(json['rolledBackAt'] as String)
          : null,
      rolledBackBy: json['rolledBackBy'] as String?,
    );
  }
}

/// 감사 로그 서비스 (EC2 REST API 사용)
class AuditService extends ChangeNotifier {
  /// API 서버 URL
  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  String? _currentUserId;
  String? _currentUserEmail;
  String? _currentUserName;
  String? _currentTeamId;
  String? _currentTeamName;

  /// 현재 사용자 컨텍스트 설정
  void setUserContext({
    required String userId,
    String? email,
    String? name,
    String? teamId,
    String? teamName,
  }) {
    _currentUserId = userId;
    _currentUserEmail = email;
    _currentUserName = name;
    _currentTeamId = teamId;
    _currentTeamName = teamName;
  }

  /// 감사 로그 기록 — 서버사이드에서 자동 기록되므로 프론트에서는 호출 불필요
  Future<bool> log({
    required AuditAction action,
    required String entityType,
    required String entityId,
    Map<String, dynamic>? previousData,
    Map<String, dynamic>? newData,
    List<String>? changedFields,
    bool canRollback = true,
  }) async {
    // 감사 로그는 서버에서 자동 기록됨 (변조 방지)
    return true;
  }

  /// 로그인 이벤트 기록
  Future<bool> logLogin(String userId, String? email) async {
    _currentUserId = userId;
    _currentUserEmail = email;

    return log(
      action: AuditAction.login,
      entityType: 'User',
      entityId: userId,
      canRollback: false,
    );
  }

  /// 로그아웃 이벤트 기록
  Future<bool> logLogout() async {
    if (_currentUserId == null) return false;

    final result = await log(
      action: AuditAction.logout,
      entityType: 'User',
      entityId: _currentUserId!,
      canRollback: false,
    );

    // 컨텍스트 클리어
    _currentUserId = null;
    _currentUserEmail = null;
    _currentUserName = null;
    _currentTeamId = null;
    _currentTeamName = null;

    return result;
  }

  /// 변경된 필드 감지
  static List<String> detectChangedFields(
    Map<String, dynamic> previous,
    Map<String, dynamic> current,
  ) {
    final changedFields = <String>[];
    final allKeys = {...previous.keys, ...current.keys};

    for (final key in allKeys) {
      final prevValue = previous[key];
      final currValue = current[key];

      if (prevValue != currValue) {
        changedFields.add(key);
      }
    }

    return changedFields;
  }

  /// 감사 로그 조회
  Future<List<AuditLogEntry>> listAuditLogs({
    String? entityType,
    String? entityId,
    String? userId,
    AuditAction? action,
    DateTime? startDate,
    DateTime? endDate,
    int limit = 50,
  }) async {
    try {
      final params = <String, String>{'limit': limit.toString()};
      if (entityType != null) params['entityType'] = entityType;
      if (action != null) params['action'] = action.name.toUpperCase();

      final uri = Uri.parse('$_baseUrl/admin/audit-logs')
          .replace(queryParameters: params);
      final response = await http.get(uri, headers: {
        'Accept': 'application/json',
        'X-User-Id': _currentUserId ?? '',
      });

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['success'] == true) {
          return (data['logs'] as List)
              .map((e) => AuditLogEntry.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      }
      debugPrint('listAuditLogs failed: ${response.statusCode}');
      return [];
    } catch (e) {
      debugPrint('listAuditLogs error: $e');
      return [];
    }
  }

  /// 특정 엔티티의 변경 이력 조회
  Future<List<AuditLogEntry>> getEntityHistory(
    String entityType,
    String entityId,
  ) async {
    return listAuditLogs(
      entityType: entityType,
      entityId: entityId,
      limit: 100,
    );
  }

  /// 롤백 수행 — Phase 2 구현 예정
  Future<bool> rollback(String auditLogId) async {
    return false;
  }
}
