# KSA (무선국 검사 관리 시스템) - PRD

## Product Requirements Document

**버전:** 2.1.0
**최종 수정일:** 2026-04-06
**작성자:** Development Team

---

## 1. 제품 개요

### 1.1 제품명
KSA (Korea Station Administration) - 무선국 검사 관리 시스템

### 1.2 제품 설명
무선국 현장 검사 업무를 효율적으로 관리하기 위한 크로스 플랫폼 애플리케이션입니다. Excel 파일로 관리되던 무선국 데이터를 클라우드 기반으로 전환하여 실시간 동기화, 지도 기반 위치 확인, 현장 사진 관리, DS(Data Set) 대용량 업로드 및 통계 기능을 제공합니다.

### 1.3 목표 사용자
- 무선국 검사 담당자
- 현장 검사원
- 검사 관리 감독자
- 본부별 DS 데이터 관리자
- 본부별 수검 대상 관리자 (본부 담당자)
- 품질개선팀 담당자

### 1.4 플랫폼 지원
| 플랫폼 | 지원 여부 | 비고 |
|--------|----------|------|
| Web | O | 주 플랫폼 (Amplify 배포) |
| Android | O | Kakao Maps Native SDK |
| iOS | O | Kakao Maps Native SDK |
| Windows | O | 맵 기능 제한 |
| macOS | O | 맵 기능 제한 |
| Linux | O | 맵 기능 제한 |

---

## 2. 핵심 기능

### 2.1 사용자 인증 및 권한
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| SSO 로그인 | i-NET SSO 사번/비밀번호 인증 → HMAC 토큰 발급 | P0 |
| Bearer 토큰 인증 | 모든 API 호출 시 `Authorization: Bearer <token>` 사용 | P0 |
| 로그아웃 | 세션 종료 + 토큰 삭제 | P0 |
| 세션 관리 | 2시간 비활성 시 자동 로그아웃 (토큰 만료와 동일) | P1 |
| 본부별 데이터 접근 | 로그인 사용자의 본부에 해당하는 데이터만 조회 | P1 |
| 역할 기반 접근 제어 | admin/manager/member 역할별 기능 분리 | P0 |

### 2.1.1 관리자 패널 (v1.4.0 ~ v2.1.0)
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 사용자 관리 | 전체 사용자 목록 조회/검색/필터 (admin/manager) | P0 |
| 역할 변경 | 사용자 역할 변경 (admin 전용) | P0 |
| 마지막 로그인 표시 | 사용자별 마지막 로그인 일시 표시 (UTC ISO → KST 변환) | P1 |
| 휴면 계정 표시 | is_dormant 상태 배지 표시, 휴면 해제 버튼 (admin/manager) | P1 |
| 감사 로그 | 역할 변경, 데이터 삭제 등 이력 조회 | P1 |
| 자동 등록 | 로그인 시 kca-user-roles 테이블에 member로 자동 등록 | P0 |

### 2.2 데이터 관리
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| Excel 가져오기 | XLSX/XLS 파일에서 무선국 데이터 import | P0 |
| Excel 내보내기 (원본 서식 유지) | 원본 Excel 서식 유지하며 검사결과 컬럼 추가 | P0 |
| Excel + 사진 ZIP 내보내기 | Excel 파일과 사진을 ZIP으로 묶어 export | P0 |
| 클라우드 동기화 | AWS 클라우드와 실시간 데이터 동기화 | P0 |
| 원본 Excel S3 저장 | 가져온 Excel 원본을 S3에 보관 (서식 유지용) | P0 |
| 로컬 저장소 | 오프라인 시 로컬 Hive DB 사용 | P1 |
| 카테고리 관리 | Excel 파일별 그룹 관리 | P1 |

### 2.3 지도 기능
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 무선국 마커 표시 | 지도에 무선국 위치 마커 표시 | P0 |
| 마커 클릭 상세정보 | 마커 클릭 시 상세정보 바텀시트 표시 | P0 |
| 주소 → 좌표 변환 | Kakao Geocoding API로 주소 기반 좌표 획득 | P0 |
| 역지오코딩 | 좌표 → 지역명 변환 (날씨 조회용) | P0 |
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
| 설치대(철탑형태) 변경 | 설치대 유형 수정 및 변경 추적 | P0 |
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

### 2.6 AI 철탑형태 분류
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 이미지 업로드 | 카메라/갤러리에서 철탑 이미지 선택 | P0 |
| 자동 분류 | YOLOv8 모델 기반 설치형태 자동 분류 | P0 |
| 분류 결과 표시 | Top-5 분류 결과 및 신뢰도 표시 | P0 |
| 앙상블 분류 | 여러 이미지로 정확도 향상 | P1 |
| 서버 상태 확인 | AI 서버 연결 상태 실시간 확인 | P1 |

### 2.7 날씨 정보
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 현재 위치 날씨 | 지도 중심 좌표 기준 날씨 표시 | P1 |
| 날씨 상세정보 | 기온, 체감온도, 습도, 바람, 강수량 표시 | P1 |
| 자동 갱신 | 지도 이동 시 날씨 정보 자동 갱신 | P2 |

### 2.8 DS 데이터 관리 (신규)
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| DS ZIP 업로드 | 본부별 XLS 파일 ZIP 업로드 (EC2 경유 S3) | P0 |
| 서버 백그라운드 처리 | ZIP 메타데이터 파싱 → S3 보관 (xlsx 빌드 없음, ~10초) | P0 |
| 업로드 진행률 폴링 | 3초 간격 잡 상태 조회 | P0 |
| DS 데이터 현황 | 본부별 업로드 현황 + 자동갱신 대시보드 | P0 |
| DS Excel Export | on-demand xlsx 빌드 + S3 캐싱 (2회차부터 즉시) | P0 |
| DS 파일 병합 | 브라우저에서 ZIP 내 XLS 파일 병합 → xlsx | P1 |
| DS 데이터 조회 | 시트별 데이터 페이징 조회 및 검색 | P1 |
| DS 데이터 삭제 | 본부/날짜별 데이터 삭제 | P1 |

