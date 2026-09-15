"""
pre_check - 사전대조 엔드포인트

담당 도메인: 일정 등록 이전 단계인 사전대조(대상 배정 → 전산비교 → 변경신고 → 완료)
주요 의존성: core.auth, core.config
엔드포인트:
    GET   /pre-check/targets
    GET   /pre-check/summary
    POST  /pre-check/request          본부담당자 — 대상 선정
    POST  /pre-check/start            품개팀   — 전산비교 착수
    POST  /pre-check/review           품개팀   — 이상 없음 보고
    POST  /pre-check/change-request   품개팀   — 변경신고 요청
    POST  /pre-check/file             품혁담당자 — 관리소 신고 완료
    POST  /pre-check/complete         본부담당자 — 최종 완료
    POST  /pre-check/revert           본부담당자 — 되돌리기
    GET   /pre-check/log

상태는 inspection_targets.pre_check_status 가 갖는다. 일정(inspection_schedules)
보다 앞서는 단계라 schedules.workflow_status 로는 표현할 수 없다 — 일정이 아직
없기 때문이다. PRE_CHECKED 가 된 대상만 일정 등록 대상이 된다.
"""

import asyncio
import json
import logging
import sqlite3
from datetime import datetime, timezone

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from core.auth import (
    _verify_auth, _get_user_role_sync, _caller_allowed_access_list, _dev_users,
)
from core.config import _INSP_DB, DYNAMODB_TABLES
from core.db import get_dynamodb_resource

router = APIRouter(tags=["pre_check"])
logger = logging.getLogger(__name__)


# ── 사전대조 상태 ──────────────────────────────────────────────
PC_NONE = ""                      # 미요청
PC_REQUESTED = "REQUESTED"        # 본부담당자가 대조 요청
PC_IN_PROGRESS = "IN_PROGRESS"    # 품개팀이 전산비교 착수
PC_REVIEWED = "REVIEWED"          # 품개팀 대조 완료(이상 없음) — 본부 확인 대기
PC_CHANGE_REQUESTED = "CHANGE_REQUESTED"  # 품개팀이 변경신고 요청
PC_CHANGE_FILED = "CHANGE_FILED"  # 품혁담당자가 관리소 신고 완료, 회신 대기
PC_DONE = "PRE_CHECKED"           # 본부담당자 최종 완료 → 일정 등록 가능

PC_ALL = (PC_NONE, PC_REQUESTED, PC_IN_PROGRESS, PC_REVIEWED,
          PC_CHANGE_REQUESTED, PC_CHANGE_FILED, PC_DONE)

# 전이 규칙: to_status → 허용되는 from_status 집합.
#
# 최종 완료(PC_DONE)는 본부담당자만 친다. 품개팀은 REVIEWED 까지만 올리고,
# 변경신고가 낀 건은 품혁담당자의 CHANGE_FILED 를 거쳐야 한다. 그래서 두 갈래
# 모두 완료 직전에 본부담당자의 확인 지점이 생긴다.
#   이상 없음:  REQUESTED → IN_PROGRESS → REVIEWED ─────────┐
#   변경 필요:  … → CHANGE_REQUESTED → CHANGE_FILED ────────┴→ PRE_CHECKED
PC_TRANSITIONS = {
    PC_REQUESTED: {PC_NONE},
    PC_IN_PROGRESS: {PC_REQUESTED, PC_IN_PROGRESS},
    PC_REVIEWED: {PC_REQUESTED, PC_IN_PROGRESS},
    PC_CHANGE_REQUESTED: {PC_REQUESTED, PC_IN_PROGRESS, PC_REVIEWED},
    PC_CHANGE_FILED: {PC_CHANGE_REQUESTED},
    PC_DONE: {PC_REVIEWED, PC_CHANGE_FILED},
    PC_NONE: set(PC_ALL) - {PC_NONE},   # 되돌리기(관리자)
}

