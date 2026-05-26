"""
users - 사용자 관리 엔드포인트

담당 도메인: 사용자/역할/감사로그 관리
주요 의존성: core.auth, core.db, core.config
엔드포인트:
    GET  /users
    GET  /users/{empno}
    PUT  /admin/set-role
    POST /admin/undormant/{empno}
    GET  /admin/users
    GET  /admin/audit-logs
"""

import asyncio
import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import hmac as _hmac_mod
from fastapi import APIRouter, HTTPException, Query, Request
from botocore.exceptions import ClientError

from core.auth import (
    _verify_auth, _require_role,
    _get_user_role_sync, _get_user_role_info,
    _ensure_user_in_roles_sync, _record_audit_log_sync,
    _list_all_users_sync, _dev_users,
)
from core.config import (
    DYNAMODB_TABLES, VALID_ROLES, ADMIN_BOOTSTRAP_KEY, USERS_DATA_PATH,
)
from core.db import get_dynamodb_resource
from core.utils import decimal_to_native
from schemas.models import SetRoleRequest

router = APIRouter(tags=["users"])
logger = logging.getLogger(__name__)

# ── 로컬 유틸 ─────────────────────────────────────────────────

_users_cache: Optional[dict] = None


def _load_users() -> dict:
    """JSON 파일에서 사용자 데이터 로드 (캐시)."""
    global _users_cache
    if _users_cache is not None:
        return _users_cache
    data_path = Path(USERS_DATA_PATH)
    if not data_path.exists():
        logger.warning(f"Users data file not found: {data_path}")
        _users_cache = {}
        return _users_cache
    import json as _json
    with open(data_path, "r", encoding="utf-8") as f:
        users_list = _json.load(f)
    _users_cache = {u["empno"]: u for u in users_list if "empno" in u}
    logger.info(f"Loaded {len(_users_cache)} users from {data_path}")
    return _users_cache


# ── 엔드포인트 ────────────────────────────────────────────────

@router.get("/users")
async def list_users_count(request: Request = None):
    """사용자 데이터 통계."""
    await _verify_auth(request)
    users = _load_users()
    return {
        "success": True,
        "total_users": len(users),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@router.get("/users/{empno}")
async def get_user_by_empno(empno: str, request: Request = None):
    """사번으로 사용자 정보 조회.

    권한 정책:
    - 본인 조회: 모든 필드(이메일/전화 포함)
    - 타인 조회: admin/manager 만 허용 (PII 보호)
    """
    caller_empno = await _verify_auth(request)
    is_self = (caller_empno == empno)
    if not is_self:
        caller_role = await asyncio.to_thread(_get_user_role_sync, caller_empno)
        if caller_role not in {"admin", "manager"}:
            raise HTTPException(403, "다른 사용자 정보는 관리자만 조회 가능")

    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["users"])
        response = table.get_item(Key={"user_id": empno})
        user = response.get("Item")

        if not user:
            dev = _dev_users.get(empno)
            if dev:
                return {
                    "success": True, "empno": empno,
                    "name": dev["name"], "region": dev["region"],
                    "team": dev["team"], "role": dev["role"],
                }
            return {"success": False, "empno": empno, "message": "User not found"}

        await asyncio.to_thread(_ensure_user_in_roles_sync, empno)
        role_info = await asyncio.to_thread(_get_user_role_info, empno)
        role       = role_info["role"]
        last_login = role_info["last_login"]
        is_dormant = role_info["is_dormant"]

        out = {
            "success": True,
            "empno": empno,
            "name": user.get("name"),
            "region": user.get("region"),
            "team": user.get("team"),
            "role": role,
            "last_login": last_login,
            "is_dormant": is_dormant,
        }
        if is_self:
            out["email"] = user.get("email")
            out["phone"] = user.get("phone_number")
        return out

    except ClientError as e:
        logger.error(f"DynamoDB error: {e}")
        users = _load_users()
        user = users.get(empno)
        if user:
            return {
                "success": True,
                "empno": empno,
                "name": user.get("name"),
                "region": user.get("region"),
                "team": user.get("DeptName"),
                "role": "member",
            }
        return {"success": False, "empno": empno}


