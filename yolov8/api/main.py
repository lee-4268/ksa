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
import hmac as _hmac_mod
import hashlib
import base64
import time as _time_mod
import threading

import httpx
import boto3
from botocore.exceptions import ClientError
import numpy as np
from fastapi import FastAPI, File, UploadFile, HTTPException, Query, Form, BackgroundTasks, Request
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
    from openpyxl.utils import get_column_letter
    HAS_OPENPYXL = True
except ImportError:
    HAS_OPENPYXL = False

try:
    import xlsxwriter
    HAS_XLSXWRITER = True
except ImportError:
    HAS_XLSXWRITER = False

try:
    import psutil
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False

MEMORY_THRESHOLD_PCT = 80  # 메모리 사용률 이 이상이면 무거운 작업 차단 (2GB RAM 기준)

def _log_mem(label: str):
    """현재 프로세스 RSS + 시스템 가용 메모리 로깅."""
    if not HAS_PSUTIL:
        return
    proc = psutil.Process()
    rss_mb = proc.memory_info().rss / (1024 * 1024)
    vm = psutil.virtual_memory()
    avail_mb = vm.available / (1024 * 1024)
    logger.info(f"[MEM] {label} | RSS={rss_mb:.0f}MB | avail={avail_mb:.0f}MB | sys={vm.percent}%")

def _release_memory():
    """gc.collect + Linux malloc_trim → pymalloc이 해제한 메모리를 OS에 실제 반환."""
    gc.collect()
    try:
        import ctypes
        libc = ctypes.CDLL("libc.so.6")
        libc.malloc_trim(0)
    except Exception:
        pass  # Windows / non-glibc → skip

def _check_memory(operation: str = "작업"):
    """메모리 사용률 체크. 임계치 초과 시 HTTPException 발생."""
    if not HAS_PSUTIL:
        return
    mem = psutil.virtual_memory()
    if mem.percent >= MEMORY_THRESHOLD_PCT:
        logger.warning(f"메모리 부족 ({mem.percent}%) — {operation} 차단")
        raise HTTPException(
            status_code=503,
            detail=f"서버 메모리 부족 ({mem.percent}%). 잠시 후 다시 시도해주세요."
        )

# pandas는 lazy import (메모리 ~150MB 절약: 필요할 때만 로드)
HAS_PANDAS = True
pd = None  # placeholder

def _get_pandas():
    """pandas lazy loader — 첫 호출 시에만 import."""
    global pd, HAS_PANDAS
    if pd is not None:
        return pd
    try:
        import pandas as _pd
        pd = _pd
        return pd
    except ImportError:
        HAS_PANDAS = False
        logging.warning("pandas not installed - callname matching disabled")
        return None

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
    "audit_logs": os.getenv("DYNAMODB_AUDIT_TABLE", "kca-audit-logs"),
    "user_roles": os.getenv("DYNAMODB_USER_ROLES_TABLE", "kca-user-roles"),
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

# 같은 본부로 병합되는 코드 (전북70→서부30, 충북55→충청50)
DS_MERGED_CODES = {"70": "30", "55": "50"}
# 대표코드 → 함께 정리해야 할 파트너 코드
DS_PARTNER_CODES = {"30": ["70"], "50": ["55"]}

# ── 호출명칭 매칭 설정 ──────────────────────────────────────
CALLNAME_CSV_PREFIX = "callname-db/"
CALLNAME_CACHE_TTL = 86400  # 24시간
CALLNAME_SESSION_TTL = 1800  # 30분
CALLNAME_MAX_SESSIONS = 3
CALLNAME_USE_COLS = ["zpwina", "zpwino", "zpwiadr", "zpcode", "area_hdofc_nm", "ons_team_nm", "zpirty3", "eqp_ser_no"]
CALLNAME_POSSIBLE_CALLNAME_COLS = ["호출명칭", "callname", "CALLNAME", "호출명", "call_name"]
CALLNAME_POSSIBLE_TONGSI_COLS = ["통시", "통합시설코드", "zpcode"]
CALLNAME_POSSIBLE_ZPWINA_COLS = ["zpwina", "ZPWINA", "Zpwina", "호출명칭", "호출명"]
CALLNAME_POSSIBLE_ZPWINO_COLS = ["zpwino", "ZPWINO", "Zpwino", "허가번호", "허가번호O"]
CALLNAME_POSSIBLE_ACCESS_COLS = ["Access담당", "access담당", "ACCESS담당"]
CALLNAME_POSSIBLE_QUALITY_COLS = ["품질개선팀", "품질개선", "QI팀"]
CALLNAME_DB_TO_EXCEL_MAP = {
    "area_hdofc_nm": CALLNAME_POSSIBLE_ACCESS_COLS,
    "ons_team_nm": CALLNAME_POSSIBLE_QUALITY_COLS,
    "zpcode": CALLNAME_POSSIBLE_TONGSI_COLS,
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


class SetRoleRequest(BaseModel):
    empno: str
    role: str  # "admin", "manager", "member"


# 역할 기반 권한 체크 (DS 업로드/삭제 보호)
VALID_ROLES = {"admin", "manager", "member"}

# 부트스트랩 키: 최초 admin 설정 시 사용 (환경변수 필수, 미설정 시 비활성화)
ADMIN_BOOTSTRAP_KEY = os.environ.get("ADMIN_BOOTSTRAP_KEY")

# ── HMAC 토큰 인증 ─────────────────────────────────────────
AUTH_TOKEN_SECRET = os.environ.get("AUTH_TOKEN_SECRET", f"dev-fallback-{uuid.uuid4().hex}")
AUTH_TOKEN_EXPIRY = 2 * 3600  # 2시간

if AUTH_TOKEN_SECRET.startswith("dev-fallback-"):
    logger.warning("AUTH_TOKEN_SECRET 환경변수 미설정 — 개발용 임시 키 사용 중 (운영 시 반드시 설정)")


def _generate_token(empno: str) -> str:
    """HMAC-SHA256 토큰 생성: base64url(empno:expiry:signature)"""
    expiry = int(_time_mod.time()) + AUTH_TOKEN_EXPIRY
    payload = f"{empno}:{expiry}"
    sig = _hmac_mod.new(
        AUTH_TOKEN_SECRET.encode(), payload.encode(), hashlib.sha256
    ).hexdigest()
    token_raw = f"{payload}:{sig}"
    return base64.urlsafe_b64encode(token_raw.encode()).decode()


def _verify_token(token: str) -> str | None:
    """토큰 검증 → empno 반환. 무효/만료 시 None."""
    try:
        decoded = base64.urlsafe_b64decode(token.encode()).decode()
        parts = decoded.split(":")
        if len(parts) != 3:
            return None
        empno, expiry_str, sig = parts
        expiry = int(expiry_str)
        if _time_mod.time() > expiry:
            return None
        expected = _hmac_mod.new(
            AUTH_TOKEN_SECRET.encode(), f"{empno}:{expiry_str}".encode(), hashlib.sha256
        ).hexdigest()
        if not _hmac_mod.compare_digest(sig, expected):
            return None
        return empno
    except Exception:
        return None


async def _verify_auth(request: Request) -> str:
    """Bearer 토큰 검증. 실패 시 401."""
    auth_header = request.headers.get("Authorization", "")
    if auth_header.startswith("Bearer "):
        token = auth_header[7:]
        empno = _verify_token(token)
        if empno:
            return empno
        raise HTTPException(status_code=401, detail="토큰이 만료되었거나 유효하지 않습니다")

    raise HTTPException(status_code=401, detail="인증 정보 없음")


# ── S3 경로 검증 ───────────────────────────────────────────
ALLOWED_S3_READ_PREFIXES = ("photos/", "excel/", "feedback/", "ds-exports/", "ds-raw/")
ALLOWED_S3_DELETE_PREFIXES = ("photos/", "excel/", "feedback/")


def _validate_s3_key(key: str, allowed_prefixes: tuple) -> None:
    """S3 키 검증: 경로 조작 방지 + prefix 제한."""
    normalized = key.replace("\\", "/")
    if ".." in normalized or normalized.startswith("/"):
        raise HTTPException(status_code=400, detail="잘못된 S3 키")
    if not any(normalized.startswith(p) for p in allowed_prefixes):
        raise HTTPException(status_code=403, detail="허용되지 않은 S3 경로")


# ── Rate Limiting ──────────────────────────────────────────
class SimpleRateLimiter:
    """IP별 슬라이딩 윈도우 Rate Limiter. 메모리: ~100B/IP."""
    def __init__(self):
        self._store: dict[str, list[float]] = {}
        self._lock = threading.Lock()

    def is_allowed(self, key: str, max_requests: int, window_seconds: int) -> bool:
        now = _time_mod.time()
        cutoff = now - window_seconds
        with self._lock:
            timestamps = self._store.get(key, [])
            timestamps = [t for t in timestamps if t > cutoff]
            if len(timestamps) >= max_requests:
                self._store[key] = timestamps
                return False
            timestamps.append(now)
            self._store[key] = timestamps
            return True

    def cleanup(self):
        now = _time_mod.time()
        cutoff = now - 3600
        with self._lock:
            stale = [k for k, v in self._store.items() if not v or v[-1] < cutoff]
            for k in stale:
                del self._store[k]


_rate_limiter = SimpleRateLimiter()

MAX_PHOTO_SIZE = 10 * 1024 * 1024    # 10MB
MAX_EXCEL_SIZE = 50 * 1024 * 1024    # 50MB
MAX_DS_UPLOAD_SIZE = 200 * 1024 * 1024  # 200MB


def _get_client_ip(request: Request) -> str:
    forwarded = request.headers.get("X-Forwarded-For", "")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _check_rate_limit(request: Request, endpoint: str, max_req: int, window: int):
    ip = _get_client_ip(request)
    if not _rate_limiter.is_allowed(f"{endpoint}:{ip}", max_req, window):
        raise HTTPException(status_code=429, detail="요청 횟수 초과. 잠시 후 다시 시도해주세요.")


def _get_user_role_sync(empno: str) -> str:
    """kca-user-roles 테이블에서 role 조회. 없으면 'member' 반환."""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        resp = table.get_item(
            Key={"user_id": empno},
            ProjectionExpression="#r",
            ExpressionAttributeNames={"#r": "role"},
        )
        item = resp.get("Item")
        if item and item.get("role") in VALID_ROLES:
            return item["role"]
    except Exception as e:
        logger.warning(f"role 조회 실패 ({empno}): {e}")
    return "member"


def _ensure_user_roles_table():
    """서버 시작 시 kca-user-roles 테이블 자동 생성"""
    try:
        client = get_dynamodb_client()
        client.create_table(
            TableName=DYNAMODB_TABLES["user_roles"],
            KeySchema=[
                {"AttributeName": "user_id", "KeyType": "HASH"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "user_id", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        logger.info(f"DynamoDB table {DYNAMODB_TABLES['user_roles']} created")
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceInUseException":
            logger.warning(f"user_roles table creation error (non-fatal): {e}")


async def _require_role(request: Request, allowed_roles: set) -> str:
    """Bearer 토큰 검증 → role 확인. 401/403."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in allowed_roles:
        raise HTTPException(status_code=403, detail=f"권한 없음 (현재: {role}, 필요: {', '.join(allowed_roles)})")
    return empno


# ── 감사 로그 기록 ──────────────────────────────────────────
_admin_users_cache: list | None = None
_admin_users_cache_time: float = 0
ADMIN_USERS_CACHE_TTL = 60  # seconds


def _record_audit_log_sync(action: str, entity_type: str, entity_id: str,
                            user_id: str, details: dict | None = None):
    """감사 로그를 DynamoDB kca-audit-logs에 기록 (동기, to_thread로 호출)"""
    import time as _time
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["audit_logs"])
        now = datetime.now(timezone.utc).isoformat()
        log_id = str(uuid.uuid4())

        item = {
            "entityType": entity_type,
            "sk": f"{now}#{log_id}",
            "action": action,
            "entityId": entity_id,
            "userId": user_id,
            "timestamp": now,
            "canRollback": False,
            "ttl": int(_time.time()) + 90 * 86400,  # 90일 후 자동 삭제
        }

        # 사용자 이름 denormalization
        try:
            users_table = dynamodb.Table(DYNAMODB_TABLES["users"])
            user_resp = users_table.get_item(
                Key={"user_id": user_id},
                ProjectionExpression="#n",
                ExpressionAttributeNames={"#n": "name"},
            )
            if user_resp.get("Item"):
                item["userName"] = user_resp["Item"].get("name", user_id)
        except Exception:
            pass

        if details:
            item.update(details)

        table.put_item(Item=item)
        logger.info(f"audit: {action} {entity_type} {entity_id} by {user_id}")
    except Exception as e:
        logger.error(f"audit log write failed: {e}")


def _ensure_audit_table():
    """서버 시작 시 kca-audit-logs 테이블 자동 생성"""
    try:
        client = get_dynamodb_client()
        client.create_table(
            TableName=DYNAMODB_TABLES["audit_logs"],
            KeySchema=[
                {"AttributeName": "entityType", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "entityType", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        logger.info(f"DynamoDB table {DYNAMODB_TABLES['audit_logs']} created")
        # TTL 활성화
        client.update_time_to_live(
            TableName=DYNAMODB_TABLES["audit_logs"],
            TimeToLiveSpecification={"Enabled": True, "AttributeName": "ttl"},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceInUseException":
            logger.warning(f"audit table creation error (non-fatal): {e}")


def _list_all_users_sync() -> list:
    """kca-user-roles 스캔 → Users 테이블 개별 조회 (캐시 60초)

    공유 Users 테이블을 Scan하지 않음.
    kca-user-roles(우리 테이블)만 Scan하고, 각 user_id로 Users 테이블 get_item(읽기전용).
    """
    global _admin_users_cache, _admin_users_cache_time
    import time as _time
    now = _time.time()
    if _admin_users_cache is not None and (now - _admin_users_cache_time) < ADMIN_USERS_CACHE_TTL:
        return _admin_users_cache

    dynamodb = get_dynamodb_resource()
    roles_table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
    users_table = dynamodb.Table(DYNAMODB_TABLES["users"])

    # 1) kca-user-roles 테이블 전체 스캔 (우리 테이블, 소규모)
    role_items = []
    params: dict = {}
    while True:
        resp = roles_table.scan(**params)
        role_items.extend(resp.get("Items", []))
        if "LastEvaluatedKey" not in resp:
            break
        params["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

    logger.info(f"kca-user-roles 스캔 결과: {len(role_items)}명")

    # 2) 각 user_id로 Users 테이블에서 이름/본부/팀 조회 (읽기전용 get_item)
    users = []
    for role_item in role_items:
        uid = role_item.get("user_id", "")
        if not uid:
            continue
        user_role = role_item.get("role", "member")

        # Users 테이블에서 프로필 정보 조회 (ProjectionExpression 없이 전체 조회)
        try:
            user_resp = users_table.get_item(Key={"user_id": uid})
            user_info = user_resp.get("Item")
            if user_info:
                logger.info(f"Users 조회 성공 ({uid}): name={user_info.get('name')}, keys={list(user_info.keys())}")
            else:
                logger.warning(f"Users 테이블에 해당 user_id 없음: {uid}")
                user_info = {}
        except Exception as e:
            logger.warning(f"Users 테이블 조회 실패 ({uid}): {e}")
            user_info = {}

        users.append({
            "empno": uid,
            "name": user_info.get("name") or None,
            "region": user_info.get("region") or None,
            "team": user_info.get("team") or None,
            "email": user_info.get("email") or None,
            "phone": user_info.get("phone_number") or None,
            "role": user_role,
        })

    users.sort(key=lambda u: u.get("name", ""))
    _admin_users_cache = users
    _admin_users_cache_time = now
    return users


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


class DsEnqueueMultiRequest(BaseModel):
    """복수 ZIP 병합 업로드 잡 요청"""
    s3Keys: List[str] = []       # S3 임시 키 목록 (기존 방식)
    tempIds: List[str] = []      # EC2 로컬 임시 파일 ID 목록 (직접 전송)
    fileNames: List[str]         # 원본 파일명 목록
    uploadedBy: str              # 업로드한 사용자 ID


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
# CORS_ALLOWED_ORIGINS 환경변수로 허용 도메인 관리 (쉼표 구분)
_cors_env = os.environ.get("CORS_ALLOWED_ORIGINS", "")
ALLOWED_ORIGINS = [x.strip() for x in _cors_env.split(",") if x.strip()]
if not ALLOWED_ORIGINS:
    logger.warning("CORS_ALLOWED_ORIGINS 환경변수 미설정 — localhost만 허용")
    ALLOWED_ORIGINS = ["http://localhost:3000", "http://localhost:8080"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Accept", "X-Admin-Key"],
    expose_headers=["Content-Length", "Content-Disposition"],
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


_bounded_executor = ThreadPoolExecutor(max_workers=2)  # 2GB RAM: 동시 무거운 작업 2개 제한

@app.on_event("startup")
async def startup_event():
    """서버 시작 - YOLO 모델은 Lazy Loading (첫 분류 요청 시 로드)"""
    global _ds_job_worker_task
    # EC2 메모리 절약: 시작 시 모델 로드 안 함 (~200MB 절약)
    # /predict, /predict/ensemble 첫 호출 시 자동 로드됨
    if HAS_PSUTIL:
        mem = psutil.virtual_memory()
        print(f"Server started! RAM: {mem.total // (1024*1024)}MB, used: {mem.percent}%")
    else:
        print("Server started successfully! (YOLO model: lazy load)")
    # DS 잡 테이블 자동 생성 (없으면) + stuck 잡 복구 + 워커 시작
    asyncio.create_task(_ensure_ds_jobs_table())
    asyncio.create_task(asyncio.to_thread(_ensure_audit_table))
    asyncio.create_task(asyncio.to_thread(_ensure_user_roles_table))
    asyncio.create_task(_recover_stuck_jobs())
    _ds_job_worker_task = asyncio.create_task(_job_worker_loop())

    # 설치확인서 조회 캐시 미리 빌드 (백그라운드) + 매일 00:00 자동 갱신
    asyncio.create_task(asyncio.to_thread(_cert_cache_load))
    asyncio.create_task(_cert_cache_daily_scheduler())

    # Rate limiter + 호출명칭 세션 5분 주기 정리
    async def _rl_cleanup():
        while True:
            await asyncio.sleep(300)
            _rate_limiter.cleanup()
            _cleanup_callname_sessions()
    asyncio.create_task(_rl_cleanup())

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
    conf_threshold: float = Query(0.5, ge=0.0, le=1.0, description="Confidence threshold"),
    request: Request = None,
):
    """
    Classify a single image

    - Upload one image
    - Returns prediction with confidence score
    """
    await _verify_auth(request)
    _check_memory("YOLO 이미지 분류")
    _check_rate_limit(request, "predict", 10, 60)

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
        logger.error(f"predict failed: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")

    finally:
        if file_path:
            cleanup_file(file_path)


@app.post("/predict/ensemble", response_model=EnsemblePredictionResponse)
async def predict_ensemble(
    files: List[UploadFile] = File(..., description="Multiple image files to classify"),
    method: str = Query("mean", regex="^(mean|max|vote)$", description="Ensemble method"),
    conf_threshold: float = Query(0.5, ge=0.0, le=1.0, description="Confidence threshold"),
    request: Request = None,
):
    """
    Classify multiple images and combine predictions

    - Upload multiple images (different angles of same tower)
    - Combines predictions using ensemble method
    - Methods: mean (average), max (maximum), vote (voting)
    """
    await _verify_auth(request)
    _check_memory("YOLO 앙상블 분류")
    _check_rate_limit(request, "predict_ensemble", 5, 60)

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
        logger.error(f"predict_ensemble failed: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")

    finally:
        for file_path in file_paths:
            cleanup_file(file_path)


@app.post("/feedback", response_model=FeedbackResponse)
async def submit_feedback(
    file: UploadFile = File(..., description="Image file"),
    original_class: str = Form(..., description="Original predicted class (English)"),
    corrected_class: str = Form(..., description="User-corrected class (English)"),
    request: Request = None,
):
    """
    Submit feedback for model improvement

    - User can correct classification results
    - Images are stored in S3 for future retraining
    - Storage path: feedback/{corrected_class}/{timestamp}_{filename}
    """
    await _verify_auth(request)
    _check_rate_limit(request, "feedback", 10, 60)

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
        raise HTTPException(status_code=500, detail="서버 내부 오류")

    finally:
        if file_path:
            cleanup_file(file_path)


@app.get("/feedback/stats")
async def get_feedback_stats(request: Request = None):
    """
    Get feedback statistics

    - Shows count of feedback images per class
    - Useful for monitoring data collection progress
    """
    await _verify_auth(request)
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
            "message": "서버 내부 오류",
            "timestamp": datetime.now(timezone.utc).isoformat()
        }


# ============================================================
# Auth Proxy Endpoint (CORS 우회용)
# ============================================================

SSO_LOGIN_URL = "https://auth.skons.net/accounts/sko/sso/login/"


@app.post("/auth/login")
async def proxy_sso_login(req: LoginRequest, request: Request):
    """SKons SSO 로그인 프록시 + 토큰 발급"""
    _check_rate_limit(request, "login", 5, 60)
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.post(
                SSO_LOGIN_URL,
                json={"username": req.username, "password": req.password},
                headers={"Content-Type": "application/json"},
            )
        sso_data = response.json()

        if response.status_code == 200 and sso_data.get("result") == "ok":
            token = _generate_token(req.username)
            await asyncio.to_thread(_ensure_user_in_roles_sync, req.username)
            return JSONResponse(
                status_code=200,
                content={**sso_data, "token": token, "expiresIn": AUTH_TOKEN_EXPIRY},
            )

        return JSONResponse(status_code=response.status_code, content=sso_data)
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
async def list_users_count(request: Request = None):
    """사용자 데이터 통계"""
    await _verify_auth(request)
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
async def create_category(category: CategoryCreate, request: Request):
    """카테고리 생성"""
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/categories")
async def list_categories(owner: str = Query(..., description="소유자 사번"), request: Request = None):
    """카테고리 목록 조회 (owner 필터)"""
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/categories/{category_id}")
async def get_category(category_id: str, request: Request = None):
    """카테고리 단일 조회"""
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.put("/categories/{category_id}")
async def update_category(category_id: str, request: Request, name: str = None, originalExcelKey: str = None):
    """카테고리 업데이트"""
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.delete("/categories/{category_id}")
async def delete_category(category_id: str, request: Request = None):
    """카테고리 삭제"""
    await _verify_auth(request)
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["categories"])

        table.delete_item(Key={"id": category_id})

        return {"success": True, "message": "Category deleted"}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


# ============================================================
# DynamoDB CRUD Endpoints - Stations
# ============================================================

@app.post("/stations")
async def create_station(station: StationCreate, request: Request):
    """무선국 생성"""
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/stations")
async def list_stations(
    owner: str = Query(..., description="소유자 사번"),
    categoryId: str = Query(None, description="카테고리 ID (선택)"),
    request: Request = None,
):
    """무선국 목록 조회"""
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/stations/{station_id}")
async def get_station(station_id: str, request: Request = None):
    """무선국 단일 조회"""
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.put("/stations/{station_id}")
async def update_station(station_id: str, station: StationUpdate, request: Request = None):
    """무선국 업데이트"""
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.delete("/stations/{station_id}")
async def delete_station(station_id: str, request: Request = None):
    """무선국 삭제"""
    await _verify_auth(request)
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["stations"])

        table.delete_item(Key={"id": station_id})

        return {"success": True, "message": "Station deleted"}
    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


# ============================================================
# S3 Upload/Download Endpoints
# ============================================================

@app.post("/upload/photo")
async def upload_photo(
    file: UploadFile = File(...),
    owner: str = Form(...),
    stationId: str = Form(...),
    request: Request = None,
):
    """사진 S3 업로드"""
    await _verify_auth(request)

    if not validate_image(file):
        raise HTTPException(status_code=400, detail="Invalid image format")

    try:
        s3_client = get_s3_client()

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        ext = Path(file.filename).suffix.lower()
        s3_key = f"photos/{owner}/{stationId}/{timestamp}{ext}"

        content = await file.read()
        if len(content) > MAX_PHOTO_SIZE:
            raise HTTPException(status_code=400, detail=f"파일 크기 초과 (최대 {MAX_PHOTO_SIZE // 1024 // 1024}MB)")
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=s3_key,
            Body=content,
            ContentType=file.content_type
        )

        return {"success": True, "key": s3_key}
    except ClientError as e:
        logger.error(f"S3 upload error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.post("/upload/excel")
async def upload_excel(
    file: UploadFile = File(...),
    owner: str = Form(...),
    categoryName: str = Form(...),
    request: Request = None,
):
    """원본 Excel S3 업로드"""
    await _verify_auth(request)

    if not file.filename.endswith(('.xlsx', '.xls')):
        raise HTTPException(status_code=400, detail="Invalid Excel format")

    try:
        s3_client = get_s3_client()

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        safe_name = categoryName.replace("/", "_").replace("\\", "_")
        s3_key = f"excel/{owner}/{safe_name}_{timestamp}.xlsx"

        content = await file.read()
        if len(content) > MAX_EXCEL_SIZE:
            raise HTTPException(status_code=400, detail=f"파일 크기 초과 (최대 {MAX_EXCEL_SIZE // 1024 // 1024}MB)")
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=s3_key,
            Body=content,
            ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        )

        return {"success": True, "key": s3_key}
    except ClientError as e:
        logger.error(f"S3 upload error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/download/presigned")
async def get_presigned_url(key: str = Query(..., description="S3 object key"), request: Request = None):
    """S3 Presigned URL 생성 (다운로드용)"""
    await _verify_auth(request)
    _validate_s3_key(key, ALLOWED_S3_READ_PREFIXES)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/download/photo")
async def download_photo(key: str = Query(..., description="S3 object key"), request: Request = None):
    """S3 이미지를 EC2 경유로 스트리밍 (CORS 우회)"""
    await _verify_auth(request)
    _validate_s3_key(key, ALLOWED_S3_READ_PREFIXES)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.delete("/storage/{key:path}")
async def delete_s3_object(key: str, request: Request = None):
    """S3 객체 삭제"""
    await _verify_auth(request)
    _check_rate_limit(request, "storage_delete", 10, 60)
    _validate_s3_key(key, ALLOWED_S3_DELETE_PREFIXES)
    try:
        s3_client = get_s3_client()
        s3_client.delete_object(Bucket=S3_BUCKET_NAME, Key=key)
        return {"success": True, "message": f"Deleted: {key}"}
    except ClientError as e:
        logger.error(f"S3 delete error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


# ============================================================
# DynamoDB Users (i-NET 사용자 - 기존 테이블 사용)
# ============================================================

def _ensure_user_in_roles_sync(empno: str):
    """kca-user-roles 테이블에 사용자가 없으면 member로 자동 등록 (로그인 시 호출)"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        resp = table.get_item(
            Key={"user_id": empno},
            ProjectionExpression="user_id",
        )
        if not resp.get("Item"):
            table.put_item(Item={"user_id": empno, "role": "member"})
            logger.info(f"kca-user-roles 자동 등록: {empno} (member)")
            # 캐시 무효화
            global _admin_users_cache
            _admin_users_cache = None
    except Exception as e:
        logger.warning(f"kca-user-roles 자동 등록 실패 ({empno}): {e}")


@app.get("/users/{empno}")
async def get_user_by_empno(empno: str, request: Request = None):
    """
    사번으로 사용자 정보 조회 (DynamoDB)

    기존 i-NET 사용자 테이블에서 조회 + kca-user-roles 자동 등록
    """
    await _verify_auth(request)
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["users"])

        # user_id가 PK
        response = table.get_item(Key={"user_id": empno})
        user = response.get("Item")

        if not user:
            return {"success": False, "empno": empno, "message": "User not found"}

        # kca-user-roles 테이블에 자동 등록 (없으면 member로)
        await asyncio.to_thread(_ensure_user_in_roles_sync, empno)

        # role은 kca-user-roles에서 조회
        role = await asyncio.to_thread(_get_user_role_sync, empno)

        return {
            "success": True,
            "empno": empno,
            "name": user.get("name"),
            "region": user.get("region"),
            "team": user.get("team"),
            "email": user.get("email"),
            "phone": user.get("phone_number"),
            "role": role,
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
                "role": "member",
            }
        return {"success": False, "empno": empno}


@app.put("/admin/set-role")
async def set_user_role(req: SetRoleRequest, request: Request):
    """사용자 역할 설정 — admin 또는 부트스트랩 키 필요"""
    if req.role not in VALID_ROLES:
        raise HTTPException(status_code=400, detail=f"유효하지 않은 역할: {req.role} (가능: {', '.join(VALID_ROLES)})")

    # 인증: admin 역할 또는 부트스트랩 키
    admin_key = request.headers.get("X-Admin-Key", "").strip()

    authorized = False
    caller_id = None
    if ADMIN_BOOTSTRAP_KEY and admin_key == ADMIN_BOOTSTRAP_KEY:
        authorized = True
        logger.info(f"role 변경 (부트스트랩): {req.empno} → {req.role}")
    else:
        try:
            caller_id = await _verify_auth(request)
            caller_role = await asyncio.to_thread(_get_user_role_sync, caller_id)
            if caller_role == "admin":
                authorized = True
                logger.info(f"role 변경 (admin {caller_id}): {req.empno} → {req.role}")
        except HTTPException:
            pass

    if not authorized:
        raise HTTPException(status_code=403, detail="권한 없음 (admin 또는 부트스트랩 키 필요)")

    try:
        # 변경 전 역할 조회 (감사 로그용)
        old_role = await asyncio.to_thread(_get_user_role_sync, req.empno)

        # kca-user-roles 테이블에 역할 저장 (Users 테이블은 건드리지 않음)
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        table.put_item(Item={"user_id": req.empno, "role": req.role})

        # 감사 로그 기록
        actor = caller_id or "bootstrap"
        await asyncio.to_thread(
            _record_audit_log_sync, "UPDATE", "User", req.empno, actor,
            {
                "previousData": json.dumps({"role": old_role}),
                "newData": json.dumps({"role": req.role}),
                "changedFields": ["role"],
            },
        )

        # 캐시 무효화
        global _admin_users_cache
        _admin_users_cache = None

        return {"success": True, "empno": req.empno, "role": req.role}
    except Exception as e:
        logger.error(f"role 설정 실패: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/admin/users")
async def admin_list_users(
    request: Request,
    search: str | None = None,
    region: str | None = None,
    role: str | None = None,
):
    """사용자 목록 조회 — admin/manager만"""
    await _require_role(request, {"admin", "manager"})

    try:
        users = await asyncio.to_thread(_list_all_users_sync)

        # 필터링
        filtered = users
        if search:
            q = search.lower()
            filtered = [u for u in filtered
                        if q in u.get("name", "").lower()
                        or q in u.get("empno", "").lower()
                        or q in u.get("email", "").lower()]
        if region:
            filtered = [u for u in filtered if u.get("region", "") == region]
        if role:
            filtered = [u for u in filtered if u.get("role", "member") == role]

        return {"success": True, "users": filtered, "total": len(filtered)}
    except Exception as e:
        logger.error(f"admin users list failed: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/admin/audit-logs")
async def admin_list_audit_logs(
    request: Request,
    entityType: str | None = None,
    action: str | None = None,
    limit: int = 50,
):
    """감사 로그 조회 — admin/manager만"""
    await _require_role(request, {"admin", "manager"})

    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["audit_logs"])

        if entityType:
            # Query by PK (entityType), newest first
            params: dict = {
                "KeyConditionExpression": "entityType = :et",
                "ExpressionAttributeValues": {":et": entityType},
                "ScanIndexForward": False,
                "Limit": limit,
            }
            if action:
                params["FilterExpression"] = "#a = :a"
                params["ExpressionAttributeNames"] = {"#a": "action"}
                params["ExpressionAttributeValues"][":a"] = action
            resp = await asyncio.to_thread(lambda: table.query(**params))
        else:
            # Scan all (no PK filter)
            params = {"Limit": limit}
            if action:
                params["FilterExpression"] = "#a = :a"
                params["ExpressionAttributeNames"] = {"#a": "action"}
                params["ExpressionAttributeValues"] = {":a": action}
            resp = await asyncio.to_thread(lambda: table.scan(**params))

        logs = []
        for item in resp.get("Items", []):
            sk = item.get("sk", "")
            log_id = sk.split("#")[-1] if "#" in sk else sk
            logs.append({
                "id": log_id,
                "action": item.get("action", "UPDATE"),
                "entityType": item.get("entityType", ""),
                "entityId": item.get("entityId", ""),
                "userId": item.get("userId", ""),
                "userName": item.get("userName"),
                "timestamp": item.get("timestamp", ""),
                "previousData": item.get("previousData"),
                "newData": item.get("newData"),
                "changedFields": item.get("changedFields"),
                "canRollback": item.get("canRollback", False),
            })

        # Scan 결과는 시간순 정렬 안 됨 → timestamp 역순 정렬
        logs.sort(key=lambda x: x.get("timestamp", ""), reverse=True)

        return {"success": True, "logs": logs}
    except Exception as e:
        logger.error(f"audit logs list failed: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


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
    """kca-ds-jobs 테이블이 없으면 자동 생성 + TTL 활성화"""
    await asyncio.sleep(1)
    dynamodb_client = get_dynamodb_client()
    try:
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
    # TTL 활성화 (이미 활성화돼 있으면 무시)
    try:
        dynamodb_client.update_time_to_live(
            TableName=DYNAMODB_TABLES["ds_jobs"],
            TimeToLiveSpecification={"Enabled": True, "AttributeName": "ttl"},
        )
        logger.info(f"DS jobs TTL enabled (ttl attribute, 7일)")
    except ClientError:
        pass  # 이미 활성화됨


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
    """DS 파일 분류: base / numbered / spt / hundred / skipped
    hundred: (100) 파일 → '일반사항' 시트를 '일반사항(검사전)'으로 변환
    """
    lower = filename.lower()
    if "(100)" in filename:
        return "hundred"
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
    """동기: 잡 완료 처리 (7일 TTL)"""
    jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])
    now = datetime.now(timezone.utc).isoformat()
    ttl = int(_time_mod.time()) + 7 * 86400  # 7일 후 자동 삭제
    jobs_table.update_item(
        Key={"jobId": job_id},
        UpdateExpression=(
            "SET #s=:s, completedAt=:ca, stage=:g, #p=:p, "
            "divisionId=:did, divisionCode=:dc, importDate=:idate, "
            "sheetStats=:ss, totalRows=:tr, #ttl=:ttl"
        ),
        ExpressionAttributeNames={"#s": "status", "#p": "percent", "#ttl": "ttl"},
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
            ":ttl": ttl,
        },
    )