# 변경 항목 — change_request 와 동일해야 한다.
PC_CHANGE_FIELDS = ("일련번호", "형식검정번호", "설치형태", "설치장소")
PC_DEVICE_FIELDS = ("일련번호", "형식검정번호")


# ── 호출자 범위 ────────────────────────────────────────────────
class _Scope:
    """호출자가 볼 수 있는 범위와 손댈 수 있는 범위.

    member(품질개선팀)는 본인 본부 전량을 '보되' 본인 팀 건만 '고칠' 수 있다.
    프론트의 비활성화만으로는 API 직접 호출을 막지 못하므로 서버가 기준이다.
    """

    def __init__(self, empno: str, role: str, allowed_access, team: str):
        self.empno = empno
        self.role = role
        self.allowed_access = allowed_access   # None = 제한 없음(admin)
        self.team = team

    @property
    def team_locked(self) -> bool:
        """조작 범위가 팀까지 좁혀지는가."""
        return self.role not in ("admin", "manager")

    def can_edit(self, access: str, team: str) -> bool:
        if self.allowed_access is not None:
            if not access or access not in self.allowed_access:
                return False
        if self.team_locked:
            # 팀이 비어 있는 대상은 아무도 자기 것이라 주장할 수 없다.
            return bool(self.team) and team == self.team
        return True


async def _scope_of(request: Request) -> _Scope:
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)

    user_data = {}
    dev = _dev_users.get(empno)
    if dev:
        user_data = {"region": dev.get("region", ""), "team": dev.get("team", "")}
    else:
        try:
            ddb = get_dynamodb_resource()
            tbl = ddb.Table(DYNAMODB_TABLES["users"])
            item = await asyncio.to_thread(lambda: tbl.get_item(
                Key={"user_id": empno},
                ProjectionExpression="#r, team",
                ExpressionAttributeNames={"#r": "region"},
            ))
            user_data = item.get("Item", {})
        except Exception as e:
            logger.error(f"pre-check 사용자 조회 실패: {e}")

    allowed = None if role == "admin" else await asyncio.to_thread(
        _caller_allowed_access_list, empno)
    team = str(user_data.get("team", "") or "")
    return _Scope(empno, role, allowed, team)


def _log_sync(c, year: int, license_no: str, frm: str, to: str,
              empno: str, memo: str = ""):
    c.execute(
        'INSERT INTO pre_check_log(year, 허가번호, from_status, to_status, '
        'changed_by, changed_at, memo) VALUES (?,?,?,?,?,?,?)',
        (year, license_no, frm, to, empno,
         datetime.now(timezone.utc).isoformat(), memo))


def _transition_sync(scope: _Scope, year: int, license_nos: list,
                     to_status: str, memo: str = "",
                     extra_sets: dict = None) -> dict:
    """상태 전이 공통 처리.

    건너뛴 건을 이유별로 돌려준다 — 일괄 처리에서 '몇 건이 왜 안 됐는지'를
    화면이 그대로 보여줄 수 있어야 한다.
    """
    allowed_from = PC_TRANSITIONS.get(to_status)
    if allowed_from is None:
        raise HTTPException(400, f"잘못된 상태: {to_status}")

    c = sqlite3.connect(_INSP_DB, timeout=60)
    c.row_factory = sqlite3.Row
    try:
        changed, skipped = 0, {"권한없음": 0, "상태불가": 0, "대상없음": 0}
        for no in license_nos:
            row = c.execute(
                "SELECT id, 허가번호, pre_check_status, access담당, 품질개선팀 "
                "FROM inspection_targets "
                "WHERE year=? AND REPLACE(허가번호,'-','')=REPLACE(?,'-','')",
                (year, no)).fetchone()
            if not row:
                skipped["대상없음"] += 1
                continue
            if not scope.can_edit(row["access담당"] or "", row["품질개선팀"] or ""):
                skipped["권한없음"] += 1
                continue
            cur = row["pre_check_status"] or PC_NONE
            if cur not in allowed_from:
                skipped["상태불가"] += 1
                continue

            sets = ["pre_check_status=?"]
            params = [to_status]
            for k, v in (extra_sets or {}).items():
                sets.append(f"{k}=?")
                params.append(v)
            params.append(row["id"])
            c.execute(f"UPDATE inspection_targets SET {', '.join(sets)} WHERE id=?",
                      params)
            _log_sync(c, year, row["허가번호"], cur, to_status, scope.empno, memo)
            changed += 1
        c.commit()
        return {"changed": changed,
                "skipped": {k: v for k, v in skipped.items() if v}}
    finally:
        c.close()


