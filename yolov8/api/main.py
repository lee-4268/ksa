"""
FastAPI Server for Tower/Antenna Classification
Flutter PWA + Mobile Web Support
"""

import os
import json
import uuid
import shutil
import asyncio
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import List, Optional, Dict
from datetime import datetime, timezone
from decimal import Decimal
import logging
import zipfile
import re
import gc
import io

import httpx
import boto3
from botocore.exceptions import ClientError
import numpy as np
from fastapi import FastAPI, File, UploadFile, HTTPException, Query, Form, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel
from ultralytics import YOLO

# DS 서버사이드 처리 패키지 (선택적 — 없으면 경고만)
try:
    import xlrd
    HAS_XLRD = True
except ImportError:
    HAS_XLRD = False
    logging.warning("xlrd not installed - DS server-side processing disabled")

try:
    import openpyxl
    from openpyxl.cell import WriteOnlyCell
    from openpyxl.styles import Font, Alignment, PatternFill, Border, Side
    from openpyxl.utils import get_column_letter
    HAS_OPENPYXL = True
except ImportError:
    HAS_OPENPYXL = False

try:
    import psutil
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False

# ============================================================
# Configuration
# ============================================================

# Model path (update this to your trained model path)
# 학습 후 생성되는 모델 경로: runs/classify/tower_classifier/weights/best.pt
MODEL_PATH = os.getenv(
    "MODEL_PATH",
    "C:/Users/user/Desktop/26/ksa/yolov8/runs/classify/tower_classifier/weights/best.pt"
)

# Temporary upload directory
UPLOAD_DIR = Path("temp_uploads")
UPLOAD_DIR.mkdir(exist_ok=True)

# Allowed image extensions
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}

# S3 Configuration
S3_BUCKET_NAME = os.getenv("S3_BUCKET_NAME", "sko-kca-s3")
S3_REGION = os.getenv("AWS_REGION", "ap-northeast-2")

# DynamoDB Table Names (새 계정에서 생성할 테이블)
DYNAMODB_TABLES = {
    "users": os.getenv("DYNAMODB_USERS_TABLE", "Users"),
    "categories": os.getenv("DYNAMODB_CATEGORIES_TABLE", "kca-categories"),
    "stations": os.getenv("DYNAMODB_STATIONS_TABLE", "kca-stations"),
    "classifications": os.getenv("DYNAMODB_CLASSIFICATIONS_TABLE", "kca-classifications"),
    "ds_records": os.getenv("DYNAMODB_DS_RECORDS_TABLE", "kca-ds-records"),
    "ds_uploads": os.getenv("DYNAMODB_DS_UPLOADS_TABLE", "kca-ds-uploads"),
    "ds_jobs": os.getenv("DYNAMODB_DS_JOBS_TABLE", "kca-ds-jobs"),
}

# DS 전파관리소 지역코드 → 회사 본부 매핑
# 수도권(10) → 강남/강북/인천/경기 4개 본부 통합 저장
# 충남(50)+충북(55) → 충청본부, 전남(30)+전북(70) → 서부본부
DS_REGION_CODE_MAP = {
    "10": {"divisionId": "sudogwon", "divisionName": "수도권"},
    "20": {"divisionId": "gyeongnam", "divisionName": "경남본부"},
    "30": {"divisionId": "seobu", "divisionName": "서부본부"},
    "40": {"divisionId": "gangwon", "divisionName": "강원본부"},
    "50": {"divisionId": "chungcheong", "divisionName": "충청본부"},
    "55": {"divisionId": "chungcheong", "divisionName": "충청본부"},
    "60": {"divisionId": "gyeongbuk", "divisionName": "경북본부"},
    "70": {"divisionId": "seobu", "divisionName": "서부본부"},
}

# Logger setup
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# DS 백그라운드 워커 상태 (싱글턴 — 동시에 1개 잡만 처리)
_ds_job_worker_task: Optional[asyncio.Task] = None

# Class name mappings (Korean)
CLASS_NAMES_KR = {
    'simple_pole': '간이폴, 분산폴 및 비기준 설치대',
    'steel_pipe': '강관주',
    'complex_type': '복합형',
    'indoor': '옥내, 터널, 지하 등',
    'single_pole_building': '원폴(건물)',
    'tower_building': '철탑(건물)',
    'tower_ground': '철탑(지면)',
    'telecom_pole': '통신주',
    'frame_mount': '프레임'
}

SHORT_NAMES = {
    '간이폴, 분산폴 및 비기준 설치대': '간이폴',
    '강관주': '강관주',
    '복합형': '복합형',
    '옥내, 터널, 지하 등': '옥내',
    '원폴(건물)': '원폴건물',
    '철탑(건물)': '철탑건물',
    '철탑(지면)': '철탑지면',
    '통신주': '통신주',
    '프레임': '프레임'
}

# ============================================================
# Pydantic Models (API Response Schemas)
# ============================================================

class PredictionResult(BaseModel):
    class_name: str
    class_name_kr: str
    short_name: str
    confidence: float


class Top5Prediction(BaseModel):
    rank: int
    class_name: str
    class_name_kr: str
    confidence: float


class SinglePredictionResponse(BaseModel):
    success: bool
    prediction: PredictionResult
    top5: List[Top5Prediction]
    is_confident: bool
    processing_time_ms: float


class IndividualPrediction(BaseModel):
    filename: str
    prediction: str
    prediction_kr: str
    confidence: float


class EnsemblePredictionResponse(BaseModel):
    success: bool
    method: str
    num_images: int
    final_prediction: PredictionResult
    top5: List[Top5Prediction]
    individual_predictions: List[IndividualPrediction]
    is_confident: bool
    processing_time_ms: float


class HealthResponse(BaseModel):
    status: str
    model_loaded: bool
    model_path: str
    timestamp: str


class ClassListResponse(BaseModel):
    classes: List[dict]


class FeedbackResponse(BaseModel):
    success: bool
    message: str
    s3_key: Optional[str] = None
    original_class: str
    corrected_class: str
    timestamp: str


class UserInfoResponse(BaseModel):
    success: bool
    empno: str
    name: Optional[str] = None
    region: Optional[str] = None
    team: Optional[str] = None
    job_title: Optional[str] = None
    email: Optional[str] = None
    phone: Optional[str] = None


class LoginRequest(BaseModel):
    username: str
    password: str


# ============================================================
# DynamoDB CRUD Models
# ============================================================

class CategoryCreate(BaseModel):
    name: str
    owner: str
    originalExcelKey: Optional[str] = None


class CategoryResponse(BaseModel):
    id: str
    name: str
    owner: str
    originalExcelKey: Optional[str] = None
    createdAt: str
    updatedAt: str


class StationCreate(BaseModel):
    categoryId: str
    owner: str
    stationName: str
    address: str
    licenseNumber: Optional[str] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    callSign: Optional[str] = None
    gain: Optional[str] = None
    antennaCount: Optional[str] = None
    remarks: Optional[str] = None
    typeApprovalNumber: Optional[str] = None
    frequency: Optional[str] = None
    stationType: Optional[str] = None
    stationOwner: Optional[str] = None
    installationType: Optional[str] = None
    isInspected: bool = False
    inspectionStatus: Optional[str] = None  # pending, passed, failed
    inspectionDate: Optional[str] = None
    memo: Optional[str] = None
    photoKeys: Optional[List[str]] = None


class StationUpdate(BaseModel):
    stationName: Optional[str] = None
    address: Optional[str] = None
    licenseNumber: Optional[str] = None
    latitude: Optional[float] = None
    longitude: Optional[float] = None
    callSign: Optional[str] = None
    gain: Optional[str] = None
    antennaCount: Optional[str] = None
    remarks: Optional[str] = None
    typeApprovalNumber: Optional[str] = None
    frequency: Optional[str] = None
    stationType: Optional[str] = None
    stationOwner: Optional[str] = None
    installationType: Optional[str] = None
    isInspected: Optional[bool] = None
    inspectionStatus: Optional[str] = None  # pending, passed, failed
    inspectionDate: Optional[str] = None
    memo: Optional[str] = None
    photoKeys: Optional[List[str]] = None


class S3UploadResponse(BaseModel):
    success: bool
    key: str
    url: Optional[str] = None


class S3PresignedUrlResponse(BaseModel):
    success: bool
    url: str


# ============================================================
# DS Upload Models
# ============================================================

class DsUploadInit(BaseModel):
    divisionId: str
    divisionCode: str
    importDate: str
    fileName: str
    uploadedBy: str


class DsUploadChunk(BaseModel):
    divisionId: str
    divisionCode: str = ""
    importDate: str
    sheetName: str
    headers: List[str]
    rows: List[List]
    chunkIndex: int
    totalChunks: int
    startIndex: int = 0


class DsUploadFinalize(BaseModel):
    divisionId: str
    divisionCode: str = ""
    importDate: str
    sheetStats: Dict[str, int]
    totalRows: int


class DsEnqueueRequest(BaseModel):
    """DS 서버사이드 처리 잡 요청"""
    s3Key: str       # S3 임시 키 (/ds/presign-raw에서 반환)
    fileName: str    # 원본 파일명 (메타 파싱용)
    uploadedBy: str  # 업로드한 사용자 ID


# ============================================================
# User Data Loading (JSON file)
# ============================================================

USERS_DATA_PATH = os.getenv("USERS_DATA_PATH", "data/users.json")
_users_cache: Optional[Dict[str, dict]] = None


def load_users() -> Dict[str, dict]:
    """Load user data from JSON file (cached)"""
    global _users_cache
    if _users_cache is not None:
        return _users_cache

    data_path = Path(USERS_DATA_PATH)
    if not data_path.exists():
        logger.warning(f"Users data file not found: {data_path}")
        _users_cache = {}
        return _users_cache

    with open(data_path, "r", encoding="utf-8") as f:
        users_list = json.load(f)

    # empno를 키로 하는 딕셔너리로 변환
    _users_cache = {user["empno"]: user for user in users_list if "empno" in user}
    logger.info(f"Loaded {len(_users_cache)} users from {data_path}")
    return _users_cache


# ============================================================
# FastAPI App Initialization
# ============================================================

app = FastAPI(
    title="Tower Classification API",
    description="API for classifying tower/antenna installation types using YOLOv8",
    version="1.0.0",
    docs_url="/docs",
    redoc_url="/redoc"
)

# CORS Configuration for Flutter Web/PWA
# Note: allow_credentials=False when using allow_origins=["*"]
# This is required for proper CORS handling in browsers
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["*"],
    expose_headers=["*"],
    max_age=3600,
)

# GZip 압축 - JSON 응답 80%+ 압축, 네트워크 전송 대폭 감소
app.add_middleware(GZipMiddleware, minimum_size=1000)

# ============================================================
# Model Loading
# ============================================================

model: Optional[YOLO] = None


def load_model():
    """Load the YOLO model"""
    global model
    if model is None:
        if not Path(MODEL_PATH).exists():
            raise FileNotFoundError(f"Model not found: {MODEL_PATH}")
        model = YOLO(MODEL_PATH)
        print(f"Model loaded from: {MODEL_PATH}")
    return model


@app.on_event("startup")
async def startup_event():
    """서버 시작 - YOLO 모델은 Lazy Loading (첫 분류 요청 시 로드)"""
    global _ds_job_worker_task
    # EC2 메모리 절약: 시작 시 모델 로드 안 함 (~200MB 절약)
    # /predict, /predict/ensemble 첫 호출 시 자동 로드됨
    print("Server started successfully! (YOLO model: lazy load)")
    # DS 잡 테이블 자동 생성 (없으면) + stuck 잡 복구 + 워커 시작
    asyncio.create_task(_ensure_ds_jobs_table())
    asyncio.create_task(_recover_stuck_jobs())
    _ds_job_worker_task = asyncio.create_task(_job_worker_loop())
    print("DS job worker started")


# ============================================================
# Utility Functions
# ============================================================

def validate_image(file: UploadFile) -> bool:
    """Validate uploaded file is an image"""
    ext = Path(file.filename).suffix.lower()
    return ext in ALLOWED_EXTENSIONS


async def save_upload_file(file: UploadFile) -> Path:
    """Save uploaded file to temp directory"""
    ext = Path(file.filename).suffix.lower()
    unique_filename = f"{uuid.uuid4()}{ext}"
    file_path = UPLOAD_DIR / unique_filename

    with open(file_path, "wb") as buffer:
        content = await file.read()
        buffer.write(content)

    return file_path


def cleanup_file(file_path: Path):
    """Remove temporary file"""
    try:
        if file_path.exists():
            file_path.unlink()
    except Exception:
        pass


def decimal_to_native(obj):
    """DynamoDB Decimal 타입을 Python 기본 타입으로 변환 (JSON 직렬화용)"""
    if isinstance(obj, Decimal):
        if obj % 1 == 0:
            return int(obj)
        return float(obj)
    if isinstance(obj, dict):
        return {k: decimal_to_native(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [decimal_to_native(v) for v in obj]
    return obj


# ============================================================
# boto3 모듈 레벨 싱글턴 — 커넥션 풀 재사용 (요청마다 재생성 금지)
# boto3 client/resource는 thread-safe하므로 싱글턴 사용 안전
# ============================================================
_s3_client = boto3.client('s3', region_name=S3_REGION)
_dynamodb_resource = boto3.resource('dynamodb', region_name=S3_REGION)
_dynamodb_client = boto3.client('dynamodb', region_name=S3_REGION)


def get_s3_client():
    return _s3_client


def get_dynamodb_resource():
    return _dynamodb_resource


def get_dynamodb_client():
    return _dynamodb_client


def upload_to_s3(file_path: Path, s3_key: str) -> bool:
    """Upload file to S3 bucket"""
    try:
        s3_client = get_s3_client()
        s3_client.upload_file(
            str(file_path),
            S3_BUCKET_NAME,
            s3_key,
            ExtraArgs={
                'ContentType': 'image/jpeg'
            }
        )
        logger.info(f"Uploaded to S3: s3://{S3_BUCKET_NAME}/{s3_key}")
        return True
    except ClientError as e:
        logger.error(f"S3 upload failed: {e}")
        return False
    except Exception as e:
        logger.error(f"S3 upload error: {e}")
        return False


def predict_single_image(image_path: Path) -> dict:
    """Run prediction on a single image"""
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
    """Combine multiple predictions using ensemble method"""
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


# ============================================================
# API Endpoints
# ============================================================

@app.get("/", response_model=HealthResponse)
async def root():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "model_loaded": model is not None,
        "model_path": MODEL_PATH,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }


@app.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "model_loaded": model is not None,
        "model_path": MODEL_PATH,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }


@app.get("/classes", response_model=ClassListResponse)
async def get_classes():
    """Get list of all classification classes"""
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


@app.post("/predict", response_model=SinglePredictionResponse)
async def predict_single(
    file: UploadFile = File(..., description="Image file to classify"),
    conf_threshold: float = Query(0.5, ge=0.0, le=1.0, description="Confidence threshold")
):
    """
    Classify a single image

    - Upload one image
    - Returns prediction with confidence score
    """
    import time
    start_time = time.time()

    # Validate file
    if not validate_image(file):
        raise HTTPException(
            status_code=400,
            detail=f"Invalid file type. Allowed: {ALLOWED_EXTENSIONS}"
        )

    file_path = None
    try:
        # Save and process
        file_path = await save_upload_file(file)
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
        raise HTTPException(status_code=500, detail=str(e))

    finally:
        if file_path:
            cleanup_file(file_path)


