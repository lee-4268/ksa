# TODO — 작업 목록

## 최종 업데이트: 2026-04-06

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
