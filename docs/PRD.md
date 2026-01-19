# KSA (무선국 검사 관리 시스템) - PRD

## Product Requirements Document

**버전:** 1.0.0
**최종 수정일:** 2026-01-13
**작성자:** Development Team

---

## 1. 제품 개요

### 1.1 제품명
KSA (Korea Station Administration) - 무선국 검사 관리 시스템

### 1.2 제품 설명
무선국 현장 검사 업무를 효율적으로 관리하기 위한 크로스 플랫폼 애플리케이션입니다. Excel 파일로 관리되던 무선국 데이터를 클라우드 기반으로 전환하여 실시간 동기화, 지도 기반 위치 확인, 현장 사진 관리 등의 기능을 제공합니다.

### 1.3 목표 사용자
- 무선국 검사 담당자
- 현장 검사원
- 검사 관리 감독자

### 1.4 플랫폼 지원
| 플랫폼 | 지원 여부 | 비고 |
|--------|----------|------|
| Android | O | Kakao Maps Native SDK |
| iOS | O | Kakao Maps Native SDK |
| Web | O | Kakao Maps JavaScript API |
| Windows | O | 맵 기능 제한 |
| macOS | O | 맵 기능 제한 |
| Linux | O | 맵 기능 제한 |

---

## 2. 핵심 기능

### 2.1 사용자 인증
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 회원가입 | 이메일 기반 회원가입 + 이메일 인증 | P0 |
| 로그인 | 이메일/비밀번호 인증 | P0 |
| 로그아웃 | 세션 종료 | P0 |
| 비밀번호 재설정 | 이메일 인증 기반 비밀번호 변경 | P1 |
| 세션 관리 | 2시간 비활성 시 자동 로그아웃 | P1 |

### 2.2 데이터 관리
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| Excel 가져오기 | XLSX/XLS 파일에서 무선국 데이터 import | P0 |
| Excel 내보내기 | 무선국 데이터를 Excel + 사진 ZIP으로 export | P0 |
| 클라우드 동기화 | AWS 클라우드와 실시간 데이터 동기화 | P0 |
| 로컬 저장소 | 오프라인 시 로컬 Hive DB 사용 | P1 |
| 카테고리 관리 | Excel 파일별 그룹 관리 | P1 |

### 2.3 지도 기능
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 무선국 마커 표시 | 지도에 무선국 위치 마커 표시 | P0 |
| 마커 클릭 상세정보 | 마커 클릭 시 상세정보 바텀시트 표시 | P0 |
| 주소 → 좌표 변환 | Kakao Geocoding API로 주소 기반 좌표 획득 | P0 |
| 로드뷰 | 카카오 로드뷰 연동 | P1 |
| 현재 위치 | GPS 기반 현재 위치 이동 | P1 |
| 검사상태 구분 | 검사완료(빨강)/대기(파랑) 마커 색상 구분 | P1 |

### 2.4 무선국 관리
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 무선국 목록 | 카테고리별 무선국 목록 표시 | P0 |
| 무선국 검색 | 이름/주소/호출부호 기반 검색 | P0 |
| 무선국 상세정보 | 전체 필드 상세 정보 표시 | P0 |
| 검사상태 변경 | 검사완료/대기 상태 토글 | P0 |
| 메모 작성 | 현장 메모 저장 | P1 |
| 카테고리 필터링 | 다중 카테고리 선택 필터 | P1 |

### 2.5 사진 관리
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 사진 촬영 | 카메라로 현장 사진 촬영 | P0 |
| 사진 선택 | 갤러리에서 사진 선택 | P0 |
| S3 업로드 | AWS S3에 사진 업로드 | P0 |
| 사진 보기 | 전체화면 사진 뷰어 | P1 |
| 사진 삭제 | S3 및 로컬 사진 삭제 | P1 |

---

## 3. 데이터 모델

### 3.1 무선국 (RadioStation)

