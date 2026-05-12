# 무선국 수검 시스템 — 최종 구현 로드맵

연간 수검 일정 등록부터 현장 수검 완료까지, 팀 간 인계가 시스템 내에서 논스톱으로 이뤄지도록 만드는 전체 구현 계획.

---

## 배경

### As-is (현재)
- 수검대상 공지 → 수검대상 검토 → 서류 현행화 / 성능 점검 → 현장 실사/수정 → 수검 서류 작성 → 수검
- 6단계, 팀 간 Excel 핸드오프 3회, 데이터 일관성 확보 어려움

### To-be (목표)
- 무선국 수검 관리 시스템 한 곳에서 수검 일정 및 현황을 관리
- N/W계획팀 / N/W혁신팀 / 품질개선팀이 같은 시스템을 보며 협업
- 변경개설 신고 같은 분기 작업도 시스템 내에서 논스톱 처리

### 액터별 역할

| 액터 | 행위 | 빈도 |
|------|------|------|
| **N/W계획팀** | 연간 수검대상 엑셀 업로드 (전파관리소 → 우리 시스템) | 연 1회 |
| **N/W혁신팀** | 일정 등록(조/주차/검사관 배정), 사전점검 의뢰, 변경개설 신고, 검사내역서 발급, 전파관리소 접수 | 상시 |
| **품질개선팀** | 전산비교 수행, 변경개설 작성, 현장 수검 | 상시 |

---

## 전체 상태 머신

```
┌──────────────────────────────────────────────┐
│ REGISTERED (등록됨)                           │
│  액터: N/W혁신팀                              │
│  트리거: 수검 대상 다중 선택 + 월/주차/조/검사관│
│         입력 + "일정 등록" 클릭                 │
└─────────────┬───────────────────┬────────────┘
              │ "사전점검 의뢰"     │ 사전점검 불필요로 분류 →
              │ (혁신팀, 다중 선택) │ 바로 "검사내역서 발급"
              ▼                    │ (REPORT_ISSUED로 직행)
                                   │
┌──────────────────────────────────────────────┐
│ PRE_CHECK (사전점검중)                        │
│  액터: 품질개선팀 (해당 조)                    │
│  작업: 전산비교 (설치형태/일련번호)            │
└──┬─────────────────────────┬─────────────────┘
   │ 일치/부분일치/확인필요만 │ 불일치 또는 DS누락 발견
   │ "이상 없음 회신"          │ "변경개설 필요" 클릭
   ▼                          ▼
                ┌──────────────────────────────┐
                │ CHANGE_FILING (변경개설중)    │
                │  액터: N/W혁신팀              │
                │  작업: A파일 자동 다운로드 →   │
                │   전파관리소 DS 다운로드 →    │
                │   변경개설 메뉴에서 변경 적용  │
                │   파일 생성 → 전파관리소 신고  │
                └────────┬─────────────────────┘
                         │ 신고 완료 후 "신고 완료" 클릭
                         ▼
                ┌──────────────────────────────┐
                │ RE_CHECK (재점검 대기)        │
                │  액터: N/W혁신팀              │
                │  작업: 다음날 부분 DS 회신 →   │
                │   [DS 데이터] 메뉴 →          │
                │   [데이터 변경요청] 업로드 →   │
                │   ds_detail.db 패치 →         │
                │   자동 재비교                  │
                └────────┬─────────────────────┘
                         │ 자동 재비교 통과 (시스템)
                         │ 실패 시 RE_CHECK 유지
   ┌─────────────────────┘
   ▼
┌──────────────────────────────────────────────┐
│ PRE_CHECK_DONE (점검완료)                     │
│  산출물: 전산비교 통과 확인                    │
└─────────────┬────────────────────────────────┘
              │ "검사내역서 발급" (혁신팀, 다중 선택)
              ▼
┌──────────────────────────────────────────────┐
│ REPORT_ISSUED (검사내역서 발급)               │
│  액터: N/W혁신팀                              │
│  산출물: 검사내역서 xlsx (S3 저장)             │
└─────────────┬────────────────────────────────┘
              │ 전파관리소 접수 후 접수번호 입력
              ▼
┌──────────────────────────────────────────────┐
│ SUBMITTED (접수완료)                          │
│  외부: 전파관리소 시스템 (수동 접수)           │
│  시스템 내: 접수번호/접수일 기록               │
└─────────────┬────────────────────────────────┘
              │ 입회자 "수검 완료" / 검사실적 입력
              ▼
┌──────────────────────────────────────────────┐
│ INSPECTED (수검완료)                          │
│  결과: 합격(기본) / 불합격 / 부적합            │
│  산출물: 수검 서류 자동 생성                    │
└──────────────────────────────────────────────┘
```

### 상태 전환 권한 매트릭스

