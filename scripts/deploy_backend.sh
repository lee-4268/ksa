#!/usr/bin/env bash
#
# deploy_backend.sh — KCA 백엔드(FastAPI) EC2 배포 스크립트
#
# 리팩토링 이후 백엔드는 단일 main.py 가 아니라 폴더 구조(core/ routers/ schemas/)입니다.
# 이 스크립트는 GitHub 저장소를 tarball 로 한 번에 받아, 코드 파일/폴더만 운영 위치로
# 복사합니다. DB(*.db) · 로그(*.log) · venv/ · data/ · runs/ 등 런타임 자산은 건드리지 않습니다.
#
# ── 사용법 ────────────────────────────────────────────────────
#   EC2 에서:
#     export GITHUB_TOKEN=ghp_xxxxxxxx        # 기존 배포에 쓰던 토큰
#     bash deploy_backend.sh                  # 코드만 받아오기 (재시작 안 함)
#     bash deploy_backend.sh --restart        # 받아온 뒤 서비스 재시작 + 로그 확인
#
#   옵션 환경변수:
#     BRANCH=main          (기본 main)        받아올 브랜치
#     APP_DIR=/home/ubuntu/kca-api            운영 코드 위치
#     PIP_INSTALL=1        (기본 0)           requirements 재설치 수행
#
# ── 안전장치 ──────────────────────────────────────────────────
#   - 받기 전 기존 main.py 를 main.py.bak.<날짜시각> 으로 백업 (롤백용)
#   - 코드는 /tmp 에서 풀고, 운영 위치에는 main.py/requirements.txt/core/routers/schemas 만 복사
#   - 토큰은 인자/코드에 하드코딩하지 않고 GITHUB_TOKEN 환경변수로만 받음
#
set -euo pipefail

# ── 설정 ──
REPO="T-O-Mega/KCA"
BRANCH="${BRANCH:-main}"
APP_DIR="${APP_DIR:-/home/ubuntu/kca-api}"
SERVICE="kca-api"
DO_RESTART=0
PIP_INSTALL="${PIP_INSTALL:-0}"

for arg in "$@"; do
  case "$arg" in
    --restart) DO_RESTART=1 ;;
    --pip)     PIP_INSTALL=1 ;;
    *) echo "알 수 없는 옵션: $arg"; exit 2 ;;
  esac
done

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "ERROR: GITHUB_TOKEN 환경변수가 없습니다."
  echo "  export GITHUB_TOKEN=<기존 배포 토큰> 후 다시 실행하세요."
  exit 1
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "ERROR: 운영 디렉터리가 없습니다: $APP_DIR"
  exit 1
fi

TS="$(date +%Y%m%d_%H%M%S)"
TARBALL="/tmp/kca_${TS}.tar.gz"
SRC_ROOT="/tmp/kca_src_${TS}"

cleanup() { rm -rf "$TARBALL" "$SRC_ROOT"; }
trap cleanup EXIT

echo "==> [1/5] tarball 다운로드 ($REPO@$BRANCH)"
# Contents API 와 동일한 토큰 사용. -f: HTTP 에러 시 실패 처리.
curl -fsSL \
  -H "Authorization: token ${GITHUB_TOKEN}" \
  -o "$TARBALL" \
  "https://api.github.com/repos/${REPO}/tarball/${BRANCH}"

echo "==> [2/5] 압축 해제"
mkdir -p "$SRC_ROOT"
# GitHub tarball 최상위는 'T-O-Mega-KCA-<sha>/' 한 겹 → --strip-components=1 로 제거
tar xzf "$TARBALL" -C "$SRC_ROOT" --strip-components=1

SRC_API="$SRC_ROOT/yolov8/api"
SRC_REQ="$SRC_ROOT/yolov8/requirements.txt"

# 받은 코드 유효성 검증 (필수 폴더/파일이 있어야 진행)
for p in "$SRC_API/main.py" "$SRC_API/core" "$SRC_API/routers" "$SRC_API/schemas"; do
  if [[ ! -e "$p" ]]; then
    echo "ERROR: 받은 코드에 $p 가 없습니다. 배포 중단."
    exit 1
  fi
done

echo "==> [3/5] 기존 main.py 백업: $APP_DIR/main.py.bak.$TS"
if [[ -f "$APP_DIR/main.py" ]]; then
  cp -p "$APP_DIR/main.py" "$APP_DIR/main.py.bak.$TS"
fi

echo "==> [4/5] 코드 복사 (DB/로그/venv 는 건드리지 않음)"
cp -f "$SRC_API/main.py" "$APP_DIR/main.py"
[[ -f "$SRC_REQ" ]] && cp -f "$SRC_REQ" "$APP_DIR/requirements.txt"
# 폴더는 통째 교체 (지운 뒤 복사 — 삭제된 모듈이 남지 않도록)
for d in core routers schemas; do
  rm -rf "${APP_DIR:?}/$d"
  cp -r "$SRC_API/$d" "$APP_DIR/$d"
done
# 옛 바이트코드 캐시 제거
rm -rf "$APP_DIR/__pycache__" "$APP_DIR"/core/__pycache__ \
       "$APP_DIR"/routers/__pycache__ "$APP_DIR"/schemas/__pycache__ 2>/dev/null || true

if [[ "$PIP_INSTALL" == "1" && -f "$APP_DIR/requirements.txt" ]]; then
  echo "==> [pip] requirements 설치"
  if [[ -f "$APP_DIR/venv/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "$APP_DIR/venv/bin/activate"
  fi
  pip install -r "$APP_DIR/requirements.txt"
fi

echo "==> [5/5] 완료"
if [[ "$DO_RESTART" == "1" ]]; then
  echo "    서비스 재시작: sudo systemctl restart $SERVICE"
  sudo systemctl restart "$SERVICE"
  sleep 2
  echo "    --- 최근 로그 60줄 ---"
  journalctl -u "$SERVICE" -n 60 --no-pager || true
else
  echo "    코드만 갱신했습니다. 재시작하려면:"
  echo "      sudo systemctl restart $SERVICE"
  echo "      journalctl -u $SERVICE -n 60 --no-pager"
fi

echo
echo "롤백이 필요하면 (옛 단일 main.py 로 복귀):"
echo "  cp $APP_DIR/main.py.bak.$TS $APP_DIR/main.py"
echo "  rm -rf $APP_DIR/core $APP_DIR/routers $APP_DIR/schemas"
echo "  sudo systemctl restart $SERVICE"
