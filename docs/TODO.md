# TODO — 작업 목록

## 최종 업데이트: 2026-05-12

---

## 완료 — 수검 워크플로우 Phase 1~5 (2026-05-08~12)

상세 설계: [`inspection_workflow_roadmap.md`](inspection_workflow_roadmap.md)

### Phase 1: 상태 머신 + 사전점검 (2026-05-08)
- ~~상태 머신 8단계 + 권한 매트릭스~~ ✓ — `_wf_can_transition`, `_wf_record_log_sync`
- ~~`inspection_schedules`에 workflow_status/log/pre_check_result 컬럼~~ ✓
- ~~전산비교 화면에 schedule_pk 연동 + 이상없음 회신 버튼~~ ✓
- ~~일정 화면 상태 배지 + 사전점검 의뢰 다중 선택 액션~~ ✓
- ~~기수 비교 제거 + DS누락 분류 추가~~ ✓

### Phase 2: 변경개설 분기 (2026-05-08)
- ~~`change_request` 테이블 + 변경 4항목 다이얼로그~~ ✓
- ~~A파일 자동 생성 (xls 즉시 응답) + 묶음 단위 다운로드~~ ✓
- ~~`/ds/apply-partial-update` 부분 DS 패치 + 자동 재비교~~ ✓
- ~~CHANGE_FILING → RE_CHECK → PRE_CHECK_DONE 흐름 완성~~ ✓

### Phase 3: 검사내역서 발급 + 접수 트래킹 (2026-05-12)
- ~~`POST /inspection/report/generate` + 기존 빌더 재활용~~ ✓
- ~~`PATCH /inspection/schedule/{pk}/submission` + 일괄 입력 API~~ ✓
- ~~워크플로우 매트릭스 확장: REGISTERED → REPORT_ISSUED 직행 허용~~ ✓
- ~~발급 직후 접수번호 일괄 입력 다이얼로그 (스킵 가능)~~ ✓
- ~~상태 무관 발급 허용 (수검완료 건 포함, 역행 방지)~~ ✓

### Phase 4: 현장 수검 결과 자동 연결 (2026-05-12)
- ~~`inspection_results`에 schedule_pk + needs_recheck 컬럼 + 백필~~ ✓
- ~~/inspection/result POST 자동 전환 + 불합격 시 needs_recheck~~ ✓
- ~~/inspection/schedules LEFT JOIN으로 needs_recheck/result_status 노출~~ ✓
- ~~일정 화면 재점검 필요 배지 + 토글 칩~~ ✓
- ~~현장수검 Map 수검가능 토글 (기본 SUBMITTED 이상만)~~ ✓
- ~~검사결과 컬럼 INSPECTED 미만 숨김 (두 status 분리)~~ ✓

### Phase 5: 시스템 알림 + 역할별 대시보드 (2026-05-12)
- ~~`notifications` 테이블 + 워크플로우 전환 자동 알림 (7종)~~ ✓
- ~~알림 조회/안 읽음 카운트/일괄 읽음 API~~ ✓
- ~~우상단 종 아이콘 + 60초 폴링 + 안 읽음 빨간 배지~~ ✓
- ~~로그인 자동 팝업 + '오늘은 더이상 보지 않기' (SharedPreferences)~~ ✓
- ~~역할별 대시보드 (admin=전사 / manager=본부 / member=팀)~~ ✓
- ~~SLA 임계점 하드코딩 + 지연 건 강조~~ ✓
- ~~홈 화면 "내 할 일" 섹션 (커뮤니티 ↔ 바로가기 사이)~~ ✓
- ~~대시보드 카드 클릭 → 일정화면 자동 필터링~~ ✓
- ~~일정 메뉴 기본 탭 변경 (매트릭스 → 수검대상)~~ ✓

### 이번 페이즈 제외 (Phase 5.x 또는 향후)
- 이메일/Slack/Teams/모바일 푸시 알림
- SLA 매일 새벽 배치 워커 (현재는 대시보드 조회 시 실시간 계산)
- 전파관리소 시스템 자동 동기화
- 본부/팀 매핑 정교화 — 현재는 일정 등록자 위주 단순 룰
- Phase 6: 성능 점검 통합 (사내망 반출 정책 확정 후)

---

## 완료

### 버그 수정
- ~~#1 member 권한 수검결과 저장 제한~~ ✓ — 일정및통계에서 member는 수검관리 화면 버튼 숨김
- ~~#6 전국 수검 현황 Map 지역 강조 버그~~ ✓
  - ValueKey에서 selectedRegion 제거 → 클릭 즉시 색상 반영
  - DashboardScreen에 selectedRegion prop 추가, didUpdateWidget으로 외부 필터와 지도 선택 동기화
- ~~#12 현장 수검 Map 뒤로가기 멈춤~~ ✓ — Navigator.canPop 체크, pop 불가 시 버튼 숨김
- ~~#14 팀 배정 없는 테스트계정에 타 팀 국소 보이는 문제~~ ✓
  - _dev_users에 등록된 계정은 팀 무관 전체 조회 (is_dev 분기)
  - 실계정은 access담당 AND 품질개선팀 AND 조건 유지

### UI 개선
- ~~#2 수검 결과 저장 시 ProgressDialog 적용~~ ✓
- ~~#3 전체 드롭다운 UI 통일~~ ✓ — DropdownButtonHideUnderline 패턴 전체 적용
- ~~#4 현장 수검 Map UI 정리~~ ✓ — 년도 버튼 제거, PopupMenu → DropdownButton
- ~~#7 현황 리포트 달성/미달성 배경색 인라인 범위 조정~~ ✓ — Row(mainAxisSize: min) + 내부 Container
- ~~#8 메뉴명 변경: 수검 현황 → 실적 관리~~ ✓
- ~~#10 상세페이지 삭제 버튼 제거 + member 저장 버튼~~ ✓
- ~~#11 커뮤니티 요청/문의 UI~~ ✓ — 글쓰기 텍스트 변경 + 검색바 우측 이동

### 기능 추가
- ~~#5 사용자 관리 — 마지막 로그인~~ ✓
  - 백엔드: 로그인 시 last_login UTC ISO 기록
  - /admin/users 응답에 last_login/is_dormant 포함 (role_item에서 파싱)
  - 프론트: AdminService.loadAllUsers에서 lastLogin/isDormant 파싱
- ~~#5-b 휴면계정 자동 전환 배치~~ ✓ — 매일 09:00 KST 스케줄러 (D-7/D-3/D-1 예고 메일 + D0 전환)
- ~~#9 실적 관리 Excel Export 옵션 팝업~~ ✓ — 본부→월→주차 3단계 다이얼로그, 동적 주차 목록 조회
- ~~#13 현장 수검 Map 내비게이션 연동~~ ✓ — tmap:// / kakaomap:// 딥링크 (모바일 앱 직접 호출)
- ~~#15 현황 리포트 Acc.담당 누적 실적에 서류 추가~~ ✓ — 성능/서류 분리 표시

---

## 참고사항

### 휴면계정 (#5-b)
- 필요 환경변수: `SES_FROM_EMAIL`, `DORMANT_DAYS`(기본 30일), `SERVICE_URL`
- SES 메일 발송 전 AWS SES 콘솔에서 발신 이메일 주소 검증 필요
- SES 설정 전이라도 서버 에러는 발생하지 않음 (logger.error로만 기록)

### 테스트 계정 (#14)
- _dev_users에 등록된 계정(dev-login 사용)은 팀 배정 무관하게 전체 조회
- 실계정은 access담당 AND 품질개선팀 동시 매칭 (팀 미배정 시 접근 불가)