@app.post("/predict/ensemble", response_model=EnsemblePredictionResponse)
async def predict_ensemble(
    files: List[UploadFile] = File(..., description="Multiple image files to classify"),
    method: str = Query("mean", regex="^(mean|max|vote)$", description="Ensemble method"),
    conf_threshold: float = Query(0.5, ge=0.0, le=1.0, description="Confidence threshold")
):
    """
    Classify multiple images and combine predictions

    - Upload multiple images (different angles of same tower)
    - Combines predictions using ensemble method
    - Methods: mean (average), max (maximum), vote (voting)
    """
    import time
    start_time = time.time()

    if len(files) < 1:
        raise HTTPException(status_code=400, detail="At least 1 image required")

    if len(files) > 10:
        raise HTTPException(status_code=400, detail="Maximum 10 images allowed")

    # Validate all files
    for file in files:
        if not validate_image(file):
            raise HTTPException(
                status_code=400,
                detail=f"Invalid file type: {file.filename}. Allowed: {ALLOWED_EXTENSIONS}"
            )

    file_paths = []
    predictions = []
    individual_results = []

    try:
        # Save and process each file
        for file in files:
            file_path = await save_upload_file(file)
            file_paths.append(file_path)

            result = predict_single_image(file_path)
            predictions.append(result)

            individual_results.append({
                "filename": file.filename,
                "prediction": result["class_name"],
                "prediction_kr": result["class_name_kr"],
                "confidence": round(result["confidence"], 4)
            })

        # Ensemble predictions
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
        raise HTTPException(status_code=500, detail=str(e))

    finally:
        for file_path in file_paths:
            cleanup_file(file_path)


@app.post("/feedback", response_model=FeedbackResponse)
async def submit_feedback(
    file: UploadFile = File(..., description="Image file"),
    original_class: str = Form(..., description="Original predicted class (English)"),
    corrected_class: str = Form(..., description="User-corrected class (English)")
):
    """
    Submit feedback for model improvement

    - User can correct classification results
    - Images are stored in S3 for future retraining
    - Storage path: feedback/{corrected_class}/{timestamp}_{filename}
    """
    # Validate file
    if not validate_image(file):
        raise HTTPException(
            status_code=400,
            detail=f"Invalid file type. Allowed: {ALLOWED_EXTENSIONS}"
        )

    # Validate class names
    valid_classes = list(CLASS_NAMES_KR.keys())
    if corrected_class not in valid_classes:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid corrected_class. Valid options: {valid_classes}"
        )

    file_path = None
    try:
        # Save uploaded file temporarily
        file_path = await save_upload_file(file)

        # Generate S3 key
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        original_filename = Path(file.filename).stem
        ext = Path(file.filename).suffix.lower()
        s3_key = f"feedback/{corrected_class}/{timestamp}_{original_filename}{ext}"

        # Upload to S3
        upload_success = upload_to_s3(file_path, s3_key)

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
            # S3 upload failed - save locally as fallback
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
        raise HTTPException(status_code=500, detail=str(e))

    finally:
        if file_path:
            cleanup_file(file_path)


@app.get("/feedback/stats")
async def get_feedback_stats():
    """
    Get feedback statistics

    - Shows count of feedback images per class
    - Useful for monitoring data collection progress
    """
    try:
        s3_client = get_s3_client()

        stats = {}
        for class_name in CLASS_NAMES_KR.keys():
            prefix = f"feedback/{class_name}/"
            try:
                response = s3_client.list_objects_v2(
                    Bucket=S3_BUCKET_NAME,
                    Prefix=prefix
                )
                count = response.get('KeyCount', 0)
                stats[class_name] = {
                    "count": count,
                    "class_name_kr": CLASS_NAMES_KR[class_name]
                }
            except ClientError:
                stats[class_name] = {
                    "count": 0,
                    "class_name_kr": CLASS_NAMES_KR[class_name],
                    "error": "S3 접근 실패"
                }

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
            "message": str(e),
            "timestamp": datetime.now(timezone.utc).isoformat()
        }


# ============================================================
# Auth Proxy Endpoint (CORS 우회용)
# ============================================================

SSO_LOGIN_URL = "https://auth.skons.net/accounts/sko/sso/login/"


@app.post("/auth/login")
async def proxy_sso_login(req: LoginRequest):
    """
    SKons SSO 로그인 프록시

    브라우저 CORS 제약 우회를 위해 서버에서 SSO 요청을 대신 수행합니다.
    """
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.post(
                SSO_LOGIN_URL,
                json={"username": req.username, "password": req.password},
                headers={"Content-Type": "application/json"},
            )
        return JSONResponse(
            status_code=response.status_code,
            content=response.json(),
        )
    except httpx.TimeoutException:
        return JSONResponse(
            status_code=504,
            content={"result": "fail", "message": "SSO 서버 응답 시간 초과"},
        )
    except Exception as e:
        logger.error(f"SSO proxy error: {e}")
        return JSONResponse(
            status_code=502,
            content={"result": "fail", "message": "SSO 서버 연결 실패"},
        )


@app.get("/users")
async def list_users_count():
    """사용자 데이터 통계"""
    users = load_users()
    return {
        "success": True,
        "total_users": len(users),
        "timestamp": datetime.now(timezone.utc).isoformat()
    }


# ============================================================
# DynamoDB CRUD Endpoints - Categories
# ============================================================

@app.post("/categories")
async def create_category(category: CategoryCreate):
    """카테고리 생성"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["categories"])

        now = datetime.now(timezone.utc).isoformat()
        item = {
            "id": str(uuid.uuid4()),
            "name": category.name,
            "owner": category.owner,
            "createdAt": now,
            "updatedAt": now,
        }
        if category.originalExcelKey:
            item["originalExcelKey"] = category.originalExcelKey

        table.put_item(Item=item)

        return {"success": True, "category": item}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/categories")
async def list_categories(owner: str = Query(..., description="소유자 사번")):
    """카테고리 목록 조회 (owner 필터)"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["categories"])

        # Scan with filter (GSI 없이 간단하게 처리)
        response = table.scan(
            FilterExpression="#owner = :owner",
            ExpressionAttributeNames={"#owner": "owner"},
            ExpressionAttributeValues={":owner": owner}
        )

        items = response.get("Items", [])

        # 페이지네이션 처리
        while "LastEvaluatedKey" in response:
            response = table.scan(
                FilterExpression="#owner = :owner",
                ExpressionAttributeNames={"#owner": "owner"},
                ExpressionAttributeValues={":owner": owner},
                ExclusiveStartKey=response["LastEvaluatedKey"]
            )
            items.extend(response.get("Items", []))

        return {"success": True, "categories": decimal_to_native(items), "count": len(items)}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/categories/{category_id}")
async def get_category(category_id: str):
    """카테고리 단일 조회"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["categories"])

        response = table.get_item(Key={"id": category_id})
        item = response.get("Item")

        if not item:
            raise HTTPException(status_code=404, detail="Category not found")

        return {"success": True, "category": decimal_to_native(item)}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.put("/categories/{category_id}")
async def update_category(category_id: str, name: str = None, originalExcelKey: str = None):
    """카테고리 업데이트"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["categories"])

        update_expr = "SET updatedAt = :now"
        expr_values = {":now": datetime.now(timezone.utc).isoformat()}

        if name:
            update_expr += ", #n = :name"
            expr_values[":name"] = name
        if originalExcelKey:
            update_expr += ", originalExcelKey = :key"
            expr_values[":key"] = originalExcelKey

        update_kwargs = {
            "Key": {"id": category_id},
            "UpdateExpression": update_expr,
            "ExpressionAttributeValues": expr_values,
            "ReturnValues": "ALL_NEW",
        }
        if name:
            update_kwargs["ExpressionAttributeNames"] = {"#n": "name"}

        response = table.update_item(**update_kwargs)

        return {"success": True, "category": decimal_to_native(response.get("Attributes"))}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/categories/{category_id}")
async def delete_category(category_id: str):
    """카테고리 삭제"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["categories"])

        table.delete_item(Key={"id": category_id})

        return {"success": True, "message": "Category deleted"}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# ============================================================
# DynamoDB CRUD Endpoints - Stations
# ============================================================

@app.post("/stations")
async def create_station(station: StationCreate):
    """무선국 생성"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["stations"])

        now = datetime.now(timezone.utc).isoformat()
        item = {
            "id": str(uuid.uuid4()),
            "categoryId": station.categoryId,
            "owner": station.owner,
            "stationName": station.stationName,
            "address": station.address,
            "isInspected": station.isInspected,
            "createdAt": now,
            "updatedAt": now,
        }

        # Optional fields
        optional_fields = [
            "licenseNumber", "latitude", "longitude", "callSign", "gain",
            "antennaCount", "remarks", "typeApprovalNumber", "frequency",
            "stationType", "stationOwner", "installationType", "inspectionStatus",
            "inspectionDate", "memo", "photoKeys"
        ]
        for field in optional_fields:
            value = getattr(station, field)
            if value is not None:
                # DynamoDB는 Python float를 지원하지 않으므로 Decimal로 변환
                if isinstance(value, float):
                    item[field] = Decimal(str(value))
                else:
                    item[field] = value

        table.put_item(Item=item)

        return {"success": True, "station": decimal_to_native(item)}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/stations")
async def list_stations(
    owner: str = Query(..., description="소유자 사번"),
    categoryId: str = Query(None, description="카테고리 ID (선택)")
):
    """무선국 목록 조회"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["stations"])

        filter_expr = "#owner = :owner"
        expr_names = {"#owner": "owner"}
        expr_values = {":owner": owner}

        if categoryId:
            filter_expr += " AND categoryId = :catId"
            expr_values[":catId"] = categoryId

        response = table.scan(
            FilterExpression=filter_expr,
            ExpressionAttributeNames=expr_names,
            ExpressionAttributeValues=expr_values
        )

        items = response.get("Items", [])

        while "LastEvaluatedKey" in response:
            response = table.scan(
                FilterExpression=filter_expr,
                ExpressionAttributeNames=expr_names,
                ExpressionAttributeValues=expr_values,
                ExclusiveStartKey=response["LastEvaluatedKey"]
            )
            items.extend(response.get("Items", []))

        return {"success": True, "stations": decimal_to_native(items), "count": len(items)}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/stations/{station_id}")
async def get_station(station_id: str):
    """무선국 단일 조회"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["stations"])

        response = table.get_item(Key={"id": station_id})
        item = response.get("Item")

        if not item:
            raise HTTPException(status_code=404, detail="Station not found")

        return {"success": True, "station": decimal_to_native(item)}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.put("/stations/{station_id}")
async def update_station(station_id: str, station: StationUpdate):
    """무선국 업데이트"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["stations"])

        update_expr = "SET updatedAt = :now"
        expr_values = {":now": datetime.now(timezone.utc).isoformat()}
        expr_names = {}

        # DynamoDB reserved keywords
        reserved_words = {"name", "owner", "status", "address", "comment", "type", "key", "value", "data", "source", "role", "user", "size", "time", "date"}

        update_fields = station.dict(exclude_unset=True)
        for field, value in update_fields.items():
            if value is not None:
                # DynamoDB는 Python float를 지원하지 않으므로 Decimal로 변환
                if isinstance(value, float):
                    value = Decimal(str(value))
                if field.lower() in reserved_words:
                    alias = f"#{field}"
                    expr_names[alias] = field
                    update_expr += f", {alias} = :{field}"
                else:
                    update_expr += f", {field} = :{field}"
                expr_values[f":{field}"] = value

        update_kwargs = {
            "Key": {"id": station_id},
            "UpdateExpression": update_expr,
            "ExpressionAttributeValues": expr_values,
            "ReturnValues": "ALL_NEW",
        }
        if expr_names:
            update_kwargs["ExpressionAttributeNames"] = expr_names

        response = table.update_item(**update_kwargs)

        return {"success": True, "station": decimal_to_native(response.get("Attributes"))}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/stations/{station_id}")
async def delete_station(station_id: str):
    """무선국 삭제"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["stations"])

        table.delete_item(Key={"id": station_id})

        return {"success": True, "message": "Station deleted"}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# ============================================================
# S3 Upload/Download Endpoints
# ============================================================

@app.post("/upload/photo")
async def upload_photo(
    file: UploadFile = File(...),
    owner: str = Form(...),
    stationId: str = Form(...)
):
    """사진 S3 업로드"""
    if not validate_image(file):
        raise HTTPException(status_code=400, detail="Invalid image format")

    try:
        s3_client = get_s3_client()

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        ext = Path(file.filename).suffix.lower()
        s3_key = f"photos/{owner}/{stationId}/{timestamp}{ext}"

        content = await file.read()
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=s3_key,
            Body=content,
            ContentType=file.content_type
        )

        return {"success": True, "key": s3_key}
    except ClientError as e:
        logger.error(f"S3 upload error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/upload/excel")
async def upload_excel(
    file: UploadFile = File(...),
    owner: str = Form(...),
    categoryName: str = Form(...)
):
    """원본 Excel S3 업로드"""
    if not file.filename.endswith(('.xlsx', '.xls')):
        raise HTTPException(status_code=400, detail="Invalid Excel format")

    try:
        s3_client = get_s3_client()

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        safe_name = categoryName.replace("/", "_").replace("\\", "_")
        s3_key = f"excel/{owner}/{safe_name}_{timestamp}.xlsx"

        content = await file.read()
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=s3_key,
            Body=content,
            ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )

        return {"success": True, "key": s3_key}
    except ClientError as e:
        logger.error(f"S3 upload error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/download/presigned")
async def get_presigned_url(key: str = Query(..., description="S3 object key")):
    """S3 Presigned URL 생성 (다운로드용)"""
    try:
        s3_client = get_s3_client()

        url = s3_client.generate_presigned_url(
            'get_object',
            Params={'Bucket': S3_BUCKET_NAME, 'Key': key},
            ExpiresIn=3600  # 1시간
        )

        return {"success": True, "url": url, "expires_in": 3600}
    except ClientError as e:
        logger.error(f"Presigned URL error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/download/photo")
async def download_photo(key: str = Query(..., description="S3 object key")):
    """S3 이미지를 EC2 경유로 스트리밍 (CORS 우회)"""
    try:
        s3_client = get_s3_client()
        response = s3_client.get_object(Bucket=S3_BUCKET_NAME, Key=key)

        # Content-Type 추정
        content_type = response.get("ContentType", "image/jpeg")
        if key.lower().endswith(".png"):
            content_type = "image/png"
        elif key.lower().endswith(".webp"):
            content_type = "image/webp"
        elif key.lower().endswith(".gif"):
            content_type = "image/gif"

        return StreamingResponse(
            response["Body"],
            media_type=content_type,
            headers={
                "Cache-Control": "public, max-age=86400",
            },
        )
    except ClientError as e:
        logger.error(f"S3 download error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/storage/{key:path}")
async def delete_s3_object(key: str):
    """S3 객체 삭제"""
    try:
        s3_client = get_s3_client()
        s3_client.delete_object(Bucket=S3_BUCKET_NAME, Key=key)
        return {"success": True, "message": f"Deleted: {key}"}
    except ClientError as e:
        logger.error(f"S3 delete error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# ============================================================
# DynamoDB Users (i-NET 사용자 - 기존 테이블 사용)
# ============================================================

@app.get("/users/{empno}")
async def get_user_by_empno(empno: str):
    """
    사번으로 사용자 정보 조회 (DynamoDB)

    기존 i-NET 사용자 테이블에서 조회
    """
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["users"])

        # user_id가 PK
        response = table.get_item(Key={"user_id": empno})
        user = response.get("Item")

        if not user:
            return {"success": False, "empno": empno, "message": "User not found"}

        return {
            "success": True,
            "empno": empno,
            "name": user.get("name"),
            "region": user.get("region"),
            "team": user.get("team"),
            "email": user.get("email"),
            "phone": user.get("phone_number"),
        }
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        # Fallback to JSON file
        users = load_users()
        user = users.get(empno)
        if user:
            return {
                "success": True,
                "empno": empno,
                "name": user.get("name"),
                "region": user.get("region"),
                "team": user.get("DeptName"),
            }
        return {"success": False, "empno": empno}