# ── 요청 모델 ──────────────────────────────────────────────────
class PcTargetsReq(BaseModel):
    year: int
    license_nos: list[str]
    memo: str = ""


class PcRequestReq(BaseModel):
    year: int
    license_nos: list[str]
    batch: str            # 묶음 이름 — 사전대조 화면이 이 단위로 목록을 묶는다
    memo: str = ""


class PcCompleteReq(BaseModel):
    year: int
    license_nos: list[str]
    summary: dict = {}
    acknowledged: bool = False
    memo: str = ""


class PcChangeItem(BaseModel):
    허가번호: str
    field: str
    before_value: str = ""
    after_value: str
    장치번호: str = ""
    memo: str = ""


class PcChangeReq(BaseModel):
    year: int
    items: list[PcChangeItem]


# ── 조회 ──────────────────────────────────────────────────────
@router.get("/pre-check/targets")
async def pre_check_targets(
    request: Request, year: int, status: str = "", team: str = "",
    batch: str = "", q: str = "", limit: int = 500, offset: int = 0,
):
    """사전대조 대상 목록 — 요청된 건만.

    수검대상 전체가 아니라 본부담당자가 요청한(=묶음에 담긴) 대상만 나온다.
    본부는 서버가 강제로 좁히고(본인 본부), 팀과 묶음은 화면의 필터로 좁힌다.
    각 행에 editable 을 실어 타 팀 건은 화면에서 선택이 막히고, 실제 차단은
    전이 API 가 한다.
    """
    scope = await _scope_of(request)

    def _q():
        c = sqlite3.connect(_INSP_DB, timeout=30)
        c.row_factory = sqlite3.Row
        try:
            # 요청되지 않은 대상은 사전대조의 일이 아니다.
            wheres = ["t.year=?",
                      "t.pre_check_status IS NOT NULL", "t.pre_check_status!=''"]
            params: list = [year]
            if scope.allowed_access is not None:
                if not scope.allowed_access:
                    return [], 0
                ph = ",".join("?" * len(scope.allowed_access))
                wheres.append(f"t.access담당 IN ({ph})")
                params.extend(scope.allowed_access)
            if status and status != "NONE":
                wheres.append("t.pre_check_status=?")
                params.append(status)
            if team:
                wheres.append("t.품질개선팀=?")
                params.append(team)
            if batch:
                wheres.append("t.pre_check_batch=?")
                params.append(batch)
            if q:
                wheres.append("(t.허가번호 LIKE ? OR t.호출명칭 LIKE ?)")
                params.extend([f"%{q}%", f"%{q}%"])

            where = " AND ".join(wheres)
            total = c.execute(
                f"SELECT COUNT(*) FROM inspection_targets t WHERE {where}",
                params).fetchone()[0]
            rows = c.execute(
                "SELECT t.허가번호, t.호출명칭, t.설치장소, t.도로명주소, t.분기, "
                "t.skt본부, t.access담당, t.품질개선팀, t.통시, t.공대, "
                "t.pre_check_status, t.pre_check_requested_at, t.pre_check_done_at, "
                "t.pre_check_result, t.pre_check_batch, "
                "(SELECT COUNT(*) FROM inspection_schedules s "
                " WHERE s.year=t.year AND REPLACE(s.허가번호,'-','')"
                "       =REPLACE(t.허가번호,'-','')) AS has_schedule "
                f"FROM inspection_targets t WHERE {where} "
                # 묶음 → 팀 → 허가번호. 화면이 묶음 단위로 끊어 보여준다.
                "ORDER BY t.pre_check_requested_at DESC, t.pre_check_batch, "
                "t.품질개선팀, t.허가번호 LIMIT ? OFFSET ?",
                (*params, limit, offset)).fetchall()
            return rows, total
        finally:
            c.close()

    rows, total = await asyncio.to_thread(_q)
    items = []
    for r in rows:
        access = r["access담당"] or ""
        tm = r["품질개선팀"] or ""
        items.append({
            "허가번호": r["허가번호"] or "",
            "호출명칭": r["호출명칭"] or "",
            "설치장소": r["설치장소"] or "",
            "도로명주소": r["도로명주소"] or "",
            "분기": r["분기"] or "",
            "skt본부": r["skt본부"] or "",
            "access담당": access,
            "품질개선팀": tm,
            "통시": r["통시"] or "",
            "공대": r["공대"] or "",
            "pre_check_status": r["pre_check_status"] or PC_NONE,
            "batch": r["pre_check_batch"] or "",
            "requested_at": r["pre_check_requested_at"] or "",
            "done_at": r["pre_check_done_at"] or "",
            "has_schedule": bool(r["has_schedule"]),
            "editable": scope.can_edit(access, tm),
        })
    return {"success": True, "total": total, "items": items,
            "role": scope.role, "my_team": scope.team}


