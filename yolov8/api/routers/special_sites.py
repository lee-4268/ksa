"""
special_sites - 특이국소 관리 (지하철/터널/야간출입 등)

담당 도메인: 특이사항 국소 등록/조회 — 일정 계획 시 참고용
주요 의존성: core.auth, core.config (inspection.db)
엔드포인트:
    GET  /special-sites          전체 목록 (+대상 정보 join)
    POST /special-sites/resolve  허가번호 목록 → 전체 대상(targets∪staging) 매칭 미리보기
    POST /special-sites/bulk     일괄 등록/수정 (admin/manager)
    POST /special-sites/delete   일괄 삭제 (admin/manager)
"""

import asyncio
import logging
import re
import sqlite3
from datetime import datetime, timezone

from fastapi import APIRouter, HTTPException, Request

from core.auth import (
    _verify_auth, _require_role, _get_user_role_sync, _caller_allowed_access_list,
)
from core.config import _INSP_DB
from schemas.models import SpecialSiteBulkReq, SpecialSiteLicensesReq

router = APIRouter(tags=["special-sites"])
logger = logging.getLogger(__name__)

VALID_SPECIAL_TYPES = ('지하철', '터널', '야간출입', '기타')


def _norm_license(v: str) -> str:
    return re.sub(r'[\s\-]', '', str(v or ''))


async def _require_manager_scope(request: Request):
    """admin/manager 게이트 + 본부 격리 범위 반환.

    반환: (empno, allowed) — allowed None = 무제약(admin),
    리스트 = manager 본인 본부의 access담당 값 목록 (일정 upsert와 동일 정책).
    """
    empno = await _require_role(request, {"admin", "manager"})
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role == 'admin':
        return empno, None
    allowed = await asyncio.to_thread(_caller_allowed_access_list, empno)
    return empno, allowed


def _split_by_access(matched: list[dict], allowed: list[str] | None):
    """resolve 결과를 (허용, 타본부 거부) 로 분리. allowed None 이면 전부 허용."""
    if allowed is None:
        return matched, []
    ok, denied = [], []
    for m in matched:
        if (m.get('access담당') or '') in allowed:
            ok.append(m)
        else:
            denied.append(m)
    return ok, denied


def _resolve_targets_sync(licenses: list[str]) -> dict:
    """허가번호 목록을 전체 수검 대상(targets ∪ staging)에서 조회.

    확정 시 staging 에서 삭제되므로 두 테이블은 서로소 — UNION 이 KCA Import 전체.
    같은 허가번호가 여러 연도에 있으면 최신 연도 행을 채택.
    """
    clean = [c for c in ({_norm_license(x) for x in licenses}) if c]
    if not clean:
        return {"matched": [], "not_found": []}
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    conn.row_factory = sqlite3.Row
    try:
        ph = ','.join('?' * len(clean))
        rows = conn.execute(
            f'''SELECT 허가번호, 호출명칭, 설치장소, skt본부, access담당, 품질개선팀, year
                FROM inspection_targets WHERE 허가번호 IN ({ph})
                UNION ALL
                SELECT 허가번호, 호출명칭, 설치장소, skt본부, access담당, 품질개선팀, year
                FROM inspection_targets_staging WHERE 허가번호 IN ({ph})''',
            clean + clean,
        ).fetchall()
    finally:
        conn.close()
    best: dict[str, dict] = {}
    for r in rows:
        d = dict(r)
        no = d['허가번호']
        if no not in best or (d.get('year') or 0) > (best[no].get('year') or 0):
            best[no] = d
    matched = list(best.values())
    not_found = [c for c in clean if c not in best]
    return {"matched": matched, "not_found": not_found}


def _list_special_sites_sync() -> list[dict]:
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            'SELECT 허가번호, 유형, 메모, 등록자, 등록일시 FROM special_sites ORDER BY 등록일시 DESC'
        ).fetchall()
    finally:
        conn.close()
    items = [dict(r) for r in rows]
    if items:
        info = _resolve_targets_sync([it['허가번호'] for it in items])
        info_map = {m['허가번호']: m for m in info['matched']}
        for it in items:
            m = info_map.get(it['허가번호'], {})
            it['호출명칭'] = m.get('호출명칭') or ''
            it['설치장소'] = m.get('설치장소') or ''
            it['skt본부'] = m.get('skt본부') or ''
            it['access담당'] = m.get('access담당') or ''
            it['품질개선팀'] = m.get('품질개선팀') or ''
    return items


@router.get("/special-sites")
async def list_special_sites(request: Request):
    """특이국소 전체 목록. 일정 화면 배경색 표시용으로 모든 로그인 사용자 조회 가능."""
    await _verify_auth(request)
    items = await asyncio.to_thread(_list_special_sites_sync)
    return {"success": True, "items": items, "total": len(items)}


