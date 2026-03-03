import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'team_context_service.dart';
import 'audit_service.dart';

/// 관리자 서비스 — EC2 REST API 연동
class AdminService extends ChangeNotifier {
  // ignore: unused_field
  final AuditService _auditService;

  static const String _baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api-sko-kca.skons.net',
  );

  String? _currentUserId;
  final List<AppUserProfile> _allUsers = [];
  bool _isLoading = false;
  String? _errorMessage;

  AdminService(this._auditService);

  // Getters
  List<AppUserProfile> get pendingUsers => const [];
  List<AppUserProfile> get allUsers => _allUsers;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  int get pendingCount => 0;

  void setCurrentUser(String empno) {
    _currentUserId = empno;
  }

  // ── 역할 매핑 ──────────────────────────────────────────
  static UserRole mapBackendRole(String backendRole) {
    switch (backendRole) {
      case 'admin':
        return UserRole.superAdmin;
      case 'manager':
        return UserRole.divisionAdmin;
      default:
        return UserRole.member;
    }
  }

  static String mapToBackendRole(UserRole role) {
    switch (role) {
      case UserRole.superAdmin:
        return 'admin';
      case UserRole.divisionAdmin:
      case UserRole.teamAdmin:
        return 'manager';
      case UserRole.member:
        return 'member';
    }
  }

  // ── 사용자 목록 조회 ───────────────────────────────────
  Future<void> loadAllUsers() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final uri = Uri.parse('$_baseUrl/admin/users');
      final response = await http.get(uri, headers: {
        'Accept': 'application/json',
        'X-User-Id': _currentUserId ?? '',
      });

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['success'] == true) {
          _allUsers.clear();
          for (final u in (data['users'] as List)) {
            // 빈 문자열을 null로 치환
            String? nullIfEmpty(dynamic v) {
              final s = v as String?;
              return (s != null && s.isNotEmpty) ? s : null;
            }
            _allUsers.add(AppUserProfile(
              id: u['empno'] as String? ?? '',
              cognitoUserId: u['empno'] as String? ?? '',
              email: nullIfEmpty(u['email']) ?? '',
              name: nullIfEmpty(u['name']),
              phoneNumber: nullIfEmpty(u['phone']),
              teamId: nullIfEmpty(u['team']),
              divisionId: nullIfEmpty(u['region']),
              status: UserStatus.approved,
              role: mapBackendRole(u['role'] as String? ?? 'member'),
            ));
          }
        } else {
          _errorMessage = data['detail'] as String? ?? '사용자 목록 로드 실패';
        }
      } else if (response.statusCode == 401) {
        _errorMessage = '인증 정보가 없습니다. 다시 로그인해주세요.';
      } else if (response.statusCode == 403) {
        _errorMessage = '권한이 없습니다 (관리자 계정 필요).';
      } else {
        // 500 등 서버 에러 시 detail 메시지 표시
        String detail = '사용자 목록 로드 실패 (${response.statusCode})';
        try {
          final body = jsonDecode(response.body) as Map<String, dynamic>;
          if (body['detail'] != null) detail = '${body['detail']}';
        } catch (_) {}
        _errorMessage = detail;
        debugPrint('loadAllUsers server error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      _errorMessage = '네트워크 오류: $e';
      debugPrint('loadAllUsers error: $e');
    }

    _isLoading = false;
    notifyListeners();
  }

  // ── 역할 변경 ─────────────────────────────────────────
  Future<bool> changeUserRole(String profileId, UserRole newRole) async {
    try {
      final backendRole = mapToBackendRole(newRole);
      final response = await http.put(
        Uri.parse('$_baseUrl/admin/set-role'),
        headers: {
          'Content-Type': 'application/json',
          'X-User-Id': _currentUserId ?? '',
        },
        body: jsonEncode({'empno': profileId, 'role': backendRole}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['success'] == true) {
          await loadAllUsers();
          return true;
        }
      }
      _errorMessage = '역할 변경 실패 (${response.statusCode})';
      notifyListeners();
      return false;
    } catch (e) {
      _errorMessage = '역할 변경 오류: $e';
      notifyListeners();
      return false;
    }
  }

  // ── i-NET에서 불필요한 stub (인터페이스 유지) ──────────
  Future<void> loadPendingUsers() async {}

  Future<bool> approveUser({
    required String profileId,
    required String teamId,
    required String divisionId,
    required String approverUserId,
    UserRole role = UserRole.member,
  }) async => true;

  Future<bool> rejectUser({required String profileId, required String reason}) async => true;
  Future<bool> suspendUser(String profileId, String reason) async => false;
  Future<bool> restoreUser(String profileId) async => false;
  Future<String?> createDivision({required String name, required String code, String? description}) async => null;
  Future<String?> createTeam({required String divisionId, required String name, required String code, String? description}) async => null;
  Future<bool> deleteTeam(String teamId) async => false;
  Future<bool> deleteDivision(String divisionId) async => false;
  Future<int> autoApprovePendingUsers({required String currentUserId, String? teamId, String? divisionId}) async => 0;
  Future<int> batchApproveUsers({required List<String> profileIds, required String teamId, required String divisionId, required String approverUserId}) async => 0;

  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }
}
