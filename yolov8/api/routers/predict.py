"""
predict - YOLO 분류 및 피드백 엔드포인트

담당 도메인: 이미지 분류 (예측/앙상블/피드백)
주요 의존성: core.auth, core.model, core.utils, core.s3, core.config
엔드포인트:
    GET  /
    GET  /health
    GET  /classes
    POST /predict
    POST /predict/ensemble
    POST /feedback
    GET  /feedback/stats
"""

import shutil
import logging
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import List

from fastapi import APIRouter, File, UploadFile, HTTPException, Query, Form, Request
from fastapi.responses import JSONResponse

from core.auth import _verify_auth
from core.config import CLASS_NAMES_KR, SHORT_NAMES, MODEL_PATH, UPLOAD_DIR, S3_BUCKET_NAME, ALLOWED_EXTENSIONS
from core.db import get_s3_client
from core.model import model, load_model, predict_single_image, ensemble_predictions
from core.utils import (
    _check_memory, _check_rate_limit, validate_image, validate_image_bytes,
    save_upload_file, cleanup_file
)
from schemas.models import (
    HealthResponse, ClassListResponse, SinglePredictionResponse,
    EnsemblePredictionResponse, FeedbackResponse
)

router = APIRouter(tags=["predict"])
logger = logging.getLogger(__name__)


# ── 로컬 유틸 ─────────────────────────────────────────────────

def upload_to_s3_local(file_path: Path, s3_key: str) -> bool:
    """S3 업로드 (predict 전용 래퍼)."""
    from botocore.exceptions import ClientError
    try:
        s3_client = get_s3_client()
        s3_client.upload_file(
            str(file_path), S3_BUCKET_NAME, s3_key,
            ExtraArgs={'ContentType': 'image/jpeg'}
        )
        return True
    except ClientError as e:
        logger.error(f"S3 upload failed: {e}")
        return False
    except Exception as e:
        logger.error(f"S3 upload error: {e}")
        return False


# ── 엔드포인트 ────────────────────────────────────────────────

@router.get("/", response_model=HealthResponse)
async def root():
    """서버 상태 확인 (루트)."""
    return {
        "status": "healthy",
        "model_loaded": model is not None,
        "model_path": MODEL_PATH,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }


@router.get("/health", response_model=HealthResponse)
async def health_check():
    """서버 상태 확인."""
    return {
        "status": "healthy",
        "model_loaded": model is not None,
        "model_path": MODEL_PATH,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }


@router.get("/classes", response_model=ClassListResponse)
async def get_classes():
    """분류 클래스 목록 조회."""
    classes = [
        {
            "id": i,
            "name": name,
            "name_kr": CLASS_NAMES_KR.get(name, name),
            "short_name": SHORT_NAMES.get(CLASS_NAMES_KR.get(name, name), name)
        }
        for i, name in enumerate([
            'simple_pole', 'steel_pipe', 'complex_type', 'indoor',
            'single_pole_building', 'tower_building', 'tower_ground',
            'telecom_pole', 'frame_mount'
        ])
    ]
    return {"classes": classes}


@router.post("/predict", response_model=SinglePredictionResponse)
async def predict_single(
    file: UploadFile = File(..., description="Image file to classify"),
    conf_threshold: float = Query(0.5, ge=0.0, le=1.0, description="Confidence threshold"),
    request: Request = None,
):
    """단일 이미지 분류."""
    await _verify_auth(request)
    _check_memory("YOLO 이미지 분류")
    _check_rate_limit(request, "predict", 10, 60)

    start_time = time.time()

    if not validate_image(file):
        raise HTTPException(
            status_code=400,
            detail=f"Invalid file type. Allowed: {list(ALLOWED_EXTENSIONS)}"
        )

    file_path = None
    try:
        file_path = await save_upload_file(file, UPLOAD_DIR)
        result = predict_single_image(file_path)
        processing_time = (time.time() - start_time) * 1000

        return {
            "success": True,
            "prediction": {
                "class_name": result["class_name"],
                "class_name_kr": result["class_name_kr"],
                "short_name": result["short_name"],
                "confidence": round(result["confidence"], 4)
            },
            "top5": result["top5"],
            "is_confident": result["confidence"] >= conf_threshold,
            "processing_time_ms": round(processing_time, 2)
        }

    except Exception as e:
        logger.error(f"predict failed: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")

    finally:
        if file_path:
            cleanup_file(file_path)


