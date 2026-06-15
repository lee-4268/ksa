"""
cert - 설치확인서 API 엔드포인트

담당 도메인: 설치확인서 조회/생성/일괄 생성, 방위각 조회, ERP-DS 비교
주요 의존성: core.auth, core.config, core.s3, core.cert_cache
엔드포인트:
    POST /cert/lookup
    POST /cert/generate
    POST /cert/batch/lookup
    POST /cert/batch/upload-photos
    POST /cert/batch/generate
    GET  /cert/batch/download/{job_id}
    POST /azimuths/batch
    POST /erp-ds/compare
"""

import asyncio
import base64
import json
import logging
import os
import re
import sqlite3
import time as _time_mod
import tempfile as _tempfile
import uuid
import zipfile
from datetime import datetime
from typing import Dict, Optional
from urllib.parse import quote

from fastapi import APIRouter, File, HTTPException, Request, UploadFile
from fastapi.responses import StreamingResponse

from core.auth import _verify_auth
from core.config import (
    S3_BUCKET_NAME, _INSP_DB, _DS_DETAIL_DB, MAX_DS_ZIP_SIZE,
)
from core.cert_cache import (
    _cert_cache_load, _cert_cache_force_rebuild,
    _cert_lookup_cached, _cert_batch_lookup_cached,
)
import core.cert_cache as _cert_cache_mod
# NOTE: _cert_cache_db_path는 모듈 레벨 가변 상태이므로 from-import하면 빈 초기값이
# 박혀버림 (Python import-by-name 동작). 항상 _cert_cache_mod._cert_cache_db_path로
# 참조해서 최신 값을 가져와야 함. inspection.py, ds.py와 동일한 패턴.
from core.s3 import get_s3_client
from core.utils import _check_memory

router = APIRouter(tags=["cert"])
logger = logging.getLogger(__name__)

# ── PDF/HWPX 생성 모듈 (optional import) ──────────────────────
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
    return _cert_lookup_cached(query)


def _cert_batch_lookup(zpwino_list: list) -> dict:
    return _cert_batch_lookup_cached(zpwino_list)


def _decode_base64_image(data_url):
    if not data_url:
        return None
    try:
        if "," in data_url:
            data_url = data_url.split(",", 1)[1]
        return base64.b64decode(data_url)
    except Exception:
        return None


def _parse_photo_zip_to_s3(zip_path: str, job_id: str) -> dict:
    """ZIP에서 이미지 추출 → S3 cert-temp/{job_id}/ 에 개별 저장."""
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

    for zpwino in summary:
        entries = sorted(summary[zpwino]["photo_entries"], key=lambda x: x[0])
        summary[zpwino]["photo_keys"] = [k for _, k in entries[:6]]
        del summary[zpwino]["photo_entries"]

    return summary


# ── ERP-DS 비교 헬퍼 ──────────────────────────────────────────

_TOWER_TYPE_NORMALIZE = {
    "철탑(지면)": "철탑(지면)",
    "강관주": "강관주",
    "통신주(cp주)": "통신주",
    "통신주": "통신주",
    "원폴(건물)": "원폴(건물)",
    "옥내,터널,지하등": "옥내,터널,지하, 차량 또는 임시",
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
    "옥내,터널,지하, 차량 또는 임시": "옥내,터널,지하, 차량 또는 임시",
    "옥내외 혼합형": "옥내외 혼합형",
    "간이폴 및 비기준 설치대": "간이폴 및 비기준 설치대",
    "복합형(원폴,분산프레임 등)": "복합형(원폴,분산프레임 등)",
}

_설치형태_CODE_TO_NAME: dict = {
    '1': '철탑(지면)', '2': '강관주', '3': '통신주', '4': '원폴(건물)',
    '6': '옥내,터널,지하, 차량 또는 임시', '8': '쌍통신주', '9': '기설물',
    '11': '옥내외 혼합형', '12': '간이폴, 분산폴 및 비기준 설치대',
    '13': '한전주(KT통신주)', '14': '철탑(건물)', '15': '프레임',
    '21': '복합형(원폴,분산프레임 등)', '25': '모노폴',
}

_TOWER_TYPE_GROUPS = [
    {
        "간이폴 및 비기준 설치대",
        "복합형(원폴,분산프레임 등)",
        "간이폴, 분산폴 및 비기준 설치대",
    },
]

_SKT_BAND_MAP = {
    "B5": "800M",
    "B3": "1.8G",
    "B1": "2.1G",
    "B7": "2.6G",
}


def _normalize_설치형태(val: str) -> str:
    v = val.strip()
    return _설치형태_CODE_TO_NAME.get(v, v)