def _mark_job_failed_sync(job_id: str, error: str):
    """동기: 잡 실패 처리 (7일 TTL)"""
    jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])
    now = datetime.now(timezone.utc).isoformat()
    ttl = int(_time_mod.time()) + 7 * 86400  # 7일 후 자동 삭제
    jobs_table.update_item(
        Key={"jobId": job_id},
        UpdateExpression="SET #s=:s, completedAt=:ca, stage=:g, #e=:e, #ttl=:ttl",
        ExpressionAttributeNames={"#s": "status", "#e": "error", "#ttl": "ttl"},
        ExpressionAttributeValues={
            ":s": "failed",
            ":ca": now,
            ":g": "실패",
            ":e": error[:500],
            ":ttl": ttl,
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
                    "ProjectionExpression": "jobId, queuedAt, s3Key, s3Keys, tempIds, fileName, fileNames, uploadedBy, #s",
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




def _read_xlsx_paginated_sync(xlsx_path: str, sheet_name: str,
                               division_id: str, import_date: str,
                               division_code: str, offset: int = 0,
                               limit: int = 100, search: Optional[str] = None) -> dict:
    """S3 xlsx에서 페이지네이션 읽기 — 경량 ZIP+XML 파서 사용 (openpyxl 제거).
    GET /ds/data 응답 형식과 100% 동일 → 프론트엔드 수정 불필요.
    메모리: sharedStrings list[str]만 임시 로드 후 즉시 해제."""
    dc_part = f"#{division_code}" if division_code else ""

    try:
        headers = []
        num_cols = 0
        items = []
        row_idx = 0
        has_more = False

        if search:
            search_lower = search.lower()
            scanned = 0
            found_limit = False

            for rn, vals in _iter_xlsx_rows_light(xlsx_path, sheet_name=sheet_name):
                if rn == 0:
                    # 헤더 (연속된 비어있지 않은 셀만)
                    for v in vals:
                        if v.strip():
                            headers.append(v.strip())
                        else:
                            break
                    num_cols = len(headers)
                    continue

                trimmed = vals[:num_cols]
                data = {}
                for i, h in enumerate(headers):
                    if i < len(trimmed) and trimmed[i]:
                        data[h] = trimmed[i]
                if not data:
                    row_idx += 1
                    continue

                if any(search_lower in str(v).lower() for v in data.values()):
                    if found_limit:
                        has_more = True
                        break
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
                            found_limit = True
                    scanned += 1
                row_idx += 1

            next_offset = offset + len(items)
        else:
            for rn, vals in _iter_xlsx_rows_light(xlsx_path, sheet_name=sheet_name):
                if rn == 0:
                    for v in vals:
                        if v.strip():
                            headers.append(v.strip())
                        else:
                            break
                    num_cols = len(headers)
                    continue

                if row_idx < offset:
                    row_idx += 1
                    continue
                if len(items) >= limit:
                    has_more = True
                    break

                trimmed = vals[:num_cols]
                data = {}
                for i, h in enumerate(headers):
                    if i < len(trimmed) and trimmed[i]:
                        data[h] = trimmed[i]

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

        # JSON round-trip: items 내 문자열이 sharedStrings 아레나를 참조 →
        # 새 문자열 객체로 복사하여 아레나 해제 가능하게 함
        if items:
            items = json.loads(json.dumps(items, ensure_ascii=False))

        _release_memory()

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
        _release_memory()
        logger.error(f"DS xlsx paginated read error: {e}")
        return {"success": True, "items": [], "count": 0, "lastEvaluatedKey": None}


def _fix_zip_filename(name: str) -> str:
    """ZIP 파일명 한글 복원: latin-1로 깨진 이름 → CP949 디코딩 시도"""
    try:
        raw = name.encode("latin-1")
        return raw.decode("cp949")
    except (UnicodeDecodeError, UnicodeEncodeError):
        return name


def _merge_zips_sync(s3_keys: list, file_names: list, job_id: str,
                     progress_cb=None, temp_ids: list = None) -> str:
    """복수 소스 ZIP → 단일 결합 ZIP (디스크 효율: 소스 1개씩 처리 후 삭제)

    각 소스 ZIP에서 XLS 파일만 추출하여 결합 ZIP에 기록.
    파일명 충돌 방지: 소스 ZIP 이름을 디렉토리 접두사로 사용.
    temp_ids 있으면 로컬 /tmp에서 직접 읽기, 없으면 S3 다운로드.

    Returns: 결합 ZIP 경로
    """
    merged_path = f"/tmp/ds_merged_{job_id}.zip"
    use_local = bool(temp_ids)
    sources = temp_ids if use_local else s3_keys
    total = len(sources)
    xls_count = 0
    s3 = None if use_local else get_s3_client()

    with zipfile.ZipFile(merged_path, "w", zipfile.ZIP_STORED) as out_zip:
        for idx, (src_id, fname) in enumerate(zip(sources, file_names)):
            if use_local:
                src_path = f"/tmp/ds_temp_{src_id}.zip"
            else:
                src_path = f"/tmp/ds_{job_id}_src_{idx}.zip"
            try:
                if progress_cb:
                    label = "ZIP 읽는 중" if use_local else "ZIP 다운로드 중"
                    progress_cb(
                        f"{label}... ({idx + 1}/{total})",
                        3 + (idx / total) * 25,
                    )
                if not use_local:
                    s3.download_file(S3_BUCKET_NAME, src_id, src_path)

                # 소스 ZIP 이름 → 디렉토리 접두사 (파일명 충돌 방지)
                prefix = os.path.splitext(os.path.basename(fname))[0]
                with zipfile.ZipFile(src_path, "r") as src_zip:
                    for entry in src_zip.namelist():
                        fixed_entry = _fix_zip_filename(entry)
                        base = os.path.basename(fixed_entry)
                        if not base.lower().endswith(".xls"):
                            continue
                        if base.lower().endswith(".xlsx"):
                            continue
                        if base.startswith("~") or base.startswith("."):
                            continue
                        out_name = f"{prefix}/{base}"
                        data = src_zip.read(entry)  # 원본 entry로 읽기
                        out_zip.writestr(out_name, data)
                        xls_count += 1
                        del data
            finally:
                # 로컬 temp 파일도 처리 후 삭제 (디스크 절약)
                if os.path.exists(src_path):
                    os.remove(src_path)

    if xls_count == 0:
        if os.path.exists(merged_path):
            os.remove(merged_path)
        raise ValueError("ZIP 파일 안에 .xls 파일이 없습니다.")

    logger.info(
        f"ZIP 병합 완료: {total}개 ZIP → {xls_count}개 XLS "
        f"({os.path.getsize(merged_path):,} bytes)"
    )
    return merged_path


def _parse_zip_metadata_sync(zip_temp_path: str, progress_cb=None) -> tuple:
    """ZIP → 메타데이터만 초고속 파싱 (xlsx 빌드 완전 생략)

    XLS 파일별로 xlrd.open_workbook → sheet.nrows + 헤더(row 0) 만 추출.
    데이터 행은 한 줄도 읽지 않음 → 10만행 ZIP도 ~5초.

    (100) 파일: '일반사항' 시트 → '일반사항(검사전)' 으로 변환 (ds_merge.js 동일)
    헤더 union: 같은 시트에 대해 모든 파일의 헤더를 합집합으로 수집

    Returns: (sheet_stats, total_rows, sheet_headers, file_manifest)
      sheet_stats:   {sheet_name: row_count}
      total_rows:    전체 행수
      sheet_headers: {sheet_name: [col1, col2, ...]}
      file_manifest: {sheet_name: [{"f": filename, "r": row_count, "orig": orig_sheet}, ...]}
        → "orig" 필드: XLS 내 실제 시트명 (리네임된 경우만 존재)
    """
    if not HAS_XLRD:
        raise RuntimeError("xlrd not installed on server")

    sheet_stats: Dict[str, int] = {}
    sheet_headers: Dict[str, list] = {}
    file_manifest: Dict[str, list] = {}  # {sheet_name: [{"f": fname, "r": rows}, ...]}
    total_rows = 0

    # (100) 파일인지 빠르게 판별하기 위한 셋
    hundred_files: set = set()

    with zipfile.ZipFile(zip_temp_path, "r") as zf:
        all_names = zf.namelist()
        # ZIP 파일명 한글 복원 (원본 entry → 고친 이름 매핑)
        name_map = {n: _fix_zip_filename(n) for n in all_names}
        xls_names = [n for n in all_names
                     if name_map[n].lower().endswith(".xls")
                     and not os.path.basename(name_map[n]).startswith("~")]

        classified: Dict[str, list] = {"base": [], "numbered": [], "spt": [], "hundred": []}
        for fname in xls_names:
            base_fname = os.path.basename(name_map[fname])
            if not base_fname:
                continue
            cls = _classify_ds_file(base_fname)
            classified[cls].append(fname)
            if cls == "hundred":
                hundred_files.add(fname)

        # (100) 파일도 처리 대상에 포함 (마지막에 추가 — ds_merge.js 순서 일치)
        process_list = classified["base"] + classified["numbered"] + classified["spt"] + classified["hundred"]
        if not process_list:
            raise ValueError("처리할 XLS 파일 없음")

        logger.info(f"DS metadata parse: {len(process_list)}개 XLS "
                    f"(base={len(classified['base'])}, numbered={len(classified['numbered'])}, "
                    f"spt={len(classified['spt'])}, hundred={len(classified['hundred'])})")

        total_files = len(process_list)
        for file_idx, fname in enumerate(process_list):
            base_fname = os.path.basename(name_map[fname]) or name_map[fname]
            is_hundred = fname in hundred_files

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
                orig_sheet_name = sheet.name.strip()
                if sheet.nrows < 2:
                    continue

                # (100) 파일: 모든 시트에 '(검사전)' 접미사 추가
                if is_hundred:
                    sheet_name = f"{orig_sheet_name}(검사전)"
                else:
                    sheet_name = orig_sheet_name

                data_rows = sheet.nrows - 1  # 헤더 행 제외

                # 헤더 추출
                header_map = []
                for col in range(sheet.ncols):
                    h = _xlrd_cell_to_str(sheet, 0, col)
                    if h:
                        header_map.append((col, h))
                if not header_map:
                    continue

                if sheet_name not in sheet_headers:
                    # 첫 등장 시트: 초기화
                    sheet_headers[sheet_name] = [name for _, name in header_map]
                    sheet_stats[sheet_name] = 0
                    file_manifest[sheet_name] = []
                else:
                    # 헤더 union: 이후 파일에 새 컬럼이 있으면 추가
                    existing = set(sheet_headers[sheet_name])
                    for _, name in header_map:
                        if name not in existing:
                            sheet_headers[sheet_name].append(name)
                            existing.add(name)

                sheet_stats[sheet_name] += data_rows
                # manifest에 원본 시트명 기록 (리네임된 경우 "orig" 필드 추가)
                entry: dict = {"f": fname, "r": data_rows}
                if sheet_name != orig_sheet_name:
                    entry["orig"] = orig_sheet_name
                file_manifest[sheet_name].append(entry)
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

    file_manifest_entries: [{"f": "file.xls", "r": 3000, "orig": "일반사항"}, ...]
      — 시트에 기여하는 XLS 파일 목록. "orig" 필드가 있으면 XLS 내 실제 시트명.
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
                # XLS 내 실제 시트명 (리네임된 경우 "orig" 사용)
                xls_sheet_name = entry.get("orig", sheet_name)
                try:
                    xls_bytes = zf.read(fname)
                    wb = xlrd.open_workbook(file_contents=xls_bytes)
                except Exception:
                    global_row_idx += entry["r"]
                    continue

                target_sheet = None
                for si in range(wb.nsheets):
                    s = wb.sheet_by_index(si)
                    if s.name.strip() == xls_sheet_name:
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
                # XLS 내 실제 시트명 (리네임된 경우 "orig" 사용)
                xls_sheet_name = entry.get("orig", sheet_name)

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
                    if s.name.strip() == xls_sheet_name:
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


def _process_zip_to_xlsx_sync(zip_temp_path: str, progress_cb=None,
                               xlsx_out_path: str = None) -> tuple:
    """ZIP → XLS 파싱 → xlsx 직접 빌드 (2-pass 스트리밍, 디스크 기반)

    Pass 1: 헤더 수집 (행 0만 읽기, 메모리 ~수 KB)
    Pass 2: xlsxwriter → 디스크 파일에 직접 쓰기 (메모리 ~수 MB)

    Returns: (xlsx_path, sheet_stats, total_rows, sheet_headers)
    progress_cb: Optional[Callable(stage, percent)] — 파일별 진행률 콜백
    xlsx_out_path: xlsx 출력 경로 (미지정 시 자동 생성)
    """
    if not HAS_XLRD:
        raise RuntimeError("xlrd not installed on server")
    if not HAS_XLSXWRITER:
        raise RuntimeError("xlsxwriter not installed on server")

    sheet_stats: Dict[str, int] = {}
    sheet_headers: Dict[str, list] = {}
    total_rows = 0

    with zipfile.ZipFile(zip_temp_path, "r") as zf:
        all_names = zf.namelist()
        # ZIP 파일명 한글 복원 (원본 entry → 고친 이름 매핑)
        name_map = {n: _fix_zip_filename(n) for n in all_names}
        xls_names = [n for n in all_names
                     if name_map[n].lower().endswith(".xls")
                     and not os.path.basename(name_map[n]).startswith("~")]

        classified: Dict[str, list] = {"base": [], "numbered": [], "spt": [], "hundred": []}
        hundred_files: set = set()
        for fname in xls_names:
            base_fname = os.path.basename(name_map[fname])
            if not base_fname:
                continue
            cls = _classify_ds_file(base_fname)
            classified[cls].append(fname)
            if cls == "hundred":
                hundred_files.add(fname)

        process_list = classified["base"] + classified["numbered"] + classified["spt"] + classified["hundred"]
        if not process_list:
            raise ValueError("처리할 XLS 파일 없음")

        total_files = len(process_list)
        logger.info(f"DS xlsx build: {total_files}개 XLS "
                    f"(base={len(classified['base'])}, numbered={len(classified['numbered'])}, "
                    f"spt={len(classified['spt'])}, hundred={len(classified['hundred'])})")

        # ── Pass 1: 헤더만 수집 (행 0) ──
        if progress_cb:
            progress_cb("헤더 분석 중...", 5)

        for fname in process_list:
            is_hundred = fname in hundred_files
            try:
                xls_bytes = zf.read(fname)
                workbook = xlrd.open_workbook(file_contents=xls_bytes)
            except Exception as e:
                logger.warning(f"DS xlsx Pass1: {fname} 실패: {e}")
                continue

            for sheet_idx in range(workbook.nsheets):
                sheet = workbook.sheet_by_index(sheet_idx)
                orig_sheet_name = sheet.name.strip()
                if sheet.nrows < 2:
                    continue

                if is_hundred:
                    sheet_name = f"{orig_sheet_name}(검사전)"
                else:
                    sheet_name = orig_sheet_name

                headers = []
                for col in range(sheet.ncols):
                    h = _xlrd_cell_to_str(sheet, 0, col)
                    if h:
                        headers.append(h)
                if not headers:
                    continue

                if sheet_name not in sheet_headers:
                    sheet_headers[sheet_name] = list(headers)
                else:
                    existing = set(sheet_headers[sheet_name])
                    for h in headers:
                        if h not in existing:
                            sheet_headers[sheet_name].append(h)
                            existing.add(h)

            workbook.release_resources()
            del xls_bytes

        if not sheet_headers:
            raise ValueError("처리할 시트가 없습니다.")

        _release_memory()
        logger.info(f"DS xlsx Pass1 완료: {len(sheet_headers)}개 시트 헤더 수집")

        # ── Pass 2: xlsxwriter에 직접 행 쓰기 (sheet_rows 없이) ──
        if progress_cb:
            progress_cb(f"xlsx 생성 중... (0/{total_files})", 10)

        if not xlsx_out_path:
            xlsx_out_path = f"/tmp/ds_xlsx_{os.path.basename(zip_temp_path)}_{id(zip_temp_path)}.xlsx"
        xwb = xlsxwriter.Workbook(xlsx_out_path, {"constant_memory": True})

        header_fmt = xwb.add_format({
            "font_name": "Arial", "font_size": 10, "bold": True,
            "align": "center", "valign": "vcenter",
            "bg_color": "#BFBFBF",
            "border": 1,
        })
        data_fmt = xwb.add_format({
            "font_name": "Arial", "font_size": 10,
            "align": "center", "valign": "vcenter",
            "border": 1,
        })

        # 워크시트 생성 + 헤더 행 쓰기
        MAX_ROWS_PER_SHEET = 1_000_000  # Excel 한도 1,048,576, 안전 여유
        worksheets: Dict[str, object] = {}
        sheet_row_idx: Dict[str, int] = {}
        sheet_split_num: Dict[str, int] = {}  # 시트 분할 번호 추적
        header_col_maps: Dict[str, Dict[str, int]] = {}

        for sname, hdrs in sheet_headers.items():
            xws = xwb.add_worksheet(sname[:31])
            xws.set_row(0, 12.75)
            for ci, h in enumerate(hdrs):
                xws.set_column(ci, ci, 20)
                xws.write(0, ci, h, header_fmt)
            worksheets[sname] = xws
            sheet_row_idx[sname] = 1
            sheet_stats[sname] = 0
            header_col_maps[sname] = {h: i for i, h in enumerate(hdrs)}

        last_cb_pct = 0.0

        for file_idx, fname in enumerate(process_list):
            base_fname = os.path.basename(name_map[fname]) or name_map[fname]
            is_hundred = fname in hundred_files

            if progress_cb:
                pct = 10 + (file_idx / total_files) * 80
                if pct - last_cb_pct >= 5 or file_idx == 0 or file_idx == total_files - 1:
                    progress_cb(f"xlsx 생성 중... ({file_idx+1}/{total_files})", pct)
                    last_cb_pct = pct

            try:
                xls_bytes = zf.read(fname)
            except Exception as e:
                logger.warning(f"DS xlsx Pass2: {fname} 읽기 실패: {e}")
                continue

            try:
                workbook = xlrd.open_workbook(file_contents=xls_bytes)
            except Exception as e:
                logger.warning(f"DS xlsx Pass2: XLS 파싱 실패 ({base_fname}): {e}")
                del xls_bytes
                continue

            file_rows = 0
            for sheet_idx in range(workbook.nsheets):
                sheet = workbook.sheet_by_index(sheet_idx)
                orig_sheet_name = sheet.name.strip()
                if sheet.nrows < 2:
                    continue

                if is_hundred:
                    sheet_name = f"{orig_sheet_name}(검사전)"
                else:
                    sheet_name = orig_sheet_name

                if sheet_name not in worksheets:
                    continue

                xws = worksheets[sheet_name]
                col_map = header_col_maps[sheet_name]
                num_cols = len(sheet_headers[sheet_name])

                # XLS 컬럼 → xlsx 컬럼 매핑
                xls_col_map = []
                for col in range(sheet.ncols):
                    h = _xlrd_cell_to_str(sheet, 0, col)
                    if h and h in col_map:
                        xls_col_map.append((col, col_map[h]))
                if not xls_col_map:
                    continue

                row_count = 0
                for row_idx in range(1, sheet.nrows):
                    # 현재 행 1개만 메모리에 보유
                    row_vals = [""] * num_cols
                    for xls_col, xlsx_col in xls_col_map:
                        val = _xlrd_cell_to_str(sheet, row_idx, xls_col)
                        if val:
                            row_vals[xlsx_col] = val

                    # 시트 행 수 100만 초과 시 자동 분할
                    if sheet_row_idx[sheet_name] > MAX_ROWS_PER_SHEET:
                        split_num = sheet_split_num.get(sheet_name, 1) + 1
                        sheet_split_num[sheet_name] = split_num
                        split_ws_name = f"{sheet_name}({split_num})"[:31]
                        new_xws = xwb.add_worksheet(split_ws_name)
                        new_xws.set_row(0, 12.75)
                        hdrs = sheet_headers[sheet_name]
                        for ci, h in enumerate(hdrs):
                            new_xws.set_column(ci, ci, 20)
                            new_xws.write(0, ci, h, header_fmt)
                        worksheets[sheet_name] = new_xws
                        xws = new_xws
                        sheet_row_idx[sheet_name] = 1
                        logger.info(f"DS xlsx build: 시트 분할 → {split_ws_name}")

                    ri = sheet_row_idx[sheet_name]
                    xws.set_row(ri, 12.75)
                    for ci, val in enumerate(row_vals):
                        xws.write(ri, ci, val, data_fmt)
                    sheet_row_idx[sheet_name] += 1
                    row_count += 1

                sheet_stats[sheet_name] += row_count
                file_rows += row_count

            workbook.release_resources()
            del xls_bytes
            total_rows += file_rows
            logger.info(f"DS xlsx build: {base_fname} → {file_rows}행")

        xwb.close()

    _release_memory()
    file_size = os.path.getsize(xlsx_out_path) if os.path.exists(xlsx_out_path) else 0
    logger.info(f"DS xlsx build 완료: {total_rows}행, {len(sheet_stats)}시트, {file_size:,} bytes → {xlsx_out_path}")
    return xlsx_out_path, sheet_stats, total_rows, sheet_headers


def _init_upload_record_sync(division_id: str, division_code: str, import_date: str,
                              file_name: str, uploaded_by: str, job_id: str):
    """동기: 업로드 레코드 초기화 (같은 본부+코드 기존 모두 삭제 후 새로 생성)"""
    uploads_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_uploads"])
    records_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_records"])
    sk = f"{division_code}#{import_date}" if division_code else import_date

    # ── 같은 본부+지역코드의 기존 업로드 모두 삭제 (날짜 무관) ──
    if division_code:
        old_resp = uploads_table.query(
            KeyConditionExpression="divisionId = :did AND begins_with(importDate, :prefix)",
            ExpressionAttributeValues={":did": division_id, ":prefix": f"{division_code}#"},
            ProjectionExpression="importDate, sheetStats, storageType, divisionCode",
        )
        for old_item in old_resp.get("Items", []):
            old_sk = old_item["importDate"]
            if old_sk == sk:
                continue  # 동일 날짜 → 아래 existing 로직이 처리
            old_date = old_sk.split("#", 1)[1] if "#" in old_sk else old_sk
            old_dc = old_item.get("divisionCode", division_code)
            old_sheets = list(old_item.get("sheetStats", {}).keys())
            old_storage = old_item.get("storageType", "")
            logger.info(f"DS init: 이전 날짜 삭제 {division_id}/{old_sk}")
            try:
                s3 = get_s3_client()
                for s3k in [f"ds-exports/{division_id}/{old_dc}_{old_date}.xlsx",
                            f"ds-raw/{division_id}/{old_dc}_{old_date}.zip"]:
                    try:
                        s3.delete_object(Bucket=S3_BUCKET_NAME, Key=s3k)
                    except Exception:
                        pass
            except Exception:
                pass
            _evict_cache(division_id, old_dc, old_date)
            if old_storage not in ("s3", "s3-zip") and old_sheets:
                _delete_ds_records_targeted(records_table, uploads_table,
                                            division_id, old_date, old_dc, old_sheets)
            uploads_table.delete_item(Key={"divisionId": division_id, "importDate": old_sk})

    # ── 파트너 코드 정리 (30→70, 50→55 등 같은 본부의 다른 코드 데이터 삭제) ──
    partner_codes = DS_PARTNER_CODES.get(division_code, [])
    for partner_code in partner_codes:
        partner_resp = uploads_table.query(
            KeyConditionExpression="divisionId = :did AND begins_with(importDate, :prefix)",
            ExpressionAttributeValues={":did": division_id, ":prefix": f"{partner_code}#"},
            ProjectionExpression="importDate, sheetStats, storageType, divisionCode",
        )
        for p_item in partner_resp.get("Items", []):
            p_sk = p_item["importDate"]
            p_date = p_sk.split("#", 1)[1] if "#" in p_sk else p_sk
            p_dc = p_item.get("divisionCode", partner_code)
            p_sheets = list(p_item.get("sheetStats", {}).keys())
            p_storage = p_item.get("storageType", "")
            logger.info(f"DS init: 파트너 코드 삭제 {division_id}/{p_sk}")
            try:
                s3 = get_s3_client()
                for s3k in [f"ds-exports/{division_id}/{p_dc}_{p_date}.xlsx",
                            f"ds-raw/{division_id}/{p_dc}_{p_date}.zip"]:
                    try:
                        s3.delete_object(Bucket=S3_BUCKET_NAME, Key=s3k)
                    except Exception:
                        pass
            except Exception:
                pass
            _evict_cache(division_id, p_dc, p_date)
            if p_storage not in ("s3", "s3-zip") and p_sheets:
                _delete_ds_records_targeted(records_table, uploads_table,
                                            division_id, p_date, p_dc, p_sheets)
            uploads_table.delete_item(Key={"divisionId": division_id, "importDate": p_sk})

    # ── 동일 날짜 기존 데이터 처리 ──
    existing = uploads_table.get_item(
        Key={"divisionId": division_id, "importDate": sk}
    ).get("Item")

    if existing:
        existing_storage = existing.get("storageType", "")
        existing_sheet_names = list(existing.get("sheetStats", {}).keys())
        logger.info(f"DS init: 기존 {division_id}/{sk} 삭제 (storageType={existing_storage})")

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

        _evict_cache(division_id, division_code, import_date)

        if existing_storage not in ("s3", "s3-zip") and existing_sheet_names:
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
                      sheet_stats: dict,
                      sheet_headers: Optional[dict] = None) -> bytes:
    """동기: DynamoDB → xlsxwriter → xlsx 바이트

    서식: Arial 10pt, 가운데정렬, 얇은 테두리, 행 높이 12.75
    헤더 행: 볼드 + #BFBFBF 배경, 모든 열 너비 = 20

    헤더 결정 방식:
      1. sheet_headers[sheet_name] 있으면 그대로 사용 (업로드 시 원본 XLS 순서 보존)
      2. 없으면 전체 스캔으로 수집 (하위 호환 fallback)
    """
    if not HAS_XLSXWRITER:
        raise RuntimeError("xlsxwriter not installed on server")

    records_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_records"])
    dc_part = f"#{division_code}" if division_code else ""

    buf = io.BytesIO()
    xwb = xlsxwriter.Workbook(buf, {"in_memory": True})

    header_fmt = xwb.add_format({
        "font_name": "Arial", "font_size": 10, "bold": True,
        "align": "center", "valign": "vcenter",
        "bg_color": "#BFBFBF",
        "border": 1,
    })
    data_fmt = xwb.add_format({
        "font_name": "Arial", "font_size": 10,
        "align": "center", "valign": "vcenter",
        "border": 1,
    })

    for sheet_name in sheet_stats.keys():
        xws = xwb.add_worksheet(sheet_name[:31])
        sk_prefix = f"{sheet_name}#{import_date}{dc_part}"

        # ── 1단계: headers 결정 ──────────────────────────────────────────────
        if sheet_headers and sheet_name in sheet_headers:
            headers = list(sheet_headers[sheet_name])
        else:
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

        # ── 2단계: 헤더 행 쓰기 + 열 너비 ───────────────────────────────────
        xws.set_row(0, 12.75)
        for ci, h in enumerate(headers):
            xws.set_column(ci, ci, 20)
            xws.write(0, ci, h, header_fmt)

        # ── 3단계: 데이터 행 쓰기 (DynamoDB 페이지네이션) ────────────────────
        row_idx = 1
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
                xws.set_row(row_idx, 12.75)
                for ci, h in enumerate(headers):
                    xws.write(row_idx, ci, data.get(h, ""), data_fmt)
                row_idx += 1

            last_key = resp.get("LastEvaluatedKey")
            if not last_key:
                break

    xwb.close()
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


def _upload_xlsx_file_to_s3_sync(xlsx_path: str, division_id: str,
                                   division_code: str, import_date: str) -> str:
    """동기: xlsx 파일을 S3 ds-exports 경로에 업로드 (디스크 기반, 메모리 절약)"""
    s3 = get_s3_client()
    key = f"ds-exports/{division_id}/{division_code}_{import_date}.xlsx"
    s3.upload_file(
        xlsx_path, S3_BUCKET_NAME, key,
        ExtraArgs={"ContentType": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
    )
    return key


async def _process_ds_job(job_id: str, job_item: dict):
    """DS 잡 메인 처리 — ZIP → xlsx 빌드 → S3 저장 (DynamoDB 행 쓰기 0회)
    복수 ZIP (s3Keys 배열) 인 경우 먼저 병합 후 동일 플로우 실행.
    """
    s3_keys = job_item.get("s3Keys", [])    # 복수 ZIP (S3 경유)
    temp_ids = job_item.get("tempIds", [])  # 복수 ZIP (로컬 직접 전송)
    s3_key = job_item.get("s3Key", "")      # 단일 ZIP
    file_name = job_item.get("fileName", "")
    uploaded_by = job_item.get("uploadedBy", "unknown")
    is_multi = (bool(s3_keys) and len(s3_keys) > 1) or (bool(temp_ids) and len(temp_ids) > 1)
    zip_temp_path = f"/tmp/ds_merged_{job_id}.zip" if is_multi else f"/tmp/ds_{job_id}.zip"

    # except 블록에서 접근 가능하도록 try 바깥에서 초기화
    division_id: Optional[str] = None
    division_code: Optional[str] = None
    import_date: Optional[str] = None
    uploads_record_created = False  # _init 이후 True → except에서 정리 대상

    async def _check_cancelled():
        """취소 요청 확인 — cancelled 상태면 CancelledError 발생"""
        try:
            jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])
            resp = await asyncio.to_thread(
                lambda: jobs_table.get_item(
                    Key={"jobId": job_id},
                    ProjectionExpression="#s",
                    ExpressionAttributeNames={"#s": "status"},
                )
            )
            if resp.get("Item", {}).get("status") == "cancelled":
                raise asyncio.CancelledError(f"DS job {job_id} 취소됨")
        except asyncio.CancelledError:
            raise
        except Exception:
            pass  # 조회 실패는 무시

    try:
        # 1. ZIP 준비 (복수: 병합 / 단수: 다운로드)
        if is_multi:
            file_names = job_item.get("fileNames", [])
            merge_keys = temp_ids if temp_ids else s3_keys
            if len(file_names) != len(merge_keys):
                file_names = [f"file_{i}.zip" for i in range(len(merge_keys))]
            zip_temp_path = await asyncio.to_thread(
                _merge_zips_sync, s3_keys, file_names, job_id,
                lambda s, p: _update_job_progress_sync(job_id, s, p),
                temp_ids=temp_ids if temp_ids else None,
            )
            mode = "로컬" if temp_ids else "S3"
            logger.info(f"DS job {job_id}: {len(merge_keys)}개 ZIP 병합 완료 [{mode}] "
                        f"({os.path.getsize(zip_temp_path):,} bytes)")
        else:
            await _update_job_progress(job_id, "S3에서 ZIP 다운로드 중...", 3)
            actual_key = s3_keys[0] if s3_keys else s3_key

            def _dl():
                get_s3_client().download_file(S3_BUCKET_NAME, actual_key, zip_temp_path)
            await asyncio.to_thread(_dl)
            logger.info(f"DS job {job_id}: ZIP downloaded ({os.path.getsize(zip_temp_path):,} bytes)")

        await _check_cancelled()

        # 2. ZIP 내 XLS 파일명에서 divisionCode/importDate 파싱
        await _update_job_progress(job_id, "ZIP 메타 파싱 중...", 30 if is_multi else 5)

        def _parse_meta():
            with zipfile.ZipFile(zip_temp_path, "r") as zf:
                for name in zf.namelist():
                    fixed = _fix_zip_filename(name)
                    base = os.path.basename(fixed)
                    if not base.lower().endswith(".xls"):
                        continue
                    if base.startswith("~"):
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

        # 병합 코드 정규화: 70→30(서부), 55→50(충청)
        if division_code in DS_MERGED_CODES:
            original_code = division_code
            division_code = DS_MERGED_CODES[division_code]
            logger.info(f"DS job {job_id}: 코드 {original_code} → {division_code} 정규화")

        division_id = DS_REGION_CODE_MAP[division_code]["divisionId"]
        division_name = DS_REGION_CODE_MAP[division_code]["divisionName"]
        logger.info(f"DS job {job_id}: {division_name}({division_code}) / {import_date}")

        # 3. 메모리 체크
        if HAS_PSUTIL:
            mem = psutil.virtual_memory()
            if mem.percent > 80:
                logger.warning(f"DS job {job_id}: 메모리 {mem.percent}% > 80%, 30초 대기")
                await asyncio.sleep(30)

        await _check_cancelled()

        # 4. 메타데이터 파싱 (기존 데이터 삭제 전에 실행 → 파싱 실패 시 데이터 보존)
        await _update_job_progress(job_id, "메타데이터 파싱 중...", 35 if is_multi else 10)

        def _progress_cb(stage: str, pct: float):
            _update_job_progress_sync(job_id, stage, pct)

        sheet_stats, total_rows, sheet_headers, file_manifest = await asyncio.to_thread(
            _parse_zip_metadata_sync, zip_temp_path, _progress_cb
        )
        logger.info(f"DS job {job_id}: 메타 파싱 완료 — {total_rows}행, {len(sheet_stats)}시트")

        if total_rows == 0:
            raise ValueError("XLS 파일에서 데이터 행을 찾을 수 없습니다.")

        await _check_cancelled()

        # 5. 기존 데이터 삭제 (병합+파싱 성공 후에만 → 데이터 안전)
        await _update_job_progress(job_id, "기존 데이터 정리 중...", 70 if is_multi else 75)
        await asyncio.to_thread(
            _init_upload_record_sync,
            division_id, division_code, import_date, file_name, uploaded_by, job_id
        )
        uploads_record_created = True

        await _check_cancelled()

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

        # 9. xlsx 캐시 빌드 큐에 등록 (워커 유휴 시 순차 실행)
        _xlsx_build_queue.append((division_id, division_code, import_date))
        logger.info(f"DS job {job_id}: xlsx 빌드 큐 등록 ({len(_xlsx_build_queue)}건 대기)")

        # 10. 복수 ZIP인 경우 S3 임시 파일 정리 (non-fatal)
        if is_multi and s3_keys:
            for temp_key in s3_keys:
                try:
                    get_s3_client().delete_object(Bucket=S3_BUCKET_NAME, Key=temp_key)
                except Exception:
                    pass

    except asyncio.CancelledError:
        logger.info(f"DS job {job_id}: 사용자 취소됨")
        # cancelled 상태는 이미 엔드포인트에서 설정됨 → 추가 처리 불필요

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
        _release_memory()


