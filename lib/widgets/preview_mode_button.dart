import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';

/// 권한·본부 체험 버튼 (실제 admin 에게만 보인다).
///
/// 다른 권한·본부 계정의 화면을 그대로 확인하기 위한 도구다. 상태는 서버가
/// 토큰에 서명해 담으므로(POST /auth/preview) 모든 요청에 일관되게 적용된다.
/// 실제 role 이 admin 이 아니면 서버가 무시하므로 권한 상승 경로가 아니다.
///
/// 전환 후에는 [onChanged] 로 화면을 다시 로드해야 한다 — 서비스들이 화면 진입
/// 시점에 setAuthToken 으로 토큰을 다시 읽는 구조라 이미 떠 있는 화면은 옛 토큰을
/// 들고 있다.
class PreviewModeButton extends StatelessWidget {
  const PreviewModeButton({super.key, this.onChanged});

  /// 체험 전환이 성공한 뒤 호출된다. 화면 재로드에 사용.
  final VoidCallback? onChanged;

  static const _roles = <String, String>{
    '': 'Admin',
    'manager': 'Manager',
    'member': 'Member',
  };

  Future<void> _apply(
    BuildContext context, {
    required String role,
    required String division,
  }) async {
    final auth = context.read<AuthService>();
    final ok = await auth.setPreview(role: role, division: division);
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('체험 전환에 실패했습니다.')),
      );
      return;
    }
    Navigator.of(context).maybePop();
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    if (!auth.canPreview) return const SizedBox.shrink();

    final active = auth.isPreviewing;
    return Tooltip(
      message: active
          ? '체험 중 — 권한 ${auth.previewRole.isEmpty ? "Admin" : auth.previewRole}'
              ' · 본부 ${auth.previewDivision.isEmpty ? "전체" : auth.previewDivision}'
          : '권한·본부 체험',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openPanel(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF6D28D9) : Colors.transparent,
            border: Border.all(
              color: active ? const Color(0xFF6D28D9) : const Color(0xFFD1D5DB),
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.build_outlined,
                size: 16,
                color: active ? Colors.white : const Color(0xFF4B5563),
              ),
              if (active) ...[
                const SizedBox(width: 6),
                Text(
                  '${auth.previewRole.isEmpty ? "Admin" : auth.previewRole}'
                  '${auth.previewDivision.isEmpty ? "" : " · ${auth.previewDivision}"}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _openPanel(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black26,
      builder: (ctx) {
        final auth = ctx.watch<AuthService>();
        return Dialog(
          alignment: Alignment.topRight,
          insetPadding: const EdgeInsets.only(top: 60, right: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Container(
            width: 260,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.verified_user_outlined,
                        size: 14, color: Color(0xFF6B7280)),
                    SizedBox(width: 6),
                    Text('권한 테스트',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF6B7280))),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: _roles.entries.map((e) {
                    final selected = auth.previewRole == e.key;
                    return ChoiceChip(
                      label: Text(e.value, style: const TextStyle(fontSize: 12)),
                      selected: selected,
                      onSelected: (_) => _apply(ctx,
                          role: e.key, division: auth.previewDivision),
                    );
                  }).toList(),
                ),
                const Divider(height: 22),
                const Row(
                  children: [
                    Icon(Icons.place_outlined, size: 14, color: Color(0xFF6B7280)),
                    SizedBox(width: 6),
                    Text('본부 테스트',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF6B7280))),
                  ],
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: auth.previewDivision.isEmpty
                      ? ''
                      : auth.previewDivision,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(fontSize: 13, color: Colors.black87),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('전체')),
                    ...AuthService.previewDivisions.map(
                      (d) => DropdownMenuItem(value: d, child: Text(d)),
                    ),
                  ],
                  onChanged: (v) => _apply(ctx,
                      role: auth.previewRole, division: v ?? ''),
                ),
                if (auth.isPreviewing) ...[
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: TextButton.icon(
                      onPressed: () => _apply(ctx, role: '', division: ''),
                      icon: const Icon(Icons.restart_alt, size: 16),
                      label: const Text('체험 해제',
                          style: TextStyle(fontSize: 13)),
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                const Text(
                  '권한 Admin 은 전사 범위라 본부 선택이 조회에 반영되지 않습니다.',
                  style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
