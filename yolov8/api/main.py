"""
main - FastAPI 앱 초기화 + 라우터 등록

구조:
    core/       - config, auth, sso_verify, db, s3, utils, model, cert_cache, inspection_db
    schemas/    - 모든 Pydantic 모델 (schemas/models.py)
    routers/    - 14개 도메인 라우터 (auth, users, predict, categories, stations,
                  storage, ds, callname, cert, inspection, inspection_results,
                  community, document, change_request, inadequate, route_basket,
                  admin)

신규 팀원 가이드:
    1. 엔드포인트 추가 → 해당 routers/*.py 에 @router.get/post 추가
    2. 공유 유틸 → core/*.py 에 함수 추가
    3. Pydantic 모델 → schemas/models.py 에 클래스 추가
    4. 환경변수 → core/config.py 에 os.environ.get() 으로 추가
    5. 보안: 모든 엔드포인트에 await _verify_auth(request) 필수
             SQL은 ? 파라미터 바인딩만 사용 (f-string 금지)
"""

import asyncio
import logging
import os
import sqlite3
import tempfile
import stat

from datetime import datetime, timezone, timedelta
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.gzip import GZipMiddleware

# ── core 모듈 ─────────────────────────────────────────────────
from core.config import (
    APP_ENV, IS_PROD,
    ALLOWED_ORIGINS,
    S3_BUCKET_NAME,
    _INSP_DB, _DS_DETAIL_DB, _COMMUNITY_DB, _SISL_PHOTO_DB,
    _SQLITE_BACKUP_RETAIN_DAYS,
)
from core.auth import (
    _ensure_audit_table, _ensure_user_roles_table, _ensure_route_baskets_table,
)
from core.db import get_s3_client
from core.cert_cache import _cert_cache_load, _cert_cache_force_rebuild
from core.utils import _rate_limiter, _cleanup_stale_temp_files
from core.inspection_db import _init_inspection_db

# ── 라우터 임포트 ─────────────────────────────────────────────
from routers import (
    auth as auth_router,
    users as users_router,
    predict as predict_router,
    categories as categories_router,
    stations as stations_router,
    storage as storage_router,
    ds as ds_router,
    callname as callname_router,
    cert as cert_router,
    inspection as inspection_router,
    inspection_results as inspection_results_router,
    community as community_router,
    document as document_router,
    change_request as change_request_router,
    pre_check as pre_check_router,
    inadequate as inadequate_router,
    route_basket as route_basket_router,
    admin as admin_router,
    sisl_photos as sisl_photos_router,
    special_sites as special_sites_router,
)
from routers.callname import _cleanup_callname_sessions
from routers.ds import (
    _ensure_ds_jobs_table, _recover_stuck_jobs, _job_worker_loop,
    _scan_missing_xlsx_caches_sync,
)

try:
    import psutil
    HAS_PSUTIL = True
except ImportError:
    HAS_PSUTIL = False

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)

# ── FastAPI 앱 ────────────────────────────────────────────────
_docs_url   = None if IS_PROD else "/docs"
_redoc_url  = None if IS_PROD else "/redoc"
_openapi_url = None if IS_PROD else "/openapi.json"

app = FastAPI(
    title="Tower Classification API",
    description="API for classifying tower/antenna installation types using YOLOv8",
    version="1.0.0",
    docs_url=_docs_url,
    redoc_url=_redoc_url,
    openapi_url=_openapi_url,
)

logger.info(f"APP_ENV={APP_ENV} (IS_PROD={IS_PROD}) — /docs {'비공개' if IS_PROD else '공개'}")

# ── CORS ─────────────────────────────────────────────────────
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Accept", "X-Filename", "X-Refreshed-Token"],
    expose_headers=[
        "Content-Length",
        "Content-Disposition",
        "X-Change-Count",
        "X-Target-Count",
        "X-Change-Types",
    ],
    max_age=3600,
)

# ── GZip 압축 ─────────────────────────────────────────────────
app.add_middleware(GZipMiddleware, minimum_size=1000)


# ── 미들웨어 ─────────────────────────────────────────────────

@app.middleware("http")
async def token_refresh_middleware(request: Request, call_next):
    """인증된 요청의 토큰 잔여 수명이 절반 이하이면 응답 헤더에 새 토큰 포함."""
    request.state.refreshed_token = None
    response = await call_next(request)
    refreshed = getattr(request.state, "refreshed_token", None)
    if refreshed:
        response.headers["X-Refreshed-Token"] = refreshed
    return response