# ============================================================
# DS Data Upload/Query Endpoints
# ============================================================

@app.get("/ds/region-codes")
async def ds_region_codes():
    """DS 지역코드 매핑 조회"""
    return {"success": True, "codes": DS_REGION_CODE_MAP}


# ============================================================
# DS S3 xlsx 로컬 캐시 — /ds/data 조회 시 반복 S3 다운로드 방지
# ============================================================
DS_CACHE_DIR = "/tmp/ds_cache"
DS_CACHE_TTL = 3600  # 1시간


def _get_cache_path(division_id: str, division_code: str, import_date: str, ext: str = "xlsx") -> str:
    """캐시 파일 경로 반환 (ext: 'xlsx' 또는 'zip')"""
    return os.path.join(DS_CACHE_DIR, division_id, f"{division_code}_{import_date}.{ext}")


def _get_cached_file(division_id: str, division_code: str, import_date: str, ext: str = "xlsx") -> Optional[str]:
    """TTL 내 캐시 파일 존재하면 경로 반환, 아니면 None"""
    path = _get_cache_path(division_id, division_code, import_date, ext)
    if os.path.exists(path):
        import time
        age = time.time() - os.path.getmtime(path)
        if age < DS_CACHE_TTL:
            return path
        try:
            os.remove(path)
        except Exception:
            pass
    return None


# 하위호환 별칭
def _get_cached_xlsx(division_id: str, division_code: str, import_date: str) -> Optional[str]:
    return _get_cached_file(division_id, division_code, import_date, "xlsx")


def _evict_cache(division_id: str, division_code: str, import_date: str):
    """캐시 파일 삭제 (xlsx + zip 모두)"""
    for ext in ("xlsx", "zip"):
        path = _get_cache_path(division_id, division_code, import_date, ext)
        try:
            if os.path.exists(path):
                os.remove(path)
        except Exception:
            pass


def _delete_ds_records_targeted(records_table, uploads_table, divisionId: str, importDate: str, divisionCode: str, sheet_names: list = None) -> int:
    """
    시트별 SK 프리픽스 정밀 쿼리로 레코드 삭제
    - 각 시트를 별도 스레드에서 병렬 처리 (최대 5개 동시)
    - 스레드별 독립 DynamoDB 세션 (thread-safe)
    - 1.8M행 기준: 직렬 ~6분 → 병렬 ~40초
    - FilterExpression 전체 스캔 완전 제거 (OOM 방지)
    - sheet_names를 직접 전달하면 uploads_table 조회 생략 (삭제 후 호출 시 필수)
    """
    dc_part = f"#{divisionCode}" if divisionCode else ""
    upload_sk = f"{divisionCode}#{importDate}" if divisionCode else importDate

    # sheet_names가 None이면 uploads_table에서 조회 (재업로드 경로)
    # ds_delete_data는 uploads 삭제 후 호출되므로 반드시 sheet_names를 직접 전달해야 함
    if sheet_names is None:
        try:
            resp = uploads_table.get_item(Key={"divisionId": divisionId, "importDate": upload_sk})
            item = resp.get("Item", {})
            sheet_names = list(item.get("sheetStats", {}).keys())
        except Exception:
            pass

    if not sheet_names:
        return 0  # 데이터 없음 → 스킵 (OOM 방지)

    def _delete_one_sheet(sheet_name: str) -> int:
        """단일 시트 삭제 - 스레드별 독립 DynamoDB 세션 사용"""
        # boto3는 기본 session이 thread-safe하지 않으므로 스레드별 신규 session 생성
        session = boto3.session.Session()
        _table = session.resource("dynamodb", region_name=S3_REGION).Table(DYNAMODB_TABLES["ds_records"])

        sk_prefix = f"{sheet_name}#{importDate}{dc_part}#"
        deleted = 0
        last_key = None
        while True:
            kwargs = {
                "KeyConditionExpression": "divisionId = :did AND begins_with(sk, :skp)",
                "ExpressionAttributeValues": {":did": divisionId, ":skp": sk_prefix},
                "ProjectionExpression": "divisionId, sk",
                "Limit": 1000,
            }
            if last_key:
                kwargs["ExclusiveStartKey"] = last_key

            response = _table.query(**kwargs)
            items = response.get("Items", [])

            if items:
                with _table.batch_writer() as batch:
                    for item in items:
                        batch.delete_item(Key={"divisionId": item["divisionId"], "sk": item["sk"]})
                        deleted += 1
                items = None

            last_key = response.get("LastEvaluatedKey")
            if not last_key:
                break
        return deleted

    # 시트 병렬 삭제 (최대 5개 동시, DynamoDB 처리량 고려)
    total_deleted = 0
    max_workers = min(len(sheet_names), 5)
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(_delete_one_sheet, sn): sn for sn in sheet_names}
        for future in as_completed(futures):
            try:
                total_deleted += future.result()
            except Exception as e:
                logger.error(f"Sheet deletion error [{futures[future]}]: {e}")

    return total_deleted


async def _background_delete_records(divisionId: str, importDate: str, divisionCode: str, sheet_names: list = None):
    """백그라운드 레코드 삭제 - asyncio.to_thread으로 이벤트 루프 블로킹 없이 실행
    sheet_names를 직접 받아야 uploads 삭제 후에도 정상 동작함"""
    try:
        dynamodb = get_dynamodb_resource()
        records_table = dynamodb.Table(DYNAMODB_TABLES["ds_records"])
        uploads_table = dynamodb.Table(DYNAMODB_TABLES["ds_uploads"])
        deleted = await asyncio.to_thread(
            _delete_ds_records_targeted, records_table, uploads_table, divisionId, importDate, divisionCode, sheet_names
        )
        logger.info(f"Background delete complete: {divisionId}/{divisionCode}_{importDate} - {deleted} records")
    except Exception as e:
        logger.error(f"Background delete error [{divisionId}/{divisionCode}_{importDate}]: {e}")


# ============================================================
# DS 서버사이드 처리 — 잡 큐 + 백그라운드 워커
# S3 ZIP → xlrd → DynamoDB → openpyxl xlsx → S3
# ============================================================

async def _ensure_ds_jobs_table():
    """kca-ds-jobs 테이블이 없으면 자동 생성"""
    await asyncio.sleep(1)
    try:
        dynamodb_client = get_dynamodb_client()
        dynamodb_client.create_table(
            TableName=DYNAMODB_TABLES["ds_jobs"],
            KeySchema=[{"AttributeName": "jobId", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "jobId", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        logger.info(f"DynamoDB table {DYNAMODB_TABLES['ds_jobs']} created")
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceInUseException":
            logger.warning(f"DS jobs table creation error (non-fatal): {e}")


def _parse_ds_filename_in_zip(filename: str) -> Optional[dict]:
    """파일명에서 divisionCode와 importDate 추출
    예: 경남DS(20)20260115.xls → {divisionCode:'20', importDate:'20260115'}
    """
    region_match = re.search(r'\((\d+)\)', filename)
    date_match = re.search(r'(\d{8})', filename)
    if not region_match or not date_match:
        return None
    return {
        "divisionCode": region_match.group(1),
        "importDate": date_match.group(1),
    }


def _classify_ds_file(filename: str) -> str:
    """DS 파일 분류: base / numbered / spt / skipped"""
    lower = filename.lower()
    if "(100)" in filename:
        return "skipped"
    if "특수" in filename or "spt" in lower:
        return "spt"
    paren_numbers = re.findall(r"\(\d+\)", filename)
    if len(paren_numbers) >= 2:
        return "numbered"
    return "base"


def _update_job_progress_sync(job_id: str, stage: str, percent: float,
                               processed_rows: int = 0, total_rows: int = 0):
    """동기: DynamoDB job 진행상황 업데이트"""
    try:
        jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])
        jobs_table.update_item(
            Key={"jobId": job_id},
            UpdateExpression="SET stage=:s, #p=:p, processedRows=:pr, totalRows=:tr",
            ExpressionAttributeNames={"#p": "percent"},
            ExpressionAttributeValues={
                ":s": stage,
                ":p": Decimal(str(round(percent, 1))),
                ":pr": processed_rows,
                ":tr": total_rows,
            },
        )
    except Exception as e:
        logger.warning(f"Job progress update failed ({job_id}): {e}")


async def _update_job_progress(job_id: str, stage: str, percent: float,
                                processed_rows: int = 0, total_rows: int = 0):
    """비동기: DynamoDB job 진행상황 업데이트"""
    await asyncio.to_thread(
        _update_job_progress_sync, job_id, stage, percent, processed_rows, total_rows
    )


def _mark_job_processing_sync(job_id: str):
    """동기: 잡 상태를 processing으로 변경"""
    jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])
    now = datetime.now(timezone.utc).isoformat()
    jobs_table.update_item(
        Key={"jobId": job_id},
        UpdateExpression="SET #s=:s, startedAt=:sa, stage=:g, #p=:p",
        ExpressionAttributeNames={"#s": "status", "#p": "percent"},
        ExpressionAttributeValues={
            ":s": "processing",
            ":sa": now,
            ":g": "처리 시작...",
            ":p": Decimal("0"),
        },
    )


def _mark_job_done_sync(job_id: str, division_id: str, division_code: str,
                         import_date: str, sheet_stats: dict, total_rows: int):
    """동기: 잡 완료 처리"""
    jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])
    now = datetime.now(timezone.utc).isoformat()
    jobs_table.update_item(
        Key={"jobId": job_id},
        UpdateExpression=(
            "SET #s=:s, completedAt=:ca, stage=:g, #p=:p, "
            "divisionId=:did, divisionCode=:dc, importDate=:idate, "
            "sheetStats=:ss, totalRows=:tr"
        ),
        ExpressionAttributeNames={"#s": "status", "#p": "percent"},
        ExpressionAttributeValues={
            ":s": "completed",
            ":ca": now,
            ":g": "완료",
            ":p": Decimal("100"),
            ":did": division_id,
            ":dc": division_code,
            ":idate": import_date,
            ":ss": {k: v for k, v in sheet_stats.items()},
            ":tr": total_rows,
        },
    )


def _mark_job_failed_sync(job_id: str, error: str):
    """동기: 잡 실패 처리"""
    jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])
    now = datetime.now(timezone.utc).isoformat()
    jobs_table.update_item(
        Key={"jobId": job_id},
        UpdateExpression="SET #s=:s, completedAt=:ca, stage=:g, #e=:e",
        ExpressionAttributeNames={"#s": "status", "#e": "error"},
        ExpressionAttributeValues={
            ":s": "failed",
            ":ca": now,
            ":g": "실패",
            ":e": error[:500],
        },
    )


async def _recover_stuck_jobs():
    """서버 시작 시 processing 상태 잡을 queued로 복구"""
    await asyncio.sleep(3)
    try:
        jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])
        resp = jobs_table.scan(
            FilterExpression="#s = :s",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": "processing"},
        )
        stuck_jobs = resp.get("Items", [])
        for job in stuck_jobs:
            job_id = job["jobId"]
            jobs_table.update_item(
                Key={"jobId": job_id},
                UpdateExpression="SET #s=:s, stage=:g",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":s": "queued", ":g": "재시작 대기 중..."},
            )
            logger.info(f"Recovered stuck DS job: {job_id}")
        if stuck_jobs:
            logger.info(f"DS job recovery: {len(stuck_jobs)}개 잡 복구 완료")
    except Exception as e:
        logger.warning(f"DS job recovery error (non-fatal): {e}")


async def _get_next_queued_job() -> Optional[dict]:
    """큐에서 다음 잡 가져오기 (FIFO: queuedAt 기준)
    페이지네이션으로 전체 테이블을 확인 — 완료/실패 잡이 많아도 누락 없음
    """
    try:
        jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])

        def _scan_all_queued():
            queued = []
            last_key = None
            while True:
                kwargs = {
                    "FilterExpression": "#s = :s",
                    "ExpressionAttributeNames": {"#s": "status"},
                    "ExpressionAttributeValues": {":s": "queued"},
                    "ProjectionExpression": "jobId, queuedAt, s3Key, fileName, uploadedBy, #s",
                    "Limit": 100,
                }
                if last_key:
                    kwargs["ExclusiveStartKey"] = last_key
                resp = jobs_table.scan(**kwargs)
                queued.extend(resp.get("Items", []))
                if queued:
                    break  # 1개라도 찾으면 즉시 반환 (추가 스캔 불필요)
                last_key = resp.get("LastEvaluatedKey")
                if not last_key:
                    break
            return queued

        items = await asyncio.to_thread(_scan_all_queued)
        if not items:
            return None
        items.sort(key=lambda x: x.get("queuedAt", ""))
        return items[0]
    except Exception as e:
        logger.error(f"Get next queued job error: {e}")
        return None


def _xlrd_cell_to_str(sheet, row_idx: int, col_idx: int) -> str:
    """xlrd 셀 값을 문자열로 변환"""
    cell_type = sheet.cell_type(row_idx, col_idx)
    # 0=EMPTY, 5=ERROR, 6=BLANK → 빈 문자열
    if cell_type in (0, 5, 6):
        return ""
    val = sheet.cell_value(row_idx, col_idx)
    # NUMBER(2) → 정수면 int, 아니면 float 문자열
    if cell_type == 2:
        if isinstance(val, float) and val == int(val):
            return str(int(val))
        return str(val)
    # BOOLEAN(4)
    if cell_type == 4:
        return "True" if val else "False"
    return str(val).strip()


def _process_xls_file_sync(xls_bytes: bytes, filename: str, division_id: str,
                             division_code: str, import_date: str,
                             base_row_counts: dict) -> tuple:
    """동기: XLS 바이트 → DynamoDB batch write
    base_row_counts: {sheet_name: current_row_count} — numbered 파일 병합 시 연속 인덱스
    Returns: (sheet_stats, total_rows_written, sheet_headers)
    sheet_headers: {sheet_name: [col1, col2, ...]} — 원본 XLS 헤더 순서 그대로
    """
    if not HAS_XLRD:
        raise RuntimeError("xlrd not installed on server")

    sheet_stats = {}
    sheet_headers: Dict[str, list] = {}
    total_rows = 0
    records_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_records"])
    now = datetime.now(timezone.utc).isoformat()
    dc_part = f"#{division_code}" if division_code else ""

    try:
        workbook = xlrd.open_workbook(file_contents=xls_bytes)
    except Exception as e:
        logger.warning(f"XLS 파싱 실패 ({filename}): {e}")
        return {}, 0, {}

    for sheet_idx in range(workbook.nsheets):
        sheet = workbook.sheet_by_index(sheet_idx)
        sheet_name = sheet.name.strip()

        if sheet.nrows < 2:
            continue

        # 헤더 추출 — 실제 컬럼 인덱스 보존 (빈 헤더 건너뛰되 위치 기억)
        header_map = []  # [(actual_col_idx, header_name), ...]
        for col in range(sheet.ncols):
            h = _xlrd_cell_to_str(sheet, 0, col)
            if h:
                header_map.append((col, h))
        headers = [name for _, name in header_map]

        if not headers:
            continue

        # 첫 등장 시트의 헤더만 기록 (base 파일 헤더가 기준)
        if sheet_name not in sheet_headers:
            sheet_headers[sheet_name] = list(headers)

        # numbered 파일 병합: 이전 파일의 마지막 rowIndex부터 이어서 번호 부여
        start_row_idx = base_row_counts.get(sheet_name, 0)
        row_count = 0

        with records_table.batch_writer() as batch:
            for row_idx in range(1, sheet.nrows):
                data = {}
                for col_idx, hname in header_map:
                    val = _xlrd_cell_to_str(sheet, row_idx, col_idx)
                    if val:
                        data[hname] = val

                if not data:
                    continue

                global_row_idx = start_row_idx + row_count
                batch.put_item(Item={
                    "divisionId": division_id,
                    "sk": f"{sheet_name}#{import_date}{dc_part}#{global_row_idx:08d}",
                    "sheetName": sheet_name,
                    "importDate": import_date,
                    "divisionCode": division_code,
                    "uploadedAt": now,
                    "data": data,
                })
                row_count += 1

        sheet_stats[sheet_name] = row_count
        total_rows += row_count
        # 다음 파일을 위해 시작 인덱스 업데이트
        base_row_counts[sheet_name] = start_row_idx + row_count

    workbook.release_resources()
    gc.collect()  # workbook 전체 해제 후 1회만 실행
    return sheet_stats, total_rows, sheet_headers


