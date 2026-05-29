"""
inspection - 수검대상 관리, 워크플로우, 일정, 결과 엔드포인트

담당 도메인: inspection_targets, inspection_schedules, inspection_results, workflow state machine
주요 의존성: core.inspection_db, core.cert_cache, core.config, core.auth, core.s3, core.db
엔드포인트: /inspection/*, /change-request/* (inspection 관련)
"""

import asyncio
import gc
import io
import json
import logging
import os
import re
import sqlite3
import struct
import sys
import tempfile as _tempfile
import time as _time_mod
import uuid
import zipfile
from array import array
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone, timedelta
from typing import Dict, List, Optional

from fastapi import APIRouter, File, Form, HTTPException, Query, Request, Response, UploadFile
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from core.auth import (
    _verify_auth, _get_user_role_sync, _get_user_info_for_community,
    _record_audit_log_sync, _caller_allowed_access_list, _check_division_access,
    _list_all_users_sync, _dev_users,
)
from core.config import (
    _INSP_DB, _DS_DETAIL_DB, _COMMUNITY_DB,
    S3_BUCKET_NAME, INSPECTION_S3_PREFIX,
    KAKAO_REST_KEY, VWORLD_API_KEY, NAVER_CLIENT_ID, NAVER_CLIENT_SECRET,
    DYNAMODB_TABLES, MAX_PHOTO_SIZE,
    _ACCESS_TO_DIVISION,
)
from core.inspection_db import _init_inspection_db, _insp_job_write_sync, _insp_job_read_sync
import core.cert_cache as _cert_cache_mod
from core.cert_cache import _cert_cache_load
from core.s3 import get_s3_client
from core.db import get_dynamodb_resource

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

try:
    import openpyxl
    HAS_OPENPYXL = True
except ImportError:
    HAS_OPENPYXL = False

router = APIRouter(tags=["inspection"])
logger = logging.getLogger(__name__)

_inspection_jobs: Dict[str, dict] = {}
MEMORY_THRESHOLD_PCT = 80
DYNAMODB_INSP_SCHEDULES = os.environ.get("DYNAMODB_INSPECTION_SCHEDULES", "kca-inspection-schedules")
DYNAMODB_INSP_RESULTS = os.environ.get("DYNAMODB_INSPECTION_RESULTS", "kca-inspection-results")


# ── 메모리 유틸 ─────────────────────────────────────────────────

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
        pass


# ── xlsx 경량 파서 헬퍼 ─────────────────────────────────────────

def _col_to_idx(col_letter: str) -> int:
    """Excel 컬럼 레터 → 0-based 인덱스. 'A'→0, 'B'→1, 'Z'→25, 'AA'→26."""
    r = 0
    for c in col_letter:
        r = r * 26 + (ord(c) - 64)
    return r - 1


def _resolve_xlsx_sheet_path(zf, sheet_name: str) -> Optional[str]:
    """xlsx ZIP 내에서 시트이름 → 워크시트 XML 파일경로 매핑."""
    import xml.etree.ElementTree as ET
    try:
        wb_xml = zf.read("xl/workbook.xml")
        wb_root = ET.fromstring(wb_xml)
        r_id = None
        for el in wb_root.iter():
            tag = el.tag.rsplit("}", 1)[-1]
            if tag == "sheet" and el.get("name") == sheet_name:
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
    """xlsx → (0-based_row_num, [str, ...]) 스트리밍 제너레이터."""
    import xml.etree.ElementTree as ET
    import struct as _struct
    import mmap as _mmap_mod

    _owns_ss = ss_cache_path is None
    ss_tmp_path = ss_cache_path
    ss_mmap_obj = None
    ss_fh = None

    try:
        with zipfile.ZipFile(xlsx_path, "r") as zf:
            if ss_cache_path and ss_offsets_bytes:
                ss_offsets = array("Q")
                ss_offsets.frombytes(ss_offsets_bytes)
            else:
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
                                ss_tmp.write(_struct.pack("<I", len(encoded)))
                                ss_tmp.write(encoded)
                                elem.clear()
                    ss_tmp.close()

            if ss_tmp_path:
                file_size = os.path.getsize(ss_tmp_path)
                if file_size > 0:
                    ss_fh = open(ss_tmp_path, "rb")
                    ss_mmap_obj = _mmap_mod.mmap(ss_fh.fileno(), 0, access=_mmap_mod.ACCESS_READ)

            def _get_ss(idx):
                if ss_mmap_obj is not None and 0 <= idx < len(ss_offsets):
                    offset = ss_offsets[idx]
                    length = _struct.unpack_from("<I", ss_mmap_obj, offset)[0]
                    start = offset + 4
                    return ss_mmap_obj[start:start + length].decode("utf-8")
                return ""

            if sheet_name:
                sp = _resolve_xlsx_sheet_path(zf, sheet_name)
                if not sp:
                    return
            else:
                sheets = sorted([n for n in zf.namelist() if "worksheets/sheet" in n])
                sp = sheets[0] if sheets else "xl/worksheets/sheet1.xml"

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
                        rn = int(elem.get("r", "0")) - 1
                        yield (rn, cells)
                        cells = []
                        elem.clear()

    finally:
        if ss_mmap_obj is not None:
            ss_mmap_obj.close()
        if ss_fh is not None:
            ss_fh.close()
        if _owns_ss and ss_tmp_path:
            try:
                os.remove(ss_tmp_path)
            except Exception:
                pass


# ── 조직 및 주소 상수 ────────────────────────────────────────────

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
INSP_TEAM_TO_HDQT: dict = {team: hdqt for hdqt, teams in INSP_ORG_MAP.items() for team in teams}

_VALID_SKT_HDQTS: set = {'수도권', '중부', '서부', '동부'}
_ACCESS_TO_SKT_HDQT: dict = {
    '강남': '수도권', '강북': '수도권', '경기': '수도권', '인천': '수도권', '강원': '수도권',
    '충청': '중부',
    '서부': '서부',
    '경북': '동부', '경남': '동부',
}


def _normalize_skt_hdqt(raw: str, access: str = '') -> str:
    s = (raw or '').strip()
    if s in _VALID_SKT_HDQTS:
        return s
    for suffix in ('Network담당', 'Access담당', '품질개선팀', '담당'):
        if s.endswith(suffix):
            s = s[:-len(suffix)].strip()
            break
    if s in _VALID_SKT_HDQTS:
        return s
    for v in _VALID_SKT_HDQTS:
        if s.startswith(v):
            return v
    if raw in INSP_TEAM_TO_HDQT:
        derived_access = INSP_TEAM_TO_HDQT[raw]
        if derived_access in _ACCESS_TO_SKT_HDQT:
            return _ACCESS_TO_SKT_HDQT[derived_access]
    access_clean = (access or '').strip()
    if access_clean in _ACCESS_TO_SKT_HDQT:
        return _ACCESS_TO_SKT_HDQT[access_clean]
    return ''


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
_SEOUL_GU_SORTED: list = sorted(_SEOUL_GU_TO_TEAM.items(), key=lambda x: -len(x[0]))

_ADDR_ABBR_MAP: dict = {
    '서울 ': '서울특별시 ', '부산 ': '부산광역시 ', '대구 ': '대구광역시 ',
    '인천 ': '인천광역시 ', '광주 ': '광주광역시 ', '대전 ': '대전광역시 ',
    '울산 ': '울산광역시 ', '세종 ': '세종특별자치시 ', '경기 ': '경기도 ',
    '강원 ': '강원특별자치도 ', '충북 ': '충청북도 ', '충남 ': '충청남도 ',
    '전북 ': '전북특별자치도 ', '전남 ': '전라남도 ',
    '경북 ': '경상북도 ', '경남 ': '경상남도 ', '제주 ': '제주특별자치도 ',
}


def _normalize_addr(addr: str) -> str:
    import re as _re
    addr = _re.sub(r'^\s*\([^)]*\)\s*', '', addr).strip()
    addr = _re.sub(r'(서울)\s*(특별시)', r'\1\2', addr)
    addr = _re.sub(r'(부산|대구|인천|광주|대전|울산)\s*(광역시)', r'\1\2', addr)
    addr = _re.sub(r'(세종)\s*(특별자치시)', r'\1\2', addr)
    addr = _re.sub(r'(경기|충청북|충청남|전라북|전라남|경상북|경상남)\s*(도)', r'\1\2', addr)
    addr = _re.sub(r'(강원)\s*(특별자치도)', r'\1\2', addr)
    addr = _re.sub(r'(전북)\s*(특별자치도)', r'\1\2', addr)
    addr = _re.sub(r'(제주)\s*(특별자치도)', r'\1\2', addr)
    for abbr, full in _ADDR_ABBR_MAP.items():
        if addr.startswith(abbr):
            return full + addr[len(abbr):]
    return addr


_LEGAL_DONG_MAP: dict = {}


def _load_legal_dong_map():
    global _LEGAL_DONG_MAP
    tsv_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "legal_dong_code.tsv")
    tsv_path = os.path.normpath(tsv_path)
    if not os.path.exists(tsv_path):
        logger.warning(f"법정동 코드 파일 없음: {tsv_path}")
        return
    count = 0
    with open(tsv_path, encoding='utf-8') as f:
        next(f)
        for line in f:
            parts = line.strip().split('\t')
            if len(parts) >= 3 and parts[2] == '존재':
                _LEGAL_DONG_MAP[parts[0]] = parts[1]
                count += 1
    logger.info(f"법정동 코드표 로드 완료: {count}개")


_load_legal_dong_map()


def _pnu_to_addr(pnu: str) -> str:
    pnu = str(pnu).strip()
    if len(pnu) < 10:
        return ''
    dong_code = pnu[:10]
    dong_name = _LEGAL_DONG_MAP.get(dong_code, '')
    if not dong_name:
        sigungu = pnu[:5] + '00000'
        dong_name = _LEGAL_DONG_MAP.get(sigungu, '')
    if not dong_name:
        return ''
    if len(pnu) >= 15:
        try:
            is_san = pnu[10] == '1'
            bon = int(pnu[11:15])
            bu = int(pnu[15:19]) if len(pnu) >= 19 else 0
            if bon > 0:
                san_prefix = '산' if is_san else ''
                dong_name += f' {san_prefix}{bon}'
                if bu > 0:
                    dong_name += f'-{bu}'
        except ValueError:
            pass
    return dong_name


