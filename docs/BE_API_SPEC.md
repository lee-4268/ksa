# KSA Backend API 명세서

**버전:** 1.3.1
**최종 수정일:** 2026-03-03
**API 타입:** AWS AppSync GraphQL + FastAPI REST (2개 서버)

---

## 1. 서버 구성

### 1.1 무선국 관리 API (AWS AppSync)
```
https://mtokcw2pmffyjdhl3uhfihwj7m.appsync-api.ap-northeast-2.amazonaws.com/graphql
```
- Region: ap-northeast-2
- Auth: AMAZON_COGNITO_USER_POOLS (Primary), API_KEY (Secondary)
- Authorization: Owner-based (사용자는 자신의 데이터만 접근)

### 1.2 DS API 서버 (FastAPI on EC2)
```
https://api-sko-kca.skons.net
```
- Framework: FastAPI + Uvicorn
- Service: systemd (kca-api)
- S3 Bucket: sko-kca-s3
- DynamoDB Tables: kca-ds-records, kca-ds-uploads, kca-ds-jobs

### 1.3 AI 분류 서버 (FastAPI on EC2 + API Gateway)
```
https://c3jictzagh.execute-api.ap-northeast-2.amazonaws.com
```
- Framework: FastAPI + YOLOv8n-cls
- Instance: c7i-flex.large

---

## 2. GraphQL API (무선국 관리)

### 2.1 Schema Types

#### Category
```graphql
type Category @model @auth(rules: [
  { allow: owner, operations: [create, read, update, delete] }
]) {
  id: ID!
  name: String!
  originalExcelKey: String
  stations: [Station] @hasMany(indexName: "byCategory", fields: ["id"])
  createdAt: AWSDateTime
  updatedAt: AWSDateTime
}
```

#### Station
```graphql
type Station @model @auth(rules: [
  { allow: owner, operations: [create, read, update, delete] }
]) {
  id: ID!
  categoryId: ID! @index(name: "byCategory", sortKeyFields: ["createdAt"])
  stationName: String!
  licenseNumber: String
  address: String!
  latitude: Float
  longitude: Float
  callSign: String
  gain: String
  antennaCount: String
  remarks: String
  typeApprovalNumber: String
  frequency: String
  stationType: String
  stationOwner: String
  installationType: String
  isInspected: Boolean @default(value: "false")
  inspectionDate: AWSDateTime
  memo: String
  photoKeys: [String]
  createdAt: AWSDateTime
  updatedAt: AWSDateTime
}
```

#### TowerClassification
```graphql
type TowerClassification @model @auth(rules: [
  { allow: owner, operations: [create, read, update, delete] }
]) {
  id: ID!
  imageKey: String!
  imageName: String
  className: String!
  classNameKr: String!
  confidence: Float!
  isConfident: Boolean
  top5Predictions: String
  ensembleMethod: String
  ensembleImageKeys: [String]
  processingTimeMs: Float
  createdAt: AWSDateTime
  updatedAt: AWSDateTime
}
```

### 2.2 Queries

#### getCategory
```graphql
query GetCategory($id: ID!) {
  getCategory(id: $id) {
    id name stations { items { id stationName address isInspected } }
    createdAt updatedAt
  }
}
```

#### listCategories
```graphql
query ListCategories($limit: Int, $nextToken: String) {
  listCategories(limit: $limit, nextToken: $nextToken) {
    items { id name createdAt updatedAt }
    nextToken
  }
}
```

#### stationsByCategory
```graphql
query StationsByCategory($categoryId: ID!, $sortDirection: ModelSortDirection, $limit: Int, $nextToken: String) {
  stationsByCategory(categoryId: $categoryId, sortDirection: $sortDirection, limit: $limit, nextToken: $nextToken) {
    items { id categoryId stationName address latitude longitude isInspected createdAt }
    nextToken
  }
}
```

### 2.3 Mutations

