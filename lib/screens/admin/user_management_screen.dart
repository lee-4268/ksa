import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/auth_service.dart';
import '../../services/admin_service.dart';
import '../../services/team_context_service.dart';
import '../../widgets/progress_dialog.dart';
import '../../widgets/app_loader.dart';

/// 사용자 관리 화면 (필터링, 검색, 권한 설정)
class UserManagementScreen extends StatefulWidget {
  const UserManagementScreen({super.key});

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  // 검색 및 필터
  final TextEditingController _searchController = TextEditingController();
  String? _selectedDivisionId;
  String? _selectedTeamId;
  UserRole? _selectedRole;

  // 데이터 (사용자에서 동적 추출)
  List<String> _uniqueDivisions = [];
  List<String> _uniqueTeams = [];
  List<UserRole> _uniqueRoles = [];
  List<AppUserProfile> _filteredUsers = [];

  // 상태
  bool _isLoading = true;
  String? _errorMessage;

  // 페이지네이션
  static const int _pageSize = 50;
  int _currentPage = 0;
  bool _hasMore = true;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitialData();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMoreUsers();
    }
  }

  Future<void> _loadInitialData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final authService = context.read<AuthService>();
      final adminService = context.read<AdminService>();

      // 현재 사용자 ID를 AdminService에 설정
      adminService.setCurrentUser(authService.userId ?? '', token: authService.authToken);

      // 사용자 목록 로드
      await adminService.loadAllUsers();

      // 사용자 데이터에서 고유 본부/팀 목록 동적 추출
      final divisions = adminService.allUsers
          .map((u) => u.divisionId)
          .where((d) => d != null && d.isNotEmpty)
          .cast<String>()
          .toSet()
          .toList()
        ..sort();
      final teams = adminService.allUsers
          .map((u) => u.teamId)
          .where((t) => t != null && t.isNotEmpty)
          .cast<String>()
          .toSet()
          .toList()
        ..sort();
      // 역할은 등급 순서(최고 관리자→일반 멤버)로 보여야 하므로 정렬하지 않고
      // UserRole.values 선언 순서를 그대로 따른다.
      final rolesInData = adminService.allUsers.map((u) => u.role).toSet();
      final roles = UserRole.values.where(rolesInData.contains).toList();

      setState(() {
        _uniqueDivisions = divisions;
        _uniqueTeams = teams;
        _uniqueRoles = roles;
        // 이 화면에서 역할을 바꾼 뒤 새로고침하면(예: 마지막 관리자 강등)
        // 필터 중인 역할이 목록에서 사라져 DropdownButton value 가 items 와
        // 어긋난다. 그런 경우 선택을 해제한다.
        if (_selectedRole != null && !roles.contains(_selectedRole)) {
          _selectedRole = null;
        }
        _applyFilters();
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = '데이터 로드 실패: $e';
        _isLoading = false;
      });
    }
  }

  void _applyFilters() {
    final adminService = context.read<AdminService>();
    final allUsers = adminService.allUsers;

    var filtered = allUsers.where((user) {
      // 본부 필터
      if (_selectedDivisionId != null && _selectedDivisionId!.isNotEmpty) {
        if (user.divisionId != _selectedDivisionId) return false;
      }

      // 팀 필터
      if (_selectedTeamId != null && _selectedTeamId!.isNotEmpty) {
        if (user.teamId != _selectedTeamId) return false;
      }

      // 역할 필터
      if (_selectedRole != null && user.role != _selectedRole) {
        return false;
      }

      // 이름 검색
      final searchQuery = _searchController.text.trim().toLowerCase();
      if (searchQuery.isNotEmpty) {
        final name = (user.name ?? '').toLowerCase();
        final email = user.email.toLowerCase();
        if (!name.contains(searchQuery) && !email.contains(searchQuery)) {
          return false;
        }
      }

      return true;
    }).toList();

    // 이름 순 정렬
    filtered.sort((a, b) {
      final aName = a.name ?? a.id;
      final bName = b.name ?? b.id;
      return aName.compareTo(bName);
    });

    setState(() {
      _filteredUsers = filtered;
      _currentPage = 0;
      _hasMore = filtered.length > _pageSize;
    });
  }

  Future<void> _loadMoreUsers() async {
    if (!_hasMore || _isLoading) return;

    final nextPage = _currentPage + 1;
    final startIndex = nextPage * _pageSize;

    if (startIndex >= _filteredUsers.length) {
      setState(() => _hasMore = false);
      return;
    }

    setState(() => _currentPage = nextPage);
  }

  Future<void> _refreshData() async {
    await _loadInitialData();
  }

  void _onDivisionChanged(String? divisionId) {
    setState(() {
      _selectedDivisionId = divisionId;
      _selectedTeamId = null; // 본부 변경 시 팀 선택 초기화
    });
    _applyFilters();
  }

  void _onTeamChanged(String? teamId) {
    setState(() {
      _selectedTeamId = teamId;
    });
    _applyFilters();
  }

  void _onRoleChanged(UserRole? role) {
    setState(() {
      _selectedRole = role;
    });
    _applyFilters();
  }

  void _onSearchChanged(String query) {
    _applyFilters();
  }

  void _clearFilters() {
    setState(() {
      _searchController.clear();
      _selectedDivisionId = null;
      _selectedTeamId = null;
      _selectedRole = null;
    });
    _applyFilters();
  }

  /// 선택된 본부에 소속된 팀 목록 (사용자 데이터에서 동적 추출)
  List<String> _getTeamsForSelectedDivision() {
    if (_selectedDivisionId == null) return _uniqueTeams;
    final adminService = context.read<AdminService>();
    return adminService.allUsers
        .where((u) => u.divisionId == _selectedDivisionId && u.teamId != null && u.teamId!.isNotEmpty)
        .map((u) => u.teamId!)
        .toSet()
        .toList()
      ..sort();
  }

  List<AppUserProfile> _getDisplayedUsers() {
    final endIndex = (_currentPage + 1) * _pageSize;
    return _filteredUsers.take(endIndex).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text(
          '사용자 관리',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: Color(0xFF111827),
            letterSpacing: -0.2,
          ),
        ),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF111827),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Color(0xFF111827)),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: Color(0xFFE5E7EB)),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refreshData,
          ),
        ],
      ),
      body: Column(
        children: [
          // 검색 및 필터 영역
          _buildFilterSection(),

          // 결과 요약
          _buildResultSummary(),

          // 사용자 목록
          Expanded(
            child: _isLoading
                ? AppLoader.centered()
                : _errorMessage != null
                    ? _buildErrorView()
                    : _filteredUsers.isEmpty
                        ? _buildEmptyView()
                        : _buildUserList(),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterSection() {
    final hasFilters = _searchController.text.isNotEmpty ||
        _selectedDivisionId != null ||
        _selectedTeamId != null ||
        _selectedRole != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Column(
        children: [
          // 검색창
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFFF5F6FA),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '이름 또는 사번으로 검색',
                hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF9CA3AF)),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18, color: Color(0xFF9CA3AF)),
                        onPressed: () {
                          _searchController.clear();
                          _applyFilters();
                        },
                      )
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              style: const TextStyle(fontSize: 13),
              onChanged: _onSearchChanged,
            ),
          ),
          const SizedBox(height: 10),

          // 본부/팀/역할 필터 (DS 대시보드 스타일)
          Row(
            children: [
              Icon(Icons.filter_list, size: 20, color: Colors.grey.shade600),
              const SizedBox(width: 8),
              // 드롭다운 3개 — 좁은 폭(모바일)에서 Row 가 넘치므로 Wrap 으로 감싼다
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    // 본부 드롭다운
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedDivisionId ?? '',
                          isDense: true,
                          dropdownColor: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          icon: Icon(Icons.arrow_drop_down, size: 20, color: Colors.teal.shade400),
                          style: const TextStyle(fontSize: 13, color: Colors.black87),
                          items: [
                            DropdownMenuItem(
                              value: '',
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.select_all, size: 16, color: Colors.teal.shade400),
                                  const SizedBox(width: 8),
                                  const Text('전체 본부'),
                                ],
                              ),
                            ),
                            ..._uniqueDivisions.map((div) => DropdownMenuItem(
                                  value: div,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.business, size: 16, color: Colors.grey.shade500),
                                      const SizedBox(width: 8),
                                      Text(div),
                                    ],
                                  ),
                                )),
                          ],
                          onChanged: (v) => _onDivisionChanged(
                            v != null && v.isNotEmpty ? v : null,
                          ),
                        ),
                      ),
                    ),
                    // 팀 드롭다운
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedTeamId ?? '',
                          isDense: true,
                          dropdownColor: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          icon: Icon(Icons.arrow_drop_down, size: 20, color: Colors.teal.shade400),
                          style: const TextStyle(fontSize: 13, color: Colors.black87),
                          items: [
                            DropdownMenuItem(
                              value: '',
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.select_all, size: 16, color: Colors.teal.shade400),
                                  const SizedBox(width: 8),
                                  const Text('전체 팀'),
                                ],
                              ),
                            ),
                            ..._getTeamsForSelectedDivision().map((team) => DropdownMenuItem(
                                  value: team,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.groups, size: 16, color: Colors.grey.shade500),
                                      const SizedBox(width: 8),
                                      Text(team),
                                    ],
                                  ),
                                )),
                          ],
                          onChanged: (v) => _onTeamChanged(
                            v != null && v.isNotEmpty ? v : null,
                          ),
                        ),
                      ),
                    ),
                    // 역할 드롭다운
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedRole?.name ?? '',
                          isDense: true,
                          dropdownColor: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          icon: Icon(Icons.arrow_drop_down, size: 20, color: Colors.teal.shade400),
                          style: const TextStyle(fontSize: 13, color: Colors.black87),
                          items: [
                            DropdownMenuItem(
                              value: '',
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.select_all, size: 16, color: Colors.teal.shade400),
                                  const SizedBox(width: 8),
                                  const Text('전체 역할'),
                                ],
                              ),
                            ),
                            ..._uniqueRoles.map((role) => DropdownMenuItem(
                                  value: role.name,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(_getRoleIcon(role), size: 16, color: _getRoleColor(role)),
                                      const SizedBox(width: 8),
                                      Text(_getRoleName(role)),
                                    ],
                                  ),
                                )),
                          ],
                          onChanged: (v) => _onRoleChanged(
                            v != null && v.isNotEmpty
                                ? UserRole.values.firstWhere((r) => r.name == v)
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 필터 초기화
              if (hasFilters)
                InkWell(
                  onTap: _clearFilters,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.filter_alt_off, size: 16, color: Colors.grey.shade500),
                        const SizedBox(width: 4),
                        Text('초기화', style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildResultSummary() {
    final adminService = context.read<AdminService>();
    final totalCount = adminService.allUsers.length;
    final filteredCount = _filteredUsers.length;
    final displayedCount = _getDisplayedUsers().length;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Colors.white,
      child: Row(
        children: [
          Text(
            '전체 $totalCount명',
            style: TextStyle(
              color: Colors.grey[600],
              fontSize: 13,
            ),
          ),
          if (filteredCount != totalCount) ...[
            const Text(' / ', style: TextStyle(color: Colors.grey)),
            Text(
              '필터 결과 $filteredCount명',
              style: const TextStyle(
                color: Colors.teal,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          if (_hasMore) ...[
            const Text(' / ', style: TextStyle(color: Colors.grey)),
            Text(
              '$displayedCount명 표시 중',
              style: TextStyle(
                color: Colors.grey[500],
                fontSize: 13,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
          const SizedBox(height: 16),
          Text(
            '데이터 로드 실패',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.red[600],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _errorMessage!,
              style: TextStyle(color: Colors.grey[600]),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _refreshData,
            icon: const Icon(Icons.refresh),
            label: const Text('다시 시도'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyView() {
    final hasFilters = _searchController.text.isNotEmpty ||
        _selectedDivisionId != null ||
        _selectedTeamId != null ||
        _selectedRole != null;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            hasFilters ? Icons.search_off : Icons.people_outline,
            size: 64,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            hasFilters ? '검색 결과가 없습니다.' : '등록된 사용자가 없습니다.',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[600],
            ),
          ),
          if (hasFilters) ...[
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: _clearFilters,
              icon: const Icon(Icons.filter_alt_off),
              label: const Text('필터 초기화'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUserList() {
    final displayedUsers = _getDisplayedUsers();

    return RefreshIndicator(
      onRefresh: _refreshData,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(16),
        itemCount: displayedUsers.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == displayedUsers.length) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: AppLoader.centered(),
            );
          }
          return _buildUserCard(displayedUsers[index]);
        },
      ),
    );
  }

  Widget _buildUserCard(AppUserProfile user) {
    final authService = context.read<AuthService>();
    final isSelf = authService.userId == user.id;
    final canChangeRole = _canChangeUserRole(authService.userRole, user.role, isSelf: isSelf);

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 헤더
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: _getRoleColor(user.role).withValues(alpha: 0.1),
                  child: Icon(
                    _getRoleIcon(user.role),
                    color: _getRoleColor(user.role),
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.name ?? user.id,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        user.email.isNotEmpty ? user.email : user.id,
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildRoleChip(user.role),
              ],
            ),

            // 소속 정보
            if (user.divisionId != null || user.teamId != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.business, size: 16, color: Colors.grey[500]),
                  const SizedBox(width: 4),
                  Text(
                    [user.divisionId, user.teamId]
                        .where((s) => s != null && s.isNotEmpty)
                        .join(' - '),
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ],

            // 마지막 로그인 + 휴면 배지
            const SizedBox(height: 6),
            Row(
              children: [
                if (user.lastLogin != null && user.lastLogin!.isNotEmpty) ...[
                  Icon(Icons.access_time, size: 16, color: Colors.grey[500]),
                  const SizedBox(width: 4),
                  Text(
                    '마지막 로그인: ${_formatLoginTime(user.lastLogin!)}',
                    style: TextStyle(color: Colors.grey[600], fontSize: 12),
                  ),
                ],
                const Spacer(),
                if (user.isDormant)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade100,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orange.shade400),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.bedtime_outlined, size: 13, color: Colors.orange.shade700),
                        const SizedBox(width: 4),
                        Text('휴면', style: TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600,
                            color: Colors.orange.shade700)),
                      ],
                    ),
                  ),
              ],
            ),

            const Divider(height: 24),

            // 권한 변경 + 휴면 해제 버튼
            if (canChangeRole)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (user.isDormant) ...[
                    OutlinedButton.icon(
                      onPressed: () => _undormantUser(user),
                      icon: const Icon(Icons.lock_open_outlined, size: 18),
                      label: const Text('휴면 해제'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.orange,
                        side: const BorderSide(color: Colors.orange),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  OutlinedButton.icon(
                    onPressed: () => _showRoleChangeDialog(user),
                    icon: const Icon(Icons.admin_panel_settings, size: 18),
                    label: const Text('권한 변경'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.teal,
                      side: const BorderSide(color: Colors.teal),
                    ),
                  ),
                ],
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    '권한 변경 불가',
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoleChip(UserRole role) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _getRoleColor(role).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _getRoleName(role),
        style: TextStyle(
          color: _getRoleColor(role),
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  /// 현재 사용자가 대상 사용자의 권한을 변경할 수 있는지 확인
  /// - 본인 권한 이하(같거나 낮음) 사용자만 변경 가능
  /// - 본인 자신은 변경 불가 (자기 강등 방지)
  bool _canChangeUserRole(AppUserRole myRole, UserRole targetRole, {bool isSelf = false}) {
    if (isSelf) return false;
    final myRoleLevel = _getRoleLevel(myRole);
    final targetRoleLevel = _getRoleLevelFromUserRole(targetRole);
    // 본인 권한 이하(같거나 낮음)만 변경 가능
    return myRoleLevel <= targetRoleLevel;
  }

  /// 현재 사용자가 부여할 수 있는 권한 목록 (백엔드 3역할: admin/manager/member)
  /// 본인 권한 이하(같거나 낮음)까지 부여 가능
  List<UserRole> _getAssignableRoles(AppUserRole myRole) {
    switch (myRole) {
      case AppUserRole.superAdmin:
        return [UserRole.superAdmin, UserRole.divisionAdmin, UserRole.member];
      case AppUserRole.divisionAdmin:
        return [UserRole.divisionAdmin, UserRole.member];
      case AppUserRole.teamAdmin:
      case AppUserRole.member:
        return [];
    }
  }

  /// AppUserRole의 권한 레벨 (낮을수록 높은 권한)
  int _getRoleLevel(AppUserRole role) {
    switch (role) {
      case AppUserRole.superAdmin:
        return 0;
      case AppUserRole.divisionAdmin:
        return 1;
      case AppUserRole.teamAdmin:
        return 2;
      case AppUserRole.member:
        return 3;
    }
  }

  /// UserRole의 권한 레벨 (낮을수록 높은 권한)
  int _getRoleLevelFromUserRole(UserRole role) {
    switch (role) {
      case UserRole.superAdmin:
        return 0;
      case UserRole.divisionAdmin:
        return 1;
      case UserRole.teamAdmin:
        return 2;
      case UserRole.member:
        return 3;
    }
  }

  Future<void> _showRoleChangeDialog(AppUserProfile user) async {
    final authService = context.read<AuthService>();
    final assignableRoles = _getAssignableRoles(authService.userRole);

    // 현재 사용자의 역할이 변경 가능한 목록에 없으면 추가 (현재 상태 표시용)
    final allRoles = [...assignableRoles];
    if (!allRoles.contains(user.role)) {
      allRoles.insert(0, user.role);
    }

    UserRole? selectedRole = user.role;

    final result = await showDialog<UserRole>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: Colors.white,
            title: const Text('권한 변경'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${user.name ?? user.id}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 16, color: Colors.blue[700]),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '본인 권한 이하(같거나 낮은)만 부여할 수 있습니다.',
                          style: TextStyle(fontSize: 12, color: Colors.blue[700]),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                ...allRoles.map((role) {
                  final isAssignable = assignableRoles.contains(role);
                  final isCurrentRole = role == user.role;

                  return RadioListTile<UserRole>(
                    title: Row(
                      children: [
                        Text(
                          _getRoleName(role),
                          style: TextStyle(
                            color: isAssignable ? null : Colors.grey[400],
                          ),
                        ),
                        if (isCurrentRole) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.grey[200],
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '현재',
                              style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      _getRoleDescription(role),
                      style: TextStyle(
                        fontSize: 12,
                        color: isAssignable ? Colors.grey[600] : Colors.grey[400],
                      ),
                    ),
                    value: role,
                    groupValue: selectedRole,
                    onChanged: isAssignable
                        ? (value) {
                            setDialogState(() => selectedRole = value);
                          }
                        : null,
                    activeColor: Colors.teal,
                  );
                }),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('취소'),
              ),
              ElevatedButton(
                onPressed: selectedRole != user.role && assignableRoles.contains(selectedRole)
                    ? () => Navigator.pop(ctx, selectedRole)
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                ),
                child: const Text('변경'),
              ),
            ],
          );
        },
      ),
    );

    if (result != null && result != user.role) {
      await _changeUserRole(user, result);
    }
  }

  Future<void> _changeUserRole(AppUserProfile user, UserRole newRole) async {
    final adminService = context.read<AdminService>();
    final d = ProgressDialog(context);
    d.show(message: '권한 변경 중...');
    final success = await adminService.changeUserRole(user.id, newRole);
    if (!mounted) return;
    if (success) {
      await d.complete(message: '${user.name ?? user.id}의 권한이 ${_getRoleName(newRole)}(으)로 변경되었습니다.');
      if (mounted) _applyFilters();
    } else {
      await d.error(message: '권한 변경 실패: ${adminService.errorMessage ?? '알 수 없는 오류'}');
    }
  }

  Future<void> _undormantUser(AppUserProfile user) async {
    final adminService = context.read<AdminService>();
    final d = ProgressDialog(context);
    d.show(message: '휴면 해제 중...');
    final ok = await adminService.undormantUser(user.id);
    if (!mounted) return;
    if (ok) {
      await d.complete(message: '${user.name ?? user.id} 휴면 해제 완료');
    } else {
      await d.error(message: '휴면 해제 실패: ${adminService.errorMessage ?? '알 수 없는 오류'}');
    }
  }

  String _formatLoginTime(String isoStr) {
    try {
      final dt = DateTime.parse(isoStr).toLocal();
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return isoStr;
    }
  }

  Color _getRoleColor(UserRole role) {
    switch (role) {
      case UserRole.superAdmin:
        return Colors.red;
      case UserRole.divisionAdmin:
        return Colors.orange;
      case UserRole.teamAdmin:
        return Colors.blue;
      case UserRole.member:
        return Colors.grey;
    }
  }

  IconData _getRoleIcon(UserRole role) {
    switch (role) {
      case UserRole.superAdmin:
        return Icons.shield;
      case UserRole.divisionAdmin:
        return Icons.business;
      case UserRole.teamAdmin:
        return Icons.groups;
      case UserRole.member:
        return Icons.person;
    }
  }

  String _getRoleName(UserRole role) {
    switch (role) {
      case UserRole.superAdmin:
        return '최고 관리자';
      case UserRole.divisionAdmin:
        return '본부 관리자';
      case UserRole.teamAdmin:
        return '팀 관리자';
      case UserRole.member:
        return '일반 멤버';
    }
  }

  String _getRoleDescription(UserRole role) {
    switch (role) {
      case UserRole.superAdmin:
        return '시스템 전체 관리 권한';
      case UserRole.divisionAdmin:
        return '본부 내 모든 데이터 관리';
      case UserRole.teamAdmin:
        return '팀 내 데이터 관리';
      case UserRole.member:
        return '기본 사용자 권한';
    }
  }
}