def _hdqt_from_addr(addr: str, known_hdqt: str = '',
                    learned_map: dict = None) -> tuple:
    if not addr:
        return known_hdqt, ''
    addr = _normalize_addr(addr.strip())
    is_seoul = ('서울특별시' in addr) or ('서울 ' in addr) or addr.startswith('서울')
    if is_seoul:
        for kw, (hdqt, team) in _SEOUL_GU_SORTED:
            if kw not in addr:
                continue
            if known_hdqt and hdqt != known_hdqt:
                continue
            return hdqt, team
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
    import re
    from collections import Counter, defaultdict

    _db = db_path or _cert_cache_mod._cert_cache_db_path
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
            normalized = _normalize_addr(str(zpwiadr))
            matches = geo_re.findall(normalized)
            for kw in matches:
                if not kw.endswith('동'):
                    kw_teams[kw][team] += 1
            cities = [m for m in matches if m.endswith('시')]
            gus = [m for m in matches if m.endswith('구')]
            guns = [m for m in matches if m.endswith('군')]
            eups = [m for m in matches if m.endswith('읍')]
            myeons = [m for m in matches if m.endswith('면')]
            dongs = [m for m in matches if m.endswith('동')]
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
        top_team, _ = counter.most_common(1)[0]
        learned[kw] = top_team

    logger.info(f"주소→팀 학습 완료(cert DB): {len(learned)}개 키워드 확정 "
                f"(전체 후보: {len(kw_teams)}개)")
    return learned


def _learn_pnu_map_from_cert_db() -> dict:
    from collections import Counter, defaultdict

    if not _cert_cache_mod._cert_cache_db_path or not os.path.exists(_cert_cache_mod._cert_cache_db_path):
        logger.warning("cert DB 없음 — PNU→팀 학습 생략")
        return {}

    pnu_teams: dict = defaultdict(Counter)

    try:
        c = sqlite3.connect(_cert_cache_mod._cert_cache_db_path, timeout=30)
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
        top_team, _ = counter.most_common(1)[0]
        learned[pnu10] = top_team

    logger.info(f"PNU→팀 학습 완료(cert DB): {len(learned)}개 PNU 확정 "
                f"(전체 후보: {len(pnu_teams)}개)")
    return learned


# ── ds_detail.db 스키마 ─────────────────────────────────────────

