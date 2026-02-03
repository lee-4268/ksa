import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/auth_service.dart';
import '../../services/admin_service.dart';
import '../../services/team_context_service.dart';

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

  // 데이터
  List<Division> _divisions = [];
  Map<String, List<Team>> _teamsByDivision = {};
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
      final adminService = context.read<AdminService>();
      final teamContext = context.read<TeamContextService>();

      // 본부/팀 목록 로드
      await teamContext.loadDivisions();
      await teamContext.loadAllTeams();

      // 본부별 팀 그룹핑
      final allTeams = teamContext.availableTeams;
      final groupedTeams = <String, List<Team>>{};
      for (final team in allTeams) {
        groupedTeams.putIfAbsent(team.divisionId, () => []);
        groupedTeams[team.divisionId]!.add(team);
      }

      // 사용자 목록 로드
      await adminService.loadAllUsers();

      setState(() {
        _divisions = teamContext.availableDivisions;
        _teamsByDivision = groupedTeams;
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
      final aName = a.name ?? a.email;
      final bName = b.name ?? b.email;
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

  void _onSearchChanged(String query) {
    _applyFilters();
  }

  void _clearFilters() {
    setState(() {
      _searchController.clear();
      _selectedDivisionId = null;
      _selectedTeamId = null;
    });
    _applyFilters();
  }

  List<Team> _getTeamsForSelectedDivision() {
    if (_selectedDivisionId == null) return [];
    return _teamsByDivision[_selectedDivisionId] ?? [];
  }

  List<AppUserProfile> _getDisplayedUsers() {
    final endIndex = (_currentPage + 1) * _pageSize;
    return _filteredUsers.take(endIndex).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('사용자 관리'),
        backgroundColor: const Color(0xFFE53935),
        foregroundColor: Colors.white,
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
                ? const Center(child: CircularProgressIndicator())
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
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        border: Border(
          bottom: BorderSide(color: Colors.grey[200]!),
        ),
      ),
      child: Column(
        children: [
          // 검색창
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: '이름 또는 이메일로 검색',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        _applyFilters();
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            onChanged: _onSearchChanged,
          ),
          const SizedBox(height: 12),

          // 본부/팀 필터
          Row(
            children: [
              // 본부 선택
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _selectedDivisionId,
                  dropdownColor: Colors.white,
                  decoration: InputDecoration(
                    labelText: '본부',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('전체 본부'),
                    ),
                    ..._divisions.map((division) {
                      return DropdownMenuItem(
                        value: division.id,
                        child: Text(division.name),
                      );
                    }),
                  ],
                  onChanged: (value) => _onDivisionChanged(
                    value?.isEmpty == true ? null : value,
                  ),
                ),
              ),
              const SizedBox(width: 12),

              // 팀 선택
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: _selectedTeamId,
                  dropdownColor: Colors.white,
                  decoration: InputDecoration(
                    labelText: '팀',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    filled: true,
                    fillColor: _selectedDivisionId != null
                        ? Colors.white
                        : Colors.grey[100],
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('전체 팀'),
                    ),
                    ..._getTeamsForSelectedDivision().map((team) {
                      return DropdownMenuItem(
                        value: team.id,
                        child: Text(team.name),
                      );
                    }),
                  ],
                  onChanged: _selectedDivisionId != null
                      ? (value) => _onTeamChanged(
                            value?.isEmpty == true ? null : value,
                          )
                      : null,
                  hint: Text(
                    _selectedDivisionId == null ? '본부 먼저 선택' : '팀 선택',
                    style: TextStyle(color: Colors.grey[500]),
                  ),
                ),
              ),
            ],
          ),

          // 필터 초기화 버튼
          if (_searchController.text.isNotEmpty ||
              _selectedDivisionId != null ||
              _selectedTeamId != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _clearFilters,
                  icon: const Icon(Icons.filter_alt_off, size: 18),
                  label: const Text('필터 초기화'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildResultSummary() {
    final adminService = context.watch<AdminService>();
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
        _selectedTeamId != null;

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
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          return _buildUserCard(displayedUsers[index]);
        },
      ),
    );
  }

  Widget _buildUserCard(AppUserProfile user) {
    final authService = context.read<AuthService>();
    final canChangeRole = _canChangeUserRole(authService.userRole, user.role);

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
                        user.name ?? '이름 없음',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        user.email,
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
            if (user.team != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.business, size: 16, color: Colors.grey[500]),
                  const SizedBox(width: 4),
                  Text(
                    '${user.team!.division?.name ?? ''} - ${user.team!.name}',
                    style: TextStyle(
                      color: Colors.grey[600],
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ],

            const Divider(height: 24),

            // 권한 변경 버튼 (권한이 있는 경우에만 표시)
            if (canChangeRole)
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
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
  /// - 자신보다 하위 권한을 가진 사용자만 변경 가능
  /// - 자기 자신이나 동급/상위 권한자는 변경 불가
  bool _canChangeUserRole(AppUserRole myRole, UserRole targetRole) {
    final myRoleLevel = _getRoleLevel(myRole);
    final targetRoleLevel = _getRoleLevelFromUserRole(targetRole);

    // 자신보다 하위 권한만 변경 가능 (동급 이상은 불가)
    return myRoleLevel < targetRoleLevel;
  }

  /// 현재 사용자가 부여할 수 있는 권한 목록 반환
  /// - 최고관리자: 본부관리자, 팀관리자, 일반멤버
  /// - 본부관리자: 팀관리자, 일반멤버
  /// - 팀관리자: 일반멤버
  /// - 일반멤버: 없음
  List<UserRole> _getAssignableRoles(AppUserRole myRole) {
    switch (myRole) {
      case AppUserRole.superAdmin:
        return [UserRole.divisionAdmin, UserRole.teamAdmin, UserRole.member];
      case AppUserRole.divisionAdmin:
        return [UserRole.teamAdmin, UserRole.member];
      case AppUserRole.teamAdmin:
        return [UserRole.member];
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
                  '${user.name ?? user.email}',
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
                          '본인보다 하위 권한만 부여할 수 있습니다.',
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
    final success = await adminService.changeUserRole(user.id, newRole);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success
                ? '${user.name ?? user.email}의 권한이 ${_getRoleName(newRole)}(으)로 변경되었습니다.'
                : '권한 변경 실패: ${adminService.errorMessage}',
          ),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );

      if (success) {
        _applyFilters();
      }
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