@router.put("/admin/set-role")
async def set_user_role(req: SetRoleRequest, request: Request):
    """사용자 역할 설정 — admin 또는 부트스트랩 키 필요."""
    if req.role not in VALID_ROLES:
        raise HTTPException(
            status_code=400,
            detail=f"유효하지 않은 역할: {req.role} (가능: {', '.join(VALID_ROLES)})",
        )

    admin_key = request.headers.get("X-Admin-Key", "").strip()
    authorized = False
    caller_id = None
    if ADMIN_BOOTSTRAP_KEY and admin_key and _hmac_mod.compare_digest(admin_key, ADMIN_BOOTSTRAP_KEY):
        authorized = True
        logger.info(f"role 변경 (부트스트랩): {req.empno} → {req.role}")
    else:
        try:
            caller_id = await _verify_auth(request)
            caller_role = await asyncio.to_thread(_get_user_role_sync, caller_id)
            if caller_role == "admin":
                authorized = True
                logger.info(f"role 변경 (admin {caller_id}): {req.empno} → {req.role}")
        except HTTPException:
            pass

    if not authorized:
        raise HTTPException(status_code=403, detail="권한 없음 (admin 또는 부트스트랩 키 필요)")

    try:
        old_role = await asyncio.to_thread(_get_user_role_sync, req.empno)
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        table.put_item(Item={"user_id": req.empno, "role": req.role})

        actor = caller_id or "bootstrap"
        await asyncio.to_thread(
            _record_audit_log_sync, "UPDATE", "User", req.empno, actor,
            {
                "previousData": json.dumps({"role": old_role}),
                "newData": json.dumps({"role": req.role}),
                "changedFields": ["role"],
            },
        )
        return {"success": True, "empno": req.empno, "role": req.role}
    except Exception as e:
        logger.error(f"role 설정 실패: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.post("/admin/undormant/{empno}")
async def admin_undormant(empno: str, request: Request):
    """휴면계정 해제 — admin 전용."""
    caller_id = await _verify_auth(request)
    caller_role = await asyncio.to_thread(_get_user_role_sync, caller_id)
    if caller_role != "admin":
        raise HTTPException(status_code=403, detail="admin 권한 필요")
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        table.update_item(
            Key={"user_id": empno},
            UpdateExpression="SET is_dormant = :f, last_login = :now REMOVE notified_d7, notified_d3, notified_d1",
            ExpressionAttributeValues={
                ":f": False,
                ":now": datetime.now(timezone.utc).isoformat(),
            },
        )
        logger.info(f"휴면 해제: {empno} (by {caller_id})")
        return {"success": True, "empno": empno, "message": "휴면 해제 완료"}
    except Exception as e:
        logger.error(f"휴면 해제 실패 ({empno}): {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.get("/admin/users")
async def admin_list_users(
    request: Request,
    search: str | None = None,
    region: str | None = None,
    role: str | None = None,
):
    """사용자 목록 조회 — admin/manager만."""
    await _require_role(request, {"admin", "manager"})
    try:
        users = await asyncio.to_thread(_list_all_users_sync)
        filtered = users
        if search:
            q = search.lower()
            filtered = [u for u in filtered
                        if q in u.get("name", "").lower()
                        or q in u.get("empno", "").lower()
                        or q in u.get("email", "").lower()]
        if region:
            filtered = [u for u in filtered if u.get("region", "") == region]
        if role:
            filtered = [u for u in filtered if u.get("role", "member") == role]
        return {"success": True, "users": filtered, "total": len(filtered)}
    except Exception as e:
        logger.error(f"admin users list failed: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


@router.get("/admin/audit-logs")
async def admin_list_audit_logs(
    request: Request,
    entityType: str | None = None,
    action: str | None = None,
    limit: int = 50,
):
    """감사 로그 조회 — admin/manager만."""
    await _require_role(request, {"admin", "manager"})
    try:
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["audit_logs"])

        if entityType:
            params: dict = {
                "KeyConditionExpression": "entityType = :et",
                "ExpressionAttributeValues": {":et": entityType},
                "ScanIndexForward": False,
                "Limit": limit,
            }
            if action:
                params["FilterExpression"] = "#a = :a"
                params["ExpressionAttributeNames"] = {"#a": "action"}
                params["ExpressionAttributeValues"][":a"] = action
            resp = await asyncio.to_thread(lambda: table.query(**params))
        else:
            params = {"Limit": limit}
            if action:
                params["FilterExpression"] = "#a = :a"
                params["ExpressionAttributeNames"] = {"#a": "action"}
                params["ExpressionAttributeValues"] = {":a": action}
            resp = await asyncio.to_thread(lambda: table.scan(**params))

        logs = []
        for item in resp.get("Items", []):
            sk = item.get("sk", "")
            log_id = sk.split("#")[-1] if "#" in sk else sk
            logs.append({
                "id": log_id,
                "action": item.get("action", "UPDATE"),
                "entityType": item.get("entityType", ""),
                "entityId": item.get("entityId", ""),
                "userId": item.get("userId", ""),
                "userName": item.get("userName"),
                "timestamp": item.get("timestamp", ""),
                "previousData": item.get("previousData"),
                "newData": item.get("newData"),
                "changedFields": item.get("changedFields"),
                "canRollback": item.get("canRollback", False),
            })
        logs.sort(key=lambda x: x.get("timestamp", ""), reverse=True)
        return {"success": True, "logs": logs}
    except Exception as e:
        logger.error(f"audit logs list failed: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")
