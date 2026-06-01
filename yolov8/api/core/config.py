"""
config - 환경변수 및 전역 상수 모음

담당 도메인: 서버 전체 설정
주요 의존성: 없음 (최상위 레이어)
엔드포인트: 없음

주의사항:
- 모든 시크릿은 os.environ.get()으로만 로드, 코드 하드코딩 금지
- IS_PROD 판별 후 AUTH_TOKEN_SECRET 미설정 시 RuntimeError 발생 (운영 fail-closed)
"""

import os
import uuid
import logging
from pathlib import Path

logger = logging.getLogger(__name__)

# ── 앱 환경 ─────────────────────────────────────────────────
APP_ENV = os.environ.get("APP_ENV", "production").lower()
IS_PROD = APP_ENV in ("production", "prod")

# ── YOLO 모델 경로 ───────────────────────────────────────────
MODEL_PATH = os.getenv(
    "MODEL_PATH",
    "C:/Users/user/Desktop/26/ksa/yolov8/runs/classify/tower_classifier/weights/best.pt"
)

# ── 파일 업로드 임시 디렉토리 ─────────────────────────────────
UPLOAD_DIR = Path("temp_uploads")
UPLOAD_DIR.mkdir(exist_ok=True)

# ── 허용 이미지 확장자 ─────────────────────────────────────────
ALLOWED_EXTENSIONS = {".jpg", ".jpeg", ".png", ".bmp", ".webp"}

# ── S3 설정 ──────────────────────────────────────────────────
S3_BUCKET_NAME = os.getenv("S3_BUCKET_NAME", "sko-kca-s3")
S3_REGION = os.getenv("AWS_REGION", "ap-northeast-2")

# ── 파일 크기 제한 ────────────────────────────────────────────
MAX_PHOTO_SIZE = 10 * 1024 * 1024    # 10MB
MAX_EXCEL_SIZE = 50 * 1024 * 1024    # 50MB
MAX_DS_UPLOAD_SIZE = 200 * 1024 * 1024  # 200MB

# ── S3 허용 prefix ────────────────────────────────────────────
ALLOWED_S3_READ_PREFIXES = ("photos/", "excel/", "feedback/", "ds-exports/", "ds-raw/")
ALLOWED_S3_DELETE_PREFIXES = ("photos/", "excel/", "feedback/")

# ── DynamoDB 테이블명 ─────────────────────────────────────────
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
    "route_baskets": os.getenv("DYNAMODB_ROUTE_BASKETS_TABLE", "kca-route-baskets"),
}

# ── 외부 API 키 ───────────────────────────────────────────────
KAKAO_REST_KEY     = os.environ.get("KAKAO_REST_KEY", "")
VWORLD_API_KEY     = os.environ.get("VWORLD_API_KEY", "")
NAVER_CLIENT_ID    = os.environ.get("NAVER_CLIENT_ID", "")
NAVER_CLIENT_SECRET = os.environ.get("NAVER_CLIENT_SECRET", "")

for _envname, _envval in (
    ("KAKAO_REST_KEY", KAKAO_REST_KEY),
    ("VWORLD_API_KEY", VWORLD_API_KEY),
    ("NAVER_CLIENT_ID", NAVER_CLIENT_ID),
    ("NAVER_CLIENT_SECRET", NAVER_CLIENT_SECRET),
):
    if not _envval:
        logger.warning(f"{_envname} 환경변수 미설정 — 해당 외부 API 기능이 동작하지 않습니다")

# ── SSO 로그인 URL ────────────────────────────────────────────
# 인프라 측 SSO 도메인 마이그레이션 중(auth2.skons.net → auth.skons.net) 으로
# systemd Environment 로 덮어쓸 수 있게 환경변수 우선. 현재 운영은 auth2 가 실서비스.
SSO_LOGIN_URL = os.environ.get(
    "SSO_LOGIN_URL",
    "https://auth2.skons.net/accounts/sko/sso/login/",
)
logger.info(f"SSO_LOGIN_URL = {SSO_LOGIN_URL}")

# ── 부트스트랩 키 ─────────────────────────────────────────────
ADMIN_BOOTSTRAP_KEY = os.environ.get("ADMIN_BOOTSTRAP_KEY")

# ── 개발용 로그인 ─────────────────────────────────────────────
DEV_LOGIN_ENABLED = os.environ.get("DEV_LOGIN_ENABLED", "0") == "1"

# ── 역할 유효값 ──────────────────────────────────────────────
VALID_ROLES = {"admin", "manager", "member"}

# ── 인증 토큰 시크릿 ─────────────────────────────────────────
_is_prod_for_secret = os.environ.get("APP_ENV", "production").lower() in ("production", "prod")
_raw_token_secret = os.environ.get("AUTH_TOKEN_SECRET")
if _raw_token_secret:
    AUTH_TOKEN_SECRET = _raw_token_secret
else:
    if _is_prod_for_secret:
        raise RuntimeError(
            "AUTH_TOKEN_SECRET 환경변수가 필수입니다. "
            "/etc/systemd/system/kca-api.service 의 [Service] 에 "
            "Environment=AUTH_TOKEN_SECRET=<32+ 글자 시크릿> 을 추가하세요."
        )
    AUTH_TOKEN_SECRET = f"dev-fallback-{uuid.uuid4().hex}"
    logger.warning("AUTH_TOKEN_SECRET 환경변수 미설정 — 개발용 임시 키 사용 중")

