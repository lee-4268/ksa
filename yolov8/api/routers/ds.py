"""
ds - DS(데이터서비스) 업로드/조회/내보내기/잡 관리 엔드포인트

담당 도메인: DS 데이터 CRUD, S3 xlsx 빌드, 잡 큐, 변경이력, 부분 업데이트
주요 의존성: core.auth, core.config, core.db, core.utils
엔드포인트:
    GET  /ds/region-codes
    GET  /ds/upload-presign, /ds/xlsx-upload-presign, /ds/export-presign
    GET  /ds/xlsx-build-status, /ds/xlsx-build-status-bulk, /ds/city-hdqt-map
    GET  /ds/proxy-xlsx, /ds/proxy-raw-zip
    POST /ds/upload-init, /ds/upload-chunk, /ds/upload-finalize
    GET  /ds/stats, /ds/export, /ds/data
    DELETE /ds/data
    GET  /ds/presign-raw
    POST /ds/upload-raw, /ds/upload-temp
    POST /ds/enqueue, /ds/enqueue-multi, /ds/trigger-xlsx-build
    GET  /ds/export-xlsx
    GET  /ds/job/{job_id}
    DELETE /ds/job/{job_id}
    POST /ds/preview-partial-update, /ds/apply-partial-update
    GET  /ds/변경이력-count, /ds/change-history, /ds/change-history/uploads
    POST /ds/change-history/bulk-cancel
    POST /ds/change-history/{history_id}/cancel

주의사항:
- DS xlsx 빌드는 서브프로세스 + asyncio 태스크로 메모리 격리
- _scan_missing_xlsx_caches_sync / _job_worker_loop / _ensure_ds_jobs_table 은
  main.py startup_event에서 create_task로 실행 → 외부 노출 함수 get_ds_startup_tasks() 제공
- _dynamodb_resource 직접 참조는 전부 get_dynamodb_resource() 로 교체됨
"""

import asyncio
import gc
import io
import json
import logging
import multiprocessing
import os
import re
import shutil
import sqlite3
import struct
import threading
import time as _time_mod
import uuid
import zipfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Dict, List, Optional
from urllib.parse import quote

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError
from fastapi import APIRouter, BackgroundTasks, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import JSONResponse, Response, StreamingResponse

from core.auth import (
    _verify_auth,
    _verify_token,
    _get_user_role_sync,
    _require_role,
    _check_division_access,
    _caller_allowed_access_list,
    _record_audit_log_sync,
)
from core.config import (
    S3_BUCKET_NAME,
    S3_REGION,
    DYNAMODB_TABLES,
    DS_REGION_CODE_MAP,
    DS_MERGED_CODES,
    DS_PARTNER_CODES,
    _HDQT_S3_KEY,
    DS_CACHE_DIR,
    DS_CACHE_TTL,
    MAX_DS_UPLOAD_SIZE,
    ALLOWED_S3_READ_PREFIXES,
    _INSP_DB,
    _DS_DETAIL_DB,
)
from botocore.config import Config as _BotoConfig
from core.db import get_s3_client, get_dynamodb_resource, get_dynamodb_client
from core.s3 import _validate_s3_key
import core.cert_cache as _cert_cache_mod
from core.utils import _check_memory, _log_mem, _release_memory, decimal_to_native
from pydantic import BaseModel
from schemas.models import (
    DsUploadInit, DsUploadChunk, DsUploadFinalize,
    DsEnqueueRequest, DsEnqueueMultiRequest,
)

try:
    import psutil
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False

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

router = APIRouter(tags=["ds"])
logger = logging.getLogger(__name__)

# ── DS xlsx 빌드 상태 ────────────────────────────────────────
_xlsx_build_queue: list = []
_xlsx_build_task = None
_xlsx_build_current = None
_xlsx_build_cancel_event = None
_xlsx_build_process = None

# ── DS 잡 워커 상태 ──────────────────────────────────────────
_ds_job_worker_task = None

# ============================================================
# DS Data Upload/Query Endpoints
# ============================================================

@router.get("/ds/region-codes")
async def ds_region_codes():
    """DS 지역코드 매핑 조회"""
    return {"success": True, "codes": DS_REGION_CODE_MAP}


# ============================================================
# DS S3 xlsx 로컬 캐시 — /ds/data 조회 시 반복 S3 다운로드 방지
# ============================================================


def _get_cache_path(division_id: str, division_code: str, import_date: str, ext: str = "xlsx") -> str:
    """캐시 파일 경로 반환 (ext: 'xlsx' 또는 'zip')"""
    return os.path.join(DS_CACHE_DIR, division_id, f"{division_code}_{import_date}.{ext}")


def _get_cached_file(division_id: str, division_code: str, import_date: str, ext: str = "xlsx") -> Optional[str]:
    """TTL 내 캐시 파일 존재하면 경로 반환, 아니면 None"""
    path = _get_cache_path(division_id, division_code, import_date, ext)
    if os.path.exists(path):
        import time
        age = _time_mod.time() - os.path.getmtime(path)
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
        jobs_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_jobs"])
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
    jobs_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_jobs"])
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
    jobs_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_jobs"])
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
    jobs_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_jobs"])
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
        jobs_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_jobs"])
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
        jobs_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_jobs"])

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

    with zipfile.ZipFile(merged_path, "w", zipfile.ZIP_DEFLATED) as out_zip:
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
                progress_cb(f"데이터 분석 중... ({file_idx+1}/{total_files}개 파일)", pct)

            # 디스크 기반 추출 (메모리 절약)
            xls_tmp_path = f"/tmp/ds_xls_meta_{id(zf)}_{file_idx}.xls"
            try:
                with zf.open(fname) as src, open(xls_tmp_path, "wb") as dst:
                    shutil.copyfileobj(src, dst)
            except Exception as e:
                logger.warning(f"DS metadata: {fname} 읽기 실패: {e}")
                if os.path.exists(xls_tmp_path):
                    os.remove(xls_tmp_path)
                continue

            try:
                try:
                    workbook = xlrd.open_workbook(xls_tmp_path, on_demand=True)
                except Exception:
                    workbook = xlrd.open_workbook(xls_tmp_path, on_demand=True, ignore_workbook_corruption=True)
            except Exception as e:
                logger.warning(f"DS metadata: XLS 파싱 실패 ({base_fname}): {e}")
                os.remove(xls_tmp_path)
                continue

            file_rows = 0
            for sheet_idx in range(workbook.nsheets):
                sheet = workbook.sheet_by_index(sheet_idx)
                orig_sheet_name = sheet.name.strip()
                if sheet.nrows < 2:
                    workbook.unload_sheet(sheet_idx)
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
                workbook.unload_sheet(sheet_idx)

            workbook.release_resources()
            del workbook
            try:
                os.remove(xls_tmp_path)
            except Exception:
                pass
            total_rows += file_rows
            _release_memory()

    logger.info(f"DS metadata parse 완료: {total_rows}행, {len(sheet_stats)}시트")
    return sheet_stats, total_rows, sheet_headers, file_manifest


def _subprocess_metadata_entry(zip_path: str, result_path: str, job_id: str = None):
    """서브프로세스 진입점: ZIP 메타데이터 파싱 후 결과를 JSON으로 저장.
    프로세스 exit → OS가 메모리 100% 회수.
    """
    import json, traceback

    progress_cb = None
    if job_id:
        def progress_cb(stage, pct):
            try:
                _update_job_progress_sync(job_id, stage, pct)
            except Exception:
                pass

    try:
        sheet_stats, total_rows, sheet_headers, file_manifest = \
            _parse_zip_metadata_sync(zip_path, progress_cb)
        out = {
            "success": True,
            "sheet_stats": sheet_stats,
            "total_rows": total_rows,
            "sheet_headers": sheet_headers,
            "file_manifest": file_manifest,
        }
    except Exception as e:
        out = {"success": False, "error": str(e),
               "traceback": traceback.format_exc()}
    try:
        with open(result_path, "w") as f:
            json.dump(out, f)
    except Exception:
        pass


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
                _pag_tmp = f"/tmp/ds_xls_pag_{id(zf)}_{global_row_idx}.xls"
                try:
                    with zf.open(fname) as _src, open(_pag_tmp, "wb") as _dst:
                        shutil.copyfileobj(_src, _dst)
                    try:
                        wb = xlrd.open_workbook(_pag_tmp, on_demand=True)
                    except Exception:
                        wb = xlrd.open_workbook(_pag_tmp, on_demand=True, ignore_workbook_corruption=True)
                except Exception:
                    global_row_idx += entry["r"]
                    if os.path.exists(_pag_tmp): os.remove(_pag_tmp)
                    continue

                target_sheet = None
                for si in range(wb.nsheets):
                    s = wb.sheet_by_index(si)
                    if s.name.strip() == xls_sheet_name:
                        target_sheet = s
                        break
                    wb.unload_sheet(si)

                if target_sheet is None or target_sheet.nrows < 2:
                    wb.release_resources()
                    if os.path.exists(_pag_tmp): os.remove(_pag_tmp)
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
                                if os.path.exists(_pag_tmp): os.remove(_pag_tmp)
                                break
                        scanned += 1
                    global_row_idx += 1

                wb.release_resources()
                if os.path.exists(_pag_tmp): os.remove(_pag_tmp)

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

                _pag_tmp2 = f"/tmp/ds_xls_pag2_{id(zf)}_{global_row_idx}.xls"
                try:
                    with zf.open(fname) as _src, open(_pag_tmp2, "wb") as _dst:
                        shutil.copyfileobj(_src, _dst)
                    try:
                        wb = xlrd.open_workbook(_pag_tmp2, on_demand=True)
                    except Exception:
                        wb = xlrd.open_workbook(_pag_tmp2, on_demand=True, ignore_workbook_corruption=True)
                except Exception:
                    global_row_idx += file_row_count
                    cumulative += file_row_count
                    if os.path.exists(_pag_tmp2): os.remove(_pag_tmp2)
                    continue

                target_sheet = None
                for si in range(wb.nsheets):
                    s = wb.sheet_by_index(si)
                    if s.name.strip() == xls_sheet_name:
                        target_sheet = s
                        break
                    wb.unload_sheet(si)

                if target_sheet is None or target_sheet.nrows < 2:
                    wb.release_resources()
                    if os.path.exists(_pag_tmp2): os.remove(_pag_tmp2)
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
                if os.path.exists(_pag_tmp2): os.remove(_pag_tmp2)

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