@router.get("/pre-check/summary")
async def pre_check_summary(request: Request, year: int, batch: str = ""):
    """상태별 건수 + 묶음·팀 목록(필터 드롭다운용).

    요청된 대상만 센다(목록과 같은 범위). 묶음 목록은 필터와 무관하게 전체를
    주고, 상태·팀 건수는 선택한 묶음 기준으로 준다 — 묶음을 고르면 그 안의
    진행 상황이 보여야 한다.
    """
    scope = await _scope_of(request)

    def _q():
        c = sqlite3.connect(_INSP_DB, timeout=30)
        c.row_factory = sqlite3.Row
        try:
            wheres = ["year=?", "pre_check_status IS NOT NULL",
                      "pre_check_status!=''"]
            params: list = [year]
            if scope.allowed_access is not None:
                if not scope.allowed_access:
                    return {}, [], []
                ph = ",".join("?" * len(scope.allowed_access))
                wheres.append(f"access담당 IN ({ph})")
                params.extend(scope.allowed_access)
            # 묶음 목록은 묶음 필터를 걸기 전 기준.
            base_where = " AND ".join(wheres)
            base_params = list(params)
            bt_rows = c.execute(
                "SELECT COALESCE(NULLIF(pre_check_batch,''),'(묶음없음)') AS bt, "
                "COUNT(*) AS cnt, MAX(pre_check_requested_at) AS at "
                f"FROM inspection_targets WHERE {base_where} "
                "GROUP BY bt ORDER BY at DESC", base_params).fetchall()

            if batch:
                wheres.append("pre_check_batch=?")
                params.append(batch)
            where = " AND ".join(wheres)
            st_rows = c.execute(
                "SELECT pre_check_status AS st, COUNT(*) AS cnt "
                f"FROM inspection_targets WHERE {where} GROUP BY st",
                params).fetchall()
            tm_rows = c.execute(
                "SELECT 품질개선팀 AS tm, COUNT(*) AS cnt FROM inspection_targets "
                f"WHERE {where} AND 품질개선팀 IS NOT NULL AND 품질개선팀!='' "
                "GROUP BY tm ORDER BY tm", params).fetchall()
            return ({r["st"]: r["cnt"] for r in st_rows},
                    [{"team": r["tm"], "count": r["cnt"]} for r in tm_rows],
                    [{"batch": r["bt"], "count": r["cnt"],
                      "requested_at": r["at"] or ""} for r in bt_rows])
        finally:
            c.close()

    counts, teams, batches = await asyncio.to_thread(_q)
    base = {s: 0 for s in PC_ALL if s}
    base.update(counts)
    return {"success": True, "counts": base, "teams": teams,
            "batches": batches, "role": scope.role, "my_team": scope.team}


