# KSA (Korea Station Administration)

무선국 정기검사 관리 시스템 — 크로스플랫폼 Flutter 앱 + FastAPI 백엔드

## 작업별 참조 문서

| 작업 | 읽어야 할 문서 |
|------|-------------|
| UI 수정/추가 | `docs/rules/ui-patterns.md` |
| 백엔드 API 수정 | `docs/rules/api-guide.md` + 해당 도메인 문서 |
| 검사/실적 관련 | `docs/rules/inspection-domain.md` |
| DS/호출명칭/설치확인서/시설물 사진 | `docs/rules/data-domain.md` |
| DS xlsx 빌드/다운로드/CORS | `docs/rules/ds-xlsx-pipeline.md` |
| 인증/권한 관련 | `docs/rules/auth-and-roles.md` |
| 보안/시크릿/환경변수/백업 | `docs/rules/security.md` |
| 구조/배포/DB | `docs/rules/architecture.md` |

> **문서 최신화 (필수)**: 위 문서들이 다루는 영역을 변경하면, 코드와 함께 해당 `docs/rules/*.md`도 같은 작업에서 갱신한다. 특히 보안 조치는 `security.md`의 점검 이력 표에 (이슈/위치/조치/커밋)을 추가하고, 해소된 '남은 항목'은 종결 표시. 라인번호·파일경로가 바뀌면 문서의 위치 표기도 현행화. 문서 갱신은 별도 작업으로 미루지 말 것.

## 핵심 규칙 (항상 적용)

### 코드 스타일
- Dart: 기존 코드 컨벤션 따름, 불필요한 주석/docstring 추가 금지
- Python(백엔드): 기존 main.py 스타일 유지, 함수명 한글 허용
- 새 파일 생성보다 기존 파일 수정 우선

### 커밋 규칙
- 한글 커밋 메시지, 변경 내용 요약
- `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>` 포함

### 에러 처리
- Flutter: `IntrinsicHeight` + `SingleChildScrollView(horizontal)` 조합 사용 금지 (render box size 에러)
- `LayoutBuilder` + `FittedBox` 조합도 `IntrinsicHeight` 내부에서 사용 금지
- DataTable 넘침 → `ClipRect`로 감싸기

### 배포
- 프론트: `flutter build web` → AWS Amplify 자동 배포 (git push)
- 백엔드: `yolov8/api/` 모듈 구조 (main.py + core/ + routers/ + schemas/). 2026.05 리팩토링으로 단일 main.py curl 배포는 폐기 → EC2에서 `scripts/deploy_backend.sh` (tarball) 사용. 상세 `docs/rules/architecture.md`
- 백엔드 코드 추가 시: 엔드포인트→`routers/*.py`, 유틸→`core/*.py`, 모델→`schemas/models.py`(라우터에서 쓰면 반드시 import)
- 환경변수는 systemd 서비스 파일에 설정 (`/etc/systemd/system/kca-api.service`)

### 보안 (항상 준수)
- 외부 API 키·시크릿·DB 비밀번호는 절대 코드에 하드코딩하지 말 것 → `os.environ.get()`
- 새 라우터는 반드시 `await _verify_auth(request)` + 필요 시 admin/manager role 게이트
- 사용자 입력 → SQL: `?` 파라미터 바인딩만 사용. f-string으로 값 삽입 금지
- 사용자 입력 → 파일/S3 키: `os.path.basename` + sanitize + prefix 화이트리스트
- 응답 dict에 `secret_password`, 내부 ID, PII가 들어가지 않는지 확인
- HTTPException detail에 `str(e)` 노출 금지, 상세는 `logger`로만
- 자세한 보안 정책·점검 이력은 `docs/rules/security.md` 참조
