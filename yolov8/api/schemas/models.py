"""
models - 모든 Pydantic 요청/응답 스키마 정의

담당 도메인: API 입출력 데이터 타입
주요 의존성: pydantic만 (외부 라이브러리)
엔드포인트: 없음 (데이터 타입만 정의)
"""

from typing import List, Optional, Dict, Union
from pydantic import BaseModel


# ── YOLO 분류 스키마 ──────────────────────────────────────────

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


# ── 사용자/인증 스키마 ─────────────────────────────────────────

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


class OtpVerifyRequest(BaseModel):
    pre_auth_token: str
    otp: str


class OtpResendRequest(BaseModel):
    pre_auth_token: str
    password: str


class DevLoginRequest(BaseModel):
    empno: str
    name: str
    region: str  # "강남본부", "강북본부" 등
    team: str = ""
    role: str = "member"  # "admin", "manager", "member"


# ── 카테고리/스테이션 스키마 ─────────────────────────────────────

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


# ── S3 스키마 ──────────────────────────────────────────────────

class S3UploadResponse(BaseModel):
    success: bool
    key: str
    url: Optional[str] = None


class S3PresignedUrlResponse(BaseModel):
    success: bool
    url: str


# ── DS 업로드 스키마 ──────────────────────────────────────────

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


class BulkCancelReq(BaseModel):
    division_id: str
    import_date: str


# ── 검사 스케줄 스키마 ─────────────────────────────────────────

class InspectionEnqueueReq(BaseModel):
    s3Key: str
    year: int
    uploadedBy: str


class InspectionScheduleReq(BaseModel):
    year: int
    허가번호: str
    호출명칭: str
    분기: str
    skt본부: str
    access담당: str
    품질개선팀: str
    수검예정주차: str = ""
    수검시작일: str = ""
    수검종료일: str = ""
    지역: str = ""
    검사관: str = ""
    조: str = ""


class InspectionResultReq(BaseModel):
    year: int
    허가번호: str
    status: str  # 검사대기 | 합격 | 불합격
    검사일: str = ""
    메모: str = ""
    철탑형태: str = ""


class InspectionStationReq(BaseModel):
    year: int
    허가번호: str
    호출명칭: str = ""
    국종군: str = ""
    부서: str = ""
    분기: str = ""
    연도주기: str = ""
    검사주기: Optional[int] = None
    허가상태: str = "허가"
    설치장소: str = ""
    도로명주소: str = ""
    장치수: Optional[int] = None
    통시: str = ""
    공대: str = ""
    kca검토결과: str = ""
    시기조정: str = ""
    기준연도: Optional[int] = None
    skt본부: str = ""
    access담당: str = ""
    품질개선팀: str = ""


class InspStagingPreviewReq(BaseModel):
    year: int
    filters: dict = {}


class InspStagingConfirmReq(BaseModel):
    year: int
    filters: dict = {}


class InspStagingItemsReq(BaseModel):
    year: int
    filters: dict = {}
    offset: int = 0
    limit: int = 100


class PreCheckStatusReq(BaseModel):
    license_nos: list[str]
    status: str = "PRE_CHECKED"
    year: int = 0


class InspectionDataReq(BaseModel):
    year: int
    access담당: str = ""
    품질개선팀: str = ""
    분기: str = ""
    국종군: str = ""
    kca검토결과: str = ""
    시기조정: str = ""
    허가상태: str = ""
    skt본부: str = ""
    offset: int = 0
    limit: int = 100
    search: str = ""
    sort_by: str = ""
    sort_dir: str = "asc"
    columns: list[str] = []


class InspectionExportReq(BaseModel):
    year: int
    access담당: str = ""
    품질개선팀: str = ""
    분기: str = ""
    국종군: str = ""
    kca검토결과: str = ""
    시기조정: str = ""
    허가상태: str = ""
    skt본부: str = ""
    search: str = ""
    columns: list[str] = []