def _process_zip_to_multiple_xlsx_sync(zip_temp_path: str, hdqts: list, progress_cb=None,
                                       cancel_event=None, city_hdqt_map: dict = None) -> dict:
    """SQLite 중간 저장 방식: ZIP 1번만 읽어 SQLite에 적재 → 본부별 xlsx 순차 생성

    Phase A: ZIP → SQLite (모든 행을 하나의 임시 DB에 저장, hdqt 컬럼으로 본부 분류)
    Phase B: SQLite → 5개 xlsx 순차 생성 (Workbook 1개씩 생성/close → 메모리 해제)

    Returns: { hdqt: (xlsx_path, sheet_stats, total_rows, sheet_headers) }
    """
    import copy, sqlite3, json
    if not HAS_XLRD or not HAS_XLSXWRITER:
        raise RuntimeError("xlrd or xlsxwriter not installed")

    results = {h: {"stats": {}, "rows": 0, "headers": {}} for h in hdqts}
    _xwb_refs = {}
    _xlsxwriter_tmpdirs = []
    sqlite_path = f"/tmp/ds_xlsx_stage_{os.getpid()}_{id(zip_temp_path)}.db"
    if os.path.exists(sqlite_path):
        try: os.remove(sqlite_path)
        except Exception: pass

    def _addr_to_hdqt(addr: str) -> str:
        if not addr: return ''
        parts = addr.strip().split()
        if city_hdqt_map and len(parts) >= 2:
            p0, p1 = parts[0], parts[1]
            key = f'서울 {p1}' if '서울' in p0 else f'인천 {p1}' if '인천' in p0 else f'경기 {p1}' if '경기' in p0 else None
            if key and key in city_hdqt_map: return city_hdqt_map[key]
        if '인천' in addr: return '인천'
        if '경기' in addr: return '경기'
        if '서울' in addr:
            for gu, hdqt in [('강남구','강남'),('서초구','강남'),('관악구','강남'),('동작구','강남'),('강동구','강남'),('송파구','강남'),('양천구','강남'),('강서구','강남'),('영등포구','강남'),('구로구','강남'),('금천구','강남')]:
                if gu in addr: return hdqt
            return '강북'
        return ''

    _SHEET_BASE_ORDER = ['일반사항', '장치', '전파형식', '주파수', '안테나', '설치장소', '종사자', '부적합무선국']
    def _sheet_sort_key(n):
        import re
        is_before = 1 if '(검사전)' in n else 0
        m = re.search(r'\((\d+)\)', n)
        num = int(m.group(1)) if m else 0
        base = re.sub(r'\(검사전\)|\(\d+\)', '', n).strip()
        base_idx = _SHEET_BASE_ORDER.index(base) if base in _SHEET_BASE_ORDER else len(_SHEET_BASE_ORDER)
        return (base_idx, is_before, num)

    conn = None
    try:
        conn = sqlite3.connect(sqlite_path)
        conn.execute("PRAGMA journal_mode=OFF")
        conn.execute("PRAGMA synchronous=OFF")
        conn.execute("PRAGMA temp_store=MEMORY")
        conn.execute("PRAGMA cache_size=-20000")  # 20MB 캐시
        conn.execute("CREATE TABLE rows (sheet_name TEXT NOT NULL, hdqt TEXT, values_json TEXT NOT NULL)")

        with zipfile.ZipFile(zip_temp_path, "r") as zf:
            all_names = zf.namelist()
            name_map = {n: _fix_zip_filename(n) for n in all_names}
            xls_names = [n for n in all_names if name_map[n].lower().endswith(".xls") and not os.path.basename(name_map[n]).startswith("~")]

            classified = {"base": [], "numbered": [], "spt": [], "hundred": []}
            hundred_files = set()
            for fname in xls_names:
                b_fname = os.path.basename(name_map[fname])
                if not b_fname: continue
                cls = _classify_ds_file(b_fname)
                classified[cls].append(fname)
                if cls == "hundred": hundred_files.add(fname)

            process_list = classified["base"] + classified["numbered"] + classified["spt"] + classified["hundred"]
            if not process_list: raise ValueError("처리할 XLS 파일 없음")

            # ── Pass 1: 헤더 및 허가번호 매핑 스캔 ──
            global_sheet_headers = {}
            lic_to_hdqt = {}

            for fname in process_list:
                if cancel_event and cancel_event.is_set(): raise InterruptedError("xlsx build cancelled")
                xls_tmp = f"/tmp/ds_xls_p1_{id(zf)}_{fname.replace('/', '_')}.xls"
                try:
                    with zf.open(fname) as src, open(xls_tmp, "wb") as dst: shutil.copyfileobj(src, dst)
                    try: wb = xlrd.open_workbook(xls_tmp, on_demand=True)
                    except: wb = xlrd.open_workbook(xls_tmp, on_demand=True, ignore_workbook_corruption=True)
                except Exception:
                    if os.path.exists(xls_tmp): os.remove(xls_tmp)
                    continue

                for sheet_idx in range(wb.nsheets):
                    sheet = wb.sheet_by_index(sheet_idx)
                    orig_sheet_name = sheet.name.strip()
                    if sheet.nrows < 2:
                        wb.unload_sheet(sheet_idx)
                        continue
                    sheet_name = f"{orig_sheet_name}(검사전)" if fname in hundred_files else orig_sheet_name

                    headers = [_xlrd_cell_to_str(sheet, 0, c) for c in range(sheet.ncols)]
                    headers = [h for h in headers if h]
                    if not headers:
                        wb.unload_sheet(sheet_idx)
                        continue

                    if sheet_name not in global_sheet_headers:
                        global_sheet_headers[sheet_name] = list(headers)
                    else:
                        existing = set(global_sheet_headers[sheet_name])
                        for h in headers:
                            if h not in existing:
                                global_sheet_headers[sheet_name].append(h)
                                existing.add(h)

                    if orig_sheet_name == '설치장소':
                        hdr = [_xlrd_cell_to_str(sheet, 0, c) for c in range(sheet.ncols)]
                        lic_col = next((i for i, hh in enumerate(hdr) if hh == '허가번호'), -1)
                        road_col = next((i for i, hh in enumerate(hdr) if hh == '설치장소도로주소'), -1)
                        inp_col = next((i for i, hh in enumerate(hdr) if hh == '설치장소입력주소'), -1)
                        if lic_col >= 0:
                            for ri in range(1, sheet.nrows):
                                lic = _xlrd_cell_to_str(sheet, ri, lic_col).strip()
                                if not lic: continue
                                addr = ((_xlrd_cell_to_str(sheet, ri, road_col) if road_col >= 0 else '') or
                                        (_xlrd_cell_to_str(sheet, ri, inp_col) if inp_col >= 0 else ''))
                                hd = _addr_to_hdqt(addr.strip())
                                if hd in hdqts: lic_to_hdqt[lic] = hd
                    wb.unload_sheet(sheet_idx)

                wb.release_resources()
                del wb
                try: os.remove(xls_tmp)
                except Exception: pass

            if not global_sheet_headers: raise ValueError("처리할 시트가 없습니다.")
            _release_memory()

            sorted_sheet_names = sorted(global_sheet_headers.keys(), key=_sheet_sort_key)
            global_sheet_headers = {k: global_sheet_headers[k] for k in sorted_sheet_names}

            for h in hdqts:
                results[h]["headers"] = copy.deepcopy(global_sheet_headers)
                for sname in global_sheet_headers:
                    results[h]["stats"][sname] = 0

            header_col_maps = {sname: {col_h: i for i, col_h in enumerate(hdrs)} for sname, hdrs in global_sheet_headers.items()}

            # ── Phase A: XLS → SQLite 적재 ──
            BATCH_SIZE = 5000
            row_buffer = []
            total_inserted = 0

            def _flush_buffer():
                nonlocal row_buffer, total_inserted
                if not row_buffer: return
                conn.executemany("INSERT INTO rows (sheet_name, hdqt, values_json) VALUES (?, ?, ?)", row_buffer)
                conn.commit()
                total_inserted += len(row_buffer)
                row_buffer = []

            total_files = len(process_list)
            for file_idx, fname in enumerate(process_list):
                if cancel_event and cancel_event.is_set(): raise InterruptedError("xlsx build cancelled")
                xls_tmp_path = f"/tmp/ds_xls_{id(zf)}_{file_idx}.xls"
                try:
                    with zf.open(fname) as src, open(xls_tmp_path, "wb") as dst: shutil.copyfileobj(src, dst)
                    try: wb = xlrd.open_workbook(xls_tmp_path, on_demand=True)
                    except: wb = xlrd.open_workbook(xls_tmp_path, on_demand=True, ignore_workbook_corruption=True)
                except Exception:
                    if os.path.exists(xls_tmp_path): os.remove(xls_tmp_path)
                    continue

                file_rows = 0
                for sheet_idx in range(wb.nsheets):
                    sheet = wb.sheet_by_index(sheet_idx)
                    orig_sheet_name = sheet.name.strip()
                    if sheet.nrows < 2:
                        wb.unload_sheet(sheet_idx)
                        continue
                    sheet_name = f"{orig_sheet_name}(검사전)" if fname in hundred_files else orig_sheet_name
                    if sheet_name not in global_sheet_headers:
                        wb.unload_sheet(sheet_idx)
                        continue

                    col_map = header_col_maps[sheet_name]
                    num_cols = len(global_sheet_headers[sheet_name])
                    xls_col_map = [(col, col_map[col_h]) for col in range(sheet.ncols) if (col_h := _xlrd_cell_to_str(sheet, 0, col)) and col_h in col_map]
                    if not xls_col_map:
                        wb.unload_sheet(sheet_idx)
                        continue

                    lic_xlsx_col = header_col_maps[sheet_name].get('허가번호', -1)

                    for row_idx in range(1, sheet.nrows):
                        row_vals = [""] * num_cols
                        for xls_col, xlsx_col in xls_col_map:
                            val = _xlrd_cell_to_str(sheet, row_idx, xls_col)
                            if val: row_vals[xlsx_col] = val

                        # 매핑된 본부 결정 (None이면 미매핑 → 전체합에만 포함)
                        hd = None
                        if lic_to_hdqt and lic_xlsx_col >= 0:
                            lic = row_vals[lic_xlsx_col].strip() if lic_xlsx_col < len(row_vals) else ''
                            mapped = lic_to_hdqt.get(lic)
                            if mapped and mapped in hdqts:
                                hd = mapped

                        row_buffer.append((sheet_name, hd, json.dumps(row_vals, ensure_ascii=False, separators=(',', ':'))))
                        file_rows += 1
                        if len(row_buffer) >= BATCH_SIZE:
                            _flush_buffer()
                    wb.unload_sheet(sheet_idx)

                wb.release_resources()
                del wb
                try: os.remove(xls_tmp_path)
                except Exception: pass

                # 10개 파일마다 진행 로그
                if (file_idx + 1) % 10 == 0 or file_idx + 1 == total_files:
                    logger.info(f"DS xlsx Phase A: [{file_idx+1}/{total_files}] 누적 {total_inserted + len(row_buffer)}행")

            _flush_buffer()
            logger.info(f"DS xlsx Phase A 완료: SQLite 적재 {total_inserted}행 → {sqlite_path}")
            _release_memory()

            # 인덱스 생성 (Phase B SELECT 가속)
            conn.execute("CREATE INDEX idx_rows_sheet_hdqt ON rows (sheet_name, hdqt)")
            conn.commit()

        # ── Phase B: SQLite → 본부별 xlsx 순차 생성 ──
        logger.info(f"DS xlsx Phase B 시작: {len(hdqts)}개 본부 순차 생성")
        for h_idx, h in enumerate(hdqts):
            if cancel_event and cancel_event.is_set(): raise InterruptedError("xlsx build cancelled")

            h_key = h if h is not None else "full"
            logger.info(f"DS xlsx Phase B [{h_idx+1}/{len(hdqts)}] 시작: hdqt={h_key}")
            out_path = f"/tmp/ds_xlsx_multi_{h_key}_{id(zip_temp_path)}.xlsx"
            results[h]["path"] = out_path
            tmpdir = f"/tmp/ds_xlsxbuild_{h_key}_{os.getpid()}"
            os.makedirs(tmpdir, exist_ok=True)
            _xlsxwriter_tmpdirs.append(tmpdir)

            xwb = xlsxwriter.Workbook(out_path, {"constant_memory": True, "tmpdir": tmpdir})
            _xwb_refs[h] = xwb
            header_fmt = xwb.add_format({"font_name": "Arial", "font_size": 10, "bold": True, "align": "center", "valign": "vcenter", "bg_color": "#BFBFBF", "border": 1})
            data_fmt = xwb.add_format({"font_name": "Arial", "font_size": 10, "align": "center", "valign": "vcenter", "border": 1})

            for sname, hdrs in global_sheet_headers.items():
                if cancel_event and cancel_event.is_set(): raise InterruptedError("xlsx build cancelled")

                xws = xwb.add_worksheet(sname[:31])
                xws.set_row(0, 12.75)
                for ci, col_h in enumerate(hdrs):
                    xws.set_column(ci, ci, 20)
                    xws.write(0, ci, col_h, header_fmt)

                # 본부 필터: None(전체합)은 모든 행, 본부별은 (해당 본부 OR NULL 제외)
                # 정확히는 None=전체합이므로 모든 행, 그 외는 hdqt=해당본부 행만
                if h is None:
                    cur = conn.execute("SELECT values_json FROM rows WHERE sheet_name=?", (sname,))
                else:
                    cur = conn.execute("SELECT values_json FROM rows WHERE sheet_name=? AND hdqt=?", (sname, h))

                ri = 1
                split_num = 1
                cur_xws = xws
                rows_in_sheet = 0
                for (values_json,) in cur:
                    if ri > 1_000_000:
                        split_num += 1
                        split_ws_name = f"{sname}({split_num})"[:31]
                        cur_xws = xwb.add_worksheet(split_ws_name)
                        cur_xws.set_row(0, 12.75)
                        for ci, col_h in enumerate(hdrs):
                            cur_xws.set_column(ci, ci, 20)
                            cur_xws.write(0, ci, col_h, header_fmt)
                        ri = 1

                    row_vals = json.loads(values_json)
                    cur_xws.set_row(ri, 12.75)
                    for ci, val in enumerate(row_vals):
                        cur_xws.write(ri, ci, val, data_fmt)
                    ri += 1
                    rows_in_sheet += 1

                results[h]["stats"][sname] = rows_in_sheet
                results[h]["rows"] += rows_in_sheet

            xwb.close()
            del _xwb_refs[h]
            logger.info(f"DS xlsx Phase B 완료: hdqt={h_key} ({results[h]['rows']}행)")
            _release_memory()

        for tmpdir in _xlsxwriter_tmpdirs:
            if os.path.isdir(tmpdir): shutil.rmtree(tmpdir, ignore_errors=True)

    except Exception:
        for xwb in _xwb_refs.values():
            try: xwb.close()
            except Exception: pass
        for tmpdir in _xlsxwriter_tmpdirs:
            if os.path.isdir(tmpdir): shutil.rmtree(tmpdir, ignore_errors=True)
        raise
    finally:
        if conn is not None:
            try: conn.close()
            except Exception: pass
        try:
            if os.path.exists(sqlite_path): os.remove(sqlite_path)
        except Exception: pass

    _release_memory()
    return {h: (results[h]["path"], results[h]["stats"], results[h]["rows"], results[h]["headers"]) for h in hdqts}