def _normalize_tower(val: str) -> str:
    if not val:
        return ""
    v = val.strip().lower()
    return _TOWER_TYPE_NORMALIZE.get(v, v)


def _tower_group(val: str):
    if not val:
        return None
    for g in _TOWER_TYPE_GROUPS:
        if val in g:
            return g
    return None


def _parse_serial_strings(s: str) -> list:
    if not s:
        return []
    return [x.strip().lower() for x in s.split(",") if x.strip()]


def _compare_values(erp_val: str, ds_val: str, normalize_fn=None) -> str:
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
    if normalize_fn is _normalize_tower:
        for ep in erp_parts:
            g = _tower_group(ep)
            if g and any(dp in g for dp in ds_parts):
                return "부분일치"
    return "불일치"


def _extract_service_band(zpannu1: str, eqp_type: str, zpcname: str) -> tuple:
    annu = (zpannu1 or "").strip().upper()
    eqp = (eqp_type or "").strip()
    zn = (zpcname or "").strip()

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

    band = None
    if service == "5G":
        if "28G" in eqp.upper() or "28G" in zn.upper():
            band = "28G"
        else:
            band = "3.5G"
    elif service == "LTE":
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
            import re as _re
            m = _re.search(r"[._]?B([1357])[._]", zn)
            if m:
                band = _SKT_BAND_MAP.get(f"B{m.group(1)}")
            else:
                for code, b in _SKT_BAND_MAP.items():
                    if code in zn:
                        band = b
                        break
        if band is None:
            band = "멀티"
    return service, band


def _parse_swing_list(s: str) -> list:
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