async def _process_zip_to_dynamodb(job_id: str, zip_temp_path: str,
                                    division_id: str, division_code: str,
                                    import_date: str) -> tuple:
    """ZIP 파일 → XLS 파싱 → DynamoDB 저장
    Returns: (sheet_stats, total_rows, sheet_headers)
    sheet_headers: {sheet_name: [col1, col2, ...]} — base 파일 헤더 순서 기준
    """
    sheet_stats: Dict[str, int] = {}
    sheet_headers: Dict[str, list] = {}
    total_rows = 0
    base_row_counts: Dict[str, int] = {}

    with zipfile.ZipFile(zip_temp_path, "r") as zf:
        all_names = zf.namelist()
        xls_names = [n for n in all_names
                     if n.lower().endswith(".xls") and not os.path.basename(n).startswith("~")]

        classified: Dict[str, list] = {"base": [], "numbered": [], "spt": [], "skipped": []}
        for fname in xls_names:
            base_fname = os.path.basename(fname)
            if not base_fname:
                continue
            cls = _classify_ds_file(base_fname)
            classified[cls].append(fname)

        process_list = classified["base"] + classified["numbered"] + classified["spt"]
        total_files = len(process_list)

        if total_files == 0:
            raise ValueError("처리할 XLS 파일 없음 (스킵 파일만 포함)")

        logger.info(f"DS job {job_id}: {total_files}개 XLS 처리 "
                    f"(base={len(classified['base'])}, numbered={len(classified['numbered'])}, "
                    f"spt={len(classified['spt'])}, skipped={len(classified['skipped'])})")

        # 프로그레스 스로틀: 5% 이상 변화 또는 첫/마지막 파일에서만 DynamoDB 업데이트
        # 기존: 파일마다 UpdateItem → 파일 N개일 때 N회 불필요한 DynamoDB 쓰기
        last_progress_pct = 0.0

        for file_idx, fname in enumerate(process_list):
            base_fname = os.path.basename(fname) or fname
            percent = 10 + (file_idx / total_files) * 70
            if percent - last_progress_pct >= 5 or file_idx in (0, total_files - 1):
                await _update_job_progress(job_id, f"XLS 파싱: {base_fname}", percent, total_rows, total_rows)
                last_progress_pct = percent

            try:
                xls_bytes = zf.read(fname)
            except Exception as e:
                logger.warning(f"DS job {job_id}: {fname} 읽기 실패: {e}")
                continue

            try:
                file_sheet_stats, file_rows, file_sheet_headers = await asyncio.to_thread(
                    _process_xls_file_sync, xls_bytes, base_fname,
                    division_id, division_code, import_date, base_row_counts
                )
            except Exception as e:
                logger.warning(f"DS job {job_id}: {fname} 처리 실패: {e}")
                del xls_bytes
                continue

            del xls_bytes  # xlrd workbook은 이미 release_resources() 호출됨

            for sn, cnt in file_sheet_stats.items():
                sheet_stats[sn] = sheet_stats.get(sn, 0) + cnt
            # base 파일 헤더 우선 (첫 등장 시트만 기록)
            for sn, hdrs in file_sheet_headers.items():
                if sn not in sheet_headers:
                    sheet_headers[sn] = hdrs
            total_rows += file_rows
            logger.info(f"DS job {job_id}: [{file_idx+1}/{total_files}] {base_fname} → {file_rows}행")

    return sheet_stats, total_rows, sheet_headers


def _read_xlsx_paginated_sync(xlsx_path: str, sheet_name: str,
                               division_id: str, import_date: str,
                               division_code: str, offset: int = 0,
                               limit: int = 100, search: Optional[str] = None) -> dict:
    """S3 xlsx에서 페이지네이션 읽기 — GET /ds/data 응답 형식과 100% 동일
    DynamoDB 경로와 동일한 응답 → 프론트엔드 수정 불필요
    """
    if not HAS_OPENPYXL:
        raise RuntimeError("openpyxl not installed on server")

    try:
        wb = openpyxl.load_workbook(xlsx_path, read_only=True, data_only=True)
    except Exception as e:
        logger.warning(f"DS xlsx read failed ({xlsx_path}): {e}")
        return {"success": True, "items": [], "count": 0, "lastEvaluatedKey": None}

    # 시트 찾기
    if sheet_name not in wb.sheetnames:
        wb.close()
        return {"success": True, "items": [], "count": 0, "lastEvaluatedKey": None}

    ws = wb[sheet_name]
    dc_part = f"#{division_code}" if division_code else ""

    try:
        # 헤더 읽기 (첫 행)
        headers = []
        rows_iter = ws.iter_rows()
        header_row = next(rows_iter, None)
        if not header_row:
            wb.close()
            return {"success": True, "items": [], "count": 0, "lastEvaluatedKey": None}
        # 헤더 셀을 위치 기반으로 읽기 (None 셀도 포함하여 컬럼 위치 보존)
        headers = []
        for cell in header_row:
            v = cell.value
            if v is not None and str(v).strip():
                headers.append(str(v).strip())
            else:
                break  # 연속된 헤더 영역 끝
        num_cols = len(headers)

        items = []
        row_idx = 0  # 0-based data row index

        if search:
            # 검색 모드: 전체 순회 + case-insensitive 필터
            search_lower = search.lower()
            scanned = 0
            for row in rows_iter:
                vals = [str(cell.value or "") for cell in row[:num_cols]]
                data = {}
                for i, h in enumerate(headers):
                    if i < len(vals) and vals[i]:
                        data[h] = vals[i]

                if not data:
                    row_idx += 1
                    continue

                # 검색 필터 (현재 DynamoDB 검색과 동일 로직)
                if any(search_lower in str(v).lower() for v in data.values()):
                    if scanned >= offset:
                        items.append({
                            "divisionId": division_id,
                            "sk": f"{sheet_name}#{import_date}{dc_part}#{row_idx:08d}",
                            "sheetName": sheet_name,
                            "importDate": import_date,
                            "divisionCode": division_code,
                            "data": data,
                        })
                        if len(items) >= limit:
                            row_idx += 1
                            break
                    scanned += 1
                row_idx += 1

            next_offset = offset + len(items)
            # 더 있는지 확인: 남은 행에서 검색 매치 존재 여부
            has_more = False
            if len(items) >= limit:
                for row in rows_iter:
                    vals = [str(cell.value or "") for cell in row[:num_cols]]
                    if any(search_lower in str(v).lower() for v in vals if v):
                        has_more = True
                        break
        else:
            # 일반 페이징: offset까지 skip → limit개 읽기
            for row in rows_iter:
                if row_idx < offset:
                    row_idx += 1
                    continue
                if len(items) >= limit:
                    break

                vals = [str(cell.value or "") for cell in row[:num_cols]]
                data = {}
                for i, h in enumerate(headers):
                    if i < len(vals) and vals[i]:
                        data[h] = vals[i]

                if data:
                    items.append({
                        "divisionId": division_id,
                        "sk": f"{sheet_name}#{import_date}{dc_part}#{row_idx:08d}",
                        "sheetName": sheet_name,
                        "importDate": import_date,
                        "divisionCode": division_code,
                        "data": data,
                    })
                row_idx += 1

            next_offset = offset + len(items)
            # 다음 행 존재 여부
            has_more = next(rows_iter, None) is not None

        wb.close()

        last_key = None
        if has_more and len(items) >= limit:
            last_key = json.dumps({"_xlsOffset": next_offset})

        return {
            "success": True,
            "items": items,
            "count": len(items),
            "lastEvaluatedKey": last_key,
        }
    except Exception as e:
        wb.close()
        logger.error(f"DS xlsx paginated read error: {e}")
        return {"success": True, "items": [], "count": 0, "lastEvaluatedKey": None}


def _parse_zip_metadata_sync(zip_temp_path: str, progress_cb=None) -> tuple:
    """ZIP → 메타데이터만 초고속 파싱 (xlsx 빌드 완전 생략)

    XLS 파일별로 xlrd.open_workbook → sheet.nrows + 헤더(row 0) 만 추출.
    데이터 행은 한 줄도 읽지 않음 → 10만행 ZIP도 ~5초.

    Returns: (sheet_stats, total_rows, sheet_headers, file_manifest)
      sheet_stats:   {sheet_name: row_count}
      total_rows:    전체 행수
      sheet_headers: {sheet_name: [col1, col2, ...]}
      file_manifest: {sheet_name: [{"f": filename, "r": row_count}, ...]}
        → 데이터 조회 시 어느 XLS 파일에서 몇 행을 읽을지 결정하는 데 사용
    """
    if not HAS_XLRD:
        raise RuntimeError("xlrd not installed on server")

    sheet_stats: Dict[str, int] = {}
    sheet_headers: Dict[str, list] = {}
    file_manifest: Dict[str, list] = {}  # {sheet_name: [{"f": fname, "r": rows}, ...]}
    total_rows = 0

    with zipfile.ZipFile(zip_temp_path, "r") as zf:
        all_names = zf.namelist()
        xls_names = [n for n in all_names
                     if n.lower().endswith(".xls") and not os.path.basename(n).startswith("~")]

        classified: Dict[str, list] = {"base": [], "numbered": [], "spt": [], "skipped": []}
        for fname in xls_names:
            base_fname = os.path.basename(fname)
            if not base_fname:
                continue
            cls = _classify_ds_file(base_fname)
            classified[cls].append(fname)

        process_list = classified["base"] + classified["numbered"] + classified["spt"]
        if not process_list:
            raise ValueError("처리할 XLS 파일 없음 (스킵 파일만 포함)")

        logger.info(f"DS metadata parse: {len(process_list)}개 XLS "
                    f"(base={len(classified['base'])}, numbered={len(classified['numbered'])}, "
                    f"spt={len(classified['spt'])}, skipped={len(classified['skipped'])})")

        total_files = len(process_list)
        for file_idx, fname in enumerate(process_list):
            base_fname = os.path.basename(fname) or fname

            if progress_cb and (file_idx % 5 == 0 or file_idx == total_files - 1):
                pct = 10 + (file_idx / total_files) * 60
                progress_cb(f"메타데이터 파싱 중... ({file_idx+1}/{total_files})", pct)

            try:
                xls_bytes = zf.read(fname)
            except Exception as e:
                logger.warning(f"DS metadata: {fname} 읽기 실패: {e}")
                continue

            try:
                workbook = xlrd.open_workbook(file_contents=xls_bytes)
            except Exception as e:
                logger.warning(f"DS metadata: XLS 파싱 실패 ({base_fname}): {e}")
                del xls_bytes
                continue

            file_rows = 0
            for sheet_idx in range(workbook.nsheets):
                sheet = workbook.sheet_by_index(sheet_idx)
                sheet_name = sheet.name.strip()
                if sheet.nrows < 2:
                    continue

                data_rows = sheet.nrows - 1  # 헤더 행 제외

                # 첫 등장 시트: 헤더 추출
                if sheet_name not in sheet_headers:
                    header_map = []
                    for col in range(sheet.ncols):
                        h = _xlrd_cell_to_str(sheet, 0, col)
                        if h:
                            header_map.append((col, h))
                    if not header_map:
                        continue
                    sheet_headers[sheet_name] = [name for _, name in header_map]
                    sheet_stats[sheet_name] = 0
                    file_manifest[sheet_name] = []

                sheet_stats[sheet_name] += data_rows
                file_manifest[sheet_name].append({"f": fname, "r": data_rows})
                file_rows += data_rows

            workbook.release_resources()
            del xls_bytes
            total_rows += file_rows

    logger.info(f"DS metadata parse 완료: {total_rows}행, {len(sheet_stats)}시트")
    return sheet_stats, total_rows, sheet_headers, file_manifest


def _read_xls_from_zip_paginated_sync(
    zip_cache_path: str,
    sheet_name: str,
    division_id: str,
    import_date: str,
    division_code: str,
    file_manifest_entries: list,
    offset: int = 0,
    limit: int = 500,
    search: str = "",
) -> dict:
    """ZIP 내 XLS 파일에서 직접 페이지네이션 읽기 (xlsx 불필요)

    file_manifest_entries: [{"f": "file.xls", "r": 3000}, ...] — 시트에 기여하는 XLS 파일 목록
    응답 형식은 _read_xlsx_paginated_sync 와 100% 동일.
    """
    if not HAS_XLRD:
        raise RuntimeError("xlrd not installed on server")

    dc_part = f"#{division_code}" if division_code else ""
    items = []
    search_lower = search.strip().lower() if search else ""

    with zipfile.ZipFile(zip_cache_path, "r") as zf:
        if search_lower:
            # 검색 모드: 모든 파일 순회, scanned 카운터로 offset/limit
            scanned = 0
            global_row_idx = 0
            for entry in file_manifest_entries:
                if len(items) >= limit:
                    break
                fname = entry["f"]
                try:
                    xls_bytes = zf.read(fname)
                    wb = xlrd.open_workbook(file_contents=xls_bytes)
                except Exception:
                    global_row_idx += entry["r"]
                    continue

                target_sheet = None
                for si in range(wb.nsheets):
                    s = wb.sheet_by_index(si)
                    if s.name.strip() == sheet_name:
                        target_sheet = s
                        break

                if target_sheet is None or target_sheet.nrows < 2:
                    wb.release_resources()
                    del xls_bytes
                    global_row_idx += entry["r"]
                    continue

                # 헤더 매핑: actual col index
                header_map = []
                for col in range(target_sheet.ncols):
                    h = _xlrd_cell_to_str(target_sheet, 0, col)
                    if h:
                        header_map.append((col, h))

                for row_i in range(1, target_sheet.nrows):
                    data = {}
                    for col_idx, hname in header_map:
                        val = _xlrd_cell_to_str(target_sheet, row_i, col_idx)
                        if val:
                            data[hname] = val
                    if not data:
                        global_row_idx += 1
                        continue

                    if any(search_lower in str(v).lower() for v in data.values()):
                        if scanned >= offset:
                            items.append({
                                "divisionId": division_id,
                                "sk": f"{sheet_name}#{import_date}{dc_part}#{global_row_idx:08d}",
                                "sheetName": sheet_name,
                                "importDate": import_date,
                                "divisionCode": division_code,
                                "data": data,
                            })
                            if len(items) >= limit:
                                wb.release_resources()
                                del xls_bytes
                                break
                        scanned += 1
                    global_row_idx += 1

                wb.release_resources()
                del xls_bytes

            next_offset = offset + len(items)
            has_more = len(items) >= limit
            last_key = json.dumps({"_xlsOffset": next_offset}) if has_more else None

        else:
            # 일반 페이지네이션: file_manifest로 파일 건너뛰기
            cumulative = 0
            global_row_idx = 0
            rows_remaining = limit
            rows_to_skip = offset

            for entry in file_manifest_entries:
                if rows_remaining <= 0:
                    break
                fname = entry["f"]
                file_row_count = entry["r"]

                # 이 파일을 완전히 건너뛸 수 있는지 확인
                if rows_to_skip >= file_row_count:
                    rows_to_skip -= file_row_count
                    global_row_idx += file_row_count
                    cumulative += file_row_count
                    continue

                try:
                    xls_bytes = zf.read(fname)
                    wb = xlrd.open_workbook(file_contents=xls_bytes)
                except Exception:
                    global_row_idx += file_row_count
                    cumulative += file_row_count
                    continue

                target_sheet = None
                for si in range(wb.nsheets):
                    s = wb.sheet_by_index(si)
                    if s.name.strip() == sheet_name:
                        target_sheet = s
                        break

                if target_sheet is None or target_sheet.nrows < 2:
                    wb.release_resources()
                    del xls_bytes
                    global_row_idx += file_row_count
                    cumulative += file_row_count
                    continue

                header_map = []
                for col in range(target_sheet.ncols):
                    h = _xlrd_cell_to_str(target_sheet, 0, col)
                    if h:
                        header_map.append((col, h))

                start_row = 1 + rows_to_skip  # 1-based (row 0 = header)
                rows_to_skip = 0  # 이 파일에서 소화

                for row_i in range(start_row, target_sheet.nrows):
                    if rows_remaining <= 0:
                        break
                    data = {}
                    for col_idx, hname in header_map:
                        val = _xlrd_cell_to_str(target_sheet, row_i, col_idx)
                        if val:
                            data[hname] = val
                    if not data:
                        global_row_idx += 1
                        continue

                    items.append({
                        "divisionId": division_id,
                        "sk": f"{sheet_name}#{import_date}{dc_part}#{global_row_idx:08d}",
                        "sheetName": sheet_name,
                        "importDate": import_date,
                        "divisionCode": division_code,
                        "data": data,
                    })
                    global_row_idx += 1
                    rows_remaining -= 1

                wb.release_resources()
                del xls_bytes

            next_offset = offset + len(items)
            total_sheet_rows = sum(e["r"] for e in file_manifest_entries)
            has_more = next_offset < total_sheet_rows
            last_key = json.dumps({"_xlsOffset": next_offset}) if has_more else None

    return {
        "success": True,
        "items": items,
        "count": len(items),
        "lastEvaluatedKey": last_key,
    }


