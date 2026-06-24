# KSA Frontend API 명세서

## Frontend Services Specification

**버전:** 2.1.0
**최종 수정일:** 2026-04-06

---

## 1. AuthService

**파일:** `lib/services/auth_service.dart`

i-NET SSO 기반 사용자 인증 + HMAC 토큰 관리를 담당합니다.

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `userId` | `String?` | 현재 로그인된 사번 |
| `userName` | `String?` | 사용자 이름 |
| `userDepartment` | `String?` | 소속 본부 |
| `userTeam` | `String?` | 소속 팀 |
| `isSignedIn` | `bool` | 로그인 상태 |
| `authToken` | `String?` | HMAC Bearer 토큰 |
| `authHeaders` | `Map<String, String>` | `{'Authorization': 'Bearer $token'}` (토큰 있을 때) |
| `isAdmin` | `bool` | admin 역할 여부 |
| `isManager` | `bool` | manager 이상 역할 여부 |

### Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `signIn` | `Future<bool> signIn(String username, String password)` | SSO 로그인 → 토큰 발급·저장 |
| `signOut` | `Future<void>` | 로그아웃 → 토큰·세션 삭제 |
| `updateActivity` | `void` | 세션 타임아웃 연장 |

### 토큰 관리

- 로그인 성공 시 서버 응답의 `token` 필드를 `SharedPreferences`에 저장
- 앱 재시작 시 `SharedPreferences`에서 토큰 복원
- 로그아웃 시 토큰 삭제
- 토큰 만료: 서버에서 2시간, 클라이언트 세션 타임아웃도 2시간
- `authHeaders` getter로 모든 서비스에서 일관된 인증 헤더 사용

---

## 2. AdminService (v1.4.0)

**파일:** `lib/services/admin_service.dart`

관리자 패널 기능을 담당합니다. Bearer 토큰 인증 사용.

### Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `setCurrentUser` | `void setCurrentUser(String empno, {String? token})` | 인증 토큰 설정 |
| `loadAllUsers` | `Future<void>` | `GET /admin/users` — 전체 사용자 목록 (last_login, is_dormant 포함) |
| `changeUserRole` | `Future<bool> changeUserRole(String profileId, UserRole newRole)` | `PUT /admin/set-role` — 역할 변경 |
| `undormantUser` | `Future<bool> undormantUser(String empno)` | `POST /admin/undormant/{empno}` — 휴면 해제 |

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `allUsers` | `List<AppUserProfile>` | 전체 사용자 목록 |
| `isLoading` | `bool` | 로딩 상태 |
| `errorMessage` | `String?` | 오류 메시지 |

### AppUserProfile 모델 (주요 필드)

| 필드 | Type | 설명 |
|------|------|------|
| `id` | `String` | 사번 |
| `email` | `String` | 이메일 |
| `role` | `UserRole` | superAdmin / divisionAdmin / member |
| `teamId` | `String?` | 소속 팀 |
| `divisionId` | `String?` | 소속 본부 |
| `lastLogin` | `String?` | 마지막 로그인 (UTC ISO) |
| `isDormant` | `bool` | 휴면 여부 |

---

## 3. AuditService (v1.4.0)

**파일:** `lib/services/audit_service.dart`

감사 로그 조회를 담당합니다. Bearer 토큰 인증 사용.

### Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `setUserContext` | `void setUserContext(String userId, {String? token})` | 인증 토큰 설정 |
| `fetchLogs` | `Future<void>` | `GET /admin/audit-logs` — 감사 로그 조회 |

---

## 4. CloudDataService

**파일:** `lib/services/cloud_data_service.dart`

AWS AppSync GraphQL API 통신을 담당합니다.

### Category Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `createCategory` | `Future<String?> createCategory(String name, {String? originalExcelKey})` | 카테고리 생성 → categoryId 반환 |
| `listCategories` | `Future<List<Map<String, dynamic>>>` | 카테고리 목록 조회 |
| `updateCategoryOriginalExcelKey` | `Future<bool>` | 원본 Excel S3 키 업데이트 |
| `deleteCategory` | `Future<bool>` | 카테고리 삭제 |

### Station Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `createStation` | `Future<String?> createStation(RadioStation, String categoryId)` | 무선국 생성 |
| `listStationsByCategory` | `Future<List<RadioStation>>` | 카테고리별 무선국 조회 |
| `listAllStations` | `Future<List<RadioStation>>` | 전체 무선국 조회 |
| `updateStation` | `Future<bool>` | 무선국 수정 |
| `deleteStation` | `Future<bool>` | 무선국 삭제 |