#### createCategory / updateCategory / deleteCategory
```graphql
mutation CreateCategory($input: CreateCategoryInput!) {
  createCategory(input: $input) { id name createdAt updatedAt }
}
mutation UpdateCategory($input: UpdateCategoryInput!) {
  updateCategory(input: $input) { id name createdAt updatedAt }
}
mutation DeleteCategory($input: DeleteCategoryInput!) {
  deleteCategory(input: $input) { id }
}
```

#### createStation / updateStation / deleteStation
```graphql
mutation UpdateStation($input: UpdateStationInput!) {
  updateStation(input: $input) { id isInspected inspectionDate memo photoKeys installationType updatedAt }
}
```

---

## 3. DS API (FastAPI REST)

Base URL: `https://api-sko-kca.skons.net`

### 3.1 지역코드 조회

#### `GET /ds/region-codes`
DS 본부별 지역코드 매핑 조회

**Response:**
```json
{
  "success": true,
  "codes": {
    "10": {"divisionId": "sudogwon", "divisionName": "수도권"},
    "20": {"divisionId": "gyeongnam", "divisionName": "경남본부"},
    "30": {"divisionId": "seobu", "divisionName": "서부본부"},
    "40": {"divisionId": "gangwon", "divisionName": "강원본부"},
    "50": {"divisionId": "chungcheong", "divisionName": "충청본부"},
    "55": {"divisionId": "chungcheong", "divisionName": "충청본부"},
    "60": {"divisionId": "gyeongbuk", "divisionName": "경북본부"},
    "70": {"divisionId": "seobu", "divisionName": "서부본부"}
  }
}
```

---

### 3.2 DS 업로드 (Upload-Zero-Build)

> **v1.3.1**: 업로드 시 xlsx 빌드 완전 생략. 메타데이터만 초고속 파싱 → ZIP을 S3에 그대로 보관.
> 처리 시간: ~30분 → **~10초** (10만행 기준)

#### `POST /ds/upload-raw`
ZIP 파일을 EC2 경유로 S3에 업로드 (CORS 설정 불필요)
- Content-Type: `multipart/form-data`
- Field: `file` (ZIP 파일)
- 8MB 청크 스트리밍으로 EC2 메모리 최소 사용
- S3 저장 경로: `ds-raw/temp/{uuid}_{filename}`

**Response:**
```json
{ "success": true, "s3Key": "ds-raw/temp/uuid_filename.zip" }
```

| Error | 설명 |
|-------|------|
| 500 | S3 업로드 실패 |

---

#### `POST /ds/enqueue`
업로드된 ZIP의 처리 잡을 큐에 등록

**Request Body:**
```json
{
  "s3Key": "ds-raw/temp/uuid_filename.zip",
  "fileName": "충청본부_20260203.zip",
  "uploadedBy": "user@example.com"
}
```

**Response:**
```json
{ "success": true, "jobId": "uuid", "queuePosition": 1 }
```

| Error | 설명 |
|-------|------|
| 503 | xlrd 미설치 |
| 500 | DynamoDB 오류 |

---

**서버 처리 흐름 (백그라운드 워커):**
1. S3에서 ZIP 다운로드 → `/tmp`
2. ZIP 내 XLS 파일 분류 (`_classify_ds_file`: base/numbered/spt)
3. **메타데이터만 파싱** — 시트별 행 수 + 헤더 추출 (데이터 행 읽기 0회)
4. `fileManifest` 생성: `{시트명: [{"f": 파일명, "r": 데이터행수}, ...]}`
5. ZIP → S3 영구 경로 복사: `ds-raw/{divisionId}/{divisionCode}_{importDate}.zip`
6. `kca-ds-uploads` 레코드 완료 처리 (`storageType: "s3-zip"`, `fileManifest` 저장)

---

#### `GET /ds/job/{job_id}`
잡 처리 상태 조회 (3초 간격 폴링)

**Response (처리 중):**
```json
{
  "success": true,
  "job": {
    "jobId": "uuid",
    "status": "processing",
    "stage": "메타데이터 파싱: base_file.xls",
    "percent": 45.0,
    "processedRows": 0,
    "totalRows": 200000,
    "queuePosition": null
  }
}
```