def _process_zip_to_xlsx_sync(zip_temp_path: str, progress_cb=None) -> tuple:
    """ZIP → XLS 파싱 → xlsx 직접 빌드 (DynamoDB 행 쓰기 0회)
    Returns: (xlsx_bytes, sheet_stats, total_rows, sheet_headers)
    progress_cb: Optional[Callable(stage, percent)] — 파일별 진행률 콜백
    """
    if not HAS_XLRD:
        raise RuntimeError("xlrd not installed on server")
    if not HAS_OPENPYXL:
        raise RuntimeError("openpyxl not installed on server")

    # openpyxl 서식 (헤더만 스타일 적용, 데이터 행은 plain 값 = 고속)
    wb = openpyxl.Workbook(write_only=True)
    header_fill = PatternFill(patternType="solid", fgColor="BFBFBF")
    thin_side = Side(style="thin")
    thin_border = Border(left=thin_side, right=thin_side, top=thin_side, bottom=thin_side)
    center_align = Alignment(horizontal="center", vertical="center")
    header_font = Font(name="Arial", size=10, bold=True)

    sheet_stats: Dict[str, int] = {}
    sheet_headers: Dict[str, list] = {}
    total_rows = 0
    ws_map: Dict[str, object] = {}  # sheet_name → openpyxl worksheet

    with zipfile.ZipFile(zip_temp_path, "r") as zf:
        all_names = zf.namelist()
        xls_names = [n for n in all_names
                     if n.lower().endswith(".xls") and not os.path.basename(n).startswith("~")]

        classified: Dict[str, list] = {"base": [], "numbered": [], "spt": [], "skipped": []}
        for fname in xls_names:
            base_fname = os.path.basename(fname)
            if not base_fname:
                continue
            cls = _classify_ds_file(base_fname)
            classified[cls].append(fname)

        process_list = classified["base"] + classified["numbered"] + classified["spt"]
        if not process_list:
            raise ValueError("처리할 XLS 파일 없음 (스킵 파일만 포함)")

        logger.info(f"DS xlsx build: {len(process_list)}개 XLS "
                    f"(base={len(classified['base'])}, numbered={len(classified['numbered'])}, "
                    f"spt={len(classified['spt'])}, skipped={len(classified['skipped'])})")

        total_files = len(process_list)
        last_cb_pct = 0.0

        for file_idx, fname in enumerate(process_list):
            base_fname = os.path.basename(fname) or fname

            # 파일별 진행률 콜백 (10% ~ 75% 구간, 5% 간격 스로틀)
            if progress_cb:
                pct = 10 + (file_idx / total_files) * 65
                if pct - last_cb_pct >= 5 or file_idx == 0 or file_idx == total_files - 1:
                    progress_cb(f"XLS 파싱 중... ({file_idx+1}/{total_files})", pct)
                    last_cb_pct = pct

            try:
                xls_bytes = zf.read(fname)
            except Exception as e:
                logger.warning(f"DS xlsx build: {fname} 읽기 실패: {e}")
                continue

            try:
                workbook = xlrd.open_workbook(file_contents=xls_bytes)
            except Exception as e:
                logger.warning(f"DS xlsx build: XLS 파싱 실패 ({base_fname}): {e}")
                del xls_bytes
                continue

            file_rows = 0
            for sheet_idx in range(workbook.nsheets):
                sheet = workbook.sheet_by_index(sheet_idx)
                sheet_name = sheet.name.strip()
                if sheet.nrows < 2:
                    continue

                # 헤더 추출 — 실제 컬럼 인덱스 보존 (빈 헤더 건너뛰되 위치 기억)
                header_map = []  # [(actual_col_idx, header_name), ...]
                for col in range(sheet.ncols):
                    h = _xlrd_cell_to_str(sheet, 0, col)
                    if h:
                        header_map.append((col, h))
                if not header_map:
                    continue

                headers = [name for _, name in header_map]

                # 첫 등장 시트: 워크시트 생성 + 헤더 행 + 열 너비
                if sheet_name not in ws_map:
                    ws = wb.create_sheet(title=sheet_name[:31])
                    ws_map[sheet_name] = ws
                    sheet_headers[sheet_name] = list(headers)
                    sheet_stats[sheet_name] = 0

                    # 헤더 행 쓰기
                    header_row = []
                    for h in headers:
                        cell = WriteOnlyCell(ws, value=h)
                        cell.font = header_font
                        cell.fill = header_fill
                        cell.border = thin_border
                        cell.alignment = center_align
                        header_row.append(cell)
                    ws.append(header_row)

                    # 열 너비 = 20
                    for i in range(1, len(headers) + 1):
                        ws.column_dimensions[get_column_letter(i)].width = 20

                ws = ws_map[sheet_name]
                canonical_headers = sheet_headers[sheet_name]
                row_count = 0

                # 현재 파일의 헤더→실제 컬럼 인덱스 매핑
                cur_col_map = {name: col_idx for col_idx, name in header_map}

                # 데이터 행 append — 실제 컬럼 인덱스로 정확하게 읽기
                for row_idx in range(1, sheet.nrows):
                    data = {}
                    for col_idx, hname in header_map:
                        val = _xlrd_cell_to_str(sheet, row_idx, col_idx)
                        if val:
                            data[hname] = val
                    if not data:
                        continue

                    ws.append([data.get(h, "") for h in canonical_headers])
                    row_count += 1

                sheet_stats[sheet_name] += row_count
                file_rows += row_count

            workbook.release_resources()
            del xls_bytes
            total_rows += file_rows
            logger.info(f"DS xlsx build: {base_fname} → {file_rows}행")

    gc.collect()
    if progress_cb:
        progress_cb(f"xlsx 파일 생성 중... ({total_rows:,}행)", 76)
    buf = io.BytesIO()
    wb.save(buf)
    xlsx_bytes = buf.getvalue()
    logger.info(f"DS xlsx build 완료: {total_rows}행, {len(sheet_stats)}시트, {len(xlsx_bytes):,} bytes")
    return xlsx_bytes, sheet_stats, total_rows, sheet_headers


def _init_upload_record_sync(division_id: str, division_code: str, import_date: str,
                              file_name: str, uploaded_by: str, job_id: str):
    """동기: 업로드 레코드 초기화 (기존 레코드 삭제 후 새로 생성)"""
    uploads_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_uploads"])
    records_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_records"])
    sk = f"{division_code}#{import_date}" if division_code else import_date

    existing = uploads_table.get_item(
        Key={"divisionId": division_id, "importDate": sk}
    ).get("Item")

    if existing:
        existing_storage = existing.get("storageType", "")
        existing_sheet_names = list(existing.get("sheetStats", {}).keys())
        logger.info(f"DS init: 기존 {division_id}/{sk} 삭제 (storageType={existing_storage})")

        # S3 파일 삭제 (공통)
        try:
            s3 = get_s3_client()
            for s3_key in [
                f"ds-exports/{division_id}/{division_code}_{import_date}.xlsx",
                f"ds-raw/{division_id}/{division_code}_{import_date}.zip",
            ]:
                try:
                    s3.delete_object(Bucket=S3_BUCKET_NAME, Key=s3_key)
                except Exception:
                    pass
        except Exception:
            pass

        # EC2 캐시 삭제
        _evict_cache(division_id, division_code, import_date)

        # DynamoDB records 삭제: S3 계열 스토리지면 건너뜀 (records 없음)
        if existing_storage not in ("s3", "s3-zip"):
            _delete_ds_records_targeted(
                records_table, uploads_table,
                division_id, import_date, division_code, existing_sheet_names
            )

        uploads_table.delete_item(Key={"divisionId": division_id, "importDate": sk})

    now = datetime.now(timezone.utc).isoformat()
    uploads_table.put_item(Item={
        "divisionId": division_id,
        "importDate": sk,
        "divisionCode": division_code,
        "uploadedBy": uploaded_by,
        "uploadedAt": now,
        "fileName": file_name,
        "status": "uploading",
        "jobId": job_id,
        "storageType": "s3",
        "sheetStats": {},
        "totalRows": 0,
    })


def _finalize_upload_record_sync(division_id: str, division_code: str,
                                  import_date: str, sheet_stats: dict, total_rows: int,
                                  sheet_headers: Optional[dict] = None,
                                  storage_type: str = "s3",
                                  file_manifest: Optional[dict] = None):
    """동기: 업로드 레코드를 completed 상태로 업데이트
    sheet_headers: {sheet_name: [col1, col2, ...]} — export 시 컬럼 순서 복원용
    storage_type: "s3-zip" (ZIP 보관, xlsx 미생성) / "s3" (xlsx 사전빌드)
    file_manifest: {sheet_name: [{"f": fname, "r": rows}, ...]} — s3-zip 시 페이지네이션용
    """
    uploads_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_uploads"])
    sk = f"{division_code}#{import_date}" if division_code else import_date
    update_expr = "SET #s=:s, sheetStats=:ss, totalRows=:tr, storageType=:st"
    attr_values: dict = {
        ":s": "completed",
        ":ss": {k: v for k, v in sheet_stats.items()},
        ":tr": total_rows,
        ":st": storage_type,
    }
    if sheet_headers:
        update_expr += ", sheetHeaders=:sh"
        attr_values[":sh"] = {k: list(v) for k, v in sheet_headers.items()}
    if file_manifest:
        update_expr += ", fileManifest=:fm"
        attr_values[":fm"] = file_manifest
    uploads_table.update_item(
        Key={"divisionId": division_id, "importDate": sk},
        UpdateExpression=update_expr,
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues=attr_values,
    )


def _build_xlsx_sync(division_id: str, division_code: str, import_date: str,
                      division_name: str, sheet_stats: dict,
                      sheet_headers: Optional[dict] = None) -> bytes:
    """동기: DynamoDB → openpyxl write-only → xlsx 바이트

    ds_merge.js와 동일한 서식:
      - Arial 10pt, 가운데정렬, 얇은 테두리 (모든 셀)
      - 헤더 행: 볼드 + #BFBFBF 배경
      - 모든 열 너비 = 20

    헤더 결정 방식:
      1. sheet_headers[sheet_name] 있으면 그대로 사용 (업로드 시 원본 XLS 순서 보존)
      2. 없으면 전체 스캔으로 수집 (하위 호환 fallback)
    → 이 방식으로 누락 컬럼 없이 원본과 동일한 컬럼 구성 보장
    """
    if not HAS_OPENPYXL:
        raise RuntimeError("openpyxl not installed on server")

    records_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_records"])
    dc_part = f"#{division_code}" if division_code else ""

    wb = openpyxl.Workbook(write_only=True)

    header_fill = PatternFill(patternType="solid", fgColor="BFBFBF")
    thin_side = Side(style="thin")
    thin_border = Border(left=thin_side, right=thin_side, top=thin_side, bottom=thin_side)
    center_align = Alignment(horizontal="center", vertical="center")
    data_font = Font(name="Arial", size=10)
    header_font = Font(name="Arial", size=10, bold=True)

    for sheet_name in sheet_stats.keys():
        ws = wb.create_sheet(title=sheet_name[:31])
        sk_prefix = f"{sheet_name}#{import_date}{dc_part}"

        # ── 1단계: headers 결정 ──────────────────────────────────────────────
        # 저장된 헤더 우선 사용 → 원본 XLS 컬럼 순서 + 누락 없음 보장
        if sheet_headers and sheet_name in sheet_headers:
            headers = list(sheet_headers[sheet_name])
        else:
            # fallback: 전체 스캔으로 헤더 수집 (기존 업로드 데이터 하위 호환)
            headers = []
            seen: set = set()
            scan_key = None
            while True:
                kw: dict = {
                    "KeyConditionExpression": "divisionId = :did AND begins_with(sk, :skp)",
                    "ExpressionAttributeValues": {":did": division_id, ":skp": sk_prefix},
                    "ProjectionExpression": "#d",
                    "ExpressionAttributeNames": {"#d": "data"},
                    "Limit": 500,
                }
                if scan_key:
                    kw["ExclusiveStartKey"] = scan_key
                r = records_table.query(**kw)
                for item in r.get("Items", []):
                    for k in item.get("data", {}).keys():
                        if k not in seen:
                            headers.append(k)
                            seen.add(k)
                scan_key = r.get("LastEvaluatedKey")
                if not scan_key:
                    break

        if not headers:
            continue

        # ── 2단계: 헤더 행 쓰기 ─────────────────────────────────────────────
        header_row = []
        for h in headers:
            cell = WriteOnlyCell(ws, value=h)
            cell.font = header_font
            cell.fill = header_fill
            cell.border = thin_border
            cell.alignment = center_align
            header_row.append(cell)
        ws.append(header_row)

        # 열 너비 = 20 (헤더 행 write 후, save 전까지 언제든 설정 가능)
        for i in range(1, len(headers) + 1):
            ws.column_dimensions[get_column_letter(i)].width = 20

        # ── 3단계: 데이터 행 쓰기 (headers 순서 고정, 빈 셀은 "" 처리) ────
        # ProjectionExpression으로 data 속성만 가져와 RCU + 네트워크 비용 절감
        last_key = None
        while True:
            kwargs: dict = {
                "KeyConditionExpression": "divisionId = :did AND begins_with(sk, :skp)",
                "ExpressionAttributeValues": {":did": division_id, ":skp": sk_prefix},
                "ProjectionExpression": "#d",
                "ExpressionAttributeNames": {"#d": "data"},
                "Limit": 500,
            }
            if last_key:
                kwargs["ExclusiveStartKey"] = last_key

            resp = records_table.query(**kwargs)
            items = resp.get("Items", [])

            for item in items:
                data = item.get("data", {})
                row = []
                for h in headers:
                    cell = WriteOnlyCell(ws, value=data.get(h, ""))
                    cell.font = data_font
                    cell.border = thin_border
                    cell.alignment = center_align
                    row.append(cell)
                ws.append(row)

            last_key = resp.get("LastEvaluatedKey")
            if not last_key:
                break

    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()


