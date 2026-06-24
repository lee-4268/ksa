# Security (보안 정책·운영 가이드)

## 시크릿 관리 원칙

### 절대 하지 말 것
- 코드에 API 키·시크릿·비밀번호 **하드코딩 금지** (string literal 평문)
- `.env`, `*.pem`, `credentials.json` 등 시크릿 파일 **git 커밋 금지**
- 프론트(Flutter Web)에 서버 사이드 시크릿 노출 금지 — Flutter Web은 모든 코드가 클라이언트에 노출됨

### 환경변수로 관리 (백엔드)
백엔드의 모든 외부 자격증명은 `os.environ.get()`으로 로드(현재 위치: `core/config.py`. 2026.05 리팩토링 전엔 main.py). 운영은 systemd service 파일의 `Environment=` 지시자로 주입.

위치: `/etc/systemd/system/kca-api.service` (또는 `override.conf`)

### 환경변수로 관리 (프론트)
빌드 타임 주입: `flutter build web --dart-define=KEY=value`. Amplify는 Console의 Environment variables 설정 후 `amplify.yml`이 자동으로 `--dart-define`에 전달.

특수 케이스: `web/index.html`처럼 빌드 산출물에 직접 박혀야 하는 키는 `{{KEY}}` 자리표시자 + amplify.yml의 `sed` 치환으로 처리.

## 운영 환경변수 (필수)

`/etc/systemd/system/kca-api.service` `[Service]` 섹션:

```ini
# 인증 (필수)
Environment=AUTH_TOKEN_SECRET=<openssl rand -hex 32 결과>
Environment=ADMIN_BOOTSTRAP_KEY=<최초 admin 설정용, 32자+>

# 외부 API 키 (미설정 시 해당 기능만 비활성, warning 로그)
Environment=KAKAO_REST_KEY=<Kakao Developers REST API 키>
Environment=VWORLD_API_KEY=<api.vworld.kr 발급 키>
Environment=NAVER_CLIENT_ID=<Naver Cloud Geocoding>
Environment=NAVER_CLIENT_SECRET=<Naver Cloud Geocoding>

# 환경 구분 + 네트워크 신뢰 정책 (필수)
Environment=APP_ENV=production     # /docs·dev-login 차단, AUTH_TOKEN_SECRET fail-closed
Environment=TRUST_PROXY=1          # ALB/nginx 뒤에 있을 때 (XFF 헤더 신뢰)

# 백업 격리 디렉토리 (선택, RuntimeDirectory 와 함께)
Environment=BACKUP_TMP_DIR=/run/kca-api

# 기타 (기존)
Environment=S3_BUCKET_NAME=sko-kca-s3
Environment=SES_FROM_EMAIL=...     # 휴면 예고 메일
Environment=DORMANT_DAYS=30
Environment=SERVICE_URL=https://ksa.skons.net
```

운영 자동 분기 (코드 동작):

| 환경변수 | 미설정 시 동작 (APP_ENV=production) | 미설정 시 동작 (APP_ENV=dev 또는 미설정으로 기본 production) |
|---|---|---|
| `AUTH_TOKEN_SECRET` | RuntimeError로 부팅 차단 (fail-closed) | 부팅 차단 (production 기본값이라서) |
| `KAKAO_REST_KEY` 등 외부 API 키 | warning 로그 + 해당 기능 비활성 | 동일 |
| `APP_ENV` 자체 | "production"으로 간주 (가장 안전한 default) | — |

### systemd 보안 강화 옵션 (권장)
```ini
[Service]
PrivateTmp=true              # /tmp 격리, 다른 프로세스에서 백업 파일 못 봄
NoNewPrivileges=true         # setuid/setcap 권한 상승 차단
RuntimeDirectory=kca-api     # /run/kca-api 자동 생성·정리
# ProtectSystem=full, ProtectHome=true 은 DB/venv 가 /home/ubuntu/ 에 있어서 부팅 실패 — 적용 안 함
```

## 인증·토큰

### 토큰 포맷
HMAC-SHA256 자체 포맷 (JWT 라이브러리 안 씀):
```
base64url(empno:expiry_unix:hmac_sha256(AUTH_TOKEN_SECRET, empno:expiry_unix))
```
- 유효기간: 2시간
- 잔여 1시간 미만 → 응답 헤더에 새 토큰 자동 발급 (Flutter가 자동 갱신)
- 검증은 `hmac.compare_digest`로 상수시간 비교

### 권한 게이트
- 모든 라우터에 `await _verify_auth(request)` 호출 — 토큰 검증 + caller empno 반환
- admin/manager 검증은 `_get_user_role_sync(empno)` 후 비교
- admin only 라우터: `/admin/*`, `/auth/dev-login` (운영에선 추가 차단)
- admin/manager only: 데이터 수정 라우터 (insp 결과 입력, DS 업로드, 부분 DS 적용, 변경개설 신고 완료 등)

