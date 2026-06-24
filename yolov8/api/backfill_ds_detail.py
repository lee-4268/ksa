"""
DS detail DB 백필 스크립트
kca-ds-uploads에서 완료된 업로드 목록을 읽고
S3 ZIP을 다운로드하여 일반사항/장치/안테나 파싱 → ds_detail.db 생성

사용법:
    cd ~/kca/yolov8/api   (main.py와 같은 디렉토리)
    python3 backfill_ds_detail.py
"""

import os, sqlite3, boto3, zipfile, tempfile
from decimal import Decimal
from boto3.dynamodb.conditions import Key

# ── 설정 ────────────────────────────────────────────────────────────────────
REGION          = os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-2")
DS_UPLOADS_TABLE = os.environ.get("DYNAMODB_DS_UPLOADS_TABLE", "kca-ds-uploads")
S3_BUCKET       = os.environ.get("S3_BUCKET_NAME", "sko-kca-s3")
DS_DETAIL_DB    = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ds_detail.db")

try:
    import xlrd
    HAS_XLRD = True
except ImportError:
    HAS_XLRD = False
    print("ERROR: xlrd 미설치. pip install xlrd==1.2.0")
    exit(1)

# ── SQLite 초기화 ─────────────────────────────────────────────────────────────
def init_db(conn):
    conn.execute('''CREATE TABLE IF NOT EXISTS ds_일반사항 (
        허가번호 TEXT PRIMARY KEY, 무선국명 TEXT, 호출명칭 TEXT, 통합시설명칭 TEXT
    )''')
    conn.execute('''CREATE TABLE IF NOT EXISTS ds_장치 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        허가번호 TEXT, 장치번호 TEXT, 기기일련번호 TEXT
    )''')
    conn.execute('''CREATE TABLE IF NOT EXISTS ds_안테나 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        허가번호 TEXT, 장치번호 TEXT,
        기 TEXT, 이득 TEXT, 공중선주설치형태명 TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_dsd_일반 ON ds_일반사항(허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_dsd_장치 ON ds_장치(허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_dsd_안테나 ON ds_안테나(허가번호)')
    conn.commit()

# ── 헬퍼 ─────────────────────────────────────────────────────────────────────
def _col_idx(ws, *names):
    for name in names:
        for c in range(ws.ncols):
            if str(ws.cell_value(0, c)).strip() == name:
                return c
    return -1

def _fix_zip_filename(name: str) -> str:
    """CP437 인코딩 한글 복원 시도"""
    try:
        return name.encode('cp437').decode('euc-kr')
    except Exception:
        return name

# ── ZIP 파싱 → SQLite 삽입 ────────────────────────────────────────────────────
def process_zip(zip_path: str, conn: sqlite3.Connection, label: str):
    일반_cnt = 장치_cnt = 안테나_cnt = 0

    with zipfile.ZipFile(zip_path, 'r') as zf:
        all_names = zf.namelist()
        name_map = {n: _fix_zip_filename(n) for n in all_names}
        xls_names = [n for n in all_names
                     if name_map[n].lower().endswith('.xls')
                     and not os.path.basename(name_map[n]).startswith(('~', '.'))]

        for entry in xls_names:
            fixed = name_map[entry]
            basename = os.path.basename(fixed)
            try:
                raw = zf.read(entry)
                wb = xlrd.open_workbook(file_contents=raw, on_demand=True)
                sheet_names = wb.sheet_names()

                # ── 일반사항 ──────────────────────────────────────────────────
                if '일반사항' in sheet_names:
                    ws = wb.sheet_by_name('일반사항')
                    hi = _col_idx(ws, '허가번호')
                    mi = _col_idx(ws, '무선국명')
                    ci = _col_idx(ws, '호출명칭')
                    zi = _col_idx(ws, '통합시설명칭')
                    batch = []
                    for r in range(1, ws.nrows):
                        h = str(ws.cell_value(r, hi) or '').strip() if hi >= 0 else ''
                        m = str(ws.cell_value(r, mi) or '').strip() if mi >= 0 else ''
                        c = str(ws.cell_value(r, ci) or '').strip() if ci >= 0 else ''
                        z = str(ws.cell_value(r, zi) or '').strip() if zi >= 0 else ''
                        if h:
                            batch.append((h, m, c, z))
                    if batch:
                        conn.executemany(
                            'INSERT OR REPLACE INTO ds_일반사항(허가번호,무선국명,호출명칭,통합시설명칭) VALUES(?,?,?,?)',
                            batch)
                        일반_cnt += len(batch)

                # ── 장치 ──────────────────────────────────────────────────────
                if '장치' in sheet_names:
                    ws = wb.sheet_by_name('장치')
                    hi = _col_idx(ws, '허가번호')
                    ji = _col_idx(ws, '장치번호')
                    si = _col_idx(ws, '기기일련번호')
                    batch = []
                    for r in range(1, ws.nrows):
                        h = str(ws.cell_value(r, hi) or '').strip() if hi >= 0 else ''
                        j = str(ws.cell_value(r, ji) or '').strip() if ji >= 0 else ''
                        s = str(ws.cell_value(r, si) or '').strip() if si >= 0 else ''
                        if h and s:
                            batch.append((h, j, s))
                    if batch:
                        conn.executemany(
                            'INSERT INTO ds_장치(허가번호,장치번호,기기일련번호) VALUES(?,?,?)',
                            batch)
                        장치_cnt += len(batch)

                # ── 안테나 ────────────────────────────────────────────────────
                if '안테나' in sheet_names:
                    ws = wb.sheet_by_name('안테나')
                    hi = _col_idx(ws, '허가번호')
                    ji = _col_idx(ws, '장치번호')
                    ki = _col_idx(ws, '기')
                    ei = _col_idx(ws, '이득')
                    pi = _col_idx(ws, '공중선주 설치형태명', '공중선주설치형태명', '안테나설치대 설치형태명', '안테나설치대설치형태명')
                    batch = []
                    for r in range(1, ws.nrows):
                        h = str(ws.cell_value(r, hi) or '').strip() if hi >= 0 else ''
                        j = str(ws.cell_value(r, ji) or '').strip() if ji >= 0 else ''
                        k = str(ws.cell_value(r, ki) or '').strip() if ki >= 0 else ''
                        e = str(ws.cell_value(r, ei) or '').strip() if ei >= 0 else ''
                        p = str(ws.cell_value(r, pi) or '').strip() if pi >= 0 else ''
                        if h:
                            batch.append((h, j, k, e, p))
                    if batch:
                        conn.executemany(
                            'INSERT INTO ds_안테나(허가번호,장치번호,기,이득,공중선주설치형태명) VALUES(?,?,?,?,?)',
                            batch)
                        안테나_cnt += len(batch)

                wb.release_resources()
            except Exception as xe:
                print(f"  XLS 파싱 오류 ({basename}): {xe}")

    conn.commit()
    print(f"  → 일반사항 {일반_cnt}건 / 장치 {장치_cnt}건 / 안테나 {안테나_cnt}건")
    return 일반_cnt, 장치_cnt, 안테나_cnt

# ── 메인 ─────────────────────────────────────────────────────────────────────
def main():
    print(f"대상 DB: {DS_DETAIL_DB}")
    print(f"S3 버킷: {S3_BUCKET}")

    dynamodb = boto3.resource("dynamodb", region_name=REGION)
    s3 = boto3.client("s3", region_name=REGION)
    uploads_table = dynamodb.Table(DS_UPLOADS_TABLE)
    conn = sqlite3.connect(DS_DETAIL_DB)
    init_db(conn)

    # 기존 데이터 초기화
    print("기존 ds_detail.db 데이터 초기화 중...")
    conn.execute("DELETE FROM ds_일반사항")
    conn.execute("DELETE FROM ds_장치")
    conn.execute("DELETE FROM ds_안테나")
    conn.commit()

    # kca-ds-uploads 전체 스캔
    print("kca-ds-uploads 스캔 중...")
    items = []
    kwargs = {}
    while True:
        resp = uploads_table.scan(**kwargs)
        items.extend(resp.get("Items", []))
        lek = resp.get("LastEvaluatedKey")
        if not lek:
            break
        kwargs["ExclusiveStartKey"] = lek

    completed = [i for i in items if i.get("status") == "completed"]
    print(f"완료된 업로드: {len(completed)}건\n")

    총_일반 = 총_장치 = 총_안테나 = 0

    for item in completed:
        div_id   = item.get("divisionId", "")
        sk       = item.get("importDate", "")   # divisionCode#importDate
        storage  = item.get("storageType", "")
        parts    = sk.split("#")
        div_code = parts[0] if len(parts) >= 2 else ""
        imp_date = parts[1] if len(parts) >= 2 else sk

        label = f"{div_id} / {sk} (storageType={storage})"
        print(f"[{label}]")

        if storage == "s3-zip":
            s3_key = f"ds-raw/{div_id}/{div_code}_{imp_date}.zip"
            tmp_path = f"/tmp/backfill_{div_id}_{div_code}_{imp_date}.zip"
            try:
                print(f"  S3 다운로드: {s3_key}")
                s3.download_file(S3_BUCKET, s3_key, tmp_path)
                a, b, c = process_zip(tmp_path, conn, label)
                총_일반 += a; 총_장치 += b; 총_안테나 += c
            except Exception as e:
                print(f"  오류: {e}")
            finally:
                if os.path.exists(tmp_path):
                    os.remove(tmp_path)

        elif storage in ("", "dynamodb"):
            # 이미 DynamoDB에 있으면 이전 방식대로 처리 (경북 등)
            print(f"  DynamoDB 저장 방식 — 별도 스크립트로 처리됨 (스킵)")

        else:
            print(f"  알 수 없는 storageType: {storage} — 스킵")

    conn.close()
    print(f"\n=== 완료 ===")
    print(f"일반사항 {총_일반}건 / 장치 {총_장치}건 / 안테나 {총_안테나}건")
    print(f"DB 크기: {os.path.getsize(DS_DETAIL_DB):,} bytes")

if __name__ == "__main__":
    main()