def _upload_xlsx_to_s3_sync(xlsx_bytes: bytes, division_id: str,
                              division_code: str, import_date: str) -> str:
    """동기: xlsx 바이트를 S3 ds-exports 경로에 업로드"""
    s3 = get_s3_client()
    key = f"ds-exports/{division_id}/{division_code}_{import_date}.xlsx"
    s3.put_object(
        Bucket=S3_BUCKET_NAME,
        Key=key,
        Body=xlsx_bytes,
        ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    )
    return key


async def _process_ds_job(job_id: str, job_item: dict):
    """DS 잡 메인 처리 — ZIP → xlsx 빌드 → S3 저장 (DynamoDB 행 쓰기 0회)"""
    s3_key = job_item.get("s3Key", "")
    file_name = job_item.get("fileName", "")
    uploaded_by = job_item.get("uploadedBy", "unknown")
    zip_temp_path = f"/tmp/ds_{job_id}.zip"

    # except 블록에서 접근 가능하도록 try 바깥에서 초기화
    division_id: Optional[str] = None
    division_code: Optional[str] = None
    import_date: Optional[str] = None
    uploads_record_created = False  # _init 이후 True → except에서 정리 대상

    try:
        # 1. ZIP S3에서 다운로드
        await _update_job_progress(job_id, "S3에서 ZIP 다운로드 중...", 3)

        def _dl():
            get_s3_client().download_file(S3_BUCKET_NAME, s3_key, zip_temp_path)
        await asyncio.to_thread(_dl)
        logger.info(f"DS job {job_id}: ZIP downloaded ({os.path.getsize(zip_temp_path):,} bytes)")

        # 2. ZIP 내 XLS 파일명에서 divisionCode/importDate 파싱
        await _update_job_progress(job_id, "ZIP 메타 파싱 중...", 5)

        def _parse_meta():
            with zipfile.ZipFile(zip_temp_path, "r") as zf:
                for name in zf.namelist():
                    base = os.path.basename(name)
                    if not base.lower().endswith(".xls"):
                        continue
                    if _classify_ds_file(base) == "skipped":
                        continue
                    parsed = _parse_ds_filename_in_zip(base)
                    if parsed:
                        return parsed
            return None

        parsed = await asyncio.to_thread(_parse_meta)
        if not parsed:
            parsed = _parse_ds_filename_in_zip(file_name)
        if not parsed:
            raise ValueError(f"지역코드/업로드일자 파싱 실패: {file_name}")

        division_code = parsed["divisionCode"]
        import_date = parsed["importDate"]

        if division_code not in DS_REGION_CODE_MAP:
            raise ValueError(f"알 수 없는 지역코드: {division_code}")

        division_id = DS_REGION_CODE_MAP[division_code]["divisionId"]
        division_name = DS_REGION_CODE_MAP[division_code]["divisionName"]
        logger.info(f"DS job {job_id}: {division_name}({division_code}) / {import_date}")

        # 3. 메모리 체크
        if HAS_PSUTIL:
            mem = psutil.virtual_memory()
            if mem.percent > 80:
                logger.warning(f"DS job {job_id}: 메모리 {mem.percent}% > 80%, 30초 대기")
                await asyncio.sleep(30)

        # 4. uploads 레코드 초기화 (기존 데이터 삭제)
        await _update_job_progress(job_id, "기존 데이터 정리 중...", 8)
        await asyncio.to_thread(
            _init_upload_record_sync,
            division_id, division_code, import_date, file_name, uploaded_by, job_id
        )
        uploads_record_created = True

        # 5. 메타데이터만 초고속 파싱 (xlsx 빌드 완전 생략 → 30분→5초)
        await _update_job_progress(job_id, "메타데이터 파싱 중...", 10)

        def _progress_cb(stage: str, pct: float):
            _update_job_progress_sync(job_id, stage, pct)

        sheet_stats, total_rows, sheet_headers, file_manifest = await asyncio.to_thread(
            _parse_zip_metadata_sync, zip_temp_path, _progress_cb
        )
        logger.info(f"DS job {job_id}: 메타 파싱 완료 — {total_rows}행, {len(sheet_stats)}시트")

        # 6. ZIP → S3 영구 경로로 복사 (xlsx 빌드 없이 원본 ZIP 보관)
        await _update_job_progress(job_id, "ZIP S3 저장 중...", 80)
        permanent_zip_key = f"ds-raw/{division_id}/{division_code}_{import_date}.zip"

        def _copy_zip_to_s3():
            s3 = get_s3_client()
            s3.upload_file(zip_temp_path, S3_BUCKET_NAME, permanent_zip_key)

        await asyncio.to_thread(_copy_zip_to_s3)
        logger.info(f"DS job {job_id}: ZIP S3 저장 완료 → {permanent_zip_key}")

        # 7. uploads 레코드 완료 처리 (storageType="s3-zip")
        await _update_job_progress(job_id, "업로드 완료 처리 중...", 90)
        await asyncio.to_thread(
            _finalize_upload_record_sync,
            division_id, division_code, import_date, sheet_stats, total_rows,
            sheet_headers, "s3-zip", file_manifest
        )

        # 8. 잡 완료
        await asyncio.to_thread(
            _mark_job_done_sync,
            job_id, division_id, division_code, import_date, sheet_stats, total_rows
        )
        uploads_record_created = False  # 정상 완료 → except 정리 불필요
        logger.info(f"DS job {job_id}: 완료! {division_name} {import_date} — {total_rows}행")

    except Exception as e:
        error_msg = str(e)[:500]
        logger.error(f"DS job {job_id} 실패: {error_msg}")

        # 잡 실패 처리
        try:
            await asyncio.to_thread(_mark_job_failed_sync, job_id, error_msg)
        except Exception as e2:
            logger.error(f"DS job {job_id} mark-failed도 실패: {e2}")

        # 고스트 uploads 레코드 정리 (step 4 이후 실패 시)
        if uploads_record_created and division_id and import_date:
            try:
                _sk = f"{division_code}#{import_date}" if division_code else import_date
                _uploads_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_uploads"])
                await asyncio.to_thread(
                    lambda: _uploads_table.delete_item(
                        Key={"divisionId": division_id, "importDate": _sk}
                    )
                )
                logger.info(f"DS job {job_id}: 고스트 uploads 레코드 삭제 완료")
            except Exception as e3:
                logger.warning(f"DS job {job_id}: uploads 정리 실패 (non-fatal): {e3}")

    finally:
        try:
            if os.path.exists(zip_temp_path):
                os.remove(zip_temp_path)
        except Exception:
            pass
        gc.collect()


async def _job_worker_loop():
    """싱글턴 백그라운드 워커 — 한 번에 1개 DS 잡만 처리 (OOM 방지)
    10분마다 stuck "processing" 잡 자동 복구
    """
    logger.info("DS job worker loop started")
    last_stuck_check = 0.0  # epoch seconds
    STUCK_CHECK_INTERVAL = 600  # 10분

    while True:
        try:
            # 주기적 stuck job 복구 (10분마다)
            now = asyncio.get_event_loop().time()
            if now - last_stuck_check > STUCK_CHECK_INTERVAL:
                last_stuck_check = now
                try:
                    await _recover_stuck_jobs()
                except Exception as e:
                    logger.warning(f"Periodic stuck job recovery error: {e}")

            job = await _get_next_queued_job()
            if job is None:
                await asyncio.sleep(5)
                continue

            job_id = job["jobId"]
            logger.info(f"DS job worker: processing {job_id}")

            await asyncio.to_thread(_mark_job_processing_sync, job_id)

            if HAS_PSUTIL:
                mem = psutil.virtual_memory()
                if mem.percent > 80:
                    logger.warning(f"메모리 {mem.percent}% > 80%, 30초 대기 후 처리")
                    await asyncio.sleep(30)

            await _process_ds_job(job_id, job)

        except asyncio.CancelledError:
            logger.info("DS job worker loop cancelled")
            break
        except Exception as e:
            logger.error(f"DS job worker loop error: {e}")
            await asyncio.sleep(5)


@app.get("/ds/upload-presign")
async def ds_upload_presign(
    divisionId: str = Query(...),
    divisionCode: str = Query(...),
    importDate: str = Query(...),
):
    """S3 presigned URL 생성 - 원본 ZIP 업로드용"""
    try:
        s3 = get_s3_client()
        key = f"ds-raw/{divisionId}/{divisionCode}_{importDate}.zip"
        url = s3.generate_presigned_url(
            "put_object",
            Params={"Bucket": S3_BUCKET_NAME, "Key": key, "ContentType": "application/zip"},
            ExpiresIn=3600,
        )
        return {"success": True, "url": url, "key": key}
    except Exception as e:
        logger.error(f"DS upload presign error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/ds/xlsx-upload-presign")
async def ds_xlsx_upload_presign(
    divisionId: str = Query(...),
    divisionCode: str = Query(...),
    importDate: str = Query(...),
):
    """S3 presigned URL 생성 - 병합된 xlsx 저장용 (업로드 시 생성)"""
    try:
        s3 = get_s3_client()
        key = f"ds-exports/{divisionId}/{divisionCode}_{importDate}.xlsx"
        url = s3.generate_presigned_url(
            "put_object",
            Params={
                "Bucket": S3_BUCKET_NAME,
                "Key": key,
                "ContentType": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            },
            ExpiresIn=3600,
        )
        return {"success": True, "url": url, "key": key}
    except Exception as e:
        logger.error(f"DS xlsx upload presign error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/ds/export-presign")
async def ds_export_presign(
    divisionId: str = Query(...),
    importDate: str = Query(...),
    divisionCode: str = Query(""),
):
    """S3 Export용 presigned URL - 병합 xlsx 우선, 없으면 원본 ZIP"""
    try:
        s3 = get_s3_client()

        # 1순위: 미리 생성된 병합 xlsx → 즉시 다운로드
        xlsx_key = f"ds-exports/{divisionId}/{divisionCode}_{importDate}.xlsx"
        try:
            s3.head_object(Bucket=S3_BUCKET_NAME, Key=xlsx_key)
            url = s3.generate_presigned_url(
                "get_object",
                Params={"Bucket": S3_BUCKET_NAME, "Key": xlsx_key},
                ExpiresIn=3600,
            )
            return {"success": True, "url": url, "type": "xlsx"}
        except ClientError:
            pass

        # 2순위: 원본 ZIP → 브라우저에서 병합
        zip_key = f"ds-raw/{divisionId}/{divisionCode}_{importDate}.zip"
        try:
            s3.head_object(Bucket=S3_BUCKET_NAME, Key=zip_key)
            url = s3.generate_presigned_url(
                "get_object",
                Params={"Bucket": S3_BUCKET_NAME, "Key": zip_key},
                ExpiresIn=3600,
            )
            return {"success": True, "url": url, "type": "zip"}
        except ClientError:
            pass

        return {"success": False, "message": "S3에 파일 없음. DB Export로 대체합니다."}
    except Exception as e:
        logger.error(f"DS export presign error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/ds/upload-init")