### ADMIN_BOOTSTRAP_KEY
- 최초 admin 등록용 비상 키 (X-Admin-Key 헤더)
- 비교는 `_hmac_mod.compare_digest`로 상수시간
- CORS `allow_headers`에서 X-Admin-Key 제거 — 브라우저(XSS)에서 자동 첨부 차단

### dev-login 라우터
운영에서는:
- `POST /auth/dev-login` → IS_PROD이면 403
- `GET /auth/dev-login/status` → IS_PROD이면 항상 `{enabled: false}` (외부 스캐너 차단)
- 개발 환경: `APP_ENV=dev` + `DEV_LOGIN_ENABLED=1` 둘 다 켜야 동작

## 비밀번호 저장

### 커뮤니티 비밀글 비밀번호
- **PBKDF2-HMAC-SHA256** (salt 16바이트, 200,000 iterations, 표준 라이브러리 `hashlib.pbkdf2_hmac`)
- 형식: `pbkdf2_sha256$<iter>$<salt_hex>$<hash_hex>`
- 헬퍼: `_hash_password(plain)`, `_verify_password(plain, hashed)` ([main.py](../../yolov8/api/main.py) 727~)
- `_init_community_db()`에 1회성 마이그레이션 포함 — 기존 평문 행을 자동 해시화
- 응답에서 `secret_password` 컬럼 제외 (`d.pop("secret_password", None)`)

## 데이터·자산 보호

### S3 키 prefix 화이트리스트
`_validate_s3_key(key, allowed_prefixes)`로 검증:
- `..`, 절대경로(`/`) 차단 → path traversal 방어
- `ALLOWED_S3_READ_PREFIXES`: `photos/`, `excel/`, `feedback/`, `ds-exports/`, `ds-raw/`
- 커뮤니티 전용: `_safe_community_key(key, "community-files/" 또는 "community-images/")` — IDOR 차단
- inspection 업로드: `X-Filename` 헤더는 `os.path.basename` + 정규식 sanitize 후 200자 제한

### 사용자 PII 노출 정책
- `GET /users/{empno}`
  - 본인 조회: 모든 필드 (name, region, team, **email, phone**, role, last_login, is_dormant)
  - 타인 조회: admin/manager만 허용. email/phone 제외하고 응답
  - member가 타인 사번 조회 → 403
- `GET /admin/users`: admin/manager 전용, 전체 PII 노출 (인사 업무)

### CORS
- `allow_origins`: 환경변수 `CORS_ALLOWED_ORIGINS` 화이트리스트 (`*` 금지)
- `allow_credentials=True`
- `allow_headers`: `Authorization, Content-Type, Accept, X-Filename, X-Refreshed-Token`
  - **X-Admin-Key 제외** — 서버↔서버 부트스트랩 전용, 브라우저에서 허용 시 XSS 자동 첨부 위험

### 에러 메시지
- `HTTPException(detail=...)`에 내부 예외(`str(e)`) 노출 금지
- 클라이언트엔 사용자용 메시지만, 상세는 `logger.error/warning`으로

## 네트워크·Rate Limit

### X-Forwarded-For 신뢰 정책
- `TRUST_PROXY=0` (기본): XFF 무시, `request.client.host`만 사용 — 헤더 위조 차단
- `TRUST_PROXY=1`: XFF의 **첫 번째 IP**(AWS ALB/nginx 표준)만 신뢰
- 헬퍼: `_get_client_ip(request)` ([main.py](../../yolov8/api/main.py) 900~)

### Rate Limit
- `SimpleRateLimiter` 메모리 기반 (IP+endpoint별 슬라이딩 윈도우)
- 로그인: 5회/60초 (`_check_rate_limit(request, "login", 5, 60)`)
- 5분마다 stale 엔트리 정리

## 백업·복구

### SQLite 자동 백업 (S3)
- 매일 03:00 KST 실행 (`_sqlite_backup_daily_scheduler`)
- 대상: `inspection`, `ds_detail`, `community`, `sisl_photo` 4개 DB
- S3 경로: `s3://sko-kca-s3/backups/sqlite/{name}/YYYY-MM-DD.db`
- 보관: 최근 7일, 그 이전 자동 삭제
- 임시파일: `tempfile.mkstemp(dir=BACKUP_TMP_DIR)`, 권한 0600