def _process_zip_to_xlsx_sync(zip_temp_path: str, progress_cb=None,

                               xlsx_out_path: str = None,
                               cancel_event: threading.Event = None,
                               hdqt_filter: str = None,
                               city_hdqt_map: dict = None,
                               pre_sheet_headers: dict = None) -> tuple:
    """ZIP → XLS 파싱 → xlsx 직접 빌드 (2-pass 스트리밍, 디스크 기반)

    Pass 1: 헤더 수집 (행 0만 읽기, 메모리 ~수 KB)
    Pass 2: xlsxwriter → 디스크 파일에 직접 쓰기 (메모리 ~수 MB)

    Returns: (xlsx_path, sheet_stats, total_rows, sheet_headers)
    progress_cb: Optional[Callable(stage, percent)] — 파일별 진행률 콜백
    xlsx_out_path: xlsx 출력 경로 (미지정 시 자동 생성)
    cancel_event: threading.Event — set되면 루프 즉시 중단
    hdqt_filter: 본부명 (예: "강남") — 설치장소 주소 기반으로 해당 본부 행만 포함
    city_hdqt_map: {"경기 시흥시": "인천", ...} — hdqt_filter 사용 시 주소→본부 매핑
    """
    if not HAS_XLRD:
        raise RuntimeError("xlrd not installed on server")
    if not HAS_XLSXWRITER:
        raise RuntimeError("xlsxwriter not installed on server")

    sheet_stats: Dict[str, int] = {}
    sheet_headers: Dict[str, list] = {}
    total_rows = 0
    _xwb_ref = None
    _xlsxwriter_tmpdir = None
    _sqlite_conn = None
    sqlite_path = f"/tmp/ds_xlsx_stage_{os.getpid()}_init.db"

    try:
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

        # ── Pass 1: 헤더 수집 (pre_sheet_headers 있으면 스킵) ──
        _SHEET_BASE_ORDER = ['일반사항', '장치', '전파형식', '주파수', '안테나', '설치장소', '종사자', '부적합무선국']

        def _sheet_sort_key(name: str):
            import re
            is_before = 1 if '(검사전)' in name else 0
            m = re.search(r'\((\d+)\)', name)
            num = int(m.group(1)) if m else 0
            base = re.sub(r'\(검사전\)|\(\d+\)', '', name).strip()
            base_idx = _SHEET_BASE_ORDER.index(base) if base in _SHEET_BASE_ORDER else len(_SHEET_BASE_ORDER)
            return (base_idx, is_before, num)

        if pre_sheet_headers:
            # DynamoDB 헤더 사전 로드 → Pass 1 전체 스킵
            sheet_headers = dict(pre_sheet_headers)
            logger.info(f"DS xlsx: DynamoDB 헤더 사용, Pass1 스킵 ({len(sheet_headers)}개 시트)")
        else:
            # Pass 1: 모든 XLS 파일에서 헤더 직접 수집
            if progress_cb:
                progress_cb("헤더 분석 중...", 5)

            for fname in process_list:
                if cancel_event and cancel_event.is_set():
                    logger.info("DS xlsx Pass1: 취소 플래그 감지 → 중단")
                    raise InterruptedError("xlsx build cancelled")
                is_hundred = fname in hundred_files
                xls_tmp = f"/tmp/ds_xls_p1_{id(zf)}_{fname.replace('/', '_')}.xls"
                try:
                    with zf.open(fname) as src, open(xls_tmp, "wb") as dst:
                        shutil.copyfileobj(src, dst)
                    try:
                        workbook = xlrd.open_workbook(xls_tmp, on_demand=True)
                    except Exception:
                        workbook = xlrd.open_workbook(xls_tmp, on_demand=True, ignore_workbook_corruption=True)
                except Exception as e:
                    logger.warning(f"DS xlsx Pass1: {fname} 실패: {e}")
                    if os.path.exists(xls_tmp):
                        os.remove(xls_tmp)
                    continue

                if is_hundred:
                    hundred_sheet_names = []
                    for si in range(workbook.nsheets):
                        s = workbook.sheet_by_index(si)
                        hundred_sheet_names.append(f"{s.name.strip()}({s.nrows}행)")
                        workbook.unload_sheet(si)
                    logger.info(f"DS xlsx Pass1: (100) 파일 {os.path.basename(name_map[fname])} "
                                f"시트: {hundred_sheet_names}")

                for sheet_idx in range(workbook.nsheets):
                    sheet = workbook.sheet_by_index(sheet_idx)
                    orig_sheet_name = sheet.name.strip()
                    if sheet.nrows < 2:
                        workbook.unload_sheet(sheet_idx)
                        continue
                    sheet_name = f"{orig_sheet_name}(검사전)" if is_hundred else orig_sheet_name
                    headers = []
                    for col in range(sheet.ncols):
                        h = _xlrd_cell_to_str(sheet, 0, col)
                        if h:
                            headers.append(h)
                    if not headers:
                        workbook.unload_sheet(sheet_idx)
                        continue
                    if sheet_name not in sheet_headers:
                        sheet_headers[sheet_name] = list(headers)
                    else:
                        existing = set(sheet_headers[sheet_name])
                        for h in headers:
                            if h not in existing:
                                sheet_headers[sheet_name].append(h)
                                existing.add(h)
                    workbook.unload_sheet(sheet_idx)

                workbook.release_resources()
                del workbook
                try:
                    os.remove(xls_tmp)
                except Exception:
                    pass

            if not sheet_headers:
                raise ValueError("처리할 시트가 없습니다.")
            _release_memory()
            all_sheets = list(sheet_headers.keys())
            hundred_sheets = [s for s in all_sheets if "(검사전)" in s]
            logger.info(f"DS xlsx Pass1 완료: {len(sheet_headers)}개 시트 헤더 수집 "
                        f"(검사전 시트: {hundred_sheets})")

        sorted_sheet_names = sorted(sheet_headers.keys(), key=_sheet_sort_key)
        sheet_headers = {k: sheet_headers[k] for k in sorted_sheet_names}

        # ── hdqt_filter: 설치장소 시트에서 허가번호→본부 매핑 생성 ──
        lic_to_hdqt: dict = {}
        if hdqt_filter:
            SEOUL_GU_MAP = {
                '강남구':'강남','서초구':'강남','관악구':'강남','동작구':'강남',
                '강동구':'강남','송파구':'강남','양천구':'강남','강서구':'강남',
                '영등포구':'강남','구로구':'강남','금천구':'강남',
                '용산구':'강북','마포구':'강북','서대문구':'강북','은평구':'강북',
                '종로구':'강북','중구':'강북','성동구':'강북','광진구':'강북',
                '중랑구':'강북','동대문구':'강북','성북구':'강북','강북구':'강북',
                '도봉구':'강북','노원구':'강북',
            }
            def _addr_to_hdqt(addr: str) -> str:
                if not addr:
                    return ''
                parts = addr.strip().split()
                # city_hdqt_map 우선 (DB 기반)
                if city_hdqt_map and len(parts) >= 2:
                    p0, p1 = parts[0], parts[1]
                    if '서울' in p0: key = f'서울 {p1}'
                    elif '인천' in p0: key = f'인천 {p1}'
                    elif '경기' in p0: key = f'경기 {p1}'
                    else: key = None
                    if key and key in city_hdqt_map:
                        return city_hdqt_map[key]
                # fallback: 키워드 기반
                if '인천' in addr: return '인천'
                if '경기' in addr: return '경기'
                if '서울' in addr:
                    for gu, hdqt in SEOUL_GU_MAP.items():
                        if gu in addr:
                            return hdqt
                    return '강북'
                return ''

            # 설치장소 시트를 ZIP에서 직접 스캔
            inst_sheet_name = '설치장소'
            for fname in process_list:
                try:
                    xls_scan_path = f"/tmp/ds_hdqtscan_{id(zf)}_{fname.replace('/','_')}.xls"
                    with zf.open(fname) as src, open(xls_scan_path, 'wb') as dst:
                        shutil.copyfileobj(src, dst)
                    try:
                        wb_scan = xlrd.open_workbook(xls_scan_path, on_demand=True)
                    except Exception:
                        wb_scan = xlrd.open_workbook(xls_scan_path, on_demand=True, ignore_workbook_corruption=True)
                    for si in range(wb_scan.nsheets):
                        sh = wb_scan.sheet_by_index(si)
                        if sh.name.strip() != inst_sheet_name or sh.nrows < 2:
                            wb_scan.unload_sheet(si)
                            continue
                        hdr = [_xlrd_cell_to_str(sh, 0, c) for c in range(sh.ncols)]
                        lic_col = next((i for i, h in enumerate(hdr) if h == '허가번호'), -1)
                        road_col = next((i for i, h in enumerate(hdr) if h == '설치장소도로주소'), -1)
                        inp_col = next((i for i, h in enumerate(hdr) if h == '설치장소입력주소'), -1)
                        if lic_col < 0:
                            continue
                        for ri in range(1, sh.nrows):
                            lic = _xlrd_cell_to_str(sh, ri, lic_col).strip()
                            if not lic:
                                continue
                            addr = (
                                (_xlrd_cell_to_str(sh, ri, road_col) if road_col >= 0 else '')
                                or (_xlrd_cell_to_str(sh, ri, inp_col) if inp_col >= 0 else '')
                            )
                            hdqt = _addr_to_hdqt(addr.strip())
                            if hdqt:
                                lic_to_hdqt[lic] = hdqt
                        wb_scan.unload_sheet(si)
                    wb_scan.release_resources()
                    del wb_scan
                except Exception as e:
                    logger.warning(f"DS hdqt scan: {fname} 실패 (non-fatal): {e}")
                finally:
                    try:
                        if os.path.exists(xls_scan_path):
                            os.remove(xls_scan_path)
                    except Exception:
                        pass
            logger.info(f"DS xlsx hdqt_filter={hdqt_filter}: 허가번호 매핑 {len(lic_to_hdqt)}건")

        # ── Phase A: XLS → SQLite (파일 1개씩 처리, 처리 후 즉시 메모리 해제) ──
        import sqlite3 as _sqlite3, json as _json
        if progress_cb:
            progress_cb(f"데이터 적재 중... (0/{total_files})", 10)

        sqlite_path = f"/tmp/ds_xlsx_stage_{os.getpid()}_{id(zip_temp_path)}.db"
        if os.path.exists(sqlite_path):
            try: os.remove(sqlite_path)
            except Exception: pass

        header_col_maps: Dict[str, Dict[str, int]] = {
            sname: {h: i for i, h in enumerate(hdrs)}
            for sname, hdrs in sheet_headers.items()
        }
        for sname in sheet_headers:
            sheet_stats[sname] = 0

        _sqlite_conn = _sqlite3.connect(sqlite_path)
        _sqlite_conn.execute("PRAGMA journal_mode=OFF")
        _sqlite_conn.execute("PRAGMA synchronous=OFF")
        _sqlite_conn.execute("PRAGMA temp_store=MEMORY")
        _sqlite_conn.execute("PRAGMA cache_size=-32000")  # 32MB
        _sqlite_conn.execute(
            "CREATE TABLE rows (id INTEGER PRIMARY KEY, sheet_name TEXT NOT NULL, values_json TEXT NOT NULL)"
        )

        BATCH_SIZE = 5000
        row_buffer = []
        total_inserted = 0

        def _flush():
            nonlocal row_buffer, total_inserted
            if not row_buffer: return
            _sqlite_conn.executemany("INSERT INTO rows (sheet_name, values_json) VALUES (?, ?)", row_buffer)
            _sqlite_conn.commit()
            total_inserted += len(row_buffer)
            row_buffer = []

        for file_idx, fname in enumerate(process_list):
            if cancel_event and cancel_event.is_set():
                raise InterruptedError("xlsx build cancelled")
            base_fname = os.path.basename(name_map[fname]) or name_map[fname]
            is_hundred = fname in hundred_files

            if progress_cb:
                pct = 10 + (file_idx / total_files) * 55
                if file_idx == 0 or file_idx == total_files - 1 or file_idx % 5 == 0:
                    progress_cb(f"데이터 적재 중... ({file_idx+1}/{total_files})", pct)

            xls_tmp_path = f"/tmp/ds_xls_{id(zf)}_{file_idx}.xls"
            try:
                with zf.open(fname) as src, open(xls_tmp_path, "wb") as dst:
                    shutil.copyfileobj(src, dst)
            except Exception as e:
                logger.warning(f"DS xlsx PhaseA: {fname} 읽기 실패: {e}")
                if os.path.exists(xls_tmp_path): os.remove(xls_tmp_path)
                continue

            try:
                try:
                    workbook = xlrd.open_workbook(xls_tmp_path, on_demand=True)
                except Exception:
                    workbook = xlrd.open_workbook(xls_tmp_path, on_demand=True, ignore_workbook_corruption=True)
            except Exception as e:
                logger.warning(f"DS xlsx PhaseA: XLS 파싱 실패 ({base_fname}): {e}")
                if os.path.exists(xls_tmp_path): os.remove(xls_tmp_path)
                continue

            file_rows = 0
            for sheet_idx in range(workbook.nsheets):
                sheet = workbook.sheet_by_index(sheet_idx)
                orig_sheet_name = sheet.name.strip()
                if sheet.nrows < 2:
                    workbook.unload_sheet(sheet_idx)
                    continue
                sheet_name = f"{orig_sheet_name}(검사전)" if is_hundred else orig_sheet_name
                if sheet_name not in header_col_maps:
                    workbook.unload_sheet(sheet_idx)
                    continue

                col_map = header_col_maps[sheet_name]
                num_cols = len(sheet_headers[sheet_name])
                xls_col_map = [
                    (col, col_map[h])
                    for col in range(sheet.ncols)
                    if (h := _xlrd_cell_to_str(sheet, 0, col)) and h in col_map
                ]
                if not xls_col_map:
                    workbook.unload_sheet(sheet_idx)
                    continue

                lic_xlsx_col = header_col_maps[sheet_name].get('허가번호', -1) if hdqt_filter and lic_to_hdqt else -1

                for row_idx in range(1, sheet.nrows):
                    row_vals = [""] * num_cols
                    for xls_col, xlsx_col in xls_col_map:
                        val = _xlrd_cell_to_str(sheet, row_idx, xls_col)
                        if val: row_vals[xlsx_col] = val

                    if hdqt_filter and lic_to_hdqt and lic_xlsx_col >= 0:
                        lic = row_vals[lic_xlsx_col].strip() if lic_xlsx_col < len(row_vals) else ''
                        if lic_to_hdqt.get(lic) != hdqt_filter:
                            continue

                    row_buffer.append((sheet_name, _json.dumps(row_vals, ensure_ascii=False, separators=(',', ':'))))
                    file_rows += 1
                    if len(row_buffer) >= BATCH_SIZE:
                        _flush()

                workbook.unload_sheet(sheet_idx)

            workbook.release_resources()
            del workbook
            try: os.remove(xls_tmp_path)
            except Exception: pass
            total_rows += file_rows

            if HAS_PSUTIL:
                mem = psutil.virtual_memory()
                swap = psutil.swap_memory()
                total_avail_mb = (mem.available + swap.free) // (1024 * 1024)
                logger.info(f"DS xlsx PhaseA: [{file_idx+1}/{total_files}] {base_fname} → {file_rows}행 "
                            f"(가용 RAM {mem.available//(1024*1024)}MB, 스왑 {swap.free//(1024*1024)}MB, 합산 {total_avail_mb}MB)")
            else:
                logger.info(f"DS xlsx PhaseA: [{file_idx+1}/{total_files}] {base_fname} → {file_rows}행")

        _flush()
        logger.info(f"DS xlsx PhaseA 완료: SQLite 적재 {total_inserted}행 → {sqlite_path}")
        _sqlite_conn.execute("CREATE INDEX idx_sheet ON rows (sheet_name, id)")
        _sqlite_conn.commit()
        _release_memory()

        # ── Phase B: SQLite → xlsx (스트리밍, 최대 ~200MB) ──
        if progress_cb:
            progress_cb("xlsx 생성 중...", 70)

        if not xlsx_out_path:
            xlsx_out_path = f"/tmp/ds_xlsx_{os.path.basename(zip_temp_path)}_{id(zip_temp_path)}.xlsx"
        _xlsxwriter_tmpdir = f"/tmp/ds_xlsxbuild_{os.getpid()}"
        os.makedirs(_xlsxwriter_tmpdir, exist_ok=True)
        xwb = xlsxwriter.Workbook(xlsx_out_path, {"constant_memory": True, "tmpdir": _xlsxwriter_tmpdir})
        _xwb_ref = xwb

        header_fmt = xwb.add_format({"font_name": "Arial", "font_size": 10, "bold": True,
                                      "align": "center", "valign": "vcenter", "bg_color": "#BFBFBF", "border": 1})
        data_fmt = xwb.add_format({"font_name": "Arial", "font_size": 10,
                                    "align": "center", "valign": "vcenter", "border": 1})

        MAX_ROWS_PER_SHEET = 1_000_000
        for sname, hdrs in sheet_headers.items():
            if cancel_event and cancel_event.is_set():
                raise InterruptedError("xlsx build cancelled")

            xws = xwb.add_worksheet(sname[:31])
            xws.set_row(0, 12.75)
            for ci, h in enumerate(hdrs):
                xws.set_column(ci, ci, 20)
                xws.write(0, ci, h, header_fmt)

            cur = _sqlite_conn.execute(
                "SELECT values_json FROM rows WHERE sheet_name=? ORDER BY id", (sname,)
            )
            ri = 1
            split_num = 1
            cur_xws = xws
            rows_in_sheet = 0
            for (values_json,) in cur:
                if ri > MAX_ROWS_PER_SHEET:
                    split_num += 1
                    split_ws_name = f"{sname}({split_num})"[:31]
                    cur_xws = xwb.add_worksheet(split_ws_name)
                    cur_xws.set_row(0, 12.75)
                    for ci, h in enumerate(hdrs):
                        cur_xws.set_column(ci, ci, 20)
                        cur_xws.write(0, ci, h, header_fmt)
                    ri = 1
                    logger.info(f"DS xlsx PhaseB: 시트 분할 → {split_ws_name}")

                row_vals = _json.loads(values_json)
                cur_xws.set_row(ri, 12.75)
                cur_xws.write_row(ri, 0, row_vals, data_fmt)
                ri += 1
                rows_in_sheet += 1

            sheet_stats[sname] = rows_in_sheet
            logger.info(f"DS xlsx PhaseB: {sname} → {rows_in_sheet}행")

        xwb.close()
        _xwb_ref = None
        if _xlsxwriter_tmpdir and os.path.isdir(_xlsxwriter_tmpdir):
            shutil.rmtree(_xlsxwriter_tmpdir, ignore_errors=True)

    except Exception:
        if _xwb_ref is not None:
            try: _xwb_ref.close()
            except Exception: pass
        if _xlsxwriter_tmpdir and os.path.isdir(_xlsxwriter_tmpdir):
            shutil.rmtree(_xlsxwriter_tmpdir, ignore_errors=True)
        raise
    finally:
        try:
            _sqlite_conn.close()
        except Exception:
            pass
        try:
            if os.path.exists(sqlite_path):
                os.remove(sqlite_path)
        except Exception:
            pass

    _release_memory()
    file_size = os.path.getsize(xlsx_out_path) if os.path.exists(xlsx_out_path) else 0
    logger.info(f"DS xlsx build 완료: {total_rows}행, {len(sheet_stats)}시트, {file_size:,} bytes → {xlsx_out_path}")
    return xlsx_out_path, sheet_stats, total_rows, sheet_headers


