# KSA Frontend API 명세서

## Frontend Services Specification

**버전:** 1.3.1
**최종 수정일:** 2026-03-03

---

## 1. AuthService

**파일:** `lib/services/auth_service.dart`

AWS Cognito 기반 사용자 인증을 담당합니다.

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `currentUserEmail` | `String?` | 현재 로그인된 사용자 이메일 |
| `currentUserName` | `String?` | 현재 사용자 이름 |
| `currentUserPhoneNumber` | `String?` | 현재 사용자 전화번호 |
| `isLoggedIn` | `bool` | 로그인 상태 |

### Methods

| 메서드 | 시그니처 | 설명 |
|--------|---------|------|
| `signUp` | `Future<SignUpResult?>` | 이메일 기반 회원가입 |
| `confirmSignUp` | `Future<bool>` | 이메일 인증 코드 확인 |
| `signIn` | `Future<bool>` | 로그인 |
| `signOut` | `Future<void>` | 로그아웃 |
| `resetPassword` | `Future<bool>` | 비밀번호 재설정 요청 |
| `confirmResetPassword` | `Future<bool>` | 비밀번호 재설정 완료 |
| `getCurrentUser` | `Future<AuthUser?>` | 현재 사용자 정보 |
| `updateActivity` | `void` | 세션 타임아웃 연장 |

---

## 2. CloudDataService

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

## 13. 화면 (Screens)

### 주요 화면 목록

| 화면 | 파일 | Drawer 메뉴 |
|------|------|------------|
| 홈 | `home_screen.dart` | — |
| 대시보드 (일정/통계) | `dashboard_screen.dart` | 일정 및 통계 |
| 무선국 지도 | `station_list_screen.dart` | — |
| AI 철탑분류 | `tower_classification_screen.dart` | AI 철탑형태 분류 |
| DS 데이터 관리 | `ds_dashboard_screen.dart` | DS 데이터 관리 |
| DS 데이터 조회 | `ds_data_screen.dart` | (DsDashboardScreen 내부) |
| DS 파일 병합 | `ds_merge_screen.dart` | (Drawer 미노출, 직접 접근) |

### Drawer 메뉴 구성

```
├── 일정 및 통계       → DashboardScreen
├── DS 데이터 관리     → DsDashboardScreen (업로드 + Export + 현황 통합)
│   └── icon: Icons.storage, color: #5C6BC0
└── AI 철탑형태 분류   → TowerClassificationScreen
```

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

---

## 14. JS 파일 (web/)

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

## 15. 환경 변수 / 빌드 설정

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `API_BASE_URL` | `https://api-sko-kca.skons.net` | DS API 서버 URL |

**Web 빌드 시:**
```bash
flutter build web --dart-define=API_BASE_URL=https://api-sko-kca.skons.net
```

**배포:** `deploy.ps1` — S3 sync (`s3://radio-inspection-web`) 또는 AWS Amplify 자동 배포

---

## 변경 이력

| 버전 | 날짜 | 변경 내용 |
|------|------|----------|
| 1.0.0 | 2026-01-13 | 최초 작성 |
| 1.2.0 | 2026-01-27 | TowerClassificationService, WeatherService, ExcelService.exportWithOriginalFormat 추가 |
| 1.3.0 | 2026-02-26 | DsDataService, DsUploadService, DsExportService 추가, Drawer 구성 변경, DsDashboardScreen 구조 명세, JS 파일 목록, 빌드 설정 추가 |
| 1.3.1 | 2026-03-03 | Upload-Zero-Build 반영: _maxPollDuration 35분→3분, DsDashboardScreen 자동 갱신 타이머 추가, DsUploadService 설명 업데이트 |
