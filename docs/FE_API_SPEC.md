# KSA Frontend API 명세서

## Frontend Services Specification

**버전:** 1.0.0
**최종 수정일:** 2026-01-13

---

## 1. AuthService (인증 서비스)

**파일:** `lib/services/auth_service.dart`

AWS Cognito 기반 사용자 인증을 담당합니다.

### 1.1 Properties

| Property | Type | Description |
|----------|------|-------------|
| `currentUserEmail` | `String?` | 현재 로그인된 사용자 이메일 |
| `currentUserName` | `String?` | 현재 사용자 이름 |
| `currentUserPhoneNumber` | `String?` | 현재 사용자 전화번호 |
| `isLoggedIn` | `bool` | 로그인 상태 |

### 1.2 Methods

#### `signUp`
회원가입을 수행합니다.

```dart
Future<SignUpResult?> signUp({
  required String email,
  required String password,
  String? name,
  String? phoneNumber,
})
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| email | String | O | 이메일 주소 |
| password | String | O | 비밀번호 (8자 이상) |
| name | String | - | 사용자 이름 |
| phoneNumber | String | - | 전화번호 (+82 형식 자동 변환) |

**Returns:** `SignUpResult?` - 성공 시 결과, 실패 시 null

---

#### `confirmSignUp`
이메일 인증 코드를 확인합니다.

```dart
Future<bool> confirmSignUp({
  required String email,
  required String code,
})
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| email | String | O | 이메일 주소 |
| code | String | O | 6자리 인증 코드 |

**Returns:** `bool` - 인증 성공 여부

---

#### `signIn`
로그인을 수행합니다.

```dart
Future<bool> signIn({
  required String email,
  required String password,
})
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| email | String | O | 이메일 주소 |
| password | String | O | 비밀번호 |

**Returns:** `bool` - 로그인 성공 여부

---

#### `signOut`
로그아웃을 수행합니다.

```dart
Future<void> signOut()
```

---

#### `resetPassword`
비밀번호 재설정 요청을 보냅니다.

```dart
Future<bool> resetPassword({required String email})
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| email | String | O | 이메일 주소 |

**Returns:** `bool` - 요청 성공 여부

---

#### `confirmResetPassword`
비밀번호 재설정을 완료합니다.

```dart
Future<bool> confirmResetPassword({
  required String email,
  required String code,
  required String newPassword,
})
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| email | String | O | 이메일 주소 |
| code | String | O | 인증 코드 |
| newPassword | String | O | 새 비밀번호 |

**Returns:** `bool` - 변경 성공 여부

---

#### `getCurrentUser`
현재 로그인된 사용자 정보를 가져옵니다.

```dart
Future<AuthUser?> getCurrentUser()
```

**Returns:** `AuthUser?` - 사용자 정보 또는 null

---

#### `updateActivity`
사용자 활동을 업데이트합니다 (세션 타임아웃 연장).

```dart
void updateActivity()
```

---

#### `extendSession`
세션을 수동으로 연장합니다.

```dart
void extendSession()
```

---

### 1.3 Error Messages

| 에러 코드 | 메시지 |
|----------|--------|
| UserNotFoundException | 등록되지 않은 이메일입니다. |
| NotAuthorizedException | 이메일 또는 비밀번호가 올바르지 않습니다. |
| UsernameExistsException | 이미 등록된 이메일입니다. |
| CodeMismatchException | 인증 코드가 올바르지 않습니다. |
| InvalidPasswordException | 비밀번호는 8자 이상이어야 합니다. |
| LimitExceededException | 요청 횟수가 초과되었습니다. |

---

## 2. CloudDataService (클라우드 데이터 서비스)

**파일:** `lib/services/cloud_data_service.dart`

AWS AppSync GraphQL API와의 통신을 담당합니다.

### 2.1 Category Methods

#### `createCategory`
새 카테고리를 생성합니다.

```dart
Future<String?> createCategory(String name)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| name | String | O | 카테고리 이름 |

**Returns:** `String?` - 생성된 카테고리 ID

---

#### `listCategories`
모든 카테고리를 조회합니다.

```dart
Future<List<Map<String, dynamic>>> listCategories()
```

**Returns:** `List<Map<String, dynamic>>` - 카테고리 목록
```dart
[
  {
    'id': 'category-id',
    'name': '카테고리명',
    'createdAt': '2026-01-13T00:00:00Z',
    'updatedAt': '2026-01-13T00:00:00Z',
  }
]
```

---

#### `deleteCategory`
카테고리를 삭제합니다.

```dart
Future<bool> deleteCategory(String categoryId)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| categoryId | String | O | 카테고리 ID |

**Returns:** `bool` - 삭제 성공 여부

---

### 2.2 Station Methods

#### `createStation`
새 무선국을 생성합니다.

```dart
Future<String?> createStation(RadioStation station, String categoryId)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| station | RadioStation | O | 무선국 데이터 |
| categoryId | String | O | 소속 카테고리 ID |

**Returns:** `String?` - 생성된 무선국 ID

---

