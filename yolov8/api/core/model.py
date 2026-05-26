"""
model - YOLO 모델 로딩 및 추론 함수

담당 도메인: YOLOv8 이미지 분류 모델
주요 의존성: core.config
엔드포인트: 없음

주의사항:
- 모델은 Lazy Loading (첫 predict 요청 시 로드) — EC2 메모리 ~200MB 절약
- ThreadPoolExecutor max_workers=2 (2GB RAM 기준 동시 작업 제한)
"""

import logging
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Optional, List

import numpy as np

from .config import MODEL_PATH, CLASS_NAMES_KR, SHORT_NAMES

logger = logging.getLogger(__name__)

# 모델 싱글턴 (Lazy Loading)
model: Optional[object] = None  # ultralytics.YOLO

# 동시 추론 제한 (EC2 2GB RAM 기준)
_bounded_executor = ThreadPoolExecutor(max_workers=2)


def load_model():
    """YOLO 모델 로드 (첫 호출 시만 실제 로드)."""
    global model
    if model is None:
        if not Path(MODEL_PATH).exists():
            raise FileNotFoundError(f"Model not found: {MODEL_PATH}")
        from ultralytics import YOLO
        model = YOLO(MODEL_PATH)
        logger.info(f"Model loaded from: {MODEL_PATH}")
    return model


def predict_single_image(image_path: Path) -> dict:
    """단일 이미지에 대해 YOLO 분류 수행."""
    mdl = load_model()
    results = mdl(str(image_path), verbose=False)
    result = results[0]

    probs = result.probs
    top1_idx = probs.top1
    top1_conf = float(probs.top1conf.item())
    top5_indices = probs.top5
    top5_confs = [float(c) for c in probs.top5conf.tolist()]

    class_names = result.names
    top1_class = class_names[top1_idx]
    top1_class_kr = CLASS_NAMES_KR.get(top1_class, top1_class)
    short_name = SHORT_NAMES.get(top1_class_kr, top1_class_kr)

    return {
        "class_name": top1_class,
        "class_name_kr": top1_class_kr,
        "short_name": short_name,
        "confidence": top1_conf,
        "top5": [
            {
                "rank": i + 1,
                "class_name": class_names[idx],
                "class_name_kr": CLASS_NAMES_KR.get(class_names[idx], class_names[idx]),
                "confidence": conf
            }
            for i, (idx, conf) in enumerate(zip(top5_indices, top5_confs))
        ],
        "all_probs": probs.data.cpu().numpy(),
        "class_names_dict": class_names
    }


def ensemble_predictions(predictions: List[dict], method: str = "mean") -> dict:
    """복수 이미지 예측 결과를 앙상블로 합산."""
    if not predictions:
        raise ValueError("No predictions to ensemble")

    all_probs = np.array([p["all_probs"] for p in predictions])
    class_names = predictions[0]["class_names_dict"]

    if method == "mean":
        ensemble_probs = np.mean(all_probs, axis=0)
    elif method == "max":
        ensemble_probs = np.max(all_probs, axis=0)
    elif method == "vote":
        votes = np.zeros(len(class_names))
        for probs in all_probs:
            votes[np.argmax(probs)] += 1
        ensemble_probs = votes / len(all_probs)
    else:
        ensemble_probs = np.mean(all_probs, axis=0)

    final_idx = int(np.argmax(ensemble_probs))
    final_class = class_names[final_idx]
    final_class_kr = CLASS_NAMES_KR.get(final_class, final_class)
    final_conf = float(ensemble_probs[final_idx])

    top5_indices = np.argsort(ensemble_probs)[::-1][:5]

    return {
        "class_name": final_class,
        "class_name_kr": final_class_kr,
        "short_name": SHORT_NAMES.get(final_class_kr, final_class_kr),
        "confidence": final_conf,
        "top5": [
            {
                "rank": i + 1,
                "class_name": class_names[idx],
                "class_name_kr": CLASS_NAMES_KR.get(class_names[idx], class_names[idx]),
                "confidence": float(ensemble_probs[idx])
            }
            for i, idx in enumerate(top5_indices)
        ]
    }
