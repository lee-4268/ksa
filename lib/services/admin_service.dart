import 'package:flutter/foundation.dart';
import 'team_context_service.dart';
import 'audit_service.dart';

/// 관리자 서비스 - 사용자 승인, 팀 관리 등 (EC2 REST API 사용)
class AdminService extends ChangeNotifier {
  // ignore: unused_field - 추후 EC2 API 구현 시 사용
  final AuditService _auditService;

  List<AppUserProfile> _pendingUsers = [];
  final List<AppUserProfile> _allUsers = [];
  bool _isLoading = false;
  String? _errorMessage;

  AdminService(this._auditService);

  // Getters
  List<AppUserProfile> get pendingUsers => _pendingUsers;
  List<AppUserProfile> get allUsers => _allUsers;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  int get pendingCount => _pendingUsers.length;

  /// 승인 대기 중인 사용자 목록 조회 (i-NET 인증에서는 불필요)
  Future<void> loadPendingUsers() async {
    debugPrint('loadPendingUsers: i-NET 인증에서는 승인 대기 없음');
    _pendingUsers = [];
    notifyListeners();
  }

  /// 모든 사용자 목록 조회 (현재 stub - EC2 API 추가 필요)
  Future<void> loadAllUsers() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    // EC2 API에 users list 엔드포인트 추가 필요
    debugPrint('loadAllUsers: EC2 API 구현 필요');

    _isLoading = false;
    notifyListeners();
  }

  /// 사용자 승인 (i-NET 인증에서는 불필요)
  Future<bool> approveUser({
    required String profileId,
    required String teamId,
    required String divisionId,
    required String approverUserId,
    UserRole role = UserRole.member,
  }) async {
    debugPrint('approveUser: i-NET 인증에서는 불필요');
    return true;
  }

  /// 사용자 거부 (i-NET 인증에서는 불필요)
  Future<bool> rejectUser({
    required String profileId,
    required String reason,
  }) async {
    debugPrint('rejectUser: i-NET 인증에서는 불필요');
    return true;
  }

  /// 사용자 정지 (현재 stub - EC2 API 추가 필요)
  Future<bool> suspendUser(String profileId, String reason) async {
    debugPrint('suspendUser: EC2 API 구현 필요');
    return false;
  }

  /// 사용자 복원 (현재 stub - EC2 API 추가 필요)
  Future<bool> restoreUser(String profileId) async {
    debugPrint('restoreUser: EC2 API 구현 필요');
    return false;
  }

  /// 사용자 역할 변경 (현재 stub - EC2 API 추가 필요)
  Future<bool> changeUserRole(String profileId, UserRole newRole) async {
    debugPrint('changeUserRole: EC2 API 구현 필요');
    return false;
  }

  /// 본부 생성 (현재 stub - EC2 API 추가 필요)
  Future<String?> createDivision({
    required String name,
    required String code,
    String? description,
  }) async {
    debugPrint('createDivision: EC2 API 구현 필요');
    return null;
  }

  /// 팀 생성 (현재 stub - EC2 API 추가 필요)
  Future<String?> createTeam({
    required String divisionId,
    required String name,
    required String code,
    String? description,
  }) async {
    debugPrint('createTeam: EC2 API 구현 필요');
    return null;
  }

  /// 팀 삭제 (현재 stub - EC2 API 추가 필요)
  Future<bool> deleteTeam(String teamId) async {
    debugPrint('deleteTeam: EC2 API 구현 필요');
    return false;
  }

  /// 본부 삭제 (현재 stub - EC2 API 추가 필요)
  Future<bool> deleteDivision(String divisionId) async {
    debugPrint('deleteDivision: EC2 API 구현 필요');
    return false;
  }

  /// 에러 메시지 클리어
  void clearError() {
    _errorMessage = null;
    notifyListeners();
  }

  /// PENDING 사용자 일괄 자동 승인 (i-NET 인증에서는 불필요)
  Future<int> autoApprovePendingUsers({
    required String currentUserId,
    String? teamId,
    String? divisionId,
  }) async {
    debugPrint('autoApprovePendingUsers: i-NET 인증에서는 불필요');
    return 0;
  }

  /// 특정 사용자 목록 일괄 승인 (i-NET 인증에서는 불필요)
  Future<int> batchApproveUsers({
    required List<String> profileIds,
    required String teamId,
    required String divisionId,
    required String approverUserId,
  }) async {
    debugPrint('batchApproveUsers: i-NET 인증에서는 불필요');
    return 0;
  }
}
