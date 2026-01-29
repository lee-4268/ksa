import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/auth_service.dart';
import '../../services/admin_service.dart';
import '../../services/team_context_service.dart';

/// 사용자 승인/관리 화면
class UserApprovalScreen extends StatefulWidget {
  final bool showAllUsers;

  const UserApprovalScreen({
    super.key,
    this.showAllUsers = false,
  });

  @override
  State<UserApprovalScreen> createState() => _UserApprovalScreenState();
}

class _UserApprovalScreenState extends State<UserApprovalScreen> {
  String? _selectedTeamId;
  List<Team> _teams = [];
  bool _isLoadingTeams = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final adminService = context.read<AdminService>();
    final teamContext = context.read<TeamContextService>();

    if (widget.showAllUsers) {
      await adminService.loadAllUsers();
    } else {
      await adminService.loadPendingUsers();
    }

    // 팀 목록 로드
    setState(() => _isLoadingTeams = true);
    await teamContext.loadAllTeams();
    setState(() {
      _teams = teamContext.availableTeams;
      _isLoadingTeams = false;
    });
  }

  Future<void> _approveUser(AppUserProfile user) async {
    if (_selectedTeamId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('팀을 선택해주세요.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final selectedTeam = _teams.firstWhere((t) => t.id == _selectedTeamId);
    final divisionId = selectedTeam.divisionId;

    final adminService = context.read<AdminService>();
    final authService = context.read<AuthService>();

    final success = await adminService.approveUser(
      profileId: user.id,
      teamId: _selectedTeamId!,
      divisionId: divisionId,
      approverUserId: authService.userId ?? '',
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '${user.name ?? user.email} 승인 완료' : '승인 실패'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }

    _selectedTeamId = null;
  }

  Future<void> _rejectUser(AppUserProfile user) async {
    final reason = await _showRejectDialog();
    if (reason == null) return;

    final adminService = context.read<AdminService>();
    final success = await adminService.rejectUser(
      profileId: user.id,
      reason: reason,
    );

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '${user.name ?? user.email} 거부됨' : '거부 실패'),
          backgroundColor: success ? Colors.orange : Colors.red,
        ),
      );
    }
  }

  Future<String?> _showRejectDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('거부 사유'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '거부 사유를 입력하세요',
            border: OutlineInputBorder(),
          ),
          maxLines: 3,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('거부'),
          ),
        ],
      ),
    );
  }

  Future<void> _suspendUser(AppUserProfile user) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('사용자 정지'),
        content: Text('${user.name ?? user.email}님을 정지하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('정지'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final adminService = context.read<AdminService>();
    final success = await adminService.suspendUser(user.id, '관리자 정지');

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '${user.name ?? user.email} 정지됨' : '정지 실패'),
          backgroundColor: success ? Colors.orange : Colors.red,
        ),
      );
    }
  }

  Future<void> _restoreUser(AppUserProfile user) async {
    final adminService = context.read<AdminService>();
    final success = await adminService.restoreUser(user.id);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '${user.name ?? user.email} 복원됨' : '복원 실패'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final adminService = context.watch<AdminService>();

    final users = widget.showAllUsers
        ? adminService.allUsers
        : adminService.pendingUsers;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.showAllUsers ? '사용자 관리' : '사용자 승인'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
      ),
      body: adminService.isLoading
          ? const Center(child: CircularProgressIndicator())
          : users.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        widget.showAllUsers ? Icons.people : Icons.check_circle,
                        size: 64,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        widget.showAllUsers
                            ? '등록된 사용자가 없습니다.'
                            : '승인 대기 중인 사용자가 없습니다.',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadData,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: users.length,
                    itemBuilder: (ctx, index) {
                      final user = users[index];
                      return _buildUserCard(user);
                    },
                  ),
                ),
    );
  }

  Widget _buildUserCard(AppUserProfile user) {
    final isPending = user.status == UserStatus.pending;
    final isSuspended = user.status == UserStatus.suspended;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 헤더
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: _getStatusColor(user.status).withValues(alpha: 0.1),
                  child: Icon(
                    Icons.person,
                    color: _getStatusColor(user.status),
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
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        user.email,
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                _buildStatusChip(user.status),
              ],
            ),
            const Divider(height: 24),

            // 정보
            if (user.phoneNumber != null)
              _buildInfoRow('연락처', user.phoneNumber!),
            if (user.team != null)
              _buildInfoRow('소속', '${user.team!.division?.name ?? ''} - ${user.team!.name}'),
            _buildInfoRow('역할', _getRoleName(user.role)),

            // 승인 대기 중인 경우 팀 선택
            if (isPending) ...[
              const SizedBox(height: 16),
              _isLoadingTeams
                  ? const Center(child: CircularProgressIndicator())
                  : DropdownButtonFormField<String>(
                      value: _selectedTeamId,
                      decoration: const InputDecoration(
                        labelText: '배정할 팀 선택',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                      items: _teams.map((team) {
                        return DropdownMenuItem(
                          value: team.id,
                          child: Text(
                            '${team.division?.name ?? ''} - ${team.name}',
                          ),
                        );
                      }).toList(),
                      onChanged: (value) {
                        setState(() => _selectedTeamId = value);
                      },
                    ),
            ],

            const SizedBox(height: 16),

            // 버튼
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isPending) ...[
                  OutlinedButton(
                    onPressed: () => _rejectUser(user),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                    ),
                    child: const Text('거부'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => _approveUser(user),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                    ),
                    child: const Text('승인'),
                  ),
                ] else if (isSuspended) ...[
                  ElevatedButton.icon(
                    onPressed: () => _restoreUser(user),
                    icon: const Icon(Icons.restore),
                    label: const Text('복원'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                    ),
                  ),
                ] else if (user.status == UserStatus.approved) ...[
                  OutlinedButton.icon(
                    onPressed: () => _suspendUser(user),
                    icon: const Icon(Icons.block),
                    label: const Text('정지'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: TextStyle(
                color: Colors.grey[600],
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusChip(UserStatus status) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _getStatusColor(status).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        _getStatusName(status),
        style: TextStyle(
          color: _getStatusColor(status),
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Color _getStatusColor(UserStatus status) {
    switch (status) {
      case UserStatus.pending:
        return Colors.orange;
      case UserStatus.approved:
        return Colors.green;
      case UserStatus.rejected:
        return Colors.red;
      case UserStatus.suspended:
        return Colors.grey;
    }
  }

  String _getStatusName(UserStatus status) {
    switch (status) {
      case UserStatus.pending:
        return '대기 중';
      case UserStatus.approved:
        return '승인됨';
      case UserStatus.rejected:
        return '거부됨';
      case UserStatus.suspended:
        return '정지됨';
    }
  }

  String _getRoleName(UserRole role) {
    switch (role) {
      case UserRole.superAdmin:
        return '최고 관리자';
      case UserRole.divisionAdmin:
        return '부서 관리자';
      case UserRole.teamAdmin:
        return '팀 관리자';
      case UserRole.member:
        return '일반 멤버';
    }
  }
}
