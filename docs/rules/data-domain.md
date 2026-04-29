# Data Domain (DS/호출명칭/설치확인서/ERP비교)

## DS 데이터 관리

### 흐름
```
ZIP 업로드 → S3(ds-raw/) 저장 → enqueue → 백그라운드 잡 처리
→ DynamoDB 저장 → xlsx 캐시 빌드 → S3(ds-exports/) 저장 → 다운로드
```

### 관련 파일
| 구분 | 파일 |
|------|------|
| 대시보드 (업로드 현황 + 다운로드) | `lib/screens/ds_dashboard_screen.dart` |
| 데이터 조회/필터 | `lib/screens/ds_data_screen.dart` |
| ZIP 업로드 | `lib/screens/ds_upload_screen.dart` |
| DS 파일 병합 | `lib/screens/ds_merge_screen.dart` |
| 서비스 | `lib/services/ds_data_service.dart`, `ds_export_service.dart`, `ds_upload_service.dart`, `ds_merge_service.dart` |
| 플랫폼별 | `*_web.dart` (웹), `*_stub.dart` (기본) |

### 본부 → divisionId 매핑
```
강남/강북/인천/경기 → sudogwon (수도권, divisionCode=10)
강원               → gangwon
충청               → chungcheong
경북               → gyeongbuk
경남               → gyeongnam
서부               → seobu
```

### S3 경로 패턴
```
원본 ZIP:         ds-raw/{divisionId}/{divisionCode}_{importDate}.zip
전체 xlsx:        ds-exports/{divisionId}/{divisionCode}_{importDate}.xlsx
수도권 본부별 xlsx: ds-exports/{divisionId}/{divisionCode}_{importDate}_{hdqt_key}.xlsx
```
- `hdqt_key` 매핑 (`_HDQT_S3_KEY`, main.py:218): `강남→gangnam`, `강북→gangbuk`, `경기→gyeonggi`, `인천→incheon`

### 권한
- 업로드/삭제: admin 또는 manager만 가능

---

## 수도권 xlsx 빌드 (특수 처리)

수도권(divisionCode='10')은 전체 통합 xlsx 대신 **본부별 4개 xlsx**를 순차 빌드.

### 빌드 흐름
```
업로드 완료 → _xlsx_build_queue 등록 → _xlsx_build_worker (독립 태스크)
→ _build_xlsx_cache_background (서브프로세스)
→ 수도권이면: ['강남', '강북', '경기', '인천'] 순차 _build_one_xlsx_cache
→ S3 ds-exports/sudogwon/10_{importDate}_{hdqt_key}.xlsx 저장
```

### 핵심 함수 위치 (main.py)
| 함수 | 라인 | 역할 |
|------|------|------|
| `_HDQT_S3_KEY` | 218 | 한글 본부명 → S3 영문 키 딕셔너리 |
| `_build_one_xlsx_cache` | 5000 | 단일 xlsx 빌드 → S3 저장 |
| `_build_xlsx_cache_background` | 5085 | 서브프로세스 진입점 (수도권 4개 순차 실행) |
| `_xlsx_build_worker` | 5190 | 큐 처리 태스크 |
| `_job_worker_loop` | 5209 | 메인 잡 워커 (싱글턴, OOM 방지) |
| `ds_xlsx_build_status` | 5398 | 본부별 캐시 상태 + 빌드 진행 현황 API |

### 메모리 관리 원칙
- 한 번에 1개 잡만 처리 (OOM 방지)
- 본부별 서브프로세스 종료 시 OS가 메모리 회수 (수도권 4개 순차라 동시에 로드 안 됨)
- xlsx 빌드 시작 전 cert_cache 빌드 완료 대기 (`_cert_cache_db_path` 체크)

### 다운로드 흐름 (CORS 처리)
```
export-presign API 호출
  → xlsx 캐시 있으면: EC2 프록시 URL(/ds/proxy-xlsx) 반환  ← S3 presigned URL 사용 안 함 (CORS 차단)
  → xlsx 캐시 없으면: ZIP 존재 확인 → /ds/proxy-raw-zip URL 반환
  → 둘 다 없으면: {"success": false} → 서버사이드 /ds/export-xlsx fallback
```

---

## 수검대상 업로드 보정 로직

DS 업로드 시 `access담당` 컬럼 품질 보정 (main.py:11750~).

### 유효한 본부명 (`_ACCESS_TO_SKT_HDQT` 키, main.py:10729)
```
강남, 강북, 경기, 인천, 강원, 충청, 서부, 동부
```
- `강남Access`, `강북Access담당` 등 접미사 붙은 형태는 제거 후 정규화
- 그 외 모든 값은 무효 (품질개선팀 이름, 폐지된 팀명 등)

### 보정 우선순위
1. **원본 본부명이 유효하면 → 보정 스킵** (`_orig_access_is_valid=True`)
2. 원본이 무효한 경우만 팀명→본부 보정 적용
3. 폐지된 팀명 → 현재 팀명으로 교체
4. 원본 없거나 무효 → cert DB에서 통시코드/공태번호로 재조회
5. 최후 수단 → PNU 코드 → 법정동 주소 → 팀 추론

---

## 호출명칭 매칭

### 흐름
```
CSV 업로드 → 분석(컬럼/건수) → 필터 설정 → 매칭 처리 → 다운로드
```

### 파일
- `callname_screen.dart`
- `callname_service.dart`
- 다운로드: `callname_download_web.dart` / `callname_download_stub.dart`

### 매칭 로직
- 통시코드 기반 자동 매칭
- Access담당/품질개선팀 매핑
- 컬럼-값 필터링

---

## 설치확인서

### 흐름
```
허가번호/호출명칭 조회 → 폼 작성 → PDF/HWPX 생성 → 다운로드
```

### 파일
- `certificate_screen.dart`
- `certificate_service.dart`
- 다운로드: `certificate_download_web.dart` / `certificate_download_stub.dart`

### cert_cache.db
- S3 CSV에서 주기적 빌드 (TTL 기반)
- 테이블: `cert(zpwino, zpwina, zpwiadr, zpcode, zpcname, eqp_type, ...)`
- 인덱스: `zpwino`, `zpwina`, `zpwiadr`
- 장비타입 매핑에도 사용 (zpcode→eqp_type, zpwino→eqp_type)
- **빌드 완료 전까지 xlsx 빌드 시작 안 함** (GIL 경합 방지)

---

## ERP-DS 비교

### 파일
- `erp_ds_compare_screen.dart`
- `erp_ds_compare_service.dart`
- API: `POST /erp-ds/compare`

### 기능
- ERP 무선국 목록 vs DS 데이터 비교
- 누락/추가/불일치 식별
- 본부별 비교

---

## 장비타입 간소화 매핑

### 딕셔너리 (`_EQP_TYPE_SIMPLIFY`)
- 280+ 장비타입 → 30+ 간소화 카테고리
- 위치: `main.py` 상단 (line 256~540)

### 주요 카테고리
```
MIBOS, RRU, AAU, IRO, GIRO, PRU, RHU, RRH,
TRIO, ERRU, SF중계기, W기지국, WAFMC, WINS, ICS,
RO-DUO, OR-DUO, LR-DUO, WLME, ...
```

### 키워드 기반 fallback (`_EQP_KEYWORD_RULES`)
- 딕셔너리 매칭 실패 시 장비명에 포함된 키워드로 분류
- 구체적인 키워드 우선 (GIRO > IRO, ARRU > RRU)
