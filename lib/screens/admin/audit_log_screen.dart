import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../services/audit_service.dart';

/// 감사 로그 화면
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key});

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  List<AuditLogEntry> _logs = [];
  bool _isLoading = false;
  String? _filterEntityType;
  AuditAction? _filterAction;

  final _dateFormat = DateFormat('yyyy-MM-dd HH:mm');

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() => _isLoading = true);

    final auditService = context.read<AuditService>();
    final logs = await auditService.listAuditLogs(
      entityType: _filterEntityType,
      action: _filterAction,
      limit: 100,
    );

    setState(() {
      _logs = logs;
      _isLoading = false;
    });
  }

  Future<void> _confirmRollback(AuditLogEntry log) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('롤백 확인'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('이 변경 사항을 롤백하시겠습니까?'),
            const SizedBox(height: 16),
            Text(
              '대상: ${log.entityType}',
              style: const TextStyle(fontSize: 14),
            ),
            Text(
              '작업: ${_getActionName(log.action)}',
              style: const TextStyle(fontSize: 14),
            ),
            Text(
              '시간: ${_dateFormat.format(log.timestamp.toLocal())}',
              style: const TextStyle(fontSize: 14),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('롤백'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final auditService = context.read<AuditService>();
    final success = await auditService.rollback(log.id);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? '롤백 완료' : '롤백 실패'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );

      if (success) {
        _loadLogs();
      }
    }
  }

  void _showFilterDialog() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '필터',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // 엔티티 타입 필터
            DropdownButtonFormField<String>(
              value: _filterEntityType,
              decoration: const InputDecoration(
                labelText: '엔티티 타입',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: null, child: Text('전체')),
                DropdownMenuItem(value: 'UserProfile', child: Text('사용자')),
                DropdownMenuItem(value: 'TeamInspectionData', child: Text('검사 데이터')),
                DropdownMenuItem(value: 'MasterStation', child: Text('무선국')),
                DropdownMenuItem(value: 'Division', child: Text('부서')),
                DropdownMenuItem(value: 'Team', child: Text('팀')),
              ],
              onChanged: (value) {
                setState(() => _filterEntityType = value);
              },
            ),
            const SizedBox(height: 12),

            // 액션 필터
            DropdownButtonFormField<AuditAction?>(
              value: _filterAction,
              decoration: const InputDecoration(
                labelText: '작업 유형',
                border: OutlineInputBorder(),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('전체')),
                ...AuditAction.values.map((action) => DropdownMenuItem(
                      value: action,
                      child: Text(_getActionName(action)),
                    )),
              ],
              onChanged: (value) {
                setState(() => _filterAction = value);
              },
            ),
            const SizedBox(height: 16),

            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      _filterEntityType = null;
                      _filterAction = null;
                    });
                    Navigator.pop(ctx);
                    _loadLogs();
                  },
                  child: const Text('초기화'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _loadLogs();
                  },
                  child: const Text('적용'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('감사 로그'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list),
            onPressed: _showFilterDialog,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _logs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.history,
                        size: 64,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '로그가 없습니다.',
                        style: TextStyle(
                          fontSize: 16,
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadLogs,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _logs.length,
                    itemBuilder: (ctx, index) {
                      final log = _logs[index];
                      return _buildLogCard(log);
                    },
                  ),
                ),
    );
  }

  Widget _buildLogCard(AuditLogEntry log) {
    final isRolledBack = log.rolledBackAt != null;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: isRolledBack ? Colors.grey[100] : null,
      child: ExpansionTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: _getActionColor(log.action).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            _getActionIcon(log.action),
            color: _getActionColor(log.action),
            size: 20,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                '${log.entityType} - ${_getActionName(log.action)}',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  decoration: isRolledBack ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            if (isRolledBack)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.grey,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '롤백됨',
                  style: TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '사용자: ${log.userEmail ?? log.userId}',
              style: const TextStyle(fontSize: 12),
            ),
            Text(
              '시간: ${_dateFormat.format(log.timestamp.toLocal())}',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 변경된 필드
                if (log.changedFields != null && log.changedFields!.isNotEmpty) ...[
                  const Text(
                    '변경된 필드:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: log.changedFields!
                        .map((field) => Chip(
                              label: Text(field, style: const TextStyle(fontSize: 11)),
                              backgroundColor: Colors.blue.withValues(alpha: 0.1),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                ],

                // 변경 내용 (이전 → 이후)
                if (log.previousData != null || log.newData != null) ...[
                  const Text(
                    '변경 내용:',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  _buildChangesTable(log),
                  const SizedBox(height: 16),
                ],

                // 롤백 버튼
                if (log.canRollback && !isRolledBack)
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton.icon(
                      onPressed: () => _confirmRollback(log),
                      icon: const Icon(Icons.undo, size: 18),
                      label: const Text('롤백'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChangesTable(AuditLogEntry log) {
    final previous = log.previousData ?? {};
    final current = log.newData ?? {};
    final allKeys = {...previous.keys, ...current.keys};

    if (allKeys.isEmpty) {
      return const Text('변경 내용 없음', style: TextStyle(color: Colors.grey));
    }

    return Table(
      border: TableBorder.all(color: Colors.grey[300]!),
      columnWidths: const {
        0: FlexColumnWidth(1),
        1: FlexColumnWidth(1.5),
        2: FlexColumnWidth(1.5),
      },
      children: [
        TableRow(
          decoration: BoxDecoration(color: Colors.grey[200]),
          children: const [
            Padding(
              padding: EdgeInsets.all(8),
              child: Text('필드', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
            Padding(
              padding: EdgeInsets.all(8),
              child: Text('이전', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
            Padding(
              padding: EdgeInsets.all(8),
              child: Text('이후', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            ),
          ],
        ),
        ...allKeys.where((key) => previous[key] != current[key]).map((key) => TableRow(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(key, style: const TextStyle(fontSize: 11)),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    _formatValue(previous[key]),
                    style: const TextStyle(fontSize: 11, color: Colors.red),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    _formatValue(current[key]),
                    style: const TextStyle(fontSize: 11, color: Colors.green),
                  ),
                ),
              ],
            )),
      ],
    );
  }

  String _formatValue(dynamic value) {
    if (value == null) return '-';
    if (value is Map || value is List) {
      return const JsonEncoder.withIndent('  ').convert(value);
    }
    return value.toString();
  }

  String _getActionName(AuditAction action) {
    switch (action) {
      case AuditAction.create:
        return '생성';
      case AuditAction.update:
        return '수정';
      case AuditAction.delete:
        return '삭제';
      case AuditAction.approve:
        return '승인';
      case AuditAction.reject:
        return '거부';
      case AuditAction.suspend:
        return '정지';
      case AuditAction.restore:
        return '복원';
      case AuditAction.rollback:
        return '롤백';
      case AuditAction.login:
        return '로그인';
      case AuditAction.logout:
        return '로그아웃';
    }
  }

  Color _getActionColor(AuditAction action) {
    switch (action) {
      case AuditAction.create:
        return Colors.green;
      case AuditAction.update:
        return Colors.blue;
      case AuditAction.delete:
        return Colors.red;
      case AuditAction.approve:
        return Colors.green;
      case AuditAction.reject:
        return Colors.red;
      case AuditAction.suspend:
        return Colors.orange;
      case AuditAction.restore:
        return Colors.teal;
      case AuditAction.rollback:
        return Colors.purple;
      case AuditAction.login:
        return Colors.indigo;
      case AuditAction.logout:
        return Colors.grey;
    }
  }

  IconData _getActionIcon(AuditAction action) {
    switch (action) {
      case AuditAction.create:
        return Icons.add_circle;
      case AuditAction.update:
        return Icons.edit;
      case AuditAction.delete:
        return Icons.delete;
      case AuditAction.approve:
        return Icons.check_circle;
      case AuditAction.reject:
        return Icons.cancel;
      case AuditAction.suspend:
        return Icons.block;
      case AuditAction.restore:
        return Icons.restore;
      case AuditAction.rollback:
        return Icons.undo;
      case AuditAction.login:
        return Icons.login;
      case AuditAction.logout:
        return Icons.logout;
    }
  }
}