@router.get("/pre-check/log")
async def pre_check_log(request: Request, year: int, 허가번호: str):
    """단일 대상의 전이 이력."""
    await _scope_of(request)

    def _q():
        c = sqlite3.connect(_INSP_DB, timeout=30)
        c.row_factory = sqlite3.Row
        try:
            return c.execute(
                "SELECT from_status, to_status, changed_by, changed_at, memo "
                "FROM pre_check_log WHERE year=? "
                "AND REPLACE(허가번호,'-','')=REPLACE(?,'-','') "
                "ORDER BY id DESC LIMIT 100", (year, 허가번호)).fetchall()
        finally:
            c.close()

    rows = await asyncio.to_thread(_q)
    return {"success": True, "items": [dict(r) for r in rows]}


# ── 전이 ──────────────────────────────────────────────────────
@router.post("/pre-check/request")
async def pre_check_request(request: Request, req: PcRequestReq):
    """본부담당자가 무선국 일정 화면에서 대상을 골라 사전대조를 요청한다.

    묶음 이름(batch)이 필수다. 사전대조 화면은 요청된 대상만, 그것도 묶음
    단위로 보여준다 — 수검대상 전체를 늘어놓으면 품개팀이 뭘 해야 하는지
    알 수 없다.
    """
    scope = await _scope_of(request)
    if scope.role not in ("admin", "manager"):
        raise HTTPException(403, "사전대조 요청은 본부담당자만 가능합니다")
    if not req.license_nos:
        raise HTTPException(400, "대상이 비어있습니다")
    batch = (req.batch or "").strip()
    if not batch:
        raise HTTPException(400, "묶음 이름을 입력해주세요")
    if len(batch) > 60:
        raise HTTPException(400, "묶음 이름은 60자 이내로 입력해주세요")

    now = datetime.now(timezone.utc).isoformat()
    res = await asyncio.to_thread(
        _transition_sync, scope, req.year, req.license_nos, PC_REQUESTED,
        req.memo or f"사전대조 요청 [{batch}]",
        {"pre_check_requested_by": scope.empno, "pre_check_requested_at": now,
         "pre_check_batch": batch})
    logger.info(f"[pre-check] request year={req.year} batch='{batch}' "
                f"by={scope.empno} {res}")
    return {"success": True, "batch": batch, **res}


@router.post("/pre-check/start")
async def pre_check_start(request: Request, req: PcTargetsReq):
    """전산비교 착수 표시. 품개팀은 본인 팀 건만 가능."""
    scope = await _scope_of(request)
    if not req.license_nos:
        raise HTTPException(400, "대상이 비어있습니다")
    res = await asyncio.to_thread(
        _transition_sync, scope, req.year, req.license_nos, PC_IN_PROGRESS,
        req.memo or "전산비교 착수")
    return {"success": True, **res}


@router.post("/pre-check/review")
async def pre_check_review(request: Request, req: PcCompleteReq):
    """품개팀이 전산비교 결과 '이상 없음'을 보고한다 → REVIEWED.

    최종 완료가 아니다. 본부담당자가 확인해 PRE_CHECKED 로 올린다.

    불일치·DS누락이 있으면 이상 없음이 아니라 변경신고로 가야 한다. 확인필요는
    외부 사이트(ACTA/시설현황) 확인 책임이 품개팀에 있다는 전제로 통과시키되,
    화면이 명시 동의(acknowledged)를 받아야 한다.
    """
    scope = await _scope_of(request)
    if not req.license_nos:
        raise HTTPException(400, "대상이 비어있습니다")

    s = req.summary or {}
    def _n(*keys):
        return sum(int(s.get(k, 0) or 0) for k in keys)
    mismatch = _n("mismatch", "불일치")
    ds_missing = _n("ds_missing", "DS누락")
    check = _n("check", "확인필요")
    if mismatch or ds_missing:
        raise HTTPException(
            400, f"불일치 {mismatch}건 · DS누락 {ds_missing}건이 남아 있어 "
                 "이상 없음으로 보고할 수 없습니다. 변경신고를 먼저 요청해주세요.")
    if check and not req.acknowledged:
        raise HTTPException(400, f"확인필요 {check}건 포함 — 확인 동의가 필요합니다")

    res = await asyncio.to_thread(
        _transition_sync, scope, req.year, req.license_nos, PC_REVIEWED,
        req.memo or "전산비교 이상 없음",
        {"pre_check_result": json.dumps(s, ensure_ascii=False)})
    logger.info(f"[pre-check] review year={req.year} by={scope.empno} {res}")
    return {"success": True, **res}