### Sync Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `syncLocalToCloud` | `Future<bool>` | 로컬 → 클라우드 동기화 |
| `syncCloudToLocal` | `Future<Map<String, List<RadioStation>>>` | 클라우드 → 로컬 동기화 |

---

## 3. StorageService

**파일:** `lib/services/storage_service.dart`

Hive 기반 로컬 데이터 저장을 담당합니다.

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `init` | `Future<void>` | 초기화 |
| `getAllStations` | `List<RadioStation>` | 전체 무선국 조회 |
| `saveStation` | `Future<void>` | 단건 저장 |
| `saveStations` | `Future<void>` | 다건 일괄 저장 |
| `deleteStation` | `Future<void>` | 삭제 |
| `clearAllStations` | `Future<void>` | 전체 삭제 |
| `updateMemo` | `Future<void>` | 메모 수정 |
| `updateInspectionStatus` | `Future<void>` | 검사 상태 변경 |
| `updatePhotoPaths` | `Future<void>` | 사진 경로 업데이트 |

---

## 4. PhotoStorageService

**파일:** `lib/services/photo_storage_service.dart`

AWS S3 기반 사진 업로드/다운로드를 담당합니다.

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `uploadPhoto` | `static Future<String?> uploadPhoto(Uint8List, String fileName, String stationId)` | S3 업로드, 키 반환 |
| `getPhotoUrl` | `static Future<String> getPhotoUrl(String photoPath)` | Presigned URL (1시간) |
| `deletePhoto` | `static Future<void> deletePhoto(String photoPath)` | S3 삭제 |
| `isValidPhotoUrl` | `static bool isValidPhotoUrl(String photoPath)` | 유효성 확인 |

**S3 경로:** `private/{identityId}/photos/{stationId}/{timestamp}_{fileName}`

---

## 5. ExcelService

**파일:** `lib/services/excel_service.dart`

Excel 파일 가져오기/내보내기를 담당합니다.

| 메서드 | 설명 |
|--------|------|
| `importExcelFile()` | XLSX/XLS 파일 선택 → `ExcelImportResult?` |
| `exportToExcelWithPhotosWeb(stations, fileName)` | Excel + 사진 ZIP export (Web) |
| `exportToExcelWithPhotosMobile(stations, fileName)` | Excel + 사진 ZIP export (Mobile) |
| `exportWithOriginalFormat({originalExcelBytes, stations})` | 원본 서식 유지 export → `Uint8List?` |

**Excel 컬럼 매핑 (import):**

| 인덱스 | 필드 |
|--------|------|
| 0 | 순번 (무시) |
| 1 | stationName |
| 2 | licenseNumber |
| 3 | address |
| 4 | callSign |
| 5 | gain |
| 6 | antennaCount |
| 7 | remarks |
| 8 | typeApprovalNumber |
| 9 | frequency |
| 10 | stationType |
| 11 | owner |

---

## 6. GeocodingService

**파일:** `lib/services/geocoding_service.dart`

Kakao API 기반 주소-좌표 변환을 담당합니다.

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `getCoordinatesFromAddress` | `Future<Map<String, double>?>` | 주소 → `{latitude, longitude}` |
| `getCoordinatesFromAddresses` | `Future<List<Map<String, double>?>>` | 다건 변환 (100ms 딜레이) |

---

## 7. DsDataService (신규)

**파일:** `lib/services/ds_data_service.dart`

DS 데이터 조회/삭제를 담당합니다. Base URL: `https://api-sko-kca.skons.net`

### 상수

```dart
// Auth 본부 → DS 본부 매핑
static const Map<String, String> authToDsDivision = {
  'gangnam': 'sudogwon', 'gangbuk': 'sudogwon', 'incheon': 'sudogwon', 'gyeonggi': 'sudogwon',
  'gangwon': 'gangwon', 'chungcheong': 'chungcheong',
  'gyeongbuk': 'gyeongbuk', 'gyeongnam': 'gyeongnam', 'seobu': 'seobu',
};
```

### Methods

#### `getStats({String? divisionId}) → Future<DsStatsResult>`
업로드 현황 조회 (`GET /ds/stats`)

```dart
class DsStatsResult {
  final List<DsUploadInfo> uploads;
  int get totalRows;
  int get totalUploads;
  Set<String> get divisions;
}

class DsUploadInfo {
  final String divisionId;
  final String divisionCode;
  final String divisionName;
  final String importDateSk;   // SK 원본 (예: "50#20260203")
  final String actualDate;     // 순수 날짜 (예: "20260203")
  final String uploadedBy;
  final String uploadedAt;
  final String fileName;
  final String status;
  final Map<String, int> sheetStats;  // {시트명: 행 수}
  final int totalRows;
  String get formattedDate;    // "2026-02-03" 형식
  int get sheetCount;
}
```