def _init_ds_detail_db():
    conn = sqlite3.connect(_DS_DETAIL_DB, timeout=60)
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('PRAGMA synchronous=NORMAL')
    conn.execute('''CREATE TABLE IF NOT EXISTS ds_일반사항 (
        허가번호 TEXT PRIMARY KEY, 무선국명 TEXT, 호출명칭 TEXT
    )''')
    try:
        conn.execute('ALTER TABLE ds_일반사항 ADD COLUMN 통합시설명칭 TEXT')
        conn.commit()
    except Exception:
        pass
    try:
        conn.execute('ALTER TABLE ds_일반사항 ADD COLUMN 공용화구분코드명 TEXT')
        conn.commit()
    except Exception:
        pass
    try:
        conn.execute('ALTER TABLE ds_일반사항 ADD COLUMN 설치장소 TEXT')
        conn.commit()
    except Exception:
        pass
    conn.execute('''CREATE TABLE IF NOT EXISTS ds_설치장소 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        허가번호 TEXT NOT NULL,
        설치장소구분 TEXT NOT NULL DEFAULT '',
        설치장소주소 TEXT,
        UNIQUE(허가번호, 설치장소구분)
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_dsd_설치장소_허가번호 ON ds_설치장소(허가번호)')
    conn.execute('''CREATE TABLE IF NOT EXISTS ds_장치 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        허가번호 TEXT, 장치번호 TEXT, 기기일련번호 TEXT, 형식검정번호 TEXT
    )''')
    try: conn.execute('ALTER TABLE ds_장치 ADD COLUMN 형식검정번호 TEXT'); conn.commit()
    except Exception: pass
    try: conn.execute('ALTER TABLE ds_장치 ADD COLUMN 장치상태 TEXT'); conn.commit()
    except Exception: pass
    conn.execute('''CREATE TABLE IF NOT EXISTS ds_안테나 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        허가번호 TEXT, 장치번호 TEXT,
        기 TEXT, 이득 TEXT, 공중선주설치형태명 TEXT,
        공중선일련번호 TEXT, 공중선형식명 TEXT
    )''')
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
    for col, dflt in [
        ('cancelled', "'0'"), ('cancelled_at', "''"), ('cancelled_by', "''"),
        ('division_id', "''"), ('upload_id', "''"),
        ('uploaded_by', "''"), ('uploaded_at', "''"), ('uploaded_filename', "''"),
    ]:
        try:
            conn.execute(f"ALTER TABLE ds_변경이력 ADD COLUMN {col} TEXT DEFAULT {dflt}")
        except Exception:
            pass
    conn.execute('CREATE INDEX IF NOT EXISTS idx_dsh_division ON ds_변경이력(division_id)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_dsh_upload ON ds_변경이력(upload_id)')
    conn.commit(); conn.close()


try:
    _init_inspection_db()
    _init_ds_detail_db()
except Exception as _e:
    logger.warning(f"inspection DB 초기화 실패 (무시): {_e}")


# ── DS 상세 빌드 (XLS ZIP → ds_detail.db) ──────────────────────

def _build_ds_detail_from_zip_sync(zip_path: str):
    """DS ZIP에서 일반사항/장치/안테나/전파형식/주파수 시트 파싱 → ds_detail.db 갱신."""
    _init_ds_detail_db()
    conn = sqlite3.connect(_DS_DETAIL_DB, timeout=60)
    conn.execute('PRAGMA journal_mode=WAL')

    batches: dict = {'일반사항': [], '장치': [], '안테나': [], '전파형식': [], '주파수': [],
                     '설치장소': {}, '설치장소_rows': []}
    _seen_licenses: set = set()

    def _col_idx(ws, *names):
        h = [str(ws.cell_value(0, c)) for c in range(ws.ncols)]
        for name in names:
            if name in h: return h.index(name)
        return -1

    def _sv(ws, r, ci):
        return str(ws.cell_value(r, ci) or '').strip() if ci >= 0 else ''

    def _hn(ws, r, ci):
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

                    if '설치장소' in sheet_names:
                        ws = wb.sheet_by_name('설치장소')
                        hi = _col_idx(ws, '허가번호')
                        ai = _col_idx(ws, '설치장소입력주소')
                        gi = _col_idx(ws, '설치장소구분')
                        if hi >= 0 and ai >= 0:
                            for r in range(1, ws.nrows):
                                h = _hn(ws, r, hi)
                                v = _sv(ws, r, ai)
                                if not (h and v):
                                    continue
                                gubun = _sv(ws, r, gi) if gi >= 0 else ''
                                batches['설치장소_rows'].append((h, gubun, v))
                                if h not in batches['설치장소']:
                                    batches['설치장소'][h] = v

                    wb.release_resources()
                except Exception as xe:
                    logger.warning(f"ds_detail XLS 파싱 실패 {xls_name}: {xe}")

        if _seen_licenses:
            lic_list = list(_seen_licenses)
            _BATCH = 900
            for tbl in ('ds_일반사항', 'ds_장치', 'ds_안테나', 'ds_전파형식', 'ds_주파수', 'ds_설치장소'):
                for i in range(0, len(lic_list), _BATCH):
                    chunk = lic_list[i:i+_BATCH]
                    ph = ','.join('?' * len(chunk))
                    conn.execute(f'DELETE FROM {tbl} WHERE 허가번호 IN ({ph})', chunk)
            conn.executemany('INSERT OR REPLACE INTO ds_일반사항(허가번호,무선국명,호출명칭,통합시설명칭,공용화구분코드명) VALUES(?,?,?,?,?)', batches['일반사항'])
            conn.executemany('INSERT INTO ds_장치(허가번호,장치번호,기기일련번호,형식검정번호,장치상태) VALUES(?,?,?,?,?)', batches['장치'])
            conn.executemany('INSERT INTO ds_안테나(허가번호,장치번호,기,이득,공중선주설치형태명,공중선일련번호,공중선형식명) VALUES(?,?,?,?,?,?,?)', batches['안테나'])
            conn.executemany('INSERT INTO ds_전파형식(허가번호,장치번호,공중선전력) VALUES(?,?,?)', batches['전파형식'])
            conn.executemany('INSERT INTO ds_주파수(허가번호,장치번호,주파수,송수신구분) VALUES(?,?,?,?)', batches['주파수'])
            if batches['설치장소_rows']:
                conn.executemany(
                    'INSERT OR REPLACE INTO ds_설치장소(허가번호,설치장소구분,설치장소주소) VALUES(?,?,?)',
                    batches['설치장소_rows'])
            for hn, addr in batches['설치장소'].items():
                conn.execute('UPDATE ds_일반사항 SET 설치장소=? WHERE 허가번호=?', (addr, hn))
            conn.commit()
            logger.info(f"ds_detail 재빌드 완료: {len(_seen_licenses)}개 허가번호")
    finally:
        conn.close()


def _process_inspection_sync(job_id: str, s3_key: str, year: int, uploaded_by: str):
    """KCA 수검대상 Excel → inspection.db 구축 (백그라운드)."""
    import sqlite3, openpyxl, tempfile, gc

    _init_inspection_db()
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    conn.execute('PRAGMA synchronous=NORMAL')
    now_iso = datetime.now(timezone.utc).isoformat

    def _upd(pct, stage, **kw):
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
        sheet_names = _list_xlsx_sheet_names(tmp_path)

        conn.execute('DELETE FROM inspection_targets_staging WHERE year=?', (year,))
        conn.execute('DELETE FROM inspection_meta WHERE year=?', (year,))
        conn.commit()

        _upd(14, "ERP 데이터 로드 중...")
        _cert_db = os.path.join(_tempfile.gettempdir(), "cert_cache.db")
        if not os.path.exists(_cert_db) or os.path.getsize(_cert_db) < 1000:
            _cert_cache_load()
        else:
            _cert_cache_mod._cert_cache_db_path = _cert_db
            logger.info(f"cert DB 캐시 재사용: {_cert_db}")
        def _norm_code(v) -> str:
            s = str(v).strip()
            if not s:
                return s
            if '.' in s:
                try:
                    s = str(int(float(s)))
                except ValueError:
                    pass
            if s.isdigit():
                s = str(int(s))
            return s

        cert_map: dict = {}
        cert_name_map: dict = {}
        try:
            c2 = sqlite3.connect(_cert_db, timeout=60)
            for r in c2.execute('SELECT zpwina, zpwino, area_hdofc_nm, ons_team_nm, zpcode FROM cert'):
                hdofc = str(r[2] or ''); team = str(r[3] or ''); name = str(r[0] or '')
                n_zpwina = _norm_code(r[0]) if r[0] else ''
                n_zpwino = _norm_code(str(r[1] or '').replace('-', '')) if r[1] else ''
                n_zpcode = _norm_code(r[4]) if r[4] else ''
                for ncode in filter(None, [n_zpwina, n_zpwino]):
                    existing = cert_map.get(ncode)
                    if existing is None:
                        cert_map[ncode] = (hdofc, team, name)
                    elif name and not existing[2]:
                        cert_map[ncode] = (existing[0], existing[1], name)
                if n_zpcode and n_zpwino and name:
                    cert_name_map[(n_zpcode, n_zpwino)] = name
            c2.close()
            logger.info(f"cert_map 로드: {len(cert_map)}개 코드, {len(cert_name_map)}개 (통시+허가) 매핑")
        except Exception as e:
            logger.warning(f"cert_map 로드 실패: {e}")

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
                    if learned_addr_map:
                        logger.info(f"학습 맵 캐시 재사용: {len(learned_addr_map)}개 키워드 ({cache_age:.0f}초 전)")
                        _cache_valid = True
            except Exception:
                pass
        if not _cache_valid:
            learned_addr_map = _learn_addr_map_from_cert_db(db_path=_cert_db)
            with open(_learned_cache, 'w', encoding='utf-8') as f:
                _j2.dump(learned_addr_map, f, ensure_ascii=False)

        def _match_access(tongsi: str, gongtae: str):
            for val in [tongsi, gongtae]:
                if not val:
                    continue
                normed = _norm_code(val)
                if normed in cert_map:
                    entry = cert_map[normed]
                    return entry[0], entry[1]
            return '', ''

        def _lookup_name(tongsi: str, gongtae: str, license_no: str = '') -> str:
            normed_lic = _norm_code(license_no.replace('-', '')) if license_no else ''
            for val in [tongsi, gongtae]:
                if not val:
                    continue
                normed = _norm_code(val)
                if normed_lic:
                    name = cert_name_map.get((normed, normed_lic))
                    if name:
                        return name
                entry = cert_map.get(normed)
                if entry and len(entry) > 2 and entry[2]:
                    return entry[2]
            return ''

        def _correct_hdqt(access: str, team: str) -> str:
            if team in INSP_TEAM_TO_HDQT:
                return INSP_TEAM_TO_HDQT[team]
            return access

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
            nonlocal matched, unmatched
            cm = col_map or {}
            def _ci(key, default_idx):
                idx = cm.get(key, -1)
                return idx if idx >= 0 else default_idx
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
                if len(row) <= IDX_HN:
                    continue
                raw_license = str(row[IDX_HN] or '').strip()
                if not raw_license:
                    continue
                access = str(row[IDX_ACCESS] or '').strip() if is_skt and len(row) > IDX_ACCESS else ''
                if access in _INVALID_TEAM: access = ''
                품질 = str(row[IDX_TEAM] or '').strip() if is_skt and len(row) > IDX_TEAM else ''
                if 품질 in _INVALID_TEAM: 품질 = ''
                tongsi = str(row[IDX_TONGSI] or '').strip() if is_skt and len(row) > IDX_TONGSI else ''
                gongtae = str(row[IDX_GONGTAE] or '').strip() if is_skt and len(row) > IDX_GONGTAE else ''
                skt본부_raw = str(row[IDX_SKTHDQT] or '').strip() if is_skt and len(row) > IDX_SKTHDQT else ''
                skt본부 = _normalize_skt_hdqt(skt본부_raw)

                if not access:
                    access, 품질 = _match_access(tongsi, gongtae)
                    if access: matched += 1
                    else: unmatched += 1
                else:
                    matched += 1

                _access_base = re.sub(r'Access담당$|Access$', '', access).strip()
                _orig_access_is_valid = _access_base in _ACCESS_TO_SKT_HDQT
                if _orig_access_is_valid and _access_base != access:
                    access = _access_base
                if 품질 in INSP_TEAM_TO_HDQT:
                    if not _orig_access_is_valid:
                        access = INSP_TEAM_TO_HDQT[품질]
                elif 품질 in _DEPRECATED_TEAM_MAP:
                    품질 = _DEPRECATED_TEAM_MAP[품질]
                    if not _orig_access_is_valid:
                        access = INSP_TEAM_TO_HDQT.get(품질, access)
                elif not _orig_access_is_valid:
                    fb_access, fb_team = _match_access(tongsi, gongtae)
                    if fb_team and fb_team in INSP_TEAM_TO_HDQT:
                        access = INSP_TEAM_TO_HDQT[fb_team]
                        품질 = fb_team
                    else:
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
                    if not v or v == '':
                        return default
                    try:
                        return int(float(str(v)))
                    except (ValueError, TypeError):
                        return default

                def _safe_str(v):
                    return str(v).strip() if v else ''

                if not skt본부 and access:
                    skt본부 = _ACCESS_TO_SKT_HDQT.get(access, '')

                insp_type_raw = _safe_str(row[insp_type_col] if insp_type_col >= 0 and len(row) > insp_type_col else '')
                def _get(idx):
                    return row[idx] if idx >= 0 and len(row) > idx else ''
                호출명칭 = _safe_str(_get(IDX_NAME))
                if 호출명칭.startswith('#'):
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
            '통시': ['통시', '통합시설코드', '통합시설번호'],
            '공대': ['공대', '공용대표코드', '공통대지코드'],
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

        if 'SKT' in sheet_names:
            _upd(20, "SKT 시트 처리 중...")
            _log_mem("SKT 시트 처리 전")

            _skt_col_map = _build_col_map('SKT')
            _insp_type_col = _skt_col_map.get('검사종류', -1)
            logger.info(f"SKT 시트 헤더 매핑: {_skt_col_map}")

            def _light_rows(path, sname):
                for _rn, cells in _iter_xlsx_rows_light(path, sheet_name=sname):
                    if _rn == 0:
                        continue
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

        if 'Sheet1' in sheet_names:
            _upd(72, "시기조정 시트 처리 중...")
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


@router.post("/inspection/upload-raw")
async def inspection_upload_raw(request: Request):
    """KCA Excel → S3 스트리밍 업로드."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    fname = request.headers.get("X-Filename", "inspection.xlsx")
    fname = os.path.basename(fname)
    fname = re.sub(r"[^\w\-.]", "_", fname)
    if not fname or fname.startswith(".") or len(fname) > 200:
        fname = "inspection.xlsx"
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
        logger.error(f"inspection multipart upload 실패: {ex}")
        raise HTTPException(500, "업로드 실패")

    return {"success": True, "s3Key": s3_key}

@router.post("/inspection/enqueue")
async def inspection_enqueue(request: Request, req: InspectionEnqueueReq):
    """KCA Import 백그라운드 잡 생성 — 별도 프로세스로 실행 (API 서버 블록 방지)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    job_id = str(uuid.uuid4())
    _init_inspection_db()
    await asyncio.to_thread(_insp_job_write_sync, job_id, status='processing', stage='대기 중...', percent=0)

    import subprocess
    worker_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'inspection_worker.py')
    log_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', f'inspection_{job_id[:8]}.log')
    venv_python = sys.executable
    log_fh = open(log_path, 'w')
    subprocess.Popen(
        [venv_python, worker_path, job_id, req.s3Key, str(req.year), req.uploadedBy],
        cwd=os.path.dirname(os.path.abspath(__file__)),
        stdout=log_fh,
        stderr=log_fh,
        start_new_session=True,
    )
    logger.info(f"inspection import subprocess 시작: job={job_id}")
    return {"success": True, "jobId": job_id}

@router.get("/inspection/job/{job_id}")
async def inspection_job_status(job_id: str, request: Request):
    await _verify_auth(request)
    job = await asyncio.to_thread(_insp_job_read_sync, job_id)
    if not job: raise HTTPException(404, "잡 없음")
    return job

@router.post("/inspection/build-ds-detail")
async def inspection_build_ds_detail(request: Request, division_id: str, import_date: str):
    """DS ZIP → ds_detail.db 빌드 (관리자 수동 트리거)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}: raise HTTPException(403, "권한 없음")

    sk_parts = import_date.split('#', 1)
    if len(sk_parts) == 2:
        division_code_part, date_part = sk_parts
    else:
        division_code_part, date_part = "", import_date
    s3_key = f"ds-raw/{division_id}/{division_code_part}_{date_part}.zip"

    try:
        s3_check = get_s3_client()
        s3_check.head_object(Bucket=S3_BUCKET_NAME, Key=s3_key)
    except Exception:
        raise HTTPException(404, f"S3에 파일 없음: {s3_key}")

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

@router.get("/inspection/meta")
async def inspection_meta(request: Request):
    """Import 이력 조회."""
    await _verify_auth(request)
    import sqlite3
    if not os.path.exists(_INSP_DB): return {"items": []}
    conn = sqlite3.connect(_INSP_DB, timeout=60); conn.row_factory = sqlite3.Row
    rows = conn.execute('SELECT * FROM inspection_meta ORDER BY year DESC').fetchall()
    conn.close()
    return {"items": [dict(r) for r in rows]}

@router.get("/inspection/unassigned")
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
        has_code = bool((r['통시'] or '').strip() or (r['공대'] or '').strip())
        reason = "ERP미매칭" if has_code else "코드없음"
        by_reason[reason] += 1
        d = dict(r)
        d['미배정원인'] = reason
        items.append(d)
    conn.close()
    return {
        "total": len(rows),
        "items": items[:500],
        "items_capped": len(rows) > 500,
        "by_region": dict(sorted(by_region.items(), key=lambda x: -x[1])),
        "by_reason": by_reason,
    }

@router.get("/inspection/column-values")
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

@router.get("/inspection/staging/column-values")
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

@router.get("/inspection/org-map")
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
    return {"org": INSP_ORG_MAP, "quarters": quarters, "nation_groups": nation_groups, "kca_results": kca_results}

class InspStagingPreviewReq(BaseModel):
    year: int
    filters: dict = {}

class InspStagingConfirmReq(BaseModel):
    year: int
    filters: dict = {}

@router.post("/inspection/staging/preview")
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

@router.post("/inspection/staging/items")
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
    search_feedback = None
    if req.search:
        import re as _re_fb
        keywords = [k.strip() for k in _re_fb.split(r'[,\s]+', req.search.strip()) if k.strip()]
        _hn_re2 = _re_fb.compile(r'^[\d\-]{15,19}$')
        if len(keywords) > 1 and all(_hn_re2.match(kw) for kw in keywords):
            searched_nos = {kw.replace('-', '') for kw in keywords}
            found_in_staging = {r['허가번호'].replace('-', '') for r in rows}
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

@router.post("/inspection/staging/confirm")
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

    added_rows = conn.execute(
        'SELECT * FROM inspection_targets WHERE year=? AND kca검토결과=?',
        (req.year, '대상 추가')
    ).fetchall()
    added_list = [dict(r) for r in added_rows]
    added_license_nos = {r['허가번호'] for r in added_list if r['허가번호']}

    coord_map: dict = {}
    for r in conn.execute(
        'SELECT 허가번호, 위도, 경도 FROM inspection_targets '
        'WHERE year=? AND 위도 IS NOT NULL AND 위도 != 0',
        (req.year,)
    ).fetchall():
        hn = r['허가번호'] or ''
        if hn:
            coord_map[hn] = (r['위도'], r['경도'])

    conn.execute('DELETE FROM inspection_targets WHERE year=?', (req.year,))

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

    preserved_count = 0
    if added_list:
        cols_with_coord = cols + ',위도,경도'
        col_list_wc = cols_with_coord.split(',')
        ph = ','.join('?' * len(col_list_wc))
        for row in added_list:
            vals = tuple(row.get(c) for c in col_list_wc)
            conn.execute(f'INSERT INTO inspection_targets ({cols_with_coord}) VALUES ({ph})', vals)
            preserved_count += 1

    if added_license_nos:
        ph = ','.join('?' * len(added_license_nos))
        conn.execute(
            f'DELETE FROM inspection_targets_staging WHERE year=? AND 허가번호 IN ({ph})',
            [req.year] + list(added_license_nos),
        )

    conn.execute(f'DELETE FROM inspection_targets_staging WHERE {where_sql}', params)

    coord_restored = 0
    if coord_map:
        for hn, (lat, lng) in coord_map.items():
            cur = conn.execute(
                'UPDATE inspection_targets SET 위도=?, 경도=? '
                'WHERE year=? AND 허가번호=? '
                'AND (위도 IS NULL OR 위도=0)',
                (lat, lng, req.year, hn)
            )
            if cur.rowcount > 0:
                coord_restored += cur.rowcount
    conn.commit()
    conn.close()

    logger.info(f"confirm: {req.year}년 신규 {count}건 + 보존 {preserved_count}건 (대상 추가) + 좌표 복원 {coord_restored}건")

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
        await _auto_geocode_background(req.year)

    asyncio.create_task(_post_confirm_bg())

    return {"success": True, "count": count, "preserved_count": preserved_count, "coord_restored": coord_restored}


async def _auto_geocode_background(year: int):
    """confirm 후 자동으로 좌표 없는 항목 지오코딩 (백그라운드)."""
    try:
        KAKAO_KEY = KAKAO_REST_KEY
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

        _VWORLD_KEY = VWORLD_API_KEY

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

        _NAVER_ID = NAVER_CLIENT_ID
        _NAVER_SECRET = NAVER_CLIENT_SECRET

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

            addr = (r['도로명주소'] or '').strip() or (r['설치장소'] or '').strip()
            new_access = old_access
            new_team = old_team
            if addr:
                inferred_access, inferred_team = _hdqt_from_addr(addr, learned_map=learned_map)
                if inferred_access:
                    new_access = inferred_access
                if inferred_team:
                    new_team = inferred_team

            new_skt = _normalize_skt_hdqt(old_skt, access=new_access)

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


@router.post("/inspection/remap-divisions")
async def inspection_remap_divisions(request: Request, year: int, dry_run: bool = True):
    """도로명주소 기반으로 inspection_targets의 access담당/품질개선팀을 재매핑."""
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


class PreCheckStatusReq(BaseModel):
    license_nos: list[str]
    status: str = "PRE_CHECKED"
    year: int = 0


@router.patch("/inspection/targets/pre-check-status")
async def update_pre_check_status(request: Request, req: PreCheckStatusReq):
    """사전점검완료 상태 마킹 (admin/manager 전용)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in ("admin", "manager"):
        raise HTTPException(403, "admin/manager만 가능")
    if not req.license_nos:
        raise HTTPException(400, "license_nos 비어있음")

    def _update():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            updated_targets = 0
            updated_schedules = 0
            now = datetime.now(timezone.utc).isoformat()
            ok_from = {WF_REGISTERED, WF_PRE_CHECK, WF_RE_CHECK}
            for no in req.license_nos:
                if req.year:
                    row = c.execute(
                        "SELECT pk, workflow_status FROM inspection_schedules "
                        "WHERE REPLACE(허가번호,'-','')=REPLACE(?,'-','') AND year=?",
                        (no, req.year)).fetchone()
                else:
                    row = c.execute(
                        "SELECT pk, workflow_status FROM inspection_schedules "
                        "WHERE REPLACE(허가번호,'-','')=REPLACE(?,'-','')",
                        (no,)).fetchone()
                if row:
                    pk, cur_st = row[0], (row[1] or WF_REGISTERED)
                    if cur_st not in ok_from:
                        continue
                    c.execute(
                        'UPDATE inspection_schedules SET workflow_status=?, '
                        'status_updated_at=?, status_updated_by=? WHERE pk=?',
                        (WF_PRE_CHECK_DONE, now, empno, pk))
                    _wf_record_log_sync(c, pk, cur_st, WF_PRE_CHECK_DONE, empno,
                                        "ERP-DS 전산비교 완료 후 사전점검완료 처리")
                    updated_schedules += 1
                else:
                    if req.year:
                        cur = c.execute(
                            "UPDATE inspection_targets SET pre_check_status=? WHERE 허가번호=? AND year=?",
                            (req.status, no, req.year))
                    else:
                        cur = c.execute(
                            "UPDATE inspection_targets SET pre_check_status=? WHERE 허가번호=?",
                            (req.status, no))
                    updated_targets += cur.rowcount
            c.commit()
            return updated_targets, updated_schedules
        finally:
            c.close()

    updated_targets, updated_schedules = await asyncio.to_thread(_update)
    total = updated_targets + updated_schedules
    return {"success": True, "updated": total,
            "updated_targets": updated_targets, "updated_schedules": updated_schedules}


@router.post("/inspection/geocode-targets")
async def inspection_geocode_targets(request: Request, year: int):
    """기존 inspection_targets의 위경도를 Kakao 지오코딩으로 채움 (관리자 1회성)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")
    if not os.path.exists(_INSP_DB):
        raise HTTPException(400, "DB 없음")

    KAKAO_KEY = KAKAO_REST_KEY
    CONCURRENCY = 10

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

    import requests as _req
    from concurrent.futures import ThreadPoolExecutor, as_completed

    def _clean_addr(addr: str) -> list:
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

    VWORLD_KEY = VWORLD_API_KEY

    def _call_kakao_addr(query: str):
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

    def _call_kakao_keyword(query: str):
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

    def _call_vworld(query: str):
        try:
            r = _req.get('https://api.vworld.kr/req/address',
                params={'service': 'address', 'request': 'getcoord', 'version': '2.0',
                        'crs': 'epsg:4326', 'address': query, 'refine': 'true',
                        'simple': 'false', 'format': 'json', 'type': 'both',
                        'key': VWORLD_KEY}, timeout=5)
            if r.status_code == 200:
                body = r.json().get('response', {})
                if body.get('status') == 'OK':
                    pt = body.get('result', {}).get('point', {})
                    x, y = float(pt.get('x', 0)), float(pt.get('y', 0))
                    if x and y: return (y, x)
        except Exception: pass
        return None

    def _call_naver(query: str):
        try:
            r = _req.get('https://maps.apigw.ntruss.com/map-geocode/v2/geocode',
                params={'query': query},
                headers={'X-NCP-APIGW-API-KEY-ID': NAVER_CLIENT_ID,
                         'X-NCP-APIGW-API-KEY': NAVER_CLIENT_SECRET}, timeout=5)
            if r.status_code == 200:
                addresses = r.json().get('addresses', [])
                if addresses:
                    x = float(addresses[0].get('x', 0))
                    y = float(addresses[0].get('y', 0))
                    if x and y: return (y, x)
        except Exception: pass
        return None

    def _geocode_one(addr: str):
        try:
            candidates = _clean_addr(addr)
            for candidate in candidates:
                result = _call_kakao_addr(candidate)
                if result: return addr, result
            for candidate in candidates:
                result = _call_kakao_keyword(candidate)
                if result: return addr, result
            for candidate in candidates:
                result = _call_vworld(candidate)
                if result: return addr, result
            for candidate in candidates:
                result = _call_naver(candidate)
                if result: return addr, result
            logger.warning(f"[geocode-targets] 주소 매칭 없음: {addr}")
        except Exception as e:
            logger.warning(f"[geocode-targets] 요청 실패: {addr} — {e}")
        return addr, None

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
    filters: dict = {}
    search: str = ""
    addr: str = ""
    page: int = 1
    page_size: int = 100
    schedule_yn: str = ""
    schedule_week: str = ""
    workflow_status: str = ""
    needs_recheck: str = ""
    overdue_only: str = ""
    sort_by: str = ""
    sort_dir: str = "asc"

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
    import re as _re_search
    keywords = [k.strip() for k in _re_search.split(r'[,\s]+', s) if k.strip()] if s else []
    addr_keywords = [k.strip() for k in _re_search.split(r'[,\s]+', a) if k.strip()] if a else []
    _hn_re2 = _re_search.compile(r'^[\d\-]{15,19}$')
    if keywords and addr_keywords and keywords == addr_keywords:
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
    if workflow_status:
        statuses = [s.strip() for s in workflow_status.split(',') if s.strip()]
        or_parts, or_params = [], []
        sched_statuses = []
        for st in statuses:
            if st == '미배정':
                or_parts.append("REPLACE(허가번호,'-','') NOT IN (SELECT REPLACE(허가번호,'-','') FROM inspection_schedules WHERE year=?)")
                or_params.append(year)
            elif st == 'PRE_CHECKED':
                or_parts.append("(pre_check_status IS NOT NULL AND pre_check_status != '' AND REPLACE(허가번호,'-','') NOT IN (SELECT REPLACE(허가번호,'-','') FROM inspection_schedules WHERE year=?))")
                or_params.append(year)
            else:
                sched_statuses.append(st)
        if sched_statuses:
            ph = ','.join('?' * len(sched_statuses))
            or_parts.append(f"REPLACE(허가번호,'-','') IN (SELECT REPLACE(허가번호,'-','') FROM inspection_schedules WHERE year=? AND workflow_status IN ({ph}))")
            or_params.extend([year, *sched_statuses])
        if or_parts:
            where.append('(' + ' OR '.join(or_parts) + ')')
            params.extend(or_params)
    if needs_recheck == '1':
        where.append("REPLACE(허가번호,'-','') IN (SELECT REPLACE(허가번호,'-','') FROM inspection_results WHERE year=? AND needs_recheck='1')")
        params.append(year)
    if overdue_only == '1':
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

@router.post("/inspection/data")
async def inspection_data(request: Request, req: InspectionDataReq):
    """필터 적용 데이터 조회 (페이지네이션)."""
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB): return {"items": [], "total": 0}
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
    _ALLOWED_INSP_SORT = {
        '허가번호', '호출명칭', '국종군', '부서', '연도주기',
        '설치장소', '도로명주소', '장치수', '통시', '공대',
        'zpprac1', '시기조정', '기준연도', 'skt본부', 'access담당', '품질개선팀',
    }
    _s_col = req.sort_by if req.sort_by in _ALLOWED_INSP_SORT else ''
    _s_dir = 'ASC' if req.sort_dir.lower() == 'asc' else 'DESC'
    if _s_col:
        _null_last = f'CASE WHEN "{_s_col}" IS NULL OR "{_s_col}" = \'\' THEN 1 ELSE 0 END'
        _order_clause = f'ORDER BY {_null_last}, "{_s_col}" {_s_dir}'
    else:
        _order_clause = 'ORDER BY id'

    def _read():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        total = c.execute(f'SELECT COUNT(*) FROM inspection_targets WHERE {where_sql}', params).fetchone()[0]
        offset = (req.page - 1) * req.page_size
        rows = c.execute(
            f'''SELECT t.*, s.수검예정주차,
                    COALESCE(r.status, irr.합불여부) AS 검사결과
                FROM (SELECT * FROM inspection_targets WHERE {where_sql} {_order_clause} LIMIT ? OFFSET ?) t
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

        items = [dict(r) for r in rows]

        _cert_db = _cert_cache_mod._cert_cache_db_path or os.path.join(_tempfile.gettempdir(), "cert_cache.db")
        if _cert_db and os.path.exists(_cert_db):
            try:
                _missing = [(i, str(it.get('허가번호') or '').strip(),
                               str(it.get('호출명칭') or '').strip())
                            for i, it in enumerate(items)
                            if not (it.get('통시') or '').strip()]
                if _missing:
                    _pairs = list({(wino, wina) for _, wino, wina in _missing if wino or wina})
                    _wino_norms = list({w.replace('-', '').strip() for w, _ in _pairs if w})
                    _norm_result: dict = {}
                    _wino_only_result: dict = {}
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
                            _val = (_row['zpcode'] or '', _row['zpkcode'] or '')
                            if _nk not in _norm_result:
                                _norm_result[_nk] = _val
                                _hit += 1
                            if _row['wino_n'] not in _wino_only_result:
                                _wino_only_result[_row['wino_n']] = _val
                        _cc.close()
                    logger.info(f"[통시/공대 보완] missing={len(_missing)} pairs={len(_pairs)} hit={_hit}")
                    for _i, _wino, _wina in _missing:
                        _wino_n = _wino.replace('-', '').strip()
                        _v = (_norm_result.get((_wino_n, _wina.strip()))
                              or _wino_only_result.get(_wino_n))
                        if _v:
                            items[_i]['통시'] = _v[0]
                            items[_i]['공대'] = _v[1]
            except Exception as _e:
                logger.warning(f"[통시/공대 보완] cert lookup 실패: {_e}")

        zpcodes = list({(it.get('통시') or '').strip() for it in items if (it.get('통시') or '').strip()})
        zpwinos = list({(it.get('허가번호') or '').replace('-', '').strip() for it in items if it.get('허가번호')})
        zpprac1_by_zpcode: dict = {}
        zpprac1_by_zpwino: dict = {}
        if zpcodes or zpwinos:
            cert_db = _cert_cache_mod._cert_cache_db_path or os.path.join(_tempfile.gettempdir(), "cert_cache.db")
            if cert_db and os.path.exists(cert_db):
                try:
                    cc = sqlite3.connect(cert_db, timeout=10)
                    cc.row_factory = sqlite3.Row
                    if zpcodes:
                        ph = ','.join('?' * len(zpcodes))
                        for row in cc.execute(
                            f"SELECT TRIM(zpcode) AS zpcode, zpprac1 FROM cert "
                            f"WHERE TRIM(zpcode) IN ({ph}) AND zpprac1 != ''",
                            zpcodes
                        ):
                            if row['zpcode']:
                                zpprac1_by_zpcode[row['zpcode']] = row['zpprac1'] or ''
                    if zpwinos:
                        ph2 = ','.join('?' * len(zpwinos))
                        for row in cc.execute(
                            f"SELECT REPLACE(TRIM(zpwino), '-', '') AS zpwino, zpprac1 FROM cert "
                            f"WHERE REPLACE(TRIM(zpwino), '-', '') IN ({ph2}) AND zpprac1 != ''",
                            zpwinos
                        ):
                            if row['zpwino'] and row['zpwino'] not in zpprac1_by_zpwino:
                                zpprac1_by_zpwino[row['zpwino']] = row['zpprac1'] or ''
                    cc.close()
                    logger.info(
                        f"[zpprac1] zpcodes={len(zpcodes)} hit_zpcode={len(zpprac1_by_zpcode)} "
                        f"zpwinos={len(zpwinos)} hit_zpwino={len(zpprac1_by_zpwino)}"
                    )
                except Exception as _ze:
                    logger.warning(f"[zpprac1] lookup 실패: {_ze}")
        for it in items:
            tongsi = (it.get('통시') or '').strip()
            zpw = (it.get('허가번호') or '').replace('-', '').strip()
            it['zpprac1'] = zpprac1_by_zpcode.get(tongsi) or zpprac1_by_zpwino.get(zpw, '')
        return total, items
    total, items = await asyncio.to_thread(_read)
    return {"items": items, "total": total, "page": req.page, "page_size": req.page_size}

