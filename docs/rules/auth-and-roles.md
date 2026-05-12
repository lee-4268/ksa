# Auth & Roles (인증/권한)

## 인증 흐름

### 일반 로그인 (SSO)
```
사번+비밀번호 → POST /auth/login → SKons SSO 검증 → HMAC 토큰 발급
→ GET /users/{empno} → DynamoDB 사용자 정보 + 역할 조회
→ kca-user-roles에 자동 등록 (없으면 member)
```

### 개발용 테스트 로그인
```
POST /auth/dev-login (DEV_LOGIN_ENABLED=1 필요)
→ SSO 인증 없이 임의 계정으로 토큰 발급
→ _dev_users 메모리 캐시에 저장
→ /users/{empno}, /inspection/my-list 등에서 fallback으로 사용
```

활성화: systemd 서비스 파일에 `Environment=DEV_LOGIN_ENABLED=1`

### 토큰 구조
```
base64url(empno:expiry_unix:hmac_sha256(SECRET, empno:expiry_unix))
```
- 유효기간: 2시간
- 잔여 1시간 미만 → 응답 헤더에 새 토큰 자동 발급
- Flutter 측에서 자동 갱신 처리

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
