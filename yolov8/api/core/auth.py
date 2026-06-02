"""
auth - 토큰 생성/검증, 블랙리스트, OTP 스토어, 역할 체크

담당 도메인: 인증/인가 전체
주요 의존성: core.config, core.db
엔드포인트: 없음

주의사항:
- _token_blacklist, _pre_auth_store, _sms_rate_store 는 이 모듈의 전역 상태
- _verify_auth()는 모든 보호 엔드포인트에서 호출 필수
- 감사 로그 기록 함수도 이 모듈에 위치 (auth 의존성 없이 utils에서 분리)
"""

import os
import hmac as _hmac_mod
import hashlib
import base64
import json
import uuid
import sqlite3
import asyncio
import threading
import time as _time_mod
import logging
from datetime import datetime, timezone, timedelta

from fastapi import HTTPException, Request

from .config import (
    AUTH_TOKEN_SECRET, AUTH_TOKEN_EXPIRY, DYNAMODB_TABLES, VALID_ROLES,
    _PBKDF2_ITER, _INSP_DB, ADMIN_USERS_CACHE_TTL
)
from .db import get_dynamodb_resource, get_dynamodb_client

logger = logging.getLogger(__name__)

# ── 토큰 블랙리스트 ────────────────────────────────────────────
# {sig: expiry_timestamp} — 만료된 항목은 자동 정리
_token_blacklist: dict[str, int] = {}

# ── OTP 2차 인증 저장소 ────────────────────────────────────────
_pre_auth_store: dict[str, dict] = {}   # {pre_auth_token: {empno, otp, expiry, attempts, phone}}
_sms_rate_store: dict[str, list] = {}   # {empno: [timestamps]}

PRE_AUTH_EXPIRY  = 5 * 60   # 5분
OTP_MAX_ATTEMPTS = 5
SMS_RATE_MAX     = 3         # 10분 내 최대 발송
SMS_RATE_WINDOW  = 10 * 60  # 10분

# ── 개발용 사용자 캐시 ─────────────────────────────────────────
_dev_users: dict = {}  # empno → {name, region, team, role}

# ── 관리자 사용자 목록 캐시 ────────────────────────────────────
_admin_users_cache: list | None = None
_admin_users_cache_time: float = 0

# ── 일일 방문자 카운트 ─────────────────────────────────────────
_daily_visitors: set = set()
_daily_visitors_date: str = ""


# ══════════════════════════════════════════════════════════════
# 비밀번호 해시
# ══════════════════════════════════════════════════════════════

def _hash_password(plain: str) -> str:
    """평문 비밀번호를 PBKDF2-SHA256으로 해시화. 빈 문자열은 빈 문자열 반환."""
    if not plain:
        return ''
    salt = os.urandom(16)
    h = hashlib.pbkdf2_hmac('sha256', plain.encode('utf-8'), salt, _PBKDF2_ITER)
    return f"pbkdf2_sha256${_PBKDF2_ITER}${salt.hex()}${h.hex()}"


def _verify_password(plain: str, hashed: str) -> bool:
    """저장된 해시와 평문을 비교. 잘못된 포맷이면 False."""
    if not (plain and hashed):
        return False
    try:
        scheme, iter_s, salt_hex, hash_hex = hashed.split('$')
        if scheme != 'pbkdf2_sha256':
            return False
        salt = bytes.fromhex(salt_hex)
        expected = bytes.fromhex(hash_hex)
        actual = hashlib.pbkdf2_hmac('sha256', plain.encode('utf-8'), salt, int(iter_s))
        return _hmac_mod.compare_digest(expected, actual)
    except Exception:
        return False


# ══════════════════════════════════════════════════════════════
# 토큰 생성/검증
# ══════════════════════════════════════════════════════════════

def _generate_token(empno: str) -> str:
    """HMAC-SHA256 토큰 생성: base64url(empno:expiry:signature)"""
    expiry = int(_time_mod.time()) + AUTH_TOKEN_EXPIRY
    payload = f"{empno}:{expiry}"
    sig = _hmac_mod.new(
        AUTH_TOKEN_SECRET.encode(), payload.encode(), hashlib.sha256
    ).hexdigest()
    token_raw = f"{payload}:{sig}"
    return base64.urlsafe_b64encode(token_raw.encode()).decode()