| 필드명 | 타입 | 필수 | 설명 |
|--------|------|------|------|
| id | String | O | 고유 식별자 |
| stationName | String | O | ERP 국소명 |
| licenseNumber | String | - | 허가번호 |
| address | String | O | 설치장소 주소 |
| latitude | double | - | 위도 |
| longitude | double | - | 경도 |
| callSign | String | - | 호출부호 |
| frequency | String | - | 주파수 |
| stationType | String | - | 무선국 종류 |
| owner | String | - | 소유자 |
| gain | String | - | 안테나 이득 (dB) |
| antennaCount | String | - | 안테나 수량 |
| typeApprovalNumber | String | - | 형식검정번호 |
| remarks | String | - | 비고 |
| memo | String | - | 메모 |
| inspectionDate | DateTime | - | 검사일시 |
| isInspected | bool | O | 검사완료 여부 (기본: false) |
| photoPaths | List<String> | - | 사진 경로 목록 |
| categoryName | String | - | 카테고리 (Excel 파일명) |
| createdAt | DateTime | O | 생성일시 |
| updatedAt | DateTime | O | 수정일시 |

### 3.2 카테고리 (Category)

| 필드명 | 타입 | 필수 | 설명 |
|--------|------|------|------|
| id | String | O | 고유 식별자 |
| name | String | O | 카테고리명 (Excel 파일명) |
| stations | List<Station> | - | 소속 무선국 목록 |
| createdAt | DateTime | O | 생성일시 |
| updatedAt | DateTime | O | 수정일시 |

---

## 4. 사용자 흐름

### 4.1 최초 사용 흐름
```
앱 실행 → 로그인 화면 → 회원가입 → 이메일 인증 → 로그인 → 메인 화면
```

### 4.2 데이터 가져오기 흐름
```
메뉴 → Excel 가져오기 → 파일 선택 → 파싱 → 주소 좌표 변환 → 클라우드 저장 → 지도 표시
```

### 4.3 현장 검사 흐름
```
지도에서 마커 선택 → 상세정보 확인 → 로드뷰로 위치 확인 → 사진 촬영 → 메모 작성 → 검사완료 처리
```

### 4.4 데이터 내보내기 흐름
```
메뉴 → Excel 내보내기 → Excel + 사진 ZIP 생성 → 공유/저장
```

---

## 5. 비기능 요구사항

### 5.1 성능
- Excel 파일 1,000건 이상 처리 가능
- 지도 마커 1,000개 이상 동시 표시
- 사진 업로드 10MB 이하

### 5.2 보안
- AWS Cognito 기반 인증
- 사용자별 데이터 격리 (Owner-based authorization)
- S3 Private 접근 제어
- 2시간 세션 타임아웃

### 5.3 가용성
- 오프라인 모드 지원 (로컬 Hive DB)
- 클라우드 연결 실패 시 로컬 fallback

### 5.4 확장성
- 페이지네이션 (1,000건 단위)
- 카테고리 기반 데이터 분류

---

## 6. 기술 스택

### 6.1 Frontend
- **Framework:** Flutter 3.x
- **State Management:** Provider (ChangeNotifier)
- **Local Storage:** Hive
- **Maps:** Kakao Maps (Native SDK + JavaScript API)

### 6.2 Backend (AWS Amplify)
- **Authentication:** AWS Cognito
- **API:** AWS AppSync (GraphQL)
- **Storage:** AWS S3
- **Region:** ap-northeast-2 (서울)

### 6.3 외부 API
- Kakao Maps JavaScript API (Web)
- Kakao Maps Native SDK (Mobile)
- Kakao Geocoding REST API

---

## 7. 릴리스 계획

### v1.0.0 (현재)
- [x] 사용자 인증 (로그인/회원가입)
- [x] Excel 가져오기/내보내기
- [x] 지도 기반 무선국 표시
- [x] 검사상태 관리
- [x] 사진 촬영 및 S3 업로드
- [x] 클라우드 동기화

### v1.1.0 (예정)
- [ ] 오프라인 모드 강화
- [ ] 푸시 알림
- [ ] 검사 보고서 생성
- [ ] 다중 사용자 협업

### v2.0.0 (예정)
- [ ] 관리자 대시보드
- [ ] 통계 및 분석
- [ ] API 연동 확장

---

## 8. 용어 정의

| 용어 | 설명 |
|------|------|
| 무선국 | 전파법에 따라 허가된 무선 통신 시설 |
| ERP 국소명 | 전파자원관리시스템에 등록된 공식 명칭 |
| 호출부호 | 무선국을 식별하는 고유 부호 |
| 검사 | 무선국의 운용 상태 및 법적 요건 충족 여부 확인 |
| 카테고리 | Excel 파일 단위로 그룹화된 무선국 집합 |

---

## 변경 이력

| 버전 | 날짜 | 변경 내용 | 작성자 |
|------|------|----------|--------|
| 1.0.0 | 2026-01-13 | 최초 작성 | Dev Team |
