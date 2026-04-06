# API Guide

## 서버 정보
- URL: `https://api-sko-kca.skons.net`
- 프레임워크: FastAPI + Uvicorn
- 소스: `yolov8/api/main.py` (단일 파일, 13000+ 줄)
- 서비스: `systemctl restart kca-api`

## 인증 방식

모든 API(로그인 제외)는 Bearer 토큰 필요:
```
Authorization: Bearer {base64url(empno:expiry:hmac_sha256)}
```
- 유효기간: 2시간
- 잔여 1시간 미만 시 응답 헤더로 새 토큰 자동 발급

## 엔드포인트 그룹 (120+)

### 인증 / 사용자 (7)
| Method | Path | 설명 |
|--------|------|------|
| POST | `/auth/login` | SSO 로그인 → 토큰 발급 + last_login 기록 |
| POST | `/auth/dev-login` | 개발용 테스트 로그인 (DEV_LOGIN_ENABLED=1 필요) |
| GET | `/auth/dev-login/status` | dev-login 활성화 여부 |
| GET | `/users/{empno}` | 사용자 정보 조회 (last_login, is_dormant 포함) |
| GET | `/admin/users` | 전체 사용자 목록 (last_login, is_dormant 포함) |
| PUT | `/admin/set-role` | 역할 변경 (admin 전용) |
| POST | `/admin/undormant/{empno}` | 휴면 해제 (is_dormant=false, notified 플래그 제거) |

### 검사 관리 (40+)
| Method | Path | 설명 |
|--------|------|------|
| POST | `/inspection/upload-raw` | ERP 엑셀 업로드 |
| POST | `/inspection/enqueue` | 대상 확정 (→ 자동 지오코딩 백그라운드 실행) |
| GET | `/inspection/my-list` | 내 팀 배정 목록 (dev 계정: 전체, 실계정: AND 조건) |
| GET | `/inspection/my-list/weeks` | 내 팀 수검예정주차 목록 (dev 계정: 전체) |
| GET | `/inspection/schedules` | 일정 조회 |
| POST | `/inspection/result` | 검사 결과 저장 |
| GET | `/inspection/data` | 검사 데이터 조회 |

### 실적 관리 (9)
| Method | Path | 설명 |
|--------|------|------|
| POST | `/inspection-results/upload` | 결과장 엑셀 업로드 |
| GET | `/inspection-results/weeks` | 업로드된 주차 목록 (month/region 필터) |
| POST | `/inspection-results/export-xlsx` | 결과장 엑셀 다운로드 |
| GET | `/inspection-results/dashboard` | 대시보드 집계 |
| GET | `/inspection-results/analysis` | 불합격 분석 + 장비타입 크로스탭 |
| GET | `/inspection-results/weekly-trend` | 주별 합격율 추이 |
| GET | `/inspection-results/weekly-trend-by-region` | 본부별 주별 추이 (성능+서류) |
| GET | `/inspection-results/summary-report` | 현황 리포트 자동 생성 (성능/서류 분리) |

### DS 데이터 (20+)
| Method | Path | 설명 |
|--------|------|------|
| POST | `/ds/upload-raw` | DS ZIP 업로드 |
| GET | `/ds/data` | DS 데이터 조회 |
| POST | `/ds/export-xlsx` | DS 엑셀 내보내기 |

### 호출명칭 (11)
| Method | Path | 설명 |
|--------|------|------|
| POST | `/callname/upload-csv` | 호출명칭 DB 업로드 |
| POST | `/callname/process` | 매칭 처리 |

### 설치확인서 (6)
| Method | Path | 설명 |
|--------|------|------|
| GET | `/cert/lookup` | 허가번호/호출명칭 조회 |
| POST | `/cert/generate` | 설치확인서 생성 (PDF/HWPX) |

### 커뮤니티 (13)
| Method | Path | 설명 |
|--------|------|------|
| GET/POST | `/community/notices` | 공지사항 CRUD |
| GET/POST | `/community/requests` | 요청사항 CRUD |

## 에러 응답 형식
```json
{"detail": "에러 메시지"}
```
- 401: 인증 실패/만료
- 403: 권한 부족
- 404: 리소스 없음
- 429: Rate limit 초과

## Rate Limiting
- 로그인: 5회/분
- 업로드: 10회/분
- 일반 API: 무제한

## 결과장 파싱 규칙 (upload 시)

### 장비타입간소화 5단계 fallback
1. 결과장 `장비타입` → `_EQP_TYPE_SIMPLIFY` 딕셔너리 직접/prefix 매칭
2. `통합시설코드` → `cert_cache.db` zpcode→eqp_type 조회 → 매칭
3. `허가번호`(하이픈 제거) → `cert_cache.db` zpwino→eqp_type 조회 → 매칭
4. 키워드 기반 fallback (`AAU`→AAU, `MIBOS`→MIBOS, `RRU`→RRU 등)
5. 최종 실패 → logger.warning

### 허가번호 정규화
- 프리로드 시: `zpwino.replace("-", "")`
- 조회 시: `허가번호.replace("-", "")`
- 양쪽 모두 하이픈 제거 후 매칭

### 헤더 없는 장비타입 컬럼 자동감지
- 매핑 안 된 컬럼의 첫 5행에서 장비타입 키워드 패턴 매칭
- 5행 중 2개 이상 매칭 시 해당 컬럼을 `장비타입`으로 매핑
