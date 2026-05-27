"""
change_request - 변경개설 요청 엔드포인트

담당 도메인: 무선국 변경개설 신고 관리
주요 의존성: core.auth, core.config
엔드포인트:
    POST /change-request/direct
    GET  /change-request
    PATCH /change-request/file
    POST /change-request/generate-form
"""

import asyncio
import io
import logging
import sqlite3
from datetime import datetime, timezone
from urllib.parse import quote

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse

from core.auth import _verify_auth, _get_user_role_sync
from core.config import _INSP_DB, _COMMUNITY_DB
from schemas.models import ChangeRequestDirectReq, ChangeRequestFileReq

router = APIRouter(tags=["change_request"])
logger = logging.getLogger(__name__)

# ── 워크플로우 상수 ────────────────────────────────────────────
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

WF_CHANGE_FIELDS = {"일련번호", "형식검정번호", "설치형태", "설치장소"}
WF_CHANGE_DEVICE_FIELDS = {"일련번호", "형식검정번호"}

_WF_CHANGE_LABEL = {
    "설치형태": "설치형태 오류정정",
    "설치장소": "(부적합 무선국)\n설치장소 오류정정",
    "일련번호": "송수신장치 변경(공용화 고시 제6조제3항제1호)",
    "형식검정번호": "(불합격 무선국)\n형식검정번호 오류정정",
}


def _wf_can_transition(from_status: str | None, to_status: str, role: str) -> bool:
    """워크플로우 상태 전환 허용 여부."""
    if to_status not in WF_VALID:
        return False
    if role == "admin":
        return True
    allowed = _WF_TRANSITIONS.get(from_status, set())
    return to_status in allowed


def _wf_record_log_sync(conn, schedule_pk: str, from_status: str | None,
                        to_status: str, changed_by: str, memo: str = ""):
    """상태 전환 이력 기록."""
    now = datetime.now(timezone.utc).isoformat()
    conn.execute(
        'INSERT INTO inspection_status_log(schedule_pk, from_status, to_status, '
        'changed_by, changed_at, memo) VALUES (?,?,?,?,?,?)',
        (schedule_pk, from_status, to_status, changed_by, now, memo))


def _wf_format_change_value(field: str, value: str) -> str:
    """변경전/변경후 값에 prefix 적용."""
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
    """허가번호 하이픈 4그룹 포맷."""
    s = (license_no or "").replace("-", "")
    if len(s) >= 12:
        return f"{s[:2]}-{s[2:6]}-{s[6:8]}-{s[8:]}"
    return license_no


@router.post("/change-request/direct")
async def change_request_direct(request: Request, req: ChangeRequestDirectReq):
    """일정 미연결 허가번호에 대한 변경개설 요청 (admin/manager 전용)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in ("admin", "manager"):
        raise HTTPException(403, "권한 없음")

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
        for it in req.items:
            c.execute(
                'INSERT INTO change_request(schedule_pk, 허가번호, field, before_value, '
                'after_value, 장치번호, memo, status, requested_by, requested_at) '
                'VALUES (?,?,?,?,?,?,?,?,?,?)',
                ('', req.허가번호, it.field, it.before_value, it.after_value,
                 it.장치번호, it.memo, 'REQUESTED', empno, now))
        c.commit()
        c.close()
        return len(req.items)

    count = await asyncio.to_thread(_save)
    return {"success": True, "count": count}


@router.get("/change-request")
async def change_request_list(
    request: Request, schedule_pk: str = "", status: str = "",
    허가번호: str = "", access담당: str = "", year: int = 0,
):
    """변경개설 요청 목록 조회."""
    await _verify_auth(request)

    def _read():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        c.row_factory = sqlite3.Row
        wheres: list = []
        params: list = []
        if schedule_pk:
            wheres.append('cr.schedule_pk=?')
            params.append(schedule_pk)
        if status:
            wheres.append('cr.status=?')
            params.append(status)
        if 허가번호:
            wheres.append('cr.허가번호=?')
            params.append(허가번호)
        join = ''
        if access담당 or year:
            join = ' JOIN inspection_schedules s ON s.pk = cr.schedule_pk'
            if access담당:
                wheres.append('s.access담당=?')
                params.append(access담당)
            if year:
                wheres.append('s.year=?')
                params.append(year)
        sql = f'SELECT cr.* FROM change_request cr{join}'
        if wheres:
            sql += ' WHERE ' + ' AND '.join(wheres)
        sql += ' ORDER BY cr.requested_at DESC'
        rows = c.execute(sql, params).fetchall()
        c.close()
        return [dict(r) for r in rows]

    items = await asyncio.to_thread(_read)
    return {"items": items}


@router.patch("/change-request/file")
async def change_request_file(request: Request, req: ChangeRequestFileReq):
    """혁신팀이 전파관리소 신고 완료 표시 (단건 또는 묶음)."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in {"admin", "manager"}:
        raise HTTPException(403, "관리자/매니저만 가능")
    now = datetime.now(timezone.utc).isoformat()

    pks = list(req.schedule_pks) if req.schedule_pks else []
    if req.schedule_pk:
        pks.append(req.schedule_pk)
    pks = list(dict.fromkeys(p for p in pks if p))
    if not pks:
        raise HTTPException(400, "schedule_pk(s) 비어있음")

    def _save_one(c, pk: str) -> tuple:
        row = c.execute(
            'SELECT workflow_status FROM inspection_schedules WHERE pk=?', (pk,)
        ).fetchone()
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
        c.commit()
        c.close()
        return results

    results = await asyncio.to_thread(_save)
    success = sum(1 for r in results if r["ok"])
    return {"success": True, "total": len(results), "succeeded": success, "results": results}


