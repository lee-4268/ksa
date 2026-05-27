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


def _learn_addr_map_from_cert_db(db_path: str = "") -> dict:
    """cert SQLite DB에서 주소→팀 학습 맵 빌드."""
    addr_map = {}
    _db = db_path or _cert_cache_db_path
    if not _db or not os.path.exists(_db):
        return addr_map
    try:
        conn = sqlite3.connect(_db, timeout=30)
        conn.row_factory = sqlite3.Row
        for row in conn.execute("SELECT zpwiadr, area_hdofc_nm, ons_team_nm FROM cert WHERE zpwiadr != ''"):
            addr = row["zpwiadr"] or ""
            access = row["area_hdofc_nm"] or ""
            team = row["ons_team_nm"] or ""
            if not addr or not (access or team):
                continue
            parts = addr.split()
            for i in range(len(parts)):
                key = " ".join(parts[i:i+2]) if i + 1 < len(parts) else parts[i]
                if len(key) >= 3 and key not in addr_map:
                    addr_map[key] = {"access": access, "team": team}
        conn.close()
    except Exception as e:
        logger.warning(f"주소→팀 학습 맵 빌드 실패: {e}")
    return addr_map


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

        import json as _jw
        _addr_cache = os.path.join(_tempfile.gettempdir(), "learned_addr_map.json")
        _should_warm = True
        if os.path.exists(_addr_cache):
            try:
                _age = _time_mod.time() - os.path.getmtime(_addr_cache)
                if _age < 86400:
                    with open(_addr_cache, 'r', encoding='utf-8') as _f:
                        _existing = _jw.load(_f)
                    if _existing:
                        _should_warm = False
            except Exception:
                pass
        if _should_warm:
            _addr_map = _learn_addr_map_from_cert_db(db_path=db_path)
            with open(_addr_cache, 'w', encoding='utf-8') as _f:
                _jw.dump(_addr_map, _f, ensure_ascii=False)
            logger.info(f"주소→팀 학습 맵 워밍업 완료: {len(_addr_map)}개 키워드")


def _cert_cache_force_rebuild():
    """캐시 TTL 무시하고 강제 재빌드."""
    global _cert_cache_ts
    _cert_cache_ts = 0.0
    _cert_cache_load()


def _cert_lookup_cached(query: str) -> dict:
    """설치확인서 단건 조회 — SQLite 인덱스 O(1) 조회."""
    if not query or not query.strip():
        return {}
    _cert_cache_load()
    q = query.strip()
    cols = ["zpwino", "zpwina", "zpwiadr", "zpcode", "zpkcode", "zpcname", "area_hdofc_nm", "ons_team_nm", "zpirty3", "eqp_ser_no"]
    try:
        conn = sqlite3.connect(_cert_cache_db_path)
        conn.row_factory = sqlite3.Row
        for col in ("zpwino", "zpwina", "zpwiadr"):
            cur = conn.execute(f"SELECT * FROM cert WHERE {col}=? LIMIT 1", (q,))
            row = cur.fetchone()
            if row:
                result = {c: (row[c] or "") for c in cols}
                conn.close()
                return result
        conn.close()
    except Exception as e:
        logger.warning(f"설치확인서 캐시 조회 실패: {e}")
    return {}


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
