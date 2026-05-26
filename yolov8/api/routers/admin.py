"""
admin - 관리자 전용 엔드포인트

담당 도메인: 메뉴 사용 로그, sisl 사진 임포트
주요 의존성: core.auth, core.config
엔드포인트:
    POST /admin/menu-log
    GET  /admin/menu-stats
    POST /admin/sisl-photos/import
    GET  /sisl-photos
    GET  /sisl-photos/stats
"""

import asyncio
import io
import logging
import os
import re
import sqlite3
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, File, HTTPException, Query, Request, UploadFile

from core.auth import (
    _verify_auth, _get_user_role_sync, _get_user_info_for_community,
    _record_audit_log_sync,
)
from core.config import _INSP_DB, _SISL_PHOTO_DB
from core.db import get_s3_client

router = APIRouter(tags=["admin"])
logger = logging.getLogger(__name__)

_SISL_PHOTO_BASE_URL = os.environ.get(
    "SISL_PHOTO_BASE_URL", "https://static-int.skons.co.kr/SKO-OCEAN"
)
_SISL_DEFAULT_YEARS_BACK = 3


def _build_sisl_photo_url(file_path: str, guid: str) -> str:
    """엑셀의 FilePath + Guid 를 URL 로 조립."""
    path = (file_path or '').replace('\\', '/').strip('/')
    base = _SISL_PHOTO_BASE_URL.rstrip('/')
    return f"{base}/{path}/{guid}"


def _sisl_upload_date_cutoff(years_back: int) -> int:
    """현재일에서 years_back 년 전을 YYYYMMDD 정수로 반환."""
    if years_back <= 0:
        return 0
    KST = timezone(timedelta(hours=9))
    cutoff = datetime.now(KST) - timedelta(days=365 * years_back)
    return int(cutoff.strftime("%Y%m%d"))


@router.post("/admin/menu-log")
async def admin_menu_log(request: Request):
    """메뉴 접속 로그 기록."""
    empno = await _verify_auth(request)
    body = await request.json()
    menu_name = body.get("menu", "")
    if not menu_name:
        return {"ok": True}
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