#### `getData({divisionId, sheetName, importDate?, limit?, lastKey?, search?}) → Future<DsDataPage>`
시트 데이터 페이징 조회 (`GET /ds/data`)

```dart
class DsDataPage {
  final List<DsRecord> items;
  final int count;
  final String? lastEvaluatedKey;
  bool get hasMore;
}

class DsRecord {
  final String divisionId;
  final String sk;
  final String sheetName;
  final String importDate;
  final String divisionCode;
  final Map<String, String> data;  // 헤더명 → 셀 값
}
```

#### `deleteData(divisionId, importDate, {divisionCode?}) → Future<int>`
데이터 삭제 (`DELETE /ds/data`) → 삭제된 건수 반환

---

## 8. DsUploadService (신규)

**파일:** `lib/services/ds_upload_service.dart`

DS ZIP 업로드 → EC2 proxy → S3 → enqueue → polling을 담당합니다.
서버는 메타데이터만 파싱 (Upload-Zero-Build) → ~10초 완료.
(JS interop 없음 — 순수 Dart)

### 타임아웃 설정

| 상수 | 값 | 용도 |
|------|-----|------|
| `_s3Timeout` | 10분 | ZIP S3 업로드 |
| `_apiTimeout` | 30초 | API 호출 |
| `_pollInterval` | 3초 | 잡 폴링 간격 |
| `_maxPollDuration` | 3분 | 최대 대기 (Upload-Zero-Build로 단축) |

### `pickAndUpload({uploadedBy, onProgress}) → Future<String>`

ZIP 파일 선택 → 업로드 → 완료 메시지 반환

**다중 파일:** 각 파일 독립 처리, 개별 오류 시 나머지 계속 진행

**진행률 표시:**
- `onProgress(String stage, double percent)` 콜백
- 0~20%: S3 업로드
- 20~100%: 서버 처리 (폴링)
- 큐 대기 중: `"$stage (대기 $queuePosition번째)"`

**내부 흐름:**
```
1. FilePicker → ZIP bytes
2. POST /ds/upload-raw (MultipartRequest) → s3Key
3. POST /ds/enqueue → jobId
4. GET /ds/job/{jobId} 3초 폴링 → completed / failed (~10초)
5. 완료: "충청본부 2026-02-03\n10개 시트, 120,000행 업로드 완료"
```

> **v1.3.1**: 서버가 메타데이터만 파싱하므로 폴링 완료까지 ~10초.
> `_maxPollDuration`을 35분 → 3분으로 단축.

---

## 9. DsExportService (신규, 웹 전용)

**파일 (web):** `lib/services/ds_export_service_web.dart`
**파일 (stub):** `lib/services/ds_export_service_stub.dart`

조건부 import 패턴으로 웹/비웹 분기 처리합니다.

### JS 함수 바인딩

```dart
@JS('_downloadXlsxFromUrl')
external void _jsDownloadXlsxFromUrl(JSString url, JSString filename, JSFunction progress, JSFunction completion);

@JS('_exportDsFromS3')
external void _jsExportDsFromS3(JSString s3Url, JSString metaJson, JSFunction progress, JSFunction completion);

@JS('_exportDsToXlsx')
external void _jsExportDsToXlsx(JSString jsonString, JSFunction progress, JSFunction completion);
```

### Methods

#### `downloadXlsxFromUrl({url, filename, onProgress}) → Future<String>`
S3 presigned URL에서 xlsx 직접 다운로드
- 타임아웃: 5분
- JS: `_downloadXlsxFromUrl` (web/ds_export.js)

#### `exportDsFromS3({s3Url, metaJson, onProgress}) → Future<String>`
S3 원본 ZIP 다운로드 → JS에서 병합 → xlsx 다운로드
- 타임아웃: 10분
- JS: `_exportDsFromS3` (web/ds_export.js)

#### `exportDsToXlsx({jsonData, onProgress}) → Future<String>`
DynamoDB JSON 데이터 → JS에서 xlsx 생성 + 다운로드 (폴백)
- 타임아웃: 10분
- JS: `_exportDsToXlsx` (web/ds_export.js)

---

## 10. DsMergeService (기존)

**파일 (web):** `lib/services/ds_merge_service_web.dart`
**파일 (stub):** `lib/services/ds_merge_service_stub.dart`

브라우저에서 ZIP 내 XLS 파일 병합 → xlsx 다운로드 담당합니다.

```dart
@JS('_mergeDsFilesFromDart')
external void _jsMergeDsFilesFromDart(JSObject zipBuffer, JSFunction progress, JSFunction completion);
```