@app.middleware("http")
async def security_headers_middleware(request: Request, call_next):
    """모든 응답에 표준 보안 헤더 주입 (XSS·clickjacking·MIME sniffing 방어)."""
    response = await call_next(request)
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("Referrer-Policy", "same-origin")
    response.headers.setdefault(
        "Content-Security-Policy",
        "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' https://dapi.kakao.com https://*.kakao.com; "
        "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https:; connect-src 'self' https:; frame-ancestors 'none';",
    )
    response.headers["Server"] = "KSA"
    if IS_PROD:
        response.headers.setdefault(
            "Strict-Transport-Security",
            "max-age=31536000; includeSubDomains",
        )
    return response


# ── 라우터 등록 ───────────────────────────────────────────────
app.include_router(auth_router.router)
app.include_router(users_router.router)
app.include_router(predict_router.router)
app.include_router(categories_router.router)
app.include_router(stations_router.router)
app.include_router(storage_router.router)
app.include_router(ds_router.router)
app.include_router(callname_router.router)
app.include_router(cert_router.router)
app.include_router(inspection_router.router)
app.include_router(inspection_results_router.router)
app.include_router(community_router.router)
app.include_router(document_router.router)
app.include_router(change_request_router.router)
app.include_router(pre_check_router.router)
app.include_router(inadequate_router.router)
app.include_router(route_basket_router.router)
app.include_router(admin_router.router)
app.include_router(sisl_photos_router.router)
app.include_router(special_sites_router.router)


# ══════════════════════════════════════════════════════════════
# SQLite S3 백업 (매일 03:00 KST)
# ── 미이전 유틸: 향후 core/backup.py 또는 routers/admin.py로 이동 예정
# ══════════════════════════════════════════════════════════════

_SQLITE_BACKUP_DBS = [
    ("inspection", lambda: _INSP_DB),
    ("ds_detail",  lambda: _DS_DETAIL_DB),
    ("community",  lambda: _COMMUNITY_DB),
    ("sisl_photo", lambda: _SISL_PHOTO_DB),
]


def _backup_sqlite_to_s3_sync():
    """각 SQLite DB를 S3에 날짜별 백업. 7일치 초과 파일 자동 삭제.

    보안: mkstemp으로 0600 권한 임시파일 생성, 완료 후 즉시 삭제.
    systemd PrivateTmp=true 와 함께 사용 시 /tmp 자체가 서비스별 격리됨.
    """
    import sqlite3 as _sq3
    KST = timezone(timedelta(hours=9))
    date_str = datetime.now(KST).strftime("%Y-%m-%d")
    s3 = get_s3_client()

    backup_dir = os.environ.get("BACKUP_TMP_DIR", "")
    if not backup_dir or not os.path.isdir(backup_dir):
        backup_dir = tempfile.gettempdir()

    for name, path_fn in _SQLITE_BACKUP_DBS:
        db_path = path_fn()
        if not db_path or not os.path.exists(db_path):
            continue
        fd, tmp = tempfile.mkstemp(dir=backup_dir, prefix=f"sqlite_backup_{name}_", suffix=".db")
        os.close(fd)
        try:
            os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)  # 0600
        except Exception:
            pass
        try:
            src = _sq3.connect(db_path, timeout=30)
            dst = _sq3.connect(tmp)
            src.backup(dst)
            dst.close(); src.close()

            s3_key = f"backups/sqlite/{name}/{date_str}.db"
            s3.upload_file(tmp, S3_BUCKET_NAME, s3_key)
            logger.info(f"SQLite 백업 완료: {s3_key} ({os.path.getsize(tmp):,} bytes)")

            cutoff = datetime.now(KST) - timedelta(days=_SQLITE_BACKUP_RETAIN_DAYS)
            prefix = f"backups/sqlite/{name}/"
            resp = s3.list_objects_v2(Bucket=S3_BUCKET_NAME, Prefix=prefix)
            for obj in resp.get("Contents", []):
                key = obj["Key"]
                fname = os.path.basename(key).replace(".db", "")
                try:
                    obj_date = datetime.strptime(fname, "%Y-%m-%d").replace(tzinfo=KST)
                    if obj_date < cutoff:
                        s3.delete_object(Bucket=S3_BUCKET_NAME, Key=key)
                        logger.info(f"오래된 백업 삭제: {key}")
                except ValueError:
                    pass
        except Exception as e:
            logger.error(f"SQLite 백업 실패 ({name}): {e}")
        finally:
            if os.path.exists(tmp):
                try:
                    os.remove(tmp)
                except Exception as _re:
                    logger.warning(f"백업 임시파일 정리 실패 {tmp}: {_re}")