@router.get("/admin/menu-stats")
async def admin_menu_stats(request: Request, days: int = Query(30)):
    """메뉴 사용 통계 (admin 전용)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role != "admin":
        raise HTTPException(403, "관리자만 조회 가능")
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()

    def _stats():
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        conn.row_factory = sqlite3.Row
        menu_counts = conn.execute(
            "SELECT menu_name, COUNT(*) as cnt FROM menu_usage_log "
            "WHERE accessed_at >= ? GROUP BY menu_name ORDER BY cnt DESC",
            (cutoff,),
        ).fetchall()
        user_counts = conn.execute(
            "SELECT user_id, user_name, COUNT(*) as cnt FROM menu_usage_log "
            "WHERE accessed_at >= ? GROUP BY user_id ORDER BY cnt DESC LIMIT 20",
            (cutoff,),
        ).fetchall()
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


@router.post("/admin/sisl-photos/import")
async def admin_sisl_photos_import(request: Request, file: UploadFile = File(...)):
    """SKO-OCEAN sisl_db 엑셀 임포트 (admin 전용).

    엑셀 컬럼: NeOSCode | UploadDate | RegClsCode | Guid | FilePath
    PRIMARY KEY (neos_code, guid) — 중복은 ON CONFLICT 로 갱신.
    배치 10,000 건 단위로 commit.
    """
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role != "admin":
        raise HTTPException(403, "admin 전용")
    if not file.filename or not file.filename.lower().endswith(('.xlsx', '.xls')):
        raise HTTPException(400, "xlsx/xls 파일만 지원합니다")

    file_bytes = await file.read()
    if not file_bytes:
        raise HTTPException(400, "빈 파일")
    if len(file_bytes) > 200 * 1024 * 1024:
        raise HTTPException(400, "파일 크기 한도(200MB) 초과")

    upload_filename = file.filename
    now_iso = datetime.now(timezone.utc).isoformat()

    def _do_import() -> dict:
        import openpyxl
        wb = openpyxl.load_workbook(io.BytesIO(file_bytes), read_only=True, data_only=True)
        total = 0
        inserted = 0
        skipped = 0
        conn = sqlite3.connect(_SISL_PHOTO_DB, timeout=120)
        try:
            before_count = conn.execute('SELECT COUNT(*) FROM sisl_photo').fetchone()[0]
            batch: list = []
            BATCH_SIZE = 10000

            def _flush():
                nonlocal batch
                if not batch:
                    return
                conn.executemany(
                    '''INSERT INTO sisl_photo(neos_code, guid, reg_cls, file_path, upload_date)
                       VALUES (?, ?, ?, ?, ?)
                       ON CONFLICT(neos_code, guid) DO UPDATE SET
                         reg_cls=excluded.reg_cls,
                         file_path=excluded.file_path,
                         upload_date=excluded.upload_date''',
                    batch,
                )
                conn.commit()
                batch = []

            for ws in wb.worksheets:
                for i, row in enumerate(ws.iter_rows(values_only=True)):
                    if i == 0:
                        continue
                    if row is None or row[0] is None:
                        continue
                    try:
                        neos = str(row[0]).strip()
                        dt = int(row[1]) if row[1] is not None else 0
                        rc = int(row[2]) if row[2] is not None else 0
                        guid = str(row[3]).strip() if row[3] else ''
                        fp = str(row[4]).strip() if row[4] else ''
                        if not (neos and guid and fp):
                            skipped += 1
                            continue
                        batch.append((neos, guid, rc, fp, dt))
                        total += 1
                        if len(batch) >= BATCH_SIZE:
                            _flush()
                    except (ValueError, TypeError):
                        skipped += 1
                        continue
            _flush()
            wb.close()

            after_count = conn.execute('SELECT COUNT(*) FROM sisl_photo').fetchone()[0]
            inserted = max(0, after_count - before_count)
            updated = max(0, total - inserted)

            conn.execute(
                '''INSERT INTO sisl_photo_import_log(imported_at, imported_by, filename, total_rows, inserted, updated)
                   VALUES (?, ?, ?, ?, ?, ?)''',
                (now_iso, empno, upload_filename, total, inserted, updated),
            )
            conn.commit()
        finally:
            conn.close()
        return {"total": total, "inserted": inserted, "updated": max(0, total - inserted), "skipped": skipped}

    result = await asyncio.to_thread(_do_import)
    await asyncio.to_thread(
        _record_audit_log_sync,
        "sisl_photos_import", "sisl_photo",
        f"total={result['total']},inserted={result['inserted']},updated={result['updated']},skipped={result['skipped']}",
        empno,
    )
    return {"success": True, "filename": upload_filename, **result}


@router.get("/sisl-photos")
async def sisl_photos_list(
    request: Request,
    neos_code: str = Query("", description="공대 (NeOSCode) — 빈 값이면 빈 결과"),
    reg_cls: int = Query(0, description="RegClsCode 필터 (0 이면 전체)"),
    years_back: int = Query(_SISL_DEFAULT_YEARS_BACK,
        description="현재일 기준 최근 N년치만 반환 (0 이면 전체). 기본 3."),
    limit: int = Query(500, ge=1, le=2000),
):
    """공대(neos_code) 기준 SKO-OCEAN 사진 메타 조회."""
    await _verify_auth(request)
    neos = (neos_code or '').strip()
    if not neos:
        return {"items": [], "total": 0}
    cutoff = _sisl_upload_date_cutoff(years_back)

    def _read() -> list:
        conn = sqlite3.connect(_SISL_PHOTO_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            wheres = ['neos_code=?']
            params: list = [neos]
            if reg_cls:
                wheres.append('reg_cls=?')
                params.append(reg_cls)
            if cutoff > 0:
                wheres.append('upload_date >= ?')
                params.append(cutoff)
            sql = (
                f"SELECT neos_code, guid, reg_cls, file_path, upload_date "
                f"FROM sisl_photo WHERE {' AND '.join(wheres)} "
                f"ORDER BY upload_date DESC, reg_cls ASC LIMIT ?"
            )
            params.append(limit)
            rows = conn.execute(sql, params).fetchall()
            out = []
            for r in rows:
                d = dict(r)
                d["url"] = _build_sisl_photo_url(d["file_path"], d["guid"])
                out.append(d)
            return out
        finally:
            conn.close()

    items = await asyncio.to_thread(_read)
    return {"items": items, "total": len(items)}


@router.get("/sisl-photos/stats")
async def sisl_photos_stats(request: Request):
    """전체 임포트 통계 (admin/manager)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")

    def _read():
        conn = sqlite3.connect(_SISL_PHOTO_DB, timeout=30)
        conn.row_factory = sqlite3.Row
        try:
            total = conn.execute('SELECT COUNT(*) FROM sisl_photo').fetchone()[0]
            neos_cnt = conn.execute('SELECT COUNT(DISTINCT neos_code) FROM sisl_photo').fetchone()[0]
            date_row = conn.execute(
                'SELECT MIN(upload_date) AS dmin, MAX(upload_date) AS dmax FROM sisl_photo'
            ).fetchone()
            by_rc = conn.execute(
                'SELECT reg_cls, COUNT(*) AS cnt FROM sisl_photo GROUP BY reg_cls ORDER BY cnt DESC'
            ).fetchall()
            recent_imports = conn.execute(
                'SELECT * FROM sisl_photo_import_log ORDER BY id DESC LIMIT 10'
            ).fetchall()
            return {
                "total": total,
                "unique_neos": neos_cnt,
                "date_min": date_row['dmin'] if date_row else None,
                "date_max": date_row['dmax'] if date_row else None,
                "by_reg_cls": [dict(r) for r in by_rc],
                "recent_imports": [dict(r) for r in recent_imports],
            }
        finally:
            conn.close()

    return await asyncio.to_thread(_read)
