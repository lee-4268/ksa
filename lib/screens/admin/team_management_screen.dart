import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/admin_service.dart';
import '../../services/team_context_service.dart';

/// 팀 관리 화면
class TeamManagementScreen extends StatefulWidget {
  const TeamManagementScreen({super.key});

  @override
  State<TeamManagementScreen> createState() => _TeamManagementScreenState();
}

class _TeamManagementScreenState extends State<TeamManagementScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final teamContext = context.read<TeamContextService>();
    await teamContext.loadDivisions();
    await teamContext.loadAllTeams();
  }

  Future<void> _showCreateDivisionDialog() async {
    final nameController = TextEditingController();
    final codeController = TextEditingController();
    final descController = TextEditingController();
    String? errorMessage;
    bool isLoading = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Colors.white,
          title: const Text('본부 생성'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      errorMessage!,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '본부명',
                    hintText: '예: 혁신팀',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: codeController,
                  decoration: const InputDecoration(
                    labelText: '본부 코드',
                    hintText: '예: INNOVATION (영문, 그룹명에 사용)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descController,
                  decoration: const InputDecoration(
                    labelText: '설명 (선택)',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isLoading ? null : () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            ElevatedButton(
              onPressed: isLoading
                  ? null
                  : () async {
                      if (nameController.text.isEmpty || codeController.text.isEmpty) {
                        setDialogState(() {
                          errorMessage = '본부명과 본부 코드를 모두 입력해주세요.';
                        });
                        return;
                      }

                      setDialogState(() {
                        isLoading = true;
                        errorMessage = null;
                      });

                      final adminService = context.read<AdminService>();
                      final divisionId = await adminService.createDivision(
                        name: nameController.text,
                        code: codeController.text.toUpperCase(),
                        description: descController.text.isEmpty ? null : descController.text,
                      );

                      if (divisionId != null) {
                        Navigator.pop(ctx, true);
                      } else {
                        setDialogState(() {
                          isLoading = false;
                          errorMessage = adminService.errorMessage ?? '본부 생성에 실패했습니다.';
                        });
                      }
                    },
              child: isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('생성'),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('본부가 생성되었습니다.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  Future<void> _showCreateTeamDialog(Division division) async {
    final nameController = TextEditingController();
    final codeController = TextEditingController();
    final descController = TextEditingController();
    String? errorMessage;
    bool isLoading = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Colors.white,
          title: Text('${division.name} 팀 생성'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (errorMessage != null) ...[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      errorMessage!,
                      style: const TextStyle(color: Colors.red, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: '팀명',
                    hintText: '예: 1팀',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: codeController,
                  decoration: const InputDecoration(
                    labelText: '팀 코드',
                    hintText: '예: TEAM1 (영문, 그룹명에 사용)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: descController,
                  decoration: const InputDecoration(
                    labelText: '설명 (선택)',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: isLoading ? null : () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            ElevatedButton(
              onPressed: isLoading
                  ? null
                  : () async {
                      if (nameController.text.isEmpty || codeController.text.isEmpty) {
                        setDialogState(() {
                          errorMessage = '팀명과 팀 코드를 모두 입력해주세요.';
                        });
                        return;
                      }

                      setDialogState(() {
                        isLoading = true;
                        errorMessage = null;
                      });

                      final adminService = context.read<AdminService>();
                      final teamId = await adminService.createTeam(
                        divisionId: division.id,
                        name: nameController.text,
                        code: codeController.text.toUpperCase(),
                        description: descController.text.isEmpty ? null : descController.text,
                      );

                      if (teamId != null) {
                        Navigator.pop(ctx, true);
                      } else {
                        setDialogState(() {
                          isLoading = false;
                          errorMessage = adminService.errorMessage ?? '팀 생성에 실패했습니다.';
                        });
                      }
                    },
              child: isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('생성'),
            ),
          ],
        ),
      ),
    );

    if (result == true) {
      _loadData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('팀이 생성되었습니다.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('팀 관리'),
        backgroundColor: const Color(0xFFE53935),
        foregroundColor: Colors.white,
        bottom: TabBar(
          controller: _tabController,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          tabs: const [
            Tab(text: '본부'),
            Tab(text: '팀'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildDivisionsTab(),
          _buildTeamsTab(),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (_tabController.index == 0) {
            _showCreateDivisionDialog();
          } else {
            _showSelectDivisionForTeam();
          }
        },
        child: const Icon(Icons.add),
      ),
    );
  }

  void _showSelectDivisionForTeam() {
    final teamContext = context.read<TeamContextService>();
    final divisions = teamContext.availableDivisions;

    if (divisions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('먼저 본부를 생성해주세요.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      builder: (ctx) => ListView.builder(
        shrinkWrap: true,
        itemCount: divisions.length,
        itemBuilder: (_, index) {
          final division = divisions[index];
          return ListTile(
            leading: const Icon(Icons.business),
            title: Text(division.name),
            subtitle: Text(division.code),
            onTap: () {
              Navigator.pop(ctx);
              _showCreateTeamDialog(division);
            },
          );
        },
      ),
    );
  }

  Widget _buildDivisionsTab() {
    final teamContext = context.watch<TeamContextService>();
    final divisions = teamContext.availableDivisions;

    if (teamContext.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (divisions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.business, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              '등록된 본부가 없습니다.',
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            const Text(
              '+ 버튼을 눌러 본부를 생성하세요.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: divisions.length,
        itemBuilder: (ctx, index) {
          final division = divisions[index];
          return _buildDivisionCard(division);
        },
      ),
    );
  }

  Widget _buildDivisionCard(Division division) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: Colors.blue.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.business, color: Colors.blue),
        ),
        title: Text(
          division.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('코드: ${division.code}'),
            if (division.description != null)
              Text(
                division.description!,
                style: TextStyle(color: Colors.grey[600], fontSize: 12),
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.add, color: Colors.blue),
              onPressed: () => _showCreateTeamDialog(division),
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: () => _showDeleteDivisionDialog(division),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTeamsTab() {
    final teamContext = context.watch<TeamContextService>();
    final teams = teamContext.availableTeams;

    if (teamContext.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (teams.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.groups, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              '등록된 팀이 없습니다.',
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 8),
            const Text(
              '먼저 본부를 생성한 후 팀을 추가하세요.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    // 본부별로 팀 그룹핑
    final teamsByDivision = <String, List<Team>>{};
    for (final team in teams) {
      final divisionName = team.division?.name ?? '미지정';
      teamsByDivision.putIfAbsent(divisionName, () => []);
      teamsByDivision[divisionName]!.add(team);
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: teamsByDivision.entries.map((entry) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  entry.key,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.indigo,
                  ),
                ),
              ),
              ...entry.value.map((team) => _buildTeamCard(team)),
              const SizedBox(height: 8),
            ],
          );
        }).toList(),
      ),
    );
  }

  Widget _buildTeamCard(Team team) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.teal.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.groups, color: Colors.teal, size: 20),
        ),
        title: Text(team.name),
        subtitle: Text('코드: ${team.code}'),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.red),
          onPressed: () => _showDeleteTeamDialog(team),
        ),
      ),
    );
  }

  Future<void> _showDeleteTeamDialog(Team team) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('팀 삭제'),
        content: Text('${team.name}을(를) 삭제하시겠습니까?\n\n이 작업은 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final adminService = context.read<AdminService>();
    final success = await adminService.deleteTeam(team.id);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '${team.name} 삭제됨' : '삭제 실패: ${adminService.errorMessage}'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );

      if (success) {
        _loadData();
      }
    }
  }

  Future<void> _showDeleteDivisionDialog(Division division) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('본부 삭제'),
        content: Text('${division.name}을(를) 삭제하시겠습니까?\n\n이 작업은 되돌릴 수 없습니다.\n하위 팀도 모두 삭제됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('삭제'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final adminService = context.read<AdminService>();
    final success = await adminService.deleteDivision(division.id);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '${division.name} 삭제됨' : '삭제 실패: ${adminService.errorMessage}'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );

      if (success) {
        _loadData();
      }
    }
  }
}