async def ds_upload_init(req: DsUploadInit):
    """DS 업로드 세션 시작 - 기존 데이터 삭제 후 새 레코드 생성"""
    try:
        dynamodb = get_dynamodb_resource()
        uploads_table = dynamodb.Table(DYNAMODB_TABLES["ds_uploads"])
        records_table = dynamodb.Table(DYNAMODB_TABLES["ds_records"])

        sk = f"{req.divisionCode}#{req.importDate}" if req.divisionCode else req.importDate

        # 기존 데이터 존재 시 처리
        existing = uploads_table.get_item(Key={"divisionId": req.divisionId, "importDate": sk}).get("Item")
        if existing:
            # 이미 completed 상태인 경우: 늦게 도착한 upload-init으로 인한 덮어쓰기 방지
            # (병렬 배치 처리 중 네트워크 지연으로 upload-init이 finalize 이후 도착할 수 있음)
            if existing.get("status") == "completed":
                logger.info(f"DS upload-init: already completed, skip overwrite - {req.divisionId}/{sk}")
                return {"success": True, "uploadId": f"{req.divisionId}#{sk}"}

            # 시트 목록 미리 추출 (asyncio.to_thread 전에 읽어야 thread-safe)
            existing_sheet_names = list(existing.get("sheetStats", {}).keys())
            logger.info(f"DS upload-init: 기존 데이터 삭제 시작 {req.divisionId}/{sk}, sheets={existing_sheet_names}")

            # 기존 pre-built xlsx S3에서도 삭제 (재업로드 시 이전 xlsx 무효화)
            try:
                s3 = get_s3_client()
                s3.delete_object(
                    Bucket=S3_BUCKET_NAME,
                    Key=f"ds-exports/{req.divisionId}/{req.divisionCode}_{req.importDate}.xlsx"
                )
            except Exception:
                pass

            # asyncio.to_thread: 이벤트 루프 블로킹 없이 병렬 시트 삭제 실행
            # sheet_names 직접 전달 → uploads_table thread-safe 문제 방지
            deleted = await asyncio.to_thread(
                _delete_ds_records_targeted, records_table, uploads_table,
                req.divisionId, req.importDate, req.divisionCode, existing_sheet_names
            )
            uploads_table.delete_item(Key={"divisionId": req.divisionId, "importDate": sk})
            logger.info(f"DS upload-init: 기존 {deleted}건 삭제 완료")

        now = datetime.now(timezone.utc).isoformat()
        uploads_table.put_item(Item={
            "divisionId": req.divisionId,
            "importDate": sk,
            "divisionCode": req.divisionCode,
            "uploadedBy": req.uploadedBy,
            "uploadedAt": now,
            "fileName": req.fileName,
            "status": "uploading",
            "sheetStats": {},
            "totalRows": 0,
        })

        logger.info(f"DS upload init: {req.divisionId} / {sk}")
        return {"success": True, "uploadId": f"{req.divisionId}#{sk}"}
    except ClientError as e:
        logger.error(f"DS upload-init error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


def _write_chunk_sync(req: "DsUploadChunk") -> int:
    """동기 DynamoDB 청크 쓰기 — asyncio.to_thread로 호출해 이벤트 루프 비점유"""
    table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_records"])
    now = datetime.now(timezone.utc).isoformat()
    written = 0
    with table.batch_writer() as batch:
        for i, row in enumerate(req.rows):
            row_idx = req.startIndex + i
            data = {}
            for col_idx, header in enumerate(req.headers):
                if col_idx < len(row):
                    val = row[col_idx]
                    if val is not None and val != "":
                        data[header] = str(val)
            dc_part = f"#{req.divisionCode}" if req.divisionCode else ""
            item = {
                "divisionId": req.divisionId,
                # 8자리 패딩: 최대 99,999,999행 (6자리는 999,999행 초과 시 정렬 오류)
                "sk": f"{req.sheetName}#{req.importDate}{dc_part}#{row_idx:08d}",
                "sheetName": req.sheetName,
                "importDate": req.importDate,
                "divisionCode": req.divisionCode,
                "uploadedAt": now,
                "data": data,
            }
            batch.put_item(Item=item)
            written += 1
    return written


@app.post("/ds/upload-chunk")
async def ds_upload_chunk(req: DsUploadChunk):
    """DS 청크 데이터 수신 → DynamoDB BatchWriteItem (스레드 풀에서 실행)"""
    try:
        written = await asyncio.to_thread(_write_chunk_sync, req)
        logger.info(f"DS chunk: {req.divisionId}/{req.sheetName} chunk {req.chunkIndex}/{req.totalChunks} - {written} rows")
        return {"success": True, "writtenCount": written}
    except ClientError as e:
        logger.error(f"DS upload-chunk error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/ds/upload-finalize")
async def ds_upload_finalize(req: DsUploadFinalize):
    """DS 업로드 완료 - status 업데이트"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["ds_uploads"])

        sk = f"{req.divisionCode}#{req.importDate}" if req.divisionCode else req.importDate
        table.update_item(
            Key={"divisionId": req.divisionId, "importDate": sk},
            UpdateExpression="SET #s = :s, sheetStats = :ss, totalRows = :tr",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":s": "completed",
                ":ss": {k: v for k, v in req.sheetStats.items()},
                ":tr": req.totalRows,
            },
        )

        logger.info(f"DS upload finalized: {req.divisionId}/{sk} - {req.totalRows} rows")
        return {"success": True}
    except ClientError as e:
        logger.error(f"DS upload-finalize error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/ds/stats")
async def ds_stats(
    divisionId: Optional[str] = Query(None),
    importDate: Optional[str] = Query(None),
    divisionCode: Optional[str] = Query(None),
):
    """DS 업로드 통계 조회 (대시보드용)"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["ds_uploads"])

        if divisionId:
            # 특정 본부 조회
            if importDate and divisionCode:
                # 특정 코드+날짜 조회
                sk = f"{divisionCode}#{importDate}"
                response = table.get_item(Key={"divisionId": divisionId, "importDate": sk})
                item = response.get("Item")
                items = [item] if item else []
            elif importDate:
                # 날짜 필터 (SK contains importDate → FilterExpression 사용)
                response = table.query(
                    KeyConditionExpression="divisionId = :did",
                    FilterExpression="contains(importDate, :idate)",
                    ExpressionAttributeValues={":did": divisionId, ":idate": importDate},
                    ScanIndexForward=False,
                )
                items = response.get("Items", [])
            else:
                response = table.query(
                    KeyConditionExpression="divisionId = :did",
                    ExpressionAttributeValues={":did": divisionId},
                    ScanIndexForward=False,
                )
                items = response.get("Items", [])
        else:
            # 전체 본부 조회 - 페이지네이션 scan (메모리 절약)
            items = []
            last_key = None
            while True:
                kwargs = {"Limit": 100}
                if last_key:
                    kwargs["ExclusiveStartKey"] = last_key
                response = table.scan(**kwargs)
                items.extend(response.get("Items", []))
                last_key = response.get("LastEvaluatedKey")
                if not last_key or len(items) >= 500:
                    break

        # divisionName 추가
        for item in items:
            code = item.get("divisionCode", "")
            if code in DS_REGION_CODE_MAP:
                item["divisionName"] = DS_REGION_CODE_MAP[code]["divisionName"]

        return {"success": True, "uploads": decimal_to_native(items), "count": len(items)}
    except ClientError as e:
        logger.error(f"DS stats error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/ds/export")
async def ds_export(
    divisionId: str = Query(...),
    importDate: str = Query(...),
    divisionCode: Optional[str] = Query(None),
):
    """DS 데이터 Excel Export용 - 스트리밍 JSON 응답 (메모리 절약)"""

    def _query_sync(table, **kwargs):
        """동기 DynamoDB 쿼리 — asyncio.to_thread로 호출해 이벤트 루프 비점유"""
        return table.query(**kwargs)

    def _get_item_sync(table, **kwargs):
        return table.get_item(**kwargs)

    async def generate():
        try:
            records_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_records"])
            uploads_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_uploads"])

            # 1. uploads에서 시트 목록 확보 (스레드에서 실행)
            upload_sk = f"{divisionCode}#{importDate}" if divisionCode else importDate
            upload_resp = await asyncio.to_thread(
                _get_item_sync, uploads_table,
                Key={"divisionId": divisionId, "importDate": upload_sk}
            )
            upload_item = upload_resp.get("Item", {})
            sheet_stats = upload_item.get("sheetStats", {})
            sheet_names = list(sheet_stats.keys())

            if not sheet_names:
                yield json.dumps({"success": False, "message": "시트 정보를 찾을 수 없습니다."})
                return

            division_name = ""
            if divisionCode and divisionCode in DS_REGION_CODE_MAP:
                division_name = DS_REGION_CODE_MAP[divisionCode]["divisionName"]

            meta = {
                "divisionId": divisionId,
                "divisionCode": divisionCode or "",
                "divisionName": division_name,
                "importDate": importDate,
            }

            # JSON 스트리밍 시작
            yield '{"success":true,"meta":' + json.dumps(meta, ensure_ascii=False) + ',"sheets":['

            first_sheet = True
            for sheet_name in sheet_names:
                dc_part = f"#{divisionCode}" if divisionCode else ""
                sk_prefix = f"{sheet_name}#{importDate}{dc_part}"
                base_query = {
                    "KeyConditionExpression": "divisionId = :did AND begins_with(sk, :skp)",
                    "ExpressionAttributeValues": {":did": divisionId, ":skp": sk_prefix},
                    "Limit": 1000,
                }

                # Pass 1: 헤더 수집 (첫 배치 — 스레드에서 실행)
                resp = await asyncio.to_thread(_query_sync, records_table, **base_query)
                first_items = resp.get("Items", [])
                if not first_items:
                    continue

                headers = []
                seen = set()
                for item in first_items:
                    for key in item.get("data", {}).keys():
                        if key not in seen:
                            headers.append(key)
                            seen.add(key)

                # 시트 JSON 출력
                if not first_sheet:
                    yield ","
                first_sheet = False

                yield '{"name":' + json.dumps(sheet_name, ensure_ascii=False)
                yield ',"headers":' + json.dumps(headers, ensure_ascii=False)
                yield ',"rows":['

                # Pass 2: 행 데이터를 DynamoDB 배치 단위로 바로 스트리밍 (메모리 미축적)
                first_row = True
                row_count = 0

                # 첫 배치 결과 먼저 출력
                batch_items = first_items
                first_items = None  # 참조 해제
                p1_last_key = resp.get("LastEvaluatedKey")

                while True:
                    chunk_rows = []
                    for item in batch_items:
                        data = item.get("data", {})
                        # 헤더에 없는 새 키 발견 시 추가
                        for key in data.keys():
                            if key not in seen:
                                headers.append(key)
                                seen.add(key)
                        row = [str(data.get(h, "")) for h in headers]
                        chunk_rows.append(json.dumps(row, ensure_ascii=False))
                    batch_items = None  # 참조 해제

                    if chunk_rows:
                        prefix = "" if first_row else ","
                        first_row = False
                        yield prefix + ",".join(chunk_rows)
                        row_count += len(chunk_rows)
                    chunk_rows = None

                    if not p1_last_key:
                        break

                    # 다음 배치 — 스레드에서 실행
                    kwargs = {**base_query, "ExclusiveStartKey": p1_last_key}
                    resp = await asyncio.to_thread(_query_sync, records_table, **kwargs)
                    batch_items = resp.get("Items", [])
                    p1_last_key = resp.get("LastEvaluatedKey")

                yield "]}"
                logger.info(f"DS export sheet '{sheet_name}': {row_count} rows streamed")

            yield "]}"

        except ClientError as e:
            logger.error(f"DS export error: {e}")
            yield json.dumps({"success": False, "message": str(e)})
        except Exception as e:
            logger.error(f"DS export unexpected error: {e}")
            yield json.dumps({"success": False, "message": str(e)})

    return StreamingResponse(generate(), media_type="application/json")


@app.get("/ds/data")
async def ds_data(
    divisionId: str = Query(...),
    sheetName: str = Query(...),
    importDate: Optional[str] = Query(None),
    limit: int = Query(100, le=1000),
    lastKey: Optional[str] = Query(None),
    search: Optional[str] = Query(None),
    divisionCode: Optional[str] = Query(None),
):
    """DS 데이터 리스트 조회 (페이징, 서버측 검색 지원)
    트리플 라우팅: s3-zip → ZIP 내 XLS 직접 / s3 → xlsx / 없음 → DynamoDB fallback
    """
    try:
        # ── 스토리지 타입 판별 ──────────────────────────────────
        storage_type = ""
        xls_offset = 0
        file_manifest = None

        if lastKey:
            parsed_key = json.loads(lastKey)
            if isinstance(parsed_key, dict) and "_xlsOffset" in parsed_key:
                xls_offset = parsed_key["_xlsOffset"]
                # S3 계열 → uploads 레코드에서 storageType 확인
                if importDate and divisionCode:
                    dynamodb = get_dynamodb_resource()
                    uploads_table = dynamodb.Table(DYNAMODB_TABLES["ds_uploads"])
                    upload_sk = f"{divisionCode}#{importDate}"
                    resp = uploads_table.get_item(
                        Key={"divisionId": divisionId, "importDate": upload_sk},
                        ProjectionExpression="storageType, fileManifest",
                    )
                    upload_rec = resp.get("Item")
                    if upload_rec:
                        storage_type = upload_rec.get("storageType", "")
                        file_manifest = upload_rec.get("fileManifest")

        if not storage_type and importDate and divisionCode:
            # 첫 페이지: uploads 레코드에서 storageType 확인
            dynamodb = get_dynamodb_resource()
            uploads_table = dynamodb.Table(DYNAMODB_TABLES["ds_uploads"])
            upload_sk = f"{divisionCode}#{importDate}"
            resp = uploads_table.get_item(
                Key={"divisionId": divisionId, "importDate": upload_sk},
                ProjectionExpression="storageType, fileManifest",
            )
            upload_rec = resp.get("Item")
            if upload_rec:
                storage_type = upload_rec.get("storageType", "")
                file_manifest = upload_rec.get("fileManifest")

        # ── s3-zip 경로: ZIP 내 XLS에서 직접 읽기 (초고속 업로드용) ──
        if storage_type == "s3-zip" and importDate and divisionCode:
            zip_path = _get_cached_file(divisionId, divisionCode, importDate, "zip")
            if not zip_path:
                s3_key = f"ds-raw/{divisionId}/{divisionCode}_{importDate}.zip"
                cache_path = _get_cache_path(divisionId, divisionCode, importDate, "zip")
                os.makedirs(os.path.dirname(cache_path), exist_ok=True)
                try:
                    s3_client = get_s3_client()
                    await asyncio.to_thread(
                        s3_client.download_file, S3_BUCKET_NAME, s3_key, cache_path
                    )
                    zip_path = cache_path
                except Exception as e:
                    logger.warning(f"DS S3 ZIP download failed ({s3_key}): {e}")
                    return {"success": True, "items": [], "count": 0, "lastEvaluatedKey": None}

            # fileManifest에서 해당 시트의 파일 목록 추출
            manifest_entries = []
            if file_manifest and sheetName in file_manifest:
                manifest_entries = file_manifest[sheetName]
            if not manifest_entries:
                return {"success": True, "items": [], "count": 0, "lastEvaluatedKey": None}

            result = await asyncio.to_thread(
                _read_xls_from_zip_paginated_sync,
                zip_path, sheetName, divisionId, importDate,
                divisionCode, manifest_entries, xls_offset, limit, search or "",
            )
            return result

        # ── s3 경로: xlsx 캐시/다운로드 → 페이지네이션 (구버전 호환) ──
        if storage_type == "s3" and importDate and divisionCode:
            xlsx_path = _get_cached_xlsx(divisionId, divisionCode, importDate)
            if not xlsx_path:
                s3_key = f"ds-exports/{divisionId}/{divisionCode}_{importDate}.xlsx"
                cache_path = _get_cache_path(divisionId, divisionCode, importDate)
                os.makedirs(os.path.dirname(cache_path), exist_ok=True)
                try:
                    s3_client = get_s3_client()
                    await asyncio.to_thread(
                        s3_client.download_file, S3_BUCKET_NAME, s3_key, cache_path
                    )
                    xlsx_path = cache_path
                except Exception as e:
                    logger.warning(f"DS S3 xlsx download failed ({s3_key}): {e}")
                    return {"success": True, "items": [], "count": 0, "lastEvaluatedKey": None}

            result = await asyncio.to_thread(
                _read_xlsx_paginated_sync,
                xlsx_path, sheetName, divisionId, importDate,
                divisionCode, xls_offset, limit, search,
            )
            return result

        # ── DynamoDB fallback (기존 데이터) ──────────────
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["ds_records"])

        sk_prefix = f"{sheetName}#{importDate}" if importDate else sheetName

        base_kwargs = {
            "KeyConditionExpression": "divisionId = :did AND begins_with(sk, :skp)",
            "ExpressionAttributeValues": {
                ":did": divisionId,
                ":skp": sk_prefix,
            },
        }

        if search:
            # 서버측 검색: DynamoDB에서 소량 배치로 읽어 Python에서 필터링
            search_lower = search.lower()
            matched = []
            continuation_key = json.loads(lastKey) if lastKey else None

            # 최대 5회 배치 쿼리 (배치당 500건 = 최대 2500건 스캔)
            for _ in range(5):
                kwargs = {**base_kwargs, "Limit": 500}
                if continuation_key:
                    kwargs["ExclusiveStartKey"] = continuation_key

                response = table.query(**kwargs)
                batch_items = response.get("Items", [])

                for item in batch_items:
                    data = item.get("data", {})
                    if any(search_lower in str(v).lower() for v in data.values()):
                        matched.append(item)
                        if len(matched) >= limit:
                            break
                batch_items = None  # 참조 해제

                continuation_key = response.get("LastEvaluatedKey")
                if not continuation_key or len(matched) >= limit:
                    break

            result_items = matched[:limit]
            matched = None  # 참조 해제
            return {
                "success": True,
                "items": decimal_to_native(result_items),
                "count": len(result_items),
                "lastEvaluatedKey": json.dumps(continuation_key) if continuation_key and len(result_items) >= limit else None,
            }
        else:
            # 일반 페이징 조회
            kwargs = {**base_kwargs, "Limit": limit}
            if lastKey:
                kwargs["ExclusiveStartKey"] = json.loads(lastKey)

            response = table.query(**kwargs)
            items = response.get("Items", [])
            last_evaluated_key = response.get("LastEvaluatedKey")

            return {
                "success": True,
                "items": decimal_to_native(items),
                "count": len(items),
                "lastEvaluatedKey": json.dumps(last_evaluated_key) if last_evaluated_key else None,
            }
    except ClientError as e:
        logger.error(f"DS data query error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/ds/data")
