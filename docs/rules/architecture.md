# Architecture

## 기술 스택

| 계층 | 기술 |
|------|------|
| 프론트엔드 | Flutter (Dart 3.10+), Provider 패턴 |
| 백엔드 | FastAPI (Python), Uvicorn, systemd |
| DB | SQLite (inspection.db, cert_cache.db), DynamoDB (사용자/역할/DS) |
| 스토리지 | AWS S3 (sko-kca-s3) |
| AI | YOLOv8n-cls (철탑 분류), AWS Lambda |
| 배포 | Amplify (프론트), EC2 (백엔드) |

## 디렉토리 구조

```
lib/
├── config/          # API 키, 환경 설정
├── models/          # 데이터 모델 (RadioStation + Hive)
├── providers/       # StationProvider (ChangeNotifier)
├── services/        # 31개 서비스 (비즈니스 로직)
├── screens/         # 28개 화면
│   └── admin/       # 관리자 전용 화면 (3개)
└── widgets/         # 공통 위젯 (지도, 프로그레스 다이얼로그 등)

yolov8/api/
└── main.py          # FastAPI 백엔드 (120+ 엔드포인트, 단일 파일)

docs/rules/          # 작업별 참조 문서 (이 폴더)
```

## DB 스키마 (SQLite: inspection.db)

### inspection_targets — 수검 대상
```sql
year, sheet, 허가번호, 호출명칭, 설치장소, 도로명주소,
skt본부, access담당, 품질개선팀, 위도, 경도, ...
```

### inspection_schedules — 수검 일정
```sql
pk (year#허가번호), year, 허가번호, access담당, 품질개선팀,
수검예정주차, 검사관, 조, 등록자, 등록일시,
-- Phase 1: 워크플로우 상태 머신
workflow_status DEFAULT 'REGISTERED',
status_updated_at, status_updated_by,
pre_check_result TEXT,    -- JSON (전산비교 결과)
-- Phase 3: 검사내역서 발급/접수 트래킹
report_issued_at, report_issued_by,
submission_no, submitted_at
```

### inspection_status_log — 워크플로우 전환 이력 (Phase 1)
```sql
id, schedule_pk, from_status, to_status, changed_by, changed_at, memo
```

### change_request — 변경개설 요청 (Phase 2)
```sql
id, schedule_pk, 허가번호, field, before_value, after_value,
장치번호, memo, status (REQUESTED/FILED/APPLIED/VERIFIED),
requested_by, requested_at, filed_by, filed_at, applied_at
```

### inspection_results — 현장 검사 결과
```sql
pk (year#허가번호), status, 검사일, 메모, 철탑형태, 사진S3키, 입력자, 입력일시,
진행여부, 성능서류, 불합격내용, 불합격상세, 공용화대상, ...,
-- Phase 4: 일정 연결 + 재점검 필요 플래그
schedule_pk TEXT DEFAULT '',
needs_recheck TEXT DEFAULT '0'    -- '1' = 불합격/부적합 → 혁신팀이 수동으로 재점검 일정 등록
```

### inspection_results_raw — 실적 결과장 (업로드 데이터)
```sql
year, region, 주차별, 허가번호, 통합시설코드, 합불여부,
성능서류, 장비타입, 장비타입간소화, ...
```

### notifications — 시스템 내 알림 (Phase 5)
```sql
id, user_id (수신자 사번), schedule_pk,
type (PRE_CHECK_REQUESTED/PRE_CHECK_REPLIED/CHANGE_REQUESTED/CHANGE_FILED
      /RE_CHECK_DONE/REPORT_ISSUED/SUBMITTED/INSPECTED/SLA_OVERDUE),
message, read_at, created_at,
meta TEXT    -- JSON (호출명칭, 허가번호, from_status, to_status)
```
- 워크플로우 전환 시 `_wf_record_log_sync` 내부에서 자동 생성
- 이메일/푸시 미사용 (시스템 내 알림 전용)

## SQLite: cert_cache.db