AUTH_TOKEN_EXPIRY = 1 * 3600  # 1시간

# ── PBKDF2 설정 ──────────────────────────────────────────────
_PBKDF2_ITER = 200_000

# ── CORS 설정 ─────────────────────────────────────────────────
_cors_env = os.environ.get("CORS_ALLOWED_ORIGINS", "")
ALLOWED_ORIGINS = [x.strip() for x in _cors_env.split(",") if x.strip()]
if not ALLOWED_ORIGINS:
    logger.warning("CORS_ALLOWED_ORIGINS 환경변수 미설정 — 기본 도메인만 허용")
    ALLOWED_ORIGINS = [
        "http://localhost:3000",
        "http://localhost:8080",
        "https://playground.idcube.sktelecom.com",
    ]

# ── 프록시 신뢰 설정 ──────────────────────────────────────────
_TRUST_PROXY = os.environ.get("TRUST_PROXY", "0") == "1"

# ── 메모리 임계치 ─────────────────────────────────────────────
MEMORY_THRESHOLD_PCT = 80

# ── SQLite DB 파일 경로 ───────────────────────────────────────
_BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_INSP_DB = os.path.join(_BASE_DIR, "inspection.db")
_DS_DETAIL_DB = os.path.join(_BASE_DIR, "ds_detail.db")
_COMMUNITY_DB = os.path.join(_BASE_DIR, "community.db")
_SISL_PHOTO_DB = os.path.join(_BASE_DIR, "sisl_photo.db")

# ── 사용자 데이터 파일 경로 ────────────────────────────────────
USERS_DATA_PATH = os.getenv("USERS_DATA_PATH", "data/users.json")

# ── 호출명칭 설정 ─────────────────────────────────────────────
CALLNAME_CSV_PREFIX = "callname-db/"
CALLNAME_CACHE_TTL = 86400   # 24시간
CALLNAME_SESSION_TTL = 1800  # 30분
CALLNAME_MAX_SESSIONS = 3

CALLNAME_USE_COLS = [
    "zpwina", "zpwino", "zpwiadr", "zpcode", "zpkcode", "zpcname",
    "area_hdofc_nm", "ons_team_nm", "zpirty3", "eqp_ser_no",
    "zpprac1", "eqp_type", "max_seqno", "zpannu1", "swing_list"
]

# ── DS 지역 코드 매핑 ─────────────────────────────────────────
DS_REGION_CODE_MAP = {
    "10": {"divisionId": "sudogwon", "divisionName": "수도권"},
    "20": {"divisionId": "gyeongnam", "divisionName": "경남본부"},
    "26": {"divisionId": "gyeongnam", "divisionName": "경남본부"},
    "30": {"divisionId": "seobu", "divisionName": "서부본부"},
    "40": {"divisionId": "gangwon", "divisionName": "강원본부"},
    "50": {"divisionId": "chungcheong", "divisionName": "충청본부"},
    "55": {"divisionId": "chungcheong", "divisionName": "충청본부"},
    "60": {"divisionId": "gyeongbuk", "divisionName": "경북본부"},
    "70": {"divisionId": "seobu", "divisionName": "서부본부"},
    "80": {"divisionId": "seobu", "divisionName": "서부본부"},
}

DS_MERGED_CODES = {"70": "30", "55": "50", "26": "20", "80": "30"}
DS_PARTNER_CODES = {"30": ["70", "80"], "50": ["55"], "20": ["26"]}

# ── 수도권 본부 S3 키 매핑 ────────────────────────────────────
_HDQT_S3_KEY: dict = {
    '강남': 'gangnam', '강북': 'gangbuk', '경기': 'gyeonggi', '인천': 'incheon'
}

# ── access담당 → divisionId 매핑 ────────────────────────────
_ACCESS_TO_DIVISION: dict = {
    '강남': 'sudogwon', '강북': 'sudogwon', '경기': 'sudogwon', '인천': 'sudogwon',
    '강원': 'gangwon', '충청': 'chungcheong', '경북': 'gyeongbuk',
    '경남': 'gyeongnam', '서부': 'seobu',
}

# divisionId → access담당 목록 역방향 맵
_DIVISION_TO_ACCESS_LIST: dict = {}
for _acc, _div in _ACCESS_TO_DIVISION.items():
    _DIVISION_TO_ACCESS_LIST.setdefault(_div, []).append(_acc)

# ── 설치확인서 캐시 TTL ────────────────────────────────────────
CERT_CACHE_TTL = 86400  # 24시간

# ── DS 로컬 xlsx 캐시 ────────────────────────────────────────
DS_CACHE_DIR = "/tmp/ds_cache"
DS_CACHE_TTL = 3600  # 1시간

# ── YOLO 클래스 이름 매핑 ─────────────────────────────────────
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

# ── 검사 관련 설정 ────────────────────────────────────────────
INSPECTION_S3_PREFIX = "inspection/raw/"

# ── SQLite 백업 설정 ──────────────────────────────────────────
_SQLITE_BACKUP_RETAIN_DAYS = 7

# ── 관리자 캐시 TTL ───────────────────────────────────────────
ADMIN_USERS_CACHE_TTL = 60  # seconds
