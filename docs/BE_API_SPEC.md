# KSA Backend API 명세서

**버전:** 2.0.0
**최종 수정일:** 2026-03-23
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

### 1.2 통합 API 서버 (FastAPI on EC2)
```
https://api-sko-kca.skons.net
```
- Framework: FastAPI + Uvicorn
- Service: systemd (kca-api)
- 호출명칭 매칭, 설치확인서 생성, 수검 관리, ERP-DS 비교 등 전체 기능 통합
- S3 Bucket: sko-kca-s3
- DynamoDB Tables: kca-ds-records, kca-ds-uploads, kca-ds-jobs, kca-user-roles
- SQLite: inspection.db, ds_detail.db
- 인증: HMAC-SHA256 Bearer 토큰 (2시간 만료)
- CORS: 환경변수 `CORS_ALLOWED_ORIGINS` 또는 기본 허용 목록

### 1.3 AI 분류 서버 (FastAPI on EC2 + API Gateway)
```
https://c3jictzagh.execute-api.ap-northeast-2.amazonaws.com
```
- Framework: FastAPI + YOLOv8n-cls
- Instance: c7i-flex.large

---

## 2. 인증 및 보안 (v1.4.0)

### 2.1 HMAC 토큰 인증

모든 인증 필요 엔드포인트는 `Authorization: Bearer <token>` 헤더가 필수입니다.

**토큰 형식:** `base64url(empno:expiry_unix:hmac_sha256(SECRET, empno:expiry_unix))`
- 만료: 2시간 (`AUTH_TOKEN_EXPIRY = 7200`)
- 시크릿: 환경변수 `AUTH_TOKEN_SECRET` (미설정 시 dev-fallback 자동 생성, 운영 시 필수 설정)
- 타이밍 공격 방지: `hmac.compare_digest` 사용

**토큰 발급:** `POST /auth/login` 성공 시 응답에 `token`, `expiresIn` 포함

### 2.2 엔드포인트 인증 분류

