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
from datetime import datetime
from decimal import Decimal
import logging

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
    # EC2 메모리 절약: 시작 시 모델 로드 안 함 (~200MB 절약)
    # /predict, /predict/ensemble 첫 호출 시 자동 로드됨
    print("Server started successfully! (YOLO model: lazy load)")


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
        "timestamp": datetime.now().isoformat()
    }


@app.get("/health", response_model=HealthResponse)
async def health_check():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "model_loaded": model is not None,
        "model_path": MODEL_PATH,
        "timestamp": datetime.now().isoformat()
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
                "timestamp": datetime.now().isoformat()
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
                "timestamp": datetime.now().isoformat()
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
            "timestamp": datetime.now().isoformat()
        }

    except Exception as e:
        logger.error(f"Feedback stats error: {e}")
        return {
            "success": False,
            "message": str(e),
            "timestamp": datetime.now().isoformat()
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
        "timestamp": datetime.now().isoformat()
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

        now = datetime.now().isoformat()
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
        expr_values = {":now": datetime.now().isoformat()}

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

        now = datetime.now().isoformat()
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
        expr_values = {":now": datetime.now().isoformat()}
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

        # 기존 데이터 존재 시 자동 삭제 (동일 divisionId+divisionCode+importDate)
        existing = uploads_table.get_item(Key={"divisionId": req.divisionId, "importDate": sk}).get("Item")
        if existing:
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

        now = datetime.now().isoformat()
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
    now = datetime.now().isoformat()
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
):
    """DS 데이터 리스트 조회 (페이징, 서버측 검색 지원)"""
    try:
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
    - DynamoDB records: 백그라운드 병렬 삭제 (1.8M행 기준 ~40초, EC2 무부하)
    """
    try:
        dynamodb = get_dynamodb_resource()
        uploads_table = dynamodb.Table(DYNAMODB_TABLES["ds_uploads"])

        dc = divisionCode or ""
        upload_sk = f"{dc}#{importDate}" if dc else importDate

        # 1. 시트 목록 먼저 조회 (uploads 삭제 전! 백그라운드 삭제에 필수)
        #    uploads 레코드를 먼저 삭제하면 background task에서 시트 목록을 읽을 수 없어
        #    sheet_names = [] → 레코드가 하나도 삭제되지 않는 버그 발생
        sheet_names = []
        try:
            upload_item = uploads_table.get_item(
                Key={"divisionId": divisionId, "importDate": upload_sk}
            ).get("Item", {})
            sheet_names = list(upload_item.get("sheetStats", {}).keys())
        except Exception as e:
            logger.warning(f"DS delete: sheet_names 조회 실패 (non-fatal): {e}")

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

        # 3. uploads 레코드 즉시 삭제 → 대시보드에서 즉시 사라짐
        uploads_table.delete_item(Key={"divisionId": divisionId, "importDate": upload_sk})

        # 4. DynamoDB records 백그라운드 삭제 (sheet_names 직접 전달 - uploads 삭제 후에도 정상 동작)
        background_tasks.add_task(_background_delete_records, divisionId, importDate, dc, sheet_names)

        logger.info(f"DS delete initiated (background): {divisionId}/{upload_sk}, sheets={len(sheet_names)}")
        return {"success": True, "deletedCount": 0}
    except ClientError as e:
        logger.error(f"DS delete error: {e}")
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
