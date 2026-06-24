import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/app_widgets.dart';

/// 시스템 안내 — KSA 무선국 정기검사 관리 시스템 사용 안내(정적).
///
/// 콘텐츠 출처: docs/OVERVIEW.md (시스템 소개·역할·워크플로우·기능·FAQ).
/// 내용 갱신은 이 파일을 직접 수정 후 배포한다(정적 내장 방식).
class SystemGuideScreen extends StatelessWidget {
  const SystemGuideScreen({super.key});

  // 워크플로우 상태 배지 색/라벨 (ui-patterns.md 와 동일)
  static const List<_Step> _workflow = [
    _Step('등록됨', '혁신팀이 수검 일정 등록', Color(0xFF6E7780)),
    _Step('사전점검중', '품개팀 전산비교(ERP↔DS) 수행', Color(0xFF6B47DC)),
    _Step('점검완료', '이상 없음 회신 또는 변경개설 통과', Color(0xFF1A8754)),
    _Step('변경개설중', '불일치/누락 → 전파관리소 신고', Color(0xFFE17055)),
    _Step('재점검대기', '신고 후 부분 DS 회신 대기 → 자동 재비교', Color(0xFFE17055)),
    _Step('내역서발급', '검사내역서 발급', Color(0xFF0984E3)),
    _Step('접수완료', '전파관리소 접수번호 입력', Color(0xFF0984E3)),
    _Step('수검완료', '현장 수검 + 결과 입력', Color(0xFF2D3436)),
  ];

  static const List<_RoleRow> _roles = [
    _RoleRow('시스템 관리자', 'admin', '전 본부 조회, 사용자·권한 관리, 데이터 보정'),
    _RoleRow('본부 관리자', 'manager', '자기 본부 데이터 + 결과장 업로드 + DS 업로드/삭제'),
    _RoleRow('일반 사용자', 'member', '자기 팀 데이터 조회, 현장 수검, 검사 결과 입력'),
  ];

  static const List<_MenuGuide> _menus = [
    _MenuGuide('현장 수검 Map', Icons.map_outlined, Color(0xFF3B82F6),
        '본인 담당 수검 대상을 지도에서 확인. "수검가능" 토글로 접수 완료 건만 표시, 경로 계획·내비(Tmap/카카오) 연동.'),
    _MenuGuide('일정 및 통계', Icons.event_note_outlined, Color(0xFF10B981),
        '수검 일정 등록·조회, 워크플로우 상태 관리(묶음 단위 일괄 처리), 매트릭스 현황.'),
    _MenuGuide('실적 관리', Icons.bar_chart_outlined, Color(0xFFE53935),
        '전국 9개 본부 진도율·합격율 대시보드, 분기/월/주차 추이, 장비타입별 분석, 결과장 엑셀 다운로드.'),
    _MenuGuide('DS 데이터', Icons.storage_outlined, Color(0xFF8B5CF6),
        '전파관리소 DS 데이터 조회·필터·다운로드(수도권 본부별 분리 지원).'),
    _MenuGuide('전산비교', Icons.compare_outlined, Color(0xFF2563EB),
        'ERP 데이터와 DS 데이터를 설치형태·일련번호로 자동 비교, 변경개설 필요 건 식별.'),
    _MenuGuide('설치확인서 · 호출명칭 · 시설물 사진', Icons.folder_outlined, Color(0xFFEF4444),
        '서류 관리 그룹 — 허가번호/호출명칭 조회·설치확인서 생성, 호출명칭 매칭, 본부/팀/국소별 시설점검 사진 검색.'),
    _MenuGuide('커뮤니티', Icons.forum_outlined, Color(0xFFE53935),
        '공지사항·요청사항 게시판(비밀글·댓글 지원).'),
  ];

