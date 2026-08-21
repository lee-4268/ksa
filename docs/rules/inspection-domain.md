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

## 동일국소 함께 배정 체크 (일정 등록)

같은 장소에 허가번호가 여러 개인 경우 일정 배정 누락 방지.

- **판정 키 우선순위**: 통시 → 공대 → pnu_code (`POST /inspection/schedule/co-located-check`). 주소 문자열 비교는 지번/도로명 혼재로 부정확하여 사용하지 않음. 2026 기준 3단 키 커버리지 100% (통시 127,278 / 공대만 1,282 / pnu만 3,127 / 전부없음 0).
- **흐름**: 일정 등록 다이얼로그(단건/일괄) 확정 직후 체크 API 호출 → 동일국소 미배정 대상이 있으면 경고 다이얼로그([함께 배정]/[선택한 것만]/[취소]) → 함께 배정 시 같은 주차·검사관·조로 일괄 upsert. 체크 API 실패는 등록을 막지 않음(fail-open).

## 특이국소 관리 (서류 관리 메뉴)

지하철·터널·야간출입 등 특이사항 국소를 별도 관리 — 일정 계획 시 참고 목적.

- **테이블**: `special_sites` (inspection.db) — **허가번호 TEXT PRIMARY KEY** (연도 무관한 국소 속성), 유형/메모/등록자/등록일시.
- **백엔드**: `routers/special_sites.py`. 유형 화이트리스트 `VALID_SPECIAL_TYPES = (지하철, 터널, 야간출입, 기타)`.
- **권한**: 등록/수정/삭제/resolve = admin·manager 전용(403). 관리 화면 자체도 member 접근 시 '권한이 없습니다' ProgressDialog + 잠금 표시. 단 `GET /special-sites`(조회)는 전체 로그인 사용자 허용 — 일정 화면 행 배경색이 member에게도 보여야 하기 때문(일정 계획 차질 방지 목적).
- **본부 격리**: admin = 전 본부 CRUD, manager = 본인 본부 대상만 (`_caller_allowed_access_list` — 일정 upsert와 동일 정책). resolve/bulk 는 타본부 건을 `denied`로 분리 반환, delete 는 타본부·미확인 건 거부. 화면에서도 manager 는 타본부 행 체크박스 비활성.
- **전체 대상 조회**: targets+staging 통합 테이블은 없음 — 확정 시 staging에서 삭제되어 서로소이므로 `inspection_targets ∪ inspection_targets_staging` UNION이 KCA Import 전체. 등록 검증(resolve)은 이 UNION 기준, 동일 허가번호 다연도 시 최신 연도 채택.
- **화면**: `special_sites_screen.dart` — 유형 칩 필터 + 본부/팀 필터 + 검색, 삭제는 admin/manager(본부 격리). CSV 다운로드 버튼 없음(마스터가 Playground이므로 불필요), 상단에 'Playground Web에서 등록' 안내 배너.
- **방향 통일 (2026-08-21 확정)**: 모든 도메인에서 **ksa = 등록·수정 원본(master), kca = 조회 미러 + [ksa에서 가져오기]**. 특이국소도 ksa 수동 등록(대상 추가 다이얼로그) 복원 — resolve 미리보기 → 일괄 등록, admin/manager 본부 격리. kca-fe의 등록/삭제 UI는 제거(숨김), CSV 가져오기·sync-ingest 등 kca→ksa 역방향 코드는 폐기.
- **kca 미러링**: kca-fe [ksa에서 가져오기] → ksa `POST /special-sites/sync-export`(body.secret, 단순 요청 CORS, 읽기 전용, 전량 JSON) → kca-be `/special-site/ksa-sync`(세션)가 전체 교체. 완전 미러라 본부 선택/격리 불필요(누가 실행해도 동일 결과). 브라우저 릴레이인 이유: 서버 간 직통·kca-be 방향 브라우저 CORS 모두 망 정책/내부 인증 게이트로 불가.
- **일정 화면 연동**: `inspection_schedule_screen.dart`가 `GET /special-sites`로 {허가번호→유형} 맵을 백그라운드 로드, 행 배경색 tint + 테이블 상단 범례 표시. 유형별 색은 `special_sites_screen.dart`의 `kSpecialSiteColors` 단일 소스 (백엔드 VALID_SPECIAL_TYPES와 함께 유지).

## 주소 → 품질개선팀 매핑
로직 전부 `yolov8/api/routers/inspection.py`. 진입점 `_hdqt_from_addr(addr, known_hdqt, learned_map)` → `(access담당, 품질개선팀)`.

판정 순서
1. `_normalize_addr` — 선행 괄호 제거, `_ADDR_ABBR_MAP`으로 축약 시도명 확장(`서울 `→`서울특별시 `)
2. 서울이면 `_SEOUL_GU_TO_TEAM` 확정 규칙표 (긴 키워드 우선, `_SEOUL_GU_SORTED`)
3. 비서울은 주소에서 `[가-힣]+(?:시|군|구|읍|면|동)` 토큰 추출 → 후보키 생성
   - 복합키: `시 구` / `시 군` / `시 동` / `군 읍` / `군 면` / `구 동`
   - 단일키: 시·군·구·읍·면 (**단독 `동`은 전국 중복이라 제외**)