### 2.9 호출명칭 매칭 (v2.0.0)
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| Excel 업로드 | 수검 대상 Excel 업로드 → 호출명칭/통시/ZPWINA/ZPWINO 컬럼 자동 감지 | P0 |
| 필터 설정 | 컬럼별 다중 선택 필터, 필터된 행 수 미리보기 | P0 |
| 매칭 실행 | SSE 스트림 기반 실시간 진행률 → Access담당/품질개선팀/통시 컬럼 매칭 결과 Excel 다운로드 | P0 |
| 호출명칭 DB 관리 | CSV/Excel 업로드로 호출명칭 DB 구축 (관리자 전용), replace/merge 모드 | P1 |

### 2.10 설치확인서 생성 (v2.0.0)
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 국소 자동 조회 | 국소명/허가번호 입력 → DB에서 기본 정보 자동 채움 | P0 |
| 설치 상세 입력 | 안테나 수(자사/타사 구분), 설치대 유형 드롭다운, 공유/단독 구분 | P0 |
| 공동 설치 정보 | SKT/KT/LGU+ 체크박스, 공동설치자 정보 | P0 |
| 문서 생성 | PDF 또는 HWPX(한글) 형식 선택 → 다운로드 | P0 |
| 일괄 생성 | Excel 일괄 업로드 → 컬럼 자동 매핑 → ZIP 다운로드 | P1 |
| 첨부 파일 | 건설 도면, 현장 사진 다수 첨부 | P1 |

### 2.11 수검 관리 시스템 (v2.0.0 ~ v2.1.0)
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| KCA 데이터 Import | KCA Excel 업로드 → 백그라운드 파싱 → Staging 영역 저장 | P0 |
| 수검 일정 관리 | 연도/분기별 수검 일정 등록, Access담당 배정, 다중 필터링 | P0 |
| 수검 결과 기록 | 합격/불합격/대기 상태, 검사일, 메모, 철탑형태 기록, 사진 첨부 | P0 |
| 저장 ProgressDialog | 결과 저장 시 로딩→완료→오류 애니메이션 다이얼로그 표시 | P1 |
| 미배정 관리 | 미배정 수검 대상 조회 및 일괄 배정 | P0 |
| 진도율 추적 | 연도별 완료/미완료 진도 통계 | P1 |
| Staging 워크플로우 | 데이터 미리보기 → 확인(confirm) → 운영 DB 반영 | P1 |
| 데이터 Export | 필터링된 수검 데이터 XLSX 내보내기 | P1 |
| 수검 관리 버튼 권한 | member는 수검 관리 화면 이동 버튼 숨김 | P1 |

### 2.12 ERP-DS 데이터 비교 (v2.0.0)
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 데이터 비교 | ERP 유지보수 데이터 vs DS 무선시설 데이터 자동 비교 | P0 |
| 불일치 검출 | 설치형태, 일련번호 등 불일치 항목 자동 추출 | P0 |
| 비교 결과 표시 | 매칭/불일치/누락 건수 및 상세 내역 표시 | P1 |

### 2.13 본부 대상 관리 (v2.0.0)
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 본부 현황 대시보드 | 본부 전체 대상 국수, 완료 건수, 진도율 | P0 |
| 대상 목록 관리 | 검색/필터, 다중 선택 일괄 상태 변경/삭제 | P0 |
| 팀 배정 관리 | 팀별 진도 현황, 국소 팀 간 재배정 | P1 |
| Excel Import/Export | 원본 서식 유지 Export + 수정본 Import | P0 |

### 2.14 실적 관리 대시보드 (v2.1.0)
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 전국 현황 지도 | 9개 본부 진도율 색상 강조 + 라벨 카드, 외부 필터와 지도 선택 실시간 동기화 | P0 |
| 본부별 현황 테이블 | 수검국소/완료/시기조정/성능합격 등 집계 | P0 |
| 도넛 차트 | 본부별 비중 시각화 | P1 |
| 목표 대비 합격율 바 차트 | 성능(목표 98.5%)/서류(목표 85%) 분리 표시, 목표선 표시 | P0 |
| 주별 Trend 콤보 차트 | 합격건수 막대 + 합격율 꺾은선 (분기 필터: 전체/1Q/2Q/3Q/4Q) | P1 |
| Acc.담당별 소형 차트 | 9개 본부별 주별 성능/서류 추이, 클릭 시 확대 | P1 |
| 현황 리포트 | 성능/서류 달성 여부 인라인 배경 표시, Acc.담당 누적 실적 분리 표시 | P0 |
| Excel Export | 본부→월→주차 3단계 선택, 월별 실제 업로드 주차 동적 조회 | P1 |
| 결과장 업로드 | 관리자/매니저 전용, RAW DATA → DB 저장 | P0 |
| 월별 탭 | ACC 누적 + 1~12월 탭 전환 | P1 |

### 2.15 현장 수검 Map 내비게이션 (v2.1.0)
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| Tmap 연동 | `tmap://route?goalx=&goaly=&goalname=` 딥링크 → 모바일 Tmap 앱 직접 호출 | P1 |
| 카카오내비 연동 | `kakaomap://route?ep=&by=CAR` 딥링크 → 카카오내비 앱 직접 호출 | P1 |

