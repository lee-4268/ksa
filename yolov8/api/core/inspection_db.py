"""
inspection_db - inspection.db SQLite 스키마 초기화

담당 도메인: inspection_targets, inspection_results, inspection_schedules 등 전체 테이블 생성/마이그레이션
주요 의존성: core.config
엔드포인트: 없음 (공유 유틸리티)
"""

import sqlite3
import logging

from .config import _INSP_DB, _DS_DETAIL_DB

logger = logging.getLogger(__name__)


def _init_inspection_db():
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_targets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        year INTEGER, sheet TEXT,
        pnu_code TEXT, 허가번호 TEXT, 호출명칭 TEXT, 국종군 TEXT,
        부서 TEXT, 분기 TEXT, 연도주기 TEXT, 검사주기 INTEGER,
        허가상태 TEXT, 설치장소 TEXT, 도로명주소 TEXT, 장치수 INTEGER,
        통시 TEXT, 공대 TEXT, kca검토결과 TEXT, 시기조정 TEXT,
        기준연도 INTEGER, skt본부 TEXT, access담당 TEXT, 품질개선팀 TEXT,
        위도 REAL, 경도 REAL, 검사종류 TEXT DEFAULT ''
    )''')
    for col in ('위도 REAL', '경도 REAL', "검사종류 TEXT DEFAULT ''", "pre_check_status TEXT DEFAULT ''"):
        try: conn.execute(f'ALTER TABLE inspection_targets ADD COLUMN {col}')
        except Exception: pass
    # 사전대조: 일정 등록보다 앞서는 단계라 상태의 주인이 targets 다.
    #   '' → REQUESTED → IN_PROGRESS → (CHANGE_REQUESTED → CHANGE_FILED) → PRE_CHECKED
    #   PRE_CHECKED 인 대상만 일정 등록이 가능하다.
    #   schedules.workflow_status 는 일정 등록 이후(REGISTERED~) 만 담당한다.
    #   pre_check_batch: 본부담당자가 요청할 때 붙이는 묶음 이름. 사전대조 화면은
    #   이 묶음 단위로 목록을 보여준다(요청되지 않은 대상은 아예 안 보인다).
    for col in ("pre_check_requested_by TEXT DEFAULT ''",
                "pre_check_requested_at TEXT DEFAULT ''",
                "pre_check_done_by TEXT DEFAULT ''",
                "pre_check_done_at TEXT DEFAULT ''",
                "pre_check_result TEXT DEFAULT ''",
                "pre_check_batch TEXT DEFAULT ''"):
        try: conn.execute(f'ALTER TABLE inspection_targets ADD COLUMN {col}')
        except Exception: pass
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_precheck '
                 'ON inspection_targets(year, pre_check_status)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_pcbatch '
                 'ON inspection_targets(year, pre_check_batch)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_year ON inspection_targets(year)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_허가번호 ON inspection_targets(허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_분기 ON inspection_targets(분기)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_access ON inspection_targets(access담당)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_품질팀 ON inspection_targets(품질개선팀)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_skt본부 ON inspection_targets(skt본부)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_국종군 ON inspection_targets(국종군)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_year_허가번호 ON inspection_targets(year, 허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_year_access ON inspection_targets(year, access담당)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_it_year_team ON inspection_targets(year, 품질개선팀)')
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_targets_staging (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        year INTEGER, sheet TEXT,
        pnu_code TEXT, 허가번호 TEXT, 호출명칭 TEXT, 국종군 TEXT,
        부서 TEXT, 분기 TEXT, 연도주기 TEXT, 검사주기 INTEGER,
        허가상태 TEXT, 설치장소 TEXT, 도로명주소 TEXT, 장치수 INTEGER,
        통시 TEXT, 공대 TEXT, kca검토결과 TEXT, 시기조정 TEXT,
        기준연도 INTEGER, skt본부 TEXT, access담당 TEXT, 품질개선팀 TEXT,
        검사종류 TEXT DEFAULT ''
    )''')
    try: conn.execute("ALTER TABLE inspection_targets_staging ADD COLUMN 검사종류 TEXT DEFAULT ''")
    except Exception: pass
    conn.execute('CREATE INDEX IF NOT EXISTS idx_stg_year ON inspection_targets_staging(year)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_stg_access ON inspection_targets_staging(access담당)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_stg_team ON inspection_targets_staging(품질개선팀)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_stg_quarter ON inspection_targets_staging(분기)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_stg_nation ON inspection_targets_staging(국종군)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_stg_허가번호 ON inspection_targets_staging(허가번호)')
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_meta (
        year INTEGER PRIMARY KEY,
        sheet TEXT, total_skt INTEGER, total_sheet1 INTEGER,
        matched INTEGER, unmatched INTEGER,
        s3_key TEXT, filename TEXT, imported_by TEXT, imported_at TEXT
    )''')
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_jobs (
        job_id TEXT PRIMARY KEY,
        status TEXT, stage TEXT, percent REAL,
        total_skt INTEGER DEFAULT 0, total_sheet1 INTEGER DEFAULT 0,
        matched INTEGER DEFAULT 0, unmatched INTEGER DEFAULT 0,
        created_at TEXT, updated_at TEXT
    )''')
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_schedules (
        pk TEXT PRIMARY KEY,
        year INTEGER NOT NULL,
        허가번호 TEXT NOT NULL,
        호출명칭 TEXT, 분기 TEXT, skt본부 TEXT,
        access담당 TEXT, 품질개선팀 TEXT,
        수검예정주차 TEXT, 수검시작일 TEXT, 수검종료일 TEXT, 지역 TEXT,
        등록자 TEXT, 등록일시 TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_is_year ON inspection_schedules(year)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_is_access ON inspection_schedules(year, access담당)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_is_year_허가번호 ON inspection_schedules(year, 허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_is_year_week ON inspection_schedules(year, 수검예정주차)')
    for _col, _default in [("검사관", "''"), ("조", "''")]:
        try:
            conn.execute(f"ALTER TABLE inspection_schedules ADD COLUMN {_col} TEXT DEFAULT {_default}")
        except Exception:
            pass
    for _col, _default in [
        ("workflow_status", "'REGISTERED'"),
        ("status_updated_at", "''"),
        ("status_updated_by", "''"),
        ("pre_check_result", "''"),
        ("report_issued_at", "''"),
        ("report_issued_by", "''"),
        ("submission_no", "''"),
        ("submitted_at", "''"),
    ]:
        try:
            conn.execute(f"ALTER TABLE inspection_schedules ADD COLUMN {_col} TEXT DEFAULT {_default}")
        except Exception:
            pass
    conn.execute('CREATE INDEX IF NOT EXISTS idx_is_status ON inspection_schedules(year, workflow_status)')
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_status_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        schedule_pk TEXT NOT NULL,
        from_status TEXT,
        to_status TEXT NOT NULL,
        changed_by TEXT,
        changed_at TEXT NOT NULL,
        memo TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_isl_pk ON inspection_status_log(schedule_pk)')
    # 사전대조 전환 이력. 일정이 없는 단계라 schedule_pk 대신 year+허가번호로 건다.
    conn.execute('''CREATE TABLE IF NOT EXISTS pre_check_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        year INTEGER NOT NULL,
        허가번호 TEXT NOT NULL,
        from_status TEXT,
        to_status TEXT NOT NULL,
        changed_by TEXT,
        changed_at TEXT NOT NULL,
        memo TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_pcl_target '
                 'ON pre_check_log(year, 허가번호)')
    conn.execute('''CREATE TABLE IF NOT EXISTS change_request (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        schedule_pk TEXT NOT NULL,
        허가번호 TEXT NOT NULL,
        field TEXT NOT NULL,
        before_value TEXT,
        after_value TEXT NOT NULL,
        장치번호 TEXT,
        memo TEXT,
        status TEXT NOT NULL DEFAULT 'REQUESTED',
        requested_by TEXT,
        requested_at TEXT,
        filed_by TEXT,
        filed_at TEXT,
        applied_at TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_cr_pk ON change_request(schedule_pk)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_cr_status ON change_request(status)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_cr_license ON change_request(허가번호)')
    # 사전대조 단계의 변경신고는 일정이 아직 없다. schedule_pk 는 NOT NULL 이라
    #   '' 로 넣고 year 로 대상을 특정한다(year+허가번호 = targets 의 키).
    #   기존 일정 기반 요청은 schedule_pk 가 그대로 채워져 구분된다.
    for _col, _dflt in [('year', '0')]:
        try:
            conn.execute(f"ALTER TABLE change_request ADD COLUMN {_col} INTEGER DEFAULT {_dflt}")
        except Exception:
            pass
    conn.execute('CREATE INDEX IF NOT EXISTS idx_cr_year_license '
                 'ON change_request(year, 허가번호)')
    # 변경 요청 soft delete (REQUESTED 상태에서만 취소 가능)
    for _col, _dflt in [
        ('cancelled', "'0'"), ('cancelled_at', "''"), ('cancelled_by', "''"),
    ]:
        try:
            conn.execute(f"ALTER TABLE change_request ADD COLUMN {_col} TEXT DEFAULT {_dflt}")
        except Exception:
            pass
    conn.execute('''CREATE TABLE IF NOT EXISTS notifications (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT NOT NULL,
        schedule_pk TEXT,
        type TEXT NOT NULL,
        message TEXT NOT NULL,
        read_at TEXT,
        created_at TEXT NOT NULL,
        meta TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_n_user ON notifications(user_id, read_at)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_n_user_created ON notifications(user_id, created_at)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_n_pk ON notifications(schedule_pk)')
    try:
        conn.execute('''
            UPDATE inspection_schedules SET workflow_status='INSPECTED'
            WHERE (workflow_status IS NULL OR workflow_status='' OR workflow_status='REGISTERED')
              AND pk IN (
                SELECT pk FROM inspection_results
                WHERE 검사일 IS NOT NULL AND 검사일 != ''
              )
        ''')
    except Exception:
        pass
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_results (
        pk TEXT PRIMARY KEY,
        year INTEGER NOT NULL,
        허가번호 TEXT NOT NULL,
        status TEXT, 검사일 TEXT, 메모 TEXT, 철탑형태 TEXT,
        사진S3키 TEXT DEFAULT '[]',
        입력자 TEXT, 입력일시 TEXT
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_ir_year ON inspection_results(year)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_ir_status ON inspection_results(year, status)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_ir_year_허가번호 ON inspection_results(year, 허가번호)')
    for col, dflt in [
        ('진행여부', "''"),
        ('성능서류', "''"),
        ('불합격내용', "''"),
        ('불합격상세', "''"),
        ('공용화대상', "''"),
        ('간략불합격', "''"),
        ('기타사항', "''"),
        ('five_g_path', "''"),
        ('수검자', "''"),
        ('시스템', "''"),
        ('기지국구분', "''"),
        ('전파진흥원', "''"),
        ('검사관', "''"),
        ('주차별', "''"),
        ('schedule_pk', "''"),
        ('needs_recheck', "'0'"),
        ('사진업로더', "'{}'"),
    ]:
        try:
            conn.execute(f"ALTER TABLE inspection_results ADD COLUMN {col} TEXT DEFAULT {dflt}")
        except Exception:
            pass
    try:
        conn.execute('''
            UPDATE inspection_results
               SET schedule_pk = pk
             WHERE (schedule_pk IS NULL OR schedule_pk='')
               AND pk IN (SELECT pk FROM inspection_schedules)
        ''')
    except Exception:
        pass
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_results_raw (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        year INTEGER,
        region TEXT,
        skt본부 TEXT,
        주차별 TEXT,
        월 TEXT,
        허가번호 TEXT,
        통합시설코드 TEXT,
        호출명칭 TEXT,
        주소 TEXT,
        기지국구분 TEXT,
        시스템 TEXT,
        검사년도 TEXT,
        검사종류 TEXT,
        검사일자 TEXT,
        ons팀 TEXT,
        수검자 TEXT,
        전파진흥원 TEXT,
        검사관 TEXT,
        진행여부 TEXT,
        합불여부 TEXT,
        성능서류 TEXT,
        불합격내용 TEXT,
        불합격상세 TEXT,
        공용화대상 TEXT,
        기타사항 TEXT,
        간략불합격 TEXT,
        five_g_path TEXT,
        장비타입 TEXT,
        허가번호2 TEXT,
        허가번호text TEXT,
        제조주소명 TEXT,
        제조정보명 TEXT,
        검사지표정보명 TEXT,
        제조Type TEXT,
        장비명 TEXT,
        NAMS기타정보 TEXT,
        장비Type공용화 TEXT,
        NAMS설명정보 TEXT,
        장비Type2 TEXT,
        장비타입간소화 TEXT,
        uploaded_by TEXT,
        uploaded_at TEXT
    )''')
    try:
        conn.execute("ALTER TABLE inspection_results_raw ADD COLUMN 장비타입간소화 TEXT DEFAULT ''")
    except Exception:
        pass
    # V12 결과장 신설 2열 — V열 '부적합'(판정 전용), Y열 '부적합내용'(사유 분류)
    try:
        conn.execute("ALTER TABLE inspection_results_raw ADD COLUMN 부적합 TEXT DEFAULT ''")
    except Exception:
        pass
    try:
        conn.execute("ALTER TABLE inspection_results_raw ADD COLUMN 부적합내용 TEXT DEFAULT ''")
    except Exception:
        pass
    # 부적합 세부유형 미상건을 공용화로 수렴 (2026-09-09 운영 결정).
    #   결과장에 유형 근거가 없는 건을 '부적합(All)'로 두면 화면 칩에도 없는
    #   어휘가 남고 유형별 집계에서 따로 새므로, 공용화로 본다. _bf_status 의
    #   신규 판정 규칙과 짝을 맞추는 1회성 정리 — 변환 후엔 매칭 행이 없어 무해.
    try:
        conn.execute("UPDATE inspection_results SET status='부적합(공용화)' "
                     "WHERE status='부적합(All)'")
    except Exception:
        pass
    conn.execute('CREATE INDEX IF NOT EXISTS idx_irr_year ON inspection_results_raw(year)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_irr_region ON inspection_results_raw(region)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_irr_hn ON inspection_results_raw(허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_irr_month ON inspection_results_raw(월)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_irr_year_hn ON inspection_results_raw(year, 허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_irr_year_team ON inspection_results_raw(year, ons팀)')
    conn.execute('''CREATE TABLE IF NOT EXISTS inadequate_management (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        year INTEGER,
        허가번호 TEXT,
        통합시설코드 TEXT,
        호출명칭 TEXT,
        주소 TEXT,
        skt본부 TEXT,
        region TEXT,
        ons팀 TEXT,
        검사일자 TEXT,
        시정기한 TEXT,
        불합격내용 TEXT,
        불합격상세 TEXT,
        status TEXT DEFAULT '미완료',
        심의차수 TEXT DEFAULT '',
        updated_by TEXT DEFAULT '',
        updated_at TEXT DEFAULT '',
        UNIQUE(year, 허가번호)
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_inad_year ON inadequate_management(year)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_inad_region ON inadequate_management(region)')
    conn.execute('''CREATE TABLE IF NOT EXISTS inspection_target_overrides (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        year INTEGER NOT NULL,
        허가번호 TEXT NOT NULL,
        field TEXT NOT NULL,
        value TEXT NOT NULL,
        original_value TEXT DEFAULT '',
        changed_by TEXT DEFAULT '',
        changed_at TEXT DEFAULT '',
        reason TEXT DEFAULT '',
        UNIQUE(year, 허가번호, field)
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_ito_year ON inspection_target_overrides(year)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_ito_hn ON inspection_target_overrides(year, 허가번호)')
    conn.execute('''CREATE TABLE IF NOT EXISTS special_sites (
        허가번호 TEXT PRIMARY KEY,
        유형 TEXT NOT NULL,
        메모 TEXT DEFAULT '',
        등록자 TEXT DEFAULT '',
        등록일시 TEXT DEFAULT ''
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_ss_유형 ON special_sites(유형)')
    conn.execute('''CREATE TABLE IF NOT EXISTS menu_usage_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT,
        user_name TEXT,
        menu_name TEXT,
        accessed_at TEXT
    )''')
    # kca 에서 브라우저 릴레이로 받은 (허가번호, 통시) 일련번호 보충분.
    #   cert 캐시는 사람이 올린 엑셀 스냅샷에서 24시간마다 통째로 재생성되므로
    #   거기 써넣으면 날아간다. 영속 DB 인 여기에 따로 둔다.
    #   MiBOS/RRU 일련번호는 cronjob(Playground)에서만 채워지는데 ksa 가 읽는
    #   엑셀 스냅샷은 그 기능 도입(2026-07) 이전 것이라 구조적으로 비어 있다.
    conn.execute('''CREATE TABLE IF NOT EXISTS serial_supplement (
        허가번호 TEXT NOT NULL,
        통시 TEXT NOT NULL DEFAULT '',
        eqp_ser_no TEXT,
        updated_at TEXT,
        PRIMARY KEY (허가번호, 통시)
    )''')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_ss_hn ON serial_supplement(허가번호)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_mul_menu ON menu_usage_log(menu_name)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_mul_user ON menu_usage_log(user_id)')
    conn.execute('CREATE INDEX IF NOT EXISTS idx_mul_date ON menu_usage_log(accessed_at)')
    conn.execute(
        "DELETE FROM inspection_jobs WHERE status IN ('complete','error') "
        "AND updated_at < datetime('now','-1 day')")
    conn.commit(); conn.close()


def _insp_job_write_sync(job_id: str, **kw):
    """inspection_jobs 테이블에 job 상태 upsert."""
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).isoformat()
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    existing = conn.execute(
        'SELECT job_id FROM inspection_jobs WHERE job_id=?', (job_id,)).fetchone()
    if existing:
        sets = ', '.join(f'{k}=?' for k in kw)
        vals = list(kw.values()) + [now, job_id]
        conn.execute(f'UPDATE inspection_jobs SET {sets}, updated_at=? WHERE job_id=?', vals)
    else:
        kw.setdefault('status', 'processing')
        kw.setdefault('stage', '대기 중...')
        kw.setdefault('percent', 0)
        cols = ', '.join(['job_id', 'created_at', 'updated_at'] + list(kw.keys()))
        placeholders = ', '.join(['?'] * (3 + len(kw)))
        vals = [job_id, now, now] + list(kw.values())
        conn.execute(f'INSERT OR REPLACE INTO inspection_jobs ({cols}) VALUES ({placeholders})', vals)
    conn.commit(); conn.close()


def _insp_job_read_sync(job_id: str):
    conn = sqlite3.connect(_INSP_DB, timeout=60)
    conn.row_factory = sqlite3.Row
    row = conn.execute(
        'SELECT * FROM inspection_jobs WHERE job_id=?', (job_id,)).fetchone()
    conn.close()
    return dict(row) if row else None