**Response (완료):**
```json
{
  "success": true,
  "job": {
    "status": "completed",
    "divisionCode": "50",
    "importDate": "20260203",
    "sheetStats": {"일반사항": 12000, "검사이력": 8000},
    "totalRows": 20000
  }
}
```

**Response (실패):**
```json
{
  "success": true,
  "job": { "status": "failed", "error": "오류 메시지" }
}
```

**job.status 값:**
| 값 | 설명 |
|----|------|
| queued | 큐 대기 중 |
| processing | 처리 중 (메타데이터 파싱) |
| completed | 완료 |
| failed | 실패 |

---

#### `DELETE /ds/job/{job_id}`
queued 상태의 잡 취소

**Response:**
```json
{ "success": true, "message": "잡이 취소되었습니다." }
```

---

### 3.3 DS 통계 / 대시보드

#### `GET /ds/stats`
업로드 현황 조회

**Query Parameters:**

| 파라미터 | 필수 | 설명 |
|---------|------|------|
| divisionId | - | 특정 본부 필터 (없으면 전체) |
| importDate | - | 날짜 필터 (YYYYMMDD) |
| divisionCode | - | 지역코드 필터 (divisionId+importDate와 함께 사용 시 단건 조회) |

**Response:**
```json
{
  "success": true,
  "count": 3,
  "uploads": [
    {
      "divisionId": "chungcheong",
      "importDate": "50#20260203",
      "divisionCode": "50",
      "divisionName": "충청본부",
      "uploadedBy": "user@example.com",
      "uploadedAt": "2026-02-03T10:00:00Z",
      "fileName": "충청_20260203.zip",
      "status": "completed",
      "sheetStats": {"일반사항": 12000},
      "totalRows": 12000
    }
  ]
}
```

---

### 3.4 DS Excel Export

#### `GET /ds/export-xlsx`
서버사이드 xlsx 빌드 후 직접 다운로드

**스토리지별 동작:**
| storageType | 동작 |
|-------------|------|
| `s3-zip` | S3 캐시 xlsx 확인 → 없으면 ZIP 다운로드 + on-demand xlsx 빌드 → S3 캐싱 |
| `s3` | S3에서 기존 xlsx 직접 스트리밍 |
| 없음 (old) | DynamoDB → openpyxl 빌드 → S3 캐싱 |

다음 요청은 presign 경로로 즉시 다운로드

**Query Parameters:**

| 파라미터 | 필수 | 설명 |
|---------|------|------|
| divisionId | O | 본부 ID |
| importDate | O | 날짜 (YYYYMMDD) |
| divisionCode | - | 지역코드 |

**Response:** `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`
- Content-Disposition: `attachment; filename*=UTF-8''...xlsx`
- xlsx 서식: Arial 10pt, 가운데정렬, #BFBFBF 헤더, 얇은 테두리, 열 너비 20
- 컬럼 순서: 업로드 시 저장된 sheetHeaders 기준 (원본 XLS 순서)

| Error | 설명 |
|-------|------|
| 503 | openpyxl 미설치 |
| 404 | 업로드 정보 없음 |

---

#### `GET /ds/export-presign`
S3에 저장된 xlsx의 presigned URL 조회 (60분 유효)

**Query Parameters:** divisionId, importDate, divisionCode

**Response (존재):**
```json
{ "success": true, "url": "https://s3.presigned.url/...", "exists": true }
```

**Response (없음):**
```json
{ "success": true, "exists": false }
```

---

### 3.5 DS 데이터 조회

#### `GET /ds/data`
시트별 레코드 페이징 조회 (트리플 라우팅)

**트리플 라우팅:**
| storageType | 데이터 소스 | 설명 |
|-------------|------------|------|
| `s3-zip` | S3 ZIP 내 XLS 직접 읽기 | `fileManifest`로 효율적 파일 스킵 |
| `s3` | S3 xlsx 파일 | openpyxl read_only 모드 |
| 없음 (old) | DynamoDB 쿼리 | 기존 `kca-ds-records` 조회 |