### 2.16 휴면계정 자동 관리 (v2.1.0)
| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 자동 휴면 전환 | 매일 09:00 KST 배치 → 30일 미로그인 시 is_dormant=true | P1 |
| 휴면 예고 메일 | D-7/D-3/D-1 에 AWS SES HTML 메일 자동 발송 | P1 |
| 중복 발송 방지 | notified_d7/d3/d1 플래그로 동일 일수 중복 발송 방지 | P1 |
| 로그인 차단 | is_dormant=true 계정 로그인 시 403 반환 | P0 |
| 관리자 휴면 해제 | 관리자 화면에서 휴면 해제 버튼, POST /admin/undormant/{empno} | P1 |

### 2.17 수검 워크플로우 시스템 (v2.2.0 — Phase 1~5)

연간 수검 일정 등록부터 현장 수검 완료까지 팀 간 인계가 시스템 내에서 논스톱으로 이뤄지도록 만든 전체 흐름.
상세: [`inspection_workflow_roadmap.md`](inspection_workflow_roadmap.md)

#### 상태 머신
```
REGISTERED → PRE_CHECK → PRE_CHECK_DONE → REPORT_ISSUED → SUBMITTED → INSPECTED
                │            ↑
                └─ CHANGE_FILING → RE_CHECK ─┘  (변경개설 분기)
   └────────────────── REPORT_ISSUED 직행 (사전점검 스킵)
```

| 기능 | 설명 | 우선순위 |
|------|------|----------|
| 상태 머신 8단계 | workflow_status 컬럼 + `inspection_status_log` 전환 이력 | P0 |
| 권한 매트릭스 | admin은 모든 전환 / 그 외는 `_WF_TRANSITIONS` 정의에 따름 | P0 |
| 사전점검 의뢰 (Phase 1) | 다중 선택 + 일괄 PRE_CHECK 전환, 품개팀에 자동 알림 | P0 |
| 전산비교 회신 (Phase 1) | 결과 첨부 + 자동 PRE_CHECK_DONE, 불일치/DS누락 0 가드 | P0 |
| 변경개설 분기 (Phase 2) | change_request 등록 + A파일(신고서) xls 자동 생성 + 부분 DS 적용 후 자동 재비교 | P0 |
| 검사내역서 발급 (Phase 3) | 다중 schedule_pk 묶음 → xls 즉시 다운로드 + REPORT_ISSUED 자동 전환 (상태 무관 발급 허용) | P0 |
| 접수번호 입력 (Phase 3) | 단건/일괄 입력 + SUBMITTED 자동 전환, 발급 직후 자동 다이얼로그 + 추후 일정 화면에서도 입력 | P0 |
| 검사 결과 자동 연결 (Phase 4) | 결과 저장 시 SUBMITTED → INSPECTED 자동 전환, 합격 외엔 `needs_recheck='1'` 세팅 | P0 |
| 재점검 필요 표시 (Phase 4) | INSPECTED 셀에 "재점검" 칩 + 일정 화면에 "재점검 필요 · N" 토글 필터 (재점검 일정 자동 생성 안 함) | P1 |
| 두 status 분리 (Phase 4) | `workflow_status` vs `inspection_results.status` 분리, INSPECTED 미만은 결과 컬럼 숨김 | P0 |
| 현장수검 Map 필터 (Phase 4) | "수검가능" 토글 (기본 ON): SUBMITTED/REPORT_ISSUED/INSPECTED만 마커 표시 | P1 |
| 시스템 내 알림 (Phase 5) | notifications 테이블 + 전환 시 자동 생성 (7종) + 우상단 종 + 60초 폴링 | P1 |
| 로그인 자동 팝업 (Phase 5) | 안 읽음 > 0 시 홈 진입 직후 자동 표시, "오늘은 더이상 보지 않기" 체크박스 (SharedPreferences) | P1 |
| 역할별 대시보드 (Phase 5) | admin=전사 / manager=본부 / member=팀, 상태 8장 카드 + 재점검/SLA 지연 강조 + 일정화면 자동 점프 | P0 |
| SLA 임계점 (Phase 5) | 단계별 임계점 하드코딩 (_SLA_DAYS), 초과 건 대시보드에 강조 (자동 알림은 향후) | P2 |

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
| installationType | String | - | 설치대 (현재 값, 수정 가능) |
| originalInstallationType | String | - | 원본 설치대 (Import 시 저장, 변경 비교용) |
| memo | String | - | 메모 |
| inspectionDate | DateTime | - | 검사일시 |
| isInspected | bool | O | 검사완료 여부 (기본: false) |
| photoPaths | List<String> | - | 사진 경로 목록 (S3 키) |
| categoryName | String | - | 카테고리 (Excel 파일명) |
| createdAt | DateTime | O | 생성일시 |
| updatedAt | DateTime | O | 수정일시 |

### 3.2 카테고리 (Category)

| 필드명 | 타입 | 필수 | 설명 |
|--------|------|------|------|
| id | String | O | 고유 식별자 |
| name | String | O | 카테고리명 (Excel 파일명) |
| originalExcelKey | String | - | 원본 Excel S3 키 |
| stations | List<Station> | - | 소속 무선국 목록 |
| createdAt | DateTime | O | 생성일시 |
| updatedAt | DateTime | O | 수정일시 |

