# Auth & Roles (인증/권한)

> 시크릿 정책·보안 점검 이력·운영 환경변수 전체 목록은 [security.md](./security.md) 참조.

## 인증 흐름

### 일반 로그인 (SSO)
```
사번+비밀번호 → POST /auth/login → SKons SSO 검증 → HMAC 토큰 발급
→ GET /users/{empno} → DynamoDB 사용자 정보 + 역할 조회
→ kca-user-roles에 자동 등록 (없으면 member)
```

**사번 정규화 규칙**: 실사번은 대문자로 변환하되, `test_` 프리픽스 계정(예: `test_user`, `test_admin`)은 SSO가 대소문자를 구분하므로 원문 그대로 전달. 규칙은 백엔드 `core/auth.py`의 `_normalize_empno()`와 프론트 `auth_service.dart`의 `_normalizeEmpno()`에 동일하게 구현 — 로그인, 관리자 사용자 목록 dedup에서 함께 사용하므로 한쪽만 바꾸면 안 됨 (역할 부여 키가 어긋남).

### 로그인 폼 자동완성 (2026-08)
- 아이디/비밀번호 필드에 `AutofillGroup` + `AutofillHints.username/password` — 브라우저 비밀번호 관리자 자동완성 인식. 1차 인증 성공 시 `TextInput.finishAutofillContext()`로 저장 프롬프트 트리거
- OTP 첫 칸에 `AutofillHints.oneTimeCode` — 키보드 OTP 제안. 6자리 붙여넣기 시 전 칸 분배 + 자동 검증 (기존 maxLength:1이 붙여넣기를 1자로 잘라 동작하지 않던 문제 수정)
- 크롬+삼성패스: 크롬은 기본이 자체 비밀번호 관리자라, 삼성패스를 쓰려면 Android 크롬 설정 → 자동완성 서비스에서 삼성패스 선택 필요. SMS 완전 자동입력(WebOTP)은 SMS 본문에 도메인 서명(`@도메인 #코드`)이 필요해 인프라(발송 주체) 협조 사항

### 개발용 테스트 로그인
```
POST /auth/dev-login (DEV_LOGIN_ENABLED=1 + APP_ENV=dev 둘 다 필요)
→ SSO 인증 없이 임의 계정으로 토큰 발급
→ _dev_users 메모리 캐시에 저장
→ /users/{empno}, /inspection/my-list 등에서 fallback으로 사용
```

활성화: systemd 서비스 파일에 `Environment=APP_ENV=dev` + `Environment=DEV_LOGIN_ENABLED=1`

**운영 차단**: `APP_ENV=production`이면 (또는 미설정 — 기본값) `/auth/dev-login`은 403, `/auth/dev-login/status`는 항상 `{enabled: false}` 반환. 외부 스캐너가 dev-login 활성 인스턴스를 식별하지 못하도록 차단.

### 토큰 구조
```
base64url(empno:expiry_unix:hmac_sha256(AUTH_TOKEN_SECRET, empno:expiry_unix))
```
- 유효기간: 2시간
- 잔여 1시간 미만 → 응답 헤더에 새 토큰 자동 발급
- Flutter 측에서 자동 갱신 처리
- 검증은 `hmac.compare_digest`로 상수시간 비교
- `AUTH_TOKEN_SECRET`은 운영(APP_ENV=production)에서 미설정 시 RuntimeError로 부팅 차단 (fail-closed)

## 역할 체계

| 역할 | 백엔드 값 | 프론트 enum | 권한 |
|------|----------|------------|------|
| 시스템 관리자 | `admin` | `superAdmin` | 모든 기능, 사용자 관리, 역할 변경 |
| 본부 관리자 | `manager` | `divisionAdmin` | 결과장 업로드, DS 업로드/삭제, 사용자 조회 |
| 일반 사용자 | `member` | `member` | 조회, 현장 수검, 검사 결과 입력 |

### 권한별 메뉴 노출

