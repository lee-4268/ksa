"""
document - 변경개설신고서 자동 반영 엔드포인트

담당 도메인: 무선국 변경개설신고 문서 처리
주요 의존성: core.auth, core.db, core.config
엔드포인트:
    POST /document/change-notification
    POST /document/apply-change-notification
    GET  /document/change-notification-sample
    POST /document/change-notification-sample
"""

import asyncio
import io
import json
import logging
import os
import sqlite3
from datetime import datetime, timezone
from urllib.parse import quote

from botocore.exceptions import ClientError
from fastapi import APIRouter, File, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse

from core.auth import _verify_auth, _get_user_role_sync
from core.config import _DS_DETAIL_DB, _INSP_DB, S3_BUCKET_NAME
from core.db import get_s3_client

router = APIRouter(tags=["document"])
logger = logging.getLogger(__name__)

_CHANGE_NOTIFICATION_SAMPLE_META_KEY = "excel/change-notification-sample-meta.json"
_CHANGE_NOTIFICATION_SAMPLE_PREFIX = "excel/change-notification-sample"


def _get_sample_meta_sync() -> dict:
    """현재 샘플 파일 메타(key, filename) 조회."""
    try:
        s3 = get_s3_client()
        obj = s3.get_object(Bucket=S3_BUCKET_NAME, Key=_CHANGE_NOTIFICATION_SAMPLE_META_KEY)
        return json.loads(obj["Body"].read().decode())
    except ClientError as e:
        if e.response.get("Error", {}).get("Code", "") in ("404", "NoSuchKey"):
            return {}
        raise


