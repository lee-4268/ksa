# Data Domain (DS/호출명칭/설치확인서/ERP비교)

## DS 데이터 관리

### 흐름
```
ZIP 업로드 → S3 저장 → 비동기 Job 처리 → SQLite 저장 → 조회/필터/Export
```

### 파일
- `ds_dashboard_screen.dart` — 업로드 현황
- `ds_data_screen.dart` — 데이터 조회/필터
- `ds_upload_screen.dart` — ZIP 업로드
- `ds_merge_screen.dart` — DS 파일 병합
- `ds_data_service.dart`, `ds_upload_service.dart`, `ds_merge_service.dart`

### 본부→Division 매핑
```
강남/강북/인천/경기 → sudogwon (수도권)
강원 → gangwon
충청 → chungcheong
경북 → gyeongbuk
경남 → gyeongnam
서부 → seobu
```

### 권한
- 업로드/삭제: admin 또는 manager만 가능

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