async def _sqlite_backup_daily_scheduler():
    """매일 03:00 KST SQLite → S3 자동 백업."""
    KST = timezone(timedelta(hours=9))
    while True:
        now = datetime.now(KST)
        next_run = (now + timedelta(days=1)).replace(hour=3, minute=0, second=0, microsecond=0)
        if now.hour < 3:
            next_run = now.replace(hour=3, minute=0, second=0, microsecond=0)
        wait_seconds = (next_run - now).total_seconds()
        logger.info(f"SQLite 백업 다음 실행: {next_run.strftime('%Y-%m-%d %H:%M')} KST ({wait_seconds:.0f}초 후)")
        await asyncio.sleep(wait_seconds)
        await asyncio.to_thread(_backup_sqlite_to_s3_sync)


# ══════════════════════════════════════════════════════════════
# 휴면계정 관리 (매일 09:00 KST)
# ── 미이전 유틸: 향후 routers/users.py 또는 routers/admin.py로 이동 예정
# ══════════════════════════════════════════════════════════════

_SES_FROM_EMAIL = os.getenv("SES_FROM_EMAIL", "noreply@ksa.skons.net")
_DORMANT_DAYS   = int(os.getenv("DORMANT_DAYS", "30"))
_SERVICE_NAME   = os.getenv("SERVICE_NAME", "KSA 무선국 정기검사 관리 시스템")
_SERVICE_URL    = os.getenv("SERVICE_URL",  "https://ksa.skons.net")


def _send_ses_email(to_address: str, subject: str, body_html: str) -> bool:
    """AWS SES로 이메일 발송."""
    try:
        import boto3 as _boto3
        ses = _boto3.client("ses", region_name=os.environ.get("AWS_REGION", "ap-northeast-2"))
        ses.send_email(
            Source=_SES_FROM_EMAIL,
            Destination={"ToAddresses": [to_address]},
            Message={
                "Subject": {"Data": subject, "Charset": "UTF-8"},
                "Body": {"Html": {"Data": body_html, "Charset": "UTF-8"}},
            },
        )
        return True
    except Exception as e:
        logger.error(f"SES 이메일 발송 실패 ({to_address}): {e}")
        return False


def _dormant_email_html(name: str, days_left: int, last_login_str: str) -> str:
    """휴면 예고 메일 HTML 본문 생성."""
    color = "#E53935" if days_left == 1 else ("#FF7043" if days_left == 3 else "#FFA726")
    return f"""<!DOCTYPE html>
<html lang="ko"><head><meta charset="UTF-8"></head>
<body style="font-family:'Apple SD Gothic Neo',sans-serif;background:#f5f5f5;padding:0;margin:0;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f5f5f5;padding:30px 0;">
    <tr><td align="center">
      <table width="600" cellpadding="0" cellspacing="0"
             style="background:#fff;border-radius:12px;overflow:hidden;box-shadow:0 2px 8px rgba(0,0,0,.1);">
        <tr><td style="background:{color};padding:28px 32px;">
          <p style="margin:0;color:#fff;font-size:20px;font-weight:700;">{_SERVICE_NAME}</p>
          <p style="margin:6px 0 0;color:rgba(255,255,255,.85);font-size:13px;">휴면계정 전환 예정 안내</p>
        </td></tr>
        <tr><td style="padding:32px 32px 24px;">
          <p style="margin:0 0 16px;font-size:15px;color:#111827;">안녕하세요, <strong>{name}</strong>님.</p>
          <p style="margin:0 0 16px;font-size:14px;color:#374151;line-height:1.7;">
            마지막 로그인 일시(<strong>{last_login_str}</strong>) 기준으로<br>
            <strong style="color:{color};">{days_left}일 후</strong> 계정이 자동으로 <strong>휴면 상태</strong>로 전환됩니다.
          </p>
          <table cellpadding="0" cellspacing="0"><tr>
            <td style="background:{color};border-radius:8px;padding:12px 28px;">
              <a href="{_SERVICE_URL}" style="color:#fff;text-decoration:none;font-size:14px;font-weight:700;">지금 로그인하기</a>
            </td>
          </tr></table>
        </td></tr>
        <tr><td style="padding:16px 32px;border-top:1px solid #E5E7EB;background:#FAFAFA;font-size:12px;color:#9CA3AF;">
          본 메일은 발신 전용입니다. 문의는 시스템 관리자에게 연락해 주세요.<br>ⓒ {_SERVICE_NAME}
        </td></tr>
      </table>
    </td></tr>
  </table>
</body></html>"""