  static const List<_Faq> _faqs = [
    _Faq('다른 본부 데이터를 볼 수 있나요?',
        '개별 무선국 운영 데이터(일정·검사결과 등)는 본인 본부/팀까지만 보입니다. '
        '실적·DS 집계 통계는 전 직원이 전국을 비교 조회할 수 있습니다. 시스템 관리자는 전사 조회가 가능합니다.'),
    _Faq('현장에서 인터넷이 안 되면 어떻게 하나요?',
        '현재는 온라인 사용을 전제로 합니다. 모바일 데이터 환경에서 동작하며, 오프라인 임시 저장은 검토 대상입니다.'),
    _Faq('사진은 어디에 저장되나요?',
        'AWS S3 클라우드에 안전하게 저장되며, 본인이 입력한 검사 결과 화면에서 조회할 수 있습니다.'),
    _Faq('검사내역서 양식은 정해진 양식인가요?',
        '기존 전파관리소 제출 양식과 동일한 엑셀이 자동 생성됩니다(시트명·셀 폭·테두리까지 동일).'),
    _Faq('알림은 어디서 확인하나요?',
        '우상단 종 아이콘에서 확인합니다. 안 읽은 알림이 있으면 로그인 직후 자동 팝업이 뜨며, '
        '"안 읽음만" 필터를 해제하면 전체 이력을 볼 수 있습니다.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgPage,
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _hero(),
                const SizedBox(height: 16),
                _intro(),
                const SizedBox(height: 16),
                _rolesCard(),
                const SizedBox(height: 16),
                _workflowCard(),
                const SizedBox(height: 16),
                _menusCard(),
                const SizedBox(height: 16),
                _dashboardCard(),
                const SizedBox(height: 16),
                _faqCard(),
                const SizedBox(height: 16),
                _contactCard(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 헤더 ──────────────────────────────────────────────
  Widget _hero() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          colors: [Color(0xFFE53935), Color(0xFFB71C1C)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.cell_tower, color: Colors.white, size: 28),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '무선국 정기검사 관리 시스템',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            '연간 수검 일정 등록부터 현장 수검 완료까지, N/W계획팀·N/W혁신팀·품질개선팀이 '
            '같은 시스템에서 논스톱으로 협업하는 통합 관리 시스템입니다.',
            style: TextStyle(color: Colors.white, fontSize: 13, height: 1.5),
          ),
        ],
      ),
    );
  }

  // ── 도입 배경 ──────────────────────────────────────────
  Widget _intro() {
    return _section('이 시스템은 무엇인가요?', Icons.lightbulb_outline, AppColors.orange, [
      _para('기존에는 수검대상 공지 → 검토 → 서류 현행화 → 현장 실사 → 수검까지 '
          '6단계마다 팀 간 엑셀을 주고받아(핸드오프 3회 이상) 데이터 일관성과 진행 현황 파악이 어려웠습니다.'),
      const SizedBox(height: 8),
      _para('이 시스템은 그 모든 과정을 한 곳에서 관리합니다. 세 팀이 같은 화면을 보며 협업하고, '
          '현재 어느 단계인지·누가 처리해야 하는지·어디가 지연됐는지를 실시간으로 확인합니다.'),
    ]);
  }

  // ── 역할/권한 ──────────────────────────────────────────
  Widget _rolesCard() {
    return _section('역할과 권한', Icons.people_outline, AppColors.blue, [
      for (final r in _roles) ...[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Row(
                children: [
                  Flexible(
                    child: Text(r.nameKr,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textDark)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            AppBadge(text: r.code, color: AppColors.blue),
            const SizedBox(width: 12),
            Expanded(
              child: Text(r.scope, style: AppTextStyles.caption),
            ),
          ],
        ),
        if (r != _roles.last) const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Divider(height: 1, color: AppColors.border),
        ),
      ],
    ]);
  }

  // ── 워크플로우 ─────────────────────────────────────────
  Widget _workflowCard() {
    return _section('수검 워크플로우 (한 건이 거치는 길)', Icons.account_tree_outlined, AppColors.green, [
      _para('각 단계는 화면에 색상 배지로 표시되며, 클릭 한 번으로 해당 상태 건만 모아 볼 수 있습니다.'),
      const SizedBox(height: 12),
      for (final s in _workflow) ...[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: s.color,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(s.label,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(s.desc, style: AppTextStyles.body),
              ),
            ),
          ],
        ),
        if (s != _workflow.last)
          const Padding(
            padding: EdgeInsets.only(left: 8, top: 4, bottom: 4),
            child: Icon(Icons.arrow_downward, size: 14, color: AppColors.textLight),
          ),
      ],
      const SizedBox(height: 8),
      _para('불합격/부적합이면 "재점검 필요" 플래그가 자동 표시되어 혁신팀이 재점검 일정을 등록할 수 있습니다.'),
    ]);
  }

  // ── 메뉴별 안내 ────────────────────────────────────────
  Widget _menusCard() {
    return _section('메뉴별 기능 안내', Icons.apps_outlined, AppColors.blue, [
      for (final m in _menus) ...[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: m.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(m.icon, size: 18, color: m.color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.title, style: AppTextStyles.sectionTitle),
                  const SizedBox(height: 3),
                  Text(m.desc, style: AppTextStyles.caption),
                ],
              ),
            ),
          ],
        ),
        if (m != _menus.last)
          const SizedBox(height: 14),
      ],
    ]);
  }

  // ── 대시보드/알림 ──────────────────────────────────────
  Widget _dashboardCard() {
    return _section('"내 할 일" 대시보드 & 알림', Icons.dashboard_outlined, AppColors.orange, [
      _para('홈 화면에 현재 본인이 처리해야 할 일이 한눈에 표시됩니다. 역할에 따라 전사/본부/팀 범위로 자동 분기되며, '
          '상태 카드를 클릭하면 해당 건만 필터링되어 일정 화면으로 이동합니다.'),
      const SizedBox(height: 10),
      _para('각 단계가 기준 일수를 넘기면 "지연"으로 강조됩니다 — '
          '사전점검중 5일 · 변경개설중 3일 · 재점검대기 7일 · 내역서발급 3일 · 접수완료 14일.'),
      const SizedBox(height: 10),
      _para('다음 단계 담당자에게 시스템 내 알림이 자동 발송되며(우상단 종 아이콘), '
          '안 읽은 알림이 있으면 로그인 직후 팝업으로 안내합니다.'),
    ]);
  }

  // ── FAQ ───────────────────────────────────────────────
  Widget _faqCard() {
    return AppCard(
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: _titleRow('자주 묻는 질문', Icons.help_outline, AppColors.green),
          ),
          for (final f in _faqs)
            Theme(
              data: ThemeData(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 12),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                title: Text(f.q, style: AppTextStyles.sectionTitle),
                iconColor: AppColors.primary,
                collapsedIconColor: AppColors.textLight,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(f.a, style: AppTextStyles.body.copyWith(height: 1.5)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ── 문의 ──────────────────────────────────────────────
  Widget _contactCard() {
    return _section('문의', Icons.support_agent_outlined, AppColors.blue, [
      _para('• 시스템 관련: AT/DT추진담당'),
      const SizedBox(height: 4),
      _para('• 도메인/운영 관련: N/W혁신팀 · 품질개선팀'),
      const SizedBox(height: 4),
      _para('• 권한/계정 관련: 시스템 관리자'),
    ]);
  }

  // ── 공통 헬퍼 ──────────────────────────────────────────
  Widget _section(String title, IconData icon, Color color, List<Widget> children) {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(title, icon, color),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _titleRow(String title, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: AppTextStyles.pageTitle)),
      ],
    );
  }

  Widget _para(String text) =>
      Text(text, style: AppTextStyles.body.copyWith(height: 1.55));
}

class _Step {
  final String label;
  final String desc;
  final Color color;
  const _Step(this.label, this.desc, this.color);
}

class _RoleRow {
  final String nameKr;
  final String code;
  final String scope;
  const _RoleRow(this.nameKr, this.code, this.scope);
}

class _MenuGuide {
  final String title;
  final IconData icon;
  final Color color;
  final String desc;
  const _MenuGuide(this.title, this.icon, this.color, this.desc);
}

class _Faq {
  final String q;
  final String a;
  const _Faq(this.q, this.a);
}