#### `mergeDsFiles({zipBytes, onProgress}) → Future<String>`
- JS: `_mergeDsFilesFromDart` (web/ds_merge.js)
- 타임아웃: 30분

---

## 11. TowerClassificationService

**파일:** `lib/services/tower_classification_service.dart`

YOLOv8 모델 기반 철탑 분류를 담당합니다.

| 메서드 | 설명 |
|--------|------|
| `checkServerConnection()` | `Future<ServerStatus>` |
| `classifySingle(imageBytes, filename, {confThreshold})` | `Future<ClassificationResult>` |
| `classifyEnsemble(imageBytesList, filenames, {method, confThreshold})` | `Future<EnsembleResult>` |
| `getClassList()` | `Future<List<ClassInfo>>` |
| `submitFeedback({imageBytes, filename, originalClass, correctedClass})` | `Future<FeedbackResult>` |

---

## 12. WeatherService

**파일:** `lib/services/weather_service.dart`

기상청 API 기반 날씨 정보를 제공합니다.

```dart
class WeatherInfo {
  final String condition;    // 맑음, 흐림, 비, 눈 등
  final String icon;         // ☀️ 🌧️ ❄️ 등
  final double? temperature;
  final String? locationName;
}
```

| 메서드 | 설명 |
|--------|------|
| `getCurrentWeather()` | `static Future<WeatherInfo>` — GPS + 기상청 API |

---

## 13. CallnameService (v2.0.0)

**파일:** `lib/services/callname_service.dart`

호출명칭 매칭 시스템 클라이언트를 담당합니다. Bearer 토큰 인증 사용.

### Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `setAuthToken` | `void setAuthToken(String? token)` | 인증 토큰 설정 |
| `getDbStatus` | `Future<Map<String, dynamic>>` | `GET /callname/db-status` — DB 상태 조회 |
| `getDbPreview` | `Future<List<Map>>` | `GET /callname/db-preview` — DB 샘플 조회 |
| `uploadCsv` | `Future<String> uploadCsv(Uint8List bytes, String filename, {String mode})` | `POST /callname/upload-csv` — DB 업로드 (admin) |
| `uploadRaw` | `Future<String> uploadRaw(Uint8List bytes, String filename)` | `POST /callname/upload-raw` — 매칭용 Excel 업로드 |
| `uploadComplete` | `Future<Map> uploadComplete(String s3Key)` | `POST /callname/upload-complete` — 업로드 완료 처리 |
| `getAnalysis` | `Future<Map> getAnalysis(String uploadId)` | `GET /callname/upload/{id}/analysis` — 컬럼 자동 감지 |
| `getColumnValues` | `Future<List<String>> getColumnValues(String uploadId, String column)` | `POST /callname/upload/{id}/column-values` |
| `startProcess` | `Future<String> startProcess(String uploadId, Map filters, List targets)` | `POST /callname/process` — 매칭 실행 |
| `streamProgress` | `Stream<Map> streamProgress(String processId)` | `GET /callname/process/{id}/stream` — SSE 진행률 |
| `downloadResult` | `Future<void> downloadResult(String processId)` | `GET /callname/process/{id}/download` — 결과 다운로드 |

---

## 14. CertificateService (v2.0.0)

**파일:** `lib/services/certificate_service.dart`

설치확인서 생성을 담당합니다. Bearer 토큰 인증 사용.

### Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `setAuthToken` | `void setAuthToken(String? token)` | 인증 토큰 설정 |
| `lookup` | `Future<Map> lookup(String zpwino)` | `POST /cert/lookup` — 국소 정보 조회 |
| `generate` | `Future<Uint8List> generate(Map data, {String format})` | `POST /cert/generate` — 단일 생성 |
| `batchLookup` | `Future<List<Map>> batchLookup(List<String> zpwinos)` | `POST /cert/batch/lookup` — 일괄 조회 |
| `batchUploadPhotos` | `Future<String> batchUploadPhotos(Uint8List zipBytes)` | `POST /cert/batch/upload-photos` — 사진 ZIP 업로드 |
| `batchGenerate` | `Future<String> batchGenerate(List items, {String? photoS3Key})` | `POST /cert/batch/generate` — 일괄 생성 |
| `batchDownload` | `Future<void> batchDownload(String jobId)` | `GET /cert/batch/download/{id}` — ZIP 다운로드 |

---

## 15. InspectionService (v2.1.0)

**파일:** `lib/services/inspection_service.dart`

수검 관리 시스템 클라이언트를 담당합니다. Bearer 토큰 인증 사용.