@router.post("/predict/ensemble", response_model=EnsemblePredictionResponse)
async def predict_ensemble(
    files: List[UploadFile] = File(..., description="Multiple image files to classify"),
    method: str = Query("mean", pattern="^(mean|max|vote)$", description="Ensemble method"),
    conf_threshold: float = Query(0.5, ge=0.0, le=1.0, description="Confidence threshold"),
    request: Request = None,
):
    """복수 이미지 앙상블 분류."""
    await _verify_auth(request)
    _check_memory("YOLO 앙상블 분류")
    _check_rate_limit(request, "predict_ensemble", 5, 60)

    start_time = time.time()

    if len(files) < 1:
        raise HTTPException(status_code=400, detail="At least 1 image required")
    if len(files) > 10:
        raise HTTPException(status_code=400, detail="Maximum 10 images allowed")

    for file in files:
        if not validate_image(file):
            raise HTTPException(
                status_code=400,
                detail=f"Invalid file type: {file.filename}."
            )

    file_paths = []
    predictions = []
    individual_results = []

    try:
        for file in files:
            file_path = await save_upload_file(file, UPLOAD_DIR)
            file_paths.append(file_path)

            result = predict_single_image(file_path)
            predictions.append(result)

            individual_results.append({
                "filename": file.filename,
                "prediction": result["class_name"],
                "prediction_kr": result["class_name_kr"],
                "confidence": round(result["confidence"], 4)
            })

        ensemble_result = ensemble_predictions(predictions, method)
        processing_time = (time.time() - start_time) * 1000

        return {
            "success": True,
            "method": method,
            "num_images": len(files),
            "final_prediction": {
                "class_name": ensemble_result["class_name"],
                "class_name_kr": ensemble_result["class_name_kr"],
                "short_name": ensemble_result["short_name"],
                "confidence": round(ensemble_result["confidence"], 4)
            },
            "top5": ensemble_result["top5"],
            "individual_predictions": individual_results,
            "is_confident": ensemble_result["confidence"] >= conf_threshold,
            "processing_time_ms": round(processing_time, 2)
        }

    except Exception as e:
        logger.error(f"predict_ensemble failed: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")

    finally:
        for file_path in file_paths:
            cleanup_file(file_path)


@router.post("/feedback", response_model=FeedbackResponse)
async def submit_feedback(
    file: UploadFile = File(..., description="Image file"),
    original_class: str = Form(..., description="Original predicted class (English)"),
    corrected_class: str = Form(..., description="User-corrected class (English)"),
    request: Request = None,
):
    """분류 피드백 제출 — 재학습 데이터 수집용."""
    await _verify_auth(request)
    _check_rate_limit(request, "feedback", 10, 60)

    if not validate_image(file):
        raise HTTPException(
            status_code=400,
            detail=f"Invalid file type."
        )

    valid_classes = list(CLASS_NAMES_KR.keys())
    if corrected_class not in valid_classes:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid corrected_class. Valid options: {valid_classes}"
        )

    file_path = None
    try:
        file_path = await save_upload_file(file, UPLOAD_DIR)

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        original_filename = Path(file.filename).stem
        ext = Path(file.filename).suffix.lower()
        s3_key = f"feedback/{corrected_class}/{timestamp}_{original_filename}{ext}"

        upload_success = upload_to_s3_local(file_path, s3_key)

        if upload_success:
            logger.info(f"Feedback saved: {original_class} -> {corrected_class}, S3: {s3_key}")
            return {
                "success": True,
                "message": "피드백이 저장되었습니다. 모델 개선에 활용됩니다.",
                "s3_key": s3_key,
                "original_class": original_class,
                "corrected_class": corrected_class,
                "timestamp": datetime.now(timezone.utc).isoformat()
            }
        else:
            # S3 실패 시 로컬 저장
            local_feedback_dir = Path("feedback_local") / corrected_class
            local_feedback_dir.mkdir(parents=True, exist_ok=True)
            local_path = local_feedback_dir / f"{timestamp}_{original_filename}{ext}"
            shutil.copy(file_path, local_path)

            logger.warning(f"S3 failed, saved locally: {local_path}")
            return {
                "success": True,
                "message": "피드백이 로컬에 저장되었습니다. (S3 연결 실패)",
                "s3_key": None,
                "original_class": original_class,
                "corrected_class": corrected_class,
                "timestamp": datetime.now(timezone.utc).isoformat()
            }

    except Exception as e:
        logger.error(f"Feedback submission error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")

    finally:
        if file_path:
            cleanup_file(file_path)


@router.get("/feedback/stats")
async def get_feedback_stats(request: Request = None):
    """피드백 통계 조회 — 클래스별 피드백 이미지 수."""
    await _verify_auth(request)
    try:
        from botocore.exceptions import ClientError
        s3_client = get_s3_client()
        stats = {}
        for class_name in CLASS_NAMES_KR.keys():
            prefix = f"feedback/{class_name}/"
            try:
                response = s3_client.list_objects_v2(Bucket=S3_BUCKET_NAME, Prefix=prefix)
                count = response.get('KeyCount', 0)
                stats[class_name] = {"count": count, "class_name_kr": CLASS_NAMES_KR[class_name]}
            except ClientError:
                stats[class_name] = {"count": 0, "class_name_kr": CLASS_NAMES_KR[class_name], "error": "S3 접근 실패"}

        return {
            "success": True,
            "bucket": S3_BUCKET_NAME,
            "stats": stats,
            "total_feedback": sum(s.get("count", 0) for s in stats.values()),
            "timestamp": datetime.now(timezone.utc).isoformat()
        }

    except Exception as e:
        logger.error(f"Feedback stats error: {e}")
        return {
            "success": False,
            "message": "서버 내부 오류",
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
