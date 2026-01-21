# 철탑/안테나 분류 프로젝트 (YOLOv8)

YOLOv8을 활용한 통신 철탑 및 안테나 형태 분류 시스템

## 분류 클래스

| 클래스명 | 한글명 | 설명 |
|---------|-------|------|
| dispersed_pole | 분산폴 | 분산형 안테나 폴 |
| single_pole | 원폴 | 원형 단일 폴 |
| eco_friendly | 환경친화형 | 가로등형/경관형 등 |
| utility_pole | 전주 | 콘크리트 전주 |
| steel_pipe | 강관주 | 철제 강관 구조물 |

## 프로젝트 구조

```
YOLOv8/
├── configs/
│   ├── dataset.yaml        # 데이터셋 설정
│   └── train_config.yaml   # 학습 하이퍼파라미터
├── data/
│   ├── images/
│   │   ├── train/          # 학습 이미지
│   │   └── val/            # 검증 이미지
│   └── labels/
│       ├── train/          # 학습 라벨
│       └── val/            # 검증 라벨
├── utils/
│   └── data_prepare.py     # 데이터 전처리 도구
├── models/                  # 학습된 모델 저장
├── train.py                # 학습 스크립트
├── predict.py              # 추론 스크립트
├── evaluate.py             # 평가 스크립트
├── requirements.txt        # 의존성 패키지
└── README.md
```

## 환경 설정

### 1. Python 가상환경 생성 (권장)

```bash
python -m venv venv
venv\Scripts\activate  # Windows
# source venv/bin/activate  # Linux/Mac
```

### 2. 패키지 설치

```bash
pip install -r requirements.txt
```

## 데이터 준비

### 메타데이터 기반 자동 구성

국소 형태정보(CSV/Excel)와 이미지가 있는 경우:

```bash
# 데이터셋 준비
python utils/data_prepare.py prepare \
    --metadata 국소정보.csv \
    --images 이미지폴더경로 \
    --output data/processed \
    --type-col 형태 \
    --id-col 국소ID \
    --train-ratio 0.8
```

### 수동 구성

이미지를 클래스별 폴더에 직접 배치:

```
data/
├── train/
│   ├── dispersed_pole/
│   │   ├── image1.jpg
│   │   └── image2.jpg
│   ├── single_pole/
│   ├── eco_friendly/
│   ├── utility_pole/
│   └── steel_pipe/
└── val/
    ├── dispersed_pole/
    └── ...
```

## 학습

### 기본 학습

```bash
python train.py
```

### 설정 파일 지정

```bash
python train.py --config configs/train_config.yaml --dataset configs/dataset.yaml
```

### 데이터 경로 직접 지정

```bash
python train.py --data data/processed
```

### 학습 재개

```bash
python train.py --resume runs/classify/tower_classifier/weights/last.pt
```

## 추론

### 단일 이미지

```bash
python predict.py \
    --model runs/classify/tower_classifier/weights/best.pt \
    --source test_image.jpg
```

### 디렉토리 전체

```bash
python predict.py \
    --model runs/classify/tower_classifier/weights/best.pt \
    --source test_images/ \
    --output results/predictions.json
```

### 신뢰도 임계값 조정

```bash
python predict.py \
    --model runs/classify/tower_classifier/weights/best.pt \
    --source test_images/ \
    --conf 0.7
```

## 평가

```bash
python evaluate.py \
    --model runs/classify/tower_classifier/weights/best.pt \
    --data data/processed \
    --split val
```

## 설정 파일

### dataset.yaml

```yaml
path: ../data
train: images/train
val: images/val

names:
  0: dispersed_pole
  1: single_pole
  2: eco_friendly
  3: utility_pole
  4: steel_pipe

nc: 5
```

### train_config.yaml

주요 하이퍼파라미터:
- `model`: 사전학습 모델 (yolov8n-cls.pt ~ yolov8x-cls.pt)
- `epochs`: 학습 에폭 수
- `batch`: 배치 크기 (GPU 메모리에 따라 조정)
- `imgsz`: 입력 이미지 크기
- `patience`: Early stopping patience

## 형태 매핑 추가

새로운 형태 유형이 있는 경우 `utils/data_prepare.py`의 `TYPE_MAPPING` 수정:

```python
TYPE_MAPPING = {
    '분산폴': 'dispersed_pole',
    '새로운형태': 'dispersed_pole',  # 추가
    ...
}
```

## GPU 사용

CUDA가 설치된 경우 자동으로 GPU 사용. CPU만 사용하려면:

```bash
# train_config.yaml에서
device: cpu
```

## 문제 해결

### 메모리 부족
- `batch` 크기를 줄이세요 (16 → 8 → 4)
- `imgsz` 크기를 줄이세요 (224 → 128)
- 더 작은 모델 사용 (yolov8x → yolov8n)

### 학습이 수렴하지 않음
- `epochs` 수를 늘리세요
- `lr0` 학습률을 조정하세요
- 데이터 증강 설정을 조정하세요