def _run_dormant_job_sync():
    """휴면계정 배치 (동기, 스레드에서 실행).

    kca-user-roles 전체 scan → last_login 기준:
    - 30일 초과 → is_dormant=true 전환
    - D-7/D-3/D-1 → 예고 메일 발송 (중복 방지 플래그 저장)
    """
    from core.db import get_dynamodb_resource
    from core.config import DYNAMODB_TABLES

    try:
        dynamodb = get_dynamodb_resource()
        roles_table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        users_table = dynamodb.Table(DYNAMODB_TABLES["users"])

        now = datetime.now(timezone.utc)
        notify_days = [7, 3, 1]

        items = []
        resp = roles_table.scan(
            ProjectionExpression="user_id, #r, last_login, is_dormant",
            ExpressionAttributeNames={"#r": "role"},
        )
        items.extend(resp.get("Items", []))
        while "LastEvaluatedKey" in resp:
            resp = roles_table.scan(
                ProjectionExpression="user_id, #r, last_login, is_dormant",
                ExpressionAttributeNames={"#r": "role"},
                ExclusiveStartKey=resp["LastEvaluatedKey"],
            )
            items.extend(resp.get("Items", []))

        converted, notified = 0, 0
        for item in items:
            empno      = item.get("user_id", "")
            last_login = item.get("last_login", "")
            is_dormant = item.get("is_dormant", False)

            if not last_login or is_dormant:
                continue

            try:
                last_dt = datetime.fromisoformat(last_login)
                if last_dt.tzinfo is None:
                    last_dt = last_dt.replace(tzinfo=timezone.utc)
            except ValueError:
                continue

            elapsed_days = (now - last_dt).days

            if elapsed_days >= _DORMANT_DAYS:
                roles_table.update_item(
                    Key={"user_id": empno},
                    UpdateExpression="SET is_dormant = :v",
                    ExpressionAttributeValues={":v": True},
                )
                logger.info(f"휴면 전환: {empno} (미접속 {elapsed_days}일)")
                converted += 1
                continue

            days_left = _DORMANT_DAYS - elapsed_days
            if days_left not in notify_days:
                continue

            notified_key = f"notified_d{days_left}"
            if item.get(notified_key):
                continue

            try:
                user_resp = users_table.get_item(
                    Key={"user_id": empno},
                    ProjectionExpression="#n, email",
                    ExpressionAttributeNames={"#n": "name"},
                )
                user  = user_resp.get("Item", {})
                email = user.get("email", "")
                name  = user.get("name", empno)
            except Exception:
                continue

            if not email:
                continue

            last_login_kst = (last_dt + timedelta(hours=9)).strftime("%Y-%m-%d %H:%M")
            subject = f"[{_SERVICE_NAME}] 휴면계정 전환 {days_left}일 전 안내"
            html    = _dormant_email_html(name, days_left, last_login_kst)

            if _send_ses_email(email, subject, html):
                roles_table.update_item(
                    Key={"user_id": empno},
                    UpdateExpression=f"SET {notified_key} = :v",
                    ExpressionAttributeValues={":v": True},
                )
                logger.info(f"휴면 예고 메일 발송: {empno} → {email} (D-{days_left})")
                notified += 1

        logger.info(f"휴면계정 배치 완료 — 전환: {converted}명, 예고 메일: {notified}건")

    except Exception as e:
        logger.error(f"휴면계정 배치 오류: {e}")


async def _dormant_account_daily_scheduler():
    """매일 09:00 KST 휴면계정 처리 실행."""
    KST = timezone(timedelta(hours=9))
    while True:
        now = datetime.now(KST)
        next_run = now.replace(hour=9, minute=0, second=0, microsecond=0)
        if now >= next_run:
            next_run += timedelta(days=1)
        wait_seconds = (next_run - now).total_seconds()
        logger.info(f"휴면계정 배치 다음 실행: {next_run.strftime('%Y-%m-%d %H:%M')} KST ({wait_seconds:.0f}초 후)")
        await asyncio.sleep(wait_seconds)
        await asyncio.to_thread(_run_dormant_job_sync)


# ══════════════════════════════════════════════════════════════
# 부적합 시정기한 알림 (매일 08:30 KST)
# ── 미이전 유틸: 향후 routers/inadequate.py로 이동 예정
# ══════════════════════════════════════════════════════════════

