"""
sisl_photos - SKO-OCEAN 시설점검 사진

담당 도메인: 외부 시스템(SKO-OCEAN) 업로드 시설점검 사진 메타 조회/검색
주요 의존성: core.auth, core.config, core.cert_cache
엔드포인트:
    POST /admin/sisl-photos/import     (admin)  엑셀 임포트
    GET  /sisl-photos                            공대(neos_code) 기준 사진 메타
    GET  /sisl-photos/stats            (admin/manager) 임포트 통계
    GET  /sisl-photos/filter-options             본부→팀 매핑 (cert distinct)
    GET  /sisl-photos/search                     본부·팀·국소명·주소 → 공대별 사진 그룹

사진 자체는 사내망 static-int.skons.co.kr 에서 서빙되므로 사내망에서만 표시됨.
사진 DB(sisl_photo)는 공대코드(neos_code)만 보유 → 본부/팀/국소명/주소 검색은
설치확인서 cert 캐시와 조인:
    area_hdofc_nm(본부, 예 '경기Access담당') / ons_team_nm(팀, 예 '평택품질개선팀')
    zpcname(국소명) / zpwiadr(주소) / zpkcode(공대=neos_code 조인키) / zpcode(통시코드)
"""

import asyncio
import io
import logging
import os
import sqlite3
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, File, HTTPException, Query, Request, UploadFile

from core.auth import _verify_auth, _get_user_role_sync, _record_audit_log_sync
from core.config import _SISL_PHOTO_DB
import core.cert_cache as _cert_cache_mod
from core.cert_cache import _cert_cache_load

router = APIRouter(tags=["sisl_photos"])
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


def _sisl_like(term: str) -> str:
    """LIKE 검색용 패턴 — 와일드카드(%, _) escape 후 양끝 % 부착."""
    t = (term or '').strip().replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')
    return f"%{t}%"


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


@router.get("/sisl-photos/filter-options")
async def sisl_photos_filter_options(request: Request):
    """본부→팀 매핑 반환 (cert 캐시의 area_hdofc_nm / ons_team_nm distinct)."""
    await _verify_auth(request)

    def _read() -> dict:
        _cert_cache_load()
        db = _cert_cache_mod._cert_cache_db_path
        if not db or not os.path.exists(db):
            return {"org": {}}
        conn = sqlite3.connect(db, timeout=30)
        try:
            rows = conn.execute(
                'SELECT DISTINCT area_hdofc_nm, ons_team_nm FROM cert '
                'WHERE area_hdofc_nm != "" ORDER BY area_hdofc_nm, ons_team_nm'
            ).fetchall()
        finally:
            conn.close()
        _VALID_HDQT = {'강남', '강북', '경기', '인천', '강원', '충청', '경북', '경남', '서부'}
        org: dict = {}
        for hdqt, team in rows:
            h = (hdqt or '').strip()
            if not h or h not in _VALID_HDQT:
                continue
            org.setdefault(h, [])
            t = (team or '').strip()
            if t and t not in org[h]:
                org[h].append(t)
        return {"org": org}

    return await asyncio.to_thread(_read)


