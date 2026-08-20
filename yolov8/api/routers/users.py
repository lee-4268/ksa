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

import hmac as _hmac_mod
from fastapi import APIRouter, HTTPException, Query, Request
from botocore.exceptions import ClientError

from core.auth import (
    _verify_auth, _require_role,
    _get_user_role_sync, _get_user_role_info,
    _ensure_user_in_roles_sync, _record_audit_log_sync,
    _list_all_users_sync, _invalidate_admin_users_cache, _dev_users,
    _mask_email, _mask_phone,
)
from core.config import (
    DYNAMODB_TABLES, VALID_ROLES, ADMIN_BOOTSTRAP_KEY,
)
from core.db import get_dynamodb_resource
from core.utils import decimal_to_native
from schemas.models import SetRoleRequest

router = APIRouter(tags=["users"])
logger = logging.getLogger(__name__)

# ── 엔드포인트 ────────────────────────────────────────────────

@router.get("/users")
async def list_users_count(request: Request = None):
    """사용자 데이터 통계 (DynamoDB user_roles 기준)."""
    await _verify_auth(request)
    users = await asyncio.to_thread(_list_all_users_sync)
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
        return {"success": False, "empno": empno}


@router.put("/admin/set-role")
async def set_user_role(req: SetRoleRequest, request: Request):
    """사용자 역할 설정.

    권한 정책:
    - admin/manager 또는 부트스트랩 키 필요
    - 본인 권한 이하(같거나 낮음)만 부여 가능 (admin→admin/manager/member, manager→manager/member)
    - 본인 자신의 권한은 변경 불가 (자기 강등 방지)
    """
    if req.role not in VALID_ROLES:
        raise HTTPException(
            status_code=400,
            detail=f"유효하지 않은 역할: {req.role} (가능: {', '.join(VALID_ROLES)})",
        )

    # 역할 레벨: 낮을수록 높은 권한
    role_level = {"admin": 0, "manager": 1, "member": 2}

    admin_key = request.headers.get("X-Admin-Key", "").strip()
    authorized = False
    caller_id = None
    caller_role = None
    if ADMIN_BOOTSTRAP_KEY and admin_key and _hmac_mod.compare_digest(admin_key, ADMIN_BOOTSTRAP_KEY):
        authorized = True
        logger.info(f"role 변경 (부트스트랩): {req.empno} → {req.role}")
    else:
        try:
            caller_id = await _verify_auth(request)
            caller_role = await asyncio.to_thread(_get_user_role_sync, caller_id)
            if caller_role in {"admin", "manager"}:
                authorized = True
        except HTTPException:
            pass

    if not authorized:
        raise HTTPException(status_code=403, detail="권한 없음 (admin/manager 또는 부트스트랩 키 필요)")

    # 부트스트랩 키가 아닌 일반 인증 경로일 때 추가 정책 검증
    if caller_role is not None:
        # 자기 자신 변경 금지
        if caller_id == req.empno:
            raise HTTPException(status_code=403, detail="본인 권한은 변경할 수 없습니다")
        # 본인 권한 이하만 부여 가능
        if role_level.get(caller_role, 99) > role_level.get(req.role, 99):
            raise HTTPException(
                status_code=403,
                detail=f"본인 권한({caller_role}) 이하만 부여 가능합니다 (요청: {req.role})",
            )
        # 대상이 본인보다 상위 권한이면 변경 불가
        target_role_current = await asyncio.to_thread(_get_user_role_sync, req.empno)
        if role_level.get(caller_role, 99) > role_level.get(target_role_current, 99):
            raise HTTPException(
                status_code=403,
                detail=f"본인({caller_role})보다 상위 권한 사용자({target_role_current})는 변경할 수 없습니다",
            )
        logger.info(f"role 변경 ({caller_role} {caller_id}): {req.empno} → {req.role}")

    try:
        old_role = await asyncio.to_thread(_get_user_role_sync, req.empno)
        dynamodb = get_dynamodb_resource()
        table = dynamodb.Table(DYNAMODB_TABLES["user_roles"])
        table.put_item(Item={"user_id": req.empno, "role": req.role})
        _invalidate_admin_users_cache()

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
        _invalidate_admin_users_cache()
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
        # PII 마스킹 (2026-07-27 보안진단 4.2 조치) — 검색은 위에서 원본으로 수행
        masked = [
            {**u,
             "email": _mask_email(u.get("email")),
             "phone": _mask_phone(u["phone"]) if u.get("phone") else None}
            for u in filtered
        ]
        return {"success": True, "users": masked, "total": len(masked)}
    except Exception as e:
        logger.error(f"admin users list failed: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")


# 감사 로그 entityType 목록 — DynamoDB 파티션 키라서 API 로 열거할 수 없다.
# _record_audit_log_sync 를 호출하는 곳이 늘어나면 여기에도 추가해야 '전체' 조회에 잡힌다.
_AUDIT_ENTITY_TYPES = (
    "User",                 # 로그인/로그아웃, 역할 변경
    "DSData",
    "callname_sample",
    "ds_변경이력",
    "ds_detail",
    "inspection_schedule",
    "inspection_result",
    "inspection_targets",
    "sisl_photo",
)


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

        def _query_one(et: str) -> list:
            """entityType 파티션 하나를 최신순으로 조회."""
            params: dict = {
                "KeyConditionExpression": "entityType = :et",
                "ExpressionAttributeValues": {":et": et},
                "ScanIndexForward": False,   # sk = timestamp#uuid → 최신 우선
                "Limit": limit,
            }
            if action:
                params["FilterExpression"] = "#a = :a"
                params["ExpressionAttributeNames"] = {"#a": "action"}
                params["ExpressionAttributeValues"][":a"] = action
            return table.query(**params).get("Items", [])

        if entityType:
            items = await asyncio.to_thread(_query_one, entityType)
        else:
            # 예전에는 scan(Limit=n) 이었는데, scan 은 파티션 순서대로 앞에서 n건을
            # 잘라오기 때문에 특정 entityType(예: inspection_result) 만 화면을 채우고
            # 다른 유형은 아예 보이지 않았다. 파티션별로 최신 n건을 받아 병합한다.
            def _query_all() -> list:
                merged: list = []
                for et in _AUDIT_ENTITY_TYPES:
                    try:
                        merged.extend(_query_one(et))
                    except Exception as qe:
                        logger.warning(f"audit query 실패 entityType={et}: {qe}")
                return merged
            items = await asyncio.to_thread(_query_all)

        logs = []
        for item in items:
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
        return {"success": True, "logs": logs[:limit]}
    except Exception as e:
        logger.error(f"audit logs list failed: {e}")
        raise HTTPException(status_code=500, detail="서버 내부 오류")
