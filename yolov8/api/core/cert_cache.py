"""
cert_cache - 설치확인서 SQLite 캐시 (공유 상태)

담당 도메인: S3 CSV → SQLite 디스크 캐시 빌드/조회 (cert.py + callname.py 공유)
주요 의존성: core.config, core.s3
엔드포인트: 없음
"""

import os
import sqlite3
import threading
import logging
import time as _time_mod
import tempfile as _tempfile

from .config import (
    S3_BUCKET_NAME, CERT_CACHE_TTL,
    CALLNAME_CSV_PREFIX, CALLNAME_USE_COLS,
    _INSP_DB,
)
from .s3 import get_s3_client

logger = logging.getLogger(__name__)

# ── 설치확인서 SQLite 캐시 상태 ──────────────────────────────────
_cert_cache_lock = threading.Lock()
_cert_cache_ts: float = 0.0
_cert_cache_db_path: str = ""


def _get_s3_csv_keys():
    """S3 호출명칭 CSV 파일 키 목록 반환."""
    resp = get_s3_client().list_objects_v2(Bucket=S3_BUCKET_NAME, Prefix=CALLNAME_CSV_PREFIX)
    return [obj["Key"] for obj in resp.get("Contents", [])
            if obj["Key"].lower().endswith(".csv")]


def _stream_s3_csvs():
    """S3 CSV를 행 단위 스트리밍. 메모리에 전체 로드하지 않음.
    Yields: dict (각 행, CALLNAME_USE_COLS 키만)"""
    import csv as _csv_mod
    import codecs
    csv_keys = _get_s3_csv_keys()
    for key in csv_keys:
        obj = get_s3_client().get_object(Bucket=S3_BUCKET_NAME, Key=key)
        body = obj["Body"]
        try:
            stream_reader = codecs.getreader("utf-8")(body, errors="replace")
            reader = _csv_mod.DictReader(stream_reader)
            for raw_row in reader:
                yield {c: (raw_row.get(c) or "") for c in CALLNAME_USE_COLS}
        finally:
            body.close()