@router.post("/pre-check/complete")
async def pre_check_complete(request: Request, req: PcCompleteReq):
    """본부담당자가 최종 사전대조 완료를 친다 → PRE_CHECKED.

    여기를 통과한 대상만 일정 등록이 가능하다. 품개팀의 이상 없음 보고
    (REVIEWED) 또는 품혁담당자의 신고 완료(CHANGE_FILED)를 거친 건만 올라온다
    — 앞 단계를 건너뛴 건은 _transition_sync 가 '상태불가'로 떨군다.
    """
    scope = await _scope_of(request)
    if scope.role not in ("admin", "manager"):
        raise HTTPException(403, "최종 사전대조 완료는 본부담당자만 가능합니다")
    if not req.license_nos:
        raise HTTPException(400, "대상이 비어있습니다")

    now = datetime.now(timezone.utc).isoformat()
    res = await asyncio.to_thread(
        _transition_sync, scope, req.year, req.license_nos, PC_DONE,
        req.memo or "사전대조 최종 완료",
        {"pre_check_done_by": scope.empno, "pre_check_done_at": now})
    logger.info(f"[pre-check] complete year={req.year} by={scope.empno} {res}")
    return {"success": True, **res}


@router.post("/pre-check/change-request")
async def pre_check_change_request(request: Request, req: PcChangeReq):
    """전산비교 오류 항목으로 변경신고를 요청한다.

    일정이 아직 없으므로 change_request.schedule_pk 는 '' 로 두고 year 로 건다.
    기존 /change-request/direct 는 일정 미등록 건을 막아두었는데, 그 이유였던
    '취소 시 사전점검 상태 복귀 불가'는 여기서는 문제가 되지 않는다 — 되돌릴
    상태(pre_check_status)를 대상 자신이 갖고 있기 때문이다.
    """
    scope = await _scope_of(request)
    if not req.items:
        raise HTTPException(400, "변경 항목이 비어있습니다")

    for it in req.items:
        if it.field not in PC_CHANGE_FIELDS:
            raise HTTPException(400, f"잘못된 변경 항목: {it.field}")
        if it.field in PC_DEVICE_FIELDS and not it.장치번호.strip():
            raise HTTPException(400, f"{it.field}는 장치번호가 필요합니다")
        if not it.after_value.strip():
            raise HTTPException(400, f"{it.field} 변경 후 값이 비어있습니다")

    license_nos = list(dict.fromkeys(it.허가번호 for it in req.items))
    now = datetime.now(timezone.utc).isoformat()

    def _save():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        c.row_factory = sqlite3.Row
        try:
            # 권한은 대상 단위로 먼저 확정한다. 한 건이라도 남의 팀이면 통째로
            #   거절한다 — 일부만 저장되면 화면이 어떤 게 들어갔는지 알 수 없다.
            ok = set()
            for no in license_nos:
                r = c.execute(
                    "SELECT access담당, 품질개선팀, pre_check_status "
                    "FROM inspection_targets WHERE year=? "
                    "AND REPLACE(허가번호,'-','')=REPLACE(?,'-','')",
                    (req.year, no)).fetchone()
                if not r:
                    raise HTTPException(400, f"{no}: 수검대상에 없습니다")
                if not scope.can_edit(r["access담당"] or "", r["품질개선팀"] or ""):
                    raise HTTPException(403, f"{no}: 다른 팀 국소는 요청할 수 없습니다")
                ok.add(no)

            for it in req.items:
                c.execute(
                    'INSERT INTO change_request(schedule_pk, year, 허가번호, field, '
                    'before_value, after_value, 장치번호, memo, status, '
                    'requested_by, requested_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                    ('', req.year, it.허가번호, it.field, it.before_value,
                     it.after_value, it.장치번호, it.memo, 'REQUESTED',
                     scope.empno, now))
            c.commit()
            return len(req.items), sorted(ok)
        finally:
            c.close()

    count, targets = await asyncio.to_thread(_save)
    res = await asyncio.to_thread(
        _transition_sync, scope, req.year, targets, PC_CHANGE_REQUESTED,
        f"변경신고 {count}건 요청")
    logger.info(f"[pre-check] change-request year={req.year} "
                f"by={scope.empno} items={count} {res}")
    return {"success": True, "count": count, **res}


