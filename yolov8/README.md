# 철탑/안테나 분류 추론 서버 (YOLOv8)

YOLOv8 Classification 모델을 활용한 통신 철탑/안테나 형태 분류 **추론(운영) 서버**.

> **이 디렉토리의 역할**: 학습이 완료된 `best.pt`(가중치)를 로드해 추론 API를 제공한다.
> 추론은 `api/core/model.py`가 `best.pt`만 로드하며, 학습 코드는 이 레포에 없다.
>
> **모델 학습은 별도 레포 `ksa-tower-trainer`에서 수행한다.**
> (데이터 준비 `utils/data_prepare.py`, 학습 `train.py`, 평가 `evaluate.py`,
> CLI 추론 `predict.py`, `configs/`는 모두 그쪽으로 분리됨 — 보안진단 대상에서 제외하고
> 학습/운영 라이프사이클을 분리하기 위함.)
> 새 모델을 학습해 `best.pt`를 갱신하면 아래 "모델 업데이트 방법"으로 운영에 배포한다.

## 분류 클래스 (9개)

| ID | 클래스명 | 한글명 | 약어 |
|----|---------|-------|------|
| 0 | simple_pole | 간이폴, 분산폴 및 비기준 설치대 | 간이폴 |
| 1 | steel_pipe | 강관주 | 강관주 |
| 2 | complex_type | 복합형 | 복합형 |
| 3 | indoor | 옥내, 터널, 지하 등 | 옥내 |
| 4 | single_pole_building | 원폴(건물) | 원폴건물 |
| 5 | tower_building | 철탑(건물) | 철탑건물 |
| 6 | tower_ground | 철탑(지면) | 철탑지면 |
| 7 | telecom_pole | 통신주 | 통신주 |
| 8 | frame_mount | 프레임 | 프레임 |

> ⚠️ 이 클래스 정의는 `api/core/config.py`(`CLASS_NAMES_KR`)와 일치해야 하며,
> 학습 레포 `ksa-tower-trainer`의 클래스 정의와도 동기화되어야 한다.

## 운영 서버 구조

```
yolov8/
├── api/                     # FastAPI 추론 서버 (운영 본체)
│   ├── main.py
│   ├── core/                # auth/config/db/model 등
│   │   └── model.py         # best.pt 로드 + 추론
│   ├── routers/             # 엔드포인트 (predict, community, inspection ...)
│   └── schemas/
├── run_server.py            # 로컬 서버 실행 진입점
├── requirements.txt
└── best.pt                  # 학습된 모델 (ksa-tower-trainer에서 산출)
```

## 로컬 실행

```bash
python -m venv venv
venv\Scripts\activate          # Windows  (Linux/Mac: source venv/bin/activate)
pip install -r requirements.txt
python run_server.py           # http://localhost:8000  (docs: /docs)
```

---

## AWS EC2 배포

### 배포 아키텍처

```
Flutter App (Amplify HTTPS)
        │
        ▼
API Gateway (HTTPS)
https://c3jictzagh.execute-api.ap-northeast-2.amazonaws.com
        │
        ▼
EC2 Instance (c7i-flex.large, Ubuntu 22.04)
http://15.165.204.39:8000
FastAPI + YOLOv8 Model
```

### EC2 인스턴스 정보

| 항목 | 값 |
|------|-----|
| Instance Type | c7i-flex.large (2 vCPU, 4GB RAM) |
| OS | Ubuntu 22.04 LTS |
| Region | ap-northeast-2 (Seoul) |
| Public IP | 15.165.204.39 |
| Port | 8000 |

### 서버 관리 명령어

```bash
ssh -i "tower-api-key.pem" ubuntu@15.165.204.39

sudo systemctl status tower-api      # 상태
sudo systemctl restart tower-api     # 재시작
sudo journalctl -u tower-api -f      # 로그
sudo systemctl stop tower-api        # 중지
```

### 모델 업데이트 방법

1. `ksa-tower-trainer` 레포에서 모델 재학습 → `best.pt` 산출 (재현 기록 표에 한 줄 추가)
2. 새 모델 업로드:
   ```powershell
   scp -i "tower-api-key.pem" best.pt ubuntu@15.165.204.39:~/tower-api/
   ```
3. 서비스 재시작:
   ```bash
   sudo systemctl restart tower-api
   ```

### systemd 서비스 설정

`/etc/systemd/system/tower-api.service`:
```ini
[Unit]
Description=Tower Classification FastAPI
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/tower-api/api
Environment="PATH=/home/ubuntu/tower-api/venv/bin"
ExecStart=/home/ubuntu/tower-api/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

### API Gateway 설정

| 항목 | 값 |
|------|-----|
| API Name | tower-api |
| Type | HTTP API |
| Route | ANY /{proxy+} |
| Integration | HTTP Proxy → http://15.165.204.39:8000/{proxy} |
| Invoke URL | https://c3jictzagh.execute-api.ap-northeast-2.amazonaws.com |