**Query Parameters:**

| 파라미터 | 필수 | 설명 |
|---------|------|------|
| divisionId | O | 본부 ID |
| sheetName | O | 시트명 |
| importDate | - | 날짜 (YYYYMMDD) |
| divisionCode | - | 지역코드 (정확한 uploads 레코드 조회용) |
| limit | - | 페이지 크기 (기본 100, 최대 1000) |
| lastKey | - | 페이징 커서 (이전 응답의 lastEvaluatedKey) |
| search | - | 검색어 (data 필드 값 포함 여부) |

> `lastKey`에 `_xlsOffset` 포함 시 → S3 경로 직행 (클라이언트는 opaque하게 처리)

**Response:**
```json
{
  "success": true,
  "count": 100,
  "items": [
    {
      "divisionId": "chungcheong",
      "sk": "일반사항#20260203#50#00000001",
      "sheetName": "일반사항",
      "importDate": "20260203",
      "divisionCode": "50",
      "data": { "국소명": "홍성국", "주소": "충남 홍성군 ..." }
    }
  ],
  "lastEvaluatedKey": "base64encodedkey"
}
```

---

#### `DELETE /ds/data`
본부/날짜별 모든 레코드 삭제 (uploads 레코드 + records 레코드 + S3 파일 포함)

**스토리지별 동작:**
| storageType | 삭제 대상 |
|-------------|----------|
| `s3` / `s3-zip` | uploads 레코드 + S3 파일 + 캐시 (DynamoDB records 삭제 생략) |
| 없음 (old) | uploads 레코드 + DynamoDB records 백그라운드 삭제 + S3 파일 |

**Query Parameters:** divisionId (필수), importDate (필수), divisionCode (선택)

**Response:**
```json
{ "success": true, "deletedCount": 12000 }
```

---

### 3.6 DS 업로드 (Legacy — 청크 방식, 사용 안 함)

> ⚠️ 아래 엔드포인트들은 구버전 청크 방식으로 현재 미사용. Scenario 2 (`/ds/upload-raw` + `/ds/enqueue`)를 사용할 것.

- `GET /ds/upload-presign` — S3 presigned PUT URL
- `GET /ds/xlsx-upload-presign` — xlsx S3 presigned PUT URL
- `POST /ds/upload-init` — 청크 업로드 초기화
- `POST /ds/upload-chunk` — 청크 데이터 전송
- `POST /ds/upload-finalize` — 청크 업로드 완료 처리
- `GET /ds/export` — 스트리밍 JSON Export (DB → JS xlsx 생성용 폴백)

---

## 4. AI 분류 API (FastAPI REST)

Base URL: `https://c3jictzagh.execute-api.ap-northeast-2.amazonaws.com`

### 4.1 분류 클래스 (9개)

| ID | 영문명 | 한글명 |
|----|--------|--------|
| 0 | simple_pole | 간이폴, 분산폴 및 비기준 설치대 |
| 1 | steel_pipe | 강관주 |
| 2 | complex_type | 복합형 |
| 3 | indoor | 옥내, 터널, 지하 등 |
| 4 | single_pole_building | 원폴(건물) |
| 5 | tower_building | 철탑(건물) |
| 6 | tower_ground | 철탑(지면) |
| 7 | telecom_pole | 통신주 |
| 8 | frame_mount | 프레임 |

### 4.2 Endpoints

#### `GET /health`
```json
{ "status": "healthy", "model_loaded": true }
```

#### `POST /predict`
- Content-Type: `multipart/form-data`
- Field: `file` (이미지), Query: `conf_threshold` (기본 0.5)

```json
{
  "success": true,
  "prediction": { "class_name": "steel_pipe", "class_name_kr": "강관주", "confidence": 0.9234 },
  "top5": [...],
  "is_confident": true,
  "processing_time_ms": 245.32
}
```