def _run_inadequate_deadline_notify_sync():
    """부적합 시정기한 D-60/D-30/D-14/D-7 해당 건을 조회하여
    해당 본부 manager에게 커뮤니티 알림을 발송한다."""
    from core.auth import _list_all_users_sync

    KST = timezone(timedelta(hours=9))
    today = datetime.now(KST).date()
    THRESHOLDS = [60, 30, 14, 7]

    conn_insp = sqlite3.connect(_INSP_DB, timeout=30)
    conn_insp.row_factory = sqlite3.Row
    try:
        rows = conn_insp.execute(
            "SELECT 허가번호, 호출명칭, region, skt본부, 시정기한 "
            "FROM inadequate_management "
            "WHERE status != '완료' AND 시정기한 != '' AND 시정기한 IS NOT NULL"
        ).fetchall()
    finally:
        conn_insp.close()

    if not rows:
        return

    targets = []
    for row in rows:
        try:
            deadline = datetime.strptime(row["시정기한"], "%Y-%m-%d").date()
            d_left = (deadline - today).days
            if d_left in THRESHOLDS:
                targets.append({
                    "region": row["region"] or row["skt본부"] or "",
                    "허가번호": row["허가번호"],
                    "호출명칭": row["호출명칭"] or "",
                    "시정기한": row["시정기한"],
                    "d_left": d_left,
                })
        except Exception:
            continue

    if not targets:
        return

    logger.info(f"부적합 시정기한 알림 대상: {len(targets)}건")

    try:
        all_users = _list_all_users_sync()
    except Exception as e:
        logger.error(f"부적합 알림: 사용자 목록 조회 실패: {e}")
        return

    region_managers: dict = {}
    for u in all_users:
        if u.get("role") not in ("manager", "admin"):
            continue
        if u.get("is_dormant"):
            continue
        r = (u.get("region") or "").strip()
        if not r:
            continue
        region_managers.setdefault(r, []).append(u["empno"])

    conn_comm = sqlite3.connect(_COMMUNITY_DB, timeout=30)
    try:
        _now = datetime.now(timezone.utc).isoformat()
        inserted = 0
        for item in targets:
            region = item["region"]
            d_left = item["d_left"]
            허가번호 = item["허가번호"]
            호출명칭 = item["호출명칭"]
            시정기한 = item["시정기한"]

            matched_empnos = []
            for r_key, empnos in region_managers.items():
                if region in r_key or r_key in region:
                    matched_empnos.extend(empnos)

            if not matched_empnos:
                logger.warning(f"부적합 알림: region '{region}' 매칭 manager 없음 ({허가번호})")
                continue

            title = f"부적합 시정기한 D-{d_left} 알림"
            body  = f"[{region}] {호출명칭} ({허가번호}) 시정기한: {시정기한}"

            for empno in set(matched_empnos):
                already = conn_comm.execute(
                    "SELECT id FROM notifications "
                    "WHERE user_empno=? AND title=? AND body=? AND DATE(created_at)=DATE(?)",
                    (empno, title, body, _now),
                ).fetchone()
                if already:
                    continue
                conn_comm.execute(
                    "INSERT INTO notifications "
                    "(user_empno, type, title, body, related_type, related_id, created_at) "
                    "VALUES (?, 'deadline', ?, ?, 'inadequate', 0, ?)",
                    (empno, title, body, _now),
                )
                inserted += 1

        conn_comm.commit()
        logger.info(f"부적합 시정기한 알림 INSERT: {inserted}건")
    finally:
        conn_comm.close()


async def _inadequate_deadline_scheduler():
    """매일 08:30 KST 부적합 시정기한 D-60/D-30/D-14/D-7 알림 발송."""
    KST = timezone(timedelta(hours=9))
    while True:
        now = datetime.now(KST)
        next_run = now.replace(hour=8, minute=30, second=0, microsecond=0)
        if now >= next_run:
            next_run += timedelta(days=1)
        wait_seconds = (next_run - now).total_seconds()
        logger.info(f"부적합 시정기한 알림 다음 실행: {next_run.strftime('%Y-%m-%d %H:%M')} KST ({wait_seconds:.0f}초 후)")
        await asyncio.sleep(wait_seconds)
        try:
            await asyncio.to_thread(_run_inadequate_deadline_notify_sync)
            logger.info("부적합 시정기한 알림 발송 완료")
        except Exception as e:
            logger.error(f"부적합 시정기한 알림 발송 실패: {e}")