@router.post("/document/change-notification")
async def document_change_notification(
    request: Request,
    file1: UploadFile = File(...),
    file2: UploadFile = File(...),
):
    """무선국 변경개설신고 자동 반영 — A파일(신고서) + B파일(DS) 업로드 → 변경된 DS 반환."""
    await _verify_auth(request)

    file1_bytes = await file1.read()
    file2_bytes = await file2.read()

    def _process():
        import xlrd

        def _identify(data):
            try:
                wb = xlrd.open_workbook(file_contents=data)
                sheets = wb.sheet_names()
                if len(sheets) >= 5:
                    return 'B', wb
                ws = wb.sheet_by_index(0)
                for ri in range(min(4, ws.nrows)):
                    if ws.ncols > 3:
                        row_vals = [str(ws.cell_value(ri, ci)).strip() for ci in range(min(ws.ncols, 11))]
                        if any('변경내역' in v or '변경후' in v for v in row_vals):
                            return 'A', wb
                if any('변경' in sn or '신고' in sn for sn in sheets):
                    return 'A', wb
                return 'B', wb
            except Exception:
                return None, None

        type1, wb1 = _identify(file1_bytes)
        type2, wb2 = _identify(file2_bytes)

        if type1 == type2:
            raise ValueError("A파일(변경개설신고)과 B파일(DS파일)을 각각 하나씩 업로드해주세요.")

        a_wb = wb1 if type1 == 'A' else wb2
        b_wb = wb1 if type1 == 'B' else wb2
        b_bytes = file1_bytes if type1 == 'B' else file2_bytes

        a_ws = a_wb.sheet_by_index(0)
        changes = {}
        header_ri = 0
        for ri in range(min(5, a_ws.nrows)):
            row_vals = [str(a_ws.cell_value(ri, ci)).strip() for ci in range(min(a_ws.ncols, 11))]
            if any('변경내역' in v for v in row_vals):
                header_ri = ri
                break
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
        device_ci = col_map.get('장치번호', 6)

        for ri in range(header_ri + 1, a_ws.nrows):
            허가번호 = str(a_ws.cell_value(ri, hn_ci) if a_ws.ncols > hn_ci else '').strip()
            변경내역 = str(a_ws.cell_value(ri, chg_ci) if a_ws.ncols > chg_ci else '').strip()
            변경전 = str(a_ws.cell_value(ri, before_ci) if a_ws.ncols > before_ci else '').strip()
            변경후 = str(a_ws.cell_value(ri, after_ci) if a_ws.ncols > after_ci else '').strip()
            _dev_raw = a_ws.cell_value(ri, device_ci) if a_ws.ncols > device_ci else ''
            if isinstance(_dev_raw, float) and _dev_raw == int(_dev_raw):
                장치번호 = str(int(_dev_raw))
            else:
                장치번호 = str(_dev_raw).strip()
            if not 허가번호 or not 변경후:
                continue
            changes.setdefault(허가번호, []).append({
                '변경내역': 변경내역, '변경전': 변경전, '변경후': 변경후, '장치번호': 장치번호,
            })

        if not changes:
            raise ValueError("A파일에 변경 데이터가 없습니다.")

        설치형태_MAP = {
            '철탑(지면)': '1', '철탑': '1', '강관주': '2', '통신주': '3',
            '원폴(건물)': '4', '원폴': '4',
            '옥내,터널,지하, 차량 또는 임시': '6', '옥내': '6', '터널': '6', '지하': '6', '차량': '6',
            '쌍통신주': '8', '기설물': '9', '옥내외 혼합형': '11', '옥내외혼합형': '11',
            '간이폴 및 비기준 설치대': '12', '간이폴': '12', '간이폴, 분산폴 및 비기준 설치대': '12',
            '한전주(KT통신주)': '13', '한전주': '13', '철탑(건물)': '14', '프레임': '15',
            '복합형(원폴,분산프레임 등)': '21', '복합형': '21', '모노폴': '25',
        }

        def _parse_value(변경내역, 변경후):
            v = 변경후.strip()
            chg = 변경내역.strip()
            v_norm = v.replace('\r\n', '\n').replace('\r', '\n').strip()
            v_upper = v_norm.upper()

            def _extract_after_colon(text):
                return text.split(':', 1)[1].strip() if ':' in text else text.strip()

            def _parse_install_type(text):
                raw = _extract_after_colon(text)
                raw_clean = raw.strip()
                code = 설치형태_MAP.get(raw_clean, '')
                if not code:
                    raw_compact = ''.join(raw_clean.split())
                    for k, c in 설치형태_MAP.items():
                        if ''.join(k.split()) == raw_compact:
                            code = c
                            break
                if not code and '복합형' in raw_clean:
                    code = '21'
                if not code:
                    sorted_keys = sorted(설치형태_MAP.keys(), key=len, reverse=True)
                    for k in sorted_keys:
                        if k in raw_clean or raw_clean in k:
                            code = 설치형태_MAP[k]
                            break
                return {'sheet': '안테나', 'col': 28, 'value': code or raw, 'type': '설치형태'}

            if '설치형태' in v_norm:
                return _parse_install_type(v_norm)
            if '형검' in v_norm or '형식검정' in v_norm:
                return {'sheet': '장치', 'col': 11, 'value': _extract_after_colon(v_norm), 'type': '형식검정번호'}
            if '일련번호' in v_norm:
                return {'sheet': '장치', 'col': 8, 'value': _extract_after_colon(v_norm), 'type': '일련번호'}
            if (v_upper.startswith('MSIP-') or v_upper.startswith('RRA-') or v_upper.startswith('KCC-')
                    or '-CRI-' in v_upper or '-CRM-' in v_upper):
                return {'sheet': '장치', 'col': 11, 'value': v_norm, 'type': '형식검정번호'}
            if any(tok in v_norm for tok in ('특별시', '광역시', '특별자치시', '특별자치도', '시 ', '군 ', '구 ', '읍 ', '면 ', '동 ', '리 ')):
                return {'sheet': '설치장소', 'col': 6, 'value': v_norm, 'type': '설치장소'}
            if any(k in v_norm or v_norm in k for k in 설치형태_MAP.keys()):
                return _parse_install_type(v_norm)
            alnum = ''.join(ch for ch in v_norm if ch.isalnum())
            if len(alnum) >= 6 and not any(ch in v_norm for ch in (' ', '\n', '특별시', '광역시', '시', '군', '구', '읍', '면', '동', '리')):
                return {'sheet': '장치', 'col': 8, 'value': v_norm, 'type': '일련번호'}
            if '형식검정' in chg:
                return {'sheet': '장치', 'col': 11, 'value': _extract_after_colon(v_norm), 'type': '형식검정번호'}
            elif '일련번호' in chg:
                return {'sheet': '장치', 'col': 8, 'value': _extract_after_colon(v_norm), 'type': '일련번호'}
            elif '설치장소' in chg:
                return {'sheet': '설치장소', 'col': 6, 'value': v_norm, 'type': '설치장소'}
            elif '설치형태' in chg:
                return _parse_install_type(v_norm)
            return None

        changes_norm = {hn.replace('-', ''): chg for hn, chg in changes.items()}

        callname_map = {}
        if os.path.exists(_DS_DETAIL_DB):
            try:
                _dc = sqlite3.connect(_DS_DETAIL_DB, timeout=10)
                _norms = list(changes_norm.keys())
                if _norms:
                    _ph = ','.join('?' * len(_norms))
                    for _r in _dc.execute(
                        f'SELECT 허가번호, 호출명칭, 무선국명 FROM ds_일반사항 WHERE 허가번호 IN ({_ph})', _norms
                    ):
                        callname_map[_r[0]] = _r[1] or _r[2] or ''
                _dc.close()
            except Exception:
                pass

        import xlwt

        out_wb = xlwt.Workbook(encoding='utf-8')

        def _make_style(yellow=False):
            style = xlwt.XFStyle()
            fnt = xlwt.Font()
            fnt.name = 'Arial'
            fnt.height = 200
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
                pat.pattern_fore_colour = 13
                style.pattern = pat
            return style

        _st = _make_style(yellow=False)
        _st_y = _make_style(yellow=True)

        change_log = []
        au_entries = {}

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

        일반_sn_pre = None
        for _sn in b_wb.sheet_names():
            if '일반사항' in _sn or '일반' in _sn:
                일반_sn_pre = _sn
                break

        AU_0 = 46

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

        설치장소_hn_count = {}
        for si in range(len(b_wb.sheet_names())):
            sn = b_wb.sheet_names()[si]
            if '설치장소' not in sn:
                continue
            b_ws = b_wb.sheet_by_index(si)
            for ri in range(1, b_ws.nrows):
                hn = _norm_hn(b_ws.cell_value(ri, 0))
                설치장소_hn_count[hn] = 설치장소_hn_count.get(hn, 0) + 1

        for si in range(len(b_wb.sheet_names())):
            sn = b_wb.sheet_names()[si]
            b_ws = b_wb.sheet_by_index(si)
            o_ws = out_wb.add_sheet(sn[:31])
            is_일반 = (sn == 일반_sn_pre)
            is_설치장소 = '설치장소' in sn
            is_안테나 = '안테나' in sn

            col_out_count = b_ws.ncols + (2 if is_일반 else 0)
            for ci in range(max(col_out_count, 49 if is_일반 else b_ws.ncols)):
                o_ws.col(ci).width = 4938

            seen_hn = set()
            out_ri = 0

            for ri in range(b_ws.nrows):
                if is_일반 and ri > 0:
                    hn_check = _norm_hn(b_ws.cell_value(ri, 0))
                    if hn_check in seen_hn:
                        continue
                    seen_hn.add(hn_check)

                overrides = {}

                if ri > 0:
                    hn_norm = _norm_hn(b_ws.cell_value(ri, 0))
                    chg_list = changes_norm.get(hn_norm)

                    if chg_list:
                        _철거구분_col = {'장치': 24, '전파형식': 8, '주파수': 9}.get(sn)
                        if _철거구분_col is not None:
                            overrides[_철거구분_col] = ('N', False)

                    if is_안테나 and chg_list:
                        ac_val = str(b_ws.cell_value(ri, 28) if b_ws.ncols > 28 else '').strip()
                        ab_cur = str(b_ws.cell_value(ri, 27) if b_ws.ncols > 27 else '').strip()
                        if ac_val and not ab_cur:
                            ab_fill = '1' if ac_val in ('6', '11') else '2'
                            overrides[27] = (ab_fill, False)

                    if is_설치장소 and 설치장소_hn_count.get(hn_norm, 0) >= 4:
                        d_val = str(b_ws.cell_value(ri, 3) if b_ws.ncols > 3 else '').strip()
                        if d_val == '04':
                            continue

                    if chg_list:
                        b_device_no = str(b_ws.cell_value(ri, 2) if b_ws.ncols > 2 else '').strip()
                        if b_device_no and isinstance(b_ws.cell_value(ri, 2), float):
                            b_device_no = str(int(b_ws.cell_value(ri, 2)))
                        b_serial = str(b_ws.cell_value(ri, 8) if b_ws.ncols > 8 else '').strip()

                        for chg in chg_list:
                            parsed = _parse_value(chg['변경내역'], chg['변경후'])
                            if not parsed or parsed['sheet'] != sn:
                                continue
                            target_col = parsed['col']
                            new_val = parsed['value']
                            old_val = str(b_ws.cell_value(ri, target_col) if target_col < b_ws.ncols else '').strip()
                            a_device = chg.get('장치번호', '').strip()
                            a_before = chg.get('변경전', '').strip()

                            if parsed['type'] in ('일련번호', '형식검정번호'):
                                if a_device:
                                    if b_device_no != a_device:
                                        continue
                                elif parsed['type'] == '일련번호' and a_before:
                                    if b_serial != a_before:
                                        continue

                            if parsed['type'] == '설치형태':
                                j_val = str(b_ws.cell_value(ri, 9) if b_ws.ncols > 9 else '').strip()
                                ab_0 = 27
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
                                    for _고도_0 in (14, 21, 29):
                                        overrides[_고도_0] = (_고도_val, False)

                            overrides[target_col] = (new_val, True)
                            au_entries[hn_norm] = chg['변경내역']
                            change_log.append({
                                '허가번호': hn_norm, 'sheet': sn,
                                'type': parsed['type'], 'old': old_val, 'new': new_val,
                                '장치번호': a_device or b_device_no,
                            })

                    if is_일반 and hn_norm in au_entries:
                        overrides[AU_0] = (au_entries[hn_norm], True)

                max_lines = 1
                out_ci = 0
                for ci in range(b_ws.ncols):
                    val = b_ws.cell_value(ri, ci)
                    if b_ws.cell_type(ri, ci) == xlrd.XL_CELL_DATE:
                        try:
                            val = xlrd.xldate_as_datetime(val, b_wb.datemode).strftime('%Y-%m-%d')
                        except Exception:
                            pass
                    if ci in overrides:
                        val, yellow = overrides[ci]
                    else:
                        yellow = False
                    max_lines = max(max_lines, _line_count(val))
                    _write(o_ws, out_ri, out_ci, val, _st_y if yellow else _st)
                    out_ci += 1
                    if is_일반 and ci == AU_0:
                        _write(o_ws, out_ri, out_ci, '', _st)
                        _write(o_ws, out_ri, out_ci + 1, '', _st)
                        out_ci += 2

                o_ws.row(out_ri).height_mismatch = True
                o_ws.row(out_ri).height = int(255 * max_lines)
                out_ri += 1

        buf = io.BytesIO()
        out_wb.save(buf)
        buf.seek(0)

        import base64
        diff_map: dict = {}
        for _entry in change_log:
            _hn = _entry['허가번호']
            if _hn not in diff_map:
                diff_map[_hn] = {'허가번호': _hn, '호출명칭': callname_map.get(_hn, ''), 'changes': []}
            if not any(
                c['field'] == _entry['type'] and c['sheet'] == _entry['sheet']
                and c.get('장치번호', '') == _entry.get('장치번호', '')
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
        logger.warning(f"DS 변경 비교 처리 실패: {e}")
        raise HTTPException(400, "파일 비교 처리에 실패했습니다. 파일 형식을 확인하세요")

    return JSONResponse(content=result)


@router.post("/document/apply-change-notification")
async def document_apply_change_notification(request: Request):
    """변경개설신고 diff 결과를 ds_detail.db에 반영하고 이력 저장."""
    await _verify_auth(request)
    body = await request.json()
    selected = set(body.get('selected', []))
    diff = body.get('diff', [])
    applied_date = body.get('applied_date', datetime.now().strftime('%y%m%d'))

    if not selected or not diff:
        raise HTTPException(400, "선택된 국소가 없습니다.")

    def _apply_sync():
        dc = sqlite3.connect(_DS_DETAIL_DB, timeout=60)
        dc.execute('PRAGMA journal_mode=WAL')
        dc.execute('''CREATE TABLE IF NOT EXISTS ds_변경이력 (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            허가번호 TEXT NOT NULL, 변경일자 TEXT NOT NULL,
            시트 TEXT NOT NULL, 필드명 TEXT NOT NULL,
            변경전값 TEXT, 변경후값 TEXT, 장치번호 TEXT
        )''')
        ic = sqlite3.connect(_INSP_DB, timeout=60)
        ic.execute('PRAGMA journal_mode=WAL')
        applied = 0
        not_found_hns: set = set()
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
                        continue
                dc.execute(
                    'INSERT INTO ds_변경이력(허가번호,변경일자,시트,필드명,변경전값,변경후값,장치번호) VALUES(?,?,?,?,?,?,?)',
                    (hn, applied_date, sheet, field, before, after, jn)
                )
                applied += 1
        dc.commit(); ic.commit()
        dc.close(); ic.close()
        return applied, sorted(not_found_hns)

    applied, not_found = await asyncio.to_thread(_apply_sync)
    logger.info(f"변경개설신고 반영: {len(selected)}개 국소, {applied}건 적용 (날짜={applied_date}), 미반영={not_found}")
    return {"ok": True, "applied": applied, "not_found": not_found}


@router.get("/document/change-notification-sample")
async def get_change_notification_sample(request: Request):
    """변경개설신고 샘플 양식 presigned URL 반환."""
    await _verify_auth(request)
    meta = await asyncio.to_thread(_get_sample_meta_sync)
    if not meta.get("key"):
        raise HTTPException(404, "샘플 양식 파일이 없습니다. 관리자에게 문의하세요.")
    original_filename = meta.get("filename", "변경개설신고_샘플양식")
    encoded_name = quote(original_filename, safe="")
    s3 = get_s3_client()
    url = s3.generate_presigned_url(
        "get_object",
        Params={
            "Bucket": S3_BUCKET_NAME,
            "Key": meta["key"],
            "ResponseContentDisposition": f"attachment; filename*=UTF-8''{encoded_name}",
        },
        ExpiresIn=300,
    )
    return {"url": url, "filename": original_filename}


@router.post("/document/change-notification-sample")
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
    meta_bytes = json.dumps({"key": s3_key, "filename": file.filename}, ensure_ascii=False).encode()
    s3 = get_s3_client()
    await asyncio.to_thread(
        lambda: s3.put_object(Bucket=S3_BUCKET_NAME, Key=s3_key, Body=data, ContentType=content_type)
    )
    await asyncio.to_thread(
        lambda: s3.put_object(
            Bucket=S3_BUCKET_NAME, Key=_CHANGE_NOTIFICATION_SAMPLE_META_KEY,
            Body=meta_bytes, ContentType="application/json",
        )
    )
    logger.info(f"변경개설신고 샘플 업로드: {empno}, {file.filename}, {len(data)} bytes")
    return {"ok": True}
