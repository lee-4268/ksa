# KSA - 무선국 검사 관리 시스템

무선국 현장 검사 업무를 효율적으로 관리하기 위한 크로스 플랫폼 애플리케이션입니다.

## 주요 기능

- **Excel 데이터 관리** - XLSX/XLS 파일 가져오기/내보내기
- **지도 기반 위치 확인** - 카카오맵을 통한 무선국 위치 표시
- **현장 검사 관리** - 검사 상태 변경, 메모 작성, 사진 촬영
- **클라우드 동기화** - AWS 기반 실시간 데이터 동기화
- **사용자 인증** - AWS Cognito 기반 회원가입/로그인
- **AI 철탑형태 분류** - YOLOv8 기반 철탑/안테나 설치형태 자동 분류

## 스크린샷

| 지도 화면 | 상세 정보 | 카테고리 필터 |
|----------|----------|--------------|
| 마커 표시 | 바텀시트 | 사이드 드로어 |

## 기술 스택

### Frontend
- **Framework:** Flutter 3.x
- **State Management:** Provider
- **Local Storage:** Hive
- **Maps:** Kakao Maps SDK

### Backend (AWS Amplify)
- **Authentication:** AWS Cognito
- **API:** AWS AppSync (GraphQL)
- **Storage:** AWS S3
- **Region:** ap-northeast-2 (Seoul)

### AI 서버 (AWS EC2)
- **Framework:** FastAPI + Uvicorn
- **Model:** YOLOv8n-cls (철탑형태 분류)
- **Proxy:** AWS API Gateway (HTTPS)
- **Instance:** c7i-flex.large (Ubuntu 22.04)

## 시작하기

### 사전 요구사항
- Flutter SDK 3.10.4+
- Dart SDK 3.0+
- AWS Amplify CLI (선택)

### 설치

1. **저장소 클론**
```bash
git clone https://github.com/your-repo/ksa.git
cd ksa
```

2. **의존성 설치**
```bash
flutter pub get
```

3. **Hive 어댑터 생성**
```bash
flutter pub run build_runner build
```

4. **실행**
```bash
# Web
flutter run -d chrome

# Android
flutter run -d android

# iOS
flutter run -d ios
```

### 빌드

```bash
# Web 빌드
flutter build web

# Android APK
flutter build apk

# iOS
flutter build ios
```

## 프로젝트 구조

```
lib/
├── main.dart                    # 앱 진입점
├── amplifyconfiguration.dart    # AWS Amplify 설정
├── config/
│   └── api_keys.dart            # API 키 설정
├── models/
│   └── radio_station.dart       # 무선국 데이터 모델
├── providers/
│   └── station_provider.dart    # 상태 관리
├── services/
│   ├── auth_service.dart        # 인증 서비스
│   ├── cloud_data_service.dart  # GraphQL API
│   ├── storage_service.dart     # 로컬 저장소
│   ├── photo_storage_service.dart # S3 사진 관리
│   ├── excel_service.dart       # Excel 처리
│   ├── geocoding_service.dart   # 주소→좌표 변환
│   └── tower_classification_service.dart  # AI 철탑분류 서비스
├── screens/
│   ├── login_screen.dart        # 로그인 화면
│   ├── register_screen.dart     # 회원가입 화면
│   ├── home_screen.dart         # 홈 화면 (메뉴 선택)
│   ├── map_screen.dart          # 지도 화면
│   ├── roadview_screen.dart     # 로드뷰 화면
│   └── tower_classification_screen.dart  # 철탑형태 분류 화면
└── widgets/
    ├── station_detail_sheet.dart    # 상세정보 바텀시트
    ├── station_list_drawer.dart     # 무선국 목록 드로어
    └── ...

yolov8/
├── api/
│   └── main.py                  # FastAPI 서버
├── configs/
│   ├── dataset.yaml             # 데이터셋 설정
│   └── train_config.yaml        # 학습 설정
├── data/                        # 학습 데이터
├── runs/                        # 학습 결과 및 모델
├── train.py                     # 학습 스크립트
├── predict.py                   # 추론 스크립트
└── README.md
```