def _cert_cache_load():
    """S3 CSV → SQLite DB 파일로 캐싱. 메모리 사용 최소화."""
    global _cert_cache_ts, _cert_cache_db_path

    now = _time_mod.time()
    if _cert_cache_db_path and os.path.exists(_cert_cache_db_path) and (now - _cert_cache_ts) < CERT_CACHE_TTL:
        return

    with _cert_cache_lock:
        if _cert_cache_db_path and os.path.exists(_cert_cache_db_path) and (_time_mod.time() - _cert_cache_ts) < CERT_CACHE_TTL:
            return

        logger.info("설치확인서 SQLite 캐시 빌드 시작...")
        t0 = _time_mod.time()

        db_path = os.path.join(_tempfile.gettempdir(), "cert_cache.db")
        tmp_path = db_path + ".tmp"

        conn = sqlite3.connect(tmp_path)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=OFF")
        conn.execute("""CREATE TABLE IF NOT EXISTS cert (
            zpwino TEXT, zpwina TEXT, zpwiadr TEXT,
            zpcode TEXT, zpkcode TEXT, zpcname TEXT, area_hdofc_nm TEXT, ons_team_nm TEXT, zpirty3 TEXT,
            eqp_ser_no TEXT, zpprac1 TEXT, eqp_type TEXT, max_seqno TEXT,
            zpannu1 TEXT, swing_list TEXT
        )""")
        conn.execute("DELETE FROM cert")

        batch = []
        total = 0
        for row in _stream_s3_csvs():
            batch.append((
                row.get("zpwino", ""), row.get("zpwina", ""),
                row.get("zpwiadr", ""), row.get("zpcode", ""), row.get("zpkcode", ""),
                row.get("zpcname", ""),
                row.get("area_hdofc_nm", ""), row.get("ons_team_nm", ""),
                row.get("zpirty3", ""), row.get("eqp_ser_no", ""),
                row.get("zpprac1", ""), row.get("eqp_type", ""),
                row.get("max_seqno", ""),
                row.get("zpannu1", ""), row.get("swing_list", ""),
            ))
            if len(batch) >= 5000:
                conn.executemany("INSERT INTO cert VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
                total += len(batch)
                batch.clear()
        if batch:
            conn.executemany("INSERT INTO cert VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", batch)
            total += len(batch)

        conn.execute("CREATE INDEX IF NOT EXISTS idx_zpwino ON cert(zpwino)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_zpwina ON cert(zpwina)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_zpwiadr ON cert(zpwiadr)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_zpcode ON cert(zpcode)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_zpwino_zpwina ON cert(zpwino, zpwina)")
        conn.commit()
        conn.close()

        os.replace(tmp_path, db_path)
        for _stale_ext in ('-wal', '-shm'):
            _stale = tmp_path + _stale_ext
            if os.path.exists(_stale):
                try:
                    os.remove(_stale)
                except Exception:
                    pass

        _cert_cache_db_path = db_path
        _cert_cache_ts = _time_mod.time()
        logger.info(f"설치확인서 SQLite 캐시 빌드 완료: {total}행, {_cert_cache_ts - t0:.1f}초")

        # 주소→팀 학습맵 워밍업은 여기서 하지 않는다.
        # 과거 이 자리에서 learned_addr_map.json 을 {'access':…,'team':…} 형태로 썼는데,
        # 같은 파일을 읽는 routers.inspection 은 {키: '팀명'} 형태를 기대해
        # _hdqt_from_addr 에서 TypeError(unhashable dict) 가 발생했다.
        # 학습맵은 routers.inspection._learn_addr_map_from_cert_db 가 필요 시 직접 빌드한다.


def _cert_cache_force_rebuild():
    """캐시 TTL 무시하고 강제 재빌드."""
    global _cert_cache_ts
    _cert_cache_ts = 0.0
    _cert_cache_load()


def _cert_lookup_cached(query: str) -> dict:
    """설치확인서 단건 조회 — SQLite 인덱스 조회.

    같은 허가번호(zpwino)에 여러 cert 행이 있을 수 있음(주파수/장비별). 단순
    LIMIT 1 은 비결정적이라 일정 화면(inspection_targets)과 어긋날 수 있어,
    inspection_targets 에 저장된 공대/통시 를 우선 매칭한다.

    매칭 우선순위 (zpwino 가 여러 행을 반환할 때):
    1) inspection_targets.공대 == zpkcode 일치
    2) inspection_targets.통시 == zpcode 일치
    3) zpkcode 비어있지 않은 행
    4) zpcname 알파벳 순 첫 번째 (결정적)
    """
    if not query or not query.strip():
        return {}
    _cert_cache_load()
    q = query.strip()
    cols = ["zpwino", "zpwina", "zpwiadr", "zpcode", "zpkcode", "zpcname",
            "area_hdofc_nm", "ons_team_nm", "zpirty3", "eqp_ser_no"]
    try:
        conn = sqlite3.connect(_cert_cache_db_path)
        conn.row_factory = sqlite3.Row
        for col in ("zpwino", "zpwina", "zpwiadr"):
            rows = conn.execute(f"SELECT * FROM cert WHERE {col}=?", (q,)).fetchall()
            if not rows:
                continue
            if len(rows) == 1:
                conn.close()
                return {c: (rows[0][c] or "") for c in cols}
            # 여러 행 — inspection_targets 와 일치하는 행 우선
            chosen = _pick_cert_row_matching_inspection(rows, q if col == "zpwino" else "")
            conn.close()
            return {c: (chosen[c] or "") for c in cols}
        conn.close()
    except Exception as e:
        logger.warning(f"설치확인서 캐시 조회 실패: {e}")
    return {}


def _pick_cert_row_matching_inspection(rows, license_no: str):
    """여러 cert 행 중 inspection_targets 의 공대/통시 와 일치하는 행을 우선 선택.

    rows: sqlite3.Row 리스트 (len >= 2 가정)
    license_no: 허가번호 (zpwino 컬럼으로 조회한 경우만 채워짐, 그 외엔 빈 문자열)
    Returns: 선택된 sqlite3.Row
    """
    insp_gongtae = ""
    insp_tongsi = ""
    if license_no and os.path.exists(_INSP_DB):
        try:
            iconn = sqlite3.connect(_INSP_DB, timeout=5)
            try:
                # inspection_targets 는 허가번호에 하이픈 포함 케이스가 있을 수 있어 REPLACE 비교
                r = iconn.execute(
                    "SELECT 공대, 통시 FROM inspection_targets "
                    "WHERE REPLACE(허가번호,'-','')=? LIMIT 1",
                    (license_no.replace('-', ''),),
                ).fetchone()
                if r:
                    insp_gongtae = (r[0] or '').strip()
                    insp_tongsi = (r[1] or '').strip()
            finally:
                iconn.close()
        except Exception as e:
            logger.warning(f"inspection_targets 조회 실패 (cert row 선택용): {e}")

    if insp_gongtae:
        for row in rows:
            if (row["zpkcode"] or "").strip() == insp_gongtae:
                return row
    if insp_tongsi:
        for row in rows:
            if (row["zpcode"] or "").strip() == insp_tongsi:
                return row
    # 공대 채워진 행 우선, 그 안에서 zpcname 알파벳 순
    non_empty_gongtae = [r for r in rows if (r["zpkcode"] or "").strip()]
    pool = non_empty_gongtae or list(rows)
    pool.sort(key=lambda r: (r["zpcname"] or ""))
    return pool[0]


def _cert_batch_lookup_cached(zpwino_list: list) -> dict:
    """설치확인서 일괄 조회 — IN 쿼리 2-pass (zpwino→zpwina 순서)."""
    if not zpwino_list:
        return {}
    _cert_cache_load()
    cols = ["zpwino", "zpwina", "zpwiadr", "zpcode", "zpkcode", "area_hdofc_nm", "ons_team_nm", "zpirty3", "eqp_ser_no", "max_seqno", "zpprac1"]
    col_str = ', '.join(cols)
    results = {}
    BATCH = 900
    try:
        conn = sqlite3.connect(_cert_cache_db_path, timeout=30)
        conn.row_factory = sqlite3.Row

        norms = list({q.replace('-', '').strip() for q in zpwino_list})
        originals = list(dict.fromkeys(zpwino_list))
        norm_map = {q.replace('-', '').strip(): q for q in originals}
        for batch in (originals, norms):
            remaining_batch = [q for q in batch if norm_map.get(q.replace('-','').strip(), q) not in results]
            if not remaining_batch:
                continue
            for i in range(0, len(remaining_batch), BATCH):
                sub = remaining_batch[i:i+BATCH]
                ph = ','.join('?' * len(sub))
                for row in conn.execute(
                    f"SELECT {col_str} FROM cert WHERE zpwino IN ({ph})", sub
                ):
                    rd = dict(row)
                    wino = (rd.get('zpwino') or '').strip()
                    orig_q = norm_map.get(wino.replace('-', ''), wino)
                    if orig_q not in results:
                        results[orig_q] = {c: (rd.get(c) or '') for c in cols}

        missing = [q for q in originals if q not in results]
        if missing:
            for i in range(0, len(missing), BATCH):
                sub = missing[i:i+BATCH]
                ph = ','.join('?' * len(sub))
                for row in conn.execute(
                    f"SELECT {col_str} FROM cert WHERE zpwina IN ({ph})", sub
                ):
                    rd = dict(row)
                    zpwina_val = (rd.get('zpwina') or '').strip()
                    if zpwina_val in sub and zpwina_val not in results:
                        results[zpwina_val] = {c: (rd.get(c) or '') for c in cols}

        conn.close()
        logger.info(f"[cert_batch] 요청={len(originals)} 조회={len(results)}")
    except Exception as e:
        logger.warning(f"설치확인서 배치 캐시 조회 실패: {e}")
    return results


def _query_callname_db(zpwina_values: list, zpwino_values: list) -> dict:
    """6방향 교차 매칭 — SQLite 캐시 활용 (인덱스 조회).
    {lookup_key: {area_hdofc_nm, ons_team_nm, zpcode, zpwiadr}}"""
    zpwina_set = set(str(v) for v in zpwina_values if v)
    zpwino_set = set(str(v) for v in zpwino_values if v)
    all_query = zpwina_set | zpwino_set
    if not all_query:
        return {}

    _cert_cache_load()

    result = {}
    try:
        conn = sqlite3.connect(_cert_cache_db_path, timeout=30)
        conn.row_factory = sqlite3.Row

        query_list = list(all_query)
        BATCH = 900
        for offset in range(0, len(query_list), BATCH):
            batch = query_list[offset:offset + BATCH]
            placeholders = ",".join("?" * len(batch))

            cur = conn.execute(
                f"SELECT zpwina, zpwino, zpwiadr, zpcode, area_hdofc_nm, ons_team_nm "
                f"FROM cert WHERE zpwina IN ({placeholders})", batch)
            for row in cur:
                data = {
                    "area_hdofc_nm": row["area_hdofc_nm"] or "",
                    "ons_team_nm": row["ons_team_nm"] or "",
                    "zpcode": row["zpcode"] or "",
                    "zpwiadr": row["zpwiadr"] or "",
                }
                for key in (row["zpwina"], row["zpwino"], row["zpwiadr"]):
                    if key and key in all_query and key not in result:
                        result[key] = data

            remaining = [q for q in batch if q not in result]
            if remaining:
                ph2 = ",".join("?" * len(remaining))
                cur = conn.execute(
                    f"SELECT zpwina, zpwino, zpwiadr, zpcode, area_hdofc_nm, ons_team_nm "
                    f"FROM cert WHERE zpwino IN ({ph2})", remaining)
                for row in cur:
                    data = {
                        "area_hdofc_nm": row["area_hdofc_nm"] or "",
                        "ons_team_nm": row["ons_team_nm"] or "",
                        "zpcode": row["zpcode"] or "",
                        "zpwiadr": row["zpwiadr"] or "",
                    }
                    for key in (row["zpwina"], row["zpwino"], row["zpwiadr"]):
                        if key and key in all_query and key not in result:
                            result[key] = data

            remaining2 = [q for q in batch if q not in result]
            if remaining2:
                ph3 = ",".join("?" * len(remaining2))
                cur = conn.execute(
                    f"SELECT zpwina, zpwino, zpwiadr, zpcode, area_hdofc_nm, ons_team_nm "
                    f"FROM cert WHERE zpwiadr IN ({ph3})", remaining2)
                for row in cur:
                    data = {
                        "area_hdofc_nm": row["area_hdofc_nm"] or "",
                        "ons_team_nm": row["ons_team_nm"] or "",
                        "zpcode": row["zpcode"] or "",
                        "zpwiadr": row["zpwiadr"] or "",
                    }
                    for key in (row["zpwina"], row["zpwino"], row["zpwiadr"]):
                        if key and key in all_query and key not in result:
                            result[key] = data

        conn.close()
    except Exception as e:
        logger.warning(f"호출명칭 SQLite 매칭 실패, 스트리밍 fallback: {e}")
        return _query_callname_db_streaming(zpwina_values, zpwino_values)

    return result


def _query_callname_db_streaming(zpwina_values: list, zpwino_values: list) -> dict:
    """6방향 교차 매칭 — S3 CSV 스트리밍 fallback."""
    zpwina_set = set(str(v) for v in zpwina_values if v)
    zpwino_set = set(str(v) for v in zpwino_values if v)
    all_query = zpwina_set | zpwino_set
    if not all_query:
        return {}
    result = {}
    for row in _stream_s3_csvs():
        zpwino = row.get("zpwino", "")
        zpwina = row.get("zpwina", "")
        zpwiadr = row.get("zpwiadr", "")
        matched_keys = []
        if zpwina and zpwina in all_query:
            matched_keys.append(zpwina)
        if zpwino and zpwino in all_query:
            matched_keys.append(zpwino)
        if zpwiadr and zpwiadr in all_query:
            matched_keys.append(zpwiadr)
        if matched_keys:
            data = {
                "area_hdofc_nm": row.get("area_hdofc_nm", ""),
                "ons_team_nm": row.get("ons_team_nm", ""),
                "zpcode": row.get("zpcode", ""),
                "zpwiadr": row.get("zpwiadr", ""),
            }
            for k in matched_keys:
                if k not in result:
                    result[k] = data
        if len(result) >= len(all_query):
            break
    return result