### Import Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `setAuthToken` | `void setAuthToken(String? token)` | 인증 토큰 설정 |
| `uploadRaw` | `Future<String> uploadRaw(Uint8List bytes, String filename)` | `POST /inspection/upload-raw` — KCA Excel 업로드 |
| `enqueue` | `Future<String> enqueue(String s3Key, String year, String uploadedBy)` | `POST /inspection/enqueue` — Import 잡 등록 |
| `getJobStatus` | `Future<Map> getJobStatus(String jobId)` | `GET /inspection/job/{id}` — 잡 상태 조회 |

### Metadata Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `getMeta` | `Future<Map> getMeta()` | `GET /inspection/meta` — 메타데이터 조회 |
| `getUnassigned` | `Future<List> getUnassigned(String year)` | `GET /inspection/unassigned` — 미배정 조회 |
| `getColumnValues` | `Future<List> getColumnValues(String year, String column)` | `GET /inspection/column-values` |
| `getOrgMap` | `Future<Map> getOrgMap()` | `GET /inspection/org-map` — 조직 맵 |

### Staging Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `stagingPreview` | `Future<Map> stagingPreview(Map request)` | `POST /inspection/staging/preview` |
| `stagingConfirm` | `Future<Map> stagingConfirm(Map request)` | `POST /inspection/staging/confirm` |

### Data Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `queryData` | `Future<Map> queryData(Map request)` | `POST /inspection/data` — 데이터 조회 |
| `exportXlsx` | `Future<void> exportXlsx(Map request)` | `POST /inspection/export-xlsx` — XLSX Export |
| `getSummary` | `Future<Map> getSummary(String year)` | `POST /inspection/summary` — 통계 |

### Schedule Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `createSchedule` | `Future<bool> createSchedule(Map schedule)` | `POST /inspection/schedule` |
| `deleteSchedule` | `Future<bool> deleteSchedule(String year, String licenseNo)` | `DELETE /inspection/schedule/{year}/{허가번호}` |
| `getSchedules` | `Future<List> getSchedules({String year, String? accessManager})` | `GET /inspection/schedules` |

### Result Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `saveResult` | `Future<bool> saveResult(Map result)` | `POST /inspection/result` |
| `uploadResultPhoto` | `Future<String> uploadResultPhoto(Uint8List bytes, String filename)` | `POST /inspection/result/photo` |
| `deleteResultPhoto` | `Future<bool> deleteResultPhoto(Map params)` | `DELETE /inspection/result/photo` |

### User Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `getMyList` | `Future<List> getMyList(String year, {String week})` | `GET /inspection/my-list` (dev: 전체, 실계정: AND 조건) |
| `getProgress` | `Future<List> getProgress(int year)` | `GET /inspection/progress` — 본부별 진행률 |

### Results Methods (실적 결과장)

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `getResultsDashboard` | `Future<Map> getResultsDashboard(int year, {String region})` | 대시보드 집계 |
| `getResultsMonthly` | `Future<Map> getResultsMonthly(int year, String month, {String region})` | 월별 집계 |
| `getResultsAnalysis` | `Future<Map> getResultsAnalysis(int year, {String region})` | 불합격 분석 |
| `getResultsWeeklyTrend` | `Future<Map> getResultsWeeklyTrend(int year, {String region})` | 주별 추이 |
| `getResultsWeeklyTrendByRegion` | `Future<Map> getResultsWeeklyTrendByRegion(int year, {String region})` | 본부별 주별 추이 |
| `getResultsSummaryReport` | `Future<Map> getResultsSummaryReport(int year, {String region})` | 현황 리포트 (성능/서류 분리) |
| `getResultsWeeks` | `Future<List<String>> getResultsWeeks(int year, {String month, String region})` | 업로드된 주차 목록 동적 조회 |
| `exportResultsXlsx` | `Future<Uint8List> exportResultsXlsx(int year, {String region, String week})` | 결과장 XLSX 다운로드 |

### Workflow Methods (Phase 1~5)

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `transitionStatus` | `Future<void> transitionStatus(String pk, String toStatus, {String memo})` | 단일 일정 상태 전환 |
| `transitionStatusBulk` | `Future<Map> transitionStatusBulk(List<String> pks, String toStatus, {String memo})` | 다중 일정 일괄 전환 |
| `getScheduleLog` | `Future<List<Map>> getScheduleLog(String pk)` | 전환 이력 조회 |
| `submitPreCheckResult` | `Future<void> submitPreCheckResult(String pk, Map summary, {List items, bool confirmationAcknowledged})` | 전산비교 결과 첨부 + PRE_CHECK_DONE 전환 |
| `createChangeRequest` | `Future<void> createChangeRequest(String pk, List<Map> items)` | 변경 요청 등록 |
| `listChangeRequests` | `Future<List<Map>> listChangeRequests({String schedulePk, String status})` | 변경 요청 목록 |
| `markChangeRequestsFiled` | `Future<void> markChangeRequestsFiled(String schedulePk)` | 신고 완료 → RE_CHECK |
| `downloadChangeRequestForm` | `Future<Uint8List> downloadChangeRequestForm(...)` | 신고서 xls 다운로드 |
| `applyPartialDs` | `Future<Map> applyPartialDs(Uint8List bytes, String filename)` | 부분 DS 업로드 + 자동 재비교 |