class InspectionExportAllReq(BaseModel):
    year: int
    columns: list[str] = []


class InspectionSummaryReq(BaseModel):
    year: int
    access담당: str = ""
    품질개선팀: str = ""


class WfTransitionReq(BaseModel):
    to_status: str
    memo: str = ""


class WfBulkTransitionReq(BaseModel):
    pks: list[str]
    to_status: str
    memo: str = ""


class WfNotificationReadReq(BaseModel):
    notification_ids: list[int] = []
    mark_all: bool = False


class PreCheckResultReq(BaseModel):
    result: str   # "PASS" 또는 "FAIL" 또는 "PARTIAL"
    memo: str = ""
    items: list[dict] = []


class ChangeRequestItem(BaseModel):
    field: str
    before_value: str = ""
    after_value: str
    장치번호: str = ""
    memo: str = ""


class ChangeRequestCreateReq(BaseModel):
    items: list[ChangeRequestItem]


class ChangeRequestDirectReq(BaseModel):
    허가번호: str
    items: list[ChangeRequestItem]


class ChangeRequestFileReq(BaseModel):
    schedule_pk: str = ""
    schedule_pks: list[str] = []
    memo: str = ""


class InspectionReportReq(BaseModel):
    year: int
    허가번호: str
    format: str = "xlsx"


class InspectionReportGenerateReq(BaseModel):
    year: int
    허가번호: str


class InspectionSubmissionReq(BaseModel):
    submitted: bool
    memo: str = ""


class InspectionSubmissionBulkReq(BaseModel):
    pks: list[str]
    submitted: bool
    memo: str = ""


class InspAddFromStagingReq(BaseModel):
    year: int
    허가번호들: list[str]
    overwrite: bool = False


# ── 실적 결과 스키마 ───────────────────────────────────────────

class InspectionResultsExportReq(BaseModel):
    year: int
    본부: Union[str, List[str]] = ""
    진행여부: str = ""
    status: str = ""
    성능서류: str = ""
    주차별: Union[str, List[str]] = ""


# ── 커뮤니티 스키마 ──────────────────────────────────────────

class NoticeCreate(BaseModel):
    title: str
    content: str
    division: str = "전체"
    images: list = []
    attachments: list = []


class NoticeUpdate(BaseModel):
    title: str
    content: str
    division: str = "전체"
    images: list = []
    attachments: list = []


class RequestCreate(BaseModel):
    title: str
    content: str
    is_secret: bool = False
    secret_password: str = ''
    images: list = []


class RequestUpdate(BaseModel):
    title: str
    content: str
    images: list = []


class RequestStatusUpdate(BaseModel):
    status: str


class CommentCreate(BaseModel):
    content: str
    parent_id: int | None = None


class CommentUpdate(BaseModel):
    content: str


# ── 부적합 스키마 ──────────────────────────────────────────────

class InadequateUpdateReq(BaseModel):
    id: int
    status: str = ""  # 완료/미완료/대상제외
    심의차수: str = ""


class CoLocatedCheckReq(BaseModel):
    year: int
    licenses: list[str]


class SpecialSiteLicensesReq(BaseModel):
    licenses: list[str]


class SpecialSiteBulkReq(BaseModel):
    licenses: list[str]
    유형: str  # 지하철/터널/야간출입/기타
    메모: str = ""


class SpecialSiteImportItem(BaseModel):
    허가번호: str
    유형: str
    메모: str = ""
    등록자: str = ""
    등록일시: str = ""


class SpecialSiteImportReq(BaseModel):
    items: list[SpecialSiteImportItem]
    hdqt: str = ""  # 본부 범위 동기화 ('' = 전체 교체, admin 전용)
    actor: str = ""  # sync-ingest 경로에서 kca측 전송자 표기 (감사 로그용)


class MappingOverrideReq(BaseModel):
    year: int
    허가번호: str
    field: str        # 'access담당' | '품질개선팀'
    value: str
    reason: str = ""
