# Inspection Domain (검사/실적 관리)

## 전체 흐름

```
ERP 엑셀 업로드 → 스테이징 → 대상 확정 → 자동 지오코딩
    → 일정 배정 → [수검 워크플로우] → 결과 입력 → 실적 대시보드
```

## 수검 워크플로우 (Phase 1~5)

상세 설계: [`docs/inspection_workflow_roadmap.md`](../inspection_workflow_roadmap.md)

### 상태 머신
```
REGISTERED → PRE_CHECK → PRE_CHECK_DONE → REPORT_ISSUED → SUBMITTED → INSPECTED
   │           │            ↑
   │           └─ CHANGE_FILING → RE_CHECK ──┘ (변경개설 분기)
   └─────────── REPORT_ISSUED 직행 (사전점검 스킵 — 혁신팀 사전 분류 후)
```

### 핵심 규칙
1. **`inspection_schedules.pk` = `year#허가번호`** — 모든 흐름의 단일 키
2. **상태 전환 = `_wf_record_log_sync` 통과** — log 기록 + 알림 자동 생성 (Phase 5)
3. **두 status 분리**:
   - `workflow_status` = 워크플로우 진행 단계
   - `inspection_results.status` = 검사 결과(합격/불합격/부적합) — INSPECTED 단계부터만 화면 표시
4. **사전점검 스킵**: 혁신팀이 서류/성능으로만 분류 완료한 건은 REGISTERED → REPORT_ISSUED 직행 허용
5. **검사내역서 발급은 상태 무관 허용**: 단, 상태 전환은 가능한 건만 수행 (이미 INSPECTED 등은 역행 방지)

### 재점검 (Phase 4)
- 결과가 합격이 아니면 `inspection_results.needs_recheck='1'` 자동 세팅
- **재점검 일정은 자동 생성 안 함** — 혁신팀이 "재점검 필요" 필터로 식별 후 수동 등록
- 일정 화면 상단에 "재점검 필요 · N" 토글 칩 + INSPECTED 셀에 "재점검" 칩 표시

### 역할별 대시보드 (Phase 5)
- 홈 화면 "내 할 일" 섹션 (커뮤니티 ↔ 바로가기 사이)
- admin = 전사 / manager = 자기 본부 / member = 자기 본부+팀
- 상태 카드 클릭 → 일정 화면으로 점프하면서 해당 상태 필터 자동 적용
- 재점검 카드 → 일정 화면 `_recheckOnly` 토글 ON으로 점프
- **행정처분 대상 카드** (구 "SLA 지연"): `inadequate_management`에서 **시정기한이 지난(미완료) 건수**
  (`status != '완료' AND 시정기한 < today`, 본부 격리 scope 적용). 카드 클릭 → **부적합 관리**로 이동.
  (기존 워크플로 단계 기반 `_SLA_DAYS` 계산은 대시보드에서 미사용 — 상수만 잔존)

### 알림 (Phase 5)
- 시스템 내 알림 전용 (이메일/Slack/푸시 미사용)
- 우상단 종 아이콘 + 빨간 안 읽음 배지 (60초 폴링)
- 로그인 직후 자동 팝업 (안 읽음 > 0 & '오늘 보지 않기' 미설정)
- 워크플로우 전환 시 `_wf_record_log_sync` 내부에서 자동 알림 생성 (`_wf_notify_transition_sync`)

## 관련 파일

| 구분 | 파일 |
|------|------|
| 일정/통계 | `inspection_schedule_screen.dart` |
| 현장 수검 Map | `inspection_my_list_screen.dart` |
| 개별 검사 결과 | `inspection_result_screen.dart` |
| 실적 대시보드 | `inspection_results_screen.dart` |
| 전산비교 | `erp_ds_compare_screen.dart` |
| 변경개설 | `change_notification_screen.dart` |
| 홈 대시보드 위젯 | `widgets/inspection_dashboard_widget.dart` |
| 알림 종 + 패널 | `widgets/notification_bell_button.dart` |
| 서비스 | `inspection_service.dart` |
| 백엔드 | `main.py` — `/inspection/*`, `/inspection-results/*`, `/notifications/*` |

