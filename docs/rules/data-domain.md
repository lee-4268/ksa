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
- `hdqt_key` 매핑 (`_HDQT_S3_KEY`, core/config.py:187): `강남→gangnam`, `강북→gangbuk`, `경기→gyeonggi`, `인천→incheon`

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

### 핵심 함수 위치 (리팩토링 후: core/config.py + routers/ds.py)
| 함수 | 위치 | 역할 |
|------|------|------|
| `_HDQT_S3_KEY` | core/config.py:187 | 한글 본부명 → S3 영문 키 딕셔너리 |
| `_build_one_xlsx_cache` | routers/ds.py:3140 | xlsx 빌드 → S3 저장 (수도권은 본부별 분리 생성) |
| `_merge_hdqt_xlsx_from_s3` | routers/ds.py:3242 | 수도권 4개 본부 xlsx 다운로드 → 단일 전체 xlsx 병합 (스트리밍) |
| `_build_xlsx_cache_background` | routers/ds.py:3329 | 빌드 진입점 (ZIP 다운로드 → _build_one_xlsx_cache → v2 재빌드 트리거) |
| `_xlsx_build_worker` | routers/ds.py:3411 | 큐 처리 태스크 |
| `_job_worker_loop` | routers/ds.py:3430 | 메인 잡 워커 (싱글턴, OOM 방지) |
| `ds_xlsx_build_status` | routers/ds.py:3632 | 본부별 캐시 상태 + 빌드 진행 현황 API |

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

DS 업로드 시 `access담당` 컬럼 품질 보정 (`_correct_hdqt`, routers/inspection.py:962~).

### 유효한 본부명 (`_ACCESS_TO_SKT_HDQT` 키, routers/inspection.py:296)
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

### Sample 양식 (admin 업로드 → 모든 사용자 다운로드)
| 메서드/경로 | 권한 | 용도 |
|------|------|------|
| `GET /callname/sample-template` | 인증 사용자 | 양식 목록 |
| `POST /callname/sample-template` | admin만 | xlsx/xls 업로드 (최대 20MB) |
| `GET /callname/sample-template/download?name=` | 인증 사용자 | presign URL 발급 |
| `DELETE /callname/sample-template?name=` | admin만 | 삭제 |

- S3 prefix: `callname-sample/`
- 파일명 sanitize: `os.path.basename` + `[^\w\-\.가-힣]` → `_`
- UI: 호출명칭 화면 Step 0(파일 업로드) 상단 카드. admin은 업로드/삭제 버튼 노출, 그 외는 다운로드만.

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
- 위치: `routers/inspection_results.py:50` (리팩토링 전 main.py 상단)

### 주요 카테고리
```
MIBOS, RRU, AAU, IRO, GIRO, PRU, RHU, RRH,
TRIO, ERRU, SF중계기, W기지국, WAFMC, WINS, ICS,
RO-DUO, OR-DUO, LR-DUO, WLME, ...
```

### 키워드 기반 fallback (`_EQP_KEYWORD_RULES`)
- 딕셔너리 매칭 실패 시 장비명에 포함된 키워드로 분류
- 구체적인 키워드 우선 (GIRO > IRO, ARRU > RRU)

---

## 시설물 사진 검색 (SKO-OCEAN)

외부 시스템(SKO-OCEAN)에서 업로드된 시설점검 사진을 본부/팀/국소명/주소로 검색.

### 파일
| 구분 | 파일 |
|------|------|
| 화면 | `lib/screens/sisl_photo_search_screen.dart` (Ocean 2-pane: 좌 국소목록 / 우 사진그리드) |
| 공용 위젯 | `lib/widgets/sisl_photo_widgets.dart` (`SislPhotoTile`/`SislPhotoViewer`, HTML img 기반 CORS 우회) |
| 서비스 | `lib/services/inspection_service.dart` (`getSislFilterOptions`/`searchSislPhotos`) |
| 백엔드 | `yolov8/api/routers/sisl_photos.py` |

### 데이터 모델 / 조인
- `sisl_photo.db` 는 **공대코드(neos_code)·분류(reg_cls)·업로드일자·guid·file_path** 만 보유
- 본부/팀/국소명/주소는 `cert_cache.db` 와 조인 (조인키: `sisl_photo.neos_code` = `cert.zpkcode`)

| 검색 조건 | cert 컬럼 |
|-----------|-----------|
| 본부 (드롭다운) | `area_hdofc_nm` distinct (예 '경기Access담당') |
| 팀 (드롭다운, 본부 종속) | `ons_team_nm` distinct (예 '평택품질개선팀') |
| 국소명 (입력) | `zpcname` LIKE |
| 주소 (입력) | `zpwiadr` LIKE |
| → 결과 국소 | `zpkcode`(공대) + `zpcode`(통시) + 국소명 + 주소 |

### 흐름
```
filter-options → 본부/팀 드롭다운 채움
→ search(본부·팀·국소명·주소) → cert 에서 매칭 공대 추출
→ 그 공대들로 sisl_photo 조회(롤링 3년) → 국소별 사진 그룹 반환
→ 좌측 국소 선택 시 우측 그리드 필터, 사진 클릭 시 SislPhotoViewer
```

### 주의
- 이미지는 사내망 `static-int.skons.co.kr` 에서 서빙 → **사내망에서만 표시**, 외부망은 메타만 정상
- 검색은 조건이 모두 비면 빈 결과 반환 (전체 스캔 방지), `?` 바인딩 + LIKE escape
- 권한: 모든 로그인 사용자 (메뉴 위치: 서류 관리 그룹)
