# Architecture

## 기술 스택

| 계층 | 기술 |
|------|------|
| 프론트엔드 | Flutter (Dart 3.10+), Provider 패턴 |
| 백엔드 | FastAPI (Python), Uvicorn, systemd |
| DB | SQLite (inspection.db), DynamoDB (사용자/역할/DS) |
| 스토리지 | AWS S3 (sko-kca-s3) |
| AI | YOLOv8n-cls (철탑 분류), AWS Lambda |
| 배포 | Amplify (프론트), EC2 (백엔드) |

## 디렉토리 구조

```
lib/
├── config/          # API 키, 환경 설정
├── models/          # 데이터 모델 (RadioStation + Hive)
├── providers/       # StationProvider (ChangeNotifier)
├── services/        # 31개 서비스 (비즈니스 로직)
├── screens/         # 28개 화면
│   └── admin/       # 관리자 전용 화면 (3개)
└── widgets/         # 공통 위젯 (지도, 프로그레스 다이얼로그 등)

yolov8/api/
└── main.py          # FastAPI 백엔드 (120+ 엔드포인트, 단일 파일)
```

## DB 스키마 (SQLite: inspection.db)

### inspection_targets — 수검 대상
```sql
year, sheet, 허가번호, 호출명칭, 설치장소, 도로명주소,
skt본부, access담당, 품질개선팀, 위도, 경도, ...
```

### inspection_schedules — 수검 일정
```sql
pk (허가번호+year), year, 허가번호, access담당, 품질개선팀,
수검예정주차, 검사종류(정기/시기조정), ...
```

### inspection_results — 현장 검사 결과
```sql
pk, status, 검사일, 메모, 철탑형태, 사진S3키, ...
```

### inspection_results_raw — 실적 결과장 (업로드 데이터)
```sql
year, region, 주차별, 허가번호, 통합시설코드, 합불여부,
성능서류, 장비타입, 장비타입간소화, ...
```

## DynamoDB 테이블

| 테이블 | PK | 용도 |
|--------|-----|------|
| kca-users | user_id (사번) | i-NET 사용자 정보 (read-only) |
| kca-user-roles | user_id | KSA 역할 관리 (admin/manager/member) |
| kca-audit-logs | id | 감사 로그 (90일 TTL) |
| kca-ds-records | — | DS 데이터 레코드 |
| kca-ds-uploads | — | DS 업로드 메타데이터 |
| kca-ds-jobs | — | DS 처리 작업 상태 |

## 배포

### 프론트엔드 (Amplify)
```bash
git push origin main  # → Amplify 자동 빌드/배포
```

### 백엔드 (EC2)
```bash
cd ~/kca-api && git pull
sudo systemctl restart kca-api
journalctl -u kca-api --no-pager -n 50  # 로그 확인
```

### 환경변수 (systemd 서비스 파일)
```ini
# /etc/systemd/system/kca-api.service [Service] 섹션
Environment=AUTH_TOKEN_SECRET=...
Environment=ADMIN_BOOTSTRAP_KEY=...
Environment=DEV_LOGIN_ENABLED=1  # 개발 모드
```
변경 후: `sudo systemctl daemon-reload && sudo systemctl restart kca-api`

## 플랫폼별 조건부 컴파일
- `*_stub.dart` — 기본 (빈 구현)
- `*_web.dart` — 웹 전용 (dart:html 사용)
- `*_mobile.dart` — 모바일 전용 (네이티브 SDK)
- import 방식: `import 'stub.dart' if (dart.library.html) 'web.dart'`
