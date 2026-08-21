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
import os
import re
import sqlite3
from datetime import datetime, timezone

import hmac as _hmac_mod

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import JSONResponse

from core.auth import (
    _verify_auth, _require_role, _get_user_role_sync, _caller_allowed_access_list,
)
from core.config import _INSP_DB
from schemas.models import (
    SpecialSiteBulkReq, SpecialSiteLicensesReq, SpecialSiteImportReq,
)

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


# ── Playground → ksa 특이국소 수신 (브라우저 릴레이) ──────────
# kca-fe 특이국소 화면의 [ksa로 전송]이 사용자 브라우저에서 직접 POST 한다.
# (서버 간 직통·ksa→kca-be 방향 CORS 는 모두 망 정책/내부 인증 게이트로 불가)
# 인증: X-Sync-Secret — 양쪽 env KSA_SYNC_SECRET 동일값. kca 사용자가 ksa 에
# 로그인돼 있지 않을 수 있어 토큰 대신 시크릿을 쓰고, 본부 범위·role 강제는
# kca-be(sync-data, 세션 인증)가 서버측에서 이미 수행한 상태로 들어온다.
# CORS 는 이 두 라우트에만 수동 개방 (에러 응답에도 헤더 필요 — 브라우저 판독용).
KSA_SYNC_SECRET = os.environ.get("KSA_SYNC_SECRET", "")
KSA_SYNC_ALLOWED_ORIGIN = os.environ.get(
    "KSA_SYNC_ALLOWED_ORIGIN", "https://playground.idcube.sktelecom.com")


def _ingest_cors(extra: dict = None) -> dict:
    return {"Access-Control-Allow-Origin": KSA_SYNC_ALLOWED_ORIGIN,
            "Vary": "Origin", **(extra or {})}


@router.post("/special-sites/sync-ingest")
async def sync_ingest(request: Request):
    """Playground 발 특이국소 수신 — hdqt 범위(또는 전체) 교체.

    브라우저의 CORS 사전요청(preflight)을 피하기 위해 '단순 요청' 규격을 쓴다:
    시크릿은 헤더가 아닌 body 의 secret 필드, Content-Type 은 text/plain 으로
    들어온다 (커스텀 헤더/JSON 타입이면 preflight 가 발생하는데, ksa 전역
    CORSMiddleware 가 그 preflight 를 라우트 도달 전에 400 으로 거절하기 때문).
    따라서 pydantic 대신 raw body 를 직접 파싱한다.
    """
    try:
        data = await request.json()
    except Exception:
        return JSONResponse({"detail": "잘못된 요청 형식"}, status_code=400,
                            headers=_ingest_cors())
    secret = str(data.get("secret") or "")
    if not (KSA_SYNC_SECRET and secret
            and _hmac_mod.compare_digest(secret, KSA_SYNC_SECRET)):
        return JSONResponse({"detail": "unauthorized"}, status_code=401,
                            headers=_ingest_cors())
    try:
        req = SpecialSiteImportReq(
            items=data.get("items") or [],
            hdqt=str(data.get("hdqt") or ""),
            actor=str(data.get("actor") or ""),
        )
    except Exception as e:
        return JSONResponse({"detail": f"항목 형식 오류: {e}"}, status_code=400,
                            headers=_ingest_cors())
    try:
        result = await _do_import(req.items, req.hdqt.strip(),
                                  req.actor or "playground")
    except ValueError as e:
        return JSONResponse({"detail": str(e)}, status_code=400,
                            headers=_ingest_cors())
    logger.info(f"특이국소 sync-ingest: 범위={result['scope']}, "
                f"신규 {result['imported']}/기존 {result['deleted']} by {req.actor or 'playground'}")
    return JSONResponse({"success": True, **result}, headers=_ingest_cors())


