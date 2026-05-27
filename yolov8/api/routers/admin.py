"""
admin - 관리자 전용 엔드포인트

담당 도메인: 메뉴 사용 로그
주요 의존성: core.auth, core.config
엔드포인트:
    POST /admin/menu-log
    GET  /admin/menu-stats

(시설점검 사진(sisl) 엔드포인트는 routers/sisl_photos.py 로 분리됨)
"""

import asyncio
import logging
import sqlite3
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, HTTPException, Query, Request

from core.auth import (
    _verify_auth, _get_user_role_sync, _get_user_info_for_community,
)
from core.config import _INSP_DB

router = APIRouter(tags=["admin"])
logger = logging.getLogger(__name__)


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