class InspectionExportReq(BaseModel):
    year: int
    sheet: str = "all"
    filters: dict = {}
    search: str = ""
    addr: str = ""

@router.post("/inspection/export-xlsx")
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

    access_list = [v for v in (req.filters or {}).get('access담당', []) if v]
    team_list = [v for v in (req.filters or {}).get('품질개선팀', []) if v]

    def _build():
        import openpyxl
        from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row

        target_rows = c.execute(f'SELECT * FROM inspection_targets WHERE {where_sql} ORDER BY id', params).fetchall()

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

        ws1 = wb.active
        ws1.title = '수검대상'
        _write_sheet(ws1, TARGET_HEADERS, target_rows, fills['수검대상'])

        ws2 = wb.create_sheet('수검일정')
        _write_sheet(ws2, SCHEDULE_HEADERS, sched_rows, fills['수검일정'])

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

@router.post("/inspection/export-all-xlsx")
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

@router.post("/inspection/summary")
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

@router.get("/inspection/detail")
async def inspection_detail(request: Request, year: int, 허가번호: str):
    """행 클릭 상세 정보 (KCA + DS + 일정 + 결과)."""
    await _verify_auth(request)
    import sqlite3

    target = None
    if os.path.exists(_INSP_DB):
        conn = sqlite3.connect(_INSP_DB, timeout=60); conn.row_factory = sqlite3.Row
        row = conn.execute('SELECT * FROM inspection_targets WHERE year=? AND 허가번호=? LIMIT 1',
                           (year, 허가번호)).fetchone()
        conn.close()
        if row: target = dict(row)

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

    callname_list: list = []
    zpprac1_val: str = ''
    _cert_db_path = _cert_cache_mod._cert_cache_db_path
    if _cert_db_path and os.path.exists(_cert_db_path):
        def _read_zpcname():
            import sqlite3 as _sq
            c = _sq.connect(_cert_db_path); c.row_factory = _sq.Row
            rows = c.execute(
                "SELECT eqp_ser_no, zpcname FROM cert WHERE zpwino=? AND zpcname!=''",
                (허가번호,)
            ).fetchall()
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