def _init_upload_record_sync(division_id: str, division_code: str, import_date: str,
                              file_name: str, uploaded_by: str, job_id: str):
    """동기: 업로드 레코드 초기화 (같은 본부+코드 기존 모두 삭제 후 새로 생성)"""
    uploads_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_uploads"])
    records_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_records"])
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
    uploads_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_uploads"])
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
                      sheet_headers: Optional[dict] = None) -> str:
    """동기: DynamoDB → xlsxwriter → xlsx 파일 경로 반환 (디스크 기반, 메모리 최소화)

    서식: Arial 10pt, 가운데정렬, 얇은 테두리, 행 높이 12.75
    헤더 행: 볼드 + #BFBFBF 배경, 모든 열 너비 = 20

    헤더 결정 방식:
      1. sheet_headers[sheet_name] 있으면 그대로 사용 (업로드 시 원본 XLS 순서 보존)
      2. 없으면 전체 스캔으로 수집 (하위 호환 fallback)
    """
    if not HAS_XLSXWRITER:
        raise RuntimeError("xlsxwriter not installed on server")

    records_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_records"])
    dc_part = f"#{division_code}" if division_code else ""

    _uid = uuid.uuid4().hex[:8]
    xlsx_out_path = f"/tmp/ds_export_{division_id}_{division_code}_{import_date}_{_uid}.xlsx"
    _xlsxwriter_tmpdir = f"/tmp/ds_export_build_{division_id}_{division_code}_{import_date}_{_uid}"
    _xwb_ref = None
    try:
        os.makedirs(_xlsxwriter_tmpdir, exist_ok=True)
        xwb = xlsxwriter.Workbook(xlsx_out_path, {"constant_memory": True, "tmpdir": _xlsxwriter_tmpdir})
        _xwb_ref = xwb

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
        _xwb_ref = None
    except Exception:
        if _xwb_ref is not None:
            try:
                _xwb_ref.close()
            except Exception:
                pass
        if os.path.exists(xlsx_out_path):
            try:
                os.remove(xlsx_out_path)
            except Exception:
                pass
        raise
    finally:
        if os.path.isdir(_xlsxwriter_tmpdir):
            shutil.rmtree(_xlsxwriter_tmpdir, ignore_errors=True)

    return xlsx_out_path


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
            jobs_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_jobs"])
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
            await _update_job_progress(job_id, "파일 준비 중...", 3)
            actual_key = s3_keys[0] if s3_keys else s3_key

            def _dl():
                get_s3_client().download_file(S3_BUCKET_NAME, actual_key, zip_temp_path)
            await asyncio.to_thread(_dl)
            logger.info(f"DS job {job_id}: ZIP downloaded ({os.path.getsize(zip_temp_path):,} bytes)")

        await _check_cancelled()

        # 2. ZIP 내 XLS 파일명에서 divisionCode/importDate 파싱
        await _update_job_progress(job_id, "파일 정보 확인 중...", 30 if is_multi else 5)

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

        # 4. 메타데이터 파싱 — 서브프로세스 (메모리 격리, 100% 회수)
        await _update_job_progress(job_id, "데이터 분석 중...", 35 if is_multi else 10)

        meta_result_json = f"/tmp/ds_meta_{job_id}_result.json"
        logger.info(f"DS job {job_id}: 메타 파싱 서브프로세스 시작")
        meta_proc = multiprocessing.Process(
            target=_subprocess_metadata_entry,
            args=(zip_temp_path, meta_result_json, job_id),
            daemon=True,
        )
        meta_proc.start()
        while meta_proc.is_alive():
            await asyncio.sleep(2)
        if meta_proc.exitcode != 0:
            raise RuntimeError(f"메타 파싱 서브프로세스 비정상 종료 (exit code {meta_proc.exitcode})")
        if not os.path.exists(meta_result_json):
            raise RuntimeError("메타 파싱 서브프로세스 결과 파일 없음")
        with open(meta_result_json, "r") as _mf:
            meta_result = json.load(_mf)
        try:
            os.remove(meta_result_json)
        except Exception:
            pass
        if not meta_result.get("success"):
            raise RuntimeError(f"메타 파싱 실패: {meta_result.get('error', 'unknown')}")
        sheet_stats = meta_result["sheet_stats"]
        total_rows = meta_result["total_rows"]
        sheet_headers = meta_result["sheet_headers"]
        file_manifest = meta_result["file_manifest"]
        logger.info(f"DS job {job_id}: 메타 파싱 완료 — {total_rows}행, {len(sheet_stats)}시트 (서브프로세스 메모리 회수)")

        if total_rows == 0:
            raise ValueError("XLS 파일에서 데이터 행을 찾을 수 없습니다.")

        await _check_cancelled()

        # 5. 기존 데이터 삭제 (병합+파싱 성공 후에만 → 데이터 안전)
        await _update_job_progress(job_id, "데이터 갱신 준비 중...", 70 if is_multi else 75)
        await asyncio.to_thread(
            _init_upload_record_sync,
            division_id, division_code, import_date, file_name, uploaded_by, job_id
        )
        uploads_record_created = True

        await _check_cancelled()

        # 6. ZIP → S3 영구 경로로 복사 (xlsx 빌드 없이 원본 ZIP 보관)
        await _update_job_progress(job_id, "데이터 저장 중...", 80)
        permanent_zip_key = f"ds-raw/{division_id}/{division_code}_{import_date}.zip"

        def _copy_zip_to_s3():
            s3 = get_s3_client()
            s3.upload_file(zip_temp_path, S3_BUCKET_NAME, permanent_zip_key)

        await asyncio.to_thread(_copy_zip_to_s3)
        logger.info(f"DS job {job_id}: ZIP S3 저장 완료 → {permanent_zip_key}")

        # 7. uploads 레코드 완료 처리 (storageType="s3-zip")
        await _update_job_progress(job_id, "마무리 중...", 90)
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
        _entry = (division_id, division_code, import_date)
        if _entry not in _xlsx_build_queue and _xlsx_build_current != _entry:
            _xlsx_build_queue.append(_entry)
            logger.info(f"DS job {job_id}: xlsx 빌드 큐 등록 ({len(_xlsx_build_queue)}건 대기)")
        else:
            logger.info(f"DS job {job_id}: xlsx 빌드 중복 스킵 (이미 빌드 중 또는 큐에 존재)")

        # 9.5. ds_detail.db 갱신 (검사내역서 export용 — non-fatal)
        try:
            await asyncio.to_thread(_build_ds_detail_from_zip_sync, zip_temp_path)
            logger.info(f"DS job {job_id}: ds_detail.db 갱신 완료")
        except Exception as _de:
            logger.warning(f"DS job {job_id}: ds_detail.db 갱신 실패 (non-fatal): {_de}")

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
                _uploads_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_uploads"])
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


# xlsx 캐시 빌드 큐 — 잡 완료 시 등록, 워커 유휴 시 별도 태스크로 실행
_xlsx_build_queue: list = []
_xlsx_build_task: Optional[asyncio.Task] = None
_xlsx_build_cancel_event: Optional[threading.Event] = None  # xlsx 빌드 취소용
_xlsx_build_current: Optional[tuple] = None  # 현재 빌드 중인 (division_id, division_code, import_date)
_xlsx_build_process: Optional[multiprocessing.Process] = None  # 현재 빌드 서브프로세스
_xlsx_build_start_time: Optional[float] = None  # 현재 빌드 시작 epoch time



def _subprocess_multiple_xlsx_entry(zip_path: str, hdqts: list, result_path: str,
                                    cancel_flag_path: str, city_hdqt_map: dict = None):
    """서브프로세스 진입점: ZIP → 여러 xlsx 동시 빌드 후 결과를 JSON으로 저장."""
    import json, os, traceback
    class _FileCancelEvent:
        def __init__(self, path): self._path = path
        def is_set(self): return os.path.exists(self._path)
        def set(self):
            with open(self._path, "w") as f: f.write("1")
    cancel_ev = _FileCancelEvent(cancel_flag_path)
    try:
        results = _process_zip_to_multiple_xlsx_sync(
            zip_path, hdqts, cancel_event=cancel_ev, city_hdqt_map=city_hdqt_map
        )
        # None 키 → "__full__", tuple → dict로 변환 (JSON 직렬화 + 호출부 호환)
        serializable = {}
        for k, v in results.items():
            key = "__full__" if k is None else k
            path, stats, rows, headers = v
            serializable[key] = {"path": path, "stats": stats, "rows": rows, "headers": headers}
        out = {"success": True, "results": serializable}
    except InterruptedError:
        out = {"success": False, "cancelled": True, "error": "cancelled"}
    except Exception as e:
        out = {"success": False, "cancelled": False, "error": str(e), "traceback": traceback.format_exc()}
    try:
        with open(result_path, "w") as f: json.dump(out, f)
    except Exception: pass

def _subprocess_xlsx_entry(zip_path: str, xlsx_path: str, result_path: str,

                           cancel_flag_path: str, hdqt_filter: str = None,
                           city_hdqt_map: dict = None, pre_sheet_headers: dict = None):
    """서브프로세스 진입점: ZIP → xlsx 빌드 후 결과를 JSON으로 저장.
    이 함수가 끝나면 프로세스가 exit → OS가 메모리 100% 회수.
    """
    import json, os, sys, traceback
    # 취소 체크를 위한 간이 Event (파일 기반)
    class _FileCancelEvent:
        def __init__(self, path):
            self._path = path
        def is_set(self):
            return os.path.exists(self._path)
        def set(self):
            with open(self._path, "w") as f:
                f.write("1")

    cancel_ev = _FileCancelEvent(cancel_flag_path)
    try:
        result = _process_zip_to_xlsx_sync(
            zip_path, None, xlsx_path, cancel_event=cancel_ev,
            hdqt_filter=hdqt_filter, city_hdqt_map=city_hdqt_map,
            pre_sheet_headers=pre_sheet_headers,
        )
        # result = (xlsx_path, sheet_stats, total_rows, sheet_headers)
        out = {
            "success": True,
            "xlsx_path": result[0],
            "total_rows": result[2],
        }
    except InterruptedError:
        out = {"success": False, "cancelled": True, "error": "cancelled"}
    except Exception as e:
        out = {"success": False, "cancelled": False, "error": str(e),
               "traceback": traceback.format_exc()}
    try:
        with open(result_path, "w") as f:
            json.dump(out, f)
    except Exception:
        pass