@router.post("/change-request/generate-form")
async def change_request_generate_form(
    request: Request,
    품질개선팀: str = "",
    수검예정주차: str = "",
    조: str = "",
    year: int = 0,
    schedule_pk: str = "",
):
    """A파일(변경개설 신고서) 묶음 자동 생성 - xls 즉시 응답."""
    await _verify_auth(request)

    def _build():
        c = sqlite3.connect(_INSP_DB, timeout=60)
        c.row_factory = sqlite3.Row
        if schedule_pk:
            scheds = c.execute(
                'SELECT * FROM inspection_schedules WHERE pk=?', (schedule_pk,)
            ).fetchall()
        else:
            wheres = []
            params: list = []
            if year:
                wheres.append('year=?')
                params.append(year)
            if 품질개선팀:
                wheres.append('품질개선팀=?')
                params.append(품질개선팀)
            if 수검예정주차:
                wheres.append('수검예정주차=?')
                params.append(수검예정주차)
            if 조:
                wheres.append('조=?')
                params.append(조)
            if not wheres:
                c.close()
                raise HTTPException(400, "묶음 키 또는 schedule_pk 필요")
            scheds = c.execute(
                f'SELECT * FROM inspection_schedules WHERE {" AND ".join(wheres)} ORDER BY 허가번호',
                params
            ).fetchall()
        scheds = [dict(s) for s in scheds]
        if not scheds:
            c.close()
            raise HTTPException(404, "묶음 일정 없음")
        sched_pks = [s['pk'] for s in scheds]
        ph = ','.join('?' * len(sched_pks))
        rows = c.execute(
            f"SELECT * FROM change_request WHERE schedule_pk IN ({ph}) ORDER BY schedule_pk, id",
            sched_pks
        ).fetchall()
        c.close()
        rows = [dict(r) for r in rows]
        if not rows:
            raise HTTPException(404, "변경 요청 없음")
        sched_map = {s['pk']: s for s in scheds}
        return scheds, sched_map, rows

    scheds, sched_map, items = await asyncio.to_thread(_build)

    first = scheds[0]
    팀 = (first.get('품질개선팀') or '').strip() or 품질개선팀
    주차 = (first.get('수검예정주차') or '').strip() or 수검예정주차
    조_v = (first.get('조') or '').strip() or 조
    sheet_name = f"{팀}_{주차}_{조_v}".strip('_') or '변경개설신고'
    if len(sheet_name) > 31:
        sheet_name = sheet_name[:31]

    import xlwt
    wb = xlwt.Workbook(encoding='utf-8')
    ws = wb.add_sheet(sheet_name)

    col_widths = [947, 5401, 4915, 2304, 13952, 13952, 13952, 1331, 1331, 2304, 3379, 1689]
    for ci, w in enumerate(col_widths):
        ws.col(ci).width = w

    def _font(height: int, name: str = '맑은 고딕'):
        f = xlwt.Font()
        f.name = name
        f.height = height
        return f

    def _border():
        b = xlwt.Borders()
        b.left = b.right = b.top = b.bottom = xlwt.Borders.THIN
        return b

    def _align(h='center', v='center', wrap=False):
        a = xlwt.Alignment()
        a.horz = {'left': xlwt.Alignment.HORZ_LEFT,
                  'center': xlwt.Alignment.HORZ_CENTER,
                  'right': xlwt.Alignment.HORZ_RIGHT}.get(h, xlwt.Alignment.HORZ_CENTER)
        a.vert = xlwt.Alignment.VERT_CENTER
        if wrap:
            a.wrap = xlwt.Alignment.WRAP_AT_RIGHT
        return a

    def _yellow_pattern():
        p = xlwt.Pattern()
        p.pattern = xlwt.Pattern.SOLID_PATTERN
        p.pattern_fore_colour = 13
        return p

    style_title = xlwt.XFStyle()
    style_title.font = _font(600)
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

    ws.row(0).height_mismatch = True; ws.row(0).height = 768
    ws.row(1).height_mismatch = True; ws.row(1).height = 345
    ws.row(2).height_mismatch = True; ws.row(2).height = 348

    ws.write(0, 0, '○ 무선국 변경개설신고', style_title)
    headers = ['순\n번', '호출명칭', '허가번호', '장치번호', '변경내역', '변경전', '변경후',
               '위도', '경도', '준공기한', '심의차수', '허가\n종류']
    for ci, h in enumerate(headers):
        ws.write_merge(1, 2, ci, ci, h, style_header)

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
        # 장치번호는 장치 단위 변경(일련번호/형식검정번호)에만 의미 — 그 외 항목은 빈 칸
        장치번호 = (it.get('장치번호') or '').strip() if field in WF_CHANGE_DEVICE_FIELDS else ''
        ws.write(ri, 0, idx + 1, style_data)
        ws.write(ri, 1, 호출명칭, style_data)
        ws.write(ri, 2, 허가번호, style_data)
        ws.write(ri, 3, 장치번호, style_data)
        ws.write(ri, 4, 변경내역, style_data_yellow)
        ws.write(ri, 5, 변경전, style_data)
        ws.write(ri, 6, 변경후, style_data)
        ws.write(ri, 7, '기존동일', style_data)
        ws.write(ri, 8, '', style_data)
        ws.write(ri, 9, '', style_data)
        ws.write(ri, 10, '', style_data)
        ws.write(ri, 11, '운용', style_data)

    buf = io.BytesIO()
    wb.save(buf)
    buf.seek(0)
    n = len(items)
    filename = f"{sheet_name}_{n}건.xls" if n else f"{sheet_name}.xls"
    return StreamingResponse(
        buf,
        media_type="application/vnd.ms-excel",
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(filename)}"},
    )