### Phase 3: 검사내역서 + 접수

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `generateInspectionReport` | `Future<Uint8List> generateInspectionReport({required List<String> schedulePks, String sheetTitle})` | 검사내역서 발급 + REPORT_ISSUED 전환 |
| `submitInspection` | `Future<void> submitInspection({required String schedulePk, required String submissionNo, String submittedAt})` | 단건 접수번호 입력 → SUBMITTED |
| `submitInspectionBulk` | `Future<Map> submitInspectionBulk({required List<String> schedulePks, required String submissionNo, String submittedAt})` | 다중 일정 접수번호 일괄 입력 |

### Phase 5: 알림 + 대시보드

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `getNotifications` | `Future<List<Map>> getNotifications({bool unreadOnly, int limit})` | 알림 목록 (안 읽음 필터 가능) |
| `getUnreadNotificationCount` | `Future<int> getUnreadNotificationCount()` | 안 읽음 카운트 (종 배지용) |
| `markNotificationsRead` | `Future<int> markNotificationsRead({List<int> ids})` | ids 비면 전체 일괄 읽음 |
| `getDashboard` | `Future<Map> getDashboard(int year)` | 역할별 대시보드 집계 |

---

## 16. ErpDsCompareService (v2.0.0)

**파일:** `lib/services/erp_ds_compare_service.dart`

ERP vs DS 데이터 비교를 담당합니다. Bearer 토큰 인증 사용.

### Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `setAuthToken` | `void setAuthToken(String? token)` | 인증 토큰 설정 |
| `compare` | `Future<Map> compare(String divisionId, String importDate)` | `POST /erp-ds/compare` — 데이터 비교 실행 |

---

## 17. DivisionDataService (v2.0.0)

**파일:** `lib/services/division_data_service.dart`

본부별 수검 대상 데이터 관리를 담당합니다.

### Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `setAuthToken` | `void setAuthToken(String? token)` | 인증 토큰 설정 |
| `getDivisionStats` | `Future<Map>` | 본부 현황 통계 조회 |
| `getTargetList` | `Future<List> getTargetList({filters, search, page, limit})` | 대상 목록 조회 |
| `batchUpdateStatus` | `Future<bool> batchUpdateStatus(List ids, String status)` | 일괄 상태 변경 |
| `exportExcel` | `Future<void> exportExcel({filters})` | 원본 서식 유지 Excel Export |
| `importExcel` | `Future<Map> importExcel(Uint8List bytes, String filename)` | 수정본 Excel Import |

---

## 18. TeamContextService (v2.0.0)

**파일:** `lib/services/team_context_service.dart`

팀/본부 컨텍스트 관리를 담당합니다.

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `currentDivision` | `String?` | 현재 선택된 본부 |
| `currentTeam` | `String?` | 현재 선택된 팀 |

### Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `setContext` | `void setContext({String? division, String? team})` | 컨텍스트 설정 |
| `clearContext` | `void clearContext()` | 컨텍스트 초기화 |

---

## 19. 화면 (Screens)

### 주요 화면 목록

| 화면 | 파일 | Drawer 메뉴 |
|------|------|------------|
| 홈 | `home_screen.dart` | — |
| 시스템 안내 | `system_guide_screen.dart` | 시스템 안내 (정적, OVERVIEW.md 기반) |
| 대시보드 (일정/통계) | `dashboard_screen.dart` | 일정 및 통계 |
| 무선국 지도 | `station_list_screen.dart` | — |
| AI 철탑분류 | `tower_classification_screen.dart` | AI 철탑형태 분류 |
| DS 데이터 관리 | `ds_dashboard_screen.dart` | DS 데이터 관리 |
| DS 데이터 조회 | `ds_data_screen.dart` | (DsDashboardScreen 내부) |
| DS 파일 병합 | `ds_merge_screen.dart` | (Drawer 미노출, 직접 접근) |
| 사용자 관리 (관리자) | `admin/user_management_screen.dart` | 관리자 패널 > 사용자 관리 |
| 감사 로그 (관리자) | `admin/audit_log_screen.dart` | 관리자 패널 > 감사 로그 |
| 호출명칭 매칭 | `callname_screen.dart` | 호출명칭 매칭 |
| 설치확인서 | `certificate_screen.dart` | 설치확인서 생성 |
| 수검 일정 관리 | `inspection_schedule_screen.dart` | 수검 관리 |
| 수검 결과 기록 | `inspection_result_screen.dart` | 수검 관리 |
| ERP-DS 비교 | `erp_ds_compare_screen.dart` | ERP-DS 비교 |
| 본부 대상 관리 | `division_management_screen.dart` | 본부 대상 관리 |
| DS 업로드 | `ds_upload_screen.dart` | DS 데이터 관리 |

