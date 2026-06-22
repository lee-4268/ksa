# DS xlsx 빌드 파이프라인

DS 업로드 후 xlsx 캐시 빌드 → 다운로드까지 전체 흐름 정리.
수도권(divisionCode='10') 특수 처리 포함.

## 전체 흐름

```
1. 업로드
   POST /ds/enqueue (또는 /ds/enqueue-multi)
   → kca-ds-jobs: status=queued

2. 잡 처리 (_job_worker_loop)
   status=processing → 서브프로세스에서 XLS 파싱 → DynamoDB 저장
   → 완료 후 _xlsx_build_queue에 (divisionId, divisionCode, importDate) 등록

3. xlsx 빌드 (_xlsx_build_worker)
   cert_cache 빌드 완료 확인 후 시작
   → _build_xlsx_cache_background (서브프로세스)
   → 수도권: ['강남','강북','경기','인천'] 순차 _build_one_xlsx_cache
   → 비수도권: 전체 단일 xlsx 빌드
   → S3 ds-exports/에 저장

4. 다운로드 (export-presign → proxy-xlsx)
   GET /ds/export-presign → xlsx 캐시 확인
   → 있으면: /ds/proxy-xlsx URL 반환 (EC2 프록시, CORS 우회)
   → 없으면: /ds/proxy-raw-zip URL 반환 (ZIP fallback)
   → 둘 다 없으면: {"success": false} → 서버사이드 /ds/export-xlsx
```

---

## S3 키 구조

| 구분 | 패턴 |
|------|------|
| 원본 ZIP | `ds-raw/{divisionId}/{divisionCode}_{importDate}.zip` |
| 비수도권 xlsx | `ds-exports/{divisionId}/{divisionCode}_{importDate}.xlsx` |
| 수도권 본부별 xlsx | `ds-exports/sudogwon/10_{importDate}_{hdqt_key}.xlsx` |

**`_HDQT_S3_KEY` 매핑 (main.py:218):**
```python
{'강남': 'gangnam', '강북': 'gangbuk', '경기': 'gyeonggi', '인천': 'incheon'}
```

---

## 수도권 특수 처리 상세

### 빌드 단계
```python
# main.py:5094
is_sudo = (division_code == '10')

# 수도권: city_hdqt_map 먼저 조회 (도로명주소 → 본부 매핑)
# main.py:5147
for hdqt in ['강남', '강북', '경기', '인천']:
    await _build_one_xlsx_cache(
        ..., hdqt_filter=hdqt, city_hdqt_map=city_hdqt_map
    )
```
- 각 본부 서브프로세스 종료 후 다음 진행 (메모리 순차 해제)
- 한 본부 빌드 실패해도 나머지 계속 진행 (non-fatal)

### city_hdqt_map
- API: `GET /ds/city-hdqt-map` (main.py:5457)
- `inspection_targets` 테이블에서 시/군별 최다 access담당 집계
- 6시간 캐시 (`_city_hdqt_cache`)
- xlsx 빌드 시 각 행의 도로명주소에서 시/군 추출 → 본부 필터링에 사용

### xlsx-build-status API 응답
```json
{
  "cached": {"강남": true, "강북": false, "경기": true, "인천": true},
  "building": false,
  "inQueue": true,
  "currentHdqt": "강북",
  "estimatedMinutes": 12
}
```

---

## 다운로드 흐름 상세

### export-presign (main.py:5338)
```
1. xlsx 캐시 확인 (S3 head_object)
   → 있으면: X-Forwarded-Host 기준 EC2 프록시 URL 생성
     origin = f"{forwarded_proto}://{forwarded_host}"
     URL = f"{origin}/ds/proxy-xlsx?divisionId=...&hdqt=..."
   → 반환: {"success": true, "type": "xlsx", "url": "https://api.../ds/proxy-xlsx?..."}

2. ZIP 확인 (S3 head_object)
   → 있으면: /ds/proxy-raw-zip URL 반환
   → 반환: {"success": true, "type": "zip", "url": "...", "building": true/false}

3. 둘 다 없음
   → {"success": false, "message": "S3에 파일 없음. DB Export로 대체합니다."}
```