4. 후보키를 길이 내림차순으로 `learned_map` 조회 → 첫 히트 팀 확정
5. `INSP_TEAM_TO_HDQT`로 본부 역산, `_normalize_skt_hdqt`로 SKT본부 정규화
6. 미히트 시 기존 본부 유지 + 팀 공란

learned_map (읍면동 단위 매핑의 실체)
- `_learn_addr_map_from_cert_db` — cert DB의 `zpwiadr`(주소) + `ons_team_nm`(실제 담당팀) 쌍을 키워드별 집계, **동일 키워드 3건 이상**일 때만 최빈 팀 채택
- 즉 하드코딩이 아니라 운영 데이터 학습 결과 → 캐시 `{tempdir}/learned_addr_map.json`
- **캐시 값 형식은 `{키: "팀명"}` 문자열 고정.** 과거 `core/cert_cache.py` 워밍업이 같은 파일에
  `{키: {"access":…, "team":…}}` 로 써서 `_hdqt_from_addr` 가 `TypeError: unhashable type: 'dict'`
  로 죽는 버그가 있었다(2026.08 수정). 워밍업은 제거했고, 읽는 쪽은 `_normalize_learned_map` 으로
  두 형식을 모두 흡수해 기존 오염 캐시가 자동 치유된다
- **`_NON_GEOGRAPHIC_TEAMS`(=지하철품질개선팀)는 주소 학습에서 제외.** 관할이 지리가 아니라
  시설 유형으로 정해지는 팀이라, 역사가 몰린 동이 통째로 지하철팀으로 학습되면 그 동의 일반
  무선국까지 오배정된다(실측: 김포시 북변동). 주소에 '지하철'이 명시된 건은
  `_SEOUL_GU_TO_TEAM` 확정 규칙으로 계속 처리
- `_learn_pnu_map_from_cert_db`는 PNU 앞 10자리(법정동코드) → 팀, 1건부터 채택. 주소 매핑 실패 시 fallback
- `_DEPRECATED_TEAM_MAP` — 폐지된 구 팀명 → 현행 팀명 치환

### Excel로 내보내기
`scripts/export_addr_team_map.py` → `docs/주소-팀_매핑.xlsx`
- 상수·함수를 inspection.py 소스에서 AST로 추출해 그대로 실행 (복사본 없음 = 드리프트 없음)
- 시트: 안내 / 조직도 / 서울_자치구_규칙 / **법정동_팀매핑**(전국 읍면동 5,067행 + 판정근거) /
  시군구_요약 / **행정동_팀매핑**(전국 행정동 3,627행) / 학습_키워드_팀 / 폐지팀_치환 / 주소약어_정규화
- **행정동 단위**: 기존 데이터가 행정동 기준일 때 조인용. 행정동↔법정동은 다대다라 단순 변환이
  불가하므로, 행정동이 관할하는 법정동들의 판정을 다수결로 집계한다. 매핑 원본은
  `scripts/data/admin_dong_map.tsv.gz` (행안부 KIKmix, 2026.3.25 시행, 이용허락범위 제한 없음).
  갱신은 mois.go.kr 의 jscode*.zip 내 KIKmix xlsx 를 `--admin-dong` 으로 넘기거나 파일 교체.
  실측 3,627건 중 3,560건이 구성 법정동 전부 동일, 15건 다수결, 52건은 출장소/신설동이라
  시군구 대표팀 폴백
- **SKT 운용팀 컬럼**: 품질개선팀(SKO) → SKT Access운용팀 매핑은 `scripts/data/skt_ops_team_map.tsv`
  (사내 SKTSKO조직맵핑.csv 기준, 12개 운용팀). 행정동_팀매핑·학습_키워드_팀 시트에
  `access운용팀(SKT)` 으로 붙는다. 원본에 남양주품질개선팀이 경기/인천 두 줄로 있어
  **인천Access운용팀으로 확정**했다. `--skt-ops` 로 교체 가능
- 로컬 실행 시 learned_map이 없어 서울(467건)만 확정됨. **전국분은 EC2에서 실행**해야 함
- 스크립트는 `deploy_backend.sh` 배포에 포함되어 `$APP_DIR/scripts/` 로 들어간다 (별도 전송 불필요)
  ```bash
  # EC2
  bash /home/ubuntu/deploy_backend.sh          # scripts/ 까지 갱신 (재시작 불필요)
  /home/ubuntu/kca-api/venv/bin/python \
      /home/ubuntu/kca-api/scripts/export_addr_team_map.py -o /tmp/addr_team_map.xlsx
  ```
- `--api-dir` 생략 시 `APP_DIR` 환경변수 → `/home/ubuntu/kca-api` 순으로 자동 탐색
- `-l` 생략 시 `{tempdir}/learned_addr_map.json` → `{tempdir}/cert_cache.db` 순으로 자동 탐색
- learned_map 캐시가 없으면 `POST /inspection/remap-divisions?year=&dry_run=true` 를 먼저 호출
  (dry_run 이라 DB 미변경, 캐시만 생성)