def _resolve_inputs_to_zpwino(raw_list: list) -> tuple:
    """입력값을 허가번호로 변환 (배치 최적화)."""
    _cert_cache_load()
    _db = _cert_cache_mod._cert_cache_db_path

    zpwino_list = []
    resolve_map = {}
    text_inputs = []

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

    BATCH = 900
    try:
        conn = sqlite3.connect(_db, timeout=30)
        conn.row_factory = sqlite3.Row
        remaining = list(text_inputs)

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

        for raw in remaining:
            found_zpwino = None
            found_type = None
            cur = conn.execute("SELECT zpwino FROM cert WHERE zpwina LIKE ? LIMIT 1", (f"%{raw}%",))
            row = cur.fetchone()
            if row and row["zpwino"]:
                found_zpwino = row["zpwino"]
                found_type = "호출명칭(부분)"
            else:
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
    """ERP vs DS 비교 동기 처리 — ds_detail.db 활용."""
    erp_data = _cert_batch_lookup_cached(zpwino_list)

    erp_multi = {}
    _cert_db = _cert_cache_mod._cert_cache_db_path or ""
    if _cert_db and os.path.exists(_cert_db):
        try:
            _cc = sqlite3.connect(_cert_db, timeout=15)
            _cc.row_factory = sqlite3.Row
            _erp_norms = list({raw.replace('-', '') for raw in zpwino_list})
            _B = 900
            for i in range(0, len(_erp_norms), _B):
                _batch = _erp_norms[i:i+_B]
                _ph = ','.join('?' * len(_batch))
                for _r in _cc.execute(
                    f"SELECT REPLACE(TRIM(zpwino),'-','') AS wn, zpcode, zpkcode, eqp_ser_no, zpirty3 "
                    f"FROM cert WHERE REPLACE(TRIM(zpwino),'-','') IN ({_ph})",
                    _batch
                ):
                    z = _r['wn'] or ''
                    if z not in erp_multi:
                        erp_multi[z] = {"통시들": [], "일련번호들": [], "공대": _r['zpkcode'] or '', "zpirty3": _r['zpirty3'] or ''}
                    tc = str(_r['zpcode'] or '').strip()
                    sn = str(_r['eqp_ser_no'] or '').strip()
                    if tc and tc not in erp_multi[z]["통시들"]:
                        erp_multi[z]["통시들"].append(tc)
                    if sn and sn not in erp_multi[z]["일련번호들"]:
                        erp_multi[z]["일련번호들"].append(sn)
            _cc.close()
        except Exception as _ce:
            logger.warning(f"erp_multi 조회 실패: {_ce}")

    ds_device = {}
    ds_form_no = {}
    ds_antenna = {}
    ds_antenna_ki = {}
    warnings = []
    BATCH = 900

    if os.path.exists(_DS_DETAIL_DB):
        try:
            conn = sqlite3.connect(_DS_DETAIL_DB, timeout=30)
            conn.row_factory = sqlite3.Row
            all_nos = list({n for raw in zpwino_list for n in (raw, raw.replace('-', ''))})

            for i in range(0, len(all_nos), BATCH):
                batch = all_nos[i:i + BATCH]
                ph = ','.join('?' * len(batch))
                for row in conn.execute(f"SELECT 허가번호, 기기일련번호, 형식검정번호 FROM ds_장치 WHERE 허가번호 IN ({ph})", batch):
                    z = row['허가번호'].replace('-', '')
                    sn = str(row['기기일련번호'] or '').strip()
                    fn = str(row['형식검정번호'] or '').strip()
                    if z not in ds_device:
                        ds_device[z] = []
                    if sn and sn not in ds_device[z]:
                        ds_device[z].append(sn)
                    if z not in ds_form_no:
                        ds_form_no[z] = []
                    if fn and fn not in ds_form_no[z]:
                        ds_form_no[z].append(fn)

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

            ds_prac1 = {z: '운용' for z in ds_device}
            conn.close()
        except Exception as e:
            logger.warning(f"ds_detail.db 비교 조회 실패: {e}")
            warnings.append(f"DS 데이터 조회 실패: {e}")
    else:
        warnings.append("DS 데이터가 아직 빌드되지 않았습니다. DS 파일을 업로드해주세요.")

    insp_info = {}
    try:
        conn_insp = sqlite3.connect(_INSP_DB, timeout=30)
        conn_insp.row_factory = sqlite3.Row
        all_nos = list({n for raw in zpwino_list for n in (raw, raw.replace('-', ''))})
        for tbl in ('inspection_targets', 'inspection_targets_staging'):
            try:
                tbl_cols = {r['name'] for r in conn_insp.execute(f"PRAGMA table_info({tbl})").fetchall()}
                if not tbl_cols:
                    continue
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

    erp_prac1_map = {
        z.replace('-', ''): (erp_data.get(z, {}).get('zpprac1', '') or '')
        for z in zpwino_list
    }

    items = []
    summary = {
        "tower_match": 0, "tower_mismatch": 0, "tower_check": 0,
        "tower_partial": 0, "tower_ds_missing": 0,
        "serial_match": 0, "serial_mismatch": 0, "serial_check": 0,
        "serial_partial": 0, "serial_ds_missing": 0,
    }

    for z in zpwino_list:
        erp = erp_data.get(z)
        z_clean = z.replace('-', '')
        multi = erp_multi.get(z_clean, {})

        erp_zpirty3 = (erp.get("zpirty3", "") if erp else "") or multi.get("zpirty3", "")
        erp_serials = multi.get("일련번호들", [])
        if not erp_serials and erp:
            sn = erp.get("eqp_ser_no", "")
            if sn:
                erp_serials = [sn]
        erp_serial = ", ".join(erp_serials)

        ds_tower = ds_antenna.get(z_clean, "") or ds_antenna.get(z, "")
        ds_serials = ds_device.get(z_clean, []) or ds_device.get(z, [])
        ds_serial_str = ", ".join(ds_serials) if ds_serials else ""
        insp = insp_info.get(z_clean) or insp_info.get(z, {})

        tower_result = _compare_values(erp_zpirty3, ds_tower, _normalize_tower)
        serial_result = _compare_values(erp_serial, ds_serial_str)

        summary_key_map = {
            "일치": "match", "부분일치": "partial", "불일치": "mismatch",
            "DS누락": "ds_missing", "확인필요": "check",
        }
        summary[f"tower_{summary_key_map.get(tower_result, 'check')}"] += 1
        summary[f"serial_{summary_key_map.get(serial_result, 'check')}"] += 1

        best_address = (insp.get("도로명주소") or insp.get("설치장소")
                        or (erp.get("zpwiadr", "") if erp else ""))

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
            "ds_form_no": ", ".join(ds_form_no.get(z_clean, []) or ds_form_no.get(z, [])),
            "tower_match": tower_result,
            "serial_match": serial_result,
            "통시": insp.get("통시", "") or ", ".join(multi.get("통시들", [])) or (erp.get("zpcode", "") if erp else ""),
            "공대": insp.get("공대", "") or multi.get("공대", "") or (erp.get("zpkcode", "") if erp else ""),
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


# ── 엔드포인트 ────────────────────────────────────────────────

@router.post("/cert/lookup")
async def cert_lookup(request: Request):
    """허가번호/호출명칭으로 설치확인서용 DB 조회."""
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


@router.post("/cert/generate")
async def cert_generate(request: Request):
    """개별 설치확인서 생성 (PDF 또는 HWPX)."""
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
        raise HTTPException(status_code=500, detail="설치확인서 생성 중 오류가 발생했습니다")