def _verify_token(token: str) -> str | None:
    """토큰 검증 → empno 반환. 무효/만료/블랙리스트 시 None."""
    try:
        decoded = base64.urlsafe_b64decode(token.encode()).decode()
        parts = decoded.split(":")
        if len(parts) != 3:
            return None
        empno, expiry_str, sig = parts
        expiry = int(expiry_str)
        if _time_mod.time() > expiry:
            return None
        expected = _hmac_mod.new(
            AUTH_TOKEN_SECRET.encode(), f"{empno}:{expiry_str}".encode(), hashlib.sha256
        ).hexdigest()
        if not _hmac_mod.compare_digest(sig, expected):
            return None
        # 블랙리스트 확인 (로그아웃된 토큰)
        if sig in _token_blacklist:
            return None
        return empno
    except Exception:
        return None


def _blacklist_token(token: str) -> None:
    """토큰을 블랙리스트에 추가하고, 만료된 항목 정리."""
    try:
        decoded = base64.urlsafe_b64decode(token.encode()).decode()
        parts = decoded.split(":")
        if len(parts) == 3:
            _, expiry_str, sig = parts
            expiry = int(expiry_str)
            now = int(_time_mod.time())
            if expiry > now:  # 아직 유효한 토큰만 블랙리스트 등록
                _token_blacklist[sig] = expiry
            # 만료된 항목 정리 (메모리 누수 방지)
            expired_sigs = [s for s, e in _token_blacklist.items() if e <= now]
            for s in expired_sigs:
                _token_blacklist.pop(s, None)
    except Exception:
        pass


# ══════════════════════════════════════════════════════════════
# 요청 인증 미들웨어 헬퍼
# ══════════════════════════════════════════════════════════════

def _track_daily_visitor(empno: str):
    """일일 방문자 집합에 사번 추가 (KST 자정 리셋)."""
    global _daily_visitors, _daily_visitors_date
    kst = timezone(timedelta(hours=9))
    today = datetime.now(kst).strftime("%Y-%m-%d")
    if _daily_visitors_date != today:
        _daily_visitors = set()
        _daily_visitors_date = today
    _daily_visitors.add(empno)


def _count_daily_visitors() -> int:
    """오늘(KST) 고유 접속자 수 (menu_usage_log 기반, 서버 재시작해도 유지)."""
    try:
        if not os.path.exists(_INSP_DB):
            return len(_daily_visitors)
        kst = timezone(timedelta(hours=9))
        kst_midnight_utc = datetime.now(kst).replace(hour=0, minute=0, second=0, microsecond=0).astimezone(timezone.utc).isoformat()
        conn = sqlite3.connect(_INSP_DB, timeout=10)
        cnt = conn.execute(
            "SELECT COUNT(DISTINCT user_id) FROM menu_usage_log WHERE accessed_at >= ?",
            (kst_midnight_utc,)
        ).fetchone()[0]
        conn.close()
        return cnt
    except Exception:
        return len(_daily_visitors)


async def _verify_auth(request: Request) -> str:
    """Bearer 토큰 검증. 실패 시 401.
    토큰 잔여 수명이 절반 이하이면 request.state.refreshed_token에 새 토큰 저장.
    """
    auth_header = request.headers.get("Authorization", "")
    if auth_header.startswith("Bearer "):
        token = auth_header[7:]
        empno = _verify_token(token)
        if empno:
            _track_daily_visitor(empno)
            # 토큰 잔여 수명 체크 → 절반 이하면 갱신
            try:
                decoded = base64.urlsafe_b64decode(token.encode()).decode()
                expiry = int(decoded.split(":")[1])
                remaining = expiry - int(_time_mod.time())
                if remaining < AUTH_TOKEN_EXPIRY // 2:
                    request.state.refreshed_token = _generate_token(empno)
            except Exception:
                pass
            return empno
        raise HTTPException(status_code=401, detail="토큰이 만료되었거나 유효하지 않습니다")

    raise HTTPException(status_code=401, detail="인증 정보 없음")