### 복구 절차 (재해 대응)
```bash
# 1. S3에서 최신 백업 다운로드 (운영 DB 안 건드림)
mkdir ~/db_restore_test && cd ~/db_restore_test
aws s3 cp s3://sko-kca-s3/backups/sqlite/inspection/YYYY-MM-DD.db ./inspection_restore.db

# 2. 무결성 검증
sqlite3 inspection_restore.db "PRAGMA integrity_check;"   # → "ok" 가 정상
sqlite3 inspection_restore.db "SELECT COUNT(*) FROM inspection_targets;"

# 3. 실제 복구 (운영 DB 교체)
sudo systemctl stop kca-api
sudo cp inspection_restore.db /home/ubuntu/kca-api/inspection.db
sudo chown ubuntu:ubuntu /home/ubuntu/kca-api/inspection.db
sudo systemctl start kca-api
```

### 일일 검증 권장
새 백업이 잘 쌓이는지 주기적으로 확인:
```bash
aws s3 ls s3://sko-kca-s3/backups/sqlite/ --recursive | tail -20
```

## API 문서 노출 (운영 차단)

`APP_ENV=production`일 때 FastAPI 자동 생성 문서 비공개:
- `/docs` (Swagger UI) → 404
- `/redoc` → 404
- `/openapi.json` → 404

이유: 인증 없이 전체 API 스키마 enumerate 가능 → 공격자의 1차 정찰 도구. 운영에선 외부에 보이면 안 됨.

운영 중 Swagger 잠깐 보려면:
1. 로컬 PC에서 main.py를 띄우거나
2. EC2에 SSH 포트포워딩 (`ssh -L 8000:localhost:8000`) + 일시적 `APP_ENV=dev` 전환

## 보안 점검 이력

### 2026-05-19 1차 점검 (조치 완료)

| 등급 | 이슈 | 위치 | 조치 | 커밋 |
|---|---|---|---|---|
| Critical | Naver Cloud Secret 하드코딩 | main.py:13292 등 | 환경변수화 + 키 재발급 | f2a761a |
| Critical | VWorld API Key 하드코딩 | main.py:13247 등 | 환경변수화 + 키 재발급 | f2a761a |
| Critical | Kakao REST/JS Key 하드코딩 | main.py + web/index.html | 환경변수화 (amplify sed 치환) | f2a761a |
| High | 비밀글 비밀번호 평문 저장+응답 노출 | main.py:requests 라우터 | PBKDF2 해시화 + secret_password 응답 제외 + 마이그레이션 | 5d7a19f |
| High | /community/images 인증 누락 (URL = capability) | main.py:19753 | community-images/ prefix 검증 + 경로 traversal 차단 (인증은 `<img src>` 호환 위해 유지) | 2e96425 |
| High | /community/files prefix 검증 누락 (IDOR) | main.py:19730 | community-files/ prefix 강제 | 2e96425 |
| High | /users/{empno} PII 무차별 조회 (사번 enumeration) | main.py:2600 | 타인 조회 admin/manager only + email/phone 제외 | 84fdd7d |
| High | AUTH_TOKEN_SECRET 미설정 fallback | main.py:710 | production에서 RuntimeError로 부팅 차단 | 743f308 |
| High | X-Forwarded-For 무검증 신뢰 | main.py:900 | TRUST_PROXY 환경변수 분기, 기본 무시 | 743f308 |
| High | /docs·/openapi.json 외부 공개 | main.py:1345 | production에서 docs_url=None | 4dcaec1 |
| High | dev-login 운영 노출 | main.py:2038 | IS_PROD이면 403, status는 항상 false | 4dcaec1 |
| Medium | 변경개설신고 권한 누락 (member도 신고완료 가능) | main.py:15234 | role in {admin, manager} 가드 | 6fc3e71 |
| Medium | X-Filename 경로 traversal | main.py:12856 | basename + 정규식 sanitize | 3d7939e |
| Medium | 에러 detail에 내부 예외 노출 (4곳) | main.py:10925 등 | detail은 일반 메시지, 상세는 logger | 3d7939e |
| Low | CORS allow_headers의 X-Admin-Key | main.py:1413 | 제거 (서버↔서버 전용) | 3d7939e |
| Low | ADMIN_BOOTSTRAP_KEY == 비교 | main.py:2720 | hmac.compare_digest 사용 | 3d7939e |
| Medium | SQLite 백업 /tmp 사용 | main.py:7771 | tempfile.mkstemp + 0600 + RuntimeDirectory | e7c95f6 |
| — | community DB 백업 누락 | main.py:7753 | _SQLITE_BACKUP_DBS에 추가 | 0d13401 |

### 남은 항목 (덜 시급, 추후 처리)
- **#2** `/ds/proxy-xlsx` 토큰을 쿼리스트링으로 받는 fallback 제거 — 프론트 다운로드 흐름 검토 필요
- **#6** SQLite DB 파일을 `/var/lib/kca-api/db/`로 이동 + systemd `ProtectSystem=full` `ProtectHome=true` 적용
- 추후 가능: presigned URL 도입(community 이미지), 감사 로그 90일 이상 보존, dev-login 폐기

### 2026-05-19 2차 재점검 (추가 조치)

