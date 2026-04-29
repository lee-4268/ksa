# API Guide

## 서버 정보
- URL: `https://api-sko-kca.skons.net`
- 프레임워크: FastAPI + Uvicorn
- 소스: `yolov8/api/main.py` (단일 파일, 13000+ 줄)
- 서비스: `systemctl restart kca-api`

## EC2 배포 방식
프론트는 git push → Amplify 자동 빌드. 백엔드는 GitHub API로 단일 파일 pull:
```bash
curl -H "Authorization: token {token}" \
  -H "Accept: application/vnd.github.v3.raw" \
  -o /home/ubuntu/kca-api/main.py \
  "https://api.github.com/repos/T-O-Mega/KCA/contents/yolov8/api/main.py" \
  && sudo systemctl restart kca-api
```

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
| GET | `/inspection/schedules` | 일정 조회 |
| POST | `/inspection/result` | 검사 결과 저장 |
| GET | `/inspection/data` | 검사 데이터 조회 |

### 실적 관리
| Method | Path | 설명 |
|--------|------|------|
| POST | `/inspection-results/upload` | 결과장 엑셀 업로드 |
| GET | `/inspection-results/weeks` | 업로드된 주차 목록 (month/region 필터) |
| POST | `/inspection-results/export-xlsx` | 결과장 엑셀 다운로드 |
| GET | `/inspection-results/dashboard` | 대시보드 집계 |
| GET | `/inspection-results/analysis` | 불합격 분석 + 장비타입 크로스탭 |
| GET | `/inspection-results/weekly-trend` | 주별 합격율 추이 |
| GET | `/inspection-results/weekly-trend-by-region` | 본부별 주별 추이 |
| GET | `/inspection-results/summary-report` | 현황 리포트 자동 생성 |

### DS 데이터
| Method | Path | 라인 | 설명 |
|--------|------|------|------|
| GET | `/ds/region-codes` | 2721 | DS 지역코드 매핑 조회 |
| GET | `/ds/upload-presign` | 5288 | S3 ZIP 업로드용 presigned PUT URL |
| GET | `/ds/xlsx-upload-presign` | 5311 | S3 xlsx 업로드용 presigned PUT URL |
| GET | `/ds/export-presign` | 5338 | xlsx 캐시 → EC2 프록시 URL 반환 (없으면 ZIP URL) |
| GET | `/ds/xlsx-build-status` | 5398 | 수도권 본부별 캐시 상태 + 빌드 진행 현황 |
| GET | `/ds/city-hdqt-map` | 5457 | 시/군별 최다 access담당 집계 (6시간 캐시) |
| GET | `/ds/proxy-xlsx` | 5514 | S3 xlsx → EC2 프록시 스트리밍 (CORS 우회) |
| GET | `/ds/proxy-raw-zip` | 5557 | S3 ZIP → EC2 프록시 스트리밍 (CORS 우회) |
| POST | `/ds/upload-init` | 5596 | 업로드 세션 시작 (기존 데이터 삭제 + 새 레코드 생성) |
| POST | `/ds/upload-chunk` | 5718 | 청크 데이터 수신 → DynamoDB BatchWriteItem |
| POST | `/ds/upload-finalize` | 5731 | 업로드 완료 처리 |
| GET | `/ds/stats` | 5758 | DS 통계 조회 |
| GET | `/ds/export` | 5821 | DB 조회 → CSV 스트리밍 |
| GET | `/ds/data` | 5957 | S3 xlsx/ZIP에서 페이지네이션 읽기 |
| DELETE | `/ds/data` | 6143 | DynamoDB 데이터 삭제 |
| GET | `/ds/presign-raw` | 6228 | ZIP S3 직접 업로드용 presigned PUT URL |
| POST | `/ds/upload-raw` | 6253 | ZIP → EC2 로컬 디스크 저장 (병합용) |
| POST | `/ds/upload-temp` | 6338 | ZIP → EC2 로컬 임시 저장 |
| POST | `/ds/enqueue` | 6372 | DS 처리 잡 등록 → 즉시 jobId 반환 |
| POST | `/ds/enqueue-multi` | 6426 | 복수 ZIP 병합 잡 생성 |
| POST | `/ds/trigger-xlsx-build` | 6581 | xlsx 캐시 없는 업로드 → 빌드 큐 등록 |
| GET | `/ds/export-xlsx` | 6596 | DB → xlsx 서버사이드 생성 (폴백) |
| GET | `/ds/job/{job_id}` | 6802 | DS 잡 상태 조회 (3초 폴링용) |
| DELETE | `/ds/job/{job_id}` | 6841 | DS 잡 취소 |

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