async def _do_import(items, hdqt: str, actor: str) -> dict:
    """검증 + (본부 범위/전체) 교체 실행 — import(토큰)·sync-ingest(시크릿) 공용.

    items: SpecialSiteImportItem 목록. 오류는 ValueError 로 던진다.
    허가번호는 ksa 전체 대상(targets∪staging)과 대조하여 매칭 건만 등록,
    원 등록자/등록일시(playground 이력)는 보존.
    """
    if not items and not hdqt:
        raise ValueError("가져올 데이터가 없습니다")
    if len(items) > 10000:
        raise ValueError("한 번에 최대 10,000건까지 가져올 수 있습니다")

    invalid_type = [it.허가번호 for it in items if it.유형 not in VALID_SPECIAL_TYPES]
    valid_items = [it for it in items if it.유형 in VALID_SPECIAL_TYPES]
    if not valid_items and not hdqt:
        raise ValueError(f"유효한 유형이 없습니다 (가능: {', '.join(VALID_SPECIAL_TYPES)})")

    resolved = await asyncio.to_thread(
        _resolve_targets_sync, [it.허가번호 for it in valid_items])
    matched = {m['허가번호']: m for m in resolved['matched']}

    now = datetime.now(timezone.utc).isoformat()
    rows = []
    denied: list = []
    seen: set = set()
    for it in valid_items:
        no = _norm_license(it.허가번호)
        m = matched.get(no)
        if not m or no in seen:
            continue
        # 본부 범위 동기화면 그 본부 대상만 반영 (서버측 재검증)
        if hdqt and not (m.get('access담당') or '').startswith(hdqt):
            denied.append(no)
            continue
        seen.add(no)
        rows.append((no, it.유형, it.메모,
                     it.등록자 or actor, it.등록일시 or now))
    if not rows and not hdqt:
        raise ValueError("전체 수검 대상에서 일치하는 허가번호가 없습니다")

    def _replace():
        conn = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            if hdqt:
                # 본부 범위 교체 — 기존 행 중 해당 본부 소속만 삭제.
                # (본부 판정은 targets∪staging 조회 기준, 미확인 행은 보존)
                ex_nos = [r[0] for r in conn.execute(
                    'SELECT 허가번호 FROM special_sites').fetchall()]
                ex_map = {m['허가번호']: (m.get('access담당') or '')
                          for m in _resolve_targets_sync(ex_nos)['matched']} if ex_nos else {}
                del_nos = [no for no in ex_nos if ex_map.get(no, '').startswith(hdqt)]
                if del_nos:
                    ph = ','.join('?' * len(del_nos))
                    conn.execute(f'DELETE FROM special_sites WHERE 허가번호 IN ({ph})', del_nos)
                deleted = len(del_nos)
            else:
                deleted = conn.execute('SELECT COUNT(*) FROM special_sites').fetchone()[0]
                conn.execute('DELETE FROM special_sites')
            if rows:
                conn.executemany(
                    'INSERT INTO special_sites (허가번호, 유형, 메모, 등록자, 등록일시) '
                    'VALUES (?, ?, ?, ?, ?)', rows)
            conn.commit()
            return deleted
        finally:
            conn.close()

    deleted = await asyncio.to_thread(_replace)
    logger.info(f"특이국소 import: 범위={hdqt or '전체'}, 신규 {len(rows)}건/기존 {deleted}건 교체 "
                f"by {actor} (미발견 {len(resolved['not_found'])}, 유형오류 {len(invalid_type)}, "
                f"범위외 {len(denied)})")
    return {
        "imported": len(rows),
        "deleted": deleted,
        "scope": hdqt or "전체",
        "denied": denied,
        "not_found": resolved['not_found'],
        "invalid_type": invalid_type,
    }


@router.post("/special-sites/import")
async def import_special_sites(req: SpecialSiteImportReq, request: Request):
    """Playground 특이국소 가져오기 (CSV 업로드 등 ksa 로그인 경로).

    - hdqt 미지정: 전체 교체 — admin 전용
    - hdqt 지정: 해당 본부 범위만 교체 — admin 또는 그 본부 manager
    """
    empno, allowed = await _require_manager_scope(request)
    hdqt = (req.hdqt or "").strip()
    if not hdqt and allowed is not None:
        raise HTTPException(403, "전체 동기화는 admin 전용입니다. 본부를 선택하세요")
    if hdqt and allowed is not None:
        if not any(a == hdqt or a.startswith(hdqt) or hdqt.startswith(a) for a in allowed):
            raise HTTPException(403, "본인 본부만 동기화할 수 있습니다")

    try:
        result = await _do_import(req.items, hdqt, empno)
    except ValueError as e:
        raise HTTPException(400, str(e))
    return {"success": True, **result}


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