# ══════════════════════════════════════════════════════════════
# 역할 조회/체크
# ══════════════════════════════════════════════════════════════

def _get_user_role_sync(empno: str) -> str:
    """kca-user-roles 테이블에서 role 조회. 없으면 'member' 반환.
    dev 로그인 계정은 DynamoDB 대신 _dev_users 메모리에서 조회."""
    # dev 로그인 계정 우선 확인
    dev = _dev_users.get(empno)
    if dev:
        role = dev.get("role", "member")
        return role if role in VALID_ROLES else "member"
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        resp = table.get_item(
            Key={"user_id": empno},
            ProjectionExpression="#r",
            ExpressionAttributeNames={"#r": "role"},
        )
        item = resp.get("Item")
        if item and item.get("role") in VALID_ROLES:
            return item["role"]
    except Exception as e:
        logger.warning(f"role 조회 실패 ({empno}): {e}")
    return "member"


def _get_user_role_info(empno: str) -> dict:
    """kca-user-roles 테이블에서 role + last_login + is_dormant 한 번에 조회."""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        resp = table.get_item(
            Key={"user_id": empno},
            ProjectionExpression="#r, last_login, is_dormant",
            ExpressionAttributeNames={"#r": "role"},
        )
        item = resp.get("Item", {})
        role = item.get("role", "member")
        if role not in VALID_ROLES:
            role = "member"
        return {
            "role": role,
            "last_login": item.get("last_login", ""),
            "is_dormant": bool(item.get("is_dormant", False)),
        }
    except Exception as e:
        logger.warning(f"user_role_info 조회 실패 ({empno}): {e}")
        return {"role": "member", "last_login": "", "is_dormant": False}


def _get_last_login(empno: str) -> str:
    """kca-user-roles 테이블에서 last_login 조회."""
    return _get_user_role_info(empno)["last_login"]


async def _require_role(request: Request, allowed_roles: set) -> str:
    """Bearer 토큰 검증 → role 확인. 401/403."""
    empno = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, empno)
    if role not in allowed_roles:
        raise HTTPException(status_code=403, detail=f"권한 없음 (현재: {role}, 필요: {', '.join(allowed_roles)})")
    return empno


async def _require_owner_or_admin(request: Request, owner: str) -> str:
    """카테고리/스테이션 소유자 격리 헬퍼.

    - 본인(caller_empno == owner) → 통과
    - admin → 통과 (인사/관리 목적)
    - 그 외 → 403
    """
    caller = await _verify_auth(request)
    if caller == owner:
        return caller
    role = await asyncio.to_thread(_get_user_role_sync, caller)
    if role == "admin":
        return caller
    raise HTTPException(403, "본인 소유 데이터만 접근 가능합니다")


async def _check_object_owner_or_admin(request: Request, owner_field: str, db_owner: str) -> str:
    """이미 저장된 객체(category/station)의 owner와 caller를 비교."""
    caller = await _verify_auth(request)
    if caller == db_owner:
        return caller
    role = await asyncio.to_thread(_get_user_role_sync, caller)
    if role == "admin":
        return caller
    raise HTTPException(403, f"{owner_field} 소유자만 접근 가능합니다")


# ══════════════════════════════════════════════════════════════
# 사용자 관리 헬퍼
# ══════════════════════════════════════════════════════════════