### Drawer 메뉴 구성

```
├── 수검 관리           → InspectionScheduleScreen
├── 일정 및 통계       → DashboardScreen
├── DS 데이터 관리     → DsDashboardScreen (업로드 + Export + 현황 통합)
├── 호출명칭 매칭      → CallnameScreen
├── 설치확인서 생성    → CertificateScreen
├── 본부 대상 관리     → DivisionManagementScreen
├── ERP-DS 비교       → ErpDsCompareScreen
├── AI 철탑형태 분류   → TowerClassificationScreen
└── 관리자 패널       → AdminPanelScreen (admin/manager only)
```

### 공통 위젯 (Phase 5 추가)

| 위젯 | 파일 | 사용처 |
|------|------|--------|
| `NotificationBellButton` | `widgets/notification_bell_button.dart` | 홈 모바일 AppBar 우상단 — 안 읽음 빨간 배지 (60초 폴링) + 클릭 시 `NotificationPanel` 다이얼로그 |
| `NotificationPanel` | `widgets/notification_bell_button.dart` | 종 클릭 시 / 로그인 자동 팝업 (`loginPopupMode: true`) — 안 읽음 토글, 모두 읽음, 오늘 보지 않기 |
| `maybeShowLoginNotificationPopup` | `widgets/notification_bell_button.dart` | 홈 진입 직후 자동 호출 — SharedPreferences 키 `notification_popup_hidden_YYYY-MM-DD` 확인 |
| `InspectionDashboardWidget` | `widgets/inspection_dashboard_widget.dart` | 홈 화면 "내 할 일" 섹션 — 역할별 자동 분기, 상태 8장 카드 + 재점검/지연 카드 |

### DsDashboardScreen 구조

```
AppBar: "DS 데이터 관리" [새로고침]
├── [ZIP 업로드] 버튼 → DsUploadService.pickAndUpload()
├── 업로드 진행 중: LinearProgressIndicator + stage 텍스트
├── 요약 카드 (본부 수 / 업로드 수 / 총 행 수)
├── 본부별 바 차트
└── 업로드 목록
    └── 카드: 본부명 | 날짜 | 코드 | 행 수 | 시트 수
        ├── [데이터 조회] → DsDataScreen
        ├── [Excel Export] → export-presign → downloadXlsxFromUrl
        │                               또는 → /ds/export-xlsx
        └── [삭제] → DsDataService.deleteData()
```

**자동 갱신 (v1.3.1):**
- `_autoRefreshTimer`: `status == 'uploading'` 레코드 존재 시 10초 주기 `_loadStats()` 호출
- 업로드 완료/실패 시 자동 중단 (uploading 레코드 소멸)
- `dispose()`에서 타이머 취소

### CallnameScreen 구조

```
AppBar: "호출명칭 매칭"
├── Step 1: Excel 업로드
│   ├── 파일 선택 버튼 → 업로드 진행률
│   └── 컬럼 자동 감지 결과 표시
├── Step 2: 필터 설정
│   ├── 컬럼별 다중 선택 필터
│   └── 필터된 행 수 미리보기
└── Step 3: 매칭 실행
    ├── SSE 실시간 진행률 바
    └── 결과 Excel 다운로드 버튼
```

### CertificateScreen 구조

```
AppBar: "설치확인서 생성"
TabBar: [개별 생성] [일괄 생성]
├── 개별 탭
│   ├── 국소명/허가번호 검색 → 자동 채움
│   ├── 설치 상세 입력 폼 (안테나, 설치대, 공동설치)
│   ├── 첨부 파일 (도면, 사진)
│   └── [PDF 생성] [HWPX 생성] 버튼
└── 일괄 탭
    ├── Excel 업로드 → 컬럼 매핑
    ├── 사진 ZIP 업로드
    └── [일괄 생성] → ZIP 다운로드
```

### InspectionScheduleScreen 구조

```
AppBar: "수검 관리" [연도 선택] [필터]
├── 필터 패널 (본부, 분기, Access담당, 상태)
├── 미배정 현황 바
├── 데이터 그리드
│   ├── 허가번호, 호출명칭, 본부, 담당, 상태, 검사일
│   └── 행 클릭 → InspectionResultScreen
└── [Export] [Import] 버튼
```

