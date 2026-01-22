# KSA Backend API 명세서

## GraphQL API Specification + Tower Classification REST API

**버전:** 1.1.0
**최종 수정일:** 2026-01-22
**API 타입:** AWS AppSync GraphQL + FastAPI REST

---

## 1. API 정보

### 1.1 Endpoint
```
https://mtokcw2pmffyjdhl3uhfihwj7m.appsync-api.ap-northeast-2.amazonaws.com/graphql
```

### 1.2 Region
`ap-northeast-2` (Seoul, Korea)

### 1.3 Authentication
| 타입 | 설명 |
|------|------|
| Primary | AMAZON_COGNITO_USER_POOLS |
| Secondary | API_KEY |

### 1.4 Authorization
Owner-based authorization - 사용자는 자신이 생성한 데이터만 접근 가능

---

## 2. Schema

### 2.1 Category Type
카테고리 (Excel 파일 그룹)

```graphql
type Category @model @auth(rules: [
  { allow: owner, operations: [create, read, update, delete] }
]) {
  id: ID!
  name: String!
  stations: [Station] @hasMany(indexName: "byCategory", fields: ["id"])
  createdAt: AWSDateTime
  updatedAt: AWSDateTime
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | ID | O | 고유 식별자 (UUID) |
| name | String | O | 카테고리 이름 |
| stations | [Station] | - | 소속 무선국 목록 (관계) |
| createdAt | AWSDateTime | - | 생성 일시 (자동) |
| updatedAt | AWSDateTime | - | 수정 일시 (자동) |

---

### 2.2 Station Type
무선국

```graphql
type Station @model @auth(rules: [
  { allow: owner, operations: [create, read, update, delete] }
]) {
  id: ID!
  categoryId: ID! @index(name: "byCategory", sortKeyFields: ["createdAt"])

  # 기본 정보
  stationName: String!
  licenseNumber: String
  address: String!
  latitude: Float
  longitude: Float

  # 상세 정보
  callSign: String
  gain: String
  antennaCount: String
  remarks: String
  typeApprovalNumber: String
  frequency: String
  stationType: String
  stationOwner: String

  # 검사 정보
  isInspected: Boolean @default(value: "false")
  inspectionDate: AWSDateTime
  memo: String

  # 사진
  photoKeys: [String]

  createdAt: AWSDateTime
  updatedAt: AWSDateTime
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | ID | O | 고유 식별자 (UUID) |
| categoryId | ID | O | 소속 카테고리 ID |
| stationName | String | O | ERP 국소명 |
| licenseNumber | String | - | 허가번호 |
| address | String | O | 설치장소 주소 |
| latitude | Float | - | 위도 |
| longitude | Float | - | 경도 |
| callSign | String | - | 호출부호 |
| gain | String | - | 안테나 이득 |
| antennaCount | String | - | 안테나 수량 |
| remarks | String | - | 비고 |
| typeApprovalNumber | String | - | 형식검정번호 |
| frequency | String | - | 주파수 |
| stationType | String | - | 무선국 종류 |
| stationOwner | String | - | 소유자 |
| isInspected | Boolean | - | 검사완료 여부 (기본: false) |
| inspectionDate | AWSDateTime | - | 검사일시 |
| memo | String | - | 메모 |
| photoKeys | [String] | - | S3 사진 키 목록 |
| createdAt | AWSDateTime | - | 생성 일시 (자동) |
| updatedAt | AWSDateTime | - | 수정 일시 (자동) |

---

## 3. Queries

### 3.1 getCategory
카테고리 단건 조회

```graphql
query GetCategory($id: ID!) {
  getCategory(id: $id) {
    id
    name
    stations {
      items {
        id
        stationName
        address
        isInspected
      }
    }
    createdAt
    updatedAt
  }
}
```

**Variables:**
```json
{
  "id": "category-uuid"
}
```

**Response:**
```json
{
  "data": {
    "getCategory": {
      "id": "category-uuid",
      "name": "2026년 1월 검사목록",
      "stations": {
        "items": [
          {
            "id": "station-uuid",
            "stationName": "서울중앙국",
            "address": "서울시 중구 세종대로 110",
            "isInspected": false
          }
        ]
      },
      "createdAt": "2026-01-13T00:00:00.000Z",
      "updatedAt": "2026-01-13T00:00:00.000Z"
    }
  }
}
```

---

### 3.2 listCategories
카테고리 목록 조회

```graphql
query ListCategories($limit: Int, $nextToken: String) {
  listCategories(limit: $limit, nextToken: $nextToken) {
    items {
      id
      name
      createdAt
      updatedAt
    }
    nextToken
  }
}
```

**Variables:**
```json
{
  "limit": 1000,
  "nextToken": null
}
```

**Response:**
```json
{
  "data": {
    "listCategories": {
      "items": [
        {
          "id": "category-uuid-1",
          "name": "2026년 1월 검사목록",
          "createdAt": "2026-01-13T00:00:00.000Z",
          "updatedAt": "2026-01-13T00:00:00.000Z"
        },
        {
          "id": "category-uuid-2",
          "name": "2026년 2월 검사목록",
          "createdAt": "2026-01-13T01:00:00.000Z",
          "updatedAt": "2026-01-13T01:00:00.000Z"
        }
      ],
      "nextToken": null
    }
  }
}
```

---

### 3.3 getStation
무선국 단건 조회

```graphql
query GetStation($id: ID!) {
  getStation(id: $id) {
    id
    categoryId
    stationName
    licenseNumber
    address
    latitude
    longitude
    callSign
    gain
    antennaCount
    remarks
    typeApprovalNumber
    frequency
    stationType
    stationOwner
    isInspected
    inspectionDate
    memo
    photoKeys
    createdAt
    updatedAt
  }
}
```

**Variables:**
```json
{
  "id": "station-uuid"
}
```

---

### 3.4 listStations
무선국 목록 조회

```graphql
query ListStations(
  $filter: ModelStationFilterInput
  $limit: Int
  $nextToken: String
) {
  listStations(filter: $filter, limit: $limit, nextToken: $nextToken) {
    items {
      id
      categoryId
      stationName
      licenseNumber
      address
      latitude
      longitude
      callSign
      gain
      antennaCount
      remarks
      typeApprovalNumber
      frequency
      stationType
      stationOwner
      isInspected
      inspectionDate
      memo
      photoKeys
      createdAt
      updatedAt
    }
    nextToken
  }
}
```

**Variables:**
```json
{
  "filter": null,
  "limit": 1000,
  "nextToken": null
}
```

---

### 3.5 stationsByCategory
카테고리별 무선국 조회 (GSI 사용)

```graphql
query StationsByCategory(
  $categoryId: ID!
  $sortDirection: ModelSortDirection
  $limit: Int
  $nextToken: String
) {
  stationsByCategory(
    categoryId: $categoryId
    sortDirection: $sortDirection
    limit: $limit
    nextToken: $nextToken
  ) {
    items {
      id
      categoryId
      stationName
      address
      latitude
      longitude
      isInspected
      createdAt
    }
    nextToken
  }
}
```

**Variables:**
```json
{
  "categoryId": "category-uuid",
  "sortDirection": "DESC",
  "limit": 1000,
  "nextToken": null
}
```

---

## 4. Mutations

### 4.1 createCategory
카테고리 생성

```graphql
mutation CreateCategory($input: CreateCategoryInput!) {
  createCategory(input: $input) {
    id
    name
    createdAt
    updatedAt
  }
}
```

**Variables:**
```json
{
  "input": {
    "name": "2026년 1월 검사목록"
  }
}
```

**Response:**
```json
{
  "data": {
    "createCategory": {
      "id": "generated-uuid",
      "name": "2026년 1월 검사목록",
      "createdAt": "2026-01-13T00:00:00.000Z",
      "updatedAt": "2026-01-13T00:00:00.000Z"
    }
  }
}
```

---

### 4.2 updateCategory
카테고리 수정

```graphql
mutation UpdateCategory($input: UpdateCategoryInput!) {
  updateCategory(input: $input) {
    id
    name
    createdAt
    updatedAt
  }
}
```

**Variables:**
```json
{
  "input": {
    "id": "category-uuid",
    "name": "수정된 카테고리명"
  }
}
```

---

### 4.3 deleteCategory
카테고리 삭제

```graphql
mutation DeleteCategory($input: DeleteCategoryInput!) {
  deleteCategory(input: $input) {
    id
  }
}
```

**Variables:**
```json
{
  "input": {
    "id": "category-uuid"
  }
}
```

---

### 4.4 createStation
무선국 생성

```graphql
mutation CreateStation($input: CreateStationInput!) {
  createStation(input: $input) {
    id
    categoryId
    stationName
    licenseNumber
    address
    latitude
    longitude
    callSign
    gain
    antennaCount
    remarks
    typeApprovalNumber
    frequency
    stationType
    stationOwner
    isInspected
    inspectionDate
    memo
    photoKeys
    createdAt
    updatedAt
  }
}
```

**Variables:**
```json
{
  "input": {
    "categoryId": "category-uuid",
    "stationName": "서울중앙국",
    "licenseNumber": "RN-2026-001",
    "address": "서울시 중구 세종대로 110",
    "latitude": 37.5665,
    "longitude": 126.9780,
    "callSign": "HLK",
    "gain": "10",
    "antennaCount": "2",
    "remarks": "비고 내용",
    "typeApprovalNumber": "KCC-2026-001",
    "frequency": "100.0 MHz",
    "stationType": "기지국",
    "stationOwner": "한국통신",
    "isInspected": false,
    "memo": null,
    "photoKeys": []
  }
}
```

---

### 4.5 updateStation
무선국 수정

```graphql
mutation UpdateStation($input: UpdateStationInput!) {
  updateStation(input: $input) {
    id
    categoryId
    stationName
    isInspected
    inspectionDate
    memo
    photoKeys
    updatedAt
  }
}
```

**Variables (검사완료 처리):**
```json
{
  "input": {
    "id": "station-uuid",
    "isInspected": true,
    "inspectionDate": "2026-01-13T10:30:00.000Z"
  }
}
```

**Variables (메모 수정):**
```json
{
  "input": {
    "id": "station-uuid",
    "memo": "현장 확인 결과 정상 운영 중"
  }
}
```

**Variables (사진 추가):**
```json
{
  "input": {
    "id": "station-uuid",
    "photoKeys": [
      "photos/station-uuid/1705123456789_photo1.jpg",
      "photos/station-uuid/1705123456790_photo2.jpg"
    ]
  }
}
```

---

### 4.6 deleteStation
무선국 삭제

```graphql
mutation DeleteStation($input: DeleteStationInput!) {
  deleteStation(input: $input) {
    id
  }
}
```

**Variables:**
```json
{
  "input": {
    "id": "station-uuid"
  }
}
```

---

## 5. Input Types

### 5.1 CreateCategoryInput
```graphql
input CreateCategoryInput {
  id: ID
  name: String!
}
```

### 5.2 UpdateCategoryInput
```graphql
input UpdateCategoryInput {
  id: ID!
  name: String
}
```

### 5.3 DeleteCategoryInput
```graphql
input DeleteCategoryInput {
  id: ID!
}
```

### 5.4 CreateStationInput
```graphql
input CreateStationInput {
  id: ID
  categoryId: ID!
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
  isInspected: Boolean
  inspectionDate: AWSDateTime
  memo: String
  photoKeys: [String]
}
```

### 5.5 UpdateStationInput
```graphql
input UpdateStationInput {
  id: ID!
  categoryId: ID
  stationName: String
  licenseNumber: String
  address: String
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
  isInspected: Boolean
  inspectionDate: AWSDateTime
  memo: String
  photoKeys: [String]
}
```

### 5.6 DeleteStationInput
```graphql
input DeleteStationInput {
  id: ID!
}
```

### 5.7 ModelStationFilterInput
```graphql
input ModelStationFilterInput {
  id: ModelIDInput
  categoryId: ModelIDInput
  stationName: ModelStringInput
  address: ModelStringInput
  isInspected: ModelBooleanInput
  and: [ModelStationFilterInput]
  or: [ModelStationFilterInput]
  not: ModelStationFilterInput
}
```

---

## 6. S3 Storage API

### 6.1 Configuration
| 항목 | 값 |
|------|-----|
| Bucket | ksa-photos-bucket1d5de-dev |
| Region | ap-northeast-2 |
| Access Level | Private |

### 6.2 Upload
**Endpoint:** AWS S3 (Amplify SDK)

**Path Format:**
```
private/{identityId}/photos/{stationId}/{timestamp}_{fileName}
```

**Request:**
```dart
await Amplify.Storage.uploadData(
  data: StorageDataPayload.bytes(bytes),
  path: StoragePath.fromIdentityId(
    (identityId) => 'private/$identityId/$fileKey',
  ),
).result;
```

### 6.3 Download (Presigned URL)
**Request:**
```dart
final result = await Amplify.Storage.getUrl(
  path: StoragePath.fromIdentityId(
    (identityId) => 'private/$identityId/$relativePath',
  ),
  options: StorageGetUrlOptions(
    pluginOptions: S3GetUrlPluginOptions(
      expiresIn: Duration(hours: 1),
    ),
  ),
).result;
```

**Response:** Presigned URL (1시간 유효)

### 6.4 Delete
**Request:**
```dart
await Amplify.Storage.remove(
  path: StoragePath.fromIdentityId(
    (identityId) => 'private/$identityId/$relativePath',
  ),
).result;
```

---

## 7. Cognito Authentication API

### 7.1 Configuration
| 항목 | 값 |
|------|-----|
| User Pool ID | ap-northeast-2_omieCGwQP |
| App Client ID | ehlckq7k9tl2n9b6gq12pj7tp |
| Identity Pool ID | ap-northeast-2:4640cfa8-1f7b-43eb-b2fa-4f8d021a70e1 |

### 7.2 Sign Up
```dart
await Amplify.Auth.signUp(
  username: email,
  password: password,
  options: SignUpOptions(
    userAttributes: {
      AuthUserAttributeKey.email: email,
      AuthUserAttributeKey.name: name,
      AuthUserAttributeKey.phoneNumber: phoneNumber,
    },
  ),
);
```

### 7.3 Confirm Sign Up
```dart
await Amplify.Auth.confirmSignUp(
  username: email,
  confirmationCode: code,
);
```

### 7.4 Sign In
```dart
await Amplify.Auth.signIn(
  username: email,
  password: password,
);
```

### 7.5 Sign Out
```dart
await Amplify.Auth.signOut();
```

### 7.6 Reset Password
```dart
await Amplify.Auth.resetPassword(username: email);
```

### 7.7 Confirm Reset Password
```dart
await Amplify.Auth.confirmResetPassword(
  username: email,
  newPassword: newPassword,
  confirmationCode: code,
);
```

---

## 8. Error Codes

### 8.1 GraphQL Errors
| Code | Description |
|------|-------------|
| Unauthorized | 인증 실패 또는 권한 없음 |
| ValidationError | 입력 데이터 유효성 검증 실패 |
| ConditionalCheckFailedException | 조건부 업데이트 실패 |
| ProvisionedThroughputExceededException | DynamoDB 처리량 초과 |

### 8.2 Cognito Errors
| Code | Description |
|------|-------------|
| UserNotFoundException | 존재하지 않는 사용자 |
| NotAuthorizedException | 인증 실패 |
| UsernameExistsException | 중복 이메일 |
| CodeMismatchException | 잘못된 인증 코드 |
| InvalidPasswordException | 비밀번호 정책 불충족 |
| LimitExceededException | 요청 횟수 초과 |
| ExpiredCodeException | 만료된 인증 코드 |

### 8.3 S3 Errors
| Code | Description |
|------|-------------|
| AccessDenied | 접근 권한 없음 |
| NoSuchKey | 존재하지 않는 키 |
| InvalidAccessKeyId | 잘못된 액세스 키 |
| SignatureDoesNotMatch | 서명 불일치 |

---

## 9. Rate Limits

| Service | Limit |
|---------|-------|
| AppSync Queries | 1,000 req/sec |
| AppSync Mutations | 1,000 req/sec |
| Cognito Sign In | 5 req/sec/IP |
| Cognito Sign Up | 5 req/sec/IP |
| S3 PUT | 3,500 req/sec/prefix |
| S3 GET | 5,500 req/sec/prefix |

---

## 10. Pagination

### 10.1 기본 페이지 크기
- 기본값: 1,000 items
- 최대값: 1,000 items

### 10.2 사용 예시
```graphql
# 첫 번째 페이지
query {
  listStations(limit: 1000) {
    items { ... }
    nextToken
  }
}

# 다음 페이지
query {
  listStations(limit: 1000, nextToken: "eyJ2ZXJzaW9u...") {
    items { ... }
    nextToken
  }
}
```

---

---

## 10. Tower Classification API (FastAPI)

철탑/안테나 설치형태 분류를 위한 REST API

### 10.1 API 정보

| 항목 | 값 |
|------|-----|
| Base URL | https://c3jictzagh.execute-api.ap-northeast-2.amazonaws.com |
| Protocol | HTTPS (API Gateway) |
| Backend | FastAPI + Uvicorn (EC2) |
| Model | YOLOv8n-cls |

### 10.2 분류 클래스 (9개)

| ID | 영문명 | 한글명 | 약어 |
|----|--------|--------|------|
| 0 | simple_pole | 간이폴, 분산폴 및 비기준 설치대 | 간이폴 |
| 1 | steel_pipe | 강관주 | 강관주 |
| 2 | complex_type | 복합형 | 복합형 |
| 3 | indoor | 옥내, 터널, 지하 등 | 옥내 |
| 4 | single_pole_building | 원폴(건물) | 원폴건물 |
| 5 | tower_building | 철탑(건물) | 철탑건물 |
| 6 | tower_ground | 철탑(지면) | 철탑지면 |
| 7 | telecom_pole | 통신주 | 통신주 |
| 8 | frame_mount | 프레임 | 프레임 |

### 10.3 Endpoints

#### GET /health
서버 및 모델 상태 확인

**Response:**
```json
{
  "status": "healthy",
  "model_loaded": true,
  "model_path": "/home/ubuntu/tower-api/best.pt",
  "timestamp": "2026-01-22T09:00:00.000Z"
}
```

#### GET /classes
분류 클래스 목록 조회

**Response:**
```json
{
  "classes": [
    {"id": 0, "name": "simple_pole", "name_kr": "간이폴, 분산폴 및 비기준 설치대", "short_name": "간이폴"},
    {"id": 1, "name": "steel_pipe", "name_kr": "강관주", "short_name": "강관주"},
    ...
  ]
}
```

#### POST /predict
단일 이미지 분류

**Request:**
- Content-Type: `multipart/form-data`
- Body: `file` (이미지 파일)
- Query: `conf_threshold` (선택, 기본값: 0.5)

**Response:**
```json
{
  "success": true,
  "prediction": {
    "class_name": "steel_pipe",
    "class_name_kr": "강관주",
    "short_name": "강관주",
    "confidence": 0.9234
  },
  "top5": [
    {"rank": 1, "class_name": "steel_pipe", "class_name_kr": "강관주", "confidence": 0.9234},
    {"rank": 2, "class_name": "telecom_pole", "class_name_kr": "통신주", "confidence": 0.0521},
    ...
  ],
  "is_confident": true,
  "processing_time_ms": 245.32
}
```

#### POST /predict/ensemble
다중 이미지 앙상블 분류

**Request:**
- Content-Type: `multipart/form-data`
- Body: `files` (여러 이미지 파일, 최대 10개)
- Query:
  - `method` (mean|max|vote, 기본값: mean)
  - `conf_threshold` (선택, 기본값: 0.5)

**Response:**
```json
{
  "success": true,
  "method": "mean",
  "num_images": 3,
  "final_prediction": {
    "class_name": "tower_ground",
    "class_name_kr": "철탑(지면)",
    "short_name": "철탑지면",
    "confidence": 0.8756
  },
  "top5": [...],
  "individual_predictions": [
    {"filename": "image1.jpg", "prediction": "tower_ground", "prediction_kr": "철탑(지면)", "confidence": 0.91},
    {"filename": "image2.jpg", "prediction": "tower_ground", "prediction_kr": "철탑(지면)", "confidence": 0.87},
    {"filename": "image3.jpg", "prediction": "tower_building", "prediction_kr": "철탑(건물)", "confidence": 0.82}
  ],
  "is_confident": true,
  "processing_time_ms": 523.45
}
```

### 10.4 Error Responses

| Status Code | 설명 |
|-------------|------|
| 400 | 잘못된 파일 형식 (지원: jpg, jpeg, png, bmp, webp) |
| 500 | 서버 내부 오류 |
| 503 | 모델 로드 실패 |

**Error Response Format:**
```json
{
  "detail": "Invalid file type. Allowed: {'.jpg', '.jpeg', '.png', '.bmp', '.webp'}"
}
```

### 10.5 인프라 구성

```
Flutter App (Amplify HTTPS)
        │
        ▼
API Gateway (HTTPS)
https://c3jictzagh.execute-api.ap-northeast-2.amazonaws.com
        │
        ▼
EC2 Instance (c7i-flex.large)
http://15.165.204.39:8000
FastAPI + YOLOv8 Model
```

---

## 변경 이력

| 버전 | 날짜 | 변경 내용 | 작성자 |
|------|------|----------|--------|
| 1.0.0 | 2026-01-13 | 최초 작성 | Dev Team |
| 1.1.0 | 2026-01-22 | Tower Classification API 추가 | Dev Team |