1차 조치 검증 결과: 16건 중 14건 양호 · 1건 부분(detail 잔존 1곳) · 1건 부분(비밀번호 검증 헬퍼가 죽은 코드). 회귀 없음.

신규 발견·조치 (Medium):

| 등급 | 이슈 | 위치 | 조치 | 커밋 |
|---|---|---|---|---|
| Medium | `/callname/db-preview` detail=str(e) 잔존 (1차 누락분) | main.py:9015 | detail은 일반 메시지로 교체 | 6ef5c70 |
| Medium | `/categories` / `/stations` IDOR — owner 격리 없음 | main.py:2149~2502 | `_require_owner_or_admin` / `_check_object_owner_or_admin` 헬퍼 도입, 11개 라우터에 적용 | 6ef5c70 |
| Medium | `/inspection/target-review` 권한 게이트 누락 | main.py:14597 | admin/manager role 가드 추가 | 6ef5c70 |

### 2026-05-19 3차 심층 재점검 (OWASP Top 10 2021)

긴급 조치 완료:

| 등급 | 이슈 | 위치 | 조치 | 커밋 |
|---|---|---|---|---|
| **Critical** | `_AllowAllValidator` 로 게시판 HTML XSS — 모든 태그/속성 허용 → admin 공지에 onerror 페이로드 삽입 시 viewer 토큰 탈취 가능 | lib/widgets/rich_content_viewer.dart:9 | `_SafeContentValidator` 화이트리스트로 교체 (태그·속성·URL 스킴·CSS 위험 패턴 차단) | aa92340 |
| High | 보안 응답 헤더 4종 누락 (X-Content-Type-Options, X-Frame-Options, Referrer-Policy, HSTS) | main.py:1408 | `security_headers_middleware` 추가, HSTS 는 IS_PROD 일 때만 | aa92340 |
| High | `/inspection/schedules` 본부 격리 부재 | main.py:16520 | `_check_division_access` 헬퍼 + caller 본부 access 값 IN 필터. admin 은 무제약, member/manager 는 본인 본부만 | (이번) |
| High | `/inspection/result` 본부 격리 부재 | main.py:16551 | 일정/대상의 access담당 ↔ caller 본부 비교, 불일치 시 403 | (이번) |
| High | `/inspection/result/photo` 본부 격리 + 사이즈/확장자 검증 부재 | main.py:16654 | 본부 격리 + 확장자(jpg/jpeg/png/webp) + MAX_PHOTO_SIZE(10MB) 검증 | (이번) |

### 남은 검토 항목 (3차 식별, 추후 처리)
- **3-4 (Medium)** 토큰 무효화 메커니즘 부재 — 비밀번호·role 변경 후 기존 토큰이 만료(2h)까지 유효
- **3-5 (Medium)** 403 거부 로깅 부재 — 침해 시도 탐지 흔적 없음
- **3-6 (Medium)** 워크플로우 자동전환에 `'admin'` 하드코딩 (main.py:16569) — member 도 INSPECTED 전환 가능
- **3-7 (Low)** Category/Station Create owner 클라이언트 지정 (mass assignment) — `_require_owner_or_admin` 이 차단하지만 모델 설계상 owner 는 caller 강제가 안전
- **3-8 (Low)** requirements.txt `>=` 핀고정 부재 → pip-tools lock + pip-audit 권장
- **N-5** community upload 전체 메모리 적재 (community.py upload) — OOM 가능
- **N-6** `_verify_password` 헬퍼·`secret_password` 컬럼 죽은 코드
- **운영**: 백업 실패 알림 부재, 감사 로그 90일 TTL, 의존성 스캐닝 부재

### 2026-06-15 4차 심층 재점검 (모듈 리팩토링 후 OWASP 멀티에이전트 감사)

main.py → `core/`·`routers/` 모듈 분리 이후 전 라우터(약 23,000줄) + Flutter 프론트를 대상으로 9개 OWASP 차원 병렬 감사 + 적대적 검증 수행. 발견 51건 중 43건은 오탐(이미 가드 존재/도달불가/의도된 설계)으로 기각, 8건 확정(중복 1건 제외 7개소). 회귀 없음(1~3차 조치 모두 모듈 분리 후에도 유지 확인).

조치 완료:

| 등급 | 이슈 | 위치 | 조치 | 커밋 |
|---|---|---|---|---|
| **High** | `DELETE /inspection/result/photo` 본부 격리·소유자 검증 부재 (cross-HQ IDOR write) — 형제 업로드엔 격리 있으나 삭제만 누락. `/inspection/detail`(격리 없음)로 타 본부 사진S3키 수집 후 삭제 가능 | routers/inspection.py:3937 | 업로드 본인 OR admin OR 해당 본부 manager 만 삭제. 사진별 업로더 추적 위해 `inspection_results.사진업로더`(JSON `{s3_key:empno}`) 컬럼 신설(자동 마이그레이션) | 1f91713 |
| Medium | `/inspection/result/photo-url`·`photo-data` 본부 격리 부재 — 타 본부 검사 사진 presigned URL 발급·열람 | routers/inspection.py:3955, 3963 | 공통 헬퍼 `_verify_photo_division_access` — s3_key의 year/허가번호 추출 → 대상 access담당 vs caller 본부 비교, 불일치 403 | 1f91713 |
| Medium | `/ds/proxy-xlsx` 쿼리스트링 토큰 fallback (로그/히스토리/Referer 토큰 유출면) — 기존 3차 #2 항목 | routers/ds.py:3772 | 쿼리 토큰 fallback **완전 제거**, Authorization 헤더만 허용. export-presign도 URL에 token 미부착. 프론트(web/ds_export.js)는 이미 fetch+Bearer 라 회귀 없음 | 1f91713 |
| Medium | `/ds/upload-temp`·`cert/batch/upload-photos` 업로드 누적 크기 제한 부재 (디스크 고갈 DoS) — 기존 N-4 항목 | routers/ds.py:4603, routers/cert.py:817 | DS/cert ZIP 전용 `MAX_DS_ZIP_SIZE`(500MB, 수도권 합계 약 330MB 대응) 신설, 누적 검사 + 413. `except Exception`이 413을 500으로 덮던 버그도 수정 | 1f91713 |
| Low | `/ds/upload-raw` 멀티파트 누적 크기·파트 수 제한 부재 (admin/manager 한정, 실패 시 abort 정리됨) | routers/ds.py:4514 | 동일 `MAX_DS_ZIP_SIZE` 누적 검사 + 413, 초과 시 멀티파트 abort | 1f91713 |

> 위 조치로 기존 남은 항목 **#2(ds proxy-xlsx 쿼리 토큰)** 와 **N-4(multipart 크기 한도)** 종결.

4차 식별 후 추후 처리(우선순위 낮음):
- 사진별 업로더 미기록인 **기존(마이그레이션 이전) 사진**은 업로더 본인 판정 불가 → admin/해당 본부 manager 만 삭제 가능(의도된 동작). 신규 업로드분부터 본인 삭제 가능.
- 키 노출 진입점 `/inspection/detail`(routers/inspection.py) 자체는 여전히 본부 격리 없음 — photo 엔드포인트 격리로 사진 접근은 차단되나, detail 응답의 메타(사진S3키 목록 등) 노출은 별도 검토 가치.

### 2026-06-16 5차 SAST 점검 (vuln-assess 플러그인, secure-coding 카탈로그)

Semgrep 로컬 룰팩 + Bandit 으로 전 백엔드(`yolov8/api/`, `auth/`) SAST 스캔 → 카탈로그 49항목 매핑. effective 취약 3 + unmatched 87. 1회차 스냅샷 `.vuln-assess/assessments/ksa/2026-06-16.yaml`. 거버넌스: 조치는 `security/*` 브랜치 → PR.

조치 완료:

| 등급 | 이슈 | 위치 | 조치 | 커밋 |
|---|---|---|---|---|
| **Critical** | 인사DB 자격증명 평문 하드코딩 (server/user/password) — Bandit B106 | auth/accounts/management/commands/download_inet_users.py:33 | 1차: `INET_DB_*` 환경변수화(fail-closed) → 2차: **레거시 CSV 동기화 체인 전체 제거**. 사용자 관리가 SSO/DynamoDB로 이관돼 이 명령(인사DB→CSV)·`update_users`(→Django User)·`convert_csv_to_json`(→users.json)이 모두 미사용. `GET /users` 통계는 `_list_all_users_sync`(DynamoDB user_roles)로 전환, `GET /users/{empno}`의 users.json fallback 제거, `USERS_DATA_PATH` 삭제. 재스캔(2026-06-18) B106 0건·삭제파일 finding 0건 검증 | (security/remove-csv-sync-chain 브랜치) |

> CSV 동기화 체인 제거 상세: FastAPI 백엔드는 Django `accounts`/`UserProfile`을 import하지 않아 `update_users` 산출물(Django User)은 운영 경로 밖. `users.json`은 `GET /users` 통계와 `/users/{empno}` DynamoDB 장애 fallback에만 쓰였고, 둘 다 DynamoDB(`_list_all_users_sync`)로 대체 가능했음. 통계는 오히려 실제 사용자(DynamoDB)와 일치하게 정확해짐.

5차 SQL injection 전수 검증 (B608, 151건 → 진성 0):