| 전환 | 권한 | 트리거 |
|------|------|------|
| (없음) → REGISTERED | N/W혁신팀 (admin/manager) | 수검 대상 다중 선택 + 일정 등록 |
| REGISTERED → PRE_CHECK | N/W혁신팀 | "사전점검 의뢰" 다중 선택 클릭 |
| REGISTERED → REPORT_ISSUED | N/W혁신팀 | 사전점검 불필요로 분류 → "검사내역서 발급" 직행 |
| PRE_CHECK → PRE_CHECK_DONE | 품질개선팀 | 전산비교 화면 "이상 없음 회신" |
| PRE_CHECK → CHANGE_FILING | 품질개선팀 | 전산비교 화면 "변경개설 필요" + 변경 항목 입력 |
| CHANGE_FILING → RE_CHECK | N/W혁신팀 | "신고 완료" 클릭 |
| RE_CHECK → PRE_CHECK_DONE | 시스템(자동) | 부분 DS 업로드 후 재비교 통과 |
| RE_CHECK 유지 | (트리거 없음) | 부분 DS 미업로드 또는 비교 실패 |
| PRE_CHECK_DONE → REPORT_ISSUED | N/W혁신팀 | "검사내역서 발급" 다중 선택 클릭 |
| REPORT_ISSUED → SUBMITTED | N/W혁신팀 | "접수번호 입력" |
| SUBMITTED → INSPECTED | 품질개선팀(입회자) | "수검 완료" 또는 검사실적 저장 |
| 모든 전환 → 강제 롤백(REGISTERED) | superadmin | 관리자 도구 |

### 두 status의 분리 (중요)

| 개념 | 컬럼 | 기본값 | 표시 시점 |
|------|------|------|--------|
| 워크플로우 상태 | `inspection_schedules.workflow_status` | REGISTERED | 모든 단계에서 배지 표시 |
| 검사 결과 | `inspection_results.status` | 합격 (현행 유지) | INSPECTED 단계부터만 표시 |

- `inspection_results.status='합격'` 자동 생성은 **유지** (입회자 편의 — 불합격일 때만 수정)
- INSPECTED 미만 단계에선 검사결과 컬럼 숨김 / 회색 처리 (모순 방지)

---

## 전산비교 정책

### 비교 항목 (수정)

기존 3항목 → **2항목**으로 축소:

| 항목 | 비교 | 비고 |
|------|-----|----|
| 설치형태 | ✅ | 분산폴/간이폴/복합형 그룹 매칭 (기존 로직 유지) |
| 일련번호 | ✅ | (장치별) |
| ~~기수(안테나)~~ | ❌ 제거 | 수기 관리 데이터로 불일치율 매우 높음 → 의미 없음 |

### 비교 결과 5가지 분류

| 상태 | ERP | DS | 의미 | 회신 시 처리 |
|------|----|----|------|------------|
| 일치 | 값 | 값(같음) | 정상 | 통과 |
| 부분일치 | 값 | 값(그룹 매칭) | 정상 (예: 분산폴 vs 간이폴) | 통과 |
| 불일치 | 값 | 값(다름) | 변경개설 대상 | 변경개설 필요 |
| **DS누락** | 값 | 빈 값 | 변경개설 대상 (DS 채우기) | 변경개설 필요 |
| 확인필요 | 빈 값 또는 양쪽 빈 값 | (다양) | 외부 사이트(ACTA/시설현황)에서 수동 확인 | 외부 확인 후 통과 |

### 회신 정책

```
[이상 없음 회신] 버튼 활성화 조건
  - 불일치 0건 AND DS누락 0건
  - 확인필요 건은 통과 허용 (품개팀이 외부 확인 완료 가정)

[회신 다이얼로그 — 확인 단계]
  ⚠ 확인필요 N건 포함 회신
  - ACTA/시설현황에서 외부 확인 완료된 것으로 간주됩니다
  [취소] [회신 진행]
```

---

## Phase 1: 상태 머신 기반 + 사전점검

**목표**: 일정 → 전산비교 → 회신 흐름 자동화
**구현 범위**: REGISTERED → PRE_CHECK → PRE_CHECK_DONE

### 데이터 모델

**`inspection_schedules` 마이그레이션**
```sql
ALTER TABLE inspection_schedules ADD COLUMN workflow_status TEXT DEFAULT 'REGISTERED';
ALTER TABLE inspection_schedules ADD COLUMN status_updated_at TEXT;
ALTER TABLE inspection_schedules ADD COLUMN status_updated_by TEXT;
ALTER TABLE inspection_schedules ADD COLUMN pre_check_result TEXT;  -- JSON
```

**`inspection_status_log` 신규**
```sql
CREATE TABLE inspection_status_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  schedule_pk TEXT NOT NULL,    -- inspection_schedules.pk가 TEXT
  from_status TEXT,
  to_status TEXT NOT NULL,
  changed_by TEXT,
  changed_at TEXT NOT NULL,
  memo TEXT
);
CREATE INDEX idx_isl_pk ON inspection_status_log(schedule_pk);
```