#### `listStationsByCategory`
특정 카테고리의 무선국을 조회합니다.

```dart
Future<List<RadioStation>> listStationsByCategory(String categoryId)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| categoryId | String | O | 카테고리 ID |

**Returns:** `List<RadioStation>` - 무선국 목록

---

#### `listAllStations`
모든 무선국을 조회합니다.

```dart
Future<List<RadioStation>> listAllStations()
```

**Returns:** `List<RadioStation>` - 전체 무선국 목록

---

#### `updateStation`
무선국 정보를 수정합니다.

```dart
Future<bool> updateStation(RadioStation station, String categoryId)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| station | RadioStation | O | 수정할 무선국 데이터 |
| categoryId | String | O | 소속 카테고리 ID |

**Returns:** `bool` - 수정 성공 여부

---

#### `deleteStation`
무선국을 삭제합니다.

```dart
Future<bool> deleteStation(String stationId)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| stationId | String | O | 무선국 ID |

**Returns:** `bool` - 삭제 성공 여부

---

### 2.3 Sync Methods

#### `syncLocalToCloud`
로컬 데이터를 클라우드에 동기화합니다.

```dart
Future<bool> syncLocalToCloud(String categoryName, List<RadioStation> stations)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| categoryName | String | O | 카테고리 이름 |
| stations | List<RadioStation> | O | 동기화할 무선국 목록 |

**Returns:** `bool` - 동기화 성공 여부

---

#### `syncCloudToLocal`
클라우드 데이터를 로컬로 가져옵니다.

```dart
Future<Map<String, List<RadioStation>>> syncCloudToLocal()
```

**Returns:** `Map<String, List<RadioStation>>` - 카테고리별 무선국 맵

---

## 3. StorageService (로컬 저장소 서비스)

**파일:** `lib/services/storage_service.dart`

Hive 기반 로컬 데이터 저장을 담당합니다.

### 3.1 Methods

#### `init`
저장소를 초기화합니다.

```dart
Future<void> init()
```

---

#### `getAllStations`
모든 무선국을 조회합니다.

```dart
List<RadioStation> getAllStations()
```

**Returns:** `List<RadioStation>` - 저장된 모든 무선국

---

#### `saveStation`
무선국을 저장합니다.

```dart
Future<void> saveStation(RadioStation station)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| station | RadioStation | O | 저장할 무선국 |

---

#### `saveStations`
여러 무선국을 일괄 저장합니다.

```dart
Future<void> saveStations(List<RadioStation> stations)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| stations | List<RadioStation> | O | 저장할 무선국 목록 |

---

#### `deleteStation`
무선국을 삭제합니다.

```dart
Future<void> deleteStation(String id)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | String | O | 무선국 ID |

---

#### `clearAllStations`
모든 무선국을 삭제합니다.

```dart
Future<void> clearAllStations()
```

---

#### `updateMemo`
무선국 메모를 수정합니다.

```dart
Future<void> updateMemo(String id, String memo)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | String | O | 무선국 ID |
| memo | String | O | 새 메모 내용 |

---

#### `updateInspectionStatus`
검사 상태를 변경합니다.

```dart
Future<void> updateInspectionStatus(String id, bool isInspected)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | String | O | 무선국 ID |
| isInspected | bool | O | 검사완료 여부 |

---

#### `updatePhotoPaths`
사진 경로를 업데이트합니다.

```dart
Future<void> updatePhotoPaths(String id, List<String> photoPaths)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | String | O | 무선국 ID |
| photoPaths | List<String> | O | 사진 경로 목록 |

---

## 4. PhotoStorageService (사진 저장소 서비스)

**파일:** `lib/services/photo_storage_service.dart`

AWS S3 기반 사진 업로드/다운로드를 담당합니다.

### 4.1 Static Methods

#### `checkStorageConfiguration`
S3 설정 상태를 확인합니다.

```dart
static Future<void> checkStorageConfiguration()
```

---

#### `uploadPhoto`
사진을 S3에 업로드합니다.

```dart
static Future<String?> uploadPhoto(
  Uint8List bytes,
  String fileName,
  String stationId,
)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| bytes | Uint8List | O | 이미지 바이트 데이터 |
| fileName | String | O | 파일명 |
| stationId | String | O | 무선국 ID |

**Returns:** `String?` - S3 키 (`s3://...`) 또는 base64 데이터 URL

**S3 경로 형식:**
```
private/{identityId}/photos/{stationId}/{timestamp}_{fileName}
```

---

#### `getPhotoUrl`
사진 URL을 가져옵니다.

```dart
static Future<String> getPhotoUrl(String photoPath)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| photoPath | String | O | 사진 경로 (S3 키 또는 URL) |

**Returns:** `String` - Presigned URL (1시간 유효) 또는 원본 URL

---

#### `deletePhoto`
사진을 삭제합니다.

```dart
static Future<void> deletePhoto(String photoPath)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| photoPath | String | O | 삭제할 사진 경로 |

---

#### `isValidPhotoUrl`
유효한 사진 URL인지 확인합니다.

