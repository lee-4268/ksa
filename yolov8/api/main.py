"""
FastAPI Server for Tower/Antenna Classification
Flutter PWA + Mobile Web Support
"""

import os
import json
import uuid
import shutil
from pathlib import Path
from typing import List, Optional, Dict
from datetime import datetime
from decimal import Decimal
import logging

import httpx
import boto3
from botocore.exceptions import ClientError
import numpy as np
from fastapi import FastAPI, File, UploadFile, HTTPException, Query, Form
from fastapi.middleware.cors import CORSMiddleware
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
    expires_in: int


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
    """Load model on startup"""
    try:
        load_model()
        print("Server started successfully!")
    except Exception as e:
        print(f"Warning: Could not load model on startup: {e}")


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


def get_s3_client():
    """Get boto3 S3 client"""
    return boto3.client('s3', region_name=S3_REGION)


def get_dynamodb_resource():
    """Get boto3 DynamoDB resource"""
    return boto3.resource('dynamodb', region_name=S3_REGION)


def get_dynamodb_client():
    """Get boto3 DynamoDB client"""
    return boto3.client('dynamodb', region_name=S3_REGION)


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
            "stationType", "stationOwner", "installationType", "inspectionDate",
            "memo", "photoKeys"
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
