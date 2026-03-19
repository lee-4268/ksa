# KSA 무선국 관리 시스템 — 사내망 Playground 구축 가이드

> **환경**: AWS Playground (사내망)
> **구현 도구**: Claude Code
> **저장소 구조**: FE / BE 별도 repo
> **최종 수정**: 2026-03-12

---

## 운영 방침

| 기능 | 운영 위치 | 비고 |
|------|-----------|------|
| 수검 관리 (지도/검사/사진) | **외부 상용망** (기존 유지) | Flutter Web + 카카오맵 |
| DS 데이터 관리 | **사내망 Playground** | 본 문서 대상 |
| 설치확인서 | **사내망 Playground** | 본 문서 대상 |
| 호출명칭 매칭 | **사내망 Playground** | 본 문서 대상 |
| 전국현황 대시보드 | **사내망 Playground** | 본 문서 대상 |
| 관리자 패널 | **사내망 Playground** | 본 문서 대상 |

---

## 목차

1. [시스템 아키텍처](#1-시스템-아키텍처)
2. [기술 스택](#2-기술-스택)
3. [저장소 구조](#3-저장소-구조)
4. [AWS 인프라 구성](#4-aws-인프라-구성)
5. [BE — FastAPI 백엔드](#5-be--fastapi-백엔드)
6. [FE — Flask 프론트엔드](#6-fe--flask-프론트엔드)
7. [환경변수 설정 총정리](#7-환경변수-설정-총정리)
8. [DynamoDB 테이블 설계](#8-dynamodb-테이블-설계)
9. [S3 버킷 구조](#9-s3-버킷-구조)
10. [인증 흐름](#10-인증-흐름)
11. [주요 기능별 데이터 흐름](#11-주요-기능별-데이터-흐름)
12. [FE 화면 명세](#12-fe-화면-명세)
13. [BE API 명세](#13-be-api-명세)
14. [운영 및 모니터링](#14-운영-및-모니터링)
15. [구축 체크리스트](#15-구축-체크리스트)
16. [트러블슈팅](#16-트러블슈팅)

---

## 1. 시스템 아키텍처

```
┌──────────────────────────────────────────────┐
│            사용자 브라우저 (사내망)               │
└────────────────────┬─────────────────────────┘
                     │ HTTPS
                     ▼
┌──────────────────────────────────────────────┐
│           FE — Flask (Jinja2 + JS)            │
│  ┌────────────────────────────────────────┐  │
│  │  /login          → 로그인               │  │
│  │  /dashboard      → 전국현황 대시보드     │  │
│  │  /ds             → DS 데이터 관리        │  │
│  │  /ds/upload      → DS 업로드            │  │
│  │  /ds/merge       → DS 파일 병합          │  │
│  │  /cert           → 설치확인서            │  │
│  │  /callname       → 호출명칭 매칭         │  │
│  │  /admin          → 관리자 패널           │  │
│  └────────────────────────────────────────┘  │
└────────────────────┬─────────────────────────┘
                     │ HTTP (내부 통신)
                     ▼
┌──────────────────────────────────────────────┐
│           BE — FastAPI (uvicorn:8000)          │
│  ┌────────────────────────────────────────┐  │
│  │  /auth/*         → 인증/토큰             │  │
│  │  /ds/*           → DS 데이터 CRUD        │  │
│  │  /cert/*         → 설치확인서             │  │
│  │  /callname/*     → 호출명칭              │  │
│  │  /admin/*        → 사용자/역할 관리       │  │
│  │  /audit/*        → 감사 로그             │  │
│  └────────────────────────────────────────┘  │
└──────────┬────────────────────┬──────────────┘
           │                    │
           ▼                    ▼
┌──────────────────┐  ┌──────────────────┐
│    DynamoDB       │  │       S3          │
│  (9개 테이블)      │  │  (버킷 1개)       │
└──────────────────┘  └──────────────────┘
```

**제외 기능** (외부망에서 별도 운영):
- 카카오맵 지도/역지오코딩
- 무선국 수검 관리 (사진 업로드, 현장 검사)
- YOLOv8 철탑 분류
- 기상청 날씨 API

---

## 2. 기술 스택

### FE (Flask)

| 항목 | 기술 | 설명 |
|------|------|------|
| 프레임워크 | **Flask** | 경량 Python 웹 프레임워크 |
| 템플릿 | Jinja2 | Flask 내장 |
| CSS | Bootstrap 5 | CDN 또는 로컬 번들 |
| JS | Vanilla JS (fetch API) | BE API 호출, 파일 업로드 |
| Excel 파싱 | SheetJS (xlsx.min.js) | 브라우저에서 XLS/XLSX 읽기 |
| ZIP 처리 | JSZip | 브라우저에서 ZIP 해제 |
| 차트 | Chart.js | 대시보드 차트 |

**Flask를 선택한 이유:**
- BE(FastAPI)와 동일한 Python → 팀 러닝커브 최소
- Jinja2 + JS로 현재 UI 기능 모두 재현 가능
- 파일 업로드 진행률, 폴링, 인증 등 자유롭게 구현
- Playground 지원 프레임워크 중 가장 유연

### BE (FastAPI)

| 항목 | 기술 | 설명 |
|------|------|------|
| 프레임워크 | **FastAPI** + Uvicorn | 기존 main.py 그대로 활용 |
| 데이터 처리 | xlrd, openpyxl, xlsxwriter | XLS 파싱, XLSX 생성 |
| 문서 생성 | python-pptx, openpyxl | 설치확인서 |
| AWS | boto3 | S3, DynamoDB |
| 메모리 관리 | psutil, multiprocessing | 서브프로세스 기반 OOM 방지 |

---

## 3. 저장소 구조

### 3.1 BE repo (`kca-be/`)

```
kca-be/
├── main.py                     # FastAPI 서버 (핵심 — 기존 코드 기반)
├── hwp_generator.py            # HWP 문서 생성
├── pdf_generator.py            # PDF 생성
├── hwpx_header_template.xml    # HWP 템플릿
├── requirements.txt            # Python 의존성
├── .env                        # 환경변수 (gitignore)
└── README.md
```

### 3.2 FE repo (`kca-fe/`)

```
kca-fe/
├── app.py                      # Flask 앱 진입점
├── config.py                   # 설정 (API_BASE_URL 등)
├── requirements.txt            # Flask 의존성
├── templates/                  # Jinja2 HTML 템플릿
│   ├── base.html               # 공통 레이아웃 (사이드바, 헤더)
│   ├── login.html              # 로그인
│   ├── dashboard.html          # 전국현황 대시보드
│   ├── ds/
│   │   ├── index.html          # DS 데이터 조회
│   │   ├── upload.html         # DS 업로드
│   │   ├── merge.html          # DS 파일 병합
│   │   └── export.html         # DS Export
│   ├── cert/
│   │   ├── search.html         # 설치확인서 검색
│   │   └── generate.html       # 설치확인서 생성
│   ├── callname/
│   │   └── index.html          # 호출명칭 매칭
│   └── admin/
│       ├── users.html          # 사용자 관리
│       └── audit.html          # 감사 로그
├── static/
│   ├── css/
│   │   └── style.css           # 커스텀 스타일
│   ├── js/
│   │   ├── api.js              # BE API 호출 공통 모듈
│   │   ├── ds_upload.js        # DS 업로드 로직 (기존 web/ds_upload.js 기반)
│   │   ├── ds_export.js        # DS Export 로직
│   │   ├── ds_merge.js         # DS 병합 로직
│   │   └── dashboard.js        # 대시보드 차트
│   └── lib/
│       ├── xlsx.full.min.js    # SheetJS
│       ├── jszip.min.js        # JSZip
│       └── chart.min.js        # Chart.js
└── .env                        # 환경변수 (gitignore)
```

---

## 4. AWS 인프라 구성

### 4.1 필요 리소스

| 리소스 | 용도 | 사양 |
|--------|------|------|
| EC2 | BE (FastAPI) | t3.medium (4GB RAM, 2 vCPU) |
| EC2 또는 Playground 환경 | FE (Flask) | t3.small 충분 |
| S3 | 파일 저장 (ZIP, XLSX, CSV) | 버킷 1개 |
| DynamoDB | 데이터 저장 | 테이블 9개, PAY_PER_REQUEST |
| IAM Role | EC2 → S3/DynamoDB 접근 | 아래 정책 참조 |

### 4.2 IAM 정책

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "s3:ListBucket", "s3:HeadObject"
      ],
      "Resource": [
        "arn:aws:s3:::YOUR-BUCKET-NAME",
        "arn:aws:s3:::YOUR-BUCKET-NAME/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem",
        "dynamodb:DeleteItem", "dynamodb:Query", "dynamodb:Scan",
        "dynamodb:BatchWriteItem", "dynamodb:BatchGetItem"
      ],
      "Resource": "arn:aws:dynamodb:ap-northeast-2:*:table/kca-*"
    }
  ]
}
```

### 4.3 EC2 초기 설정 (BE 서버)

```bash
# 스왑 2GB (DS 수도권 800만행 처리 시 필수)
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

### 4.4 DynamoDB 테이블 생성 스크립트

```bash
#!/bin/bash
REGION="ap-northeast-2"

# 1. DS 레코드 (PK=divisionId, SK=복합키)
aws dynamodb create-table --region $REGION \
  --table-name kca-ds-records \
  --attribute-definitions \
    AttributeName=divisionId,AttributeType=S \
    AttributeName=SK,AttributeType=S \
  --key-schema \
    AttributeName=divisionId,KeyType=HASH \
    AttributeName=SK,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST

# 2. DS 업로드 메타 (PK=divisionId, SK=코드#날짜)
aws dynamodb create-table --region $REGION \
  --table-name kca-ds-uploads \
  --attribute-definitions \
    AttributeName=divisionId,AttributeType=S \
    AttributeName=importDate,AttributeType=S \
  --key-schema \
    AttributeName=divisionId,KeyType=HASH \
    AttributeName=importDate,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST

# 3. DS 백그라운드 잡 큐 (PK=jobId)
aws dynamodb create-table --region $REGION \
  --table-name kca-ds-jobs \
  --attribute-definitions \
    AttributeName=jobId,AttributeType=S \
  --key-schema \
    AttributeName=jobId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# 4. 감사 로그 (PK, SK 복합)
aws dynamodb create-table --region $REGION \
  --table-name kca-audit-logs \
  --attribute-definitions \
    AttributeName=PK,AttributeType=S \
    AttributeName=SK,AttributeType=S \
  --key-schema \
    AttributeName=PK,KeyType=HASH \
    AttributeName=SK,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST

# 5. 사용자 역할 (PK=empno)
aws dynamodb create-table --region $REGION \
  --table-name kca-user-roles \
  --attribute-definitions \
    AttributeName=empno,AttributeType=S \
  --key-schema \
    AttributeName=empno,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# 6. 사용자 정보
aws dynamodb create-table --region $REGION \
  --table-name Users \
  --attribute-definitions \
    AttributeName=username,AttributeType=S \
  --key-schema \
    AttributeName=username,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# 7~9. 카테고리, 무선국, 분류 (외부망 기능이지만 스키마 호환용)
for TABLE in kca-categories kca-stations kca-classifications; do
  aws dynamodb create-table --region $REGION \
    --table-name $TABLE \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
done

echo "모든 테이블 생성 완료"
```

---

## 5. BE — FastAPI 백엔드

### 5.1 의존성 (requirements.txt)

```
fastapi>=0.100.0
uvicorn[standard]>=0.23.0
python-multipart>=0.0.6
pydantic>=2.0.0
boto3>=1.28.0
httpx>=0.24.0
xlrd>=2.0.0
openpyxl>=3.1.0
xlsxwriter>=3.1.0
psutil>=5.9.0
python-pptx>=0.6.21
```

### 5.2 핵심 설계 원칙 (기존 main.py에 반영됨)

| 원칙 | 구현 |
|------|------|
| **메모리 최소 사용** | 서브프로세스로 XLS 파싱/xlsx 빌드 → 완료 후 OS에 메모리 100% 반환 |
| **스트리밍 필수** | 대용량 응답은 StreamingResponse 사용 (한번에 메모리 로드 금지) |
| **싱글 워커** | `--workers 1` — 백그라운드 잡 메모리 경합 방지 |
| **OOM 방지** | psutil로 RAM 모니터링, 가용 300MB 미만 시 대기 |
| **DynamoDB 비용 최적화** | ProjectionExpression, Select='COUNT', Limit 사용 |

### 5.3 systemd 서비스

```ini
[Unit]
Description=KCA API Backend
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/kca-be
EnvironmentFile=/home/ubuntu/kca-be/.env
ExecStart=/home/ubuntu/kca-be/venv/bin/uvicorn main:app \
  --host 0.0.0.0 --port 8000 --workers 1 --log-level info
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### 5.4 BE에서 제외 가능한 엔드포인트

외부망 전용 기능 (사내망에서 불필요):

```
/predict, /predict/ensemble    — YOLOv8 분류
/stations/*                    — 무선국 CRUD
/categories/*                  — 카테고리 CRUD
/upload/photo, /download/photo — 사진 관리
/feedback/*                    — ML 피드백
```

> main.py에서 해당 엔드포인트를 삭제하거나 그대로 두어도 무방 (호출되지 않으면 리소스 미사용)

---

## 6. FE — Flask 프론트엔드

### 6.1 의존성 (requirements.txt)

```
flask>=3.0.0
requests>=2.31.0
python-dotenv>=1.0.0
```

### 6.2 Flask 앱 기본 구조 (app.py)

```python
from flask import Flask, render_template, request, redirect, session, jsonify
import requests
import os

app = Flask(__name__)
app.secret_key = os.getenv("FLASK_SECRET_KEY", "dev-secret")

API_BASE_URL = os.getenv("API_BASE_URL", "http://localhost:8000")


# ── 인증 ──
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        resp = requests.post(f"{API_BASE_URL}/auth/login", json={
            "username": request.form["username"],
            "password": request.form["password"],
        })
        if resp.status_code == 200 and resp.json().get("result") == "ok":
            data = resp.json()
            session["token"] = data["token"]
            session["username"] = request.form["username"]
            session["name"] = data.get("name", "")
            return redirect("/dashboard")
        return render_template("login.html", error="로그인 실패")
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    return redirect("/login")


# ── 대시보드 ──
@app.route("/dashboard")
def dashboard():
    return render_template("dashboard.html")


# ── DS 데이터 관리 ──
@app.route("/ds")
def ds_index():
    return render_template("ds/index.html")

@app.route("/ds/upload")
def ds_upload():
    return render_template("ds/upload.html")

@app.route("/ds/merge")
def ds_merge():
    return render_template("ds/merge.html")


# ── 설치확인서 ──
@app.route("/cert")
def cert_search():
    return render_template("cert/search.html")


# ── 호출명칭 ──
@app.route("/callname")
def callname():
    return render_template("callname/index.html")


# ── 관리자 ──
@app.route("/admin/users")
def admin_users():
    return render_template("admin/users.html")

@app.route("/admin/audit")
def admin_audit():
    return render_template("admin/audit.html")


# ── BE API 프록시 (CORS 우회) ──
@app.route("/api/<path:path>", methods=["GET", "POST", "PUT", "DELETE"])
def api_proxy(path):
    """FE → BE API 프록시. 세션 토큰 자동 첨부."""
    token = session.get("token")
    headers = {"Authorization": f"Bearer {token}"} if token else {}

    resp = requests.request(
        method=request.method,
        url=f"{API_BASE_URL}/{path}",
        headers=headers,
        params=request.args,
        json=request.get_json(silent=True),
        stream=True,
    )

    return (resp.content, resp.status_code, dict(resp.headers))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
```

### 6.3 JS에서 BE API 호출 패턴 (static/js/api.js)

```javascript
// 모든 API 호출은 Flask 프록시 경유 (/api/*)
// → Flask가 세션 토큰을 자동 첨부하므로 JS에서 토큰 관리 불필요

async function apiGet(path) {
    const resp = await fetch(`/api/${path}`);
    if (resp.status === 401) {
        window.location.href = '/login';
        return null;
    }
    return resp.json();
}

async function apiPost(path, body) {
    const resp = await fetch(`/api/${path}`, {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(body),
    });
    if (resp.status === 401) {
        window.location.href = '/login';
        return null;
    }
    return resp.json();
}

// DS 업로드 (스트리밍, 프록시 미경유 — 대용량)
async function dsUploadRaw(file, onProgress) {
    const token = document.querySelector('meta[name="api-token"]')?.content;
    // ... 기존 ds_upload.js 로직 활용
}
```

### 6.4 base.html 템플릿 구조

```html
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>무선국 관리 시스템</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="{{ url_for('static', filename='css/style.css') }}" rel="stylesheet">
</head>
<body>
    <div class="d-flex">
        <!-- 사이드바 -->
        <nav class="sidebar bg-dark text-white" style="width: 240px; min-height: 100vh;">
            <div class="p-3">
                <h5>무선국 관리 시스템</h5>
                <hr>
                <ul class="nav flex-column">
                    <li><a href="/dashboard" class="nav-link text-white">전국 현황</a></li>
                    <li><a href="/ds" class="nav-link text-white">DS 데이터 관리</a></li>
                    <li><a href="/ds/upload" class="nav-link text-white">DS 업로드</a></li>
                    <li><a href="/ds/merge" class="nav-link text-white">DS 파일 병합</a></li>
                    <li><a href="/cert" class="nav-link text-white">설치확인서</a></li>
                    <li><a href="/callname" class="nav-link text-white">호출명칭 매칭</a></li>
                    {% if session.get('role') in ['admin', 'manager'] %}
                    <hr>
                    <li><a href="/admin/users" class="nav-link text-white">사용자 관리</a></li>
                    <li><a href="/admin/audit" class="nav-link text-white">감사 로그</a></li>
                    {% endif %}
                </ul>
            </div>
        </nav>

        <!-- 메인 콘텐츠 -->
        <main class="flex-grow-1 p-4">
            {% block content %}{% endblock %}
        </main>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5/dist/js/bootstrap.bundle.min.js"></script>
    <script src="{{ url_for('static', filename='js/api.js') }}"></script>
    {% block scripts %}{% endblock %}
</body>
</html>
```

---

## 7. 환경변수 설정 총정리

### 7.1 BE (.env)

| 변수명 | 필수 | 기본값 | 설명 |
|--------|------|--------|------|
| `S3_BUCKET_NAME` | ✅ | `sko-kca-s3` | S3 버킷명 |
| `AWS_REGION` | | `ap-northeast-2` | AWS 리전 |
| `AUTH_TOKEN_SECRET` | ✅ | 랜덤(개발용) | HMAC 토큰 서명 키. **운영 시 고정값 필수** |
| `ADMIN_BOOTSTRAP_KEY` | ✅ | — | 최초 관리자 생성 키 |
| `CORS_ALLOWED_ORIGINS` | | — | FE 도메인 (쉼표 구분) |
| `SSO_LOGIN_URL` | | — | 사내 SSO 서버 주소 |

### 7.2 FE (.env)

| 변수명 | 필수 | 기본값 | 설명 |
|--------|------|--------|------|
| `API_BASE_URL` | ✅ | `http://localhost:8000` | BE FastAPI 서버 주소 |
| `FLASK_SECRET_KEY` | ✅ | — | Flask 세션 암호화 키 |
| `FLASK_ENV` | | `production` | 실행 환경 |

---

## 8. DynamoDB 테이블 설계

### 8.1 핵심 테이블 (사내망에서 주로 사용)

| 테이블 | PK | SK | 용도 |
|--------|----|----|------|
| `kca-ds-records` | `divisionId` (S) | `SK` (S) | DS 데이터 행 (수백만 건) |
| `kca-ds-uploads` | `divisionId` (S) | `importDate` (S) | DS 업로드 메타 (시트 통계, 헤더) |
| `kca-ds-jobs` | `jobId` (S) | — | 업로드 백그라운드 잡 큐 |
| `kca-user-roles` | `empno` (S) | — | 사용자 역할 (admin/manager/member) |
| `kca-audit-logs` | `PK` (S) | `SK` (S) | 감사 로그 |
| `Users` | `username` (S) | — | 사용자 기본 정보 |

### 8.2 SK 형식

```
# kca-ds-records
SK = "{sheetName}#{importDate}#{divisionCode}#{rowIndex}"
예: "전국(1)#20260303#10#00001"

# kca-ds-uploads
SK = "{divisionCode}#{importDate}"
예: "10#20260303"
```

### 8.3 DS 지역코드 매핑

```
10 → sudogwon    (수도권)
20 → gyeongnam   (경남본부)
30 → seobu       (서부본부)
40 → gangwon     (강원본부)
50 → chungcheong (충청본부)
55 → chungcheong (충청본부)
60 → gyeongbuk   (경북본부)
70 → seobu       (서부본부)
```

---

## 9. S3 버킷 구조

```
YOUR-BUCKET-NAME/
├── ds-raw/                    # DS 원본 ZIP
│   ├── temp/                  # 임시 업로드 (처리 후 삭제)
│   └── {divisionId}/         # 본부별 영구 보관
│       └── {code}_{date}.zip
├── ds-exports/                # DS xlsx 캐시 (Export 시 반환)
│   └── {divisionId}/
│       └── {code}_{date}.xlsx
└── callname/                  # 호출명칭 CSV
    └── latest.csv
```

> 외부망 전용 prefix (`photos/`, `excel/`, `feedback/`)는 사내망에서 미사용

---

## 10. 인증 흐름

```
1. 사용자 → Flask /login (ID/PW 입력)
2. Flask → FastAPI POST /auth/login (SSO 프록시)
3. FastAPI → 사내 SSO 서버 검증
4. 성공 시 HMAC 토큰 발급 (2시간 만료)
5. Flask 세션에 토큰 저장
6. 이후 API 호출 시 Flask 프록시가 토큰 자동 첨부

토큰 갱신:
- BE 미들웨어: 잔여 수명 50% 이하 시 X-Refreshed-Token 헤더로 새 토큰 반환
- Flask 프록시: 응답 헤더에서 새 토큰 감지 → 세션 업데이트
- POST /auth/refresh: 명시적 토큰 갱신 (세션 연장 시)
```

---

## 11. 주요 기능별 데이터 흐름

### 11.1 DS 데이터 업로드 (단일 ZIP)

```
1. 브라우저: ZIP 파일 선택
2. JS: POST /api/ds/upload-raw (8MB 청크 스트리밍) → S3 ds-raw/temp/
3. JS: POST /api/ds/enqueue {s3Key, fileName, uploadedBy} → jobId
4. JS: GET /api/ds/job/{jobId} 3초 폴링 → 진행률 표시
5. BE 백그라운드:
   a. S3 ZIP 다운로드
   b. xlrd XLS 파싱 (서브프로세스, 메모리 격리)
   c. DynamoDB 기존 데이터 삭제 → 새 데이터 저장
   d. ZIP → S3 영구 경로 이동
   e. xlsx 캐시 빌드 큐 등록
```

### 11.2 DS 복수 ZIP 병합 업로드

```
1. 브라우저: 여러 ZIP 선택 → 지역코드별 자동 그룹핑
2. 각 ZIP → POST /api/ds/upload-raw → S3 임시 저장
3. POST /api/ds/enqueue-multi {s3Keys, fileNames, uploadedBy}
4. BE: 소스 ZIP들 → 단일 결합 ZIP 생성 → 기존 파싱 플로우 실행
```

### 11.3 DS Excel Export

```
1. 브라우저: Export 버튼 클릭
2. GET /api/ds/export-xlsx?divisionId=...&divisionCode=...&importDate=...
3. BE: S3 캐시 확인
   ├── 캐시 있음 → presigned URL 반환 → 브라우저 직접 다운로드
   └── 캐시 없음 → on-demand 빌드 → StreamingResponse
```

### 11.4 설치확인서

```
1. GET /api/cert/search?query=... → SQLite 캐시에서 빠른 검색
2. POST /api/cert/generate → HWP/PDF 문서 생성 → 다운로드
```

### 11.5 호출명칭 매칭

```
1. POST /api/callname/upload → CSV 업로드
2. GET /api/callname/search?query=... → 검색
3. GET /api/callname/match → 자동 매칭 결과
```

---

## 12. FE 화면 명세

### 12.1 로그인 (`/login`)
- ID/PW 입력 폼
- SSO 인증 → 세션 생성

### 12.2 전국현황 대시보드 (`/dashboard`)
- 본부별 DS 업로드 현황 카드
- 업로드 일자, 총 행수, 시트 수 표시
- Chart.js 차트 (본부별 데이터량 비교)

### 12.3 DS 데이터 조회 (`/ds`)
- 본부/지역코드/날짜 필터
- 시트별 데이터 테이블 (페이지네이션)
- Excel Export 버튼

### 12.4 DS 업로드 (`/ds/upload`)
- 파일 선택 (단일/복수 ZIP)
- 업로드 진행률 표시 (프로그레스바)
- 지역코드 자동 파싱 + 그룹핑 표시
- 잡 폴링 → 완료/실패 상태

### 12.5 DS 파일 병합 (`/ds/merge`)
- 여러 ZIP 선택
- SheetJS + JSZip으로 브라우저 내 병합
- 결과 XLSX 다운로드

### 12.6 설치확인서 (`/cert`)
- 검색 폼 (국명, 호출부호 등)
- 결과 테이블
- HWP/PDF 생성 버튼

### 12.7 호출명칭 매칭 (`/callname`)
- CSV 업로드
- 매칭 결과 테이블
- 필터 (통시/Access담당/품질개선팀)

### 12.8 관리자 — 사용자 관리 (`/admin/users`)
- 사용자 목록 테이블
- 역할 변경 (admin/manager/member)
- 권한: admin, manager만 접근

### 12.9 관리자 — 감사 로그 (`/admin/audit`)
- 날짜 범위 필터
- 액션별 필터 (로그인, 업로드, Export 등)
- 로그 테이블 (시간, 사용자, 액션, 상세)

---

## 13. BE API 명세 (FE에서 사용하는 엔드포인트)

### 인증

| Method | Path | 설명 |
|--------|------|------|
| POST | `/auth/login` | 로그인 (SSO 프록시) |
| POST | `/auth/refresh` | 토큰 갱신 |

### DS 데이터

| Method | Path | 설명 |
|--------|------|------|
| GET | `/ds/uploads` | 업로드 목록 조회 |
| GET | `/ds/data` | 데이터 조회 (페이지네이션) |
| POST | `/ds/upload-raw` | ZIP 파일 S3 업로드 (스트리밍) |
| POST | `/ds/enqueue` | 단일 ZIP 잡 생성 |
| POST | `/ds/enqueue-multi` | 복수 ZIP 병합 잡 생성 |
| GET | `/ds/job/{jobId}` | 잡 진행 상태 조회 |
| GET | `/ds/export-xlsx` | Excel Export |
| DELETE | `/ds/uploads/{id}` | 업로드 데이터 삭제 |
| POST | `/ds/trigger-xlsx-build` | xlsx 캐시 수동 빌드 트리거 |

### 설치확인서

| Method | Path | 설명 |
|--------|------|------|
| GET | `/cert/search` | 검색 |
| POST | `/cert/generate` | 문서 생성 |
| GET | `/cert/batch/{jobId}` | 일괄 생성 상태 |

### 호출명칭

| Method | Path | 설명 |
|--------|------|------|
| GET | `/callname/search` | 검색 |
| POST | `/callname/upload` | CSV 업로드 |
| GET | `/callname/match` | 매칭 결과 |

### 관리자

| Method | Path | 설명 |
|--------|------|------|
| GET | `/admin/users` | 사용자 목록 |
| PUT | `/admin/users/{empno}/role` | 역할 변경 |
| GET | `/audit/logs` | 감사 로그 조회 |

### 공통

| Method | Path | 설명 |
|--------|------|------|
| GET | `/health` | 헬스 체크 |

---

## 14. 운영 및 모니터링

### 서비스 관리

```bash
# BE
sudo systemctl restart kca-api
sudo journalctl -u kca-api -f

# FE (Flask)
sudo systemctl restart kca-fe
sudo journalctl -u kca-fe -f
```

### 헬스 체크

```bash
curl http://BE-HOST:8000/health    # BE
curl http://FE-HOST:5000/          # FE
```

### 메모리 모니터링 (BE 서버)

```bash
watch -n 1 'free -h'
# DS 빌드 중 자동 로그:
# DS xlsx build: [5/63] SKT(10)20260302.xls → 144582행 (RAM 81.1%, 가용 724MB)
```

---

## 15. 구축 체크리스트

### AWS 인프라

- [ ] S3 버킷 생성 + CORS 설정
- [ ] DynamoDB 9개 테이블 생성 (스크립트 실행)
- [ ] EC2 인스턴스 (BE: t3.medium + 스왑 2GB)
- [ ] IAM Role 연결

### BE (FastAPI)

- [ ] Python 3.9+ venv 구성
- [ ] `pip install -r requirements.txt`
- [ ] main.py 배포
- [ ] .env 환경변수 설정
  - [ ] `S3_BUCKET_NAME`
  - [ ] `AUTH_TOKEN_SECRET` (운영용 고정값)
  - [ ] `ADMIN_BOOTSTRAP_KEY`
  - [ ] `CORS_ALLOWED_ORIGINS`
  - [ ] `SSO_LOGIN_URL` (사내 SSO)
- [ ] systemd 서비스 등록
- [ ] `GET /health` 정상 응답 확인

### FE (Flask)

- [ ] Python 3.9+ venv 구성
- [ ] `pip install -r requirements.txt`
- [ ] .env 환경변수 설정
  - [ ] `API_BASE_URL` (BE 주소)
  - [ ] `FLASK_SECRET_KEY`
- [ ] 템플릿/정적파일 배포
- [ ] 브라우저 접속 확인

### 기능 검증

- [ ] 로그인/로그아웃
- [ ] DS 데이터 업로드 (단일 ZIP)
- [ ] DS 데이터 업로드 (복수 ZIP 병합)
- [ ] DS 데이터 조회 (페이지네이션)
- [ ] DS Excel Export
- [ ] 설치확인서 검색/생성
- [ ] 호출명칭 매칭
- [ ] 관리자 — 사용자 역할 관리
- [ ] 감사 로그 조회
- [ ] 세션 연장 (토큰 갱신)

---

## 16. 트러블슈팅

### OOM (Out of Memory)

```bash
sudo dmesg | grep -i "out of memory"
```
→ t3.medium (4GB) + 스왑 2GB 확인. DS 수도권 (800만행)이 피크.

### DS xlsx 빌드 실패

```bash
sudo journalctl -u kca-api | grep "xlsx build"
```
→ xlsxwriter tmpdir 격리 확인, 메모리 부족 여부 확인.

### 401 토큰 만료

→ Flask 프록시에서 `X-Refreshed-Token` 헤더 감지 → 세션 토큰 업데이트 로직 확인.

### FE → BE 통신 실패

```bash
# FE에서 BE 접근 확인
curl http://BE-HOST:8000/health
```
→ 보안 그룹, CORS 설정, 네트워크 경로 확인.