```sql
cert(zpwino, zpwina, zpwiadr, zpcode, zpcname, eqp_type, ...)
-- 인덱스: zpwino, zpwina, zpwiadr
```
- S3 CSV에서 주기적 빌드 (TTL 기반)
- 설치확인서 조회 + 장비타입간소화 5단계 fallback에 사용
- 서버 시작 시 빌드, 완료 전까지 xlsx 빌드 시작 안 함

## DynamoDB 테이블

| 테이블 | PK | 용도 |
|--------|-----|------|
| kca-users | user_id (사번) | i-NET 사용자 정보 (read-only) |
| kca-user-roles | user_id | KSA 역할/로그인/휴면 관리 (role, last_login, is_dormant) |
| kca-audit-logs | id | 감사 로그 (90일 TTL) |
| kca-ds-records | — | DS 데이터 레코드 |
| kca-ds-uploads | — | DS 업로드 메타데이터 |
| kca-ds-jobs | — | DS 처리 작업 상태 |

## S3 버킷 구조 (sko-kca-s3)

```
photos/          # 현장 수검 사진
excel/           # 엑셀 파일
feedback/        # 피드백
ds-raw/          # DS 원본 ZIP
  {divisionId}/{divisionCode}_{importDate}.zip
ds-exports/      # DS 빌드된 xlsx 캐시
  {divisionId}/{divisionCode}_{importDate}.xlsx          # 전체 (비수도권)
  {divisionId}/{divisionCode}_{importDate}_{hdqt}.xlsx   # 수도권 본부별
```
- `ALLOWED_S3_READ_PREFIXES`: `photos/`, `excel/`, `feedback/`, `ds-exports/`, `ds-raw/`

## 배포

### 프론트엔드 (Amplify)
```bash
git push origin main  # → Amplify 자동 빌드/배포
```

### 백엔드 (EC2) — GitHub API 직접 다운로드 방식
```bash
curl -H "Authorization: token {token}" \
  -H "Accept: application/vnd.github.v3.raw" \
  -o /home/ubuntu/kca-api/main.py \
  "https://api.github.com/repos/T-O-Mega/KCA/contents/yolov8/api/main.py" \
  && sudo systemctl restart kca-api

# 로그 확인
journalctl -u kca-api --no-pager -n 80
```

### 환경변수 (systemd 서비스 파일)
```ini
# /etc/systemd/system/kca-api.service [Service] 섹션
Environment=AUTH_TOKEN_SECRET=...
Environment=ADMIN_BOOTSTRAP_KEY=...
Environment=S3_BUCKET_NAME=sko-kca-s3
Environment=DEV_LOGIN_ENABLED=1        # 개발 모드 (dev-login 활성화)
Environment=SES_FROM_EMAIL=...         # 휴면 예고 메일 발신 주소 (AWS SES 검증 필요)
Environment=DORMANT_DAYS=30            # 휴면 기준일 (기본 30)
Environment=SERVICE_URL=https://...    # 메일 본문 링크용 서비스 URL
```
변경 후: `sudo systemctl daemon-reload && sudo systemctl restart kca-api`

## 플랫폼별 조건부 컴파일
- `*_stub.dart` — 기본 (빈 구현)
- `*_web.dart` — 웹 전용 (dart:js_interop 사용)
- `*_mobile.dart` — 모바일 전용 (네이티브 SDK)
- import 방식: `import 'stub.dart' if (dart.library.html) 'web.dart'`

## 백그라운드 태스크 구조

```
서버 시작
├── cert_cache 빌드 (asyncio.to_thread)     → _cert_cache_db_path 설정
├── _job_worker_loop (asyncio.create_task)  → DS 잡 큐 순차 처리 (싱글턴)
└── _xlsx_build_worker (create_task, 지연)  → xlsx 빌드 큐 처리
     └── cert_cache 완료 후 시작 (GIL 경합 방지)
```

### DS 잡 처리 흐름
```
POST /ds/enqueue → kca-ds-jobs에 queued 상태 등록
→ _job_worker_loop 감지 → processing 상태로 변경
→ 서브프로세스에서 XLS 파싱 + DynamoDB 저장
→ 완료 후 _xlsx_build_queue에 등록
→ _xlsx_build_worker 감지 → xlsx 빌드 → S3 저장
```