@router.patch("/inspection/target-review")
async def inspection_target_review(request: Request, year: int, 허가번호: str, 시기조정: str = ""):
    """수검 검토 결과(시기조정) 업데이트 — admin/manager 만 허용."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")
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
    """일정 등록된 국소 1건 지오코딩."""
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
        if lat and lat != 0:
            conn.close(); return
        addr = (road_addr or '').strip() or (install_addr or '').strip()
        if not addr:
            conn.close(); return
        r = _req.get(
            'https://dapi.kakao.com/v2/local/search/address.json',
            params={'query': addr, 'size': 1},
            headers={'Authorization': f'KakaoAK {KAKAO_REST_KEY}'},
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
# 워크플로우 상태 머신
# ============================================================

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

_WF_TRANSITIONS = {
    None: {WF_REGISTERED},
    WF_REGISTERED: {WF_PRE_CHECK, WF_REPORT_ISSUED},
    WF_PRE_CHECK: {WF_PRE_CHECK_DONE, WF_CHANGE_FILING},
    WF_CHANGE_FILING: {WF_RE_CHECK},
    WF_RE_CHECK: {WF_PRE_CHECK_DONE},
    WF_PRE_CHECK_DONE: {WF_REPORT_ISSUED},
    WF_REPORT_ISSUED: {WF_SUBMITTED},
    WF_SUBMITTED: {WF_INSPECTED},
    WF_INSPECTED: set(),
}


def _wf_can_transition(from_status, to_status: str, role: str) -> bool:
    if to_status not in WF_VALID:
        return False
    if role == "admin":
        return True
    allowed = _WF_TRANSITIONS.get(from_status, set())
    return to_status in allowed


def _wf_record_log_sync(conn, schedule_pk: str, from_status, to_status: str,
                        changed_by: str, memo: str = ""):
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        'INSERT INTO inspection_status_log(schedule_pk, from_status, to_status, '
        'changed_by, changed_at, memo) VALUES (?,?,?,?,?,?)',
        (schedule_pk, from_status, to_status, changed_by, now, memo))
    try:
        _wf_notify_transition_sync(conn, schedule_pk, from_status, to_status, changed_by)
    except Exception as e:
        logger.error(f"알림 생성 실패 (schedule={schedule_pk}, to={to_status}): {e}")


_SLA_DAYS = {
    WF_PRE_CHECK: 5,
    WF_CHANGE_FILING: 3,
    WF_RE_CHECK: 7,
    WF_REPORT_ISSUED: 3,
    WF_SUBMITTED: 14,
}


def _create_notification_sync(conn, user_id: str, sub_type: str, message: str,
                               schedule_pk: str = "", meta=None, title: str = ""):
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
        _ = meta_json
        c2.commit(); c2.close()
    except Exception as e:
        logger.error(f"워크플로우 알림 INSERT 실패: {e}")


def _notify_targets_for_sync(access담당: str, 품질개선팀: str, target_team: str) -> list:
    if not access담당:
        return []
    try:
        all_users = _list_all_users_sync()
    except Exception as e:
        logger.error(f"수신자 조회 실패 (전체 사용자 캐시): {e}")
        return []

    def _norm_region(r) -> str:
        return (r or '').replace('Access담당', '').strip()

    targets = set()
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


def _wf_notify_transition_sync(conn, schedule_pk: str, from_status,
                               to_status: str, changed_by: str):
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
    recipients.discard(changed_by)
    if not recipients:
        logger.info(f"알림 수신자 없음 (schedule={schedule_pk}, to={to_status}, "
                   f"team={target_team}, access={sched['access담당']}, 품개팀={sched['품질개선팀']})")
        return
    for uid in recipients:
        _create_notification_sync(conn, uid, sub_type, message,
                                  schedule_pk=schedule_pk, meta=meta, title=title)


def _wf_transition_sync(schedule_pk: str, to_status: str, changed_by: str,
                        role: str, memo: str = "") -> tuple:
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
    schedule_pks: list = []
    to_status: str
    memo: str = ""


@router.patch("/inspection/schedule/{pk:path}/status")
async def inspection_schedule_transition(pk: str, request: Request, req: WfTransitionReq):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    ok, msg = await asyncio.to_thread(
        _wf_transition_sync, pk, req.to_status, empno, role, req.memo)
    if not ok:
        raise HTTPException(400, msg)
    await asyncio.to_thread(_record_audit_log_sync,
                            "wf_transition", "inspection_schedule", pk, empno)
    return {"success": True}


@router.post("/inspection/schedule/transition-bulk")
async def inspection_schedule_transition_bulk(request: Request, req: WfBulkTransitionReq):
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


@router.get("/inspection/schedule/{pk:path}/log")
async def inspection_schedule_log(pk: str, request: Request):
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


@router.get("/inspection/notifications")
async def wf_notifications_list(request: Request, unread_only: bool = False, limit: int = 50):
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


@router.get("/inspection/notifications/unread-count")
async def wf_notifications_unread_count(request: Request):
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
    ids: list = []


@router.post("/inspection/notifications/mark-read")
async def wf_notifications_mark_read(request: Request, req: WfNotificationReadReq):
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


@router.get("/inspection/dashboard")
async def inspection_dashboard(request: Request, year: int):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

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
        else:
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

        counts = {
            'PRE_CHECKED': 0,
            'REGISTERED': 0, 'PRE_CHECK': 0, 'PRE_CHECK_DONE': 0,
            'CHANGE_FILING': 0, 'RE_CHECK': 0,
            'REPORT_ISSUED': 0, 'SUBMITTED': 0, 'INSPECTED': 0,
        }
        recheck = 0
        overdue: list = []
        now = datetime.now(timezone.utc)
        for r in rows:
            st = (r['workflow_status'] or 'REGISTERED')
            if st in counts:
                counts[st] += 1
            if (r['needs_recheck'] or '0') == '1':
                recheck += 1
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

        t_wheres = ["t.pre_check_status='PRE_CHECKED'",
                    "REPLACE(t.허가번호,'-','') NOT IN "
                    "(SELECT REPLACE(허가번호,'-','') FROM inspection_schedules WHERE year=?)"]
        t_params: list = [year]
        if role != "admin" and access_team:
            t_wheres.append('t.access담당=?')
            t_params.append(access_team)
        if role == "member" and 품질팀:
            t_wheres.append('t.품질개선팀=?')
            t_params.append(품질팀)
        t_sel = ('SELECT COUNT(*) as cnt FROM inspection_targets t WHERE '
                 + ' AND '.join(t_wheres))
        counts['PRE_CHECKED'] = c.execute(t_sel, t_params).fetchone()['cnt']

        from datetime import date as _date
        today_str = now.strftime('%Y-%m-%d')
        cutoff_str = (now + timedelta(days=60)).strftime('%Y-%m-%d')
        d_wheres = ["status != '완료'", "시정기한 IS NOT NULL", "시정기한 != ''",
                    "시정기한 <= ?", "시정기한 >= ?"]
        d_params: list = [cutoff_str, today_str]
        if role != "admin" and access_team:
            d_wheres.append("(region LIKE ? OR skt본부 LIKE ?)")
            d_params.extend([f'%{access_team}%', f'%{access_team}%'])
        d_sel = ('SELECT 허가번호, 호출명칭, 시정기한, region, skt본부 '
                 'FROM inadequate_management WHERE ' + ' AND '.join(d_wheres)
                 + ' ORDER BY 시정기한 ASC LIMIT 10')
        d_rows = c.execute(d_sel, d_params).fetchall()
        deadline_items = []
        for dr in d_rows:
            try:
                dl = (_date.fromisoformat(dr['시정기한']) - now.date()).days
            except Exception:
                dl = 999
            deadline_items.append({
                '허가번호': dr['허가번호'] or '',
                '호출명칭': dr['호출명칭'] or '',
                '시정기한': dr['시정기한'],
                'd_left': dl,
                'region': dr['region'] or dr['skt본부'] or '',
            })

        c.close()
        overdue.sort(key=lambda x: x['days_overdue'], reverse=True)
        return {
            'role': role,
            'scope': scope,
            'counts': counts,
            'recheck': recheck,
            'overdue': overdue[:20],
            'overdue_total': len(overdue),
            'deadline_items': deadline_items,
        }

    result = await asyncio.to_thread(_aggregate)
    return result


class PreCheckResultReq(BaseModel):
    summary: dict
    items: list = []
    confirmation_acknowledged: bool = False


@router.post("/inspection/schedule/{pk:path}/pre-check-result")
async def inspection_schedule_pre_check_result(pk: str, request: Request, req: PreCheckResultReq):
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


WF_CHANGE_FIELDS = {"일련번호", "형식검정번호", "설치형태", "설치장소"}
WF_CHANGE_DEVICE_FIELDS = {"일련번호", "형식검정번호"}


class ChangeRequestItem(BaseModel):
    field: str
    before_value: str = ""
    after_value: str
    장치번호: str = ""
    memo: str = ""


class ChangeRequestCreateReq(BaseModel):
    items: list = []


@router.post("/inspection/schedule/{pk:path}/change-request")
async def inspection_change_request_create(pk: str, request: Request, req: ChangeRequestCreateReq):
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


_WF_CHANGE_LABEL = {
    "설치형태": "설치형태 오류정정",
    "설치장소": "(부적합 무선국)\n설치장소 오류정정",
    "일련번호": "송수신장치 변경(공용화 고시 제6조제3항제1호)",
    "형식검정번호": "(불합격 무선국)\n형식검정번호 오류정정",
}

def _wf_format_change_value(field: str, value: str) -> str:
    v = (value or "").strip()
    if field == "설치형태":
        return f"설치형태 : {v}"
    if field == "설치장소":
        return v
    if field == "일련번호":
        return f"일련번호 : {v}"
    if field == "형식검정번호":
        return f"형검 : {v}"
    return v


def _wf_format_license_no(license_no: str) -> str:
    s = (license_no or "").replace("-", "")
    if len(s) >= 12:
        return f"{s[:2]}-{s[2:6]}-{s[6:8]}-{s[8:]}"
    return license_no



# ============================================================
# 수검 일정 / 결과 / 사진 / My-list / 진도율 / 보고서 / 접수
# ============================================================

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
    status: str
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


@router.post("/inspection/schedule")
async def inspection_schedule_upsert(request: Request, req: InspectionScheduleReq):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}: raise HTTPException(403, "권한 없음")
    pk = f"{req.year}#{req.허가번호}"
    now = datetime.now(timezone.utc).isoformat()
    def _write():
        c = sqlite3.connect(_INSP_DB, timeout=60)
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
        c.execute('''INSERT OR IGNORE INTO inspection_results
            (pk, year, 허가번호, status, 입력자, 입력일시)
            VALUES (?,?,?,?,?,?)''',
            (pk, req.year, req.허가번호, '합격', empno, now))
        if not existed:
            _wf_record_log_sync(c, pk, None, WF_REGISTERED, empno, "일정 등록")
        c.commit(); c.close()
    await asyncio.to_thread(_write)
    await asyncio.to_thread(_record_audit_log_sync, "inspection_schedule_upsert", "inspection_schedule", pk, empno)
    asyncio.create_task(asyncio.to_thread(_geocode_target_sync, req.year, req.허가번호))
    return {"success": True}

@router.delete("/inspection/schedule/{year}/{license_no}")
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

@router.get("/inspection/schedules")
async def inspection_schedules_list(
    request: Request, year: int, access담당: str = "", workflow_status: str = ""
):
    caller, role, allowed = await _check_division_access(request, access담당)
    def _read():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        wheres = ['s.year=?']
        params: list = [year]
        if access담당:
            wheres.append('s.access담당=?')
            params.append(access담당)
        elif role != 'admin' and allowed:
            placeholders = ','.join(['?'] * len(allowed))
            wheres.append(f's.access담당 IN ({placeholders})')
            params.extend(allowed)
        if workflow_status:
            wheres.append('s.workflow_status=?')
            params.append(workflow_status)
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

@router.post("/inspection/result")
async def inspection_result_upsert(request: Request, req: InspectionResultReq):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    pk = f"{req.year}#{req.허가번호}"
    now = datetime.now(timezone.utc).isoformat()

    if role != 'admin':
        def _resolve_target_access() -> str:
            c = sqlite3.connect(_INSP_DB, timeout=10); c.row_factory = sqlite3.Row
            try:
                row = c.execute(
                    'SELECT access담당 FROM inspection_schedules WHERE pk=?', (pk,)).fetchone()
                if row and row['access담당']:
                    return row['access담당']
                row = c.execute(
                    'SELECT access담당 FROM inspection_targets WHERE year=? AND 허가번호=?',
                    (req.year, req.허가번호)).fetchone()
                return (row['access담당'] if row else '') or ''
            finally:
                c.close()
        target_access = await asyncio.to_thread(_resolve_target_access)
        if target_access:
            allowed = await asyncio.to_thread(_caller_allowed_access_list, empno)
            if target_access not in allowed:
                raise HTTPException(403, "본인 본부의 검사 결과만 입력 가능합니다")

    user_info = await asyncio.to_thread(_get_user_info_for_community, empno)
    입력자_name = user_info.get("name", empno)
    needs_recheck = '1' if req.status.strip() not in ('합격', '') else '0'

    def _write():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        existing = c.execute('SELECT 사진S3키 FROM inspection_results WHERE pk=?', (pk,)).fetchone()
        photos_json = existing['사진S3키'] if existing else '[]'
        c.execute('''INSERT OR REPLACE INTO inspection_results
            (pk, year, 허가번호, status, 검사일, 메모, 철탑형태, 사진S3키, 입력자, 입력일시,
             schedule_pk, needs_recheck)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)''',
            (pk, req.year, req.허가번호, req.status, req.검사일,
             req.메모, req.철탑형태, photos_json, 입력자_name, now,
             pk, needs_recheck))
        transitioned = False
        if (req.검사일 or '').strip():
            sched = c.execute(
                'SELECT workflow_status FROM inspection_schedules WHERE pk=?', (pk,)).fetchone()
            if sched:
                cur = sched['workflow_status'] or WF_REGISTERED
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

@router.post("/inspection/station")
async def inspection_station_add(request: Request, req: InspectionStationReq):
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


@router.post("/inspection/result/photo")
async def inspection_result_photo_upload(request: Request, year: int, 허가번호: str,
                                         file: UploadFile = File(...)):
    import json as _j
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    if role != 'admin':
        def _resolve_target_access() -> str:
            c = sqlite3.connect(_INSP_DB, timeout=10); c.row_factory = sqlite3.Row
            pk_ = f"{year}#{허가번호}"
            try:
                row = c.execute('SELECT access담당 FROM inspection_schedules WHERE pk=?', (pk_,)).fetchone()
                if row and row['access담당']:
                    return row['access담당']
                row = c.execute(
                    'SELECT access담당 FROM inspection_targets WHERE year=? AND 허가번호=?',
                    (year, 허가번호)).fetchone()
                return (row['access담당'] if row else '') or ''
            finally:
                c.close()
        target_access = await asyncio.to_thread(_resolve_target_access)
        if target_access:
            allowed = await asyncio.to_thread(_caller_allowed_access_list, empno)
            if target_access not in allowed:
                raise HTTPException(403, "본인 본부 사진만 업로드 가능합니다")

    allowed_ext = {'.jpg', '.jpeg', '.png', '.webp'}
    ext = os.path.splitext(file.filename or "photo.jpg")[1].lower() or ".jpg"
    if ext not in allowed_ext:
        raise HTTPException(400, f"허용되지 않는 형식입니다 ({ext}). jpg/jpeg/png/webp 만 가능.")

    s3_key = f"inspection/photos/{year}/{허가번호}/{uuid.uuid4()}{ext}"
    content = await file.read()
    if len(content) > MAX_PHOTO_SIZE:
        raise HTTPException(400, f"사진 크기가 {MAX_PHOTO_SIZE // (1024*1024)}MB 를 초과합니다")
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

@router.delete("/inspection/result/photo")
async def inspection_result_photo_delete(request: Request, year: int, 허가번호: str, s3_key: str):
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

@router.get("/inspection/result/photo-url")
async def inspection_result_photo_url(request: Request, s3_key: str):
    await _verify_auth(request)
    if not s3_key.startswith("inspection/photos/"): raise HTTPException(400, "허용되지 않은 경로")
    s3 = get_s3_client()
    url = s3.generate_presigned_url('get_object', Params={'Bucket': S3_BUCKET_NAME, 'Key': s3_key}, ExpiresIn=3600)
    return {"url": url}

@router.get("/inspection/result/photo-data")
async def inspection_result_photo_data(request: Request, s3_key: str):
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
        logger.warning(f"inspection 사진 조회 실패: {e}")
        raise HTTPException(404, "사진을 찾을 수 없습니다")

@router.get("/inspection/my-list/weeks")
async def inspection_my_list_weeks(request: Request, year: int, team: str = ""):
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
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND access담당=? AND 품질개선팀=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, access_team, 품질팀)).fetchall()
        elif is_manager and access_team:
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND access담당=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, access_team)).fetchall()
        elif is_dev and access_team and 품질팀:
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND access담당=? AND 품질개선팀=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, access_team, 품질팀)).fetchall()
        elif is_dev and access_team:
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND access담당=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, access_team)).fetchall()
        elif is_dev:
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year,)).fetchall()
        elif access_team and 품질팀:
            rows = c.execute(
                'SELECT DISTINCT 수검예정주차 FROM inspection_schedules WHERE year=? AND access담당=? AND 품질개선팀=? AND 수검예정주차 != "" ORDER BY 수검예정주차',
                (year, access_team, 품질팀)).fetchall()
        elif is_manager and access_team:
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


@router.get("/inspection/my-list")
async def inspection_my_list(request: Request, year: int, week: str = "", team: str = ""):
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

    logger.info(f"my-list: empno={empno}, access_team='{access_team}', 품질팀='{품질팀}', is_dev={is_dev}, is_manager={is_manager}, role={user_role}")

    if not is_dev and not access_team and not 품질팀 and not is_manager:
        return {"items": [], "message": "팀 배정 없음"}

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
            where_parts.append('s.year=? AND s.access담당=? AND s.품질개선팀=?')
            params.extend([year, access_team, 품질팀])
        elif is_manager and access_team:
            where_parts.append('s.year=? AND s.access담당=?')
            params.extend([year, access_team])
        elif is_manager:
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


@router.get("/inspection/progress")
async def inspection_progress(request: Request, year: int):
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB):
        return {"items": []}

    def _query():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        total_rows = c.execute(
            'SELECT access담당, COUNT(*) as cnt FROM inspection_targets WHERE year=? GROUP BY access담당',
            (year,)).fetchall()
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


@router.get("/inspection/progress-by-team")
async def inspection_progress_by_team(request: Request, year: int, region: str):
    """본부 하나의 팀별 진행률 (실적 화면 Map 우측 팀 리스트용).

    팀 목록 소스 (합집합):
    1) inspection_targets.품질개선팀 (year, access담당=region)
    2) inspection_schedules.품질개선팀 (year, access담당=region) — targets에 비어있을 때 폴백
    3) inspection_results_raw.ons팀 (year, region=region) — 완료 카운트와 결합
    """
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB) or not region:
        return {"items": []}

    def _query():
        c = sqlite3.connect(_INSP_DB, timeout=60); c.row_factory = sqlite3.Row
        # 1) targets에서 팀별 total
        target_rows = c.execute(
            'SELECT 품질개선팀, COUNT(*) AS cnt FROM inspection_targets '
            'WHERE year=? AND access담당=? AND 품질개선팀 IS NOT NULL AND 품질개선팀<>"" '
            'GROUP BY 품질개선팀',
            (year, region)
        ).fetchall()
        # 2) schedules에서 팀 목록 (폴백: targets에 팀 정보 없을 수 있음)
        schedule_teams = c.execute(
            'SELECT DISTINCT 품질개선팀 FROM inspection_schedules '
            'WHERE year=? AND access담당=? AND 품질개선팀 IS NOT NULL AND 품질개선팀<>""',
            (year, region)
        ).fetchall()
        # 3) raw에서 ons팀별 완료 카운트
        done_rows = c.execute(
            'SELECT ons팀, COUNT(*) AS cnt FROM inspection_results_raw '
            'WHERE year=? AND region=? AND ons팀 IS NOT NULL AND ons팀<>"" '
            'GROUP BY ons팀',
            (year, region)
        ).fetchall()
        c.close()
        return target_rows, schedule_teams, done_rows

    target_rows, schedule_teams, done_rows = await asyncio.to_thread(_query)
    total_map = {r['품질개선팀']: r['cnt'] for r in target_rows}
    done_map = {r['ons팀']: r['cnt'] for r in done_rows}
    schedule_team_set = {r['품질개선팀'] for r in schedule_teams}
    all_teams = sorted(set(total_map) | set(done_map) | schedule_team_set)
    items = []
    for tm in all_teams:
        total = total_map.get(tm, 0)
        completed = done_map.get(tm, 0)
        items.append({
            "팀": tm,
            "total": total,
            "completed": completed,
            "percent": round(completed / total * 100, 1) if total > 0 else 0.0,
        })
    logger.info(
        f"progress-by-team(year={year}, region={region}): "
        f"targets={len(target_rows)}, schedules={len(schedule_teams)}, "
        f"results={len(done_rows)}, returned={len(items)}"
    )
    return {"items": items}


@router.get("/inspection/progress-by-result")
async def inspection_progress_by_result(request: Request, year: int):
    await _verify_auth(request)
    if not os.path.exists(_INSP_DB):
        return {"total": 0, "completed": 0, "percent": 0.0, "by_hdqt": []}

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
    허가번호_list: list = []
    sheet: str = "all"
    filters: dict = {}
    search: str = ""
    addr: str = ""
    schedule_yn: str = ""
    sheet_title: str = ""

@router.post("/inspection/export-inspection-report")
async def inspection_export_report(request: Request, req: InspectionReportReq):
    await _verify_auth(request)
    if not HAS_OPENPYXL:
        raise HTTPException(503, "openpyxl 미설치")
    if not os.path.exists(_INSP_DB):
        raise HTTPException(404, "수검 데이터 없음")

    def _build():
        import openpyxl
        from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
        from openpyxl.utils import get_column_letter

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

        _raw_nos = [t['허가번호'] for t in targets]
        license_nos = list({n for raw in _raw_nos for n in (raw, raw.replace('-', ''))})
        _norm_to_raw = {}
        for raw in _raw_nos:
            _norm_to_raw[raw] = raw
            _norm_to_raw[raw.replace('-', '')] = raw
        ph = ','.join('?' * len(license_nos))

        ds_장치_map: dict = {}
        ds_안테나_map: dict = {}
        ds_전파_map: dict = {}
        ds_주파수_map: dict = {}
        ds_일반_map: dict = {}

        if os.path.exists(_DS_DETAIL_DB):
            conn_d = sqlite3.connect(_DS_DETAIL_DB); conn_d.row_factory = sqlite3.Row

            def _raw(hn):
                return _norm_to_raw.get(hn, hn)

            rows = conn_d.execute(
                f'SELECT 허가번호, 공용화구분코드명 FROM ds_일반사항 WHERE 허가번호 IN ({ph})',
                license_nos).fetchall()
            for r in rows:
                ds_일반_map[_raw(r['허가번호'])] = dict(r)

            rows = conn_d.execute(
                f'SELECT 허가번호, 장치번호, 기기일련번호, 형식검정번호 FROM ds_장치 WHERE 허가번호 IN ({ph}) ORDER BY 허가번호, CAST(장치번호 AS INTEGER)',
                license_nos).fetchall()
            for r in rows:
                ds_장치_map.setdefault(_raw(r['허가번호']), []).append(dict(r))

            rows = conn_d.execute(
                f'SELECT * FROM ds_안테나 WHERE 허가번호 IN ({ph}) ORDER BY 허가번호, CAST(장치번호 AS INTEGER)',
                license_nos).fetchall()
            for r in rows:
                ds_안테나_map.setdefault(_raw(r['허가번호']), []).append(dict(r))

            rows = conn_d.execute(
                f'SELECT 허가번호, 장치번호, 공중선전력 FROM ds_전파형식 WHERE 허가번호 IN ({ph}) ORDER BY 허가번호, CAST(장치번호 AS INTEGER)',
                license_nos).fetchall()
            for r in rows:
                ds_전파_map.setdefault(_raw(r['허가번호']), []).append(dict(r))

            rows = conn_d.execute(
                f'SELECT 허가번호, 주파수, 송수신구분 FROM ds_주파수 WHERE 허가번호 IN ({ph}) ORDER BY id',
                license_nos).fetchall()
            def _freq_int(v):
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
                if tx_vals and rx_vals and tx_vals == rx_vals:
                    ds_주파수_map[hn] = f"TRX : {','.join(tx_vals)}"
                else:
                    parts = []
                    if tx_vals: parts.append(f"TX : {','.join(tx_vals)}")
                    if rx_vals: parts.append(f"RX : {','.join(rx_vals)}")
                    if len(tx_vals) <= 1 and len(rx_vals) <= 1:
                        ds_주파수_map[hn] = '  '.join(parts)
                    else:
                        ds_주파수_map[hn] = '\n'.join(parts)

            conn_d.close()

        zpcode_by_eqp: dict = {}
        zpcode_by_active: dict = {}
        zpcode_by_name: dict = {}
        zpcode_fallback: dict = {}
        def _norm_serno(v):
            return re.sub(r'[^0-9A-Za-z]', '', str(v or '').upper())
        _cert_cache_db_path = _cert_cache_mod._cert_cache_db_path
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
                if eqp:
                    zpcode_by_eqp[f"{k}|{eqp}"] = code
                    eqp_norm = _norm_serno(eqp)
                    if eqp_norm:
                        zpcode_by_eqp[f"{k}|{eqp_norm}"] = code
                if '운용' in status and k not in zpcode_by_active:
                    zpcode_by_active[k] = code
                zpcode_by_name[f"{k}|{name}"] = code
                if k not in zpcode_fallback:
                    zpcode_fallback[k] = code
            c2.close()

        wb = openpyxl.Workbook()
        ws = wb.active
        sheet_title = req.sheet_title or f"{req.year}년_검사내역서"
        ws.title = sheet_title[:31]

        _font_base = Font(name='맑은 고딕', size=11)
        _font_base10 = Font(name='맑은 고딕', size=10)
        _font_bold = Font(name='맑은 고딕', size=9, bold=True)
        _font_title = Font(name='맑은 고딕', size=18, bold=True)
        _font_red   = Font(name='맑은 고딕', size=11, color='FFFF0000')

        _fill_yellow  = PatternFill('solid', fgColor='FFFFFF00')
        _fill_hdr_lt  = PatternFill('solid', fgColor='FFBFBFBF')
        _fill_none    = PatternFill(fill_type=None)

        _thin_side = Side(style='thin')
        _thin_border = Border(left=_thin_side, right=_thin_side,
                              top=_thin_side, bottom=_thin_side)
        _med_side  = Side(style='medium')
        _med_border = Border(left=_med_side, right=_med_side,
                             top=_med_side, bottom=_med_side)

        _al_center = Alignment(horizontal='center', vertical='center', wrap_text=True)
        _al_left   = Alignment(horizontal='left',   vertical='center', wrap_text=True)
        _al_shrink = Alignment(horizontal='center', vertical='center', wrap_text=False, shrink_to_fit=True)

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

        ws.row_dimensions[1].height = 39.95
        ws.merge_cells('A1:T1')
        _set(1, 1, '검사신청 접수',
             font=_font_title, align=_al_center, border=_med_border)

        ws.row_dimensions[2].height = 16.5
        ws.row_dimensions[3].height = 16.5

        _HDR_FONT = Font(name='맑은 고딕', size=9, bold=True)
        _HDR_FILL = PatternFill('solid', fgColor='BFBFBF')

        for _r in (2, 3):
            for _c in range(1, 21):
                _cell = ws.cell(row=_r, column=_c)
                _cell.font = _HDR_FONT
                _cell.fill = _HDR_FILL
                _cell.border = _thin_border
                _cell.alignment = _al_center

        def _hdr(r, c, val):
            _set(r, c, val, font=_HDR_FONT, fill=_HDR_FILL,
                 border=_thin_border, align=_al_center)

        for col, label in [(1,'순번'),(2,'(허가자료)\n설치형태'),(3,'tosi_code'),
                           (4,'허가번호'),(5,'name'),(6,'검사종류'),
                           (7,'특이사항'),(11,'공중선전력'),(12,'허가주파수\n(채널)'),
                           (17,'공용화/환경친화'),(18,'수수료'),(19,'검사지'),
                           (20,'설치장소')]:
            ws.merge_cells(start_row=2, start_column=col, end_row=3, end_column=col)
            _hdr(2, col, label)

        ws.merge_cells('H2:J2'); _hdr(2, 8, '장치사항')
        for col, lbl in [(8,'장치수'),(9,'기기명칭1'),(10,'기기일련번호1')]:
            _hdr(3, col, lbl)

        ws.merge_cells('M2:P2'); _hdr(2, 13, '공중선')
        for col, lbl in [(13,'장치'),(14,'형식'),(15,'기수'),(16,'이득')]:
            _hdr(3, col, lbl)

        def _fmt_hn(hn_raw):
            hn = str(hn_raw or '').replace('-', '')
            if len(hn) == 15:
                return f"{hn[:2]}-{hn[2:6]}-{hn[6:8]}-{hn[8:]}"
            return hn_raw

        _LINE_HEIGHT = 13.5
        max_tosi_line_len = 0
        for seq, t in enumerate(targets, 1):
            r = seq + 3
            hn = t['허가번호']
            hn_norm = str(hn or '').replace('-', '')

            jt_list  = ds_장치_map.get(hn, [])
            ant_list = ds_안테나_map.get(hn, [])
            pwr_list = ds_전파_map.get(hn, [])
            freq     = ds_주파수_map.get(hn, '')
            일반     = ds_일반_map.get(hn, {})

            def _join_unique(lst, key):
                seen = set(); result = []
                for row in lst:
                    v = str(row.get(key) or '').strip()
                    if v and v not in seen:
                        seen.add(v); result.append(v)
                return '\n'.join(result)

            def _join_all(lst, key, as_int=False):
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

            장치수 = ''
            if jt_list:
                unique_jnos = set(str(j.get('장치번호') or '').strip() for j in jt_list)
                unique_jnos.discard('')
                장치수 = str(len(unique_jnos)) if unique_jnos else str(len(jt_list))

            _seen_serial: set = set()
            unique_장치: list = []
            for j in jt_list:
                serial = str(j.get('기기일련번호') or '').strip()
                if serial and serial not in _seen_serial:
                    _seen_serial.add(serial)
                    unique_장치.append(j)
                elif not serial:
                    unique_장치.append(j)
            기기명칭1    = _join_all(unique_장치, '형식검정번호')
            기기일련번호1 = _join_unique(unique_장치, '기기일련번호')

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

            _seen_ant: set = set()
            deduped_ant: list = []
            for _ant in ant_list:
                _k = str(_ant.get('공중선일련번호') or '').strip()
                if not _k or _k not in _seen_ant:
                    _seen_ant.add(_k); deduped_ant.append(_ant)

            _callname = str(t['호출명칭'] or '').strip()
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

            설치장소 = t['설치장소'] or ''

            검사지 = ''
            _addr_for_area = 설치장소 or t.get('도로명주소') or ''
            _addr_parts = _addr_for_area.split()
            if len(_addr_parts) >= 2:
                검사지 = _addr_parts[1]

            row_data = [
                seq, 설치형태, tosi_code, _fmt_hn(hn),
                t['호출명칭'] or '', '정기', '',
                장치수, 기기명칭1, 기기일련번호1,
                공중선전력, freq,
                공중선장치, 공중선형식, 기수, 이득,
                공용화, '', 검사지, 설치장소,
            ]
            max_lines = 1
            for _v in row_data:
                if isinstance(_v, str) and '\n' in _v:
                    _lc = _v.count('\n') + 1
                    if _lc > max_lines:
                        max_lines = _lc
            ws.row_dimensions[r].height = _LINE_HEIGHT * max_lines

            for c_idx, val in enumerate(row_data, 1):
                if c_idx == 2:
                    _set(r, c_idx, val, font=_font_red, fill=_fill_yellow,
                         border=_thin_border, align=_al_shrink)
                elif c_idx == 3:
                    _set(r, c_idx, val, font=_font_base10,
                         border=_thin_border, align=_al_center)
                elif c_idx in (7, 20):
                    _set(r, c_idx, val, font=_font_base,
                         border=_thin_border, align=_al_left)
                elif c_idx in (9, 10):
                    _set(r, c_idx, val, font=_font_base10,
                         border=_thin_border, align=_al_center)
                else:
                    _set(r, c_idx, val, font=_font_base,
                         border=_thin_border, align=_al_center)

        if max_tosi_line_len > 0:
            ws.column_dimensions['C'].width = max(9.0, min(22.0, max_tosi_line_len * 1.1 + 1.5))

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


class InspectionReportGenerateReq(BaseModel):
    schedule_pks: list = []
    sheet_title: str = ""


@router.post("/inspection/report/generate")
async def inspection_report_generate(request: Request, req: InspectionReportGenerateReq):
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

    years = {s['year'] for s in scheds}
    if len(years) > 1:
        raise HTTPException(400, f"여러 연도 혼합 불가: {sorted(years)}")
    year = scheds[0]['year']
    허가번호_list = [s['허가번호'] for s in scheds]

    inner_req = InspectionReportReq(
        year=year,
        허가번호_list=허가번호_list,
        sheet_title=req.sheet_title,
    )
    response = await inspection_export_report(request, inner_req)

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
    submitted_at: str = ""


@router.patch("/inspection/schedule/{pk:path}/submission")
async def inspection_schedule_submission(pk: str, request: Request, req: InspectionSubmissionReq):
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
    schedule_pks: list = []
    submission_no: str
    submitted_at: str = ""


@router.post("/inspection/schedule/submission-bulk")
async def inspection_schedule_submission_bulk(request: Request, req: InspectionSubmissionBulkReq):
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


@router.post("/inspection/add-from-staging")
async def inspection_add_from_staging(request: Request, req: InspAddFromStagingReq):
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    if not os.path.exists(_INSP_DB):
        raise HTTPException(400, "DB 없음")

    manager_access = ""
    if role == "manager":
        dynamodb = get_dynamodb_resource()
        users_table = dynamodb.Table(DYNAMODB_TABLES["users"])
        user_item = await asyncio.to_thread(lambda: users_table.get_item(
            Key={"user_id": empno},
            ProjectionExpression="#r",
            ExpressionAttributeNames={"#r": "region"},
        ))
        manager_access = user_item.get("Item", {}).get("region", "").replace("Access담당", "").strip()
        if not manager_access:
            raise HTTPException(403, "본부 정보가 설정되지 않았습니다")

    def _do_add():
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        conn.row_factory = sqlite3.Row
        try:
            row = conn.execute(
                'SELECT * FROM inspection_targets_staging WHERE year=? AND 허가번호=? LIMIT 1',
                (req.year, req.허가번호)
            ).fetchone()
            if not row:
                raise ValueError(f"스테이징에서 찾을 수 없습니다: {req.허가번호}")

            d = dict(row)

            if manager_access and d.get("access담당", "") != manager_access:
                raise PermissionError(f"본부 불일치: 대상={d.get('access담당')}, 내 본부={manager_access}")

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
                '대상 추가',
                d.get('시기조정'), d.get('기준연도'), d.get('skt본부'),
                d.get('access담당'), d.get('품질개선팀'), d.get('검사종류'),
            )
            conn.execute(f'INSERT INTO inspection_targets ({cols}) VALUES ({ph})', vals)
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