**기존 데이터 백필**
```sql
-- 검사일 입력된 건은 INSPECTED, 나머지는 REGISTERED (DEFAULT)
UPDATE inspection_schedules SET workflow_status = 'INSPECTED'
WHERE pk IN (
  SELECT pk FROM inspection_results
  WHERE 검사일 IS NOT NULL AND 검사일 != ''
);
```

### 전산비교 변경

**`_compare_values` 수정** ([main.py:10273](../yolov8/api/main.py#L10273))
```python
def _compare_values(erp_val, ds_val, normalize_fn=None):
    if not erp_val and not ds_val: return "확인필요"
    if not ds_val: return "DS누락"     # 신규 분류
    if not erp_val: return "확인필요"   # ERP 누락 → 외부 확인 대상
    # ... 기존 일치/부분일치/불일치 로직 ...
```

**기수 비교 제거**
- `_erp_ds_compare_sync` ([main.py:10850](../yolov8/api/main.py#L10850))에서 `antenna_result` 계산/반환 제거
- 프론트 [erp_ds_compare_screen.dart](../lib/screens/erp_ds_compare_screen.dart) 컬럼 정의에서 ERP기수/DS기수/기수비교 3컬럼 제거
- 엑셀 export에서도 동일 컬럼 제거
- 비교 결과 요약에서 "기수" 항목 제거

### API

```
PATCH /inspection/schedule/{pk}/status
  body: { to_status: "PRE_CHECK", memo: "..." }
  권한 체크: 워크플로우 권한 매트릭스 적용

POST /inspection/schedule/transition-bulk
  body: { schedule_pks: [...], to_status: "PRE_CHECK" }
  → 다중 선택 일괄 전환 (혁신팀 사전점검 의뢰용)

GET /inspection/schedule/{pk}/log

POST /inspection/schedule/{pk}/pre-check-result
  body: {
    summary: { 일치, 부분일치, 불일치, DS누락, 확인필요 카운트 },
    items: [...],
    confirmation_acknowledged: true   ← 확인필요 포함 회신 시 명시 동의
  }
  → 자동으로 PRE_CHECK → PRE_CHECK_DONE 전환
  → 단, 불일치 또는 DS누락 0건일 때만 허용
```

### UI 변경

#### 일정관리 화면 ([inspection_schedule_screen.dart](../lib/screens/inspection_schedule_screen.dart))
- **상태 배지 컬럼** 추가 (등록됨/사전점검중/점검완료/접수완료/수검중/수검완료)
- **"사전점검 의뢰" 액션 버튼**: 다중 선택된 REGISTERED 건들 → PRE_CHECK 일괄 전환
- 권한별 노출:
  - 혁신팀: 일정 등록 + 사전점검 의뢰
  - 품개팀: 자기 조 일정만 (PRE_CHECK 이상)

#### 전산비교 화면 ([erp_ds_compare_screen.dart](../lib/screens/erp_ds_compare_screen.dart))
- **`?schedule_pk=123` 쿼리 수신 시** 자동으로 해당 일정 zpwino 채움
- 헤더에 "수검 건: 2026-Q2-3주차-A조" 컨텍스트 표시
- **기수 컬럼 제거** (ERP기수/DS기수/기수비교)
- "확인필요" 행에 ⓘ 툴팁: "ACTA/시설현황에서 외부 확인 후 판단"
- **"이상 없음 회신" 버튼**: 불일치/DS누락 0건일 때 활성, 확인필요 포함 시 다이얼로그
- (Phase 2에서 "변경개설 필요" 버튼 추가)

### 작업 분해

| # | 작업 | 파일 | 변경량 |
|---|------|------|------|
| 1 | DB 마이그레이션 (4컬럼 + status_log + 백필) | main.py | +40줄 |
| 2 | `_compare_values` DS누락 분류 추가 | main.py | +10줄 |
| 3 | 기수 비교 로직 제거 (백엔드) | main.py | -50줄 |
| 4 | 상태 전환 API + bulk 전환 | main.py | +90줄 |
| 5 | 권한 헬퍼 `_can_transition(...)` | main.py | +30줄 |
| 6 | 사전점검 결과 첨부 API | main.py | +40줄 |
| 7 | 기존 schedule upsert에 workflow_status 처리 추가 + log 기록 | main.py | +20줄 |
| 8 | 일정 GET response에 workflow_status 포함 | main.py | +5줄 |
| 9 | 일정 화면 상태 배지 + 사전점검 의뢰 버튼 | inspection_schedule_screen.dart | +120줄 |
| 10 | 전산비교 화면 schedule_pk 연동 + 회신 버튼 + 기수 컬럼 제거 | erp_ds_compare_screen.dart | +80 / -100줄 |
| 11 | inspection_service.dart에 신규 메서드 | inspection_service.dart | +50줄 |
| 12 | 토스트 알림 (Phase 5 푸시는 별도) | 양 화면 | +20줄 |

**규모**: 백엔드 ~225줄(증) -50줄(감), 프론트 ~270줄(증) -100줄(감) = 백엔드 +175줄 순증, 프론트 +170줄 순증

### 검증 시나리오
1. 혁신팀 → 수검 대상 다중 선택 + 일정 등록 → 모두 "등록됨" 배지
2. 혁신팀 → 일정 다중 선택 + "사전점검 의뢰" → 모두 "사전점검중"
3. 품개팀 계정 → 자기 조 사전점검중 일정 표시
4. 일정 행 클릭 → 전산비교 화면 자동 진입(zpwino 자동)
5. 비교 결과 모두 일치/부분일치 → "회신" → "점검완료"
6. 확인필요 건 포함 회신 시 다이얼로그 표시 → 동의 → "점검완료"
7. 불일치/DS누락 있을 때 "회신" 버튼 비활성 확인
8. status_log 에 모든 전환 기록 확인

### 위험 요소
1. **기수 컬럼 제거 시 기존 백필 데이터 호환성** — 응답 스키마 변경되므로 프론트 동시 배포 필요
2. **권한 충돌** — 한 사용자가 두 팀 소속인 경우 단일 팀 가정, 예외는 superadmin
3. **확인필요 회신 정책** — 외부 확인 책임이 품개팀에 있다는 점을 다이얼로그로 명시

---

## Phase 2: 변경개설 분기 자동화

**목표**: 전산비교 불일치/DS누락 → 변경개설 신고 → 부분 DS 회신 적용 → 자동 재비교

### 핵심 설계 원칙

1. **기존 변경개설 메뉴 80% 재활용** ([main.py:16175](../yolov8/api/main.py#L16175) `/document/change-notification`)
2. **DS DB 패치 시점은 RE_CHECK 단계 부분 DS 회신 받은 후만** — 신고 단계에서 우리 DB 보호
3. **A파일(신고서)은 시스템이 자동 생성** — 품개팀이 입력한 데이터로 (논스톱)
4. **변경 4항목 분류 로직 재활용** ([main.py:16286-16350](../yolov8/api/main.py#L16286))

### 변경 항목 (4가지)

| 변경 항목 | 단위 | DS DB 컬럼 |
|---------|------|-----------|
| 일련번호 | 장치 (허가번호+장치번호) | `ds_장치.기기일련번호` |
| 형식검정번호 | 장치 (허가번호+장치번호) | `ds_장치.형식검정번호` |
| 설치장소 | 국소 (허가번호) | `inspection_targets.설치장소` |
| 설치형태 | 국소 (허가번호) | `ds_안테나.공중선주설치형태명` |

### 데이터 모델

**`change_request` 신규**
```sql
CREATE TABLE change_request (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  schedule_pk TEXT NOT NULL,
  허가번호 TEXT NOT NULL,
  field TEXT NOT NULL,            -- '일련번호'/'형식검정번호'/'설치형태'/'설치장소'
  before_value TEXT,              -- DS 현재값 (전산비교 결과에서 자동 채움)
  after_value TEXT NOT NULL,      -- 품개팀이 입력한 변경 후 값
  장치번호 TEXT,                  -- 장치 단위 항목인 경우만
  memo TEXT,
  status TEXT NOT NULL,           -- REQUESTED/FILED/APPLIED/VERIFIED
  requested_by TEXT, requested_at TEXT,
  filed_by TEXT, filed_at TEXT,
  applied_at TEXT,                -- 부분 DS 적용 시점
  FOREIGN KEY (schedule_pk) REFERENCES inspection_schedules(pk)
);
CREATE INDEX idx_cr_pk ON change_request(schedule_pk);
CREATE INDEX idx_cr_status ON change_request(status);
```

### 전체 흐름

```
[PRE_CHECK 단계 — 품개팀 작성]
1. 전산비교에서 불일치/DS누락 행 체크박스 다중 선택
2. "변경개설 필요" 버튼 → 다이얼로그
   - 항목별 입력 (일련번호/형식검정번호/설치장소/설치형태)
   - DS 현재값 자동 채움 (전산비교 결과에서)
   - 변경 후 값 입력
   - 장치번호 입력 (장치 단위 항목)
3. 저장
   - change_request 테이블에 INSERT (status=REQUESTED)
   - workflow_status: PRE_CHECK → CHANGE_FILING

[CHANGE_FILING 단계 — 혁신팀 처리]
4. 혁신팀 화면 "변경 요청 목록" 탭에 신청 표시
5. "A파일(신고서) 자동 생성" 버튼 → 시스템이 change_request 데이터로 신고서 xls 생성/다운로드
6. 혁신팀이 전파관리소에서 변경 대상 허가번호의 현재 DS 파일 다운로드
7. 기존 변경개설 메뉴에서 A+B 업로드 → 변경 적용 DS 파일 출력
   ⚠ 이 단계에서는 DS DB 건드리지 않음 (파일 생성만)
8. 혁신팀이 [변경 적용 DS + A파일] 전파관리소에 신고
9. 신고 완료 → "신고 완료" 버튼 클릭
   - change_request.status: REQUESTED → FILED
   - workflow_status: CHANGE_FILING → RE_CHECK

[RE_CHECK 단계 — 다음날]
10. 전파관리소가 변경 반영된 부분 DS 회신
11. 혁신팀이 [DS 데이터] 메뉴 → 본부 옆 [데이터 변경요청] 버튼 클릭
12. 부분 DS xls 업로드
   - ds_detail.db 패치 (해당 허가번호+장치번호의 4항목 중 변경된 것만)
   - change_request.status: FILED → APPLIED
13. 자동 재비교 트리거
   - change_request 의 모든 항목이 DS에 반영됐는지 확인
   - 통과 → workflow_status: RE_CHECK → PRE_CHECK_DONE
   - change_request.status: APPLIED → VERIFIED
   - 실패 → RE_CHECK 유지 (다음 부분 DS 업로드 기다림)
```

### API

```
POST /inspection/schedule/{pk}/change-request
  body: { items: [{ field, before, after, 장치번호?, memo? }, ...] }
  → change_request 다중 INSERT, workflow_status: PRE_CHECK → CHANGE_FILING

GET /change-request?schedule_pk=...&status=...
  → 혁신팀이 변경 요청 목록 조회

POST /change-request/generate-form
  body: { schedule_pk: "..." }
  → A파일(신고서) xls 자동 생성, presigned URL 반환

PATCH /change-request/file
  body: { schedule_pk: "..." }
  → "신고 완료" — 해당 schedule의 모든 change_request status: REQUESTED → FILED
  → workflow_status: CHANGE_FILING → RE_CHECK

POST /ds/apply-partial-update
  multipart: file (부분 DS xls)
  → 기존 /document/apply-change-notification 로직 재활용 + 워크플로우 통합:
    1. 부분 DS 파싱
    2. change_request (status=FILED) 매칭
    3. 매칭된 항목만 ds_detail.db UPDATE
    4. ds_변경이력 INSERT
    5. change_request.status: FILED → APPLIED
    6. 자동 재비교 → 통과 시 PRE_CHECK_DONE 전환 + change_request.status: APPLIED → VERIFIED

(기존 /document/change-notification 은 파일 생성 전용으로 분리,
 DB UPDATE 로직 제거 → /ds/apply-partial-update 로 이동)
```

### UI 변경

#### 1. 전산비교 화면 ([erp_ds_compare_screen.dart](../lib/screens/erp_ds_compare_screen.dart))
- 불일치/DS누락 행에 체크박스
- "변경개설 필요" 버튼 → 다이얼로그
- 다이얼로그 구조:
  ```
  대상: 허가번호 ○○○○○○ / ○○국 (체크된 행 일괄)

  ▼ 변경 항목 1
    필드: ⊙ 일련번호 ○ 형식검정번호 ○ 설치장소 ○ 설치형태
    장치번호: [    ] (장치 단위만)
    DS 현재값: ABC123 (자동, 회색)
    변경 후 값: [_____]
    메모: [........]

  ▼ + 항목 추가

  [취소] [신고 요청 등록]
  ```

#### 2. 변경개설 메뉴 ([change_notification_screen.dart](../lib/screens/change_notification_screen.dart))
- **신규 탭**: "변경 요청 목록" (혁신팀)
- 컬럼: 허가번호, 호출명칭, 변경항목 수, 작성자(품개팀), 작성일, 액션
- 액션: [A파일 자동 생성] [신고 완료]
- 기존 "A+B 업로드" 영역은 유지 (혁신팀이 변경 적용 DS 파일 만들 때 사용)

#### 3. DS 데이터 메뉴 (기존 화면 — 위치 확인 필요)
- 본부별 [Excel 다운로드] 버튼 옆에 [데이터 변경요청] 버튼 추가
- 클릭 시 부분 DS 업로드 다이얼로그 → /ds/apply-partial-update 호출
- 결과: "패치된 건 N건 / 재비교 통과 M건 / RE_CHECK 유지 K건"

### 작업 분해

| # | 작업 | 변경량 |
|---|------|------|
| 1 | change_request 테이블 신설 | +25줄 |
| 2 | 전산비교 화면 "변경개설 필요" 다이얼로그 | +200줄 |
| 3 | POST /inspection/schedule/{pk}/change-request | +70줄 |
| 4 | 혁신팀 "변경 요청 목록" 탭 | +220줄 |
| 5 | A파일 자동 생성 API + xls 빌드 로직 | +150줄 |
| 6 | 기존 /document/change-notification에서 DB UPDATE 분리 | -80줄 (수정) |
| 7 | POST /ds/apply-partial-update (워크플로우 통합) | +180줄 |
| 8 | DS 데이터 메뉴에 [데이터 변경요청] 버튼 + 다이얼로그 | +100줄 |
| 9 | 자동 재비교 + 상태 전환 로직 | +120줄 |

**규모**: 백엔드 ~545줄 / 프론트 ~520줄

### 위험 요소
1. **기존 `/document/apply-change-notification` 의 DB UPDATE 로직 분리** — 다른 곳에서 호출 안 하는지 확인 필요
2. **부분 DS와 change_request 매칭 실패** — 장치번호 불일치 등, 명확한 에러 메시지 필요
3. **자동 재비교 정확도** — change_request 의 변경 항목과 DS 현재 값이 정확히 일치해야 통과 처리

---

## Phase 3: 검사내역서 발급 + 접수 트래킹

**목표**: 점검완료 건 묶음 검사내역서 즉시 다운로드 + 전파관리소 접수 이력 관리

### 핵심 설계
- 일정 화면에서 **PRE_CHECK_DONE 또는 REGISTERED** 건 다중 선택 → "검사내역서 발급" 클릭
  - 사전점검 거친 건(PRE_CHECK_DONE): 정상 경로
  - 사전점검 스킵 건(REGISTERED): 혁신팀이 서류/성능만으로 사전 분류해 현장 방문 불필요로 판정한 케이스 → 직행
- **기존 `/inspection/export-inspection-report` 빌더 100% 재활용** — 양식 동일
- **즉시 응답 다운로드** (S3 저장 X, 메모리에서 xls 생성 후 바로 stream 응답)
- 발급 시점에 REPORT_ISSUED 전환 (시각/발급자만 DB 기록)
- 혁신팀이 전파관리소 접수 후 접수번호/접수일 입력 → SUBMITTED

### 컬럼 추가
```sql
ALTER TABLE inspection_schedules ADD COLUMN report_issued_at TEXT;
ALTER TABLE inspection_schedules ADD COLUMN report_issued_by TEXT;
ALTER TABLE inspection_schedules ADD COLUMN submission_no TEXT;
ALTER TABLE inspection_schedules ADD COLUMN submitted_at TEXT;
```

### API
```
POST /inspection/report/generate
  body: { schedule_pks: [...] }
  → 즉시 xls 바이너리 응답 (StreamingResponse)
  → 동시에 모든 schedule workflow_status: PRE_CHECK_DONE → REPORT_ISSUED
  → report_issued_at, report_issued_by 기록

PATCH /inspection/schedule/{pk}/submission
  body: { submission_no: "...", submitted_at: "..." }
  → workflow_status: REPORT_ISSUED → SUBMITTED
```

### 재활용 포인트
- 기존 전산비교 화면의 엑셀 다운로드 패턴 ([erp_ds_compare_screen.dart](../lib/screens/erp_ds_compare_screen.dart) 866-937 근처) 참고
- openpyxl/xlwt 직접 생성 후 즉시 응답 (워커/큐 불필요)

### 재발급 정책
- 같은 schedule_pks 로 재호출 시 항상 최신 데이터로 재생성
- 스냅샷 저장 X (PRE_CHECK_DONE → REPORT_ISSUED 구간엔 DS 변경 없다는 가정)
- 만약 REPORT_ISSUED 이후 DS가 바뀌어야 하는 케이스는 워크플로우 강제 롤백(superadmin)으로 처리

**규모**: 백엔드 ~150줄, 프론트 ~130줄

---

## Phase 4: 현장 수검 결과 자동 연결

**목표**: 현장수검 Map ↔ 검사실적 ↔ 상태 갱신 일관화

### 핵심 설계
- `inspection_my_list_screen` + `inspection_results` 이미 존재 → schedule_pk로 묶기만
- 현장수검 Map은 **수검 가능 상태(SUBMITTED/REPORT_ISSUED/INSPECTED) 건만 표시**가 기본,
  사용자가 토글로 전체 보기 전환 가능 (접수 안 된 건 수검 불가 도메인 룰)
- 입회자 검사일 입력 → SUBMITTED → INSPECTED 자동 전환 (`_wf_can_transition` 가드)
- 불합격/부적합 시 **재점검 일정 자동 생성은 안 함, 대신 `needs_recheck` 플래그만 세팅**
  → 혁신팀이 일정 화면 "재점검 필요" 칩 필터로 식별, 새 일정은 수동 등록
- INSPECTED 단계부터 검사결과(`inspection_results.status`) 표시 — 그 외 단계엔 숨김 (두 status 분리)

### 변경
```sql
ALTER TABLE inspection_results ADD COLUMN schedule_pk TEXT DEFAULT '';
ALTER TABLE inspection_results ADD COLUMN needs_recheck TEXT DEFAULT '0';  -- '1'=재점검 필요
-- 백필: inspection_results.pk == inspection_schedules.pk (year#허가번호) 이미 동일 포맷이라 자기 자신 복사
UPDATE inspection_results SET schedule_pk = pk
 WHERE (schedule_pk IS NULL OR schedule_pk='')
   AND pk IN (SELECT pk FROM inspection_schedules);
```

### 자동화
- `/inspection/result` POST 시:
  - `schedule_pk` 자동 세팅
  - 검사일 입력 + schedule 존재 + `_wf_can_transition` 통과 시 INSPECTED로 전환 + 상태 로그 기록
  - status가 합격이 아니면 `needs_recheck='1'`
- `/inspection/schedules` 응답에 `needs_recheck`, `result_status` LEFT JOIN으로 노출 → 프론트에서 활용

### UI
- 일정 화면:
  - 상태 칩 영역에 별도 토글 "재점검 필요 · N" (상태 필터와 독립적)
  - INSPECTED 셀에 작은 "재점검" 칩 노출 (배지 옆 한 줄, 셀 높이 제한 안 침범)
  - 검사결과 컬럼은 INSPECTED일 때만 표시 (그 외 단계엔 빈칸)
- 현장수검 Map:
  - 상단 필터 행에 "수검가능" 토글 칩 (기본 ON, 접수 완료 이상 건만 표시)

**규모**: 백엔드 ~120줄, 프론트 ~150줄

---

## Phase 5: 알림 + 대시보드

**목표**: "내 할 일"이 한눈에 보이는 종합 대시보드 + 워크플로우 전환 자동 알림

### 알림 시스템 (시스템 내 알림 전용)
- 이메일/Slack/Teams/푸시는 모두 **이번 Phase 5에서 제외** — 시스템 내 알림(우상단 종)만 구현
- 상태 전환 시 다음 액터에게 자동 알림:
  · PRE_CHECK_REQUESTED (REGISTERED→PRE_CHECK): 품개팀에게
  · PRE_CHECK_REPLIED (PRE_CHECK→PRE_CHECK_DONE): 혁신팀에게
  · CHANGE_REQUESTED (PRE_CHECK→CHANGE_FILING): 혁신팀에게
  · CHANGE_FILED (CHANGE_FILING→RE_CHECK): 혁신팀에게
  · RE_CHECK_DONE (RE_CHECK→PRE_CHECK_DONE 자동): 혁신팀에게
  · REPORT_ISSUED: 혁신팀에게
  · SUBMITTED: 품개팀(수검 담당)에게
  · INSPECTED: 혁신팀에게
- 수신자 결정 (현재 단순 룰): 일정 등록자(혁신팀) 우선, 상태 변경 본인은 제외
- 향후 본부/팀 매핑은 user_roles 별도 조회로 확장 예정

### 대시보드 (홈 화면 "내 할 일" 섹션 — 커뮤니티 ↔ 바로가기 사이)
- 역할 자동 분기 (admin/manager/member 권한 그대로 활용 — manager가 곧 본부장 포지션)
- **admin**: 전사 상태별 카운트 + 전체 지연 건 + 재점검 필요
- **manager**: 자기 본부(region) 상태별 카운트 + 본부 지연 건
- **member**: 자기 본부+팀 상태별 카운트 + 팀 지연 건
- 상태 카드 클릭 → 일정 화면으로 점프 (필터 적용은 향후 확장)
- 지연 건 상위 5개 미니 리스트 + 클릭 시 일정 점프

### SLA / 지연 표시 (자동 알림은 미구현 — 대시보드 강조만)
- 임계점 하드코딩 (`_SLA_DAYS`):
  · PRE_CHECK 5일 / CHANGE_FILING 3일 / RE_CHECK 7일
  · REPORT_ISSUED 3일 / SUBMITTED 14일
- `status_updated_at` 기준 경과 일수로 판정, 임계점 초과 시 overdue 목록에 포함
- 매일 새벽 배치 워커는 향후 추가 (현재는 대시보드 조회 시점에 실시간 계산)

### 신규 테이블
```sql
CREATE TABLE notifications (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id TEXT NOT NULL,           -- 수신자 사번
  schedule_pk TEXT,
  type TEXT NOT NULL,              -- PRE_CHECK_REQUESTED / PRE_CHECK_REPLIED / CHANGE_REQUESTED / CHANGE_FILED / RE_CHECK_DONE / REPORT_ISSUED / SUBMITTED / INSPECTED / SLA_OVERDUE
  message TEXT NOT NULL,
  read_at TEXT,                    -- 읽은 시각 (null이면 안 읽음)
  created_at TEXT NOT NULL,
  meta TEXT                        -- JSON (호출명칭, 허가번호 등)
);
CREATE INDEX idx_n_user ON notifications(user_id, read_at);
CREATE INDEX idx_n_user_created ON notifications(user_id, created_at);
```

### API
- `GET /notifications?unread_only=&limit=` — 알림 목록 (최신순, meta JSON 파싱 포함)
- `GET /notifications/unread-count` — 안 읽음 개수 (종 아이콘 배지용)
- `POST /notifications/mark-read` body: `{ids?: [int]}` — 단건/일괄 읽음 처리 (ids 비면 전체)
- `GET /inspection/dashboard?year=` — 역할별 집계 + 지연 건 상위 20

### UI
- **종 아이콘**: 홈 모바일 AppBar / 데스크탑 사이드바 사용자 카드에 추가
  · 안 읽음 카운트 빨간 배지, 60초마다 폴링
  · 클릭 시 다이얼로그 패널 (안 읽음 토글 + 모두 읽음 + 타입별 색상 배지 + 상대 시각)
- **대시보드 위젯**: 홈에 InspectionDashboardWidget 삽입 (역할 라벨/스코프 헤더 + 상태별 8장 카드 + 재점검·지연 카드 + 지연 상위 5건)

### 외부 연동 (이번 Phase 제외)
- 전파관리소 시스템 API / Slack/Teams webhook / 이메일 / 모바일 푸시 — 모두 Phase 5.x로 분리

**규모**: 백엔드 ~320줄, 프론트 ~600줄 (위젯 2개 + 홈 통합)

---

## Phase 6 (장기): 성능 점검 통합

**목표**: 사내망 반출 이슈 해결 시 성능 점검 자동화

- 알람/출력 데이터 외부 반출 가능해지면 성능 점검을 PRE_CHECK 안에 통합
- 알람 있는 국소 자동 표시, 출력 미달 국소 강조
- 성능 점검 통과 여부도 PRE_CHECK_DONE 조건에 포함

**규모**: 반출 정책 확정 후 재산정

---

## 전체 일정/규모 추정

| Phase | 작업 명 | 백엔드 | 프론트 | 기간 |
|-------|--------|--------|--------|----|
| 1 | 상태머신 + 일정-전산비교 연결 + 기수 제거 | +175줄 | +170줄 | 1주 |
| 2 | 변경개설 분기 (기존 메뉴 재활용) | +545줄 | +520줄 | 2주 |
| 3 | 검사내역서 발급 + 접수 트래킹 | +150줄 | +130줄 | 1주 |
| 4 | 현장 수검 결과 연결 | +120줄 | +150줄 | 1주 |
| 5 | 알림 + 대시보드 | +300줄 | +400줄 | 2주 |
| 6 | 성능점검 통합 | TBD | TBD | 반출 후 |
| **합계** | | **~1,290줄** | **~1,370줄** | **~7주** |

(1인 풀타임 기준 추정, 테스트/디버깅 포함)

---

## 핵심 설계 원칙

1. **`inspection_schedules.pk` 가 모든 흐름의 키** — 일정/전산비교/변경개설/검사내역서/실적이 전부 이 pk로 연결
2. **상태 전환은 항상 로그에 기록** — `inspection_status_log` 가 감사 추적의 근거
3. **권한은 상태별 매트릭스로 정의** — N/W계획팀 / N/W혁신팀 / 품질개선팀 / superadmin
4. **외부 시스템(전파관리소)은 데이터 입력 슬롯만** — 자동 연동을 시도하지 않음 (Phase 5에서 옵션)
5. **산출물은 용도에 따라 분리** — 검사내역서는 즉시 다운로드(S3 X), 변경개설 신고서는 시점 기록만 (xls는 즉시 응답)
6. **기존 코드 최대한 재활용** — DS xlsx 파이프라인, 변경개설 메뉴, 전산비교 로직, 현장수검 Map 그대로 활용
7. **두 status 분리 운영** — `workflow_status` (워크플로우) vs `inspection_results.status` (검사결과). INSPECTED 미만에선 검사결과 숨김
8. **DS DB 패치는 RE_CHECK 단계 한 곳에서만** — 신고 단계에선 DB 보호, 전파관리소 회신 부분 DS 받은 후만 패치
9. **워크플로우는 ERP 누락 케이스에 멈추지 않음** — 외부 사이트(ACTA/시설현황) 확인 책임은 품개팀에 위임

---

## 관련 문서

- [docs/rules/inspection-domain.md](rules/inspection-domain.md) — 검사/실적 도메인
- [docs/rules/ds-xlsx-pipeline.md](rules/ds-xlsx-pipeline.md) — DS xlsx 빌드 파이프라인
- [docs/rules/auth-and-roles.md](rules/auth-and-roles.md) — 인증/권한
- [docs/rules/data-domain.md](rules/data-domain.md) — DS/호출명칭/설치확인서
- [docs/rules/architecture.md](rules/architecture.md) — 구조/배포/DB