## 실적 대시보드 구성 (inspection_results_screen)

### 레이아웃 (와이드 모드 ≥900px)
```
Row 1: [본부별 현황 테이블 + 도넛 차트] | [본부별 목표 대비 합격율 바 차트]
         IntrinsicHeight + stretch (DataTable은 ClipRect로 감쌈)

Row 2: [성능 합격율 주별 Trend — Combo Chart]
         분기 선택 버튼 (전체/1Q/2Q/3Q/4Q)

Row 3: [Acc.담당별 주별 Trend — 3x3 소형 차트]

Row 4: [장비 Type별 불합격 현황 테이블] | [장비 Type별 불합격 비율 요약]
         IntrinsicHeight + stretch
```

### 분기 필터 (1Q~4Q)
- `_selectedQuarter`: 0=전체, 1~4=분기
- `_filterByQuarter()`: 주차명에서 월 파싱 → 분기 필터
- 차트 + 하단 테이블 모두 적용
- 전체: `SingleChildScrollView` 스크롤, 1~12월 표시
- 분기: `Expanded` 균등 배분, 해당 3개월만 표시 + 폰트 확대

### 현황 리포트 (_buildSummaryReport)
- 성능/서류 달성 여부: `perf_ok`/`perf_fail`/`doc_ok`/`doc_fail` type
- 달성: 초록 배경 + 체크 아이콘
- 미달성: 빨간 배경 + 경고 아이콘
- 인라인 배경 범위: `Row(mainAxisSize: min)` + 내부 `Container` (전체 너비 배경 방지)
- Acc.담당 누적 실적: 성능/서류 **분리 표시**, 합격율 **높은 순** 정렬 (내림차순)

### 장비 Type별 불합격 현황
- `성능불합격(건)` 합계 = **전체 성능불합격 건수** (Top3 합이 아님)
- 별도 SQL로 본부별 전체 집계

## 현장 수검 Map (inspection_my_list_screen)
- `/inspection/my-list` API로 데이터 조회
- region에서 "Access담당" 제거 후 `access담당` 컬럼과 매칭
- dev-login 사용자(is_dev=True): 팀 무관 전체 목록 조회
- 실계정: access담당 AND 품질개선팀 동시 조건 (팀 미배정 시 빈 목록)
- 뒤로가기: Navigator.canPop 체크 → pop 불가 시 버튼 숨김
- **Phase 4 수검가능 토글**: 상단 필터행에 토글 칩 (기본 ON)
  - ON: `workflow_status` ∈ {SUBMITTED, REPORT_ISSUED, INSPECTED}만 마커/리스트 표시
  - OFF: 전체 일정 (디버깅/조회용)
  - 도메인 룰: 전파관리소 접수 안 된 건은 수검 불가

## 내비게이션 연동 (inspection_result_screen)
- 설치장소 행에 위/경도가 있을 때 Tmap / 카카오 버튼 표시
- **Tmap**: `tmap://route?goalx={lng}&goaly={lat}&goalname={name}` (모바일 앱 직접 호출)
- **카카오내비**: `kakaomap://route?ep={lat},{lng}&by=CAR` (모바일 앱 직접 호출)
- `html.window.open('딥링크', '_blank')` — 모바일 브라우저에서 앱 실행

## 실적 Excel Export
- `POST /inspection-results/export-xlsx` — RAW DATA 시트 1장
- 다이얼로그 3단계: 본부 → 월 → 주차 (순서대로 선택)
- 월 선택 시 `GET /inspection-results/weeks?year=&month=&region=` 로 실제 업로드된 주차 목록 동적 조회
- 파일명: `실적_결과장_{year}_{본부}_{월}_{주차}.xlsx`

## 결과장 업로드 규칙
- 본부관리자(isDivisionAdmin) 이상만 업로드 버튼 노출
- 같은 region+year 기존 데이터는 DELETE 후 INSERT (중복 안전)
- 업로드 시 장비타입간소화 자동 파생 (5단계 fallback)

## 지오코딩
- ERP 대상 확정(confirm) 시 **백그라운드 자동 실행**
- Kakao API 10개 동시 요청, 500개 배치
- 수동 좌표 갱신 버튼도 유지