@router.post("/cert/batch/lookup")
async def cert_batch_lookup(request: Request):
    """허가번호 목록 일괄 조회 (최대 500건)."""
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


@router.post("/cert/batch/upload-photos")
async def cert_batch_upload_photos(request: Request, file: UploadFile = File(...)):
    """사진 ZIP 업로드 → 허가번호별 자동 매칭 → S3 temp 저장."""
    await _verify_auth(request)

    if not file.filename or not file.filename.lower().endswith(".zip"):
        raise HTTPException(status_code=400, detail="ZIP 파일만 가능합니다.")

    tmp_path = None
    try:
        total_size = 0
        with _tempfile.NamedTemporaryFile(delete=False, suffix=".zip") as tmp:
            tmp_path = tmp.name
            while True:
                chunk = await file.read(8 * 1024 * 1024)
                if not chunk:
                    break
                total_size += len(chunk)
                if total_size > MAX_DS_ZIP_SIZE:
                    raise HTTPException(status_code=413,
                        detail=f"파일 크기 초과 ({MAX_DS_ZIP_SIZE // (1024*1024)}MB)")
                tmp.write(chunk)

        job_id = str(uuid.uuid4())
        summary = await asyncio.to_thread(_parse_photo_zip_to_s3, tmp_path, job_id)

        _cert_sessions[job_id] = {
            "type": "photos", "ts": _time_mod.time(),
            "s3_prefix": f"cert-temp/{job_id}/",
            "summary": summary,
        }

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
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"사진 ZIP 처리 실패: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")
    finally:
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


@router.post("/cert/batch/generate")
async def cert_batch_generate(request: Request):
    """일괄 설치확인서 생성 (SSE 스트리밍, PDF만)."""
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

            import shutil
            shutil.rmtree(tmp_dir, ignore_errors=True)

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


@router.get("/cert/batch/download/{job_id}")
async def cert_batch_download(job_id: str, request: Request):
    """일괄 생성 결과 ZIP 다운로드 (S3 presigned URL)."""
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


@router.post("/azimuths/batch")
async def azimuths_batch(request: Request):
    """현장 수검 Map 부채꼴 표시용 batch 안테나 방위각 조회."""
    await _verify_auth(request)
    body = await request.json()
    raw_list = body.get("zpwino_list", [])
    zpwino_list = list({str(z).strip() for z in raw_list if str(z).strip()})
    if not zpwino_list:
        return {"items": {}}
    if len(zpwino_list) > 1000:
        raise HTTPException(status_code=400, detail="최대 1000건까지 조회 가능합니다.")

    _cert_cache_load()
    _db = _cert_cache_mod._cert_cache_db_path
    if not _db or not os.path.exists(_db):
        logger.warning(f"azimuths/batch: cert cache DB 미존재 (path={_db!r})")
        return {"items": {}}
    result = {z: {} for z in zpwino_list}

    try:
        conn = sqlite3.connect(_db, timeout=30)
        conn.row_factory = sqlite3.Row
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
        raise HTTPException(status_code=500, detail="방위각 조회 실패")

    out = {}
    for z, by_key in result.items():
        if not by_key:
            continue
        out[z] = [
            {"service": s, "band": b, "swings": sorted(sw)}
            for (s, b), sw in sorted(by_key.items(), key=lambda x: (x[0][0], x[0][1]))
        ]
    return {"items": out}


@router.post("/erp-ds/compare")
async def erp_ds_compare(request: Request):
    """ERP vs DS 전산자료 비교 (철탑형태 + 일련번호)."""
    await _verify_auth(request)
    body = await request.json()
    raw_list = body.get("zpwino_list", [])
    division_id = body.get("division_id", "")
    division_code = body.get("division_code", "")
    import_date = body.get("import_date", "")

    raw_list = list(dict.fromkeys([str(z).strip() for z in raw_list if str(z).strip()]))
    if not raw_list:
        raise HTTPException(status_code=400, detail="검색어를 입력해주세요.")
    if len(raw_list) > 500:
        raise HTTPException(status_code=400, detail="한 번에 최대 500건까지 비교 가능합니다.")
    if not division_id or not import_date:
        raise HTTPException(status_code=400, detail="본부 및 DS 업로드 정보가 필요합니다.")

    try:
        zpwino_list, resolve_map = await asyncio.to_thread(_resolve_inputs_to_zpwino, raw_list)
        result = await asyncio.to_thread(
            _erp_ds_compare_sync, zpwino_list, division_id, division_code, import_date
        )
        result["resolve_map"] = resolve_map
        return result
    except Exception as e:
        logger.error(f"ERP-DS 비교 실패: {e}")
        raise HTTPException(status_code=500, detail="비교 처리 중 오류")