def _ensure_user_in_roles_sync(empno: str):
    """kca-user-roles 테이블에 사용자가 없으면 member로 자동 등록 (로그인 시 호출)"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        resp = table.get_item(
            Key={"user_id": empno},
            ProjectionExpression="user_id",
        )
        if not resp.get("Item"):
            table.put_item(Item={"user_id": empno, "role": "member"})
            logger.info(f"kca-user-roles 자동 등록: {empno} (member)")
            # 캐시 무효화
            global _admin_users_cache
            _admin_users_cache = None
    except Exception as e:
        logger.warning(f"kca-user-roles 자동 등록 실패 ({empno}): {e}")


def _update_last_login(empno: str):
    """로그인 시 last_login 업데이트 (kca-user-roles 테이블)"""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        table.update_item(
            Key={"user_id": empno},
            UpdateExpression="SET last_login = :ts",
            ExpressionAttributeValues={":ts": datetime.now(timezone.utc).isoformat()},
        )
    except Exception as e:
        logger.warning(f"last_login 업데이트 실패 ({empno}): {e}")


def _ensure_user_roles_table():
    """서버 시작 시 kca-user-roles 테이블 자동 생성"""
    from botocore.exceptions import ClientError
    try:
        client = get_dynamodb_client()
        client.create_table(
            TableName=DYNAMODB_TABLES["user_roles"],
            KeySchema=[{"AttributeName": "user_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "user_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        logger.info(f"DynamoDB table {DYNAMODB_TABLES['user_roles']} created")
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceInUseException":
            logger.warning(f"user_roles table creation error (non-fatal): {e}")


def _ensure_route_baskets_table():
    """서버 시작 시 kca-route-baskets 테이블 자동 생성"""
    from botocore.exceptions import ClientError
    try:
        client = get_dynamodb_client()
        client.create_table(
            TableName=DYNAMODB_TABLES["route_baskets"],
            KeySchema=[
                {"AttributeName": "user_id", "KeyType": "HASH"},
                {"AttributeName": "entry_id", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "user_id", "AttributeType": "S"},
                {"AttributeName": "entry_id", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        logger.info(f"DynamoDB table {DYNAMODB_TABLES['route_baskets']} created")
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceInUseException":
            logger.warning(f"route_baskets table creation error (non-fatal): {e}")


def _ensure_audit_table():
    """서버 시작 시 kca-audit-logs 테이블 자동 생성"""
    from botocore.exceptions import ClientError
    try:
        client = get_dynamodb_client()
        client.create_table(
            TableName=DYNAMODB_TABLES["audit_logs"],
            KeySchema=[
                {"AttributeName": "entityType", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
            AttributeDefinitions=[
                {"AttributeName": "entityType", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            BillingMode="PAY_PER_REQUEST",
        )
        logger.info(f"DynamoDB table {DYNAMODB_TABLES['audit_logs']} created")
        # TTL 활성화
        client.update_time_to_live(
            TableName=DYNAMODB_TABLES["audit_logs"],
            TimeToLiveSpecification={"Enabled": True, "AttributeName": "ttl"},
        )
    except ClientError as e:
        if e.response["Error"]["Code"] != "ResourceInUseException":
            logger.warning(f"audit table creation error (non-fatal): {e}")


# ══════════════════════════════════════════════════════════════
# 감사 로그
# ══════════════════════════════════════════════════════════════

def _record_audit_log_sync(action: str, entity_type: str, entity_id: str,
                            user_id: str, details: dict | None = None):
    """감사 로그를 DynamoDB kca-audit-logs에 기록 (동기, to_thread로 호출)"""
    import time as _time
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["audit_logs"])
        now = datetime.now(timezone.utc).isoformat()
        log_id = str(uuid.uuid4())

        item = {
            "entityType": entity_type,
            "sk": f"{now}#{log_id}",
            "action": action,
            "entityId": entity_id,
            "userId": user_id,
            "timestamp": now,
            "canRollback": False,
            "ttl": int(_time.time()) + 90 * 86400,  # 90일 후 자동 삭제
        }

        # 사용자 이름 denormalization
        try:
            users_table = dynamodb.Table(DYNAMODB_TABLES["users"])
            user_resp = users_table.get_item(
                Key={"user_id": user_id},
                ProjectionExpression="#n",
                ExpressionAttributeNames={"#n": "name"},
            )
            if user_resp.get("Item"):
                item["userName"] = user_resp["Item"].get("name", user_id)
        except Exception:
            pass

        if details:
            item.update(details)

        table.put_item(Item=item)
        logger.info(f"audit: {action} {entity_type} {entity_id} by {user_id}")
    except Exception as e:
        logger.error(f"audit log write failed: {e}")


# ══════════════════════════════════════════════════════════════
# 전체 사용자 목록 (admin 화면용)
# ══════════════════════════════════════════════════════════════

def _invalidate_admin_users_cache():
    """관리자 사용자 목록 캐시 무효화 (역할/휴면 변경 후 호출)."""
    global _admin_users_cache, _admin_users_cache_time
    _admin_users_cache = None
    _admin_users_cache_time = 0


def _list_all_users_sync() -> list:
    """kca-user-roles 스캔 → Users 테이블 개별 조회 (캐시 60초)"""
    global _admin_users_cache, _admin_users_cache_time
    import time as _time
    now = _time.time()
    if _admin_users_cache is not None and (now - _admin_users_cache_time) < ADMIN_USERS_CACHE_TTL:
        return _admin_users_cache

    dynamodb = get_dynamodb_resource()
    roles_table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
    users_table = dynamodb.Table(DYNAMODB_TABLES["users"])

    # 1) kca-user-roles 테이블 전체 스캔 (우리 테이블, 소규모)
    role_items = []
    params: dict = {}
    while True:
        resp = roles_table.scan(**params)
        role_items.extend(resp.get("Items", []))
        if "LastEvaluatedKey" not in resp:
            break
        params["ExclusiveStartKey"] = resp["LastEvaluatedKey"]

    logger.info(f"kca-user-roles 스캔 결과: {len(role_items)}명")

    # 2) 각 user_id로 Users 테이블에서 이름/본부/팀 조회 (읽기전용 get_item)
    users = []
    for role_item in role_items:
        uid = role_item.get("user_id", "")
        if not uid:
            continue
        user_role = role_item.get("role", "member")

        try:
            user_resp = users_table.get_item(Key={"user_id": uid})
            if not user_resp.get("Item"):
                user_resp = users_table.get_item(Key={"user_id": uid.upper()})
            user_info = user_resp.get("Item")
            if user_info:
                logger.info(f"Users 조회 성공 ({uid}): name={user_info.get('name')}, keys={list(user_info.keys())}")
            else:
                logger.warning(f"Users 테이블에 해당 user_id 없음: {uid}")
                user_info = {}
        except Exception as e:
            logger.warning(f"Users 테이블 조회 실패 ({uid}): {e}")
            user_info = {}

        users.append({
            "empno": uid,
            "name": user_info.get("name") or None,
            "region": user_info.get("region") or None,
            "team": user_info.get("team") or None,
            "email": user_info.get("email") or None,
            "phone": user_info.get("phone_number") or None,
            "role": user_role,
            "last_login": role_item.get("last_login") or None,
            "is_dormant": bool(role_item.get("is_dormant", False)),
        })

    # 대소문자 중복 제거 (role 우선순위: admin > manager > member)
    _ROLE_RANK = {"admin": 3, "manager": 2, "member": 1, "": 0}
    deduped: dict = {}
    for u in users:
        key = u["empno"].upper()
        if key not in deduped:
            u["empno"] = key
            deduped[key] = u
            continue
        cur = deduped[key]
        if _ROLE_RANK.get(u.get("role") or "", 0) > _ROLE_RANK.get(cur.get("role") or "", 0):
            cur["role"] = u["role"]
        if (u.get("last_login") or "") > (cur.get("last_login") or ""):
            cur["last_login"] = u["last_login"]
        if not u.get("is_dormant"):
            cur["is_dormant"] = False
        for fld in ("name", "region", "team", "email", "phone"):
            if not cur.get(fld) and u.get(fld):
                cur[fld] = u[fld]
    users = list(deduped.values())

    users.sort(key=lambda u: u.get("name") or "")
    _admin_users_cache = users
    _admin_users_cache_time = now
    return users


# ══════════════════════════════════════════════════════════════
# 본부 접근 제어 (DS 격리)
# ══════════════════════════════════════════════════════════════

def _user_region_to_access(region: str) -> str:
    """DynamoDB의 region 값 ('강남Access담당' 등) → access담당 키('강남') 변환."""
    if not region:
        return ''
    return region.replace('Access담당', '').replace('본부', '').strip()


def _caller_allowed_access_list(empno: str) -> list[str]:
    """caller의 본부에서 접근 가능한 access담당 값 목록 반환."""
    from .config import _ACCESS_TO_DIVISION, _DIVISION_TO_ACCESS_LIST
    # 커뮤니티 기반 region 조회
    info = _get_user_info_for_community(empno)
    region = info.get('org') or ''
    try:
        ddb = get_dynamodb_resource()
        item = ddb.Table(DYNAMODB_TABLES["users"]).get_item(
            Key={"user_id": empno},
            ProjectionExpression="#r",
            ExpressionAttributeNames={"#r": "region"},
        ).get('Item') or {}
        region = item.get('region') or region
    except Exception:
        pass
    acc = _user_region_to_access(region)
    div = _ACCESS_TO_DIVISION.get(acc, '')
    if div and div in _DIVISION_TO_ACCESS_LIST:
        return list(_DIVISION_TO_ACCESS_LIST[div])
    return [acc] if acc else []


def _get_user_info_for_community(empno: str) -> dict:
    """Users DynamoDB 테이블에서 이름·소속 조회."""
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["users"])
        resp = table.get_item(
            Key={"user_id": empno},
            ProjectionExpression="#n, #r, #t",
            ExpressionAttributeNames={"#n": "name", "#r": "region", "#t": "team"},
        )
        item = resp.get("Item", {})
        name = item.get("name", empno)
        region = item.get("region", "")
        team = item.get("team", "")
        org = team if team else region
        return {"name": name, "org": org}
    except Exception as e:
        logger.warning(f"community user info 조회 실패 ({empno}): {e}")
        return {"name": empno, "org": ""}


async def _check_division_access(request: Request, target_access: str) -> tuple[str, str, list[str]]:
    """본부 격리 검사.

    Returns: (caller_empno, caller_role, allowed_access_list)
    - admin: 모든 본부 허용
    - manager/member: caller_allowed_access_list에 target_access가 포함되어야 함
    """
    caller = await _verify_auth(request)
    role = await asyncio.to_thread(_get_user_role_sync, caller)
    if role == 'admin':
        return caller, role, []  # 빈 리스트 = 제약 없음
    allowed = await asyncio.to_thread(_caller_allowed_access_list, caller)
    if target_access:
        if target_access not in allowed:
            raise HTTPException(403, "본인 본부 데이터만 접근 가능합니다")
    return caller, role, allowed


# ══════════════════════════════════════════════════════════════
# 전화번호 유틸
# ══════════════════════════════════════════════════════════════
# 2026-06-01: 자체 SMS 발송(Celery)/OTP 생성 로직은 인프라 통합 SSO 로 이관되어
# 제거. 응답 마스킹용 _mask_phone 과 _get_user_phone_sync 만 유지.

def _mask_phone(phone: str) -> str:
    """전화번호 마스킹 (개인정보 보호)."""
    clean = phone.replace('-', '').replace(' ', '')
    if len(clean) == 11:
        return f"{clean[:3]}-****-{clean[7:]}"
    if len(clean) == 10:
        return f"{clean[:3]}-***-{clean[6:]}"
    return "***-****-****"


def _get_user_phone_sync(empno: str) -> str | None:
    """DynamoDB Users 테이블에서 phone_number 조회."""
    try:
        ddb = get_dynamodb_resource()
        tbl = ddb.Table(DYNAMODB_TABLES["users"])
        resp = tbl.get_item(Key={"user_id": empno})
        item = resp.get("Item") or tbl.get_item(Key={"user_id": empno.upper()}).get("Item")
        return (item or {}).get("phone_number") or None
    except Exception as e:
        logger.warning(f"phone_number 조회 실패 ({empno}): {e}")
        return None