| 메뉴 | member | manager | admin |
|------|--------|---------|-------|
| 실적 관리 | O | O | O |
| 일정 및 통계 | O | O | O |
| 현장 수검 Map | O | O | O |
| DS 데이터 | O | O | O |
| 호출명칭/설치확인서/전산비교 | O | O | O |
| 커뮤니티 | O | O | O |
| 결과장 업로드 버튼 | X | O | O |
| 수검 관리 화면 버튼 (일정탭) | X | O | O |
| 관리자 메뉴 | X | X | O |

### 프론트 권한 체크
```dart
final auth = context.read<AuthService>();
auth.isSuperAdmin    // admin
auth.isDivisionAdmin // admin || manager
// 메뉴: _isAdmin = auth.isSuperAdmin || auth.isDivisionAdmin
```

### 사용자 PII 조회 정책 (/users/{empno})
- **본인 조회** (`caller_empno == empno`): 모든 필드 (name, region, team, **email, phone**, role, last_login, is_dormant)
- **타인 조회** (admin/manager만): name, region, team, role 등 — **email/phone 응답에서 제외**
- 일반 member가 타인 사번 조회 → 403 (사번 enumeration으로 전 직원 연락처 수집 차단)
- 관리자 패널 전체 사용자 목록은 별도 라우터 `/admin/users` 사용

## 본부 매핑

### region 문자열 → divisionId
```dart
'강남본부'/'강남' → 'gangnam'
'강북본부'/'강북' → 'gangbuk'
'인천본부'/'인천' → 'incheon'
'경기본부'/'경기' → 'gyeonggi'
'강원본부'/'강원' → 'gangwon'
'충청본부'/'충청' → 'chungcheong'
'경북본부'/'경북' → 'gyeongbuk'
'경남본부'/'경남' → 'gyeongnam'
'서부본부'/'서부' → 'seobu'
```

### 수도권 4개 본부 → sudogwon (divisionCode=10)
```
강남, 강북, 인천, 경기 → divisionId='sudogwon'
```
DS 조회/업로드 시 4개 본부가 같은 divisionId를 공유하며, xlsx는 본부별로 분리 저장.

### region → access담당 (검사 데이터 매칭)
```
"경북Access담당" → .replace("Access담당", "") → "경북"
→ inspection_schedules.access담당 = "경북" 매칭
```

## 테스트 계정 (dev-login)

각 본부 첫 번째 품질개선팀을 기본 team으로 설정 (경북은 포항품질개선팀).
실계정 로그인 시엔 DynamoDB Users 테이블의 team 값이 사용됨.

| empno | 이름 | region | team | role |
|-------|------|--------|------|------|
| TEST_GN | 테스트_강남 | 강남Access담당 | 강남품질개선팀 | member |
| TEST_GB | 테스트_강북 | 강북Access담당 | 용산품질개선팀 | member |
| TEST_IC | 테스트_인천 | 인천Access담당 | 북인천품질개선팀 | member |
| TEST_GG | 테스트_경기 | 경기Access담당 | 하남품질개선팀 | member |
| TEST_GW | 테스트_강원 | 강원Access담당 | 원주품질개선팀 | member |
| TEST_CC | 테스트_충청 | 충청Access담당 | 대전품질개선팀 | member |
| TEST_KB | 테스트_경북 | 경북Access담당 | 포항품질개선팀 | member |
| TEST_KN | 테스트_경남 | 경남Access담당 | 동부산품질개선팀 | member |
| TEST_SB | 테스트_서부 | 서부Access담당 | 서광주품질개선팀 | member |

## DynamoDB 테이블

### kca-users (read-only, i-NET 연동)
- PK: `user_id` (사번)
- 필드: name, region, team, email, phone_number

### kca-user-roles (KSA 전용)
- PK: `user_id`
- 필드: role (admin/manager/member), last_login (UTC ISO), is_dormant (bool)
- 최초 로그인 시 자동 등록 (member)
- 로그인 시 last_login 자동 갱신
- 30일 미로그인 → is_dormant=true (매일 09:00 KST 배치)

### _dev_users (메모리 캐시)
- dev-login 시 저장
- `/users/{empno}`, `/inspection/my-list`, `/inspection/my-list/weeks`에서 fallback
- 서버 재시작 시 초기화
- **my-list 조회 시 is_dev=True이면 팀 무관 전체 조회** (실계정은 AND 조건)