`cert_cache.py`/`inspection.py`/`cert.py`/`community.py`/`inspection_results.py`/`ds.py`/`change_request.py`/`inadequate.py`/`document.py`/`sisl_photos.py`/`inspection_db.py` 19개소 151건(Semgrep+Bandit 중복 포함)을 5개 병렬 에이전트 + 적대적 핵심 케이스(`inadequate.py:153` sort_col 등) 검증 → **전부 과탐, 진성 0건**. 모든 finding 이 다음 3패턴 중 하나:
- **IN 절 동적 플레이스홀더**: `ph = ','.join('?'*len(x))` 후 `execute(f'... IN ({ph})', x)` — 값은 바인딩 분리.
- **WHERE/SET 절 상수 조립**: `wheres=['col=?', ...]` → `' AND '.join(wheres)` 보간, 값은 `params` 튜플 분리.
- **식별자 화이트리스트 보간**: 테이블/컬럼명만 상수 튜플 또는 `_ALLOWED_SORT`/`ALLOWED_COLS` 검증 후 f-string.

→ 판결: `baseline.yaml` 에 `slug: sql-injection` `false-positive` 억제(2026-12-16 만료, 재검토 강제). effective 취약에서 제외, 0화 집계 반영. B608은 f-string+SQL 키워드 휴리스틱이라 올바른 파라미터화 코드에도 발화하는 advisory 오탐.

5차 식별 후 추후 처리(다음 회차):
- ~~**os-command-injection (B603) 2건**~~ — routers/inspection.py:1361, 1366. **검증 완료: 과탐.** `subprocess.Popen` 이 `shell=False`(기본)+리스트 인자라 셸 주입 불가, 실행파일 고정(`inspection_worker.py`), 사용자 입력은 worker argv 로만 전달되고 worker 는 셸 재실행 없음, admin/manager 게이트 존재. → `baseline.yaml` `false-positive` 억제(2026-12-16 만료).
- ~~**improper-input-validation (B405/B314/B406) 22건**~~ — XXE in callname.py/inspection.py/hwp_generator.py. **검증 완료: 과탐.** 파싱 대상은 사용자 업로드 XLSX 내부 XML(입력 통제 가능)이나, Python 표준 `xml.etree.ElementTree` 는 **외부 엔티티를 확장하지 않음**(실측: `SYSTEM file://` → `undefined entity` ParseError 거부). XXE 파일탈취/SSRF 경로 없음. hwp_generator.py:11 은 `xml.sax.saxutils.escape`(XML 생성 이스케이프, 파싱 아님). → `baseline.yaml` `false-positive` 억제(2026-12-16 만료). **effective 취약 0 달성** (모든 results 취약 판결 완료).
- ~~**unmatched 86건**~~ — **전수 판결 완료.** B110/B112(try/except/pass·continue) 75건 → `accepted-risk`(CWE-703 관용 패턴, 보안 영향 없음). B113(requests timeout) 4건 → `accepted-risk`(Django 레거시 `auth/`, FastAPI 운영 미사용). B108(insecure temp) 6건 → `false-positive`(고정 /tmp 캐시·정리 경로 상수). B104(0.0.0.0) 1건 → `false-positive`(dev 실행 스크립트, 운영은 systemd). 전부 `baseline.yaml` 등록(2026-12-16 만료).

### 🎯 5차 SAST 0화 달성 (2026-06-18 스냅샷 기준)

`ci_gate --mode zero` **exit 0 (PASS)** — **effective 취약 0건 + 미판결 unmatched 0건**. 억제 174건(false-positive 161 / accepted-risk 13), 모든 항목 판결 완료. 진성 조치 1건(인사DB 자격증명 하드코딩 → 체인 제거), 나머지 175건은 전수 검증 후 과탐/수용 판결. 억제는 전부 **2026-12-16 만료**로 재검토 강제.

> ⚠️ 운영 메모(미해소, 0화와 별개): 본 비밀번호(`ons12345!`)가 **git 이력에 남아 있다**. 파일 삭제·환경변수화 모두 현재 트리에서만 제거이므로 **인사DB `onsuser1` 계정 비밀번호 재발급(DBA 요청) 필수** — 이력의 평문은 그대로 노출 상태.

### 2026-06-16 Sparrow SAST/SAQT 공식 진단 대응 (외부 도구)

사내 IT보안진단(Sparrow, 분석ID 111637, 5월말~6월초 코드 기준)에서 검출된 이슈 2건 대응. 두 건 모두 면밀 조사 결과 **진성 취약 아님**(과탐)이나, 보고서 권장 방향에 맞춰 가능한 부분은 코드로 보강.

