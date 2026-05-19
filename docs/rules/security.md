# Security (보안 정책·운영 가이드)

## 시크릿 관리 원칙

### 절대 하지 말 것
- 코드에 API 키·시크릿·비밀번호 **하드코딩 금지** (string literal 평문)
- `.env`, `*.pem`, `credentials.json` 등 시크릿 파일 **git 커밋 금지**
- 프론트(Flutter Web)에 서버 사이드 시크릿 노출 금지 — Flutter Web은 모든 코드가 클라이언트에 노출됨

### 환경변수로 관리 (백엔드)
백엔드 `main.py`의 모든 외부 자격증명은 `os.environ.get()`으로 로드. 운영은 systemd service 파일의 `Environment=` 지시자로 주입.

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
- 대상: `inspection`, `ds_detail`, `community` 3개 DB
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

## 보안 작업 체크리스트 (새 라우터 추가 시)

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
