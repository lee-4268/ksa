# API Guide

## 서버 정보
- URL: `https://api-sko-kca.skons.net`
- 프레임워크: FastAPI + Uvicorn (포트 8000, `--workers 1`)
- 소스: `yolov8/api/` 모듈 구조 — `main.py`(엔트리) + `core/` + `routers/`(18개) + `schemas/`
  (2026.05 리팩토링 전까지는 단일 `main.py` 13000줄이었음)
- 서비스: `systemctl restart kca-api`

## EC2 배포 방식
프론트는 git push → Amplify 자동 빌드.

백엔드는 **모듈 구조라 단일 파일 pull 불가** → tarball 배포 스크립트 사용:
```bash
export GITHUB_TOKEN={token}
bash /home/ubuntu/deploy_backend.sh --restart   # --pip: requirements 바뀌면 추가
```
- 스크립트 자체는 최초 1회 Contents API 로 받음 (`scripts/deploy_backend.sh`)
- 받아오는 것: `main.py`, `requirements.txt`, `core/`, `routers/`, `schemas/` (DB·로그·venv 보존)
- 상세: [rules/architecture.md](./architecture.md#백엔드-ec2--tarball-배포-스크립트-202605-리팩토링-이후) 참조

## 인증 방식

모든 API(로그인 제외)는 Bearer 토큰 필요:
```
Authorization: Bearer {base64url(empno:expiry:hmac_sha256)}
```
- 유효기간: 2시간
- 잔여 1시간 미만 시 응답 헤더로 새 토큰 자동 발급

## 엔드포인트 그룹

### 인증 / 사용자
| Method | Path | 설명 |
|--------|------|------|
| POST | `/auth/login` | SSO 로그인 → 토큰 발급 |
| POST | `/auth/dev-login` | 개발용 테스트 로그인 (DEV_LOGIN_ENABLED=1 필요) |
| GET | `/users/{empno}` | 사용자 정보 조회 |
| GET | `/admin/users` | 전체 사용자 목록 |
| PUT | `/admin/set-role` | 역할 변경 (admin 전용) |
| POST | `/admin/undormant/{empno}` | 휴면 해제 |

### 검사 관리
| Method | Path | 설명 |
|--------|------|------|
| POST | `/inspection/upload-raw` | ERP 엑셀 업로드 |
| POST | `/inspection/enqueue` | 대상 확정 (→ 자동 지오코딩 백그라운드 실행) |
| GET | `/inspection/my-list` | 내 팀 배정 목록 |
| GET | `/inspection/my-list/weeks` | 내 팀 수검예정주차 목록 |
| GET | `/inspection/schedules` | 일정 조회 (Phase 4: needs_recheck, result_status LEFT JOIN 포함) |
| POST | `/inspection/result` | 검사 결과 저장 (Phase 4: SUBMITTED→INSPECTED 자동 전환 + 불합격 시 needs_recheck) |
| GET | `/inspection/data` | 검사 데이터 조회 |

### 수검 워크플로우 (Phase 1~5)
| Method | Path | 설명 |
|--------|------|------|
| PATCH | `/inspection/schedule/{pk}/status` | 단일 일정 상태 전환 |
| POST | `/inspection/schedule/transition-bulk` | 다중 일정 일괄 전환 (사전점검 의뢰 등) |
| GET | `/inspection/schedule/{pk}/log` | 상태 전환 이력 조회 |
| POST | `/inspection/schedule/{pk}/pre-check-result` | 전산비교 결과 첨부 + PRE_CHECK_DONE 전환 |
| POST | `/inspection/schedule/{pk}/change-request` | 변경개설 요청 등록 + CHANGE_FILING 전환 |
| GET | `/change-request` | 변경개설 요청 목록 (혁신팀) |
| PATCH | `/change-request/file` | 신고 완료 → RE_CHECK 전환 |
| POST | `/change-request/generate-form` | 변경개설 신고서(A파일) xls 생성 |
| POST | `/ds/apply-partial-update` | 부분 DS 업로드 + 자동 재비교 |
| POST | `/inspection/report/generate` | 검사내역서 xls 발급 (Phase 3, 상태 무관 허용) |
| PATCH | `/inspection/schedule/{pk}/submission` | 단건 접수번호 입력 → SUBMITTED |
| POST | `/inspection/schedule/submission-bulk` | 다중 일정 접수번호 일괄 입력 (Phase 3) |
| GET | `/inspection/dashboard?year=` | 역할별 대시보드 집계 + 행정처분 대상(부적합 시정기한 지남) + 시정기한 도래 (Phase 5) |
| POST | `/inspection/schedule/co-located-check` | 일정 등록 전 동일국소(통시→공대→pnu) 미배정 대상 확인 |
| POST | `/inspection/sync-export` | kca-fe [ksa에서 가져오기] 용 일정+건별결과 JSON — body.secret 인증, 읽기 전용, 단순 요청 CORS |
| POST | `/inspection/sync-photo-urls` | kca-fe 특이사항 사진용 presigned URL(10분) 발급 — body.secret, 읽기 전용 |
| POST | `/inspection/sync-import-file` | kca 신규연도 파일 릴레이용 — 최신 KCA Import 원본 메타(연도/파일명/행수), body.secret |
| POST | `/inspection/sync-import-file-data` | 위 원본 엑셀 바이너리를 EC2 프록시 스트리밍 (S3 직접 fetch는 버킷 CORS 차단) |
| POST | `/inspection/sync-export-targets` | kca 수검대상 미러링용 — 확정 targets 본부 단위 JSON (division='__ETC__'=잔여분). [대상 추가] 수동 확정분까지 포함 |

### 특이국소 관리
| Method | Path | 설명 |
|--------|------|------|
| GET | `/special-sites` | 특이국소 목록 (+대상 정보 join, 전체 로그인 사용자) |
| POST | `/special-sites/resolve` | 허가번호 목록 → 전체 대상(targets∪staging) 매칭 미리보기 (admin/manager) |
| POST | `/special-sites/bulk` | 일괄 등록/upsert — 유형: 지하철/터널/야간출입/기타 (admin/manager) |
| POST | `/special-sites/sync-export` | kca 미러링용 전량 JSON — body.secret 인증, 읽기 전용, playground 오리진만 CORS |
| POST | `/special-sites/delete` | 일괄 삭제 (admin/manager) |

### 부적합 관리 (`routers/inadequate.py`)
| Method | Path | 설명 |
|--------|------|------|
| POST | `/inadequate/sync` | 실적(성능서류='부적합')에서 부적합 국소 동기화 (admin/manager) |
| GET | `/inadequate/list` | 목록 조회 (연도/본부/팀/상태/검색/정렬/페이징) |
| PUT | `/inadequate/update` | 상태·심의차수 변경 (admin/manager) |
| GET | `/inadequate/stats` | 상태별 통계 |
| GET | `/inadequate/export-xlsx` | Excel 내보내기 |
| POST | `/inadequate/sync-export` | kca 미러링용 연도별 전량 JSON — body {secret, year}, 읽기 전용, 단순 요청 CORS. kca 부적합 화면은 조회 미러(등록·상태변경은 ksa에서만) |

### 알림 (Phase 5)
| Method | Path | 설명 |
|--------|------|------|
| GET | `/notifications?unread_only=&limit=` | 현재 사용자 알림 목록 |
| GET | `/notifications/unread-count` | 안 읽음 알림 개수 (종 아이콘 배지용) |
| POST | `/notifications/mark-read` | 알림 읽음 처리 (ids 비면 일괄) |

### 실적 관리
| Method | Path | 설명 |
|--------|------|------|
| POST | `/inspection-results/upload` | 결과장 엑셀 업로드 |
| GET | `/inspection-results/weeks` | 업로드된 주차 목록 (month/region 필터) |
| POST | `/inspection-results/export-xlsx` | 결과장 엑셀 다운로드 |
| POST | `/inspection-results/sync-export` | kca 실적 미러링용 — inspection_results_raw 본부(region) 단위 JSON (region='__ETC__'=잔여분). body {secret, year, region}, 읽기 전용, 단순 요청 CORS. 연 7만행이라 한 번에 못 넘겨 region 단위 10회로 쪼갠다 |
| GET | `/inspection-results/dashboard` | 대시보드 집계 |
| GET | `/inspection-results/analysis` | 불합격 분석 + 장비타입 크로스탭 |
| GET | `/inspection-results/weekly-trend` | 주별 합격율 추이 |
| GET | `/inspection-results/weekly-trend-by-region` | 본부별 주별 추이 |
| GET | `/inspection-results/summary-report` | 현황 리포트 자동 생성 |

### DS 데이터

> 라인 = `yolov8/api/routers/ds.py` 기준 (2026.05 모듈 리팩토링 이후. 이전 단일 main.py 라인 아님)

| Method | Path | ds.py 라인 | 설명 |
|--------|------|------|------|
| GET | `/ds/region-codes` | 139 | DS 지역코드 매핑 조회 |
| GET | `/ds/upload-presign` | 3509 | S3 ZIP 업로드용 presigned PUT URL |
| GET | `/ds/xlsx-upload-presign` | 3532 | S3 xlsx 업로드용 presigned PUT URL |
| GET | `/ds/export-presign` | 3559 | xlsx 캐시 → EC2 프록시 URL 반환 (없으면 ZIP URL) |
| GET | `/ds/xlsx-build-status` | 3631 | 수도권 본부별 캐시 상태 + 빌드 진행 현황 |
| GET | `/ds/city-hdqt-map` | 3714 | 시/군별 최다 access담당 집계 (6시간 캐시) |
| GET | `/ds/proxy-xlsx` | 3771 | S3 xlsx → EC2 프록시 스트리밍 (CORS 우회) |
| GET | `/ds/proxy-raw-zip` | 3817 | S3 ZIP → EC2 프록시 스트리밍 (CORS 우회) |
| POST | `/ds/sync-list` | 3874 | kca DS 파일 릴레이용 — (본부, 지역코드)별 최신 DS ZIP 목록+크기, body.secret 인증 |
| POST | `/ds/sync-raw-zip` | 3944 | kca DS 파일 릴레이용 — 본부 원본 ZIP 스트리밍 (proxy-raw-zip의 시크릿판, Content-Length expose) |
| POST | `/ds/upload-init` | 3856 | 업로드 세션 시작 (기존 데이터 삭제 + 새 레코드 생성) |
| POST | `/ds/upload-chunk` | 3978 | 청크 데이터 수신 → DynamoDB BatchWriteItem |
| POST | `/ds/upload-finalize` | 3991 | 업로드 완료 처리 |
| GET | `/ds/stats` | 4018 | DS 통계 조회 |
| GET | `/ds/export` | 4081 | DB 조회 → CSV 스트리밍 |
| GET | `/ds/data` | 4217 | S3 xlsx/ZIP에서 페이지네이션 읽기 |
| DELETE | `/ds/data` | 4403 | DynamoDB 데이터 삭제 |
| GET | `/ds/presign-raw` | 4488 | ZIP S3 직접 업로드용 presigned PUT URL |
| POST | `/ds/upload-raw` | 4513 | ZIP → EC2 로컬 디스크 저장 (병합용) |
| POST | `/ds/upload-temp` | 4605 | ZIP → EC2 로컬 임시 저장 |
| POST | `/ds/enqueue` | 4648 | DS 처리 잡 등록 → 즉시 jobId 반환 |
| POST | `/ds/enqueue-multi` | 4702 | 복수 ZIP 병합 잡 생성 |
| POST | `/ds/trigger-xlsx-build` | 4837 | xlsx 캐시 없는 업로드 → 빌드 큐 등록 |
| GET | `/ds/export-xlsx` | 4852 | DB → xlsx 서버사이드 생성 (폴백) |
| GET | `/ds/job/{job_id}` | 5075 | DS 잡 상태 조회 (3초 폴링용) |
| DELETE | `/ds/job/{job_id}` | 5114 | DS 잡 취소 |

### 호출명칭
| Method | Path | 설명 |
|--------|------|------|
| POST | `/callname/upload-csv` | 호출명칭 DB 업로드 |
| POST | `/callname/process` | 매칭 처리 |

### 설치확인서
| Method | Path | 설명 |
|--------|------|------|
| GET | `/cert/lookup` | 허가번호/호출명칭 조회 |
| POST | `/cert/generate` | 설치확인서 생성 (PDF/HWPX) |

### 시설물 사진 (SKO-OCEAN) — `routers/sisl_photos.py`
| Method | Path | 권한 | 설명 |
|--------|------|------|------|
| POST | `/admin/sisl-photos/import` | admin | sisl_db 엑셀 임포트 |
| GET | `/sisl-photos?neos_code=` | 인증 | 공대 기준 사진 메타 (롤링 3년 기본) |
| GET | `/sisl-photos/stats` | admin/manager | 임포트 통계 |
| GET | `/sisl-photos/filter-options` | 인증 | 본부→팀 매핑 (cert distinct) |
| GET | `/sisl-photos/search?hdqt=&team=&facility=&address=` | 인증 | cert 조인 → 공대별 사진 그룹 |
- 사진 메타는 `sisl_photo.db`(공대코드만 보유), 검색 조건(본부/팀/국소명/주소)은 `cert_cache.db` 와 조인
- 이미지 자체는 사내망 `static-int.skons.co.kr` 에서 서빙 → 사내망에서만 표시
- 상세: [rules/data-domain.md](./data-domain.md#시설물-사진-검색-sko-ocean)

### 커뮤니티
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