| 분류 | 엔드포인트 |
|------|-----------|
| **공개** (인증 불필요) | `GET /`, `/health`, `/classes`, `POST /auth/login`, `GET /ds/region-codes` |
| **인증 필요** (Bearer 토큰) | categories·stations CRUD, upload/photo·excel, download/*, predict, feedback, ds/stats·data·export*, ds/presign-*, ds/upload-raw·enqueue, ds/job/*, users/{empno}, `DELETE /storage/*`, callname/*, cert/*, inspection/*, erp-ds/* |
| **관리자 전용** (admin/manager 역할) | `GET /admin/users`, `GET /admin/audit-logs`, `PUT /admin/set-role`, `DELETE /ds/data`, `POST /ds/upload-raw`, `POST /ds/enqueue`, `POST /callname/upload-csv`, `POST /inspection/upload-raw`, `POST /inspection/enqueue` |

### 2.3 Rate Limiting

dict 기반 슬라이딩 윈도우, 5분 주기 자동 정리.

| 엔드포인트 | 제한 | 윈도우 |
|-----------|------|--------|
| `POST /auth/login` | 5회 | 60초 |
| `POST /predict` | 10회 | 60초 |
| `POST /predict/ensemble` | 5회 | 60초 |
| `POST /ds/upload-raw` | 3회 | 60초 |
| `POST /feedback` | 10회 | 60초 |
| `DELETE /storage/*` | 10회 | 60초 |

초과 시 `429 Too Many Requests` 반환.

### 2.4 업로드 크기 제한

| 엔드포인트 | 최대 크기 |
|-----------|----------|
| `POST /upload/photo`, `/predict`, `/feedback` | 10MB |
| `POST /upload/excel` | 50MB |
| `POST /ds/upload-raw` | 200MB |

### 2.5 S3 경로 검증

`..`, `/` 시작 등 경로 탐색 공격 차단.

| 엔드포인트 | 허용 prefix |
|-----------|------------|
| `GET /download/presigned` | `photos/`, `excel/`, `feedback/`, `ds-exports/`, `ds-raw/` |
| `GET /download/photo` | `photos/`, `excel/`, `feedback/` |
| `DELETE /storage/{key:path}` | `photos/`, `excel/`, `feedback/` |

### 2.6 CORS 정책

```python
CORS_ALLOWED_ORIGINS=https://main.d3fueh5qj86kgy.amplifyapp.com,http://localhost:3000,http://localhost:8080
```
- `allow_methods`: GET, POST, PUT, DELETE, OPTIONS
- `allow_headers`: Authorization, Content-Type, Accept, X-Admin-Key
- `expose_headers`: Content-Length, Content-Disposition
- `max_age`: 3600초

### 2.7 에러 메시지 보안

서버 내부 오류(500) 시 `str(e)` 대신 `"서버 내부 오류"` 반환. 상세 오류는 서버 로그에만 기록.

### 2.8 환경변수

| 변수 | 필수 | 설명 |
|------|------|------|
| `AUTH_TOKEN_SECRET` | 운영 필수 | HMAC 토큰 서명 키 (64자 hex 권장) |
| `ADMIN_BOOTSTRAP_KEY` | 선택 | 초기 관리자 설정용 부트스트랩 키 (미설정 시 비활성화) |
| `CORS_ALLOWED_ORIGINS` | 선택 | 허용 도메인 (쉼표 구분, 미설정 시 기본값 사용) |

---

## 3. GraphQL API (무선국 관리)

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

## 4. 인증/관리 API (FastAPI REST)

Base URL: `https://api-sko-kca.skons.net`

### 4.1 SSO 로그인

#### `POST /auth/login`
i-NET SSO 인증 + HMAC 토큰 발급. Rate Limit: 5회/60초.

**Request Body:**
```json
{ "username": "N1104268", "password": "****" }
```

**Response (성공):**
```json
{
  "result": "ok",
  "empno": "N1104268",
  "name": "홍길동",
  "token": "base64url_encoded_hmac_token",
  "expiresIn": 7200
}
```

### 4.2 사용자 정보 조회

#### `GET /users/{empno}`
인증 필요. i-NET Users 테이블에서 프로필 조회 + kca-user-roles에서 역할 조회.

**Response:**
```json
{
  "empno": "N1104268",
  "name": "홍길동",
  "region": "충청본부",
  "team": "전파관리팀",
  "role": "admin"
}
```

### 4.3 관리자 — 사용자 목록

#### `GET /admin/users`
관리자/매니저 전용. kca-user-roles 스캔 + Users 테이블 조회.

**Query Parameters:** `search`, `region`, `role` (선택)

**Response:**
```json
{
  "success": true,
  "users": [
    { "empno": "N1104268", "name": "홍길동", "region": "충청본부", "team": "전파관리팀", "role": "admin" }
  ],
  "total": 1
}
```

### 4.4 관리자 — 역할 변경

#### `PUT /admin/set-role`
관리자 또는 부트스트랩 키 필요.

**Request Body:**
```json
{ "empno": "N1104268", "role": "admin" }
```

**인증 방식:** `Authorization: Bearer <token>` (admin 역할) 또는 `X-Admin-Key: <bootstrap_key>`
**유효 역할:** `admin`, `manager`, `member`

### 4.5 관리자 — 감사 로그

#### `GET /admin/audit-logs`
관리자/매니저 전용.

**Query Parameters:** `entityType`, `action`, `limit` (기본 50)

**Response:**
```json
{
  "success": true,
  "logs": [
    {
      "logId": "uuid",
      "action": "UPDATE",
      "entityType": "UserRole",
      "entityId": "N1104268",
      "performedBy": "N1104268",
      "timestamp": "2026-03-04T10:00:00Z",
      "details": {}
    }
  ]
}
```

---

## 5. AI 분류 API (FastAPI REST)

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

## 6. 호출명칭 매칭 API (v2.0.0)

Base URL: `https://api-sko-kca.skons.net`

### 6.1 호출명칭 DB 관리

#### `GET /callname/db-status`
현재 호출명칭 DB 상태 조회

**Response:**
```json
{ "success": true, "rowCount": 150000, "fileCount": 3 }
```

#### `GET /callname/db-preview`
호출명칭 DB 샘플 10건 조회

**Response:**
```json
{ "success": true, "rows": [...] }
```

#### `POST /callname/upload-csv`
호출명칭 DB CSV/Excel 업로드 (관리자 전용)
- Content-Type: `multipart/form-data`
- Fields: `file` (CSV/Excel), `mode` (`"replace"` | `"merge"`)

**Response:**
```json
{ "success": true, "jobId": "uuid" }
```

#### `GET /callname/upload-job/{job_id}`
업로드 잡 상태 조회

**Response:**
```json
{ "success": true, "status": "completed", "rowCount": 150000 }
```

### 6.2 Excel 매칭 워크플로우

#### `POST /callname/upload-raw`
Excel 파일을 S3 temp에 스트리밍 업로드

**Response:**
```json
{ "success": true, "s3Key": "callname/temp/uuid_file.xlsx" }
```

#### `POST /callname/upload-complete`
업로드 완료 → 메타데이터 반환

**Request Body:**
```json
{ "s3Key": "..." }
```

**Response:**
```json
{ "success": true, "uploadId": "uuid", "fileName": "...", "rowCount": 5000, "columns": [...] }
```

#### `GET /callname/upload/{upload_id}/analysis`
컬럼 자동 감지 (zpwina, zpwino, access담당, 품질개선팀 등)

**Response:**
```json
{ "success": true, "detectedColumns": { "zpwina": "F", "zpwino": "G" }, "totalRows": 5000 }
```

#### `POST /callname/upload/{upload_id}/column-values`
특정 컬럼의 고유값 목록 조회 (필터용)

**Request Body:**
```json
{ "column": "본부" }
```

**Response:**
```json
{ "success": true, "values": ["충청본부", "강원본부"], "count": 9 }
```

#### `POST /callname/process`
매칭 실행 시작

**Request Body:**
```json
{ "uploadId": "uuid", "filters": { "본부": ["충청본부"] }, "targetColumns": [...] }
```

**Response:**
```json
{ "success": true, "processId": "uuid" }
```

#### `GET /callname/process/{process_id}/stream`
SSE(Server-Sent Events) 스트림으로 매칭 진행률 수신
- Content-Type: `text/event-stream`

**Events:**
```json
{ "progress": 45.0, "matched": 2500, "total": 5000 }
```

#### `GET /callname/process/{process_id}/download`
매칭 결과 Excel 다운로드

**Response:** `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`

---

## 7. 설치확인서 API (v2.0.0)

Base URL: `https://api-sko-kca.skons.net`

### 7.1 개별 생성

#### `POST /cert/lookup`
zpwino로 국소 정보 조회

**Request Body:**
```json
{ "zpwino": "12345" }
```

**Response:**
```json
{ "success": true, "station": { } }
```

#### `POST /cert/generate`
단일 설치확인서 HWP 생성

**Request Body:**
```json
{ "zpwino": "12345", "data": { "안테나수_자사": 3 }, "format": "hwpx" }
```

**Response:** `application/octet-stream` (HWP file)

### 7.2 일괄 생성

#### `POST /cert/batch/lookup`
다건 zpwino 일괄 조회

**Request Body:**
```json
{ "zpwinos": ["12345", "12346"] }
```

**Response:**
```json
{ "success": true, "results": [...] }
```

#### `POST /cert/batch/upload-photos`
사진 ZIP 업로드 (8MB 청크 스트리밍)
- Content-Type: `multipart/form-data`

**Response:**
```json
{ "success": true, "s3Key": "cert/photos/uuid.zip" }
```

#### `POST /cert/batch/generate`
일괄 설치확인서 생성

**Request Body:**
```json
{ "items": [...], "photoS3Key": "..." }
```

**Response:**
```json
{ "success": true, "jobId": "uuid" }
```

#### `GET /cert/batch/download/{job_id}`
생성된 설치확인서 ZIP 다운로드

**Response:** `application/zip`

---

## 8. 수검 관리 API (v2.0.0)

Base URL: `https://api-sko-kca.skons.net`

### 8.1 데이터 Import

#### `POST /inspection/upload-raw`
KCA Excel 파일을 S3에 스트리밍 업로드

**Response:**
```json
{ "success": true, "s3Key": "inspection/temp/uuid.xlsx" }
```

#### `POST /inspection/enqueue`
백그라운드 Import 잡 큐 등록

**Request Body:**
```json
{ "s3Key": "...", "year": "2026", "uploadedBy": "user@email" }
```

**Response:**
```json
{ "success": true, "jobId": "uuid" }
```

#### `GET /inspection/job/{job_id}`
Import 잡 상태 조회

**Response:**
```json
{ "success": true, "status": "completed", "importedRows": 50000 }
```

### 8.2 메타데이터 및 설정

#### `GET /inspection/meta`
수검 메타데이터 조회 (연도, 상태값 등)

**Response:**
```json
{ "success": true, "years": ["2025", "2026"], "statuses": [...] }
```

#### `GET /inspection/unassigned`
미배정 수검 대상 조회

**Query Parameters:** `year`

**Response:**
```json
{ "success": true, "items": [...], "count": 500 }
```

#### `GET /inspection/column-values`
특정 컬럼 고유값 조회

**Query Parameters:** `year`, `sheet`, `column`

**Response:**
```json
{ "success": true, "values": [...] }
```

#### `GET /inspection/org-map`
조직 계층 맵 조회 (본부→팀→담당)

**Response:**
```json
{ "success": true, "orgMap": { } }
```

### 8.3 Staging 워크플로우

#### `POST /inspection/staging/preview`
Staging 데이터 필터링 미리보기

**Request Body:**
```json
{ "year": "2026", "filters": { }, "page": 1, "limit": 50 }
```

**Response:**
```json
{ "success": true, "items": [...], "total": 500 }
```

#### `POST /inspection/staging/confirm`
Staging → 운영 DB 확정

**Request Body:**
```json
{ "year": "2026", "filters": { } }
```

**Response:**
```json
{ "success": true, "confirmedCount": 500 }
```

### 8.4 데이터 조회 및 Export

#### `POST /inspection/data`
수검 데이터 조회 (필터, 검색, 페이지네이션)

**Request Body:**
```json
{ "year": "2026", "filters": { }, "search": "...", "page": 1, "limit": 50 }
```

**Response:**
```json
{ "success": true, "items": [...], "total": 5000 }
```

#### `POST /inspection/export-xlsx`
필터링된 수검 데이터 XLSX 내보내기

**Request Body:**
```json
{ "year": "2026", "filters": { } }
```

**Response:** `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`

#### `POST /inspection/summary`
수검 통계 요약 (조직별, 상태별)

**Request Body:**
```json
{ "year": "2026" }
```

**Response:**
```json
{ "success": true, "summary": { "total": 50000, "completed": 30000 } }
```

### 8.5 일정 관리

#### `POST /inspection/schedule`
수검 일정 등록/수정

**Request Body:**
```json
{ "year": "2026", "허가번호": "12345", "호출명칭": "...", "분기": "1Q", "skt본부": "충청", "access담당": "홍길동" }
```

**Response:**
```json
{ "success": true }
```

#### `DELETE /inspection/schedule/{year}/{허가번호}`
수검 일정 삭제

**Response:**
```json
{ "success": true }
```

#### `GET /inspection/schedules`
수검 일정 목록 조회

**Query Parameters:** `year`, `access담당`

**Response:**
```json
{ "success": true, "schedules": [...] }
```

### 8.6 결과 기록

#### `POST /inspection/result`
수검 결과 등록/수정

**Request Body:**
```json
{ "year": "2026", "허가번호": "12345", "status": "합격", "검사일": "2026-03-15", "메모": "...", "철탑형태": "강관주" }
```

**Response:**
```json
{ "success": true }
```

#### `POST /inspection/result/photo`
수검 결과 사진 업로드
- Content-Type: `multipart/form-data`

**Response:**
```json
{ "success": true, "photoUrl": "..." }
```

#### `DELETE /inspection/result/photo`
수검 결과 사진 삭제

**Request Body:**
```json
{ "year": "2026", "허가번호": "12345", "photoKey": "..." }
```

**Response:**
```json
{ "success": true }
```

### 8.7 사용자 조회

#### `GET /inspection/my-list`
내 배정 수검 목록

**Query Parameters:** `year`

**Response:**
```json
{ "success": true, "items": [...] }
```

#### `GET /inspection/progress`
수검 진도율 통계

**Query Parameters:** `year`

**Response:**
```json
{ "success": true, "total": 50000, "completed": 30000, "rate": 60.0 }
```

#### `POST /inspection/build-ds-detail`
DS 데이터에서 수검 상세 인덱스 빌드

**Response:**
```json
{ "success": true }
```

---

## 9. ERP-DS 비교 API (v2.0.0)

Base URL: `https://api-sko-kca.skons.net`

#### `POST /erp-ds/compare`
ERP 유지보수 데이터 vs DS 무선시설 데이터 비교
- zpwino 기반 매칭, 주소 비교, 철탑형태 정규화

**Request Body:**
```json
{ "divisionId": "chungcheong", "importDate": "20260203" }
```

**Response:**
```json
{ "success": true, "matched": 4500, "mismatched": 300, "missing": 200, "details": [...] }
```

---

## 10. S3 Storage

### 10.1 무선국 관리 (ksa-photos-bucket)
| 경로 | 설명 |
|------|------|
| `private/{identityId}/photos/{stationId}/{ts}_{filename}` | 현장 사진 |
| `private/{identityId}/excel-originals/{categoryId}_{ts}.xlsx` | 원본 Excel |

### 10.2 DS 데이터 (sko-kca-s3)
| 경로 | 설명 |
|------|------|
| `ds-raw/temp/{uuid}_{filename}` | 업로드 임시 ZIP |
| `ds-raw/{divisionId}/{divisionCode}_{importDate}.zip` | 원본 ZIP 보관 |
| `ds-exports/{divisionId}/{divisionCode}_{importDate}.xlsx` | 생성된 xlsx 캐시 |
| `callname/temp/{uuid}_{filename}` | 호출명칭 매칭 임시 Excel |
| `callname/db/{filename}` | 호출명칭 DB 파일 |
| `cert/photos/{uuid}.zip` | 설치확인서 사진 ZIP |
| `cert/output/{jobId}/` | 생성된 설치확인서 |
| `inspection/temp/{uuid}.xlsx` | KCA Import 임시 파일 |

---

## 11. Cognito Authentication

| 항목 | 값 |
|------|-----|
| User Pool ID | ap-northeast-2_omieCGwQP |
| App Client ID | ehlckq7k9tl2n9b6gq12pj7tp |
| Identity Pool ID | ap-northeast-2:4640cfa8-1f7b-43eb-b2fa-4f8d021a70e1 |

---

## 12. DynamoDB Tables

| Table | PK | SK | 용도 |
|-------|----|----|------|
| kca-ds-records | divisionId | sheetName#importDate#divisionCode#rowIndex | DS 레코드 (old 데이터만) |
| kca-ds-uploads | divisionId | divisionCode#importDate | 업로드 메타/현황 |
| kca-ds-jobs | jobId | — | 처리 잡 큐 |
| kca-user-roles | user_id | — | 사용자 역할 관리 (admin/manager/member) |
| kca-audit-logs | logId | — | 감사 로그 (역할 변경, 데이터 삭제 등) |
| inspection.db | SQLite | — | 수검 데이터 (Staging/운영) |
| ds_detail.db | SQLite | — | DS 수검 상세 인덱스 |

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

## 13. Error Codes

### DS API 공통
| Status | 설명 |
|--------|------|
| 400 | 잘못된 파라미터 / S3 경로 탐색 차단 |
| 401 | 인증 정보 없음 / 토큰 만료·위조 |
| 403 | 권한 부족 (관리자 전용 엔드포인트) / S3 경로 prefix 불일치 |
| 404 | 리소스 없음 |
| 413 | 업로드 크기 초과 |
| 429 | Rate Limit 초과 |
| 500 | 서버 내부 오류 (상세 정보는 서버 로그에만 기록) |
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
| 1.4.0 | 2026-03-04 | 보안 강화: HMAC 토큰 인증, SSO 로그인 토큰 발급, 관리자 패널 API (users/audit-logs/set-role), kca-user-roles·kca-audit-logs 테이블, Rate Limiting, 업로드 크기 제한, S3 경로 검증, CORS 제한, 에러 메시지 내부정보 차단, X-User-Id 폴백 제거 |
| 2.0.0 | 2026-03-23 | 호출명칭 매칭 API (DB 관리 + 3-Step 매칭 워크플로우 + SSE 스트리밍), 설치확인서 API (개별/일괄 HWP 생성), 수검 관리 API (Import → Staging → 일정 → 결과 → 진도율), ERP-DS 비교 API, S3 경로 추가, SQLite DB 추가 |