async def _build_multiple_xlsx_cache(
    division_id: str, division_code: str, import_date: str,
    zip_temp: str, cancel_ev, hdqts: list, city_hdqt_map: dict = None,
):
    global _xlsx_build_process
    tag = f"{division_id}/{division_code}_{import_date}_multi"
    result_json = f"/tmp/ds_bgxlsx_{division_id}_{division_code}_{import_date}_multi_result.json"
    cancel_flag = f"/tmp/ds_bgxlsx_{division_id}_{division_code}_{import_date}_multi_cancel"

    try:
        if cancel_ev.is_set(): raise InterruptedError("xlsx build cancelled before subprocess")

        logger.info(f"DS bg xlsx: 다중 서브프로세스 시작 {tag}")
        proc = multiprocessing.Process(
            target=_subprocess_multiple_xlsx_entry,
            args=(zip_temp, hdqts, result_json, cancel_flag),
            kwargs={"city_hdqt_map": city_hdqt_map},
            daemon=True,
        )
        _xlsx_build_process = proc
        proc.start()

        start_wait_time = _time_mod.time()
        while proc.is_alive():
            if cancel_ev.is_set():
                try:
                    with open(cancel_flag, "w") as f: f.write("1")
                except Exception: pass
                proc.join(timeout=10)
                if proc.is_alive():
                    proc.terminate()
                    proc.join(timeout=5)
                raise InterruptedError("xlsx build cancelled")

            if _time_mod.time() - start_wait_time > 10800:
                logger.error(f"DS bg xlsx 타임아웃 발생 (강제 종료): {tag}")
                proc.terminate()
                proc.join(timeout=5)
                raise TimeoutError("엑셀 빌드 타임아웃 초과로 서브프로세스를 강제 종료했습니다.")
            await asyncio.sleep(2)

        _xlsx_build_process = None
        if proc.exitcode != 0: raise RuntimeError(f"서브프로세스 비정상 종료 (exit code {proc.exitcode})")

        if not os.path.exists(result_json): raise RuntimeError("서브프로세스 결과 파일 없음")
        with open(result_json, "r") as f: result = json.load(f)
        if not result.get("success"):
            if result.get("cancelled"): raise InterruptedError("xlsx build cancelled in subprocess")
            raise RuntimeError(f"서브프로세스 빌드 실패: {result.get('error', 'unknown')}")

        if cancel_ev.is_set(): raise InterruptedError("xlsx build cancelled after processing")

        s3 = get_s3_client()
        for hdqt, hdqt_res in result["results"].items():
            if hdqt == "__full__":
                # 전체합: suffix 없음 → 10_YYYYMMDD.xlsx
                s3_key = f"ds-exports/{division_id}/{division_code}_{import_date}.xlsx"
            else:
                hdqt_key = _HDQT_S3_KEY.get(hdqt, hdqt)
                s3_key = f"ds-exports/{division_id}/{division_code}_{import_date}_{hdqt_key}.xlsx"
            xlsx_temp = hdqt_res["path"]
            total_rows = hdqt_res.get("rows", 0)
            logger.info(f"DS xlsx multi upload: {s3_key} ({total_rows}행)")
            await asyncio.to_thread(
                s3.upload_file, xlsx_temp, S3_BUCKET_NAME, s3_key,
                ExtraArgs={"ContentType": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
            )
            logger.info(f"DS xlsx multi upload 완료: {s3_key}")
            try:
                if os.path.exists(xlsx_temp): os.remove(xlsx_temp)
            except Exception: pass

    finally:
        for tmp in [result_json, cancel_flag]:
            try:
                if os.path.exists(tmp): os.remove(tmp)
            except Exception: pass

async def _build_one_xlsx_cache(

    division_id: str, division_code: str, import_date: str,
    zip_temp: str, cancel_ev,
    hdqt_filter: str = None, city_hdqt_map: dict = None,
) -> int:
    """단일 xlsx 빌드 → S3 저장. 성공 시 total_rows 반환. 취소/실패 시 예외."""
    global _xlsx_build_process
    hdqt_key = _HDQT_S3_KEY.get(hdqt_filter, hdqt_filter) if hdqt_filter else None
    suffix = f"_{hdqt_key}" if hdqt_key else ""
    tag = f"{division_id}/{division_code}_{import_date}{suffix}"
    xlsx_temp = f"/tmp/ds_bgxlsx_{division_id}_{division_code}_{import_date}{suffix}.xlsx"
    result_json = f"/tmp/ds_bgxlsx_{division_id}_{division_code}_{import_date}{suffix}_result.json"
    cancel_flag = f"/tmp/ds_bgxlsx_{division_id}_{division_code}_{import_date}{suffix}_cancel"

    try:
        if cancel_ev.is_set():
            raise InterruptedError("xlsx build cancelled before subprocess")

        # DynamoDB sheetHeaders 사전 로드 → 서브프로세스에서 Pass1 스킵
        pre_sheet_headers = {}
        try:
            def _fetch_headers_sync():
                tbl = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_uploads"])
                item = tbl.get_item(
                    Key={"divisionId": division_id, "importDate": f"{division_code}#{import_date}"},
                    ProjectionExpression="sheetHeaders",
                ).get("Item", {})
                return item.get("sheetHeaders", {})
            pre_sheet_headers = await asyncio.to_thread(_fetch_headers_sync)
            if pre_sheet_headers:
                logger.info(f"DS bg xlsx: sheetHeaders 로드 완료 ({len(pre_sheet_headers)}개 시트) → Pass1 스킵")
        except Exception as _he:
            logger.warning(f"DS bg xlsx: sheetHeaders 로드 실패 ({_he}) → Pass1 실행")

        logger.info(f"DS bg xlsx: 서브프로세스 시작 {tag}")
        proc = multiprocessing.Process(
            target=_subprocess_xlsx_entry,
            args=(zip_temp, xlsx_temp, result_json, cancel_flag),
            kwargs={"hdqt_filter": hdqt_filter, "city_hdqt_map": city_hdqt_map,
                    "pre_sheet_headers": pre_sheet_headers},
            daemon=True,
        )
        _xlsx_build_process = proc
        proc.start()

        start_wait_time = _time_mod.time()
        while proc.is_alive():
            if cancel_ev.is_set():
                try:
                    with open(cancel_flag, "w") as f:
                        f.write("1")
                except Exception:
                    pass
                proc.join(timeout=10)
                if proc.is_alive():
                    proc.terminate()
                    proc.join(timeout=5)
                raise InterruptedError("xlsx build cancelled")

            if _time_mod.time() - start_wait_time > 10800:
                logger.error(f"DS bg xlsx 타임아웃 발생 (강제 종료): {tag}")
                proc.terminate()
                proc.join(timeout=5)
                raise TimeoutError("엑셀 빌드 타임아웃 초과로 서브프로세스를 강제 종료했습니다.")

            await asyncio.sleep(2)

        _xlsx_build_process = None
        if proc.exitcode != 0:
            raise RuntimeError(f"서브프로세스 비정상 종료 (exit code {proc.exitcode})")

        if not os.path.exists(result_json):
            raise RuntimeError("서브프로세스 결과 파일 없음")
        with open(result_json, "r") as f:
            result = json.load(f)
        if not result.get("success"):
            if result.get("cancelled"):
                raise InterruptedError("xlsx build cancelled in subprocess")
            raise RuntimeError(f"서브프로세스 빌드 실패: {result.get('error', 'unknown')}")

        if cancel_ev.is_set():
            raise InterruptedError("xlsx build cancelled after processing")

        s3_key = f"ds-exports/{division_id}/{division_code}_{import_date}{suffix}.xlsx"
        s3 = get_s3_client()
        await asyncio.to_thread(
            s3.upload_file, xlsx_temp, S3_BUCKET_NAME, s3_key,
            ExtraArgs={"ContentType": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
        )
        total_rows = result.get("total_rows", 0)
        logger.info(f"DS bg xlsx cache: {tag} 완료 ({total_rows}행)")
        return total_rows
    finally:
        for tmp in [xlsx_temp, result_json, cancel_flag]:
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
            except Exception:
                pass


async def _merge_hdqt_xlsx_from_s3(
    division_id: str, division_code: str, import_date: str, cancel_ev
):
    """S3에 캐시된 4개 본부 xlsx를 내려받아 하나로 병합 → S3 저장.
    openpyxl read_only + write_only 스트리밍: 한 번에 한 본부만 메모리에 올림.
    """
    import openpyxl
    hdqt_order = ['강남', '강북', '경기', '인천']
    tmp_inputs = []
    full_xlsx_temp = f"/tmp/ds_bgxlsx_{division_id}_{division_code}_{import_date}_full.xlsx"
    s3_key_full = f"ds-exports/{division_id}/{division_code}_{import_date}.xlsx"

    try:
        # 1. 4개 본부 xlsx S3 → /tmp 다운로드 (순차)
        for hdqt in hdqt_order:
            if cancel_ev.is_set():
                raise InterruptedError("xlsx merge cancelled")
            hdqt_key = _HDQT_S3_KEY[hdqt]
            s3_key = f"ds-exports/{division_id}/{division_code}_{import_date}_{hdqt_key}.xlsx"
            tmp_path = f"/tmp/ds_bgxlsx_merge_{division_id}_{division_code}_{import_date}_{hdqt_key}.xlsx"
            logger.info(f"DS xlsx 전체합 병합: {hdqt} 다운로드 → {tmp_path}")
            def _dl(key=s3_key, path=tmp_path):
                s3c = boto3.client('s3', region_name=S3_REGION, config=_BotoConfig(
                    connect_timeout=30, read_timeout=300, retries={'max_attempts': 2}
                ))
                s3c.download_file(S3_BUCKET_NAME, key, path)
            await asyncio.to_thread(_dl)
            tmp_inputs.append((hdqt, tmp_path))

        if cancel_ev.is_set():
            raise InterruptedError("xlsx merge cancelled after download")

        # 2. write_only 워크북 생성 → 4개 본부 순서대로 read_only 스트리밍 append
        logger.info(f"DS xlsx 전체합 병합: openpyxl 스트리밍 병합 시작")
        def _merge():
            wb_out = openpyxl.Workbook(write_only=True)
            ws_out = wb_out.create_sheet("DS데이터")
            header_written = False
            total = 0
            for hdqt, tmp_path in tmp_inputs:
                wb_in = openpyxl.load_workbook(tmp_path, read_only=True, data_only=True)
                ws_in = wb_in.active
                first_row = True
                for row in ws_in.iter_rows(values_only=True):
                    if first_row:
                        first_row = False
                        if not header_written:
                            ws_out.append(list(row))
                            header_written = True
                        continue  # 본부별 헤더행은 첫 번째 이후 스킵
                    ws_out.append(list(row))
                    total += 1
                wb_in.close()
            wb_out.save(full_xlsx_temp)
            return total
        total_rows = await asyncio.to_thread(_merge)
        logger.info(f"DS xlsx 전체합 병합: {total_rows}행 병합 완료 → S3 업로드")

        if cancel_ev.is_set():
            raise InterruptedError("xlsx merge cancelled before upload")

        # 3. S3 업로드
        def _upload():
            s3c = boto3.client('s3', region_name=S3_REGION, config=_BotoConfig(
                connect_timeout=30, read_timeout=600, retries={'max_attempts': 2}
            ))
            s3c.upload_file(
                full_xlsx_temp, S3_BUCKET_NAME, s3_key_full,
                ExtraArgs={"ContentType": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"},
            )
        await asyncio.to_thread(_upload)
        logger.info(f"DS xlsx 전체합 병합: S3 업로드 완료 → {s3_key_full} ({total_rows}행)")

    finally:
        for _, p in tmp_inputs:
            try:
                if os.path.exists(p):
                    os.remove(p)
            except Exception:
                pass
        try:
            if os.path.exists(full_xlsx_temp):
                os.remove(full_xlsx_temp)
        except Exception:
            pass


async def _build_xlsx_cache_background(division_id: str, division_code: str, import_date: str):
    """S3 ZIP → xlsx 빌드 → S3 캐싱.
    실패해도 export 시 on-demand 빌드 가능하므로 non-fatal.
    """
    global _xlsx_build_cancel_event, _xlsx_build_current, _xlsx_build_process, _xlsx_build_start_time
    _xlsx_build_current = (division_id, division_code, import_date)
    _xlsx_build_start_time = _time_mod.time()
    cancel_ev = threading.Event()
    _xlsx_build_cancel_event = cancel_ev
    _xlsx_build_process = None

    zip_s3_key = f"ds-raw/{division_id}/{division_code}_{import_date}.zip"
    zip_temp = f"/tmp/ds_bgxlsx_{division_id}_{division_code}_{import_date}.zip"
    try:
        # 1. S3 → ZIP 다운로드 (매번 새 클라이언트: CLOSE-WAIT 잔여 커넥션 회피)
        logger.info(f"DS xlsx build: S3 다운로드 시작 → {zip_s3_key}")
        def _download_zip():
            s3 = boto3.client('s3', region_name=S3_REGION, config=_BotoConfig(
                connect_timeout=30, read_timeout=600,
                retries={'max_attempts': 2},
            ))
            s3.download_file(S3_BUCKET_NAME, zip_s3_key, zip_temp)
        await asyncio.to_thread(_download_zip)
        logger.info(f"DS xlsx build: S3 다운로드 완료 → {zip_temp}")
        if cancel_ev.is_set():
            raise InterruptedError("xlsx build cancelled before processing")

        await _build_one_xlsx_cache(
            division_id, division_code, import_date,
            zip_temp, cancel_ev,
        )
    except asyncio.CancelledError:
        logger.warning(f"DS bg xlsx cache CancelledError: {division_id}/{division_code}_{import_date} — 태스크 취소됨")
        raise  # 상위 _xlsx_build_worker도 중단시켜야 함
    except InterruptedError as e:
        logger.info(f"DS bg xlsx cache 중단: {division_id}/{division_code}_{import_date} ({e})")
    except Exception as e:
        logger.warning(f"DS bg xlsx cache 실패 (non-fatal, export 시 on-demand 빌드): {e}")
    finally:
        _xlsx_build_cancel_event = None
        _xlsx_build_current = None
        _xlsx_build_start_time = None
        if _xlsx_build_process and _xlsx_build_process.is_alive():
            try:
                _xlsx_build_process.terminate()
                _xlsx_build_process.join(timeout=5)
            except Exception:
                pass
        _xlsx_build_process = None
        try:
            if os.path.exists(zip_temp):
                os.remove(zip_temp)
        except Exception:
            pass
        _release_memory()


async def _xlsx_build_worker():
    """xlsx 빌드 큐를 순차 처리하는 별도 태스크.
    워커 루프와 독립 실행 → 새 잡이 들어와도 워커가 즉시 처리 가능.
    """
    global _xlsx_build_task
    try:
        while _xlsx_build_queue:
            args = _xlsx_build_queue.pop(0)
            label = f"{args[0]}/{args[1]}_{args[2]}"
            logger.info(f"DS xlsx build queue: {label} 빌드 시작 (남은 {len(_xlsx_build_queue)}건)")
            await _build_xlsx_cache_background(*args)
        _xlsx_build_task = None
        logger.info("DS xlsx build queue: 모든 빌드 완료")
    except asyncio.CancelledError:
        logger.warning(f"DS xlsx build worker CancelledError — 태스크 외부에서 취소됨")
    except Exception as e:
        logger.error(f"DS xlsx build worker 예외 발생: {e}", exc_info=True)


async def _job_worker_loop():
    """싱글턴 백그라운드 워커 — 한 번에 1개 DS 잡만 처리 (OOM 방지)
    10분마다 stuck "processing" 잡 자동 복구
    """
    logger.info("DS job worker loop started")
    global _xlsx_build_task, _xlsx_build_cancel_event
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
                # 잡 큐가 비었을 때 xlsx 빌드 태스크 시작 (이미 실행 중이면 무시)
                if _xlsx_build_queue and (_xlsx_build_task is None or _xlsx_build_task.done()):
                    # cert 캐시 빌드 완료 대기 (GIL 경합으로 xlsx 코루틴 실행 기회 차단 방지)
                    if not _cert_cache_mod._cert_cache_db_path:
                        await asyncio.sleep(5)
                        continue
                    _xlsx_build_task = asyncio.create_task(_xlsx_build_worker())
                await asyncio.sleep(5)
                continue

            # 새 잡이 들어왔는데 xlsx 빌드 중이면 빌드 중단 → 큐 끝에 재등록
            if _xlsx_build_task and not _xlsx_build_task.done():
                # 취소된 빌드를 큐 끝에 다시 넣기
                cancelled_target = _xlsx_build_current
                # 1. 취소 이벤트 set
                if _xlsx_build_cancel_event:
                    _xlsx_build_cancel_event.set()
                # 2. 서브프로세스 직접 강제 종료 (확실한 종료 보장)
                if _xlsx_build_process and _xlsx_build_process.is_alive():
                    logger.info("DS xlsx build: 서브프로세스 강제 종료 (SIGKILL)")
                    try:
                        _xlsx_build_process.kill()  # SIGKILL — 즉시 종료
                        _xlsx_build_process.join(timeout=5)
                    except Exception:
                        pass
                # 3. asyncio task도 cancel
                _xlsx_build_task.cancel()
                await asyncio.sleep(1)  # task 정리 대기
                # 3. 취소된 빌드 재등록 (큐에 없으면)
                if cancelled_target and cancelled_target not in _xlsx_build_queue:
                    _xlsx_build_queue.append(cancelled_target)
                    logger.info(f"DS xlsx build: 새 잡 도착 → 빌드 중단 → "
                                f"{cancelled_target[0]}/{cancelled_target[1]}_{cancelled_target[2]} 큐 재등록")
                else:
                    logger.info("DS xlsx build: 새 잡 도착 → 빌드 중단")

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


@router.get("/ds/upload-presign")
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


@router.get("/ds/xlsx-upload-presign")
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


@router.get("/ds/export-presign")
async def ds_export_presign(
    request: Request,
    divisionId: str = Query(...),
    importDate: str = Query(...),
    divisionCode: str = Query(""),
):
    """S3 Export용 presigned URL - xlsx 우선, 없으면 원본 ZIP"""
    await _verify_auth(request)
    try:
        s3 = get_s3_client()

        # 1순위: 미리 생성된 xlsx → EC2 프록시로 반환 (S3 CORS 우회)
        xlsx_key = f"ds-exports/{divisionId}/{divisionCode}_{importDate}.xlsx"
        _validate_s3_key(xlsx_key, ALLOWED_S3_READ_PREFIXES)
        try:
            s3.head_object(Bucket=S3_BUCKET_NAME, Key=xlsx_key)
            # EC2 프록시 URL — X-Forwarded-Host 기준으로 origin 추정
            forwarded_proto = request.headers.get("x-forwarded-proto", "https")
            forwarded_host = request.headers.get("x-forwarded-host") or request.headers.get("host", "")
            origin = f"{forwarded_proto}://{forwarded_host}"
            qs = f"divisionId={divisionId}&importDate={importDate}&divisionCode={divisionCode}"
            # 토큰을 쿼리파라미터로 포함 (브라우저 fetch 시 헤더 설정 불필요)
            raw_token = request.headers.get("Authorization", "")[7:]  # "Bearer " 제거
            if raw_token:
                qs += f"&token={raw_token}"
            proxy_url = f"{origin}/ds/proxy-xlsx?{qs}"
            return {"success": True, "url": proxy_url, "type": "xlsx"}
        except ClientError:
            pass

        # 2순위: 원본 ZIP → 브라우저에서 병합 (hdqt 있으면 JS 필터링)
        zip_key = f"ds-raw/{divisionId}/{divisionCode}_{importDate}.zip"
        try:
            s3.head_object(Bucket=S3_BUCKET_NAME, Key=zip_key)

            _target = (divisionId, divisionCode, importDate)
            building = (_xlsx_build_current == _target or _target in _xlsx_build_queue)

            url = s3.generate_presigned_url(
                "get_object",
                Params={"Bucket": S3_BUCKET_NAME, "Key": zip_key},
                ExpiresIn=3600,
            )
            return {
                "success": True, "url": url, "type": "zip",
                "building": building,
            }
        except ClientError:
            pass

        return {"success": False, "message": "S3에 파일 없음. DB Export로 대체합니다."}
    except Exception as e:
        logger.error(f"DS export presign error: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.get("/ds/xlsx-build-status")
async def ds_xlsx_build_status(request: Request, divisionId: str, divisionCode: str, importDate: str):
    """xlsx 캐시 존재 여부 + 현재 빌드 큐 상태 반환."""
    await _verify_auth(request)
    s3 = get_s3_client()
    key = f"ds-exports/{divisionId}/{divisionCode}_{importDate}.xlsx"
    cached = False
    try:
        s3.head_object(Bucket=S3_BUCKET_NAME, Key=key)
        cached = True
    except Exception:
        pass

    _target = (divisionId, divisionCode, importDate)
    is_building = _xlsx_build_current == _target
    in_queue = _target in _xlsx_build_queue

    SECS_TOTAL = 300
    estimated_remaining_sec = None
    elapsed_sec = None
    if is_building and _xlsx_build_start_time:
        elapsed_sec = int(_time_mod.time() - _xlsx_build_start_time)
        estimated_remaining_sec = max(0, SECS_TOTAL - elapsed_sec)
    elif in_queue:
        estimated_remaining_sec = SECS_TOTAL

    return {
        "building": is_building or in_queue,
        "in_queue": in_queue,
        "cached": cached,
        "elapsed_sec": elapsed_sec,
        "estimated_remaining_sec": estimated_remaining_sec,
    }


@router.get("/ds/xlsx-build-status-bulk")
async def ds_xlsx_build_status_bulk(request: Request, items: str = Query(default="")):
    """여러 업로드의 xlsx 빌드 상태 일괄 조회.

    items: 'divisionId:divisionCode:importDate' 형태를 쉼표로 구분한 문자열
    응답: {"results": {"divId:dc:date": "building"|"completed"|"unknown", ...}}
    """
    await _verify_auth(request)
    if not items.strip():
        return {"results": {}}

    parsed = [s.strip() for s in items.split(",") if s.strip()]
    if not parsed:
        return {"results": {}}

    s3 = get_s3_client()

    def _check_one_sync(key: str):
        parts = key.split(":")
        if len(parts) != 3:
            return key, "unknown"
        division_id, division_code, import_date = parts
        s3_key = f"ds-exports/{division_id}/{division_code}_{import_date}.xlsx"
        cached = False
        try:
            s3.head_object(Bucket=S3_BUCKET_NAME, Key=s3_key)
            cached = True
        except Exception:
            pass
        _target = (division_id, division_code, import_date)
        is_building = _xlsx_build_current == _target
        in_queue = _target in _xlsx_build_queue
        if cached:
            return key, "completed"
        if is_building or in_queue:
            return key, "building"
        return key, "unknown"

    # S3 head_object는 IO bound → 스레드 풀 병렬 실행
    tasks = [asyncio.to_thread(_check_one_sync, k) for k in parsed]
    results_list = await asyncio.gather(*tasks)
    return {"results": dict(results_list)}


_city_hdqt_cache: dict | None = None
_city_hdqt_cache_ts: float = 0.0
_CITY_HDQT_CACHE_TTL = 3600 * 6  # 6시간

@router.get("/ds/city-hdqt-map")
async def ds_city_hdqt_map(request: Request):
    """inspection_targets 전체에서 시/군별 최다 access담당 집계 반환.
    응답: { "경기 시흥시": {"본부": "인천", "건수": 1847, "비율": 99.2}, ... }
    6시간 캐시.
    """
    await _verify_auth(request)
    import sqlite3, time
    global _city_hdqt_cache, _city_hdqt_cache_ts
    now = _time_mod.time()
    if _city_hdqt_cache is not None and (now - _city_hdqt_cache_ts) < _CITY_HDQT_CACHE_TTL:
        return _city_hdqt_cache

    conn = sqlite3.connect(_INSP_DB, timeout=30)
    try:
        rows = conn.execute(
            "SELECT 도로명주소, access담당 FROM inspection_targets "
            "WHERE 도로명주소 IS NOT NULL AND 도로명주소 != '' "
            "AND access담당 IS NOT NULL AND access담당 != ''"
        ).fetchall()
    finally:
        conn.close()

    from collections import defaultdict
    # 시/군 추출: "경기도 시흥시 ..." → "경기 시흥시", "서울특별시 강남구 ..." → "서울 강남구"
    city_counts: dict = defaultdict(lambda: defaultdict(int))
    for addr, hdqt in rows:
        parts = addr.split()
        if len(parts) < 2:
            continue
        p0 = parts[0]  # 경기도 / 서울특별시 / 인천광역시 등
        p1 = parts[1]  # 시흥시 / 강남구 / 남동구 등
        # 광역시/도 약칭
        if p0.startswith('서울'): region = '서울'
        elif p0.startswith('인천'): region = '인천'
        elif p0.startswith('경기'): region = '경기'
        else: continue
        key = f"{region} {p1}"
        city_counts[key][hdqt] += 1

    result = {}
    for city, hdqt_cnt in sorted(city_counts.items()):
        total = sum(hdqt_cnt.values())
        top_hdqt = max(hdqt_cnt, key=hdqt_cnt.get)
        top_cnt = hdqt_cnt[top_hdqt]
        result[city] = {
            "본부": top_hdqt,
            "건수": top_cnt,
            "비율": round(top_cnt / total * 100, 1),
            "상세": {h: c for h, c in sorted(hdqt_cnt.items(), key=lambda x: -x[1])},
        }

    _city_hdqt_cache = result
    _city_hdqt_cache_ts = now
    return result


@router.get("/ds/proxy-xlsx")
async def ds_proxy_xlsx(
    request: Request,
    divisionId: str = Query(...),
    importDate: str = Query(...),
    divisionCode: str = Query(""),
    token: str = Query(""),
):
    """S3 캐시 xlsx → EC2 프록시 스트리밍 (브라우저 CORS 우회)
    Authorization 헤더 또는 token 쿼리파라미터로 인증.
    """
    # 헤더에 없으면 쿼리파라미터 token으로 fallback
    if token and not request.headers.get("Authorization"):
        empno = _verify_token(token)
        if not empno:
            raise HTTPException(status_code=401, detail="토큰이 만료되었거나 유효하지 않습니다")
    else:
        await _verify_auth(request)
    s3_key = f"ds-exports/{divisionId}/{divisionCode}_{importDate}.xlsx"
    _validate_s3_key(s3_key, ALLOWED_S3_READ_PREFIXES)
    s3 = get_s3_client()
    try:
        head = s3.head_object(Bucket=S3_BUCKET_NAME, Key=s3_key)
    except ClientError:
        raise HTTPException(status_code=404, detail="xlsx 파일 없음")

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
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Length": str(content_length)},
    )


@router.get("/ds/proxy-raw-zip")
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


@router.post("/ds/upload-init")
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
    table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_records"])
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


@router.post("/ds/upload-chunk")
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


@router.post("/ds/upload-finalize")
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


@router.get("/ds/stats")
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


@router.get("/ds/export")
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
            records_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_records"])
            uploads_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_uploads"])

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


@router.get("/ds/data")
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


@router.delete("/ds/data")
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

@router.get("/ds/presign-raw")
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


@router.post("/ds/upload-raw")
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


@router.post("/ds/upload-temp")
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


@router.post("/ds/enqueue")
async def ds_enqueue(request: Request, req: DsEnqueueRequest):
    """DS 처리 잡을 큐에 추가 — 즉시 jobId 반환, 실제 처리는 백그라운드 워커"""
    # 권한 체크: admin, manager만 업로드 가능
    await _require_role(request, {"admin", "manager"})
    if not HAS_XLRD:
        raise HTTPException(status_code=503, detail="서버에 xlrd가 설치되지 않았습니다. 관리자에게 문의하세요.")

    try:
        jobs_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_jobs"])
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


@router.post("/ds/enqueue-multi")
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
        jobs_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_jobs"])
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


def _s3_key_exists(s3, key: str) -> bool:
    try:
        s3.head_object(Bucket=S3_BUCKET_NAME, Key=key)
        return True
    except Exception:
        return False


def _scan_missing_xlsx_caches_sync() -> tuple:
    """uploads 테이블 스캔 → S3 xlsx 캐시 없는 항목 찾아 빌드 큐 등록 (동기)"""
    uploads_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_uploads"])
    s3 = get_s3_client()

    scan_kwargs = {
        "ProjectionExpression": "divisionId, importDate, storageType",
        "FilterExpression": "storageType = :st",
        "ExpressionAttributeValues": {":st": "s3-zip"},
    }
    items = []
    while True:
        resp = uploads_table.scan(**scan_kwargs)
        items.extend(resp.get("Items", []))
        if "LastEvaluatedKey" not in resp:
            break
        scan_kwargs["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

    queued = []
    skipped = []
    for item in items:
        division_id = item.get("divisionId", "")
        sk = item.get("importDate", "")  # divisionCode#importDate
        parts = sk.split("#")
        if len(parts) < 2:
            continue
        division_code = parts[0]
        import_date = parts[1]

        # xlsx 캐시 존재 체크: 단일 xlsx 파일 (수도권 포함 전 지역 동일)
        xlsx_key = f"ds-exports/{division_id}/{division_code}_{import_date}.xlsx"
        if _s3_key_exists(s3, xlsx_key):
            skipped.append(f"{division_id}/{division_code}_{import_date}")
            continue

        zip_key = f"ds-raw/{division_id}/{division_code}_{import_date}.zip"
        try:
            s3.head_object(Bucket=S3_BUCKET_NAME, Key=zip_key)
        except Exception:
            continue

        entry = (division_id, division_code, import_date)
        if entry not in _xlsx_build_queue and _xlsx_build_current != entry:
            _xlsx_build_queue.append(entry)
            queued.append(f"{division_id}/{division_code}_{import_date}")

    logger.info(f"DS xlsx cache scan: {len(queued)}건 빌드 필요, {len(skipped)}건 캐시 존재")
    return queued, skipped


@router.post("/ds/trigger-xlsx-build")
async def ds_trigger_xlsx_build(request: Request):
    """xlsx 캐시가 없는 업로드 데이터를 찾아 백그라운드 빌드 큐에 등록.
    재업로드 없이 xlsx 캐시를 생성할 때 사용.
    """
    await _require_role(request, {"admin", "manager"})
    queued, skipped = await asyncio.to_thread(_scan_missing_xlsx_caches_sync)
    return {
        "success": True,
        "queued": queued,
        "skipped": skipped,
        "message": f"{len(queued)}건 xlsx 빌드 큐에 등록됨 (백그라운드 순차 처리)",
    }


@router.get("/ds/export-xlsx")
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
        uploads_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_uploads"])
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
                    "Content-Disposition": f"attachment; filename*=UTF-8''{quote(filename)}",
                    "Content-Length": str(content_length),
                },
            )
        except Exception as e:
            logger.info(f"DS export: S3 xlsx 미존재 ({xlsx_s3_key}), 빌드 진행: {e}")

    # ── s3-zip: ZIP에서 on-demand xlsx 빌드 → 디스크 스트리밍 + S3 캐싱 ──
    if storage_type == "s3-zip":
        # 백그라운드 xlsx 빌드 진행 중이면 중복 빌드 방지
        _build_target = (divisionId, divisionCode, importDate)
        if _xlsx_build_current == _build_target or _build_target in _xlsx_build_queue:
            raise HTTPException(
                status_code=409,
                detail="해당 데이터의 xlsx 빌드가 진행 중입니다. 잠시 후 다시 시도해 주세요."
            )

        # 메모리 사전 체크 — OOM 방지
        if HAS_PSUTIL:
            mem = psutil.virtual_memory()
            if mem.available < 200 * 1024 * 1024:  # 가용 200MB 미만
                gc.collect()
                mem = psutil.virtual_memory()
                if mem.available < 200 * 1024 * 1024:
                    raise HTTPException(
                        status_code=503,
                        detail=f"서버 메모리 부족 (가용 {mem.available // (1024*1024)}MB). "
                               f"잠시 후 다시 시도해 주세요."
                    )

        zip_s3_key = f"ds-raw/{divisionId}/{divisionCode}_{importDate}.zip"
        zip_temp = f"/tmp/ds_export_{divisionId}_{divisionCode}_{importDate}.zip"
        xlsx_temp = f"/tmp/ds_export_{divisionId}_{divisionCode}_{importDate}.xlsx"
        result_json_exp = f"/tmp/ds_export_{divisionId}_{divisionCode}_{importDate}_result.json"
        cancel_flag_exp = f"/tmp/ds_export_{divisionId}_{divisionCode}_{importDate}_cancel"
        try:
            s3_client = get_s3_client()
            await asyncio.to_thread(s3_client.download_file, S3_BUCKET_NAME, zip_s3_key, zip_temp)

            # 서브프로세스에서 xlsx 빌드 (메모리 격리)
            proc = multiprocessing.Process(
                target=_subprocess_xlsx_entry,
                args=(zip_temp, xlsx_temp, result_json_exp, cancel_flag_exp),
                daemon=True,
            )
            proc.start()
            while proc.is_alive():
                await asyncio.sleep(2)
            if proc.exitcode != 0:
                raise RuntimeError(f"export 서브프로세스 비정상 종료 (exit code {proc.exitcode})")
            if not os.path.exists(result_json_exp):
                raise RuntimeError("export 서브프로세스 결과 파일 없음")
            with open(result_json_exp, "r") as _rf:
                _exp_result = json.load(_rf)
            if not _exp_result.get("success"):
                raise RuntimeError(f"export 빌드 실패: {_exp_result.get('error', 'unknown')}")
            xlsx_path = xlsx_temp

            # 임시파일 즉시 삭제
            for _tmp_f in [zip_temp, result_json_exp, cancel_flag_exp]:
                try:
                    if os.path.exists(_tmp_f):
                        os.remove(_tmp_f)
                except Exception:
                    pass

            content_length = os.path.getsize(xlsx_path)

            # S3에 캐싱 (백그라운드 — 완료 후 xlsx 파일 삭제)
            async def _cache_and_cleanup_xlsx():
                try:
                    await asyncio.to_thread(
                        _upload_xlsx_file_to_s3_sync, xlsx_path, divisionId, divisionCode, importDate
                    )
                    logger.info(f"DS export: xlsx S3 캐싱 완료 {xlsx_s3_key}")
                except Exception as ce:
                    logger.warning(f"DS export: xlsx S3 캐싱 실패 (non-fatal): {ce}")
                finally:
                    # 캐싱 완료/실패 후 xlsx 임시파일 삭제 (스트리밍 완료 대기)
                    await asyncio.sleep(30)
                    try:
                        if os.path.exists(xlsx_path):
                            os.remove(xlsx_path)
                            logger.info(f"DS export: xlsx 임시파일 삭제 {xlsx_path}")
                    except Exception:
                        pass

            asyncio.create_task(_cache_and_cleanup_xlsx())

            def _stream_xlsx():
                with open(xlsx_path, "rb") as f:
                    while True:
                        chunk = f.read(1024 * 1024)  # 1MB chunks
                        if not chunk:
                            break
                        yield chunk

            return StreamingResponse(
                _stream_xlsx(),
                media_type=xlsx_media,
                headers={
                    "Content-Disposition": f"attachment; filename*=UTF-8''{quote(filename)}",
                    "Content-Length": str(content_length),
                },
            )
        except Exception as e:
            logger.error(f"DS export s3-zip build failed: {e}")
            # 에러 시 zip + xlsx 모두 즉시 정리
            for _tmp in [zip_temp, xlsx_temp]:
                try:
                    if os.path.exists(_tmp):
                        os.remove(_tmp)
                except Exception:
                    pass
            raise HTTPException(status_code=500, detail="서버 내부 오류")

    # ── DynamoDB fallback: 기존 빌드 경로 (파일 기반, 메모리 최소화) ──
    xlsx_path = await asyncio.to_thread(
        _build_xlsx_sync, divisionId, divisionCode, importDate,
        sheet_stats, sheet_headers
    )

    content_length = os.path.getsize(xlsx_path)

    # S3에 저장 + 임시파일 정리 (비치명적)
    async def _save_to_s3():
        try:
            await asyncio.to_thread(
                _upload_xlsx_file_to_s3_sync, xlsx_path, divisionId, divisionCode, importDate
            )
            logger.info(f"DS export-xlsx: S3 저장 완료 {xlsx_s3_key}")
        except Exception as e:
            logger.warning(f"DS export-xlsx: S3 저장 실패 (non-fatal): {e}")
        finally:
            await asyncio.sleep(30)
            try:
                if os.path.exists(xlsx_path):
                    os.remove(xlsx_path)
            except Exception:
                pass

    asyncio.create_task(_save_to_s3())

    def _stream_xlsx_fallback():
        with open(xlsx_path, "rb") as f:
            while True:
                chunk = f.read(1024 * 1024)
                if not chunk:
                    break
                yield chunk

    return StreamingResponse(
        _stream_xlsx_fallback(),
        media_type=xlsx_media,
        headers={
            "Content-Disposition": f"attachment; filename*=UTF-8''{quote(filename)}",
            "Content-Length": str(content_length),
        },
    )


@router.get("/ds/job/{job_id}")
async def ds_job_status(job_id: str, request: Request = None):
    """DS 잡 상태 조회 — 브라우저가 3초 간격으로 폴링"""
    await _verify_auth(request)
    try:
        jobs_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_jobs"])
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


@router.delete("/ds/job/{job_id}")
async def ds_job_cancel(job_id: str, request: Request = None):
    """DS 잡 취소 — queued/processing 상태 모두 가능"""
    await _verify_auth(request)
    try:
        jobs_table = get_dynamodb_resource().Table(DYNAMODB_TABLES["ds_jobs"])
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

@router.post("/ds/preview-partial-update")
async def ds_preview_partial_update(request: Request, file: UploadFile = File(...)):
    """부분 DS 파일을 파싱하여 변경 전/후 diff를 반환 (DB 미적용).
    비교 대상: 기기일련번호, 형식검정번호, 공중선주설치형태명, 설치장소 (장치상태 제외)
    - 권한: admin/manager만 가능 (apply와 동일 정책)
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")
    file_bytes = await file.read()
    if not file_bytes:
        raise HTTPException(400, "빈 파일")

    def _preview():
        import xlrd as _xlrd
        import zipfile as _zf
        import io as _io
        xls_bytes = file_bytes
        if _zf.is_zipfile(_io.BytesIO(xls_bytes)):
            with _zf.ZipFile(_io.BytesIO(xls_bytes)) as zf:
                xls_names = [n for n in zf.namelist() if n.lower().endswith('.xls') and not n.lower().endswith('.xlsx')]
                if not xls_names:
                    raise HTTPException(400, "ZIP 내부에 XLS 파일이 없습니다")
                xls_bytes = zf.read(xls_names[0])
        try:
            wb = _xlrd.open_workbook(file_contents=xls_bytes)
        except Exception as e:
            raise HTTPException(400, "파일 파싱에 실패했습니다. 올바른 XLS/ZIP 형식인지 확인하세요")

        def _norm_hn(val):
            if isinstance(val, float) and val == int(val):
                return str(int(val))
            return str(val).strip().replace('-', '')

        def _find_col(ws, *keywords):
            for keyword in keywords:
                for c in range(ws.ncols):
                    if keyword in str(ws.cell_value(0, c)).strip():
                        return c
            return -1

        def _find_sheet(keyword):
            for sn in wb.sheet_names():
                if keyword in sn:
                    return wb.sheet_names().index(sn)
            return -1

        장치_si = _find_sheet('장치')
        안테나_si = _find_sheet('안테나')
        설치장소_si = _find_sheet('설치장소')

        # 장치: (허가번호, 장치번호) → {기기일련번호, 형식검정번호}  (장치상태 제외)
        device_data: dict[tuple, dict] = {}
        # 안테나: (허가번호, 장치번호) → 설치형태 텍스트 (숫자 코드 정규화)
        # 장치번호별로 다른 안테나가 연결될 수 있어 행별 처리
        antenna_data: dict[tuple[str, str], str] = {}
        # 설치장소: 허가번호 → 설치장소주소
        location_data: dict[str, str] = {}
        license_set: set[str] = set()

        if 장치_si >= 0:
            ws = wb.sheet_by_index(장치_si)
            jn_col = _find_col(ws, '장치번호') or 3
            sn_col = _find_col(ws, '일련번호')
            형식_col = _find_col(ws, '형식검정번호')
            for ri in range(1, ws.nrows):
                hn = _norm_hn(ws.cell_value(ri, 0))
                if not hn: continue
                license_set.add(hn)
                jn = _norm_hn(ws.cell_value(ri, jn_col)) if ws.ncols > jn_col else ''
                d = {}
                if sn_col >= 0 and ws.ncols > sn_col:
                    v = str(ws.cell_value(ri, sn_col) or '').strip()
                    if v: d['기기일련번호'] = v
                if 형식_col >= 0 and ws.ncols > 형식_col:
                    v = str(ws.cell_value(ri, 형식_col) or '').strip()
                    if v: d['형식검정번호'] = v
                if d: device_data[(hn, jn)] = d

        if 안테나_si >= 0:
            ws = wb.sheet_by_index(안테나_si)
            설치형태_col = _find_col(ws, '설치형태명', '설치형태')
            if 설치형태_col < 0: 설치형태_col = 28
            jn_col_a = _find_col(ws, '장치번호')
            for ri in range(1, ws.nrows):
                hn = _norm_hn(ws.cell_value(ri, 0))
                if not hn: continue
                license_set.add(hn)
                if ws.ncols > 설치형태_col:
                    raw = str(ws.cell_value(ri, 설치형태_col) or '').strip()
                    v = _normalize_설치형태(raw)  # 숫자코드 → 텍스트
                    jn = (_norm_hn(ws.cell_value(ri, jn_col_a))
                          if jn_col_a >= 0 and ws.ncols > jn_col_a else '')
                    key = (hn, jn)
                    if v and key not in antenna_data:
                        antenna_data[key] = v

        # 설치장소: 같은 허가번호에 여러 행 가능 — (허가번호, 설치장소구분) 단위로 모두 수집
        # location_rows: list[(허가번호, 설치장소구분, 설치장소주소)]
        location_rows: list[tuple[str, str, str]] = []
        if 설치장소_si >= 0:
            ws = wb.sheet_by_index(설치장소_si)
            hn_col = _find_col(ws, '허가번호')
            # 부분 DS 파일 컬럼명: 설치장소주소 (원본 DS는 설치장소입력주소)
            addr_col = _find_col(ws, '설치장소주소', '설치장소입력주소')
            gubun_col = _find_col(ws, '설치장소구분')
            if hn_col >= 0 and addr_col >= 0:
                for ri in range(1, ws.nrows):
                    hn = _norm_hn(ws.cell_value(ri, hn_col))
                    v = str(ws.cell_value(ri, addr_col) or '').strip()
                    if not (hn and v):
                        continue
                    license_set.add(hn)
                    gubun = (str(ws.cell_value(ri, gubun_col) or '').strip()
                             if gubun_col >= 0 and ws.ncols > gubun_col else '')
                    location_rows.append((hn, gubun, v))

        if not license_set:
            raise HTTPException(400, "허가번호 없음")

        if not os.path.exists(_DS_DETAIL_DB):
            return {"diffs": [], "license_count": len(license_set)}

        dc = sqlite3.connect(_DS_DETAIL_DB, timeout=30)
        dc.row_factory = sqlite3.Row
        diffs = []

        for (hn, jn), fields in device_data.items():
            existing = dc.execute(
                'SELECT 기기일련번호, 형식검정번호 FROM ds_장치 WHERE 허가번호=? AND 장치번호=?',
                (hn, jn)
            ).fetchone()
            if not existing: continue
            for col, new_val in fields.items():
                old_val = str(existing[col] or '') if existing[col] is not None else ''
                if old_val != new_val:
                    diffs.append({"허가번호": hn, "장치번호": jn, "필드명": col, "변경전": old_val, "변경후": new_val})

        # 설치형태: (허가번호, 장치번호) 단위로 행별 비교
        # 장치번호별로 안테나가 다를 수 있어 행별 매칭
        for (hn, jn), new_형태 in antenna_data.items():
            existing = dc.execute(
                'SELECT 공중선주설치형태명 FROM ds_안테나 WHERE 허가번호=? AND 장치번호=? LIMIT 1',
                (hn, jn)
            ).fetchone()
            old_val = str(existing['공중선주설치형태명'] or '') if existing else ''
            if old_val != new_형태:
                diffs.append({
                    "허가번호": hn,
                    "장치번호": jn,
                    "필드명": "설치형태",
                    "변경전": old_val,
                    "변경후": new_형태,
                })

        # 설치장소: (허가번호, 설치장소구분) 단위로 행별 비교
        # 신고서 파일 각 행에 대해 ds_설치장소의 동일 (허가번호, 설치장소구분) 행과 비교
        for hn, gubun, new_addr in location_rows:
            existing = dc.execute(
                'SELECT 설치장소주소 FROM ds_설치장소 WHERE 허가번호=? AND 설치장소구분=?',
                (hn, gubun)
            ).fetchone()
            old_val = str(existing['설치장소주소'] or '') if existing and existing['설치장소주소'] else ''
            if old_val != new_addr:
                # 장치번호 필드를 설치장소구분으로 사용해 화면/적용 시 어느 행인지 식별
                diffs.append({
                    "허가번호": hn,
                    "장치번호": gubun,  # 설치장소구분 (예: '01')
                    "필드명": "설치장소",
                    "변경전": old_val,
                    "변경후": new_addr,
                })

        dc.close()
        return {"diffs": diffs, "license_count": len(license_set)}

    return await asyncio.to_thread(_preview)


@router.get("/ds/변경이력-count")
async def ds_change_history_count(request: Request, division_id: str = ""):
    """ds_변경이력 활성(취소 안 됨) 건수 조회. division_id 지정 시 본부별 카운트."""
    await _verify_auth(request)
    if not os.path.exists(_DS_DETAIL_DB):
        return {"count": 0}

    def _count():
        dc = sqlite3.connect(_DS_DETAIL_DB, timeout=10)
        try:
            wheres = ["(cancelled IS NULL OR cancelled='0')"]
            params: list = []
            if division_id:
                wheres.append("division_id=?")
                params.append(division_id)
            row = dc.execute(
                f"SELECT COUNT(*) FROM ds_변경이력 WHERE {' AND '.join(wheres)}",
                params
            ).fetchone()
            return row[0] if row else 0
        except Exception:
            return 0
        finally:
            dc.close()

    count = await asyncio.to_thread(_count)
    return {"count": count}


@router.get("/ds/change-history")
async def ds_change_history_list(
    request: Request,
    허가번호: str = "",
    division_id: str = "",
    upload_id: str = "",
    search: str = "",
    include_cancelled: bool = True,
    limit: int = 2000,
):
    """DS 변경 이력 목록.

    필터:
    - 허가번호: 단건 정확 매칭 (하이픈 정규화)
    - division_id: 본부 필터 (gyeongbuk 등)
    - upload_id: 특정 업로드 묶음만
    - search: 허가번호 부분 일치 검색 (하이픈 정규화 후 LIKE)
    - include_cancelled: 취소된 이력 포함 여부 (기본 True)
    """
    await _verify_auth(request)
    if not os.path.exists(_DS_DETAIL_DB):
        return {"items": [], "total": 0}

    def _do():
        dc = sqlite3.connect(_DS_DETAIL_DB, timeout=30); dc.row_factory = sqlite3.Row
        try:
            wheres: list = ['1=1']
            params: list = []
            if 허가번호.strip():
                wheres.append('허가번호=?')
                params.append(허가번호.replace('-', ''))
            if division_id.strip():
                wheres.append('division_id=?')
                params.append(division_id.strip())
            if upload_id.strip():
                wheres.append('upload_id=?')
                params.append(upload_id.strip())
            if search.strip():
                wheres.append('허가번호 LIKE ?')
                params.append(f"%{search.replace('-', '')}%")
            if not include_cancelled:
                wheres.append("(cancelled IS NULL OR cancelled='0')")
            sql = (f"SELECT * FROM ds_변경이력 WHERE {' AND '.join(wheres)} "
                   f"ORDER BY uploaded_at DESC, id DESC LIMIT ?")
            params.append(max(1, min(limit, 5000)))
            return [dict(r) for r in dc.execute(sql, params).fetchall()]
        finally:
            dc.close()

    items = await asyncio.to_thread(_do)
    return {"items": items, "total": len(items)}


@router.get("/ds/change-history/uploads")
async def ds_change_history_uploads(
    request: Request,
    division_id: str = "",
    include_cancelled: bool = True,
    limit: int = 100,
):
    """업로드 묶음(upload_id) 단위 요약 — 다이얼로그 트리뷰 헤더용.

    각 묶음: {upload_id, uploaded_at, uploaded_by, uploaded_filename, division_id,
              active_count, cancelled_count}
    """
    await _verify_auth(request)
    if not os.path.exists(_DS_DETAIL_DB):
        return {"items": []}

    def _do():
        dc = sqlite3.connect(_DS_DETAIL_DB, timeout=30); dc.row_factory = sqlite3.Row
        try:
            wheres: list = ["upload_id != ''"]
            params: list = []
            if division_id.strip():
                wheres.append('division_id=?')
                params.append(division_id.strip())
            sql = (f"SELECT upload_id, uploaded_at, uploaded_by, uploaded_filename, division_id, "
                   f"COUNT(*) AS total, "
                   f"SUM(CASE WHEN cancelled='1' THEN 1 ELSE 0 END) AS cancelled_count, "
                   f"SUM(CASE WHEN cancelled IS NULL OR cancelled='0' THEN 1 ELSE 0 END) AS active_count "
                   f"FROM ds_변경이력 WHERE {' AND '.join(wheres)} "
                   f"GROUP BY upload_id "
                   f"ORDER BY uploaded_at DESC LIMIT ?")
            params.append(max(1, min(limit, 500)))
            rows = [dict(r) for r in dc.execute(sql, params).fetchall()]
            if not include_cancelled:
                rows = [r for r in rows if (r.get('active_count') or 0) > 0]
            return rows
        finally:
            dc.close()

    items = await asyncio.to_thread(_do)
    return {"items": items}


class BulkCancelReq(BaseModel):
    ids: list[int]


@router.post("/ds/change-history/bulk-cancel")
async def ds_change_history_bulk_cancel(request: Request, req: BulkCancelReq):
    """여러 변경 이력을 한 번에 되돌리기. 활성(미취소) 이력만 처리, 결과 요약 반환."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")
    if not req.ids:
        raise HTTPException(400, "ids 비어있음")

    results = {"succeeded": 0, "failed": 0, "skipped": 0, "errors": []}
    # 단건 cancel 라우터 로직을 재사용해 일관성 유지
    for hid in req.ids:
        try:
            await ds_change_history_cancel(hid, request)
            results["succeeded"] += 1
        except HTTPException as he:
            if he.status_code == 400 and '이미 취소된' in (he.detail or ''):
                results["skipped"] += 1
            else:
                results["failed"] += 1
                results["errors"].append({"id": hid, "detail": he.detail})
        except Exception as e:
            results["failed"] += 1
            results["errors"].append({"id": hid, "detail": str(e)})
    return {"success": True, **results}


@router.post("/ds/change-history/{history_id}/cancel")
async def ds_change_history_cancel(history_id: int, request: Request):
    """DS 변경 이력 단건 취소(되돌리기).

    - admin/manager만 수행 가능
    - 필드 매핑은 apply-partial-update와 동일 (ds_장치/ds_안테나/inspection_targets)
    - 워크플로우 상태(change_request/workflow_status)는 건드리지 않음
    - 이력 행은 보존하고 cancelled='1'로 마킹
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    def _do():
        dc = sqlite3.connect(_DS_DETAIL_DB, timeout=60); dc.row_factory = sqlite3.Row
        ic = None
        try:
            row = dc.execute('SELECT * FROM ds_변경이력 WHERE id=?', (history_id,)).fetchone()
            if not row:
                raise HTTPException(404, "변경 이력을 찾을 수 없습니다")
            d = dict(row)
            if (d.get('cancelled') or '0') == '1':
                raise HTTPException(400, "이미 취소된 변경입니다")
            hn = (d.get('허가번호') or '').replace('-', '')
            jn = (d.get('장치번호') or '').strip()
            field = (d.get('필드명') or '').strip()
            before = d.get('변경전값') or ''

            if field == '일련번호':
                dc.execute(
                    'UPDATE ds_장치 SET 기기일련번호=? WHERE 허가번호=? AND 장치번호=?',
                    (before, hn, jn))
            elif field == '형식검정번호':
                dc.execute(
                    'UPDATE ds_장치 SET 형식검정번호=? WHERE 허가번호=? AND 장치번호=?',
                    (before, hn, jn))
            elif field == '설치형태':
                # 행별 되돌리기: 이력의 장치번호 컬럼이 장치별 안테나 식별자
                # 구버전 이력은 장치번호 빈 값일 수 있어 그 경우 전체 안테나 행 복원 (하위 호환)
                if jn:
                    dc.execute(
                        'UPDATE ds_안테나 SET 공중선주설치형태명=? WHERE 허가번호=? AND 장치번호=?',
                        (before, hn, jn))
                else:
                    dc.execute(
                        'UPDATE ds_안테나 SET 공중선주설치형태명=? WHERE 허가번호=?',
                        (before, hn))
            elif field == '설치장소':
                # 행별 되돌리기: 이력의 장치번호 컬럼이 설치장소구분으로 사용됨
                gubun = jn
                dc.execute(
                    'UPDATE ds_설치장소 SET 설치장소주소=? WHERE 허가번호=? AND 설치장소구분=?',
                    (before, hn, gubun))
                # 하위 호환: 첫 행(또는 구분 없음)일 때만 ds_일반사항.설치장소도 갱신
                if not gubun or gubun == '01':
                    try:
                        dc.execute(
                            'UPDATE ds_일반사항 SET 설치장소=? WHERE 허가번호=?',
                            (before, hn))
                    except Exception:
                        pass
                    # inspection_targets도 대표값으로만 동기화
                    ic = sqlite3.connect(_INSP_DB, timeout=60)
                    ic.execute(
                        "UPDATE inspection_targets SET 설치장소=? WHERE REPLACE(허가번호,'-','')=?",
                        (before, hn))
                    ic.commit()
            else:
                raise HTTPException(400, f"취소를 지원하지 않는 필드: {field}")

            now = datetime.now(timezone.utc).isoformat()
            dc.execute(
                "UPDATE ds_변경이력 SET cancelled='1', cancelled_at=?, cancelled_by=? "
                "WHERE id=?",
                (now, empno, history_id))
            dc.commit()
            return {"허가번호": hn, "field": field, "장치번호": jn, "restored_to": before}
        finally:
            if ic is not None:
                ic.close()
            dc.close()

    result = await asyncio.to_thread(_do)
    await asyncio.to_thread(_record_audit_log_sync,
                           "ds_change_cancel", "ds_변경이력",
                           f"id={history_id},field={result['field']}", empno)
    return {"success": True, **result}


@router.post("/ds/apply-partial-update")
async def ds_apply_partial_update(request: Request, file: UploadFile = File(...),
                                   excluded: str = Form("")):
    """변경개설 신고 후 전파관리소 회신 부분 DS 파일 업로드 → ds_detail.db 갱신 + 자동 재비교 + 워크플로우 전환.

    - 파일은 변경개설 신고한 허가번호들만 포함된 DS 파일 (전파관리소 회신본)
    - 해당 허가번호의 ds_장치/ds_안테나를 파일 실제 값으로 갱신 (change_request 값 아님)
    - FILED/REQUESTED 상태 change_request → APPLIED 전환
    - 모든 change_request 항목이 APPLIED 이상이면 RE_CHECK → PRE_CHECK_DONE 자동 전환
    - 권한: admin/manager만 가능 (운영 절차상 본부관리자가 수행)
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    file_bytes = await file.read()
    if not file_bytes:
        raise HTTPException(400, "빈 파일")

    excluded_set: set[str] = set(json.loads(excluded)) if excluded.strip() else set()
    # 업로드 묶음 식별자 — 같은 파일에서 발생한 모든 이력 행이 공유
    import uuid as _uuid
    upload_id = _uuid.uuid4().hex
    upload_filename = file.filename or ''
    upload_ts = datetime.now(timezone.utc).isoformat()

    def _process():
        import xlrd as _xlrd
        try:
            wb = _xlrd.open_workbook(file_contents=file_bytes)
        except Exception as e:
            raise HTTPException(400, "파일 파싱에 실패했습니다. 올바른 XLS 형식인지 확인하세요")

        def _norm_hn(val):
            if isinstance(val, float) and val == int(val):
                return str(int(val))
            return str(val).strip().replace('-', '')

        def _find_col(ws, *keywords):
            # 첫 번째로 매치되는 키워드의 컬럼 인덱스 반환 (폴백 키워드 지원)
            for keyword in keywords:
                for c in range(ws.ncols):
                    if keyword in str(ws.cell_value(0, c)).strip():
                        return c
            return -1

        def _find_sheet(keyword):
            for sn in wb.sheet_names():
                if keyword in sn:
                    return wb.sheet_names().index(sn)
            return -1

        장치_si = _find_sheet('장치')
        안테나_si = _find_sheet('안테나')
        설치장소_si = _find_sheet('설치장소')

        # ── 장치 시트: (허가번호, 장치번호) → {기기일련번호, 형식검정번호}  (장치상태 제외)
        device_data: dict[tuple, dict] = {}
        license_set: set[str] = set()

        if 장치_si >= 0:
            ws = wb.sheet_by_index(장치_si)
            jn_col  = _find_col(ws, '장치번호')
            if jn_col < 0:
                raise HTTPException(400, "장치 시트에 '장치번호' 컬럼이 없습니다. 올바른 DS 양식인지 확인하세요")
            sn_col  = _find_col(ws, '일련번호'); sn_col  = sn_col  if sn_col  >= 0 else 8
            형식_col = _find_col(ws, '형식검정번호'); 형식_col = 형식_col if 형식_col >= 0 else 11

            for ri in range(1, ws.nrows):
                hn = _norm_hn(ws.cell_value(ri, 0))
                if not hn: continue
                license_set.add(hn)
                jn = _norm_hn(ws.cell_value(ri, jn_col)) if ws.ncols > jn_col else ''
                d = {}
                if sn_col >= 0 and ws.ncols > sn_col:
                    v = str(ws.cell_value(ri, sn_col) or '').strip()
                    if v: d['기기일련번호'] = v
                if 형식_col >= 0 and ws.ncols > 형식_col:
                    v = str(ws.cell_value(ri, 형식_col) or '').strip()
                    if v: d['형식검정번호'] = v
                if d: device_data[(hn, jn)] = d

        # ── 안테나 시트: (허가번호, 장치번호) → 공중선주설치형태명 (숫자코드 정규화)
        # 장치별로 안테나가 다를 수 있어 행별 처리
        antenna_data: dict[tuple[str, str], str] = {}

        if 안테나_si >= 0:
            ws = wb.sheet_by_index(안테나_si)
            설치형태_col = _find_col(ws, '설치형태명')
            if 설치형태_col < 0: 설치형태_col = _find_col(ws, '설치형태')
            if 설치형태_col < 0: 설치형태_col = 28
            jn_col_a = _find_col(ws, '장치번호')
            if jn_col_a < 0:
                raise HTTPException(400, "안테나 시트에 '장치번호' 컬럼이 없습니다. 올바른 DS 양식인지 확인하세요")

            for ri in range(1, ws.nrows):
                hn = _norm_hn(ws.cell_value(ri, 0))
                if not hn: continue
                license_set.add(hn)
                if ws.ncols > 설치형태_col:
                    raw = str(ws.cell_value(ri, 설치형태_col) or '').strip()
                    v = _normalize_설치형태(raw)  # 숫자코드 → 텍스트
                    jn = (_norm_hn(ws.cell_value(ri, jn_col_a))
                          if jn_col_a >= 0 and ws.ncols > jn_col_a else '')
                    key = (hn, jn)
                    if v and key not in antenna_data:
                        antenna_data[key] = v

        # ── 설치장소 시트: (허가번호, 설치장소구분) 단위로 모든 행 수집
        location_rows: list[tuple[str, str, str]] = []

        if 설치장소_si >= 0:
            ws = wb.sheet_by_index(설치장소_si)
            hn_col = _find_col(ws, '허가번호')
            addr_col = _find_col(ws, '설치장소주소', '설치장소입력주소')
            gubun_col = _find_col(ws, '설치장소구분')
            if hn_col >= 0 and addr_col >= 0:
                for ri in range(1, ws.nrows):
                    hn = _norm_hn(ws.cell_value(ri, hn_col))
                    v = str(ws.cell_value(ri, addr_col) or '').strip()
                    if not (hn and v):
                        continue
                    license_set.add(hn)
                    gubun = (str(ws.cell_value(ri, gubun_col) or '').strip()
                             if gubun_col >= 0 and ws.ncols > gubun_col else '')
                    location_rows.append((hn, gubun, v))

        if not license_set:
            raise HTTPException(400, "허가번호 없음")

        # ── DS DB 갱신 (파일 실제 값 기준)
        dc = sqlite3.connect(_DS_DETAIL_DB, timeout=60)
        dc.row_factory = sqlite3.Row
        dc.execute('PRAGMA journal_mode=WAL')
        dc.execute('''CREATE TABLE IF NOT EXISTS ds_변경이력 (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            허가번호 TEXT NOT NULL, 변경일자 TEXT NOT NULL,
            시트 TEXT NOT NULL, 필드명 TEXT NOT NULL,
            변경전값 TEXT, 변경후값 TEXT, 장치번호 TEXT
        )''')
        # 신규 컬럼 (구버전 DB 호환용 — _init_ds_detail_db에서 이미 추가됐어야 정상)
        for _col, _dflt in [
            ('cancelled', "'0'"), ('cancelled_at', "''"), ('cancelled_by', "''"),
            ('division_id', "''"), ('upload_id', "''"),
            ('uploaded_by', "''"), ('uploaded_at', "''"), ('uploaded_filename', "''"),
        ]:
            try:
                dc.execute(f"ALTER TABLE ds_변경이력 ADD COLUMN {_col} TEXT DEFAULT {_dflt}")
            except Exception:
                pass

        applied_date = datetime.now().strftime('%y%m%d')
        updated_count = 0

        # 허가번호 → division_id 매핑 (inspection_targets에서 일괄 조회)
        hn_to_div: dict[str, str] = {}
        try:
            ic_tmp = sqlite3.connect(_INSP_DB, timeout=10); ic_tmp.row_factory = sqlite3.Row
            for r in ic_tmp.execute(
                "SELECT DISTINCT REPLACE(허가번호,'-','') AS hn, access담당 "
                "FROM inspection_targets WHERE access담당 != ''"
            ):
                acc = (r['access담당'] or '').strip()
                div = _ACCESS_TO_DIVISION.get(acc, '')
                if r['hn']:
                    hn_to_div[r['hn']] = div
            ic_tmp.close()
        except Exception as _e:
            logger.warning(f"hn_to_div 매핑 실패: {_e}")

        def _div(hn: str) -> str:
            return hn_to_div.get(hn, '')

        for (hn, jn), fields in device_data.items():
            included = {col: val for col, val in fields.items()
                        if f"{hn}#{col}#{jn}" not in excluded_set}
            if not included: continue
            existing = dc.execute(
                'SELECT 기기일련번호, 형식검정번호 FROM ds_장치 WHERE 허가번호=? AND 장치번호=?',
                (hn, jn)
            ).fetchone()
            if not existing: continue
            # 실제로 값이 달라지는 필드만 추려서 UPDATE — preview의 diff 기준과 일치시킴
            changed = {col: new_val for col, new_val in included.items()
                       if (str(existing[col] or '') if existing[col] is not None else '') != new_val}
            if not changed: continue
            set_parts = [f'{col}=?' for col in changed]
            cur = dc.execute(
                f'UPDATE ds_장치 SET {", ".join(set_parts)} WHERE 허가번호=? AND 장치번호=?',
                list(changed.values()) + [hn, jn]
            )
            if cur.rowcount > 0:
                updated_count += 1
                for col, new_val in changed.items():
                    old_val = str(existing[col] or '') if existing[col] is not None else ''
                    dc.execute(
                        'INSERT INTO ds_변경이력(허가번호,변경일자,시트,필드명,변경전값,변경후값,장치번호,'
                        'division_id,upload_id,uploaded_by,uploaded_at,uploaded_filename) '
                        'VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
                        (hn, applied_date, '부분DS장치', col, old_val, new_val, jn,
                         _div(hn), upload_id, empno, upload_ts, upload_filename)
                    )

        # 설치형태: (허가번호, 장치번호) 단위로 행별 적용
        for (hn, jn), 설치형태 in antenna_data.items():
            if f"{hn}#설치형태#{jn}" in excluded_set: continue
            existing = dc.execute(
                'SELECT 공중선주설치형태명 FROM ds_안테나 WHERE 허가번호=? AND 장치번호=? LIMIT 1',
                (hn, jn)
            ).fetchone()
            old_val = str(existing['공중선주설치형태명'] or '') if existing else ''
            if old_val == 설치형태: continue
            cur = dc.execute(
                'UPDATE ds_안테나 SET 공중선주설치형태명=? WHERE 허가번호=? AND 장치번호=?',
                (설치형태, hn, jn))
            if cur.rowcount > 0:
                updated_count += 1
                dc.execute(
                    'INSERT INTO ds_변경이력(허가번호,변경일자,시트,필드명,변경전값,변경후값,장치번호,'
                    'division_id,upload_id,uploaded_by,uploaded_at,uploaded_filename) '
                    'VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
                    (hn, applied_date, '부분DS안테나', '설치형태', old_val, 설치형태, jn,
                     _div(hn), upload_id, empno, upload_ts, upload_filename)
                )

        # 설치장소: (허가번호, 설치장소구분) 단위로 행별 적용
        for hn, gubun, new_addr in location_rows:
            # excluded_set의 키는 "허가번호#설치장소#설치장소구분" 형태로 통일
            if f"{hn}#설치장소#{gubun}" in excluded_set: continue
            existing = dc.execute(
                'SELECT 설치장소주소 FROM ds_설치장소 WHERE 허가번호=? AND 설치장소구분=?',
                (hn, gubun)
            ).fetchone()
            old_val = str(existing['설치장소주소'] or '') if existing and existing['설치장소주소'] else ''
            if old_val == new_addr: continue
            cur = dc.execute(
                'INSERT INTO ds_설치장소(허가번호,설치장소구분,설치장소주소) VALUES(?,?,?) '
                'ON CONFLICT(허가번호,설치장소구분) DO UPDATE SET 설치장소주소=excluded.설치장소주소',
                (hn, gubun, new_addr))
            if cur.rowcount > 0:
                updated_count += 1
                # 이력에 설치장소구분도 장치번호 컬럼에 기록 (되돌리기 시 식별)
                dc.execute(
                    'INSERT INTO ds_변경이력(허가번호,변경일자,시트,필드명,변경전값,변경후값,장치번호,'
                    'division_id,upload_id,uploaded_by,uploaded_at,uploaded_filename) '
                    'VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
                    (hn, applied_date, '부분DS설치장소', '설치장소', old_val, new_addr, gubun,
                     _div(hn), upload_id, empno, upload_ts, upload_filename)
                )
                # 하위 호환: ds_일반사항.설치장소도 동기화 (대표값 — 첫 행만 의미 있음)
                if not gubun or gubun == '01':
                    dc.execute('UPDATE ds_일반사항 SET 설치장소=? WHERE 허가번호=?', (new_addr, hn))

        dc.commit(); dc.close()

        # ── change_request FILED/REQUESTED → APPLIED
        ic = sqlite3.connect(_INSP_DB, timeout=60)
        ic.row_factory = sqlite3.Row
        ph = ','.join('?' * len(license_set))
        crs = ic.execute(
            f"SELECT * FROM change_request WHERE status IN ('REQUESTED','FILED') "
            f"AND REPLACE(허가번호, '-', '') IN ({ph})",
            list(license_set)
        ).fetchall()
        crs = [dict(r) for r in crs]

        # ── 신고-반영 정합성 검증 (경고만, 적용은 그대로 진행) ──
        # 신고된 장치 단위 변경: 일련번호/형식검정번호 = device_data 와 동일 키 (허가번호,장치번호)
        #                        설치형태 = antenna_data 와 동일 키
        warnings: list[str] = []
        device_changed_keys = set(device_data.keys()) | set(antenna_data.keys())  # (hn, jn)
        reported_device_keys: set[tuple[str, str]] = set()
        for cr in crs:
            if cr.get('field') in ('일련번호', '형식검정번호', '설치형태'):
                hn_c = (cr.get('허가번호') or '').replace('-', '').strip()
                jn_c = (cr.get('장치번호') or '').strip()
                reported_device_keys.add((hn_c, jn_c))
        # 신고됐는데 파일에 해당 장치 행이 없음 (신고한 장치가 반영 누락)
        for (hn_r, jn_r) in sorted(reported_device_keys):
            if (hn_r, jn_r) not in device_changed_keys:
                warnings.append(f"신고된 장치(허가 {hn_r} / 장치 {jn_r or '미지정'})가 업로드 파일에 없습니다")
        # 파일엔 있는데 신고 안 된 장치 (신고 없이 다른 장치가 포함됨)
        for (hn_f, jn_f) in sorted(device_changed_keys):
            if hn_f in license_set and (hn_f, jn_f) not in reported_device_keys:
                warnings.append(f"신고되지 않은 장치(허가 {hn_f} / 장치 {jn_f or '미지정'})가 파일에 포함되어 있습니다")

        now = datetime.now(timezone.utc).isoformat()
        applied_cr_ids = [cr['id'] for cr in crs]
        if applied_cr_ids:
            ph2 = ','.join('?' * len(applied_cr_ids))
            ic.execute(
                f"UPDATE change_request SET status='APPLIED', applied_at=? WHERE id IN ({ph2})",
                [now] + applied_cr_ids
            )

        # ── 자동 재비교: 모든 CR APPLIED 이상이면 RE_CHECK → PRE_CHECK_DONE
        sched_pks = {cr['schedule_pk'] for cr in crs}
        schedule_done: list[str] = []
        for spk in sched_pks:
            row = ic.execute(
                'SELECT workflow_status FROM inspection_schedules WHERE pk=?', (spk,)
            ).fetchone()
            if not row:
                continue
            cur_status = row['workflow_status'] or WF_REGISTERED
            if cur_status != WF_RE_CHECK:
                continue
            unfinished = ic.execute(
                "SELECT COUNT(*) FROM change_request WHERE schedule_pk=? AND status NOT IN ('APPLIED','VERIFIED')",
                (spk,)
            ).fetchone()[0]
            if unfinished > 0:
                continue
            ic.execute(
                'UPDATE inspection_schedules SET workflow_status=?, status_updated_at=?, status_updated_by=? WHERE pk=?',
                (WF_PRE_CHECK_DONE, now, 'system', spk)
            )
            _wf_record_log_sync(ic, spk, cur_status, WF_PRE_CHECK_DONE, 'system', "부분 DS 적용 후 자동 재비교 통과")
            ic.execute(
                "UPDATE change_request SET status='VERIFIED' WHERE schedule_pk=? AND status='APPLIED'", (spk,)
            )
            schedule_done.append(spk)

        ic.commit(); ic.close()

        return {
            "matched_changes": len(crs),
            "applied": updated_count,
            "schedule_done": schedule_done,
            "warnings": warnings,
        }

    result = await asyncio.to_thread(_process)
    await asyncio.to_thread(_record_audit_log_sync,
                           "ds_partial_update", "ds_detail",
                           f"updated={result['applied']},cr_applied={result['matched_changes']},done={len(result['schedule_done'])}",
                           empno)
    return {"success": True, **result}



# ── startup 헬퍼 ─────────────────────────────────────────────
# main.py startup_event에서 이 함수를 호출하여 DS 관련 비동기 태스크 등록

def get_ds_startup_tasks(app_startup_event):
    """DS 백그라운드 태스크 목록 반환 (main.py startup_event에서 사용).

    반환: 비동기 코루틴 목록 (asyncio.create_task로 등록)
    """
    async def _startup_xlsx_scan():
        try:
            await asyncio.sleep(3)
            queued, skipped = await asyncio.to_thread(_scan_missing_xlsx_caches_sync)
            if queued:
                logger.info(f"DS startup: xlsx 빌드 {len(queued)}건 자동 등록: {queued}")
        except Exception as e:
            logger.warning(f"DS startup xlsx scan error: {e}")

    return [
        _ensure_ds_jobs_table(),
        _recover_stuck_jobs(),
        _job_worker_loop(),
        _startup_xlsx_scan(),
    ]