### proxy-xlsx (main.py:5514)
- S3 GetObject → 65536byte 청크 스트리밍
- `_verify_auth` 호출 → Bearer 토큰 검증 필수
- `Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`

### 프론트 분기 (ds_dashboard_screen.dart:498~)
```dart
if (type == 'xlsx') {
  // EC2 프록시 URL + authToken 헤더로 다운로드
  await platform_export.downloadXlsxFromUrl(
    url: data['url'],
    filename: filename,
    onProgress: onProgress,
    authToken: authToken,  // 필수: EC2 프록시도 인증 필요
  );
}
if (type == 'zip') {
  // EC2 프록시 URL로 ZIP 다운로드 → JS에서 xlsx 변환
  await platform_export.exportDsFromS3(s3Url: proxyUri, ...);
}
```

---

## 수도권 본부 선택 다이얼로그 (ds_dashboard_screen.dart:189)

`_showHdqtSelectDialog` 함수:
1. `GET /ds/xlsx-build-status` 호출 → 캐시 상태 파악
2. 본부 선택 UI: "전체" + 강남/강북/경기/인천 칩
3. 캐시 상태 아이콘:
   - ✅ 초록 체크 = 캐시됨 → 선택 가능
   - ⏳ 회색 = 미캐시 → 선택 불가 (빌드 후 재시도)
   - 🔄 주황 = 빌드 중
4. "전체" 선택은 항상 가능 (ZIP fallback으로 처리)

---

## 안테나 시트 컬럼명 변경 이력

DS 원본의 안테나 시트 헤더가 `공중선주 설치형태명` → `안테나설치대 설치형태명`(설치위치코드/명/형태코드/명 동일 패턴)으로 변경됨(2026-06).
업로드 메인 파싱은 헤더를 **정확 매칭**(`_col_idx`)으로 찾아 못 찾으면 **빈 값으로 조용히 저장**하므로,
컬럼명이 바뀌면 업로드는 오류 없이 통과하지만 설치형태명이 유실됨. 구·신 헤더 모두 키워드로 허용 처리.

| 파싱 위치 | 함수 | 매칭 | 처리 |
|-----------|------|------|------|
| `inspection.py:748` (업로드 메인) | `_col_idx` | 정확 | 구·신 헤더 4종 키워드 추가 |
| `backfill_ds_detail.py:128` | `_col_idx` | 정확 | `*names` 다중 인자화 + 4종 키워드 추가 |
| `ds.py:5267,5804` (diff/apply) | `_find_col` | substring | `설치형태명` 부분일치로 신헤더 자동 대응 |

> ⚠ 설치**위치**코드/명은 현재 어느 경로에서도 파싱하지 않음(미사용). 설치**형태명**만 DB(`ds_안테나.공중선주설치형태명`) 저장.

---

## 주요 에러 패턴 및 해결

| 증상 | 원인 | 해결 |
|------|------|------|
| xlsx 빌드가 "빌드 시작"에서 멈춤 | 워커 태스크가 예외로 사망 (silently swallowed) | `_xlsx_build_worker`에 `except Exception` 추가 |
| S3 다운로드 CLOSE-WAIT 소켓 누적 | 싱글턴 boto3 클라이언트 재사용 | 다운로드마다 새 client 생성 |
| `multiprocessing.Event()` 데드락 | 스레드 환경에서 내부 세마포어 충돌 | `threading.Event()` 로 교체 |
| cert cache 빌드 중 xlsx 시작 → 멈춤 | SQLite 빌드가 GIL 점유해 asyncio 블락 | `_cert_cache_db_path` 체크 후 xlsx 시작 |
| 수도권 OOM | 단일 서브프로세스에서 7M행 전체 로드 | 본부별 순차 서브프로세스 (메모리 분리) |
| CORS 오류 (`Failed to fetch`) | S3 presigned URL → 브라우저 직접 접근 차단 | EC2 프록시(`/ds/proxy-xlsx`)로 전환 |