```dart
static bool isValidPhotoUrl(String photoPath)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| photoPath | String | O | 확인할 경로 |

**Returns:** `bool` - 유효 여부

---

## 5. ExcelService (Excel 서비스)

**파일:** `lib/services/excel_service.dart`

Excel 파일 가져오기/내보내기를 담당합니다.

### 5.1 Methods

#### `importExcelFile`
Excel 파일을 가져옵니다.

```dart
Future<ExcelImportResult?> importExcelFile()
```

**Returns:** `ExcelImportResult?`
```dart
class ExcelImportResult {
  final String fileName;           // 파일명 (카테고리명으로 사용)
  final List<RadioStation> stations;  // 파싱된 무선국 목록
}
```

**지원 형식:** XLSX, XLS

**Excel 컬럼 매핑:**

| 컬럼 인덱스 | 필드 |
|-------------|------|
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

#### `exportToExcelWithPhotos`
Excel + 사진을 ZIP으로 내보냅니다.

```dart
// Web
Future<void> exportToExcelWithPhotosWeb(
  List<RadioStation> stations,
  String fileName,
)

// Mobile
Future<void> exportToExcelWithPhotosMobile(
  List<RadioStation> stations,
  String fileName,
)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| stations | List<RadioStation> | O | 내보낼 무선국 목록 |
| fileName | String | O | 출력 파일명 |

**출력 형식:** ZIP 파일
```
{fileName}.zip
├── {fileName}.xlsx
└── photos/
    ├── station1_photo1.jpg
    ├── station1_photo2.jpg
    └── ...
```

---

## 6. GeocodingService (지오코딩 서비스)

**파일:** `lib/services/geocoding_service.dart`

Kakao API 기반 주소-좌표 변환을 담당합니다.

### 6.1 Methods

#### `getCoordinatesFromAddress`
주소에서 좌표를 가져옵니다.

```dart
Future<Map<String, double>?> getCoordinatesFromAddress(String address)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| address | String | O | 변환할 주소 |

**Returns:** `Map<String, double>?`
```dart
{
  'latitude': 37.5665,
  'longitude': 126.9780,
}
```

---

#### `getCoordinatesFromAddresses`
여러 주소를 일괄 변환합니다.

```dart
Future<List<Map<String, double>?>> getCoordinatesFromAddresses(
  List<String> addresses,
)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| addresses | List<String> | O | 변환할 주소 목록 |

**Returns:** `List<Map<String, double>?>` - 좌표 목록 (실패 시 null)

**Rate Limiting:** 요청 간 100ms 지연

---

## 7. StationProvider (상태 관리)

**파일:** `lib/providers/station_provider.dart`

앱 전체 상태를 관리합니다.

### 7.1 Properties

| Property | Type | Description |
|----------|------|-------------|
| `stations` | `List<RadioStation>` | 전체 무선국 목록 |
| `filteredStations` | `List<RadioStation>` | 필터링된 무선국 목록 |
| `stationsByCategory` | `Map<String, List<RadioStation>>` | 카테고리별 무선국 |
| `isLoading` | `bool` | 로딩 상태 |
| `errorMessage` | `String?` | 에러 메시지 |
| `selectedStation` | `RadioStation?` | 선택된 무선국 |
| `searchQuery` | `String` | 검색어 |
| `selectedCategories` | `Set<String>` | 선택된 카테고리 |
| `loadingProgress` | `double` | 로딩 진행률 (0.0-1.0) |
| `loadingStatus` | `String` | 로딩 상태 메시지 |

### 7.2 Methods

#### `loadStations`
무선국 데이터를 로드합니다.

```dart
Future<void> loadStations({bool forceReload = false})
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| forceReload | bool | - | 강제 새로고침 여부 |

---

#### `setSearchQuery`
검색어를 설정합니다.

```dart
void setSearchQuery(String query)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| query | String | O | 검색어 |

---

#### `toggleCategory`
카테고리 선택을 토글합니다.

```dart
void toggleCategory(String category)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| category | String | O | 카테고리명 |

---

#### `selectAllCategories`
모든 카테고리를 선택합니다.

```dart
void selectAllCategories()
```

---

#### `clearCategorySelection`
카테고리 선택을 초기화합니다.

```dart
void clearCategorySelection()
```

---

#### `selectStation`
무선국을 선택합니다.

```dart
void selectStation(RadioStation station)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| station | RadioStation | O | 선택할 무선국 |

---

#### `updateInspectionStatus`
검사 상태를 변경합니다.

```dart
Future<void> updateInspectionStatus(String id, bool isInspected)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | String | O | 무선국 ID |
| isInspected | bool | O | 검사완료 여부 |

---

#### `updateMemo`
메모를 수정합니다.

```dart
Future<void> updateMemo(String id, String memo)
```

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| id | String | O | 무선국 ID |
| memo | String | O | 새 메모 내용 |

---

## 변경 이력

| 버전 | 날짜 | 변경 내용 | 작성자 |
|------|------|----------|--------|
| 1.0.0 | 2026-01-13 | 최초 작성 | Dev Team |
