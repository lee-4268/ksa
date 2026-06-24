import 'package:flutter/material.dart';

/// 시스템 안내 — KCA/KSA 무선국 관리 시스템 기능 안내(정적, 초심자용).
///
/// 콘텐츠 구성: 메뉴 그룹별(수검 관리 / 허가현황 관리 / 서류 관리 / 커뮤니티)
/// 프로세스 흐름 + STEP 카드 + 단계 설명 + 상태칩 + 팁.
/// 내용 갱신은 이 파일을 직접 수정 후 배포한다(정적 내장).
/// (스크린샷은 추후 assets 로 추가 가능 — 현재는 텍스트·구조 중심)
class SystemGuideScreen extends StatelessWidget {
  const SystemGuideScreen({super.key});

  // 참고 안내 페이지와 동일한 색 체계
  static const _primary = Color(0xFF1A56DB);
  static const _primaryLight = Color(0xFFEFF4FF);
  static const _green = Color(0xFF0D9F6E);
  static const _greenLight = Color(0xFFECFDF5);
  static const _orange = Color(0xFFD97706);
  static const _orangeLight = Color(0xFFFFFBEB);
  static const _red = Color(0xFFDC2626);
  static const _redLight = Color(0xFFFEF2F2);
  static const _purple = Color(0xFF7C3AED);
  static const _purpleLight = Color(0xFFF5F3FF);
  static const _sky = Color(0xFF0284C7);
  static const _skyLight = Color(0xFFF0F9FF);
  static const _text = Color(0xFF1E293B);
  static const _muted = Color(0xFF64748B);
  static const _border = Color(0xFFE2E8F0);
  static const _surface2 = Color(0xFFF0F4F8);
  static const _bg = Color(0xFFF5F7FA);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SingleChildScrollView(
        child: Column(
          children: [
            _hero(),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 28, 16, 40),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _sectionInspection(),
                      _sectionDivider(),
                      _sectionDs(),
                      _sectionDivider(),
                      _sectionDocs(),
                      _sectionDivider(),
                      _sectionCommunity(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ════ HERO ════
  Widget _hero() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1A56DB), Color(0xFF1E40AF), Color(0xFF4338CA)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
            ),
            child: const Text('무선국 정기검사 관리 시스템',
                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
          ),
          const SizedBox(height: 18),
          const Text('기능 안내',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: -0.5)),
          const SizedBox(height: 14),
          const Text(
            '연간 수검 대상 등록부터 현장 수검 완료까지 — 처음 사용하시는 분도\n'
            '메뉴 순서대로 따라오시면 전체 업무 흐름을 익힐 수 있습니다.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.7),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: const [
              _HeroCard('4', '메뉴 그룹'),
              _HeroCard('5', '수검 STEP'),
              _HeroCard('3', '역할 권한'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionDivider() => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Divider(height: 1, color: _border),
      );

  // ════ 1. 수검 관리 ════
  Widget _sectionInspection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _groupHeader('메뉴 ① · 수검 관리', '📋', '수검 관리',
            '연간 수검 대상 등록부터 현장 수검 완료까지, 수검 업무의 전 과정을 하나의 흐름으로 관리합니다.',
            ['일정 및 대상 관리', '실적관리', '수검 Map']),
        const SizedBox(height: 20),
        _processFlow(),
        const SizedBox(height: 20),
        _card(
          location: '수검 관리 ▸ 일정 및 대상 관리',
          roleFlag: 'Admin 권한',
          stepBadge: ('STEP 1', _primary),
          emoji: '📋', iconBg: _primaryLight,
          title: '연간 수검 대상 업로드',
          sub: 'KCA로부터 받은 연간 수검 대상 파일을 등록합니다',
          desc: 'KCA에서 전달받은 연간 수검 대상 엑셀을 업로드하면, 시스템이 ERP와 자동 매칭하여 통시코드를 자동으로 채웁니다. 등록된 대상은 [일정 및 대상 관리]에서 확인할 수 있습니다.',
          steps: const [
            'KCA 제공 연간 수검 대상 XLSX 업로드',
            'ERP 매칭 자동 실행 → 통시코드 자동 입력',
            '[일정 및 대상 관리]에서 등록 결과 확인 (국소별 허가현황·로드뷰·시설DB 사진 조회 가능)',
          ],
          warning: ('통시코드 미매칭 국소 처리',
              '자동 매칭이 안 된 국소는 [수검검토]에서 개별 처리합니다. 장비 검색(시설명·망구분·주파수)으로 최적의 통합시설코드를 추천받아 수동 매칭합니다.'),
        ),
        _card(
          location: '수검 관리 ▸ 일정 및 대상 관리',
          stepBadge: ('STEP 2', _primary),
          extraBadge: ('→ 사전점검중', _sky),
          emoji: '📅', iconBg: _skyLight,
          title: '일정 등록',
          sub: '수검 예정 일정을 배정하면 상태가 [사전점검중]으로 전환됩니다',
          desc: '등록된 수검 대상에 예정 일정을 배정합니다. 일정을 등록하는 순간 해당 국소의 상태가 사전점검중으로 자동 업데이트됩니다.',
          steps: const [
            '대상 국소 선택 후 월/주차 선택 (필수)',
            '조 / 검사관 입력 (필요 시)',
            '등록 완료 → 상태 자동 변경 [사전점검중]',
          ],
        ),
        _card(
          location: '수검 관리 ▸ 실적관리 ▸ 수검 분석',
          stepBadge: ('STEP 3 · 사전점검', _sky),
          spotlight: _primary,
          emoji: '📈', iconBg: _primaryLight,
          title: '분석 — 사전점검',
          spotBadge: ('⭐ 핵심 기능', _primary, _primaryLight),
          sub: '일정 등록된 대상을 자동 비교 분석하여 현황 이상 여부를 확인합니다',
          desc: '일정이 등록된 국소를 선택하고 「분석」을 클릭하면, KCA 허가현황(DS)과 ERP 시스템현황을 자동 비교합니다. 설치대·일련번호 불일치 항목과 알람을 즉시 확인할 수 있습니다.',
          steps: const [
            '분석 대상 국소 선택',
            '「분석」 클릭 → 설치대·일련번호 자동 비교, 알람 조회',
            '결과 확인 → 수정 불필요면 STEP 4-1 점검완료, 변경 필요면 STEP 4-2 변경개설 요청으로 분기',
          ],
          chips: const [('✅ 일치', _green), ('❌ 불일치', _red), ('🟡 확인필요', _orange)],
        ),
        _branchHeader('STEP 4 · 분석 결과에 따라 분기'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _card(
                location: '수검 관리 ▸ 수검 분석',
                stepBadge: ('STEP 4-1 · 수정 불필요', _green),
                topBorder: _green,
                emoji: '✅', iconBg: _greenLight,
                title: '점검완료 처리',
                sub: '현황 수정이 필요 없을 때',
                desc: '분석 결과 수정 사항이 없으면 「점검완료」를 클릭합니다. 상태가 즉시 점검완료로 바뀌고 실 수검(STEP 5)을 진행할 수 있습니다.',
                steps: const ['분석 화면에서 「점검완료」 클릭', '상태 자동 변경 [점검완료]'],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _card(
                location: '수검 관리 ▸ 수검 분석',
                stepBadge: ('STEP 4-2 · 변경개설 필요', _orange),
                topBorder: _orange,
                emoji: '📝', iconBg: _orangeLight,
                title: '변경개설신고 요청',
                sub: '현황 수정이 필요할 때',
                desc: '현황 수정이 필요하면 변경개설신고를 요청합니다. 본부 담당자가 신고를 완료하면 상태가 재점검 대기로 전환되고, 다시 분석 → 점검완료 흐름을 거칩니다.',
                steps: const [
                  '해당 대상 선택 후 「변경개설신고 요청」 클릭',
                  '변경 항목·실 확인 데이터 입력 후 요청 제출',
                  '[서류관리] ▸ [변경개설신고]에서 본부 담당자가 신고·완료',
                  '완료 시 상태 자동 변경 [재점검 대기] → 다시 분석',
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _card(
          location: '수검 관리 ▸ 실적관리',
          stepBadge: ('STEP 5 · 최종', _primary),
          extraBadge: ('→ 수검완료', _green),
          emoji: '🏁', iconBg: _greenLight,
          title: '수검완료 — 수검 결과 입력',
          sub: '점검완료된 국소를 현장 수검 후 결과를 입력합니다',
          desc: '점검완료 상태의 국소를 현장 수검한 뒤 결과를 입력합니다. 결과가 입력되면 상태가 수검완료로 최종 업데이트됩니다.',
          steps: const [
            '점검완료된 국소 현장 수검 진행',
            '수검 결과 입력 — 합격 / 불합격 / 시기조정 선택',
            '입력 완료 시 상태 자동 변경 [수검완료]',
          ],
          chips: const [('✅ 합격', _green), ('❌ 불합격', _red), ('⏰ 시기조정', _orange)],
          tip: '불합격 결과 입력 시 [서류관리] ▸ [부적합 관리]에 자동 등록되고 담당자 알림이 발송됩니다.',
        ),
        _card(
          location: '수검 관리 ▸ 실적관리 ▸ 수검 결과 입력',
          extraBadge: ('보조 기능', _purple),
          spotlight: _purple,
          emoji: '🤖', iconBg: _purpleLight,
          title: 'AI 철탑형태 분류',
          spotBadge: ('⭐ AI 핵심 기능', _purple, _purpleLight),
          sub: '사진 한 장으로 철탑·안테나 설치형태를 자동 판별',
          desc: '수검 결과 입력 시 철탑/안테나 사진을 올리면 AI가 설치형태를 자동 분석해 상위 후보(Top 5)와 신뢰도(%)를 제시합니다. 육안 분류 작업을 AI가 보조합니다.',
          steps: const [
            '수검 결과 입력 화면에서 「철탑형태 분석하기」 클릭',
            '사진 직접 업로드 또는 시설DB 사진에서 선택',
            'AI 분석 결과(Top 5 + 신뢰도) 확인 후 「확인」 → 결과 자동 입력',
          ],
          tip: '결과는 담당자가 최종 확인·수정할 수 있습니다. 신뢰도가 낮으면 직접 선택을 권장합니다.',
        ),
        _card(
          location: '수검 관리 ▸ 수검 Map',
          emoji: '🗺️', iconBg: _primaryLight,
          title: '전국 수검 진행 현황 지도',
          sub: '수검 프로세스 상태를 지도에서 한눈에 확인합니다',
          desc: '수검 대상 국소를 지도에 표시하고 각 상태(사전점검중·점검완료·수검완료 등)를 색으로 구분합니다. 본부·팀·검색어로 필터링할 수 있습니다.',
          steps: const [
            '연도 선택 → 해당 연도 수검 대상이 지도에 표시',
            '본부·팀 드롭다운, 검색어로 원하는 국소 필터링',
            '마커 클릭 → 국소별 상세 정보 및 현재 수검 상태 확인',
          ],
          chips: const [
            ('사전점검중', _primary), ('변경개설중', _orange), ('재점검 대기', _purple),
            ('점검완료', _green), ('수검완료', _sky),
          ],
          tip: '본인 본부가 지정된 담당자·매니저는 자동으로 본인 본부 필터로 표시됩니다.',
        ),
      ],
    );
  }

  // ════ 2. 허가현황 관리 ════
  Widget _sectionDs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _groupHeader('메뉴 ② · 허가현황 관리', '🗄️', '허가현황 관리',
            'KCA 무선국 인허가 원장 데이터(DS)를 올리고, 조회하고, 합칩니다.',
            ['DS 데이터', 'DS 병합']),
        const SizedBox(height: 16),
        _notice('DS란?',
            '한국방송통신전파진흥원(KCA)이 관리하는 무선국 인허가 원장 데이터입니다. 여러 시트가 묶인 큰 엑셀로 제공되며, 시스템에 올리면 DB에 저장되어 언제든 조회·비교·내보내기가 가능합니다.'),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _card(
                location: '허가현황 관리 ▸ DS 데이터',
                roleFlag: '업로드: Manager+',
                emoji: '📂', iconBg: _primaryLight,
                title: 'DS 올리기 & 보기',
                sub: '원장 파일을 등록하고 조회합니다',
                desc: 'KCA에서 받은 엑셀을 올리면 백그라운드에서 자동 정리·저장됩니다. 파일이 커도 진행률(%)이 실시간 표시됩니다. 저장 후 본부별 필터·시트 탭으로 보고 XLSX로 다시 내려받을 수 있습니다.',
                steps: const [
                  'DS 파일 업로드 — 진행률 실시간 확인',
                  '완료 알림 후 DS 목록에서 데이터 확인',
                  '본부 필터·시트 탭 탐색, 필요 시 XLSX 내보내기',
                ],
                tip: '큰 파일도 백그라운드 처리되므로 다른 업무를 계속해도 됩니다.',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _card(
                location: '허가현황 관리 ▸ DS 병합',
                roleFlag: 'Manager+',
                emoji: '🔗', iconBg: _purpleLight,
                title: '여러 DS 파일 합치기',
                sub: '중복은 자동으로 정리합니다',
                desc: '여러 번 올린 DS 파일을 시트별로 하나로 합칩니다. 같은 무선국(허가번호)이 중복되면 자동 제거하여 통합 XLSX로 내려받습니다.',
                steps: const [
                  'DS 병합 화면에서 합칠 업로드 항목 선택',
                  '병합 실행 — 허가번호 기준 중복 자동 제거',
                  '통합 결과 XLSX 다운로드',
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ════ 3. 서류 관리 ════
  Widget _sectionDocs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _groupHeader('메뉴 ③ · 서류 관리', '📁', '서류 관리',
            '데이터 매칭·비교부터 확인서 발급, 부적합·변경신고 추적, 시설물 사진 조회까지 — 문서·데이터 정합성 기능을 모았습니다.',
            ['호출명칭', '전산비교', '설치확인서', '부적합 관리', '변경개설신고', '시설물 사진']),
        const SizedBox(height: 16),
        _card(
          spotlight: _green,
          emoji: '📑', iconBg: _greenLight,
          title: '서류 자동 생성',
          spotBadge: ('⭐ 자동화 핵심 기능', _green, _greenLight),
          sub: '손으로 작성하던 공식 문서를 양식에 맞춰 자동으로 만들어 줍니다',
          desc: '시스템에 쌓인 무선국 데이터를 그대로 활용해 아래 세 가지 문서를 자동 생성합니다. 옮겨 적으며 생기던 시간 낭비와 실수를 줄입니다.',
          miniCards: const [
            ('📄 설치확인서 (PDF/HWP)', ['허가번호로 정보 조회 후 즉시 발급', '목록 업로드 시 일괄 생성 → ZIP', '현장 사진 자동 첨부 가능']),
            ('📝 변경개설신고서', ['변경 내역+DS 파일로 자동 작성', '추가/삭제/변경 항목 자동 강조']),
            ('📊 검사 결과 보고서', ['수검 일정·실적 기반 PDF 보고서', '상태별·지역별 집계 자동 반영']),
          ],
          tip: '각 문서의 상세 발급 절차는 아래 설치확인서·변경개설신고 항목에서 이어집니다.',
        ),
        _card(
          location: '서류 관리 ▸ 호출명칭',
          emoji: '📡', iconBg: _skyLight,
          title: '호출명칭 자동 매칭',
          sub: '이름만 있는 엑셀에 허가번호·주소를 자동으로 채웁니다',
          desc: '호출명칭(무선국 이름)이 적힌 엑셀을 올리면 시스템이 해당 칸을 자동으로 찾아 무선국 번호·주소·설치대 수 등을 채워 결과 엑셀로 만들어 줍니다. 진행 상황은 실시간 표시됩니다.',
          steps: const [
            '호출명칭이 포함된 엑셀 업로드',
            '시스템이 호출명칭 칸 자동 감지',
            '(선택) 통시코드·담당자 등 필터 조건 지정',
            '매칭 실행 — 실시간 진행률 확인 후 병합 XLSX 다운로드',
          ],
        ),
        _card(
          location: '서류 관리 ▸ 전산비교',
          emoji: '🔄', iconBg: _orangeLight,
          title: '데이터 비교 (KCA 허가현황 ↔ SKT 시스템현황)',
          sub: '두 시스템의 무선국 정보가 일치하는지 대조합니다',
          desc: '확인할 무선국 번호 목록을 입력하거나 파일로 올리면 호출명칭·주소·설치대 수·허가상태 등을 항목별로 비교합니다. 결과는 일치/부분일치/불일치/확인필요로 분류되어 표로 내려받습니다. (화면·사용법은 분석 기능과 동일)',
          steps: const [
            '허가번호 목록 직접 입력 또는 파일 업로드',
            '비교 실행 — 항목별 일치 여부 자동 분석',
            '결과 테이블에서 불일치 항목 확인·조치, 필요 시 내보내기',
          ],
          chips: const [('✅ 일치', _green), ('🟡 부분일치', _orange), ('❌ 불일치', _red), ('❓ 확인필요', _muted)],
          tip: '확인된 불일치 건은 변경개설신고로 이어집니다.',
        ),
        _card(
          location: '서류 관리 ▸ 설치확인서',
          emoji: '📄', iconBg: _greenLight,
          title: '설치확인서 발급',
          spotBadge: ('📑 자동 생성', _green, _greenLight),
          sub: '무선국 설치 완료를 증명하는 공식 문서',
          desc: '손으로 작성하던 확인서를 자동 발급합니다. 한 건씩 즉시 발급하거나 목록을 올려 한꺼번에 ZIP으로 발급할 수 있습니다.',
          miniCards: const [
            ('📄 한 건씩 발급', ['무선국 번호 입력 → 정보 조회', 'PDF 또는 HWP 선택 후 즉시 발급']),
            ('📦 여러 건 일괄 발급', ['번호 목록 XLSX 업로드', '(선택) 사진 ZIP 첨부 — 폴더명은 허가번호', '일괄 생성 후 ZIP 다운로드']),
          ],
          tip: '사진 ZIP 구조는 반드시 {허가번호}/파일명 형식이어야 합니다.',
        ),
        _card(
          location: '서류 관리 ▸ 부적합 관리',
          emoji: '⚠️', iconBg: _redLight,
          title: '부적합(불합격) 건 추적·관리',
          sub: '시정이 끝날 때까지 따라갑니다',
          desc: '검사에서 불합격 판정을 받은 무선국은 자동으로 목록에 올라오고 알림이 발송됩니다. 연도·지역·팀·상태로 걸러 보고, 표에서 바로 상태를 바꾸거나 심의차수를 관리합니다.',
          steps: const [
            '불합격 건 자동 등록 + 알림 수신',
            '연도·지역·팀·상태 필터로 조회',
            '시정 완료 시 인라인으로 상태 변경, 심의차수 업데이트',
            '필요한 조건으로 걸러 XLSX 내보내기',
          ],
          chips: const [('미완료', _red), ('완료', _green)],
        ),
        _card(
          location: '서류 관리 ▸ 변경개설신고',
          emoji: '📝', iconBg: _orangeLight,
          title: '변경개설신고 문서 관리',
          spotBadge: ('📑 자동 생성', _green, _greenLight),
          sub: '무선국 제원이 바뀌었을 때 내는 신고 서류',
          desc: '변경 내역 파일과 DS 파일을 올리면 변경개설신고에 필요한 문서를 자동 생성합니다. 변경 요청 목록은 연도·상태별로 관리하고, 완료 건은 묶어서 일괄 처리합니다.',
          steps: const [
            '변경개설내역 파일(A) 업로드',
            '최신 DS 파일(B) 업로드',
            '추가/삭제/변경 행을 색상으로 구분해 확인',
            '변경 요청 목록을 상태별로 추적, 완료 건 번들 처리',
          ],
          chips: const [('대기중', _orange), ('처리중', _primary), ('완료', _green)],
        ),
        _card(
          location: '서류 관리 ▸ 시설물 사진 조회',
          emoji: '🖼️', iconBg: _skyLight,
          title: '시설물 사진 검색·조회',
          sub: '현장 점검 사진을 빠르게 찾습니다',
          desc: '본부·팀·국소명·주소로 시설물 사진을 검색해 조회합니다. 시설물 점검·위험성평가 등 분류별 사진을 한 화면에서 확인할 수 있습니다.',
          steps: const [
            '본부·팀·국소명·주소 등 검색 조건 입력',
            '검색 결과에서 국소 선택',
            '분류별 시설물 사진 확인',
          ],
        ),
      ],
    );
  }

  // ════ 4. 커뮤니티 ════
  Widget _sectionCommunity() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _groupHeader('메뉴 ④ · 커뮤니티', '💬', '커뮤니티',
            '업무 소통을 위한 공간입니다.', ['공지사항', '요청/문의']),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _card(
                emoji: '📢', iconBg: _primaryLight,
                title: '공지사항',
                sub: '본부별 공지를 올리고 봅니다',
                desc: '본부별 공지를 등록·열람합니다. 조회수가 자동으로 기록됩니다.',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _card(
                emoji: '💬', iconBg: _greenLight,
                title: '요청 / 문의',
                sub: '요청을 등록하고 댓글로 소통합니다',
                desc: '요청을 등록하고 접수·처리중·완료 상태별로 확인하며 댓글로 소통합니다.',
                chips: const [('접수', _orange), ('처리중', _primary), ('완료', _green)],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _notice('🔔 실시간 알림',
            'DS 가져오기 완료, 검사 완료, 부적합 발생 같은 이벤트가 생기면 상단 종 아이콘에 알림이 쌓입니다. 읽지 않은 개수가 숫자로 표시되며, 하나씩 또는 전체를 읽음 처리할 수 있습니다.'),
      ],
    );
  }

  // ════════ 공통 빌더 ════════

  Widget _groupHeader(String eyebrow, String emoji, String name, String desc, List<String> chips) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 8),
          child: Text(eyebrow,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _primary, letterSpacing: 1.2)),
        ),
        Row(
          children: [
            Container(
              width: 46, height: 46,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: _primaryLight, borderRadius: BorderRadius.circular(11)),
              child: Text(emoji, style: const TextStyle(fontSize: 22)),
            ),
            const SizedBox(width: 14),
            Text(name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: _text, letterSpacing: -0.3)),
          ],
        ),
        const SizedBox(height: 10),
        Text(desc, style: const TextStyle(fontSize: 14, color: _muted, height: 1.6)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6, runSpacing: 6,
          children: [
            for (final c in chips)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: _surface2, borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _border),
                ),
                child: Text(c, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _muted)),
              ),
          ],
        ),
      ],
    );
  }

  Widget _processFlow() {
    const nodes = <(String, String, String, Color, bool)>[
      ('📋', '일정등록', 'STEP 1–2', _primary, false),
      ('🔍', '사전점검중', 'STEP 3', _sky, false),
      ('📝', '변경개설중', '필요시만', _orange, true),
      ('🔄', '재점검 대기', '필요시만', _purple, true),
      ('✅', '점검완료', 'STEP 4', _green, false),
      ('🏁', '수검완료', 'STEP 5', _primary, false),
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('수검 프로세스 전체 흐름',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _muted)),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < nodes.length; i++) ...[
                  _flowNode(nodes[i]),
                  if (i < nodes.length - 1)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: Icon(Icons.arrow_forward, size: 16, color: Color(0xFFCBD5E1)),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Text('* 변경개설중·재점검 대기 단계는 변경개설 신고가 필요할 때만 거칩니다.',
              style: TextStyle(fontSize: 11, color: _muted)),
        ],
      ),
    );
  }

  Widget _flowNode((String, String, String, Color, bool) n) {
    final (emoji, label, sub, color, dim) = n;
    return SizedBox(
      width: 92,
      child: Column(
        children: [
          Opacity(
            opacity: dim ? 0.65 : 1,
            child: Container(
              width: 44, height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: Text(emoji, style: const TextStyle(fontSize: 18)),
            ),
          ),
          const SizedBox(height: 8),
          Text(label, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _text)),
          const SizedBox(height: 2),
          Text(sub, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 10, color: _muted)),
        ],
      ),
    );
  }

  Widget _branchHeader(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          const Expanded(child: Divider(color: _border)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(text, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _muted)),
          ),
          const Expanded(child: Divider(color: _border)),
        ],
      ),
    );
  }

  Widget _notice(String title, String body) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: BoxDecoration(
        color: _primaryLight, borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(fontSize: 13, color: Color(0xFF1240A8), height: 1.6),
          children: [
            TextSpan(text: '$title  ', style: const TextStyle(fontWeight: FontWeight.w700)),
            TextSpan(text: body),
          ],
        ),
      ),
    );
  }

  /// 기능 카드. 대부분 옵션은 nullable/기본값.
  Widget _card({
    String? location,
    String? roleFlag,
    (String, Color)? stepBadge,
    (String, Color)? extraBadge,
    Color? spotlight,
    Color? topBorder,
    required String emoji,
    Color iconBg = _primaryLight,
    required String title,
    (String, Color, Color)? spotBadge,
    String? sub,
    required String desc,
    List<String> steps = const [],
    List<(String, Color)> chips = const [],
    List<(String, List<String>)> miniCards = const [],
    String? tip,
    (String, String)? warning,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: spotlight != null
            ? Border.all(color: spotlight, width: 2)
            : Border.all(color: _border),
        boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (topBorder != null)
            Container(margin: const EdgeInsets.only(bottom: 12), height: 3, width: 48,
                decoration: BoxDecoration(color: topBorder, borderRadius: BorderRadius.circular(2))),
          // location + badges
          if (location != null || stepBadge != null || extraBadge != null || roleFlag != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(
                spacing: 6, runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (location != null)
                    Text(location, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _muted)),
                  if (roleFlag != null)
                    Text('· $roleFlag', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _orange)),
                  if (stepBadge != null) _solidBadge(stepBadge.$1, stepBadge.$2),
                  if (extraBadge != null) _solidBadge(extraBadge.$1, extraBadge.$2),
                ],
              ),
            ),
          // header
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44, height: 44, alignment: Alignment.center,
                decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(10)),
                child: Text(emoji, style: const TextStyle(fontSize: 22)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _text)),
                        if (spotBadge != null) _softBadge(spotBadge.$1, spotBadge.$2, spotBadge.$3),
                      ],
                    ),
                    if (sub != null) ...[
                      const SizedBox(height: 3),
                      Text(sub, style: const TextStyle(fontSize: 12, color: _muted)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(desc, style: const TextStyle(fontSize: 13, color: _muted, height: 1.7)),
          if (steps.isNotEmpty) ...[
            const SizedBox(height: 14),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 22, height: 22, alignment: Alignment.center,
                      decoration: const BoxDecoration(color: _primaryLight, shape: BoxShape.circle),
                      child: Text('${i + 1}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _primary)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(steps[i], style: const TextStyle(fontSize: 13, color: _text, height: 1.5)),
                    )),
                  ],
                ),
              ),
          ],
          if (miniCards.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final m in miniCards)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(8)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(m.$1, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _text)),
                    const SizedBox(height: 6),
                    for (final li in m.$2)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text('· $li', style: const TextStyle(fontSize: 12, color: _muted, height: 1.5)),
                      ),
                  ],
                ),
              ),
          ],
          if (chips.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [for (final c in chips) _softBadge(c.$1, c.$2, c.$2.withValues(alpha: 0.12))]),
          ],
          if (warning != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _orangeLight, borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFDE68A)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('⚠️ ${warning.$1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _orange)),
                  const SizedBox(height: 6),
                  Text(warning.$2, style: const TextStyle(fontSize: 12, color: Color(0xFF92400E), height: 1.6)),
                ],
              ),
            ),
          ],
          if (tip != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: _primaryLight, borderRadius: BorderRadius.circular(8)),
              child: Text('💡 $tip', style: const TextStyle(fontSize: 12, color: Color(0xFF1240A8), height: 1.6)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _solidBadge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
      );

  Widget _softBadge(String text, Color fg, Color bg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
      );
}

class _HeroCard extends StatelessWidget {
  final String num;
  final String label;
  const _HeroCard(this.num, this.label);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
      ),
      child: Column(
        children: [
          Text(num, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900, height: 1)),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
        ],
      ),
    );
  }
}