@router.post("/special-sites/resolve")
async def resolve_special_sites(req: SpecialSiteLicensesReq, request: Request):
    """등록 전 미리보기 — 허가번호가 전체 대상(targets∪staging)에 있는지 확인.

    manager 는 본인 본부 대상만 허용 — 타본부 건은 denied 로 분리 반환.
    """
    _, allowed = await _require_manager_scope(request)
    if not req.licenses:
        raise HTTPException(400, "허가번호를 입력하세요")
    if len(req.licenses) > 1000:
        raise HTTPException(400, "한 번에 최대 1000건까지 조회 가능합니다")
    result = await asyncio.to_thread(_resolve_targets_sync, req.licenses)
    ok, denied = _split_by_access(result['matched'], allowed)
    return {"success": True, "matched": ok, "denied": denied,
            "not_found": result['not_found']}


@router.post("/special-sites/bulk")
async def bulk_register_special_sites(req: SpecialSiteBulkReq, request: Request):
    """특이국소 일괄 등록 — 이미 등록된 허가번호는 유형/메모 갱신(upsert).

    manager 는 본인 본부 대상만 등록 가능 (타본부 건은 denied 로 제외).
    """
    empno, allowed = await _require_manager_scope(request)
    if req.유형 not in VALID_SPECIAL_TYPES:
        raise HTTPException(400, f"유효하지 않은 유형: {req.유형} (가능: {', '.join(VALID_SPECIAL_TYPES)})")
    if not req.licenses:
        raise HTTPException(400, "허가번호를 입력하세요")
    if len(req.licenses) > 1000:
        raise HTTPException(400, "한 번에 최대 1000건까지 등록 가능합니다")

    resolved = await asyncio.to_thread(_resolve_targets_sync, req.licenses)
    ok, denied = _split_by_access(resolved['matched'], allowed)
    matched_nos = [m['허가번호'] for m in ok]
    if not matched_nos:
        if denied:
            raise HTTPException(403, "본인 본부의 대상만 등록할 수 있습니다")
        raise HTTPException(400, "전체 수검 대상에서 일치하는 허가번호가 없습니다")

    now = datetime.now(timezone.utc).isoformat()

    def _insert():
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            conn.executemany(
                '''INSERT INTO special_sites (허가번호, 유형, 메모, 등록자, 등록일시)
                   VALUES (?, ?, ?, ?, ?)
                   ON CONFLICT(허가번호) DO UPDATE SET
                     유형=excluded.유형, 메모=excluded.메모,
                     등록자=excluded.등록자, 등록일시=excluded.등록일시''',
                [(no, req.유형, req.메모, empno, now) for no in matched_nos],
            )
            conn.commit()
        finally:
            conn.close()

    await asyncio.to_thread(_insert)
    logger.info(f"특이국소 일괄 등록: {len(matched_nos)}건 ({req.유형}) by {empno}"
                + (f", 타본부 제외 {len(denied)}건" if denied else ""))
    return {
        "success": True,
        "registered": len(matched_nos),
        "denied": [m['허가번호'] for m in denied],
        "not_found": resolved['not_found'],
    }


@router.post("/special-sites/delete")
async def delete_special_sites(req: SpecialSiteLicensesReq, request: Request):
    """특이국소 일괄 삭제 — manager 는 본인 본부 대상만."""
    empno, allowed = await _require_manager_scope(request)
    clean = [c for c in ({_norm_license(x) for x in req.licenses}) if c]
    if not clean:
        raise HTTPException(400, "허가번호를 입력하세요")

    denied_count = 0
    if allowed is not None:
        # manager: 대상의 access담당으로 본부 확인 — 본인 본부 건만 삭제 허용.
        # 대상 테이블에서 확인 불가한 허가번호(과년도 제외 등)도 안전하게 거부.
        resolved = await asyncio.to_thread(_resolve_targets_sync, clean)
        ok, denied = _split_by_access(resolved['matched'], allowed)
        ok_nos = {m['허가번호'] for m in ok}
        denied_count = len(clean) - len(ok_nos)
        clean = [c for c in clean if c in ok_nos]
        if not clean:
            raise HTTPException(403, "본인 본부의 대상만 삭제할 수 있습니다")

    def _delete():
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            ph = ','.join('?' * len(clean))
            cur = conn.execute(f'DELETE FROM special_sites WHERE 허가번호 IN ({ph})', clean)
            conn.commit()
            return cur.rowcount
        finally:
            conn.close()

    deleted = await asyncio.to_thread(_delete)
    logger.info(f"특이국소 삭제: {deleted}건 by {empno}"
                + (f", 타본부 거부 {denied_count}건" if denied_count else ""))
    return {"success": True, "deleted": deleted, "denied": denied_count}