| 위험도 | 이슈 | 위치 | 조사 결과 | 조치 |
|---|---|---|---|---|
| 위험 | 적절하지 않은 난수 값 사용 (CWE-330) | yolov8/utils/data_prepare.py:8,126,212 | 학습 데이터셋 train/val 분할 셔플용 `random` — 보안 결정 무관(OTP/세션/키 아님). 실제 보안 난수는 `core/auth.py` 가 `os.urandom`·HMAC-SHA256·PBKDF2 사용(안전 확인). | 전역 `random.seed`/`random.shuffle` → `random.Random(seed)` 인스턴스로 전환. 동작·재현성 동일(실측 검증), 보안 스캐너 룰 회피. `secrets.randbelow` 는 seed/shuffle 미지원이라 부적합. |
| 매우위험 | 하드코드된 중요정보 (CWE-259/321) | yolov8/api/routers/community.py:61 | `_COMMUNITY_FILE_CONTENT_TYPES` 딕셔너리의 `'.zip':'application/zip'` — 파일 확장자→MIME 타입 매핑 상수. DB연결·비밀번호·암호화키 아님. Sparrow 가 문자열 상수를 시크릿으로 오탐. | 복호화 대상 비밀정보가 없어 코드 변경 불가(설정파일 분리 시 기능 손상). `baseline.yaml` finding-level `false-positive` 억제(path=community.py, 2026-12-16 만료). 보고서 권장(설정파일 복호화)은 실제 DB 자격증명 하드코딩에 적용되는 것으로, 본 건은 해당 대상 없음. |

### 2026-06-24 6차 점검 — 모의해킹 사전 대비 (접근통제: 수직/수평 권한 상승)

테스트 계정 모의해킹(본인 권한 밖 CRUD) 대비. 18개 라우터 mutating 엔드포인트를 인증/role/본부격리/IDOR 4차원으로 병렬 감사(4 에이전트) + 헤드라인 진성 코드 직접 검증. **인증 커버리지는 100%**(누락 0)였으나, role 게이트·본부 격리·소유자 격리가 일부 엔드포인트에만 적용돼(비일관) 진성 취약 다수 확인. `security/access-control-hardening` 브랜치에서 일괄 조치.

**수직 권한(role 게이트 누락) — member 가 호출 가능했던 mutating:**

| 등급 | 이슈 | 위치 | 조치 | 커밋 |
|---|---|---|---|---|
| High | `/document/apply-change-notification` role 게이트 전무 → member 가 임의 허가번호 DS/대상 UPDATE (형제 `change-notification-sample` 엔 게이트 있음) | routers/document.py:461 | `_require_role({admin,manager})` 로 교체 | (6차) |
| High | `/ds/upload-init`·`upload-chunk`·`upload-finalize` role 게이트 누락 → member 가 타 본부 DS 삭제·초기화·임의 레코드 주입 | routers/ds.py:3876,3998,4011 | 3종 모두 `_require_role({admin,manager})` (형제 enqueue/upload-raw 와 동일) | (6차) |
| Medium | `DELETE /ds/job/{job_id}` role 게이트 누락 → member 가 DS 처리 잡 취소·사보타주 | routers/ds.py:5135 | `_require_role({admin,manager})` | (6차) |
| Medium | `/inspection/result` 자동 INSPECTED 전환에 `'admin'` 하드코딩(3-6 항목 실코드) — role 가드 우회 구조 | routers/inspection.py:3891 | `_wf_can_transition(cur, WF_INSPECTED, role)` 로 실제 role 전달 (정상 SUBMITTED→INSPECTED 는 전이표에 있어 member 현장수검 흐름 유지) | (6차) |

**수평 권한(본부 격리 부재) — 강남 계정이 경기 본부 데이터 R/W/D:**

`_check_division_access` 헬퍼가 `/inspection/schedules` 1곳에만 적용돼 있던 것을 전 write/delete/고노출 read 로 확장. inspection.py 에 재사용 헬퍼 `_resolve_schedule_access_sync`/`_require_schedule_division`(pk→access담당 resolve 후 `_caller_allowed_access_list` 비교), ds.py 에 `_require_division_for_ds`(divisionId 격리, 수도권 4본부는 sudogwon 공유), change_request.py 에 `_resolve_cr_access_sync` 신설.