## 환경 설정

### Kakao API 키
`lib/config/api_keys.dart` 파일에서 설정:
```dart
class ApiKeys {
  static const String kakaoJavaScriptKey = 'your-javascript-key';
  static const String kakaoRestApiKey = 'your-rest-api-key';
  static const String kakaoNativeAppKey = 'your-native-app-key';
}
```

### AWS Amplify
`lib/amplifyconfiguration.dart` 파일에 AWS 설정이 포함되어 있습니다.

Amplify 백엔드 수정 후:
```bash
amplify push
# 또는
.\amplify-push.ps1  # 자동 설정 수정 포함
```

## 주요 화면

### 1. 로그인/회원가입
- 이메일 기반 회원가입
- 이메일 인증 코드 확인
- 비밀번호 재설정

### 2. 지도 화면
- 무선국 마커 표시 (검사완료: 빨강, 대기: 파랑)
- 마커 클릭 시 상세정보 표시
- 현재 위치 이동
- 로드뷰 연동

### 3. 무선국 목록
- 카테고리별 필터링
- 검색 기능
- 검사 상태 변경

### 4. 상세정보 화면
- 무선국 전체 정보 표시
- 메모 작성/수정
- 사진 촬영/업로드
- 검사완료 처리

### 5. 철탑형태 분류 화면
- AI 기반 설치형태 자동 분류
- 이미지 업로드 (카메라/갤러리)
- 9가지 철탑 유형 분류
- Top-5 분류 결과 및 신뢰도 표시

## 시스템 아키텍처

```
┌─────────────────────────────────────────────────────────────────┐
│                         AWS Cloud                               │
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │   Amplify    │    │ API Gateway  │    │   EC2 Instance   │  │
│  │ (Flutter Web)│    │   (HTTPS)    │───►│  FastAPI Server  │  │
│  │              │    │              │    │  + YOLOv8 Model  │  │
│  └──────┬───────┘    └──────────────┘    └──────────────────┘  │
│         │                                                       │
│         ▼                                                       │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │   Cognito    │    │   AppSync    │    │       S3         │  │
│  │    (Auth)    │    │  (GraphQL)   │    │    (Storage)     │  │
│  └──────────────┘    └──────────────┘    └──────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## API 문서

- [PRD (제품 요구사항 문서)](docs/PRD.md)
- [Frontend API 명세서](docs/FE_API_SPEC.md)
- [Backend API 명세서](docs/BE_API_SPEC.md)
- [YOLOv8 모델 문서](yolov8/README.md)

## 데이터 흐름

```
Excel 파일 → 파싱 → 주소 좌표 변환 → 클라우드 저장 → 지도 표시
                                        ↓
                                   로컬 캐시 (Hive)
```

## 오프라인 지원

- 로컬 Hive 데이터베이스에 데이터 캐시
- 클라우드 연결 실패 시 로컬 데이터 사용
- 연결 복구 시 자동 동기화

## 보안

- AWS Cognito 기반 사용자 인증
- Owner-based 데이터 격리 (사용자별 데이터 분리)
- S3 Private 접근 제어
- 2시간 세션 타임아웃

## 문제 해결

### Excel 가져오기 오류
- 지원 형식: XLSX, XLS
- 첫 번째 행은 헤더로 인식됨
- 빈 행은 자동 스킵

### 지도가 표시되지 않음
- Kakao API 키 확인
- 웹: `web/index.html`에 JavaScript SDK 로드 확인
- 모바일: `AndroidManifest.xml`, `Info.plist` 설정 확인

### 사진 업로드 실패
- S3 버킷 설정 확인
- Cognito Identity Pool 권한 확인
- 네트워크 연결 상태 확인

## 라이선스

This project is proprietary software.

## 기여

이 프로젝트는 내부용 소프트웨어입니다.

## 연락처

- 개발팀: dev@example.com

---

**버전:** 1.1.0
**최종 수정일:** 2026-01-22