@router.get("/sisl-photos/search")
async def sisl_photos_search(
    request: Request,
    hdqt: str = Query("", description="본부 (area_hdofc_nm 정확 일치)"),
    team: str = Query("", description="팀 (ons_team_nm 정확 일치)"),
    facility: str = Query("", description="국소명 (zpcname LIKE)"),
    address: str = Query("", description="주소 (zpwiadr LIKE)"),
    years_back: int = Query(_SISL_DEFAULT_YEARS_BACK,
        description="현재일 기준 최근 N년 사진만 (0 이면 전체). 기본 3."),
    max_neos: int = Query(500, ge=1, le=2000, description="추출 국소 상한"),
    max_photos: int = Query(4000, ge=1, le=10000, description="반환 사진 상한"),
):
    """본부·팀·국소명·주소로 cert 캐시에서 국소(공대) 추출 → 각 공대의 사진 메타 조회.

    응답:
      {
        "groups": [{neos_code, 통시코드, 국소명, 주소, 본부, 팀, photo_count, photos:[...]}],
        "total_neos": N, "total_photos": M
      }
    조건이 모두 비어 있으면 빈 결과 (전체 스캔 방지).
    """
    await _verify_auth(request)
    hdqt = (hdqt or '').strip()
    team = (team or '').strip()
    facility = (facility or '').strip()
    address = (address or '').strip()
    if not (hdqt or team or facility or address):
        return {"groups": [], "total_neos": 0, "total_photos": 0}

    cutoff = _sisl_upload_date_cutoff(years_back)

    def _read() -> dict:
        _cert_cache_load()
        cert_db = _cert_cache_mod._cert_cache_db_path
        if not cert_db or not os.path.exists(cert_db):
            return {"groups": [], "total_neos": 0, "total_photos": 0}

        # 1) cert 에서 조건 매칭 국소(공대) 추출 — 공대당 1행 (대표 통시/국소명/주소)
        wheres = ['zpkcode != ""']
        params: list = []
        if hdqt:
            wheres.append('area_hdofc_nm = ?')
            params.append(hdqt)
        if team:
            wheres.append('ons_team_nm = ?')
            params.append(team)
        if facility:
            wheres.append("zpcname LIKE ? ESCAPE '\\'")
            params.append(_sisl_like(facility))
        if address:
            wheres.append("zpwiadr LIKE ? ESCAPE '\\'")
            params.append(_sisl_like(address))

        cconn = sqlite3.connect(cert_db, timeout=30)
        cconn.row_factory = sqlite3.Row
        try:
            sql = (
                'SELECT zpkcode, MAX(zpcode) AS zpcode, MAX(zpcname) AS zpcname, '
                'MAX(zpwiadr) AS zpwiadr, MAX(area_hdofc_nm) AS hdqt, MAX(ons_team_nm) AS team '
                f'FROM cert WHERE {" AND ".join(wheres)} '
                'GROUP BY zpkcode ORDER BY zpcname LIMIT ?'
            )
            crows = cconn.execute(sql, [*params, max_neos]).fetchall()
        finally:
            cconn.close()

        if not crows:
            return {"groups": [], "total_neos": 0, "total_photos": 0}

        # 공대 → 국소 메타
        meta = {}
        for r in crows:
            neos = (r['zpkcode'] or '').strip()
            if neos and neos not in meta:
                meta[neos] = {
                    "neos_code": neos,
                    "통시코드": (r['zpcode'] or '').strip(),
                    "국소명": (r['zpcname'] or '').strip(),
                    "주소": (r['zpwiadr'] or '').strip(),
                    "본부": (r['hdqt'] or '').strip(),
                    "팀": (r['team'] or '').strip(),
                }
        neos_list = list(meta.keys())

        # 2) sisl_photo 에서 해당 공대들 사진 조회 (롤링 N년)
        pconn = sqlite3.connect(_SISL_PHOTO_DB, timeout=30)
        pconn.row_factory = sqlite3.Row
        try:
            photos_by_neos: dict = {n: [] for n in neos_list}
            total_photos = 0
            BATCH = 400
            stop = False
            for i in range(0, len(neos_list), BATCH):
                if stop:
                    break
                batch = neos_list[i:i + BATCH]
                ph = ','.join('?' * len(batch))
                pw = [f'neos_code IN ({ph})']
                pp: list = list(batch)
                if cutoff > 0:
                    pw.append('upload_date >= ?')
                    pp.append(cutoff)
                psql = (
                    'SELECT neos_code, guid, reg_cls, file_path, upload_date '
                    f'FROM sisl_photo WHERE {" AND ".join(pw)} '
                    'ORDER BY upload_date DESC, reg_cls ASC'
                )
                for pr in pconn.execute(psql, pp):
                    d = dict(pr)
                    n = d["neos_code"]
                    d["url"] = _build_sisl_photo_url(d["file_path"], d["guid"])
                    bucket = photos_by_neos.get(n)
                    if bucket is None:
                        continue
                    bucket.append(d)
                    total_photos += 1
                    if total_photos >= max_photos:
                        stop = True
                        break
        finally:
            pconn.close()

        # 3) 사진 있는 국소만 그룹으로 묶어 반환 (국소명 정렬 유지)
        groups = []
        for n in neos_list:
            ph_list = photos_by_neos.get(n) or []
            if not ph_list:
                continue
            m = meta[n]
            groups.append({**m, "photo_count": len(ph_list), "photos": ph_list})

        return {
            "groups": groups,
            "total_neos": len(groups),
            "total_photos": total_photos,
        }

    return await asyncio.to_thread(_read)
