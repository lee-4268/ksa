"""
FastAPI Server for Tower/Antenna Classification
Flutter PWA + Mobile Web Support
"""

import os
import sys
import json
import uuid
import shutil
import asyncio
import sqlite3
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import List, Optional, Dict, Union
from datetime import datetime, timezone, timedelta
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
import time
import threading
import multiprocessing
from urllib.parse import quote

import httpx
import boto3
from boto3.dynamodb.conditions import Attr, Key
from botocore.exceptions import ClientError
import numpy as np
from fastapi import FastAPI, File, UploadFile, HTTPException, Query, Form, BackgroundTasks, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse, Response, StreamingResponse, RedirectResponse
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

def _cleanup_stale_temp_files(max_age_seconds: int = 3600):
    """오래된 임시파일 자동 삭제 (서버 시작/주기적 실행)
    대상:
    - ds_temp_*, ds_merged_*, ds_export_*, ds_bgxlsx_*, ds_xlsx_*, ds_{uuid}.*
    - tmp* (xlsxwriter constant_memory, NamedTemporaryFile(delete=False) 누수)
    - cert_batch_*
    제외: ds_cache/ 디렉토리 (자체 TTL 관리)
    """
    ds_prefixes = ("ds_temp_", "ds_merged_", "ds_export_", "ds_bgxlsx_", "ds_xlsx_", "ds_xls_")
    now = _time_mod.time()
    removed = 0
    freed_bytes = 0
    try:
        for fname in os.listdir("/tmp"):
            should_check = False
            # DS 관련 임시파일
            if any(fname.startswith(p) for p in ds_prefixes):
                should_check = True
            elif fname.startswith("ds_") and not fname.startswith("ds_cache"):
                should_check = True
            # xlsxwriter / Python tempfile 임시파일 (tmp로 시작, 소유자 확인)
            elif fname.startswith("tmp") and not fname.endswith(".conf"):
                should_check = True
            # cert_batch 임시파일
            elif fname.startswith("cert_batch_"):
                should_check = True
            # cert_cache WAL/SHM 임시파일
            elif fname.startswith("cert_cache.db.tmp-"):
                should_check = True

            if not should_check:
                continue

            fpath = f"/tmp/{fname}"
            try:
                if os.path.isdir(fpath):
                    # cert_batch / ds_xlsxbuild / ds_ 임시 디렉토리 정리
                    if fname.startswith(("cert_batch_", "ds_xlsxbuild_", "ds_")):
                        stat = os.stat(fpath)
                        if now - stat.st_mtime > max_age_seconds:
                            import shutil
                            shutil.rmtree(fpath, ignore_errors=True)
                            removed += 1
                    continue
                stat = os.stat(fpath)
                age = now - stat.st_mtime
                if age > max_age_seconds:
                    size = stat.st_size
                    os.remove(fpath)
                    removed += 1
                    freed_bytes += size
            except Exception:
                pass
    except Exception as e:
        logger.warning(f"temp cleanup scan 실패: {e}")
    if removed > 0:
        logger.info(f"temp cleanup: {removed}개 파일 삭제 ({freed_bytes // (1024*1024)}MB 확보)")
    return removed

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
    "route_baskets": os.getenv("DYNAMODB_ROUTE_BASKETS_TABLE", "kca-route-baskets"),
}

# 수도권 본부명 한글 → S3 키용 영문 변환 (presigned URL 인코딩 문제 방지)
_HDQT_S3_KEY: dict = {'강남': 'gangnam', '강북': 'gangbuk', '경기': 'gyeonggi', '인천': 'incheon'}

# DS 전파관리소 지역코드 → 회사 본부 매핑
# 수도권(10) → 강남/강북/인천/경기 4개 본부 통합 저장
# 충남(50)+충북(55) → 충청본부, 전남(30)+전북(70) → 서부본부
DS_REGION_CODE_MAP = {
    "10": {"divisionId": "sudogwon", "divisionName": "수도권"},
    "20": {"divisionId": "gyeongnam", "divisionName": "경남본부"},
    "26": {"divisionId": "gyeongnam", "divisionName": "경남본부"},      # 울산 → 경남본부
    "30": {"divisionId": "seobu", "divisionName": "서부본부"},
    "40": {"divisionId": "gangwon", "divisionName": "강원본부"},
    "50": {"divisionId": "chungcheong", "divisionName": "충청본부"},
    "55": {"divisionId": "chungcheong", "divisionName": "충청본부"},
    "60": {"divisionId": "gyeongbuk", "divisionName": "경북본부"},
    "70": {"divisionId": "seobu", "divisionName": "서부본부"},
    "80": {"divisionId": "seobu", "divisionName": "서부본부"},          # 제주 → 서부본부
}

# 같은 본부로 병합되는 코드 (전북70→서부30, 충북55→충청50, 울산26→경남20, 제주80→서부30)
DS_MERGED_CODES = {"70": "30", "55": "50", "26": "20", "80": "30"}
# 대표코드 → 함께 정리해야 할 파트너 코드
DS_PARTNER_CODES = {"30": ["70", "80"], "50": ["55"], "20": ["26"]}

# ── 호출명칭 매칭 설정 ──────────────────────────────────────
CALLNAME_CSV_PREFIX = "callname-db/"
CALLNAME_CACHE_TTL = 86400  # 24시간
CALLNAME_SESSION_TTL = 1800  # 30분
CALLNAME_MAX_SESSIONS = 3
CALLNAME_USE_COLS = ["zpwina", "zpwino", "zpwiadr", "zpcode", "zpkcode", "zpcname", "area_hdofc_nm", "ons_team_nm", "zpirty3", "eqp_ser_no", "zpprac1", "eqp_type", "max_seqno", "zpannu1", "swing_list"]
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

# 장비Type 간소화 매핑 (v6 기준 283개)
_EQP_TYPE_SIMPLIFY = {
    "0x2a": "MIBOS",
    "800-SHRFW20-S1R": "SRF-W",
    "AAU10-3.5G-32T(EL)": "RRU",
    "AAU10-3.5G-32T(SS)": "AAU",
    "AAU20-3.5G-32T(EL)": "AAU",
    "AAU20-3.5G-32T(SS)": "AAU",
    "AAU20-3.5G-64T(EL)": "RRU",
    "AAU20-3.5G-64T(SS)": "AAU",
    "AAU21-3.5G-32T(SS)": "AAU",
    "ARRU_L(SS)": "RRU",
    "ARRU_WL(SS)": "RRU",
    "Airscale 5G MAA_AVQL": "AAU",
    "Airscale 5G MAA_Band n78_AEQY": "AAU",
    "Airscale 5G MAA_Band n78_AQQL": "AAU",
    "CRU_L10(NSN)": "RRU",
    "CRU_L10(SS)": "RRU",
    "CSW-4903-RRFU": "OMW-DUO",
    "DBRRU(SS)-WL": "RRU",
    "DR-NODEB(외)": "W기지국",
    "DUO-IBSF": "DUO-IBS",
    "E3-NODEB(내)": "W기지국",
    "E3-NODEB(외)": "W기지국",
    "ERRHS": "ERRH",
    "ERRUP": "ERRU",
    "FX-NODEB": "W기지국",
    "Flexi Multiradio BTS": "RRU",
    "Flexi Multiradio RRH_Band 1_3": "RRU",
    "Flexi Multiradio RRH_Band 3": "RRU",
    "Flexi Multiradio RRH_Band 7": "RRU",
    "Flexi Multiradio RRH_Band n78": "AAU",
    "GST-SF-W15": "SF중계기",
    "ICS-W1": "ICS",
    "ICS-W20": "ICS",
    "ICS-W5": "ICS",
    "ICS-WN20": "ICS",
    "IMT1050026": "SF중계기",
    "IMT1050028": "SF중계기",
    "KCC-CRI-LE1-RRUS11B5": "RRU",
    "KCC-CRI-LE1-RRUS11B5-40W": "RRU",
    "KCC-CRM-CSW-1SFF-B707": "RHU",
    "LR-DUO2": "LR-DUO",
    "LR-DUO5": "LR-DUO",
    "LR-DUOF6": "LR-DUO",
    "LR-DUON5": "LR-DUO",
    "MIBOS-T-L60 RO-세로형": "MIBOS",
    "MIBOS-WL-L10": "WLME",
    "MPR-DUOF0530_IBS": "MPR-DUO",
    "MPR-DUOF6_IBS": "MPR-DUO",
    "MPR-DUON0520_IBS": "MPR",
    "MPR-RHU-W5,MPR-RHU-WN5": "RHU",
    "MPR-RHU-WN20": "RHU",
    "MPRDN-RHUW": "RHU",
    "MPRDUO-RHU-R,MPRDN-RHU": "RHU",
    "MRRU_L10(ELG)": "RRU",
    "MSIP-CRI-LE1-RRU22F1B3D": "RRU",
    "MSIP-CRI-LE1-RRUS12B1": "RRH",
    "MSIP-CRI-LE1-RRUS12B3-20M": "RRU",
    "MSIP-CRI-LE1-RRUS13B1": "RRU",
    "MSIP-CRI-LE1-Radio2212B7": "RRU",
    "MSIP-CRI-LE1-Radio2217B7": "RRU",
    "MSIP-CRM-800-SHTLHD-S1": "MIBOS",
    "MSIP-CRM-CSW-1SFA-T802TL60": "MIBOS",
    "MSIP-CRM-CSW-RROIROT80W6RLD": "IRO",
    "MSIP-CRM-GST-MIBOS-T-L60R-S": "MIBOS",
    "MSIP-CRM-GST-MIBOS-T-L60ROR": "MIBOS",
    "MSIP-CRM-STC-MIBOS-Ad-L60LW": "MIBOS",
    "MSIP-CRM-STC-MiBOS-Ad-L0LW": "MIBOS",
    "MSIP-CRM-STC-MiBOS-Ad-L26LO": "MIBOS",
    "MSIP-CRM-STC-MiBOS-Ad-L60LW": "MIBOS",
    "MSIP-CRM-STC-RMIBQROTL": "MIBOS",
    "MSIP-CRM-STC-RMIBTROLD60": "MIBOS",
    "MSIP-CRM-STC-RMiBLROLO25": "MIBOS",
    "MSIP-CRM-STC-RMiBQROTL": "MIBOS",
    "MSIP-CRM-STC-RMiBTROLD60": "MIBOS",
    "MSIP-CRM-STC-RMiBWMCL05": "MIBOS",
    "MSIP-CRM-STC-RROIROQ8126RLD": "IRO",
    "MSIP-CRM-STC-RROIROT8120LD": "IRO",
    "MSIP-CRM-TSK-MIBOS-TF-L60-A": "MIBOS",
    "MSIP-CRM-TSK-MIBOS-TF-L60-B": "MIBOS",
    "MSIP-CRM-TSK-MiBOS-DF-L60-A": "MIBOS",
    "MSIP-CRM-TSK-MiBOS-QF-L60-B": "MIBOS",
    "MSIP-CRM-TSK-MiBOS-TF-L60-A": "MIBOS",
    "MSIP-CRM-TSK-MiBOS-TF-L60-B": "MIBOS",
    "MSIP-CRM-TSK-MiBOS-TSF-L60": "MIBOS",
    "MiBOS-Ad-L26": "MIBOS",
    "MiBOS-Ad-L60": "MIBOS",
    "MiBOS-T-L60-AH": "MIBOS",
    "MiBOS-T-L60-BH": "MIBOS",
    "MiBOS-TS-L60-H": "MIBOS",
    "MiBOS-WL-L10": "WLME",
    "NLG-iBTSOutdoorS": "W기지국",
    "NLG-iBTSOutdoorSH": "W기지국",
    "OR-DUO2": "OR-DUO",
    "OR-DUO5": "OR-DUO",
    "OR-DUON5": "OR-DUO",
    "OR-DUOR2": "OR-DUO",
    "OR-DUOR5": "OR-DUO",
    "OR-DUORC6": "OR-DUO",
    "OTTA-W20": "TTA",
    "PRU10-3.5G-4T": "PRU",
    "PRU10-3.5G-4T(EL)": "PRU",
    "PRU10-3.5G-8T(SS)": "PRU",
    "R-C-CSW-ROIRODS8100LO": "IRO",
    "R-C-Hfr-PRU10-3-5G-4T": "PRU",
    "R-C-LE1-AIR3227B43": "AAU",
    "R-C-LE1-AIR3239B78C": "AAU",
    "R-C-LE1-AIR6419B78Y": "AAU",
    "R-C-LE1-AIR6488B43": "AAU",
    "R-C-LE1-Radi2242B1B3": "RRU",
    "R-C-LE1-Radio4422B78C": "PRU",
    "R-C-STC-ROIROD0120RLW": "IRO",
    "R-C-STC-ROIRODS0120LW": "IRO",
    "R-C-STC-ROIROTS8120LD": "IRO",
    "R-C-STC-ROgIRODS0120": "GIRO",
    "R-C-STC-ROgIRODS8100": "GIRO",
    "R-C-STC-ROgIROTS8120": "GIRO",
    "R-IMT1-05-0028": "SF중계기",
    "RAU-DUO5": "RAU",
    "RAU-DUON5": "RAU",
    "RHU-DUO0520": "RHU",
    "RHU-DUO0520-MHU": "RHU",
    "RHU-DUO0520-OMHU": "RHU",
    "RHU-DUO0530-OMHU": "RHU",
    "RHU-DUO20-MHU": "RHU",
    "RHU-DUO20-OMHU": "RHU",
    "RHU-DUO5": "RHU",
    "RHU-DUO5-MHU": "RHU",
    "RHU-DUOC0520": "RHU",
    "RHU-DUOC0520-OMHU": "RHU",
    "RHU-DUOC0530": "RHU",
    "RHU-DUOF30-MHU": "RHU",
    "RHU-DUOF30-OMHU": "RHU",
    "RHU-DUOF6": "RHU",
    "RHU-DUOF6-MHU": "RHU",
    "RHU-DUON20": "RHU",
    "RHU-DUON20-MHU": "RHU",
    "RHU-DUON20-OMHU": "RHU",
    "RHU-DUON30": "PRU",
    "RHU-DUON30-OMHU": "RHU",
    "RHU-DUON5": "RHU",
    "RHU-DUON5-MHU": "RHU",
    "RHU-DUON5-OMHU": "RHU",
    "RHU-DUON6": "RHU",
    "RHU-DUON6-OMHU": "RHU",
    "RHU-DUONC20-MHU": "RHU",
    "RHU-DUONC5-OMHU": "RHU",
    "RHU-WF30-MHU": "RHU",
    "RHU-WF30-OMHU": "RHU",
    "RHU-WF6-OMHU": "RHU",
    "RHU-WN20": "RHU",
    "RHU-WN20-OMHU": "RHU",
    "RHU-WN30": "RHU",
    "RHU-WN5-MHU": "RHU",
    "RHU-WN5-OMHU": "RHU",
    "RMiBLRO": "MIBOS",
    "RMiBTRO": "MIBOS",
    "RMiBTSRO": "MIBOS",
    "RMiBWM": "MIBOS",
    "RO-DUO-AA2020": "RO-DUO",
    "RO-DUO-AA2020-CMHU": "RO-DUO",
    "RO-DUO-AA2030": "RO-DUO",
    "RO-DUO-AA2030-CMHU": "RO-DUO",
    "RO-DUO-DD4060": "RO-DUO",
    "RO-DUO-DD4060-CMHU": "RO-DUO",
    "RO-DUON5": "RO-DUO",
    "RO-DUON5-MHU": "RO-DUO",
    "RO-DUON5-MOU": "RO-DUO",
    "RO-DUONC5-MOU": "RO-DUO",
    "RO-GIRO-DS(0120)": "GIRO",
    "RO-GIRO-T(8120)": "GIRO",
    "RO-GIRO-TS(8120)": "GIRO",
    "RO-IRO-D(0120)": "IRO",
    "RO-IRO-D(8020)-SMHS(1C)": "IRO",
    "RO-IRO-D(8100)": "IRO",
    "RO-IRO-D(8100)-IMHS": "IRO",
    "RO-IRO-D(8100)-QMHS": "IRO",
    "RO-IRO-D(8100)-SMHS(1C)": "IRO",
    "RO-IRO-DS(0120)": "IRO",
    "RO-IRO-DS(8020)": "IRO",
    "RO-IRO-DS(8020)-SMHS(1C)": "IRO",
    "RO-IRO-DS(80W0)": "IRO",
    "RO-IRO-DS(8100)-SMHS(1C)": "IRO",
    "RO-IRO-Q(8126)": "IRO",
    "RO-IRO-Q(8126)-IMHS": "IRO",
    "RO-IRO-Q(8126)-SMHS(1C)": "IRO",
    "RO-IRO-Q(81W6)": "IRO",
    "RO-IRO-Q(81W6)-IMHS": "IRO",
    "RO-IRO-QS(8126)-SMHS(2C)": "IRO",
    "RO-IRO-QS(81W6)": "IRO",
    "RO-IRO-SS(0020)": "IRO",
    "RO-IRO-T(01W6)": "IRO",
    "RO-IRO-T(80W6)": "IRO",
    "RO-IRO-T(80W6)-IMHS": "IRO",
    "RO-IRO-T(8120)": "IRO",
    "RO-IRO-T(8120)-IMHS": "IRO",
    "RO-IRO-T(8120)-SMHS(1C)": "IRO",
    "RO-IRO-T(81W0)": "IRO",
    "RO-IRO-T(81W0)-IMHS": "IRO",
    "RO-IRO-T(81W0)-SMHS(1C)": "IRO",
    "RO-IRO-TS(8120)": "IRO",
    "RO-IRO-TS(8120)-SMHS(1C)": "IRO",
    "RO-IRO-TS(81W0)": "IRO",
    "RO-IRO-TS(81W0)-SMHS(1C)": "IRO",
    "RO-IRO_SLIM-Q(8126)": "IRO",
    "RO-MBS-T-L60-SMHS-3C": "MIBOS",
    "RO-MBS-TS-L60-SMHS-3C": "MIBOS",
    "RO-MIBOS-AD-L0": "MIBOS",
    "RO-MIBOS-AD-L0(2.6)": "MIBOS",
    "RO-MIBOS-AD-L60": "MIBOS",
    "RO-MIBOS-AD-L60-AMHS": "MIBOS",
    "RO-MIBOS-CL-L60": "MIBOS",
    "RO-MIBOS-CL-L60-QMHS": "MIBOS",
    "RO-MIBOS-D-L60": "MIBOS",
    "RO-MIBOS-D-L60-QMHS": "MIBOS",
    "RO-MIBOS-Q-L60": "MIBOS",
    "RO-MIBOS-Q-L60-QMHS": "MIBOS",
    "RO-MIBOS-T-L0-QMHS": "MIBOS",
    "RO-MIBOS-T-L60": "MIBOS",
    "RO-MIBOS-T-L60-QMHS": "MIBOS",
    "RO-MIBOS-TS-L60": "MIBOS",
    "RO-MIBOS-TS-L60-QMHS": "MIBOS",
    "RO-MIBOS-WL(ME)-L05": "MIBOS",
    "RO-MIBOS-WL(ME)-L05-QMHS": "WLME",
    "RO-MIBOS-WL-L10": "MIBOS",
    "RO-MIBOS-WL-L10-QMHS": "MIBOS",
    "RO-PRU-3.5G-4T": "PRU",
    "RO-PRU-3.5G-4T-LSH310(EL)": "PRU",
    "RO-PRU-3.5G-4T-LSH310(SS)": "PRU",
    "RO-W-D60": "WRO",
    "RO-W-D60-CMHU": "DDR",
    "ROIRODS8020": "IRO",
    "ROIROTS8120": "IRO",
    "RRH_L(ELG)-WL": "RRH",
    "RRH_L(LGE)": "RRU",
    "RRH_L(NSN)": "RRU",
    "RROIROQ8126R": "IRO",
    "RROIROQ81W6R": "IRO",
    "RROIROT8120": "IRO",
    "RRU(0120)_AHEGA(NSN)": "RRU",
    "RRU(0120)_AHEGA(NSN)-WL": "RRU",
    "RRU(0120)_R2242(ELG)": "RRU",
    "RRU(0120)_R2242(ELG)-WL": "RRU",
    "RRUS12(ELG)-WL": "RRU",
    "RRUS13(ELG)": "RRU",
    "RRUS13(ELG)-WL": "RRU",
    "RRU_1.8G_FHEA(NSN)": "RRU",
    "RRU_2.6G_ARRU(SS)": "RRU",
    "RRU_2.6G_FRHG(NSN)": "RRU",
    "RRU_2.6G_R2212(ELG)": "RRU",
    "RRU_2.6G_R2217(ELG)": "RRU",
    "RRU_2.6G_R4415(ELG)": "RRU",
    "RRU_800M_R2212(ELG)": "RRU",
    "RRU_FHEB(NSN)": "RRU",
    "RRU_FRGT(NSN)-WL": "RRU",
    "RRU_L(SS)": "RRU",
    "RU(NSN)": "RRU",
    "RU_FXEB(NSN)": "RRU",
    "SF-DUO": "SF중계기",
    "SF-DUO20": "SF중계기",
    "SF-DUOR": "SF중계기",
    "SF-TF433": "SF중계기",
    "SF-TMF463": "SF중계기",
    "SF-W15": "SF중계기",
    "SF-W20": "SF중계기",
    "SF-WIMF33": "SF중계기",
    "SF-WN20": "SF중계기",
    "SF-WR15": "SF중계기",
    "SF-WR20": "SF중계기",
    "SFDUO-R(C60W20)": "SF중계기",
    "SHTLHD-S1": "TRIO",
    "SPSFFRTTS0": "SF중계기",
    "SRF-W15": "SF중계기",
    "SRF-W20": "SF중계기",
    "SRRU(SS)": "RRU",
    "SRRU_D(SS)": "RRU",
    "SS E3NODEB": "W기지국",
    "SS-E3NODEB": "W기지국",
    "STC-SFW-R15": "SF중계기",
    "TRIO-LH": "TRIO",
    "WAFMCA": "WAFMC",
    "WAFMCB": "WAFMC",
    "WINS PLUSF": "WINS",
    "etr-SF-W15-REMOTE": "SF중계기",
}

# 키워드 기반 장비타입 간소화 fallback (딕셔너리 매칭 실패 시)
_EQP_KEYWORD_RULES = [
    # (키워드 패턴, 간소화명) — 순서 중요: 구체적인 것 먼저
    ("GIRO", "GIRO"),
    ("IRO", "IRO"),
    ("MIBOS", "MIBOS"), ("MiBOS", "MIBOS"), ("MBS", "MIBOS"),
    ("AAU", "AAU"),
    ("PRU", "PRU"),
    ("ARRU", "RRU"), ("MRRU", "RRU"), ("SRRU", "RRU"), ("DBRRU", "RRU"),
    ("ERRU", "ERRU"), ("RRU", "RRU"), ("RRH", "RRH"),
    ("RHU", "RHU"),
    ("TRIO", "TRIO"),
    ("WAFMC", "WAFMC"), ("WINS", "WINS"), ("WLME", "WLME"),
    ("ICS", "ICS"),
    ("LR-DUO", "LR-DUO"), ("OR-DUO", "OR-DUO"), ("RO-DUO", "RO-DUO"),
    ("SF-DUO", "SF중계기"), ("SF-W", "SF중계기"), ("SF-", "SF중계기"), ("SRF-W", "SF중계기"),
    ("DUO", "DUO"),
    ("NODEB", "W기지국"), ("iBTS", "W기지국"),
]

def _simplify_eqp_by_keyword(raw: str) -> str:
    """딕셔너리 매칭 실패 시 키워드 기반으로 장비타입 간소화."""
    upper = raw.upper()
    for keyword, simplified in _EQP_KEYWORD_RULES:
        if keyword.upper() in upper:
            return simplified
    return ""

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

# 개발용 테스트 로그인 활성화 (환경변수 DEV_LOGIN_ENABLED=1 로 활성화)
DEV_LOGIN_ENABLED = os.environ.get("DEV_LOGIN_ENABLED", "0") == "1"
_dev_users: dict = {}  # empno → {name, region, team, role} 메모리 캐시

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


# ── 일일 접속자 카운트 (메모리 기반) ──
_daily_visitors: set = set()
_daily_visitors_date: str = ""

def _count_daily_visitors() -> int:
    """오늘 고유 접속자 수 (menu_usage_log 기반, 서버 재시작해도 유지)."""
    try:
        if not os.path.exists(_INSP_DB):
            return len(_daily_visitors)
        today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        conn = sqlite3.connect(_INSP_DB, timeout=10)
        cnt = conn.execute(
            "SELECT COUNT(DISTINCT user_id) FROM menu_usage_log WHERE accessed_at >= ?",
            (today,)
        ).fetchone()[0]
        conn.close()
        return cnt
    except Exception:
        return len(_daily_visitors)

def _track_daily_visitor(empno: str):
    global _daily_visitors, _daily_visitors_date
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    if _daily_visitors_date != today:
        _daily_visitors = set()
        _daily_visitors_date = today
    _daily_visitors.add(empno)


async def _verify_auth(request: Request) -> str:
    """Bearer 토큰 검증. 실패 시 401.
    토큰 잔여 수명이 절반 이하이면 request.state.refreshed_token에 새 토큰 저장.
    """
    auth_header = request.headers.get("Authorization", "")
    if auth_header.startswith("Bearer "):
        token = auth_header[7:]
        empno = _verify_token(token)
        if empno:
            _track_daily_visitor(empno)
            # 토큰 잔여 수명 체크 → 절반 이하면 갱신
            try:
                decoded = base64.urlsafe_b64decode(token.encode()).decode()
                expiry = int(decoded.split(":")[1])
                remaining = expiry - int(_time_mod.time())
                if remaining < AUTH_TOKEN_EXPIRY // 2:
                    request.state.refreshed_token = _generate_token(empno)
            except Exception:
                pass
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


def _get_last_login(empno: str) -> str:
    """kca-user-roles 테이블에서 last_login 조회."""
    return _get_user_role_info(empno)["last_login"]


def _get_user_role_info(empno: str) -> dict:
    """kca-user-roles 테이블에서 role + last_login + is_dormant 한 번에 조회."""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        resp = table.get_item(
            Key={"user_id": empno},
            ProjectionExpression="#r, last_login, is_dormant",
            ExpressionAttributeNames={"#r": "role"},
        )
        item = resp.get("Item", {})
        role = item.get("role", "member")
        if role not in VALID_ROLES:
            role = "member"
        return {
            "role": role,
            "last_login": item.get("last_login", ""),
            "is_dormant": bool(item.get("is_dormant", False)),
        }
    except Exception as e:
        logger.warning(f"user_role_info 조회 실패 ({empno}): {e}")
        return {"role": "member", "last_login": "", "is_dormant": False}


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


def _ensure_route_baskets_table():
    """서버 시작 시 kca-route-baskets 테이블 자동 생성"""
    try:
        client = get_dynamodb_client()
        client.create_table(
            TableName=DYNAMODB_TABLES["route_baskets"],
            KeySchema=[
                {"AttributeName": "user_id", "KeyType": "HASH"},
                {"AttributeName": "entry_id", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "user_id", "AttributeType": "S"},
                {"AttributeName": "entry_id", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        logger.info(f"DynamoDB table {DYNAMODB_TABLES['route_baskets']} created")
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceInUseException":
            logger.warning(f"route_baskets table creation error (non-fatal): {e}")


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

        # Users 테이블에서 프로필 정보 조회 (대소문자 불일치 대응)
        try:
            user_resp = users_table.get_item(Key={"user_id": uid})
            if not user_resp.get("Item"):
                user_resp = users_table.get_item(Key={"user_id": uid.upper()})
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
            "last_login": role_item.get("last_login") or None,
            "is_dormant": bool(role_item.get("is_dormant", False)),
        })


    # 대소문자 중복 제거.
    # 동일 사번이 대소문자 다르게 여러 row로 존재할 수 있으므로 안전하게 병합:
    # - role 우선순위: admin > manager > member (높은 권한 유지)
    # - last_login: 더 최근 값 유지
    # - is_dormant: 한 쪽이라도 False면 활성으로 간주
    # - empno: 대문자 버전으로 통일 (인증/감사 추적 용이)
    # - 이름/프로필: 채워진 쪽 우선
    _ROLE_RANK = {"admin": 3, "manager": 2, "member": 1, "": 0}
    deduped: dict = {}
    for u in users:
        key = u["empno"].upper()
        if key not in deduped:
            # 키는 대문자로 통일하되 row 자체의 empno도 대문자로 강제
            u["empno"] = key
            deduped[key] = u
            continue
        cur = deduped[key]
        # role: 우선순위 높은 쪽
        if _ROLE_RANK.get(u.get("role") or "", 0) > _ROLE_RANK.get(cur.get("role") or "", 0):
            cur["role"] = u["role"]
        # last_login: 더 최근
        if (u.get("last_login") or "") > (cur.get("last_login") or ""):
            cur["last_login"] = u["last_login"]
        # is_dormant: 한 쪽이라도 활성이면 활성
        if not u.get("is_dormant"):
            cur["is_dormant"] = False
        # 이름/프로필 정보: 채워진 쪽 우선
        for fld in ("name", "region", "team", "email", "phone"):
            if not cur.get(fld) and u.get(fld):
                cur[fld] = u[fld]
    users = list(deduped.values())

    users.sort(key=lambda u: u.get("name") or "")
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
    logger.warning("CORS_ALLOWED_ORIGINS 환경변수 미설정 — 기본 도메인만 허용")
    ALLOWED_ORIGINS = [
        "http://localhost:3000",
        "http://localhost:8080",
        "https://playground.idcube.sktelecom.com",
    ]
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Accept", "X-Admin-Key", "X-Filename", "X-Refreshed-Token"],
    expose_headers=[
        "Content-Length",
        "Content-Disposition",
        "X-Change-Count",
        "X-Target-Count",
        "X-Change-Types",
    ],
    max_age=3600,
)

# GZip 압축 - JSON 응답 80%+ 압축, 네트워크 전송 대폭 감소
app.add_middleware(GZipMiddleware, minimum_size=1000)


@app.middleware("http")
async def token_refresh_middleware(request: Request, call_next):
    """인증된 요청의 토큰 잔여 수명이 절반 이하이면 응답 헤더에 새 토큰 포함"""
    request.state.refreshed_token = None
    response = await call_next(request)
    refreshed = getattr(request.state, "refreshed_token", None)
    if refreshed:
        response.headers["X-Refreshed-Token"] = refreshed
    return response


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
    asyncio.create_task(asyncio.to_thread(_ensure_route_baskets_table))
    asyncio.create_task(_recover_stuck_jobs())
    _ds_job_worker_task = asyncio.create_task(_job_worker_loop())

    # 설치확인서 조회 캐시 미리 빌드 (백그라운드) + 매일 00:00 자동 갱신
    asyncio.create_task(asyncio.to_thread(_cert_cache_load))
    asyncio.create_task(_cert_cache_daily_scheduler())

    # SQLite DB 매일 03:00 KST S3 자동 백업
    asyncio.create_task(_sqlite_backup_daily_scheduler())

    # 휴면계정 처리 매일 09:00 KST 실행 (예고 메일 + 자동 전환)
    asyncio.create_task(_dormant_account_daily_scheduler())

    # 부적합 시정기한 D-60/D-30/D-14/D-7 알림 매일 08:30 KST
    asyncio.create_task(_inadequate_deadline_scheduler())

    # Rate limiter + 호출명칭 세션 5분 주기 정리
    async def _rl_cleanup():
        while True:
            await asyncio.sleep(300)
            _rate_limiter.cleanup()
            _cleanup_callname_sessions()
    asyncio.create_task(_rl_cleanup())

    # 서버 시작 시 고아 임시파일 즉시 정리 + 10분 주기 정리
    await asyncio.to_thread(_cleanup_stale_temp_files, 0)  # 시작 시 전부 삭제
    async def _temp_cleanup_loop():
        while True:
            await asyncio.sleep(600)  # 10분
            await asyncio.to_thread(_cleanup_stale_temp_files, 3600)  # 1시간 이상만
    asyncio.create_task(_temp_cleanup_loop())

    # 서버 시작 시 xlsx 캐시 없는 본부 자동 스캔 → 빌드 큐 등록
    async def _startup_xlsx_scan():
        try:
            await asyncio.sleep(3)  # 서버 초기화 완료 대기
            queued, skipped = await asyncio.to_thread(_scan_missing_xlsx_caches_sync)
            if queued:
                logger.info(f"DS startup: xlsx 빌드 {len(queued)}건 자동 등록: {queued}")
        except Exception as e:
            logger.warning(f"DS startup xlsx scan error: {e}")
    asyncio.create_task(_startup_xlsx_scan())

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
from botocore.config import Config as _BotoConfig
_boto_config = _BotoConfig(max_pool_connections=25)
_s3_client = boto3.client('s3', region_name=S3_REGION, config=_boto_config)
# xlsx 대용량 다운로드 전용 — read_timeout 600초, hang 방지
_s3_client_xlsx = boto3.client('s3', region_name=S3_REGION, config=_BotoConfig(
    max_pool_connections=2, connect_timeout=10, read_timeout=600,
    retries={'max_attempts': 1},
))
_dynamodb_resource = boto3.resource('dynamodb', region_name=S3_REGION, config=_boto_config)
_dynamodb_client = boto3.client('dynamodb', region_name=S3_REGION, config=_boto_config)


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


@app.post("/auth/refresh")
async def auth_refresh_token(request: Request):
    """현재 유효한 토큰으로 새 토큰 발급 (세션 연장용)"""
    empno = await _verify_auth(request)
    new_token = _generate_token(empno)
    return {"token": new_token, "expiresIn": AUTH_TOKEN_EXPIRY}


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
            # 사번 대문자 정규화 (Users 테이블 키와 일치시키기)
            username = req.username.upper()
            # 휴면계정 차단
            role_info = await asyncio.to_thread(_get_user_role_info, username)
            if role_info["is_dormant"]:
                return JSONResponse(
                    status_code=403,
                    content={"result": "fail", "message": "휴면 계정입니다. 관리자에게 문의하거나 이메일 인증을 진행해 주세요."},
                )
            token = _generate_token(username)
            await asyncio.to_thread(_ensure_user_in_roles_sync, username)
            await asyncio.to_thread(_update_last_login, username)
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


# ── 개발용 테스트 로그인 ────────────────────────────────────
class DevLoginRequest(BaseModel):
    empno: str
    name: str
    region: str  # "강남본부", "강북본부" 등
    team: str = ""
    role: str = "member"  # "admin", "manager", "member"


@app.post("/auth/dev-login")
async def dev_login(req: DevLoginRequest):
    """개발용 테스트 로그인 (SSO 인증 없이 임의 계정으로 토큰 발급)"""
    if not DEV_LOGIN_ENABLED:
        raise HTTPException(403, "개발 모드가 비활성화되어 있습니다")
    if req.role not in VALID_ROLES:
        raise HTTPException(400, f"유효하지 않은 역할: {req.role}")

    token = _generate_token(req.empno)
    _dev_users[req.empno] = {
        "name": req.name, "region": req.region,
        "team": req.team, "role": req.role,
    }
    logger.info(f"[DEV-LOGIN] empno={req.empno}, name={req.name}, region={req.region}, role={req.role}")

    return {
        "result": "ok",
        "token": token,
        "expiresIn": AUTH_TOKEN_EXPIRY,
        "dev_mode": True,
        "user": {
            "empno": req.empno,
            "name": req.name,
            "region": req.region,
            "team": req.team,
            "role": req.role,
        },
    }


@app.get("/auth/dev-login/status")
async def dev_login_status():
    """개발 로그인 모드 활성화 여부 확인"""
    return {"enabled": DEV_LOGIN_ENABLED}


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


def _update_last_login(empno: str):
    """로그인 시 last_login 업데이트 (kca-user-roles 테이블)"""
    try:
        from datetime import datetime, timezone
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        table.update_item(
            Key={"user_id": empno},
            UpdateExpression="SET last_login = :ts",
            ExpressionAttributeValues={":ts": datetime.now(timezone.utc).isoformat()},
        )
    except Exception as e:
        logger.warning(f"last_login 업데이트 실패 ({empno}): {e}")


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
            # dev-login 사용자 fallback
            dev = _dev_users.get(empno)
            if dev:
                return {
                    "success": True, "empno": empno,
                    "name": dev["name"], "region": dev["region"],
                    "team": dev["team"], "role": dev["role"],
                }
            return {"success": False, "empno": empno, "message": "User not found"}

        # kca-user-roles 테이블에 자동 등록 (없으면 member로)
        await asyncio.to_thread(_ensure_user_in_roles_sync, empno)

        # role + last_login + is_dormant은 kca-user-roles에서 조회
        role_info = await asyncio.to_thread(_get_user_role_info, empno)
        role       = role_info["role"]
        last_login = role_info["last_login"]
        is_dormant = role_info["is_dormant"]

        return {
            "success": True,
            "empno": empno,
            "name": user.get("name"),
            "region": user.get("region"),
            "team": user.get("team"),
            "email": user.get("email"),
            "phone": user.get("phone_number"),
            "role": role,
            "last_login": last_login,
            "is_dormant": is_dormant,
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


@app.post("/admin/undormant/{empno}")
async def admin_undormant(empno: str, request: Request):
    """휴면계정 해제 — admin 전용"""
    caller_id = await _verify_auth(request)
    caller_role = await asyncio.to_thread(_get_user_role_sync, caller_id)
    if caller_role != "admin":
        raise HTTPException(status_code=403, detail="admin 권한 필요")
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        table.update_item(
            Key={"user_id": empno},
            UpdateExpression="SET is_dormant = :f, last_login = :now REMOVE notified_d7, notified_d3, notified_d1",
            ExpressionAttributeValues={
                ":f": False,
                ":now": datetime.now(timezone.utc).isoformat(),
            },
        )
        logger.info(f"휴면 해제: {empno} (by {caller_id})")
        return {"success": True, "empno": empno, "message": "휴면 해제 완료"}
    except Exception as e:
        logger.error(f"휴면 해제 실패 ({empno}): {e}")
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
                    try: wb = xlrd.open_workbook(xls_tmp)
                    except: wb = xlrd.open_workbook(xls_tmp, ignore_workbook_corruption=True)
                except Exception:
                    if os.path.exists(xls_tmp): os.remove(xls_tmp)
                    continue

                for sheet_idx in range(wb.nsheets):
                    sheet = wb.sheet_by_index(sheet_idx)
                    orig_sheet_name = sheet.name.strip()
                    if sheet.nrows < 2: continue
                    sheet_name = f"{orig_sheet_name}(검사전)" if fname in hundred_files else orig_sheet_name

                    headers = [_xlrd_cell_to_str(sheet, 0, c) for c in range(sheet.ncols)]
                    headers = [h for h in headers if h]
                    if not headers: continue

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
                    try: wb = xlrd.open_workbook(xls_tmp_path)
                    except: wb = xlrd.open_workbook(xls_tmp_path, ignore_workbook_corruption=True)
                except Exception:
                    if os.path.exists(xls_tmp_path): os.remove(xls_tmp_path)
                    continue

                file_rows = 0
                for sheet_idx in range(wb.nsheets):
                    sheet = wb.sheet_by_index(sheet_idx)
                    orig_sheet_name = sheet.name.strip()
                    if sheet.nrows < 2: continue
                    sheet_name = f"{orig_sheet_name}(검사전)" if fname in hundred_files else orig_sheet_name
                    if sheet_name not in global_sheet_headers: continue

                    col_map = header_col_maps[sheet_name]
                    num_cols = len(global_sheet_headers[sheet_name])
                    xls_col_map = [(col, col_map[col_h]) for col in range(sheet.ncols) if (col_h := _xlrd_cell_to_str(sheet, 0, col)) and col_h in col_map]
                    if not xls_col_map: continue

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

        start_wait_time = time.time()
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

            if time.time() - start_wait_time > 10800:
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
                tbl = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_uploads"])
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

        start_wait_time = time.time()
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

            if time.time() - start_wait_time > 10800:
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
    _xlsx_build_start_time = time.time()
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
                    if not _cert_cache_db_path:
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


@app.get("/ds/xlsx-build-status")
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
        elapsed_sec = int(time.time() - _xlsx_build_start_time)
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


_city_hdqt_cache: dict | None = None
_city_hdqt_cache_ts: float = 0.0
_CITY_HDQT_CACHE_TTL = 3600 * 6  # 6시간

@app.get("/ds/city-hdqt-map")
async def ds_city_hdqt_map(request: Request):
    """inspection_targets 전체에서 시/군별 최다 access담당 집계 반환.
    응답: { "경기 시흥시": {"본부": "인천", "건수": 1847, "비율": 99.2}, ... }
    6시간 캐시.
    """
    await _verify_auth(request)
    import sqlite3, time
    global _city_hdqt_cache, _city_hdqt_cache_ts
    now = time.time()
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


@app.get("/ds/proxy-xlsx")
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


def _s3_key_exists(s3, key: str) -> bool:
    try:
        s3.head_object(Bucket=S3_BUCKET_NAME, Key=key)
        return True
    except Exception:
        return False


def _scan_missing_xlsx_caches_sync() -> tuple:
    """uploads 테이블 스캔 → S3 xlsx 캐시 없는 항목 찾아 빌드 큐 등록 (동기)"""
    uploads_table = _dynamodb_resource.Table(DYNAMODB_TABLES["ds_uploads"])
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


@app.post("/ds/trigger-xlsx-build")
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
            "Content-Disposition": f"attachment; filename*=UTF-8''{quote(filename)}",
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
            zpcode TEXT, zpkcode TEXT, zpcname TEXT, area_hdofc_nm TEXT, ons_team_nm TEXT, zpirty3 TEXT,
            eqp_ser_no TEXT, zpprac1 TEXT, eqp_type TEXT, max_seqno TEXT,
            zpannu1 TEXT, swing_list TEXT
        )""")
        conn.execute("DELETE FROM cert")

        batch = []
        total = 0
        for row in _stream_s3_csvs():
            batch.append((
                row.get("zpwino", ""), row.get("zpwina", ""),
                row.get("zpwiadr", ""), row.get("zpcode", ""), row.get("zpkcode", ""),
                row.get("zpcname", ""),
                row.get("area_hdofc_nm", ""), row.get("ons_team_nm", ""),
                row.get("zpirty3", ""), row.get("eqp_ser_no", ""),
                row.get("zpprac1", ""), row.get("eqp_type", ""),
                row.get("max_seqno", ""),
                row.get("zpannu1", ""), row.get("swing_list", ""),
            ))
            if len(batch) >= 5000:
                conn.executemany("INSERT INTO cert VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
                total += len(batch)
                batch.clear()
        if batch:
            conn.executemany("INSERT INTO cert VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
            total += len(batch)

        conn.execute("CREATE INDEX IF NOT EXISTS idx_zpwino ON cert(zpwino)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_zpwina ON cert(zpwina)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_zpwiadr ON cert(zpwiadr)")
        # Phase 5 성능: inspection_data가 IN (zpcode...)로 lookup
        conn.execute("CREATE INDEX IF NOT EXISTS idx_zpcode ON cert(zpcode)")
        # 통시/공대 보완용 복합 키 인덱스 (허가번호+호출명칭)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_zpwino_zpwina ON cert(zpwino, zpwina)")
        conn.commit()
        conn.close()

        # 원자적 교체 (os.replace = atomic rename, overwrites existing on all OS)
        os.replace(tmp_path, db_path)
        # 고아 WAL/SHM 파일 제거 (rename 전 .tmp-wal, .tmp-shm)
        for _stale_ext in ('-wal', '-shm'):
            _stale = tmp_path + _stale_ext
            if os.path.exists(_stale):
                try:
                    os.remove(_stale)
                except Exception:
                    pass

        _cert_cache_db_path = db_path
        _cert_cache_ts = _time_mod.time()
        logger.info(f"설치확인서 SQLite 캐시 빌드 완료: {total}행, {_cert_cache_ts - t0:.1f}초")

        # 주소→팀 학습 맵 워밍업 (import 시 즉시 캐시 히트)
        import tempfile as _tf2, json as _jw
        _addr_cache = os.path.join(_tf2.gettempdir(), "learned_addr_map.json")
        _should_warm = True
        if os.path.exists(_addr_cache):
            try:
                _age = _time_mod.time() - os.path.getmtime(_addr_cache)
                if _age < 86400:
                    with open(_addr_cache, 'r', encoding='utf-8') as _f:
                        _existing = _jw.load(_f)
                    if _existing:  # 유효한 캐시 있으면 워밍업 생략
                        _should_warm = False
            except Exception:
                pass
        if _should_warm:
            _addr_map = _learn_addr_map_from_cert_db(db_path=db_path)
            with open(_addr_cache, 'w', encoding='utf-8') as _f:
                _jw.dump(_addr_map, _f, ensure_ascii=False)
            logger.info(f"주소→팀 학습 맵 워밍업 완료: {len(_addr_map)}개 키워드")


def _cert_cache_force_rebuild():
    """캐시 TTL 무시하고 강제 재빌드."""
    global _cert_cache_ts
    _cert_cache_ts = 0.0  # TTL 만료시켜서 재빌드 유도
    _cert_cache_load()


# ── SQLite S3 백업 ──────────────────────────────────────────────────────────

_SQLITE_BACKUP_DBS = [
    ("inspection", lambda: _INSP_DB),
    ("ds_detail",  lambda: _DS_DETAIL_DB),
]
_SQLITE_BACKUP_RETAIN_DAYS = 7  # S3에 보관할 최대 일수

def _backup_sqlite_to_s3_sync():
    """각 SQLite DB를 S3에 날짜별 백업. 7일치 초과 파일 자동 삭제."""
    import sqlite3 as _sq3
    from datetime import datetime, timezone, timedelta
    KST = timezone(timedelta(hours=9))
    date_str = datetime.now(KST).strftime("%Y-%m-%d")
    s3 = get_s3_client()

    for name, path_fn in _SQLITE_BACKUP_DBS:
        db_path = path_fn()
        if not db_path or not os.path.exists(db_path):
            continue
        tmp = f"/tmp/sqlite_backup_{name}_{date_str}.db"
        try:
            # SQLite backup API: WAL 모드에서도 일관된 스냅샷 보장
            src = _sq3.connect(db_path, timeout=30)
            dst = _sq3.connect(tmp)
            src.backup(dst)
            dst.close(); src.close()

            s3_key = f"backups/sqlite/{name}/{date_str}.db"
            s3.upload_file(tmp, S3_BUCKET_NAME, s3_key)
            logger.info(f"SQLite 백업 완료: {s3_key} ({os.path.getsize(tmp):,} bytes)")

            # 7일치 초과 오래된 백업 삭제
            cutoff = datetime.now(KST) - timedelta(days=_SQLITE_BACKUP_RETAIN_DAYS)
            prefix = f"backups/sqlite/{name}/"
            resp = s3.list_objects_v2(Bucket=S3_BUCKET_NAME, Prefix=prefix)
            for obj in resp.get("Contents", []):
                key = obj["Key"]
                # 파일명에서 날짜 추출: backups/sqlite/{name}/YYYY-MM-DD.db
                fname = os.path.basename(key).replace(".db", "")
                try:
                    obj_date = datetime.strptime(fname, "%Y-%m-%d").replace(tzinfo=KST)
                    if obj_date < cutoff:
                        s3.delete_object(Bucket=S3_BUCKET_NAME, Key=key)
                        logger.info(f"오래된 백업 삭제: {key}")
                except ValueError:
                    pass  # 날짜 형식 아닌 파일은 무시
        except Exception as e:
            logger.error(f"SQLite 백업 실패 ({name}): {e}")
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)


# ── 휴면계정 관리 ──────────────────────────────────────────────────────────────

# 환경변수
_SES_FROM_EMAIL = os.getenv("SES_FROM_EMAIL", "noreply@ksa.skons.net")
_DORMANT_DAYS = int(os.getenv("DORMANT_DAYS", "30"))   # 휴면 전환 기준 (일)
_SERVICE_NAME = os.getenv("SERVICE_NAME", "KSA 무선국 정기검사 관리 시스템")
_SERVICE_URL  = os.getenv("SERVICE_URL",  "https://ksa.skons.net")


def _send_ses_email(to_address: str, subject: str, body_html: str) -> bool:
    """AWS SES 로 HTML 메일 발송. 성공 True, 실패 False."""
    try:
        ses = boto3.client("ses", region_name=S3_REGION)
        ses.send_email(
            Source=_SES_FROM_EMAIL,
            Destination={"ToAddresses": [to_address]},
            Message={
                "Subject": {"Data": subject, "Charset": "UTF-8"},
                "Body": {"Html": {"Data": body_html, "Charset": "UTF-8"}},
            },
        )
        return True
    except Exception as e:
        logger.error(f"SES 메일 발송 실패 ({to_address}): {e}")
        return False


def _dormant_email_html(name: str, days_left: int, last_login_str: str) -> str:
    """휴면 예고 메일 HTML 본문 생성."""
    color = "#E53935" if days_left == 1 else ("#FF7043" if days_left == 3 else "#FFA726")
    return f"""
<!DOCTYPE html>
<html lang="ko">
<head><meta charset="UTF-8"></head>
<body style="font-family:'Apple SD Gothic Neo',sans-serif;background:#f5f5f5;padding:0;margin:0;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f5f5f5;padding:30px 0;">
    <tr><td align="center">
      <table width="600" cellpadding="0" cellspacing="0"
             style="background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.1);">
        <!-- 헤더 -->
        <tr>
          <td style="background:{color};padding:28px 32px;">
            <p style="margin:0;color:#fff;font-size:20px;font-weight:700;">{_SERVICE_NAME}</p>
            <p style="margin:6px 0 0;color:rgba(255,255,255,.85);font-size:13px;">휴면계정 전환 예정 안내</p>
          </td>
        </tr>
        <!-- 본문 -->
        <tr>
          <td style="padding:32px 32px 24px;">
            <p style="margin:0 0 16px;font-size:15px;color:#111827;">
              안녕하세요, <strong>{name}</strong>님.
            </p>
            <p style="margin:0 0 16px;font-size:14px;color:#374151;line-height:1.7;">
              마지막 로그인 일시(<strong>{last_login_str}</strong>) 기준으로<br>
              미접속 기간이 <strong>{_DORMANT_DAYS}일</strong>에 가까워지고 있습니다.<br>
              <strong style="color:{color};">{days_left}일 후</strong> 계정이 자동으로 <strong>휴면 상태</strong>로 전환됩니다.
            </p>
            <div style="background:#FFF3E0;border-left:4px solid {color};
                        padding:14px 16px;border-radius:4px;margin:0 0 24px;">
              <p style="margin:0;font-size:13px;color:#374151;">
                휴면 전환 후에는 로그인이 제한되며, 재활성화를 위해 관리자에게 문의하거나<br>
                아래 시스템에 접속하여 이메일 인증을 진행해야 합니다.
              </p>
            </div>
            <p style="margin:0 0 24px;font-size:14px;color:#374151;">
              계속 서비스를 이용하시려면 아래 버튼을 클릭하여 로그인해 주세요.
            </p>
            <table cellpadding="0" cellspacing="0">
              <tr>
                <td style="background:{color};border-radius:8px;padding:12px 28px;">
                  <a href="{_SERVICE_URL}" style="color:#fff;text-decoration:none;
                     font-size:14px;font-weight:700;">지금 로그인하기</a>
                </td>
              </tr>
            </table>
          </td>
        </tr>
        <!-- 푸터 -->
        <tr>
          <td style="padding:16px 32px;border-top:1px solid #E5E7EB;
                     background:#FAFAFA;font-size:12px;color:#9CA3AF;">
            본 메일은 발신 전용입니다. 문의는 시스템 관리자에게 연락해 주세요.<br>
            ⓒ {_SERVICE_NAME}
          </td>
        </tr>
      </table>
    </td></tr>
  </table>
</body>
</html>"""


def _run_dormant_job_sync():
    """
    휴면계정 배치 (동기, 스레드에서 실행):
    - kca-user-roles 전체 scan
    - last_login 기준으로
        · 30일 초과  → is_dormant=true 마킹
        · 23일 경과 (D-7) / 27일 경과 (D-3) / 29일 경과 (D-1) → 예고 메일
    """
    from datetime import datetime, timezone, timedelta

    try:
        dynamodb = get_dynamodb_resource()
        roles_table  = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        users_table  = dynamodb.Table(DYNAMODB_TABLES["users"])

        now = datetime.now(timezone.utc)
        dormant_cutoff    = now - timedelta(days=_DORMANT_DAYS)
        notify_days = [7, 3, 1]

        # kca-user-roles 전체 scan (소규모 테이블)
        items = []
        resp = roles_table.scan(ProjectionExpression="user_id, #r, last_login, is_dormant",
                                ExpressionAttributeNames={"#r": "role"})
        items.extend(resp.get("Items", []))
        while "LastEvaluatedKey" in resp:
            resp = roles_table.scan(
                ProjectionExpression="user_id, #r, last_login, is_dormant",
                ExpressionAttributeNames={"#r": "role"},
                ExclusiveStartKey=resp["LastEvaluatedKey"],
            )
            items.extend(resp.get("Items", []))

        converted, notified = 0, 0
        for item in items:
            empno       = item.get("user_id", "")
            last_login  = item.get("last_login", "")
            is_dormant  = item.get("is_dormant", False)

            if not last_login or is_dormant:
                continue  # 로그인 이력 없거나 이미 휴면이면 스킵

            try:
                last_dt = datetime.fromisoformat(last_login)
                if last_dt.tzinfo is None:
                    last_dt = last_dt.replace(tzinfo=timezone.utc)
            except ValueError:
                continue

            elapsed_days = (now - last_dt).days

            # 휴면 전환
            if elapsed_days >= _DORMANT_DAYS:
                roles_table.update_item(
                    Key={"user_id": empno},
                    UpdateExpression="SET is_dormant = :v",
                    ExpressionAttributeValues={":v": True},
                )
                logger.info(f"휴면 전환: {empno} (미접속 {elapsed_days}일)")
                converted += 1
                continue

            # 예고 메일 (D-7, D-3, D-1)
            days_left = _DORMANT_DAYS - elapsed_days
            if days_left not in notify_days:
                continue

            # 이미 해당 days_left 메일을 보냈는지 확인
            notified_key = f"notified_d{days_left}"
            if item.get(notified_key):
                continue

            # users 테이블에서 이름 + 이메일 조회
            try:
                user_resp = users_table.get_item(
                    Key={"user_id": empno},
                    ProjectionExpression="#n, email",
                    ExpressionAttributeNames={"#n": "name"},
                )
                user = user_resp.get("Item", {})
                email = user.get("email", "")
                name  = user.get("name", empno)
            except Exception:
                continue

            if not email:
                continue

            last_login_kst = (last_dt + timedelta(hours=9)).strftime("%Y-%m-%d %H:%M")
            subject = f"[{_SERVICE_NAME}] 휴면계정 전환 {days_left}일 전 안내"
            html    = _dormant_email_html(name, days_left, last_login_kst)

            if _send_ses_email(email, subject, html):
                # 발송 성공 플래그 저장 (중복 발송 방지)
                roles_table.update_item(
                    Key={"user_id": empno},
                    UpdateExpression=f"SET {notified_key} = :v",
                    ExpressionAttributeValues={":v": True},
                )
                logger.info(f"휴면 예고 메일 발송: {empno} → {email} (D-{days_left})")
                notified += 1

        logger.info(f"휴면계정 배치 완료 — 전환: {converted}명, 예고 메일: {notified}건")

    except Exception as e:
        logger.error(f"휴면계정 배치 오류: {e}")


async def _dormant_account_daily_scheduler():
    """매일 09:00 KST 휴면계정 처리 실행."""
    from datetime import datetime, timezone, timedelta
    KST = timezone(timedelta(hours=9))
    while True:
        now = datetime.now(KST)
        next_run = now.replace(hour=9, minute=0, second=0, microsecond=0)
        if now >= next_run:
            next_run += timedelta(days=1)
        wait_seconds = (next_run - now).total_seconds()
        logger.info(f"휴면계정 배치 다음 실행: {next_run.strftime('%Y-%m-%d %H:%M')} KST ({wait_seconds:.0f}초 후)")
        await asyncio.sleep(wait_seconds)
        await asyncio.to_thread(_run_dormant_job_sync)


async def _sqlite_backup_daily_scheduler():
    """매일 03:00 KST SQLite → S3 자동 백업."""
    from datetime import datetime, timezone, timedelta
    KST = timezone(timedelta(hours=9))
    while True:
        now = datetime.now(KST)
        next_run = (now + timedelta(days=1)).replace(hour=3, minute=0, second=0, microsecond=0)
        if now.hour < 3:  # 오늘 03:00이 아직 안 지났으면 오늘 03:00
            next_run = now.replace(hour=3, minute=0, second=0, microsecond=0)
        wait_seconds = (next_run - now).total_seconds()
        logger.info(f"SQLite 백업 다음 실행: {next_run.strftime('%Y-%m-%d %H:%M')} KST ({wait_seconds:.0f}초 후)")
        await asyncio.sleep(wait_seconds)
        await asyncio.to_thread(_backup_sqlite_to_s3_sync)


async def _inadequate_deadline_scheduler():
    """매일 08:30 KST 부적합 시정기한 D-60/D-30/D-14/D-7 알림 발송."""
    from datetime import datetime, timezone, timedelta
    KST = timezone(timedelta(hours=9))
    while True:
        now = datetime.now(KST)
        next_run = now.replace(hour=8, minute=30, second=0, microsecond=0)
        if now >= next_run:
            next_run += timedelta(days=1)
        wait_seconds = (next_run - now).total_seconds()
        logger.info(f"부적합 시정기한 알림 다음 실행: {next_run.strftime('%Y-%m-%d %H:%M')} KST ({wait_seconds:.0f}초 후)")
        await asyncio.sleep(wait_seconds)
        try:
            await asyncio.to_thread(_run_inadequate_deadline_notify_sync)
            logger.info("부적합 시정기한 알림 발송 완료")
        except Exception as e:
            logger.error(f"부적합 시정기한 알림 발송 실패: {e}")


def _run_inadequate_deadline_notify_sync():
    """부적합 시정기한 D-60/D-30/D-14/D-7 해당 건을 조회하여
    해당 본부 manager에게 알림을 발송한다."""
    from datetime import datetime, timezone, timedelta
    KST = timezone(timedelta(hours=9))
    today = datetime.now(KST).date()

    THRESHOLDS = [60, 30, 14, 7]  # D-N 기준

    # 1. 부적합 관리 DB에서 미완료 건 전체 조회
    conn_insp = sqlite3.connect(_INSP_DB, timeout=30)
    conn_insp.row_factory = sqlite3.Row
    try:
        rows = conn_insp.execute(
            "SELECT 허가번호, 호출명칭, region, skt본부, 시정기한 "
            "FROM inadequate_management "
            "WHERE status != '완료' AND 시정기한 != '' AND 시정기한 IS NOT NULL"
        ).fetchall()
    finally:
        conn_insp.close()

    if not rows:
        return

    # 2. D-N 해당 건 필터링
    targets = []  # [(region, 허가번호, 호출명칭, 시정기한, d_left)]
    for row in rows:
        try:
            deadline = datetime.strptime(row['시정기한'], '%Y-%m-%d').date()
            d_left = (deadline - today).days
            if d_left in THRESHOLDS:
                targets.append({
                    'region': row['region'] or row['skt본부'] or '',
                    '허가번호': row['허가번호'],
                    '호출명칭': row['호출명칭'] or '',
                    '시정기한': row['시정기한'],
                    'd_left': d_left,
                })
        except Exception:
            continue

    if not targets:
        return

    logger.info(f"부적합 시정기한 알림 대상: {len(targets)}건")

    # 3. kca-user-roles 스캔 → region 매칭 manager 목록 수집
    try:
        all_users = _list_all_users_sync()
    except Exception as e:
        logger.error(f"부적합 알림: 사용자 목록 조회 실패: {e}")
        return

    # region → manager empno 목록 매핑
    region_managers = {}  # {region_key: [empno, ...]}
    for u in all_users:
        if u.get('role') not in ('manager', 'admin'):
            continue
        if u.get('is_dormant'):
            continue
        r = (u.get('region') or '').strip()
        if not r:
            continue
        region_managers.setdefault(r, []).append(u['empno'])

    # 4. 알림 INSERT
    conn_comm = sqlite3.connect(_COMMUNITY_DB, timeout=30)
    try:
        _now = datetime.now(timezone.utc).isoformat()
        inserted = 0
        for item in targets:
            region = item['region']
            d_left = item['d_left']
            허가번호 = item['허가번호']
            호출명칭 = item['호출명칭']
            시정기한 = item['시정기한']

            # region 부분 매칭 (예: "강남본부" ↔ "강남")
            matched_empnos = []
            for r_key, empnos in region_managers.items():
                if region in r_key or r_key in region:
                    matched_empnos.extend(empnos)

            if not matched_empnos:
                logger.warning(f"부적합 알림: region '{region}' 매칭 manager 없음 ({허가번호})")
                continue

            title = f'부적합 시정기한 D-{d_left} 알림'
            body = f'[{region}] {호출명칭} ({허가번호}) 시정기한: {시정기한}'

            for empno in set(matched_empnos):
                # 동일 허가번호 + D-N 에 대해 오늘 이미 발송된 알림이면 중복 방지
                already = conn_comm.execute(
                    "SELECT id FROM notifications "
                    "WHERE user_empno=? AND title=? AND body=? AND DATE(created_at)=DATE(?)",
                    (empno, title, body, _now),
                ).fetchone()
                if already:
                    continue
                conn_comm.execute(
                    "INSERT INTO notifications (user_empno, type, title, body, related_type, related_id, created_at) "
                    "VALUES (?, 'deadline', ?, ?, 'inadequate', 0, ?)",
                    (empno, title, body, _now),
                )
                inserted += 1

        conn_comm.commit()
        logger.info(f"부적합 시정기한 알림 INSERT: {inserted}건")
    finally:
        conn_comm.close()


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
    """설치확인서 일괄 조회 — IN 쿼리 2-pass (zpwino→zpwina 순서)."""
    import sqlite3
    if not zpwino_list:
        return {}
    _cert_cache_load()
    cols = ["zpwino", "zpwina", "zpwiadr", "zpcode", "area_hdofc_nm", "ons_team_nm", "zpirty3", "eqp_ser_no", "zpwilat", "zpwilon", "max_seqno", "zpprac1"]
    col_str = ', '.join(cols)
    results = {}
    BATCH = 900
    try:
        conn = sqlite3.connect(_cert_cache_db_path, timeout=30)
        conn.row_factory = sqlite3.Row

        # pass1: zpwino IN — 원본 & 하이픈 제거본 둘 다 시도 (인덱스 활용)
        norms = list({q.replace('-', '').strip() for q in zpwino_list})
        originals = list(dict.fromkeys(zpwino_list))  # 순서 보존 중복 제거
        norm_map = {q.replace('-', '').strip(): q for q in originals}  # norm→original
        for batch in (originals, norms):
            remaining_batch = [q for q in batch if norm_map.get(q.replace('-','').strip(), q) not in results]
            if not remaining_batch:
                continue
            for i in range(0, len(remaining_batch), BATCH):
                sub = remaining_batch[i:i+BATCH]
                ph = ','.join('?' * len(sub))
                for row in conn.execute(
                    f"SELECT {col_str} FROM cert WHERE zpwino IN ({ph})", sub
                ):
                    rd = dict(row)
                    wino = (rd.get('zpwino') or '').strip()
                    orig_q = norm_map.get(wino.replace('-', ''), wino)
                    if orig_q not in results:
                        results[orig_q] = {c: (rd.get(c) or '') for c in cols}

        # pass2: zpwina IN — 아직 못 찾은 항목
        missing = [q for q in originals if q not in results]
        if missing:
            for i in range(0, len(missing), BATCH):
                sub = missing[i:i+BATCH]
                ph = ','.join('?' * len(sub))
                for row in conn.execute(
                    f"SELECT {col_str} FROM cert WHERE zpwina IN ({ph})", sub
                ):
                    rd = dict(row)
                    zpwina_val = (rd.get('zpwina') or '').strip()
                    if zpwina_val in sub and zpwina_val not in results:
                        results[zpwina_val] = {c: (rd.get(c) or '') for c in cols}

        conn.close()
        logger.info(f"[cert_batch] 요청={len(originals)} 조회={len(results)}")
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
        conn = sqlite3.connect(_cert_cache_db_path, timeout=30)
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

        _callname_db_row_count = uploaded_rows
        # 새 CSV로 cert_cache 재빌드 (백그라운드 — ERP비교/호출명칭 조회에 즉시 반영)
        import threading as _th
        _th.Thread(target=_cert_cache_force_rebuild, daemon=True).start()

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


# 철탑형태 그룹: 같은 그룹에 속하면 부분일치로 인정
# (간이폴, 분산폴, 비기준 설치대 계열이 ERP/DS에서 서로 다른 정규화 값으로 갈리는 문제 해결)
_TOWER_TYPE_GROUPS = [
    {
        "간이폴 및 비기준 설치대",
        "복합형(원폴,분산프레임 등)",
        "간이폴, 분산폴 및 비기준 설치대",
    },
]


def _tower_group(val: str):
    """정규화된 설치대 값이 속하는 그룹 set을 반환. 없으면 None."""
    if not val:
        return None
    for g in _TOWER_TYPE_GROUPS:
        if val in g:
            return g
    return None


def _parse_serial_strings(s: str) -> list:
    """쉼표로 구분된 일련번호 문자열을 리스트로 변환."""
    if not s:
        return []
    return [x.strip().lower() for x in s.split(",") if x.strip()]


def _compare_values(erp_val: str, ds_val: str, normalize_fn=None) -> str:
    """ERP vs DS 값 비교. 일치/부분일치/불일치/DS누락/확인필요 반환.

    - 양쪽 다 빈 값: '확인필요' (외부 사이트에서 수동 확인)
    - ERP만 빈 값: '확인필요' (ERP 누락 — 외부 확인 후 판단)
    - DS만 빈 값: 'DS누락' (변경개설 대상)
    """
    erp_empty = not erp_val
    ds_empty = not ds_val
    if erp_empty and ds_empty:
        return "확인필요"
    if ds_empty:
        return "DS누락"
    if erp_empty:
        return "확인필요"
    if normalize_fn:
        erp_parts = [normalize_fn(x.strip()) for x in erp_val.split(",") if x.strip()]
        ds_parts = [normalize_fn(x.strip()) for x in ds_val.split(",") if x.strip()]
    else:
        erp_parts = _parse_serial_strings(erp_val)
        ds_parts = _parse_serial_strings(ds_val)
    if not erp_parts and not ds_parts:
        return "확인필요"
    if not ds_parts:
        return "DS누락"
    if not erp_parts:
        return "확인필요"
    if set(erp_parts) == set(ds_parts) and len(erp_parts) == len(ds_parts):
        return "일치"
    elif set(erp_parts).intersection(ds_parts):
        return "부분일치"
    # 설치대 그룹 매칭: 양쪽 값이 같은 그룹에 속하면 부분일치
    if normalize_fn is _normalize_tower:
        for ep in erp_parts:
            g = _tower_group(ep)
            if g and any(dp in g for dp in ds_parts):
                return "부분일치"
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


# ============================================================
# 안테나 방위각 batch 조회 (현장 수검 Map 부채꼴 표시용)
# ============================================================

# SKT band code → 주파수 대역
_SKT_BAND_MAP = {
    "B5": "800M",
    "B3": "1.8G",
    "B1": "2.1G",
    "B7": "2.6G",
}


def _extract_service_band(zpannu1: str, eqp_type: str, zpcname: str) -> tuple:
    """(service, band) 추출. service: LTE/5G/WCDMA/3G/None, band: 800M/1.8G/2.1G/2.6G/3.5G/28G/None"""
    annu = (zpannu1 or "").strip().upper()
    eqp = (eqp_type or "").strip()
    zn = (zpcname or "").strip()

    # service 매핑
    if annu == "5G" or "5G" in annu:
        service = "5G"
    elif annu == "LTE":
        service = "LTE"
    elif annu in ("WCDMA", "3G"):
        service = "3G"
    elif annu == "CDMA":
        service = "CDMA"
    else:
        service = annu or None

    # band 매핑
    band = None
    if service == "5G":
        if "28G" in eqp.upper() or "28G" in zn.upper():
            band = "28G"
        else:
            band = "3.5G"  # SKT 5G 기본값
    elif service == "LTE":
        # 1순위: eqp_type 직접 명시
        eqp_u = eqp.upper()
        if "2.6G" in eqp_u or "L26" in eqp_u:
            band = "2.6G"
        elif "1.8G" in eqp_u or "L18" in eqp_u:
            band = "1.8G"
        elif "2.1G" in eqp_u or "L21" in eqp_u:
            band = "2.1G"
        elif "800" in eqp_u or "L08" in eqp_u or "L800" in eqp_u:
            band = "800M"
        else:
            # 2순위: zpcname의 SKT band code (.B5./.B3./.B1./.B7. 형식 우선)
            import re as _re
            m = _re.search(r"[._]?B([1357])[._]", zn)
            if m:
                band = _SKT_BAND_MAP.get(f"B{m.group(1)}")
            else:
                # fallback: 단어 경계 매칭
                for code, b in _SKT_BAND_MAP.items():
                    if code in zn:
                        band = b
                        break
        # 3순위: LTE인데 밴드 미식별 → 멀티밴드 장비(MIBOS/IRO/RRH_L/RRU_L 등)
        # 같은 안테나에서 여러 밴드 동시 송출 → 단일 "멀티" 키로 묶음
        if band is None:
            band = "멀티"
    return service, band


def _parse_swing_list(s: str) -> list:
    """'40,160,280' → [40,160,280] (0~359 정규화, 빈값/비숫자 무시)"""
    if not s:
        return []
    out = []
    for tok in str(s).split(","):
        tok = tok.strip()
        if not tok:
            continue
        try:
            v = int(float(tok)) % 360
            out.append(v)
        except (ValueError, TypeError):
            pass
    return out


@app.post("/azimuths/batch")
async def azimuths_batch(request: Request):
    """현장 수검 Map 부채꼴 표시용 batch 안테나 방위각 조회.

    입력: {"zpwino_list": ["322021410002166", ...]}
    출력: {
      "items": {
        "<zpwino>": [
          {"service": "LTE", "band": "800M", "swings": [0, 120, 240]},
          {"service": "5G",  "band": "3.5G", "swings": [40, 160, 280]}
        ]
      }
    }
    """
    await _verify_auth(request)
    body = await request.json()
    raw_list = body.get("zpwino_list", [])
    zpwino_list = list({str(z).strip() for z in raw_list if str(z).strip()})
    if not zpwino_list:
        return {"items": {}}
    if len(zpwino_list) > 1000:
        raise HTTPException(status_code=400, detail="최대 1000건까지 조회 가능합니다.")

    _cert_cache_load()
    result = {z: {} for z in zpwino_list}  # {zpwino: {(service,band): set(swings)}}

    try:
        import sqlite3 as _sql
        conn = _sql.connect(_cert_cache_db_path, timeout=30)
        conn.row_factory = _sql.Row
        try:
            BATCH = 900
            for offset in range(0, len(zpwino_list), BATCH):
                batch = zpwino_list[offset:offset + BATCH]
                placeholders = ",".join("?" * len(batch))
                cur = conn.execute(
                    f"SELECT zpwino, zpannu1, eqp_type, zpcname, swing_list "
                    f"FROM cert WHERE zpwino IN ({placeholders})",
                    batch,
                )
                for row in cur:
                    z = row["zpwino"]
                    if not z:
                        continue
                    service, band = _extract_service_band(
                        row["zpannu1"] or "",
                        row["eqp_type"] or "",
                        row["zpcname"] or "",
                    )
                    if not service or not band:
                        continue
                    swings = _parse_swing_list(row["swing_list"] or "")
                    if not swings:
                        continue
                    key = (service, band)
                    bucket = result[z].setdefault(key, set())
                    for s in swings:
                        bucket.add(s)
        finally:
            conn.close()
    except Exception as e:
        logger.warning(f"azimuths/batch 조회 실패: {e}")
        raise HTTPException(status_code=500, detail=f"방위각 조회 실패: {e}")

    out = {}
    for z, by_key in result.items():
        if not by_key:
            continue
        out[z] = [
            {"service": s, "band": b, "swings": sorted(sw)}
            for (s, b), sw in sorted(by_key.items(), key=lambda x: (x[0][0], x[0][1]))
        ]
    return {"items": out}


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
        conn = sqlite3.connect(_cert_cache_db_path, timeout=30)
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
    """ERP vs DS 비교 동기 처리 — ds_detail.db 활용 (메모리 절약)."""
    import sqlite3

    # 1) ERP 데이터 조회
    erp_data = _cert_batch_lookup_cached(zpwino_list)

    # 2) DS 데이터: ds_detail.db에서 직접 조회 (ZIP 파싱 불필요)
    ds_device = {}      # {zpwino: [serial, ...]}
    ds_antenna = {}     # {zpwino: tower_type}
    ds_antenna_ki = {}  # {zpwino: max 기수 (int)}
    warnings = []
    BATCH = 900

    if os.path.exists(_DS_DETAIL_DB):
        try:
            conn = sqlite3.connect(_DS_DETAIL_DB, timeout=30)
            conn.row_factory = sqlite3.Row
            # 양쪽 형식(하이픈 유/무) 모두 포함
            all_nos = list({n for raw in zpwino_list for n in (raw, raw.replace('-', ''))})

            # 장치: 허가번호별 일련번호 목록
            for i in range(0, len(all_nos), BATCH):
                batch = all_nos[i:i + BATCH]
                ph = ','.join('?' * len(batch))
                for row in conn.execute(f"SELECT 허가번호, 기기일련번호 FROM ds_장치 WHERE 허가번호 IN ({ph})", batch):
                    z = row['허가번호'].replace('-', '')
                    sn = str(row['기기일련번호'] or '').strip()
                    if z not in ds_device:
                        ds_device[z] = []
                    if sn and sn not in ds_device[z]:
                        ds_device[z].append(sn)

            # 안테나: 허가번호별 설치형태 + 기수
            for i in range(0, len(all_nos), BATCH):
                batch = all_nos[i:i + BATCH]
                ph = ','.join('?' * len(batch))
                for row in conn.execute(f"SELECT 허가번호, 공중선주설치형태명, 기 FROM ds_안테나 WHERE 허가번호 IN ({ph})", batch):
                    z = row['허가번호'].replace('-', '')
                    if z not in ds_antenna:
                        ds_antenna[z] = str(row['공중선주설치형태명'] or '').strip()
                    try:
                        ki_int = int(str(row['기'] or '').strip())
                    except (ValueError, TypeError):
                        ki_int = 0
                    if ki_int > ds_antenna_ki.get(z, 0):
                        ds_antenna_ki[z] = ki_int

            # DS 장치상태 (활용구분): 허가번호별 첫 번째 비어있지 않은 값
            ds_prac1 = {}
            for i in range(0, len(all_nos), BATCH):
                batch = all_nos[i:i + BATCH]
                ph = ','.join('?' * len(batch))
                try:
                    for row in conn.execute(
                        f"SELECT 허가번호, 장치상태 FROM ds_장치 WHERE 허가번호 IN ({ph}) AND TRIM(COALESCE(장치상태,'')) != ''",
                        batch
                    ):
                        z2 = str(row['허가번호'] or '').replace('-', '')
                        if z2 and z2 not in ds_prac1:
                            ds_prac1[z2] = str(row['장치상태'] or '').strip()
                except Exception:
                    pass  # 장치상태 컬럼 미존재 시(구 DB) 무시

            conn.close()
        except Exception as e:
            logger.warning(f"ds_detail.db 비교 조회 실패: {e}")
            warnings.append(f"DS 데이터 조회 실패: {e}")
    else:
        warnings.append("DS 데이터가 아직 빌드되지 않았습니다. DS 파일을 업로드해주세요.")

    # 4-2) inspection_targets + staging에서 통시/공대/위경도/주소 조회
    insp_info = {}  # {허가번호(하이픈제거): {"통시":, "공대":, "위도":, "경도":, "도로명주소":, "설치장소":}}
    try:
        conn_insp = sqlite3.connect(_INSP_DB, timeout=30)
        conn_insp.row_factory = sqlite3.Row
        all_nos = list({n for raw in zpwino_list for n in (raw, raw.replace('-', ''))})
        BATCH = 900
        for tbl in ('inspection_targets', 'inspection_targets_staging'):
            # 테이블마다 실제 컬럼 확인 후 SELECT (staging은 위도/경도 없음)
            try:
                tbl_cols = {r['name'] for r in conn_insp.execute(f"PRAGMA table_info({tbl})").fetchall()}
                if not tbl_cols:
                    continue  # 테이블 없음
                has_location = '위도' in tbl_cols and '경도' in tbl_cols
                has_road_addr = '도로명주소' in tbl_cols
                has_install_addr = '설치장소' in tbl_cols
                select_extra = ''
                if has_location:
                    select_extra += ', 위도, 경도'
                if has_road_addr:
                    select_extra += ', 도로명주소'
                if has_install_addr:
                    select_extra += ', 설치장소'
                for i in range(0, len(all_nos), BATCH):
                    batch = all_nos[i:i + BATCH]
                    ph = ','.join('?' * len(batch))
                    for row in conn_insp.execute(
                        f"SELECT 허가번호, 통시, 공대{select_extra} FROM {tbl} WHERE 허가번호 IN ({ph})", batch
                    ):
                        z = str(row['허가번호'] or '').replace('-', '').strip()
                        if z and z not in insp_info:
                            lat = float(row['위도']) if has_location and row['위도'] else None
                            lng = float(row['경도']) if has_location and row['경도'] else None
                            road_addr = str(row['도로명주소'] or '').strip() if has_road_addr else ''
                            inst_addr = str(row['설치장소'] or '').strip() if has_install_addr else ''
                            insp_info[z] = {
                                "통시": str(row['통시'] or '').strip(),
                                "공대": str(row['공대'] or '').strip(),
                                "위도": lat,
                                "경도": lng,
                                "도로명주소": road_addr,
                                "설치장소": inst_addr,
                            }
            except Exception as te:
                logger.warning(f"{tbl} 조회 실패: {te}")
        conn_insp.close()
    except Exception as e:
        logger.warning(f"inspection_targets 조회 실패: {e}")

    # ERP 활용구분(zpprac1): _cert_batch_lookup_cached 결과(erp_data)에서 직접 추출
    erp_prac1_map = {
        z.replace('-', ''): (erp_data.get(z, {}).get('zpprac1', '') or '')
        for z in zpwino_list
    }

    # 5) 비교 결과 생성
    items = []
    summary = {
        "tower_match": 0, "tower_mismatch": 0, "tower_check": 0,
        "tower_partial": 0, "tower_ds_missing": 0,
        "serial_match": 0, "serial_mismatch": 0, "serial_check": 0,
        "serial_partial": 0, "serial_ds_missing": 0,
    }

    for z in zpwino_list:
        erp = erp_data.get(z)
        erp_zpirty3 = erp.get("zpirty3", "") if erp else ""
        erp_serial = erp.get("eqp_ser_no", "") if erp else ""
        z_clean = z.replace('-', '')
        ds_tower = ds_antenna.get(z_clean, "") or ds_antenna.get(z, "")
        ds_serials = ds_device.get(z_clean, []) or ds_device.get(z, [])
        ds_serial_str = ", ".join(ds_serials) if ds_serials else ""
        insp = insp_info.get(z_clean) or insp_info.get(z, {})

        # 철탑형태 비교
        tower_result = _compare_values(erp_zpirty3, ds_tower, _normalize_tower)
        # 일련번호 비교
        serial_result = _compare_values(erp_serial, ds_serial_str)

        summary_key_map = {
            "일치": "match", "부분일치": "partial", "불일치": "mismatch",
            "DS누락": "ds_missing", "확인필요": "check",
        }
        summary[f"tower_{summary_key_map.get(tower_result, 'check')}"] += 1
        summary[f"serial_{summary_key_map.get(serial_result, 'check')}"] += 1

        # 주소 우선순위: inspection_targets 도로명주소 > 설치장소 > ERP zpwiadr
        best_address = (insp.get("도로명주소") or insp.get("설치장소")
                        or (erp.get("zpwiadr", "") if erp else ""))

        # 위경도 우선순위: inspection_targets > ERP zpwilat/zpwilon
        lat = insp.get("위도")
        lng = insp.get("경도")
        if (lat is None or lng is None) and erp:
            try:
                erp_lat = erp.get("zpwilat", "")
                erp_lng = erp.get("zpwilon", "")
                if erp_lat and erp_lng:
                    lat = float(erp_lat) or None
                    lng = float(erp_lng) or None
            except (ValueError, TypeError):
                pass

        erp_prac = erp_prac1_map.get(z_clean, '')
        ds_prac = ds_prac1.get(z_clean, '') or ds_prac1.get(z, '')
        if erp_prac and ds_prac:
            prac_match = '일치' if erp_prac == ds_prac else '불일치'
        elif not ds_prac and erp_prac:
            prac_match = 'DS누락'
        elif not erp_prac and ds_prac:
            prac_match = 'ERP누락'
        else:
            prac_match = ''

        items.append({
            "zpwino": z,
            "zpwina": erp.get("zpwina", "") if erp else "",
            "zpwiadr": best_address,
            "lat": lat,
            "lng": lng,
            "area_hdofc_nm": erp.get("area_hdofc_nm", "") if erp else "",
            "erp_found": bool(erp),
            "erp_zpirty3": erp_zpirty3,
            "erp_serial": erp_serial,
            "ds_tower_type": ds_tower,
            "ds_serial": ds_serial_str,
            "tower_match": tower_result,
            "serial_match": serial_result,
            "통시": insp.get("통시", ""),
            "공대": insp.get("공대", ""),
            "erp_prac1": erp_prac,
            "ds_prac1": ds_prac,
            "prac1_match": prac_match,
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
# Inspection Schedule Management (수검 일정 관리)
# ============================================================

INSPECTION_S3_PREFIX = "inspection/raw/"
_INSP_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "inspection.db")

# 본부-팀 매핑 (하드코딩 — DB 데이터 없어도 드롭다운 동작 보장)
INSP_ORG_MAP: dict = {
    "강남": ["강남품질개선팀", "관악품질개선팀", "강동품질개선팀", "양천품질개선팀"],
    "강북": ["용산품질개선팀", "종로품질개선팀", "성수품질개선팀", "수유품질개선팀", "지하철품질개선팀"],
    "인천": ["북인천품질개선팀", "남인천품질개선팀", "부천품질개선팀", "일산품질개선팀", "남양주품질개선팀", "의정부품질개선팀"],
    "경기": ["하남품질개선팀", "평택품질개선팀", "수원품질개선팀", "분당품질개선팀", "용인품질개선팀"],
    "경남": ["동부산품질개선팀", "서부산품질개선팀", "김해품질개선팀", "울산품질개선팀", "진주품질개선팀", "창원품질개선팀"],
    "경북": ["동대구품질개선팀", "서대구품질개선팀", "경산품질개선팀", "포항품질개선팀", "안동품질개선팀", "구미품질개선팀"],
    "서부": ["서광주품질개선팀", "동광주품질개선팀", "목포품질개선팀", "순천품질개선팀", "제주품질개선팀", "전주품질개선팀", "군산품질개선팀"],
    "충청": ["대전품질개선팀", "천안품질개선팀", "세종품질개선팀", "서산품질개선팀", "서청주품질개선팀", "동청주품질개선팀", "충주품질개선팀"],
    "강원": ["원주품질개선팀", "춘천품질개선팀", "강릉품질개선팀"],
}
# 팀 → 본부 역방향 맵 (import 시 매칭용)
INSP_TEAM_TO_HDQT: dict = {team: hdqt for hdqt, teams in INSP_ORG_MAP.items() for team in teams}

# ── SKT본부 유효값 + access담당(9) → skt본부(4) 매핑 ──────────────────────
_VALID_SKT_HDQTS: set = {'수도권', '중부', '서부', '동부'}
_ACCESS_TO_SKT_HDQT: dict = {
    # 수도권: 강남, 강북, 경기, 인천, 강원
    '강남': '수도권', '강북': '수도권', '경기': '수도권', '인천': '수도권', '강원': '수도권',
    # 중부: 충청
    '충청': '중부',
    # 서부: 서부
    '서부': '서부',
    # 동부: 경북, 경남
    '경북': '동부', '경남': '동부',
}

def _normalize_skt_hdqt(raw: str, access: str = '') -> str:
    """skt본부 값 정규화.
    - 유효값(수도권/중부/서부/동부)이면 그대로
    - 'xx Network담당', 'xx담당' 같은 접미사 제거
    - 품질개선팀명이 들어온 경우 → 팀→access담당→skt본부로 유추
    - 그래도 안 되면 access담당 파라미터로 유추
    - 최종 실패 시 빈 문자열
    """
    s = (raw or '').strip()
    if s in _VALID_SKT_HDQTS:
        return s

    # 접미사 제거
    for suffix in ('Network담당', 'Access담당', '품질개선팀', '담당'):
        if s.endswith(suffix):
            s = s[:-len(suffix)].strip()
            break
    if s in _VALID_SKT_HDQTS:
        return s

    # 앞부분 매칭 (예: "수도권-강남" → "수도권")
    for v in _VALID_SKT_HDQTS:
        if s.startswith(v):
            return v

    # 팀명이 들어왔으면 팀→access→skt본부
    if raw in INSP_TEAM_TO_HDQT:
        derived_access = INSP_TEAM_TO_HDQT[raw]
        if derived_access in _ACCESS_TO_SKT_HDQT:
            return _ACCESS_TO_SKT_HDQT[derived_access]

    # 파라미터로 받은 access담당으로 유추
    access_clean = (access or '').strip()
    if access_clean in _ACCESS_TO_SKT_HDQT:
        return _ACCESS_TO_SKT_HDQT[access_clean]

    return ''

# ── 알려진 폐지 팀 → 현재 팀 명시 매핑 ──────────────────────────────────────
_DEPRECATED_TEAM_MAP: dict = {
    '남산품질개선팀':   '용산품질개선팀',
    '삼척품질개선팀':   '강릉품질개선팀',
    '통영품질개선팀':   '진주품질개선팀',
    '마산품질개선팀':   '창원품질개선팀',
    '성북품질개선팀':   '수유품질개선팀',
    '수원북품질개선팀': '수원품질개선팀',
    '수원남품질개선팀': '수원품질개선팀',
    '인천품질개선팀':   '남인천품질개선팀',
    '광주품질개선팀':   '동광주품질개선팀',
    '청주품질개선팀':   '서청주품질개선팀',
    '부산품질개선팀':   '서부산품질개선팀',
    '대구품질개선팀':   '동대구품질개선팀',
}

# ── 서울 구명 → 팀 (행정구역이 명확해 하드코딩 안전) ────────────────────────
# 지방 시/군은 하드코딩하지 않음 — 임포트 시 데이터 학습으로 결정
_SEOUL_GU_TO_TEAM: dict = {
    '강남구': ('강남', '강남품질개선팀'), '서초구': ('강남', '강남품질개선팀'),
    '관악구': ('강남', '관악품질개선팀'), '동작구': ('강남', '관악품질개선팀'),
    '강동구': ('강남', '강동품질개선팀'), '송파구': ('강남', '강동품질개선팀'),
    '양천구': ('강남', '양천품질개선팀'), '강서구': ('강남', '양천품질개선팀'),
    '영등포구': ('강남', '양천품질개선팀'), '구로구': ('강남', '양천품질개선팀'),
    '금천구': ('강남', '양천품질개선팀'),
    '용산구': ('강북', '용산품질개선팀'), '마포구': ('강북', '용산품질개선팀'),
    '서대문구': ('강북', '용산품질개선팀'), '은평구': ('강북', '용산품질개선팀'),
    '종로구': ('강북', '종로품질개선팀'), '중구': ('강북', '종로품질개선팀'),
    '성동구': ('강북', '성수품질개선팀'), '광진구': ('강북', '성수품질개선팀'),
    '중랑구': ('강북', '성수품질개선팀'), '동대문구': ('강북', '성수품질개선팀'),
    '성북구': ('강북', '수유품질개선팀'), '강북구': ('강북', '수유품질개선팀'),
    '도봉구': ('강북', '수유품질개선팀'), '노원구': ('강북', '수유품질개선팀'),
    '지하철': ('강북', '지하철품질개선팀'),
}
# 길이 내림차순 (긴 키워드 우선)
_SEOUL_GU_SORTED: list = sorted(_SEOUL_GU_TO_TEAM.items(), key=lambda x: -len(x[0]))

# ── 광역시/도 축약형 → 정식명 매핑 ──────────────────────────────────────────
_ADDR_ABBR_MAP: dict = {
    '서울 ': '서울특별시 ',
    '부산 ': '부산광역시 ',
    '대구 ': '대구광역시 ',
    '인천 ': '인천광역시 ',
    '광주 ': '광주광역시 ',
    '대전 ': '대전광역시 ',
    '울산 ': '울산광역시 ',
    '세종 ': '세종특별자치시 ',
    '경기 ': '경기도 ',
    '강원 ': '강원특별자치도 ',
    '충북 ': '충청북도 ',
    '충남 ': '충청남도 ',
    '전북 ': '전북특별자치도 ',
    '전남 ': '전라남도 ',
    '경북 ': '경상북도 ',
    '경남 ': '경상남도 ',
    '제주 ': '제주특별자치도 ',
}

def _normalize_addr(addr: str) -> str:
    """주소 정규화: 앞쪽 괄호+코드 제거 + 띄어쓰기 변형 처리 + 축약형→정식명 변환.
    '(701240)대구 동구' → '대구광역시 동구'
    '부산 광역시 북구' → '부산광역시 북구'
    """
    import re as _re
    # 1) 앞쪽 괄호+숫자/공백 제거: "(701240)대구" → "대구"
    addr = _re.sub(r'^\s*\([^)]*\)\s*', '', addr).strip()
    # 2) "부산 광역시" → "부산광역시" 등 띄어쓰기 변형 정규화
    addr = _re.sub(r'(서울)\s*(특별시)', r'\1\2', addr)
    addr = _re.sub(r'(부산|대구|인천|광주|대전|울산)\s*(광역시)', r'\1\2', addr)
    addr = _re.sub(r'(세종)\s*(특별자치시)', r'\1\2', addr)
    addr = _re.sub(r'(경기|충청북|충청남|전라북|전라남|경상북|경상남)\s*(도)', r'\1\2', addr)
    addr = _re.sub(r'(강원)\s*(특별자치도)', r'\1\2', addr)
    addr = _re.sub(r'(전북)\s*(특별자치도)', r'\1\2', addr)
    addr = _re.sub(r'(제주)\s*(특별자치도)', r'\1\2', addr)
    # 3) 축약형 → 정식명
    for abbr, full in _ADDR_ABBR_MAP.items():
        if addr.startswith(abbr):
            return full + addr[len(abbr):]
    return addr

# ── 법정동 코드표 (PNU 10자리 → 법정동명) ──────────────────────────────────
_LEGAL_DONG_MAP: dict = {}

def _load_legal_dong_map():
    """법정동 코드 TSV 파일 로드 (서버 시작 시 1회)."""
    global _LEGAL_DONG_MAP
    tsv_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "legal_dong_code.tsv")
    if not os.path.exists(tsv_path):
        logger.warning(f"법정동 코드 파일 없음: {tsv_path}")
        return
    count = 0
    with open(tsv_path, encoding='utf-8') as f:
        next(f)  # 헤더 스킵
        for line in f:
            parts = line.strip().split('\t')
            if len(parts) >= 3 and parts[2] == '존재':
                _LEGAL_DONG_MAP[parts[0]] = parts[1]
                count += 1
    logger.info(f"법정동 코드표 로드 완료: {count}개")

# 모듈 로드 시 즉시 실행 (가벼운 딕셔너리, ~2MB)
_load_legal_dong_map()


def _pnu_to_addr(pnu: str) -> str:
    """PNU 19자리 → '서울특별시 강남구 역삼동 산168-5' 형태로 변환.
    [0:10]  = 법정동코드 10자리
    [10:11] = 산 여부 (1=산, 2=일반)
    [11:15] = 본번 4자리
    [15:19] = 부번 4자리
    """
    pnu = str(pnu).strip()
    if len(pnu) < 10:
        return ''
    dong_code = pnu[:10]
    dong_name = _LEGAL_DONG_MAP.get(dong_code, '')
    if not dong_name:
        # 읍면동 코드로 못 찾으면 시군구(5자리)로 시도
        sigungu = pnu[:5] + '00000'
        dong_name = _LEGAL_DONG_MAP.get(sigungu, '')
    if not dong_name:
        return ''
    # 번지 추출
    if len(pnu) >= 15:
        try:
            is_san = pnu[10] == '1'  # 1=산, 2=일반
            bon = int(pnu[11:15])    # 본번 4자리
            bu = int(pnu[15:19]) if len(pnu) >= 19 else 0  # 부번 4자리
            if bon > 0:
                san_prefix = '산' if is_san else ''
                dong_name += f' {san_prefix}{bon}'
                if bu > 0:
                    dong_name += f'-{bu}'
        except ValueError:
            pass
    return dong_name


def _hdqt_from_addr(addr: str, known_hdqt: str = '',
                    learned_map: dict | None = None) -> tuple:
    """도로명주소/설치장소에서 (본부, 팀) 추론.
    우선순위: 서울 구명(하드코딩) → 학습된 맵 → (본부만 반환)
    known_hdqt가 있으면 같은 본부 팀만 수락.
    """
    if not addr:
        return known_hdqt, ''

    # 0) 축약형 정규화 ("대구 동구" → "대구광역시 동구")
    addr = _normalize_addr(addr.strip())

    # 1) 서울 구명 (명확한 하드코딩) — 서울 주소일 때만 적용
    #    (인천/대전 '중구' 등 동명이 다른 지역에 잘못 매칭되는 문제 방지)
    is_seoul = ('서울특별시' in addr) or ('서울 ' in addr) or addr.startswith('서울')
    if is_seoul:
        for kw, (hdqt, team) in _SEOUL_GU_SORTED:
            if kw not in addr:
                continue
            if known_hdqt and hdqt != known_hdqt:
                continue
            return hdqt, team

    # 2) 학습된 맵 (임포트 시 same-file known-team rows에서 학습)
    if learned_map:
        import re as _re
        geo_re = _re.compile(r'[가-힣]+(?:시|군|구|읍|면|동)')
        matches = geo_re.findall(addr)
        cities = [m for m in matches if m.endswith('시')]
        gus = [m for m in matches if m.endswith('구')]
        guns = [m for m in matches if m.endswith('군')]
        eups = [m for m in matches if m.endswith('읍')]
        myeons = [m for m in matches if m.endswith('면')]
        dongs = [m for m in matches if m.endswith('동')]
        # 복합 키워드: 시+구, 시+군, 군+읍, 군+면, 시+동, 구+동
        compound_keys = []
        for city in cities:
            for gu in gus:
                compound_keys.append(f"{city} {gu}")
            for gun in guns:
                compound_keys.append(f"{city} {gun}")
            for dong in dongs:
                compound_keys.append(f"{city} {dong}")
        for gun in guns:
            for eup in eups:
                compound_keys.append(f"{gun} {eup}")
            for myeon in myeons:
                compound_keys.append(f"{gun} {myeon}")
        for gu in gus:
            for dong in dongs:
                compound_keys.append(f"{gu} {dong}")
        # 복합(긴 것 우선) → 단일(동 제외, 긴 것 우선) — 동만 동명 충돌 위험
        single_safe = [m for m in matches if not m.endswith('동')]
        candidates = sorted(compound_keys, key=len, reverse=True) + sorted(single_safe, key=len, reverse=True)
        for kw in candidates:
            team = learned_map.get(kw)
            if not team or team not in INSP_TEAM_TO_HDQT:
                continue
            hdqt = INSP_TEAM_TO_HDQT[team]
            if known_hdqt and hdqt != known_hdqt:
                continue
            return hdqt, team

    return known_hdqt, ''


def _learn_addr_map_from_cert_db(db_path: str = "") -> dict:
    """호출명칭 DB(cert SQLite)에서 주소 키워드 → 팀 다수결 학습.

    원칙:
    - cert DB의 ons_team_nm이 현재 유효 팀(INSP_TEAM_TO_HDQT)인 행만 사용
    - zpwiadr(도로명주소)에서 시·군·구 키워드 추출
    - 키워드당 ≥10 샘플 & 1위 팀 비율 ≥60% 이상일 때만 확정
      → 경계 지역(화성시가 수원팀 20% + 평택팀 80% → 평택팀으로 확정)도 올바르게 처리
    - 업로드 파일과 무관하게 항상 최신 ERP 데이터 기반으로 학습
    """
    import re
    from collections import Counter, defaultdict

    _db = db_path or _cert_cache_db_path
    if not _db or not os.path.exists(_db):
        logger.warning("cert DB 없음 — 주소→팀 학습 생략")
        return {}

    geo_re = re.compile(r'[가-힣]+(?:시|군|구|읍|면|동)')
    kw_teams: dict = defaultdict(Counter)

    try:
        c = sqlite3.connect(_db, timeout=30)
        for zpwiadr, ons_team in c.execute(
            'SELECT zpwiadr, ons_team_nm FROM cert WHERE zpwiadr IS NOT NULL AND zpwiadr != ""'
        ):
            team = str(ons_team or '').strip()
            if team not in INSP_TEAM_TO_HDQT:
                continue
            # 주소 정규화: "(701240)대구 동구" → "대구광역시 동구"
            normalized = _normalize_addr(str(zpwiadr))
            matches = geo_re.findall(normalized)
            # 단일 키워드 (시, 군, 구, 읍, 면 — 동만 복합으로 제한, 동명 충돌 방지)
            for kw in matches:
                if not kw.endswith('동'):
                    kw_teams[kw][team] += 1
            cities = [m for m in matches if m.endswith('시')]
            gus = [m for m in matches if m.endswith('구')]
            guns = [m for m in matches if m.endswith('군')]
            eups = [m for m in matches if m.endswith('읍')]
            myeons = [m for m in matches if m.endswith('면')]
            dongs = [m for m in matches if m.endswith('동')]
            # 복합 키워드: 시+구, 시+군, 군+읍, 군+면, 시+동, 구+동
            for city in cities:
                for gu in gus:
                    kw_teams[f"{city} {gu}"][team] += 1
                for gun in guns:
                    kw_teams[f"{city} {gun}"][team] += 1
                for dong in dongs:
                    kw_teams[f"{city} {dong}"][team] += 1
            for gun in guns:
                for eup in eups:
                    kw_teams[f"{gun} {eup}"][team] += 1
                for myeon in myeons:
                    kw_teams[f"{gun} {myeon}"][team] += 1
            for gu in gus:
                for dong in dongs:
                    kw_teams[f"{gu} {dong}"][team] += 1
        c.close()
    except Exception as e:
        logger.warning(f"cert DB 주소 학습 실패: {e}")
        return {}

    learned: dict = {}
    for kw, counter in kw_teams.items():
        total = sum(counter.values())
        if total < 3:
            continue
        # 비율 기준 없이 다수결 — 가장 많은 팀으로 확정
        top_team, _ = counter.most_common(1)[0]
        learned[kw] = top_team

    logger.info(f"주소→팀 학습 완료(cert DB): {len(learned)}개 키워드 확정 "
                f"(전체 후보: {len(kw_teams)}개)")
    return learned


def _learn_pnu_map_from_cert_db() -> dict:
    """cert DB에서 PNU코드(법정동코드) 10자리 → 팀 다수결 학습.

    PNU 10자리 = 시도(2) + 시군구(3) + 읍면동(5) → 동 단위 정확 매핑.
    주소 텍스트 파싱보다 정확하고, 경계 지역도 읍면동 단위로 구분 가능.
    """
    import sqlite3
    from collections import Counter, defaultdict

    if not _cert_cache_db_path or not os.path.exists(_cert_cache_db_path):
        logger.warning("cert DB 없음 — PNU→팀 학습 생략")
        return {}

    pnu_teams: dict = defaultdict(Counter)

    try:
        c = sqlite3.connect(_cert_cache_db_path, timeout=30)
        for zpcode, ons_team in c.execute(
            'SELECT zpcode, ons_team_nm FROM cert WHERE zpcode IS NOT NULL AND zpcode != ""'
        ):
            team = str(ons_team or '').strip()
            if team not in INSP_TEAM_TO_HDQT:
                continue
            pnu = str(zpcode).strip()
            if len(pnu) < 10:
                continue
            pnu10 = pnu[:10]
            pnu_teams[pnu10][team] += 1
        c.close()
    except Exception as e:
        logger.warning(f"cert DB PNU 학습 실패: {e}")
        return {}

    learned: dict = {}
    for pnu10, counter in pnu_teams.items():
        total = sum(counter.values())
        if total < 1:
            continue
        # 비율 기준 없이 다수결 — 같은 법정동 내 국소는 대부분 동일 팀
        top_team, _ = counter.most_common(1)[0]
        learned[pnu10] = top_team

    logger.info(f"PNU→팀 학습 완료(cert DB): {len(learned)}개 PNU 확정 "
                f"(전체 후보: {len(pnu_teams)}개)")
    return learned

_DS_DETAIL_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ds_detail.db")
_inspection_jobs: Dict[str, dict] = {}
DYNAMODB_INSP_SCHEDULES = os.environ.get("DYNAMODB_INSPECTION_SCHEDULES", "kca-inspection-schedules")
DYNAMODB_INSP_RESULTS = os.environ.get("DYNAMODB_INSPECTION_RESULTS", "kca-inspection-results")

# ── SQLite 초기화 ──────────────────────────────────────────

def _init_inspection_db():
    import sqlite3
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    conn.execute('PRAGMA journal_mode=WAL')  # 읽기/쓰기 동시 허용
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_targets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        year INTEGER, sheet TEXT,
        pnu_code TEXT, 허가번호 TEXT, 호출명칭 TEXT, 국종군 TEXT,
        부서 TEXT, 분기 TEXT, 연도주기 TEXT, 검사주기 INTEGER,
        허가상태 TEXT, 설치장소 TEXT, 도로명주소 TEXT, 장치수 INTEGER,
        통시 TEXT, 공대 TEXT, kca검토결과 TEXT, 시기조정 TEXT,
        기준연도 INTEGER, skt본부 TEXT, access담당 TEXT, 품질개선팀 TEXT,
        위도 REAL, 경도 REAL, 검사종류 TEXT DEFAULT ''
    )''')
    # 마이그레이션: 기존 DB에 위도/경도/검사종류 컬럼 추가
    for col in ('위도 REAL', '경도 REAL', "검사종류 TEXT DEFAULT ''"):
        try: conn.execute(f'ALTER TABLE inspection_targets ADD COLUMN {col}')
        except Exception: pass
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_year ON inspection_targets(year)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_허가번호 ON inspection_targets(허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_분기 ON inspection_targets(분기)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_access ON inspection_targets(access담당)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_품질팀 ON inspection_targets(품질개선팀)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_skt본부 ON inspection_targets(skt본부)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_국종군 ON inspection_targets(국종군)')
    # Phase 5 성능 — inspection_data 쿼리 최적화용 복합 인덱스
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_year_허가번호 ON inspection_targets(year, 허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_year_access ON inspection_targets(year, access담당)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_year_team ON inspection_targets(year, 품질개선팀)')
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_targets_staging (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        year INTEGER, sheet TEXT,
        pnu_code TEXT, 허가번호 TEXT, 호출명칭 TEXT, 국종군 TEXT,
        부서 TEXT, 분기 TEXT, 연도주기 TEXT, 검사주기 INTEGER,
        허가상태 TEXT, 설치장소 TEXT, 도로명주소 TEXT, 장치수 INTEGER,
        통시 TEXT, 공대 TEXT, kca검토결과 TEXT, 시기조정 TEXT,
        기준연도 INTEGER, skt본부 TEXT, access담당 TEXT, 품질개선팀 TEXT,
        검사종류 TEXT DEFAULT ''
    )''')
    # 마이그레이션: 기존 스테이징에 검사종류 추가
    try: conn.execute("ALTER TABLE inspection_targets_staging ADD COLUMN 검사종류 TEXT DEFAULT ''")
    except Exception: pass
    # 스테이징 인덱스
    conn.execute('CREATE INDEX IF NOT EXISTS idx_stg_year ON inspection_targets_staging(year)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_stg_access ON inspection_targets_staging(access담당)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_stg_team ON inspection_targets_staging(품질개선팀)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_stg_quarter ON inspection_targets_staging(분기)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_stg_nation ON inspection_targets_staging(국종군)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_stg_허가번호 ON inspection_targets_staging(허가번호)')
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_meta (
        year INTEGER PRIMARY KEY,
        sheet TEXT, total_skt INTEGER, total_sheet1 INTEGER,
        matched INTEGER, unmatched INTEGER,
        s3_key TEXT, filename TEXT, imported_by TEXT, imported_at TEXT
    )''')
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_jobs (
        job_id TEXT PRIMARY KEY,
        status TEXT, stage TEXT, percent REAL,
        total_skt INTEGER DEFAULT 0, total_sheet1 INTEGER DEFAULT 0,
        matched INTEGER DEFAULT 0, unmatched INTEGER DEFAULT 0,
        created_at TEXT, updated_at TEXT
    )''')
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_schedules (
        pk TEXT PRIMARY KEY,
        year INTEGER NOT NULL,
        허가번호 TEXT NOT NULL,
        호출명칭 TEXT, 분기 TEXT, skt본부 TEXT,
        access담당 TEXT, 품질개선팀 TEXT,
        수검예정주차 TEXT, 수검시작일 TEXT, 수검종료일 TEXT, 지역 TEXT,
        등록자 TEXT, 등록일시 TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_is_year ON inspection_schedules(year)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_is_access ON inspection_schedules(year, access담당)')
    # Phase 5 성능 — LEFT JOIN 및 서브쿼리 최적화
    conn.execute('CREATE INDEX IF NOT EXISTS idx_is_year_허가번호 ON inspection_schedules(year, 허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_is_year_week ON inspection_schedules(year, 수검예정주차)')
    # 마이그레이션: inspection_schedules 확장 컬럼
    for _col, _default in [("검사관", "''"), ("조", "''")]:
        try:
            conn.execute(f"ALTER TABLE inspection_schedules ADD COLUMN {_col} TEXT DEFAULT {_default}")
        except Exception:
            pass
    # 워크플로우 상태 머신용 컬럼
    for _col, _default in [
        ("workflow_status", "'REGISTERED'"),
        ("status_updated_at", "''"),
        ("status_updated_by", "''"),
        ("pre_check_result", "''"),  # JSON
        ("report_issued_at", "''"),
        ("report_issued_by", "''"),
        ("submission_no", "''"),
        ("submitted_at", "''"),
    ]:
        try:
            conn.execute(f"ALTER TABLE inspection_schedules ADD COLUMN {_col} TEXT DEFAULT {_default}")
        except Exception:
            pass
    conn.execute('CREATE INDEX IF NOT EXISTS idx_is_status ON inspection_schedules(year, workflow_status)')
    # 워크플로우 상태 전환 이력
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_status_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        schedule_pk TEXT NOT NULL,
        from_status TEXT,
        to_status TEXT NOT NULL,
        changed_by TEXT,
        changed_at TEXT NOT NULL,
        memo TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_isl_pk ON inspection_status_log(schedule_pk)')
    # 변경개설 요청 (Phase 2)
    conn.execute('''CREATE TABLE IF NOT EXISTS change_request (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        schedule_pk TEXT NOT NULL,
        허가번호 TEXT NOT NULL,
        field TEXT NOT NULL,            -- 일련번호/형식검정번호/설치형태/설치장소
        before_value TEXT,
        after_value TEXT NOT NULL,
        장치번호 TEXT,
        memo TEXT,
        status TEXT NOT NULL DEFAULT 'REQUESTED',  -- REQUESTED/FILED/APPLIED/VERIFIED
        requested_by TEXT,
        requested_at TEXT,
        filed_by TEXT,
        filed_at TEXT,
        applied_at TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_cr_pk ON change_request(schedule_pk)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_cr_status ON change_request(status)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_cr_license ON change_request(허가번호)')
    # 알림 (Phase 5) — 시스템 내 알림 전용 (이메일 미사용)
    conn.execute('''CREATE TABLE IF NOT EXISTS notifications (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,          -- 수신자 사번
        schedule_pk TEXT,               -- 관련 일정 (없을 수도 있음)
        type TEXT NOT NULL,             -- PRE_CHECK_REQUESTED / PRE_CHECK_REPLIED / CHANGE_FILED / RE_CHECK_DONE / REPORT_ISSUED / SUBMITTED / INSPECTED / SLA_OVERDUE
        message TEXT NOT NULL,
        read_at TEXT,                   -- 읽은 시각 (null이면 안 읽음)
        created_at TEXT NOT NULL,
        meta TEXT                       -- JSON 추가 메타 (호출명칭, 허가번호 등)
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_n_user ON notifications(user_id, read_at)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_n_user_created ON notifications(user_id, created_at)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_n_pk ON notifications(schedule_pk)')
    # 기존 데이터 백필: 검사일이 입력된 건은 INSPECTED, 나머지는 REGISTERED (DEFAULT 적용됨)
    try:
        conn.execute('''
            UPDATE inspection_schedules SET workflow_status='INSPECTED'
            WHERE (workflow_status IS NULL OR workflow_status='' OR workflow_status='REGISTERED')
              AND pk IN (
                SELECT pk FROM inspection_results
                WHERE 검사일 IS NOT NULL AND 검사일 != ''
              )
        ''')
    except Exception:
        pass
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_results (
        pk TEXT PRIMARY KEY,
        year INTEGER NOT NULL,
        허가번호 TEXT NOT NULL,
        status TEXT, 검사일 TEXT, 메모 TEXT, 철탑형태 TEXT,
        사진S3키 TEXT DEFAULT '[]',
        입력자 TEXT, 입력일시 TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_ir_year ON inspection_results(year)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_ir_status ON inspection_results(year, status)')
    # Phase 5 성능 — LEFT JOIN(year, 허가번호) 최적화
    conn.execute('CREATE INDEX IF NOT EXISTS idx_ir_year_허가번호 ON inspection_results(year, 허가번호)')
    # 마이그레이션: inspection_results 확장 컬럼
    for col, dflt in [
        ('진행여부', "''"),
        ('성능서류', "''"),
        ('불합격내용', "''"),
        ('불합격상세', "''"),
        ('공용화대상', "''"),
        ('간략불합격', "''"),
        ('기타사항', "''"),
        ('five_g_path', "''"),
        ('수검자', "''"),
        ('시스템', "''"),
        ('기지국구분', "''"),
        ('전파진흥원', "''"),
        ('검사관', "''"),
        ('주차별', "''"),
        # Phase 4: 일정 연결 + 재점검 필요 플래그
        ('schedule_pk', "''"),
        ('needs_recheck', "'0'"),  # '1' = 재점검 필요, '0' = 미해당
    ]:
        try:
            conn.execute(f"ALTER TABLE inspection_results ADD COLUMN {col} TEXT DEFAULT {dflt}")
        except Exception:
            pass
    # Phase 4: 기존 결과를 schedule과 매칭해 schedule_pk 백필 (pk가 동일 포맷 'year#허가번호')
    try:
        conn.execute('''
            UPDATE inspection_results
               SET schedule_pk = pk
             WHERE (schedule_pk IS NULL OR schedule_pk='')
               AND pk IN (SELECT pk FROM inspection_schedules)
        ''')
    except Exception:
        pass
    # ── inspection_results_raw 테이블 (검사실적 RAW DATA) ──
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_results_raw (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        year INTEGER,
        region TEXT,
        skt본부 TEXT,
        주차별 TEXT,
        월 TEXT,
        허가번호 TEXT,
        통합시설코드 TEXT,
        호출명칭 TEXT,
        주소 TEXT,
        기지국구분 TEXT,
        시스템 TEXT,
        검사년도 TEXT,
        검사종류 TEXT,
        검사일자 TEXT,
        ons팀 TEXT,
        수검자 TEXT,
        전파진흥원 TEXT,
        검사관 TEXT,
        진행여부 TEXT,
        합불여부 TEXT,
        성능서류 TEXT,
        불합격내용 TEXT,
        불합격상세 TEXT,
        공용화대상 TEXT,
        기타사항 TEXT,
        간략불합격 TEXT,
        five_g_path TEXT,
        장비타입 TEXT,
        허가번호2 TEXT,
        허가번호text TEXT,
        제조주소명 TEXT,
        제조정보명 TEXT,
        검사지표정보명 TEXT,
        제조Type TEXT,
        장비명 TEXT,
        NAMS기타정보 TEXT,
        장비Type공용화 TEXT,
        NAMS설명정보 TEXT,
        장비Type2 TEXT,
        uploaded_by TEXT,
        uploaded_at TEXT
    )''')
    # 마이그레이션: 장비타입간소화 컬럼 추가
    try:
        conn.execute("ALTER TABLE inspection_results_raw ADD COLUMN 장비타입간소화 TEXT DEFAULT ''")
    except Exception:
        pass
    conn.execute('CREATE INDEX IF NOT EXISTS idx_irr_year ON inspection_results_raw(year)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_irr_region ON inspection_results_raw(region)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_irr_hn ON inspection_results_raw(허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_irr_month ON inspection_results_raw(월)')
    # Phase 5 성능 — inspection_data 서브쿼리 (year + 허가번호 매칭) 최적화
    conn.execute('CREATE INDEX IF NOT EXISTS idx_irr_year_hn ON inspection_results_raw(year, 허가번호)')
    # ── inadequate_management 테이블 (부적합 관리) ──
    conn.execute('''CREATE TABLE IF NOT EXISTS inadequate_management (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        year INTEGER,
        허가번호 TEXT,
        통합시설코드 TEXT,
        호출명칭 TEXT,
        주소 TEXT,
        skt본부 TEXT,
        region TEXT,
        ons팀 TEXT,
        검사일자 TEXT,
        시정기한 TEXT,
        불합격내용 TEXT,
        불합격상세 TEXT,
        status TEXT DEFAULT '미완료',
        심의차수 TEXT DEFAULT '',
        updated_by TEXT DEFAULT '',
        updated_at TEXT DEFAULT '',
        UNIQUE(year, 허가번호)
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_inad_year ON inadequate_management(year)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_inad_region ON inadequate_management(region)')
    # ── menu_usage_log 테이블 (메뉴 접속 로그) ──
    conn.execute('''CREATE TABLE IF NOT EXISTS menu_usage_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT,
        user_name TEXT,
        menu_name TEXT,
        accessed_at TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_mul_menu ON menu_usage_log(menu_name)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_mul_user ON menu_usage_log(user_id)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_mul_date ON menu_usage_log(accessed_at)')
    # 24시간 지난 완료/에러 잡 정리
    conn.execute(
        "DELETE FROM inspection_jobs WHERE status IN ('complete','error') "
        "AND updated_at < datetime('now','-1 day')")
    conn.commit(); conn.close()


def _insp_job_write_sync(job_id: str, **kw):
    """inspection_jobs 테이블에 job 상태 upsert (동기, to_thread 사용)."""
    import sqlite3, json as _json
    now = datetime.now(timezone.utc).isoformat()
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    existing = conn.execute(
        'SELECT job_id FROM inspection_jobs WHERE job_id=?', (job_id,)).fetchone()
    if existing:
        sets = ', '.join(f'{k}=?' for k in kw)
        vals = list(kw.values()) + [now, job_id]
        conn.execute(f'UPDATE inspection_jobs SET {sets}, updated_at=? WHERE job_id=?', vals)
    else:
        kw.setdefault('status', 'processing')
        kw.setdefault('stage', '대기 중...')
        kw.setdefault('percent', 0)
        cols = ', '.join(['job_id', 'created_at', 'updated_at'] + list(kw.keys()))
        placeholders = ', '.join(['?'] * (3 + len(kw)))
        vals = [job_id, now, now] + list(kw.values())
        conn.execute(f'INSERT OR REPLACE INTO inspection_jobs ({cols}) VALUES ({placeholders})', vals)
    conn.commit(); conn.close()


def _insp_job_read_sync(job_id: str):
    import sqlite3
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    conn.row_factory = sqlite3.Row
    row = conn.execute(
        'SELECT * FROM inspection_jobs WHERE job_id=?', (job_id,)).fetchone()
    conn.close()
    return dict(row) if row else None

def _init_ds_detail_db():
    import sqlite3
    conn = sqlite3.connect(_DS_DETAIL_DB, timeout=60)
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('PRAGMA synchronous=NORMAL')
    conn.execute('''CREATE TABLE IF NOT EXISTS ds_일반사항 (
        허가번호 TEXT PRIMARY KEY, 무선국명 TEXT, 호출명칭 TEXT
    )''')
    # 마이그레이션: 통합시설명칭 컬럼 추가 (기존 DB 호환)
    try:
        conn.execute('ALTER TABLE ds_일반사항 ADD COLUMN 통합시설명칭 TEXT')
        conn.commit()
    except Exception:
        pass  # 이미 존재하면 무시
    # 마이그레이션: 공용화구분코드명 컬럼 추가
    try:
        conn.execute('ALTER TABLE ds_일반사항 ADD COLUMN 공용화구분코드명 TEXT')
        conn.commit()
    except Exception:
        pass
    conn.execute('''CREATE TABLE IF NOT EXISTS ds_장치 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        허가번호 TEXT, 장치번호 TEXT, 기기일련번호 TEXT, 형식검정번호 TEXT
    )''')
    # 마이그레이션: 형식검정번호 컬럼 추가
    try: conn.execute('ALTER TABLE ds_장치 ADD COLUMN 형식검정번호 TEXT'); conn.commit()
    except Exception: pass
    # 마이그레이션: 장치상태 컬럼 추가
    try: conn.execute('ALTER TABLE ds_장치 ADD COLUMN 장치상태 TEXT'); conn.commit()
    except Exception: pass
    conn.execute('''CREATE TABLE IF NOT EXISTS ds_안테나 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        허가번호 TEXT, 장치번호 TEXT,
        기 TEXT, 이득 TEXT, 공중선주설치형태명 TEXT,
        공중선일련번호 TEXT, 공중선형식명 TEXT
    )''')
    # 마이그레이션: 공중선일련번호, 공중선형식명 컬럼 추가
    for _mc in ('공중선일련번호 TEXT', '공중선형식명 TEXT'):
        try: conn.execute(f'ALTER TABLE ds_안테나 ADD COLUMN {_mc}'); conn.commit()
        except Exception: pass
    conn.execute('''CREATE TABLE IF NOT EXISTS ds_전파형식 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        허가번호 TEXT, 장치번호 TEXT, 공중선전력 TEXT
    )''')
    conn.execute('''CREATE TABLE IF NOT EXISTS ds_주파수 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        허가번호 TEXT, 장치번호 TEXT, 주파수 TEXT, 송수신구분 TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_dsd_일반 ON ds_일반사항(허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_dsd_장치 ON ds_장치(허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_dsd_안테나 ON ds_안테나(허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_dsd_전파 ON ds_전파형식(허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_dsd_주파수 ON ds_주파수(허가번호)')
    conn.execute('''CREATE TABLE IF NOT EXISTS ds_변경이력 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        허가번호 TEXT NOT NULL,
        변경일자 TEXT NOT NULL,
        시트 TEXT NOT NULL,
        필드명 TEXT NOT NULL,
        변경전값 TEXT,
        변경후값 TEXT,
        장치번호 TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_dsh_허가번호 ON ds_변경이력(허가번호)')
    conn.commit(); conn.close()

try:
    _init_inspection_db()
    _init_ds_detail_db()
except Exception as _e:
    logger.warning(f"inspection DB 초기화 실패 (무시): {_e}")

# ── ds_detail.db 빌드 (XLS ZIP → 장치/안테나/일반사항) ────

def _build_ds_detail_from_zip_sync(zip_path: str):
    """DS ZIP에서 일반사항/장치/안테나/전파형식/주파수 시트 파싱 → ds_detail.db 갱신."""
    import sqlite3, zipfile
    _init_ds_detail_db()
    conn = sqlite3.connect(_DS_DETAIL_DB, timeout=60)
    conn.execute('PRAGMA journal_mode=WAL')

    # 1pass: 모든 데이터 수집 (INSERT 전 DELETE를 위해 허가번호 먼저 확보)
    batches: dict = {'일반사항': [], '장치': [], '안테나': [], '전파형식': [], '주파수': []}
    _seen_licenses: set = set()

    def _col_idx(ws, *names):
        h = [str(ws.cell_value(0, c)) for c in range(ws.ncols)]
        for name in names:
            if name in h: return h.index(name)
        return -1

    def _sv(ws, r, ci):
        return str(ws.cell_value(r, ci) or '').strip() if ci >= 0 else ''

    def _hn(ws, r, ci):
        """허가번호 정규화: 하이픈 제거 (inspection_targets와 형식 통일)"""
        return _sv(ws, r, ci).replace('-', '')

    try:
        with zipfile.ZipFile(zip_path, 'r') as zf:
            xls_names = [n for n in zf.namelist() if n.lower().endswith('.xls') and not n.startswith('__') and '(100)' not in n]
            for xls_name in xls_names:
                try:
                    with zf.open(xls_name) as xf:
                        raw = xf.read()
                    wb = xlrd.open_workbook(file_contents=raw)
                    sheet_names = wb.sheet_names()

                    # 일반사항
                    if '일반사항' in sheet_names:
                        ws = wb.sheet_by_name('일반사항')
                        hi = _col_idx(ws, '허가번호'); mi = _col_idx(ws, '무선국명'); ci = _col_idx(ws, '호출명칭')
                        zi = _col_idx(ws, '통합시설명칭')
                        gi = _col_idx(ws, '공용화구분코드명')
                        if hi >= 0:
                            for r in range(1, ws.nrows):
                                h = _hn(ws, r, hi)
                                if h:
                                    _seen_licenses.add(h)
                                    batches['일반사항'].append((h, _sv(ws, r, mi), _sv(ws, r, ci), _sv(ws, r, zi), _sv(ws, r, gi)))

                    # 장치
                    if '장치' in sheet_names:
                        ws = wb.sheet_by_name('장치')
                        hi = _col_idx(ws, '허가번호'); ji = _col_idx(ws, '장치번호')
                        si = _col_idx(ws, '기기일련번호'); fi = _col_idx(ws, '형식검정번호')
                        vi = _col_idx(ws, '장치상태')
                        if hi >= 0:
                            for r in range(1, ws.nrows):
                                h = _hn(ws, r, hi)
                                if h:
                                    _seen_licenses.add(h)
                                    batches['장치'].append((h, _sv(ws, r, ji), _sv(ws, r, si), _sv(ws, r, fi), _sv(ws, r, vi) if vi >= 0 else ''))

                    # 안테나
                    if '안테나' in sheet_names:
                        ws = wb.sheet_by_name('안테나')
                        hi = _col_idx(ws, '허가번호'); ji = _col_idx(ws, '장치번호')
                        ki = _col_idx(ws, '기'); ei = _col_idx(ws, '이득')
                        pi = _col_idx(ws, '공중선주 설치형태명', '공중선주설치형태명')
                        ai = _col_idx(ws, '공중선일련번호')
                        ni = _col_idx(ws, '공중선형식명')
                        if hi >= 0:
                            for r in range(1, ws.nrows):
                                h = _hn(ws, r, hi)
                                if h:
                                    _seen_licenses.add(h)
                                    batches['안테나'].append((h, _sv(ws, r, ji), _sv(ws, r, ki), _sv(ws, r, ei),
                                                             _sv(ws, r, pi), _sv(ws, r, ai), _sv(ws, r, ni)))

                    # 전파형식
                    if '전파형식' in sheet_names:
                        ws = wb.sheet_by_name('전파형식')
                        hi = _col_idx(ws, '허가번호'); ji = _col_idx(ws, '장치번호')
                        pi = _col_idx(ws, '공중선전력', '공중선 전력')
                        if hi >= 0:
                            for r in range(1, ws.nrows):
                                h = _hn(ws, r, hi)
                                if h:
                                    _seen_licenses.add(h)
                                    batches['전파형식'].append((h, _sv(ws, r, ji), _sv(ws, r, pi)))

                    # 주파수
                    if '주파수' in sheet_names:
                        ws = wb.sheet_by_name('주파수')
                        hi = _col_idx(ws, '허가번호'); ji = _col_idx(ws, '장치번호')
                        fi = _col_idx(ws, '주파수', '주파수(MHz)')
                        di = _col_idx(ws, '송수신구분', '송수신 구분')
                        if hi >= 0:
                            for r in range(1, ws.nrows):
                                h = _hn(ws, r, hi)
                                if h:
                                    _seen_licenses.add(h)
                                    batches['주파수'].append((h, _sv(ws, r, ji), _sv(ws, r, fi), _sv(ws, r, di)))

                    wb.release_resources()
                except Exception as xe:
                    logger.warning(f"ds_detail XLS 파싱 실패 {xls_name}: {xe}")

        # 2pass: 기존 데이터 삭제 후 재삽입 (SQLite 변수 제한 900개씩 배치)
        if _seen_licenses:
            lic_list = list(_seen_licenses)
            _BATCH = 900
            for tbl in ('ds_일반사항', 'ds_장치', 'ds_안테나', 'ds_전파형식', 'ds_주파수'):
                for i in range(0, len(lic_list), _BATCH):
                    chunk = lic_list[i:i+_BATCH]
                    ph = ','.join('?' * len(chunk))
                    conn.execute(f'DELETE FROM {tbl} WHERE 허가번호 IN ({ph})', chunk)
            conn.executemany('INSERT OR REPLACE INTO ds_일반사항(허가번호,무선국명,호출명칭,통합시설명칭,공용화구분코드명) VALUES(?,?,?,?,?)', batches['일반사항'])
            conn.executemany('INSERT INTO ds_장치(허가번호,장치번호,기기일련번호,형식검정번호,장치상태) VALUES(?,?,?,?,?)', batches['장치'])
            conn.executemany('INSERT INTO ds_안테나(허가번호,장치번호,기,이득,공중선주설치형태명,공중선일련번호,공중선형식명) VALUES(?,?,?,?,?,?,?)', batches['안테나'])
            conn.executemany('INSERT INTO ds_전파형식(허가번호,장치번호,공중선전력) VALUES(?,?,?)', batches['전파형식'])
            conn.executemany('INSERT INTO ds_주파수(허가번호,장치번호,주파수,송수신구분) VALUES(?,?,?,?)', batches['주파수'])
            conn.commit()
            logger.info(f"ds_detail 재빌드 완료: {len(_seen_licenses)}개 허가번호")
    finally:
        conn.close()

# ── KCA 파일 Import 백그라운드 잡 ──────────────────────────

def _process_inspection_sync(job_id: str, s3_key: str, year: int, uploaded_by: str):
    """KCA 수검대상 Excel → inspection.db 구축 (백그라운드)."""
    import sqlite3, openpyxl, tempfile, gc

    # conn을 최상단에서 열어 _upd와 데이터 writes가 같은 연결 사용
    # → 두 번째 연결이 lock을 시도하는 OperationalError 방지
    _init_inspection_db()
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    conn.execute('PRAGMA synchronous=NORMAL')
    now_iso = datetime.now(timezone.utc).isoformat

    def _upd(pct, stage, **kw):
        """같은 conn으로 job 상태 업데이트 — 별도 연결 열지 않음."""
        now = datetime.now(timezone.utc).isoformat()
        if kw:
            sets = ', '.join(f'{k}=?' for k in kw)
            vals = [pct, stage] + list(kw.values()) + [now, job_id]
            conn.execute(f'UPDATE inspection_jobs SET percent=?, stage=?, {sets}, updated_at=? WHERE job_id=?', vals)
        else:
            conn.execute('UPDATE inspection_jobs SET percent=?, stage=?, updated_at=? WHERE job_id=?',
                         [pct, stage, now, job_id])
        conn.commit()

    try:
        _upd(5, "S3 파일 다운로드 중...")
        tmp = tempfile.NamedTemporaryFile(suffix='.xlsx', delete=False)
        tmp_path = tmp.name; tmp.close()
        s3 = get_s3_client()
        s3.download_file(S3_BUCKET_NAME, s3_key, tmp_path)

        _upd(12, "Excel 시트 목록 확인 중...")
        # ZIP 내부의 workbook.xml만 읽어 시트 이름 추출 (openpyxl 로드 불필요)
        sheet_names = _list_xlsx_sheet_names(tmp_path)

        # 해당 연도 기존 데이터 삭제
        conn.execute('DELETE FROM inspection_targets_staging WHERE year=?', (year,))
        conn.execute('DELETE FROM inspection_meta WHERE year=?', (year,))
        conn.commit()

        # cert 전체를 dict에 로드 → 행마다 DB 연결 불필요 (74만행 × DB연결 제거)
        # cert DB가 이미 빌드되어 있으면 재사용 (subprocess에서 45초 절약)
        _upd(14, "ERP 데이터 로드 중...")
        global _cert_cache_db_path
        _cert_db = os.path.join(_tempfile.gettempdir(), "cert_cache.db")
        if not os.path.exists(_cert_db) or os.path.getsize(_cert_db) < 1000:
            _cert_cache_load()
        else:
            # subprocess에서 _cert_cache_db_path가 비어있을 수 있으므로 세팅
            _cert_cache_db_path = _cert_db
            logger.info(f"cert DB 캐시 재사용: {_cert_db}")
        def _norm_code(v) -> str:
            """통시/공대 코드 정규화: float 문자열·앞자리 0 제거.
            '5410001.0' → '5410001', '05410001' → '5410001'"""
            s = str(v).strip()
            if not s:
                return s
            # float 형태('12345.0') → 정수 문자열
            if '.' in s:
                try:
                    s = str(int(float(s)))
                except ValueError:
                    pass
            # 앞자리 0 제거 (숫자로만 구성된 경우)
            if s.isdigit():
                s = str(int(s))
            return s

        cert_map: dict = {}
        # (normed_zpcode, normed_zpwino) → zpcname
        # zpcode=통시코드, zpwino=허가번호 — 동일 통시코드 복수 행 구분용
        cert_name_map: dict = {}
        try:
            c2 = sqlite3.connect(_cert_db, timeout=60)
            for r in c2.execute('SELECT zpwina, zpwino, area_hdofc_nm, ons_team_nm, zpcode FROM cert'):
                hdofc = str(r[2] or ''); team = str(r[3] or ''); name = str(r[0] or '')  # zpwina = 호출명칭
                n_zpwina = _norm_code(r[0]) if r[0] else ''
                n_zpwino = _norm_code(str(r[1] or '').replace('-', '')) if r[1] else ''
                n_zpcode = _norm_code(r[4]) if r[4] else ''  # zpcode는 이제 r[4]
                for ncode in filter(None, [n_zpwina, n_zpwino]):
                    existing = cert_map.get(ncode)
                    if existing is None:
                        cert_map[ncode] = (hdofc, team, name)
                    elif name and not existing[2]:
                        cert_map[ncode] = (existing[0], existing[1], name)
                # (통시코드, 허가번호) 쌍으로 zpcname 정확 매칭
                if n_zpcode and n_zpwino and name:
                    cert_name_map[(n_zpcode, n_zpwino)] = name
            c2.close()
            logger.info(f"cert_map 로드: {len(cert_map)}개 코드, {len(cert_name_map)}개 (통시+허가) 매핑")
        except Exception as e:
            logger.warning(f"cert_map 로드 실패: {e}")

        # 학습 맵 캐시: JSON 파일이 있으면 재사용 (23초 절약)
        _learned_cache = os.path.join(_tempfile.gettempdir(), "learned_addr_map.json")
        _upd(17, "주소-팀 매핑 학습 중 (ERP 데이터)...")
        import json as _j2
        _cache_valid = False
        if os.path.exists(_learned_cache):
            try:
                cache_age = _time_mod.time() - os.path.getmtime(_learned_cache)
                if cache_age < 86400:
                    with open(_learned_cache, 'r', encoding='utf-8') as f:
                        learned_addr_map = _j2.load(f)
                    if learned_addr_map:  # 비어있으면 재생성
                        logger.info(f"학습 맵 캐시 재사용: {len(learned_addr_map)}개 키워드 ({cache_age:.0f}초 전)")
                        _cache_valid = True
            except Exception:
                pass
        if not _cache_valid:
            learned_addr_map = _learn_addr_map_from_cert_db(db_path=_cert_db)
            with open(_learned_cache, 'w', encoding='utf-8') as f:
                _j2.dump(learned_addr_map, f, ensure_ascii=False)

        def _match_access(tongsi: str, gongtae: str):
            """cert dict에서 통시코드로 access담당/품질개선팀 조회 (O(1)).
            정규화된 코드로 조회 — float 문자열·앞자리 0 차이 허용."""
            for val in [tongsi, gongtae]:
                if not val:
                    continue
                normed = _norm_code(val)
                if normed in cert_map:
                    entry = cert_map[normed]
                    return entry[0], entry[1]
            return '', ''

        def _lookup_name(tongsi: str, gongtae: str, license_no: str = '') -> str:
            """cert dict에서 통시코드+허가번호로 호출명칭(zpcname) 조회.
            동일 통시코드에 복수 행이 있을 때 허가번호로 정확 매칭 우선."""
            # 허가번호 하이픈 제거 후 정규화 (KCA "32-2015-61-0014690" → cert "322015610014690")
            normed_lic = _norm_code(license_no.replace('-', '')) if license_no else ''
            for val in [tongsi, gongtae]:
                if not val:
                    continue
                normed = _norm_code(val)
                # 1) 허가번호 정확 매칭
                if normed_lic:
                    name = cert_name_map.get((normed, normed_lic))
                    if name:
                        return name
                # 2) 통시코드만으로 fallback
                entry = cert_map.get(normed)
                if entry and len(entry) > 2 and entry[2]:
                    return entry[2]
            return ''

        def _correct_hdqt(access: str, team: str) -> str:
            """팀명으로 본부 보정 — 하드코딩 INSP_TEAM_TO_HDQT 기준."""
            if team in INSP_TEAM_TO_HDQT:
                return INSP_TEAM_TO_HDQT[team]
            return access  # 매핑 없으면 원본 유지

        INSERT_SQL = '''INSERT INTO inspection_targets_staging
            (year,sheet,pnu_code,허가번호,호출명칭,국종군,부서,분기,연도주기,검사주기,
             허가상태,설치장소,도로명주소,장치수,통시,공대,kca검토결과,시기조정,
             기준연도,skt본부,access담당,품질개선팀,검사종류)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)'''

        total_skt = 0; total_s1 = 0; matched = 0; unmatched = 0

        _INVALID_TEAM = {'#N/A', '#n/a', 'N/A', 'n/a', '미배정', '-', '없음', '', '0', '0.0'}

        def _proc_sheet(rows, sheet_label, pct_start, pct_end, is_skt,
                        learned_map=None, total_rows=0, insp_type_col=-1,
                        col_map=None):
            """헤더명 기반 컬럼 매핑(col_map). None이거나 누락된 키는 기존 인덱스 기본값 사용."""
            nonlocal matched, unmatched
            cm = col_map or {}
            # 헤더명 → 인덱스 조회 헬퍼 (없으면 기본 인덱스 fallback)
            def _ci(key, default_idx):
                idx = cm.get(key, -1)
                return idx if idx >= 0 else default_idx
            # 컬럼 인덱스 (헤더 기반 우선, fallback은 기존 고정 인덱스)
            IDX_PNU      = _ci('pnu_code', 0)
            IDX_HN       = _ci('허가번호', 2)
            IDX_NAME     = _ci('호출명칭', 3)
            IDX_GROUP    = _ci('국종군', 4)
            IDX_QUARTER  = _ci('분기', 8)
            IDX_CYCLE_YR = _ci('연도주기', 9)
            IDX_CYCLE    = _ci('검사주기', 10)
            IDX_DEPT     = _ci('부서', 11)
            IDX_STATUS   = _ci('허가상태', 12)
            IDX_LOC      = _ci('설치장소', 13)
            IDX_ROAD     = _ci('도로명주소', 14)
            IDX_EXTRA1   = _ci('도로명주소2', 15)
            IDX_DEVCNT   = _ci('장치수', 16)
            IDX_ADJ      = _ci('시기조정', 25)
            IDX_KCA      = _ci('kca검토결과', 26)
            IDX_BASE_YR  = _ci('기준연도', 27)
            IDX_TONGSI   = _ci('통시', 28)
            IDX_GONGTAE  = _ci('공대', 29)
            IDX_SKTHDQT  = _ci('skt본부', 30)
            IDX_ACCESS   = _ci('access담당', 31)
            IDX_TEAM     = _ci('품질개선팀', 32)

            batch = []; row_count = 0
            for i, row in enumerate(rows):
                # 허가번호 없거나 빈 행 스킵 — None, 빈 문자열, 공백 모두 제외
                if len(row) <= IDX_HN:
                    continue
                raw_license = str(row[IDX_HN] or '').strip()
                if not raw_license:
                    continue
                # #N/A, 미배정 등 무효값 → 빈 문자열로 정규화
                access = str(row[IDX_ACCESS] or '').strip() if is_skt and len(row) > IDX_ACCESS else ''
                if access in _INVALID_TEAM: access = ''
                품질 = str(row[IDX_TEAM] or '').strip() if is_skt and len(row) > IDX_TEAM else ''
                if 품질 in _INVALID_TEAM: 품질 = ''
                tongsi = str(row[IDX_TONGSI] or '').strip() if is_skt and len(row) > IDX_TONGSI else ''
                gongtae = str(row[IDX_GONGTAE] or '').strip() if is_skt and len(row) > IDX_GONGTAE else ''
                skt본부_raw = str(row[IDX_SKTHDQT] or '').strip() if is_skt and len(row) > IDX_SKTHDQT else ''
                skt본부 = _normalize_skt_hdqt(skt본부_raw)

                # 초기 매핑: access/팀 없으면 cert DB로 조회
                if not access:
                    access, 품질 = _match_access(tongsi, gongtae)
                    if access: matched += 1
                    else: unmatched += 1
                else:
                    matched += 1

                # ── 4단계 본부/팀 보정 ──
                # 엑셀 원본 access담당이 유효한 본부명이면 보정 스킵 (원본 우선)
                # 유효: 정확한 본부명 or "본부명+Access" or "본부명+Access담당"
                _access_base = re.sub(r'Access담당$|Access$', '', access).strip()
                _orig_access_is_valid = _access_base in _ACCESS_TO_SKT_HDQT
                if _orig_access_is_valid and _access_base != access:
                    access = _access_base  # "강북Access" → "강북" 정규화
                if 품질 in INSP_TEAM_TO_HDQT:
                    # 1) 현재 팀명 → 본부 직접 보정 (단, 원본 본부명이 유효하면 본부는 유지)
                    if not _orig_access_is_valid:
                        access = INSP_TEAM_TO_HDQT[품질]
                elif 품질 in _DEPRECATED_TEAM_MAP:
                    # 2) 알려진 폐지 팀 → 현재 팀으로 교체
                    품질 = _DEPRECATED_TEAM_MAP[품질]
                    if not _orig_access_is_valid:
                        access = INSP_TEAM_TO_HDQT.get(품질, access)
                elif not _orig_access_is_valid:
                    # 3) 원본 본부명이 없거나 무효한 경우만 tongsi/gongtae → cert DB 재조회
                    fb_access, fb_team = _match_access(tongsi, gongtae)
                    if fb_team and fb_team in INSP_TEAM_TO_HDQT:
                        access = INSP_TEAM_TO_HDQT[fb_team]
                        품질 = fb_team
                    else:
                        # 4) 주소 키워드로 팀 추론 (ERP cert DB 학습 맵 + Seoul 구명)
                        addr_parts = []
                        for ci in {IDX_LOC, IDX_ROAD, IDX_EXTRA1, 22}:
                            if ci >= 0 and len(row) > ci and row[ci]:
                                addr_parts.append(str(row[ci]).strip())
                        addr = ' '.join(addr_parts)
                        inferred_hdqt, inferred_team = _hdqt_from_addr(
                            addr, known_hdqt=access or fb_access,
                            learned_map=learned_map)
                        if inferred_team:
                            access = INSP_TEAM_TO_HDQT[inferred_team]
                            품질 = inferred_team
                        elif inferred_hdqt:
                            access = inferred_hdqt

                # 5) 원본 본부명 없고 팀 미배정이면 PNU코드 → 법정동 주소 변환 → 팀 추론
                if not _orig_access_is_valid and (not 품질 or 품질 not in INSP_TEAM_TO_HDQT):
                    pnu_raw = str(row[IDX_PNU] or '').strip() if len(row) > IDX_PNU else ''
                    if pnu_raw and len(pnu_raw) >= 10:
                        pnu_addr = _pnu_to_addr(pnu_raw)
                        if pnu_addr:
                            pnu_hdqt, pnu_team = _hdqt_from_addr(
                                pnu_addr, known_hdqt=access,
                                learned_map=learned_map)
                            if pnu_team:
                                access = INSP_TEAM_TO_HDQT[pnu_team]
                                품질 = pnu_team
                            elif pnu_hdqt:
                                access = pnu_hdqt

                def _safe_int(v, default=0):
                    """문자열/숫자 → int 안전 변환."""
                    if not v or v == '':
                        return default
                    try:
                        return int(float(str(v)))
                    except (ValueError, TypeError):
                        return default

                def _safe_str(v):
                    return str(v).strip() if v else ''

                # 최종 access담당이 확정됐으니 skt본부 재정규화 (원본 값이 이상했던 케이스 보정)
                if not skt본부 and access:
                    skt본부 = _ACCESS_TO_SKT_HDQT.get(access, '')

                insp_type_raw = _safe_str(row[insp_type_col] if insp_type_col >= 0 and len(row) > insp_type_col else '')
                def _get(idx):
                    return row[idx] if idx >= 0 and len(row) > idx else ''
                호출명칭 = _safe_str(_get(IDX_NAME))
                if 호출명칭.startswith('#'):  # Excel 수식 오류(#N/A, #REF! 등) → 빈값 처리
                    호출명칭 = ''
                if not 호출명칭:
                    호출명칭 = _lookup_name(tongsi, gongtae, raw_license)
                batch.append((
                    year, sheet_label,
                    _safe_str(_get(IDX_PNU)),
                    _safe_str(_get(IDX_HN)),
                    호출명칭,
                    _safe_str(_get(IDX_GROUP)),
                    _safe_str(_get(IDX_DEPT)),
                    _safe_str(_get(IDX_QUARTER)),
                    _safe_str(_get(IDX_CYCLE_YR)),
                    _safe_int(_get(IDX_CYCLE) or 0),
                    _safe_str(_get(IDX_STATUS)),
                    _safe_str(_get(IDX_LOC)),
                    _safe_str(_get(IDX_ROAD)),
                    _safe_int(_get(IDX_DEVCNT) or 0),
                    tongsi, gongtae,
                    _safe_str(_get(IDX_KCA)),
                    _safe_str(_get(IDX_ADJ)),
                    _safe_int(_get(IDX_BASE_YR) or '', year),
                    skt본부, access, 품질,
                    insp_type_raw,
                ))
                row_count += 1
                if len(batch) >= 5000:
                    conn.executemany(INSERT_SQL, batch); batch.clear()
                    pct = int(pct_start + (pct_end - pct_start) * row_count / max(total_rows, 1))
                    _upd(pct, f"{sheet_label} 처리 중... ({row_count:,}행)")
            if batch: conn.executemany(INSERT_SQL, batch)
            conn.commit()
            return row_count

        # 헤더명 → 인덱스 맵 (모든 주요 컬럼) — SKT/Sheet1 공통 사용
        _HEADER_ALIASES = {
            'pnu_code': ['pnu_code', 'PNU_CODE', 'PNU'],
            '허가번호': ['허가번호'],
            '호출명칭': ['호출명칭'],
            '국종군': ['국종군'],
            '분기': ['분기'],
            '연도주기': ['연도주기'],
            '검사주기': ['검사주기'],
            '부서': ['부서', 'KCA부서'],
            '허가상태': ['허가상태'],
            '설치장소': ['설치장소'],
            '도로명주소': ['도로명주소'],
            '도로명주소2': ['도로명주소2', '도로명주소_보조'],
            '장치수': ['장치수'],
            '시기조정': ['시기조정'],
            'kca검토결과': ['kca검토결과', 'KCA검토결과'],
            '기준연도': ['기준연도'],
            '통시': ['통시'],
            '공대': ['공대'],
            'skt본부': ['skt본부', 'SKT본부'],
            'access담당': ['access담당', 'Access담당'],
            '품질개선팀': ['품질개선팀'],
            '검사종류': ['검사종류'],
        }
        def _build_col_map(sname):
            cm = {}
            for _rn, cells in _iter_xlsx_rows_light(tmp_path, sheet_name=sname):
                if _rn == 0:
                    header_norm = [str(c or '').strip() for c in cells]
                    for key, aliases in _HEADER_ALIASES.items():
                        for al in aliases:
                            if al in header_norm:
                                cm[key] = header_norm.index(al)
                                break
                break
            return cm

        # SKT 시트 — ZIP+XML 경량 파서 (openpyxl 제거, 메모리 ~95% 절감)
        if 'SKT' in sheet_names:
            _upd(20, "SKT 시트 처리 중...")
            _log_mem("SKT 시트 처리 전")

            _skt_col_map = _build_col_map('SKT')
            _insp_type_col = _skt_col_map.get('검사종류', -1)
            logger.info(f"SKT 시트 헤더 매핑: {_skt_col_map}")

            def _light_rows(path, sname):
                """_iter_xlsx_rows_light 래퍼: (row_num, cells) → cells(리스트)로 변환."""
                for _rn, cells in _iter_xlsx_rows_light(path, sheet_name=sname):
                    if _rn == 0:
                        continue  # 헤더(0행) 스킵
                    yield cells

            total_skt = _proc_sheet(
                _light_rows(tmp_path, 'SKT'),
                'SKT', 20, 70, True,
                learned_map=learned_addr_map,
                total_rows=0,
                insp_type_col=_insp_type_col,
                col_map=_skt_col_map)
            _release_memory()
            _log_mem("SKT 시트 처리 후")

        # Sheet1 (시기조정)
        if 'Sheet1' in sheet_names:
            _upd(72, "시기조정 시트 처리 중...")
            # Sheet1도 헤더명 기반 매핑 (SKT와 동일한 헬퍼 사용)
            _s1_col_map = _build_col_map('Sheet1')
            _s1_insp_type_col = _s1_col_map.get('검사종류', -1)
            logger.info(f"Sheet1 시트 헤더 매핑: {_s1_col_map}")
            total_s1 = _proc_sheet(
                _light_rows(tmp_path, 'Sheet1'),
                'sheet1', 72, 85, False,
                learned_map=learned_addr_map,
                total_rows=0,
                insp_type_col=_s1_insp_type_col,
                col_map=_s1_col_map)
            _release_memory()
            _log_mem("시기조정 시트 처리 후")

        os.unlink(tmp_path)
        _release_memory()

        # ── 미배정 항목 상세 로그 ──
        try:
            unassigned = conn.execute(
                'SELECT 허가번호, 호출명칭, 도로명주소, 설치장소, 통시, 공대 '
                'FROM inspection_targets_staging '
                'WHERE year=? AND (access담당 IS NULL OR access담당="" OR 품질개선팀 IS NULL OR 품질개선팀="")',
                (year,)
            ).fetchall()
            if unassigned:
                logger.warning(f"  [미배정 항목] {len(unassigned)}건 — 본부/팀 매핑 실패:")
                for row in unassigned[:30]:
                    logger.warning(f"    허가={row[0]} 호출={row[1]} "
                                   f"도로명=[{row[2]}] 설치=[{row[3]}] 통시={row[4]} 공대={row[5]}")
                if len(unassigned) > 30:
                    logger.warning(f"    ... 외 {len(unassigned) - 30}건")
        except Exception as e:
            logger.warning(f"미배정 로그 조회 실패: {e}")

        # 메타 저장
        now_str = datetime.now(timezone.utc).isoformat()
        conn.execute('''INSERT OR REPLACE INTO inspection_meta
            (year,sheet,total_skt,total_sheet1,matched,unmatched,s3_key,filename,imported_by,imported_at)
            VALUES(?,?,?,?,?,?,?,?,?,?)''',
            (year, 'SKT+sheet1', total_skt, total_s1, matched, unmatched, s3_key, s3_key.split('/')[-1], uploaded_by, now_str))
        conn.commit()
        _upd(100, f"완료 — SKT {total_skt:,}건 / 시기조정 {total_s1:,}건 / 매칭 {matched:,}건",
             status="complete", total_skt=total_skt, total_sheet1=total_s1, matched=matched, unmatched=unmatched)
        logger.info(f"inspection import 완료: year={year} skt={total_skt} sheet1={total_s1}")

    except Exception as ex:
        logger.error(f"inspection import 실패: {ex}", exc_info=True)
        try:
            _upd(0, f'실패: {ex}', status='error')
        except Exception:
            pass
    finally:
        try:
            conn.close()
        except Exception:
            pass
        # 대형 딕셔너리 명시 해제 + OS에 메모리 반환
        try:
            cert_map.clear()
            learned_addr_map.clear()
        except Exception:
            pass
        _release_memory()
        _log_mem("inspection import 완료 후")

# ── Endpoints ──────────────────────────────────────────────

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

@app.post("/inspection/upload-raw")
async def inspection_upload_raw(request: Request):
    """KCA Excel → S3 스트리밍 업로드."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    fname = request.headers.get("X-Filename", "inspection.xlsx")
    s3_key = f"{INSPECTION_S3_PREFIX}{fname}"
    s3 = get_s3_client()
    mp = s3.create_multipart_upload(Bucket=S3_BUCKET_NAME, Key=s3_key)
    upload_id = mp["UploadId"]
    parts = []; part_num = 0; buf = b""
    PART_SIZE = 8 * 1024 * 1024

    try:
        async for chunk in request.stream():
            buf += chunk
            while len(buf) >= PART_SIZE:
                part_num += 1
                resp = s3.upload_part(Bucket=S3_BUCKET_NAME, Key=s3_key,
                                      UploadId=upload_id, PartNumber=part_num, Body=buf[:PART_SIZE])
                parts.append({"PartNumber": part_num, "ETag": resp["ETag"]})
                buf = buf[PART_SIZE:]
        if buf:
            part_num += 1
            resp = s3.upload_part(Bucket=S3_BUCKET_NAME, Key=s3_key,
                                  UploadId=upload_id, PartNumber=part_num, Body=buf)
            parts.append({"PartNumber": part_num, "ETag": resp["ETag"]})
        s3.complete_multipart_upload(Bucket=S3_BUCKET_NAME, Key=s3_key,
                                     UploadId=upload_id, MultipartUpload={"Parts": parts})
    except Exception as ex:
        s3.abort_multipart_upload(Bucket=S3_BUCKET_NAME, Key=s3_key, UploadId=upload_id)
        raise HTTPException(500, f"업로드 실패: {ex}")

    return {"success": True, "s3Key": s3_key}

@app.post("/inspection/enqueue")
async def inspection_enqueue(request: Request, req: InspectionEnqueueReq):
    """KCA Import 백그라운드 잡 생성 — 별도 프로세스로 실행 (API 서버 블록 방지)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    job_id = str(uuid.uuid4())
    _init_inspection_db()
    await asyncio.to_thread(_insp_job_write_sync, job_id, status='processing', stage='대기 중...', percent=0)

    # 별도 프로세스로 Import 실행 — API 서버가 블록되지 않음
    import subprocess
    worker_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'inspection_worker.py')
    log_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), f'inspection_{job_id[:8]}.log')
    venv_python = sys.executable  # 현재 가상환경의 python
    log_fh = open(log_path, 'w')
    subprocess.Popen(
        [venv_python, worker_path, job_id, req.s3Key, str(req.year), req.uploadedBy],
        cwd=os.path.dirname(os.path.abspath(__file__)),
        stdout=log_fh,
        stderr=log_fh,
        start_new_session=True,  # 부모 프로세스와 완전 분리
    )
    logger.info(f"inspection import subprocess 시작: job={job_id}")
    return {"success": True, "jobId": job_id}

@app.get("/inspection/job/{job_id}")
async def inspection_job_status(job_id: str, request: Request):
    await _verify_auth(request)
    job = await asyncio.to_thread(_insp_job_read_sync, job_id)
    if not job: raise HTTPException(404, "잡 없음")
    return job

@app.post("/inspection/build-ds-detail")
async def inspection_build_ds_detail(request: Request, division_id: str, import_date: str):
    """DS ZIP → ds_detail.db 빌드 (관리자 수동 트리거)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}: raise HTTPException(403, "권한 없음")

    # DynamoDB에서 s3Key 조회
    dynamodb = get_dynamodb_resource()
    table = dynamodb.Table(DYNAMODB_TABLES["ds_uploads"])
    resp = await asyncio.to_thread(lambda: table.query(
        KeyConditionExpression=Key("divisionId").eq(division_id) & Key("importDate").begins_with(import_date),
        ProjectionExpression="s3Key", Limit=1))
    items = resp.get("Items", [])
    if not items: raise HTTPException(404, "DS 업로드 없음")
    s3_key = items[0].get("s3Key", "")
    if not s3_key: raise HTTPException(404, "S3 키 없음")

    job_id = str(uuid.uuid4())
    _inspection_jobs[job_id] = {"status": "processing", "stage": "ds_detail 빌드 중...", "percent": 0}

    async def _run():
        try:
            import tempfile
            s3 = get_s3_client()
            tmp = tempfile.NamedTemporaryFile(suffix='.zip', delete=False)
            tmp_path = tmp.name; tmp.close()
            s3.download_file(S3_BUCKET_NAME, s3_key, tmp_path)
            await asyncio.to_thread(_build_ds_detail_from_zip_sync, tmp_path)
            os.unlink(tmp_path)
            _inspection_jobs[job_id].update({"status": "complete", "percent": 100, "stage": "완료"})
        except Exception as ex:
            _inspection_jobs[job_id].update({"status": "error", "stage": str(ex), "percent": 0})

    asyncio.create_task(_run())
    return {"success": True, "jobId": job_id}

@app.get("/inspection/meta")
async def inspection_meta(request: Request):
    """Import 이력 조회."""
    await _verify_auth(request)
    import sqlite3
    if not os.path.exists(_INSP_DB): return {"items": []}
    conn = sqlite3.connect(_INSP_DB, timeout=60); conn.row_factory = sqlite3.Row
    rows = conn.execute('SELECT * FROM inspection_meta ORDER BY year DESC').fetchall()
    conn.close()
    return {"items": [dict(r) for r in rows]}

@app.get("/inspection/unassigned")
async def inspection_unassigned(request: Request, year: int = Query(...)):
    """미배정(본부/팀 없음) 항목 조회 — 관리자 화면에서 확인용."""
    await _verify_auth(request)
    import sqlite3
    if not os.path.exists(_INSP_DB):
        return {"total": 0, "items": [], "by_region": {}}
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        'SELECT 허가번호, 호출명칭, 도로명주소, 설치장소, 국종군, 분기, 통시, 공대, access담당, 품질개선팀 '
        'FROM inspection_targets '
        'WHERE year=? AND (access담당 IS NULL OR access담당="" OR 품질개선팀 IS NULL OR 품질개선팀="")',
        (year,)
    ).fetchall()
    import re
    geo_re = re.compile(r'[가-힣]+(?:시|군|구)')
    by_region: dict = {}
    by_reason: dict = {"코드없음": 0, "ERP미매칭": 0}
    items = []
    for r in rows:
        addr = r['도로명주소'] or r['설치장소'] or ''
        matches = geo_re.findall(addr)
        region = ' '.join(matches[:2]) if matches else '주소없음'
        by_region.setdefault(region, 0)
        by_region[region] += 1
        # 미배정 원인 분류
        has_code = bool((r['통시'] or '').strip() or (r['공대'] or '').strip())
        reason = "ERP미매칭" if has_code else "코드없음"
        by_reason[reason] += 1
        d = dict(r)
        d['미배정원인'] = reason
        items.append(d)
    conn.close()
    return {
        "total": len(rows),
        "items": items[:500],   # 브라우저 OOM 방지: 상위 500건만 반환
        "items_capped": len(rows) > 500,
        "by_region": dict(sorted(by_region.items(), key=lambda x: -x[1])),
        "by_reason": by_reason,
    }

@app.get("/inspection/column-values")
async def inspection_column_values(request: Request, year: int, col: str, sheet: str = "all"):
    """필터 UI용 컬럼 고유값 조회."""
    await _verify_auth(request)
    ALLOWED_COLS = {'분기','국종군','부서','kca검토결과','시기조정','skt본부','access담당','품질개선팀','허가상태'}
    if col not in ALLOWED_COLS: raise HTTPException(400, "허용되지 않은 컬럼")
    import sqlite3
    if not os.path.exists(_INSP_DB): return {"values": []}
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    where = "year=?"
    params: list = [year]
    if sheet != "all": where += " AND sheet=?"; params.append(sheet)
    col_q = col.replace('담당','담당').replace('팀','팀')
    rows = conn.execute(f'SELECT DISTINCT "{col_q}" FROM inspection_targets WHERE {where} AND "{col_q}" IS NOT NULL AND "{col_q}" != "" ORDER BY "{col_q}"', params).fetchall()
    conn.close()
    return {"values": [r[0] for r in rows]}

@app.get("/inspection/staging/column-values")
async def inspection_staging_column_values(request: Request, year: int, col: str):
    """스테이징 데이터의 컬럼별 고유값+건수 조회 (필터 UI용)."""
    await _verify_auth(request)
    ALLOWED_COLS = {'분기','국종군','부서','kca검토결과','시기조정','skt본부','access담당','품질개선팀','허가상태','허가번호','호출명칭','연도주기','검사주기','설치장소','도로명주소','장치수','통시','공대','기준연도','pnu_code'}
    if col not in ALLOWED_COLS: raise HTTPException(400, "허용되지 않은 컬럼")
    import sqlite3
    if not os.path.exists(_INSP_DB): return {"values": []}
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    rows = conn.execute(
        f'SELECT "{col}", COUNT(*) as cnt FROM inspection_targets_staging WHERE year=? GROUP BY "{col}" ORDER BY cnt DESC',
        (year,)).fetchall()
    conn.close()
    return {"values": [{"value": r[0] or "", "count": r[1]} for r in rows]}

@app.get("/inspection/org-map")
async def inspection_org_map(request: Request, year: int):
    """본부→팀 매핑 + 분기/국종군/KCA결과 고유값 반환."""
    await _verify_auth(request)
    import sqlite3
    if not os.path.exists(_INSP_DB):
        return {"org": {}, "quarters": [], "nation_groups": [], "kca_results": []}
    conn = sqlite3.connect(_INSP_DB, timeout=60); conn.row_factory = sqlite3.Row
    rows = conn.execute(
        'SELECT DISTINCT "access담당", "품질개선팀" FROM inspection_targets WHERE year=? AND "access담당" != "" ORDER BY "access담당", "품질개선팀"',
        (year,)).fetchall()
    quarters = [r[0] for r in conn.execute(
        'SELECT DISTINCT 분기 FROM inspection_targets WHERE year=? AND 분기 != "" ORDER BY 분기', (year,)).fetchall()]
    nation_groups = [r[0] for r in conn.execute(
        'SELECT DISTINCT 국종군 FROM inspection_targets WHERE year=? AND 국종군 != "" ORDER BY 국종군', (year,)).fetchall()]
    kca_results = [r[0] for r in conn.execute(
        'SELECT DISTINCT "kca검토결과" FROM inspection_targets WHERE year=? AND "kca검토결과" != "" ORDER BY "kca검토결과"', (year,)).fetchall()]
    conn.close()
    # 하드코딩 맵을 primary로 사용 (DB 데이터 오염 방지)
    return {"org": INSP_ORG_MAP, "quarters": quarters, "nation_groups": nation_groups, "kca_results": kca_results}

class InspStagingPreviewReq(BaseModel):
    year: int
    filters: dict = {}  # {col: [val, ...]}

class InspStagingConfirmReq(BaseModel):
    year: int
    filters: dict = {}  # {col: [val, ...]}

@app.post("/inspection/staging/preview")
async def inspection_staging_preview(request: Request, req: InspStagingPreviewReq):
    """스테이징 데이터 필터 미리보기 (행 수 반환)."""
    await _verify_auth(request)
    import sqlite3
    if not os.path.exists(_INSP_DB): return {"total": 0, "filtered": 0}
    ALLOWED_COLS = {'분기','국종군','부서','kca검토결과','시기조정','skt본부','access담당','품질개선팀','허가상태','허가번호','호출명칭','연도주기','검사주기','설치장소','도로명주소','장치수','통시','공대','기준연도','pnu_code'}
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    total = conn.execute('SELECT COUNT(*) FROM inspection_targets_staging WHERE year=?', (req.year,)).fetchone()[0]

    where = ["year=?"]
    params = [req.year]
    for col, vals in req.filters.items():
        if col not in ALLOWED_COLS or not vals: continue
        ph = ",".join("?" * len(vals))
        where.append(f'"{col}" IN ({ph})')
        params.extend(vals)

    filtered = conn.execute(f'SELECT COUNT(*) FROM inspection_targets_staging WHERE {" AND ".join(where)}', params).fetchone()[0]
    conn.close()
    return {"total": total, "filtered": filtered}

class InspStagingItemsReq(BaseModel):
    year: int
    filters: dict = {}
    search: str = ""
    page: int = 1
    pageSize: int = 500

@app.post("/inspection/staging/items")
async def inspection_staging_items(request: Request, req: InspStagingItemsReq):
    """스테이징 항목 목록 조회 (대상 추가 선택용)."""
    await _verify_auth(request)
    import sqlite3
    if not os.path.exists(_INSP_DB):
        return {"items": [], "total": 0}
    ALLOWED_COLS = {'분기','국종군','kca검토결과','access담당','품질개선팀','허가번호','호출명칭','설치장소','도로명주소'}
    where = ["year=?"]
    params: list = [req.year]
    for col, vals in req.filters.items():
        if col not in ALLOWED_COLS or not vals: continue
        ph = ",".join("?" * len(vals))
        where.append(f'"{col}" IN ({ph})')
        params.extend(vals)
    if req.search:
        import re as _re_stg
        keywords = [k.strip() for k in _re_stg.split(r'[,\s]+', req.search.strip()) if k.strip()]
        # 모든 키워드가 허가번호 형식(숫자+하이픈, 15자리)이면 IN 절로 최적화
        _hn_re = _re_stg.compile(r'^[\d\-]{15,19}$')
        all_hn = all(_hn_re.match(kw) for kw in keywords) and len(keywords) > 1
        if all_hn:
            clean_nos = [kw.replace('-', '') for kw in keywords]
            ph = ','.join('?' * len(clean_nos))
            where.append(f"REPLACE(허가번호,'-','') IN ({ph})")
            params.extend(clean_nos)
        else:
            or_parts = []
            for kw in keywords:
                kw_clean = kw.replace('-', '')
                or_parts.append(
                    "(REPLACE(호출명칭,'-','') LIKE ? OR REPLACE(허가번호,'-','') LIKE ? OR REPLACE(도로명주소,'-','') LIKE ? OR REPLACE(설치장소,'-','') LIKE ?)"
                )
                pat = f'%{kw_clean}%'
                params.extend([pat, pat, pat, pat])
            if or_parts:
                where.append(f"({' OR '.join(or_parts)})")
    where_sql = " AND ".join(where)
    offset = (req.page - 1) * req.pageSize
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    conn.row_factory = sqlite3.Row
    total = conn.execute(f'SELECT COUNT(*) FROM inspection_targets_staging WHERE {where_sql}', params).fetchone()[0]
    rows = conn.execute(
        f'SELECT 허가번호, 호출명칭, 품질개선팀, 분기, 국종군, 도로명주소, access담당 '
        f'FROM inspection_targets_staging WHERE {where_sql} '
        f'ORDER BY CASE WHEN 호출명칭 = \'\' THEN 1 ELSE 0 END, 호출명칭 LIMIT ? OFFSET ?',
        params + [req.pageSize, offset]
    ).fetchall()
    # 복수 허가번호 검색 시 피드백 통계
    search_feedback = None
    if req.search:
        import re as _re_fb
        keywords = [k.strip() for k in _re_fb.split(r'[,\s]+', req.search.strip()) if k.strip()]
        _hn_re2 = _re_fb.compile(r'^[\d\-]{15,19}$')
        if len(keywords) > 1 and all(_hn_re2.match(kw) for kw in keywords):
            searched_nos = {kw.replace('-', '') for kw in keywords}
            # staging에서 찾은 허가번호
            found_in_staging = {r['허가번호'].replace('-', '') for r in rows}
            # inspection_targets(본 테이블)에서 이미 추가된 허가번호
            ph2 = ','.join('?' * len(searched_nos))
            slist = list(searched_nos)
            already_rows = conn.execute(
                f"SELECT REPLACE(허가번호,'-','') FROM inspection_targets WHERE year=? AND REPLACE(허가번호,'-','') IN ({ph2})",
                [req.year] + slist
            ).fetchall()
            already_added = {r[0] for r in already_rows}
            not_found = searched_nos - found_in_staging - already_added
            search_feedback = {
                "searched": len(searched_nos),
                "found": len(found_in_staging),
                "already_added": len(already_added),
                "not_found": len(not_found),
                "not_found_nos": sorted(not_found)[:20],
            }
    conn.close()
    result = {"items": [dict(r) for r in rows], "total": total}
    if search_feedback:
        result["search_feedback"] = search_feedback
    return result

@app.post("/inspection/staging/confirm")
async def inspection_staging_confirm(request: Request, req: InspStagingConfirmReq):
    """스테이징 데이터 중 필터된 항목만 본 테이블로 이동."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    import sqlite3
    if not os.path.exists(_INSP_DB): raise HTTPException(400, "DB 없음")

    ALLOWED_COLS = {'분기','국종군','부서','kca검토결과','시기조정','skt본부','access담당','품질개선팀','허가상태','허가번호','호출명칭','연도주기','검사주기','설치장소','도로명주소','장치수','통시','공대','기준연도','pnu_code'}

    where = ["year=?"]
    params = [req.year]
    for col, vals in req.filters.items():
        if col not in ALLOWED_COLS or not vals: continue
        ph = ",".join("?" * len(vals))
        where.append(f'"{col}" IN ({ph})')
        params.extend(vals)
    where_sql = " AND ".join(where)

    conn = sqlite3.connect(_INSP_DB, timeout=60)
    conn.execute('PRAGMA synchronous=NORMAL')
    conn.row_factory = sqlite3.Row

    # 기존 "대상 추가"로 넣은 행들 보존 (재import 시 유실 방지)
    added_rows = conn.execute(
        'SELECT * FROM inspection_targets WHERE year=? AND kca검토결과=?',
        (req.year, '대상 추가')
    ).fetchall()
    added_list = [dict(r) for r in added_rows]
    added_license_nos = {r['허가번호'] for r in added_list if r['허가번호']}

    # 기존 좌표 보관: (허가번호, 도로명주소) → (위도, 경도)
    # 같은 허가번호 + 같은 도로명주소이면 기존 좌표 재사용, 주소 변경 시 재지오코딩 대상
    coord_map: dict = {}
    for r in conn.execute(
        'SELECT 허가번호, 도로명주소, 위도, 경도 FROM inspection_targets '
        'WHERE year=? AND 위도 IS NOT NULL AND 위도 != 0',
        (req.year,)
    ).fetchall():
        hn = r['허가번호'] or ''
        addr = (r['도로명주소'] or '').strip()
        if hn and addr:
            coord_map[(hn, addr)] = (r['위도'], r['경도'])

    # 기존 본 테이블 데이터 삭제 (같은 연도)
    conn.execute('DELETE FROM inspection_targets WHERE year=?', (req.year,))

    # 스테이징에서 필터된 데이터를 본 테이블로 복사 (단, 이미 "대상 추가"로 보존된 허가번호는 제외)
    cols = 'year,sheet,pnu_code,허가번호,호출명칭,국종군,부서,분기,연도주기,검사주기,허가상태,설치장소,도로명주소,장치수,통시,공대,kca검토결과,시기조정,기준연도,skt본부,access담당,품질개선팀,검사종류'
    exclude_sql = ''
    exclude_params: list = []
    if added_license_nos:
        ph = ','.join('?' * len(added_license_nos))
        exclude_sql = f' AND 허가번호 NOT IN ({ph})'
        exclude_params = list(added_license_nos)
    count = conn.execute(
        f'SELECT COUNT(*) FROM inspection_targets_staging WHERE {where_sql}{exclude_sql}',
        params + exclude_params,
    ).fetchone()[0]
    conn.execute(
        f'INSERT INTO inspection_targets ({cols}) SELECT {cols} FROM inspection_targets_staging WHERE {where_sql}{exclude_sql}',
        params + exclude_params,
    )

    # "대상 추가"로 보존한 행들 다시 삽입
    preserved_count = 0
    if added_list:
        col_list = cols.split(',')
        ph = ','.join('?' * len(col_list))
        for row in added_list:
            vals = tuple(row.get(c) for c in col_list)
            conn.execute(f'INSERT INTO inspection_targets ({cols}) VALUES ({ph})', vals)
            preserved_count += 1

    # 스테이징에서 해당 허가번호 제거 (중복 방지)
    if added_license_nos:
        ph = ','.join('?' * len(added_license_nos))
        conn.execute(
            f'DELETE FROM inspection_targets_staging WHERE year=? AND 허가번호 IN ({ph})',
            [req.year] + list(added_license_nos),
        )

    # 확정된 항목만 스테이징에서 제거 (미확정 항목은 유지 → 개별 추가 용도)
    conn.execute(f'DELETE FROM inspection_targets_staging WHERE {where_sql}', params)

    # 기존 좌표 복원: (허가번호, 도로명주소)가 동일한 행에만 적용
    coord_restored = 0
    if coord_map:
        for (hn, addr), (lat, lng) in coord_map.items():
            cur = conn.execute(
                'UPDATE inspection_targets SET 위도=?, 경도=? '
                'WHERE year=? AND 허가번호=? AND 도로명주소=? '
                'AND (위도 IS NULL OR 위도=0)',
                (lat, lng, req.year, hn, addr)
            )
            if cur.rowcount > 0:
                coord_restored += cur.rowcount
    conn.commit()
    conn.close()

    logger.info(f"confirm: {req.year}년 신규 {count}건 + 보존 {preserved_count}건 (대상 추가) + 좌표 복원 {coord_restored}건")

    # confirm 후 백그라운드에서 자동 재매핑 + 지오코딩 실행
    async def _post_confirm_bg():
        try:
            learned_map = await _load_learned_addr_map_async()
            if learned_map:
                result = await asyncio.to_thread(_remap_divisions_sync, req.year, learned_map, False)
                logger.info(f"[auto-remap] {req.year}년 {result['changed_count']}건 재매핑 완료")
            else:
                logger.warning("[auto-remap] learned_map 비어있음 — 재매핑 생략")
        except Exception as e:
            logger.error(f"[auto-remap] 오류: {e}")
        # 재매핑 후 지오코딩
        await _auto_geocode_background(req.year)

    asyncio.create_task(_post_confirm_bg())

    return {"success": True, "count": count, "preserved_count": preserved_count, "coord_restored": coord_restored}


async def _auto_geocode_background(year: int):
    """confirm 후 자동으로 좌표 없는 항목 지오코딩 (백그라운드)."""
    try:
        KAKAO_KEY = "cb3f4b95ada5f92fc3924b9685aec16b"
        CONCURRENCY = 10
        import requests as _req
        from concurrent.futures import ThreadPoolExecutor, as_completed

        def _fetch():
            c = sqlite3.connect(_INSP_DB, timeout=60)
            rows = c.execute(
                'SELECT id, 도로명주소, 설치장소 FROM inspection_targets '
                'WHERE year=? AND (위도 IS NULL OR 위도=0)', (year,)).fetchall()
            c.close()
            return rows

        rows = await asyncio.to_thread(_fetch)
        if not rows:
            return

        addr_map: dict = {}
        for rid, road_addr, install_addr in rows:
            addr = (road_addr or '').strip() or (install_addr or '').strip()
            if addr:
                addr_map.setdefault(addr, []).append(rid)

        unique_addrs = list(addr_map.keys())
        logger.info(f"[auto-geocode] {len(rows)}건 중 고유 주소 {len(unique_addrs)}개 (year={year})")

        def _clean_addr_auto(addr):
            import re
            candidates = [addr]
            no_paren = re.sub(r'[\(\（][^\)\）]*[\)\）]', '', addr).strip()
            if no_paren != addr:
                candidates.append(no_paren)
            no_comma = re.split(r',', no_paren)[0].strip()
            if no_comma != no_paren:
                candidates.append(no_comma)
            no_bunji = re.sub(r'번지', '', no_comma).strip()
            if no_bunji != no_comma:
                candidates.append(no_bunji)
            else:
                no_bunji = no_comma
            no_suffix = re.sub(r'(\d[\d\-]*)\s+[^\d].*$', r'\1', no_bunji).strip()
            if no_suffix != no_bunji and len(no_suffix) > 5:
                candidates.append(no_suffix)
            seen = set()
            result = []
            for c in candidates:
                if c and c not in seen:
                    seen.add(c)
                    result.append(c)
            return result

        _VWORLD_KEY = '60301A2D-7EA7-3C05-9B4D-4BC523408605'

        def _kakao_addr(query):
            try:
                r = _req.get('https://dapi.kakao.com/v2/local/search/address.json',
                    params={'query': query, 'size': 1},
                    headers={'Authorization': f'KakaoAK {KAKAO_KEY}'}, timeout=5)
                if r.status_code == 200:
                    docs = r.json().get('documents', [])
                    if docs:
                        x, y = float(docs[0].get('x', 0)), float(docs[0].get('y', 0))
                        if x and y: return (y, x)
            except Exception: pass
            return None

        def _kakao_keyword(query):
            try:
                r = _req.get('https://dapi.kakao.com/v2/local/search/keyword.json',
                    params={'query': query, 'size': 1},
                    headers={'Authorization': f'KakaoAK {KAKAO_KEY}'}, timeout=5)
                if r.status_code == 200:
                    docs = r.json().get('documents', [])
                    if docs:
                        x, y = float(docs[0].get('x', 0)), float(docs[0].get('y', 0))
                        if x and y: return (y, x)
            except Exception: pass
            return None

        def _vworld(query):
            try:
                r = _req.get('https://api.vworld.kr/req/address',
                    params={'service': 'address', 'request': 'getcoord', 'version': '2.0',
                            'crs': 'epsg:4326', 'address': query, 'refine': 'true',
                            'simple': 'false', 'format': 'json', 'type': 'both',
                            'key': _VWORLD_KEY}, timeout=5)
                if r.status_code == 200:
                    body = r.json().get('response', {})
                    if body.get('status') == 'OK':
                        pt = body.get('result', {}).get('point', {})
                        x, y = float(pt.get('x', 0)), float(pt.get('y', 0))
                        if x and y: return (y, x)
            except Exception: pass
            return None

        _NAVER_ID = 'x0a4aeu0l5'
        _NAVER_SECRET = 't0yDP6Lbti6Ruplw5wfrYKwkPQS3fI806bRVzkBi'

        def _naver(query):
            try:
                r = _req.get('https://maps.apigw.ntruss.com/map-geocode/v2/geocode',
                    params={'query': query},
                    headers={'X-NCP-APIGW-API-KEY-ID': _NAVER_ID,
                             'X-NCP-APIGW-API-KEY': _NAVER_SECRET}, timeout=5)
                if r.status_code == 200:
                    addresses = r.json().get('addresses', [])
                    if addresses:
                        x, y = float(addresses[0].get('x', 0)), float(addresses[0].get('y', 0))
                        if x and y: return (y, x)
            except Exception: pass
            return None

        def _geocode_one(addr):
            try:
                candidates = _clean_addr_auto(addr)
                for c in candidates:
                    res = _kakao_addr(c)
                    if res: return addr, res
                for c in candidates:
                    res = _kakao_keyword(c)
                    if res: return addr, res
                for c in candidates:
                    res = _vworld(c)
                    if res: return addr, res
                for c in candidates:
                    res = _naver(c)
                    if res: return addr, res
                logger.warning(f"[auto-geocode] 주소 매칭 없음: {addr}")
            except Exception as e:
                logger.warning(f"[auto-geocode] 요청 실패: {addr} — {e}")
            return addr, None

        updated = 0
        for i in range(0, len(unique_addrs), 500):
            batch = unique_addrs[i:i+500]
            def _process(ba=batch):
                results = []
                with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
                    for fut in as_completed({pool.submit(_geocode_one, a): a for a in ba}):
                        results.append(fut.result())
                upd = [(c[0], c[1], rid) for addr, c in results if c for rid in addr_map.get(addr, [])]
                if upd:
                    c = sqlite3.connect(_INSP_DB, timeout=60)
                    c.executemany('UPDATE inspection_targets SET 위도=?, 경도=? WHERE id=?', upd)
                    c.commit(); c.close()
                return len(upd)
            updated += await asyncio.to_thread(_process)

        logger.info(f"[auto-geocode] 완료: {updated}/{len(rows)}건 (year={year})")
    except Exception as e:
        logger.error(f"[auto-geocode] 오류: {e}")


async def _load_learned_addr_map_async() -> dict:
    """학습된 주소→팀 맵 로드 (캐시 우선, 없으면 cert DB에서 생성)."""
    import tempfile as _tf, json as _jr
    _cache_path = os.path.join(_tf.gettempdir(), "learned_addr_map.json")
    learned_map: dict = {}
    if os.path.exists(_cache_path):
        try:
            with open(_cache_path, 'r', encoding='utf-8') as _f:
                learned_map = _jr.load(_f)
        except Exception:
            learned_map = {}

    if not learned_map:
        learned_map = await asyncio.to_thread(_learn_addr_map_from_cert_db)
        if not learned_map:
            logger.info("learned_addr_map: cert DB 없음 — 빌드 시작")
            await asyncio.to_thread(_cert_cache_load)
            learned_map = await asyncio.to_thread(_learn_addr_map_from_cert_db)
        if learned_map:
            try:
                with open(_cache_path, 'w', encoding='utf-8') as _f:
                    _jr.dump(learned_map, _f, ensure_ascii=False)
            except Exception:
                pass
    return learned_map


def _remap_divisions_sync(year: int, learned_map: dict, dry_run: bool = False) -> dict:
    """동기: inspection_targets / inspection_schedules 재매핑 + skt본부 정규화."""
    conn = sqlite3.connect(_INSP_DB, timeout=120)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            'SELECT id, 허가번호, 도로명주소, 설치장소, access담당, 품질개선팀, skt본부 '
            'FROM inspection_targets WHERE year=?',
            (year,)
        ).fetchall()

        total = len(rows)
        changed = []

        for r in rows:
            old_access = r['access담당'] or ''
            old_team = r['품질개선팀'] or ''
            old_skt = r['skt본부'] or ''

            # 1) 주소 기반으로 access/team 재계산
            addr = (r['도로명주소'] or '').strip() or (r['설치장소'] or '').strip()
            new_access = old_access
            new_team = old_team
            if addr:
                inferred_access, inferred_team = _hdqt_from_addr(addr, learned_map=learned_map)
                if inferred_access:
                    new_access = inferred_access
                if inferred_team:
                    new_team = inferred_team

            # 2) skt본부 정규화 (유효값이 아니면 access담당으로 유추)
            new_skt = _normalize_skt_hdqt(old_skt, access=new_access)

            # 변경사항 있으면 기록
            if (new_access != old_access
                or (new_team and new_team != old_team)
                or new_skt != old_skt):
                changed.append({
                    'id': r['id'],
                    '허가번호': r['허가번호'],
                    'before_access': old_access,
                    'after_access': new_access,
                    'before_team': old_team,
                    'after_team': new_team or old_team,
                    'before_skt': old_skt,
                    'after_skt': new_skt,
                })

        if not dry_run and changed:
            for c in changed:
                conn.execute(
                    'UPDATE inspection_targets SET access담당=?, 품질개선팀=?, skt본부=? WHERE id=?',
                    (c['after_access'], c['after_team'], c['after_skt'], c['id'])
                )
            for c in changed:
                conn.execute(
                    'UPDATE inspection_schedules SET access담당=?, 품질개선팀=?, skt본부=? '
                    'WHERE year=? AND 허가번호=?',
                    (c['after_access'], c['after_team'], c['after_skt'], year, c['허가번호'])
                )
            conn.commit()

        return {'total': total, 'changed_count': len(changed), 'samples': changed[:20]}
    finally:
        conn.close()


@app.post("/inspection/remap-divisions")
async def inspection_remap_divisions(request: Request, year: int, dry_run: bool = True):
    """도로명주소 기반으로 inspection_targets의 access담당/품질개선팀을 재매핑.

    - dry_run=True: 변경 예정 건수만 리포트 (실제 UPDATE 안 함)
    - dry_run=False: 실제 UPDATE 실행 (inspection_schedules도 함께 동기화)
    - admin 전용
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role != "admin":
        raise HTTPException(403, "최고관리자만 가능")
    if not os.path.exists(_INSP_DB):
        raise HTTPException(400, "DB 없음")

    learned_map = await _load_learned_addr_map_async()
    logger.info(f"remap-divisions: learned_map {len(learned_map)}개 키워드 학습됨")

    if not learned_map:
        raise HTTPException(500, "주소→팀 학습 맵 생성 실패 (cert DB 확인 필요)")

    result = await asyncio.to_thread(_remap_divisions_sync, year, learned_map, dry_run)
    return {
        'success': True,
        'dry_run': dry_run,
        'year': year,
        **result,
    }


@app.post("/inspection/geocode-targets")
async def inspection_geocode_targets(request: Request, year: int):
    """기존 inspection_targets의 위경도를 Kakao 지오코딩으로 채움 (관리자 1회성).
    최적화: 주소 중복 제거 + 10개 동시 요청 → 순차 대비 ~20x 빠름.
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")
    if not os.path.exists(_INSP_DB):
        raise HTTPException(400, "DB 없음")

    KAKAO_KEY = "cb3f4b95ada5f92fc3924b9685aec16b"
    CONCURRENCY = 10  # Kakao 10 req/s 제한

    # 1. 좌표 없는 항목 조회
    def _fetch_rows():
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        rows = conn.execute(
            'SELECT id, 도로명주소, 설치장소 FROM inspection_targets '
            'WHERE year=? AND (위도 IS NULL OR 위도=0)', (year,)).fetchall()
        conn.close()
        return rows

    rows = await asyncio.to_thread(_fetch_rows)
    if not rows:
        return {"success": True, "total": 0, "updated": 0}

    total = len(rows)

    # 2. 주소 중복 제거: {주소: [id, ...]}
    addr_map: dict = {}
    no_addr: list = []
    for rid, road_addr, install_addr in rows:
        addr = (road_addr or '').strip() or (install_addr or '').strip()
        if not addr:
            no_addr.append(rid)
            continue
        addr_map.setdefault(addr, []).append(rid)

    unique_addrs = list(addr_map.keys())
    logger.info(f"geocode-targets: {total}건 중 고유 주소 {len(unique_addrs)}개 (year={year})")

    # 3. requests + ThreadPoolExecutor로 동시 10개 처리 (aiohttp 불필요)
    import requests as _req
    from concurrent.futures import ThreadPoolExecutor, as_completed

    def _clean_addr(addr: str) -> list[str]:
        """주소 후보 목록 반환 (원본 → 전처리 순)."""
        import re
        candidates = [addr]
        # 괄호 제거: "OO동 123(건물명)" → "OO동 123"
        no_paren = re.sub(r'[\(\（][^\)\）]*[\)\）]', '', addr).strip()
        if no_paren != addr:
            candidates.append(no_paren)
        # 쉼표 이후 제거: "화합로 1829-14, (율정동)" → "화합로 1829-14"
        no_comma = re.split(r',', no_paren)[0].strip()
        if no_comma != no_paren:
            candidates.append(no_comma)
        # "번지" 제거: "갈전리 932번지 상록수아파트" → "갈전리 932 상록수아파트" → 이후 suffix도 제거
        no_bunji = re.sub(r'번지', '', no_comma).strip()
        if no_bunji != no_comma:
            candidates.append(no_bunji)
        else:
            no_bunji = no_comma
        # 숫자 뒤 부가설명 제거 (나대지/인근/지하/옥상/동/PIT/건물명 등)
        no_suffix = re.sub(r'(\d[\d\-]*)\s+[^\d].*$', r'\1', no_bunji).strip()
        if no_suffix != no_bunji and len(no_suffix) > 5:
            candidates.append(no_suffix)
        # 중복 제거 (순서 유지)
        seen = set()
        result = []
        for c in candidates:
            if c and c not in seen:
                seen.add(c)
                result.append(c)
        return result

    VWORLD_KEY = '60301A2D-7EA7-3C05-9B4D-4BC523408605'

    def _call_kakao_addr(query: str):
        try:
            r = _req.get(
                'https://dapi.kakao.com/v2/local/search/address.json',
                params={'query': query, 'size': 1},
                headers={'Authorization': f'KakaoAK {KAKAO_KEY}'},
                timeout=5,
            )
            if r.status_code == 200:
                docs = r.json().get('documents', [])
                if docs:
                    x, y = float(docs[0].get('x', 0)), float(docs[0].get('y', 0))
                    if x and y:
                        return (y, x)
        except Exception:
            pass
        return None

    def _call_kakao_keyword(query: str):
        try:
            r = _req.get(
                'https://dapi.kakao.com/v2/local/search/keyword.json',
                params={'query': query, 'size': 1},
                headers={'Authorization': f'KakaoAK {KAKAO_KEY}'},
                timeout=5,
            )
            if r.status_code == 200:
                docs = r.json().get('documents', [])
                if docs:
                    x, y = float(docs[0].get('x', 0)), float(docs[0].get('y', 0))
                    if x and y:
                        return (y, x)
        except Exception:
            pass
        return None

    def _call_vworld(query: str):
        try:
            r = _req.get(
                'https://api.vworld.kr/req/address',
                params={
                    'service': 'address',
                    'request': 'getcoord',
                    'version': '2.0',
                    'crs': 'epsg:4326',
                    'address': query,
                    'refine': 'true',
                    'simple': 'false',
                    'format': 'json',
                    'type': 'both',
                    'key': VWORLD_KEY,
                },
                timeout=5,
            )
            if r.status_code == 200:
                body = r.json().get('response', {})
                if body.get('status') == 'OK':
                    pt = body.get('result', {}).get('point', {})
                    x, y = float(pt.get('x', 0)), float(pt.get('y', 0))
                    if x and y:
                        return (y, x)
        except Exception:
            pass
        return None

    NAVER_CLIENT_ID = 'x0a4aeu0l5'
    NAVER_CLIENT_SECRET = 't0yDP6Lbti6Ruplw5wfrYKwkPQS3fI806bRVzkBi'

    def _call_naver(query: str):
        try:
            r = _req.get(
                'https://maps.apigw.ntruss.com/map-geocode/v2/geocode',
                params={'query': query},
                headers={
                    'X-NCP-APIGW-API-KEY-ID': NAVER_CLIENT_ID,
                    'X-NCP-APIGW-API-KEY': NAVER_CLIENT_SECRET,
                },
                timeout=5,
            )
            if r.status_code == 200:
                addresses = r.json().get('addresses', [])
                if addresses:
                    x = float(addresses[0].get('x', 0))
                    y = float(addresses[0].get('y', 0))
                    if x and y:
                        return (y, x)
        except Exception:
            pass
        return None

    def _geocode_one(addr: str):
        try:
            candidates = _clean_addr(addr)
            # 1단계: 카카오 주소검색
            for candidate in candidates:
                result = _call_kakao_addr(candidate)
                if result:
                    return addr, result
            # 2단계: 카카오 키워드검색
            for candidate in candidates:
                result = _call_kakao_keyword(candidate)
                if result:
                    return addr, result
            # 3단계: Vworld 주소검색
            for candidate in candidates:
                result = _call_vworld(candidate)
                if result:
                    return addr, result
            # 4단계: 네이버 지오코딩
            for candidate in candidates:
                result = _call_naver(candidate)
                if result:
                    return addr, result
            logger.warning(f"[geocode-targets] 주소 매칭 없음: {addr}")
        except Exception as e:
            logger.warning(f"[geocode-targets] 요청 실패: {addr} — {e}")
        return addr, None

    # 4. 배치(500개)씩 → ThreadPoolExecutor(10) → OOM 방지
    BATCH = 500
    updated = 0

    def _process_batch(batch_addrs):
        results = []
        with ThreadPoolExecutor(max_workers=CONCURRENCY) as pool:
            futures = {pool.submit(_geocode_one, a): a for a in batch_addrs}
            for fut in as_completed(futures):
                results.append(fut.result())
        upd = []
        for addr, coord in results:
            if coord:
                for rid in addr_map.get(addr, []):
                    upd.append((coord[0], coord[1], rid))
        if upd:
            c = sqlite3.connect(_INSP_DB, timeout=60)
            c.executemany('UPDATE inspection_targets SET 위도=?, 경도=? WHERE id=?', upd)
            c.commit(); c.close()
        return len(upd)

    for i in range(0, len(unique_addrs), BATCH):
        batch = unique_addrs[i:i + BATCH]
        batch_updated = await asyncio.to_thread(_process_batch, batch)
        updated += batch_updated
        logger.info(f"geocode-targets: {min(i+BATCH, len(unique_addrs))}/{len(unique_addrs)} 주소 처리 ({updated}건 업데이트)")

    logger.info(f"geocode-targets 완료: {updated}/{total}건 (year={year})")
    return {"success": True, "total": total, "unique_addrs": len(unique_addrs), "updated": updated}


class InspectionDataReq(BaseModel):
    year: int
    sheet: str = "all"
    filters: dict = {}   # {col: [val, ...]}
    search: str = ""     # 호출명칭/허가번호 검색
    addr: str = ""       # 도로명주소/설치장소 검색
    page: int = 1
    page_size: int = 100
    schedule_yn: str = ""    # 일정등록 여부 필터 (Y/N)
    schedule_week: str = ""  # 수검예정주차 필터
    workflow_status: str = ""  # Phase 5: 워크플로우 상태 필터 (서버측, '미배정'은 schedule 미존재)
    needs_recheck: str = ""    # Phase 5: '1' = 재점검 필요만
    overdue_only: str = ""     # Phase 5: '1' = SLA 임계점 초과 건만

def _build_insp_where(year, sheet, filters, search, addr, schedule_yn="", schedule_week="",
                     workflow_status="", needs_recheck="", overdue_only=""):
    """inspection_data / export 공통 WHERE 절 빌더."""
    ALLOWED_COLS = {'분기','국종군','부서','kca검토결과','시기조정','skt본부','access담당','품질개선팀','허가상태'}
    where = ["year=?"]
    params: list = [year]
    if sheet != "all": where.append("sheet=?"); params.append(sheet)
    for col, vals in filters.items():
        if col not in ALLOWED_COLS or not vals: continue
        ph = ",".join("?" * len(vals))
        where.append(f'"{col}" IN ({ph})')
        params.extend(vals)
    s = search.strip()
    a = addr.strip()
    # 복수검색: 쉼표/공백으로 분리 → 복수 키워드는 OR 조건
    import re as _re_search
    keywords = [k.strip() for k in _re_search.split(r'[,\s]+', s) if k.strip()] if s else []
    addr_keywords = [k.strip() for k in _re_search.split(r'[,\s]+', a) if k.strip()] if a else []
    _hn_re2 = _re_search.compile(r'^[\d\-]{15,19}$')
    if keywords and addr_keywords and keywords == addr_keywords:
        # 모든 키워드가 허가번호 형식이면 IN 절로 최적화
        if all(_hn_re2.match(kw) for kw in keywords) and len(keywords) > 1:
            clean_nos = [kw.replace('-', '') for kw in keywords]
            ph = ','.join('?' * len(clean_nos))
            where.append(f"REPLACE(허가번호,'-','') IN ({ph})")
            params.extend(clean_nos)
        else:
            or_parts = []
            for kw in keywords:
                kw_clean = kw.replace('-', '')
                or_parts.append(
                    "(REPLACE(호출명칭,'-','') LIKE ? OR REPLACE(허가번호,'-','') LIKE ? OR REPLACE(도로명주소,'-','') LIKE ? OR REPLACE(설치장소,'-','') LIKE ?)"
                )
                pat = f'%{kw_clean}%'
                params.extend([pat, pat, pat, pat])
            if or_parts:
                where.append(f"({' OR '.join(or_parts)})")
    else:
        if keywords:
            if all(_hn_re2.match(kw) for kw in keywords) and len(keywords) > 1:
                clean_nos = [kw.replace('-', '') for kw in keywords]
                ph = ','.join('?' * len(clean_nos))
                where.append(f"REPLACE(허가번호,'-','') IN ({ph})")
                params.extend(clean_nos)
            else:
                or_parts = []
                for kw in keywords:
                    kw_clean = kw.replace('-', '')
                    or_parts.append("(REPLACE(호출명칭,'-','') LIKE ? OR REPLACE(허가번호,'-','') LIKE ?)")
                    pat = f'%{kw_clean}%'
                    params.extend([pat, pat])
                where.append(f"({' OR '.join(or_parts)})")
        if addr_keywords:
            or_parts = []
            for kw in addr_keywords:
                kw_clean = kw.replace('-', '')
                or_parts.append("(REPLACE(도로명주소,'-','') LIKE ? OR REPLACE(설치장소,'-','') LIKE ?)")
                pat = f'%{kw_clean}%'
                params.extend([pat, pat])
            where.append(f"({' OR '.join(or_parts)})")
            pat = f'%{kw_clean}%'
            params.extend([pat, pat])
    if schedule_yn == 'Y':
        where.append('허가번호 IN (SELECT 허가번호 FROM inspection_schedules WHERE year=?)')
        params.append(year)
    elif schedule_yn == 'N':
        where.append('허가번호 NOT IN (SELECT 허가번호 FROM inspection_schedules WHERE year=?)')
        params.append(year)
    if schedule_week:
        where.append("REPLACE(허가번호,'-','') IN (SELECT REPLACE(허가번호,'-','') FROM inspection_schedules WHERE year=? AND TRIM(수검예정주차)=TRIM(?))")
        params.extend([year, schedule_week])
    # Phase 5: 워크플로우 상태 필터 (대시보드 카드 → 일정 화면 점프용)
    if workflow_status:
        if workflow_status == '미배정':
            # 일정 미등록 — schedule이 없는 건만
            where.append("REPLACE(허가번호,'-','') NOT IN (SELECT REPLACE(허가번호,'-','') FROM inspection_schedules WHERE year=?)")
            params.append(year)
        else:
            where.append("REPLACE(허가번호,'-','') IN (SELECT REPLACE(허가번호,'-','') FROM inspection_schedules WHERE year=? AND workflow_status=?)")
            params.extend([year, workflow_status])
    if needs_recheck == '1':
        where.append("REPLACE(허가번호,'-','') IN (SELECT REPLACE(허가번호,'-','') FROM inspection_results WHERE year=? AND needs_recheck='1')")
        params.append(year)
    # Phase 5: SLA 임계점 초과 건만 (단계별 임계 일수 _SLA_DAYS와 동일 로직)
    # status_updated_at 으로부터 임계점 일수 초과한 건
    if overdue_only == '1':
        # SLA 단계별 임계점 (코드의 _SLA_DAYS와 동기화)
        # SQLite julianday()를 사용해 status_updated_at 으로부터 경과 일수 계산
        sla_pairs = [
            ('PRE_CHECK', 5),
            ('CHANGE_FILING', 3),
            ('RE_CHECK', 7),
            ('REPORT_ISSUED', 3),
            ('SUBMITTED', 14),
        ]
        sub_conditions = []
        for st, days in sla_pairs:
            sub_conditions.append(
                f"(workflow_status='{st}' AND status_updated_at != '' "
                f"AND CAST((julianday('now') - julianday(status_updated_at)) AS INTEGER) > {days})"
            )
        where.append(
            "REPLACE(허가번호,'-','') IN (SELECT REPLACE(허가번호,'-','') "
            "FROM inspection_schedules WHERE year=? AND (" +
            " OR ".join(sub_conditions) + "))"
        )
        params.append(year)
    return " AND ".join(where), params

@app.post("/inspection/data")
async def inspection_data(request: Request, req: InspectionDataReq):
    """필터 적용 데이터 조회 (페이지네이션)."""
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB): return {"items": [], "total": 0}
    # Phase 5 디버그: 워크플로우/재점검/지연 필터 적용 시 로그
    if req.workflow_status or req.needs_recheck or req.overdue_only:
        logger.info(
            f"[inspection_data] workflow_status='{req.workflow_status}', "
            f"needs_recheck='{req.needs_recheck}', overdue_only='{req.overdue_only}', "
            f"search='{req.search}', year={req.year}, page={req.page}"
        )
    where_sql, params = _build_insp_where(
        req.year, req.sheet, req.filters, req.search, req.addr,
        req.schedule_yn, req.schedule_week,
        req.workflow_status, req.needs_recheck, req.overdue_only)
    def _read():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        total = c.execute(f'SELECT COUNT(*) FROM inspection_targets WHERE {where_sql}', params).fetchone()[0]
        offset = (req.page - 1) * req.page_size
        rows = c.execute(
            f'''SELECT t.*, s.수검예정주차,
                    COALESCE(r.status, irr.합불여부) AS 검사결과
                FROM (SELECT * FROM inspection_targets WHERE {where_sql} ORDER BY id LIMIT ? OFFSET ?) t
                LEFT JOIN inspection_schedules s ON s.year = t.year AND s.허가번호 = t.허가번호
                LEFT JOIN inspection_results r ON r.year = t.year AND r.허가번호 = t.허가번호
                LEFT JOIN (
                    SELECT year, REPLACE(허가번호,'-','') AS 허가번호, MIN(합불여부) AS 합불여부
                    FROM inspection_results_raw
                    WHERE 합불여부 != ''
                    GROUP BY year, REPLACE(허가번호,'-','')
                ) irr ON irr.year = t.year AND irr.허가번호 = REPLACE(t.허가번호,'-','')''',
            params + [req.page_size, offset]
        ).fetchall()
        c.close()

        # Phase 5 성능: 현재 페이지의 통시(zpcode)만 IN 절로 lookup → 전체 GROUP BY 풀스캔 제거
        items = [dict(r) for r in rows]

        # 통시/공대 보완: 새 Excel에 컬럼 없는 경우 cert_cache.db에서 허가번호+호출명칭으로 채움
        # _cert_cache_load() 호출 금지 — S3 재빌드가 블로킹되어 요청 실패 유발
        _cert_db = _cert_cache_db_path or os.path.join(_tempfile.gettempdir(), "cert_cache.db")
        if _cert_db and os.path.exists(_cert_db):
            try:
                _missing = [(i, str(it.get('허가번호') or '').strip(),
                               str(it.get('호출명칭') or '').strip())
                            for i, it in enumerate(items)
                            if not (it.get('통시') or '').strip()]
                if _missing:
                    _pairs = list({(wino, wina) for _, wino, wina in _missing if wino or wina})
                    # 허가번호 대시 제거 후 정규화 → 단일 IN 쿼리 (100개 개별 쿼리 → 1개 일괄 쿼리)
                    _wino_norms = list({w.replace('-', '').strip() for w, _ in _pairs if w})
                    _norm_result: dict = {}  # (wino_norm, wina_norm) → (zpcode, zpkcode)
                    _hit = 0
                    if _wino_norms:
                        _cc = sqlite3.connect(_cert_db, timeout=10)
                        _cc.row_factory = sqlite3.Row
                        _ph = ','.join('?' * len(_wino_norms))
                        for _row in _cc.execute(
                            f"SELECT REPLACE(TRIM(zpwino),'-','') AS wino_n, TRIM(zpwina) AS wina_n, zpcode, zpkcode "
                            f"FROM cert WHERE REPLACE(TRIM(zpwino),'-','') IN ({_ph})",
                            _wino_norms
                        ):
                            _nk = (_row['wino_n'], _row['wina_n'])
                            if _nk not in _norm_result:
                                _norm_result[_nk] = (_row['zpcode'] or '', _row['zpkcode'] or '')
                                _hit += 1
                        _cc.close()
                    logger.info(f"[통시/공대 보완] missing={len(_missing)} pairs={len(_pairs)} hit={_hit}")
                    for _i, _wino, _wina in _missing:
                        _v = _norm_result.get((_wino.replace('-', '').strip(), _wina.strip()))
                        if _v:
                            items[_i]['통시'] = _v[0]
                            items[_i]['공대'] = _v[1]
            except Exception as _e:
                logger.warning(f"[통시/공대 보완] cert lookup 실패: {_e}")

        zpcodes = list({(it.get('통시') or '').strip() for it in items if (it.get('통시') or '').strip()})
        zpprac1_map: dict = {}
        if zpcodes:
            cert_db = _cert_cache_db_path or os.path.join(_tempfile.gettempdir(), "cert_cache.db")
            if cert_db and os.path.exists(cert_db):
                try:
                    cc = sqlite3.connect(cert_db, timeout=10)
                    cc.row_factory = sqlite3.Row
                    ph = ','.join('?' * len(zpcodes))
                    for row in cc.execute(
                        f"SELECT TRIM(zpcode) AS zpcode, zpprac1 FROM cert "
                        f"WHERE TRIM(zpcode) IN ({ph})",
                        zpcodes
                    ):
                        if row['zpcode']:
                            zpprac1_map[row['zpcode']] = row['zpprac1'] or ''
                    cc.close()
                    logger.info(f"[zpprac1] zpcodes={len(zpcodes)} hit={len(zpprac1_map)}")
                except Exception as _ze:
                    logger.warning(f"[zpprac1] lookup 실패: {_ze}")
        for it in items:
            tongsi = (it.get('통시') or '').strip()
            it['zpprac1'] = zpprac1_map.get(tongsi, '')
        return total, items
    total, items = await asyncio.to_thread(_read)
    return {"items": items, "total": total, "page": req.page, "page_size": req.page_size}

class InspectionExportReq(BaseModel):
    year: int
    sheet: str = "all"
    filters: dict = {}
    search: str = ""
    addr: str = ""

@app.post("/inspection/export-xlsx")
async def inspection_export_xlsx(request: Request, req: InspectionExportReq):
    """필터 적용 전체 데이터 → xlsx (수검대상 + 수검일정 + 수검결과 3시트)."""
    await _verify_auth(request)
    if not HAS_OPENPYXL:
        raise HTTPException(503, "openpyxl 미설치")
    if not os.path.exists(_INSP_DB):
        raise HTTPException(404, "데이터 없음")
    where_sql, params = _build_insp_where(req.year, req.sheet, req.filters, req.search, req.addr)

    TARGET_HEADERS = ['허가번호','호출명칭','국종군','부서','분기','연도주기','검사주기','허가상태',
                      '설치장소','도로명주소','장치수','통시','공대','kca검토결과','시기조정',
                      '기준연도','skt본부','access담당','품질개선팀']

    SCHEDULE_HEADERS = ['허가번호','호출명칭','분기','skt본부','access담당','품질개선팀',
                        '수검예정주차','수검시작일','수검종료일','지역',
                        '등록자','등록일시','검사관','조']

    RESULT_HEADERS = ['허가번호','status','검사일','메모','철탑형태',
                      '입력자','입력일시']

    # 수검일정/결과도 수검대상과 동일한 본부/팀 필터 적용 (복수 선택 지원)
    access_list = [v for v in (req.filters or {}).get('access담당', []) if v]
    team_list = [v for v in (req.filters or {}).get('품질개선팀', []) if v]

    def _build():
        import openpyxl
        from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row

        # 수검대상
        target_rows = c.execute(f'SELECT * FROM inspection_targets WHERE {where_sql} ORDER BY id', params).fetchall()

        # 수검일정 (본부/팀 IN 필터)
        sched_where = 'year=?'
        sched_params: list = [req.year]
        if access_list:
            ph = ','.join('?' * len(access_list))
            sched_where += f' AND access담당 IN ({ph})'
            sched_params.extend(access_list)
        if team_list:
            ph = ','.join('?' * len(team_list))
            sched_where += f' AND 품질개선팀 IN ({ph})'
            sched_params.extend(team_list)
        sched_rows = c.execute(
            f'SELECT * FROM inspection_schedules WHERE {sched_where}',
            sched_params).fetchall()

        # 수검결과 (입회자가 직접 입력한 수검결과, targets JOIN으로 본부/팀 IN 필터)
        result_where = 'r.year=?'
        result_params: list = [req.year]
        if access_list:
            ph = ','.join('?' * len(access_list))
            result_where += f' AND t.access담당 IN ({ph})'
            result_params.extend(access_list)
        if team_list:
            ph = ','.join('?' * len(team_list))
            result_where += f' AND t.품질개선팀 IN ({ph})'
            result_params.extend(team_list)
        result_rows = c.execute(
            f'''SELECT r.* FROM inspection_results r
                JOIN inspection_targets t ON r.year = t.year AND r.허가번호 = t.허가번호
                WHERE {result_where}
                ORDER BY r.허가번호''',
            result_params).fetchall()

        c.close()

        wb = openpyxl.Workbook()

        hdr_font = Font(name='Arial', size=10, bold=True, color='FFFFFF')
        hdr_align = Alignment(horizontal='center', vertical='center')
        thin = Border(
            left=Side(style='thin'), right=Side(style='thin'),
            top=Side(style='thin'), bottom=Side(style='thin'))
        data_font = Font(name='Arial', size=10)
        data_align = Alignment(horizontal='center', vertical='center')

        fills = {
            '수검대상': PatternFill('solid', fgColor='E53935'),
            '수검일정': PatternFill('solid', fgColor='1565C0'),
            '수검결과': PatternFill('solid', fgColor='43A047'),
        }

        def _write_sheet(ws, headers, rows, fill):
            ws.append(headers)
            for cell in ws[1]:
                cell.font = hdr_font; cell.fill = fill
                cell.alignment = hdr_align; cell.border = thin
            for row in rows:
                d = dict(row)
                ws.append([d.get(h, '') for h in headers])
            for col in ws.iter_cols(min_row=2, max_row=max(ws.max_row, 2)):
                for cell in col:
                    cell.alignment = data_align; cell.border = thin
                    cell.font = data_font
            for i in range(1, len(headers) + 1):
                ws.column_dimensions[ws.cell(1, i).column_letter].width = 18

        # 시트 1: 수검대상
        ws1 = wb.active
        ws1.title = '수검대상'
        _write_sheet(ws1, TARGET_HEADERS, target_rows, fills['수검대상'])

        # 시트 2: 수검일정
        ws2 = wb.create_sheet('수검일정')
        _write_sheet(ws2, SCHEDULE_HEADERS, sched_rows, fills['수검일정'])

        # 시트 3: 수검결과
        ws3 = wb.create_sheet('수검결과')
        _write_sheet(ws3, RESULT_HEADERS, result_rows, fills['수검결과'])

        buf = io.BytesIO()
        wb.save(buf); buf.seek(0)
        return buf.getvalue()

    data = await asyncio.to_thread(_build)
    fname = f"수검데이터_{req.year}년.xlsx"
    from urllib.parse import quote as _q
    return Response(
        content=data,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{_q(fname)}"}
    )

class InspectionExportAllReq(BaseModel):
    year: int
    access담당: str = ""

@app.post("/inspection/export-all-xlsx")
async def inspection_export_all_xlsx(request: Request, req: InspectionExportAllReq):
    """수검 데이터 통합 Excel (4시트: 대상/일정/결과/주차별실적) — Playground import용."""
    await _verify_auth(request)
    if not HAS_OPENPYXL:
        raise HTTPException(503, "openpyxl 미설치")
    if not os.path.exists(_INSP_DB):
        raise HTTPException(404, "데이터 없음")

    def _build():
        import openpyxl
        from openpyxl.styles import Font, PatternFill, Alignment, Border, Side

        thin = Border(left=Side(style='thin'), right=Side(style='thin'),
                      top=Side(style='thin'), bottom=Side(style='thin'))
        hdr_font = Font(name='Arial', size=10, bold=True, color='FFFFFF')
        hdr_fill = PatternFill('solid', fgColor='E53935')
        hdr_align = Alignment(horizontal='center', vertical='center')
        data_font = Font(name='Arial', size=10)
        data_align = Alignment(horizontal='center', vertical='center')

        c = sqlite3.connect(_INSP_DB, timeout=60)
        c.row_factory = sqlite3.Row

        access_filter = ""
        access_params = (req.year,)
        if req.access담당:
            access_filter = " AND access담당 = ?"
            access_params = (req.year, req.access담당)

        wb = openpyxl.Workbook()

        # ── 시트1: 수검대상 ──
        ws1 = wb.active
        ws1.title = "수검대상"
        h1 = ['허가번호','호출명칭','국종군','부서','분기','연도주기','검사주기','허가상태',
              '설치장소','도로명주소','장치수','통시','공대','kca검토결과','시기조정',
              '기준연도','skt본부','access담당','품질개선팀']
        ws1.append(h1)
        rows = c.execute(
            f'SELECT * FROM inspection_targets WHERE year=?{access_filter} ORDER BY id',
            access_params).fetchall()
        for row in rows:
            d = dict(row)
            ws1.append([d.get(h, '') for h in h1])

        # ── 시트2: 수검일정 ──
        ws2 = wb.create_sheet("수검일정")
        h2 = ['허가번호','호출명칭','분기','skt본부','access담당','품질개선팀',
              '수검예정주차','수검시작일','수검종료일','지역','등록자','등록일시','검사관','조']
        ws2.append(h2)
        rows2 = c.execute(
            f'SELECT * FROM inspection_schedules WHERE year=?{access_filter} ORDER BY rowid',
            access_params).fetchall()
        for row in rows2:
            d = dict(row)
            ws2.append([d.get(h, '') for h in h2])

        # ── 시트3: 수검결과 ──
        ws3 = wb.create_sheet("수검결과")
        h3 = ['허가번호','status','검사일','메모','철탑형태','입력자','입력일시',
              '진행여부','성능서류','불합격내용','불합격상세','공용화대상','간략불합격',
              '기타사항','수검자','시스템','기지국구분','전파진흥원','검사관','주차별']
        ws3.append(h3)
        rows3 = c.execute(
            'SELECT * FROM inspection_results WHERE year=? ORDER BY rowid',
            (req.year,)).fetchall()
        for row in rows3:
            d = dict(row)
            ws3.append([d.get(h, '') for h in h3])

        c.close()

        # 스타일 적용
        for ws in [ws1, ws2, ws3]:
            for cell in ws[1]:
                cell.font = hdr_font
                cell.fill = hdr_fill
                cell.alignment = hdr_align
                cell.border = thin
            for row in ws.iter_rows(min_row=2, max_row=ws.max_row):
                for cell in row:
                    cell.font = data_font
                    cell.alignment = data_align
                    cell.border = thin
            for col in ws.iter_cols(min_row=1, max_row=1):
                ws.column_dimensions[col[0].column_letter].width = 18

        buf = io.BytesIO()
        wb.save(buf)
        buf.seek(0)
        return buf.getvalue()

    data = await asyncio.to_thread(_build)
    fname = f"수검데이터_통합_{req.year}년.xlsx"
    from urllib.parse import quote as _q
    return Response(
        content=data,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{_q(fname)}"}
    )


class InspectionSummaryReq(BaseModel):
    year: int
    sheet: str = "all"
    filters: dict = {}
    search: str = ""
    addr: str = ""
    schedule_yn: str = ""

@app.post("/inspection/summary")
async def inspection_summary(request: Request, req: InspectionSummaryReq):
    """본부×분기 매트릭스 집계."""
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB): return {"matrix": {}}
    where_sql, params = _build_insp_where(req.year, req.sheet, req.filters, req.search, req.addr, req.schedule_yn)
    def _read():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        rows = c.execute(
            f'SELECT access담당, 품질개선팀, 분기, COUNT(*) as cnt FROM inspection_targets WHERE {where_sql} GROUP BY access담당, 품질개선팀, 분기',
            params).fetchall()
        c.close()
        return rows
    rows = await asyncio.to_thread(_read)
    # matrix: { 본부: { 팀: { 분기: count } } }
    matrix: dict = {}
    quarters = set()
    for r in rows:
        hdqt = r['access담당'] or '미배정'
        team = r['품질개선팀'] or '미배정'
        q = r['분기'] or '-'
        quarters.add(q)
        if hdqt not in matrix: matrix[hdqt] = {}
        if team not in matrix[hdqt]: matrix[hdqt][team] = {}
        matrix[hdqt][team][q] = r['cnt']
    return {"matrix": matrix, "quarters": sorted(quarters)}

@app.get("/inspection/detail")
async def inspection_detail(request: Request, year: int, 허가번호: str):
    """행 클릭 상세 정보 (KCA + DS + 일정 + 결과)."""
    await _verify_auth(request)
    import sqlite3

    # 1. inspection.db 기본 정보
    target = None
    if os.path.exists(_INSP_DB):
        conn = sqlite3.connect(_INSP_DB, timeout=60); conn.row_factory = sqlite3.Row
        row = conn.execute('SELECT * FROM inspection_targets WHERE year=? AND 허가번호=? LIMIT 1',
                           (year, 허가번호)).fetchone()
        conn.close()
        if row: target = dict(row)

    # 2. ds_detail.db 기술 정보
    ds_info: dict = {"일반사항": None, "장치": [], "안테나": []}
    if os.path.exists(_DS_DETAIL_DB):
        conn = sqlite3.connect(_DS_DETAIL_DB); conn.row_factory = sqlite3.Row
        row = conn.execute('SELECT * FROM ds_일반사항 WHERE 허가번호=?', (허가번호,)).fetchone()
        if row: ds_info["일반사항"] = dict(row)
        장치rows = conn.execute('SELECT * FROM ds_장치 WHERE 허가번호=?', (허가번호,)).fetchall()
        ds_info["장치"] = [dict(r) for r in 장치rows]
        안테나rows = conn.execute('SELECT * FROM ds_안테나 WHERE 허가번호=?', (허가번호,)).fetchall()
        ds_info["안테나"] = [dict(r) for r in 안테나rows]
        conn.close()

    # 3. SQLite 일정/결과
    pk = f"{year}#{허가번호}"
    schedule = None
    result = None
    if os.path.exists(_INSP_DB):
        def _read_sched_result():
            c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
            s = c.execute('SELECT * FROM inspection_schedules WHERE pk=?', (pk,)).fetchone()
            r = c.execute('SELECT * FROM inspection_results WHERE pk=?', (pk,)).fetchone()
            c.close()
            return (dict(s) if s else None, dict(r) if r else None)
        schedule, result = await asyncio.to_thread(_read_sched_result)
        if result and result.get('사진S3키'):
            import json as _j
            try: result['사진S3키'] = _j.loads(result['사진S3키'])
            except Exception: result['사진S3키'] = []

    # 4. callname_matching_cache에서 통합시설명칭 + zpprac1(ERP활용구분) 조회
    callname_list: list = []
    zpprac1_val: str = ''
    if _cert_cache_db_path and os.path.exists(_cert_cache_db_path):
        def _read_zpcname():
            import sqlite3 as _sq
            c = _sq.connect(_cert_cache_db_path); c.row_factory = _sq.Row
            rows = c.execute(
                "SELECT eqp_ser_no, zpcname FROM cert WHERE zpwino=? AND zpcname!=''",
                (허가번호,)
            ).fetchall()
            # zpprac1: zpwino(허가번호) 기준으로 직접 조회
            r2 = c.execute(
                "SELECT zpprac1 FROM cert WHERE zpwino=? AND zpprac1 != '' LIMIT 1",
                (허가번호,)
            ).fetchone()
            prac1 = (r2['zpprac1'] if r2 else '') or ''
            c.close()
            return [{"eqp_ser_no": r["eqp_ser_no"], "zpcname": r["zpcname"]} for r in rows], prac1
        callname_list, zpprac1_val = await asyncio.to_thread(_read_zpcname)
    if target is not None:
        target['zpprac1'] = zpprac1_val

    # 5. ds_변경이력 조회
    ds_changes: list = []
    if os.path.exists(_DS_DETAIL_DB):
        def _read_changes():
            c = sqlite3.connect(_DS_DETAIL_DB, timeout=10); c.row_factory = sqlite3.Row
            try:
                rows = c.execute(
                    'SELECT * FROM ds_변경이력 WHERE 허가번호=? ORDER BY 변경일자 DESC, id DESC',
                    (허가번호.replace('-', ''),)
                ).fetchall()
                return [dict(r) for r in rows]
            except Exception:
                return []
            finally:
                c.close()
        ds_changes = await asyncio.to_thread(_read_changes)

    return {"target": target, "ds": ds_info, "schedule": schedule, "result": result, "callname_list": callname_list, "ds_changes": ds_changes}

@app.patch("/inspection/target-review")
async def inspection_target_review(request: Request, year: int, 허가번호: str, 시기조정: str = ""):
    """수검 검토 결과(시기조정) 업데이트."""
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB):
        raise HTTPException(404, "수검 데이터 없음")
    def _update():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        c.execute(
            "UPDATE inspection_targets SET 시기조정=? WHERE year=? AND 허가번호=?",
            (시기조정, year, 허가번호)
        )
        c.commit(); c.close()
    await asyncio.to_thread(_update)
    return {"ok": True}


def _geocode_target_sync(year: int, 허가번호: str):
    """일정 등록된 국소 1건 지오코딩 (좌표 이미 있으면 스킵 — 캐시 역할).
    inspection_targets.위도/경도 업데이트."""
    import requests as _req
    try:
        conn = sqlite3.connect(_INSP_DB, timeout=30)
        row = conn.execute(
            'SELECT id, 도로명주소, 설치장소, 위도 FROM inspection_targets WHERE year=? AND 허가번호=? LIMIT 1',
            (year, 허가번호)
        ).fetchone()
        if not row:
            conn.close(); return
        rid, road_addr, install_addr, lat = row
        # 이미 좌표 있으면 스킵 (캐시 히트)
        if lat and lat != 0:
            conn.close(); return
        addr = (road_addr or '').strip() or (install_addr or '').strip()
        if not addr:
            conn.close(); return
        r = _req.get(
            'https://dapi.kakao.com/v2/local/search/address.json',
            params={'query': addr, 'size': 1},
            headers={'Authorization': 'KakaoAK cb3f4b95ada5f92fc3924b9685aec16b'},
            timeout=5,
        )
        if r.status_code == 200:
            docs = r.json().get('documents', [])
            if docs:
                x = float(docs[0].get('x', 0))
                y = float(docs[0].get('y', 0))
                if x and y:
                    conn.execute('UPDATE inspection_targets SET 위도=?, 경도=? WHERE id=?', (y, x, rid))
                    conn.commit()
                    logger.debug(f"지오코딩 완료: {허가번호} ({y:.4f}, {x:.4f})")
        conn.close()
    except Exception as e:
        logger.debug(f"지오코딩 실패 (non-fatal): {허가번호} — {e}")


# ============================================================
# 워크플로우 상태 머신 (Phase 1)
# ============================================================

# 상태 정의
WF_REGISTERED = "REGISTERED"
WF_PRE_CHECK = "PRE_CHECK"
WF_PRE_CHECK_DONE = "PRE_CHECK_DONE"
WF_CHANGE_FILING = "CHANGE_FILING"
WF_RE_CHECK = "RE_CHECK"
WF_REPORT_ISSUED = "REPORT_ISSUED"
WF_SUBMITTED = "SUBMITTED"
WF_INSPECTED = "INSPECTED"

WF_VALID = {WF_REGISTERED, WF_PRE_CHECK, WF_PRE_CHECK_DONE, WF_CHANGE_FILING,
            WF_RE_CHECK, WF_REPORT_ISSUED, WF_SUBMITTED, WF_INSPECTED}

# 허용 전환 (from -> to 집합). superadmin은 어디든 가능.
_WF_TRANSITIONS = {
    None: {WF_REGISTERED},                       # 신규 등록
    WF_REGISTERED: {WF_PRE_CHECK, WF_REPORT_ISSUED},  # 사전점검 의뢰 또는 사전점검 스킵 후 즉시 발급
    WF_PRE_CHECK: {WF_PRE_CHECK_DONE, WF_CHANGE_FILING},
    WF_CHANGE_FILING: {WF_RE_CHECK},
    WF_RE_CHECK: {WF_PRE_CHECK_DONE},            # 시스템 자동
    WF_PRE_CHECK_DONE: {WF_REPORT_ISSUED},
    WF_REPORT_ISSUED: {WF_SUBMITTED},
    WF_SUBMITTED: {WF_INSPECTED},
    WF_INSPECTED: set(),
}


def _wf_can_transition(from_status: str | None, to_status: str, role: str) -> bool:
    """워크플로우 상태 전환 허용 여부."""
    if to_status not in WF_VALID:
        return False
    if role == "admin":  # superadmin은 강제 롤백 포함 모든 전환 가능
        return True
    allowed = _WF_TRANSITIONS.get(from_status, set())
    return to_status in allowed


def _wf_record_log_sync(conn, schedule_pk: str, from_status: str | None,
                       to_status: str, changed_by: str, memo: str = ""):
    """상태 전환 이력 기록 + Phase 5 알림 자동 생성.

    notify=False로 호출하고 싶으면 _wf_record_log_silent_sync()를 사용 (현재 없음).
    """
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        'INSERT INTO inspection_status_log(schedule_pk, from_status, to_status, '
        'changed_by, changed_at, memo) VALUES (?,?,?,?,?,?)',
        (schedule_pk, from_status, to_status, changed_by, now, memo))
    # 알림 자동 생성 (실패해도 트랜잭션은 영향받지 않게 별도 try)
    try:
        _wf_notify_transition_sync(conn, schedule_pk, from_status, to_status, changed_by)
    except Exception as e:
        logger.error(f"알림 생성 실패 (schedule={schedule_pk}, to={to_status}): {e}")


# ── 알림 (Phase 5) ────────────────────────────────────────────

# SLA 임계점 (일) — 단계별 지연 기준
_SLA_DAYS = {
    WF_PRE_CHECK: 5,        # 사전점검 의뢰 후 5일 초과면 지연
    WF_CHANGE_FILING: 3,    # 변경개설 작성 후 3일 초과면 지연
    WF_RE_CHECK: 7,         # 부분 DS 회신 대기 7일 초과면 지연
    WF_REPORT_ISSUED: 3,    # 검사내역서 발급 후 3일 내 접수번호 미입력이면 지연
    WF_SUBMITTED: 14,       # 접수 완료 후 14일 내 수검 미완료면 지연
}


def _create_notification_sync(conn, user_id: str, sub_type: str, message: str,
                              schedule_pk: str = "", meta: dict | None = None,
                              title: str = ""):
    """워크플로우 알림 1건 생성.

    기존 community.db의 notifications 테이블에 통합 저장하여 종 아이콘에서 함께 노출.
    - type='workflow' 고정, sub_type에 PRE_CHECK_REQUESTED 등 세부 타입 기록
    - related_type='inspection', related_pk=schedule_pk (related_id는 0 유지)

    호출자(_wf_record_log_sync)는 inspection.db conn을 들고 있으나, 알림은 community.db에
    별도 연결로 INSERT (트랜잭션은 분리되지만 워크플로우 로그 기록과 알림 생성이 한쪽만
    성공해도 안전).
    """
    if not user_id:
        return
    import json as _j
    now = datetime.now(timezone.utc).isoformat()
    meta_json = _j.dumps(meta, ensure_ascii=False) if meta else ''
    body = message
    label = title or sub_type
    try:
        c2 = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        c2.execute(
            'INSERT INTO notifications(user_empno, type, title, body, '
            'related_type, related_id, related_pk, sub_type, is_read, created_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)',
            (user_id, 'workflow', label, body,
             'inspection', 0, schedule_pk, sub_type, now))
        # meta는 별도 필드가 없어 body 끝에 JSON 형태로 부착하진 않고 sub_type만 남김
        _ = meta_json   # 현재는 사용 안 함 (필요 시 별도 컬럼 추가)
        c2.commit(); c2.close()
    except Exception as e:
        logger.error(f"워크플로우 알림 INSERT 실패: {e}")


def _notify_targets_for_sync(access담당: str, 품질개선팀: str, target_team: str) -> list[str]:
    """본부/팀에 해당하는 수신자 사번 목록 (DynamoDB 60초 캐시 사용).

    target_team:
    - 'quality': 일정의 품질개선팀 소속 전원 (member/manager 모두)
                 0명이면 본부 혁신팀(manager) 폴백
    - 'innovation': 일정의 access담당 본부에 속한 manager/admin (= 혁신팀)
                    region에서 'Access담당' 제거 후 매칭

    반환: 사번 리스트 (중복 제거됨)
    """
    if not access담당:
        return []
    try:
        all_users = _list_all_users_sync()
    except Exception as e:
        logger.error(f"수신자 조회 실패 (전체 사용자 캐시): {e}")
        return []

    def _norm_region(r: str | None) -> str:
        return (r or '').replace('Access담당', '').strip()

    targets: set[str] = set()
    if target_team == 'quality' and 품질개선팀:
        for u in all_users:
            if u.get('is_dormant'):
                continue
            if _norm_region(u.get('region')) != access담당:
                continue
            if (u.get('team') or '').strip() != 품질개선팀:
                continue
            uid = (u.get('empno') or '').strip()
            if uid:
                targets.add(uid)
        # 폴백: 0명이면 본부 혁신팀
        if not targets:
            return _notify_targets_for_sync(access담당, 품질개선팀, 'innovation')

    elif target_team == 'innovation':
        for u in all_users:
            if u.get('is_dormant'):
                continue
            if _norm_region(u.get('region')) != access담당:
                continue
            role = (u.get('role') or '').strip()
            if role not in ('manager', 'admin'):
                continue
            uid = (u.get('empno') or '').strip()
            if uid:
                targets.add(uid)

    return list(targets)


def _wf_notify_transition_sync(conn, schedule_pk: str, from_status: str | None,
                              to_status: str, changed_by: str):
    """워크플로우 전환 시 도메인 룰에 따라 대상 팀에 알림 생성.

    수신자 매트릭스 (target_team):
    - REGISTERED → PRE_CHECK         : 'quality'    — 품개팀 (사전점검 의뢰)
    - PRE_CHECK → PRE_CHECK_DONE     : 'innovation' — 혁신팀 (회신 도착)
    - PRE_CHECK → CHANGE_FILING      : 'innovation' — 혁신팀 (변경개설 작성)
    - CHANGE_FILING → RE_CHECK       : 'innovation' — 혁신팀 (신고 완료 → 같은 팀 다른 사람)
    - RE_CHECK → PRE_CHECK_DONE      : 'innovation' — 혁신팀 (자동 재비교 통과)
    - PRE_CHECK_DONE → REPORT_ISSUED : 'innovation' — 혁신팀 (발급 완료 → 같은 팀 다른 사람)
    - REPORT_ISSUED → SUBMITTED      : 'quality'    — 품개팀 (수검 가능)
    - SUBMITTED → INSPECTED          : 'innovation' — 혁신팀 (수검 완료 보고)

    상태 변경자 본인은 수신자에서 제외 (본인 액션은 화면에 즉시 반영).
    schedule이 없으면 조용히 무시.
    """
    sched = conn.execute(
        'SELECT pk, 호출명칭, 허가번호, access담당, 품질개선팀, 수검예정주차 '
        'FROM inspection_schedules WHERE pk=?',
        (schedule_pk,)).fetchone()
    if not sched:
        return
    label = (sched['호출명칭'] or '').strip() or (sched['허가번호'] or '')
    week = (sched['수검예정주차'] or '').strip()
    meta = {
        '호출명칭': sched['호출명칭'] or '',
        '허가번호': sched['허가번호'] or '',
        '수검예정주차': week,
        'from_status': from_status or '',
        'to_status': to_status,
    }
    # (sub_type, title, message, target_team)
    msg_map = {
        WF_PRE_CHECK:      ('PRE_CHECK_REQUESTED', '사전점검 의뢰',
                            f'[{label}] 사전점검이 의뢰되었습니다.', 'quality'),
        WF_PRE_CHECK_DONE: ('PRE_CHECK_REPLIED',   '사전점검 회신',
                            f'[{label}] 사전점검 완료 회신이 도착했습니다.', 'innovation'),
        WF_CHANGE_FILING:  ('CHANGE_REQUESTED',    '변경개설 작성 요청',
                            f'[{label}] 변경개설 신고가 필요합니다.', 'innovation'),
        WF_RE_CHECK:       ('CHANGE_FILED',        '전파관리소 신고 완료',
                            f'[{label}] 전파관리소 신고가 완료되었습니다.', 'innovation'),
        WF_REPORT_ISSUED:  ('REPORT_ISSUED',       '검사내역서 발급',
                            f'[{label}] 검사내역서가 발급되었습니다.', 'innovation'),
        WF_SUBMITTED:      ('SUBMITTED',           '전파관리소 접수 완료',
                            f'[{label}] 전파관리소 접수가 완료되어 수검 가능합니다.', 'quality'),
        WF_INSPECTED:      ('INSPECTED',           '수검 완료',
                            f'[{label}] 수검이 완료되었습니다.', 'innovation'),
    }
    if to_status not in msg_map:
        return
    sub_type, title, message, target_team = msg_map[to_status]
    recipients = set(_notify_targets_for_sync(
        sched['access담당'] or '', sched['품질개선팀'] or '', target_team))
    # 상태 변경자 본인은 제외 — 본인 액션 결과는 즉시 화면 반영됨
    recipients.discard(changed_by)
    if not recipients:
        logger.info(f"알림 수신자 없음 (schedule={schedule_pk}, to={to_status}, "
                   f"team={target_team}, access={sched['access담당']}, 품개팀={sched['품질개선팀']})")
        return
    for uid in recipients:
        _create_notification_sync(conn, uid, sub_type, message,
                                  schedule_pk=schedule_pk, meta=meta,
                                  title=title)


def _wf_transition_sync(schedule_pk: str, to_status: str, changed_by: str,
                       role: str, memo: str = "") -> tuple[bool, str]:
    """단일 schedule 상태 전환. (성공여부, 메시지) 반환."""
    if to_status not in WF_VALID:
        return False, f"잘못된 상태: {to_status}"
    c = sqlite3.connect(_INSP_DB, timeout=60)
    try:
        row = c.execute(
            'SELECT workflow_status FROM inspection_schedules WHERE pk=?',
            (schedule_pk,)).fetchone()
        if not row:
            return False, "일정 없음"
        cur = row[0] or WF_REGISTERED
        if cur == to_status:
            return False, "이미 해당 상태"
        if not _wf_can_transition(cur, to_status, role):
            return False, f"전환 불가: {cur} → {to_status}"
        now = datetime.now(timezone.utc).isoformat()
        c.execute(
            'UPDATE inspection_schedules SET workflow_status=?, '
            'status_updated_at=?, status_updated_by=? WHERE pk=?',
            (to_status, now, changed_by, schedule_pk))
        _wf_record_log_sync(c, schedule_pk, cur, to_status, changed_by, memo)
        c.commit()
        return True, "ok"
    finally:
        c.close()


class WfTransitionReq(BaseModel):
    to_status: str
    memo: str = ""


class WfBulkTransitionReq(BaseModel):
    schedule_pks: list[str]
    to_status: str
    memo: str = ""


@app.patch("/inspection/schedule/{pk:path}/status")
async def inspection_schedule_transition(pk: str, request: Request, req: WfTransitionReq):
    """단일 일정의 워크플로우 상태 전환."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    ok, msg = await asyncio.to_thread(
        _wf_transition_sync, pk, req.to_status, empno, role, req.memo)
    if not ok:
        raise HTTPException(400, msg)
    await asyncio.to_thread(_record_audit_log_sync,
                           "wf_transition", "inspection_schedule", pk, empno)
    return {"success": True}


@app.post("/inspection/schedule/transition-bulk")
async def inspection_schedule_transition_bulk(request: Request, req: WfBulkTransitionReq):
    """다중 일정 일괄 상태 전환 (혁신팀 사전점검 의뢰 등)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if not req.schedule_pks:
        raise HTTPException(400, "schedule_pks 비어있음")

    def _bulk():
        results = []
        for spk in req.schedule_pks:
            ok, msg = _wf_transition_sync(spk, req.to_status, empno, role, req.memo)
            results.append({"pk": spk, "ok": ok, "msg": msg})
        return results

    results = await asyncio.to_thread(_bulk)
    success = sum(1 for r in results if r["ok"])
    await asyncio.to_thread(_record_audit_log_sync,
                           "wf_transition_bulk", "inspection_schedule",
                           f"count={len(req.schedule_pks)},to={req.to_status}", empno)
    return {"success": True, "total": len(results), "succeeded": success, "results": results}


@app.get("/inspection/schedule/{pk:path}/log")
async def inspection_schedule_log(pk: str, request: Request):
    """워크플로우 상태 전환 이력 조회."""
    await _verify_auth(request)
    def _read():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        rows = c.execute(
            'SELECT * FROM inspection_status_log WHERE schedule_pk=? ORDER BY id ASC',
            (pk,)).fetchall()
        c.close()
        return [dict(r) for r in rows]
    items = await asyncio.to_thread(_read)
    return {"items": items}


# ── 워크플로우 알림 API (Phase 5) ─────────────────────────────
#
# 주의: 기존 /notifications (커뮤니티/시정기한, _COMMUNITY_DB)와 분리.
# 워크플로우 전환 자동 알림은 /inspection/notifications/* 네임스페이스 사용.
# (URL 충돌로 기존 알림이 가려지던 문제 수정)

@app.get("/inspection/notifications")
async def wf_notifications_list(request: Request, unread_only: bool = False, limit: int = 50):
    """워크플로우 전환 알림 목록 (최신순). unread_only=true면 안 읽음만.

    저장소: inspection.db / notifications 테이블 (커뮤니티 community.db와 별개)
    """
    empno = await _verify_auth(request)
    def _read():
        import json as _j
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        sql = 'SELECT * FROM notifications WHERE user_id=?'
        params: list = [empno]
        if unread_only:
            sql += ' AND read_at IS NULL'
        sql += ' ORDER BY id DESC LIMIT ?'
        params.append(max(1, min(limit, 200)))
        rows = c.execute(sql, params).fetchall()
        c.close()
        out = []
        for r in rows:
            d = dict(r)
            if d.get('meta'):
                try: d['meta'] = _j.loads(d['meta'])
                except Exception: d['meta'] = {}
            else:
                d['meta'] = {}
            out.append(d)
        return out
    items = await asyncio.to_thread(_read)
    return {"items": items}


@app.get("/inspection/notifications/unread-count")
async def wf_notifications_unread_count(request: Request):
    """워크플로우 알림 안 읽음 개수."""
    empno = await _verify_auth(request)
    def _count():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        row = c.execute(
            'SELECT COUNT(*) FROM notifications WHERE user_id=? AND read_at IS NULL',
            (empno,)).fetchone()
        c.close()
        return row[0] if row else 0
    n = await asyncio.to_thread(_count)
    return {"count": n}


class WfNotificationReadReq(BaseModel):
    ids: list[int] = []   # 비어있으면 전체 안 읽음 → 읽음


@app.post("/inspection/notifications/mark-read")
async def wf_notifications_mark_read(request: Request, req: WfNotificationReadReq):
    """워크플로우 알림 읽음 처리. ids 비어있으면 본인의 모든 안 읽음 일괄 처리."""
    empno = await _verify_auth(request)
    def _update():
        now = datetime.now(timezone.utc).isoformat()
        c = sqlite3.connect(_INSP_DB, timeout=60)
        if req.ids:
            ph = ','.join('?' * len(req.ids))
            c.execute(
                f'UPDATE notifications SET read_at=? WHERE user_id=? '
                f'AND read_at IS NULL AND id IN ({ph})',
                [now, empno, *req.ids])
        else:
            c.execute(
                'UPDATE notifications SET read_at=? WHERE user_id=? AND read_at IS NULL',
                (now, empno))
        affected = c.total_changes
        c.commit(); c.close()
        return affected
    n = await asyncio.to_thread(_update)
    return {"success": True, "updated": n}


# ── 역할별 대시보드 (Phase 5) ──────────────────────────────────

@app.get("/inspection/dashboard")
async def inspection_dashboard(request: Request, year: int):
    """역할별 워크플로우 대시보드 집계.

    - admin: 본부 무관 전사
    - manager: 자기 본부(region)만
    - member: 자기 본부 + 자기 팀만

    응답: { role, scope, counts (워크플로우 상태별), recheck, overdue (SLA 초과 건 목록) }
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    # 사용자 region/team 조회 (my-list와 동일 패턴)
    user_data = {}
    dev = _dev_users.get(empno)
    if dev:
        user_data = {"region": dev["region"], "team": dev["team"]}
    else:
        try:
            dynamodb = get_dynamodb_resource()
            users_table = dynamodb.Table(DYNAMODB_TABLES["users"])
            item = await asyncio.to_thread(lambda: users_table.get_item(
                Key={"user_id": empno},
                ProjectionExpression="#r, team",
                ExpressionAttributeNames={"#r": "region"},
            ))
            user_data = item.get("Item", {})
        except Exception as e:
            logger.error(f"dashboard 사용자 조회 실패: {e}")
    access_team = (user_data.get("region", "") or "").replace("Access담당", "").strip()
    품질팀 = user_data.get("team", "") or ""

    def _aggregate():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        wheres = ['s.year=?']
        params: list = [year]
        scope = "전사"
        if role == "admin":
            pass
        elif role == "manager":
            if access_team:
                wheres.append('s.access담당=?')
                params.append(access_team)
                scope = access_team
            # region 없는 manager는 전사 (보수적)
        else:  # member
            if access_team:
                wheres.append('s.access담당=?')
                params.append(access_team)
                scope = access_team
            if 품질팀:
                wheres.append('s.품질개선팀=?')
                params.append(품질팀)
                scope = f"{access_team or ''}-{품질팀}" if access_team else 품질팀

        sel = ('SELECT s.workflow_status, s.status_updated_at, s.pk, '
               's.호출명칭, s.허가번호, r.needs_recheck '
               'FROM inspection_schedules s '
               'LEFT JOIN inspection_results r ON r.pk = s.pk '
               'WHERE ' + ' AND '.join(wheres))
        rows = c.execute(sel, params).fetchall()
        c.close()

        # 상태별 카운트
        counts = {
            'REGISTERED': 0, 'PRE_CHECK': 0, 'PRE_CHECK_DONE': 0,
            'CHANGE_FILING': 0, 'RE_CHECK': 0,
            'REPORT_ISSUED': 0, 'SUBMITTED': 0, 'INSPECTED': 0,
        }
        recheck = 0
        overdue: list[dict] = []
        now = datetime.now(timezone.utc)
        for r in rows:
            st = (r['workflow_status'] or 'REGISTERED')
            if st in counts:
                counts[st] += 1
            if (r['needs_recheck'] or '0') == '1':
                recheck += 1
            # SLA 지연 판정
            threshold = _SLA_DAYS.get(st)
            if threshold and r['status_updated_at']:
                try:
                    updated = datetime.fromisoformat(r['status_updated_at'])
                    if updated.tzinfo is None:
                        updated = updated.replace(tzinfo=timezone.utc)
                    days = (now - updated).days
                    if days > threshold:
                        overdue.append({
                            'pk': r['pk'],
                            '호출명칭': r['호출명칭'] or '',
                            '허가번호': r['허가번호'] or '',
                            'status': st,
                            'days_overdue': days - threshold,
                            'threshold': threshold,
                        })
                except Exception:
                    pass
        # 지연 큰 순으로 정렬, 상위 20건만
        overdue.sort(key=lambda x: x['days_overdue'], reverse=True)
        return {
            'role': role,
            'scope': scope,
            'counts': counts,
            'recheck': recheck,
            'overdue': overdue[:20],
            'overdue_total': len(overdue),
        }

    result = await asyncio.to_thread(_aggregate)
    return result


class PreCheckResultReq(BaseModel):
    summary: dict      # {tower_match, tower_mismatch, ..., serial_*, ds_missing, check}
    items: list = []   # zpwino별 상세 (선택)
    confirmation_acknowledged: bool = False  # 확인필요 포함 회신 동의


@app.post("/inspection/schedule/{pk:path}/pre-check-result")
async def inspection_schedule_pre_check_result(pk: str, request: Request, req: PreCheckResultReq):
    """전산비교 결과 첨부 + PRE_CHECK_DONE 자동 전환.

    - 불일치 또는 DS누락 0건일 때만 전환 허용
    - 확인필요 포함 회신 시 confirmation_acknowledged=true 필요
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    s = req.summary or {}
    mismatch = (s.get("tower_mismatch", 0) + s.get("serial_mismatch", 0))
    ds_missing = (s.get("tower_ds_missing", 0) + s.get("serial_ds_missing", 0))
    check = (s.get("tower_check", 0) + s.get("serial_check", 0))
    if mismatch > 0 or ds_missing > 0:
        raise HTTPException(400, f"불일치 {mismatch}건/DS누락 {ds_missing}건 — 변경개설 필요")
    if check > 0 and not req.confirmation_acknowledged:
        raise HTTPException(400, f"확인필요 {check}건 — 외부 확인 동의 필요")

    now = datetime.now(timezone.utc).isoformat()
    payload = json.dumps({
        "summary": s, "items": req.items,
        "checked_at": now, "checked_by": empno,
    }, ensure_ascii=False)

    def _save():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        row = c.execute('SELECT workflow_status FROM inspection_schedules WHERE pk=?', (pk,)).fetchone()
        if not row:
            c.close()
            return False, "일정 없음"
        cur = row[0] or WF_REGISTERED
        if not _wf_can_transition(cur, WF_PRE_CHECK_DONE, role):
            c.close()
            return False, f"전환 불가: {cur} → PRE_CHECK_DONE"
        c.execute(
            'UPDATE inspection_schedules SET pre_check_result=?, workflow_status=?, '
            'status_updated_at=?, status_updated_by=? WHERE pk=?',
            (payload, WF_PRE_CHECK_DONE, now, empno, pk))
        _wf_record_log_sync(c, pk, cur, WF_PRE_CHECK_DONE, empno,
                          f"전산비교 회신 (확인필요 {check}건 포함={req.confirmation_acknowledged})")
        c.commit(); c.close()
        return True, "ok"

    ok, msg = await asyncio.to_thread(_save)
    if not ok:
        raise HTTPException(400, msg)
    return {"success": True}


# ============================================================
# 변경개설 요청 (Phase 2)
# ============================================================

# 변경 가능 4항목
WF_CHANGE_FIELDS = {"일련번호", "형식검정번호", "설치형태", "설치장소"}
# 장치 단위 항목 (장치번호 필수)
WF_CHANGE_DEVICE_FIELDS = {"일련번호", "형식검정번호"}


class ChangeRequestItem(BaseModel):
    field: str
    before_value: str = ""
    after_value: str
    장치번호: str = ""
    memo: str = ""


class ChangeRequestCreateReq(BaseModel):
    items: list[ChangeRequestItem]   # 한 schedule에 여러 항목 일괄 등록


@app.post("/inspection/schedule/{pk:path}/change-request")
async def inspection_change_request_create(pk: str, request: Request, req: ChangeRequestCreateReq):
    """전산비교에서 불일치/DS누락 발견 시 변경개설 요청 작성 (품개팀).

    - schedule이 PRE_CHECK 상태일 때만 가능
    - 항목 검증 (4개 필드, 장치 단위는 장치번호 필수)
    - workflow_status: PRE_CHECK → CHANGE_FILING 자동 전환
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    if not req.items:
        raise HTTPException(400, "변경 항목이 비어있습니다.")
    for it in req.items:
        if it.field not in WF_CHANGE_FIELDS:
            raise HTTPException(400, f"잘못된 변경 항목: {it.field}")
        if it.field in WF_CHANGE_DEVICE_FIELDS and not it.장치번호.strip():
            raise HTTPException(400, f"{it.field}는 장치번호 필수")
        if not it.after_value.strip():
            raise HTTPException(400, f"{it.field} 변경 후 값이 비어있습니다.")

    now = datetime.now(timezone.utc).isoformat()

    def _save():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        row = c.execute('SELECT workflow_status, 허가번호 FROM inspection_schedules WHERE pk=?', (pk,)).fetchone()
        if not row:
            c.close()
            return False, "일정 없음", 0
        cur, license_no = row[0] or WF_REGISTERED, row[1]
        if not _wf_can_transition(cur, WF_CHANGE_FILING, role):
            c.close()
            return False, f"전환 불가: {cur} → CHANGE_FILING", 0

        for it in req.items:
            c.execute(
                'INSERT INTO change_request(schedule_pk, 허가번호, field, before_value, '
                'after_value, 장치번호, memo, status, requested_by, requested_at) '
                'VALUES (?,?,?,?,?,?,?,?,?,?)',
                (pk, license_no, it.field, it.before_value, it.after_value,
                 it.장치번호, it.memo, 'REQUESTED', empno, now))

        c.execute(
            'UPDATE inspection_schedules SET workflow_status=?, '
            'status_updated_at=?, status_updated_by=? WHERE pk=?',
            (WF_CHANGE_FILING, now, empno, pk))
        _wf_record_log_sync(c, pk, cur, WF_CHANGE_FILING, empno,
                          f"변경개설 요청 {len(req.items)}건")
        c.commit(); c.close()
        return True, "ok", len(req.items)

    ok, msg, count = await asyncio.to_thread(_save)
    if not ok:
        raise HTTPException(400, msg)
    return {"success": True, "count": count}


@app.get("/change-request")
async def change_request_list(
    request: Request, schedule_pk: str = "", status: str = "",
    허가번호: str = "", access담당: str = "", year: int = 0,
):
    """변경개설 요청 목록 조회 (혁신팀: 본부 필터, 품개팀: schedule_pk 단건)."""
    await _verify_auth(request)

    def _read():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        wheres: list = []
        params: list = []

        if schedule_pk:
            wheres.append('cr.schedule_pk=?'); params.append(schedule_pk)
        if status:
            wheres.append('cr.status=?'); params.append(status)
        if 허가번호:
            wheres.append('cr.허가번호=?'); params.append(허가번호)
        # access담당/year 는 inspection_schedules와 JOIN해서 필터
        join = ''
        if access담당 or year:
            join = ' JOIN inspection_schedules s ON s.pk = cr.schedule_pk'
            if access담당:
                wheres.append('s.access담당=?'); params.append(access담당)
            if year:
                wheres.append('s.year=?'); params.append(year)

        sql = f'SELECT cr.* FROM change_request cr{join}'
        if wheres:
            sql += ' WHERE ' + ' AND '.join(wheres)
        sql += ' ORDER BY cr.requested_at DESC'
        rows = c.execute(sql, params).fetchall()
        c.close()
        return [dict(r) for r in rows]

    items = await asyncio.to_thread(_read)
    return {"items": items}


class ChangeRequestFileReq(BaseModel):
    schedule_pk: str = ""        # 단건
    schedule_pks: list[str] = [] # 묶음
    memo: str = ""


@app.patch("/change-request/file")
async def change_request_file(request: Request, req: ChangeRequestFileReq):
    """혁신팀이 전파관리소 신고 완료 표시 (단건 또는 묶음).

    - schedule의 모든 change_request status: REQUESTED → FILED
    - workflow_status: CHANGE_FILING → RE_CHECK
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    now = datetime.now(timezone.utc).isoformat()

    pks = list(req.schedule_pks) if req.schedule_pks else []
    if req.schedule_pk:
        pks.append(req.schedule_pk)
    pks = list(dict.fromkeys(p for p in pks if p))  # dedupe + drop empty
    if not pks:
        raise HTTPException(400, "schedule_pk(s) 비어있음")

    def _save_one(c, pk: str) -> tuple[bool, str]:
        row = c.execute(
            'SELECT workflow_status FROM inspection_schedules WHERE pk=?',
            (pk,)).fetchone()
        if not row:
            return False, "일정 없음"
        cur = row[0] or WF_REGISTERED
        if not _wf_can_transition(cur, WF_RE_CHECK, role):
            return False, f"전환 불가: {cur} → RE_CHECK"
        c.execute(
            "UPDATE change_request SET status='FILED', filed_by=?, filed_at=? "
            "WHERE schedule_pk=? AND status='REQUESTED'",
            (empno, now, pk))
        c.execute(
            'UPDATE inspection_schedules SET workflow_status=?, '
            'status_updated_at=?, status_updated_by=? WHERE pk=?',
            (WF_RE_CHECK, now, empno, pk))
        _wf_record_log_sync(c, pk, cur, WF_RE_CHECK, empno,
                          req.memo or "전파관리소 신고 완료")
        return True, "ok"

    def _save():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        results = []
        for pk in pks:
            ok, msg = _save_one(c, pk)
            results.append({"pk": pk, "ok": ok, "msg": msg})
        c.commit(); c.close()
        return results

    results = await asyncio.to_thread(_save)
    success = sum(1 for r in results if r["ok"])
    return {"success": True, "total": len(results), "succeeded": success, "results": results}


# 변경개설 신고서 양식 매핑
_WF_CHANGE_LABEL = {
    "설치형태": "설치형태 오류정정",
    "설치장소": "(부적합 무선국)\n설치장소 오류정정",
    "일련번호": "송수신장치 변경(공용화 고시 제6조제3항제1호)",
    "형식검정번호": "(불합격 무선국)\n형식검정번호 오류정정",
}

def _wf_format_change_value(field: str, value: str) -> str:
    """변경전/변경후 값에 prefix 적용."""
    v = (value or "").strip()
    if field == "설치형태":
        return f"설치형태 : {v}"
    if field == "설치장소":
        return v  # prefix 없음, 주소 그대로
    if field == "일련번호":
        return f"일련번호 : {v}"
    if field == "형식검정번호":
        return f"형검 : {v}"
    return v


def _wf_format_license_no(license_no: str) -> str:
    """허가번호 하이픈 4그룹 포맷 (32-2006-61-0000356)."""
    s = (license_no or "").replace("-", "")
    if len(s) >= 12:
        return f"{s[:2]}-{s[2:6]}-{s[6:8]}-{s[8:]}"
    return license_no


@app.post("/change-request/generate-form")
async def change_request_generate_form(
    request: Request,
    품질개선팀: str = "",
    수검예정주차: str = "",
    조: str = "",
    year: int = 0,
    schedule_pk: str = "",
):
    """A파일(변경개설 신고서) 묶음 자동 생성 - xls 즉시 응답.

    묶음 키: (품질개선팀, 수검예정주차, 조, year)
    또는 schedule_pk 단건도 지원 (역호환).
    """
    await _verify_auth(request)

    def _build():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        if schedule_pk:
            scheds = c.execute(
                'SELECT * FROM inspection_schedules WHERE pk=?',
                (schedule_pk,)).fetchall()
        else:
            wheres = []
            params: list = []
            if year:
                wheres.append('year=?'); params.append(year)
            if 품질개선팀:
                wheres.append('품질개선팀=?'); params.append(품질개선팀)
            if 수검예정주차:
                wheres.append('수검예정주차=?'); params.append(수검예정주차)
            if 조:
                wheres.append('조=?'); params.append(조)
            if not wheres:
                c.close()
                raise HTTPException(400, "묶음 키 또는 schedule_pk 필요")
            scheds = c.execute(
                f'SELECT * FROM inspection_schedules WHERE {" AND ".join(wheres)} ORDER BY 허가번호',
                params).fetchall()

        scheds = [dict(s) for s in scheds]
        if not scheds:
            c.close()
            raise HTTPException(404, "묶음 일정 없음")

        # 각 schedule_pk 별로 change_request 조회
        sched_pks = [s['pk'] for s in scheds]
        ph = ','.join('?' * len(sched_pks))
        rows = c.execute(
            f"SELECT * FROM change_request WHERE schedule_pk IN ({ph}) ORDER BY schedule_pk, id",
            sched_pks).fetchall()
        c.close()
        rows = [dict(r) for r in rows]
        if not rows:
            raise HTTPException(404, "변경 요청 없음")

        # schedule_pk → schedule 메타 매핑
        sched_map = {s['pk']: s for s in scheds}
        return scheds, sched_map, rows

    scheds, sched_map, items = await asyncio.to_thread(_build)

    # 묶음 식별자: <품질개선팀>_<주차>_<조>
    first = scheds[0]
    팀 = (first.get('품질개선팀') or '').strip() or 품질개선팀
    주차 = (first.get('수검예정주차') or '').strip() or 수검예정주차
    조_v = (first.get('조') or '').strip() or 조
    sheet_name = f"{팀}_{주차}_{조_v}".strip('_') or '변경개설신고'
    if len(sheet_name) > 31:
        sheet_name = sheet_name[:31]

    # xlwt — 샘플 양식 1:1 재현
    import xlwt, io as _io
    wb = xlwt.Workbook(encoding='utf-8')
    ws = wb.add_sheet(sheet_name)

    # 컬럼 너비 (xlwt 단위 = 1/256 char width; 샘플 값 그대로)
    col_widths = [947, 5401, 4915, 13952, 13952, 13952, 1331, 1331, 2304, 3379, 1689]
    for ci, w in enumerate(col_widths):
        ws.col(ci).width = w

    # 폰트
    def _font(height: int, name: str = '맑은 고딕'):
        f = xlwt.Font()
        f.name = name
        f.height = height
        return f

    # 테두리 (얇은 사면)
    def _border():
        b = xlwt.Borders()
        b.left = b.right = b.top = b.bottom = xlwt.Borders.THIN
        return b

    # 정렬
    def _align(h='center', v='center', wrap=False):
        a = xlwt.Alignment()
        a.horz = {'left': xlwt.Alignment.HORZ_LEFT,
                  'center': xlwt.Alignment.HORZ_CENTER,
                  'right': xlwt.Alignment.HORZ_RIGHT}.get(h, xlwt.Alignment.HORZ_CENTER)
        a.vert = xlwt.Alignment.VERT_CENTER
        if wrap:
            a.wrap = xlwt.Alignment.WRAP_AT_RIGHT
        return a

    # 노란 배경 (변경내역 열)
    def _yellow_pattern():
        p = xlwt.Pattern()
        p.pattern = xlwt.Pattern.SOLID_PATTERN
        p.pattern_fore_colour = 13  # yellow
        return p

    # 스타일들
    style_title = xlwt.XFStyle()
    style_title.font = _font(600)  # 30pt, 기본 폰트(맑은 고딕)
    style_title.alignment = _align('left', 'center', False)

    style_header = xlwt.XFStyle()
    style_header.font = _font(220)
    style_header.alignment = _align('center', 'center', True)
    style_header.borders = _border()

    style_data = xlwt.XFStyle()
    style_data.font = _font(200)
    style_data.alignment = _align('center', 'center', True)
    style_data.borders = _border()

    style_data_yellow = xlwt.XFStyle()
    style_data_yellow.font = _font(200)
    style_data_yellow.alignment = _align('center', 'center', True)
    style_data_yellow.borders = _border()
    style_data_yellow.pattern = _yellow_pattern()

    # 행 높이
    ws.row(0).height_mismatch = True; ws.row(0).height = 768
    ws.row(1).height_mismatch = True; ws.row(1).height = 345
    ws.row(2).height_mismatch = True; ws.row(2).height = 348

    # 제목 (A1 셀)
    ws.write(0, 0, '○ 무선국 변경개설신고', style_title)

    # 헤더 (row 1-2 병합)
    headers = ['순\n번', '호출명칭', '허가번호', '변경내역', '변경전', '변경후',
               '위도', '경도', '준공기한', '심의차수', '허가\n종류']
    for ci, h in enumerate(headers):
        ws.write_merge(1, 2, ci, ci, h, style_header)

    # 데이터 row[3+]
    for idx, it in enumerate(items):
        ri = idx + 3
        ws.row(ri).height_mismatch = True
        ws.row(ri).height = 1305

        sched = sched_map.get(it.get('schedule_pk'), {})
        호출명칭 = sched.get('호출명칭', '')
        허가번호 = _wf_format_license_no(it.get('허가번호') or sched.get('허가번호', ''))
        field = it.get('field', '')
        변경내역 = _WF_CHANGE_LABEL.get(field, field)
        변경전 = _wf_format_change_value(field, it.get('before_value', ''))
        변경후 = _wf_format_change_value(field, it.get('after_value', ''))

        ws.write(ri, 0, idx + 1, style_data)
        ws.write(ri, 1, 호출명칭, style_data)
        ws.write(ri, 2, 허가번호, style_data)
        ws.write(ri, 3, 변경내역, style_data_yellow)
        ws.write(ri, 4, 변경전, style_data)
        ws.write(ri, 5, 변경후, style_data)
        ws.write(ri, 6, '기존동일', style_data)
        ws.write(ri, 7, '', style_data)
        ws.write(ri, 8, '', style_data)
        ws.write(ri, 9, '', style_data)
        ws.write(ri, 10, '운용', style_data)

    buf = _io.BytesIO()
    wb.save(buf)
    buf.seek(0)
    n = len(items)
    filename = f"{sheet_name}_{n}건.xls" if n else f"{sheet_name}.xls"
    from fastapi.responses import StreamingResponse
    from urllib.parse import quote
    return StreamingResponse(
        buf,
        media_type="application/vnd.ms-excel",
        headers={
            "Content-Disposition": f"attachment; filename*=UTF-8''{quote(filename)}",
        },
    )


@app.post("/ds/apply-partial-update")
async def ds_apply_partial_update(request: Request, file: UploadFile = File(...)):
    """부분 DS 파일 업로드 → ds_detail.db 패치 + 자동 재비교 + 워크플로우 전환.

    - 파일은 전체 DS 파일과 동일 시트/컬럼 구조의 부분 파일
    - change_request에 등록된 (허가번호, 장치번호, field) 만 패치
    - 모든 change_request 항목이 일치하면 RE_CHECK → PRE_CHECK_DONE 자동 전환
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    file_bytes = await file.read()
    if not file_bytes:
        raise HTTPException(400, "빈 파일")

    def _process():
        import xlrd as _xlrd
        try:
            wb = _xlrd.open_workbook(file_contents=file_bytes)
        except Exception as e:
            raise HTTPException(400, f"xls 파싱 실패: {e}")

        # 부분 DS에서 (허가번호 정규화) 추출
        license_set: set[str] = set()
        for si in range(len(wb.sheet_names())):
            ws = wb.sheet_by_index(si)
            for ri in range(1, ws.nrows):
                v = ws.cell_value(ri, 0)
                if isinstance(v, float) and v == int(v):
                    license_set.add(str(int(v)))
                elif v:
                    license_set.add(str(v).strip().replace('-', ''))

        if not license_set:
            raise HTTPException(400, "허가번호 없음")

        # change_request에서 FILED/REQUESTED 상태 + 부분 DS에 포함된 허가번호 항목들 조회
        ic = sqlite3.connect(_INSP_DB, timeout=60); ic.row_factory = sqlite3.Row
        placeholders = ','.join('?' * len(license_set))
        crs = ic.execute(
            f"SELECT * FROM change_request WHERE status IN ('REQUESTED','FILED') "
            f"AND REPLACE(허가번호, '-', '') IN ({placeholders})",
            list(license_set)).fetchall()
        crs = [dict(r) for r in crs]

        if not crs:
            ic.close()
            return {"matched_changes": 0, "applied": 0, "schedule_done": [], "skipped_licenses": list(license_set)}

        # 시트 구조 파싱: 일반사항(0), 위치(1), 송신장치(2), 안테나(4), 설치장소(5)
        # 각 sheet에서 (허가번호 normalized) → row 인덱스 맵
        sheet_idx_map = {}  # {sheet_name: idx}
        for si, sn in enumerate(wb.sheet_names()):
            sheet_idx_map[sn] = si

        # 시트 이름 매칭 (포함 검색)
        def _find_sheet(keyword: str) -> int:
            for sn, idx in sheet_idx_map.items():
                if keyword in sn:
                    return idx
            return -1

        장치_si = _find_sheet('장치')
        안테나_si = _find_sheet('안테나')
        설치장소_si = _find_sheet('설치장소')

        # 장치 시트: col 8 = 일련번호, col 11 = 형식검정번호
        # 안테나 시트: col 28 = 공중선주설치형태명
        # 설치장소 시트: col 6 = 설치소재주소
        # 모두 col 0 = 허가번호, col 3 = 장치번호 (장치/안테나)

        def _norm_hn(val):
            if isinstance(val, float) and val == int(val):
                return str(int(val))
            return str(val).strip().replace('-', '')

        # (license_norm, 장치번호) → {field: new_value}
        device_patches: dict[tuple[str, str], dict[str, str]] = {}
        # license_norm → {field: new_value}
        license_patches: dict[str, dict[str, str]] = {}

        if 장치_si >= 0:
            ws = wb.sheet_by_index(장치_si)
            for ri in range(1, ws.nrows):
                hn = _norm_hn(ws.cell_value(ri, 0))
                jn = _norm_hn(ws.cell_value(ri, 3)) if ws.ncols > 3 else ''
                if not hn or not jn:
                    continue
                key = (hn, jn)
                d = device_patches.setdefault(key, {})
                if ws.ncols > 8:
                    v = str(ws.cell_value(ri, 8) or '').strip()
                    if v:
                        d['일련번호'] = v
                if ws.ncols > 11:
                    v = str(ws.cell_value(ri, 11) or '').strip()
                    if v:
                        d['형식검정번호'] = v

        if 안테나_si >= 0:
            ws = wb.sheet_by_index(안테나_si)
            for ri in range(1, ws.nrows):
                hn = _norm_hn(ws.cell_value(ri, 0))
                if not hn:
                    continue
                if ws.ncols > 28:
                    v = str(ws.cell_value(ri, 28) or '').strip()
                    if v:
                        license_patches.setdefault(hn, {})['설치형태'] = v

        if 설치장소_si >= 0:
            ws = wb.sheet_by_index(설치장소_si)
            for ri in range(1, ws.nrows):
                hn = _norm_hn(ws.cell_value(ri, 0))
                if not hn:
                    continue
                if ws.ncols > 6:
                    v = str(ws.cell_value(ri, 6) or '').strip()
                    if v:
                        license_patches.setdefault(hn, {})['설치장소'] = v

        # change_request 매칭 + DS DB 패치
        dc = sqlite3.connect(_DS_DETAIL_DB, timeout=60)
        dc.execute('PRAGMA journal_mode=WAL')
        dc.execute('''CREATE TABLE IF NOT EXISTS ds_변경이력 (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            허가번호 TEXT NOT NULL, 변경일자 TEXT NOT NULL,
            시트 TEXT NOT NULL, 필드명 TEXT NOT NULL,
            변경전값 TEXT, 변경후값 TEXT, 장치번호 TEXT
        )''')

        applied_date = datetime.now().strftime('%y%m%d')
        applied_count = 0
        applied_cr_ids: list[int] = []

        for cr in crs:
            hn_norm = (cr['허가번호'] or '').replace('-', '').strip()
            field = cr['field']
            jn = (cr['장치번호'] or '').strip()
            expected = (cr['after_value'] or '').strip()

            patched_value = None
            if field in WF_CHANGE_DEVICE_FIELDS:
                if not jn:
                    continue
                patches = device_patches.get((hn_norm, jn), {})
                patched_value = patches.get(field)
            else:
                patches = license_patches.get(hn_norm, {})
                patched_value = patches.get(field)

            if not patched_value:
                continue
            # change_request 의 expected 값과 일치하는지 (선택적 검증)
            # 부분 DS의 값이 신고된 값과 다르면 일단 신고된 값(expected)으로 패치 (의심스러우면 patched_value 사용)
            new_value = expected  # 신고서 기준이 진실

            # DS DB 패치
            try:
                if field == '일련번호':
                    cur = dc.execute(
                        'UPDATE ds_장치 SET 기기일련번호=? WHERE 허가번호=? AND 장치번호=?',
                        (new_value, hn_norm, jn))
                elif field == '형식검정번호':
                    cur = dc.execute(
                        'UPDATE ds_장치 SET 형식검정번호=? WHERE 허가번호=? AND 장치번호=?',
                        (new_value, hn_norm, jn))
                elif field == '설치형태':
                    cur = dc.execute(
                        'UPDATE ds_안테나 SET 공중선주설치형태명=? WHERE 허가번호=?',
                        (new_value, hn_norm))
                elif field == '설치장소':
                    cur = ic.execute(
                        "UPDATE inspection_targets SET 설치장소=? WHERE REPLACE(허가번호,'-','')=?",
                        (new_value, hn_norm))
                else:
                    continue
                if cur.rowcount > 0:
                    dc.execute(
                        'INSERT INTO ds_변경이력(허가번호,변경일자,시트,필드명,변경전값,변경후값,장치번호) '
                        'VALUES(?,?,?,?,?,?,?)',
                        (hn_norm, applied_date, '부분DS', field,
                         cr['before_value'] or '', new_value, jn))
                    applied_count += 1
                    applied_cr_ids.append(cr['id'])
            except Exception as e:
                logger.warning(f"부분 DS 패치 실패 ({hn_norm}/{jn}/{field}): {e}")

        dc.commit(); dc.close()

        # 패치된 change_request 들을 APPLIED 로
        now = datetime.now(timezone.utc).isoformat()
        if applied_cr_ids:
            ph = ','.join('?' * len(applied_cr_ids))
            ic.execute(
                f"UPDATE change_request SET status='APPLIED', applied_at=? WHERE id IN ({ph})",
                [now] + applied_cr_ids)

        # 자동 재비교: schedule별로 모든 change_request가 APPLIED 이상이면 PRE_CHECK_DONE 전환
        sched_pks = set()
        for cr in crs:
            if cr['id'] in applied_cr_ids:
                sched_pks.add(cr['schedule_pk'])

        schedule_done: list[str] = []
        for spk in sched_pks:
            row = ic.execute(
                'SELECT workflow_status FROM inspection_schedules WHERE pk=?',
                (spk,)).fetchone()
            if not row:
                continue
            cur_status = row['workflow_status'] or WF_REGISTERED
            if cur_status != WF_RE_CHECK:
                continue
            # 해당 schedule의 모든 cr이 APPLIED/VERIFIED 인지
            unfinished = ic.execute(
                "SELECT COUNT(*) FROM change_request WHERE schedule_pk=? AND status NOT IN ('APPLIED','VERIFIED')",
                (spk,)).fetchone()[0]
            if unfinished > 0:
                continue
            # 전환
            ic.execute(
                'UPDATE inspection_schedules SET workflow_status=?, '
                'status_updated_at=?, status_updated_by=? WHERE pk=?',
                (WF_PRE_CHECK_DONE, now, 'system', spk))
            _wf_record_log_sync(ic, spk, cur_status, WF_PRE_CHECK_DONE, 'system',
                              "부분 DS 적용 후 자동 재비교 통과")
            ic.execute(
                "UPDATE change_request SET status='VERIFIED' WHERE schedule_pk=? AND status='APPLIED'",
                (spk,))
            schedule_done.append(spk)

        ic.commit(); ic.close()

        return {
            "matched_changes": len(crs),
            "applied": applied_count,
            "schedule_done": schedule_done,
        }

    result = await asyncio.to_thread(_process)
    await asyncio.to_thread(_record_audit_log_sync,
                           "ds_partial_update", "ds_detail",
                           f"applied={result['applied']},done={len(result['schedule_done'])}",
                           empno)
    return {"success": True, **result}


@app.post("/inspection/schedule")
async def inspection_schedule_upsert(request: Request, req: InspectionScheduleReq):
    """수검 일정 등록/수정 (관리자/매니저)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}: raise HTTPException(403, "권한 없음")
    pk = f"{req.year}#{req.허가번호}"
    now = datetime.now(timezone.utc).isoformat()
    def _write():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        # 기존 행 존재 여부 확인 (신규 INSERT인지 UPDATE인지 판단 → log 기록용)
        existed = c.execute(
            'SELECT workflow_status FROM inspection_schedules WHERE pk=?', (pk,)).fetchone()
        c.execute('''INSERT OR REPLACE INTO inspection_schedules
            (pk, year, 허가번호, 호출명칭, 분기, skt본부, access담당, 품질개선팀,
             수검예정주차, 수검시작일, 수검종료일, 지역, 등록자, 등록일시, 검사관, 조,
             workflow_status, status_updated_at, status_updated_by)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
            (pk, req.year, req.허가번호, req.호출명칭, req.분기, req.skt본부,
             req.access담당, req.품질개선팀, req.수검예정주차,
             req.수검시작일, req.수검종료일, req.지역, empno, now, req.검사관, req.조,
             (existed[0] if existed and existed[0] else WF_REGISTERED), now, empno))
        # 검사결과 기본값 '합격' 자동 생성 (기존 결과 있으면 덮어쓰지 않음)
        c.execute('''INSERT OR IGNORE INTO inspection_results
            (pk, year, 허가번호, status, 입력자, 입력일시)
            VALUES (?,?,?,?,?,?)''',
            (pk, req.year, req.허가번호, '합격', empno, now))
        # 신규 등록 시에만 status_log 기록 (REGISTERED 진입)
        if not existed:
            _wf_record_log_sync(c, pk, None, WF_REGISTERED, empno, "일정 등록")
        c.commit(); c.close()
    await asyncio.to_thread(_write)
    await asyncio.to_thread(_record_audit_log_sync, "inspection_schedule_upsert", "inspection_schedule", pk, empno)
    # 백그라운드 지오코딩 (좌표 없는 경우만, 이미 있으면 즉시 스킵)
    asyncio.create_task(asyncio.to_thread(_geocode_target_sync, req.year, req.허가번호))
    return {"success": True}

@app.delete("/inspection/schedule/{year}/{license_no}")
async def inspection_schedule_delete(year: int, license_no: str, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}: raise HTTPException(403, "권한 없음")
    pk = f"{year}#{license_no}"
    def _del():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        c.execute('DELETE FROM inspection_schedules WHERE pk=?', (pk,))
        c.commit(); c.close()
    await asyncio.to_thread(_del)
    return {"success": True}

@app.get("/inspection/schedules")
async def inspection_schedules_list(
    request: Request, year: int, access담당: str = "", workflow_status: str = ""
):
    """일정 목록 조회 (팀별 + workflow_status 필터). Phase 4부터 needs_recheck, 검사결과status 함께 노출."""
    await _verify_auth(request)
    def _read():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        wheres = ['s.year=?']
        params: list = [year]
        if access담당:
            wheres.append('s.access담당=?')
            params.append(access담당)
        if workflow_status:
            wheres.append('s.workflow_status=?')
            params.append(workflow_status)
        # inspection_results와 LEFT JOIN — needs_recheck, 검사결과 status 노출 (INSPECTED 단계에서만 의미있음)
        rows = c.execute(
            f'''SELECT s.*,
                       r.needs_recheck AS needs_recheck,
                       r.status        AS result_status,
                       r.검사일        AS 검사일
                  FROM inspection_schedules s
                  LEFT JOIN inspection_results r ON r.pk = s.pk
                 WHERE {" AND ".join(wheres)}''',
            params).fetchall()
        c.close()
        return [dict(r) for r in rows]
    items = await asyncio.to_thread(_read)
    return {"items": items}

@app.post("/inspection/result")
async def inspection_result_upsert(request: Request, req: InspectionResultReq):
    """수검 결과 입력 (팀원 가능).

    Phase 4 자동 처리:
    - schedule_pk = pk (year#허가번호 동일)
    - 검사일 입력 시 워크플로우 자동 전환 (SUBMITTED → INSPECTED, 가능한 경우)
    - status가 불합격/부적합이면 needs_recheck='1' (혁신팀이 재점검 일정을 수동 등록)
    """
    empno = await _verify_auth(request)
    # 입력자 이름 조회
    user_info = await asyncio.to_thread(_get_user_info_for_community, empno)
    입력자_name = user_info.get("name", empno)
    pk = f"{req.year}#{req.허가번호}"
    now = datetime.now(timezone.utc).isoformat()
    # 재점검 플래그 판정 — 합격이 아니면(불합격/부적합 등) recheck
    needs_recheck = '1' if req.status.strip() not in ('합격', '') else '0'

    def _write():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        # 기존 사진 목록 보존
        existing = c.execute('SELECT 사진S3키 FROM inspection_results WHERE pk=?', (pk,)).fetchone()
        photos_json = existing['사진S3키'] if existing else '[]'
        c.execute('''INSERT OR REPLACE INTO inspection_results
            (pk, year, 허가번호, status, 검사일, 메모, 철탑형태, 사진S3키, 입력자, 입력일시,
             schedule_pk, needs_recheck)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)''',
            (pk, req.year, req.허가번호, req.status, req.검사일,
             req.메모, req.철탑형태, photos_json, 입력자_name, now,
             pk, needs_recheck))
        # 검사일이 입력됐고 schedule이 존재하면 INSPECTED로 자동 전환 시도
        transitioned = False
        if (req.검사일 or '').strip():
            sched = c.execute(
                'SELECT workflow_status FROM inspection_schedules WHERE pk=?',
                (pk,)).fetchone()
            if sched:
                cur = sched['workflow_status'] or WF_REGISTERED
                # 시스템 자동 전환 — admin 권한과 동일하게 처리 (역행 방지는 _wf_can_transition으로)
                if _wf_can_transition(cur, WF_INSPECTED, 'admin') and cur != WF_INSPECTED:
                    c.execute(
                        'UPDATE inspection_schedules SET workflow_status=?, '
                        'status_updated_at=?, status_updated_by=? WHERE pk=?',
                        (WF_INSPECTED, now, empno, pk))
                    _wf_record_log_sync(c, pk, cur, WF_INSPECTED, empno,
                                      f"수검 결과 입력 ({req.status})")
                    transitioned = True
        c.commit(); c.close()
        return transitioned

    transitioned = await asyncio.to_thread(_write)
    await asyncio.to_thread(_record_audit_log_sync,
                           "inspection_result_upsert", "inspection_result",
                           f"{pk},inspected={transitioned},recheck={needs_recheck}", empno)
    return {"success": True, "inspected": transitioned, "needs_recheck": needs_recheck == '1'}

@app.post("/inspection/station")
async def inspection_station_add(request: Request, req: InspectionStationReq):
    """개별 수검 대상 국소 추가 (admin/manager 전용)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")
    if not req.허가번호.strip():
        raise HTTPException(400, "허가번호 필수")
    if not req.skt본부.strip():
        raise HTTPException(400, "본부 필수")
    def _insert():
        import sqlite3 as _sq
        c = _sq.connect(_INSP_DB, timeout=60)
        # 중복 허가번호+연도 방지 (이미 있으면 업데이트)
        existing = c.execute(
            'SELECT id FROM inspection_targets WHERE year=? AND 허가번호=?',
            (req.year, req.허가번호.strip())).fetchone()
        if existing:
            c.execute('''UPDATE inspection_targets SET
                호출명칭=?, 국종군=?, 부서=?, 분기=?, 연도주기=?, 검사주기=?,
                허가상태=?, 설치장소=?, 도로명주소=?, 장치수=?, 통시=?, 공대=?,
                kca검토결과=?, 시기조정=?, 기준연도=?, skt본부=?, access담당=?, 품질개선팀=?
                WHERE year=? AND 허가번호=?''',
                (req.호출명칭, req.국종군, req.부서, req.분기, req.연도주기, req.검사주기,
                 req.허가상태, req.설치장소, req.도로명주소, req.장치수, req.통시, req.공대,
                 req.kca검토결과, req.시기조정, req.기준연도, req.skt본부, req.access담당, req.품질개선팀,
                 req.year, req.허가번호.strip()))
            action = "updated"
        else:
            c.execute('''INSERT INTO inspection_targets
                (year, sheet, 허가번호, 호출명칭, 국종군, 부서, 분기, 연도주기, 검사주기,
                 허가상태, 설치장소, 도로명주소, 장치수, 통시, 공대, kca검토결과, 시기조정,
                 기준연도, skt본부, access담당, 품질개선팀)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)''',
                (req.year, 'SKT', req.허가번호.strip(), req.호출명칭, req.국종군, req.부서,
                 req.분기, req.연도주기, req.검사주기, req.허가상태, req.설치장소,
                 req.도로명주소, req.장치수, req.통시, req.공대, req.kca검토결과,
                 req.시기조정, req.기준연도, req.skt본부, req.access담당, req.품질개선팀))
            action = "inserted"
        c.commit(); c.close()
        return action
    action = await asyncio.to_thread(_insert)
    await asyncio.to_thread(_record_audit_log_sync, f"inspection_station_{action}", "inspection_targets",
                            f"{req.year}#{req.허가번호}", empno)
    return {"success": True, "action": action}

@app.post("/inspection/result/photo")
async def inspection_result_photo_upload(request: Request, year: int, 허가번호: str,
                                         file: UploadFile = File(...)):
    """수검 결과 사진 업로드."""
    import json as _j
    empno = await _verify_auth(request)
    ext = os.path.splitext(file.filename or "photo.jpg")[1].lower() or ".jpg"
    s3_key = f"inspection/photos/{year}/{허가번호}/{uuid.uuid4()}{ext}"
    content = await file.read()
    s3 = get_s3_client()
    s3.put_object(Bucket=S3_BUCKET_NAME, Key=s3_key, Body=content, ContentType=file.content_type or "image/jpeg")

    pk = f"{year}#{허가번호}"
    now = datetime.now(timezone.utc).isoformat()
    def _add_photo():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        existing = c.execute('SELECT 사진S3키 FROM inspection_results WHERE pk=?', (pk,)).fetchone()
        photos = _j.loads(existing['사진S3키']) if existing and existing['사진S3키'] else []
        photos.append(s3_key)
        c.execute('''INSERT INTO inspection_results (pk, year, 허가번호, 사진S3키, 입력자, 입력일시)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(pk) DO UPDATE SET 사진S3키=excluded.사진S3키,
            입력자=excluded.입력자, 입력일시=excluded.입력일시''',
            (pk, year, 허가번호, _j.dumps(photos), empno, now))
        c.commit(); c.close()
    await asyncio.to_thread(_add_photo)
    presigned = s3.generate_presigned_url('get_object', Params={'Bucket': S3_BUCKET_NAME, 'Key': s3_key}, ExpiresIn=3600)
    return {"success": True, "s3Key": s3_key, "url": presigned}

@app.delete("/inspection/result/photo")
async def inspection_result_photo_delete(request: Request, year: int, 허가번호: str, s3_key: str):
    """수검 결과 사진 삭제."""
    import json as _j
    await _verify_auth(request)
    if not s3_key.startswith("inspection/photos/"): raise HTTPException(400, "허용되지 않은 경로")
    s3 = get_s3_client()
    s3.delete_object(Bucket=S3_BUCKET_NAME, Key=s3_key)
    pk = f"{year}#{허가번호}"
    def _del_photo():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        existing = c.execute('SELECT 사진S3키 FROM inspection_results WHERE pk=?', (pk,)).fetchone()
        photos = _j.loads(existing['사진S3키']) if existing and existing['사진S3키'] else []
        photos = [p for p in photos if p != s3_key]
        c.execute('UPDATE inspection_results SET 사진S3키=? WHERE pk=?', (_j.dumps(photos), pk))
        c.commit(); c.close()
    await asyncio.to_thread(_del_photo)
    return {"success": True}

@app.get("/inspection/result/photo-url")
async def inspection_result_photo_url(request: Request, s3_key: str):
    """사진 presigned URL 생성."""
    await _verify_auth(request)
    if not s3_key.startswith("inspection/photos/"): raise HTTPException(400, "허용되지 않은 경로")
    s3 = get_s3_client()
    url = s3.generate_presigned_url('get_object', Params={'Bucket': S3_BUCKET_NAME, 'Key': s3_key}, ExpiresIn=3600)
    return {"url": url}

@app.get("/inspection/result/photo-data")
async def inspection_result_photo_data(request: Request, s3_key: str):
    """사진 바이너리 직접 반환 (Flutter web CORS 우회용)."""
    await _verify_auth(request)
    if not s3_key.startswith("inspection/photos/"): raise HTTPException(400, "허용되지 않은 경로")
    s3 = get_s3_client()
    try:
        obj = await asyncio.to_thread(
            lambda: s3.get_object(Bucket=S3_BUCKET_NAME, Key=s3_key))
        content_type = obj.get('ContentType', 'image/jpeg')
        data = await asyncio.to_thread(obj['Body'].read)
        return Response(content=data, media_type=content_type)
    except Exception as e:
        raise HTTPException(404, f"사진을 찾을 수 없습니다: {e}")

@app.get("/inspection/my-list/weeks")
async def inspection_my_list_weeks(request: Request, year: int, team: str = ""):
    """내 팀 수검예정주차 목록. 본부 관리자는 team 파라미터로 특정 팀 필터 가능."""
    empno = await _verify_auth(request)
    user_data = {}
    dev = _dev_users.get(empno)
    if dev:
        user_data = {"region": dev["region"], "team": dev["team"], "role": dev.get("role", "member")}
    else:
        dynamodb = get_dynamodb_resource()
        users_table = dynamodb.Table(DYNAMODB_TABLES["users"])
        user_item = await asyncio.to_thread(lambda: users_table.get_item(
            Key={"user_id": empno},
            ProjectionExpression="#r, team, #ro",
            ExpressionAttributeNames={"#r": "region", "#ro": "role"},
        ))
        user_data = user_item.get("Item", {})
    access_team = user_data.get("region", "").replace("Access담당", "").strip()
    품질팀 = user_data.get("team", "")
    is_dev = _dev_users.get(empno) is not None
    user_role = await asyncio.to_thread(_get_user_role_sync, empno)
    is_manager = user_role in ("admin", "manager")

    if is_manager:
        품질팀 = team

    if not is_dev and not access_team and not 품질팀 and not is_manager:
        return {"weeks": []}

    def _read_weeks():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        if is_manager and access_team and 품질팀:
            # 본부 관리자 + 팀 필터
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND access담당=? AND 품질개선팀=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, access_team, 품질팀)).fetchall()
        elif is_manager and access_team:
            # 본부 관리자 (팀 미선택)
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND access담당=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, access_team)).fetchall()
        elif is_dev and access_team and 품질팀:
            # 테스트 계정 + 팀 지정: 해당 팀 주차만
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND access담당=? AND 품질개선팀=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, access_team, 품질팀)).fetchall()
        elif is_dev and access_team:
            # 테스트 계정 + 팀 없음: 본부 전체
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND access담당=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, access_team)).fetchall()
        elif is_dev:
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year,)).fetchall()
        elif access_team and 품질팀:
            # 본부 관리자 + 팀 필터
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND access담당=? AND 품질개선팀=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, access_team, 품질팀)).fetchall()
        elif is_manager and access_team:
            # 본부 관리자 (팀 필터 없음 → 본부 전체)
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND access담당=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, access_team)).fetchall()
        elif access_team and 품질팀:
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND access담당=? AND 품질개선팀=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, access_team, 품질팀)).fetchall()
        elif access_team:
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND access담당=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, access_team)).fetchall()
        else:
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND 품질개선팀=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, 품질팀)).fetchall()
        c.close()
        return [r[0] for r in rows]
    weeks = await asyncio.to_thread(_read_weeks)
    return {"weeks": weeks}


@app.get("/inspection/my-list")
async def inspection_my_list(request: Request, year: int, week: str = "", team: str = ""):
    """내 팀 배정 수검 목록. 본부 관리자는 team 파라미터로 특정 팀 필터 가능."""
    empno = await _verify_auth(request)
    # Users 테이블에서 region(본부=access담당), team(품질개선팀), role 조회
    user_data = {}
    dev = _dev_users.get(empno)
    if dev:
        user_data = {"region": dev["region"], "team": dev["team"], "role": dev.get("role", "member")}
    else:
        dynamodb = get_dynamodb_resource()
        users_table = dynamodb.Table(DYNAMODB_TABLES["users"])
        user_item = await asyncio.to_thread(lambda: users_table.get_item(
            Key={"user_id": empno},
            ProjectionExpression="#r, team, #ro",
            ExpressionAttributeNames={"#r": "region", "#ro": "role"},
        ))
        user_data = user_item.get("Item", {})
    # region: "경북Access담당" → "경북" (inspection_schedules.access담당과 매칭)
    access_team = user_data.get("region", "").replace("Access담당", "").strip()
    품질팀 = user_data.get("team", "")
    is_dev = _dev_users.get(empno) is not None
    # role은 user_roles 테이블에서 조회 (권한 설정과 동일한 소스)
    user_role = await asyncio.to_thread(_get_user_role_sync, empno)
    is_manager = user_role in ("admin", "manager")

    # 본부 관리자: team 파라미터 있으면 해당 팀, 없으면 본부 전체
    if is_manager:
        품질팀 = team

    logger.info(f"my-list: empno={empno}, access_team='{access_team}', 품질팀='{품질팀}', is_dev={is_dev}, is_manager={is_manager}, role={user_role}")

    if not is_dev and not access_team and not 품질팀 and not is_manager:
        return {"items": [], "message": "팀 배정 없음"}

    # SQLite schedules + results 조인
    import json as _j
    def _read_my_list():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        _sel = ('SELECT s.*, t.위도, t.경도, t.설치장소 as t_설치장소, '
                'r.status, r.검사일, r.메모, r.철탑형태, r.사진S3키 '
                'FROM inspection_schedules s '
                'LEFT JOIN inspection_targets t ON s.허가번호=t.허가번호 AND t.year=s.year '
                'LEFT JOIN inspection_results r ON s.pk=r.pk ')
        params = []
        where_parts = []
        if is_manager and access_team and 품질팀:
            # 본부 관리자 + 팀 필터
            where_parts.append('s.year=? AND s.access담당=? AND s.품질개선팀=?')
            params.extend([year, access_team, 품질팀])
        elif is_manager and access_team:
            # 본부 관리자 (팀 미선택 → 본부 전체)
            where_parts.append('s.year=? AND s.access담당=?')
            params.extend([year, access_team])
        elif is_manager:
            # 수퍼어드민 또는 region 미설정 관리자 → 전체 연도 조회
            where_parts.append('s.year=?')
            params.extend([year])
        elif is_dev and access_team and 품질팀:
            where_parts.append('s.year=? AND s.access담당=? AND s.품질개선팀=?')
            params.extend([year, access_team, 품질팀])
        elif is_dev and access_team:
            where_parts.append('s.year=? AND s.access담당=?')
            params.extend([year, access_team])
        elif is_dev:
            where_parts.append('s.year=?')
            params.extend([year])
        elif access_team and 품질팀:
            where_parts.append('s.year=? AND s.access담당=? AND s.품질개선팀=?')
            params.extend([year, access_team, 품질팀])
        elif access_team:
            where_parts.append('s.year=? AND s.access담당=?')
            params.extend([year, access_team])
        else:
            where_parts.append('s.year=? AND s.품질개선팀=?')
            params.extend([year, 품질팀])
        if week:
            where_parts.append('s.수검예정주차=?')
            params.append(week)
        rows = c.execute(
            _sel + 'WHERE ' + ' AND '.join(where_parts), params).fetchall()
        c.close()
        items = []
        for row in rows:
            d = dict(row)
            if d.get('사진S3키'):
                try: d['사진S3키'] = _j.loads(d['사진S3키'])
                except Exception: d['사진S3키'] = []
            items.append(d)
        return items
    items = await asyncio.to_thread(_read_my_list)
    return {"items": items}


@app.get("/inspection/progress")
async def inspection_progress(request: Request, year: int):
    """본부별 수검 진행률 (전국 현황 대시보드용)."""
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB):
        return {"items": []}

    def _query():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        # 본부별 전체 수검대상 수
        total_rows = c.execute(
            'SELECT access담당, COUNT(*) as cnt FROM inspection_targets WHERE year=? GROUP BY access담당',
            (year,)).fetchall()
        # 본부별 실적 업로드 건수
        done_rows = c.execute(
            'SELECT region, COUNT(*) as cnt FROM inspection_results_raw WHERE year=? GROUP BY region',
            (year,)).fetchall()
        c.close()
        return total_rows, done_rows

    total_rows, done_rows = await asyncio.to_thread(_query)
    total_map = {(r['access담당'] or '미배정'): r['cnt'] for r in total_rows}
    done_map = {(r['region'] or '미배정'): r['cnt'] for r in done_rows}

    items = []
    for hdqt, total in sorted(total_map.items()):
        completed = done_map.get(hdqt, 0)
        items.append({
            "본부": hdqt,
            "total": total,
            "completed": completed,
            "percent": round(completed / total * 100, 1) if total > 0 else 0.0,
        })
    return {"items": items}


@app.get("/inspection/progress-by-result")
async def inspection_progress_by_result(request: Request, year: int):
    """검사결과(합격/불합격/부적합) 기준 전체 및 본부별 진도율."""
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB):
        return {"total": 0, "completed": 0, "percent": 0.0, "by_hdqt": []}

    DONE_VALUES = ('합격', '불합격', '부적합')

    def _query():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        irr_sub = """
            SELECT year, REPLACE(허가번호,'-','') AS 허가번호, MIN(합불여부) AS 합불여부
            FROM inspection_results_raw
            WHERE 합불여부 != ''
            GROUP BY year, REPLACE(허가번호,'-','')
        """
        rows = c.execute(f"""
            SELECT t.access담당,
                   COUNT(*) AS total,
                   SUM(CASE WHEN COALESCE(r.status, irr.합불여부) IN ('합격','불합격','부적합') THEN 1 ELSE 0 END) AS completed
            FROM inspection_targets t
            LEFT JOIN inspection_results r ON r.year = t.year AND r.허가번호 = t.허가번호
            LEFT JOIN ({irr_sub}) irr ON irr.year = t.year AND irr.허가번호 = REPLACE(t.허가번호,'-','')
            WHERE t.year = ?
            GROUP BY t.access담당
        """, (year,)).fetchall()
        c.close()
        return rows

    rows = await asyncio.to_thread(_query)
    by_hdqt = []
    grand_total = 0
    grand_completed = 0
    for r in rows:
        hdqt = r['access담당'] or '미배정'
        total = r['total'] or 0
        completed = r['completed'] or 0
        grand_total += total
        grand_completed += completed
        by_hdqt.append({
            "본부": hdqt,
            "total": total,
            "completed": completed,
            "percent": round(completed / total * 100, 1) if total > 0 else 0.0,
        })
    by_hdqt.sort(key=lambda x: x['본부'])
    return {
        "total": grand_total,
        "completed": grand_completed,
        "percent": round(grand_completed / grand_total * 100, 1) if grand_total > 0 else 0.0,
        "by_hdqt": by_hdqt,
    }


class InspectionReportReq(BaseModel):
    year: int
    허가번호_list: list = []   # 빈 리스트이면 필터 기반 전체 조회
    sheet: str = "all"
    filters: dict = {}
    search: str = ""
    addr: str = ""
    schedule_yn: str = ""
    sheet_title: str = ""     # 시트명 (예: "남구_동대구(78)_김성욱")

@app.post("/inspection/export-inspection-report")
async def inspection_export_report(request: Request, req: InspectionReportReq):
    """검사내역서 Excel 생성 (정확한 형식 일치)."""
    await _verify_auth(request)
    if not HAS_OPENPYXL:
        raise HTTPException(503, "openpyxl 미설치")
    if not os.path.exists(_INSP_DB):
        raise HTTPException(404, "수검 데이터 없음")

    def _build():
        import openpyxl
        from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
        from openpyxl.utils import get_column_letter

        # ── 1. 대상 목록 조회 ────────────────────────────────
        conn_i = sqlite3.connect(_INSP_DB, timeout=60); conn_i.row_factory = sqlite3.Row
        if req.허가번호_list:
            ph = ','.join('?' * len(req.허가번호_list))
            targets = conn_i.execute(
                f'SELECT * FROM inspection_targets WHERE year=? AND 허가번호 IN ({ph})',
                [req.year] + list(req.허가번호_list)).fetchall()
        else:
            where_sql, params = _build_insp_where(
                req.year, req.sheet, req.filters, req.search, req.addr, req.schedule_yn)
            targets = conn_i.execute(
                f'SELECT * FROM inspection_targets WHERE {where_sql} ORDER BY id',
                params).fetchall()
        conn_i.close()
        if not targets:
            raise ValueError("조회된 수검 대상이 없습니다")

        # ── 2. DS 데이터 일괄 조회 ───────────────────────────
        # 허가번호 정규화: 하이픈 포함/미포함 양쪽 버전 모두 조회
        _raw_nos = [t['허가번호'] for t in targets]
        license_nos = list({n for raw in _raw_nos for n in (raw, raw.replace('-', ''))})
        # DS 결과를 원본 허가번호로 역매핑하기 위한 dict
        _norm_to_raw = {}
        for raw in _raw_nos:
            _norm_to_raw[raw] = raw
            _norm_to_raw[raw.replace('-', '')] = raw
        ph = ','.join('?' * len(license_nos))

        ds_장치_map: dict = {}    # 허가번호 → list of 장치 rows
        ds_안테나_map: dict = {}  # 허가번호 → list of 안테나 rows (장치번호 정렬)
        ds_전파_map: dict = {}    # 허가번호 → list of 전파형식 rows
        ds_주파수_map: dict = {}  # 허가번호 → formatted string
        ds_일반_map: dict = {}    # 허가번호 → 일반사항 row (공용화 등)

        if os.path.exists(_DS_DETAIL_DB):
            conn_d = sqlite3.connect(_DS_DETAIL_DB); conn_d.row_factory = sqlite3.Row

            def _raw(hn):
                return _norm_to_raw.get(hn, hn)

            # 일반사항: 공용화구분코드명
            rows = conn_d.execute(
                f'SELECT 허가번호, 공용화구분코드명 FROM ds_일반사항 WHERE 허가번호 IN ({ph})',
                license_nos).fetchall()
            for r in rows:
                ds_일반_map[_raw(r['허가번호'])] = dict(r)

            # 장치: 허가번호별 전체 행 (장치번호 오름차순)
            rows = conn_d.execute(
                f'SELECT 허가번호, 장치번호, 기기일련번호, 형식검정번호 FROM ds_장치 WHERE 허가번호 IN ({ph}) ORDER BY 허가번호, CAST(장치번호 AS INTEGER)',
                license_nos).fetchall()
            for r in rows:
                ds_장치_map.setdefault(_raw(r['허가번호']), []).append(dict(r))

            # 안테나: 허가번호별 전체 행 (장치번호 오름차순)
            rows = conn_d.execute(
                f'SELECT * FROM ds_안테나 WHERE 허가번호 IN ({ph}) ORDER BY 허가번호, CAST(장치번호 AS INTEGER)',
                license_nos).fetchall()
            for r in rows:
                ds_안테나_map.setdefault(_raw(r['허가번호']), []).append(dict(r))

            # 전파형식: 허가번호별 전체 행 (장치번호 오름차순)
            rows = conn_d.execute(
                f'SELECT 허가번호, 장치번호, 공중선전력 FROM ds_전파형식 WHERE 허가번호 IN ({ph}) ORDER BY 허가번호, CAST(장치번호 AS INTEGER)',
                license_nos).fetchall()
            for r in rows:
                ds_전파_map.setdefault(_raw(r['허가번호']), []).append(dict(r))

            # 주파수: TX/RX별 중복제거 후 합산
            rows = conn_d.execute(
                f'SELECT 허가번호, 주파수, 송수신구분 FROM ds_주파수 WHERE 허가번호 IN ({ph}) ORDER BY id',
                license_nos).fetchall()
            def _freq_int(v):
                """주파수 값 정수화: 879.0→879, 1732.5→1732.5"""
                try:
                    f = float(v)
                    return str(int(f)) if f == int(f) else str(f)
                except (ValueError, TypeError):
                    return v

            _freq_tmp: dict = {}
            for r in rows:
                hn = _raw(r['허가번호'])
                if hn not in _freq_tmp:
                    _freq_tmp[hn] = {'TX': [], 'RX': [], 'ALL': []}
                구분 = str(r['송수신구분'] or '').strip().upper()
                주파수 = _freq_int(str(r['주파수'] or '').strip())
                if not 주파수:
                    continue
                if 'TX' in 구분 or '송신' in 구분:
                    if 주파수 not in _freq_tmp[hn]['TX']:
                        _freq_tmp[hn]['TX'].append(주파수)
                elif 'RX' in 구분 or '수신' in 구분:
                    if 주파수 not in _freq_tmp[hn]['RX']:
                        _freq_tmp[hn]['RX'].append(주파수)
                else:
                    if 주파수 not in _freq_tmp[hn]['ALL']:
                        _freq_tmp[hn]['ALL'].append(주파수)
            for hn, fmap in _freq_tmp.items():
                tx_vals = fmap['TX'] or fmap['ALL']
                rx_vals = fmap['RX'] or fmap['ALL']
                # TX와 RX가 동일하면 TRX로 표시
                if tx_vals and rx_vals and tx_vals == rx_vals:
                    ds_주파수_map[hn] = f"TRX : {','.join(tx_vals)}"
                else:
                    parts = []
                    if tx_vals: parts.append(f"TX : {','.join(tx_vals)}")
                    if rx_vals: parts.append(f"RX : {','.join(rx_vals)}")
                    # TX 1개 + RX 1개면 한 줄로 표시
                    if len(tx_vals) <= 1 and len(rx_vals) <= 1:
                        ds_주파수_map[hn] = '  '.join(parts)
                    else:
                        ds_주파수_map[hn] = '\n'.join(parts)

            conn_d.close()

        # ── 3. cert_cache에서 zpcode 조회 ──
        # 우선순위: 1) 기기일련번호 매칭 → 2) 운용 상태 → 3) 호출명칭 매칭 → 4) fallback
        zpcode_by_eqp: dict = {}    # key: "허가번호|기기일련번호" → zpcode
        zpcode_by_active: dict = {} # key: "허가번호" → zpcode (zpprac1=운용)
        zpcode_by_name: dict = {}   # key: "허가번호|호출명칭" → zpcode
        zpcode_fallback: dict = {}  # key: "허가번호" → zpcode
        def _norm_serno(v):
            return re.sub(r'[^0-9A-Za-z]', '', str(v or '').upper())
        if _cert_cache_db_path and os.path.exists(_cert_cache_db_path):
            import sqlite3 as _sq2
            c2 = _sq2.connect(_cert_cache_db_path)
            rows = c2.execute(
                f'SELECT TRIM(zpwino), TRIM(zpwina), zpcode, TRIM(eqp_ser_no), TRIM(COALESCE(zpprac1,"")) FROM cert WHERE TRIM(zpwino) IN ({ph})',
                license_nos).fetchall()
            for r in rows:
                k_raw = str(r[0] or '').strip()
                k = k_raw.replace('-', '')
                name = str(r[1] or '').strip()
                code = str(r[2] or '').strip()
                eqp = str(r[3] or '').strip()
                status = str(r[4] or '').strip()
                if not k or not code:
                    continue
                # 1) 기기일련번호 매칭
                if eqp:
                    zpcode_by_eqp[f"{k}|{eqp}"] = code
                    eqp_norm = _norm_serno(eqp)
                    if eqp_norm:
                        zpcode_by_eqp[f"{k}|{eqp_norm}"] = code
                # 2) 운용 상태
                if '운용' in status and k not in zpcode_by_active:
                    zpcode_by_active[k] = code
                # 3) 호출명칭 매칭
                zpcode_by_name[f"{k}|{name}"] = code
                # 4) fallback
                if k not in zpcode_fallback:
                    zpcode_fallback[k] = code
            c2.close()

        # ── 4. Excel 생성 ────────────────────────────────────
        wb = openpyxl.Workbook()
        ws = wb.active
        sheet_title = req.sheet_title or f"{req.year}년_검사내역서"
        ws.title = sheet_title[:31]  # Excel 시트명 최대 31자

        # 스타일 정의 (샘플과 일치)
        _font_base = Font(name='맑은 고딕', size=11)
        _font_base10 = Font(name='맑은 고딕', size=10)  # I,J열 (기기명칭/일련번호)
        _font_bold = Font(name='맑은 고딕', size=9, bold=True)
        _font_title = Font(name='맑은 고딕', size=18, bold=True)
        _font_red   = Font(name='맑은 고딕', size=11, color='FFFF0000')

        _fill_yellow  = PatternFill('solid', fgColor='FFFFFF00')
        _fill_hdr_lt  = PatternFill('solid', fgColor='FFBFBFBF')  # 헤더 회색
        _fill_none    = PatternFill(fill_type=None)

        _thin_side = Side(style='thin')
        _thin_border = Border(left=_thin_side, right=_thin_side,
                              top=_thin_side, bottom=_thin_side)
        _med_side  = Side(style='medium')
        _med_border = Border(left=_med_side, right=_med_side,
                             top=_med_side, bottom=_med_side)

        _al_center = Alignment(horizontal='center', vertical='center', wrap_text=True)
        _al_left   = Alignment(horizontal='left',   vertical='center', wrap_text=True)
        _al_shrink = Alignment(horizontal='center', vertical='center', wrap_text=False, shrink_to_fit=True)  # B,C열

        COL_WIDTHS = {
            1: 8.125, 2: 13.0,  3: 9.0,   4: 20.375, 5: 28.5,
            6: 9.0,   7: 27.25, 8: 9.0,   9: 35.125, 10: 20.875,
            11: 10.5, 12: 22.75,13: 9.0,  14: 20.25, 15: 19.0,
            16: 13.0, 17: 14.25,18: 13.625,19: 11.125,20: 44.125,
        }
        for col_idx, w in COL_WIDTHS.items():
            ws.column_dimensions[get_column_letter(col_idx)].width = w

        def _set(r, c, val, font=None, fill=None, border=None, align=None):
            cell = ws.cell(row=r, column=c, value=val)
            if font:   cell.font   = font
            if fill:   cell.fill   = fill
            if border: cell.border = border
            if align:  cell.alignment = align
            return cell

        # ── 행 1: 제목 ──────────────────────────────────────
        ws.row_dimensions[1].height = 39.95
        ws.merge_cells('A1:T1')
        _set(1, 1, '검사신청 접수',
             font=_font_title, align=_al_center, border=_med_border)

        # ── 행 2-3: 이중 헤더 ───────────────────────────────
        ws.row_dimensions[2].height = 16.5
        ws.row_dimensions[3].height = 16.5

        _HDR_FONT = Font(name='맑은 고딕', size=9, bold=True)
        _HDR_FILL = PatternFill('solid', fgColor='BFBFBF')

        # 병합 전 모든 헤더 셀에 스타일 적용 (병합 후 누락 테두리 방지)
        for _r in (2, 3):
            for _c in range(1, 21):  # A~T (20열)까지만
                _cell = ws.cell(row=_r, column=_c)
                _cell.font = _HDR_FONT
                _cell.fill = _HDR_FILL
                _cell.border = _thin_border
                _cell.alignment = _al_center

        def _hdr(r, c, val):
            _set(r, c, val, font=_HDR_FONT, fill=_HDR_FILL,
                 border=_thin_border, align=_al_center)

        # 단순 병합 헤더 (2행-3행 병합)
        for col, label in [(1,'순번'),(2,'(허가자료)\n설치형태'),(3,'tosi_code'),
                           (4,'허가번호'),(5,'name'),(6,'검사종류'),
                           (7,'특이사항'),(11,'공중선전력'),(12,'허가주파수\n(채널)'),
                           (17,'공용화/환경친화'),(18,'수수료'),(19,'검사지'),
                           (20,'설치장소')]:
            ws.merge_cells(start_row=2, start_column=col, end_row=3, end_column=col)
            _hdr(2, col, label)

        # 장치사항 그룹 (H2:J2)
        ws.merge_cells('H2:J2'); _hdr(2, 8, '장치사항')
        for col, lbl in [(8,'장치수'),(9,'기기명칭1'),(10,'기기일련번호1')]:
            _hdr(3, col, lbl)

        # 공중선 그룹 (M2:P2)
        ws.merge_cells('M2:P2'); _hdr(2, 13, '공중선')
        for col, lbl in [(13,'장치'),(14,'형식'),(15,'기수'),(16,'이득')]:
            _hdr(3, col, lbl)

        # ── 허가번호 하이픈 포맷 함수 (2-4-2-7) ───────────────
        def _fmt_hn(hn_raw):
            hn = str(hn_raw or '').replace('-', '')
            if len(hn) == 15:
                return f"{hn[:2]}-{hn[2:6]}-{hn[6:8]}-{hn[8:]}"
            return hn_raw  # 형식 안 맞으면 원본 그대로

        # ── 데이터 행 ────────────────────────────────────────
        _LINE_HEIGHT = 13.5  # 1줄 높이
        max_tosi_line_len = 0
        for seq, t in enumerate(targets, 1):
            r = seq + 3
            hn = t['허가번호']
            hn_norm = str(hn or '').replace('-', '')

            # DS 데이터 조합
            jt_list  = ds_장치_map.get(hn, [])
            ant_list = ds_안테나_map.get(hn, [])
            pwr_list = ds_전파_map.get(hn, [])
            freq     = ds_주파수_map.get(hn, '')
            일반     = ds_일반_map.get(hn, {})

            def _join_unique(lst, key):
                """unique 값만 순서 유지하며 줄바꿈으로 결합"""
                seen = set(); result = []
                for row in lst:
                    v = str(row.get(key) or '').strip()
                    if v and v not in seen:
                        seen.add(v); result.append(v)
                return '\n'.join(result)

            def _join_all(lst, key, as_int=False):
                """모든 값을 순서대로 줄바꿈으로 결합 (중복 유지)"""
                result = []
                for row in lst:
                    v = str(row.get(key) or '').strip()
                    if as_int and v:
                        try:
                            f = float(v)
                            v = str(int(f)) if f == int(f) else str(f)
                        except (ValueError, TypeError):
                            pass
                    result.append(v)
                return '\n'.join(result)

            # 장치수: 해당 허가번호의 장치번호 고유값 갯수
            장치수 = ''
            if jt_list:
                unique_jnos = set(str(j.get('장치번호') or '').strip() for j in jt_list)
                unique_jnos.discard('')
                장치수 = str(len(unique_jnos)) if unique_jnos else str(len(jt_list))

            # 기기명칭/기기일련번호: 기기일련번호 기준 unique (중복 장비 제거)
            _seen_serial: set = set()
            unique_장치: list = []
            for j in jt_list:
                serial = str(j.get('기기일련번호') or '').strip()
                if serial and serial not in _seen_serial:
                    _seen_serial.add(serial)
                    unique_장치.append(j)
                elif not serial:
                    unique_장치.append(j)  # 일련번호 없는 건 모두 포함
            기기명칭1    = _join_all(unique_장치, '형식검정번호')  # 일련번호 unique 행에 맞춰 (중복 형식도 유지)
            기기일련번호1 = _join_unique(unique_장치, '기기일련번호')  # 일련번호는 중복 제거

            # 공중선전력: unique
            # 공중선전력: unique, 정수값 표시 (소수점 제거)
            _pwr_seen = set(); _pwr_result = []
            for _pw in pwr_list:
                v = str(_pw.get('공중선전력') or '').strip()
                if v:
                    try:
                        v = str(int(float(v)))
                    except (ValueError, TypeError):
                        pass
                    if v not in _pwr_seen:
                        _pwr_seen.add(v); _pwr_result.append(v)
            공중선전력 = '\n'.join(_pwr_result)

            # 공중선일련번호 기준 중복 제거 → 형식/기수/이득 행수 일치
            _seen_ant: set = set()
            deduped_ant: list = []
            for _ant in ant_list:
                _k = str(_ant.get('공중선일련번호') or '').strip()
                if not _k or _k not in _seen_ant:
                    _seen_ant.add(_k); deduped_ant.append(_ant)

            _callname = str(t['호출명칭'] or '').strip()
            # tosi_code 우선순위:
            # 1) DS 기기일련번호별 cert(eqp_ser_no) 매칭 결과를 다건(줄바꿈)으로 반영
            # 2) 매칭값이 전혀 없을 때만 운용/호출명칭/fallback 단건 적용
            tosi_code = ''
            if unique_장치:
                _tosi_lines = []
                _has_serial_matched = False
                for _uj in unique_장치:
                    _eqp = str(_uj.get('기기일련번호') or '').strip()
                    _code = ''
                    if _eqp:
                        _code = zpcode_by_eqp.get(f"{hn_norm}|{_eqp}", '')
                        if not _code:
                            _eqp_norm = _norm_serno(_eqp)
                            if _eqp_norm:
                                _code = zpcode_by_eqp.get(f"{hn_norm}|{_eqp_norm}", '')
                    if _code:
                        _has_serial_matched = True
                    _tosi_lines.append(_code)
                if _has_serial_matched:
                    tosi_code = '\n'.join(_tosi_lines)
            if not tosi_code:
                tosi_code = zpcode_by_active.get(hn_norm, '')
            if not tosi_code:
                tosi_code = zpcode_by_name.get(f"{hn_norm}|{_callname}", '')
            if not tosi_code:
                tosi_code = zpcode_fallback.get(hn_norm, '')
            if tosi_code:
                for _line in str(tosi_code).split('\n'):
                    _line_len = len(_line.strip())
                    if _line_len > max_tosi_line_len:
                        max_tosi_line_len = _line_len
            설치형태     = ant_list[0].get('공중선주설치형태명', '') if ant_list else ''
            공중선장치   = _join_all(deduped_ant, '장치번호')
            # 공중선형식: SECTOR만 괄호 안 값 추출, 나머지는 그대로
            _ant_형식_vals = []
            for _a in deduped_ant:
                v = str(_a.get('공중선형식명') or '').strip()
                if 'SECTOR' in v.upper() and '(' in v:
                    _ant_형식_vals.append('SECTOR')
                else:
                    _ant_형식_vals.append(v)
            공중선형식 = '\n'.join(_ant_형식_vals)
            기수         = _join_all(deduped_ant, '기')
            이득         = _join_all(deduped_ant, '이득', as_int=True)
            공용화       = str(일반.get('공용화구분코드명') or '').strip() or '공란'

            # 설치장소: DS 설치장소 사용, 없으면 target의 설치장소
            설치장소 = t['설치장소'] or ''

            # 검사지: 주소에서 두 번째 토큰만 추출 (화성시, 남구 등)
            검사지 = ''
            _addr_for_area = 설치장소 or t.get('도로명주소') or ''
            _addr_parts = _addr_for_area.split()
            if len(_addr_parts) >= 2:
                검사지 = _addr_parts[1]

            row_data = [
                seq,                       # A: 순번
                설치형태,                   # B: 설치형태
                tosi_code,                 # C: tosi_code
                _fmt_hn(hn),               # D: 허가번호 (하이픈 포맷)
                t['호출명칭'] or '',        # E: name
                '정기',                    # F: 검사종류 (항상 '정기')
                '',                        # G: 특이사항
                장치수,                    # H: 장치수 (장치번호 max)
                기기명칭1,                  # I: 기기명칭1 (일련번호 unique)
                기기일련번호1,              # J: 기기일련번호1 (unique)
                공중선전력,                 # K: 공중선전력 (unique)
                freq,                      # L: 허가주파수(채널)
                공중선장치,                 # M: 공중선 장치
                공중선형식,                 # N: 공중선 형식
                기수,                      # O: 기수
                이득,                      # P: 이득
                공용화,                    # Q: 공용화/환경친화
                '',                        # R: 수수료
                검사지,                    # S: 검사지
                설치장소,                  # T: 설치장소
            ]
            # 행높이: 모든 셀 중 최대 줄 수 × 13.5
            max_lines = 1
            for _v in row_data:
                if isinstance(_v, str) and '\n' in _v:
                    _lc = _v.count('\n') + 1
                    if _lc > max_lines:
                        max_lines = _lc
            ws.row_dimensions[r].height = _LINE_HEIGHT * max_lines

            for c_idx, val in enumerate(row_data, 1):
                if c_idx == 2:  # B열: 빨간 글씨 + 노란 배경 + 셀에 맞춤
                    _set(r, c_idx, val, font=_font_red, fill=_fill_yellow,
                         border=_thin_border, align=_al_shrink)
                elif c_idx == 3:  # C열(tosi_code): 10pt + 줄바꿈 표시
                    _set(r, c_idx, val, font=_font_base10,
                         border=_thin_border, align=_al_center)
                elif c_idx in (7, 20):  # G(특이사항), T(설치장소): 왼쪽 정렬
                    _set(r, c_idx, val, font=_font_base,
                         border=_thin_border, align=_al_left)
                elif c_idx in (9, 10):  # I(기기명칭), J(기기일련번호): 10pt
                    _set(r, c_idx, val, font=_font_base10,
                         border=_thin_border, align=_al_center)
                else:
                    _set(r, c_idx, val, font=_font_base,
                         border=_thin_border, align=_al_center)

        # C열(tosi_code) 너비 자동 조정: 기본 9.0 유지, 내용 길이에 따라 확장(최대 22)
        if max_tosi_line_len > 0:
            ws.column_dimensions['C'].width = max(9.0, min(22.0, max_tosi_line_len * 1.1 + 1.5))

        # Excel 자동 필터 설정 (3행 하위 헤더 기준, 샘플과 동일)
        last_row = len(targets) + 3
        ws.auto_filter.ref = f"A3:T{last_row}"

        buf = io.BytesIO()
        wb.save(buf); buf.seek(0)
        return buf.getvalue()

    try:
        data = await asyncio.to_thread(_build)
    except ValueError as ve:
        raise HTTPException(400, str(ve))

    fname = f"검사내역서_{req.year}년_{req.sheet_title or '전체'}.xlsx"
    from urllib.parse import quote as _q
    return Response(
        content=data,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{_q(fname)}"}
    )


# ============================================================
# 워크플로우 Phase 3: 검사내역서 발급 + 접수 트래킹
# ============================================================

class InspectionReportGenerateReq(BaseModel):
    schedule_pks: list[str]
    sheet_title: str = ""


@app.post("/inspection/report/generate")
async def inspection_report_generate(request: Request, req: InspectionReportGenerateReq):
    """다중 schedule → 검사내역서 즉시 다운로드.

    - 발급 자체는 워크플로우 상태와 무관하게 허용 (REGISTERED/PRE_CHECK_DONE/SUBMITTED/INSPECTED 등 모두)
    - 단, 상태 전환은 전환 가능한 건(_wf_can_transition)에 한해서만 REPORT_ISSUED로 이동
      → 이미 SUBMITTED/INSPECTED 같이 진행된 건은 그 상태 유지 (역행 방지)
    - report_issued_at/by는 발급된 모든 건에 항상 갱신 (재발급 추적)
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if not req.schedule_pks:
        raise HTTPException(400, "schedule_pks 비어있음")

    def _load():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        ph = ','.join('?' * len(req.schedule_pks))
        rows = c.execute(
            f'SELECT pk, year, 허가번호, workflow_status FROM inspection_schedules '
            f'WHERE pk IN ({ph})',
            list(req.schedule_pks)).fetchall()
        c.close()
        return [dict(r) for r in rows]

    scheds = await asyncio.to_thread(_load)
    if not scheds:
        raise HTTPException(404, "해당 일정 없음")

    # year 추출 — 묶음 내 동일 가정 (다르면 차단)
    years = {s['year'] for s in scheds}
    if len(years) > 1:
        raise HTTPException(400, f"여러 연도 혼합 불가: {sorted(years)}")
    year = scheds[0]['year']
    허가번호_list = [s['허가번호'] for s in scheds]

    # 기존 빌더에 위임
    inner_req = InspectionReportReq(
        year=year,
        허가번호_list=허가번호_list,
        sheet_title=req.sheet_title,
    )
    response = await inspection_export_report(request, inner_req)

    # 빌더 성공 후 — 발급 시각 갱신 + 가능한 건만 상태 전환
    def _transition():
        now = datetime.now(timezone.utc).isoformat()
        c = sqlite3.connect(_INSP_DB, timeout=60)
        transitioned = 0
        for s in scheds:
            cur = s.get('workflow_status') or WF_REGISTERED
            can_transition = _wf_can_transition(cur, WF_REPORT_ISSUED, role)
            if can_transition:
                c.execute(
                    'UPDATE inspection_schedules SET workflow_status=?, '
                    'status_updated_at=?, status_updated_by=?, '
                    'report_issued_at=?, report_issued_by=? WHERE pk=?',
                    (WF_REPORT_ISSUED, now, empno, now, empno, s['pk']))
                _wf_record_log_sync(c, s['pk'], cur, WF_REPORT_ISSUED, empno,
                                  f"검사내역서 발급 (묶음 {len(scheds)}건)")
                transitioned += 1
            else:
                # 상태는 유지하되 발급 시각만 갱신 (재발급 추적)
                c.execute(
                    'UPDATE inspection_schedules SET '
                    'report_issued_at=?, report_issued_by=? WHERE pk=?',
                    (now, empno, s['pk']))
        c.commit(); c.close()
        return transitioned

    transitioned = await asyncio.to_thread(_transition)
    await asyncio.to_thread(_record_audit_log_sync,
                           "inspection_report_generate", "inspection_schedule",
                           f"count={len(scheds)},transitioned={transitioned}", empno)
    return response


class InspectionSubmissionReq(BaseModel):
    submission_no: str
    submitted_at: str = ""    # ISO; 비면 서버 현재시각


@app.patch("/inspection/schedule/{pk:path}/submission")
async def inspection_schedule_submission(pk: str, request: Request, req: InspectionSubmissionReq):
    """전파관리소 접수번호 입력 → REPORT_ISSUED → SUBMITTED 전환."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if not req.submission_no.strip():
        raise HTTPException(400, "접수번호 필요")

    submitted_at = req.submitted_at.strip() or datetime.now(timezone.utc).isoformat()

    def _save():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        row = c.execute(
            'SELECT workflow_status FROM inspection_schedules WHERE pk=?', (pk,)).fetchone()
        if not row:
            c.close()
            return False, "일정 없음"
        cur = row[0] or WF_REGISTERED
        if not _wf_can_transition(cur, WF_SUBMITTED, role):
            c.close()
            return False, f"전환 불가: {cur} → SUBMITTED"
        now = datetime.now(timezone.utc).isoformat()
        c.execute(
            'UPDATE inspection_schedules SET workflow_status=?, '
            'status_updated_at=?, status_updated_by=?, '
            'submission_no=?, submitted_at=? WHERE pk=?',
            (WF_SUBMITTED, now, empno, req.submission_no.strip(), submitted_at, pk))
        _wf_record_log_sync(c, pk, cur, WF_SUBMITTED, empno,
                          f"전파관리소 접수: {req.submission_no.strip()}")
        c.commit(); c.close()
        return True, "ok"

    ok, msg = await asyncio.to_thread(_save)
    if not ok:
        raise HTTPException(400, msg)
    await asyncio.to_thread(_record_audit_log_sync,
                           "inspection_submission", "inspection_schedule", pk, empno)
    return {"success": True}


class InspectionSubmissionBulkReq(BaseModel):
    schedule_pks: list[str]
    submission_no: str
    submitted_at: str = ""


@app.post("/inspection/schedule/submission-bulk")
async def inspection_schedule_submission_bulk(request: Request, req: InspectionSubmissionBulkReq):
    """접수번호 일괄 입력 — 다중 schedule_pk에 동일 접수번호 적용 + SUBMITTED 전환.

    - 전환 가능한 건만 처리 (admin 외엔 REPORT_ISSUED → SUBMITTED만 통과)
    - 나머지는 results에 사유 포함하여 반환
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if not req.schedule_pks:
        raise HTTPException(400, "schedule_pks 비어있음")
    sub_no = req.submission_no.strip()
    if not sub_no:
        raise HTTPException(400, "접수번호 필요")
    submitted_at = req.submitted_at.strip() or datetime.now(timezone.utc).isoformat()

    def _save():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        now = datetime.now(timezone.utc).isoformat()
        results = []
        for pk in req.schedule_pks:
            row = c.execute(
                'SELECT workflow_status FROM inspection_schedules WHERE pk=?', (pk,)).fetchone()
            if not row:
                results.append({"pk": pk, "ok": False, "msg": "일정 없음"})
                continue
            cur = row[0] or WF_REGISTERED
            if not _wf_can_transition(cur, WF_SUBMITTED, role):
                results.append({"pk": pk, "ok": False, "msg": f"전환 불가: {cur}"})
                continue
            c.execute(
                'UPDATE inspection_schedules SET workflow_status=?, '
                'status_updated_at=?, status_updated_by=?, '
                'submission_no=?, submitted_at=? WHERE pk=?',
                (WF_SUBMITTED, now, empno, sub_no, submitted_at, pk))
            _wf_record_log_sync(c, pk, cur, WF_SUBMITTED, empno,
                              f"전파관리소 접수(일괄): {sub_no}")
            results.append({"pk": pk, "ok": True, "msg": "ok"})
        c.commit(); c.close()
        return results

    results = await asyncio.to_thread(_save)
    success = sum(1 for r in results if r["ok"])
    await asyncio.to_thread(_record_audit_log_sync,
                           "inspection_submission_bulk", "inspection_schedule",
                           f"count={len(req.schedule_pks)},no={sub_no}", empno)
    return {"success": True, "total": len(results), "succeeded": success, "results": results}


class InspAddFromStagingReq(BaseModel):
    year: int
    허가번호: str


@app.post("/inspection/add-from-staging")
async def inspection_add_from_staging(request: Request, req: InspAddFromStagingReq):
    """스테이징에서 단건 허가번호를 검색해 inspection_targets에 추가 (관리자/매니저 전용).
    - admin(최고관리자): 본부 무관
    - manager(본부관리자): 자신의 본부(access담당) 대상만 추가 가능
    - kca검토결과='대상 추가' 로 삽입
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    if not os.path.exists(_INSP_DB):
        raise HTTPException(400, "DB 없음")

    # manager이면 자기 본부(access담당) 확인
    manager_access = ""
    if role == "manager":
        dynamodb = get_dynamodb_resource()
        users_table = dynamodb.Table(DYNAMODB_TABLES["users"])
        user_item = await asyncio.to_thread(lambda: users_table.get_item(
            Key={"user_id": empno},
            ProjectionExpression="#r",
            ExpressionAttributeNames={"#r": "region"},
        ))
        # region: "경북Access담당" → "경북"
        manager_access = user_item.get("Item", {}).get("region", "").replace("Access담당", "").strip()
        if not manager_access:
            raise HTTPException(403, "본부 정보가 설정되지 않았습니다")

    def _do_add():
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        conn.row_factory = sqlite3.Row
        try:
            # 스테이징에서 조회
            row = conn.execute(
                'SELECT * FROM inspection_targets_staging WHERE year=? AND 허가번호=? LIMIT 1',
                (req.year, req.허가번호)
            ).fetchone()
            if not row:
                raise ValueError(f"스테이징에서 찾을 수 없습니다: {req.허가번호}")

            d = dict(row)

            # manager 본부 검증
            if manager_access and d.get("access담당", "") != manager_access:
                raise PermissionError(f"본부 불일치: 대상={d.get('access담당')}, 내 본부={manager_access}")

            # 이미 targets에 있는지 확인
            exists = conn.execute(
                'SELECT id FROM inspection_targets WHERE year=? AND 허가번호=? LIMIT 1',
                (req.year, req.허가번호)
            ).fetchone()
            if exists:
                raise ValueError(f"이미 수검 대상에 등록된 허가번호입니다: {req.허가번호}")

            cols = 'year,sheet,pnu_code,허가번호,호출명칭,국종군,부서,분기,연도주기,검사주기,허가상태,설치장소,도로명주소,장치수,통시,공대,kca검토결과,시기조정,기준연도,skt본부,access담당,품질개선팀,검사종류'
            ph = ','.join(['?'] * len(cols.split(',')))

            vals = (
                d.get('year'), d.get('sheet'), d.get('pnu_code'),
                d.get('허가번호'), d.get('호출명칭'), d.get('국종군'), d.get('부서'),
                d.get('분기'), d.get('연도주기'), d.get('검사주기'), d.get('허가상태'),
                d.get('설치장소'), d.get('도로명주소'), d.get('장치수'),
                d.get('통시'), d.get('공대'),
                '대상 추가',  # kca검토결과 강제 설정
                d.get('시기조정'), d.get('기준연도'), d.get('skt본부'),
                d.get('access담당'), d.get('품질개선팀'), d.get('검사종류'),
            )
            conn.execute(f'INSERT INTO inspection_targets ({cols}) VALUES ({ph})', vals)
            # 스테이징에서 제거
            conn.execute(
                'DELETE FROM inspection_targets_staging WHERE year=? AND 허가번호=?',
                (req.year, req.허가번호)
            )
            conn.commit()
            return dict(d) | {"kca검토결과": "대상 추가"}
        finally:
            conn.close()

    try:
        result = await asyncio.to_thread(_do_add)
    except ValueError as ve:
        raise HTTPException(400, str(ve))
    except PermissionError as pe:
        raise HTTPException(403, str(pe))

    return {"success": True, "item": result}


# ============================================================
# Inspection Results RAW DATA (검사실적 RAW 데이터 관리)
# ============================================================

# Excel 헤더 → DB 컬럼 매핑
_IRR_HEADER_MAP = {
    # Col 0: 주차 (변형: 주차별, 주별)
    "주차": "주차별",
    "주차별": "주차별",
    "주별": "주차별",
    "주차구별": "주차별",
    # Col 1
    "월": "월",
    # Col 2
    "구분": None,  # skip
    # (강남 전용) 연도 컬럼 — skip
    "연도": None,
    # Col 3-4
    "SKT본부": "skt본부",
    "ONS 본부": "_ons본부",
    "ONS본부": "_ons본부",
    # Col 5-8
    "허가번호": "허가번호",
    "통합시설코드": "통합시설코드",
    "통합시설코": "통합시설코드",  # 인천 (잘림)
    "호출명칭": "호출명칭",
    "주소": "주소",
    # Col 9-12
    "기지국/중계기 여부": "기지국구분",
    "시스템": "시스템",
    "정기검사 년도": "검사년도",
    "정기검사년도": "검사년도",
    "검사년도": "검사년도",
    "검사년도": "검사년도",
    "정기/시기조정": "검사종류",
    "정기/이월구분": "_이월구분_auto",  # 데이터 값으로 검사년도/검사종류 자동 판별
    "검사일자": "검사일자",
    # Col 13-18
    "1. ONS(팀)": "ons팀",
    "수검자": "수검자",
    "입회자": "수검자",  # 강북 변형
    "전파진흥원": "전파진흥원",
    "진흥원본부": "전파진흥원",  # 경남 변형
    "검사관": "검사관",
    "진행여부": "진행여부",
    "합격,불합격여부": "합불여부",
    # Col 19-25
    "성능/서류": "성능서류",
    "불합격내용": "불합격내용",
    "불합격상세사유": "불합격상세",
    "공용화 정비대상 유/무": "공용화대상",
    "기타사항": "기타사항",
    "기타사항(폐국 및 대개체국소)": "기타사항",
    "간략불합격내역": "간략불합격",
    "간략 불합격 내역": "간략불합격",  # 띄어쓰기 변형
    "간략불합격내역": "간략불합격",
    # Col 26-27
    "5G Path 확인 방법": "five_g_path",
    "허가번호 장비 Type": "장비타입",
}

# ONS 본부 → region 매핑
_ONS_REGION_MAP = {
    "경북": "경북", "경남": "경남",
    "강원": "강원", "강원Access": "강원",
    "강남": "강남", "강남본부": "강남",
    "강북": "강북", "강북본부": "강북",
    "경기": "경기",
    "인천": "인천", "인천본부": "인천",
    "충청": "충청", "충남": "충청", "충북": "충청", "충청본부": "충청",
    "서부": "서부", "서부본부": "서부", "전북": "서부", "전남": "서부",
    "수도권": "수도권",
}


def _parse_irr_xlsx_sync(file_bytes: bytes, year_hint: int, uploaded_by: str):
    """검사실적 RAW DATA xlsx 파싱 → (rows, region, year) 반환."""
    wb = openpyxl.load_workbook(io.BytesIO(file_bytes), read_only=True, data_only=True)
    # RAW DATA 시트 찾기
    target_ws = None
    for name in wb.sheetnames:
        if "RAW" in name.upper():
            target_ws = wb[name]
            break
    # RAW 시트 못 찾으면 허가번호 헤더가 있는 첫 번째 시트 사용
    if target_ws is None:
        for name in wb.sheetnames:
            ws = wb[name]
            for row in ws.iter_rows(min_row=1, max_row=2, values_only=True):
                if any('허가번호' in str(c or '') for c in row):
                    target_ws = wb[name]
                    break
            if target_ws is not None:
                break
    if target_ws is None:
        wb.close()
        raise ValueError("RAW DATA 시트를 찾을 수 없습니다")

    rows_iter = target_ws.iter_rows(values_only=True)
    # 헤더 행 찾기 (첫 행 or 둘째 행에 '허가번호' 포함)
    header_row = next(rows_iter, None)
    if header_row is None:
        wb.close()
        raise ValueError("빈 시트입니다")

    headers = [str(h).strip().split('\n')[0].strip() if h else "" for h in header_row]
    # 허가번호가 헤더에 없으면 다음 행 시도
    if not any('허가번호' in hh for hh in headers):
        header_row = next(rows_iter, None)
        if header_row is None:
            wb.close()
            raise ValueError("헤더를 찾을 수 없습니다")
        headers = [str(h).strip().split('\n')[0].strip() if h else "" for h in header_row]

    # 헤더 인덱스 매핑
    col_map = {}  # db_col -> excel_col_index
    ons_idx = -1
    year_idx = -1
    # 허가번호 컬럼이 두 번 나올 수 있음 — 두 번째는 허가번호2
    hn_count = 0
    for i, h in enumerate(headers):
        if not h:
            continue
        # 허가번호 특수 처리 (두 번째 출현)
        if h == "허가번호":
            hn_count += 1
            if hn_count == 1:
                col_map["허가번호"] = i
            else:
                col_map["허가번호2"] = i
            continue
        # 검사지표 특수 처리: 원본에 Ʈ문자가 있을 수 있음
        h_clean = h.replace("\u01ae", "T").replace("Ʈ", "T")
        h_nospace = h_clean.replace(" ", "")
        matched = False
        for excel_h, db_col in _IRR_HEADER_MAP.items():
            if db_col is None:
                continue
            excel_h_clean = excel_h.replace("\u01ae", "T").replace("Ʈ", "T")
            excel_h_nospace = excel_h_clean.replace(" ", "")
            if h == excel_h or h_clean == excel_h_clean or h_nospace == excel_h_nospace:
                if db_col == "_ons본부":
                    ons_idx = i
                elif db_col == "검사년도":
                    year_idx = i
                    col_map[db_col] = i
                else:
                    col_map[db_col] = i
                matched = True
                break

    # 장비타입 컬럼 fallback: 헤더 매핑 실패 시 데이터 패턴으로 자동 감지
    if "장비타입" not in col_map:
        # 매핑된 컬럼 인덱스 집합
        _mapped_indices = set(col_map.values())
        if ons_idx >= 0:
            _mapped_indices.add(ons_idx)
        # 장비타입 패턴 (일반적인 장비명 키워드)
        _eqp_keywords = {"MIBOS", "RRU", "AAU", "IRO", "RHU", "RHH", "PRU", "DUO", "SF-", "RO-", "GIRO", "WAFMC"}
        # 첫 몇 행 데이터를 읽어서 패턴 매칭
        _probe_rows = []
        for _pr in rows_iter:
            if _pr is None or all(c is None or str(c).strip() == "" for c in _pr):
                continue
            _probe_rows.append(_pr)
            if len(_probe_rows) >= 5:
                break
        # 매핑 안 된 컬럼 중 장비타입 패턴이 있는 컬럼 찾기
        for ci in range(len(headers)):
            if ci in _mapped_indices:
                continue
            hits = 0
            for _pr in _probe_rows:
                if ci < len(_pr) and _pr[ci]:
                    val = str(_pr[ci]).strip().upper()
                    if any(kw in val for kw in _eqp_keywords):
                        hits += 1
            if hits >= 2:  # 5개 중 2개 이상 매칭
                col_map["장비타입"] = ci
                logger.info(f"장비타입 컬럼 자동감지: Col {ci} (헤더: '{headers[ci] if ci < len(headers) else ''}')")
                break
        # probe_rows를 다시 처리하기 위해 체인
        import itertools
        rows_iter = itertools.chain(_probe_rows, rows_iter)

    now_str = datetime.now(timezone.utc).isoformat()
    db_rows = []
    region_set = set()

    # cert_cache.db에서 zpcode→eqp_type, zpwino→eqp_type 매핑 프리로드
    # 허가번호는 하이픈 제거하여 정규화
    _zpcode_eqp_map = {}
    _permit_eqp_map = {}
    if _cert_cache_db_path and os.path.exists(_cert_cache_db_path):
        try:
            cc = sqlite3.connect(_cert_cache_db_path, timeout=10)
            for _r in cc.execute("SELECT zpcode, zpwino, eqp_type FROM cert WHERE eqp_type IS NOT NULL AND eqp_type != ''"):
                eqp = str(_r[2]).strip()
                zp = str(_r[0] or "").strip()
                permit = str(_r[1] or "").strip().replace("-", "")
                if zp:
                    _zpcode_eqp_map[zp] = eqp
                if permit:
                    _permit_eqp_map[permit] = eqp
            cc.close()
            logger.info(f"장비타입 매핑 로드: zpcode={len(_zpcode_eqp_map)}, permit={len(_permit_eqp_map)}")
        except Exception:
            pass

    for row in rows_iter:
        if row is None or all(c is None or str(c).strip() == "" for c in row):
            continue

        rec = {}
        for db_col, ci in col_map.items():
            if ci < len(row):
                val = row[ci]
                rec[db_col] = str(val).strip() if val is not None else ""
            else:
                rec[db_col] = ""

        # region 결정 (ONS 본부)
        region = ""
        if ons_idx >= 0 and ons_idx < len(row) and row[ons_idx]:
            ons_val = str(row[ons_idx]).strip()
            for k, v in _ONS_REGION_MAP.items():
                if k in ons_val:
                    region = v
                    break
            if not region:
                # "본부", "Access" 등 접미사 제거 후 재시도
                cleaned = ons_val.replace("본부", "").replace("Access", "").replace("access", "").strip()
                region = _ONS_REGION_MAP.get(cleaned, cleaned)
        rec["region"] = region
        region_set.add(region)

        # _이월구분_auto: 데이터 값으로 검사년도/검사종류 자동 판별
        auto_val = rec.pop("_이월구분_auto", "")
        if auto_val:
            # 숫자(년도)인지 텍스트(정기/이월)인지 판별
            cleaned = auto_val.replace("년", "").replace("년도", "").strip()
            try:
                int(float(cleaned))
                # 숫자 → 검사년도
                if not rec.get("검사년도"):
                    rec["검사년도"] = auto_val
            except (ValueError, TypeError):
                # 텍스트 → 검사종류
                if not rec.get("검사종류"):
                    rec["검사종류"] = auto_val

        # year: 당해년도 실적만 관리 — 항상 업로드 시점 year 사용
        rec["year"] = year_hint

        # 검사종류 자동 결정: 검사년도 > 올해 → 시기조정, 그 외 → 정기
        if not rec.get("검사종류"):
            try:
                raw_yr = rec.get("검사년도", "").replace("년", "").replace("년도", "").strip()
                insp_yr = int(float(raw_yr))
                # 202601 같은 6자리 → 앞 4자리만 추출
                if insp_yr > 9999:
                    insp_yr = int(str(insp_yr)[:4])
                rec["검사종류"] = "시기조정" if insp_yr > year_hint else "정기"
            except (ValueError, TypeError):
                rec["검사종류"] = "정기"

        # 주차별 정규화: "n월n주" 형식으로 통일
        import re as _re_wk
        week = rec.get("주차별", "").strip().replace(" ", "")

        # 1) "n월n주" 패턴 추출 (뒤에 붙은 메모/특수문자 제거)
        _wk_match = _re_wk.search(r'(\d{1,2})월(\d)주', week)
        if _wk_match:
            week = f"{_wk_match.group(1)}월{_wk_match.group(2)}주"
        elif week and '주' in week and '월' not in week:
            # 2) "n주"만 있는 경우 → 월 컬럼 또는 검사일자에서 월 추출
            _jw_match = _re_wk.search(r'(\d)주', week)
            if _jw_match:
                ju = _jw_match.group(1)
                month = ""
                # 월 컬럼 우선
                월_val = rec.get("월", "").strip().replace("월", "").strip()
                if 월_val:
                    try:
                        month = str(int(월_val))
                    except Exception:
                        pass
                # 월 컬럼 없으면 검사일자
                if not month:
                    date_str = str(rec.get("검사일자", "")).strip()
                    try:
                        if '-' in date_str:
                            month = str(int(date_str.split('-')[1]))
                        elif '/' in date_str:
                            month = str(int(date_str.split('/')[1]))
                    except Exception:
                        pass
                if month:
                    week = f"{month}월{ju}주"
                else:
                    week = ""
        else:
            # 패턴 매칭 안 되면 빈값
            if week and not _re_wk.match(r'^\d{1,2}월\d주$', week):
                week = ""
        rec["주차별"] = week

        # 장비타입간소화 파생 (5단계 fallback)
        raw_eqp = rec.get("장비타입", "").strip()
        simplified = ""
        eqp_from_cert = ""
        eqp_from_permit = ""

        # 1) 결과장 장비타입 직접 매칭
        if raw_eqp:
            simplified = _EQP_TYPE_SIMPLIFY.get(raw_eqp, "")
            if not simplified:
                for k, v in _EQP_TYPE_SIMPLIFY.items():
                    if raw_eqp.startswith(k) or k.startswith(raw_eqp):
                        simplified = v
                        break

        # 2) 통시코드로 ERP DB 조회
        if not simplified:
            zpcode = rec.get("통합시설코드", "").strip()
            eqp_from_cert = _zpcode_eqp_map.get(zpcode, "") if zpcode else ""
            if eqp_from_cert:
                simplified = _EQP_TYPE_SIMPLIFY.get(eqp_from_cert, "")
                if not simplified:
                    for k, v in _EQP_TYPE_SIMPLIFY.items():
                        if eqp_from_cert.startswith(k) or k.startswith(eqp_from_cert):
                            simplified = v
                            break

        # 3) 허가번호로 ERP DB 조회 (하이픈 제거하여 정규화)
        if not simplified:
            permit = rec.get("허가번호", "").strip().replace("-", "")
            eqp_from_permit = _permit_eqp_map.get(permit, "") if permit else ""
            if eqp_from_permit:
                simplified = _EQP_TYPE_SIMPLIFY.get(eqp_from_permit, "")
                if not simplified:
                    for k, v in _EQP_TYPE_SIMPLIFY.items():
                        if eqp_from_permit.startswith(k) or k.startswith(eqp_from_permit):
                            simplified = v
                            break
                # 장비타입 필드도 채워주기 (결과장에 없었던 경우)
                if not raw_eqp:
                    rec["장비타입"] = eqp_from_permit

        # 4) 키워드 기반 fallback
        if not simplified:
            for candidate in [raw_eqp, eqp_from_cert, eqp_from_permit]:
                if candidate:
                    simplified = _simplify_eqp_by_keyword(candidate)
                    if simplified:
                        break

        # 5) 최종 실패 로깅
        if not simplified:
            permit = rec.get("허가번호", "").strip()
            zpcode = rec.get("통합시설코드", "").strip()
            logger.warning(f"장비타입간소화 최종 실패: 허가번호='{permit}', zpcode='{zpcode}', raw_eqp='{raw_eqp}'")

        rec["장비타입간소화"] = simplified

        rec["uploaded_by"] = uploaded_by
        rec["uploaded_at"] = now_str

        db_rows.append(rec)

    wb.close()
    # 대표 region (가장 많은 것)
    if region_set:
        primary_region = max(region_set, key=lambda r: sum(1 for d in db_rows if d.get("region") == r))
    else:
        primary_region = ""

    return db_rows, primary_region, year_hint


_IRR_DB_COLS = [
    "year", "region", "skt본부", "주차별", "월", "허가번호", "통합시설코드", "호출명칭",
    "주소", "기지국구분", "시스템", "검사년도", "검사종류", "검사일자", "ons팀", "수검자",
    "전파진흥원", "검사관", "진행여부", "합불여부", "성능서류", "불합격내용", "불합격상세",
    "공용화대상", "기타사항", "간략불합격", "five_g_path", "장비타입", "허가번호2",
    "허가번호text", "제조주소명", "제조정보명", "검사지표정보명", "제조Type", "장비명",
    "NAMS기타정보", "장비Type공용화", "NAMS설명정보", "장비Type2", "장비타입간소화", "uploaded_by", "uploaded_at",
]


@app.post("/inspection-results/upload")
async def inspection_results_upload(request: Request, file: UploadFile = File(...)):
    """검사실적 RAW DATA xlsx 업로드 (admin/manager)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    if not HAS_OPENPYXL:
        raise HTTPException(500, "openpyxl 미설치")

    fname = file.filename or ""
    if fname.lower().endswith('.xls') and not fname.lower().endswith('.xlsx'):
        raise HTTPException(400, ".xls 형식은 지원하지 않습니다. xlsx 파일로 변환 후 업로드해주세요.")

    file_bytes = await file.read()
    if not file_bytes:
        raise HTTPException(400, "빈 파일입니다")

    year_hint = datetime.now().year

    try:
        db_rows, primary_region, year = await asyncio.to_thread(
            _parse_irr_xlsx_sync, file_bytes, year_hint, empno
        )
    except ValueError as ve:
        raise HTTPException(400, str(ve))
    finally:
        del file_bytes

    if not db_rows:
        raise HTTPException(400, "파싱된 데이터가 없습니다")

    def _insert_sync():
        _init_inspection_db()
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            # 같은 region+year 기존 데이터 삭제
            regions = set(r.get("region", "") for r in db_rows)
            years = set(r.get("year", year) for r in db_rows)
            for rg in regions:
                for yr in years:
                    conn.execute(
                        'DELETE FROM inspection_results_raw WHERE region=? AND year=?',
                        (rg, yr)
                    )
            # batch INSERT
            placeholders = ','.join(['?'] * len(_IRR_DB_COLS))
            sql = f'INSERT INTO inspection_results_raw ({",".join(_IRR_DB_COLS)}) VALUES ({placeholders})'
            batch = []
            for rec in db_rows:
                vals = tuple(rec.get(c, "") for c in _IRR_DB_COLS)
                batch.append(vals)
            conn.executemany(sql, batch)
            conn.commit()
            return len(batch)
        finally:
            conn.close()

    count = await asyncio.to_thread(_insert_sync)
    return {"success": True, "count": count, "region": primary_region}


def _irr_dashboard_calc_sync(year: int, region: str = "", month: str = ""):
    """검사실적 대시보드 집계 (동기)."""
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    conn.row_factory = sqlite3.Row
    try:
        base_where = "year=?"
        params: list = [year]
        if region:
            base_where += " AND region=?"
            params.append(region)
        if month:
            base_where += " AND 월=?"
            params.append(month)

        # 지역 목록
        regions = [r[0] for r in conn.execute(
            f'SELECT DISTINCT region FROM inspection_results_raw WHERE {base_where} ORDER BY region',
            params
        ).fetchall()]

        result_regions = []
        for rg in regions:
            rg_where = base_where + (" AND region=?" if not region else "")
            rg_params = params + ([rg] if not region else [])
            if region:
                rg_where = base_where
                rg_params = list(params)
            else:
                rg_where = "year=? AND region=?"
                rg_params = [year, rg]
                if month:
                    rg_where += " AND 월=?"
                    rg_params.append(month)

            수검국소 = conn.execute(
                f'SELECT COUNT(*) FROM inspection_results_raw WHERE {rg_where}', rg_params
            ).fetchone()[0]

            시기조정 = conn.execute(
                f"SELECT COUNT(*) FROM inspection_results_raw WHERE {rg_where} AND 검사종류 LIKE '%시기조정%'",
                rg_params
            ).fetchone()[0]

            폐 = conn.execute(
                f"SELECT COUNT(*) FROM inspection_results_raw WHERE {rg_where} AND 기타사항 LIKE '%폐국%'",
                rg_params
            ).fetchone()[0]

            성능불합격 = conn.execute(
                f"SELECT COUNT(*) FROM inspection_results_raw WHERE {rg_where} AND 성능서류='성능'",
                rg_params
            ).fetchone()[0]

            서류불합격 = conn.execute(
                f"SELECT COUNT(*) FROM inspection_results_raw WHERE {rg_where} AND 성능서류='서류'",
                rg_params
            ).fetchone()[0]

            완료 = 수검국소 - 시기조정
            성능합격 = 수검국소 - 성능불합격
            서류합격 = 수검국소 - 서류불합격

            result_regions.append({
                "name": rg,
                "수검국소": 수검국소,
                "완료": 완료,
                "시기조정": 시기조정,
                "폐": 폐,
                "성능합격": 성능합격,
                "성능불합격": 성능불합격,
                "서류검사": 수검국소,
                "서류합격": 서류합격,
                "서류불합격": 서류불합격,
                "성능합격율": round(성능합격 / 수검국소, 4) if 수검국소 > 0 else 0,
                "성능불합격율": round(성능불합격 / 수검국소, 4) if 수검국소 > 0 else 0,
                "서류합격율": round(서류합격 / 수검국소, 4) if 수검국소 > 0 else 0,
                "서류불합격율": round(서류불합격 / 수검국소, 4) if 수검국소 > 0 else 0,
            })

        # 합계
        t_수검 = sum(r["수검국소"] for r in result_regions)
        t_시기 = sum(r["시기조정"] for r in result_regions)
        t_폐 = sum(r["폐"] for r in result_regions)
        t_성능불 = sum(r["성능불합격"] for r in result_regions)
        t_서류불 = sum(r["서류불합격"] for r in result_regions)
        t_완료 = t_수검 - t_시기
        t_성능합 = t_수검 - t_성능불
        t_서류합 = t_수검 - t_서류불

        total = {
            "name": "합계",
            "수검국소": t_수검,
            "완료": t_완료,
            "시기조정": t_시기,
            "폐": t_폐,
            "성능합격": t_성능합,
            "성능불합격": t_성능불,
            "서류검사": t_수검,
            "서류합격": t_서류합,
            "서류불합격": t_서류불,
            "성능합격율": round(t_성능합 / t_수검, 4) if t_수검 > 0 else 0,
            "성능불합격율": round(t_성능불 / t_수검, 4) if t_수검 > 0 else 0,
            "서류합격율": round(t_서류합 / t_수검, 4) if t_수검 > 0 else 0,
            "서류불합격율": round(t_서류불 / t_수검, 4) if t_수검 > 0 else 0,
        }

        # target (inspection_targets 기준 전체 대상 수)
        try:
            target_전체 = conn.execute('SELECT COUNT(*) FROM inspection_targets WHERE year=?', (year,)).fetchone()[0]
        except Exception:
            target_전체 = 0
        target = {
            "전체": target_전체,
            "정기검사": target_전체,
            "시기조정": 0,
            "미이행": max(0, target_전체 - t_수검),
        }

        return {"regions": result_regions, "total": total, "target": target}
    finally:
        conn.close()


@app.get("/inspection-results/dashboard")
async def inspection_results_dashboard(request: Request, year: int = Query(...), region: str = Query("")):
    """검사실적 대시보드 — 지역별 합격/불합격 집계."""
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB):
        return {"regions": [], "total": {}, "target": {}}
    return await asyncio.to_thread(_irr_dashboard_calc_sync, year, region=region)


@app.get("/inspection-results/dashboard/monthly")
async def inspection_results_dashboard_monthly(
    request: Request, year: int = Query(...), month: str = Query("")
):
    """검사실적 월별 대시보드."""
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB):
        return {"regions": [], "total": {}, "target": {}}
    return await asyncio.to_thread(_irr_dashboard_calc_sync, year, month=month)


@app.get("/inspection-results/trend")
async def inspection_results_trend(request: Request, year: int = Query(...)):
    """검사실적 월별 트렌드 (차트용)."""
    await _verify_auth(request)

    def _trend_sync():
        if not os.path.exists(_INSP_DB):
            return {"months": []}
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            rows = conn.execute(
                "SELECT 월, COUNT(*) as cnt, "
                "SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as 성능불, "
                "SUM(CASE WHEN 성능서류='서류' THEN 1 ELSE 0 END) as 서류불 "
                "FROM inspection_results_raw WHERE year=? AND 월 IS NOT NULL AND 월 != '' "
                "GROUP BY 월 ORDER BY 월",
                (year,)
            ).fetchall()
            months = []
            for r in rows:
                월, cnt, 성능불, 서류불 = r
                성능합 = cnt - 성능불
                서류합 = cnt - 서류불
                months.append({
                    "월": 월,
                    "수검국소": cnt,
                    "성능합격율": round(성능합 / cnt, 4) if cnt > 0 else 0,
                    "서류합격율": round(서류합 / cnt, 4) if cnt > 0 else 0,
                })
            return {"months": months}
        finally:
            conn.close()

    return await asyncio.to_thread(_trend_sync)


@app.get("/inspection-results/raw")
async def inspection_results_raw_list(
    request: Request,
    year: int = Query(...),
    region: str = Query(""),
    월: str = Query(""),
    page: int = Query(1),
    pageSize: int = Query(100),
):
    """검사실적 RAW DATA 목록 (페이징)."""
    await _verify_auth(request)

    def _list_sync():
        if not os.path.exists(_INSP_DB):
            return {"items": [], "total": 0}
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        conn.row_factory = sqlite3.Row
        try:
            where = "year=?"
            params: list = [year]
            if region:
                where += " AND region=?"
                params.append(region)
            if 월:
                where += " AND 월=?"
                params.append(월)

            total = conn.execute(
                f'SELECT COUNT(*) FROM inspection_results_raw WHERE {where}', params
            ).fetchone()[0]

            offset = (max(1, page) - 1) * pageSize
            items = conn.execute(
                f'SELECT * FROM inspection_results_raw WHERE {where} ORDER BY id LIMIT ? OFFSET ?',
                params + [pageSize, offset]
            ).fetchall()

            return {
                "items": [dict(r) for r in items],
                "total": total,
            }
        finally:
            conn.close()

    return await asyncio.to_thread(_list_sync)


@app.get("/inspection-results/analysis")
async def inspection_results_analysis(request: Request, year: int = Query(...), region: str = Query("")):
    """불합격 사유 분석 (성능/서류/장비타입별)."""
    await _verify_auth(request)

    def _analysis():
        if not os.path.exists(_INSP_DB):
            return {"성능불합격": [], "서류불합격": [], "장비타입별": []}
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            rgn_filter = " AND region=?" if region else ""
            rgn_params = (year, region) if region else (year,)

            perf_rows = conn.execute(
                "SELECT 간략불합격, COUNT(*) as cnt FROM inspection_results_raw "
                f"WHERE year=?{rgn_filter} AND 성능서류='성능' AND 간략불합격 IS NOT NULL AND 간략불합격 != '' "
                "GROUP BY 간략불합격 ORDER BY cnt DESC",
                rgn_params
            ).fetchall()
            perf_total = sum(r[1] for r in perf_rows) or 1
            성능불합격 = [{"사유": r[0], "건수": r[1], "비율": round(r[1]/perf_total, 4)} for r in perf_rows]

            doc_rows = conn.execute(
                "SELECT 간략불합격, COUNT(*) as cnt FROM inspection_results_raw "
                f"WHERE year=?{rgn_filter} AND 성능서류='서류' AND 간략불합격 IS NOT NULL AND 간략불합격 != '' "
                "GROUP BY 간략불합격 ORDER BY cnt DESC",
                rgn_params
            ).fetchall()
            doc_total = sum(r[1] for r in doc_rows) or 1
            서류불합격 = [{"사유": r[0], "건수": r[1], "비율": round(r[1]/doc_total, 4)} for r in doc_rows]

            equip_rows = conn.execute(
                "SELECT 장비타입간소화, COUNT(*) as cnt FROM inspection_results_raw "
                f"WHERE year=?{rgn_filter} AND 성능서류='성능' AND 장비타입간소화 IS NOT NULL AND 장비타입간소화 != '' "
                "GROUP BY 장비타입간소화 ORDER BY cnt DESC",
                rgn_params
            ).fetchall()
            equip_total = sum(r[1] for r in equip_rows) or 1
            장비타입별 = [{"타입": r[0], "건수": r[1], "비율": round(r[1]/equip_total, 4)} for r in equip_rows]

            # 장비타입별 × 본부 크로스탭 (Top3 장비타입간소화)
            top3_types = [r["타입"] for r in 장비타입별[:3]]
            crosstab = []
            if top3_types:
                placeholders = ",".join("?" for _ in top3_types)
                ct_params = list(rgn_params) + top3_types
                ct_rows = conn.execute(
                    f"SELECT 장비타입간소화, region, COUNT(*) as cnt FROM inspection_results_raw "
                    f"WHERE year=?{rgn_filter} AND 성능서류='성능' AND 장비타입간소화 IN ({placeholders}) "
                    f"AND 장비타입간소화 IS NOT NULL AND 장비타입간소화 != '' "
                    f"GROUP BY 장비타입간소화, region ORDER BY 장비타입간소화",
                    ct_params
                ).fetchall()
                # pivot: {type: {region: cnt, ...}}
                pivot: Dict[str, Dict[str, int]] = {}
                for typ, reg, cnt in ct_rows:
                    pivot.setdefault(typ, {})[reg or "기타"] = cnt
                # 전체 본부 목록
                all_regions = [r[0] for r in conn.execute(
                    "SELECT DISTINCT region FROM inspection_results_raw WHERE year=? AND region != ''", (year,)).fetchall()]
                for typ in top3_types:
                    row_data = {rg: pivot.get(typ, {}).get(rg, 0) for rg in all_regions}
                    total_ct = sum(row_data.values())
                    crosstab.append({"타입": typ, "본부별": row_data, "총합계": total_ct})
                # 성능불합격(건) 합계 행 — 전체 성능 불합격 건수 (Top3 합이 아닌 전체)
                total_rows = conn.execute(
                    f"SELECT region, COUNT(*) FROM inspection_results_raw "
                    f"WHERE year=?{rgn_filter} AND 성능서류='성능' AND region != '' "
                    f"GROUP BY region",
                    rgn_params
                ).fetchall()
                total_row = {rg: cnt for rg, cnt in total_rows}
                crosstab.append({"타입": "성능불합격(건)", "본부별": total_row, "총합계": sum(total_row.values())})

            return {"성능불합격": 성능불합격, "서류불합격": 서류불합격, "장비타입별": 장비타입별, "장비타입별_크로스탭": crosstab}
        finally:
            conn.close()

    return await asyncio.to_thread(_analysis)


@app.get("/inspection-results/weekly-trend")
async def inspection_results_weekly_trend(request: Request, year: int = Query(...), region: str = Query("")):
    """주차별 합격율 추이."""
    await _verify_auth(request)

    def _weekly():
        if not os.path.exists(_INSP_DB):
            return {"weeks": []}
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            rgn_f = " AND region=?" if region else ""
            rgn_p = (year, region) if region else (year,)
            rows = conn.execute(
                "SELECT 주차별, COUNT(*) as cnt, "
                "SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as 성능불, "
                "SUM(CASE WHEN 성능서류='서류' THEN 1 ELSE 0 END) as 서류불 "
                f"FROM inspection_results_raw WHERE year=?{rgn_f} AND 주차별 IS NOT NULL AND 주차별 != '' "
                "GROUP BY 주차별 ORDER BY 주차별",
                rgn_p
            ).fetchall()
            weeks = []
            for r in rows:
                주차, cnt, 성능불, 서류불 = r
                weeks.append({
                    "주차": 주차,
                    "수검": cnt,
                    "불합격": 성능불,
                    "합격율": round((cnt - 성능불) / cnt, 4) if cnt > 0 else 0,
                    "서류불합격": 서류불,
                    "서류합격율": round((cnt - 서류불) / cnt, 4) if cnt > 0 else 0,
                })
            return {"weeks": weeks}
        finally:
            conn.close()

    return await asyncio.to_thread(_weekly)


@app.get("/inspection-results/weekly-trend-by-region")
async def inspection_results_weekly_trend_by_region(request: Request, year: int = Query(...)):
    """본부별 주차별 합격율 추이 (9개 소형 차트용)."""
    await _verify_auth(request)

    def _by_region():
        if not os.path.exists(_INSP_DB):
            return {"regions": {}}
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            rows = conn.execute(
                "SELECT region, 주차별, COUNT(*) as cnt, "
                "SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as 성능불, "
                "SUM(CASE WHEN 성능서류='서류' THEN 1 ELSE 0 END) as 서류불 "
                "FROM inspection_results_raw "
                "WHERE year=? AND 주차별 IS NOT NULL AND 주차별 != '' AND region IS NOT NULL AND region != '' "
                "GROUP BY region, 주차별 ORDER BY region, 주차별",
                (year,)
            ).fetchall()
            regions: Dict[str, list] = {}
            for region, 주차, cnt, 성능불, 서류불 in rows:
                regions.setdefault(region, []).append({
                    "주차": 주차,
                    "합격율": round((cnt - 성능불) / cnt, 4) if cnt > 0 else 0,
                    "서류합격율": round((cnt - 서류불) / cnt, 4) if cnt > 0 else 0,
                })
            return {"regions": regions}
        finally:
            conn.close()

    return await asyncio.to_thread(_by_region)


@app.get("/inspection-results/summary-report")
async def inspection_results_summary_report(request: Request, year: int = Query(...), region: str = Query("")):
    """실적 현황 리포트 자동 생성."""
    await _verify_auth(request)

    def _build_report():
        if not os.path.exists(_INSP_DB):
            return {"lines": []}
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            # 1. 전사 집계
            rgn_f = " AND region=?" if region else ""
            rgn_p = (year, region) if region else (year,)
            total = conn.execute(f"SELECT COUNT(*) FROM inspection_results_raw WHERE year=?{rgn_f}", rgn_p).fetchone()[0]
            if total == 0:
                return {"lines": ["데이터가 없습니다."]}

            perf_fail = conn.execute(f"SELECT COUNT(*) FROM inspection_results_raw WHERE year=?{rgn_f} AND 성능서류='성능'", rgn_p).fetchone()[0]
            doc_fail = conn.execute(f"SELECT COUNT(*) FROM inspection_results_raw WHERE year=?{rgn_f} AND 성능서류='서류'", rgn_p).fetchone()[0]
            perf_pass = total - perf_fail
            doc_pass = total - doc_fail
            perf_rate = round(perf_pass / total * 100, 1) if total > 0 else 0
            doc_rate = round(doc_pass / total * 100, 1) if total > 0 else 0
            perf_target = 98.5
            doc_target = 85.5
            perf_diff = round(perf_rate - perf_target, 1)
            doc_diff = round(doc_rate - doc_target, 1)

            lines = []

            # Line 1: 전사 합격율 요약
            perf_status = "달성중" if perf_diff >= 0 else "미달성중"
            doc_status = "달성중" if doc_diff >= 0 else "미달성중"
            perf_arrow = "↑" if perf_diff >= 0 else "↓"
            doc_arrow = "↑" if doc_diff >= 0 else "↓"
            lines.append({
                "type": "header",
                "text": f"○ '{year % 100}년 무선국 합격율 실적(누적)"
            })
            lines.append({
                "type": "perf_ok" if perf_diff >= 0 else "perf_fail",
                "text": f"   성능 {perf_rate}% (목표 대비 {abs(perf_diff)}%{perf_arrow}) {perf_status}"
            })
            lines.append({
                "type": "doc_ok" if doc_diff >= 0 else "doc_fail",
                "text": f"   서류 {doc_rate}% (목표 대비 {abs(doc_diff)}%{doc_arrow}) {doc_status}"
            })

            # 2. 주별 추이 (최근 2주)
            weeks = conn.execute(
                "SELECT 주차별, COUNT(*) as cnt, SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as fail "
                "FROM inspection_results_raw WHERE year=? AND 주차별 IS NOT NULL AND 주차별 != '' "
                "GROUP BY 주차별 ORDER BY 주차별",
                (year,)
            ).fetchall()

            if len(weeks) >= 2:
                curr_week = weeks[-1]
                prev_week = weeks[-2]
                curr_rate = round((curr_week[1] - curr_week[2]) / curr_week[1] * 100, 1) if curr_week[1] > 0 else 0
                prev_rate = round((prev_week[1] - prev_week[2]) / prev_week[1] * 100, 1) if prev_week[1] > 0 else 0
                diff = round(curr_rate - prev_rate, 1)
                direction = "상승" if diff >= 0 else "하락"
                lines.append({
                    "type": "detail",
                    "text": f" - 성능합격율 : {curr_week[0]} {curr_rate}%로 전주대비 {abs(diff)}% {direction}({prev_rate}% → {curr_rate}%)"
                })

            # 3. 본부별 전주 대비 하락 분석
            if len(weeks) >= 2:
                curr_wk_name = weeks[-1][0]
                prev_wk_name = weeks[-2][0]

                regions_curr = conn.execute(
                    "SELECT region, COUNT(*) as cnt, SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as fail "
                    "FROM inspection_results_raw WHERE year=? AND 주차별=? GROUP BY region",
                    (year, curr_wk_name)
                ).fetchall()
                regions_prev = conn.execute(
                    "SELECT region, COUNT(*) as cnt, SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as fail "
                    "FROM inspection_results_raw WHERE year=? AND 주차별=? GROUP BY region",
                    (year, prev_wk_name)
                ).fetchall()

                prev_map = {r[0]: (r[1], r[2]) for r in regions_prev}
                drops = []
                for r in regions_curr:
                    rg, cnt, fail = r
                    curr_r = round((cnt - fail) / cnt * 100, 1) if cnt > 0 else 0
                    if rg in prev_map:
                        p_cnt, p_fail = prev_map[rg]
                        prev_r = round((p_cnt - p_fail) / p_cnt * 100, 1) if p_cnt > 0 else 0
                        d = round(curr_r - prev_r, 1)
                        if d < 0:
                            drops.append((rg, curr_r, abs(d), fail))

                if drops:
                    drops.sort(key=lambda x: -x[2])  # 하락폭 큰 순
                    drop_texts = [f"{rg} {rate}% {drop}%하락(성능불합격 {fail}국)" for rg, rate, drop, fail in drops[:3]]
                    lines.append({
                        "type": "sub",
                        "text": f"   → 전주대비 하락 Acc.담당 : {', '.join(drop_texts)}"
                    })

            # 4. 동작 불능 건수
            동작불능 = conn.execute(
                "SELECT region, COUNT(*) FROM inspection_results_raw WHERE year=? AND 불합격내용 LIKE '%동작불능%' GROUP BY region",
                (year,)
            ).fetchall()
            if 동작불능:
                total_불능 = sum(r[1] for r in 동작불능)
                detail = ', '.join(f"{r[0]} {r[1]}국" for r in 동작불능)
                lines.append({
                    "type": "sub",
                    "text": f"   → 동작 불능 {total_불능}국 발생 : {detail}"
                })

            # 5. 본부별 누적 실적 순위
            region_stats = conn.execute(
                "SELECT region, COUNT(*) as cnt, "
                "SUM(CASE WHEN 성능서류='성능' THEN 1 ELSE 0 END) as perf_fail, "
                "SUM(CASE WHEN 성능서류='서류' THEN 1 ELSE 0 END) as doc_fail "
                "FROM inspection_results_raw WHERE year=? AND region != '' GROUP BY region ORDER BY region",
                (year,)
            ).fetchall()

            ranked = []
            for r in region_stats:
                rg, cnt, pf, df = r
                p_rate = round((cnt - pf) / cnt * 100, 1) if cnt > 0 else 0
                d_rate = round((cnt - df) / cnt * 100, 1) if cnt > 0 else 0
                ranked.append((rg, p_rate, d_rate))
            ranked.sort(key=lambda x: x[1], reverse=True)  # 성능 합격율 내림차순

            if ranked:
                perf_text = " > ".join(f"{rg} {pr}%" for rg, pr, _ in ranked)
                lines.append({
                    "type": "detail",
                    "text": f" - Acc.담당 누적 실적 (성능)\n   → {perf_text}순"
                })
                doc_ranked = sorted(ranked, key=lambda x: x[2], reverse=True)
                doc_text = " > ".join(f"{rg} {dr}%" for rg, _, dr in doc_ranked)
                lines.append({
                    "type": "detail",
                    "text": f" - Acc.담당 누적 실적 (서류)\n   → {doc_text}순"
                })

            # 6. 목표 달성 전망
            if perf_rate < perf_target and len(weeks) > 0:
                remaining_weeks = 52 - len(weeks)  # rough estimate
                if remaining_weeks > 0:
                    needed_rate = round(perf_target + (perf_target - perf_rate) * len(weeks) / remaining_weeks, 1)
                    needed_max_fail = max(0, int(total / len(weeks) * (1 - needed_rate / 100)))
                    lines.append({
                        "type": "highlight",
                        "text": f"   ☞ 목표 달성 위해 주단위 {min(needed_rate, 99.9)}%이상 달성시 (주단위 불합격 {needed_max_fail}국 이하) 달성으로 전환 가능"
                    })

            return {"lines": lines}
        finally:
            conn.close()

    return await asyncio.to_thread(_build_report)


class InspectionResultsExportReq(BaseModel):
    year: int
    본부: Union[str, List[str]] = ""
    진행여부: str = ""
    status: str = ""
    성능서류: str = ""
    주차별: Union[str, List[str]] = ""


@app.get("/inspection-results/weeks")
async def inspection_results_weeks(request: Request, year: int, month: str = "", region: str = ""):
    """실적 업로드된 주차 목록 조회 (월/본부 필터)."""
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB):
        return {"weeks": []}

    def _query():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        where_parts = ["year=?", "주차별 IS NOT NULL", "주차별 != ''"]
        params: list = [year]
        if month:
            where_parts.append("월=?"); params.append(month)
        if region:
            where_parts.append("region=?"); params.append(region)
        rows = c.execute(
            f"SELECT DISTINCT 주차별 FROM inspection_results_raw WHERE {' AND '.join(where_parts)} ORDER BY 주차별",
            params,
        ).fetchall()
        c.close()
        return [r[0] for r in rows]

    weeks = await asyncio.to_thread(_query)
    return {"weeks": weeks}


@app.post("/inspection-results/export-xlsx")
async def inspection_results_export_xlsx(request: Request, req: InspectionResultsExportReq):
    """실적 결과장 RAW DATA Excel 내보내기."""
    await _verify_auth(request)
    if not HAS_OPENPYXL:
        raise HTTPException(503, "openpyxl 미설치")
    if not os.path.exists(_INSP_DB):
        raise HTTPException(404, "데이터 없음")

    def _build():
        import openpyxl
        from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
        from openpyxl.utils import get_column_letter

        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        _sel = (
            'SELECT r.* '
            'FROM inspection_results_raw r '
        )
        where_parts = ['r.year=?']
        params = [req.year]
        # 본부: 단일 str 또는 리스트
        본부_list = [req.본부] if isinstance(req.본부, str) else req.본부
        본부_list = [v for v in 본부_list if v]
        if 본부_list:
            placeholders = ','.join('?' * len(본부_list))
            where_parts.append(f'r.region IN ({placeholders})')
            params.extend(본부_list)
        if req.진행여부:
            where_parts.append('r.진행여부=?'); params.append(req.진행여부)
        if req.status:
            where_parts.append('r.합불여부=?'); params.append(req.status)
        if req.성능서류:
            where_parts.append('r.성능서류=?'); params.append(req.성능서류)
        # 주차별: 단일 str 또는 리스트
        주차_list = [req.주차별] if isinstance(req.주차별, str) else req.주차별
        주차_list = [v for v in 주차_list if v]
        if 주차_list:
            placeholders = ','.join('?' * len(주차_list))
            where_parts.append(f'r.주차별 IN ({placeholders})')
            params.extend(주차_list)
        where_sql = ' AND '.join(where_parts)
        rows = c.execute(_sel + f'WHERE {where_sql} ORDER BY r.id', params).fetchall()
        c.close()

        if not rows:
            raise ValueError("조회된 실적 데이터가 없습니다")

        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = "RAW DATA"

        _thin_side = Side(style='thin')
        _thin_border = Border(left=_thin_side, right=_thin_side,
                              top=_thin_side, bottom=_thin_side)
        _hdr_fill = PatternFill('solid', fgColor='FFBFBFBF')
        _hdr_font = Font(name='맑은 고딕', size=10, bold=True)
        _data_font = Font(name='맑은 고딕', size=10)
        _center = Alignment(horizontal='center', vertical='center', wrap_text=False)
        _left = Alignment(horizontal='left', vertical='center', wrap_text=False)
        _left_wrap = Alignment(horizontal='left', vertical='center', wrap_text=True)
        _hdr_wrap = Alignment(horizontal='center', vertical='center', wrap_text=True)
        _hdr_left_wrap = Alignment(horizontal='left', vertical='center', wrap_text=True)
        _LINE_H = 16.5

        headers = [
            '주차', '월', '구분', 'SKT본부', 'ONS 본부', '허가번호',
            '통합시설코드', '호출명칭', '주소', '기지국/중계기 여부', '시스템',
            '정기검사 년도', '정기/시기조정', '검사일자', '1. ONS(팀)', '수검자',
            '전파진흥원\n(예. 서울본부/북서울본부/경인본부 등)',
            '검사관\n(검사관 이름)', '진행여부', '합격,불합격여부', '성능/서류', '불합격내용',
            '불합격상세사유', '공용화 정비대상 유/무', '기타사항(폐국 및 대개체국소)', '간략불합격내역',
            '5G Path 확인 방법\n1. 전체 Path\n2. 부분 Path\n3. 1개 Path \n4. Total Power',
            '허가번호 장비 Type\n\n1. MIBOS(SMHS 등등)\n2. RRU\n3. AAU20-5G-AAU3.5G-64T\nAAU21-5G-AAU3.5G-32T 등\n4. 광급중계기(DDR,MPR 등)',
            '장비타입간소화',
        ]

        # 왼쪽 정렬 컬럼: 주소(9), 불합격상세(23), 허가번호 장비 Type(28)
        _left_cols = {9, 23, 28}
        _left_wrap_cols = {9, 23}  # wrap_text 적용 컬럼
        _hdr_left_cols = {28}

        # 헤더 행 높이
        _hdr_max_lines = 1
        for h in headers:
            _lc = h.count('\n') + 1
            if _lc > _hdr_max_lines:
                _hdr_max_lines = _lc
        ws.row_dimensions[1].height = _LINE_H * _hdr_max_lines

        for ci, h in enumerate(headers, 1):
            cell = ws.cell(row=1, column=ci, value=h)
            cell.font = _hdr_font
            cell.fill = _hdr_fill
            cell.border = _thin_border
            cell.alignment = _hdr_left_wrap if ci in _hdr_left_cols else _hdr_wrap

        # DB 컬럼 → Excel 컬럼 매핑
        db_cols = [
            '주차별', '월', None, 'skt본부', 'region', '허가번호',
            '통합시설코드', '호출명칭', '주소', '기지국구분', '시스템',
            '검사년도', '검사종류', '검사일자', 'ons팀', '수검자',
            '전파진흥원', '검사관', '진행여부', '합불여부', '성능서류', '불합격내용',
            '불합격상세', '공용화대상', '기타사항', '간략불합격',
            'five_g_path', '장비타입', '장비타입간소화',
        ]

        for ri, row in enumerate(rows, 2):
            d = dict(row)
            values = []
            for i, db_col in enumerate(db_cols):
                if db_col is None:
                    values.append(ri - 1)  # 구분(순번)
                else:
                    values.append(d.get(db_col) or '')

            # 행높이
            max_lines = 1
            for _v in values:
                if isinstance(_v, str) and '\n' in _v:
                    _lc = _v.count('\n') + 1
                    if _lc > max_lines:
                        max_lines = _lc
            ws.row_dimensions[ri].height = _LINE_H * max_lines

            for ci, v in enumerate(values, 1):
                cell = ws.cell(row=ri, column=ci, value=v)
                cell.font = _data_font
                cell.border = _thin_border
                cell.alignment = _left_wrap if ci in _left_wrap_cols else (_left if ci in _left_cols else _center)

        # 컬럼 너비: 데이터 기준 자동
        def _col_width(s):
            w = 0.0
            for ch in str(s):
                w += 2.2 if ord(ch) > 127 else 1.1
            return w

        for ci in range(1, len(headers) + 1):
            best = 0
            for ri2 in range(2, min(len(rows) + 2, 202)):
                val = ws.cell(row=ri2, column=ci).value
                if val is not None:
                    for line in str(val).split('\n'):
                        best = max(best, _col_width(line))
            max_w = 40 if ci in _left_wrap_cols else 80
            ws.column_dimensions[get_column_letter(ci)].width = max(min(best + 1, max_w), 12.25)

        # 틀 고정: 1행(헤더) + A~H열
        ws.freeze_panes = 'I2'

        buf = io.BytesIO()
        wb.save(buf)
        wb.close()
        buf.seek(0)
        return buf.getvalue()

    try:
        data = await asyncio.to_thread(_build)
    except ValueError as e:
        raise HTTPException(404, str(e))

    filename = f"inspection_results_{req.year}.xlsx"
    from urllib.parse import quote as _q
    return Response(
        content=data,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{_q(filename)}"}
    )


# ============================================================
# 변경개설신고 자동 변경 (A파일 + B파일 → 변경적용 DS)
# ============================================================

@app.post("/document/change-notification")
async def document_change_notification(request: Request, file1: UploadFile = File(...), file2: UploadFile = File(...)):
    """무선국 변경개설신고 자동 반영 — A파일(신고서) + B파일(DS) 업로드 → 변경된 DS 반환."""
    await _verify_auth(request)

    file1_bytes = await file1.read()
    file2_bytes = await file2.read()

    def _process():
        import xlrd

        # 1. 파일 식별 (A: 1시트+변경내역 헤더, B: 9시트)
        def _identify(data):
            try:
                wb = xlrd.open_workbook(file_contents=data)
                sheets = wb.sheet_names()
                if len(sheets) >= 5:  # DS파일은 보통 9개 시트
                    return 'B', wb
                # 1-3개 시트이면 헤더로 확인 (Row 0~3 검사)
                ws = wb.sheet_by_index(0)
                for ri in range(min(4, ws.nrows)):
                    if ws.ncols > 3:
                        row_vals = [str(ws.cell_value(ri, ci)).strip() for ci in range(min(ws.ncols, 11))]
                        if any('변경내역' in v or '변경후' in v for v in row_vals):
                            return 'A', wb
                # 시트 이름으로도 확인
                if any('변경' in sn or '신고' in sn for sn in sheets):
                    return 'A', wb
                return 'B', wb  # fallback
            except:
                return None, None

        type1, wb1 = _identify(file1_bytes)
        type2, wb2 = _identify(file2_bytes)
        logger.info(f"변경개설신고: file1={type1}(sheets={wb1.sheet_names() if wb1 else 'None'}), file2={type2}(sheets={wb2.sheet_names() if wb2 else 'None'})")

        if type1 == type2:
            raise ValueError("A파일(변경개설신고)과 B파일(DS파일)을 각각 하나씩 업로드해주세요.")

        a_wb = wb1 if type1 == 'A' else wb2
        b_wb = wb1 if type1 == 'B' else wb2
        b_bytes = file1_bytes if type1 == 'B' else file2_bytes

        # 2. A파일 파싱: 헤더 행 동적 탐색 후 데이터 추출
        a_ws = a_wb.sheet_by_index(0)
        changes = {}  # {허가번호: [{변경내역, 변경전, 변경후, 장치번호}, ...]}
        # 헤더 행 찾기 (변경내역/변경후 포함하는 행)
        header_ri = 0
        for ri in range(min(5, a_ws.nrows)):
            row_vals = [str(a_ws.cell_value(ri, ci)).strip() for ci in range(min(a_ws.ncols, 11))]
            if any('변경내역' in v for v in row_vals):
                header_ri = ri
                break
        # 컬럼 인덱스 매핑 (G열=장치번호 추가)
        col_map = {}
        for ci in range(min(a_ws.ncols, 11)):
            h = str(a_ws.cell_value(header_ri, ci)).replace('\n', '').strip()
            if '허가번호' in h: col_map['허가번호'] = ci
            elif '변경내역' in h: col_map['변경내역'] = ci
            elif '변경전' in h: col_map['변경전'] = ci
            elif '변경후' in h: col_map['변경후'] = ci
            elif '장치번호' in h: col_map['장치번호'] = ci
        hn_ci = col_map.get('허가번호', 2)
        chg_ci = col_map.get('변경내역', 3)
        before_ci = col_map.get('변경전', 4)
        after_ci = col_map.get('변경후', 5)
        device_ci = col_map.get('장치번호', 6)  # G열 (없으면 공란)

        for ri in range(header_ri + 1, a_ws.nrows):
            허가번호 = str(a_ws.cell_value(ri, hn_ci) if a_ws.ncols > hn_ci else '').strip()
            변경내역 = str(a_ws.cell_value(ri, chg_ci) if a_ws.ncols > chg_ci else '').strip()
            변경전 = str(a_ws.cell_value(ri, before_ci) if a_ws.ncols > before_ci else '').strip()
            변경후 = str(a_ws.cell_value(ri, after_ci) if a_ws.ncols > after_ci else '').strip()
            # 장치번호: 숫자로 올 수 있으므로 int 변환 후 문자열화
            _dev_raw = a_ws.cell_value(ri, device_ci) if a_ws.ncols > device_ci else ''
            if isinstance(_dev_raw, float) and _dev_raw == int(_dev_raw):
                장치번호 = str(int(_dev_raw))
            else:
                장치번호 = str(_dev_raw).strip()
            if not 허가번호 or not 변경후:
                continue
            changes.setdefault(허가번호, []).append({
                '변경내역': 변경내역,
                '변경전': 변경전,
                '변경후': 변경후,
                '장치번호': 장치번호,
            })

        logger.info(f"변경개설신고: A파일 {len(changes)}건 허가번호 파싱, 샘플={list(changes.keys())[:3]}")
        if not changes:
            raise ValueError("A파일에 변경 데이터가 없습니다.")

        # 3. 설치형태 코드 매핑
        설치형태_MAP = {
            '철탑(지면)': '1', '철탑': '1',
            '강관주': '2',
            '통신주': '3',
            '원폴(건물)': '4', '원폴': '4',
            '옥내, 터널, 지하, 차량': '6', '옥내': '6', '터널': '6', '지하': '6', '차량': '6',
            '쌍통신주': '8',
            '기설물': '9',
            '옥내외 혼합형': '11', '옥내외혼합형': '11',
            '간이폴 및 비기준 설치대': '12', '간이폴': '12', '간이폴, 분산폴 및 비기준 설치대': '12',
            '한전주(KT통신주)': '13', '한전주': '13',
            '철탑(건물)': '14',
            '프레임': '15',
            '복합형(원폴,분산프레임 등)': '21', '복합형': '21',
            '모노폴': '25',
        }

        # 4. 변경후 값 파싱 헬퍼
        def _parse_value(변경내역, 변경후):
            """변경후(F열) 우선으로 값/대상 시트를 판별."""
            v = 변경후.strip()
            chg = 변경내역.strip()
            v_norm = v.replace('\r\n', '\n').replace('\r', '\n').strip()
            v_upper = v_norm.upper()

            def _extract_after_colon(text):
                return text.split(':', 1)[1].strip() if ':' in text else text.strip()

            def _parse_install_type(text):
                raw = _extract_after_colon(text)
                code = 설치형태_MAP.get(raw, '')
                if not code:
                    for k, c in 설치형태_MAP.items():
                        if k in raw or raw in k:
                            code = c
                            break
                return {'sheet': '안테나', 'col': 28, 'value': code or raw, 'type': '설치형태'}

            # F열에 설치형태가 직접 들어온 경우
            if '설치형태' in v_norm:
                return _parse_install_type(v_norm)

            # F열에 형식검정번호가 직접 들어온 경우
            if '형검' in v_norm or '형식검정' in v_norm:
                return {'sheet': '장치', 'col': 11, 'value': _extract_after_colon(v_norm), 'type': '형식검정번호'}

            # F열에 일련번호가 직접 들어온 경우
            if '일련번호' in v_norm:
                return {'sheet': '장치', 'col': 8, 'value': _extract_after_colon(v_norm), 'type': '일련번호'}

            # F열 값 패턴 기반 판별 (문구가 "송수신장치 변경" 등으로 오는 케이스 대응)
            if (
                v_upper.startswith('MSIP-')
                or v_upper.startswith('RRA-')
                or v_upper.startswith('KCC-')
                or '-CRI-' in v_upper
                or '-CRM-' in v_upper
            ):
                return {'sheet': '장치', 'col': 11, 'value': v_norm, 'type': '형식검정번호'}

            if any(tok in v_norm for tok in ('특별시', '광역시', '특별자치시', '특별자치도', '시 ', '군 ', '구 ', '읍 ', '면 ', '동 ', '리 ')):
                return {'sheet': '설치장소', 'col': 6, 'value': v_norm, 'type': '설치장소'}

            if any(k in v_norm or v_norm in k for k in 설치형태_MAP.keys()):
                return _parse_install_type(v_norm)

            # 영숫자(하이픈 포함) 위주면 일련번호로 간주
            alnum = ''.join(ch for ch in v_norm if ch.isalnum())
            if len(alnum) >= 6 and not any(ch in v_norm for ch in (' ', '\n', '특별시', '광역시', '시', '군', '구', '읍', '면', '동', '리')):
                return {'sheet': '장치', 'col': 8, 'value': v_norm, 'type': '일련번호'}

            # 최후 fallback: D열(변경내역) 기준
            if '형식검정' in chg:
                return {'sheet': '장치', 'col': 11, 'value': _extract_after_colon(v_norm), 'type': '형식검정번호'}
            elif '일련번호' in chg:
                return {'sheet': '장치', 'col': 8, 'value': _extract_after_colon(v_norm), 'type': '일련번호'}
            elif '설치장소' in chg:
                # 주소 그대로
                return {'sheet': '설치장소', 'col': 6, 'value': v_norm, 'type': '설치장소'}
            elif '설치형태' in chg:
                return _parse_install_type(v_norm)

            return None

        # 5. 허가번호 하이픈 제거 매핑 (A↔B 매칭용)
        changes_norm = {}
        for hn, chg_list in changes.items():
            norm = hn.replace('-', '')
            changes_norm[norm] = chg_list
        logger.info(f"변경개설신고: norm keys 샘플={list(changes_norm.keys())[:3]}")

        # 5-1. 호출명칭 맵 (ds_detail.db 조회 → 없으면 빈값)
        callname_map = {}
        if os.path.exists(_DS_DETAIL_DB):
            try:
                import sqlite3 as _sq3
                _dc = _sq3.connect(_DS_DETAIL_DB, timeout=10)
                _norms = list(changes_norm.keys())
                if _norms:
                    _ph = ','.join('?' * len(_norms))
                    for _r in _dc.execute(f'SELECT 허가번호, 호출명칭, 무선국명 FROM ds_일반사항 WHERE 허가번호 IN ({_ph})', _norms):
                        callname_map[_r[0]] = _r[1] or _r[2] or ''
                _dc.close()
            except Exception:
                pass

        # 6. B파일을 xlwt로 복사 + 서식 적용 (실제 xls 포맷)
        import xlwt

        out_wb = xlwt.Workbook(encoding='utf-8')

        # xlwt 스타일 생성
        def _make_style(yellow=False):
            style = xlwt.XFStyle()
            fnt = xlwt.Font()
            fnt.name = 'Arial'
            fnt.height = 200  # 10pt
            style.font = fnt
            al = xlwt.Alignment()
            al.horz = xlwt.Alignment.HORZ_CENTER
            al.vert = xlwt.Alignment.VERT_CENTER
            al.wrap = xlwt.Alignment.WRAP_AT_RIGHT
            style.alignment = al
            brd = xlwt.Borders()
            brd.left = brd.right = brd.top = brd.bottom = xlwt.Borders.THIN
            style.borders = brd
            if yellow:
                pat = xlwt.Pattern()
                pat.pattern = xlwt.Pattern.SOLID_PATTERN
                pat.pattern_fore_colour = 13  # yellow
                style.pattern = pat
            return style

        _st = _make_style(yellow=False)
        _st_y = _make_style(yellow=True)

        change_log = []
        au_entries = {}  # {norm_hn: 변경내역 text}

        def _norm_hn(val):
            if isinstance(val, float):
                return str(int(val))
            return str(val).strip().replace('-', '')

        def _line_count(val):
            text = '' if val is None else str(val)
            text = text.replace('\r\n', '\n').replace('\r', '\n')
            return max(1, text.count('\n') + 1)

        def _write(ws, r, c, val, style):
            if val is None:
                ws.write(r, c, '', style)
            elif isinstance(val, float) and val == int(val):
                ws.write(r, c, int(val), style)
            else:
                ws.write(r, c, val, style)

        # 일반사항 시트명 사전 파악
        일반_sn_pre = None
        for _sn in b_wb.sheet_names():
            if '일반사항' in _sn or '일반' in _sn:
                일반_sn_pre = _sn
                break

        AU_0 = 46  # AU열 0-based 인덱스

        # 사전 패스: au_entries 미리 수집 (일반사항 시트 기입 시 순서 무관하게 사용)
        for si in range(len(b_wb.sheet_names())):
            sn = b_wb.sheet_names()[si]
            b_ws = b_wb.sheet_by_index(si)
            for ri in range(1, b_ws.nrows):
                hn_norm = _norm_hn(b_ws.cell_value(ri, 0))
                chg_list = changes_norm.get(hn_norm)
                if not chg_list:
                    continue
                for chg in chg_list:
                    parsed = _parse_value(chg['변경내역'], chg['변경후'])
                    if parsed:
                        au_entries[hn_norm] = chg['변경내역']

        # 설치장소 시트 사전 집계: 허가번호별 행 수 (4개 이상이면 04행 스킵)
        설치장소_hn_count = {}  # {hn_norm: count}
        for si in range(len(b_wb.sheet_names())):
            sn = b_wb.sheet_names()[si]
            if '설치장소' not in sn:
                continue
            b_ws = b_wb.sheet_by_index(si)
            for ri in range(1, b_ws.nrows):
                hn = _norm_hn(b_ws.cell_value(ri, 0))
                설치장소_hn_count[hn] = 설치장소_hn_count.get(hn, 0) + 1

        # Pass 1: 모든 시트 복사 + 변경 적용
        for si in range(len(b_wb.sheet_names())):
            sn = b_wb.sheet_names()[si]
            b_ws = b_wb.sheet_by_index(si)
            o_ws = out_wb.add_sheet(sn[:31])
            is_일반 = (sn == 일반_sn_pre)
            is_설치장소 = '설치장소' in sn
            is_안테나 = '안테나' in sn

            # 열 너비 (xlwt 단위 256 = 1문자, 19.29문자 ≈ 4938)
            col_out_count = b_ws.ncols + (2 if is_일반 else 0)
            for ci in range(max(col_out_count, 49 if is_일반 else b_ws.ncols)):
                o_ws.col(ci).width = 4938

            seen_hn = set()
            out_ri = 0

            for ri in range(b_ws.nrows):
                # 일반사항: 중복 허가번호 스킵
                if is_일반 and ri > 0:
                    hn_check = _norm_hn(b_ws.cell_value(ri, 0))
                    if hn_check in seen_hn:
                        continue
                    seen_hn.add(hn_check)

                # 이 행의 오버라이드 {0-based 출력열: (value, yellow)}
                overrides = {}

                if ri > 0:
                    hn_norm = _norm_hn(b_ws.cell_value(ri, 0))
                    chg_list = changes_norm.get(hn_norm)

                    # ── 공통 선제 적용 ──

                    # [공통2] 장치/전파형식/주파수: 변경 대상 허가번호 행이면 철거구분 N
                    if chg_list:
                        _철거구분_col = {'장치': 24, '전파형식': 8, '주파수': 9}.get(sn)
                        if _철거구분_col is not None:
                            overrides[_철거구분_col] = ('N', False)

                    # [공통3] 안테나: AC열(설치형태, 0-based=28) 값 있고 AB열(0-based=27) 비어있으면 AB 채우기
                    if is_안테나 and chg_list:
                        ac_val = str(b_ws.cell_value(ri, 28) if b_ws.ncols > 28 else '').strip()
                        ab_cur = str(b_ws.cell_value(ri, 27) if b_ws.ncols > 27 else '').strip()
                        if ac_val and not ab_cur:
                            ab_fill = '1' if ac_val in ('6', '11') else '2'
                            overrides[27] = (ab_fill, False)

                    # [공통4] 설치장소: 허가번호당 4행이면 D열(0-based=3)이 '04'인 행 스킵
                    if is_설치장소 and 설치장소_hn_count.get(hn_norm, 0) >= 4:
                        d_val = str(b_ws.cell_value(ri, 3) if b_ws.ncols > 3 else '').strip()
                        if d_val == '04':
                            continue  # 이 행 출력 스킵

                    if chg_list:
                        # B파일 현재 행의 장치번호(C열=2), 일련번호(I열=8), 형검번호(L열=11) 미리 추출
                        b_device_no = str(b_ws.cell_value(ri, 2) if b_ws.ncols > 2 else '').strip()
                        if b_device_no and isinstance(b_ws.cell_value(ri, 2), float):
                            b_device_no = str(int(b_ws.cell_value(ri, 2)))
                        b_serial = str(b_ws.cell_value(ri, 8) if b_ws.ncols > 8 else '').strip()
                        b_형검 = str(b_ws.cell_value(ri, 11) if b_ws.ncols > 11 else '').strip()

                        for chg in chg_list:
                            parsed = _parse_value(chg['변경내역'], chg['변경후'])
                            if not parsed or parsed['sheet'] != sn:
                                continue

                            target_col = parsed['col']  # 0-based
                            new_val = parsed['value']
                            old_val = str(b_ws.cell_value(ri, target_col) if target_col < b_ws.ncols else '').strip()

                            # ── 장치번호 기반 행 특정 (일련번호/형검번호) ──
                            # A파일에 장치번호가 있으면 → 허가번호 + 장치번호로 행 특정
                            # A파일에 장치번호 없고 일련번호 변경이면 → 변경전 값으로 행 특정
                            a_device = chg.get('장치번호', '').strip()
                            a_before = chg.get('변경전', '').strip()

                            if parsed['type'] in ('일련번호', '형식검정번호'):
                                if a_device:
                                    # 장치번호가 명시된 경우: B파일 C열(장치번호)과 비교
                                    if b_device_no != a_device:
                                        continue  # 장치번호 불일치 → 이 행 건너뜀
                                elif parsed['type'] == '일련번호' and a_before:
                                    # 장치번호 없고 변경전 일련번호 있으면 → 일련번호로 행 특정
                                    if b_serial != a_before:
                                        continue  # 일련번호 불일치 → 이 행 건너뜀
                                # 장치번호도 없고 변경전도 없으면 → 허가번호만으로 전체 적용 (기존 동작)

                            if parsed['type'] == '설치형태':
                                j_val = str(b_ws.cell_value(ri, 9) if b_ws.ncols > 9 else '').strip()
                                ab_0 = 27  # AB열 0-based
                                if not j_val:
                                    overrides[target_col] = ('', False)
                                    overrides[ab_0] = ('', False)
                                    continue
                                ab_val = '1' if new_val in ('6', '11') else '2'
                                overrides[ab_0] = (ab_val, False)
                                _고도_기본값 = {
                                    '3': '16', '4': '6', '6': '1', '8': '16',
                                    '11': '2', '12': '3', '13': '16', '15': '2', '25': '2',
                                }
                                _고도_val = _고도_기본값.get(new_val)
                                if _고도_val:
                                    for _고도_0 in (14, 21, 29):  # O, V, AD 0-based
                                        overrides[_고도_0] = (_고도_val, False)

                            overrides[target_col] = (new_val, True)
                            au_entries[hn_norm] = chg['변경내역']
                            change_log.append({
                                '허가번호': hn_norm, 'sheet': sn,
                                'type': parsed['type'], 'old': old_val, 'new': new_val,
                                '장치번호': a_device or b_device_no,
                            })

                    # 일반사항: AU열에 변경내역 기입
                    if is_일반 and hn_norm in au_entries:
                        overrides[AU_0] = (au_entries[hn_norm], True)

                # 셀 쓰기 — 일반사항은 AU열(0-based=46) 이후 출력열을 +2 오프셋
                max_lines = 1
                out_ci = 0
                for ci in range(b_ws.ncols):
                    val = b_ws.cell_value(ri, ci)
                    if b_ws.cell_type(ri, ci) == xlrd.XL_CELL_DATE:
                        try:
                            val = xlrd.xldate_as_datetime(val, b_wb.datemode).strftime('%Y-%m-%d')
                        except:
                            pass
                    if ci in overrides:
                        val, yellow = overrides[ci]
                    else:
                        yellow = False
                    max_lines = max(max_lines, _line_count(val))
                    _write(o_ws, out_ri, out_ci, val, _st_y if yellow else _st)
                    out_ci += 1
                    # 일반사항: AU열 직후 빈 열 2개 삽입
                    if is_일반 and ci == AU_0:
                        _write(o_ws, out_ri, out_ci, '', _st)
                        _write(o_ws, out_ri, out_ci + 1, '', _st)
                        out_ci += 2

                # 행 높이 (xlwt: 1/20pt, 12.75pt → 255)
                o_ws.row(out_ri).height_mismatch = True
                o_ws.row(out_ri).height = int(255 * max_lines)
                out_ri += 1

        logger.info(f"변경개설신고: {len(au_entries)}건 AU열 기입, {len(change_log)}건 변경 적용, 일반사항 빈열 2개 삽입")

        # 7. 결과 바이트 생성
        buf = io.BytesIO()
        out_wb.save(buf)
        buf.seek(0)

        # 8. diff 구조 빌드 (허가번호별 그룹핑, 중복 제거)
        import base64
        diff_map: dict = {}
        for _entry in change_log:
            _hn = _entry['허가번호']
            if _hn not in diff_map:
                diff_map[_hn] = {'허가번호': _hn, '호출명칭': callname_map.get(_hn, ''), 'changes': []}
            _key = (_entry['type'], _entry['sheet'], _entry.get('장치번호', ''))
            if not any(
                c['field'] == _entry['type'] and c['sheet'] == _entry['sheet'] and c.get('장치번호', '') == _entry.get('장치번호', '')
                for c in diff_map[_hn]['changes']
            ):
                diff_map[_hn]['changes'].append({
                    'field': _entry['type'], 'sheet': _entry['sheet'],
                    'before': _entry['old'], 'after': _entry['new'],
                    '장치번호': _entry.get('장치번호', ''),
                })

        b_fname = file1.filename if type1 == 'B' else file2.filename
        b_stem = b_fname.rsplit('.', 1)[0] if b_fname and '.' in b_fname else (b_fname or 'DS파일')
        return {
            'xls_base64': base64.b64encode(buf.getvalue()).decode('utf-8'),
            'filename': f"{b_stem}_변경후.xls",
            'diff': list(diff_map.values()),
            'change_count': len(change_log),
            'target_count': len(changes),
        }

    try:
        result = await asyncio.to_thread(_process)
    except ValueError as e:
        raise HTTPException(400, str(e))

    from fastapi.responses import JSONResponse as _JSONResponse
    return _JSONResponse(content=result)


@app.post("/document/apply-change-notification")
async def document_apply_change_notification(request: Request):
    """변경개설신고 diff 결과를 ds_detail.db에 반영하고 이력 저장."""
    await _verify_auth(request)
    import sqlite3, datetime as _dt
    body = await request.json()
    selected = set(body.get('selected', []))      # 허가번호 norm (하이픈 없음)
    diff = body.get('diff', [])
    applied_date = body.get('applied_date', _dt.datetime.now().strftime('%y%m%d'))

    if not selected or not diff:
        raise HTTPException(400, "선택된 국소가 없습니다.")

    def _apply_sync():
        dc = sqlite3.connect(_DS_DETAIL_DB, timeout=60)
        dc.execute('PRAGMA journal_mode=WAL')
        # ds_변경이력 테이블 보장 (서버 재시작 전 반영 케이스 대비)
        dc.execute('''CREATE TABLE IF NOT EXISTS ds_변경이력 (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            허가번호 TEXT NOT NULL, 변경일자 TEXT NOT NULL,
            시트 TEXT NOT NULL, 필드명 TEXT NOT NULL,
            변경전값 TEXT, 변경후값 TEXT, 장치번호 TEXT
        )''')
        ic = sqlite3.connect(_INSP_DB, timeout=60)
        ic.execute('PRAGMA journal_mode=WAL')
        applied = 0
        not_found_hns: set = set()  # inspection_targets에 없어서 반영 실패한 허가번호
        for item in diff:
            hn = item.get('허가번호', '')
            if hn not in selected:
                continue
            for chg in item.get('changes', []):
                field  = chg.get('field', '')
                sheet  = chg.get('sheet', '')
                before = chg.get('before', '')
                after  = chg.get('after', '')
                jn     = chg.get('장치번호', '')
                if field == '일련번호':
                    if jn:
                        cur = dc.execute('UPDATE ds_장치 SET 기기일련번호=? WHERE 허가번호=? AND 장치번호=?', (after, hn, jn))
                    else:
                        cur = dc.execute('UPDATE ds_장치 SET 기기일련번호=? WHERE 허가번호=?', (after, hn))
                    if cur.rowcount == 0:
                        not_found_hns.add(hn)
                        continue
                elif field == '형식검정번호':
                    if jn:
                        cur = dc.execute('UPDATE ds_장치 SET 형식검정번호=? WHERE 허가번호=? AND 장치번호=?', (after, hn, jn))
                    else:
                        cur = dc.execute('UPDATE ds_장치 SET 형식검정번호=? WHERE 허가번호=?', (after, hn))
                    if cur.rowcount == 0:
                        not_found_hns.add(hn)
                        continue
                elif field == '설치형태':
                    if jn:
                        cur = dc.execute('UPDATE ds_안테나 SET 공중선주설치형태명=? WHERE 허가번호=? AND 장치번호=?', (after, hn, jn))
                    else:
                        cur = dc.execute('UPDATE ds_안테나 SET 공중선주설치형태명=? WHERE 허가번호=?', (after, hn))
                    if cur.rowcount == 0:
                        not_found_hns.add(hn)
                        continue
                elif field == '설치장소':
                    cur = ic.execute("UPDATE inspection_targets SET 설치장소=? WHERE REPLACE(허가번호,'-','')=?", (after, hn))
                    if cur.rowcount == 0:
                        not_found_hns.add(hn)
                        continue  # 이력 기록 스킵 (실제 반영 안 됐으므로)
                dc.execute(
                    'INSERT INTO ds_변경이력(허가번호,변경일자,시트,필드명,변경전값,변경후값,장치번호) VALUES(?,?,?,?,?,?,?)',
                    (hn, applied_date, sheet, field, before, after, jn)
                )
                applied += 1
        dc.commit(); ic.commit()
        dc.close();  ic.close()
        return applied, sorted(not_found_hns)

    applied, not_found = await asyncio.to_thread(_apply_sync)
    logger.info(f"변경개설신고 반영: {len(selected)}개 국소, {applied}건 적용 (날짜={applied_date}), 미반영={not_found}")
    return {"ok": True, "applied": applied, "not_found": not_found}


_CHANGE_NOTIFICATION_SAMPLE_META_KEY = "excel/change-notification-sample-meta.json"
_CHANGE_NOTIFICATION_SAMPLE_PREFIX = "excel/change-notification-sample"


def _get_sample_meta_sync() -> dict:
    """현재 샘플 파일 메타(key, filename) 조회. 없으면 빈 dict."""
    try:
        obj = _s3_client.get_object(Bucket=S3_BUCKET_NAME, Key=_CHANGE_NOTIFICATION_SAMPLE_META_KEY)
        return json.loads(obj["Body"].read().decode())
    except ClientError as e:
        if e.response.get("Error", {}).get("Code", "") in ("404", "NoSuchKey"):
            return {}
        raise


@app.get("/document/change-notification-sample")
async def get_change_notification_sample(request: Request):
    """변경개설신고 샘플 양식 presigned URL 반환 (모든 인증된 사용자)."""
    await _verify_auth(request)
    meta = await asyncio.to_thread(_get_sample_meta_sync)
    if not meta.get("key"):
        raise HTTPException(404, "샘플 양식 파일이 없습니다. 관리자에게 문의하세요.")
    original_filename = meta.get("filename", "변경개설신고_샘플양식")
    encoded_name = quote(original_filename, safe="")
    url = _s3_client.generate_presigned_url(
        "get_object",
        Params={
            "Bucket": S3_BUCKET_NAME,
            "Key": meta["key"],
            "ResponseContentDisposition": f"attachment; filename*=UTF-8''{encoded_name}",
        },
        ExpiresIn=300,
    )
    return {"url": url, "filename": original_filename}


@app.post("/document/change-notification-sample")
async def upload_change_notification_sample(request: Request, file: UploadFile = File(...)):
    """변경개설신고 샘플 양식 업로드 (admin/manager 전용)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in ("admin", "manager"):
        raise HTTPException(403, "관리자만 샘플 양식을 업로드할 수 있습니다.")
    if not file.filename.lower().endswith((".xls", ".xlsx", ".zip")):
        raise HTTPException(400, "xls, xlsx, zip 파일만 업로드 가능합니다.")
    data = await file.read()
    ext = file.filename.lower().rsplit(".", 1)[-1]
    content_type = {
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "xls": "application/vnd.ms-excel",
        "zip": "application/zip",
    }.get(ext, "application/octet-stream")
    s3_key = f"{_CHANGE_NOTIFICATION_SAMPLE_PREFIX}.{ext}"
    meta = json.dumps({"key": s3_key, "filename": file.filename}, ensure_ascii=False).encode()
    await asyncio.to_thread(
        lambda: _s3_client.put_object(Bucket=S3_BUCKET_NAME, Key=s3_key, Body=data, ContentType=content_type)
    )
    await asyncio.to_thread(
        lambda: _s3_client.put_object(
            Bucket=S3_BUCKET_NAME, Key=_CHANGE_NOTIFICATION_SAMPLE_META_KEY,
            Body=meta, ContentType="application/json",
        )
    )
    logger.info(f"변경개설신고 샘플 업로드: {empno}, {file.filename}, {len(data)} bytes")
    return {"ok": True}


# ============================================================
# Community Board (공지사항/요청사항)
# ============================================================

_COMMUNITY_DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "community.db")


def _init_community_db():
    conn = sqlite3.connect(_COMMUNITY_DB, timeout=60)
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('''CREATE TABLE IF NOT EXISTS notices (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        content TEXT,
        division TEXT DEFAULT '전체',
        author_empno TEXT,
        author_name TEXT,
        author_org TEXT DEFAULT '',
        view_count INTEGER DEFAULT 0,
        created_at TEXT,
        updated_at TEXT
    )''')
    conn.execute('''CREATE TABLE IF NOT EXISTS requests (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        content TEXT,
        status TEXT DEFAULT '접수',
        is_secret INTEGER DEFAULT 0,
        secret_password TEXT DEFAULT '',
        author_empno TEXT,
        author_name TEXT,
        author_org TEXT DEFAULT '',
        view_count INTEGER DEFAULT 0,
        created_at TEXT,
        updated_at TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_notices_division ON notices(division)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_notices_created ON notices(created_at)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_requests_status ON requests(status)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_requests_created ON requests(created_at)')
    conn.execute('''CREATE TABLE IF NOT EXISTS comments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        request_id INTEGER NOT NULL,
        content TEXT NOT NULL,
        author_empno TEXT NOT NULL,
        author_name TEXT NOT NULL,
        author_org TEXT DEFAULT '',
        created_at TEXT,
        FOREIGN KEY (request_id) REFERENCES requests(id) ON DELETE CASCADE
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_comments_request ON comments(request_id)')
    # comments 테이블 마이그레이션: updated_at 컬럼 추가
    try:
        conn.execute("ALTER TABLE comments ADD COLUMN updated_at TEXT DEFAULT ''")
    except Exception:
        pass
    # 대댓글(2단계) 지원: parent_id NULL이면 최상위 댓글, 값이 있으면 대댓글
    try:
        conn.execute("ALTER TABLE comments ADD COLUMN parent_id INTEGER")
    except Exception:
        pass
    conn.execute('CREATE INDEX IF NOT EXISTS idx_comments_parent ON comments(parent_id)')
    # 기존 테이블에 컬럼 추가 (이미 존재하면 무시)
    for col, default in [('secret_password', "''")]:
        try:
            conn.execute(f"ALTER TABLE requests ADD COLUMN {col} TEXT DEFAULT {default}")
        except Exception:
            pass
    # images, author_role, attachments 컬럼 추가
    for tbl in ('notices', 'requests'):
        for col, dflt in [("images", "'[]'"), ("author_role", "''"), ("attachments", "'[]'")]:
            try:
                conn.execute(f"ALTER TABLE {tbl} ADD COLUMN {col} TEXT DEFAULT {dflt}")
            except Exception:
                pass
    conn.execute('PRAGMA foreign_keys = ON')
    # notifications 테이블
    conn.execute('''CREATE TABLE IF NOT EXISTS notifications (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        user_empno   TEXT NOT NULL,
        type         TEXT NOT NULL,
        title        TEXT NOT NULL,
        body         TEXT NOT NULL,
        related_type TEXT DEFAULT '',
        related_id   INTEGER DEFAULT 0,
        is_read      INTEGER DEFAULT 0,
        created_at   TEXT NOT NULL
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_notif_user ON notifications(user_empno, is_read)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_notif_created ON notifications(created_at)')
    # Phase 5: 워크플로우 알림 통합용 추가 컬럼
    # - related_pk: schedule_pk(year#허가번호 문자열)를 related_id 대신 사용
    # - sub_type: workflow 알림 세부 타입 (PRE_CHECK_REQUESTED 등)
    for col, dflt in [
        ('related_pk', "''"),
        ('sub_type', "''"),
    ]:
        try:
            conn.execute(f"ALTER TABLE notifications ADD COLUMN {col} TEXT DEFAULT {dflt}")
        except Exception:
            pass
    conn.commit()
    conn.close()


_init_community_db()


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
    parent_id: int | None = None   # 대댓글일 때 부모 댓글 id

class CommentUpdate(BaseModel):
    content: str


_COMMUNITY_DIVISIONS = ['전체', '강남', '강북', '경기', '인천', '충청', '강원', '경남', '경북', '서부']


def _get_user_info_for_community(empno: str) -> dict:
    """Users DynamoDB 테이블에서 이름·소속 조회."""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["users"])
        resp = table.get_item(
            Key={"user_id": empno},
            ProjectionExpression="#n, #r, #t",
            ExpressionAttributeNames={"#n": "name", "#r": "region", "#t": "team"},
        )
        item = resp.get("Item", {})
        name = item.get("name", empno)
        region = item.get("region", "")
        team = item.get("team", "")
        org = team if team else region
        return {"name": name, "org": org}
    except Exception as e:
        logger.warning(f"community user info 조회 실패 ({empno}): {e}")
        return {"name": empno, "org": ""}


# ── 커뮤니티 이미지 업로드/조회 ──

_COMMUNITY_IMAGE_ALLOWED_EXT = {'.jpg', '.jpeg', '.png', '.gif', '.webp'}
_COMMUNITY_IMAGE_MAX_SIZE = 5 * 1024 * 1024  # 5MB


@app.post("/community/upload-image")
async def community_upload_image(request: Request, file: UploadFile = File(...)):
    """커뮤니티 게시판 이미지 업로드 → S3"""
    await _verify_auth(request)

    # 확장자 검증
    original_filename = file.filename or "image.jpg"
    ext = os.path.splitext(original_filename)[1].lower()
    if ext not in _COMMUNITY_IMAGE_ALLOWED_EXT:
        raise HTTPException(400, f"허용되지 않는 파일 형식입니다. ({', '.join(_COMMUNITY_IMAGE_ALLOWED_EXT)})")

    # 파일 읽기 + 크기 검증
    data = await file.read()
    if len(data) > _COMMUNITY_IMAGE_MAX_SIZE:
        raise HTTPException(400, f"파일 크기가 5MB를 초과합니다. ({len(data) / (1024*1024):.1f}MB)")

    # S3 업로드
    safe_name = re.sub(r'[^a-zA-Z0-9._-]', '_', original_filename)
    s3_key = f"community-images/{uuid.uuid4().hex}_{safe_name}"

    content_type_map = {
        '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
        '.gif': 'image/gif', '.webp': 'image/webp',
    }
    content_type = content_type_map.get(ext, 'image/jpeg')

    try:
        s3_client = get_s3_client()
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=s3_key,
            Body=data,
            ContentType=content_type,
        )
        logger.info(f"Community image uploaded: s3://{S3_BUCKET_NAME}/{s3_key} ({len(data)} bytes)")
    except Exception as e:
        logger.error(f"Community image upload failed: {e}")
        raise HTTPException(500, "이미지 업로드에 실패했습니다")

    return {"url": s3_key, "filename": original_filename}


_COMMUNITY_FILE_MAX_SIZE = 50 * 1024 * 1024  # 50MB
_COMMUNITY_FILE_CONTENT_TYPES = {
    '.pdf': 'application/pdf',
    '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    '.xls': 'application/vnd.ms-excel',
    '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    '.ppt': 'application/vnd.ms-powerpoint',
    '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    '.doc': 'application/msword',
    '.hwp': 'application/x-hwp',
    '.hwpx': 'application/x-hwpx',
    '.zip': 'application/zip',
    '.txt': 'text/plain',
    '.csv': 'text/csv',
    '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
    '.gif': 'image/gif', '.webp': 'image/webp',
}


@app.post("/community/upload-file")
async def community_upload_file(request: Request, file: UploadFile = File(...)):
    """커뮤니티 게시판 일반 파일 업로드 → S3"""
    await _verify_auth(request)

    original_filename = file.filename or "file"
    ext = os.path.splitext(original_filename)[1].lower()
    if ext not in _COMMUNITY_FILE_CONTENT_TYPES:
        raise HTTPException(400, f"허용되지 않는 파일 형식입니다. ({ext})")

    data = await file.read()
    if len(data) > _COMMUNITY_FILE_MAX_SIZE:
        raise HTTPException(400, f"파일 크기가 50MB를 초과합니다. ({len(data) / (1024*1024):.1f}MB)")

    safe_name = re.sub(r'[^a-zA-Z0-9._-]', '_', original_filename)
    s3_key = f"community-files/{uuid.uuid4().hex}_{safe_name}"
    content_type = _COMMUNITY_FILE_CONTENT_TYPES.get(ext, 'application/octet-stream')

    try:
        s3_client = get_s3_client()
        s3_client.put_object(
            Bucket=S3_BUCKET_NAME,
            Key=s3_key,
            Body=data,
            ContentType=content_type,
            ContentDisposition=f'attachment; filename="{safe_name}"',
        )
        logger.info(f"Community file uploaded: s3://{S3_BUCKET_NAME}/{s3_key} ({len(data)} bytes)")
    except Exception as e:
        logger.error(f"Community file upload failed: {e}")
        raise HTTPException(500, "파일 업로드에 실패했습니다")

    return {"url": s3_key, "filename": original_filename, "size": len(data), "ext": ext}


@app.get("/community/files/{file_key:path}")
async def community_serve_file(file_key: str, request: Request):
    """커뮤니티 첨부파일 다운로드 — S3에서 스트리밍"""
    await _verify_auth(request)
    try:
        s3_client = get_s3_client()
        obj = s3_client.get_object(Bucket=S3_BUCKET_NAME, Key=file_key)
        data = obj['Body'].read()
        content_type = obj.get('ContentType', 'application/octet-stream')
        filename = file_key.split('/')[-1]
        # UUID prefix 제거하여 원본 파일명 복원
        if '_' in filename:
            filename = filename[filename.index('_') + 1:]
        return Response(
            content=data,
            media_type=content_type,
            headers={'Content-Disposition': f'attachment; filename="{filename}"'},
        )
    except Exception as e:
        logger.error(f"Community file serve failed: {e}")
        raise HTTPException(404, "파일을 찾을 수 없습니다")


@app.get("/community/images/{image_key:path}")
async def community_serve_image(image_key: str):
    """커뮤니티 이미지 조회 — S3에서 직접 스트리밍 (인증 불필요, UUID 키로 보호)"""
    # image_key가 이미 community-images/ 포함이면 그대로, 아니면 추가
    if not image_key.startswith("community-images/"):
        image_key = f"community-images/{image_key}"

    ext = os.path.splitext(image_key)[1].lower()
    ct_map = {'.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png',
              '.gif': 'image/gif', '.webp': 'image/webp'}
    content_type = ct_map.get(ext, 'image/jpeg')

    try:
        s3_client = get_s3_client()
        obj = s3_client.get_object(Bucket=S3_BUCKET_NAME, Key=image_key)
        data = obj['Body'].read()
        return Response(content=data, media_type=content_type)
    except Exception as e:
        logger.error(f"Community image presign failed: {e}")
        raise HTTPException(500, "이미지를 불러올 수 없습니다")


# ── 공지사항 endpoints ──


@app.get("/community/notices")
async def list_notices(
    request: Request,
    division: str = Query(None),
    search: str = Query(None),
    page: int = Query(1, ge=1),
    pageSize: int = Query(20, ge=1, le=100),
):
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            where_clauses = []
            params = []
            if division:
                where_clauses.append("division = ?")
                params.append(division)
            if search:
                where_clauses.append("(title LIKE ? OR content LIKE ?)")
                params.extend([f"%{search}%", f"%{search}%"])
            where_sql = (" WHERE " + " AND ".join(where_clauses)) if where_clauses else ""

            total = conn.execute(f"SELECT COUNT(*) FROM notices{where_sql}", params).fetchone()[0]

            offset = (page - 1) * pageSize
            rows = conn.execute(
                f"SELECT * FROM notices{where_sql} ORDER BY created_at DESC LIMIT ? OFFSET ?",
                params + [pageSize, offset],
            ).fetchall()

            notices = []
            for i, row in enumerate(rows):
                d = dict(row)
                d["번호"] = total - offset - i
                d["is_mine"] = (d.get("author_empno") == empno)
                notices.append(d)
            return {"notices": notices, "total": total}
        finally:
            conn.close()

    return await asyncio.to_thread(_do)


@app.get("/community/notices/{notice_id}")
async def get_notice(notice_id: int, request: Request):
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT * FROM notices WHERE id = ?", (notice_id,)).fetchone()
            if not row:
                raise HTTPException(404, "공지사항을 찾을 수 없습니다")
            d = dict(row)
            d["is_mine"] = (d.get("author_empno") == empno)
            return d
        finally:
            conn.close()

    return await asyncio.to_thread(_do)


@app.post("/community/notices/{notice_id}/view")
async def increment_notice_view(notice_id: int, request: Request):
    await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        try:
            conn.execute("UPDATE notices SET view_count = view_count + 1 WHERE id = ?", (notice_id,))
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}


@app.post("/community/notices")
async def create_notice(body: NoticeCreate, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in ("admin", "manager"):
        raise HTTPException(403, "관리자 또는 매니저만 공지사항을 작성할 수 있습니다")

    user_info = await asyncio.to_thread(_get_user_info_for_community, empno)
    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            cur = conn.execute(
                "INSERT INTO notices (title, content, division, author_empno, author_name, author_org, author_role, images, attachments, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (body.title, body.content, body.division, empno, user_info["name"], user_info["org"], role, json.dumps(body.images), json.dumps(body.attachments), now, now),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM notices WHERE id = ?", (cur.lastrowid,)).fetchone()
            return dict(row), cur.lastrowid
        finally:
            conn.close()

    result, notice_id = await asyncio.to_thread(_do)

    # 비동기로 알림 발송 (응답 블로킹 없음)
    async def _send_notice_notifications():
        try:
            all_users = await asyncio.to_thread(_list_all_users_sync)
            division = body.division  # '전체' 또는 특정 본부명
            targets = [
                u for u in all_users
                if not u.get("is_dormant")
                and u.get("empno") != empno
                and (
                    division == '전체'
                    or division in (u.get("region") or '')
                    or u.get("role") == "admin"  # admin은 모든 공지 알림 수신
                )
            ]

            def _bulk_insert():
                conn2 = sqlite3.connect(_COMMUNITY_DB, timeout=30)
                try:
                    _now = datetime.now(timezone.utc).isoformat()
                    notif_title = f'[{"전체" if division == "전체" else division}] 새 공지사항'
                    conn2.executemany(
                        "INSERT INTO notifications (user_empno, type, title, body, related_type, related_id, created_at) "
                        "VALUES (?, 'notice', ?, ?, 'notice', ?, ?)",
                        [
                            (u["empno"], notif_title, body.title[:60], notice_id, _now)
                            for u in targets
                        ],
                    )
                    conn2.commit()
                finally:
                    conn2.close()

            if targets:
                await asyncio.to_thread(_bulk_insert)
        except Exception as e:
            logger.warning(f"공지 알림 발송 실패: {e}")

    asyncio.create_task(_send_notice_notifications())

    return {"success": True, "notice": result}


@app.put("/community/notices/{notice_id}")
async def update_notice(notice_id: int, body: NoticeUpdate, request: Request):
    empno = await _verify_auth(request)
    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT author_empno FROM notices WHERE id = ?", (notice_id,)).fetchone()
            if not row:
                raise HTTPException(404, "공지사항을 찾을 수 없습니다")
            if row["author_empno"] != empno:
                raise HTTPException(403, "작성자만 수정할 수 있습니다")
            conn.execute(
                "UPDATE notices SET title = ?, content = ?, division = ?, images = ?, attachments = ?, updated_at = ? WHERE id = ?",
                (body.title, body.content, body.division, json.dumps(body.images), json.dumps(body.attachments), now, notice_id),
            )
            conn.commit()
            updated = conn.execute("SELECT * FROM notices WHERE id = ?", (notice_id,)).fetchone()
            return dict(updated)
        finally:
            conn.close()

    result = await asyncio.to_thread(_do)
    return {"success": True, "notice": result}


@app.delete("/community/notices/{notice_id}")
async def delete_notice(notice_id: int, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT author_empno FROM notices WHERE id = ?", (notice_id,)).fetchone()
            if not row:
                raise HTTPException(404, "공지사항을 찾을 수 없습니다")
            if row["author_empno"] != empno and role != "admin":
                raise HTTPException(403, "작성자 또는 관리자만 삭제할 수 있습니다")
            conn.execute("DELETE FROM notices WHERE id = ?", (notice_id,))
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}


# ── 커뮤니티 통계 ──


@app.get("/community/stats")
async def community_stats(request: Request):
    """커뮤니티 요약 통계 (개인별 + 전체 요청 + 공지)"""
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        try:
            # 개인별 요청
            my_total = conn.execute("SELECT COUNT(*) FROM requests WHERE author_empno=?", (empno,)).fetchone()[0]
            my_접수 = conn.execute("SELECT COUNT(*) FROM requests WHERE author_empno=? AND status='접수'", (empno,)).fetchone()[0]
            my_처리중 = conn.execute("SELECT COUNT(*) FROM requests WHERE author_empno=? AND status='처리중'", (empno,)).fetchone()[0]
            my_완료 = conn.execute("SELECT COUNT(*) FROM requests WHERE author_empno=? AND status='완료'", (empno,)).fetchone()[0]
            # 전체 요청
            all_total = conn.execute("SELECT COUNT(*) FROM requests").fetchone()[0]
            all_접수 = conn.execute("SELECT COUNT(*) FROM requests WHERE status='접수'").fetchone()[0]
            all_처리중 = conn.execute("SELECT COUNT(*) FROM requests WHERE status='처리중'").fetchone()[0]
            all_완료 = conn.execute("SELECT COUNT(*) FROM requests WHERE status='완료'").fetchone()[0]
            # 공지
            notice_total = conn.execute("SELECT COUNT(*) FROM notices").fetchone()[0]
            return {
                "my": {"total": my_total, "접수": my_접수, "처리중": my_처리중, "완료": my_완료},
                "all": {"total": all_total, "접수": all_접수, "처리중": all_처리중, "완료": all_완료},
                "notices": notice_total,
                "daily_visitors": _count_daily_visitors(),
            }
        finally:
            conn.close()

    return await asyncio.to_thread(_do)


# ── 요청사항 endpoints ──


@app.get("/community/requests")
async def list_requests(
    request: Request,
    status: str = Query(None),
    search: str = Query(None),
    page: int = Query(1, ge=1),
    pageSize: int = Query(20, ge=1, le=100),
):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            where_clauses = []
            params = []
            if status:
                where_clauses.append("status = ?")
                params.append(status)
            if search:
                where_clauses.append("(title LIKE ? OR content LIKE ?)")
                params.extend([f"%{search}%", f"%{search}%"])
            where_sql = (" WHERE " + " AND ".join(where_clauses)) if where_clauses else ""

            total = conn.execute(f"SELECT COUNT(*) FROM requests{where_sql}", params).fetchone()[0]

            offset = (page - 1) * pageSize
            rows = conn.execute(
                f"SELECT * FROM requests{where_sql} ORDER BY created_at DESC LIMIT ? OFFSET ?",
                params + [pageSize, offset],
            ).fetchall()

            items = []
            for i, row in enumerate(rows):
                d = dict(row)
                d["번호"] = total - offset - i
                # 비밀글: 작성자/관리자가 아니면 제목·내용 숨김
                d["is_mine"] = (d.get("author_empno") == empno)
                if d["is_secret"] and d["author_empno"] != empno and role != "admin":
                    d["title"] = "비밀글입니다"
                    d["content"] = ""
                items.append(d)
            return {"requests": items, "total": total}
        finally:
            conn.close()

    return await asyncio.to_thread(_do)


@app.get("/community/requests/{req_id}")
async def get_request_detail(req_id: int, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT * FROM requests WHERE id = ?", (req_id,)).fetchone()
            if not row:
                raise HTTPException(404, "요청사항을 찾을 수 없습니다")
            d = dict(row)
            d["is_mine"] = (d.get("author_empno") == empno)
            if d["is_secret"] and d["author_empno"] != empno and role != "admin":
                raise HTTPException(403, "비밀글은 작성자와 관리자만 열람할 수 있습니다")
            return d
        finally:
            conn.close()

    return await asyncio.to_thread(_do)


@app.post("/community/requests/{req_id}/view")
async def increment_request_view(req_id: int, request: Request):
    await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        try:
            conn.execute("UPDATE requests SET view_count = view_count + 1 WHERE id = ?", (req_id,))
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}


@app.post("/community/requests")
async def create_request(body: RequestCreate, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    user_info = await asyncio.to_thread(_get_user_info_for_community, empno)
    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            cur = conn.execute(
                "INSERT INTO requests (title, content, is_secret, secret_password, author_empno, author_name, author_org, author_role, images, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (body.title, body.content, 1 if body.is_secret else 0, body.secret_password, empno, user_info["name"], user_info["org"], role, json.dumps(body.images), now, now),
            )
            conn.commit()
            row = conn.execute("SELECT * FROM requests WHERE id = ?", (cur.lastrowid,)).fetchone()
            return dict(row), cur.lastrowid
        finally:
            conn.close()

    result, request_id = await asyncio.to_thread(_do)

    # admin에게 새 요청 알림 — 응답 반환 전 동기 실행 (누락 방지)
    # _list_all_users_sync는 60초 캐시라 일반적으로 빠름. 첫 호출만 ~1초 추가.
    try:
        all_users = await asyncio.to_thread(_list_all_users_sync)
        logger.info(f"[req-notify] request_id={request_id}, requester={empno}, total_users={len(all_users)}")
        # 진단: admin 전원 목록 + 필터 사유 기록
        all_admins = [u for u in all_users if u.get("role") == "admin"]
        logger.info(f"[req-notify] all_admins_in_cache={len(all_admins)}, "
                   f"empnos={[u.get('empno') for u in all_admins]}, "
                   f"dormant={[u.get('empno') for u in all_admins if u.get('is_dormant')]}")
        admins = [
            u for u in all_users
            if u.get("role") == "admin"
            and not u.get("is_dormant")
            and u.get("empno") != empno
        ]
        logger.info(f"[req-notify] admins_to_notify={len(admins)} "
                   f"empnos={[u.get('empno') for u in admins]} "
                   f"(after dormant/self filter)")
        if admins:
            def _bulk():
                conn2 = sqlite3.connect(_COMMUNITY_DB, timeout=30)
                try:
                    _now = datetime.now(timezone.utc).isoformat()
                    author_name = user_info.get("name") or empno
                    conn2.executemany(
                        "INSERT INTO notifications (user_empno, type, title, body, related_type, related_id, created_at) "
                        "VALUES (?, 'comment', ?, ?, 'request', ?, ?)",
                        [
                            (u["empno"], '새로운 요청/문의가 등록되었습니다',
                             f'{author_name}: {body.title[:50]}', request_id, _now)
                            for u in admins
                        ],
                    )
                    conn2.commit()
                    logger.info(f"[req-notify] inserted {len(admins)} rows for request_id={request_id}")
                finally:
                    conn2.close()

            await asyncio.to_thread(_bulk)
    except Exception as e:
        # 알림 실패는 요청 등록 자체에는 영향 없음
        logger.warning(f"요청 알림 발송 실패 (request_id={request_id}): {e}", exc_info=True)

    return {"success": True, "request": result}


@app.put("/community/requests/{req_id}")
async def update_request(req_id: int, body: RequestUpdate, request: Request):
    empno = await _verify_auth(request)
    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT author_empno FROM requests WHERE id = ?", (req_id,)).fetchone()
            if not row:
                raise HTTPException(404, "요청사항을 찾을 수 없습니다")
            if row["author_empno"] != empno:
                raise HTTPException(403, "작성자만 수정할 수 있습니다")
            conn.execute(
                "UPDATE requests SET title = ?, content = ?, images = ?, updated_at = ? WHERE id = ?",
                (body.title, body.content, json.dumps(body.images), now, req_id),
            )
            conn.commit()
            updated = conn.execute("SELECT * FROM requests WHERE id = ?", (req_id,)).fetchone()
            return dict(updated)
        finally:
            conn.close()

    result = await asyncio.to_thread(_do)
    return {"success": True, "request": result}


@app.delete("/community/requests/{req_id}")
async def delete_request(req_id: int, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT author_empno FROM requests WHERE id = ?", (req_id,)).fetchone()
            if not row:
                raise HTTPException(404, "요청사항을 찾을 수 없습니다")
            if row["author_empno"] != empno and role != "admin":
                raise HTTPException(403, "작성자 또는 관리자만 삭제할 수 있습니다")
            conn.execute("DELETE FROM requests WHERE id = ?", (req_id,))
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}


@app.put("/community/requests/{req_id}/status")
async def update_request_status(req_id: int, body: RequestStatusUpdate, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role != "admin":
        raise HTTPException(403, "관리자만 상태를 변경할 수 있습니다")

    valid_statuses = ("접수", "처리중", "완료")
    if body.status not in valid_statuses:
        raise HTTPException(400, f"유효하지 않은 상태: {body.status} (가능: {', '.join(valid_statuses)})")

    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT id, author_empno, title FROM requests WHERE id = ?", (req_id,)).fetchone()
            if not row:
                raise HTTPException(404, "요청사항을 찾을 수 없습니다")
            conn.execute(
                "UPDATE requests SET status = ?, updated_at = ? WHERE id = ?",
                (body.status, now, req_id),
            )
            # 알림: 작성자에게 상태 변경 통보
            req_author = row["author_empno"]
            if req_author and req_author != empno:
                label_map = {'처리중': '처리 중으로 변경되었습니다', '완료': '처리 완료되었습니다', '접수': '접수 상태로 변경되었습니다'}
                label = label_map.get(body.status, f'{body.status} 상태로 변경되었습니다')
                _insert_notification(
                    conn, req_author, 'status',
                    '요청사항 상태가 변경되었습니다',
                    f'"{row["title"]}" 이(가) {label}',
                    'request', req_id,
                )
            conn.commit()
            updated = conn.execute("SELECT * FROM requests WHERE id = ?", (req_id,)).fetchone()
            return dict(updated)
        finally:
            conn.close()

    result = await asyncio.to_thread(_do)
    return {"success": True, "request": result}


# ── 댓글 (Comments) ──────────────────────────────────────────

@app.get("/community/requests/{req_id}/comments")
async def list_comments(req_id: int, request: Request):
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute(
                "SELECT * FROM comments WHERE request_id = ? ORDER BY created_at ASC",
                (req_id,),
            ).fetchall()
            result = []
            for r in rows:
                d = dict(r)
                d["is_mine"] = 1 if d.get("author_empno") == empno else 0
                result.append(d)
            return result
        finally:
            conn.close()

    comments = await asyncio.to_thread(_do)
    return {"comments": comments}


@app.post("/community/requests/{req_id}/comments")
async def create_comment(req_id: int, body: CommentCreate, request: Request):
    empno = await _verify_auth(request)
    user_info = await asyncio.to_thread(_get_user_info_for_community, empno)
    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.execute('PRAGMA foreign_keys = ON')
        conn.row_factory = sqlite3.Row
        try:
            # 요청사항 존재 확인
            req_row = conn.execute("SELECT id, author_empno, title FROM requests WHERE id = ?", (req_id,)).fetchone()
            if not req_row:
                raise HTTPException(404, "요청사항을 찾을 수 없습니다")

            # 대댓글 검증: 2단계만 허용 (대대댓글 금지)
            parent_id = body.parent_id
            parent_author = None
            if parent_id is not None:
                parent_row = conn.execute(
                    "SELECT id, request_id, parent_id, author_empno FROM comments WHERE id = ?",
                    (parent_id,)
                ).fetchone()
                if not parent_row:
                    raise HTTPException(404, "부모 댓글을 찾을 수 없습니다")
                if parent_row["request_id"] != req_id:
                    raise HTTPException(400, "부모 댓글이 다른 요청에 속해 있습니다")
                if parent_row["parent_id"] is not None:
                    raise HTTPException(400, "대대댓글은 허용되지 않습니다 (2단계까지만 가능)")
                parent_author = parent_row["author_empno"]

            cur = conn.execute(
                "INSERT INTO comments (request_id, parent_id, content, author_empno, author_name, author_org, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (req_id, parent_id, body.content, empno, user_info["name"], user_info["org"], now),
            )

            preview = body.content[:40] + ('...' if len(body.content) > 40 else '')
            if parent_id is not None:
                # 대댓글: 부모 댓글 작성자에게 알림 (본인 제외)
                if parent_author and parent_author != empno:
                    _insert_notification(
                        conn, parent_author, 'comment',
                        '내 댓글에 답글이 달렸습니다',
                        f'"{req_row["title"]}" — {preview}',
                        'request', req_id,
                    )
            else:
                # 일반 댓글: 요청 작성자에게 알림 (본인 제외)
                req_author = req_row["author_empno"]
                if req_author and req_author != empno:
                    _insert_notification(
                        conn, req_author, 'comment',
                        '내 요청에 댓글이 달렸습니다',
                        f'"{req_row["title"]}" — {preview}',
                        'request', req_id,
                    )
            conn.commit()
            row = conn.execute("SELECT * FROM comments WHERE id = ?", (cur.lastrowid,)).fetchone()
            d = dict(row)
            d["is_mine"] = 1
            return d
        finally:
            conn.close()

    comment = await asyncio.to_thread(_do)
    return {"success": True, "comment": comment}


# ── 알림 (Notifications) ─────────────────────────────────────

def _insert_notification(conn, user_empno: str, ntype: str, title: str, body: str,
                          related_type: str = '', related_id: int = 0):
    """알림 1건 INSERT (이미 열린 connection 사용)."""
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        "INSERT INTO notifications (user_empno, type, title, body, related_type, related_id, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (user_empno, ntype, title, body, related_type, related_id, now),
    )


@app.get("/notifications")
async def get_notifications(request: Request):
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            rows = conn.execute(
                "SELECT * FROM notifications WHERE user_empno = ? "
                "ORDER BY is_read ASC, created_at DESC LIMIT 50",
                (empno,),
            ).fetchall()
            items = [dict(r) for r in rows]
            unread = sum(1 for r in items if r["is_read"] == 0)
            return {"unread_count": unread, "items": items}
        finally:
            conn.close()

    return await asyncio.to_thread(_do)


@app.post("/notifications/read-all")
async def read_all_notifications(request: Request):
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        try:
            conn.execute("UPDATE notifications SET is_read = 1 WHERE user_empno = ?", (empno,))
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}


@app.post("/notifications/{notif_id}/read")
async def read_notification(notif_id: int, request: Request):
    empno = await _verify_auth(request)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        try:
            conn.execute(
                "UPDATE notifications SET is_read = 1 WHERE id = ? AND user_empno = ?",
                (notif_id, empno),
            )
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}


@app.put("/community/comments/{comment_id}")
async def update_comment(comment_id: int, body: CommentUpdate, request: Request):
    empno = await _verify_auth(request)
    now = datetime.now(timezone.utc).isoformat()

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT author_empno FROM comments WHERE id = ?", (comment_id,)).fetchone()
            if not row:
                raise HTTPException(404, "댓글을 찾을 수 없습니다")
            if row["author_empno"] != empno:
                raise HTTPException(403, "작성자만 수정할 수 있습니다")
            conn.execute(
                "UPDATE comments SET content = ?, updated_at = ? WHERE id = ?",
                (body.content, now, comment_id),
            )
            conn.commit()
            updated = conn.execute("SELECT * FROM comments WHERE id = ?", (comment_id,)).fetchone()
            d = dict(updated)
            d["is_mine"] = 1
            return d
        finally:
            conn.close()

    comment = await asyncio.to_thread(_do)
    return {"success": True, "comment": comment}


@app.delete("/community/comments/{comment_id}")
async def delete_comment(comment_id: int, request: Request):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    def _do():
        conn = sqlite3.connect(_COMMUNITY_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute("SELECT author_empno FROM comments WHERE id = ?", (comment_id,)).fetchone()
            if not row:
                raise HTTPException(404, "댓글을 찾을 수 없습니다")
            if row["author_empno"] != empno and role != "admin":
                raise HTTPException(403, "작성자 또는 관리자만 삭제할 수 있습니다")
            conn.execute("DELETE FROM comments WHERE id = ?", (comment_id,))
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_do)
    return {"success": True}


# ============================================================
# 부적합 관리 (Inadequate Management)
# ============================================================

class InadequateUpdateReq(BaseModel):
    id: int
    status: str = ""  # 완료/미완료/대상제외
    심의차수: str = ""


@app.post("/inadequate/sync")
async def inadequate_sync(request: Request, year: int = Query(...)):
    """실적 데이터에서 부적합 국소 동기화."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    def _sync():
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT * FROM inspection_results_raw WHERE year=? AND 성능서류='부적합'",
            (year,)
        ).fetchall()

        count = 0
        for r in rows:
            검사일자_raw = r['검사일자'] or ''
            검사일자 = 검사일자_raw
            시정기한 = ''
            if 검사일자_raw:
                try:
                    dt = None
                    s = str(검사일자_raw).strip()
                    # 엑셀 시리얼 숫자 (예: 46097)
                    try:
                        serial = float(s)
                        if 40000 < serial < 60000:
                            from datetime import timedelta as _td
                            dt = datetime(1899, 12, 30) + _td(days=int(serial))
                            검사일자 = dt.strftime('%Y-%m-%d')
                    except (ValueError, TypeError):
                        pass
                    # 일반 날짜 형식
                    if dt is None:
                        for fmt in ('%Y-%m-%d %H:%M:%S', '%Y-%m-%d', '%Y/%m/%d'):
                            try:
                                dt = datetime.strptime(s.split('.')[0].strip(), fmt)
                                검사일자 = dt.strftime('%Y-%m-%d')
                                break
                            except Exception:
                                pass
                    if dt:
                        month = dt.month + 6
                        year_add = (month - 1) // 12
                        month = ((month - 1) % 12) + 1
                        시정기한 = dt.replace(year=dt.year + year_add, month=month).strftime('%Y-%m-%d')
                except Exception:
                    pass

            conn.execute('''INSERT OR IGNORE INTO inadequate_management
                (year, 허가번호, 통합시설코드, 호출명칭, 주소, skt본부, region, ons팀,
                 검사일자, 시정기한, 불합격내용, 불합격상세)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)''',
                (year, r['허가번호'], r['통합시설코드'], r['호출명칭'], r['주소'],
                 r['skt본부'], r['region'], r['ons팀'],
                 검사일자, 시정기한, r['불합격내용'] or '', r['불합격상세'] or ''))
            count += 1
        conn.commit()
        total = conn.execute("SELECT COUNT(*) FROM inadequate_management WHERE year=?", (year,)).fetchone()[0]
        conn.close()
        return {"synced": count, "total": total}

    return await asyncio.to_thread(_sync)


@app.get("/inadequate/list")
async def inadequate_list(
    request: Request,
    year: int = Query(...),
    region: str = Query(""),
    team: str = Query(""),
    status: str = Query(""),
    search_field: str = Query(""),   # 'license' | 'callname' | 'address'
    search_values: str = Query(""),  # 콤마 구분 복수값
    page: int = Query(1),
    pageSize: int = Query(100),
):
    """부적합 관리 목록 조회."""
    await _verify_auth(request)

    def _list():
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        conn.row_factory = sqlite3.Row
        where = "year=?"
        params: list = [year]
        if region:
            where += " AND region=?"
            params.append(region)
        if team:
            where += " AND ons팀=?"
            params.append(team)
        if status:
            where += " AND status=?"
            params.append(status)
        # 검색 조건
        if search_field and search_values:
            tokens = [t.strip() for t in search_values.split(',') if t.strip()]
            if tokens:
                if search_field == 'license':
                    # 하이픈 제거 후 비교
                    placeholders = ','.join('?' * len(tokens))
                    normalized = [t.replace('-', '') for t in tokens]
                    where += f" AND REPLACE(허가번호, '-', '') IN ({placeholders})"
                    params.extend(normalized)
                elif search_field == 'callname':
                    clauses = ' OR '.join(['호출명칭 LIKE ?' for _ in tokens])
                    where += f" AND ({clauses})"
                    params.extend([f'%{t}%' for t in tokens])
                elif search_field == 'address':
                    clauses = ' OR '.join(['주소 LIKE ?' for _ in tokens])
                    where += f" AND ({clauses})"
                    params.extend([f'%{t}%' for t in tokens])
        total = conn.execute(
            f"SELECT COUNT(*) FROM inadequate_management WHERE {where}", params
        ).fetchone()[0]
        offset = (page - 1) * pageSize
        rows = conn.execute(
            f"SELECT * FROM inadequate_management WHERE {where} ORDER BY 검사일자 DESC LIMIT ? OFFSET ?",
            params + [pageSize, offset],
        ).fetchall()
        conn.close()
        return {"items": [dict(r) for r in rows], "total": total}

    return await asyncio.to_thread(_list)


@app.put("/inadequate/update")
async def inadequate_update(request: Request, req: InadequateUpdateReq):
    """부적합 상태/심의차수 업데이트 (관리자/매니저)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")
    now = datetime.now(timezone.utc).isoformat()

    def _update():
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        sets = []
        params = []
        if req.status:
            sets.append("status=?")
            params.append(req.status)
        if req.심의차수 is not None:
            sets.append("심의차수=?")
            params.append(req.심의차수)
        sets.append("updated_by=?")
        params.append(empno)
        sets.append("updated_at=?")
        params.append(now)
        params.append(req.id)
        conn.execute(f"UPDATE inadequate_management SET {','.join(sets)} WHERE id=?", params)
        conn.commit()
        conn.close()

    await asyncio.to_thread(_update)
    return {"success": True}


@app.get("/inadequate/stats")
async def inadequate_stats(
    request: Request,
    year: int = Query(...),
    region: str = Query(""),
    team: str = Query(""),
):
    """부적합 관리 통계 (필터 적용)."""
    await _verify_auth(request)

    def _stats():
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        where = "year=?"
        params: list = [year]
        if region:
            where += " AND region=?"
            params.append(region)
        if team:
            where += " AND ons팀=?"
            params.append(team)
        total = conn.execute(f"SELECT COUNT(*) FROM inadequate_management WHERE {where}", params).fetchone()[0]
        done = conn.execute(f"SELECT COUNT(*) FROM inadequate_management WHERE {where} AND status='완료'", params).fetchone()[0]
        pending = conn.execute(f"SELECT COUNT(*) FROM inadequate_management WHERE {where} AND status='미완료'", params).fetchone()[0]
        excluded = conn.execute(f"SELECT COUNT(*) FROM inadequate_management WHERE {where} AND status='대상제외'", params).fetchone()[0]
        conn.close()
        return {"total": total, "완료": done, "미완료": pending, "대상제외": excluded}

    return await asyncio.to_thread(_stats)


@app.get("/inadequate/export-xlsx")
async def inadequate_export_xlsx(
    request: Request,
    year: int = Query(...),
    region: str = Query(""),
    team: str = Query(""),
    status: str = Query(""),
):
    """부적합 관리 Excel 내보내기 (결과장 동일 양식)."""
    await _verify_auth(request)
    if not HAS_OPENPYXL:
        raise HTTPException(503, "openpyxl 미설치")

    def _build():
        import openpyxl
        from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
        from openpyxl.utils import get_column_letter

        conn = sqlite3.connect(_INSP_DB, timeout=60)
        conn.row_factory = sqlite3.Row
        where = "year=?"
        params: list = [year]
        if region:
            where += " AND region=?"
            params.append(region)
        if team:
            where += " AND ons팀=?"
            params.append(team)
        if status:
            where += " AND status=?"
            params.append(status)
        rows = conn.execute(
            f"SELECT * FROM inadequate_management WHERE {where} ORDER BY 검사일자 DESC",
            params,
        ).fetchall()
        conn.close()

        if not rows:
            raise ValueError("조회된 데이터가 없습니다")

        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = "부적합관리"

        _thin_side = Side(style='thin')
        _thin_border = Border(left=_thin_side, right=_thin_side,
                              top=_thin_side, bottom=_thin_side)
        _hdr_fill = PatternFill('solid', fgColor='FFBFBFBF')
        _hdr_font = Font(name='맑은 고딕', size=10, bold=True)
        _data_font = Font(name='맑은 고딕', size=10)
        _center = Alignment(horizontal='center', vertical='center', wrap_text=False)
        _left = Alignment(horizontal='left', vertical='center', wrap_text=False)
        _left_wrap = Alignment(horizontal='left', vertical='center', wrap_text=True)
        _hdr_wrap = Alignment(horizontal='center', vertical='center', wrap_text=True)
        _LINE_H = 16.5

        headers = ['본부', '팀', '허가번호', '호출명칭', '주소', '검사일자',
                   '시정기한', '불합격내용', '불합격상세', '상태', '심의차수', '최종수정자', '최종수정일시']
        db_cols = ['region', 'ons팀', '허가번호', '호출명칭', '주소', '검사일자',
                   '시정기한', '불합격내용', '불합격상세', 'status', '심의차수', 'updated_by', 'updated_at']

        # 왼쪽 정렬: 주소(5), 불합격상세(9)
        _left_cols = {5, 9}
        _left_wrap_cols = {5, 9}

        ws.row_dimensions[1].height = _LINE_H
        for ci, h in enumerate(headers, 1):
            cell = ws.cell(row=1, column=ci, value=h)
            cell.font = _hdr_font
            cell.fill = _hdr_fill
            cell.border = _thin_border
            cell.alignment = _hdr_wrap

        # 텍스트 표시 너비 계산 (한글 2.2, 영문 1.1)
        def _col_width(s):
            w = 0.0
            for ch in str(s):
                w += 2.2 if ord(ch) > 127 else 1.1
            return w

        # 데이터 먼저 기록 (행 높이는 열 너비 확정 후 계산)
        all_row_values = []
        for ri, row in enumerate(rows, 2):
            d = dict(row)
            values = [d.get(col) or '' for col in db_cols]
            all_row_values.append(values)
            for ci, v in enumerate(values, 1):
                cell = ws.cell(row=ri, column=ci, value=v)
                cell.font = _data_font
                cell.border = _thin_border
                cell.alignment = _left_wrap if ci in _left_wrap_cols else (_left if ci in _left_cols else _center)

        # 열 너비 확정 (헤더 포함)
        col_widths = {}
        for ci in range(1, len(headers) + 1):
            best = _col_width(headers[ci - 1])
            for ri2 in range(2, len(rows) + 2):
                val = ws.cell(row=ri2, column=ci).value
                if val is not None:
                    for line in str(val).split('\n'):
                        best = max(best, _col_width(line))
            max_w = 40 if ci in _left_wrap_cols else 60
            final_w = max(min(best + 1, max_w), 10)
            col_widths[ci] = final_w
            ws.column_dimensions[get_column_letter(ci)].width = final_w

        # 행 높이: wrap 컬럼은 셀 너비 기준 줄 수 계산, 명시적 \n도 반영
        for ri, values in enumerate(all_row_values, 2):
            max_lines = 1
            for ci, v in enumerate(values, 1):
                if not isinstance(v, str) or not v:
                    continue
                col_w = col_widths.get(ci, 10)
                # 각 \n 세그먼트별 줄 수 합산
                cell_lines = 0
                for segment in v.split('\n'):
                    if ci in _left_wrap_cols and col_w > 0:
                        seg_w = _col_width(segment)
                        cell_lines += max(1, int(seg_w / col_w) + (1 if seg_w % col_w > 0 else 0))
                    else:
                        cell_lines += 1
                max_lines = max(max_lines, cell_lines)
            ws.row_dimensions[ri].height = _LINE_H * max_lines

        # 틀 고정: 1행(헤더) + A~B열
        ws.freeze_panes = 'C2'

        buf = io.BytesIO()
        wb.save(buf)
        wb.close()
        buf.seek(0)
        return buf.getvalue()

    try:
        data = await asyncio.to_thread(_build)
    except ValueError as e:
        raise HTTPException(404, str(e))

    suffix_parts = [p for p in [region, team, str(year)] if p]
    filename = f"부적합관리_{'_'.join(suffix_parts)}.xlsx"
    from urllib.parse import quote as _q
    return Response(
        content=data,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{_q(filename)}"}
    )


# ============================================================
# Menu Usage Logging
# ============================================================

@app.post("/admin/menu-log")
async def admin_menu_log(request: Request):
    """메뉴 접속 로그 기록."""
    empno = await _verify_auth(request)
    body = await request.json()
    menu_name = body.get("menu", "")
    if not menu_name:
        return {"ok": True}

    # Get user name
    user_info = await asyncio.to_thread(_get_user_info_for_community, empno)
    now = datetime.now(timezone.utc).isoformat()

    def _log():
        conn = sqlite3.connect(_INSP_DB, timeout=30)
        conn.execute(
            "INSERT INTO menu_usage_log (user_id, user_name, menu_name, accessed_at) VALUES (?,?,?,?)",
            (empno, user_info.get("name", empno), menu_name, now),
        )
        conn.commit()
        conn.close()

    await asyncio.to_thread(_log)
    return {"ok": True}


@app.get("/admin/menu-stats")
async def admin_menu_stats(request: Request, days: int = Query(30)):
    """메뉴 사용 통계 (관리자용)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role != "admin":
        raise HTTPException(403, "관리자만 조회 가능")

    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()

    def _stats():
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        conn.row_factory = sqlite3.Row
        # 메뉴별 접속 횟수
        menu_counts = conn.execute(
            "SELECT menu_name, COUNT(*) as cnt FROM menu_usage_log "
            "WHERE accessed_at >= ? GROUP BY menu_name ORDER BY cnt DESC",
            (cutoff,),
        ).fetchall()
        # 사용자별 접속 횟수
        user_counts = conn.execute(
            "SELECT user_id, user_name, COUNT(*) as cnt FROM menu_usage_log "
            "WHERE accessed_at >= ? GROUP BY user_id ORDER BY cnt DESC LIMIT 20",
            (cutoff,),
        ).fetchall()
        # 일별 접속 추이
        daily = conn.execute(
            "SELECT DATE(accessed_at) as day, COUNT(*) as cnt FROM menu_usage_log "
            "WHERE accessed_at >= ? GROUP BY DATE(accessed_at) ORDER BY day",
            (cutoff,),
        ).fetchall()
        conn.close()
        return {
            "menu_counts": [dict(r) for r in menu_counts],
            "user_counts": [dict(r) for r in user_counts],
            "daily": [dict(r) for r in daily],
        }

    return await asyncio.to_thread(_stats)


# ============================================================
# Route Basket (경로 담기)
# ============================================================

@app.get("/route-basket")
async def get_route_baskets(request: Request):
    """사용자 경로 담기 목록 조회."""
    from decimal import Decimal
    empno = await _verify_auth(request)
    dynamodb = get_dynamodb_resource()
    table = dynamodb.Table(DYNAMODB_TABLES["route_baskets"])
    resp = await asyncio.to_thread(lambda: table.query(
        KeyConditionExpression=Key("user_id").eq(empno),
        ScanIndexForward=False,
    ))
    # DynamoDB Decimal → float 변환
    def _fix(item):
        stations = item.get("stations", [])
        return {**item, "stations": [
            {**s, "lat": float(s["lat"]), "lng": float(s["lng"])} for s in stations
        ]}
    return {"entries": [_fix(i) for i in resp.get("Items", [])]}


@app.post("/route-basket")
async def save_route_basket(request: Request):
    """경로 담기 저장."""
    from decimal import Decimal
    empno = await _verify_auth(request)
    body = await request.json()
    entry_id = str(uuid.uuid4())
    now = datetime.utcnow().isoformat()
    # DynamoDB는 float 미지원 → Decimal 변환
    stations_raw = body.get("stations", [])
    stations = [
        {
            "id": s.get("id", ""),
            "name": s.get("name", ""),
            "lat": Decimal(str(s.get("lat", 0))),
            "lng": Decimal(str(s.get("lng", 0))),
        }
        for s in stations_raw
    ]
    item = {
        "user_id": empno,
        "entry_id": entry_id,
        "title": body.get("title", ""),
        "week_label": body.get("week_label", ""),
        "jo_label": body.get("jo_label", ""),
        "stations": stations,
        "created_at": now,
    }
    dynamodb = get_dynamodb_resource()
    table = dynamodb.Table(DYNAMODB_TABLES["route_baskets"])
    await asyncio.to_thread(lambda: table.put_item(Item=item))
    # 응답은 float으로 직렬화 (Decimal은 JSON 직렬화 불가)
    item_resp = {**item, "stations": [
        {**s, "lat": float(s["lat"]), "lng": float(s["lng"])} for s in stations
    ]}
    return {"entry": item_resp}


@app.patch("/route-basket/{entry_id}")
async def update_route_basket(request: Request, entry_id: str):
    """경로 담기 국소 순서 수정."""
    from decimal import Decimal
    empno = await _verify_auth(request)
    body = await request.json()
    stations_raw = body.get("stations", [])
    stations = [
        {
            "id": s.get("id", ""),
            "name": s.get("name", ""),
            "lat": Decimal(str(s.get("lat", 0))),
            "lng": Decimal(str(s.get("lng", 0))),
        }
        for s in stations_raw
    ]
    dynamodb = get_dynamodb_resource()
    table = dynamodb.Table(DYNAMODB_TABLES["route_baskets"])
    await asyncio.to_thread(lambda: table.update_item(
        Key={"user_id": empno, "entry_id": entry_id},
        UpdateExpression="SET stations = :s",
        ExpressionAttributeValues={":s": stations},
    ))
    return {"success": True}


@app.delete("/route-basket/{entry_id}")
async def delete_route_basket(request: Request, entry_id: str):
    """경로 담기 삭제."""
    empno = await _verify_auth(request)
    dynamodb = get_dynamodb_resource()
    table = dynamodb.Table(DYNAMODB_TABLES["route_baskets"])
    await asyncio.to_thread(lambda: table.delete_item(
        Key={"user_id": empno, "entry_id": entry_id}
    ))
    return {"success": True}


# ============================================================
# Run Server
# ============================================================

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        workers=3,
        reload=False,
    )