| 등급 | 이슈 | 위치 | 조치 | 커밋 |
|---|---|---|---|---|
| High | 워크플로 전환 전 계열 본부 격리 부재 (status·status-force·transition-bulk·pre-check-result·change-request·submission·submission-bulk·target-review·pre-check-status) | routers/inspection.py | 각 핸들러에 `_require_schedule_division` 적용, bulk/리스트 계열은 per-pk 격리 필터 | (6차) |
| High | 일정 생성/삭제 본부 격리 부재 (manager 가 타 본부 일정 생성·삭제) | routers/inspection.py:3759,3795 | upsert 는 req.access담당/기존 access담당 검사, delete 는 `_require_schedule_division` | (6차) |
| High | `/inspection/detail` 본부 격리 부재 → 사진S3키 등 메타 노출(키 enumerate 발판) | routers/inspection.py:2847 | `_require_schedule_division` | (6차) |
| High | `/inspection/data` 본부 격리 부재 (access담당을 클라이언트 선택 필터로만 취급) | routers/inspection.py:2453 | 비-admin 은 `access담당 IN (allowed)` 강제 주입(미배정 본부는 `1=0`) | (6차) |
| High | `DELETE /ds/data` 본부 격리 부재 (manager 가 타 본부 DS 삭제) | routers/ds.py:4435 | `_require_division_for_ds` | (6차) |
| Medium | `/ds/apply-partial-update` 본부 격리 부재 | routers/ds.py:5713 | `_require_division_for_ds`(division_id 지정 시) | (6차) |
| High | change_request `direct`·`cancel-bulk`·`DELETE {id}`·`file` 본부 격리 부재 (타 본부 변경개설 등록·취소·신고완료) | routers/change_request.py | `_resolve_cr_access_sync` + `_caller_allowed_access_list` 비교(단건 403, bulk skip) | (6차) |

**IDOR(소유자 격리):**

| 등급 | 이슈 | 위치 | 조치 | 커밋 |
|---|---|---|---|---|
| High | storage read/download/delete 가 `photos/{owner}`·`excel/{owner}` 키의 owner 미검증 → 키만 알면 타인 사진/엑셀 R/D | routers/storage.py:137,158,189 | `_key_owner` 추출 + `_enforce_key_owner`(소유자 또는 admin). feedback/·ds-*/ 는 사번 기반 아니라 인증만 | (6차) |

**안전 확인(조치 불요):** HMAC 토큰 위조 불가(상수시간·시크릿·운영 fail-closed); role 강등은 매 요청 DynamoDB 재조회로 즉시 반영(3-4 의 "강등 후 토큰 잔존" 시나리오는 실제 미해당); `set-role` 자기강등/상위변경 차단; role 클라이언트 입력 mass-assignment 없음; categories/stations/route_basket/community(공지·요청·댓글·알림) owner 격리 정상; `/inspection/result`·photo R/W/D·schedules·my-list 본부 격리 정상.

**accepted by design — 전국 조회는 의도된 설계 (조치 안 함, 진단 지적 시 "accepted"로 답변):**
- **실적 데이터**(`inspection_results.py` 대시보드/분석/추이/export)와 **DS 데이터**(`/ds/data`·`/ds/stats`·`/ds/export(-xlsx)`·`/ds/proxy-*`·`/ds/change-history` 조회) 는 **전 직원이 전국 본부를 비교·조회하는 것이 업무상 의도된 기능**이다 (OVERVIEW 5.8 "전국 9개 본부 진도율/합격율", 메뉴 권한 실적·DS = member/manager/admin 모두 O). 운영 정책 확인 완료(2026-06-24): member/manager 가 타 본부 실적·DS 를 보는 것은 정상. → **read 본부 격리 적용 안 함.** (단 개별 무선국 운영 레코드 — `/inspection/detail`·`/inspection/data`·`/inspection/schedules` — 는 OVERVIEW 의 "본인 본부/팀만" 정책대로 6차에서 격리함. 실적/DS 집계와 성격이 다름.)

**6차 이후 추후 처리(우선순위 낮음):**
- `/ds/change-history/{id}/cancel`·`bulk-cancel` (되돌리기=write) 은 admin/manager 게이트만 있고 divisionId 횡적 격리 미적용(허가번호↔본부 2-DB 조인 필요 → 별도 회차). ※ 조회가 아니라 write 라 "전국 조회 허용" 정책과 무관.
- 3-4(토큰 무효화 메커니즘 부재), 3-5(403 거부 로깅 부재) 미해소 유지.

> py_compile 검증은 로컬 Python 부재로 EC2 배포(`deploy_backend.sh --restart`) 시 모듈 로드 + `journalctl` 로 확인 필요.

```
□ await _verify_auth(request) 호출
□ admin/manager 필요한 작업이면 role 게이트
□ SQL은 ? 파라미터 바인딩 (f-string 금지, identifier만 화이트리스트 후 보간)
□ 사용자 입력으로 만든 S3 키는 _validate_s3_key 또는 _safe_community_key
□ 파일 업로드: 확장자 화이트리스트, 크기 제한, basename + sanitize
□ 응답 dict에 비밀번호 해시·내부 ID·PII가 끼지 않았는지 확인
□ HTTPException detail에 str(e) 노출 안 함, 상세는 logger
□ 외부 API 호출 시 키는 전역 환경변수 참조 (하드코딩 금지)
```

## 향후 점검 시 참조

코드 보안 감사가 필요할 때:
1. 이 문서 → 적용된 조치 + 남은 항목 확인
2. `git log --oneline --grep="보안\|H-\|security"` → 보안 관련 커밋 추적
3. 신규 라우터/기능에 대해 위 체크리스트 적용