# xlsx 캐시 빌드 큐 — 잡 완료 시 등록, 워커 유휴 시 순차 실행
_xlsx_build_queue: list = []


async def _build_xlsx_cache_background(division_id: str, division_code: str, import_date: str):
    """S3 ZIP → xlsx 디스크 빌드 → S3 캐싱 (워커 유휴 시 실행)
    실패해도 export 시 on-demand 빌드 가능하므로 non-fatal.
    """
    zip_s3_key = f"ds-raw/{division_id}/{division_code}_{import_date}.zip"
    zip_temp = f"/tmp/ds_bgxlsx_{division_id}_{division_code}_{import_date}.zip"
    xlsx_temp = f"/tmp/ds_bgxlsx_{division_id}_{division_code}_{import_date}.xlsx"
    try:
        s3 = get_s3_client()
        await asyncio.to_thread(s3.download_file, S3_BUCKET_NAME, zip_s3_key, zip_temp)
        await asyncio.to_thread(_process_zip_to_xlsx_sync, zip_temp, None, xlsx_temp)
        await asyncio.to_thread(
            _upload_xlsx_file_to_s3_sync, xlsx_temp, division_id, division_code, import_date
        )
        logger.info(f"DS bg xlsx cache: {division_id}/{division_code}_{import_date} 완료")
    except Exception as e:
        logger.warning(f"DS bg xlsx cache 실패 (non-fatal, export 시 on-demand 빌드): {e}")
    finally:
        for tmp in [zip_temp, xlsx_temp]:
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
            except Exception:
                pass
        _release_memory()


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
                # 잡 큐가 비었을 때 xlsx 캐시 빌드 큐 처리
                if _xlsx_build_queue:
                    build_args = _xlsx_build_queue.pop(0)
                    logger.info(f"DS xlsx build queue: {build_args[0]}/{build_args[1]}_{build_args[2]} "
                                f"빌드 시작 (남은 {len(_xlsx_build_queue)}건)")
                    await _build_xlsx_cache_background(*build_args)
                else:
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
    request: Request,
    divisionId: str = Query(...),
    divisionCode: str = Query(...),
    importDate: str = Query(...),
):
    """S3 presigned URL 생성 - 원본 ZIP 업로드용"""
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/ds/xlsx-upload-presign")
async def ds_xlsx_upload_presign(
    request: Request,
    divisionId: str = Query(...),
    divisionCode: str = Query(...),
    importDate: str = Query(...),
):
    """S3 presigned URL 생성 - 병합된 xlsx 저장용 (업로드 시 생성)"""
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/ds/export-presign")
async def ds_export_presign(
    request: Request,
    divisionId: str = Query(...),
    importDate: str = Query(...),
    divisionCode: str = Query(""),
):
    """S3 Export용 presigned URL - 병합 xlsx 우선, 없으면 원본 ZIP"""
    await _verify_auth(request)
    try:
        s3 = get_s3_client()

        # 1순위: 미리 생성된 병합 xlsx → 즉시 다운로드
        xlsx_key = f"ds-exports/{divisionId}/{divisionCode}_{importDate}.xlsx"
        _validate_s3_key(xlsx_key, ALLOWED_S3_READ_PREFIXES)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/ds/proxy-raw-zip")
async def ds_proxy_raw_zip(
    request: Request,
    divisionId: str = Query(...),
    importDate: str = Query(...),
    divisionCode: str = Query(""),
):
    """S3 원본 ZIP → EC2 프록시 스트리밍 (브라우저 CORS 우회)"""
    await _verify_auth(request)
    s3_key = f"ds-raw/{divisionId}/{divisionCode}_{importDate}.zip"
    s3 = get_s3_client()
    try:
        head = s3.head_object(Bucket=S3_BUCKET_NAME, Key=s3_key)
    except ClientError:
        raise HTTPException(status_code=404, detail="ZIP 파일 없음")

    content_length = head["ContentLength"]

    async def _stream():
        obj = await asyncio.to_thread(
            s3.get_object, Bucket=S3_BUCKET_NAME, Key=s3_key
        )
        body = obj["Body"]
        try:
            while True:
                chunk = await asyncio.to_thread(body.read, 65536)
                if not chunk:
                    break
                yield chunk
        finally:
            body.close()

    return StreamingResponse(
        _stream(),
        media_type="application/zip",
        headers={"Content-Length": str(content_length)},
    )