@router.post("/pre-check/file")
async def pre_check_file(request: Request, req: PcTargetsReq):
    """본부담당자가 변경신고서를 만들어 관리소에 요청한 뒤 신고 완료를 표시한다.

    신고도 최종 완료도 본부담당자(= 품혁담당자, 같은 사람)의 일이라 둘 다
    admin/manager 로 연다.
    """
    scope = await _scope_of(request)
    if scope.role not in ("admin", "manager"):
        raise HTTPException(403, "신고 완료 처리 권한이 없습니다")
    if not req.license_nos:
        raise HTTPException(400, "대상이 비어있습니다")

    now = datetime.now(timezone.utc).isoformat()

    def _mark():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        try:
            for no in req.license_nos:
                c.execute(
                    "UPDATE change_request SET status='FILED', filed_by=?, filed_at=? "
                    "WHERE year=? AND REPLACE(허가번호,'-','')=REPLACE(?,'-','') "
                    "AND status='REQUESTED' AND cancelled!='1'",
                    (scope.empno, now, req.year, no))
            c.commit()
        finally:
            c.close()

    await asyncio.to_thread(_mark)
    res = await asyncio.to_thread(
        _transition_sync, scope, req.year, req.license_nos, PC_CHANGE_FILED,
        req.memo or "전파관리소 신고 완료")
    return {"success": True, **res}


@router.post("/pre-check/revert")
async def pre_check_revert(request: Request, req: PcTargetsReq):
    """사전대조 상태 되돌리기 (admin/manager).

    잘못 배정했거나 완료 처리한 건을 미요청으로 되돌린다. 일정이 이미 등록된
    건은 되돌리면 일정만 남아 앞뒤가 안 맞으므로 막는다.
    """
    scope = await _scope_of(request)
    if scope.role not in ("admin", "manager"):
        raise HTTPException(403, "되돌리기는 본부담당자만 가능합니다")
    if not req.license_nos:
        raise HTTPException(400, "대상이 비어있습니다")

    def _scheduled():
        c = sqlite3.connect(_INSP_DB, timeout=30)
        try:
            out = set()
            for no in req.license_nos:
                r = c.execute(
                    "SELECT 1 FROM inspection_schedules WHERE year=? "
                    "AND REPLACE(허가번호,'-','')=REPLACE(?,'-','')",
                    (req.year, no)).fetchone()
                if r:
                    out.add(no)
            return out
        finally:
            c.close()

    blocked = await asyncio.to_thread(_scheduled)
    targets = [n for n in req.license_nos if n not in blocked]
    if not targets:
        raise HTTPException(400, "일정이 등록된 국소는 되돌릴 수 없습니다")

    res = await asyncio.to_thread(
        _transition_sync, scope, req.year, targets, PC_NONE,
        req.memo or "사전대조 되돌리기")
    if blocked:
        res.setdefault("skipped", {})["일정등록됨"] = len(blocked)
    return {"success": True, **res}
