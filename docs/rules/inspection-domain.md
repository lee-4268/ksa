# Inspection Domain (검사/실적 관리)

## 전체 흐름

```
ERP 엑셀 업로드 → 스테이징 → 대상 확정 → 자동 지오코딩
    → 일정 배정 (본부/팀별) → 현장 수검 (사진/결과) → 결과장 업로드 → 실적 대시보드
```

## 관련 파일

| 구분 | 파일 |
|------|------|
| 일정/통계 | `inspection_schedule_screen.dart` |
| 현장 수검 Map | `inspection_my_list_screen.dart` |
| 개별 검사 결과 | `inspection_result_screen.dart` |
| 실적 대시보드 | `inspection_results_screen.dart` |
| 서비스 | `inspection_service.dart` |
| 백엔드 | `main.py` — `/inspection/*`, `/inspection-results/*` |

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
- Acc.담당 누적 실적: 합격율 **높은 순** 정렬 (내림차순)

### 장비 Type별 불합격 현황
- `성능불합격(건)` 합계 = **전체 성능불합격 건수** (Top3 합이 아님)
- 별도 SQL로 본부별 전체 집계

## 현장 수검 Map (inspection_my_list_screen)
- `/inspection/my-list` API로 데이터 조회
- region에서 "Access담당" 제거 후 `access담당` 컬럼과 매칭
- dev-login 사용자: `_dev_users` 캐시에서 region/team 조회 (DynamoDB fallback)

## 결과장 업로드 규칙
- 본부관리자(isDivisionAdmin) 이상만 업로드 버튼 노출
- 같은 region+year 기존 데이터는 DELETE 후 INSERT (중복 안전)
- 업로드 시 장비타입간소화 자동 파생 (5단계 fallback)

## 지오코딩
- ERP 대상 확정(confirm) 시 **백그라운드 자동 실행**
- Kakao API 10개 동시 요청, 500개 배치
- 수동 좌표 갱신 버튼도 유지