# ══════════════════════════════════════════════════════════════
# 설치확인서 캐시 일일 갱신 스케줄러 (매일 00:00 KST)
# ══════════════════════════════════════════════════════════════

async def _cert_cache_daily_scheduler():
    """매일 00:00 KST 에 설치확인서 SQLite 캐시 자동 재빌드."""
    KST = timezone(timedelta(hours=9))
    while True:
        now = datetime.now(KST)
        tomorrow_midnight = (now + timedelta(days=1)).replace(
            hour=0, minute=0, second=0, microsecond=0)
        wait_seconds = (tomorrow_midnight - now).total_seconds()
        logger.info(f"설치확인서 캐시 다음 갱신: {tomorrow_midnight.strftime('%Y-%m-%d %H:%M')} KST ({wait_seconds:.0f}초 후)")
        await asyncio.sleep(wait_seconds)
        try:
            await asyncio.to_thread(_cert_cache_force_rebuild)
            logger.info("설치확인서 캐시 자정 자동 갱신 완료")
        except Exception as e:
            logger.error(f"설치확인서 캐시 자정 갱신 실패: {e}")


# ══════════════════════════════════════════════════════════════
# 서버 시작 이벤트
# ══════════════════════════════════════════════════════════════

@app.on_event("startup")
async def startup_event():
    """서버 시작 — YOLO 모델은 Lazy Loading (첫 분류 요청 시 로드).

    EC2 메모리 최적화:
    - 모델 로드 지연 (~200MB 절약)
    - 임시파일 즉시 정리
    - DS 잡 워커 + xlsx 빌드 큐 백그라운드 시작
    """
    if HAS_PSUTIL:
        mem = psutil.virtual_memory()
        print(f"Server started! RAM: {mem.total // (1024*1024)}MB, used: {mem.percent}%")
    else:
        print("Server started successfully! (YOLO model: lazy load)")

    # SQLite DB 초기화
    await asyncio.to_thread(_init_inspection_db)

    # DynamoDB 테이블 자동 생성 (없으면)
    asyncio.create_task(_ensure_ds_jobs_table())
    asyncio.create_task(asyncio.to_thread(_ensure_audit_table))
    asyncio.create_task(asyncio.to_thread(_ensure_user_roles_table))
    asyncio.create_task(asyncio.to_thread(_ensure_route_baskets_table))

    # DS 잡 워커 (stuck 잡 복구 + 백그라운드 처리 루프)
    asyncio.create_task(_recover_stuck_jobs())
    asyncio.create_task(_job_worker_loop())

    # 설치확인서 캐시 미리 빌드 (백그라운드) + 매일 00:00 자동 갱신
    asyncio.create_task(asyncio.to_thread(_cert_cache_load))
    asyncio.create_task(_cert_cache_daily_scheduler())

    # SQLite DB 매일 03:00 KST S3 자동 백업
    asyncio.create_task(_sqlite_backup_daily_scheduler())

    # 휴면계정 처리 매일 09:00 KST
    asyncio.create_task(_dormant_account_daily_scheduler())

    # 부적합 시정기한 D-60/D-30/D-14/D-7 알림 매일 08:30 KST
    asyncio.create_task(_inadequate_deadline_scheduler())

    # Rate limiter + 호출명칭 세션 5분 주기 정리
    async def _rl_cleanup():
        while True:
            await asyncio.sleep(300)
            _rate_limiter.cleanup()
            _cleanup_callname_sessions()
    asyncio.create_task(_rl_cleanup())

    # 서버 시작 시 고아 임시파일 즉시 정리 + 10분 주기 정리
    await asyncio.to_thread(_cleanup_stale_temp_files, 0)

    async def _temp_cleanup_loop():
        while True:
            await asyncio.sleep(600)
            await asyncio.to_thread(_cleanup_stale_temp_files, 3600)
    asyncio.create_task(_temp_cleanup_loop())

    # DS xlsx 캐시 없는 본부 자동 스캔 → 빌드 큐 등록
    async def _startup_xlsx_scan():
        try:
            await asyncio.sleep(3)
            queued, skipped = await asyncio.to_thread(_scan_missing_xlsx_caches_sync)
            if queued:
                logger.info(f"DS startup: xlsx 빌드 {len(queued)}건 자동 등록: {queued}")
        except Exception as e:
            logger.warning(f"DS startup xlsx scan error: {e}")
    asyncio.create_task(_startup_xlsx_scan())

    print("DS job worker started")