async def ds_delete_data(
    background_tasks: BackgroundTasks,
    divisionId: str = Query(...),
    importDate: str = Query(...),
    divisionCode: Optional[str] = Query(None),
):
    """
    DS 데이터 삭제 - 즉시 응답 + 레코드는 백그라운드 삭제
    - uploads 레코드: 즉시 삭제 → 대시보드에서 즉시 사라짐
    - S3 xlsx/zip: 즉시 삭제 → 이전 Export 파일 무효화
    - DynamoDB records: storageType="s3"면 건너뜀 (records 없음)
    """
    try:
        dynamodb = get_dynamodb_resource()
        uploads_table = dynamodb.Table(DYNAMODB_TABLES["ds_uploads"])

        dc = divisionCode or ""
        upload_sk = f"{dc}#{importDate}" if dc else importDate

        # 1. uploads 레코드 조회 (storageType + sheet_names 확인)
        storage_type = ""
        sheet_names = []
        try:
            upload_item = uploads_table.get_item(
                Key={"divisionId": divisionId, "importDate": upload_sk}
            ).get("Item", {})
            sheet_names = list(upload_item.get("sheetStats", {}).keys())
            storage_type = upload_item.get("storageType", "")
        except Exception as e:
            logger.warning(f"DS delete: uploads 조회 실패 (non-fatal): {e}")

        # 2. S3 파일 즉시 삭제 (xlsx + zip)
        try:
            s3 = get_s3_client()
            for s3_key in [
                f"ds-exports/{divisionId}/{dc}_{importDate}.xlsx",
                f"ds-raw/{divisionId}/{dc}_{importDate}.zip",
            ]:
                try:
                    s3.delete_object(Bucket=S3_BUCKET_NAME, Key=s3_key)
                except Exception:
                    pass
        except Exception as e:
            logger.warning(f"S3 delete error (non-fatal): {e}")

        # 3. 로컬 캐시 삭제
        if dc:
            _evict_cache(divisionId, dc, importDate)

        # 4. uploads 레코드 즉시 삭제 → 대시보드에서 즉시 사라짐
        uploads_table.delete_item(Key={"divisionId": divisionId, "importDate": upload_sk})

        # 5. DynamoDB records 삭제: S3 계열이면 건너뜀 (records 없음)
        if storage_type not in ("s3", "s3-zip"):
            background_tasks.add_task(_background_delete_records, divisionId, importDate, dc, sheet_names)
            logger.info(f"DS delete initiated (background/dynamo): {divisionId}/{upload_sk}, sheets={len(sheet_names)}")
        else:
            logger.info(f"DS delete complete ({storage_type}, no records): {divisionId}/{upload_sk}")

        return {"success": True, "deletedCount": 0}
    except ClientError as e:
        logger.error(f"DS delete error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# ============================================================
# DS 잡 큐 엔드포인트
# ============================================================

@app.get("/ds/presign-raw")
async def ds_presign_raw(
    fileName: str = Query(...),
):
    """DS ZIP S3 직접 업로드용 presigned PUT URL 발급
    브라우저가 이 URL로 직접 S3에 PUT → EC2 메모리 0 사용
    (S3 버킷 CORS 설정 필요 — 없으면 /ds/upload-raw 사용)
    """
    try:
        s3 = get_s3_client()
        safe_name = re.sub(r"[^\w\-_\.]", "_", fileName)
        temp_key = f"ds-raw/temp/{uuid.uuid4()}_{safe_name}"
        url = s3.generate_presigned_url(
            "put_object",
            Params={"Bucket": S3_BUCKET_NAME, "Key": temp_key, "ContentType": "application/zip"},
            ExpiresIn=3600,
        )
        return {"success": True, "url": url, "s3Key": temp_key}
    except Exception as e:
        logger.error(f"DS presign-raw error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/ds/upload-raw")
async def ds_upload_raw(file: UploadFile = File(...)):
    """DS ZIP → S3 멀티파트 스트리밍 업로드
    디스크 저장 없이 브라우저 → EC2 → S3 직접 파이프라인
    메모리 최대 ~16MB (8MB 수신 버퍼 + 8MB 업로드 파트)
    기존: 디스크 write(100MB) + S3 upload(100MB) = 200MB I/O
    개선: 수신 즉시 S3 파트 업로드 → I/O 절반 + 시간 30~50% 단축
    """
    safe_name = re.sub(r"[^\w\-_\.]", "_", file.filename or "upload.zip")
    s3_key = f"ds-raw/temp/{uuid.uuid4()}_{safe_name}"
    s3 = get_s3_client()
    upload_id: Optional[str] = None
    try:
        # S3 멀티파트 업로드 초기화
        mpu = await asyncio.to_thread(
            lambda: s3.create_multipart_upload(
                Bucket=S3_BUCKET_NAME, Key=s3_key, ContentType="application/zip"
            )
        )
        upload_id = mpu["UploadId"]

        PART_SIZE = 8 * 1024 * 1024  # 8MB (AWS 최소 5MB, 마지막 파트 예외)
        buf = b""
        parts: list = []
        part_number = 1

        # 8MB씩 수신 → 버퍼가 PART_SIZE 이상이면 즉시 S3 파트 업로드
        while True:
            chunk = await file.read(PART_SIZE)
            if not chunk:
                break
            buf += chunk
            while len(buf) >= PART_SIZE:
                part_data, buf = buf[:PART_SIZE], buf[PART_SIZE:]
                pn = part_number
                resp = await asyncio.to_thread(
                    lambda pd=part_data, n=pn: s3.upload_part(
                        Bucket=S3_BUCKET_NAME, Key=s3_key,
                        UploadId=upload_id, PartNumber=n, Body=pd,
                    )
                )
                parts.append({"PartNumber": pn, "ETag": resp["ETag"]})
                part_number += 1

        # 나머지 버퍼를 마지막 파트로 업로드 (< PART_SIZE 허용)
        if buf:
            pn = part_number
            resp = await asyncio.to_thread(
                lambda pd=buf, n=pn: s3.upload_part(
                    Bucket=S3_BUCKET_NAME, Key=s3_key,
                    UploadId=upload_id, PartNumber=n, Body=pd,
                )
            )
            parts.append({"PartNumber": pn, "ETag": resp["ETag"]})

        if not parts:
            raise ValueError("업로드된 데이터가 없습니다")

        # 멀티파트 완료
        await asyncio.to_thread(
            lambda: s3.complete_multipart_upload(
                Bucket=S3_BUCKET_NAME, Key=s3_key, UploadId=upload_id,
                MultipartUpload={"Parts": parts},
            )
        )
        logger.info(f"DS upload-raw: {s3_key} ({len(parts)} parts)")
        return {"success": True, "s3Key": s3_key}

    except Exception as e:
        # 오류 시 S3 멀티파트 정리 (미완료 파트 과금 방지)
        if upload_id:
            try:
                await asyncio.to_thread(
                    lambda: s3.abort_multipart_upload(
                        Bucket=S3_BUCKET_NAME, Key=s3_key, UploadId=upload_id,
                    )
                )
            except Exception:
                pass
        logger.error(f"DS upload-raw error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/ds/enqueue")
async def ds_enqueue(req: DsEnqueueRequest):
    """DS 처리 잡을 큐에 추가 — 즉시 jobId 반환, 실제 처리는 백그라운드 워커"""
    if not HAS_XLRD:
        raise HTTPException(status_code=503, detail="서버에 xlrd가 설치되지 않았습니다. 관리자에게 문의하세요.")

    try:
        jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])
        job_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()

        jobs_table.put_item(Item={
            "jobId": job_id,
            "status": "queued",
            "stage": "처리 대기 중...",
            "percent": Decimal("0"),
            "processedRows": 0,
            "totalRows": 0,
            "s3Key": req.s3Key,
            "fileName": req.fileName,
            "uploadedBy": req.uploadedBy,
            "queuedAt": now,
        })

        # 현재 큐 길이 (대기 순서 표시용)
        # Select='COUNT': 아이템 데이터 반환 없이 개수만 집계 → RCU + 네트워크 비용 절감
        resp = jobs_table.scan(
            FilterExpression="#s = :s",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": "queued"},
            Select="COUNT",
        )
        queue_position = resp.get("Count", 0)

        logger.info(f"DS job enqueued: {job_id} ({req.fileName}, 큐 {queue_position}번째)")
        return {"success": True, "jobId": job_id, "queuePosition": queue_position}
    except ClientError as e:
        logger.error(f"DS enqueue error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/ds/export-xlsx")
async def ds_export_xlsx(
    divisionId: str = Query(...),
    importDate: str = Query(...),
    divisionCode: str = Query(""),
):
    """DS xlsx 다운로드
    - storageType="s3": S3에서 직접 다운로드 (빌드 불필요, 즉시)
    - old: DynamoDB → xlsx 서버사이드 빌드 후 다운로드 + S3 캐싱
    """
    if not HAS_OPENPYXL:
        raise HTTPException(status_code=503, detail="서버에 openpyxl이 설치되지 않았습니다.")

    division_name = ""
    if divisionCode and divisionCode in DS_REGION_CODE_MAP:
        division_name = DS_REGION_CODE_MAP[divisionCode]["divisionName"]

    dc = divisionCode or divisionId
    filename = f"{division_name or dc}_{importDate}_DS.xlsx"

    # uploads에서 sheetStats + sheetHeaders + storageType 가져오기
    def _get_upload_meta():
        uploads_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_uploads"])
        sk = f"{divisionCode}#{importDate}" if divisionCode else importDate
        item = uploads_table.get_item(
            Key={"divisionId": divisionId, "importDate": sk}
        ).get("Item", {})
        return item.get("sheetStats", {}), item.get("sheetHeaders", {}), item.get("storageType", "")

    sheet_stats, sheet_headers, storage_type = await asyncio.to_thread(_get_upload_meta)
    if not sheet_stats:
        raise HTTPException(status_code=404, detail="업로드 정보를 찾을 수 없습니다.")

    xlsx_s3_key = f"ds-exports/{divisionId}/{divisionCode}_{importDate}.xlsx"
    xlsx_media = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"

    # ── S3 fast path: xlsx가 이미 S3에 있음 → 스트리밍 다운로드 ──
    if storage_type in ("s3", "s3-zip"):
        try:
            s3_client = get_s3_client()
            s3_obj = await asyncio.to_thread(
                lambda: s3_client.get_object(Bucket=S3_BUCKET_NAME, Key=xlsx_s3_key)
            )
            content_length = s3_obj["ContentLength"]

            def _stream_s3():
                body = s3_obj["Body"]
                try:
                    while True:
                        chunk = body.read(1024 * 1024)  # 1MB chunks
                        if not chunk:
                            break
                        yield chunk
                finally:
                    body.close()

            return StreamingResponse(
                _stream_s3(),
                media_type=xlsx_media,
                headers={
                    "Content-Disposition": f"attachment; filename*=UTF-8''{filename.replace(' ', '%20')}",
                    "Content-Length": str(content_length),
                },
            )
        except Exception as e:
            logger.info(f"DS export: S3 xlsx 미존재 ({xlsx_s3_key}), 빌드 진행: {e}")

    # ── s3-zip: ZIP에서 on-demand xlsx 빌드 → S3 캐싱 ──
    if storage_type == "s3-zip":
        zip_s3_key = f"ds-raw/{divisionId}/{divisionCode}_{importDate}.zip"
        zip_temp = f"/tmp/ds_export_{divisionId}_{divisionCode}_{importDate}.zip"
        try:
            s3_client = get_s3_client()
            await asyncio.to_thread(s3_client.download_file, S3_BUCKET_NAME, zip_s3_key, zip_temp)

            xlsx_bytes, _, _, _ = await asyncio.to_thread(
                _process_zip_to_xlsx_sync, zip_temp
            )

            # S3에 캐싱 (다음 export는 fast path)
            async def _cache_xlsx():
                try:
                    await asyncio.to_thread(
                        _upload_xlsx_to_s3_sync, xlsx_bytes, divisionId, divisionCode, importDate
                    )
                    logger.info(f"DS export: xlsx S3 캐싱 완료 {xlsx_s3_key}")
                except Exception as ce:
                    logger.warning(f"DS export: xlsx S3 캐싱 실패 (non-fatal): {ce}")

            asyncio.create_task(_cache_xlsx())

            return StreamingResponse(
                iter([xlsx_bytes]),
                media_type=xlsx_media,
                headers={
                    "Content-Disposition": f"attachment; filename*=UTF-8''{filename.replace(' ', '%20')}",
                    "Content-Length": str(len(xlsx_bytes)),
                },
            )
        except Exception as e:
            logger.error(f"DS export s3-zip build failed: {e}")
            raise HTTPException(status_code=500, detail=f"Export 빌드 실패: {str(e)[:200]}")
        finally:
            try:
                if os.path.exists(zip_temp):
                    os.remove(zip_temp)
            except Exception:
                pass

    # ── DynamoDB fallback: 기존 빌드 경로 ──
    xlsx_bytes = await asyncio.to_thread(
        _build_xlsx_sync, divisionId, divisionCode, importDate, division_name,
        sheet_stats, sheet_headers
    )

    # S3에 저장 (비치명적 — 이후 presign 경로로 빠르게 다운로드 가능)
    async def _save_to_s3():
        try:
            await asyncio.to_thread(
                _upload_xlsx_to_s3_sync, xlsx_bytes, divisionId, divisionCode, importDate
            )
            logger.info(f"DS export-xlsx: S3 저장 완료 {xlsx_s3_key}")
        except Exception as e:
            logger.warning(f"DS export-xlsx: S3 저장 실패 (non-fatal): {e}")

    asyncio.create_task(_save_to_s3())

    return StreamingResponse(
        iter([xlsx_bytes]),
        media_type=xlsx_media,
        headers={
            "Content-Disposition": f"attachment; filename*=UTF-8''{filename.replace(' ', '%20')}",
            "Content-Length": str(len(xlsx_bytes)),
        },
    )


@app.get("/ds/job/{job_id}")
async def ds_job_status(job_id: str):
    """DS 잡 상태 조회 — 브라우저가 3초 간격으로 폴링"""
    try:
        jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])
        resp = await asyncio.to_thread(
            lambda: jobs_table.get_item(Key={"jobId": job_id})
        )
        item = resp.get("Item")
        if not item:
            raise HTTPException(status_code=404, detail="Job not found")

        # queued 상태: 대기 순서 계산
        queue_position = None
        if item.get("status") == "queued":
            resp2 = await asyncio.to_thread(
                lambda: jobs_table.scan(
                    FilterExpression="#s = :s AND queuedAt <= :qt",
                    ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={
                        ":s": "queued",
                        ":qt": item.get("queuedAt", ""),
                    },
                )
            )
            queue_position = len(resp2.get("Items", []))

        return {
            "success": True,
            "job": {**decimal_to_native(item), "queuePosition": queue_position},
        }
    except HTTPException:
        raise
    except ClientError as e:
        logger.error(f"DS job status error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/ds/job/{job_id}")
async def ds_job_cancel(job_id: str):
    """DS 잡 취소 — queued 상태인 경우만 가능"""
    try:
        jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])
        item = jobs_table.get_item(Key={"jobId": job_id}).get("Item")
        if not item:
            raise HTTPException(status_code=404, detail="Job not found")
        if item.get("status") != "queued":
            raise HTTPException(status_code=400, detail="처리 중인 잡은 취소할 수 없습니다.")

        jobs_table.delete_item(Key={"jobId": job_id})

        # S3 임시 파일 삭제
        try:
            s3_key = item.get("s3Key", "")
            if s3_key and "/temp/" in s3_key:
                get_s3_client().delete_object(Bucket=S3_BUCKET_NAME, Key=s3_key)
        except Exception:
            pass

        return {"success": True}
    except HTTPException:
        raise
    except ClientError as e:
        logger.error(f"DS job cancel error: {e}")
        raise HTTPException(status_code=500, detail=str(e))


# ============================================================
# Run Server
# ============================================================

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=True
    )