### 3.3 DS 업로드 (DsUpload)
DynamoDB Table: `kca-ds-uploads` (PK=divisionId, SK=divisionCode#importDate)

| 필드명 | 타입 | 설명 |
|--------|------|------|
| divisionId | String | 본부 ID (예: sudogwon) |
| importDate | String | SK: `{divisionCode}#{importDate}` (예: 50#20260203) |
| divisionCode | String | 지역코드 (10/20/30/40/50/55/60/70) |
| divisionName | String | 본부명 (예: 충청본부) |
| uploadedBy | String | 업로드한 사용자 이메일 |
| uploadedAt | String | 업로드 일시 (ISO 8601) |
| fileName | String | 원본 ZIP 파일명 |
| status | String | uploading / completed |
| jobId | String | 처리 잡 ID |
| storageType | String | `"s3-zip"` (ZIP 보관) / `"s3"` (xlsx 사전빌드) / 없음 (구 DynamoDB) |
| sheetStats | Map<String, int> | 시트별 행 수 (예: {"일반사항": 12000}) |
| sheetHeaders | Map<String, List<String>> | 시트별 컬럼 목록 (원본 XLS 순서) |
| fileManifest | Map<String, List> | 시트별 XLS 파일 목록 (s3-zip용 페이지네이션) |
| totalRows | int | 전체 행 수 |

### 3.4 DS 레코드 (DsRecord)
DynamoDB Table: `kca-ds-records` (PK=divisionId, SK=sheetName#importDate#divisionCode#rowIndex)

| 필드명 | 타입 | 설명 |
|--------|------|------|
| divisionId | String | 본부 ID |
| sk | String | sheetName#importDate#divisionCode#rowIndex (8자리 패딩) |
| sheetName | String | XLS 시트명 |
| importDate | String | 업로드 날짜 (YYYYMMDD) |
| divisionCode | String | 지역코드 |
| uploadedAt | String | 저장 일시 |
| data | Map<String, String> | 헤더명 → 셀 값 (비어있는 셀은 저장 안 함) |

### 3.5 DS 잡 (DsJob)
DynamoDB Table: `kca-ds-jobs` (PK=jobId)

| 필드명 | 타입 | 설명 |
|--------|------|------|
| jobId | String | UUID |
| status | String | queued / processing / completed / failed |
| stage | String | 현재 처리 단계 메시지 |
| percent | Decimal | 진행률 (0~100) |
| s3Key | String | 처리할 ZIP S3 키 |
| fileName | String | 원본 파일명 |
| uploadedBy | String | 업로더 이메일 |
| queuedAt | String | 큐 등록 일시 |
| divisionCode | String | 처리 완료 후 설정 |
| importDate | String | 처리 완료 후 설정 |
| sheetStats | Map | 처리 완료 후 설정 |
| totalRows | int | 처리 완료 후 설정 |
| error | String | 실패 시 오류 메시지 |

### 3.6 DS 본부 코드 매핑

| divisionCode | divisionId | 본부명 |
|-------------|-----------|--------|
| 10 | sudogwon | 수도권 |
| 20 | gyeongnam | 경남본부 |
| 30, 70 | seobu | 서부본부 |
| 40 | gangwon | 강원본부 |
| 50, 55 | chungcheong | 충청본부 |
| 60 | gyeongbuk | 경북본부 |

### 3.7 철탑 분류 결과 (TowerClassification)

| 필드명 | 타입 | 필수 | 설명 |
|--------|------|------|------|
| id | String | O | 고유 식별자 |
| imageKey | String | O | S3 이미지 키 |
| imageName | String | O | 이미지 파일명 |
| className | String | O | 분류 클래스 (영문) |
| classNameKr | String | O | 분류 클래스 (한글) |
| confidence | Float | O | 신뢰도 (0.0~1.0) |
| isConfident | Boolean | O | 임계값 이상 여부 |
| top5Predictions | String | - | Top-5 분류 결과 (JSON) |
| ensembleMethod | String | - | 앙상블 방식 (mean/max/vote) |
| processingTimeMs | Float | - | 처리 시간 (ms) |

### 3.8 사용자 역할 (AppUserProfile)
DynamoDB Table: `kca-user-roles` (PK=user_id)

| 필드명 | 타입 | 설명 |
|--------|------|------|
| user_id | String | 사번 (PK) |
| role | String | admin / manager / member |
| last_login | String | 마지막 로그인 UTC ISO 8601 |
| is_dormant | bool | 휴면 여부 (30일 미로그인 시 true) |
| notified_d7/d3/d1 | bool | 예고 메일 발송 플래그 |

### 3.9 수검 스케줄 (InspectionSchedule)

| 필드명 | 타입 | 설명 |
|--------|------|------|
| pk | String | `year#허가번호` — 모든 흐름의 단일 키 |
| year | String | 수검 연도 |
| 허가번호 | String | 무선국 허가번호 |
| 호출명칭 | String | 호출명칭 |
| 분기 | String | 수검 분기 |
| skt본부 | String | SKT 본부 |
| access담당 | String | Access 담당자 |
| 품질개선팀 | String | 품질개선팀 담당 |
| 수검예정주차 | String | 수검 주차 |
| 검사관 | String | 검사관 |
| 조 | String | 조 (1조/2조 등) |
| **workflow_status** | String | Phase 1: 워크플로우 상태 (REGISTERED ~ INSPECTED) |
| status_updated_at/by | String | Phase 1: 상태 변경 시각/주체 (SLA 산정 기준) |
| pre_check_result | TEXT | Phase 1: 전산비교 결과 (JSON) |
| **report_issued_at/by** | String | Phase 3: 검사내역서 발급 시각/주체 |
| **submission_no, submitted_at** | String | Phase 3: 전파관리소 접수번호/일시 |

### 3.9.1 검사 결과 (InspectionResult)
SQLite Table: `inspection_results`

| 필드명 | 타입 | 설명 |
|--------|------|------|
| pk | String | `year#허가번호` (= inspection_schedules.pk) |
| status | String | 검사 결과 (합격/불합격/부적합) — INSPECTED 단계부터만 화면에 표시 |
| 검사일 | String | 입회자가 검사한 날 |
| 메모, 철탑형태, 사진S3키, 입력자, 입력일시 | — | 기본 메타 |
| **schedule_pk** | String | Phase 4: 일정과 명시적 연결 (백필로 자기 자신 복사) |
| **needs_recheck** | String | Phase 4: '1' = 불합격/부적합 → 혁신팀이 수동으로 재점검 일정 등록 |

### 3.9.2 상태 전환 이력 (InspectionStatusLog)
SQLite Table: `inspection_status_log`
- id, schedule_pk, from_status, to_status, changed_by, changed_at, memo

### 3.9.3 변경개설 요청 (ChangeRequest)
SQLite Table: `change_request`
- field ∈ {일련번호, 형식검정번호, 설치형태, 설치장소}
- status: REQUESTED → FILED → APPLIED → VERIFIED
- 부분 DS 업로드 시 자동 재비교로 VERIFIED 처리

### 3.9.4 알림 (Notification)
SQLite Table: `notifications` (Phase 5)
- user_id (수신자 사번), schedule_pk, type, message, read_at, created_at, meta (JSON)
- type: PRE_CHECK_REQUESTED / PRE_CHECK_REPLIED / CHANGE_REQUESTED / CHANGE_FILED / RE_CHECK_DONE / REPORT_ISSUED / SUBMITTED / INSPECTED / SLA_OVERDUE
- 워크플로우 전환 시 `_wf_record_log_sync` 내부에서 자동 생성

### 3.10 실적 결과장 (InspectionResultsRaw)
SQLite Table: `inspection_results_raw`

| 필드명 | 타입 | 설명 |
|--------|------|------|
| year | int | 실적 연도 |
| region | String | 본부 (강남/강북/인천 등) |
| 주차별 | String | 주차 (예: 1월1주) |
| 월 | String | 월 (예: 1월) |
| 허가번호 | String | 무선국 허가번호 |
| 통합시설코드 | String | 통합시설코드 |
| 합불여부 | String | 합격/불합격 |
| 성능서류 | String | 성능/서류 구분 |
| 장비타입 | String | 원본 장비타입 |
| 장비타입간소화 | String | 5단계 fallback 간소화 타입 |

---

## 4. Excel Export 상세 스펙

### 4.1 무선국 원본 서식 유지 Export
- 가져온 Excel 원본 파일의 서식, 스타일, 병합 셀 등을 유지
- 새 컬럼 3개 추가: 설치대(수정후), 수검여부, 특이사항
- 새 컬럼은 마지막 컬럼의 스타일을 상속

### 4.2 스테이션 매칭 방식
매칭 우선순위:
1. **허가번호**: 가장 고유한 식별자
2. **국소명 + 호출명칭**: 같은 국소명이어도 호출명칭으로 구분
3. **국소명 + 주소**: fallback 매칭

### 4.3 DS Excel Export 서식
- **글꼴**: Arial 10pt
- **정렬**: 가운데 정렬 (수평/수직)
- **헤더 행**: 볼드 + 배경색 #BFBFBF
- **테두리**: 얇은 테두리 (모든 셀)
- **열 너비**: 20 (고정)

### 4.4 컬럼 너비 자동 조절 (무선국 Export)
- 한글 문자: 2 단위
- ASCII 문자: 1 단위
- 셀 패딩: +2 단위

---

## 5. DS 데이터 처리 흐름

### 5.1 업로드 흐름 (Upload-Zero-Build)
```
브라우저
  → POST /ds/upload-raw (ZIP, 8MB 청크)
  → EC2 스트리밍 → S3 ds-raw/temp/
  → POST /ds/enqueue → jobId
  → GET /ds/job/{jobId} 폴링 (3초 간격)

백그라운드 워커 (단일 FIFO) — ~10초
  → S3 ZIP 다운로드
  → 메타데이터만 파싱 (행수 + 헤더 추출, 데이터 행 읽기 0회)
  → ZIP을 S3 영구 경로로 복사 (ds-raw/{divisionId}/{code}_{date}.zip)
  → storageType="s3-zip" + fileManifest 저장
  → xlsx 빌드 없음! (DynamoDB 쓰기 0회, openpyxl 0회)
```

### 5.2 데이터 조회 흐름 (트리플 라우팅)
```
GET /ds/data
  1. storageType="s3-zip" → S3 ZIP 다운로드 (캐시) → xlrd로 XLS 직접 읽기
  2. storageType="s3"     → S3 xlsx 다운로드 (캐시) → openpyxl 읽기
  3. storageType 없음      → DynamoDB 쿼리 (구버전 fallback)
```

### 5.3 Export 흐름
```
1. S3 ds-exports/ xlsx 존재 확인
   → 존재: presign URL → 브라우저 직접 다운로드 (즉시)

2. storageType="s3-zip": 없으면 on-demand 빌드
   → S3 ZIP 다운로드 → xlrd + openpyxl xlsx 빌드 → StreamingResponse
   → 비동기로 S3 저장 (다음 Export는 1번 경로, 즉시)

3. storageType 없음: DynamoDB fallback
   → DynamoDB 조회 → openpyxl xlsx 빌드 → StreamingResponse
```

### 5.3 DS 파일 분류 규칙
| 조건 | 분류 |
|------|------|
| 파일명에 `(100)` 포함 | skipped (일반사항(검사전) 시트) |
| 파일명에 `특수` 또는 `spt` 포함 | spt |
| 파일명에 `(\d+)` 패턴 2개 이상 | numbered |
| 그 외 | base |

처리 순서: base → numbered (번호순) → spt

---

## 6. 사용자 흐름

### 6.1 최초 사용 흐름
```
앱 실행 → 로그인 화면 → 회원가입 → 이메일 인증 → 로그인 → 메인 화면
```

### 6.2 데이터 가져오기 흐름
```
메뉴 → Excel 가져오기 → 파일 선택 → 파싱 → 주소 좌표 변환 → 클라우드 저장 → 원본 Excel S3 업로드 → 지도 표시
```

### 6.3 현장 검사 흐름
```
지도에서 마커 선택 → 상세정보 확인 → 로드뷰로 위치 확인 → 사진 촬영 → 메모 작성 → 검사완료 처리
```

### 6.4 DS 업로드 흐름
```
DS 데이터 관리 → ZIP 업로드 버튼 → 파일 선택
→ EC2 업로드 진행률 표시
→ 서버 처리 진행률 폴링 (XLS 파싱 → DB 저장 → xlsx 생성)
→ 완료 후 대시보드 자동 갱신
```

### 6.5 DS Export 흐름
```
DS 데이터 관리 → 업로드 카드 → Excel Export 버튼
→ S3 xlsx 존재 확인 → 있으면 즉시 다운로드
→ 없으면 서버사이드 빌드 → 다운로드 (다음부터 즉시 다운로드)
```

### 6.6 호출명칭 매칭 흐름
```
호출명칭 매칭 → Step 1: Excel 업로드 → 컬럼 자동 감지
→ Step 2: 필터 설정 (컬럼별 다중 선택)
→ Step 3: 매칭 실행 (SSE 실시간 진행률)
→ 결과 Excel 다운로드
```

### 6.7 설치확인서 생성 흐름
```
설치확인서 → 개별: 국소 조회 → 정보 입력 → PDF/HWPX 생성 다운로드
         → 일괄: Excel 업로드 → 사진 ZIP 업로드 → 일괄 생성 → ZIP 다운로드
```

### 6.8 수검 관리 흐름
```
수검 관리 → KCA Excel Import → Staging 미리보기 → Confirm → 운영 DB
→ 일정 등록/배정 → 현장 수검 → 결과 기록 → 진도율 확인
→ 필요 시 XLSX Export
```

### 6.9 현장 수검 내비게이션 흐름
```
현장 수검 Map → 국소 선택 → 상세정보 확인
→ Tmap 버튼: tmap:// 딥링크 → 모바일 Tmap 앱 실행 → 자동 경로 안내
→ 카카오내비 버튼: kakaomap:// 딥링크 → 카카오내비 앱 실행 → 자동 경로 안내
```

### 6.10 실적 관리 Excel Export 흐름
```
실적 관리 → Excel Export 버튼
→ 다이얼로그: 본부 선택 → 월 선택 (→ 서버에서 해당 월/본부 실제 주차 조회) → 주차 선택
→ ProgressDialog 표시 → POST /inspection-results/export-xlsx
→ 다운로드 완료
```

### 6.11 휴면계정 관리 흐름
```
[자동] 매일 09:00 KST 배치 실행
  → last_login 기준 D-7/D-3/D-1: SES 예고 메일 발송
  → D+0 (30일 초과): is_dormant=true → 이후 로그인 시 403 반환

[관리자 수동] 사용자 관리 화면 → 휴면 배지 확인 → 휴면 해제 버튼 클릭
  → POST /admin/undormant/{empno} → is_dormant=false → 즉시 로그인 가능
```

---

## 7. 비기능 요구사항

### 7.1 성능
- Excel 파일 1,000건 이상 처리 가능
- 지도 마커 1,000개 이상 동시 표시
- 사진 업로드 10MB 이하
- AI 분류 응답 시간 2초 이내
- DS 업로드 ZIP 최대 200MB (EC2 8MB 청크 스트리밍)
- DS 업로드 처리: ~10초 (메타데이터만 파싱, xlsx 빌드 없음)
- DS Export: S3 캐시 시 즉시, 최초 빌드 시 수분 소요 (자동 S3 캐싱)

### 7.2 보안
- HMAC-SHA256 토큰 인증 (Bearer token, 2시간 만료)
- i-NET SSO 연동 (사번/비밀번호)
- 역할 기반 접근 제어 (admin/manager/member)
- Rate Limiting: 로그인 5회/60초, 예측 10회/60초, 업로드 3회/60초 등
- 업로드 크기 제한: 사진 10MB, Excel 50MB, DS ZIP 200MB
- S3 경로 검증: 경로 탐색 공격 차단 (prefix 화이트리스트)
- CORS 제한: 허용 도메인만 접근 (환경변수 설정)
- 에러 메시지 보안: 서버 내부 오류 시 상세 정보 미노출
- API 키 빌드 타임 주입: dart-define으로 소스코드 노출 방지
- 사용자별 데이터 격리 (Owner-based authorization)
- S3 Private 접근 제어
- API Gateway HTTPS 프록시 (AI 서버)
- 감사 로그: 역할 변경, 데이터 삭제 등 이력 기록
- 휴면계정 로그인 차단: is_dormant=true 시 403 반환
- 휴면 배치: 매일 09:00 KST 실행, SES 예고 메일 3회 (D-7/D-3/D-1) + D0 전환

### 7.3 가용성
- 오프라인 모드 지원 (로컬 Hive DB)
- 클라우드 연결 실패 시 로컬 fallback
- AI 서버 상태 실시간 확인
- DS 잡 워커: 서버 재시작 시 processing → queued 자동 복구

### 7.4 확장성
- 페이지네이션 (1,000건 단위)
- 카테고리 기반 데이터 분류
- DS: 본부별 독립 데이터 파티션 (DynamoDB PK=divisionId)

### 7.5 AWS 비용 최적화
- DynamoDB 쿼리 시 ProjectionExpression으로 필요 속성만 조회
- Scan 대신 Query 우선 사용; 집계만 필요할 때 Select='COUNT'
- S3 xlsx 캐싱으로 반복 Export 시 DynamoDB 읽기 비용 절감
- EC2 OOM 방지: 잡 워커 단일 FIFO, write-only xlsx, 배치 25개
- Upload-Zero-Build: 업로드 시 DynamoDB WCU 0, xlsx 빌드 0 → 비용 극소

---

## 8. 기술 스택

### 8.1 Frontend
- **Framework:** Flutter 3.x (Web 주 플랫폼)
- **State Management:** Provider (ChangeNotifier)
- **Local Storage:** Hive
- **Maps:** Kakao Maps (Native SDK + JavaScript API)
- **Deploy:** AWS Amplify (Web) / S3 sync (deploy.ps1)

### 8.2 Backend - 무선국 관리 (AWS Amplify)
- **Authentication:** AWS Cognito
- **API:** AWS AppSync (GraphQL)
- **Storage:** AWS S3 (ksa-photos-bucket)
- **Region:** ap-northeast-2 (서울)

### 8.3 Backend - AI 분류 (메인 백엔드 EC2 통합)
- **Framework:** FastAPI + Uvicorn (`routers/predict.py`)
- **Model:** YOLOv8n-cls (철탑형태 분류, `best.pt` lazy load)
- **Endpoint:** https://api-sko-kca.skons.net (메인 백엔드와 동일, 인증 필수)
- **변경(2026-06):** 옛 별도 API Gateway(`c3jictzagh…`)는 폐기 → 메인 백엔드 predict 라우터로 일원화

### 8.4 Backend - 통합 API 서버 (EC2 #2)
- **Framework:** FastAPI + Uvicorn
- **Service:** systemd (kca-api)
- **Endpoint:** https://api-sko-kca.skons.net
- **Storage:** AWS S3 (sko-kca-s3), DynamoDB, SQLite (inspection.db, ds_detail.db)
- **의존성:** xlrd (XLS 파싱), openpyxl (xlsx 생성), psutil (메모리 모니터링)
- **API 범위:** DS 데이터, 호출명칭 매칭, 설치확인서 생성, 수검 관리, ERP-DS 비교

### 8.5 외부 API
- Kakao Maps JavaScript API (Web)
- Kakao Maps Native SDK (Mobile)
- Kakao Geocoding REST API
- 기상청 단기예보 API (날씨)

---

## 9. 릴리스 계획

### v1.0.0
- [x] 사용자 인증 (로그인/회원가입)
- [x] Excel 가져오기/내보내기
- [x] 지도 기반 무선국 표시
- [x] 검사상태 관리
- [x] 사진 촬영 및 S3 업로드
- [x] 클라우드 동기화

### v1.1.0
- [x] AI 철탑형태 분류 기능
- [x] FastAPI 서버 (EC2 배포)
- [x] API Gateway HTTPS 프록시
- [x] 홈 화면 메뉴 시스템

### v1.2.0
- [x] 원본 Excel 서식 유지 Export
- [x] 설치대(수정후) 컬럼 추가
- [x] 원본 Excel S3 저장/관리
- [x] 국소명 기반 스테이션 매칭 개선 (허가번호/호출명칭)
- [x] 날씨 정보 표시 (기상청 API)
- [x] 역지오코딩 (좌표→지역명)
- [x] Export 컬럼 너비 자동 조절

### v1.3.0
- [x] DS 파일 병합 (브라우저 ZIP + SheetJS + JSZip)
- [x] DS 데이터 업로드 (EC2 proxy → S3 → 백그라운드 워커)
- [x] DS 데이터 현황 대시보드
- [x] DS Excel Export (서버사이드 xlsx 빌드 + S3 캐싱)
- [x] DS 잡 큐 시스템 (DynamoDB + 싱글 워커)
- [x] 본부별 DS 데이터 접근 필터링
- [x] sheetHeaders 저장으로 컬럼 순서 보존

### v1.3.1
- [x] Upload-Zero-Build: 업로드 시 xlsx 빌드 완전 제거 (30분 → ~10초)
- [x] storageType 기반 트리플 라우팅 (s3-zip / s3 / DynamoDB fallback)
- [x] ZIP 원본 S3 보관 + fileManifest 메타데이터 저장
- [x] 데이터 조회: ZIP 내 XLS에서 xlrd 직접 읽기 (xlsx 불필요)
- [x] Export: on-demand xlsx 빌드 + S3 자동 캐싱
- [x] 대시보드 자동갱신 (uploading 상태 시 10초 주기)
- [x] 고스트 uploads 레코드 자동 정리
- [x] stuck job 10분 주기 자동 복구
- [x] 컬럼 정합성 수정 (빈 헤더 건너뛰기 + 실제 컬럼 인덱스 보존)

### v1.4.0
- [x] HMAC-SHA256 토큰 인증 (i-NET SSO + Bearer 토큰)
- [x] 관리자 패널 (사용자 관리, 역할 변경, 감사 로그)
- [x] kca-user-roles 테이블 분리 (공유 Users 테이블 보호)
- [x] Rate Limiting (로그인, 예측, 업로드 등)
- [x] 업로드 크기 제한 (10MB/50MB/200MB)
- [x] S3 경로 검증 (경로 탐색 공격 차단)
- [x] CORS 제한 (환경변수 기반 허용 도메인)
- [x] 에러 메시지 내부정보 차단
- [x] API 키 dart-define 분리 (소스코드 노출 방지)
- [x] X-User-Id 폴백 제거 (Bearer 토큰 전용)
- [x] Amplify 자동 빌드 (amplify.yml + 환경변수)

### v2.0.0
- [x] 호출명칭 매칭 시스템 (3-Step: 업로드→필터→매칭, SSE 스트리밍)
- [x] 설치확인서 생성 (개별/일괄, PDF/HWPX, 사진 첨부)
- [x] 수검 관리 시스템 (KCA Import → Staging → 일정 → 결과 → 진도율)
- [x] ERP-DS 데이터 비교 (설치형태/일련번호 불일치 검출)
- [x] 본부 대상 관리 (대시보드, 팀 배정, Excel Import/Export)
- [x] 전국 현황 지도 대시보드 (9개 본부 진도율 시각화)

### v2.1.0 (현재)
- [x] 실적 관리 대시보드 고도화 (전국 지도 + 본부별 현황 + 차트 + 현황 리포트)
- [x] 실적 Excel Export 3단계 (본부→월→주차, 동적 주차 조회)
- [x] 현황 리포트 성능/서류 분리 표시 + 인라인 배경 범위 조정
- [x] 전국 지도 외부 필터 동기화 (DashboardScreen.selectedRegion prop)
- [x] 지도 클릭 즉시 강조 (ValueKey 개선으로 타이밍 버그 수정)
- [x] 현장 수검 내비게이션 딥링크 (tmap:// / kakaomap://)
- [x] 사용자 관리 — 마지막 로그인 일시 표시
- [x] 사용자 관리 — 휴면계정 배지 + 관리자 휴면 해제 버튼
- [x] 휴면계정 자동 전환 배치 (매일 09:00 KST, D-7/D-3/D-1 SES 예고 메일)
- [x] 테스트 계정 전체 조회 / 실계정 팀 AND 조건 분리
- [x] 수검 결과 저장 ProgressDialog 적용
- [x] 수검 관리 화면 버튼 member 숨김
- [x] 커뮤니티 게시판 UI 개선 (글쓰기 위치, 텍스트 변경)
- [ ] DS 파일 활용 장비 일련번호 매칭 (개발 예정)
- [ ] DS 파일 활용 철탑형태 매칭 (개발 예정)

---

## 10. 용어 정의

| 용어 | 설명 |
|------|------|
| 무선국 | 전파법에 따라 허가된 무선 통신 시설 |
| ERP 국소명 | 전파자원관리시스템에 등록된 공식 명칭 |
| 호출부호 | 무선국을 식별하는 고유 부호 |
| 검사 | 무선국의 운용 상태 및 법적 요건 충족 여부 확인 |
| 카테고리 | Excel 파일 단위로 그룹화된 무선국 집합 |
| 설치대 | 안테나 설치 형태 (철탑, 강관주, 옥내 등) |
| DS | Data Set — 본부별 무선국 검사 원시 데이터 (XLS 파일 묶음) |
| divisionId | DS 본부 식별자 (sudogwon, gangwon, gyeongnam 등) |
| divisionCode | XLS 파일명 기반 지역코드 (10, 20, 30, 40, 50, 55, 60, 70) |
| importDate | DS 업로드 기준 날짜 (YYYYMMDD 형식) |
| sheetHeaders | 업로드 시 저장된 원본 XLS 컬럼 순서 (Export 시 정확도 보장) |
| access담당 | 본부별 Access 담당 조직 (예: 경북Access담당) |
| 품질개선팀 | 팀 단위 품질 담당 조직 (예: 강남품질개선팀) |
| is_dormant | 휴면 계정 여부 — 30일 미로그인 시 true, 로그인 시 403 |
| 주차별 | 실적 결과장의 주차 구분 (예: 1월1주, 2월3주) |
| 실적 관리 | 구 '수검 현황' — 본부별 수검 실적 대시보드 및 결과장 관리 화면 |

---

## 변경 이력

| 버전 | 날짜 | 변경 내용 | 작성자 |
|------|------|----------|--------|
| 1.0.0 | 2026-01-13 | 최초 작성 | Dev Team |
| 1.1.0 | 2026-01-22 | AI 철탑형태 분류 기능 추가, EC2/API Gateway 배포 | Dev Team |
| 1.2.0 | 2026-01-27 | 원본 서식 유지 Export, 설치대 추적, 날씨 정보, 매칭 개선 | Dev Team |
| 1.3.0 | 2026-02-26 | DS 데이터 관리 전체 추가 (업로드/파싱/저장/Export/대시보드), sheetHeaders 설계, DS API 서버 분리 | Dev Team |
| 1.3.1 | 2026-03-03 | Upload-Zero-Build (30분→10초), 트리플 라우팅, 자동갱신, 고스트 레코드 정리, 컬럼 정합성 수정 | Dev Team |
| 1.4.0 | 2026-03-04 | 보안 강화: HMAC 토큰 인증, 관리자 패널, Rate Limiting, S3 경로 검증, CORS 제한, API 키 분리, 에러 보안 | Dev Team |
| 2.0.0 | 2026-03-23 | 호출명칭 매칭, 설치확인서 생성, 수검 관리 시스템, ERP-DS 데이터 비교, 본부 대상 관리, 전국 현황 대시보드 추가 | Dev Team |
| 2.1.0 | 2026-04-06 | 실적 관리 대시보드 고도화 (차트/리포트/지도 동기화), Excel Export 3단계, 내비 딥링크, 휴면계정 배치, 마지막 로그인/휴면 표시, 테스트계정 전체조회 분리, ProgressDialog, 각종 버그 수정 | Dev Team |
| 2.2.0 | 2026-05-12 | 수검 워크플로우 시스템 Phase 1~5 완료: 상태 머신 8단계 + 변경개설 분기 + 검사내역서 발급/접수번호 트래킹 + 결과 자동 연결 + 재점검 플래그 + 시스템 내 알림 + 역할별 대시보드 + SLA 강조 + 로그인 자동 팝업 | Dev Team |