## 감사 로그 (kca-audit-logs)

- PK: `entityType` / SK: `{timestamp}#{uuid}` / TTL 90일
- 기록: `core/auth.py` `_record_audit_log_sync(action, entity_type, entity_id, user_id, details)`
  — `details` 는 item 에 그대로 merge 되므로 상세는 `{"newData": json.dumps(...)}` 형태로 넣는다
- 조회: GET `/admin/audit-logs` (admin/manager) → 화면 `lib/screens/admin/audit_log_screen.dart`

### 로그인/로그아웃 기록
| 이벤트 | action | entityType | entityId | newData |
|--------|--------|-----------|----------|---------|
| SSO OTP 인증 성공 (`/auth/verify-otp`) | `LOGIN` | `User` | 사번 | method=sso_otp, ip |
| dev-login (`/auth/dev-login`) | `LOGIN` | `User` | 사번 | method=dev_login, role, ip |
| 로그아웃 (`/auth/logout`) | `LOGOUT` | `User` | 사번 | ip |

- 로그아웃은 `_blacklist_token()` **전에** `_verify_token()` 으로 사번을 뽑는다 (블랙리스트 등록
  후에는 None 이 반환됨). 만료·손상 토큰도 로그아웃은 성공시켜야 하므로 `_verify_auth` 를 쓰지 않는다.
- 로그인 실패(비번 오류·OTP 오류)는 기록하지 않는다. 필요해지면 별도 논의.

### ⚠️ action 문자열은 대문자 enum 이름과 일치시켜야 한다
프론트가 `AuditAction.values.firstWhere((a) => a.name.toUpperCase() == json['action'], orElse: update)`
로 파싱한다. 일치하지 않으면 **전부 '수정'으로 표시된다** — `inspection_result_upsert` 가
화면에 `inspection_result - 수정` 으로 보이던 원인. 유효값은
`CREATE/UPDATE/DELETE/APPROVE/REJECT/SUSPEND/RESTORE/ROLLBACK/LOGIN/LOGOUT`.
기존 소문자 snake_case action 들은 표시만 부정확하고 데이터는 남아 있다.

### entityType 목록은 코드에 하드코딩되어 있다
`entityType` 이 파티션 키라서 DynamoDB API 로 열거할 수 없다. `/admin/audit-logs` 의 '전체'
조회는 `routers/users.py` `_AUDIT_ENTITY_TYPES` 를 순회하며 파티션별 최신 N건을 query 해서
병합·정렬한다(과거에는 `scan(Limit=n)` 이라 특정 유형만 화면을 채웠다).
**새 entityType 으로 감사 로그를 남기면 `_AUDIT_ENTITY_TYPES` 와 화면 드롭다운에도 추가할 것.**

현재 등록된 entityType: `User`, `inspection_schedule`, `inspection_result`,
`inspection_targets`, `DSData`, `ds_detail`, `ds_변경이력`, `callname_sample`, `sisl_photo`

## 휴면계정 관리

### 배치 스케줄러
- 매일 09:00 KST 실행 (`_dormant_account_daily_scheduler`)
- kca-user-roles 전체 스캔 → last_login 기준 경과일 계산
- D-7, D-3, D-1: SES HTML 예고 메일 발송 (notified_d7/d3/d1 플래그로 중복 방지)
- D+0 (30일 초과): `is_dormant=true` 마킹 → 로그인 시 403 반환

### 환경변수 (필수)
```ini
SES_FROM_EMAIL=no-reply@example.com   # AWS SES 검증된 발신 주소
DORMANT_DAYS=30                        # 기본값 30
SERVICE_URL=https://your-service.com  # 메일 본문 링크용
```

### 휴면 해제
- 관리자: POST `/admin/undormant/{empno}` → is_dormant=false + notified 플래그 제거
- 프론트: AdminService.undormantUser() → user_management_screen 휴면 해제 버튼

### SES 설정 없을 때 동작
- SES 호출 실패 시 `logger.error`만 기록, 서버 에러 없음 (non-fatal)