#### `POST /predict/ensemble`
- Fields: `files` (최대 10개), Query: `method` (mean|max|vote), `conf_threshold`

---

## 5. S3 Storage

### 5.1 무선국 관리 (ksa-photos-bucket)
| 경로 | 설명 |
|------|------|
| `private/{identityId}/photos/{stationId}/{ts}_{filename}` | 현장 사진 |
| `private/{identityId}/excel-originals/{categoryId}_{ts}.xlsx` | 원본 Excel |

### 5.2 DS 데이터 (sko-kca-s3)
| 경로 | 설명 |
|------|------|
| `ds-raw/temp/{uuid}_{filename}` | 업로드 임시 ZIP |
| `ds-raw/{divisionId}/{divisionCode}_{importDate}.zip` | 원본 ZIP 보관 |
| `ds-exports/{divisionId}/{divisionCode}_{importDate}.xlsx` | 생성된 xlsx 캐시 |

---

## 6. Cognito Authentication

| 항목 | 값 |
|------|-----|
| User Pool ID | ap-northeast-2_omieCGwQP |
| App Client ID | ehlckq7k9tl2n9b6gq12pj7tp |
| Identity Pool ID | ap-northeast-2:4640cfa8-1f7b-43eb-b2fa-4f8d021a70e1 |

---

## 7. DynamoDB Tables

| Table | PK | SK | 용도 |
|-------|----|----|------|
| kca-ds-records | divisionId | sheetName#importDate#divisionCode#rowIndex | DS 레코드 (old 데이터만) |
| kca-ds-uploads | divisionId | divisionCode#importDate | 업로드 메타/현황 |
| kca-ds-jobs | jobId | — | 처리 잡 큐 |

### kca-ds-uploads 주요 속성

| 속성 | 타입 | 설명 |
|------|------|------|
| divisionId | S (PK) | 본부 ID |
| importDate | S (SK) | `{divisionCode}#{YYYYMMDD}` |
| storageType | S | `"s3-zip"` (v1.3.1+) / `"s3"` (v1.3.0) / 없음 (old DynamoDB) |
| fileManifest | M | `{시트명: [{"f": 파일명, "r": 행수}, ...]}` (s3-zip만) |
| sheetStats | M | `{시트명: 행수}` |
| sheetHeaders | M | `{시트명: [컬럼1, 컬럼2, ...]}` |
| totalRows | N | 전체 행 수 |
| fileName | S | 원본 ZIP 파일명 |
| uploadedBy | S | 업로더 이메일 |
| status | S | `uploading` / `completed` / `failed` |

---

## 8. Error Codes

### DS API 공통
| Status | 설명 |
|--------|------|
| 400 | 잘못된 파라미터 |
| 404 | 리소스 없음 |
| 500 | 서버 내부 오류 (DynamoDB, S3) |
| 503 | 의존성 미설치 (xlrd, openpyxl) |

### GraphQL
| Code | 설명 |
|------|------|
| Unauthorized | 인증 실패 |
| ValidationError | 입력 유효성 오류 |
| ProvisionedThroughputExceededException | DynamoDB 처리량 초과 |

---

## 변경 이력

| 버전 | 날짜 | 변경 내용 |
|------|------|----------|
| 1.0.0 | 2026-01-13 | 최초 작성 |
| 1.1.0 | 2026-01-22 | Tower Classification API 추가 |
| 1.2.0 | 2026-01-27 | Category.originalExcelKey, Station.installationType, TowerClassification 타입 추가 |
| 1.3.0 | 2026-02-26 | DS API 서버 전체 추가 (upload-raw, enqueue, job, stats, export-xlsx, export-presign, data CRUD), S3 경로, DynamoDB 테이블 구조 추가 |
| 1.3.1 | 2026-03-03 | Upload-Zero-Build: 메타데이터만 파싱 (xlsx 빌드 제거), storageType/fileManifest 추가, 트리플 라우팅 (s3-zip/s3/DynamoDB), export on-demand 빌드, kca-ds-uploads 속성 명세 |
