# KSA (Korea Station Administration)

무선국 정기검사 관리 시스템 — 크로스플랫폼 Flutter 앱 + FastAPI 백엔드

## 작업별 참조 문서

| 작업 | 읽어야 할 문서 |
|------|-------------|
| UI 수정/추가 | `docs/rules/ui-patterns.md` |
| 백엔드 API 수정 | `docs/rules/api-guide.md` + 해당 도메인 문서 |
| 검사/실적 관련 | `docs/rules/inspection-domain.md` |
| DS/호출명칭/설치확인서 | `docs/rules/data-domain.md` |
| 인증/권한 관련 | `docs/rules/auth-and-roles.md` |
| 구조/배포/DB | `docs/rules/architecture.md` |

## 핵심 규칙 (항상 적용)

### 코드 스타일
- Dart: 기존 코드 컨벤션 따름, 불필요한 주석/docstring 추가 금지
- Python(백엔드): 기존 main.py 스타일 유지, 함수명 한글 허용
- 새 파일 생성보다 기존 파일 수정 우선

### 커밋 규칙
- 한글 커밋 메시지, 변경 내용 요약
- `Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>` 포함

### 에러 처리
- Flutter: `IntrinsicHeight` + `SingleChildScrollView(horizontal)` 조합 사용 금지 (render box size 에러)
- `LayoutBuilder` + `FittedBox` 조합도 `IntrinsicHeight` 내부에서 사용 금지
- DataTable 넘침 → `ClipRect`로 감싸기

### 배포
- 프론트: `flutter build web` → AWS Amplify 자동 배포 (git push)
- 백엔드: EC2 직접 배포, `sudo systemctl restart kca-api`
- 환경변수는 systemd 서비스 파일에 설정 (`/etc/systemd/system/kca-api.service`)
