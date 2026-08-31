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
- 권한/본부 체험 중에는 5-파트 형식이 된다 (아래 [권한/본부 체험](#권한본부-체험-admin-전용) 참조)
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
| 특이국소 관리 | X | O | O |
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

## 권한/본부 체험 (admin 전용)

실제 admin 이 다른 권한·본부 계정의 화면을 그대로 확인하는 기능. 상단바의 🔧 버튼
(`lib/widgets/preview_mode_button.dart`) → 권한 칩(Admin/Manager/Member) + 본부 드롭다운.

### 왜 헤더가 아니라 토큰인가
kca-fe 는 Flask 세션 + `X-Preview-Role` 헤더 + 프록시 주입이라 서버 한 곳에서 처리된다.
ksa 는 서버 세션이 없고 `lib/services/` 의 21개 파일이 각자 헤더를 만들며 일부는 인라인으로
작성한다 → 헤더 방식은 **일부 화면만 체험이 걸리는 사고**가 난다. 토큰은 모든 요청이 이미
들고 다니므로 누락이 구조적으로 불가능하다.

```
체험 없음: base64url(empno:expiry:sig)                ← 기존 형식 그대로 (하위호환)
체험 중  : base64url(empno:expiry:sig:prole:pdiv)
           sig 가 체험 값까지 덮는다(위조 방지)
```

### 엔드포인트
| Method | Path | 설명 |
|--------|------|------|
| POST | `/auth/preview` | 체험 토큰 발급. body {role, division}. 둘 다 빈 값이면 해제 |
| GET | `/auth/preview` | 현재 체험 상태 (새로고침 후 UI 복원용) |

### 안전장치
- 서버가 **항상 DynamoDB 의 실제 role 을 다시 확인**(`_real_role_sync`)한다. 실제 admin 이
  아니면 토큰에 무엇이 적혀 있어도 무시 → **권한 상승 불가, 내려가기만 가능**
- 서명이 체험 값을 덮으므로 v1 토큰에 체험 값을 덧붙여도 서명 불일치로 거부
- 체험은 `empno == caller` 일 때만 적용 → 사용자 목록 화면의 타인 role 은 실제 값
- `preview_role='admin'` 은 실제와 같아 의미가 없으므로 **해제로 취급**
- 값은 화이트리스트(`VALID_ROLES` / `_ACCESS_TO_DIVISION`)로만 받는다
- 체험 전환은 감사 로그에 기록 (`preview_role`, `preview_division`, ip)

### 구현 지점
- `core/auth.py` — `_real_role_sync`(실제) / `_get_user_role_sync`(체험 적용) 분리.
  기존 호출부 50여 곳이 수정 없이 체험을 따른다. `_PREVIEW` ContextVar 는
  `asyncio.to_thread` 가 컨텍스트를 복사하므로 스레드 호출에도 전달된다.
- `_caller_allowed_access_list` — 체험 본부를 같은 divisionId 의 access담당 전체로 확장
  (실제 사용자와 동일 범위여야 체험이 의미가 있다)
- `_verify_auth` 의 토큰 자동갱신이 **체험을 보존**한다 (안 하면 30분 뒤 체험이 풀린다)
- `auth_service.dart` — `userDepartment` / `currentDivisionId` / `currentDivisionShortName`
  세 게터가 모두 `_effectiveDepartment`(체험 중이면 `'{본부}Access담당'`)를 쓴다. 화면들의
  자동 필터가 `userDepartment` 를 기준으로 본부를 고르므로(`replaceAll('Access담당','')`)
  여기서 갈아주면 **화면 5곳을 수정하지 않고 전부 따라온다**.
  `currentDivisionId` 는 `_divisionNameToId` 가 `'경기'`/`'경기본부'` 만 키로 갖는데 실제
  region 은 `'경기Access담당'` 이라 접미사를 떼고 재조회한다(실제 사용자에게도 있던 버그).

### 권한·본부 조합별 동작
| 권한 | 본부 | 서버 조회 범위 | 화면 자동 필터 |
|------|------|----------------|----------------|
| Admin | 전체 | 전사 (격리 분기 미진입) | 실제 소속 |
| Admin | 경기 | **전사** — 격리 분기를 타지 않아 서버에서는 안 좁혀진다 | 수도권 |
| Manager/Member | 전체 | **전사** (아래 주의 참조) | 실제 소속 |
| Manager/Member | 경기 | 수도권 4본부(강남·강북·경기·인천) | 수도권 |

권한을 admin 으로 두면 본부 선택이 **서버 조회에는** 반영되지 않는다. 대부분의 엔드포인트가
`if role != 'admin'` 으로 본부 격리 분기를 타기 때문이고, 실제 admin 이 전사 범위인 것과 같은
동작이다. 화면 자동 필터는 `userDepartment` 를 따라가므로 표시 범위는 좁아진다.

### ⚠️ 권한만 체험할 때 본부 격리를 끄는 이유
`_caller_allowed_access_list` 는 체험 role 이 있고 체험 본부가 없으면 **전사 9본부를 반환**한다.
이 분기가 없으면 admin 의 실제 본부(대개 미설정)로 격리를 계산해 빈 목록이 되고, 호출부가
`WHERE 1=0` 을 붙여 **화면에 아무것도 안 나온다**(2026-08 무선국 Map 이 텅 비는 증상으로 발견).
권한과 본부를 독립적으로 고르게 하려면 "본부 미선택 = 범위 유지" 여야 한다.

호출부 17곳을 고쳐 admin+본부 조합까지 서버에서 좁힐 수 있으나, 보안 분기를 건드리는 위험
대비 이득이 없어 하지 않았다.

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