@app.post("/ds/upload-init")
async def ds_upload_init(req: DsUploadInit, request: Request = None):
    """DS 업로드 세션 시작 - 기존 데이터 삭제 후 새 레코드 생성"""
    await _verify_auth(request)
    try:
        dynamodb = get_dynamodb_resource()
        uploads_table = dynamodb.Table(DYNAMODB_TABLES["ds_uploads"])
        records_table = dynamodb.Table(DYNAMODB_TABLES["ds_records"])

        sk = f"{req.divisionCode}#{req.importDate}" if req.divisionCode else req.importDate

        # ── 같은 본부+지역코드의 기존 업로드 모두 삭제 (날짜 무관) ──
        if req.divisionCode:
            old_resp = uploads_table.query(
                KeyConditionExpression="divisionId = :did AND begins_with(importDate, :prefix)",
                ExpressionAttributeValues={":did": req.divisionId, ":prefix": f"{req.divisionCode}#"},
                ProjectionExpression="importDate, sheetStats, storageType, divisionCode",
            )
            for old_item in old_resp.get("Items", []):
                old_sk = old_item["importDate"]
                if old_sk == sk:
                    continue  # 동일 날짜 → 아래 existing 로직이 처리
                old_date = old_sk.split("#", 1)[1] if "#" in old_sk else old_sk
                old_dc = old_item.get("divisionCode", req.divisionCode)
                old_sheets = list(old_item.get("sheetStats", {}).keys())
                old_storage = old_item.get("storageType", "")
                logger.info(f"DS upload-init: 이전 날짜 삭제 {req.divisionId}/{old_sk}")
                # S3 파일 삭제
                try:
                    s3 = get_s3_client()
                    for s3k in [f"ds-exports/{req.divisionId}/{old_dc}_{old_date}.xlsx",
                                f"ds-raw/{req.divisionId}/{old_dc}_{old_date}.zip"]:
                        try:
                            s3.delete_object(Bucket=S3_BUCKET_NAME, Key=s3k)
                        except Exception:
                            pass
                except Exception:
                    pass
                _evict_cache(req.divisionId, old_dc, old_date)
                # DynamoDB records 삭제 (S3 계열이면 스킵)
                if old_storage not in ("s3", "s3-zip") and old_sheets:
                    await asyncio.to_thread(
                        _delete_ds_records_targeted, records_table, uploads_table,
                        req.divisionId, old_date, old_dc, old_sheets
                    )
                uploads_table.delete_item(Key={"divisionId": req.divisionId, "importDate": old_sk})

        # ── 동일 날짜 기존 데이터 처리 ──
        existing = uploads_table.get_item(Key={"divisionId": req.divisionId, "importDate": sk}).get("Item")
        if existing:
            # 이미 completed 상태인 경우에도 덮어쓰기 허용 (이전 날짜 삭제 후 새 업로드이므로)
            existing_sheet_names = list(existing.get("sheetStats", {}).keys())
            logger.info(f"DS upload-init: 기존 데이터 삭제 시작 {req.divisionId}/{sk}, sheets={existing_sheet_names}")

            try:
                s3 = get_s3_client()
                s3.delete_object(
                    Bucket=S3_BUCKET_NAME,
                    Key=f"ds-exports/{req.divisionId}/{req.divisionCode}_{req.importDate}.xlsx"
                )
            except Exception:
                pass

            existing_storage = existing.get("storageType", "")
            if existing_storage not in ("s3", "s3-zip") and existing_sheet_names:
                deleted = await asyncio.to_thread(
                    _delete_ds_records_targeted, records_table, uploads_table,
                    req.divisionId, req.importDate, req.divisionCode, existing_sheet_names
                )
                logger.info(f"DS upload-init: 기존 {deleted}건 삭제 완료")
            uploads_table.delete_item(Key={"divisionId": req.divisionId, "importDate": sk})

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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


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
async def ds_upload_chunk(req: DsUploadChunk, request: Request = None):
    """DS 청크 데이터 수신 → DynamoDB BatchWriteItem (스레드 풀에서 실행)"""
    await _verify_auth(request)
    try:
        written = await asyncio.to_thread(_write_chunk_sync, req)
        logger.info(f"DS chunk: {req.divisionId}/{req.sheetName} chunk {req.chunkIndex}/{req.totalChunks} - {written} rows")
        return {"success": True, "writtenCount": written}
    except ClientError as e:
        logger.error(f"DS upload-chunk error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.post("/ds/upload-finalize")
async def ds_upload_finalize(req: DsUploadFinalize, request: Request = None):
    """DS 업로드 완료 - status 업데이트"""
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/ds/stats")
async def ds_stats(
    request: Request,
    divisionId: Optional[str] = Query(None),
    importDate: Optional[str] = Query(None),
    divisionCode: Optional[str] = Query(None),
):
    """DS 업로드 통계 조회 (대시보드용)"""
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/ds/export")
async def ds_export(
    request: Request,
    divisionId: str = Query(...),
    importDate: str = Query(...),
    divisionCode: Optional[str] = Query(None),
):
    """DS 데이터 Excel Export용 - 스트리밍 JSON 응답 (메모리 절약)"""
    await _verify_auth(request)

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
            yield json.dumps({"success": False, "message": "서버 내부 오류"})
        except Exception as e:
            logger.error(f"DS export unexpected error: {e}")
            yield json.dumps({"success": False, "message": "서버 내부 오류"})

    return StreamingResponse(generate(), media_type="application/json")


@app.get("/ds/data")
async def ds_data(
    request: Request,
    background_tasks: BackgroundTasks,
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
    await _verify_auth(request)
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
                        ProjectionExpression="storageType, fileManifest, sheetHeaders",
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
                ProjectionExpression="storageType, fileManifest, sheetHeaders",
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
            # 첫 페이지: 서버 저장 헤더 반환 (컬럼 순서 보장 + 빈 컬럼 표시)
            if xls_offset == 0 and upload_rec:
                sh = upload_rec.get("sheetHeaders")
                if sh and sheetName in sh:
                    result["headers"] = sh[sheetName]
            background_tasks.add_task(_release_memory)
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
            background_tasks.add_task(_release_memory)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.delete("/ds/data")
async def ds_delete_data(
    request: Request,
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
    # 권한 체크: admin, manager만 삭제 가능
    await _require_role(request, {"admin", "manager"})

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

        # 6. 감사 로그
        try:
            empno = await _verify_auth(request)
        except HTTPException:
            empno = "unknown"
        await asyncio.to_thread(
            _record_audit_log_sync, "DELETE", "DSData",
            f"{divisionId}/{importDate}", empno,
            {"newData": json.dumps({"divisionCode": dc, "storageType": storage_type})},
        )

        return {"success": True, "deletedCount": 0}
    except ClientError as e:
        logger.error(f"DS delete error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


# ============================================================
# DS 잡 큐 엔드포인트
# ============================================================

@app.get("/ds/presign-raw")
async def ds_presign_raw(
    request: Request,
    fileName: str = Query(...),
):
    """DS ZIP S3 직접 업로드용 presigned PUT URL 발급
    브라우저가 이 URL로 직접 S3에 PUT → EC2 메모리 0 사용
    (S3 버킷 CORS 설정 필요 — 없으면 /ds/upload-raw 사용)
    """
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.post("/ds/upload-raw")
async def ds_upload_raw(request: Request, file: UploadFile = File(...)):
    # 권한 체크: admin, manager만 업로드 가능
    await _require_role(request, {"admin", "manager"})
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.post("/ds/upload-temp")
async def ds_upload_temp(request: Request, file: UploadFile = File(...)):
    """DS ZIP → EC2 로컬 디스크 스트리밍 저장 (S3 경유 없음, 병합용)
    메모리: ~8MB (청크 버퍼만), 디스크: 파일 크기만큼
    """
    await _require_role(request, {"admin", "manager"})
    temp_id = str(uuid.uuid4())
    temp_path = f"/tmp/ds_temp_{temp_id}.zip"
    total_size = 0
    CHUNK_SIZE = 8 * 1024 * 1024  # 8MB

    try:
        with open(temp_path, "wb") as f:
            while True:
                chunk = await file.read(CHUNK_SIZE)
                if not chunk:
                    break
                f.write(chunk)
                total_size += len(chunk)

        if total_size == 0:
            os.remove(temp_path)
            raise ValueError("업로드된 데이터가 없습니다")

        logger.info(f"DS upload-temp: {temp_id} ({total_size // 1024}KB) → {temp_path}")
        return {"success": True, "tempId": temp_id}

    except Exception as e:
        if os.path.exists(temp_path):
            os.remove(temp_path)
        logger.error(f"DS upload-temp error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.post("/ds/enqueue")
async def ds_enqueue(request: Request, req: DsEnqueueRequest):
    """DS 처리 잡을 큐에 추가 — 즉시 jobId 반환, 실제 처리는 백그라운드 워커"""
    # 권한 체크: admin, manager만 업로드 가능
    await _require_role(request, {"admin", "manager"})
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

        # 감사 로그
        try:
            empno = await _verify_auth(request)
        except HTTPException:
            empno = req.uploadedBy
        await asyncio.to_thread(
            _record_audit_log_sync, "CREATE", "DSData", req.s3Key, empno,
            {"newData": json.dumps({"fileName": req.fileName, "jobId": job_id})},
        )

        return {"success": True, "jobId": job_id, "queuePosition": queue_position}
    except ClientError as e:
        logger.error(f"DS enqueue error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.post("/ds/enqueue-multi")
async def ds_enqueue_multi(request: Request, req: DsEnqueueMultiRequest):
    """복수 ZIP 병합 업로드 잡 생성 — 같은 지역코드 ZIP들을 하나로 병합 처리"""
    await _require_role(request, {"admin", "manager"})
    if not HAS_XLRD:
        raise HTTPException(status_code=503, detail="서버에 xlrd가 설치되지 않았습니다.")

    # tempIds (로컬 직접 전송) 또는 s3Keys (S3 경유) 중 하나 필수
    use_temp = bool(req.tempIds)
    keys = req.tempIds if use_temp else req.s3Keys
    if len(keys) != len(req.fileNames):
        raise HTTPException(status_code=400, detail="파일 키와 fileNames 길이가 일치하지 않습니다.")
    if len(keys) < 2:
        raise HTTPException(status_code=400, detail="2개 이상의 파일이 필요합니다.")

    # tempIds 유효성 검증 (존재하는 파일인지)
    if use_temp:
        for tid in req.tempIds:
            if not os.path.exists(f"/tmp/ds_temp_{tid}.zip"):
                raise HTTPException(status_code=400, detail=f"임시 파일 없음: {tid}")

    try:
        jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])
        job_id = str(uuid.uuid4())
        now = datetime.now(timezone.utc).isoformat()

        job_item = {
            "jobId": job_id,
            "status": "queued",
            "stage": f"{len(keys)}개 ZIP 병합 대기 중...",
            "percent": Decimal("0"),
            "processedRows": 0,
            "totalRows": 0,
            "fileNames": req.fileNames,
            "fileName": req.fileNames[0],
            "uploadedBy": req.uploadedBy,
            "queuedAt": now,
        }
        if use_temp:
            job_item["tempIds"] = req.tempIds
        else:
            job_item["s3Keys"] = req.s3Keys
            job_item["s3Key"] = req.s3Keys[0]

        jobs_table.put_item(Item=job_item)

        resp = jobs_table.scan(
            FilterExpression="#s = :s",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": "queued"},
            Select="COUNT",
        )
        queue_position = resp.get("Count", 0)

        mode = "로컬" if use_temp else "S3"
        logger.info(f"DS multi-job enqueued: {job_id} ({len(keys)}개 ZIP [{mode}], 큐 {queue_position}번째)")

        try:
            empno = await _verify_auth(request)
        except HTTPException:
            empno = req.uploadedBy
        await asyncio.to_thread(
            _record_audit_log_sync, "CREATE", "DSData", req.fileNames[0], empno,
            {"newData": json.dumps({
                "fileCount": len(keys),
                "fileNames": req.fileNames[:5],
                "jobId": job_id,
                "mode": mode,
            })},
        )

        return {"success": True, "jobId": job_id, "queuePosition": queue_position}
    except ClientError as e:
        logger.error(f"DS enqueue-multi error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/ds/export-xlsx")
async def ds_export_xlsx(
    request: Request,
    divisionId: str = Query(...),
    importDate: str = Query(...),
    divisionCode: str = Query(""),
):
    """DS xlsx 다운로드
    - storageType="s3": S3에서 직접 다운로드 (빌드 불필요, 즉시)
    - old: DynamoDB → xlsx 서버사이드 빌드 후 다운로드 + S3 캐싱
    """
    await _verify_auth(request)
    if not HAS_XLSXWRITER:
        raise HTTPException(status_code=503, detail="서버에 xlsxwriter가 설치되지 않았습니다.")

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

    # ── s3-zip: ZIP에서 on-demand xlsx 빌드 → 디스크 스트리밍 + S3 캐싱 ──
    if storage_type == "s3-zip":
        zip_s3_key = f"ds-raw/{divisionId}/{divisionCode}_{importDate}.zip"
        zip_temp = f"/tmp/ds_export_{divisionId}_{divisionCode}_{importDate}.zip"
        xlsx_temp = f"/tmp/ds_export_{divisionId}_{divisionCode}_{importDate}.xlsx"
        try:
            s3_client = get_s3_client()
            await asyncio.to_thread(s3_client.download_file, S3_BUCKET_NAME, zip_s3_key, zip_temp)

            xlsx_path, _, _, _ = await asyncio.to_thread(
                _process_zip_to_xlsx_sync, zip_temp, None, xlsx_temp
            )

            # ZIP 임시파일 즉시 삭제
            try:
                os.remove(zip_temp)
            except Exception:
                pass

            content_length = os.path.getsize(xlsx_path)

            # S3에 캐싱 (백그라운드 — 파일에서 직접 업로드)
            async def _cache_xlsx():
                try:
                    await asyncio.to_thread(
                        _upload_xlsx_file_to_s3_sync, xlsx_path, divisionId, divisionCode, importDate
                    )
                    logger.info(f"DS export: xlsx S3 캐싱 완료 {xlsx_s3_key}")
                except Exception as ce:
                    logger.warning(f"DS export: xlsx S3 캐싱 실패 (non-fatal): {ce}")

            asyncio.create_task(_cache_xlsx())

            def _stream_xlsx():
                try:
                    with open(xlsx_path, "rb") as f:
                        while True:
                            chunk = f.read(1024 * 1024)  # 1MB chunks
                            if not chunk:
                                break
                            yield chunk
                finally:
                    # S3 캐싱이 끝날 시간을 고려해 삭제는 별도 태스크로
                    pass

            return StreamingResponse(
                _stream_xlsx(),
                media_type=xlsx_media,
                headers={
                    "Content-Disposition": f"attachment; filename*=UTF-8''{filename.replace(' ', '%20')}",
                    "Content-Length": str(content_length),
                },
            )
        except Exception as e:
            logger.error(f"DS export s3-zip build failed: {e}")
            raise HTTPException(status_code=500, detail="서버 내부 오류")
        finally:
            try:
                if os.path.exists(zip_temp):
                    os.remove(zip_temp)
            except Exception:
                pass

    # ── DynamoDB fallback: 기존 빌드 경로 ──
    xlsx_bytes = await asyncio.to_thread(
        _build_xlsx_sync, divisionId, divisionCode, importDate,
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
async def ds_job_status(job_id: str, request: Request = None):
    """DS 잡 상태 조회 — 브라우저가 3초 간격으로 폴링"""
    await _verify_auth(request)
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
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.delete("/ds/job/{job_id}")
async def ds_job_cancel(job_id: str, request: Request = None):
    """DS 잡 취소 — queued/processing 상태 모두 가능"""
    await _verify_auth(request)
    try:
        jobs_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_jobs"])
        item = jobs_table.get_item(Key={"jobId": job_id}).get("Item")
        if not item:
            raise HTTPException(status_code=404, detail="Job not found")

        status = item.get("status", "")
        if status not in ("queued", "processing"):
            raise HTTPException(status_code=400, detail="완료/실패된 잡은 취소할 수 없습니다.")

        if status == "queued":
            # 대기 중: 바로 삭제
            jobs_table.delete_item(Key={"jobId": job_id})
        else:
            # 처리 중: cancelled 상태로 변경 → 워커가 감지 후 중단
            jobs_table.update_item(
                Key={"jobId": job_id},
                UpdateExpression="SET #s = :s, stage = :st",
                ExpressionAttributeNames={"#s": "status"},
                ExpressionAttributeValues={":s": "cancelled", ":st": "취소 요청됨"},
            )

        # S3 임시 파일 삭제
        try:
            s3_key = item.get("s3Key", "")
            if s3_key and "/temp/" in s3_key:
                get_s3_client().delete_object(Bucket=S3_BUCKET_NAME, Key=s3_key)
            # 복수 ZIP 임시 파일도 삭제
            for key in item.get("s3Keys", []):
                if key and "/temp/" in key:
                    get_s3_client().delete_object(Bucket=S3_BUCKET_NAME, Key=key)
        except Exception:
            pass

        return {"success": True, "wasProcessing": status == "processing"}
    except HTTPException:
        raise
    except ClientError as e:
        logger.error(f"DS job cancel error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


# ============================================================
# 호출명칭 매칭 (Callname Matching) — 메모리 최적화 버전
# EC2 1.9GB RAM 환경: 피크 ~80-100MB 이내 설계
# 핵심: DataFrame/원본파일 메모리 보관 안 함 → S3 임시저장
#        XML split 대신 임시파일 스트리밍 행 단위 처리
#        callname_df lazy load → 매칭 후 해제 가능
# ============================================================

import tempfile as _tempfile

# ── 글로벌 캐시 & 세션 ──
_callname_db_row_count = 0     # 행 수 캐시 (상태 조회용)
_callname_sessions: Dict[str, dict] = {}  # upload_id/process_id → 세션 (경량 메타만)
_callname_upload_jobs: Dict[str, dict] = {}  # jobId → {status, stage, percent, ...}


def _col_to_idx(col_letter: str) -> int:
    """Excel 컬럼 레터 → 0-based 인덱스. 'A'→0, 'B'→1, 'Z'→25, 'AA'→26."""
    r = 0
    for c in col_letter:
        r = r * 26 + (ord(c) - 64)
    return r - 1


def _resolve_xlsx_sheet_path(zf, sheet_name: str) -> Optional[str]:
    """xlsx ZIP 내에서 시트이름 → 워크시트 XML 파일경로 매핑.
    workbook.xml + rels 파싱. 못 찾으면 None."""
    import xml.etree.ElementTree as ET
    try:
        wb_xml = zf.read("xl/workbook.xml")
        wb_root = ET.fromstring(wb_xml)
        r_id = None
        for el in wb_root.iter():
            tag = el.tag.rsplit("}", 1)[-1]
            if tag == "sheet" and el.get("name") == sheet_name:
                # {http://schemas.openxmlformats.org/officeDocument/2006/relationships}id
                for attr_key in el.attrib:
                    if attr_key.endswith("}id") or attr_key == "r:id":
                        r_id = el.attrib[attr_key]
                        break
                break
        del wb_xml, wb_root
        if not r_id:
            return None
        rels_xml = zf.read("xl/_rels/workbook.xml.rels")
        rels_root = ET.fromstring(rels_xml)
        for rel in rels_root:
            if rel.get("Id") == r_id:
                target = rel.get("Target", "")
                del rels_xml, rels_root
                if target.startswith("/"):
                    return target[1:]
                return f"xl/{target}"
        del rels_xml, rels_root
    except Exception:
        pass
    return None


def _list_xlsx_sheet_names(xlsx_path: str) -> list:
    """xlsx 파일의 시트이름 목록 반환 (경량: workbook.xml만 파싱)."""
    import xml.etree.ElementTree as ET
    names = []
    try:
        with zipfile.ZipFile(xlsx_path, "r") as zf:
            wb_xml = zf.read("xl/workbook.xml")
            root = ET.fromstring(wb_xml)
            for el in root.iter():
                tag = el.tag.rsplit("}", 1)[-1]
                if tag == "sheet":
                    n = el.get("name")
                    if n:
                        names.append(n)
            del wb_xml, root
    except Exception:
        pass
    return names


def _iter_xlsx_rows_light(xlsx_path: str, sheet_name: str = None, *,
                          ss_cache_path: str = None, ss_offsets_bytes: bytes = None):
    """xlsx → (0-based_row_num, [str, ...]) 스트리밍 제너레이터.
    openpyxl.load_workbook 대신 ZIP + XML iterparse 사용.
    sharedStrings를 디스크 임시파일 + mmap으로 처리 → RAM ~95% 절감.
    메모리: offsets 배열(~4MB/50만건) + 현재 행 버퍼만.
    sheet_name: 특정 시트 (None이면 첫 번째 시트).
    ss_cache_path/ss_offsets_bytes: 미리 빌드된 SS 캐시 → 재파싱 스킵."""
    import xml.etree.ElementTree as ET
    import struct
    import mmap as _mmap_mod
    from array import array

    _owns_ss = ss_cache_path is None  # True면 이 함수에서 SS 생성·정리
    ss_tmp_path = ss_cache_path
    ss_mmap_obj = None
    ss_fh = None

    try:
        with zipfile.ZipFile(xlsx_path, "r") as zf:
            # ── sharedStrings ──
            if ss_cache_path and ss_offsets_bytes:
                # 캐시 재사용 (sharedStrings 파싱 스킵)
                ss_offsets = array("Q")
                ss_offsets.frombytes(ss_offsets_bytes)
            else:
                # 새로 빌드 (기존 로직)
                ss_offsets = array("Q")
                ss_names = [n for n in zf.namelist() if n.endswith("sharedStrings.xml")]
                if ss_names:
                    ss_tmp = _tempfile.NamedTemporaryFile(delete=False, suffix=".ss")
                    ss_tmp_path = ss_tmp.name
                    with zf.open(ss_names[0]) as ssf:
                        for _, elem in ET.iterparse(ssf, events=("end",)):
                            tag = elem.tag.rsplit("}", 1)[-1]
                            if tag == "si":
                                parts = []
                                for ch in elem.iter():
                                    if ch.tag.rsplit("}", 1)[-1] == "t" and ch.text:
                                        parts.append(ch.text)
                                text = "".join(parts)
                                encoded = text.encode("utf-8")
                                ss_offsets.append(ss_tmp.tell())
                                ss_tmp.write(struct.pack("<I", len(encoded)))
                                ss_tmp.write(encoded)
                                elem.clear()
                    ss_tmp.close()

            # mmap으로 랜덤 액세스 (OS가 페이지 관리 → Python 힙 사용 안 함)
            if ss_tmp_path:
                file_size = os.path.getsize(ss_tmp_path)
                if file_size > 0:
                    ss_fh = open(ss_tmp_path, "rb")
                    ss_mmap_obj = _mmap_mod.mmap(ss_fh.fileno(), 0, access=_mmap_mod.ACCESS_READ)

            def _get_ss(idx):
                """디스크에서 sharedString 조회 (mmap → OS 페이지캐시 활용)."""
                if ss_mmap_obj is not None and 0 <= idx < len(ss_offsets):
                    offset = ss_offsets[idx]
                    length = struct.unpack_from("<I", ss_mmap_obj, offset)[0]
                    start = offset + 4
                    return ss_mmap_obj[start:start + length].decode("utf-8")
                return ""

            # ── 시트 파일 결정 ──
            if sheet_name:
                sp = _resolve_xlsx_sheet_path(zf, sheet_name)
                if not sp:
                    return
            else:
                sheets = sorted([n for n in zf.namelist() if "worksheets/sheet" in n])
                sp = sheets[0] if sheets else "xl/worksheets/sheet1.xml"

            # ── sheet XML iterparse (한 행씩 yield) ──
            _cr = re.compile(r"([A-Z]+)")
            cells = []

            with zf.open(sp) as sf:
                for _, elem in ET.iterparse(sf, events=("end",)):
                    tag = elem.tag.rsplit("}", 1)[-1]

                    if tag == "c":
                        ct = elem.get("t", "")
                        val = ""
                        if ct == "s":
                            for ch in elem:
                                if ch.tag.rsplit("}", 1)[-1] == "v" and ch.text:
                                    si = int(ch.text)
                                    val = _get_ss(si)
                                    break
                        elif ct == "inlineStr":
                            for ch in elem.iter():
                                if ch.tag.rsplit("}", 1)[-1] == "t" and ch.text:
                                    val = ch.text
                                    break
                        else:
                            for ch in elem:
                                if ch.tag.rsplit("}", 1)[-1] == "v":
                                    val = ch.text or ""
                                    break
                        r_attr = elem.get("r", "")
                        m = _cr.match(r_attr)
                        if m:
                            ci = _col_to_idx(m.group(1))
                            while len(cells) <= ci:
                                cells.append("")
                            cells[ci] = val
                        elem.clear()

                    elif tag == "row":
                        rn = int(elem.get("r", "0")) - 1  # 0-based
                        yield (rn, cells)
                        cells = []
                        elem.clear()

    finally:
        # mmap 핸들 정리
        if ss_mmap_obj is not None:
            ss_mmap_obj.close()
        if ss_fh is not None:
            ss_fh.close()
        # 이 함수에서 생성한 SS만 삭제 (캐시 제공 시 삭제 안 함)
        if _owns_ss and ss_tmp_path:
            try:
                os.remove(ss_tmp_path)
            except Exception:
                pass


def _parse_xlsx_header_fast(xlsx_path: str) -> dict:
    """xlsx 헤더(첫 행) + 행 수만 초고속 추출 (sharedStrings 전체 파싱 불필요).
    1) sheet XML dimension 태그에서 총 행 수
    2) sheet XML 첫 행에서 shared string 인덱스 수집
    3) sharedStrings.xml에서 필요 인덱스까지만 파싱 (조기 종료)
    → 140MB 파일도 수 초 내 완료."""
    import xml.etree.ElementTree as ET
    _cr_col = re.compile(r"([A-Z]+)")

    with zipfile.ZipFile(xlsx_path, "r") as zf:
        sheets = sorted([n for n in zf.namelist() if "worksheets/sheet" in n])
        sp = sheets[0] if sheets else "xl/worksheets/sheet1.xml"

        # ── Pass 1: sheet XML — dimension + 첫 행 셀 정보 ──
        total_rows = 0
        header_cells = []  # [(col_idx, cell_type, raw_value)]

        with zf.open(sp) as sf:
            for _, elem in ET.iterparse(sf, events=("end",)):
                tag = elem.tag.rsplit("}", 1)[-1]

                if tag == "dimension":
                    ref = elem.get("ref", "")
                    if ":" in ref:
                        m = re.search(r"(\d+)$", ref.split(":")[1])
                        if m:
                            total_rows = int(m.group(1)) - 1
                    elem.clear()
                    continue

                if tag == "c":
                    # row 1의 셀만 수집 (row 속성은 부모 <row>에 있으므로 r 속성에서 판별)
                    r_attr = elem.get("r", "")
                    # row 1의 셀: A1, B1, ..., Z1, AA1, ...
                    if r_attr and r_attr[-1] == "1" and re.match(r"^[A-Z]+1$", r_attr):
                        ct = elem.get("t", "")
                        m = _cr_col.match(r_attr)
                        ci = _col_to_idx(m.group(1)) if m else -1

                        if ct == "s":
                            for ch in elem:
                                if ch.tag.rsplit("}", 1)[-1] == "v" and ch.text:
                                    header_cells.append((ci, "s", int(ch.text)))
                                    break
                        elif ct == "inlineStr":
                            for ch in elem.iter():
                                if ch.tag.rsplit("}", 1)[-1] == "t" and ch.text:
                                    header_cells.append((ci, "v", ch.text))
                                    break
                        else:
                            for ch in elem:
                                if ch.tag.rsplit("}", 1)[-1] == "v":
                                    header_cells.append((ci, "v", ch.text or ""))
                                    break
                    elem.clear()
                    continue

                if tag == "row":
                    rn = int(elem.get("r", "0"))
                    elem.clear()
                    if rn >= 2:
                        break  # 첫 행 이후 즉시 중단
                elif tag not in ("v", "t"):
                    # v, t는 부모 c에서 참조하므로 clear하지 않음
                    elem.clear()

        # ── Pass 2: sharedStrings — 필요 인덱스만 파싱 (조기 종료) ──
        needed = {val for _, typ, val in header_cells if typ == "s"}
        ss_map = {}
        if needed:
            max_idx = max(needed)
            ss_names = [n for n in zf.namelist() if n.endswith("sharedStrings.xml")]
            if ss_names:
                idx = 0
                with zf.open(ss_names[0]) as ssf:
                    for _, elem in ET.iterparse(ssf, events=("end",)):
                        tag = elem.tag.rsplit("}", 1)[-1]
                        if tag == "si":
                            if idx in needed:
                                parts = []
                                for ch in elem.iter():
                                    if ch.tag.rsplit("}", 1)[-1] == "t" and ch.text:
                                        parts.append(ch.text)
                                ss_map[idx] = "".join(parts)
                            elem.clear()
                            idx += 1
                            if idx > max_idx:
                                break

        # ── 헤더 조립 ──
        if header_cells:
            max_ci = max(ci for ci, _, _ in header_cells)
            columns = [""] * (max_ci + 1)
            for ci, typ, val in header_cells:
                columns[ci] = ss_map.get(val, "") if typ == "s" else str(val)
        else:
            columns = []

        # trailing 빈 컬럼 제거
        while columns and not columns[-1].strip():
            columns.pop()

        return {"columns": columns, "total_rows": total_rows}


def _detect_column(df_columns, candidates):
    """DataFrame 컬럼 목록에서 후보 이름과 일치하는 첫 번째 컬럼명 반환.
    3단계 매칭: 정확 일치 → 공백제거+대소문자무시 → 부분 문자열 포함."""
    col_list = list(df_columns)
    # Pass 1: 정확 일치
    for name in candidates:
        if name in col_list:
            return name
    # Pass 2: 양쪽 공백 제거 + 대소문자 무시
    stripped_map = {c.strip().lower(): c for c in col_list if c.strip()}
    for name in candidates:
        key = name.strip().lower()
        if key in stripped_map:
            return stripped_map[key]
    # Pass 3: 부분 문자열 포함 (후보가 컬럼명에 포함)
    for name in candidates:
        nl = name.strip().lower()
        if not nl:
            continue
        for c in col_list:
            if nl in c.strip().lower():
                return c
    return None


# 통시 NA 값 패턴 (빈 문자열, #N/A 계열, nan 등)
_TONGSI_NA_VALUES = frozenset({
    "", "#n/a", "#na", "n/a", "na", "nan", "#ref!", "#value!", "#null!",
    "null", "none", "-", "--",
})


def _is_tongsi_empty(val: str) -> bool:
    """통시 컬럼 값이 비어있는지 판단.
    빈 문자열, #N/A, nan 등 = True (매칭 대상)
    숫자, 숫자+영문 (통시코드) = False (매칭 제외)"""
    stripped = val.strip()
    if not stripped:
        return True
    return stripped.lower() in _TONGSI_NA_VALUES


def _build_xlsx_ss_cache(xlsx_path: str):
    """xlsx sharedStrings → 디스크 바이너리 캐시 빌드.
    Returns: (cache_path: str | None, offsets_bytes: bytes | None)
    호출자가 cache_path 파일 삭제 책임."""
    import xml.etree.ElementTree as ET
    import struct
    from array import array

    with zipfile.ZipFile(xlsx_path, "r") as zf:
        ss_names = [n for n in zf.namelist() if n.endswith("sharedStrings.xml")]
        if not ss_names:
            return None, None

        ss_offsets = array("Q")
        ss_tmp = _tempfile.NamedTemporaryFile(delete=False, suffix=".ss")
        cache_path = ss_tmp.name
        try:
            with zf.open(ss_names[0]) as ssf:
                for _, elem in ET.iterparse(ssf, events=("end",)):
                    tag = elem.tag.rsplit("}", 1)[-1]
                    if tag == "si":
                        parts = []
                        for ch in elem.iter():
                            if ch.tag.rsplit("}", 1)[-1] == "t" and ch.text:
                                parts.append(ch.text)
                        text = "".join(parts)
                        encoded = text.encode("utf-8")
                        ss_offsets.append(ss_tmp.tell())
                        ss_tmp.write(struct.pack("<I", len(encoded)))
                        ss_tmp.write(encoded)
                        elem.clear()
            ss_tmp.close()

            if os.path.getsize(cache_path) == 0:
                os.remove(cache_path)
                return None, None
            return cache_path, ss_offsets.tobytes()
        except Exception:
            ss_tmp.close()
            try:
                os.remove(cache_path)
            except Exception:
                pass
            raise



def _s3_to_tempfile(s3_key: str, suffix: str = ".tmp") -> str:
    """S3 파일을 디스크 임시파일로 스트리밍 다운로드. 경로 반환."""
    obj = get_s3_client().get_object(Bucket=S3_BUCKET_NAME, Key=s3_key)
    tmp = _tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
    body = obj["Body"]
    try:
        while True:
            chunk = body.read(1024 * 1024)  # 1MB
            if not chunk:
                break
            tmp.write(chunk)
    finally:
        body.close()
    tmp.close()
    return tmp.name


def _get_s3_csv_keys():
    """S3 호출명칭 CSV 파일 키 목록 반환."""
    resp = get_s3_client().list_objects_v2(Bucket=S3_BUCKET_NAME, Prefix=CALLNAME_CSV_PREFIX)
    return [obj["Key"] for obj in resp.get("Contents", [])
            if obj["Key"].lower().endswith(".csv")]


def _stream_s3_csvs():
    """S3 CSV를 행 단위 스트리밍. 메모리에 전체 로드하지 않음.
    Yields: dict (각 행, CALLNAME_USE_COLS 키만)"""
    import csv as _csv_mod
    import codecs
    csv_keys = _get_s3_csv_keys()
    for key in csv_keys:
        obj = get_s3_client().get_object(Bucket=S3_BUCKET_NAME, Key=key)
        body = obj["Body"]
        try:
            stream_reader = codecs.getreader("utf-8")(body, errors="replace")
            reader = _csv_mod.DictReader(stream_reader)
            for raw_row in reader:
                yield {c: (raw_row.get(c) or "") for c in CALLNAME_USE_COLS}
        finally:
            body.close()


def _cert_lookup_streaming(query: str) -> dict:
    """설치확인서 단건 조회 — S3 CSV 스트리밍 (메모리 ~0).
    zpwino/zpwina/zpwiadr 순서로 첫 매칭 반환."""
    if not query or not query.strip():
        return {}
    q = query.strip()
    for row in _stream_s3_csvs():
        if row.get("zpwino") == q or row.get("zpwina") == q or row.get("zpwiadr") == q:
            return row
    return {}


# ── 설치확인서 조회 캐시 (SQLite 디스크 기반 — 메모리 ~0) ────────
_cert_cache_lock = threading.Lock()
_cert_cache_ts: float = 0.0
_cert_cache_db_path: str = ""
CERT_CACHE_TTL = 86400  # 24시간


def _cert_cache_load():
    """S3 CSV → SQLite DB 파일로 캐싱. 메모리 사용 최소화."""
    global _cert_cache_ts, _cert_cache_db_path
    import sqlite3

    now = _time_mod.time()
    if _cert_cache_db_path and os.path.exists(_cert_cache_db_path) and (now - _cert_cache_ts) < CERT_CACHE_TTL:
        return

    with _cert_cache_lock:
        if _cert_cache_db_path and os.path.exists(_cert_cache_db_path) and (_time_mod.time() - _cert_cache_ts) < CERT_CACHE_TTL:
            return

        logger.info("설치확인서 SQLite 캐시 빌드 시작...")
        t0 = _time_mod.time()

        db_path = os.path.join(_tempfile.gettempdir(), "cert_cache.db")
        tmp_path = db_path + ".tmp"

        conn = sqlite3.connect(tmp_path)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=OFF")
        conn.execute("""CREATE TABLE IF NOT EXISTS cert (
            zpwino TEXT, zpwina TEXT, zpwiadr TEXT,
            zpcode TEXT, area_hdofc_nm TEXT, ons_team_nm TEXT, zpirty3 TEXT,
            eqp_ser_no TEXT
        )""")
        conn.execute("DELETE FROM cert")

        batch = []
        total = 0
        for row in _stream_s3_csvs():
            batch.append((
                row.get("zpwino", ""), row.get("zpwina", ""),
                row.get("zpwiadr", ""), row.get("zpcode", ""),
                row.get("area_hdofc_nm", ""), row.get("ons_team_nm", ""),
                row.get("zpirty3", ""), row.get("eqp_ser_no", ""),
            ))
            if len(batch) >= 5000:
                conn.executemany("INSERT INTO cert VALUES (?,?,?,?,?,?,?,?)", batch)
                total += len(batch)
                batch.clear()
        if batch:
            conn.executemany("INSERT INTO cert VALUES (?,?,?,?,?,?,?,?)", batch)
            total += len(batch)

        conn.execute("CREATE INDEX IF NOT EXISTS idx_zpwino ON cert(zpwino)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_zpwina ON cert(zpwina)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_zpwiadr ON cert(zpwiadr)")
        conn.commit()
        conn.close()

        # 원자적 교체
        if os.path.exists(db_path):
            try:
                os.remove(db_path)
            except Exception:
                pass
        os.rename(tmp_path, db_path)

        _cert_cache_db_path = db_path
        _cert_cache_ts = _time_mod.time()
        logger.info(f"설치확인서 SQLite 캐시 빌드 완료: {total}행, {_cert_cache_ts - t0:.1f}초")


def _cert_cache_force_rebuild():
    """캐시 TTL 무시하고 강제 재빌드."""
    global _cert_cache_ts
    _cert_cache_ts = 0.0  # TTL 만료시켜서 재빌드 유도
    _cert_cache_load()


async def _cert_cache_daily_scheduler():
    """매일 00:00 (KST) 에 캐시 자동 재빌드."""
    from datetime import datetime, timedelta, timezone
    KST = timezone(timedelta(hours=9))
    while True:
        now = datetime.now(KST)
        tomorrow_midnight = (now + timedelta(days=1)).replace(
            hour=0, minute=0, second=0, microsecond=0)
        wait_seconds = (tomorrow_midnight - now).total_seconds()
        logger.info(f"설치확인서 캐시 다음 갱신: {tomorrow_midnight.strftime('%Y-%m-%d %H:%M')} KST ({wait_seconds:.0f}초 후)")
        await asyncio.sleep(wait_seconds)
        try:
            await asyncio.to_thread(_cert_cache_force_rebuild)
            logger.info("설치확인서 캐시 자정 자동 갱신 완료")
        except Exception as e:
            logger.error(f"설치확인서 캐시 자정 갱신 실패: {e}")


def _cert_lookup_cached(query: str) -> dict:
    """설치확인서 단건 조회 — SQLite 인덱스 O(1) 조회."""
    import sqlite3
    if not query or not query.strip():
        return {}
    _cert_cache_load()
    q = query.strip()
    cols = ["zpwino", "zpwina", "zpwiadr", "zpcode", "area_hdofc_nm", "ons_team_nm", "zpirty3", "eqp_ser_no"]
    try:
        conn = sqlite3.connect(_cert_cache_db_path)
        conn.row_factory = sqlite3.Row
        for col in ("zpwino", "zpwina", "zpwiadr"):
            cur = conn.execute(f"SELECT * FROM cert WHERE {col}=? LIMIT 1", (q,))
            row = cur.fetchone()
            if row:
                result = {c: (row[c] or "") for c in cols}
                conn.close()
                return result
        conn.close()
    except Exception as e:
        logger.warning(f"설치확인서 캐시 조회 실패: {e}")
    return {}


def _cert_batch_lookup_cached(zpwino_list: list) -> dict:
    """설치확인서 일괄 조회 — SQLite 인덱스 O(1) 조회."""
    import sqlite3
    if not zpwino_list:
        return {}
    _cert_cache_load()
    cols = ["zpwino", "zpwina", "zpwiadr", "zpcode", "area_hdofc_nm", "ons_team_nm", "zpirty3", "eqp_ser_no"]
    results = {}
    try:
        conn = sqlite3.connect(_cert_cache_db_path)
        conn.row_factory = sqlite3.Row
        for q in zpwino_list:
            if q in results:
                continue
            for col in ("zpwino", "zpwina"):
                cur = conn.execute(f"SELECT * FROM cert WHERE {col}=? LIMIT 1", (q,))
                row = cur.fetchone()
                if row:
                    results[q] = {c: (row[c] or "") for c in cols}
                    break
        conn.close()
    except Exception as e:
        logger.warning(f"설치확인서 배치 캐시 조회 실패: {e}")
    return results


def _cleanup_callname_session_files(sess: dict):
    """세션의 캐시/임시 파일 정리 (디스크 + S3) + 대용량 데이터 해제."""
    # S3 임시 파일
    s3_temp = sess.get("s3_temp_key")
    if s3_temp:
        try:
            get_s3_client().delete_object(Bucket=S3_BUCKET_NAME, Key=s3_temp)
        except Exception:
            pass
    # 디스크 캐시 파일 (xlsx + SS mmap)
    for path_key in ("cached_xlsx_path", "cached_ss_path"):
        p = sess.get(path_key)
        if p:
            try:
                os.remove(p)
            except Exception:
                pass
    # 대용량 데이터 명시적 해제 (GC 지원)
    for data_key in ("filter_cache_rows", "filter_cache_row_indices",
                      "column_stats", "cached_ss_offsets",
                      "original_row_indices", "row_zpwina_list", "row_zpwino_list",
                      "zpwina_values", "zpwino_values"):
        sess.pop(data_key, None)


def _cleanup_callname_sessions():
    """만료된 세션 + S3/디스크 임시 파일 정리."""
    now = _time_mod.time()
    expired = [k for k, v in _callname_sessions.items()
               if (now - v.get("created_at_ts", 0)) > CALLNAME_SESSION_TTL]
    for k in expired:
        _cleanup_callname_session_files(_callname_sessions[k])
        del _callname_sessions[k]


def _analyze_callname_bg(upload_id: str):
    """Background: xlsx 단일 ZIP 오픈 → SS캐시 빌드 + 전행 스캔 통합.
    - 컬럼 자동 감지 (첫 행에서 직접 추출, _parse_xlsx_header_fast 실패 보완)
    - filtered_rows 정확 계산 + 컬럼별 top-100 통계
    upload-complete 이후 백그라운드 스레드에서 실행."""
    import xml.etree.ElementTree as ET
    import struct
    import mmap as _mmap_mod
    from array import array
    from collections import Counter

    sess = _callname_sessions.get(upload_id)
    if not sess or sess.get("status") != "uploaded":
        return
    try:
        sess["analysis_status"] = "processing"

        tmp_path = sess.get("cached_xlsx_path")
        if not tmp_path or not os.path.exists(tmp_path):
            tmp_path = _s3_to_tempfile(sess["s3_temp_key"], f".{sess['ext']}")
            sess["cached_xlsx_path"] = tmp_path

        columns = []
        filtered_rows = 0
        total_rows = 0
        callname_set = set()
        col_counters = []
        filter_cache_rows = []  # tongsi 빈 행의 컬럼값 저장 (preview 즉시 계산용)
        filter_cache_row_indices = []  # tongsi 빈 행의 원본 행번호 (process에서 사용)
        ss_cache_path = None
        ss_offsets_bytes = None

        if sess.get("ext") == "xlsx":
            # ── 단일 ZIP 오픈: SS 캐시 빌드 + 행 반복 통합 ──
            _cr = re.compile(r"([A-Z]+)")
            ss_offsets = array("Q")
            ss_tmp_path = None
            ss_mmap_obj = None
            ss_fh = None

            try:
                with zipfile.ZipFile(tmp_path, "r") as zf:
                    # 1) sharedStrings → 디스크 캐시
                    ss_names = [n for n in zf.namelist() if n.endswith("sharedStrings.xml")]
                    if ss_names:
                        ss_tmp = _tempfile.NamedTemporaryFile(delete=False, suffix=".ss")
                        ss_tmp_path = ss_tmp.name
                        with zf.open(ss_names[0]) as ssf:
                            for _, elem in ET.iterparse(ssf, events=("end",)):
                                tag = elem.tag.rsplit("}", 1)[-1]
                                if tag == "si":
                                    parts = []
                                    for ch in elem.iter():
                                        if ch.tag.rsplit("}", 1)[-1] == "t" and ch.text:
                                            parts.append(ch.text)
                                    text = "".join(parts)
                                    encoded = text.encode("utf-8")
                                    ss_offsets.append(ss_tmp.tell())
                                    ss_tmp.write(struct.pack("<I", len(encoded)))
                                    ss_tmp.write(encoded)
                                    elem.clear()
                        ss_tmp.close()

                        file_size = os.path.getsize(ss_tmp_path)
                        if file_size > 0:
                            ss_fh = open(ss_tmp_path, "rb")
                            ss_mmap_obj = _mmap_mod.mmap(
                                ss_fh.fileno(), 0, access=_mmap_mod.ACCESS_READ)

                    def _get_ss(idx):
                        if ss_mmap_obj is not None and 0 <= idx < len(ss_offsets):
                            offset = ss_offsets[idx]
                            length = struct.unpack_from("<I", ss_mmap_obj, offset)[0]
                            start = offset + 4
                            return ss_mmap_obj[start:start + length].decode("utf-8")
                        return ""

                    # 2) sheet XML 행 반복 (SS 캐시 즉시 사용, ZIP 재오픈 없음)
                    sheets = sorted([n for n in zf.namelist()
                                     if "worksheets/sheet" in n])
                    sp = sheets[0] if sheets else "xl/worksheets/sheet1.xml"
                    cells = []

                    with zf.open(sp) as sf:
                        for _, elem in ET.iterparse(sf, events=("end",)):
                            tag = elem.tag.rsplit("}", 1)[-1]

                            if tag == "c":
                                ct = elem.get("t", "")
                                val = ""
                                if ct == "s":
                                    for ch in elem:
                                        if ch.tag.rsplit("}", 1)[-1] == "v" and ch.text:
                                            val = _get_ss(int(ch.text))
                                            break
                                elif ct == "inlineStr":
                                    for ch in elem.iter():
                                        if ch.tag.rsplit("}", 1)[-1] == "t" and ch.text:
                                            val = ch.text
                                            break
                                else:
                                    for ch in elem:
                                        if ch.tag.rsplit("}", 1)[-1] == "v":
                                            val = ch.text or ""
                                            break
                                r_attr = elem.get("r", "")
                                m = _cr.match(r_attr) if r_attr else None
                                if m:
                                    ci = _col_to_idx(m.group(1))
                                    while len(cells) <= ci:
                                        cells.append("")
                                    cells[ci] = val
                                else:
                                    cells.append(val)
                                elem.clear()

                            elif tag == "row":
                                rn = int(elem.get("r", "0")) - 1
                                if rn == 0:
                                    # 첫 행 → 컬럼 헤더
                                    columns = cells[:]
                                    while columns and not columns[-1].strip():
                                        columns.pop()
                                    col_counters = [Counter() for _ in range(len(columns))]
                                    # 컬럼 감지
                                    tongsi_col = _detect_column(columns, CALLNAME_POSSIBLE_TONGSI_COLS)
                                    callname_col = _detect_column(columns, CALLNAME_POSSIBLE_CALLNAME_COLS)
                                    zpwina_col = _detect_column(columns, CALLNAME_POSSIBLE_ZPWINA_COLS)
                                    zpwino_col = _detect_column(columns, CALLNAME_POSSIBLE_ZPWINO_COLS)
                                    tongsi_idx = columns.index(tongsi_col) if tongsi_col else -1
                                    callname_idx = columns.index(callname_col) if callname_col and callname_col in columns else -1
                                else:
                                    total_rows += 1
                                    tongsi_val = cells[tongsi_idx] if 0 <= tongsi_idx < len(cells) else ""
                                    tongsi_empty = _is_tongsi_empty(tongsi_val)
                                    if tongsi_empty:
                                        filtered_rows += 1
                                        # 호출명칭 중복 제거 카운트
                                        if 0 <= callname_idx < len(cells) and cells[callname_idx].strip():
                                            callname_set.add(cells[callname_idx].strip())
                                        # preview 즉시 계산용 캐시 (tongsi 빈 행만 저장)
                                        row_vals = cells[:len(columns)] if len(cells) >= len(columns) else cells + [""] * (len(columns) - len(cells))
                                        filter_cache_rows.append(row_vals[:])
                                        filter_cache_row_indices.append(rn + 1)  # XML row number (1-based)
                                    for i, v in enumerate(cells):
                                        if v and i < len(col_counters) and len(col_counters[i]) < 200:
                                            col_counters[i][v] += 1
                                cells = []
                                elem.clear()
                            elif tag not in ("v", "t"):
                                # v, t는 부모 c에서 참조하므로 clear하지 않음
                                elem.clear()

                # 캐시 경로 저장 (preview/process 재사용)
                ss_cache_path = ss_tmp_path
                ss_offsets_bytes = ss_offsets.tobytes() if ss_tmp_path else None
            finally:
                if ss_mmap_obj is not None:
                    ss_mmap_obj.close()
                if ss_fh is not None:
                    ss_fh.close()
        else:
            # xls
            import xlrd
            wb = xlrd.open_workbook(tmp_path)
            ws = wb.sheet_by_index(0)
            columns = [str(ws.cell_value(0, c)) for c in range(ws.ncols)]
            col_counters = [Counter() for _ in range(len(columns))]
            tongsi_col = _detect_column(columns, CALLNAME_POSSIBLE_TONGSI_COLS)
            callname_col = _detect_column(columns, CALLNAME_POSSIBLE_CALLNAME_COLS)
            zpwina_col = _detect_column(columns, CALLNAME_POSSIBLE_ZPWINA_COLS)
            zpwino_col = _detect_column(columns, CALLNAME_POSSIBLE_ZPWINO_COLS)
            tongsi_idx = columns.index(tongsi_col) if tongsi_col else -1
            cn_idx = columns.index(callname_col) if callname_col and callname_col in columns else -1
            for r in range(1, ws.nrows):
                total_rows += 1
                vals = [str(ws.cell_value(r, c)) for c in range(ws.ncols)]
                tongsi_val = vals[tongsi_idx] if 0 <= tongsi_idx < len(vals) else ""
                tongsi_empty = _is_tongsi_empty(tongsi_val)
                if tongsi_empty:
                    filtered_rows += 1
                    # 호출명칭 중복 제거 카운트
                    if 0 <= cn_idx < len(vals) and vals[cn_idx].strip():
                        callname_set.add(vals[cn_idx].strip())
                    # preview 즉시 계산용 캐시
                    filter_cache_rows.append(vals[:len(columns)])
                    filter_cache_row_indices.append(r + 1)  # 원본 행번호 (1-based, 헤더=row1이므로 r+1)
                for i, v in enumerate(vals):
                    if v and i < len(col_counters) and len(col_counters[i]) < 200:
                        col_counters[i][v] += 1
            wb.release_resources()

        # 컬럼별 top-100 값 통계
        column_stats = {}
        for i, col in enumerate(columns):
            if i < len(col_counters):
                top = col_counters[i].most_common(100)
                if top:
                    column_stats[col] = [{"value": v, "count": c} for v, c in top]

        # 컬럼 감지 디버깅 로그
        _cn = callname_col if 'callname_col' in dir() else None
        _ts = tongsi_col if 'tongsi_col' in dir() else None
        if not _cn or not _ts:
            logger.warning(f"호출명칭 컬럼 감지 결과 — callname={_cn}, tongsi={_ts}, "
                           f"파일 컬럼(앞 20개): {columns[:20]}")

        # 세션 갱신 (컬럼 감지 결과도 덮어쓰기 → _parse_xlsx_header_fast 실패 보완)
        sess["columns"] = columns
        sess["callname_col"] = callname_col if 'callname_col' in dir() else sess.get("callname_col")
        sess["tongsi_col"] = tongsi_col if 'tongsi_col' in dir() else sess.get("tongsi_col")
        sess["zpwina_col"] = zpwina_col if 'zpwina_col' in dir() else sess.get("zpwina_col")
        sess["zpwino_col"] = zpwino_col if 'zpwino_col' in dir() else sess.get("zpwino_col")
        sess["filtered_rows"] = filtered_rows
        sess["target_callnames"] = len(callname_set)
        sess["total_rows"] = total_rows
        sess["column_stats"] = column_stats
        sess["filter_cache_rows"] = filter_cache_rows  # tongsi 빈 행의 컬럼값 (preview 즉시 계산용)
        sess["filter_cache_row_indices"] = filter_cache_row_indices  # 원본 행번호 (process에서 사용)
        sess["cached_ss_path"] = ss_cache_path
        sess["cached_ss_offsets"] = ss_offsets_bytes
        sess["analysis_status"] = "complete"

        # SS 캐시는 분석 완료 후 즉시 해제 (process에서 더 이상 사용 안 함)
        if ss_cache_path:
            try:
                os.remove(ss_cache_path)
            except Exception:
                pass
        sess.pop("cached_ss_path", None)
        sess.pop("cached_ss_offsets", None)
        del ss_offsets_bytes, ss_cache_path

        # 명시적 해제 (GC가 빠르게 수거하도록)
        del col_counters, callname_set
        logger.info(f"filter_cache_rows: {len(filter_cache_rows)}행 캐시됨")
        _release_memory()
        logger.info(f"호출명칭 분석 완료: upload_id={upload_id}, "
                     f"cols={len(columns)}, total={total_rows}, filtered={filtered_rows}")
    except Exception as e:
        sess_ref = _callname_sessions.get(upload_id)
        if sess_ref:
            sess_ref["analysis_status"] = "error"
        logger.error(f"호출명칭 분석 실패: upload_id={upload_id}: {e}")
        import traceback
        logger.error(traceback.format_exc())


def _query_callname_db(zpwina_values: list, zpwino_values: list) -> dict:
    """6방향 교차 매칭 — SQLite 캐시 활용 (인덱스 조회).
    {lookup_key: {area_hdofc_nm, ons_team_nm, zpcode, zpwiadr}}"""
    import sqlite3
    zpwina_set = set(str(v) for v in zpwina_values if v)
    zpwino_set = set(str(v) for v in zpwino_values if v)
    all_query = zpwina_set | zpwino_set
    if not all_query:
        return {}

    _cert_cache_load()  # SQLite 캐시 보장

    result = {}
    try:
        conn = sqlite3.connect(_cert_cache_db_path)
        conn.row_factory = sqlite3.Row

        # 배치 크기 제한 (SQLite 변수 최대 999개)
        query_list = list(all_query)
        BATCH = 900
        for offset in range(0, len(query_list), BATCH):
            batch = query_list[offset:offset + BATCH]
            placeholders = ",".join("?" * len(batch))

            # zpwina 매칭
            cur = conn.execute(
                f"SELECT zpwina, zpwino, zpwiadr, zpcode, area_hdofc_nm, ons_team_nm "
                f"FROM cert WHERE zpwina IN ({placeholders})", batch)
            for row in cur:
                data = {
                    "area_hdofc_nm": row["area_hdofc_nm"] or "",
                    "ons_team_nm": row["ons_team_nm"] or "",
                    "zpcode": row["zpcode"] or "",
                    "zpwiadr": row["zpwiadr"] or "",
                }
                for key in (row["zpwina"], row["zpwino"], row["zpwiadr"]):
                    if key and key in all_query and key not in result:
                        result[key] = data

            # zpwino 매칭 (zpwina에서 못 찾은 것만)
            remaining = [q for q in batch if q not in result]
            if remaining:
                ph2 = ",".join("?" * len(remaining))
                cur = conn.execute(
                    f"SELECT zpwina, zpwino, zpwiadr, zpcode, area_hdofc_nm, ons_team_nm "
                    f"FROM cert WHERE zpwino IN ({ph2})", remaining)
                for row in cur:
                    data = {
                        "area_hdofc_nm": row["area_hdofc_nm"] or "",
                        "ons_team_nm": row["ons_team_nm"] or "",
                        "zpcode": row["zpcode"] or "",
                        "zpwiadr": row["zpwiadr"] or "",
                    }
                    for key in (row["zpwina"], row["zpwino"], row["zpwiadr"]):
                        if key and key in all_query and key not in result:
                            result[key] = data

            # zpwiadr 매칭 (아직 못 찾은 것만)
            remaining2 = [q for q in batch if q not in result]
            if remaining2:
                ph3 = ",".join("?" * len(remaining2))
                cur = conn.execute(
                    f"SELECT zpwina, zpwino, zpwiadr, zpcode, area_hdofc_nm, ons_team_nm "
                    f"FROM cert WHERE zpwiadr IN ({ph3})", remaining2)
                for row in cur:
                    data = {
                        "area_hdofc_nm": row["area_hdofc_nm"] or "",
                        "ons_team_nm": row["ons_team_nm"] or "",
                        "zpcode": row["zpcode"] or "",
                        "zpwiadr": row["zpwiadr"] or "",
                    }
                    for key in (row["zpwina"], row["zpwino"], row["zpwiadr"]):
                        if key and key in all_query and key not in result:
                            result[key] = data

        conn.close()
    except Exception as e:
        logger.warning(f"호출명칭 SQLite 매칭 실패, 스트리밍 fallback: {e}")
        return _query_callname_db_streaming(zpwina_values, zpwino_values)

    return result


def _query_callname_db_streaming(zpwina_values: list, zpwino_values: list) -> dict:
    """6방향 교차 매칭 — S3 CSV 스트리밍 fallback."""
    zpwina_set = set(str(v) for v in zpwina_values if v)
    zpwino_set = set(str(v) for v in zpwino_values if v)
    all_query = zpwina_set | zpwino_set
    if not all_query:
        return {}
    result = {}
    total_rows = 0
    for row in _stream_s3_csvs():
        total_rows += 1
        zpwino = row.get("zpwino", "")
        zpwina = row.get("zpwina", "")
        zpwiadr = row.get("zpwiadr", "")
        matched_keys = []
        if zpwina and zpwina in all_query:
            matched_keys.append(zpwina)
        if zpwino and zpwino in all_query:
            matched_keys.append(zpwino)
        if zpwiadr and zpwiadr in all_query:
            matched_keys.append(zpwiadr)
        if matched_keys:
            data = {
                "area_hdofc_nm": row.get("area_hdofc_nm", ""),
                "ons_team_nm": row.get("ons_team_nm", ""),
                "zpcode": row.get("zpcode", ""),
                "zpwiadr": row.get("zpwiadr", ""),
            }
            for k in matched_keys:
                if k not in result:
                    result[k] = data
        if len(result) >= len(all_query):
            break
    global _callname_db_row_count
    if total_rows > 0:
        _callname_db_row_count = total_rows
    return result


# ── 호출명칭 매칭 API ──────────────────────────────────────

def _process_callname_upload_sync(job_id: str, tmp_path: str, filename: str,
                                   ext: str, replace: bool):
    """백그라운드: 호출명칭 DB 파일 파싱 → S3 업로드 (동기, to_thread에서 실행)"""
    import csv as _csv_mod
    global _callname_db_row_count
    job = _callname_upload_jobs[job_id]
    filtered_paths = []
    try:
        job["stage"] = "파일 분석 중..."
        job["percent"] = 10
        base_name = filename.rsplit(".", 1)[0].replace(" ", "_")

        # ── 파일 형식별 파싱 → 필터링된 CSV 생성 ──
        if ext == "csv":
            filtered_path = tmp_path + ".filtered.csv"
            filtered_paths.append(("csv", filtered_path))
            first_chunk = True
            with open(filtered_path, "w", encoding="utf-8", newline="") as f:
                for chunk_df in pd.read_csv(
                    tmp_path, dtype=str, na_filter=False, chunksize=50000
                ):
                    avail = [c for c in CALLNAME_USE_COLS if c in chunk_df.columns]
                    if not avail:
                        del chunk_df
                        continue
                    chunk_df[avail].to_csv(f, index=False, header=first_chunk)
                    first_chunk = False
                    del chunk_df
            job["stage"] = "CSV 필터링 완료"
            job["percent"] = 50

        elif ext == "xlsx":
            logger.info(f"호출명칭 xlsx 파싱 시작: {filename}")
            wb = openpyxl.load_workbook(tmp_path, read_only=True, data_only=True)
            sheet_names = wb.sheetnames
            logger.info(f"호출명칭 xlsx 시트 목록: {sheet_names}")
            total_sheets = len(sheet_names)

            for sheet_idx, sn in enumerate(sheet_names):
                pct = 10 + int(40 * sheet_idx / max(total_sheets, 1))
                job["stage"] = f"시트 '{sn}' 처리 중... ({sheet_idx+1}/{total_sheets})"
                job["percent"] = pct

                ws = wb[sn]
                filtered_path = tmp_path + f".sheet{sheet_idx}.csv"
                header_row = None
                avail_indices = []
                row_count_sheet = 0
                try:
                    with open(filtered_path, "w", encoding="utf-8", newline="") as f:
                        writer = _csv_mod.writer(f)
                        for row_idx, row in enumerate(ws.iter_rows(values_only=True)):
                            if row_idx == 0:
                                header_row = [str(c) if c is not None else "" for c in row]
                                logger.info(f"호출명칭 시트 '{sn}' 헤더: {header_row[:10]}...")
                                avail_indices = [i for i, h in enumerate(header_row) if h in CALLNAME_USE_COLS]
                                if not avail_indices:
                                    logger.warning(f"호출명칭 시트 '{sn}': 필요 컬럼 없음")
                                    break
                                writer.writerow([header_row[i] for i in avail_indices])
                                continue
                            writer.writerow([str(row[i]) if i < len(row) and row[i] is not None else "" for i in avail_indices])
                            row_count_sheet += 1
                            if row_count_sheet % 100000 == 0:
                                job["stage"] = f"시트 '{sn}': {row_count_sheet:,}행 처리 중..."
                                logger.info(job["stage"])
                except Exception as sheet_err:
                    logger.error(f"호출명칭 시트 '{sn}' 처리 오류: {sheet_err}")
                    try:
                        os.unlink(filtered_path)
                    except OSError:
                        pass
                    continue
                if avail_indices:
                    filtered_paths.append((f"sheet_{sn}", filtered_path))
                    logger.info(f"호출명칭 Excel 시트 '{sn}': {row_count_sheet:,}행 추출 완료")
                else:
                    try:
                        os.unlink(filtered_path)
                    except OSError:
                        pass
            wb.close()
            del wb
            job["percent"] = 50

        elif ext == "xls":
            if not HAS_XLRD:
                raise RuntimeError("xlrd 미설치")
            xls_book = xlrd.open_workbook(tmp_path)
            for sheet_idx in range(xls_book.nsheets):
                ws = xls_book.sheet_by_index(sheet_idx)
                sn = ws.name
                if ws.nrows == 0:
                    continue
                header_row = [str(ws.cell_value(0, c)) for c in range(ws.ncols)]
                avail_indices = [i for i, h in enumerate(header_row) if h in CALLNAME_USE_COLS]
                if not avail_indices:
                    continue
                filtered_path = tmp_path + f".sheet{sheet_idx}.csv"
                filtered_paths.append((f"sheet_{sn}", filtered_path))
                with open(filtered_path, "w", encoding="utf-8", newline="") as f:
                    writer = _csv_mod.writer(f)
                    writer.writerow([header_row[i] for i in avail_indices])
                    for r in range(1, ws.nrows):
                        writer.writerow([str(ws.cell_value(r, i)) for i in avail_indices])
            xls_book.release_resources()
            del xls_book
            job["percent"] = 50

        # 원본 임시파일 삭제
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        _release_memory()

        if not filtered_paths:
            job["status"] = "failed"
            job["stage"] = "필요한 컬럼이 포함된 시트가 없습니다."
            job["percent"] = 100
            return

        # ── S3 업로드 ──
        job["stage"] = "S3에 업로드 중..."
        job["percent"] = 60

        if replace:
            try:
                resp = get_s3_client().list_objects_v2(
                    Bucket=S3_BUCKET_NAME, Prefix=CALLNAME_CSV_PREFIX)
                for obj in resp.get("Contents", []):
                    get_s3_client().delete_object(
                        Bucket=S3_BUCKET_NAME, Key=obj["Key"])
                logger.info("호출명칭 DB 기존 파일 전체 삭제 (replace 모드)")
            except Exception:
                pass

        uploaded_keys = []
        timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
        for i, (label, fpath) in enumerate(filtered_paths):
            s3_key = f"{CALLNAME_CSV_PREFIX}{base_name}_{label}_{timestamp}.csv"
            file_size = os.path.getsize(fpath)
            with open(fpath, "rb") as f:
                get_s3_client().put_object(Bucket=S3_BUCKET_NAME, Key=s3_key, Body=f)
            uploaded_keys.append(s3_key)
            pct = 60 + int(25 * (i + 1) / len(filtered_paths))
            job["stage"] = f"S3 업로드 중... ({i+1}/{len(filtered_paths)})"
            job["percent"] = pct
            logger.info(f"호출명칭 DB 업로드: {s3_key} ({file_size:,} bytes)")

        # ── 행 수 집계 ──
        job["stage"] = "행 수 집계 중..."
        job["percent"] = 90
        uploaded_rows = 0
        for _, fpath in filtered_paths:
            with open(fpath, encoding="utf-8") as cnt_f:
                uploaded_rows += sum(1 for _ in cnt_f) - 1

        # 스트리밍 방식이므로 캐시 무효화 불필요 (항상 S3에서 직접 읽음)
        _callname_db_row_count = uploaded_rows

        file_count = len(filtered_paths)
        job["status"] = "completed"
        job["stage"] = "완료"
        job["percent"] = 100
        job["result"] = {
            "message": f"DB 업로드 완료 ({file_count}개 파일, 총 {uploaded_rows:,}행)",
            "files": uploaded_keys,
            "total_rows": uploaded_rows,
        }
        logger.info(f"호출명칭 DB 업로드 완료: {file_count}개 파일, {uploaded_rows:,}행")

    except Exception as e:
        logger.error(f"호출명칭 DB 업로드 실패: {e}")
        job["status"] = "failed"
        job["stage"] = f"업로드 실패: {str(e)[:200]}"
        job["percent"] = 100
    finally:
        # 임시파일 정리
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        for _, fpath in filtered_paths:
            try:
                os.unlink(fpath)
            except OSError:
                pass
        _release_memory()


@app.post("/callname/upload-csv")
async def callname_upload_csv(
    request: Request,
    file: UploadFile = File(...),
    replace: bool = Query(False, description="True면 기존 DB 전체 교체, False면 추가/병합"),
):
    """관리자: 파일 → 디스크 저장 → jobId 즉시 반환 → 백그라운드 처리"""
    await _require_role(request, {"admin"})
    _check_memory("호출명칭 DB 업로드")
    if not file.filename.lower().endswith((".csv", ".xlsx", ".xls")):
        raise HTTPException(status_code=400, detail="CSV 또는 Excel 파일만 가능합니다.")
    _get_pandas()
    if not HAS_PANDAS:
        raise HTTPException(status_code=500, detail="pandas 미설치")

    ext = file.filename.rsplit(".", 1)[-1].lower()

    # 1) 파일 → 디스크 임시 저장 (메모리에 전체 로드 X)
    with _tempfile.NamedTemporaryFile(delete=False, suffix=f".{ext}") as tmp:
        tmp_path = tmp.name
        while True:
            chunk = await file.read(8 * 1024 * 1024)  # 8MB 청크
            if not chunk:
                break
            tmp.write(chunk)

    # 2) 잡 생성 + 즉시 반환
    job_id = str(uuid.uuid4())
    _callname_upload_jobs[job_id] = {
        "status": "processing",
        "stage": "파일 수신 완료, 처리 시작...",
        "percent": 5,
        "filename": file.filename,
        "replace": replace,
        "created_at": datetime.now(timezone.utc).isoformat(),
    }

    # 3) 백그라운드 스레드에서 처리 (제한된 executor)
    asyncio.get_event_loop().run_in_executor(
        _bounded_executor, _process_callname_upload_sync,
        job_id, tmp_path, file.filename, ext, replace,
    )

    return {"success": True, "jobId": job_id}


@app.get("/callname/upload-job/{job_id}")
async def callname_upload_job_status(job_id: str, request: Request):
    """호출명칭 DB 업로드 잡 상태 조회 (프론트에서 2초 간격 폴링)"""
    await _verify_auth(request)
    job = _callname_upload_jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return {
        "status": job["status"],
        "stage": job["stage"],
        "percent": job["percent"],
        "result": job.get("result"),
    }


@app.get("/callname/db-status")
async def callname_db_status(request: Request):
    """호출명칭 DB 상태 조회 (S3 파일 목록 기반)"""
    await _verify_auth(request)
    files = []
    total_size = 0
    try:
        resp = get_s3_client().list_objects_v2(
            Bucket=S3_BUCKET_NAME, Prefix=CALLNAME_CSV_PREFIX)
        for obj in resp.get("Contents", []):
            key = obj["Key"]
            if not key.lower().endswith(".csv"):
                continue
            size = obj.get("Size", 0)
            total_size += size
            files.append({
                "name": key.split("/")[-1],
                "size": size,
                "last_modified": obj["LastModified"].isoformat() if obj.get("LastModified") else None,
            })
    except Exception:
        pass
    return {
        "loaded": len(files) > 0,
        "rows": _callname_db_row_count,
        "file_count": len(files),
        "total_size": total_size,
        "files": files,
    }


@app.get("/callname/db-preview")
async def callname_db_preview(request: Request, limit: int = Query(50, ge=1, le=200)):
    """호출명칭 DB 미리보기 — S3 CSV에서 첫 N행 반환 (메모리 최소 사용)"""
    await _verify_auth(request)
    import csv as _csv_mod
    s3 = get_s3_client()
    result_files = []
    try:
        resp = s3.list_objects_v2(Bucket=S3_BUCKET_NAME, Prefix=CALLNAME_CSV_PREFIX)
        for obj in resp.get("Contents", []):
            key = obj["Key"]
            if not key.lower().endswith(".csv"):
                continue
            s3_obj = s3.get_object(Bucket=S3_BUCKET_NAME, Key=key)
            body_bytes = b""
            # 미리보기용: 최대 1MB만 읽기 (전체 로드 방지)
            for chunk in s3_obj["Body"].iter_chunks(1024 * 1024):
                body_bytes = chunk
                break
            text = body_bytes.decode("utf-8", errors="replace")
            lines = text.split("\n")
            reader = _csv_mod.reader(lines)
            headers = []
            rows = []
            for i, row in enumerate(reader):
                if i == 0:
                    headers = row
                    continue
                if not any(row):
                    continue
                rows.append(row)
                if len(rows) >= limit:
                    break
            result_files.append({
                "name": key.split("/")[-1],
                "headers": headers,
                "rows": rows,
                "preview_count": len(rows),
            })
    except Exception as e:
        logger.error(f"호출명칭 DB 미리보기 실패: {e}")
        raise HTTPException(status_code=500, detail=str(e))
    return {"files": result_files}


@app.post("/callname/upload-raw")
async def callname_upload_raw(request: Request, file: UploadFile = File(...)):
    """호출명칭 Excel → S3 멀티파트 스트리밍 (파싱 없음, 파일 전송만)
    140MB+ 대용량 파일도 ALB timeout 없이 업로드 가능.
    메모리: ~16MB (8MB 수신 + 8MB 업로드 파트)"""
    await _verify_auth(request)
    _check_memory("호출명칭 업로드")
    _cleanup_callname_sessions()
    active = sum(1 for v in _callname_sessions.values() if v.get("status") in ("uploaded", "ready"))
    if active >= CALLNAME_MAX_SESSIONS:
        raise HTTPException(status_code=429, detail=f"동시 세션 초과 (최대 {CALLNAME_MAX_SESSIONS})")

    filename = file.filename or "unknown.xlsx"
    ext = filename.rsplit(".", 1)[-1].lower()
    if ext not in ("xlsx", "xls"):
        raise HTTPException(status_code=400, detail="xlsx 또는 xls 파일만 가능합니다.")

    safe_name = re.sub(r"[^\w\-_\.]", "_", filename)
    upload_id = str(uuid.uuid4())
    s3_key = f"callname-temp/{upload_id}/{safe_name}"
    content_type = (
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        if ext == "xlsx" else "application/vnd.ms-excel"
    )
    s3 = get_s3_client()
    mpu_upload_id: Optional[str] = None

    try:
        mpu = await asyncio.to_thread(
            lambda: s3.create_multipart_upload(
                Bucket=S3_BUCKET_NAME, Key=s3_key, ContentType=content_type
            )
        )
        mpu_upload_id = mpu["UploadId"]

        PART_SIZE = 8 * 1024 * 1024
        buf = b""
        parts: list = []
        part_number = 1
        total_size = 0

        while True:
            chunk = await file.read(PART_SIZE)
            if not chunk:
                break
            total_size += len(chunk)
            if total_size > MAX_DS_UPLOAD_SIZE:
                raise HTTPException(status_code=413, detail="파일 크기 초과 (200MB)")
            buf += chunk
            while len(buf) >= PART_SIZE:
                part_data, buf = buf[:PART_SIZE], buf[PART_SIZE:]
                pn = part_number
                resp = await asyncio.to_thread(
                    lambda pd=part_data, n=pn: s3.upload_part(
                        Bucket=S3_BUCKET_NAME, Key=s3_key,
                        UploadId=mpu_upload_id, PartNumber=n, Body=pd,
                    )
                )
                parts.append({"PartNumber": pn, "ETag": resp["ETag"]})
                part_number += 1

        if buf:
            pn = part_number
            resp = await asyncio.to_thread(
                lambda pd=buf, n=pn: s3.upload_part(
                    Bucket=S3_BUCKET_NAME, Key=s3_key,
                    UploadId=mpu_upload_id, PartNumber=n, Body=pd,
                )
            )
            parts.append({"PartNumber": pn, "ETag": resp["ETag"]})

        if not parts:
            raise ValueError("업로드된 데이터가 없습니다")

        await asyncio.to_thread(
            lambda: s3.complete_multipart_upload(
                Bucket=S3_BUCKET_NAME, Key=s3_key, UploadId=mpu_upload_id,
                MultipartUpload={"Parts": parts},
            )
        )
        logger.info(f"callname upload-raw: {s3_key} ({len(parts)} parts, {total_size // 1024}KB)")
        return {
            "success": True,
            "s3Key": s3_key,
            "uploadId": upload_id,
            "filename": filename,
            "ext": ext,
        }

    except HTTPException:
        raise
    except Exception as e:
        if mpu_upload_id:
            try:
                await asyncio.to_thread(
                    lambda: s3.abort_multipart_upload(
                        Bucket=S3_BUCKET_NAME, Key=s3_key, UploadId=mpu_upload_id,
                    )
                )
            except Exception:
                pass
        logger.error(f"호출명칭 upload-raw 실패: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.post("/callname/upload-complete")
async def callname_upload_complete(request: Request):
    """S3 업로드 완료 후 경량 파싱 — 컬럼 감지 + 행 수 집계
    /callname/upload-raw 이후 호출. S3→EC2 다운로드(VPC 내부, 빠름) + mmap 파싱."""
    await _verify_auth(request)
    _check_memory("호출명칭 파싱")

    body = await request.json()
    upload_id = body.get("uploadId")
    s3_key = body.get("s3Key")
    filename = body.get("filename", "unknown.xlsx")
    ext = body.get("ext", filename.rsplit(".", 1)[-1].lower())

    if not upload_id or not s3_key:
        raise HTTPException(status_code=400, detail="uploadId, s3Key 필수")

    # 이미 같은 upload_id로 세션이 있으면 중복 방지
    if upload_id in _callname_sessions:
        sess = _callname_sessions[upload_id]
        return {
            "upload_id": upload_id,
            "filename": sess.get("filename", filename),
            **{k: sess.get(k) for k in ("total_rows", "columns", "callname_col",
                                          "tongsi_col", "zpwina_col", "zpwino_col",
                                          "filtered_rows")},
            "detected_callname_col": sess.get("callname_col"),
            "detected_tongsi_col": sess.get("tongsi_col"),
            "detected_zpwina_col": sess.get("zpwina_col"),
            "detected_zpwino_col": sess.get("zpwino_col"),
        }

    try:
        # S3 → 디스크 다운로드 (VPC 내부, 빠름) — 백그라운드 분석용으로 보존
        tmp_path = await asyncio.to_thread(_s3_to_tempfile, s3_key, f".{ext}")

        def _parse_lightweight_from_s3():
            # 임시파일 삭제하지 않음 → 백그라운드 분석에서 재사용
            if ext == "xlsx":
                fast = _parse_xlsx_header_fast(tmp_path)
                columns = fast["columns"]
                total_rows = fast["total_rows"]
                tongsi_col = _detect_column(columns, CALLNAME_POSSIBLE_TONGSI_COLS)
                filtered_rows = total_rows  # 정확한 값은 백그라운드 분석 후 갱신
            else:
                import xlrd
                wb = xlrd.open_workbook(tmp_path)
                ws = wb.sheet_by_index(0)
                columns = [str(ws.cell_value(0, c)) for c in range(ws.ncols)]
                total_rows = ws.nrows - 1
                tongsi_col = _detect_column(columns, CALLNAME_POSSIBLE_TONGSI_COLS)
                filtered_rows = total_rows
                wb.release_resources()

            callname_col = _detect_column(columns, CALLNAME_POSSIBLE_CALLNAME_COLS)
            zpwina_col = _detect_column(columns, CALLNAME_POSSIBLE_ZPWINA_COLS)
            zpwino_col = _detect_column(columns, CALLNAME_POSSIBLE_ZPWINO_COLS)

            return {
                "total_rows": total_rows, "columns": columns,
                "callname_col": callname_col, "tongsi_col": tongsi_col,
                "zpwina_col": zpwina_col, "zpwino_col": zpwino_col,
                "filtered_rows": filtered_rows,
            }

        info = await asyncio.to_thread(_parse_lightweight_from_s3)

        _callname_sessions[upload_id] = {
            "filename": filename,
            "s3_temp_key": s3_key,
            "ext": ext,
            "status": "uploaded",
            "created_at_ts": _time_mod.time(),
            "cached_xlsx_path": tmp_path,  # 백그라운드 분석용 보존
            "analysis_status": "pending",
            **info,
        }

        # 백그라운드 분석 시작 (전행 스캔 → 정확한 filtered_rows + 컬럼 통계)
        asyncio.get_event_loop().run_in_executor(None, _analyze_callname_bg, upload_id)

        return {
            "upload_id": upload_id,
            "filename": filename,
            **info,
            "detected_callname_col": info["callname_col"],
            "detected_tongsi_col": info["tongsi_col"],
            "detected_zpwina_col": info["zpwina_col"],
            "detected_zpwino_col": info["zpwino_col"],
        }
    except HTTPException:
        raise
    except Exception as e:
        # 실패 시 임시파일 정리
        if 'tmp_path' in dir():
            try:
                os.remove(tmp_path)
            except Exception:
                pass
        logger.error(f"호출명칭 upload-complete 실패: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.get("/callname/upload/{upload_id}/analysis")
async def callname_analysis_status(upload_id: str, request: Request):
    """백그라운드 분석 상태 조회 — 프론트엔드 폴링용."""
    await _verify_auth(request)
    sess = _callname_sessions.get(upload_id)
    if not sess:
        raise HTTPException(status_code=404, detail="세션 없음")
    status = sess.get("analysis_status", "pending")
    result = {"status": status}
    if status == "complete":
        result["filtered_rows"] = sess.get("filtered_rows", 0)
        result["target_callnames"] = sess.get("target_callnames", 0)
        result["total_rows"] = sess.get("total_rows", 0)
        # 컬럼 + 감지 결과 (upload-complete에서 누락됐을 수 있으므로 분석 결과로 갱신)
        result["columns"] = sess.get("columns", [])
        result["detected_callname_col"] = sess.get("callname_col")
        result["detected_tongsi_col"] = sess.get("tongsi_col")
        result["detected_zpwina_col"] = sess.get("zpwina_col")
        result["detected_zpwino_col"] = sess.get("zpwino_col")
    return result


@app.post("/callname/upload")
async def callname_upload(request: Request, file: UploadFile = File(...)):
    """Excel 업로드 → S3 임시저장 + 경량 컬럼 감지 (소용량 fallback)"""
    await _verify_auth(request)
    _check_memory("호출명칭 Excel 업로드")

    _cleanup_callname_sessions()
    active = sum(1 for v in _callname_sessions.values() if v.get("status") in ("uploaded", "ready"))
    if active >= CALLNAME_MAX_SESSIONS:
        raise HTTPException(status_code=429, detail=f"동시 세션 초과 (최대 {CALLNAME_MAX_SESSIONS})")

    filename = file.filename or "unknown.xlsx"
    ext = filename.rsplit(".", 1)[-1].lower()
    if ext not in ("xlsx", "xls"):
        raise HTTPException(status_code=400, detail="xlsx 또는 xls 파일만 가능합니다.")

    # 1) 디스크에 스트리밍 저장 (메모리에 전체 파일 올리지 않음)
    tmp = _tempfile.NamedTemporaryFile(delete=False, suffix=f".{ext}")
    tmp_path = tmp.name
    file_size = 0
    try:
        while True:
            chunk = await file.read(4 * 1024 * 1024)  # 4MB 청크
            if not chunk:
                break
            file_size += len(chunk)
            if file_size > MAX_DS_UPLOAD_SIZE:
                tmp.close()
                os.remove(tmp_path)
                raise HTTPException(status_code=413, detail="파일 크기 초과 (200MB)")
            tmp.write(chunk)
        tmp.close()

        # 2) S3 업로드 (디스크에서 스트리밍)
        upload_id = str(uuid.uuid4())
        s3_temp_key = f"callname-temp/{upload_id}/{filename}"
        with open(tmp_path, "rb") as f:
            get_s3_client().upload_fileobj(f, S3_BUCKET_NAME, s3_temp_key)

        # 3) 경량 컬럼 감지: ZIP+XML 직접 파싱 (openpyxl.load_workbook 회피 → 메모리 절감)
        def _parse_lightweight():
            if ext == "xlsx":
                columns = []
                total_rows = 0
                tongsi_idx = -1
                filtered_rows = 0
                for rn, vals in _iter_xlsx_rows_light(tmp_path):
                    if rn == 0:
                        columns = vals[:]
                        tongsi_col = _detect_column(columns, CALLNAME_POSSIBLE_TONGSI_COLS)
                        tongsi_idx = columns.index(tongsi_col) if tongsi_col and tongsi_col in columns else -1
                        continue
                    total_rows += 1
                    if tongsi_idx >= 0 and tongsi_idx < len(vals):
                        val = vals[tongsi_idx]
                        if not val.strip():
                            filtered_rows += 1
                _release_memory()
            else:
                # xls: xlrd
                import xlrd
                wb = xlrd.open_workbook(tmp_path)
                ws = wb.sheet_by_index(0)
                columns = [str(ws.cell_value(0, c)) for c in range(ws.ncols)]
                total_rows = ws.nrows - 1

                tongsi_col = _detect_column(columns, CALLNAME_POSSIBLE_TONGSI_COLS)
                tongsi_idx = columns.index(tongsi_col) if tongsi_col and tongsi_col in columns else -1
                filtered_rows = 0
                if tongsi_idx >= 0:
                    for r in range(1, ws.nrows):
                        val = ws.cell_value(r, tongsi_idx)
                        if val is None or str(val).strip() == "":
                            filtered_rows += 1
                wb.release_resources()

            callname_col = _detect_column(columns, CALLNAME_POSSIBLE_CALLNAME_COLS)
            zpwina_col = _detect_column(columns, CALLNAME_POSSIBLE_ZPWINA_COLS)
            zpwino_col = _detect_column(columns, CALLNAME_POSSIBLE_ZPWINO_COLS)

            return {
                "total_rows": total_rows, "columns": columns,
                "callname_col": callname_col, "tongsi_col": tongsi_col,
                "zpwina_col": zpwina_col, "zpwino_col": zpwino_col,
                "filtered_rows": filtered_rows,
            }

        info = await asyncio.to_thread(_parse_lightweight)

        _callname_sessions[upload_id] = {
            "filename": filename,
            "s3_temp_key": s3_temp_key,
            "ext": ext,
            "status": "uploaded",
            "created_at_ts": _time_mod.time(),
            **info,
        }

        return {
            "upload_id": upload_id,
            "filename": filename,
            **info,
            "detected_callname_col": info["callname_col"],
            "detected_tongsi_col": info["tongsi_col"],
            "detected_zpwina_col": info["zpwina_col"],
            "detected_zpwino_col": info["zpwino_col"],
        }
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"호출명칭 Excel 업로드 실패: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")
    finally:
        try:
            os.remove(tmp_path)
        except Exception:
            pass


@app.post("/callname/upload/{upload_id}/column-values")
async def callname_column_values(upload_id: str, request: Request):
    """컬럼 고유값 조회 — S3에서 Excel 재로드 후 계산, 즉시 해제"""
    await _verify_auth(request)
    if upload_id not in _callname_sessions:
        raise HTTPException(status_code=404, detail="세션 없음")
    sess = _callname_sessions[upload_id]
    if sess.get("status") != "uploaded":
        raise HTTPException(status_code=400, detail="이미 처리 시작됨")

    body = await request.json()
    col = body.get("column")
    if not col or col not in sess.get("columns", []):
        raise HTTPException(status_code=400, detail=f"'{col}' 컬럼 없음")

    # 백그라운드 분석 완료 시 사전 계산된 통계 즉시 반환
    column_stats = sess.get("column_stats", {})
    if col in column_stats:
        return {"column": col, "values": column_stats[col]}

    # 분석 미완료 → S3에서 재로드 (소용량 파일 또는 fallback)
    def _calc():
        from collections import Counter
        columns = sess.get("columns", [])
        col_idx = columns.index(col) if col in columns else -1
        if col_idx < 0:
            return []

        cached_xlsx = sess.get("cached_xlsx_path")
        cached_ss = sess.get("cached_ss_path")
        cached_ss_off = sess.get("cached_ss_offsets")

        if cached_xlsx and os.path.exists(cached_xlsx):
            tmp_path = cached_xlsx
            need_cleanup = False
        else:
            tmp_path = _s3_to_tempfile(sess["s3_temp_key"], suffix=f".{sess['ext']}")
            need_cleanup = True
            cached_ss = None
            cached_ss_off = None
        try:
            counter = Counter()
            if sess["ext"] == "xlsx":
                for rn, vals in _iter_xlsx_rows_light(
                        tmp_path, ss_cache_path=cached_ss, ss_offsets_bytes=cached_ss_off):
                    if rn == 0:
                        continue
                    v = vals[col_idx] if col_idx < len(vals) else ""
                    if v:
                        counter[v] += 1
                _release_memory()
            else:
                xls_book = xlrd.open_workbook(tmp_path)
                ws = xls_book.sheet_by_index(0)
                for r in range(1, ws.nrows):
                    v = str(ws.cell_value(r, col_idx)) if col_idx < ws.ncols else ""
                    if v:
                        counter[v] += 1
                xls_book.release_resources()
            return [{"value": v, "count": c} for v, c in counter.most_common(100)]
        finally:
            if need_cleanup:
                try:
                    os.remove(tmp_path)
                except OSError:
                    pass

    values = await asyncio.to_thread(_calc)
    return {"column": col, "values": values}


@app.post("/callname/upload/{upload_id}/preview")
async def callname_preview(upload_id: str, request: Request):
    """필터 미리보기 — 분석 시 캐시된 tongsi 빈 행 데이터로 즉시 계산 (전행 스캔 불필요)"""
    await _verify_auth(request)
    if upload_id not in _callname_sessions:
        raise HTTPException(status_code=404, detail="세션 없음")
    sess = _callname_sessions[upload_id]
    if sess.get("status") != "uploaded":
        raise HTTPException(status_code=400, detail="이미 처리 시작됨")

    body = await request.json()
    filters = body.get("filters", {})
    callname_col = sess.get("callname_col")

    # 필터 없으면 사전 계산된 값 즉시 반환
    if not filters and sess.get("analysis_status") == "complete":
        return {
            "filtered_rows": sess.get("filtered_rows", 0),
            "target_callnames": sess.get("target_callnames", 0),
        }

    # 캐시된 tongsi 빈 행 데이터로 즉시 계산
    cached_rows = sess.get("filter_cache_rows")
    if cached_rows is not None:
        columns = sess.get("columns", [])
        callname_idx = columns.index(callname_col) if callname_col and callname_col in columns else -1

        # 필터 인덱스 빌드
        filter_col_indices = {}
        if filters:
            for c, vals in filters.items():
                if c in columns and vals:
                    filter_col_indices[columns.index(c)] = set(str(v) for v in vals)

        filtered_rows = 0
        callname_set = set()
        for row_vals in cached_rows:
            # 필터 조건 체크
            passed = True
            for ci, allowed in filter_col_indices.items():
                if ci < len(row_vals) and row_vals[ci] not in allowed:
                    passed = False
                    break
            if not passed:
                continue
            filtered_rows += 1
            if 0 <= callname_idx < len(row_vals) and row_vals[callname_idx].strip():
                callname_set.add(row_vals[callname_idx].strip())

        return {"filtered_rows": filtered_rows, "target_callnames": len(callname_set)}

    # 분석 미완료 시 기본값 반환
    return {
        "filtered_rows": sess.get("filtered_rows", 0),
        "target_callnames": sess.get("target_callnames", 0),
    }


@app.post("/callname/process")
async def callname_process(request: Request):
    """매칭 시작 — filter_cache_rows 캐시 활용 (Excel 재스캔 불필요, 즉시 완료)"""
    await _verify_auth(request)
    _check_rate_limit(request, "callname_process", 3, 60)

    body = await request.json()
    upload_id = body.get("upload_id")
    filters = body.get("filters", {})

    if not upload_id or upload_id not in _callname_sessions:
        raise HTTPException(status_code=404, detail="세션 없음")
    sess = _callname_sessions[upload_id]
    if sess.get("status") != "uploaded":
        raise HTTPException(status_code=400, detail="이미 처리 시작됨")

    zpwina_col = sess.get("zpwina_col")
    zpwino_col = sess.get("zpwino_col")

    if not zpwina_col and not zpwino_col:
        raise HTTPException(status_code=400, detail="zpwina/zpwino 컬럼 없음")

    columns = sess.get("columns", [])
    cached_rows = sess.get("filter_cache_rows")
    if cached_rows is None:
        raise HTTPException(status_code=400, detail="분석 미완료 — 잠시 후 다시 시도해주세요.")

    # 컬럼 인덱스 계산
    zpwina_idx = columns.index(zpwina_col) if zpwina_col and zpwina_col in columns else -1
    zpwino_idx = columns.index(zpwino_col) if zpwino_col and zpwino_col in columns else -1

    # 필터 인덱스
    filter_col_indices = {}
    if filters:
        for c, vals in filters.items():
            if c in columns and vals:
                filter_col_indices[columns.index(c)] = set(str(v) for v in vals)

    # filter_cache_rows + row_indices에서 즉시 추출 (Excel 재스캔 불필요)
    cached_row_indices = sess.get("filter_cache_row_indices", [])
    zpwina_set = set()
    zpwino_set = set()
    original_row_indices = []
    row_zpwina_list = []
    row_zpwino_list = []

    for i, row_vals in enumerate(cached_rows):
        # 사용자 필터 적용
        passed = True
        for ci, allowed in filter_col_indices.items():
            if ci < len(row_vals) and row_vals[ci] not in allowed:
                passed = False
                break
        if not passed:
            continue

        # 원본 Excel 행번호 (1-based)
        excel_row = cached_row_indices[i] if i < len(cached_row_indices) else (i + 2)
        original_row_indices.append(excel_row)
        za = row_vals[zpwina_idx] if 0 <= zpwina_idx < len(row_vals) else ""
        zo = row_vals[zpwino_idx] if 0 <= zpwino_idx < len(row_vals) else ""
        row_zpwina_list.append(za)
        row_zpwino_list.append(zo)
        if za:
            zpwina_set.add(za)
        if zo:
            zpwino_set.add(zo)

    _log_mem("callname_process 완료 (캐시 활용)")

    total_values = len(zpwina_set | zpwino_set)
    if total_values == 0:
        raise HTTPException(status_code=400, detail="매칭 대상 값이 없습니다.")

    process_id = str(uuid.uuid4())
    _callname_sessions[process_id] = {
        "s3_temp_key": sess["s3_temp_key"],
        "ext": sess["ext"],
        "original_row_indices": original_row_indices,
        "row_zpwina_list": row_zpwina_list,
        "row_zpwino_list": row_zpwino_list,
        "zpwina_col": zpwina_col,
        "zpwino_col": zpwino_col,
        "zpwina_values": list(zpwina_set),
        "zpwino_values": list(zpwino_set),
        "filename": sess["filename"],
        "columns": columns,
        "cached_xlsx_path": sess.get("cached_xlsx_path"),
        "status": "ready",
        "created_at_ts": _time_mod.time(),
    }
    # upload 세션 삭제 (filter_cache_rows 등 대용량 데이터 해제)
    del _callname_sessions[upload_id]
    _release_memory()

    return {
        "process_id": process_id,
        "total_values": total_values,
        "total_rows": len(row_zpwina_list),
    }


@app.get("/callname/process/{process_id}/stream")
async def callname_stream(process_id: str, request: Request):
    """SSE 스트리밍 — 메모리 최소 버전
    1) S3 CSV 스트리밍 6방향 매칭 → db_data dict
    2) 세션 저장 행별 값으로 row_data_map 생성 (Excel 재로드 없음)
    3) ZIP XML 512KB 청크 스트리밍 → S3 업로드
    피크 메모리: ~5MB (db_data + row_data_map + 512KB 버퍼)
    """
    await _verify_auth(request)
    _check_memory("호출명칭 매칭")
    if process_id not in _callname_sessions:
        raise HTTPException(status_code=404, detail="세션 없음")

    sess = _callname_sessions[process_id]

    def _generate():
        try:
            zpwina_values = sess["zpwina_values"]
            zpwino_values = sess["zpwino_values"]
            filename = sess["filename"]
            s3_temp_key = sess["s3_temp_key"]
            ext = sess["ext"]
            original_row_indices = sess.get("original_row_indices", [])

            total_values = len(set(zpwina_values + zpwino_values))
            total_rows = len(original_row_indices)

            _log_mem("stream 시작")
            yield f"data: {json.dumps({'type': 'progress', 'progress': 5, 'message': '파일 분석 완료', 'detail': f'{total_rows:,}행, {total_values:,}개 고유값'})}\n\n"

            # ── 1단계: DB 조회 ──
            _log_mem("1단계: DB 조회 시작")
            yield f"data: {json.dumps({'type': 'progress', 'progress': 10, 'message': 'DB 로드 + 6방향 교차 조회 중...'})}\n\n"

            db_data = _query_callname_db(zpwina_values, zpwino_values)
            db_count = len(db_data)
            _log_mem("1단계: DB 조회 완료")

            yield f"data: {json.dumps({'type': 'progress', 'progress': 40, 'message': 'DB 조회 완료', 'detail': f'{db_count:,}건 매칭됨'})}\n\n"

            # ── 2단계: 매칭 ──
            _log_mem("2단계: 매칭 시작")
            yield f"data: {json.dumps({'type': 'progress', 'progress': 45, 'message': '매칭 데이터 준비 중...'})}\n\n"

            columns = sess.get("columns", [])

            # DB 필드 → Excel 컬럼명 매핑
            db_fields = ["area_hdofc_nm", "ons_team_nm", "zpcode"]
            excel_col_map = {}
            for db_field, candidates in CALLNAME_DB_TO_EXCEL_MAP.items():
                detected = _detect_column(columns, candidates)
                excel_col_map[db_field] = detected if detected else candidates[0]
            target_excel_cols = [excel_col_map[f] for f in db_fields]

            # ── 세션 데이터로 row_data_map 직접 생성 (Excel 재로드 불필요) ──
            row_zpwina_list = sess.get("row_zpwina_list", [])
            row_zpwino_list = sess.get("row_zpwino_list", [])
            # 캐시된 xlsx가 있으면 재사용 (S3 재다운로드 방지)
            cached_xlsx = sess.get("cached_xlsx_path")
            if cached_xlsx and os.path.exists(cached_xlsx):
                tmp_excel_path = cached_xlsx
                _log_mem("2단계: 캐시된 xlsx 재사용")
            else:
                _log_mem("2단계: S3 temp 다운로드 시작")
                tmp_excel_path = _s3_to_tempfile(s3_temp_key, suffix=f".{ext}")
                _log_mem("2단계: S3 temp 다운로드 완료")

            matched_count = 0
            zpwina_matched = 0
            zpwino_matched = 0
            cross_matched = 0
            row_data_map = {}

            for i, row_idx in enumerate(original_row_indices):
                excel_row_num = row_idx  # 이미 1-based xlsx row number
                za = row_zpwina_list[i] if i < len(row_zpwina_list) else ""
                zo = row_zpwino_list[i] if i < len(row_zpwino_list) else ""
                hit = None
                if za:
                    hit = db_data.get(za)
                    if hit and hit.get("zpcode"):
                        row_data_map[excel_row_num] = [
                            hit.get("area_hdofc_nm", ""),
                            hit.get("ons_team_nm", ""),
                            hit.get("zpcode", ""),
                        ]
                        zpwina_matched += 1
                        continue
                if zo:
                    hit = db_data.get(zo)
                    if hit and hit.get("zpcode"):
                        row_data_map[excel_row_num] = [
                            hit.get("area_hdofc_nm", ""),
                            hit.get("ons_team_nm", ""),
                            hit.get("zpcode", ""),
                        ]
                        zpwino_matched += 1

            matched_count = len(row_data_map)
            del db_data, row_zpwina_list, row_zpwino_list
            _release_memory()
            _log_mem("2단계: 매칭 완료")

            yield f"data: {json.dumps({'type': 'progress', 'progress': 60, 'message': '매칭 완료', 'detail': f'{matched_count:,}/{total_rows:,}행 (zpwina:{zpwina_matched:,}, zpwino:{zpwino_matched:,})'})}\n\n"

            # ── 3단계: ZIP XML 행단위 처리 ──
            _log_mem("3단계: ZIP XML 시작")
            yield f"data: {json.dumps({'type': 'progress', 'progress': 65, 'message': 'Excel 파일 생성 중...'})}\n\n"

            # 임시 출력 파일
            tmp_output = _tempfile.NamedTemporaryFile(delete=False, suffix=".xlsx")
            tmp_output_path = tmp_output.name
            tmp_output.close()

            try:
                with zipfile.ZipFile(tmp_excel_path, "r") as zin:
                    sheet_files = [f for f in zin.namelist() if "worksheets/sheet" in f]
                    sheet_path = sheet_files[0] if sheet_files else "xl/worksheets/sheet1.xml"

                    # 컬럼 레터 계산 (헤더 파싱 불필요 — 이미 알고 있는 컬럼 순서 사용)
                    target_col_letters = []
                    for ecn in target_excel_cols:
                        if ecn in columns:
                            idx = columns.index(ecn) + 1
                            target_col_letters.append(get_column_letter(idx))
                        else:
                            target_col_letters.append(get_column_letter(len(columns) + 1 + len(target_col_letters)))

                    target_letters_set = set(target_col_letters)
                    cell_pattern = re.compile(r'(<c r="([A-Z]+)\d+"[^>]*(?:>.*?</c>|/>))', re.DOTALL)

                    # ── 시트 XML 청크 스트리밍 (메모리에 전체 로드하지 않음) ──
                    tmp_sheet = _tempfile.NamedTemporaryFile(delete=False, suffix=".xml", mode="w", encoding="utf-8")
                    tmp_sheet_path = tmp_sheet.name

                    with zin.open(sheet_path) as sheet_stream:
                        buffer = ""
                        CHUNK_SIZE = 512 * 1024  # 512KB
                        while True:
                            raw = sheet_stream.read(CHUNK_SIZE)
                            if not raw:
                                break
                            buffer += raw.decode("utf-8", errors="replace")

                            while "</row>" in buffer:
                                row_end = buffer.index("</row>") + 6
                                row_section = buffer[:row_end]
                                buffer = buffer[row_end:]

                                r_pos = row_section.find('<row r="')
                                if r_pos == -1:
                                    tmp_sheet.write(row_section)
                                    continue

                                r_start = r_pos + 8
                                r_end_q = row_section.index('"', r_start)
                                row_num = int(row_section[r_start:r_end_q])
                                vals = row_data_map.get(row_num)

                                if vals is None:
                                    tmp_sheet.write(row_section)
                                else:
                                    # </row> 제거 후 처리
                                    part = row_section[:-6]
                                    row_tag_start = part.find('<row r="')
                                    row_tag_end = part.index(">", row_tag_start) + 1
                                    before_row = part[:row_tag_start]
                                    row_tag = part[row_tag_start:row_tag_end]
                                    after_row_tag = part[row_tag_end:]

                                    cell_dict = {}
                                    for cell_match in cell_pattern.finditer(after_row_tag):
                                        full_cell = cell_match.group(1)
                                        cl = cell_match.group(2)
                                        if cl not in target_letters_set:
                                            cell_dict[cl] = full_cell

                                    for i, val in enumerate(vals):
                                        cl = target_col_letters[i]
                                        safe_val = str(val).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")
                                        if safe_val:
                                            cell_dict[cl] = f'<c r="{cl}{row_num}" t="inlineStr"><is><t>{safe_val}</t></is></c>'

                                    sorted_cells = sorted(cell_dict.items(),
                                        key=lambda x: openpyxl.utils.column_index_from_string(x[0]))
                                    tmp_sheet.write(before_row)
                                    tmp_sheet.write(row_tag)
                                    for _, xml in sorted_cells:
                                        tmp_sheet.write(xml)
                                    tmp_sheet.write("</row>")

                        # 마지막 잔여 (</sheetData></worksheet> 등)
                        if buffer:
                            tmp_sheet.write(buffer)

                    tmp_sheet.close()
                    del row_data_map
                    _release_memory()

                    _log_mem("3단계: XML 스트리밍 완료")
                    yield f"data: {json.dumps({'type': 'progress', 'progress': 85, 'message': 'ZIP 재조립 중...'})}\n\n"

                    # 새 ZIP 생성 (임시파일에, 청크 복사)
                    with zipfile.ZipFile(tmp_output_path, "w", zipfile.ZIP_DEFLATED, compresslevel=1) as zout:
                        for item in zin.infolist():
                            if item.filename == sheet_path:
                                zout.write(tmp_sheet_path, item.filename)
                            else:
                                with zin.open(item.filename) as src, zout.open(item, "w") as dst:
                                    while True:
                                        chunk = src.read(512 * 1024)
                                        if not chunk:
                                            break
                                        dst.write(chunk)

                # 임시 sheet XML 삭제
                try:
                    os.remove(tmp_sheet_path)
                except Exception:
                    pass
                _release_memory()

                _log_mem("4단계: ZIP 재조립 완료")
                yield f"data: {json.dumps({'type': 'progress', 'progress': 92, 'message': 'S3 업로드 중...'})}\n\n"

                # S3 업로드 (임시파일에서 스트리밍)
                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                base_name = filename.rsplit(".", 1)[0]
                output_filename = f"{base_name}_matched_{timestamp}.xlsx"
                s3_result_key = f"callname-results/{process_id}/{output_filename}"

                with open(tmp_output_path, "rb") as f:
                    get_s3_client().upload_fileobj(
                        f, S3_BUCKET_NAME, s3_result_key,
                        ExtraArgs={"ContentType": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
                    )

                sess["s3_result_key"] = s3_result_key
                sess["output_filename"] = output_filename
                sess["status"] = "completed"

                # ── 세션 무거운 데이터 즉시 해제 (다운로드에 필요한 것만 유지) ──
                for _drop_key in ("original_row_indices", "row_zpwina_list", "row_zpwino_list",
                                  "zpwina_values", "zpwino_values", "columns",
                                  "cached_xlsx_path", "column_stats", "cached_ss_offsets"):
                    sess.pop(_drop_key, None)

                yield f"data: {json.dumps({'type': 'complete', 'progress': 100, 'message': f'완료! (매칭: {matched_count:,}/{total_rows:,}건)', 'matched': matched_count, 'total': total_rows, 'zpwina_matched': zpwina_matched, 'zpwino_matched': zpwino_matched, 'cross_matched': cross_matched})}\n\n"

            finally:
                # 임시파일 정리
                for _p in [tmp_output_path, tmp_excel_path]:
                    try:
                        os.remove(_p)
                    except Exception:
                        pass
                _release_memory()
                _log_mem("stream 종료 (정리 완료)")

        except Exception as e:
            logger.exception(f"호출명칭 매칭 스트림 오류: {e}")
            try:
                os.remove(tmp_excel_path)
            except Exception:
                pass
            _release_memory()
            yield f"data: {json.dumps({'type': 'error', 'message': '서버 내부 오류'})}\n\n"

    return StreamingResponse(
        _generate(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/callname/process/{process_id}/download")
async def callname_download(process_id: str, request: Request):
    """매칭 결과 Excel 다운로드 (S3 presign URL)"""
    await _verify_auth(request)
    if process_id not in _callname_sessions:
        raise HTTPException(status_code=404, detail="세션 없음")

    data = _callname_sessions[process_id]
    if data.get("status") != "completed":
        raise HTTPException(status_code=400, detail="처리 미완료")

    s3_key = data.get("s3_result_key")
    output_filename = data.get("output_filename", "result.xlsx")

    if not s3_key:
        raise HTTPException(status_code=500, detail="결과 파일 없음")

    try:
        from urllib.parse import quote
        encoded_filename = quote(output_filename, safe="")
        url = get_s3_client().generate_presigned_url(
            "get_object",
            Params={
                "Bucket": S3_BUCKET_NAME,
                "Key": s3_key,
                "ResponseContentDisposition": f"attachment; filename*=UTF-8''{encoded_filename}",
            },
            ExpiresIn=600,
        )
        return {"url": url, "filename": output_filename}
    except Exception as e:
        logger.error(f"호출명칭 결과 다운로드 실패: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


# ============================================================
# 설치확인서 API
# ============================================================

# PDF/HWPX 생성 모듈 (optional import)
try:
    from pdf_generator import generate_certificate_pdf
    HAS_REPORTLAB = True
except ImportError:
    HAS_REPORTLAB = False

try:
    from hwp_generator import generate_certificate_hwp
    HAS_HWP_GEN = True
except ImportError:
    HAS_HWP_GEN = False

CERT_IMAGE_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.tiff', '.tif'}
CERT_BLUEPRINT_KEYWORDS = {'도면', 'blueprint', 'bp', 'design', '설계'}
CERT_PHOTO_KEYWORDS = {'사진', 'photo', 'pic', 'img', '현장'}
CERT_SESSION_TTL = 1800  # 30분
_cert_sessions: Dict[str, dict] = {}
_cert_batch_lock = asyncio.Lock()


def _cleanup_cert_sessions():
    now = _time_mod.time()
    expired = [k for k, v in _cert_sessions.items()
               if (now - v.get("ts", 0)) > CERT_SESSION_TTL]
    for k in expired:
        # S3 temp 정리
        prefix = _cert_sessions[k].get("s3_prefix")
        if prefix:
            try:
                resp = get_s3_client().list_objects_v2(
                    Bucket=S3_BUCKET_NAME, Prefix=prefix)
                for obj in resp.get("Contents", []):
                    get_s3_client().delete_object(
                        Bucket=S3_BUCKET_NAME, Key=obj["Key"])
            except Exception:
                pass
        del _cert_sessions[k]


def _cert_lookup_single(query: str) -> dict:
    """설치확인서 단건 조회 — 메모리 캐시 O(1)"""
    return _cert_lookup_cached(query)


def _cert_batch_lookup(zpwino_list: list) -> dict:
    """설치확인서 일괄 조회 — 메모리 캐시 O(1)"""
    return _cert_batch_lookup_cached(zpwino_list)


def _parse_photo_zip_to_s3(zip_path: str, job_id: str) -> dict:
    """ZIP에서 이미지 추출 → S3 cert-temp/{job_id}/ 에 개별 저장.
    Returns: {zpwino: {has_blueprint: bool, photo_count: int, photo_keys: [...], bp_key: str|None}}
    """
    s3_prefix = f"cert-temp/{job_id}/"
    summary = {}
    s3 = get_s3_client()

    with zipfile.ZipFile(zip_path, "r") as zf:
        for name in zf.namelist():
            if name.endswith("/"):
                continue
            basename = os.path.basename(name)
            if basename.startswith(".") or "__MACOSX" in name:
                continue
            ext = os.path.splitext(basename)[1].lower()
            if ext not in CERT_IMAGE_EXTENSIONS:
                continue

            fname_no_ext = os.path.splitext(basename)[0]
            parts = name.replace("\\", "/").split("/")

            zpwino = None
            is_blueprint = False
            photo_order = 0

            if len(parts) >= 2:
                folder = parts[-2]
                folder_digits = re.sub(r"[^0-9]", "", folder)
                if len(folder_digits) >= 5:
                    zpwino = folder_digits
                    fname_lower = fname_no_ext.lower()
                    if any(kw in fname_lower for kw in CERT_BLUEPRINT_KEYWORDS):
                        is_blueprint = True
                    else:
                        nums = re.findall(r"\d+", fname_no_ext)
                        photo_order = int(nums[-1]) if nums else 0

            if not zpwino:
                match = re.match(r"^(\d[\d\-]*\d)", fname_no_ext)
                if match:
                    zpwino = re.sub(r"[^0-9]", "", match.group(1))
                    remainder = fname_no_ext[match.end():].strip("_- ")
                    remainder_lower = remainder.lower()
                    if any(kw in remainder_lower for kw in CERT_BLUEPRINT_KEYWORDS):
                        is_blueprint = True
                    elif any(kw in remainder_lower for kw in CERT_PHOTO_KEYWORDS):
                        nums = re.findall(r"\d+", remainder)
                        photo_order = int(nums[0]) if nums else 0
                    elif not remainder:
                        is_blueprint = True
                    else:
                        nums = re.findall(r"\d+", remainder)
                        photo_order = int(nums[0]) if nums else 0

            if not zpwino or len(zpwino) < 5:
                continue

            if zpwino not in summary:
                summary[zpwino] = {
                    "has_blueprint": False, "photo_count": 0,
                    "bp_key": None, "photo_entries": [],
                }

            file_bytes = zf.read(name)
            if not file_bytes:
                continue

            if is_blueprint:
                s3_key = f"{s3_prefix}{zpwino}/blueprint{ext}"
                s3.put_object(Bucket=S3_BUCKET_NAME, Key=s3_key, Body=file_bytes)
                summary[zpwino]["has_blueprint"] = True
                summary[zpwino]["bp_key"] = s3_key
            else:
                if summary[zpwino]["photo_count"] < 6:
                    s3_key = f"{s3_prefix}{zpwino}/photo_{photo_order:03d}{ext}"
                    s3.put_object(Bucket=S3_BUCKET_NAME, Key=s3_key, Body=file_bytes)
                    summary[zpwino]["photo_entries"].append((photo_order, s3_key))
                    summary[zpwino]["photo_count"] += 1

            del file_bytes

    # 사진 정렬 + photo_keys 생성
    for zpwino in summary:
        entries = sorted(summary[zpwino]["photo_entries"], key=lambda x: x[0])
        summary[zpwino]["photo_keys"] = [k for _, k in entries[:6]]
        del summary[zpwino]["photo_entries"]

    return summary


def _decode_base64_image(data_url):
    if not data_url:
        return None
    try:
        if "," in data_url:
            data_url = data_url.split(",", 1)[1]
        return base64.b64decode(data_url)
    except Exception:
        return None


@app.post("/cert/lookup")
async def cert_lookup(request: Request):
    """허가번호/호출명칭으로 설치확인서용 DB 조회"""
    await _verify_auth(request)
    body = await request.json()
    query = str(body.get("query", "")).strip()
    if not query:
        raise HTTPException(status_code=400, detail="허가번호 또는 호출명칭을 입력하세요.")

    try:
        result = await asyncio.to_thread(_cert_lookup_single, query)
        if result:
            return {"found": True, **result}
        return {"found": False}
    except Exception as e:
        logger.error(f"설치확인서 조회 실패: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.post("/cert/generate")
async def cert_generate(request: Request):
    """개별 설치확인서 생성 (PDF 또는 HWPX)"""
    await _verify_auth(request)
    _check_memory("설치확인서 생성")
    body = await request.json()

    fmt = body.get("format", "pdf").lower()
    form_data = body.get("form_data", {})
    photos_b64 = body.get("photos", [])
    blueprint_b64 = body.get("blueprint")

    if fmt == "pdf" and not HAS_REPORTLAB:
        raise HTTPException(status_code=503, detail="서버에 reportlab이 설치되지 않았습니다.")
    if fmt == "hwpx" and not HAS_HWP_GEN:
        raise HTTPException(status_code=503, detail="HWPX 생성 모듈 로드 실패")

    try:
        photo_list = []
        for p in photos_b64[:8]:
            decoded = _decode_base64_image(p)
            if decoded:
                photo_list.append(decoded)

        blueprint_bytes = _decode_base64_image(blueprint_b64)

        if fmt == "hwpx":
            output = await asyncio.to_thread(
                generate_certificate_hwp, form_data,
                photo_list or None, blueprint_bytes)
            media = "application/hwp+zip"
            ext = "hwpx"
        else:
            output = await asyncio.to_thread(
                generate_certificate_pdf, form_data,
                photo_list or None, blueprint_bytes)
            media = "application/pdf"
            ext = "pdf"

        zpwino = form_data.get("zpwino", "certificate")
        filename = f"{zpwino}.{ext}"
        data = output.getvalue()
        del output, photo_list, blueprint_bytes

        from urllib.parse import quote
        filename_encoded = quote(filename, safe="")
        return StreamingResponse(
            iter([data]),
            media_type=media,
            headers={
                "Content-Disposition": f"attachment; filename*=UTF-8''{filename_encoded}",
                "Content-Length": str(len(data)),
            },
        )
    except Exception as e:
        logger.error(f"설치확인서 생성 실패: {e}")
        raise HTTPException(status_code=500, detail=f"생성 실패: {str(e)}")


@app.post("/cert/batch/lookup")
async def cert_batch_lookup(request: Request):
    """허가번호 목록 일괄 조회 (최대 500건)"""
    await _verify_auth(request)
    body = await request.json()
    zpwino_list = body.get("zpwino_list", [])
    zpwino_list = list(dict.fromkeys([str(z).strip().replace("-", "") for z in zpwino_list if str(z).strip()]))

    if not zpwino_list:
        raise HTTPException(status_code=400, detail="허가번호를 입력해주세요.")
    if len(zpwino_list) > 500:
        raise HTTPException(status_code=400, detail="한 번에 최대 500건까지 조회 가능합니다.")

    try:
        results = await asyncio.to_thread(_cert_batch_lookup, zpwino_list)

        items = []
        for z in zpwino_list:
            if z in results:
                items.append({"input_zpwino": z, "found": True, **results[z]})
            else:
                items.append({"input_zpwino": z, "found": False})

        found_count = sum(1 for it in items if it["found"])
        return {"total": len(items), "found": found_count,
                "not_found": len(items) - found_count, "items": items}
    except Exception as e:
        logger.error(f"일괄 조회 실패: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@app.post("/cert/batch/upload-photos")
async def cert_batch_upload_photos(request: Request, file: UploadFile = File(...)):
    """사진 ZIP 업로드 → 허가번호별 자동 매칭 → S3 temp 저장"""
    await _verify_auth(request)

    if not file.filename or not file.filename.lower().endswith(".zip"):
        raise HTTPException(status_code=400, detail="ZIP 파일만 가능합니다.")

    tmp_path = None
    try:
        # 디스크 임시 저장 (메모리 절약)
        with _tempfile.NamedTemporaryFile(delete=False, suffix=".zip") as tmp:
            tmp_path = tmp.name
            while True:
                chunk = await file.read(8 * 1024 * 1024)
                if not chunk:
                    break
                tmp.write(chunk)

        job_id = str(uuid.uuid4())
        summary = await asyncio.to_thread(_parse_photo_zip_to_s3, tmp_path, job_id)

        _cert_sessions[job_id] = {
            "type": "photos", "ts": _time_mod.time(),
            "s3_prefix": f"cert-temp/{job_id}/",
            "summary": summary,
        }

        # 클라이언트용 요약 (S3 키 제외)
        client_summary = {}
        for zpwino, data in summary.items():
            client_summary[zpwino] = {
                "has_blueprint": data["has_blueprint"],
                "photo_count": data["photo_count"],
            }

        return {
            "photo_job_id": job_id,
            "matched_count": len(summary),
            "summary": client_summary,
        }
    except zipfile.BadZipFile:
        raise HTTPException(status_code=400, detail="올바른 ZIP 파일이 아닙니다.")
    except Exception as e:
        logger.error(f"사진 ZIP 처리 실패: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


@app.post("/cert/batch/generate")
async def cert_batch_generate(request: Request):
    """일괄 설치확인서 생성 (SSE 스트리밍, PDF만)"""
    await _verify_auth(request)
    _check_memory("일괄 설치확인서 생성")
    if not HAS_REPORTLAB:
        raise HTTPException(status_code=503, detail="서버에 reportlab이 설치되지 않았습니다.")

    body = await request.json()
    items = body.get("items", [])
    common = body.get("common", {})
    photo_job_id = body.get("photo_job_id")

    if not items:
        raise HTTPException(status_code=400, detail="생성할 항목이 없습니다.")
    if len(items) > 500:
        raise HTTPException(status_code=400, detail="최대 500건까지 생성 가능합니다.")

    # 동시 일괄 생성 1건 제한
    if _cert_batch_lock.locked():
        raise HTTPException(status_code=429, detail="다른 일괄 생성이 진행 중입니다. 잠시 후 다시 시도하세요.")

    photo_summary = {}
    if photo_job_id and photo_job_id in _cert_sessions:
        photo_summary = _cert_sessions[photo_job_id].get("summary", {})

    installer_name = common.get("installer_name", "에스케이텔레콤 주식회사")
    sharing_type = common.get("sharing_type", "")
    antenna_frame_type = common.get("antenna_frame_type", "")
    antenna_count = common.get("antenna_count", 1)
    other_antenna_count = common.get("other_antenna_count", 0)
    co_installer_name = common.get("co_installer_name", "")
    co_zpwino_common = common.get("co_zpwino", "")
    date_str = common.get("date", datetime.now().strftime("%Y년 %m월 %d일"))

    async def stream():
        async with _cert_batch_lock:
            job_id = str(uuid.uuid4())
            tmp_dir = os.path.join(_tempfile.gettempdir(), f"cert_batch_{job_id}")
            os.makedirs(tmp_dir, exist_ok=True)
            s3 = get_s3_client()

            total = len(items)
            success_count = 0
            fail_count = 0
            pdf_files = []

            yield f"data: {json.dumps({'type': 'start', 'total': total, 'job_id': job_id})}\n\n"

            for idx, item in enumerate(items):
                zpwino = item.get("zpwino", "")
                zpwina = item.get("zpwina", "")

                try:
                    form_data = {
                        "zpwino": zpwino,
                        "zpwina": zpwina,
                        "zpwiadr": item.get("zpwiadr", ""),
                        "installer_name": installer_name,
                        "antenna_count": antenna_count,
                        "other_antenna_count": other_antenna_count,
                        "sharing_type": sharing_type,
                        "antenna_frame_type": item.get("antenna_frame_type") or item.get("zpirty3") or antenna_frame_type,
                        "co_installer_name": co_installer_name,
                        "co_zpwino": co_zpwino_common,
                        "remark": item.get("remark", ""),
                        "date": date_str,
                    }

                    photo_list = None
                    blueprint_bytes = None

                    # S3에서 사진 로드 (1건씩, 메모리 안전)
                    ps = photo_summary.get(zpwino)
                    if ps:
                        if ps.get("bp_key"):
                            try:
                                obj = s3.get_object(Bucket=S3_BUCKET_NAME, Key=ps["bp_key"])
                                blueprint_bytes = obj["Body"].read()
                            except Exception:
                                pass
                        if ps.get("photo_keys"):
                            photo_list = []
                            for pk in ps["photo_keys"]:
                                try:
                                    obj = s3.get_object(Bucket=S3_BUCKET_NAME, Key=pk)
                                    photo_list.append(obj["Body"].read())
                                except Exception:
                                    pass
                            if not photo_list:
                                photo_list = None

                    output = await asyncio.to_thread(
                        generate_certificate_pdf, form_data,
                        photo_list, blueprint_bytes)

                    filename = f"{zpwino}.pdf"
                    filepath = os.path.join(tmp_dir, filename)
                    with open(filepath, "wb") as f:
                        f.write(output.getvalue())
                    pdf_files.append((filename, filepath))
                    success_count += 1

                    del output, photo_list, blueprint_bytes

                    yield f"data: {json.dumps({'type': 'progress', 'current': idx + 1, 'total': total, 'zpwino': zpwino, 'status': 'success'})}\n\n"

                except Exception as e:
                    fail_count += 1
                    logger.warning(f"일괄 PDF 생성 실패 ({zpwino}): {e}")
                    yield f"data: {json.dumps({'type': 'progress', 'current': idx + 1, 'total': total, 'zpwino': zpwino, 'status': 'fail', 'error': str(e)})}\n\n"

            # ZIP 패키징 → S3 업로드
            result_s3_key = None
            if pdf_files:
                zip_path = os.path.join(_tempfile.gettempdir(), f"cert_batch_{job_id}.zip")
                with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
                    for fname, fpath in pdf_files:
                        zf.write(fpath, fname)

                result_s3_key = f"cert-results/{job_id}.zip"
                with open(zip_path, "rb") as f:
                    s3.put_object(Bucket=S3_BUCKET_NAME, Key=result_s3_key, Body=f)

                try:
                    os.unlink(zip_path)
                except OSError:
                    pass

            # 임시 디렉토리 정리
            import shutil
            shutil.rmtree(tmp_dir, ignore_errors=True)

            # 사진 S3 temp 정리
            if photo_job_id and photo_job_id in _cert_sessions:
                prefix = _cert_sessions[photo_job_id].get("s3_prefix")
                if prefix:
                    try:
                        resp = s3.list_objects_v2(Bucket=S3_BUCKET_NAME, Prefix=prefix)
                        for obj in resp.get("Contents", []):
                            s3.delete_object(Bucket=S3_BUCKET_NAME, Key=obj["Key"])
                    except Exception:
                        pass
                _cert_sessions.pop(photo_job_id, None)

            # 결과 세션 저장
            if result_s3_key:
                _cert_sessions[job_id] = {
                    "type": "result", "ts": _time_mod.time(),
                    "s3_result_key": result_s3_key,
                }

            yield f"data: {json.dumps({'type': 'complete', 'job_id': job_id, 'success': success_count, 'fail': fail_count, 'total': total})}\n\n"

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive",
                 "X-Accel-Buffering": "no"},
    )


@app.get("/cert/batch/download/{job_id}")
async def cert_batch_download(job_id: str, request: Request):
    """일괄 생성 결과 ZIP 다운로드 (S3 presigned URL)"""
    await _verify_auth(request)
    if job_id not in _cert_sessions:
        raise HTTPException(status_code=404, detail="세션을 찾을 수 없습니다.")

    sess = _cert_sessions[job_id]
    s3_key = sess.get("s3_result_key")
    if not s3_key:
        raise HTTPException(status_code=400, detail="결과 파일이 없습니다.")

    today = datetime.now().strftime("%Y%m%d")
    filename = f"설치확인서_{today}.zip"
    try:
        url = get_s3_client().generate_presigned_url(
            "get_object",
            Params={
                "Bucket": S3_BUCKET_NAME, "Key": s3_key,
                "ResponseContentDisposition": f"attachment; filename*=UTF-8''{filename}",
            },
            ExpiresIn=600,
        )
        return {"url": url, "filename": filename}
    except Exception as e:
        logger.error(f"일괄 다운로드 실패: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


# ============================================================
# ERP vs DS 전산자료 비교
# ============================================================

# ERP zpirty3 → DS 공중선주설치형태명 정규화 매핑
# DS 기준 14개 값: 철탑(지면), 강관주, 통신주, 원폴(건물), 옥내/터널/지하/차량,
#   쌍통신주, 기설물, 옥내외혼합형, 간이폴및비기준설치대, 한전주(KT통신주),
#   철탑(건물), 프레임, 복합형(원폴,분산프레임등), 모노폴
_TOWER_TYPE_NORMALIZE = {
    # ERP → DS (lowercase 키)
    "철탑(지면)": "철탑(지면)",
    "강관주": "강관주",
    "통신주(cp주)": "통신주",
    "통신주": "통신주",
    "원폴(건물)": "원폴(건물)",
    "옥내,터널,지하등": "옥내, 터널, 지하, 차량",
    "쌍통신주": "쌍통신주",
    "ip주": "기설물",
    "기설물": "기설물",
    "간이폴": "간이폴 및 비기준 설치대",
    "한전주(kt통신주)": "한전주(KT통신주)",
    "한전주": "한전주(KT통신주)",
    "철탑(건물)": "철탑(건물)",
    "프레임": "프레임",
    "환경친화형(확인필요)": "프레임",
    "환경친화형 프레임": "프레임",
    "환경친화형(건물)": "프레임",
    "환경친화형": "프레임",
    "분산폴": "복합형(원폴,분산프레임 등)",
    "모노폴": "모노폴",
    "기타": "기설물",
    # DS 값 자체 (이미 정규화된 경우)
    "옥내, 터널, 지하, 차량": "옥내, 터널, 지하, 차량",
    "옥내외 혼합형": "옥내외 혼합형",
    "간이폴 및 비기준 설치대": "간이폴 및 비기준 설치대",
    "복합형(원폴,분산프레임 등)": "복합형(원폴,분산프레임 등)",
}


def _normalize_tower(val: str) -> str:
    """철탑형태 문자열을 정규화하여 비교 가능하게 변환."""
    if not val:
        return ""
    v = val.strip().lower()
    return _TOWER_TYPE_NORMALIZE.get(v, v)


def _parse_serial_strings(s: str) -> list:
    """쉼표로 구분된 일련번호 문자열을 리스트로 변환."""
    if not s:
        return []
    return [x.strip().lower() for x in s.split(",") if x.strip()]


def _compare_values(erp_val: str, ds_val: str, normalize_fn=None) -> str:
    """ERP vs DS 값 비교. 일치/부분일치/불일치/확인필요 반환."""
    if not ds_val:
        return "확인필요"
    if not erp_val:
        return "확인필요"
    if normalize_fn:
        erp_parts = [normalize_fn(x.strip()) for x in erp_val.split(",") if x.strip()]
        ds_parts = [normalize_fn(x.strip()) for x in ds_val.split(",") if x.strip()]
    else:
        erp_parts = _parse_serial_strings(erp_val)
        ds_parts = _parse_serial_strings(ds_val)
    if not erp_parts or not ds_parts:
        return "확인필요"
    if set(erp_parts) == set(ds_parts) and len(erp_parts) == len(ds_parts):
        return "일치"
    elif set(erp_parts).intersection(ds_parts):
        return "부분일치"
    else:
        return "불일치"


# ── DS SQLite 캐시 (ZIP → SQLite 인덱스 조회) ────────────────
_ds_compare_cache = {}  # {cache_key: {"db_path": str, "ts": float}}
_ds_compare_cache_lock = threading.Lock()
DS_COMPARE_CACHE_TTL = 3600  # 1시간


def _get_ds_compare_cache_key(division_id: str, division_code: str, import_date: str) -> str:
    return f"{division_id}_{division_code}_{import_date}"


def _build_ds_compare_cache(
    zip_cache_path: str,
    file_manifest: dict,
    cache_key: str,
) -> tuple:
    """DS ZIP → SQLite DB 빌드. 장치/안테나 시트에서 허가번호+값 추출.
    Returns: (db_path, warnings)
    """
    import sqlite3
    warnings = []

    db_path = os.path.join(_tempfile.gettempdir(), f"ds_compare_{cache_key}.db")
    tmp_path = db_path + ".tmp"

    conn = sqlite3.connect(tmp_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=OFF")
    conn.execute("""CREATE TABLE IF NOT EXISTS ds_device (
        zpwino TEXT, serial_no TEXT
    )""")
    conn.execute("""CREATE TABLE IF NOT EXISTS ds_antenna (
        zpwino TEXT, tower_type TEXT
    )""")
    conn.execute("DELETE FROM ds_device")
    conn.execute("DELETE FROM ds_antenna")

    sheet_configs = {
        "장치": {
            "table": "ds_device",
            "sheet_candidates": ["장치"],
            "key_cols": ["허가번호"],
            "val_cols": ["기기일련번호"],
            "val_db_col": "serial_no",
        },
        "안테나": {
            "table": "ds_antenna",
            "sheet_candidates": ["안테나"],
            "key_cols": ["허가번호"],
            "val_cols": ["공중선주 설치형태명", "공중선주설치형태명"],
            "val_db_col": "tower_type",
        },
    }

    with zipfile.ZipFile(zip_cache_path, "r") as zf:
        for sheet_type, cfg in sheet_configs.items():
            manifest_entries = []
            matched_sheet_name = None
            for candidate in cfg["sheet_candidates"]:
                if candidate in file_manifest:
                    manifest_entries = file_manifest[candidate]
                    matched_sheet_name = candidate
                    break
            if not manifest_entries:
                for fm_key in file_manifest:
                    for candidate in cfg["sheet_candidates"]:
                        if candidate in fm_key:
                            manifest_entries = file_manifest[fm_key]
                            matched_sheet_name = fm_key
                            break
                    if manifest_entries:
                        break

            if not manifest_entries:
                warnings.append(f"DS 파일에 '{sheet_type}' 시트가 없습니다")
                continue

            batch = []
            for entry in manifest_entries:
                fname = entry["f"]
                xls_sheet_name = entry.get("orig", matched_sheet_name)
                try:
                    xls_bytes = zf.read(fname)
                    wb = xlrd.open_workbook(file_contents=xls_bytes)
                except Exception:
                    continue

                target_sheet = None
                for si in range(wb.nsheets):
                    s = wb.sheet_by_index(si)
                    if s.name.strip() == xls_sheet_name:
                        target_sheet = s
                        break

                if target_sheet is None or target_sheet.nrows < 2:
                    wb.release_resources()
                    del xls_bytes
                    continue

                header = []
                for col in range(target_sheet.ncols):
                    h = _xlrd_cell_to_str(target_sheet, 0, col)
                    header.append(h.strip() if h else "")

                key_col_idx = None
                for kc in cfg["key_cols"]:
                    for i, h in enumerate(header):
                        if h == kc:
                            key_col_idx = i
                            break
                    if key_col_idx is not None:
                        break

                val_col_idx = None
                for vc in cfg["val_cols"]:
                    for i, h in enumerate(header):
                        if h == vc:
                            val_col_idx = i
                            break
                    if val_col_idx is not None:
                        break

                if key_col_idx is None:
                    warnings.append(f"'{sheet_type}' 시트에 허가번호 컬럼이 없습니다 (헤더: {header[:10]})")
                    wb.release_resources()
                    del xls_bytes
                    continue
                if val_col_idx is None:
                    warnings.append(f"'{sheet_type}' 시트에 '{cfg['val_cols'][0]}' 컬럼이 없습니다")
                    wb.release_resources()
                    del xls_bytes
                    continue

                for row_i in range(1, target_sheet.nrows):
                    key_val = _xlrd_cell_to_str(target_sheet, row_i, key_col_idx)
                    if not key_val:
                        continue
                    cell_val = _xlrd_cell_to_str(target_sheet, row_i, val_col_idx) or ""
                    batch.append((key_val.strip(), cell_val.strip()))
                    if len(batch) >= 5000:
                        conn.executemany(f"INSERT INTO {cfg['table']} VALUES (?,?)", batch)
                        batch.clear()

                wb.release_resources()
                del xls_bytes

            if batch:
                conn.executemany(f"INSERT INTO {cfg['table']} VALUES (?,?)", batch)

    conn.execute("CREATE INDEX IF NOT EXISTS idx_device_zpwino ON ds_device(zpwino)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_antenna_zpwino ON ds_antenna(zpwino)")
    conn.commit()
    conn.close()

    if os.path.exists(db_path):
        try:
            os.remove(db_path)
        except Exception:
            pass
    os.rename(tmp_path, db_path)

    return db_path, warnings


def _get_ds_compare_db(
    zip_cache_path: str,
    file_manifest: dict,
    division_id: str,
    division_code: str,
    import_date: str,
) -> tuple:
    """DS 비교용 SQLite 캐시 반환. 없으면 빌드."""
    cache_key = _get_ds_compare_cache_key(division_id, division_code, import_date)
    now = _time_mod.time()

    cached = _ds_compare_cache.get(cache_key)
    if cached and os.path.exists(cached["db_path"]) and (now - cached["ts"]) < DS_COMPARE_CACHE_TTL:
        return cached["db_path"], []

    with _ds_compare_cache_lock:
        cached = _ds_compare_cache.get(cache_key)
        if cached and os.path.exists(cached["db_path"]) and (_time_mod.time() - cached["ts"]) < DS_COMPARE_CACHE_TTL:
            return cached["db_path"], []

        logger.info(f"DS 비교 SQLite 캐시 빌드: {cache_key}")
        t0 = _time_mod.time()
        db_path, warnings = _build_ds_compare_cache(zip_cache_path, file_manifest, cache_key)
        _ds_compare_cache[cache_key] = {"db_path": db_path, "ts": _time_mod.time()}
        logger.info(f"DS 비교 SQLite 캐시 빌드 완료: {_time_mod.time() - t0:.1f}초")
        return db_path, warnings


def _scan_ds_sheets_by_zpwino(
    zip_cache_path: str,
    file_manifest: dict,
    target_zpwinos: set,
    division_id: str = "",
    division_code: str = "",
    import_date: str = "",
) -> dict:
    """DS SQLite 캐시에서 허가번호 기준 배치 조회.
    첫 호출 시 ZIP → SQLite 빌드, 이후 인덱스 O(1) 조회.
    """
    import sqlite3
    BATCH = 900

    db_path, warnings = _get_ds_compare_db(
        zip_cache_path, file_manifest, division_id, division_code, import_date)

    result = {"장치": {}, "안테나": {}, "warnings": warnings}
    zpwino_list = list(target_zpwinos)

    try:
        conn = sqlite3.connect(db_path)
        conn.row_factory = sqlite3.Row

        # 장치: 허가번호별 일련번호 목록
        for i in range(0, len(zpwino_list), BATCH):
            batch = zpwino_list[i:i + BATCH]
            placeholders = ",".join("?" * len(batch))
            cur = conn.execute(
                f"SELECT zpwino, serial_no FROM ds_device WHERE zpwino IN ({placeholders})", batch)
            for row in cur.fetchall():
                z = row["zpwino"]
                sn = row["serial_no"]
                if z not in result["장치"]:
                    result["장치"][z] = []
                if sn and sn not in result["장치"][z]:
                    result["장치"][z].append(sn)

        # 안테나: 허가번호별 설치형태
        for i in range(0, len(zpwino_list), BATCH):
            batch = zpwino_list[i:i + BATCH]
            placeholders = ",".join("?" * len(batch))
            cur = conn.execute(
                f"SELECT zpwino, tower_type FROM ds_antenna WHERE zpwino IN ({placeholders})", batch)
            for row in cur.fetchall():
                z = row["zpwino"]
                if z not in result["안테나"]:
                    result["안테나"][z] = row["tower_type"] or ""

        conn.close()
    except Exception as e:
        logger.warning(f"DS 비교 캐시 조회 실패: {e}")
        result["warnings"].append(f"DS 캐시 조회 실패: {e}")

    return result


@app.post("/erp-ds/compare")
async def erp_ds_compare(request: Request):
    """ERP vs DS 전산자료 비교 (철탑형태 + 일련번호)
    입력: 허가번호, 호출명칭, 주소 혼합 가능 → 자동으로 허가번호 변환
    """
    await _verify_auth(request)
    body = await request.json()
    raw_list = body.get("zpwino_list", [])
    division_id = body.get("division_id", "")
    division_code = body.get("division_code", "")
    import_date = body.get("import_date", "")

    # 입력 정제 (하이픈 자동 제거, 중복 제거)
    raw_list = list(dict.fromkeys([str(z).strip() for z in raw_list if str(z).strip()]))
    if not raw_list:
        raise HTTPException(status_code=400, detail="검색어를 입력해주세요.")
    if len(raw_list) > 500:
        raise HTTPException(status_code=400, detail="한 번에 최대 500건까지 비교 가능합니다.")
    if not division_id or not import_date:
        raise HTTPException(status_code=400, detail="본부 및 DS 업로드 정보가 필요합니다.")

    try:
        # 호출명칭/주소 → 허가번호 변환
        zpwino_list, resolve_map = await asyncio.to_thread(_resolve_inputs_to_zpwino, raw_list)
        result = await asyncio.to_thread(
            _erp_ds_compare_sync, zpwino_list, division_id, division_code, import_date
        )
        # 원본 입력값 매핑 정보 추가
        result["resolve_map"] = resolve_map
        return result
    except Exception as e:
        logger.error(f"ERP-DS 비교 실패: {e}")
        raise HTTPException(status_code=500, detail=f"비교 처리 중 오류: {e}")


def _resolve_inputs_to_zpwino(raw_list: list) -> tuple:
    """입력값을 허가번호로 변환 (배치 최적화).
    - 숫자만 → 허가번호 (하이픈 제거)
    - 문자 포함 → 호출명칭/주소 배치 조회로 zpwino 변환

    Returns: (zpwino_list, resolve_map)
    """
    import sqlite3
    _cert_cache_load()

    zpwino_list = []
    resolve_map = {}
    text_inputs = []  # 숫자가 아닌 입력 (호출명칭/주소)

    # 1단계: 숫자/텍스트 분리
    for raw in raw_list:
        cleaned = raw.replace("-", "").strip()
        if cleaned.isdigit():
            if cleaned not in resolve_map:
                zpwino_list.append(cleaned)
                resolve_map[cleaned] = {"input": raw, "type": "허가번호"}
        else:
            text_inputs.append(raw)

    if not text_inputs:
        return zpwino_list, resolve_map

    # 2단계: 텍스트 입력 배치 조회 (WHERE IN)
    BATCH = 900
    try:
        conn = sqlite3.connect(_cert_cache_db_path)
        conn.row_factory = sqlite3.Row
        remaining = list(text_inputs)

        # 2a) 호출명칭 정확 매칭 (배치)
        unresolved = []
        for i in range(0, len(remaining), BATCH):
            batch = remaining[i:i + BATCH]
            placeholders = ",".join("?" * len(batch))
            cur = conn.execute(
                f"SELECT zpwino, zpwina FROM cert WHERE zpwina IN ({placeholders})", batch)
            found = {row["zpwina"]: row["zpwino"] for row in cur.fetchall()}
            for raw in batch:
                if raw in found and found[raw]:
                    zpwino = found[raw]
                    if zpwino not in resolve_map:
                        zpwino_list.append(zpwino)
                        resolve_map[zpwino] = {"input": raw, "type": "호출명칭"}
                else:
                    unresolved.append(raw)
        remaining = unresolved

        # 2b) 주소 정확 매칭 (배치)
        if remaining:
            unresolved = []
            for i in range(0, len(remaining), BATCH):
                batch = remaining[i:i + BATCH]
                placeholders = ",".join("?" * len(batch))
                cur = conn.execute(
                    f"SELECT zpwino, zpwiadr FROM cert WHERE zpwiadr IN ({placeholders})", batch)
                found = {row["zpwiadr"]: row["zpwino"] for row in cur.fetchall()}
                for raw in batch:
                    if raw in found and found[raw]:
                        zpwino = found[raw]
                        if zpwino not in resolve_map:
                            zpwino_list.append(zpwino)
                            resolve_map[zpwino] = {"input": raw, "type": "주소"}
                    else:
                        unresolved.append(raw)
            remaining = unresolved

        # 2c) 나머지: LIKE 부분 검색 (건별, 최소화됨)
        for raw in remaining:
            found_zpwino = None
            found_type = None
            # 호출명칭 부분
            cur = conn.execute("SELECT zpwino FROM cert WHERE zpwina LIKE ? LIMIT 1", (f"%{raw}%",))
            row = cur.fetchone()
            if row and row["zpwino"]:
                found_zpwino = row["zpwino"]
                found_type = "호출명칭(부분)"
            else:
                # 주소 부분
                cur = conn.execute("SELECT zpwino FROM cert WHERE zpwiadr LIKE ? LIMIT 1", (f"%{raw}%",))
                row = cur.fetchone()
                if row and row["zpwino"]:
                    found_zpwino = row["zpwino"]
                    found_type = "주소(부분)"

            if found_zpwino and found_zpwino not in resolve_map:
                zpwino_list.append(found_zpwino)
                resolve_map[found_zpwino] = {"input": raw, "type": found_type}
            elif not found_zpwino and raw not in resolve_map:
                zpwino_list.append(raw)
                resolve_map[raw] = {"input": raw, "type": "미확인"}

        conn.close()
    except Exception as e:
        logger.warning(f"입력값 변환 실패: {e}")
        for raw in text_inputs:
            if raw not in resolve_map:
                zpwino_list.append(raw)
                resolve_map[raw] = {"input": raw, "type": "미확인"}

    return zpwino_list, resolve_map


def _erp_ds_compare_sync(
    zpwino_list: list,
    division_id: str,
    division_code: str,
    import_date: str,
) -> dict:
    """ERP vs DS 비교 동기 처리."""
    import sqlite3

    # 1) ERP 데이터 조회
    erp_data = _cert_batch_lookup_cached(zpwino_list)

    # 2) DS ZIP 파일 확보
    zip_path = _get_cached_file(division_id, division_code, import_date, "zip")
    if not zip_path:
        s3_key = f"ds-raw/{division_id}/{division_code}_{import_date}.zip"
        cache_path = _get_cache_path(division_id, division_code, import_date, "zip")
        os.makedirs(os.path.dirname(cache_path), exist_ok=True)
        try:
            get_s3_client().download_file(S3_BUCKET_NAME, s3_key, cache_path)
            zip_path = cache_path
        except Exception as e:
            logger.warning(f"DS ZIP 다운로드 실패 ({s3_key}): {e}")
            # ZIP 없이 ERP 데이터만 반환
            items = []
            for z in zpwino_list:
                erp = erp_data.get(z)
                items.append({
                    "zpwino": z,
                    "zpwina": erp.get("zpwina", "") if erp else "",
                    "area_hdofc_nm": erp.get("area_hdofc_nm", "") if erp else "",
                    "erp_found": bool(erp),
                    "erp_zpirty3": erp.get("zpirty3", "") if erp else "",
                    "erp_serial": erp.get("eqp_ser_no", "") if erp else "",
                    "ds_tower_type": "",
                    "ds_serial": "",
                    "tower_match": "확인필요",
                    "serial_match": "확인필요",
                })
            return {
                "success": True, "total": len(items),
                "erp_found": sum(1 for it in items if it["erp_found"]),
                "ds_device_found": 0, "ds_antenna_found": 0,
                "warnings": [f"DS ZIP 파일을 찾을 수 없습니다: {s3_key}"],
                "summary": {"tower_match": 0, "tower_mismatch": 0, "tower_check": len(items),
                             "serial_match": 0, "serial_mismatch": 0, "serial_check": len(items)},
                "items": items,
            }

    # 3) DynamoDB에서 fileManifest 조회
    dynamodb = get_dynamodb_resource()
    uploads_table = dynamodb.Table(DYNAMODB_TABLES["ds_uploads"])
    upload_sk = f"{division_code}#{import_date}" if division_code else import_date
    resp = uploads_table.get_item(
        Key={"divisionId": division_id, "importDate": upload_sk},
        ProjectionExpression="fileManifest",
    )
    upload_rec = resp.get("Item")
    file_manifest = upload_rec.get("fileManifest", {}) if upload_rec else {}

    if not file_manifest:
        logger.warning(f"DS fileManifest 없음: {division_id}/{upload_sk}")

    # 4) DS 시트 스캔 (SQLite 캐시 활용)
    target_set = set(zpwino_list)
    ds_data = _scan_ds_sheets_by_zpwino(
        zip_path, file_manifest, target_set,
        division_id, division_code, import_date)

    ds_device = ds_data["장치"]    # {zpwino: [serial, ...]}
    ds_antenna = ds_data["안테나"]  # {zpwino: tower_type}
    warnings = ds_data["warnings"]

    # 5) 비교 결과 생성
    items = []
    summary = {
        "tower_match": 0, "tower_mismatch": 0, "tower_check": 0,
        "tower_partial": 0,
        "serial_match": 0, "serial_mismatch": 0, "serial_check": 0,
        "serial_partial": 0,
    }

    for z in zpwino_list:
        erp = erp_data.get(z)
        erp_zpirty3 = erp.get("zpirty3", "") if erp else ""
        erp_serial = erp.get("eqp_ser_no", "") if erp else ""
        ds_tower = ds_antenna.get(z, "")
        ds_serials = ds_device.get(z, [])
        ds_serial_str = ", ".join(ds_serials) if ds_serials else ""

        # 철탑형태 비교
        tower_result = _compare_values(erp_zpirty3, ds_tower, _normalize_tower)
        # 일련번호 비교
        serial_result = _compare_values(erp_serial, ds_serial_str)

        summary_key_map = {"일치": "match", "부분일치": "partial", "불일치": "mismatch", "확인필요": "check"}
        summary[f"tower_{summary_key_map.get(tower_result, 'check')}"] += 1
        summary[f"serial_{summary_key_map.get(serial_result, 'check')}"] += 1

        items.append({
            "zpwino": z,
            "zpwina": erp.get("zpwina", "") if erp else "",
            "area_hdofc_nm": erp.get("area_hdofc_nm", "") if erp else "",
            "erp_found": bool(erp),
            "erp_zpirty3": erp_zpirty3,
            "erp_serial": erp_serial,
            "ds_tower_type": ds_tower,
            "ds_serial": ds_serial_str,
            "tower_match": tower_result,
            "serial_match": serial_result,
        })

    return {
        "success": True,
        "total": len(items),
        "erp_found": sum(1 for it in items if it["erp_found"]),
        "ds_device_found": len(ds_device),
        "ds_antenna_found": len(ds_antenna),
        "warnings": warnings,
        "summary": summary,
        "items": items,
    }


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