---

## 20. JS 파일 (web/)

| 파일 | 역할 |
|------|------|
| `web/ds_merge.js` | ZIP + SheetJS + JSZip → 브라우저 XLS 병합 → xlsx |
| `web/ds_export.js` | S3 xlsx 다운로드 / DB JSON → xlsx (폴백) |
| `web/ds_upload.js` | (사용 안 함, upload-raw로 대체) |

### ds_export.js 전역 함수

| 함수 | 설명 |
|------|------|
| `_downloadXlsxFromUrl(url, filename, progress, completion)` | S3 presigned URL 직접 다운로드 |
| `_exportDsFromS3(s3Url, metaJson, progress, completion)` | S3 ZIP → 병합 → xlsx |
| `_exportDsToXlsx(jsonString, progress, completion)` | JSON → xlsx (폴백) |

### ds_merge.js 전역 함수

| 함수 | 설명 |
|------|------|
| `_mergeDsFilesFromDart(zipArrayBuffer, progress, completion)` | ZIP → XLS 병합 → xlsx 다운로드 |

---

## 21. 환경 변수 / 빌드 설정

### 빌드 시 `--dart-define` 변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `API_BASE_URL` | `https://api-sko-kca.skons.net` | DS API 서버 URL |
| `KAKAO_JS_KEY` | (없음) | 카카오 JavaScript 키 (웹/지도용) |
| `KAKAO_REST_KEY` | (없음) | 카카오 REST API 키 (지오코딩용) |
| `KAKAO_NATIVE_KEY` | (없음) | 카카오 Native 앱 키 (Android/iOS용) |
| `KMA_SERVICE_KEY` | (없음) | 기상청 API 서비스 키 |

**Web 빌드 시:**
```bash
flutter build web --release \
  --dart-define=KAKAO_JS_KEY=xxx \
  --dart-define=KAKAO_REST_KEY=xxx \
  --dart-define=KAKAO_NATIVE_KEY=xxx \
  --dart-define=KMA_SERVICE_KEY=xxx
```

**Amplify 자동 빌드:** `amplify.yml`에서 환경변수 참조 (`$KAKAO_JS_KEY` 등), Amplify 콘솔 Environment variables에 설정.

**배포:** AWS Amplify 자동 배포 (git push) 또는 `deploy.ps1` — S3 sync

### 인증 헤더

모든 인증 필요 API 호출 시 `Authorization: Bearer <token>` 헤더 사용.
- 토큰: `AuthService.authToken`에서 취득
- 각 서비스에 `setAuthToken(String? token)` 메서드로 전달
- `main.dart`의 `_propagateAuthToken()`에서 로그인/로그아웃 시 자동 전파

---

## 변경 이력

| 버전 | 날짜 | 변경 내용 |
|------|------|----------|
| 1.0.0 | 2026-01-13 | 최초 작성 |
| 1.2.0 | 2026-01-27 | TowerClassificationService, WeatherService, ExcelService.exportWithOriginalFormat 추가 |
| 1.3.0 | 2026-02-26 | DsDataService, DsUploadService, DsExportService 추가, Drawer 구성 변경, DsDashboardScreen 구조 명세, JS 파일 목록, 빌드 설정 추가 |
| 1.3.1 | 2026-03-03 | Upload-Zero-Build 반영: _maxPollDuration 35분→3분, DsDashboardScreen 자동 갱신 타이머 추가, DsUploadService 설명 업데이트 |
| 1.4.0 | 2026-03-04 | 보안 강화: AuthService SSO+토큰 전환, AdminService·AuditService 추가, 전 서비스 Bearer 토큰 인증, API 키 dart-define 분리, X-User-Id 완전 제거, 관리자 화면(사용자 관리/감사 로그) 추가 |
| 2.0.0 | 2026-03-23 | CallnameService, CertificateService, InspectionService, ErpDsCompareService, DivisionDataService, TeamContextService 추가. 화면 7개 추가 (호출명칭 매칭, 설치확인서, 수검 일정, 수검 결과, ERP-DS 비교, 본부 대상 관리, DS 업로드). Drawer 메뉴 전면 재구성 |
| 2.1.0 | 2026-04-06 | AdminService.undormantUser() 추가 (휴면 해제), AppUserProfile에 lastLogin/isDormant 필드 추가, InspectionService Results Methods 섹션 추가 (getResultsWeeks 포함), 메뉴명 '수검 현황' → '실적 관리' 반영, DashboardScreen.selectedRegion prop 추가 (외부 필터 동기화) |
